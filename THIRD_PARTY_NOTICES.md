# THIRD_PARTY_NOTICES

Last updated: 2026-08-26

This file lists third-party components used or redistributed by STEMwerk builds.

STEMwerk itself is licensed under the repository `LICENSE` file.
Third-party software remains under the license terms of its respective owner.

## Bundled or Downloaded Runtime Components

1. Python (CPython) 3.11.x
Source: https://www.python.org/
Notes: used to create the local STEMwerk runtime environment.

2. FFmpeg (Windows builds from gyan.dev)
Source: https://www.gyan.dev/ffmpeg/builds/
Upstream: https://ffmpeg.org/
Notes: used for audio decoding/encoding in runtime workflows.

3. FFmpeg 8.0.3 (macOS Apple Silicon source build)
Source: https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz
License: LGPL-2.1-or-later (external/GPL/nonfree codecs disabled)
Notes: `ffmpeg` and `ffprobe` are built as thin arm64 executables with static FFmpeg
libraries and macOS system-library references only. Exact source and binary provenance is
recorded by `tools/macos_ffmpeg.py`; see `tools/macos-ffmpeg/PROVENANCE.md`. The corresponding
verified source is prepared as the accompanying release artifact `ffmpeg-8.0.3.tar.xz` with
SHA-256 `6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`.

## Python Ecosystem Components (Installed by Bootstrap)

STEMwerk bootstrap installs Python packages (online or from bundled wheels in offline installers).
Examples of installed components include:

- audio-separator
- torch
- torchvision
- torch-directml
- onnxruntime / onnxruntime-directml
- numpy
- scipy
- librosa
- soundfile
- onnx
- onnx2torch
- requests
- pydub
- tqdm
- samplerate

Exact package set can differ by backend (CPU, CUDA, DirectML) and installer flavor.

## Vendored Components in Repository

1. `scripts/reaper/vendor/stemwerk-core`
Maintainer: flarkAUDIO / STEMwerk project

2. `scripts/reaper/vendor/julius`
Maintainer: flarkAUDIO / STEMwerk project (compatibility fallback implementation)

## Where To Find Exact License Metadata On Installed Systems

After installation, inspect:

- `%LOCALAPPDATA%\\STEMwerk\\.venv\\Lib\\site-packages\\*dist-info\\METADATA`
- `%LOCALAPPDATA%\\STEMwerk\\.venv\\Lib\\site-packages\\*dist-info\\LICENSE*`
- `%LOCALAPPDATA%\\STEMwerk\\logs\\bootstrap.log` (exact installed package names/versions)

For offline installers, bundled wheels are under:

- `{app}\\_bundled\\wheels`

Wheel contents include metadata and package license information from upstream maintainers.

## Attribution Notes

All trademarks and product names belong to their respective owners.
If a package attribution is missing or incorrect, please report it:

- GitHub Issues: https://github.com/flarkflarkflark/STEMwerk-reaper/issues
