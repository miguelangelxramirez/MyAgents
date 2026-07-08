import SwiftUI
import MyAgentsMacCore

/// First-run consent (local-first, D3): shown in the popover when hooks aren't installed. It
/// explains, in plain language, that enabling writes tracking hooks into `~/.claude` — MyAgents
/// never silently modifies the user's config without this visible affordance.
struct OnboardingView: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: DesignTokens.Metrics.heroGlyphPointSize, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.claudeOrange)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(String(localized: "onboarding.title", defaultValue: "Watch your agent sessions"))
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.foreground)

                Text(String(localized: "onboarding.body", defaultValue: "MyAgents adds a few local hooks to ~/.claude so it can show what each Claude Code and Codex session is doing. Everything stays on your Mac — no tokens, no network."))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onEnable) {
                Text(String(localized: "onboarding.enable", defaultValue: "Enable tracking"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.claudeOrange)
        }
        .padding(DesignTokens.Spacing.s)
    }
}
