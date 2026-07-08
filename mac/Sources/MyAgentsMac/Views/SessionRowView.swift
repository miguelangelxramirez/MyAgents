import SwiftUI
import MyAgentsMacCore

/// One session row: a provider accent bar, three lines (name · folder · state), a discreet elapsed
/// timer while busy, a pending dot, and an amber wash when the session needs a human.
struct SessionRowView: View {
    let session: Session
    /// Clears the pending flag. TODO (Hito 2): also focus the owning terminal (AppleScript/AX) —
    /// deliberately NOT faked here; today the click only dismisses the "unopened" dot.
    let onActivate: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                accentBar

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs / 2) {
                    topLine
                    Text(session.folder.isEmpty ? " " : session.folder)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    stateLine
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Pieces

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.accentBarWidth / 2, style: .continuous)
            .fill(providerColor)
            .frame(width: DesignTokens.Metrics.accentBarWidth, height: DesignTokens.Metrics.accentBarHeight)
    }

    private var topLine: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(displayName)
                .font(DesignTokens.Typography.rowTitle)
                .foregroundStyle(DesignTokens.Colors.foreground)
                .lineLimit(1)
                .truncationMode(.tail)

            if session.pending {
                Circle()
                    .fill(providerColor)
                    .frame(width: DesignTokens.Metrics.dotSize, height: DesignTokens.Metrics.dotSize)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            elapsedTimer
        }
    }

    @ViewBuilder
    private var elapsedTimer: some View {
        if session.isBusy, let startedAt = session.startedAt {
            // TimelineView drives the once-a-second tick and, crucially, only while this view is on
            // screen — so the timer stops the moment the popover closes (energy law).
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(ElapsedTimeFormatter.format(since: startedAt, now: context.date) ?? "")
                    .font(DesignTokens.Typography.monoCaption)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
            }
        }
    }

    private var stateLine: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: stateSymbol)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(stateColor)
            Text(session.state.localizedLabel)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
        if session.needsAttention {
            shape.fill(DesignTokens.Colors.attentionRowTint)
        } else if isHovering {
            shape.fill(DesignTokens.Colors.hairline)
        } else {
            shape.fill(Color.clear)
        }
    }

    // MARK: - Derived presentation

    private var displayName: String {
        if !session.name.isEmpty { return session.name }
        if !session.folder.isEmpty { return session.folder }
        return String(localized: "session.untitled", defaultValue: "Session")
    }

    private var providerColor: Color {
        session.provider == .claude ? DesignTokens.Colors.claudeOrange : DesignTokens.Colors.codexTeal
    }

    private var stateColor: Color {
        switch session.state {
        case .permission: return DesignTokens.Colors.permission
        case .thinking, .tool: return providerColor
        case .idle, .ended: return DesignTokens.Colors.secondaryForeground
        }
    }

    private var stateSymbol: String {
        switch session.state {
        case .permission: return "exclamationmark.triangle.fill"
        case .thinking: return "ellipsis"
        case .tool: return "hammer.fill"
        case .idle: return "pause.circle"
        case .ended: return "checkmark.circle"
        }
    }

    private var accessibilityLabel: String {
        "\(displayName), \(session.folder), \(session.state.localizedLabel)"
    }
}
