#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/macos/dist"
SCRIPTS_DIR="$ROOT_DIR/installer/macos/scripts"
BUNDLED_PAYLOAD_ROOT="$ROOT_DIR/scripts/reaper/_bundled/macos/apple-silicon"

VERSION="${STEMWERK_VERSION:-}"
PKG_ID="com.flarkaudio.stemwerk"
VARIANT="online"
OUTPUT_SUFFIX=""

usage() {
  cat <<'EOF'
Usage: build_pkg.sh [--variant online|bundled-apple-silicon|offline-bundled-apple-silicon-mps-allmodels]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 1
      }
      VARIANT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" && -f "$ROOT_DIR/VERSION" ]]; then
  VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: STEMWERK_VERSION is not set and VERSION could not be read." >&2
  exit 1
fi

case "$VARIANT" in
  online)
    OUTPUT_SUFFIX=""
    ;;
  bundled-apple-silicon)
    OUTPUT_SUFFIX="-bundled-apple-silicon"
    ;;
  offline-bundled-apple-silicon-mps-allmodels)
    OUTPUT_SUFFIX="-offline-bundled-apple-silicon-mps-allmodels"
    ;;
  *)
    echo "ERROR: unsupported variant: $VARIANT" >&2
    usage >&2
    exit 1
    ;;
esac

STAGE="$ROOT_DIR/installer/macos/build/$VARIANT/root"
PAYLOAD_DEST="$STAGE/Users/Shared/STEMwerk-reaper/_bundled/macos/apple-silicon"
OUTPUT_PKG="$OUT_DIR/STEMwerk-$VERSION$OUTPUT_SUFFIX.pkg"

rm -rf "$STAGE"
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
  "$STAGE/Users/Shared/STEMwerk-reaper/"

case "$VARIANT" in
  online)
    rm -rf "$STAGE/Users/Shared/STEMwerk-reaper/_bundled/macos/apple-silicon"
    ;;
  bundled-apple-silicon|offline-bundled-apple-silicon-mps-allmodels)
    if [[ -d "$BUNDLED_PAYLOAD_ROOT" ]]; then
      mkdir -p "$(dirname "$PAYLOAD_DEST")"
      rsync -a --delete "$BUNDLED_PAYLOAD_ROOT/" "$PAYLOAD_DEST/"
    else
      mkdir -p "$PAYLOAD_DEST"
      cat > "$PAYLOAD_DEST/.variant-placeholder" <<EOF
variant=$VARIANT
payload_status=missing
EOF
    fi
    ;;
esac

# Ensure pkg scripts are executable
chmod +x "$SCRIPTS_DIR/postinstall" 2>/dev/null || true

pkgbuild \
  --root "$STAGE" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  "$OUTPUT_PKG"

echo "Built: $OUTPUT_PKG"
