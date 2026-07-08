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
