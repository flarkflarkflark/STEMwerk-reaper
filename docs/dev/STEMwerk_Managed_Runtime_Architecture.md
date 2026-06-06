# STEMwerk Managed Runtime Architecture

## 1. Scope

This document is a planning and design note for STEMwerk managed runtime bundles and a possible future native REAPER extension direction.

- No `2.3` runtime or setup behavior is changed by this note.
- ReaPack remains script-first.
- The AI backend remains Python + `torch` + `audio-separator`.
- Native extension work is future / R&D, not part of the current implementation slice.

## 2. Current Architecture Map

- ReaPack payload is script-first.
- `scripts/reaper/STEMwerk-SETUP.lua` routes into the internal runtime and setup logic.
- Runtime state lives in an OS-specific `runtimeBase` with `bootstrap.env`, `capabilities.env`, logs, and `.venv`.
- macOS currently relies on online `pip` installation plus system FFmpeg detection.
- Linux currently uses managed Python, online `pip`, and `imageio-ffmpeg` as a fallback FFmpeg path.
- Windows is installer-first and already has stronger bundled/offline wheel support.
- Linux and macOS packaging are currently still mostly script payload delivery rather than fully managed runtime delivery.

Current architecture touchpoints:

- ReaPack payload and entry scripts:
  `scripts/reaper/STEMwerk.lua`, `scripts/reaper/STEMwerk-SETUP.lua`, `scripts/reaper/STEMwerk-Support.lua`
- Setup/runtime orchestration:
  `scripts/reaper/_internal/STEMwerk_Setup_Internal.lua`, `scripts/reaper/_internal/STEMwerk_Runtime.lua`, `scripts/reaper/_internal/STEMwerk_Versioning.lua`
- Python bootstrap/install:
  `scripts/reaper/_internal/bootstrap_runtime.py`, `scripts/reaper/_internal/bootstrap_shared.py`, `scripts/reaper/_internal/bootstrap_mac.py`, `scripts/reaper/_internal/bootstrap_linux.py`, `scripts/reaper/_internal/bootstrap_windows.py`
- Backend runtime:
  `scripts/reaper/audio_separator_process.py`, `scripts/reaper/vendor/stemwerk-core/...`
- Support bundle:
  `scripts/reaper/STEMwerk_Save_Support_Bundle.lua`
- Release/ReaPack packaging:
  `tools/version_sync.py`, `tools/release_gate.py`, release packaging scripts, `index.xml`

## 3. Drift Risks

- Platform backend version skew.
  Windows `audio-separator` / `torch` differs from macOS/Linux today.
- macOS system/Homebrew FFmpeg dependency.
- macOS/Linux online `pip` drift.
- Duplicated managed Python metadata across bootstrap/setup files.
- No unified runtime manifest for the selected runtime asset and installed dependency set.
- Support bundle does not yet capture selected runtime asset identity, hashes, or manifest verification state.

Observed drift-control points already present in the repo:

- `torch` pinning and platform-specific backend handling in bootstrap/runtime install logic.
- `numpy` pinning in Python dependency constraints.
- `samplerate` guard logic for platform/architecture compatibility.
- `audio-separator` constraints and version shaping in platform-specific install flows.

These controls reduce breakage, but they are still distributed across multiple scripts rather than described by one runtime asset + manifest contract.

## 4. Recommended Path

### `2.3`

- Do not ship a native extension.
- Do not make MPS public or default.
- Keep ReaPack script-only.
- Keep the current Python/`torch`/`audio-separator` backend architecture.
- Optionally prepare manifest/logging hooks if they can land without changing product behavior.
- If any MPS work exists in parallel, keep it hidden/experimental only.

### `2.4`

- Introduce platform-specific managed runtime assets containing Python + FFmpeg + wheelhouse + manifest + hashes.
- Normalize backend stack versions across platforms where practical.
- Add support bundle capture for runtime manifest and manifest verification results.
- Treat a later native REAPER extension as a thin frontend/supervisor layer, not as a Demucs/`torch` replacement.

## 5. ReaPack Compatibility

- No large runtime binaries in `index.xml`.
- ReaPack should only deliver Lua/bootstrap/helpers/runtime descriptor metadata.
- Runtime assets should ship as release assets, installers, or pre-staged payloads outside the ReaPack index.
- Script-first delivery remains the compatibility anchor: install/update via ReaPack, acquire heavier runtime assets via setup/runtime bootstrap.

## 6. Runtime Manifest Proposal

Proposed manifest fields:

- `runtime_manifest_version`
- `selected_runtime_asset_id`
- `platform`
- `arch`
- `python_source`
- `python_version`
- `python_hash`
- `ffmpeg_source`
- `ffmpeg_version`
- `ffmpeg_hash`
- `wheelhouse_id`
- `wheelhouse_hash`
- `backend_stack_id`
- `torch_version`
- `audio_separator_version`
- `numpy_version`
- `samplerate_version`
- `manifest_hash_ok`
- `installed_asset_hash_ok`
- `bootstrap_manifest_version`

Intent:

- One manifest describes exactly which runtime asset was selected.
- Bootstrap/setup verifies the selected asset and installed files against hashes.
- Support output can report drift as a manifest mismatch instead of an inferred package mismatch.

## 7. Support Bundle Additions

Planned additions for managed runtime rollout:

- `runtime_manifest.json`
- `runtime_manifest_verify.txt`
- manifest status summary in `diagnostics.txt`
- explicit drift reason when mismatch is detected

Recommended diagnostics lines:

- selected runtime asset id
- runtime manifest version
- manifest hash verification result
- installed asset hash verification result
- backend stack id
- Python source/version/hash
- FFmpeg source/version/hash
- wheelhouse id/hash
- drift reason when validation fails

## 8. Platform Risks

### macOS

- notarization and quarantine handling for downloaded runtime assets
- separate `arm64` and `x86_64` runtime assets
- `samplerate` architecture mismatch risk
- current system/Homebrew FFmpeg dependency is a user-machine drift source
- MPS should remain hidden/research-only unless later explicitly exposed behind an experimental flag

### Linux

- `glibc` vs `musl` portability
- distro FFmpeg differences
- fragmented GPU stack expectations across CUDA / ROCm / CPU
- wheel compatibility and native dependency expectations vary across distributions

### Windows

- installer-first flow is already stronger for offline delivery
- backend version skew versus macOS/Linux still creates medium-term maintenance drift
- harmonizing backend stack timing must be planned to avoid destabilizing the existing installer path

## 9. Native Extension Future Direction

Possible binary names:

- `reaper_stemwerk.so`
- `reaper_stemwerk.dylib`
- `reaper_stemwerk-x64.dll`

Likely role:

- setup
- status
- job launch
- process supervision
- progress bridge
- support bundle bridge
- import bridge

Not the first-version role:

- not embedding Demucs/`torch`
- not replacing the Python runtime
- not changing the core AI backend stack in the first native-extension slice

Pragmatic direction:

- Start as a thin frontend/supervisor around the Python runtime.
- Prefer IPC-first architecture initially.
- Keep the Python backend as the source of truth for separation behavior until managed runtimes are stable.

## 10. Open Questions

- Should macOS/Linux runtime assets ship inside installers/packages or download during setup?
- On macOS, should FFmpeg be bundled directly or managed via `imageio-ffmpeg`?
- Is Linux offline wheelhouse a `2.3` stretch goal or a `2.4` target?
- When should Windows backend-stack harmonization happen?
- Should a future native extension start IPC-first or C ABI-first?

## File-Level Implementation Plan

This is a planning map only. No files are changed by this note beyond the document itself.

### A. Bundled Python

- `scripts/reaper/_internal/bootstrap_runtime.py`
- `scripts/reaper/_internal/bootstrap_shared.py`
- `scripts/reaper/_internal/bootstrap_mac.py`
- `scripts/reaper/_internal/bootstrap_linux.py`
- `scripts/reaper/_internal/bootstrap_windows.py`
- `scripts/reaper/_internal/STEMwerk_Setup_Internal.lua`
- `scripts/reaper/_internal/STEMwerk_Runtime.lua`

### B. Bundled FFmpeg

- `scripts/reaper/_internal/bootstrap_mac.py`
- `scripts/reaper/_internal/bootstrap_linux.py`
- `scripts/reaper/_internal/bootstrap_windows.py`
- FFmpeg detection helpers in Lua setup/runtime modules
- any support-bundle diagnostics that report FFmpeg provenance

### C. Offline wheelhouse

- platform bootstrap scripts
- Python dependency constraints / requirements inputs
- Windows installer/release packaging scripts
- future Linux/macOS runtime-asset packaging scripts

### D. Runtime manifest + hash validation

- bootstrap/install scripts
- runtime state writer/reader in Lua setup/runtime modules
- support bundle diagnostics writer
- release asset packaging metadata generation

### E. Platform-specific runtime asset

- release packaging scripts
- setup/runtime asset-selection logic
- version/release gates
- support bundle reporting

### F. Experimental MPS runtime flag

- device capability detection in Lua and Python
- setup diagnostics/support output
- hidden/experimental settings exposure only

This remains separate from managed-runtime bundling and should not drive `2.3` runtime-asset scope.

### G. Native REAPER extension frontend

- future native extension project folder/build system
- thin IPC/supervisor bridge into the Python backend
- setup/status/progress/support-bundle integration points in Lua

## Short-Term and Medium-Term Recommendation

Best short-term path for `2.3`:

- keep product behavior stable
- avoid native extension work
- avoid public/default MPS exposure
- keep ReaPack script-first
- optionally add non-behavioral manifest/logging hooks only if low-risk

Best medium-term path for `2.4`:

- ship platform-specific managed runtime assets
- bundle Python + FFmpeg + wheelhouse + manifest + hashes
- reduce online `pip` and machine-local FFmpeg dependence
- normalize backend stacks where practical
- extend support bundles with manifest verification
- revisit native extension only after runtime asset flow is stable

## Explicitly Out of Scope for `2.3`

- shipping a native REAPER extension
- moving Demucs/`torch` out of Python
- putting large runtime binaries into ReaPack/index payloads
- making MPS public/default
- a full macOS/Linux managed-runtime rollout if it forces behavior risk late in the cycle
