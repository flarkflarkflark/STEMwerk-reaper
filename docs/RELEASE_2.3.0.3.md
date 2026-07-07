# STEMwerk 2.3.0.3

## Scope

`2.3.0.3` is the next public Windows-focused patch release on top of the trusted `2.3.0.0` full-release basis.

- `2.3.0.3` supersedes the original `2.3.0.0` Windows full installers.
- The ReaPack/script hotfix line `2.3.0.2` is not used as the full installer release identity.
- The Windows update-patch asset remains retired and is not published.

## Windows install/upgrade guidance

- Existing Windows users should uninstall the old STEMwerk version first, then install `2.3.0.3` using the full online or bundled installer.
- A clean reinstall avoids stale runtime/backend state, including broken setup state, stale script overrides, and GPU routes falling back incorrectly.
- Supported Windows GitHub assets for `2.3.0.3`:
  - `STEMwerk-Setup-2.3.0.3.exe`
  - `STEMwerk-Setup-2.3.0.3-bundled.exe`
- `STEMwerk-2.3.0.3-update-patch.exe` is not published.

## Fixes included in 2.3.0.3

- Windows path normalization now collapses duplicate local separators before canonicalization, logging, setup validation, bundled Python install, FFmpeg handling, and venv rebuild/repair routing.
- Setup `Repair` and `Rebuild venv` on Windows now launch bootstrap instead of the old verify-only path.
- Drum Kit Split CUDA failures now preserve primary runtime causes such as `cuda_illegal_memory_access` and `cuda_out_of_memory` instead of reporting only secondary output-count mismatch symptoms.
- Low-VRAM CUDA diagnostics now surface clearer guidance for GTX 1650 / ~4 GB class GPUs.
- CPU Drum Kit selection now reports missing or broken CPU runtime state explicitly.
- Worker Python launchers now clear `PYTHONPATH` and `PYTHONHOME`, and stale `separatorScript` overrides outside the current install tree are ignored.
- Support bundle ZIP entry names are normalized to forward slashes for portable ZIP readers.

## Offline allmodels note

The large Windows offline allmodels installers remain at `2.3.0.0` and are still valid unless a user specifically needs the latest Windows setup/runtime fixes from `2.3.0.3`.

## Pre-release live smoke plan

- READY_TO_GO_SMOKE_PASS
- PRE_RELEASE_SMOKE_MATRIX_BLOCKED
