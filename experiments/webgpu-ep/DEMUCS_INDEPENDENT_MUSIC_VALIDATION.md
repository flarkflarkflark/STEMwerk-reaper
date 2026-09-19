# Demucs Independent Music Validation — Phase L7

Status date: 2026-09-19. Companion to `DEMUCS_SHIFT_PARITY.md` (L6). Tests whether L6's
residual `vocals`/`other` gap (1.22×–1.67× PyTorch's own noise floor) is a property of
the model/export, or an artifact of L5/L6's one test fixture (which was itself a
stem-sum *reconstruction*, not an original mix — disclosed at the time as a caveat).

**Headline result: the L6 residual does not reproduce on this second, independent,
original-mix fixture — if anything, parity is stronger here.** On this fixture, every
one of the four stems (including vocals and other) shows a PyTorch-vs-ONNX gap
*smaller* than PyTorch's own run-to-run noise floor (ratio 0.66×–0.73×, uniformly,
across all four stems) — compared to L6's 1.01×–1.67× with the worst case on vocals.
This is evidence, not proof, that L6's elevated vocals/other ratio was more likely
related to that fixture's reconstructed (stem-sum) provenance than to a general
model/export property — see "Interpretation" below for exactly how strong a claim this
supports.

**A real bug in this phase's own analysis code was found and fixed before any of the
above was trusted** — documented in full in §L7.3, per the standing instruction to
investigate anomalies rather than report them.

## L7.1: Independent fixture

Searched systematically for a second, genuinely independent real-music source, in this
priority order: (1) other `local/` STEMwerk test-output directories (all four found
traced back to the same `coretest.wav` already used in L5/L6 — confirmed via each
directory's own `separation_log.txt` "Processing file:" line, not assumed); (2) the
user's personal `~/Music` library, which contains both clearly-personal STEMwerk test
renders (`stemwerk_reaperr_dnb1/2.wav`, `RECwerk-output.wav`, `TEST.wav`,
`modeltest.wav`, `loop.wav`) and unrelated commercial/copyrighted tracks (kept out of
consideration entirely — not used, not analyzed, not referenced further).

Selected **`/home/flark/Music/modeltest.wav`** — chosen over the `dnb` renders for a
combination of duration, dynamic range, and zero clipping (see table). Unlike L5/L6's
fixture, **this is a genuine original mix**, not a reconstruction from separated stems
— a strictly better provenance category for this kind of test.

| Property | Value |
|---|---|
| Source | `/home/flark/Music/modeltest.wav` (personal STEMwerk test file, outside any git repository — confirmed via `git status`, "outside repository") |
| Full-file duration | 57.1 s |
| Excerpt used | first 25.0 s (0–25 s) — checked second-by-second for dead air first; none found, RMS stayed in a healthy 0.07–0.18 range throughout the full 57 s |
| Sample rate | 44,100 Hz |
| Channels | 2 (stereo) |
| Full-file SHA256 | `7d2092ef7ca746aa8cb4eb8698ac0d7394aa7ff4ee6dbc614cffda7c595709fa` |
| Excerpt SHA256 | `c4e0e755d1d6f2a9e8e38e11ec1b9cae0324253ebce3bf54fc468c37373634ba` |
| Energy-variance ratio (crest-factor proxy, same metric as L4/L5) | 0.513 — genuinely dynamic (L4's synthetic signal: 0.003; L5/L6's fixture: 0.350) |
| RMS / peak (excerpt) | 0.122 / 0.695 — no clipping |
| Segments per 7.8 s Demucs window | 25.0 s / (0.75 × 7.8 s stride) ≈ 4 internal chunks — more than L5/L6's ~3, satisfying "sufficient duration for multiple inference segments" more comfortably |

Kept entirely outside Git throughout (`/tmp/l7-parity-test/`), per instructions.

## L7.2: Repeated-run validation

Same three-seed design as L6, applied identically to the new fixture: `shifts=0`
baseline (deterministic, one run each) + `shifts=2` at seeds `111`, `222`, `333`, for
all three routes (PyTorch, ONNX CPU, ONNX WebGPU). Offsets observed and logged:

| Seed | ONNX offsets (CPU and WebGPU — identical, as established in L6) |
|---|---|
| 111 | `[6971, 10353]` |
| 222 | `[3535, 7708]` |
| 333 | `[18180, 11495]` |

Per L6's already-established finding (not re-litigated here): PyTorch's actual offsets
at the same seeds are **not** expected to match these beyond the first draw, because of
the positional-embedding RNG coupling documented in full in `DEMUCS_SHIFT_PARITY.md`
§L6.1/§L6.3. This phase did not attempt to re-verify that mechanism (already
conclusively established) and used the same repeated-run statistical comparison
approach throughout, as instructed ("do not introduce fragile global-RNG manipulation
... unless testing exposes a demonstrable defect" — none was found, so L6's design was
kept unchanged).

## L7.3: Numerical analysis — including a self-discovered bug

**A serious-looking anomaly appeared on the first analysis pass and was investigated
before being trusted, per standing instructions.** The first comparison run showed
strongly *negative* correlations for `drums` (as low as −0.96) even in the fully
deterministic `shifts=0` case — a result that would imply a severe routing or
alignment failure. Investigated rather than reported: RMS values between the two
routes matched almost exactly (0.084968 vs 0.084937 for `drums`) despite the
catastrophic correlation figure, which is the signature of a **shape/orientation bug in
the comparison code itself**, not a real signal problem. Confirmed directly: this
phase's comparison helper computed the array length from `shape[-1]` before normalizing
channel/sample axis order, and PyTorch's captured arrays are `(samples, 2)` while ONNX's
are `(2, samples)` — so for PyTorch arrays, `shape[-1]` returned the **channel count**
(2), not the sample count, silently comparing near-empty slices. Fixed by normalizing
both arrays to `(channels, samples)` before computing length, then re-verified with a
direct sanity check (`shifts=0`, deterministic, expected a clean match): corrected
`drums` correlation came out to **0.999466**. **All results below are from the
corrected code only** — the broken numbers are not reported anywhere else in this
document. This is disclosed in this much detail specifically because the brief warns
against "adjusting acceptance thresholds after seeing results," and the discipline that
applies to is the same discipline that requires disclosing when the *code*, not the
threshold, turned out to be wrong.

### `shifts=0` (deterministic, single measurement, L5-equivalent)

| Stem | PT vs ONNX-CPU correlation | PT vs ONNX-CPU rel. RMS error |
|---|---|---|
| drums | 0.999466 | 3.27% |
| bass | 0.999124 | 4.19% |
| other | 0.998903 | 4.69% |
| vocals | 0.999272 | 3.82% |

PT vs WebGPU is identical to three decimal places throughout this phase (as in L4–L6) —
not re-tabulated separately below except where it's the primary comparison.

**Notably tighter and more uniform than L5's `shifts=0` table** (L5: 0.9967–0.9997,
with `drums`/`vocals` the outliers; here: 0.9989–0.9995, no stem-specific outlier
pattern at all). Consistent with the hypothesis that an *original* mix produces cleaner
parity than L5/L6's *reconstructed* one.

### `shifts=2`, repeated-run statistics (mean ± std across seed-pairs/seeds)

| Stem | PyTorch noise floor | ONNX-CPU noise floor | PyTorch vs ONNX-CPU | PyTorch vs WebGPU | **Ratio (PT-vs-WebGPU / PT-noise-floor)** |
|---|---|---|---|---|---|
| drums | 4.02% ± 0.75% | 4.12% ± 0.39% | 2.93% ± 0.12% | 2.93% ± 0.12% | **0.73×** |
| bass | 7.76% ± 2.30% | 7.39% ± 1.16% | 5.35% ± 0.44% | 5.35% ± 0.44% | **0.69×** |
| other | 6.27% ± 1.23% | 6.35% ± 0.54% | 4.51% ± 0.21% | 4.51% ± 0.21% | **0.72×** |
| vocals | 5.26% ± 1.15% | 5.23% ± 0.81% | 3.47% ± 0.32% | 3.47% ± 0.32% | **0.66×** |

(all figures are relative-RMS-error percentages; correlations for every individual
seed/stem/route pair are in the raw run logs — all ≥0.995, most ≥0.998, none below
0.93 anywhere after the bug fix, a categorical improvement over the pre-fix numbers)

**ONNX CPU vs WebGPU** (backend-only difference, same offsets): correlation
**1.000000** and relative RMS error **≤0.013%**, every stem, every seed — unchanged
from L4–L6, confirming WebGPU backend fidelity holds on this fixture too.

### Interpretation

**All four ratios are below 1.0** — meaning, on this fixture, the PyTorch-vs-ONNX-WebGPU
gap is *smaller* than the gap between two independent runs of PyTorch *itself*, for
every stem, including `vocals` and `other`. This directly answers L7's central
question: **the L6 residual (vocals/other showing 1.22×–1.67× the noise floor) does not
reproduce here.** Two fixtures is not a large sample — this is explicitly *not* claimed
as proof that vocals/other are never worse, only as evidence against "vocals/other are
*consistently, structurally* worse than drums/bass" as a general property of the
model/export. The available evidence is more consistent with L6's residual being
related to that fixture's reconstructed-mix provenance (a hypothesis raised at the
time, now supported rather than refuted) than with an inherent per-stem asymmetry in
the ONNX export itself. **Neither fixture is claimed to be statistically representative
of "all music"** — two real, independently-sourced clips is meaningfully more evidence
than one, but not a general guarantee across genres, mix styles, or mastering choices.

## L7.4: Performance

Same fixture, cold (`shifts=0`, first call per backend) then `shifts=2` at 3 seeds
(all effectively warm, since each backend's `shifts=0` call already primed the
session/shader-compile cost before the `shifts=2` runs):

| | PyTorch (production) | ONNX CPU | ONNX WebGPU |
|---|---|---|---|
| `shifts=0` | 6.94 s | 9.55 s | 3.92 s |
| `shifts=2`, seed 111 | 10.81 s | 19.12 s | 7.81 s |
| `shifts=2`, seed 222 | 11.18 s | 14.09 s | 7.81 s |
| `shifts=2`, seed 333 | 11.39 s | 18.22 s | 7.79 s |
| `shifts=2` average | 11.13 s | 17.14 s | **7.80 s** |
| RTF (25.0 s clip, `shifts=2` avg) | 2.25× | 1.46× | 3.21× |

**Speedup vs actual PyTorch production settings** (`shifts=2` average, 11.13 s):
**WebGPU (7.80 s) → 1.43× faster.** Lower than L6's 1.74× on the other fixture — a
different absolute number, not treated as a discrepancy requiring explanation (longer
clip, different content, different absolute compute-time ratios between fixed overhead
and per-sample work are all plausible, ordinary contributors) but reported honestly
rather than silently reconciled with L6's figure. **WebGPU's own `shifts=2` timing was
remarkably stable across all three seeds** (7.79–7.81 s, effectively identical) despite
the different random offsets each seed produces — consistent with runtime being
governed by total sample-count processed (which is offset-independent by construction)
rather than by the specific offset drawn. **ONNX CPU's timing was much noisier**
(14.09–19.12 s) — consistent with ordinary CPU scheduling/background-load variance
already observed throughout L1–L6, not a new finding.

**GPU execution evidence**: `gpu_reports` shows **exactly 1 verified WebGPU session**
across the entire WebGPU portion of this phase (1 `shifts=0` call + 3×2 `shifts=2`
internal calls = 7 total `_chunked_separate_single` invocations, all through the same
session). Placement proof unchanged: **1594/1594 nodes on WebGpuExecutionProvider, 0
CPU fallback.** No AMD-to-other-vendor or Linux-to-other-OS extrapolation is made
anywhere in this report — this remains an RX 9070 / Linux-only result, as in every
prior phase.

**Peak memory**: not separately re-instrumented this phase, consistent with L5/L6's
choice not to re-litigate an already-answered (and already heavily caveated) whole-GPU
measurement question.

## L7.5: Regression

| Check | Result |
|---|---|
| `shifts=0` still reproduces L5 (on L5's *own* fixture, re-run this phase) | **PASS** — bit-for-bit identical (`np.array_equal` true on all 4 stems) to the saved L5 baseline, re-verified directly before trusting anything else |
| `shifts=2` retains L6 behavior | **PASS** — same `demucs_shift_wrapper.py`, unmodified this phase (no defect was found that would have justified a change, per instructions) |
| Stem routing | **PASS, unambiguous** — cross-correlation diagonal ≥0.9984 vs off-diagonal ≤0.11 (mostly ≤0.04) on the new fixture, `shifts=2` |
| WAV/array output validity | **PASS** — correct shape `(2, 1,102,500)`, 25.000 s, 44,100 Hz, finite (no NaN/Inf), no silence (RMS 0.033–0.085), no clipping (peak 0.18–0.69) |
| No production code changes | **PASS** — read-only use of `audio-separator`, `demucs-onnx`, `webgpu_adapter.py`; no file in either package modified |
| No model/audio artifacts staged | **PASS** — verified via `git status`/`git add -A -n` before committing; only the two new/changed tracked files present |

## L7.6: Milestones

| Milestone | Status |
|---|---|
| Independent fixture found and documented | **PASS** — genuine original mix, different source, provenance fully documented |
| Repeated-run validation executed | **PASS** — 3 seeds × 3 routes × 2 shift settings |
| Analysis bug found and fixed before reporting | **PASS (self-caught)** — see §L7.3; nothing pre-fix is reported as a finding anywhere in this document |
| `shifts=0` parity, independent fixture | **PASS** — correlation 0.9989–0.9995, all 4 stems, tighter than L5 |
| `shifts=2` parity vs PyTorch noise floor, independent fixture | **PASS** — ratio 0.66×–0.73×, all 4 stems below 1.0× |
| L6's vocals/other residual reproduced here | **NOT REPRODUCED** — evidence against it being a general model/export property, not proof it never occurs |
| WebGPU vs CPU ONNX, with shifts | **PASS** — correlation 1.000000, all 4 stems |
| WebGPU graph placement, with shifts | **PASS** — 1594/1594, 0 fallback, 1 session reused across 7 internal calls |
| Stem routing / output validation | **PASS** |
| Regression (L5/L6 behavior unchanged) | **PASS** |
| "Two fixtures represent all music" | **NOT CLAIMED, explicitly** — see Interpretation above |

## Recommendation for L8

The model-identity/export-fidelity question that has driven L5→L6→L7 is now about as
well-characterized as two real fixtures on one platform can make it: parity holds, with
appropriate statistical framing, and the one residual concern from L6 did not generalize.
Continuing to add more Linux/RX-9070 fixtures has **declining marginal value** at this
point relative to the two higher-leverage directions already identified across L1–L6 and
not yet acted on:

1. **macOS M1 validation of this same shift-averaging + real-music methodology**
   (mirroring the L1→M1 pattern already used for the base MDX-Net proof). This is the
   more valuable next step: it tests a genuinely new dimension (platform/GPU vendor)
   rather than accumulating more same-platform fixtures, and `demucs_shift_wrapper.py`
   was written provider-agnostically specifically so this should require minimal
   platform-specific changes (the same `pci_bus_id`-vs-single-device pattern already
   handled by `webgpu_adapter.select_device()`).
2. Only if resources allow after (1): a third Linux fixture specifically chosen to be
   *closer in character* to L5/L6's reconstructed-stem fixture (e.g. deliberately
   sparse/ambient content) to directly test the "reconstructed mix vs original mix"
   hypothesis this phase's evidence supports but doesn't prove.

**(1) is the recommended next step.**

## Reproducing this phase

```bash
source /home/flark/stemwerk-rnd/venvs/webgpu-ep-demucsonnx/.venv-demucsonnx/bin/activate
cd experiments/webgpu-ep
python3 -c "
import sys; sys.path.insert(0, '.')
from demucs_shift_wrapper import run_with_seed
from demucs_onnx.inference import session_pool, resolve_providers
from demucs_onnx._hub import MODEL_REGISTRY, download_single_model
import soundfile as sf, numpy as np

# Substitute any real, independently-sourced multi-instrument recording you have
# rights to -- provenance must be documented per L7.1's table above.
mix, sr = sf.read('/path/to/your/independent_fixture.wav')
mix = mix.T.astype(np.float32)
info = MODEL_REGISTRY['htdemucs']; path = download_single_model('htdemucs')
session = session_pool().get(path, resolve_providers('cpu'))
out, offsets = run_with_seed(session, info.sources, mix, shifts=2, seed=111)
print(offsets)
"
# WebGPU: construct `session` via webgpu_adapter.py as in DEMUCS_ONNX_FEASIBILITY.md's
# reproduction snippet, pass it to the same run_with_seed() call. IMPORTANT: when
# comparing PyTorch and ONNX arrays yourself, normalize both to (channels, samples)
# BEFORE computing any length/slicing -- see L7.3 for exactly the bug this guards against.
```
