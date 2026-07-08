import AppKit
import Foundation
import os

/// Click-to-focus: brings the terminal window (and, where the terminal's scripting allows, the
/// exact TAB) hosting a session to the front. macOS analogue of the Windows `TabFocuser`/
/// `WindowFocuser` (`src/MyAgents/Services/`): Windows uses UI Automation; macOS uses Apple Events
/// (AppleScript, via `/usr/bin/osascript`) for the tab-capable terminals and plain app activation
/// (`NSRunningApplication`, no Automation consent needed) for the window-only ones.
///
/// The DECISIONS are pure and unit-tested — `TerminalFocusPlanner.strategy(forTerminalHost:)`
/// (which terminal → tab-capable vs window-only) and `TerminalFocusScript` (the AppleScript SOURCE
/// builder, with `AppleScriptString.escaped` guarding against injection through the title marker).
/// Only the two side effects are thin and injectable: running the script and activating an app.
public struct TerminalFocuser: Sendable {
    /// Runs an AppleScript source string and yields its trimmed stdout (the terminals' scripts
    /// return a small token: `"tab"` when a tab was selected, `"app"` when only the app was
    /// activated), or an error (execution failure, including a TCC/Automation denial).
    public typealias ScriptRunner = @Sendable (String) -> Result<String, Error>
    /// Activates a window-only terminal app; returns `false` iff the app isn't running.
    public typealias AppActivator = @Sendable (TerminalAppTarget) -> Bool

    private let runScript: ScriptRunner
    private let activate: AppActivator
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "TerminalFocuser")

    public init(
        runScript: @escaping ScriptRunner = TerminalFocuser.runOsascript,
        activate: @escaping AppActivator = TerminalFocuser.activateRunningApp
    ) {
        self.runScript = runScript
        self.activate = activate
    }

    // MARK: - Focus

    /// Convenience over `focus(terminalHost:titleTag:)` reading both keys off the session.
    public func focus(session: Session) -> TerminalFocusResult {
        focus(terminalHost: session.terminalHost, titleTag: session.titleTag)
    }

    /// Brings the session's terminal forward. Never throws, never crashes: a missing app or a
    /// permission-denied script both come back as `.failed(reason:)`, logged.
    public func focus(terminalHost: String, titleTag: String) -> TerminalFocusResult {
        switch TerminalFocusPlanner.strategy(forTerminalHost: terminalHost) {
        case .appleTerminal, .iterm, .ghostty:
            return focusScriptable(TerminalFocusPlanner.strategy(forTerminalHost: terminalHost), titleTag: titleTag)
        case .windowOnly(let target):
            if activate(target) {
                logger.debug("Activated window-only terminal \(target.displayName, privacy: .public)")
                return .focusedWindow
            }
            logger.info("Window-only terminal \(target.displayName, privacy: .public) is not running")
            return .failed(reason: .appNotRunning)
        case .unsupported:
            logger.info("No focus strategy for terminalHost '\(terminalHost, privacy: .public)'")
            return .failed(reason: .unsupportedTerminal)
        }
    }

    private func focusScriptable(_ strategy: TerminalFocusStrategy, titleTag: String) -> TerminalFocusResult {
        guard let appName = strategy.scriptableAppName else { return .failed(reason: .unsupportedTerminal) }
        let marker = titleTag.trimmingCharacters(in: .whitespacesAndNewlines)

        // A marker shorter than 3 chars would match almost any tab title (same guard the Windows
        // reference uses) — degrade to "just bring the app forward" rather than land on the wrong
        // tab.
        let source: String
        if marker.count >= 3, let matchScript = TerminalFocusScript.build(strategy: strategy, titleTag: marker) {
            source = matchScript
        } else {
            source = TerminalFocusScript.activateOnly(appName: appName)
        }

        switch runScript(source) {
        case .success(let token):
            let result: TerminalFocusResult = (token == "tab") ? .focusedTab : .appActivatedOnly
            logger.debug("Focus \(appName, privacy: .public) → \(String(describing: result), privacy: .public)")
            return result
        case .failure(let error):
            // A denied Automation (Apple Events) prompt lands here — surfaced as `.failed`, never a
            // crash. The technical detail stays in the log (METODOLOGIA §4).
            logger.error("osascript focus of \(appName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed(reason: .scriptError)
        }
    }

    // MARK: - Default side effects (thin)

    /// Runs an AppleScript through `/usr/bin/osascript` (a separate, Apple-signed process — so this
    /// works under our hardened runtime without the `com.apple.security.automation.apple-events`
    /// entitlement; TCC still prompts once per target app, attributed to MyAgents via the
    /// `NSAppleEventsUsageDescription` in Info.plist). No shell is involved — the source is passed
    /// as a single argv entry — so the only injection surface is the AppleScript source itself,
    /// which is why `TerminalFocusScript` interpolates only `AppleScriptString.escaped` markers.
    public static func runOsascript(_ source: String) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errData, encoding: .utf8) ?? ""
                return .failure(TerminalFocusError.osascriptFailed(status: process.terminationStatus, message: message))
            }
            let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success(out)
        } catch {
            return .failure(error)
        }
    }

    /// Activates a window-only terminal by matching a running app against the target's bundle IDs
    /// (stable) or, failing that, its localized name. Plain app activation needs no Automation
    /// consent. Returns `false` iff no matching app is running.
    public static func activateRunningApp(_ target: TerminalAppTarget) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        let match = running.first { app in
            if let bundleID = app.bundleIdentifier, target.bundleIDs.contains(bundleID) { return true }
            if let name = app.localizedName,
               target.appNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return true }
            return false
        }
        guard let match else { return false }
        // Activation touches the window server — hop to the main thread.
        DispatchQueue.main.async {
            match.activate(options: [.activateAllWindows])
        }
        return true
    }
}

// MARK: - Result & failure

/// Outcome of a focus attempt, most-precise first.
public enum TerminalFocusResult: Equatable, Sendable {
    /// The exact tab hosting the session was selected and brought to the front.
    case focusedTab
    /// A window-only terminal (no tab scripting) had its window(s) brought forward — the best that
    /// terminal supports.
    case focusedWindow
    /// A tab-capable terminal was brought to the front but no tab matched the marker (e.g. the
    /// title was never stamped, or the tab was closed).
    case appActivatedOnly
    /// Nothing was focused; see `reason`. Always logged, never fatal.
    case failed(reason: TerminalFocusFailure)
}

public enum TerminalFocusFailure: Equatable, Sendable {
    /// `terminalHost` didn't map to any terminal we can drive.
    case unsupportedTerminal
    /// A window-only terminal that isn't currently running.
    case appNotRunning
    /// The AppleScript failed to execute (includes a denied Automation prompt).
    case scriptError
}

enum TerminalFocusError: Error {
    case osascriptFailed(status: Int32, message: String)
}

// MARK: - Strategy selection (pure, tested)

/// How a given terminal can be focused. `scriptableAppName` is the AppleScript application name for
/// the three tab-capable terminals (and `nil` for the rest).
public enum TerminalFocusStrategy: Equatable, Sendable {
    case appleTerminal            // Terminal.app — exact tab via AppleScript
    case iterm                    // iTerm2 — exact tab via AppleScript
    case ghostty                  // Ghostty (≥1.3) — exact tab via AppleScript
    case windowOnly(TerminalAppTarget)  // Warp / VS Code / Cursor — activate the app only
    case unsupported              // unknown / empty host — nothing safe to do

    public var scriptableAppName: String? {
        switch self {
        case .appleTerminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .windowOnly, .unsupported: return nil
        }
    }
}

/// A window-only terminal app and the keys used to find it among running apps. Bundle IDs are the
/// stable primary key; localized names are the fallback (e.g. Cursor's bundle ID is generated and
/// may change between builds).
public struct TerminalAppTarget: Equatable, Sendable {
    public let displayName: String
    public let bundleIDs: [String]
    public let appNames: [String]

    public init(displayName: String, bundleIDs: [String], appNames: [String]) {
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.appNames = appNames
    }

    // TERM_PROGRAM → app. Bundle IDs web-verified 2026-07-08 (see return notes).
    public static let warp = TerminalAppTarget(
        displayName: "Warp",
        bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
        appNames: ["Warp"]
    )
    public static let vscode = TerminalAppTarget(
        displayName: "Visual Studio Code",
        bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        appNames: ["Code", "Visual Studio Code"]
    )
    public static let cursor = TerminalAppTarget(
        displayName: "Cursor",
        bundleIDs: ["com.todesktop.230313mzl4w4u92"],
        appNames: ["Cursor"]
    )
}

public enum TerminalFocusPlanner {
    /// Maps the hook's `terminalHost` (the shell's `TERM_PROGRAM`) to a focus strategy. Case- and
    /// whitespace-insensitive. Anything unrecognized is `.unsupported` (best-effort = don't guess
    /// and focus the wrong app — mirrors the Windows reference's "better to fall through than
    /// guess").
    public static func strategy(forTerminalHost host: String) -> TerminalFocusStrategy {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple_terminal": return .appleTerminal
        case "iterm.app": return .iterm
        case "ghostty": return .ghostty
        case "warpterminal": return .windowOnly(.warp)
        case "vscode": return .windowOnly(.vscode)
        case "cursor": return .windowOnly(.cursor)
        default: return .unsupported
        }
    }
}

// MARK: - AppleScript string escaping (pure, tested)

/// Escapes an arbitrary string for safe interpolation into an AppleScript double-quoted literal.
/// The title marker is derived from a project name, so treat it as HOSTILE: a bare `"` would end
/// the literal and let the rest be parsed as AppleScript (`… & do shell script "…"`). We escape `\`
/// and `"`, and drop control characters (newline/CR/tab/DEL and anything below U+0020) so nothing
/// can terminate the literal or inject a new statement.
public enum AppleScriptString {
    public static func escaped(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count + 2)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\":
                out.append("\\"); out.append("\\")
            case "\"":
                out.append("\\"); out.append("\"")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                out.append(scalar)
            }
        }
        return String(out)
    }
}

// MARK: - AppleScript source builder (pure, tested)

/// Builds the AppleScript SOURCE for the three tab-capable terminals. Each script walks the
/// terminal's window/tab hierarchy, matches the tab whose title CONTAINS the (escaped) marker,
/// selects that tab and raises its window, then `activate`s the app — returning `"tab"` on a match
/// or `"app"` when only the app was brought forward. Verified against each terminal's scripting
/// docs (see return notes for URLs).
public enum TerminalFocusScript {
    public static func build(strategy: TerminalFocusStrategy, titleTag: String) -> String? {
        let marker = AppleScriptString.escaped(titleTag)
        switch strategy {
        case .appleTerminal: return appleTerminal(marker: marker)
        case .iterm: return iterm(marker: marker)
        case .ghostty: return ghostty(marker: marker)
        case .windowOnly, .unsupported: return nil
        }
    }

    /// Bare "bring the app to the front" fallback (no marker available / too short to be safe).
    public static func activateOnly(appName: String) -> String {
        """
        tell application "\(AppleScriptString.escaped(appName))"
        \tactivate
        \treturn "app"
        end tell
        """
    }

    private static func appleTerminal(marker: String) -> String {
        """
        tell application "Terminal"
        \tset theMarker to "\(marker)"
        \tset matched to false
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\tset tt to ""
        \t\t\ttry
        \t\t\t\tset tt to custom title of t
        \t\t\tend try
        \t\t\tif tt is not missing value and tt contains theMarker then
        \t\t\t\tset selected tab of w to t
        \t\t\t\tset index of w to 1
        \t\t\t\tset frontmost of w to true
        \t\t\t\tset matched to true
        \t\t\t\texit repeat
        \t\t\tend if
        \t\tend repeat
        \t\tif matched then exit repeat
        \tend repeat
        \tactivate
        \tif matched then
        \t\treturn "tab"
        \telse
        \t\treturn "app"
        \tend if
        end tell
        """
    }

    private static func iterm(marker: String) -> String {
        """
        tell application "iTerm2"
        \tset theMarker to "\(marker)"
        \tset matched to false
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\trepeat with s in sessions of t
        \t\t\t\tset sn to ""
        \t\t\t\ttry
        \t\t\t\t\tset sn to name of s
        \t\t\t\tend try
        \t\t\t\tif sn contains theMarker then
        \t\t\t\t\ttell t to select
        \t\t\t\t\ttell w to select
        \t\t\t\t\tset matched to true
        \t\t\t\t\texit repeat
        \t\t\t\tend if
        \t\t\tend repeat
        \t\t\tif matched then exit repeat
        \t\tend repeat
        \t\tif matched then exit repeat
        \tend repeat
        \tactivate
        \tif matched then
        \t\treturn "tab"
        \telse
        \t\treturn "app"
        \tend if
        end tell
        """
    }

    private static func ghostty(marker: String) -> String {
        """
        tell application "Ghostty"
        \tset theMarker to "\(marker)"
        \tset matched to false
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\trepeat with term in terminals of t
        \t\t\t\tset tn to ""
        \t\t\t\ttry
        \t\t\t\t\tset tn to name of term
        \t\t\t\tend try
        \t\t\t\tif tn contains theMarker then
        \t\t\t\t\tselect t
        \t\t\t\t\tfocus term
        \t\t\t\t\tset matched to true
        \t\t\t\t\texit repeat
        \t\t\t\tend if
        \t\t\tend repeat
        \t\t\tif matched then exit repeat
        \t\tend repeat
        \t\tif matched then exit repeat
        \tend repeat
        \tactivate
        \tif matched then
        \t\treturn "tab"
        \telse
        \t\treturn "app"
        \tend if
        end tell
        """
    }
}
