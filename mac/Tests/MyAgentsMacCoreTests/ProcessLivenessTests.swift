import Darwin
import XCTest
@testable import MyAgentsMacCore

/// `URL.resolvingSymlinksInPath()`/`NSString.resolvingSymlinksInPath` deliberately do NOT expand
/// well-known compatibility symlinks like `/var` → `/private/var` (Foundation keeps them as-is for
/// historical reasons), but the kernel's `proc_pidinfo` reports the fully resolved path. `realpath`
/// (POSIX, `man 3 realpath`) gives the same canonical form the kernel uses.
private func canonicalPath(_ url: URL) -> String {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard let resolved = realpath(url.path, &buffer) else { return url.path }
    return String(cString: resolved)
}

/// `ProcessLiveness` coverage using ONLY public Darwin/libproc APIs (no private frameworks, no
/// entitlements). These tests bite: flip `isAlive`'s `ESRCH`/other-errno handling (e.g. always
/// return `true`) and `testDefinitelyDeadPid_isNotAlive` fails; break the `claude`/`codex`
/// substring match and `testDiscoversASpawnedProcessNamedCodex` fails.
final class ProcessLivenessTests: XCTestCase {
    // MARK: - isAlive

    func testCurrentProcess_isAlive() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessLiveness.isAlive(pid: myPid))
    }

    func testDefinitelyDeadPid_isNotAlive() throws {
        // Spawn a short-lived child, wait for it to exit, then check ITS pid — this is a pid we
        // KNOW existed a moment ago and is now provably gone (stronger evidence than guessing an
        // arbitrary large pid number that might coincidentally be reused by the OS).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["done"]
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        XCTAssertFalse(ProcessLiveness.isAlive(pid: deadPid))
    }

    func testNonPositivePid_isNotAlive() {
        XCTAssertFalse(ProcessLiveness.isAlive(pid: 0))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: -1))
    }

    // MARK: - discoverAgentProcesses

    func testDiscoversASpawnedProcessNamedCodex() throws {
        // The kernel derives a process's short "comm" name (what `proc_pidinfo`'s `pbi_name`
        // reports) from the executable path it was exec'd with — so copying `/bin/sleep` to a
        // file literally named "codex" and launching THAT gives us a real, live, honestly-named
        // "codex" process to discover, without needing an actual Codex install on this machine.
        let fakeCodexBinary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessLivenessTests-\(UUID().uuidString)")
            .appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: fakeCodexBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fakeCodexBinary)

        let workingDirectory = fakeCodexBinary.deletingLastPathComponent()
        let process = Process()
        process.executableURL = fakeCodexBinary
        process.arguments = ["30"]
        process.currentDirectoryURL = workingDirectory
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let discovered = ProcessLiveness.discoverAgentProcesses()
        let match = try XCTUnwrap(discovered.first { $0.pid == process.processIdentifier })

        XCTAssertEqual(match.provider, .codex)
        XCTAssertEqual(
            match.cwd,
            canonicalPath(workingDirectory),
            "best-effort cwd must match the directory we launched it from"
        )
    }

    // MARK: - Pure classification (the real-world shapes, without spawning anything)

    func testClaudeRenamedToItsVersion_isClassifiedByExecutablePath() {
        // The regression that made the app "detect no working sessions": modern Claude Code renames
        // its own process to its version, so `pbi_name` is "2.1.204" — useless. It must still be
        // recognised by its install path.
        let provider = ProcessLiveness.provider(
            name: "2.1.204",
            executablePath: "/Users/me/.local/share/claude/versions/2.1.204",
            arguments: ["claude"]
        )
        XCTAssertEqual(provider, .claude)
    }

    func testCodexNativeBinary_isClassifiedByName() {
        let provider = ProcessLiveness.provider(
            name: "codex-aarch64-apple-darwin",
            executablePath: "/opt/homebrew/Caskroom/codex/0.143.0/codex-aarch64-apple-darwin",
            arguments: ["codex"]
        )
        XCTAssertEqual(provider, .codex)
    }

    func testCodexCodeModeHostHelper_isNotClassifiedAsASession() {
        // `codex-code-mode-host` is a Codex internal helper spawned per interactive session. Its name
        // starts with "codex-" but it is NOT a session — classifying it produced a phantom row AND a
        // spurious "1 agent" badge on its own parent codex. It must stay unclassified everywhere the
        // "codex-" prefix is honored (name, executable base, argv[0]).
        XCTAssertNil(ProcessLiveness.provider(
            name: "codex-code-mode-host",
            executablePath: "/opt/homebrew/bin/codex-code-mode-host",
            arguments: ["codex-code-mode-host"]
        ))
    }

    func testCodexCodeModeHostHelper_withResolvedCaskroomPath_isStillNotASession() {
        // REALITY the symlink-path test above missed: `/opt/homebrew/bin/codex-code-mode-host` is a
        // symlink, and `proc_pidpath` hands back the RESOLVED target under the Homebrew Caskroom,
        // whose path contains "/codex/". That matched the `path.contains("/codex/")` rule and
        // classified the helper as a codex session — a phantom "1 agent" on every real codex row
        // (2026-07-16). The helper must be rejected BEFORE any path rule.
        XCTAssertNil(ProcessLiveness.provider(
            name: "codex-code-mode-",   // pbi_name is capped at 16 chars → the truncated helper name
            executablePath: "/opt/homebrew/Caskroom/codex/0.144.1/bin/codex-code-mode-host",
            arguments: ["codex-code-mode-host"]
        ))
    }

    func testNodeHostedClaude_isClassifiedByScriptArg() {
        let provider = ProcessLiveness.provider(
            name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        )
        XCTAssertEqual(provider, .claude)
    }

    func testMcpServerMentioningCodexInEnvironment_isNotMisclassified() {
        // `@playwright/mcp` runs under node and its argv/env mention "codex" (a plugin path), which
        // a naive whole-argv substring scan wrongly flagged as a Codex session — one phantom row
        // PER project, the "GameCozy codex repeated" bug. argv[1] is the real script; it has no
        // "codex", so it must stay unclassified.
        let provider = ProcessLiveness.provider(
            name: "npm exec @playwright/mcp",
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "/Users/me/.npm/_npx/abc/node_modules/.bin/playwright-mcp", "--codex-plugin-path=/x/codex"]
        )
        XCTAssertNil(provider)
    }

    func testProjectFolderNamedLikeClaude_isNotMisclassified() {
        // A user working in "/tmp/claude-501/…" running an unrelated tool must not be mistaken for
        // Claude: "/claude-501/" is not the "/claude/" path component the real install has.
        let provider = ProcessLiveness.provider(
            name: "mytool",
            executablePath: "/private/tmp/claude-501/build/mytool",
            arguments: ["mytool"]
        )
        XCTAssertNil(provider)
    }

    func testDiscoveredProcess_disappearsAfterItExits() throws {
        let fakeClaudeBinary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessLivenessTests-\(UUID().uuidString)")
            .appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: fakeClaudeBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fakeClaudeBinary)
        defer { try? FileManager.default.removeItem(at: fakeClaudeBinary.deletingLastPathComponent()) }

        let process = Process()
        process.executableURL = fakeClaudeBinary
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier

        XCTAssertTrue(ProcessLiveness.discoverAgentProcesses().contains { $0.pid == pid && $0.provider == .claude })

        process.terminate()
        process.waitUntilExit()

        XCTAssertFalse(ProcessLiveness.discoverAgentProcesses().contains { $0.pid == pid })
        XCTAssertFalse(ProcessLiveness.isAlive(pid: pid))
    }
}
