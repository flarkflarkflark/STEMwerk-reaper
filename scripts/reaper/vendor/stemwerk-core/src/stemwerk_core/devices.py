from __future__ import annotations

from dataclasses import dataclass
import platform
import re
import subprocess
import warnings
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_DEVICE_SKIPS: List[Dict[str, str]] = []
_ROCMINFO_ARCHES: Optional[List[str]] = None


@dataclass(frozen=True)
class DeviceNormalizationResult:
    requested_device: str
    normalized_device: str
    effective_backend: str
    device_normalized: bool
    error_reason: str = ""


class DeviceNormalizationError(ValueError):
    def __init__(self, result: DeviceNormalizationResult):
        self.result = result
        super().__init__(result.error_reason)


class TorchDeviceProbe:
    def torch_cuda_is_available(self) -> bool:
        try:
            import torch

            return bool(torch.cuda.is_available())
        except Exception:
            return False

    def torch_cuda_device_count(self) -> int:
        try:
            import torch

            return int(torch.cuda.device_count())
        except Exception:
            return 0

    def torch_cuda_get_device_name(self, index: int) -> str:
        try:
            import torch

            return str(torch.cuda.get_device_name(index))
        except Exception:
            return ""

    def torch_hip_version(self) -> str:
        try:
            import torch

            return str(getattr(getattr(torch, "version", None), "hip", "") or "")
        except Exception:
            return ""

    def torch_mps_is_available(self) -> bool:
        return _is_mps_available()

    def system(self) -> str:
        try:
            return str(platform.system())
        except Exception:
            return ""

    def machine(self) -> str:
        try:
            return str(platform.machine())
        except Exception:
            return ""


def _device_error(
    requested: str,
    normalized: str,
    backend: str,
    reason: str,
) -> DeviceNormalizationError:
    return DeviceNormalizationError(
        DeviceNormalizationResult(
            requested_device=requested,
            normalized_device=normalized,
            effective_backend=backend,
            device_normalized=False,
            error_reason=reason,
        )
    )


def _cuda_backend_from_probe(probe: object) -> str:
    try:
        hip = str(probe.torch_hip_version() or "")
    except Exception:
        hip = ""
    return "rocm" if hip else "cuda"


def normalize_torch_device(
    requested: str = "auto",
    probe: Optional[object] = None,
    strict: bool = False,
) -> DeviceNormalizationResult:
    """Normalize explicit torch device requests without owning auto policy."""
    requested_device = str(requested or "auto").strip().lower()
    probe = probe or TorchDeviceProbe()

    if requested_device == "cpu":
        return DeviceNormalizationResult("cpu", "cpu", "cpu", False)

    if requested_device == "auto":
        return DeviceNormalizationResult("auto", "auto", "auto", False)

    if requested_device == "cuda":
        backend = _cuda_backend_from_probe(probe)
        try:
            cuda_available = bool(probe.torch_cuda_is_available())
            device_count = int(probe.torch_cuda_device_count())
        except Exception:
            cuda_available = False
            device_count = 0
        if not cuda_available or device_count < 1:
            error = _device_error("cuda", "cuda", backend, "torch_cuda_unavailable")
            if strict:
                raise error
            return error.result
        return DeviceNormalizationResult("cuda", "cuda:0", backend, True)

    cuda_match = re.fullmatch(r"cuda:(\d+)", requested_device)
    if cuda_match:
        backend = _cuda_backend_from_probe(probe)
        try:
            cuda_available = bool(probe.torch_cuda_is_available())
            device_count = int(probe.torch_cuda_device_count())
        except Exception:
            cuda_available = False
            device_count = 0
        if not cuda_available or device_count < 1:
            error = _device_error(requested_device, requested_device, backend, "torch_cuda_unavailable")
            if strict:
                raise error
            return error.result
        index = int(cuda_match.group(1))
        if index >= device_count:
            error = _device_error(
                requested_device,
                requested_device,
                backend,
                f"cuda_index_out_of_range:index={index}:count={device_count}",
            )
            if strict:
                raise error
            return error.result
        return DeviceNormalizationResult(requested_device, requested_device, backend, False)

    if requested_device == "mps":
        try:
            system = str(probe.system() or "")
            machine = str(probe.machine() or "").lower()
            mps_available = bool(probe.torch_mps_is_available())
        except Exception:
            system = ""
            machine = ""
            mps_available = False
        if system == "Darwin" and machine in {"arm64", "aarch64"} and mps_available:
            return DeviceNormalizationResult("mps", "mps", "mps", False)
        error = _device_error("mps", "mps", "mps", "mps_unavailable")
        if strict:
            raise error
        return error.result

    if requested_device == "directml" or re.fullmatch(r"directml:\d+", requested_device):
        return DeviceNormalizationResult(requested_device, requested_device, "directml", False)

    error = _device_error(
        requested_device,
        requested_device,
        "unknown",
        "unknown_device_request",
    )
    if strict:
        raise error
    return error.result


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

    normalized = normalize_torch_device(requested_device)

    if not normalized.error_reason and normalized.normalized_device == "mps":
        return "mps", "Apple MPS"

    if not normalized.error_reason and normalized.effective_backend == "directml":
        if normalized.normalized_device in available_ids:
            for dev in available:
                if dev["id"] == normalized.normalized_device:
                    return dev["id"], dev["name"]
        return normalized.normalized_device, "DirectML"

    if not normalized.error_reason and normalized.normalized_device.startswith("cuda:"):
        device_name = ""
        index_match = re.fullmatch(r"cuda:(\d+)", normalized.normalized_device)
        if index_match and torch is not None:
            try:
                device_name = str(torch.cuda.get_device_name(int(index_match.group(1))))
            except Exception:
                device_name = ""
        return normalized.normalized_device, device_name or normalized.normalized_device

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
