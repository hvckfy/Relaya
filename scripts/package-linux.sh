#!/usr/bin/env bash
# Linux client packages from a finished dotnet publish: AppImage (main) and .deb.
#   scripts/package-linux.sh <publish dir> <version> <ru|en>
#     ->  build/Relaya-<version>-<lang>-x86_64.AppImage, build/relaya_<version>-<lang>_amd64.deb
# The language is the build's (ADR-002, -p:RelayaLang) and sets the menu label. The .deb package name is one (relaya),
# so ru and en replace each other on install instead of living side by side.
# Needs appimagetool (in PATH or APPIMAGETOOL), ImageMagick (convert/magick), dpkg-deb.
# freedesktop integration: Desktop Entry, hicolor icons 16…512 (Icon Theme), AppStream metainfo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB="$(cd "$1" && pwd)"
VERSION="$2"
LANG_CODE="${3:-en}"
case "$LANG_CODE" in
  ru) COMMENT="SSH-хосты, терминалы, туннели и удалённые столы" ;;
  en) COMMENT="SSH hosts, terminals, tunnels and remote desktops" ;;
  *) echo "язык: ru или en, получено «$LANG_CODE»" >&2; exit 2 ;;
esac
OUT="$ROOT/build"
WORK="$OUT/pkg"
rm -rf "$WORK" && mkdir -p "$WORK"

ICON_SRC="$ROOT/resources/icon/relaya-icon.png"
resize() { if command -v magick >/dev/null; then magick "$ICON_SRC" -resize "$1x$1" "$2"; else convert "$ICON_SRC" -resize "$1x$1" "$2"; fi; }

desktop() {
  cat <<DESK
[Desktop Entry]
Type=Application
Name=Relaya
Comment=$COMMENT
Exec=$1 %U
Icon=relaya
Terminal=false
Categories=Network;RemoteAccess;
Keywords=ssh;sftp;terminal;tunnel;rdp;vnc;
StartupWMClass=relaya
DESK
}

# MSBuild copies the chain libX.so -> libX.so.3 -> libX.so.3.x as separate files. The loader (rpath $ORIGIN) needs
# only the file named by SONAME (libX.so.3): drop the other copies so the package does not grow 2-3 times.
# Libraries without a version in SONAME (librelaya_core.so, libRoyalVNCKit.so) stay as they are.
for f in "$PUB"/*.so "$PUB"/*.so.*; do
  [[ -f "$f" ]] || continue
  soname=$(readelf -d "$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  if [[ -n "$soname" && "$(basename "$f")" != "$soname" && -f "$PUB/$soname" ]]; then rm -f "$f"; fi
done
# Check: the core finds all its libraries inside the package (rpath $ORIGIN), no "not found".
if ldd "$PUB/librelaya_core.so" | grep -q 'not found'; then
  ldd "$PUB/librelaya_core.so" | grep 'not found' >&2
  echo "librelaya_core.so: не хватает библиотек в пакете" >&2
  exit 1
fi

# --- AppImage: the whole app in usr/lib/relaya, started through AppRun ---
APPDIR="$WORK/Relaya.AppDir"
mkdir -p "$APPDIR/usr/lib/relaya" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$PUB/." "$APPDIR/usr/lib/relaya/"
chmod +x "$APPDIR/usr/lib/relaya/relaya"
ID=app.relaya.Relaya
SIZES="16 24 32 48 64 128 256 512"
icons() { for n in $SIZES; do mkdir -p "$1/${n}x${n}/apps"; resize "$n" "$1/${n}x${n}/apps/relaya.png"; done; }
icons "$APPDIR/usr/share/icons/hicolor"
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/relaya.png" "$APPDIR/relaya.png"
desktop relaya > "$APPDIR/$ID.desktop"
cp "$APPDIR/$ID.desktop" "$APPDIR/usr/share/applications/$ID.desktop"
mkdir -p "$APPDIR/usr/share/metainfo"
cp "$ROOT/resources/linux/$ID.metainfo.xml" "$APPDIR/usr/share/metainfo/$ID.appdata.xml"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
# ssh runs this same binary as askpass (SSH_ASKPASS = the process path inside the mounted AppImage).
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/relaya/relaya" "$@"
RUN
chmod +x "$APPDIR/AppRun"
TOOL="${APPIMAGETOOL:-appimagetool}"
ARCH=x86_64 "$TOOL" "$APPDIR" "$OUT/Relaya-$VERSION-$LANG_CODE-x86_64.AppImage"

# --- .deb: /opt/relaya, the relaya command in /usr/bin ---
DEB="$WORK/deb"
mkdir -p "$DEB/DEBIAN" "$DEB/opt/relaya" "$DEB/usr/bin" "$DEB/usr/share/applications" "$DEB/usr/share/metainfo"
cp -a "$PUB/." "$DEB/opt/relaya/"
chmod +x "$DEB/opt/relaya/relaya"
ln -s /opt/relaya/relaya "$DEB/usr/bin/relaya"
desktop /opt/relaya/relaya > "$DEB/usr/share/applications/$ID.desktop"
cp -a "$APPDIR/usr/share/icons" "$DEB/usr/share/"
cp "$ROOT/resources/linux/$ID.metainfo.xml" "$DEB/usr/share/metainfo/$ID.metainfo.xml"
cat > "$DEB/DEBIAN/control" <<CTRL
Package: relaya
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: Relaya <relaya@users.noreply.github.com>
Depends: openssh-client, libsecret-1-0, bzip2, libglib2.0-bin, libicu74 | libicu72 | libicu70, dbus-user-session, xdg-utils, libx11-6, libfontconfig1, libfreetype6, fonts-dejavu-core | fonts-liberation, libice6, libsm6
Recommends: gnome-keyring | kwalletmanager, gvfs-backends, zenity | kdialog, pulseaudio-utils, freerdp3-x11 | remmina, tigervnc-viewer | remmina
Description: SSH hosts, terminals, tunnels and remote desktops
 Relaya keeps ~/.ssh/config hosts, opens native terminals, SFTP, tunnels,
 RDP and VNC, and syncs settings with the macOS and Windows clients.
CTRL
dpkg-deb --root-owner-group --build "$DEB" "$OUT/relaya_${VERSION}-${LANG_CODE}_amd64.deb"
echo "packages: $OUT/Relaya-$VERSION-$LANG_CODE-x86_64.AppImage $OUT/relaya_${VERSION}-${LANG_CODE}_amd64.deb"
