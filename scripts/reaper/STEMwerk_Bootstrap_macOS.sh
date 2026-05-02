#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"
MACOS_CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints/macos.txt"

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
      _resolved=$(command -v "$1" 2>/dev/null || true)
      [ -n "${_resolved}" ] || return 1
      case "${_resolved}" in
        /*) resolve_existing_path "${_resolved}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

model_cache_dir() {
  printf "%s/Library/Application Support/STEMwerk/models\n" "${HOME:-/tmp}"
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

remove_incompatible_venv() {
  if [ -d "${RUNTIME_BASE}/.venv" ]; then
    log "Removing incompatible virtual environment: ${RUNTIME_BASE}/.venv"
    rm -rf "${RUNTIME_BASE}/.venv"
  fi
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
  fi
  return 1
}

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
      [ -n "${PYTHON}" ] && echo "PYTHON_PATH=${PYTHON}"
      [ -n "${VENV_PY}" ] && echo "VENV_PYTHON=${VENV_PY}"
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

if [ -z "${RUNTIME_BASE}" ]; then
  echo "Missing runtime base" >&2
  exit 1
fi

log "Bootstrap started"
log "Requested mode: ${MODE}"
log "Downloaded models are kept at: $(model_cache_dir)"
if [ "${MODE}" = "rebuild-venv" ] && [ -d "${RUNTIME_BASE}/.venv" ]; then
  log "Removing requested virtual environment rebuild target: ${RUNTIME_BASE}/.venv"
  rm -rf "${RUNTIME_BASE}/.venv"
fi

mkdir -p "${RUNTIME_BASE}/state" "${RUNTIME_BASE}/logs" "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"

STATUS="ok"
STATUS_REASON=""
PYTHON=""
FFMPEG=""
VENV_PY=""
# Conservative default on macOS to avoid GPU extras with limited wheel support.
PACKAGE="audio-separator==0.23.0"
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
STEP_TOTAL="4"
STEP_LABEL=""
SELECTED_PYTHON_VERSION=""
FIRST_UNSUPPORTED_PYTHON_PATH=""
FIRST_UNSUPPORTED_PYTHON_VERSION=""
SEEN_PYTHON_PATHS="|"

set_progress "1" "${STEP_TOTAL}" "Preparing runtime"

# macOS must not blindly trust bare python3 because Homebrew/system aliases can
# move to 3.13+ while STEMwerk 2.x only supports Python 3.10-3.12.
if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
  if evaluate_python_candidate "${RUNTIME_BASE}/.venv/bin/python"; then
    log "Selected existing virtual environment Python: ${PYTHON} (version ${SELECTED_PYTHON_VERSION})"
  else
    remove_incompatible_venv
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

BREW=""
if [ -x "/opt/homebrew/bin/brew" ]; then
  BREW="/opt/homebrew/bin/brew"
elif [ -x "/usr/local/bin/brew" ]; then
  BREW="/usr/local/bin/brew"
elif command -v brew >/dev/null 2>&1; then
  BREW="$(command -v brew)"
fi

set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"

if [ -z "${PYTHON}" ]; then
  if [ -n "${FIRST_UNSUPPORTED_PYTHON_PATH}" ] && [ -n "${FIRST_UNSUPPORTED_PYTHON_VERSION}" ]; then
    PYTHON_MESSAGE="Detected Python ${FIRST_UNSUPPORTED_PYTHON_VERSION} at ${FIRST_UNSUPPORTED_PYTHON_PATH}, but STEMwerk currently supports Python 3.10-3.12 on macOS. Please install Python 3.11 or 3.12, or let STEMwerk use one if already present."
    log "${PYTHON_MESSAGE}"
    printf "%s\n" "${PYTHON_MESSAGE}" >&2
    set_status "missing_python" "python_unsupported"
  else
    PYTHON_MESSAGE="No supported Python 3.10-3.12 interpreter found on macOS. Please install Python 3.11 or 3.12, or let STEMwerk use one if already present."
    log "${PYTHON_MESSAGE}"
    printf "%s\n" "${PYTHON_MESSAGE}" >&2
    set_status "missing_python" "python_not_found"
  fi
  write_state
  exit 1
else
  if [ ! -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    log "Creating venv with ${PYTHON}"
    "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv" >> "${LOG_FILE}" 2>&1 || set_status "venv_failed" "venv_create_failed"
  fi
  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    log "Installing ${PACKAGE} (conservative default on macOS)"
    "${VENV_PY}" -m pip install --upgrade pip >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    "${VENV_PY}" -m pip install "numpy<2.0" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "numpy_install_failed"

    log "Installing stemwerk-core"
    resolve_core_target || true
    if [ -n "${CORE_TARGET:-}" ]; then
      log "Installing stemwerk-core from ${CORE_TARGET_DESC}: ${CORE_TARGET}"
      if ! "${VENV_PY}" -m pip install "${CORE_TARGET}" >> "${LOG_FILE}" 2>&1; then
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
    "${VENV_PY}" -m pip install --only-binary=:all: "llvmlite==0.42.0" "numba==0.59.1" >> "${LOG_FILE}" 2>&1 || \
      log "WARN: numba/llvmlite wheel install failed; continuing with audio-separator install"

    "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || \
      {
        if [ -f "${MACOS_CONSTRAINTS_FILE}" ]; then
          log "Installing ${PACKAGE} with macOS constraints from ${MACOS_CONSTRAINTS_FILE}"
          "${VENV_PY}" -m pip install -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}" >> "${LOG_FILE}" 2>&1
        else
          "${VENV_PY}" -m pip install "${PACKAGE}" >> "${LOG_FILE}" 2>&1
        fi
      } || set_status "deps_failed" "audio_separator_install_failed"

    if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
      log "Installing ${ONNX_PACKAGE}"
      if ! "${VENV_PY}" -m pip install "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1; then
        if [ -n "${ONNX_FALLBACK_PACKAGE}" ] && [ "${ONNX_FALLBACK_PACKAGE}" != "${ONNX_PACKAGE}" ]; then
          log "WARN: ${ONNX_PACKAGE} install failed; falling back to ${ONNX_FALLBACK_PACKAGE}"
          printf "WARN: %s install failed; falling back to %s\n" "${ONNX_PACKAGE}" "${ONNX_FALLBACK_PACKAGE}" >&2
          "${VENV_PY}" -m pip install "${ONNX_FALLBACK_PACKAGE}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "onnxruntime_install_failed"
        else
          set_status "deps_failed" "onnxruntime_install_failed"
        fi
      fi
    fi
  fi
fi

set_progress "3" "${STEP_TOTAL}" "Checking FFmpeg"

for p in \
  "${RUNTIME_BASE}/bin/ffmpeg" \
  "${RUNTIME_BASE}/ffmpeg/bin/ffmpeg" \
  "/opt/homebrew/bin/ffmpeg" \
  "/usr/local/bin/ffmpeg" \
  "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" \
  "/usr/local/opt/ffmpeg/bin/ffmpeg" \
  "/usr/bin/ffmpeg"
do
  if [ -x "$p" ]; then
    FFMPEG="$p"
    break
  fi
done

if [ -z "${FFMPEG}" ] && [ -n "${BREW}" ]; then
  log "Installing ffmpeg via brew"
  "${BREW}" install ffmpeg >> "${LOG_FILE}" 2>&1 || true
  if [ -x "/opt/homebrew/bin/ffmpeg" ]; then
    FFMPEG="/opt/homebrew/bin/ffmpeg"
  elif [ -x "/usr/local/bin/ffmpeg" ]; then
    FFMPEG="/usr/local/bin/ffmpeg"
  elif [ -x "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" ]; then
    FFMPEG="/opt/homebrew/opt/ffmpeg/bin/ffmpeg"
  elif [ -x "/usr/local/opt/ffmpeg/bin/ffmpeg" ]; then
    FFMPEG="/usr/local/opt/ffmpeg/bin/ffmpeg"
  fi
fi

if [ -z "${FFMPEG}" ]; then
  set_status "missing_ffmpeg" "ffmpeg_not_found"
fi

set_progress "4" "${STEP_TOTAL}" "Finalizing setup"

if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || set_status "audio_separator_check_failed" "audio_separator_import_failed"
  "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1 || set_status "onnxruntime_check_failed" "onnxruntime_missing_after_setup"
  "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1 || set_status "stemwerk_core_check_failed" "stemwerk_core_missing_after_setup"
fi

if [ -n "${STATE_FILE}" ]; then
  write_state
fi

if [ "${STATUS}" != "ok" ]; then
  exit 1
fi
exit 0
