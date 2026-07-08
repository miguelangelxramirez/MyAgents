import XCTest
@testable import MyAgentsMacCore

/// Usage-bar severity thresholds and stale-age arithmetic are design decisions pinned by tests.
/// These bite: move a threshold or the boundary inclusivity and the assertions fail.
final class UsageDisplayTests: XCTestCase {
    func testLevel_normalBelowWarn() {
        XCTAssertEqual(UsageLevel.forPercent(0), .normal)
        XCTAssertEqual(UsageLevel.forPercent(74.9), .normal)
    }

    func testLevel_warnBoundaryIsInclusive() {
        XCTAssertEqual(UsageLevel.forPercent(75), .warn)
        XCTAssertEqual(UsageLevel.forPercent(89.9), .warn)
    }

    func testLevel_highBoundaryIsInclusive() {
        XCTAssertEqual(UsageLevel.forPercent(90), .high)
        XCTAssertEqual(UsageLevel.forPercent(100), .high)
    }

    func testLevel_ordering_highBeatsWarnBeatsNormal() {
        // Custom thresholds must still respect high-before-warn evaluation order.
        XCTAssertEqual(UsageLevel.forPercent(50, warnAt: 40, highAt: 45), .high)
    }

    func testAge_nilCapture_isNil() {
        XCTAssertNil(UsageAge.minutes(since: nil))
    }

    func testAge_wholeMinutes() {
        let now = Date()
        XCTAssertEqual(UsageAge.minutes(since: now.addingTimeInterval(-125), now: now), 2)
    }

    func testAge_futureCapture_clampsToZero() {
        let now = Date()
        XCTAssertEqual(UsageAge.minutes(since: now.addingTimeInterval(30), now: now), 0)
    }

    // MARK: - UsageSummaryFormatter (Fix 4: small top-of-popover usage line)

    func testSummaryLine_bothWindowsKnown_showsRoundedPercents() {
        let info = UsageInfo(provider: .claude, fiveHourPercent: 29.6, sevenDayPercent: 91.4)
        XCTAssertEqual(UsageSummaryFormatter.line(providerTitle: "Claude", info: info), "Claude · 5h 30% · 7d 91%")
    }

    func testSummaryLine_unknownWindow_showsEmDash_neverFakeZero() {
        let info = UsageInfo(provider: .codex, fiveHourPercent: nil, sevenDayPercent: 12)
        XCTAssertEqual(UsageSummaryFormatter.line(providerTitle: "Codex", info: info), "Codex · 5h — · 7d 12%")
    }

    func testSummaryLine_bothWindowsUnknown_isAllEmDashes() {
        let info = UsageInfo.unknown(provider: .claude)
        XCTAssertEqual(UsageSummaryFormatter.line(providerTitle: "Claude", info: info), "Claude · 5h — · 7d —")
    }
}
