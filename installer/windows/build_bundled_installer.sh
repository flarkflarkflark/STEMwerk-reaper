#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk.iss"

"$ROOT_DIR/fetch_runtime_assets.sh"

export STEMWERK_BUNDLE_RUNTIME=1
wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"

RAW_VERSION_VALUE="${STEMWERK_VERSION:-$(cat "$REPO_DIR/VERSION")}" 
VERSION_VALUE="$(printf '%s' "$RAW_VERSION_VALUE" | tr -d '\r\n')"
DIST_DIR="$ROOT_DIR/dist"
BASE_OUT="$DIST_DIR/STEMwerk-Setup-$VERSION_VALUE.exe"
BUNDLED_OUT="$DIST_DIR/STEMwerk-Setup-$VERSION_VALUE-bundled.exe"
if [[ -f "$BASE_OUT" ]]; then
	mv -f "$BASE_OUT" "$BUNDLED_OUT"
fi
