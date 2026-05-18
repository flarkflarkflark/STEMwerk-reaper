# STEMwerk v2.2.2.2

Release date: 2026-05-18

This release focuses on reliability, packaging parity, setup clarity, and supportability. It does not introduce new end-user model families or claim Apple Silicon MPS production acceleration.

## Reliability / Support

- Support bundles now create a ready-to-upload `.zip` next to the source folder.
- Windows support bundle collection is now bounded and much faster, avoiding broad temp/probe scans that could make REAPER appear unresponsive.
- Support bundles include timing diagnostics and a compact recent processing summary with model/backend/mode/job count and realtime speed where available.
- Runtime run artifacts and recent run logs are included in support bundles, while audio, model, wheel, binary, and runtime payloads remain excluded.
- A busy/status window is shown while saving support bundles.
- Support guidance is expanded in both Native and Visual Help.
- Generated `dist/` output is ignored to reduce accidental commits.

## Setup / Runtime

- Windows now has an in-REAPER setup/status overview similar to Linux/macOS.
- Windows setup shows runtime path, model path, backend/profile, Python/FFmpeg status, verification status, and dependency status where available.
- Windows setup actions include Check only, Repair, Rebuild venv, Save Support Bundle, Open logs folder, and Open runtime folder.
- Stale or invalid Windows `pythonPath` values such as `python` are no longer treated as reliable when a valid runtime Python is known from setup/capabilities.
- Offline Windows bundled installers restore the required `samplerate==0.1.0` wheel payloads for NVIDIA, AMD/DirectML, and CPU packages.
- Offline setup now hard-fails or repairs missing samplerate/runtime dependencies instead of reporting success too early.
- The bundled `julius` fallback remains available for offline repair paths.

## macOS / Apple Silicon

- Missing FFmpeg recovery is improved.
- Setup checks Homebrew and MacPorts FFmpeg paths, including `/opt/local/bin/ffmpeg`.
- Setup can guide users to **Set FFmpeg Path**.
- Intel macOS setup uses the conservative CPU fallback stack.
- Apple Silicon MPS is detected for diagnostics, but Demucs separation uses CPU fallback for reliability.
- This avoids a known PyTorch/MPS failure path with Demucs on Apple Silicon.
- MPS acceleration remains experimental/R&D in this release.
- The no-audio/select-audio window now follows the main STEMwerk window placement more reliably on macOS.

## Windows / Installer

- Offline patch accepts both modern and legacy install layouts.
- Installer payload excludes are restored for non-runtime/source assets.
- The Windows installer EXE icon uses the correct STEMwerk app icon.
- The Windows installer wizard header now uses the correct compact STEMwerk logo.
- A stray installer status/header repaint artifact near the top-right logo area is suppressed.
- Windows bundled/offline installers include the restored samplerate payload required for offline audio-separator runtime repair.

## Packaging / Icons

- Obsolete file-based `themes/` payloads are removed from release script packages.
- Toolbar setup script and toolbar icon assets are included in the release payload.
- Linux AppImage/deb/rpm/Arch packages now install/use the STEMwerk icon metadata where supported.
- AppImage icon metadata uses the square STEMwerk icon and `.DirIcon`.
- Linux package hicolor icons are installed for package formats where applicable.

## UI / Workflow

- STEMwerk includes a cleaner, calmer REAPER-Native UI mode designed to feel more DAW-like and less visually busy while keeping the existing flarkAUDIO Visual mode available.
- Existing users keep their saved UI preference after update.
- You can switch UI mode from the top-right UI control.
- Light/dark mode remains available as before.
- New output grouping option: **Per item / Per track**.
- Source-track grouping applies only to **New Tracks**.
- Storage labels are clarified (`Storage/Opslag/Speicherort`).
- Cleanup labels are clarified (`Cleanup/Opruimen/Aufraumen`).
- Section and footer tooltips are added, including processing-window footer tooltip polish.
- Native/Visual Help support information is improved.
- Visible EN/NL/DE i18n polish.

## Diagnostics / Performance

- Phase/timing diagnostics are included for GPU scheduling analysis.
- Timing summary helper is included for diagnostics workflows.
- Support bundles now include `support_bundle_timings.txt`.
- Support bundles now include `processing_summary.txt` for recent processing speed/results where available.
- Internal parallel job limiter prototype exists, but remains off by default.
