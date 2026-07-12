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
public enum SessionLivenessJoin {
    public static func join(
        sessions: [Session],
        liveProcesses: [ProcessLiveness.DiscoveredProcess],
        isAlive: (Int32) -> Bool = ProcessLiveness.isAlive
    ) -> [Session] {
        let liveKeys = Set(liveProcesses.map { key(provider: $0.provider, cwd: $0.cwd) })

        let openSessions = sessions.filter { session in
            if let ownerPid = session.ownerPid {
                return isAlive(ownerPid)
            }
            guard !session.cwd.isEmpty else { return false }
            return liveKeys.contains(key(provider: session.provider, cwd: session.cwd))
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
                    state: .idle,
                    ownerPid: process.pid
                )
            }

        return liveSessions + discovered
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
