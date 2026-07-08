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

    /// Clears a session's pending flag (Hito 2 will also focus its terminal).
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
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(String(localized: "menu.title", defaultValue: "MyAgents"))
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Colors.foreground)
            Spacer()
            SettingsMenu(preferences: preferences, model: model)
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
        .padding(.vertical, DesignTokens.Spacing.xs)
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
            }
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
