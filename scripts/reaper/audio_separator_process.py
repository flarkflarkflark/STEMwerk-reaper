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
import threading
import sys
import time
import urllib.request
import yaml
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
MPS_DEMUCS_SEGMENT_SIZE = 2
MPS_SEGMENT_POLICY = "universal_safe_segment_2"
DRUMSEP_RUNTIME_LIMIT_REASON = "audio_separator_mdxc_runtime_primary_secondary_only"
DIRECT_DKS_MODEL_ALIAS = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
DIRECT_DKS_MODEL_FILENAME = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
DIRECT_DKS_MODEL_ENTRY_NAME = "MDX23C Model: DrumSep 6stem | (by aufr33 & jarredou)"
DIRECT_DKS_MODEL_DEAD_CKPT_URL = (
    "https://github.com/jarredou/models/releases/download/"
    "aufr33-jarredou_MDX23C_DrumSep_model_v0.1/"
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
)
DIRECT_DKS_MODEL_MIRROR_CKPT_URL = (
    "https://huggingface.co/Sucial/MSST-WebUI/resolve/main/"
    "All_Models/multi_stem_models/"
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
)
DRUMSEP_RUNTIME_DIRNAME = ".venv-drumsep"
DRUMSEP_RUNTIME_ROCM_DIRNAME = ".venv-drumsep-rocm"
DRUMSEP_RUNTIME_GUIDANCE = "Run Setup/Repair Drum Kit Split runtime."
DRUMSEP_HELPER_RELATIVE = Path("_internal") / "stemwerk_drumsep_process.py"
DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 4
DKS_EXTRACT_STAGE2_BENCHMARK_CAPS = {1, 2, 4}
BENCHMARK_CPU_CAPS = {1, 2, 4}
BENCHMARK_MPS_CAP_MIN = 1
BENCHMARK_MPS_CAP_MAX = 8
BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV = "STEMWERK_BENCH_DRUMSEP_HELPER_DEVICE"
BENCHMARK_DRUMSEP_HELPER_DEVICES = {"cpu", "cuda", "rocm"}
DIRECT_DKS_EXPECTED_STEMS = ("kick", "snare", "toms", "hihat", "ride", "crash")

def _ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())


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


def _is_extract_dks_source(workflow_mode: Optional[str], workflow_source: Optional[str]) -> bool:
    mode = str(workflow_mode or "").strip().lower()
    source = str(workflow_source or "").strip().lower()
    return mode == "drumkit" and source == "dks_extract"


def _should_use_drumsep_mps_direct_demix(
    workflow_mode: Optional[str],
    workflow_source: Optional[str],
    requested_device: str,
    runtime_info: Optional[Dict[str, Any]],
    resolved_model: str,
) -> tuple[bool, str]:
    if not (
        _is_direct_dks_source(workflow_mode, workflow_source)
        or _is_extract_dks_source(workflow_mode, workflow_source)
    ):
        return False, "not_direct_kit_stage2"
    if sys.platform != "darwin":
        return False, "platform_not_darwin"
    machine = platform.machine().lower()
    if machine not in {"arm64", "aarch64"}:
        return False, "machine_not_apple_silicon"
    if str(requested_device or "").strip().lower() != "mps":
        return False, "requested_device_not_explicit_mps"

    info = runtime_info if isinstance(runtime_info, dict) else {}
    if str(info.get("kind") or "").strip().lower() != "mps":
        return False, "effective_runtime_not_mps"
    if not bool(info.get("mps_built")):
        return False, "mps_not_built"
    if not bool(info.get("mps_available")):
        return False, "mps_not_available"
    versions = info.get("versions") if isinstance(info.get("versions"), dict) else {}
    if str(versions.get("audio-separator") or "").strip() != "0.23.0":
        return False, "audio_separator_version_not_0_23_0"
    if str(resolved_model or "").strip() != DIRECT_DKS_MODEL_ALIAS:
        return False, "unsupported_drumsep_model"
    if os.environ.get(MPS_FALLBACK_ENV):
        return False, "pytorch_mps_fallback_env_set"
    if not bool(info.get("mps_experimental")):
        return False, "mps_experimental_policy_inactive"
    return True, "ok"


def _resolve_normal_workflow_backend(selected_device: Optional[str]) -> str:
    device = str(selected_device or "").strip().lower()
    if device.startswith("cuda:") or device == "cuda":
        return "gpu"
    if device.startswith("directml:") or device == "directml":
        return "gpu"
    if device == "mps":
        return "gpu"
    if device == "rocm":
        return "gpu"
    if device == "cpu":
        return "cpu"
    if device == "auto":
        return "unknown"
    return "unknown"


def _read_benchmark_dks_stage2_cap_request() -> tuple[Optional[int], str]:
    raw = str(os.environ.get("STEMWERK_BENCH_DKS_STAGE2_CAP") or "").strip()
    if raw == "":
        return None, "unset"
    try:
        requested = int(raw)
    except ValueError:
        return None, raw
    if requested in DKS_EXTRACT_STAGE2_BENCHMARK_CAPS:
        return requested, raw
    return None, raw


def _read_benchmark_mps_cap_request(env_name: str) -> tuple[Optional[int], str]:
    raw = str(os.environ.get(env_name) or "").strip()
    if raw == "":
        return None, "unset"
    try:
        requested = int(raw)
    except ValueError:
        return None, raw
    if BENCHMARK_MPS_CAP_MIN <= requested <= BENCHMARK_MPS_CAP_MAX:
        return requested, raw
    return None, raw


def _read_benchmark_dks_stage2_mps_cap_request() -> tuple[Optional[int], str, str]:
    requested, raw = _read_benchmark_mps_cap_request("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")
    if raw != "unset":
        return requested, raw, "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP"
    requested_cap, raw_cap = _read_benchmark_dks_stage2_cap_request()
    return requested_cap, raw_cap, "STEMWERK_BENCH_DKS_STAGE2_CAP"


def _read_benchmark_cpu_cap_request(env_name: str) -> tuple[Optional[int], str]:
    raw = str(os.environ.get(env_name) or "").strip()
    if raw == "":
        return None, "unset"
    try:
        requested = int(raw)
    except ValueError:
        return None, raw
    if requested in BENCHMARK_CPU_CAPS:
        return requested, raw
    return None, raw


def _read_benchmark_dks_stage2_cpu_cap_request() -> tuple[Optional[int], str, str]:
    requested, raw = _read_benchmark_cpu_cap_request("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")
    if raw != "unset":
        return requested, raw, "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP"
    requested, raw = _read_benchmark_cpu_cap_request("STEMWERK_BENCH_CPU_CAP")
    return requested, raw, "STEMWERK_BENCH_CPU_CAP"


def _detect_dks_extract_stage2_backend(
    selected_backend: str = "",
    runtime_info: Optional[Dict[str, Any]] = None,
    python_path: Optional[Path] = None,
) -> str:
    backend = str(selected_backend or "").strip().lower()
    if backend in {"rocm", "cuda", "directml", "mps", "cpu"}:
        return backend

    info = runtime_info if isinstance(runtime_info, dict) else {}
    info_kind = str(info.get("kind") or "").strip().lower()
    if info_kind in {"rocm", "cuda", "directml", "mps", "cpu"}:
        return info_kind

    versions = info.get("versions") if isinstance(info.get("versions"), dict) else {}
    torch_version = str(versions.get("torch") or "").strip().lower()
    torch_hip = str(info.get("torch_hip") or "").strip()
    torch_cuda_available = bool(info.get("torch_cuda_available"))

    if torch_hip or "+rocm" in torch_version or "rocm" in torch_version:
        return "rocm"
    if torch_cuda_available and ("+cu" in torch_version or "cuda" in torch_version):
        return "cuda"

    executable = str((python_path or sys.executable) or "").lower()
    if "rocm" in executable:
        return "rocm"
    if "cuda" in executable:
        return "cuda"
    if "directml" in executable:
        return "directml"
    if "mps" in executable:
        return "mps"
    return "cpu"


def _resolve_dks_extract_stage2_benchmark_cap(stage2_backend: str) -> tuple[Optional[int], str, int, str]:
    requested_cap, raw_cap = _read_benchmark_dks_stage2_cap_request()
    applied_cap = (
        DKS_EXTRACT_STAGE2_CONCURRENCY_CAP
        if stage2_backend in {"rocm", "cuda"}
        else 1
    )
    ignored_reason = ""

    if requested_cap is None:
        if raw_cap == "unset":
            ignored_reason = "not_requested"
        else:
            ignored_reason = "invalid_request"
        return requested_cap, raw_cap, applied_cap, ignored_reason

    if requested_cap == 1:
        return requested_cap, raw_cap, 1, ""

    if stage2_backend not in {"rocm", "cuda"}:
        return requested_cap, raw_cap, 1, "backend_not_rocm_cuda"

    if os.name != "posix":
        return requested_cap, raw_cap, 1, "fcntl_unavailable"

    return requested_cap, raw_cap, requested_cap, ""


def _resolve_dks_extract_stage2_mps_benchmark_cap(stage2_backend: str) -> tuple[Optional[int], str, int, str, str]:
    requested_cap, raw_cap, env_name = _read_benchmark_dks_stage2_mps_cap_request()
    applied_cap = 1
    ignored_reason = ""

    if requested_cap is None:
        if raw_cap == "unset":
            ignored_reason = "not_requested"
        else:
            ignored_reason = "invalid_request"
        return requested_cap, raw_cap, applied_cap, ignored_reason, env_name

    if stage2_backend != "mps":
        return requested_cap, raw_cap, applied_cap, "backend_not_mps", env_name

    return requested_cap, raw_cap, max(1, requested_cap), "", env_name


def _benchmark_cpu_count() -> Optional[int]:
    try:
        cpu_count = os.cpu_count()
    except Exception:
        cpu_count = None
    if cpu_count is None:
        return None
    try:
        cpu_count = int(cpu_count)
    except Exception:
        return None
    return cpu_count if cpu_count > 0 else None


def _benchmark_ram_gib() -> Optional[float]:
    system = platform.system()
    if system == "Linux":
        meminfo = _read_linux_meminfo()
        if meminfo is not None:
            _, total_mb = meminfo
            if total_mb and total_mb > 0:
                return float(total_mb) / 1024.0
    if system == "Darwin":
        try:
            result = subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True,
                text=True,
                check=False,
            )
            raw = str(result.stdout or "").strip()
            bytes_total = int(raw) if raw else 0
            if bytes_total > 0:
                return float(bytes_total) / (1024.0 ** 3)
        except Exception:
            return None
    return None


def _resolve_dks_extract_stage2_cpu_benchmark_cap(stage2_backend: str) -> tuple[Optional[int], str, int, str, str]:
    requested_cap, raw_cap, env_name = _read_benchmark_dks_stage2_cpu_cap_request()
    applied_cap = 1
    ignored_reason = ""

    if requested_cap is None:
        if raw_cap == "unset":
            ignored_reason = "not_requested"
        else:
            ignored_reason = "invalid_request"
        return requested_cap, raw_cap, applied_cap, ignored_reason, env_name

    if stage2_backend == "directml":
        return requested_cap, raw_cap, applied_cap, "directml_fixed_cap1", env_name
    if stage2_backend == "mps":
        return requested_cap, raw_cap, applied_cap, "mps_fixed_cap1", env_name
    if stage2_backend != "cpu":
        return requested_cap, raw_cap, applied_cap, "backend_not_cpu", env_name
    if requested_cap == 1:
        return requested_cap, raw_cap, 1, "", env_name
    if os.name != "posix":
        return requested_cap, raw_cap, 1, "fcntl_unavailable", env_name

    if requested_cap == 4:
        cpu_count = _benchmark_cpu_count()
        ram_gib = _benchmark_ram_gib()
        if cpu_count is None:
            return requested_cap, raw_cap, applied_cap, "cpu_threads_unknown_for_cap4", env_name
        if cpu_count < 8:
            return requested_cap, raw_cap, applied_cap, "cpu_threads_low_for_cap4", env_name
        if ram_gib is None:
            return requested_cap, raw_cap, applied_cap, "cpu_ram_unknown_for_cap4", env_name
        if ram_gib < 8:
            return requested_cap, raw_cap, applied_cap, "cpu_ram_low_for_cap4", env_name

    return requested_cap, raw_cap, requested_cap, "", env_name


def _benchmark_resource_sampling_requested() -> bool:
    gpu_cap = str(os.environ.get("STEMWERK_BENCH_GPU_CAP") or "").strip()
    mps_cap = str(os.environ.get("STEMWERK_BENCH_MPS_CAP") or "").strip()
    stage1_mps_cap = str(os.environ.get("STEMWERK_BENCH_DKS_STAGE1_MPS_CAP") or "").strip()
    stage2_mps_cap = str(os.environ.get("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP") or "").strip()
    sampling = str(os.environ.get("STEMWERK_BENCH_RESOURCE_SAMPLING") or "").strip().lower()
    return (
        gpu_cap != ""
        or mps_cap != ""
        or stage1_mps_cap != ""
        or stage2_mps_cap != ""
        or sampling in {"1", "true", "yes", "on"}
    )


def _read_linux_cpu_times() -> Optional[tuple[int, int]]:
    try:
        with open("/proc/stat", "r", encoding="utf-8", errors="ignore") as fh:
            first_line = fh.readline().strip()
    except Exception:
        return None
    parts = first_line.split()
    if not parts or parts[0] != "cpu" or len(parts) < 5:
        return None
    values: list[int] = []
    for raw in parts[1:]:
        try:
            values.append(int(raw))
        except Exception:
            values.append(0)
    total = sum(values)
    idle = values[3] if len(values) > 3 else 0
    idle += values[4] if len(values) > 4 else 0
    return total, idle


def _read_linux_meminfo() -> Optional[tuple[float, float]]:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
    except Exception:
        return None
    total_kb = None
    available_kb = None
    for line in text.splitlines():
        if line.startswith("MemTotal:"):
            try:
                total_kb = float(re.findall(r"\d+", line)[0])
            except Exception:
                pass
        elif line.startswith("MemAvailable:"):
            try:
                available_kb = float(re.findall(r"\d+", line)[0])
            except Exception:
                pass
        if total_kb is not None and available_kb is not None:
            break
    if not total_kb or available_kb is None:
        return None
    used_mb = max(0.0, (total_kb - available_kb) / 1024.0)
    total_mb = total_kb / 1024.0
    return used_mb, total_mb


def _read_process_rss_mb() -> Optional[float]:
    page_size = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096
    candidates = ["/proc/self/statm", "/proc/self/status"]
    for path in candidates:
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except Exception:
            continue
        if path.endswith("statm"):
            parts = text.split()
            if len(parts) >= 2:
                try:
                    rss_pages = float(parts[1])
                    return rss_pages * float(page_size) / (1024.0 * 1024.0)
                except Exception:
                    pass
        else:
            match = re.search(r"VmRSS:\s*(\d+)\s*kB", text)
            if match:
                return float(match.group(1)) / 1024.0
    return None


def _bytes_to_mb(value: float) -> float:
    return float(value) / (1024.0 * 1024.0)


def _value_to_mb(raw_value: float, unit: str, line: str) -> float:
    unit_l = unit.lower()
    if unit_l in {"b", "byte", "bytes"}:
        return _bytes_to_mb(raw_value)
    if unit_l in {"kb", "kib"}:
        return raw_value / 1024.0
    if unit_l in {"mb", "mib"}:
        return raw_value
    if unit_l in {"gb", "gib"}:
        return raw_value * 1024.0
    if unit_l in {"tb", "tib"}:
        return raw_value * 1024.0 * 1024.0
    lowered = line.lower()
    if "memory" in lowered or "vram" in lowered or "ram" in lowered:
        if "(b)" in lowered or " bytes" in lowered or "byte" in lowered:
            return _bytes_to_mb(raw_value)
    return raw_value


def _first_number(text: str, pattern: str) -> Optional[float]:
    match = re.search(pattern, text, re.IGNORECASE)
    if not match:
        return None
    try:
        return float(match.group(1))
    except Exception:
        return None


def _extract_metric_from_line(line: str, key_patterns: tuple[str, ...]) -> Optional[float]:
    lowered = line.lower()
    if not any(pattern in lowered for pattern in key_patterns):
        return None
    match = re.search(r"(-?\d+(?:\.\d+)?)\s*(tb|tib|gb|gib|mb|mib|kb|kib|b|c|w|%)?", line, re.IGNORECASE)
    if not match:
        return None
    raw_value = float(match.group(1))
    unit = match.group(2) or ""
    return _value_to_mb(raw_value, unit, line) if unit.lower() not in {"c", "w", "%"} else raw_value


def _run_command_capture_text(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=_clean_env(),
            **_windows_no_window_kwargs(),
        )
        text = "\n".join(part for part in (completed.stdout or "", completed.stderr or "") if part)
        return completed.returncode, text.strip()
    except Exception as exc:
        return 1, f"{type(exc).__name__}: {exc}"


def _parse_rocm_smi_gpu_line(line: str) -> tuple[Optional[int], str]:
    match = re.match(r"^\s*GPU\[(\d+)\]\s*:\s*(.+?)\s*$", line)
    if not match:
        return None, ""
    return int(match.group(1)), match.group(2).strip()


def _parse_rocm_smi_product_names(text: str) -> Dict[int, str]:
    product_names: Dict[int, str] = {}
    for line in text.splitlines():
        gpu_index, payload = _parse_rocm_smi_gpu_line(line)
        if gpu_index is None:
            continue
        if "card series" not in payload.lower():
            continue
        parts = payload.rsplit(":", 1)
        if len(parts) != 2:
            continue
        gpu_name = parts[1].strip()
        if gpu_name:
            product_names[gpu_index] = gpu_name
    return product_names


def _parse_rocm_smi_metrics_text(text: str, product_text: str = "") -> Dict[str, Optional[float] | str]:
    per_gpu: Dict[int, Dict[str, Optional[float] | str]] = {}
    product_names = _parse_rocm_smi_product_names(product_text)

    def _gpu_metrics(index: int) -> Dict[str, Optional[float] | str]:
        metrics = per_gpu.setdefault(
            index,
            {
                "gpu_util_percent": None,
                "gpu_vram_used_mb": None,
                "gpu_vram_total_mb": None,
                "gpu_vram_percent": None,
                "gpu_temp_c": None,
                "gpu_power_w": None,
                "gpu_name": product_names.get(index, ""),
            },
        )
        if not metrics.get("gpu_name") and index in product_names:
            metrics["gpu_name"] = product_names[index]
        return metrics

    for line in text.splitlines():
        gpu_index, payload = _parse_rocm_smi_gpu_line(line)
        if gpu_index is None:
            continue
        metrics = _gpu_metrics(gpu_index)
        lowered = payload.lower()
        value_text = payload.rsplit(":", 1)[-1].strip()

        if "gpu use (%)" in lowered or "gpu utilization" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                metrics["gpu_util_percent"] = value
        elif "vram total used memory" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                metrics["gpu_vram_used_mb"] = value / (1024.0 * 1024.0)
        elif "vram total memory" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                metrics["gpu_vram_total_mb"] = value / (1024.0 * 1024.0)
        elif "gpu memory allocated (vram%)" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                metrics["gpu_vram_percent"] = value
        elif "temperature" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                current = metrics.get("gpu_temp_c")
                metrics["gpu_temp_c"] = value if current is None else max(float(current), value)
        elif "power" in lowered:
            value = _first_number(value_text, r"(-?\d+(?:\.\d+)?)")
            if value is not None:
                metrics["gpu_power_w"] = value

    for metrics in per_gpu.values():
        if metrics.get("gpu_vram_used_mb") is None and metrics.get("gpu_vram_total_mb") is not None and metrics.get("gpu_vram_percent") is not None:
            metrics["gpu_vram_used_mb"] = float(metrics["gpu_vram_total_mb"]) * float(metrics["gpu_vram_percent"]) / 100.0

    if not per_gpu:
        return {
            "gpu_util_percent": None,
            "gpu_vram_used_mb": None,
            "gpu_vram_total_mb": None,
            "gpu_temp_c": None,
            "gpu_power_w": None,
            "gpu_name": "",
        }

    def _select_gpu_key(item: tuple[int, Dict[str, Optional[float] | str]]) -> tuple[float, float, float, float]:
        _, metrics = item
        total = float(metrics.get("gpu_vram_total_mb") or 0.0)
        used = float(metrics.get("gpu_vram_used_mb") or 0.0)
        util = float(metrics.get("gpu_util_percent") or 0.0)
        power = float(metrics.get("gpu_power_w") or 0.0)
        return total, used, util, power

    _, selected = max(per_gpu.items(), key=_select_gpu_key)
    return {
        "gpu_util_percent": selected.get("gpu_util_percent"),
        "gpu_vram_used_mb": selected.get("gpu_vram_used_mb"),
        "gpu_vram_total_mb": selected.get("gpu_vram_total_mb"),
        "gpu_temp_c": selected.get("gpu_temp_c"),
        "gpu_power_w": selected.get("gpu_power_w"),
        "gpu_name": str(selected.get("gpu_name") or ""),
    }


def _collect_rocm_smi_metrics() -> tuple[Dict[str, Any], bool, str, str]:
    if not shutil.which("rocm-smi"):
        return {}, False, "rocm-smi_missing", "rocm-smi not found"

    rc, text = _run_command_capture_text(
        ["rocm-smi", "--showuse", "--showmemuse", "--showmeminfo", "vram", "--showtemp", "--showpower"],
        timeout=12,
    )
    if rc != 0 or not text:
        return {}, False, "rocm-smi_failed", text[:500] or f"rocm-smi exit {rc}"

    _, product_text = _run_command_capture_text(["rocm-smi", "--showproductname"], timeout=8)
    metrics = _parse_rocm_smi_metrics_text(text, product_text)

    if metrics.get("gpu_vram_used_mb") is None and metrics.get("gpu_vram_total_mb") is None and metrics.get("gpu_util_percent") is None:
        return metrics, False, "rocm-smi_parse_failed", text[:500] or "no parseable metrics"
    return metrics, True, "", text[:500]


def _collect_nvidia_smi_metrics() -> tuple[Dict[str, Any], bool, str, str]:
    if not shutil.which("nvidia-smi"):
        return {}, False, "nvidia-smi_missing", "nvidia-smi not found"
    rc, text = _run_command_capture_text(
        [
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw",
            "--format=csv,noheader,nounits",
        ],
        timeout=8,
    )
    if rc != 0 or not text:
        return {}, False, "nvidia-smi_failed", text[:500] or f"nvidia-smi exit {rc}"
    first_row = text.splitlines()[0] if text.splitlines() else ""
    parts = [p.strip() for p in first_row.split(",")]
    if len(parts) < 5:
        return {}, False, "nvidia-smi_parse_failed", first_row[:500]
    metrics: Dict[str, Optional[float]] = {
        "gpu_util_percent": None,
        "gpu_vram_used_mb": None,
        "gpu_vram_total_mb": None,
        "gpu_temp_c": None,
        "gpu_power_w": None,
    }
    try:
        metrics["gpu_util_percent"] = float(parts[0])
    except Exception:
        pass
    try:
        metrics["gpu_vram_used_mb"] = float(parts[1])
    except Exception:
        pass
    try:
        metrics["gpu_vram_total_mb"] = float(parts[2])
    except Exception:
        pass
    try:
        metrics["gpu_temp_c"] = float(parts[3])
    except Exception:
        pass
    try:
        metrics["gpu_power_w"] = float(parts[4])
    except Exception:
        pass
    return metrics, True, "", first_row[:500]


class BenchmarkResourceSampler:
    def __init__(self, output_dir: Path):
        self.output_dir = output_dir
        self.samples_path = output_dir / "benchmark_resource_samples.jsonl"
        self.summary_json_path = output_dir / "benchmark_resource_summary.json"
        self.summary_txt_path = output_dir / "benchmark_resource_summary.txt"
        self.interval_seconds = 1.0
        self.stop_event = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.sample_index = 0
        self.started_at = time.time()
        self.ended_at = None
        self.resource_sampling_available = False
        self.resource_sampling_reason = "unknown"
        self.gpu_backend = "unknown"
        self._jsonl_fh = None
        self._cpu_last: Optional[tuple[int, int]] = None
        self._cpu_util_sum = 0.0
        self._cpu_util_count = 0
        self._gpu_util_sum = 0.0
        self._gpu_util_count = 0
        self._gpu_util_peak = None
        self._vram_peak = None
        self._vram_total = None
        self._system_ram_peak = None
        self._gpu_temp_peak = None
        self._gpu_power_peak = None
        self._process_rss_peak = None
        self._gpu_name = ""

    def start(self) -> None:
        try:
            self.output_dir.mkdir(parents=True, exist_ok=True)
            self._jsonl_fh = self.samples_path.open("w", encoding="utf-8", buffering=1)
            self.gpu_backend = self._detect_backend()
            if sys.platform.startswith("linux"):
                if self.gpu_backend == "rocm-smi":
                    self.resource_sampling_reason = "benchmark_active"
                elif self.gpu_backend == "nvidia-smi":
                    self.resource_sampling_reason = "benchmark_active_nvidia"
                else:
                    self.resource_sampling_reason = "rocm-smi_missing"
            elif self.gpu_backend == "nvidia-smi":
                self.resource_sampling_reason = "benchmark_active_nvidia"
            else:
                self.resource_sampling_reason = f"{self.gpu_backend}_unsupported"
            first_sample = self._collect_sample()
            self._update_summary(first_sample)
            self._write_sample(first_sample)
            self.sample_index += 1
            self.thread = threading.Thread(target=self._run, name="stemwerk-resource-sampler", daemon=True)
            self.thread.start()
        except Exception as exc:
            self.resource_sampling_available = False
            self.resource_sampling_reason = f"sampler_start_failed:{type(exc).__name__}"
            self._close_files()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=10)
        self.ended_at = time.time()
        self._write_summary_files()
        self._close_files()

    def _close_files(self) -> None:
        if self._jsonl_fh is not None:
            try:
                self._jsonl_fh.close()
            except Exception:
                pass
            self._jsonl_fh = None

    def _detect_backend(self) -> str:
        if sys.platform.startswith("linux"):
            if shutil.which("rocm-smi"):
                return "rocm-smi"
            if shutil.which("nvidia-smi"):
                return "nvidia-smi"
            return "linux-unknown"
        if sys.platform == "darwin":
            if shutil.which("nvidia-smi"):
                return "nvidia-smi"
            return "macos-unknown"
        if os.name == "nt":
            if shutil.which("nvidia-smi"):
                return "nvidia-smi"
            return "windows-unknown"
        return "unknown"

    def _collect_sample(self) -> Dict[str, Any]:
        sample: Dict[str, Any] = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
            "sample_index": self.sample_index,
            "gpu_backend": self.gpu_backend,
            "resource_sampling_available": "no" if not self.resource_sampling_available else "yes",
            "resource_sampling_reason": self.resource_sampling_reason,
            "gpu_util_percent": None,
            "gpu_vram_used_mb": None,
            "gpu_vram_total_mb": None,
            "gpu_temp_c": None,
            "gpu_power_w": None,
            "gpu_name": "",
            "cpu_util_percent": None,
            "system_ram_used_mb": None,
            "system_ram_total_mb": None,
            "process_rss_mb": _read_process_rss_mb(),
        }
        if sys.platform.startswith("linux"):
            meminfo = _read_linux_meminfo()
            if meminfo is not None:
                sample["system_ram_used_mb"], sample["system_ram_total_mb"] = meminfo
            cpu_times = _read_linux_cpu_times()
            if cpu_times is not None and self._cpu_last is not None:
                total_now, idle_now = cpu_times
                total_prev, idle_prev = self._cpu_last
                delta_total = total_now - total_prev
                delta_idle = idle_now - idle_prev
                if delta_total > 0:
                    sample["cpu_util_percent"] = max(0.0, min(100.0, 100.0 * (1.0 - (float(delta_idle) / float(delta_total)))))
            self._cpu_last = cpu_times

            gpu_metrics = {}
            gpu_available = False
            gpu_reason = ""
            if self.gpu_backend == "rocm-smi":
                gpu_metrics, gpu_available, gpu_reason, _ = _collect_rocm_smi_metrics()
            elif self.gpu_backend == "nvidia-smi":
                gpu_metrics, gpu_available, gpu_reason, _ = _collect_nvidia_smi_metrics()
            if gpu_metrics:
                sample.update(gpu_metrics)
            if gpu_available:
                self.resource_sampling_available = True
                self.resource_sampling_reason = ""
            elif not self.resource_sampling_available and gpu_reason:
                self.resource_sampling_reason = gpu_reason
        else:
            if sys.platform.startswith("linux") and self.gpu_backend == "linux-unknown":
                self.resource_sampling_reason = "rocm-smi_missing"
            else:
                self.resource_sampling_reason = f"{self.gpu_backend}_unsupported"
        return sample

    def _update_summary(self, sample: Dict[str, Any]) -> None:
        def _peak(current: Optional[float], new_value: Any) -> Optional[float]:
            try:
                value = float(new_value)
            except Exception:
                return current
            if current is None or value > current:
                return value
            return current

        def _sum_count(sum_value: float, count: int, new_value: Any) -> tuple[float, int]:
            try:
                value = float(new_value)
            except Exception:
                return sum_value, count
            return sum_value + value, count + 1

        self._gpu_util_peak = _peak(self._gpu_util_peak, sample.get("gpu_util_percent"))
        self._vram_peak = _peak(self._vram_peak, sample.get("gpu_vram_used_mb"))
        self._vram_total = _peak(self._vram_total, sample.get("gpu_vram_total_mb"))
        self._system_ram_peak = _peak(self._system_ram_peak, sample.get("system_ram_used_mb"))
        self._gpu_temp_peak = _peak(self._gpu_temp_peak, sample.get("gpu_temp_c"))
        self._gpu_power_peak = _peak(self._gpu_power_peak, sample.get("gpu_power_w"))
        self._process_rss_peak = _peak(self._process_rss_peak, sample.get("process_rss_mb"))
        self._gpu_util_sum, self._gpu_util_count = _sum_count(self._gpu_util_sum, self._gpu_util_count, sample.get("gpu_util_percent"))
        self._cpu_util_sum, self._cpu_util_count = _sum_count(self._cpu_util_sum, self._cpu_util_count, sample.get("cpu_util_percent"))
        gpu_name = str(sample.get("gpu_name") or "").strip()
        if gpu_name:
            self._gpu_name = gpu_name

    def _write_sample(self, sample: Dict[str, Any]) -> None:
        if self._jsonl_fh is None:
            return
        try:
            self._jsonl_fh.write(json.dumps(sample, sort_keys=True) + "\n")
        except Exception:
            pass

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                sample = self._collect_sample()
                self._update_summary(sample)
                self._write_sample(sample)
                self.sample_index += 1
            except Exception as exc:
                if not self.resource_sampling_reason or self.resource_sampling_reason == "benchmark_active":
                    self.resource_sampling_reason = f"sample_failed:{type(exc).__name__}"
            if self.stop_event.wait(self.interval_seconds):
                break

    def _summary_payload(self) -> Dict[str, Any]:
        gpu_util_avg = (self._gpu_util_sum / self._gpu_util_count) if self._gpu_util_count else None
        cpu_util_avg = (self._cpu_util_sum / self._cpu_util_count) if self._cpu_util_count else None
        available = "yes" if self.resource_sampling_available else "no"
        reason = "" if self.resource_sampling_available else self.resource_sampling_reason
        return {
            "resource_sampling_available": available,
            "resource_sampling_reason": reason,
            "gpu_backend": self.gpu_backend,
            "sample_count": self.sample_index,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(self.started_at)),
            "ended_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(self.ended_at or time.time())),
            "interval_seconds": self.interval_seconds,
            "samples_path": str(self.samples_path),
            "gpu_util_peak_percent": self._gpu_util_peak,
            "gpu_util_avg_percent": gpu_util_avg,
            "vram_peak_mb": self._vram_peak,
            "vram_total_mb": self._vram_total,
            "gpu_temp_peak_c": self._gpu_temp_peak,
            "gpu_power_peak_w": self._gpu_power_peak,
            "gpu_name": self._gpu_name,
            "system_ram_peak_mb": self._system_ram_peak,
            "cpu_avg_percent": cpu_util_avg,
            "process_rss_peak_mb": self._process_rss_peak,
        }

    def _write_summary_files(self) -> None:
        if not self.output_dir:
            return
        payload = self._summary_payload()
        try:
            self.summary_json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        except Exception:
            pass
        try:
            lines = [
                f"resource_sampling_available={payload['resource_sampling_available']}",
                f"resource_sampling_reason={payload['resource_sampling_reason']}",
                f"gpu_backend={payload['gpu_backend']}",
                f"sample_count={payload['sample_count']}",
                f"started_at={payload['started_at']}",
                f"ended_at={payload['ended_at']}",
                f"interval_seconds={payload['interval_seconds']}",
                f"gpu_util_peak_percent={payload['gpu_util_peak_percent']}",
                f"gpu_util_avg_percent={payload['gpu_util_avg_percent']}",
                f"vram_peak_mb={payload['vram_peak_mb']}",
                f"vram_total_mb={payload['vram_total_mb']}",
                f"gpu_temp_peak_c={payload['gpu_temp_peak_c']}",
                f"gpu_power_peak_w={payload['gpu_power_peak_w']}",
                f"gpu_name={payload['gpu_name']}",
                f"system_ram_peak_mb={payload['system_ram_peak_mb']}",
                f"cpu_avg_percent={payload['cpu_avg_percent']}",
                f"process_rss_peak_mb={payload['process_rss_peak_mb']}",
                f"samples_path={payload['samples_path']}",
            ]
            self.summary_txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        except Exception:
            pass


def _finish_benchmark_run(sampler: Optional[BenchmarkResourceSampler], code: int) -> int:
    if sampler is not None:
        sampler.stop()
    return code


def _resolve_run_model(args: argparse.Namespace) -> str:
    if _is_direct_dks_source(getattr(args, "workflow_mode", ""), getattr(args, "workflow_source", "")):
        requested = str(getattr(args, "requested_stage2_model", "") or "").strip()
        if requested:
            return requested
    return str(getattr(args, "model", "htdemucs") or "htdemucs")


def _resolve_requested_stage2_model(args: argparse.Namespace) -> str:
    requested = str(getattr(args, "requested_stage2_model", "") or "").strip()
    if requested:
        return requested
    return DIRECT_DKS_MODEL_ALIAS


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


def _emit_direct_dks_backend_limited_markers(requested_model: str, resolved_model: str, detail: str) -> None:
    print("error_stage=stage2_preflight", file=sys.stderr)
    print("error_reason=drumsep_backend_runtime_limited", file=sys.stderr)
    print(f"requested_model={requested_model}", file=sys.stderr)
    if resolved_model:
        print(f"resolved_model={resolved_model}", file=sys.stderr)
    detail_map: Dict[str, str] = {}
    for part in str(detail or "").split("|"):
        token = str(part or "").strip()
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        detail_map[key.strip()] = value.strip()
    for key in (
        "model_id",
        "audio_separator_version",
        "yaml_path",
        "yaml_source",
        "yaml_top_level_keys",
        "yaml_training_instruments",
        "yaml_target_instrument",
        "expected_stems",
        "found_stems",
        "found_files",
        "output_validation_reason",
    ):
        value = detail_map.get(key, "")
        if value == "" and key in {"found_files", "yaml_target_instrument"}:
            value = "none"
        print(f"{key}={value}", file=sys.stderr)
    print("Direct Drum Kit Split preflight failed: drumsep_backend_runtime_limited", file=sys.stderr)
    print("This DrumSep backend currently returned only Kick and Snare; 6 drum parts are required for Direct Kit / Kit Split.", file=sys.stderr)
    if detail:
        print(f"Detail: {detail}", file=sys.stderr)
    print("guidance=Use normal stems for now; a 6-output DrumSep backend is still required for Direct Kit / Kit Split.", file=sys.stderr)


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


@contextmanager
def _dks_extract_stage2_lock(output_root: Path, stage2_backend: str = ""):
    """Throttle DrumSep stage 2 for Drum Split multi runs with backend-aware caps."""
    stage2_backend = _detect_dks_extract_stage2_backend(stage2_backend)
    requested_cap, raw_cap, effective_cap, ignored_reason = _resolve_dks_extract_stage2_benchmark_cap(stage2_backend)
    mps_requested_cap, mps_raw_cap, mps_effective_cap, mps_ignored_reason, mps_env_name = _resolve_dks_extract_stage2_mps_benchmark_cap(stage2_backend)
    cpu_requested_cap, cpu_raw_cap, cpu_effective_cap, cpu_ignored_reason, cpu_env_name = _resolve_dks_extract_stage2_cpu_benchmark_cap(stage2_backend)
    if mps_requested_cap is not None and stage2_backend == "mps":
        effective_cap = mps_effective_cap
    if cpu_requested_cap is not None:
        effective_cap = cpu_effective_cap
    batch_root = output_root.parent if output_root.parent.name.startswith("STEMwerk_") else output_root
    lock_path = batch_root / ".dks_extract_stage2.lock"
    lock_fh = None
    acquired_slot = None
    waited = False
    wait_started = time.monotonic()
    print(f"bench_dks_stage2_cap_requested={requested_cap if requested_cap is not None else raw_cap}", file=sys.stderr)
    print(f"bench_dks_stage2_cap_applied={effective_cap}", file=sys.stderr)
    print(f"bench_dks_stage2_cap_ignored_reason={ignored_reason}", file=sys.stderr)
    print(f"bench_dks_stage2_mps_cap_env={mps_env_name}", file=sys.stderr)
    print(f"bench_dks_stage2_mps_cap_requested={mps_requested_cap if mps_requested_cap is not None else mps_raw_cap}", file=sys.stderr)
    print(f"bench_dks_stage2_mps_cap_applied={mps_effective_cap}", file=sys.stderr)
    print(f"bench_dks_stage2_mps_cap_ignored_reason={mps_ignored_reason}", file=sys.stderr)
    print(f"bench_cpu_cap_env={cpu_env_name}", file=sys.stderr)
    print(f"bench_cpu_cap_requested={cpu_requested_cap if cpu_requested_cap is not None else cpu_raw_cap}", file=sys.stderr)
    print(f"bench_cpu_cap_applied={cpu_effective_cap}", file=sys.stderr)
    print(f"bench_cpu_cap_ignored_reason={cpu_ignored_reason}", file=sys.stderr)
    print(f"dks_extract_stage2_effective_cap={effective_cap}", file=sys.stderr)
    print(f"dks_extract_stage2_backend={stage2_backend}", file=sys.stderr)
    print(f"dks_extract_stage2_device={stage2_backend}", file=sys.stderr)
    print("dks_extract_stage2_runtime=drumsep", file=sys.stderr)
    print(f"lua_dks_extract_stage2_concurrency_cap={effective_cap}", file=sys.stderr)
    print("dks_extract_stage2_throttled=yes", file=sys.stderr)
    print(f"dks_extract_stage2_lock_path={lock_path}", file=sys.stderr)
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_fh = lock_path.open("a+", encoding="utf-8")
        try:
            import fcntl  # POSIX only; Windows falls back to no lock.

            if effective_cap <= 1:
                print("lua_dks_extract_stage2_queue_wait_start", file=sys.stderr)
                print("PROGRESS:50:Stage 2 queued for DrumSep...", flush=True)
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
                acquired_slot = 0
                waited = True
                wait_seconds = max(0.0, time.monotonic() - wait_started)
                print(f"lua_dks_extract_stage2_queue_wait_end wait_seconds={wait_seconds:.3f}", file=sys.stderr)
            else:
                slot_count = max(1, int(effective_cap))
                slot_handles = []
                while acquired_slot is None:
                    for slot_index in range(slot_count):
                        slot_path = Path(f"{lock_path}.{slot_index}")
                        slot_fh = slot_path.open("a+", encoding="utf-8")
                        try:
                            fcntl.flock(slot_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                            acquired_slot = slot_index
                            lock_fh.close()
                            lock_fh = slot_fh
                            break
                        except BlockingIOError:
                            slot_fh.close()
                            continue
                    if acquired_slot is not None:
                        break
                    if not waited:
                        print("lua_dks_extract_stage2_queue_wait_start", file=sys.stderr)
                        print("PROGRESS:50:Stage 2 queued for DrumSep...", flush=True)
                        waited = True
                    time.sleep(0.5)
                if waited:
                    wait_seconds = max(0.0, time.monotonic() - wait_started)
                    print(f"lua_dks_extract_stage2_queue_wait_end wait_seconds={wait_seconds:.3f}", file=sys.stderr)
        except ImportError:
            print("lua_dks_extract_stage2_queue_wait_skipped=fcntl_unavailable", file=sys.stderr)
        yield
    finally:
        if lock_fh is not None:
            try:
                if acquired_slot is not None:
                    import fcntl

                    fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
                    print("lua_dks_extract_stage2_lock_released=yes", file=sys.stderr)
            except Exception:
                pass
            try:
                lock_fh.close()
            except Exception:
                pass


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

    normalized_sources = _normalize_direct_dks_asset_map(entry_payload)
    yaml_filename = _direct_dks_yaml_filename(normalized_sources)
    if not yaml_filename:
        return False, "drumsep_yaml_filename_missing"

    changed = False
    mdx23c = checks_data.setdefault("mdx23c_download_list", {})
    if not isinstance(mdx23c, dict):
        return False, "mdx23c_download_list_invalid"
    runtime_entry = {DIRECT_DKS_MODEL_FILENAME: yaml_filename}
    current = mdx23c.get(entry_name)
    if current != runtime_entry:
        mdx23c[entry_name] = dict(runtime_entry)
        changed = True

    other_network = checks_data.setdefault("other_network_list_new", {})
    if not isinstance(other_network, dict):
        return False, "other_network_list_new_invalid"
    current_sources = other_network.get(entry_name)
    if current_sources != normalized_sources:
        other_network[entry_name] = dict(normalized_sources)
        changed = True

    if changed or not checks_path.exists():
        try:
            checks_path.parent.mkdir(parents=True, exist_ok=True)
            checks_path.write_text(json.dumps(checks_data, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        except Exception as exc:
            return False, f"download_checks_write_failed:{exc}"
    return True, str(checks_path)


def _preferred_direct_dks_asset_url(filename: str, url: str) -> str:
    normalized_filename = str(filename or "").strip()
    normalized_url = str(url or "").strip()
    if normalized_filename == DIRECT_DKS_MODEL_FILENAME and normalized_url == DIRECT_DKS_MODEL_DEAD_CKPT_URL:
        return DIRECT_DKS_MODEL_MIRROR_CKPT_URL
    return normalized_url


def _normalize_direct_dks_asset_map(asset_map: Dict[str, str]) -> Dict[str, str]:
    normalized: Dict[str, str] = {}
    for filename, url in (asset_map or {}).items():
        normalized[str(filename)] = _preferred_direct_dks_asset_url(str(filename), str(url))
    return normalized


def _direct_dks_yaml_filename(asset_map: Dict[str, str]) -> str:
    for filename in asset_map:
        if str(filename).lower().endswith(".yaml"):
            return str(filename)
    return ""


def _direct_dks_assets_ready(model_cache_dir: Path, asset_map: Dict[str, str]) -> Tuple[bool, List[str]]:
    missing_targets: List[str] = []
    for filename in asset_map:
        target = model_cache_dir / str(filename)
        if not target.exists():
            missing_targets.append(str(target))
    return len(missing_targets) == 0, missing_targets


def _validate_direct_dks_yaml(asset_map: Dict[str, str], model_cache_dir: Path, model_name: str) -> Tuple[bool, str]:
    yaml_name = _direct_dks_yaml_filename(asset_map)
    if not yaml_name:
        return False, "yaml_path_missing"
    yaml_path = model_cache_dir / yaml_name
    yaml_source = str(asset_map.get(yaml_name) or "")
    ckpt_path = model_cache_dir / DIRECT_DKS_MODEL_FILENAME
    ckpt_source = str(asset_map.get(DIRECT_DKS_MODEL_FILENAME) or "")
    print(f"model_id={model_name}", file=sys.stderr)
    print(f"yaml_path={yaml_path}", file=sys.stderr)
    print(f"yaml_source={yaml_source or 'unknown'}", file=sys.stderr)
    print(f"ckpt_path={ckpt_path}", file=sys.stderr)
    print(f"ckpt_source={ckpt_source or 'unknown'}", file=sys.stderr)
    print("expected_schema=audio,model,training", file=sys.stderr)
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=yaml.FullLoader)
    except Exception as exc:
        return False, f"yaml_load_failed:path={yaml_path}:source={yaml_source}:{type(exc).__name__}: {exc}"
    if not isinstance(data, dict):
        return False, f"yaml_schema_invalid:path={yaml_path}:top_level_type={type(data).__name__}"
    top_keys = sorted(str(key) for key in data.keys())
    print(f"yaml_top_level_keys={','.join(top_keys)}", file=sys.stderr)
    if "model" not in data:
        return False, (
            f"yaml_schema_invalid:path={yaml_path}:source={yaml_source}:"
            f"top_level_keys={','.join(top_keys)}:missing=model"
        )
    if "audio" not in data or "training" not in data:
        return False, (
            f"yaml_schema_invalid:path={yaml_path}:source={yaml_source}:"
            f"top_level_keys={','.join(top_keys)}:missing=audio_or_training"
        )
    model_section = data.get("model")
    if not isinstance(model_section, dict):
        return False, f"yaml_schema_invalid:path={yaml_path}:model_type={type(model_section).__name__}"
    return True, "ok"


def _normalize_direct_dks_stem_name(value: Any) -> str:
    text = str(value or "").strip().lower().replace("_", "").replace("-", "").replace(" ", "")
    if text in {"kick", "snare", "toms", "ride", "crash"}:
        return text
    if text in {"tom", "tomsdrums"}:
        return "toms"
    if text in {"hh", "hihat", "hihats"}:
        return "hihat"
    return text


def _load_direct_dks_yaml_metadata(asset_map: Dict[str, str], model_cache_dir: Path) -> Dict[str, Any]:
    yaml_name = _direct_dks_yaml_filename(asset_map)
    yaml_path = model_cache_dir / yaml_name if yaml_name else model_cache_dir
    payload: Dict[str, Any] = {
        "yaml_path": str(yaml_path) if yaml_name else "",
        "yaml_source": str(asset_map.get(yaml_name) or "") if yaml_name else "",
        "yaml_top_level_keys": [],
        "yaml_training_instruments": [],
        "yaml_target_instrument": "",
    }
    if not yaml_name or not yaml_path.exists():
        return payload
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=yaml.FullLoader)
    except Exception:
        return payload
    if not isinstance(data, dict):
        return payload
    payload["yaml_top_level_keys"] = sorted(str(key) for key in data.keys())
    training = data.get("training")
    if isinstance(training, dict):
        instruments = training.get("instruments")
        if isinstance(instruments, list):
            payload["yaml_training_instruments"] = [str(item) for item in instruments if str(item).strip()]
        target = str(training.get("target_instrument") or "").strip()
        if target:
            payload["yaml_target_instrument"] = target
    return payload


def _direct_dks_backend_limit_payload(
    runtime_info: Optional[Dict[str, Any]],
    model_name: str,
    model_meta: Dict[str, Any],
) -> Optional[Dict[str, Any]]:
    info = runtime_info if isinstance(runtime_info, dict) else {}
    versions = info.get("versions") if isinstance(info.get("versions"), dict) else {}
    audio_separator_version = str(versions.get("audio-separator") or "").strip()
    if audio_separator_version != "0.23.0":
        return None

    training_instruments = model_meta.get("yaml_training_instruments")
    if not isinstance(training_instruments, list):
        training_instruments = []
    normalized = {_normalize_direct_dks_stem_name(item) for item in training_instruments if str(item).strip()}
    if not set(DIRECT_DKS_EXPECTED_STEMS).issubset(normalized):
        return None

    return {
        "audio_separator_version": audio_separator_version,
        "model_id": str(model_name or ""),
        "yaml_path": str(model_meta.get("yaml_path") or ""),
        "yaml_source": str(model_meta.get("yaml_source") or ""),
        "yaml_top_level_keys": list(model_meta.get("yaml_top_level_keys") or []),
        "yaml_training_instruments": list(training_instruments),
        "yaml_target_instrument": str(model_meta.get("yaml_target_instrument") or ""),
        "expected_stems": list(DIRECT_DKS_EXPECTED_STEMS),
        "found_stems": ["kick", "snare"],
        "found_files": [],
        "output_validation_reason": DRUMSEP_RUNTIME_LIMIT_REASON,
    }


def _format_direct_dks_backend_limit_detail(payload: Dict[str, Any]) -> str:
    detail_parts = [
        f"model_id={payload.get('model_id') or ''}",
        f"audio_separator_version={payload.get('audio_separator_version') or ''}",
        f"expected_stems={','.join(str(item) for item in payload.get('expected_stems') or [])}",
        f"found_stems={','.join(str(item) for item in payload.get('found_stems') or [])}",
        f"found_files={','.join(str(item) for item in payload.get('found_files') or [])}",
        f"yaml_path={payload.get('yaml_path') or ''}",
        f"yaml_source={payload.get('yaml_source') or ''}",
        f"yaml_top_level_keys={','.join(str(item) for item in payload.get('yaml_top_level_keys') or [])}",
        f"yaml_training_instruments={','.join(str(item) for item in payload.get('yaml_training_instruments') or [])}",
        f"yaml_target_instrument={payload.get('yaml_target_instrument') or ''}",
        f"output_validation_reason={payload.get('output_validation_reason') or ''}",
    ]
    return " | ".join(detail_parts)


def _download_direct_dks_assets(model_cache_dir: Path, asset_map: Dict[str, str]) -> Tuple[bool, str]:
    for filename, url in asset_map.items():
        target = model_cache_dir / filename
        if target.exists():
            print(f"drumsep_cache_target={target}", file=sys.stderr)
            print("drumsep_cache_status=exists", file=sys.stderr)
            continue
        if not url:
            return False, f"asset_url_missing:{filename}:target={target}"
        print(f"drumsep_cache_target={target}", file=sys.stderr)
        print(f"drumsep_cache_source={url}", file=sys.stderr)
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
            print(f"drumsep_cache_error={filename}|{url}|{type(exc).__name__}: {exc}", file=sys.stderr)
            return False, f"asset_download_failed:{filename}:target={target}:source={url}:{type(exc).__name__}: {exc}"
    return True, "ok"


def _direct_dks_preflight_check(
    model_name: str,
    model_cache_dir: Path,
    runtime_info: Optional[Dict[str, Any]] = None,
    allow_mps_direct_demix: bool = False,
) -> Tuple[bool, str, str, Optional[str]]:
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
    for filename, source_url in asset_map.items():
        print(f"drumsep_catalog_asset={filename}|{source_url}", file=sys.stderr)
    asset_map = _normalize_direct_dks_asset_map(asset_map)
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
    ready, missing_targets = _direct_dks_assets_ready(model_cache_dir, asset_map)
    if not ready:
        return False, requested_model, resolved_model, "asset_ready_check_failed:" + "|".join(missing_targets)
    yaml_ok, yaml_detail = _validate_direct_dks_yaml(asset_map, model_cache_dir, requested_model or resolved_model)
    if not yaml_ok:
        return False, requested_model, resolved_model, yaml_detail
    model_meta = _load_direct_dks_yaml_metadata(asset_map, model_cache_dir)
    skip_backend_limit = (
        allow_mps_direct_demix
        and requested_model == DIRECT_DKS_MODEL_ALIAS
        and resolved_model == DIRECT_DKS_MODEL_FILENAME
    )
    backend_limit = None
    if not skip_backend_limit:
        backend_limit = _direct_dks_backend_limit_payload(runtime_info, resolved_model or requested_model, model_meta)
    if backend_limit:
        return False, requested_model, resolved_model, "backend_limited:" + _format_direct_dks_backend_limit_detail(backend_limit)
    print("drumsep_model_files_ready=yes", file=sys.stderr)
    return True, requested_model, resolved_model, None


def _apply_mps_experimental_policy(
    requested_device: str, resolved_device: str, model_name: str
) -> str:
    if resolved_device != "mps":
        return resolved_device
    if not (_is_darwin_arm64() and _is_demucs_model(model_name)):
        return resolved_device
    print(f"STEMWERK_DIAG requested_device={requested_device}", file=sys.stderr)
    print("STEMWERK_DIAG effective_device=mps", file=sys.stderr)
    print("STEMWERK_DIAG mps_experimental=yes", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_segment_size={MPS_DEMUCS_SEGMENT_SIZE}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_segment_policy={MPS_SEGMENT_POLICY}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_model={model_name}", file=sys.stderr)
    print("STEMWERK_DIAG mps_fallback_used=no", file=sys.stderr)
    print("STEMWERK_DIAG mps_fallback_reason=none", file=sys.stderr)
    return resolved_device


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
    state_name = "drumsep_runtime_rocm.env" if kind == "rocm" else "drumsep_runtime.env"
    return _read_env_file(base / "state" / state_name)


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


def _probe_drumsep_runtime_candidates(
    candidates: List[Path],
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
) -> Tuple[Optional[Path], str, Dict[str, Any], List[Dict[str, Any]]]:
    attempts: List[Dict[str, Any]] = []
    first_broken_detail = ""
    for candidate in candidates:
        if require_cuda:
            ok, detail, payload = _verify_drumsep_runtime(
                candidate,
                require_gpu=require_gpu,
                require_mps=require_mps,
                require_cuda=True,
            )
        elif require_mps:
            ok, detail, payload = _verify_drumsep_runtime(
                candidate,
                require_gpu=require_gpu,
                require_mps=True,
            )
        else:
            ok, detail, payload = _verify_drumsep_runtime(candidate, require_gpu=require_gpu)
        attempts.append({"python": str(candidate), "ok": bool(ok), "detail": str(detail)})
        if ok:
            return candidate, detail, payload, attempts
        if detail != "missing" and first_broken_detail == "":
            first_broken_detail = str(detail)
    return None, (first_broken_detail or "missing"), {}, attempts


def _verify_drumsep_runtime(
    python_path: Path,
    require_gpu: bool = False,
    require_mps: bool = False,
    require_cuda: bool = False,
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

print(json.dumps({
    "ok": True,
    "versions": versions,
    "torch_hip": torch_hip,
    "torch_cuda_available": torch_cuda_available,
    "device_names": device_names,
    "mps_built": mps_built,
    "mps_available": mps_available,
}, sort_keys=True))
"""
    try:
        completed = subprocess.run(
            [str(python_path), "-c", verify_code],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            env=_clean_env(),
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

    return True, output[:1200] or "ok", payload


def _select_drumsep_runtime(
    requested_device: str = "auto", runtime_base: Optional[Path] = None
) -> Tuple[Optional[Path], str, Dict[str, Any]]:
    rocm_state = _drumsep_runtime_state(runtime_base, "rocm")
    cpu_state = _drumsep_runtime_state(runtime_base, "cpu")
    rocm_candidates = _drumsep_state_python_candidates(rocm_state, _drumsep_rocm_runtime_python_path(runtime_base))
    cpu_candidates = _drumsep_state_python_candidates(cpu_state, _drumsep_runtime_python_path(runtime_base))
    rocm_python = rocm_candidates[0]
    cpu_python = cpu_candidates[0]
    device_norm = str(requested_device or "auto").strip().lower()

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
    bench_helper_device = str(os.environ.get(BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "") or "").strip().lower()
    print(f"normalized_device_request={normalized_request}", file=sys.stderr)

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
        info = {
            "cpu_detail": cpu_detail,
            "cpu_python": str(cpu_python),
            "cpu_python_attempts": cpu_attempts,
            "selection_policy": "explicit_cpu",
        }
        reason = "missing" if cpu_detail == "missing" else "broken"
        return None, reason, info

    if bench_helper_device == "cuda" and sys.platform.startswith("linux"):
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
        time.sleep(1.0)
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

    print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_start", file=sys.stderr)
    selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(cpu_candidates, require_gpu=False)
    print(f"timing_utc={_ts()} drumsep_runtime_probe_cpu_end detail={cpu_detail}", file=sys.stderr)
    if selected_cpu_python is not None:
        info = dict(cpu_payload or {})
        info["kind"] = "cpu"
        info["detail"] = cpu_detail
        info["fallback_reason"] = f"rocm_skipped:{rocm_detail}"
        info["selection_policy"] = "fallback_cpu"
        info["cpu_python_attempts"] = cpu_attempts
        info["rocm_python_attempts"] = rocm_attempts
        return selected_cpu_python, "cpu", info

    info = {
        "rocm_detail": rocm_detail,
        "cpu_detail": cpu_detail,
        "rocm_python": str(rocm_python),
        "cpu_python": str(cpu_python),
        "rocm_python_attempts": rocm_attempts,
        "cpu_python_attempts": cpu_attempts,
        "selection_policy": "fallback_cpu",
        "normalized_request": normalized_request,
    }
    reason = "missing" if rocm_detail == "missing" and cpu_detail == "missing" else "broken"
    return None, reason, info


def _resolve_benchmark_drumsep_helper_device(
    requested_device: str,
    runtime_kind: str,
    runtime_python: Optional[Path] = None,
) -> Tuple[str, str]:
    raw = str(os.environ.get(BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "") or "").strip().lower()
    normalized_request = str(requested_device or "auto").strip().lower()
    print(f"bench_drumsep_helper_device_env={raw or 'unset'}", file=sys.stderr)
    print(f"bench_drumsep_helper_device_requested={raw or 'none'}", file=sys.stderr)

    if not raw:
        print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=not_requested", file=sys.stderr)
        return "cpu", "not_requested"
    if raw not in BENCHMARK_DRUMSEP_HELPER_DEVICES:
        print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=invalid_request", file=sys.stderr)
        return "cpu", "invalid_request"
    if normalized_request == "cpu" and raw != "cpu":
        print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=explicit_cpu", file=sys.stderr)
        return "cpu", "explicit_cpu"
    if raw == "cpu":
        print("bench_drumsep_helper_device_applied=cpu", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=", file=sys.stderr)
        return "cpu", ""
    if not sys.platform.startswith("linux"):
        print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=platform_not_linux", file=sys.stderr)
        return "cpu", "platform_not_linux"
    if str(runtime_kind or "").strip().lower() != raw:
        print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
        print("bench_drumsep_helper_device_ignored_reason=runtime_backend_mismatch", file=sys.stderr)
        return "cpu", "runtime_backend_mismatch"
    if raw == "cuda":
        probe_ok, probe_reason, probe_detail = _probe_cuda_helper_isolation(Path(runtime_python or ""))
        print(f"drumsep_cuda_helper_probe_status={'ok' if probe_ok else 'failed'}", file=sys.stderr)
        print(f"drumsep_cuda_helper_probe_reason={probe_reason}", file=sys.stderr)
        print(f"drumsep_cuda_helper_probe_detail={probe_detail}", file=sys.stderr)
        if not probe_ok:
            print("bench_drumsep_helper_device_applied=none", file=sys.stderr)
            print(f"bench_drumsep_helper_device_ignored_reason={probe_reason}", file=sys.stderr)
            return "cpu", probe_reason

    print(f"bench_drumsep_helper_device_applied={raw}", file=sys.stderr)
    print("bench_drumsep_helper_device_ignored_reason=", file=sys.stderr)
    return raw, ""


def _run_direct_dks_drumsep_helper(
    input_path: Path,
    output_root: Path,
    model_cache_dir: Path,
    drumsep_python: Path,
    requested_model: str,
    resolved_model: str,
    route: str = "wrapper",
    device: str = "cpu",
    requested_device: str = "",
    backend_runtime: str = "",
) -> Tuple[bool, Dict[str, str], str, str]:
    helper_path = _drumsep_helper_path()
    result_json = output_root / "drumsep_result.json"
    helper_stdout = output_root / "drumsep_helper_stdout.txt"
    helper_stderr = output_root / "drumsep_helper_stderr.txt"
    helper_log = output_root / "drumsep_helper.log"

    print(f"timing_utc={_ts()} drumsep_helper_start", file=sys.stderr)
    print(f"drumsep_helper_python={drumsep_python}", file=sys.stderr)
    print(f"drumsep_helper_script={helper_path}", file=sys.stderr)
    print(f"drumsep_helper_model={resolved_model}", file=sys.stderr)
    print(f"drumsep_helper_route={route}", file=sys.stderr)
    print(f"drumsep_helper_device={device}", file=sys.stderr)
    print(f"drumsep_helper_requested_device={requested_device or device}", file=sys.stderr)
    print(f"drumsep_helper_backend_runtime={backend_runtime or device}", file=sys.stderr)
    print(f"drumsep_helper_output_dir={output_root}", file=sys.stderr)
    print(f"drumsep_helper_result_json={result_json}", file=sys.stderr)
    print(f"drumsep_helper_stdout={helper_stdout}", file=sys.stderr)
    print(f"drumsep_helper_stderr={helper_stderr}", file=sys.stderr)

    helper_env, helper_env_diag = build_drumsep_subprocess_env(
        _clean_env(),
        drumsep_python,
        _runtime_venv_root(drumsep_python),
        device,
    )
    _emit_drumsep_subprocess_env_diagnostics(helper_env_diag)

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
        "--route",
        route,
        "--device",
        device,
        "--requested-device",
        requested_device or device,
        "--backend-runtime",
        backend_runtime or device,
    ]
    print("PROGRESS:1:Starting Drum Kit runtime...", flush=True)
    print(f"timing_utc={_ts()} drumsep_helper_python_start", file=sys.stderr)

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
            env=helper_env,
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
                print(f"PROGRESS:{percent}:Splitting drum kit...", flush=True)
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
    print(f"timing_utc={_ts()} drumsep_helper_returncode={completed_returncode}", file=sys.stderr)
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
        detail_parts = [str(result_data.get("message") or reason)]
        for key in (
            "expected_stems",
            "found_stems",
            "found_files",
            "output_dir",
            "model_id",
            "yaml_path",
            "yaml_resolution",
            "yaml_top_level_keys",
            "yaml_training_instruments",
            "yaml_target_instrument",
            "output_validation_reason",
            "drumsep_mps_all_targets_route",
            "backend_runtime",
            "audio_separator_version",
            "requested_device",
            "effective_device",
            "model_device",
            "direct_demix_keys",
        ):
            value = result_data.get(key)
            if value in (None, "", [], {}):
                continue
            if isinstance(value, list):
                rendered = ",".join(str(item) for item in value)
            else:
                rendered = str(value)
            detail_parts.append(f"{key}={rendered}")
        detail = " | ".join(detail_parts)
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

    for key in (
        "drumsep_mps_all_targets_route",
        "mps_fallback_enabled",
        "pytorch_mps_fallback_env",
        "output_validation_reason",
        "expected_stems",
        "found_stems",
        "backend_runtime",
        "audio_separator_version",
        "requested_device",
        "effective_device",
        "model_device",
        "direct_demix_keys",
    ):
        value = result_data.get(key)
        if isinstance(value, list):
            value = ",".join(str(item) for item in value)
        if value not in (None, ""):
            print(f"{key}={value}", file=sys.stderr)

    print(f"timing_utc={_ts()} drumsep_helper_ok=true", file=sys.stderr)
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


def _resolve_normal_runtime_device(device_preference: str) -> Tuple[str, str, str, List[str]]:
    requested = str(device_preference or "auto")
    resolved = requested
    live_devices = get_available_devices()
    live_device_ids = [str(dev.get("id", "")) for dev in live_devices]
    print(f"STEMWERK_DIAG requested_device={requested}", file=sys.stderr)

    if requested == "auto":
        preferred = None
        if sys.platform.startswith("linux"):
            preferred = _prefer_linux_amd_device(live_devices, _get_skip_ids())
        if preferred:
            resolved = preferred.get("id") or "auto"
            print(
                f"STEMWERK_DIAG auto_selected_preferred={resolved} ({preferred.get('name','')})",
                file=sys.stderr,
            )
        else:
            try:
                dev_id, dev_name = select_device("auto")
                print(f"STEMWERK_DIAG auto_selected={dev_id} ({dev_name})", file=sys.stderr)
                resolved = dev_id
            except Exception:
                resolved = "auto"
    preview_device_id = resolved
    preview_device_name = ""
    try:
        preview_device_id, preview_device_name = select_device(resolved)
    except Exception as exc:
        print(f"normal_workflow_backend_preview_error={type(exc).__name__}:{exc}", file=sys.stderr)

    return requested, resolved, f"{preview_device_id}|{preview_device_name}", live_device_ids


def _is_unexpected_cpu_downgrade(requested_device: str, preview_device: str) -> bool:
    requested = str(requested_device or "auto").strip().lower()
    effective = str(preview_device or "").strip().lower()
    if effective != "cpu":
        return False
    return requested not in ("", "auto", "cpu")


def _map_reaper_stems_from_result(result: Any, output_root: Path) -> Dict[str, str]:
    stem_mapping = {
        "vocals": ["vocals", "vocal", "Vocals"],
        "drums": ["drums", "drum", "Drums"],
        "bass": ["bass", "Bass"],
        "other": ["other", "Other", "no_vocals", "instrumental", "Instrumental"],
        "guitar": ["guitar", "Guitar"],
        "piano": ["piano", "Piano", "keys", "Keys"],
    }

    reaper_stems: Dict[str, str] = {}
    for stem_name, stem_path in result.stems.items():
        abs_path = _resolve_stem_path(output_root, stem_path)
        if not abs_path.exists():
            raise FileNotFoundError(f"Expected separated stem not found: {abs_path}")

        filename = abs_path.stem.lower()
        target_name = stem_name
        for map_name, patterns in stem_mapping.items():
            if any(p.lower() in filename for p in patterns):
                target_name = map_name
                break

        new_path = abs_path.parent / f"{target_name}.wav"
        if abs_path != new_path:
            if new_path.exists():
                os.remove(new_path)
            shutil.move(str(abs_path), str(new_path))

        reaper_stems[target_name] = str(new_path)
        print(f"  {target_name}:  {new_path}", file=sys.stderr)

    return reaper_stems


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


def _path_text(value: str | Path | None) -> str:
    return str(value or "").replace("\\", "/").strip().lower()


def _split_path_value(value: str | None) -> List[str]:
    parts: List[str] = []
    for part in str(value or "").split(os.pathsep):
        text = part.strip()
        if text:
            parts.append(text)
    return parts


def _dedupe_path_parts(parts: List[str]) -> List[str]:
    seen: Set[str] = set()
    deduped: List[str] = []
    for part in parts:
        normalized = _path_text(part)
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        deduped.append(part)
    return deduped


def _filter_path_parts(parts: List[str], blocked_tokens: List[str]) -> List[str]:
    blocked = [token for token in blocked_tokens if token]
    if not blocked:
        return _dedupe_path_parts(parts)
    filtered: List[str] = []
    for part in parts:
        normalized = _path_text(part)
        if not normalized:
            continue
        if any(token in normalized for token in blocked):
            continue
        filtered.append(part)
    return _dedupe_path_parts(filtered)


def _runtime_venv_root(runtime_python: Path) -> Path:
    return Path(runtime_python).expanduser().parent.parent


def _runtime_bin_dir(runtime_venv: Path) -> Path:
    return Path(runtime_venv) / ("Scripts" if os.name == "nt" else "bin")


def build_drumsep_subprocess_env(
    base_env: Dict[str, str],
    runtime_python: Path,
    runtime_venv: Path,
    selected_backend: str,
) -> tuple[Dict[str, str], Dict[str, str]]:
    env = dict(base_env or {})
    backend = str(selected_backend or "").strip().lower()
    main_venv_root = _path_text(Path(sys.executable).expanduser().parent.parent)
    runtime_python = Path(runtime_python).expanduser()
    runtime_venv = Path(runtime_venv).expanduser()
    runtime_bin = str(_runtime_bin_dir(runtime_venv))
    runtime_venv_text = _path_text(runtime_venv)
    profile = "cpu_isolated" if backend == "cpu" else (f"{backend}_isolated" if backend else "helper_isolated")

    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env["VIRTUAL_ENV"] = str(runtime_venv)

    if backend == "cpu":
        env["CUDA_VISIBLE_DEVICES"] = ""
        env["NVIDIA_VISIBLE_DEVICES"] = ""
        env.pop("HIP_VISIBLE_DEVICES", None)
        env.pop("ROCR_VISIBLE_DEVICES", None)
        env.pop("HSA_OVERRIDE_GFX_VERSION", None)

    path_parts = _split_path_value(env.get("PATH"))
    path_parts = _filter_path_parts(path_parts, [main_venv_root, runtime_venv_text])
    env["PATH"] = os.pathsep.join([runtime_bin] + path_parts) if path_parts else runtime_bin

    ld_library_parts = _split_path_value(env.get("LD_LIBRARY_PATH"))
    ld_library_parts = _filter_path_parts(
        ld_library_parts,
        [
            main_venv_root,
            f"{main_venv_root}/site-packages/torch",
            f"{main_venv_root}/site-packages/nvidia",
        ],
    )
    if ld_library_parts:
        env["LD_LIBRARY_PATH"] = os.pathsep.join(ld_library_parts)
    else:
        env.pop("LD_LIBRARY_PATH", None)

    sanitized_ld = _path_text(env.get("LD_LIBRARY_PATH"))
    sanitized_path = _split_path_value(env.get("PATH"))
    diagnostics = {
        "drumsep_subprocess_env_profile": profile,
        "drumsep_helper_device_arg": backend or "unknown",
        "drumsep_python": str(runtime_python),
        "drumsep_virtual_env": str(runtime_venv),
        "drumsep_cuda_visible_devices": str(env.get("CUDA_VISIBLE_DEVICES", "")),
        "drumsep_nvidia_visible_devices": str(env.get("NVIDIA_VISIBLE_DEVICES", "")),
        "drumsep_ld_library_path_contains_main_venv": "yes" if main_venv_root and main_venv_root in sanitized_ld else "no",
        "drumsep_cuda_ld_library_path_contains_main_venv": "yes" if backend == "cuda" and main_venv_root and main_venv_root in sanitized_ld else "no",
        "drumsep_cuda_helper_runtime_venv": str(runtime_venv) if backend == "cuda" else "",
        "drumsep_path_starts_with_drumsep_venv": "yes" if sanitized_path and _path_text(sanitized_path[0]) == _path_text(runtime_bin) else "no",
    }
    return env, diagnostics


def _probe_cuda_helper_isolation(runtime_python: Path) -> tuple[bool, str, str]:
    if not str(runtime_python or "").strip() or not runtime_python.exists():
        return False, "cuda_helper_probe_runtime_missing", str(runtime_python or "")
    runtime_venv = _runtime_venv_root(runtime_python)
    env, diagnostics = build_drumsep_subprocess_env(_clean_env(), runtime_python, runtime_venv, "cuda")
    if diagnostics.get("drumsep_cuda_ld_library_path_contains_main_venv") != "no":
        return False, "cuda_helper_isolation_failed_main_venv_cudnn_leak", "sanitized_ld_library_path_contains_main_venv"

    main_venv_root = _path_text(Path(sys.executable).expanduser().parent.parent)
    probe_code = r"""
import json
import os
from pathlib import Path

from audio_separator.separator import Separator
import torch

tensor = torch.ones((1, 1, 8, 8), device="cuda:0")
weight = torch.ones((1, 1, 3, 3), device="cuda:0")
torch.nn.functional.conv2d(tensor, weight)
torch.cuda.synchronize()
maps = ""
try:
    maps = Path("/proc/self/maps").read_text(encoding="utf-8", errors="ignore")
except Exception:
    pass
cudnn_paths = sorted({
    line.rsplit(None, 1)[-1]
    for line in maps.splitlines()
    if "libcudnn" in line.lower() and "/" in line
})
print(json.dumps({
    "torch_file": str(getattr(torch, "__file__", "") or ""),
    "torch_cuda": str(getattr(torch.version, "cuda", "") or ""),
    "device_name": str(torch.cuda.get_device_name(0)),
    "cudnn_version": str(torch.backends.cudnn.version() or ""),
    "cudnn_paths": cudnn_paths,
    "virtual_env": str(os.environ.get("VIRTUAL_ENV", "")),
}))
"""
    try:
        completed = subprocess.run(
            [str(runtime_python), "-c", probe_code],
            text=True,
            capture_output=True,
            timeout=90,
            env=env,
            **_windows_no_window_kwargs(),
        )
    except Exception as exc:
        return False, "cuda_helper_probe_failed", f"{type(exc).__name__}:{exc}"

    combined = "\n".join(part for part in (completed.stdout, completed.stderr) if part).strip()
    lower = combined.lower()
    if "cudnngetlibconfig" in lower or "undefined symbol" in lower:
        return False, "cuda_helper_probe_failed_cudnn_symbol", combined[-1000:]
    if completed.returncode != 0:
        return False, "cuda_helper_probe_failed", combined[-1000:] or f"exit_{completed.returncode}"
    try:
        payload = json.loads((completed.stdout or "").strip().splitlines()[-1])
    except Exception as exc:
        return False, "cuda_helper_probe_invalid_output", f"{type(exc).__name__}:{combined[-500:]}"
    cudnn_paths = [str(path) for path in payload.get("cudnn_paths", [])]
    if main_venv_root and any(main_venv_root in _path_text(path) for path in cudnn_paths):
        return False, "cuda_helper_isolation_failed_main_venv_cudnn_leak", "|".join(cudnn_paths)
    runtime_venv_text = _path_text(runtime_venv)
    if cudnn_paths and not all(runtime_venv_text in _path_text(path) for path in cudnn_paths):
        return False, "cuda_helper_probe_untrusted_cudnn_source", "|".join(cudnn_paths)
    detail = json.dumps(payload, sort_keys=True)
    print(f"drumsep_cuda_helper_cudnn_source={'|'.join(cudnn_paths) or 'torch_runtime_managed'}", file=sys.stderr)
    return True, "ok", detail


def _emit_drumsep_subprocess_env_diagnostics(diagnostics: Dict[str, str]) -> None:
    for key in (
        "drumsep_subprocess_env_profile",
        "drumsep_helper_device_arg",
        "drumsep_python",
        "drumsep_virtual_env",
        "drumsep_cuda_visible_devices",
        "drumsep_nvidia_visible_devices",
        "drumsep_ld_library_path_contains_main_venv",
        "drumsep_cuda_ld_library_path_contains_main_venv",
        "drumsep_cuda_helper_runtime_venv",
        "drumsep_path_starts_with_drumsep_venv",
    ):
        print(f"{key}={diagnostics.get(key, '')}", file=sys.stderr)

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
    print(f"STEMWERK_DIAG cuda_available={env.get('cuda_available')}", file=sys.stderr)
    print(f"STEMWERK_DIAG cuda_count={env.get('cuda_count')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_built={env.get('mps_built')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_available={env.get('mps_available')}", file=sys.stderr)
    print(f"STEMWERK_DIAG mps_fallback_env={env.get('mps_fallback_env')}", file=sys.stderr)
    print(f"STEMWERK_DIAG selected_device={selected_device}", file=sys.stderr)
    print(f"STEMWERK_DIAG effective_device={selected_device}", file=sys.stderr)
    return env


def _configure_mps_runtime_fallback(requested_device: str, resolved_device: str) -> bool:
    if resolved_device != "mps":
        return False
    os.environ.pop(MPS_FALLBACK_ENV, None)
    print(
        f"STEMWERK_DIAG mps_fallback_enabled=0 requested_device={requested_device} resolved_device={resolved_device}",
        file=sys.stderr,
    )
    print("STEMWERK_DIAG pytorch_mps_fallback_env=unset", file=sys.stderr)
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
        "effective_device": selected_device or "",
        "model": model_name or "",
        "torch_version": str(env.get("torch_version") or env.get("torch") or "unknown"),
        "platform": str(env.get("platform") or platform.system()),
        "platform_machine": str(env.get("platform_machine") or platform.machine()),
        "mps_built": str(env.get("mps_built")),
        "mps_available": str(env.get("mps_available")),
        "mps_fallback_env": str(env.get("mps_fallback_env") or os.environ.get(MPS_FALLBACK_ENV, "")),
        "mps_experimental": "yes",
        "mps_segment_size": str(MPS_DEMUCS_SEGMENT_SIZE),
        "mps_segment_policy": MPS_SEGMENT_POLICY,
        "mps_fallback_used": "no",
        "mps_fallback_reason": "mps_channel_limit",
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

    benchmark_sampler = None
    if _benchmark_resource_sampling_requested():
        benchmark_sampler = BenchmarkResourceSampler(Path(args.output_dir).resolve())
        benchmark_sampler.start()

    device_preference = args.device
    if device_preference in skip_devices:
        print(f"WARNING: Device '{device_preference}' skipped; using auto", file=sys.stderr)
        device_preference = "auto"

    stems = _split_list(args.stems)
    run_model = _resolve_run_model(args)
    requested_stage2_model = _resolve_requested_stage2_model(args)
    if _is_extract_dks_source(args.workflow_mode, args.workflow_source):
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)
        stage1_root = output_root / "stage1_normal"
        stage2_root = output_root / "stage2_drumsep"
        stage1_root.mkdir(parents=True, exist_ok=True)
        stage2_root.mkdir(parents=True, exist_ok=True)
        stage1_model = run_model
        stage1_requested, stage1_resolved, stage1_preview, live_device_ids = _resolve_normal_runtime_device(device_preference)
        stage1_preview_device, _sep, stage1_preview_name = stage1_preview.partition("|")
        print(
            f"Drum Kit Split route detected: workflow_mode={args.workflow_mode} workflow_source={args.workflow_source}",
            file=sys.stderr,
        )
        print(f"workflow_mode={args.workflow_mode}", file=sys.stderr)
        print(f"workflow_source={args.workflow_source}", file=sys.stderr)
        print(f"ui_device_selected_before_run={device_preference}", file=sys.stderr)
        print(f"backend_device_arg={stage1_resolved}", file=sys.stderr)
        print(f"dks_extract_stage1_runtime=normal", file=sys.stderr)
        print(f"dks_extract_stage1_requested_device={stage1_requested}", file=sys.stderr)
        print(f"dks_extract_stage1_device={stage1_preview_device or stage1_resolved}", file=sys.stderr)
        print(f"dks_extract_stage1_device_name={stage1_preview_name}", file=sys.stderr)
        print(f"dks_extract_stage1_live_device_ids={','.join(live_device_ids)}", file=sys.stderr)
        print(f"dks_extract_intermediate_dir={stage1_root}", file=sys.stderr)
        print(f"dks_extract_stage2_dir={stage2_root}", file=sys.stderr)
        emit_phase("stage2_preflight")
        print("PROGRESS:0:Checking Drum Kit backend...", flush=True)
        if str(device_preference or "").strip().lower() == "mps":
            _configure_mps_runtime_fallback("mps", "mps")
        print(f"timing_utc={_ts()} drumsep_runtime_select_start", file=sys.stderr)
        drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime(device_preference)
        print(f"timing_utc={_ts()} drumsep_runtime_select_end", file=sys.stderr)
        print(f"dks_extract_stage2_backend={runtime_kind}", file=sys.stderr)
        if drumsep_python is None:
            reason = "drumsep_runtime_missing" if runtime_kind == "missing" else "drumsep_runtime_broken"
            runtime_path = Path(
                str(runtime_info.get("cpu_python") or runtime_info.get("rocm_python") or _drumsep_runtime_python_path())
            )
            _emit_direct_dks_stage2_runtime_markers(reason, runtime_path, json.dumps(runtime_info, sort_keys=True))
            print("dks_extract_stage2_runtime=drumsep", file=sys.stderr)
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)
        versions = runtime_info.get("versions") if isinstance(runtime_info.get("versions"), dict) else {}
        device_names = runtime_info.get("device_names") if isinstance(runtime_info.get("device_names"), list) else []
        fallback_reason = str(runtime_info.get("fallback_reason") or "")
        print(f"dks_extract_stage2_runtime=drumsep", file=sys.stderr)
        print(f"dks_extract_stage2_device={runtime_kind}", file=sys.stderr)
        print(f"dks_extract_stage2_requested_device={device_preference}", file=sys.stderr)
        print(f"drumsep_runtime_selected={runtime_kind}", file=sys.stderr)
        print(f"drumsep_runtime_selection_policy={runtime_info.get('selection_policy', '')}", file=sys.stderr)
        print(f"drumsep_python={drumsep_python}", file=sys.stderr)
        print(f"drumsep_gpu_capable={'yes' if runtime_kind in {'rocm', 'mps'} else 'no'}", file=sys.stderr)
        print(f"drumsep_torch_version={versions.get('torch', '')}", file=sys.stderr)
        print(f"drumsep_torch_hip={runtime_info.get('torch_hip', '')}", file=sys.stderr)
        print(f"drumsep_device_names={'|'.join(str(x) for x in device_names if str(x).strip())}", file=sys.stderr)
        if fallback_reason:
            print(f"drumsep_runtime_fallback_reason={fallback_reason}", file=sys.stderr)
        use_mps_direct_demix, mps_direct_demix_reason = _should_use_drumsep_mps_direct_demix(
            args.workflow_mode,
            args.workflow_source,
            device_preference,
            runtime_info,
            requested_stage2_model,
        )
        print(f"drumsep_mps_direct_demix_gate={'enabled' if use_mps_direct_demix else 'disabled'}", file=sys.stderr)
        print(f"drumsep_mps_direct_demix_gate_reason={mps_direct_demix_reason}", file=sys.stderr)
        ok, requested_model, resolved_model, known_err = _direct_dks_preflight_check(
            requested_stage2_model,
            model_cache_dir,
            runtime_info=runtime_info,
            allow_mps_direct_demix=use_mps_direct_demix,
        )
        if not ok:
            known_err_text = str(known_err or "")
            known_err_lower = known_err_text.lower()
            if known_err_text.startswith("backend_limited:"):
                _emit_direct_dks_backend_limited_markers(
                    requested_model or requested_stage2_model,
                    resolved_model or "",
                    known_err_text[len("backend_limited:"):],
                )
            else:
                reason = (
                    "drumsep_model_missing"
                    if "not found in supported model files" in known_err_lower or known_err_lower.startswith("catalog_") or known_err_lower.startswith("unsupported_")
                    else "drumsep_model_download_failed"
                )
                _emit_direct_dks_preflight_markers(reason, requested_model or requested_stage2_model, resolved_model or "", known_err_text)
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)
        requested_stage2_model = requested_model or requested_stage2_model
        run_model = resolved_model or run_model
        stage1_fallback_reason = ""
        if _is_unexpected_cpu_downgrade(stage1_requested, stage1_preview_device):
            stage1_fallback_reason = "live_runtime_cpu_only"
            print(f"dks_extract_stage1_fallback_reason={stage1_fallback_reason}", file=sys.stderr)
        try:
            print("PROGRESS:1:Extracting drums...", flush=True)
            emit_phase("stage1_parent_start")
            runtime_env = _emit_runtime_diagnostics(stage1_preview_device or stage1_resolved)
            _configure_mps_runtime_fallback(stage1_requested, stage1_resolved)
            stage1_runtime_device = _apply_mps_experimental_policy(
                stage1_requested,
                stage1_preview_device or stage1_resolved,
                stage1_model,
            )
            _enable_torch_weights_only_compat(stage1_model, stage1_runtime_device)
            emit_phase("model_setup_start")
            stage1_sep = StemSeparator(model=stage1_model, device=stage1_runtime_device)
            emit_phase("model_setup_end")

            def stage1_progress(pct: float, _msg: str):
                bounded = max(1, min(48, int(float(pct or 0) * 0.48)))
                emit_progress(bounded, "Extracting drums...")

            stage1_sep.on_progress = stage1_progress
            with _working_directory(stage1_root):
                emit_phase("separate_start")
                stage1_result = stage1_sep.separate(args.input, str(stage1_root), stems=["drums"])
                emit_phase("separate_end")
            stage1_stems = _map_reaper_stems_from_result(stage1_result, stage1_root)
            drums_input = Path(stage1_stems.get("drums", stage1_root / "drums.wav")).resolve()
            if not drums_input.exists():
                print("error_stage=stage1_parent", file=sys.stderr)
                print("error_reason=missing_drums_intermediate", file=sys.stderr)
                print(f"dks_extract_stage1_output={drums_input}", file=sys.stderr)
                return _finish_benchmark_run(benchmark_sampler, 1)
            print(f"dks_extract_stage1_output={drums_input}", file=sys.stderr)
            emit_phase("stage1_parent_end")

            print("PROGRESS:50:Starting Drum Kit runtime [Stage 2]...", flush=True)
            emit_phase("stage2_separate")
            stage2_backend = _detect_dks_extract_stage2_backend(runtime_kind, runtime_info, drumsep_python)
            helper_device, _ = _resolve_benchmark_drumsep_helper_device(device_preference, runtime_kind, drumsep_python)
            with _dks_extract_stage2_lock(output_root, stage2_backend):
                helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(
                    drums_input,
                    stage2_root,
                    model_cache_dir,
                    drumsep_python,
                    requested_stage2_model,
                    run_model,
                    route="mps-direct-demix" if use_mps_direct_demix else "wrapper",
                    device="mps" if use_mps_direct_demix else helper_device,
                    requested_device=device_preference,
                    backend_runtime="mps" if use_mps_direct_demix else stage2_backend,
                )
            if not helper_ok:
                stage = "stage2_separate"
                if helper_reason == "drumsep_model_load_failed":
                    stage = "stage2_model_load"
                elif helper_reason in {"drumsep_output_count_mismatch", "drumsep_direct_demix_failed"}:
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
                return _finish_benchmark_run(benchmark_sampler, 1)
            emit_phase("stem_write_start")
            print("PROGRESS:95:Writing drum tracks...", flush=True)
            final_stems: Dict[str, str] = {}
            for stem_name, stage2_path in helper_stems.items():
                src = Path(stage2_path).resolve()
                dst = output_root / src.name
                if dst.exists():
                    dst.unlink()
                shutil.move(str(src), str(dst))
                final_stems[stem_name] = str(dst)
            print(json.dumps(final_stems))
            emit_phase("stem_write_end")
            emit_phase("python_done")
            if write_done:
                write_done("DONE")
            return _finish_benchmark_run(benchmark_sampler, 0)
        except Exception as exc:
            import traceback

            traceback_text = traceback.format_exc()
            print(f"ERROR: {exc}", file=sys.stderr)
            print(traceback_text, file=sys.stderr, end="" if traceback_text.endswith("\n") else "\n")
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)

    if _is_direct_dks_source(args.workflow_mode, args.workflow_source):
        emit_phase("stage2_preflight")
        print("PROGRESS:0:Preparing Direct Drum Kit...", flush=True)
        print(f"timing_utc={_ts()} drumsep_runtime_select_start", file=sys.stderr)
        print(
            f"Direct Drum Kit Split route detected: workflow_mode={args.workflow_mode} workflow_source={args.workflow_source}",
            file=sys.stderr,
        )
        print(f"ui_device_selected_before_run={device_preference}", file=sys.stderr)
        print(f"backend_device_arg={device_preference}", file=sys.stderr)
        if str(device_preference or "").strip().lower() == "mps":
            _configure_mps_runtime_fallback("mps", "mps")
        drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime(device_preference)
        print(f"timing_utc={_ts()} drumsep_runtime_select_end", file=sys.stderr)
        if drumsep_python is None:
            reason = "drumsep_runtime_missing" if runtime_kind == "missing" else "drumsep_runtime_broken"
            runtime_path = Path(
                str(runtime_info.get("cpu_python") or runtime_info.get("rocm_python") or _drumsep_runtime_python_path())
            )
            _emit_direct_dks_stage2_runtime_markers(reason, runtime_path, json.dumps(runtime_info, sort_keys=True))
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)
        versions = runtime_info.get("versions") if isinstance(runtime_info.get("versions"), dict) else {}
        device_names = runtime_info.get("device_names") if isinstance(runtime_info.get("device_names"), list) else []
        fallback_reason = str(runtime_info.get("fallback_reason") or "")
        print(f"drumsep_runtime_selected={runtime_kind}", file=sys.stderr)
        print(
            f"drumsep_runtime_selection_policy={runtime_info.get('selection_policy', '')}",
            file=sys.stderr,
        )
        print(f"drumsep_python={drumsep_python}", file=sys.stderr)
        print(f"drumsep_gpu_capable={'yes' if runtime_kind in {'rocm', 'mps'} else 'no'}", file=sys.stderr)
        print(f"drumsep_torch_version={versions.get('torch', '')}", file=sys.stderr)
        print(f"drumsep_torch_hip={runtime_info.get('torch_hip', '')}", file=sys.stderr)
        print(f"drumsep_device_names={'|'.join(str(x) for x in device_names if str(x).strip())}", file=sys.stderr)
        if fallback_reason:
            print(f"drumsep_runtime_fallback_reason={fallback_reason}", file=sys.stderr)
        use_mps_direct_demix, mps_direct_demix_reason = _should_use_drumsep_mps_direct_demix(
            args.workflow_mode,
            args.workflow_source,
            device_preference,
            runtime_info,
            run_model,
        )
        print(f"drumsep_mps_direct_demix_gate={'enabled' if use_mps_direct_demix else 'disabled'}", file=sys.stderr)
        print(f"drumsep_mps_direct_demix_gate_reason={mps_direct_demix_reason}", file=sys.stderr)
        try:
            ok, requested_model, resolved_model, known_err = _direct_dks_preflight_check(
                run_model,
                model_cache_dir,
                runtime_info=runtime_info,
                allow_mps_direct_demix=use_mps_direct_demix,
            )
            if not ok:
                known_err_text = str(known_err or "")
                known_err_lower = known_err_text.lower()
                if known_err_text.startswith("backend_limited:"):
                    _emit_direct_dks_backend_limited_markers(
                        requested_model or run_model,
                        resolved_model or "",
                        known_err_text[len("backend_limited:"):],
                    )
                else:
                    reason = (
                        "drumsep_model_missing"
                        if "not found in supported model files" in known_err_lower
                        or known_err_lower.startswith("catalog_")
                        else "drumsep_model_download_failed"
                    )
                    _emit_direct_dks_preflight_markers(reason, requested_model or run_model, resolved_model or "", known_err_text)
                emit_phase("python_error")
                if write_done:
                    write_done("ERROR")
                return _finish_benchmark_run(benchmark_sampler, 1)
            requested_stage2_model = requested_model or requested_stage2_model
            run_model = resolved_model or run_model
        except Exception as exc:
            _emit_direct_dks_preflight_markers("drumsep_model_download_failed", run_model, "", str(exc))
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)
        emit_phase("separate_start")
        print(f"timing_utc={_ts()} drumsep_helper_start", file=sys.stderr)
        stage2_backend = _detect_dks_extract_stage2_backend(runtime_kind, runtime_info, drumsep_python)
        helper_device, _ = _resolve_benchmark_drumsep_helper_device(device_preference, runtime_kind, drumsep_python)
        helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(
            Path(args.input).resolve(),
            output_root,
            model_cache_dir,
            drumsep_python,
            requested_stage2_model,
            run_model,
            route="mps-direct-demix" if use_mps_direct_demix else "wrapper",
            device="mps" if use_mps_direct_demix else helper_device,
            requested_device=device_preference,
            backend_runtime="mps" if use_mps_direct_demix else stage2_backend,
        )
        if not helper_ok:
            stage = "stage2_separate"
            if helper_reason == "drumsep_model_load_failed":
                stage = "stage2_model_load"
            elif helper_reason in {"drumsep_output_count_mismatch", "drumsep_direct_demix_failed"}:
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
            return _finish_benchmark_run(benchmark_sampler, 1)
        emit_phase("separate_end")
        emit_phase("stem_write_start")
        print("PROGRESS:95:Writing drum tracks...", flush=True)
        print(json.dumps(helper_stems))
        emit_phase("stem_write_end")
        emit_phase("python_done")
        if write_done:
            write_done("DONE")
        return _finish_benchmark_run(benchmark_sampler, 0)

    requested_device, resolved_device, preview_text, live_device_ids = _resolve_normal_runtime_device(device_preference)
    preview_device_id, _sep, preview_device_name = preview_text.partition("|")
    print(f"normal_workflow_backend_seen_device_request={requested_device}", file=sys.stderr)
    print(f"normal_workflow_live_device_ids={','.join(live_device_ids)}", file=sys.stderr)
    print(f"normal_workflow_backend_seen_device_resolved={resolved_device}", file=sys.stderr)
    print(f"normal_workflow_backend_preview_device={preview_device_id}", file=sys.stderr)
    print(f"normal_workflow_backend_preview_name={preview_device_name}", file=sys.stderr)
    workflow_mode = str(args.workflow_mode or "stems").strip() or "stems"
    workflow_source = str(args.workflow_source or "normal").strip() or "normal"
    route = "normal"
    stage = "single_stage"
    backend = _resolve_normal_workflow_backend(resolved_device)
    print(f"workflow_source={workflow_source}", file=sys.stderr)
    print(f"workflow_mode={workflow_mode}", file=sys.stderr)
    print(f"route={route}", file=sys.stderr)
    print(f"stage={stage}", file=sys.stderr)
    print(f"model_name={run_model}", file=sys.stderr)
    print(f"device={resolved_device}", file=sys.stderr)
    print(f"backend={backend}", file=sys.stderr)
    if _is_unexpected_cpu_downgrade(device_preference, preview_device_id):
        print("normal_workflow_backend_fallback_reason=live_runtime_cpu_only", file=sys.stderr)
        print(
            "Runtime device fallback blocked: the explicitly requested accelerator is unavailable in the live normal STEMwerk runtime.",
            file=sys.stderr,
        )
        return 2

    runtime_env: Dict[str, object] = {}
    try:
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)
        _configure_mps_runtime_fallback(device_preference, resolved_device)
        resolved_device = _apply_mps_experimental_policy(
            device_preference,
            resolved_device,
            run_model,
        )
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
        reaper_stems = _map_reaper_stems_from_result(result, output_root)

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
        if (_is_direct_dks_source(args.workflow_mode, args.workflow_source) or _is_extract_dks_source(args.workflow_mode, args.workflow_source)) and _is_known_drumsep_runtime_unsupported_error(exc, traceback_text, run_model):
            _emit_direct_dks_runtime_unsupported_markers(
                requested_stage2_model or run_model,
                run_model,
                "audio_separator mdxc loader missing expected config field 'model'",
            )
            emit_phase("python_error")
            if write_done:
                write_done("ERROR")
            return _finish_benchmark_run(benchmark_sampler, 1)
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
                print(f"STEMWERK_DIAG {key}={value}", file=sys.stderr)
        print(f"ERROR: {exc}", file=sys.stderr)
        print(traceback_text, file=sys.stderr, end="" if traceback_text.endswith("\n") else "\n")
        emit_phase("python_error")
        if write_done:
            write_done("ERROR")
        return _finish_benchmark_run(benchmark_sampler, 1)


if __name__ == "__main__":
    raise SystemExit(main())
