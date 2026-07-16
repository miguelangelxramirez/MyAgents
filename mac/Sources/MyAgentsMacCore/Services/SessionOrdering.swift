import Foundation

/// Attention-first ordering policy for the session list — a pure function so it's testable
/// without any of `SessionStore`'s polling machinery.
///
/// Product requirement (CONTEXT.md Hito 1 / D9): a session that needs a human RIGHT NOW always
/// sorts above one that's merely busy, which always sorts above idle, which sorts above a
/// finished (`ended`) session. Within the same tier, the most recently updated session comes
/// first — that's the one the user most likely wants to check next.
public enum SessionOrdering {
    public static func attentionFirst(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.enumerated().sorted { lhs, rhs in
            let lRank = rank(of: lhs.element)
            let rRank = rank(of: rhs.element)
            if lRank != rRank { return lRank < rRank }
            let lRecency = recency(of: lhs.element)
            let rRecency = recency(of: rhs.element)
            if lRecency != rRecency { return lRecency > rRecency }
            // Stable tie-break: preserve original relative order for two sessions with identical
            // rank and recency (e.g. two sessions with no timestamp at all).
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(of session: Session) -> Int {
        switch session.state {
        case .permission: return 0
        case .thinking, .tool: return 1
        case .active: return 2   // alive (a discovered Codex process), above a hook-reported at-rest
        case .idle: return 3
        case .ended: return 4
        }
    }

    private static func recency(of session: Session) -> TimeInterval {
        (session.updatedAt ?? session.startedAt)?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
    }
}
