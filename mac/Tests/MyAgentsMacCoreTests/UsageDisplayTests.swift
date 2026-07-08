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
}
