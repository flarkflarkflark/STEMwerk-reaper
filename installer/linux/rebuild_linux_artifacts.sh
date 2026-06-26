#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/linux/dist"

VERSION="${STEMWERK_VERSION:-}"
if [[ -z "$VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: STEMWERK_VERSION is not set and VERSION could not be read." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: bash installer/linux/rebuild_linux_artifacts.sh [--variant NAME|--matrix] [all|deb|rpm|appimage|arch]...

Examples:
  bash installer/linux/rebuild_linux_artifacts.sh all
  bash installer/linux/rebuild_linux_artifacts.sh --variant offline-bundled-rocm-allmodels deb rpm
  bash installer/linux/rebuild_linux_artifacts.sh --matrix appimage
  STEMWERK_VERSION=2.2.1 bash installer/linux/rebuild_linux_artifacts.sh appimage rpm
EOF
}

VARIANT="${STEMWERK_LINUX_VARIANT:-online-minimal}"
MATRIX_MODE=0

if [[ $# -eq 0 ]]; then
  set -- all
fi

declare -A selected=()
while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --variant)
      VARIANT="$2"
      shift 2
      continue
      ;;
    --matrix)
      MATRIX_MODE=1
      shift
      continue
      ;;
    all)
      selected[deb]=1
      selected[rpm]=1
      selected[appimage]=1
      selected[arch]=1
      ;;
    deb|rpm|appimage|arch)
      selected["$arg"]=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown target: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$OUT_DIR"

targets=()
for target in deb rpm appimage arch; do
  if [[ -n "${selected[$target]:-}" ]]; then
    targets+=("$target")
  fi
done

variant_suffix() {
  case "$1" in
    online-minimal) printf '%s' "" ;;
    bundled) printf '%s' "-bundled" ;;
    offline-bundled-cuda-allmodels) printf '%s' "-offline-bundled-nvidia-gpu-allmodels" ;;
    offline-bundled-rocm-allmodels) printf '%s' "-offline-bundled-amd-gpu-allmodels" ;;
    offline-bundled-cpu-allmodels) printf '%s' "-offline-bundled-cpu-allmodels" ;;
    *)
      echo "ERROR: unknown Linux artifact variant: $1" >&2
      return 1
      ;;
  esac
}

build_variant() {
  local variant="$1"
  local suffix
  local payload_dir=""
  suffix="$(variant_suffix "$variant")"

  if [[ "$variant" != "online-minimal" ]]; then
    payload_dir="$(mktemp -d "/tmp/stemwerk-linux-payload-${variant//[^A-Za-z0-9]/_}-XXXXXX")"
    python3 "$ROOT_DIR/tools/build_linux_variant_payload.py" \
      --variant "$variant" \
      --repo-root "$ROOT_DIR" \
      --output-dir "$payload_dir"
  fi

  if [[ -n "${selected[deb]:-}" ]]; then
    rm -f "$OUT_DIR"/stemwerk_"$VERSION"_*"${suffix}".deb
  fi
  if [[ -n "${selected[rpm]:-}" ]]; then
    rm -f "$OUT_DIR"/stemwerk-"$VERSION"-*"${suffix}".rpm
  fi
  if [[ -n "${selected[appimage]:-}" ]]; then
    rm -f "$OUT_DIR"/STEMwerk-"$VERSION"-*"${suffix}".AppImage
  fi
  if [[ -n "${selected[arch]:-}" ]]; then
    rm -f "$OUT_DIR"/stemwerk-"$VERSION"-*"${suffix}".pkg.tar.zst
  fi

  for target in "${targets[@]}"; do
    case "$target" in
      deb)
        STEMWERK_LINUX_VARIANT="$variant" STEMWERK_OUTPUT_SUFFIX="$suffix" STEMWERK_BUNDLED_PAYLOAD_DIR="$payload_dir" bash "$ROOT_DIR/installer/linux/build_deb.sh"
        ;;
      rpm)
        STEMWERK_LINUX_VARIANT="$variant" STEMWERK_OUTPUT_SUFFIX="$suffix" STEMWERK_BUNDLED_PAYLOAD_DIR="$payload_dir" bash "$ROOT_DIR/installer/linux/build_rpm.sh"
        ;;
      appimage)
        STEMWERK_LINUX_VARIANT="$variant" STEMWERK_OUTPUT_SUFFIX="$suffix" STEMWERK_BUNDLED_PAYLOAD_DIR="$payload_dir" bash "$ROOT_DIR/installer/linux/build_appimage.sh"
        ;;
      arch)
        STEMWERK_LINUX_VARIANT="$variant" STEMWERK_OUTPUT_SUFFIX="$suffix" STEMWERK_BUNDLED_PAYLOAD_DIR="$payload_dir" bash "$ROOT_DIR/installer/linux/build_archpkg.sh"
        ;;
    esac
  done

  if [[ -n "$payload_dir" && -d "$payload_dir" ]]; then
    rm -rf "$payload_dir"
  fi
}

variants=("$VARIANT")
if [[ "$MATRIX_MODE" -eq 1 ]]; then
  variants=(
    online-minimal
    bundled
    offline-bundled-cuda-allmodels
    offline-bundled-rocm-allmodels
    offline-bundled-cpu-allmodels
  )
fi

for variant in "${variants[@]}"; do
  build_variant "$variant"
done

MANIFEST="$OUT_DIR/STEMwerk-${VERSION}-linux-build-manifest.txt"
commit="unknown"
if command -v git >/dev/null 2>&1; then
  commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
fi

artifact_patterns=()
if [[ -n "${selected[deb]:-}" ]]; then artifact_patterns+=("$OUT_DIR/stemwerk_${VERSION}_*.deb"); fi
if [[ -n "${selected[rpm]:-}" ]]; then artifact_patterns+=("$OUT_DIR/stemwerk-${VERSION}-*.rpm"); fi
if [[ -n "${selected[appimage]:-}" ]]; then artifact_patterns+=("$OUT_DIR/STEMwerk-${VERSION}-*.AppImage"); fi
if [[ -n "${selected[arch]:-}" ]]; then artifact_patterns+=("$OUT_DIR/stemwerk-${VERSION}-*.pkg.tar.zst"); fi

{
  echo "version=$VERSION"
  echo "git_commit=$commit"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "targets=${targets[*]}"
  echo "variants=${variants[*]}"
  echo
  echo "sha256:"
  for pattern in "${artifact_patterns[@]}"; do
    shopt -s nullglob
    for file in $pattern; do
      sha256sum "$file"
    done
    shopt -u nullglob
  done
} > "$MANIFEST"

echo "Built Linux targets: ${targets[*]}"
echo "Manifest: $MANIFEST"
