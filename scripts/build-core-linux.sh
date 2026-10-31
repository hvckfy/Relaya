#!/usr/bin/env bash
# Собирает Rust-ядро в librelaya_core.so и генерирует C#-привязки UniFFI для Linux-клиента
# (тот же uniffi-bindgen-cs, что в build-core-windows.ps1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"
# remote-desktop: встроенный RDP (IronRDP), как на Windows.
cargo build --release --lib --features remote-desktop
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
