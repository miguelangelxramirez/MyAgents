import XCTest
@testable import MyAgentsMacCore

/// Coverage for `CodexSessionScanner` against a TEMP directory shaped like real Codex rollout
/// output (verified against actual `~/.codex/sessions/**/rollout-*.jsonl` files on the executor's
/// machine while building this — see the executor's final report for the exact line shapes and
/// which branches are [VERIFICADO] vs [ASUMIDO]). NEVER points at the real `~/.codex`.
///
/// These tests bite: e.g. remove the `isInjectedContext` check for `"# AGENTS.md"` and
/// `testSkipsAgentsAndEnvironmentContext_findsRealFirstPrompt` fails (it would return the
/// AGENTS.md block as the "name" instead of the real prompt after it); change `firstContentText`
/// to concatenate ALL content parts instead of just the first and the same test's malformed-JSON
/// sibling starts returning garbage; drop the tail scan's newest→oldest order and
/// `testInferState_prefersMostRecentMarker` fails.
final class CodexSessionScannerTests: XCTestCase {
    private var sessionsRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sessionsRoot, FileManager.default.fileExists(atPath: sessionsRoot.path) {
            try? FileManager.default.removeItem(at: sessionsRoot)
        }
        sessionsRoot = nil
        try super.tearDownWithError()
    }

    /// Writes one rollout file at `sessionsRoot/2026/07/08/rollout-<sessionId>.jsonl` (the nested
    /// date path is irrelevant to the scanner — it recurses — but mirrors the real layout).
    @discardableResult
    private func writeRollout(sessionId: String, cwd: String, lines: [String], mtime: Date? = nil) throws -> URL {
        let file = sessionsRoot
            .appendingPathComponent("2026/07/08", isDirectory: true)
            .appendingPathComponent("rollout-\(sessionId).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metaLine = #"{"timestamp":"2026-07-08T16:43:26.739Z","type":"session_meta","payload":{"session_id":"\#(sessionId)","id":"\#(sessionId)","cwd":"\#(cwd)"}}"#
        try ([metaLine] + lines).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        return file
    }

    private func userMessageLine(_ text: String, timestamp: String = "2026-07-08T16:43:28.283Z") -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(escaped)"}]}}"#
    }

    // MARK: - Name extraction: the real shape from this machine's ~/.codex/sessions

    func testSkipsAgentsAndEnvironmentContext_findsRealFirstPrompt() throws {
        // Reproduces the EXACT real shape verified on the executor's machine: Codex injects a
        // single user-role message whose first content part is the project's "# AGENTS.md
        // instructions for <cwd>" text and whose second part is <environment_context>. Only the
        // FIRST part is inspected (mirrors the C# reference), so this whole message must be
        // skipped, and the NEXT user-role message ("porfa, revisa...") must be the extracted name.
        // NOTE: uses `##"…"##` (not `#"…"#`) because the payload text itself contains the
        // substring `"#` (`:"# AGENTS.md`), which would otherwise prematurely close a single-`#`
        // raw string.
        let combinedLine = ##"{"timestamp":"2026-07-08T09:36:55.529Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/me/CaloryDay\n\n<INSTRUCTIONS>\nSome project rules\n</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>\n  <cwd>/Users/me/CaloryDay</cwd>\n</environment_context>"}]}}"##
        try writeRollout(
            sessionId: "s1",
            cwd: "/Users/me/CaloryDay",
            lines: [combinedLine, userMessageLine("porfa, revisa esta conversación di cosas actuales")]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        let session = try XCTUnwrap(sessions.first { $0.sessionId == "s1" })
        XCTAssertEqual(session.name, "porfa, revisa esta conversación di cosas actuales")
        XCTAssertEqual(session.cwd, "/Users/me/CaloryDay")
    }

    func testBareEnvironmentContextWithNoAgentsMd_isSkipped() throws {
        // A session with no AGENTS.md file: the first user message is JUST <environment_context>,
        // starting with '<' — must still be skipped.
        try writeRollout(
            sessionId: "s2",
            cwd: "/Users/me/no-agents-md",
            lines: [
                userMessageLine("<environment_context>\n  <cwd>/Users/me/no-agents-md</cwd>\n</environment_context>"),
                userMessageLine("Fix the crash on launch"),
            ]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        let session = try XCTUnwrap(sessions.first { $0.sessionId == "s2" })
        XCTAssertEqual(session.name, "Fix the crash on launch")
    }

    func testDeveloperRoleMessage_isNotMistakenForUserPrompt() throws {
        // The permissions/sandbox preamble is role "developer", not "user" — must never be picked
        // as the name even though its text mentions things like "the user's approval".
        let developerLine = #"{"timestamp":"2026-07-08T16:43:28.283Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\nApproval policy requires the user's request before proceeding."}]}}"#
        try writeRollout(
            sessionId: "s3",
            cwd: "/Users/me/dev-role",
            lines: [developerLine, userMessageLine("Add dark mode support")]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        let session = try XCTUnwrap(sessions.first { $0.sessionId == "s3" })
        XCTAssertEqual(session.name, "Add dark mode support")
    }

    func testNoRealUserPromptYet_nameIsEmpty_notCrash() throws {
        try writeRollout(
            sessionId: "s4",
            cwd: "/Users/me/just-started",
            lines: [userMessageLine("<environment_context>only injected context so far</environment_context>")]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        let session = try XCTUnwrap(sessions.first { $0.sessionId == "s4" })
        XCTAssertEqual(session.name, "")
    }

    // MARK: - Defensive: malformed / missing / empty input never crashes

    func testMissingSessionsDirectory_returnsEmpty_noCrash() {
        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(scanner.scanRecentSessions(), [])
    }

    func testMalformedFirstLine_wholeFileSkipped_othersStillReturned() throws {
        let malformedFile = sessionsRoot.appendingPathComponent("2026/07/08/rollout-broken.jsonl")
        try FileManager.default.createDirectory(at: malformedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ this is not valid json at all".write(to: malformedFile, atomically: true, encoding: .utf8)

        try writeRollout(sessionId: "good", cwd: "/Users/me/good-project", lines: [userMessageLine("A real prompt")])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        XCTAssertFalse(sessions.contains { $0.sessionId == "broken" })
        XCTAssertTrue(sessions.contains { $0.sessionId == "good" && $0.name == "A real prompt" })
    }

    func testEmptyRolloutFile_isSkipped_noCrash() throws {
        let emptyFile = sessionsRoot.appendingPathComponent("2026/07/08/rollout-empty.jsonl")
        try FileManager.default.createDirectory(at: emptyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        XCTAssertEqual(scanner.scanRecentSessions(), [])
    }

    func testMalformedMiddleLine_isSkipped_validPromptStillFound() throws {
        try writeRollout(
            sessionId: "s5",
            cwd: "/Users/me/garbage-middle",
            lines: [
                "{ garbage that mentions \"user\" but is not valid json",
                userMessageLine("The real first prompt"),
            ]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        let session = try XCTUnwrap(sessions.first { $0.sessionId == "s5" })
        XCTAssertEqual(session.name, "The real first prompt")
    }

    // MARK: - maxAge: stale rollouts are ignored entirely

    func testStaleRollout_olderThanMaxAge_isIgnored() throws {
        try writeRollout(
            sessionId: "stale",
            cwd: "/Users/me/stale-project",
            lines: [userMessageLine("Old prompt")],
            mtime: Date().addingTimeInterval(-3600) // 1h old, default maxAge is 1800s
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot, maxAge: 1800)
        XCTAssertTrue(scanner.scanRecentSessions().isEmpty, "a rollout older than maxAge must be ignored entirely")
    }

    // MARK: - State inference (verified against real task_started/task_complete/turn_aborted shapes)

    func testInferState_taskStarted_isToolWorking_withStartedAt() throws {
        let startedLine = #"{"timestamp":"2026-07-08T16:43:26.739Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#
        try writeRollout(sessionId: "working", cwd: "/Users/me/working-project", lines: [userMessageLine("Do the thing"), startedLine])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let session = try XCTUnwrap(scanner.scanRecentSessions().first { $0.sessionId == "working" })

        XCTAssertEqual(session.state, .tool)
        XCTAssertNotNil(session.startedAt)
    }

    func testInferState_taskComplete_isIdle() throws {
        let startedLine = #"{"timestamp":"2026-07-08T16:43:26.739Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#
        let completeLine = #"{"timestamp":"2026-07-08T16:44:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#
        try writeRollout(sessionId: "done", cwd: "/Users/me/done-project", lines: [userMessageLine("Do the thing"), startedLine, completeLine])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let session = try XCTUnwrap(scanner.scanRecentSessions().first { $0.sessionId == "done" })

        XCTAssertEqual(session.state, .idle)
    }

    func testInferState_turnAborted_isIdle() throws {
        let startedLine = #"{"timestamp":"2026-07-08T16:43:26.739Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#
        let abortedLine = #"{"timestamp":"2026-07-08T16:44:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1"}}"#
        try writeRollout(sessionId: "aborted", cwd: "/Users/me/aborted-project", lines: [userMessageLine("Do the thing"), startedLine, abortedLine])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let session = try XCTUnwrap(scanner.scanRecentSessions().first { $0.sessionId == "aborted" })

        XCTAssertEqual(session.state, .idle, "an aborted turn must not linger as 'working' just because the file is recent")
    }

    func testInferState_prefersMostRecentMarker() throws {
        // task_started, then task_complete, then a SECOND task_started (a follow-up turn) — the
        // state must reflect the LATEST marker (working), not the first one it happens to match.
        let firstStart = #"{"timestamp":"2026-07-08T16:43:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#
        let complete = #"{"timestamp":"2026-07-08T16:43:30.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#
        let secondStart = #"{"timestamp":"2026-07-08T16:44:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        try writeRollout(
            sessionId: "two-turns",
            cwd: "/Users/me/two-turns-project",
            lines: [userMessageLine("First ask"), firstStart, complete, userMessageLine("Second ask"), secondStart]
        )

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let session = try XCTUnwrap(scanner.scanRecentSessions().first { $0.sessionId == "two-turns" })

        XCTAssertEqual(session.state, .tool)
    }

    // MARK: - name(forCwd:) persists across scans; latestSession(forCwd:) does not

    func testNameForCwd_survivesAcrossScans_evenAfterRolloutAgesOut() throws {
        try writeRollout(sessionId: "lingering", cwd: "/Users/me/lingering-project", lines: [userMessageLine("Remember me")])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot, maxAge: 1800)
        _ = scanner.scanRecentSessions()
        XCTAssertEqual(scanner.name(forCwd: "/Users/me/lingering-project"), "Remember me")

        // Simulate the rollout aging out of the scan window (backdate it), then re-scan.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: sessionsRoot.appendingPathComponent("2026/07/08/rollout-lingering.jsonl").path
        )
        _ = scanner.scanRecentSessions()

        XCTAssertNil(scanner.latestSession(forCwd: "/Users/me/lingering-project"), "state must not be trusted once the rollout ages out of the scan")
        XCTAssertEqual(scanner.name(forCwd: "/Users/me/lingering-project"), "Remember me", "the NAME must still be remembered even though the rollout is no longer in the current scan")
    }

    func testTwoSessionsSameCwd_nameForCwdIsNil_butEachSessionStillParsedIndividually() throws {
        try writeRollout(sessionId: "a", cwd: "/Users/me/shared-project", lines: [userMessageLine("First terminal's task")])
        try writeRollout(sessionId: "b", cwd: "/Users/me/shared-project", lines: [userMessageLine("Second terminal's task")])

        let scanner = CodexSessionScanner(sessionsRoot: sessionsRoot)
        let sessions = scanner.scanRecentSessions()

        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["a", "b"])
        XCTAssertNil(scanner.name(forCwd: "/Users/me/shared-project"), "ambiguous cwd must never resolve to either session's name")
        XCTAssertNil(scanner.latestSession(forCwd: "/Users/me/shared-project"), "ambiguous cwd must never resolve a state either")
    }
}
