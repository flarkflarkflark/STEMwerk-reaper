from __future__ import annotations

import platform
import subprocess
import warnings
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_DEVICE_SKIPS: List[Dict[str, str]] = []
_ROCMINFO_ARCHES: Optional[List[str]] = None


def _windows_no_window_kwargs() -> Dict[str, int]:
    if platform.system() == "Windows" and hasattr(subprocess, "CREATE_NO_WINDOW"):
        return {"creationflags": subprocess.CREATE_NO_WINDOW}
    return {}


def _is_macos_apple_silicon() -> bool:
    machine = ""
    try:
        machine = platform.machine().lower()
    except Exception:
        machine = ""
    return platform.system() == "Darwin" and machine in {"arm64", "aarch64"}


def _is_mps_available() -> bool:
    if not _is_macos_apple_silicon():
        return False
    try:
        import torch

        mps = getattr(getattr(torch, "backends", None), "mps", None)
        return bool(mps is not None and mps.is_available())
    except Exception:
        return False


def _rocm_arches_from_rocminfo() -> List[str]:
    """Best-effort list of GPU arch names (gfx...) in enumeration order."""
    try:
        proc = subprocess.run(
            ["rocminfo"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3.0,
        )
        text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    except Exception:
        return []

    arches: List[str] = []
    in_agent = False
    is_gpu = False
    arch: Optional[str] = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Agent "):
            if in_agent and is_gpu and arch and arch.startswith("gfx"):
                arches.append(arch)
            in_agent = True
            is_gpu = False
            arch = None
            continue
        if not in_agent:
            continue
        if line.startswith("Device Type:"):
            is_gpu = "GPU" in line
        elif line.startswith("Name:"):
            val = line.split(":", 1)[1].strip() if ":" in line else ""
            if val:
                arch = val
    if in_agent and is_gpu and arch and arch.startswith("gfx"):
        arches.append(arch)
    return arches


def _get_cached_rocm_arches() -> List[str]:
    global _ROCMINFO_ARCHES
    if _ROCMINFO_ARCHES is None:
        _ROCMINFO_ARCHES = _rocm_arches_from_rocminfo()
    return _ROCMINFO_ARCHES


def _rocblas_has_tensile_for_arch(arch: Optional[str]) -> bool:
    if not arch or not isinstance(arch, str):
        return True
    arch = arch.split(":", 1)[0].strip()
    if not arch.startswith("gfx"):
        return True
    rocblas_lib_dir = Path("/opt/rocm/lib/rocblas/library")
    try:
        if not rocblas_lib_dir.exists():
            return True
        matches = list(rocblas_lib_dir.glob(f"*{arch}*.dat"))
        return len(matches) > 0
    except Exception:
        return True


def _windows_gpu_names() -> List[str]:
    if platform.system() != "Windows":
        return []

    names: List[str] = []
    try:
        proc = subprocess.run(
            ["wmic", "path", "win32_VideoController", "get", "name"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3.0,
            **_windows_no_window_kwargs(),
        )
        for line in (proc.stdout or "").splitlines():
            line = line.strip()
            if not line or line.lower() == "name":
                continue
            names.append(line)
    except Exception:
        names = []

    if names:
        return names

    try:
        proc = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=3.0,
            **_windows_no_window_kwargs(),
        )
        for line in (proc.stdout or "").splitlines():
            line = line.strip()
            if line:
                names.append(line)
    except Exception:
        return []

    return names


def get_available_devices() -> List[Dict[str, str]]:
    """Get list of available compute devices."""
    global _DEVICE_SKIPS
    _DEVICE_SKIPS = []
    devices = [
        {"id": "auto", "name": "Auto", "type": "auto"},
        {"id": "cpu", "name": "CPU", "type": "cpu"},
    ]

    try:
        import torch
    except ImportError:
        return devices

    is_linux = platform.system() == "Linux"
    try:
        torch_hip = getattr(getattr(torch, "version", None), "hip", None)
    except Exception:
        torch_hip = None
    torch_version = str(getattr(torch, "__version__", ""))
    is_rocm = bool(is_linux and (torch_hip or ("rocm" in torch_version.lower())))

    def _device_rocm_arch(idx: int) -> Optional[str]:
        try:
            arches = _get_cached_rocm_arches()
            if idx < len(arches):
                return arches[idx]
        except Exception:
            pass
        try:
            props = torch.cuda.get_device_properties(idx)
            return getattr(props, "gcnArchName", None) or getattr(props, "gcnArch", None)
        except Exception:
            return None

    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            name = torch.cuda.get_device_name(i)
            if is_rocm:
                arch = _device_rocm_arch(i)
                if not _rocblas_has_tensile_for_arch(arch):
                    _DEVICE_SKIPS.append(
                        {
                            "id": f"cuda:{i}",
                            "name": name,
                            "reason": (
                                "ROCm rocBLAS Tensile library missing for arch "
                                f"{arch} (see /opt/rocm/lib/rocblas/library)."
                            ),
                        }
                    )
                    continue
            devices.append({"id": f"cuda:{i}", "name": name, "type": "cuda"})

    if _is_mps_available():
        devices.append({"id": "mps", "name": "Apple MPS", "type": "mps"})

    try:
        import torch_directml

        dml_device_count = torch_directml.device_count()
        win_names = _windows_gpu_names()
        for i in range(dml_device_count):
            name = win_names[i] if i < len(win_names) else f"DirectML GPU {i}"
            device_id = f"directml:{i}" if dml_device_count > 1 else "directml"
            devices.append({"id": device_id, "name": name, "type": "directml"})
    except ImportError:
        pass
    except Exception:
        pass

    return devices


def select_device(requested_device: str = "auto") -> Tuple[str, str]:
    """Select the compute device based on user preference."""
    try:
        import torch
    except ImportError:
        torch = None

    available = get_available_devices()
    available_ids = [d["id"] for d in available]
    skipped_ids = {d.get("id") for d in (_DEVICE_SKIPS or []) if d.get("id")}
    requested_device = requested_device or "auto"

    def first_backend_device(backend: str) -> Optional[Tuple[str, str]]:
        for dev in available:
            dev_id = str(dev.get("id", ""))
            dev_type = str(dev.get("type", ""))
            if dev_type == backend or dev_id == backend or dev_id.startswith(f"{backend}:"):
                return str(dev["id"]), str(dev["name"])
        return None

    if requested_device == "auto":
        for dev in available:
            if dev["type"] in ("cuda", "directml"):
                return dev["id"], dev["name"]
        return "cpu", "CPU"

    if requested_device == "cpu":
        return "cpu", "CPU"

    if requested_device == "mps":
        if torch is not None and _is_mps_available():
            return "mps", "Apple MPS"
        warnings.warn("MPS requested but not available; using CPU.")
        return "cpu", "CPU"

    if requested_device in available_ids:
        for dev in available:
            if dev["id"] == requested_device:
                return dev["id"], dev["name"]

    if requested_device == "directml":
        fallback = first_backend_device("directml")
        if fallback:
            return fallback

    if isinstance(requested_device, str) and requested_device.startswith("directml:"):
        if requested_device in skipped_ids:
            for skip in (_DEVICE_SKIPS or []):
                if skip.get("id") == requested_device:
                    warnings.warn(
                        f"Requested device '{requested_device}' is not usable: {skip.get('reason')}"
                    )
                    break
        fallback = first_backend_device("directml")
        if fallback:
            warnings.warn(
                f"Requested device '{requested_device}' not available; falling back to {fallback[0]}"
            )
            return fallback

    if isinstance(requested_device, str) and requested_device.startswith("cuda:"):
        if requested_device in skipped_ids:
            for skip in (_DEVICE_SKIPS or []):
                if skip.get("id") == requested_device:
                    warnings.warn(
                        f"Requested device '{requested_device}' is not usable: {skip.get('reason')}"
                    )
                    break
        for dev in available:
            if dev.get("type") == "cuda" and str(dev.get("id", "")).startswith("cuda:"):
                warnings.warn(
                    f"Requested device '{requested_device}' not available; falling back to {dev['id']}"
                )
                return dev["id"], dev["name"]

    warnings.warn(f"Requested device '{requested_device}' not available; using CPU.")
    return "cpu", "CPU"
