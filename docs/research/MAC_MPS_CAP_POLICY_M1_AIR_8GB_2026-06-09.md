# Apple Silicon MPS cap policy - M1 Air 8GB

Date: `2026-06-09`
Branch: `feature/direct-dks-linux-integration`
HEAD: `ebb4b33b8c2bd8ffdac74d8fc8149b637ee09e5b`
Relevant commit: `ebb4b33b8c2bd8ffdac74d8fc8149b637ee09e5b`

## Scope

- Machine: M1 MacBook Air 8GB internal.
- Workflows covered: Normal stems, Direct Kit, Kit Split.
- MPS is experimental/explicit in this slice.
- Benchmark-only env overrides were used; no default-policy code was changed.

## Controlled Launch Requirement

Benchmark runs were only considered reliable when REAPER was started via the binary with a controlled environment. Using `open -a REAPER` could mix in stale LaunchServices state or previous REAPER instances and skew markers.

```bash
osascript -e 'tell application "REAPER" to quit' || true
sleep 5

REAPER_BIN="/Applications/REAPER.app/Contents/MacOS/REAPER"
if [ ! -x "$REAPER_BIN" ]; then
  REAPER_BIN="/Applications/REAPER64.app/Contents/MacOS/REAPER"
fi

env -i \
  HOME="$HOME" \
  USER="$USER" \
  LOGNAME="$LOGNAME" \
  TMPDIR="$TMPDIR" \
  LANG="${LANG:-en_US.UTF-8}" \
  LC_ALL="${LC_ALL:-en_US.UTF-8}" \
  __CF_USER_TEXT_ENCODING="${__CF_USER_TEXT_ENCODING:-0x1F5:0:0}" \
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  STEMWERK_BENCH_MPS_CAP=2 \
  "$REAPER_BIN"
```

## Normal Stems

Validated run IDs:

- CPU cap1: `STEMwerk_1780953177_1780953177686_2`
- CPU cap2: `STEMwerk_1780953559_1780953559577_2`
- MPS cap1: `STEMwerk_1780954128_1780954128384_2`
- MPS cap2: `STEMwerk_1780954508_1780954508850_2`
- MPS cap4: `STEMwerk_1780954670_1780954670328_2`

Observed outcome:

- CPU cap1 and cap2 were PASS.
- MPS cap1 and cap2 were PASS.
- MPS cap4 was functionally PASS WITH NOTES, but it made the machine noticeably sluggish.

Policy conclusion for this machine:

- default candidate: MPS cap2
- fallback: MPS cap1
- cap4: not a default candidate on M1 Air 8GB

## Direct Kit

Validated run IDs:

- cap1 PASS: `STEMwerk_1780957468_1780957468901_2`
- cap2 PASS: `STEMwerk_1780957830_1780957830534_2`
- cap4 run: `STEMwerk_1780958297_1780958297213_2`

Direct Kit cap2 markers observed on the successful runs:

- `workflow_source=dks_direct`
- `requested_device=mps`
- `effective_device=mps`
- `backend_runtime=mps`
- `model_device=mps:0`
- `drumsep_helper_route=mps-direct-demix`
- `bench_mps_cap_requested=2`
- `bench_mps_cap_applied=2`
- `scheduler_policy_cap=2`
- `effective_parallel_cap=2`
- `parallelJobLimit=2`
- 6/6 canonical drum outputs
- no fallback

Direct Kit cap4 result:

- front markers were correct:
  - `bench_mps_cap_requested=4`
  - `bench_mps_cap_applied=4`
  - `scheduler_policy_cap=4`
  - `effective_parallel_cap=4`
  - `parallelJobLimit=4`
- the run became very sluggish and later failed with:
  - `error_reason=drumsep_direct_demix_failed`
  - `detail=OSError: [Errno 28] No space left on device`
- the disk was near full at that point (`/System/Volumes/Data` at 96% used).

Conclusion:

- Direct Kit cap2 is the best candidate.
- cap1 remains the conservative fallback.
- cap4 is not suitable as a default candidate on M1 Air 8GB.

## Kit Split

Validated run IDs:

- `1/1`: `STEMwerk_1780962526_1780962526178_2`
- `2/1`: `STEMwerk_1780962925_1780962925032_2`
- `2/2`: `STEMwerk_1780963387_1780963387221_2`

Observed matrix:

| workflow | cap config | run_id | wall time | effective caps | outputs/imports | fallback | result | UX notes |
| --- | ---: | --- | ---: | --- | --- | --- | --- | --- |
| Kit Split MPS | `1/1` | `STEMwerk_1780962526_1780962526178_2` | ~40s stage2, ~58s total | stage1 `1`, stage2 `1` | 6 outputs, import ok | none | PASS | soepel/handelbaar |
| Kit Split MPS | `2/1` | `STEMwerk_1780962925_1780962925032_2` | ~18s stage1 + ~22s stage2, ~40s total | stage1 `2`, stage2 `1` | 6 outputs, import ok | none | PASS | soepel, wel warm |
| Kit Split MPS | `2/2` | `STEMwerk_1780963387_1780963387221_2` | ~18s stage1 + ~40s stage2, ~58s total | stage1 `2`, stage2 `2` | 6 outputs, import ok | none | PASS | soepel, maar duidelijk zwaarder |

Explicit markers confirmed on `2/2`:

- `workflow_source=dks_extract`
- `workflow_mode=drumkit`
- `dks_extract_stage1_requested_device=mps`
- `dks_extract_stage1_device=mps`
- `dks_extract_stage2_requested_device=mps`
- `dks_extract_stage2_device=mps`
- `dks_extract_stage2_backend=mps`
- `bench_dks_stage1_mps_cap_requested=2`
- `bench_dks_stage1_mps_cap_applied=2`
- `bench_dks_stage2_mps_cap_requested=2`
- `bench_dks_stage2_mps_cap_applied=2`
- `effective_parallel_cap=2`
- `scheduler_policy_cap=2`
- `parallelJobLimit=2`
- 6/6 canonical outputs
- `mps_fallback_enabled=0`
- `pytorch_mps_fallback_env=unset`
- `mps_fallback_used=no`

Kit Split policy conclusion:

- default candidate: stage1 MPS cap2 + stage2 MPS cap1
- conservative fallback: stage1 MPS cap1 + stage2 MPS cap1
- optional/advanced: stage1 MPS cap2 + stage2 MPS cap2
- cap4: not a default candidate on M1 Air 8GB

## Recommended Policy Candidate

```text
Apple Silicon M1 Air 8GB MPS policy candidate:

Normal stems:
- default candidate: MPS cap2
- fallback: MPS cap1
- cap4: not default

Direct Kit:
- default candidate: MPS cap2
- fallback: MPS cap1
- cap4: not default

Kit Split:
- default candidate: stage1 MPS cap2 + stage2 MPS cap1
- fallback: stage1 MPS cap1 + stage2 MPS cap1
- optional/advanced: stage1 MPS cap2 + stage2 MPS cap2
- cap4: not default
```

## Notes And Risks

- This conclusion is specific to the M1 MacBook Air 8GB internal machine.
- It does not automatically generalize to M1/M2/M3 Pro, Max, Ultra, or higher-RAM systems.
- Cap-heavy runs should be preceded by a quick disk check, because temp pressure can distort results.
- No product default was changed here; this note is input for a later policy/code slice.
