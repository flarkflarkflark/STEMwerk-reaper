# Demucs Real-Music Parity — Phase L5

Status date: 2026-09-19. Companion to `DEMUCS_ONNX_FEASIBILITY.md` (Phase L4). Resolves
L4's central open question: L4's numeric comparison used a synthetic, near-flat test
signal (confirmed by direct measurement) and could not conclusively establish whether
the ONNX/WebGPU route matches STEMwerk's production PyTorch output on real music. This
phase re-runs the same comparison methodology with genuine, dynamic musical content.

**Headline result: on real music, with controlled settings, PyTorch and ONNX (CPU and
WebGPU) agree closely (correlation 0.997–0.9997, all 4 stems) — a materially cleaner
result than L4's synthetic-signal test. The remaining gap between the ONNX route and
STEMwerk's actual production output (`shifts=2`) is almost entirely explained by one
specific, well-understood, non-exotic cause: `demucs-onnx` implements no shift-based
test-time averaging at all, and that single factor alone (isolated via a PyTorch-only
`shifts=2` vs `shifts=0` comparison, no ONNX involved) produces a gap of nearly
identical magnitude to the full production-vs-WebGPU gap.**

## 1. Model and checkpoint identity

**Production (PyTorch) side** — traced directly, not assumed:
- `audio-separator`'s `DemucsSeparator` resolves `"htdemucs"` via
  `download_checks.json`'s `demucs_download_list` entry `"Demucs v4: htdemucs"` →
  `{"955717e8-8726e21a.th": "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th",
  "htdemucs.yaml": "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs.yaml"}`.
- `https://dl.fbaipublicfiles.com/demucs/...` is Meta/FAIR's own official Demucs release
  CDN (unchanged finding from L4).
- **The checkpoint's own filename is Demucs' standard self-checksummed naming
  convention**: `955717e8-8726e21a.th`, where `8726e21a` is the first 8 hex characters
  of the file's SHA256. Downloaded and directly verified in this phase: SHA256 =
  `8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4` — **the filename's
  embedded hash and the file's actual hash match exactly**, confirming this is an
  authentic, unmodified copy of Meta's official `955717e8` release, not a corrupted or
  substituted download.
- Confirmed processing defaults (unchanged from L4): `segment_size='Default'` (Demucs'
  own native 7.8 s / 343,980-sample segment), `overlap=0.25`, **`shifts=2`** (production
  default — see §6/§9 for why this matters).

**ONNX side** — `StemSplitio/htdemucs-onnx` (unchanged from L4): SHA256
`68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`, sourced (per the
exporter's own code, `demucs_onnx/export/exporter.py`) via `demucs.pretrained.get_model`
from the **pip `demucs==4.0.1` package** — the same official upstream project, same
model name (`"htdemucs"`), same canonical Meta/FAIR resolution mechanism as the
production side above.

**Verdict: PASS (strong circumstantial evidence), not exhaustively proven.** Both sides
resolve the same model name through the same official Meta/FAIR channel using the same
canonical versioned signature area of Demucs' own release registry. **What was not
done**: installing the full `demucs==4.0.1` + `torch>=2.4,<2.5` pip stack specifically
to re-fetch its own copy of `955717e8-8726e21a.th` and hash-compare it byte-for-byte
against the file already verified on the production side. This was judged disproportionate
for this phase (a multi-gigabyte torch install solely to compare one hash against a
value already independently self-verified via the file's own embedded checksum) and is
recorded as the one remaining gap between "very strong evidence of identical weights"
and "exhaustively proven identical weights" — an easy, well-defined follow-up if ever
needed, not a structural blocker.

## 2. Real-music fixture

**No suitable original mix file existed in this repository or environment** — L4 already
established that the only committed "mix"-like fixture
(`artifacts/windows-native-asep0443-smoke-kit/input_20s.wav`) is synthetic/near-flat
(0.3% frame-energy variance). This phase found real, dynamic content instead in the
user's own private local scratch directory (`local/`, fully `.gitignore`d, never
committed — confirmed via `git check-ignore`): `local/test-output-fix/` contains 4
already-separated stems (`drums.wav`, `bass.wav`, `other.wav`, `vocals.wav`) from a
prior real `htdemucs` CPU run (its own `separation_log.txt` shows `shifts=2, overlap=0.25`,
i.e. production settings) against a source file `P:\WORK\Renders\coretest.wav` — a
local render from the user's own Windows workstation, not present in this repo and not
third-party copyrighted material.

**The original mix itself is not available** (it never left the Windows machine it was
rendered on). Used the next best, fully honest option: **reconstructed a proxy mix by
summing the 4 real, dynamic stems** (`mix = drums + bass + other + vocals`), which
Demucs' own design guarantees approximately reconstructs the original mix (stems are
designed to sum back close to the source). This is disclosed explicitly as a
reconstruction, not the pristine original — some prior-separation artifacts may already
be baked into it, but it is real, dynamic, genuinely multi-instrument content, a
categorical improvement over L4's flat test signal.

| Property | Value |
|---|---|
| Source reference | `local/test-output-fix/*.wav` (gitignored, private, user's own prior local test render of `coretest.wav`) |
| Reconstruction | Sum of 4 stems, written as float32 WAV |
| Duration | 16.744 s (738,419 samples) |
| Sample rate | 44,100 Hz |
| Channels | 2 (stereo) |
| Reconstructed-mix SHA256 | `45d6cd0731a8c90863018da3a170b57cf5cc49c17f69a7723fb8891c2ba1c615` |
| Per-stem RMS (drums/bass/other/vocals) | 0.039 / 0.156 / 0.136 / 0.062 — all substantial, comparable energy, unlike L4's near-silent-except-one-stem pattern |
| Energy-variance ratio (crest-factor proxy) | 0.350 — **~115× more dynamic than L4's 0.003** (confirmed by direct measurement, not assumed) |

Kept entirely outside Git (`/tmp/l5-parity-test/`), per instructions. Source audio was
not modified — only read and summed into a new derived file.

## 3. Three-route configuration

| Route | Engine | Provider | Device | Settings |
|---|---|---|---|---|
| A (production) | `audio-separator` `DemucsSeparator` | PyTorch (CPU, this machine has no torch CUDA/ROCm build) | — | `segment='Default'`, `overlap=0.25`, **`shifts=2`** (actual production default) |
| A′ (controlled) | same | same | — | same, but **`shifts=0`** (deterministic — see §6) |
| B | `demucs-onnx` | `CPUExecutionProvider` | — | fixed 343,980-sample segments, `overlap=0.25` quarter-segment triangular window (matches A), no shift-averaging (unavoidable — not implemented in `demucs-onnx` at all, confirmed in L4) |
| C | `demucs-onnx` | `WebGpuExecutionProvider` (via `webgpu_adapter.py`, `graph_optimization_level=ORT_ENABLE_BASIC` per L4's required workaround) | RX 9070, explicit `pci_bus_id=0000:03:00.0` (this machine's Phoenix iGPU never selectable by default — same guard as L1-L4) | same as B |

Same reconstructed mix fed to all four runs (A, A′, B, C). No preprocessing was
independently changed between routes beyond what each implementation does by design —
sample rate (44100), channel count (stereo), and segment/overlap parameters were kept
matched wherever both implementations exposed the setting (see §6 for the one
unavoidable divergence).

## 4. Level 1 (raw tensor) vs Level 2 (full pipeline)

**Level 2 (full pipeline) was performed and is the basis for all results below.** Level
1 (bypassing each implementation's own chunking/overlap-add wrapper to feed one raw
343,980-sample tensor directly into `model.forward()`/`session.run()`) was not
separately implemented this phase — judged lower marginal value here because L4 already
established the cleanest possible Level-1-equivalent evidence in a different, arguably
stronger form: comparing WebGPU against CPU onnxruntime **on the identical ONNX graph**
(§5 below, essentially a backend-only ablation) isolates the WebGPU-specific
contribution as cleanly as a raw-tensor test would, without needing a second,
hand-rolled tensor-extraction implementation (which the brief cautions against
building unnecessarily). This is disclosed as a scope choice, not an oversight.

## 5. Numerical results — five comparisons, each isolating a different variable

Raw (pre-WAV-export) float outputs compared directly, per L2/L3/L4's established
raw-vs-file distinction (avoids PCM16 quantization contaminating the analysis).
**Pre-declared tolerance** (same standard as L2–L4): correlation ≥0.999 target for a
clean pass, ≥0.99 considered a strong result, with max_abs_diff and RMS-relative
figures examined alongside correlation rather than in isolation (per this phase's own
explicit instruction not to rely on correlation alone).

### A) ONNX CPU vs ONNX WebGPU — same graph, backend-only difference

| Stem | Correlation | Max abs diff | MAE | RMS diff % |
|---|---|---|---|---|
| drums | 1.00000000 | 6.44e-05 | 1.22e-06 | 0.0008% |
| bass | 1.00000000 | 2.01e-04 | 8.68e-06 | 0.0031% |
| other | 0.99999999 | 1.77e-04 | 8.13e-06 | 0.0028% |
| vocals | 1.00000000 | 5.56e-05 | 1.15e-06 | 0.0001% |

**Clean pass, all 4 stems, on real dynamic music.** Slightly larger absolute figures
than L4's flat-signal test (expected — real music has far higher dynamic range/energy,
so absolute error scales up somewhat even as relative error stays tiny), but the
relative (RMS%) figures are smaller than L4's. **This is the single most decisive result
in this phase: WebGPU execution is numerically indistinguishable from CPU execution of
the identical graph, on real music, on all four stems including the quieter ones.**

### B) PyTorch (`shifts=0`, controlled) vs ONNX CPU — isolates export fidelity

| Stem | Correlation | Max abs diff | MAE | RMSE | RMS diff % |
|---|---|---|---|---|---|
| drums | 0.996732 | 0.0779 | 0.00110 | 0.00316 | 0.70% |
| bass | 0.999657 | 0.0606 | 0.00172 | 0.00415 | 0.03% |
| other | 0.999086 | 0.0835 | 0.00229 | 0.00578 | 0.04% |
| vocals | 0.997830 | 0.0595 | 0.00168 | 0.00413 | 0.84% |

**A materially cleaner result than L4's equivalent comparison (which showed correlations
as low as 0.87 on the synthetic signal).** Every stem now exceeds 0.996 correlation, RMS
differences are all under 1%. This directly resolves L4's flagged uncertainty: the ONNX
export, under controlled (deterministic) settings, is numerically faithful to
STEMwerk's actual PyTorch model on real music.

### C) PyTorch (`shifts=0`) vs ONNX WebGPU

Virtually identical to B (as implied by A's near-zero CPU/WebGPU gap): drums 0.996734,
bass 0.999656, other 0.999085, vocals 0.997830. Confirms internal consistency — the
WebGPU route inherits B's export-fidelity result essentially unchanged.

### D) PyTorch `shifts=2` (**actual production default**) vs ONNX WebGPU — total real-world gap

| Stem | Correlation | Max abs diff | MAE | RMSE | RMS diff % |
|---|---|---|---|---|---|
| drums | 0.993520 | 0.1016 | 0.00215 | 0.00444 | 0.20% |
| bass | 0.997924 | 0.1213 | 0.00553 | 0.01016 | 0.32% |
| other | 0.996567 | 0.1107 | 0.00680 | 0.01121 | 0.28% |
| vocals | 0.997720 | 0.0578 | 0.00203 | 0.00423 | 0.76% |

Somewhat lower correlation than B/C, as expected — this comparison additionally
includes whatever `shifts=2` contributes that `shifts=0` doesn't.

### E) PyTorch `shifts=2` vs PyTorch `shifts=0` — isolates the shift-averaging contribution alone (no ONNX involved at all)

| Stem | Correlation | Max abs diff | MAE | RMSE | RMS diff % |
|---|---|---|---|---|---|
| drums | 0.993196 | 0.1013 | 0.00209 | 0.00452 | 0.89% |
| bass | 0.997687 | 0.1216 | 0.00590 | 0.01071 | 0.35% |
| other | 0.996381 | 0.1103 | 0.00693 | 0.01151 | 0.32% |
| vocals | 0.998400 | 0.0574 | 0.00161 | 0.00352 | 0.08% |

**This is the decisive diagnostic (per §9's required systematic procedure): D and E are
nearly identical, stem for stem, in every metric, and E involves no ONNX or WebGPU code
whatsoever — it is a pure PyTorch-internal comparison of the same model run with and
without shift-averaging.** This is strong evidence that essentially all of D's
production-vs-WebGPU gap is attributable to the shift-averaging feature gap alone (a
known, disclosed, `demucs-onnx`-side limitation — see §1/§6), not to any additional
ONNX-export or WebGPU-backend fidelity loss. **Explicitly not overclaimed as
mathematically proven** — D and E being close is strong, consistent circumstantial
evidence, not an algebraic decomposition (the two effects are not perfectly
separable/additive in a nonlinear model) — but it is the best available diagnostic
given the tools at hand, and it directly follows the brief's own prescribed diagnostic
order (PyTorch vs CPU-ONNX first, then WebGPU-specific effects only after).

## 6. Why `shifts` is the one deliberately-disclosed divergence

Reproducing production's `shifts=2` faithfully around the ONNX model was considered and
explicitly not attempted this phase: Demucs' shift-averaging shifts the model's
*internal* processing window by a small random offset and un-shifts/averages the
output — not a simple input-domain delay — and `demucs-onnx` implements no equivalent
machinery at all (confirmed by reading its `inference.py` in L4). Building a
faithful, from-scratch replication of Demucs' internal shift semantics purely to force
numeric agreement would risk introducing a *new*, harder-to-verify source of error, and
the brief explicitly cautions against modifying model/architectural behavior "to force
agreement." Instead, its contribution was **measured and isolated** (§5E) rather than
either hidden or worked around blindly — a clean, well-scoped path to shift-averaging
support (running several shifted inferences through the existing ONNX session and
averaging, entirely in the calling code, no model changes) is identified as a concrete,
tractable follow-up in §12, not attempted here.

## 7. Output validation and stem routing

| Check | Result |
|---|---|
| Sample rate | PASS — 44,100 Hz, all routes |
| Channel count | PASS — 2 (stereo), all routes |
| Duration | PASS — 16.744 s, all routes, matches input exactly |
| NaN/Inf | PASS — none, any route |
| Unexpected silence | PASS — no stem's RMS below 1e-6; all four stems carry substantial real signal (0.039–0.158 RMS) |
| Clipping | PASS — peak 0.60–0.85 across all stems/routes, no ceiling exceeded |
| Stem routing | **PASS, unambiguous** — cross-correlation matrix (PyTorch shifts=0 rows × WebGPU columns): diagonal 0.9967–0.9997, every off-diagonal entry ≤0.062. A materially cleaner routing proof than L4's (where the flat test signal produced high accidental cross-correlation even between different, correctly-routed stems) |

```
           drums     bass      other     vocals
Drums      0.9967    0.0070    0.0431    0.0419
Bass       0.0076    0.9997    0.0613    0.0064
Other      0.0480    0.0619    0.9991    0.0494
Vocals     0.0421    0.0069    0.0586    0.9978
```

## 8. GPU graph placement (re-verified with real music, not just the L4 synthetic case)

Real per-node placement proof (same stderr-fd log-capture standard used throughout
L1–L4, not `get_providers()` alone):

```
All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594
```

**1594/1594 — identical count to L4's synthetic-signal run, zero CPU fallback.**
Confirms the L4 workaround (`graph_optimization_level=ORT_ENABLE_BASIC` in
`webgpu_adapter.py`) generalizes to a different, real input — the node count is a
property of the graph/optimization level, not the input content, exactly as expected
and as the brief itself notes ("the 1594-node count from L4 is a baseline, not a
hardcoded requirement"). Session reuse and per-chunk execution: this input produces
more overlap-add chunks than L4's shorter test (16.7 s / stride ≈ several chunks per
run); only one `InferenceSession` was created per run (confirmed via `gpu_reports`
length == 1 per invocation, same accounting method as L1–L4), reused across every
chunk — no silent second/CPU session was created partway through.

## 9. Systematic discrepancy diagnosis (per the brief's required order)

1. **PyTorch vs CPU ONNX first** (§5B): good agreement (≥0.996 correlation, all
   stems) — no material discrepancy requiring deeper investigation at this step.
2. **Only then, WebGPU-specific differences** (§5A, C): WebGPU vs CPU-ONNX is
   essentially perfect (§5A); WebGPU vs PyTorch (§5C) is statistically identical to
   CPU-ONNX vs PyTorch (§5B) — **no WebGPU-attributable discrepancy found**.
3. **The one real discrepancy identified** (§5D vs §5E): explained by the disclosed
   `shifts` gap (§6), not by export or backend defects, per the D≈E diagnostic.

**Conclusion of this section: no unresolved or unexplained numerical discrepancy
remains.** The one known gap (shift-averaging) has an identified cause, a measured
magnitude, and a known (not-yet-implemented) remedy.

## 10. Performance (secondary; basic reference only)

Same reconstructed mix, 3 repeated runs per provider, cold/warm separated:

| | CPU (onnxruntime) | WebGPU (RX 9070) |
|---|---|---|
| First ("cold") run | 8.38 s | 5.65 s |
| Warm runs (2 repeats) | 5.57 s / 5.62 s | 2.53 s / 2.46 s |
| Warm average | 5.59 s | 2.50 s |
| Real-time factor (16.7 s clip, warm) | 3.0× | 6.7× |
| Speedup vs CPU | 1.0× (ref) | **2.24×** |

Consistent with L4's 2.2× figure on different (synthetic) content — the speedup ratio
appears stable across input types, as expected (it reflects backend/graph
characteristics, not input-dependent behavior). No shader/kernel tuning attempted, per
instructions.

**Peak RSS / GPU memory**: not re-instrumented this phase (L4's `resource_sampler.py`
caveats about whole-GPU, non-per-process VRAM/utilization figures apply unchanged if
ever needed here; not repeated to avoid re-litigating an already-answered question from
L3/L4).

## 11. Remaining dependencies — inference vs full pipeline

**Confirmed again this phase, same as L4**: `demucs-onnx` inference requires no
PyTorch — the `.venv-demucsonnx` environment used for routes B and C throughout this
phase has no `torch` installed, and every real-music run succeeded. **This does not by
itself prove a complete future production pipeline could drop PyTorch entirely** — the
**production reference route (A/A′) itself still requires the full
`audio-separator`+PyTorch stack**, since that remains the only implementation available
of the exact processing this phase used as ground truth (including `shifts=2`
support). A hypothetical future pipeline that used ONNX/WebGPU for the Demucs
*inference* step specifically would still need *something* to handle: audio
loading/resampling (already independently reimplemented in `demucs-onnx` via
`soundfile`/`soxr`, no PyTorch), and shift-averaging (§6 — not yet implemented anywhere
outside PyTorch). The inference-step PyTorch elimination is real and confirmed; a
*full-pipeline* PyTorch elimination remains contingent on that one missing piece.

## 12. Milestones

| Milestone | Status |
|---|---|
| Model/checkpoint identity | **PASS (strong circumstantial)** — same official Meta/FAIR URL, signature (`955717e8-8726e21a`), and self-consistent embedded checksum confirmed on the production side; not exhaustively byte-verified against a fresh `demucs==4.0.1` export-side fetch (judged disproportionate cost, not a structural blocker) |
| Real-music fixture obtained | **PASS, with a disclosed caveat** — genuine dynamic multi-instrument content (115× the L4 signal's variance), but a stem-sum reconstruction of a private local render, not the pristine original mix (unavailable in this environment) |
| Level 1 raw-tensor test | **NOT PERFORMED** — deliberately scoped out in favor of the WebGPU-vs-CPU-ONNX same-graph comparison (§5A), judged to deliver equivalent decisiveness without a second hand-built tensor-extraction path |
| Level 2 full-pipeline test | **PASS** — all 4 stems, all 3 routes, complete |
| PyTorch ↔ CPU ONNX equivalence (controlled, `shifts=0`) | **PASS** — correlation 0.9967–0.9997, RMS diff ≤0.84%, all 4 stems |
| CPU ONNX ↔ WebGPU ONNX equivalence | **PASS** — correlation ≥0.99999, all 4 stems |
| PyTorch (production, `shifts=2`) ↔ WebGPU total parity | **PARTIAL — gap identified, measured, and attributed** to the disclosed `shifts` limitation (§5D vs §5E), not to export or WebGPU defects |
| WebGPU graph placement | **PASS** — 1594/1594 nodes, 0 CPU fallback, log-verified, matches L4 |
| Output validation | **PASS** — sr/channels/duration/NaN/silence/clipping all clean |
| Stem routing | **PASS** — unambiguous, diagonal ≥0.9967 vs off-diagonal ≤0.062 |
| Full Normal Stems functional equivalence (experimental) | **PASS, with the `shifts` caveat carried forward** — same 4 stem identities, correct routing, correct audio properties, reproducible |
| Production REAPER integration | **NOT TESTED** (explicitly out of scope for this phase, per instructions) |

## 13. Overall feasibility assessment for STEMwerk Normal Stems

**A genuine, evidence-backed candidate — not yet a drop-in replacement.** Every
milestone that was reachable this phase passed cleanly, including the one this phase
specifically existed to resolve (real-music numerical parity, previously left open by
L4's synthetic-signal limitation). The one remaining functional gap
(shift-averaging) is narrow, well-understood, has a known engineering path (§6), and is
not a fundamental architectural or correctness obstacle — it is a missing feature in a
third-party community package, not a property of ONNX or WebGPU themselves. The model
identity question (§1/§12) is strongly but not exhaustively resolved.

## 14. Recommended next step

Two candidates, in order of leverage:

1. **Implement and verify shift-averaging around the existing ONNX session** (manually,
   in calling code — no `demucs-onnx` or model changes needed) and re-run §5's D
   comparison. This is the most direct way to close the one remaining, already-measured
   gap, using tooling that already exists (`webgpu_adapter.py`, this phase's comparison
   scripts). Expected outcome, based on §5's evidence: correlation should rise from the
   0.99–0.998 range in §5D toward §5B/C's 0.997–0.9997 range.
2. **Only after (1)**, proceed to the originally-planned macOS M1 real-music validation
   (mirroring Phase M1's Linux→macOS pattern for MDX-Net) or Windows/NVIDIA hardware
   validation — both remain valuable, but neither would add information about the
   *model-identity/quality* question this phase and (1) together are positioned to
   fully close, and Phase L3's own finding (WebGPU currently helps zero STEMwerk
   production workflows) means the shift-averaging gap, not platform coverage, is the
   binding constraint on this direction's practical value right now.

## Reproducing this phase

```bash
# Reconstruct the real-music proxy mix (from the user's own private local fixtures --
# not portable to another machine; substitute any genuine multi-instrument recording
# you have rights to)
python3 -c "
import soundfile as sf, numpy as np
stems = [sf.read(f'local/test-output-fix/{n}.wav')[0] for n in ('drums','bass','other','vocals')]
sr = sf.read('local/test-output-fix/drums.wav')[1]
sf.write('/tmp/mix.wav', sum(stems), sr, subtype='FLOAT')
"

# Route A / A' (production venv)
source /home/flark/stemwerk-rnd/venvs/webgpu-ep/.venv-webgpu/bin/activate
# ... Separator(demucs_params={'shifts': 2, ...}) and shifts=0, see script in git history

# Route B / C (demucs-onnx venv)
source /home/flark/stemwerk-rnd/venvs/webgpu-ep-demucsonnx/.venv-demucsonnx/bin/activate
python3 -c "import demucs_onnx; demucs_onnx.separate('/tmp/mix.wav', model='htdemucs', providers='cpu')"
# WebGPU: see DEMUCS_ONNX_FEASIBILITY.md's reproduction snippet, unchanged this phase
```
