<p align="center">
	<img src="docs/assets/STEMwerk.gif" alt="STEMwerk-reaper" title="STEMwerk-reaper" width="720" />
</p>

Local-first stem separation inside REAPER (open source, ReaPack).<br>
Split vocals, drums, bass, and more directly in your DAW for practical production, editing, remix, and karaoke workflows.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend (audio-separator/Demucs) and keeps processing on your machine.

### Stable release note
This README describes the public stable release behavior. Ongoing refactor and UI polish work happens on separate development branches and may not be in the latest stable release yet.

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
- 64-bit Windows, Linux, or macOS
- Internet access for first-time setup and first model download
- Enough free disk space for the runtime, package cache, temporary files, and model cache

Recommended free space:
- Windows thin installer: at least 4-8 GB free during first setup
- Windows bundled installer: fewer first-time downloads, but similar runtime/model space is still needed
- Additional space is needed for downloaded models and separated stem files

## What the installer does
STEMwerk uses a Python runtime for separation. On first setup it may:

- create a dedicated Python virtual environment
- install backend/runtime packages
- verify FFmpeg
- download the selected model on first use

On Windows, the installer handles the runtime/bootstrap work outside REAPER.
On macOS and Linux, `STEMwerk-SETUP.lua` is the normal REAPER-side setup and repair entry point.

## Internet And Offline Use
For most users, internet is needed on first install for:

- runtime/bootstrap setup
- backend package installation
- first model download

After runtime setup is complete and your model is cached, normal separation is typically offline.

Windows release assets may also include bundled or offline-oriented installers for specific stable versions. Those reduce or remove first-run downloads, but you should still run `STEMwerk-SETUP.lua` when asked to verify/repair the runtime inside REAPER.

## Backend Support
Windows and Linux are the primary day-to-day validated environments. macOS is supported, but backend parity can vary by system and Python/backend package availability.

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
Use this quick guide:

- Fresh Windows install: use the current Windows installer release asset.
- Existing Windows bundled/offline install (including 2.2.1.4-era installs): use the matching offline patch/update installer when available for that release line.
- Linux/macOS stable users: use ReaPack or manual script install, then run `STEMwerk-SETUP.lua`.

Windows installer asset types you may see:
- `STEMwerk-Setup-<version>.exe`: thin/online installer
- `STEMwerk-Setup-<version>-bundled.exe`: bundled Python + FFmpeg installer
- `STEMwerk-<version>-offline-patch.exe`: patch installer for existing offline/bundled installs

Approximate first-use model downloads (when not already bundled/cached):
- `Fast` (`htdemucs`): about 84 MB
- `Quality` (`htdemucs_ft`): about 337 MB
- `6-Stem` (`htdemucs_6s`): about 55 MB

Model size is separate from runtime/bootstrap size, and model download size is not a direct indicator of how many stems a model outputs.

## Windows Notes
- The installer is the recommended setup path on Windows.
- ReaPack is not recommended for first-time Windows setup because it installs scripts only, not the full runtime.
- During first-time setup, installer steps can appear paused for several minutes while Python/backend packages are resolved.
- For stable releases around `2.2.1.4` and newer hotfixes, offline/bundled users may also get a small offline patch installer path.
- `STEMwerk-SETUP.lua` is a REAPER-side verify/repair tool. It does not replace the Windows installer bootstrap path.

### Updating from older Windows offline installs (2.2.1.4+)
- If you already use an older bundled/offline Windows install, prefer the matching `*-offline-patch.exe` for that same release line when available.
- If no matching patch asset exists, use the current full Windows installer for your target version.
- Quick release links: [v2.2.1.4](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.2.1.4), [v2.2.1.5](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.2.1.5), [current stable](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/latest).
- After any installer update, run `STEMwerk-SETUP.lua` once to verify paths/runtime state.
- If setup still reports missing runtime/bootstrap pieces, rerun the installer first, then rerun `STEMwerk-SETUP.lua`.

## Installation

### Recommended (Stable users)
1. Windows: use the current Windows installer release asset (`.exe`).
2. Linux/macOS: install via ReaPack (or manual install), then run `STEMwerk-SETUP.lua`.
3. Open REAPER and ensure `STEMwerk-SETUP.lua` and `STEMwerk.lua` are present in the Action List.
4. Run `STEMwerk-SETUP.lua` first when prompted (or after updates/repairs), then run `STEMwerk.lua`.

Notes:
- Windows installer flow is the canonical bootstrap path for stable Windows use.
- On Linux/macOS, `STEMwerk-SETUP.lua` is the normal in-REAPER setup/repair entry point.
- On Windows, if runtime/bootstrap is incomplete, rerun the installer first, then verify with `STEMwerk-SETUP.lua`.

### Manual / Developer (Advanced)
1. Install a supported 64-bit Python 3 version and ensure it is on your PATH.
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
- `STEMwerk: Main` (`STEMwerk.lua`) — the main UI.
- `STEMwerk: Karaoke`, `STEMwerk: Vocals Only`, `STEMwerk: Drums Only`, `STEMwerk: Bass Only`, `STEMwerk: All Stems` — optional presets.

Internal/troubleshooting (not for regular use):
- everything under `scripts/reaper/_internal/` — runtime helpers used by the public scripts

Note: REAPER does not auto-register scripts in the Action List. Use Actions → ReaScript → Load ReaScript… or run `STEMwerk_Setup_Toolbar.lua` to register the standard actions.

## First-run expectations
- First run can take a while: STEMwerk may need to create or verify its runtime, install backend packages, and download the selected model.
- Setup time depends on OS, backend path (CPU/GPU), internet speed, and package resolver speed.
- This is expected behavior for a first install or major update, not a normal "per-track" processing delay.

## Troubleshooting setup/runtime
- If setup fails or runtime looks incomplete, run `STEMwerk-SETUP.lua` to verify/repair the install.
- Check the STEMwerk logs shown by setup/runtime diagnostics to identify the failing step (Python, FFmpeg, backend package, model download, permissions, etc.).
- Backend behavior differs by system and drivers: CPU is the safest fallback, while CUDA/DirectML/ROCm availability depends on hardware and compatible packages.
- On Windows, if bootstrap/runtime files are missing, re-run the installer first, then verify with `STEMwerk-SETUP.lua`.

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
Parallel mode is used when `Parallel` is enabled. Sequential mode is used when `Parallel` is disabled.

When `Parallel` is enabled and multiple jobs are queued, STEMwerk still forces Sequential in these cases:
- Explicit `DirectML` device selection on multi-job runs (Windows stability safeguard).
- `device = auto` with no detected GPU backend (`Auto device, no GPU`).

If those safeguards do not apply, both per-track and per-item multi-job queues can run in parallel.

Examples where parallel runs:
- 3 tracks queued, `Parallel` on, device = `cuda:0` -> jobs run in parallel.
- Multiple selected items across tracks, no time selection, `Parallel` on, device = `cuda` -> per-item jobs run in parallel.
- `device = auto` with a detected GPU backend and multiple queued jobs -> parallel.

Examples where sequential is used:
- `Parallel` is switched off by the user.
- Explicit `DirectML` with multiple queued jobs -> sequential (`DirectML multi-track stability mode`).
- `Parallel` on + `device = auto` with no detected GPU backend -> sequential (`Auto device, no GPU`).

The progress window shows the active mode and, when applicable, the forced-sequential reason.

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
