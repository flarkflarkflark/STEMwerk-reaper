#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$ROOT_DIR/payload"
PYTHON_DIR="$PAYLOAD_DIR/python"
FFMPEG_DIR="$PAYLOAD_DIR/ffmpeg"

PYTHON_FILE="python-3.11.8-amd64.exe"
PYTHON_URL="https://www.python.org/ftp/python/3.11.8/$PYTHON_FILE"
FFMPEG_FILE="ffmpeg-release-essentials.zip"
FFMPEG_URL="https://www.gyan.dev/ffmpeg/builds/$FFMPEG_FILE"

mkdir -p "$PYTHON_DIR" "$FFMPEG_DIR"

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

echo
echo "Bundled runtime assets ready:"
ls -lh "$PYTHON_DIR/$PYTHON_FILE" "$FFMPEG_DIR/$FFMPEG_FILE"

