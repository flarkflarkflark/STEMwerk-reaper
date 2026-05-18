# STEMwerk Diagnostics Artifacts

This note describes where STEMwerk diagnostics are written and how they persist when `Temp files` is set to `Delete`.

## Temp job diagnostics (in run/job temp dirs)

STEMwerk writes per-job diagnostics to temp run directories (for example under `/tmp/STEMwerk_*`):

- `timing_events.jsonl` (Lua-side events)
- `phase_events.jsonl` (Python-side phases)
- `stdout.txt` (progress/result protocol output)
- `separation_log.txt` (backend stderr/logging)
- `exit_code.txt`
- `done.txt`

These files remain directly inspectable when `Temp files: Keep` is enabled.

## Persistent diagnostics (durable)

Before temp cleanup, STEMwerk now copies the same small diagnostics into persistent logs:

- Linux/macOS: `$XDG_CACHE_HOME/STEMwerk/logs/runs/` (fallback `~/.cache/STEMwerk/logs/runs/`)
- Windows: `%TEMP%\\STEMwerk\\logs\\runs\\`

Layout:

`<logs_dir>/runs/<run_id>/<job_name>/`

Files copied per job (if present):

- `timing_events.jsonl`
- `phase_events.jsonl`
- `stdout.txt`
- `separation_log.txt`
- `exit_code.txt`
- `done.txt`

`<run_id>` reuses the temp run base name (for example `STEMwerk_1778695701_31964909_2`).

## Behavior when Temp files = Delete

When temp cleanup removes job folders, diagnostics remain available in the persistent `logs/runs/...` tree.

This applies to:

- successful jobs
- failed jobs
- canceled/killed jobs (partial files are copied when available)

No audio/stem/project/model payloads are copied into persistent run diagnostics.

## Support bundle inclusion

`STEMwerk_Save_Support_Bundle.lua` includes persisted run diagnostics from `logs/runs` into:

- `runtime_runs/<run_id>/<job_name>/...`

Support bundle contents remain text diagnostics only.

## Timing helper usage

The helper supports persisted run folders directly:

- `python tools/dev/summarize_stemwerk_timing.py <logs_dir>/runs/<run_id>`

Example:

- `python tools/dev/summarize_stemwerk_timing.py ~/.cache/STEMwerk/logs/runs/STEMwerk_1778695701_31964909_2`

This prints per-job timings and a run summary for sequential/parallel comparison.
