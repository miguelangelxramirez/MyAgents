import Foundation
import Combine

/// `ObservableObject` holding the latest Claude + Codex usage readings for SwiftUI consumption —
/// matches `SessionStore`'s shape (Hito 0 established `ObservableObject` + `@MainActor` as the
/// house style for Core stores).
///
/// Refreshes roughly once a minute, off the main thread (`Task.detached`, since both services do
/// blocking file/process I/O), and is resilient to transient failures: an `.unknown` reading NEVER
/// overwrites a previously known-good one — the UI keeps showing the last real percentage (greyed
/// via `isStale`, once the UI layer wires that up) instead of flashing "—" on every hiccup.
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var claude: UsageInfo
    @Published public private(set) var codex: UsageInfo

    private let claudeService: ClaudeUsageService
    private let codexService: CodexUsageService
    private let refreshInterval: TimeInterval
    /// How old a KEPT-because-the-refresh-failed reading may be before it's greyed out. A once-live
    /// value must not stay coloured fresh forever when its source goes down (Codex audit MED #5).
    private let stalenessThreshold: TimeInterval
    private var refreshTask: Task<Void, Never>?

    public init(
        claudeService: ClaudeUsageService = ClaudeUsageService(),
        codexService: CodexUsageService = CodexUsageService(),
        refreshInterval: TimeInterval = 60,
        stalenessThreshold: TimeInterval = 10 * 60
    ) {
        self.claudeService = claudeService
        self.codexService = codexService
        self.refreshInterval = refreshInterval
        self.stalenessThreshold = stalenessThreshold
        self.claude = .unknown(provider: .claude)
        self.codex = .unknown(provider: .codex)
    }

    /// Starts the periodic refresh loop off the main thread. A second call while already running
    /// is a no-op.
    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                let nanoseconds = UInt64(max(self.refreshInterval, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Fetches both providers (off the main thread) and updates published state resiliently.
    public func refreshOnce() async {
        let claudeService = self.claudeService
        let codexService = self.codexService
        async let newClaude = Task.detached { claudeService.fetch() }.value
        async let newCodex = Task.detached { await codexService.fetch() }.value
        let (claudeResult, codexResult) = await (newClaude, newCodex)
        // Publish only on a real change — assigning an `@Published` fires `objectWillChange` even
        // when the value is identical, which would re-render every usage bar (and the menu-bar
        // badge) on each refresh for nothing. Same contract as `SessionStore.apply`.
        let mergedClaude = Self.merge(newValue: claudeResult, keeping: claude, stalenessThreshold: stalenessThreshold)
        let mergedCodex = Self.merge(newValue: codexResult, keeping: codex, stalenessThreshold: stalenessThreshold)
        if mergedClaude != claude { claude = mergedClaude }
        if mergedCodex != codex { codex = mergedCodex }
    }

    /// A fresh reading with no data at all (a transient blip: file briefly missing, RPC timed
    /// out, …) never replaces a reading that DID have data — that's the "keep the last good
    /// value" resilience contract. Any reading with actual data (including a fresh, all-`nil`
    /// `.unknown` replacing a PRIOR `.unknown` — nothing lost either way) is applied normally.
    ///
    /// When we DO keep the previous reading, its staleness is re-derived from how long ago it was
    /// actually captured (`stalenessThreshold`): `isStale` is stored on the value, so without this a
    /// once-live percentage would keep painting fresh forever after its source went down (Codex
    /// audit MED #5). Keeping the value never drops its percentages — only greys them out.
    static func merge(newValue: UsageInfo, keeping current: UsageInfo, stalenessThreshold: TimeInterval, now: Date = Date()) -> UsageInfo {
        let newHasData = newValue.hasFiveHourReading || newValue.hasSevenDayReading
        let currentHasData = current.hasFiveHourReading || current.hasSevenDayReading
        if !newHasData && currentHasData {
            return current.markingStale(ifOlderThan: stalenessThreshold, now: now)
        }
        return newValue
    }
}
