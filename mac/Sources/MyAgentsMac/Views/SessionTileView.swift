import SwiftUI
import MyAgentsMacCore

/// One session as a compact card in the popover grid: a left provider accent bar and three tight
/// lines — the session name (with an elapsed timer / pending dot in the top-right corner), the
/// folder name, and the full state label with its glyph (pulsing while busy). Three tiles sit per
/// row (see `PopoverRootView`, feedback 2026-07-11); the state label shrinks-to-fit at the narrower
/// width rather than truncating, so "Awaiting permission" / "Esperando permiso" still shows in full
/// (user feedback, 2026-07-09: "que se vea la carpeta y el estado sí o sí, que no se corte").
struct SessionTileView: View {
    let session: Session
    /// Opens the session: clears the pending "unopened" dot and brings its terminal to the front.
    /// Wired in `AppDelegate.activate`.
    let onActivate: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 0) {
                accentBar
                content
            }
            .frame(height: DesignTokens.Metrics.sessionTileHeight)
            .background(tileBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                    .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Pieces

    private var accentBar: some View {
        Rectangle()
            .fill(providerColor)
            .frame(width: DesignTokens.Metrics.accentBarWidth)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xxs) {
                Text(displayName)
                    .font(DesignTokens.Typography.rowTitle)
                    .foregroundStyle(DesignTokens.Colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DesignTokens.Spacing.xxs)

                topTrailing
            }

            folderRow

            Spacer(minLength: 0)

            stateRow
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Top-right corner of the name line: the live elapsed timer while busy, otherwise the
    /// pending "unopened" dot. Keeping the timer up here (not on the state line) frees the whole
    /// bottom line for the state label so it never has to share width and truncate.
    @ViewBuilder
    private var topTrailing: some View {
        if session.isBusy {
            elapsedTimer
        } else if session.pending {
            Circle()
                .fill(providerColor)
                .frame(width: DesignTokens.Metrics.dotSize, height: DesignTokens.Metrics.dotSize)
                .accessibilityHidden(true)
        }
    }

    /// Middle line: the working-directory folder name, always shown ("que se vea la carpeta sí o
    /// sí"). `session.folder` is already the basename, so no path parsing here.
    @ViewBuilder
    private var folderRow: some View {
        if !session.folder.isEmpty {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "folder")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                Text(session.folder)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityHidden(true)
        }
    }

    private var stateRow: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: stateSymbol)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(stateColor)
                // While busy the state glyph pulses in the provider colour — the macOS-native
                // equivalent of the Windows "moving glyph". `.symbolEffect` is energy-aware: the
                // system runs it ONLY while the view is on screen, so it stops the instant the
                // popover closes. Idle/ended tiles pass `isActive: false` and stay calm.
                .symbolEffect(.pulse, options: .repeating, isActive: session.isBusy)

            Text(session.state.localizedLabel)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(stateColor)
                .lineLimit(1)
                // Belt-and-braces so the label is NEVER cut: the three-up tile is narrower, so the
                // full text shrinks to fit (down to 70% ≈ 7.7pt) rather than truncating. This is
                // what preserves the "que no se corte" guarantee at the tighter column width.
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)

            Spacer(minLength: DesignTokens.Spacing.xxs)

            subagentBadge
        }
    }

    /// A small, tasteful pill on the state line — "2 agents" / "2 agentes" — shown only when this
    /// session has active subagents nested under it (a delegated `codex exec`; see
    /// `SessionLivenessJoin`). Neutral track fill + provider-tinted text so it reads as belonging to
    /// the session without shouting; hidden entirely when there are none. `fixedSize` keeps it from
    /// being squeezed by the shrinking state label to its left.
    @ViewBuilder
    private var subagentBadge: some View {
        if session.subagentCount > 0 {
            Text(subagentBadgeText)
                .font(DesignTokens.Typography.sectionHeader)
                .foregroundStyle(providerColor)
                .padding(.horizontal, DesignTokens.Spacing.xxs)
                .padding(.vertical, DesignTokens.Metrics.badgePaddingVertical)
                .background(Capsule().fill(DesignTokens.Colors.usageTrack))
                .overlay(Capsule().strokeBorder(DesignTokens.Colors.hairline, lineWidth: 1))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    /// The localized, plural-correct badge string (resolves the xcstrings plural variation for the
    /// count). Computed as a `String` so the same value can feed both the visible pill and the tile's
    /// combined accessibility label.
    private var subagentBadgeText: String {
        // Single-arg `LocalizationValue` form: the interpolated `%lld` key resolves the plural
        // variation defined in `Localizable.xcstrings` (`session.subagentCount %lld`).
        String(localized: "session.subagentCount \(session.subagentCount)")
    }

    @ViewBuilder
    private var elapsedTimer: some View {
        if session.isBusy, let startedAt = session.startedAt {
            // TimelineView drives the once-a-second tick only while this view is on screen — the
            // timer stops the moment the popover closes (energy law).
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(ElapsedTimeFormatter.format(since: startedAt, now: context.date) ?? "")
                    .font(DesignTokens.Typography.monoCaption)
                    .foregroundStyle(DesignTokens.Colors.secondaryForeground)
            }
        }
    }

    @ViewBuilder
    private var tileBackground: some View {
        if session.needsAttention {
            DesignTokens.Colors.attentionRowTint
        } else if isHovering {
            DesignTokens.Colors.hairline
        } else {
            DesignTokens.Colors.usageTrack
        }
    }

    // MARK: - Derived presentation

    /// Title line — resolved off the main thread by `SessionStore` (`SessionDisplayName.resolve`,
    /// preferring the transcript's AI-authored title). Re-resolved locally (pure, I/O-free) as a
    /// belt-and-braces guard against an empty value from a preview constructing a `Session` directly.
    private var displayName: String {
        session.displayName.isEmpty
            ? SessionDisplayName.resolve(aiTitle: nil, name: session.name, folder: session.folder)
            : session.displayName
    }

    private var providerColor: Color {
        session.provider == .claude ? DesignTokens.Colors.claudeOrange : DesignTokens.Colors.codexBlue
    }

    private var stateColor: Color {
        switch session.state {
        case .permission: return DesignTokens.Colors.permission
        case .thinking, .tool: return providerColor
        case .active: return providerColor
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
        case .active: return "terminal"
        }
    }

    /// Hover tooltip. The folder basename is on the tile face now, but the tooltip still pairs it
    /// with the name (and, unlike the truncated face, shows the folder in full on a narrow tile).
    private var helpText: String {
        session.folder.isEmpty ? displayName : "\(displayName) — \(session.folder)"
    }

    private var accessibilityLabel: String {
        let base = session.folder.isEmpty
            ? "\(displayName), \(session.state.localizedLabel)"
            : "\(displayName), \(session.folder), \(session.state.localizedLabel)"
        return session.subagentCount > 0 ? "\(base), \(subagentBadgeText)" : base
    }
}
