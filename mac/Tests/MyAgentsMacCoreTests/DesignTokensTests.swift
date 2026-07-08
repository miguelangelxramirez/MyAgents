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
            components(of: DesignTokens.Colors.codexTeal, appearance: aqua)
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
}
