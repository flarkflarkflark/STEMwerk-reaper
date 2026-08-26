#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
INNO_EXE="/mnt/WINDOWS11/Users/Administrator/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
ISS_PATH="$REPO_DIR/installer/windows/STEMwerk.iss"
MODEL_CACHE_DIR="${STEMWERK_MODEL_CACHE_DIR:-$HOME/.local/share/STEMwerk/models}"
DRUMSEP_PREP_SCRIPT="$REPO_DIR/tools/build_windows_drumsep_payload.py"
RAW_VERSION_VALUE="${STEMWERK_VERSION:-$(cat "$REPO_DIR/VERSION")}" 
VERSION_VALUE="$(printf '%s' "$RAW_VERSION_VALUE" | tr -d '\r\n')"
STAMP="$(date +%Y%m%d_%H%M%S)"
VARIANT_FILTER="${STEMWERK_VARIANTS:-all}"
if [[ -z "${VARIANT_FILTER// }" ]]; then
	VARIANT_FILTER="allmodels"
fi

should_build_variant() {
	local variant="$1"
	if [[ "$variant" != "allmodels" ]]; then
		return 1
	fi
	return 0
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

warn_if_non_allmodels_requested() {
	local raw="${VARIANT_FILTER,,}"
	local compact="${raw// /}"
	if [[ "$compact" == "allmodels" || "$compact" == "all" ]]; then
		return
	fi
	echo "Warning: only 'allmodels' is supported for offline-bundled installers; ignoring requested variants: $VARIANT_FILTER" >&2
}

build_variant() {
	local payload_subdir="$1"
	local variant_name="$2"
	local wheel_subdir="$3"
	local drumsep_wheel_subdir="$4"
	local drumsep_model_subdir="$5"
	local offline_tag="$6"
	local dist_dir="$ROOT_DIR/dist"
	local base_out="$dist_dir/STEMwerk-Setup-$VERSION_VALUE.exe"
	local variant_tag="$offline_tag-allmodels"
	if [[ "$variant_name" != "allmodels" ]]; then
		variant_tag="$offline_tag-model-$variant_name"
	fi
	local variant_out="$dist_dir/STEMwerk-Setup-$VERSION_VALUE-$variant_tag.exe"
	echo "Building variant: $variant_name (payload: $payload_subdir)"
	STEMWERK_BUNDLE_RUNTIME=1 \
	STEMWERK_VERSION="$VERSION_VALUE" \
	STEMWERK_MODEL_PAYLOAD_SUBDIR="$payload_subdir" \
	STEMWERK_WHEEL_PAYLOAD_SUBDIR="$wheel_subdir" \
	STEMWERK_DRUMSEP_WHEEL_PAYLOAD_SUBDIR="$drumsep_wheel_subdir" \
	STEMWERK_DRUMSEP_MODEL_PAYLOAD_SUBDIR="$drumsep_model_subdir" \
	STEMWERK_OFFLINE_BUNDLED_ALLMODELS=1 \
	wine "$INNO_EXE" "Z:${ISS_PATH//\//\\}"
	require_file "$base_out"
	mv -f "$base_out" "$variant_out"
}

prepare_wheelhouse() {
	local wheel_subdir="$1"
	local include_cuda="$2"
	local include_directml="$3"
	STEMWERK_WHEELHOUSE_SUBDIR="$wheel_subdir" \
	STEMWERK_INCLUDE_CUDA_WHEELS="$include_cuda" \
	STEMWERK_INCLUDE_DIRECTML_WHEELS="$include_directml" \
	bash "$ROOT_DIR/fetch_runtime_assets.sh"
}

build_flavor() {
	local flavor="$1"
	local wheel_subdir="$2"
	local drumsep_wheel_subdir="$3"
	local offline_tag="$4"
	local include_cuda="$5"
	local include_directml="$6"

	echo "Preparing offline wheelhouse for $flavor..."
	prepare_wheelhouse "$wheel_subdir" "$include_cuda" "$include_directml"

	if should_build_variant "allmodels"; then
		build_variant "$ALL_SUBDIR" "allmodels" "$wheel_subdir" "$drumsep_wheel_subdir" "drumsep-models" "$offline_tag"
	fi
}

BASE_PAYLOAD_DIR="$ROOT_DIR/payload"
ALL_SUBDIR="models-$STAMP-allmodels"

ALL_DIR="$BASE_PAYLOAD_DIR/$ALL_SUBDIR"

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

python3 "$DRUMSEP_PREP_SCRIPT" --payload-root "$ROOT_DIR/payload" --model-src "$MODEL_CACHE_DIR"

warn_if_non_allmodels_requested

build_flavor "nvidia" "wheels-nvidia" "drumsep-wheels-nvidia" "offline-bundled-nvidia-gpu" "1" "0"
build_flavor "amd" "wheels-directml" "drumsep-wheels-directml" "offline-bundled-amd-gpu" "0" "1"
build_flavor "cpu" "wheels-cpu" "drumsep-wheels-cpu" "offline-bundled-cpu" "0" "0"

echo
echo "Build complete. Generated installers in: $ROOT_DIR/dist"
ls -lh "$ROOT_DIR/dist"/STEMwerk-Setup-"$VERSION_VALUE"-offline-bundled-*.exe
