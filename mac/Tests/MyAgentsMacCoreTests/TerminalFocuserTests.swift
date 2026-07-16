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

    private func session(host: String, tag: String, title: String = "") -> Session {
        Session(id: "s", terminalHost: host, titleTag: tag, displayName: title)
    }

    // MARK: - Tab-exact by tty (Codex sessions, discovered by process)

    func testAppleTerminal_withTty_matchesTabByTty_notTitle() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let session = Session(id: "s", terminalHost: "Apple_Terminal", displayName: "codex", tty: "/dev/ttys009")
        let result = makeFocuser(spy).focus(session: session)
        XCTAssertEqual(result, .focusedTab)
        let script = try! XCTUnwrap(spy.lastScript)
        XCTAssertTrue(script.contains("tty of t"), "must match the Terminal tab by its tty")
        XCTAssertTrue(script.contains(#"is "/dev/ttys009""#), "the exact tty must reach the script")
        XCTAssertFalse(script.contains("contains"), "tty match is exact, never a fuzzy title contains")
    }

    func testITerm_withTty_matchesSessionByTty() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let session = Session(id: "s", terminalHost: "iTerm.app", tty: "/dev/ttys009")
        _ = makeFocuser(spy).focus(session: session)
        let script = try! XCTUnwrap(spy.lastScript)
        XCTAssertTrue(script.contains(#"tell application "iTerm2""#))
        XCTAssertTrue(script.contains("tty of s"), "iTerm exposes tty on the session")
    }

    func testTty_takesPrecedenceOverTitleMarker() {
        let spy = Spy()
        let session = Session(id: "s", terminalHost: "Apple_Terminal", titleTag: "⟦cc:1fd1ff1c⟧", displayName: "Some Long Title", tty: "/dev/ttys004")
        _ = makeFocuser(spy).focus(session: session)
        let script = try! XCTUnwrap(spy.lastScript)
        XCTAssertTrue(script.contains(#"is "/dev/ttys004""#))
        XCTAssertFalse(script.contains("1fd1ff1c"), "with a tty present, the title marker is not used")
    }

    func testGhosttyWithTty_fallsBackToTitleOrActivate_noTtyScript() {
        // Ghostty exposes no tty over AppleScript, so `buildByTTY` returns nil and we degrade to the
        // title path (here empty → activate only). It must NOT emit a bogus `tty of` script.
        let spy = Spy()
        let session = Session(id: "s", terminalHost: "Ghostty", tty: "/dev/ttys009")
        _ = makeFocuser(spy).focus(session: session)
        let script = try! XCTUnwrap(spy.lastScript)
        XCTAssertTrue(script.contains(#"tell application "Ghostty""#))
        XCTAssertFalse(script.contains("tty of"), "Ghostty has no scriptable tty")
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
        XCTAssertFalse(script.contains("contains"), "no marker-matching for an unsafe short marker")
        XCTAssertTrue(script.contains("activate"))
    }

    func testEmptyMarker_stillBringsTheAppForward() {
        let spy = Spy(); spy.scriptOutcome = .success("app")
        let result = makeFocuser(spy).focus(session: session(host: "iTerm.app", tag: ""))
        XCTAssertEqual(result, .appActivatedOnly)
        XCTAssertFalse(spy.lastScript?.contains("contains") ?? true)
    }

    // MARK: - Title (aiTitle) as the PRIMARY match key (root-cause fix)

    /// Root cause of "clicking a row does nothing": Terminal.app's `custom title` is Claude's
    /// task-summary title (aiTitle) with a leading status glyph, e.g.
    /// `"⠐ Adapt Windows app to macOS with menu bar design"` — it never contains the `titleTag`
    /// marker. The focus script must match on the plain aiTitle with a CONTAINS clause, which
    /// tolerates that leading glyph/whitespace since it only needs to appear AS A SUBSTRING of the
    /// real tab title, not equal it.
    func testTitleMatch_usesDisplayNameAsPrimaryMarker_toleratingLeadingGlyph() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let aiTitle = "Adapt Windows app to macOS with menu bar design"
        let result = makeFocuser(spy).focus(session: session(host: "Apple_Terminal", tag: "", title: aiTitle))
        XCTAssertEqual(result, .focusedTab)
        let script = spy.lastScript ?? ""
        XCTAssertTrue(script.contains(#"contains "\#(aiTitle)""#),
                       "the plain aiTitle (no glyph) must be the CONTAINS marker — a real tab title "
                       + "like '⠐ \(aiTitle)' contains it as a substring")
    }

    /// When the transcript title hasn't resolved (empty `displayName`), the focuser must still be
    /// able to match via the secondary `titleTag` marker — never silently give up on the title path
    /// entirely.
    func testEmptyDisplayName_fallsBackToTitleTagMarker() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let result = makeFocuser(spy).focus(session: session(host: "Apple_Terminal", tag: "MyAgents ⟦cc:1fd1ff1c⟧", title: ""))
        XCTAssertEqual(result, .focusedTab)
        XCTAssertTrue(spy.lastScript?.contains("1fd1ff1c") ?? false)
    }

    /// Both keys present: the built condition ORs them together, so a terminal that stamped only
    /// the marker (not the aiTitle) still matches.
    func testBothTitleAndTitleTagPresent_conditionMatchesEither() {
        let spy = Spy(); spy.scriptOutcome = .success("tab")
        let result = makeFocuser(spy).focus(session: session(host: "iTerm.app", tag: "MyAgents ⟦cc:1fd1ff1c⟧", title: "Adapt Windows app"))
        XCTAssertEqual(result, .focusedTab)
        let script = spy.lastScript ?? ""
        XCTAssertTrue(script.contains(#"contains "Adapt Windows app""#))
        XCTAssertTrue(script.contains("1fd1ff1c"))
        XCTAssertTrue(script.contains(" or "), "both markers must be OR-ed in a single condition")
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
