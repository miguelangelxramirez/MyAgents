import Foundation

/// Severity of a usage-bar reading — decides whether the bar keeps its provider accent or shifts
/// to the warning/high colour as the window fills. Pure so the thresholds are pinned by tests
/// (a design decision that must not drift silently).
///
/// `percent` is percent *consumed* (0 = fresh window, 100 = capped), matching `UsageInfo`.
public enum UsageLevel: Equatable, Sendable {
    /// Comfortably inside the window — bar stays provider-coloured.
    case normal
    /// Getting close to the cap — amber.
    case warn
    /// Nearly/at the cap — red.
    case high

    /// Default thresholds: warn from 75 % consumed, high from 90 %. Kept as parameters so a test
    /// can prove the boundaries are inclusive and ordered, not magic numbers scattered in a view.
    public static func forPercent(_ percent: Double, warnAt: Double = 75, highAt: Double = 90) -> UsageLevel {
        if percent >= highAt { return .high }
        if percent >= warnAt { return .warn }
        return .normal
    }
}

/// Which single usage percentage the menu-bar glyph shows next to it. Miguel replaced the two mini
/// usage bars ("los dos puntos") with ONE chosen number and a setting to pick which one (feedback
/// 2026-07-09). The choice is persisted in `AppPreferences`; this enum is the pure, testable
/// mapping from that choice to the value to read out of the two providers' `UsageInfo`.
public enum MenuBarUsageMetric: String, CaseIterable, Sendable {
    case claudeFiveHour
    case claudeSevenDay
    case codexFiveHour
    case codexSevenDay

    /// Default matches the old badge's most prominent bar — Claude's 5-hour window.
    public static let `default`: MenuBarUsageMetric = .claudeFiveHour

    /// Which provider's reading this metric comes from (also drives the badge's accent colour).
    public var provider: Provider {
        switch self {
        case .claudeFiveHour, .claudeSevenDay: return .claude
        case .codexFiveHour, .codexSevenDay: return .codex
        }
    }

    /// Which rolling window this metric reads.
    public var window: Window {
        switch self {
        case .claudeFiveHour, .codexFiveHour: return .fiveHour
        case .claudeSevenDay, .codexSevenDay: return .sevenDay
        }
    }

    public enum Window: Sendable {
        case fiveHour
        case sevenDay
    }

    /// The (percent, staleness) for this metric, picked from whichever provider applies. `percent`
    /// is `nil` when that window is unknown — the UI shows "—", never a fabricated 0%.
    public func reading(claude: UsageInfo, codex: UsageInfo) -> (percent: Double?, isStale: Bool) {
        let info = provider == .claude ? claude : codex
        switch window {
        case .fiveHour: return (info.fiveHourPercent, info.isStale)
        case .sevenDay: return (info.sevenDayPercent, info.isStale)
        }
    }
}

/// Age of a stale usage reading, in whole minutes — the number the UI renders as "hace N min".
/// Pure so the "N" is deterministic and tested; localisation of the surrounding text lives in the
/// view. Clamps to 0 (never a negative age from a capture timestamp slightly in the future).
public enum UsageAge {
    public static func minutes(since capturedAt: Date?, now: Date = Date()) -> Int? {
        guard let capturedAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(capturedAt))
        return Int(seconds / 60)
    }
}
