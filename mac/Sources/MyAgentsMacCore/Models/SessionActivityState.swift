import Foundation

/// Lifecycle state of an agent session.
///
/// The first four cases mirror the state machine the Claude Code / Codex hooks write to the
/// `state` field of `~/.claude/statusbar/sessions.d/*.json` (see `docs/state-schema.md`).
/// `ended` has no wire representation: it is a state the app itself assigns once a session's
/// owning process is no longer alive (process-liveness join lands in Hito 2; the case exists
/// now so the model and its localization are already complete).
public enum SessionActivityState: String, Sendable, Codable {
    case thinking
    case tool
    case permission
    case idle
    case ended

    /// Tolerant decode: an unrecognized raw value (a future hook state) falls back to `.idle`
    /// instead of failing the whole session file — a corrupt/unknown `state` string must not
    /// take down an otherwise-valid session.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SessionActivityState(rawValue: raw) ?? .idle
    }

    /// `true` for the two states that mean "the agent is doing work right now".
    public var isBusy: Bool {
        self == .thinking || self == .tool
    }

    /// `true` when the session needs a human right now.
    public var needsAttention: Bool {
        self == .permission
    }

    /// User-facing label. Falls back to English if the app's string catalog isn't reachable
    /// (e.g. calls from a unit test bundle with no `Bundle.main` resources).
    public var localizedLabel: String {
        switch self {
        case .thinking:
            return String(localized: "state.thinking", defaultValue: "Thinking…")
        case .tool:
            return String(localized: "state.tool", defaultValue: "Running tool")
        case .permission:
            return String(localized: "state.permission", defaultValue: "Awaiting permission")
        case .idle:
            return String(localized: "state.idle", defaultValue: "Idle")
        case .ended:
            return String(localized: "state.ended", defaultValue: "Ended")
        }
    }
}
