#!/bin/bash
# Builds Tracky.app with just the Swift toolchain (no Xcode project). Layout borrowed from claude-mascot (MIT).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Tracky.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Pin the target: swiftc otherwise defaults to the newest macOS its SDK knows, which may be newer than this Mac.
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/Tracky" Sources/*.swift -framework Cocoa -framework SwiftUI -framework ServiceManagement
cp Resources/models.json "$APP/Contents/Resources/"
cp -R extension "$APP/Contents/Resources/"   # Chrome loads it from here, via the card's setup
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tracky</string>
  <key>CFBundleIdentifier</key><string>local.tracky</string>
  <key>CFBundleExecutable</key><string>Tracky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
"$APP/Contents/MacOS/Tracky" --selftest
echo "built $APP"
