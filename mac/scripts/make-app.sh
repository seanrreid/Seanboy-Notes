#!/usr/bin/env bash
# Builds a runnable "Seanboy.app" bundle from the SwiftPM release build.
# Usage: scripts/make-app.sh   → dist/Seanboy.app (ad-hoc signed)
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Seanboy"
BUNDLE_ID="com.torchcodelab.seanboy"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Seanboy" "$APP/Contents/MacOS/Seanboy"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>Seanboy</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP"
echo "  Launch with: open \"$APP\""
