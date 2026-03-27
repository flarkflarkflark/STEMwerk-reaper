#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-rpm"
RPMTOP="$BUILD_DIR/rpmbuild"

VERSION="${STEMWERK_VERSION:-}"

if [[ -z "$VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: STEMWERK_VERSION is not set and VERSION could not be read." >&2
  exit 1
fi

# RPM spec "Version:" may not contain '-' characters.
# Our CI/dev versions sometimes include a suffix (e.g. 2.1.0-devabcdef0 or 2.1.0-abcdef0).
# Keep the semantic meaning but make it RPM-safe.
RPM_VERSION="${VERSION//-/.}"

rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR" \
  "$RPMTOP/BUILD" "$RPMTOP/RPMS" "$RPMTOP/SOURCES" "$RPMTOP/SPECS" "$RPMTOP/SRPMS"

# Create source tarball
SRC_DIR="$BUILD_DIR/stemwerk-$VERSION"
mkdir -p "$SRC_DIR"

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
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/TODO.md" \
  "$SRC_DIR/"

tar -C "$BUILD_DIR" -czf "$RPMTOP/SOURCES/stemwerk-$VERSION.tar.gz" "stemwerk-$VERSION"

# Spec (use RPM-safe version)
sed "s/@VERSION@/$RPM_VERSION/g" "$ROOT_DIR/installer/linux/rpm/stemwerk.spec" > "$RPMTOP/SPECS/stemwerk.spec"

rpmbuild \
  --define "_topdir $RPMTOP" \
  -ba "$RPMTOP/SPECS/stemwerk.spec"

# Copy RPM(s)
find "$RPMTOP/RPMS" -type f -name "*.rpm" -maxdepth 3 -print -exec cp -f {} "$OUT_DIR/" \;

echo "Built RPM(s) in: $OUT_DIR"
