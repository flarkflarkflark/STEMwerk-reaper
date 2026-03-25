#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/macos/dist"
STAGE="$ROOT_DIR/installer/macos/build/root"
SCRIPTS_DIR="$ROOT_DIR/installer/macos/scripts"

VERSION="${STEMWERK_VERSION:-}"
PKG_ID="com.flarkaudio.stemwerk"

if [[ -z "$VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: STEMWERK_VERSION is not set and VERSION could not be read." >&2
  exit 1
fi

rm -rf "$OUT_DIR" "$STAGE"
mkdir -p "$OUT_DIR" "$STAGE/Users/Shared/STEMwerk-reaper"

# Copy only what we need
rsync -a --delete \
  --exclude='*.bak' \
  --exclude='*.bak2' \
  --exclude='sync_to_reaper.sh' \
  --exclude='STEMwerk_Enable_Debug.lua' \
  --exclude='STEMwerk_Disable_Debug.lua' \
  --exclude='STEMwerk_Set_FFmpegPath.lua' \
  --exclude='STEMwerk_Set_PythonPath.lua' \
  --exclude='STEMwerk_separate.lua' \
  "$ROOT_DIR/scripts/reaper/" \
  "$ROOT_DIR/i18n" \
  "$ROOT_DIR/installer/assets/stemwerk.svg" \
  "$ROOT_DIR/docs" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/TODO.md" \
  "$ROOT_DIR/INTEGRATION.md" \
  "$ROOT_DIR/TESTING.md" \
  "$STAGE/Users/Shared/STEMwerk-reaper/"

# Ensure pkg scripts are executable
chmod +x "$SCRIPTS_DIR/postinstall" 2>/dev/null || true

pkgbuild \
  --root "$STAGE" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  "$OUT_DIR/STEMwerk-$VERSION.pkg"

echo "Built: $OUT_DIR/STEMwerk-$VERSION.pkg"
