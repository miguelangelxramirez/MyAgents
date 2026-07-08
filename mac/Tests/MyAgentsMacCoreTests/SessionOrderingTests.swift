import XCTest
@testable import MyAgentsMacCore

/// `SessionOrdering.attentionFirst` must rank permission > busy (thinking/tool) > idle > ended,
/// and break ties by recency. These tests bite: swap the rank table (e.g. make `.idle` outrank
/// `.permission`) or drop the recency tie-break and the ordering assertions fail immediately.
final class SessionOrderingTests: XCTestCase {
    private func session(
        _ id: String,
        state: SessionActivityState,
        secondsAgo: TimeInterval?,
        now: Date
    ) -> Session {
        Session(id: id, state: state, updatedAt: secondsAgo.map { now.addingTimeInterval(-$0) })
    }

    func testHostileMix_permissionBeatsBusyBeatsIdleBeatsEnded_recencyBreaksTies() {
        let now = Date()
        // Deliberately hostile ordering on input: worst-ranked-but-newest first, to prove the
        // sort isn't just "leave already-sorted input alone".
        let ended = session("ended-but-newest-timestamp", state: .ended, secondsAgo: 1, now: now)
        let idleNoTimestamp = session("idle-no-timestamp", state: .idle, secondsAgo: nil, now: now)
        let idleWithTimestamp = session("idle-with-timestamp", state: .idle, secondsAgo: 100, now: now)
        let toolOlder = session("tool-older", state: .tool, secondsAgo: 500, now: now)
        let thinkingNewer = session("thinking-newer", state: .thinking, secondsAgo: 10, now: now)
        let permissionOlder = session("permission-older", state: .permission, secondsAgo: 1000, now: now)
        let permissionNewest = session("permission-newest", state: .permission, secondsAgo: 5, now: now)

        let input = [ended, idleNoTimestamp, idleWithTimestamp, toolOlder, thinkingNewer, permissionOlder, permissionNewest]
        let ordered = SessionOrdering.attentionFirst(input, now: now)

        XCTAssertEqual(ordered.map(\.id), [
            "permission-newest",
            "permission-older",
            "thinking-newer",
            "tool-older",
            "idle-with-timestamp",
            "idle-no-timestamp",
            "ended-but-newest-timestamp",
        ])
    }

    func testSingleSession_isTrivialOrder() {
        let now = Date()
        let only = session("only", state: .idle, secondsAgo: 0, now: now)
        XCTAssertEqual(SessionOrdering.attentionFirst([only], now: now).map(\.id), ["only"])
    }

    func testEmptyInput_returnsEmpty() {
        XCTAssertEqual(SessionOrdering.attentionFirst([]), [])
    }

    func testAllSameRankAndNoTimestamps_preservesOriginalRelativeOrder() {
        let now = Date()
        let a = session("a", state: .idle, secondsAgo: nil, now: now)
        let b = session("b", state: .idle, secondsAgo: nil, now: now)
        let c = session("c", state: .idle, secondsAgo: nil, now: now)
        XCTAssertEqual(SessionOrdering.attentionFirst([a, b, c], now: now).map(\.id), ["a", "b", "c"])
    }
}
