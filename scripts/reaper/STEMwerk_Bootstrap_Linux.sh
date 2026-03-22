#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"

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

log_stage() {
  log "================================================================================"
  log "STAGE: $*"
}

log_step() {
  log " - $*"
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
      [ -n "${BACKEND_NOTE}" ] && echo "BACKEND_NOTE=${BACKEND_NOTE}"
      echo "PYTHON_PATH=${PYTHON_PATH}"
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

resolve_core_target() {
  CORE_TARGET=""
  CORE_TARGET_DESC=""
  CORE_SUPPORTS_EXTRAS=0

  if [ -n "${STEMWERK_CORE_PATH:-}" ] && [ -e "${STEMWERK_CORE_PATH}" ]; then
    if [ -f "${STEMWERK_CORE_PATH}/pyproject.toml" ] && [ -d "${STEMWERK_CORE_PATH}/src/stemwerk_core" ]; then
      CORE_TARGET="${STEMWERK_CORE_PATH}"
      CORE_TARGET_DESC="STEMWERK_CORE_PATH source"
      CORE_SUPPORTS_EXTRAS=1
      return 0
    fi
    case "${STEMWERK_CORE_PATH}" in
      *.whl|*.zip|*.tar.gz)
        CORE_TARGET="${STEMWERK_CORE_PATH}"
        CORE_TARGET_DESC="STEMWERK_CORE_PATH artifact"
        CORE_SUPPORTS_EXTRAS=0
        return 0
        ;;
    esac
    log_step "STEMWERK_CORE_PATH is set but invalid: ${STEMWERK_CORE_PATH}"
  fi

  CORE_BUNDLE_DIR="${STEMWERK_CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
  if [ -d "${CORE_BUNDLE_DIR}" ]; then
    for pattern in "${CORE_BUNDLE_DIR}"/*.whl "${CORE_BUNDLE_DIR}"/*.tar.gz "${CORE_BUNDLE_DIR}"/*.zip; do
      if [ -f "${pattern}" ]; then
        CORE_TARGET="${pattern}"
        CORE_TARGET_DESC="bundled artifact"
        CORE_SUPPORTS_EXTRAS=0
        return 0
      fi
    done
  fi

  return 1
}

if [ -z "${RUNTIME_BASE}" ]; then
  echo "Missing runtime base" >&2
  exit 1
fi

log_stage "Bootstrap started"
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
# Conservative default on Linux to avoid extra GPU deps unless explicitly needed.
PACKAGE="audio-separator"
CORE_EXTRA=""
PROFILE="linux-cpu"
BACKEND="cpu"
BACKEND_REASON=""
BACKEND_NOTE=""
CONSTRAINTS_FILE=""
STEP_INDEX=""
STEP_TOTAL="4"
STEP_LABEL=""

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
  PACKAGE="audio-separator[gpu]"
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

find_pyenv_real() {
  if [ -d "${HOME}/.pyenv/versions" ]; then
    for p in \
      "${HOME}/.pyenv/versions/"*/bin/python3.11 \
      "${HOME}/.pyenv/versions/"*/bin/python3.12 \
      "${HOME}/.pyenv/versions/"*/bin/python3
    do
      if [ -x "$p" ]; then
        PYTHON="$p"
        return 0
      fi
    done
  fi
  return 1
}

if ! find_pyenv_real; then
  for p in \
    "/usr/local/bin/python3.11" \
    "/usr/bin/python3.11" \
    "/usr/local/bin/python3.12" \
    "/usr/bin/python3.12" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3" \
    "/snap/bin/python3"
  do
    if [ -x "$p" ]; then
      PYTHON="$p"
      break
    fi
  done
fi

if [ -z "${PYTHON}" ]; then
  for cmd in python3.11 python3.12 python3; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      candidate="$(command -v "${cmd}")"
      if ! is_pyenv_shim "${candidate}"; then
        PYTHON="${candidate}"
        break
      fi
    fi
  done
fi

if [ -z "${PYTHON}" ] && command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
fi

if [ -n "${PYTHON}" ]; then
  log_step "Using Python: ${PYTHON}"
fi

PKEXEC=""
if [ -x "/usr/bin/pkexec" ]; then
  PKEXEC="/usr/bin/pkexec"
fi

if [ -z "${PYTHON}" ] && [ -n "${PKEXEC}" ]; then
  log_step "Installing python3 via package manager"
  if [ -x "/usr/bin/apt-get" ]; then
    log "Installing python3 via apt-get"
    "${PKEXEC}" /usr/bin/apt-get -y install python3 >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/dnf" ]; then
    log "Installing python3 via dnf"
    "${PKEXEC}" /usr/bin/dnf -y install python3 >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/pacman" ]; then
    log "Installing python via pacman"
    "${PKEXEC}" /usr/bin/pacman -Sy --noconfirm python >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/zypper" ]; then
    log "Installing python3 via zypper"
    "${PKEXEC}" /usr/bin/zypper --non-interactive install python3 >> "${LOG_FILE}" 2>&1 || true
  fi
  if command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
  fi
fi

if [ -z "${PYTHON}" ]; then
  set_status "missing_python" "python_not_found"
else
  log_stage "Creating venv"
  if [ ! -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    log_step "Creating venv at ${RUNTIME_BASE}/.venv"
    "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv" >> "${LOG_FILE}" 2>&1 || set_status "venv_failed" "venv_create_failed"
  fi
  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    log_step "Upgrading pip/setuptools/wheel"
    "${VENV_PY}" -m pip install --upgrade pip setuptools wheel >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    log_step "Selected profile=${PROFILE} backend=${BACKEND}"

    if [ "${BACKEND}" = "cpu" ]; then
      log_stage "Installing CPU torch"
      log_step "Uninstalling existing torch/vision/audio before CPU install"
      "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
      log_step "Torch source index: https://download.pytorch.org/whl/cpu (no extra index; CUDA deps blocked)"
      "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url "https://download.pytorch.org/whl/cpu" torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "torch_cpu_install_failed"
      NVIDIA_PKGS="$("${VENV_PY}" -m pip list 2>/dev/null | awk '/^nvidia-/{print $1"=="$2}')"
      if [ -n "${NVIDIA_PKGS}" ]; then
        log_step "WARNING: NVIDIA packages detected after CPU torch install: ${NVIDIA_PKGS}"
      else
        log_step "No NVIDIA packages detected after CPU torch install"
      fi
      PACKAGE="audio-separator"
      CORE_EXTRA=""
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
        log_step "Uninstalling existing torch/vision/audio before ROCm install"
        "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
        if ! "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url "${idx}" torch torchvision torchaudio >> "${LOG_FILE}" 2>&1; then
          log_step "ROCm torch pip install failed for ${idx}"
          rocm_fail_reason="rocm_wheel_not_found"
          continue
        fi
        NVIDIA_PKGS="$("${VENV_PY}" -m pip list 2>/dev/null | awk '/^nvidia-/{print $1"=="$2}')"
        if [ -n "${NVIDIA_PKGS}" ]; then
          log_step "WARNING: NVIDIA packages detected after ROCm torch install: ${NVIDIA_PKGS}"
        else
          log_step "No NVIDIA packages detected after ROCm torch install"
        fi

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
        break
      done

      if [ "${rocm_ok}" -ne 1 ]; then
        log_step "ROCm torch install/probe failed; falling back to CPU (reason=${rocm_fail_reason})"
        log_step "Torch source index: https://download.pytorch.org/whl/cpu (no extra index; CUDA deps blocked)"
        "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url "https://download.pytorch.org/whl/cpu" torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
        PROFILE="linux-cpu"
        BACKEND="cpu"
        BACKEND_REASON="${rocm_fail_reason}"
        PACKAGE="audio-separator"
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
        echo "torch==${TORCH_VER}"
        "${VENV_PY}" - <<'PY' 2>/dev/null
import importlib
for name in ("torchvision","torchaudio"):
    try:
        m = importlib.import_module(name)
        ver = getattr(m, "__version__", "")
        if ver:
            print(f"{name}=={ver}")
    except Exception:
        pass
PY
      } > "${CONSTRAINTS_FILE}"
      log_step "CUDA/NVIDIA package overrides blocked via constraints"
    fi

    log_step "Installing numpy<2.4"
    "${VENV_PY}" -m pip install "numpy<2.4" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "numpy_install_failed"

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
      log_step "stemwerk-core bundle missing from installer payload"
      log_step "Expected bundle directory: ${CORE_BUNDLE_DIR:-${BUNDLED_CORE_DIR}}"
      core_install_rc=1
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
    if ! "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; then
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        log_step "Installing audio-separator with constraints (torch pinned)"
        "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${LOG_FILE}" 2>&1 || audio_install_rc=$?
      else
        "${VENV_PY}" -m pip install "${PACKAGE}" >> "${LOG_FILE}" 2>&1 || audio_install_rc=$?
      fi
    fi
    if [ "${audio_install_rc}" -ne 0 ] && [ "${PACKAGE}" != "audio-separator" ]; then
      log_step "GPU audio-separator install failed; falling back to CPU package"
      PACKAGE="audio-separator"
      PROFILE="linux-cpu"
      BACKEND="cpu"
      BACKEND_REASON="${BACKEND_REASON:-backend_install_failed}"
      "${VENV_PY}" -m pip install "${PACKAGE}" >> "${LOG_FILE}" 2>&1 || audio_install_rc=$?
    fi
    if [ "${audio_install_rc}" -ne 0 ]; then
      set_status "deps_failed" "audio_separator_install_failed"
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

if [ -z "${FFMPEG}" ] && [ -n "${PKEXEC}" ]; then
  log_step "Installing FFmpeg via package manager"
  if [ -x "/usr/bin/apt-get" ]; then
    log "Installing ffmpeg via apt-get"
    "${PKEXEC}" /usr/bin/apt-get -y install ffmpeg >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/dnf" ]; then
    log "Installing ffmpeg via dnf"
    "${PKEXEC}" /usr/bin/dnf -y install ffmpeg >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/pacman" ]; then
    log "Installing ffmpeg via pacman"
    "${PKEXEC}" /usr/bin/pacman -Sy --noconfirm ffmpeg >> "${LOG_FILE}" 2>&1 || true
  elif [ -x "/usr/bin/zypper" ]; then
    log "Installing ffmpeg via zypper"
    "${PKEXEC}" /usr/bin/zypper --non-interactive install ffmpeg >> "${LOG_FILE}" 2>&1 || true
  fi
  for p in /usr/local/bin/ffmpeg /usr/bin/ffmpeg /snap/bin/ffmpeg; do
    if [ -x "$p" ]; then
      FFMPEG="$p"
      break
    fi
  done
fi

if [ -z "${FFMPEG}" ]; then
  set_status "missing_ffmpeg" "ffmpeg_not_found"
elif ! "${FFMPEG}" -version >/dev/null 2>&1; then
  set_status "ffmpeg_unusable" "ffmpeg_version_check_failed"
fi

if [ -z "${FFMPEG}" ] || ! "${FFMPEG}" -version >/dev/null 2>&1; then
  FINAL_OK=0
fi

set_progress "4" "${STEP_TOTAL}" "Finalizing setup"

if [ -n "${PYTHON}" ] && [ -n "${VENV_PY}" ]; then
  log_step "Final verification"
  if ! "${VENV_PY}" -m pip show audio-separator >/dev/null 2>&1; then
    set_status "audio_separator_check_failed" "audio_separator_missing_after_setup"
  fi
  if ! "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; then
    set_status "audio_separator_check_failed" "audio_separator_import_failed"
  fi
  if ! "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1; then
    set_status "stemwerk_core_check_failed" "stemwerk_core_missing_after_setup"
  fi
fi

# verify venv runtime is complete (torch backend + audio_separator + stemwerk_core)
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
    hip = getattr(getattr(torch, "version", None), "hip", None)
    cuda_avail = torch.cuda.is_available()
    cuda_cnt = torch.cuda.device_count()
    ok = True
    if backend == "rocm":
        ok = (hip is not None) and cuda_avail and cuda_cnt > 0
    elif backend == "cuda":
        ok = cuda_avail and cuda_cnt > 0
    else:
        ok = True
    print("ok=%s|ver=%s|hip=%s|cuda=%s|cnt=%s" % (ok, ver, hip, cuda_avail, cuda_cnt))
except Exception as e:
    print("ok=False|err=%s" % e)
PY
)
  if echo "${VENV_TORCH_PROBE}" | grep -q "ok=True"; then
    VENV_TORCH_OK=1
  fi
fi
log_step "Venv torch probe: ${VENV_TORCH_PROBE}"

if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ] && \
   "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 && \
   "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1 && \
   [ "${VENV_TORCH_OK}" -eq 1 ]; then
  PYTHON_PATH="${VENV_PY}"
  log_step "Venv runtime verified; PYTHON_PATH set to venv"
  FINAL_OK=1
else
  set_status "deps_failed" "runtime_python_split_brain"
  log_step "Venv runtime incomplete; refusing to set PYTHON_PATH"
  audio_rc="na"
  core_rc="na"
  if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
    audio_rc=$("${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; echo $?)
    core_rc=$("${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1; echo $?)
  fi
  log_step "Venv failure detail: audio_separator=${audio_rc} stemwerk_core=${core_rc} VENV_TORCH_OK=${VENV_TORCH_OK}"
  PYTHON_PATH=""
  FINAL_OK=0
fi

if [ -n "${PYTHON_PATH}" ] && [ "${STATUS}" = "deps_failed" ]; then
  log_step "Clearing sticky deps_failed status after successful verification"
  STATUS="ok"
  STATUS_REASON=""
fi

if [ "${FINAL_OK}" -eq 1 ] && { [ "${STATUS}" = "ok" ] || [ "${STATUS}" = "deps_failed" ]; }; then
  STATUS="ok"
  STATUS_REASON=""
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
