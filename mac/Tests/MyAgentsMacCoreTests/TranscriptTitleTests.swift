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

    func testNoTitleAnywhereInTheHead_isAFinalMiss_neverReRead() throws {
        // The other half of the miss contract, and the reason it exists: when a scan consumes the
        // WHOLE 150-line head without finding a title, the answer is settled — a transcript is
        // append-only, so those 150 lines can never change. Re-reading them on every 0.5s poll is
        // exactly what made a 100 MB transcript ruinous to poll.
        //
        // Proof that no second read happens: the file is rewritten with a title at line 1, and the
        // next call must STILL say nil. (A real transcript can't be rewritten like this; a scanner
        // that re-read the file would return "Impossible" and fail here.)
        let path = try write((0..<200).map { #"{"type":"filler","n":\#($0)}"# }, named: "final-miss.jsonl")
        let sut = TranscriptTitle()

        XCTAssertNil(sut.title(sessionId: "final-miss", transcriptPath: path))

        try #"{"type":"ai-title","aiTitle":"Impossible"}"#.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        XCTAssertNil(
            sut.title(sessionId: "final-miss", transcriptPath: path),
            "a miss over the full head window is final — the transcript must never be read again"
        )
    }

    func testTranscriptThatDoesNotExistYet_isNotAPermanentMiss_titleAppearsOnceItIsCreated() throws {
        // REGRESSION (external review, 2026-07-12). The hook can publish a session's transcript PATH
        // before Claude Code has created the file. An earlier version of the miss cache used `-1` as
        // "couldn't stat the file" AND as "window fully scanned, never look again" — the same value —
        // so a not-yet-created transcript was written off FOREVER and the session was stuck showing
        // its folder name for the rest of the app's life. An unreadable file must cache NOTHING.
        let path = tempDirectory.appendingPathComponent("not-yet.jsonl").path
        let sut = TranscriptTitle()

        XCTAssertNil(sut.title(sessionId: "late", transcriptPath: path), "the file doesn't exist yet")

        try #"{"type":"ai-title","aiTitle":"Created a moment later"}"#
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            sut.title(sessionId: "late", transcriptPath: path),
            "Created a moment later",
            "a transcript that didn't exist yet must be picked up as soon as it does"
        )
    }

    /// Codex audit MED #7: the per-session cache must be prunable to the live session set so it can't
    /// grow for every session ever seen. After pruning a session away, its cached title is gone — a
    /// subsequent lookup re-reads the file (here proven by the file being deleted meanwhile: the
    /// cached value would have survived, a pruned one is gone). Bites: make `prune` a no-op and the
    /// title is still returned from cache.
    func testPrune_dropsEntriesNotInLiveSet_soCacheDoesNotLeak() throws {
        let path = try write([#"{"type":"ai-title","aiTitle":"Cached then pruned"}"#], named: "prune.jsonl")
        let sut = TranscriptTitle()

        XCTAssertEqual(sut.title(sessionId: "gone-session", transcriptPath: path), "Cached then pruned")

        // The session is no longer live, and its transcript is deleted.
        sut.prune(keepingSessionIds: ["some-other-live-session"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))

        XCTAssertNil(
            sut.title(sessionId: "gone-session", transcriptPath: path),
            "a pruned session's title must not survive in the cache"
        )
    }

    /// Pruning must KEEP entries whose ids are still live.
    func testPrune_keepsEntriesStillInLiveSet() throws {
        let path = try write([#"{"type":"ai-title","aiTitle":"Still live"}"#], named: "keep.jsonl")
        let sut = TranscriptTitle()

        XCTAssertEqual(sut.title(sessionId: "live-session", transcriptPath: path), "Still live")

        sut.prune(keepingSessionIds: ["live-session"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))

        XCTAssertEqual(
            sut.title(sessionId: "live-session", transcriptPath: path),
            "Still live",
            "a kept session's title stays cached even after the file is gone"
        )
    }

    func testHugePastedLineInTheHead_doesNotHideTheTitle() throws {
        // A pasted image is a single multi-megabyte line. It can't be a title, so it must be walked
        // past and discarded — not buffered, and not allowed to swallow the title after it.
        let path = try write([
            String(repeating: "x", count: 2_000_000),
            #"{"type":"ai-title","aiTitle":"Behind the blob"}"#,
        ], named: "blob.jsonl")

        let sut = TranscriptTitle()
        XCTAssertEqual(sut.title(sessionId: "blob-session", transcriptPath: path), "Behind the blob")
    }
}
