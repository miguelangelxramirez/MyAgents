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

    /// Extracts a trustworthy 0...100 percentage from a value produced by `JSONSerialization`,
    /// or `nil` when it can't be trusted as a real reading. This is the single funnel every usage
    /// parser uses, so the "percentages are 0...100" invariant above is actually enforced.
    ///
    /// It rejects two things a bare `(raw as? NSNumber)?.doubleValue` accepts silently:
    /// - JSON booleans. `true`/`false` bridge to `NSNumber` as `CFBoolean`, so `"used_percent": false`
    ///   would read as `0.0` — a fabricated `0%`, the one value this type must never show (a real 0%
    ///   and "unknown" are different facts). Told apart by `CFTypeID`, not by `as? Bool` (which is
    ///   itself unreliable for `NSNumber`).
    /// - Non-finite or out-of-range numbers. `"used_percent": 1e100` is a finite JSON number that
    ///   later overflows `Int(percent.rounded())` and traps; `NaN`/`±inf`/negatives are meaningless.
    ///   Anything outside `0...100` is treated as corruption and rejected (shown as "—"), while a
    ///   genuine numeric `0` is preserved.
    public static func percent(from raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }

    /// Returns a copy flagged `isStale` when this reading's capture is older than `threshold`, or
    /// when it has no capture timestamp at all (an unknowable age can't be trusted as fresh). Used
    /// when a fresh fetch failed and the store keeps showing the last good percentages: they must
    /// grey out once they stop being refreshed instead of staying "live" forever (Codex audit MED
    /// #5). Staleness is ONE-WAY here — this never un-flags an already-stale reading, and never
    /// touches the percentages (a known reading is never dropped back to "—").
    public func markingStale(ifOlderThan threshold: TimeInterval, now: Date = Date()) -> UsageInfo {
        let aged = capturedAt.map { now.timeIntervalSince($0) > threshold } ?? true
        guard aged, !isStale else { return self }
        return UsageInfo(
            provider: provider,
            fiveHourPercent: fiveHourPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayPercent: sevenDayPercent,
            sevenDayResetsAt: sevenDayResetsAt,
            capturedAt: capturedAt,
            isStale: true
        )
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
