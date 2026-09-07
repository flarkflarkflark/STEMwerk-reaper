# Slice 3 (2.4.0.0) — Linux ROCm main-runtime modernization status (2026-09-07)

## Summary / verdict

NO_PIN_CHANGE_FOR_MAIN_RUNTIME. The audio-separator 0.44.3 / NumPy 2 migration
for the Linux "main" (Normal Stems) runtime was investigated, found to have
already been attempted and deliberately reverted before shipping, and that
revert is independently corroborated by a fresh dependency-resolution
reproduction in this slice. The current shipped pins remain the correct,
defensible target. DrumSep is unaffected and already runs a newer, isolated
stack; it is not touched here either.

This is a validation/investigation slice, not a version-bump slice. See
`docs/research/MAC_LINUX_ROFORMER_ASEP_0443_RND.md` and
`docs/research/ASEP_0443_PIN_MATRIX_2026-07-14.md` for the prior R&D this
builds on.

## What was investigated

Two prior branches attempted the Linux main-runtime bump to
audio-separator 0.44.3:

- `feature/linux-rocm-asep-0443-main-runtime` (`12a6c344`) — bumps
  `PINNED_AUDIO_SEPARATOR_VERSION` to `0.44.3` with a `--no-deps` install
  fallback, keeping `PINNED_NUMPY_VERSION="1.26.4"` unchanged. Never merged
  to `main`.
- `feature/linux-rocm-asep-0443-numpy2-main-runtime` (`94fb94a2`,
  `bb49dc8c`, merged via PR #78, `90f39a42`) — bumps the same pin, but pairs
  it with `numpy==2.4.4`, `numba==0.66.0`, `llvmlite==0.48.0`,
  `scipy==1.18.0`, `beartype==0.18.5`. This one **was** merged into `main`.

`main`'s current `scripts/reaper/STEMwerk_Bootstrap_Linux.sh` was checked
directly: it has **no** `PINNED_AUDIO_SEPARATOR_VERSION` at all, and
`PINNED_NUMPY_VERSION`/`PINNED_NUMBA_VERSION`/`PINNED_LLVM_VERSION` are back
at `1.26.4`/`0.59.1`/`0.42.0`. A file-level diff between `94fb94a2` and
`main` on this script shows the NumPy-2 pin block explicitly reverted to
the pre-migration values in a later commit on the way to `main`, alongside
unrelated new work (DrumSep ROCm tmpdir validation, ready-to-go state
fields) in the same commit — i.e. this was a deliberate hand-revert of the
migration, not an accidental loss. `tools/build_linux_wheelhouse.py`'s
`("main", *)` specs on `main` likewise still read `audio-separator==0.23.0`.

## Independent reproduction (this slice)

An isolated venv (Python 3.12.9, scratch-only, no system/production
packages touched) was built with the exact `feature/.../numpy2` candidate
stack: `torch/torchaudio==2.10.0+rocm7.0`, `torchvision==0.25.0+rocm7.0`,
then `pip install -c {numpy==1.26.4, numba==0.59.1, llvmlite==0.42.0}
audio-separator==0.44.3`.

Result: **pip's resolver fails immediately** —
`audio-separator 0.44.3 depends on numpy>=2`, directly conflicting with the
`numpy==1.26.4` constraint. This independently reproduces, from first
principles and without reading the prior branches' code, the exact
conflict that most likely motivated the revert.

The `--no-deps` fallback from `12a6c344` was also reproduced: downgrading
numpy back to `1.26.4` after installing audio-separator's other runtime
deps, then force-installing `audio-separator==0.44.3 --no-deps`, does
produce an importable environment (`import audio_separator` succeeds, all
verify-list modules import). Whether it is *correct* at runtime despite
audio-separator's own declared `numpy>=2` floor was not exhaustively
proven either way in this slice; the point is moot since this approach
was not the one that shipped.

## Current production baseline (confirmed on this machine)

This machine already has a real, fully-bootstrapped STEMwerk runtime at
`~/.local/share/STEMwerk/` (not touched — read-only inspection only). Its
actual installed "main" runtime:

```
audio-separator  0.23.0
torch            2.10.0+rocm7.0
torchaudio       2.10.0+rocm7.0
torchvision      0.25.0+rocm7.0
numpy            1.26.4
numba            0.59.1
llvmlite         0.42.0
scipy            1.17.1
onnxruntime      1.29.0 (unpinned policy, resolved at install time)
```

`state/ready_to_go.env`: `READY_TO_GO_STATUS=ok`, `MAIN_RUNTIME_STATUS=ok`,
`NORMAL_STEMS_MODEL_READY=yes`, `QUALITY_READY=yes`, `SIX_STEM_READY=yes`,
`DIRECT_KIT_READY=yes`, `KIT_SPLIT_READY=yes` — this exact pin combination
is the one already shipped and already green on real AMD Linux/ROCm
hardware (RX 9070 discrete + 780M integrated), independent of anything
this slice did.

A fresh isolated venv built to this exact same combination (not the
production one) additionally proved, in this slice: a real matmul on
`cuda:0`; a real `htdemucs` separation of a real 20s clip via
`stemwerk_core.separator.StemSeparator` (4 stems, `device_used=cuda:0`,
7.9s elapsed); and that `stemwerk_core.runtime_resolution.resolve_execution_plan`
via the real `stemwerk_runtime_seam.build_normal_stems_capability_probe()`
independently resolves the same plan (`rocm`/`cuda:0`) that the real
separation actually used, proving contract/runtime agreement against the
*true* production-matching runtime for the first time (Slice 1/2's
real-hardware validation used ambient system Python's torch, which happens
to be a different, newer build than the managed runtime).

DrumSep (unaffected, unchanged, isolated stack, `audio-separator==0.34.1`)
was independently proven on this same real production runtime base: real
`_select_drumsep_runtime` explicit-`rocm` and `auto` calls both resolve to
the real ROCm venv (`AMD Radeon RX 9070`, `AMD Radeon 780M Graphics`
detected); an explicit `cuda:0` request (no real NVIDIA hardware present)
correctly fails closed (`python_path=None`, `reason=missing`,
`selection_policy=explicit_cuda`) rather than silently downgrading —
confirming Slice 2's fail-closed fix holds on genuine hardware absence,
not only in mocks.

## hdemucs_mmi (Slice 2 open question)

Slice 2 could not find any evidence for `hdemucs_mmi`'s stem semantics
anywhere in this repository or this machine's installed/deployed state.
This slice extends that check to the actual installed `audio-separator`
package contents: `grep -rl hdemucs_mmi` across the entire installed
0.23.0 venv (including its vendored `demucs` implementation and
`torchaudio`'s own HDemucs code) returns **no matches**. The model is
resolved generically via `stemwerk_core.models.py`'s friendly-name mapping
to a `hdemucs_mmi.yaml` file that does not exist in this repo or this
machine's model cache; audio-separator itself has no special-cased
knowledge of it. This remains unprovable locally. The Slice 2 catalog
entry (`role: internal`, 4-stem, output_semantic_ids inferred from the
support bundle's own generic fallback) is left unchanged, per Slice 3's
instruction not to broaden into unrelated internet research.

## Non-goals honored

No system package, Linux kernel, Mesa, or system Python was touched. The
production runtime at `~/.local/share/STEMwerk/` was read-only inspected,
never written to. All package installs happened in a disposable venv under
this session's scratch directory. DrumSep, Direct Kit/Split contract
authority, and macOS/Windows constraint files are unchanged.
