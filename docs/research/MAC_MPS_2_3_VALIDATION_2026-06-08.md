# Mac MPS 2.3 Validation

Date: `2026-06-08`
Branch: `feature/direct-dks-linux-integration`
HEAD: `d806a13409cb61eb84b8cd10fabc79ea6174860f`

## Context

This note records live macOS Apple Silicon validation for the current branch.

- machine context: Apple Silicon Mac
- runtime context: STEMwerk managed runtime in REAPER with explicit Apple MPS selection
- repo status during validation: project code clean, only local untracked `docs/research/` artifacts present

## MPS Availability Note

There was a temporary MPS availability mismatch before reboot:

- earlier Codex/probe context temporarily reported `mps_available=False`
- after reboot, Terminal and REAPER runtime context reported `mps_available=True`
- live REAPER explicit-MPS smoke runs are treated as the source of truth for this validation pass

Conclusion for this pass:

- no STEMwerk regression found
- the earlier mismatch behaved like a session-context issue rather than a branch/runtime packaging issue

## Direct Kit MPS PASS

Validated run IDs:

- `STEMwerk_1780947768_1780947768016_6` - 8-item run
- `STEMwerk_1780948480_1780948480981_4` - single confirm

Observed markers:

- `workflow_source=dks_direct`
- `requested_device=mps`
- `effective_device=mps`
- `backend_runtime=mps`
- `model_device=mps:0`
- `drumsep_runtime_selected=mps`
- `drumsep_mps_all_targets_route=direct_demix`
- `mps_fallback_enabled=0`
- `PYTORCH_ENABLE_MPS_FALLBACK` unset

Observed outcomes:

- exact 6 canonical drum outputs per item
- `kick`, `snare`, `toms`, `hi-hat`, `ride`, `crash`
- `import_start` and `import_end` present
- no CPU fallback
- no `Traceback`
- no `partial`
- no `no_stems`

## Kit Split MPS PASS

Validated run IDs:

- `STEMwerk_1780947521_1780947521820_4` - 8-item run
- `STEMwerk_1780948560_1780948560243_5` - single confirm

Observed markers:

- `workflow_source=dks_extract`
- stage 1 requested MPS
- stage 2 requested MPS
- stage 2 backend/runtime MPS
- `requested_device=mps`
- `effective_device=mps`
- `backend_runtime=mps`
- `model_device=mps:0`
- `drumsep_runtime_selected=mps`
- `drumsep_mps_all_targets_route=direct_demix`
- `mps_fallback_enabled=0`
- `PYTORCH_ENABLE_MPS_FALLBACK` unset

Observed outcomes:

- exact 6 canonical drum outputs per item
- `kick`, `snare`, `toms`, `hi-hat`, `ride`, `crash`
- `import_start` and `import_end` present
- no CPU fallback
- no `Traceback`
- no `partial`
- no `no_stems`

## Normal Stems MPS Observed PASS

Observed run IDs:

- `STEMwerk_1780948319_1780948319885_1`
- `STEMwerk_1780948343_1780948343165_2`
- `STEMwerk_1780948052_1780948052489_2`

Observed markers:

- `requested_device=mps`
- `effective_device=mps`
- `mps_available=True`
- `mps_fallback_enabled=0`
- no CPU fallback

## UI And Progress

Visual validation during the live REAPER pass was OK:

- loading, queued, percentage, and done-row behavior looked correct
- progress rows and right-side percentages looked correct
- Mac footer may appear a bit more compact than Linux, but this was not a blocker

## Conclusion

- Mac MPS PASS
- no STEMwerk regression found on this branch
- optional later follow-up: harden live MPS tensorprobe observability if availability flips again
