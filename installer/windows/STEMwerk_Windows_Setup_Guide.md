# STEMwerk Windows Setup Guide

This guide is for the Windows installer build of STEMwerk 2.3.0.0.

## What the installer just did

The Windows installer:

- installed the STEMwerk REAPER scripts
- prepared the STEMwerk runtime under `%LOCALAPPDATA%\STEMwerk`
- created or updated the Python environment used by STEMwerk
- checked FFmpeg and the core runtime packages
- installed bundled Drum Kit runtime and offline model payloads when included in the installer

The Windows installer remains the recommended fresh-install and repair route on Windows.

## Installer types

- `online installer`: smaller installer; it can download runtime or model assets when needed
- `bundled installer`: includes Python and FFmpeg
- `offline-bundled ... allmodels installer`: includes the bundled runtime payloads needed for a fully offline install for its target backend

## Offline allmodels variants

If you downloaded an offline allmodels installer, the filename indicates the bundled backend:

- `offline-bundled-cpu-allmodels`: CPU Drum Kit runtime and offline models
- `offline-bundled-nvidia-allmodels`: NVIDIA/CUDA Drum Kit runtime and offline models
- `offline-bundled-amd-allmodels`: DirectML Drum Kit runtime and offline models

These installers are intended to complete setup fully offline from bundled wheels and payloads for their target runtime.

## What to do next

1. Start REAPER.
2. Run `STEMwerk: Setup` if you want to check or repair the runtime.
3. Use `Check only` to verify runtime health.
4. Run `Stemwerk: Main` from the Actions menu for normal use.
5. If actions are missing, load scripts from `REAPER/Scripts/STEMwerk-reaper/`.
6. `STEMwerk_Setup_Toolbar.lua` is optional if you want a toolbar shortcut set.

## Setup and repair

Use `STEMwerk: Setup` for:

- `Check only`
- `Repair`
- `Rebuild venv`
- `Save Support Bundle`
- `Open logs folder`
- `Open runtime folder`

Re-run the installer mainly when the installed script payload is missing or damaged, or when you want to reinstall bundled payloads.

Uninstall removes STEMwerk runtime data and installed STEMwerk REAPER scripts.

## When something is missing

1. Run `STEMwerk: Setup`.
2. Click `Check only`.
3. Use `Repair` or `Rebuild venv` if recommended.
4. Use `Open logs folder` if deeper troubleshooting is needed.
5. Use `Save Support Bundle` when asking for help.
6. Re-run the installer only if the installation payload itself is missing or damaged.

## Support bundles

Support bundles are stored at:

`%APPDATA%\REAPER\STEMwerk-support-bundles\`

Each save creates both:

- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS\`
- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS.zip`

Attach the `.zip` when contacting support.

A support bundle includes, where available:

- bootstrap/runtime logs
- state/capabilities files
- recent run logs/artifacts
- `support_bundle_timings.txt`
- `processing_summary.txt`

Support bundles intentionally exclude audio, model, wheel, binary, and runtime payload files.

## Parallel vs Sequential (Multi-track)

STEMwerk can process multi-track jobs in parallel when Parallel is enabled and the selected backend/job layout supports it.

It may fall back to Sequential for stability depending on backend, device choice, job layout, time selection/item isolation, or when only one job is queued.

The progress window shows the active mode and the fallback reason when a fallback happens.

## Open the setup log

Bootstrap/setup log:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Use the Setup action buttons to open logs or runtime folders directly.

## What scripts are for normal use

Normal use:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` for selected multi-take items

Support and repair:

- `STEMwerk: Setup`
- `STEMwerk: Save Support Bundle`

Optional setup convenience:

- `STEMwerk_Setup_Toolbar.lua`
