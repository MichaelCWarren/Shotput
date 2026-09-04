#!/bin/zsh
# Builds build/Shotput.app: a release binary wrapped in a minimal, ad-hoc
# signed bundle. No entitlements, no sandbox (decision: Build & signing).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ShotputApp
BIN_PATH="$(swift build -c release --show-bin-path)"

APP="build/Shotput.app"
rm -rf "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ShotputApp" "$APP/Contents/MacOS/Shotput"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc, so the designated requirement is a bare cdhash that changes with
# every build. macOS therefore treats each rebuild as a new app when it
# reads the cloud key back, and asks for keychain access again. Always Allow
# authorises exactly one build. A Developer ID signature ends this.
codesign --force --sign - "$APP"

echo "$APP"
