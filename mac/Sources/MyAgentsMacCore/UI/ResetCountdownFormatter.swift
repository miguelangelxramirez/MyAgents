import Foundation

/// Formats the time remaining until a rate-limit window resets — the "resets in …" hint the usage
/// section shows next to each 5h/7d bar (user feedback, 2026-07-09: "no se ve cuándo se acaba").
///
/// Compact and total, mirroring `ElapsedTimeFormatter`'s discipline: a non-positive interval (the
/// window already reset, or clock skew put the reset time in the past) and a `nil` date both return
/// `nil` — the caller shows nothing rather than a stale "0m" or a negative countdown. Units shrink
/// with the magnitude so the string stays short in a tight column: "6d 3h", "2h 14m", "45m", "<1m".
public enum ResetCountdownFormatter {
    public static func format(_ interval: TimeInterval) -> String? {
        guard interval > 0 else { return nil }
        let total = Int(interval.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Convenience: time from `now` until `resetAt`, formatted. `nil` `resetAt` → `nil` (no reset
    /// time known for this window, e.g. a bucket the provider didn't report).
    public static func format(until resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        return format(resetAt.timeIntervalSince(now))
    }
}
