# STEMwerk Windows Setup Guide

This guide is for the Windows installer build of STEMwerk.

## What the installer just did

The Windows installer:

- copied the STEMwerk REAPER scripts into your REAPER Scripts folder
- prepared the STEMwerk runtime under your local Windows profile
- created or updated the Python environment used by STEMwerk
- checked FFmpeg and the core runtime Python packages
- in bundled or offline/full variants, can include runtime wheels and core model payloads

The Windows installer remains the recommended fresh-install/bootstrap route.

For `2.3.0.0` pre-release verification, use installers rebuilt from `e06507c99e6e336cbbf36892a39c97876d10daa0` or later. Earlier `21a59cd` builds are stale after the Windows ready-to-go fix.

## Installer terminology

- `offline installer`: smaller installer/downloader style; it may still require internet to fetch runtime or model assets
- `bundled installer`: includes Python + FFmpeg
- `offline/full installer`: larger complete package intended for no-internet install/use

In the 2.3 release line, "offline/full" still needs to be read carefully: existing `allmodels` variants cover the core Demucs cache scope, not an unconditional complete DrumSep/Drum Kit offline runtime bundle.

## Offline/full installer flavors (GPU)

If you downloaded an offline/full bundled installer, the filename tells you which runtime flavor is bundled:

- `offline-bundled-nvidia`: CUDA wheel payload for NVIDIA GPUs
- `offline-bundled-amd`: DirectML wheel payload for AMD/Intel GPUs
- CPU/fallback paths are included where applicable for runtime repair

Existing `allmodels` offline/full assets are currently distributed around the core Demucs model cache. They are not complete DrumSep/Drum Kit offline/full bundles in the 2.3 release line.

Samplerate/runtime note:

- Bundled/offline installers include restored `samplerate==0.1.0` wheel payloads for NVIDIA, AMD/DirectML, and CPU package sets.
- If `samplerate` is missing, Setup/Repair should install it from bundled wheels where available.
- Verification should not report `ok` before required runtime dependency checks pass.

Bundled-model cleanup note:

- In bundled/offline pre-setup flow, cleanup-models is intentionally disabled to avoid deleting freshly bundled model payloads.
- Drum Kit/DrumSep runtimes and model assets in 2.3 are still handled through the setup/runtime flow after installation when needed.

## What to do next

1. Open REAPER.
2. Run `STEMwerk: Setup` first if you want to check runtime status.
3. Use `Check only` to verify runtime health.
4. Run `Stemwerk: Main` for normal use.
5. If actions are missing, load scripts from `REAPER/Scripts/STEMwerk-reaper/`.
6. Toolbar setup is optional: `STEMwerk_Setup_Toolbar.lua`.

## Important Windows note

- The Windows installer remains the recommended fresh-install/bootstrap route.
- `STEMwerk: Setup` is now the in-REAPER status/repair center after installation.
- Use Setup for: `Check only`, `Repair`, `Rebuild venv`, `Save Support Bundle`, `Open logs folder`, and `Open runtime folder`.
- Re-run the installer mainly when script payload itself is missing/damaged, or when you need to reinstall bundled payloads.
- If you are validating a 2.3.0.0 pre-release installer, do not sign off an older `21a59cd` build; rebuild from `e06507c` or later first.

## When something is missing

1. Run `STEMwerk: Setup`.
2. Click `Check only`.
3. Use `Repair` or `Rebuild venv` if recommended.
4. Use `Open logs folder` if deeper troubleshooting is needed.
5. Use `Save Support Bundle` when asking for help.
6. Re-run the installer only if installation/script payload is missing or damaged.

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

Windows collection is speed-bounded; expensive probes/scans may appear as skipped-for-speed to keep Save Support Bundle responsive.

## Parallel vs Sequential (Multi-track)

STEMwerk can process multi-track jobs in parallel when Parallel is enabled and the selected backend/job layout supports it.

It may fall back to Sequential for stability depending on backend, device choice, job layout, time selection/item isolation, or when only one job is queued.

Recent Windows DirectML builds can run parallel jobs where supported.

The progress window shows the active mode and the fallback reason when a fallback happens.

## Open the setup log

Bootstrap/setup log:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Use the Setup action buttons to open logs/runtime directly.

Support bundle output path:

`%APPDATA%\REAPER\STEMwerk-support-bundles\`

## What scripts are for normal use

Normal use:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` (for selected multi-take items)

Support / repair paths:

- `STEMwerk: Setup`
- `STEMwerk: Save Support Bundle` (action for `STEMwerk_Save_Support_Bundle.lua`)

Optional setup convenience:

- `STEMwerk_Setup_Toolbar.lua`
