#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"
BUILD_DIR="$ROOT_DIR/installer/linux/build-arch"
WORK_DIR="$BUILD_DIR/work"

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
mkdir -p "$OUT_DIR" "$WORK_DIR"

# Source tarball for makepkg
SRC_DIR="$BUILD_DIR/stemwerk-$VERSION"
mkdir -p "$SRC_DIR"

copy_linux_payload "$ROOT_DIR" "$SRC_DIR"

tar -C "$BUILD_DIR" -czf "$WORK_DIR/stemwerk-$VERSION.tar.gz" "stemwerk-$VERSION"
SHA256="$(sha256sum "$WORK_DIR/stemwerk-$VERSION.tar.gz" | awk '{print $1}')"

# Generate PKGBUILD
sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@SHA256@/$SHA256/g" \
  "$ROOT_DIR/installer/linux/arch/PKGBUILD" > "$WORK_DIR/PKGBUILD"

cp -f "$ROOT_DIR/installer/linux/arch/stemwerk.install" "$WORK_DIR/stemwerk.install"

# Build inside an Arch container (makepkg is Arch-specific).
# Copy into a container-local workdir so makepkg can create symlinks even when
# the host workspace mount disallows them.
docker run --rm \
  -v "$WORK_DIR:/src:ro" \
  -v "$WORK_DIR:/out" \
  archlinux:latest \
  bash -lc "set -euo pipefail; pacman -Syu --noconfirm --needed base-devel zstd; useradd -m builder; mkdir -p /work; cp -a /src/. /work/; chown -R builder:builder /work; su builder -c 'cd /work && makepkg --noconfirm --nosign'; cp -f /work/*.pkg.tar.zst /out/"

# Copy output package
dist_pkg="$(ls -1 "$WORK_DIR"/*.pkg.tar.zst | head -n 1)"
base_name="$(basename "$dist_pkg")"
ext=".pkg.tar.zst"
stem="${base_name%$ext}"
cp -f "$dist_pkg" "$OUT_DIR/${stem}${OUTPUT_SUFFIX}${ext}"

echo "Built variant ${VARIANT}: $OUT_DIR/${stem}${OUTPUT_SUFFIX}${ext}"
