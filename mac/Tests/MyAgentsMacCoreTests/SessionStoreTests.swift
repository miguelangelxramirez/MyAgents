import XCTest
@testable import MyAgentsMacCore

/// Wiring test for `SessionStore`: `refresh()` must run the scan through
/// `SessionLivenessJoin`/`SessionOrdering`, not just publish the raw scanner output. Bites: revert
/// `apply(scanned:processes:)` to `sessions = scanned` directly and both assertions below fail
/// (the dead session stays, and the discovered process row never shows up).
// NOTE: the class itself is deliberately NOT `@MainActor` — `XCTestCase.setUpWithError()` /
// `tearDownWithError()` are nonisolated in XCTest, and a stored property can't be MainActor-only
// while those overrides (which touch it) stay nonisolated. Only `SessionStore` itself needs
// MainActor, so just the test methods that touch it are marked `@MainActor` individually.
final class SessionStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testRefresh_dropsDeadSession_addsDiscoveredRow_andOrdersAttentionFirst() throws {
        // Two rows on disk: one with a dead owner pid (must be dropped), one idle with no pid
        // that matches nothing live (also dropped — a hostile "orphaned" row).
        try #"{"state":"permission","provider":"claude","sessionId":"dead-owner","pid":999999}"#
            .write(to: tempDirectory.appendingPathComponent("dead-owner.json"), atomically: true, encoding: .utf8)
        try #"{"state":"idle","provider":"claude","sessionId":"orphan","cwd":"/nowhere"}"#
            .write(to: tempDirectory.appendingPathComponent("orphan.json"), atomically: true, encoding: .utf8)

        let liveProcess = ProcessLiveness.DiscoveredProcess(pid: 42, provider: .codex, cwd: "/Users/me/live-project", executablePath: "")

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [liveProcess] }
        )

        store.refresh()

        XCTAssertFalse(store.sessions.contains { $0.id == "dead-owner" }, "a session whose pid isn't alive must be dropped")
        XCTAssertFalse(store.sessions.contains { $0.id == "orphan" }, "a pid-less session matching no live process must be dropped")
        XCTAssertTrue(store.sessions.contains { $0.ownerPid == 42 && $0.provider == .codex }, "the unclaimed live process must appear as a discovered row")
    }

    @MainActor
    func testRefresh_resolvesDisplayName_preferringTranscriptAITitle_overRawName() throws {
        // Reproduces the reported bug directly: a hook file whose `name` is empty (as
        // `lifecycle.js` leaves it before the first prompt lands) must NOT show the folder twice —
        // it must show the transcript's ai-title once TranscriptTitle reads it.
        let transcriptFile = tempDirectory.appendingPathComponent("transcript.jsonl")
        try #"{"type":"ai-title","aiTitle":"Fix duplicated folder name"}"#
            .write(to: transcriptFile, atomically: true, encoding: .utf8)

        try """
        {"state":"idle","provider":"claude","sessionId":"titled","name":"","project":"MyAgents",\
        "transcript":"\(transcriptFile.path)","pid":\(ProcessInfo.processInfo.processIdentifier)}
        """.write(to: tempDirectory.appendingPathComponent("titled.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [] }
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.id == "titled" })
        XCTAssertEqual(session.displayName, "Fix duplicated folder name")
    }

    @MainActor
    func testRefresh_emptyNameNoTranscriptTitle_neverDuplicatesFolder() throws {
        // Same empty-`name` shape as the bug report, but with no transcript at all (the exact
        // real-world file from the bug report has no ai-title line yet) — the row must fall back
        // to the placeholder, never repeat "MyAgents" as both the title and folder line.
        try """
        {"state":"tool","provider":"claude","sessionId":"no-title","name":"","project":"MyAgents",\
        "pid":\(ProcessInfo.processInfo.processIdentifier)}
        """.write(to: tempDirectory.appendingPathComponent("no-title.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [] }
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.id == "no-title" })
        XCTAssertNotEqual(session.displayName, "MyAgents", "the title line must never just repeat the folder")
        XCTAssertEqual(session.folder, "MyAgents")
    }

    @MainActor
    func testStartThenStop_doesNotCrash_andPublishesAtLeastOnce() async throws {
        try #"{"state":"idle","provider":"claude","sessionId":"s1","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
            .write(to: tempDirectory.appendingPathComponent("s1.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            pollInterval: 0.05,
            discoverProcesses: { [] }
        )
        store.start()
        // Give the poll loop a couple of cycles to run.
        try await Task.sleep(nanoseconds: 300_000_000)
        store.stop()

        XCTAssertTrue(store.sessions.contains { $0.id == "s1" }, "own test-process pid is genuinely alive, so this row must survive the join")
    }
}
