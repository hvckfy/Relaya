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

# Иконка из icon-sources/ (рендер Blender, см. icon-sources/README.md) → все размеры .iconset.
ICON_SRC="$ROOT/icon-sources/relaya-chain-r-icon.png"
ICONSET="$ROOT/build/Relaya.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z $SIZE $SIZE "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z $((SIZE * 2)) $((SIZE * 2)) "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
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
