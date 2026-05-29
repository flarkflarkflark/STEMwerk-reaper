#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLED_CORE_DIR="${SCRIPT_DIR}/vendor/stemwerk-core"
MACOS_ARM_CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints/macos.txt"
MACOS_INTEL_CONSTRAINTS_FILE="${SCRIPT_DIR}/constraints/macos-intel.txt"
MACOS_CONSTRAINTS_FILE=""
PINNED_NUMPY_VERSION="1.26.4"
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
  [ "${MAC_ARCH}" = "arm64" ] || return 0
  _probe="$(probe_samplerate_runtime)"
  [ -n "${_probe}" ] || return 0

  SAMPLERATE_VERSION=""
  SAMPLERATE_MODULE_PATH=""
  SAMPLERATE_DYLIB_PATH=""
  SAMPLERATE_DYLIB_ARCH=""
  SAMPLERATE_PLATFORM_MACHINE=""
  SAMPLERATE_SYSCONFIG_PLATFORM=""
  SAMPLERATE_ARCH_MATCH="unknown"
  SAMPLERATE_REPAIR_ATTEMPTED="no"

  _samplerate_import=""
  _samplerate_dylib_exists=""
  while IFS='=' read -r _k _v; do
    case "${_k}" in
      samplerate_import) _samplerate_import="${_v}" ;;
      samplerate_version) SAMPLERATE_VERSION="${_v}" ;;
      samplerate_module) SAMPLERATE_MODULE_PATH="${_v}" ;;
      samplerate_dylib) SAMPLERATE_DYLIB_PATH="${_v}" ;;
      samplerate_dylib_exists) _samplerate_dylib_exists="${_v}" ;;
      samplerate_dylib_file) SAMPLERATE_DYLIB_ARCH="${_v}" ;;
      platform_machine) SAMPLERATE_PLATFORM_MACHINE="${_v}" ;;
      sysconfig_platform) SAMPLERATE_SYSCONFIG_PLATFORM="${_v}" ;;
      samplerate_error) log "samplerate probe error: ${_v}" ;;
    esac
  done <<EOF
${_probe}
EOF

  log "samplerate diagnostics: version=${SAMPLERATE_VERSION:-missing}; module=${SAMPLERATE_MODULE_PATH:-missing}; dylib=${SAMPLERATE_DYLIB_PATH:-missing}"
  log "samplerate diagnostics: platform_machine=${SAMPLERATE_PLATFORM_MACHINE:-unknown}; sysconfig_platform=${SAMPLERATE_SYSCONFIG_PLATFORM:-unknown}"
  [ -n "${SAMPLERATE_DYLIB_ARCH}" ] && log "samplerate diagnostics: file ${SAMPLERATE_DYLIB_ARCH}"

  _arch_bad=0
  if [ "${_samplerate_import}" != "ok" ] || [ "${_samplerate_dylib_exists}" != "yes" ]; then
    _arch_bad=1
  elif [ -n "${SAMPLERATE_DYLIB_ARCH}" ]; then
    case "${SAMPLERATE_DYLIB_ARCH}" in
      *arm64*|*universal*)
        SAMPLERATE_ARCH_MATCH="yes"
        _arch_bad=0
        ;;
      *)
        SAMPLERATE_ARCH_MATCH="no"
        _arch_bad=1
        ;;
    esac
  fi

  if [ "${_arch_bad}" -eq 0 ]; then
    return 0
  fi

  SAMPLERATE_REPAIR_ATTEMPTED="yes"
  log "Detected samplerate runtime mismatch on Apple Silicon; attempting forced reinstall of samplerate==0.2.4"
  "${VENV_PY}" -m pip uninstall -y samplerate >> "${LOG_FILE}" 2>&1 || true
  if ! "${VENV_PY}" -m pip install --force-reinstall --no-cache-dir "samplerate==0.2.4" >> "${LOG_FILE}" 2>&1; then
    BACKEND_DEPS_REASON="samplerate_reinstall_failed"
    return 1
  fi

  _probe2="$(probe_samplerate_runtime)"
  [ -n "${_probe2}" ] || {
    BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild"
    return 1
  }
  _arch_ok=0
  _import_ok=0
  while IFS='=' read -r _k _v; do
    case "${_k}" in
      samplerate_import)
        [ "${_v}" = "ok" ] && _import_ok=1
        ;;
      samplerate_version) SAMPLERATE_VERSION="${_v}" ;;
      samplerate_module) SAMPLERATE_MODULE_PATH="${_v}" ;;
      samplerate_dylib) SAMPLERATE_DYLIB_PATH="${_v}" ;;
      samplerate_dylib_file)
        SAMPLERATE_DYLIB_ARCH="${_v}"
        case "${_v}" in
          *arm64*|*universal*) _arch_ok=1 ;;
        esac
        ;;
      platform_machine) SAMPLERATE_PLATFORM_MACHINE="${_v}" ;;
      sysconfig_platform) SAMPLERATE_SYSCONFIG_PLATFORM="${_v}" ;;
      samplerate_error) log "samplerate repair probe error: ${_v}" ;;
    esac
  done <<EOF
${_probe2}
EOF

  log "samplerate diagnostics after repair: version=${SAMPLERATE_VERSION:-missing}; module=${SAMPLERATE_MODULE_PATH:-missing}; dylib=${SAMPLERATE_DYLIB_PATH:-missing}"
  [ -n "${SAMPLERATE_DYLIB_ARCH}" ] && log "samplerate diagnostics after repair: file ${SAMPLERATE_DYLIB_ARCH}"
  if [ "${_import_ok}" -eq 1 ] && [ "${_arch_ok}" -eq 1 ]; then
    SAMPLERATE_ARCH_MATCH="yes"
    BACKEND_DEPS_REASON=""
    return 0
  fi

  SAMPLERATE_ARCH_MATCH="no"
  BACKEND_DEPS_REASON="samplerate_arch_mismatch_requires_runtime_rebuild"
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
  log "Installing pinned torch stack (${PINNED_TORCH_STACK_LABEL}): torch==${PINNED_TORCH_VERSION} torchvision==${PINNED_TORCHVISION_VERSION} torchaudio==${PINNED_TORCHAUDIO_VERSION}"
  "${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio >> "${LOG_FILE}" 2>&1 || true
  "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir \
    "numpy==${PINNED_NUMPY_VERSION}" \
    "torch==${PINNED_TORCH_VERSION}" \
    "torchvision==${PINNED_TORCHVISION_VERSION}" \
    "torchaudio==${PINNED_TORCHAUDIO_VERSION}" >> "${LOG_FILE}" 2>&1
  "${VENV_PY}" -m pip install --upgrade --force-reinstall --no-cache-dir \
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
expected_audio_separator = "0.23.0"
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

if command -v managed_python_init_state >/dev/null 2>&1; then
  managed_python_init_state
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
    VENV_PY="${RUNTIME_BASE}/.venv/bin/python"
    "${VENV_PY}" -m pip install --upgrade pip >> "${LOG_FILE}" 2>&1 || set_status "pip_failed" "pip_upgrade_failed"
    log "Installing pinned STEMwerk backend packages..."
    "${VENV_PY}" -m pip install "numpy==${PINNED_NUMPY_VERSION}" >> "${LOG_FILE}" 2>&1 || set_status "deps_failed" "numpy_install_failed"
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
        _audio_tmp_log="${RUNTIME_BASE}/logs/audio_separator_install.log"
        : > "${_audio_tmp_log}" || true
        if [ -f "${MACOS_CONSTRAINTS_FILE}" ]; then
          log "Installing ${PACKAGE} with macOS constraints from ${MACOS_CONSTRAINTS_FILE}"
          "${VENV_PY}" -m pip install -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}" >> "${_audio_tmp_log}" 2>&1
        else
          "${VENV_PY}" -m pip install "${PACKAGE}" >> "${_audio_tmp_log}" 2>&1
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
      }

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
  "/opt/local/bin/ffmpeg" \
  "/opt/homebrew/opt/ffmpeg/bin/ffmpeg" \
  "/usr/local/opt/ffmpeg/bin/ffmpeg" \
  "/usr/bin/ffmpeg"
do
  if [ -x "$p" ]; then
    FFMPEG="$p"
    break
  fi
done

if [ -z "${FFMPEG}" ]; then
  set_status "missing_ffmpeg" "ffmpeg_not_found"
fi

set_progress "4" "${STEP_TOTAL}" "Finalizing setup"

if [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then
  if ! repair_samplerate_if_arch_mismatch; then
    if [ -n "${BACKEND_DEPS_REASON}" ]; then
      set_status "deps_failed" "${BACKEND_DEPS_REASON}"
    else
      set_status "deps_failed" "samplerate_arch_mismatch_requires_runtime_rebuild"
    fi
  fi
  "${VENV_PY}" -c "import numba" >/dev/null 2>&1 || set_status "deps_failed" "numba_missing_after_setup"
  log_final_dependency_versions "${VENV_PY}"
  "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || set_status "audio_separator_check_failed" "audio_separator_import_failed"
  if ! verify_audio_separator_runtime_deps; then
    if [ "${BACKEND_DEPS_REASON}" = "samplerate_arch_mismatch_requires_runtime_rebuild" ] || [ "${BACKEND_DEPS_REASON}" = "samplerate_reinstall_failed" ]; then
      set_status "deps_failed" "${BACKEND_DEPS_REASON}"
    else
      set_status "deps_failed" "audio_separator_install_failed"
    fi
  fi
  "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1 || set_status "onnxruntime_check_failed" "onnxruntime_missing_after_setup"
  "${VENV_PY}" -c "import stemwerk_core" >/dev/null 2>&1 || set_status "stemwerk_core_check_failed" "stemwerk_core_missing_after_setup"
  if ! assert_pinned_torch_stack "${VENV_PY}"; then
    set_status "deps_failed" "torch_pin_assert_failed"
  fi
fi

if [ -n "${STATE_FILE}" ]; then
  write_state
fi

if [ "${STATUS}" != "ok" ]; then
  exit 1
fi
log "Runtime verification passed."
exit 0
