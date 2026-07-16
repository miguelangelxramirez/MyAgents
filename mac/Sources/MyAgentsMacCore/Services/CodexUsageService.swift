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
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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
        }
    }

    /// Parses the app-server's `account/rateLimits/read` result — camelCase `usedPercent`/`resetsAt`
    /// under `result.rateLimits.primary` (5h) / `.secondary` (7d).
    private static func parseRPCLine(_ line: String) -> UsageInfo? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rateLimits = result["rateLimits"] as? [String: Any] else {
            return nil
        }
        return usageInfo(
            fiveHour: camelBucket(rateLimits["primary"]),
            sevenDay: camelBucket(rateLimits["secondary"]),
            capturedAt: Date() // a live RPC reading — "now" is accurate, never stale by construction
        )
    }

    private static func camelBucket(_ raw: Any?) -> (percent: Double, resetAt: Date?)? {
        guard let dict = raw as? [String: Any], let percent = UsageInfo.percent(from: dict["usedPercent"]) else {
            return nil
        }
        let resetSeconds = (dict["resetsAt"] as? NSNumber)?.int64Value ?? 0
        let resetAt = resetSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(resetSeconds)) : nil
        return (percent, resetAt)
    }

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

    /// Tail-reads the last 64 KB of `file` and returns its last line containing `"rate_limits"`.
    private static func lastRateLimitsLine(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let tailSize: UInt64 = 65536
        let offset = fileSize > tailSize ? fileSize - tailSize : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var last: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.contains("\"rate_limits\"") {
            last = String(line)
        }
        return last
    }

    /// Parses one rollout JSONL line → `UsageInfo` (snake_case `used_percent`/`resets_at`, bucket
    /// names `primary` (5h) / `secondary` (7d), possibly nested under `payload`).
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
            fiveHour: snakeBucket(rateLimits["primary"]),
            sevenDay: snakeBucket(rateLimits["secondary"]),
            // A rollout reading reflects the last turn Codex processed, not "right now" — flag it
            // stale so the UI can grey it out, same idea as an aged Claude statusline capture.
            capturedAt: Date(),
            forceStale: true
        )
    }

    private static func snakeBucket(_ raw: Any?) -> (percent: Double, resetAt: Date?)? {
        guard let dict = raw as? [String: Any], let percent = UsageInfo.percent(from: dict["used_percent"]) else {
            return nil
        }
        let resetSeconds = (dict["resets_at"] as? NSNumber)?.int64Value ?? 0
        let resetAt = resetSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(resetSeconds)) : nil
        return (percent, resetAt)
    }

    private static func usageInfo(
        fiveHour: (percent: Double, resetAt: Date?)?,
        sevenDay: (percent: Double, resetAt: Date?)?,
        capturedAt: Date?,
        forceStale: Bool = false
    ) -> UsageInfo? {
        guard fiveHour != nil || sevenDay != nil else { return nil }
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
