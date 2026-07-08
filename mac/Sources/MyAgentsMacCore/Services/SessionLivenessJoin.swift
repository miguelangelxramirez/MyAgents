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

        return openSessions + discovered
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
