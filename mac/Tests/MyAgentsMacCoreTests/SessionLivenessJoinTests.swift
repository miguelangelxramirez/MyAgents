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

    // MARK: - Per-folder collapse of pid-less duplicates (the macOS "ghost permission" fix)

    private func date(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

    func testPidLessDuplicatesInOneFolder_collapseToTheNewest() {
        // The exact macOS shape: three orphan files for the same folder (pid:0 → nil), one live
        // process there. Before the fix all three showed; now only the freshest survives.
        let cwd = "/Users/me/TravelApp"
        let old = Session(id: "old", cwd: cwd, provider: .claude, state: .permission, updatedAt: date(100), ownerPid: nil)
        let mid = Session(id: "mid", cwd: cwd, provider: .claude, state: .idle, updatedAt: date(200), ownerPid: nil)
        let live = Session(id: "live", cwd: cwd, provider: .claude, state: .thinking, updatedAt: date(300), ownerPid: nil)
        let processes = [process(pid: 42, provider: .claude, cwd: cwd)]

        let result = SessionLivenessJoin.join(sessions: [old, mid, live], liveProcesses: processes, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.id), ["live"], "only the newest file for the folder survives — the stale ghosts are dropped")
    }

    func testCollapse_dropsAFrozenPermissionGhostBehindALiveSession() {
        // Regression for the reported bug: a dead sibling frozen on `.permission` must not surface
        // when the folder's live session is calm.
        let cwd = "/Users/me/proj"
        let ghost = Session(id: "ghost", cwd: cwd, provider: .claude, state: .permission, updatedAt: date(10), ownerPid: nil)
        let liveIdle = Session(id: "liveIdle", cwd: cwd, provider: .claude, state: .idle, updatedAt: date(999), ownerPid: nil)
        let processes = [process(pid: 7, provider: .claude, cwd: cwd)]

        let result = SessionLivenessJoin.join(sessions: [ghost, liveIdle], liveProcesses: processes, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.id), ["liveIdle"])
        XCTAssertFalse(result.contains { $0.needsAttention }, "no phantom 'Awaiting permission' row must remain")
    }

    func testCollapse_keepsDistinctFoldersAndDistinctProviders() {
        // Same folder but different providers is NOT a duplicate; different folders are never merged.
        let a = Session(id: "a", cwd: "/proj-a", provider: .claude, updatedAt: date(1), ownerPid: nil)
        let b = Session(id: "b", cwd: "/proj-b", provider: .claude, updatedAt: date(1), ownerPid: nil)
        let c = Session(id: "c", cwd: "/proj-a", provider: .codex, updatedAt: date(1), ownerPid: nil)
        let processes = [
            process(pid: 1, provider: .claude, cwd: "/proj-a"),
            process(pid: 2, provider: .claude, cwd: "/proj-b"),
            process(pid: 3, provider: .codex, cwd: "/proj-a"),
        ]

        let result = SessionLivenessJoin.join(sessions: [a, b, c], liveProcesses: processes, isAlive: { _ in false })

        XCTAssertEqual(Set(result.map(\.id)), ["a", "b", "c"], "only same provider+cwd collapses")
    }

    func testCollapse_pidFulDuplicatesInOneFolder_areBothKept() {
        // On a platform that DOES record pids, two real sessions in one folder are distinguishable
        // and must both stay — the collapse only touches the pid-less (macOS) rows.
        let s1 = Session(id: "s1", cwd: "/proj", provider: .claude, updatedAt: date(1), ownerPid: 10)
        let s2 = Session(id: "s2", cwd: "/proj", provider: .claude, updatedAt: date(2), ownerPid: 11)

        let result = SessionLivenessJoin.join(sessions: [s1, s2], liveProcesses: [], isAlive: { $0 == 10 || $0 == 11 })

        XCTAssertEqual(Set(result.map(\.id)), ["s1", "s2"])
    }

    func testCollapse_missingTimestampLosesToARecordedOne() {
        // A file with no `ts` (updatedAt nil) must never win over one that has a timestamp.
        let cwd = "/proj"
        let noTs = Session(id: "noTs", cwd: cwd, provider: .claude, state: .permission, updatedAt: nil, ownerPid: nil)
        let withTs = Session(id: "withTs", cwd: cwd, provider: .claude, state: .idle, updatedAt: date(5), ownerPid: nil)
        let processes = [process(pid: 1, provider: .claude, cwd: cwd)]

        let result = SessionLivenessJoin.join(sessions: [noTs, withTs], liveProcesses: processes, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.id), ["withTs"], "a timestamped session beats a timestamp-less one regardless of input order")
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

    // MARK: - Subagent nesting (the "phantom codex tile" fix)

    private func entry(_ ppid: Int32, _ comm: String) -> ProcessLiveness.ProcessTableEntry {
        ProcessLiveness.ProcessTableEntry(ppid: ppid, comm: comm)
    }

    func testSubagent_incrementsParentDiscoveredRow_andAddsNoRowOfItsOwn() {
        // codex(100) ← zsh(150) ← codex(200 = the parent session, itself interactive). The parent
        // is a process-discovered row (ownerPid 200); the subagent folds into it, no tile of its own.
        let parent = process(pid: 200, provider: .codex, cwd: "/proj")
        let subagent = process(pid: 100, provider: .codex, cwd: "/proj")
        let table: [Int32: ProcessLiveness.ProcessTableEntry] = [
            100: entry(150, "codex"),
            150: entry(200, "zsh"),
            200: entry(1, "codex"),
        ]

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: [parent, subagent], processTable: table, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.ownerPid), [200], "only the parent is a row — the subagent is not")
        XCTAssertEqual(result.first?.subagentCount, 1)
        XCTAssertFalse(result.contains { $0.ownerPid == 100 }, "the codex exec subagent must never surface as its own tile")
    }

    func testSubagent_resolvesParentByPidlessProviderAndCwd() {
        // The macOS-Claude case: the parent session row is PID-LESS (hooks can't record a pid),
        // matched by provider+cwd. The subagent's parent process (claude 200 at /proj) must resolve
        // to that row and bump it.
        let claudeRow = Session(id: "s1", cwd: "/proj", provider: .claude, ownerPid: nil)
        let parent = process(pid: 200, provider: .claude, cwd: "/proj")
        let subagent = process(pid: 100, provider: .codex, cwd: "/proj")
        let table: [Int32: ProcessLiveness.ProcessTableEntry] = [
            100: entry(150, "codex"),
            150: entry(200, "zsh"),
            200: entry(180, "claude"),
            180: entry(1, "Terminal"),
        ]

        let result = SessionLivenessJoin.join(sessions: [claudeRow], liveProcesses: [parent, subagent], processTable: table, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.id), ["s1"], "the pid-less claude session is the only row")
        XCTAssertEqual(result.first?.subagentCount, 1)
        XCTAssertFalse(result.contains { $0.ownerPid == 100 }, "the subagent must not be a row")
    }

    func testTwoSubagentsUnderOneParent_countTwo() {
        let parent = process(pid: 200, provider: .codex, cwd: "/proj")
        let sub1 = process(pid: 100, provider: .codex, cwd: "/proj")
        let sub2 = process(pid: 101, provider: .codex, cwd: "/proj")
        let table: [Int32: ProcessLiveness.ProcessTableEntry] = [
            100: entry(200, "codex"),
            101: entry(200, "codex"),
            200: entry(1, "codex"),
        ]

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: [parent, sub1, sub2], processTable: table, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.ownerPid), [200])
        XCTAssertEqual(result.first?.subagentCount, 2)
    }

    func testOrphanSubagent_isDroppedEntirely() {
        // codex(100) ← MyAgentsMac(50): the app's own usage helper — no row, counted nowhere.
        let orphan = process(pid: 100, provider: .codex, cwd: "/proj")
        let table: [Int32: ProcessLiveness.ProcessTableEntry] = [
            100: entry(50, "codex"),
            50: entry(1, "MyAgentsMac"),
        ]

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: [orphan], processTable: table, isAlive: { _ in false })

        XCTAssertTrue(result.isEmpty, "an app-owned orphan codex must be hidden completely")
    }

    func testInteractiveProcess_stillBecomesADiscoveredRow_withNoSubagentCount() {
        // codex(100) ← zsh(90) ← Terminal(1): a genuine standalone session — a normal tile, count 0.
        let interactive = process(pid: 100, provider: .codex, cwd: "/proj")
        let table: [Int32: ProcessLiveness.ProcessTableEntry] = [
            100: entry(90, "zsh"),
            90: entry(1, "Terminal"),
        ]

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: [interactive], processTable: table, isAlive: { _ in false })

        XCTAssertEqual(result.map(\.ownerPid), [100])
        XCTAssertEqual(result.first?.subagentCount, 0)
    }

    func testEmptyProcessTable_preservesExactlyThePreNestingBehavior() {
        // With no ancestry map every process is interactive — the join must behave identically to
        // before nesting existed (default-arg path, exercised by every legacy test above).
        let a = process(pid: 100, provider: .codex, cwd: "/proj-a")
        let b = process(pid: 200, provider: .claude, cwd: "/proj-b")

        let result = SessionLivenessJoin.join(sessions: [], liveProcesses: [a, b], isAlive: { _ in false })

        XCTAssertEqual(Set(result.map(\.ownerPid)), [100, 200])
        XCTAssertTrue(result.allSatisfy { $0.subagentCount == 0 })
    }
}
