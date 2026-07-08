import Foundation
import os

/// The four Node scripts a running Claude Code hook actually `require`s (mirrors the `FILES`
/// array in `hooks/install.js`). `install.js`/`uninstall.js`/`install-codex.js` are the
/// standalone fallback entry points at the repo root — not bundled here, since no hook
/// invokes them directly; only these four are copied to `~/.claude/statusbar/`.
public enum HookScript: String, CaseIterable, Sendable {
    case common = "_common"
    case update
    case lifecycle
    case statusline

    public var fileName: String { "\(rawValue).js" }
}

/// Thrown only for genuine environment failures (e.g. a bundled script is missing at build
/// time) — never for a malformed `settings.json`, which is handled without throwing (see
/// `HookInstaller.install()`).
public enum HookInstallerError: Error, Sendable, Equatable {
    case missingBundledScript(String)
}

/// Self-installs (and can repair/uninstall) the Node hook scripts and wires them into
/// `~/.claude/settings.json`, so the Mac app doesn't require the user to run anything by hand.
///
/// This is the Swift twin of two existing pieces that MUST agree on the exact same
/// `settings.json` shape and marker:
/// - `hooks/install.js` / `hooks/uninstall.js` — the standalone Node fallback (repo root).
/// - `src/MyAgents/Services/HookInstaller.cs` — the Windows app's self-installer.
///
/// MARKER-GUARDED by construction: every hook command and the statusLine command we write
/// points at a script under `~/.claude/statusbar/…`, so the literal substring `"statusbar"`
/// (`HookInstaller.marker`) is always embedded in the command we own. We only ever touch
/// entries whose command already contains that marker — every other hook/statusLine entry in
/// a user's `settings.json`, however foreign, passes through completely untouched. The file is
/// backed up once (`.bak-ccapp`, never overwritten by a later run) before the first mutation,
/// exactly like `install.js`'s `.bak-ccapp` and `HookInstaller.cs`'s `Backup`.
public struct HookInstaller: Sendable {
    /// Every hook command and the statusLine command we write contains this marker (inside the
    /// `~/.claude/statusbar/…` script path) — see `hooks/install.js`'s `const MARKER`.
    public static let marker = "statusbar"

    public struct Paths: Sendable, Equatable {
        public let claudeDirectory: URL
        public let statusbarDirectory: URL
        public let sessionsDirectory: URL
        public let settingsURL: URL
        public let backupSettingsURL: URL
        public let origStatusLineURL: URL

        public init(homeDirectory: URL) {
            claudeDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
            statusbarDirectory = claudeDirectory.appendingPathComponent("statusbar", isDirectory: true)
            sessionsDirectory = statusbarDirectory.appendingPathComponent("sessions.d", isDirectory: true)
            settingsURL = claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
            backupSettingsURL = claudeDirectory.appendingPathComponent("settings.json.bak-ccapp", isDirectory: false)
            origStatusLineURL = statusbarDirectory.appendingPathComponent("orig-statusline.txt", isDirectory: false)
        }

        /// The real `~/.claude`. Tests MUST override with a temp directory — never point this
        /// at a real home directory from a unit test.
        public static var live: Paths { Paths(homeDirectory: FileManager.default.homeDirectoryForCurrentUser) }
    }

    /// What the UI needs to decide whether to offer "Install", "Repair", or "Uninstall".
    public enum Status: Sendable, Equatable {
        /// No marker-carrying hook/statusLine entries in `settings.json` (or no settings.json,
        /// or it's unreadable).
        case notInstalled
        /// Marker entries present in `settings.json` AND all four scripts exist on disk.
        case installed
        /// Marker entries present in `settings.json` but one or more scripts are missing —
        /// `repair()` will fix this.
        case degraded
    }

    public struct InstallResult: Sendable, Equatable {
        public let scriptsCopied: [String]
        /// True if, after this call, a foreign statusline is being chained (either newly
        /// captured this run, or already chained from a previous install).
        public let isChainingExistingStatusLine: Bool
        /// True if a pre-existing `settings.json` was backed up during THIS call (i.e. no
        /// `.bak-ccapp` existed yet before it).
        public let didCreateBackup: Bool
    }

    private let paths: Paths
    // `FileManager` isn't `Sendable`, but Apple documents instances as safe to use from
    // multiple threads for the read/write/move/exists operations this type performs — same
    // rationale as `SessionScanner`.
    nonisolated(unsafe) private let fileManager: FileManager
    private let scriptProvider: @Sendable (HookScript) throws -> Data
    private let nodeExecutableResolver: @Sendable () -> String
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "HookInstaller")

    /// - Parameters:
    ///   - paths: injectable so tests point at a temp `HOME` — NEVER the real `~/.claude`.
    ///   - scriptProvider: how to obtain each script's bytes. Defaults to the bundled copies
    ///     added to the app via `project.yml`; tests can inject fixture content instead.
    ///   - nodeExecutableResolver: how to find the `node` binary. Defaults to
    ///     `resolveNodeExecutable()`; tests inject a fixed fake path for determinism.
    public init(
        paths: Paths = .live,
        fileManager: FileManager = .default,
        scriptProvider: @escaping @Sendable (HookScript) throws -> Data = HookInstaller.defaultScriptProvider,
        nodeExecutableResolver: @escaping @Sendable () -> String = HookInstaller.resolveNodeExecutable
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.scriptProvider = scriptProvider
        self.nodeExecutableResolver = nodeExecutableResolver
    }

    // MARK: - Public API

    /// Fresh install: creates `~/.claude/statusbar/`, copies the 4 scripts, and merges our
    /// marker-guarded hook + statusLine entries into `settings.json`. Idempotent — safe to call
    /// on an already-installed environment (re-asserts the same entries, no duplicates).
    @discardableResult
    public func install() throws -> InstallResult { try installOrRepair() }

    /// Re-copies the scripts and re-asserts the settings entries. Identical operation to
    /// `install()` today (both are already idempotent) — kept as a distinct name because the UI
    /// offers it as a separate action when `status()` is `.degraded`.
    @discardableResult
    public func repair() throws -> InstallResult { try installOrRepair() }

    /// Removes ONLY our marker-carrying hook/statusLine entries from `settings.json`, restores
    /// the user's original statusline if we had chained one, and deletes `~/.claude/statusbar/`
    /// (scripts + `sessions.d/` + the sidecar) — mirrors `hooks/uninstall.js`. Every other key
    /// and every non-marked hook entry in `settings.json` is left exactly as it was.
    public func uninstall() throws {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            try removeStatusbarDirectory()
            return
        }

        var (settings, _) = try loadSettings()
        stripTitleDisableEnv(from: &settings)

        if var hooks = settings["hooks"] as? [String: Any] {
            for event in hooks.keys {
                guard let entries = hooks[event] as? [[String: Any]] else { continue }
                let kept = stripOurs(entries)
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }

        if let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           command.contains(HookScript.statusline.fileName) {
            // Read the sidecar BEFORE we delete ~/.claude/statusbar/ below — otherwise a crash
            // between the two steps would lose the user's original statusline forever.
            var original = ""
            if let data = try? Data(contentsOf: paths.origStatusLineURL),
               let text = String(data: data, encoding: .utf8) {
                original = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !original.isEmpty {
                var restored = statusLine
                restored["command"] = original
                settings["statusLine"] = restored
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }

        try save(settings)
        try removeStatusbarDirectory()
    }

    /// Read-only: what state is the install in, so the UI can offer Install / Repair / Uninstall.
    public func status() -> Status {
        guard fileManager.fileExists(atPath: paths.settingsURL.path),
              let data = try? Data(contentsOf: paths.settingsURL),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data),
              let settings = json as? [String: Any] else {
            return .notInstalled
        }

        guard hasMarkerHooks(in: settings) || hasMarkerStatusLine(in: settings) else {
            return .notInstalled
        }

        let scriptsPresent = HookScript.allCases.allSatisfy {
            fileManager.fileExists(atPath: paths.statusbarDirectory.appendingPathComponent($0.fileName).path)
        }
        return scriptsPresent ? .installed : .degraded
    }

    // MARK: - Bundled script lookup

    /// Locates the copy of `script` bundled into the app via `project.yml`'s `../hooks/*.js`
    /// resources on `MyAgentsMacCore`. [Verified against Apple docs: `Bundle(for:)` resolves to
    /// the framework bundle a class is defined in; `url(forResource:withExtension:)` looks it up
    /// in that bundle's Resources.]
    public static func defaultScriptProvider(_ script: HookScript) throws -> Data {
        guard let url = Bundle(for: BundleMarker.self).url(forResource: script.rawValue, withExtension: "js") else {
            throw HookInstallerError.missingBundledScript(script.fileName)
        }
        return try Data(contentsOf: url)
    }

    /// Finds an absolute path to `node`, since a GUI app launched by `launchd` does NOT inherit
    /// the user's interactive shell `PATH` (no `.zprofile`/nvm/Homebrew shims) — the same problem
    /// D12 solved for locating `codex`. Checks the common Homebrew/system locations first (fast,
    /// no subprocess), then falls back to a login shell's `PATH` resolution.
    public static func resolveNodeExecutable() -> String {
        let fileManager = FileManager.default
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let loginShellPath = resolveNodeViaLoginShell() { return loginShellPath }
        // Last resort: a bare literal relying on PATH at hook-execution time (Claude Code's own
        // hook runner may have a richer PATH than our launchd-started app did).
        return "node"
    }

    private static func resolveNodeViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Kill switch: never let a broken/slow login shell rc file hang installation.
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        guard let firstLine = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first,
            firstLine.hasPrefix("/") else { return nil }
        return String(firstLine)
    }

    // MARK: - install()/repair() shared implementation

    private func installOrRepair() throws -> InstallResult {
        try ensureDirectories()
        let copied = try copyScripts()
        let node = nodeExecutableResolver()
        let (chaining, didBackup) = try mergeSettings(node: node)
        return InstallResult(scriptsCopied: copied, isChainingExistingStatusLine: chaining, didCreateBackup: didBackup)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: paths.statusbarDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
    }

    private func copyScripts() throws -> [String] {
        var copied: [String] = []
        for script in HookScript.allCases {
            let data = try scriptProvider(script)
            let destination = paths.statusbarDirectory.appendingPathComponent(script.fileName, isDirectory: false)
            try writeAtomically(data, to: destination)
            copied.append(script.fileName)
        }
        return copied
    }

    /// Atomic swap (temp file + rename) so a mid-write hiccup can never leave a 0-byte hook
    /// script — every hook `require`s `_common.js`, so a truncated copy of it would break EVERY
    /// session. Mirrors `install.js`'s temp+rename copy and `HookInstaller.cs`'s `WriteScripts`.
    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp-\(ProcessInfo.processInfo.globallyUniqueString)")
        try data.write(to: tmp, options: .atomic)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - settings.json load / merge / save

    /// Loads `settings.json`, backing it up first (once, regardless of whether it turns out to
    /// be parseable) so a corrupt file's bytes are never lost. A malformed file (or one that
    /// isn't a JSON object) NEVER throws — it's treated as an empty settings object, matching
    /// the DoD requirement that a hostile `settings.json` never crashes the installer.
    private func loadSettings() throws -> (settings: [String: Any], didBackup: Bool) {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else {
            return ([:], false)
        }
        let didBackup = try backupSettingsIfNeeded()
        let data = (try? Data(contentsOf: paths.settingsURL)) ?? Data()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else {
            logger.error("""
            settings.json at \(paths.settingsURL.path, privacy: .public) is malformed or not a \
            JSON object — backed up to \(paths.backupSettingsURL.lastPathComponent, privacy: .public); \
            proceeding with a fresh settings object instead of crashing.
            """)
            return ([:], didBackup)
        }
        return (dict, didBackup)
    }

    /// Backs up the existing `settings.json` ONCE — never overwrites a prior backup. Mirrors
    /// `install.js` (`.bak-ccapp`) and `HookInstaller.cs`'s `Backup`.
    @discardableResult
    private func backupSettingsIfNeeded() throws -> Bool {
        guard fileManager.fileExists(atPath: paths.settingsURL.path) else { return false }
        guard !fileManager.fileExists(atPath: paths.backupSettingsURL.path) else { return false }
        try fileManager.copyItem(at: paths.settingsURL, to: paths.backupSettingsURL)
        return true
    }

    private func mergeSettings(node: String) throws -> (chaining: Bool, didBackup: Bool) {
        var (settings, didBackup) = try loadSettings()
        stripTitleDisableEnv(from: &settings)

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        addUnmatched(&hooks, event: "UserPromptSubmit", command: command(.update, arg: "prompt", node: node))
        addMatched(&hooks, event: "PreToolUse", command: command(.update, arg: "pre", node: node))
        addMatched(&hooks, event: "PostToolUse", command: command(.update, arg: "post", node: node))
        addUnmatched(&hooks, event: "Notification", command: command(.update, arg: "notify", node: node))
        addMatched(&hooks, event: "PermissionRequest", command: command(.update, arg: "permreq", node: node))
        addUnmatched(&hooks, event: "Stop", command: command(.update, arg: "stop", node: node))
        addUnmatched(&hooks, event: "SessionStart", command: command(.lifecycle, arg: "start", node: node))
        addUnmatched(&hooks, event: "SessionEnd", command: command(.lifecycle, arg: "end", node: node))
        settings["hooks"] = hooks

        let chaining = try mergeStatusLine(&settings, node: node)
        try save(settings)
        return (chaining, didBackup)
    }

    /// We WANT Claude to title the tab (its task summary is what the app would match for
    /// precise focus in Hito 2), so remove any legacy disable flag a prior version may have set
    /// — mirrors `install.js`.
    private func stripTitleDisableEnv(from settings: inout [String: Any]) {
        guard var env = settings["env"] as? [String: Any],
              env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] != nil else { return }
        env.removeValue(forKey: "CLAUDE_CODE_DISABLE_TERMINAL_TITLE")
        if env.isEmpty { settings.removeValue(forKey: "env") } else { settings["env"] = env }
    }

    /// Removes every hook entry that carries OUR marker, keeping every foreign entry — the core
    /// of the marker guard. An entry with mixed hooks (ours + foreign in the same array) keeps
    /// only the foreign ones.
    private func stripOurs(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry -> [String: Any]? in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return entry }
            let kept = hookList.filter { !(($0["command"] as? String ?? "").contains(HookInstaller.marker)) }
            guard !kept.isEmpty else { return nil }
            var newEntry = entry
            newEntry["hooks"] = kept
            return newEntry
        }
    }

    private func addUnmatched(_ hooks: inout [String: Any], event: String, command: String) {
        var entries = (hooks[event] as? [[String: Any]]).map(stripOurs) ?? []
        entries.append(["hooks": [["type": "command", "command": command]]])
        hooks[event] = entries
    }

    private func addMatched(_ hooks: inout [String: Any], event: String, command: String) {
        var entries = (hooks[event] as? [[String: Any]]).map(stripOurs) ?? []
        entries.append(["matcher": "*", "hooks": [["type": "command", "command": command]]])
        hooks[event] = entries
    }

    private func command(_ script: HookScript, arg: String, node: String) -> String {
        let path = paths.statusbarDirectory.appendingPathComponent(script.fileName, isDirectory: false).path
        return "\"\(node)\" \"\(path)\" \(arg)"
    }

    /// Point Claude Code's single `statusLine` field at our wrapper, which captures the OFFICIAL
    /// `rate_limits` from stdin (no tokens, no endpoint). If the user already had a statusline we
    /// CHAIN it: save the original command to a sidecar so the wrapper runs it and `uninstall()`
    /// restores it. Preserves every other field of the existing `statusLine` object (padding,
    /// etc.) — only the command changes. Returns whether a foreign statusline is being chained
    /// after this call.
    private func mergeStatusLine(_ settings: inout [String: Any], node: String) throws -> Bool {
        let ourCommand = "\"\(node)\" \"\(paths.statusbarDirectory.appendingPathComponent(HookScript.statusline.fileName).path)\""
        let existing = settings["statusLine"] as? [String: Any]
        let existingCommand = existing?["command"] as? String ?? ""
        let alreadyOurs = existingCommand.contains(HookScript.statusline.fileName)

        if existing != nil, !alreadyOurs, !existingCommand.isEmpty {
            try existingCommand.write(to: paths.origStatusLineURL, atomically: true, encoding: .utf8)
            logger.info("Chaining existing statusline (saved to \(paths.origStatusLineURL.lastPathComponent, privacy: .public)).")
        } else if existing == nil, fileManager.fileExists(atPath: paths.origStatusLineURL.path) {
            // No prior statusline → drop any stale sidecar so we render our own line.
            try? fileManager.removeItem(at: paths.origStatusLineURL)
        }
        // (alreadyOurs and existing != nil → re-install: keep any chained sidecar untouched,
        // just re-point the command below.)

        var statusLineObject = existing ?? [:]
        statusLineObject["type"] = "command"
        statusLineObject["command"] = ourCommand
        settings["statusLine"] = statusLineObject

        return fileManager.fileExists(atPath: paths.origStatusLineURL.path)
    }

    private func save(_ settings: [String: Any]) throws {
        try fileManager.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        let tmp = paths.settingsURL.appendingPathExtension("tmp-\(ProcessInfo.processInfo.globallyUniqueString)")
        try data.write(to: tmp, options: .atomic)
        do {
            if fileManager.fileExists(atPath: paths.settingsURL.path) {
                _ = try fileManager.replaceItemAt(paths.settingsURL, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: paths.settingsURL)
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    private func removeStatusbarDirectory() throws {
        guard fileManager.fileExists(atPath: paths.statusbarDirectory.path) else { return }
        try fileManager.removeItem(at: paths.statusbarDirectory)
    }

    // MARK: - status() helpers

    private func hasMarkerHooks(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                if hookList.contains(where: { ($0["command"] as? String ?? "").contains(HookInstaller.marker) }) {
                    return true
                }
            }
        }
        return false
    }

    private func hasMarkerStatusLine(in settings: [String: Any]) -> Bool {
        guard let statusLine = settings["statusLine"] as? [String: Any] else { return false }
        return (statusLine["command"] as? String ?? "").contains(HookScript.statusline.fileName)
    }
}

/// Pure marker class with no behavior — exists only so `Bundle(for: BundleMarker.self)` can
/// resolve to the `MyAgentsMacCore` framework bundle that the hook scripts are bundled into.
private final class BundleMarker {}
