import SwiftUI
import MyAgentsMacCore

/// The bottom usage section: Claude + Codex 5h/7d bars, coloured by provider, shifting to
/// warn/high as a window fills. A stale reading is greyed with a "N min ago" note; an unknown
/// value renders "—", never a fabricated 0%.
struct UsageSectionView: View {
    let claude: UsageInfo
    let codex: UsageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(String(localized: "usage.header", defaultValue: "Usage"))
                .font(DesignTokens.Typography.sectionHeader)
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)

            UsageProviderView(
                title: String(localized: "usage.claude", defaultValue: "Claude"),
                info: claude,
                provider: .claude
            )
            UsageProviderView(
                title: String(localized: "usage.codex", defaultValue: "Codex"),
                info: codex,
                provider: .codex
            )
        }
    }
}

private struct UsageProviderView: View {
    let title: String
    let info: UsageInfo
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.foreground)
                if info.isStale, let minutes = UsageAge.minutes(since: info.capturedAt) {
                    Text(staleNote(minutes: minutes))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                }
            }

            UsageBarRow(
                label: String(localized: "usage.window.5h", defaultValue: "5 h"),
                percent: info.fiveHourPercent,
                provider: provider,
                stale: info.isStale
            )
            UsageBarRow(
                label: String(localized: "usage.window.7d", defaultValue: "7 d"),
                percent: info.sevenDayPercent,
                provider: provider,
                stale: info.isStale
            )
        }
    }

    private func staleNote(minutes: Int) -> String {
        String(localized: "usage.stale", defaultValue: "· \(minutes) min ago")
    }
}

private struct UsageBarRow: View {
    let label: String
    let percent: Double?
    let provider: Provider
    let stale: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(DesignTokens.Typography.monoCaption)
                .foregroundStyle(DesignTokens.Colors.secondaryForeground)
                .frame(width: DesignTokens.Metrics.usageLabelWidth, alignment: .leading)

            UsageBar(fraction: fraction, color: fillColor)

            Text(valueText)
                .font(DesignTokens.Typography.monoCaption)
                .foregroundStyle(stale ? DesignTokens.Colors.secondaryForeground : DesignTokens.Colors.foreground)
                .frame(width: DesignTokens.Metrics.usageValueWidth, alignment: .trailing)
        }
    }

    private var fraction: Double? {
        percent.map { max(0, min(1, $0 / 100)) }
    }

    private var valueText: String {
        guard let percent else {
            return String(localized: "usage.unknown", defaultValue: "—")
        }
        return "\(Int(percent.rounded()))%"
    }

    /// Provider accent normally; amber/red as the window fills; muted grey when the reading is
    /// stale (so a greyed bar visually matches its greyed number).
    private var fillColor: Color {
        if stale { return DesignTokens.Colors.idle }
        guard let percent else { return DesignTokens.Colors.idle }
        switch UsageLevel.forPercent(percent) {
        case .normal:
            return provider == .claude ? DesignTokens.Colors.claudeOrange : DesignTokens.Colors.codexTeal
        case .warn:
            return DesignTokens.Colors.usageWarn
        case .high:
            return DesignTokens.Colors.usageHigh
        }
    }
}

private struct UsageBar: View {
    /// 0...1, or `nil` for an unknown reading (empty track only — no fabricated fill).
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.Colors.usageTrack)
                if let fraction {
                    Capsule()
                        .fill(color)
                        .frame(width: fraction * geometry.size.width)
                }
            }
        }
        .frame(height: DesignTokens.Metrics.usageBarHeight)
    }
}
