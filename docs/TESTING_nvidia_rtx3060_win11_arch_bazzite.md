## STEMwerk testing — NVIDIA RTX 3060 laptop (Win11 + Arch + Bazzite)

This guide is optimized for **stability first** and quick diagnosis.

### Common “pass criteria” (all OS)
- `tools/gpu_check.py` shows the expected device backend (CUDA on NVIDIA)
- In REAPER runs, the newest `separation_log.txt` shows:
  - `sys_executable: ...` points at the Python you set up
  - `Selected device: cuda:0 (NVIDIA GeForce RTX 3060 ...)`

### Windows 11 (CUDA)
#### 1) Prereqs
- NVIDIA driver installed (Studio or Game Ready)

#### 2) Repo + venv + deps
```powershell
git clone https://github.com/flarkflarkflark/STEMwerk
cd STEMwerk
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -U pip
.\.venv\Scripts\python.exe -m pip install -r requirements-ci.txt
```

Install a CUDA-enabled PyTorch build (pick one that matches your driver; if unsure, start with the latest stable on the PyTorch site):
```powershell
.\.venv\Scripts\python.exe -m pip install torch torchvision torchaudio
```

Verify:
```powershell
.\.venv\Scripts\python.exe tools\gpu_check.py
```

#### 3) REAPER scripts
- Copy `scripts/reaper/` into REAPER’s Scripts folder, or use your preferred sync method.
- In REAPER: run `STEMwerk_Enable_Debug.lua`, then `STEMwerk.lua`.

### Arch Linux (CUDA)
#### 1) Prereqs
- Install NVIDIA driver + userspace, reboot
- Verify `nvidia-smi` works

#### 2) Repo + venv + deps
```bash
git clone https://github.com/flarkflarkflark/STEMwerk
cd STEMwerk
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-ci.txt
python tools/gpu_check.py
```

#### 3) REAPER scripts
```bash
bash scripts/reaper/sync_to_reaper.sh
```

### Bazzite (immutable, CUDA) — recommended: toolbox
#### 1) Prereqs
- Verify NVIDIA is working on the host: `nvidia-smi`

#### 2) Use toolbox for Python deps
```bash
toolbox create -c stemwerk
toolbox enter stemwerk
sudo dnf install -y git python3 python3-pip python3-virtualenv
git clone https://github.com/flarkflarkflark/STEMwerk
cd STEMwerk
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-ci.txt
python tools/gpu_check.py
```

Then install/sync REAPER scripts as normal in `~/.config/REAPER/...` on the host.


