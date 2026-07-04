# STEMwerk 2.3.0.0

## Highlights

STEMwerk 2.3 expands GPU/runtime coverage across macOS, Linux, and Windows, and promotes the Drum Kit workflows to release-ready status.

## New acceleration backends

- macOS Apple Silicon MPS support for normal stems and Drum Kit workflows.
- Linux AMD ROCm support for accelerated separation.
- Linux NVIDIA CUDA support.
- Windows AMD DirectML support.
- Windows NVIDIA CUDA support for normal stems and DrumSep-based Drum Kit workflows.
- DirectML and CPU fallback paths remain available.

## Drum Kit workflows

- Direct Kit / Z is validated across the current 2.3 matrix.
- Kit Split / X is validated with platform-specific scheduler behavior.
- Windows NVIDIA Direct Kit uses DrumSep CUDA with a conservative cap2 default.
- Windows NVIDIA Kit Split uses stage1 CUDA cap2 and stage2 DrumSep CUDA cap1 where Windows locking/fcntl support is unavailable.
- CPU fallback remains available for supported workflows.

## Windows setup/runtime

- `STEMwerk-2.3.0.0-update-patch.exe` is the smaller update path for an existing STEMwerk installation.
- This patch is not a full offline all-models installer; for fully offline setup, use one of the offline bundled allmodels installers.
- Windows uninstall now removes STEMwerk runtime data and installed STEMwerk REAPER scripts cleanly.
- Added Windows DrumSep CUDA runtime support via a dedicated CUDA runtime environment.
- Preserved Windows DirectML runtime support and DirectML fallback.
- Hardened Windows DrumSep runtime setup and state reporting.
- Improved Windows NVIDIA device/runtime selection and scheduler markers.
- Installer license text is now aligned to `2.3.0.0` / `2026-06-22`.
- Normal/core Demucs aliases are now translated to concrete `audio-separator 0.24.4` model ids before load/prefetch: `htdemucs.yaml`, `htdemucs_ft.yaml`, `htdemucs_6s.yaml`.
- Windows capabilities writes are now atomic; outdated `capabilities.env` is removed on write failure.
- Required capabilities write failures now force `STATUS=deps_failed` / `REASON=capabilities_write_failed` instead of leaving contradictory ready-state markers behind.
- Unsupported internal model ids are now classified as `model_mapping_failed` rather than as internet/DNS/proxy download failures.
- Direct Kit success dialogs no longer leak the placeholder-style `result method line` text.
- Windows normal CPU multi-item processing now restores the intended `cap2` scheduler policy for the `normal` route instead of falling back to the generic low-resource sequential gate.
- Windows DrumSep ready-state writers now persist to the dedicated runtime state files, so `ready_to_go` reporting no longer remains `missing` after successful DrumSep verify.

## Diagnostics and support bundles

- Support bundles now surface clearer backend/runtime state for CUDA, DirectML, and CPU fallback.
- Support bundles now include `ready_to_go.env` markers for prefetched core model cache state and DrumSep ready/runtime state.
- Processing summaries report runtime/backend, output validation, and pass/fail state more accurately.

## Final source and artifact basis

- Final source HEAD: `3051afc50205b9340900c32a468e0716bf4535c4`
- Current artifact inventory: `/mnt/PRODUCTION/stemwerk-build-evidence/STEMWERK_2300_ARTIFACT_INVENTORY_CURRENT.txt`
- Current SHA256 manifest: `/mnt/PRODUCTION/stemwerk-build-evidence/STEMWERK_2300_SHA256SUMS_CURRENT.txt`
- Artifact verification status:
  - Windows current artifacts verified against local files and current SHA256 inventory
  - macOS public artifacts verified
  - Linux full native offline packaging deferred unless explicitly included
- Runtime/UI notes:
  - Windows DirectML UI labels now show `RX 9070` and `780M` instead of generic DirectML entries.
  - Windows DirectML startup no longer flashes a transient generic `DirectML`/`GPU` button when cached named devices are available.
- Release blockers:
  - No current runtime/workflow blocker remains in the accepted Windows and macOS release set.
  - Linux full native offline packaging remains deferred and should not be presented as included unless those artifacts are explicitly published.

## Publication exceptions

- Linux ROCm/AMD offline allmodels `.deb` is excluded.
  - reason: `dpkg-deb: error: ar member size 10310026300 too large`
  - use the Linux ROCm offline `AppImage`, `RPM`, or `pkg.tar.zst` instead
- macOS `STEMwerk-2.3.0.0-bundled-apple-silicon.pkg` is excluded.
  - reason: redundant/misleading; payload effectively identical to offline allmodels
- macOS publication set:
  - publish `STEMwerk-2.3.0.0.pkg`
  - publish `STEMwerk-2.3.0.0-offline-bundled-apple-silicon-mps-allmodels.pkg`

## Publication state

- Artifact build and verification: done
- Upload plan:
  - smaller/normal artifacts to GitHub
  - large offline installers to Google Drive
- Verify downloads with SHA256 before installing.
- Still not performed:
  - tag
  - GitHub release
  - ReaPack publish
  - installer upload/publish

## Known notes

- In 2.3 terminology, the smaller update path can still download required runtime or model assets, while bundled installers include Python and FFmpeg.
- The offline allmodels CPU, NVIDIA, and AMD variants are intended to complete setup offline for their target backend.
- Large offline all-model installers are hosted externally on Google Drive due to file size.
- Linux full native offline packaging remains deferred if it is not included in a specific release bundle.
- Windows DrumSep CUDA cap4 is not the default in 2.3; it remains an advanced/post-2.3 performance topic.
- Windows Kit Split stage2 remains cap1 where Windows locking/fcntl support is unavailable.
- Some support bundles may include historical failed runs; the latest processing summary and current run markers are the source of truth.
- Broad Windows test-harness cleanup remains separate from the release payload.
