#!/usr/bin/env bash
# Linux/macOS REAPER test launcher for STEMwerk

set -e

echo "=== STEMwerk REAPER Test ($(uname)) ==="

# Detect REAPER
if [[ "$(uname)" == "Darwin" ]]; then
    REAPER_PATHS=(
        "/Applications/REAPER.app/Contents/MacOS/REAPER"
        "$HOME/Applications/REAPER.app/Contents/MacOS/REAPER"
    )
else
    REAPER_PATHS=(
        "/opt/REAPER/reaper"
        "$HOME/opt/REAPER/reaper"
        "/usr/local/bin/reaper"
    )
fi

REAPER_EXE=""
for path in "${REAPER_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        REAPER_EXE="$path"
        break
    fi
done

if [[ -z "$REAPER_EXE" ]]; then
    echo "Error: REAPER not found. Please install REAPER or specify --reaper-path"
    exit 1
fi

echo "Found REAPER: $REAPER_EXE"

# Activate venv if exists
VENV_PATH="$(dirname "$0")/../../.venv"
if [[ -f "$VENV_PATH/bin/activate" ]]; then
    echo "Activating Python venv..."
    source "$VENV_PATH/bin/activate"
fi

# Check ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo "Warning: ffmpeg not found in PATH"
fi

# Run test harness
TEST_SCRIPT="$(dirname "$0")/../../tests/reaper/run_reaper_test.py"
FILTER="${1:-quick}"

echo "Running test suite (filter: $FILTER)..."
python3 "$TEST_SCRIPT" --reaper-path "$REAPER_EXE" --filter "$FILTER"
