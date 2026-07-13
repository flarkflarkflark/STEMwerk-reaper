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
    "$dest_dir/"

  rsync -a \
    "$root_dir/i18n" \
    "$root_dir/installer/assets/stemwerk.svg" \
    "$root_dir/installer/assets/stemwerk.png" \
    "$root_dir/README.md" \
    "$root_dir/LICENSE" \
    "$dest_dir/"

  local variant="${STEMWERK_LINUX_VARIANT:-online-minimal}"
  local bundle_dir="${STEMWERK_BUNDLED_PAYLOAD_DIR:-}"
  if [[ "$variant" != "online-minimal" && -z "$bundle_dir" ]]; then
    echo "Variant $variant requires STEMWERK_BUNDLED_PAYLOAD_DIR." >&2
    return 1
  fi
  if [[ -n "$bundle_dir" ]]; then
    if [[ ! -d "$bundle_dir" ]]; then
      echo "Missing bundled payload directory: $bundle_dir" >&2
      return 1
    fi
    mkdir -p "$dest_dir/_bundled"
    rsync -a --delete "$bundle_dir/" "$dest_dir/_bundled/"
  fi
}
