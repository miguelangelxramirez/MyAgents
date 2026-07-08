import XCTest
@testable import MyAgentsMacCore

/// Hostile-input coverage for `ClaudeUsageService` (METODOLOGIA §4). Every scenario injects a
/// throwaway temp file — never the real `~/.claude/statusbar/usage.json`. The bar these tests
/// hold: never a fabricated `0%`, a missing/malformed capture is `.unknown`, and an aged capture
/// is flagged `isStale` WITHOUT losing its real percentages.
final class ClaudeUsageServiceTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageServiceTests-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if let tempFile, FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }
        tempFile = nil
        try super.tearDownWithError()
    }

    private func write(_ contents: String) throws {
        try contents.write(to: tempFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Missing file

    func testMissingFile_returnsUnknown_neverFakeZero() {
        // tempFile was never created on disk.
        let service = ClaudeUsageService(fileURL: tempFile)
        let usage = service.fetch()

        XCTAssertEqual(usage, UsageInfo.unknown(provider: .claude))
        XCTAssertNil(usage.fiveHourPercent)
        XCTAssertNil(usage.sevenDayPercent)
    }

    // MARK: - Malformed JSON

    func testMalformedJSON_returnsUnknown() throws {
        try write("{ this is not valid json }}}")
        let service = ClaudeUsageService(fileURL: tempFile)
        XCTAssertEqual(service.fetch(), UsageInfo.unknown(provider: .claude))
    }

    func testEmptyFile_returnsUnknown() throws {
        try Data().write(to: tempFile)
        let service = ClaudeUsageService(fileURL: tempFile)
        XCTAssertEqual(service.fetch(), UsageInfo.unknown(provider: .claude))
    }

    func testValidJSONButNeitherBucketPresent_returnsUnknown() throws {
        // Right after `/clear`, or on a non-Pro/Max plan, statusline.js still writes a document —
        // just with both buckets absent. Must not be confused with a real (fresh) reading.
        try write(#"{"provider":"claude","source":"statusline","ts":1719400000}"#)
        let service = ClaudeUsageService(fileURL: tempFile)
        XCTAssertEqual(service.fetch(), UsageInfo.unknown(provider: .claude))
    }

    // MARK: - Valid capture: both buckets present

    func testValidCapture_bothBuckets_decodesExpectedFields() throws {
        let now = Int(Date().timeIntervalSince1970)
        try write("""
        {
          "provider": "claude",
          "source": "statusline",
          "five_hour": { "used_percent": 42.5, "reset_at": \(now + 3600) },
          "seven_day": { "used_percent": 10.0, "reset_at": \(now + 86_400) },
          "ts": \(now)
        }
        """)
        let service = ClaudeUsageService(fileURL: tempFile)
        let usage = service.fetch()

        XCTAssertEqual(usage.provider, .claude)
        XCTAssertEqual(usage.fiveHourPercent, 42.5)
        XCTAssertEqual(usage.sevenDayPercent, 10.0)
        XCTAssertNotNil(usage.fiveHourResetsAt)
        XCTAssertNotNil(usage.sevenDayResetsAt)
        XCTAssertFalse(usage.isStale, "a freshly captured reading must not be marked stale")
    }

    func testValidCapture_onlyFiveHourBucket_sevenDayStaysNil() throws {
        let now = Int(Date().timeIntervalSince1970)
        try write(#"{"five_hour":{"used_percent":5,"reset_at":\#(now + 100)},"ts":\#(now)}"#)
        let service = ClaudeUsageService(fileURL: tempFile)
        let usage = service.fetch()

        XCTAssertEqual(usage.fiveHourPercent, 5)
        XCTAssertNil(usage.sevenDayPercent)
    }

    // MARK: - Genuine 0% must not be confused with unknown

    func testGenuineZeroPercent_isPreserved_neverCollapsedToUnknown() throws {
        let now = Int(Date().timeIntervalSince1970)
        try write(#"{"five_hour":{"used_percent":0,"reset_at":0},"seven_day":{"used_percent":0,"reset_at":0},"ts":\#(now)}"#)
        let service = ClaudeUsageService(fileURL: tempFile)
        let usage = service.fetch()

        XCTAssertTrue(usage.hasFiveHourReading)
        XCTAssertTrue(usage.hasSevenDayReading)
        XCTAssertEqual(usage.fiveHourPercent, 0)
        XCTAssertEqual(usage.sevenDayPercent, 0)
    }

    // MARK: - Staleness: aged capture is flagged, NOT dropped

    func testAgedCapture_isFlaggedStale_butKeepsItsRealPercentages() throws {
        let old = Int(Date().timeIntervalSince1970) - 3600 // 1 hour old
        try write(#"{"five_hour":{"used_percent":77,"reset_at":0},"ts":\#(old)}"#)
        let service = ClaudeUsageService(fileURL: tempFile, stalenessThreshold: 600) // 10 minutes
        let usage = service.fetch()

        XCTAssertTrue(usage.isStale, "a 1-hour-old capture must be flagged stale under a 10-minute threshold")
        XCTAssertEqual(usage.fiveHourPercent, 77, "staleness must never drop the real percentage back to nil/0")
    }

    func testFreshCapture_underThreshold_isNotStale() throws {
        let now = Int(Date().timeIntervalSince1970)
        try write(#"{"five_hour":{"used_percent":30,"reset_at":0},"ts":\#(now)}"#)
        let service = ClaudeUsageService(fileURL: tempFile, stalenessThreshold: 600)
        XCTAssertFalse(service.fetch().isStale)
    }
}
