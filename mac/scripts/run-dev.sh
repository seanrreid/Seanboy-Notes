#!/usr/bin/env bash
# Builds a debug "Seanboy Dev.app" and launches it fully isolated from the
# real app: its own settings, notes folder, and (absent) sync credentials,
# and no Spotlight indexing. Safe to run next to /Applications/Seanboy.app.
#
# Usage: scripts/run-dev.sh [support-dir]   (default: .build/dev-support)
set -euo pipefail

cd "$(dirname "$0")/.."
SUPPORT="${1:-$PWD/.build/dev-support}"
APP=".build/Seanboy Dev.app"

swift build
pkill -f "Seanboy Dev.app/Contents/MacOS/Seanboy" || true  # restart if running

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SUPPORT"
cp .build/debug/Seanboy "$APP/Contents/MacOS/Seanboy"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>Seanboy</string>
    <key>CFBundleIdentifier</key>          <string>com.torchcodelab.seanboy.dev</string>
    <key>CFBundleName</key>                <string>Seanboy Dev</string>
    <key>CFBundleDisplayName</key>         <string>Seanboy Dev</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>dev</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null

# A bare executable can't show windows (no bundle); `open --env` passes the
# isolation setting to the bundled app.
open -n --env SEANBOY_SUPPORT_DIR="$SUPPORT" "$APP"
echo "▸ Seanboy Dev running with support dir: $SUPPORT"
