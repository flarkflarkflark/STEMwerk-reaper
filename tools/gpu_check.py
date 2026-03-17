#!/usr/bin/env python3
"""
Lightweight GPU/runtime detection and quick tensor benchmark.
Writes results to stdout and `gpu_check.json`.

Run inside your project's venv: `python tools/gpu_check.py`
"""
import json
import platform
import subprocess
import sys
import os
import time


def run_cmd(cmd):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True, text=True)
        return out.strip()
    except Exception:
        return None


info = {
    "platform": platform.system(),
    "platform_release": platform.release(),
    "python": platform.python_version(),
    "torch": None,
    "cuda_available": False,
    "cuda_version": None,
    "torch_hip": None,
    "cuda_devices": [],
    "nvidia_smi": None,
    "rocm_detected": False,
    "rocm_path": None,
    "rocminfo_available": False,
    "rocminfo_summary": None,
    "mps_available": False,
    "directml_possible": False,
    "lspci_vga": None,
    "amd_gpus": [],
    "quick_benchmark": {},
}

# Try import torch
try:
    import torch
    info["torch"] = getattr(torch, "__version__", str(torch))
    try:
        info["cuda_available"] = torch.cuda.is_available()
    except Exception:
        info["cuda_available"] = False
    try:
        info["cuda_version"] = torch.version.cuda
    except Exception:
        info["cuda_version"] = None
    try:
        info["torch_hip"] = getattr(getattr(torch, "version", None), "hip", None)
    except Exception:
        info["torch_hip"] = None
    try:
        if info["cuda_available"]:
            info["cuda_devices"] = [torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())]
    except Exception:
        info["cuda_devices"] = []
    try:
        info["mps_available"] = getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available()
    except Exception:
        info["mps_available"] = False
except Exception as e:
    info["torch_error"] = str(e)

# lspci (Linux) - useful to detect AMD GPUs even when ROCm isn't installed yet
if platform.system().lower() == "linux":
    vga = run_cmd("lspci | grep -i vga") or run_cmd("lspci -nn | grep -i vga")
    if vga:
        info["lspci_vga"] = vga
        for line in vga.splitlines():
            if "AMD" in line or "Advanced Micro Devices" in line or "AMD/ATI" in line:
                info["amd_gpus"].append(line.strip())

# nvidia-smi
n = run_cmd("nvidia-smi -L") or run_cmd("nvidia-smi --query-gpu=name --format=csv,noheader")
if n:
    info["nvidia_smi"] = n

# ROCm detection (Linux AMD)
rocm_path = os.environ.get("ROCM_PATH") or ("/opt/rocm" if os.path.exists("/opt/rocm") else None)
info["rocm_path"] = rocm_path
rocminfo = run_cmd("rocminfo") or (run_cmd("/opt/rocm/bin/rocminfo") if os.path.exists("/opt/rocm/bin/rocminfo") else None)
if rocminfo:
    info["rocminfo_available"] = True
    # Keep it short for logs/UIs
    info["rocminfo_summary"] = "\n".join(rocminfo.splitlines()[:40])

# Consider ROCm "detected" if path exists, rocminfo works, or torch exposes HIP.
if rocm_path or info.get("rocminfo_available") or info.get("torch_hip"):
    info["rocm_detected"] = True

# DirectML hint (torch-directml)
try:
    import importlib
    info["directml_possible"] = importlib.util.find_spec("torch_directml") is not None
except Exception:
    info["directml_possible"] = False


def try_benchmark(device):
    res = {"device": device, "ok": False}
    try:
        import torch
        dtype = torch.float32
        # handle DirectML device object via torch_directml
        if device == "dml":
            try:
                import torch_directml
                d = torch_directml.device()
            except Exception as e:
                res["error"] = f"torch_directml import/device error: {e}"
                return res
            a = torch.randn((1024, 1024), device=d, dtype=dtype)
            b = torch.randn((1024, 1024), device=d, dtype=dtype)
            # run and time; DirectML may not expose a synchronize API similar to CUDA
            t0 = time.time()
            c = torch.matmul(a, b)
            # best-effort wait briefly to let compute dispatch
            time.sleep(0.05)
            t1 = time.time()
        else:
            # device may be 'cpu', 'mps' or 'cuda:0'
            a = torch.randn((1024, 1024), device=device, dtype=dtype)
            b = torch.randn((1024, 1024), device=device, dtype=dtype)
            if isinstance(device, str) and device.startswith("cuda"):
                torch.cuda.synchronize()
            t0 = time.time()
            c = torch.matmul(a, b)
            if isinstance(device, str) and device.startswith("cuda"):
                torch.cuda.synchronize()
            t1 = time.time()

        res["time_s"] = t1 - t0
        res["ok"] = True
    except Exception as e:
        res["error"] = str(e)
    return res


# device priority for quick benchmark
devices = []
if info.get("cuda_available"):
    devices.append("cuda:0")
if info.get("mps_available"):
    devices.append("mps")
if info.get("directml_possible"):
    devices.append("dml")
# always include cpu
devices.append("cpu")

for d in devices:
    bench = try_benchmark(d)
    info["quick_benchmark"][d] = bench
    if bench.get("ok"):
        # stop after first working device benchmark
        break

print(json.dumps(info, indent=2))
try:
    with open("gpu_check.json", "w", encoding="utf-8") as f:
        json.dump(info, f, indent=2)
except Exception:
    pass
