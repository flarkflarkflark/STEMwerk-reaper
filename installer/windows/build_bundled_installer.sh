#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk.iss"

"$ROOT_DIR/fetch_runtime_assets.sh"

export STEMWERK_BUNDLE_RUNTIME=1
wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"
