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
export MACOSX_DEPLOYMENT_TARGET=14.0
for T in "${TARGETS[@]}"; do cargo build --release --lib --target "$T"; done

rm -rf "$OUT" && mkdir -p "$OUT/headers" "$MAC/Sources/RelayaRust" "$MAC/Frameworks"
lipo -create $(for T in "${TARGETS[@]}"; do echo "target/$T/release/librelaya_core.a"; done) -output "$OUT/librelaya_core.a"

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
