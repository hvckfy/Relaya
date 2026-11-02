#!/usr/bin/env bash
# Builds Relaya.app from the SwiftPM build.
# Usage: scripts/bundle-macos.sh [version] [ru|en]
#   no language: build/Relaya.app with both translations (system language, a switch in settings);
#   a language: build/<lang>/Relaya.app with that language only (ADR-002: the language is fixed at build time).
set -euo pipefail

VERSION="${1:-0.0.0}"
RELAYA_LANG="${2:-}"
case "$RELAYA_LANG" in ""|ru|en) ;; *) echo "language: ru or en" >&2; exit 1 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build${RELAYA_LANG:+/$RELAYA_LANG}/Relaya.app"

cd "$ROOT/apps/swift"
# One architecture at a time: a multi-arch build goes through xcbuild, which cannot run the SwiftTerm plugin.
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx15.0"
  BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx15.0" --show-bin-path)/Relaya")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Relaya"

# Dependency dylibs (RoyalVNCKit) next to the binary: SwiftPM sets rpath @loader_path.
for LIB in "$(dirname "${BINS[0]}")"/*.dylib; do
  [[ -e "$LIB" ]] || continue
  DYLIB="$(basename "$LIB")"
  PARTS=()
  for B in "${BINS[@]}"; do PARTS+=("$(dirname "$B")/$DYLIB"); done
  lipo -create "${PARTS[@]}" -output "$APP/Contents/MacOS/$DYLIB"
done

# FreeRDP 3 (the core's built-in RDP) in Contents/Frameworks with its links; vcpkg's install name is @rpath/…,
# and rpath @executable_path/../Frameworks is set in Package.swift.
if [ -d "$ROOT/core/build/freerdp" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -a "$ROOT/core/build/freerdp/"*.dylib "$APP/Contents/Frameworks/"
fi

# The icon from resources/icon/ (a Blender render, see resources/icon/README.md) in every .iconset size.
ICON_SRC="$ROOT/resources/icon/relaya-chain-r-icon.png"
ICONSET="$ROOT/build/Relaya.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z $SIZE $SIZE "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z $((SIZE * 2)) $((SIZE * 2)) "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/build/Relaya.iconset" -o "$APP/Contents/Resources/Relaya.icns"

# UI translations: keys are Russian strings, en.lproj is English (see apps/swift/Sources/RelayaCore/Localization.swift).
if [ -n "$RELAYA_LANG" ]; then
  cp -R "$ROOT/resources/localization/$RELAYA_LANG.lproj" "$APP/Contents/Resources/"
  DEV_REGION="$RELAYA_LANG"
  LOCALIZATIONS="<string>$RELAYA_LANG</string>"
else
  cp -R "$ROOT/resources/localization/"*.lproj "$APP/Contents/Resources/"
  DEV_REGION="ru"
  LOCALIZATIONS="<string>ru</string><string>en</string>"
fi

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
  <key>CFBundleDevelopmentRegion</key><string>${DEV_REGION}</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$APP"
