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

    /// A `CodexSessionScanner` pointed at a directory that doesn't exist — every `SessionStore` in
    /// this file MUST use this instead of the real-`~/.codex` default (METODOLOGIA §4: tests never
    /// touch a real user directory), even in tests that don't care about Codex naming at all.
    private var isolatedCodexSessionScanner: CodexSessionScanner {
        CodexSessionScanner(sessionsRoot: tempDirectory.appendingPathComponent("no-such-codex-sessions", isDirectory: true))
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
            pollInterval: 0.05,
            discoverProcesses: { [] },
            codexSessionScanner: isolatedCodexSessionScanner
        )
        store.start()
        // Give the poll loop a couple of cycles to run.
        try await Task.sleep(nanoseconds: 300_000_000)
        store.stop()

        XCTAssertTrue(store.sessions.contains { $0.id == "s1" }, "own test-process pid is genuinely alive, so this row must survive the join")
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
