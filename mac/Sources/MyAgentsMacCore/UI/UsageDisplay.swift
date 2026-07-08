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
