import Foundation

/// One agent session — the macOS-side mirror of the Windows `SessionState` model
/// (`src/MyAgents/Models/SessionState.cs`). Built by `SessionScanner` from the per-session JSON
/// the Claude Code / Codex hooks write to `~/.claude/statusbar/sessions.d/<id>.json`.
///
/// This is a plain value type, not `Decodable` from the wire format directly: the wire JSON's
/// key names, unix-second timestamps and required tolerance for missing/garbage fields are a
/// decoding *detail* owned by `SessionScanner` (see `SessionWireFormat` there), not part of the
/// Core model's public contract.
public struct Session: Identifiable, Equatable, Sendable {
    /// Stable identity: the hook's `sessionId`, or (if that's missing) the JSON file's name.
    public let id: String
    public var name: String
    /// Basename of the working directory (`project` in the wire format).
    public var folder: String
    /// Full working directory path (`cwd` in the wire format). Kept alongside `folder` (the
    /// display basename) because the process-liveness join (`SessionLivenessJoin`) needs the full
    /// path to match a pid-less session to a live process by provider+cwd — a basename alone
    /// collides across projects with the same folder name.
    public var cwd: String
    public var provider: Provider
    public var state: SessionActivityState
    /// Human-facing label for the current activity (e.g. "Editing", "Running command"); falls
    /// back to the raw tool name when no friendlier label was provided.
    public var toolLabel: String
    public var startedAt: Date?
    public var updatedAt: Date?
    public var ownerPid: Int32?
    /// Finished-but-unopened marker (mirrors the Windows widget's "small dot"); the scanner never
    /// sets this — it's app-owned state a future `SessionStore` clears when the row is clicked.
    public var pending: Bool

    public init(
        id: String,
        name: String = "",
        folder: String = "",
        cwd: String = "",
        provider: Provider = .claude,
        state: SessionActivityState = .idle,
        toolLabel: String = "",
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        ownerPid: Int32? = nil,
        pending: Bool = false
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.cwd = cwd
        self.provider = provider
        self.state = state
        self.toolLabel = toolLabel
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.ownerPid = ownerPid
        self.pending = pending
    }

    // MARK: - Derived flags (mirror `SessionState.cs`'s `NeedsAttention`/`IsBusy`/`IsStale`)

    /// `true` when this session needs a human right now.
    public var needsAttention: Bool { state.needsAttention }

    /// `true` while the agent is actively doing work (thinking or running a tool).
    public var isBusy: Bool { state.isBusy }

    /// `true` if we haven't heard from this session in longer than `threshold` — a crash-safety
    /// net so a session whose process died without a clean end event doesn't sit "thinking"
    /// forever in the UI.
    public func isStale(asOf now: Date = Date(), threshold: TimeInterval) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > threshold
    }
}
