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
    /// How long to coalesce a burst of file-system events before rescanning. An agent working writes
    /// its state file several times in quick succession; without this every write would trigger its
    /// own scan.
    private let coalesceInterval: TimeInterval
    /// The safety net, and the ONLY thing here that still ticks.
    ///
    /// Everything the app needs is delivered by the watchers — but a watcher can miss an event
    /// (FSEvents is explicitly allowed to drop events and demand a rescan), a directory can be
    /// created after we failed to watch it, and a process can DIE WITHOUT ANY FILE CHANGING: a
    /// terminal killed outright never fires `SessionEnd`, so its session file just sits there and
    /// only the process table knows it's gone.
    ///
    /// That last case is why this beat isn't minutes. A `DispatchSourceProcess(.exit)` watch per
    /// agent would catch it instantly, and that was tried — but `makeProcessSource` on a pid that has
    /// already exited crashes libdispatch, and the pid we'd hand it always comes from a scan that
    /// happened microseconds earlier. A crash in the user's menu bar is a far worse bug than a stale
    /// row for a few seconds, so: no process watchers, and a beat short enough not to be noticed. One
    /// scan now costs ~1 ms, so 5 s is still, in effect, nothing.
    private let reconcileInterval: TimeInterval
    private var reconcileTask: Task<Void, Never>?
    private var coalesceTask: Task<Void, Never>?
    private var sessionsWatcher: DirectoryWatcher?
    private var rolloutsWatcher: FileTreeWatcher?
    /// When the stale-file reap last ran. It's disk hygiene, so it runs on a wall-clock beat rather
    /// than once every N scans — scans are event-driven now, and their rate says nothing about how
    /// long orphan files have been sitting there.
    private var lastReapAt: Date?
    private let reapInterval: TimeInterval = 30 * 60
    /// A session file untouched for longer than this is considered abandoned and reaped. Generous
    /// on purpose: the per-folder dedup already hides ghosts from the live list, so this only has to
    /// stop the directory growing — 24h never reaps a session you're realistically still in.
    private let staleFileThreshold: TimeInterval = 24 * 60 * 60
    /// In-memory "finished-but-unopened" state, folded into every published list. Owned here (not
    /// in the scanner) because it's derived from what the app watched happen across polls, not from
    /// disk. See `PendingTracker`.
    private var pendingTracker = PendingTracker()

    /// - Parameters:
    ///   - coalesceInterval: how long a burst of file-system events is collapsed before rescanning.
    ///   - reconcileInterval: the slow safety-net rescan (see `reconcileInterval`).
    ///   - discoverProcesses: injectable so tests can supply canned live processes instead of
    ///     scanning the real system process table.
    ///   - transcriptTitle: shared `TranscriptTitle` instance so its per-session cache survives
    ///     across scans instead of re-reading transcripts that already resolved a title.
    ///   - codexSessionScanner: shared `CodexSessionScanner` instance so its name-by-cwd cache
    ///     survives across scans (a Codex rollout that goes idle can still resolve a name from an
    ///     earlier scan). Tests MUST inject one pointed at a temp directory — the default reads
    ///     the real `~/.codex/sessions`.
    public init(
        scanner: SessionScanner = SessionScanner(),
        coalesceInterval: TimeInterval = 0.08,
        reconcileInterval: TimeInterval = 5,
        discoverProcesses: @escaping @Sendable () -> [ProcessLiveness.DiscoveredProcess] = { ProcessLiveness.discoverAgentProcesses() },
        transcriptTitle: TranscriptTitle = TranscriptTitle(),
        codexSessionScanner: CodexSessionScanner = CodexSessionScanner()
    ) {
        self.scanner = scanner
        self.coalesceInterval = coalesceInterval
        self.reconcileInterval = reconcileInterval
        self.discoverProcesses = discoverProcesses
        self.transcriptTitle = transcriptTitle
        self.codexSessionScanner = codexSessionScanner
    }

    /// One-shot synchronous scan+join+order on the calling thread/actor. Useful for previews, tests,
    /// and the moment the popover opens; the live app is otherwise driven by `start()`.
    public func refresh() {
        codexSessionScanner.scanRecentSessions()
        let scanned = Self.resolvingDisplayNames(scanner.scanSessions(), transcriptTitle: transcriptTitle, codexSessionScanner: codexSessionScanner)
        apply(scanned: scanned, processes: discoverProcesses())
    }

    /// Starts watching. NOT a poll loop.
    ///
    /// The app used to rescan everything twice a second forever — waking the CPU 2×/s with no agent
    /// even running. Nothing here is periodic by nature: a session changes when a hook WRITES A FILE.
    /// So we watch the two places that can change (`sessions.d` for Claude, the rollout tree for
    /// Codex) and otherwise do nothing at all, except for the slow `reconcileInterval` safety net.
    ///
    /// A second call while already running is a no-op.
    public func start() {
        guard reconcileTask == nil else { return }

        refresh()

        let sessionsWatcher = DirectoryWatcher(url: scanner.directoryURL) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRescan() }
        }
        sessionsWatcher.start()
        self.sessionsWatcher = sessionsWatcher

        let rolloutsWatcher = FileTreeWatcher(root: codexSessionScanner.sessionsRoot) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRescan() }
        }
        rolloutsWatcher.start()
        self.rolloutsWatcher = rolloutsWatcher

        reconcileTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let seconds = await self.reconcileInterval
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.pollOnce()
            }
        }
    }

    public func stop() {
        reconcileTask?.cancel()
        reconcileTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        sessionsWatcher?.stop()
        sessionsWatcher = nil
        rolloutsWatcher?.stop()
        rolloutsWatcher = nil
    }

    /// Something on disk moved. Collapse the burst, then rescan once.
    private func scheduleRescan() {
        coalesceTask?.cancel()
        let seconds = coalesceInterval
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.01) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.pollOnce()
        }
    }


    private func pollOnce() async {
        let scanner = self.scanner
        let discoverProcesses = self.discoverProcesses
        let transcriptTitle = self.transcriptTitle
        let codexSessionScanner = self.codexSessionScanner
        // Disk hygiene is time-based, not scan-based: rescans are now event-driven, so counting them
        // would reap at a rate that depends on how busy your agents are.
        let now = Date()
        let shouldReap = lastReapAt.map { now.timeIntervalSince($0) >= reapInterval } ?? true
        if shouldReap { lastReapAt = now }
        let staleFileThreshold = self.staleFileThreshold
        let (scanned, processes) = await Task.detached {
            // Off-main: drop long-abandoned orphan files before this scan so they neither reach the
            // join nor keep piling up (see `SessionScanner.reapStaleFiles`).
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
        let ordered = SessionOrdering.attentionFirst(withPending)

        // Publish ONLY on a real change. `sessions` is `@Published`, so assigning it fires
        // `objectWillChange` whether or not the value differs — and this runs twice a second,
        // forever. Re-publishing an identical list made SwiftUI re-evaluate and re-lay-out the menu
        // bar item continuously even with the popover closed and nothing happening
        // (`NSHostingView.layout`: 794 of 8078 samples in the idle profile, 2026-07-12).
        guard ordered != sessions else { return }
        sessions = ordered
    }

    /// Marks a session as opened (the row was clicked) — clears its pending dot immediately, without
    /// waiting for the next poll. The dot re-arms if the session goes busy again (see
    /// `PendingTracker`).
    public func markSeen(_ id: String) {
        pendingTracker.markSeen(id)
        sessions = pendingTracker.apply(to: sessions)
    }
}
