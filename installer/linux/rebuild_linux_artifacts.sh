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
Usage: bash installer/linux/rebuild_linux_artifacts.sh [all|deb|rpm|appimage|arch]...

Examples:
  bash installer/linux/rebuild_linux_artifacts.sh all
  STEMWERK_VERSION=2.2.1 bash installer/linux/rebuild_linux_artifacts.sh appimage rpm
EOF
}

if [[ $# -eq 0 ]]; then
  set -- all
fi

declare -A selected=()
for arg in "$@"; do
  case "$arg" in
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
done

mkdir -p "$OUT_DIR"

if [[ -n "${selected[deb]:-}" ]]; then
  rm -f "$OUT_DIR"/stemwerk_"$VERSION"_*.deb
fi
if [[ -n "${selected[rpm]:-}" ]]; then
  rm -f "$OUT_DIR"/stemwerk-"$VERSION"-*.rpm
fi
if [[ -n "${selected[appimage]:-}" ]]; then
  rm -f "$OUT_DIR"/STEMwerk-"$VERSION"-*.AppImage
fi
if [[ -n "${selected[arch]:-}" ]]; then
  rm -f "$OUT_DIR"/stemwerk-"$VERSION"-*.pkg.tar.zst
fi

targets=()
for target in deb rpm appimage arch; do
  if [[ -n "${selected[$target]:-}" ]]; then
    targets+=("$target")
  fi
done

for target in "${targets[@]}"; do
  case "$target" in
    deb)
      bash "$ROOT_DIR/installer/linux/build_deb.sh"
      ;;
    rpm)
      bash "$ROOT_DIR/installer/linux/build_rpm.sh"
      ;;
    appimage)
      bash "$ROOT_DIR/installer/linux/build_appimage.sh"
      ;;
    arch)
      bash "$ROOT_DIR/installer/linux/build_archpkg.sh"
      ;;
  esac
done

MANIFEST="$OUT_DIR/STEMwerk-${VERSION}-linux-build-manifest.txt"
commit="unknown"
if command -v git >/dev/null 2>&1; then
  commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
fi

artifact_patterns=()
if [[ -n "${selected[deb]:-}" ]]; then
  artifact_patterns+=("$OUT_DIR/stemwerk_${VERSION}_*.deb")
fi
if [[ -n "${selected[rpm]:-}" ]]; then
  artifact_patterns+=("$OUT_DIR/stemwerk-${VERSION}-*.rpm")
fi
if [[ -n "${selected[appimage]:-}" ]]; then
  artifact_patterns+=("$OUT_DIR/STEMwerk-${VERSION}-*.AppImage")
fi
if [[ -n "${selected[arch]:-}" ]]; then
  artifact_patterns+=("$OUT_DIR/stemwerk-${VERSION}-*.pkg.tar.zst")
fi

{
  echo "version=$VERSION"
  echo "git_commit=$commit"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "targets=${targets[*]}"
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
