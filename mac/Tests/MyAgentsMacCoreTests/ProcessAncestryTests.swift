import XCTest
@testable import MyAgentsMacCore

/// `ProcessLiveness.classifyAncestry` decides — purely from a synthetic `[pid: (ppid, comm)]` map,
/// spawning nothing — whether a discovered agent process is a standalone INTERACTIVE session, a
/// SUBAGENT nested under another session, or an ORPHAN owned by the app / ChatGPT. This is the fix
/// for the "phantom codex tile" bug: a `codex exec` subprocess must fold into its parent session,
/// never surface as its own un-focusable tile.
///
/// These tests bite: make the walk stop at the first ancestor instead of climbing past shells and
/// `testCodexUnderZshUnderLoginUnderTerminal_isInteractive` breaks; drop the cycle guard and the
/// cycle test hangs; forget the depth cap and the deep-chain test regresses.
final class ProcessAncestryTests: XCTestCase {
    private typealias Entry = ProcessLiveness.ProcessTableEntry

    /// Builds an ancestry map from `pid: (ppid, comm)` triples.
    private func table(_ rows: [(pid: Int32, ppid: Int32, comm: String)]) -> [Int32: Entry] {
        var map: [Int32: Entry] = [:]
        for row in rows { map[row.pid] = Entry(ppid: row.ppid, comm: row.comm) }
        return map
    }

    // MARK: - The three canonical shapes (verified live on the real machine)

    func testCodexUnderClaude_isSubagentOfThatClaude() {
        // codex ← zsh ← claude ← … : the real "delegated work" shape.
        let map = table([
            (100, 90, "codex"),
            (90, 50, "zsh"),
            (50, 40, "claude"),
            (40, 20, "zsh"),
            (20, 1, "Terminal"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .subagent(parentPid: 50))
    }

    func testCodexUnderZshUnderLoginUnderTerminal_isInteractive() {
        // codex ← -zsh ← login ← Terminal : a genuine interactive session — no agent/app owner on
        // the way up, so it stays a normal tile.
        let map = table([
            (100, 90, "codex"),
            (90, 80, "-zsh"),
            (80, 70, "login"),
            (70, 1, "Terminal"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .interactive)
    }

    func testCodexUnderMyAgentsMac_isOrphan() {
        // codex ← MyAgentsMac : the app's OWN usage helper — must be hidden, not shown as a session.
        let map = table([
            (100, 50, "codex"),
            (50, 1, "MyAgentsMac"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .orphan)
    }

    func testCodexUnderChatGPT_isOrphan() {
        let map = table([
            (100, 50, "codex"),
            (50, 1, "ChatGPT"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .orphan)
    }

    func testChatGPTHelperSuffix_isStillANonSessionOwner() {
        // Non-session owners are matched with suffixes allowed (helper processes, case-insensitive).
        let map = table([
            (100, 50, "codex"),
            (50, 1, "ChatGPT Helper (GPU)"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .orphan)
    }

    // MARK: - Nearest owner wins

    func testNearestAgentBeatsAFartherAppOwner() {
        // codex ← claude ← MyAgentsMac : the CLAUDE is nearer, so this is that claude's subagent —
        // the app owner farther up must not turn it into an orphan.
        let map = table([
            (100, 50, "codex"),
            (50, 30, "claude"),
            (30, 1, "MyAgentsMac"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .subagent(parentPid: 50))
    }

    func testNearestAppOwnerBeatsAFartherAgent() {
        // codex ← MyAgentsMac ← claude : the app owns it directly, so it's an orphan even though a
        // claude sits farther up the tree.
        let map = table([
            (100, 50, "codex"),
            (50, 30, "MyAgentsMac"),
            (30, 1, "claude"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .orphan)
    }

    func testAgentAncestorRecognized_forArchSuffixedCodexName() {
        // A native codex parent self-names "codex-aarch64-apple-darwin" — still an agent ancestor.
        let map = table([
            (100, 50, "codex"),
            (50, 1, "codex-aarch64-apple-darwin"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .subagent(parentPid: 50))
    }

    // MARK: - Depth, cycles, and missing data (hostile maps)

    func testDeepButWithinCapChain_stillFindsTheAgentParent() {
        // A long transparent shell chain (well under the 64 cap) must still resolve to the claude
        // at its top.
        var rows: [(pid: Int32, ppid: Int32, comm: String)] = [(1000, 999, "codex")]
        for pid in stride(from: Int32(999), through: 941, by: -1) {
            rows.append((pid, pid - 1, "zsh"))
        }
        rows.append((940, 1, "claude"))
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 1000, in: table(rows)), .subagent(parentPid: 940))
    }

    func testCycleInAncestry_terminates_asInteractive() {
        // A ← B ← A (both transparent shells): the walk must not loop forever; with no owner found
        // it settles on interactive.
        let map = table([
            (100, 200, "codex"),
            (200, 100, "zsh"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .interactive)
    }

    func testMissingParentEntry_isInteractive() {
        // The process's ppid points at a pid that isn't in the map (parent exited / another user) —
        // ancestry lost, so it's treated as a standalone session, never guessed as a subagent.
        let map = table([
            (100, 777, "codex"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .interactive)
    }

    func testMissingSelfEntry_orPpidZero_isInteractive() {
        // No entry for the process at all (ppid resolves to 0) — nothing to climb, interactive.
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: [:]), .interactive)

        let mapWithZeroPpid = table([(100, 0, "codex")])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: mapWithZeroPpid), .interactive)
    }

    func testReachingLaunchdPid1_isInteractive() {
        // Climbing all the way to pid 1 (launchd) with no owner en route is the definition of a
        // standalone session.
        let map = table([
            (100, 50, "codex"),
            (50, 1, "bash"),
        ])
        XCTAssertEqual(ProcessLiveness.classifyAncestry(pid: 100, in: map), .interactive)
    }
}
