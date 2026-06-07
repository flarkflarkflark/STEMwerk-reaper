# STEMwerk 2.3 Regression Matrix

Date: `2026-06-07`
Branch: `feature/direct-dks-linux-integration`
Scope: merge-prep regression pass after DrumSep/MPS direct-demix slice and ROCm marker alignment

## Status Summary

- repo sanity: `PASS`
- focused regression tests/checks: `PASS`
- root audio in repo root: `PASS` (`none`)
- branch-side Linux managed-runtime smokes: `PASS`
- live REAPER/Linux branch-validating smokes: `SKIPPED`
- macOS MPS direct-demix validation: `ALREADY PROVEN`

## Repo Sanity

Observed:

- branch: `feature/direct-dks-linux-integration`
- `git status --short`: clean
- `git log --oneline -8` includes:
  - `7c2d09a fix(drumsep): align ROCm runtime markers`
  - `2391132 docs(drumsep): add dev note for MPS direct-demix slice`
  - `a016f0c test(drumsep): avoid mandatory soundfile dependency for MPS gate tests`
  - `c4043db feat(drumsep): add experimental MPS direct-demix route`

Checks:

- `python3 -m pytest -q tests/test_drumsep_mps_direct_demix.py`
  - `23 passed, 1 skipped`
- `python3 -m pytest -q tests/test_macos_mps_fallback.py`
  - `11 passed`
- `python3 -m pytest -q tests/test_dependency_constraints.py::test_direct_dks_preflight_flags_audio_separator_0230_runtime_as_backend_limited tests/test_dependency_constraints.py::test_direct_dks_preflight_allows_linux_rocm_runtime_with_six_output_capable_backend`
  - `2 passed`
- `python3 -B -m py_compile scripts/reaper/audio_separator_process.py scripts/reaper/_internal/stemwerk_drumsep_process.py`
  - `PASS`
- `luac -p scripts/reaper/STEMwerk_Save_Support_Bundle.lua`
  - `PASS`
- `luac -p scripts/reaper/STEMwerk.lua`
  - `PASS`
- `find scripts/reaper/_internal -name '*.lua' -print0 | xargs -0 -n1 luac -p`
  - `PASS`
- `python3 tools/version_sync.py --check`
  - `PASS`
  - informational: `tools/STEMwerk_Setup_Guide_Linux_macOS.md: no version marker found`
- `python3 tools/release_gate.py --check`
  - `PASS`
- `git diff --check`
  - clean

Repo root audio check:

- `find . -maxdepth 1 -type f \( -iname '*.wav' -o -iname '*.flac' -o -iname '*.mp3' \) -print`
  - no matches

## Live REAPER Deployment Check

Compared against `~/.config/REAPER/Scripts/STEMwerk-reaper/`:

- `audio_separator_process.py`: `MISMATCH`
- `_internal/stemwerk_drumsep_process.py`: `MISMATCH`
- `STEMwerk_Save_Support_Bundle.lua`: `MATCH`

Observed diffstat against live deploy:

- `audio_separator_process.py`: live copy missing `13` repo lines
- `_internal/stemwerk_drumsep_process.py`: `30` changed lines vs repo copy

Also observed in live REAPER ExtState before any new live smoke:

- `device=cpu`
- `model=htdemucs`
- `active_workflow_mode=stems`
- `active_workflow_source=normal`

Implication:

- running live REAPER quick actions without sync would not validate the exact branch content
- running live REAPER quick actions would also inherit stale in-memory settings rather than a deterministic matrix setup

No sync was performed in this pass.

## Branch-Side Linux Managed Runtime Smokes

Execution method:

- Python: `/home/flark/.local/share/STEMwerk/.venv/bin/python`
- input: `/tmp/stemwerk_regression_20260607/modeltest_10s.wav`
- source clip: trimmed from `/home/flark/Music/modeltest.wav`
- all outputs written under `/tmp/stemwerk_regression_20260607/`

Environment sanity:

- `audio_separator_process.py --check`: `PASS`
- available devices:
  - `auto`
  - `cpu`
  - `cuda:0` = `AMD Radeon RX 9070`

### Normal Stems Matrix

| Case | Status | Run dir | requested_device | selected_device | effective_device | backend/runtime | workflow_source | workflow_mode | created | outputs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| Auto/GPU `htdemucs` | PASS | `/tmp/stemwerk_regression_20260607/normal_auto_htdemucs` | `auto` | `cuda:0` | `cuda:0` | `gpu` | `normal` | `stems` | 4 | `bass, drums, other, vocals` |
| Auto/GPU `htdemucs_ft` | PASS | `/tmp/stemwerk_regression_20260607/normal_auto_htdemucs_ft` | `auto` | `cuda:0` | `cuda:0` | `gpu` | `normal` | `stems` | 4 | `bass, drums, other, vocals` |
| Auto/GPU `htdemucs_6s` | PASS | `/tmp/stemwerk_regression_20260607/normal_auto_htdemucs_6s` | `auto` | `cuda:0` | `cuda:0` | `gpu` | `normal` | `stems` | 6 | `bass, drums, guitar, other, piano, vocals` |
| CPU `htdemucs` | PASS | `/tmp/stemwerk_regression_20260607/normal_cpu_htdemucs` | `cpu` | `cpu` | `cpu` | `cpu` | `normal` | `stems` | 4 | `bass, drums, other, vocals` |
| CPU `htdemucs_ft` | PASS | `/tmp/stemwerk_regression_20260607/normal_cpu_htdemucs_ft` | `cpu` | `cpu` | `cpu` | `cpu` | `normal` | `stems` | 4 | `bass, drums, other, vocals` |
| CPU `htdemucs_6s` | PASS | `/tmp/stemwerk_regression_20260607/normal_cpu_htdemucs_6s` | `cpu` | `cpu` | `cpu` | `cpu` | `normal` | `stems` | 6 | `bass, drums, guitar, other, piano, vocals` |

### Direct Kit Matrix

| Case | Status | Run dir / run-id | requested_device | effective_device | backend_runtime | model_device | drumsep_runtime_selected | MPS gate | route | created | outputs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| Linux/ROCm Direct Kit | PASS | `/tmp/stemwerk_regression_20260607/direct_gpu` | `gpu` | `cuda` | `rocm` | `cuda:0` | `rocm` | `disabled / platform_not_darwin` | wrapper, not direct-demix | 6 | `crash, hi-hat, kick, ride, snare, toms` |
| CPU Direct Kit | PASS | `/tmp/stemwerk_regression_20260607/direct_cpu` | `cpu` | `cpu` | `cpu` | `cpu` | `cpu` | `disabled / platform_not_darwin` | wrapper | 6 | `crash, hi-hat, kick, ride, snare, toms` |
| macOS MPS Direct Kit | ALREADY PROVEN | `STEMwerk_1780857082_1780857082072_1` | `mps` | `mps` | `mps` | `mps:0` | n/a | enabled on mac | `direct_demix` | 6 | import `created=6` |

### Kit Split Matrix

| Case | Status | Run dir / run-id | requested_device | stage1 selected | effective_device | stage2 backend/runtime | model_device | drumsep_runtime_selected | MPS gate | created | outputs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| Linux/ROCm Kit Split | PASS | `/tmp/stemwerk_regression_20260607/kitsplit_gpu` | `gpu` | `cpu` preview fallback | `cuda` | `rocm / drumsep` | `cuda:0` | `rocm` | `disabled / platform_not_darwin` | 6 | `crash, hi-hat, kick, ride, snare, toms` |
| CPU Kit Split | PASS | `/tmp/stemwerk_regression_20260607/kitsplit_cpu` | `cpu` | `cpu` | `cpu` | `cpu / drumsep` | `cpu` | `cpu` | `disabled / platform_not_darwin` | 6 | `crash, hi-hat, kick, ride, snare, toms` |
| macOS MPS Kit Split | ALREADY PROVEN | `STEMwerk_1780860697_1780860697163_1` | `mps` | stage1 explicit MPS | `mps` | `mps / drumsep` | `mps:0` | n/a | enabled on mac | 6 | import `created=6` |

## Policy / Negative Checks

| Check | Evidence | Status |
| --- | --- | --- |
| Auto does not choose MPS | `tests/test_macos_mps_fallback.py` | PASS |
| Linux MPS gate disabled with `platform_not_darwin` | branch-side `direct_gpu`, `direct_cpu`, `kitsplit_gpu`, `kitsplit_cpu`; gate markers present | PASS |
| Linux/ROCm does not use `mps-direct-demix` route | branch-side GPU drumkit runs show gate disabled and no `drumsep_mps_all_targets_route=direct_demix` | PASS |
| Old `audio-separator 0.23.0` wrapper primary/secondary-only route fails as backend-limited | dependency tests targeted in phase 1 | PASS |
| No fake partial kit success | helper/output-count regression tests and dependency constraints | PASS |
| No-stems remains failure | existing log/test coverage in `tests/test_model_failure_classification.py` and `STEMwerk.lua`/`STEMwerk_Log.lua` failure routing | PASS |

## Observability Checks

Confirmed in this pass:

- Linux/ROCm Direct Kit now reports:
  - `drumsep_runtime_selected=rocm`
  - `backend_runtime=rocm`
  - `requested_device=gpu`
  - `effective_device=cuda`
  - `model_device=cuda:0`
  - `drumsep_mps_direct_demix_gate=disabled`
  - `drumsep_mps_direct_demix_gate_reason=platform_not_darwin`
- Linux/ROCm Kit Split stage 2 now reports:
  - `dks_extract_stage2_backend=rocm`
  - `dks_extract_stage2_runtime=drumsep`
  - `dks_extract_stage2_device=rocm`
  - `dks_extract_stage2_requested_device=gpu`
  - `drumsep_runtime_selected=rocm`
  - `backend_runtime=rocm`
  - `requested_device=gpu`
  - `effective_device=cuda`
  - `model_device=cuda:0`

Remaining observability caveat seen locally:

- `kitsplit_gpu` still logs stage 1 preview/fallback markers as:
  - `dks_extract_stage1_device=cpu`
  - `dks_extract_stage1_fallback_reason=live_runtime_cpu_only`
  - `STEMWERK_DIAG selected_device=cpu`
- while stage 2 helper/runtime is cleanly GPU-backed:
  - `backend_runtime=rocm`
  - `effective_device=cuda`
  - `model_device=cuda:0`

Interpretation:

- the original DrumSep helper/result inconsistency is fixed
- there is still a separate shorthand/device-preview inconsistency for stage 1 when the request is literal `gpu`

## Existing Proven REAPER Evidence

Already proven before this pass and retained as merge-prep evidence:

- Mac Direct Kit MPS PASS:
  - `STEMwerk_1780857082_1780857082072_1`
- Mac Kit Split MPS PASS:
  - `STEMwerk_1780860697_1780860697163_1`
- Linux/ROCm Direct Kit PASS:
  - `/tmp/STEMwerk_1780863471_34994356_1`
- Linux/ROCm Kit Split PASS:
  - `/tmp/STEMwerk_1780863410_34934079_1`

## REAPER/Linux Smokes In This Pass

Live REAPER smoke execution on this machine was not performed in this pass.

Reason:

- live REAPER deployment for the two Python files did not match repo
- live REAPER ExtState was not in a deterministic branch-validation configuration
- running quick actions without sync would validate stale deployed code rather than the branch

If a follow-up pass wants true live REAPER validation, the minimal sync set is:

- `scripts/reaper/audio_separator_process.py`
- `scripts/reaper/_internal/stemwerk_drumsep_process.py`

Destination:

- `~/.config/REAPER/Scripts/STEMwerk-reaper/`

## Blockers / Risks / Follow-Up

Blocking for strict local live REAPER signoff:

- live REAPER deploy mismatch prevented branch-accurate MCP smoke execution in this pass

Non-blocking:

- stage 1 `gpu` shorthand on Linux Kit Split still previews/logs as CPU before the GPU-backed stage 2 path runs
- no local support bundle was generated in this pass

## Bottom Line

- branch code and targeted test gates are green
- branch-side Linux managed-runtime smokes are green for normal stems, Direct Kit, and Kit Split
- macOS MPS direct-demix remains already proven
- local live REAPER validation is still pending a minimal two-file sync to the REAPER resource install
