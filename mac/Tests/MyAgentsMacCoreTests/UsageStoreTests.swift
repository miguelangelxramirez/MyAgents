import XCTest
@testable import MyAgentsMacCore

/// `UsageStore` must never flash "—" over a transient blip: an `.unknown` result must not
/// overwrite a previously known-good reading. These tests bite: delete the `merge` guard (always
/// apply the new value) and `testMerge_transientUnknown_keepsLastGoodValue` fails immediately.
@MainActor
final class UsageStoreTests: XCTestCase {
    private let threshold: TimeInterval = 10 * 60

    func testMerge_transientUnknown_keepsLastGoodValue() {
        // A recently-captured good reading: a transient blip must keep BOTH its percentages and its
        // freshness (it's still well under the staleness threshold).
        let good = UsageInfo(provider: .claude, fiveHourPercent: 55, sevenDayPercent: 12, capturedAt: Date())
        let blip = UsageInfo.unknown(provider: .claude)

        let merged = UsageStore.merge(newValue: blip, keeping: good, stalenessThreshold: threshold)
        XCTAssertEqual(merged, good, "a transient unknown reading must not erase a recent good one")
    }

    func testMerge_freshKnownValue_replacesPrevious() {
        let old = UsageInfo(provider: .claude, fiveHourPercent: 55)
        let fresh = UsageInfo(provider: .claude, fiveHourPercent: 60)

        XCTAssertEqual(UsageStore.merge(newValue: fresh, keeping: old, stalenessThreshold: threshold), fresh)
    }

    func testMerge_unknownReplacingUnknown_isHarmless() {
        let a = UsageInfo.unknown(provider: .codex)
        let b = UsageInfo.unknown(provider: .codex)
        XCTAssertEqual(UsageStore.merge(newValue: b, keeping: a, stalenessThreshold: threshold), b)
    }

    /// Codex audit MED #5: a reading that succeeded (fresh) and then goes unavailable must KEEP its
    /// percentages but be re-flagged stale once its capture ages past the threshold — not stay
    /// coloured "live" forever. Bites: revert `merge` to `return current` and this fails (stays fresh).
    func testMerge_succeededThenUnavailable_becomesStaleAfterThreshold() {
        let capturedLongAgo = Date().addingTimeInterval(-3600) // 1 hour ago, well past 10 min
        let onceLive = UsageInfo(provider: .codex, fiveHourPercent: 40, capturedAt: capturedLongAgo, isStale: false)
        let blip = UsageInfo.unknown(provider: .codex)

        let merged = UsageStore.merge(newValue: blip, keeping: onceLive, stalenessThreshold: threshold)
        XCTAssertEqual(merged.fiveHourPercent, 40, "the last good percentage must survive")
        XCTAssertTrue(merged.isStale, "an aged, no-longer-refreshed reading must grey out, not stay live")
    }

    /// The same keep-the-value path, but the last good reading is still recent — it must stay fresh.
    func testMerge_recentValue_thenUnavailable_staysFresh() {
        let onceLive = UsageInfo(provider: .codex, fiveHourPercent: 40, capturedAt: Date(), isStale: false)
        let merged = UsageStore.merge(newValue: .unknown(provider: .codex), keeping: onceLive, stalenessThreshold: threshold)
        XCTAssertFalse(merged.isStale, "a value captured moments ago must not be greyed out on one failed refresh")
    }

    /// A kept value with NO capture timestamp has an unknowable age — it must be treated as stale.
    func testMerge_keptValueWithNoCaptureTime_isStale() {
        let noTimestamp = UsageInfo(provider: .codex, fiveHourPercent: 40, capturedAt: nil, isStale: false)
        let merged = UsageStore.merge(newValue: .unknown(provider: .codex), keeping: noTimestamp, stalenessThreshold: threshold)
        XCTAssertTrue(merged.isStale, "a kept value with no capture time can't be trusted as fresh")
        XCTAssertEqual(merged.fiveHourPercent, 40)
    }

    // MARK: - End-to-end refreshOnce(), off the main thread, both providers

    func testRefreshOnce_populatesClaudeFromFile_andHandlesCodexFailureAsUnknown() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("UsageStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let now = Int(Date().timeIntervalSince1970)
        try #"{"five_hour":{"used_percent":33,"reset_at":0},"ts":\#(now)}"#.write(to: tempFile, atomically: true, encoding: .utf8)

        let store = UsageStore(
            claudeService: ClaudeUsageService(fileURL: tempFile),
            codexService: CodexUsageService(
                rpcCommand: ["/bin/sh", "-c", "exit 1"],
                rpcTimeout: 2,
                rolloutRoot: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-dir-\(UUID().uuidString)")
            )
        )

        await store.refreshOnce()

        XCTAssertEqual(store.claude.fiveHourPercent, 33)
        XCTAssertEqual(store.codex, UsageInfo.unknown(provider: .codex))
    }
}
