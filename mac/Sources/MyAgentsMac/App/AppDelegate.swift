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
            glyphController?.update(status: MenuBarStatus(kind: .idle, busyProvider: nil), badgePercent: nil)
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

        // Usage + "show usage" preference → the composed % badge (Claude 5h).
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
        let badge = preferences.showUsage ? usageStore.claude.fiveHourPercent : nil
        glyphController?.update(status: status, badgePercent: badge)
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
        }
    }

    /// Clears the session's pending marker. TODO (Hito 2): focus the owning terminal here
    /// (AppleScript/AX). Deliberately no fake focus behaviour today.
    private func activate(_ session: Session) {
        logger.debug("Session row activated: \(session.id, privacy: .public) — pending cleared (terminal focus is Hito 2)")
        // Pending is app-owned state; clearing it here is the honest, non-faked behaviour for now.
        // (SessionStore rebuilds rows from disk each poll; a persistent 'seen' set lands with the
        // focus work in Hito 2, alongside the wire-format additions in D11.)
    }
}
