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

        public init(pid: Int32, provider: Provider, cwd: String, executablePath: String) {
            self.pid = pid
            self.provider = provider
            self.cwd = cwd
            self.executablePath = executablePath
        }
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
        let shortName = processName(pid: pid) ?? ""
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
        return DiscoveredProcess(pid: pid, provider: provider, cwd: cwd(pid: pid) ?? "", executablePath: executablePath)
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
        if shortName == "codex" || shortName.hasPrefix("codex-") { return .codex }
        if shortName == "claude" { return .claude }

        // 2) Executable path with a REAL path component (not a loose substring): Claude lives at
        //    `…/claude/versions/<ver>`; a folder merely named "claude-501" won't match "/claude/".
        let path = executablePath.lowercased()
        let executableBase = (executablePath as NSString).lastPathComponent.lowercased()
        if executableBase == "codex" || executableBase.hasPrefix("codex-") || path.contains("/codex/") { return .codex }
        if path.contains("/claude/") || path.contains("/.claude/") { return .claude }

        // 3) argv[0] basename — the exact CLI invocation (native install: argv0 = "claude"/"codex").
        let argv0 = (arguments.first.map { ($0 as NSString).lastPathComponent } ?? "").lowercased()
        if argv0 == "codex" || argv0.hasPrefix("codex-") { return .codex }
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

    private static func processName(pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return nulTerminatedCString(from: &info.pbi_name)
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
