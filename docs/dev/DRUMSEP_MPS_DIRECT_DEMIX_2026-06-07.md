# DrumSep MPS Direct Demix Slice

Date: `2026-06-07`
Branch: `feature/direct-dks-linux-integration`
Remote head: `a016f0c`
Base slice commit: `c4043db`

## 1. Problem Statement

`audio-separator 0.23.0` exposes a wrapper path where `MDXCSeparator.separate()` returns only primary/secondary outputs. For DrumSep MDX23C this is insufficient because the desired direct kit mapping needs the explicit per-part outputs (`Kick`, `Snare`, `Toms`, `Hh`, `Ride`, `Crash`) rather than only the wrapper-level primary/secondary pair.

## 2. Solution

Add a hidden experimental macOS Apple Silicon explicit-MPS direct-demix route that bypasses the wrapper-level `separate()` limitation and calls `MDXCSeparator.demix()` directly.

Scope of this slice:

- Direct Kit route
- Kit Split stage 2 route
- explicit MPS request only
- no product-surface default change

## 3. Gate

The direct-demix route is enabled only when all of the following are true:

- platform is `macOS`
- machine arch is `arm64` or `aarch64`
- `requested_device=mps` was explicitly requested
- MPS is built and available
- fallback env is unset
- selected model is the exact DrumSep `MDX23C` model
- `audio-separator==0.23.0`
- route is Direct Kit or Kit Split stage 2

Otherwise the existing behavior remains in place.

## 4. Output Contract

Direct-demix outputs map to the existing STEMwerk filenames/tracks as follows:

- `Kick -> kick`
- `Snare -> snare`
- `Toms -> toms`
- `Hh -> hihat` via `hi-hat.wav`
- `Ride -> ride`
- `Crash -> crash`

Expected result is exactly 6 stems/tracks.

## 5. Policy

- Auto never selects MPS for this slice.
- Linux/ROCm remains on the existing route.
- `b2dd696` wrapper early-fail behavior remains the fallback path.

## 6. Smoke Evidence

Mac MPS Direct Kit PASS:

- run-id: `STEMwerk_1780857082_1780857082072_1`
- `workflow_source=dks_direct`
- `workflow_mode=drumkit`
- `route=direct_demix`
- `requested/effective/backend=mps`
- `model_device=mps:0`
- fallback unset/disabled
- exact 6 stems
- exit `0` / `DONE`
- REAPER import `created=6`

Mac MPS Kit Split PASS:

- run-id: `STEMwerk_1780860697_1780860697163_1`
- stage 1 `htdemucs_ft` explicit MPS
- stage 2 `DrumSep mps-direct-demix`
- `requested/effective/backend=mps`
- `model_device=mps:0`
- exact 6 stems/tracks
- exit `0` / `DONE`
- import `created=6`

Linux/ROCm Direct Kit PASS:

- run-id: `/tmp/STEMwerk_1780863471_34994356_1`
- `workflow_source=dks_direct`
- `workflow_mode=drumkit`
- `backend_device_arg=gpu`
- `drumsep_runtime_selected=rocm`
- MPS gate disabled: `platform_not_darwin`
- 6 outputs: `Kick/Snare/Toms/Hi-Hat/Ride/Crash`

Linux/ROCm Kit Split PASS:

- run-id: `/tmp/STEMwerk_1780863410_34934079_1`
- `workflow_source=dks_extract`
- `workflow_mode=drumkit`
- `dks_extract_stage2_backend=rocm`
- `dks_extract_stage2_runtime=drumsep`
- `drumsep_runtime_selected=rocm`
- MPS gate disabled: `platform_not_darwin`
- 6 outputs: `Kick/Snare/Toms/Hi-Hat/Ride/Crash`

## 7. Tests And Checks

Verified for this slice:

- direct-demix tests: `21 passed, 1 skipped` on Linux
- MPS tests: `11 passed`
- dependency guards: `2 passed`
- `py_compile`: `PASS`
- `luac`: `PASS`
- `version_sync`: `PASS`
- `release_gate`: `PASS`
- `git diff --check`: clean

## 8. Risks

- private lower-level `audio-separator` API use
- array orientation, dtype, and normalization assumptions
- future `audio-separator` updates can break the route or gate assumptions

## 9. Rollback

Disable the direct-demix gate and the old wrapper early-fail path remains active.

## 10. Known Follow-Up

There is an observability inconsistency where the helper result can show `requested_device/backend_runtime=cpu` while the actual runtime selection and effective model device are GPU-backed, for example `drumsep_runtime_selected=rocm`, `effective_device=cuda`, and `model_device=cuda:0`.
