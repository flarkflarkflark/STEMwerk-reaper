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

Local CPU audit (explicit `device=cpu`, 8 jobs, same source set) showed:

- Normal UI sequential: `74.476s`, overlap `1`, success `8/0`.
- Normal UI parallel unlimited: `77.989s`, overlap `8`, success `8/0`.
- Toolbar `All Stems` parallel unlimited: `84.170s`, overlap `8`, success `8/0`.

Findings:

- CPU parallel technically works in both normal UI and toolbar quick-preset flow.
- `All Stems` quick mode appears to use the same `runSeparationWorkflow` concurrency path as normal UI.
- No evidence that toolbar mode bypasses concurrency guards.
- In this local benchmark, explicit CPU parallel is slower than CPU sequential and shows stronger contention.
- Existing `auto_no_gpu` sequential fallback (for `device=auto` without GPU backend) remains justified.

Recommendation:

- Keep CPU auto fallback sequential for now.
- Keep internal parallel limiter default `nil`.
- Treat CPU+GPU hybrid scheduling as future research only; do not implement until mixed CPU/GPU benchmarks justify it.

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

- implemented as a code and regression slice only
- still needs a live CPU normal-stems smoke before it should be treated as validated policy
- should not be conflated with the separate GPU recommendation of `cap4` as the default candidate
