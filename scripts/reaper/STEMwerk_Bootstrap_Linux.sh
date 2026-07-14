#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"
BUNDLED_PAYLOAD_DIR="${SCRIPT_DIR}/_bundled"
PINNED_TORCH_VERSION="2.5.1"
PINNED_TORCHAUDIO_VERSION="2.5.1"
PINNED_TORCHVISION_VERSION="0.20.1"
PINNED_AUDIO_SEPARATOR_VERSION="0.44.3"
ROCM7_GFX1201_TORCH_VERSION="2.10.0"
ROCM7_GFX1201_TORCHAUDIO_VERSION="2.10.0"
ROCM7_GFX1201_TORCHVISION_VERSION="0.25.0"
PINNED_NUMPY_VERSION="2.4.4"
PINNED_SCIPY_VERSION="1.18.0"
PINNED_NUMBA_VERSION="0.66.0"
PINNED_LLVM_VERSION="0.48.0"
PINNED_BEARTYPE_VERSION="0.18.5"
PINNED_IMAGEIO_FFMPEG_VERSION="0.6.0"
DRUMSEP_AUDIO_SEPARATOR_VERSION="0.34.1"
DRUMSEP_NUMPY_VERSION="2.4.6"
DRUMSEP_ONNXRUNTIME_VERSION="1.26.0"
DRUMSEP_ONNX_VERSION="1.21.0"
DRUMSEP_ONNX2TORCH_VERSION="1.5.15"
DRUMSEP_ONNX2TORCH_PY313_VERSION="1.6.0"
DRUMSEP_TORCH_VERSION="2.12.0"
DRUMSEP_TORCHVISION_VERSION="0.27.0"
DRUMSEP_NUMBA_VERSION="0.65.1"
DRUMSEP_ROCM_TORCH_VERSION="2.9.1+rocm6.4"
DRUMSEP_ROCM_TORCHVISION_VERSION="0.24.1+rocm6.4"
DRUMSEP_ROCM_TORCHAUDIO_VERSION="2.9.1+rocm6.4"
DRUMSEP_ROCM_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm6.4"
DRUMSEP_ROCM7_GFX1201_TORCH_VERSION="2.10.0+rocm7.0"
DRUMSEP_ROCM7_GFX1201_TORCHVISION_VERSION="0.25.0+rocm7.0"
DRUMSEP_ROCM7_GFX1201_TORCHAUDIO_VERSION="2.10.0+rocm7.0"
DRUMSEP_ROCM7_GFX1201_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm7.0"
DRUMSEP_ROCM_MIN_FREE_GB="20"
DRUMSEP_MODEL_FILE="aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
DRUMSEP_MODEL_YAML="aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"

RUNTIME_BASE=""
STATE_FILE=""
LOG_FILE=""
MODE="repair"
CORE_MODEL_PREFETCH_STATUS="missing"
CORE_MODEL_PREFETCH_DETAIL=""

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

bundled_main_wheelhouse_dir() {
  if [ -d "${BUNDLED_PAYLOAD_DIR}/wheels/main" ]; then
    printf "%s/wheels/main\n" "${BUNDLED_PAYLOAD_DIR}"
    return 0
  fi
  return 1
}

bundled_drumsep_wheelhouse_dir() {
  if [ -d "${BUNDLED_PAYLOAD_DIR}/drumsep-wheels" ]; then
    printf "%s/drumsep-wheels\n" "${BUNDLED_PAYLOAD_DIR}"
    return 0
  fi
  return 1
}

append_find_links_args() {
  _scope="$1"
  shift
  _dirs=""
  case "${_scope}" in
    main)
      _dir="$(bundled_main_wheelhouse_dir || true)"
      [ -n "${_dir}" ] && _dirs="${_dir}"
      ;;
    drumsep)
      _dir="$(bundled_drumsep_wheelhouse_dir || true)"
      [ -n "${_dir}" ] && _dirs="${_dir}"
      ;;
  esac
  if [ -z "${_dirs}" ]; then
    return 0
  fi
  set -- "$@" --no-index --find-links "${_dirs}"
  printf "%s\n" "$*"
}

pip_install_with_scope() {
  _scope="$1"
  _py="$2"
  shift 2
  _dir=""
  case "${_scope}" in
    main) _dir="$(bundled_main_wheelhouse_dir || true)" ;;
    drumsep) _dir="$(bundled_drumsep_wheelhouse_dir || true)" ;;
  esac
  if [ -n "${_dir}" ]; then
    "${_py}" -m pip install --no-index --find-links "${_dir}" "$@"
    return $?
  fi
  "${_py}" -m pip install "$@"
}

copy_bundled_models_to_cache() {
  _src_dir="$1"
  _dest_dir="${2:-$(model_cache_dir)}"
  [ -d "${_src_dir}" ] || return 0
  mkdir -p "${_dest_dir}" >/dev/null 2>&1 || return 1
  find "${_src_dir}" -maxdepth 1 -type f | while read -r _file; do
    cp -f "${_file}" "${_dest_dir}/"
  done
}

ready_to_go_state_file() {
  printf "%s/state/ready_to_go.env\n" "${RUNTIME_BASE}"
}

ready_to_go_output_file() {
  case "${STATE_FILE:-}" in
    */ready_to_go.env|ready_to_go.env)
      printf "%s\n" "${STATE_FILE}"
      ;;
    *)
      ready_to_go_state_file
      ;;
  esac
}

main_runtime_python() {
  printf "%s/.venv/bin/python\n" "${RUNTIME_BASE}"
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
  copy_bundled_models_to_cache "${BUNDLED_PAYLOAD_DIR}/models" "${_model_dir}" || return 1
  _status="$(verify_core_model_cache "${_model_dir}")"
  case "${_status}" in
    *$'\nfast=ok'$'\n'*$'quality=ok'$'\n'*$'sixstem=ok'*|*fast=ok*quality=ok*sixstem=ok*)
      log_step "Core model cache already present: ${_model_dir}"
      return 0
      ;;
  esac
  "${_py}" - <<PY >> "${LOG_FILE}" 2>&1
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
  copy_bundled_models_to_cache "${BUNDLED_PAYLOAD_DIR}/drumsep-models" "${_model_dir}" || return 1
  "${_py}" - <<PY >> "${LOG_FILE}" 2>&1
import importlib.util
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
if not ok:
    raise SystemExit(str(detail or "drumsep_prefetch_failed"))
print("STEMWERK_DRUMSEP_MODEL_PREFETCH ok")
PY
}

write_ready_to_go_state() {
  _runtime_kind="${1:-unknown}"
  _runtime_status="${2:-missing}"
  _drumsep_model_status="${3:-missing}"
  _detail="${4:-}"
  _main_runtime_status="${5:-ok}"
  _core_prefetch_status="${6:-${CORE_MODEL_PREFETCH_STATUS:-missing}}"
  _core_prefetch_detail="${7:-${CORE_MODEL_PREFETCH_DETAIL:-}}"
  _out_file="$(ready_to_go_output_file)"
  _core="$(verify_core_model_cache)"
  _model_dir="$(printf "%s\n" "${_core}" | awk -F= '/^model_dir=/{print $2; exit}')"
  _fast="$(printf "%s\n" "${_core}" | awk -F= '/^fast=/{print $2; exit}')"
  _quality="$(printf "%s\n" "${_core}" | awk -F= '/^quality=/{print $2; exit}')"
  _sixstem="$(printf "%s\n" "${_core}" | awk -F= '/^sixstem=/{print $2; exit}')"
  _ready="ok"
  case "${_main_runtime_status}" in
    broken|verify_failed|runtime_verify_failed) _ready="broken" ;;
    ok) ;;
    *) _ready="missing" ;;
  esac
  case "${_runtime_status}" in
    ok|skipped) ;;
    broken|load_failed|verify_failed|install_failed|disk_space_insufficient)
      _ready="broken"
      ;;
    *)
      if [ "${_ready}" = "ok" ]; then
        _ready="missing"
      fi
      ;;
  esac
  if [ "${_drumsep_model_status}" != "ok" ]; then
    if [ "${_ready}" = "ok" ]; then
      _ready="missing"
    fi
  fi
  if [ "${_fast}" != "ok" ] || [ "${_quality}" != "ok" ] || [ "${_sixstem}" != "ok" ]; then
    if [ "${_core_prefetch_status}" != "skipped" ] && [ "${_ready}" = "ok" ]; then
      _ready="missing"
    fi
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
    echo "CORE_MODEL_PREFETCH_STATUS=${_core_prefetch_status}"
    echo "CORE_MODEL_PREFETCH_DETAIL=${_core_prefetch_detail}"
    echo "DRUMSEP_READY_RUNTIME=${_runtime_kind}"
    echo "DRUMSEP_READY_RUNTIME_STATUS=${_runtime_status}"
    echo "DRUMSEP_READY_MODEL_STATUS=${_drumsep_model_status}"
  } > "${_out_file}"
  log_step "ready_to_go_state_file=${_out_file}"
  log_step "ready_to_go_state_written=1"
  log_step "ready_to_go_status=${_ready}"
}

probe_main_runtime_ready() {
  _py="${1:-$(main_runtime_python)}"
  _backend="${2:-${BACKEND:-cpu}}"
  [ -x "${_py}" ] || {
    printf "missing|python_missing"
    return 1
  }
  _probe="$(STEMWERK_BACKEND="${_backend}" "${_py}" - <<'PY' 2>/dev/null || true
import os

backend = os.environ.get("STEMWERK_BACKEND", "cpu")
errors = []
for mod_name in ("audio_separator", "onnxruntime", "stemwerk_core", "torchaudio"):
    try:
        __import__(mod_name)
    except Exception as exc:
        errors.append(mod_name + "_import_failed:" + str(exc))
try:
    import torch
    ver = str(getattr(torch, "__version__", "0.0.0"))
    core = ver.split("+", 1)[0]
    try:
        major, minor = [int(x) for x in core.split(".")[:2]]
    except Exception:
        major, minor = 999, 999
    hip = getattr(getattr(torch, "version", None), "hip", None)
    cuda_available = bool(torch.cuda.is_available())
    cuda_count = int(torch.cuda.device_count()) if cuda_available else 0
    names = []
    if cuda_available:
        for idx in range(cuda_count):
            try:
                names.append(str(torch.cuda.get_device_name(idx)))
            except Exception:
                pass
    dev_text = "|".join(names).lower()
    allow_rocm7_gfx1201 = (
        backend == "rocm"
        and (major, minor) == (2, 10)
        and hip is not None
        and cuda_available
        and cuda_count > 0
        and ("rx 9070" in dev_text or "gfx1201" in dev_text)
    )
    if (major > 2 or (major == 2 and minor >= 6)) and not allow_rocm7_gfx1201:
        errors.append("torch_too_new_for_demucs:" + ver)
    if backend == "rocm" and not (hip is not None and cuda_available and cuda_count > 0):
        errors.append("rocm_runtime_probe_failed")
    if backend == "cuda" and not (cuda_available and cuda_count > 0):
        errors.append("cuda_runtime_probe_failed")
except Exception as exc:
    errors.append("torch_import_failed:" + str(exc))
if errors:
    print("broken|" + ";".join(errors))
else:
    print("ok")
PY
)"
  case "${_probe}" in
    ok)
      log_step "Main runtime ready probe passed: ${_py}"
      printf "ok"
      return 0
      ;;
    broken\|*)
      log_step "Main runtime ready probe failed: ${_probe#broken|}"
      printf "%s" "${_probe}"
      return 1
      ;;
    *)
      log_step "Main runtime ready probe could not determine status"
      printf "broken|probe_failed"
      return 1
      ;;
  esac
}

load_ready_runtime_state() {
  _kind="${1:-cpu}"
  if [ "${_kind}" = "rocm" ] && [ -f "$(drumsep_rocm_state_file)" ]; then
    READY_RUNTIME_KIND="rocm"
    READY_RUNTIME_STATUS="$(awk -F= '/^DRUMSEP_ROCM_RUNTIME_STATUS=/{print $2; exit} /^STATUS=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
    READY_DRUMSEP_MODEL_STATUS="$(awk -F= '/^DRUMSEP_ROCM_MODEL_STATUS=/{print $2; exit} /^DRUMSEP_MODEL_STATUS=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
    READY_DETAIL="$(awk -F= '/^DRUMSEP_ROCM_RUNTIME_DETAIL=/{print $2; exit} /^STATUS_REASON=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
    return 0
  fi
  if [ -f "$(drumsep_state_file)" ]; then
    READY_RUNTIME_KIND="cpu"
    READY_RUNTIME_STATUS="$(awk -F= '/^DRUMSEP_RUNTIME_STATUS=/{print $2; exit} /^STATUS=/{print $2; exit}' "$(drumsep_state_file)")"
    READY_DRUMSEP_MODEL_STATUS="$(awk -F= '/^DRUMSEP_MODEL_STATUS=/{print $2; exit}' "$(drumsep_state_file)")"
    READY_DETAIL="$(awk -F= '/^DRUMSEP_RUNTIME_DETAIL=/{print $2; exit} /^STATUS_REASON=/{print $2; exit}' "$(drumsep_state_file)")"
    return 0
  fi
  return 1
}

verify_existing_ready_runtime() {
  _preferred="${1:-cpu}"
  if [ "${_preferred}" = "rocm" ]; then
    if verify_drumsep_rocm_runtime; then
      load_ready_runtime_state "rocm"
      return 0
    fi
    if verify_drumsep_runtime; then
      load_ready_runtime_state "cpu"
      return 0
    fi
    load_ready_runtime_state "rocm" || load_ready_runtime_state "cpu" || true
    return 1
  fi
  if verify_drumsep_runtime; then
    load_ready_runtime_state "cpu"
    return 0
  fi
  if verify_drumsep_rocm_runtime; then
    load_ready_runtime_state "rocm"
    return 0
  fi
  load_ready_runtime_state "cpu" || load_ready_runtime_state "rocm" || true
  return 1
}

run_ready_to_go_verify_only() {
  STEP_TOTAL="3"
  set_progress "1" "${STEP_TOTAL}" "Preparing ready-to-go verify"
  READY_RUNTIME_KIND="cpu"
  READY_RUNTIME_STATUS="missing"
  READY_DRUMSEP_MODEL_STATUS="missing"
  READY_DETAIL=""
  MAIN_READY_STATUS="missing"
  MAIN_READY_DETAIL="python_missing"
  READY_BACKEND="cpu"
  if [ "${BACKEND}" = "rocm" ]; then
    READY_BACKEND="rocm"
  fi

  set_progress "2" "${STEP_TOTAL}" "Verifying existing runtimes"
  _main_probe="$(probe_main_runtime_ready "$(main_runtime_python)" "${BACKEND}")"
  if [ "${_main_probe}" = "ok" ]; then
    MAIN_READY_STATUS="ok"
    MAIN_READY_DETAIL="main_runtime_ok"
  else
    case "${_main_probe}" in
      missing\|*)
        MAIN_READY_STATUS="missing"
        MAIN_READY_DETAIL="${_main_probe#missing|}"
        ;;
      broken\|*)
        MAIN_READY_STATUS="broken"
        MAIN_READY_DETAIL="${_main_probe#broken|}"
        ;;
      *)
        MAIN_READY_STATUS="broken"
        MAIN_READY_DETAIL="${_main_probe}"
        ;;
    esac
  fi

  verify_existing_ready_runtime "${READY_BACKEND}" || true
  if [ -z "${READY_DETAIL}" ]; then
    READY_DETAIL="${MAIN_READY_DETAIL}"
  elif [ "${MAIN_READY_STATUS}" != "ok" ]; then
    READY_DETAIL="main_runtime_${MAIN_READY_STATUS}:${MAIN_READY_DETAIL};drumsep:${READY_DETAIL}"
  fi

  set_progress "3" "${STEP_TOTAL}" "Writing ready-to-go state"
  if [ "${MAIN_READY_STATUS}" = "ok" ] && [ "${READY_RUNTIME_STATUS}" = "ok" ]; then
    STATUS="ok"
    STATUS_REASON=""
  else
    STATUS="deps_failed"
    STATUS_REASON="ready_to_go_verify_only"
    RUNTIME_VERIFY_DETAIL="${READY_DETAIL}"
    PYTHON_PATH=""
  fi
  READY_STATE_FILE="$(ready_to_go_output_file)"
  write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "${MAIN_READY_STATUS}"
  if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" = "${READY_STATE_FILE}" ]; then
    log_step "ready_to_go_state_persists_in_state_file=1"
    STATE_FILE=""
  fi
  if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" != "${READY_STATE_FILE}" ]; then
    log_stage "Writing bootstrap.env"
    write_state
  fi
  if [ "${MAIN_READY_STATUS}" = "ok" ] && [ "${READY_RUNTIME_STATUS}" = "ok" ]; then
    log_stage "Ready-to-go verify finished"
    log "Ready-to-go verify finished successfully"
    exit 0
  fi
  log "Ready-to-go verify finished with status=${MAIN_READY_STATUS} detail=${READY_DETAIL}"
  exit 1
}

drumsep_state_file() {
  printf "%s/state/drumsep_runtime.env\n" "${RUNTIME_BASE}"
}

drumsep_log_file() {
  printf "%s/logs/drumsep_install.log\n" "${RUNTIME_BASE}"
}

drumsep_runtime_python() {
  printf "%s/.venv-drumsep/bin/python\n" "${RUNTIME_BASE}"
}

drumsep_rocm_state_file() {
  printf "%s/state/drumsep_runtime_rocm.env\n" "${RUNTIME_BASE}"
}

drumsep_rocm_log_file() {
  printf "%s/logs/drumsep_rocm_install.log\n" "${RUNTIME_BASE}"
}

drumsep_rocm_runtime_python() {
  printf "%s/.venv-drumsep-rocm/bin/python\n" "${RUNTIME_BASE}"
}

write_drumsep_state() {
  _status="$1"
  _model_status="${2:-missing}"
  _detail="${3:-}"
  _py="$(drumsep_runtime_python)"
  _state="$(drumsep_state_file)"
  _model_dir="$(model_cache_dir)"
  _model_file="${_model_dir}/${DRUMSEP_MODEL_FILE}"
  _model_yaml="${_model_dir}/${DRUMSEP_MODEL_YAML}"
  _last_check="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"

  _versions=""
  if [ -x "${_py}" ]; then
    _versions="$("${_py}" - <<'PY' 2>/dev/null || true
import importlib.metadata as metadata
for env_key, dist_name in (
    ("DRUMSEP_AUDIO_SEPARATOR_VERSION", "audio-separator"),
    ("DRUMSEP_NUMPY_VERSION", "numpy"),
    ("DRUMSEP_TORCH_VERSION", "torch"),
    ("DRUMSEP_ONNX_VERSION", "onnx"),
    ("DRUMSEP_ONNXRUNTIME_VERSION", "onnxruntime"),
    ("DRUMSEP_ONNX2TORCH_VERSION", "onnx2torch"),
    ("DRUMSEP_ONNX2TORCH_PY313_VERSION", "onnx2torch-py313"),
):
    try:
        value = metadata.version(dist_name)
    except Exception:
        value = ""
    print(f"{env_key}={value}")
PY
)"
  fi

  {
    echo "STATUS=${_status}"
    [ -n "${_detail}" ] && echo "STATUS_REASON=${_detail}"
    echo "DRUMSEP_RUNTIME_STATUS=${_status}"
    [ -n "${_detail}" ] && echo "DRUMSEP_RUNTIME_DETAIL=${_detail}"
    echo "DRUMSEP_PYTHON=${_py}"
    if [ -n "${_versions}" ]; then
      printf "%s\n" "${_versions}"
    else
      echo "DRUMSEP_AUDIO_SEPARATOR_VERSION="
      echo "DRUMSEP_NUMPY_VERSION="
      echo "DRUMSEP_TORCH_VERSION="
      echo "DRUMSEP_ONNX_VERSION="
      echo "DRUMSEP_ONNXRUNTIME_VERSION="
      echo "DRUMSEP_ONNX2TORCH_VERSION="
      echo "DRUMSEP_ONNX2TORCH_PY313_VERSION="
    fi
    echo "DRUMSEP_LAST_CHECK_UTC=${_last_check}"
    echo "DRUMSEP_MODEL_STATUS=${_model_status}"
    echo "DRUMSEP_MODEL_FILE=${_model_file}"
    echo "DRUMSEP_MODEL_YAML=${_model_yaml}"
  } > "${_state}"
}

write_drumsep_rocm_state() {
  _status="$1"
  _model_status="${2:-missing}"
  _detail="${3:-}"
  _py="$(drumsep_rocm_runtime_python)"
  _state="$(drumsep_rocm_state_file)"
  _model_dir="$(model_cache_dir)"
  _model_file="${_model_dir}/${DRUMSEP_MODEL_FILE}"
  _model_yaml="${_model_dir}/${DRUMSEP_MODEL_YAML}"
  _last_check="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
  _tmp_dir="${DRUMSEP_ROCM_TMPDIR:-}"

  _versions=""
  if [ -x "${_py}" ]; then
    _versions="$("${_py}" - <<'PY' 2>/dev/null || true
import importlib.metadata as metadata
for env_key, dist_name in (
    ("DRUMSEP_ROCM_AUDIO_SEPARATOR_VERSION", "audio-separator"),
    ("DRUMSEP_ROCM_NUMPY_VERSION", "numpy"),
    ("DRUMSEP_ROCM_TORCH_VERSION", "torch"),
    ("DRUMSEP_ROCM_ONNX_VERSION", "onnx"),
    ("DRUMSEP_ROCM_ONNXRUNTIME_VERSION", "onnxruntime"),
    ("DRUMSEP_ROCM_ONNX2TORCH_VERSION", "onnx2torch"),
):
    try:
        value = metadata.version(dist_name)
    except Exception:
        value = ""
    print(f"{env_key}={value}")
PY
)"
  fi

  _gpu_probe=""
  if [ -x "${_py}" ]; then
    _gpu_probe="$("${_py}" - <<'PY' 2>/dev/null || true
import json
try:
    import torch
    hip = str(getattr(getattr(torch, "version", None), "hip", "") or "")
    avail = bool(torch.cuda.is_available())
    names = []
    if avail:
        for i in range(int(torch.cuda.device_count())):
            try:
                names.append(str(torch.cuda.get_device_name(i)))
            except Exception:
                pass
    print(json.dumps({
        "hip": hip,
        "cuda_available": avail,
        "device_names": names,
    }))
except Exception:
    print("{}")
PY
)"
  fi
  _hip=""
  _cuda_available="false"
  _device_names=""
  if [ -n "${_gpu_probe}" ]; then
    _hip="$(printf "%s" "${_gpu_probe}" | sed -n 's/.*"hip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n1)"
    if printf "%s" "${_gpu_probe}" | grep -q '"cuda_available"[[:space:]]*:[[:space:]]*true'; then
      _cuda_available="true"
    fi
    _device_names="$(printf "%s" "${_gpu_probe}" | sed -n 's/.*"device_names"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' | tail -n1 | tr -d '"' | tr ',' '|' | tr -d ' ')"
  fi

  {
    echo "STATUS=${_status}"
    [ -n "${_detail}" ] && echo "STATUS_REASON=${_detail}"
    echo "DRUMSEP_ROCM_RUNTIME_STATUS=${_status}"
    [ -n "${_detail}" ] && echo "DRUMSEP_ROCM_RUNTIME_DETAIL=${_detail}"
    echo "DRUMSEP_ROCM_PYTHON=${_py}"
    if [ -n "${_versions}" ]; then
      printf "%s\n" "${_versions}"
    else
      echo "DRUMSEP_ROCM_AUDIO_SEPARATOR_VERSION="
      echo "DRUMSEP_ROCM_NUMPY_VERSION="
      echo "DRUMSEP_ROCM_TORCH_VERSION="
      echo "DRUMSEP_ROCM_ONNX_VERSION="
      echo "DRUMSEP_ROCM_ONNXRUNTIME_VERSION="
      echo "DRUMSEP_ROCM_ONNX2TORCH_VERSION="
    fi
    echo "DRUMSEP_ROCM_TORCH_HIP=${_hip}"
    echo "DRUMSEP_ROCM_CUDA_AVAILABLE=${_cuda_available}"
    echo "DRUMSEP_ROCM_DEVICE_NAMES=${_device_names}"
    echo "DRUMSEP_ROCM_LAST_CHECK_UTC=${_last_check}"
    echo "DRUMSEP_ROCM_MODEL_STATUS=${_model_status}"
    echo "DRUMSEP_ROCM_MODEL_FILE=${_model_file}"
    echo "DRUMSEP_ROCM_MODEL_YAML=${_model_yaml}"
    echo "DRUMSEP_ROCM_TEMP_DIR=${_tmp_dir}"
  } > "${_state}"
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
      [ -n "${DRUMSEP_STEP_INDEX}" ] && echo "DRUMSEP_STEP_INDEX=${DRUMSEP_STEP_INDEX}"
      [ -n "${DRUMSEP_STEP_TOTAL}" ] && echo "DRUMSEP_STEP_TOTAL=${DRUMSEP_STEP_TOTAL}"
      [ -n "${DRUMSEP_STEP_LABEL}" ] && echo "DRUMSEP_STEP_LABEL=${DRUMSEP_STEP_LABEL}"
      [ -n "${PROFILE}" ] && echo "PROFILE=${PROFILE}"
      [ -n "${BACKEND}" ] && echo "BACKEND=${BACKEND}"
      [ -n "${BACKEND_REASON}" ] && echo "BACKEND_REASON=${BACKEND_REASON}"
      [ -n "${BACKEND_NOTE}" ] && echo "BACKEND_NOTE=${BACKEND_NOTE}"
      [ -n "${SELECTED_TORCH_INDEX}" ] && echo "SELECTED_TORCH_INDEX=${SELECTED_TORCH_INDEX}"
      [ -n "${SELECTED_TORCH_STACK}" ] && echo "SELECTED_TORCH_STACK=${SELECTED_TORCH_STACK}"
      [ -n "${ROCM_DETECTED_DEVICES}" ] && echo "ROCM_DETECTED_DEVICES=${ROCM_DETECTED_DEVICES}"
      [ -n "${ROCM_SELECTED_DEVICE}" ] && echo "ROCM_SELECTED_DEVICE=${ROCM_SELECTED_DEVICE}"
      [ -n "${ROCM_FALLBACK_REASON}" ] && echo "ROCM_FALLBACK_REASON=${ROCM_FALLBACK_REASON}"
      [ -n "${TORCH_RUNTIME_POLICY}" ] && echo "TORCH_RUNTIME_POLICY=${TORCH_RUNTIME_POLICY}"
      [ -n "${RUNTIME_VERIFY_DETAIL}" ] && echo "RUNTIME_VERIFY_DETAIL=${RUNTIME_VERIFY_DETAIL}"
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
  _os_name="${OS_NAME:-}"
  if [ -z "${_os_name}" ]; then
    _os_name="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  fi
  _arch="${ARCH:-}"
  if [ -z "${_arch}" ]; then
    _arch="$(uname -m 2>/dev/null)"
  fi
  [ "${_os_name}" = "linux" ] || return 1
  [ "${_arch}" = "x86_64" ] || return 1
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
    "${BUNDLED_PAYLOAD_DIR}/wheels/main" \
    "${SCRIPT_DIR}/../../installer/linux/payload/wheels/linux-x86_64-cp312" \
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
  "${VENV_PY}" -m pip install --no-deps "${diffq_wheel}" >> "${LOG_FILE}" 2>&1
}

resolve_managed_ffmpeg_from_venv() {
  [ -n "${VENV_PY:-}" ] || return 1
  [ -x "${VENV_PY}" ] || return 1
  "${VENV_PY}" - <<'PY' 2>/dev/null
import os
try:
    import imageio_ffmpeg
    exe = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    raise SystemExit(1)
if exe and os.path.isfile(exe) and os.access(exe, os.X_OK):
    print(exe)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

install_managed_ffmpeg() {
  [ -n "${VENV_PY:-}" ] || return 1
  [ -x "${VENV_PY}" ] || return 1
  log_step "System FFmpeg missing; installing managed FFmpeg runtime (imageio-ffmpeg==${PINNED_IMAGEIO_FFMPEG_VERSION})"
  if [ -n "${CONSTRAINTS_FILE:-}" ]; then
    "${VENV_PY}" -m pip install -c "${CONSTRAINTS_FILE}" "imageio-ffmpeg==${PINNED_IMAGEIO_FFMPEG_VERSION}" >> "${LOG_FILE}" 2>&1 || return 1
  else
    "${VENV_PY}" -m pip install "imageio-ffmpeg==${PINNED_IMAGEIO_FFMPEG_VERSION}" >> "${LOG_FILE}" 2>&1 || return 1
  fi
  return 0
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

clear_drumsep_substep_state() {
  DRUMSEP_STEP_INDEX=""
  DRUMSEP_STEP_TOTAL=""
  DRUMSEP_STEP_LABEL=""
}

set_drumsep_substep_progress() {
  _drumsep_idx="$1"
  _drumsep_total="$2"
  _drumsep_label="$3"
  if [ "${MODE}" = "drumsep-runtime" ]; then
    set_progress "${_drumsep_idx}" "${_drumsep_total}" "${_drumsep_label}"
    return 0
  fi
  DRUMSEP_STEP_INDEX="${_drumsep_idx}"
  DRUMSEP_STEP_TOTAL="${_drumsep_total}"
  DRUMSEP_STEP_LABEL="${_drumsep_label}"
  log "DRUMSEP STEP ${DRUMSEP_STEP_INDEX}/${DRUMSEP_STEP_TOTAL}: ${DRUMSEP_STEP_LABEL}"
  write_state
}

select_drumsep_rocm_torch_stack() {
  DRUMSEP_ACTIVE_ROCM_TORCH_VERSION="${DRUMSEP_ROCM_TORCH_VERSION}"
  DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION="${DRUMSEP_ROCM_TORCHVISION_VERSION}"
  DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION="${DRUMSEP_ROCM_TORCHAUDIO_VERSION}"
  DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL="${DRUMSEP_ROCM_TORCH_INDEX_URL}"
  DRUMSEP_ACTIVE_ROCM_STACK_POLICY="rocm6_4_default"
  _device_probe_py="$(main_runtime_python)"
  if [ -x "${_device_probe_py}" ]; then
    _gpu_probe="$("${_device_probe_py}" - <<'PY' 2>/dev/null || true
try:
    import torch
    hip = str(getattr(getattr(torch, "version", None), "hip", "") or "")
    cuda_available = bool(torch.cuda.is_available())
    device_count = int(torch.cuda.device_count()) if cuda_available else 0
    names = []
    if cuda_available:
        for i in range(device_count):
            try:
                names.append(str(torch.cuda.get_device_name(i)))
            except Exception:
                pass
    print(f"hip={hip}")
    print(f"cuda_available={'yes' if cuda_available else 'no'}")
    print(f"device_count={device_count}")
    print(f"device_names={'|'.join(names)}")
except Exception:
    pass
PY
)"
    _hip="$(printf "%s\n" "${_gpu_probe}" | awk -F= '/^hip=/{print $2; exit}')"
    _cuda_available="$(printf "%s\n" "${_gpu_probe}" | awk -F= '/^cuda_available=/{print $2; exit}')"
    _device_count="$(printf "%s\n" "${_gpu_probe}" | awk -F= '/^device_count=/{print $2; exit}')"
    _device_names="$(printf "%s\n" "${_gpu_probe}" | awk -F= '/^device_names=/{print $2; exit}')"
    if [ -n "${_hip}" ] && [ "${_cuda_available}" = "yes" ] && [ "${_device_count:-0}" -gt 0 ] \
      && printf "%s\n" "${_device_names}" | grep -Eiq "rx 9070|gfx1201"; then
      DRUMSEP_ACTIVE_ROCM_TORCH_VERSION="${DRUMSEP_ROCM7_GFX1201_TORCH_VERSION}"
      DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION="${DRUMSEP_ROCM7_GFX1201_TORCHVISION_VERSION}"
      DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION="${DRUMSEP_ROCM7_GFX1201_TORCHAUDIO_VERSION}"
      DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL="${DRUMSEP_ROCM7_GFX1201_TORCH_INDEX_URL}"
      DRUMSEP_ACTIVE_ROCM_STACK_POLICY="rocm7_gfx1201_align_main_runtime"
    fi
  fi
  log_step "drumsep_rocm_stack_policy=${DRUMSEP_ACTIVE_ROCM_STACK_POLICY}"
  log_step "drumsep_rocm_torch_index=${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}"
  log_step "drumsep_rocm_torch_stack=torch==${DRUMSEP_ACTIVE_ROCM_TORCH_VERSION} torchvision==${DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION} torchaudio==${DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION}"
}

verify_drumsep_runtime() {
  _py="$(drumsep_runtime_python)"
  _model_dir="$(model_cache_dir)"
  _model_file="${_model_dir}/${DRUMSEP_MODEL_FILE}"
  _model_yaml="${_model_dir}/${DRUMSEP_MODEL_YAML}"
  if [ ! -x "${_py}" ]; then
    write_drumsep_state "missing" "missing" "python_missing"
    return 1
  fi
  "${_py}" - <<PY >> "$(drumsep_log_file)" 2>&1
import importlib
import importlib.metadata as metadata
import os
import sys

expected = {
    "audio-separator": "${DRUMSEP_AUDIO_SEPARATOR_VERSION}",
    "numpy": "${DRUMSEP_NUMPY_VERSION}",
    "torch": "${DRUMSEP_TORCH_VERSION}",
    "onnx": "${DRUMSEP_ONNX_VERSION}",
    "onnxruntime": "${DRUMSEP_ONNXRUNTIME_VERSION}",
    "onnx2torch": "${DRUMSEP_ONNX2TORCH_VERSION}",
    "onnx2torch-py313": "${DRUMSEP_ONNX2TORCH_PY313_VERSION}",
    "numba": "${DRUMSEP_NUMBA_VERSION}",
    "torchvision": "${DRUMSEP_TORCHVISION_VERSION}",
}
modules = ["audio_separator", "numpy", "torch", "onnx", "onnxruntime", "onnx2torch"]
errors = []
for module_name in modules:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        errors.append(f"import_failed:{module_name}:{type(exc).__name__}:{exc}")

for dist_name, wanted in expected.items():
    try:
        found = metadata.version(dist_name).split("+", 1)[0]
    except Exception as exc:
        errors.append(f"version_missing:{dist_name}:{type(exc).__name__}:{exc}")
        continue
    if found != wanted:
        errors.append(f"version_mismatch:{dist_name}:expected={wanted}:found={found}")

model_file = "${_model_file}"
model_yaml = "${_model_yaml}"
if not os.path.isfile(model_file) or not os.path.isfile(model_yaml):
    print("DRUMSEP_VERIFY model_missing")
    raise SystemExit(2)

if errors:
    print("DRUMSEP_VERIFY broken " + ";".join(errors))
    raise SystemExit(1)

try:
    import torch
    torch.cuda.is_available = lambda: False
    from audio_separator.separator import Separator
    sep = Separator(model_file_dir="${_model_dir}", output_dir=".", output_format="wav")
    sep.load_model("${DRUMSEP_MODEL_FILE}")
except Exception as exc:
    print(f"DRUMSEP_VERIFY load_failed {type(exc).__name__}: {exc}")
    raise SystemExit(3)

print("DRUMSEP_VERIFY ok")
PY
  _rc=$?
  case "${_rc}" in
    0)
      write_drumsep_state "ok" "ok" "ok"
      return 0
      ;;
    2)
      write_drumsep_state "model_missing" "missing" "model_missing"
      return 1
      ;;
    3)
      write_drumsep_state "broken" "load_failed" "model_load_failed"
      return 1
      ;;
    *)
      write_drumsep_state "broken" "missing" "verify_failed"
      return 1
      ;;
  esac
}

free_kb_for_path() {
  _path="$1"
  df -Pk "${_path}" 2>/dev/null | awk 'NR==2{print $4}'
}

resolve_drumsep_rocm_tmpdir() {
  _required_kb="$1"
  for _cand in \
    "/mnt/PRODUCTION/TMP/stemwerk-rocm-tmp" \
    "${RUNTIME_BASE}/tmp/stemwerk-rocm-tmp" \
    "${HOME:-/tmp}/.cache/STEMwerk/tmp/stemwerk-rocm-tmp"
  do
    _parent="$(dirname "${_cand}")"
    mkdir -p "${_parent}" >/dev/null 2>&1 || true
    mkdir -p "${_cand}" >/dev/null 2>&1 || continue
    if [ ! -w "${_cand}" ]; then
      continue
    fi
    _avail_kb="$(free_kb_for_path "${_cand}")"
    if [ -n "${_avail_kb}" ] && [ "${_avail_kb}" -ge "${_required_kb}" ]; then
      printf "%s\n" "${_cand}"
      return 0
    fi
  done
  return 1
}

drumsep_rocm_disk_preflight() {
  _required_kb="$((DRUMSEP_ROCM_MIN_FREE_GB * 1024 * 1024))"
  _target_dir="${RUNTIME_BASE}"
  _target_avail_kb="$(free_kb_for_path "${_target_dir}")"
  _target_avail_gb="0"
  if [ -n "${_target_avail_kb}" ]; then
    _target_avail_gb=$(( _target_avail_kb / 1024 / 1024 ))
  fi
  log_step "ROCm disk preflight target=${_target_dir} free_gb=${_target_avail_gb} required_gb=${DRUMSEP_ROCM_MIN_FREE_GB}"
  if [ -z "${_target_avail_kb}" ] || [ "${_target_avail_kb}" -lt "${_required_kb}" ]; then
    DRUMSEP_ROCM_PREFLIGHT_DETAIL="target_free_space_insufficient"
    return 1
  fi

  DRUMSEP_ROCM_TMPDIR="$(resolve_drumsep_rocm_tmpdir "${_required_kb}" || true)"
  if [ -z "${DRUMSEP_ROCM_TMPDIR}" ]; then
    DRUMSEP_ROCM_PREFLIGHT_DETAIL="temp_dir_free_space_insufficient"
    return 1
  fi
  _tmp_avail_kb="$(free_kb_for_path "${DRUMSEP_ROCM_TMPDIR}")"
  _tmp_avail_gb=$(( _tmp_avail_kb / 1024 / 1024 ))
  log_step "ROCm disk preflight tmp=${DRUMSEP_ROCM_TMPDIR} free_gb=${_tmp_avail_gb} required_gb=${DRUMSEP_ROCM_MIN_FREE_GB}"
  return 0
}

verify_drumsep_rocm_runtime() {
  _py="$(drumsep_rocm_runtime_python)"
  _model_dir="$(model_cache_dir)"
  _model_file="${_model_dir}/${DRUMSEP_MODEL_FILE}"
  _model_yaml="${_model_dir}/${DRUMSEP_MODEL_YAML}"
  if [ ! -x "${_py}" ]; then
    write_drumsep_rocm_state "missing" "missing" "python_missing"
    return 1
  fi
  "${_py}" - <<PY >> "$(drumsep_rocm_log_file)" 2>&1
import importlib
import importlib.metadata as metadata
import os
import sys

expected = {
    "audio-separator": "${DRUMSEP_AUDIO_SEPARATOR_VERSION}",
    "numpy": "${DRUMSEP_NUMPY_VERSION}",
    "onnxruntime": "${DRUMSEP_ONNXRUNTIME_VERSION}",
    "onnx": "${DRUMSEP_ONNX_VERSION}",
    "onnx2torch": "${DRUMSEP_ONNX2TORCH_VERSION}",
    "numba": "${DRUMSEP_NUMBA_VERSION}",
}
modules = ["audio_separator", "numpy", "torch", "onnx", "onnxruntime", "onnx2torch"]
errors = []
for module_name in modules:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        errors.append(f"import_failed:{module_name}:{type(exc).__name__}:{exc}")

for dist_name, wanted in expected.items():
    try:
        found = metadata.version(dist_name).split("+", 1)[0]
    except Exception as exc:
        errors.append(f"version_missing:{dist_name}:{type(exc).__name__}:{exc}")
        continue
    if found != wanted:
        errors.append(f"version_mismatch:{dist_name}:expected={wanted}:found={found}")

try:
    import torch
    torch_ver = str(getattr(torch, "__version__", ""))
    hip = getattr(getattr(torch, "version", None), "hip", None)
    cuda_available = bool(torch.cuda.is_available())
    device_count = int(torch.cuda.device_count()) if cuda_available else 0
    names = []
    if cuda_available:
        for i in range(device_count):
            try:
                names.append(str(torch.cuda.get_device_name(i)))
            except Exception:
                pass
except Exception as exc:
    errors.append(f"torch_probe_failed:{type(exc).__name__}:{exc}")
    torch_ver = ""
    hip = None
    cuda_available = False
    device_count = 0
    names = []

if "+rocm" not in torch_ver:
    errors.append(f"rocm_torch_required:found={torch_ver}")
if hip is None or str(hip).strip() == "":
    errors.append("rocm_hip_missing")
if not cuda_available:
    errors.append("rocm_cuda_unavailable")
if device_count <= 0:
    errors.append("rocm_no_device")
if not any(("amd" in n.lower() or "radeon" in n.lower() or "rx " in n.lower()) for n in names):
    errors.append("rocm_amd_device_missing")

model_file = "${_model_file}"
model_yaml = "${_model_yaml}"
if not os.path.isfile(model_file) or not os.path.isfile(model_yaml):
    print("DRUMSEP_ROCM_VERIFY model_missing")
    raise SystemExit(2)

if errors:
    print("DRUMSEP_ROCM_VERIFY broken " + ";".join(errors))
    raise SystemExit(1)

try:
    from audio_separator.separator import Separator
    sep = Separator(model_file_dir="${_model_dir}", output_dir=".", output_format="wav")
    sep.load_model("${DRUMSEP_MODEL_FILE}")
except Exception as exc:
    print(f"DRUMSEP_ROCM_VERIFY load_failed {type(exc).__name__}: {exc}")
    raise SystemExit(3)

print("DRUMSEP_ROCM_VERIFY ok")
PY
  _rc=$?
  case "${_rc}" in
    0)
      write_drumsep_rocm_state "ok" "ok" "ok"
      return 0
      ;;
    2)
      write_drumsep_rocm_state "model_missing" "missing" "model_missing"
      return 1
      ;;
    3)
      write_drumsep_rocm_state "broken" "load_failed" "model_load_failed"
      return 1
      ;;
    *)
      write_drumsep_rocm_state "broken" "missing" "verify_failed"
      return 1
      ;;
  esac
}

install_drumsep_rocm_runtime() {
  _log="$(drumsep_rocm_log_file)"
  _py="$(drumsep_rocm_runtime_python)"
  : > "${_log}" || true
  log_stage "Installing optional DrumSep ROCm runtime"
  log_step "DrumSep ROCm runtime path: ${RUNTIME_BASE}/.venv-drumsep-rocm"
  log_step "DrumSep ROCm install log: ${_log}"

  # Repair path: if runtime already exists and verifies, succeed without reinstall.
  if [ -x "${_py}" ]; then
    log_step "Existing DrumSep ROCm runtime detected; running verification before reinstall"
    if verify_drumsep_rocm_runtime; then
      log_step "Existing DrumSep ROCm runtime verified; skipping reinstall"
      return 0
    fi
    log_step "Existing DrumSep ROCm runtime failed verification; rebuilding"
  fi

  if ! drumsep_rocm_disk_preflight; then
    log_step "ROCm preflight failed: ${DRUMSEP_ROCM_PREFLIGHT_DETAIL:-unknown}"
    write_drumsep_rocm_state "disk_space_insufficient" "missing" "${DRUMSEP_ROCM_PREFLIGHT_DETAIL:-disk_space_insufficient}"
    return 1
  fi
  log_step "ROCm temp dir selected: ${DRUMSEP_ROCM_TMPDIR}"
  export TMPDIR="${DRUMSEP_ROCM_TMPDIR}"

  STEP_TOTAL="5"
  select_drumsep_rocm_torch_stack
  set_progress "1" "${STEP_TOTAL}" "Creating DrumSep ROCm runtime"
  rm -rf "${RUNTIME_BASE}/.venv-drumsep-rocm"
  if ! "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv-drumsep-rocm" >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "venv_create_failed"
    return 1
  fi
  if [ ! -x "${_py}" ]; then
    write_drumsep_rocm_state "install_failed" "missing" "python_missing_after_create"
    return 1
  fi

  set_progress "2" "${STEP_TOTAL}" "Upgrading ROCm runtime pip"
  if ! pip_install_with_scope drumsep "${_py}" --no-cache-dir --upgrade pip setuptools wheel >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "pip_upgrade_failed"
    return 1
  fi

  set_progress "3" "${STEP_TOTAL}" "Installing ROCm torch stack"
  if ! pip_install_with_scope drumsep "${_py}" --no-cache-dir --index-url "${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}" \
    "torch==${DRUMSEP_ACTIVE_ROCM_TORCH_VERSION}" \
    "torchvision==${DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION}" \
    "torchaudio==${DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION}" >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "rocm_torch_install_failed"
    return 1
  fi

  set_progress "4" "${STEP_TOTAL}" "Installing DrumSep packages"
  if ! pip_install_with_scope drumsep "${_py}" --no-cache-dir --no-deps \
    "audio-separator==${DRUMSEP_AUDIO_SEPARATOR_VERSION}" >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "audio_separator_install_failed"
    return 1
  fi
  if ! pip_install_with_scope drumsep "${_py}" --no-cache-dir \
    "numpy==${DRUMSEP_NUMPY_VERSION}" \
    "onnxruntime==${DRUMSEP_ONNXRUNTIME_VERSION}" \
    "onnx==${DRUMSEP_ONNX_VERSION}" \
    "onnx2torch==${DRUMSEP_ONNX2TORCH_VERSION}" \
    "onnx2torch-py313==${DRUMSEP_ONNX2TORCH_PY313_VERSION}" \
    "numba==${DRUMSEP_NUMBA_VERSION}" \
    "beartype==0.18.5" "diffq==0.2.4" "einops==0.8.2" "julius==0.2.7" \
    "librosa==0.11.0" "ml_collections==1.1.0" "pydub==0.25.1" "pyyaml==6.0.3" \
    "requests==2.34.2" "resampy==0.4.3" "rotary-embedding-torch==0.6.5" \
    "samplerate==0.1.0" "scipy==1.17.1" "six==1.17.0" "tqdm==4.67.3" >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "package_install_failed"
    return 1
  fi
  if ! "${_py}" -m pip check >> "${_log}" 2>&1; then
    write_drumsep_rocm_state "install_failed" "missing" "pip_check_failed"
    return 1
  fi

  set_progress "5" "${STEP_TOTAL}" "Verifying DrumSep ROCm runtime"
  if ! ensure_drumsep_assets "${_py}" "$(model_cache_dir)"; then
    write_drumsep_rocm_state "install_failed" "missing" "model_download_failed"
    return 1
  fi
  if ! verify_drumsep_rocm_runtime; then
    return 1
  fi
  log_step "DrumSep ROCm runtime verification complete"
  return 0
}

install_drumsep_runtime() {
  _drumsep_log="$(drumsep_log_file)"
  _drumsep_py="$(drumsep_runtime_python)"
  _drumsep_step_total="4"
  : > "${_drumsep_log}" || true
  log_stage "Installing optional DrumSep runtime"
  log_step "DrumSep runtime path: ${RUNTIME_BASE}/.venv-drumsep"
  log_step "DrumSep install log: ${_drumsep_log}"
  if [ -x "${_drumsep_py}" ]; then
    log_step "Existing DrumSep runtime detected; running verification before reinstall"
    if verify_drumsep_runtime; then
      log_step "Existing DrumSep runtime verified; skipping reinstall"
      return 0
    fi
    log_step "Existing DrumSep runtime failed verification; rebuilding"
  fi
  clear_drumsep_substep_state
  set_drumsep_substep_progress "1" "${_drumsep_step_total}" "Creating DrumSep runtime"
  rm -rf "${RUNTIME_BASE}/.venv-drumsep"
  if ! "${PYTHON}" -m venv "${RUNTIME_BASE}/.venv-drumsep" >> "${_drumsep_log}" 2>&1; then
    write_drumsep_state "install_failed" "missing" "venv_create_failed"
    return 1
  fi
  if [ ! -x "${_drumsep_py}" ]; then
    write_drumsep_state "install_failed" "missing" "python_missing_after_create"
    return 1
  fi

  set_drumsep_substep_progress "2" "${_drumsep_step_total}" "Upgrading DrumSep pip"
  if ! pip_install_with_scope drumsep "${_drumsep_py}" --upgrade pip setuptools wheel >> "${_drumsep_log}" 2>&1; then
    write_drumsep_state "install_failed" "missing" "pip_upgrade_failed"
    return 1
  fi

  set_drumsep_substep_progress "3" "${_drumsep_step_total}" "Installing DrumSep packages"
  if ! pip_install_with_scope drumsep "${_drumsep_py}" \
    "audio-separator==${DRUMSEP_AUDIO_SEPARATOR_VERSION}" \
    "numpy==${DRUMSEP_NUMPY_VERSION}" \
    "onnxruntime==${DRUMSEP_ONNXRUNTIME_VERSION}" \
    "onnx==${DRUMSEP_ONNX_VERSION}" \
    "onnx2torch==${DRUMSEP_ONNX2TORCH_VERSION}" \
    "onnx2torch-py313==${DRUMSEP_ONNX2TORCH_PY313_VERSION}" \
    "torch==${DRUMSEP_TORCH_VERSION}" \
    "torchvision==${DRUMSEP_TORCHVISION_VERSION}" \
    "numba==${DRUMSEP_NUMBA_VERSION}" >> "${_drumsep_log}" 2>&1; then
    write_drumsep_state "install_failed" "missing" "package_install_failed"
    return 1
  fi

  set_drumsep_substep_progress "4" "${_drumsep_step_total}" "Verifying DrumSep runtime"
  if ! ensure_drumsep_assets "${_drumsep_py}" "$(model_cache_dir)"; then
    write_drumsep_state "install_failed" "missing" "model_download_failed"
    return 1
  fi
  if ! verify_drumsep_runtime; then
    return 1
  fi
  log_step "DrumSep runtime verification complete"
  return 0
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
      log_step "Existing venv has incompatible torch ${_probe#rebuild|}; rebuilding .venv for audio-separator ${PINNED_AUDIO_SEPARATOR_VERSION} compatibility"
      return 0
      ;;
    ok\|*)
      log_step "Existing venv torch is compatible: ${_probe#ok|}"
      ;;
  esac
  return 1
}

linux_torch_install_args() {
  printf 'torch==%s torchvision==%s torchaudio==%s' \
    "${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}" \
    "${ACTIVE_TORCHVISION_VERSION:-${PINNED_TORCHVISION_VERSION}}" \
    "${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}"
}

bundled_main_has_required_torch_stack() {
  _dir="$(bundled_main_wheelhouse_dir || true)"
  [ -n "${_dir}" ] || return 1
  [ -f "${_dir}/torch-${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}-"*.whl ] || return 1
  [ -f "${_dir}/torchvision-${ACTIVE_TORCHVISION_VERSION:-${PINNED_TORCHVISION_VERSION}}-"*.whl ] || return 1
  [ -f "${_dir}/torchaudio-${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}-"*.whl ] || return 1
  return 0
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
  _pip_rc=1
  TORCH_STACK_INSTALLED_THIS_RUN=0
  log_step "Uninstalling existing torch/vision/audio before ${_mode} torch install"
  "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
  case "${_mode}" in
    cpu)
      log_step "Torch source index: https://download.pytorch.org/whl/cpu (torch/torchaudio pinned to ${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}})"
      if bundled_main_has_required_torch_stack; then
        pip_install_with_scope main "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir $(linux_torch_install_args) >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      else
        log_step "Bundled main wheelhouse does not contain the requested torch stack; using CPU index fallback"
        eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url https://download.pytorch.org/whl/cpu $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      fi
      ;;
    rocm)
      log_step "Torch source index: ${_index} (torch/torchaudio pinned to ${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}})"
      if bundled_main_has_required_torch_stack; then
        pip_install_with_scope main "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir $(linux_torch_install_args) >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      else
        log_step "Bundled main wheelhouse does not contain the requested torch stack; using ROCm index fallback"
        eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir --index-url \"${_index}\" $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      fi
      ;;
    cuda)
      log_step "Torch source index: default pip index (torch/torchaudio pinned to ${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}})"
      if bundled_main_has_required_torch_stack; then
        pip_install_with_scope main "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir $(linux_torch_install_args) >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      else
        log_step "Bundled main wheelhouse does not contain the requested torch stack; using default pip index fallback"
        eval "\"${VENV_PY}\" -m pip install --upgrade --force-reinstall --no-cache-dir $(linux_torch_install_args)" >> "${LOG_FILE}" 2>&1
        _pip_rc=$?
      fi
      ;;
    *)
      return 1
      ;;
  esac
  if [ "${_pip_rc}" -ne 0 ]; then
    log_step "${_mode} torch pip install failed with exit code ${_pip_rc}"
    return 1
  fi
  enforce_runtime_python_pins || return 1
  if verify_current_torch_stack "${VENV_PY}" "${_mode}" "after_install"; then
    TORCH_STACK_INSTALLED_THIS_RUN=1
    TORCH_STACK_VERIFY_AFTER_INSTALL="ok"
    return 0
  fi
  TORCH_STACK_VERIFY_AFTER_INSTALL="failed"
  return 1
}

assert_pinned_torch_stack() {
  _venv_py="$1"
  _probe="$("${_venv_py}" - <<PY 2>/dev/null || true
expected_torch = "${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}"
expected_torchaudio = "${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}"
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
  printf "STEMwerk bootstrap failed: expected torch=%s and torchaudio=%s after setup.\n" "${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}" "${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}" >&2
  return 1
}

verify_current_torch_stack() {
  _venv_py="$1"
  _backend="$2"
  _label="${3:-current}"
  _probe="$("${_venv_py}" - <<PY 2>/dev/null || true
expected_torch = "${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}"
expected_torchvision = "${ACTIVE_TORCHVISION_VERSION:-${PINNED_TORCHVISION_VERSION}}"
expected_torchaudio = "${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}"
expected_backend = "${_backend}"
def core(ver):
    return str(ver).split("+", 1)[0]
try:
    import torch
    import torchvision
    import torchaudio
except Exception as exc:
    print("error|import|" + str(exc))
    raise SystemExit(0)
torch_ver = getattr(torch, "__version__", "")
torchvision_ver = getattr(torchvision, "__version__", "")
torchaudio_ver = getattr(torchaudio, "__version__", "")
if core(torch_ver) != expected_torch:
    print("bad|torch_version|" + torch_ver)
    raise SystemExit(0)
if core(torchvision_ver) != expected_torchvision:
    print("bad|torchvision_version|" + torchvision_ver)
    raise SystemExit(0)
if core(torchaudio_ver) != expected_torchaudio:
    print("bad|torchaudio_version|" + torchaudio_ver)
    raise SystemExit(0)
hip = getattr(getattr(torch, "version", None), "hip", None)
cuda = getattr(getattr(torch, "version", None), "cuda", None)
if expected_backend == "rocm" and (hip is None or str(hip) == ""):
    print("bad|backend|missing_rocm_hip")
    raise SystemExit(0)
if expected_backend == "cuda" and (cuda is None or str(cuda) == ""):
    print("bad|backend|missing_cuda_version")
    raise SystemExit(0)
print("ok|" + torch_ver + "|" + torchvision_ver + "|" + torchaudio_ver + "|backend=" + expected_backend)
PY
)"
  case "${_probe}" in
    ok\|*)
      log_step "torch_stack_verify_after_install=ok context=${_label} detail=${_probe}"
      return 0
      ;;
  esac
  log_step "torch_stack_verify_after_install=failed context=${_label} detail=${_probe}"
  return 1
}

enforce_runtime_python_pins() {
  if [ -z "${VENV_PY}" ] || [ ! -x "${VENV_PY}" ]; then
    return 1
  fi
  log_step "Enforcing runtime Python deps: numpy==${PINNED_NUMPY_VERSION} scipy==${PINNED_SCIPY_VERSION} numba==${PINNED_NUMBA_VERSION} llvmlite==${PINNED_LLVM_VERSION} beartype==${PINNED_BEARTYPE_VERSION}"
  pip_install_with_scope main "${VENV_PY}" --upgrade --force-reinstall --no-cache-dir \
    "numpy==${PINNED_NUMPY_VERSION}" \
    "scipy==${PINNED_SCIPY_VERSION}" \
    "llvmlite==${PINNED_LLVM_VERSION}" \
    "beartype==${PINNED_BEARTYPE_VERSION}" \
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
TORCH_STACK_INSTALLED_THIS_RUN=0
TORCH_STACK_VERIFY_AFTER_INSTALL="not_run"
TORCH_PIN_REAPPLY_REASON="not_needed"
PYTHON=""
FFMPEG=""
VENV_PY=""
PYTHON_PATH=""
SUPPORTED_PYTHON_FOUND="no"
DETECTED_PYTHON_VERSION=""
DETECTED_PYTHON_PATH=""
# Conservative default on Linux to avoid extra GPU deps unless explicitly needed.
PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
ONNX_PACKAGE="onnxruntime"
CORE_EXTRA=""
PROFILE="linux-cpu"
BACKEND="cpu"
BACKEND_REASON=""
BACKEND_NOTE=""
BACKEND_DEPS_COMPLETE="unknown"
BACKEND_DEPS_REASON=""
ACTIVE_TORCH_VERSION="${PINNED_TORCH_VERSION}"
ACTIVE_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION}"
ACTIVE_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION}"
SELECTED_TORCH_STACK=""
ROCM_DETECTED_DEVICES=""
ROCM_SELECTED_DEVICE=""
ROCM_FALLBACK_REASON=""
TORCH_RUNTIME_POLICY="service_line_default_torch_lt_2_6"
RUNTIME_VERIFY_DETAIL=""
BUILD_TOOLS_MISSING="no"
AUDIO_SEPARATOR_IMPORT="unknown"
AUDIO_SEPARATOR_DEPS_COMPLETE="unknown"
CONSTRAINTS_FILE=""
SELECTED_TORCH_INDEX=""
STEP_INDEX=""
STEP_TOTAL="5"
STEP_LABEL=""
DRUMSEP_STEP_INDEX=""
DRUMSEP_STEP_TOTAL=""
DRUMSEP_STEP_LABEL=""
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
  PACKAGE="audio-separator[gpu]==${PINNED_AUDIO_SEPARATOR_VERSION}"
  CORE_EXTRA="[gpu]"
  PROFILE="linux-cuda"
  BACKEND="cuda"
elif [ "${ROCM_MODE}" -eq 1 ]; then
  log_step "ROCm detected; enabling ROCm packages"
  CORE_EXTRA="[rocm]"
  PROFILE="linux-rocm"
  BACKEND="rocm"
fi

if [ "${MODE}" = "ready-to-go-verify" ]; then
  run_ready_to_go_verify_only
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
    if [ "${MODE}" = "drumsep-runtime" ]; then
      write_drumsep_state "install_failed" "missing" "python_missing"
      exit 1
    fi
    if [ "${MODE}" = "drumsep-rocm-runtime" ]; then
      write_drumsep_rocm_state "install_failed" "missing" "python_missing"
      exit 1
    fi
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
    if [ "${MODE}" = "drumsep-runtime" ]; then
      write_drumsep_state "install_failed" "missing" "python_missing"
      exit 1
    fi
    if [ "${MODE}" = "drumsep-rocm-runtime" ]; then
      write_drumsep_rocm_state "install_failed" "missing" "python_missing"
      exit 1
    fi
  fi
else
  if [ "${MODE}" = "drumsep-runtime" ]; then
    if install_drumsep_runtime; then
      STATUS="ok"
      STATUS_REASON=""
      write_drumsep_state "ok" "ok" "ok"
      log_stage "DrumSep runtime install finished"
      exit 0
    fi
    log "DrumSep runtime install failed"
    exit 1
  elif [ "${MODE}" = "drumsep-rocm-runtime" ]; then
    if install_drumsep_rocm_runtime; then
      STATUS="ok"
      STATUS_REASON=""
      write_drumsep_rocm_state "ok" "ok" "ok"
      log_stage "DrumSep ROCm runtime install finished"
      exit 0
    fi
    log "DrumSep ROCm runtime install failed"
    exit 1
  fi
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
    set_progress "3" "${STEP_TOTAL}" "Installing STEMwerk runtime"
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    clear_stale_python_backend_reason
    log_step "Upgrading pip/setuptools/wheel"
    pip_install_with_scope main "${VENV_PY}" --upgrade pip setuptools wheel >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    log_step "Selected profile=${PROFILE} backend=${BACKEND}"
    log_step "Installing pinned STEMwerk backend packages..."

    if [ "${BACKEND}" = "cpu" ]; then
      log_stage "Installing CPU torch"
      install_linux_torch_stack "cpu" || set_status "deps_failed" "torch_cpu_install_failed"
      log_nvidia_packages "CPU torch install"
      PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
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
        TORCH_RUNTIME_POLICY="rocm_gfx1201_allow_2_10_rocm7"
        ACTIVE_TORCH_VERSION="${ROCM7_GFX1201_TORCH_VERSION}"
        ACTIVE_TORCHVISION_VERSION="${ROCM7_GFX1201_TORCHVISION_VERSION}"
        ACTIVE_TORCHAUDIO_VERSION="${ROCM7_GFX1201_TORCHAUDIO_VERSION}"
        IDX_LIST="https://download.pytorch.org/whl/rocm7.0 https://download.pytorch.org/whl/rocm7.1 https://download.pytorch.org/whl/rocm7.2"
        case "${ROCM_MM}" in
          7.*)
            IDX_LIST="${IDX_LIST} https://download.pytorch.org/whl/rocm${ROCM_MM}"
            ;;
        esac
      else
        TORCH_RUNTIME_POLICY="service_line_default_torch_lt_2_6"
        ACTIVE_TORCH_VERSION="${PINNED_TORCH_VERSION}"
        ACTIVE_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION}"
        ACTIVE_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION}"
      fi
      if [ "${ROCM_GFX1201}" -eq 1 ]; then
        IDX_LIST="${IDX_LIST}"
      else
        IDX_LIST="${IDX_LIST} https://download.pytorch.org/whl/rocm6.1 https://download.pytorch.org/whl/rocm6.0 https://download.pytorch.org/whl/rocm5.7 https://download.pytorch.org/whl/rocm5.6"
      fi

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
          ROCM_DETECTED_DEVICES="${device_names}"
        else
          log_step "ROCm device names: (none)"
          ROCM_DETECTED_DEVICES=""
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
        if [ "${ROCM_GFX1201}" -eq 1 ]; then
          if printf "%s %s\n" "${device_names}" "${device_props}" | grep -Eiq "rx 9070|gfx1201"; then
            ROCM_SELECTED_DEVICE="rx9070_gfx1201"
          else
            log_step "ROCm runtime probe missing RX 9070/gfx1201 device on gfx1201 machine; rejecting index ${idx}"
            rocm_fail_reason="rocm_gfx1201_device_not_selected"
            continue
          fi
        fi

        rocm_ok=1
        SELECTED_TORCH_INDEX="${idx}"
        SELECTED_TORCH_STACK="torch==${ACTIVE_TORCH_VERSION}+$(basename "${idx}") torchvision==${ACTIVE_TORCHVISION_VERSION}+$(basename "${idx}") torchaudio==${ACTIVE_TORCHAUDIO_VERSION}+$(basename "${idx}")"
        break
      done

      if [ "${rocm_ok}" -ne 1 ]; then
        if [ "${ROCM_GFX1201}" -eq 1 ] && [ "${rocm_fail_reason}" = "rocm_wheel_not_found" ]; then
          rocm_fail_reason="rocm7_stack_unavailable_for_gfx1201"
        fi
        ROCM_FALLBACK_REASON="${rocm_fail_reason}"
        log_step "ROCm torch install/probe failed; falling back to CPU (reason=${rocm_fail_reason})"
        ACTIVE_TORCH_VERSION="${PINNED_TORCH_VERSION}"
        ACTIVE_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION}"
        ACTIVE_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION}"
        install_linux_torch_stack "cpu" || true
        TORCH_RUNTIME_POLICY="service_line_default_torch_lt_2_6"
        PROFILE="linux-cpu"
        BACKEND="cpu"
        BACKEND_REASON="${rocm_fail_reason}"
        PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
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
        echo "scipy==${PINNED_SCIPY_VERSION}"
        echo "llvmlite==${PINNED_LLVM_VERSION}"
        echo "beartype==${PINNED_BEARTYPE_VERSION}"
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
        pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${INSTALL_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      else
        pip_install_with_scope main "${VENV_PY}" "${INSTALL_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
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
        pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${CORE_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
      else
        pip_install_with_scope main "${VENV_PY}" "${CORE_TARGET}" >> "${LOG_FILE}" 2>&1 || core_install_rc=$?
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
        log_step "Installing audio-separator ${PINNED_AUDIO_SEPARATOR_VERSION} with constraints (torch pinned)"
        if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
          pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        else
          pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        fi
      else
        if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
          pip_install_with_scope main "${VENV_PY}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        else
          pip_install_with_scope main "${VENV_PY}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
        fi
      fi
      cat "${audio_install_log}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    if [ "${audio_install_rc}" -ne 0 ] && [ "${PACKAGE}" != "audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}" ]; then
      if detect_build_tools_missing_log "${audio_install_log}"; then
        mark_build_tools_missing
      fi
      log_step "GPU audio-separator install failed; falling back to CPU package"
      PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
      PROFILE="linux-cpu"
      BACKEND="cpu"
      BACKEND_REASON="${BACKEND_REASON:-backend_install_failed}"
      audio_install_rc=0
      : > "${audio_install_log}" || true
      if [ -n "${CONSTRAINTS_FILE}" ]; then
        pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
      else
        pip_install_with_scope main "${VENV_PY}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_install_rc=$?
      fi
      cat "${audio_install_log}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    if [ "${audio_install_rc}" -ne 0 ] && [ "${managed_diffq_required}" -eq 0 ]; then
      if detect_build_tools_missing_log "${audio_install_log}"; then
        mark_build_tools_missing
      fi
      log_step "audio-separator dependency install failed; no --no-deps fallback is allowed for the NumPy 2 runtime"
    elif [ "${audio_install_rc}" -ne 0 ]; then
      log_step "Managed wheel path required for Linux managed Python 3.12; skipping no-deps fallback"
    fi
    if [ "${audio_install_rc}" -eq 0 ]; then
      verify_audio_separator_runtime_deps || audio_install_rc=1
    fi
    if [ "${audio_install_rc}" -ne 0 ]; then
      log_step "audio-separator runtime dependencies incomplete; attempting full dependency repair install"
      audio_repair_attempted=1
      PACKAGE="audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"
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
            pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          else
            pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          fi
        else
          if [ "${managed_diffq_required}" -eq 1 ] && [ "${managed_diffq_ready}" -eq 1 ]; then
            pip_install_with_scope main "${VENV_PY}" --only-binary=diffq "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
          else
            pip_install_with_scope main "${VENV_PY}" "${PACKAGE}" >> "${audio_install_log}" 2>&1 || audio_repair_rc=$?
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
      if verify_current_torch_stack "${VENV_PY}" "${BACKEND}" "before_reapply"; then
        if [ "${TORCH_STACK_INSTALLED_THIS_RUN}" = "1" ]; then
          TORCH_PIN_REAPPLY_REASON="already_installed_this_run"
          log_step "torch_pin_reapply_skipped=already_installed_this_run"
        else
          TORCH_PIN_REAPPLY_REASON="current_stack_already_matches_requested_pin"
          log_step "torch_pin_reapply_skipped=current_stack_already_matches_requested_pin"
        fi
      else
        TORCH_PIN_REAPPLY_REASON="current_stack_verify_failed"
        log_step "torch_pin_reapply_reason=${TORCH_PIN_REAPPLY_REASON}"
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
      fi
      if ! assert_pinned_torch_stack "${VENV_PY}"; then
        set_status "deps_failed" "torch_pin_assert_failed"
      fi
      enforce_runtime_python_pins || set_status "deps_failed" "runtime_python_pins_failed"

      log_stage "Checking/installing ONNX Runtime"
      onnx_install_rc=0
      if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
        log_step "Installing ${ONNX_PACKAGE}"
        if [ -n "${CONSTRAINTS_FILE}" ]; then
          pip_install_with_scope main "${VENV_PY}" -c "${CONSTRAINTS_FILE}" "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1 || onnx_install_rc=$?
        else
          pip_install_with_scope main "${VENV_PY}" "${ONNX_PACKAGE}" >> "${LOG_FILE}" 2>&1 || onnx_install_rc=$?
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

set_progress "4" "${STEP_TOTAL}" "Checking FFmpeg"
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
  managed_ffmpeg=""
  if install_managed_ffmpeg; then
    managed_ffmpeg="$(resolve_managed_ffmpeg_from_venv || true)"
  fi
  if [ -n "${managed_ffmpeg}" ] && [ -x "${managed_ffmpeg}" ]; then
    FFMPEG="${managed_ffmpeg}"
    log_step "Using managed FFmpeg from Python runtime: ${FFMPEG}"
  else
    set_status "missing_ffmpeg" "ffmpeg_not_found"
  fi
elif ! "${FFMPEG}" -version >/dev/null 2>&1; then
  set_status "ffmpeg_unusable" "ffmpeg_version_check_failed"
fi

if [ -z "${FFMPEG}" ] || ! "${FFMPEG}" -version >/dev/null 2>&1; then
  FINAL_OK=0
fi

set_progress "5" "${STEP_TOTAL}" "Preparing Drum Kit runtime"
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
    hip = getattr(getattr(torch, "version", None), "hip", None)
    cuda_available = bool(torch.cuda.is_available())
    cuda_count = int(torch.cuda.device_count()) if cuda_available else 0
    names = []
    if cuda_available:
        for i in range(cuda_count):
            try:
                names.append(str(torch.cuda.get_device_name(i)))
            except Exception:
                pass
    dev_text = "|".join(names).lower()
    allow_rocm7_gfx1201 = (
        backend == "rocm"
        and (major, minor) == (2, 10)
        and hip is not None
        and cuda_available
        and cuda_count > 0
        and ("rx 9070" in dev_text or "gfx1201" in dev_text)
    )
    if (major > 2 or (major == 2 and minor >= 6)) and not allow_rocm7_gfx1201:
        errors.append("torch_too_new_for_demucs:" + ver)
    if backend == "rocm":
        if not (hip is not None and cuda_available and cuda_count > 0):
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
    RUNTIME_VERIFY_DETAIL="${RUNTIME_VERIFY_PROBE}"
    set_status "deps_failed" "runtime_verify_failed"
    RUNTIME_STRICT_OK=0
  else
    RUNTIME_VERIFY_DETAIL="ok"
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
    names = []
    if cuda_avail:
        for i in range(cuda_cnt):
            try:
                names.append(str(torch.cuda.get_device_name(i)))
            except Exception:
                pass
    dev_text = "|".join(names).lower()
    allow_rocm7_gfx1201 = (
        backend == "rocm"
        and (major, minor) == (2, 10)
        and (hip is not None)
        and cuda_avail
        and cuda_cnt > 0
        and ("rx 9070" in dev_text or "gfx1201" in dev_text)
    )
    ok = ((major, minor) < (2, 6)) or allow_rocm7_gfx1201
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

READY_RUNTIME_KIND="cpu"
READY_RUNTIME_STATUS="missing"
READY_DRUMSEP_MODEL_STATUS="missing"
READY_DETAIL="${STATUS_REASON}"
if [ "${STATUS}" = "ok" ] && [ "${FINAL_OK}" -eq 1 ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  if ensure_core_model_cache "${VENV_PY}" "$(model_cache_dir)"; then
    CORE_MODEL_PREFETCH_STATUS="ok"
    CORE_MODEL_PREFETCH_DETAIL=""
  else
    CORE_MODEL_PREFETCH_STATUS="skipped"
    CORE_MODEL_PREFETCH_DETAIL="non_blocking_prefetch_failure"
    log_step "core_model_prefetch_skipped=${CORE_MODEL_PREFETCH_DETAIL}"
  fi
fi
if [ "${STATUS}" = "ok" ] && [ "${FINAL_OK}" -eq 1 ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  if [ "${BACKEND}" = "rocm" ]; then
    READY_RUNTIME_KIND="rocm"
    if ! install_drumsep_rocm_runtime; then
      set_status "deps_failed" "drumsep_ready_runtime_failed"
    fi
  else
    READY_RUNTIME_KIND="cpu"
    if ! install_drumsep_runtime; then
      set_status "deps_failed" "drumsep_ready_runtime_failed"
    fi
  fi
fi
if [ "${READY_RUNTIME_KIND}" = "rocm" ] && [ -f "$(drumsep_rocm_state_file)" ]; then
  READY_RUNTIME_STATUS="$(awk -F= '/^DRUMSEP_ROCM_RUNTIME_STATUS=/{print $2; exit} /^STATUS=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
  READY_DRUMSEP_MODEL_STATUS="$(awk -F= '/^DRUMSEP_ROCM_MODEL_STATUS=/{print $2; exit} /^DRUMSEP_MODEL_STATUS=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
  READY_DETAIL="$(awk -F= '/^DRUMSEP_ROCM_RUNTIME_DETAIL=/{print $2; exit} /^STATUS_REASON=/{print $2; exit}' "$(drumsep_rocm_state_file)")"
else
  load_ready_runtime_state "cpu" || true
fi
if [ -z "${READY_RUNTIME_STATUS}" ]; then READY_RUNTIME_STATUS="missing"; fi
if [ -z "${READY_DRUMSEP_MODEL_STATUS}" ]; then READY_DRUMSEP_MODEL_STATUS="missing"; fi
if [ -z "${READY_DETAIL}" ]; then READY_DETAIL="${STATUS_REASON}"; fi
READY_STATE_FILE="$(ready_to_go_output_file)"
write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "ok" "${CORE_MODEL_PREFETCH_STATUS}" "${CORE_MODEL_PREFETCH_DETAIL}"

if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" = "${READY_STATE_FILE}" ]; then
  log_step "ready_to_go_state_persists_in_state_file=1"
  STATE_FILE=""
fi

if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" != "${READY_STATE_FILE}" ]; then
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
