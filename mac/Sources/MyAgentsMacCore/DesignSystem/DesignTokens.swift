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
    }
}
