<p align="center">
	<img src="docs/assets/stemwerk-dynamic.svg" alt="STEMwerk-reaper" title="STEMwerk-reaper" width="720" />
</p>

Demucs stem separation directly inside REAPER, no round-tripping (open source, ReaPack) 
Split vocals, drums, bass, and more directly inside your DAW with GPU acceleration where available.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend (audio-separator/Demucs) and keeps processing on your machine.

![STEMwerk in action](docs/assets/stemwerk_fullscreen.gif)

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

## Requirements
- 64-bit REAPER
- 64-bit Windows, macOS, or Linux
- Internet access for first-time setup and first model download
- Enough free disk space for the runtime, package cache, temporary files, and model cache

Recommended free space:
- Windows thin installer: at least 4-8 GB free during first setup
- Windows bundled installer: fewer first-time downloads, but similar runtime/model space is still needed
- Additional space is needed for downloaded models and separated stem files

## What The Installer Does
STEMwerk uses a Python runtime for separation. On first setup it may:

- create a dedicated Python virtual environment
- install backend/runtime packages
- verify FFmpeg
- download the selected model on first use

On Windows, the installer handles the runtime/bootstrap work outside REAPER.
On macOS and Linux, `STEMwerk-SETUP.lua` is the normal REAPER-side setup and repair entry point.

## Internet And Offline Use
Internet is normally required for:

- first-time runtime setup
- backend package installation
- first-time model download

After setup is complete and the model is cached locally, normal separation usually works offline.

For releasing pre-zipped offline model packs (`Fast`, `Quality`, `6-Stem`, `All`), see `docs/OFFLINE_MODEL_PACKS.md`.

## Backend Support
### CPU
- Windows: supported
- macOS: supported
- Linux: supported

### Windows GPU
- NVIDIA: CUDA when compatible PyTorch/CUDA packages install successfully
- AMD / Intel GPU: DirectML route (`torch-directml` + `onnxruntime-directml`)

### Linux GPU
- NVIDIA: CUDA when compatible drivers and PyTorch packages are available
- AMD: ROCm only on supported hardware/driver combinations
- Not all AMD GPUs that work on Windows DirectML are supported on Linux ROCm

### Apple Silicon
- CPU is supported
- Platform-specific acceleration should be treated as best-effort unless explicitly documented otherwise

## Download Expectations
Installer/runtime size and model size are separate.

Windows installers:
- `STEMwerk-Setup-<version>.exe`: thin installer
- `STEMwerk-Setup-<version>-bundled.exe`: bundled Python + FFmpeg installer
- `STEMwerk-<version>-offline-patch.exe`: small patch installer for existing offline installs

Approximate first-use model downloads:
- `Fast` (`htdemucs`): about 84 MB
- `Quality` (`htdemucs_ft`): about 337 MB
- `6-Stem` (`htdemucs_6s`): about 55 MB

These model downloads are the same for CPU and GPU. Only the runtime/backend packages differ.

Note: the 6-stem model is not necessarily larger than the 4-stem models. Model size depends on the checkpoint set used by the model, not just the number of output stems.

## Windows Notes
- The installer is the recommended setup path on Windows.
- ReaPack is not recommended for first-time Windows setup because it installs scripts only, not the full runtime.
- During first-time setup, the installer may appear to pause for several minutes while Python packages are resolved and installed. This is most noticeable during the `audio-separator` step and can take longer on slower systems or virtual machines.
- Windows setup now verifies ONNX Runtime automatically and installs the required backend package when needed.
- For a normal Windows first run, the installer is the canonical setup path. `STEMwerk-SETUP.lua` is a REAPER-side verify/repair path, not a replacement for the installer bootstrap.

## Installation

### Recommended (Installer)
1. Download the latest installer for your platform (Windows/macOS/Linux).
2. Run the installer.
3. Open REAPER.
4. If the scripts are not visible yet in the Action List, use Actions -> ReaScript -> Load ReaScript... and load `STEMwerk-SETUP.lua`, `STEMwerk.lua`, or `STEMwerk_Setup_Toolbar.lua` from `REAPER/Scripts/STEMwerk-reaper/`.
5. On macOS and Linux, run `STEMwerk-SETUP.lua` first.
6. Then run `STEMwerk.lua` (shown in REAPER as `Stemwerk: Main`).

On Windows, the installer handles the runtime/bootstrap work outside REAPER.
On macOS and Linux, `STEMwerk-SETUP.lua` is the normal REAPER-side bootstrap and repair entry point.

On Windows, `STEMwerk-SETUP.lua` does not replace the installer bootstrap. If the runtime is incomplete, re-run the Windows installer first.

### Manual / Developer (Advanced)
1. Install a 64-bit Python 3.x and ensure it is on your PATH.
2. Clone or download this repository.
3. In REAPER: Actions -> Show action list -> ReaScript: Load ReaScript...
4. Load and run `scripts/reaper/STEMwerk-SETUP.lua` for guided setup.
5. Then run `scripts/reaper/STEMwerk.lua`.

If REAPER cannot find your Python, the setup script lets you point to a specific interpreter.

### ReaPack (Linux and macOS only)
Import this repository URL into ReaPack:

```text
https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/index.xml
```

Example workflow:
1. Extensions -> ReaPack -> Import a repository.
2. Paste the URL above.
3. ReaPack -> Synchronize packages.
4. Search for "STEMwerk" and install.
5. In the REAPER Action List, run `STEMwerk-SETUP.lua`, then `STEMwerk.lua`.

> **WARNING (Windows)**: ReaPack is not recommended. On Windows, full setup is intentionally handled by the installer; the REAPER setup does not launch bootstrap installers. ReaPack installs only the scripts, so Python/FFmpeg/venv are often missing or resolve to unsupported Windows shim paths. Use the installer (recommended) or the manual developer install instead.

- ReaPack installs STEMwerk under `REAPER/Scripts/STEMwerk-reaper/`, the same folder layout used by the installers.
- Older ReaPack layouts are still accepted by the runtime scripts as a fallback, so existing installs keep working.
- After installing or updating via ReaPack, run `STEMwerk-SETUP.lua` once.

### REAPER Action List: which scripts to use
To avoid confusion, only these are meant for normal use:
- `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) — use this for manual installs, ReaPack installs, and the normal bootstrap/repair flow on macOS/Linux.
- `Stemwerk: Main` (`STEMwerk.lua`) — the main UI.
- `Stemwerk: Karaoke`, `Stemwerk: Vocals Only`, `Stemwerk: Drums Only`, `Stemwerk: Bass Only`, `Stemwerk: All Stems` — optional presets.

Internal/troubleshooting (not for regular use):
- everything under `scripts/reaper/_internal/` — runtime helpers used by the public scripts

Note: REAPER does not auto-register scripts in the Action List. Use Actions → ReaScript → Load ReaScript… or run `STEMwerk_Setup_Toolbar.lua` to register the standard actions.

## REAPER workflows
- New tracks: Create dedicated stem tracks, optionally grouped in a folder
- In-place: Replace the source item with stems as takes
- Time selection: Process only the selected region, even without a selected item
- Per-item: Multi-item tracks can be processed item-by-item for cleaner naming
- Quick presets: Optional toolbar scripts for one-click workflows

## GUI highlights
- Main dialog: stem toggles, presets, in-place vs new tracks, model choice, and device selector.
- Progress window: per-job status, realtime stages/ETA, sequential/parallel indicator with fallback reason.
- Visuals: optional procedural art gallery and audio-reactive visuals (toggleable).
- Shortcuts: quick stem toggles (1-4), presets (K/I/D), Enter to start, Esc to cancel.
- Language support: provisional three-language UI (EN/NL/DE).
- Theme: day/night mode (light/dark) with persistent settings.

## Parallel vs Sequential (Multi-track)
STEMwerk can run multi-track jobs in parallel when Parallel is enabled and more than one job is queued. It will automatically fall back to Sequential in two cases:
- Per-item time selection jobs (for correctness and isolation).
- Explicit `DirectML` multi-job runs on Windows (current stability safeguard).
- Device = Auto with no GPU backends detected (CPU-only is faster and safer).

Examples where pure parallel does happen:
- You select 3 tracks with items, no time selection, Parallel on, device = `cuda:0`. -> 3 jobs at once (per track).
- You select 5 tracks, Parallel on, device = `auto`, and a GPU is detected. -> 5 jobs at once.
- You select multiple items across multiple tracks (no time selection), Parallel on, device = `cuda`. -> per-track jobs in parallel.

Examples where it does not run in parallel:
- Time selection with multiple items on one track -> per-item jobs -> sequential forced ("Per-item multi-track isolation").
- Explicit `DirectML` with multiple queued jobs -> sequential forced ("DirectML multi-track stability mode").
- Parallel on, device = `auto`, but no GPU backend -> sequential forced ("Auto device (no GPU)").
- Only 1 job (1 track) -> sequential by definition.

The progress window shows the active mode and the reason when a fallback happens.

## Relationship to STEMwerk-core
STEMwerk-reaper bundles the same separation pipeline used by STEMwerk-core via `scripts/reaper/audio_separator_process.py` and the `tools/` utilities. The REAPER layer handles DAW integration, UI, and item or track management, while the core handles model execution and device selection.

See `docs/ROCm.md` for Linux AMD guidance.

## Development / advanced setup
- Python tooling lives in `tools/` and `scripts/reaper/audio_separator_process.py`
- Helpers include `tools/gpu_check.py`, `tools/warmup.py`, and `tools/stress_bench.py`
- Requirements are listed in `requirements-ci.txt` and `requirements-gui.txt`
- Tests and fixtures live under `tests/`

## Versioning
Single source of truth: `VERSION`.
Before tagging/releases:
1. Update `VERSION`
2. Run `python tools/version_sync.py --write`
3. Commit the changes
4. Tag `vX.Y.Z` to match `VERSION`

## Credits
3D artwork collection inspired by / derived from Milkdrop presets.

## License / author
MIT License.
Author: flarkAUDIO (flarkaudio@pm.me)
