#!/usr/bin/env bash
# Пакеты Linux-клиента из готового dotnet publish: AppImage (основной) и .deb.
#   scripts/package-linux.sh <каталог publish> <версия>  →  build/Relaya-<версия>-x86_64.AppImage, build/relaya_<версия>_amd64.deb
# Нужны: appimagetool (в PATH или APPIMAGETOOL), ImageMagick (convert/magick), dpkg-deb.
# Интеграция по freedesktop: Desktop Entry, иконки hicolor 16…512 (Icon Theme), AppStream metainfo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB="$(cd "$1" && pwd)"
VERSION="$2"
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
Comment=SSH hosts, terminals, tunnels and remote desktops
Exec=$1 %U
Icon=relaya
Terminal=false
Categories=Network;RemoteAccess;
Keywords=ssh;sftp;terminal;tunnel;rdp;vnc;
StartupWMClass=relaya
DESK
}

# --- AppImage: приложение целиком в usr/lib/relaya, запуск через AppRun ---
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
# ssh запускает этот же бинарник как askpass (SSH_ASKPASS = путь процесса внутри смонтированного AppImage).
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/relaya/relaya" "$@"
RUN
chmod +x "$APPDIR/AppRun"
TOOL="${APPIMAGETOOL:-appimagetool}"
ARCH=x86_64 "$TOOL" "$APPDIR" "$OUT/Relaya-$VERSION-x86_64.AppImage"

# --- .deb: /opt/relaya, команда relaya в /usr/bin ---
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
Depends: openssh-client, libsecret-1-0, libicu74 | libicu72 | libicu70, dbus-user-session, xdg-utils, libx11-6, libfontconfig1, libfreetype6, fonts-dejavu-core | fonts-liberation, libice6, libsm6
Recommends: gnome-keyring | kwalletmanager, zenity | kdialog, pulseaudio-utils, freerdp3-x11 | remmina, tigervnc-viewer | remmina
Description: SSH hosts, terminals, tunnels and remote desktops
 Relaya keeps ~/.ssh/config hosts, opens native terminals, SFTP, tunnels,
 RDP and VNC, and syncs settings with the macOS and Windows clients.
CTRL
dpkg-deb --root-owner-group --build "$DEB" "$OUT/relaya_${VERSION}_amd64.deb"
echo "packages: $OUT/Relaya-$VERSION-x86_64.AppImage $OUT/relaya_${VERSION}_amd64.deb"
