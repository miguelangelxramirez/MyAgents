import XCTest
@testable import MyAgentsMacCore

/// The permission banner must fire on the RISING EDGE only — once per request, not once per poll.
/// These tests bite: drop the `previous != .permission` guard (fire every poll) or forget to
/// forget vanished sessions (a reappearing request never re-fires) and they fail.
final class PermissionNotificationDetectorTests: XCTestCase {
    private func session(_ id: String, _ state: SessionActivityState) -> Session {
        Session(id: id, state: state)
    }

    func testFiresOnceOnTransitionIntoPermission_thenNotAgainWhileStillPermission() {
        var detector = PermissionNotificationDetector()

        // Poll 1: session is thinking — no fire.
        XCTAssertEqual(detector.newlyAwaitingPermission([session("s1", .thinking)]).map(\.id), [])
        // Poll 2: it enters permission — fires.
        XCTAssertEqual(detector.newlyAwaitingPermission([session("s1", .permission)]).map(\.id), ["s1"])
        // Poll 3: still permission (human hasn't answered) — must NOT fire again.
        XCTAssertEqual(detector.newlyAwaitingPermission([session("s1", .permission)]).map(\.id), [])
    }

    func testNewSessionAppearingAlreadyInPermission_fires() {
        var detector = PermissionNotificationDetector()
        XCTAssertEqual(detector.newlyAwaitingPermission([session("fresh", .permission)]).map(\.id), ["fresh"])
    }

    func testAnswered_thenAsksAgain_firesAgain() {
        var detector = PermissionNotificationDetector()
        _ = detector.newlyAwaitingPermission([session("s1", .permission)])   // fire 1
        _ = detector.newlyAwaitingPermission([session("s1", .tool)])          // answered → working
        XCTAssertEqual(
            detector.newlyAwaitingPermission([session("s1", .permission)]).map(\.id), ["s1"],
            "a second, distinct permission request must fire again"
        )
    }

    func testVanishedThenReappearsInPermission_firesAgain() {
        var detector = PermissionNotificationDetector()
        _ = detector.newlyAwaitingPermission([session("s1", .permission)])   // fire 1
        _ = detector.newlyAwaitingPermission([])                             // process died, dropped
        XCTAssertEqual(
            detector.newlyAwaitingPermission([session("s1", .permission)]).map(\.id), ["s1"],
            "a session forgotten then seen again in permission is a new edge"
        )
    }

    func testMultipleSimultaneousTransitions_allFire() {
        var detector = PermissionNotificationDetector()
        let fired = detector.newlyAwaitingPermission([
            session("a", .permission),
            session("b", .idle),
            session("c", .permission),
        ])
        XCTAssertEqual(Set(fired.map(\.id)), ["a", "c"])
    }

    func testPureTransitions_matchesStatefulWrapper() {
        // The static rule and the mutating wrapper must agree.
        let previous: [String: SessionActivityState] = ["s1": .thinking]
        let current = [session("s1", .permission), session("s2", .permission)]
        let (fired, next) = PermissionNotificationDetector.transitions(previous: previous, current: current)
        XCTAssertEqual(Set(fired), ["s1", "s2"])
        XCTAssertEqual(next, ["s1": .permission, "s2": .permission])
    }
}
