# STEMwerk 2.3.0.5 Release Notes

Status: release planning. No tag, release, or installer build has been created.

## Highlights

### Linux ROCm unified runtime

- The managed main `.venv` handles normal stems, Viperx, and Direct Kit/DKS.
- The legacy `.venv-drumsep-rocm` was removed only after quarantine, repair-guard validation, and a successful post-delete parent-route smoke.
- Normal setup and repair no longer recreate the legacy runtime while the unified main-runtime capability probe passes.

### Linux NVIDIA/CUDA

- Current-main bootstrap passed with audio-separator 0.44.3.
- CUDA processing passed for `htdemucs`, `htdemucs_ft`, and `htdemucs_6s`.
- An invalid `cuda:9` request failed explicitly without silent CPU fallback.

### Linux wheelhouse completeness

- Full CPU, CUDA, and ROCm wheelhouse download gates passed.
- Cython 3.2.8 and diffq 0.2.4 are present in every Linux wheelhouse target.

### macOS Apple Silicon

- The managed main runtime uses audio-separator 0.44.3 and NumPy 2.4.4.
- Normal-stems MPS processing and `pip check` passed.
- Viperx on an 8 GB M1 is classified as CPU-only acceptable: CPU processing passed, while explicit MPS ran out of memory.

### macOS installer

- AppleDouble `._*` sidecars are excluded from package staging and the final BOM/Payload flow.

### Model, device, and runtime behavior

- The model registry now supplies validated metadata to the runtime and Lua UI.
- Device requests are normalized before processing.
- Invalid GPU requests fail explicitly instead of silently changing to CPU.
- Dependency runtime probes are platform-aware while static dependency-policy checks remain hard.
- Optional REAPER toolbar icons and actions make the existing Direct Kit and Kit Split workflows easier to access.

## Platform Evidence

- #78: Linux ROCm main runtime audio-separator 0.44.3 and NumPy 2 migration
- #79: DKS catalog and cache migration
- #80: Linux ROCm parent-route `main_unified` selection
- #81: setup/repair guard against automatic legacy runtime recreation
- #82: Linux ROCm unified runtime cleanup evidence
- #83: Linux NVIDIA/CUDA bootstrap and processing evidence
- #84: Linux CPU/CUDA/ROCm wheelhouse completeness
- #85: macOS Apple Silicon audio-separator 0.44.3 runtime update
- #86: macOS installer AppleDouble hygiene
- #87: platform-aware dependency runtime probes

Detailed Linux evidence is recorded in:

- `docs/research/LINUX_ROCM_UNIFIED_RUNTIME_CLEANUP_2026-07-15.md`
- `docs/research/LINUX_NVIDIA_CUDA_BOOTSTRAP_ASEP0443_2026-07-15.md`
- `docs/research/ASEP_0443_PIN_MATRIX_2026-07-14.md`

## Known Limitations

- Viperx on an 8 GB M1 works on CPU; explicit MPS ran out of memory during validation.
- Drum Kit Separation remains unsupported on macOS Intel; the explicit unsupported policy and messaging remain in place.
- A native Windows current-main smoke is still required before the final tag.
- A macOS Intel current-main setup and normal-stems smoke is recommended before the final tag.

## GUI And Flow Policy

- Users choose the intended result, not an implementation model.
- Do not add one button per model or expose Viperx as a technical model button.
- A possible later user-facing result flow is `Vocals HQ`.
- New models remain hidden unless they are deliberately designed as part of a result-oriented flow.
- The GUI audit is release-blocking only if the current interface misrepresents supported capabilities or expected behavior.

## Pre-Tag Checklist

### Windows native current-main smoke

- [ ] Setup/bootstrap completes on a clean or controlled throwaway runtime.
- [ ] CPU normal-stems processing passes.
- [ ] DirectML and/or CUDA processing is checked where matching hardware is available.
- [ ] DKS status and behavior match the supported Windows runtime policy.
- [ ] Invalid GPU requests do not silently fall back to CPU.

### macOS Intel current-main smoke

- [ ] Setup/bootstrap completes with the supported Intel CPU stack.
- [ ] Normal-stems CPU processing passes.
- [ ] DKS remains blocked with accurate unsupported messaging and state.

### GUI/flow audit

- [ ] Visible buttons and labels match current backend capabilities.
- [ ] No technical model is exposed as a user-facing result without an intentional flow design.
- [ ] No release-blocking mismatch exists between runtime capability and visible guidance.

### Final release gate

- [ ] `python -m pytest -q tests/test_dependency_constraints.py`
- [ ] `python -m pytest -q tests/test_device_normalization.py tests/test_model_registry_schema.py tests/test_macos_mps_fallback.py`
- [ ] `python tools/release_gate.py --check`
- [ ] `git diff --check`
- [ ] All required CI checks are green.
