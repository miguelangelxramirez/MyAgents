import Foundation

/// Usage-limit snapshot for one provider's 5-hour and 7-day rate-limit windows
/// (Claude's statusline `rate_limits`, Codex's `app-server` RPC `account/rateLimits/read` —
/// see `src/MyAgents/Models/UsageInfo.cs` and CONTEXT.md §6 for the reused contracts).
///
/// Every percentage/date is `Optional`. `nil` means "genuinely unknown right now" (no
/// statusline capture yet, RPC unreachable, session idle too long, …) and MUST be rendered by
/// the UI as "—", never as a fabricated `0%` — a real 0% and "we don't know" are different facts.
public struct UsageInfo: Equatable, Sendable {
    public let provider: Provider

    /// 0...100, the rolling 5-hour window. `nil` when unknown.
    public let fiveHourPercent: Double?
    public let fiveHourResetsAt: Date?

    /// 0...100, the rolling 7-day window. `nil` when unknown.
    public let sevenDayPercent: Double?
    public let sevenDayResetsAt: Date?

    /// When this reading was captured. `nil` for a live source (direct RPC) or when unknown.
    public let capturedAt: Date?

    /// `true` when this reading is old enough that the UI should show it "greyed out, N minutes
    /// ago" instead of as fresh (mirrors the Windows tray's stale-usage treatment — see
    /// `ClaudeUsageService`/`CodexUsageService`). The percentages themselves are still the last
    /// real values: staleness NEVER drops a known reading back to "—". Always `false` for a value
    /// with no meaningful age (e.g. `.unknown`, or a just-fetched live RPC reading).
    public let isStale: Bool

    public init(
        provider: Provider,
        fiveHourPercent: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        sevenDayPercent: Double? = nil,
        sevenDayResetsAt: Date? = nil,
        capturedAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.provider = provider
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPercent = sevenDayPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.capturedAt = capturedAt
        self.isStale = isStale
    }

    /// The canonical "we have no reading yet" value — every field `nil`, never `0`.
    public static func unknown(provider: Provider) -> UsageInfo {
        UsageInfo(provider: provider)
    }

    public var hasFiveHourReading: Bool { fiveHourPercent != nil }
    public var hasSevenDayReading: Bool { sevenDayPercent != nil }

    public var fiveHourResetCountdown: TimeInterval? {
        fiveHourResetsAt?.timeIntervalSinceNow
    }

    public var sevenDayResetCountdown: TimeInterval? {
        sevenDayResetsAt?.timeIntervalSinceNow
    }
}
