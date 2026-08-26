#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk.iss"
RAW_VERSION_VALUE="${STEMWERK_VERSION:-$(cat "$REPO_DIR/VERSION")}"
VERSION_VALUE="$(printf '%s' "$RAW_VERSION_VALUE" | tr -d '\r\n')"
OUT_EXE="$ROOT_DIR/dist/STEMwerk-Setup-$VERSION_VALUE-bundled.exe"
MAX_BYTES=$((500 * 1024 * 1024))

STEMWERK_SKIP_WHEELHOUSE=1 \
bash "$ROOT_DIR/fetch_runtime_assets.sh"

export STEMWERK_BUNDLE_RUNTIME=1
export STEMWERK_OUTPUT_SUFFIX="-bundled"
unset STEMWERK_WHEEL_PAYLOAD_SUBDIR
unset STEMWERK_MODEL_PAYLOAD_SUBDIR
unset STEMWERK_WHEELHOUSE_SUBDIR
unset STEMWERK_INCLUDE_CUDA_WHEELS
unset STEMWERK_INCLUDE_DIRECTML_WHEELS
wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"

if [[ ! -f "$OUT_EXE" ]]; then
  echo "Bundled installer not found: $OUT_EXE" >&2
  exit 1
fi

size_bytes="$(stat -c '%s' "$OUT_EXE")"
if [[ "$size_bytes" -gt "$MAX_BYTES" ]]; then
  echo "Normal bundled installer is too large; possible allmodels/GPU payload contamination." >&2
  echo "File: $OUT_EXE" >&2
  echo "Size bytes: $size_bytes (limit: $MAX_BYTES)" >&2
  exit 1
fi
