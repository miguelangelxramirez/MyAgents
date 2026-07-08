import XCTest
@testable import MyAgentsMacCore

/// Hostile-state coverage for `HookInstaller` (METODOLOGIA §4: "estados de datos hostiles").
/// Every test injects a throwaway temp directory as `HOME` — NEVER the real `~/.claude`, which
/// may hold the developer's actual Claude Code configuration.
final class HookInstallerTests: XCTestCase {
    private var homeDirectory: URL!
    private var fixtureContents: [HookScript: String] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyAgentsMacTests-HookInstaller-\(UUID().uuidString)", isDirectory: true)
        fixtureContents = [
            .common: "// fixture _common.js\nmodule.exports = {};\n",
            .update: "// fixture update.js\n",
            .lifecycle: "// fixture lifecycle.js\n",
            .statusline: "// fixture statusline.js\n",
        ]
    }

    override func tearDownWithError() throws {
        if let homeDirectory, FileManager.default.fileExists(atPath: homeDirectory.path) {
            try? FileManager.default.removeItem(at: homeDirectory)
        }
        homeDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeInstaller(node: String = "/fixture/bin/node") -> HookInstaller {
        HookInstaller(
            paths: .init(homeDirectory: homeDirectory),
            scriptProvider: { [fixtureContents] script in Data(fixtureContents[script]!.utf8) },
            nodeExecutableResolver: { node }
        )
    }

    private var paths: HookInstaller.Paths { .init(homeDirectory: homeDirectory) }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.settingsURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ json: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func entries(_ settings: [String: Any], event: String) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return (hooks[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ settings: [String: Any], event: String) -> [String] {
        entries(settings, event: event).flatMap { entry -> [String] in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return [] }
            return hookList.compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Fresh install

    func testFreshInstall_writesExpectedKeysAndCopiesScripts() throws {
        let installer = makeInstaller()
        let result = try installer.install()

        XCTAssertEqual(Set(result.scriptsCopied), Set(HookScript.allCases.map(\.fileName)))
        XCTAssertFalse(result.didCreateBackup, "nothing existed yet, so there's nothing to back up")
        XCTAssertFalse(result.isChainingExistingStatusLine, "no prior statusline to chain")

        // Scripts copied verbatim.
        for script in HookScript.allCases {
            let copiedURL = paths.statusbarDirectory.appendingPathComponent(script.fileName)
            let copiedContent = try String(contentsOf: copiedURL, encoding: .utf8)
            XCTAssertEqual(copiedContent, fixtureContents[script])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionsDirectory.path))

        let settings = try readSettings()
        let expectedEvents: [String: (matcher: String?, script: HookScript, arg: String)] = [
            "SessionStart": (nil, .lifecycle, "start"),
            "SessionEnd": (nil, .lifecycle, "end"),
            "UserPromptSubmit": (nil, .update, "prompt"),
            "PreToolUse": ("*", .update, "pre"),
            "PostToolUse": ("*", .update, "post"),
            "PermissionRequest": ("*", .update, "permreq"),
            "Notification": (nil, .update, "notify"),
            "Stop": (nil, .update, "stop"),
        ]
        for (event, expected) in expectedEvents {
            let eventEntries = entries(settings, event: event)
            XCTAssertEqual(eventEntries.count, 1, "event \(event) should have exactly one entry")
            let entry = try XCTUnwrap(eventEntries.first)
            XCTAssertEqual(entry["matcher"] as? String, expected.matcher, "matcher for \(event)")
            let scriptPath = paths.statusbarDirectory.appendingPathComponent(expected.script.fileName).path
            let expectedCommand = "\"/fixture/bin/node\" \"\(scriptPath)\" \(expected.arg)"
            XCTAssertEqual(commands(settings, event: event), [expectedCommand])
        }

        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        let expectedStatusLineCommand = "\"/fixture/bin/node\" \"\(paths.statusbarDirectory.appendingPathComponent("statusline.js").path)\""
        XCTAssertEqual(statusLine["command"] as? String, expectedStatusLineCommand)

        XCTAssertEqual(installer.status(), .installed)
    }

    // MARK: - Idempotency

    func testInstallTwice_isIdempotent() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.install()

        let settings = try readSettings()
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop"] {
            XCTAssertEqual(entries(settings, event: event).count, 1, "running install() twice must not duplicate entries for \(event)")
        }
    }

    // MARK: - Foreign settings.json: backed up, non-marked keys preserved

    func testForeignSettingsJSON_isBackedUpAndNonMarkedKeysPreserved() throws {
        let foreign: [String: Any] = [
            "model": "custom-model",
            "env": ["SOME_OTHER_VAR": "keep-me"],
            "hooks": [
                "PreToolUse": [
                    ["matcher": "CustomTool", "hooks": [["type": "command", "command": "my-script.sh"]]]
                ]
            ],
        ]
        try write(foreign, to: paths.settingsURL)
        let originalData = try Data(contentsOf: paths.settingsURL)

        let installer = makeInstaller()
        let result = try installer.install()
        XCTAssertTrue(result.didCreateBackup)

        // Backup preserved verbatim.
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backupSettingsURL.path))
        XCTAssertEqual(try Data(contentsOf: paths.backupSettingsURL), originalData)

        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "custom-model")
        XCTAssertEqual((settings["env"] as? [String: Any])?["SOME_OTHER_VAR"] as? String, "keep-me")

        let preToolUseEntries = entries(settings, event: "PreToolUse")
        XCTAssertEqual(preToolUseEntries.count, 2, "the foreign matcher entry AND our matcher:* entry must both be present")
        XCTAssertTrue(preToolUseEntries.contains { $0["matcher"] as? String == "CustomTool" })
        XCTAssertTrue(preToolUseEntries.contains { $0["matcher"] as? String == "*" })

        // Second install must not duplicate our entry nor touch the foreign one again.
        try installer.install()
        let settingsAfterSecondInstall = try readSettings()
        XCTAssertEqual(entries(settingsAfterSecondInstall, event: "PreToolUse").count, 2)
    }

    // MARK: - Malformed settings.json: backup + proceed, never crash

    func testMalformedSettingsJSON_backsUpAndProceedsWithoutCrashing() throws {
        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        let garbage = Data("{ this is not valid json at all }}}".utf8)
        try garbage.write(to: paths.settingsURL)

        let installer = makeInstaller()
        // Must not throw.
        XCTAssertNoThrow(try installer.install())

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backupSettingsURL.path))
        XCTAssertEqual(try Data(contentsOf: paths.backupSettingsURL), garbage)

        let settings = try readSettings()
        XCTAssertEqual(entries(settings, event: "SessionStart").count, 1)
    }

    // MARK: - Uninstall: marker-guarded removal + statusline restore

    func testUninstall_removesOnlyMarkedKeysAndRestoresChainedStatusline() throws {
        let foreign: [String: Any] = [
            "statusLine": ["type": "command", "command": "~/bin/my-old-statusline.sh", "padding": 2],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "echo foreign-stop-hook"]]]]
            ],
        ]
        try write(foreign, to: paths.settingsURL)

        let installer = makeInstaller()
        let installResult = try installer.install()
        XCTAssertTrue(installResult.isChainingExistingStatusLine)
        XCTAssertEqual(try String(contentsOf: paths.origStatusLineURL, encoding: .utf8), "~/bin/my-old-statusline.sh")

        let afterInstall = try readSettings()
        XCTAssertEqual(entries(afterInstall, event: "Stop").count, 2, "our Stop entry + the foreign one")

        try installer.uninstall()

        XCTAssertEqual(installer.status(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.statusbarDirectory.path), "statusbar dir must be removed on uninstall")

        let afterUninstall = try readSettings()
        let statusLine = try XCTUnwrap(afterUninstall["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/my-old-statusline.sh", "original statusline restored")
        XCTAssertEqual(statusLine["padding"] as? Int, 2, "unrelated statusLine fields preserved")

        let stopEntries = entries(afterUninstall, event: "Stop")
        XCTAssertEqual(stopEntries.count, 1, "only the foreign Stop hook remains")
        XCTAssertEqual(commands(afterUninstall, event: "Stop"), ["echo foreign-stop-hook"])
    }

    func testUninstall_withNoPriorStatusline_removesOurStatusLineEntirely() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.uninstall()

        let settings = try readSettings()
        XCTAssertNil(settings["statusLine"], "no original to restore, and ours must be gone")
        XCTAssertNil(settings["hooks"], "all hook events were ours, so the whole key is gone")
    }

    // MARK: - status()

    func testStatus_reflectsNotInstalledInstalledAndDegraded() throws {
        let installer = makeInstaller()
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install()
        XCTAssertEqual(installer.status(), .installed)

        // Sabotage a script file directly (simulates a partial/corrupted install state).
        try FileManager.default.removeItem(at: paths.statusbarDirectory.appendingPathComponent("lifecycle.js"))
        XCTAssertEqual(installer.status(), .degraded)
    }

    // MARK: - repair()

    func testRepair_recopiesScriptsAndReassertsSettings() throws {
        let installer = makeInstaller()
        try installer.install()

        let lifecycleURL = paths.statusbarDirectory.appendingPathComponent("lifecycle.js")
        try Data("corrupted-by-accident".utf8).write(to: lifecycleURL)
        XCTAssertEqual(installer.status(), .installed, "file still exists, just wrong content — status() only checks presence")

        try installer.repair()

        XCTAssertEqual(try String(contentsOf: lifecycleURL, encoding: .utf8), fixtureContents[.lifecycle])
        let settings = try readSettings()
        XCTAssertEqual(entries(settings, event: "SessionStart").count, 1, "repair must not duplicate entries")
    }

    // MARK: - Bundled scripts are real (proves project.yml resource wiring, not just fixtures)

    func testDefaultScriptProvider_findsAllBundledScriptsNonEmpty() throws {
        let expectedMarkers: [HookScript: String] = [
            .common: "module.exports",
            .update: "Usage: node update.js",
            .lifecycle: "Usage: node lifecycle.js",
            .statusline: "Claude Code statusline wrapper",
        ]
        for script in HookScript.allCases {
            let data = try HookInstaller.defaultScriptProvider(script)
            XCTAssertFalse(data.isEmpty, "\(script.fileName) must not be an empty resource")
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(
                text.contains(expectedMarkers[script]!),
                "\(script.fileName) bundled content should contain '\(expectedMarkers[script]!)' — got prefix: \(text.prefix(80))"
            )
        }
    }

    // MARK: - Marker string sanity

    func testMarkerIsStatusbar() {
        XCTAssertEqual(HookInstaller.marker, "statusbar")
    }
}
