#!/bin/zsh
# Regenerates Resources/AppIcon.icns from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -parse-as-library make-icon.swift ../Sources/Shotput/UI/CaptureGlyph.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns

echo "Resources/AppIcon.icns"
