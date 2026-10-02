#!/bin/zsh
# Builds ClaudeWatch.app (menu bar) + the claude-watch CLI and installs them.
#   ./install.sh            -> ~/Applications/ClaudeWatch.app and ~/.local/bin/claude-watch
#   ./install.sh --no-open  -> don't launch the app afterwards
#   ./install.sh --force    -> install even if the notarized /Applications/Session Watch.app exists
set -euo pipefail
cd "${0:A:h}"
BUNDLE_ID="${CLAUDE_WATCH_BUNDLE_ID:-local.claude-watch}"

# The notarized release (scripts/release-mac.sh) lives in /Applications. Two copies would fight over
# the same config and port, so don't install a local build next to it unless asked.
if [[ -d "/Applications/Session Watch.app" && "${1:-}" != "--force" && "${2:-}" != "--force" ]]; then
  echo "Session Watch (notarized) is installed in /Applications. To update it, run scripts/release-mac.sh"
  echo "and copy the new app from build/mac/. Use ./install.sh --force for a local build instead."
  exit 1
fi

swift build -c release --product ClaudeWatch
swift build -c release --product claude-watch
BIN=$(swift build -c release --show-bin-path)

APP="$HOME/Applications/ClaudeWatch.app"
pkill -x ClaudeWatch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeWatch" "$APP/Contents/MacOS/ClaudeWatch"
# The CLI also serves the iPhone prompt tool; keep a copy next to the app binary.
cp "$BIN/claude-watch" "$APP/Contents/MacOS/claude-watch"
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Session Watch opens a chat in the right Claude window so it can resume it after a usage limit resets.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null

mkdir -p "$HOME/.local/bin"
cp "$BIN/claude-watch" "$HOME/.local/bin/claude-watch"
codesign --force --sign - "$HOME/.local/bin/claude-watch" >/dev/null

echo "Installed $APP"
echo "Installed ~/.local/bin/claude-watch"
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "Add ~/.local/bin to your PATH to run claude-watch from anywhere."
[[ "${1:-}" == "--no-open" ]] || open "$APP"
