import SwiftUI
import AppKit
import MyAgentsMacCore

/// Popover content for Hito 0: a plain list of session rows plus a Quit action. The animated
/// glyph, usage bars and polished layout are Hito 1 (CONTEXT.md §4) — this view exists to prove
/// the store/scanner plumbing end to end, on `DesignTokens`, nothing more.
struct SessionListView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(String(localized: "menu.title", defaultValue: "MyAgents"))
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Colors.foreground)
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.top, DesignTokens.Spacing.xs)

            Divider()

            if store.sessions.isEmpty {
                Text(String(localized: "sessions.empty", defaultValue: "No active sessions"))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                    .padding(DesignTokens.Spacing.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        ForEach(store.sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.xxs)
            Divider()

            Button(String(localized: "menu.quit", defaultValue: "Quit MyAgents")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryForeground)
            .font(DesignTokens.Typography.caption)
            .padding(DesignTokens.Spacing.xs)
        }
        .frame(width: 280, height: 320)
        .background(DesignTokens.Colors.background)
        .onAppear { store.refresh() }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.name.isEmpty ? session.folder : session.name)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.foreground)
                .lineLimit(1)
            Text("\(session.folder) · \(session.state.localizedLabel)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(providerColor)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var providerColor: Color {
        session.provider == .claude ? DesignTokens.Colors.claudeOrange : DesignTokens.Colors.codexTeal
    }
}
