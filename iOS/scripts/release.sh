#!/bin/bash
# Archives ClaudeRemote and uploads it to App Store Connect (TestFlight first; App Store from there).
#
# Auth, either:
#   • an Apple ID signed in under Xcode › Settings › Accounts (team 6W5NJUTUCV), or
#   • an App Store Connect API key: ASC_KEY_PATH=…/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=uuid
#
#   iOS/scripts/release.sh             archive + upload
#   iOS/scripts/release.sh --archive   archive only (checks signing and the Release build)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
OUT=${OUT_DIR:-build/release}
ARCHIVE="$OUT/ClaudeRemote-$BUILD.xcarchive"
mkdir -p "$OUT"

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "› archiving build $BUILD"
xcodebuild -project ClaudeRemote.xcodeproj -scheme ClaudeRemote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates "${AUTH[@]}" archive | tail -3

[[ "${1:-}" == "--archive" ]] && { echo "Archive: $ARCHIVE"; exit 0; }

echo "› uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export-$BUILD" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist -allowProvisioningUpdates "${AUTH[@]}" | tail -3
echo "Uploaded build $BUILD. It shows in TestFlight after processing (~10–30 min)."
