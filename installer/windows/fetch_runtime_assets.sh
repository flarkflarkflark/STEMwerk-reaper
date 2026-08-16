#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$ROOT_DIR/payload"
PYTHON_DIR="$PAYLOAD_DIR/python"
FFMPEG_DIR="$PAYLOAD_DIR/ffmpeg"
WHEELHOUSE_SUBDIR="${STEMWERK_WHEELHOUSE_SUBDIR:-wheels}"
WHEELS_DIR="$PAYLOAD_DIR/$WHEELHOUSE_SUBDIR"
INCLUDE_CUDA_WHEELS="${STEMWERK_INCLUDE_CUDA_WHEELS:-1}"
INCLUDE_DIRECTML_WHEELS="${STEMWERK_INCLUDE_DIRECTML_WHEELS:-0}"
SKIP_WHEELHOUSE="${STEMWERK_SKIP_WHEELHOUSE:-0}"

PYTHON_FILE="python-3.11.8-amd64.exe"
PYTHON_URL="https://www.python.org/ftp/python/3.11.8/$PYTHON_FILE"
PYTHON_SHA256="fd3428eb6c80901b877d036ffa2be127ccad9bbe036a43f00fc96a48b724f9c7"

# The plain "ffmpeg-release-essentials.zip" alias is a rolling redirect to
# whatever gyan.dev currently considers the latest release build, so it is
# not a stable input on its own. Fetch from the exact versioned package URL
# it currently resolves to (release 9.0.1) instead, pinned with the SHA256
# gyan.dev itself publishes for that package
# (https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip.sha256).
# The local cache/staged filename stays "ffmpeg-release-essentials.zip" so
# STEMwerk.iss's payload\ffmpeg\ffmpeg-release-essentials.zip reference does
# not need to change every time this pin is bumped.
FFMPEG_FILE="ffmpeg-release-essentials.zip"
FFMPEG_URL="https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip"
FFMPEG_SHA256="fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9"

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
  python3 "$ROOT_DIR/../../tools/build_windows_wheelhouse.py" \
    --output-dir "$WHEELS_DIR" \
    --include-cuda-wheels "$INCLUDE_CUDA_WHEELS" \
    --include-directml-wheels "$INCLUDE_DIRECTML_WHEELS"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: SHA256 mismatch for $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
  return 0
}

download_if_missing() {
  local url="$1"
  local out="$2"
  local expected_sha256="$3"
  if [[ -f "$out" ]]; then
    if verify_sha256 "$out" "$expected_sha256"; then
      echo "Already present and verified: $out"
      return 0
    fi
    echo "Cached file failed checksum verification, re-downloading: $out" >&2
    rm -f "$out"
  fi
  echo "Downloading $url"
  curl -L --fail --retry 3 --retry-delay 2 -o "$out" "$url"
  if ! verify_sha256 "$out" "$expected_sha256"; then
    rm -f "$out"
    echo "ERROR: downloaded file failed checksum verification, refusing to use it: $out" >&2
    return 1
  fi
}

if [[ "${STEMWERK_FETCH_RUNTIME_ASSETS_NO_MAIN:-0}" != "1" ]]; then
  download_if_missing "$PYTHON_URL" "$PYTHON_DIR/$PYTHON_FILE" "$PYTHON_SHA256"
  download_if_missing "$FFMPEG_URL" "$FFMPEG_DIR/$FFMPEG_FILE" "$FFMPEG_SHA256"
  if [[ "$SKIP_WHEELHOUSE" != "1" ]]; then
    download_windows_wheels
  fi

  echo
  echo "Bundled runtime assets ready:"
  ls -lh "$PYTHON_DIR/$PYTHON_FILE" "$FFMPEG_DIR/$FFMPEG_FILE"
  if [[ "$SKIP_WHEELHOUSE" == "1" ]]; then
    echo
    echo "Skipping wheelhouse fetch (STEMWERK_SKIP_WHEELHOUSE=1)"
  else
    echo
    echo "Bundled wheels ready ($WHEELHOUSE_SUBDIR):"
    ls -lh "$WHEELS_DIR" | sed -n '1,8p'
  fi
fi
