// IconArt.swift — draws the MyAgents master 1024x1024 app-icon artwork with plain CoreGraphics
// (no AppKit/NSApplication needed, so it runs headless via `swift IconArt.swift <out.png>`).
//
// Design (HITO 3, see mac/README.md "App icon"):
//   - macOS-style squircle plate, dark graphite — premium/utility, not "AI gradient".
//   - A terminal prompt mark built from two solid geometric shapes in the two brand colors this
//     app already uses for its provider accents (DesignTokens.swift):
//       - claudeOrange #D97757 -> the ">" chevron (two round-capped strokes meeting at an apex)
//       - codexTeal    #40C4B4 -> the cursor block
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

// 2) Terminal-prompt mark: "> _" built from geometric primitives only.
let midY = canvas / 2
let apexX = canvas / 2 - 30

let armLength: CGFloat = 175
let armAngle: CGFloat = 32 * .pi / 180 // degrees from horizontal
let armThickness: CGFloat = 100

let upperEnd = CGPoint(x: apexX - armLength * cos(armAngle), y: midY + armLength * sin(armAngle))
let lowerEnd = CGPoint(x: apexX - armLength * cos(armAngle), y: midY - armLength * sin(armAngle))

context.setLineCap(.round)
context.setLineWidth(armThickness)
context.setStrokeColor(claudeOrange)

context.beginPath()
context.move(to: CGPoint(x: apexX, y: midY))
context.addLine(to: upperEnd)
context.strokePath()

context.beginPath()
context.move(to: CGPoint(x: apexX, y: midY))
context.addLine(to: lowerEnd)
context.strokePath()

// Cursor block, continuing the "> _" reading order to the right of the chevron's apex.
let cursorWidth: CGFloat = 108
let cursorHeight: CGFloat = 290
let cursorGap: CGFloat = 78
let cursorRect = CGRect(
    x: apexX + cursorGap,
    y: midY - cursorHeight / 2,
    width: cursorWidth,
    height: cursorHeight
)
let cursorRadius = cursorWidth * 0.32
let cursorPath = CGPath(roundedRect: cursorRect, cornerWidth: cursorRadius, cornerHeight: cursorRadius, transform: nil)
context.addPath(cursorPath)
context.setFillColor(codexTeal)
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
