#!/usr/bin/env bash
# generate-app-icon.sh — (re)generates mac/Resources/Assets.xcassets/AppIcon.appiconset from the
# single 1024x1024 master drawn by IconArt.swift (plain CoreGraphics, no external assets/network).
#
# Re-run this any time IconArt.swift's artwork changes; it's idempotent (overwrites the PNGs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ICONSET_DIR="$MAC_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

MASTER_PNG="$WORK_DIR/AppIcon-1024.png"

echo "==> Rendering master artwork (1024x1024) with IconArt.swift"
swift "$SCRIPT_DIR/IconArt.swift" "$MASTER_PNG"

mkdir -p "$ICONSET_DIR"

# name:pixels pairs required by a macOS AppIcon.appiconset (16/32/128/256/512 at 1x and 2x).
render() {
    local name="$1" px="$2"
    sips -z "$px" "$px" "$MASTER_PNG" --out "$ICONSET_DIR/$name" >/dev/null
    echo "    $name (${px}x${px})"
}

echo "==> Rendering sized PNGs into $ICONSET_DIR"
render "icon_16x16.png" 16
render "icon_16x16@2x.png" 32
render "icon_32x32.png" 32
render "icon_32x32@2x.png" 64
render "icon_128x128.png" 128
render "icon_128x128@2x.png" 256
render "icon_256x256.png" 256
render "icon_256x256@2x.png" 512
render "icon_512x512.png" 512
render "icon_512x512@2x.png" 1024

cat > "$ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",      "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",      "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",    "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",    "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",    "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png", "scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "==> Done. Regenerate the Xcode project (xcodegen generate) to pick up any new files."
