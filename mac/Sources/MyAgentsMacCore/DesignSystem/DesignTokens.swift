import SwiftUI
import AppKit

/// Central design system for MyAgents Mac.
///
/// METODOLOGIA §6 ("un estándar de diseño es ley, no documento"): views are OBLIGED to use these
/// tokens. A literal color/spacing/font value in view code is a build-review violation, not a
/// style nit — the whole point of a design system is that it's the only place literals live.
public enum DesignTokens {

    public enum Colors {
        /// Anthropic/Claude accent — provider colour for the left accent bar, badges, etc.
        /// TODO(Hito 1): confirm the exact brand hex against the shipped Windows tray icon.
        public static let claudeOrange = Color(red: 0.82, green: 0.42, blue: 0.31)

        /// OpenAI Codex accent — provider colour, teal per the Windows reference (README: "Claude
        /// orange / Codex teal").
        /// TODO(Hito 1): confirm the exact brand hex against the shipped Windows tray icon.
        public static let codexTeal = Color(red: 0.15, green: 0.55, blue: 0.55)

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
