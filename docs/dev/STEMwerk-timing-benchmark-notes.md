# STEMwerk Timing Benchmark Notes

This is a developer-only diagnostics helper for comparing STEMwerk timing between sequential and parallel runs.

## Scope

- Measurement only.
- No UI/runtime behavior changes.
- No backend optimization in this step.
- File-based pipeline remains intentional for now.

## Helper script

Use:

`python tools/dev/summarize_stemwerk_timing.py <run_or_job_dir> [<run_or_job_dir> ...]`

Examples:

- `python tools/dev/summarize_stemwerk_timing.py /tmp/STEMwerk_1778694923_31186729_4`
- `python tools/dev/summarize_stemwerk_timing.py /tmp/STEMwerk_1778695397_31660991_2 /tmp/STEMwerk_1778695701_31964909_2`

The helper reads per-job diagnostics files (if present):

- `timing_events.jsonl` (Lua-side timing events)
- `phase_events.jsonl` (Python-side phase events)
- `exit_code.txt`
- `done.txt`
- `stdout.txt` (only for latest progress note)

It prints a per-job table and a run summary with overlap/wallclock indicators.

## Suggested benchmark protocol

1. Set `Temp files` to `Keep`.
2. Use the same audio selection for both runs.
3. Use the same model.
4. Use the same device.
5. Run once with parallel `ON`.
6. Run once with sequential mode (`parallel OFF`).
7. Run the helper on both run directories.
8. Compare:
   - `wallclock_span_s`
   - `model_setup_s`
   - `separate_s`
   - `import_s`
   - `max_python_overlap`

## Interpretation notes

- Meaningful comparison requires identical model/device/audio length and similar system load.
- High `max_python_overlap` with weak wallclock improvement can indicate contention pressure.
- Canceled runs are still useful; helper reports partial rows with `NA` and notes.
- Current objective is diagnostics only (no GPU limiter added in this slice).

## CPU parallel audit

Older exploratory local runs had suggested that unconstrained CPU parallelism could be slower than sequential. Those observations are now superseded for the current narrow policy slice by the live `cap2` validation below.

## Manual DKS integration benchmark

Manual single-system benchmark captured on `feature/direct-dks-linux-integration`
after Direct Kit (Z) and Drum Split (X) were working end-to-end.

Environment:

- Date: 2026-06-03
- STEMwerk UI version shown: `v2.2.2.11`
- OS: Linux / Arch-family EndeavourOS
- CPU: AMD Ryzen 7 7840HS
- GPU: AMD Radeon RX 9070 via ROCm
- Source: one whole track, `3:23.571`
- Mode: Quality
- Output target: 6 drum tracks

Results:

| Route | Device mode | Runtime path | Result | Time | Speed |
| --- | --- | --- | --- | --- | --- |
| X / Drum Split | Auto GPU | Stage 1 normal ROCm `cuda:0`; Stage 2 DrumSep | PASS | `3:04` | `1.11x` realtime |
| Z / Direct Drum Kit | Auto GPU | Direct DrumSep ROCm RX 9070 | PASS | `2:22` | `1.43x` realtime |
| X / Drum Split | CPU | Stage 1 CPU runtime; Stage 2 DrumSep CPU | PASS | `20:04` | `0.17x` realtime |
| Z / Direct Drum Kit | CPU | Direct DrumSep CPU | PASS | `16:27` | `0.21x` realtime |

Interpretation:

- GPU is roughly `6.5x` to `7x` faster than CPU for this whole-track Quality DKS workload on this machine.
- Direct Kit (Z) is faster than Drum Split (X) because X performs a normal extraction stage before DrumSep.
- CPU whole-track DKS should keep conservative concurrency defaults.
- X stage 2 DrumSep serialization remains justified based on earlier parallel stage-2 output-loss observations and this long-track runtime cost.
- Long-track GPU DKS works on RX 9070, but DKS concurrency policy should remain conservative until more systems are measured.

## Normal stems benchmark matrix on RX 9070

Read-only REAPER benchmark matrix captured on Linux with:

- CPU: AMD Ryzen 7 7840HS
- GPU: discrete `AMD Radeon RX 9070` via ROCm/CUDA (`GPU 0`)
- Material: 8 short items
- Route: normal stems
- Device request: `Auto`
- Resource sampling: enabled

Strict PASS gate for every run:

- `workflow_source=normal`
- `workflow_mode=stems`
- `route=normal`
- `stage=single_stage`
- `backend=gpu`
- root summary `device=auto`
- requested/applied/effective/scheduler cap all match
- `8/8 exit_code=0`
- `8/8` non-empty `stdout.txt` JSON stem outputs
- `resource_sampling_available=yes`
- no partial/fail/OOM markers

Results:

| Model | Cap | Result | Wall | VRAM peak | Temp peak | Power peak |
| --- | --- | --- | --- | --- | --- | --- |
| `htdemucs` | `2` | PASS | `40.997s` | `5315 MB` | `71 C` | `262 W` |
| `htdemucs` | `4` | PASS | `25.490s` | `7636 MB` | `76 C` | `226 W` |
| `htdemucs` | `8` | PASS | `27.262s` | `10474 MB` | `79 C` | `292 W` |
| `htdemucs_ft` | `2` | PASS | `50.520s` | `6298 MB` | `75 C` | `229 W` |
| `htdemucs_ft` | `4` | PASS | `34.254s` | `9442 MB` | `80 C` | `268 W` |
| `htdemucs_ft` | `8` | PASS | `49.015s` | `15959 MB / 16304 MB` | `80 C` | `294 W` |
| `htdemucs_6s` | `2` | PASS | `43.490s` | `5127 MB` | `72 C` | `223 W` |
| `htdemucs_6s` | `4` | PASS | `25.110s` | `7292 MB` | `70 C` | `177 W` |
| `htdemucs_6s` | `8` | PASS | `26.195s` | `11048 MB` | `79 C` | `279 W` |

Interpretation:

- cap scaling is functionally correct for all three models on RX 9070
- worker device resolves to `cuda:0`, while the root scheduler summary keeps `device=auto`
- `cap4` is the best current throughput/safety balance for normal stems
- `cap8` is valid, but it does not consistently outperform `cap4` and drives much higher VRAM and power demand
- `htdemucs_ft cap8` is the near-limit case at about `15.96 GB / 16.30 GB` VRAM
- `htdemucs_6s` correctly emits 6 outputs and should not be judged by 4-stem expectations

Provisional policy recommendation for normal stems on discrete AMD ROCm/CUDA GPU:

- `cap4` as the default candidate
- `cap2` as the low-pressure fallback
- `cap8` as benchmark, advanced, or stress-only

Telemetry note:

- the sampler selects the discrete RX 9070 rather than the integrated 780M
- `gpu_temp_peak_c` is the maximum observed temperature during the run, not the final temperature shown after cooldown

## Experimental CPU normal-stems cap2 slice

Separate from the RX 9070 GPU findings above, the current policy candidate for normal stems on `backend=cpu` is:

- `route=normal`
- `stage=single_stage`
- `scheduler_policy_cap=2`
- `effective_parallel_cap=2`

This slice is intentionally narrow:

- no GPU policy change here
- no DirectML change
- no MPS change
- no DKS route change

Status:

- implemented as a code, regression, and live benchmark slice
- live-validated on `htdemucs`, `htdemucs_ft`, and `htdemucs_6s`
- should not be conflated with the separate GPU recommendation of `cap4` as the default candidate

### Sequential vs cap2 live comparison

All six comparison runs were clean:

- `route=normal`
- `stage=single_stage`
- `workflow_source=normal`
- `workflow_mode=stems`
- `device=cpu`
- `backend=cpu`
- `8/8 exit_code=0`
- no partial/fail/OOM markers

Policy markers:

- cap2 runs logged `scheduler_policy_cap=2` and `effective_parallel_cap=2`
- sequential runs logged `scheduler_policy_cap=none` and `effective_parallel_cap=none`

Observed wall times:

| Model | Sequential wall | Cap2 wall | Cap2 gain |
| --- | --- | --- | --- |
| `htdemucs` | `57.436s` | `36.769s` | `20.667s` faster, about `36.0%` less time |
| `htdemucs_ft` | `110.573s` | `88.456s` | `22.117s` faster, about `20.0%` less time |
| `htdemucs_6s` | `65.159s` | `35.930s` | `29.229s` faster, about `44.9%` less time |

Interpretation:

- `cap2` beats sequential on all three normal-stems CPU models in this 8-item test set
- there is no evidence here that sequential is more stable or safer than `cap2`
- `cap2` is therefore the best-supported CPU default candidate within this slice
- CPU `cap4` should not be mixed into this conclusion; treat it as a separate experimental slice if pursued later

Resource-sampling caveat:

- these CPU runs did not persist `resource_summary` or `resource_samples` artifacts, despite the launch env carrying `STEMWERK_BENCH_RESOURCE_SAMPLING=1`
- use this comparison for correctness, policy markers, and wall time only
- do not draw hard thermal or efficiency conclusions from this specific CPU dataset

## Experimental CPU drum-workflow slice

This slice added benchmark-only CPU override hooks for drum workflows:

- `STEMWERK_BENCH_CPU_CAP=1|2|4`
- `STEMWERK_BENCH_DKS_STAGE1_CPU_CAP=1|2|4`
- `STEMWERK_BENCH_DKS_STAGE2_CPU_CAP=1|2|4`

Benchmark override boundary:

- benchmark-only
- CPU backend only
- only when `requestedParallel=true`
- no GPU policy change
- no DirectML change
- no MPS change
- `cap4` remains experimental and safety-gated only

### Direct Kit CPU live benchmark

Dataset:

- branch: `feature/direct-dks-linux-integration`
- route: `dks_direct`
- workflow: `drumkit`
- device/backend: `cpu`
- material: 8 short items

Results:

| CPU cap | Result | Wall | Notes |
| --- | --- | --- | --- |
| `1` | PASS | `343.03s` | clean baseline |
| `2` | PASS | `331.77s` | fastest result |
| `4` | PASS | `501.62s` | much slower than `1` and `2` |

PASS gate:

- `workflow_source=dks_direct`
- `workflow_mode=drumkit`
- `route=dks_direct`
- `stage=single_stage`
- `device=cpu`
- `backend=cpu`
- cap markers matched request
- `8/8 exit_code=0`
- all expected drum outputs present
- no partial, fail, OOM, or error markers

Interpretation:

- Direct Kit CPU benefits from `cap2`
- `cap4` is a stress-only or experimental path, not a default candidate
- the follow-up default-policy slice applies Direct Kit CPU `cap2`

### Kit Split CPU live benchmark

Dataset:

- branch: `feature/direct-dks-linux-integration`
- route: `dks_extract`
- workflow: `drumkit`
- device/backend: `cpu`
- material: 8 short items

Results:

| Stage1 / Stage2 | Result | Wall | Notes |
| --- | --- | --- | --- |
| `1 / 1` | PASS | `366.16s` | clean conservative baseline |
| `2 / 1` | PASS | `333.39s` | best result |
| `2 / 2` | PASS | `389.56s` | worse than `1 / 1` and `2 / 1` |

Marker notes:

- Stage 1 uses the root scheduler summary:
  - `bench_cpu_cap_env`
  - `bench_cpu_cap_requested`
  - `bench_cpu_cap_applied`
  - `scheduler_policy_cap`
  - `effective_parallel_cap`
- Stage 2 uses per-item `separation_log.txt` markers:
  - `bench_cpu_cap_env`
  - `bench_cpu_cap_requested`
  - `bench_cpu_cap_applied`
  - `dks_extract_stage2_effective_cap`
  - `lua_dks_extract_stage2_concurrency_cap`

Interpretation:

- Stage 1 benefits from `cap2`
- Stage 2 should remain at `cap1` on this dataset
- `2 / 1` is the strongest current CPU default candidate for Kit Split
- `2 / 2` is not a good default candidate

Applied follow-up default-policy direction:

- Direct Kit CPU: `cap2`
- Kit Split CPU: Stage 1 `cap2`, Stage 2 `cap1`

Still intentionally not done in the default-policy slice:

- no GPU policy changes
- no `cap4` default anywhere
- no CPU policy changes outside drum workflows

## UI polish TODO

Future GUI polish notes:

- replace status text `AI model laden` with `Model laden`
- show method or backend in the Multi-Track footer, for example `CPU`, `GPU`, `ROCm`, `CUDA`, `DirectML`, or `MPS`
- make ETA display more consistent across the other progress windows

This TODO is intentionally out of scope for the current policy slice.
