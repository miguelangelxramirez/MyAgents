import XCTest
@testable import MyAgentsMacCore

/// Pins `ResetCountdownFormatter`'s compact output and its total-ness (nil for past/unknown), the
/// same way `ElapsedTimeFormatterTests` guards the row timer — the format is a design decision, not
/// an implementation detail that may drift.
final class ResetCountdownFormatterTests: XCTestCase {
    func testDaysAndHours_forMultiDayWindow() {
        // 6 days, 3 hours, 40 minutes → days+hours only, minutes dropped at this magnitude.
        let interval: TimeInterval = 6 * 86_400 + 3 * 3600 + 40 * 60
        XCTAssertEqual(ResetCountdownFormatter.format(interval), "6d 3h")
    }

    func testHoursAndMinutes_underADay() {
        let interval: TimeInterval = 2 * 3600 + 14 * 60 + 30
        XCTAssertEqual(ResetCountdownFormatter.format(interval), "2h 14m")
    }

    func testMinutesOnly_underAnHour() {
        XCTAssertEqual(ResetCountdownFormatter.format(45 * 60 + 59), "45m")
    }

    func testSubMinute_showsLessThanOneMinute() {
        XCTAssertEqual(ResetCountdownFormatter.format(30), "<1m")
    }

    func testExactlyOneDay_hasZeroHours() {
        XCTAssertEqual(ResetCountdownFormatter.format(86_400), "1d 0h")
    }

    func testZeroAndNegative_returnNil() {
        // The window already reset (or clock skew) → nothing to show, never "0m" or a negative.
        XCTAssertNil(ResetCountdownFormatter.format(0))
        XCTAssertNil(ResetCountdownFormatter.format(-120))
    }

    func testNilDate_returnsNil() {
        XCTAssertNil(ResetCountdownFormatter.format(until: nil))
    }

    func testUntilDate_computesFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetAt = now.addingTimeInterval(3 * 3600 + 5 * 60)
        XCTAssertEqual(ResetCountdownFormatter.format(until: resetAt, now: now), "3h 5m")
    }

    func testUntilDate_inThePast_returnsNil() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetAt = now.addingTimeInterval(-60)
        XCTAssertNil(ResetCountdownFormatter.format(until: resetAt, now: now))
    }
}
