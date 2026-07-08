import Foundation
import Combine

/// `ObservableObject` wrapper around `SessionScanner` + `ProcessLiveness` for SwiftUI consumption.
///
/// Hito 1: polls the session-file scan and the live process table a few times a second, joins
/// them (`SessionLivenessJoin`: a session is open iff its process is alive, dead sessions are
/// dropped, live processes with no session row become discovered idle rows), and publishes the
/// result attention-first (`SessionOrdering`). The scan + process discovery are genuinely blocking
/// I/O, so the poll loop always hops off the main actor to do that work (`Task.detached`) before
/// coming back to publish.
///
/// Each scanned session's row TITLE is also resolved here (`SessionDisplayName` +
/// `TranscriptTitle`) before publishing — never in the view. Resolving requires reading the
/// session's transcript file (`TranscriptTitle`), which is exactly the kind of blocking I/O that
/// must happen inside the same `Task.detached` hop as the scan, not on the main actor.
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []

    private let scanner: SessionScanner
    private let discoverProcesses: @Sendable () -> [ProcessLiveness.DiscoveredProcess]
    private let transcriptTitle: TranscriptTitle
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pollInterval: seconds between scans while `start()` is running. Default 0.5s — "a few
    ///     times a second", fast enough that a state change (e.g. permission requested) reaches
    ///     the menu bar glyph without a noticeable lag.
    ///   - discoverProcesses: injectable so tests can supply canned live processes instead of
    ///     scanning the real system process table.
    ///   - transcriptTitle: shared `TranscriptTitle` instance so its per-session cache survives
    ///     across polls instead of re-reading transcripts that already resolved a title.
    public init(
        scanner: SessionScanner = SessionScanner(),
        pollInterval: TimeInterval = 0.5,
        discoverProcesses: @escaping @Sendable () -> [ProcessLiveness.DiscoveredProcess] = { ProcessLiveness.discoverAgentProcesses() },
        transcriptTitle: TranscriptTitle = TranscriptTitle()
    ) {
        self.scanner = scanner
        self.pollInterval = pollInterval
        self.discoverProcesses = discoverProcesses
        self.transcriptTitle = transcriptTitle
    }

    /// One-shot synchronous scan+join+order on the calling thread/actor. Useful for previews and
    /// tests; the live app should prefer `start()` so this blocking work never runs on the main
    /// actor repeatedly.
    public func refresh() {
        let scanned = Self.resolvingDisplayNames(scanner.scanSessions(), transcriptTitle: transcriptTitle)
        apply(scanned: scanned, processes: discoverProcesses())
    }

    /// Starts the periodic poll loop off the main thread. A second call while already running is
    /// a no-op.
    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                let nanoseconds = UInt64(max(self.pollInterval, 0.05) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        let scanner = self.scanner
        let discoverProcesses = self.discoverProcesses
        let transcriptTitle = self.transcriptTitle
        let (scanned, processes) = await Task.detached {
            let raw = scanner.scanSessions()
            let resolved = Self.resolvingDisplayNames(raw, transcriptTitle: transcriptTitle)
            return (resolved, discoverProcesses())
        }.value
        apply(scanned: scanned, processes: processes)
    }

    /// Reads each session's transcript (if any) for its AI-authored title and resolves the final
    /// row title via `SessionDisplayName.resolve`. Static + only `Sendable` captures so this can
    /// run inside `Task.detached` without touching the main actor.
    nonisolated private static func resolvingDisplayNames(_ sessions: [Session], transcriptTitle: TranscriptTitle) -> [Session] {
        sessions.map { session in
            var resolved = session
            let aiTitle = transcriptTitle.title(sessionId: session.id, transcriptPath: session.transcript)
            resolved.displayName = SessionDisplayName.resolve(aiTitle: aiTitle, name: session.name, folder: session.folder)
            return resolved
        }
    }

    private func apply(scanned: [Session], processes: [ProcessLiveness.DiscoveredProcess]) {
        let joined = SessionLivenessJoin.join(sessions: scanned, liveProcesses: processes)
        // Discovered rows (a live process with no hook file at all) never went through
        // `resolvingDisplayNames` above — resolve them here too. No transcript to read for these
        // (there's no wire data at all), so this is a cheap, I/O-free fallback safe for the main
        // actor: `displayName` empty is the sentinel for "not resolved yet" (see `Session`).
        let withNames = joined.map { session -> Session in
            guard session.displayName.isEmpty else { return session }
            var resolved = session
            resolved.displayName = SessionDisplayName.resolve(aiTitle: nil, name: session.name, folder: session.folder)
            return resolved
        }
        sessions = SessionOrdering.attentionFirst(withNames)
    }
}
