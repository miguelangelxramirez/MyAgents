import AppKit
import SwiftUI
import Combine
import os
import MyAgentsMacCore

/// Owns the whole menu-bar surface: the `NSStatusItem`, its animated glyph, the `NSPopover`
/// hosting the SwiftUI popover, the two Core stores, notifications, and preferences.
///
/// Wiring, in one place: the session store drives (a) the aggregate glyph via `MenuBarStatus` and
/// (b) permission banners via the edge-detector; the usage store + "show usage" preference drive
/// the composed % badge. All the actual decisions live in tested Core functions — this class is
/// glue.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var glyphController: MenuBarGlyphController?

    private let sessionStore = SessionStore()
    private let usageStore = UsageStore()
    private let preferences = AppPreferences()
    private let model = AppViewModel()
    private let notifier = PermissionNotifier()
    private let terminalFocuser = TerminalFocuser()

    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Delegate must be set before launch completes (HITO1_DESIGN / Apple guidance).
        notifier.configure()

        configureStatusItem()
        configurePopover()
        bindStores()

        model.refreshStatus()
        sessionStore.start()
        usageStore.start()

        logger.info("MyAgents menu bar launched — version \(BuildInfo.version, privacy: .public) (\(BuildInfo.buildDateDescription, privacy: .public))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionStore.stop()
        usageStore.stop()
    }

    // MARK: - Status item + popover

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover)
            button.target = self
            glyphController = MenuBarGlyphController(button: button)
            glyphController?.update(status: MenuBarStatus(kind: .idle, busyProvider: nil), usage: nil)
        }
        statusItem = item
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let root = PopoverRootView(
            sessionStore: sessionStore,
            usageStore: usageStore,
            preferences: preferences,
            model: model,
            onActivateSession: { [weak self] session in self?.activate(session) }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
    }

    // MARK: - Reactive wiring

    private func bindStores() {
        // Sessions → glyph + permission banners.
        sessionStore.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.refreshGlyph(sessions: sessions)
                self?.notifier.handle(sessions: sessions)
            }
            .store(in: &cancellables)

        // Usage + "show usage" preference → the menu-bar usage badge (Claude 5h/7d mini bars).
        usageStore.$claude
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGlyph() }
            .store(in: &cancellables)

        preferences.$showUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGlyph() }
            .store(in: &cancellables)
    }

    private func refreshGlyph(sessions: [Session]? = nil) {
        let status = MenuBarStatus.evaluate(sessions ?? sessionStore.sessions)
        let usage: MenuBarUsage?
        if preferences.showUsage {
            let claude = usageStore.claude
            usage = MenuBarUsage(
                fiveHour: claude.fiveHourPercent,
                sevenDay: claude.sevenDayPercent,
                isStale: claude.isStale
            )
        } else {
            usage = nil
        }
        glyphController?.update(status: status, usage: usage)
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sessionStore.refresh()
            model.refreshStatus()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover window key so SwiftUI controls INSIDE it (the session-row buttons,
            // which live in a ScrollView) receive the click. Without this, an LSUIElement app's
            // transient popover window isn't key and the first click on a row is swallowed — the
            // symptom Miguel hit: "clicking a session does nothing" (no focus, no log).
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Clicking a row: acknowledge it (clear the pending dot now) and bring its terminal — the exact
    /// tab where the terminal's scripting allows — to the front. The focus runs off the main thread
    /// (Apple Events round-trip / app lookup); a failure shows a localized note, never a crash.
    private func activate(_ session: Session) {
        // `.notice` (persisted, unlike `.info`) so a click is verifiable in `log show` — this path
        // silently not running was exactly what made the "clicks do nothing" bug hard to see.
        logger.notice("row click → activate session \(session.id, privacy: .public) host=\(session.terminalHost, privacy: .public)")
        // The click is the "opened" signal: clear pending immediately regardless of focus outcome.
        sessionStore.markSeen(session.id)

        let focuser = terminalFocuser
        let terminalHost = session.terminalHost
        let title = session.displayName
        let titleTag = session.titleTag
        let id = session.id
        Task.detached { [weak self] in
            let result = focuser.focus(terminalHost: terminalHost, title: title, titleTag: titleTag)
            await self?.handleFocusResult(result, sessionID: id)
        }
    }

    private func handleFocusResult(_ result: TerminalFocusResult, sessionID: String) {
        switch result {
        case .focusedTab, .focusedWindow, .appActivatedOnly:
            logger.notice("Focus \(sessionID, privacy: .public): \(String(describing: result), privacy: .public)")
        case .failed(let reason):
            logger.notice("Focus \(sessionID, privacy: .public) failed: \(String(describing: reason), privacy: .public)")
            model.showTransientMessage(String(localized: "focus.failed", defaultValue: "Couldn't open that session's terminal"))
        }
    }
}
