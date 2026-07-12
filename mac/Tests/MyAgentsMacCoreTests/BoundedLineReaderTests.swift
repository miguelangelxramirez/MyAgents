import XCTest
@testable import MyAgentsMacCore

/// Coverage for `BoundedLineReader`, the streaming head-reader that replaced two hand-rolled chunked
/// readers after they pegged a CPU core in the shipped app (2026-07-12: 113% CPU, 353 min of CPU
/// time, `sample(1)` showing 2258/2259 samples inside the old `readLines`).
///
/// These tests bite on each of the three defects that caused it:
/// - reinstate the EAGER read (materialize all `maxLines` lines before the caller looks at any) and
///   `testStopsAtTheLineTheCallerWants_neverReadsPastIt` fails on its call count;
/// - remove the over-long line ceiling and `testOverlongLine_isSkipped_notDelivered` fails (and the
///   multi-megabyte case starts buffering 6 MB to find a 20-byte name);
/// - collapse the `.lineLimit` / `.endOfFile` distinction and
///   `testStop_lineLimitVsEndOfFile_tellsAFinalMissFromARetryableOne` fails — that distinction is
///   what lets `TranscriptTitle` cache a miss forever instead of re-reading a 100 MB file every poll.
final class BoundedLineReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedLineReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ contents: String, named name: String = "file.txt") throws -> URL {
        let file = tempDirectory.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Early exit: work must be proportional to the lines the caller actually needs

    func testStopsAtTheLineTheCallerWants_neverReadsPastIt() throws {
        // The real shape from this machine's rollouts: the interesting line is #6, but the window is
        // 60 lines deep. The body must be handed exactly 6 lines — not 60.
        let lines = (1...60).map { "line-\($0)" }
        let file = try write(lines.joined(separator: "\n") + "\n")

        var seen: [String] = []
        let stop = BoundedLineReader.forEachLine(of: file, maxLines: 60) { line in
            seen.append(line)
            return line == "line-6" ? .stop : .continue
        }

        XCTAssertEqual(stop, .callerStopped)
        XCTAssertEqual(seen.count, 6, "a caller that stops at line 6 must never be handed lines 7...60")
        XCTAssertEqual(seen.last, "line-6")
    }

    func testHead_collectsUpToMaxLines_inOrder() throws {
        let file = try write((1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n")
        XCTAssertEqual(BoundedLineReader.head(of: file, maxLines: 3), ["line-1", "line-2", "line-3"])
    }

    func testMaxLines_boundsHowDeepTheScanLooks() throws {
        let lines = (1...200).map { "line-\($0)" }
        let file = try write(lines.joined(separator: "\n") + "\n")

        let head = BoundedLineReader.head(of: file, maxLines: 150)

        XCTAssertEqual(head.count, 150)
        XCTAssertEqual(head.last, "line-150", "line 151+ is past the window and must never be read")
    }

    // MARK: - The 5.2 MB line: the exact shape that pegged the CPU

    func testOverlongLine_isSkipped_notDelivered() throws {
        // A pasted image / huge tool result is a single multi-megabyte line. It can never be a
        // session name (capped at ~90 chars) or an ai-title, so it must be walked past and
        // DISCARDED — never accumulated, never handed to the caller.
        let monster = String(repeating: "x", count: 300_000)
        let file = try write(["first", monster, "after-the-monster"].joined(separator: "\n") + "\n")

        let head = BoundedLineReader.head(of: file, maxLines: 10, maxLineBytes: 64 * 1024)

        XCTAssertEqual(head, ["first", "after-the-monster"], "the over-long line is skipped, the ones around it survive")
    }

    func testOverlongLine_stillCountsTowardMaxLines() throws {
        // It IS a line of the file, so it must still bound how deep we look — otherwise a file full
        // of monsters would be walked end to end.
        let monster = String(repeating: "x", count: 300_000)
        let file = try write([monster, "second", "third"].joined(separator: "\n") + "\n")

        let head = BoundedLineReader.head(of: file, maxLines: 2, maxLineBytes: 64 * 1024)

        XCTAssertEqual(head, ["second"], "the skipped monster consumed one of the two allowed lines")
    }

    func testMultiMegabyteLine_beforeTheTargetLine_isWalkedPastCheaply() throws {
        // The full production shape: a 6 MB blob sits between the caller and the line it wants. The
        // old quadratic reader re-scanned its whole accumulated buffer once per 8 KiB chunk here
        // (gigabytes of byte-walking, twice a second). This must resolve promptly and correctly; if
        // the quadratic buffering ever comes back, this test slows to a crawl.
        let blob = String(repeating: "z", count: 6_000_000)
        let file = try write(["head", blob, "the-prompt"].joined(separator: "\n") + "\n")

        var seen: [String] = []
        let stop = BoundedLineReader.forEachLine(of: file, maxLines: 60) { line in
            seen.append(line)
            return line == "the-prompt" ? .stop : .continue
        }

        XCTAssertEqual(stop, .callerStopped)
        XCTAssertEqual(seen, ["head", "the-prompt"], "the 6 MB line is never materialized, and the line after it is still found")
    }

    func testByteBudget_isAHardCeiling_neverReadsPastIt() throws {
        // REGRESSION (external review, 2026-07-12): the reader used to ask for a FULL chunk even when
        // fewer bytes of budget remained, then process all of it — so a line living beyond `maxBytes`
        // could still be delivered and the scan could report `.lineLimit` instead of `.byteLimit`.
        // The ceiling has to actually be a ceiling.
        let file = try write("aaaa\nbbbb\ncccc\ndddd\n") // 5 bytes per line

        var seen: [String] = []
        let stop = BoundedLineReader.forEachLine(of: file, maxLines: 100, maxBytes: 10, chunkSize: 8192) { line in
            seen.append(line)
            return .continue
        }

        XCTAssertEqual(seen, ["aaaa", "bbbb"], "only the lines fully inside the 10-byte budget may be delivered")
        XCTAssertEqual(stop, .byteLimit, "and the scan must say WHY it stopped — a byte-budget stop is not a settled window")
    }

    func testByteBudget_stopsAPathologicalFile() throws {
        // One enormous line and nothing else: `maxLines` alone can't bound this, so the byte budget
        // must.
        let file = try write(String(repeating: "q", count: 900_000))

        let stop = BoundedLineReader.forEachLine(of: file, maxLines: 60, maxBytes: 64 * 1024) { _ in .continue }

        XCTAssertEqual(stop, .byteLimit)
    }

    // MARK: - Stop reasons — these drive the miss caching in TranscriptTitle

    func testStop_lineLimitVsEndOfFile_tellsAFinalMissFromARetryableOne() throws {
        let short = try write("only-line\n", named: "short.txt")
        let long = try write((1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n", named: "long.txt")

        // Fewer lines than the window: the file could still grow into it, so a miss here is retryable.
        XCTAssertEqual(BoundedLineReader.forEachLine(of: short, maxLines: 5) { _ in .continue }, .endOfFile)
        // The window was consumed in full: an append-only file's head can never change, so a miss
        // here is final.
        XCTAssertEqual(BoundedLineReader.forEachLine(of: long, maxLines: 5) { _ in .continue }, .lineLimit)
    }

    func testMissingFile_isUnreadable_neverThrows() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist.txt")
        XCTAssertEqual(BoundedLineReader.forEachLine(of: missing, maxLines: 10) { _ in .continue }, .unreadable)
        XCTAssertEqual(BoundedLineReader.head(of: missing, maxLines: 10), [])
    }

    // MARK: - Line-splitting edge cases

    func testFinalLineWithoutTrailingNewline_isStillDelivered() throws {
        // A file being appended to right now may not have flushed its last newline — the C#
        // reference's StreamReader still returns that line, so this must too.
        let file = try write("first\nsecond-no-newline")
        XCTAssertEqual(BoundedLineReader.head(of: file, maxLines: 10), ["first", "second-no-newline"])
    }

    func testLineSpanningManyChunks_isReassembledIntact() throws {
        // A line far longer than one chunk must come back whole, not split at the chunk boundary.
        let long = String(repeating: "ab", count: 10_000) // 20 KB, chunk is 4 KB below
        let file = try write("short\n\(long)\ntail\n")

        let head = BoundedLineReader.head(of: file, maxLines: 10, chunkSize: 4096)

        XCTAssertEqual(head.count, 3)
        XCTAssertEqual(head[1], long, "a line spanning several chunks must be reassembled exactly")
        XCTAssertEqual(head[2], "tail")
    }

    func testEmptyFile_yieldsNoLines() throws {
        let file = try write("")
        XCTAssertEqual(BoundedLineReader.head(of: file, maxLines: 10), [])
    }

    func testBlankLines_arePreservedAsEmptyStrings() throws {
        let file = try write("a\n\nb\n")
        XCTAssertEqual(BoundedLineReader.head(of: file, maxLines: 10), ["a", "", "b"])
    }

    func testMaxLinesZero_readsNothing() throws {
        let file = try write("a\nb\n")
        XCTAssertEqual(BoundedLineReader.head(of: file, maxLines: 0), [])
    }
}
