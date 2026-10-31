#!/bin/bash
# Builds Tracky.app with just the Swift toolchain (no Xcode project).
#
# Adapted from claude-mascot's build.sh (https://github.com/No-one9/claude-mascot), under its MIT License:
#
#   MIT License
#
#   Copyright (c) 2026 No-one9
#
#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions:
#
#   The above copyright notice and this permission notice shall be included in all
#   copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#   SOFTWARE.
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
"$APP/Contents/MacOS/Tracky" --selftest
echo "built $APP"
