import Foundation
import os

/// Reads OpenAI Codex's OWN rollout transcripts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// to give a Codex session a real NAME (and a best-effort STATE) — mirroring
/// `src/MyAgents/Services/CodexScanner.cs`'s `ExtractName`/`InferState`/`_namesByCwd`. Codex has no
/// hook mechanism as reliable as Claude Code's on macOS, so a Codex row otherwise only ever
/// reaches `SessionStore` as a bare `ProcessLiveness`-discovered row: a pid and a cwd, no name, no
/// real state (see `SessionLivenessJoin`'s "discovered row" case, which stamps `.idle` because it
/// has nothing better). This type supplies exactly the (cwd → name/state) enrichment those rows
/// are missing; it does NOT build `Session` rows itself.
///
/// File location REUSES `CodexUsageService`'s approach (same file, `fetchFromRollout`): recurse
/// the sessions root with `FileManager.enumerator`, filter to `rollout-*.jsonl`, sort by
/// modification date, take the newest few. `CODEX_HOME` is honored the same way Codex's own CLI
/// honors it (an env override for where `~/.codex` lives), matching this class's `defaultCodexHome`.
///
/// Defensive by construction (METODOLOGIA §4 / CONTEXT.md D1): a missing/unreadable `sessions`
/// directory, a malformed rollout file, or a truncated/garbage JSONL line are all skipped — this
/// type never throws and never crashes the caller. Reads are bounded (a capped number of leading
/// lines for the name, a capped tail for the state), never a whole-file slurp, so a rollout that
/// has grown to megabytes is still cheap to scan.
public final class CodexSessionScanner: @unchecked Sendable {
    /// One rollout session as read directly off disk for THIS scan. `state`/`label`/`startedAt`
    /// reflect only the current scan (never cached across scans — state is transient, unlike the
    /// name); see `latestSession(forCwd:)`.
    public struct RolloutSession: Equatable, Sendable {
        public let sessionId: String
        public let cwd: String
        /// The first genuine user prompt, trimmed and capped to ~90 characters — "" if none was
        /// found within the leading-lines cap (session too young, or nothing but injected
        /// context so far).
        public let name: String
        public let state: SessionActivityState
        /// Human-facing label for `state` (mirrors `Session.toolLabel`); "" when the state needs
        /// no extra label (idle).
        public let label: String
        /// The CURRENT turn's real start time (from its `task_started` event), if the tail scan
        /// found one and the session is actively working. `nil` otherwise.
        public let startedAt: Date?
        /// The rollout file's last-modified time.
        public let updatedAt: Date?

        public init(sessionId: String, cwd: String, name: String, state: SessionActivityState, label: String, startedAt: Date?, updatedAt: Date?) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.name = name
            self.state = state
            self.label = label
            self.startedAt = startedAt
            self.updatedAt = updatedAt
        }
    }

    /// Rollout lines older than this (by file modification time) are ignored entirely — mirrors
    /// the C# reference's `ShowSeconds` (a session Codex hasn't touched in 30 minutes might as
    /// well not exist for naming purposes; a stale/wrong name is worse than none).
    public static let defaultMaxAge: TimeInterval = 1800
    /// Codex's `task_started`/file-recency fallback treats a rollout as "still working" only if
    /// it was written to within this many seconds — mirrors the C# reference's `BusySeconds`.
    private static let busyFallbackSeconds: TimeInterval = 30
    /// How many of the leading lines of a rollout to scan looking for the first real user prompt
    /// — mirrors the C# reference's cap (the prompt is always near the top; a session that's 60
    /// lines deep with no user message yet has nothing useful to show).
    private static let maxNameScanLines = 60
    /// How many trailing bytes of a rollout to scan looking for a turn-boundary marker — mirrors
    /// the C# reference's `Tail(file, 16384)`.
    private static let stateTailBytes = 16384

    private let sessionsRoot: URL
    // `FileManager` isn't `Sendable` in the SDK, but Apple documents instances as safe to use
    // from multiple threads for the read-only operations this scanner performs (same rationale
    // `SessionScanner` and `CodexUsageService` already rely on).
    nonisolated(unsafe) private let fileManager: FileManager
    private let maxFilesPerScan: Int
    private let maxAge: TimeInterval
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "CodexSessionScanner")

    private let nameCache = CodexNameCache()
    private let latestLock = NSLock()
    private var latestByCwd: [String: [RolloutSession]] = [:]

    /// `CODEX_HOME` if set (matches Codex's own CLI convention for relocating its home directory),
    /// else `~/.codex`.
    public static var defaultCodexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static var defaultSessionsRoot: URL {
        defaultCodexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// - Parameters:
    ///   - sessionsRoot: production default is `~/.codex/sessions` (or `$CODEX_HOME/sessions`).
    ///     Tests MUST inject a temp directory — never point this at a real `~/.codex`.
    ///   - maxFilesPerScan: hard cap on how many rollout files one scan will parse, newest-first —
    ///     bounds the cost of a scan regardless of how many historical sessions exist on disk.
    ///   - maxAge: rollout files whose modification time is older than this (relative to the
    ///     `now` passed to `scanRecentSessions`) are ignored — "how far back" (mirrors `ShowSeconds`).
    public init(
        sessionsRoot: URL = CodexSessionScanner.defaultSessionsRoot,
        fileManager: FileManager = .default,
        maxFilesPerScan: Int = 40,
        maxAge: TimeInterval = CodexSessionScanner.defaultMaxAge
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
        self.maxFilesPerScan = maxFilesPerScan
        self.maxAge = maxAge
    }

    /// Scans the newest rollout files (bounded by `maxFilesPerScan`/`maxAge`) and returns whatever
    /// parsed successfully. Also feeds the internal name-by-cwd cache (see `name(forCwd:)`) and
    /// replaces the "latest scan" snapshot used by `latestSession(forCwd:)`. Never throws.
    @discardableResult
    public func scanRecentSessions(now: Date = Date()) -> [RolloutSession] {
        let files = recentRolloutFiles(now: now)
        var results: [RolloutSession] = []
        for file in files {
            guard let session = Self.parse(file: file, fileManager: fileManager, logger: logger) else { continue }
            nameCache.record(cwd: session.cwd, sessionId: session.sessionId, name: session.name)
            results.append(session)
        }

        latestLock.lock()
        latestByCwd = Dictionary(grouping: results) { CodexNameCache.normalize($0.cwd) }
        latestLock.unlock()

        return results
    }

    /// A rollout-derived name for `cwd` — nil if never seen, no session there has produced a name
    /// yet, or the cwd is ambiguous (see `CodexNameCache`). Persists across scans: a session whose
    /// rollout aged out of the last `scanRecentSessions()` window can still resolve a name here.
    public func name(forCwd cwd: String) -> String? {
        nameCache.name(forCwd: cwd)
    }

    /// The state/label/timing for `cwd` from the MOST RECENT scan only — nil when zero or more
    /// than one session shares that cwd in that scan. Unlike `name(forCwd:)`, this is intentionally
    /// NOT persisted across scans: a stale state is actively misleading (a row could get stuck
    /// showing "Working" forever), whereas a stale name is merely a still-true fact.
    public func latestSession(forCwd cwd: String) -> RolloutSession? {
        latestLock.lock()
        defer { latestLock.unlock() }
        guard let matches = latestByCwd[CodexNameCache.normalize(cwd)], matches.count == 1 else { return nil }
        return matches.first
    }

    // MARK: - Locating files (mirrors `CodexUsageService.fetchFromRollout`)

    private func recentRolloutFiles(now: Date) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) <= maxAge else { continue }
            candidates.append((url, modifiedAt))
        }

        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFilesPerScan).map(\.url)
    }

    // MARK: - Parsing one rollout file (never throws)

    private static func parse(file: URL, fileManager: FileManager, logger: Logger) -> RolloutSession? {
        guard let firstLine = readLines(at: file, maxLines: 1).first,
              let (sessionId, cwd) = parseSessionMeta(firstLine),
              !sessionId.isEmpty else {
            return nil
        }

        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let name = extractName(file: file)
        let ageSeconds = modifiedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let (state, label, startedAt) = inferState(file: file, ageSeconds: ageSeconds)

        return RolloutSession(sessionId: sessionId, cwd: cwd, name: name, state: state, label: label, startedAt: startedAt, updatedAt: modifiedAt)
    }

    /// The rollout's first line is always a `session_meta` event carrying the session's id and
    /// cwd, e.g. (real line from this machine's `~/.codex/sessions`, truncated):
    /// ```
    /// {"timestamp":"...","type":"session_meta","payload":{"session_id":"019f...","id":"019f...","cwd":"/Users/…/Project", …}}
    /// ```
    /// Reads `payload.id` (matching the C# reference; `payload.session_id` carries the identical
    /// value on this Codex version but `id` is what the reference reads).
    private static func parseSessionMeta(_ line: String) -> (sessionId: String, cwd: String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let sessionId = (payload["id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        return (sessionId, cwd)
    }

    /// Best-effort session name = the first genuine user message in the rollout, skipping Codex's
    /// own injected context. A `response_item` user message looks like:
    /// ```
    /// {"timestamp":"...","type":"response_item","payload":{"type":"message","role":"user",
    ///   "content":[{"type":"input_text","text":"…"}]}}
    /// ```
    /// Codex ALSO injects a leading user-role message combining the project's `AGENTS.md` text
    /// (as one content part, starting with `"# AGENTS.md instructions for …"`) and an
    /// `<environment_context>…</environment_context>` block (as a second content part) — verified
    /// directly against this machine's real rollouts. Only the FIRST content part is inspected
    /// (mirroring the C# reference's `ExtractText`, which returns on the first part with a `text`
    /// field), so this injected message is skipped by matching its first part against:
    /// starts with `<` (a bare `<environment_context>` block with no AGENTS.md ahead of it), OR
    /// case-insensitively contains `environment_context`, `<user_instructions`, or `# AGENTS.md`.
    private static func extractName(file: URL) -> String {
        let lines = readLines(at: file, maxLines: maxNameScanLines)
        for line in lines {
            guard line.contains("\"user\"") else { continue } // cheap pre-filter before JSON-decoding
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  (payload["type"] as? String) == "message",
                  (payload["role"] as? String) == "user" else {
                continue
            }
            let text = firstContentText(payload["content"]).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isInjectedContext(text) else { continue }
            return text
        }
        return ""
    }

    private static func isInjectedContext(_ text: String) -> Bool {
        if text.hasPrefix("<") { return true }
        for marker in ["environment_context", "<user_instructions", "# AGENTS.md"] {
            if text.range(of: marker, options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    /// Returns the FIRST content part's text (mirroring the C# reference's `ExtractText`, which
    /// stops at the first part with a `text` field), capped to 90 characters. `content` can be a
    /// plain string or an array of typed parts (`{"type":"input_text","text":"…"}`).
    private static func firstContentText(_ content: Any?) -> String {
        if let text = content as? String {
            return String(text.prefix(90))
        }
        if let parts = content as? [Any] {
            for case let part as [String: Any] in parts {
                if let text = part["text"] as? String {
                    return String(text.prefix(90))
                }
            }
        }
        return ""
    }

    /// Derives state from the last TURN-BOUNDARY marker in the rollout's tail, walking newest→
    /// oldest — mirrors the C# reference's `InferState`. Codex writes explicit lifecycle markers:
    /// `task_started` → a turn began (working), `task_complete`/`turn_aborted`/
    /// `thread_rolled_back` → the turn ended one way or another (idle), plus an approval-request
    /// heuristic (permission). If none of those appear in the tail, this falls back to the file's
    /// recency (`ageSeconds <= busyFallbackSeconds` ⇒ still working).
    ///
    /// [ASUMIDO]: `task_started`/`task_complete`/`turn_aborted` were verified against real rollout
    /// files on this machine; no real approval-required session was available to verify the
    /// approval-request line shape, so that branch mirrors the C# reference's heuristic
    /// (case-insensitive "approval" + "request" substrings) unverified against a live example.
    private static func inferState(file: URL, ageSeconds: TimeInterval) -> (SessionActivityState, String, Date?) {
        let tailText = tail(of: file, maxBytes: stateTailBytes)
        let lines = tailText.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            if line.contains("\"task_complete\"") { return (.idle, "", nil) }
            if line.contains("\"turn_aborted\"") { return (.idle, "", nil) }
            if line.contains("\"thread_rolled_back\"") { return (.idle, "", nil) }
            if line.range(of: "approval", options: .caseInsensitive) != nil,
               line.range(of: "request", options: .caseInsensitive) != nil {
                return (.permission, String(localized: "codex.state.awaiting-approval", defaultValue: "Awaiting your approval"), nil)
            }
            if line.contains("\"task_started\"") {
                return (.tool, String(localized: "codex.state.working", defaultValue: "Working"), parseTimestamp(String(line)))
            }
        }
        if ageSeconds <= busyFallbackSeconds {
            return (.tool, String(localized: "codex.state.working", defaultValue: "Working"), nil)
        }
        return (.idle, "", nil)
    }

    /// Parses the leading `"timestamp":"2026-07-08T16:43:26.739Z"` of a rollout line to a `Date`.
    /// `nil` if the marker is absent or unparseable — never throws.
    private static func parseTimestamp(_ line: String) -> Date? {
        guard let markerRange = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[markerRange.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[rest.startIndex..<endQuote])
        return iso8601WithFractionalSeconds.date(from: value) ?? iso8601Plain.date(from: value)
    }

    // MARK: - Bounded file reading (never slurps a whole file)

    /// Reads up to `maxLines` lines from the START of `file`, in small chunks — never the whole
    /// file at once, so even a multi-megabyte rollout is cheap to scan for its leading lines.
    /// Mirrors `TranscriptTitle`'s chunked reader. A final unterminated line at EOF still counts
    /// (a rollout Codex is actively writing to may not have flushed its last newline yet).
    private static func readLines(at file: URL, maxLines: Int, chunkSize: Int = 8192) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        var lines: [String] = []
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while lines.count < maxLines {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty {
                if lines.count < maxLines, !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    lines.append(line)
                }
                break
            }
            buffer.append(chunk)
            while lines.count < maxLines, let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
            }
        }
        return lines
    }

    /// Reads the last `maxBytes` of `file` — mirrors `CodexUsageService.lastRateLimitsLine`'s tail
    /// read (and the C# reference's `Tail`).
    private static func tail(of file: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "" }
        let size = UInt64(maxBytes)
        let offset = fileSize > size ? fileSize - size : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

// `ISO8601DateFormatter` isn't `Sendable` in the SDK, but these are only ever read (`.date(from:)`)
// after construction, never mutated — safe to share across threads, same rationale as the
// `nonisolated(unsafe) FileManager` properties elsewhere in this file.
nonisolated(unsafe) private let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let iso8601Plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()
