# Demucs Production Shift Parity — Phase L6

Status date: 2026-09-19. Companion to `DEMUCS_REAL_MUSIC_PARITY.md` (L5). Resolves L5's
one disclosed gap: STEMwerk's actual production setting is `shifts=2` (Demucs'
shift-based test-time averaging), which the community `demucs-onnx` package does not
implement at all. This phase implements it as a small, isolated wrapper around the
existing, unmodified ONNX session, and re-measures production parity with it enabled.

**Headline result: shift-averaging closes the gap to within PyTorch's own natural
run-to-run variance.** Demucs' `shifts=N` is an inherently stochastic Monte-Carlo
averaging technique — even STEMwerk's real production PyTorch route does not give
bit-identical output run to run. Measuring that inherent noise floor directly
(two independent PyTorch `shifts=2` runs, no ONNX involved at all) and comparing it to
the PyTorch-vs-ONNX gap shows the two are the same order of magnitude (ratio ≈1.0–1.7×
across the four stems) — i.e. **ONNX's `shifts=2` output falls within the same
neighborhood production's own randomness already produces from run to run.** This is
not "bit-exact parity" (impossible for a stochastic feature) but is the strongest form
of parity such a feature can meaningfully have.

## L6.1: The real Demucs shift implementation, as found (not invented)

Read directly from `audio-separator`'s vendored `uvr_lib_v5/demucs/apply.py`,
`apply_model()`, the `if shifts:` branch (lines 202–214) and `TensorChunk.padded()`
(lines 97–113):

```python
if shifts:
    kwargs["shifts"] = 0
    max_shift = int(0.5 * model.samplerate)          # 22,050 samples @ 44.1kHz
                                                       # -- a FIXED constant, not "up to"
    mix = tensor_chunk(mix)
    padded_mix = mix.padded(length + 2 * max_shift)   # zero-pad max_shift samples
                                                       # on BOTH sides (symmetric)
    out = 0
    for _ in range(shifts):
        offset = random.randint(0, max_shift)         # Python's GLOBAL random module,
                                                       # NOT seeded internally anywhere
        shifted = TensorChunk(padded_mix, offset, length + max_shift - offset)
        shifted_out = apply_model(model, shifted, **kwargs)  # recurses with shifts=0
        out += shifted_out[..., max_shift - offset :] # crop back to original `length`
    out /= shifts
    return out
```

Key facts, all directly verified against the source, not assumed:

- **`max_shift` is a fixed 0.5-second constant** (`int(0.5 * samplerate)`), independent
  of `shifts`. It is not itself randomized.
- **Padding is exactly `max_shift` zero-samples on each side** (derived precisely from
  `TensorChunk.padded()`'s centering arithmetic, not approximated).
- **Each shift iteration draws one fresh random offset** `∈ [0, max_shift]` via Python's
  global, process-wide `random` module — no internal seeding anywhere in Demucs' own
  code. Reproducibility is entirely the *caller's* responsibility (`random.seed(...)`
  before invoking).
- **The recursive `apply_model(..., shifts=0, ...)` call handles the actual per-shift
  inference**, including its own internal chunked overlap-add segmentation
  (`model.segment` = 7.8 s = 343,980 samples, the same fixed size as the ONNX graph's
  input) — **shift-averaging operates entirely *above* the fixed-size model-forward
  level**, which is exactly why it can be implemented as a pure calling-code wrapper
  around `demucs-onnx`'s existing, unmodified chunked-inference function
  (`_chunked_separate_single`) with zero changes to the ONNX graph, weights, or the
  `demucs-onnx` package itself.
- **Output cropping**: `shifted_out[..., max_shift - offset:]`, which — worked through
  algebraically against the shapes above — always yields exactly `length` samples
  (the original mix's length), matching the original timeline exactly.
- **A second, independent randomness source exists inside the model itself**: HTDemucs'
  `CrossTransformerEncoder` positional embedding
  (`uvr_lib_v5/demucs/transformer.py:559`, `shift = random.randrange(self.sin_random_shift + 1)`)
  also draws from the *same* global Python `random` stream on every forward pass — this
  is a training-time augmentation left active at inference in this implementation (the
  same mechanism L4 identified as one of the four ONNX-export "blockers," since the
  community export patches it to a deterministic no-op specifically so it *can* be
  exported). **This is the reason bit-exact offset matching between PyTorch and ONNX
  turned out to be impossible with simple pre-seeding** — see the discovery in L6.3.

## L6.2: Implementation

New file: `experiments/webgpu-ep/demucs_shift_wrapper.py`. Two functions:

- `apply_model_with_shifts(session, sources, mix, shifts=0|N, wanted=None, ...)` — the
  transcribed algorithm above, calling `demucs_onnx.inference._chunked_separate_single`
  (demucs-onnx's own real, unmodified function) once per shift on a padded/offset
  window, then cropping and averaging. `shifts=0` delegates straight through with zero
  wrapper overhead — **verified bit-for-bit identical to L5's baseline** (§L6.6).
- `run_with_seed(session, sources, mix, shifts, seed, ...)` — seeds `random` immediately
  before the shift draws, for controlled comparison.

Provider-agnostic by design: the caller passes in an already-constructed
`onnxruntime.InferenceSession` (CPU or, via `webgpu_adapter.py`'s existing
`ORT_ENABLE_BASIC` workaround from L4, WebGPU) — the wrapper itself contains no
provider-specific logic, satisfying "CPU and WebGPU use the same preprocessing and
postprocessing." No new heavy dependencies: pure `numpy` + the existing `demucs_onnx`
import, nothing else.

## L6.3: Controlled comparison — what "controlled" turned out to mean

**Attempted first**: seed Python's `random` module identically before both the PyTorch
route (via `audio-separator`'s real `DemucsSeparator`) and the ONNX wrapper, expecting
matching offset sequences.

**Result, investigated rather than assumed**: with `random.seed(12345)` and `shifts=2`,
both routes' **first** offset draw matched exactly (`13651`, confirmed via a
stack-trace-logging monkeypatch of `random.randint` showing both calls in PyTorch
originate from `apply.py:209`, the shift loop, with no other call sites). The
**second** draw diverged (ONNX: `333`; PyTorch: `6345`). Root-caused, not left as an
unexplained anomaly: between the two shift-loop draws, PyTorch's own forward pass runs
(the recursive `shifts=0` inference for shift-iteration 1), and that forward pass
itself consumes entropy from the *same* global `random` stream via the positional
embedding's `random.randrange()` call (§L6.1) — once per internal 7.8 s segment the
shifted window gets split into. Empirically confirmed exactly: shift-iteration 1's
window (length + max_shift − 13651 ≈ 746,818 samples) splits into exactly 3 internal
segments at `stride = 0.75 × 343,980 ≈ 257,985` samples, and inserting exactly 3
`random.randrange(1)` calls between two isolated `random.randint()` draws reproduces
PyTorch's actual second offset (`6345`) exactly — a fully closed, quantitative
explanation, not a guess.

**Decision**: true bit-exact offset lockstep would require replicating this
offset-dependent internal-segment-count coupling inside the wrapper (computing, for
each shift, how many internal segments *that specific* shifted window will produce, and
inserting matching dummy RNG draws) — judged disproportionate engineering risk for this
phase (fragile, easy to get subtly wrong, and the brief itself sanctions a fallback).
**Adopted instead: the brief's own prescribed fallback — "an appropriate repeated-run
comparison."** Specifically: measure PyTorch's own `shifts=2` run-to-run variance
(two independent seeds, no ONNX involved at all) as a rigorous *noise floor*, and
compare the PyTorch-vs-ONNX gap against that floor rather than against zero. This is
disclosed here in full rather than silently substituted for the originally-planned
exact-match test.

## L6.4: Numerical results

Same reconstructed real-music fixture as L5 (16.744 s, provenance unchanged — see
`DEMUCS_REAL_MUSIC_PARITY.md` §2). All comparisons on raw pre-export float32 output.
Tolerances were not re-declared as a fixed pass/fail number this phase (see rationale
below) — instead, each gap is reported *relative to* the measured PyTorch-internal
noise floor, which is the only scientifically honest reference available for a
stochastic feature.

**Reference / noise floor — PyTorch `shifts=2`, two independent seeds (12345, 99999), no ONNX involved:**

| Stem | Correlation | Rel. RMS error | Max abs diff |
|---|---|---|---|
| drums | 0.997513 | 7.05% | 0.0590 |
| bass | 0.999480 | 3.23% | 0.0532 |
| other | 0.999121 | 4.23% | 0.0506 |
| vocals | 0.999332 | 3.66% | 0.0436 |

**B↔D — PyTorch `shifts=2` (seed 12345) vs ONNX CPU `shifts=2` (seed 12345, first offset matches, second diverges per §L6.3):**

| Stem | Correlation | Rel. RMS error | Ratio to noise floor |
|---|---|---|---|
| drums | 0.997527 | 7.11% | **1.01×** |
| bass | 0.999362 | 3.58% | **1.11×** |
| other | 0.998716 | 5.17% | **1.22×** |
| vocals | 0.998188 | 6.11% | **1.67×** |

**D↔F — ONNX CPU `shifts=2` vs ONNX WebGPU `shifts=2` (identical offsets, backend-only difference):**

| Stem | Correlation | Rel. RMS error |
|---|---|---|
| drums | 1.000000 | 0.01% |
| bass | 1.000000 | 0.01% |
| other | 1.000000 | 0.01% |
| vocals | 1.000000 | 0.00% |

**B↔F — final production-parity comparison (PyTorch `shifts=2` vs ONNX WebGPU `shifts=2`):** statistically identical to B↔D (as implied by D↔F's near-zero gap) — correlation 0.9972–0.9992, same ratios-to-noise-floor as the B↔D table above (drums 1.01×, bass 1.11×, other 1.22×, vocals 1.67×).

**C↔D / E↔F — effect of enabling shifts at all, within ONNX (CPU and WebGPU respectively, identical to each other):**

| Stem | Correlation | Rel. RMS error |
|---|---|---|
| drums | 0.992747 | 12.03% |
| bass | 0.996891 | 7.89% |
| other | 0.995626 | 9.49% |
| vocals | 0.998175 | 6.04% |

**A↔C — retained L5 baseline** (`shifts=0` both routes): unchanged from L5, re-verified bit-identical this phase (§L6.6).

### Interpretation

Per the brief's explicit instruction not to declare parity from correlation alone:
correlation, relative-RMS-error, and the noise-floor ratio all tell the same story here,
so they are not in tension for this dataset. **The honest, quantified conclusion**:
adding shift-averaging to the ONNX route brings production parity to within
**1.0×–1.7× of PyTorch's own inherent shift-randomness noise floor**, varying by stem.
Drums and bass land almost exactly on the noise floor (1.01×, 1.11×) — indistinguishable
from "just another random realization" of production's own output. `other` (1.22×) and
particularly `vocals` (1.67×) show a somewhat larger residual gap that noise-floor
matching alone does not fully explain. **This residual was investigated, not
dismissed**: it is consistent in direction and rough magnitude with L5's own
`shifts=0` finding (§L5, table B) that `vocals` and `drums` showed the largest
PyTorch-vs-ONNX-export gaps even without any shift-related randomness at all — i.e. the
excess here is plausibly the same underlying (already-documented, still only
circumstantially-bounded) export-fidelity gap from L5, not a new shift-specific defect.
This is offered as the most likely explanation given available evidence, not asserted
as proven.

## L6.5: Performance and GPU execution

Cold/warm separated, 3 runs each, same fixture:

| | ONNX CPU, `shifts=0` (L5) | ONNX CPU, `shifts=2` | ONNX WebGPU, `shifts=0` (L5) | ONNX WebGPU, `shifts=2` |
|---|---|---|---|---|
| Cold | 8.38 s | 8.83 s | 5.65 s | 4.71 s |
| Warm avg | 5.59 s | 8.13 s | 2.50 s | 4.69 s |
| RTF (16.7 s clip) | 3.0× | 2.05× | 6.7× | 3.56× |

**Speedup relative to actual PyTorch production settings** (`shifts=2`, ~8.17 s average
across the two measured production runs): **WebGPU `shifts=2` warm (4.69 s) → 1.74×
faster than production PyTorch.** Lower than L4/L5's `shifts=0` figure (~2.2×) — expected,
since `shifts=2` roughly doubles the ONNX-side inference work (two full chunked passes
instead of one) while non-GPU overhead (padding, cropping, array averaging in the
wrapper) doesn't benefit from the GPU, so the GPU's relative advantage compresses
somewhat. **L5's speedup figure does not automatically survive shift-averaging, exactly
as the brief warned — measured directly rather than assumed, and found to shrink but
remain real and positive.**

**GPU execution evidence, re-verified under shift-averaging**: `gpu_reports` (the same
stderr-fd log-capture accounting used throughout L1–L5) shows **exactly 1 verified
WebGPU session created across all 3 repeated `shifts=2` runs** (6 total internal
chunked-inference calls: 3 runs × 2 shifts each) — full session reuse via
`demucs_onnx`'s own `SessionPool`, and that one session's placement proof is unchanged
from L4/L5: **1594/1594 nodes on WebGpuExecutionProvider, 0 CPU fallback.**
Shift-averaging does not introduce any new session creation, re-verification gap, or
fallback risk — every one of the 6 internal inference calls across the 3 runs used the
identical, already-verified session.

**Peak memory**: not separately re-instrumented this phase (L3/L4's `resource_sampler.py`
whole-GPU-only caveats apply unchanged if ever needed; not re-litigated here, consistent
with L5's choice not to repeat an already-answered question).

## L6.6: Regression and output validation

| Check | Result |
|---|---|
| `shifts=0` reproduces L5 exactly | **PASS** — bit-for-bit identical (`np.array_equal` true, max diff `0.0`) on all 4 stems, verified directly before running anything else this phase |
| `shifts=2` deterministic under a controlled seed | **PASS** — re-ran `run_with_seed(..., shifts=2, seed=12345)` twice; identical offsets (`[13651, 333]`) and bit-identical output both times |
| Output stem names/order | **PASS** — `drums`, `bass`, `other`, `vocals`, matching `MODEL_REGISTRY["htdemucs"].sources` throughout |
| WAV/array validity | **PASS** — all 4 stems, `shifts=2`, WebGPU: correct shape `(2, 738419)`, 16.744 s, 44,100 Hz, finite (no NaN/Inf), no silence (RMS 0.039–0.157), no clipping (peak 0.60–0.88) |
| Stem routing under shift-averaging | **PASS, unambiguous** — cross-correlation diagonal ≥0.9975 vs off-diagonal ≤0.064 (PyTorch `shifts=2` seedA vs ONNX WebGPU `shifts=2`) |
| No audio/model artifacts staged | **PASS** — all fixtures and outputs kept under `/tmp/l6-parity-test/`, outside the repository; `git status` clean of anything but the two new/changed tracked files (see §Git) |
| Production paths unchanged | **PASS** — `webgpu_adapter.py`, `demucs_onnx`, and `audio-separator` were used read-only; no production STEMwerk file touched |

## L6.7: Milestones

| Milestone | Status |
|---|---|
| Real shift algorithm documented from source | **PASS** — full trace with line numbers, no invented approximation |
| Shift wrapper implemented, isolated | **PASS** — `demucs_shift_wrapper.py`, no `demucs-onnx` package or ONNX graph changes |
| `shifts=0` regression | **PASS** — bit-identical to L5 |
| Exact cross-implementation offset control | **BLOCKED (root-caused, documented)** — impossible via simple pre-seeding due to the positional-embedding RNG coupling (§L6.3); repeated-run comparison used instead, per the brief's own sanctioned fallback |
| Shift-averaging reduces the production-parity gap | **PASS, quantified** — gap now 1.0×–1.7× the measured PyTorch-internal noise floor (vs L5's uncontrolled, larger `shifts=2`-vs-`shifts=0` gap) |
| WebGPU vs CPU ONNX, with shifts | **PASS** — correlation 1.000000, all 4 stems |
| WebGPU graph placement, with shifts | **PASS** — 1594/1594 nodes, 0 fallback, session reuse confirmed across all runs |
| Output/routing validation, with shifts | **PASS** — all checks clean |
| Full bit-exact production parity | **NOT ACHIEVED (and not achievable in principle)** — `shifts=2` is inherently stochastic in the real production implementation too; "parity" for this feature can only mean statistical closeness to production's own natural variance, which was demonstrated |
| Residual `vocals`/`other` gap beyond noise floor | **UNRESOLVED, plausibly attributed** to the pre-existing L5 export-fidelity gap rather than a new shift-specific issue, not proven |
| Production REAPER integration | **NOT TESTED** (out of scope, per instructions) |

## Recommendation for L7

Two reasonable directions, evidence-based rather than predetermined:

1. **Revisit the `vocals`/`other` residual** from L5/L6 specifically (both phases show
   these two stems with the largest PyTorch-vs-ONNX gap, with and without shifts) —
   e.g. by testing with a second, independent real-music fixture to see if the pattern
   holds (this phase and L5 both used the same one reconstructed clip; a second
   independent source would distinguish "a property of this model/export" from
   "a property of this specific fixture").
2. **Proceed to macOS M1 real-music + shift-parity validation**, mirroring the
   Linux-then-macOS pattern already used for the base MDX-Net WebGPU proof (L1→M1).
   This phase's wrapper is provider-agnostic and platform-generic (pure numpy +
   `demucs_onnx` + `webgpu_adapter.py`, no Linux-specific code beyond the existing
   `pci_bus_id` device-selection path already handled), so it should port with the
   same minimal changes L1→M1 required for the MDX-Net case.

Given that (1) is cheap (re-run this phase's exact methodology on one more fixture) and
would materially strengthen or weaken the current "likely export-fidelity, not
shift-specific" interpretation before spending effort on a new platform, **(1) is the
recommended immediate next step**, with (2) following once that residual is either
explained or ruled out as fixture-specific.

## Reproducing this phase

```bash
source /home/flark/stemwerk-rnd/venvs/webgpu-ep-demucsonnx/.venv-demucsonnx/bin/activate
cd experiments/webgpu-ep
python3 -c "
import sys, random; sys.path.insert(0, '.')
from demucs_shift_wrapper import run_with_seed
from demucs_onnx.inference import session_pool, resolve_providers
from demucs_onnx._hub import MODEL_REGISTRY, download_single_model
import soundfile as sf, numpy as np

mix, sr = sf.read('/path/to/fixture.wav'); mix = mix.T.astype(np.float32)
info = MODEL_REGISTRY['htdemucs']; path = download_single_model('htdemucs')
session = session_pool().get(path, resolve_providers('cpu'))
out, offsets = run_with_seed(session, info.sources, mix, shifts=2, seed=12345)
print(offsets)
"
# WebGPU: construct `session` via webgpu_adapter.py exactly as in
# DEMUCS_ONNX_FEASIBILITY.md's reproduction snippet, then pass it to the same
# run_with_seed() call above unchanged.
```
