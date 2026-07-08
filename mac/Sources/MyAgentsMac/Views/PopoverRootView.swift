import SwiftUI
import MyAgentsMacCore

/// The popover's SwiftUI content: header (with an optional small usage summary line, Fix 4) + ⚙
/// menu, then either first-run onboarding or the live session list. Thin — every decision it makes
/// (ordering, glyph state, elapsed time, usage formatting) is a tested Core function.
struct PopoverRootView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var model: AppViewModel

    /// Opens a session: clears its pending dot and focuses its terminal (see `AppDelegate.activate`).
    let onActivateSession: (Session) -> Void

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
            sessionStore.refresh()
            model.refreshStatus()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs / 2) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(String(localized: "menu.title", defaultValue: "MyAgents"))
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.foreground)
                Spacer()
                SettingsMenu(preferences: preferences, model: model)
            }
            if preferences.showUsage {
                usageSummary
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    /// Fix 4 (live user feedback, 2026-07-09): usage shown small, at the top, INSTEAD OF the
    /// menu-bar % badge and the old bottom bars section. One tight mono line per provider, e.g.
    /// `"Claude · 5h 30% · 7d 91%"`; Codex only gets its own line once it has ever reported a
    /// reading, so a Codex-less setup doesn't show a permanent "— · —" line for a provider that
    /// isn't in use.
    @ViewBuilder
    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs / 2) {
            usageLine(title: String(localized: "usage.claude", defaultValue: "Claude"), info: usageStore.claude)
            if usageStore.codex.hasFiveHourReading || usageStore.codex.hasSevenDayReading {
                usageLine(title: String(localized: "usage.codex", defaultValue: "Codex"), info: usageStore.codex)
            }
        }
    }

    private func usageLine(title: String, info: UsageInfo) -> some View {
        Text(UsageSummaryFormatter.line(providerTitle: title, info: info))
            .font(DesignTokens.Typography.monoCaption)
            .foregroundStyle(info.isStale ? DesignTokens.Colors.idle : DesignTokens.Colors.secondaryForeground)
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
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessionStore.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    ForEach(sessionStore.sessions) { session in
                        SessionRowView(session: session) { onActivateSession(session) }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, DesignTokens.Spacing.xs)
                // Fix 2 (live user feedback, 2026-07-09): pin the content to the popover's own
                // width instead of letting the ScrollView infer it from the available space. Left
                // to infer, the inferred width changes by the scrollbar's width the instant a
                // vertical scroll indicator appears/disappears (System Settings → "Show scroll
                // bars: Always" reserves real layout space, not just an overlay), which reads as
                // the whole list shifting sideways. A fixed width removes that dependency
                // entirely — the scrollbar can only overlay on top, never reflow the content.
                .frame(width: DesignTokens.Metrics.popoverWidth, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: DesignTokens.Metrics.popoverMaxListHeight)
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

    var body: some View {
        Menu {
            hookItems
            Divider()
            Toggle(String(localized: "menu.show-usage", defaultValue: "Show usage"), isOn: $preferences.showUsage)
            Toggle(String(localized: "menu.start-at-login", defaultValue: "Open at login"), isOn: startAtLoginBinding)
            Divider()
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

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.startAtLoginEnabled },
            set: { model.setStartAtLogin($0) }
        )
    }
}
