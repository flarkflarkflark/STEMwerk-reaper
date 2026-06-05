# STEMwerk 2.3 X / Drum Kit Split Benchmark Findings

This note captures the current read-only benchmark findings for the STEMwerk 2.3 X / Drum Kit Split route on AMD RX 9070 / ROCm.

Scope:

- route: `workflow_source=dks_extract`
- material: 8 selected short items
- stage 1 benchmark cap request: `STEMWERK_BENCH_GPU_CAP=4`
- stage 2 benchmark cap requests compared: `1`, `2`, `4`
- result quality gate: functional success first, performance comparison second

## Summary

All three benchmark runs were functionally clean:

- `8/8` item runs completed
- all exit codes were `0`
- `48/48` drum outputs were created
- `output_count_mismatch=false`
- no `partial_dks_multi`

Observed wall times:

- stage2 cap1 baseline: `203s`
- stage2 cap2: `139s`
- stage2 cap4: `128s`

Observed gains:

- cap1 -> cap2: `203s -> 139s`
  - `64s` faster
  - about `31.5%` faster
- cap2 -> cap4: `139s -> 128s`
  - `11s` faster
  - about `7.9%` faster

Current interpretation:

- `STEMWERK_BENCH_DKS_STAGE2_CAP=2` is the strongest safe-default candidate for ROCm/CUDA right now.
- `STEMWERK_BENCH_DKS_STAGE2_CAP=4` is clean in one useful run and slightly faster, but should still be treated as high-throughput or experimental until repeated and until GPU/VRAM metrics work.
- no default policy change yet.

## Runs

### 1. Stage2 cap1 baseline

- run-dir:
  - `/home/flark/.cache/STEMwerk/logs/runs/STEMwerk_1780643050_29058355_2`
- benchmark markers:
  - `bench_gpu_cap_applied=4`
  - `bench_dks_stage2_cap_requested=1`
  - `bench_dks_stage2_cap_applied=1`
  - `dks_extract_stage2_effective_cap=1`
  - `dks_extract_stage2_backend=rocm`
  - `drumsep_runtime_selected=rocm`
- output completeness:
  - `8/8 exitcodes 0`
  - `48/48 outputs`
  - `output_count_mismatch=false`
  - `partial_dks_multi=no`
- timing:
  - total wall time: `203s`
- resource notes:
  - `resource_sampling_available=no`
  - `resource_sampling_reason=rocm-smi_parse_failed`
  - CPU avg range: about `17.84 .. 41.77`
  - system RAM peak range: about `18.4 .. 22.0 GB`
  - GPU metrics unavailable
  - VRAM metrics unavailable

### 2. Stage2 cap2

- run-dir:
  - `/home/flark/.cache/STEMwerk/logs/runs/STEMwerk_1780644104_30111948_2`
- benchmark markers:
  - `bench_gpu_cap_applied=4`
  - `bench_dks_stage2_cap_requested=2`
  - `bench_dks_stage2_cap_applied=2`
  - `dks_extract_stage2_effective_cap=2`
  - `dks_extract_stage2_backend=rocm`
  - `drumsep_runtime_selected=rocm`
- output completeness:
  - `8/8 exitcodes 0`
  - `48/48 outputs`
  - `output_count_mismatch=false`
  - `partial_dks_multi=no`
- timing:
  - total wall time: `139s`
- resource notes:
  - `resource_sampling_available=no`
  - `resource_sampling_reason=rocm-smi_parse_failed`
  - CPU avg range: about `35.88 .. 45.12`
  - system RAM peak range: about `22.1 .. 23.9 GB`
  - GPU metrics unavailable
  - VRAM metrics unavailable

### 3. Stage2 cap4

- run-dir:
  - `/home/flark/.cache/STEMwerk/logs/runs/STEMwerk_1780644821_30828768_2`
- benchmark markers:
  - `bench_gpu_cap_applied=4`
  - `bench_dks_stage2_cap_requested=4`
  - `bench_dks_stage2_cap_applied=4`
  - `dks_extract_stage2_effective_cap=4`
  - `dks_extract_stage2_backend=rocm`
  - `drumsep_runtime_selected=rocm`
- output completeness:
  - `8/8 exitcodes 0`
  - `48/48 outputs`
  - `output_count_mismatch=false`
  - `partial_dks_multi=no`
- timing:
  - total wall time: `128s`
- resource notes:
  - `resource_sampling_available=no`
  - `resource_sampling_reason=rocm-smi_parse_failed`
  - CPU avg range: about `45.46 .. 51.40`
  - system RAM peak range: about `24.5 .. 24.7 GB`
  - GPU metrics unavailable
  - VRAM metrics unavailable

## Comparison

| Run | Stage1 cap | Stage2 requested | Stage2 applied | Backend | Wall time | Result |
| --- | --- | --- | --- | --- | ---: | --- |
| cap1 baseline | 4 | 1 | 1 | rocm | 203s | clean |
| cap2 | 4 | 2 | 2 | rocm | 139s | clean |
| cap4 | 4 | 4 | 4 | rocm | 128s | clean |

Interpretation:

- cap2 delivers the largest practical gain over the cap1 baseline.
- cap4 still improves over cap2, but the incremental gain is much smaller.
- CPU and RAM pressure trend upward as stage2 cap increases.

## Resource Sampling Caveat

These benchmark runs were captured before the ROCm resource parser was updated for the current RX 9070 `rocm-smi` concise output.

Observed marker state:

- `resource_sampling_available=no`
- `resource_sampling_reason=rocm-smi_parse_failed`

Implication:

- CPU and system RAM trends are useful
- GPU utilization and VRAM pressure are still unknown for these specific stored runs
- cap4 should not be treated as a safe new default until those GPU-side metrics are trustworthy
- new runs after the parser fix should populate GPU utilization, VRAM total and used, GPU temperature, GPU power, and GPU name when `rocm-smi` returns those fields

## Preliminary Policy Hypothesis

Current working hypothesis for X / Drum Kit Split Stage2 on ROCm or CUDA:

- safe-default candidate:
  - stage2 cap `2`
- high-throughput candidate:
  - stage2 cap `4`

Reasoning:

- cap2 provides a large gain over cap1 with a smaller step-up in host resource pressure
- cap4 is functionally clean and faster, but only modestly faster than cap2 and with visibly higher CPU and RAM demand
- without working GPU/VRAM telemetry, cap4 should remain a benchmark setting rather than a policy default

This is a benchmark interpretation only. It is not a default-policy recommendation yet.

## Next Steps

- repeat the stage2 cap4 run once to check stability of the `128s` result
- rerun one benchmark after the `rocm-smi` parser fix to confirm GPU and VRAM metrics now populate in persisted summaries
- benchmark normal stems cap2 vs cap4 on the same machine
- benchmark Z / Direct Drum Kit cap2 vs cap4 with at least one repeat
- test the same X stage2 cap matrix on other GPUs and platforms before any default policy change
