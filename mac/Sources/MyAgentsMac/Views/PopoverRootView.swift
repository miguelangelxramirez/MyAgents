import SwiftUI
import MyAgentsMacCore

/// The popover's SwiftUI content: header + ⚙ menu, then either first-run onboarding or the live
/// session list, with the optional usage section pinned at the bottom. Thin — every decision it
/// makes (ordering, glyph state, elapsed time, usage severity) is a tested Core function.
struct PopoverRootView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var model: AppViewModel

    /// Opens a session: clears its pending dot and focuses its terminal (see `AppDelegate.activate`).
    let onActivateSession: (Session) -> Void

    /// `true` when this view is hosted in the torn-off floating window rather than the menu-bar
    /// popover — flips the header's anchored/detached affordance (shows the "return" button).
    var isDetached: Bool = false
    /// Re-anchors the window back to the menu bar (closes the floating window). No-op in the popover.
    var onReturnToMenuBar: () -> Void = {}
    /// Triggers a user-initiated Sparkle update check (⚙ menu → "Check for Updates…"). No-op in
    /// previews/tests that don't wire the updater.
    var onCheckForUpdates: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DesignTokens.Colors.hairline)

            if let message = model.transientMessage {
                transientBanner(message)
            }

            content
        }
        .frame(width: DesignTokens.Metrics.popoverWidth)
        .background(VisualEffectBackground())
        .onAppear {
            // No session rescan here: opening the popover already kicks one off-main
            // (`AppDelegate.togglePopover` → `refreshSoon`). A second synchronous `refresh()` on the
            // main actor was the audit's "scans twice on open" (2026-07-16).
            model.refreshStatus()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(String(localized: "menu.title", defaultValue: "MyAgents"))
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Colors.foreground)
            Spacer()
            if isDetached {
                returnToMenuBarButton
            }
            SettingsMenu(preferences: preferences, model: model, onCheckForUpdates: onCheckForUpdates)
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    /// Only in the torn-off window: sends the floating panel back to the menu bar. The inward
    /// "collapse" arrows read as "put it away" — the counterpart to the drag-out that detached it.
    private var returnToMenuBarButton: some View {
        Button(action: onReturnToMenuBar) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)
        }
        .buttonStyle(.plain)
        .help(String(localized: "menu.return-to-menubar", defaultValue: "Return to the menu bar"))
        .accessibilityLabel(String(localized: "menu.return-to-menubar", defaultValue: "Return to the menu bar"))
    }

    private func transientBanner(_ message: String) -> some View {
        Text(message)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.s)
            .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.hookStatus == .notInstalled {
            OnboardingView(onEnable: { model.installHooks() })
        } else {
            sessionList

            if preferences.showUsage {
                Divider().overlay(DesignTokens.Colors.hairline)
                UsageSectionView(claude: usageStore.claude, codex: usageStore.codex)
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .padding(.vertical, DesignTokens.Spacing.s)
            }
        }
    }

    /// Three flexible columns, evenly gapped — the sessions read as a grid of compact cards
    /// (`SessionTileView`) instead of a tall vertical list (feedback 2026-07-11: "de 3 en 3").
    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
            count: DesignTokens.Metrics.sessionGridColumns
        )
    }

    /// The scroll viewport's exact height for the current session count: one row for ≤3 sessions,
    /// two full rows for more, and scroll-in-place past two rows — always a whole number of rows so
    /// no half-cut row ever peeks (`SessionGridLayout`, tested). Includes the grid's own vertical
    /// padding so the visible content lines up flush with the frame.
    private var sessionListHeight: CGFloat {
        let rows = SessionGridLayout.visibleRows(
            sessionCount: sessionStore.sessions.count,
            columns: DesignTokens.Metrics.sessionGridColumns,
            maxRows: DesignTokens.Metrics.sessionMaxVisibleRows
        )
        return SessionGridLayout.viewportHeight(
            rows: rows,
            tileHeight: DesignTokens.Metrics.sessionTileHeight,
            rowGap: DesignTokens.Spacing.xs,
            verticalPadding: DesignTokens.Spacing.xs
        )
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessionStore.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(sessionStore.sessions) { session in
                        SessionTileView(session: session) { onActivateSession(session) }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.s)
                .padding(.vertical, DesignTokens.Spacing.xs)
                // Fix 2 (live user feedback, 2026-07-09): pin the content to the popover's own
                // width instead of letting the ScrollView infer it from the available space. Left
                // to infer, the inferred width changes by the scrollbar's width the instant a
                // vertical scroll indicator appears/disappears (System Settings → "Show scroll
                // bars: Always" reserves real layout space, not just an overlay), which reads as
                // the whole grid shifting sideways. A fixed width removes that dependency
                // entirely — the scrollbar can only overlay on top, never reflow the content.
                .frame(width: DesignTokens.Metrics.popoverWidth, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(height: sessionListHeight)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "moon.zzz")
                .font(.system(size: DesignTokens.Metrics.emptyGlyphPointSize, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)
            Text(String(localized: "sessions.empty", defaultValue: "No active sessions"))
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.l)
    }
}

/// The ⚙ settings menu. A SwiftUI `Menu` renders as a native `NSMenu` on macOS; the actions call
/// through to `AppViewModel` (hook ops off-main, About panel, quit).
private struct SettingsMenu: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var model: AppViewModel
    /// Triggers a user-initiated Sparkle update check (see `AppDelegate.updaterController`).
    var onCheckForUpdates: () -> Void = {}

    var body: some View {
        Menu {
            hookItems
            Divider()
            Toggle(String(localized: "menu.show-usage", defaultValue: "Show usage"), isOn: $preferences.showUsage)
            if preferences.showUsage {
                menuBarMetricPicker
            }
            Toggle(String(localized: "menu.start-at-login", defaultValue: "Open at login"), isOn: startAtLoginBinding)
            Divider()
            Button(String(localized: "menu.check-updates", defaultValue: "Check for Updates…"), action: onCheckForUpdates)
            Button(String(localized: "menu.about", defaultValue: "About MyAgents")) { model.showAbout() }
            Button(String(localized: "menu.quit", defaultValue: "Quit MyAgents")) { model.quit() }
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "menu.settings.a11y", defaultValue: "Settings"))
    }

    @ViewBuilder
    private var hookItems: some View {
        switch model.hookStatus {
        case .notInstalled:
            Button(String(localized: "menu.hooks.enable", defaultValue: "Enable tracking")) { model.installHooks() }
        case .installed:
            Button(String(localized: "menu.hooks.repair", defaultValue: "Repair tracking")) { model.repairHooks() }
            Button(String(localized: "menu.hooks.remove", defaultValue: "Remove tracking")) { model.removeHooks() }
        case .degraded:
            Button(String(localized: "menu.hooks.repair", defaultValue: "Repair tracking")) { model.repairHooks() }
            Button(String(localized: "menu.hooks.remove", defaultValue: "Remove tracking")) { model.removeHooks() }
        }
    }

    /// Which single percentage the menu-bar glyph shows (Claude/Codex × 5h/7d). A SwiftUI `Picker`
    /// in a `Menu` renders as a native submenu with a checkmark on the selection. Only shown while
    /// "Show usage" is on (an inert picker for a hidden badge would just be noise).
    private var menuBarMetricPicker: some View {
        Picker(
            String(localized: "menu.usage-metric", defaultValue: "Menu bar shows"),
            selection: $preferences.menuBarUsageMetric
        ) {
            ForEach(MenuBarUsageMetric.allCases, id: \.self) { metric in
                Text(Self.label(for: metric)).tag(metric)
            }
        }
    }

    /// "Claude · 5 h" etc. Provider names are brands (kept as-is); the window reuses the same
    /// localized "5 h"/"7 d" strings the popover's usage rows use.
    private static func label(for metric: MenuBarUsageMetric) -> String {
        let provider = metric.provider == .codex
            ? String(localized: "usage.codex", defaultValue: "Codex")
            : String(localized: "usage.claude", defaultValue: "Claude")
        let window = metric.window == .fiveHour
            ? String(localized: "usage.window.5h", defaultValue: "5 h")
            : String(localized: "usage.window.7d", defaultValue: "7 d")
        return "\(provider) · \(window)"
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.startAtLoginEnabled },
            set: { model.setStartAtLogin($0) }
        )
    }
}
