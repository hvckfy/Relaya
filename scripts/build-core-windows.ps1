# Собирает Rust-ядро в relaya_core.dll и генерирует C#-привязки UniFFI для Windows-клиента.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location "$root/core"
cargo build --release
if (-not (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue)) {
    cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3
}
$out = "$root/apps/dotnet/Relaya.Windows/Core"
New-Item -ItemType Directory -Force $out | Out-Null
uniffi-bindgen-cs --library target/release/relaya_core.dll --out-dir $out
Pop-Location
