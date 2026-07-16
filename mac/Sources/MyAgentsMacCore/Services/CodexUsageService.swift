import Foundation
import os

/// Reads Codex's 5-hour/7-day rate-limit usage. Mirrors `src/MyAgents/Services/CodexUsageService.cs`
/// adapted to macOS (no WSL — there's only ever one native process tree to talk to):
///
/// 1. PRIMARY: spawn Codex's own local `app-server` and call the JSON-RPC method
///    `account/rateLimits/read` — LIVE, TOKEN-FREE (Codex's `app-server` reads its own cached
///    `~/.codex/auth.json`; we never touch that file ourselves), and OFFICIAL (Codex's own local
///    RPC surface, not an undocumented HTTP endpoint). Same mechanism CodexBar uses.
/// 2. FALLBACK: the latest `rate_limits` line tailed out of Codex's rollout JSONL
///    (`~/.codex/sessions/**/rollout-*.jsonl`) — the same data Codex itself already writes on
///    every turn, so still no token and no network; just lags behind the live value.
/// 3. Neither available → `.unknown(provider: .codex)`. NEVER a fabricated `0%`.
///
/// The gray `wham`/ChatGPT-usage HTTP endpoint the Windows build guards behind `USAGE_LOCAL` is
/// intentionally NOT ported here — out of scope for the public macOS build (CONTEXT.md D3).
public struct CodexUsageService: Sendable {
    private let rpcCommand: [String]
    private let rpcTimeout: TimeInterval
    private let rolloutRoot: URL
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "CodexUsageService")

    /// Launches `codex app-server` through a login shell (`zsh -l -c`) rather than invoking the
    /// `codex` binary path directly: a macOS GUI app launched by `launchd` does NOT inherit the
    /// user's interactive shell `PATH` (no `.zprofile`/nvm/Homebrew shims), which is exactly where
    /// `codex` usually lives when installed via npm/Homebrew. A login shell re-derives that PATH
    /// the same way Terminal.app would, so this works whether the user installed Codex via
    /// Homebrew, npm global, or a version manager — without us hard-coding any install location.
    public static var defaultRPCCommand: [String] {
        ["/bin/zsh", "-l", "-c", "codex -s read-only -a untrusted app-server"]
    }

    public static var defaultRolloutRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// - Parameters:
    ///   - rpcCommand: `execve`-style argv for the shell that launches `app-server`. Injectable so
    ///     tests can point at a fixture script instead of a real Codex install.
    ///   - rpcTimeout: bound on how long we wait for the RPC response before killing the process
    ///     and falling back to the rollout file — a slow/hung `codex` must never hang usage refresh.
    public init(
        rpcCommand: [String] = CodexUsageService.defaultRPCCommand,
        rpcTimeout: TimeInterval = 12,
        rolloutRoot: URL = CodexUsageService.defaultRolloutRoot
    ) {
        self.rpcCommand = rpcCommand
        self.rpcTimeout = rpcTimeout
        self.rolloutRoot = rolloutRoot
    }

    public func fetch() async -> UsageInfo {
        // Observability (user feedback, 2026-07-09: "el usage de codex no se actualiza"). Unlike
        // Claude (a local file read), Codex has to spawn `codex app-server` and talk JSON-RPC —
        // which works from a shell but can fail or time out when the app is launched by launchd
        // (no interactive PATH). These `.notice` lines make WHICH path won visible in `log show`,
        // so a frozen/greyed Codex reading is diagnosable instead of silent. Percentages aren't
        // sensitive, so they're logged `.public`.
        if let live = await fetchFromAppServerRPC() {
            logger.notice("codex usage: live RPC ok (5h=\(live.fiveHourPercent ?? -1, privacy: .public), 7d=\(live.sevenDayPercent ?? -1, privacy: .public))")
            return live
        }
        logger.notice("codex usage: live RPC unavailable — falling back to rollout file (stale)")
        if let rollout = fetchFromRollout() {
            logger.notice("codex usage: using rollout fallback (5h=\(rollout.fiveHourPercent ?? -1, privacy: .public), 7d=\(rollout.sevenDayPercent ?? -1, privacy: .public))")
            return rollout
        }
        logger.notice("codex usage: no data — RPC and rollout both failed, reporting unknown")
        return .unknown(provider: .codex)
    }

    // MARK: - PRIMARY: live `account/rateLimits/read` over the app-server's JSON-RPC stdio

    private func fetchFromAppServerRPC() async -> UsageInfo? {
        let command = rpcCommand
        let timeout = rpcTimeout
        let logger = self.logger
        // Runs on a background thread (not the Swift-concurrency cooperative pool) because the
        // process I/O below is genuinely blocking, bounded only by the kill-switch timer.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runRPCBlocking(command: command, timeout: timeout, logger: logger))
            }
        }
    }

    private static func runRPCBlocking(command: [String], timeout: TimeInterval, logger: Logger) -> UsageInfo? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr → /dev/null, NOT a Pipe. A Pipe has a finite (~64 KB) kernel buffer; since only
        // stdout is drained below, enough stderr from the login shell or `codex app-server` fills
        // that buffer and BLOCKS the child before it ever answers `account/rateLimits/read` — so
        // every refresh waited out the 12s kill-switch and fell to the stale rollout (Codex audit
        // MED #8, 2026-07-16). `nullDevice` can never fill, so the child never blocks on it.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.debug("codex app-server failed to launch: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Kill switch: if the RPC hasn't produced a response by `timeout`, terminate the process
        // so the blocking read below unblocks with EOF instead of hanging the refresh forever.
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        defer {
            timeoutWorkItem.cancel()
            if process.isRunning { process.terminate() }
        }

        let requestLines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"myagents-mac","title":"MyAgents","version":"0.1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        let inputHandle = stdinPipe.fileHandleForWriting
        for line in requestLines {
            if let data = (line + "\n").data(using: .utf8) {
                inputHandle.write(data)
            }
        }

        // Do NOT close stdin here. `codex app-server` treats a stdin EOF as "the client is done"
        // and shuts down — if we close right after writing, it exits after answering only
        // `initialize` and NEVER replies to `account/rateLimits/read` (id:2). That was the real
        // reason Codex usage "no se actualizaba": every live fetch silently lost the race and fell
        // through to the greyed rollout fallback (root-caused live on this machine, 2026-07-09 —
        // keeping stdin open for the same request returns the data, closing it immediately doesn't).
        // Keep the write end open until we've read the response; the kill-switch timer and the
        // `defer` above still guarantee the process is torn down no matter what.
        let matchedLine = readLine(containing: "\"id\":2", from: stdoutPipe.fileHandleForReading)
        try? inputHandle.close()
        process.terminate()
        process.waitUntilExit()

        guard let matchedLine else { return nil }
        return parseRPCLine(matchedLine)
    }

    /// Hard ceiling on the stdout accumulator: a runaway child streaming without a newline must not
    /// grow this without limit. The real response line is a few hundred bytes; 1 MiB is enormous
    /// headroom and still bounds a misbehaving `app-server`.
    private static let maxStdoutBufferBytes = 1 << 20

    /// Reads newline-delimited stdout until a line containing `marker` shows up, or EOF/the
    /// kill-switch closes the pipe first (in which case this returns `nil`).
    private static func readLine(containing marker: String, from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil } // EOF — process exited or was killed by the timeout
            buffer.append(chunk)
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                if let line = String(data: lineData, encoding: .utf8), line.contains(marker) {
                    return line
                }
            }
            // Whatever's left is an as-yet-incomplete line. If even that has blown past the ceiling,
            // the child is misbehaving (no newline in sight) — bail rather than accumulate forever.
            if buffer.count > maxStdoutBufferBytes { return nil }
        }
    }

    /// Parses the app-server's `account/rateLimits/read` result — camelCase `usedPercent`/`resetsAt`/
    /// `windowDurationMins` under `result.rateLimits.primary` / `.secondary`. Which bucket is the 5h
    /// vs the 7d window is decided by its DURATION, not its position (see `bucket`).
    private static func parseRPCLine(_ line: String) -> UsageInfo? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rateLimits = result["rateLimits"] as? [String: Any] else {
            return nil
        }
        return usageInfo(
            buckets: [
                bucket(rateLimits["primary"], percentKey: "usedPercent", resetKey: "resetsAt", windowKey: "windowDurationMins", positionalDefault: .fiveHour),
                bucket(rateLimits["secondary"], percentKey: "usedPercent", resetKey: "resetsAt", windowKey: "windowDurationMins", positionalDefault: .sevenDay),
            ],
            capturedAt: Date() // a live RPC reading — "now" is accurate, never stale by construction
        )
    }

    /// A window ≥ this many minutes is the "7-day" bucket; anything shorter is the "5-hour" bucket.
    /// One day is a wide gap between Codex's real windows (5 h = 300 min, 7 d = 10080 min), so the
    /// split is unambiguous and tolerant of the exact numbers changing slightly.
    private static let sevenDayCutoffMinutes: Double = 1440

    // MARK: - FALLBACK: tail the newest rollout JSONL files for their last `rate_limits` line

    private func fetchFromRollout() -> UsageInfo? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rolloutRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = fileManager.enumerator(
            at: rolloutRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((url, modifiedAt))
        }

        // Newest few, not just the single newest: the most-recently-touched rollout can be a
        // just-started session with no rate_limits line yet (mirrors CodexUsageService.cs).
        let newest = candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(6)
        for candidate in newest {
            if let line = Self.lastRateLimitsLine(in: candidate.url), let info = Self.parseRolloutLine(line) {
                return info
            }
        }
        return nil
    }

    /// How many trailing bytes of a rollout to scan looking for the last `rate_limits` line.
    private static let tailBytes = 65536

    /// Tail-reads the last 64 KB of `file` and returns its last line containing `"rate_limits"`.
    ///
    /// Uses `BoundedLineReader.tailLines` — the SAME offset-safe reader `CodexSessionScanner` uses —
    /// rather than decoding the whole 64 KB block with one strict `String(data:encoding:.utf8)`.
    /// The old block-decode returned nil whenever the arbitrary `size - 64K` offset split a multi-byte
    /// UTF-8 character (routine in a Spanish prompt), silently discarding a valid later `rate_limits`
    /// line (Codex audit MED #6, 2026-07-16 — the same bug already fixed in the status-tail path).
    private static func lastRateLimitsLine(in file: URL) -> String? {
        var last: String?
        for line in BoundedLineReader.tailLines(of: file, maxBytes: tailBytes) where line.contains("\"rate_limits\"") {
            last = line
        }
        return last
    }

    /// Parses one rollout JSONL line → `UsageInfo` (snake_case `used_percent`/`resets_at`/
    /// `window_minutes`, buckets `primary`/`secondary`, possibly nested under `payload`). Window
    /// assignment is by DURATION, same as the RPC path (see `bucket`).
    private static func parseRolloutLine(_ line: String) -> UsageInfo? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rateLimits: [String: Any]?
        if let payload = object["payload"] as? [String: Any], let nested = payload["rate_limits"] as? [String: Any] {
            rateLimits = nested
        } else {
            rateLimits = object["rate_limits"] as? [String: Any]
        }
        guard let rateLimits else { return nil }
        return usageInfo(
            buckets: [
                bucket(rateLimits["primary"], percentKey: "used_percent", resetKey: "resets_at", windowKey: "window_minutes", positionalDefault: .fiveHour),
                bucket(rateLimits["secondary"], percentKey: "used_percent", resetKey: "resets_at", windowKey: "window_minutes", positionalDefault: .sevenDay),
            ],
            // A rollout reading reflects the last turn Codex processed, not "right now" — flag it
            // stale so the UI can grey it out, same idea as an aged Claude statusline capture.
            capturedAt: Date(),
            forceStale: true
        )
    }

    /// One parsed rate-limit bucket, already resolved to the display window it belongs to.
    private struct RateBucket {
        let percent: Double
        let resetAt: Date?
        let window: UsageWindow
    }

    /// Parses a rate-limit bucket and assigns it to a display window by its DURATION — NOT its
    /// position in the response. Codex used to send `primary` = 5-hour and `secondary` = 7-day; it
    /// now sends a single `primary` = 7-day (`windowDurationMins` 10080) with `secondary` null, and
    /// may rearrange again. Reading the duration (5 h = 300 min, 7 d = 10080 min) maps each bucket
    /// correctly whatever slot it arrives in: under a day → the 5-hour row, a day or more → the 7-day
    /// row. When no duration field is present (older payloads / tests) it falls back to the bucket's
    /// historical position, so nothing regresses.
    private static func bucket(_ raw: Any?, percentKey: String, resetKey: String, windowKey: String, positionalDefault: UsageWindow) -> RateBucket? {
        guard let dict = raw as? [String: Any], let percent = UsageInfo.percent(from: dict[percentKey]) else {
            return nil
        }
        let resetSeconds = (dict[resetKey] as? NSNumber)?.int64Value ?? 0
        let resetAt = resetSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(resetSeconds)) : nil
        let window: UsageWindow
        if let minutes = (dict[windowKey] as? NSNumber)?.doubleValue, minutes > 0 {
            window = minutes < sevenDayCutoffMinutes ? .fiveHour : .sevenDay
        } else {
            window = positionalDefault
        }
        return RateBucket(percent: percent, resetAt: resetAt, window: window)
    }

    /// Assembles a `UsageInfo` from whichever buckets parsed, slotting each into its resolved window.
    /// `nil` when no bucket had a usable reading (both absent → the provider reports no limit right
    /// now, rendered as "—"/hidden by the UI). If two buckets resolve to the same window the first
    /// wins — Codex never sends duplicates, but this stays deterministic if it ever did.
    private static func usageInfo(buckets: [RateBucket?], capturedAt: Date?, forceStale: Bool = false) -> UsageInfo? {
        let present = buckets.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        let fiveHour = present.first { $0.window == .fiveHour }
        let sevenDay = present.first { $0.window == .sevenDay }
        return UsageInfo(
            provider: .codex,
            fiveHourPercent: fiveHour?.percent,
            fiveHourResetsAt: fiveHour?.resetAt,
            sevenDayPercent: sevenDay?.percent,
            sevenDayResetsAt: sevenDay?.resetAt,
            capturedAt: capturedAt,
            isStale: forceStale
        )
    }
}
