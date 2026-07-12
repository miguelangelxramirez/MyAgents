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

        /// OpenAI Codex accent. Intentionally DIVERGES from the Windows product's teal
        /// (`ProviderCodex` = #40C4B4) — on macOS Miguel wanted a bright sky-blue so Codex reads as
        /// unmistakably "blue" next to Claude's orange (live user feedback, 2026-07-09). #3B9EFF.
        public static let codexBlue = Color(red: 59/255, green: 158/255, blue: 255/255)

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
        /// Popover content width. Bumped 340 → 400 (live user feedback, 2026-07-09) so the session
        /// tiles read as a grid of cards, not a tall vertical list ("un poco más ancho y menos
        /// largo").
        public static let popoverWidth: CGFloat = 400
        /// Left provider accent bar (session tile / usage).
        public static let accentBarWidth: CGFloat = 3
        public static let accentBarHeight: CGFloat = 34

        /// Session grid: THREE tiles per row (feedback 2026-07-11: "muéstralas de 3 en 3"). The
        /// narrower tile is defended by a lower `minimumScaleFactor` on the state label
        /// (`SessionTileView`), so "Awaiting permission" / "Esperando permiso" still shrinks-to-fit
        /// rather than truncating — the "que no se corte" guarantee survives the extra column.
        public static let sessionGridColumns: Int = 3
        /// A single session tile's height. Compact: three tight text lines (name · folder · state)
        /// plus padding — lower than the old square so the tiles read "más compacto" while the
        /// extra width does the work of fitting the folder + state text.
        public static let sessionTileHeight: CGFloat = 78
        /// The viewport never grows past this many tile rows — beyond it, the grid scrolls in place.
        /// Two (feedback 2026-07-11): ≤3 sessions show one row, 4–6 show two full rows, >6 keep two
        /// rows and scroll. The height is computed exactly (`SessionGridLayout.viewportHeight`) so a
        /// half-cut row never peeks — the bug Miguel reported ("la tercera fila se ve a la mitad").
        public static let sessionMaxVisibleRows: Int = 2
        /// Usage progress bar.
        public static let usageBarHeight: CGFloat = 5
        /// Pending / activity dot.
        public static let dotSize: CGFloat = 7
        /// Menu-bar glyph point size (drawn into the status item image).
        public static let glyphPointSize: CGFloat = 15
        /// Font size of the composed "% badge" text drawn next to the menu-bar glyph.
        public static let glyphBadgeFontSize: CGFloat = 9
        /// Fixed columns in a usage row so bars line up across providers.
        public static let usageLabelWidth: CGFloat = 24
        public static let usageValueWidth: CGFloat = 36
        /// Trailing "resets in …" countdown column in a usage row (e.g. "2h 14m", "6d 3h").
        public static let usageResetWidth: CGFloat = 54
        /// Decorative SF Symbol sizes for the onboarding hero and the empty-state illustration.
        public static let heroGlyphPointSize: CGFloat = 26
        public static let emptyGlyphPointSize: CGFloat = 22
    }
}

/// Pure layout math for the session grid — how many rows to actually SHOW, and the exact pixel
/// height that many rows occupy. A product rule Miguel pinned by feel (feedback 2026-07-11):
/// ≤3 sessions show ONE row; 4–6 show two full rows; >6 keep two rows and scroll. Kept pure and
/// tested so the "no half-cut row" guarantee (the reported bug) can't silently rot as tokens move.
public enum SessionGridLayout {
    /// Rows to render in the viewport: `ceil(sessionCount / columns)`, clamped to `[1, maxRows]`.
    /// One row is the floor even at zero sessions so the (empty-guarded) frame never collapses.
    public static func visibleRows(sessionCount: Int, columns: Int, maxRows: Int) -> Int {
        guard sessionCount > 0, columns > 0 else { return 1 }
        let needed = (sessionCount + columns - 1) / columns   // ceil without floating point
        return min(max(needed, 1), max(maxRows, 1))
    }

    /// Exact viewport height for `rows` tiles of `tileHeight`, with `rowGap` between them and
    /// `verticalPadding` above and below. A clean multiple of the row height — the grid can only
    /// show whole rows, so a partial row can never peek at the bottom edge.
    public static func viewportHeight(
        rows: Int,
        tileHeight: CGFloat,
        rowGap: CGFloat,
        verticalPadding: CGFloat
    ) -> CGFloat {
        let rows = CGFloat(max(rows, 1))
        return rows * tileHeight + (rows - 1) * rowGap + 2 * verticalPadding
    }
}
