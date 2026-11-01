# Собирает Rust-ядро в relaya_core.dll и генерирует C#-привязки UniFFI для Windows-клиента.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location "$root/core"
# Встроенный RDP: с FREERDP_DIR (артефакт freerdp.yml) — движок FreeRDP 3 и его DLL рядом с relaya_core.dll,
# без него — IronRDP (remote-desktop). На Mac встроенного RDP пока нет.
if ($env:FREERDP_DIR) {
    cargo build --release --features rdp-freerdp
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Copy-Item "$env:FREERDP_DIR/bin/*.dll" target/release/ -Force
} else {
    cargo build --release --features remote-desktop
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if (-not (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue)) {
    cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3
}
$out = "$root/apps/dotnet/Relaya.Shared/Core"
New-Item -ItemType Directory -Force $out | Out-Null
uniffi-bindgen-cs --library target/release/relaya_core.dll --out-dir $out
# Сгенерированный код не под нашими правилами nullable: предупреждения глушим только в нём (А9), а не во всём проекте.
Get-ChildItem "$out/*.cs" | ForEach-Object {
    $text = Get-Content $_.FullName -Raw
    if (-not $text.StartsWith("#nullable disable")) { Set-Content $_.FullName ("#nullable disable`n#pragma warning disable`n" + $text) -NoNewline }
}
Pop-Location
