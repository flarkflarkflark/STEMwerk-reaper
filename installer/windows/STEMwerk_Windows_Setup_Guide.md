# STEMwerk Windows Setup Guide

This guide is for the Windows installer build of STEMwerk.

## What the installer just did

The Windows installer:

- copied the STEMwerk REAPER scripts into your REAPER Scripts folder
- prepared the STEMwerk runtime under your local Windows profile
- created or updated the Python environment used by STEMwerk
- checked FFmpeg and installed the core Python packages

In the normal Windows flow, this installer is the bootstrap step.

## Offline installer flavors (GPU)

If you downloaded an offline bundled installer, the filename tells you which GPU runtime is included:

- `offline-bundled-nvidia`: CUDA wheels for NVIDIA GPUs.
- `offline-bundled-amd`: DirectML wheels for AMD/Intel GPUs.

If the installer cannot verify a GPU runtime, STEMwerk will fall back to CPU.

## What to do next

1. Open REAPER.
2. Open the Action List.
3. If STEMwerk is not visible yet, use `Actions -> ReaScript -> Load ReaScript...`.
4. Browse to `REAPER/Scripts/STEMwerk-reaper/`.
5. Load `STEMwerk.lua`.
6. Run `Stemwerk: Main`.

Optional:

- Load `STEMwerk_Setup_Toolbar.lua` to register the standard STEMwerk actions in the Action List.
- Load the quick presets if you want one-click actions such as Karaoke, Vocals Only, Drums Only, Bass Only, or All Stems.

## Important Windows note

On Windows, `STEMwerk-SETUP.lua` does not replace the installer bootstrap.

If something is missing or the runtime is incomplete:

1. re-run the Windows installer first
2. then check the setup log if needed

## Parallel vs Sequential (Multi-track)
STEMwerk can run multi-track jobs in parallel when Parallel is enabled and more than one job is queued.

It will automatically fall back to Sequential when:
- device = explicit `DirectML` and more than one job is queued
- device = `auto` and no GPU backend is available
- time selection processing splits the work into isolated per-item jobs
- only 1 job is queued

Examples where pure parallel does happen:
- You select 3 tracks with items, no time selection, Parallel on, device = `cuda:0`. -> 3 jobs at once (per track).
- You select 5 tracks, Parallel on, device = `auto`, and a GPU is detected. -> 5 jobs at once.
- You select multiple items across multiple tracks (no time selection), Parallel on, device = `cuda`. -> per-track jobs in parallel.

Examples where it does not run in parallel:
- Parallel on, device = explicit `DirectML`, more than one queued job -> sequential fallback ("DirectML multi-track stability mode").
- Time selection with multiple items on one track -> per-item jobs -> sequential fallback ("Per-item multi-track isolation").
- Parallel on, device = `auto`, but no GPU backend -> sequential fallback ("Auto device, no GPU").
- Only 1 job (1 track) -> sequential by definition.

The progress window shows the active mode and the reason when a fallback happens.

## Open the setup log

The setup log is stored at:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Use it if setup failed, FFmpeg was not detected, or the runtime packages did not finish installing.

## What scripts are for normal use

Normal use:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`

Support / repair paths:

- `STEMwerk: Setup`

## When to use Setup

On Windows, use `STEMwerk: Setup` only as a REAPER-side support or repair path after installation.

For a fresh Windows installation, the installer is the correct setup route.
