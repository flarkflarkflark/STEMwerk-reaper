#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"
PINNED_TORCH_VERSION="2.5.1"
PINNED_TORCHAUDIO_VERSION="2.5.1"
PINNED_TORCHVISION_VERSION="0.20.1"
PINNED_NUMPY_VERSION="1.26.4"
PINNED_NUMBA_VERSION="0.59.1"
PINNED_LLVM_VERSION="0.42.0"

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

log_stage() {
  log "================================================================================"
  log "STAGE: $*"
}

log_step() {
  log " - $*"
}

is_core_source_bundle() {
  [ -n "${1:-}" ] \
    && [ -f "$1/pyproject.toml" ] \
    && [ -f "$1/src/stemwerk_core/__init__.py" ] \
    && [ -f "$1/src/stemwerk_core/separator.py" ]
}

model_cache_dir() {
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    printf "%s/STEMwerk/models\n" "${XDG_DATA_HOME}"
  else
    printf "%s/.local/share/STEMwerk/models\n" "${HOME:-/tmp}"
  fi
}

write_state() {
  if [ -n "${STATE_FILE}" ]; then
    py_path_out="${PYTHON_PATH}"
    case "${STATUS}:${STATUS_REASON}" in
      deps_failed:*|venv_failed:*|*:audio_separator_install_failed)
        py_path_out=""
        ;;
    esac
    {
      echo "STATUS=${STATUS}"
      [ -n "${STATUS_REASON}" ] && echo "STATUS_REASON=${STATUS_REASON}"
      [ -n "${STEP_INDEX}" ] && echo "STEP_INDEX=${STEP_INDEX}"
      [ -n "${STEP_TOTAL}" ] && echo "STEP_TOTAL=${STEP_TOTAL}"
      [ -n "${STEP_LABEL}" ] && echo "STEP_LABEL=${STEP_LABEL}"
      [ -n "${PROFILE}" ] && echo "PROFILE=${PROFILE}"
      [ -n "${BACKEND}" ] && echo "BACKEND=${BACKEND}"
      [ -n "${BACKEND_REASON}" ] && echo "BACKEND_REASON=${BACKEND_REASON}"
      [ -n "${BACKEND_NOTE}" ] && echo "BACKEND_NOTE=${BACKEND_NOTE}"
      echo "AUDIO_SEPARATOR_IMPORT=${AUDIO_SEPARATOR_IMPORT}"
      echo "AUDIO_SEPARATOR_DEPS_COMPLETE=${AUDIO_SEPARATOR_DEPS_COMPLETE}"
      echo "BACKEND_DEPS_COMPLETE=${BACKEND_DEPS_COMPLETE}"
      [ -n "${BACKEND_DEPS_REASON}" ] && echo "BACKEND_DEPS_REASON=${BACKEND_DEPS_REASON}"
      echo "BUILD_TOOLS_MISSING=${BUILD_TOOLS_MISSING}"
      [ -n "${SUPPORTED_PYTHON_FOUND}" ] && echo "SUPPORTED_PYTHON_FOUND=${SUPPORTED_PYTHON_FOUND}"
      [ -n "${DETECTED_PYTHON_VERSION}" ] && echo "DETECTED_PYTHON_VERSION=${DETECTED_PYTHON_VERSION}"
      [ -n "${DETECTED_PYTHON_PATH}" ] && echo "DETECTED_PYTHON_PATH=${DETECTED_PYTHON_PATH}"
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
      echo "PYTHON_PATH=${py_path_out}"
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

detect_build_tools_missing_log() {
  _log="$1"
  [ -f "${_log}" ] || return 1
  grep -Eiq "command 'clang' failed: No such file or directory|command 'gcc' failed: No such file or directory|command 'cc' failed: No such file or directory|error: command 'clang' failed|error: command 'gcc' failed|error: command 'cc' failed" "${_log}"
}

mark_build_tools_missing() {
  BUILD_TOOLS_MISSING="yes"
  BACKEND_DEPS_COMPLETE="no"
  BACKEND_DEPS_REASON="missing_diffq_or_build_tools"
  BACKEND_REASON="audio_separator_install_failed"
  log_step "Backend dependency build failed because no C compiler was found. Install clang/gcc/build tools, then run Repair/Rebuild again."
}

is_managed_python_312_linux_x86_64() {
  [ "${OS_NAME}" = "linux" ] || return 1
  [ "${ARCH}" = "x86_64" ] || return 1
  [ -n "${MANAGED_PYTHON_PATH:-}" ] || return 1
  [ -n "${PYTHON:-}" ] || return 1
  [ "${PYTHON}" = "${MANAGED_PYTHON_PATH}" ] || return 1
  [ -n "${DETECTED_PYTHON_VERSION:-}" ] || return 1
  case "${DETECTED_PYTHON_VERSION}" in
    3.12.*|3.12) return 0 ;;
    *) return 1 ;;
  esac
}

find_managed_diffq_wheel() {
  for wheel_dir in \
    "${SCRIPT_DIR}/vendor/wheels/linux-x86_64-cp312" \
    "${RUNTIME_BASE}/wheels/linux-x86_64-cp312" \
    "${RUNTIME_BASE}/cache/wheels"
  do
    [ -d "${wheel_dir}" ] || continue
    for wheel in "${wheel_dir}"/diffq-*.whl; do
      [ -f "${wheel}" ] || continue
      printf "%s\n" "${wheel}"
      return 0
    done
  done
  return 1
}

install_managed_diffq_wheel() {
  [ -n "${VENV_PY:-}" ] || return 1
  [ -x "${VENV_PY}" ] || return 1
  diffq_wheel="$(find_managed_diffq_wheel || true)"
  if [ -z "${diffq_wheel}" ]; then
    BACKEND_DEPS_COMPLETE="no"
    BACKEND_DEPS_REASON="managed_diffq_wheel_missing"
    BACKEND_REASON="managed_diffq_wheel_missing"
    log_step "Managed dependency wheel missing for diffq on Linux Python 3.12. Repair/Rebuild could not complete."
    return 1
  fi
  log_step "Installing managed diffq wheel: ${diffq_wheel}"
  "${VENV_PY}" -m pip install --no-index --find-links "$(dirname "${diffq_wheel}")" --only-binary=:all: "${diffq_wheel}" >> "${LOG_FILE}" 2>&1
}

clear_stale_python_backend_reason() {
  case "${BACKEND_REASON:-}" in
    python_missing|python_not_found|python_unsupported)
      if [ -n "${VENV_PY:-}" ] && [ -x "${VENV_PY}" ]; then
        log_step "Clearing stale backend reason after valid venv Python: ${BACKEND_REASON}"
        BACKEND_REASON=""
      fi
      ;;
  esac
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
  BACKEND_DEPS_REASON="${BACKEND_DEPS_REASON:-audio_separator_deps_missing}"
  log_step "audio-separator dependency verification failed: ${_probe}"
  return 1
}

classify_venv_failure() {
  _log="$1"
  if [ -f "${_log}" ] && grep -Eiq "ensurepip is not available|No module named ensurepip|python[0-9.]*-venv|install python[0-9.]*-venv" "${_log}"; then
    printf "venv_create_failed_missing_ensurepip"
  else
    printf "venv_create_failed"
  fi
}

create_venv_with_selected_python() {
  rm -rf "${RUNTIME_BASE}/.venv"
  _venv_log="${RUNTIME_BASE}/logs/venv_create.log"
  : > "${_venv_log}" || true
  log_step "Creating venv at ${RUNTIME_BASE}/.venv"
  if "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv" >> "${_venv_log}" 2>&1; then
    cat "${_venv_log}" >> "${LOG_FILE}" 2>/dev/null || true
    return 0
  fi
  cat "${_venv_log}" >> "${LOG_FILE}" 2>/dev/null || true
  VENV_CREATE_REASON="$(classify_venv_failure "${_venv_log}")"
  log_step "Venv creation failed with ${PYTHON}: ${VENV_CREATE_REASON}"
  rm -rf "${RUNTIME_BASE}/.venv"
  return 1
}

selected_python_is_managed() {
  case "${PYTHON}" in
    "${RUNTIME_BASE}/python"/*) return 0 ;;
  esac
  return 1
}

try_managed_python_after_venv_failure() {
  selected_python_is_managed && return 1
  log_step "System Python could not create a venv; trying STEMwerk-managed Python fallback."
  if install_managed_python_runtime && find_managed_python; then
    MANAGED_PYTHON_PATH="${PYTHON}"
    SYSTEM_PYTHON_USED="no"
    log_step "Using managed Python after system venv failure: ${PYTHON}"
    create_venv_with_selected_python
    return $?
  fi
  return 1
}

set_progress() {
  STEP_INDEX="$1"
  STEP_TOTAL="$2"
  STEP_LABEL="$3"
  log "STEP ${STEP_INDEX}/${STEP_TOTAL}: ${STEP_LABEL}"
  write_state
}

resolve_core_target() {
  CORE_TARGET=""
  CORE_TARGET_DESC=""
  CORE_SUPPORTS_EXTRAS=0

  if [ -n "${STEMWERK_CORE_PATH:-}" ] && [ -e "${STEMWERK_CORE_PATH}" ]; then
    if is_core_source_bundle "${STEMWERK_CORE_PATH}"; then
      CORE_TARGET="${STEMWERK_CORE_PATH}"
      CORE_TARGET_DESC="STEMWERK_CORE_PATH source"
      CORE_SUPPORTS_EXTRAS=1
      return 0
    fi
    log_step "STEMWERK_CORE_PATH is set but incomplete: ${STEMWERK_CORE_PATH}"
    log_step "Required: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
  fi

  CORE_BUNDLE_DIR="${STEMWERK_CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
  if [ -d "${CORE_BUNDLE_DIR}" ]; then
    if is_core_source_bundle "${CORE_BUNDLE_DIR}"; then
      CORE_TARGET="${CORE_BUNDLE_DIR}"
      CORE_TARGET_DESC="bundled source"
      CORE_SUPPORTS_EXTRAS=1
      return 0
    fi
    log_step "Bundled stemwerk-core source is incomplete: ${CORE_BUNDLE_DIR}"
    log_step "Required: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
  fi

  return 1
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
      log_step "Existing venv has incompatible torch ${_probe#rebuild|}; rebuilding .venv for audio-separator 0.23.0 compatibility"
      return 0
      ;;
    ok\|*)
      log_step "Existing venv torch is compatible: ${_probe#ok|}"
      ;;
  esac
  return 1
}

linux_torch_install_args() {
  printf '"torch==%s" "torchvision==%s" "torchaudio==%s"' \
    "${PINNED_TORCH_VERSION}" \
    "${PINNED_TORCHVISION_VERSION}" \
    "${PINNED_TORCHAUDIO_VERSION}"
}

log_nvidia_packages() {
  NVIDIA_PKGS="$("${VENV_PY}" -m pip list 2>/dev/null | awk '/^nvidia-/{print $1"=="$2}')"
  if [ -n "${NVIDIA_PKGS}" ]; then
    log_step "WARNING: NVIDIA packages detected after ${1}: ${NVIDIA_PKGS}"
  else
    log_step "No NVIDIA packages detected after ${1}"
  fi
}

install_linux_torch_stack() {
  _mode="$1"
  _index="${2:-}"
  log_step "Uninstalling existing torch/vision/audio before ${_mode} torch install"
  "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
  case "${_mode}" in
    cpu)
      log_step "Torch source index: https://download.pytorch.org/whl/cpu (torch/torchaudio pinned to ${PINNED_TORCH_VERSION})"
      eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url https://download.pytorch.org/whl/cpu $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
      ;;
    rocm)
      log_step "Torch source index: ${_index} (torch/torchaudio pinned to ${PINNED_TORCH_VERSION})"
      eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url \"${_index}\" $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
      ;;
    cuda)
      log_step "Torch source index: default pip index (torch/torchaudio pinned to ${PINNED_TORCH_VERSION})"
      eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
      ;;
    *)
      return 1
      ;;
  esac
	  enforce_runtime_python_pins || set_status "deps_failed" "runtime_python_pins_failed"
}

assert_pinned_torch_stack() {
  _venv_py="$1"
  _probe="$("${_venv_py}" - <<PY 2>/dev/null || true
expected_torch = "${PINNED_TORCH_VERSION}"
expected_torchaudio = "${PINNED_TORCHAUDIO_VERSION}"
def core(ver):
    return str(ver).split("+", 1)[0]
try:
    import torch
    torch_ver = getattr(torch, "__version__", "")
except Exception as exc:
    print("error|torch_import|" + str(exc))
    raise SystemExit(0)
try:
    import torchaudio
    torchaudio_ver = getattr(torchaudio, "__version__", "")
except Exception as exc:
    print("error|torchaudio_import|" + str(exc))
    raise SystemExit(0)
if core(torch_ver) == expected_torch and core(torchaudio_ver) == expected_torchaudio:
    print("ok|" + torch_ver + "|" + torchaudio_ver)
else:
    print("bad|" + torch_ver + "|" + torchaudio_ver)
PY
)"
  case "${_probe}" in
    ok\|*)
      log_step "Pinned torch assertion passed: torch=$(printf "%s" "${_probe}" | cut -d'|' -f2) torchaudio=$(printf "%s" "${_probe}" | cut -d'|' -f3)"
      return 0
      ;;
  esac
  log_step "Pinned torch assertion failed: ${_probe}"
  printf "STEMwerk bootstrap failed: expected torch=%s and torchaudio=%s after setup.\n" "${PINNED_TORCH_VERSION}" "${PINNED_TORCHAUDIO_VERSION}" >&2
  return 1
}

enforce_runtime_python_pins() {
  if [ -z "${VENV_PY}" ] || [ ! -x "${VENV_PY}" ]; then
    return 1
  fi
  log_step "Enforcing runtime Python deps: numpy==${PINNED_NUMPY_VERSION} numba==${PINNED_NUMBA_VERSION} llvmlite==${PINNED_LLVM_VERSION}"
  "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir \
    "numpy==${PINNED_NUMPY_VERSION}" \
    "llvmlite==${PINNED_LLVM_VERSION}" \
    "numba==${PINNED_NUMBA_VERSION}" >> "${LOG_FILE}" 2>&1
}

if [ -z "${RUNTIME_BASE}" ]; then
  echo "Missing runtime base" >&2
  exit 1
fi

log_stage "Bootstrap started"
log_step "Requested mode: ${MODE}"
log_step "Downloaded models are kept at: $(model_cache_dir)"
if [ "${MODE}" = "rebuild-venv" ] && [ -d "${RUNTIME_BASE}/.venv" ]; then
  log_step "Removing existing virtual environment: ${RUNTIME_BASE}/.venv"
  rm -rf "${RUNTIME_BASE}/.venv"
fi
log_step "Preparing runtime directories"
log_step "Clearing GPU override env vars (HIP_VISIBLE_DEVICES/HSA_OVERRIDE_GFX_VERSION/ROCR_VISIBLE_DEVICES/CUDA_VISIBLE_DEVICES)"
log_step "GPU env before clear: HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-} HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-} ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
unset HIP_VISIBLE_DEVICES HSA_OVERRIDE_GFX_VERSION ROCR_VISIBLE_DEVICES CUDA_VISIBLE_DEVICES
log_step "GPU env after clear: HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-} HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-} ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
if command -v rocminfo >/dev/null 2>&1; then
  log_step "rocminfo summary (filtered)"
  env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES \
    rocminfo 2>/dev/null | grep -E "Name:|Marketing Name:|gfx|Device Type|Vendor Name" | head -n 40 | \
    while read -r line; do log_step "rocminfo: ${line}"; done
fi
if command -v rocm-smi >/dev/null 2>&1; then
  log_step "rocm-smi summary"
  env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES \
    rocm-smi 2>/dev/null | head -n 40 | while read -r line; do log_step "rocm-smi: ${line}"; done
fi
mkdir -p "${RUNTIME_BASE}/state" "${RUNTIME_BASE}/logs" "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"

STATUS="ok"
STATUS_REASON=""
PYTHON=""
FFMPEG=""
VENV_PY=""
PYTHON_PATH=""
SUPPORTED_PYTHON_FOUND="no"
DETECTED_PYTHON_VERSION=""
DETECTED_PYTHON_PATH=""
# Conservative default on Linux to avoid extra GPU deps unless explicitly needed.
PACKAGE="audio-separator==0.23.0"
ONNX_PACKAGE="onnxruntime"
CORE_EXTRA=""
PROFILE="linux-cpu"
BACKEND="cpu"
BACKEND_REASON=""
BACKEND_NOTE=""
BACKEND_DEPS_COMPLETE="unknown"
BACKEND_DEPS_REASON=""
BUILD_TOOLS_MISSING="no"
AUDIO_SEPARATOR_IMPORT="unknown"
AUDIO_SEPARATOR_DEPS_COMPLETE="unknown"
CONSTRAINTS_FILE=""
SELECTED_TORCH_INDEX=""
STEP_INDEX=""
STEP_TOTAL="4"
STEP_LABEL=""
VENV_CREATE_REASON=""
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
SYSTEM_PYTHON_PATH=""
SYSTEM_PYTHON_VERSION=""
SYSTEM_PYTHON_USED="no"

if [ -f "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh" ]; then
  . "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh"
  managed_python_init_state
fi

set_progress "1" "${STEP_TOTAL}" "Preparing runtime"

GPU_MODE=0
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi -L >/dev/null 2>&1; then
    GPU_MODE=1
  fi
fi
if [ "${GPU_MODE}" -eq 0 ] && [ -c "/dev/nvidia0" ]; then
  GPU_MODE=1
fi

ROCM_MODE=0
if [ -d "/opt/rocm" ] || [ -n "${ROCM_PATH:-}" ] || command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; then
  ROCM_MODE=1
fi
ROCM_GFX1201=0
if command -v rocminfo >/dev/null 2>&1; then
  if env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES \
    rocminfo 2>/dev/null | grep -qi "gfx1201\\|rx 9070\\|radeon rx 9070"; then
    ROCM_GFX1201=1
  fi
fi

if [ "${ROCM_MODE}" -eq 1 ] && [ "${GPU_MODE}" -eq 0 ]; then
  log_step "ROCm detected; enabling ROCm packages"
  CORE_EXTRA="[rocm]"
  PROFILE="linux-rocm"
  BACKEND="rocm"
elif [ "${GPU_MODE}" -eq 1 ]; then
  log_step "CUDA-capable NVIDIA detected; enabling GPU packages"
  PACKAGE="audio-separator[gpu]==0.23.0"
  CORE_EXTRA="[gpu]"
  PROFILE="linux-cuda"
  BACKEND="cuda"
elif [ "${ROCM_MODE}" -eq 1 ]; then
  log_step "ROCm detected; enabling ROCm packages"
  CORE_EXTRA="[rocm]"
  PROFILE="linux-rocm"
  BACKEND="rocm"
fi

set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"
log_step "Checking Python"
is_pyenv_shim() {
  case "$1" in
    *"/.pyenv/shims/"*) return 0 ;;
    *) return 1 ;;
  esac
}

command_path() {
  local cmd="$1"
  command -v "${cmd}" 2>/dev/null | while IFS= read -r line; do
    case "${line}" in
      /*)
        if [ -x "${line}" ]; then
          printf "%s\n" "${line}"
          exit 0
        fi
        ;;
    esac
  done
}

UNSUPPORTED_PYTHON_VERSION=""
UNSUPPORTED_PYTHON_PATH=""
MANAGED_PYTHON=""

python_major_minor() {
  local py="$1"
  if [ ! -x "$py" ]; then
    return 1
  fi
  local out
  out="$("$py" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)"
  if [ -z "${out}" ]; then
    return 1
  fi
  printf "%s" "${out}"
  return 0
}

python_full_version() {
  local py="$1"
  if [ ! -x "$py" ]; then
    return 1
  fi
  local out
  out="$("$py" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  if [ -z "${out}" ]; then
    return 1
  fi
  printf "%s" "${out}"
  return 0
}

is_supported_python() {
  local py="$1"
  local mm
  mm="$(python_major_minor "$py" || true)"
  case "${mm}" in
    3.10|3.11|3.12)
      SUPPORTED_PYTHON_FOUND="yes"
      DETECTED_PYTHON_VERSION="$(python_full_version "$py" || printf "%s" "${mm}")"
      DETECTED_PYTHON_PATH="${py}"
      return 0
      ;;
  esac
  if [ -n "${mm}" ]; then
    local full
    full="$(python_full_version "$py" || printf "%s" "${mm}")"
    if [ -z "${SYSTEM_PYTHON_PATH}" ]; then
      SYSTEM_PYTHON_PATH="${py}"
      SYSTEM_PYTHON_VERSION="${full}"
    fi
    log_step "Ignoring unsupported Python ${full} at ${py} (need 3.10-3.12)"
    UNSUPPORTED_PYTHON_VERSION="${full}"
    UNSUPPORTED_PYTHON_PATH="${py}"
    if [ -z "${DETECTED_PYTHON_VERSION}" ]; then
      DETECTED_PYTHON_VERSION="${full}"
      DETECTED_PYTHON_PATH="${py}"
    fi
  fi
  return 1
}

find_pyenv_real() {
  if [ -d "${HOME}/.pyenv/versions" ]; then
    for p in \
      "${HOME}/.pyenv/versions/"*/bin/python3.12 \
      "${HOME}/.pyenv/versions/"*/bin/python3.11 \
      "${HOME}/.pyenv/versions/"*/bin/python3.10 \
      "${HOME}/.pyenv/versions/"*/bin/python3
    do
      if [ -x "$p" ] && is_supported_python "$p"; then
        PYTHON="$p"
        return 0
      fi
    done
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
    if [ -x "$p" ] && is_supported_python "$p"; then
      MANAGED_PYTHON="$p"
      PYTHON="$p"
      return 0
    fi
  done
  return 1
}

install_managed_python_runtime() {
  log_step "Attempting STEMwerk-managed Python runtime acquisition"
  for src in \
    "${STEMWERK_MANAGED_PYTHON_SOURCE:-}" \
    "${SCRIPT_DIR}/python" \
    "${SCRIPT_DIR}/runtime/python" \
    "${SCRIPT_DIR}/_runtime/python" \
    "${SCRIPT_DIR}/../runtime/python"
  do
    if [ -n "${src}" ] && [ -d "${src}" ]; then
      log_step "Found local managed Python source: ${src}"
      rm -rf "${RUNTIME_BASE}/python.tmp"
      mkdir -p "${RUNTIME_BASE}/python.tmp" || return 1
      if cp -R "${src}/." "${RUNTIME_BASE}/python.tmp/" >> "${LOG_FILE}" 2>&1; then
        if find_managed_python_from_dir "${RUNTIME_BASE}/python.tmp"; then
          rm -rf "${RUNTIME_BASE}/python"
          mv "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python" || return 1
          log_step "Installed STEMwerk-managed Python runtime under ${RUNTIME_BASE}/python"
          return 0
        fi
      fi
      rm -rf "${RUNTIME_BASE}/python.tmp"
    fi
  done
  log_step "No local STEMwerk-managed Python runtime payload is available"
  return 1
}

find_managed_python_from_dir() {
  local base="$1"
  for p in \
    "${base}/bin/python3.12" \
    "${base}/bin/python3.11" \
    "${base}/bin/python3.10" \
    "${base}/bin/python3" \
    "${base}/python3.12" \
    "${base}/python3.11" \
    "${base}/python3.10" \
    "${base}/python3"
  do
    if [ -x "$p" ] && is_supported_python "$p"; then
      return 0
    fi
  done
  return 1
}

if [ -f "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh" ]; then
  . "${SCRIPT_DIR}/_internal/STEMwerk_Managed_Python.sh"
  managed_python_init_state
fi

if find_managed_python; then
  MANAGED_PYTHON_STATUS="existing"
  MANAGED_PYTHON_PATH="${PYTHON}"
  log_step "Using managed Python: ${PYTHON}"
fi

if [ -z "${PYTHON}" ]; then
  if install_managed_python_runtime && find_managed_python; then
    log_step "Using managed Python after acquisition: ${PYTHON}"
  fi
fi

if [ -z "${PYTHON}" ] && ! find_pyenv_real; then
  for p in \
    "/usr/local/bin/python3.12" \
    "/usr/bin/python3.12" \
    "/usr/local/bin/python3.11" \
    "/usr/bin/python3.11" \
    "/usr/local/bin/python3.10" \
    "/usr/bin/python3.10" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3" \
    "/snap/bin/python3"
  do
    if [ -x "$p" ] && is_supported_python "$p"; then
      PYTHON="$p"
      break
    fi
  done
fi

if [ -z "${PYTHON}" ]; then
  for cmd in python3.12 python3.11 python3.10 python3; do
    candidate="$(command_path "${cmd}" || true)"
    if [ -n "${candidate}" ]; then
      if ! is_pyenv_shim "${candidate}"; then
        if is_supported_python "${candidate}"; then
          PYTHON="${candidate}"
          break
        fi
      fi
    fi
  done
fi

if [ -z "${PYTHON}" ]; then
  candidate="$(command_path python3 || true)"
  if [ -n "${candidate}" ]; then
    if is_supported_python "${candidate}"; then
      PYTHON="${candidate}"
    fi
  fi
fi

if [ -z "${PYTHON}" ]; then
  if [ -n "${UNSUPPORTED_PYTHON_VERSION}" ]; then
    log_step "System Python ${UNSUPPORTED_PYTHON_VERSION} is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."
  fi
fi

if [ -n "${PYTHON}" ]; then
  case "${PYTHON}" in
    "${RUNTIME_BASE}/python"/*)
      MANAGED_PYTHON_PATH="${PYTHON}"
      ;;
    *)
      SYSTEM_PYTHON_USED="yes"
      SYSTEM_PYTHON_PATH="${PYTHON}"
      SYSTEM_PYTHON_VERSION="$(python_full_version "${PYTHON}" || true)"
      ;;
  esac
  log_step "Using Python: ${PYTHON}"
fi

if [ -z "${PYTHON}" ]; then
  if [ -n "${UNSUPPORTED_PYTHON_VERSION}" ]; then
    BACKEND_REASON="python_unsupported"
    if [ "${MANAGED_PYTHON_ERROR}" = "unsupported_platform" ]; then
      msg="STEMwerk managed Python is not available for this platform yet."
    elif [ "${MANAGED_PYTHON_ERROR}" = "sha256_mismatch" ]; then
      msg="Managed Python download failed verification and was not installed."
    elif [ "${MANAGED_PYTHON_ERROR}" = "download_failed" ] || [ "${MANAGED_PYTHON_ERROR}" = "download_tool_missing" ]; then
      msg="STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
    else
      msg="STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-managed_python_unavailable}."
    fi
    log_step "${msg}"
    printf "%s\n" "${msg}" >&2
    set_status "missing_python" "managed_python_unavailable"
  else
    BACKEND_REASON="python_not_found"
    if [ "${MANAGED_PYTHON_ERROR}" = "unsupported_platform" ]; then
      msg="STEMwerk managed Python is not available for this platform yet."
    elif [ "${MANAGED_PYTHON_ERROR}" = "sha256_mismatch" ]; then
      msg="Managed Python download failed verification and was not installed."
    elif [ "${MANAGED_PYTHON_ERROR}" = "download_failed" ] || [ "${MANAGED_PYTHON_ERROR}" = "download_tool_missing" ]; then
      msg="STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
    else
      msg="STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-managed_python_unavailable}."
    fi
    log_step "${msg}"
    printf "%s\n" "${msg}" >&2
    set_status "missing_python" "managed_python_unavailable"
  fi
else
  log_stage "Creating venv"
  log_step "Creating STEMwerk virtual environment..."
  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ] && venv_torch_requires_rebuild "${RUNTIME_BASE}/.venv/bin/python"; then
    log_step "Removing existing virtual environment: ${RUNTIME_BASE}/.venv"
    rm -rf "${RUNTIME_BASE}/.venv"
  fi
  if [ ! -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    if ! create_venv_with_selected_python; then
      if ! try_managed_python_after_venv_failure; then
        if [ "${VENV_CREATE_REASON}" = "venv_create_failed_missing_ensurepip" ]; then
          msg="Could not create Python virtual environment because Python venv/ensurepip is missing. STEMwerk could not use or install a managed Python runtime. Install python3.12-venv or use the STEMwerk Linux/macOS package with managed runtime, then run Repair/Rebuild."
          log_step "${msg}"
          printf "%s\n" "${msg}" >&2
        fi
        set_status "venv_failed" "${VENV_CREATE_REASON:-venv_create_failed}"
      fi
    fi
  fi
  if [ "${STATUS}" != "ok" ]; then
    log_step "Stopping setup after venv creation failure; dependency installation will not run."
  elif [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    if ! "${RUNTIME_BASE}/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
      if [ -z "${VENV_CREATE_REASON}" ]; then
        VENV_CREATE_REASON="venv_create_failed_missing_ensurepip"
      fi
      msg="Could not create Python virtual environment because Python venv/ensurepip is missing. STEMwerk could not use or install a managed Python runtime. Install python3.12-venv or use the STEMwerk Linux/macOS package with managed runtime, then run Repair/Rebuild."
      log_step "${msg}"
      printf "%s\n" "${msg}" >&2
      rm -rf "${RUNTIME_BASE}/.venv"
      set_status "venv_failed" "${VENV_CREATE_REASON}"
    fi
  fi
  if [ "${STATUS}" = "ok" ] && [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    clear_stale_python_backend_reason
    log_step "Upgrading pip/setuptools/wheel"
    "${VENV_PY}" -m pip install --upgrade pip setuptools wheel >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    log_step "Selected profile=${PROFILE} backend=${BACKEND}"
    log_step "Installing pinned STEMwerk backend packages..."

    if [ "${BACKEND}" = "cpu" ]; then
      log_stage "Installing CPU torch"
      install_linux_torch_stack "cpu" || set_status "deps_failed" "torch_cpu_install_failed"
      log_nvidia_packages "CPU torch install"
      PACKAGE="audio-separator==0.23.0"
      CORE_EXTRA=""
    elif [ "${BACKEND}" = "cuda" ]; then
      log_stage "Installing CUDA torch"
      install_linux_torch_stack "cuda" || set_status "deps_failed" "torch_cuda_install_failed"
      log_nvidia_packages "CUDA torch install"
    fi

if [ "${BACKEND}" = "rocm" ]; then
      log_stage "Installing ROCm torch"
      rocm_ok=0
      rocm_fail_reason="rocm_wheel_not_found"
      rocm_platform_supported=0
      BACKEND_NOTE=""
      OS_ID=""
      OS_VERSION=""
      if [ -r "/etc/os-release" ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-}"
      fi
      case "${OS_ID}" in
        ubuntu)
          case "${OS_VERSION}" in
            22.04*|24.04*) rocm_platform_supported=1 ;;
          esac
          ;;
        rhel)
          OS_MAJOR="${OS_VERSION%%.*}"
          if [ -n "${OS_MAJOR}" ] && [ "${OS_MAJOR}" -ge 9 ]; then
            rocm_platform_supported=1
          fi
          ;;
        sles|sles_sap)
          OS_MAJOR="${OS_VERSION%%.*}"
          if [ -n "${OS_MAJOR}" ] && [ "${OS_MAJOR}" -ge 15 ]; then
            rocm_platform_supported=1
          fi
          ;;
      esac
      log_step "ROCm platform check: id=${OS_ID} version=${OS_VERSION} supported=${rocm_platform_supported}"
      if [ "${rocm_platform_supported}" -ne 1 ]; then
        BACKEND_NOTE="non_official_rocm_distro"
      fi
      ROCM_VER=""
      if [ -f "/opt/rocm/.info/version" ]; then
        ROCM_VER="$(tr -d ' \n' </opt/rocm/.info/version)"
      elif [ -f "/opt/rocm/.info/rocm_version" ]; then
        ROCM_VER="$(tr -d ' \n' </opt/rocm/.info/rocm_version)"
      fi
      ROCM_MM=""
      if [ -n "${ROCM_VER}" ]; then
        ROCM_MM="$(printf "%s" "${ROCM_VER}" | awk -F. '{print $1"."$2}')"
      fi

      IDX_LIST=""
      if [ -n "${ROCM_MM}" ]; then
        IDX_LIST="https://download.pytorch.org/whl/rocm${ROCM_MM}"
      fi
      if [ "${ROCM_GFX1201}" -eq 1 ]; then
        log_step "Detected gfx1201/RX 9070; trying experimental ROCm 7.x torch indexes first"
        IDX_LIST="https://download.pytorch.org/whl/rocm7.0 https://download.pytorch.org/whl/rocm7.1 ${IDX_LIST}"
      fi
      IDX_LIST="${IDX_LIST} https://download.pytorch.org/whl/rocm6.1 https://download.pytorch.org/whl/rocm6.0 https://download.pytorch.org/whl/rocm5.7 https://download.pytorch.org/whl/rocm5.6"

      for idx in ${IDX_LIST}
      do
        log_step "Trying ROCm torch index: ${idx} (no extra index; CUDA deps blocked)"
        if ! install_linux_torch_stack "rocm" "${idx}"; then
          log_step "ROCm torch pip install failed for ${idx}"
          rocm_fail_reason="rocm_wheel_not_found"
          continue
        fi
        log_nvidia_packages "ROCm torch install"

        probe_line="$("${VENV_PY}" - <<'PY' 2>&1
import torch
ver = getattr(torch, "__version__", "")
hip = getattr(getattr(torch, "version", None), "hip", None)
cuda_avail = bool(torch.cuda.is_available())
cuda_count = int(torch.cuda.device_count()) if cuda_avail else 0
names = []
if cuda_avail:
    for i in range(torch.cuda.device_count()):
        try:
            names.append(torch.cuda.get_device_name(i))
        except Exception:
            names.append("unknown")
props = []
if cuda_avail:
    for i in range(torch.cuda.device_count()):
        try:
            p = torch.cuda.get_device_properties(i)
            props.append({
                "name": p.name,
                "total_memory": getattr(p, "total_memory", None),
                "multi_processor_count": getattr(p, "multi_processor_count", None),
                "major": getattr(p, "major", None),
                "minor": getattr(p, "minor", None),
                "gcn_arch": getattr(p, "gcnArchName", None),
                "pci_bus_id": getattr(p, "pciBusID", None),
            })
        except Exception:
            props.append("unknown")
print(f"ROCM_DEVICE_NAMES={'|'.join(names)}")
print(f"ROCM_DEVICE_PROPS={props}")
print(f"ROCM_PROBE_RESULT={ver}|{hip}|{int(cuda_avail)}|{cuda_count}")
PY
)"
        log_step "ROCm probe output: ${probe_line}"

        probe_result="$(printf "%s\n" "$probe_line" | sed -n 's/^ROCM_PROBE_RESULT=//p' | tail -n 1)"
        device_names="$(printf "%s\n" "$probe_line" | sed -n 's/^ROCM_DEVICE_NAMES=//p' | tail -n 1)"
        device_props="$(printf "%s\n" "$probe_line" | sed -n 's/^ROCM_DEVICE_PROPS=//p' | tail -n 1)"
        if [ -n "${device_names}" ]; then
          log_step "ROCm device names: ${device_names}"
        else
          log_step "ROCm device names: (none)"
        fi
        if [ -n "${device_props}" ]; then
          log_step "ROCm device props: ${device_props}"
        fi
        if [ -z "${probe_result}" ]; then
          rocm_fail_reason="rocm_probe_failed"
          continue
        fi

        IFS='|' read -r ver hip cuda_avail cuda_count <<EOF
${probe_result}
EOF
        log_step "ROCm torch version: ${ver}"
        log_step "ROCm torch hip: ${hip}"
        log_step "ROCm torch cuda_available: ${cuda_avail}"
        log_step "ROCm torch cuda_count: ${cuda_count}"

        if printf "%s" "${ver}" | grep -q "+cpu"; then
          log_step "ROCm torch is CPU build (${ver})"
          rocm_fail_reason="rocm_torch_cpu_fallback"
          continue
        fi
        if [ "${hip}" = "None" ] || [ -z "${hip}" ]; then
          log_step "ROCm torch hip missing"
          rocm_fail_reason="rocm_torch_cpu_fallback"
          continue
        fi
        if [ "${cuda_avail}" != "1" ] || [ -z "${cuda_count}" ] || [ "${cuda_count}" = "0" ]; then
          log_step "ROCm torch runtime reports no devices: cuda_available=${cuda_avail} cuda_count=${cuda_count}"
          rocm_fail_reason="rocm_runtime_no_device"
          # ROCm build installed but runtime sees no device; stop trying older indexes.
          break
        fi

        rocm_ok=1
        SELECTED_TORCH_INDEX="${idx}"
        break
      done

      if [ "${rocm_ok}" -ne 1 ]; then
        log_step "ROCm torch install/probe failed; falling back to CPU (reason=${rocm_fail_reason})"
        install_linux_torch_stack "cpu" || true
        PROFILE="linux-cpu"
        BACKEND="cpu"
        BACKEND_REASON="${rocm_fail_reason}"
        PACKAGE="audio-separator==0.23.0"
        CORE_EXTRA=""
      fi
    fi

    TORCH_VER="$("${VENV_PY}" - <<'PY' 2>/dev/null
import torch
print(getattr(torch, "__version__", ""))
PY
)"
    if [ -n "${TORCH_VER}" ]; then
      CONSTRAINTS_FILE="${RUNTIME_BASE}/state/pip_constraints.txt"
      mkdir -p "${RUNTIME_BASE}/state"
      log_step "Pinned torch version for downstream installs: ${TORCH_VER}"
      {
        echo "numpy==${PINNED_NUMPY_VERSION}"
        echo "llvmlite==${PINNED_LLVM_VERSION}"
        echo "numba==${PINNED_NUMBA_VERSION}"
        "${VENV_PY}" - <<'PY' 2>/dev/null
import importlib
for name in ("torch","torchvision","torchaudio"):
    try:
        m = importlib.import_module(name)
        ver = str(getattr(m, "__version__", "")).split("+", 1)[0]
        if ver:
            print(f"{name}=={ver}")
    except Exception:
        pass
PY
      } > "${CONSTRAINTS_FILE}"
      log_step "CUDA/NVIDIA package overrides blocked via constraints"
    fi

    enforce_runtime_python_pins || set_status "deps_failed" "runtime_python_pins_failed"

    log_stage "Installing STEMwerk-core"
    core_install_rc=0
    resolve_core_target || true
    if [ -n "${CORE_TARGET:-}" ]; then
      INSTALL_TARGET="${CORE_TARGET}"
      if [ "${CORE_SUPPORTS_EXTRAS:-0}" -eq 1 ] && [ -n "${CORE_EXTRA}" ]; then
        INSTALL_TARGET="${CORE_TARGET}${CORE_EXTRA}"
      fi
      log_step "Installing stemwerk-core from ${CORE_TARGET_DESC}: ${INSTALL_TARGET}"
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        log_step "Installing stemwerk-core with constraints (torch pinned)"
        "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${INSTALL_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      else
        "${VENV_PY}" -m pip install "${INSTALL_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      fi
    else
      log_step "stemwerk-core source bundle is missing or incomplete"
      log_step "Expected bundle directory: ${CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
      log_step "Required files: pyproject.toml, src/stemwerk_core/__init__.py, src/stemwerk_core/separator.py"
      log_step "Recovery: run STEMwerk-SETUP.lua again after fixing or reinstalling STEMwerk."
      set_status "deps_failed" "stemwerk_core_bundle_incomplete"
      write_state
      exit 1
    fi

    if [ "${core_install_rc}" -ne 0 ] && [ -n "${CORE_EXTRA}" ] && [ "${CORE_SUPPORTS_EXTRAS:-0}" -eq 1 ] && [ -n "${CORE_TARGET:-}" ]; then
      log_step "GPU/ROCm core install failed; falling back to CPU packages"
      CORE_EXTRA=""
      PROFILE="linux-cpu"
      BACKEND="cpu"
      BACKEND_REASON="backend_install_failed"
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        log_step "Installing stemwerk-core with constraints (torch pinned)"
        "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${CORE_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      else
        "${VENV_PY}" -m pip install "${CORE_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      fi
    fi
    if [ "${core_install_rc}" -ne 0 ]; then
      set_status "deps_failed" "stemwerk_core_install_failed"
    fi

    log_stage "Checking/installing audio_separator"
    audio_install_rc=0
    audio_repair_rc=0
    audio_import_rc=0
    audio_repair_attempted=0
    managed_diffq_required=0
    managed_diffq_ready=0
    audio_install_log="${RUNTIME_BASE}/logs/audio_separator_install.log"
    : > "${audio_install_log}" || true
    if is_managed_python_312_linux_x86_64; then
      managed_diffq_required=1
      if install_managed_diffq_wheel; then
        managed_diffq_ready=1
      else
        audio_install_rc=1
      fi
    fi
    "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || audio_import_rc=$?
    if [ "${audio_import_rc}" -ne 0 ] && [ "${audio_install_rc}" -eq 0 ]; then
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        log_step "Installing audio-separator 0.23.0 with constraints (torch pinned)"
        if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
          "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        else
          "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        fi
      else
        if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
          "${VENV_PY}" -m pip install --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        else
          "${VENV_PY}" -m pip install "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        fi
      fi
      cat "${audio_install_log}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    if [ "${audio_install_rc}" -ne 0 ] && [ "${PACKAGE}" != "audio-separator==0.23.0" ]; then
      if detect_build_tools_missing_log "${audio_install_log}"; then
        mark_build_tools_missing
      fi
      log_step "GPU audio-separator install failed; falling back to CPU package"
      PACKAGE="audio-separator==0.23.0"
      PROFILE="linux-cpu"
      BACKEND="cpu"
      BACKEND_REASON="${BACKEND_REASON:-backend_install_failed}"
      audio_install_rc=0
      : > "${audio_install_log}" || true
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
      else
        "${VENV_PY}" -m pip install "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
      fi
      cat "${audio_install_log}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    if [ "${audio_install_rc}" -ne 0 ] && [ "${managed_diffq_required}" -eq 0 ]; then
      if detect_build_tools_missing_log "${audio_install_log}"; then
        mark_build_tools_missing
      fi
      log_step "audio-separator dependency install failed; retrying package install without dependency resolution"
      audio_install_rc=0
      "${VENV_PY}" -m pip install --no-deps "${PACKAGE}" >> "${LOG_FILE}" 2>&1 || audio_install_rc=$?
    elif [ "${audio_install_rc}" -ne 0 ]; then
      log_step "Managed wheel path required for Linux managed Python 3.12; skipping no-deps fallback"
    fi
    if [ "${audio_install_rc}" -eq 0 ]; then
      verify_audio_separator_runtime_deps || audio_install_rc=1
    fi
    if [ "${audio_install_rc}" -ne 0 ]; then
      log_step "audio-separator runtime dependencies incomplete; attempting full dependency repair install"
      audio_repair_attempted=1
      PACKAGE="audio-separator==0.23.0"
      audio_repair_rc=0
      : > "${audio_install_log}" || true
      if [ "${managed_diffq_required}" -eq 1 ]; then
        if install_managed_diffq_wheel; then
          managed_diffq_ready=1
        else
          audio_repair_rc=1
        fi
      fi
      if [ "${audio_repair_rc}" -ne 0 ] && [ "${managed_diffq_required}" -eq 1 ]; then
        log_step "Managed wheel path required for Linux managed Python 3.12; full dependency repair cannot continue without diffq wheel"
      fi
      if [ "${audio_repair_rc}" -eq 0 ]; then
        if [ -n "${CONSTRAINTS_FILE}" ]; then
          if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
            "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          else
            "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          fi
        else
          if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
            "${VENV_PY}" -m pip install --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          else
            "${VENV_PY}" -m pip install "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          fi
        fi
      fi
      cat "${audio_install_log}" >> "${LOG_FILE}" 2>/dev/null || true
      if [ "${audio_repair_rc}" -eq 0 ]; then
        verify_audio_separator_runtime_deps || audio_repair_rc=1
      fi
      audio_install_rc="${audio_repair_rc}"
    fi
    if [ "${audio_install_rc}" -ne 0 ]; then
      if [ "${audio_repair_attempted}" -eq 1 ] && detect_build_tools_missing_log "${audio_install_log}"; then
        mark_build_tools_missing
      fi
      BACKEND_REASON="${BACKEND_REASON:-audio_separator_install_failed}"
      set_status "deps_failed" "audio_separator_install_failed"
    fi
    if [ "${audio_install_rc}" -eq 0 ] && [ "${STATUS}" = "ok" ]; then
      log_stage "Re-applying pinned torch stack"
      case "${BACKEND}" in
        rocm)
          if [ -n "${SELECTED_TORCH_INDEX}" ]; then
            install_linux_torch_stack "rocm" "${SELECTED_TORCH_INDEX}" || set_status "deps_failed" "torch_pin_repair_failed"
          else
            install_linux_torch_stack "cpu" || set_status "deps_failed" "torch_pin_repair_failed"
          fi
          ;;
        cuda)
          install_linux_torch_stack "cuda" || set_status "deps_failed" "torch_pin_repair_failed"
          ;;
        *)
          install_linux_torch_stack "cpu" || set_status "deps_failed" "torch_pin_repair_failed"
          ;;
      esac
      if ! assert_pinned_torch_stack "${VENV_PY}"; then
        set_status "deps_failed" "torch_pin_assert_failed"
      fi
      enforce_runtime_python_pins || set_status "deps_failed" "runtime_python_pins_failed"

      log_stage "Checking/installing ONNX Runtime"
      onnx_install_rc=0
      if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
        log_step "Installing ${ONNX_PACKAGE}"
        if [ -n "${CONSTRAINTS_FILE}" ]; then
          "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1 || onnx_install_rc=$?
        else
          "${VENV_PY}" -m pip install "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1 || onnx_install_rc=$?
        fi
      fi
      if [ "${onnx_install_rc}" -ne 0 ]; then
        set_status "deps_failed" "onnxruntime_install_failed"
      fi
    else
      log_step "Skipping torch pin repair and ONNX install after audio-separator dependency failure"
    fi
  fi
fi

set_progress "3" "${STEP_TOTAL}" "Checking FFmpeg"
log_stage "Checking/installing FFmpeg"
for p in \
  "${RUNTIME_BASE}/bin/ffmpeg" \
  "${RUNTIME_BASE}/ffmpeg/bin/ffmpeg" \
  "/usr/local/bin/ffmpeg" \
  "/usr/bin/ffmpeg" \
  "/snap/bin/ffmpeg"
do
  if [ -x "$p" ]; then
    FFMPEG="$p"
    break
  fi
done

if [ -z "${FFMPEG}" ]; then
  set_status "missing_ffmpeg" "ffmpeg_not_found"
elif ! "${FFMPEG}" -version >/dev/null 2>&1; then
  set_status "ffmpeg_unusable" "ffmpeg_version_check_failed"
fi

if [ -z "${FFMPEG}" ] || ! "${FFMPEG}" -version >/dev/null 2>&1; then
  FINAL_OK=0
fi

set_progress "4" "${STEP_TOTAL}" "Finalizing setup"
RUNTIME_STRICT_OK=1

if [ -n "${PYTHON}" ] && [ -n "${VENV_PY}" ]; then
  log_step "Final verification"
  if ! verify_audio_separator_runtime_deps; then
    set_status "deps_failed" "audio_separator_install_failed"
  fi
  RUNTIME_VERIFY_PROBE=$(STEMWERK_BACKEND="${BACKEND}" "${VENV_PY}" - <<'PY'
import os
import sys
backend = os.environ.get("STEMWERK_BACKEND", "cpu")
errors = []
try:
    import numpy as np
    if int(str(getattr(np, "__version__", "0")).split(".", 1)[0]) >= 2:
        errors.append("numpy_major_gte_2")
except Exception as exc:
    errors.append("numpy_import_failed:" + str(exc))
try:
    import numba  # noqa: F401
except Exception as exc:
    errors.append("numba_import_failed:" + str(exc))
try:
    import audio_separator  # noqa: F401
except Exception as exc:
    errors.append("audio_separator_import_failed:" + str(exc))
for mod_name in (
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
        __import__(mod_name)
    except Exception as exc:
        errors.append("audio_separator_dep_import_failed:" + mod_name + ":" + str(exc))
for mod_name in ("onnxruntime", "stemwerk_core"):
    try:
        __import__(mod_name)
    except Exception as exc:
        errors.append(mod_name + "_import_failed:" + str(exc))
try:
    import torch
    ver = str(getattr(torch, "__version__", "0.0.0")).split("+", 1)[0]
    try:
        major, minor = [int(x) for x in ver.split(".")[:2]]
    except Exception:
        major, minor = 999, 999
    if major > 2 or (major == 2 and minor >= 6):
        errors.append("torch_too_new_for_demucs:" + ver)
    if backend == "rocm":
        hip = getattr(getattr(torch, "version", None), "hip", None)
        if not (hip is not None and torch.cuda.is_available() and int(torch.cuda.device_count()) > 0):
            errors.append("rocm_runtime_probe_failed")
    elif backend == "cuda":
        if not (torch.cuda.is_available() and int(torch.cuda.device_count()) > 0):
            errors.append("cuda_runtime_probe_failed")
except Exception as exc:
    errors.append("torch_import_failed:" + str(exc))
try:
    import torchaudio  # noqa: F401
except Exception as exc:
    errors.append("torchaudio_missing_for_demucs:" + str(exc))
if errors:
    print(";".join(errors))
    sys.exit(1)
print("ok")
PY
)
  if [ $? -ne 0 ]; then
    log_step "Final runtime probe failed: ${RUNTIME_VERIFY_PROBE}"
    set_status "deps_failed" "runtime_verify_failed"
    RUNTIME_STRICT_OK=0
  fi
  if ! "${VENV_PY}" -m pip show audio-separator >/dev/null 2>&1; then
    set_status "audio_separator_check_failed" "audio_separator_missing_after_setup"
  fi
  if ! "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; then
    set_status "audio_separator_check_failed" "audio_separator_import_failed"
  fi
  if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
    set_status "onnxruntime_check_failed" "onnxruntime_missing_after_setup"
  fi
  if ! "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1; then
    set_status "stemwerk_core_check_failed" "stemwerk_core_missing_after_setup"
  fi
  if ! assert_pinned_torch_stack "${VENV_PY}"; then
    set_status "deps_failed" "torch_pin_assert_failed"
  fi
fi

# verify venv runtime is complete (torch backend + audio_separator + onnxruntime + stemwerk_core)
VENV_TORCH_OK=0
VENV_TORCH_PROBE=""
FINAL_OK=0
if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  VENV_TORCH_PROBE=$(STEMWERK_BACKEND="${BACKEND}" "${VENV_PY}" - <<'PY'
import os
backend = os.environ.get("STEMWERK_BACKEND", "cpu")
try:
    import torch
    ver = getattr(torch, "__version__", "unknown")
    core = str(ver).split("+", 1)[0]
    try:
        major, minor = [int(x) for x in core.split(".")[:2]]
    except Exception:
        major, minor = 999, 999
    hip = getattr(getattr(torch, "version", None), "hip", None)
    cuda_avail = torch.cuda.is_available()
    cuda_cnt = torch.cuda.device_count()
    ok = (major, minor) < (2, 6)
    try:
        import torchaudio  # noqa: F401
        torchaudio_present = True
    except Exception:
        torchaudio_present = False
    ok = ok and torchaudio_present
    if backend == "rocm":
        ok = ok and (hip is not None) and cuda_avail and cuda_cnt > 0
    elif backend == "cuda":
        ok = ok and cuda_avail and cuda_cnt > 0
    print("ok=%s|ver=%s|torchaudio=%s|hip=%s|cuda=%s|cnt=%s" % (ok, ver, torchaudio_present, hip, cuda_avail, cuda_cnt))
except Exception as e:
    print("ok=False|err=%s" % e)
PY
)
  if echo "${VENV_TORCH_PROBE}" | grep -q "ok=True"; then
    VENV_TORCH_OK=1
  fi
fi
log_step "Venv torch probe: ${VENV_TORCH_PROBE}"

if [ "${STATUS}" = "ok" ] && \
   [ "${RUNTIME_STRICT_OK}" -eq 1 ] && \
   [ "${AUDIO_SEPARATOR_DEPS_COMPLETE}" = "yes" ] && \
   [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ] && \
   "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 && \
   "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1 && \
   "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1 && \
   [ "${VENV_TORCH_OK}" -eq 1 ]; then
  PYTHON_PATH="${VENV_PY}"
  log_step "Venv runtime verified; PYTHON_PATH set to venv"
  FINAL_OK=1
else
  set_status "deps_failed" "runtime_python_split_brain"
  log_step "Venv runtime incomplete; refusing to set PYTHON_PATH"
  audio_rc="na"
  onnx_rc="na"
  core_rc="na"
  if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
    audio_rc=$("${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; echo $?)
    onnx_rc=$("${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; echo $?)
    core_rc=$("${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1; echo $?)
  fi
  log_step "Venv failure detail: audio_separator=${audio_rc} onnxruntime=${onnx_rc} stemwerk_core=${core_rc} VENV_TORCH_OK=${VENV_TORCH_OK}"
  PYTHON_PATH=""
  FINAL_OK=0
fi

if [ -n "${PYTHON_PATH}" ] && [ "${STATUS}" = "deps_failed" ] && [ "${RUNTIME_STRICT_OK}" -eq 1 ]; then
  log_step "Clearing sticky deps_failed status after successful verification"
  STATUS="ok"
  STATUS_REASON=""
fi

if [ "${FINAL_OK}" -eq 1 ] && [ "${RUNTIME_STRICT_OK}" -eq 1 ] && { [ "${STATUS}" = "ok" ] || [ "${STATUS}" = "deps_failed" ]; }; then
  STATUS="ok"
  STATUS_REASON=""
  log_step "Runtime verification passed."
fi

if [ -n "${STATE_FILE}" ]; then
  log_stage "Writing bootstrap.env"
  write_state
fi

if [ "${STATUS}" != "ok" ]; then
  log "Bootstrap failed with status=${STATUS} reason=${STATUS_REASON}"
  exit 1
fi

log_stage "Bootstrap finished"
log "Bootstrap finished successfully"
exit 0
