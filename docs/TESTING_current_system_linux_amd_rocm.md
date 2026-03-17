## STEMwerk testing (current system) — Linux + AMD (ROCm)

This guide is optimized for **stability first** on your current Linux machine with AMD GPUs (ROCm).

### 1) Prereqs
- **REAPER** installed
- Recommended: **js_ReaScriptAPI** (for best window behavior)
- Python available (system Python is fine)

### 2) Python environment (the one REAPER will use)
From repo root:

```bash
cd /home/flark/GIT/STEMwerk
rm -rf .venv
python -m venv --system-site-packages .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-ci.txt
```

Verify ROCm is actually visible in this env:

```bash
/home/flark/GIT/STEMwerk/.venv/bin/python tools/gpu_check.py
```

Success criteria:
- `rocm_detected: true`
- `torch_hip` is not null
- `cuda_available: true`
- `cuda_devices` lists your AMD GPU(s)

### 3) Install/update the REAPER scripts
If your repo is the source of truth:

```bash
bash scripts/reaper/sync_to_reaper.sh
```

### 4) Test flow in REAPER
- Run `STEMwerk_Enable_Debug.lua`
- Run `STEMwerk.lua`
- Pick **Device = Auto**, run a short separation (30–60s)
- Repeat for **Device = CPU** and **Device = cuda:1** (if offered)

Verify per-run device selection in the newest `separation_log.txt`:
- `Selected device: ...`
- `Using GPU: ...` (for GPU runs)

If anything is weird, grab `/tmp/STEMwerk_debug.log` + the newest `separation_log.txt`.


