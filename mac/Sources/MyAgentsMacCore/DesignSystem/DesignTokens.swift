import SwiftUI
import AppKit

/// Central design system for MyAgents Mac.
///
/// METODOLOGIA §6 ("un estándar de diseño es ley, no documento"): views are OBLIGED to use these
/// tokens. A literal color/spacing/font value in view code is a build-review violation, not a
/// style nit — the whole point of a design system is that it's the only place literals live.
public enum DesignTokens {

    public enum Colors {
        // Provider + state accents are the EXACT values shipped in the Windows product
        // (`src/MyAgents/Ui/Palette.cs`) so both platforms read identically. Appearance-independent
        // (same in light/dark) — they are brand/semantic accents, not surfaces.

        /// Anthropic/Claude accent — provider colour for the left accent bar, badges, busy glyph.
        /// Windows `ProviderClaude`/`Busy` = RGB(217,119,87) = #D97757.
        public static let claudeOrange = Color(red: 217/255, green: 119/255, blue: 87/255)

        /// OpenAI Codex accent — Windows `ProviderCodex` = RGB(64,196,180) = #40C4B4.
        public static let codexTeal = Color(red: 64/255, green: 196/255, blue: 180/255)

        /// Awaiting-permission accent (attention). Windows `Permission` = RGB(235,190,70) = #EBBE46.
        public static let permission = Color(red: 235/255, green: 190/255, blue: 70/255)

        /// Idle/ready accent. Windows `Idle` = RGB(120,120,128).
        public static let idle = Color(red: 120/255, green: 120/255, blue: 128/255)

        /// Usage bar warning / high thresholds. Windows `UsageWarn` / `UsageHigh`.
        public static let usageWarn = Color(red: 232/255, green: 170/255, blue: 80/255)
        public static let usageHigh = Color(red: 226/255, green: 108/255, blue: 108/255)

        /// Very low-alpha amber wash behind a row that `needsAttention`, so the whole row (not just
        /// a dot) reads as "this one wants you" — a hue, not an opaque fill, so the system material
        /// still shows through. Derived from `permission` on purpose (single source of the amber).
        public static let attentionRowTint = permission.opacity(0.14)

        /// Hairline separators / usage-bar troughs — a faint neutral that works on the material in
        /// both appearances without a hard opaque line.
        public static let hairline = adaptive(
            light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.12)
        )

        /// Track behind a usage bar's fill.
        public static let usageTrack = adaptive(
            light: NSColor(calibratedWhite: 0.0, alpha: 0.08),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.10)
        )

        /// Semantic popover background, light/dark aware.
        public static let background = adaptive(
            light: NSColor(calibratedWhite: 1.00, alpha: 1),
            dark: NSColor(calibratedWhite: 0.11, alpha: 1)
        )

        /// Semantic primary text, light/dark aware.
        public static let foreground = adaptive(
            light: NSColor(calibratedWhite: 0.09, alpha: 1),
            dark: NSColor(calibratedWhite: 0.95, alpha: 1)
        )

        /// Semantic secondary/muted text, light/dark aware.
        public static let secondaryForeground = adaptive(
            light: NSColor(calibratedWhite: 0.42, alpha: 1),
            dark: NSColor(calibratedWhite: 0.68, alpha: 1)
        )

        /// Builds a `Color` that resolves to `light` or `dark` depending on the effective
        /// appearance, via `NSColor(name:dynamicProvider:)` (AppKit, available since macOS 10.15).
        private static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }
    }

    /// 8pt grid (with 4pt half-steps for tight rows). Every spacing literal in a view must come
    /// from here.
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 16
        public static let m: CGFloat = 24
        public static let l: CGFloat = 32
        public static let xl: CGFloat = 40

        /// All scale steps, smallest to largest — exists so tests can assert on the whole scale
        /// (grid compliance, monotonicity) without hand-listing the cases twice.
        public static let scale: [CGFloat] = [xxs, xs, s, m, l, xl]
    }

    public enum Typography {
        public static let title = Font.system(size: 13, weight: .semibold)
        public static let body = Font.system(size: 12, weight: .regular)
        public static let caption = Font.system(size: 11, weight: .regular)
        /// Uppercased section label (usage header). Small, tracked, muted in use.
        public static let sectionHeader = Font.system(size: 10, weight: .semibold)
        /// Row name — a touch heavier than `body` so the session name anchors each row.
        public static let rowTitle = Font.system(size: 12, weight: .medium)
        /// Elapsed timer / percentages — monospaced digits so a live-updating value never jitters
        /// the layout as digits change width.
        public static let monoCaption = Font.system(size: 11, weight: .regular).monospacedDigit()
    }

    /// Corner radii — the only place rounded-rect literals live (design-token law: no magic radius
    /// in a view).
    public enum Radius {
        public static let small: CGFloat = 5
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
    }

    /// Fixed pixel metrics that aren't spacing (bar widths/heights, dot sizes, the popover width).
    /// Kept out of `Spacing` because they're not on the 8pt gap grid — they're component sizes.
    public enum Metrics {
        /// Popover content width. Roomy enough for a folder path + state without wrapping, narrow
        /// enough to feel like a menu, not a window. Bumped 300 → 340 (live user feedback, Fix 3)
        /// for more breathing room around the top usage summary line and longer folder paths.
        public static let popoverWidth: CGFloat = 340
        /// Left provider accent bar.
        public static let accentBarWidth: CGFloat = 3
        public static let accentBarHeight: CGFloat = 34
        /// Usage progress bar.
        public static let usageBarHeight: CGFloat = 5
        /// Pending / activity dot.
        public static let dotSize: CGFloat = 7
        /// Menu-bar glyph point size (drawn into the status item image).
        public static let glyphPointSize: CGFloat = 15
        /// Max height of the scrolling session list before it scrolls instead of growing.
        public static let popoverMaxListHeight: CGFloat = 320
        /// Fixed columns in a usage row so bars line up across providers.
        public static let usageLabelWidth: CGFloat = 24
        public static let usageValueWidth: CGFloat = 36
        /// Decorative SF Symbol sizes for the onboarding hero and the empty-state illustration.
        public static let heroGlyphPointSize: CGFloat = 26
        public static let emptyGlyphPointSize: CGFloat = 22
    }
}
