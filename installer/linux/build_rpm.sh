#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-rpm"
RPMTOP="$BUILD_DIR/rpmbuild"

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

copy_linux_payload "$ROOT_DIR" "$SRC_DIR"

tar -C "$BUILD_DIR" -czf "$RPMTOP/SOURCES/stemwerk-$VERSION.tar.gz" "stemwerk-$VERSION"
install -m0644 "$ROOT_DIR/installer/linux/stemwerk-integrate-reaper" \
  "$RPMTOP/SOURCES/stemwerk-integrate-reaper"

# Spec (use RPM-safe version)
sed "s/@VERSION@/$RPM_VERSION/g" "$ROOT_DIR/installer/linux/rpm/stemwerk.spec" > "$RPMTOP/SPECS/stemwerk.spec"

rpmbuild \
  --define "_topdir $RPMTOP" \
  -ba "$RPMTOP/SPECS/stemwerk.spec"

# Copy RPM(s)
find "$RPMTOP/RPMS" -type f -name "*.rpm" -maxdepth 3 | while read -r rpm_file; do
  base_name="$(basename "$rpm_file")"
  ext=".rpm"
  stem="${base_name%$ext}"
  cp -f "$rpm_file" "$OUT_DIR/${stem}${OUTPUT_SUFFIX}${ext}"
done

echo "Built variant ${VARIANT} RPM(s) in: $OUT_DIR"
