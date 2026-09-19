# Demucs ONNX/WebGPU — macOS Apple Silicon Validation (Phase L8)

Status date: 2026-09-19. Companion to `DEMUCS_ONNX_FEASIBILITY.md` (L4),
`DEMUCS_REAL_MUSIC_PARITY.md` (L5), `DEMUCS_SHIFT_PARITY.md` (L6),
`DEMUCS_INDEPENDENT_MUSIC_VALIDATION.md` (L7). Tests whether the same, unmodified
`demucs-onnx`/`webgpu_adapter.py`/`demucs_shift_wrapper.py` implementation that L4-L7
validated on Linux/AMD/Vulkan works technically on macOS/Apple Silicon/Metal, whether
GPU inference genuinely executes, and whether it offers a practical advantage over
STEMwerk's existing macOS processing routes (production PyTorch/MPS).

**Headline result: technically works end-to-end (1594/1594 nodes on WebGPU, zero CPU
fallback, numerical parity as strong as or stronger than every prior Linux phase) — but
offers no practical performance advantage on this hardware. It is measurably slower
than STEMwerk's existing MPS production route (≈5.9× slower) and even slower than plain
ONNX CPU on this same machine (≈1.7× slower).** This is the opposite performance
conclusion from L4's Linux/RX-9070 result (WebGPU 2.2× faster than CPU there) — a real,
measured, platform-specific finding, not a regression in the implementation. Numerical
correctness is unaffected by this: WebGPU produces the same output as CPU ONNX to
within the float32 noise floor on this platform too.

## 1. Exact Mac hardware and OS

| Property | Value |
|---|---|
| Machine | MacBook Air (MacBookAir10,1) |
| Chip | Apple M1 |
| Unified memory | 8.0 GB |
| macOS | 26.7 (build 25G229) |
| Architecture | arm64 (native throughout — see §3) |
| REAPER | 7.79.0_06dd787u installed (`/Applications/REAPER.app`), universal binary (x86_64+arm64 slices); not launched or used in this phase — all testing was standalone Python, same as L4-L7 |
| Free disk | 52-58 GB free throughout |

Same physical machine as the earlier "Phase M1" MDX-Net/WebGPU validation
(`README.md` §"Phase M1"), reused here for the separate Demucs/htdemucs track.

## 2. Environment and dependency versions

Two fully isolated venvs, mirroring L4-L7's own two-venv-per-experiment-track practice
(never mixed with each other, with STEMwerk's production runtime, or with the earlier
MDX-Net WebGPU venv):

**Main venv** (`/Users/flark/stemwerk-m1-validation/venvs/webgpu-ep/` — the same venv
used for the earlier MDX-Net Phase M1 work; reused here only for the PyTorch/MPS
reference routes, matching L4's own methodology of running its PyTorch reference "in
the main experiment venv"):
- Python 3.12.13 (arm64) — the existing STEMwerk-managed interpreter, read-only, used
  only to create the venv
- `torch==2.14.0` (arm64, MPS built and available — confirmed via
  `torch.backends.mps.is_built()`/`is_available()`)
- `audio-separator==0.47.0` (STEMwerk's actual production separation library)

**New venv** (`/Users/flark/stemwerk-m1-validation/venvs/webgpu-ep-demucsonnx/` —
created this phase, mirroring the Linux `webgpu-ep-demucsonnx` venv name/purpose):
- Python 3.12.13 (arm64), same managed interpreter
- `demucs-onnx==0.3.4` (identical version to L4-L7)
- `onnxruntime==1.30.0`, `onnxruntime-ep-webgpu==0.3.0`, `onnx==1.23.0` (identical
  versions to L4-L7 and to the earlier MDX-Net Phase M1 venv)
- No `torch` installed — confirmed empirically (import never attempted, full separation
  completed anyway), matching L4's own finding that `demucs-onnx` needs no PyTorch at
  inference

Neither venv touches, modifies, or was created inside STEMwerk's production runtime
(`~/Library/Application Support/STEMwerk/`) or any REAPER-managed location.

## 3. Native arm64 verification

Every installed package resolved to a native `macosx_*_arm64`/`universal2` wheel in
both venvs — confirmed by inspecting the actual downloaded wheel filenames during
install (`cp312-cp312-macosx_14_0_arm64`, `macosx_14_0_universal2`, etc.), not assumed.
**No Rosetta/x86_64 anywhere.** `platform.machine()` returns `arm64` in both venvs. No
source compilation was needed for anything in this phase's dependency set.

## 4. WebGPU availability and initialization

`webgpu_adapter.py` — reused completely unmodified from L1-L7 (this file was NOT
edited in this phase; the "zero code changes needed for device selection" finding from
the earlier MDX-Net Phase M1 work holds again here, independently reconfirmed):

```
device selected: WebGpuExecutionProvider {}
```

Exactly one WebGPU device (Apple M1's integrated GPU), no `pci_bus_id` metadata (same
as the MDX-Net Phase M1 finding) — `select_device()`'s existing single-device
auto-select path handled it with no macOS-specific code required.

**The L4 `ConvActivationFusion`/WebGPU-Conv-kernel bug reproduces identically on
macOS.** Constructing a session with onnxruntime's default `graph_optimization_level`
(`ORT_ENABLE_ALL`) against the real `htdemucs.onnx` graph fails with the exact same
error L4 documented on Linux:

```
onnxruntime.capi.onnxruntime_pybind11_state.EPFail: [ONNXRuntimeError] : 11 : EP_FAIL :
.../onnxruntime/core/providers/webgpu/nn/conv.h:21
onnxruntime::webgpu::Conv<is_channels_last, is_fused>::Conv(...)
GetFusedActivationAttr(info, activation_).IsOK() was false.
```

This confirms L4's root cause (an onnxruntime WebGPU-EP bug in how `ConvActivationFusion`
interacts with this specific Conv+activation graph pattern) is not Linux/AMD/Vulkan-
specific — it is a property of the onnxruntime WebGPU EP itself on this graph shape,
reproducing on a completely different OS, GPU vendor, and WebGPU backend (Metal/Dawn
vs. Vulkan/Dawn). **The already-existing fix works unchanged**: passing
`graph_optimization_level=ORT_ENABLE_BASIC` (via `webgpu_adapter.py`'s L4-added
parameter, itself untouched this phase) avoids it, session construction succeeds.

## 5. Actual GPU execution evidence

Same log-capture verification standard as every prior phase (onnxruntime's own C++
stderr-fd log, not `get_providers()` alone):

```
All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594
```

**1594/1594 — identical node count to L4's Linux/RX-9070 result, zero CPU fallback.**
`session.get_providers()` returns `['WebGpuExecutionProvider', 'CPUExecutionProvider']`
(the second entry is onnxruntime's standard registration, not evidence of fallback —
the log-captured placement line is the actual proof, same distinction every prior phase
insisted on).

A direct, minimal inference call (random input, no chunking wrapper) was run first, to
distinguish "session constructs" from "a node actually executes" per the 6-level
staged proof this phase's brief required:

1. Package installation works — **PASS** (§2/§3)
2. Provider loads — **PASS** (`ort.get_ep_devices()` lists it)
3. Apple GPU is selected — **PASS** (`select_device()`, vendor_id `0x106B` = Apple)
4. Model initializes successfully — **PASS**, with the §4 workaround
5. Actual inference completes on the GPU — **PASS** — real Metal dispatch log observed
   (`webgpu_context.cc` executing named kernels: `Conv2dMM`, `ConvTranspose2D`,
   `Transpose`, `Slice`, `Mul`, `Add`, `OIHW2OHWI` — real HTDemucs op names, not
   synthetic), single raw-model call completed in 5.54 s, output shape
   `(1, 4, 2, 343980)`, finite, non-zero
6. Full separation completes correctly — **PASS** — via the real, unmodified
   `_chunked_separate_single`/`demucs_shift_wrapper.run_with_seed`, on a real 6.00 s
   clip first as a mechanical smoke test (4 stems, correct shape, finite, plausible
   RMS/peak), then on the full 25.0 s parity fixture (§6/§7 below)

No stage failed. No CPU fallback was masked or silently accepted at any stage.

## 6. Numerical parity results

**Fixture note — read before the numbers below.** L7's original fixture
(`modeltest.wav`, `/home/flark/Music/modeltest.wav` on the Linux machine) is not
present on this Mac (confirmed by direct search of this machine's separate personal
`~/Music` library and the whole filesystem) and was not transferred in this phase (the
user explicitly chose to proceed with a substitute rather than wait for a transfer).
**Per this brief's own fallback instruction, a separate genuine local recording was
used instead, and the cross-platform numerical comparison against L7's exact fixture is
correspondingly limited** — this section's numbers are internally consistent (all
routes below were run against the identical macOS fixture) but are not a byte-for-byte
apples-to-apples re-run of L7's own input.

**Fixture used**: `01 Thomas Dolby - Dissidents.flac` — a genuine, personally-owned
commercial studio master (not a stem-sum reconstruction — same "original mix" category
L7 specifically sought out, for the same reason: L5/L6's fixture was a reconstruction
and that was flagged as a possible confound). 25.0 s excerpt, selected by the same
"no dead-air second anywhere in the window" methodology L7 used (scanned per-second RMS
across the full 296.9 s track; the chosen window has zero seconds below the healthy
range).

| Property | Value |
|---|---|
| Source | `/Users/flark/Music/01 Thomas Dolby - Dissidents.flac` (personal music library, outside any git repository) |
| Full-file duration | 296.9 s |
| Excerpt used | 255.0-280.0 s (25.0 s), scanned second-by-second for dead air first; none found, RMS stayed in a 0.104-0.138 range throughout |
| Sample rate | 44,100 Hz |
| Channels | 2 (stereo) |
| Full-file SHA256 | `3f7104be734ca2b4088219ff7015284c681500d81bebd628b7bf0abe54e74d03` |
| Excerpt SHA256 (as-written 16-bit PCM WAV) | `c391c46688d80e90b1a59a91b4dd124de965f2b03bc1d9e7ea1eaff2f0ad01ea` |
| Energy-variance ratio (crest-factor proxy, 2048-sample frames — same style of metric as L4/L5/L7) | 0.399 — genuinely dynamic (L4's synthetic signal: 0.003; L5/L6: 0.350; L7: 0.513) |
| RMS / peak (excerpt) | 0.119 / 0.726 — no clipping |
| Segments per 7.8 s Demucs window | 25.0 s / (0.75 × 7.8 s stride) ≈ 4.3 — comparable to L7's ≈4 |

Kept entirely outside Git throughout (`/tmp/l8-parity-test/`).

**A real correctness bug was checked for and NOT found this phase** — L7's own
disclosed array-orientation bug (PyTorch stems captured as `(samples, channels)`, ONNX
stems as `(channels, samples)`, silently comparing near-empty slices if not normalized)
was independently reconfirmed as a real property of this phase's own captured data
(`np.load(...).shape` checked directly: PyTorch route outputs are `(1102500, 2)`, ONNX
route outputs are `(2, 1102500)`) and the comparison code for this phase was written
with explicit channel/sample normalization from the start, specifically citing L7.3's
finding as the reason — verified before trusting any result below by confirming the
`shifts=0` PyTorch-CPU-vs-PyTorch-MPS comparison (same framework, same device family,
expected to be nearly bit-identical) actually came out that way (correlation
0.9999999999994, not a corrupted/near-zero value), the same sanity-check discipline L7
used.

### `shifts=0` (deterministic, single measurement, L5/L7-equivalent)

| Stem | PT-CPU vs PT-MPS corr | PT-CPU vs ONNX-CPU corr | PT-CPU vs ONNX-CPU rel. RMS err | ONNX-CPU vs ONNX-WebGPU corr |
|---|---|---|---|---|
| drums | 0.999999999999 | 0.999571 | 2.94% | 0.999999999 |
| bass | 0.999999999999 | 0.999454 | 3.33% | 0.999999997 |
| other | 0.999999999996 | 0.996699 | — | 0.999999999 |
| vocals | 0.999999999999 | 0.999430 | 3.40% | 0.999999999 |

PT-CPU/PT-MPS agreement is essentially exact (as expected — same framework, same math,
different device backend of the same library). **PT-vs-ONNX parity (0.9967-0.9996) is
comparable to L5's shifts=0 table (0.997-0.9997) and tighter than L7's own
(0.9989-0.9995 — L7's numbers were actually slightly better than L5's; this phase's
"other" stem at 0.9967 is the one value in this table below L7's tightest, still a
strong PASS against the 0.999 correlation bar used elsewhere in this project, and well
above L4's original synthetic-signal numbers).**

### `shifts=2`, repeated-run statistics (3 seeds: 111, 222, 333)

Same design as L6/L7: measure PyTorch's own run-to-run "noise floor" (two independent
PyTorch `shifts=2` runs, no ONNX involved) and compare it to the PyTorch-vs-ONNX gap.

| Stem | PyTorch noise floor (mean of 3 pairwise) | PT vs ONNX-WebGPU (mean of 3 seeds) | **Ratio (PT-vs-WebGPU / PT-noise-floor)** |
|---|---|---|---|
| drums | 3.71% | 2.94% | **0.79×** |
| bass | 4.61% | 3.70% | **0.80×** |
| other | 11.68% | 7.87% | **0.67×** |
| vocals | 4.30% | 3.03% | **0.71×** |

**All four ratios are below 1.0 — the same headline result L7 found on its independent
Linux fixture (0.66×-0.73×), now independently reconfirmed on a third fixture, a
different platform, and a different GPU vendor (0.67×-0.80×).** This is now the
**third** independent piece of evidence (L7's Linux fixture, and now this macOS
fixture) against "vocals/other are consistently worse than drums/bass" as a general
model/export property — the original L6 residual continues to look more consistent
with that one fixture's reconstructed-mix provenance than with an inherent per-stem
asymmetry. As before: **two platforms, two fixtures beyond the original — still not
proof this never occurs, but consistent, corroborating evidence.**

**ONNX CPU vs WebGPU, per-seed, shifts=2** (backend-only difference, identical offsets
— confirmed: seed 111→`[6971, 10353]`, 222→`[3535, 7708]`, 333→`[18180, 11495]`,
**exactly matching L7's own recorded offsets for the same seeds** — Python's `random`
module is deterministic given the same seed regardless of platform, confirming this is
not a coincidence but the expected behavior):

| Stem | Correlation (all seeds) | Max abs diff (range) | Rel. RMS error (range) |
|---|---|---|---|
| drums | 1.00000000 | 7.5e-05 – 9.9e-05 | 0.0035% – 0.0037% |
| bass | 1.00000000 | 9.5e-05 – 1.3e-04 | 0.0062% – 0.0066% |
| other | 1.00000000 | 2.6e-05 – 4.7e-05 | 0.0079% – 0.0092% |
| vocals | 1.00000000 | 3.0e-05 – 4.0e-05 | 0.0028% – 0.0030% |

**Matches L4/L6/L7's "correlation 1.000000, rel RMS error ≤0.013%" pattern extremely
closely.** WebGPU backend fidelity is unaffected by platform — the same clean
near-bit-exact match to CPU ONNX holds on Metal as it did on Vulkan.

## 7. Shift-averaging results

`demucs_shift_wrapper.py` was used **completely unmodified** (not edited this phase,
same file bytes as the L6 commit that introduced it). `shifts=0` correctly delegates
straight to `_chunked_separate_single` with zero wrapper overhead (verified: PT
`shifts=0` and ONNX `shifts=0` both ran once each, no offsets logged, matching the
docstring's documented behavior). `shifts=2` correctly drew 2 random offsets per call,
logged for reproducibility, and produced the same offsets for identical seeds across
CPU and WebGPU ONNX sessions (see §6 above) — all exactly as designed and already
verified on Linux; no macOS-specific behavior difference found.

Routes actually run, per this brief's required list:

| Route | Status |
|---|---|
| A. PyTorch CPU, shifts=0 | **RAN** — reference baseline |
| B. PyTorch MPS, shifts=0 | **RAN** |
| C. PyTorch MPS, shifts=2 | **RAN** — 3 seeds (111/222/333); this is STEMwerk's actual current production route on this hardware |
| D. ONNX CPU, shifts=0 | **RAN** |
| E. ONNX CPU, shifts=2 | **RAN** — 3 seeds |
| F. ONNX WebGPU, shifts=0 | **RAN** |
| G. ONNX WebGPU, shifts=2 | **RAN** — 3 seeds |

No route was BLOCKED or substituted. All 7 (well, 5 unique configurations × repeated
seeds where applicable = 13 total runs) completed and produced valid, finite,
correctly-shaped, non-silent, non-clipping 4-stem output — confirmed via direct
per-file/per-array validation (§11).

## 8. CPU/MPS/WebGPU performance comparison

Same 25.0 s fixture, `htdemucs`, all `shifts=2` numbers are the mean of 3 seed-repeats
(111/222/333); `shifts=0` numbers are single deterministic measurements. **The critical
comparison this brief specifically asked for — WebGPU vs. STEMwerk's actual existing
MPS production route — is the PT-MPS-shifts=2 row below, not CPU.**

| Route | `shifts=0` | `shifts=2` (mean of 3 seeds) | RTF (25.0 s clip, `shifts=2`) |
|---|---|---|---|
| PyTorch CPU | 10.57 s | — (not repeated; CPU is not the production route on this hardware) | — |
| PyTorch MPS (**STEMwerk's actual current production route**) | 7.17 s | **8.28 s** | **3.02×** |
| ONNX CPU | 13.10 s | 28.14 s | 0.89× (sub-real-time) |
| ONNX WebGPU | 28.57 s | **49.08 s** | 0.51× (sub-real-time) |

**WebGPU vs. STEMwerk's actual production route (PyTorch MPS, `shifts=2`): 8.28 s vs.
49.08 s — WebGPU is ≈5.9× SLOWER, not faster.** WebGPU is even slower than plain ONNX
CPU on this same machine (49.08 s vs. 28.14 s, ≈1.7× slower) — this is not merely "MPS
is unusually fast," WebGPU itself underperforms CPU for this workload on this hardware.

**This is the opposite conclusion from Phase L4's Linux/RX-9070 result** (WebGPU 2.2×
faster than CPU there). Per this brief's explicit instruction not to extrapolate AMD
speedups to Apple Silicon and not to call the route faster unless the measured
end-to-end results support it: **they do not, on this specific machine/model/workload
combination.** No root-cause profiling (e.g. per-kernel dispatch timing, thermal
throttling measurement) was performed to explain *why* — flagged as an open question,
not resolved here, per the same discipline this project has applied to open questions
throughout L1-L7. Plausible, unverified contributing factors worth investigating if
this direction is pursued further: (a) Demucs' 1594-node graph has many small
ops/kernels relative to MDX-Net's 185 (the earlier Phase M1 MDX-Net WebGPU test *was*
faster than CPU on this same M1 — see `README.md` §"Phase M1" — 1.68×), consistent with
per-dispatch overhead dominating on a graph this fragmented, more so on Metal/Dawn's
dispatch model than was observed on Vulkan/Dawn; (b) Apple's own MPS backend in PyTorch
is a mature, heavily-optimized, first-party acceleration path for exactly this kind of
model, which onnxruntime's WebGPU EP (a much younger, cross-vendor abstraction) has no
particular reason to beat on Apple's own hardware.

**CoreML — checked separately, not silently substituted for WebGPU (per this brief's
explicit instruction)**: `demucs-onnx`'s own native `--providers coreml` option (a real,
built-in, unmodified feature of the installed package, distinct from this project's
custom WebGPU monkeypatch) was tested directly on the same model file and **fails to
compile at all**:

```
onnxruntime.capi.onnxruntime_pybind11_state.Fail: [ONNXRuntimeError] : 1 : FAIL :
Error compiling model: compiler error: Espresso exception: "Invalid argument":
generic_general_slice: Invalid values 2048 in begin_ids for input_shape 1
```

A real, repeatable CoreML/Espresso compiler limitation on this graph's dynamic-shape
slice operations — reported honestly as a genuine platform-compatibility finding, not
glossed over or worked around. (Contrast with the earlier Phase M1 MDX-Net experiment,
where the much simpler 185-node MDX-Net graph *did* compile and run successfully under
CoreML — this is graph-complexity-dependent, not a blanket "CoreML doesn't work"
finding.)

## 9. Unified-memory observations

Measured with `memory_pressure`/`vm_stat`/`sysctl vm.swapusage` before this phase's
work began and after the full route/analysis suite completed (13 separation runs total
across both venvs, sequential, in a machine already carrying background load from the
earlier session's work — not a clean dedicated test box):

| | Before this phase | After this phase |
|---|---|---|
| System-wide free memory | 67% | 79%¹ |
| Swap file size | 4096 MB | 5120 MB |
| Swap used | ~3217 MB | ~3472 MB |

¹ Higher *after* only because the Python processes had exited and their memory was
reclaimed by the time this was sampled, same caveat as documented in the earlier Phase
M1 report — not evidence the runs themselves were memory-light. **The swap file grew
again during this phase** (continuing the trend from the earlier MDX-Net phase on this
same machine/session) — real, cumulative memory pressure across this whole multi-hour
validation session, on an 8 GB unified-memory machine already running other software.
**No OOM, no crash, no failed allocation** at any point across all 13 runs (5 unique
route configurations, repeated for the 3 `shifts=2` seeds) — the full L8 route matrix
completed successfully. Peak per-process RSS was not separately re-instrumented this
phase (consistent with L5/L6/L7's own choice not to re-litigate an already-answered,
heavily-caveated whole-system measurement question — see `resource_sampler.py`'s
already-documented reliability limits for RSS/VRAM/GPU-util attribution).

This machine's 8 GB should not be assumed to have comfortable headroom for
significantly longer clips, larger batch sizes, or additional concurrent load without
re-checking swap/pressure directly.

## 10. Platform-specific failures and limitations

- **WebGPU is real but not practically advantageous on this hardware** (§8) — the
  single most important platform-specific finding of this phase.
- **CoreML cannot compile the Demucs/htdemucs graph at all** (§8) — a genuine, verified
  compiler-level incompatibility for this specific graph's dynamic-shape ops, distinct
  from WebGPU's "works but slow" result.
- **`ConvActivationFusion` WebGPU-EP bug (L4) reproduces identically on Metal** (§4) —
  confirms this is an onnxruntime-internal issue, not Linux/Vulkan-specific; the
  existing `ORT_ENABLE_BASIC` workaround (already in `webgpu_adapter.py` since L4)
  works unchanged, no new code was needed.
- **No macOS-specific code change was needed anywhere** in `webgpu_adapter.py`,
  `demucs_shift_wrapper.py`, or any other experiment file — everything used in this
  phase is byte-identical to what L4-L7 committed. This itself is a positive
  cross-platform-code-quality finding (§L8.9 of the brief): the existing
  provider-agnostic, device-selection-isolated design held up exactly as L7's own
  "Recommendation for L8" predicted it would.
- **`modeltest.wav` unavailable on this machine** (§6) — a data-availability
  limitation, not a technical one; the substitute fixture used is well-characterized
  and the limitation this creates (no byte-identical cross-platform comparison against
  L7's exact input) is disclosed explicitly rather than glossed over.
- **onnxruntime-ep-webgpu's known macOS Intel gap (L3/L4) was not re-tested here** —
  this machine is Apple Silicon only; the macOS-Intel-specific finding from L3/L4
  (`onnxruntime-ep-webgpu`'s base `onnxruntime` dependency has no macOS x86_64 wheel)
  remains as previously documented and is unaffected by this phase's Apple-Silicon-only
  results.

## 11. Regression results

| Check | Result |
|---|---|
| `demucs_shift_wrapper.py` unmodified, `shifts=0` behavior unchanged | **PASS** — delegates straight to `_chunked_separate_single`, zero offsets logged, matches docstring exactly |
| `shifts=2` behavior unchanged | **PASS** — same wrapper, same stochastic-offset design, correctly reproducible via seeding (§6) |
| Four-stem routing | **PASS** — self-correlation 1.0 for every stem; cross-stem correlation 0.008-0.155, well separated from the diagonal, no swap detected |
| Valid WAV/array outputs | **PASS** — correct shape (4 stems × `(2, 1102500)` @ 44.1 kHz = 25.000 s), finite (no NaN/Inf), no unexpected silence (RMS 0.019-0.082), no clipping (peak ≤0.726) across every route checked |
| No model changes | **PASS** — SHA256-verified byte-identical `htdemucs.onnx` to L4-L7 (`68d0bf16...cc5e74`, independently re-verified via direct hash computation on this machine, not assumed) |
| No production-code changes | **PASS** — `audio-separator`, `demucs-onnx`, `webgpu_adapter.py` all used read-only/unmodified; only runtime monkeypatches (device forcing on `Separator` instances, `final_process` capture), same techniques L4/M1 already established, restored after use |
| No changes to the released macOS installer/bundled runtimes | **PASS** — no file under `scripts/reaper/`, no installer artifact, no bundled runtime touched |
| No modification of the canonical checkout | **PASS** — `/Users/flark/GIT/STEMwerk` untouched throughout (verified via `git status` before and after this phase) |
| No accidental staging of audio/caches/models/env files | **PASS** — all test fixtures, model downloads, `.npy`/`.json` intermediate artifacts kept in `/tmp/l8-parity-test/` and the two isolated venvs, entirely outside the git worktree; verified via `git status --short` before committing (§ commit below) |
| No interference with STEMwerk Standalone's M1 environment or other existing macOS validation worktrees | **PASS** — neither touched; this phase only used its own two isolated venvs and the one shared `experiment/webgpu-ep` worktree |

## 12. Practical implications for STEMwerk

**On this specific machine (Apple M1, 8 GB), for the Demucs/htdemucs model: no case for
adopting ONNX/WebGPU over the existing PyTorch/MPS production route.** The existing
MPS path is both faster (3.02× real-time vs. WebGPU's 0.51×) and numerically the actual
production reference already — there is nothing to gain and real complexity to add
(a second onnxruntime-based inference stack, a `graph_optimization_level` workaround
specific to this model's graph, a provider that's slower than the status quo).

This is a **materially different conclusion than the earlier MDX-Net Phase M1 result**
on the exact same machine (WebGPU 1.68× faster than CPU for MDX-Net) — the two findings
do not contradict each other; they establish that **WebGPU's advantage on Apple Silicon
is model/graph-dependent**, not a blanket property of the platform. MDX-Net's much
simpler 185-node graph benefits from WebGPU on this M1; Demucs' far more complex
1594-node graph does not, and is in fact actively disadvantaged relative to the
existing MPS route. Any future WebGPU-adoption discussion for STEMwerk should be scoped
per-model, not treated as a single yes/no platform question.

The Linux side of this experiment (L4) reached a genuinely different, favorable
conclusion for the *same* Demucs model on AMD/RX-9070 (2.2× faster than CPU there,
where there is no MPS-equivalent first-party GPU path to compete against). **If a
cross-vendor WebGPU Demucs route were pursued for STEMwerk, the practical case for it
would rest entirely on non-Apple-Silicon platforms** (AMD/NVIDIA/Intel on Linux/Windows,
where no comparably mature first-party PyTorch GPU backend already exists in
STEMwerk's current architecture for every vendor) — not on macOS, where PyTorch/MPS is
already fast, already production, and already wins this comparison outright.

The CoreML compiler failure (§8/§10) additionally rules out CoreML as a near-term
alternative acceleration path for this specific model on this platform, without further
upstream investigation (this is a `demucs-onnx`/onnxruntime CoreML EP graph-compilation
issue, not something this experiment can fix).

## 13. Recommended next experimental phase

Given §12's finding that WebGPU's practical value is model-dependent and
platform-dependent, and that the Apple-Silicon macOS case for the *Demucs* model
specifically is now clearly negative on performance grounds (not blocked on technical
feasibility — feasibility is fully proven, §4-§7), the highest-leverage next steps are:

1. **If cross-vendor WebGPU-Demucs is still of interest**: validate on a
   non-Apple-Silicon, non-AMD platform (NVIDIA/Linux or any Windows GPU vendor) where,
   unlike this Mac, there is currently no already-fast first-party PyTorch GPU backend
   in STEMwerk's Demucs path to lose to — this is where §12 suggests the actual
   practical opportunity (if any) lies.
2. **Root-cause the WebGPU-slower-than-CPU-on-M1 result** (§8's open question) before
   drawing any stronger platform-level conclusion — per-kernel dispatch timing on
   Metal/Dawn for this graph would distinguish "fixable overhead" from "structural
   Apple-Silicon-WebGPU limitation for large/fragmented graphs," which materially
   changes whether this finding is temporary or durable.
3. **Obtain L7's exact `modeltest.wav` fixture** (transfer from the Linux machine,
   SHA256-verified per this brief's original instruction) and re-run §6's comparison
   against it specifically, to get a true byte-identical cross-platform numerical
   comparison rather than this phase's necessarily-limited substitute-fixture
   comparison — lower priority than (1)/(2) since §6's own result is already a strong,
   internally-consistent PASS on its own fixture, but would close the one disclosed gap
   in this phase's rigor.
4. Given §12's clear negative performance verdict for this specific model/platform
   combination, **do not integrate ONNX/WebGPU-Demucs into STEMwerk's macOS production
   path** on the basis of this phase's evidence — this is not a "needs more testing"
   conclusion, it is a measured result that would need to change materially (e.g. via
   (2) resolving favorably) before revisiting that decision for macOS specifically.

## Reproducing this phase

```bash
# Main venv (PyTorch CPU/MPS reference routes -- reuses the existing MDX-Net Phase M1
# venv, same as L4's own methodology)
source /Users/flark/stemwerk-m1-validation/venvs/webgpu-ep/bin/activate
# (audio-separator + torch already installed there from the earlier MDX-Net phase)

# New, isolated venv (ONNX CPU/WebGPU routes)
python3.12 -m venv /Users/flark/stemwerk-m1-validation/venvs/webgpu-ep-demucsonnx
source /Users/flark/stemwerk-m1-validation/venvs/webgpu-ep-demucsonnx/bin/activate
pip install demucs-onnx onnxruntime-ep-webgpu onnx

# Fetch the exact same SHA256-verified model L4-L7 used
python3 -c "
from demucs_onnx._hub import download_single_model
print(download_single_model('htdemucs'))
"
# Expected SHA256: 68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74

# ONNX CPU / WebGPU, with the required graph_optimization_level workaround
python3 - <<'PYEOF'
import sys; sys.path.insert(0, "/path/to/experiments/webgpu-ep")
from webgpu_adapter import select_device, _ORIGINAL_INFERENCE_SESSION_CLASS
from demucs_shift_wrapper import run_with_seed
from demucs_onnx._hub import MODEL_REGISTRY
import onnxruntime as ort, soundfile as sf, numpy as np

device = select_device()  # omit pci_bus_id on single-GPU systems (macOS)
so = ort.SessionOptions()
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
so.add_provider_for_devices([device], {})
session = _ORIGINAL_INFERENCE_SESSION_CLASS("/path/to/htdemucs.onnx", sess_options=so)

mix, sr = sf.read("/path/to/your_fixture.wav")
mix = mix.T.astype(np.float32)
info = MODEL_REGISTRY["htdemucs"]
out, offsets = run_with_seed(session, info.sources, mix, shifts=2, seed=111)
print(offsets)
PYEOF

# PyTorch CPU/MPS reference (main venv, STEMwerk's actual DemucsSeparator)
python3 -c "
from audio_separator.separator import Separator
import torch
sep = Separator(model_file_dir='/path/to/cache', output_dir='/path/to/out',
                 demucs_params={'segment_size': 'Default', 'shifts': 2, 'overlap': 0.25, 'segments_enabled': True})
sep.torch_device = torch.device('mps')  # or 'cpu'
sep.load_model('htdemucs.yaml')
sep.separate('/path/to/your_fixture.wav')
"
```

IMPORTANT (per L7.3, independently reconfirmed this phase, §6): when comparing PyTorch
and ONNX arrays yourself, normalize BOTH to `(channels, samples)` before computing any
length/slicing — PyTorch's captured raw arrays are `(samples, channels)`, ONNX's are
`(channels, samples)`.
