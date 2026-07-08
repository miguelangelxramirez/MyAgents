import Foundation

/// The coding agent that owns a session: Claude Code or Codex.
///
/// Mirrors the `provider` field of the wire-format JSON the hooks write to
/// `~/.claude/statusbar/sessions.d/*.json` (see `docs/state-schema.md` and
/// `src/MyAgents/Models/SessionState.cs` in the Windows reference).
public enum Provider: String, CaseIterable, Sendable, Codable {
    case claude
    case codex

    /// Tolerant decode: an unrecognized provider string (a future hook we don't know about
    /// yet) falls back to `.claude` rather than failing the whole session file. Hostile JSON
    /// is a first-class input here (METODOLOGIA §4), not an exceptional case.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Provider(rawValue: raw) ?? .claude
    }
}
