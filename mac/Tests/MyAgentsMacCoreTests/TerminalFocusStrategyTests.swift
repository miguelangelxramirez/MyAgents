import XCTest
@testable import MyAgentsMacCore

/// `TerminalFocusPlanner.strategy` is the single decision "which terminal can I focus, and how".
/// These bite: swap the tab-capable set with the window-only set, or drop the case-insensitive
/// normalization, and the assertions fail.
final class TerminalFocusStrategyTests: XCTestCase {
    func testTabCapableTerminals_getExactTabStrategies() {
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "Apple_Terminal"), .appleTerminal)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "iTerm.app"), .iterm)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "ghostty"), .ghostty)
    }

    func testTabCapableTerminals_exposeAScriptableAppName() {
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "Apple_Terminal").scriptableAppName, "Terminal")
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "iTerm.app").scriptableAppName, "iTerm2")
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "ghostty").scriptableAppName, "Ghostty")
    }

    func testWindowOnlyTerminals_mapToTheirApp_andHaveNoScriptName() {
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "WarpTerminal"), .windowOnly(.warp))
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "vscode"), .windowOnly(.vscode))
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "cursor"), .windowOnly(.cursor))

        // A window-only terminal must NOT be driven by AppleScript.
        XCTAssertNil(TerminalFocusPlanner.strategy(forTerminalHost: "WarpTerminal").scriptableAppName)
        XCTAssertNil(TerminalFocusPlanner.strategy(forTerminalHost: "vscode").scriptableAppName)
    }

    func testWindowOnlyTargets_carryStableBundleIDs() {
        // If these bundle IDs regress, click-to-focus silently activates nothing — pin them.
        XCTAssertTrue(TerminalAppTarget.warp.bundleIDs.contains("dev.warp.Warp-Stable"))
        XCTAssertTrue(TerminalAppTarget.vscode.bundleIDs.contains("com.microsoft.VSCode"))
        XCTAssertTrue(TerminalAppTarget.cursor.bundleIDs.contains("com.todesktop.230313mzl4w4u92"))
        // Name fallbacks exist for when a bundle ID drifts (Cursor's is generated).
        XCTAssertTrue(TerminalAppTarget.cursor.appNames.contains("Cursor"))
    }

    func testUnknownOrEmptyHost_isUnsupported_notAWrongGuess() {
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: ""), .unsupported)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "kitty"), .unsupported)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "WezTerm"), .unsupported)
    }

    func testHostMatching_isCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "  apple_terminal  "), .appleTerminal)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "ITERM.APP"), .iterm)
        XCTAssertEqual(TerminalFocusPlanner.strategy(forTerminalHost: "WARPTERMINAL"), .windowOnly(.warp))
    }
}
