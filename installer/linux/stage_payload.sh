#!/usr/bin/env bash
set -euo pipefail

copy_linux_payload() {
  local root_dir="$1"
  local dest_dir="$2"

  mkdir -p "$dest_dir"

  rsync -a --delete \
    --exclude='*.bak' \
    --exclude='*.bak2' \
    --exclude='*.pyc' \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='__MACOSX/' \
    --exclude='__pycache__/' \
    --exclude='sync_to_reaper.sh' \
    --exclude='STEMwerk_Enable_Debug.lua' \
    --exclude='STEMwerk_Disable_Debug.lua' \
    --exclude='STEMwerk_Set_FFmpegPath.lua' \
    --exclude='STEMwerk_Set_PythonPath.lua' \
    --exclude='STEMwerk_separate.lua' \
    --exclude='themes/' \
    --exclude='assets/toolbar_icons/stemwerk_*.png' \
    --exclude='vendor/stemwerk-core/build/' \
    --exclude='vendor/stemwerk-core/src/*.egg-info/' \
    "$root_dir/scripts/reaper/" \
    "$root_dir/i18n" \
    "$root_dir/installer/assets/stemwerk.svg" \
    "$root_dir/README.md" \
    "$root_dir/LICENSE" \
    "$root_dir/TODO.md" \
    "$dest_dir/"
}
