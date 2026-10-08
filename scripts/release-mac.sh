#!/bin/zsh
# Builds a distributable ClaudeWatch: universal, Developer ID signed with the hardened runtime,
# packed in a DMG, notarized and stapled. (Mac TestFlight / App Store needs the App Sandbox,
# which rules out Accessibility, Apple events to Claude and running the claude CLI.)
#
#   scripts/release-mac.sh                 build, sign, DMG, notarize
#   scripts/release-mac.sh --no-notarize   stop after the signed DMG
#   VARIANT=next scripts/release-mac.sh    "Session Watch Next": a side-by-side build with its own bundle id,
#                                          data folder (claude-watch-next) and port (7434), for trying changes
#                                          without touching the installed app
#   DRY_RUN=1 scripts/release-mac.sh       print the version and build number it would use, then stop
#
# Version: scripts/MAC_VERSION holds the last released version and is the source of truth.
#   (default)        bump the patch: 0.4.0 → 0.4.1
#   BUMP=minor       0.4.0 → 0.5.0          BUMP=major   0.4.0 → 1.0.0
#   BUMP=none        rebuild the same version (e.g. after a failed notarization you want to redo by hand)
#   VERSION=x.y.z    use exactly this version
# The new version is written to scripts/MAC_VERSION only after notarization succeeds, so a failed or
# --no-notarize run leaves it alone and a rerun gets the same number. The script never commits or tags;
# commit scripts/MAC_VERSION yourself ("Release the Mac app as x.y.z").
# VARIANT=next computes the same upcoming version (so Next shows what the next release will be) but never
# writes scripts/MAC_VERSION: Next builds don't use up a version number.
# The build number (CFBundleVersion) is a timestamp, YYYYMMDDHHMM; override with BUILD_NUMBER.
#
# Notarization uses a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials session-watch-notary --apple-id <you> --team-id 6W5NJUTUCV
# (it asks for an app-specific password from appleid.apple.com). Override with NOTARY_PROFILE.
# Or use an App Store Connect API key (Admin): ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=…
set -euo pipefail
cd "${0:A:h}/.."

VERSION_FILE=scripts/MAC_VERSION
LAST_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
semver() { [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] }
semver "$LAST_VERSION" || { echo "$VERSION_FILE holds '$LAST_VERSION', not x.y.z" >&2; exit 1; }
if [[ -n "${VERSION:-}" ]]; then
  semver "$VERSION" || { echo "VERSION must be x.y.z, got '$VERSION'" >&2; exit 1; }
else
  parts=("${(@s/./)LAST_VERSION}")
  case "${BUMP:-patch}" in
    patch) VERSION="${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))" ;;
    minor) VERSION="${parts[1]}.$(( parts[2] + 1 )).0" ;;
    major) VERSION="$(( parts[1] + 1 )).0.0" ;;
    none)  VERSION="$LAST_VERSION" ;;
    *) echo "BUMP must be patch, minor, major or none, got '$BUMP'" >&2; exit 1 ;;
  esac
fi
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
VARIANT="${VARIANT:-}"
if [[ "$VARIANT" == "next" ]]; then
  NAME="Session Watch Next"; DEFAULT_ID="dev.lajward.SessionWatch.next"; FOLDER="claude-watch-next"; OUT="build/mac-next"
else
  NAME="Session Watch"; DEFAULT_ID="dev.lajward.SessionWatch"; FOLDER="claude-watch"; OUT="build/mac"
fi
BUNDLE_ID="${CLAUDE_WATCH_BUNDLE_ID:-$DEFAULT_ID}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Rashid Obaidi (6W5NJUTUCV)}"
PROFILE="${NOTARY_PROFILE:-session-watch-notary}"
APP="$OUT/ClaudeWatch.app"
DMG="$OUT/${NAME// /}-$VERSION.dmg"

record_version() {
  if [[ "$VARIANT" == "next" ]]; then
    echo "Version $VERSION not recorded (Next builds leave $VERSION_FILE at $LAST_VERSION)"
  elif [[ "$VERSION" != "$LAST_VERSION" ]]; then
    print -r -- "$VERSION" > "$VERSION_FILE"
    echo "Recorded $VERSION in $VERSION_FILE (was $LAST_VERSION). Commit it: Release the Mac app as $VERSION"
  fi
}

echo "› $NAME $VERSION (build $BUILD; last release $LAST_VERSION)"
if [[ -n "${DRY_RUN:-}" && "${DRY_RUN}" != "0" ]]; then
  echo "Dry run: would build $DMG"
  [[ "$VARIANT" == "next" ]] && echo "Dry run: Next build, $VERSION_FILE would stay $LAST_VERSION" \
    || echo "Dry run: $VERSION_FILE would become $VERSION after notarization"
  exit 0
fi

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
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>SWDataFolder</key><string>$FOLDER</string>
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
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
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
record_version
echo "Ready to share: $DMG"
