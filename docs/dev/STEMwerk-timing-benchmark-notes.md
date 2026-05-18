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
