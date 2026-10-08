#!/bin/bash
# Archives ClaudeRemote and uploads it to App Store Connect (TestFlight first; App Store from there).
#
# Auth, either:
#   • an Apple ID signed in under Xcode › Settings › Accounts (team 6W5NJUTUCV), or
#   • an App Store Connect API key: ASC_KEY_PATH=…/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=uuid
#
#   iOS/scripts/release.sh                     archive + upload
#   iOS/scripts/release.sh --archive           archive only (checks signing and the Release build)
#   VARIANT=next iOS/scripts/release.sh        "Session Watch Next": a separate app (Config/Next.xcconfig) that
#                                              installs next to the TestFlight app. Bundle id
#                                              dev.lajward.SessionWatch.next, widgets dev.lajward.SessionWatch.next.Widgets,
#                                              its own keychain groups, and the manual pairing port defaults to 7434
#                                              (the Mac's Session Watch Next; the QR carries its relay room).
#
# One-time setup for VARIANT=next, by hand (this script never creates App Store Connect records):
#   1. developer.apple.com › Identifiers: register the App IDs dev.lajward.SessionWatch.next and
#      dev.lajward.SessionWatch.next.Widgets (team 6W5NJUTUCV) with the same capabilities as the main app:
#      Push Notifications on the app; keychain sharing needs no capability. (-allowProvisioningUpdates can
#      register them on the first archive if the signed-in account is allowed to.)
#   2. App Store Connect › Apps › +: new iOS app "Session Watch Next", bundle id dev.lajward.SessionWatch.next,
#      any SKU (e.g. session-watch-next). Then add yourself to its internal TestFlight group.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
OUT=${OUT_DIR:-build/release}
VARIANT=${VARIANT:-}
XCCONFIG=()
NAME=ClaudeRemote
if [[ "$VARIANT" == "next" ]]; then
  XCCONFIG=(-xcconfig Config/Next.xcconfig)
  NAME=SessionWatchNext
  OUT=${OUT_DIR:-build/release-next}
elif [[ -n "$VARIANT" ]]; then
  echo "Unknown VARIANT '$VARIANT' (only 'next')" >&2; exit 1
fi
ARCHIVE="$OUT/$NAME-$BUILD.xcarchive"
mkdir -p "$OUT"

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "› archiving $NAME build $BUILD"
xcodebuild -project ClaudeRemote.xcodeproj -scheme ClaudeRemote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" ${XCCONFIG[@]+"${XCCONFIG[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive | tail -3

[[ "${1:-}" == "--archive" ]] && { echo "Archive: $ARCHIVE"; exit 0; }

echo "› uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export-$BUILD" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | tail -3
echo "Uploaded $NAME build $BUILD. It shows in TestFlight after processing (~10–30 min)."
