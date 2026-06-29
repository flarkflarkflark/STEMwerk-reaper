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
- Fixed the Windows installer ready-to-go blocker in `e06507c99e6e336cbbf36892a39c97876d10daa0`, followed by the final verified 2.3 release source and artifact pass documented below.
- Installer license text is now aligned to `2.3.0.0` / `2026-06-22`.
- Normal/core Demucs aliases are now translated to concrete `audio-separator 0.24.4` model ids before load/prefetch: `htdemucs.yaml`, `htdemucs_ft.yaml`, `htdemucs_6s.yaml`.
- Windows capabilities writes are now atomic; stale `capabilities.env` is removed on write failure.
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

- Final source HEAD: `6efdf0152ba1db057f15a3e9e8ec72969f8c2b57`
- Runtime/UI basis: `5c9ab966988d44430a27b666a9a5310e2276b7ba`
- Build-tool fixes after runtime/UI basis:
  - `2547cf40ee860d112463011a8d1b53d9fd02662c`
  - `6efdf0152ba1db057f15a3e9e8ec72969f8c2b57`
- Final artifact manifest: `/mnt/PRODUCTION/stemwerk-build-evidence/stemwerk-linux-windows-final-build-5c9ab96-20260629-035955/STEMwerk-2.3.0.0-crossplatform-artifacts-6efdf015-FINAL-ROCM-DEB-EXCLUDED.txt`
- Artifact verification status:
  - Linux adjusted set verified: `20 files / 19 artifacts`
  - Windows verified unchanged: `6/6`
  - macOS public artifacts verified
- Smoke matrix verdict: `PRE_RELEASE_SMOKE_MATRIX_PASS_WITH_NOTES`
- Platform verdicts:
  - Linux AMD/ROCm: `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - macOS Apple Silicon/MPS: `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Windows NVIDIA CUDA: `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Windows AMD DirectML: `READY_TO_GO_SMOKE_PASS_WITH_NOTES`
- Runtime/UI notes:
  - Windows DirectML UI labels now show `RX 9070` and `780M` instead of generic DirectML entries.
  - Windows DirectML startup no longer flashes a transient generic `DirectML`/`GPU` button when cached named devices are available.
- Release blockers:
  - No current runtime/workflow blocker remains in the smoke matrix.
  - Remaining notes are cache/support-bundle/history/test-environment notes, not runtime blockers.
- Matrix evidence:
  - Linux AMD/ROCm
    - support bundle: `/home/flark/.config/REAPER/STEMwerk-support-bundles/STEMwerk-support-bundle-20260621-050157(.zip)`
    - key runs: Normal `/tmp/STEMwerk_1782010650_17415638_1`; Direct Kit `/tmp/STEMwerk_1782010735_17500740_1`; Kit Split `/tmp/STEMwerk_1782010809_17574772_1`
    - first-run download evidence: no workflow-first-run Demucs, DrumSep, or runtime redownload/rebuild observed after ready-to-go preparation
    - notes: verdict `LINUX_ROCM_READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - macOS Apple Silicon/MPS
    - support bundle: `/Users/flark/Library/Application Support/REAPER/STEMwerk-support-bundles/STEMwerk-support-bundle-20260621-130344(.zip)`
    - key runs: Normal `STEMwerk_1782039594_1782039594734_1`; Direct Kit `STEMwerk_1782039643_1782039643467_1`; Kit Split `STEMwerk_1782039700_1782039700676_1`
    - first-run download evidence: no workflow-first-run Demucs, DrumSep, or runtime redownload/rebuild observed after ready-to-go preparation
    - notes: verdict `MACOS_MPS_READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Windows NVIDIA CUDA
    - support bundle: `C:\Users\Administrator\AppData\Roaming\REAPER\STEMwerk-support-bundles\STEMwerk-support-bundle-20260621-141524(.zip)`
    - key runs: Normal `C:\Users\Administrator\AppData\Local\Temp\STEMwerk_1782043814_2699765_1`; Direct Kit `C:\Users\Administrator\AppData\Local\Temp\STEMwerk_1782043884_2769127_1`; Kit Split `C:\Users\Administrator\AppData\Local\Temp\STEMwerk_1782043947_2831897_1`
    - first-run download evidence: setup/verify proved Windows ready state without redownloading assets before smoke workflows
    - notes: verdict `WINDOWS_NVIDIA_CUDA_READY_TO_GO_SMOKE_PASS_WITH_NOTES`
  - Windows AMD DirectML
    - support bundle: `C:\Users\Administrator\AppData\Roaming\REAPER\STEMwerk-support-bundles\STEMwerk-support-bundle-20260621-224334(.zip)`
    - key runs: Normal `C:\Users\Administrator\AppData\Local\Temp\STEMwerk_1782074547_39966221_1` (`DONE/0`, `normal/stems`, `selected/effective directml:0`, outputs `4/4`); Direct Kit `STEMwerk_1781920635_28708640_1`, `STEMwerk_1781918283_26356207_1`; Kit Split `STEMwerk_1781878333_14341624_1`
    - first-run download evidence: native REAPER smoke completed without workflow-first-run Demucs, DrumSep, or runtime redownload/rebuild
    - notes: Kit Split evidence recorded under `runtime_runs/diagnostics`, `workflow_source=dks_extract`, stage2 `DmlExecutionProvider`; verdict `WINDOWS_AMD_DIRECTML_NATIVE_REAPER_SMOKE_PASS_WITH_NOTES`

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
- Still not performed:
  - tag
  - GitHub release
  - ReaPack publish
  - installer upload/publish

## Known notes

- All Linux and Windows artifacts generated from `21a59cd64686b6cc8c6feca62ac863d8a9e13b6a`, `e06507c99e6e336cbbf36892a39c97876d10daa0`, or `328c614c8adcdc8244c8bb9bf601083907f29032` are stale and superseded by the final verified artifact set documented in the manifest above.
- In 2.3 terminology, smaller offline installers can still download required runtime/model assets, while bundled installers include Python + FFmpeg. Existing allmodels/Demucs core assets are not complete DrumSep/Drum Kit offline/full bundles. DrumSep runtimes and model assets are handled by setup/runtime routes unless a specific full/offline asset explicitly says otherwise.
- Windows DrumSep CUDA cap4 is not the default in 2.3; it remains an advanced/post-2.3 performance topic.
- Windows Kit Split stage2 remains cap1 where Windows locking/fcntl support is unavailable.
- Some support bundles may include historical failed runs; the latest processing summary and current run markers are the source of truth.
- Broad Windows test-harness cleanup remains separate from the release payload.
