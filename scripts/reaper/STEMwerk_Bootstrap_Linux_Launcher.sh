#!/bin/sh
set -u

RUNTIME_BASE=""
STATE_FILE=""
LOG_FILE=""
PID_FILE=""
BOOTSTRAP_SCRIPT=""
MODE="repair"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-base) RUNTIME_BASE="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --pid-file) PID_FILE="$2"; shift 2 ;;
    --bootstrap-script) BOOTSTRAP_SCRIPT="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP_SCRIPT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "${LOG_FILE}" ]; then
  LOG_FILE="/dev/null"
fi

log() {
  printf "%s\n" "$*" >> "${LOG_FILE}"
}

set_status() {
  if [ -n "${STATE_FILE}" ]; then
    {
      echo "STATUS=$1"
      [ -n "${2:-}" ] && echo "STATUS_REASON=$2"
      [ -n "${3:-}" ] && echo "STEP_INDEX=$3"
      [ -n "${4:-}" ] && echo "STEP_TOTAL=$4"
      [ -n "${5:-}" ] && echo "STEP_LABEL=$5"
    } > "${STATE_FILE}"
  fi
}

log "Launcher started"
log "Launcher PID: $$"
log "Bootstrap script: ${BOOTSTRAP_SCRIPT}"
log "Requested mode: ${MODE}"
log "State file: ${STATE_FILE}"
log "PID file: ${PID_FILE}"

set_status "running" "launcher_started" "1" "5" "Launching bootstrap"

if [ -z "${BOOTSTRAP_SCRIPT}" ] || [ ! -f "${BOOTSTRAP_SCRIPT}" ]; then
  log "Launcher error: bootstrap script missing"
  set_status "bootstrap_launch_failed" "bootstrap_script_missing" "1" "5" "Launching bootstrap"
  exit 1
fi

if [ -z "${PID_FILE}" ]; then
  log "Launcher error: pid file missing"
  set_status "bootstrap_launch_failed" "pidfile_missing" "1" "5" "Launching bootstrap"
  exit 1
fi

/bin/sh "${BOOTSTRAP_SCRIPT}" \
  --runtime-base "${RUNTIME_BASE}" \
  --state-file "${STATE_FILE}" \
  --log-file "${LOG_FILE}" \
  --mode "${MODE}" >> "${LOG_FILE}" 2>&1 &

CHILD_PID=$!
if [ -z "${CHILD_PID}" ]; then
  log "Launcher error: failed to start bootstrap"
  set_status "bootstrap_launch_failed" "spawn_failed" "1" "5" "Launching bootstrap"
  exit 1
fi

echo "${CHILD_PID}" > "${PID_FILE}" 2>/dev/null || {
  log "Launcher error: failed to write pid file"
  set_status "bootstrap_launch_failed" "pidfile_write_failed" "1" "5" "Launching bootstrap"
  exit 1
}

log "Launcher started bootstrap pid=${CHILD_PID}"
exit 0
