#!/usr/bin/env bash
# build-release.sh — HITO 3: builds, signs (Developer ID), notarizes and staples a distributable
# MyAgentsMac.app, then zips it and prints the sha256 needed for the Homebrew cask
# (mac/dist/Casks/myagents.rb).
#
# This is the ONLY script that touches the real Developer ID identity / notary credentials, and it
# never embeds a password: notarytool authenticates via a keychain profile you create ONCE with
# `xcrun notarytool store-credentials` (see mac/README.md "Release checklist" / PUBLISHING.md).
#
# Commands used here (verified against this machine's Xcode 26.6 man pages, 2026-07):
#   xcodebuild archive / -exportArchive -exportOptionsPlist (method: developer-id)
#   xcrun notarytool submit --keychain-profile <profile> --wait
#   xcrun stapler staple
#
# Usage:
#   ./scripts/build-release.sh
#
# Env vars (all optional, sensible defaults):
#   TEAM_ID          Apple Developer Team ID.                  default: 2BYX29N42C
#   SIGN_IDENTITY    Codesign identity common name.             default: "Developer ID Application"
#   NOTARY_PROFILE   xcrun notarytool keychain-profile name.    default: myagents-notary
#   SCHEME           Xcode scheme to archive.                   default: MyAgentsMac
#   CONFIGURATION    Build configuration to archive.             default: Release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEAM_ID="${TEAM_ID:-2BYX29N42C}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-myagents-notary}"
SCHEME="${SCHEME:-MyAgentsMac}"
CONFIGURATION="${CONFIGURATION:-Release}"

BUILD_DIR="$MAC_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/MyAgentsMac.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_NAME="MyAgentsMac.app"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

fail() {
    echo ""
    echo "ERROR: $1" >&2
    echo "" >&2
    exit 1
}

echo "==> [1/8] Checking required tools"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found. Install it with: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install/select Xcode with xcode-select."

echo "==> [2/8] Preflight: Developer ID Application certificate"
# find-identity lists valid signing identities in the login keychain. A missing cert here means
# Miguel hasn't created one yet (Apple Developer > Certificates > + > Developer ID Application) —
# this build MUST fail loud rather than silently falling back to ad-hoc/self signing, because an
# ad-hoc-signed .app cannot be notarized and Gatekeeper will refuse to launch it on another Mac.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    fail "No \"$SIGN_IDENTITY\" identity found in the login keychain.
This build requires a real Developer ID Application certificate — it will NOT fall back to
ad-hoc signing (an ad-hoc/self-signed .app cannot be notarized and Gatekeeper will block it on
any other Mac).

To fix:
  1. developer.apple.com/account/resources/certificates/list -> '+' -> \"Developer ID Application\"
     (requires the paid Apple Developer Program membership; team 2BYX29N42C).
  2. Download the .cer and double-click it to install it into your login keychain (or use
     Xcode > Settings > Accounts > Manage Certificates > '+' > Developer ID Application).
  3. Re-run: security find-identity -v -p codesigning   (confirm it now lists
     \"Developer ID Application: <Your Name> ($TEAM_ID)\")."
fi

echo "==> [3/8] Preflight: notarytool keychain profile \"$NOTARY_PROFILE\""
# `notarytool history` is a lightweight authenticated call — it fails immediately (and loudly) if
# the named keychain profile doesn't exist or its stored credentials are stale/invalid, instead of
# discovering that 10 minutes into a `submit --wait`.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "No notarytool keychain profile named \"$NOTARY_PROFILE\" (or its credentials are invalid).
This script never accepts a password on the command line — it only reads credentials notarytool
already stored securely in the keychain.

To fix, run ONCE (an app-specific password from appleid.apple.com > Sign-In and Security >
App-Specific Passwords is the simplest option; an App Store Connect API key also works):
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
      --apple-id \"<your Apple ID email>\" \\
      --team-id \"$TEAM_ID\" \\
      --password \"<app-specific password>\"
Then re-run this script."
fi

echo "==> [4/8] xcodegen generate"
(cd "$MAC_DIR" && xcodegen generate)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> [5/8] xcodebuild archive ($CONFIGURATION, $SIGN_IDENTITY)"
xcodebuild archive \
    -project "$MAC_DIR/MyAgentsMac.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "==> [6/8] Export (method: developer-id)"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGN_IDENTITY</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME"
[ -d "$APP_PATH" ] || fail "Export succeeded but $APP_PATH is missing — check the log above."

# Read the version straight off the exported app's own Info.plist so the zip/cask name always
# matches what's actually inside it (never hand-typed, never drifts from project.yml).
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
ZIP_PATH="$BUILD_DIR/MyAgentsMac-$VERSION.zip"

echo "==> [7/8] Notarize v$VERSION"
# ditto (not `zip`) is Apple's recommended way to zip a .app for notarization/distribution — it
# preserves the code signature's resource forks/metadata that a plain `zip` can silently corrupt.
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

SUBMIT_LOG="$BUILD_DIR/notarytool-submit.log"
if ! xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$SUBMIT_LOG"; then
    fail "notarytool submit failed to run — see $SUBMIT_LOG."
fi

if ! grep -q "status: Accepted" "$SUBMIT_LOG"; then
    SUBMISSION_ID="$(awk '/id:/{print $2; exit}' "$SUBMIT_LOG")"
    echo "" >&2
    echo "Notarization did NOT report \"Accepted\". Fetching the notary log for details:" >&2
    if [ -n "${SUBMISSION_ID:-}" ]; then
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    fail "Notarization rejected or failed — see the log above (common causes: missing hardened
runtime, an unsigned nested binary/Node script executable bit issue, or a stale/expired cert)."
fi

echo "==> [8/8] Staple + re-zip the stapled app"
# The zip above is what notarytool saw — it does NOT contain the staple. Staple the .app itself,
# then re-zip so the file we actually distribute/hash has the ticket embedded (works offline).
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "$SHA256" > "$ZIP_PATH.sha256"

echo ""
echo "==> Done."
echo "    App:     $APP_PATH"
echo "    Zip:     $ZIP_PATH"
echo "    Version: $VERSION"
echo "    SHA256:  $SHA256"
echo ""
echo "Next: upload $ZIP_PATH to the GitHub release (tag v$VERSION), then update"
echo "mac/dist/Casks/myagents.rb 'version' and 'sha256' with the values above."
