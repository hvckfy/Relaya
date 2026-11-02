# Builds the Rust core into relaya_core.dll and generates the UniFFI C# bindings for the Windows client.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location "$root/core"
# Built-in RDP: with FREERDP_DIR (the freerdp.yml artifact), the FreeRDP 3 engine and its DLLs next to relaya_core.dll;
# without it there is no built-in RDP (only the shared remote-desktop types).
# VNC on RoyalVNCKit: with ROYALVNC_DIR (.github/actions/royalvnc), feature vnc-royal, RoyalVNCKit.dll and the Swift runtime
# next to relaya_core.dll.
$vnc = if ($env:ROYALVNC_DIR) { ",vnc-royal" } else { "" }
if ($env:FREERDP_DIR) {
    cargo build --locked --release --features "rdp-freerdp$vnc"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Copy-Item "$env:FREERDP_DIR/bin/*.dll" target/release/ -Force
} else {
    cargo build --locked --release --features "remote-desktop$vnc"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if ($env:ROYALVNC_DIR) {
    Copy-Item "$env:ROYALVNC_DIR/RoyalVNCKit.dll" target/release/ -Force
    # Swift runtime that RoyalVNCKit.dll needs (measured when VNC was first built on Windows); the VC++ runtime is the system one.
    $swiftBin = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source
    foreach ($dll in "swiftCore", "swift_Concurrency", "swift_StringProcessing", "swift_RegexParser", "swiftCRT", "swiftDispatch",
                     "swiftWinSDK", "dispatch", "BlocksRuntime", "FoundationEssentials", "swiftSynchronization") {
        $p = Join-Path $swiftBin "$dll.dll"
        if (Test-Path $p) { Copy-Item $p target/release/ -Force }
    }
}
if (-not (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue)) {
    cargo install --locked uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --rev 2f4880f03ed08d960ad0ee14d11cf95444eee540 # tag v0.9.0+v0.28.3
}
$out = "$root/apps/dotnet/Relaya.Shared/Core"
New-Item -ItemType Directory -Force $out | Out-Null
uniffi-bindgen-cs --library target/release/relaya_core.dll --out-dir $out
# Generated code is not under our nullable rules: silence the warnings in it only (A9), not in the whole project.
Get-ChildItem "$out/*.cs" | ForEach-Object {
    $text = Get-Content $_.FullName -Raw
    if (-not $text.StartsWith("#nullable disable")) { Set-Content $_.FullName ("#nullable disable`n#pragma warning disable`n" + $text) -NoNewline }
}
Pop-Location
