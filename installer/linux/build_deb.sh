#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build"
PKG_ROOT="$BUILD_DIR/root"

VERSION="${STEMWERK_VERSION:-0.0.0}"
ARCH="${STEMWERK_DEB_ARCH:-amd64}"

if [[ -z "${STEMWERK_VERSION:-}" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR" "$PKG_ROOT/DEBIAN" "$PKG_ROOT/usr/share/stemwerk-reaper"

# Copy only what we need
rsync -a --delete \
  "$ROOT_DIR/scripts/reaper/" \
  "$ROOT_DIR/i18n" \
  "$ROOT_DIR/installer/assets/stemwerk.svg" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/TODO.md" \
  "$ROOT_DIR/INTEGRATION.md" \
  "$ROOT_DIR/TESTING.md" \
  "$PKG_ROOT/usr/share/stemwerk-reaper/"

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: stemwerk
Version: $VERSION
Section: sound
Priority: optional
Architecture: $ARCH
Maintainer: flarkAUDIO <flarkaudio@pm.me>
Homepage: https://github.com/flarkflarkflark/STEMwerk
Description: STEMwerk REAPER scripts and helpers
 Installs the STEMwerk REAPER scripts and helper files.
EOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MESSAGE=$(printf 'STEMwerk is installed to /usr/share/stemwerk-reaper\n\nNext step:\nOpen REAPER and run STEMwerk_First_Run_Setup.lua before using STEMwerk.lua.')

echo
echo "STEMwerk installed to /usr/share/stemwerk-reaper"
echo "Next step: Open REAPER and run STEMwerk_First_Run_Setup.lua before using STEMwerk.lua."
echo

if command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  zenity --info --width=520 --title="STEMwerk Installer" --window-icon="/usr/share/stemwerk-reaper/stemwerk.svg" --text="$MESSAGE" >/dev/null 2>&1 || true
elif command -v kdialog >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  kdialog --msgbox "$MESSAGE" --title "STEMwerk Installer" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  notify-send -i "/usr/share/stemwerk-reaper/stemwerk.svg" "STEMwerk Installer" "$MESSAGE" >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$PKG_ROOT/DEBIAN/postinst"

# Build deb
DEB_FILE="$OUT_DIR/stemwerk_${VERSION}_${ARCH}.deb"
dpkg-deb --build "$PKG_ROOT" "$DEB_FILE"

echo "Built: $DEB_FILE"
