import SwiftUI
import MyAgentsMacCore

/// One session row: a provider accent bar, three lines (name · folder · state), a discreet elapsed
/// timer while busy, a pending dot, and an amber wash when the session needs a human.
struct SessionRowView: View {
    let session: Session
    /// Opens the session: clears the pending "unopened" dot and brings its terminal (the exact tab
    /// where the terminal's scripting allows) to the front. Wired in `AppDelegate.activate`.
    let onActivate: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                accentBar

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs / 2) {
                    topLine
                    Text(folderLineText)
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
                // Make a WORKING session unmistakable (user feedback: "tengo una trabajando y no
                // sale NINGUNA trabajando"). While busy (thinking / tool) the state glyph pulses in
                // the provider colour — the macOS-native equivalent of the Windows "moving glyph".
                // `.symbolEffect` is energy-aware: the system runs it ONLY while the view is on
                // screen, so it stops the instant the popover closes (no forever-Timer). Idle/ended
                // rows pass `isActive: false` and stay calm.
                .symbolEffect(.pulse, options: .repeating, isActive: session.isBusy)
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

    /// The title line — resolved off the main thread by `SessionStore`
    /// (`SessionDisplayName.resolve`, preferring the transcript's AI-authored title over the raw
    /// hook `name`, and NEVER falling back to the folder). Guarded against an unresolved/empty
    /// value (e.g. a preview constructing a `Session` directly) by re-resolving locally — this is
    /// pure and I/O-free, so it's safe to call from the view.
    private var displayName: String {
        session.displayName.isEmpty
            ? SessionDisplayName.resolve(aiTitle: nil, name: session.name, folder: session.folder)
            : session.displayName
    }

    /// The folder line. `SessionDisplayName.resolve` guarantees the title never just repeats the
    /// folder, but this is a last-resort belt-and-braces check: if some edge case ever DID produce
    /// an identical title and folder, showing the same text twice is exactly the bug being fixed —
    /// so blank the second line instead.
    private var folderLineText: String {
        if session.folder.isEmpty { return " " }
        return displayName.caseInsensitiveCompare(session.folder) == .orderedSame ? " " : session.folder
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
        let folderPart = folderLineText.trimmingCharacters(in: .whitespaces)
        return folderPart.isEmpty
            ? "\(displayName), \(session.state.localizedLabel)"
            : "\(displayName), \(folderPart), \(session.state.localizedLabel)"
    }
}
