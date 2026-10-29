#!/usr/bin/env bash
# Собирает Relaya.app из SwiftPM-сборки.
# Использование: scripts/bundle.sh [version]   →   build/Relaya.app
set -euo pipefail

VERSION="${1:-0.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Relaya.app"

cd "$ROOT"
# По архитектуре отдельно: мульти-arch сборка уходит в xcbuild, который не тянет плагин SwiftTerm.
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0"
  BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Relaya")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Relaya"

swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/Relaya.iconset"
iconutil -c icns "$ROOT/build/Relaya.iconset" -o "$APP/Contents/Resources/Relaya.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Relaya</string>
  <key>CFBundleIdentifier</key><string>app.relaya.Relaya</string>
  <key>CFBundleExecutable</key><string>Relaya</string>
  <key>CFBundleIconFile</key><string>Relaya</string>
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
