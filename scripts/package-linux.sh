#!/usr/bin/env bash
# Пакеты Linux-клиента из готового dotnet publish: AppImage (основной) и .deb.
#   scripts/package-linux.sh <каталог publish> <версия>  →  build/Relaya-<версия>-x86_64.AppImage, build/relaya_<версия>_amd64.deb
# Нужны: appimagetool (в PATH или APPIMAGETOOL), ImageMagick (convert/magick), dpkg-deb.
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
Categories=Network;RemoteAccess;System;TerminalEmulator;
StartupWMClass=relaya
DESK
}

# --- AppImage: приложение целиком в usr/lib/relaya, запуск через AppRun ---
APPDIR="$WORK/Relaya.AppDir"
mkdir -p "$APPDIR/usr/lib/relaya" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$PUB/." "$APPDIR/usr/lib/relaya/"
chmod +x "$APPDIR/usr/lib/relaya/relaya"
resize 256 "$APPDIR/usr/share/icons/hicolor/256x256/apps/relaya.png"
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/relaya.png" "$APPDIR/relaya.png"
desktop relaya > "$APPDIR/relaya.desktop"
cp "$APPDIR/relaya.desktop" "$APPDIR/usr/share/applications/relaya.desktop"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
# ssh запускает этот же бинарник как askpass (SSH_ASKPASS = путь процесса внутри смонтированного AppImage).
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/relaya/relaya" "$@"
RUN
chmod +x "$APPDIR/AppRun"
TOOL="${APPIMAGETOOL:-appimagetool}"
ARCH=x86_64 "$TOOL" --no-appstream "$APPDIR" "$OUT/Relaya-$VERSION-x86_64.AppImage"

# --- .deb: /opt/relaya, команда relaya в /usr/bin ---
DEB="$WORK/deb"
mkdir -p "$DEB/DEBIAN" "$DEB/opt/relaya" "$DEB/usr/bin" "$DEB/usr/share/applications" "$DEB/usr/share/icons/hicolor/256x256/apps"
cp -a "$PUB/." "$DEB/opt/relaya/"
chmod +x "$DEB/opt/relaya/relaya"
ln -s /opt/relaya/relaya "$DEB/usr/bin/relaya"
desktop /opt/relaya/relaya > "$DEB/usr/share/applications/relaya.desktop"
cp "$APPDIR/relaya.png" "$DEB/usr/share/icons/hicolor/256x256/apps/relaya.png"
cat > "$DEB/DEBIAN/control" <<CTRL
Package: relaya
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: Relaya <relaya@users.noreply.github.com>
Depends: openssh-client, libsecret-1-0, libx11-6, libfontconfig1, libfreetype6, libice6, libsm6
Recommends: zenity | kdialog, freerdp3-x11 | freerdp2-x11 | remmina, tigervnc-viewer | remmina
Description: SSH hosts, terminals, tunnels and remote desktops
 Relaya keeps ~/.ssh/config hosts, opens native terminals, SFTP, tunnels,
 RDP and VNC, and syncs settings with the macOS and Windows clients.
CTRL
dpkg-deb --root-owner-group --build "$DEB" "$OUT/relaya_${VERSION}_amd64.deb"
echo "packages: $OUT/Relaya-$VERSION-x86_64.AppImage $OUT/relaya_${VERSION}_amd64.deb"
