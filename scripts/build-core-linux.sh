#!/usr/bin/env bash
# Собирает Rust-ядро в librelaya_core.so и генерирует C#-привязки UniFFI для Linux-клиента
# (тот же uniffi-bindgen-cs, что в build-core-windows.ps1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"
# RDP: с FREERDP_DIR (.github/actions/freerdp, триплет x64-linux-dynamic) — движок FreeRDP, как на Mac и Windows;
# его .so (и OpenSSL из vcpkg) кладутся рядом с librelaya_core.so, ядро ищет их по rpath $ORIGIN. Без него — IronRDP.
# С ROYALVNC_DIR (.github/actions/royalvnc) — ещё VNC на RoyalVNCKit: libRoyalVNCKit.so (с -static-stdlib, без
# рантайма Swift) тоже кладётся рядом.
features=remote-desktop
[[ -n "${FREERDP_DIR:-}" ]] && features=rdp-freerdp
[[ -n "${ROYALVNC_DIR:-}" ]] && features="$features,vnc-royal"
cargo build --release --lib --features "$features"
[[ -n "${ROYALVNC_DIR:-}" ]] && cp "$ROYALVNC_DIR/libRoyalVNCKit.so" target/release/
if [[ -n "${FREERDP_DIR:-}" ]]; then
  # Только .so и их ссылки (cp -P сохраняет цепочку libfoo.so -> libfoo.so.3 -> libfoo.so.3.x).
  find "$FREERDP_DIR/lib" -maxdepth 1 -name '*.so*' -exec cp -P {} target/release/ \;
fi
if ! command -v uniffi-bindgen-cs >/dev/null; then
  cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3
fi
OUT="$ROOT/apps/dotnet/Relaya.Shared/Core"
mkdir -p "$OUT"
uniffi-bindgen-cs --library target/release/librelaya_core.so --out-dir "$OUT"
# Сгенерированный код не проходит nullable-проверки проекта — отключаем их только в нём (А9), не NoWarn на весь проект.
for f in "$OUT"/*.cs; do
  grep -q '^#nullable disable' "$f" || printf '#nullable disable\n#pragma warning disable\n%s' "$(cat "$f")" > "$f"
done
echo "core: $ROOT/core/target/release/librelaya_core.so"
