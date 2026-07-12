import XCTest
@testable import MyAgentsMacCore

/// Coverage for `CodexUsageService`'s two real code paths — the `app-server` JSON-RPC framing
/// and the rollout-JSONL fallback — using fixture doubles instead of a real Codex install (this
/// dev machine may not have one signed in; see the service's own doc comment and the executor's
/// final report for the [VERIFICADO]/[ASUMIDO] split). Every scenario proves the MECHANISM bites:
/// sabotage the field-name mapping (`usedPercent`/`resetsAt` vs `used_percent`/`resets_at`, or
/// swap `primary`/`secondary`) and the corresponding test fails.
final class CodexUsageServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func writeScript(_ contents: String, named name: String) throws -> URL {
        let file = tempDirectory.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private var emptyRolloutRoot: URL {
        tempDirectory.appendingPathComponent("no-such-codex-sessions-dir", isDirectory: true)
    }

    private func writeRollout(_ line: String, subpath: String = "2026/07/08/rollout-test.jsonl") throws {
        let file = tempDirectory.appendingPathComponent("sessions").appendingPathComponent(subpath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line.write(to: file, atomically: true, encoding: .utf8)
    }

    private var rolloutRoot: URL { tempDirectory.appendingPathComponent("sessions") }

    // MARK: - PRIMARY: app-server RPC framing + parsing

    func testAppServerRPC_success_parsesCamelCasePrimaryAsFiveHourAndSecondaryAsSevenDay() async throws {
        let script = try writeScript("""
        #!/bin/sh
        read -r l1
        read -r l2
        read -r l3
        echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"resetsAt":1700000000},"secondary":{"usedPercent":17,"resetsAt":1700100000}}}}'
        """, named: "fake-app-server-ok.sh")

        let service = CodexUsageService(
            rpcCommand: ["/bin/sh", script.path],
            rpcTimeout: 5,
            rolloutRoot: emptyRolloutRoot
        )
        let usage = await service.fetch()

        XCTAssertEqual(usage.provider, .codex)
        XCTAssertEqual(usage.fiveHourPercent, 42, "primary must map to the 5h bucket")
        XCTAssertEqual(usage.sevenDayPercent, 17, "secondary must map to the 7d bucket")
        XCTAssertNotNil(usage.fiveHourResetsAt)
        XCTAssertNotNil(usage.sevenDayResetsAt)
        XCTAssertFalse(usage.isStale, "a live RPC reading must not be flagged stale")
    }

    /// Regression: real `codex app-server` only answers `account/rateLimits/read` while the client
    /// keeps stdin OPEN — a stdin EOF makes it shut down after `initialize`, so it never replies to
    /// id:2 (root-caused live, 2026-07-09: this was why Codex usage stayed greyed/stale). This
    /// fixture emulates exactly that: it queues the id:2 reply but cancels it the instant stdin
    /// hits EOF. It therefore FAILS (falls back to the stale rollout) if the service closes stdin
    /// before reading, and SUCCEEDS (live reading) only if the service keeps it open.
    func testAppServerRPC_requiresStdinToStayOpen_untilResponseIsRead() async throws {
        let script = try writeScript("""
        #!/bin/sh
        read -r l1
        read -r l2
        read -r l3
        # Queue the id:2 answer, but only deliver it if the client keeps stdin open.
        ( sleep 0.3; echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"resetsAt":1700000000},"secondary":{"usedPercent":88,"resetsAt":1700100000}}}}' ) &
        pending=$!
        # Block on stdin: if the client already closed it (EOF), read returns immediately and we
        # kill the pending answer before it fires — mirroring codex shutting down on stdin EOF.
        if ! read -r _extra; then
          kill "$pending" 2>/dev/null
          exit 0
        fi
        wait "$pending"
        """, named: "fake-app-server-needs-open-stdin.sh")
        // A rollout fallback exists and is DIFFERENT, so a wrong (stale) result is unambiguous.
        try writeRollout(#"{"payload":{"rate_limits":{"primary":{"used_percent":1,"resets_at":1700000000}}}}"#)

        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: rolloutRoot)
        let usage = await service.fetch()

        XCTAssertEqual(usage.fiveHourPercent, 7, "must read the LIVE RPC value — service closed stdin too early if this is 1 (the stale rollout)")
        XCTAssertEqual(usage.sevenDayPercent, 88)
        XCTAssertFalse(usage.isStale, "a live RPC reading must not be flagged stale")
    }

    func testAppServerRPC_malformedResponse_fallsBackRatherThanCrashing() async throws {
        let script = try writeScript("""
        #!/bin/sh
        read -r l1
        read -r l2
        read -r l3
        echo 'not even json, id:2 mentioned but garbage'
        """, named: "fake-app-server-garbage.sh")
        try writeRollout(#"{"payload":{"rate_limits":{"primary":{"used_percent":9,"resets_at":1700000000}}}}"#)

        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: rolloutRoot)
        let usage = await service.fetch()

        XCTAssertEqual(usage.fiveHourPercent, 9, "a garbage RPC line must fall back to the rollout, not crash or fake 0%")
    }

    func testAppServerRPC_timesOutQuickly_fallsBackWithoutHangingTheFullDefaultTimeout() async throws {
        let script = try writeScript("""
        #!/bin/sh
        sleep 30
        """, named: "fake-app-server-hang.sh")
        try writeRollout(#"{"rate_limits":{"primary":{"used_percent":55,"resets_at":1700000000}}}"#)

        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 1, rolloutRoot: rolloutRoot)

        let start = Date()
        let usage = await service.fetch()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5, "the 1s kill-switch must cut the hung RPC short, not wait out a 30s sleep")
        XCTAssertEqual(usage.fiveHourPercent, 55, "must fall back to the rollout once the RPC is killed")
        XCTAssertTrue(usage.isStale, "a rollout-derived reading is inherently not live — flagged stale")
    }

    func testAppServerRPC_immediateExit_fallsBackToRollout() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1\n", named: "fake-app-server-exit1.sh")
        try writeRollout(#"{"rate_limits":{"primary":{"used_percent":3,"resets_at":0},"secondary":{"used_percent":1,"resets_at":0}}}"#)

        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: rolloutRoot)
        let usage = await service.fetch()

        XCTAssertEqual(usage.fiveHourPercent, 3)
        XCTAssertEqual(usage.sevenDayPercent, 1)
    }

    // MARK: - Neither RPC nor rollout available → unknown, never a fake 0%

    func testNoRPCAndNoRollout_returnsUnknown() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1\n", named: "fake-app-server-exit1-b.sh")
        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: emptyRolloutRoot)

        let usage = await service.fetch()
        XCTAssertEqual(usage, UsageInfo.unknown(provider: .codex))
        XCTAssertNil(usage.fiveHourPercent)
        XCTAssertNil(usage.sevenDayPercent)
    }

    // MARK: - Rollout parsing details

    func testRollout_picksNewestOfSeveralFiles_skippingOnesWithNoRateLimitsLine() async throws {
        try writeRollout(#"{"type":"session_meta"}"#, subpath: "2026/07/06/rollout-old-no-data.jsonl")
        // Make the "old" file's mtime provably older than the "newest" one below.
        let oldFile = rolloutRoot.appendingPathComponent("2026/07/06/rollout-old-no-data.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: oldFile.path)

        try writeRollout(
            #"{"payload":{"rate_limits":{"primary":{"used_percent":64,"resets_at":1700000000},"secondary":{"used_percent":21,"resets_at":1700200000}}}}"#,
            subpath: "2026/07/08/rollout-newest.jsonl"
        )

        let script = try writeScript("#!/bin/sh\nexit 1\n", named: "fake-app-server-exit1-c.sh")
        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: rolloutRoot)
        let usage = await service.fetch()

        XCTAssertEqual(usage.fiveHourPercent, 64)
        XCTAssertEqual(usage.sevenDayPercent, 21)
    }

    func testRollout_missingDirectory_returnsUnknown() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1\n", named: "fake-app-server-exit1-d.sh")
        let service = CodexUsageService(rpcCommand: ["/bin/sh", script.path], rpcTimeout: 5, rolloutRoot: emptyRolloutRoot)
        let usage = await service.fetch()
        XCTAssertEqual(usage, UsageInfo.unknown(provider: .codex))
    }
}
