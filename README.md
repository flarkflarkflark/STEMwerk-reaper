<p>
  <img src="https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/installer/assets/stemwerk.png" alt="STEMwerk" width="64">
</p>

Local-first stem separation inside REAPER (open source, ReaPack).<br>
Split vocals, drums, bass, and more directly in your DAW for practical production, editing, remix, and karaoke workflows.

## What is STEMwerk-reaper?
STEMwerk-reaper is a REAPER script package that runs high-quality stem separation on selected items or time selections and brings the results back into your project as new tracks or in-place takes. It uses a Python backend and keeps processing on your machine.

## Release status
This README describes the current public full GitHub release: `STEMwerk 2.3.0.0`.

- Latest full GitHub release: <https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/2.3.0.0>
- Latest ReaPack script hotfix: `2.3.0.2`
- ReaPack index: <https://raw.githubusercontent.com/flarkflarkflark/STEMwerk-reaper/main/index.xml>

For full release notes, GitHub asset checksums, and current download details, use the published GitHub Release page.

![STEMwerk in action](docs/assets/stemwerk_fullscreen.gif)

## Screenshots
Small cross-platform showcase from the current public `STEMwerk 2.3` release line.

<p>
  <img src="docs/assets/stemwerk-2.3-macos-kit-split.png" alt="STEMwerk 2.3 on macOS with Kit Split selected" width="48%">
  <img src="docs/assets/stemwerk-2.3-linux-amd-rx9070-kit-split.png" alt="STEMwerk 2.3 on Linux with AMD RX 9070 and Kit Split selected" width="48%">
</p>
<p>
  <img src="docs/assets/stemwerk-2.3-linux-nvidia-rtx3060-kit-split.png" alt="STEMwerk 2.3 on Linux with NVIDIA RTX 3060 and Kit Split selected" width="48%">
  <img src="docs/assets/stemwerk-2.3-windows-kit-split.png" alt="STEMwerk 2.3 on Windows with Kit Split selected" width="48%">
</p>

## What's new in 2.3.0.0
- Direct Drum Kit and Drum Kit Split workflows for drum-focused separation.
- Improved Windows, macOS, and Linux packaging for public installs and updates.
- Windows offline allmodels installers for CPU, NVIDIA CUDA, and AMD DirectML.
- macOS offline allmodels installers for Intel CPU and Apple Silicon MPS.
- Standard Linux AppImages included in the public release.
- Better setup, repair, and support-bundle flow for end users.
- Local-first processing remains the default workflow.

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
- macOS Intel: validated
- Linux: supported

### Windows GPU
- NVIDIA CUDA: validated
- AMD DirectML: validated

### Linux GPU
- Standard Linux packages are included in the public 2.3.0.0 release.
- Large fully offline Linux allmodels AppImages are still being validated separately and are not part of the final 2.3.0.0 offline allmodels set.
- Linux CUDA and ROCm support remain hardware-driver dependent.

### Apple Silicon
- Apple Silicon MPS is included in the macOS Apple Silicon offline allmodels installer for 2.3.0.0.
- CPU remains a supported fallback path when needed.

## Downloads

### Recommended install path
- Existing users: ReaPack remains the preferred update path for scripts and actions.
- New Windows users: use the Windows installer.
- macOS users: use the `.pkg` installer or ReaPack/script setup.
- Linux users: use ReaPack or the standard AppImages.

After install or update, use `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) when runtime verification or repair is needed, then launch `STEMwerk: Main` (`STEMwerk.lua`).

### GitHub release assets for 2.3.0.0
All current public GitHub downloads are on the release page for `2.3.0.0`:
<https://github.com/flarkflarkflark/STEMwerk-reaper/releases/tag/2.3.0.0>

| Download | Use | Size |
|---|---|---:|
| [STEMwerk-Setup-2.3.0.0.exe](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-Setup-2.3.0.0.exe) | Windows standard installer | 3.85 MB / 3,845,263 bytes |
| [STEMwerk-Setup-2.3.0.0-bundled.exe](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-Setup-2.3.0.0-bundled.exe) | Windows bundled installer | 139.38 MB / 139,381,315 bytes |
| [STEMwerk-2.3.0.0-update-patch.exe](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-2.3.0.0-update-patch.exe) | Windows update / repair patch | 3.82 MB / 3,817,256 bytes |
| [STEMwerk-2.3.0.0.pkg](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-2.3.0.0.pkg) | macOS installer | 7.76 MB / 7,763,439 bytes |
| [STEMwerk-2.3.0.0-x86_64.AppImage](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-2.3.0.0-x86_64.AppImage) | Linux standard AppImage | 1.81 MB / 1,811,648 bytes |
| [STEMwerk-2.3.0.0-x86_64-bundled.AppImage](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMwerk-2.3.0.0-x86_64-bundled.AppImage) | Linux bundled AppImage | 433.15 MB / 433,145,024 bytes |
| [STEMWERK_2300_SHA256SUMS_CURRENT.txt](https://github.com/flarkflarkflark/STEMwerk-reaper/releases/download/2.3.0.0/STEMWERK_2300_SHA256SUMS_CURRENT.txt) | Current public SHA256 manifest | 7.97 KB / 7,968 bytes |

Use the SHA256 manifest above for the published GitHub assets. GitHub also provides automatic source archives (`.zip` / `.tar.gz`) on the release page, but those are not the recommended end-user downloads.

### Large offline allmodels installers
The large offline allmodels installers for Windows and macOS are linked from release materials and are not attached to the GitHub Release.

| Download | Target | Size | SHA256 |
|---|---|---:|---|
| [STEMwerk-Setup-2.3.0.0-offline-bundled-cpu-allmodels.exe](https://drive.google.com/file/d/1yfqURi2sllPPdIVu8RepaJmDQKuLyVWX/view?usp=drivesdk) | Windows CPU | 1.54 GB / 1,535,981,216 bytes | `a9a3825a2f6ee8e11d662913b352a68fb0a77e5fad792f462328f1cfcbae43fe` |
| [STEMwerk-Setup-2.3.0.0-offline-bundled-amd-gpu-allmodels.exe](https://drive.google.com/file/d/15Lpi_CjcjvZndqdpZevwA76wslcXASkm/view?usp=drivesdk) | Windows AMD / DirectML | 1.39 GB / 1,392,439,785 bytes | `072043e57e515aa6d928c8f1954770129605787583593070619aaba38b4ab7cd` |
| [STEMwerk-Setup-2.3.0.0-offline-bundled-nvidia-gpu-allmodels.exe](https://drive.google.com/file/d/1mS_TmmXBlqPPBbJGZt_YoDC05N7DWZCh/view?usp=drivesdk) | Windows NVIDIA / CUDA | 3.83 GB / 3,828,446,792 bytes | `a5a87ee20aed9a7d5f219b44d2144952b8c26435f6044b56f50e8c04f404ec42` |
| [STEMwerk-2.3.0.0-offline-bundled-intel-cpu-allmodels.pkg](https://drive.google.com/file/d/1PAjHndTmYgQkyJ9ZOEqHEUSRYxvCHmQ-/view?usp=drivesdk) | macOS Intel CPU | 1.33 GB / 1,325,151,327 bytes | `46de2b9bb801635fc1df2e2a630f750f0f97530da089c9c8dc41f5caca24039d` |
| [STEMwerk-2.3.0.0-offline-bundled-apple-silicon-mps-allmodels.pkg](https://drive.google.com/file/d/1zIKV3BrYoNFjQzw34mTox7wV60nZ5bts/view?usp=drivesdk) | macOS Apple Silicon MPS | 1.12 GB / 1,123,438,652 bytes | `f124bc425bf0462706dbe41e00409440ae6beeb94d2d512fa87e94d28c744b71` |

Linux ordinary AppImages included in the public 2.3.0.0 release:
- `STEMwerk-2.3.0.0-x86_64.AppImage`
- `STEMwerk-2.3.0.0-x86_64-bundled.AppImage`

Large fully offline Linux allmodels AppImages are still being validated separately and are not listed as final 2.3.0.0 downloads here.

### First-use model downloads
If models are not already included in your installer, approximate download sizes on first use:
- `Fast` (`htdemucs`): about 84 MB
- `Quality` (`htdemucs_ft`): about 337 MB
- `6-Stem` (`htdemucs_6s`): about 55 MB

## Installation

### Recommended
1. Windows: use the current Windows installer release asset.
2. macOS: use the current `.pkg` installer or install through ReaPack.
3. Linux: use ReaPack or one of the standard AppImages.
4. In REAPER, run `STEMwerk: Setup` (`STEMwerk-SETUP.lua`) when prompted or when runtime verification/repair is needed.
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
