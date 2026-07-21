# STEMwerk 2.3.0.6

## Corrective hotfix scope

STEMwerk 2.3.0.6 is a narrow corrective release based directly on the official
2.3.0.4 tag. An unreleased 2.3.0.5 planning build was briefly exposed through
the moving ReaPack `main` branch; there was no official 2.3.0.5 tag or GitHub
release.

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

No push, tag, installer build, or publication is part of release preparation.
