import XCTest
@testable import MyAgentsMacCore

/// `UsageStore` must never flash "—" over a transient blip: an `.unknown` result must not
/// overwrite a previously known-good reading. These tests bite: delete the `merge` guard (always
/// apply the new value) and `testMerge_transientUnknown_keepsLastGoodValue` fails immediately.
@MainActor
final class UsageStoreTests: XCTestCase {
    func testMerge_transientUnknown_keepsLastGoodValue() {
        let good = UsageInfo(provider: .claude, fiveHourPercent: 55, sevenDayPercent: 12)
        let blip = UsageInfo.unknown(provider: .claude)

        let merged = UsageStore.merge(newValue: blip, keeping: good)
        XCTAssertEqual(merged, good, "a transient unknown reading must not erase the last good one")
    }

    func testMerge_freshKnownValue_replacesPrevious() {
        let old = UsageInfo(provider: .claude, fiveHourPercent: 55)
        let fresh = UsageInfo(provider: .claude, fiveHourPercent: 60)

        XCTAssertEqual(UsageStore.merge(newValue: fresh, keeping: old), fresh)
    }

    func testMerge_unknownReplacingUnknown_isHarmless() {
        let a = UsageInfo.unknown(provider: .codex)
        let b = UsageInfo.unknown(provider: .codex)
        XCTAssertEqual(UsageStore.merge(newValue: b, keeping: a), b)
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
