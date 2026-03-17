## STEMwerk testing — MacBookPro 11,2 (Ventura via OCLP + Arch)

This guide is optimized for **stability first**.

### Expectations (important)
- On **Intel Macs**, GPU acceleration via **MPS** is typically **not available** (MPS is primarily Apple Silicon).
- So the realistic target is: **CPU mode works reliably** and produces correct stems.

### Ventura (OCLP)
#### 1) Repo + venv + deps
```bash
git clone https://github.com/flarkflarkflark/STEMwerk
cd STEMwerk
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-ci.txt
python tools/gpu_check.py
```

Expected in `gpu_check.py`:
- `mps_available: false` (on Intel)

#### 2) Install scripts into REAPER
- Copy/sync `scripts/reaper/` into REAPER’s Scripts folder for macOS.

#### 3) Test flow in REAPER
- Run `STEMwerk_Enable_Debug.lua`
- Run `STEMwerk.lua`
- Pick **Device = CPU** (or Auto if only CPU exists)
- Run a 30–60s separation
- Verify the newest `separation_log.txt` includes:
  - `Selected device: cpu`
  - and stems were written

### Arch Linux on the same Mac
Same as the Linux flow:
```bash
git clone https://github.com/flarkflarkflark/STEMwerk
cd STEMwerk
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements-ci.txt
python tools/gpu_check.py
```

Then sync scripts into `~/.config/REAPER/...` and run the same REAPER test.


