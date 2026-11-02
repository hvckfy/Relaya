#!/usr/bin/env bash
# Собирает Rust-ядро (core/) в универсальную статическую библиотеку для macOS (arm64 + x86_64),
# генерирует Swift-обёртки UniFFI и кладёт всё туда, откуда их берёт SwiftPM:
#   apps/swift/Frameworks/RelayaCoreFFI.xcframework — библиотека + заголовок + modulemap
#   apps/swift/Sources/RelayaRust/relaya_core.swift  — сгенерированный Swift API
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$CORE/build"
MAC="$ROOT/apps/swift"
cd "$CORE"

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
if command -v rustup >/dev/null; then rustup target add "${TARGETS[@]}" >/dev/null; fi
export MACOSX_DEPLOYMENT_TARGET=15.0
# Встроенный RDP (FreeRDP 3): с FREERDP_DIR_ARM64 и FREERDP_DIR_X64 (каталоги vcpkg arm64-osx-dynamic и
# x64-osx-dynamic, см. .github/actions/freerdp) ядро собирается с rdp-freerdp, а dylib FreeRDP/OpenSSL склеиваются
# в universal и кладутся в $OUT/freerdp — их линкует и встраивает в .app Swift-сборка. Без них — как раньше.
# VNC на RoyalVNCKit: с ROYALVNC_DIR (.github/actions/royalvnc — universal libRoyalVNCKit.dylib, minos 15) ядро
# собирается с vnc-royal, dylib кладётся в $OUT/freerdp рядом с FreeRDP (каталог нативных dylib для Contents/Frameworks).
VNC_FEATURE=""
[[ -n "${ROYALVNC_DIR:-}" ]] && VNC_FEATURE=",vnc-royal"
if [[ -n "${FREERDP_DIR_ARM64:-}" && -n "${FREERDP_DIR_X64:-}" ]]; then
  for T in "${TARGETS[@]}"; do
    case "$T" in
      aarch64-*) dir="$FREERDP_DIR_ARM64" ;;
      *) dir="$FREERDP_DIR_X64" ;;
    esac
    FREERDP_DIR="$dir" cargo build --release --lib --target "$T" --features "rdp-freerdp$VNC_FEATURE"
  done
  FREERDP_UNIVERSAL=1
else
  for T in "${TARGETS[@]}"; do cargo build --release --lib --target "$T" ${VNC_FEATURE:+--features "${VNC_FEATURE#,}"}; done
  FREERDP_UNIVERSAL=0
fi

rm -rf "$OUT" && mkdir -p "$OUT/headers" "$MAC/Sources/RelayaRust" "$MAC/Frameworks"
LIBS=()
for T in "${TARGETS[@]}"; do LIBS+=("target/$T/release/librelaya_core.a"); done
lipo -create "${LIBS[@]}" -output "$OUT/librelaya_core.a"
if [[ "$FREERDP_UNIVERSAL" == 1 ]]; then
  mkdir -p "$OUT/freerdp"
  for lib in "$FREERDP_DIR_ARM64"/lib/*.dylib; do
    name="$(basename "$lib")"
    [[ -L "$lib" ]] && { cp -P "$lib" "$OUT/freerdp/"; continue; }
    lipo -create "$lib" "$FREERDP_DIR_X64/lib/$name" -output "$OUT/freerdp/$name"
  done
  echo "freerdp: $OUT/freerdp ($(find "$OUT/freerdp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') files)"
fi

# RoyalVNCKit — и без FreeRDP: ядро с vnc-royal без этой dylib не загрузится.
if [[ -n "${ROYALVNC_DIR:-}" ]]; then
  mkdir -p "$OUT/freerdp"
  cp "$ROYALVNC_DIR/libRoyalVNCKit.dylib" "$OUT/freerdp/"
fi

# Обёртки из метаданных собранной библиотеки (library mode).
cargo run --release --quiet --features bindgen --bin uniffi-bindgen -- generate \
  --library "target/${TARGETS[0]}/release/librelaya_core.dylib" --language swift --out-dir "$OUT/gen"
cp "$OUT/gen/"*.h "$OUT/headers/"
# SwiftPM/xcframework ищет module.modulemap.
cp "$OUT/gen/"*.modulemap "$OUT/headers/module.modulemap"
cp "$OUT/gen/"*.swift "$MAC/Sources/RelayaRust/"

rm -rf "$MAC/Frameworks/RelayaCoreFFI.xcframework"
xcodebuild -create-xcframework -library "$OUT/librelaya_core.a" -headers "$OUT/headers" \
  -output "$MAC/Frameworks/RelayaCoreFFI.xcframework" >/dev/null
echo "core: $MAC/Frameworks/RelayaCoreFFI.xcframework"
