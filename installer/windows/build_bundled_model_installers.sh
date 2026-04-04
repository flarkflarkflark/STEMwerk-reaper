#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk.iss"
MODEL_CACHE_DIR="${STEMWERK_MODEL_CACHE_DIR:-$HOME/.local/share/STEMwerk/models}"
RAW_VERSION_VALUE="${STEMWERK_VERSION:-$(cat "$REPO_DIR/VERSION")}" 
VERSION_VALUE="$(printf '%s' "$RAW_VERSION_VALUE" | tr -d '\r\n')"
STAMP="$(date +%Y%m%d_%H%M%S)"
VARIANT_FILTER="${STEMWERK_VARIANTS:-all}"
INCLUDE_CUDA_WHEELS="${STEMWERK_INCLUDE_CUDA_WHEELS:-1}"

if [[ "$INCLUDE_CUDA_WHEELS" == "0" ]]; then
	OFFLINE_TAG="offline-bundled-cpu"
else
	OFFLINE_TAG="offline-bundled-gpu"
fi

should_build_variant() {
	local variant="$1"
	if [[ "$VARIANT_FILTER" == "all" ]]; then
		return 0
	fi
	IFS=',' read -r -a requested <<< "$VARIANT_FILTER"
	for v in "${requested[@]}"; do
		if [[ "${v// /}" == "$variant" ]]; then
			return 0
		fi
	done
	return 1
}

require_file() {
	local path="$1"
	if [[ ! -f "$path" ]]; then
		echo "Missing required file: $path" >&2
		exit 1
	fi
}

copy_variant_files() {
	local dest_dir="$1"
	shift
	mkdir -p "$dest_dir"
	for rel in "$@"; do
		require_file "$MODEL_CACHE_DIR/$rel"
		cp -f "$MODEL_CACHE_DIR/$rel" "$dest_dir/"
	done
}

build_variant() {
	local payload_subdir="$1"
	local variant_name="$2"
	local dist_dir="$ROOT_DIR/dist"
	local base_out="$dist_dir/STEMwerk-Setup-$VERSION_VALUE.exe"
	local variant_tag="$OFFLINE_TAG-allmodels"
	if [[ "$variant_name" != "allmodels" ]]; then
		variant_tag="$OFFLINE_TAG-model-$variant_name"
	fi
	local variant_out="$dist_dir/STEMwerk-Setup-$VERSION_VALUE-$variant_tag.exe"
	echo "Building variant: $variant_name (payload: $payload_subdir)"
	STEMWERK_BUNDLE_RUNTIME=1 \
	STEMWERK_VERSION="$VERSION_VALUE" \
	STEMWERK_MODEL_PAYLOAD_SUBDIR="$payload_subdir" \
	wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"
	require_file "$base_out"
	mv -f "$base_out" "$variant_out"
}

"$ROOT_DIR/fetch_runtime_assets.sh"

BASE_PAYLOAD_DIR="$ROOT_DIR/payload"
FAST_SUBDIR="models-$STAMP-fast"
QUALITY_SUBDIR="models-$STAMP-quality"
SIXSTEM_SUBDIR="models-$STAMP-6stem"
ALL_SUBDIR="models-$STAMP-allmodels"

FAST_DIR="$BASE_PAYLOAD_DIR/$FAST_SUBDIR"
QUALITY_DIR="$BASE_PAYLOAD_DIR/$QUALITY_SUBDIR"
SIXSTEM_DIR="$BASE_PAYLOAD_DIR/$SIXSTEM_SUBDIR"
ALL_DIR="$BASE_PAYLOAD_DIR/$ALL_SUBDIR"

copy_variant_files "$FAST_DIR" \
	htdemucs.yaml \
	955717e8-8726e21a.th \
	download_checks.json

copy_variant_files "$QUALITY_DIR" \
	htdemucs_ft.yaml \
	f7e0c4bc-ba3fe64a.th \
	d12395a8-e57c48e6.th \
	92cfc3b6-ef3bcb9c.th \
	04573f0d-f3cf25b2.th \
	download_checks.json

copy_variant_files "$SIXSTEM_DIR" \
	htdemucs_6s.yaml \
	5c90dfd2-34c22ccb.th \
	download_checks.json

copy_variant_files "$ALL_DIR" \
	htdemucs.yaml \
	htdemucs_ft.yaml \
	htdemucs_6s.yaml \
	955717e8-8726e21a.th \
	f7e0c4bc-ba3fe64a.th \
	d12395a8-e57c48e6.th \
	92cfc3b6-ef3bcb9c.th \
	04573f0d-f3cf25b2.th \
	5c90dfd2-34c22ccb.th \
	download_checks.json

if should_build_variant "fast"; then
	build_variant "$FAST_SUBDIR" "fast"
fi
if should_build_variant "quality"; then
	build_variant "$QUALITY_SUBDIR" "quality"
fi
if should_build_variant "6stem"; then
	build_variant "$SIXSTEM_SUBDIR" "6stem"
fi
if should_build_variant "allmodels"; then
	build_variant "$ALL_SUBDIR" "allmodels"
fi

echo
echo "Build complete. Generated installers in: $ROOT_DIR/dist"
ls -lh "$ROOT_DIR/dist"/STEMwerk-Setup-"$VERSION_VALUE"-offline-bundled-*.exe
