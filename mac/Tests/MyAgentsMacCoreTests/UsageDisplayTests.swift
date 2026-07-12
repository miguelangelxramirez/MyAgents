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

    // MARK: - MenuBarUsageMetric: the chosen menu-bar percentage maps to the right provider/window

    private var claudeInfo: UsageInfo {
        UsageInfo(provider: .claude, fiveHourPercent: 11, sevenDayPercent: 22, isStale: false)
    }
    private var codexInfo: UsageInfo {
        UsageInfo(provider: .codex, fiveHourPercent: 33, sevenDayPercent: 44, isStale: true)
    }

    func testMetric_readsTheCorrectProviderAndWindow() {
        // Each of the four options must pull the value from its own provider AND its own window —
        // swap the provider (claude/codex info) or the window (5h/7d field) and this fails.
        XCTAssertEqual(MenuBarUsageMetric.claudeFiveHour.reading(claude: claudeInfo, codex: codexInfo).percent, 11)
        XCTAssertEqual(MenuBarUsageMetric.claudeSevenDay.reading(claude: claudeInfo, codex: codexInfo).percent, 22)
        XCTAssertEqual(MenuBarUsageMetric.codexFiveHour.reading(claude: claudeInfo, codex: codexInfo).percent, 33)
        XCTAssertEqual(MenuBarUsageMetric.codexSevenDay.reading(claude: claudeInfo, codex: codexInfo).percent, 44)
    }

    func testMetric_carriesTheChosenProvidersStaleness() {
        XCTAssertFalse(MenuBarUsageMetric.claudeFiveHour.reading(claude: claudeInfo, codex: codexInfo).isStale)
        XCTAssertTrue(MenuBarUsageMetric.codexFiveHour.reading(claude: claudeInfo, codex: codexInfo).isStale,
                      "a codex metric must reflect codex's staleness, not claude's")
    }

    func testMetric_unknownWindow_isNilNotZero() {
        let noSevenDay = UsageInfo(provider: .claude, fiveHourPercent: 5, sevenDayPercent: nil)
        XCTAssertNil(MenuBarUsageMetric.claudeSevenDay.reading(claude: noSevenDay, codex: codexInfo).percent,
                     "an unknown window must stay nil (UI shows '—'), never a fabricated 0%")
    }

    func testMetric_providerMapping() {
        XCTAssertEqual(MenuBarUsageMetric.claudeSevenDay.provider, .claude)
        XCTAssertEqual(MenuBarUsageMetric.codexFiveHour.provider, .codex)
    }

    func testMetric_rawValuesRoundTrip_forPersistence() {
        // AppPreferences persists the rawValue; a rename would silently reset users to the default.
        for metric in MenuBarUsageMetric.allCases {
            XCTAssertEqual(MenuBarUsageMetric(rawValue: metric.rawValue), metric)
        }
        XCTAssertNil(MenuBarUsageMetric(rawValue: "garbage"))
    }
}
