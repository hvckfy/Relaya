# Собирает Rust-ядро в relaya_core.dll и генерирует C#-привязки UniFFI для Windows-клиента.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location "$root/core"
# Встроенный RDP: с FREERDP_DIR (артефакт freerdp.yml) — движок FreeRDP 3 и его DLL рядом с relaya_core.dll,
# без него встроенного RDP нет (только общие типы remote-desktop).
# VNC на RoyalVNCKit: с ROYALVNC_DIR (.github/actions/royalvnc) — фича vnc-royal, RoyalVNCKit.dll и рантайм Swift
# рядом с relaya_core.dll.
$vnc = if ($env:ROYALVNC_DIR) { ",vnc-royal" } else { "" }
if ($env:FREERDP_DIR) {
    cargo build --release --features "rdp-freerdp$vnc"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Copy-Item "$env:FREERDP_DIR/bin/*.dll" target/release/ -Force
} else {
    cargo build --release --features "remote-desktop$vnc"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if ($env:ROYALVNC_DIR) {
    Copy-Item "$env:ROYALVNC_DIR/RoyalVNCKit.dll" target/release/ -Force
    # Рантайм Swift, который нужен RoyalVNCKit.dll (замерено в vnc-poc.yml); VC++ runtime — системный.
    $swiftBin = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source
    foreach ($dll in "swiftCore", "swift_Concurrency", "swift_StringProcessing", "swift_RegexParser", "swiftCRT", "swiftDispatch",
                     "swiftWinSDK", "dispatch", "BlocksRuntime", "FoundationEssentials", "swiftSynchronization") {
        $p = Join-Path $swiftBin "$dll.dll"
        if (Test-Path $p) { Copy-Item $p target/release/ -Force }
    }
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
