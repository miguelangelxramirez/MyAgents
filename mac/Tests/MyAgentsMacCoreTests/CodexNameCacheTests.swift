import XCTest
@testable import MyAgentsMacCore

/// Coverage for `CodexNameCache`'s core safety invariant: never guess a name across an ambiguous
/// cwd. These tests bite: e.g. drop the `idsByCwd[key]?.count == 1` guard in `name(forCwd:)` (or
/// replace it with `>= 1`) and `testTwoSessionsShareCwd_returnsNil` starts failing (it would
/// return one of the two names instead of `nil`); stop recording ids for empty names and
/// `testEmptyNameStillCountsTowardAmbiguity` fails.
final class CodexNameCacheTests: XCTestCase {
    func testSingleSession_nameIsReturned() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "Fix the login bug")
        XCTAssertEqual(cache.name(forCwd: "/Users/me/project"), "Fix the login bug")
    }

    func testUnknownCwd_returnsNil() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "Fix the login bug")
        XCTAssertNil(cache.name(forCwd: "/Users/me/other-project"))
    }

    func testTwoSessionsShareCwd_returnsNil_neverGuesses() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/shared", sessionId: "s1", name: "First session's prompt")
        cache.record(cwd: "/Users/me/shared", sessionId: "s2", name: "Second session's prompt")
        XCTAssertNil(cache.name(forCwd: "/Users/me/shared"), "two distinct sessions in one cwd is ambiguous — must never guess")
    }

    func testRecordingSameSessionIdAgain_doesNotManufactureAmbiguity() {
        // A later poll re-scans the SAME still-open session — recording its id again must not
        // make the cwd look ambiguous.
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "Fix the login bug")
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "Fix the login bug")
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "Fix the login bug")
        XCTAssertEqual(cache.name(forCwd: "/Users/me/project"), "Fix the login bug")
    }

    func testEmptyNameStillCountsTowardAmbiguity() {
        // Session 1 hasn't produced a name yet (empty), session 2 has — the cwd is still shared
        // by two DISTINCT ids, so this must stay ambiguous even though only one name was ever set.
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/shared", sessionId: "s1", name: "")
        cache.record(cwd: "/Users/me/shared", sessionId: "s2", name: "Real prompt")
        XCTAssertNil(cache.name(forCwd: "/Users/me/shared"))
    }

    func testNoNameYet_returnsNil_notEmptyString() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project", sessionId: "s1", name: "")
        XCTAssertNil(cache.name(forCwd: "/Users/me/project"))
    }

    func testNormalize_trimsWhitespaceAndTrailingSlash_soBothFormsHitTheSameKey() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project/", sessionId: "s1", name: "Trailing slash form")
        XCTAssertEqual(cache.name(forCwd: "/Users/me/project"), "Trailing slash form")
        XCTAssertEqual(cache.name(forCwd: "  /Users/me/project/  "), "Trailing slash form")
    }

    func testEmptySessionId_isIgnored_neverRecorded() {
        let cache = CodexNameCache()
        cache.record(cwd: "/Users/me/project", sessionId: "", name: "Should not be recorded")
        XCTAssertNil(cache.name(forCwd: "/Users/me/project"))
    }
}
