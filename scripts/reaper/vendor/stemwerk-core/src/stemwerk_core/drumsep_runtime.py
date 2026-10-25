"""Core-owned DrumSep runtime discovery, verification, and selection policy.

This module is independent of REAPER and the legacy processor. The processor
keeps dynamically bound compatibility wrappers, while readiness and processing
share this single policy implementation.
"""

from __future__ import annotations

import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Optional, Set, Tuple

from . import managed_runtime

DRUMSEP_RUNTIME_DIRNAME = ".venv-drumsep"
DRUMSEP_RUNTIME_ROCM_DIRNAME = ".venv-drumsep-rocm"
DRUMSEP_RUNTIME_CUDA_DIRNAME = ".venv-drumsep-cuda"
DRUMSEP_RUNTIME_DIRECTML_DIRNAME = ".venv-drumsep-directml"
BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV = "STEMWERK_BENCH_DRUMSEP_HELPER_DEVICE"
DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS = 120
DRUMSEP_RUNTIME_VERIFY_TIMEOUT_DETAIL_PREFIX = "verify_timeout:"

_OVERRIDES: ContextVar[Optional[Dict[str, Any]]] = ContextVar(
    "stemwerk_drumsep_runtime_overrides", default=None
)


def _override(name: str, fallback: Any) -> Any:
    values = _OVERRIDES.get()
    if values is None or values.get(name) is None:
        return fallback
    return values[name]


@contextmanager
def _runtime_context(**values: Any) -> Iterator[None]:
    token = _OVERRIDES.set(values)
    try:
        yield
    finally:
        _OVERRIDES.reset(token)


def _platform_name() -> str:
    return str(_override("platform_name", sys.platform))


def _os_name() -> str:
    return str(_override("os_name", os.name))


def _machine() -> str:
    return str(_override("machine", platform.machine()))


def _environ() -> Mapping[str, str]:
    return _override("environ", os.environ)

def _ts() -> str:
    callback = _override("timestamp", None)
    if callback is not None:
        return str(callback())
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _is_darwin_arm64() -> bool:
    return _platform_name() == "darwin" and _machine().lower() in {"arm64", "aarch64"}

def _is_windows_runtime() -> bool:
    return _os_name() == "nt" or _platform_name().startswith("win")

def _windows_no_window_kwargs() -> Dict[str, int]:
    subprocess_module = _override("subprocess_module", subprocess)
    if _os_name() == "nt" and hasattr(subprocess_module, "CREATE_NO_WINDOW"):
        return {"creationflags": subprocess_module.CREATE_NO_WINDOW}
    return {}

def _clean_env() -> Dict[str, str]:
    env = dict(_environ())
    for key in (
        "HIP_VISIBLE_DEVICES", "HSA_OVERRIDE_GFX_VERSION",
        "ROCR_VISIBLE_DEVICES", "CUDA_VISIBLE_DEVICES",
        "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT",
    ):
        env.pop(key, None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env

def _runtime_base_candidates() -> List[Path]:
    callback = _override("runtime_base_candidates", None)
    return list(callback()) if callback is not None else managed_runtime.runtime_base_candidates()

def _drumsep_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_DIRNAME
    if _is_windows_runtime():
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _main_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / ".venv"
    if _is_windows_runtime():
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _drumsep_rocm_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_ROCM_DIRNAME
    if _is_windows_runtime():
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _drumsep_cuda_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_CUDA_DIRNAME
    if _is_windows_runtime():
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _drumsep_directml_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_DIRECTML_DIRNAME
    if _is_windows_runtime():
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _read_env_file(path: Path) -> Dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return {}
    result: Dict[str, str] = {}
    for raw_line in text.splitlines():
        line = str(raw_line or "").strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key:
            result[key] = value.strip()
    return result


def _drumsep_runtime_state(runtime_base: Optional[Path] = None, kind: str = "cpu") -> Dict[str, str]:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    if kind == "rocm":
        state_name = "drumsep_runtime_rocm.env"
    elif kind == "cuda":
        state_name = "drumsep_runtime_cuda.env"
    elif kind == "directml":
        state_name = "drumsep_runtime_directml.env"
    else:
        state_name = "drumsep_runtime.env"
    return _read_env_file(base / "state" / state_name)


def _ready_to_go_state(runtime_base: Optional[Path] = None) -> Dict[str, str]:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    return _read_env_file(base / "state" / "ready_to_go.env")


def _macos_ready_drumsep_main_runtime_candidates(runtime_base: Optional[Path] = None) -> List[Path]:
    if not _is_darwin_arm64():
        return []
    ready = _ready_to_go_state(runtime_base)
    runtime_kind = str(ready.get("DRUMSEP_READY_RUNTIME") or "").strip().lower()
    runtime_status = str(ready.get("DRUMSEP_READY_RUNTIME_STATUS") or "").strip().lower()
    model_status = str(ready.get("DRUMSEP_READY_MODEL_STATUS") or "").strip().lower()
    main_status = str(ready.get("MAIN_RUNTIME_STATUS") or "").strip().lower()
    ready_status = str(ready.get("READY_TO_GO_STATUS") or "").strip().lower()
    if (
        runtime_kind in {"mps", "cpu"}
        and runtime_status == "ok"
        and model_status == "ok"
        and main_status == "ok"
        and ready_status == "ok"
    ):
        return [_main_runtime_python_path(runtime_base)]
    return []


def _drumsep_state_python_candidates(state: Dict[str, str], fallback: Path) -> List[Path]:
    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(raw_value: Any) -> None:
        text = str(raw_value or "").strip()
        if not text:
            return
        try:
            path = Path(text).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    add(state.get("PYTHON_PATH"))
    add(state.get("VENV_PYTHON_PATH"))
    add(state.get("VENV_PYTHON"))
    add(fallback)
    return candidates


def _probe_drumsep_runtime_candidates_impl(
    candidates: List[Path],
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
    require_directml: bool = False,
) -> Tuple[Optional[Path], str, Dict[str, Any], List[Dict[str, Any]]]:
    verify_runtime = _override("verify_runtime", None) or _verify_drumsep_runtime
    attempts: List[Dict[str, Any]] = []
    first_broken_detail = ""
    for candidate in candidates:
        if require_directml:
            ok, detail, payload = verify_runtime(
                candidate,
                require_gpu=require_gpu,
                require_mps=require_mps,
                require_directml=True,
            )
        elif require_cuda:
            ok, detail, payload = verify_runtime(
                candidate,
                require_gpu=require_gpu,
                require_mps=require_mps,
                require_cuda=True,
            )
        elif require_mps:
            ok, detail, payload = verify_runtime(
                candidate,
                require_gpu=require_gpu,
                require_mps=True,
            )
        else:
            ok, detail, payload = verify_runtime(candidate, require_gpu=require_gpu)
        attempts.append({"python": str(candidate), "ok": bool(ok), "detail": str(detail)})
        if ok:
            return candidate, detail, payload, attempts
        if detail != "missing" and first_broken_detail == "":
            first_broken_detail = str(detail)
    return None, (first_broken_detail or "missing"), {}, attempts


def _probe_drumsep_runtime_candidates(
    candidates: List[Path],
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
    require_directml: bool = False,
) -> Tuple[Optional[Path], str, Dict[str, Any], List[Dict[str, Any]]]:
    replacement = _override("probe_candidates", None)
    if replacement is not None:
        return replacement(
            candidates,
            require_gpu=require_gpu,
            require_mps=require_mps,
            require_cuda=require_cuda,
            require_directml=require_directml,
        )
    return _probe_drumsep_runtime_candidates_impl(
        candidates,
        require_gpu=require_gpu,
        require_mps=require_mps,
        require_cuda=require_cuda,
        require_directml=require_directml,
    )


def _verify_drumsep_runtime(
    python_path: Path,
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
    require_directml: bool = False,
) -> Tuple[bool, str, Dict[str, Any]]:
    try:
        exists = python_path.exists()
    except Exception:
        exists = False
    if not exists:
        return False, "missing", {}
    if not os.access(str(python_path), os.X_OK):
        return False, "not_executable", {}

    verify_code = r"""
import importlib
import importlib.metadata as metadata
import json
import sys

required = ["audio_separator", "numpy", "torch", "onnx", "onnxruntime"]
optional = ["onnx2torch"]
versions = {}

for module_name in required:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        print(json.dumps({"ok": False, "module": module_name, "error": f"{type(exc).__name__}: {exc}"}))
        sys.exit(1)

for dist_name in ["audio-separator", "numpy", "torch", "onnx", "onnxruntime", "onnx2torch", "onnx2torch-py313"]:
    try:
        versions[dist_name] = metadata.version(dist_name)
    except Exception:
        versions[dist_name] = ""

for module_name in optional:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        versions[module_name + "_import_error"] = f"{type(exc).__name__}: {exc}"

device_names = []
torch_hip = ""
torch_cuda_available = False
mps_built = False
mps_available = False
directml_available = False
directml_device_count = 0
onnxruntime_providers = []
try:
    import torch
    torch_hip = str(getattr(torch.version, "hip", "") or "")
    torch_cuda_available = bool(torch.cuda.is_available())
    mps_backend = getattr(torch.backends, "mps", None)
    if mps_backend is not None:
        mps_built = bool(mps_backend.is_built())
        mps_available = bool(mps_backend.is_available())
    if torch_cuda_available:
        for idx in range(int(torch.cuda.device_count())):
            try:
                device_names.append(str(torch.cuda.get_device_name(idx)))
            except Exception:
                pass
except Exception:
    pass

try:
    import onnxruntime as ort
    onnxruntime_providers = [str(item) for item in (ort.get_available_providers() or [])]
except Exception:
    pass

try:
    import torch_directml
    directml_available = bool(torch_directml.is_available())
    directml_device_count = int(torch_directml.device_count())
except Exception:
    pass

print(json.dumps({
    "ok": True,
    "versions": versions,
    "torch_hip": torch_hip,
    "torch_cuda_available": torch_cuda_available,
    "device_names": device_names,
    "mps_built": mps_built,
    "mps_available": mps_available,
    "directml_available": directml_available,
    "directml_device_count": directml_device_count,
    "onnxruntime_providers": onnxruntime_providers,
}, sort_keys=True))
"""
    subprocess_module = _override("subprocess_module", subprocess)
    timeout_seconds = int(
        _override("verify_timeout_seconds", DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS)
    )
    try:
        with tempfile.TemporaryDirectory(prefix="stemwerk-drumsep-verify-") as scratch:
            completed = subprocess_module.run(
                [str(python_path), "-I", "-B", "-c", verify_code],
                text=True,
                stdout=subprocess_module.PIPE,
                stderr=subprocess_module.PIPE,
                timeout=timeout_seconds,
                cwd=scratch,
                env=_clean_env(),
                **_windows_no_window_kwargs(),
            )
    except subprocess_module.TimeoutExpired:
        # subprocess.run() has already killed and reaped the probe. Running out
        # of time is inconclusive, not evidence that the runtime is broken.
        return False, f"{DRUMSEP_RUNTIME_VERIFY_TIMEOUT_DETAIL_PREFIX}{timeout_seconds}s", {}
    except Exception as exc:
        return False, f"verify_spawn_failed:{type(exc).__name__}:{exc}", {}

    output = " ".join(part.strip() for part in (completed.stdout, completed.stderr) if part and part.strip())
    if completed.returncode != 0:
        return False, output[:1200] or f"verify_exit_{completed.returncode}", {}

    try:
        payload = json.loads((completed.stdout or "").strip())
    except Exception as exc:
        return False, f"verify_malformed_output:{type(exc).__name__}", {}
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return False, "verify_malformed_output:missing_ok", {}

    if require_gpu:
        hip = str(payload.get("torch_hip") or "")
        cuda_available = bool(payload.get("torch_cuda_available"))
        device_names = payload.get("device_names") or []
        if not isinstance(device_names, list):
            device_names = []
        if not hip:
            return False, "rocm_no_hip", payload
        if not cuda_available:
            return False, "rocm_cuda_unavailable", payload
        if len([d for d in device_names if str(d).strip()]) == 0:
            return False, "rocm_no_device_names", payload
    if require_cuda:
        hip = str(payload.get("torch_hip") or "")
        cuda_available = bool(payload.get("torch_cuda_available"))
        device_names = payload.get("device_names") or []
        if not isinstance(device_names, list):
            device_names = []
        if hip:
            return False, "cuda_runtime_is_rocm", payload
        if not cuda_available:
            return False, "cuda_unavailable", payload
        if len([d for d in device_names if str(d).strip()]) == 0:
            return False, "cuda_no_device_names", payload
    if require_mps:
        if not bool(payload.get("mps_built")):
            return False, "mps_not_built", payload
        if not bool(payload.get("mps_available")):
            return False, "mps_not_available", payload
    if require_directml:
        providers = payload.get("onnxruntime_providers") or []
        if not isinstance(providers, list):
            providers = []
        if not bool(payload.get("directml_available")):
            return False, "torch_directml_unavailable", payload
        if int(payload.get("directml_device_count") or 0) < 1:
            return False, "directml_no_devices", payload
        if "DmlExecutionProvider" not in [str(item) for item in providers]:
            return False, "onnxruntime_dml_provider_missing", payload

    return True, output[:1200] or "ok", payload


def _select_drumsep_runtime(
    requested_device: str = "auto", runtime_base: Optional[Path] = None
) -> Tuple[Optional[Path], str, Dict[str, Any]]:
    cuda_state = _drumsep_runtime_state(runtime_base, "cuda")
    directml_state = _drumsep_runtime_state(runtime_base, "directml")
    rocm_state = _drumsep_runtime_state(runtime_base, "rocm")
    cpu_state = _drumsep_runtime_state(runtime_base, "cpu")
    cuda_candidates = _drumsep_state_python_candidates(
        cuda_state,
        _drumsep_cuda_runtime_python_path(runtime_base),
    )
    directml_candidates = _drumsep_state_python_candidates(
        directml_state,
        _drumsep_directml_runtime_python_path(runtime_base),
    )
    rocm_candidates = _drumsep_state_python_candidates(rocm_state, _drumsep_rocm_runtime_python_path(runtime_base))
    cpu_candidates = _drumsep_state_python_candidates(cpu_state, _drumsep_runtime_python_path(runtime_base))
    macos_ready_candidates = _macos_ready_drumsep_main_runtime_candidates(runtime_base)
    if macos_ready_candidates:
        cpu_candidates = list(macos_ready_candidates)
    cuda_python = cuda_candidates[0]
    directml_python = directml_candidates[0]
    rocm_python = rocm_candidates[0]
    cpu_python = cpu_candidates[0]
    device_norm = str(requested_device or "auto").strip().lower()
    explicit_cuda = device_norm == "cuda" or bool(re.match(r"^cuda:\d+$", device_norm))
    explicit_rocm = device_norm == "rocm"
    explicit_directml = device_norm == "directml" or device_norm.startswith("directml:")
    def _normalized_device_request(value: str) -> str:
        if value == "cpu":
            return "cpu"
        if value == "" or value == "auto":
            return "auto"
        if value.startswith("cuda") or value.startswith("directml") or value.startswith("rocm") or value == "mps":
            return "gpu"
        if "rx " in value or "radeon" in value or "nvidia" in value or value.startswith("gpu"):
            return "gpu"
        return "unknown"

    normalized_request = _normalized_device_request(device_norm)
    explicit_cpu = normalized_request == "cpu"
    bench_helper_device = str(_environ().get(BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "") or "").strip().lower()
    print(f"normalized_device_request={normalized_request}", file=sys.stderr)

    if explicit_directml:
        print("drumsep_runtime_selection_policy=explicit_directml", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_start", file=sys.stderr)
        selected_directml_python, directml_detail, directml_payload, directml_attempts = _probe_drumsep_runtime_candidates(
            directml_candidates,
            require_gpu=False,
            require_directml=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_end detail={directml_detail}", file=sys.stderr)
        if selected_directml_python is not None:
            info = dict(directml_payload or {})
            info["kind"] = "directml"
            info["detail"] = directml_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "explicit_directml"
            info["directml_python_attempts"] = directml_attempts
            return selected_directml_python, "directml", info
        info = {
            "directml_detail": directml_detail,
            "directml_python": str(directml_python),
            "directml_python_attempts": directml_attempts,
            "selection_policy": "explicit_directml",
        }
        reason = "missing" if directml_detail == "missing" else "broken"
        return None, reason, info

    if _is_windows_runtime() and explicit_cuda:
        print("drumsep_runtime_selection_policy=explicit_cuda", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_start", file=sys.stderr)
        selected_cuda_python, cuda_detail, cuda_payload, cuda_attempts = _probe_drumsep_runtime_candidates(
            cuda_candidates,
            require_cuda=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_end detail={cuda_detail}", file=sys.stderr)
        if selected_cuda_python is not None:
            info = dict(cuda_payload or {})
            info["kind"] = "cuda"
            info["detail"] = cuda_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "explicit_cuda"
            info["cuda_python_attempts"] = cuda_attempts
            return selected_cuda_python, "cuda", info
        info = {
            "cuda_detail": cuda_detail,
            "cuda_python": str(cuda_python),
            "cuda_python_attempts": cuda_attempts,
            "selection_policy": "explicit_cuda",
        }
        reason = "missing" if cuda_detail == "missing" else "broken"
        return None, reason, info

    if _is_windows_runtime() and normalized_request in {"auto", "gpu"}:
        selection_policy = "gpu_prefer_cuda" if normalized_request == "gpu" else "auto_prefer_cuda"
        print(f"drumsep_runtime_selection_policy={selection_policy}", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_start", file=sys.stderr)
        selected_cuda_python, cuda_detail, cuda_payload, cuda_attempts = _probe_drumsep_runtime_candidates(
            cuda_candidates,
            require_cuda=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_end detail={cuda_detail}", file=sys.stderr)
        if selected_cuda_python is not None:
            info = dict(cuda_payload or {})
            info["kind"] = "cuda"
            info["detail"] = cuda_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = selection_policy
            info["cuda_python_attempts"] = cuda_attempts
            return selected_cuda_python, "cuda", info

        directml_selection_policy = "fallback_directml"
        print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_start", file=sys.stderr)
        selected_directml_python, directml_detail, directml_payload, directml_attempts = _probe_drumsep_runtime_candidates(
            directml_candidates,
            require_gpu=False,
            require_directml=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_end detail={directml_detail}", file=sys.stderr)
        if selected_directml_python is not None:
            info = dict(directml_payload or {})
            info["kind"] = "directml"
            info["detail"] = directml_detail
            info["fallback_reason"] = f"cuda_skipped:{cuda_detail}"
            info["selection_policy"] = directml_selection_policy
            info["cuda_python_attempts"] = cuda_attempts
            info["directml_python_attempts"] = directml_attempts
            return selected_directml_python, "directml", info

        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
        selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_gpu=False,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
        if selected_cpu_python is not None:
            info = dict(cpu_payload or {})
            info["kind"] = "cpu"
            info["detail"] = cpu_detail
            info["fallback_reason"] = f"cuda_skipped:{cuda_detail};directml_skipped:{directml_detail}"
            info["selection_policy"] = "fallback_cpu"
            info["cpu_python_attempts"] = cpu_attempts
            info["cuda_python_attempts"] = cuda_attempts
            info["directml_python_attempts"] = directml_attempts
            return selected_cpu_python, "cpu", info

        info = {
            "cuda_detail": cuda_detail,
            "directml_detail": directml_detail,
            "cpu_detail": cpu_detail,
            "cuda_python": str(cuda_python),
            "directml_python": str(directml_python),
            "cpu_python": str(cpu_python),
            "cuda_python_attempts": cuda_attempts,
            "directml_python_attempts": directml_attempts,
            "cpu_python_attempts": cpu_attempts,
            "selection_policy": "fallback_cpu",
            "normalized_request": normalized_request,
        }
        reason = "missing" if cuda_detail == "missing" and directml_detail == "missing" and cpu_detail == "missing" else "broken"
        return None, reason, info

    if device_norm == "mps" and _is_darwin_arm64():
        print("drumsep_runtime_selection_policy=explicit_mps", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_mps_start", file=sys.stderr)
        selected_mps_python, mps_detail, mps_payload, mps_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_mps=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_mps_end detail={mps_detail}", file=sys.stderr)
        if selected_mps_python is not None:
            info = dict(mps_payload or {})
            info["kind"] = "mps"
            info["detail"] = mps_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "explicit_mps"
            info["mps_experimental"] = True
            info["mps_python_attempts"] = mps_attempts
            return selected_mps_python, "mps", info
        info = {
            "mps_detail": mps_detail,
            "mps_python": str(cpu_python),
            "mps_python_attempts": mps_attempts,
            "selection_policy": "explicit_mps",
        }
        reason = "missing" if mps_detail == "missing" else "broken"
        return None, reason, info

    if _is_darwin_arm64() and normalized_request in {"auto", "gpu"}:
        selection_policy = "gpu_prefer_mps" if normalized_request == "gpu" else "auto_prefer_mps"
        print(f"drumsep_runtime_selection_policy={selection_policy}", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_mps_start", file=sys.stderr)
        selected_mps_python, mps_detail, mps_payload, mps_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_mps=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_mps_end detail={mps_detail}", file=sys.stderr)
        if selected_mps_python is not None:
            info = dict(mps_payload or {})
            info["kind"] = "mps"
            info["detail"] = mps_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = selection_policy
            info["mps_experimental"] = True
            info["mps_python_attempts"] = mps_attempts
            return selected_mps_python, "mps", info

        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
        selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(cpu_candidates, require_gpu=False)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
        if selected_cpu_python is not None:
            info = dict(cpu_payload or {})
            info["kind"] = "cpu"
            info["detail"] = cpu_detail
            info["fallback_reason"] = f"mps_skipped:{mps_detail}"
            info["selection_policy"] = "fallback_cpu_direct_demix"
            info["cpu_python_attempts"] = cpu_attempts
            info["mps_python_attempts"] = mps_attempts
            return selected_cpu_python, "cpu", info

        info = {
            "mps_detail": mps_detail,
            "cpu_detail": cpu_detail,
            "mps_python": str(cpu_python),
            "cpu_python": str(cpu_python),
            "mps_python_attempts": mps_attempts,
            "cpu_python_attempts": cpu_attempts,
            "selection_policy": "fallback_cpu_direct_demix",
            "normalized_request": normalized_request,
        }
        reason = "missing" if cpu_detail == "missing" and mps_detail == "missing" else "broken"
        return None, reason, info

    if explicit_cpu:
        print("drumsep_runtime_selection_policy=explicit_cpu", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
        selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(cpu_candidates, require_gpu=False)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
        if selected_cpu_python is not None:
            info = dict(cpu_payload or {})
            info["kind"] = "cpu"
            info["detail"] = cpu_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "explicit_cpu"
            info["cpu_python_attempts"] = cpu_attempts
            return selected_cpu_python, "cpu", info

        # No dedicated CPU DrumSep runtime (.venv-drumsep) exists or it is
        # broken. On Linux, a ROCm DrumSep runtime (.venv-drumsep-rocm), when
        # present, is a fully CPU-capable Python environment in its own
        # right (proven: real production DrumSep helper run, device=cpu,
        # inside .venv-drumsep-rocm -- effective_device/model_device=cpu,
        # CPUExecutionProvider, no GPU touched). Probing it with
        # require_gpu=False here only checks that its interpreter and
        # required packages import cleanly, exactly like the cpu_candidates
        # probe above -- it does not require the GPU to be present or
        # working. This mirrors the existing cuda-falls-back-to-cpu and
        # mps-falls-back-to-cpu conventions elsewhere in this function: fall
        # through to the next tier regardless of whether the preferred tier
        # was "missing" or "broken".
        rocm_cpu_detail = "missing"
        rocm_cpu_attempts: List[Dict[str, Any]] = []
        if _platform_name().startswith("linux"):
            print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_as_cpu_start", file=sys.stderr)
            selected_rocm_cpu_python, rocm_cpu_detail, rocm_cpu_payload, rocm_cpu_attempts = _probe_drumsep_runtime_candidates(
                rocm_candidates, require_gpu=False
            )
            print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_as_cpu_end detail={rocm_cpu_detail}", file=sys.stderr)
            if selected_rocm_cpu_python is not None:
                info = dict(rocm_cpu_payload or {})
                info["kind"] = "cpu"
                info["detail"] = rocm_cpu_detail
                info["fallback_reason"] = f"cpu_skipped:{cpu_detail}"
                info["selection_policy"] = "explicit_cpu_via_rocm_runtime"
                info["runtime_source_family"] = "rocm"
                info["cpu_python_attempts"] = cpu_attempts
                info["rocm_cpu_python_attempts"] = rocm_cpu_attempts
                return selected_rocm_cpu_python, "cpu", info

        # No dedicated CPU DrumSep runtime (.venv-drumsep) exists or it is
        # broken. On Windows, a DirectML DrumSep runtime
        # (.venv-drumsep-directml), when present, is a fully CPU-capable
        # Python environment in its own right: the DrumSep helper
        # (stemwerk_drumsep_process.py) only calls torch_directml.device()
        # / sets use_directml=True when --device directml is passed -- for
        # --device cpu it always takes the plain mdx_params/demucs_params/
        # mdxc_params={"device": "cpu"} path, identical to a dedicated CPU
        # venv, regardless of which venv hosts the interpreter. Probing it
        # here with require_gpu=False only checks that its interpreter and
        # required packages import cleanly, exactly like the cpu_candidates
        # probe above -- it does not require DirectML/the GPU to be present
        # or working. This mirrors the Linux ROCm-as-CPU fallback above:
        # fall through to the next tier regardless of whether the preferred
        # tier was "missing" or "broken".
        directml_cpu_detail = "missing"
        directml_cpu_attempts: List[Dict[str, Any]] = []
        if _is_windows_runtime():
            print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_as_cpu_start", file=sys.stderr)
            selected_directml_cpu_python, directml_cpu_detail, directml_cpu_payload, directml_cpu_attempts = _probe_drumsep_runtime_candidates(
                directml_candidates, require_gpu=False
            )
            print(f"timing_utc={_ts()} drumsep_runtime_probe_directml_as_cpu_end detail={directml_cpu_detail}", file=sys.stderr)
            if selected_directml_cpu_python is not None:
                info = dict(directml_cpu_payload or {})
                info["kind"] = "cpu"
                info["detail"] = directml_cpu_detail
                info["fallback_reason"] = f"cpu_skipped:{cpu_detail}"
                info["selection_policy"] = "explicit_cpu_via_directml_runtime"
                info["runtime_source_family"] = "directml"
                info["cpu_python_attempts"] = cpu_attempts
                info["directml_cpu_python_attempts"] = directml_cpu_attempts
                return selected_directml_cpu_python, "cpu", info

        # No dedicated CPU DrumSep runtime (.venv-drumsep) exists or it is
        # broken, and no DirectML runtime is present either. On Windows, a
        # CUDA DrumSep runtime (.venv-drumsep-cuda), when present, is a fully
        # CPU-capable Python environment in its own right: the DrumSep helper
        # only enables GPU execution when --device cuda is passed -- for
        # --device cpu it always takes the plain mdx_params/demucs_params/
        # mdxc_params={"device": "cpu"} path, identical to a dedicated CPU
        # venv, regardless of which venv hosts the interpreter. Probing it
        # here with require_gpu=False only checks that its interpreter and
        # required packages import cleanly, exactly like the cpu_candidates
        # probe above -- it does not require CUDA/the GPU to be present or
        # working. This mirrors the Linux ROCm-as-CPU and Windows
        # DirectML-as-CPU fallbacks above: fall through to the next tier
        # regardless of whether the preferred tier was "missing" or "broken".
        # build_drumsep_subprocess_env additionally blanks CUDA_VISIBLE_DEVICES
        # / NVIDIA_VISIBLE_DEVICES whenever backend=="cpu", so the CUDA-capable
        # interpreter cannot see the GPU even though it is CUDA-capable.
        cuda_cpu_detail = "missing"
        cuda_cpu_attempts: List[Dict[str, Any]] = []
        if _is_windows_runtime():
            print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_as_cpu_start", file=sys.stderr)
            selected_cuda_cpu_python, cuda_cpu_detail, cuda_cpu_payload, cuda_cpu_attempts = _probe_drumsep_runtime_candidates(
                cuda_candidates, require_gpu=False
            )
            print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_as_cpu_end detail={cuda_cpu_detail}", file=sys.stderr)
            if selected_cuda_cpu_python is not None:
                info = dict(cuda_cpu_payload or {})
                info["kind"] = "cpu"
                info["detail"] = cuda_cpu_detail
                info["fallback_reason"] = f"cpu_skipped:{cpu_detail};directml_skipped:{directml_cpu_detail}"
                info["selection_policy"] = "explicit_cpu_via_cuda_runtime"
                info["runtime_source_family"] = "cuda"
                info["cpu_python_attempts"] = cpu_attempts
                info["directml_cpu_python_attempts"] = directml_cpu_attempts
                info["cuda_cpu_python_attempts"] = cuda_cpu_attempts
                return selected_cuda_cpu_python, "cpu", info

        info = {
            "cpu_detail": cpu_detail,
            "cpu_python": str(cpu_python),
            "cpu_python_attempts": cpu_attempts,
            "rocm_cpu_detail": rocm_cpu_detail,
            "rocm_cpu_python_attempts": rocm_cpu_attempts,
            "directml_cpu_detail": directml_cpu_detail,
            "directml_cpu_python_attempts": directml_cpu_attempts,
            "cuda_cpu_detail": cuda_cpu_detail,
            "cuda_cpu_python_attempts": cuda_cpu_attempts,
            "selection_policy": "explicit_cpu",
        }
        reason = (
            "missing"
            if cpu_detail == "missing"
            and rocm_cpu_detail == "missing"
            and directml_cpu_detail == "missing"
            and cuda_cpu_detail == "missing"
            else "broken"
        )
        return None, reason, info

    if explicit_cuda and _platform_name().startswith("linux"):
        # 2.3.1.3 production chain, kept over the Slice-2 fail-closed
        # variant: a genuine NVIDIA failure first resolves the cuda:N
        # namespace through ROCm (AMD/HIP), fails closed only when a
        # provisioned ROCm runtime proves broken, and otherwise keeps the
        # attributed CPU fallback (selection_policy + fallback_reason).
        # See tests/test_linux_drumsep_rocm_fallback_chain.py.
        print("drumsep_runtime_selection_policy=explicit_cuda", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_start", file=sys.stderr)
        selected_cuda_python, cuda_detail, cuda_payload, cuda_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_cuda=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_end detail={cuda_detail}", file=sys.stderr)
        if selected_cuda_python is not None:
            info = dict(cuda_payload or {})
            info["kind"] = "cuda"
            info["detail"] = cuda_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "explicit_cuda"
            info["cuda_python_attempts"] = cuda_attempts
            return selected_cuda_python, "cuda", info

        # No genuine NVIDIA CUDA runtime verified. AMD/HIP GPUs also live
        # under the torch.cuda / "cuda:N" namespace on ROCm builds of
        # PyTorch -- a literal "cuda:0" request on Linux is not proof the
        # physical backend is NVIDIA, so before falling back to CPU, check
        # the ROCm candidate against the exact same live capability test
        # Auto's gpu_prefer_rocm branch already trusts (require_gpu=True:
        # torch_hip non-empty, torch_cuda_available, real device names) --
        # not merely whether .venv-drumsep-rocm exists on disk. This only
        # runs after the real NVIDIA check above has already failed, so a
        # machine with genuine NVIDIA CUDA available is never redirected to
        # ROCm. On a genuine NVIDIA machine with no ROCm runtime installed,
        # this candidate is simply absent (detail=="missing"), so this falls
        # straight through to the unmodified CPU fallback below.
        print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_for_cuda_namespace_start", file=sys.stderr)
        selected_rocm_python, rocm_detail, rocm_payload, rocm_attempts = _probe_drumsep_runtime_candidates(
            rocm_candidates, require_gpu=True
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_for_cuda_namespace_end detail={rocm_detail}", file=sys.stderr)
        if selected_rocm_python is not None:
            info = dict(rocm_payload or {})
            info["kind"] = "rocm"
            info["detail"] = rocm_detail
            info["fallback_reason"] = f"cuda_skipped:{cuda_detail}"
            info["selection_policy"] = "explicit_cuda_namespace_resolved_rocm"
            info["rocm_python_attempts"] = rocm_attempts
            info["cuda_python_attempts"] = cuda_attempts
            return selected_rocm_python, "rocm", info
        if rocm_detail != "missing":
            # .venv-drumsep-rocm exists (Setup/Repair specifically provisioned
            # it for this machine) but failed its own ROCm capability check --
            # this is a ROCm runtime problem, not evidence this is a plain
            # CPU-only machine. Report it as such instead of chasing the
            # (irrelevant here) CPU fallback below, which would otherwise
            # misattribute the failure to .venv-drumsep.
            info = {
                "cuda_detail": cuda_detail,
                "rocm_detail": rocm_detail,
                "rocm_python": str(rocm_python),
                "cuda_python_attempts": cuda_attempts,
                "rocm_python_attempts": rocm_attempts,
                "selection_policy": "explicit_cuda_namespace_resolved_rocm",
            }
            return None, "broken", info

        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
        selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_gpu=False,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
        if selected_cpu_python is not None:
            info = dict(cpu_payload or {})
            info["kind"] = "cpu"
            info["detail"] = cpu_detail
            info["fallback_reason"] = f"cuda_skipped:{cuda_detail}"
            info["selection_policy"] = "fallback_cpu"
            info["cpu_python_attempts"] = cpu_attempts
            info["cuda_python_attempts"] = cuda_attempts
            return selected_cpu_python, "cpu", info

        info = {
            "cuda_detail": cuda_detail,
            "cpu_detail": cpu_detail,
            "cuda_python": str(cpu_python),
            "cpu_python": str(cpu_python),
            "cuda_python_attempts": cuda_attempts,
            "cpu_python_attempts": cpu_attempts,
            "selection_policy": "fallback_cpu",
            "normalized_request": normalized_request,
        }
        reason = "missing" if cuda_detail == "missing" and cpu_detail == "missing" else "broken"
        return None, reason, info

    if bench_helper_device == "cuda" and _platform_name().startswith("linux"):
        print("drumsep_runtime_selection_policy=bench_helper_cuda", file=sys.stderr)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_start", file=sys.stderr)
        selected_cuda_python, cuda_detail, cuda_payload, cuda_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_cuda=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_end detail={cuda_detail}", file=sys.stderr)
        if selected_cuda_python is not None:
            info = dict(cuda_payload or {})
            info["kind"] = "cuda"
            info["detail"] = cuda_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = "bench_helper_cuda"
            info["cuda_python_attempts"] = cuda_attempts
            return selected_cuda_python, "cuda", info
        info = {
            "cuda_detail": cuda_detail,
            "cuda_python": str(cpu_python),
            "cuda_python_attempts": cuda_attempts,
            "selection_policy": "bench_helper_cuda_failed",
        }
        reason = "missing" if cuda_detail == "missing" else "broken"
        return None, reason, info

    selection_policy = "gpu_prefer_rocm" if normalized_request == "gpu" else "auto_prefer_rocm"
    print(f"drumsep_runtime_selection_policy={selection_policy}", file=sys.stderr)
    print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_start", file=sys.stderr)
    selected_rocm_python, rocm_detail, rocm_payload, rocm_attempts = _probe_drumsep_runtime_candidates(rocm_candidates, require_gpu=True)
    print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_end detail={rocm_detail}", file=sys.stderr)
    if selected_rocm_python is None and rocm_detail in {"rocm_cuda_unavailable", "rocm_no_device_names"}:
        (_override("sleep", None) or time.sleep)(1.0)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_retry_start", file=sys.stderr)
        selected_rocm_python, rocm_detail, rocm_payload, rocm_attempts = _probe_drumsep_runtime_candidates(rocm_candidates, require_gpu=True)
        print(f"timing_utc={_ts()} drumsep_runtime_probe_rocm_retry_end detail={rocm_detail}", file=sys.stderr)
    if selected_rocm_python is not None:
        info = dict(rocm_payload or {})
        info["kind"] = "rocm"
        info["detail"] = rocm_detail
        info["fallback_reason"] = ""
        info["selection_policy"] = selection_policy
        info["rocm_python_attempts"] = rocm_attempts
        return selected_rocm_python, "rocm", info

    if explicit_rocm:
        # Fails closed on failure, matching every other explicit-device
        # branch in this function: an explicit ROCm request must not
        # silently downgrade to CPU. This was previously the other Linux
        # outlier -- see tests/test_linux_drumsep_rocm_fallback_chain.py.
        info = dict(rocm_payload or {})
        info["kind"] = "rocm"
        info["detail"] = rocm_detail
        info["selection_policy"] = "explicit_rocm"
        info["rocm_python_attempts"] = rocm_attempts
        reason = "missing" if rocm_detail == "missing" else "broken"
        return None, reason, info

    cuda_detail = "skipped"
    cuda_attempts: List[Dict[str, Any]] = []
    if _platform_name().startswith("linux") and not explicit_rocm:
        cuda_selection_policy = "gpu_prefer_cuda" if normalized_request == "gpu" else "auto_prefer_cuda"
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_start", file=sys.stderr)
        selected_cuda_python, cuda_detail, cuda_payload, cuda_attempts = _probe_drumsep_runtime_candidates(
            cpu_candidates,
            require_cuda=True,
        )
        print(f"timing_utc={_ts()} drumsep_runtime_probe_cuda_end detail={cuda_detail}", file=sys.stderr)
        if selected_cuda_python is not None:
            print(f"drumsep_runtime_selection_policy={cuda_selection_policy}", file=sys.stderr)
            info = dict(cuda_payload or {})
            info["kind"] = "cuda"
            info["detail"] = cuda_detail
            info["fallback_reason"] = ""
            info["selection_policy"] = cuda_selection_policy
            info["cuda_python_attempts"] = cuda_attempts
            info["rocm_python_attempts"] = rocm_attempts
            return selected_cuda_python, "cuda", info

    print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
    selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(cpu_candidates, require_gpu=False)
    print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
    if selected_cpu_python is not None:
        info = dict(cpu_payload or {})
        info["kind"] = "cpu"
        info["detail"] = cpu_detail
        fallback_reason = f"rocm_skipped:{rocm_detail}"
        if _platform_name().startswith("linux") and not explicit_rocm:
            fallback_reason = fallback_reason + f";cuda_skipped:{cuda_detail}"
        info["fallback_reason"] = fallback_reason
        info["selection_policy"] = "fallback_cpu"
        info["cpu_python_attempts"] = cpu_attempts
        info["rocm_python_attempts"] = rocm_attempts
        info["cuda_python_attempts"] = cuda_attempts
        return selected_cpu_python, "cpu", info

    info = {
        "rocm_detail": rocm_detail,
        "cuda_detail": cuda_detail,
        "cpu_detail": cpu_detail,
        "rocm_python": str(rocm_python),
            "cuda_python": str(cpu_python),
            "cpu_python": str(cpu_python),
        "rocm_python_attempts": rocm_attempts,
        "cuda_python_attempts": cuda_attempts,
        "cpu_python_attempts": cpu_attempts,
        "selection_policy": "fallback_cpu",
        "normalized_request": normalized_request,
    }
    reason = "missing" if rocm_detail == "missing" and cpu_detail == "missing" else "broken"
    return None, reason, info


def verify_drumsep_runtime(
    python_path: Path,
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
    require_directml: bool = False,
    *,
    subprocess_module: Any = None,
    environ: Optional[Mapping[str, str]] = None,
    os_name: Optional[str] = None,
    verify_timeout_seconds: Optional[int] = None,
) -> Tuple[bool, str, Dict[str, Any]]:
    """Validate one candidate without importing its packages in-process."""

    with _runtime_context(
        subprocess_module=subprocess_module,
        environ=environ,
        os_name=os_name,
        verify_timeout_seconds=verify_timeout_seconds,
    ):
        return _verify_drumsep_runtime(
            Path(python_path),
            require_gpu=require_gpu,
            require_mps=require_mps,
            require_cuda=require_cuda,
            require_directml=require_directml,
        )


def runtime_python_path(
    kind: str,
    runtime_base: Optional[Path] = None,
    *,
    platform_name: Optional[str] = None,
    os_name: Optional[str] = None,
    runtime_base_candidates: Optional[Callable[[], List[Path]]] = None,
) -> Path:
    """Return the conventional interpreter path for one runtime family."""

    functions = {
        "cpu": _drumsep_runtime_python_path,
        "main": _main_runtime_python_path,
        "rocm": _drumsep_rocm_runtime_python_path,
        "cuda": _drumsep_cuda_runtime_python_path,
        "directml": _drumsep_directml_runtime_python_path,
    }
    if kind not in functions:
        raise ValueError(f"unknown DrumSep runtime kind: {kind}")
    with _runtime_context(
        platform_name=platform_name,
        os_name=os_name,
        runtime_base_candidates=runtime_base_candidates,
    ):
        return functions[kind](runtime_base)


def runtime_state(
    runtime_base: Optional[Path] = None,
    kind: str = "cpu",
    *,
    runtime_base_candidates: Optional[Callable[[], List[Path]]] = None,
) -> Dict[str, str]:
    with _runtime_context(runtime_base_candidates=runtime_base_candidates):
        return _drumsep_runtime_state(runtime_base, kind)


def ready_to_go_state(
    runtime_base: Optional[Path] = None,
    *,
    runtime_base_candidates: Optional[Callable[[], List[Path]]] = None,
) -> Dict[str, str]:
    with _runtime_context(runtime_base_candidates=runtime_base_candidates):
        return _ready_to_go_state(runtime_base)


def state_python_candidates(state: Dict[str, str], fallback: Path) -> List[Path]:
    return _drumsep_state_python_candidates(state, fallback)


def macos_ready_main_runtime_candidates(
    runtime_base: Optional[Path] = None,
    *,
    platform_name: Optional[str] = None,
    os_name: Optional[str] = None,
    machine: Optional[str] = None,
    runtime_base_candidates: Optional[Callable[[], List[Path]]] = None,
) -> List[Path]:
    with _runtime_context(
        platform_name=platform_name,
        os_name=os_name,
        machine=machine,
        runtime_base_candidates=runtime_base_candidates,
    ):
        return _macos_ready_drumsep_main_runtime_candidates(runtime_base)


def probe_drumsep_runtime_candidates(
    candidates: List[Path],
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
    require_directml: bool = False,
    *,
    verify_runtime: Optional[Callable[..., Tuple[bool, str, Dict[str, Any]]]] = None,
) -> Tuple[Optional[Path], str, Dict[str, Any], List[Dict[str, Any]]]:
    """Probe ordered candidates once each, preserving missing/broken detail."""

    with _runtime_context(verify_runtime=verify_runtime):
        return _probe_drumsep_runtime_candidates_impl(
            candidates,
            require_gpu=require_gpu,
            require_mps=require_mps,
            require_cuda=require_cuda,
            require_directml=require_directml,
        )


def select_drumsep_runtime(
    requested_device: str = "auto",
    runtime_base: Optional[Path] = None,
    *,
    probe_candidates: Optional[Callable[..., Any]] = None,
    verify_runtime: Optional[Callable[..., Tuple[bool, str, Dict[str, Any]]]] = None,
    platform_name: Optional[str] = None,
    os_name: Optional[str] = None,
    machine: Optional[str] = None,
    environ: Optional[Mapping[str, str]] = None,
    runtime_base_candidates: Optional[Callable[[], List[Path]]] = None,
    sleep: Optional[Callable[[float], None]] = None,
    timestamp: Optional[Callable[[], str]] = None,
) -> Tuple[Optional[Path], str, Dict[str, Any]]:
    """Select the production DrumSep runtime using the shared Core policy.

    Optional dependencies are resolved inside each call. They exist for the
    legacy compatibility wrapper and controlled tests; normal callers should
    pass only ``requested_device`` and, when needed, ``runtime_base``.
    """

    with _runtime_context(
        probe_candidates=probe_candidates,
        verify_runtime=verify_runtime,
        platform_name=platform_name,
        os_name=os_name,
        machine=machine,
        environ=environ,
        runtime_base_candidates=runtime_base_candidates,
        sleep=sleep,
        timestamp=timestamp,
    ):
        return _select_drumsep_runtime(requested_device, runtime_base)
