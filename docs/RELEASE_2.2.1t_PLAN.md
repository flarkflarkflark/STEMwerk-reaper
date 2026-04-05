# STEMwerk 2.2.1t Windows Validation Build

## Purpose

2.2.1t is a targeted Windows validation build for the REAPER per-item time
selection extraction fix before broader follow-up work continues.

## Fix Included

- Fix the Windows per-item AudioAccessor fallback when REAPER returns an
  item-local accessor range while STEMwerk is still holding a project-time
  request range.
- Translate overlapping project-time item bounds into the accessor's local
  range before sampling.
- Preserve a richer extraction error when AudioAccessor still returns zero
  samples, so request range, sampled range, and accessor bounds remain visible.

## Symptom Addressed

- In time-selection mode with per-item processing, the first media item could
  separate correctly while the second overlapping item failed.
- Typical failing signature before the fix:
  `AudioAccessor rendered 0 samples (requested 213.333333..224.761905, accessor 0.000000..11.428571)`

## Expected Result

- Both overlapping items in the same time selection produce valid extracted
  inputs and stems on Windows.
- Result summary still reports the correct number of source items processed.

## Packaging Notes

- Build a dedicated Windows installer named `STEMwerk-Setup-2.2.1t.exe`.
- Keep the repo baseline version at `2.2.1`; inject `2.2.1t` at installer build
  time through `STEMWERK_VERSION`.

## Validation Target

- Primary follow-up validation target: Windows Nvidia laptop.