#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-appimage"
APPDIR="$BUILD_DIR/AppDir"

source "$ROOT_DIR/installer/linux/stage_payload.sh"

VERSION="${STEMWERK_VERSION:-}"
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
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/stemwerk" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/512x512/apps" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps"

# Copy only what we need
copy_linux_payload "$ROOT_DIR" "$APPDIR/usr/share/stemwerk"

# Icon (optional)
if [[ -f "$ROOT_DIR/installer/assets/stemwerk.png" ]]; then
  cp -f "$ROOT_DIR/installer/assets/stemwerk.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/stemwerk.png"
  cp -f "$ROOT_DIR/installer/assets/stemwerk.png" "$APPDIR/stemwerk.png"
  rm -f "$APPDIR/.DirIcon"
  if ! ln -s "stemwerk.png" "$APPDIR/.DirIcon" 2>/dev/null; then
    cp -f "$APPDIR/stemwerk.png" "$APPDIR/.DirIcon"
  fi
fi
if [[ -f "$ROOT_DIR/installer/assets/stemwerk.svg" ]]; then
  cp -f "$ROOT_DIR/installer/assets/stemwerk.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/stemwerk.svg"
  if [[ ! -f "$APPDIR/stemwerk.png" ]]; then
    cp -f "$ROOT_DIR/installer/assets/stemwerk.svg" "$APPDIR/stemwerk.svg"
    rm -f "$APPDIR/.DirIcon"
    if ! ln -s "stemwerk.svg" "$APPDIR/.DirIcon" 2>/dev/null; then
      cp -f "$APPDIR/stemwerk.svg" "$APPDIR/.DirIcon"
    fi
  fi
fi

# Desktop entry
cat > "$APPDIR/usr/share/applications/stemwerk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=STEMwerk Installer
Exec=stemwerk-installer
Icon=stemwerk
Categories=AudioVideo;Audio;
Terminal=false
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
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/STEMwerk"
LOG_DIR="$STATE_DIR/logs"
LOG_FILE="$LOG_DIR/appimage-installer.log"
show_dialog() {
  local title="$1"
  local rich_body="$2"
  local plain_body="$3"
  local kind="${4:-info}"

  if command -v zenity >/dev/null 2>&1; then
    if [[ "$kind" == "error" ]]; then
      zenity --error --width=520 --title="$title" --text="$plain_body" >/dev/null 2>&1 && return 0
    else
      zenity --info --width=520 --title="$title" --text="$rich_body" >/dev/null 2>&1 && return 0
    fi
  fi

  if command -v kdialog >/dev/null 2>&1; then
    if [[ "$kind" == "error" ]]; then
      kdialog --error "$plain_body" --title "$title" >/dev/null 2>&1 && return 0
    else
      kdialog --msgbox "$rich_body" --title "$title" >/dev/null 2>&1 && return 0
    fi
  fi

  if command -v xmessage >/dev/null 2>&1; then
    xmessage -center "$title\n\n$plain_body" >/dev/null 2>&1 && return 0
  fi

  if command -v notify-send >/dev/null 2>&1; then
    if [[ "$kind" == "error" ]]; then
      notify-send -u critical "$title" "$plain_body" >/dev/null 2>&1 && return 0
    else
      notify-send "$title" "$plain_body" >/dev/null 2>&1 && return 0
    fi
  fi

  return 1
}

mkdir -p "$REAPER_SCRIPTS" "$LOG_DIR"

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] STEMwerk AppImage installer started"
  echo "Source: $SRC"
  echo "Destination: $DEST"
  rsync -a --delete "$SRC/" "$DEST/"
  echo "Copy finished successfully"
} >"$LOG_FILE" 2>&1 || {
  MESSAGE=$(printf 'STEMwerk could not copy the files to:\n%s\n\nSee the log:\n%s' "$DEST" "$LOG_FILE")
  printf '%b\n' "$MESSAGE" >&2
  show_dialog "STEMwerk Installer" "$MESSAGE" "$MESSAGE" error || true
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$LOG_FILE" >/dev/null 2>&1 || true
  fi
  exit 1
}

PLAIN_MESSAGE=$(printf 'STEMwerk files were copied to:\n%s\n\nNext step:\n1. Open REAPER\n2. Run STEMwerk-SETUP.lua\n3. Then run STEMwerk.lua\n\nLog:\n%s' "$DEST" "$LOG_FILE")
RICH_MESSAGE=$(printf '<span size="x-large"><span foreground="#d83b01"><b>S</b></span><span foreground="#107c10"><b>T</b></span><span foreground="#0078d4"><b>E</b></span><span foreground="#ffb900"><b>M</b></span><b>werk Installer</b></span>\n\nSTEMwerk files were copied to:\n%s\n\n<b>Next step</b>\n1. Open REAPER\n2. Run STEMwerk-SETUP.lua\n3. Then run STEMwerk.lua\n\nLog:\n%s' "$DEST" "$LOG_FILE")

echo "STEMwerk files copied to: $DEST"
echo ""
echo "Next steps:"
echo "1) In REAPER, open Actions -> Load ReaScript..."
echo "2) Add: $DEST/STEMwerk-SETUP.lua (run this first)"
echo "3) Add: $DEST/STEMwerk.lua"
echo ""
echo "Docs:"
echo "- $DEST/README.md"
echo "- $DEST/docs (if present)"

show_dialog "STEMwerk Installer" "$RICH_MESSAGE" "$PLAIN_MESSAGE" info || true
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
"$APPIMAGETOOL_CMD" "$APPDIR" "STEMwerk-$VERSION-x86_64${OUTPUT_SUFFIX}.AppImage"
popd >/dev/null

mv -f "$BUILD_DIR/STEMwerk-$VERSION-x86_64${OUTPUT_SUFFIX}.AppImage" "$OUT_DIR/"
echo "Built variant ${VARIANT}: $OUT_DIR/STEMwerk-$VERSION-x86_64${OUTPUT_SUFFIX}.AppImage"
