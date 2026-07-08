import XCTest
@testable import MyAgentsMacCore

/// The title marker is derived from a project name → treat it as HOSTILE. These tests prove the
/// escaping neutralizes an AppleScript-injection attempt: after escaping, a marker CANNOT terminate
/// the string literal it's interpolated into, so the payload can never become executable script.
///
/// They bite: make `AppleScriptString.escaped` a no-op (return the raw string) and every
/// "no unescaped quote" / "no control char" assertion below fails.
final class AppleScriptEscapingTests: XCTestCase {
    func testDoubleQuote_isEscaped_soItCannotCloseTheLiteral() {
        let escaped = AppleScriptString.escaped(#"a"b"#)
        XCTAssertEqual(escaped, #"a\"b"#)
        XCTAssertFalse(containsUnescapedQuote(escaped), "an unescaped quote would break out of the literal")
    }

    func testBackslash_isDoubled() {
        XCTAssertEqual(AppleScriptString.escaped(#"a\b"#), #"a\\b"#)
    }

    func testBackslashBeforeQuote_bothEscaped_stillNoBreakout() {
        // Naive "escape quotes only" would leave `\"` → the backslash escapes our escape and the
        // quote closes the literal. Escaping the backslash first prevents that.
        let escaped = AppleScriptString.escaped(#"\""#)
        XCTAssertEqual(escaped, #"\\\""#)
        XCTAssertFalse(containsUnescapedQuote(escaped))
    }

    func testControlCharacters_areDropped() {
        let hostile = "a\nb\tc\r\u{7F}d\u{00}e"
        let escaped = AppleScriptString.escaped(hostile)
        XCTAssertEqual(escaped, "abcde")
        XCTAssertFalse(escaped.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
    }

    func testFullInjectionPayload_staysInsideTheStringLiteral() throws {
        // The classic breakout: close the string, then run a shell command.
        let payload = #"x" & (do shell script "rm -rf ~") & ""#
        let escaped = AppleScriptString.escaped(payload)
        XCTAssertFalse(containsUnescapedQuote(escaped),
                       "no bare quote may survive — otherwise `do shell script` would execute")

        // And embedded in the real Terminal script, the payload appears only as an escaped literal.
        let src = try XCTUnwrap(TerminalFocusScript.build(strategy: .appleTerminal, titleTag: payload))
        XCTAssertTrue(src.contains(#"set theMarker to "\#(escaped)""#),
                      "the marker must be interpolated exactly as the escaped literal")
        // The interpolated line must be the ONLY place a `do shell script` substring appears, and it
        // is inside quotes — never as a standalone statement.
        XCTAssertEqual(occurrences(of: "do shell script", in: src), 1)
    }

    func testLegitimateUnicodeMarker_survivesUnchanged() {
        // The real markers look like `MyAgents ⟦cc:1fd1ff1c⟧` — escaping must not mangle them.
        let marker = "MyAgents ⟦cc:1fd1ff1c⟧"
        XCTAssertEqual(AppleScriptString.escaped(marker), marker)
    }

    // MARK: - Helpers

    /// A quote is "unescaped" if it is not immediately preceded by an ODD number of backslashes.
    private func containsUnescapedQuote(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        for (i, scalar) in scalars.enumerated() where scalar == "\"" {
            var backslashes = 0
            var j = i - 1
            while j >= 0, scalars[j] == "\\" { backslashes += 1; j -= 1 }
            if backslashes % 2 == 0 { return true }
        }
        return false
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
