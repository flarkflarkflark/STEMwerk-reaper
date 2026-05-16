# STEMwerk v2.2.2.2

Release date: 2026-05-16

This release focuses on reliability, packaging parity, and supportability. It does not introduce new end-user model families or claim Apple Silicon MPS production acceleration.

## Reliability / Support

- Better support bundle diagnostics.
- Runtime run artifacts are included in support bundles.
- A busy/status window is shown while saving support bundles.
- Support guidance is expanded in both Native and Visual Help.
- Generated `dist/` output is now ignored to reduce accidental commits.

## macOS / Apple Silicon

- Missing FFmpeg recovery is improved.
- Setup checks Homebrew and MacPorts FFmpeg paths, including `/opt/local/bin/ffmpeg`.
- Setup can guide users to **Set FFmpeg Path**.
- Apple Silicon MPS is detected for diagnostics, but Demucs separation now uses CPU fallback for reliability.
- This avoids a known PyTorch/MPS failure path with Demucs on Apple Silicon.
- MPS acceleration remains experimental/R&D in this release.

## Windows / Installer

- Offline patch accepts both modern and legacy install layouts.
- Installer payload excludes are restored for non-runtime/source assets.
- Installer icon assets are restored.

## UI / Workflow

- New output grouping option: **Per item / Per track**.
- Source-track grouping applies only to **New Tracks**.
- Storage labels are clarified (`Storage/Opslag/Speicherort`).
- Cleanup labels are clarified (`Cleanup/Opruimen/Aufräumen`).
- Section and footer tooltips are added.
- Native/Visual Help support information is improved.
- Visible EN/NL/DE i18n polish.

## Diagnostics / Performance

- Phase/timing diagnostics for GPU scheduling analysis.
- Timing summary helper is included for diagnostics workflows.
- Internal parallel job limiter prototype exists, but remains off by default.
