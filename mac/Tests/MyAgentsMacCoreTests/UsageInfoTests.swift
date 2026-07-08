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
