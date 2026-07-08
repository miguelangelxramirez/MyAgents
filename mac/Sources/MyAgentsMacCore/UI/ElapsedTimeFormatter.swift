import Foundation

/// Formats a busy session's elapsed run time for the discreet row timer.
///
/// Pure and total: clamps a negative interval (clock skew, a `startedAt` in the future) to zero
/// rather than emitting a garbage "-01:-3" string. Under an hour it's `mm:ss`; from an hour on it
/// gains the hours field (`h:mm:ss`) — seconds are kept even past the hour so a running timer
/// never looks frozen.
public enum ElapsedTimeFormatter {
    public static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Convenience: elapsed time from `start` to `now`, formatted. `nil` `start` → `nil` (no
    /// timer to show).
    public static func format(since start: Date?, now: Date = Date()) -> String? {
        guard let start else { return nil }
        return format(now.timeIntervalSince(start))
    }
}
