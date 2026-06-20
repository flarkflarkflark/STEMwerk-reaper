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

- Added Windows DrumSep CUDA runtime support via a dedicated CUDA runtime environment.
- Preserved Windows DirectML runtime support and DirectML fallback.
- Hardened Windows DrumSep runtime setup and state reporting.
- Improved Windows NVIDIA device/runtime selection and scheduler markers.

## Diagnostics and support bundles

- Support bundles now surface clearer backend/runtime state for CUDA, DirectML, and CPU fallback.
- Support bundles now include `ready_to_go.env` markers for prefetched core model cache state and DrumSep ready/runtime state.
- Processing summaries report runtime/backend, output validation, and pass/fail state more accurately.

## Pre-release live smoke plan

- Release must stay blocked until live smoke evidence is captured per available target system with support bundles and latest run ids.
- Required systems before release:
  - Windows NVIDIA RTX 3060 / CUDA: `READY_TO_GO_SMOKE_PASS` or `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Linux AMD RX 9070 / ROCm: `READY_TO_GO_SMOKE_PASS` or `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - macOS Apple Silicon / MPS: `READY_TO_GO_SMOKE_PASS` or `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Windows AMD DirectML / RX 9070: `READY_TO_GO_SMOKE_PASS` or `READY_TO_GO_SMOKE_PASS_WITH_NOTES` if available before release
  - Linux NVIDIA CUDA laptop: optional if available, otherwise `NOT_TESTED`
- Per system, prove after Setup/Repair/Prepare Ready-to-Go:
  - `ready_to_go.env` exists
  - `READY_TO_GO_STATUS=ok`
  - `CORE_MODEL_FAST_STATUS=ok`
  - `CORE_MODEL_QUALITY_STATUS=ok`
  - `CORE_MODEL_6STEM_STATUS=ok`
  - `DRUMSEP_READY_MODEL_STATUS=ok`
  - matching DrumSep runtime status is `ok`
  - first real run does not trigger a large Demucs, DrumSep, or runtime download/rebuild
- Minimal workflow smokes per system:
  - Normal stems: auto/default, one short audio item
  - Direct Kit / Z: auto/default, one short audio item, expect six drum outputs
  - Kit Split / X: auto/default, one short audio item, expect stage1 normal drums extraction, stage2 DrumSep, and six drum outputs
- Log/support-bundle download prevention checks:
  - no new Demucs model download on first run
  - no DrumSep CKPT/YAML download on first run
  - no `drumsep_model_download_failed`
  - no `drumsep_cache_error`
  - no runtime rebuild/download on first run
- Report per system:
  - exact system/OS/backend
  - setup command or action
  - support bundle path
  - latest run id and workflow ids
  - timings and output validation
  - requested/effective device
  - ready-to-go markers and status lines
  - proof that first run did not perform a large download
  - warnings, regressions, and final verdict
- Release verdict values:
  - `PRE_RELEASE_SMOKE_MATRIX_PASS`
  - `PRE_RELEASE_SMOKE_MATRIX_PASS_WITH_NOTES`
  - `PRE_RELEASE_SMOKE_MATRIX_BLOCKED`

## Known notes

- In 2.3 terminology, smaller offline installers can still download required runtime/model assets, while bundled installers include Python + FFmpeg. Existing allmodels/Demucs core assets are not complete DrumSep/Drum Kit offline/full bundles. DrumSep runtimes and model assets are handled by setup/runtime routes unless a specific full/offline asset explicitly says otherwise.
- Windows DrumSep CUDA cap4 is not the default in 2.3; it remains an advanced/post-2.3 performance topic.
- Windows Kit Split stage2 remains cap1 where Windows locking/fcntl support is unavailable.
- Some support bundles may include historical failed runs; the latest processing summary and current run markers are the source of truth.
- Broad Windows test-harness cleanup remains separate from the release payload.
