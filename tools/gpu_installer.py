#!/usr/bin/env python3
"""
Cross-platform GPU installer helper.
Runs `tools/gpu_check.py`, reads `gpu_check.json`, then suggests (and can install) appropriate PyTorch/torch-* packages.

Usage: python tools/gpu_installer.py
"""
import json
import os
import subprocess
import sys
import shlex

CHECK_FILE = "gpu_check.json"


def run_check():
    # run gpu_check.py to refresh output
    print("Running gpu check...")
    cmd = [sys.executable, os.path.join(os.path.dirname(__file__), "gpu_check.py")]
    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError:
        print("gpu_check.py failed; proceeding with any existing gpu_check.json if present")


def load_check():
    if not os.path.exists(CHECK_FILE):
        return None
    try:
        with open(CHECK_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print("Failed to read", CHECK_FILE, e)
        return None


def prompt_yes_no(question, default=False):
    yes = {"y", "yes"}
    no = {"n", "no"}
    if default:
        q = f"{question} [Y/n]: "
    else:
        q = f"{question} [y/N]: "
    while True:
        try:
            r = input(q).strip().lower()
        except EOFError:
            return default
        if r == "":
            return default
        if r in yes:
            return True
        if r in no:
            return False


def run_pip_install(package):
    cmd = [sys.executable, "-m", "pip", "install", package]
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    return subprocess.call(cmd) == 0


def recommend_and_install(info):
    platform = info.get("platform", sys.platform)
    torch_version = info.get("torch")
    cuda = info.get("cuda_available")
    nvidia = bool(info.get("nvidia_smi"))
    rocm = bool(info.get("rocm_detected"))
    mps = bool(info.get("mps_available"))
    directml = bool(info.get("directml_possible"))
    amd_gpus = info.get("amd_gpus") or []

    print("\nDetected summary:")
    print(json.dumps({"platform": platform, "torch": torch_version, "cuda": cuda, "nvidia": nvidia, "rocm": rocm, "mps": mps, "directml": directml, "amd_gpus": bool(amd_gpus)}, indent=2))

    if platform.lower().startswith("win"):
        # Windows: NVIDIA -> suggest CUDA-enabled torch on test machine; AMD -> torch-directml
        if nvidia:
            print("\nNVIDIA GPU detected on Windows.")
            print("Recommendation: install a CUDA-enabled PyTorch wheel matching your CUDA driver. Example command (adjust CUDA tag as needed):")
            print("  python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118")
            if prompt_yes_no("Attempt to install the CPU wheel of torch (safe fallback)?"):
                run_pip_install("torch")
        else:
            print("\nNo NVIDIA GPU detected. For AMD GPUs on Windows the recommended route is torch-directml.")
            print("You can install it with:")
            print("  python -m pip install torch-directml")
            if prompt_yes_no("Attempt to install torch-directml now?"):
                ok = run_pip_install("torch-directml")
                print("torch-directml install", "succeeded" if ok else "failed")
            else:
                print("Skipping torch-directml installation.")
    elif platform.lower().startswith("linux"):
        # Linux: ROCm or NVIDIA
        if rocm:
            print("\nROCm detected — recommend installing PyTorch built for ROCm.")
            print("See https://pytorch.org/get-started/locally/ for ROCm-specific wheels.")
            if prompt_yes_no("Open PyTorch local installation page in default browser?"):
                try:
                    import webbrowser
                    webbrowser.open("https://pytorch.org/get-started/locally/")
                except Exception:
                    pass
        elif nvidia:
            print("\nNVIDIA GPU detected on Linux — install CUDA-enabled PyTorch matching your driver/CUDA runtime.")
            print("See https://pytorch.org/get-started/locally/ for the correct wheel and command.")
            if prompt_yes_no("Open PyTorch local installation page in default browser?"):
                try:
                    import webbrowser
                    webbrowser.open("https://pytorch.org/get-started/locally/")
                except Exception:
                    pass
        elif amd_gpus:
            print("\nAMD GPU detected on Linux, but ROCm was not detected.")
            print("To get AMD GPU acceleration you generally need:")
            print("  1) A ROCm-supported AMD GPU + kernel/driver stack")
            print("  2) ROCm userspace installed (so `rocminfo` works)")
            print("  3) A ROCm-enabled PyTorch build (torch.version.hip != None and torch.cuda.is_available() == True)")
            print("\nOnce ROCm + ROCm PyTorch are installed, re-run this tool and STEMwerk should expose GPU devices automatically.")
        else:
            print("\nNo ROCm or NVIDIA detected. You can continue with CPU-only PyTorch (already installed in many venvs).")
            if prompt_yes_no("Install CPU-only torch now?"):
                run_pip_install("torch")
    elif platform.lower().startswith("darwin") or platform.lower().startswith("mac"):
        print("\nmacOS detected — recommend installing PyTorch with MPS support per PyTorch instructions.")
        print("See https://pytorch.org/get-started/locally/ for macOS wheels.")
        if prompt_yes_no("Open PyTorch local installation page in default browser?"):
            try:
                import webbrowser
                webbrowser.open("https://pytorch.org/get-started/locally/")
            except Exception:
                pass
    else:
        print("\nUnknown platform — default to CPU-only instructions.")
        if prompt_yes_no("Install CPU-only torch now?"):
            run_pip_install("torch")


def main():
    run_check()
    info = load_check()
    if not info:
        print("No gpu_check.json found; aborting.")
        return 1
    recommend_and_install(info)
    return 0


if __name__ == '__main__':
    sys.exit(main())
