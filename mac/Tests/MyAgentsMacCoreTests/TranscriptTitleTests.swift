import XCTest
@testable import MyAgentsMacCore

/// Hostile-input coverage for `TranscriptTitle` (METODOLOGIA §4). Every scenario uses a throwaway
/// temp file — never the real `~/.claude`, which may not exist at all on the machine running
/// these tests. These tests bite: e.g. drop the `maxLines` cap (or set it absurdly high) and
/// `testAITitleBeyondCap_isNotFound` starts failing; stop caching and
/// `testCache_returnsSameValueEvenAfterFileChanges` fails because the second call would read the
/// mutated file instead of the cached title.
final class TranscriptTitleTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func write(_ lines: [String], named name: String) throws -> String {
        let file = tempDirectory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    // MARK: - Happy path

    func testValidAITitleLine_isFound() throws {
        let path = try write([
            #"{"type":"summary","text":"irrelevant"}"#,
            #"{"type":"ai-title","aiTitle":"Fix the folder-duplication bug"}"#,
            #"{"type":"user","content":"hello"}"#,
        ], named: "valid.jsonl")

        let sut = TranscriptTitle()
        XCTAssertEqual(sut.title(sessionId: "s1", transcriptPath: path), "Fix the folder-duplication bug")
    }

    func testMultipleLines_titleNearTop_isFound() throws {
        var lines = [#"{"type":"ai-title","aiTitle":"Refactor session store"}"#]
        lines.append(contentsOf: (0..<50).map { #"{"type":"assistant-turn","n":\#($0)}"# })
        let path = try write(lines, named: "near-top.jsonl")

        let sut = TranscriptTitle()
        XCTAssertEqual(sut.title(sessionId: "s2", transcriptPath: path), "Refactor session store")
    }

    // MARK: - Negative cases — all must return nil, never throw/crash

    func testNoAITitleLine_returnsNil() throws {
        let path = try write([
            #"{"type":"user","content":"hi"}"#,
            #"{"type":"assistant","content":"hello back"}"#,
        ], named: "no-title.jsonl")

        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "s3", transcriptPath: path))
    }

    func testMissingFile_returnsNil() {
        let sut = TranscriptTitle()
        let missingPath = tempDirectory.appendingPathComponent("does-not-exist.jsonl").path
        XCTAssertNil(sut.title(sessionId: "s4", transcriptPath: missingPath))
    }

    func testEmptyTranscriptPath_returnsNil() {
        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "s5", transcriptPath: ""))
    }

    func testEmptySessionId_returnsNilWithoutTouchingDisk() throws {
        let path = try write([#"{"type":"ai-title","aiTitle":"Should never be read"}"#], named: "ignored.jsonl")
        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "", transcriptPath: path))
    }

    func testMalformedJSONLine_isSkipped_validLineStillFound() throws {
        let path = try write([
            #"{ this line mentions ai-title but is not valid json }}}"#,
            #"{"type":"ai-title","aiTitle":"Real title after garbage"}"#,
        ], named: "malformed.jsonl")

        let sut = TranscriptTitle()
        XCTAssertEqual(sut.title(sessionId: "s6", transcriptPath: path), "Real title after garbage")
    }

    func testLineContainingSubstringButWrongType_isIgnored() throws {
        // Contains the substring "ai-title" but the JSON object's "type" isn't "ai-title" — must
        // not be mistaken for a real title line.
        let path = try write([
            #"{"type":"note","text":"this mentions ai-title in passing","aiTitle":"decoy"}"#,
        ], named: "decoy.jsonl")

        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "s7", transcriptPath: path))
    }

    func testAITitleBeyondCap_isNotFound() throws {
        // 200 filler lines before the real ai-title line — well past the 150-line head cap, so it
        // must NOT be found (mirrors the Windows reference's `MaxLines`).
        var lines = (0..<200).map { #"{"type":"filler","n":\#($0)}"# }
        lines.append(#"{"type":"ai-title","aiTitle":"Too deep to find"}"#)
        let path = try write(lines, named: "too-deep.jsonl")

        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "s8", transcriptPath: path))
    }

    func testBlankAITitleValue_isTreatedAsNoTitle() throws {
        let path = try write([#"{"type":"ai-title","aiTitle":"   "}"#], named: "blank.jsonl")
        let sut = TranscriptTitle()
        XCTAssertNil(sut.title(sessionId: "s9", transcriptPath: path))
    }

    // MARK: - Cache

    func testCache_returnsSameValueEvenAfterFileChanges() throws {
        let path = try write([#"{"type":"ai-title","aiTitle":"Original title"}"#], named: "cached.jsonl")
        let sut = TranscriptTitle()

        XCTAssertEqual(sut.title(sessionId: "cached-session", transcriptPath: path), "Original title")

        // Mutate the file on disk — a real second read would see this, but the cache must win.
        try #"{"type":"ai-title","aiTitle":"Changed title"}"#.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            sut.title(sessionId: "cached-session", transcriptPath: path),
            "Original title",
            "titles are cached per session id and never re-read once found"
        )
    }

    func testNoTitleFound_isNotCached_retriesOnNextCall() throws {
        let path = try write([#"{"type":"user","content":"no title yet"}"#], named: "retry.jsonl")
        let sut = TranscriptTitle()

        XCTAssertNil(sut.title(sessionId: "retry-session", transcriptPath: path))

        // Claude Code writes the ai-title line a moment later — a subsequent poll must find it,
        // proving a miss wasn't cached as a permanent nil.
        try (#"{"type":"user","content":"no title yet"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Arrived late"}"#)
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        XCTAssertEqual(sut.title(sessionId: "retry-session", transcriptPath: path), "Arrived late")
    }
}
