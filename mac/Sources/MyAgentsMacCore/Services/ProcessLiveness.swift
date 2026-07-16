import Darwin
import Foundation

/// Discovers and validates OS processes using ONLY public Darwin/`libproc` APIs — no private
/// frameworks, no entitlements beyond ordinary (non-sandboxed, see CONTEXT.md D5) user privileges.
/// Mirrors the Windows `ProcessScanner`/`ProcessLiveness`
/// (`src/MyAgents/Services/ProcessScanner.cs`, `ProcessLiveness.cs`): there's no WSL on macOS, so
/// this talks directly to the native process table instead of shelling out to `wsl.exe`.
///
/// APIs used, every one confirmed against this machine's actual macOS 26 SDK headers
/// (`usr/include/libproc.h`, `usr/include/sys/proc_info.h`, `usr/include/sys/sysctl.h`) by
/// compiling and running a standalone Swift program that calls each of them — see CONTEXT.md
/// Hito 1 notes for the exact commands:
///   - `proc_listpids(PROC_ALL_PIDS, …)` — enumerate every live pid.
///   - `proc_pidpath(pid, …)` — the process's resolved executable path.
///   - `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` → `proc_bsdinfo.pbi_name` — the short "comm" name
///     (what `ps -o comm` shows), used to recognize `claude`/`codex` directly.
///   - `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)` → `proc_vnodepathinfo.pvi_cdir.vip_path` —
///     the process's current working directory, best-effort (fails for another user's process).
///   - `sysctl([CTL_KERN, KERN_PROCARGS2, pid], …)` — the process's `argv`, used to recognize a
///     CLI running under a script host (`node`/`bun`/`deno`) whose `comm` name is just the host.
///   - POSIX `kill(pid, 0)` — liveness check (signal 0 sends nothing, only validates existence).
/// None of these are documented on developer.apple.com (they're BSD/Darwin-layer interfaces, not
/// an Apple framework) — the SDK header + man page (`man 2 kill`, `man 3 sysctl`) is the source of
/// truth, and this is the same interface `ps`/Activity Monitor/`top` are built on.
public enum ProcessLiveness {
    /// One live process this scanner recognized as a Claude Code or Codex CLI.
    public struct DiscoveredProcess: Equatable, Sendable {
        public let pid: Int32
        public let provider: Provider
        /// Best-effort current working directory. Empty when we couldn't read it (permission,
        /// or the process exited mid-scan).
        public let cwd: String
        /// Best-effort resolved executable path. Empty when `proc_pidpath` failed.
        public let executablePath: String
        /// Parent process id (`pbi_ppid`), read from the SAME `PROC_PIDTBSDINFO` fetch that gives
        /// the short name — never a second syscall (energy law). `0` when the `bsdInfo` fetch
        /// failed (e.g. a process owned by another user). Used by `classifyAncestry` to tell a
        /// standalone interactive session apart from a nested subagent / orphan.
        public let ppid: Int32
        /// Controlling terminal device path (e.g. `/dev/ttys005`), from the SAME `PROC_PIDTBSDINFO`
        /// fetch that gives the name/ppid (`e_tdev`, mapped via `devname` — no extra syscall). Empty
        /// when the process has no controlling terminal. Lets click-to-focus select the EXACT tab
        /// hosting a Codex session, which — unlike Claude — writes no hook file carrying a title.
        public let tty: String

        public init(pid: Int32, provider: Provider, cwd: String, executablePath: String, ppid: Int32 = 0, tty: String = "") {
            self.pid = pid
            self.provider = provider
            self.cwd = cwd
            self.executablePath = executablePath
            self.ppid = ppid
            self.tty = tty
        }
    }

    /// One row of the whole-process-table ancestry map: a pid's parent and its short `comm` name.
    /// A tiny value type (not a raw tuple) so the map is trivially `Sendable` when threaded through
    /// `SessionStore`'s off-main scan closure.
    public struct ProcessTableEntry: Equatable, Sendable {
        public let ppid: Int32
        public let comm: String

        public init(ppid: Int32, comm: String) {
            self.ppid = ppid
            self.comm = comm
        }
    }

    /// How an agent process relates to the session tree, decided purely from ancestry.
    /// - `interactive`: a genuine standalone session (its ancestry reaches a login shell / Terminal
    ///   / launchd without passing through another agent or a non-session owner) — keep as a tile.
    /// - `subagent(parentPid)`: nested under another tracked AGENT process — fold into that parent
    ///   session's count, never a tile of its own.
    /// - `orphan`: owned by the app itself or ChatGPT — a phantom, hidden entirely.
    public enum ProcessAncestry: Equatable, Sendable {
        case interactive
        case subagent(parentPid: Int32)
        case orphan
    }

    /// `true` iff a process with this pid exists right now.
    ///
    /// Uses `kill(pid, 0)`: signal 0 sends no actual signal, it only validates existence +
    /// permission. `EPERM` (process exists, owned by someone else — e.g. root) still counts as
    /// alive; only `ESRCH` ("no such process") means dead.
    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Scans every process on the system and returns the ones that look like a Claude Code or
    /// Codex CLI, best-effort. Never throws: any single pid that fails to introspect (permission,
    /// or it exited mid-scan) is skipped, not fatal to the whole scan.
    public static func discoverAgentProcesses() -> [DiscoveredProcess] {
        pids().compactMap(classify(pid:))
    }

    /// Builds the whole-process-table ancestry map: `pid → (ppid, comm)` for every live process,
    /// best-effort. This is the WHOLE table (not just agents) because `classifyAncestry` and
    /// `terminalHost` have to walk through transparent ancestors (shells, `login`, `Terminal`) that
    /// aren't agents.
    ///
    /// Built with ONE `sysctl(KERN_PROC_ALL)` — deliberately NOT `proc_pidinfo` per pid. The chain
    /// from a user's shell up to Terminal.app passes through a ROOT-owned `login` (Terminal spawns
    /// `login`, which drops to the user's shell), and `proc_pidinfo(PROC_PIDTBSDINFO)` CANNOT read
    /// another user's process — so `login` was silently missing from the table, the ancestry walk
    /// died there before reaching `Terminal`, and every hookless discovered session (a Codex row, or
    /// a Claude with no hook file) resolved `terminalHost == ""` → `.unsupported` → click did
    /// nothing. `KERN_PROC_ALL` returns ppid + `p_comm` for EVERY process regardless of owner (it's
    /// what `ps` uses), so the chain is complete. `p_comm` is capped at `MAXCOMLEN` (16) — fine here:
    /// every name we match on (`terminal`, `iterm2`, `ghostty`, `claude`, `codex`, `codex-code-mode…`)
    /// fits. Falls back to the old per-pid scan if the sysctl fails.
    public static func processTable() -> [Int32: ProcessTableEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return processTableViaProcInfo()
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Over-allocate: the table can grow between the sizing call and the fetch.
        let capacity = size / stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var written = capacity * stride
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var length = raw.count
            let result = sysctl(&mib, 4, raw.baseAddress, &length, nil, 0)
            written = length
            return result
        }
        guard rc == 0, written > 0 else { return processTableViaProcInfo() }

        let count = min(written / stride, buffer.count)
        var table: [Int32: ProcessTableEntry] = [:]
        table.reserveCapacity(count)
        for i in 0..<count {
            let pid = buffer[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            let comm = nulTerminatedCString(from: &buffer[i].kp_proc.p_comm)
            table[pid] = ProcessTableEntry(ppid: buffer[i].kp_eproc.e_ppid, comm: comm)
        }
        return table.isEmpty ? processTableViaProcInfo() : table
    }

    /// Fallback table via `proc_pidinfo` per pid (the original implementation). Misses root-owned
    /// ancestors like `login`, so `terminalHost` may come back empty for a hookless session — but a
    /// degraded table beats no table if `KERN_PROC_ALL` ever fails.
    private static func processTableViaProcInfo() -> [Int32: ProcessTableEntry] {
        var table: [Int32: ProcessTableEntry] = [:]
        for pid in pids() {
            guard let bsd = bsdInfo(pid: pid) else { continue }
            table[Int32(pid)] = ProcessTableEntry(ppid: bsd.ppid, comm: bsd.name)
        }
        return table
    }

    // MARK: - Ancestry classification (pure — synthetic tables, no real processes)

    /// Comm names, and a max walk depth, that make `classifyAncestry` a pure function of the map.
    private static let maxAncestryDepth = 64

    /// A tracked AGENT ancestor — the thing that makes a codex/claude a SUBAGENT rather than a
    /// standalone session. Recognized by `comm` alone (cheap): `claude`, `codex`, `codex-*` — but
    /// NOT a Codex internal helper (`isCodexHelper`), which is a child of a real codex, not a session.
    static func isAgentComm(_ comm: String) -> Bool {
        let name = comm.lowercased()
        if isCodexHelper(name) { return false }
        return name == "claude" || name == "codex" || name.hasPrefix("codex-")
    }

    /// A Codex INTERNAL helper process — `codex-code-mode-host` — spawned by every interactive Codex
    /// (one per session). Its `comm` starts with `codex-`, so the broad `codex-*` match above would
    /// otherwise (a) surface it as a phantom session row and (b) count it as a "1 agent" subagent of
    /// its own parent Codex. It is neither: exclude it from both discovery and ancestry. Prefix (not
    /// exact) match tolerates the 32-char `pbi_name` cap and any future `codex-code-mode-*` variant.
    static func isCodexHelper(_ comm: String) -> Bool {
        comm.lowercased().hasPrefix("codex-code-mode")
    }

    /// The `terminalHost` (a `TERM_PROGRAM`-style token, e.g. `apple_terminal`) for the tab-capable
    /// terminal app hosting `pid`, found by walking its ancestry — the analogue, for a Codex session
    /// discovered purely by process (no hook file), of the `terminalHost` a Claude hook records.
    /// Returns "" when no recognized terminal app is an ancestor. Pure over the process-table map.
    static func terminalHost(forPid pid: Int32, in table: [Int32: ProcessTableEntry]) -> String {
        var current = table[pid]?.ppid ?? 0
        var visited: Set<Int32> = [pid]
        var depth = 0
        while current > 1, depth < maxAncestryDepth, !visited.contains(current) {
            visited.insert(current)
            guard let entry = table[current] else { return "" }
            if let host = terminalHostForComm(entry.comm) { return host }
            current = entry.ppid
            depth += 1
        }
        return ""
    }

    /// Maps a terminal APP's `comm` to the `terminalHost` token `TerminalFocusPlanner` understands.
    /// Only the three tab-capable terminals (Terminal.app / iTerm2 / Ghostty) have a stable, clean
    /// process name; window-only terminals reach the shell through renamed helper processes, so we
    /// don't guess them here (they degrade to no focus, exactly as before).
    static func terminalHostForComm(_ comm: String) -> String? {
        switch comm.lowercased() {
        case "terminal": return "apple_terminal"
        case "iterm2": return "iterm.app"
        case "ghostty": return "ghostty"
        default: return nil
        }
    }

    /// A non-session owner — an ancestor that owns the process but is NOT a session: the app's own
    /// usage helper (`MyAgentsMac`) or ChatGPT.app. Case-insensitive, suffixes allowed
    /// (`ChatGPT Helper`, etc.). Hitting one of these means the process is an ORPHAN → hidden.
    static func isNonSessionOwner(_ comm: String) -> Bool {
        let name = comm.lowercased()
        return name.hasPrefix("myagentsmac") || name.hasPrefix("chatgpt")
    }

    /// Walks a discovered agent process's ancestry through the whole-table map to classify it.
    /// Pure: takes the synthetic-friendly `[pid: (ppid, comm)]` map, spawns nothing.
    ///
    /// The walk starts at the process's PARENT (its own comm is irrelevant — it's already known to
    /// be an agent) and climbs: the FIRST ancestor that is another agent wins as the parent session
    /// (`.subagent`); the first that is the app / ChatGPT wins as `.orphan`; anything else (shells,
    /// `login`, `Terminal`, unknown intermediates) is transparent and we keep climbing. Reaching the
    /// top (pid ≤ 1, an unknown/missing ancestor, the depth cap, or a cycle) with no owner found
    /// means it's a genuine `.interactive` session.
    ///
    /// `agentPids` is the set of pids already CLASSIFIED as agents by discovery (path/argv — the
    /// strong signals), used to recognize an ancestor whose `comm` alone gives it away: a modern
    /// Claude Code renames its process to its VERSION ("2.1.207"), so `isAgentComm` can't spot it in
    /// the table, and a `codex exec` subagent spawned by that Claude would otherwise climb straight
    /// past it to Terminal and be misread as a standalone INTERACTIVE session — a duplicate tile,
    /// with its own `codex-code-mode-host` counted as its "1 agent". Matching an ancestor by pid
    /// folds it into that Claude instead. Empty (the default) preserves the old comm-only behavior.
    static func classifyAncestry(pid: Int32, in table: [Int32: ProcessTableEntry], agentPids: Set<Int32> = []) -> ProcessAncestry {
        var current = table[pid]?.ppid ?? 0
        var visited: Set<Int32> = [pid]
        var depth = 0
        while current > 1, depth < maxAncestryDepth, !visited.contains(current) {
            visited.insert(current)
            guard let entry = table[current] else { return .interactive }
            if agentPids.contains(current) || isAgentComm(entry.comm) { return .subagent(parentPid: current) }
            if isNonSessionOwner(entry.comm) { return .orphan }
            current = entry.ppid
            depth += 1
        }
        return .interactive
    }

    // MARK: - Enumeration

    private static func pids() -> [pid_t] {
        let initialSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard initialSize > 0 else { return [] }
        // Ask for a bit more than the last-reported size: the process table can grow between the
        // sizing call and the fetch call.
        let capacity = Int(initialSize) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytesWritten = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytesWritten > 0 else { return [] }
        let count = Int(bytesWritten) / MemoryLayout<pid_t>.size
        return buffer.prefix(count).filter { $0 > 0 }
    }

    // MARK: - Classification

    private static func classify(pid: pid_t) -> DiscoveredProcess? {
        // ONE `PROC_PIDTBSDINFO` fetch gives BOTH the short name and the parent pid (energy law:
        // no second syscall for `ppid`).
        let bsd = bsdInfo(pid: pid)
        let shortName = bsd?.name ?? ""
        let ppid = bsd?.ppid ?? 0
        let tty = bsd.map { ttyPath(forDev: $0.tdev) } ?? ""
        let executablePath = executablePath(pid: pid) ?? ""
        let executableBase = (executablePath as NSString).lastPathComponent

        // `argv` is only NEEDED for the node/bun/deno-hosted case (and as belt-and-braces for a
        // Claude binary that renamed itself to its VERSION, e.g. "2.1.204"). Fetching it costs a
        // `KERN_PROCARGS2` sysctl per pid, and this runs over the WHOLE process table twice a
        // second — so we skip it for the vast majority of processes (energy law) and read it only
        // when the cheap name/path signals could plausibly be hiding a hosted or version-named CLI.
        let nameLooksVersioned = shortName.first?.isNumber ?? false
        let needsArguments = isScriptHost(executableBase) || isScriptHost(shortName) || nameLooksVersioned
        let arguments = needsArguments ? (processArguments(pid: pid) ?? []) : []

        guard let provider = provider(name: shortName, executablePath: executablePath, arguments: arguments) else {
            return nil
        }
        return DiscoveredProcess(pid: pid, provider: provider, cwd: cwd(pid: pid) ?? "", executablePath: executablePath, ppid: ppid, tty: tty)
    }

    private static func isScriptHost(_ name: String) -> Bool {
        ["node", "bun", "deno"].contains(name.lowercased())
    }

    /// Pure classifier — decides whether a process is a Claude Code / Codex CLI from its short name
    /// (`pbi_name`), resolved executable path, and argv. Kept `internal` + pure so the tricky
    /// real-world shapes are unit-tested WITHOUT spawning processes:
    ///  - Claude Code renames its own process to its VERSION ("2.1.204"), so `pbi_name` is useless
    ///    for a modern Claude install — it's recognised by its executable path
    ///    (`~/.local/share/claude/versions/<ver>`) or its `argv[0]` ("claude").
    ///  - Codex ships a native binary self-named "codex" / "codex-aarch64-apple-darwin".
    ///  - Either can run hosted by node/bun/deno (argv[0] = the runtime, the CLI is argv[1]).
    ///
    /// PRECISION is the whole point: an unrelated process that merely MENTIONS "codex"/"claude"
    /// somewhere in its argv or environment (an MCP server, a project folder named "claude-work")
    /// must NOT be misclassified — otherwise it becomes a phantom idle session row. So every rule
    /// keys off a strong, positional signal (exact name, a real `/claude/` path component, argv[0],
    /// or the script arg of a known runtime) — never a blanket substring scan of all of argv.
    static func provider(name: String, executablePath: String, arguments: [String]) -> Provider? {
        let shortName = name.lowercased()
        // 1) Exact process name. Codex self-names "codex[-arch]"; "claude" covers older installs
        //    and the test fixtures (a modern Claude renames itself to its version — caught below).
        if shortName == "codex" || (shortName.hasPrefix("codex-") && !isCodexHelper(shortName)) { return .codex }
        if shortName == "claude" { return .claude }

        // 2) Executable path with a REAL path component (not a loose substring): Claude lives at
        //    `…/claude/versions/<ver>`; a folder merely named "claude-501" won't match "/claude/".
        let path = executablePath.lowercased()
        let executableBase = (executablePath as NSString).lastPathComponent.lowercased()
        if executableBase == "codex" || (executableBase.hasPrefix("codex-") && !isCodexHelper(executableBase)) || path.contains("/codex/") { return .codex }
        if path.contains("/claude/") || path.contains("/.claude/") { return .claude }

        // 3) argv[0] basename — the exact CLI invocation (native install: argv0 = "claude"/"codex").
        let argv0 = (arguments.first.map { ($0 as NSString).lastPathComponent } ?? "").lowercased()
        if argv0 == "codex" || (argv0.hasPrefix("codex-") && !isCodexHelper(argv0)) { return .codex }
        if argv0 == "claude" { return .claude }

        // 4) node/bun/deno-hosted CLI: inspect ONLY the script argument (argv[1]) — NOT env or the
        //    rest of argv, which is where stray "codex"/"claude" substrings live.
        if isScriptHost(argv0) || isScriptHost(shortName), arguments.count >= 2 {
            let script = arguments[1].lowercased()
            if script.contains("codex") { return .codex }
            if script.contains("claude-code") || script.contains("@anthropic-ai/claude") || script.contains("/claude/") { return .claude }
        }
        return nil
    }

    // MARK: - Per-pid introspection (all best-effort: return nil on any failure)

    /// The short `comm` name AND parent pid from ONE `PROC_PIDTBSDINFO` fetch. Both callers
    /// (`classify` for discovery, `processTable` for the ancestry map) go through here, so `pbi_ppid`
    /// never costs a syscall of its own (energy law). `nil` on any failure (e.g. another user's
    /// process), which callers treat as name `""` / ppid `0`.
    private static func bsdInfo(pid: pid_t) -> (name: String, ppid: Int32, tdev: UInt32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = nulTerminatedCString(from: &info.pbi_name)
        return (name: name, ppid: Int32(bitPattern: info.pbi_ppid), tdev: info.e_tdev)
    }

    /// Maps a controlling-terminal device number (`e_tdev`) to its `/dev` path (`/dev/ttys005`) via
    /// `devname` — the reverse of what a terminal reports over AppleScript, so a Codex session can be
    /// matched to its exact tab by tty. Empty when the process has no controlling terminal (`e_tdev`
    /// is `NODEV`, all-ones) or `devname` yields nothing.
    private static func ttyPath(forDev dev: UInt32) -> String {
        guard dev != 0, dev != UInt32.max else { return "" }
        guard let cName = devname(dev_t(bitPattern: dev), mode_t(S_IFCHR)) else { return "" }
        let name = String(cString: cName)
        return name.isEmpty ? "" : "/dev/\(name)"
    }

    private static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN). The macro itself doesn't import into Swift
        // ("structure not supported" — verified while building this), so the literal is inlined.
        let maxSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: maxSize)
        let result = proc_pidpath(pid, &buffer, UInt32(maxSize))
        guard result > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private static func cwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = nulTerminatedCString(from: &info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Reads a fixed-size C char array/tuple (as Swift imports e.g. `pbi_name`/`vip_path`) as a
    /// NUL-terminated string, without a force-unwrap: `withUnsafeBytes(of:)` on a concrete stored
    /// value never actually produces a `nil` base address, but we don't assert that — an empty
    /// string is a safe, harmless fallback if it ever did.
    private static func nulTerminatedCString<T>(from value: inout T) -> String {
        withUnsafeBytes(of: &value) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= 4 else { return nil }

        // Layout (see `man 3 sysctl`, KERN_PROCARGS2): a leading Int32 argc, then the exec_path
        // NUL-terminated, then `argc` more NUL-terminated strings (argv).
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer[0..<4]) }

        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 } // skip exec_path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 } // skip the NULs after it

        var args: [String] = []
        var seen: Int32 = 0
        while offset < buffer.count, seen < argc {
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            args.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            while offset < buffer.count, buffer[offset] == 0 { offset += 1 }
            seen += 1
        }
        return args
    }
}
