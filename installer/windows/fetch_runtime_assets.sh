#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$ROOT_DIR/payload"
PYTHON_DIR="$PAYLOAD_DIR/python"
FFMPEG_DIR="$PAYLOAD_DIR/ffmpeg"
WHEELS_DIR="$PAYLOAD_DIR/wheels"
INCLUDE_CUDA_WHEELS="${STEMWERK_INCLUDE_CUDA_WHEELS:-1}"

PYTHON_FILE="python-3.11.8-amd64.exe"
PYTHON_URL="https://www.python.org/ftp/python/3.11.8/$PYTHON_FILE"
FFMPEG_FILE="ffmpeg-release-essentials.zip"
FFMPEG_URL="https://www.gyan.dev/ffmpeg/builds/$FFMPEG_FILE"

mkdir -p "$PYTHON_DIR" "$FFMPEG_DIR"

# Build-time dependency for downloading Windows wheels on Linux/macOS hosts.
ensure_pip() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip --version >/dev/null 2>&1 || python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
    python3 -m pip install --quiet --disable-pip-version-check packaging >/dev/null 2>&1 || true
    return 0
  fi
  echo "python3 is required to fetch bundled wheels" >&2
  return 1
}

download_windows_wheels() {
  ensure_pip || return 1
  mkdir -p "$WHEELS_DIR"
  find "$WHEELS_DIR" -maxdepth 1 -type f -name '*.whl' -delete
  python3 "$ROOT_DIR/../../tools/build_windows_wheelhouse.py" --output-dir "$WHEELS_DIR" --include-cuda-wheels "$INCLUDE_CUDA_WHEELS"
}

download_if_missing() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" ]]; then
    echo "Already present: $out"
    return 0
  fi
  echo "Downloading $url"
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
}

download_if_missing "$PYTHON_URL" "$PYTHON_DIR/$PYTHON_FILE"
download_if_missing "$FFMPEG_URL" "$FFMPEG_DIR/$FFMPEG_FILE"
download_windows_wheels

echo
echo "Bundled runtime assets ready:"
ls -lh "$PYTHON_DIR/$PYTHON_FILE" "$FFMPEG_DIR/$FFMPEG_FILE"
echo
echo "Bundled wheels ready:"
ls -lh "$WHEELS_DIR" | sed -n '1,8p'

