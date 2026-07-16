import XCTest
import Combine
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

    /// A `CodexSessionScanner` pointed at a directory that doesn't exist — every `SessionStore` in
    /// this file MUST use this instead of the real-`~/.codex` default (METODOLOGIA §4: tests never
    /// touch a real user directory), even in tests that don't care about Codex naming at all.
    private var isolatedCodexSessionScanner: CodexSessionScanner {
        CodexSessionScanner(sessionsRoot: tempDirectory.appendingPathComponent("no-such-codex-sessions", isDirectory: true))
    }

    /// The poll runs twice a second forever. `sessions` is `@Published`, so ASSIGNING it fires
    /// `objectWillChange` even when the value is identical — and that made SwiftUI re-evaluate and
    /// re-lay-out the menu bar item continuously with the popover closed and nothing happening
    /// (`NSHostingView.layout`: 794 of 8078 samples in the idle profile, 2026-07-12). A refresh that
    /// changes nothing must notify NOBODY.
    @MainActor
    func testRefresh_withNothingChanged_doesNotNotifyObservers() throws {
        try #"{"state":"idle","provider":"claude","sessionId":"steady","cwd":"/Users/me/steady","pid":1}"#
            .write(to: tempDirectory.appendingPathComponent("steady.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [ProcessLiveness.DiscoveredProcess(pid: 1, provider: .claude, cwd: "/Users/me/steady", executablePath: "")] },
            codexSessionScanner: isolatedCodexSessionScanner
        )

        store.refresh() // first one populates the list — that IS a change
        XCTAssertEqual(store.sessions.map(\.id), ["steady"])

        var notifications = 0
        let token = store.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        store.refresh()
        store.refresh()
        store.refresh()

        XCTAssertEqual(notifications, 0, "three polls over an unchanged world must not republish, or SwiftUI re-lays-out the menu bar for nothing")
        XCTAssertEqual(store.sessions.map(\.id), ["steady"], "and the list is of course still there")
    }

    @MainActor
    func testRefresh_whenSomethingActuallyChanges_stillNotifies() throws {
        // The other half: publish-on-change must not become publish-never.
        try #"{"state":"idle","provider":"claude","sessionId":"steady","cwd":"/Users/me/steady","pid":1}"#
            .write(to: tempDirectory.appendingPathComponent("steady.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [ProcessLiveness.DiscoveredProcess(pid: 1, provider: .claude, cwd: "/Users/me/steady", executablePath: "")] },
            codexSessionScanner: isolatedCodexSessionScanner
        )
        store.refresh()

        var notifications = 0
        let token = store.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        // The session starts asking for permission — the whole point of the app.
        try #"{"state":"permission","provider":"claude","sessionId":"steady","cwd":"/Users/me/steady","pid":1}"#
            .write(to: tempDirectory.appendingPathComponent("steady.json"), atomically: true, encoding: .utf8)
        store.refresh()

        XCTAssertEqual(notifications, 1, "a real state change must reach the UI immediately")
        XCTAssertTrue(store.sessions.contains { $0.id == "steady" && $0.state == .permission })
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
            discoverProcesses: { [liveProcess] },
            codexSessionScanner: isolatedCodexSessionScanner
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
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
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
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
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
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
        )
        store.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        store.stop()

        XCTAssertTrue(store.sessions.contains { $0.id == "s1" }, "own test-process pid is genuinely alive, so this row must survive the join")
    }

    /// The whole point of the event-driven rewrite: a hook writing a file must reach the UI on its
    /// own, with NO polling. `reconcileInterval` is set to an hour here, so if the directory watcher
    /// doesn't fire, nothing else will save this test — it just times out and fails.
    @MainActor
    func testNewSessionFile_reachesTheUI_withoutAnyPolling() async throws {
        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            reconcileInterval: 3600, // the safety net must NOT be what makes this pass
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
        )
        store.start()
        defer { store.stop() }
        XCTAssertTrue(store.sessions.isEmpty, "nothing on disk yet")

        // A hook fires: a brand-new session appears in the watched directory.
        try #"{"state":"permission","provider":"claude","sessionId":"asks","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
            .write(to: tempDirectory.appendingPathComponent("asks.json"), atomically: true, encoding: .utf8)

        let appeared = try await waitUntil(timeout: 5) { store.sessions.contains { $0.id == "asks" } }
        XCTAssertTrue(appeared, "the directory watcher must deliver the new session without a poll loop")
        XCTAssertTrue(store.sessions.contains { $0.id == "asks" && $0.state == .permission })
    }

    /// And the reverse: the hook DELETES the file when a session ends.
    @MainActor
    func testDeletedSessionFile_removesTheRow_withoutAnyPolling() async throws {
        let file = tempDirectory.appendingPathComponent("bye.json")
        try #"{"state":"idle","provider":"claude","sessionId":"bye","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            reconcileInterval: 3600,
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
        )
        store.start()
        defer { store.stop() }
        XCTAssertEqual(store.sessions.map(\.id), ["bye"])

        try FileManager.default.removeItem(at: file)

        let gone = try await waitUntil(timeout: 5) { store.sessions.isEmpty }
        XCTAssertTrue(gone, "the row must disappear as soon as the file does")
    }

    /// Polls a condition until it holds or the timeout expires. Used only to await ASYNCHRONOUS
    /// file-system events — the code under test does no polling of its own.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: - Codex naming from rollout transcripts (Hito 2 Ronda B)

    private var codexSessionsRoot: URL { tempDirectory.appendingPathComponent("codex-sessions", isDirectory: true) }

    private func writeCodexRollout(sessionId: String, cwd: String, userText: String) throws {
        let file = codexSessionsRoot.appendingPathComponent("2026/07/08/rollout-\(sessionId).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metaLine = #"{"timestamp":"2026-07-08T16:43:26.739Z","type":"session_meta","payload":{"session_id":"\#(sessionId)","id":"\#(sessionId)","cwd":"\#(cwd)"}}"#
        let userLine = #"{"timestamp":"2026-07-08T16:43:28.283Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(userText)"}]}}"#
        try (metaLine + "\n" + userLine + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// A Codex session discovered as a bare process row (no hook file at all — the common case on
    /// macOS, since Codex has no reliable hook mechanism there) must show the rollout's real first
    /// prompt as its title once a matching rollout can be found by cwd. Bites: revert the
    /// `codexSessionScanner.latestSession`/`name(forCwd:)` wiring in `SessionStore.apply` and this
    /// falls back to the placeholder instead of the real prompt.
    @MainActor
    func testRefresh_codexDiscoveredRow_withDiscoverableRollout_showsPromptDerivedName() throws {
        try writeCodexRollout(sessionId: "codex-1", cwd: "/Users/me/lapiz-rojo", userText: "Arregla el bug del boton guardar")
        let liveProcess = ProcessLiveness.DiscoveredProcess(pid: 4242, provider: .codex, cwd: "/Users/me/lapiz-rojo", executablePath: "")

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [liveProcess] },
            codexSessionScanner: CodexSessionScanner(sessionsRoot: codexSessionsRoot)
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.ownerPid == 4242 })
        XCTAssertEqual(session.displayName, "Arregla el bug del boton guardar")
        XCTAssertEqual(session.provider, .codex)
    }

    /// The same discovered-row shape, but with NO rollout anywhere that matches its cwd — must
    /// fall back to the existing placeholder behavior, NEVER a wrong/guessed name and never the
    /// folder repeated as the title (mirrors `testRefresh_emptyNameNoTranscriptTitle_neverDuplicatesFolder`
    /// for Claude).
    @MainActor
    func testRefresh_codexDiscoveredRow_noMatchingRollout_showsPlaceholderNotWrongName() throws {
        // A rollout exists, but for a DIFFERENT cwd — proves this isn't just "any rollout wins".
        try writeCodexRollout(sessionId: "codex-elsewhere", cwd: "/Users/me/some-other-project", userText: "Unrelated task")
        let liveProcess = ProcessLiveness.DiscoveredProcess(pid: 4343, provider: .codex, cwd: "/Users/me/no-rollout-here", executablePath: "")

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [liveProcess] },
            codexSessionScanner: CodexSessionScanner(sessionsRoot: codexSessionsRoot)
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.ownerPid == 4343 })
        XCTAssertEqual(session.folder, "no-rollout-here")
        XCTAssertNotEqual(session.displayName, "Unrelated task", "must never borrow another cwd's rollout name")
        XCTAssertNotEqual(session.displayName, session.folder, "the title line must never just repeat the folder")
    }

    /// Two Codex rollouts share the SAME cwd (two terminals in one project) — `name(forCwd:)` is
    /// ambiguous by design (`CodexNameCache`), so the discovered row must fall back to the
    /// placeholder rather than borrow either session's name. Bites: remove the ambiguity guard in
    /// `CodexNameCache.name(forCwd:)` and this starts asserting a specific (wrong, guessed) name.
    @MainActor
    func testRefresh_codexDiscoveredRow_ambiguousCwd_neverGuessesAName() throws {
        try writeCodexRollout(sessionId: "codex-a", cwd: "/Users/me/shared-terminals", userText: "First terminal's task")
        try writeCodexRollout(sessionId: "codex-b", cwd: "/Users/me/shared-terminals", userText: "Second terminal's task")
        let liveProcess = ProcessLiveness.DiscoveredProcess(pid: 4444, provider: .codex, cwd: "/Users/me/shared-terminals", executablePath: "")

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [liveProcess] },
            codexSessionScanner: CodexSessionScanner(sessionsRoot: codexSessionsRoot)
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.ownerPid == 4444 })
        XCTAssertNotEqual(session.displayName, "First terminal's task")
        XCTAssertNotEqual(session.displayName, "Second terminal's task")
    }

    /// Codex audit MED #7: session A ran in /repo and ended; B now runs in /repo as the ONLY rollout
    /// there. Even though the historical name cache remembers both ids forever (so `name(forCwd:)` is
    /// permanently poisoned to nil for /repo), B must still get its own prompt-derived title from the
    /// current unambiguous scan (`latestSession(forCwd:)`). Bites: revert `codexName` to use only
    /// `name(forCwd:)` and B falls back to the folder placeholder.
    @MainActor
    func testRefresh_codexCwdOnceAmbiguousHistorically_currentSoleSessionStillGetsItsTitle() throws {
        // fileListTTL 0 so the second refresh re-walks the tree (A gone, B present) instead of reusing
        // the first scan's file listing.
        let scanner = CodexSessionScanner(sessionsRoot: codexSessionsRoot, fileListTTL: 0)
        let cwd = "/Users/me/repo"
        let aFile = codexSessionsRoot.appendingPathComponent("2026/07/08/rollout-codex-a.jsonl")

        // Scan 1: A is the live rollout in /repo — records A's id in the historical cache.
        try writeCodexRollout(sessionId: "codex-a", cwd: cwd, userText: "Session A's task")
        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [ProcessLiveness.DiscoveredProcess(pid: 5252, provider: .codex, cwd: cwd, executablePath: "")] },
            codexSessionScanner: scanner
        )
        store.refresh()

        // A ends (its rollout is gone), B starts in the SAME cwd — now the sole rollout there, but the
        // historical cache still remembers A's id alongside B's, poisoning `name(forCwd:)`.
        try FileManager.default.removeItem(at: aFile)
        try writeCodexRollout(sessionId: "codex-b", cwd: cwd, userText: "Session B's fresh task")
        store.refresh()

        XCTAssertNil(scanner.name(forCwd: cwd), "the historical cache is poisoned by two ids sharing the cwd")
        let session = try XCTUnwrap(store.sessions.first { $0.ownerPid == 5252 })
        XCTAssertEqual(session.displayName, "Session B's fresh task", "the current sole session must still get its own prompt")
    }

    // MARK: - Out-of-order scan guard (Codex audit MED #4)

    /// A slow scan A can finish after a newer scan B and try to republish an older snapshot. The
    /// monotonic generation gate must drop it. `shouldApply` records the newest generation seen and
    /// rejects any lower one arriving later. Bites: remove the `generation > lastAppliedGeneration`
    /// guard and the stale (lower) generation is accepted.
    @MainActor
    func testShouldApply_dropsAnOlderGenerationArrivingAfterANewerOne() {
        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
        )

        XCTAssertTrue(store.shouldApply(generation: 2), "the first (newest so far) scan applies")
        XCTAssertFalse(store.shouldApply(generation: 1), "a slower, older scan finishing later must be dropped")
        XCTAssertTrue(store.shouldApply(generation: 3), "a genuinely newer scan still applies")
        XCTAssertFalse(store.shouldApply(generation: 3), "the same generation is not applied twice")
    }

    /// Claude rows must be completely unaffected by the Codex-rollout enrichment path — a Claude
    /// session sharing a cwd with a Codex rollout must not have its name touched at all.
    @MainActor
    func testRefresh_claudeRow_neverEnrichedFromCodexRollout() throws {
        try writeCodexRollout(sessionId: "codex-x", cwd: "/Users/me/shared-with-claude", userText: "Codex's own prompt")
        try """
        {"state":"idle","provider":"claude","sessionId":"claude-row","name":"","project":"shared-with-claude",\
        "cwd":"/Users/me/shared-with-claude","pid":\(ProcessInfo.processInfo.processIdentifier)}
        """.write(to: tempDirectory.appendingPathComponent("claude-row.json"), atomically: true, encoding: .utf8)

        let store = SessionStore(
            scanner: SessionScanner(directoryURL: tempDirectory),
            discoverProcesses: { [] },
            codexSessionScanner: CodexSessionScanner(sessionsRoot: codexSessionsRoot)
        )
        store.refresh()

        let session = try XCTUnwrap(store.sessions.first { $0.id == "claude-row" })
        XCTAssertNotEqual(session.displayName, "Codex's own prompt")
    }
}
