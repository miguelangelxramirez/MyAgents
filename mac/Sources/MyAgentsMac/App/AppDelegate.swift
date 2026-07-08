import AppKit
import SwiftUI
import os
import MyAgentsMacCore

/// Builds the menu-bar `NSStatusItem` + `NSPopover`. Hito 0 scope only: a static SF Symbol glyph
/// and a popover that lists sessions as plain rows. The animated/colored glyph, usage badge and
/// polished popover are Hito 1.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let sessionStore = SessionStore()
    private let logger = Logger(subsystem: "com.miguelangelramirez.myagents.mac", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces: LSUIElement already keeps us out of the Dock, but setting the
        // activation policy explicitly makes the "menu-bar-only" intent obvious in code too.
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        logger.info("MyAgents menu bar launched — version \(BuildInfo.version, privacy: .public) (\(BuildInfo.buildDateDescription, privacy: .public))")
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: String(localized: "menu.title", defaultValue: "MyAgents")
            )
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 320)
        popover.contentViewController = NSHostingController(rootView: SessionListView(store: sessionStore))
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sessionStore.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
