// IconArt.swift — draws the MyAgents master 1024x1024 app-icon artwork with plain CoreGraphics
// (no AppKit/NSApplication needed, so it runs headless via `swift IconArt.swift <out.png>`).
//
// Design (see mac/README.md "App icon"):
//   - macOS-style squircle plate, dark graphite — premium/utility, not "AI gradient".
//   - The mark is THE ROBOT HEAD — the same one the menu-bar glyph draws, scaled up from the same
//     15pt geometry (see MenuBarGlyphController.robotImage). One face in the menu bar, in Finder
//     and on the web: Miguel's call (2026-07-13), replacing the earlier "> _" terminal mark, which
//     was a second, unrelated identity.
//   - Both provider accents carry the brand (DesignTokens.swift):
//       - claudeOrange #D97757 -> the head silhouette
//       - codexTeal    #40C4B4 -> the eyes (lit); the mouth is knocked back to the plate colour
//   No text/font glyphs, no gradients, no photographic effects — flat fills only.
//
// Usage: swift IconArt.swift /path/to/AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

let canvas: CGFloat = 1024

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: swift IconArt.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Brand colors — must match Sources/MyAgentsMacCore/DesignSystem/DesignTokens.swift exactly.
let claudeOrange = color(217, 119, 87)   // #D97757
let codexTeal = color(64, 196, 180)      // #40C4B4
let plateColor = color(28, 28, 31)       // near-black graphite plate
let plateStroke = color(46, 46, 50)      // faint 1px edge so the plate reads on light AND dark menu bars

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write("failed to create CGContext\n".data(using: .utf8)!)
    exit(1)
}

// Transparent canvas (macOS icons ship with alpha; Xcode/Finder render the plate's own shape).
context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// 1) Squircle plate. macOS icons are conventionally inset ~100px on a 1024 canvas (the visible
// glyph occupies ~824x824), with a corner radius around 22% of the plate's side.
let plateInset: CGFloat = 100
let plateRect = CGRect(x: plateInset, y: plateInset, width: canvas - plateInset * 2, height: canvas - plateInset * 2)
let plateRadius = plateRect.width * 0.224
let platePath = CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

context.addPath(platePath)
context.setFillColor(plateColor)
context.fillPath()

context.addPath(platePath)
context.setStrokeColor(plateStroke)
context.setLineWidth(2)
context.strokePath()

// 2) The robot head — the SAME shapes MenuBarGlyphController.robotImage draws on its 15x15pt
// canvas, scaled up here. Keeping the source geometry identical (rather than re-eyeballing it at
// 1024) is the whole point: the icon and the menu-bar glyph must be the same face, so a tweak to
// one is a tweak to both.
let unit: CGFloat = 40                     // one point of the 15pt glyph -> 40px here

// The drawn content sits at x∈[1.5, 13.5], y∈[1.5, 14.8] of that 15pt canvas — centre THAT (not
// the canvas), or the antenna's empty margin pushes the head visibly off-centre in the plate.
let contentCentre = CGPoint(x: 7.5, y: 8.15)
let originX = canvas / 2 - contentCentre.x * unit
let originY = canvas / 2 - contentCentre.y * unit
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: originX + x * unit, y: originY + y * unit) }
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(origin: p(x, y), size: CGSize(width: w * unit, height: h * unit))
}

// Silhouette: head + antenna stem + antenna tip, filled as one non-zero union.
let head = CGMutablePath()
head.addRoundedRect(in: r(1.5, 1.5, 12, 9.5), cornerWidth: 3 * unit, cornerHeight: 3 * unit)
head.addRect(r(7, 10.6, 1, 1.9))
head.addEllipse(in: r(6.1, 12, 2.8, 2.8))
context.addPath(head)
context.setFillColor(claudeOrange)
context.fillPath()

// Eyes — lit in the Codex accent, so both providers the app watches are present in the mark.
let eyes = CGMutablePath()
eyes.addEllipse(in: r(3.9, 5.1, 2.6, 2.6))
eyes.addEllipse(in: r(8.5, 5.1, 2.6, 2.6))
context.addPath(eyes)
context.setFillColor(codexTeal)
context.fillPath()

// Mouth — knocked back to the plate colour so it reads as a cut-out of the head, exactly like the
// menu-bar glyph punches it out with .destinationOut (here a real hole would punch the plate too).
let mouth = CGPath(
    roundedRect: r(5, 3, 5, 1.1),
    cornerWidth: 0.55 * unit,
    cornerHeight: 0.55 * unit,
    transform: nil
)
context.addPath(mouth)
context.setFillColor(plateColor)
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write("failed to render image\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
let utType: CFString
if #available(macOS 11.0, *) {
    utType = UTType.png.identifier as CFString
} else {
    utType = "public.png" as CFString
}
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
    FileHandle.standardError.write("failed to create PNG destination at \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("failed to write PNG\n".data(using: .utf8)!)
    exit(1)
}

print("Wrote \(outputPath)")
