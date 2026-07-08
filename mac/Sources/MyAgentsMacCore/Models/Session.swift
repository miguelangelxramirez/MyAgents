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
        self.provider = provider
        self.state = state
        self.toolLabel = toolLabel
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.ownerPid = ownerPid
        self.pending = pending
    }
}
