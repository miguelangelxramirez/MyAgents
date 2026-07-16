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
    public var window: UsageWindow {
        switch self {
        case .claudeFiveHour, .codexFiveHour: return .fiveHour
        case .claudeSevenDay, .codexSevenDay: return .sevenDay
        }
    }

    /// The (percent, staleness) for this metric, picked from whichever provider applies. `percent`
    /// is `nil` when that window is unknown OR the provider doesn't expose it — the badge shows "—".
    public func reading(claude: UsageInfo, codex: UsageInfo) -> (percent: Double?, isStale: Bool) {
        let info = provider == .claude ? claude : codex
        return (info.percent(for: window), info.isStale)
    }
}

/// One of the two rolling rate-limit windows. Shared by the menu-bar metric picker and the popover
/// usage rows so "which window" is one type, not two parallel enums.
public enum UsageWindow: String, CaseIterable, Sendable {
    case fiveHour
    case sevenDay
}

public extension UsageInfo {
    /// This window's consumed percentage (`nil` when the provider gave no reading for it).
    func percent(for window: UsageWindow) -> Double? {
        switch window {
        case .fiveHour: return fiveHourPercent
        case .sevenDay: return sevenDayPercent
        }
    }

    /// This window's reset time (`nil` when unknown or the window isn't reported).
    func resetsAt(for window: UsageWindow) -> Date? {
        switch window {
        case .fiveHour: return fiveHourResetsAt
        case .sevenDay: return sevenDayResetsAt
        }
    }

    /// The windows this provider ACTUALLY reports, in display order (5 h before 7 d). A window the
    /// provider doesn't expose is omitted — e.g. Codex currently publishes only the 7-day limit, so
    /// its 5-hour row simply isn't drawn instead of showing an empty "—". It reappears on its own if
    /// the provider starts sending it again, and the same rule applies to Claude, so either provider
    /// adapts identically if their windows ever change (feedback 2026-07-16). Empty only when the
    /// provider has no reading at all (never fetched / source unreachable) — the UI then shows a
    /// single "—" placeholder rather than a bare, windowless block.
    var presentWindows: [UsageWindow] {
        UsageWindow.allCases.filter { percent(for: $0) != nil }
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
