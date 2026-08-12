#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build"
PKG_ROOT="$BUILD_DIR/root"

source "$ROOT_DIR/installer/linux/stage_payload.sh"

VERSION="${STEMWERK_VERSION:-}"
ARCH="${STEMWERK_DEB_ARCH:-amd64}"
VARIANT="${STEMWERK_LINUX_VARIANT:-online-minimal}"
OUTPUT_SUFFIX="${STEMWERK_OUTPUT_SUFFIX:-}"

if [[ -z "$VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: STEMWERK_VERSION is not set and VERSION could not be read." >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR" \
  "$PKG_ROOT/DEBIAN" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/usr/share/stemwerk-reaper" \
  "$PKG_ROOT/usr/share/icons/hicolor/512x512/apps" \
  "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps"

# Copy only what we need
copy_linux_payload "$ROOT_DIR" "$PKG_ROOT/usr/share/stemwerk-reaper"
install -m0755 "$ROOT_DIR/installer/linux/stemwerk-integrate-reaper" \
  "$PKG_ROOT/usr/bin/stemwerk-integrate-reaper"

if [[ -f "$PKG_ROOT/usr/share/stemwerk-reaper/stemwerk.png" ]]; then
  cp -f "$PKG_ROOT/usr/share/stemwerk-reaper/stemwerk.png" \
    "$PKG_ROOT/usr/share/icons/hicolor/512x512/apps/stemwerk.png"
fi
if [[ -f "$PKG_ROOT/usr/share/stemwerk-reaper/stemwerk.svg" ]]; then
  cp -f "$PKG_ROOT/usr/share/stemwerk-reaper/stemwerk.svg" \
    "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/stemwerk.svg"
fi

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: stemwerk
Version: $VERSION
Section: sound
Priority: optional
Architecture: $ARCH
Depends: rsync
Maintainer: flarkAUDIO <flarkaudio@pm.me>
Homepage: https://github.com/flarkflarkflark/STEMwerk
Description: STEMwerk REAPER scripts and helpers
 Installs the STEMwerk REAPER scripts and helper files.
EOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PLAIN_MESSAGE=$(printf 'STEMwerk is installed to /usr/share/stemwerk-reaper\n\nRun as your normal desktop user:\n  stemwerk-integrate-reaper\n\nThen in REAPER:\n1. Open Actions -> Show action list -> ReaScript: Load...\n2. Select STEMwerk_Setup_Toolbar.lua from the copied STEMwerk-reaper folder\n3. Run STEMwerk: Setup.')
RICH_MESSAGE='<span size="x-large"><span foreground="#d83b01"><b>S</b></span><span foreground="#107c10"><b>T</b></span><span foreground="#0078d4"><b>E</b></span><span foreground="#ffb900"><b>M</b></span><b>werk Installer</b></span>

STEMwerk is installed to /usr/share/stemwerk-reaper

<b>Next step</b>
Run as your normal desktop user:
<tt>stemwerk-integrate-reaper</tt>

Then in REAPER, use Actions -&gt; Show action list -&gt; ReaScript: Load...
and select STEMwerk_Setup_Toolbar.lua from the copied STEMwerk-reaper folder.
Then run STEMwerk: Setup.'

echo
echo "STEMwerk installed to /usr/share/stemwerk-reaper"
echo "Run as your normal desktop user:"
echo "  stemwerk-integrate-reaper"
echo "Then in REAPER:"
echo "  Actions -> Show action list -> ReaScript: Load..."
echo "  Select STEMwerk_Setup_Toolbar.lua from the copied STEMwerk-reaper folder."
echo "  Run STEMwerk: Setup."
echo

if command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  zenity --info --width=520 --title="STEMwerk Installer" --text="$RICH_MESSAGE" >/dev/null 2>&1 || true
elif command -v kdialog >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  kdialog --msgbox "$RICH_MESSAGE" --title "STEMwerk Installer" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  notify-send -i stemwerk "STEMwerk Installer" "$PLAIN_MESSAGE" >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$PKG_ROOT/DEBIAN/postinst"

# Build deb
DEB_FILE="$OUT_DIR/stemwerk_${VERSION}_${ARCH}${OUTPUT_SUFFIX}.deb"
dpkg-deb --root-owner-group --build "$PKG_ROOT" "$DEB_FILE"

echo "Built variant ${VARIANT}: $DEB_FILE"
