import XCTest
@testable import MyAgentsMacCore

/// These exercise the REAL kqueue and FSEvents machinery against REAL temp directories — no fakes.
/// That is the point: this is the code that replaced the 2 Hz poll loop, so if a watcher silently
/// fails to fire, the app simply stops noticing that an agent is asking for permission, and no amount
/// of mocking would have caught it.
final class FileSystemWatchersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemWatchersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - DirectoryWatcher: the Claude path (~/.claude/statusbar/sessions.d)

    func testDirectoryWatcher_firesWhenAFileAppears() throws {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false

        let watcher = DirectoryWatcher(url: root) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // The hooks write each session's JSON via temp-file + rename, which changes the directory's
        // entries — exactly the `.write` this watch is for.
        try "{}".write(to: root.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 5)
    }

    func testDirectoryWatcher_firesWhenAFileIsDeleted() throws {
        let file = root.appendingPathComponent("gone.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)

        let fired = expectation(description: "watcher fired on delete")
        fired.assertForOverFulfill = false
        let watcher = DirectoryWatcher(url: root) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // SessionEnd deletes the file; the row has to go with it.
        try FileManager.default.removeItem(at: file)

        wait(for: [fired], timeout: 5)
    }

    func testDirectoryWatcher_missingDirectory_doesNotCrash_andCanBeStopped() {
        // The steady state on a machine whose hooks were never installed.
        let watcher = DirectoryWatcher(url: root.appendingPathComponent("no-such-dir", isDirectory: true)) {}
        watcher.start()
        watcher.stop()
    }

    func testDirectoryWatcher_stop_silencesIt() throws {
        let fired = expectation(description: "must NOT fire after stop")
        fired.isInverted = true

        let watcher = DirectoryWatcher(url: root) { fired.fulfill() }
        watcher.start()
        watcher.stop()

        try "{}".write(to: root.appendingPathComponent("after-stop.json"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 1.5)
    }

    // MARK: - FileTreeWatcher: the Codex path (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    func testFileTreeWatcher_firesOnAWriteSEVERALLevelsDeep() throws {
        // THE reason FSEvents is here at all. Codex rollouts live in nested date folders and are
        // APPENDED to — a kqueue watch on the root directory would never see this write, because the
        // root's own entries never change. If this test fails, Codex sessions silently stop updating.
        let deep = root.appendingPathComponent("2026/07/12", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let rollout = deep.appendingPathComponent("rollout-abc.jsonl")
        try "first\n".write(to: rollout, atomically: true, encoding: .utf8)

        let fired = expectation(description: "tree watcher fired on a nested append")
        fired.assertForOverFulfill = false
        let watcher = FileTreeWatcher(root: root, latency: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // FSEvents delivers events from the moment the stream starts; give it a beat to arm.
        Thread.sleep(forTimeInterval: 0.3)
        let handle = try FileHandle(forWritingTo: rollout)
        handle.seekToEndOfFile()
        handle.write(Data("appended\n".utf8))
        try handle.close()

        wait(for: [fired], timeout: 10)
    }

    func testFileTreeWatcher_firesWhenAWholeNewDateFolderAppears() throws {
        // A brand-new Codex session creates today's folder AND its rollout in one go.
        let fired = expectation(description: "tree watcher fired on a new nested file")
        fired.assertForOverFulfill = false
        let watcher = FileTreeWatcher(root: root, latency: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        let deep = root.appendingPathComponent("2026/07/13", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "x\n".write(to: deep.appendingPathComponent("rollout-new.jsonl"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 10)
    }

    func testFileTreeWatcher_stop_silencesIt_andIsIdempotent() throws {
        let fired = expectation(description: "must NOT fire after stop")
        fired.isInverted = true

        let watcher = FileTreeWatcher(root: root, latency: 0.05) { fired.fulfill() }
        watcher.start()
        watcher.stop()
        watcher.stop() // stopping twice must not blow up

        try "x\n".write(to: root.appendingPathComponent("after-stop.jsonl"), atomically: true, encoding: .utf8)

        wait(for: [fired], timeout: 1.5)
    }
}
