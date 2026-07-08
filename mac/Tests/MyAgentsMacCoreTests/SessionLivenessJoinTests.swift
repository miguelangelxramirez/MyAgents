import XCTest
@testable import MyAgentsMacCore

/// `SessionLivenessJoin.join` decides which sessions are OPEN by matching against the live
/// process table. `isAlive` is injected with deterministic fakes throughout (never the real
/// `kill(pid, 0)` check) so these tests never depend on which real pids happen to be running on
/// the machine. These tests bite: flip the pid-liveness check, break the provider+cwd key (e.g.
/// drop the cwd normalization), or stop emitting discovered rows, and the corresponding assertion
/// fails.
final class SessionLivenessJoinTests: XCTestCase {
    private func process(pid: Int32, provider: Provider, cwd: String) -> ProcessLiveness.DiscoveredProcess {
        ProcessLiveness.DiscoveredProcess(pid: pid, provider: provider, cwd: cwd, executablePath: "")
    }

    func testSessionWithLiveOwnerPid_staysOpen() {
        let session = Session(id: "s1", provider: .claude, ownerPid: 111)

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: [], isAlive: { $0 == 111 })
        XCTAssertEqual(result.map(\.id), ["s1"])
    }

    func testSessionWithDeadOwnerPid_isRemoved() {
        let session = Session(id: "s1", provider: .claude, ownerPid: 111)

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: [], isAlive: { _ in false })
        XCTAssertTrue(result.isEmpty, "a session whose owning pid isn't alive must be dropped")
    }

    func testPidBasedLiveness_isIndependentOfTheProviderClassifiedList() {
        // The pid is alive, but `liveProcesses` (the claude/codex NAME-classified scan) doesn't
        // happen to include it — e.g. the hook already told us this pid is a Claude session, so
        // it must not ALSO have to pass the name/argv heuristic to count as open.
        let session = Session(id: "s1", provider: .claude, ownerPid: 111)

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: [], isAlive: { $0 == 111 })
        XCTAssertEqual(result.map(\.id), ["s1"], "a pid-based session must rely on isAlive, not membership in liveProcesses")
    }

    func testPidLessSession_matchesLiveProcessByProviderAndCwd() {
        let session = Session(id: "s1", cwd: "/Users/me/project", provider: .codex, ownerPid: nil)
        let live = [process(pid: 500, provider: .codex, cwd: "/Users/me/project")]

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: live, isAlive: { _ in false })
        XCTAssertEqual(result.map(\.id), ["s1"])
    }

    func testPidLessSession_toleratesTrailingSlashDifference() {
        let session = Session(id: "s1", cwd: "/Users/me/project/", provider: .codex, ownerPid: nil)
        let live = [process(pid: 500, provider: .codex, cwd: "/Users/me/project")]

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: live, isAlive: { _ in false })
        XCTAssertEqual(result.map(\.id), ["s1"], "trailing-slash cwd differences must not defeat the match")
    }

    func testPidLessSession_wrongProvider_isRemoved_processStillShowsUpDiscovered() {
        let session = Session(id: "s1", cwd: "/Users/me/project", provider: .claude, ownerPid: nil)
        let live = [process(pid: 500, provider: .codex, cwd: "/Users/me/project")]

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: live, isAlive: { _ in false })

        XCTAssertFalse(result.contains { $0.id == "s1" }, "provider must be part of the match key, not just cwd")
        XCTAssertTrue(result.contains { $0.ownerPid == 500 }, "the live codex process at that cwd is unclaimed, so it must surface as a discovered row")
    }

    func testPidLessSession_emptyCwd_neverMatchesAnything() {
        let session = Session(id: "s1", cwd: "", provider: .claude, ownerPid: nil)
        let live = [process(pid: 500, provider: .claude, cwd: "")]

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: live, isAlive: { _ in false })
        XCTAssertTrue(result.isEmpty, "an empty cwd must never be treated as a match key")
    }

    func testLiveProcessWithNoSessionRow_becomesDiscoveredIdleRow() throws {
        let live = [process(pid: 900, provider: .claude, cwd: "/Users/me/other-project")]

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: live, isAlive: { _ in false })

        XCTAssertEqual(result.count, 1)
        let discovered = try XCTUnwrap(result.first)
        XCTAssertEqual(discovered.ownerPid, 900)
        XCTAssertEqual(discovered.provider, .claude)
        XCTAssertEqual(discovered.folder, "other-project")
        XCTAssertEqual(discovered.state, .idle)
    }

    func testLiveProcessAlreadyClaimedByPidSession_doesNotAlsoAppearAsDiscovered() {
        let session = Session(id: "s1", provider: .claude, ownerPid: 111)
        let live = [process(pid: 111, provider: .claude, cwd: "/whatever")]

        let result = SessionLivenessJoin.join(sessions: [session], liveProcesses: live, isAlive: { $0 == 111 })
        XCTAssertEqual(result.count, 1, "the live process must not ALSO produce a duplicate discovered row")
    }

    func testHostileMix_deadRemoved_aliveKept_unmatchedDiscovered() {
        let aliveByPid = Session(id: "alive-pid", provider: .claude, ownerPid: 1)
        let deadByPid = Session(id: "dead-pid", provider: .claude, ownerPid: 2)
        let aliveByCwd = Session(id: "alive-cwd", cwd: "/proj-a", provider: .codex, ownerPid: nil)
        let deadByCwd = Session(id: "dead-cwd", cwd: "/proj-b", provider: .codex, ownerPid: nil)

        let live = [
            process(pid: 1, provider: .claude, cwd: "/does-not-matter"),
            process(pid: 3, provider: .codex, cwd: "/proj-a"),
            process(pid: 9, provider: .codex, cwd: "/proj-unclaimed"),
        ]

        let result = SessionLivenessJoin.join(sessions: [aliveByPid, deadByPid, aliveByCwd, deadByCwd], liveProcesses: live, isAlive: { $0 == 1 })

        XCTAssertEqual(Set(result.map(\.id)).count, 3) // alive-pid, alive-cwd, + 1 discovered
        XCTAssertTrue(result.contains { $0.id == "alive-pid" })
        XCTAssertTrue(result.contains { $0.id == "alive-cwd" })
        XCTAssertFalse(result.contains { $0.id == "dead-pid" })
        XCTAssertFalse(result.contains { $0.id == "dead-cwd" })
        XCTAssertTrue(result.contains { $0.ownerPid == 9 }, "the unclaimed live process must show up as discovered")
    }
}
