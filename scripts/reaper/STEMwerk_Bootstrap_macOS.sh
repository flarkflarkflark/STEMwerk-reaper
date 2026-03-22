#!/bin/sh
set -u

RUNTIME_BASE=""
STATE_FILE=""
LOG_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-base) RUNTIME_BASE="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
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

if [ -z "${RUNTIME_BASE}" ]; then
  echo "Missing runtime base" >&2
  exit 1
fi

mkdir -p "${RUNTIME_BASE}/state" "${RUNTIME_BASE}/logs" "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"

STATUS="ok"
STATUS_REASON=""
PYTHON=""
FFMPEG=""
VENV_PY=""
# Conservative default on macOS to avoid GPU extras with limited wheel support.
PACKAGE="audio-separator==0.14.5"
PROFILE="mac-cpu"
BACKEND="cpu"
BACKEND_REASON=""
STEP_INDEX=""
STEP_TOTAL="4"
STEP_LABEL=""

set_progress "1" "${STEP_TOTAL}" "Preparing runtime"

for p in \
  "${RUNTIME_BASE}/.venv/bin/python" \
  "/opt/homebrew/opt/python@3.11/libexec/bin/python3" \
  "/usr/local/opt/python@3.11/libexec/bin/python3" \
  "/opt/homebrew/opt/python@3.12/libexec/bin/python3" \
  "/usr/local/opt/python@3.12/libexec/bin/python3" \
  "/opt/homebrew/bin/python3.11" \
  "/usr/local/bin/python3.11" \
  "/opt/homebrew/bin/python3" \
  "/usr/local/bin/python3" \
  "/usr/bin/python3"
do
  if [ -x "$p" ]; then
    PYTHON="$p"
    break
  fi
done

BREW=""
if [ -x "/opt/homebrew/bin/brew" ]; then
  BREW="/opt/homebrew/bin/brew"
elif [ -x "/usr/local/bin/brew" ]; then
  BREW="/usr/local/bin/brew"
elif command -v brew >/dev/null 2>&1; then
  BREW="$(command -v brew)"
fi

if [ -z "${PYTHON}" ] && [ -n "${BREW}" ]; then
  log "Installing python@3.11 via brew"
  "${BREW}" install python@3.11 >> "${LOG_FILE}" 2>&1 || true
  if [ -x "/opt/homebrew/opt/python@3.11/libexec/bin/python3" ]; then
    PYTHON="/opt/homebrew/opt/python@3.11/libexec/bin/python3"
  elif [ -x "/usr/local/opt/python@3.11/libexec/bin/python3" ]; then
    PYTHON="/usr/local/opt/python@3.11/libexec/bin/python3"
  elif [ -x "/opt/homebrew/bin/python3.11" ]; then
    PYTHON="/opt/homebrew/bin/python3.11"
  elif [ -x "/usr/local/bin/python3.11" ]; then
    PYTHON="/usr/local/bin/python3.11"
  fi
fi

set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"

if [ -z "${PYTHON}" ]; then
  set_status "missing_python" "python_not_found"
else
  if [ ! -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    log "Creating venv"
    "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv" >> "${LOG_FILE}" 2>&1 || set_status "venv_failed" "venv_create_failed"
  fi
  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    log "Installing ${PACKAGE} (conservative default on macOS)"
    "${VENV_PY}" -m pip install --upgrade pip >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    "${VENV_PY}" -m pip install "numpy<2.4" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "numpy_install_failed"

    log "Installing stemwerk-core"
    CORE_PATH=""
    if [ -n "${STEMWERK_CORE_PATH:-}" ] && [ -f "${STEMWERK_CORE_PATH}/pyproject.toml" ] && [ -d "${STEMWERK_CORE_PATH}/src/stemwerk_core" ]; then
      CORE_PATH="${STEMWERK_CORE_PATH}"
    fi

    if [ -n "${CORE_PATH}" ]; then
      log "Installing stemwerk-core from ${CORE_PATH}"
      "${VENV_PY}" -m pip install "${CORE_PATH}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "stemwerk_core_install_failed"
    else
      log "Local stemwerk-core not found, trying pip install"
      "${VENV_PY}" -m pip install "stemwerk-core" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "stemwerk_core_missing"
    fi

    "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || \
      "${VENV_PY}" -m pip install "${PACKAGE}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "audio_separator_install_failed"
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

if [ -n "${STATE_FILE}" ]; then
  write_state
fi

if [ "${STATUS}" != "ok" ]; then
  exit 1
fi
exit 0
