#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/installer/macos/dist"
SCRIPTS_DIR="$ROOT_DIR/installer/macos/scripts"
BUNDLED_PAYLOAD_ROOT="$ROOT_DIR/scripts/reaper/_bundled/macos/apple-silicon"
PAYLOAD_MANIFEST="$ROOT_DIR/installer/macos/payload-manifest.txt"
PAYLOAD_AUDITOR="$ROOT_DIR/installer/macos/audit_payload.py"

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
PACKAGE_REPACK_DIR=""

cleanup() {
  if [[ -n "$PACKAGE_REPACK_DIR" && -d "$PACKAGE_REPACK_DIR" ]]; then
    rm -rf "$PACKAGE_REPACK_DIR"
  fi
}
trap cleanup EXIT

remove_appledouble_sidecars() {
  find "$1" -name '._*' -delete
}

repack_pkg_without_appledouble() {
  PACKAGE_REPACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stemwerk-macos-pkg-repack.XXXXXX")"
  (
    cd "$PACKAGE_REPACK_DIR"
    xar -xf "$OUTPUT_PKG"
  )

  mkbom "$STAGE" "$PACKAGE_REPACK_DIR/Bom"
  (
    cd "$STAGE"
    find . -print | cpio -o --format odc --owner 0:80 2>/dev/null | gzip -c > "$PACKAGE_REPACK_DIR/Payload"
  )

  rm -f "$OUTPUT_PKG"
  (
    cd "$PACKAGE_REPACK_DIR"
    xar --compression none -cf "$OUTPUT_PKG" Bom Payload Scripts PackageInfo
  )
}

rm -rf "$STAGE"
mkdir -p "$OUT_DIR" "$STAGE/Users/Shared/STEMwerk-reaper"

PAYLOAD_ROOT="$STAGE/Users/Shared/STEMwerk-reaper"
awk -F '\t' '
  $0 !~ /^#/ && NF >= 2 { if (seen[$2]++) { print "ERROR: duplicate payload destination: " $2 > "/dev/stderr"; exit 1 } }
' "$PAYLOAD_MANIFEST"
while IFS=$'\t' read -r source destination; do
  [[ -n "$source" && "${source:0:1}" != "#" ]] || continue
  [[ -e "$ROOT_DIR/$source" ]] || {
    echo "ERROR: manifest source is missing: $source" >&2
    exit 1
  }
  mkdir -p "$(dirname "$PAYLOAD_ROOT/$destination")"
  cp -p "$ROOT_DIR/$source" "$PAYLOAD_ROOT/$destination"
done < "$PAYLOAD_MANIFEST"

case "$VARIANT" in
  online)
    rm -rf "$STAGE/Users/Shared/STEMwerk-reaper/_bundled/macos/apple-silicon"
    ;;
  bundled-apple-silicon|offline-bundled-apple-silicon-mps-allmodels)
    if [[ -d "$BUNDLED_PAYLOAD_ROOT" ]]; then
      mkdir -p "$(dirname "$PAYLOAD_DEST")"
      rsync -a --delete \
        --exclude='._*' --exclude='*.exe' --exclude='*.dll' \
        --exclude='*.bat' --exclude='*.cmd' --exclude='*.ps1' \
        "$BUNDLED_PAYLOAD_ROOT/" "$PAYLOAD_DEST/"
    else
      mkdir -p "$PAYLOAD_DEST"
      cat > "$PAYLOAD_DEST/.variant-placeholder" <<EOF
variant=$VARIANT
payload_status=missing
EOF
    fi
    ;;
esac

remove_appledouble_sidecars "$STAGE"
python3 "$PAYLOAD_AUDITOR" --root "$PAYLOAD_ROOT" \
  --variant "$VARIANT" --inventory "$ROOT_DIR/installer/macos/build/$VARIANT/payload-inventory.json"

if [[ "${STEMWERK_STAGE_ONLY:-0}" == "1" ]]; then
  echo "Staged and audited: $PAYLOAD_ROOT"
  exit 0
fi

# Ensure pkg scripts are executable
chmod +x "$SCRIPTS_DIR/postinstall" 2>/dev/null || true

pkgbuild \
  --root "$STAGE" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  "$OUTPUT_PKG"

repack_pkg_without_appledouble

echo "Built: $OUTPUT_PKG"
