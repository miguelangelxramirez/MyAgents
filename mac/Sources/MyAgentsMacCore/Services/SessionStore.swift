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
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []

    private let scanner: SessionScanner
    private let discoverProcesses: @Sendable () -> [ProcessLiveness.DiscoveredProcess]
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pollInterval: seconds between scans while `start()` is running. Default 0.5s — "a few
    ///     times a second", fast enough that a state change (e.g. permission requested) reaches
    ///     the menu bar glyph without a noticeable lag.
    ///   - discoverProcesses: injectable so tests can supply canned live processes instead of
    ///     scanning the real system process table.
    public init(
        scanner: SessionScanner = SessionScanner(),
        pollInterval: TimeInterval = 0.5,
        discoverProcesses: @escaping @Sendable () -> [ProcessLiveness.DiscoveredProcess] = { ProcessLiveness.discoverAgentProcesses() }
    ) {
        self.scanner = scanner
        self.pollInterval = pollInterval
        self.discoverProcesses = discoverProcesses
    }

    /// One-shot synchronous scan+join+order on the calling thread/actor. Useful for previews and
    /// tests; the live app should prefer `start()` so this blocking work never runs on the main
    /// actor repeatedly.
    public func refresh() {
        apply(scanned: scanner.scanSessions(), processes: discoverProcesses())
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
        let (scanned, processes) = await Task.detached {
            (scanner.scanSessions(), discoverProcesses())
        }.value
        apply(scanned: scanned, processes: processes)
    }

    private func apply(scanned: [Session], processes: [ProcessLiveness.DiscoveredProcess]) {
        let joined = SessionLivenessJoin.join(sessions: scanned, liveProcesses: processes)
        sessions = SessionOrdering.attentionFirst(joined)
    }
}
