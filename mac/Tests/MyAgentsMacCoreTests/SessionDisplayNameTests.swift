import XCTest
@testable import MyAgentsMacCore

/// `SessionDisplayName.resolve` is the pure logic that fixes the reported bug: a session row
/// showing the folder name TWICE (title line AND folder line) because an empty hook `name` fell
/// back straight to the folder. These tests bite: revert the "name == folder → placeholder"
/// branch to "return name/folder anyway" and `testEmptyName_neverFallsBackToFolder` /
/// `testNameEqualsFolder_doesNotDuplicate_fallsBackToPlaceholder` fail immediately; drop the
/// `aiTitle` priority and `testAITitle_winsOverEverything` fails.
final class SessionDisplayNameTests: XCTestCase {
    // MARK: - aiTitle wins over everything

    func testAITitle_winsOverEverything() {
        let resolved = SessionDisplayName.resolve(aiTitle: "Fix login bug", name: "raw prompt text", folder: "MyAgents")
        XCTAssertEqual(resolved, "Fix login bug")
    }

    func testAITitle_winsEvenWhenNameIsEmpty() {
        let resolved = SessionDisplayName.resolve(aiTitle: "Fix login bug", name: "", folder: "MyAgents")
        XCTAssertEqual(resolved, "Fix login bug")
    }

    func testBlankAITitle_isIgnored_fallsThroughToName() {
        let resolved = SessionDisplayName.resolve(aiTitle: "   ", name: "Refactor scanner", folder: "MyAgents")
        XCTAssertEqual(resolved, "Refactor scanner")
    }

    func testNilAITitle_fallsThroughToName() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "Refactor scanner", folder: "MyAgents")
        XCTAssertEqual(resolved, "Refactor scanner")
    }

    // MARK: - The bug: empty/duplicate name must NEVER become the folder

    func testEmptyName_neverFallsBackToFolder() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "", folder: "MyAgents")
        XCTAssertNotEqual(resolved, "MyAgents", "an empty name must resolve to the placeholder, never the folder")
        XCTAssertEqual(resolved, String(localized: "session.untitled", defaultValue: "New session"))
    }

    func testWhitespaceOnlyName_isTreatedAsEmpty() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "   ", folder: "MyAgents")
        XCTAssertNotEqual(resolved, "MyAgents")
        XCTAssertEqual(resolved, String(localized: "session.untitled", defaultValue: "New session"))
    }

    func testNameEqualsFolder_doesNotDuplicate_fallsBackToPlaceholder() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "MyAgents", folder: "MyAgents")
        XCTAssertNotEqual(resolved, "MyAgents")
        XCTAssertEqual(resolved, String(localized: "session.untitled", defaultValue: "New session"))
    }

    func testNameEqualsFolder_caseInsensitive_stillDoesNotDuplicate() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "myagents", folder: "MyAgents")
        XCTAssertNotEqual(resolved.lowercased(), "myagents")
    }

    func testNameDifferentFromFolder_isUsedAsIs() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "Add dark mode support", folder: "MyAgents")
        XCTAssertEqual(resolved, "Add dark mode support")
    }

    func testEverythingEmpty_returnsPlaceholder_neverEmptyString() {
        let resolved = SessionDisplayName.resolve(aiTitle: nil, name: "", folder: "")
        XCTAssertFalse(resolved.isEmpty, "resolve() must never return an empty string — empty is the sentinel for 'not yet resolved'")
    }
}
