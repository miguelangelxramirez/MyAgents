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
    /// Enriches Codex rows (name, and best-effort state) from Codex's own rollout transcripts —
    /// Codex has no reliable hook mechanism on macOS, so without this a Codex session only ever
    /// shows up as a bare `ProcessLiveness`-discovered row (folder only). See `CodexSessionScanner`.
    private let codexSessionScanner: CodexSessionScanner
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    /// Counts polls so the stale-file reap runs on the first poll and then only occasionally (it's
    /// disk hygiene, not per-frame work — see `reapEveryPolls`).
    private var pollCount = 0
    /// Reap once every this many polls. At the default 0.5s interval that's ~every 60s — often
    /// enough to keep `sessions.d/` from accumulating orphans, rare enough to be negligible I/O.
    private let reapEveryPolls = 120
    /// A session file untouched for longer than this is considered abandoned and reaped. Generous
    /// on purpose: the per-folder dedup already hides ghosts from the live list, so this only has to
    /// stop the directory growing — 24h never reaps a session you're realistically still in.
    private let staleFileThreshold: TimeInterval = 24 * 60 * 60
    /// In-memory "finished-but-unopened" state, folded into every published list. Owned here (not
    /// in the scanner) because it's derived from what the app watched happen across polls, not from
    /// disk. See `PendingTracker`.
    private var pendingTracker = PendingTracker()

    /// - Parameters:
    ///   - pollInterval: seconds between scans while `start()` is running. Default 0.5s — "a few
    ///     times a second", fast enough that a state change (e.g. permission requested) reaches
    ///     the menu bar glyph without a noticeable lag.
    ///   - discoverProcesses: injectable so tests can supply canned live processes instead of
    ///     scanning the real system process table.
    ///   - transcriptTitle: shared `TranscriptTitle` instance so its per-session cache survives
    ///     across polls instead of re-reading transcripts that already resolved a title.
    ///   - codexSessionScanner: shared `CodexSessionScanner` instance so its name-by-cwd cache
    ///     survives across polls (a Codex rollout that goes idle can still resolve a name from an
    ///     earlier scan). Tests MUST inject one pointed at a temp directory — the default reads
    ///     the real `~/.codex/sessions`.
    public init(
        scanner: SessionScanner = SessionScanner(),
        pollInterval: TimeInterval = 0.5,
        discoverProcesses: @escaping @Sendable () -> [ProcessLiveness.DiscoveredProcess] = { ProcessLiveness.discoverAgentProcesses() },
        transcriptTitle: TranscriptTitle = TranscriptTitle(),
        codexSessionScanner: CodexSessionScanner = CodexSessionScanner()
    ) {
        self.scanner = scanner
        self.pollInterval = pollInterval
        self.discoverProcesses = discoverProcesses
        self.transcriptTitle = transcriptTitle
        self.codexSessionScanner = codexSessionScanner
    }

    /// One-shot synchronous scan+join+order on the calling thread/actor. Useful for previews and
    /// tests; the live app should prefer `start()` so this blocking work never runs on the main
    /// actor repeatedly.
    public func refresh() {
        codexSessionScanner.scanRecentSessions()
        let scanned = Self.resolvingDisplayNames(scanner.scanSessions(), transcriptTitle: transcriptTitle, codexSessionScanner: codexSessionScanner)
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
        let codexSessionScanner = self.codexSessionScanner
        let shouldReap = pollCount % reapEveryPolls == 0
        let staleFileThreshold = self.staleFileThreshold
        pollCount += 1
        let (scanned, processes) = await Task.detached {
            // Disk hygiene, off-main: drop long-abandoned orphan files before this poll's scan so
            // they neither reach the join nor keep piling up (see `SessionScanner.reapStaleFiles`).
            if shouldReap { scanner.reapStaleFiles(olderThan: staleFileThreshold) }
            // Off-main: reads Codex's rollout files to (re)populate the name/state caches BEFORE
            // resolving display names below, so both the hook-based path here and the
            // discovered-row path in `apply()` see this poll's data.
            codexSessionScanner.scanRecentSessions()
            let raw = scanner.scanSessions()
            let resolved = Self.resolvingDisplayNames(raw, transcriptTitle: transcriptTitle, codexSessionScanner: codexSessionScanner)
            return (resolved, discoverProcesses())
        }.value
        apply(scanned: scanned, processes: processes)
    }

    /// Reads each session's transcript (if any) for its AI-authored title, enriches a nameless
    /// Codex session's `name` from its rollout (see `codexName(for:codexSessionScanner:)`), and
    /// resolves the final row title via `SessionDisplayName.resolve`. Static + only `Sendable`
    /// captures so this can run inside `Task.detached` without touching the main actor.
    nonisolated private static func resolvingDisplayNames(_ sessions: [Session], transcriptTitle: TranscriptTitle, codexSessionScanner: CodexSessionScanner) -> [Session] {
        sessions.map { session in
            var resolved = session
            let aiTitle = transcriptTitle.title(sessionId: session.id, transcriptPath: session.transcript)
            let name = codexName(for: session, codexSessionScanner: codexSessionScanner)
            resolved.name = name
            resolved.displayName = SessionDisplayName.resolve(aiTitle: aiTitle, name: name, folder: session.folder)
            return resolved
        }
    }

    /// `session.name` as-is, UNLESS this is a Codex session with no name at all — in which case
    /// this looks up a rollout-derived name for its cwd (`CodexSessionScanner.name(forCwd:)`,
    /// which itself returns `nil` rather than guess when the cwd is ambiguous — see
    /// `CodexNameCache`). Claude sessions are never touched here: their name always comes from the
    /// hook file / transcript ai-title, exactly as before this enrichment existed.
    nonisolated private static func codexName(for session: Session, codexSessionScanner: CodexSessionScanner) -> String {
        guard session.provider == .codex else { return session.name }
        guard session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return session.name }
        return codexSessionScanner.name(forCwd: session.cwd) ?? session.name
    }

    private func apply(scanned: [Session], processes: [ProcessLiveness.DiscoveredProcess]) {
        let joined = SessionLivenessJoin.join(sessions: scanned, liveProcesses: processes)
        // Discovered rows (a live process with no hook file at all) never went through
        // `resolvingDisplayNames` above — resolve them here too. For a Codex discovered row, also
        // pull in this poll's rollout-derived state/label/timing (`latestSession(forCwd:)`) before
        // resolving the name/title — both lookups are cheap in-memory cache reads at this point
        // (the actual rollout I/O already ran inside the `Task.detached` hop above / before
        // `apply()` is called from `refresh()`), so this stays safe on the main actor.
        let withNames = joined.map { session -> Session in
            guard session.displayName.isEmpty else { return session }
            var resolved = session
            if resolved.provider == .codex, let rollout = codexSessionScanner.latestSession(forCwd: resolved.cwd) {
                resolved.state = rollout.state
                resolved.toolLabel = rollout.label
                if let startedAt = rollout.startedAt { resolved.startedAt = startedAt }
                if let updatedAt = rollout.updatedAt { resolved.updatedAt = updatedAt }
            }
            let name = Self.codexName(for: resolved, codexSessionScanner: codexSessionScanner)
            resolved.name = name
            resolved.displayName = SessionDisplayName.resolve(aiTitle: nil, name: name, folder: session.folder)
            return resolved
        }
        // Compute the pending dot from watched busy→finished transitions, then order attention-first
        // (pending doesn't affect ordering, so either order works; this keeps the tracker's view of
        // "current sessions" in sync with what we publish).
        let withPending = pendingTracker.apply(to: withNames)
        sessions = SessionOrdering.attentionFirst(withPending)
    }

    /// Marks a session as opened (the row was clicked) — clears its pending dot immediately, without
    /// waiting for the next poll. The dot re-arms if the session goes busy again (see
    /// `PendingTracker`).
    public func markSeen(_ id: String) {
        pendingTracker.markSeen(id)
        sessions = pendingTracker.apply(to: sessions)
    }
}
