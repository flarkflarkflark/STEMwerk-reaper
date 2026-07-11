# STEMwerk Windows Setup Guide

This guide is for the Windows installer build of STEMwerk 2.3.0.3.

## What the installer just did

The Windows installer:

- installed the STEMwerk REAPER scripts
- prepared the STEMwerk runtime under `%LOCALAPPDATA%\STEMwerk`
- created or updated the Python environment used by STEMwerk
- checked FFmpeg and the core runtime packages
- installed bundled Drum Kit runtime and offline model payloads when included in the installer

The Windows installer remains the recommended fresh-install and repair route on Windows.

If you are updating an older Windows STEMwerk install, uninstall the old version first and then install `2.3.0.3` fresh. This avoids stale runtime/backend state.

## Installer types

- `online installer`: smaller installer; it can download runtime or model assets when needed
- `bundled installer`: includes Python and FFmpeg
- `offline-bundled ... allmodels installer`: includes the bundled runtime payloads needed for a fully offline install for its target backend

The large offline allmodels installers remain on the `2.3.0.0` release line and are still valid unless you specifically need the latest Windows setup/runtime fixes from `2.3.0.3`.

## Offline allmodels variants

If you downloaded an offline allmodels installer, the filename indicates the bundled backend:

- `offline-bundled-cpu-allmodels`: CPU Drum Kit runtime and offline models
- `offline-bundled-nvidia-gpu-allmodels`: NVIDIA/CUDA Drum Kit runtime and offline models
- `offline-bundled-amd-gpu-allmodels`: DirectML Drum Kit runtime and offline models

These installers are intended to complete setup fully offline from bundled wheels and payloads for their target runtime.

## What to do next

1. Start REAPER.
2. If `STEMwerk` actions are already visible, run `STEMwerk: Setup` if you want to check or repair the runtime.
3. Use `Check only` to verify runtime health.
4. Run `Stemwerk: Main` from the Actions menu for normal use.
5. If `STEMwerk` actions are missing, open `Actions -> Show action list -> ReaScript: Load...`.
6. Preferred one-time registration helper:
   `C:\Users\<Username>\AppData\Roaming\REAPER\Scripts\STEMwerk-reaper\STEMwerk_Setup_Toolbar.lua`
7. That helper registers the normal STEMwerk actions inside REAPER. If you only need the actions, you can cancel the later toolbar prompt.

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

1. First confirm the installed script folder exists:
   `%APPDATA%\REAPER\Scripts\STEMwerk-reaper`
2. If the folder exists but no `STEMwerk` actions appear, REAPER has not registered the scripts yet.
3. In REAPER, open `Actions -> Show action list -> ReaScript: Load...`.
4. Preferred one-time registration helper:
   `STEMwerk_Setup_Toolbar.lua`
5. If you do not want to use the helper, manually load only:
   `STEMwerk-SETUP.lua`, `STEMwerk.lua`, `STEMwerk_Drum_Kit_Split.lua`, `STEMwerk_Explode_Takes.lua`
6. Do not load every `.lua` file in the folder.
7. Do not load files under `_internal\`.
8. `STEMwerk_AI_Separate.lua` is a compatibility wrapper for older installs and is not needed on a fresh install.
9. After registration, run `STEMwerk: Setup`, click `Check only`, then use `Repair` or `Rebuild venv` if recommended.
10. Use `Open logs folder` or `Save Support Bundle` when asking for help.
11. Re-run the installer only if the installation payload itself is missing or damaged.

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

- `STEMwerk: Setup`
- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Drum Kit Split`
- `Stemwerk: Explode Takes (In Place)` for selected multi-take items

Support and repair:

- `STEMwerk: Save Support Bundle`

Optional setup convenience:

- `STEMwerk_Setup_Toolbar.lua`

Compatibility wrapper:

- `STEMwerk_AI_Separate.lua` exists so older REAPER action bindings do not break, but new installs should use `STEMwerk.lua`.
