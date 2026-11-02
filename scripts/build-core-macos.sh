#!/usr/bin/env bash
# Builds the Rust core (core/) into a universal static library for macOS (arm64 + x86_64),
# generates the UniFFI Swift wrappers and puts everything where SwiftPM takes it from:
#   apps/swift/Frameworks/RelayaCoreFFI.xcframework: library + header + modulemap
#   apps/swift/Sources/RelayaRust/relaya_core.swift: the generated Swift API
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$CORE/build"
MAC="$ROOT/apps/swift"
cd "$CORE"

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
if command -v rustup >/dev/null; then rustup target add "${TARGETS[@]}" >/dev/null; fi
export MACOSX_DEPLOYMENT_TARGET=15.0
# Built-in RDP (FreeRDP 3): with FREERDP_DIR_ARM64 and FREERDP_DIR_X64 (vcpkg folders arm64-osx-dynamic and
# x64-osx-dynamic, see .github/actions/freerdp) the core builds with rdp-freerdp, and the FreeRDP/OpenSSL dylibs are
# merged into universal ones in $OUT/freerdp, which the Swift build links and embeds in the .app. Without them, no RDP.
# VNC on RoyalVNCKit: with ROYALVNC_DIR (.github/actions/royalvnc, universal libRoyalVNCKit.dylib, minos 15) the core
# builds with vnc-royal; the dylib goes to $OUT/freerdp next to FreeRDP (the native dylib folder for Contents/Frameworks).
VNC_FEATURE=""
[[ -n "${ROYALVNC_DIR:-}" ]] && VNC_FEATURE=",vnc-royal"
if [[ -n "${FREERDP_DIR_ARM64:-}" && -n "${FREERDP_DIR_X64:-}" ]]; then
  for T in "${TARGETS[@]}"; do
    case "$T" in
      aarch64-*) dir="$FREERDP_DIR_ARM64" ;;
      *) dir="$FREERDP_DIR_X64" ;;
    esac
    FREERDP_DIR="$dir" cargo build --locked --release --lib --target "$T" --features "rdp-freerdp$VNC_FEATURE"
  done
  FREERDP_UNIVERSAL=1
else
  for T in "${TARGETS[@]}"; do cargo build --locked --release --lib --target "$T" ${VNC_FEATURE:+--features "${VNC_FEATURE#,}"}; done
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

# RoyalVNCKit even without FreeRDP: a core with vnc-royal does not load without this dylib.
if [[ -n "${ROYALVNC_DIR:-}" ]]; then
  mkdir -p "$OUT/freerdp"
  cp "$ROYALVNC_DIR/libRoyalVNCKit.dylib" "$OUT/freerdp/"
fi

# Wrappers from the built library's metadata (library mode).
cargo run --locked --release --quiet --features bindgen --bin uniffi-bindgen -- generate \
  --library "target/${TARGETS[0]}/release/librelaya_core.dylib" --language swift --out-dir "$OUT/gen"
cp "$OUT/gen/"*.h "$OUT/headers/"
# SwiftPM/xcframework looks for module.modulemap.
cp "$OUT/gen/"*.modulemap "$OUT/headers/module.modulemap"
cp "$OUT/gen/"*.swift "$MAC/Sources/RelayaRust/"

rm -rf "$MAC/Frameworks/RelayaCoreFFI.xcframework"
xcodebuild -create-xcframework -library "$OUT/librelaya_core.a" -headers "$OUT/headers" \
  -output "$MAC/Frameworks/RelayaCoreFFI.xcframework" >/dev/null
echo "core: $MAC/Frameworks/RelayaCoreFFI.xcframework"
