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
- Processing summaries report runtime/backend, output validation, and pass/fail state more accurately.

## Known notes

- Windows DrumSep CUDA cap4 is not the default in 2.3; it remains an advanced/post-2.3 performance topic.
- Windows Kit Split stage2 remains cap1 where Windows locking/fcntl support is unavailable.
- Some support bundles may include historical failed runs; the latest processing summary and current run markers are the source of truth.
- Broad Windows test-harness cleanup remains separate from the release payload.
