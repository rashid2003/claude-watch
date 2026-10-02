#!/bin/zsh
# Builds a distributable ClaudeWatch: universal, Developer ID signed with the hardened runtime,
# packed in a DMG, notarized and stapled. (Mac TestFlight / App Store needs the App Sandbox,
# which rules out Accessibility, Apple events to Claude and running the claude CLI.)
#
#   scripts/release-mac.sh                 build, sign, DMG, notarize
#   scripts/release-mac.sh --no-notarize   stop after the signed DMG
#
# Notarization uses a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials session-watch-notary --apple-id <you> --team-id 6W5NJUTUCV
# (it asks for an app-specific password from appleid.apple.com). Override with NOTARY_PROFILE.
# Or use an App Store Connect API key (Admin): ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=…
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${CLAUDE_WATCH_BUNDLE_ID:-dev.lajward.SessionWatch}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Rashid Obaidi (6W5NJUTUCV)}"
PROFILE="${NOTARY_PROFILE:-session-watch-notary}"
OUT="build/mac"
APP="$OUT/ClaudeWatch.app"
DMG="$OUT/SessionWatch-$VERSION.dmg"

echo "› building universal release"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS --product ClaudeWatch
swift build -c release $ARCHS --product claude-watch
BIN=$(swift build -c release $ARCHS --show-bin-path)

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeWatch" "$BIN/claude-watch" "$APP/Contents/MacOS/"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Session Watch</string>
  <key>CFBundleDisplayName</key><string>Session Watch</string>
  <key>CFBundleExecutable</key><string>ClaudeWatch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Session Watch opens a chat in the right Claude window so it can resume it after a usage limit resets.</string>
</dict></plist>
PLIST

echo "› signing with $IDENTITY"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/claude-watch"
codesign --force --timestamp --options runtime --entitlements scripts/ClaudeWatch.entitlements \
  --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "› packing $DMG"
STAGE="$OUT/dmg" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Session Watch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE"

if [[ "${1:-}" == "--no-notarize" ]]; then echo "Signed (not notarized): $DMG"; exit 0; fi

if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  echo "› notarizing (App Store Connect key $ASC_KEY_ID)"
  AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  echo "› notarizing (profile $PROFILE)"
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool profile '$PROFILE'. Create it once, or pass ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID:"
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id 6W5NJUTUCV"
    echo "Signed (not notarized): $DMG"
    exit 2
  fi
  AUTH=(--keychain-profile "$PROFILE")
fi
xcrun notarytool submit "$DMG" $AUTH --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready to share: $DMG"
