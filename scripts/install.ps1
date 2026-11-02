# Installs the latest Relaya release (or $env:RELAYA_VERSION) on Windows x64.
# The installer is checked against the release SHA256SUMS before it runs. The download keeps its Mark of the Web,
# so SmartScreen may still ask once for the unsigned installer.
# Language: $env:RELAYA_LANG = ru|en, default from the Windows UI language.
# Runs in its own scope: with `irm | iex` nothing (ErrorActionPreference, variables) stays in the user's session.
& {
$ErrorActionPreference = "Stop"
$repo = "hvckfy/Relaya"

$lang = $env:RELAYA_LANG
if (-not $lang) { $lang = if ((Get-UICulture).TwoLetterISOLanguageName -eq "ru") { "ru" } else { "en" } }
if ($lang -notin @("ru", "en")) { throw "RELAYA_LANG must be ru or en" }

$ver = $env:RELAYA_VERSION
if ($ver) { $ver = $ver.TrimStart("v") } else {
    $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
    if ($tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Cannot find the latest release" }
    $ver = $tag.Substring(1)
}

$name = "Relaya-$ver-windows-x64-$lang-setup.exe"
$base = "https://github.com/$repo/releases/download/v$ver"
$dir = Join-Path ([IO.Path]::GetTempPath()) ("relaya-" + [Guid]::NewGuid())
New-Item -ItemType Directory $dir | Out-Null
try {
    $file = Join-Path $dir $name
    Write-Host "Downloading $name"
    Invoke-WebRequest "$base/$name" -OutFile $file -UseBasicParsing
    $sums = (Invoke-WebRequest "$base/SHA256SUMS" -UseBasicParsing).Content -split "`n"
    $line = $sums | Where-Object { ($_ -split '\s+')[1] -in @($name, "*$name") } | Select-Object -First 1
    if (-not $line) { throw "$name is not listed in SHA256SUMS" }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "Checksum mismatch for $name" }
    $p = Start-Process $file -ArgumentList "/SILENT" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Installer exited with code $($p.ExitCode)" }
    Write-Host "Installed Relaya $ver"
} finally {
    Remove-Item -Recurse -Force $dir
}
}
