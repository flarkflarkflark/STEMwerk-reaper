#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"
BUNDLED_PAYLOAD_DIR="${SCRIPT_DIR}/_bundled/macos/apple-silicon"
MACOS_ARM_CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints/macos.txt"
MACOS_INTEL_CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints/macos-intel.txt"
MACOS_CONSTRAINTS_FILE=""
PINNED_NUMPY_VERSION="1.26.4"
PINNED_NUMBA_VERSION="0.59.1"
PINNED_LLVMLITE_VERSION="0.42.0"
PINNED_AUDIO_SEPARATOR_VERSION="0.23.0"
PINNED_SAMPLERATE_VERSION="0.1.0"
PINNED_PYTHON_MAJOR_MINOR="3.12"
PINNED_TORCH_VERSION=""
PINNED_TORCHVISION_VERSION=""
PINNED_TORCHAUDIO_VERSION=""
PINNED_TORCH_VERSION_ARM64="2.5.1"
PINNED_TORCHVISION_VERSION_ARM64="0.20.1"
PINNED_TORCHAUDIO_VERSION_ARM64="2.5.1"
PINNED_TORCH_VERSION_INTEL="2.2.2"
PINNED_TORCHVISION_VERSION_INTEL="0.17.2"
PINNED_TORCHAUDIO_VERSION_INTEL="2.2.2"
PINNED_TORCH_STACK_LABEL=""
TORCH_PIN_APPLIED="0"

RUNTIME_BASE=""
STATE_FILE=""
LOG_FILE=""
MODE="repair"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-base) RUNTIME_BASE="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "${LOG_FILE}" ]; then
  LOG_FILE="/dev/null"
fi

log() {
  if [ -n "${LOG_FILE}" ]; then
    printf "%s\n" "$*" >> "$LOG_FILE"
  fi
}

resolve_existing_path() {
  if [ -z "${1:-}" ] || [ ! -e "$1" ]; then
    return 1
  fi
  _dir=$(CDPATH= cd -- "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf "%s/%s\n" "${_dir}" "$(basename "$1")"
}

resolve_python_candidate() {
  case "$1" in
    */*)
      resolve_existing_path "$1"
      ;;
    *)
      _resolved=$(command_path "$1" || true)
      [ -n "${_resolved}" ] || return 1
      case "${_resolved}" in
        /*) resolve_existing_path "${_resolved}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

bundled_payload_available() {
  [ "${MAC_ARCH:-unknown}" = "arm64" ] \
    && [ -f "${BUNDLED_PAYLOAD_DIR}/manifest.json" ] \
    && [ -d "${BUNDLED_PAYLOAD_DIR}/wheels" ] \
    && [ -d "${BUNDLED_PAYLOAD_DIR}/python" ] \
    && [ -d "${BUNDLED_PAYLOAD_DIR}/models" ] \
    && [ -d "${BUNDLED_PAYLOAD_DIR}/drumsep" ] \
    && { [ -x "${BUNDLED_PAYLOAD_DIR}/ffmpeg/ffmpeg" ] || [ -x "${BUNDLED_PAYLOAD_DIR}/ffmpeg/bin/ffmpeg" ]; }
}

bundled_ffmpeg_path() {
  for _p in \
    "${BUNDLED_PAYLOAD_DIR}/ffmpeg/ffmpeg" \
    "${BUNDLED_PAYLOAD_DIR}/ffmpeg/bin/ffmpeg"
  do
    if [ -x "${_p}" ]; then
      printf "%s\n" "${_p}"
      return 0
    fi
  done
  return 1
}

bundled_wheels_dir() {
  [ -d "${BUNDLED_PAYLOAD_DIR}/wheels" ] || return 1
  printf "%s\n" "${BUNDLED_PAYLOAD_DIR}/wheels"
}

bundled_managed_python_dir() {
  [ -d "${BUNDLED_PAYLOAD_DIR}/python" ] || return 1
  printf "%s\n" "${BUNDLED_PAYLOAD_DIR}/python"
}

bundled_stemwerk_core_wheel() {
  [ -n "${BUNDLED_WHEELS_DIR:-}" ] && [ -d "${BUNDLED_WHEELS_DIR}" ] || return 1
  for _wheel in "${BUNDLED_WHEELS_DIR}"/stemwerk_core-*.whl; do
    [ -f "${_wheel}" ] || continue
    printf "%s\n" "${_wheel}"
    return 0
  done
  return 1
}

bundled_models_dir() {
  [ -d "${BUNDLED_PAYLOAD_DIR}/models" ] || return 1
  printf "%s\n" "${BUNDLED_PAYLOAD_DIR}/models"
}

bundled_drumsep_dir() {
  [ -d "${BUNDLED_PAYLOAD_DIR}/drumsep" ] || return 1
  printf "%s\n" "${BUNDLED_PAYLOAD_DIR}/drumsep"
}

copy_bundled_models_to_cache() {
  _src="$1"
  _dest="${2:-$(model_cache_dir)}"
  [ -n "${_src}" ] && [ -d "${_src}" ] || return 1
  mkdir -p "${_dest}" >/dev/null 2>&1 || return 1
  cp -R "${_src}/." "${_dest}/" >> "${LOG_FILE}" 2>&1 || return 1
}

install_with_optional_bundled_wheels() {
  _py="$1"
  shift
  if [ -n "${BUNDLED_WHEELS_DIR:-}" ] && [ -d "${BUNDLED_WHEELS_DIR}" ]; then
    MACOS_BUNDLED_WHEELHOUSE_STATUS="ok"
    "${_py}" -m pip install --no-index --find-links "${BUNDLED_WHEELS_DIR}" "$@"
    return $?
  fi
  "${_py}" -m pip install "$@"
}

command_path() {
  _cmd="$1"
  command -v "${_cmd}" 2>/dev/null | while IFS= read -r _line; do
    case "${_line}" in
      /*)
        if [ -x "${_line}" ]; then
          printf "%s\n" "${_line}"
          exit 0
        fi
        ;;
    esac
  done
}

model_cache_dir() {
  printf "%s/Library/Application Support/STEMwerk/models\n" "${HOME:-/tmp}"
}

ready_to_go_state_file() {
  printf "%s/state/ready_to_go.env\n" "${RUNTIME_BASE}"
}

verify_core_model_cache() {
  _model_dir="${1:-$(model_cache_dir)}"
  _fast="missing"
  _quality="missing"
  _sixstem="missing"
  [ -f "${_model_dir}/htdemucs.yaml" ] && [ -f "${_model_dir}/955717e8-8726e21a.th" ] && _fast="ok"
  [ -f "${_model_dir}/htdemucs_ft.yaml" ] \
    && [ -f "${_model_dir}/f7e0c4bc-ba3fe64a.th" ] \
    && [ -f "${_model_dir}/d12395a8-e57c48e6.th" ] \
    && [ -f "${_model_dir}/92cfc3b6-ef3bcb9c.th" ] \
    && [ -f "${_model_dir}/04573f0d-f3cf25b2.th" ] && _quality="ok"
  [ -f "${_model_dir}/htdemucs_6s.yaml" ] && [ -f "${_model_dir}/5c90dfd2-34c22ccb.th" ] && _sixstem="ok"
  printf "model_dir=%s\nfast=%s\nquality=%s\nsixstem=%s\n" "${_model_dir}" "${_fast}" "${_quality}" "${_sixstem}"
}

ensure_core_model_cache() {
  _py="$1"
  _model_dir="${2:-$(model_cache_dir)}"
  [ -n "${_py}" ] && [ -x "${_py}" ] || return 1
  mkdir -p "${_model_dir}" >/dev/null 2>&1 || return 1
  _status="$(verify_core_model_cache "${_model_dir}")"
  case "${_status}" in
    *$'\nfast=ok'$'\n'*$'quality=ok'$'\n'*$'sixstem=ok'*|*fast=ok*quality=ok*sixstem=ok*)
      log "Core model cache already present: ${_model_dir}"
      return 0
      ;;
  esac
  _prefetch_path="${PATH:-}"
  _prefetch_ffmpeg_path="${FFMPEG:-}"
  if [ -n "${_prefetch_ffmpeg_path}" ] && [ -x "${_prefetch_ffmpeg_path}" ]; then
    _prefetch_ffmpeg_dir="$(CDPATH= cd -- "$(dirname "${_prefetch_ffmpeg_path}")" 2>/dev/null && pwd -P || dirname "${_prefetch_ffmpeg_path}")"
    _prefetch_path="${_prefetch_ffmpeg_dir}:${_prefetch_path}"
    log "core_model_prefetch_ffmpeg_path=${_prefetch_ffmpeg_path}"
    log "core_model_prefetch_path_prefix=${_prefetch_ffmpeg_dir}"
  else
    _prefetch_ffmpeg_path=""
    log "core_model_prefetch_ffmpeg_path=missing"
    log "core_model_prefetch_path_prefix=none"
  fi
  PATH="${_prefetch_path}" FFMPEG_PATH="${_prefetch_ffmpeg_path}" STEMWERK_FFMPEG_PATH="${_prefetch_ffmpeg_path}" IMAGEIO_FFMPEG_EXE="${_prefetch_ffmpeg_path}" "${_py}" - <<PY >> "${LOG_FILE}" 2>&1
from audio_separator.separator import Separator
from stemwerk_core.models import resolve_audio_separator_model_id

model_dir = r"${_model_dir}"
for model_name in ("htdemucs", "htdemucs_ft", "htdemucs_6s"):
    sep = Separator(model_file_dir=model_dir, output_dir=".", output_format="wav")
    sep.load_model(resolve_audio_separator_model_id(model_name))
print("STEMWERK_CORE_MODEL_PREFETCH ok")
PY
  [ $? -eq 0 ] || return 1
  _status="$(verify_core_model_cache "${_model_dir}")"
  case "${_status}" in
    *$'\nfast=ok'$'\n'*$'quality=ok'$'\n'*$'sixstem=ok'*|*fast=ok*quality=ok*sixstem=ok*) return 0 ;;
  esac
  return 1
}

ensure_drumsep_assets() {
  _py="$1"
  _model_dir="${2:-$(model_cache_dir)}"
  [ -n "${_py}" ] && [ -x "${_py}" ] || return 1
  mkdir -p "${_model_dir}" >/dev/null 2>&1 || return 1
  _detail_file="$(mktemp "${TMPDIR:-/tmp}/stemwerk-drumsep-prefetch.XXXXXX")" || return 1
  STEMWERK_DRUMSEP_DETAIL_FILE="${_detail_file}" "${_py}" - <<PY >> "${LOG_FILE}" 2>&1
import importlib.util
import os
from pathlib import Path

script_path = Path(r"${SCRIPT_DIR}") / "audio_separator_process.py"
spec = importlib.util.spec_from_file_location("stemwerk_audio_separator_process_ready", script_path)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)
ok, _requested, _resolved, detail = module._direct_dks_preflight_check(
    module.DIRECT_DKS_MODEL_ALIAS,
    Path(r"${_model_dir}"),
)
detail_path = os.environ.get("STEMWERK_DRUMSEP_DETAIL_FILE", "").strip()
if detail_path:
    Path(detail_path).write_text(str(detail or ""), encoding="utf-8")
if not ok:
    raise SystemExit(str(detail or "drumsep_prefetch_failed"))
print("STEMWERK_DRUMSEP_MODEL_PREFETCH ok")
PY
  _rc=$?
  DRUMSEP_PREFETCH_DETAIL=""
  if [ -f "${_detail_file}" ]; then
    DRUMSEP_PREFETCH_DETAIL="$(cat "${_detail_file}" 2>/dev/null || true)"
  fi
  rm -f "${_detail_file}" 2>/dev/null || true
  [ "${_rc}" -eq 0 ]
}

write_ready_to_go_state() {
  _runtime_kind="${1:-unknown}"
  _runtime_status="${2:-missing}"
  _drumsep_model_status="${3:-missing}"
  _detail="${4:-}"
  _main_runtime_status="${5:-ok}"
  _core="$(verify_core_model_cache)"
  _model_dir="$(printf "%s\n" "${_core}" | awk -F= '/^model_dir=/{print $2; exit}')"
  _fast="$(printf "%s\n" "${_core}" | awk -F= '/^fast=/{print $2; exit}')"
  _quality="$(printf "%s\n" "${_core}" | awk -F= '/^quality=/{print $2; exit}')"
  _sixstem="$(printf "%s\n" "${_core}" | awk -F= '/^sixstem=/{print $2; exit}')"
  _drumsep_status="ready"
  _dks_supported="true"
  _normal_stems_supported="false"
  if [ "${_main_runtime_status}" = "ok" ] && [ "${_fast}" = "ok" ] && [ "${_quality}" = "ok" ] && [ "${_sixstem}" = "ok" ]; then
    _normal_stems_supported="true"
  fi
  if [ "${MAC_ARCH}" = "x86_64" ] && [ "${_detail}" = "unsupported_mac_intel" ]; then
    _drumsep_status="unsupported_mac_intel"
    _dks_supported="false"
  elif [ "${_runtime_status}" = "ok" ] && [ "${_drumsep_model_status}" = "ok" ]; then
    _drumsep_status="ready"
  elif [ "${_runtime_status}" = "skipped" ] || [ "${_drumsep_model_status}" = "skipped" ]; then
    _drumsep_status="skipped"
  else
    _drumsep_status="missing"
  fi
  _ready="ok"
  if [ "${_fast}" != "ok" ] || [ "${_quality}" != "ok" ] || [ "${_sixstem}" != "ok" ]; then
    _ready="missing"
  fi
  if [ "${_drumsep_model_status}" != "ok" ] && [ "${_drumsep_model_status}" != "skipped" ]; then
    _ready="missing"
  fi
  if [ "${_runtime_status}" != "ok" ] && [ "${_runtime_status}" != "skipped" ]; then
    _ready="missing"
  fi
  if [ "${_main_runtime_status}" != "ok" ]; then
    _ready="missing"
  fi
  {
    echo "READY_TO_GO_STATUS=${_ready}"
    echo "READY_TO_GO_DETAIL=${_detail}"
    echo "READY_TO_GO_LAST_CHECK_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
    echo "MAIN_RUNTIME_STATUS=${_main_runtime_status}"
    echo "CORE_MODEL_CACHE_DIR=${_model_dir}"
    echo "CORE_MODEL_FAST_STATUS=${_fast}"
    echo "CORE_MODEL_QUALITY_STATUS=${_quality}"
    echo "CORE_MODEL_6STEM_STATUS=${_sixstem}"
    echo "DRUMSEP_READY_RUNTIME=${_runtime_kind}"
    echo "DRUMSEP_READY_RUNTIME_STATUS=${_runtime_status}"
    echo "DRUMSEP_READY_MODEL_STATUS=${_drumsep_model_status}"
    echo "DRUMSEP_STATUS=${_drumsep_status}"
    echo "DKS_SUPPORTED=${_dks_supported}"
    echo "NORMAL_STEMS_SUPPORTED=${_normal_stems_supported}"
  } > "$(ready_to_go_state_file)"
}

get_python_version() {
  if [ -z "${1:-}" ] || [ ! -x "$1" ]; then
    return 1
  fi
  "$1" -c 'import sys; print("{}.{}.{}".format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))' 2>/dev/null | awk 'NR==1 { print; exit }'
}

accept_python_version() {
  _version_text=$(get_python_version "$1") || return 1
  _major=$(printf "%s" "${_version_text}" | awk -F. 'NR==1 { print $1 }')
  _minor=$(printf "%s" "${_version_text}" | awk -F. 'NR==1 { print $2 }')
  [ "${_major}" = "3" ] || return 1
  case "${_minor}" in
    10|11|12) return 0 ;;
  esac
  return 1
}

probe_existing_runtime_policy() {
  _venv_py="$1"
  [ -x "${_venv_py}" ] || return 2
  "${_venv_py}" - <<PY 2>/dev/null
import importlib
import platform
import sys
from importlib.metadata import PackageNotFoundError, version

expected = {
    "audio-separator": "${PINNED_AUDIO_SEPARATOR_VERSION}",
    "numpy": "${PINNED_NUMPY_VERSION}",
    "numba": "${PINNED_NUMBA_VERSION}",
    "llvmlite": "${PINNED_LLVMLITE_VERSION}",
    "torch": "${PINNED_TORCH_VERSION}",
    "torchaudio": "${PINNED_TORCHAUDIO_VERSION}",
    "samplerate": "${PINNED_SAMPLERATE_VERSION}",
}
imports = {
    "audio-separator": "audio_separator",
    "numpy": "numpy",
    "numba": "numba",
    "llvmlite": "llvmlite",
    "torch": "torch",
    "torchaudio": "torchaudio",
    "samplerate": "samplerate",
}

def core(value):
    return str(value).split("+", 1)[0]

observed = {
    "python": f"{sys.version_info.major}.{sys.version_info.minor}",
    "architecture": platform.machine(),
}
broken = []
for distribution, module in imports.items():
    try:
        observed[distribution] = version(distribution)
    except PackageNotFoundError:
        observed[distribution] = "missing"
        broken.append(distribution + ":missing")
        continue
    except Exception as exc:
        observed[distribution] = "metadata_error"
        broken.append(distribution + ":metadata_error:" + str(exc))
        continue
    try:
        importlib.import_module(module)
    except Exception as exc:
        broken.append(distribution + ":import_error:" + str(exc))

mismatch = []
if observed["python"] != "${PINNED_PYTHON_MAJOR_MINOR}":
    mismatch.append("python:" + observed["python"])
if observed["architecture"] != "${MAC_ARCH}":
    mismatch.append("architecture:" + observed["architecture"])
for distribution, wanted in expected.items():
    if core(observed.get(distribution, "missing")) != wanted:
        mismatch.append(distribution + ":" + observed.get(distribution, "missing"))

summary = ";".join(
    key + "=" + str(observed.get(key, "missing")).replace("\n", " ")
    for key in ("python", "architecture", "audio-separator", "numpy", "numba", "llvmlite", "torch", "torchaudio", "samplerate")
)
if broken:
    print("broken|" + summary + ";errors=" + ",".join(item.replace("\n", " ") for item in broken))
elif mismatch:
    print("mismatch|" + summary + ";different=" + ",".join(mismatch))
else:
    print("match|" + summary)
PY
}

verify_audio_separator_runtime_deps() {
  if [ -z "${VENV_PY}" ] || [ ! -x "${VENV_PY}" ]; then
    AUDIO_SEPARATOR_IMPORT="failed"
    AUDIO_SEPARATOR_DEPS_COMPLETE="no"
    BACKEND_DEPS_COMPLETE="no"
    BACKEND_DEPS_REASON="${BACKEND_DEPS_REASON:-missing_venv_python}"
    return 1
  fi
  _probe="$("${VENV_PY}" - <<'PY' 2>/dev/null || true
import importlib
errors = []
try:
    import audio_separator  # noqa: F401
except Exception as exc:
    errors.append("audio_separator:" + str(exc))
for name in (
    "beartype",
    "diffq",
    "einops",
    "julius",
    "librosa",
    "llvmlite",
    "ml_collections",
    "onnx",
    "onnx2torch",
    "pydub",
    "requests",
    "resampy",
    "rotary_embedding_torch",
    "samplerate",
    "scipy",
    "six",
    "tqdm",
    "yaml",
):
    try:
        importlib.import_module(name)
    except Exception as exc:
        errors.append(name + ":" + str(exc))
if errors:
    print("missing|" + ";".join(errors))
else:
    print("ok")
PY
)"
  case "${_probe}" in
    ok)
      AUDIO_SEPARATOR_IMPORT="ok"
      AUDIO_SEPARATOR_DEPS_COMPLETE="yes"
      BACKEND_DEPS_COMPLETE="yes"
      BACKEND_DEPS_REASON=""
      return 0
      ;;
  esac
  AUDIO_SEPARATOR_IMPORT="failed"
  AUDIO_SEPARATOR_DEPS_COMPLETE="no"
  BACKEND_DEPS_COMPLETE="no"
  case "${_probe}" in
    *samplerate*incompatible*architecture*|*samplerate*incompatible*arch*)
      if [ "${MAC_ARCH}" = "arm64" ]; then
        BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild"
      else
        BACKEND_DEPS_REASON="${BACKEND_DEPS_REASON:-audio_separator_deps_missing}"
      fi
      ;;
    *)
      BACKEND_DEPS_REASON="${BACKEND_DEPS_REASON:-audio_separator_deps_missing}"
      ;;
  esac
  log "audio-separator dependency verification failed: ${_probe}"
  return 1
}

probe_samplerate_runtime() {
  if [ -z "${VENV_PY}" ] || [ ! -x "${VENV_PY}" ]; then
    return 1
  fi
  "${VENV_PY}" - <<'PY' 2>/dev/null || true
import importlib
import os
import platform
import subprocess
import sysconfig

def emit(name, value):
    print(f"{name}={value if value is not None else ''}")

emit("platform_machine", platform.machine())
emit("sysconfig_platform", sysconfig.get_platform())

try:
    samplerate = importlib.import_module("samplerate")
except Exception as exc:
    emit("samplerate_import", "failed")
    emit("samplerate_error", str(exc).replace("\n", " "))
    raise SystemExit(0)

emit("samplerate_import", "ok")
emit("samplerate_version", getattr(samplerate, "__version__", ""))
emit("samplerate_module", getattr(samplerate, "__file__", ""))

base = os.path.dirname(getattr(samplerate, "__file__", "") or "")
dylib = os.path.join(base, "_samplerate_data", "libsamplerate.dylib")
emit("samplerate_dylib", dylib)
if os.path.isfile(dylib):
    emit("samplerate_dylib_exists", "yes")
    try:
        out = subprocess.check_output(["file", dylib], text=True, stderr=subprocess.STDOUT).strip()
    except Exception as exc:
        out = f"file_error:{exc}"
    emit("samplerate_dylib_file", out)
else:
    emit("samplerate_dylib_exists", "no")
PY
}

repair_samplerate_if_arch_mismatch() {
  _guard_phase="${1:-unspecified}"
  [ "${MAC_ARCH}" = "arm64" ] || return 0
  [ -n "${VENV_PY}" ] || return 0
  [ -x "${VENV_PY}" ] || return 0

  _guard_script="${SCRIPT_DIR}/_internal/stemwerk_samplerate_guard.py"
  log "samplerate_guard_start phase=${_guard_phase}"
  log "samplerate_guard_script_path=${_guard_script}"
  if [ ! -f "${_guard_script}" ]; then
    log "samplerate guard script missing: ${_guard_script}"
    BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild"
    return 1
  fi

  if [ -n "${BUNDLED_WHEELS_DIR:-}" ] && [ -d "${BUNDLED_WHEELS_DIR}" ]; then
    _guard_out="$("${VENV_PY}" "${_guard_script}" --python "${VENV_PY}" --find-links "${BUNDLED_WHEELS_DIR}" 2>&1)"
  else
    _guard_out="$("${VENV_PY}" "${_guard_script}" --python "${VENV_PY}" 2>&1)"
  fi
  _guard_rc=$?
  [ -n "${_guard_out}" ] && printf "%s\n" "${_guard_out}" >> "${LOG_FILE}"
  _guard_before_samplerate_import="unknown"
  _guard_after_samplerate_import="unknown"
  _guard_before_samplerate_version=""
  _guard_after_samplerate_version=""
  _guard_before_audio_separator_import="not_checked"
  _guard_after_audio_separator_import="not_checked"
  _guard_repair_attempted="no"

  while IFS= read -r _line; do
    case "${_line}" in
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_import=*) _guard_before_samplerate_import="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_import=*) _guard_after_samplerate_import="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_version=*) SAMPLERATE_VERSION="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_version=*) SAMPLERATE_VERSION="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_version=*) _guard_before_samplerate_version="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_version=*) _guard_after_samplerate_version="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_audio_separator_import=*) _guard_before_audio_separator_import="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_audio_separator_import=*) _guard_after_audio_separator_import="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_module=*) SAMPLERATE_MODULE_PATH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_module=*) SAMPLERATE_MODULE_PATH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_dylib=*) SAMPLERATE_DYLIB_PATH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_dylib=*) SAMPLERATE_DYLIB_PATH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_samplerate_dylib_file=*) SAMPLERATE_DYLIB_ARCH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_samplerate_dylib_file=*) SAMPLERATE_DYLIB_ARCH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_platform_machine=*) SAMPLERATE_PLATFORM_MACHINE="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_platform_machine=*) SAMPLERATE_PLATFORM_MACHINE="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ before_sysconfig_platform=*) SAMPLERATE_SYSCONFIG_PLATFORM="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ after_sysconfig_platform=*) SAMPLERATE_SYSCONFIG_PLATFORM="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ repair_attempted=*) _guard_repair_attempted="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ arch_match=*) SAMPLERATE_ARCH_MATCH="${_line#*=}" ;;
      STEMWERK_SAMPLERATE_GUARD\ error=samplerate_reinstall_failed) BACKEND_DEPS_REASON="samplerate_reinstall_failed" ;;
      STEMWERK_SAMPLERATE_GUARD\ error=samplerate_arch_mismatch_requires_runtime_rebuild) BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild" ;;
    esac
  done <<EOF
${_guard_out}
EOF
  if [ "${_guard_repair_attempted}" = "yes" ]; then
    SAMPLERATE_REPAIR_ATTEMPTED="yes"
  elif [ "${SAMPLERATE_REPAIR_ATTEMPTED}" != "yes" ]; then
    SAMPLERATE_REPAIR_ATTEMPTED="no"
  fi
  log "samplerate_guard_before_samplerate_import=${_guard_before_samplerate_import}"
  log "samplerate_guard_after_samplerate_import=${_guard_after_samplerate_import}"
  log "samplerate_guard_before_samplerate_version=${_guard_before_samplerate_version}"
  log "samplerate_guard_after_samplerate_version=${_guard_after_samplerate_version}"
  log "samplerate_guard_before_audio_separator_import=${_guard_before_audio_separator_import}"
  log "samplerate_guard_after_audio_separator_import=${_guard_after_audio_separator_import}"
  log "samplerate_guard_repair_attempted=${SAMPLERATE_REPAIR_ATTEMPTED}"

  if [ "${_guard_rc}" -ne 0 ]; then
    if [ -z "${BACKEND_DEPS_REASON}" ]; then
      BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild"
    fi
    return 1
  fi
  BACKEND_DEPS_REASON=""
  return 0
}

log_python_candidate() {
  _candidate_path="$1"
  _candidate_version="$2"
  _candidate_action="$3"
  _candidate_reason="$4"
  if [ -n "${_candidate_reason}" ]; then
    log "Python candidate ${_candidate_action}: ${_candidate_path} (version ${_candidate_version}; ${_candidate_reason})"
  else
    log "Python candidate ${_candidate_action}: ${_candidate_path} (version ${_candidate_version})"
  fi
}

log_macos_diagnostics() {
  log "=== macOS runtime diagnostics ==="
  log "uname -m: $(uname -m 2>/dev/null || echo unknown)"
  if command -v sw_vers >/dev/null 2>&1; then
    log "sw_vers productVersion: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    log "sw_vers buildVersion: $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  fi
  if [ -n "${PYTHON}" ] && [ -x "${PYTHON}" ]; then
    log "selected python path: ${PYTHON}"
    log "selected python version: ${SELECTED_PYTHON_VERSION:-unknown}"
    "${PYTHON}" - <<'PY' >> "${LOG_FILE}" 2>&1 || true
import platform, sys
print("python sys.version:", sys.version.replace("\n", " "))
print("python platform.machine:", platform.machine())
print("python platform.platform:", platform.platform())
PY
  fi
  if [ "$(uname -m)" = "arm64" ]; then
    log "expected backend path: Apple Silicon (MPS-capable when available)"
  else
    log "expected backend path: Intel macOS CPU-only fallback (no MPS)"
  fi
  log "=== end diagnostics ==="
}

remove_incompatible_venv() {
  if [ -d "${RUNTIME_BASE}/.venv" ]; then
    log "Removing incompatible virtual environment: ${RUNTIME_BASE}/.venv"
    rm -rf "${RUNTIME_BASE}/.venv"
  fi
}

venv_torch_requires_rebuild() {
  _venv_py="$1"
  [ -x "${_venv_py}" ] || return 1
  _probe="$("${_venv_py}" - <<'PY' 2>/dev/null || true
try:
    import torch
    ver = getattr(torch, "__version__", "")
    core = ver.split("+", 1)[0]
    parts = core.split(".")
    major = int(parts[0])
    minor = int(parts[1])
    if major > 2 or (major == 2 and minor >= 6):
        print("rebuild|" + ver)
    else:
        print("ok|" + ver)
except Exception:
    print("missing")
PY
)"
  case "${_probe}" in
    rebuild\|*)
      log "Existing venv has incompatible torch ${_probe#rebuild|}; rebuilding .venv for audio-separator 0.23.0 compatibility"
      return 0
      ;;
    ok\|*)
      log "Existing venv torch is compatible: ${_probe#ok|}"
      ;;
  esac
  return 1
}

pinned_torch_stack_already_ok() {
  _venv_py="$1"
  [ -x "${_venv_py}" ] || return 1
  _probe="$("${_venv_py}" - <<PY 2>/dev/null || true
from importlib.metadata import PackageNotFoundError, version

expected = {
    "numpy": "${PINNED_NUMPY_VERSION}",
    "torch": "${PINNED_TORCH_VERSION}",
    "torchvision": "${PINNED_TORCHVISION_VERSION}",
    "torchaudio": "${PINNED_TORCHAUDIO_VERSION}",
}

def core(ver):
    return str(ver).split("+", 1)[0]

missing = []
bad = []
for name, want in expected.items():
    try:
        got = version(name)
    except PackageNotFoundError:
        missing.append(name)
        continue
    if core(got) != want:
        bad.append(f"{name}:{got}")

if missing or bad:
    print("bad|missing=" + ",".join(missing) + ";bad=" + ",".join(bad))
else:
    print("ok")
PY
)"
  case "${_probe}" in
    ok) return 0 ;;
    *) log "Pinned torch stack needs install: ${_probe}" ;;
  esac
  return 1
}

install_pinned_torch_stack() {
  TORCH_PIN_APPLIED="1"
  log "torch pin applied: true (${PINNED_TORCH_STACK_LABEL})"
  "${VENV_PY}" - <<'PY' >> "${LOG_FILE}" 2>&1 || true
from importlib.metadata import PackageNotFoundError, version
for name in ("torch", "torchvision", "torchaudio"):
    try:
        print(f"pre_pin_{name}={version(name)}")
    except PackageNotFoundError:
        print(f"pre_pin_{name}=missing")
PY
  if pinned_torch_stack_already_ok "${VENV_PY}"; then
    log "Pinned torch stack already satisfies ${PINNED_TORCH_STACK_LABEL}; skipping reinstall"
    return 0
  fi
  log "Installing pinned torch stack (${PINNED_TORCH_STACK_LABEL}): torch==${PINNED_TORCH_VERSION} torchvision==${PINNED_TORCHVISION_VERSION} torchaudio==${PINNED_TORCHAUDIO_VERSION}"
  "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
  install_with_optional_bundled_wheels "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir \
    "numpy==${PINNED_NUMPY_VERSION}" \
    "torch==${PINNED_TORCH_VERSION}" \
    "torchvision==${PINNED_TORCHVISION_VERSION}" \
    "torchaudio==${PINNED_TORCHAUDIO_VERSION}" >> "${LOG_FILE}" 2>&1
  install_with_optional_bundled_wheels "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir \
    "numpy==${PINNED_NUMPY_VERSION}" >> "${LOG_FILE}" 2>&1
}

assert_pinned_torch_stack() {
  _venv_py="$1"
  _probe_output="$("${_venv_py}" - <<PY 2>&1
from importlib.metadata import PackageNotFoundError, version

expected_numpy = "${PINNED_NUMPY_VERSION}"
expected_torch = "${PINNED_TORCH_VERSION}"
expected_torchvision = "${PINNED_TORCHVISION_VERSION}"
expected_torchaudio = "${PINNED_TORCHAUDIO_VERSION}"
expected_audio_separator = "${PINNED_AUDIO_SEPARATOR_VERSION}"
expected_profile = "${PINNED_TORCH_STACK_LABEL}"
mac_arch = "${MAC_ARCH}"

def core(ver):
    return str(ver).split("+", 1)[0]

details = {}
failures = []

def record(name, value):
    details[name] = str(value)

def add_failure(name, expected=None, actual=None):
    if expected is None:
        failures.append(str(name))
    else:
        failures.append(f"{name}: expected {expected}, got {actual}")

def import_module_version(import_name, detail_name=None):
    try:
        module = __import__(import_name)
    except Exception as exc:
        record(detail_name or import_name, f"import_error:{exc}")
        failures.append(f"{import_name} import failed: {exc}")
        return None, ""
    module_ver = getattr(module, "__version__", "")
    record(detail_name or import_name, module_ver or "imported")
    return module, module_ver

def distribution_version(dist_name, detail_name=None):
    try:
        dist_ver = version(dist_name)
    except PackageNotFoundError:
        record(detail_name or dist_name, "missing")
        failures.append(f"{dist_name} distribution missing")
        return ""
    except Exception as exc:
        record(detail_name or dist_name, f"metadata_error:{exc}")
        failures.append(f"{dist_name} metadata lookup failed: {exc}")
        return ""
    record(detail_name or dist_name, dist_ver)
    return dist_ver

try:
    _, numpy_ver = import_module_version("numpy")
    _, numba_ver = import_module_version("numba")
    _, llvmlite_ver = import_module_version("llvmlite")
    torch_mod, torch_ver = import_module_version("torch")
    _, torchvision_ver = import_module_version("torchvision")
    _, torchaudio_ver = import_module_version("torchaudio")
    audio_separator_ver = distribution_version("audio-separator")
    _, onnxruntime_ver = import_module_version("onnxruntime")

    mps_backend = getattr(getattr(torch_mod, "backends", None), "mps", None) if torch_mod is not None else None
    if mps_backend is not None:
        try:
            record("mps_built", mps_backend.is_built())
        except Exception as exc:
            record("mps_built", f"error:{exc}")
        try:
            record("mps_available", mps_backend.is_available())
        except Exception as exc:
            record("mps_available", f"error:{exc}")
    else:
        record("mps_built", "unsupported")
        record("mps_available", "unsupported")
    record("mac_arch", mac_arch)

    if core(numpy_ver) != expected_numpy:
        add_failure("numpy", expected_numpy, numpy_ver or "missing")
    if core(torch_ver) != expected_torch:
        add_failure("torch", expected_torch, torch_ver or "missing")
    if core(torchvision_ver) != expected_torchvision:
        add_failure("torchvision", expected_torchvision, torchvision_ver or "missing")
    if core(torchaudio_ver) != expected_torchaudio:
        add_failure("torchaudio", expected_torchaudio, torchaudio_ver or "missing")
    if core(audio_separator_ver) != expected_audio_separator:
        add_failure("audio-separator", expected_audio_separator, audio_separator_ver or "missing")

    ordered_names = (
        "mac_arch",
        "numpy",
        "numba",
        "llvmlite",
        "torch",
        "torchvision",
        "torchaudio",
        "audio-separator",
        "onnxruntime",
        "mps_built",
        "mps_available",
    )
    summary = "; ".join(f"{name}={details.get(name, 'missing')}" for name in ordered_names)
    if failures:
        print("bad|profile=" + expected_profile + "; failures=" + "; ".join(failures) + "; " + summary)
    else:
        print("ok|profile=" + expected_profile + "; " + summary)
except Exception as exc:
    print("error|runtime_probe|" + str(exc))
PY
)"
  _probe_rc=$?
  _probe=$(printf "%s\n" "${_probe_output}" | tail -n 1)
  if [ -z "${_probe}" ] && [ -n "${_probe_output}" ]; then
    _probe="${_probe_output}"
  fi
  if [ -n "${_probe_output}" ] && [ "${_probe_output}" != "${_probe}" ]; then
    log "Pinned runtime assertion probe emitted auxiliary output:"
    printf "%s\n" "${_probe_output}" | while IFS= read -r _line; do
      log "  ${_line}"
    done
  fi
  case "${_probe}" in
    ok\|*)
      log "Pinned runtime assertion passed: ${_probe#ok|}"
      return 0
      ;;
  esac
  if [ -z "${_probe}" ]; then
    _probe="error|runtime_probe|no probe output (python exit ${_probe_rc})"
  fi
  log "Pinned runtime assertion failed: ${_probe}"
  printf "STEMwerk bootstrap failed: pinned runtime assertion failed (%s): %s\n" "${PINNED_TORCH_STACK_LABEL}" "${_probe}" >&2
  return 1
}

log_final_dependency_versions() {
  _venv_py="$1"
  [ -x "${_venv_py}" ] || return 0
  log "=== final dependency versions ==="
  log "torch_stack_profile=${PINNED_TORCH_STACK_LABEL}"
  log "torch_pin_applied=${TORCH_PIN_APPLIED}"
  "${_venv_py}" - <<'PY' >> "${LOG_FILE}" 2>&1 || true
from importlib.metadata import PackageNotFoundError, version

for name in ("torch", "torchvision", "torchaudio", "audio-separator", "onnxruntime", "samplerate"):
    try:
        print(f"{name}={version(name)}")
    except PackageNotFoundError:
        print(f"{name}=missing")
for name in ("numpy", "numba", "llvmlite"):
    try:
        print(f"{name}={version(name)}")
    except PackageNotFoundError:
        print(f"{name}=missing")
PY
  log "=== end final dependency versions ==="
}

evaluate_python_candidate() {
  _resolved_path=$(resolve_python_candidate "$1") || return 1
  case "${SEEN_PYTHON_PATHS}" in
    *"|${_resolved_path}|"*)
      return 1
      ;;
  esac
  SEEN_PYTHON_PATHS="${SEEN_PYTHON_PATHS}${_resolved_path}|"

  _version_text=$(get_python_version "${_resolved_path}" || true)
  if [ -z "${_version_text}" ]; then
    log_python_candidate "${_resolved_path}" "unknown" "rejected" "version_probe_failed"
    return 1
  fi
  if accept_python_version "${_resolved_path}"; then
    log_python_candidate "${_resolved_path}" "${_version_text}" "accepted" "supported"
    PYTHON="${_resolved_path}"
    SELECTED_PYTHON_VERSION="${_version_text}"
    return 0
  fi

  log_python_candidate "${_resolved_path}" "${_version_text}" "rejected" "unsupported_on_macos"
  if [ -z "${FIRST_UNSUPPORTED_PYTHON_PATH}" ]; then
    FIRST_UNSUPPORTED_PYTHON_PATH="${_resolved_path}"
    FIRST_UNSUPPORTED_PYTHON_VERSION="${_version_text}"
    SYSTEM_PYTHON_PATH="${_resolved_path}"
    SYSTEM_PYTHON_VERSION="${_version_text}"
  fi
  return 1
}

find_managed_python() {
  for p in \
    "${RUNTIME_BASE}/python/bin/python3.12" \
    "${RUNTIME_BASE}/python/bin/python3.11" \
    "${RUNTIME_BASE}/python/bin/python3.10" \
    "${RUNTIME_BASE}/python/bin/python3" \
    "${RUNTIME_BASE}/python/python3.12" \
    "${RUNTIME_BASE}/python/python3.11" \
    "${RUNTIME_BASE}/python/python3.10" \
    "${RUNTIME_BASE}/python/python3"
  do
    if evaluate_python_candidate "${p}"; then
      return 0
    fi
  done
  return 1
}

find_managed_python_from_dir() {
  _base="$1"
  for p in \
    "${_base}/bin/python3.12" \
    "${_base}/bin/python3.11" \
    "${_base}/bin/python3.10" \
    "${_base}/bin/python3" \
    "${_base}/python3.12" \
    "${_base}/python3.11" \
    "${_base}/python3.10" \
    "${_base}/python3"
  do
    if evaluate_python_candidate "${p}"; then
      return 0
    fi
  done
  return 1
}

install_managed_python_runtime() {
  log "Attempting STEMwerk-managed Python runtime acquisition"
  for src in \
    "${STEMWERK_MANAGED_PYTHON_SOURCE:-}" \
    "${SCRIPT_DIR}/python" \
    "${SCRIPT_DIR}/runtime/python" \
    "${SCRIPT_DIR}/_runtime/python" \
    "${SCRIPT_DIR}/../runtime/python"
  do
    if [ -n "${src}" ] && [ -d "${src}" ]; then
      log "Found local managed Python source: ${src}"
      rm -rf "${RUNTIME_BASE}/python.tmp"
      mkdir -p "${RUNTIME_BASE}/python.tmp" || return 1
      if cp -R "${src}/." "${RUNTIME_BASE}/python.tmp/" >> "${LOG_FILE}" 2>&1; then
        if find_managed_python_from_dir "${RUNTIME_BASE}/python.tmp"; then
          rm -rf "${RUNTIME_BASE}/python"
          mv "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python" || return 1
          log "Installed STEMwerk-managed Python runtime under ${RUNTIME_BASE}/python"
          return 0
        fi
      fi
      rm -rf "${RUNTIME_BASE}/python.tmp"
    fi
  done
  log "No local STEMwerk-managed Python runtime payload is available"
  return 1
}

if [ -f "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh" ]; then
  . "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh"
fi

write_state() {
  if [ -n "${STATE_FILE}" ]; then
    {
      echo "STATUS=${STATUS}"
      [ -n "${STATUS_REASON}" ] && echo "STATUS_REASON=${STATUS_REASON}"
      [ -n "${STEP_INDEX}" ] && echo "STEP_INDEX=${STEP_INDEX}"
      [ -n "${STEP_TOTAL}" ] && echo "STEP_TOTAL=${STEP_TOTAL}"
      [ -n "${STEP_LABEL}" ] && echo "STEP_LABEL=${STEP_LABEL}"
      [ -n "${PROFILE}" ] && echo "PROFILE=${PROFILE}"
      [ -n "${BACKEND}" ] && echo "BACKEND=${BACKEND}"
      [ -n "${BACKEND_REASON}" ] && echo "BACKEND_REASON=${BACKEND_REASON}"
      echo "AUDIO_SEPARATOR_IMPORT=${AUDIO_SEPARATOR_IMPORT}"
      echo "AUDIO_SEPARATOR_DEPS_COMPLETE=${AUDIO_SEPARATOR_DEPS_COMPLETE}"
      echo "BACKEND_DEPS_COMPLETE=${BACKEND_DEPS_COMPLETE}"
      [ -n "${BACKEND_DEPS_REASON}" ] && echo "BACKEND_DEPS_REASON=${BACKEND_DEPS_REASON}"
      [ -n "${SAMPLERATE_VERSION}" ] && echo "SAMPLERATE_VERSION=${SAMPLERATE_VERSION}"
      [ -n "${SAMPLERATE_MODULE_PATH}" ] && echo "SAMPLERATE_MODULE_PATH=${SAMPLERATE_MODULE_PATH}"
      [ -n "${SAMPLERATE_DYLIB_PATH}" ] && echo "SAMPLERATE_DYLIB_PATH=${SAMPLERATE_DYLIB_PATH}"
      [ -n "${SAMPLERATE_DYLIB_ARCH}" ] && echo "SAMPLERATE_DYLIB_ARCH=${SAMPLERATE_DYLIB_ARCH}"
      [ -n "${SAMPLERATE_PLATFORM_MACHINE}" ] && echo "SAMPLERATE_PLATFORM_MACHINE=${SAMPLERATE_PLATFORM_MACHINE}"
      [ -n "${SAMPLERATE_SYSCONFIG_PLATFORM}" ] && echo "SAMPLERATE_SYSCONFIG_PLATFORM=${SAMPLERATE_SYSCONFIG_PLATFORM}"
      [ -n "${SAMPLERATE_ARCH_MATCH}" ] && echo "SAMPLERATE_ARCH_MATCH=${SAMPLERATE_ARCH_MATCH}"
      [ -n "${SAMPLERATE_REPAIR_ATTEMPTED}" ] && echo "SAMPLERATE_REPAIR_ATTEMPTED=${SAMPLERATE_REPAIR_ATTEMPTED}"
      echo "BUILD_TOOLS_MISSING=${BUILD_TOOLS_MISSING}"
      if [ -n "${PYTHON}" ]; then
        echo "SUPPORTED_PYTHON_FOUND=yes"
        [ -n "${SELECTED_PYTHON_VERSION}" ] && echo "DETECTED_PYTHON_VERSION=${SELECTED_PYTHON_VERSION}"
        echo "DETECTED_PYTHON_PATH=${PYTHON}"
      else
        echo "SUPPORTED_PYTHON_FOUND=no"
        [ -n "${FIRST_UNSUPPORTED_PYTHON_VERSION}" ] && echo "DETECTED_PYTHON_VERSION=${FIRST_UNSUPPORTED_PYTHON_VERSION}"
        [ -n "${FIRST_UNSUPPORTED_PYTHON_PATH}" ] && echo "DETECTED_PYTHON_PATH=${FIRST_UNSUPPORTED_PYTHON_PATH}"
      fi
      echo "SUPPORTED_PYTHON_RANGE=3.10-3.12"
      echo "MANAGED_PYTHON_ENABLED=${MANAGED_PYTHON_ENABLED}"
      echo "MANAGED_PYTHON_STATUS=${MANAGED_PYTHON_STATUS}"
      echo "MANAGED_PYTHON_VERSION=${MANAGED_PYTHON_VERSION}"
      echo "MANAGED_PYTHON_RELEASE=${MANAGED_PYTHON_RELEASE}"
      echo "MANAGED_PYTHON_PLATFORM=${MANAGED_PYTHON_PLATFORM}"
      echo "MANAGED_PYTHON_ARCH=${MANAGED_PYTHON_ARCH}"
      echo "MANAGED_PYTHON_URL=${MANAGED_PYTHON_URL}"
      echo "MANAGED_PYTHON_SHA256_OK=${MANAGED_PYTHON_SHA256_OK}"
      echo "MANAGED_PYTHON_PATH=${MANAGED_PYTHON_PATH}"
      echo "MANAGED_PYTHON_REPLACED=${MANAGED_PYTHON_REPLACED}"
      echo "MANAGED_PYTHON_ROLLBACK=${MANAGED_PYTHON_ROLLBACK}"
      [ -n "${MANAGED_PYTHON_ERROR}" ] && echo "MANAGED_PYTHON_ERROR=${MANAGED_PYTHON_ERROR}"
      echo "SYSTEM_PYTHON_PATH=${SYSTEM_PYTHON_PATH}"
      echo "SYSTEM_PYTHON_VERSION=${SYSTEM_PYTHON_VERSION}"
      echo "SYSTEM_PYTHON_USED=${SYSTEM_PYTHON_USED}"
      echo "MACOS_BUNDLED_PAYLOAD_STATUS=${MACOS_BUNDLED_PAYLOAD_STATUS}"
      echo "MACOS_BUNDLED_FFMPEG_STATUS=${MACOS_BUNDLED_FFMPEG_STATUS}"
      echo "MACOS_BUNDLED_WHEELHOUSE_STATUS=${MACOS_BUNDLED_WHEELHOUSE_STATUS}"
      echo "MACOS_BUNDLED_MODELS_STATUS=${MACOS_BUNDLED_MODELS_STATUS}"
      echo "MACOS_BUNDLED_DRUMSEP_STATUS=${MACOS_BUNDLED_DRUMSEP_STATUS}"
      echo "MACOS_PAYLOAD_PREFLIGHT_STATUS=${MACOS_PAYLOAD_PREFLIGHT_STATUS}"
      echo "MACOS_PAYLOAD_PREFLIGHT_REASON=${MACOS_PAYLOAD_PREFLIGHT_REASON}"
      echo "MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE=${MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE}"
      echo "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=${MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED}"
      echo "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
      echo "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
      echo "MACOS_RUNTIME_POLICY_OBSERVED=${MACOS_RUNTIME_POLICY_OBSERVED}"
      echo "MACOS_RUNTIME_POLICY_MUTATION_STARTED=${MACOS_RUNTIME_POLICY_MUTATION_STARTED}"
      [ -n "${PYTHON}" ] && echo "PYTHON_PATH=${PYTHON}"
      [ -n "${VENV_PY}" ] && echo "VENV_PYTHON=${VENV_PY}"
      [ -n "${VENV_PY}" ] && echo "VENV_PYTHON_PATH=${VENV_PY}"
      [ -n "${FFMPEG}" ] && echo "FFMPEG_PATH=${FFMPEG}"
      [ -n "${STEMWERK_INSTALLER:-}" ] && echo "INSTALLER=1"
      [ -n "${RUNTIME_BASE}" ] && echo "RUNTIME_BASE=${RUNTIME_BASE}"
    } > "${STATE_FILE}"
  fi
}

set_status() {
  if [ "${STATUS}" = "ok" ]; then
    STATUS="$1"
    STATUS_REASON="$2"
    log "STATUS=${STATUS} REASON=${STATUS_REASON}"
    write_state
  fi
}

set_progress() {
  STEP_INDEX="$1"
  STEP_TOTAL="$2"
  STEP_LABEL="$3"
  log "STEP ${STEP_INDEX}/${STEP_TOTAL}: ${STEP_LABEL}"
  write_state
}

is_core_source_bundle() {
  [ -n "${1:-}" ] \
    && [ -f "$1/pyproject.toml" ] \
    && [ -f "$1/src/stemwerk_core/__init__.py" ] \
    && [ -f "$1/src/stemwerk_core/separator.py" ]
}

resolve_core_target() {
  CORE_TARGET=""
  CORE_TARGET_DESC=""
  CORE_SUPPORTS_EXTRAS=0

  _bundled_core_wheel="$(bundled_stemwerk_core_wheel || true)"
  if [ -n "${_bundled_core_wheel}" ]; then
    CORE_TARGET="${_bundled_core_wheel}"
    CORE_TARGET_DESC="bundled wheel"
    return 0
  fi

  if [ -n "${STEMWERK_CORE_PATH:-}" ] && [ -e "${STEMWERK_CORE_PATH}" ]; then
    if is_core_source_bundle "${STEMWERK_CORE_PATH}"; then
      CORE_TARGET="${STEMWERK_CORE_PATH}"
      CORE_TARGET_DESC="STEMWERK_CORE_PATH source"
      CORE_SUPPORTS_EXTRAS=1
      return 0
    fi
    log "STEMWERK_CORE_PATH is set but incomplete: ${STEMWERK_CORE_PATH}"
    log "Required: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
  fi

  CORE_BUNDLE_DIR="${STEMWERK_CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
  if [ -d "${CORE_BUNDLE_DIR}" ]; then
    if is_core_source_bundle "${CORE_BUNDLE_DIR}"; then
      CORE_TARGET="${CORE_BUNDLE_DIR}"
      CORE_TARGET_DESC="bundled source"
      CORE_SUPPORTS_EXTRAS=1
      return 0
    fi
    log "Bundled stemwerk-core source is incomplete: ${CORE_BUNDLE_DIR}"
    log "Required: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
  fi

  return 1
}

install_stemwerk_core_target() {
  _py="$1"
  _target="$2"
  _desc="$3"
  case "${_desc}" in
    *source*)
      install_with_optional_bundled_wheels "${_py}" --no-build-isolation --no-deps "${_target}"
      ;;
    *)
      install_with_optional_bundled_wheels "${_py}" --no-deps "${_target}"
      ;;
  esac
}

if [ -z "${RUNTIME_BASE}" ]; then
  echo "Missing runtime base" >&2
  exit 1
fi

log "Bootstrap started"
log "Requested mode: ${MODE}"
log "Downloaded models are kept at: $(model_cache_dir)"
MAC_ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "${MAC_ARCH}" = "x86_64" ]; then
  MACOS_CONSTRAINTS_FILE="${MACOS_INTEL_CONSTRAINTS_FILE}"
  PINNED_TORCH_VERSION="${PINNED_TORCH_VERSION_INTEL}"
  PINNED_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION_INTEL}"
  PINNED_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION_INTEL}"
  PINNED_TORCH_STACK_LABEL="Intel macOS CPU fallback"
  log "Using macOS Intel constraints: ${MACOS_CONSTRAINTS_FILE}"
else
  MACOS_CONSTRAINTS_FILE="${MACOS_ARM_CONSTRAINTS_FILE}"
  PINNED_TORCH_VERSION="${PINNED_TORCH_VERSION_ARM64}"
  PINNED_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION_ARM64}"
  PINNED_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION_ARM64}"
  PINNED_TORCH_STACK_LABEL="Apple Silicon macOS"
  log "Using macOS Apple Silicon constraints: ${MACOS_CONSTRAINTS_FILE}"
fi
log "Selected torch stack profile: ${PINNED_TORCH_STACK_LABEL}"
log "Selected torch stack versions: torch==${PINNED_TORCH_VERSION} torchvision==${PINNED_TORCHVISION_VERSION} torchaudio==${PINNED_TORCHAUDIO_VERSION}"
MACOS_BUNDLED_PAYLOAD_STATUS="missing"
MACOS_BUNDLED_FFMPEG_STATUS="missing"
MACOS_BUNDLED_WHEELHOUSE_STATUS="missing"
MACOS_BUNDLED_MODELS_STATUS="missing"
MACOS_BUNDLED_DRUMSEP_STATUS="missing"
BUNDLED_WHEELS_DIR=""

if bundled_payload_available; then
  MACOS_BUNDLED_PAYLOAD_STATUS="present"
  BUNDLED_WHEELS_DIR="$(bundled_wheels_dir || true)"
  [ -n "${BUNDLED_WHEELS_DIR}" ] && MACOS_BUNDLED_WHEELHOUSE_STATUS="present"
  [ -n "$(bundled_models_dir || true)" ] && MACOS_BUNDLED_MODELS_STATUS="present"
  [ -n "$(bundled_drumsep_dir || true)" ] && MACOS_BUNDLED_DRUMSEP_STATUS="present"
fi
log "MACOS_BUNDLED_PAYLOAD_STATUS=${MACOS_BUNDLED_PAYLOAD_STATUS}"
log "MACOS_BUNDLED_WHEELHOUSE_STATUS=${MACOS_BUNDLED_WHEELHOUSE_STATUS}"
log "MACOS_BUNDLED_MODELS_STATUS=${MACOS_BUNDLED_MODELS_STATUS}"
log "MACOS_BUNDLED_DRUMSEP_STATUS=${MACOS_BUNDLED_DRUMSEP_STATUS}"

mkdir -p "${RUNTIME_BASE}/state" "${RUNTIME_BASE}/logs"

STATUS="ok"
STATUS_REASON=""
PYTHON=""
FFMPEG=""
VENV_PY=""
# Conservative default on macOS to avoid GPU extras with limited wheel support.
PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
ONNX_PACKAGE="onnxruntime"
ONNX_FALLBACK_PACKAGE=""
if [ "$(uname -m)" = "arm64" ]; then
  ONNX_PACKAGE="onnxruntime-silicon"
  ONNX_FALLBACK_PACKAGE="onnxruntime"
fi
PROFILE="mac-cpu"
BACKEND="cpu"
BACKEND_REASON=""
STEP_INDEX=""
STEP_TOTAL="5"
STEP_LABEL=""
SELECTED_PYTHON_VERSION=""
FIRST_UNSUPPORTED_PYTHON_PATH=""
FIRST_UNSUPPORTED_PYTHON_VERSION=""
SEEN_PYTHON_PATHS="|"
MANAGED_PYTHON_ENABLED="yes"
MANAGED_PYTHON_STATUS="missing"
MANAGED_PYTHON_VERSION=""
MANAGED_PYTHON_RELEASE=""
MANAGED_PYTHON_PLATFORM=""
MANAGED_PYTHON_ARCH=""
MANAGED_PYTHON_URL=""
MANAGED_PYTHON_SHA256_OK="no"
MANAGED_PYTHON_PATH=""
MANAGED_PYTHON_ERROR=""
MANAGED_PYTHON_REPLACED="no"
MANAGED_PYTHON_ROLLBACK="no"
BACKEND_DEPS_COMPLETE="unknown"
BACKEND_DEPS_REASON=""
SAMPLERATE_VERSION=""
SAMPLERATE_MODULE_PATH=""
SAMPLERATE_DYLIB_PATH=""
SAMPLERATE_DYLIB_ARCH=""
SAMPLERATE_PLATFORM_MACHINE=""
SAMPLERATE_SYSCONFIG_PLATFORM=""
SAMPLERATE_ARCH_MATCH=""
SAMPLERATE_REPAIR_ATTEMPTED="no"
BUILD_TOOLS_MISSING="no"
AUDIO_SEPARATOR_IMPORT="unknown"
AUDIO_SEPARATOR_DEPS_COMPLETE="unknown"
SYSTEM_PYTHON_PATH=""
SYSTEM_PYTHON_VERSION=""
SYSTEM_PYTHON_USED="no"
MACOS_PAYLOAD_PREFLIGHT_STATUS="not_required"
MACOS_PAYLOAD_PREFLIGHT_REASON="not_apple_silicon"
MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE="${BUNDLED_WHEELS_DIR}"
MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="false"
MACOS_RUNTIME_POLICY_STATUS="not_checked"
MACOS_RUNTIME_POLICY_REASON=""
MACOS_RUNTIME_POLICY_OBSERVED=""
MACOS_RUNTIME_POLICY_MUTATION_STARTED="false"

if command -v managed_python_init_state >/dev/null 2>&1; then
  managed_python_init_state
fi

if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_BUNDLED_PAYLOAD_STATUS}" != "present" ]; then
  MACOS_PAYLOAD_PREFLIGHT_STATUS="failed"
  MACOS_PAYLOAD_PREFLIGHT_REASON="bundled_payload_missing_or_incomplete"
  log "Apple Silicon Repair requires a complete bundled payload; online fallback is unsupported"
  log "MACOS_PAYLOAD_PREFLIGHT_STATUS=${MACOS_PAYLOAD_PREFLIGHT_STATUS}"
  log "MACOS_PAYLOAD_PREFLIGHT_REASON=${MACOS_PAYLOAD_PREFLIGHT_REASON}"
  log "MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE=${MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE}"
  log "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false"
  set_status "deps_failed" "apple_silicon_requires_bundled_payload"
  write_ready_to_go_state "mps" "missing" "missing" "apple_silicon_requires_bundled_payload" "missing"
  write_state
  exit 1
fi

if [ "${MAC_ARCH}" = "arm64" ]; then
  MACOS_PAYLOAD_PREFLIGHT_STATUS="ok"
  MACOS_PAYLOAD_PREFLIGHT_REASON="bundled_payload_complete"
  log "MACOS_PAYLOAD_PREFLIGHT_STATUS=${MACOS_PAYLOAD_PREFLIGHT_STATUS}"
  log "MACOS_PAYLOAD_PREFLIGHT_REASON=${MACOS_PAYLOAD_PREFLIGHT_REASON}"
  log "MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE=${MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE}"
  log "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false"
fi

if [ "${MODE}" = "repair" ] && [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
  _runtime_policy_probe="$(probe_existing_runtime_policy "${RUNTIME_BASE}/.venv/bin/python" || true)"
  MACOS_RUNTIME_POLICY_OBSERVED="${_runtime_policy_probe}"
  case "${_runtime_policy_probe}" in
    match\|*)
      MACOS_RUNTIME_POLICY_STATUS="match"
      MACOS_RUNTIME_POLICY_REASON="runtime_policy_match"
      log "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
      log "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
      log "MACOS_RUNTIME_POLICY_OBSERVED=${MACOS_RUNTIME_POLICY_OBSERVED}"
      log "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false"
      ;;
    mismatch\|*)
      MACOS_RUNTIME_POLICY_STATUS="mismatch"
      MACOS_RUNTIME_POLICY_REASON="runtime_policy_mismatch_requires_rebuild"
      log "Existing managed runtime is operational but does not match the bundled 2.3.0.6 dependency policy"
      log "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
      log "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
      log "MACOS_RUNTIME_POLICY_OBSERVED=${MACOS_RUNTIME_POLICY_OBSERVED}"
      log "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false"
      set_status "repair_required" "${MACOS_RUNTIME_POLICY_REASON}"
      write_state
      exit 1
      ;;
    *)
      MACOS_RUNTIME_POLICY_STATUS="broken"
      MACOS_RUNTIME_POLICY_REASON="runtime_broken_requires_rebuild"
      log "Existing managed runtime could not pass the installed dependency policy probe"
      log "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
      log "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
      log "MACOS_RUNTIME_POLICY_OBSERVED=${MACOS_RUNTIME_POLICY_OBSERVED}"
      log "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false"
      set_status "rebuild_required" "${MACOS_RUNTIME_POLICY_REASON}"
      write_state
      exit 1
      ;;
  esac
elif [ "${MODE}" = "repair" ]; then
  MACOS_RUNTIME_POLICY_STATUS="missing"
  MACOS_RUNTIME_POLICY_REASON="missing_runtime_recovery"
  log "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
  log "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
  log "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false"
else
  MACOS_RUNTIME_POLICY_STATUS="explicit_rebuild"
  MACOS_RUNTIME_POLICY_REASON="explicit_rebuild_after_payload_preflight"
  log "MACOS_RUNTIME_POLICY_STATUS=${MACOS_RUNTIME_POLICY_STATUS}"
  log "MACOS_RUNTIME_POLICY_REASON=${MACOS_RUNTIME_POLICY_REASON}"
  log "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false"
fi

MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="true"
MACOS_RUNTIME_POLICY_MUTATION_STARTED="true"
mkdir -p "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"

if [ "${MODE}" = "rebuild-venv" ] && [ -d "${RUNTIME_BASE}/.venv" ]; then
  log "Removing requested virtual environment rebuild target: ${RUNTIME_BASE}/.venv"
  rm -rf "${RUNTIME_BASE}/.venv"
fi

set_progress "1" "${STEP_TOTAL}" "Preparing runtime"

# macOS must not blindly trust bare python3 because Homebrew/system aliases can
# move to 3.13+ while STEMwerk 2.x only supports Python 3.10-3.12.
if [ -x "${RUNTIME_BASE}/.venv/bin/python" ] && venv_torch_requires_rebuild "${RUNTIME_BASE}/.venv/bin/python"; then
  remove_incompatible_venv
fi
if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
  if evaluate_python_candidate "${RUNTIME_BASE}/.venv/bin/python"; then
    log "Selected existing virtual environment Python: ${PYTHON} (version ${SELECTED_PYTHON_VERSION})"
  else
    remove_incompatible_venv
  fi
fi

if [ -z "${PYTHON}" ] && find_managed_python; then
  MANAGED_PYTHON_STATUS="existing"
  MANAGED_PYTHON_PATH="${PYTHON}"
  log "Selected STEMwerk-managed Python interpreter: ${PYTHON} (version ${SELECTED_PYTHON_VERSION})"
fi

if [ -z "${PYTHON}" ]; then
  if install_managed_python_runtime && find_managed_python; then
    log "Selected STEMwerk-managed Python interpreter after acquisition: ${PYTHON} (version ${SELECTED_PYTHON_VERSION})"
  fi
fi

if [ -z "${PYTHON}" ]; then
  for p in \
    "python3.12" \
    "/opt/homebrew/bin/python3.12" \
    "/usr/local/bin/python3.12" \
    "/opt/homebrew/opt/python@3.12/libexec/bin/python3" \
    "/usr/local/opt/python@3.12/libexec/bin/python3" \
    "/opt/homebrew/opt/python@3.12/bin/python3" \
    "/usr/local/opt/python@3.12/bin/python3" \
    "python3.11" \
    "/opt/homebrew/bin/python3.11" \
    "/usr/local/bin/python3.11" \
    "/opt/homebrew/opt/python@3.11/libexec/bin/python3" \
    "/usr/local/opt/python@3.11/libexec/bin/python3" \
    "/opt/homebrew/opt/python@3.11/bin/python3" \
    "/usr/local/opt/python@3.11/bin/python3" \
    "python3.10" \
    "/opt/homebrew/bin/python3.10" \
    "/usr/local/bin/python3.10" \
    "/opt/homebrew/opt/python@3.10/libexec/bin/python3" \
    "/usr/local/opt/python@3.10/libexec/bin/python3" \
    "/opt/homebrew/opt/python@3.10/bin/python3" \
    "/usr/local/opt/python@3.10/bin/python3" \
    "python3" \
    "/opt/homebrew/bin/python3" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3"
  do
    if evaluate_python_candidate "${p}"; then
      log "Selected macOS Python interpreter: ${PYTHON} (version ${SELECTED_PYTHON_VERSION})"
      break
    fi
  done
fi

set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"

if [ -z "${PYTHON}" ]; then
  if [ -n "${FIRST_UNSUPPORTED_PYTHON_VERSION}" ]; then
    log "System Python ${FIRST_UNSUPPORTED_PYTHON_VERSION} is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."
  fi
fi

if [ -z "${PYTHON}" ]; then
  if [ -n "${FIRST_UNSUPPORTED_PYTHON_PATH}" ] && [ -n "${FIRST_UNSUPPORTED_PYTHON_VERSION}" ]; then
    if [ "${MANAGED_PYTHON_ERROR}" = "unsupported_platform" ]; then
      PYTHON_MESSAGE="STEMwerk managed Python is not available for this platform yet."
    elif [ "${MANAGED_PYTHON_ERROR}" = "offline_local_payload_missing" ]; then
      PYTHON_MESSAGE="Offline bundled installer is missing a local STEMwerk-managed Python runtime payload."
    elif [ "${MANAGED_PYTHON_ERROR}" = "sha256_mismatch" ]; then
      PYTHON_MESSAGE="Managed Python download failed verification and was not installed."
    elif [ "${MANAGED_PYTHON_ERROR}" = "download_failed" ] || [ "${MANAGED_PYTHON_ERROR}" = "download_tool_missing" ]; then
      PYTHON_MESSAGE="STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
    else
      PYTHON_MESSAGE="STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-managed_python_unavailable}."
    fi
    log "${PYTHON_MESSAGE}"
    printf "%s\n" "${PYTHON_MESSAGE}" >&2
    set_status "missing_python" "managed_python_unavailable"
  else
    if [ "${MANAGED_PYTHON_ERROR}" = "unsupported_platform" ]; then
      PYTHON_MESSAGE="STEMwerk managed Python is not available for this platform yet."
    elif [ "${MANAGED_PYTHON_ERROR}" = "offline_local_payload_missing" ]; then
      PYTHON_MESSAGE="Offline bundled installer is missing a local STEMwerk-managed Python runtime payload."
    elif [ "${MANAGED_PYTHON_ERROR}" = "sha256_mismatch" ]; then
      PYTHON_MESSAGE="Managed Python download failed verification and was not installed."
    elif [ "${MANAGED_PYTHON_ERROR}" = "download_failed" ] || [ "${MANAGED_PYTHON_ERROR}" = "download_tool_missing" ]; then
      PYTHON_MESSAGE="STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
    else
      PYTHON_MESSAGE="STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-managed_python_unavailable}."
    fi
    log "${PYTHON_MESSAGE}"
    printf "%s\n" "${PYTHON_MESSAGE}" >&2
    set_status "missing_python" "managed_python_unavailable"
  fi
  write_state
  exit 1
else
  case "${PYTHON}" in
    "${RUNTIME_BASE}/python"/*)
      MANAGED_PYTHON_PATH="${PYTHON}"
      ;;
    *)
      SYSTEM_PYTHON_USED="yes"
      SYSTEM_PYTHON_PATH="${PYTHON}"
      SYSTEM_PYTHON_VERSION="${SELECTED_PYTHON_VERSION}"
      ;;
  esac
  log_macos_diagnostics
  if [ ! -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    log "Creating STEMwerk virtual environment..."
    log "Creating venv with ${PYTHON}"
    "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv" >> "${LOG_FILE}" 2>&1 || set_status "venv_failed" "venv_create_failed"
  fi
  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    set_progress "3" "${STEP_TOTAL}" "Installing STEMwerk runtime"
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    install_with_optional_bundled_wheels "${VENV_PY}" --upgrade pip >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    log "Installing pinned STEMwerk backend packages..."
    install_with_optional_bundled_wheels "${VENV_PY}" "numpy==${PINNED_NUMPY_VERSION}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "numpy_install_failed"
    if ! install_pinned_torch_stack; then
      if [ "${MAC_ARCH}" = "x86_64" ]; then
        log "Intel macOS CPU fallback dependency install failed during initial torch stack setup"
      fi
      set_status "deps_failed" "torch_install_failed"
    fi

    log "Installing stemwerk-core"
    resolve_core_target || true
    if [ -n "${CORE_TARGET:-}" ]; then
      log "Installing stemwerk-core from ${CORE_TARGET_DESC}: ${CORE_TARGET}"
      if ! install_stemwerk_core_target "${VENV_PY}" "${CORE_TARGET}" "${CORE_TARGET_DESC}" >> "${LOG_FILE}" 2>&1; then
        log "stemwerk-core install failed; aborting macOS bootstrap before secondary dependency installation"
        set_status "deps_failed" "stemwerk_core_install_failed"
        write_state
        exit 1
      fi
    else
      log "stemwerk-core source bundle is missing or incomplete"
      log "Expected bundle directory: ${CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
      log "Required files: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
      log "Recovery: run STEMwerk-SETUP.lua again after fixing or reinstalling STEMwerk."
      set_status "deps_failed" "stemwerk_core_bundle_incomplete"
      write_state
      exit 1
    fi

    log "Preinstalling numba/llvmlite (macOS wheels)"
    install_with_optional_bundled_wheels "${VENV_PY}" --only-binary=:all: \
      "llvmlite==${PINNED_LLVMLITE_VERSION}" "numba==${PINNED_NUMBA_VERSION}" >> "${LOG_FILE}" 2>&1 || \
      log "WARN: numba/llvmlite wheel install failed; continuing with audio-separator install"

    if ! "${VENV_PY}" -m pip show audio-separator >/dev/null 2>&1; then
        _audio_tmp_log="${RUNTIME_BASE}/logs/audio_separator_install.log"
        : > "${_audio_tmp_log}" || true
        if [ -f "${MACOS_CONSTRAINTS_FILE}" ]; then
          log "Installing ${PACKAGE} with macOS constraints from ${MACOS_CONSTRAINTS_FILE}"
          install_with_optional_bundled_wheels "${VENV_PY}" -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}" >> "${_audio_tmp_log}" 2>&1
        else
          install_with_optional_bundled_wheels "${VENV_PY}" "${PACKAGE}" >> "${_audio_tmp_log}" 2>&1
        fi
        _audio_rc=$?
        cat "${_audio_tmp_log}" >> "${LOG_FILE}" 2>/dev/null || true
        if [ "${_audio_rc}" -ne 0 ]; then
          if grep -Eiq "No matching distribution found for torch|no matching distributions available for your environment.*torch|depends on torch" "${_audio_tmp_log}" 2>/dev/null; then
            if [ "$(uname -m)" = "x86_64" ]; then
              log "audio-separator install failed: PyTorch wheels unavailable for this Intel macOS/Python combination"
              set_status "deps_failed" "audio_separator_torch_unavailable_macos_intel"
            else
              log "audio-separator install failed: PyTorch wheels unavailable for this macOS/Python/architecture combination"
              set_status "deps_failed" "audio_separator_torch_unavailable"
            fi
          else
            set_status "deps_failed" "audio_separator_install_failed"
          fi
        fi
        rm -f "${_audio_tmp_log}" >/dev/null 2>&1 || true
    fi

    if ! repair_samplerate_if_arch_mismatch "post_audio_separator_install"; then
      if [ -n "${BACKEND_DEPS_REASON}" ]; then
        set_status "deps_failed" "${BACKEND_DEPS_REASON}"
      else
        set_status "deps_failed" "samplerate_arch_mismatch_requires_runtime_rebuild"
      fi
    fi

    if ! install_pinned_torch_stack; then
      if [ "${MAC_ARCH}" = "x86_64" ]; then
        log "Intel macOS CPU fallback dependency install failed during post-audio-separator torch stack repair"
      fi
      set_status "deps_failed" "torch_pin_repair_failed"
    fi
    if ! assert_pinned_torch_stack "${VENV_PY}"; then
      set_status "deps_failed" "torch_pin_assert_failed"
    fi

    if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
      log "Installing ${ONNX_PACKAGE}"
      if ! install_with_optional_bundled_wheels "${VENV_PY}" "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1; then
        if [ -n "${ONNX_FALLBACK_PACKAGE}" ] && [ "${ONNX_FALLBACK_PACKAGE}" != "${ONNX_PACKAGE}" ]; then
          log "WARN: ${ONNX_PACKAGE} install failed; falling back to ${ONNX_FALLBACK_PACKAGE}"
          printf "WARN: %s install failed; falling back to %s\n" "${ONNX_PACKAGE}" "${ONNX_FALLBACK_PACKAGE}" >&2
          install_with_optional_bundled_wheels "${VENV_PY}" "${ONNX_FALLBACK_PACKAGE}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "onnxruntime_install_failed"
        else
          set_status "deps_failed" "onnxruntime_install_failed"
        fi
      fi
    fi
  fi
fi

set_progress "4" "${STEP_TOTAL}" "Checking FFmpeg"

_bundled_ffmpeg="$(bundled_ffmpeg_path || true)"
if [ -n "${_bundled_ffmpeg}" ] && [ -x "${_bundled_ffmpeg}" ]; then
  FFMPEG="${_bundled_ffmpeg}"
  MACOS_BUNDLED_FFMPEG_STATUS="ok"
fi
log "MACOS_BUNDLED_FFMPEG_STATUS=${MACOS_BUNDLED_FFMPEG_STATUS}"

for p in \
  "${RUNTIME_BASE}/bin/ffmpeg" \
  "${RUNTIME_BASE}/ffmpeg/bin/ffmpeg" \
  "/opt/homebrew/bin/ffmpeg" \
  "/usr/local/bin/ffmpeg" \
  "/opt/local/bin/ffmpeg" \
  "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" \
  "/usr/local/opt/ffmpeg/bin/ffmpeg" \
  "/usr/bin/ffmpeg"
do
  if [ -n "${FFMPEG}" ]; then
    break
  fi
  if [ -x "$p" ]; then
    FFMPEG="$p"
    break
  fi
done

if [ -z "${FFMPEG}" ]; then
  set_status "missing_ffmpeg" "ffmpeg_not_found"
fi

set_progress "5" "${STEP_TOTAL}" "Preparing Drum Kit runtime"

if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  FINAL_RUNTIME_VERIFIED="yes"
  "${VENV_PY}" -c "import numba" >/dev/null 2>&1 || set_status "deps_failed" "numba_missing_after_setup"
  log_final_dependency_versions "${VENV_PY}"
  if ! repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"; then
    FINAL_RUNTIME_VERIFIED="no"
    if [ -n "${BACKEND_DEPS_REASON}" ]; then
      set_status "deps_failed" "${BACKEND_DEPS_REASON}"
    else
      set_status "deps_failed" "samplerate_arch_mismatch_requires_runtime_rebuild"
    fi
  fi
  if ! "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; then
    FINAL_RUNTIME_VERIFIED="no"
    set_status "audio_separator_check_failed" "audio_separator_import_failed"
  fi
  if ! verify_audio_separator_runtime_deps; then
    FINAL_RUNTIME_VERIFIED="no"
    if [ "${BACKEND_DEPS_REASON}" = "samplerate_arch_mismatch_requires_runtime_rebuild" ] || [ "${BACKEND_DEPS_REASON}" = "samplerate_reinstall_failed" ]; then
      set_status "deps_failed" "${BACKEND_DEPS_REASON}"
    else
      set_status "deps_failed" "audio_separator_install_failed"
    fi
  fi
  if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
    FINAL_RUNTIME_VERIFIED="no"
    set_status "onnxruntime_check_failed" "onnxruntime_missing_after_setup"
  fi
  if ! "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1; then
    FINAL_RUNTIME_VERIFIED="no"
    set_status "stemwerk_core_check_failed" "stemwerk_core_missing_after_setup"
  fi
  if ! assert_pinned_torch_stack "${VENV_PY}"; then
    FINAL_RUNTIME_VERIFIED="no"
    set_status "deps_failed" "torch_pin_assert_failed"
  fi
  if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ]; then
    case "${STATUS_REASON}" in
      torch_install_failed|torch_pin_repair_failed|torch_pin_assert_failed)
    STATUS="ok"
    STATUS_REASON=""
        log "Cleared stale STATUS from earlier pinned torch failure after final runtime verification success"
        ;;
    esac
  fi
fi

READY_RUNTIME_KIND="cpu"
READY_RUNTIME_STATUS="missing"
READY_DRUMSEP_MODEL_STATUS="missing"
READY_MAIN_RUNTIME_STATUS="missing"
READY_DETAIL="${STATUS_REASON}"
if [ "${MAC_ARCH}" = "arm64" ]; then
  READY_RUNTIME_KIND="mps"
fi
if [ "${STATUS}" = "ok" ] && [ "${FINAL_RUNTIME_VERIFIED:-no}" = "yes" ]; then
  READY_MAIN_RUNTIME_STATUS="ok"
fi
if [ "${STATUS}" = "ok" ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  _bundled_models_dir="$(bundled_models_dir || true)"
  if [ -n "${_bundled_models_dir}" ]; then
    if copy_bundled_models_to_cache "${_bundled_models_dir}" "$(model_cache_dir)"; then
      MACOS_BUNDLED_MODELS_STATUS="seeded"
    else
      MACOS_BUNDLED_MODELS_STATUS="copy_failed"
    fi
  fi
  if ! ensure_core_model_cache "${VENV_PY}" "$(model_cache_dir)"; then
    READY_DETAIL="core_model_download_failed"
    log "core_model_prefetch_failed=core_model_download_failed"
    set_status "deps_failed" "core_model_download_failed"
  fi
fi
if [ "${STATUS}" = "ok" ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  _bundled_drumsep_dir="$(bundled_drumsep_dir || true)"
  if [ -n "${_bundled_drumsep_dir}" ]; then
    if copy_bundled_models_to_cache "${_bundled_drumsep_dir}" "$(model_cache_dir)"; then
      MACOS_BUNDLED_DRUMSEP_STATUS="seeded"
    else
      MACOS_BUNDLED_DRUMSEP_STATUS="copy_failed"
    fi
  fi
  if [ "${MAC_ARCH}" = "x86_64" ]; then
    READY_RUNTIME_STATUS="skipped"
    READY_DRUMSEP_MODEL_STATUS="skipped"
    READY_DETAIL="unsupported_mac_intel"
    log "drumsep_ready_status=unsupported_mac_intel"
  else
    if ensure_drumsep_assets "${VENV_PY}" "$(model_cache_dir)"; then
      READY_RUNTIME_STATUS="ok"
      READY_DRUMSEP_MODEL_STATUS="ok"
      READY_DETAIL="ok"
    else
      log "drumsep_model_prefetch_detail=${DRUMSEP_PREFETCH_DETAIL:-unknown}"
      READY_RUNTIME_STATUS="missing"
      READY_DRUMSEP_MODEL_STATUS="missing"
      case "${DRUMSEP_PREFETCH_DETAIL:-}" in
        asset_download_failed:*|download_checks_write_failed:*|runtime_download_checks_missing|drumsep_yaml_filename_missing|builtin_fallback|catalog_entry_missing)
          READY_DETAIL="drumsep_model_download_failed"
          set_status "deps_failed" "drumsep_model_download_failed"
          ;;
        *)
          READY_DETAIL="drumsep_model_prefetch_failed"
          set_status "deps_failed" "drumsep_model_prefetch_failed"
          ;;
      esac
    fi
  fi
fi
write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "${READY_MAIN_RUNTIME_STATUS}"

if [ -n "${STATE_FILE}" ]; then
  write_state
fi

if [ "${STATUS}" != "ok" ]; then
  exit 1
fi
log "Runtime verification passed."
exit 0
