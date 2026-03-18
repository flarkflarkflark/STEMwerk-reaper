#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-appimage"
APPDIR="$BUILD_DIR/AppDir"

VERSION="${STEMWERK_VERSION:-0.0.0}"

if [[ -z "${STEMWERK_VERSION:-}" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR" \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/stemwerk" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps"

# Copy only what we need
rsync -a --delete \
  "$ROOT_DIR/scripts/reaper/" \
  "$ROOT_DIR/i18n" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/TODO.md" \
  "$ROOT_DIR/INTEGRATION.md" \
  "$ROOT_DIR/TESTING.md" \
  "$APPDIR/usr/share/stemwerk/"

# Icon (optional)
if [[ -f "$ROOT_DIR/installer/assets/stemwerk.svg" ]]; then
  cp -f "$ROOT_DIR/installer/assets/stemwerk.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/stemwerk.svg"
  # appimagetool expects the icon referenced by the desktop file to be present at AppDir root
  # as stemwerk.{png,svg,xpm}. Provide svg + .DirIcon for maximum compatibility.
  cp -f "$ROOT_DIR/installer/assets/stemwerk.svg" "$APPDIR/stemwerk.svg"
  ln -sf "stemwerk.svg" "$APPDIR/.DirIcon"
fi

# Desktop entry
cat > "$APPDIR/usr/share/applications/stemwerk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=STEMwerk Installer
Exec=stemwerk-installer
Icon=stemwerk
Categories=AudioVideo;Audio;
Terminal=true
EOF

# AppRun: minimal "portable installer" behavior for testers.
# On first run it copies the STEMwerk folder into \$HOME/STEMwerk and prints next steps.
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APPDIR="${APPDIR:-$(cd "$(dirname "$0")" && pwd)}"
SRC="$APPDIR/usr/share/stemwerk"
REAPER_SCRIPTS="$HOME/.config/REAPER/Scripts"
DEST="$REAPER_SCRIPTS/STEMwerk-reaper"

mkdir -p "$REAPER_SCRIPTS"
rsync -a --delete "$SRC/" "$DEST/"

echo "STEMwerk files copied to: $DEST"
echo ""
echo "Next steps:"
echo "1) In REAPER, open Actions -> Load ReaScript..."
echo "2) Add: $DEST/STEMwerk_First_Run_Setup.lua (run this first)"
echo "3) Add: $DEST/STEMwerk.lua"
echo ""
echo "Docs:"
echo "- $DEST/README.md"
echo "- $DEST/docs (if present)"
EOF
chmod +x "$APPDIR/AppRun"

# Provide a stable executable name inside the AppImage
cat > "$APPDIR/usr/bin/stemwerk-installer" <<'EOF'
#!/usr/bin/env bash
exec "$(dirname "$0")/../../AppRun" "$@"
EOF
chmod +x "$APPDIR/usr/bin/stemwerk-installer"

# Make sure desktop file is at the AppDir root too (common AppImage convention)
cp -f "$APPDIR/usr/share/applications/stemwerk.desktop" "$APPDIR/stemwerk.desktop"

# Download appimagetool if missing
APPIMAGETOOL="$BUILD_DIR/appimagetool-x86_64.AppImage"
if [[ ! -f "$APPIMAGETOOL" ]]; then
  curl -L -o "$APPIMAGETOOL" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$APPIMAGETOOL"
fi

# Build the AppImage.
# NOTE: On many CI runners FUSE isn't available, so executing AppImages directly fails with:
#   dlopen(): error loading libfuse.so.2
# Workaround: extract appimagetool and run the extracted AppRun (no FUSE required).
pushd "$BUILD_DIR" >/dev/null

APPIMAGETOOL_CMD="$APPIMAGETOOL"
if ! "$APPIMAGETOOL_CMD" --version >/dev/null 2>&1; then
  echo "appimagetool AppImage is not runnable (likely missing FUSE). Falling back to --appimage-extract."
  rm -rf "$BUILD_DIR/squashfs-root"
  "$APPIMAGETOOL" --appimage-extract >/dev/null
  if [[ -x "$BUILD_DIR/squashfs-root/AppRun" ]]; then
    APPIMAGETOOL_CMD="$BUILD_DIR/squashfs-root/AppRun"
  else
    echo "ERROR: appimagetool extraction failed (no squashfs-root/AppRun)."
    exit 1
  fi
fi

# appimagetool sometimes can't infer architecture from an AppDir; force it explicitly.
# (Don't rely on runner env which can be unset/empty.)
export ARCH="x86_64"
"$APPIMAGETOOL_CMD" "$APPDIR" "STEMwerk-$VERSION-x86_64.AppImage"
popd >/dev/null

mv -f "$BUILD_DIR/STEMwerk-$VERSION-x86_64.AppImage" "$OUT_DIR/"
echo "Built: $OUT_DIR/STEMwerk-$VERSION-x86_64.AppImage"
