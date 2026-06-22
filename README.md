<p>
  <img src="https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/installer/assets/stemwerk.png" alt="STEMwerk" width="64">
</p>

Local-first stem separation inside REAPER (open source, ReaPack).<br>
Split vocals, drums, bass, and more directly in your DAW for practical production, editing, remix, and karaoke workflows.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend (audio-separator/Demucs) and keeps processing on your machine.

### Release status note
This README still points to the current public stable release, `v2.2.2.2`, for end-user download links.

For the current `2.3.0.0` release candidate:

- final code basis: `95013e6d8e9e3bf6cda0456264612153678ed1c0`
- the final Windows readiness follow-up in that commit restores normal Windows CPU multi-item `cap2` scheduling and persists DrumSep ready-state markers to the dedicated runtime state files
- `ready_to_go` reporting no longer remains `missing` after a successful DrumSep verify on the current Windows 2.3 candidate line
- Linux and Windows artifacts built from `21a59cd64686b6cc8c6feca62ac863d8a9e13b6a`, `e06507c99e6e336cbbf36892a39c97876d10daa0`, or `328c614c8adcdc8244c8bb9bf601083907f29032` are stale and superseded by artifacts rebuilt from `95013e6d8e9e3bf6cda0456264612153678ed1c0` or later
- see [docs/RELEASE_2.3.0.0.md](docs/RELEASE_2.3.0.0.md) for the 2.3 release-line notes

`v2.2.2.2` is a reliability and packaging parity release on top of the `2.2.2.x` UI/workflow line.

<img src="https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/v2.2.2.2/STEMwerk-v2.2.2.2-REAPER-Native-UI-cropped-720.png" alt="STEMwerk v2.2.2.2 REAPER-Native UI" width="720">

#### What's new in v2.2.2.2
`v2.2.2.2` is a reliability, setup, packaging, and supportability release.

- Adds a cleaner REAPER-Native UI mode alongside the existing flarkAUDIO Visual mode
- Improves Windows setup/status/repair flow inside REAPER (`Check only`, `Repair`, `Rebuild venv`)
- Support bundles now produce a folder plus a ready-to-upload `.zip`
- Support bundles include `support_bundle_timings.txt` and `processing_summary.txt`
- Windows support-bundle collection is faster and bounded; macOS busy-window repaint is polished
- Restores offline `samplerate==0.1.0` payloads and keeps bundled `julius` fallback/repair path
- Polishes installer icon/header/status rendering behavior
- Removes obsolete `themes/` payload from release packaging
- Includes toolbar setup script and toolbar icon assets in release payloads
- Improves Linux package icon metadata
- Apple Silicon MPS remains experimental/R&D; this release does not claim production MPS acceleration

Current stable release: [STEMwerk v2.2.2.2](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.2.2.2).

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
- Internet access is recommended for first-time setup, runtime/package installation, and first model download
- Enough free disk space for the runtime, package cache, temporary files, and model cache

Recommended free space:
- Windows standard/online installer: at least 8 GB free recommended during first setup
- Windows NVIDIA CUDA or Linux ROCm setups may need more because torch/runtime packages can be large
- Windows bundled installer includes Python + FFmpeg, but it may still need backend package and model downloads
- Large offline allmodels installers need additional free space for the installer itself, extracted runtime/model assets, cache, and output stems
- Additional space is still needed for downloaded models and separated stem files

## What the installer does
STEMwerk uses a Python runtime for separation. On first setup it may:

- create a dedicated Python virtual environment
- install backend/runtime packages
- verify FFmpeg
- download the selected model on first use

On Windows, the installer handles the runtime/bootstrap work outside REAPER.
On macOS and Linux, `STEMwerk-SETUP.lua` is the normal REAPER-side setup and repair entry point. On supported Linux/macOS platforms it downloads a pinned STEMwerk-managed Python runtime on first setup instead of relying on system Python.

## Internet And Offline Use
For most users, internet is needed on first install for:

- runtime/bootstrap setup
- backend package installation
- first model download

After runtime setup is complete and your model is cached, normal separation is typically offline.

Windows release assets may also include offline installers, bundled installers, or larger offline/full asset variants for specific stable versions. In this terminology, the smaller offline installer path is still a downloader-style installer and can require internet for backend package or model downloads. Bundled installers include Python + FFmpeg, but they can still require backend package or model downloads on first use. Existing allmodels/Demucs core model-cache assets are not complete DrumSep/Drum Kit offline/full bundles. Drum Kit/DrumSep runtime and model assets in the 2.3 release line are handled through the setup/runtime flow unless a specific full/offline asset explicitly says otherwise. Large offline/full allmodels-style assets are hosted separately on Google Drive because they are too large for GitHub release assets.

For the unreleased `2.3.0.0` artifact set, do not treat any installer/package built from `21a59cd`, `e06507c`, or `328c614` as final; those artifacts are stale and superseded by `95013e6`.

You should still run `STEMwerk-SETUP.lua` when asked to verify or repair the runtime inside REAPER.

## Backend Support
Windows is the primary validated path for the `v2.2.2.2` release.

### CPU
- Windows: validated, including CPU/VM setups
- macOS Intel: validated
- Linux: supported

### Windows GPU
- NVIDIA: CUDA validated on `v2.2.2.2`
- AMD / Intel GPU: DirectML route (`torch-directml` + `onnxruntime-directml`), validated on Windows AMD

### Linux GPU
- NVIDIA: CUDA validated on RTX 3060 Laptop GPU when compatible drivers and PyTorch packages are available
- AMD: ROCm validated on RX 9070; ROCm remains dependent on supported hardware/driver combinations
- Not all AMD GPUs that work on Windows DirectML are supported on Linux ROCm

### Apple Silicon
- CPU is supported
- Apple Silicon MPS is detected for diagnostics only in this release path
- Demucs separation uses CPU fallback for reliability on Apple Silicon
- MPS acceleration remains experimental/R&D and is not a normal production route in `v2.2.2.2`

## Downloads

### Which installer should I use?
For most existing users with a working STEMwerk setup, ReaPack is the preferred update path for the REAPER scripts/actions on Windows, macOS and Linux.

- **New Windows users**: `STEMwerk-Setup-2.2.2.2.exe`
- **Windows users who want a bundled installer with Python + FFmpeg included**: `STEMwerk-Setup-2.2.2.2-bundled.exe`
- **Existing Windows users who do not use ReaPack or need the smaller offline installer/update path**: `STEMwerk-2.2.2.2-offline-patch.exe`
- **Windows users who need a complete offline/full asset with bundled core Demucs model-cache payloads**: use the Google Drive allmodels installers from the [v2.2.2.2 release page](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.2.2.2)
- **Linux users**: use ReaPack for scripts/actions, or use AppImage/`.deb`/`.rpm`/Arch packages for package-based installs
- **macOS users**: use ReaPack or the Linux/macOS script package, then run `STEMwerk: Setup` if the backend runtime needs checking/rebuilding

### GitHub release assets (v2.2.2.2)

| File | Description | Size |
|---|---|---:|
| `STEMwerk-Setup-2.2.2.2.exe` | Windows standard installer | 3.33 MB |
| `STEMwerk-Setup-2.2.2.2-bundled.exe` | Windows bundled installer (Python + FFmpeg included) | 133 MB |
| `STEMwerk-2.2.2.2-offline-patch.exe` | Windows smaller offline installer/update helper | 3.42 MB |
| `STEMwerk-2.2.2.2-x86_64.AppImage` | Linux portable build | 1.21 MB |
| `stemwerk_2.2.2.2_amd64.deb` | Debian/Ubuntu package | 0.93 MB |
| `stemwerk-2.2.2.2-1.noarch.rpm` | RPM package | 0.95 MB |
| `STEMwerk-v2.2.2.2-Linux-macOS-reaper-scripts-6c8d4db.zip` | Linux/macOS REAPER script package | 1.7 MB |

Linux packages were repacked after publish to remove non-runtime source toolbar PNGs and junk files from the package payload. Runtime files and toolbar assets are preserved; no runtime code changed.

GitHub also provides automatic source archives (`.zip` / `.tar.gz`) on the release page, but those are not the recommended end-user installer download.

### Large offline/full allmodels installers (Google Drive)
These Windows assets are the larger offline/full installer class: they bundle core Demucs model-cache assets plus related runtime payloads and are intended for no-internet install/use within that Demucs/core scope. They should not be described as complete DrumSep/Drum Kit offline/full installers. In the 2.3 release line, DrumSep runtime and model assets are still managed through setup/runtime routes unless a specific full/offline asset explicitly says otherwise. These larger installers are hosted on Google Drive because they are too large for GitHub release assets.

| File | Target | Size | Download |
|---|---|---:|---|
| `STEMwerk-Setup-2.2.2.2-offline-bundled-cpu-allmodels.exe` | Windows CPU | 871.3 MB | [Google Drive](https://drive.google.com/file/d/1jPN1-DSxjh-DOy_rBjV2MCCO_F1MM3-H/view?usp=drive_link) |
| `STEMwerk-Setup-2.2.2.2-offline-bundled-amd-gpu-allmodels.exe` | Windows AMD GPU / DirectML | 903.7 MB | [Google Drive](https://drive.google.com/file/d/1mR7CXJ8aY4uaezxfcm5Qa5CIjiQnXTQc/view?usp=drive_link) |
| `STEMwerk-Setup-2.2.2.2-offline-bundled-nvidia-gpu-allmodels.exe` | Windows NVIDIA GPU / CUDA | 3.13 GB | [Google Drive](https://drive.google.com/file/d/17i6LmjgQOmrqhugt1QhwMSQ-UlJhz2Ma/view?usp=drive_link) |

### First-use model downloads
If models are not already included in your installer, approximate download sizes on first use:
- `Fast` (`htdemucs`): about 84 MB
- `Quality` (`htdemucs_ft`): about 337 MB
- `6-Stem` (`htdemucs_6s`): about 55 MB

Model size is separate from runtime/bootstrap size, and model download size is not a direct indicator of how many stems a model outputs.

## Windows Notes
- The installer is the recommended setup path on Windows.
- ReaPack is not recommended for first-time Windows setup because it installs scripts only, not the full runtime.
- During first-time setup, installer steps can appear paused for several minutes while Python/backend packages are resolved.
- For `v2.2.2.2`, offline or bundled users may also use the offline patch installer path when appropriate.
- `STEMwerk-SETUP.lua` is a REAPER-side verify/repair tool. It does not replace the Windows installer bootstrap path.

### Updating from older Windows installs
- If you already use an older bundled or offline Windows install, `v2.2.2.2` is the current stable target.
- Prefer `STEMwerk-2.2.2.2-offline-patch.exe` when you want the smaller update path for an existing compatible install.
- If that patch path is not appropriate for your current install state, use the full Windows installer for `v2.2.2.2` instead.
- Current stable release: [STEMwerk v2.2.2.2](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.2.2.2).
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

### ReaPack
Repository URL:

```text
https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/index.xml
```

To install or update:
1. In REAPER: `Extensions -> ReaPack -> Browse packages...`
2. Search for `STEMwerk` and install or update the package.
3. Apply/synchronize changes in REAPER.
4. Run `STEMwerk-SETUP.lua` in the Action List to verify or rebuild the backend runtime if needed.

To add the repository for the first time:
1. `Extensions -> ReaPack -> Import repositories...`
2. Add the URL above
3. Open `Browse packages...`
4. Search `STEMwerk`
5. Install/update
6. Synchronize packages

> **WARNING (Windows)**: ReaPack is not recommended for first-time Windows setup. On Windows, full setup is intentionally handled by the installer; the REAPER setup does not launch bootstrap installers. ReaPack installs only the scripts, so Python/FFmpeg/venv are often missing or resolve to unsupported Windows shim paths. Use the installer (recommended) or the manual developer install instead.

- ReaPack installs STEMwerk under `REAPER/Scripts/STEMwerk-reaper/`, the same folder layout used by the installers.
- Older ReaPack layouts are still accepted by the runtime scripts as a fallback, so existing installs keep working.
- After installing or updating via ReaPack, run `STEMwerk-SETUP.lua` once.

### REAPER Action List: which scripts to use
To avoid confusion, only these are meant for normal use:
- `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) â€” use this for manual installs, ReaPack installs, and the normal bootstrap/repair flow on macOS/Linux.
- `STEMwerk: Main` (`STEMwerk.lua`) â€” the main UI.
- `STEMwerk: Karaoke`, `STEMwerk: Vocals Only`, `STEMwerk: Drums Only`, `STEMwerk: Bass Only`, `STEMwerk: All Stems` â€” optional presets.
- `Stemwerk: Explode Takes (In Place)` (`STEMwerk_Explode_Takes.lua`) â€” quick tool for selected multi-take items.

Internal/troubleshooting (not for regular use):
- everything under `scripts/reaper/_internal/` â€” runtime helpers used by the public scripts

Note: REAPER does not auto-register scripts in the Action List. Use Actions â†’ ReaScript â†’ Load ReaScriptâ€¦ or run `STEMwerk_Setup_Toolbar.lua` to register the standard actions.

### Toolbar icons (manual assign)
- STEMwerk ships a language-neutral icon pack under `scripts/reaper/assets/toolbar_icons/`.
- Recommended REAPER formats:
  - `strips_90x30/` for standard DPI toolbars (3-state strip: normal/hover/active)
  - `strips_180x60/` for hiDPI/retina toolbars
  - `single/` for custom/manual icon assignment sizes (24/30/36/48/64)
- Icons are optional and do not edit `reaper-menu.ini`; assign them manually in toolbar customize dialogs.

## First-run expectations
- First run can take a while: STEMwerk may need to create or verify its runtime, install backend packages, and download the selected model.
- Setup time depends on OS, backend path (CPU/GPU), internet speed, and package resolver speed.
- This is expected behavior for a first install or major update, not a normal "per-track" processing delay.

## Troubleshooting setup/runtime
- If setup fails or runtime looks incomplete, run `STEMwerk-SETUP.lua` to verify/repair the install.
- Check the STEMwerk logs shown by setup/runtime diagnostics to identify the failing step (Python, FFmpeg, backend package, model download, permissions, etc.).
- Backend behavior differs by system and drivers: CPU is the safest fallback, while CUDA/DirectML/ROCm availability depends on hardware and compatible packages.
- On Windows, if bootstrap/runtime files are missing, re-run the installer first, then verify with `STEMwerk-SETUP.lua`.
- If no stems are created and you need help, please provide: `bootstrap.log`, any available `separation_log.txt`, `stdout.txt`, and `stderr.txt`.
- NVIDIA offline bundled troubleshooting (related to issue #11):
  - If separation works online but fails offline, verify models are present in `%LOCALAPPDATA%\\STEMwerk\\models` and that the installed variant actually includes the model set you selected.
  - Re-run the matching offline bundled installer variant (for example `STEMwerk-Setup-2.2.2.2-offline-bundled-nvidia-gpu-allmodels.exe`) and test once with internet disabled to confirm the offline path.
  - Bundled/offline installers intentionally disable the pre-setup "cleanup models" task to avoid deleting freshly bundled model payloads.

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

When `Parallel` is enabled and multiple jobs are queued, STEMwerk can run multi-job processing in parallel when backend/device/job layout support it.

STEMwerk may still fall back to Sequential for stability depending on backend, selected device, job layout, time-selection/per-item isolation, or when only one job is queued.

Recent Windows DirectML builds can run parallel jobs where supported.

Examples where parallel runs:
- 3 tracks queued, `Parallel` on, device = `cuda:0` -> jobs run in parallel.
- Multiple selected items across tracks, no time selection, `Parallel` on, device = `cuda` -> jobs run in parallel where supported.
- `device = auto` with a detected GPU backend and multiple queued jobs -> parallel.

Examples where sequential is used:
- `Parallel` is switched off by the user.
- Backend/device/job-layout stability safeguards force sequential.
- `Parallel` on + `device = auto` with no detected GPU backend -> sequential (`Auto device, no GPU`).
- Single queued job -> sequential by definition.

The progress window shows the active mode and, when applicable, the fallback reason.

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
