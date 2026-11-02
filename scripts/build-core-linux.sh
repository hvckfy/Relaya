#!/usr/bin/env bash
# Builds the Rust core into librelaya_core.so and generates the UniFFI C# bindings for the Linux client
# (the same uniffi-bindgen-cs as build-core-windows.ps1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"
# RDP: with FREERDP_DIR (.github/actions/freerdp, triplet x64-linux-dynamic), the FreeRDP engine, as on Mac and Windows;
# its .so files (and OpenSSL from vcpkg) go next to librelaya_core.so, found by rpath $ORIGIN. Without it, no built-in RDP.
# With ROYALVNC_DIR (.github/actions/royalvnc), VNC on RoyalVNCKit too: libRoyalVNCKit.so (-static-stdlib, without
# the Swift runtime) goes alongside as well.
features=remote-desktop
[[ -n "${FREERDP_DIR:-}" ]] && features=rdp-freerdp
[[ -n "${ROYALVNC_DIR:-}" ]] && features="$features,vnc-royal"
cargo build --locked --release --lib --features "$features"
[[ -n "${ROYALVNC_DIR:-}" ]] && cp "$ROYALVNC_DIR/libRoyalVNCKit.so" target/release/
if [[ -n "${FREERDP_DIR:-}" ]]; then
  # Only .so files and their links (cp -P keeps the chain libfoo.so -> libfoo.so.3 -> libfoo.so.3.x).
  find "$FREERDP_DIR/lib" -maxdepth 1 -name '*.so*' -exec cp -P {} target/release/ \;
fi
if ! command -v uniffi-bindgen-cs >/dev/null; then
  cargo install --locked uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --rev 2f4880f03ed08d960ad0ee14d11cf95444eee540 # tag v0.9.0+v0.28.3
fi
OUT="$ROOT/apps/dotnet/Relaya.Shared/Core"
mkdir -p "$OUT"
uniffi-bindgen-cs --library target/release/librelaya_core.so --out-dir "$OUT"
# Generated code does not pass the project's nullable checks: disable them in it only (A9), no project-wide NoWarn.
for f in "$OUT"/*.cs; do
  grep -q '^#nullable disable' "$f" || printf '#nullable disable\n#pragma warning disable\n%s' "$(cat "$f")" > "$f"
done
echo "core: $ROOT/core/target/release/librelaya_core.so"
