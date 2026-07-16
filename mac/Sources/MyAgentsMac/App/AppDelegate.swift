import AppKit
import SwiftUI
import Combine
import os
import Sparkle
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
    /// The torn-off floating window (lazily built the first time the popover is dragged out). Kept
    /// alive across returns (`isReleasedWhenClosed = false`) so the same panel is reused.
    private var detachedWindow: NSWindow?

    private let sessionStore = SessionStore()
    private let usageStore = UsageStore()
    private let preferences = AppPreferences()
    private let model = AppViewModel()
    private let notifier = PermissionNotifier()
    private let terminalFocuser = TerminalFocuser()
    /// Sparkle auto-updater. Reads `SUFeedURL`/`SUPublicEDKey` from Info.plist; `startingUpdater:
    /// true` lets it schedule background checks (and ask the user, on first launch, whether to check
    /// automatically). Only meaningful for the direct-.zip install path — Homebrew users update via
    /// `brew upgrade`. See `onCheckForUpdates` (the ⚙ menu's "Check for Updates…").
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
        // Usage polling is NOT started here: it's an opt-in feature (`showUsage`, off by default)
        // and each refresh spawns `zsh -l` + `codex app-server`. `bindStores()` drives
        // start/stop from the `showUsage` preference — whose `@Published` delivers its persisted
        // value on subscription, so an install with usage enabled still starts on its own.

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

    /// The popover is created empty and only gets its SwiftUI content when it's actually shown (see
    /// `mountPopoverContent`), which is then released again on close (`popoverDidClose`).
    ///
    /// ENERGY LAW (measured 2026-07-12): a retained `NSHostingController` keeps its SwiftUI view
    /// alive and SUBSCRIBED to the stores even while the popover is invisible — and with
    /// `sizingOptions = [.preferredContentSize]`, every store change makes AppKit re-measure it. With
    /// sessions publishing as agents work, that was `NSHostingView.layout` running forever on a view
    /// nobody can see: 643 of 8078 samples in the idle profile. A closed popover must cost nothing.
    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
    }

    /// Builds the popover's SwiftUI content if it isn't mounted. Cheap: it happens on a click, at
    /// human speed, not on the 2 Hz poll.
    private func mountPopoverContent(_ popover: NSPopover) {
        guard popover.contentViewController == nil else { return }
        let hosting = NSHostingController(rootView: makeRootView(isDetached: false))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// The SwiftUI root, parameterised by where it's hosted. Both the anchored popover and the
    /// torn-off window observe the SAME stores, so they show identical live data — the detached
    /// copy just additionally offers the "return to the menu bar" affordance.
    private func makeRootView(isDetached: Bool) -> PopoverRootView {
        PopoverRootView(
            sessionStore: sessionStore,
            usageStore: usageStore,
            preferences: preferences,
            model: model,
            onActivateSession: { [weak self] session in self?.activate(session) },
            isDetached: isDetached,
            onReturnToMenuBar: { [weak self] in self?.returnToMenuBar() },
            onCheckForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) }
        )
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

        // Usage (both providers) + the "show usage" and chosen-metric preferences → the menu-bar
        // percentage badge. Codex is bound too now that either provider can be the chosen metric.
        usageStore.$claude
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGlyph() }
            .store(in: &cancellables)

        usageStore.$codex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGlyph() }
            .store(in: &cancellables)

        // The `showUsage` toggle both gates the periodic usage polling (start it only while the
        // feature is on — otherwise `zsh -l`/`codex app-server` would run every minute for a hidden
        // section) AND drives the menu-bar badge. `@Published` delivers the persisted value on
        // subscription, so this also performs the initial start/stop at launch.
        preferences.$showUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                guard let self else { return }
                if show { self.usageStore.start() } else { self.usageStore.stop() }
                self.refreshGlyph()
            }
            .store(in: &cancellables)

        preferences.$menuBarUsageMetric
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGlyph() }
            .store(in: &cancellables)
    }

    private func refreshGlyph(sessions: [Session]? = nil) {
        let status = MenuBarStatus.evaluate(sessions ?? sessionStore.sessions)
        let usage: MenuBarUsage?
        if preferences.showUsage {
            let metric = preferences.menuBarUsageMetric
            let reading = metric.reading(claude: usageStore.claude, codex: usageStore.codex)
            usage = MenuBarUsage(percent: reading.percent, provider: metric.provider, isStale: reading.isStale)
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
            // Off-main rescan: don't block the click (and don't scan twice — `onAppear` no longer
            // rescans). The popover shows the live `sessions` immediately; the fresh scan lands a
            // beat later.
            sessionStore.refreshSoon()
            model.refreshStatus()
            NSApp.activate(ignoringOtherApps: true)
            mountPopoverContent(popover)
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

// MARK: - Tear-off: drag the popover out into a floating window, return it to the menu bar

extension AppDelegate: NSPopoverDelegate {
    /// Let the user drag the popover off the status item — macOS then "tears it off" into the
    /// window returned by `detachableWindow(for:)`. This is the built-in detach gesture (feedback
    /// 2026-07-11: "arrástralo y que escape de ahí, que se quede flotante").
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    /// Release the popover's SwiftUI content the moment it's no longer on screen, so nothing stays
    /// subscribed to the stores and re-laying-out invisibly (see `configurePopover`). It's rebuilt on
    /// the next click. Safe with the tear-off: the detached window hosts its OWN root view
    /// (`makeDetachedWindow`), so dropping this one takes nothing away from it.
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
    }

    /// The window the torn-off popover becomes: a lightweight always-on-top panel (so the sessions
    /// stay visible while you work in another app) hosting the SAME SwiftUI root in `isDetached`
    /// mode. We own its content, so the anchored popover and this window are independent views over
    /// the shared stores — no content is "stolen" from the popover.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let window = detachedWindow ?? makeDetachedWindow()
        mountDetachedContent(window)
        return window
    }

    /// Same energy law as the popover (see `configurePopover`): the torn-off window is reused across
    /// detaches, so its SwiftUI content is mounted when it's about to be shown and dropped again in
    /// `windowWillClose` — a hidden window must not keep a view subscribed to the stores.
    private func mountDetachedContent(_ window: NSWindow) {
        guard window.contentViewController == nil else { return }
        let hosting = NSHostingController(rootView: makeRootView(isDetached: true))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
    }

    private func makeDetachedWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Metrics.popoverWidth, height: 1),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        // Chrome-light: no visible title, content runs edge-to-edge under a transparent titlebar,
        // draggable from anywhere. Minimise/zoom are hidden — an accessory app has no Dock tile to
        // minimise into, and "return to the menu bar" is the in-header button, not the traffic light.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Always-on-top so the panel keeps watch over other apps (Miguel's pick, 2026-07-11).
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        detachedWindow = window
        return window
    }

    /// The in-header "return" button (and the window's close button) both re-anchor to the menu bar:
    /// just hide the floating window. The next status-item click shows the popover anchored again.
    private func returnToMenuBar() {
        detachedWindow?.close()
    }
}

// MARK: - The torn-off window's content dies with its visibility

extension AppDelegate: NSWindowDelegate {
    /// The window is kept (and reused) across detaches, but its SwiftUI tree must not outlive its
    /// visibility: an invisible `NSHostingView` still observes the stores and still re-lays-out on
    /// every change. `detachableWindow(for:)` re-mounts it on the next tear-off.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === detachedWindow else { return }
        detachedWindow?.contentViewController = nil
    }
}
