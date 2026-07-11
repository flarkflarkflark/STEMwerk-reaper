<p>
  <img src="https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/installer/assets/stemwerk.png" alt="STEMwerk" width="64">
</p>

Local-first stem separation inside REAPER (open source, ReaPack).<br>
Split vocals, drums, bass, and more directly in your DAW for practical production, editing, remix, and karaoke workflows.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script package that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend and keeps processing on your machine.

## Release status
This README describes the current hotfix release: `STEMwerk 2.3.0.4`.

- `2.3.0.4` is the current hotfix release for the 2.3 line.
- `2.3.0.0` remains the original 2.3 full-release baseline.
- `2.3.0.4` is a focused hotfix release for the 2.3 line with the DrumSep timeout fix plus post-`2.3.0.3` docs/helper improvements.
- ReaPack is updated to `2.3.0.4`.
- Windows users should uninstall older STEMwerk versions first, then install the `2.3.0.4` online or bundled installer.
- GitHub Release: <https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.3.0.4>
- ReaPack index: <https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/index.xml>

For full release notes, asset checksums, and current download details, use the published GitHub Release page.

![STEMwerk in action](docs/assets/stemwerk_fullscreen.gif)

## What's new in 2.3.0.4
- Long-running DrumSep, Direct Kit, and Kit Split jobs are no longer killed after a hard 3600-second wall-clock timeout.
- DrumSep now uses a progress-aware no-output stall watchdog instead of an absolute one-hour kill.
- Windows installer and manual setup guidance now explains REAPER Action List registration more clearly.
- `STEMwerk_Setup_Toolbar.lua` remains the preferred one-time action-registration helper and also registers Drum Kit Split.
- README, screenshots, offline/allmodels links, and the full-workflow demo GIF are refreshed.
- ReaPack is updated to `2.3.0.4`.
- Large offline/allmodels assets remain separate and are not part of the `2.3.0.4` GitHub release assets.

## Platform screenshots
### Windows
![STEMwerk 2.3 Windows Kit Split](docs/assets/stemwerk-2.3-windows-kit-split.png)

### Linux (AMD ROCm)
![STEMwerk 2.3 Linux AMD ROCm Kit Split](docs/assets/stemwerk-2.3-linux-amd-rx9070-kit-split.png)

### Linux (NVIDIA CUDA)
![STEMwerk 2.3 Linux NVIDIA CUDA Kit Split](docs/assets/stemwerk-2.3-linux-nvidia-rtx3060-kit-split.png)

### macOS (Apple Silicon / MPS)
![STEMwerk 2.3 macOS Kit Split](docs/assets/stemwerk-2.3-macos-kit-split.png)

## Features
- Stem separation for vocals, drums, bass, other, and drum-kit workflows
- Time selection and per-item workflows for multi-item tracks
- New-tracks or in-place replacement as takes
- Presets for quick workflows
- Batch and multi-track processing queue
- Device selection with CPU and GPU fallback
- Local-first processing with transparent logs

## Who is this for?
- Producers and remixers who need quick stems without leaving REAPER
- Editors and podcasters cleaning dialog or music beds
- Sound designers and educators building isolated parts
- Anyone who wants a fast local stem workflow

## Requirements
- 64-bit REAPER
- 64-bit Windows, Linux, or macOS
- Internet access is recommended for first-time setup, runtime/package installation, and first model download
- Enough free disk space for runtime files, package cache, temporary files, model cache, and output stems

Recommended free space:
- Windows standard installer: at least 8 GB free during first setup
- Windows NVIDIA CUDA and Linux ROCm setups may need more
- Bundled installers include Python and FFmpeg, but can still require backend package and model downloads
- Large offline allmodels installers need additional free space for the installer itself, extracted assets, cache, and output stems

## Backend support

### CPU
- Windows: validated
- macOS Intel: supported
- Apple Silicon: supported
- Linux: supported

### Windows GPU
- NVIDIA CUDA: validated for the installer/runtime path
- AMD DirectML: validated for the installer/runtime path

### Linux GPU
- Linux is supported via ReaPack and package-based installs (`AppImage`, `.deb`, `.rpm`, Arch package).
- GPU acceleration depends on a compatible CUDA or ROCm environment.
- ROCm support remains hardware and driver dependent.

### Apple Silicon and macOS
- macOS Intel and Apple Silicon are supported through the setup flow.
- Apple Silicon MPS passed smoke for this release, but remains hardware and runtime dependent.
- CPU remains a supported fallback path when GPU acceleration is unavailable.

## Downloads

### Recommended install path
- Existing users: ReaPack remains the preferred update path for scripts and actions.
- New Windows users: use the Windows installer.
- macOS users: use the `.pkg` installer or ReaPack/script setup.
- Linux users: use ReaPack or one of the package-based release assets.

After install or update, use `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) when runtime verification or repair is needed, then launch `STEMwerk: Main` (`STEMwerk.lua`).

Windows installer note: the installer copies the REAPER script payload to `%APPDATA%\REAPER\Scripts\STEMwerk-reaper`, but REAPER action entries may still need to be registered from inside REAPER. If `STEMwerk:` actions are missing, open `Actions -> Show action list -> ReaScript: Load...`, load `STEMwerk_Setup_Toolbar.lua`, and cancel the toolbar prompt if you only need action registration.

### GitHub release assets for 2.3.0.4
All current public GitHub downloads are on the release page:
<https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.3.0.4>

| File | Description |
|---|---|
| `STEMwerk-Setup-2.3.0.4.exe` | Windows standard installer |
| `STEMwerk-Setup-2.3.0.4-bundled.exe` | Windows bundled installer |
| `STEMwerk-2.3.0.4.pkg` | macOS installer |
| `STEMwerk-2.3.0.4-x86_64.AppImage` | Linux AppImage |
| `stemwerk_2.3.0.4_amd64.deb` | Debian/Ubuntu package |
| `stemwerk-2.3.0.4-1.noarch.rpm` | RPM package |
| `stemwerk-2.3.0.4-1-any.pkg.tar.zst` | Arch package |
| `STEMWERK_2304_SHA256SUMS_CURRENT.txt` | Current public SHA256 manifest |

GitHub also provides automatic source archives (`.zip` / `.tar.gz`) on the release page, but those are not the recommended end-user downloads.

### Large offline allmodels installers (separate / optional)
These large offline/full installers are not part of the lightweight `2.3.0.4` GitHub release asset set. They remain available separately for users who specifically want the larger offline allmodels installers with bundled runtime/model payloads.

The large Windows offline allmodels installers remain at [`2.3.0.0`](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/2.3.0.0) and are still valid unless a user specifically needs the latest Windows setup/runtime fixes from [`2.3.0.4`](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/v2.3.0.4). These are optional separate downloads, not the current `2.3.0.4` GitHub release assets.

| File | Platform | Download |
|---|---|---|
| `STEMwerk-Setup-2.3.0.0-offline-bundled-cpu-allmodels.exe` | Windows CPU | [Google Drive](https://drive.google.com/file/d/1yfqURi2sllPPdIVu8RepaJmDQKuLyVWX/view?usp=drivesdk) |
| `STEMwerk-Setup-2.3.0.0-offline-bundled-amd-gpu-allmodels.exe` | Windows AMD / DirectML | [Google Drive](https://drive.google.com/file/d/15Lpi_CjcjvZndqdpZevwA76wslcXASkm/view?usp=drivesdk) |
| `STEMwerk-Setup-2.3.0.0-offline-bundled-nvidia-gpu-allmodels.exe` | Windows NVIDIA / CUDA | [Google Drive](https://drive.google.com/file/d/1mS_TmmXBlqPPBbJGZt_YoDC05N7DWZCh/view?usp=drivesdk) |
| `STEMwerk-2.3.0.0-offline-bundled-intel-cpu-allmodels.pkg` | macOS Intel CPU | [Google Drive](https://drive.google.com/file/d/1PAjHndTmYgQkyJ9ZOEqHEUSRYxvCHmQ-/view?usp=drivesdk) |
| `STEMwerk-2.3.0.0-offline-bundled-apple-silicon-mps-allmodels.pkg` | macOS Apple Silicon / MPS | [Google Drive](https://drive.google.com/file/d/1zIKV3BrYoNFjQzw34mTox7wV60nZ5bts/view?usp=drivesdk) |

No current public Linux large offline allmodels download URLs are listed here because those larger Linux offline builds were not part of the public lightweight `2.3` release set.

### Runtime and model downloads
STEMwerk downloads the required separation models during setup/runtime preparation when possible, or automatically on first use if a model is not cached yet.

Approximate model-cache downloads:
- `Fast` (`htdemucs`): about 84 MB
- `Quality` (`htdemucs_ft`): about 337 MB
- `6-Stem` (`htdemucs_6s`): about 55 MB
- Drum Kit / DrumSep models are handled by the separate DrumSep runtime and model setup and can require additional downloads.

Bundled installers include Python + FFmpeg, but not necessarily every backend package and model cache. Large offline/allmodels installers are separate assets for users who need more complete offline model payloads.

## Installation

### Recommended
1. Windows: use the current Windows installer release asset.
2. macOS: use the current `.pkg` installer or install through ReaPack.
3. Linux: use ReaPack, AppImage, `.deb`, `.rpm`, or the Arch package.
4. In REAPER, run `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) when prompted or when runtime verification or repair is needed.
5. Start the main UI with `STEMwerk: Main` (`STEMwerk.lua`).

Notes:
- On Windows, the installer is the preferred first-time setup path.
- On macOS and Linux, `STEMwerk: Setup` is the normal in-REAPER setup and repair entry point.
- ReaPack installs scripts and actions; runtime validation still happens through `STEMwerk: Setup`.

### Manual or developer install
1. Install a supported 64-bit Python 3 version and ensure it is on your `PATH`.
2. Clone or download this repository.
3. In REAPER, open `Actions -> Show action list -> ReaScript: Load ReaScript...`
4. Load and run `scripts/reaper/STEMwerk-SETUP.lua`.
5. Then run `scripts/reaper/STEMwerk.lua`.

### ReaPack
Repository URL:

```text
https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/index.xml
```

To add the repository:
1. In REAPER, open `Extensions -> ReaPack -> Import repositories...`
2. Add the URL above.
3. Open `Browse packages...`
4. Search for `STEMwerk`.
5. Install or update the package.
6. Synchronize packages.

After installing or updating via ReaPack, run `STEMwerk: Setup` once.

> **Windows note**: ReaPack is not the preferred first-time Windows install path. Use the Windows installer first, then use ReaPack for later script updates if desired.

## Windows Notes
- The current stable Windows target is `2.3.0.4`.
- The small Windows patch-only path is retired.
- Existing Windows users should uninstall older STEMwerk versions first, then install the full online or bundled `2.3.0.4` installer.
- After install, run `STEMwerk-SETUP.lua` once to verify paths and runtime state.
- If setup still reports missing runtime or bootstrap pieces, rerun the installer first, then rerun `STEMwerk-SETUP.lua`.

## REAPER Action List
For normal use:
- `STEMwerk: Setup` (`STEMwerk-SETUP.lua`)
- `STEMwerk: Main` (`STEMwerk.lua`)
- `STEMwerk: Karaoke`
- `STEMwerk: Vocals Only`
- `STEMwerk: Drums Only`
- `STEMwerk: Bass Only`
- `STEMwerk: All Stems`
- `STEMwerk: Drum Kit Split`
- `STEMwerk: Explode Takes (In Place)`

Windows installer note:
- If STEMwerk does not appear in REAPER Actions after install, open `Actions -> Show action list -> ReaScript: Load...` and first try `STEMwerk_Setup_Toolbar.lua` from `%APPDATA%\REAPER\Scripts\STEMwerk-reaper`.
- If you prefer manual registration, load only `STEMwerk-SETUP.lua`, `STEMwerk.lua`, `STEMwerk_Drum_Kit_Split.lua`, and `STEMwerk_Explode_Takes.lua`.
- Do not load every `.lua` file in that folder, and do not load files under `scripts/reaper/_internal/`.
- `STEMwerk_AI_Separate.lua` is a compatibility wrapper for older action bindings and is not needed on a fresh install.

Internal or troubleshooting content:
- Files under `scripts/reaper/_internal/` are runtime helpers and not normal user entry points.

## First-run expectations
- First setup can take a while while STEMwerk creates or verifies its runtime, installs backend packages, and downloads the selected model.
- Setup time depends on OS, backend path, internet speed, and package resolver speed.
- This is expected on a first install or major update.

## Troubleshooting
- If setup fails or runtime looks incomplete, run `STEMwerk: Setup`.
- Check the STEMwerk logs shown by the setup/runtime flow to identify the failing step.
- CPU is the safest fallback path if CUDA, DirectML, ROCm, or MPS is unavailable on your machine.
- On Windows, if bootstrap or runtime files are missing, rerun the installer first and then rerun `STEMwerk: Setup`.
