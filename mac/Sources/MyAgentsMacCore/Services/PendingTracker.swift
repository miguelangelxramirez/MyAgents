import Foundation

/// Computes each session's `pending` dot — the "finished-but-unopened" marker mirrored from the
/// Windows widget's small dot. The wire format has no `pending` field (the scanner always leaves it
/// `false`); it is app-owned state derived here from what the app has WATCHED happen across polls.
///
/// The rule, as a pure reducer over an in-memory arm/seen pair (per app run, `Session` on disk is
/// stateless):
/// - A session is ARMED once we've seen it busy (thinking/tool) at least once.
/// - `pending` is `true` when an armed session is now FINISHED (idle or ended) and hasn't been
///   opened (clicked) since it last went busy.
/// - Going busy again RE-ARMS it: the seen mark is cleared, so the dot reappears when it next
///   finishes. Clicking (`markSeen`) sets the seen mark, clearing the dot until the next re-arm.
///
/// Kept pure and `Equatable` so the whole policy is unit-testable without a store, a poll loop, or
/// the UI. `SessionStore` owns one instance and threads every published list through `apply`.
public struct PendingTracker: Equatable, Sendable {
    /// Sessions seen busy at least once (and not since re-armed by going busy after a click).
    private var armed: Set<String> = []
    /// Sessions the user has opened/clicked since they last went busy.
    private var seen: Set<String> = []

    public init() {}

    /// Records that the user opened this session — clears its pending dot until it next re-arms.
    public mutating func markSeen(_ id: String) {
        seen.insert(id)
    }

    /// Folds the latest session list in (updating arm/seen state) and returns the same sessions
    /// with `pending` computed. Order-preserving. Prunes state for sessions that no longer exist so
    /// the sets can't grow without bound.
    public mutating func apply(to sessions: [Session]) -> [Session] {
        let liveIDs = Set(sessions.map(\.id))
        armed.formIntersection(liveIDs)
        seen.formIntersection(liveIDs)

        return sessions.map { session in
            var updated = session
            if session.isBusy {
                // Working now: arm it and drop any stale "seen" so the dot re-appears when it ends.
                armed.insert(session.id)
                seen.remove(session.id)
                updated.pending = false
            } else {
                let finished = session.state == .idle || session.state == .ended
                updated.pending = finished
                    && armed.contains(session.id)
                    && !seen.contains(session.id)
            }
            return updated
        }
    }
}
