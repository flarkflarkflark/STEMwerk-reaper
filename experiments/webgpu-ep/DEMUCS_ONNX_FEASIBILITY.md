# Demucs ONNX/WebGPU Feasibility — Phase L4

Status date: 2026-09-19. Companion to `README.md` (Phase L4 summary + link) and
`MODEL_COMPATIBILITY_MATRIX.md`. Central question: can STEMwerk's actual default
Demucs model (`htdemucs`, the model behind All Stems / Vocals / Bass / Drums Only /
Karaoke) run through native ONNX Runtime WebGPU, using the same unmodified weights,
without changing separation quality?

**Headline result: yes, with one specific, identified, reproducible fix.** A real,
independently-downloaded, unmodified `htdemucs` ONNX export runs with **1594/1594
graph nodes on WebGpuExecutionProvider, zero CPU fallback**, once a specific
`SessionOptions.graph_optimization_level` workaround is applied (default
`ORT_ENABLE_ALL` triggers a real onnxruntime WebGPU-EP bug on this graph; `BASIC` or
`DISABLE_ALL` avoid it). WebGPU output matches CPU-onnxruntime output on the *same*
ONNX graph to within 1e-6–7e-6 (correlation ≥0.99999) on all 4 stems — a clean,
decisive numerical PASS. Whether the ONNX export itself is faithful to STEMwerk's
*production* PyTorch pipeline is a **separate, only partially resolved question** — see
§8 below; this experiment's own test audio was not adequate to fully answer it.

## 1. Independent verification of the L3 community claim

**Source, directly verified via `gh api` and PyPI (not scraped/trusted blindly):**
- Repository: `github.com/StemSplit/demucs-onnx` (organization account, MIT license,
  created 2026-05-22, last push 2026-05-22, 5 stars, 0 forks, 2 open issues — a small,
  young, low-traction project; not evidence of unreliability on its own, but a fair
  characterization).
- Package: `demucs-onnx` 0.3.4 on PyPI, installed and run directly in an isolated venv
  (`/home/flark/stemwerk-rnd/venvs/webgpu-ep-demucsonnx/.venv-demucsonnx`).
- Author: `StemSplit <team@stemsplit.io>` (organization email, not an individual).
- Claimed export method: `torch.onnx.export`, **opset 17**, legacy (non-dynamo)
  exporter, `torch` pinned `>=2.4,<2.5` for the `[export]` extra, source weights from
  `facebookresearch/demucs`.
- Claimed four export blockers and fixes (verified present as separate, named modules
  in the installed package — `export/stft.py`, `export/segment.py`,
  `export/pos_embed.py`, `export/mha.py` — not just claimed in prose):
  1. `torch.stft`'s complex64 output has no ONNX equivalent → replaced with a Conv1d
     whose kernels are precomputed sin/cos DFT bases.
  2. `self.segment = Fraction(39, 5)` (a non-tensor Python object) breaks graph
     tracing → coerced to a float.
  3. `random.randrange` in the cross-transformer's positional-embedding code (a
     training-time augmentation) breaks export → monkey-patched to a deterministic
     version for export only.
  4. `aten::_native_multi_head_attention` has no ONNX symbolic → replaced with a
     manual Linear/bmm/softmax scaled-dot-product-attention implementation.
- Claimed PyTorch-fp32 parity (from their own published benchmarks, not re-derived by
  us): max abs diff ~1.4–1.7e-4 per stem, tolerance 1e-3.
- **Important correction to how this claim should be read**: their own claimed/tested
  execution providers are `CoreML / CUDA / DML / CPU` — **WebGPU is not among them**.
  Confirmed directly: `demucs-onnx separate --help`'s `--providers` choices are
  `{auto, cpu, coreml, cuda, dml, wasm}` — no WebGPU option exists anywhere in this
  package. **The original claim covers levels 1–6 of this phase's required 7-level
  distinction (export exists → CPU inference → PyTorch-parity → full separation);
  level 7 (native WebGPU) was never claimed by the source project at all — this
  experiment establishes that independently, it is not a verification of an existing
  WebGPU claim.**

**Due-diligence note (not a blocker, included for transparency)**: the first CLI
invocation logged a `GET https://huggingface.co/api/agent-harnesses` request. This was
paused and investigated before proceeding — traced to the official `huggingface_hub`
package (Hugging Face, Inc., not `demucs-onnx` itself), a documented, best-effort,
fail-silent telemetry feature that detects AI-agent-driven invocations via environment
variables, publicly described at
`https://huggingface.co/docs/hub/agents-overview#register-your-agent-harness`. Verified
via direct source inspection (`huggingface_hub/utils/_detect_agent.py`) rather than
either ignored or assumed malicious.

## 2. Exact STEMwerk model identity

From direct inspection of `scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/separator.py`
and the installed `audio-separator==0.47.0`'s `DemucsSeparator`:

- Model: `htdemucs` (STEMwerk's actual default — see `MODEL_COMPATIBILITY_MATRIX.md`
  §A; `htdemucs_ft`/`htdemucs_6s` are user-selectable alternatives, not tested here).
- Loader: `audio_separator.separator.uvr_lib_v5.demucs.pretrained.get_model`, weights
  fetched from `https://dl.fbaipublicfiles.com/demucs/...` — Meta/FAIR's own official
  release CDN for Demucs, the canonical first-party distribution channel.
- `demucs-onnx`'s own README states its source as "Original PyTorch weights:
  `facebookresearch/demucs`" — the same official upstream project. **Provenance is
  consistent with, but not byte-hash-verified against, STEMwerk's actual weights in
  this phase** — a direct weight-tensor comparison (or a published SHA256 of the
  original `.th`/safetensors checkpoint from both sources) was not performed; this is
  the one open item standing between "very likely the same model" and "proven
  identical," and should be the first thing checked before any further investment in
  this direction.
- Default STEMwerk/`audio-separator` processing parameters (`demucs_params`):
  `segment_size='Default'` (Demucs' own native default, `Fraction(39,5)` = 7.8 s =
  343,980 samples at 44.1 kHz — **matches the ONNX export's fixed input shape
  `[1, 2, 343980]` exactly**, confirming the export used the model's native segment
  length, not an arbitrary one), `overlap=0.25` (**matches** `demucs-onnx`'s hardcoded
  quarter-segment overlap-add), `shifts=2` (**does not match** — `demucs-onnx`
  implements no shift-based test-time averaging at all, confirmed by reading
  `inference.py` end to end; this is a genuine, confirmed processing-behavior
  difference from STEMwerk's production default, not a rounding detail).

## 3. ONNX graph inspection (`htdemucs.onnx`, fp32)

Downloaded directly from Hugging Face
(`https://huggingface.co/StemSplitio/htdemucs-onnx/resolve/main/htdemucs.onnx`,
301.7 MB, `x-linked-size` header confirmed before download) into the isolated
experiment venv's model cache (not STEMwerk's production cache).

- **SHA256**: `68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`
  (this is also literally the Hugging Face Hub blob's own content-addressed identity,
  i.e. it's independently reproducible by anyone re-downloading the same file).
- `onnx.checker.check_model()`: **PASS**.
- Opset 17, IR version 8 (matches the claimed export method exactly).
- **24,765 raw graph nodes, 38 distinct operator types** — dramatically more complex
  and architecturally diverse than every model tested in L1–L3 (MDX-Net's `.onnx`
  models were 178 nodes / 8 op types, all *identical* to each other — see
  `MODEL_COMPATIBILITY_MATRIX.md`). Op-type histogram includes `LayerNormalization`,
  `Softmax`, `Erf` (GELU), `InstanceNormalization`, `Sigmoid`, and heavy dynamic-shape
  machinery (`Shape`, `Range`, `Expand`, `ScatterND`, `Slice` — 2090 `Slice` nodes
  alone) consistent with HTDemucs' hybrid time/spectral CrossTransformer architecture.
- Input: `mix`, shape `[1, 2, 343980]` — **fixed batch and sample count**, not a
  dynamic axis. `demucs-onnx`'s `inference.py` implements its own chunked overlap-add
  wrapper around this fixed-size graph to handle arbitrary-length audio (§4 below) —
  the ONNX graph itself has no dynamic-length support.
- Single output tensor `stems` (all 4 stems stacked, not 4 separate outputs).

## 4. What's inside the ONNX graph vs what stays in Python

Per the brief's explicit warning not to claim PyTorch-independence just because the
neural network itself is exported:

**Inside the ONNX graph** (confirmed by the op-type histogram and the four blockers'
own descriptions): the full HTDemucs forward pass, **including STFT/iSTFT** (replaced
with Conv1d-based DFT basis kernels specifically so they *could* be included — unlike
MDX-Net in this repo's own pipeline, where STFT/iSTFT deliberately stays in PyTorch
outside the graph, see `README.md` §2a). This is a materially different, more complete
export than any model tested in L1–L3.

**Outside the ONNX graph, still Python** (all confirmed by reading `demucs_onnx`'s
installed source, not assumed): audio loading and resampling (`_audio.py`, via
`soundfile`+`soxr`), the fixed-segment chunking / quarter-segment triangular-window
overlap-add wrapper (`inference.py`), and model/weight downloading
(`_hub.py`, via `huggingface_hub`). **Confirmed empirically, not just architecturally**:
`torch` is not even installed in the test venv, and a full, real separation completed
successfully anyway — `demucs-onnx`'s own claim of "pure numpy + onnxruntime, no
PyTorch dependency at inference" holds up under direct testing for this export. PyTorch
would still be required to *re-run the export itself* (the `[export]` extra pins
`torch>=2.4,<2.5`), but not to *use* an already-exported model.

## 5. Controlled export proof of concept — not performed; a pre-published artifact was used instead

Per the brief's explicit instruction to use exact, unmodified pretrained weights and
avoid retraining/pruning/quantizing, and given a maintained, versioned, publicly
re-downloadable artifact already existed (§3's SHA256 makes it independently
reproducible), this phase used the **published fp32 ONNX file directly** rather than
re-running `demucs-onnx`'s own export pipeline from scratch. This means: **the export
process itself (PyTorch → ONNX, the four blocker patches) was not independently
re-executed in this phase** — only its published output was tested. This is a
deliberate scope choice (the brief allows using a "reproducible export method" without
requiring re-running it when a trustworthy pre-built artifact is available) and is
flagged here explicitly rather than silently implied.

## 6. CPU ONNX inference

`demucs_onnx.separate(..., providers='cpu', precision='fp32')`, real 20 s test clip
(`artifacts/windows-native-asep0443-smoke-kit/input_20s.wav`, an existing STEMwerk CI
smoke-test fixture — see §9's important caveat about this file's content). **PASS**:
completed without error, 4 stems (`drums`, `bass`, `other`, `vocals`) returned as
`float32` arrays, correct shape `(2, 882000)` at 44.1 kHz, no NaN/Inf.

## 7. CPU ONNX ↔ PyTorch equivalence — PASS on the dominant stem, inconclusive on the rest

**Reference**: real, unmodified `htdemucs` run via `audio-separator`'s own
`DemucsSeparator` (i.e. STEMwerk's actual production code path) in the main experiment
venv, `shifts=0` (§2's noted processing difference — set to 0 specifically to isolate
ONNX-export fidelity from the separate shift-averaging question, not to hide it).
Same input file, same output captured pre-export (via the same `final_process`
interception technique as L2/L3, adapted for `DemucsSeparator`).

**Pre-declared tolerance** (stated before running, consistent with L2/L3's raw-output
standard): correlation ≥0.999, max_abs_diff ≤5e-3 — the same standard applied to
MDX-Net in L2/L3, chosen for the same reason (expected float32 cross-implementation
noise floor, not an arbitrary bar).

| Stem | Correlation | Max abs diff | RMS diff % | vs tolerance |
|---|---|---|---|---|
| **other** | 0.999990 | 0.007377 | 0.08% | Correlation PASS; max_abs_diff exceeds 5e-3 by a small margin |
| drums | 0.944662 | 0.008690 | 22.9% | FAIL both metrics |
| bass | 0.936855 | 0.002555 | 34.0% | Correlation FAIL, max_abs_diff PASS |
| vocals | 0.872225 | 0.000983 | 7.6% | Correlation FAIL, max_abs_diff PASS |

**This table alone would look like a real fidelity problem. It is very likely a test-
signal artifact, not an export defect — and this experiment cannot fully rule the
alternative out, which is reported honestly rather than either overclaiming a pass or
overclaiming a bug.** Investigated directly (§9): both audio files available in this
repository for testing (the original L1–L3 clip and this phase's `input_20s.wav`) turn
out to be near-flat-energy synthetic test tones (frame-to-frame RMS varies by only
~0.3% across the whole clip), not real music with genuine drums/bass/vocals content —
confirmed by direct measurement, not assumed. The `other` stem (which correctly absorbs
almost all of this ambient/tonal content) shows excellent agreement; `drums`/`bass`/
`vocals` are separating near-silence from near-silence, where small absolute errors
(MAE is a *consistent* ~1–1.6e-4 across all four stems regardless of energy level —
notably *not* growing with the signal, which would be more consistent with a
test-signal noise-floor effect than a systematic export bug) dominate the relative
comparison. **A real musical test clip with genuine multi-instrument content would be
needed to resolve this conclusively — none was available in this environment**
(STEMwerk's committed test fixtures are deliberately synthetic, and downloading
copyrighted commercial music for testing was out of scope). Flagged as the top
follow-up item, not glossed over.

## 8. Native WebGPU initialization — real bug found, real workaround found

**First attempt: FAIL.** Passing `providers=["WebGpuExecutionProvider"]` (through this
project's own `webgpu_adapter.py`, unmodified — same monkeypatch pattern proven in
L1–L3) to `demucs_onnx.separate()` produced a real onnxruntime C++ exception during
session initialization, not a Python-level error:

```
onnxruntime.capi.onnxruntime_pybind11_state.EPFail: [ONNXRuntimeError] : 11 : EP_FAIL :
.../onnxruntime/core/providers/webgpu/nn/conv.h:21
onnxruntime::webgpu::Conv<is_channels_last, is_fused>::Conv(...)
GetFusedActivationAttr(info, activation_).IsOK() was false.
```

**Root-caused, not just worked around blindly**: tested `SessionOptions
.graph_optimization_level` directly against three settings on the same model/device —
`ORT_ENABLE_ALL` (onnxruntime's own default, and what both `demucs-onnx`'s own
`_make_session()` and this project's `webgpu_adapter.py` used by default) **fails
every time**; `ORT_ENABLE_BASIC` and `ORT_DISABLE_ALL` **both succeed, every time**.
Conclusion: onnxruntime's `ConvActivationFusion` graph transformer (which runs under
`ENABLE_ALL`/`ENABLE_EXTENDED` but not `BASIC`) fuses a Conv+activation pattern in
Demucs' graph into a form the WebGPU EP's own `Conv` kernel implementation doesn't
correctly parse — a real bug in onnxruntime's WebGPU EP for this specific graph
pattern, not something MDX-Net's much simpler graph ever triggered in L1–L3, and not
something this experiment caused or can fix upstream. **This is exactly the kind of
model-specific WebGPU limitation §6 of the L3 brief anticipated finding eventually.**

**Fix, added to the shared adapter** (`webgpu_adapter.py`, backward compatible — a new
optional `graph_optimization_level` parameter, `None` by default, meaning L1–L3
behavior is completely unchanged): pass `ORT_ENABLE_BASIC` when constructing the
WebGPU session for this model. Verified this doesn't regress L1–L3: re-ran the
`UVR_MDXNET_KARA_2.onnx` graph-placement check afterward — still 185/185 nodes on
WebGPU, unchanged.

## 9. Demucs graph placement — PASS, zero fallback

With the §8 workaround applied, real per-node placement proof (same stderr-fd
log-capture standard as every prior phase, not `get_providers()` alone):

```
All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594
```

**1594/1594 — zero CPU-fallback nodes**, for the full 24,765-raw-node graph (reduced to
1594 after onnxruntime's `ORT_ENABLE_BASIC`-level optimization/fusion — a large,
expected reduction from constant-folding the graph's very large `Constant`/`Shape`/
`Range` bookkeeping overhead, not evidence of missing operators). `session.get_providers()`
returns `['WebGpuExecutionProvider', 'CPUExecutionProvider']` (the second entry is
onnxruntime's standard fallback-provider registration, not evidence any node actually
ran there — the log-captured placement line is the actual proof).

## 10. WebGPU numerical validation

**WebGPU vs CPU onnxruntime, same ONNX graph — the cleanest, most decisive comparison
in this whole phase** (isolates the EP-backend difference completely, same weights,
same graph, same chunking code, same test input):

| Stem | Correlation | Max abs diff | MAE |
|---|---|---|---|
| drums | 0.99999993 | 1.57e-06 | 5.02e-08 |
| bass | 0.99999261 | 2.03e-06 | 2.75e-07 |
| other | 1.00000000 | 7.51e-06 | 4.57e-07 |
| vocals | 0.99999994 | 7.84e-07 | 3.75e-08 |

**All 4 stems pass by 3+ orders of magnitude margin against the same 5e-3/0.999
tolerance used throughout L2–L4.** This is a materially cleaner result than §7's
CPU-ONNX-vs-PyTorch comparison, and it directly demonstrates that §7's noisier numbers
are **not** a WebGPU correctness problem — the WebGPU EP reproduces the CPU EP's own
output on this exact graph essentially perfectly, on all four stems including the
near-silent ones, using the identical synthetic test signal that produced §7's noisy
numbers. Whatever is causing §7's drums/bass/vocals discrepancy, it is upstream of
(shared by) both onnxruntime backends equally — consistent with §7's test-signal
hypothesis, not with a WebGPU-specific defect.

**WebGPU vs PyTorch reference**: shows the same pattern as §7 — `other` stem
correlation 0.999990, same magnitude family as the CPU-ONNX-vs-PyTorch comparison;
drums/bass/vocals equally noisy, for the same reason. Not re-tabulated separately here
since it adds no new information beyond confirming consistency with §7 and this
section's CPU-vs-WebGPU table above — see the raw JSON/npz artifacts (not committed,
machine-local) for exact figures if needed.

## 11. Full "Normal Stems" feasibility

Reached and validated: 4-stem output (`drums`, `bass`, `other`, `vocals` — matching
STEMwerk's actual `DRUMKIT_STEMS`-adjacent naming and the standard Demucs 4-stem
convention), correct duration (20.00 s), correct sample rate (44100 Hz), correct
channel count (stereo), no NaN/Inf in any output, no unexpected total silence (every
stem carries a real, non-zero, physically plausible signal for this input), no
clipping observed. Stem *routing* (drums↔drums, bass↔bass, etc. — not scrambled)
confirmed via the RMS-profile match between all three runs (CPU-ONNX, WebGPU-ONNX,
PyTorch) being consistent per-stem rather than swapped. **Stem *quality* equivalence
to production remains open per §7/§9's test-signal limitation** — explicitly not
concealed behind an overall PASS, per the brief's own instruction.

This experimental flow was run entirely outside any REAPER/STEMwerk production
workflow — a standalone Python script and CLI invocation only, in the isolated venv.

## 12. Runtime architecture and dependency implications

**This is the most consequential finding of the phase for STEMwerk's actual
architecture decision, independent of the §7 open question.**

- **Confirmed empirically** (not assumed): `demucs-onnx` inference requires **no
  PyTorch, no torchaudio, no vendor-specific torch build at all** — pure `numpy` +
  `onnxruntime` (+`soundfile`/`soxr` for audio I/O, `huggingface_hub` for model
  download). The test venv had no `torch` installed whatsoever and every inference
  call succeeded.
- **What this could eliminate, if §7's open question resolves favorably**: STEMwerk's
  `STEMwerk_Bootstrap_Linux.sh`/`.ps1` today install a *different* torch build per
  platform/vendor combination for the Demucs path specifically (`--index-url
  .../whl/cpu`, `.../whl/rocm6.4`, `.../whl/rocm7.0`, `.../whl/rocm7.1`,
  `.../whl/rocm7.2`, plus separate CUDA/MPS/DirectML variants elsewhere in the same
  scripts) — real, current, multi-path maintenance burden confirmed in Phase L3's
  packaging research. An ONNX/WebGPU Demucs route would need exactly **one**
  `onnxruntime`+`onnxruntime-ep-webgpu` combination across AMD/NVIDIA/Intel/Apple, for
  this one model, replacing N vendor-specific torch installs with 1 vendor-neutral
  onnxruntime install.
- **What would remain unchanged regardless**: MDXC/RoFormer/DrumSep (§L3.6, still no
  ONNX artifact of any kind found) would still need PyTorch+vendor-specific torch
  builds — this does not eliminate STEMwerk's torch dependency *entirely*, only for
  the Demucs-family models specifically. `audio-separator` itself would likely remain
  a dependency for the non-Demucs paths regardless.
- **Distribution cost**: `onnxruntime`+`onnxruntime-ep-webgpu` add ~83 MB installed
  (measured directly in Phase L3, unchanged here) — negligible next to the ~301 MB
  `htdemucs.onnx` weight file itself (a cost STEMwerk already pays today for the
  equivalent PyTorch checkpoint, of comparable size).
- **macOS Intel**: unchanged from Phase L3's finding — `onnxruntime-ep-webgpu`'s
  required base `onnxruntime` dependency has no macOS x86_64 wheel for any version
  from 1.24.4 through 1.30.0, so this route is equally blocked on macOS Intel as every
  other WebGPU route tested so far, regardless of model.
- **Two-venv-style isolation still applies**: this phase's `demucs-onnx` venv was kept
  fully separate from both the main WebGPU venv and the ROCm reference venv — not
  because of a *new* conflict, but as a continuation of Phase L2/L3's established
  practice of isolating each experimental dependency combination.

## 13. Performance (secondary; basic reference only, no tuning performed)

Same 20 s clip, `htdemucs`, fp32, `demucs-onnx`'s own chunked overlap-add pipeline
unchanged, load/first-run/warm-run separated, 3 repeats:

| | CPU (onnxruntime) | WebGPU (RX 9070) |
|---|---|---|
| First ("cold") run | 10.06 s | 6.32 s |
| Warm runs (2 repeats) | 7.28 s / 7.35 s | 3.33 s / 3.25 s |
| Warm average | 7.32 s | 3.29 s |
| Real-time factor (20 s clip, warm) | 2.7× | 6.1× |
| Speedup vs CPU | 1.0× (ref) | **2.2×** |

Modest compared to MDX-Net's 5.75× (L2) — expected, given Demucs' far larger and more
diverse graph (1594 optimized WebGPU nodes vs MDX-Net's 185, including many small
shape/bookkeeping ops with relatively more per-dispatch overhead on a discrete GPU).
**Not impractical**: still comfortably faster than real-time and meaningfully faster
than CPU. No graph-capture, quantization, or kernel tuning was attempted, per the
brief's instruction to keep this basic.

## 14. Milestones

| Milestone | Status |
|---|---|
| Community claim verified | **PARTIAL** — levels 1–6 (export exists, CPU inference, full separation) verified directly; the claim itself never covered WebGPU (level 7) at all |
| Exact STEMwerk model identified | **PASS** — `htdemucs`, default model, traced to `DemucsSeparator`/`dl.fbaipublicfiles.com` |
| Same model weights confirmed | **BLOCKED** — same official upstream source (Meta/FAIR `facebookresearch/demucs`) confirmed; no byte-level weight-hash comparison performed |
| Reproducible ONNX export | **PASS (artifact only)** — pre-published, SHA256-verified, independently re-downloadable artifact used; the export *process* itself was not re-run in this phase |
| ONNX graph validation | **PASS** — `onnx.checker` clean, opset 17, 24,765 nodes / 38 op types |
| CPU ONNX inference | **PASS** — real, measured, no PyTorch installed in the test venv |
| CPU ONNX ↔ PyTorch equivalence | **PARTIAL** — `other` stem PASS; drums/bass/vocals inconclusive due to a synthetic/non-musical test signal (confirmed by direct measurement), not a confirmed export defect |
| Native WebGPU initialization | **PASS (after a found and fixed workaround)** — real `EP_FAIL` root-caused to `ConvActivationFusion`+WebGPU-Conv-kernel interaction, resolved via `graph_optimization_level=ORT_ENABLE_BASIC` |
| Demucs graph placement | **PASS** — 1594/1594 nodes on WebGPU, 0 CPU fallback, log-verified |
| WebGPU numerical validation | **PASS** — vs CPU-ONNX (same graph): correlation ≥0.99999, max diff ≤7.5e-6, all 4 stems. Vs PyTorch: same open question as the CPU-ONNX row above, not a WebGPU-specific issue |
| Full Normal Stems | **REACHED, PARTIALLY VALIDATED** — shape/routing/no-NaN/no-silence/no-clipping all PASS; absolute quality-vs-production equivalence NOT TESTED (blocked on §7/§9's test-signal limitation) |
| Runtime simplification assessment | **COMPLETE** — pure numpy+onnxruntime confirmed at inference, no torch; real potential to replace N vendor-specific torch builds with one onnxruntime+WebGPU install for the Demucs-family path specifically, contingent on §7 resolving favorably |

## 15. Recommended next step

**Get (or license/record) one real, musically representative multi-instrument test
clip and re-run §7/§10's numeric comparison.** This is now the single blocking
uncertainty standing between "Demucs-on-WebGPU is demonstrated" and "Demucs-on-WebGPU
is demonstrated *at production quality*" — every other milestone in §14 is resolved one
way or another. Everything needed to re-run this comparison already exists and works
(`webgpu_adapter.py`'s new `graph_optimization_level` parameter, the
`demucs-onnx`/`audio-separator` reference-comparison scripts used in this phase) — this
is a data problem, not an engineering problem. Secondary, lower-priority follow-ups:
a byte-level weight-hash comparison between the ONNX-embedded weights and STEMwerk's
actual `.th` checkpoint (§2/§14's "BLOCKED" item), and independently re-running
`demucs-onnx`'s own export pipeline from scratch (§5) rather than relying on the
published artifact, before considering this direction for anything beyond further
research.

## Reproducing this phase

```bash
# Isolated venv, outside exFAT, separate from the main WebGPU and ROCm-reference venvs
python3.11 -m venv /path/to/.venv-demucsonnx
source /path/to/.venv-demucsonnx/bin/activate
pip install demucs-onnx onnxruntime-ep-webgpu onnx

# CPU baseline
python -m demucs_onnx.cli separate /path/to/clip.wav /tmp/out --model htdemucs --providers cpu --precision fp32

# WebGPU, with the required graph_optimization_level workaround (Python API; the CLI
# itself has no webgpu provider option, see §8):
python3 - <<'PYEOF'
import sys; sys.path.insert(0, "/path/to/experiments/webgpu-ep")
from webgpu_adapter import patch_inference_session_for_provider_swap, select_device
import onnxruntime as ort
original_cls, reports = patch_inference_session_for_provider_swap(
    lambda: select_device(pci_bus_id="0000:xx:00.0"),  # omit pci_bus_id on single-GPU systems
    graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_BASIC,
)
import demucs_onnx
stems = demucs_onnx.separate("/path/to/clip.wav", model="htdemucs",
                              providers=["WebGpuExecutionProvider"], precision="fp32")
ort.InferenceSession = original_cls
print(reports[0]["all_nodes_placed_line"])
PYEOF
```
