import XCTest
@testable import MyAgentsMacCore

/// `MenuBarStatus.evaluate` is the single source of truth for the glyph and, via `shouldAnimate`
/// and `pulseFrameBudget`, for the energy law. These tests bite: flip the priority so busy outranks
/// attention, let `shouldAnimate` return true when idle, or — the regression that cost a measured
/// 6.7 % of a core — start animating a *working* session again, and they fail immediately.
final class MenuBarStatusTests: XCTestCase {
    private func session(_ id: String, _ state: SessionActivityState, provider: Provider = .claude) -> Session {
        Session(id: id, provider: provider, state: state)
    }

    func testEmpty_isIdle_andDoesNotAnimate() {
        let status = MenuBarStatus.evaluate([])
        XCTAssertEqual(status.kind, .idle)
        XCTAssertFalse(status.shouldAnimate, "energy law: idle must never animate")
        XCTAssertNil(status.busyProvider)
    }

    func testAnyPermission_winsOverBusy_andIsTheOneAnimatedState() {
        let sessions = [
            session("busy", .thinking, provider: .codex),
            session("perm", .permission),
        ]
        let status = MenuBarStatus.evaluate(sessions)
        XCTAssertEqual(status.kind, .attention)
        XCTAssertTrue(status.shouldAnimate, "a session waiting on a human is the only thing worth a pulse")
        XCTAssertNil(status.busyProvider)
    }

    func testBusy_whenNoAttention_isStatic_andCarriesFirstBusyProvider() {
        // Idle first, then a codex busy, then a claude busy — the FIRST busy (codex) wins the tint.
        let sessions = [
            session("idle", .idle),
            session("codex-busy", .tool, provider: .codex),
            session("claude-busy", .thinking, provider: .claude),
        ]
        let status = MenuBarStatus.evaluate(sessions)
        XCTAssertEqual(status.kind, .busy)
        XCTAssertFalse(
            status.shouldAnimate,
            "energy law: working can last hours — animating it burned 6.7% of a core for nothing"
        )
        XCTAssertEqual(status.busyProvider, .codex)
    }

    // MARK: - Pulse budget (the pulse is a doorbell, not a siren)

    func testOnlyAttentionGetsAFrameBudget() {
        for kind in MenuBarStatus.Kind.allCases {
            let budget = MenuBarStatus(kind: kind, busyProvider: nil).pulseFrameBudget(fps: 12)
            if kind == .attention {
                XCTAssertEqual(budget, 360, "30s of breath at 12fps")
            } else {
                XCTAssertEqual(budget, 0, "\(kind) must not be able to animate at all")
            }
        }
    }

    func testAttentionPulseIsBounded_soAnUnansweredPromptCannotPulseAllNight() {
        let attention = MenuBarStatus(kind: .attention, busyProvider: nil)
        let budget = attention.pulseFrameBudget(fps: 12)
        XCTAssertGreaterThan(budget, 0, "the pulse must actually ring")
        XCTAssertEqual(
            Double(budget) / 12,
            MenuBarStatus.attentionPulseWindow,
            accuracy: 0.5,
            "the budget IS the window — a pulse that outlives it is the bug this policy exists to prevent"
        )
    }

    func testZeroFps_yieldsNoBudget_ratherThanCrashingOrLoopingForever() {
        let attention = MenuBarStatus(kind: .attention, busyProvider: nil)
        XCTAssertEqual(attention.pulseFrameBudget(fps: 0), 0)
    }

    func testAllIdleOrEnded_isIdle() {
        let sessions = [session("a", .idle), session("b", .ended)]
        XCTAssertEqual(MenuBarStatus.evaluate(sessions).kind, .idle)
    }

    func testEachKindHasADistinctSymbol() {
        let symbols = MenuBarStatus.Kind.allCases.map {
            MenuBarStatus(kind: $0, busyProvider: nil).symbolName
        }
        XCTAssertEqual(Set(symbols).count, symbols.count, "each glyph state needs its own symbol")
    }
}
