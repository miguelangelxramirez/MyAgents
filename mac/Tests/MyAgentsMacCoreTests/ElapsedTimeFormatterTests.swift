import XCTest
@testable import MyAgentsMacCore

/// Elapsed-timer formatting must be total and stable. These tests bite: drop the negative clamp
/// and `testNegative` fails; drop the hours field and `testOverAnHour` fails.
final class ElapsedTimeFormatterTests: XCTestCase {
    func testZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(0), "00:00")
    }

    func testUnderAMinute() {
        XCTAssertEqual(ElapsedTimeFormatter.format(7), "00:07")
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(3 * 60 + 42), "03:42")
    }

    func testExactlyAtAnHour_gainsHoursField() {
        XCTAssertEqual(ElapsedTimeFormatter.format(3600), "1:00:00")
    }

    func testOverAnHour_keepsSeconds() {
        XCTAssertEqual(ElapsedTimeFormatter.format(3600 + 23 * 60 + 5), "1:23:05")
    }

    func testNegative_clampsToZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(-30), "00:00")
    }

    func testSinceDate_nilStart_isNil() {
        XCTAssertNil(ElapsedTimeFormatter.format(since: nil))
    }

    func testSinceDate_computesFromNow() {
        let now = Date()
        let start = now.addingTimeInterval(-90)
        XCTAssertEqual(ElapsedTimeFormatter.format(since: start, now: now), "01:30")
    }
}
