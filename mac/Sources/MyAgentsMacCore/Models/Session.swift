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

    /// Path to the Claude Code transcript JSONL for this session (`transcript` in the wire
    /// format), if the hook reported one. Read by `TranscriptTitle` to find the AI-authored title
    /// — not used for anything else yet (D11: also reserved for Hito 2 click-to-focus).
    public var transcript: String
    /// Terminal identity the hook captured (`terminalHost` in the wire format, e.g.
    /// `"Apple_Terminal"`, `"iTerm.app"`) — unused until Hito 2's click-to-focus.
    public var terminalHost: String
    /// Focus marker the hook wrote into the terminal's tab/window title (`titleTag` in the wire
    /// format) — unused until Hito 2's click-to-focus.
    public var titleTag: String
    /// Host platform the hook ran on (`host` in the wire format, e.g. `"darwin"`) — unused today,
    /// reserved for Hito 2/3.
    public var host: String

    /// The title actually shown on the row's top line, resolved by `SessionDisplayName.resolve`
    /// (AI-authored transcript title → hook `name` → localized placeholder — NEVER the folder
    /// name, which is what caused the folder to show twice). Populated by `SessionStore` before a
    /// session reaches the UI; empty only means "not yet resolved" — `resolve` always returns a
    /// non-empty string, so an empty value is a safe sentinel, never a legitimate title.
    public var displayName: String

    /// Number of active SUBAGENTS nested under this session — the `codex exec` (and future
    /// nested-agent) processes whose ancestry resolves to THIS session (see `SessionLivenessJoin`
    /// + `ProcessLiveness.classifyAncestry`). Zero for a normal session. Drives the "N agents"
    /// badge on the tile; a subagent never gets a tile of its own, so this is the only place its
    /// presence shows.
    public var subagentCount: Int

    /// Controlling terminal device path (`/dev/ttys005`) for a session discovered purely as a live
    /// PROCESS (a Codex session — no hook file). Lets click-to-focus select the EXACT tab by tty.
    /// Empty for hook-sourced sessions (they focus by title) and any process without a terminal.
    public var tty: String

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
        pending: Bool = false,
        transcript: String = "",
        terminalHost: String = "",
        titleTag: String = "",
        host: String = "",
        displayName: String = "",
        subagentCount: Int = 0,
        tty: String = ""
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
        self.transcript = transcript
        self.terminalHost = terminalHost
        self.titleTag = titleTag
        self.host = host
        self.displayName = displayName
        self.subagentCount = subagentCount
        self.tty = tty
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
