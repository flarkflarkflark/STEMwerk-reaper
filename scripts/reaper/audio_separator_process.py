#!/home/flark/STEMwerk/.venv/bin/python -u
"""
Audio Separator Script for STEMwerk
Thin wrapper around stemwerk-core for REAPER.

Progress output (stdout):
    PROGRESS:<percent>:<stage>
    Example: PROGRESS:45:Processing chunk 3/8
"""

import argparse
from contextlib import contextmanager
import importlib
import importlib.util
import json
import hashlib
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

StemSeparator = None
get_available_devices = None
select_device = None
core_devices = None
stemwerk_core_file = None
_core_loaded = False

MPS_UNSUPPORTED_MARKER = "STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536"
MPS_FALLBACK_ENV = "PYTORCH_ENABLE_MPS_FALLBACK"
DIRECT_DKS_MODEL_ALIAS = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
DIRECT_DKS_MODEL_FILENAME = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
DIRECT_DKS_MODEL_ENTRY_NAME = "MDX23C Model: DrumSep 6stem | (by aufr33 & jarredou)"
DRUMSEP_RUNTIME_DIRNAME = ".venv-drumsep"
DRUMSEP_RUNTIME_ROCM_DIRNAME = ".venv-drumsep-rocm"
DRUMSEP_RUNTIME_GUIDANCE = "Run Setup/Repair Drum Kit Split runtime."
DRUMSEP_HELPER_RELATIVE = Path("_internal") / "stemwerk_drumsep_process.py"


def _is_darwin_arm64() -> bool:
    return sys.platform == "darwin" and platform.machine().lower() in {"arm64", "aarch64"}


def _is_demucs_model(model_name: Optional[str]) -> bool:
    name = str(model_name or "").lower()
    return name.startswith("htdemucs") or name.startswith("hdemucs")


def _is_direct_dks_mode(workflow_mode: Optional[str]) -> bool:
    return str(workflow_mode or "").strip().lower() == "dks_direct"


def _is_direct_dks_source(workflow_mode: Optional[str], workflow_source: Optional[str]) -> bool:
    mode = str(workflow_mode or "").strip().lower()
    source = str(workflow_source or "").strip().lower()
    return source == "dks_direct" or mode == "dks_direct"


def _resolve_run_model(args: argparse.Namespace) -> str:
    if _is_direct_dks_source(getattr(args, "workflow_mode", ""), getattr(args, "workflow_source", "")):
        requested = str(getattr(args, "requested_stage2_model", "") or "").strip()
        if requested:
            return requested
    return str(getattr(args, "model", "htdemucs") or "htdemucs")


def _is_known_drumsep_model_missing_error(exc: Exception) -> bool:
    text = str(exc or "").lower()
    return "not found in supported model files" in text and "model file" in text


def _is_known_drumsep_runtime_unsupported_error(exc: Exception, traceback_text: str, model_name: str) -> bool:
    text = f"{exc}\n{traceback_text}".lower()
    model_text = str(model_name or "").lower()
    if "drumsep" not in model_text and "mdx23c_ep_141" not in model_text:
        return False
    return (
        ("mdxc_separator.py" in text or "mdxc_separator" in text)
        and "attributeerror" in text
        and ("'model'" in text or "\"model\"" in text)
    )


def _emit_direct_dks_preflight_markers(reason: str, requested_model: str, resolved_model: str = "", detail: str = "") -> None:
    print("error_stage=stage2_preflight", file=sys.stderr)
    print(f"error_reason={reason}", file=sys.stderr)
    print(f"requested_model={requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"resolved_model={resolved_model}", file=sys.stderr)
    print(f"Direct Drum Kit Split preflight failed: {reason}", file=sys.stderr)
    print(f"Requested model: {requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"Resolved model: {resolved_model}", file=sys.stderr)
    if detail:
        print(f"Detail: {detail}", file=sys.stderr)
    print(
        "guidance=Update or repair runtime model catalog/audio-separator mapping for DrumSep and retry.",
        file=sys.stderr,
    )


def _emit_direct_dks_runtime_unsupported_markers(requested_model: str, resolved_model: str, detail: str) -> None:
    print("error_stage=stage2_model_load", file=sys.stderr)
    print("error_reason=drumsep_model_runtime_unsupported", file=sys.stderr)
    print(f"requested_model={requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"resolved_model={resolved_model}", file=sys.stderr)
    print("Direct Drum Kit Split model load failed: drumsep_model_runtime_unsupported", file=sys.stderr)
    print(f"Requested model: {requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"Resolved model: {resolved_model}", file=sys.stderr)
    if detail:
        print(f"Detail: {detail}", file=sys.stderr)


def _emit_direct_dks_stage2_runtime_markers(reason: str, python_path: Path, detail: str = "") -> None:
    print("error_stage=stage2_runtime", file=sys.stderr)
    print(f"error_reason={reason}", file=sys.stderr)
    print(f"drumsep_runtime_python={python_path}", file=sys.stderr)
    if detail:
        print(f"detail={detail}", file=sys.stderr)
    print(f"guidance={DRUMSEP_RUNTIME_GUIDANCE}", file=sys.stderr)
    if reason == "drumsep_runtime_missing":
        print("Direct Drum Kit Split runtime is not installed.", file=sys.stderr)
    else:
        print("Direct Drum Kit Split runtime is broken.", file=sys.stderr)
    print(DRUMSEP_RUNTIME_GUIDANCE, file=sys.stderr)


def _emit_direct_dks_helper_failure_markers(reason: str, stage: str, requested_model: str, resolved_model: str, detail: str = "") -> None:
    print(f"error_stage={stage}", file=sys.stderr)
    print(f"error_reason={reason}", file=sys.stderr)
    print(f"requested_model={requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"resolved_model={resolved_model}", file=sys.stderr)
    if detail:
        print(f"detail={detail}", file=sys.stderr)
    print(f"Direct Drum Kit Split helper failed: {reason}", file=sys.stderr)


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _drumsep_helper_path() -> Path:
    return Path(__file__).resolve().parent / DRUMSEP_HELPER_RELATIVE


def _find_repo_download_checks_path() -> Optional[Path]:
    payload_root = _repository_root() / "installer" / "windows" / "payload"
    if not payload_root.exists():
        return None
    candidates = sorted(
        payload_root.glob("models-*-allmodels/download_checks.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if candidates:
        return candidates[0]
    fallback = sorted(payload_root.glob("models-*/download_checks.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    return fallback[0] if fallback else None


def _read_json_file(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _runtime_download_checks_path(model_cache_dir: Path) -> Path:
    return model_cache_dir / "download_checks.json"


def _resolve_direct_dks_model_catalog_entry(requested_model: str, model_cache_dir: Path) -> Tuple[str, Dict[str, str], Optional[Path], List[str], str]:
    requested = str(requested_model or "").strip()
    if requested and requested != DIRECT_DKS_MODEL_ALIAS and requested != DIRECT_DKS_MODEL_FILENAME:
        return requested, {}, None, [], "unsupported_requested_model"

    resolved_default = DIRECT_DKS_MODEL_FILENAME
    checked_paths: List[str] = []
    candidate_paths: List[Path] = []
    runtime_checks = _runtime_download_checks_path(model_cache_dir)
    candidate_paths.append(runtime_checks)
    repo_checks = _find_repo_download_checks_path()
    if repo_checks:
        candidate_paths.append(repo_checks)

    seen: Set[str] = set()
    for path in candidate_paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        checked_paths.append(key + (" [exists]" if path.exists() else " [missing]"))
        if not path.exists():
            continue
        try:
            data = _read_json_file(path)
        except Exception:
            continue
        other_network = data.get("other_network_list_new", {}) or {}
        if not isinstance(other_network, dict):
            continue
        entry = other_network.get(DIRECT_DKS_MODEL_ENTRY_NAME, {}) or {}
        if not isinstance(entry, dict):
            continue
        normalized = {str(k): str(v) for k, v in entry.items() if str(v).strip()}
        if not normalized:
            return resolved_default, {}, path, checked_paths, "catalog_entry_empty"
        return resolved_default, normalized, path, checked_paths, "ok"

    return resolved_default, {}, None, checked_paths, "catalog_entry_missing"


def _ensure_runtime_download_checks_has_drumsep(model_cache_dir: Path, entry_name: str, entry_payload: Dict[str, str], source_checks_path: Optional[Path]) -> Tuple[bool, str]:
    checks_path = model_cache_dir / "download_checks.json"
    checks_data: Dict[str, Any]
    try:
        if checks_path.exists():
            checks_data = _read_json_file(checks_path)
        elif source_checks_path and source_checks_path.exists():
            checks_data = _read_json_file(source_checks_path)
        else:
            return False, "runtime_download_checks_missing"
    except Exception as exc:
        return False, f"download_checks_read_failed:{exc}"

    changed = False
    mdx23c = checks_data.setdefault("mdx23c_download_list", {})
    if not isinstance(mdx23c, dict):
        return False, "mdx23c_download_list_invalid"
    current = mdx23c.get(entry_name)
    if current != entry_payload:
        mdx23c[entry_name] = dict(entry_payload)
        changed = True

    if changed or not checks_path.exists():
        try:
            checks_path.parent.mkdir(parents=True, exist_ok=True)
            checks_path.write_text(json.dumps(checks_data, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        except Exception as exc:
            return False, f"download_checks_write_failed:{exc}"
    return True, str(checks_path)


def _download_direct_dks_assets(model_cache_dir: Path, asset_map: Dict[str, str]) -> Tuple[bool, str]:
    for filename, url in asset_map.items():
        target = model_cache_dir / filename
        if target.exists():
            continue
        if not url:
            return False, f"asset_url_missing:{filename}"
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            tmp = target.with_suffix(target.suffix + ".part")
            tmp.write_bytes(data)
            tmp.replace(target)
            if target.suffix.lower() == ".ckpt":
                digest = hashlib.sha256(target.read_bytes()).hexdigest()
                print(f"drumsep_cache_sha256={digest}", file=sys.stderr)
            print(f"drumsep_cache_asset={target}", file=sys.stderr)
        except Exception as exc:
            return False, f"asset_download_failed:{filename}:{exc}"
    return True, "ok"


def _direct_dks_preflight_check(model_name: str, model_cache_dir: Path) -> Tuple[bool, str, str, Optional[str]]:
    # Force an explicit model-catalog lookup before normal workflow setup.
    # This prevents delayed failure in sep.separate()/load_model for known
    # unresolved DrumSep model names.
    requested_model = str(model_name or "").strip()
    resolved_model, asset_map, source_path, checked_paths, lookup_status = _resolve_direct_dks_model_catalog_entry(
        requested_model,
        model_cache_dir,
    )
    if checked_paths:
        print("catalog_paths_checked=" + " | ".join(checked_paths), file=sys.stderr)
    print(f"catalog_lookup_status={lookup_status}", file=sys.stderr)
    if not asset_map:
        return False, requested_model, resolved_model, lookup_status
    ok, check_detail = _ensure_runtime_download_checks_has_drumsep(
        model_cache_dir,
        DIRECT_DKS_MODEL_ENTRY_NAME,
        asset_map,
        source_path,
    )
    if not ok:
        return False, requested_model, resolved_model, check_detail
    print(f"requested_model={requested_model}", file=sys.stderr)
    print(f"resolved_model={resolved_model}", file=sys.stderr)
    print(f"catalog_source={source_path if source_path else 'none'}", file=sys.stderr)
    dl_ok, dl_detail = _download_direct_dks_assets(model_cache_dir, asset_map)
    if not dl_ok:
        return False, requested_model, resolved_model, dl_detail
    try:
        from audio_separator.separator import Separator as AudioSeparator

        sep = AudioSeparator(model_file_dir=str(model_cache_dir), output_dir=".")
        sep.download_model_files(resolved_model)
        return True, requested_model, resolved_model, None
    except Exception as exc:
        if _is_known_drumsep_model_missing_error(exc):
            return False, requested_model, resolved_model, str(exc)
        raise


def _enforce_mps_demucs_cpu_policy(requested_device: str, resolved_device: str, model_name: str) -> str:
    if resolved_device != "mps":
        return resolved_device
    if not _is_darwin_arm64():
        return resolved_device
    if not _is_demucs_model(model_name):
        return resolved_device
    requested = str(requested_device or "")
    print("STEMWERK_MPS_DISABLED_FOR_DEMUCS=1", file=sys.stderr)
    print("STEMWERK_MPS_DISABLED_REASON=mps_demucs_output_channels_unsupported", file=sys.stderr)
    print(f"STEMWERK_MPS_CONTEXT requested_device={requested}", file=sys.stderr)
    print("STEMWERK_MPS_CONTEXT selected_device=cpu", file=sys.stderr)
    print(f"STEMWERK_DIAG requested_device={requested}", file=sys.stderr)
    print("STEMWERK_DIAG selected_device=cpu", file=sys.stderr)
    return "cpu"


def _require_core() -> None:
    global StemSeparator, get_available_devices, select_device, core_devices, stemwerk_core_file, _core_loaded
    if _core_loaded:
        return
    try:
        import stemwerk_core as _stemwerk_core
        from stemwerk_core import StemSeparator as _StemSeparator
        from stemwerk_core import get_available_devices as _get_available_devices
        from stemwerk_core import select_device as _select_device
        from stemwerk_core import devices as _core_devices
    except Exception as exc:
        raise ModuleNotFoundError(
            "stemwerk_core is required for this operation. Install with: pip install stemwerk-core"
        ) from exc

    StemSeparator = _StemSeparator
    get_available_devices = _get_available_devices
    select_device = _select_device
    core_devices = _core_devices
    stemwerk_core_file = getattr(_stemwerk_core, "__file__", None)
    _core_loaded = True


class _TeeTextIO:
    def __init__(self, *streams):
        self._streams = [s for s in streams if s is not None]

    def write(self, s):
        for st in self._streams:
            try:
                st.write(s)
            except Exception:
                pass
        return len(s)

    def flush(self):
        for st in self._streams:
            try:
                st.flush()
            except Exception:
                pass


_progress_file = None
_phase_file = None


def _windows_no_window_kwargs() -> Dict[str, int]:
    if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW"):
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


@contextmanager
def _working_directory(path: Path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def _resolve_stem_path(output_dir: Path, stem_path: Path | str) -> Path:
    path = Path(stem_path)
    if path.is_absolute():
        return path
    return output_dir / path


def _setup_reaper_io(output_dir: Optional[str]):
    """If output_dir is set, write progress/log markers into that folder."""
    global _phase_file, _progress_file
    if not output_dir:
        return None

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    stdout_path = out / "stdout.txt"
    stderr_path = out / "separation_log.txt"
    phase_path = out / "phase_events.jsonl"

    stdout_f = open(stdout_path, "w", encoding="utf-8", buffering=1)
    stderr_f = open(stderr_path, "w", encoding="utf-8", buffering=1)
    phase_f = open(phase_path, "w", encoding="utf-8", buffering=1)
    _progress_file = stdout_f
    _phase_file = phase_f

    sys.stderr = _TeeTextIO(sys.stderr, stderr_f)

    # done.txt / exit_code.txt are owned by the async launcher wrapper.
    # Writing done.txt here can race with exit_code emission and cause
    # diagnostics persistence to snapshot before exit_code.txt exists.
    return None


def _read_simple_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return values
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        if key:
            values[key] = value
    return values


def _runtime_base_candidates() -> List[Path]:
    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(path_value: Optional[Path | str]) -> None:
        if not path_value:
            return
        try:
            path = Path(path_value).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            add(Path(local_appdata) / "STEMwerk")
    elif sys.platform == "darwin":
        add(Path.home() / "Library" / "Application Support" / "STEMwerk")
    else:
        xdg_data_home = os.environ.get("XDG_DATA_HOME")
        if xdg_data_home:
            add(Path(xdg_data_home) / "STEMwerk")
        add(Path.home() / ".local" / "share" / "STEMwerk")

    return candidates


def _drumsep_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_DIRNAME
    if os.name == "nt":
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _drumsep_rocm_runtime_python_path(runtime_base: Optional[Path] = None) -> Path:
    base = runtime_base or (_runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk")
    runtime_dir = base / DRUMSEP_RUNTIME_ROCM_DIRNAME
    if os.name == "nt":
        return runtime_dir / "Scripts" / "python.exe"
    return runtime_dir / "bin" / "python"


def _verify_drumsep_runtime(python_path: Path, require_gpu: bool = False) -> Tuple[bool, str, Dict[str, Any]]:
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
try:
    import torch
    torch_hip = str(getattr(torch.version, "hip", "") or "")
    torch_cuda_available = bool(torch.cuda.is_available())
    if torch_cuda_available:
        for idx in range(int(torch.cuda.device_count())):
            try:
                device_names.append(str(torch.cuda.get_device_name(idx)))
            except Exception:
                pass
except Exception:
    pass

print(json.dumps({
    "ok": True,
    "versions": versions,
    "torch_hip": torch_hip,
    "torch_cuda_available": torch_cuda_available,
    "device_names": device_names,
}, sort_keys=True))
"""
    try:
        completed = subprocess.run(
            [str(python_path), "-c", verify_code],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            **_windows_no_window_kwargs(),
        )
    except Exception as exc:
        return False, f"verify_spawn_failed:{type(exc).__name__}:{exc}", {}

    output = " ".join(part.strip() for part in (completed.stdout, completed.stderr) if part and part.strip())
    if completed.returncode != 0:
        return False, output[:1200] or f"verify_exit_{completed.returncode}", {}

    try:
        payload = json.loads((completed.stdout or "").strip() or "{}")
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

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

    return True, output[:1200] or "ok", payload


def _select_drumsep_runtime(runtime_base: Optional[Path] = None) -> Tuple[Optional[Path], str, Dict[str, Any]]:
    rocm_python = _drumsep_rocm_runtime_python_path(runtime_base)
    cpu_python = _drumsep_runtime_python_path(runtime_base)

    rocm_ok, rocm_detail, rocm_payload = _verify_drumsep_runtime(rocm_python, require_gpu=True)
    if rocm_ok:
        info = dict(rocm_payload or {})
        info["kind"] = "rocm"
        info["detail"] = rocm_detail
        info["fallback_reason"] = ""
        return rocm_python, "rocm", info

    cpu_ok, cpu_detail, cpu_payload = _verify_drumsep_runtime(cpu_python, require_gpu=False)
    if cpu_ok:
        info = dict(cpu_payload or {})
        info["kind"] = "cpu"
        info["detail"] = cpu_detail
        info["fallback_reason"] = f"rocm_skipped:{rocm_detail}"
        return cpu_python, "cpu", info

    info = {
        "rocm_detail": rocm_detail,
        "cpu_detail": cpu_detail,
        "rocm_python": str(rocm_python),
        "cpu_python": str(cpu_python),
    }
    reason = "missing" if rocm_detail == "missing" and cpu_detail == "missing" else "broken"
    return None, reason, info


def _run_direct_dks_drumsep_helper(
    input_path: Path,
    output_root: Path,
    model_cache_dir: Path,
    drumsep_python: Path,
    requested_model: str,
    resolved_model: str,
) -> Tuple[bool, Dict[str, str], str, str]:
    helper_path = _drumsep_helper_path()
    result_json = output_root / "drumsep_result.json"
    helper_stdout = output_root / "drumsep_helper_stdout.txt"
    helper_stderr = output_root / "drumsep_helper_stderr.txt"
    helper_log = output_root / "drumsep_helper.log"

    print("drumsep_helper_start", file=sys.stderr)
    print(f"drumsep_helper_python={drumsep_python}", file=sys.stderr)
    print(f"drumsep_helper_script={helper_path}", file=sys.stderr)
    print(f"drumsep_helper_model={resolved_model}", file=sys.stderr)
    print(f"drumsep_helper_output_dir={output_root}", file=sys.stderr)
    print(f"drumsep_helper_result_json={result_json}", file=sys.stderr)
    print(f"drumsep_helper_stdout={helper_stdout}", file=sys.stderr)
    print(f"drumsep_helper_stderr={helper_stderr}", file=sys.stderr)

    if not helper_path.exists():
        return False, {}, "drumsep_helper_failed", f"helper script missing: {helper_path}"

    cmd = [
        str(drumsep_python),
        str(helper_path),
        "--input",
        str(input_path),
        "--output-dir",
        str(output_root),
        "--model-dir",
        str(model_cache_dir),
        "--model",
        resolved_model,
        "--result-json",
        str(result_json),
        "--log-file",
        str(helper_log),
    ]
    print("PROGRESS:1:Starting DrumSep runtime", flush=True)

    def helper_log_percent() -> Optional[int]:
        try:
            text = helper_log.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return None
        matches = list(re.finditer(r"(\d{1,3})%\|", text))
        if not matches:
            return None
        return max(0, min(99, int(matches[-1].group(1))))

    with helper_stdout.open("w", encoding="utf-8", errors="replace") as stdout_fh, helper_stderr.open(
        "w", encoding="utf-8", errors="replace"
    ) as stderr_fh:
        process = subprocess.Popen(
            cmd,
            text=True,
            stdout=stdout_fh,
            stderr=stderr_fh,
            **_windows_no_window_kwargs(),
        )
        start_time = time.monotonic()
        last_percent = -1
        while True:
            rc = process.poll()
            percent = helper_log_percent()
            if percent is None:
                elapsed = int(time.monotonic() - start_time)
                percent = min(12, 1 + elapsed // 10)
            if percent != last_percent:
                print(f"PROGRESS:{percent}:DrumSep stage2 separating kit stems", flush=True)
                last_percent = percent
            if rc is not None:
                break
            if time.monotonic() - start_time > 60 * 60:
                process.kill()
                return False, {}, "drumsep_helper_failed", "helper timeout after 3600 seconds"
            time.sleep(2.0)

    completed_returncode = process.returncode

    helper_stdout_text = helper_stdout.read_text(encoding="utf-8", errors="replace") if helper_stdout.exists() else ""
    helper_stderr_text = helper_stderr.read_text(encoding="utf-8", errors="replace") if helper_stderr.exists() else ""
    print(f"drumsep_helper_returncode={completed_returncode}", file=sys.stderr)
    if helper_stdout_text:
        print("drumsep_helper_stdout_begin", file=sys.stderr)
        print(helper_stdout_text.rstrip(), file=sys.stderr)
        print("drumsep_helper_stdout_end", file=sys.stderr)
    if helper_stderr_text:
        print("drumsep_helper_stderr_begin", file=sys.stderr)
        print(helper_stderr_text.rstrip(), file=sys.stderr)
        print("drumsep_helper_stderr_end", file=sys.stderr)

    try:
        result_data = json.loads(result_json.read_text(encoding="utf-8"))
    except Exception as exc:
        return False, {}, "drumsep_helper_failed", f"failed reading helper result JSON: {type(exc).__name__}: {exc}"

    if completed_returncode != 0 or not result_data.get("ok"):
        reason = str(result_data.get("error_reason") or "drumsep_helper_failed")
        detail = str(result_data.get("message") or result_data)
        return False, {}, reason, detail

    raw_stems = result_data.get("stems") or {}
    if not isinstance(raw_stems, dict):
        return False, {}, "drumsep_output_count_mismatch", "helper result stems is not an object"

    key_to_reaper = {
        "kick": "kick",
        "snare": "snare",
        "toms": "toms",
        "hihat": "hi-hat",
        "ride": "ride",
        "crash": "crash",
    }
    reaper_stems: Dict[str, str] = {}
    for source_key, reaper_key in key_to_reaper.items():
        value = raw_stems.get(source_key)
        if not value:
            return False, {}, "drumsep_output_count_mismatch", f"missing helper stem: {source_key}"
        path = _resolve_stem_path(output_root, str(value))
        if not path.exists():
            return False, {}, "drumsep_output_count_mismatch", f"helper stem missing on disk: {path}"
        target = output_root / f"{reaper_key}.wav"
        if path.resolve() != target.resolve():
            if target.exists():
                target.unlink()
            shutil.move(str(path), str(target))
        reaper_stems[reaper_key] = str(target)
        print(f"  {reaper_key}:  {target}", file=sys.stderr)

    print("drumsep_helper_ok=true", file=sys.stderr)
    return True, reaper_stems, "", ""


def _prepend_path(path_value: str) -> None:
    current_path = os.environ.get("PATH", "")
    path_parts = current_path.split(os.pathsep) if current_path else []
    normalized = path_value.lower()
    if normalized not in {part.lower() for part in path_parts if part}:
        os.environ["PATH"] = path_value + (os.pathsep + current_path if current_path else "")


def _ensure_runtime_ffmpeg_wrapper(runtime_base: Path, ffmpeg_path: Path) -> Optional[Path]:
    if os.name == "nt":
        return ffmpeg_path
    if ffmpeg_path.name == "ffmpeg":
        return ffmpeg_path

    wrapper_dir = runtime_base / "bin"
    wrapper_path = wrapper_dir / "ffmpeg"
    try:
        wrapper_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return None

    target = str(ffmpeg_path)
    try:
        if wrapper_path.exists() or wrapper_path.is_symlink():
            try:
                if wrapper_path.is_symlink() and os.readlink(wrapper_path) == target:
                    return wrapper_path
            except Exception:
                pass
            wrapper_path.unlink()
        os.symlink(target, wrapper_path)
        return wrapper_path
    except Exception:
        script_body = "#!/bin/sh\nexec " + shlex.quote(target) + " \"$@\"\n"
        try:
            wrapper_path.write_text(script_body, encoding="utf-8")
            wrapper_path.chmod(0o755)
            return wrapper_path
        except Exception:
            return None


def _candidate_ffmpeg_paths() -> List[Path]:
    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(path_value: Optional[str | Path]) -> None:
        if not path_value:
            return
        try:
            path = Path(path_value).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    for env_key in ("STEMWERK_FFMPEG_PATH", "FFMPEG_PATH", "IMAGEIO_FFMPEG_EXE"):
        add(os.environ.get(env_key))

    for runtime_base in _runtime_base_candidates():
        add(runtime_base / "ffmpeg" / "bin" / "ffmpeg.exe")
        add(runtime_base / "ffmpeg" / "ffmpeg.exe")
        add(runtime_base / "bin" / "ffmpeg.exe")
        add(runtime_base / "ffmpeg" / "bin" / "ffmpeg")
        add(runtime_base / "ffmpeg" / "ffmpeg")
        add(runtime_base / "bin" / "ffmpeg")
        bootstrap_values = _read_simple_env_file(runtime_base / "state" / "bootstrap.env")
        add(bootstrap_values.get("FFMPEG_PATH"))
        add(bootstrap_values.get("FFMPEG"))
        add(bootstrap_values.get("MANAGED_FFMPEG_PATH"))
        capabilities_values = _read_simple_env_file(runtime_base / "state" / "capabilities.env")
        add(capabilities_values.get("FFMPEG_PATH"))
        add(capabilities_values.get("FFMPEG"))
        add(capabilities_values.get("MANAGED_FFMPEG_PATH"))

    exe_dir = Path(sys.executable).resolve().parent
    add(exe_dir / "ffmpeg.exe")
    add(exe_dir.parent / "ffmpeg" / "bin" / "ffmpeg.exe")

    found = shutil.which("ffmpeg")
    add(found)

    return candidates


def _configure_ffmpeg_runtime() -> Tuple[Optional[Path], Optional[Path], Optional[str]]:
    for candidate in _candidate_ffmpeg_paths():
        try:
            if not candidate.exists() or candidate.is_dir():
                continue
        except Exception:
            continue

        candidate_str = str(candidate.resolve())
        runtime_base = _runtime_base_candidates()[0] if _runtime_base_candidates() else Path.home() / ".local" / "share" / "STEMwerk"
        wrapper = _ensure_runtime_ffmpeg_wrapper(runtime_base, Path(candidate_str))
        path_prefix = str(wrapper.parent if wrapper else Path(candidate_str).parent)
        _prepend_path(path_prefix)
        os.environ["STEMWERK_FFMPEG_PATH"] = candidate_str
        os.environ["FFMPEG_PATH"] = candidate_str
        os.environ["IMAGEIO_FFMPEG_EXE"] = candidate_str
        return Path(candidate_str), wrapper, path_prefix
    return None, None, None


def _default_model_cache_dir() -> Path:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override).expanduser()

    home = Path.home()
    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return Path(local_appdata) / "STEMwerk" / "models"
        return home / "AppData" / "Local" / "STEMwerk" / "models"

    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "STEMwerk" / "models"

    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return Path(xdg_data_home) / "STEMwerk" / "models"
    return home / ".local" / "share" / "STEMwerk" / "models"


def _configure_model_cache_runtime() -> Path:
    model_dir = _default_model_cache_dir()
    try:
        model_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    os.environ["AUDIO_SEPARATOR_MODEL_DIR"] = str(model_dir)
    return model_dir


def emit_progress(percent: float, stage: str = ""):
    """Output progress in machine-readable format for Lua to parse."""
    line = f"PROGRESS:{int(percent)}:{stage}\n"
    global _progress_file
    if _progress_file is not None:
        try:
            _progress_file.write(line)
            _progress_file.flush()
        except Exception:
            pass
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except Exception:
        pass


def emit_phase(phase_name: str):
    """Write timestamped phase markers to a per-job JSONL file."""
    global _phase_file
    if _phase_file is None:
        return
    event = {
        "time": time.time(),
        "phase": str(phase_name),
    }
    try:
        _phase_file.write(json.dumps(event, separators=(",", ":")) + "\n")
        _phase_file.flush()
    except Exception:
        pass


def _split_list(value: Optional[str]) -> List[str]:
    if not value:
        return []
    text = str(value)
    for sep in (";", "\n", "\t", " "):
        text = text.replace(sep, ",")
    return [part.strip() for part in text.split(",") if part.strip()]


def _get_device_skips() -> List[Dict[str, str]]:
    _require_core()
    skips = getattr(core_devices, "_DEVICE_SKIPS", None)
    if not skips:
        return []
    return [dict(item) for item in skips]


def _get_skip_ids() -> Set[str]:
    ids: Set[str] = set()
    for s in _get_device_skips():
        sid = s.get("id", "")
        if sid:
            ids.add(sid)
    return ids


def _prefer_linux_amd_device(devices: List[Dict[str, str]], skip_ids: Set[str]) -> Optional[Dict[str, str]]:
    if not devices:
        return None
    candidates = [d for d in devices if d.get("id") not in skip_ids]
    if not candidates:
        return None

    def score(dev: Dict[str, str]) -> int:
        name = (dev.get("name") or "").lower()
        sc = 0
        if "radeon rx" in name or " rx " in name or name.startswith("rx "):
            sc += 3
        if "radeon" in name and "graphics" not in name:
            sc += 1
        if "graphics" in name and "rx" not in name:
            sc -= 1
        if "780m" in name:
            sc -= 2
        return sc

    return max(candidates, key=score)


def _clean_env() -> Dict[str, str]:
    env = dict(os.environ)
    for key in ("HIP_VISIBLE_DEVICES", "HSA_OVERRIDE_GFX_VERSION", "ROCR_VISIBLE_DEVICES", "CUDA_VISIBLE_DEVICES"):
        env.pop(key, None)
    return env

def _run_cmd_lines(cmd: List[str]) -> List[str]:
    try:
        out = subprocess.check_output(
            cmd,
            stderr=subprocess.STDOUT,
            text=True,
            env=_clean_env(),
            **_windows_no_window_kwargs(),
        )
    except Exception:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def _filter_rocm_lines(lines: List[str]) -> List[str]:
    keep: List[str] = []
    for line in lines:
        if re.search(r"(Marketing Name|Name:|gfx\d+|Device Type|Vendor Name)", line):
            keep.append(line.strip())
    return keep


def _get_rocm_host_lines() -> List[str]:
    lines: List[str] = []
    if shutil.which("rocminfo"):
        lines.extend(_filter_rocm_lines(_run_cmd_lines(["rocminfo"])))
    if shutil.which("rocm-smi"):
        smi = _run_cmd_lines(["rocm-smi"])
        for line in smi:
            if "GPU" in line or "gfx" in line or "Device" in line:
                lines.append(line)
    seen: Set[str] = set()
    out: List[str] = []
    for line in lines:
        if line not in seen:
            out.append(line)
            seen.add(line)
    return out


def _emit_env_diagnostics() -> None:
    keys = [
        "ROCM_PATH",
        "LD_LIBRARY_PATH",
        "HIP_VISIBLE_DEVICES",
        "HSA_OVERRIDE_GFX_VERSION",
        "ROCR_VISIBLE_DEVICES",
        "CUDA_VISIBLE_DEVICES",
    ]
    for key in keys:
        val = os.environ.get(key)
        if val is not None and val != "":
            print(f"STEMWERK_ENV\t{key}={val}")
        else:
            print(f"STEMWERK_ENV\t{key}=")


def _build_env_json() -> Dict[str, object]:
    env: Dict[str, object] = {
        "platform": platform.system(),
        "platform_machine": platform.machine(),
        "python": platform.python_version(),
        "python_version": platform.python_version(),
        "sys_executable": sys.executable,
        "python_executable": sys.executable,
        "pythonpath_env": os.environ.get("PYTHONPATH"),
        "ld_library_path_env": os.environ.get("LD_LIBRARY_PATH"),
        "mps_fallback_env": os.environ.get(MPS_FALLBACK_ENV),
        "torch": None,
        "torch_version": None,
        "torchaudio_version": None,
        "torch_file": None,
        "cuda_available": False,
        "cuda_count": 0,
        "mps_built": False,
        "mps_available": False,
        "selected_device": None,
        "directml_possible": importlib.util.find_spec("torch_directml") is not None,
        "rocm_path_exists": False,
        "torch_hip": None,
        "onnxruntime_version": None,
        "onnxruntime": None,
        "onnxruntime-gpu": None,
        "onnxruntime-directml": None,
        "onnxruntime-silicon": None,
    }

    try:
        env["rocm_path_exists"] = bool(os.path.exists("/opt/rocm") or os.environ.get("ROCM_PATH"))
    except Exception:
        env["rocm_path_exists"] = False

    try:
        import torch

        env["torch"] = getattr(torch, "__version__", str(torch))
        env["torch_version"] = env["torch"]
        try:
            env["torch_file"] = getattr(torch, "__file__", None)
        except Exception:
            env["torch_file"] = None
        try:
            env["torch_hip"] = getattr(getattr(torch, "version", None), "hip", None)
        except Exception:
            env["torch_hip"] = None
        try:
            env["cuda_available"] = bool(torch.cuda.is_available())
        except Exception:
            env["cuda_available"] = False
        try:
            env["cuda_count"] = int(torch.cuda.device_count()) if env["cuda_available"] else 0
        except Exception:
            env["cuda_count"] = 0
        try:
            env["mps_built"] = bool(
                getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_built()
            )
        except Exception:
            env["mps_built"] = False
        try:
            env["mps_available"] = bool(
                getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available()
            )
        except Exception:
            env["mps_available"] = False
    except Exception:
        pass

    try:
        import torchaudio

        env["torchaudio_version"] = getattr(torchaudio, "__version__", str(torchaudio))
    except Exception:
        pass

    try:
        try:
            from importlib.metadata import version as dist_version
        except Exception:
            from importlib_metadata import version as dist_version  # type: ignore

        def _dist(name: str) -> Optional[str]:
            try:
                return dist_version(name)
            except Exception:
                return None

        env["onnxruntime"] = _dist("onnxruntime")
        env["onnxruntime-gpu"] = _dist("onnxruntime-gpu")
        env["onnxruntime-directml"] = _dist("onnxruntime-directml")
        env["onnxruntime-silicon"] = _dist("onnxruntime-silicon")
        env["onnxruntime_version"] = (
            env["onnxruntime-silicon"]
            or env["onnxruntime-directml"]
            or env["onnxruntime-gpu"]
            or env["onnxruntime"]
        )
    except Exception:
        pass

    return env


def _emit_runtime_diagnostics(selected_device: Optional[str]) -> Dict[str, object]:
    env = _build_env_json()
    env["selected_device"] = selected_device
    print(f"STEMWERK_DIAG python_executable={env.get('python_executable')}", file=sys.stderr)
    print(f"STEMWERK_DIAG python_version={env.get('python_version')}", file=sys.stderr)
    print(f"STEMWERK_DIAG platform={env.get('platform')} machine={env.get('platform_machine')}", file=sys.stderr)
    print(f"STEMWERK_DIAG torch_version={env.get('torch_version')}", file=sys.stderr)
    print(f"STEMWERK_DIAG torchaudio_version={env.get('torchaudio_version')}", file=sys.stderr)
    print(f"STEMWERK_DIAG onnxruntime_version={env.get('onnxruntime_version')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_built={env.get('mps_built')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_available={env.get('mps_available')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_fallback_env={env.get('mps_fallback_env')}", file=sys.stderr)
    print(f"STEMWERK_DIAG selected_device={selected_device}", file=sys.stderr)
    return env


def _enable_mps_runtime_fallback(requested_device: str, resolved_device: str) -> bool:
    if resolved_device != "mps":
        return False
    os.environ[MPS_FALLBACK_ENV] = "1"
    print(
        f"STEMWERK_DIAG mps_fallback_enabled=1 requested_device={requested_device} resolved_device={resolved_device}",
        file=sys.stderr,
    )
    return True


def _classify_runtime_failure(
    exc: BaseException,
    traceback_text: str,
    requested_device: str,
    selected_device: str,
    model_name: str,
    env: Optional[Dict[str, object]] = None,
) -> Optional[Dict[str, object]]:
    text = "\n".join(
        part for part in (str(exc or ""), traceback_text or "") if part
    )
    lower = text.lower()
    is_mps_unsupported = (
        "output channels > 65536 not supported at the mps device" in lower
        or (
            "notimplementederror" in lower
            and "pytorch_enable_mps_fallback" in lower
            and "mps" in lower
        )
    )
    if not is_mps_unsupported:
        return None

    env = env or {}
    details = {
        "requested_device": requested_device or "",
        "selected_device": selected_device or "",
        "model": model_name or "",
        "torch_version": str(env.get("torch_version") or env.get("torch") or "unknown"),
        "platform": str(env.get("platform") or platform.system()),
        "platform_machine": str(env.get("platform_machine") or platform.machine()),
        "mps_built": str(env.get("mps_built")),
        "mps_available": str(env.get("mps_available")),
        "mps_fallback_env": str(env.get("mps_fallback_env") or os.environ.get(MPS_FALLBACK_ENV, "")),
    }
    return {
        "marker": MPS_UNSUPPORTED_MARKER,
        "details": details,
    }


def _classify_model_failure_text(text: str) -> Optional[Dict[str, str]]:
    lower = str(text or "").lower()
    if not lower:
        return None

    has_timeout = any(
        token in lower
        for token in (
            "read timed out",
            "httpsconnectionpool",
            "max retries exceeded",
            "timeouterror",
        )
    )
    has_download = any(
        token in lower
        for token in (
            "dl.fbaipublicfiles.com",
            "connectionerror",
            "temporary failure in name resolution",
            "name or service not known",
            "certificate verify failed",
        )
    )
    has_checksum = "invalid checksum" in lower or ("checksum" in lower and ".th" in lower)

    url_match = re.search(r"(https?://[^\s'\"]+)", text or "")
    path_match = re.search(r"([^\r\n]*\.th)", text or "", flags=re.IGNORECASE)

    if has_checksum:
        return {
            "error_class": "model_checksum_failed",
            "error_hint": "Cached model file appears corrupted. Delete/redownload model cache.",
            "model_cache_hint": "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            "model_url": url_match.group(1) if url_match else "",
            "model_path": path_match.group(1).strip() if path_match else "",
        }
    if has_timeout and (has_download or ".th" in lower):
        return {
            "error_class": "model_download_timeout",
            "error_hint": "Model download timed out. Check network/VPN/firewall or delete partial model cache and retry.",
            "model_cache_hint": "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            "model_url": url_match.group(1) if url_match else "",
            "model_path": path_match.group(1).strip() if path_match else "",
        }
    if has_download:
        return {
            "error_class": "model_download_failed",
            "error_hint": "Model download failed. Check internet/DNS/proxy/VPN/firewall and retry.",
            "model_cache_hint": "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            "model_url": url_match.group(1) if url_match else "",
            "model_path": path_match.group(1).strip() if path_match else "",
        }
    return None


def _parse_major_minor(version_text: Optional[str]) -> Tuple[int, int]:
    raw = str(version_text or "").strip()
    match = re.match(r"^\s*(\d+)\.(\d+)", raw)
    if not match:
        return (0, 0)
    return (int(match.group(1)), int(match.group(2)))


def _enable_torch_weights_only_compat(model_name: str, selected_device: str) -> bool:
    if not _is_demucs_model(model_name):
        print("STEMWERK_DIAG torch_weights_only_compat=off model_family=non_demucs", file=sys.stderr)
        return False

    try:
        import torch
    except Exception:
        print("STEMWERK_DIAG torch_weights_only_compat=off torch_import_failed=1", file=sys.stderr)
        return False

    torch_ver = str(getattr(torch, "__version__", ""))
    major, minor = _parse_major_minor(torch_ver)
    if major < 2 or (major == 2 and minor < 6):
        print(
            f"STEMWERK_DIAG torch_weights_only_compat=off torch_version={torch_ver} model={model_name} device={selected_device}",
            file=sys.stderr,
        )
        return False

    os.environ["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"
    print(
        f"STEMWERK_DIAG torch_weights_only_compat=enabled mode=TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD "
        f"torch_version={torch_ver} model={model_name} device={selected_device}",
        file=sys.stderr,
    )
    return True


def _log_device_diagnostics(devices: List[Dict[str, str]], env: Dict[str, object]) -> None:
    try:
        ids = [d.get("id", "") for d in devices]
        print(f"STEMWERK_DIAG devices={ids}", file=sys.stderr)
    except Exception:
        pass

    try:
        print(
            "STEMWERK_DIAG cuda_available="
            + str(env.get("cuda_available"))
            + " cuda_count="
            + str(env.get("cuda_count")),
            file=sys.stderr,
        )
    except Exception:
        pass

    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                print(f"STEMWERK_DIAG cuda_device_{i}={torch.cuda.get_device_name(i)}", file=sys.stderr)
    except Exception:
        pass

    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                try:
                    props = torch.cuda.get_device_properties(i)
                    info = {
                        "name": props.name,
                        "total_memory": getattr(props, "total_memory", None),
                        "multi_processor_count": getattr(props, "multi_processor_count", None),
                        "major": getattr(props, "major", None),
                        "minor": getattr(props, "minor", None),
                        "gcn_arch": getattr(props, "gcnArchName", None),
                        "pci_bus_id": getattr(props, "pciBusID", None),
                    }
                    print(f"STEMWERK_DIAG cuda_props_{i}={info}", file=sys.stderr)
                except Exception:
                    pass
    except Exception:
        pass


def list_devices_machine(skip_devices: Optional[Set[str]] = None):
    """Machine-readable dump for REAPER/Lua UIs (no JSON parser needed on Lua side)."""
    _require_core()
    devices = get_available_devices()
    if skip_devices:
        devices = [d for d in devices if d.get("id") not in skip_devices]

    print("STEMWERK_DEVICES_BEGIN")
    print("STEMWERK_ENV_BEGIN")
    _emit_env_diagnostics()
    print("STEMWERK_ENV_END")
    print("STEMWERK_HOST_VISIBLE_BEGIN")
    for d in devices:
        print(f"STEMWERK_DEVICE\t{d.get('id','')}\t{d.get('name','')}\t{d.get('type','')}")

    skips = _get_device_skips()
    skip_ids = set()
    for s in skips:
        sid = s.get("id", "")
        sname = s.get("name", "")
        reason = s.get("reason", "")
        reason = str(reason).replace("\t", " ")
        print(f"STEMWERK_DEVICE_SKIPPED\t{sid}\t{sname}\t{reason}")
        if sid:
            skip_ids.add(sid)

    preferred = None
    selected_device = None
    if sys.platform.startswith("linux"):
        preferred = _prefer_linux_amd_device(devices, skip_ids)
    if preferred:
        selected_device = preferred.get("id", "")
        print(f"STEMWERK_SELECTED_DEVICE\t{selected_device}\t{preferred.get('name','')}")
    else:
        try:
            dev_id, dev_name = select_device("auto")
            selected_device = dev_id
            print(f"STEMWERK_SELECTED_DEVICE\t{dev_id}\t{dev_name}")
        except Exception:
            pass

    if devices:
        print("STEMWERK_USABLE_BEGIN")
        for d in devices:
            print(f"STEMWERK_USABLE_GPU\t{d.get('id','')}\t{d.get('name','')}\t{d.get('type','')}")
        print("STEMWERK_USABLE_END")

    host_lines = _get_rocm_host_lines()
    for line in host_lines:
        print(f"STEMWERK_HOST_GPU\t{line}")
    print("STEMWERK_HOST_VISIBLE_END")

    env = _build_env_json()
    env["selected_device"] = selected_device
    print("STEMWERK_TORCH_VISIBLE_BEGIN")
    try:
        print(
            "STEMWERK_TORCH_INFO\tver="
            + str(env.get("torch"))
            + "\thip="
            + str(env.get("torch_hip"))
            + "\tcuda_available="
            + str(env.get("cuda_available"))
            + "\tcuda_count="
            + str(env.get("cuda_count")),
        )
    except Exception:
        pass
    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                print(f"STEMWERK_TORCH_GPU\tcuda:{i}\t{torch.cuda.get_device_name(i)}")
                try:
                    props = torch.cuda.get_device_properties(i)
                    info = {
                        "name": props.name,
                        "total_memory": getattr(props, "total_memory", None),
                        "multi_processor_count": getattr(props, "multi_processor_count", None),
                        "major": getattr(props, "major", None),
                        "minor": getattr(props, "minor", None),
                        "gcn_arch": getattr(props, "gcnArchName", None),
                        "pci_bus_id": getattr(props, "pciBusID", None),
                    }
                    print(f"STEMWERK_TORCH_PROP\tcuda:{i}\t{info}")
                except Exception:
                    pass
    except Exception:
        pass
    print("STEMWERK_TORCH_VISIBLE_END")
    _log_device_diagnostics(devices, env)
    print("STEMWERK_ENV_JSON " + json.dumps(env, ensure_ascii=False))
    print("STEMWERK_DEVICES_END")


def list_devices(skip_devices: Optional[Set[str]] = None):
    """List all available compute devices."""
    _require_core()
    devices = get_available_devices()
    if skip_devices:
        devices = [d for d in devices if d.get("id") not in skip_devices]
    print("Available devices:")
    for dev in devices:
        print(f"  {dev['id']}:  {dev['name']} ({dev['type']})")
    return devices


def check_installation():
    """Check if stemwerk-core and audio-separator are properly installed."""
    try:
        _require_core()
        from audio_separator.separator import Separator  # noqa: F401
        import torch

        print("audio-separator:  OK", file=sys.stderr)
        print(f"PyTorch: {torch.__version__}", file=sys.stderr)
        print(f"CUDA available: {torch.cuda.is_available()}", file=sys.stderr)

        if torch.cuda.is_available():
            for i in range(torch.cuda.device_count()):
                print(f"GPU {i}:  {torch.cuda.get_device_name(i)}", file=sys.stderr)

        try:
            import torch_directml
            print("DirectML:  Available", file=sys.stderr)
        except ImportError:
            print("DirectML: Not installed (pip install torch-directml)", file=sys.stderr)

        return True
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("\nInstall with: pip install stemwerk-core", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description="Audio Separator for STEMwerk")
    parser.add_argument("input", nargs="?", help="Input audio file")
    parser.add_argument("output_dir", nargs="?", help="Output directory for stems")
    parser.add_argument("--model", default="htdemucs",
                        help="Model to use (htdemucs, htdemucs_ft, htdemucs_6s, etc.)")
    parser.add_argument("--device", default="auto",
                        help="Device to use:  auto, cpu, cuda:0, cuda: 1, directml")
    parser.add_argument("--stems", default="",
                        help="Optional comma-separated stems (vocals, drums, bass, other, guitar, piano)")
    parser.add_argument("--env-json", action="store_true",
                        help="Emit STEMWERK_ENV_JSON and device list for Lua")
    parser.add_argument("--skip-devices", default="",
                        help="Comma-separated device ids to skip")
    parser.add_argument("--check", action="store_true",
                        help="Only check installation, don't process")
    parser.add_argument("--list-models", action="store_true",
                        help="List available models")
    parser.add_argument("--list-devices", action="store_true",
                        help="List available compute devices")
    parser.add_argument("--list-devices-machine", action="store_true",
                        help="List available devices in a machine-readable format (for REAPER UIs)")
    parser.add_argument("--workflow-mode", default="",
                        help="Optional workflow mode")
    parser.add_argument("--workflow-source", default="",
                        help="Optional workflow source route (internal)")
    parser.add_argument("--requested-stage2-model", default="",
                        help="Optional stage2 model override for direct DKS")

    args = parser.parse_args()

    if sys.platform == "darwin":
        print(f"STEMWERK_DIAG runtime_executable={sys.executable}", file=sys.stderr)
        print(f"STEMWERK_DIAG runtime_prefix={sys.prefix}", file=sys.stderr)
        print(f"STEMWERK_DIAG runtime_base_prefix={getattr(sys, 'base_prefix', '')}", file=sys.stderr)

    write_done = _setup_reaper_io(args.output_dir if args.output_dir else None)
    emit_phase("python_start")
    ffmpeg_path, ffmpeg_wrapper, ffmpeg_path_prefix = _configure_ffmpeg_runtime()
    model_cache_dir = _configure_model_cache_runtime()
    if ffmpeg_path is not None:
        print(f"STEMWERK_DIAG ffmpeg_path={ffmpeg_path}", file=sys.stderr)
        print(
            f"STEMWERK_DIAG ffmpeg_wrapper={ffmpeg_wrapper if ffmpeg_wrapper is not None else 'none'}",
            file=sys.stderr,
        )
        print(
            f"STEMWERK_DIAG path_prefix={ffmpeg_path_prefix if ffmpeg_path_prefix else 'none'}",
            file=sys.stderr,
        )
    else:
        print("STEMWERK_DIAG ffmpeg_path=NOT_FOUND", file=sys.stderr)
        print("STEMWERK_DIAG ffmpeg_wrapper=none", file=sys.stderr)
        print("STEMWERK_DIAG path_prefix=none", file=sys.stderr)
    print(f"STEMWERK_DIAG model_cache_dir={model_cache_dir}", file=sys.stderr)

    skip_devices = set(_split_list(args.skip_devices))

    if args.env_json or args.list_devices_machine:
        list_devices_machine(skip_devices)
        return 0

    if args.check:
        if check_installation():
            print("\nInstallation OK!")
            list_devices(skip_devices)
            return 0
        return 1

    if args.list_devices:
        list_devices(skip_devices)
        return 0

    if args.list_models:
        print("Popular models:")
        print("  htdemucs - Hybrid Transformer Demucs (default, fast)")
        print("  htdemucs_ft - Fine-tuned Demucs (better quality)")
        print("  htdemucs_6s - 6-stem model (guitar, piano)")
        print("  UVR-MDX-NET-Voc_FT - Best vocal isolation")
        print("  Kim_Vocal_2 - Alternative vocal model")
        return 0

    if not args.input or not args.output_dir:
        parser.print_help()
        return 1

    _require_core()
    if stemwerk_core_file:
        print(f"STEMWERK_DIAG stemwerk_core_file={stemwerk_core_file}", file=sys.stderr)

    if not os.path.exists(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        return 1

    device_preference = args.device
    if device_preference in skip_devices:
        print(f"WARNING: Device '{device_preference}' skipped; using auto", file=sys.stderr)
        device_preference = "auto"

    stems = _split_list(args.stems)
    run_model = _resolve_run_model(args)
    requested_stage2_model = run_model
    if _is_direct_dks_source(args.workflow_mode, args.workflow_source):
        emit_phase("stage2_preflight")
        print(
            f"Direct Drum Kit Split route detected: workflow_mode={args.workflow_mode} workflow_source={args.workflow_source}",
            file=sys.stderr,
        )
        drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime()
        if drumsep_python is None:
            reason = "drumsep_runtime_missing" if runtime_kind == "missing" else "drumsep_runtime_broken"
            runtime_path = _drumsep_rocm_runtime_python_path()
            _emit_direct_dks_stage2_runtime_markers(reason, runtime_path, json.dumps(runtime_info, sort_keys=True))
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return 1
        versions = runtime_info.get("versions") if isinstance(runtime_info.get("versions"), dict) else {}
        device_names = runtime_info.get("device_names") if isinstance(runtime_info.get("device_names"), list) else []
        fallback_reason = str(runtime_info.get("fallback_reason") or "")
        print(f"drumsep_runtime_selected={runtime_kind}", file=sys.stderr)
        print(f"drumsep_python={drumsep_python}", file=sys.stderr)
        print(f"drumsep_gpu_capable={'yes' if runtime_kind == 'rocm' else 'no'}", file=sys.stderr)
        print(f"drumsep_torch_version={versions.get('torch', '')}", file=sys.stderr)
        print(f"drumsep_torch_hip={runtime_info.get('torch_hip', '')}", file=sys.stderr)
        print(f"drumsep_device_names={'|'.join(str(x) for x in device_names if str(x).strip())}", file=sys.stderr)
        if fallback_reason:
            print(f"drumsep_runtime_fallback_reason={fallback_reason}", file=sys.stderr)
        try:
            ok, requested_model, resolved_model, known_err = _direct_dks_preflight_check(run_model, model_cache_dir)
            if not ok:
                known_err_text = str(known_err or "").lower()
                reason = (
                    "drumsep_model_missing"
                    if "not found in supported model files" in known_err_text
                    or known_err_text.startswith("catalog_")
                    else "drumsep_model_download_failed"
                )
                _emit_direct_dks_preflight_markers(reason, requested_model or run_model, resolved_model or "", str(known_err or ""))
                emit_phase("python_error")
                if write_done:
                    write_done("ERROR")
                return 1
            requested_stage2_model = requested_model or requested_stage2_model
            run_model = resolved_model or run_model
        except Exception as exc:
            _emit_direct_dks_preflight_markers("drumsep_model_download_failed", run_model, "", str(exc))
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return 1
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)
        emit_phase("separate_start")
        helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(
            Path(args.input).resolve(),
            output_root,
            model_cache_dir,
            drumsep_python,
            requested_stage2_model,
            run_model,
        )
        if not helper_ok:
            stage = "stage2_separate"
            if helper_reason == "drumsep_model_load_failed":
                stage = "stage2_model_load"
            elif helper_reason == "drumsep_output_count_mismatch":
                stage = "stage2_output_validation"
            _emit_direct_dks_helper_failure_markers(
                helper_reason or "drumsep_helper_failed",
                stage,
                requested_stage2_model,
                run_model,
                helper_detail,
            )
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return 1
        emit_phase("separate_end")
        emit_phase("stem_write_start")
        print(json.dumps(helper_stems))
        emit_phase("stem_write_end")
        emit_phase("python_done")
        if write_done:
            write_done("DONE")
        return 0

    resolved_device = device_preference
    if device_preference == "auto":
        preferred = None
        if sys.platform.startswith("linux"):
            preferred = _prefer_linux_amd_device(get_available_devices(), _get_skip_ids())
        if preferred:
            resolved_device = preferred.get("id") or "auto"
            print(
                f"STEMWERK_DIAG auto_selected_preferred={resolved_device} ({preferred.get('name','')})",
                file=sys.stderr,
            )
        else:
            try:
                dev_id, dev_name = select_device("auto")
                print(f"STEMWERK_DIAG auto_selected={dev_id} ({dev_name})", file=sys.stderr)
                resolved_device = dev_id
            except Exception:
                resolved_device = "auto"
    else:
        print(f"STEMWERK_DIAG requested_device={device_preference}", file=sys.stderr)

    runtime_env: Dict[str, object] = {}
    try:
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)
        _enable_mps_runtime_fallback(device_preference, resolved_device)
        resolved_device = _enforce_mps_demucs_cpu_policy(device_preference, resolved_device, run_model)
        runtime_env = _emit_runtime_diagnostics(resolved_device)
        _enable_torch_weights_only_compat(run_model, resolved_device)

        emit_phase("model_setup_start")
        sep = StemSeparator(model=run_model, device=resolved_device)
        emit_phase("model_setup_end")

        def reaper_progress(pct: float, msg: str):
            emit_progress(pct, msg)

        sep.on_progress = reaper_progress

        with _working_directory(output_root):
            emit_phase("separate_start")
            result = sep.separate(args.input, str(output_root), stems=stems or None)
            emit_phase("separate_end")

        # audio-separator writes model outputs inside sep.separate(); this phase
        # brackets the REAPER-facing output mapping and final stem renames.
        emit_phase("stem_write_start")
        # Mapping logica voor REAPER compatibiliteit
        stem_mapping = {
            'vocals': ['vocals', 'vocal', 'Vocals'],
            'drums':  ['drums', 'drum', 'Drums'],
            'bass': ['bass', 'Bass'],
            'other': ['other', 'Other', 'no_vocals', 'instrumental', 'Instrumental'],
            'guitar': ['guitar', 'Guitar'],
            'piano': ['piano', 'Piano', 'keys', 'Keys']
        }

        reaper_stems = {}
        for stem_name, stem_path in result.stems.items():
            abs_path = _resolve_stem_path(output_root, stem_path)
            if not abs_path.exists():
                raise FileNotFoundError(f"Expected separated stem not found: {abs_path}")
            
            # Zoek naar de juiste REAPER naam
            filename = abs_path.stem.lower()
            target_name = stem_name  # fallback
            
            for map_name, patterns in stem_mapping.items():
                if any(p.lower() in filename for p in patterns):
                    target_name = map_name
                    break
            
            # Hernoem bestand naar simpele naam (bijv. vocals.wav)
            new_path = abs_path.parent / f"{target_name}.wav"
            if abs_path != new_path:
                if new_path.exists():
                    os.remove(new_path)
                shutil.move(str(abs_path), str(new_path))
            
            reaper_stems[target_name] = str(new_path)
            print(f"  {target_name}:  {new_path}", file=sys.stderr)

        emit_phase("stem_write_end")

        # Print de JSON die Lua verwacht
        print(json.dumps(reaper_stems))

        emit_phase("python_done")
        if write_done:
            write_done("DONE")

        return 0
    except Exception as exc:
        import traceback

        traceback_text = traceback.format_exc()
        if _is_direct_dks_source(args.workflow_mode, args.workflow_source) and _is_known_drumsep_runtime_unsupported_error(exc, traceback_text, run_model):
            _emit_direct_dks_runtime_unsupported_markers(
                requested_stage2_model or run_model,
                run_model,
                "audio_separator mdxc loader missing expected config field 'model'",
            )
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return 1
        model_failure = _classify_model_failure_text(f"{exc}\n{traceback_text}")
        if model_failure:
            print(f"STEMWERK_ERROR_CLASS={model_failure['error_class']}", file=sys.stderr)
            print(f"STEMWERK_ERROR_HINT={model_failure['error_hint']}", file=sys.stderr)
            print(f"STEMWERK_MODEL_CACHE_HINT={model_failure['model_cache_hint']}", file=sys.stderr)
            if model_failure.get("model_url"):
                print(f"STEMWERK_MODEL_URL={model_failure['model_url']}", file=sys.stderr)
            if model_failure.get("model_path"):
                print(f"STEMWERK_MODEL_PATH={model_failure['model_path']}", file=sys.stderr)
        failure = _classify_runtime_failure(
            exc,
            traceback_text,
            device_preference,
            resolved_device,
            run_model,
            runtime_env,
        )
        if failure:
            print(failure["marker"], file=sys.stderr)
            for key, value in failure.get("details", {}).items():
                print(f"STEMWERK_MPS_CONTEXT {key}={value}", file=sys.stderr)
        print(f"ERROR: {exc}", file=sys.stderr)
        print(traceback_text, file=sys.stderr, end="" if traceback_text.endswith("\n") else "\n")
        emit_phase("python_error")
        if write_done:
            write_done("ERROR")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
