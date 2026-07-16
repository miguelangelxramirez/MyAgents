import XCTest
@testable import MyAgentsMacCore

/// `UsageInfo` must never fabricate a `0%` reading — a real zero and "we don't know yet" are
/// different facts, and the Windows reference (`UsageInfo.cs`) treats them as such via
/// `UsageStatus.Unknown`. These tests bite: flip `unknown(provider:)` to return `0` instead of
/// `nil` and every assertion here fails.
final class UsageInfoTests: XCTestCase {
    func testUnknown_hasNilPercentagesNeverZero() {
        let usage = UsageInfo.unknown(provider: .claude)

        XCTAssertNil(usage.fiveHourPercent, "unknown usage must be nil, not a fake 0%")
        XCTAssertNil(usage.sevenDayPercent, "unknown usage must be nil, not a fake 0%")
        XCTAssertNil(usage.fiveHourResetsAt)
        XCTAssertNil(usage.sevenDayResetsAt)
        XCTAssertNil(usage.capturedAt)
        XCTAssertFalse(usage.hasFiveHourReading)
        XCTAssertFalse(usage.hasSevenDayReading)
    }

    // MARK: - percent(from:) — the single funnel that enforces the 0...100 invariant

    func testPercent_acceptsGenuineNumbers() {
        XCTAssertEqual(UsageInfo.percent(from: NSNumber(value: 42.5)), 42.5)
        XCTAssertEqual(UsageInfo.percent(from: NSNumber(value: 0)), 0,
                       "a genuine numeric 0 is a real reading, not 'unknown'")
        XCTAssertEqual(UsageInfo.percent(from: NSNumber(value: 100)), 100)
    }

    func testPercent_rejectsBooleanParsedFromRealJSON() throws {
        // The exact bug shape: JSONSerialization turns `false`/`true` into an NSNumber (CFBoolean),
        // whose `doubleValue` is 0.0/1.0 — so the old code showed a forbidden fake 0%. This test
        // fails against that code and passes only once booleans are rejected.
        let boolObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(#"{"p": false, "q": true}"#.utf8)) as? [String: Any]
        )
        XCTAssertNil(UsageInfo.percent(from: boolObj["p"]), "a JSON `false` must never read as 0%")
        XCTAssertNil(UsageInfo.percent(from: boolObj["q"]))

        // Sanity: genuine numbers from the same JSON path still parse (incl. a real 0).
        let numObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(#"{"p": 0, "q": 55.5}"#.utf8)) as? [String: Any]
        )
        XCTAssertEqual(UsageInfo.percent(from: numObj["p"]), 0)
        XCTAssertEqual(UsageInfo.percent(from: numObj["q"]), 55.5)
    }

    func testPercent_rejectsOutOfRangeAndNonFinite() {
        XCTAssertNil(UsageInfo.percent(from: NSNumber(value: 1e100)),
                     "garbage that would overflow Int(percent.rounded()) must be rejected")
        XCTAssertNil(UsageInfo.percent(from: NSNumber(value: -1)))
        XCTAssertNil(UsageInfo.percent(from: NSNumber(value: 100.01)))
        XCTAssertNil(UsageInfo.percent(from: NSNumber(value: Double.nan)))
        XCTAssertNil(UsageInfo.percent(from: NSNumber(value: Double.infinity)))
    }

    func testPercent_rejectsNonNumbers() {
        XCTAssertNil(UsageInfo.percent(from: nil))
        XCTAssertNil(UsageInfo.percent(from: "50"))
        XCTAssertNil(UsageInfo.percent(from: ["x": 1]))
    }

    func testUnknown_preservesProvider() {
        XCTAssertEqual(UsageInfo.unknown(provider: .claude).provider, .claude)
        XCTAssertEqual(UsageInfo.unknown(provider: .codex).provider, .codex)
    }

    func testKnownReading_isDistinguishableFromUnknown() {
        let known = UsageInfo(
            provider: .claude,
            fiveHourPercent: 42,
            fiveHourResetsAt: Date(timeIntervalSinceNow: 3600),
            sevenDayPercent: 10,
            sevenDayResetsAt: Date(timeIntervalSinceNow: 86_400),
            capturedAt: Date()
        )

        XCTAssertTrue(known.hasFiveHourReading)
        XCTAssertTrue(known.hasSevenDayReading)
        XCTAssertEqual(known.fiveHourPercent, 42)
        XCTAssertNotEqual(known, UsageInfo.unknown(provider: .claude))
    }

    func testGenuineZeroPercent_isNotConfusedWithUnknown() {
        // A REAL 0% usage reading is a valid, meaningful value — distinct from "unknown". The
        // model must be able to represent it (hasFiveHourReading == true even though the value
        // itself is 0).
        let zero = UsageInfo(provider: .codex, fiveHourPercent: 0, sevenDayPercent: 0)
        XCTAssertTrue(zero.hasFiveHourReading)
        XCTAssertEqual(zero.fiveHourPercent, 0)
    }

    func testResetCountdown_derivedFromResetsAt() {
        let future = Date(timeIntervalSinceNow: 120)
        let usage = UsageInfo(provider: .claude, fiveHourResetsAt: future)
        let countdown = try? XCTUnwrap(usage.fiveHourResetCountdown)
        XCTAssertEqual(countdown ?? 0, 120, accuracy: 2)
    }
}
