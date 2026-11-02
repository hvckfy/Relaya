#!/usr/bin/env bash
# Installs the latest Relaya release (or RELAYA_VERSION) on macOS or Linux.
# The package is checked against the release SHA256SUMS before anything is installed.
#   macOS: Relaya.app → /Applications (or ~/Applications without write access)
#   Linux: .deb via apt when available, otherwise the AppImage → ~/.local/bin/relaya
# Language: RELAYA_LANG=ru|en, default from $LANG.
set -euo pipefail

REPO="hvckfy/Relaya"

#######################################
# Prints an error and exits.
# Arguments:
#   Message.
#######################################
die() { echo "relaya-install: $*" >&2; exit 1; }

#######################################
# Prints the release version without "v": RELAYA_VERSION or the latest release.
# Outputs:
#   Version to stdout.
#######################################
release_version() {
  if [[ -n "${RELAYA_VERSION:-}" ]]; then echo "${RELAYA_VERSION#v}"; return; fi
  local tag
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") || die "no network"
  tag="${tag##*/}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot find the latest release"
  echo "${tag#v}"
}

lang="${RELAYA_LANG:-}"
if [[ -z "$lang" ]]; then case "${LANG:-}" in ru*) lang=ru ;; *) lang=en ;; esac; fi
[[ "$lang" == ru || "$lang" == en ]] || die "RELAYA_LANG must be ru or en"

case "$(uname -s)" in
  Darwin) asset_os=macos-universal; ext=zip ;;
  Linux)
    [[ "$(uname -m)" == x86_64 ]] || die "only x86_64 Linux builds are published"
    asset_os=linux-x64
    if command -v apt-get >/dev/null && command -v sudo >/dev/null; then ext=deb; else ext=AppImage; fi ;;
  *) die "unsupported system: $(uname -s)" ;;
esac

ver=$(release_version)
name="Relaya-$ver-$asset_os-$lang.$ext"
base="https://github.com/$REPO/releases/download/v$ver"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $name"
curl -fSL --progress-bar -o "$tmp/$name" "$base/$name" || die "download failed: $base/$name"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "download failed: SHA256SUMS"
expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$tmp/SHA256SUMS")
[[ -n "$expected" ]] || die "$name is not listed in SHA256SUMS"
if command -v sha256sum >/dev/null; then actual=$(sha256sum "$tmp/$name" | awk '{print $1}')
else actual=$(shasum -a 256 "$tmp/$name" | awk '{print $1}'); fi
[[ "$actual" == "$expected" ]] || die "checksum mismatch for $name"

case "$ext" in
  zip)
    dest=/Applications
    [[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
    ditto -x -k "$tmp/$name" "$tmp/app"
    rm -rf "$dest/Relaya.app"
    mv "$tmp/app/Relaya.app" "$dest/Relaya.app"
    echo "Installed $dest/Relaya.app" ;;
  deb)
    sudo apt-get install -y "$tmp/$name"
    echo "Installed: run relaya" ;;
  AppImage)
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/$name" "$HOME/.local/bin/relaya"
    echo "Installed $HOME/.local/bin/relaya" ;;
esac
