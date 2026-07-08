import XCTest
@testable import MyAgentsMacCore

/// Hostile-input coverage for `SessionScanner` (METODOLOGIA §4: "estados de datos hostiles").
/// Every scenario here uses a throwaway temp directory injected into the scanner — never the
/// real `~/.claude`, which may not even exist on the machine running these tests (that absence
/// is itself the primary case, see `testMissingDirectory_returnsEmptyList`).
final class SessionScannerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyAgentsMacTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func write(_ contents: String, named name: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let file = tempDirectory.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private func writeRawBytes(_ bytes: [UInt8], named name: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let file = tempDirectory.appendingPathComponent(name)
        try Data(bytes).write(to: file)
    }

    // MARK: - Missing / empty directory (the primary hostile case on a clean machine)

    func testMissingDirectory_returnsEmptyList() {
        // tempDirectory was never created on disk — mirrors a machine that has never run the
        // Claude Code hooks, so ~/.claude/statusbar/sessions.d/ doesn't exist at all.
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }

    func testEmptyDirectory_returnsEmptyList() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }

    // MARK: - Corrupt / truncated JSON

    func testCorruptJSON_isSkippedNotThrown() throws {
        try write("{ this is not valid json at all }}}", named: "corrupt.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [], "a corrupt file must be skipped, not crash the scan")
    }

    func testTruncatedJSON_isSkipped() throws {
        // A realistic truncation: the writer got cut off mid-object (crash / disk full).
        try write(#"{"state":"thinking","provider":"claude","sessionId":"abc123","project":"my-r"#, named: "truncated.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }

    func testEmptyFile_isSkipped() throws {
        try writeRawBytes([], named: "empty.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }

    func testNonJSONExtension_isIgnored() throws {
        try write("not even trying to be json", named: "notes.txt")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }

    // MARK: - A valid session decodes with the right fields

    func testValidSession_decodesExpectedFields() throws {
        let json = """
        {
          "state": "tool",
          "provider": "claude",
          "name": "Refactor SessionScanner",
          "label": "Editing",
          "tool": "Edit",
          "project": "MyAgents",
          "cwd": "/Users/me/MyAgents",
          "host": "darwin",
          "sessionId": "sess-001",
          "pid": 4242,
          "startedAt": 1719400000,
          "ts": 1719400042
        }
        """
        try write(json, named: "sess-001.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        let sessions = scanner.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "sess-001")
        XCTAssertEqual(session.name, "Refactor SessionScanner")
        XCTAssertEqual(session.folder, "MyAgents")
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.state, .tool)
        XCTAssertEqual(session.toolLabel, "Editing")
        XCTAssertEqual(session.ownerPid, 4242)
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1719400000))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1719400042))
        XCTAssertFalse(session.pending)
    }

    func testSessionIdFallsBackToFileName_whenMissingFromJSON() throws {
        let json = #"{"state":"idle","provider":"codex","project":"other-repo"}"#
        try write(json, named: "fallback-id.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        let sessions = scanner.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "fallback-id")
        XCTAssertEqual(sessions.first?.provider, .codex)
    }

    func testUnknownStateValue_fallsBackToIdleInsteadOfSkippingFile() throws {
        // A future hook state we don't know about yet must not take an otherwise-good file down.
        let json = #"{"state":"quantum-flux","provider":"claude","sessionId":"future-state"}"#
        try write(json, named: "future-state.json")
        let scanner = SessionScanner(directoryURL: tempDirectory)
        let sessions = scanner.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .idle)
    }

    // MARK: - Mixed batch: corrupt files must not hide the valid ones

    func testMixedValidAndCorrupt_onlyValidOnesReturned() throws {
        try write(#"{"state":"idle","provider":"claude","sessionId":"good-1"}"#, named: "good-1.json")
        try write("{{{ garbage", named: "bad-1.json")
        try write(#"{"state":"permission","provider":"codex","sessionId":"good-2"}"#, named: "good-2.json")
        try writeRawBytes([], named: "bad-2.json")

        let scanner = SessionScanner(directoryURL: tempDirectory)
        let sessions = scanner.scanSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.id)), Set(["good-1", "good-2"]))
        XCTAssertTrue(sessions.contains { $0.id == "good-2" && $0.state.needsAttention })
    }

    // MARK: - Prove the scanner actually enforces "directory missing/unreadable" defensively

    func testFileMasqueradingAsDirectory_doesNotCrash() throws {
        // Create a plain FILE at the path the scanner expects to be a directory — the
        // `isDirectory` guard must reject this instead of the FileManager calls throwing up
        // through `scanSessions()`.
        try FileManager.default.createDirectory(
            at: tempDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not a directory".write(to: tempDirectory, atomically: true, encoding: .utf8)

        let scanner = SessionScanner(directoryURL: tempDirectory)
        XCTAssertEqual(scanner.scanSessions(), [])
    }
}
