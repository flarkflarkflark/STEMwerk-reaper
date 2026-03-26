# STEMwerk Windows Setup Guide

This guide is for the Windows installer build of STEMwerk.

## What the installer just did

The Windows installer:

- copied the STEMwerk REAPER scripts into your REAPER Scripts folder
- prepared the STEMwerk runtime under your local Windows profile
- created or updated the Python environment used by STEMwerk
- checked FFmpeg and installed the core Python packages

In the normal Windows flow, this installer is the bootstrap step.

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
- device = `auto` and no GPU backend is available
- only 1 job is queued

Examples where pure parallel does happen:
- You select 3 tracks with items, no time selection, Parallel on, device = `cuda:0` or `directml`. -> 3 jobs at once (per track).
- You select 5 tracks, Parallel on, device = `auto`, and a GPU is detected. -> 5 jobs at once.
- You select multiple items across multiple tracks (no time selection), Parallel on, device = `cuda`. -> per-track jobs in parallel.
- You select a time range that includes multiple items on one or more tracks, Parallel on, and a GPU backend is available. -> per-item jobs can still run in parallel.

Examples where it does not run in parallel:
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
