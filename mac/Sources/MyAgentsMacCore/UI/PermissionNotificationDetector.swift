import Foundation

/// Edge-detector for "a session just started awaiting permission" — the trigger for a banner.
///
/// A permission request is a *transition*, not a level: the poll loop sees the same
/// `permission` session dozens of times while the human is away, but the banner must fire exactly
/// ONCE, on the rising edge (was-not-permission → is-permission). This type remembers the last
/// observed state per session and reports only genuine new edges.
///
/// The core rule is a pure static function (`transitions`) so it's testable without any mutable
/// object; the `mutating` wrapper just threads the remembered memory across polls.
public struct PermissionNotificationDetector: Sendable {
    /// Last-seen activity state, keyed by session id. A session absent from this map is treated as
    /// "never seen" — so a brand-new session that appears already awaiting permission fires (an
    /// unknown → permission edge is still an edge), and a session that vanished and reappears in
    /// permission fires again (a genuinely new request).
    private var memory: [String: SessionActivityState] = [:]

    public init() {}

    /// Pure rule: given the previous per-session states and the current sessions, return the ids
    /// that just transitioned into `.permission`, plus the memory to carry into the next call.
    ///
    /// The next memory contains ONLY the currently present sessions (bounded growth; a session
    /// that disappears is forgotten, which is what lets a later reappearance re-fire).
    public static func transitions(
        previous: [String: SessionActivityState],
        current: [Session]
    ) -> (firedIDs: [String], nextMemory: [String: SessionActivityState]) {
        var fired: [String] = []
        for session in current where session.state == .permission {
            if previous[session.id] != .permission {
                fired.append(session.id)
            }
        }
        let nextMemory = Dictionary(
            current.map { ($0.id, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        return (fired, nextMemory)
    }

    /// Stateful convenience over `transitions`: returns the sessions that just entered
    /// `.permission` since the previous call and advances the remembered state.
    public mutating func newlyAwaitingPermission(_ sessions: [Session]) -> [Session] {
        let (firedIDs, nextMemory) = Self.transitions(previous: memory, current: sessions)
        memory = nextMemory
        guard !firedIDs.isEmpty else { return [] }
        let firedSet = Set(firedIDs)
        return sessions.filter { firedSet.contains($0.id) }
    }
}
