#!/usr/bin/env bash
set -euo pipefail

# Sync the repo versions of the REAPER scripts into the user's REAPER Scripts
# folder. This is useful because REAPER often runs the copies under its config
# directory, not the files inside this git repo.
#
# Linux:  ~/.config/REAPER/Scripts/STEMwerk-reaper/
# macOS:  ~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/
#
# Usage (from repo root):
#   bash scripts/reaper/sync_to_reaper.sh

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src_dir="${repo_root}/scripts/reaper"

linux_dest="${HOME}/.config/REAPER/Scripts/STEMwerk-reaper"
mac_dest="${HOME}/Library/Application Support/REAPER/Scripts/STEMwerk-reaper"

dest=""
if [[ -d "${HOME}/.config/REAPER" ]]; then
  dest="${linux_dest}"
elif [[ -d "${HOME}/Library/Application Support/REAPER" ]]; then
  dest="${mac_dest}"
else
  echo "Could not find a REAPER config directory in HOME."
  echo "Expected either:"
  echo "  ${HOME}/.config/REAPER"
  echo "  ${HOME}/Library/Application Support/REAPER"
  exit 1
fi

mkdir -p "${dest}"

prune_files=(
  "STEMwerk.lua.bak"
  "STEMwerk.lua.bak2"
  "sync_to_reaper.sh"
  "STEMwerk_Enable_Debug.lua"
  "STEMwerk_Disable_Debug.lua"
  "STEMwerk_Set_FFmpegPath.lua"
  "STEMwerk_Set_PythonPath.lua"
  "STEMwerk_separate.lua"
)

for rel in "${prune_files[@]}"; do
  rm -f "${dest}/${rel}"
done

rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='*.bak' \
  --exclude='*.bak2' \
  --exclude='.DS_Store' \
  --exclude='sync_to_reaper.sh' \
  --exclude='STEMwerk_Enable_Debug.lua' \
  --exclude='STEMwerk_Disable_Debug.lua' \
  --exclude='STEMwerk_Set_FFmpegPath.lua' \
  --exclude='STEMwerk_Set_PythonPath.lua' \
  --exclude='STEMwerk_separate.lua' \
  --exclude='vendor/stemwerk-core/build/' \
  "${src_dir}/" \
  "${dest}/"

# Keep using script-local i18n from scripts/reaper/i18n.
# Do not overwrite with repo-root i18n, which can be older and cause
# raw-key/fallback regressions in live REAPER UI.

if [[ ! -f "${dest}/vendor/stemwerk-core/pyproject.toml" ]] \
  || [[ ! -f "${dest}/vendor/stemwerk-core/src/stemwerk_core/__init__.py" ]] \
  || [[ ! -f "${dest}/vendor/stemwerk-core/src/stemwerk_core/separator.py" ]]; then
  echo "WARNING: stemwerk-core source bundle was not synced to ${dest}/vendor/stemwerk-core" >&2
fi

echo
echo "Synced STEMwerk scripts to: ${dest}"
echo "Restart REAPER (or re-run the script) to pick up changes."
