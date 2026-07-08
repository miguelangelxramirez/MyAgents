import XCTest
@testable import MyAgentsMacCore

/// Orchestration tests for `TerminalFocuser.focus`: the mapping from (terminal, marker, side-effect
/// outcome) to a `TerminalFocusResult`, using injected fakes for the two side effects (the live
/// osascript / NSRunningApplication round-trip is Miguel's manual test — see CONTEXT §5).
///
/// They bite: e.g. make the scriptable branch return `.focusedWindow` instead of `.focusedTab`, or
/// let an unknown terminal fall through to Terminal.app, and the assertions fail.
final class TerminalFocuserTests: XCTestCase {

    /// Captures what the injected side effects were asked to do (reference type so an `@Sendable`
    /// closure can record into it; `focus` runs synchronously here so no real concurrency).
    private final class Spy: @unchecked Sendable {
        var lastScript: String?
        var scriptOutcome: Result<String, Error> = .success("tab")
        var activatedTargets: [TerminalAppTarget] = []
        var appIsRunning = true
    }

    private func makeFocuser(_ spy: Spy) -> TerminalFocuser {
        TerminalFocuser(
            runScript: { source in spy.lastScript = source; return spy.scriptOutcome },
            activate: { target in spy.activatedTargets.append(target); return spy.appIsRunning }
        )
    }

    private func session(host: String, tag: String) -> Session {
        Session(id: "s", terminalHost: host, titleTag: tag)
    }

    // MARK: - Tab-capable

    func testAppleTerminal_withMarker_scriptSelectsTab_isFocusedTab() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let result = makeFocuser(spy).focus(session: session(host: "Apple_Terminal", tag: "MyAgents ⟦cc:1fd1ff1c⟧"))
        XCTAssertEqual(result, .focusedTab)
        XCTAssertTrue(spy.lastScript?.contains(#"tell application "Terminal""#) ?? false)
        XCTAssertTrue(spy.lastScript?.contains("1fd1ff1c") ?? false, "the marker must reach the script")
    }

    func testScriptRunsButNoTabMatched_isAppActivatedOnly() {
        let spy = Spy(); spy.scriptOutcome = .success("app")
        let result = makeFocuser(spy).focus(session: session(host: "iTerm.app", tag: "MyAgents ⟦cc:abcd⟧"))
        XCTAssertEqual(result, .appActivatedOnly)
        XCTAssertTrue(spy.lastScript?.contains(#"tell application "iTerm2""#) ?? false)
    }

    func testGhostty_routesToGhosttyScript() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        _ = makeFocuser(spy).focus(session: session(host: "ghostty", tag: "MyAgents ⟦cc:abcd⟧"))
        XCTAssertTrue(spy.lastScript?.contains(#"tell application "Ghostty""#) ?? false)
    }

    func testScriptFailure_isFailedScriptError_neverCrashes() {
        let spy = Spy(); spy.scriptOutcome = .failure(TerminalFocusError.osascriptFailed(status: 1, message: "not authorized"))
        let result = makeFocuser(spy).focus(session: session(host: "Apple_Terminal", tag: "MyAgents ⟦cc:abcd⟧"))
        XCTAssertEqual(result, .failed(reason: .scriptError))
    }

    func testTooShortMarker_degradesToActivateOnly_notAWrongTabMatch() {
        // A 1-char marker would match almost any tab title; the focuser must NOT build a match
        // script with it — it activates the app instead.
        let spy = Spy(); spy.scriptOutcome = .success("app")
        let result = makeFocuser(spy).focus(session: session(host: "Apple_Terminal", tag: "x"))
        XCTAssertEqual(result, .appActivatedOnly)
        let script = spy.lastScript ?? ""
        XCTAssertFalse(script.contains("set theMarker"), "no marker-matching for an unsafe short marker")
        XCTAssertTrue(script.contains("activate"))
    }

    func testEmptyMarker_stillBringsTheAppForward() {
        let spy = Spy(); spy.scriptOutcome = .success("app")
        let result = makeFocuser(spy).focus(session: session(host: "iTerm.app", tag: ""))
        XCTAssertEqual(result, .appActivatedOnly)
        XCTAssertFalse(spy.lastScript?.contains("set theMarker") ?? true)
    }

    // MARK: - Window-only

    func testWarp_running_isFocusedWindow_viaActivateNotScript() {
        let spy = Spy(); spy.appIsRunning = true
        let result = makeFocuser(spy).focus(session: session(host: "WarpTerminal", tag: "irrelevant"))
        XCTAssertEqual(result, .focusedWindow)
        XCTAssertEqual(spy.activatedTargets, [.warp])
        XCTAssertNil(spy.lastScript, "window-only terminals must NOT run AppleScript")
    }

    func testVSCode_notRunning_isFailedAppNotRunning() {
        let spy = Spy(); spy.appIsRunning = false
        let result = makeFocuser(spy).focus(session: session(host: "vscode", tag: "irrelevant"))
        XCTAssertEqual(result, .failed(reason: .appNotRunning))
    }

    // MARK: - Unsupported

    func testUnknownTerminal_isFailedUnsupported_withNoSideEffects() {
        let spy = Spy()
        let result = makeFocuser(spy).focus(session: session(host: "kitty", tag: "MyAgents ⟦cc:abcd⟧"))
        XCTAssertEqual(result, .failed(reason: .unsupportedTerminal))
        XCTAssertNil(spy.lastScript)
        XCTAssertTrue(spy.activatedTargets.isEmpty, "an unknown terminal must not activate a guessed app")
    }
}
