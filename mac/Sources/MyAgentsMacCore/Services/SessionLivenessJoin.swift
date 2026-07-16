import Foundation

/// Joins the session rows read from disk (`SessionScanner`) against the live process table
/// (`ProcessLiveness`) to decide which sessions are actually OPEN — the robust signal the Windows
/// reference uses (`src/MyAgents/Services/ProcessScanner.cs`: "a session is open iff its CLI
/// process is running"), which survives idle sessions and doesn't depend on a clean SessionEnd
/// hook firing (Codex has none).
///
/// Rules (pure function — `isAlive` is injected so this is directly testable without spinning up
/// real processes; production callers get the real check for free via the default):
/// - A session with a recorded `ownerPid` is OPEN iff `isAlive(ownerPid)` — a raw liveness check,
///   independent of `liveProcesses`. That list is filtered to processes NAMED/argv'd like
///   `claude`/`codex` (see `ProcessLiveness`), but a session's `ownerPid` came straight from the
///   hook that already knows it's a Claude/Codex process — it shouldn't need to also pass the
///   name heuristic to count as alive.
/// - A pid-less session is OPEN iff some entry in `liveProcesses` shares its provider +
///   (normalized) cwd — this is the ONLY use of the classified list for existing session rows.
/// - Any session that's neither is DEAD → removed from the result.
/// - A live process that matches no session row at all becomes a discovered idle row (the process
///   started before the app did, or its hook file hasn't landed yet).
///
/// Nesting (`processTable` non-empty): each live agent process is first classified by ancestry
/// (`ProcessLiveness.classifyAncestry`). Only INTERACTIVE processes go through the rules above.
/// A SUBAGENT process (a `codex exec` spawned by another session) never becomes a row — instead it
/// bumps its PARENT session's `subagentCount`, resolved by the parent's pid (a discovered/pid-ful
/// row) or, for pid-less Claude rows, by the parent process's own provider+cwd. An ORPHAN (owned by
/// the app itself or ChatGPT) is dropped entirely. With an EMPTY `processTable` every process
/// classifies as interactive, so the pre-nesting behavior is exactly preserved.
public enum SessionLivenessJoin {
    public static func join(
        sessions: [Session],
        liveProcesses: [ProcessLiveness.DiscoveredProcess],
        processTable: [Int32: ProcessLiveness.ProcessTableEntry] = [:],
        isAlive: (Int32) -> Bool = ProcessLiveness.isAlive
    ) -> [Session] {
        // Split the live processes by ancestry. Only interactive processes drive the open-session
        // match + discovered rows below; subagents fold into a parent, orphans vanish.
        var interactive: [ProcessLiveness.DiscoveredProcess] = []
        var subagents: [(process: ProcessLiveness.DiscoveredProcess, parentPid: Int32)] = []
        for process in liveProcesses {
            switch ProcessLiveness.classifyAncestry(pid: process.pid, in: processTable) {
            case .interactive: interactive.append(process)
            case .subagent(let parentPid): subagents.append((process, parentPid))
            case .orphan: break // a phantom (app / ChatGPT subagent) — hidden entirely
            }
        }
        let liveProcesses = interactive

        // Index the live processes by (provider, cwd) so an open session can ADOPT the tty of the
        // process it matched. A hook-sourced row (every Claude session, and any Codex that does have
        // a hook file) records no tty of its own — without this it's stuck with the fragile
        // custom-title heuristic even though its live process's EXACT tab is known. The result was
        // maddeningly inconsistent: a session whose agent `cd`'d into a subfolder no longer matched a
        // process by cwd, fell through to a bare process-DISCOVERED row (which DID carry the tty) and
        // opened fine; a session sitting in its original cwd stayed a hook row with no tty and failed
        // to open. Copying the tty here makes both focus by exact tab. First process per key wins.
        var processByKey: [String: ProcessLiveness.DiscoveredProcess] = [:]
        for process in liveProcesses where !process.cwd.isEmpty {
            let k = key(provider: process.provider, cwd: process.cwd)
            if processByKey[k] == nil { processByKey[k] = process }
        }

        let openSessions = sessions.compactMap { session -> Session? in
            if let ownerPid = session.ownerPid {
                return isAlive(ownerPid) ? session : nil
            }
            guard !session.cwd.isEmpty else { return nil }
            guard let process = processByKey[key(provider: session.provider, cwd: session.cwd)] else { return nil }
            guard session.tty.isEmpty, !process.tty.isEmpty else { return session }
            var enriched = session
            enriched.tty = process.tty
            return enriched
        }

        // Collapse the pid-less rows that share a folder down to the single freshest one. On macOS
        // the hooks can't record an owner pid (no `/proc` to walk — every session file lands with
        // `pid:0`), so a session is matched ONLY by provider+cwd. That means a stale orphan file —
        // left behind when a terminal tab was closed or the Mac shut down before `SessionEnd` could
        // fire and delete it — is resurrected by ANY later live session in the same folder, and the
        // row freezes on whatever state it last wrote (the reported "Awaiting permission" that isn't
        // asking anything: a dead sibling's frozen state, not the live session's). Keeping only the
        // newest file per (provider, cwd) drops those ghosts. Pid-ful rows are individually
        // identifiable, so they pass through untouched (a real two-sessions-in-one-folder case on a
        // platform that DOES record pids keeps both).
        let liveSessions = collapsePidlessDuplicatesPerFolder(openSessions)

        let claimedPids = Set(sessions.compactMap(\.ownerPid))
        let claimedKeys = Set(
            sessions.filter { $0.ownerPid == nil }.map { key(provider: $0.provider, cwd: $0.cwd) }
        )

        let discovered = liveProcesses
            .filter { process in
                !claimedPids.contains(process.pid) && !claimedKeys.contains(key(provider: process.provider, cwd: process.cwd))
            }
            .map { process in
                Session(
                    id: "process-\(process.pid)",
                    folder: URL(fileURLWithPath: process.cwd.isEmpty ? "/" : process.cwd).lastPathComponent,
                    cwd: process.cwd,
                    provider: process.provider,
                    // Discovered purely as a live process (no hook file): we know it's alive, not its
                    // exact activity — `.active`, never a hook-reported `.idle`. `terminalHost`/`tty`
                    // come from the process itself so click-to-focus can still find its terminal tab.
                    state: .active,
                    ownerPid: process.pid,
                    terminalHost: ProcessLiveness.terminalHost(forPid: process.pid, in: processTable),
                    tty: process.tty
                )
            }

        return applyingSubagentCounts(to: liveSessions + discovered, subagents: subagents, interactive: interactive)
    }

    /// Folds each subagent process into its parent session's `subagentCount`, without adding any
    /// row for the subagent itself. A subagent resolves to a parent row by, in order:
    ///  1. `ownerPid == parentPid` — the parent is a pid-ful / discovered row (a Codex session, or
    ///     any process-discovered row).
    ///  2. the parent PROCESS's own (provider, cwd) matching a PID-LESS row's key — the macOS-Claude
    ///     case, where hooks can't record a pid so the parent session row has `ownerPid == nil` and
    ///     is matched by provider+cwd (the parent process is looked up in `interactive` by pid).
    /// A subagent whose parent resolves to neither is dropped (counted nowhere) — same fate as an
    /// orphan: better to hide a phantom than to attach it to the wrong session.
    private static func applyingSubagentCounts(
        to rows: [Session],
        subagents: [(process: ProcessLiveness.DiscoveredProcess, parentPid: Int32)],
        interactive: [ProcessLiveness.DiscoveredProcess]
    ) -> [Session] {
        guard !subagents.isEmpty else { return rows }

        var indexByOwnerPid: [Int32: Int] = [:]
        var indexByKey: [String: Int] = [:]
        for (i, row) in rows.enumerated() {
            if let pid = row.ownerPid {
                indexByOwnerPid[pid] = i
            } else {
                indexByKey[key(provider: row.provider, cwd: row.cwd)] = i
            }
        }
        let processByPid = Dictionary(interactive.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var rows = rows
        for (_, parentPid) in subagents {
            if let i = indexByOwnerPid[parentPid] {
                rows[i].subagentCount += 1
            } else if let parent = processByPid[parentPid],
                      let i = indexByKey[key(provider: parent.provider, cwd: parent.cwd)] {
                rows[i].subagentCount += 1
            }
            // else: parent isn't a visible row → drop the subagent (count it nowhere).
        }
        return rows
    }

    /// Keeps every pid-ful session, but for pid-less ones sharing a (provider, cwd) key keeps only
    /// the one with the newest `updatedAt` (a session with a timestamp always beats one without;
    /// two without keep the first seen). This is what stops a folder's stale orphan files from
    /// multiplying its live session into several frozen ghost rows.
    private static func collapsePidlessDuplicatesPerFolder(_ sessions: [Session]) -> [Session] {
        var pidful: [Session] = []
        var newestPidlessByKey: [String: Session] = [:]
        for session in sessions {
            guard session.ownerPid == nil else { pidful.append(session); continue }
            let k = key(provider: session.provider, cwd: session.cwd)
            if let existing = newestPidlessByKey[k], !isNewer(session, than: existing) { continue }
            newestPidlessByKey[k] = session
        }
        return pidful + Array(newestPidlessByKey.values)
    }

    /// Is `a` a fresher session file than `b`? A recorded `updatedAt` always wins over a missing
    /// one; between two recorded times the later wins; two missing times are treated as equal (so
    /// the incumbent is kept — the loop above only replaces on a strict win).
    private static func isNewer(_ a: Session, than b: Session) -> Bool {
        switch (a.updatedAt, b.updatedAt) {
        case let (lhs?, rhs?): return lhs > rhs
        case (.some, nil): return true
        case (nil, _): return false
        }
    }

    private static func key(provider: Provider, cwd: String) -> String {
        provider.rawValue + "|" + normalize(cwd)
    }

    private static func normalize(_ cwd: String) -> String {
        var path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
