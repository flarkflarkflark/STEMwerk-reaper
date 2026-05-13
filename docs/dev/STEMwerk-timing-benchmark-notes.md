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
