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
    private let fileListTTL: TimeInterval

    /// Serializes whole scans (see `scanRecentSessions`) — not the individual caches, which have
    /// their own locks.
    private let scanLock = NSLock()
    private let listLock = NSLock()
    /// PATHS, deliberately — not `URL`s. A `URL` memoizes the resource values read through it
    /// (`.contentModificationDateKey`, `.fileSizeKey`), so reusing the same `URL` instance across
    /// polls would serve a STALE mtime and size forever: an aged-out rollout would never age out,
    /// and a growing rollout would look frozen. A fresh `URL` per scan always stats for real.
    private var cachedFileList: [String] = []
    private var fileListBuiltAt: Date?
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "CodexSessionScanner")

    private let nameCache = CodexNameCache()
    private let latestLock = NSLock()
    private var latestByCwd: [String: [RolloutSession]] = [:]

    /// The parts of a rollout that CANNOT change once written: its session id, its cwd, and the
    /// first genuine user prompt that names it. A rollout file is append-only, so re-reading these
    /// on every poll was pure waste — and, on a real 10 MB rollout, ruinous waste (see
    /// `BoundedLineReader`). Cached per file path and read at most once.
    private struct CachedHeader {
        let sessionId: String
        let cwd: String
        let name: String
        /// The file's size when the name was last looked for. Only consulted while `name` is still
        /// empty (a session too young to have a prompt yet): since the file is append-only, a head
        /// scan can only produce a NEW answer once the file has grown.
        let sizeAtNameScan: Int64
    }

    private let headerLock = NSLock()
    private var headerByPath: [String: CachedHeader] = [:]

    /// The turn-boundary marker found in a rollout's tail. Derived from the file's CONTENT, so it
    /// only changes when the file does — which is what lets `state(for:...)` skip the 16 KiB tail
    /// read on a rollout that hasn't been written to since the last poll (the common case: a Codex
    /// session sitting idle while the app polls it twice a second).
    private enum TailMarker: Equatable {
        /// `task_complete` / `turn_aborted` / `thread_rolled_back` — the turn ended.
        case turnEnded
        case awaitingApproval
        /// `task_started`, with that turn's start time when the line carried a parseable timestamp.
        case working(Date?)
        /// No turn-boundary marker in the tail at all — the caller must fall back to file recency,
        /// which depends on `now` and therefore CANNOT be cached.
        case none
    }

    private struct CachedTail {
        let marker: TailMarker
        let modifiedAt: Date?
        let size: Int64
    }

    private let tailLock = NSLock()
    private var tailByPath: [String: CachedTail] = [:]

    /// Localized once, not on every poll: `String(localized:)` hits the bundle each call, and these
    /// were being resolved per rollout per poll (twice a second, forever).
    private static let workingLabel = String(localized: "codex.state.working", defaultValue: "Working")
    private static let awaitingApprovalLabel = String(localized: "codex.state.awaiting-approval", defaultValue: "Awaiting your approval")

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
    ///   - fileListTTL: how long the recursive listing of the rollout tree is reused before being
    ///     rebuilt. Pass `0` in a test that creates a NEW rollout file between two scans of the same
    ///     scanner, so the second scan re-walks the tree instead of reusing the first scan's listing.
    public init(
        sessionsRoot: URL = CodexSessionScanner.defaultSessionsRoot,
        fileManager: FileManager = .default,
        maxFilesPerScan: Int = 40,
        maxAge: TimeInterval = CodexSessionScanner.defaultMaxAge,
        fileListTTL: TimeInterval = 3
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
        self.maxFilesPerScan = maxFilesPerScan
        self.maxAge = maxAge
        self.fileListTTL = fileListTTL
    }

    /// Scans the newest rollout files (bounded by `maxFilesPerScan`/`maxAge`) and returns whatever
    /// parsed successfully. Also feeds the internal name-by-cwd cache (see `name(forCwd:)`) and
    /// replaces the "latest scan" snapshot used by `latestSession(forCwd:)`. Never throws.
    @discardableResult
    public func scanRecentSessions(now: Date = Date()) -> [RolloutSession] {
        // One scan at a time. The per-cache `NSLock`s stop data races on the dictionaries, but they
        // don't make a SCAN atomic: `SessionStore.refresh()` (popover opened) can land while the poll
        // loop's scan is in flight, and two interleaved scans could publish `latestByCwd` out of
        // order or prune entries the other one just cached.
        scanLock.lock()
        defer { scanLock.unlock() }

        let files = recentRolloutFiles(now: now)
        var results: [RolloutSession] = []
        for file in files {
            guard let session = parse(file: file) else { continue }
            nameCache.record(cwd: session.cwd, sessionId: session.sessionId, name: session.name)
            results.append(session)
        }

        // Drop header entries for files this scan no longer sees, so the cache stays the size of the
        // live window instead of growing for every rollout the machine has ever produced. A file
        // that comes back into the window simply pays for one more header read.
        let scannedPaths = Set(files.map(\.path))
        headerLock.lock()
        headerByPath = headerByPath.filter { scannedPaths.contains($0.key) }
        headerLock.unlock()
        tailLock.lock()
        tailByPath = tailByPath.filter { scannedPaths.contains($0.key) }
        tailLock.unlock()

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
        // The AGE filter is re-applied on every scan (a rollout ages out of the window purely with
        // the passage of time, and its mtime is needed for the state cache anyway). Only the
        // expensive part — walking the whole `sessions` tree to find out which rollout files exist
        // at all — is cached: see `rolloutFiles(now:)`.
        var candidates: [(url: URL, modifiedAt: Date)] = []
        for path in rolloutFiles(now: now) {
            // A FRESH URL per scan: see `cachedFileList` — a reused one would hand back a memoized
            // mtime and never notice the file had changed.
            let url = URL(fileURLWithPath: path)
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) <= maxAge else { continue }
            candidates.append((url, modifiedAt))
        }

        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFilesPerScan).map(\.url)
    }

    /// The PATH of every `rollout-*.jsonl` under `sessionsRoot`, from a cache that is rebuilt at most
    /// every `fileListTTL` seconds.
    ///
    /// Rebuilding means a full recursive walk of `~/.codex/sessions` — on this machine, 190 files
    /// across a 310 MB tree of nested date folders. Doing that twice a second (the poll rate) cost
    /// 217 of 8078 samples in the idle profile, purely to re-discover a set of files that changes
    /// only when a Codex session is created. A few seconds' delay in NOTICING a brand-new rollout is
    /// invisible to the user — the session already shows up immediately as a process-discovered row.
    private func rolloutFiles(now: Date) -> [String] {
        listLock.lock()
        if let builtAt = fileListBuiltAt, now.timeIntervalSince(builtAt) < fileListTTL, now >= builtAt {
            defer { listLock.unlock() }
            return cachedFileList
        }
        listLock.unlock()

        let files = enumerateRolloutFiles()

        listLock.lock()
        cachedFileList = files
        fileListBuiltAt = now
        listLock.unlock()
        return files
    }

    private func enumerateRolloutFiles() -> [String] {
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

        var files: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            files.append(url.path)
        }
        return files
    }

    // MARK: - Parsing one rollout file (never throws)

    /// Builds one `RolloutSession`. Only the STATE is re-derived from disk on every scan (a cheap
    /// 16 KiB tail read) — the id/cwd/name come from `header(for:)`, which reads them at most once
    /// per file, because they cannot change.
    private func parse(file: URL) -> RolloutSession? {
        guard let header = header(for: file) else { return nil }

        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let ageSeconds = modifiedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let (state, label, startedAt) = self.state(for: file, modifiedAt: modifiedAt, ageSeconds: ageSeconds)

        return RolloutSession(
            sessionId: header.sessionId,
            cwd: header.cwd,
            name: header.name,
            state: state,
            label: label,
            startedAt: startedAt,
            updatedAt: modifiedAt
        )
    }

    /// The rollout's immutable header, from cache when possible. Reads the file only when there is
    /// something new to learn: never once a name has been found, and — while the session is still
    /// nameless — only after the file has actually grown.
    private func header(for file: URL) -> CachedHeader? {
        let path = file.path
        let size = Self.fileSize(of: file)

        headerLock.lock()
        let cached = headerByPath[path]
        headerLock.unlock()

        if let cached {
            // A name, once found, is final: the first user prompt of an append-only file never changes.
            if !cached.name.isEmpty { return cached }
            // Still nameless and the file hasn't grown — a re-scan would read the same bytes for the
            // same answer.
            if cached.sizeAtNameScan == size { return cached }
        }

        // The id/cwd live on line 1 and are equally immutable — only read them if we've never had them.
        let meta: (sessionId: String, cwd: String)
        if let cached {
            meta = (cached.sessionId, cached.cwd)
        } else if let read = Self.readSessionMeta(file: file) {
            meta = read
        } else {
            return nil
        }

        let fresh = CachedHeader(sessionId: meta.sessionId, cwd: meta.cwd, name: Self.extractName(file: file), sizeAtNameScan: size)
        headerLock.lock()
        headerByPath[path] = fresh
        headerLock.unlock()
        return fresh
    }

    private static func readSessionMeta(file: URL) -> (sessionId: String, cwd: String)? {
        guard let firstLine = BoundedLineReader.head(of: file, maxLines: 1).first,
              let parsed = parseSessionMeta(firstLine),
              !parsed.sessionId.isEmpty else {
            return nil
        }
        return parsed
    }

    /// `-1` when the size can't be read — a value no real file has, so the caller treats it as
    /// "changed" and re-scans rather than trusting a stale name.
    private static func fileSize(of file: URL) -> Int64 {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return -1 }
        return Int64(size)
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
    ///
    /// Stops at the first line that yields a name (`.stop`) rather than materializing all
    /// `maxNameScanLines` lines up front: on this machine's real rollouts the prompt is line 6, some
    /// 29 KB in, while the first 60 lines run to 5.5 MB because one of them is a 5.2 MB pasted blob.
    private static func extractName(file: URL) -> String {
        var name = ""
        BoundedLineReader.forEachLine(of: file, maxLines: maxNameScanLines) { line in
            guard line.contains("\"user\"") else { return .continue } // cheap pre-filter before JSON-decoding
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  (payload["type"] as? String) == "message",
                  (payload["role"] as? String) == "user" else {
                return .continue
            }
            let text = firstContentText(payload["content"]).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isInjectedContext(text) else { return .continue }
            name = text
            return .stop
        }
        return name
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
    /// approval-request line shape — see `isApprovalRequest` for how the marker is now matched.
    /// The state for one rollout. The tail is only RE-READ when the file has actually changed since
    /// the last poll (`modifiedAt`/size) — an idle Codex session is polled twice a second and its
    /// bytes cannot have moved, so re-reading 16 KiB and re-walking it every time was pure waste.
    /// The recency fallback still runs on every call, because it depends on `now`, not on the file.
    private func state(for file: URL, modifiedAt: Date?, ageSeconds: TimeInterval) -> (SessionActivityState, String, Date?) {
        switch cachedMarker(for: file, modifiedAt: modifiedAt) {
        case .turnEnded:
            return (.idle, "", nil)
        case .awaitingApproval:
            return (.permission, Self.awaitingApprovalLabel, nil)
        case .working(let startedAt):
            return (.tool, Self.workingLabel, startedAt)
        case .none:
            // No turn-boundary marker at all: all we have is how recently Codex touched the file.
            return ageSeconds <= Self.busyFallbackSeconds ? (.tool, Self.workingLabel, nil) : (.idle, "", nil)
        }
    }

    private func cachedMarker(for file: URL, modifiedAt: Date?) -> TailMarker {
        let path = file.path
        let size = Self.fileSize(of: file)

        tailLock.lock()
        let cached = tailByPath[path]
        tailLock.unlock()
        if let cached, cached.modifiedAt == modifiedAt, cached.size == size {
            return cached.marker
        }

        let marker = Self.readMarker(file: file)
        tailLock.lock()
        tailByPath[path] = CachedTail(marker: marker, modifiedAt: modifiedAt, size: size)
        tailLock.unlock()
        return marker
    }

    /// Derives the last TURN-BOUNDARY marker from the rollout's tail, walking newest→oldest —
    /// mirrors the C# reference's `InferState`. Codex writes explicit lifecycle markers:
    /// `task_started` → a turn began (working), `task_complete`/`turn_aborted`/`thread_rolled_back`
    /// → the turn ended one way or another (idle), plus an approval-request heuristic (permission).
    ///
    /// [ASUMIDO]: `task_started`/`task_complete`/`turn_aborted` were verified against real rollout
    /// files on this machine; no real approval-required session was available to verify the
    /// approval-request line shape — see `isApprovalRequest` for how the marker is now matched.
    private static func readMarker(file: URL) -> TailMarker {
        let lines = tailLines(of: file, maxBytes: stateTailBytes)
        for line in lines.reversed() {
            if line.contains("\"task_complete\"") { return .turnEnded }
            if line.contains("\"turn_aborted\"") { return .turnEnded }
            if line.contains("\"thread_rolled_back\"") { return .turnEnded }
            if isApprovalRequest(line: line) { return .awaitingApproval }
            if line.contains("\"task_started\"") { return .working(parseTimestamp(String(line))) }
        }
        return .none
    }

    /// A REAL pending-approval marker, told apart from the ubiquitous `approval_policy` config and
    /// the `request_user_input` tool. Codex serializes an approval prompt as an event whose type
    /// ends in `approval_request` (`exec_approval_request`, `apply_patch_approval_request`), so the
    /// two tokens must be ADJACENT.
    ///
    /// The old heuristic ("approval" AND "request" anywhere on the line) fired on
    /// `"approval_policy":"on-request"` — a field present in EVERY turn context (19k+ lines in this
    /// machine's rollouts). Because the state walk runs newest→oldest and the turn context is
    /// written after `task_started`, that false match beat the real "working" marker and made a
    /// merely-thinking Codex session read as "Esperando permiso" (live user feedback, 2026-07-09).
    /// Requiring adjacency is strictly tighter than the old check, so it can only remove false
    /// positives — it never matches `approval_policy`, `on-request`, or `request_user_input`.
    ///
    /// Two literal case-insensitive searches, NOT a regex: `range(of:options:.regularExpression)`
    /// builds and compiles an `NSRegularExpression` on every call, and this ran once per line of
    /// every rollout's tail on every poll — 95 of 8078 samples in the idle profile, for a match that
    /// is really just "one of two fixed substrings".
    static func isApprovalRequest<S: StringProtocol>(line: S) -> Bool {
        line.range(of: "approval_request", options: .caseInsensitive) != nil
            || line.range(of: "approval-request", options: .caseInsensitive) != nil
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

    /// The COMPLETE lines contained in the last `maxBytes` of `file`.
    ///
    /// The byte offset we seek to is arbitrary — it will usually land in the middle of a line, and it
    /// can land in the middle of a multi-byte UTF-8 character (a Spanish prompt is full of them). So:
    /// drop everything before the first newline AS BYTES (that fragment is not a whole line anyway,
    /// and it is the only place a split character can occur), then decode each remaining line on its
    /// own. A line that still fails to decode is skipped, never fatal.
    ///
    /// The old version decoded the WHOLE 16 KiB block with one strict `String(data:encoding:.utf8)`.
    /// A single orphaned continuation byte at the front made that return nil, throwing away every
    /// valid marker behind it — the session then fell through to the 30-second recency heuristic and
    /// could show the wrong state (found by an external review, 2026-07-12).
    private static func tailLines(of file: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return [] }
        let size = UInt64(maxBytes)
        let offset = fileSize > size ? fileSize - size : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else {
            return []
        }

        let newline = UInt8(ascii: "\n")
        // Only when we started mid-file is the leading fragment a partial line; a tail that IS the
        // whole file starts at a real line boundary and must keep its first line.
        var body = data[data.startIndex...]
        if offset > 0 {
            guard let firstNewline = body.firstIndex(of: newline) else { return [] }
            body = body[body.index(after: firstNewline)...]
        }

        return body.split(separator: newline, omittingEmptySubsequences: true)
            .compactMap { String(data: $0, encoding: .utf8) }
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
