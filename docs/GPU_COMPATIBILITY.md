# GPU compatibility overview (STEMwerk)

This is a practical "in principle" overview by OS and backend. Exact support
depends on driver versions and the vendor support matrices.

Legend:
- CUDA = NVIDIA GPU backend
- DirectML = Windows GPU backend for AMD/Intel
- ROCm = Linux GPU backend for AMD
- MPS = Apple Silicon GPU backend (Metal)

| OS | Backend | "In principle" GPU families | Requirements | Notes |
| --- | --- | --- | --- | --- |
| Windows | CUDA | NVIDIA GTX 900/10/16, RTX 20/30/40 | Recent NVIDIA driver + CUDA 12.1 compatible PyTorch | NVIDIA-only |
| Windows | DirectML | AMD RX 5000/6000/7000, Intel Arc/Iris Xe | DX12-capable GPU + up-to-date driver (WDDM 2.9+) | AMD/Intel route |
| Windows | CPU | Any | None | Always available |
| Linux | CUDA | NVIDIA GTX 900/10/16, RTX 20/30/40 | Recent NVIDIA driver + CUDA 12.1 compatible PyTorch | NVIDIA-only |
| Linux | ROCm | AMD RDNA2/RDNA3, Instinct MI-series | ROCm-supported GPU + ROCm stack | Check AMD ROCm matrix |
| Linux | CPU | Any | None | Always available |
| macOS | MPS | Apple Silicon (M1/M2/M3) | macOS 12+ | Intel Macs use CPU |
| macOS | CPU | Any | None | Always available |

Quick checks (in the same venv that REAPER/STEMwerk uses):
- `python tools/gpu_check.py`
- `python scripts/reaper/audio_separator_process.py --list-devices`

Notes:
- Windows AMD/Intel uses DirectML (not ROCm).
- Linux AMD requires ROCm-supported hardware; not all AMD GPUs are supported.
- If unsure, the CPU installer always works.
