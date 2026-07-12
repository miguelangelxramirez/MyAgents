import XCTest
import SwiftUI
import AppKit
@testable import MyAgentsMacCore

/// Sanity checks for `DesignTokens` (METODOLOGIA §6: "un estándar de diseño es ley, no
/// documento" — the tokens themselves must be provably well-formed, not just present).
final class DesignTokensTests: XCTestCase {
    func testSpacingScale_isStrictlyIncreasing() {
        let scale = DesignTokens.Spacing.scale
        XCTAssertEqual(scale, scale.sorted(), "spacing scale must be defined smallest to largest")
        XCTAssertEqual(Set(scale).count, scale.count, "no duplicate spacing steps")
    }

    func testSpacingValues_areMultiplesOfFourOnAnEightPointGrid() {
        for value in DesignTokens.Spacing.scale {
            XCTAssertEqual(
                value.truncatingRemainder(dividingBy: 4), 0,
                "\(value) is not a multiple of 4 — spacing must sit on the 8pt grid (4pt half-steps allowed)"
            )
        }
    }

    func testNamedSpacingConstants_matchTheScale() {
        // Guards against someone adding a new named constant without adding it to `scale` too
        // (which would make testSpacingValues_areMultiplesOfFourOnAnEightPointGrid silently
        // stop covering it).
        let named: [CGFloat] = [
            DesignTokens.Spacing.xxs,
            DesignTokens.Spacing.xs,
            DesignTokens.Spacing.s,
            DesignTokens.Spacing.m,
            DesignTokens.Spacing.l,
            DesignTokens.Spacing.xl,
        ]
        XCTAssertEqual(named, DesignTokens.Spacing.scale)
    }

    // MARK: - Colors, resolved to concrete components under a fixed appearance

    /// Dynamic (`NSColor(name:dynamicProvider:)`-backed) colors don't compare meaningfully with
    /// plain `==` — resolve them to concrete sRGB components under a forced appearance instead,
    /// via `NSAppearance.performAsCurrentDrawingAppearance` (AppKit, macOS 10.14+). This is what
    /// makes these tests actually bite: comparing the dynamic `NSColor`/`Color` objects directly
    /// would pass even if `adaptive(light:dark:)` silently ignored the appearance.
    private func components(of color: Color, appearance: NSAppearance) -> [CGFloat] {
        var result: [CGFloat] = [0, 0, 0, 0]
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            result = [r, g, b, a]
        }
        return result
    }

    private var aqua: NSAppearance { NSAppearance(named: .aqua)! }
    private var darkAqua: NSAppearance { NSAppearance(named: .darkAqua)! }

    func testAdaptiveBackground_resolvesDifferentlyInLightAndDark() {
        let light = components(of: DesignTokens.Colors.background, appearance: aqua)
        let dark = components(of: DesignTokens.Colors.background, appearance: darkAqua)
        XCTAssertNotEqual(light, dark, "background must actually respond to the appearance, not just declare light+dark values")
    }

    func testAdaptiveForeground_resolvesDifferentlyInLightAndDark() {
        let light = components(of: DesignTokens.Colors.foreground, appearance: aqua)
        let dark = components(of: DesignTokens.Colors.foreground, appearance: darkAqua)
        XCTAssertNotEqual(light, dark)
    }

    func testProviderColors_areDistinctFromEachOther() {
        // Claude and Codex must never resolve to the same accent — that's the whole point of a
        // provider color (README: "the left accent bar is the provider colour").
        XCTAssertNotEqual(
            components(of: DesignTokens.Colors.claudeOrange, appearance: aqua),
            components(of: DesignTokens.Colors.codexBlue, appearance: aqua)
        )
    }

    func testSemanticColors_areDistinctFromEachOtherInLightAppearance() {
        XCTAssertNotEqual(
            components(of: DesignTokens.Colors.background, appearance: aqua),
            components(of: DesignTokens.Colors.foreground, appearance: aqua)
        )
        XCTAssertNotEqual(
            components(of: DesignTokens.Colors.foreground, appearance: aqua),
            components(of: DesignTokens.Colors.secondaryForeground, appearance: aqua)
        )
    }

    func testTypography_scalesFromCaptionToTitle() {
        // We can't introspect a SwiftUI `Font`'s point size directly, but we CAN assert the
        // three roles exist and are not accidentally aliased to the same Font value.
        XCTAssertNotEqual(DesignTokens.Typography.title, DesignTokens.Typography.body)
        XCTAssertNotEqual(DesignTokens.Typography.body, DesignTokens.Typography.caption)
        XCTAssertNotEqual(DesignTokens.Typography.title, DesignTokens.Typography.caption)
    }

    // MARK: - SessionGridLayout: the "≤3 → one row, 4–6 → two rows, >6 → scroll" product rule

    private let columns = DesignTokens.Metrics.sessionGridColumns   // 3
    private let maxRows = DesignTokens.Metrics.sessionMaxVisibleRows // 2

    func testVisibleRows_threeOrFewerSessions_isExactlyOneRow() {
        // Miguel's rule: up to a full row (3 tiles) collapses the viewport to a single row.
        for count in 0...3 {
            XCTAssertEqual(
                SessionGridLayout.visibleRows(sessionCount: count, columns: columns, maxRows: maxRows), 1,
                "\(count) sessions must show one row, not a tall half-empty viewport"
            )
        }
    }

    func testVisibleRows_fourToSixSessions_isTwoRows() {
        for count in 4...6 {
            XCTAssertEqual(
                SessionGridLayout.visibleRows(sessionCount: count, columns: columns, maxRows: maxRows), 2,
                "\(count) sessions spill into a second row"
            )
        }
    }

    func testVisibleRows_moreThanTwoRows_capsAtMaxAndScrolls() {
        // Seven sessions want three rows (ceil(7/3)) but the viewport caps at two — the rest scroll.
        XCTAssertEqual(SessionGridLayout.visibleRows(sessionCount: 7, columns: columns, maxRows: maxRows), 2)
        XCTAssertEqual(SessionGridLayout.visibleRows(sessionCount: 99, columns: columns, maxRows: maxRows), 2)
    }

    func testVisibleRows_degenerateInputs_neverCollapseBelowOne() {
        // Zero columns / zero max would divide-by-zero or vanish the list; the floor is one row.
        XCTAssertEqual(SessionGridLayout.visibleRows(sessionCount: 5, columns: 0, maxRows: maxRows), 1)
        XCTAssertEqual(SessionGridLayout.visibleRows(sessionCount: 5, columns: columns, maxRows: 0), 1)
    }

    func testViewportHeight_isAWholeNumberOfRows_noPartialRowEverPeeks() {
        // The exact height for N rows must equal N tiles + (N-1) gaps + top/bottom padding — the
        // property that guarantees a half-cut row (the reported bug) is impossible.
        let tile: CGFloat = 78, gap: CGFloat = 8, pad: CGFloat = 8
        let oneRow = SessionGridLayout.viewportHeight(rows: 1, tileHeight: tile, rowGap: gap, verticalPadding: pad)
        let twoRows = SessionGridLayout.viewportHeight(rows: 2, tileHeight: tile, rowGap: gap, verticalPadding: pad)
        XCTAssertEqual(oneRow, 78 + 16)                 // 1·78 + 0·8 + 2·8
        XCTAssertEqual(twoRows, 2 * 78 + 8 + 16)        // 2·78 + 1·8 + 2·8
        // Two rows must be exactly one tile + one gap taller than one row — never a fractional sliver.
        XCTAssertEqual(twoRows - oneRow, tile + gap)
    }
}
