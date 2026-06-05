# STEMwerk 2.3 REAPER MCP Smoke / Benchmark Prep

This note captures the safe REAPER MCP surface available from Codex CLI and a minimal protocol for STEMwerk 2.3 smoke and cap 2 vs cap 4 benchmarking.
It also documents the normal stems benchmark matrix for GPU cap 2 / 4 / 8.

## Verified MCP Surface

- `codex mcp list` shows the `reaper` server as enabled.
- `reaper` server config:
  - command: `/home/flark/.venvs/total-reaper-mcp/bin/python`
  - args: `-m server.app --profile dsl`
  - cwd: `/mnt/PRODUCTION/GIT/total-reaper-mcp`
- Available read-only MCP tools in this session:
  - `dsl_list_actions`
  - `dsl_get_extstate`
- Available write-capable MCP tool in this session:
  - `dsl_set_extstate`

## What Is Reliably Readable

- STEMwerk action inventory via `dsl_list_actions`
- STEMwerk ExtState values via `dsl_get_extstate`
- Current workflow source and mode values if stored in ExtState
- Current device selection if stored in ExtState

## What Is Not Reachable Yet

- Project track count
- Project item count
- Project take count
- Project dirty state
- Time selection summary

Those are not exposed by the current MCP surface in a direct read-only way. If we need them, the cleanest next step is a tiny dedicated REAPER helper action that writes a summary to ExtState or a temp file.

## Verified STEMwerk ExtState Keys

Observed keys that are useful for smoke snapshots:

- `workflow_source`
- `workflow_mode`
- `active_workflow_source`
- `active_workflow_mode`
- `device`
- `quick_preset`
- `selected_model`
- `backend`

Observed values during the audit:

- `workflow_source = dks_extract`
- `workflow_mode = drumkit`
- `device = auto`
- `active_workflow_mode` absent
- `active_workflow_source` absent
- `quick_preset` absent
- `selected_model` absent
- `backend` absent

## Read-Only Smoke Checklist

Capture these before and after a manual run:

- Timestamp
- `codex mcp list` output
- STEMwerk action list result for `filter = STEMwerk`
- Selected track count, item count, take count, and time selection state if a helper becomes available
- ExtState snapshot for the keys above
- Project dirty state if a helper becomes available

## Suggested Benchmark Protocol

- Keep the project, input material, and REAPER version fixed across runs.
- Use the same STEMwerk workflow source for both runs.
- Run one cap 2 trial and one cap 4 trial on the same project state.
- Set `STEMWERK_BENCH_GPU_CAP=2` for the baseline run and `STEMWERK_BENCH_GPU_CAP=4` for the benchmark run.
- `STEMWERK_BENCH_GPU_CAP=8` is available for normal GPU separation as an experimental high-throughput benchmark only.
- Use only GPU-parallel routes where the default scheduler already allows cap 2:
  - normal GPU separation
  - Z / Direct Drum Kit short / multi
  - X / Drum Kit Split stage 1
- Cap 8 is benchmark-only and must stay limited to normal GPU separation until repeated clean runs confirm it.
- Do not use the override for:
  - DirectML
  - MPS
  - CPU-only runs
  - Z / Direct Drum Kit cap 8
  - X / Drum Kit Split stage 2
- X stage 2 remains serialized at cap 1.
- Record a before snapshot, start the run, then record an after snapshot.
- Collect the support bundle and timing files for both runs.
- Compare:
  - wall clock total
  - total source duration
  - realtime factor
  - any stage 2 queue wait time
  - any failure or partial-result markers

## Manual Steps Still Needed

- Start the intended STEMwerk run manually in REAPER.
- Confirm the intended route before launching:
  - direct DKS
  - extract DKS
  - normal separation
- Set the benchmark env var in the REAPER launch environment:
  - `STEMWERK_BENCH_GPU_CAP=2`
  - `STEMWERK_BENCH_GPU_CAP=4`
  - `STEMWERK_BENCH_GPU_CAP=8` for experimental normal-stems GPU runs only
- For X / Drum Kit Split Stage 2, also set:
  - `STEMWERK_BENCH_DKS_STAGE2_CAP=1`
  - `STEMWERK_BENCH_DKS_STAGE2_CAP=2`
  - `STEMWERK_BENCH_DKS_STAGE2_CAP=4`
- Capture the support bundle after completion.
- Compare cap 2 and cap 4 results with the project-state helper and the support bundle markers.

## Benchmark Markers

When the override is active, check the support bundle logs for:

- `bench_gpu_cap_requested=`
- `bench_gpu_cap_applied=`
- `bench_gpu_cap_ignored_reason=`
- `bench_dks_stage2_cap_requested=`
- `bench_dks_stage2_cap_applied=`
- `bench_dks_stage2_cap_ignored_reason=`
- `workflow_source=`
- `stage=`
- `device=`
- `backend=`
- `effective_parallel_cap=`

## X Benchmark Matrix

Run X / Drum Kit Split with 8 short items and compare these 4 subruns:

1. A. `STEMWERK_BENCH_GPU_CAP=2`, `STEMWERK_BENCH_DKS_STAGE2_CAP` unset or `1`
2. B. `STEMWERK_BENCH_GPU_CAP=4`, `STEMWERK_BENCH_DKS_STAGE2_CAP` unset or `1`
3. C. `STEMWERK_BENCH_GPU_CAP=4`, `STEMWERK_BENCH_DKS_STAGE2_CAP=2`
4. D. `STEMWERK_BENCH_GPU_CAP=4`, `STEMWERK_BENCH_DKS_STAGE2_CAP=4`, only if C is clean

PASS criteria for X:

- 8 item-subruns
- all exit codes 0
- expected outputs 48/48
- no `partial_dks_multi`
- no `drumsep_output_count_mismatch`
- no missing stage2 DrumSep logs
- no stale success when outputs are missing
- support/log markers present

## Normal Stems Benchmark Matrix (GPU cap 2 / 4 / 8)

Normal stems benchmark matrix (GPU cap 2 / 4 / 8):

Use the same 8 short items, `Auto`, and GPU-capable runtime for all runs.

Run all 9 combinations:

1. `htdemucs` / cap 2
2. `htdemucs` / cap 4
3. `htdemucs` / cap 8
4. `htdemucs_ft` / cap 2
5. `htdemucs_ft` / cap 4
6. `htdemucs_ft` / cap 8
7. `htdemucs_6s` / cap 2
8. `htdemucs_6s` / cap 4
9. `htdemucs_6s` / cap 8

Per run, capture:

- selected model
- workflow source for normal stems
- selected stems
- `bench_gpu_cap_requested`
- `bench_gpu_cap_applied`
- `effective_parallel_cap`
- `scheduler_policy_cap`
- item count
- exit codes
- output count
- wall time
- realtime factor
- `benchmark_resource_summary` fields:
  - `gpu_name`
  - `gpu_util_peak_percent`
  - `gpu_util_avg_percent`
  - `vram_peak_mb`
  - `vram_total_mb`
  - `gpu_temp_peak_c`
  - `gpu_power_peak_w`
  - `cpu_avg_percent`
  - `system_ram_peak_mb`

Stop the matrix early if any run shows:

- non-zero exit code
- missing outputs
- partial or fail markers
- VRAM close to full
- OOM, killed worker, or helper/runtime errors

Interpretation guardrail:

- cap 8 is experimental high-throughput benchmark only
- cap 8 is not a default candidate until repeated clean runs stay stable

### RX 9070 / ROCm results

Captured on Linux with the discrete `AMD Radeon RX 9070` ROCm/CUDA path (`GPU 0`).
All runs below were strict PASS with correct provenance and cap markers:

- `workflow_source=normal`
- `workflow_mode=stems`
- `route=normal`
- `stage=single_stage`
- `device=auto` in the root scheduler summary
- `backend=gpu`
- requested/applied/effective/scheduler cap matched the requested `2`, `4`, or `8`
- `8/8` exit codes `0`
- `8/8` non-empty `stdout.txt` JSON stem outputs
- `resource_sampling_available=yes`
- no partial/fail/OOM markers

Observed matrix:

| Model | Cap | Result | Wall time | VRAM peak | Temp peak | Power peak |
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

- cap scaling works correctly; all strict cap markers matched the requested cap.
- GPU backend stayed stable on RX 9070; worker device resolved to `cuda:0`.
- `cap4` is the strongest throughput/safety balance for normal stems on this machine.
- `cap8` is valid but not consistently faster than `cap4` and uses much more VRAM and power.
- `htdemucs_ft cap8` is near-limit at about `15.96 GB / 16.30 GB` VRAM and should remain benchmark or advanced-only.
- `htdemucs_6s` correctly emits 6 outputs (`vocals`, `drums`, `bass`, `other`, `guitar`, `piano`); this is expected model behavior, not an anomaly.

Current policy candidate for normal stems on ROCm/CUDA discrete AMD GPU:

- `cap4`: default candidate
- `cap2`: low-pressure fallback
- `cap8`: benchmark, advanced, or stress-only

Telemetry note:

- resource sampling measures the discrete RX 9070, not the integrated `780M`
- `gpu_temp_peak_c` is the peak seen during the run, not the final on-screen temperature after cooldown

## Safe MCP Calls To Use

- `dsl_list_actions(section="Main", filter="STEMwerk")`
- `dsl_get_extstate(section="STEMwerk", key="workflow_source")`
- `dsl_get_extstate(section="STEMwerk", key="workflow_mode")`
- `dsl_get_extstate(section="STEMwerk", key="active_workflow_source")`
- `dsl_get_extstate(section="STEMwerk", key="active_workflow_mode")`
- `dsl_get_extstate(section="STEMwerk", key="device")`
- `dsl_get_extstate(section="STEMwerk", key="quick_preset")`
- `dsl_get_extstate(section="STEMwerk", key="selected_model")`
- `dsl_get_extstate(section="STEMwerk", key="backend")`

## Project State Snapshot Helper

Use this dev/test-only Action List script when you need a project snapshot without changing the project:

1. Run `Custom: STEMwerk_Dev_Project_State_Snapshot.lua`
2. Read ExtState section `STEMwerkDevSnapshot`
3. Inspect keys:
   - `timestamp`
   - `track_count`
   - `selected_track_count`
   - `media_item_count`
   - `selected_media_item_count`
   - `take_count_total`
   - `selected_take_count`
   - `time_selection_start`
   - `time_selection_end`
   - `time_selection_length`
   - `project_dirty`
   - `project_path`
   - `project_name`
   - `last_error`
   - `snapshot_ok`

## Benchmark Request Flow

Use the registered snapshot helper as the fixed dispatcher for benchmark prep and snapshot capture.

Registered action:

- `Custom: STEMwerk_Dev_Project_State_Snapshot.lua`
- command id: `_RS6591f55c0e89376ce59cc3be252bf722305ed9e0`
- numeric id observed in this REAPER session: `71254`

Before running it, set the MCP request ExtState:

1. Set `STEMwerk/dev_mcp_request = prepare_benchmark_state`
2. Set `STEMwerk/dev_mcp_requested_item_count = 8`
3. Set `STEMwerk/dev_mcp_workflow_source = dks_direct`
4. Set `STEMwerk/dev_mcp_workflow_mode = drumkit`
5. Set `STEMwerk/dev_mcp_device = auto`
6. Run `Custom: STEMwerk_Dev_Project_State_Snapshot.lua` or command id `71254`

After the run, read:

- `STEMwerkDevBenchmarkPrep/*`
- `STEMwerkDevSnapshot/*`
- `STEMwerk/dev_mcp_request_handled`

The dispatcher handles the benchmark prep only when the request key is set to `prepare_benchmark_state`.
Without that explicit request, it stays a read-only snapshot helper.

The compatibility script `Custom: STEMwerk_Dev_Prepare_Benchmark_State.lua` remains on disk for manual use, but MCP does not need to discover or invoke it.
`STEMwerkDevMCP` is no longer used because the bridge write allowlist blocks that section.

## Benchmark Prep Result

When `STEMwerkDevMCP/request = prepare_benchmark_state`, the dispatcher writes `STEMwerkDevBenchmarkPrep` with:

- `prep_ok`
- `requested_item_count`
- `selected_media_item_count`
- `selection_source`
- `time_selection_start`
- `time_selection_end`
- `workflow_source_set`
- `workflow_mode_set`
- `device_set`
- `last_error`

Selection rules:

- Prefer items in the current time selection if that yields at least 8 media items.
- Otherwise fall back to the first 8 media items in the project.
- If fewer than 8 media items are available, fail without changing selection.

Applied workflow ExtState:

- `workflow_source = dks_direct`
- `workflow_mode = drumkit`
- `device = auto`
- `active_workflow_source = dks_direct`
- `active_workflow_mode = drumkit`
- `quick_run = 1`
- `quick_preset = dks_direct`

This request path is benchmark-only and does not create, remove, or save any audio content.

## Future Extension

- If we later need a richer benchmark snapshot, add a second helper that records only additional read-only fields.
- Keep it read-only and benchmark-oriented.
- Do not change scheduler policy, backend routing, import routing, or UI copy.
