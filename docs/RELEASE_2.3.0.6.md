# STEMwerk 2.3.0.6

## Corrective hotfix scope

STEMwerk 2.3.0.6 is the official narrow corrective hotfix based directly on the
official 2.3.0.4 tag. Version 2.3.0.5 was unintentionally exposed through the
moving ReaPack `main` branch; there was no official 2.3.0.5 GitHub release.

## Fixes

- Apple Silicon Repair now verifies that the complete bundled recovery payload
  is available before any requested `.venv` rebuild cleanup. If the payload is
  absent or incomplete, Repair exits with `ready_to_go.env` reconciled to
  `READY_TO_GO_STATUS=missing` and `MAIN_RUNTIME_STATUS=missing`. An existing
  managed runtime is left untouched.
- Runtime verification now imports NumPy and Numba and executes a compiled
  Numba JIT probe. A working NumPy 2 runtime is no longer rejected solely by
  its NumPy major version.
- DrumSep resolves the audio-separator 0.44.3 catalog checkpoint name to the
  existing managed canonical checkpoint and configuration in memory. Direct
  Kit and Kit Split no longer need to create a processing-time checkpoint
  alias. A conflicting pre-existing alias fails closed without modifying the
  model cache.
- macOS package staging excludes AppleDouble `._*` sidecars.
- The bundled Apple Silicon payload is resolved as one coherent, closed
  dependency set. Its NumPy/Numba combination is verified with live imports and
  a compiled Numba JIT probe, and its DrumSep compatibility configuration is
  hash-verified during payload assembly.
- Ordinary Repair probes an existing operational runtime before mutation. If
  its dependency policy differs from the bundled 2.3.0.6 policy, Repair reports
  `runtime_policy_mismatch_requires_rebuild` and directs the user to explicit
  `Rebuild venv` without changing the environment or readiness state.

The available support evidence does not establish why the reported managed
`.venv` disappeared. In particular, it does not prove that the last logged
Repair run removed it; that run stopped at payload preflight.

## Recovery package

ReaPack and the normal online `STEMwerk-2.3.0.6.pkg` do not contain the complete
Apple Silicon recovery payload. Recovery of a missing managed runtime requires:

`STEMwerk-2.3.0.6-bundled-apple-silicon.pkg`

Build it only after assembling and auditing the complete payload at
`scripts/reaper/_bundled/macos/apple-silicon`, then run:

```bash
STEMWERK_VERSION=2.3.0.6 \
  bash installer/macos/build_pkg.sh --variant bundled-apple-silicon
```

The package must pass a package-originated M1 fresh-install, missing-runtime
Repair, healthy-runtime Repair, Normal Stems, Direct Kit, Kit Split, and
no-network payload smoke before publication.

The final bundled Apple Silicon candidate is:

`STEMwerk-2.3.0.6-bundled-apple-silicon.pkg`

SHA256:

`eedd4d293e4c7e351c2e2a07b641b18db0388d368504379b84636cfac3908856`

## Final Apple Silicon evidence

The final installed-package smoke on M1 passed:

- Package receipt version and installed script provenance matched 2.3.0.6.
- Ordinary Repair detected the newer operational runtime policy, returned
  `repair_required`, and preserved the full pip inventory, readiness state,
  Python environment, and sentinel byte-for-byte.
- Missing-runtime recovery restored managed Python and the complete bundled
  dependency/model policy without requiring network access.
- Explicit `Rebuild venv` completed only after full payload preflight; the
  rebuilt NumPy/Numba imports and compiled JIT probe passed.
- Canonical DrumSep checkpoint/catalog resolution passed without creating a
  conflicting model alias.
- A live 25-second Kit Split run used MPS for both stages and produced the six
  canonical drum outputs with `output_validation_reason=ok`.
- The original production runtime was restored and matched the retained full
  backup for pip inventory, readiness, and model inventory.

## Explicit exclusions

- No model-registry v2 or Vocals HQ proof.
- No device/backend-normalization architecture.
- No Linux ROCm unified runtime, Linux DrumSep online distribution/runtime
  policy, or Linux Numba cache architecture.
- No new toolbar actions or icons.
- No broad Windows payload changes.
- No 2.4 design or handoff work.
- The retired Windows update-patch path is not restored.
- Offline/allmodels products are not rebuilt or replaced.
- No 2.4 runtime architecture is included.

No push, tag, installer build, or publication is part of release preparation.
