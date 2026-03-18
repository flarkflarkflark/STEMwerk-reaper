#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-arch"
WORK_DIR="$BUILD_DIR/work"

VERSION="${STEMWERK_VERSION:-0.0.0}"

if [[ -z "${STEMWERK_VERSION:-}" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR" "$WORK_DIR"

# Source tarball for makepkg
SRC_DIR="$BUILD_DIR/stemwerk-$VERSION"
mkdir -p "$SRC_DIR"

rsync -a --delete \
  "$ROOT_DIR/scripts/reaper/" \
  "$ROOT_DIR/i18n" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/TODO.md" \
  "$ROOT_DIR/INTEGRATION.md" \
  "$ROOT_DIR/TESTING.md" \
  "$SRC_DIR/"

tar -C "$BUILD_DIR" -czf "$WORK_DIR/stemwerk-$VERSION.tar.gz" "stemwerk-$VERSION"
SHA256="$(sha256sum "$WORK_DIR/stemwerk-$VERSION.tar.gz" | awk '{print $1}')"

# Generate PKGBUILD
sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@SHA256@/$SHA256/g" \
  "$ROOT_DIR/installer/linux/arch/PKGBUILD" > "$WORK_DIR/PKGBUILD"

# Build inside an Arch container (makepkg is Arch-specific)
# NOTE: Ubuntu GitHub runners have Docker available by default.
docker run --rm \
  -v "$WORK_DIR:/work" \
  -w /work \
  archlinux:latest \
  bash -lc "pacman -Sy --noconfirm --needed base-devel zstd; useradd -m builder; chown -R builder:builder /work; su builder -c 'cd /work && makepkg --noconfirm --nosign'"

# Copy output package
dist_pkg="$(ls -1 "$WORK_DIR"/*.pkg.tar.zst | head -n 1)"
cp -f "$dist_pkg" "$OUT_DIR/"

echo "Built: $OUT_DIR/$(basename "$dist_pkg")"
