# ROCm on Linux (AMD GPU acceleration)

STEMwerk can use an AMD GPU on Linux **only if** your system has a working ROCm stack and you are using a **ROCm-enabled PyTorch** build.

## 1) Quick check (recommended)

Run this inside the same venv REAPER uses (or your project venv):

```bash
python tools/gpu_check.py
```

What you want to see in the JSON:

- `rocm_detected: true`
- `torch_hip` is **not** `null`
- `cuda_available: true`
- `cuda_devices` contains your AMD GPU name(s)

## 2) If ROCm is not detected

ROCm requires:

- A **ROCm-supported AMD GPU** (not all GPUs are supported on all ROCm versions)
- Kernel + driver stack compatible with the ROCm version you install
- ROCm userspace installed so `rocminfo` works

After installing ROCm, re-run `python tools/gpu_check.py`.

## 3) Install ROCm-enabled PyTorch

On ROCm setups, PyTorch usually exposes AMD GPUs via `torch.cuda` (and sets `torch.version.hip`).
Once PyTorch is installed correctly, STEMwerk will automatically show usable GPU devices in the **device** list.

## 4) Verify in STEMwerk

- Re-run the STEMwerk script in REAPER
- Under **device**, you should see GPU devices (e.g. `cuda:0`) instead of only Auto/CPU

If you still only see Auto/CPU, open the latest `separation_log.txt` in the temp output folder; it will show why the backend was not configured.


