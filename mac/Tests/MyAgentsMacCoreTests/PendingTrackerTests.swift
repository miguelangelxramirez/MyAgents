import XCTest
@testable import MyAgentsMacCore

/// The pending-dot rule as a pure reducer. These bite: drop the `armed` requirement (a
/// never-busy idle session would falsely go pending), drop the `seen` check (clicking wouldn't
/// clear it), or drop the `seen.remove` on busy (a re-run wouldn't re-arm the dot).
final class PendingTrackerTests: XCTestCase {
    private func s(_ id: String, _ state: SessionActivityState) -> Session {
        Session(id: id, state: state)
    }

    private func pending(_ sessions: [Session], _ id: String) -> Bool {
        sessions.first { $0.id == id }?.pending ?? false
    }

    func testNeverBusy_idleSession_isNotPending() {
        var tracker = PendingTracker()
        let out = tracker.apply(to: [s("a", .idle)])
        XCTAssertFalse(pending(out, "a"), "a session we never saw busy has no finished-result to flag")
    }

    func testBusyThenIdle_unseen_isPending() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking)])
        let out = tracker.apply(to: [s("a", .idle)])
        XCTAssertTrue(pending(out, "a"), "busy → idle without a click is the classic pending case")
    }

    func testBusyThenEnded_unseen_isPending() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .tool)])
        let out = tracker.apply(to: [s("a", .ended)])
        XCTAssertTrue(pending(out, "a"))
    }

    func testStillBusy_isNotPending() {
        var tracker = PendingTracker()
        let out = tracker.apply(to: [s("a", .thinking)])
        XCTAssertFalse(pending(out, "a"), "a working session is not a finished-but-unopened one")
    }

    func testClicked_clearsPending() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking)])
        _ = tracker.apply(to: [s("a", .idle)])   // now pending
        tracker.markSeen("a")
        let out = tracker.apply(to: [s("a", .idle)])
        XCTAssertFalse(pending(out, "a"), "clicking marks it seen → dot clears")
    }

    func testGoingBusyAgain_afterClick_reArmsTheDot() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking)])
        _ = tracker.apply(to: [s("a", .idle)])
        tracker.markSeen("a")
        _ = tracker.apply(to: [s("a", .idle)])   // cleared
        // It goes busy again…
        _ = tracker.apply(to: [s("a", .tool)])
        // …and finishes again → the dot must return even though it was seen before.
        let out = tracker.apply(to: [s("a", .idle)])
        XCTAssertTrue(pending(out, "a"), "a fresh busy→idle cycle re-arms the pending dot after a prior click")
    }

    func testPermissionState_isNotPending_evenWhenArmed() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking)])
        let out = tracker.apply(to: [s("a", .permission)])
        XCTAssertFalse(pending(out, "a"), "awaiting-permission is active, not finished — no pending dot")
    }

    func testDisappearedSession_isPruned_soStateCannotGrowUnbounded() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking)])
        _ = tracker.apply(to: [])                 // 'a' gone → pruned
        // 'a' reappears fresh (new run, never observed busy this time) → must NOT be pending.
        let out = tracker.apply(to: [s("a", .idle)])
        XCTAssertFalse(pending(out, "a"), "arm state for a vanished id must be dropped, not resurrected")
    }

    func testIndependentSessions_trackedSeparately() {
        var tracker = PendingTracker()
        _ = tracker.apply(to: [s("a", .thinking), s("b", .thinking)])
        let out = tracker.apply(to: [s("a", .idle), s("b", .thinking)])
        XCTAssertTrue(pending(out, "a"))
        XCTAssertFalse(pending(out, "b"), "b is still busy")
    }
}
