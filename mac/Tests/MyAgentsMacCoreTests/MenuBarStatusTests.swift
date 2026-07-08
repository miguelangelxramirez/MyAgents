import XCTest
@testable import MyAgentsMacCore

/// `MenuBarStatus.evaluate` is the single source of truth for the glyph and, via `shouldAnimate`,
/// for the energy law. These tests bite: flip the priority so busy outranks attention, or let
/// `shouldAnimate` return true when idle, and they fail immediately.
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

    func testAnyPermission_winsOverBusy_andIsAttentionNotAnimated() {
        let sessions = [
            session("busy", .thinking, provider: .codex),
            session("perm", .permission),
        ]
        let status = MenuBarStatus.evaluate(sessions)
        XCTAssertEqual(status.kind, .attention)
        XCTAssertFalse(status.shouldAnimate, "attention is a steady glyph, not an animated one")
        XCTAssertNil(status.busyProvider)
    }

    func testBusy_whenNoAttention_animates_andCarriesFirstBusyProvider() {
        // Idle first, then a codex busy, then a claude busy — the FIRST busy (codex) wins the tint.
        let sessions = [
            session("idle", .idle),
            session("codex-busy", .tool, provider: .codex),
            session("claude-busy", .thinking, provider: .claude),
        ]
        let status = MenuBarStatus.evaluate(sessions)
        XCTAssertEqual(status.kind, .busy)
        XCTAssertTrue(status.shouldAnimate, "energy law: busy is the only animated state")
        XCTAssertEqual(status.busyProvider, .codex)
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
