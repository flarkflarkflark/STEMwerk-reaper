# STEMwerk 2.3 REAPER MCP Smoke / Benchmark Prep

This note captures the safe REAPER MCP surface available from Codex CLI and a minimal protocol for STEMwerk 2.3 smoke and cap 2 vs cap 4 benchmarking.

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
- Capture the support bundle after completion.
- Compare cap 2 and cap 4 results manually until a project-state helper exists.

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

## Optional Next Step

- Add a tiny REAPER helper action that writes a project-state snapshot to ExtState or a temp file.
- Keep it read-only and benchmark-oriented.
- Do not change scheduler policy, backend routing, import routing, or UI copy.
