# Linux ROCm Unified Runtime Cleanup

Date: `2026-07-15`
Main HEAD: `088bb9a5cca04662b704de875d07e520356d17f2`

## Context

This note records the completed migration from the dedicated Linux ROCm DrumSep
runtime to the unified STEMwerk main runtime. The work was performed as a
controlled sequence with eligibility checks, a reversible quarantine, repair
validation, and a final post-delete smoke test.

The deleted runtime was legacy fallback state only. No repository artifacts,
models, installers, releases, or tags were removed or rebuilt as part of the
cleanup.

## Timeline

1. PR #78 upgraded the Linux main runtime to `audio-separator 0.44.3`, NumPy 2,
   and the compatible SciPy, Numba, llvmlite, and ROCm Torch stack.
2. PR #79 added the DKS catalog and cache migration required by
   `audio-separator 0.44.3`.
3. PR #80 changed the Linux ROCm DKS parent route to prefer the main runtime
   when its capability probe passes, reporting `dks_runtime_selection=main_unified`.
4. PR #81 guarded normal Linux setup and repair so a DKS-capable unified main
   runtime prevents automatic creation or rebuild of `.venv-drumsep-rocm`.

## Eligibility Audit

The final eligibility rerun produced:

`LEGACY_DKS_RUNTIME_CLEANUP_ELIGIBLE`

The production main runtime was verified with:

- `audio-separator 0.44.3`
- `numpy 2.4.4`
- `scipy 1.18.0`
- `numba 0.66.0`
- `llvmlite 0.48.0`
- `torch 2.10.0+rocm7.0`
- `torchaudio 2.10.0+rocm7.0`
- `torchvision 0.25.0+rocm7.0`
- `onnxruntime 1.27.0`
- clean `pip check`
- HIP `7.0.51831`
- successful `cuda:0` tensor allocation on an AMD Radeon RX 9070

The parent-route DKS smoke selected the main runtime and produced all six
canonical outputs: `kick`, `snare`, `toms`, `hi-hat`, `ride`, and `crash`.

## Quarantine And Repair Guard

The legacy runtime was first renamed, not deleted:

`/home/flark/.local/share/STEMwerk/.venv-drumsep-rocm.legacy-quarantine-20260715-043721`

The quarantine phase produced:

`LEGACY_DKS_RUNTIME_QUARANTINE_PASS`

Validation covered:

- baseline parent-route DKS smoke before the rename
- parent-route DKS smoke with the legacy path absent
- normal Linux bootstrap repair with the legacy path absent
- a final parent-route DKS smoke after repair

Repair rebuilt and revalidated the main runtime but did not recreate the legacy
runtime. The resulting state recorded:

```text
DRUMSEP_ROCM_RUNTIME_STATUS=unified_main
DRUMSEP_ROCM_RUNTIME_SELECTION=main_unified
DRUMSEP_ROCM_LEGACY_RUNTIME_STATUS=missing
DRUMSEP_ROCM_LEGACY_INSTALL_SKIPPED=main_unified_ready
```

The explicit `drumsep-rocm-runtime` setup action remains available as a manual
fallback path. Normal setup and repair no longer create that runtime while the
main unified capability probe passes.

## Final Delete

After quarantine and repair validation passed, only the exact timestamped
quarantine directory was deleted. The original legacy path was already absent
and remained absent:

`/home/flark/.local/share/STEMwerk/.venv-drumsep-rocm`

Measured cleanup result:

- freed: `13,931,696,128` bytes
- STEMwerk runtime base before: `31G`
- STEMwerk runtime base after: `18G`

Audit output is retained at:

`/home/flark/stemwerk-rnd/legacy-drumsep-rocm-final-cleanup-20260715-045207`

## Post-Delete Smoke

The production parent-route DKS smoke passed after the final delete:

```text
dks_runtime_selection=main_unified
dks_runtime_python=/home/flark/.local/share/STEMwerk/.venv/bin/python
dks_legacy_fallback_available=false
audio_separator_version=0.44.3
backend_runtime=rocm
model_device=cuda:0
expected_drum_outputs=6
actual_drum_outputs=6
```

All six output files were present and non-empty. No legacy runtime was recreated.

## Final Runtime State

- the Linux ROCm main `.venv` is the active normal-stems and DKS runtime
- `.venv-drumsep-rocm` is absent
- the timestamped quarantine is absent
- DKS selects `main_unified` without a legacy fallback
- setup and repair record the unified runtime and skip legacy installation
- model caches and repository-local `artifacts/` remain untouched

## Follow-Ups

- complete NVIDIA S1/S2 coverage and CUDA bootstrap validation
- close the `diffq`/Cython wheelhouse gap
- reconfirm and pin Linux NVIDIA behavior with `audio-separator 0.44.3`
- recover and document exact supported macOS dependency versions
- continue model-pack and model-manager work
