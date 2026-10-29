#!/usr/bin/env bash
# Собирает Relaya.app из SwiftPM-сборки.
# Использование: scripts/bundle.sh [version]   →   build/Relaya.app
set -euo pipefail

VERSION="${1:-0.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Relaya.app"

cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Relaya"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Relaya"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Relaya</string>
  <key>CFBundleIdentifier</key><string>app.relaya.Relaya</string>
  <key>CFBundleExecutable</key><string>Relaya</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$APP"
