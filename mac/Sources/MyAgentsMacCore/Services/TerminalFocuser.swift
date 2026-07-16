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

    /// Convenience over `focus(terminalHost:title:titleTag:)` reading the keys off the session.
    /// `title` is `session.displayName` (the resolved aiTitle) — the PRIMARY match key, because
    /// empirically (verified on this machine) Terminal.app/iTerm2/Ghostty stamp the tab's
    /// name/custom-title with Claude's task-summary title (plus a leading status glyph), not the
    /// `titleTag` marker. `titleTag` stays as a secondary fallback for setups that do embed the
    /// `⟦cc:…⟧` marker in the title.
    public func focus(session: Session) -> TerminalFocusResult {
        focus(terminalHost: session.terminalHost, title: session.displayName, titleTag: session.titleTag, tty: session.tty)
    }

    /// Brings the session's terminal forward. Never throws, never crashes: a missing app or a
    /// permission-denied script both come back as `.failed(reason:)`, logged.
    ///
    /// - Parameters:
    ///   - title: the session's resolved display title (aiTitle) — matched against the terminal's
    ///     tab title with a CONTAINS check, tolerating a leading glyph/whitespace Claude Code
    ///     prepends (e.g. tab title `"⠐ Adapt Windows app to macOS"` contains title `"Adapt Windows
    ///     app to macOS"`).
    ///   - titleTag: the `⟦cc:…⟧` focus marker — a secondary fallback CONTAINS match for setups
    ///     that put the marker literally in the title instead.
    /// - Parameter tty: the session's controlling terminal device path (`/dev/ttys005`) when the
    ///   session was discovered as a live process (a Codex session). When present, it drives an
    ///   EXACT tab match by tty on Terminal.app/iTerm2 — more reliable than the title heuristic, and
    ///   the only match key a Codex session has (it stamps no aiTitle). Empty → title matching.
    public func focus(terminalHost: String, title: String, titleTag: String, tty: String = "") -> TerminalFocusResult {
        let titleSource = Self.describeTitleSource(title: title, titleTag: titleTag)
        logger.info("Focus start: host='\(terminalHost, privacy: .public)' using \(tty.isEmpty ? titleSource : "tty", privacy: .public)")

        let result: TerminalFocusResult
        switch TerminalFocusPlanner.strategy(forTerminalHost: terminalHost) {
        case .appleTerminal, .iterm, .ghostty:
            result = focusScriptable(TerminalFocusPlanner.strategy(forTerminalHost: terminalHost), title: title, titleTag: titleTag, tty: tty)
        case .windowOnly(let target):
            if activate(target) {
                result = .focusedWindow
            } else {
                result = .failed(reason: .appNotRunning)
            }
        case .unsupported:
            result = .failed(reason: .unsupportedTerminal)
        }

        logger.info("Focus result: host='\(terminalHost, privacy: .public)' → \(String(describing: result), privacy: .public)")
        return result
    }

    /// Which key (if any) will drive the tab match — logged at `.info` (not the title's CONTENT,
    /// which may be a user's project name/prompt) so a diagnostic session shows "what happened"
    /// without leaking the title text itself.
    private static func describeTitleSource(title: String, titleTag: String) -> String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 { return "title(aiTitle)" }
        if titleTag.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 { return "titleTag(marker)" }
        return "none"
    }

    private func focusScriptable(_ strategy: TerminalFocusStrategy, title: String, titleTag: String, tty: String) -> TerminalFocusResult {
        guard let appName = strategy.scriptableAppName else { return .failed(reason: .unsupportedTerminal) }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = titleTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTty = tty.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer an EXACT tty match (Codex sessions) over the title heuristic. A marker shorter than
        // 3 chars would match almost any tab title (same guard the Windows reference uses) — degrade
        // to "just bring the app forward" rather than land on the wrong tab.
        let source: String
        if !trimmedTty.isEmpty, let ttyScript = TerminalFocusScript.buildByTTY(strategy: strategy, tty: trimmedTty) {
            source = ttyScript
        } else if let matchScript = TerminalFocusScript.build(strategy: strategy, title: trimmedTitle, titleTag: trimmedTag) {
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
/// terminal's window/tab hierarchy, matches the tab whose title CONTAINS the (escaped) title
/// and/or titleTag marker — case-insensitively (AppleScript's `contains` is case-insensitive by
/// DEFAULT; wrapped in an explicit `ignoring case` block anyway for self-documentation, per the
/// AppleScript Language Guide "Considering/Ignoring" — verified 2026-07-09,
/// developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html)
/// — selects that tab and raises its window, then `activate`s the app — returning `"tab"` on a
/// match or `"app"` when only the app was brought forward. Verified against each terminal's
/// scripting docs (see return notes for URLs).
///
/// `title` (the session's aiTitle) is the PRIMARY key: empirically, Terminal.app's `custom title`
/// (and iTerm2/Ghostty's session/terminal `name`) is Claude's task-summary title with a leading
/// status glyph — e.g. `"⠐ Adapt Windows app to macOS with menu bar design"` — which CONTAINS the
/// aiTitle but never the `⟦cc:…⟧` `titleTag` marker. `titleTag` is a secondary fallback CONTAINS
/// clause (`OR`) for setups that do embed the marker in the title.
public enum TerminalFocusScript {
    /// `nil` when neither `title` nor `titleTag` is long enough (≥3 chars) to be a safe marker —
    /// the caller then falls back to `activateOnly`.
    public static func build(strategy: TerminalFocusStrategy, title: String, titleTag: String) -> String? {
        let titleMarker = title.count >= 3 ? AppleScriptString.escaped(title) : nil
        let tagMarker = titleTag.count >= 3 ? AppleScriptString.escaped(titleTag) : nil
        guard titleMarker != nil || tagMarker != nil else { return nil }
        switch strategy {
        case .appleTerminal: return appleTerminal(titleMarker: titleMarker, tagMarker: tagMarker)
        case .iterm: return iterm(titleMarker: titleMarker, tagMarker: tagMarker)
        case .ghostty: return ghostty(titleMarker: titleMarker, tagMarker: tagMarker)
        case .windowOnly, .unsupported: return nil
        }
    }

    /// Builds an EXACT-tab-by-tty script for the terminals whose scripting exposes a tab/session
    /// `tty` — Terminal.app (`tty of tab`) and iTerm2 (`tty of session`), both verified against their
    /// scripting dictionaries (2026-07). Ghostty exposes no tty, so it returns `nil` and the caller
    /// falls back to the title heuristic. The tty is a device path we produced (`/dev/ttysNNN`), but
    /// it's escaped anyway (defense in depth), and matched with `is` (exact), never `contains`.
    public static func buildByTTY(strategy: TerminalFocusStrategy, tty: String) -> String? {
        let escaped = AppleScriptString.escaped(tty)
        switch strategy {
        case .appleTerminal: return appleTerminalByTTY(tty: escaped)
        case .iterm: return itermByTTY(tty: escaped)
        case .ghostty, .windowOnly, .unsupported: return nil
        }
    }

    /// NOTE: the window is raised with `set frontmost of w to true` ALONE. An earlier version also
    /// did `set index of w to 1` first — but on macOS 26 that silently fails to reorder (the window's
    /// `index` stays put) AND leaves the window behind whichever one was already frontmost, so a
    /// session in a non-front window would select its tab yet never come forward: only the session
    /// whose window happened to be frontmost appeared to work (Miguel, 2026-07-16 — "solo abre una").
    /// Verified on this machine: `frontmost` alone raises the correct window every time.
    private static func appleTerminalByTTY(tty: String) -> String {
        """
        tell application "Terminal"
        \tset matched to false
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\tset td to ""
        \t\t\ttry
        \t\t\t\tset td to tty of t
        \t\t\tend try
        \t\t\tif td is "\(tty)" then
        \t\t\t\tset selected tab of w to t
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

    private static func itermByTTY(tty: String) -> String {
        """
        tell application "iTerm2"
        \tset matched to false
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\trepeat with s in sessions of t
        \t\t\t\tset td to ""
        \t\t\t\ttry
        \t\t\t\t\tset td to tty of s
        \t\t\t\tend try
        \t\t\t\tif td is "\(tty)" then
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

    /// Bare "bring the app to the front" fallback (no marker available / too short to be safe).
    public static func activateOnly(appName: String) -> String {
        """
        tell application "\(AppleScriptString.escaped(appName))"
        \tactivate
        \treturn "app"
        end tell
        """
    }

    /// Builds the `(variable contains "…") or (variable contains "…")` condition from whichever
    /// marker(s) are available. At least one of `titleMarker`/`tagMarker` is guaranteed non-nil by
    /// `build`'s guard.
    private static func matchCondition(variable: String, titleMarker: String?, tagMarker: String?) -> String {
        var clauses: [String] = []
        if let titleMarker { clauses.append("\(variable) contains \"\(titleMarker)\"") }
        if let tagMarker { clauses.append("\(variable) contains \"\(tagMarker)\"") }
        return "(" + clauses.joined(separator: " or ") + ")"
    }

    private static func appleTerminal(titleMarker: String?, tagMarker: String?) -> String {
        let condition = matchCondition(variable: "tt", titleMarker: titleMarker, tagMarker: tagMarker)
        return """
        tell application "Terminal"
        \tset matched to false
        \tignoring case
        \t\trepeat with w in windows
        \t\t\trepeat with t in tabs of w
        \t\t\t\tset tt to ""
        \t\t\t\ttry
        \t\t\t\t\tset tt to custom title of t
        \t\t\t\tend try
        \t\t\t\tif tt is not missing value and \(condition) then
        \t\t\t\t\tset selected tab of w to t
        \t\t\t\t\tset frontmost of w to true
        \t\t\t\t\tset matched to true
        \t\t\t\t\texit repeat
        \t\t\t\tend if
        \t\t\tend repeat
        \t\t\tif matched then exit repeat
        \t\tend repeat
        \tend ignoring
        \tactivate
        \tif matched then
        \t\treturn "tab"
        \telse
        \t\treturn "app"
        \tend if
        end tell
        """
    }

    private static func iterm(titleMarker: String?, tagMarker: String?) -> String {
        let condition = matchCondition(variable: "sn", titleMarker: titleMarker, tagMarker: tagMarker)
        return """
        tell application "iTerm2"
        \tset matched to false
        \tignoring case
        \t\trepeat with w in windows
        \t\t\trepeat with t in tabs of w
        \t\t\t\trepeat with s in sessions of t
        \t\t\t\t\tset sn to ""
        \t\t\t\t\ttry
        \t\t\t\t\t\tset sn to name of s
        \t\t\t\t\tend try
        \t\t\t\t\tif \(condition) then
        \t\t\t\t\t\ttell t to select
        \t\t\t\t\t\ttell w to select
        \t\t\t\t\t\tset matched to true
        \t\t\t\t\t\texit repeat
        \t\t\t\t\tend if
        \t\t\t\tend repeat
        \t\t\t\tif matched then exit repeat
        \t\t\tend repeat
        \t\t\tif matched then exit repeat
        \t\tend repeat
        \tend ignoring
        \tactivate
        \tif matched then
        \t\treturn "tab"
        \telse
        \t\treturn "app"
        \tend if
        end tell
        """
    }

    private static func ghostty(titleMarker: String?, tagMarker: String?) -> String {
        let condition = matchCondition(variable: "tn", titleMarker: titleMarker, tagMarker: tagMarker)
        return """
        tell application "Ghostty"
        \tset matched to false
        \tignoring case
        \t\trepeat with w in windows
        \t\t\trepeat with t in tabs of w
        \t\t\t\trepeat with term in terminals of t
        \t\t\t\t\tset tn to ""
        \t\t\t\t\ttry
        \t\t\t\t\t\tset tn to name of term
        \t\t\t\t\tend try
        \t\t\t\t\tif \(condition) then
        \t\t\t\t\t\tselect t
        \t\t\t\t\t\tfocus term
        \t\t\t\t\t\tset matched to true
        \t\t\t\t\t\texit repeat
        \t\t\t\t\tend if
        \t\t\t\tend repeat
        \t\t\t\tif matched then exit repeat
        \t\t\tend repeat
        \t\t\tif matched then exit repeat
        \t\tend repeat
        \tend ignoring
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
