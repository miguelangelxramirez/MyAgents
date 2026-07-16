import Foundation
import os

/// Reads Claude's 5-hour/7-day rate-limit usage from `~/.claude/statusbar/usage.json` — the file
/// `hooks/statusline.js` writes on every statusline render from Claude Code's OFFICIAL
/// `rate_limits` payload (see `src/MyAgents/Services/UsageService.cs`). No token, no network: this
/// is a local file read of a capture Claude Code itself already produces.
///
/// Wire schema (written by `statusline.js`, camelCase-free — snake_case matches the JS emitter):
/// ```json
/// { "provider": "claude", "source": "statusline",
///   "five_hour": { "used_percent": 42.0, "reset_at": 1719400000 },
///   "seven_day":  { "used_percent": 10.0, "reset_at": 1719900000 },
///   "ts": 1719400042 }
/// ```
/// Either bucket may be `null` (absent right after `/clear`, or on non-Pro/Max plans).
///
/// Defensive by construction (METODOLOGIA §4): a missing file, a file that isn't valid JSON, or a
/// JSON document with neither bucket present all return `.unknown(provider: .claude)` — NEVER a
/// fabricated `0%`. A capture that's aged past `stalenessThreshold` is still returned (its
/// percentages are the last real values) but flagged `isStale` so the UI can grey it out with
/// "N minutes ago", mirroring the Windows tray's stale-usage treatment.
public struct ClaudeUsageService: Sendable {
    private let fileURL: URL
    private let stalenessThreshold: TimeInterval
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "ClaudeUsageService")

    /// Production location of the statusline's capture. Tests inject a temp file instead — never
    /// hit the real `~/.claude` from a unit test.
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("statusbar", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
    }

    /// - Parameter stalenessThreshold: how old (in seconds) `ts` may be before the reading is
    ///   flagged `isStale`. Default 10 minutes: Claude Code re-renders the statusline on basically
    ///   every turn while a session is open, so a gap this long means either no session is active
    ///   right now or the capture stopped updating.
    public init(fileURL: URL = ClaudeUsageService.defaultFileURL, stalenessThreshold: TimeInterval = 10 * 60) {
        self.fileURL = fileURL
        self.stalenessThreshold = stalenessThreshold
    }

    /// Synchronous file read + parse — callers running on the main actor must hop off it first
    /// (see `UsageStore`), this type does no threading of its own.
    public func fetch() -> UsageInfo {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return .unknown(provider: .claude)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Malformed usage.json at \(fileURL.path, privacy: .public)")
            return .unknown(provider: .claude)
        }

        let fiveHour = bucket(from: object["five_hour"])
        let sevenDay = bucket(from: object["seven_day"])
        guard fiveHour != nil || sevenDay != nil else {
            logger.warning("usage.json has neither five_hour nor seven_day — treating as unknown")
            return .unknown(provider: .claude)
        }

        let capturedAt = (object["ts"] as? NSNumber).flatMap { number -> Date? in
            let seconds = number.int64Value
            return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        }
        // A reading with valid buckets but NO capture timestamp (absent/zero `ts`) has an unknowable
        // age, so it can't be trusted as fresh — it's stale, not fresh (Codex audit MED #5). Only a
        // `ts` we can actually compare keeps a reading live while it's under the threshold.
        let isStale = capturedAt.map { Date().timeIntervalSince($0) > stalenessThreshold } ?? true

        return UsageInfo(
            provider: .claude,
            fiveHourPercent: fiveHour?.percent,
            fiveHourResetsAt: fiveHour?.resetAt,
            sevenDayPercent: sevenDay?.percent,
            sevenDayResetsAt: sevenDay?.resetAt,
            capturedAt: capturedAt,
            isStale: isStale
        )
    }

    private func bucket(from raw: Any?) -> (percent: Double, resetAt: Date?)? {
        guard let dict = raw as? [String: Any], let percent = UsageInfo.percent(from: dict["used_percent"]) else {
            return nil
        }
        let resetSeconds = (dict["reset_at"] as? NSNumber)?.int64Value ?? 0
        let resetAt = resetSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(resetSeconds)) : nil
        return (percent, resetAt)
    }
}
