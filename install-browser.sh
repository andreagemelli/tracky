#!/bin/bash
# Lets the Tracky Chrome extension talk to the Tracky app: registers Tracky as Chrome's native
# messaging host "local.tracky". Undo with: ./install-browser.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"
DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
FILE="$DIR/local.tracky.json"
if [ "${1:-}" = "--uninstall" ]; then rm -f "$FILE"; echo "removed $FILE"; exit 0; fi
BIN="$PWD/build/Tracky.app/Contents/MacOS/Tracky"
test -x "$BIN" || { echo "build Tracky first: ./build.sh"; exit 1; }
mkdir -p "$DIR"
cat > "$FILE" <<JSON
{
  "name": "local.tracky",
  "description": "Tracky: counts the water behind AI replies",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://dcbfgnpofnkeooopckmnjbcdepjgphhh/"]
}
JSON
echo "installed $FILE"
echo "Now load the extension: chrome://extensions → Developer mode → Load unpacked → $PWD/extension"
