# STEMwerk-reaper

Local-first AI stem separation for REAPER. Split vocals, drums, bass, and more directly inside your DAW with GPU acceleration where available.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend (audio-separator/Demucs) and keeps processing on your machine.

## Features
- Stem separation for vocals, drums, bass, other (plus optional guitar/piano with 6-stem models)
- Time selection and per-item workflows for multi-item tracks
- New-tracks or in-place replacement as takes
- Presets for quick workflows (Karaoke, Instrumental, Drums Only, etc.)
- Batch and multi-track processing queue
- Device selection with CPU and GPU fallback
- Local-first processing with transparent logs

## Who is this for?
- Producers and remixers who need quick stems without leaving REAPER
- Editors and podcasters cleaning dialog or music beds
- Sound designers and educators building isolated parts
- Anyone who wants a fast, offline stem workflow

## Quick installation
1. Install a 64-bit Python 3.x and ensure it is on your PATH.
2. Clone or download this repository.
3. In REAPER: Actions -> Show action list -> ReaScript: Load ReaScript...
4. Load and run `scripts/reaper/STEMwerk-SETUP.lua` for guided setup.
5. Then run `scripts/reaper/STEMwerk.lua`.

If REAPER cannot find your Python, the setup script lets you point to a specific interpreter.

## Install via ReaPack
Import this repository URL into ReaPack:
https://github.com/flarkflarkflark/STEMwerk-reaper/raw/main/index.xml

## REAPER workflows
- New tracks: Create dedicated stem tracks, optionally grouped in a folder
- In-place: Replace the source item with stems as takes
- Time selection: Process only the selected region, even without a selected item
- Per-item: Multi-item tracks can be processed item-by-item for cleaner naming
- Quick presets: Optional toolbar scripts for one-click workflows

## Relationship to STEMwerk-core
STEMwerk-reaper bundles the same separation pipeline used by STEMwerk-core via `scripts/reaper/audio_separator_process.py` and the `tools/` utilities. The REAPER layer handles DAW integration, UI, and item or track management, while the core handles model execution and device selection.

## Platform / GPU support
- Windows, macOS, Linux with CPU fallback on all platforms
- NVIDIA CUDA on Windows and Linux when CUDA-enabled PyTorch is installed
- AMD ROCm on Linux with a working ROCm stack
- AMD DirectML on Windows with torch-directml and onnxruntime-directml

See `docs/ROCm.md` for Linux AMD guidance.

## Development / advanced setup
- Python tooling lives in `tools/` and `scripts/reaper/audio_separator_process.py`
- Helpers include `tools/gpu_check.py`, `tools/warmup.py`, and `tools/stress_bench.py`
- Requirements are listed in `requirements-ci.txt` and `requirements-gui.txt`
- Tests and fixtures live under `tests/`

## Roadmap
- Installer builds for Windows, macOS, and Linux
- UI scaling and i18n polish for long translations
- Improved device detection and guidance

## License / author
MIT License.
Author: flarkAUDIO (flarkaudio@pm.me)
