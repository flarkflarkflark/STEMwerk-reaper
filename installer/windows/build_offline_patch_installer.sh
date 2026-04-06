#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="${INNO_EXE:-/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe}"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk_Offline_Patch.iss"

export STEMWERK_VERSION="${STEMWERK_VERSION:-$(tr -d '\r\n' < "$REPO_DIR/VERSION")}"

wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"
