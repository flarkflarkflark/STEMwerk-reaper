# Demucs ONNX/WebGPU — Windows NVIDIA Validation (Phase W1)

Status date: 2026-09-20. Companion to `DEMUCS_ONNX_FEASIBILITY.md` (L4),
`DEMUCS_REAL_MUSIC_PARITY.md` (L5), `DEMUCS_SHIFT_PARITY.md` (L6),
`DEMUCS_INDEPENDENT_MUSIC_VALIDATION.md` (L7), `DEMUCS_MACOS_APPLE_SILICON.md` (L8).
Tests whether the same, unmodified (Windows-specific fixes noted below and kept
minimal) `demucs-onnx`/`webgpu_adapter.py`/`demucs_shift_wrapper.py` implementation
that L4-L8 validated on Linux/AMD/Vulkan and macOS/Apple Silicon/Metal works on
Windows/NVIDIA/D3D12, whether GPU inference genuinely executes there, and whether it
offers a practical advantage over STEMwerk's existing Windows production route
(PyTorch/CUDA).

**Headline result: technically works end-to-end, on the actually-confirmed D3D12
backend (not merely "Windows means D3D12" — proven with live evidence, see §4) —
1594/1594 nodes on WebGPU, zero CPU fallback, numerical parity as strong as every
prior phase. But exactly like macOS/MPS in L8, it is measurably slower than
STEMwerk's existing production PyTorch/CUDA route on this hardware: ≈4.8× slower with
production settings (`shifts=2`).** Three genuine, previously-latent bugs in the
shared adapter code were found and fixed — none of them Vulkan- or Metal-specific,
all Windows-only, all confirmed with direct before/after evidence, none guessed.

## 1. Git synchronization

- Repository: `C:\Users\Administrator\Documents\GIT\STEMwerk` (canonical checkout,
  left untouched throughout — still on `integration/2.4.0.0`, its pre-existing
  unrelated state unchanged).
- Branch: `experiment/webgpu-ep`. Remote HEAD verified via `git fetch origin --prune`
  before any work: `0e8d825fcd89df0cd65d44966165afc99d787ab1` (full SHA), exactly
  matching the expected post-L8 HEAD — no discrepancy to investigate.
- Ancestry verified: `dbfeab59` (L1) → `ae75db92` (L2) → `467c7ce2` (M1) → `a9a27421`
  (L3) → `008f7ebc` (L4) → `4a380909` (L5) → `0fae0d61` (L6) → `c59c8e42` (L7) →
  `0e8d825f` (L8), all present as ancestors, branched from `c0f1d3294` (the same
  common maintenance base as the parallel 2.3.1.2 hotfix work on this machine).
- Worktree: `C:\Users\Administrator\Documents\GIT\STEMwerk-worktrees\experiment-webgpu-ep-win-nvidia`,
  created via `git worktree add ... experiment/webgpu-ep` (existing branch, tracking
  `origin/experiment/webgpu-ep` — no new branch history). All other existing
  worktrees on this machine (the parallel 2.3.1.2 Windows NVIDIA DKS-CPU hotfix work,
  Blackwell investigations, etc.) confirmed untouched.
- No merges, rebases, cherry-picks, or edits to any other branch. No `git push` at
  any point.

## 2. Prior evidence reviewed

Full `README.md` (L1-L8, all phases) plus `DEMUCS_ONNX_FEASIBILITY.md`,
`DEMUCS_REAL_MUSIC_PARITY.md`, `DEMUCS_SHIFT_PARITY.md`,
`DEMUCS_INDEPENDENT_MUSIC_VALIDATION.md`, `DEMUCS_MACOS_APPLE_SILICON.md`, and the
adapter/wrapper source (`webgpu_adapter.py`, `demucs_shift_wrapper.py`,
`end_to_end_pipeline_test.py`, `resource_sampler.py`) read in full before any Windows
work began. Key facts carried forward, not re-derived: the `UVR_MDXNET_KARA_2.onnx`
MDX-Net injection point (§2a of `README.md`), the `ConvActivationFusion` WebGPU-EP
bug and its `ORT_ENABLE_BASIC` workaround (L4, reproduced on Metal in L8), the
GPU-selection safeguards (`select_device()` refuses to guess with >1 device), the
per-node placement log verification standard, the shift-averaging transcription in
`demucs_shift_wrapper.py`, and the recurring vocals/other parity discrepancy
(L5/L6, not reproduced in L7/L8's independent fixtures).

## 3. Isolated Windows environment

Two fully isolated venvs, outside the git worktree, mirroring the Linux/macOS
`stemwerk-rnd`/`stemwerk-m1-validation` convention — neither touches, modifies, or was
created inside any production STEMwerk venv:

| | Path | Contents |
|---|---|---|
| Main experiment venv | `C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep\.venv-webgpu\` | `onnxruntime==1.30.0`, `onnxruntime-ep-webgpu==0.3.0`, `onnx==1.23.0`, `numpy==2.4.6`, `soundfile==0.14.0`, `audio-separator==0.47.0`, `audioread==3.1.0`, `torch==2.14.0` (generic PyPI build, CPU-only — pulled in transitively by `audio-separator`, matching L1-L8's own methodology of keeping STFT/windowing on CPU regardless of ONNX EP) |
| Demucs-ONNX venv (new this phase) | `C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep-demucsonnx\.venv-demucsonnx\` | `demucs-onnx==0.3.4` (identical version to L4-L8), `onnxruntime==1.30.0`, `onnxruntime-ep-webgpu==0.3.0`, `onnx==1.23.0`, `soundfile`, `numpy` — **no torch installed**, confirmed empirically (import never attempted, full separation completed anyway), matching L4/L8's own finding that `demucs-onnx` needs no PyTorch at inference |

- Python: 3.11.8 (only version available on this machine via `py -3.11`; `onnxruntime-ep-webgpu`
  requires ≥3.11 per its own PyPI metadata). Native `AMD64`/`win_amd64` throughout —
  confirmed by inspecting the actual downloaded wheel filenames
  (`onnxruntime_ep_webgpu-0.3.0-py3-none-win_amd64.whl`, `torch-2.14.0-...-win_amd64.whl`,
  etc.), not assumed.
- Windows: 11 Pro, build 10.0.26200.
- No system driver, SDK, Vulkan/Dawn, or runtime library was installed — `nvidia-smi`
  (bundled with the existing NVIDIA driver) and `ffmpeg` (STEMwerk's own already-installed
  bundled copy, read-only, added to `PATH` for the duration of test runs only — not
  copied, not modified, not added system-wide) were the only external, already-present
  dependencies used, mirroring Linux's own reliance on an already-installed system
  Vulkan loader.
- No production STEMwerk venv (`.venv`, `.venv-drumsep-cuda`) was modified. STEMwerk's
  main production venv (`C:\Users\Administrator\AppData\Local\STEMwerk\.venv\`) was
  used **read-only** as an interpreter for the §8 PyTorch/CUDA production reference run
  — nothing was installed into it, confirmed via its state being identical before and
  after (only `.pyc` cache effects possible, no package changes).

## 4. Actual graphics backend — proven, not assumed

This machine has **two** GPUs (a gaming laptop, not the single-GPU macOS case or the
discrete+iGPU-same-vendor Linux case) — `list_webgpu_devices()` finds both:

```
vendor_id=4318 (0x10DE=NVIDIA) device_id=9504  Description=NVIDIA GeForce RTX 3060 Laptop GPU  Discrete=1  DxgiVideoMemory=5994 MB
vendor_id=4098 (0x1002=AMD)    device_id=5688  Description=AMD Radeon(TM) Graphics            Discrete=0  DxgiVideoMemory=495 MB
```

Calling `select_device()` with no selector correctly **raises**
`GpuExecutionNotProvenError` ("2 WebGPU devices found ... refusing to guess") — the
existing safeguard, unmodified, working correctly on a genuinely new scenario
(NVIDIA+AMD, not same-vendor multi-GPU) this project had never actually tested before.
The RTX 3060 is selected explicitly throughout via `select_device(device_id=9504)` —
**zero changes to `select_device()` itself** were needed; Windows/Dawn/D3D12 exposes a
richer `metadata` dict than Linux (`pci_bus_id`) or macOS (empty) — `Description`,
`Discrete`, `DxgiAdapterNumber`, `DxgiVideoMemory`, `LUID` — but the existing
`device_id` selector (already present for exactly this kind of case, originally
motivated by Linux's own RX 9070 vs Phoenix iGPU distinction) was sufficient as-is.

**D3D12 vs Vulkan — determined with live evidence, not inferred from "it's Windows":**
Static binary inspection alone is **not sufficient** on Windows, unlike macOS: the
installed `onnxruntime_providers_webgpu.dll` statically references **both** backend
toolchains (`d3dcompiler_47.dll`/`dxcompiler.dll`/`dxil.dll` for D3D12, **and**
`vulkan-1.dll` for Vulkan) — Dawn's Windows build ships both, choosing at runtime.
Proof instead came from checking which backend DLL is actually **loaded into the live
process** at the moment of WebGPU session creation (`ctypes` `GetModuleHandleW`, a
direct dynamic analogue of macOS's static `otool -L` check):

| Module | Before session creation | After session creation + real inference |
|---|---|---|
| `d3d12.dll` | not loaded | **loaded** |
| `dxcompiler.dll` | not loaded | **loaded** |
| `dxil.dll` | not loaded | **loaded** |
| `vulkan-1.dll` | not loaded | **never loaded** |
| `dxgi.dll` | already loaded (adapter enumeration) | loaded |

**D3D12 confirmed, Vulkan confirmed never touched.** This is the requested backend
(§4 of the brief: "prefer D3D12 when supported") and is what actually executed, not
an assumption.

## 5. MDX-Net regression (`UVR_MDXNET_KARA_2.onnx`)

Ran `end_to_end_pipeline_test.py` unchanged in design (two flags added, see §11) via
`--device-id 9504`, on a real 25.0 s excerpt of a personally-owned FLAC track (see §7
for full fixture provenance — the same fixture is reused for the Demucs phase below,
per the brief's "same Windows input for all local backend comparisons" instruction).

| Check | Result |
|---|---|
| Native WebGPU EP registration | **PASS** — 2 devices found, RTX 3060 explicitly selected (not the AMD iGPU) |
| Graph placement | **PASS** — `"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185"` — **identical node count to Linux (L1/L2/L3) and macOS (M1)** |
| CPU fallback | **PASS** — 0 fallback nodes |
| Model loading / actual inference | **PASS** — real named D3D12/Dawn kernel dispatches observed (`Conv2dMM`, `Transpose`, real MDX-Net op names, not synthetic) |
| Complete audio processing | **PASS** — both providers produced 2 stems (Vocals, Instrumental), no crash, complete export |
| Output validation | **PASS** — sr=44100, ch=2, duration=25.00s, no NaN/Inf, no unexpected silence, no clipping, for both providers |
| Stem routing | **PASS** — same-stem corr ≈1.000000 vs other-stem corr ≈0.178 (well separated) |
| Raw (pre-export) numeric comparison | **PASS** — Vocals corr=0.99999999994771 max_abs_diff=**1.10e-06**; Instrumental corr=0.999999999999941 max_abs_diff=**1.03e-06** — both ~4 orders of magnitude inside the pre-declared 5e-3 ceiling |
| File (exported WAV) numeric comparison | **PASS** — both stems max_abs_diff=3.05e-05 = **exactly 1.00× PCM16 LSB**, identical pattern to every prior platform |
| Single-run timing | load: CPU=10.51s / WebGPU=0.79s; run: CPU=28.02s / WebGPU=3.14s (≈8.9× single-run) |

This establishes that the original shared MDX-Net route survives a third operating
system, a third GPU vendor, and a genuinely new dual-vendor-GPU selection scenario,
with **bit-for-bit-identical graph node counts (185)** to both prior platforms.

### 5a. Formal 4-run warm benchmark (`benchmark_resources.py`)

| Metric | CPU EP | WebGPU EP (RTX 3060, D3D12) |
|---|---|---|
| Session/model load | 1.89 s | 0.77 s |
| First ("cold") run | 15.02 s | 2.91 s |
| Warm runs (3 repeats), min–max | 13.69–13.86 s | 2.63–2.69 s |
| Warm median | 13.81 s | 2.67 s |
| Warm stdev | 0.086 s | 0.029 s |
| Real-time factor (25.00 s clip, warm) | 1.8× | 9.4× |
| Speedup vs CPU (warm median) | 1.0× (ref) | **5.17×** |
| Graph placement (re-verified across all 4 runs) | 100% CPU (by definition) | **185/185 nodes on GPU, 0 fallback, one session reused across all 4 runs** |
| Peak process RSS | 2211.5 MB | 792.0 MB |
| Peak GPU memory, whole-GPU attributable delta (`nvidia-smi`, best-effort) | 1.0 MB | 1082.0 MB |
| Avg whole-GPU utilization | 2.8% | 46.8% |

**Not directly comparable in absolute terms to Linux's L2 table (20 s clip) or
macOS's Phase-M1 table (6 s clip)** — different input length, different hardware —
per the brief's own instruction. What *is* comparable: the qualitative pattern
(WebGPU faster than CPU, one verified session reused, zero fallback) holds
identically across all three platforms tested so far for this model.

## 6. Demucs ONNX validation

Model: `htdemucs.onnx` via `demucs_onnx._hub.download_single_model("htdemucs")` — the
exact community export L4-L8 used.

- **SHA256: `68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`
  — byte-identical to L4-L8's artifact**, verified by direct hash computation on this
  machine after a fresh download (not assumed, not copied from another machine).

### 6a. `ConvActivationFusion` bug — confirmed to reproduce on D3D12

Constructing a session with onnxruntime's default `graph_optimization_level`
(`ORT_ENABLE_ALL`) fails identically to L4 (Vulkan) and L8 (Metal):

```
EPFail: [ONNXRuntimeError] : 11 : EP_FAIL : .../onnxruntime/core/providers/webgpu/nn/conv.h:21
onnxruntime::webgpu::Conv<1,1>::Conv GetFusedActivationAttr(info, activation_).IsOK() was false.
```

**Same file, same line, same message, third backend (D3D12) confirmed.** This is
conclusively an onnxruntime-internal WebGPU-EP bug independent of the underlying
graphics API — not something this experiment can or should try to fix upstream. The
existing `ORT_ENABLE_BASIC` workaround (added in L4, unmodified since) avoids it here
too, with no Windows-specific change needed to the workaround itself.

### 6b. GPU execution evidence

```
All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594
```

**1594/1594 — identical node count to Linux (L4-L7) and macOS (L8), zero CPU
fallback.** `session.get_providers()` returns
`['WebGpuExecutionProvider', 'CPUExecutionProvider']` (the log-captured placement
line is the actual proof, not the provider list alone — same standard as every prior
phase).

### 6c. Numerical parity (`shifts=0`, deterministic)

Sanity check first (same framework, different device, expected near-exact — this is
where a genuine, disclosed deviation from prior-phase tightness was found, see §6e):

| Comparison | drums | bass | other | vocals |
|---|---|---|---|---|
| PT-CPU vs PT-CUDA correlation | 0.999996 | 0.999891 | 0.989035 | 0.982475 |

Main parity table, `shifts=0`:

| Stem | PT-CUDA vs ONNX-CPU corr | max abs diff | ONNX-CPU vs ONNX-WebGPU corr | max abs diff |
|---|---|---|---|---|
| drums | 0.999769 | 1.09e-01 | 0.999999999 | 4.32e-04 |
| bass | 0.999831 | 8.56e-02 | 1.000000000 | 5.45e-04 |
| other | 0.977991 | 1.08e-01 | 0.999999938 | 1.49e-04 |
| vocals | 0.980250 | 9.75e-03 | 0.999999478 | 3.12e-05 |

**ONNX-CPU-vs-WebGPU backend fidelity is excellent across every stem** (correlation
≥0.9999994, matching every prior phase's "backend-only difference is near the float32
noise floor" pattern). The looser PT-vs-ONNX numbers for `other`/`vocals` are
investigated in §6e below with a concrete, numerically-confirmed root cause specific
to this fixture — not glossed over.

### 6d. `shifts=2` production-setting statistics (3 seeds: 111, 222, 333)

Same design as L6-L8: PyTorch's own run-to-run noise floor (independent seeded
`shifts=2` CUDA runs, no ONNX involved) vs. the PT-vs-ONNX-WebGPU gap.

| Stem | PyTorch noise floor (rel. RMS) | PT vs ONNX-WebGPU (mean of 3 seeds) | Ratio |
|---|---|---|---|
| drums | 2.90% | 2.77% | **0.96×** |
| bass | 2.78% | 2.13% | **0.77×** |
| other | 51.05% | 31.43% | **0.62×** |
| vocals | 265.45% | 60.44% | **0.23×** |

At face value, every ratio is <1.0 — consistent with L6/L7/L8's own "PT-vs-WebGPU gap
below PyTorch's own noise floor" pattern. **But the `other`/`vocals` noise-floor
percentages themselves (51%, 265%) are anomalously large compared to every prior
phase's (single-digit to low-double-digit %)** — investigated directly rather than
taken at face value, see §6e.

Backend-only fidelity (ONNX CPU vs WebGPU, identical offsets, `shifts=2`) remains
excellent regardless:

| Stem | Correlation (all 3 seeds) | Max abs diff (range) |
|---|---|---|
| drums | 1.00000000 | 1.29e-04 – 1.79e-04 |
| bass | 1.00000000 | 1.20e-04 – 1.76e-04 |
| other | 0.9999999 | 1.07e-04 – 1.42e-04 |
| vocals | 0.9999996 | 3.57e-05 – 5.18e-05 |

Offsets drawn per seed (Python's `random`, identical across CPU/WebGPU, and
**identical to L7/L8's own recorded offsets for the same seeds** — confirming
cross-platform `random` determinism for a fourth time: Linux, macOS, and now Windows):
`111→[6971, 10353]`, `222→[3535, 7708]`, `333→[18180, 11495]`.

### 6e. Root cause of the `other`/`vocals` anomaly — diagnosed, not merely disclosed

Unlike L5/L6 (which attributed their residual to the fixture's reconstructed-mix
provenance, a plausible but unconfirmed hypothesis), this fixture is a genuine
original studio master (see §7) — so a different explanation was investigated
directly. Measuring the raw per-stem signal level (PT-CUDA, `shifts=0`) explains it
numerically:

| Stem | RMS | Peak |
|---|---|---|
| Bass | 0.3397 | 0.760 |
| Drums | 0.2152 | 1.347 |
| Other | 0.0164 | 0.314 |
| Vocals | **0.0017** | 0.026 |

**This track (`11th Hour – Project XI`, an instrumental progressive/tech act) has
little to no actual lead-vocal content — the "Vocals" stem's RMS is ~200× quieter
than Bass/Drums.** Relative-RMS-error and correlation are both highly sensitive to
near-silent signals (a small absolute difference produces a huge relative percentage,
exactly the mechanism L4 originally identified with its synthetic near-flat-energy
clip, but here occurring on a genuine, dynamic, real-music fixture that simply
happens to be mostly instrumental). This is a **fixture-content limitation specific
to this track's vocals/other stems**, not a demonstrated WebGPU or ONNX-export
defect — the ONNX-CPU-vs-WebGPU backend-fidelity numbers (§6c/§6d, unaffected by
this) stay excellent throughout. **Per the brief's explicit instruction, this
discrepancy is reported here rather than resolved or hidden** — a second,
vocal-prominent fixture was not pursued this phase given the time budget; the
existing L7/L8 finding (independent fixtures showing the discrepancy does not
generalize) is neither confirmed nor contradicted by this result, since this
fixture's vocals content is not comparable to theirs.

### 6f. Clipping observation (applies identically across every route)

The raw pre-export Drums stem consistently exceeds full scale (peak ≈1.35–1.37)
**identically across PT-CPU, PT-CUDA, ONNX-CPU, and ONNX-WebGPU** — a property of
separating this specific track's drums in isolation before any final-mix
normalization, not a backend-specific or Windows-specific defect. No NaN/Inf and no
unexpected silence were found in any of the 40 captured raw stem arrays (5 PT routes
+ 8 ONNX routes × 4 stems).

## 7. Full audio test — fixture and validation

Per the brief's "no copyrighted music in Git" and "one suitable local real-music
fixture" instructions: a genuinely owned, already-local FLAC track was used (never
transferred between machines), following the exact L7/L8 dead-air-scan methodology.

| Property | Value |
|---|---|
| Source | `11th Hour – Project XI – 01 Project XI.flac` (personal Bandcamp purchase, outside any git repository) |
| Full-file duration | 336.0 s |
| Excerpt used | 192.0–217.0 s (25.0 s), scanned second-by-second for dead air first; none found, RMS stayed in a 0.385–0.424 range throughout |
| Sample rate / channels | 44,100 Hz / 2 (stereo) |
| Full-file SHA256 | `179cf6debfeda8db809d9919c4751a8dfce045d5c17473651f1531abad9ede6e` |
| Excerpt SHA256 (16-bit PCM WAV) | `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` |
| Energy-variance ratio (crest-factor proxy) | 0.4484 — genuinely dynamic (comparable to L8's 0.399, L5/L6's 0.350, L7's 0.513) |

Kept entirely outside Git throughout (`C:\Users\Administrator\stemwerk-rnd\evidence\`).

All four stems (Drums, Bass, Vocals, Other) were validated across every route and
backend (§6f): correct sample rate (44100 Hz), correct channel count (2), correct
duration (25.0 s / 1,102,500 samples, exact match across all 13 captured routes), no
NaN/Inf, no unexpected silence, and the one disclosed clipping-relevant observation
(§6f) that applies identically regardless of backend. Per the brief's explicit
instruction: **this does not constitute a claim of complete production equivalence**
— see §6e's vocals/other caveat and §8/§9 below for the practical-performance
verdict.

## 8. NVIDIA reference comparison

**A. STEMwerk's actual production PyTorch/CUDA** — used directly, read-only, via
STEMwerk's own already-installed main venv (`torch==2.7.1+cu128`, confirmed
`torch.cuda.is_available()==True`, device name `NVIDIA GeForce RTX 3060 Laptop GPU`),
running the real `audio_separator.separator.Separator` class with `sep.torch_device =
torch.device("cuda")`, the real production checkpoint
(`955717e8-8726e21a.th`, confirmed to be the exact "htdemucs" — not "htdemucs_ft" —
checkpoint via `htdemucs.yaml`'s `models: ['955717e8']` mapping and its own
self-checksummed filename convention, same identity-verification standard L5
established), and production `demucs_params` (`segment_size: Default, shifts: 2,
overlap: 0.25`). **This is a genuine pipeline comparison (PyTorch's full STFT-free
time-domain Demucs pipeline) against ONNX's pipeline, not a pure backend
comparison — reported as such, per the brief's explicit distinction.**

**B. Demucs ONNX / CPU** and **C. Demucs ONNX / WebGPU** — §6/§6d above, same model,
same fixture, same `demucs_shift_wrapper.py` shift-averaging.

**D. ONNX Runtime CUDA reference** — not attempted this phase (optional per the
brief; DirectML also optional and not attempted). Given the clear, decisive result
already obtained comparing against the real production route (A), and the time
budget, this was deprioritized — noted as a gap, not silently skipped.

### 8a. Performance: A vs C (the comparison STEMwerk actually cares about)

| Route | `shifts=0` | `shifts=2` (mean of 3 seeds) | RTF (25.0 s clip, `shifts=2`) |
|---|---|---|---|
| PyTorch CPU | 15.27 s | — (not repeated; not the production route on this hardware) | — |
| **PyTorch CUDA (STEMwerk's actual production route)** | **2.58 s** | **2.97 s** | **8.4×** |
| ONNX CPU | 13.42 s | 26.78 s | 0.93× (sub-real-time) |
| ONNX WebGPU | 9.68 s | 14.25 s | 1.75× |

**WebGPU vs. STEMwerk's actual production route (PyTorch CUDA, `shifts=2`): 2.97 s
vs. 14.25 s — WebGPU is ≈4.8× SLOWER, not faster.** This mirrors L8's macOS/MPS
finding (WebGPU ≈5.9× slower than production MPS) via a different vendor and a
different, more mature GPU compute stack (CUDA). Unlike macOS, WebGPU here **is**
faster than plain ONNX CPU (1.75× at `shifts=2`, up from the earlier `shifts=0`
1.39×) — so this is not "WebGPU itself is broken on this hardware" (§6b's clean
1594/1594 zero-fallback placement already rules that out) — it simply cannot compete
with a mature, first-party, vendor-optimized PyTorch/CUDA backend that STEMwerk
already ships and uses today.

**Important scope note for §10's cross-platform assessment**: this is the *second*
platform (after macOS/MPS) where Demucs-WebGPU has been benchmarked against a real,
production-grade, vendor-accelerated PyTorch backend — and it loses on both. The
original Linux phases (L4-L7) never ran an equivalent PyTorch+ROCm Demucs benchmark
(only PyTorch-CPU parity checks and a CPU-vs-WebGPU-ONNX speed comparison were
recorded for Demucs on Linux); Linux's "WebGPU beats CPU" finding was never tested
against Linux's own accelerated PyTorch/ROCm route for this model. Whether
Demucs-WebGPU would also lose to PyTorch+ROCm on Linux is therefore an **open
question this experiment cannot answer**, not something either confirmed or ruled
out by any phase to date.

## 9. Performance summary (session lifecycle)

| Metric | MDX-Net WebGPU | Demucs WebGPU (`shifts=2`) |
|---|---|---|
| Session/model load | 0.77 s | (included in first run; not separately isolated for Demucs this phase) |
| First inference | 2.91 s | ~14 s (first seed, not separately isolated from warm) |
| Warm/repeat inference | 2.63–2.69 s | 14.09–14.38 s (3 seeds) |
| Real-time factor | 9.4× | 1.75× |
| Peak process RSS | 792.0 MB | not separately re-instrumented for the Demucs routes this phase (MDX-Net's `benchmark_resources.py` 4-run harness was not re-run for Demucs; the two `onnx_route_runner.py`/`pt_reference_runner.py` scripts used for Demucs record wall-clock only) |
| GPU memory (whole-GPU, best-effort, `nvidia-smi`) | 1082.0 MB attributable delta | not measured for Demucs this phase |

**Correctness was established before any performance measurement, per the brief's
explicit ordering** — the MDX-Net formal benchmark used the dedicated
`benchmark_resources.py` harness (with the Windows RSS/`nvidia-smi` additions, §11);
the Demucs performance numbers came from the same runner scripts used for the
correctness/parity work (§6/§8), which is why per-process RSS/VRAM were not
separately isolated for Demucs — a real scope gap, disclosed rather than
backfilled with an estimate.

## 10. Cross-platform architecture assessment

| Platform | Hardware | WebGPU backend | Status |
|---|---|---|---|
| Linux | AMD RX 9070 | Vulkan (Mesa/RADV) | **Proven** — L1-L7 |
| macOS | Apple M1 | Metal | **Proven** — M1 phase, L8 |
| Windows | NVIDIA RTX 3060 Laptop GPU | **D3D12** (proven via live module-load evidence, §4) | **Proven** — this phase (W1) |

**MDX-Net (185-node graph)**: WebGPU beats CPU on all three platforms now proven
(Linux 5.3–5.75×, macOS 1.68×, Windows 5.17×) — node count is **bit-for-bit
identical (185)** across all three, confirming hardware-independent graph placement
for this model family.

**Demucs (1594-node graph)**: WebGPU beats plain CPU on Linux (2.2×) and Windows
(1.39–1.75×), but **loses to the existing mature, accelerated, first-party PyTorch
backend on every platform where that comparison has actually been made** — macOS/MPS
(≈5.9× slower) and now Windows/CUDA (≈4.8× slower). Node count is again
**bit-for-bit identical (1594)** across Linux, macOS, and Windows.

**How much Windows-specific code was required**: five files touched, all minimal and
additive —

1. `webgpu_adapter.py`: two genuine bug fixes (§11), no changes to `select_device()`,
   `create_verified_webgpu_session()`'s public contract, or the WebGPU EP
   registration/patching logic itself.
2. `webgpu_ep_probe.py`, `end_to_end_pipeline_test.py`, `benchmark_resources.py`: one
   additive `--device-id` CLI flag each (mirroring the macOS phase's own precedent of
   adding `--pci-bus-id` for parity) — zero behavior change for Linux/macOS when
   omitted.
3. `resource_sampler.py`: one new Windows RSS branch (`GetProcessMemoryInfo`) and one
   new optional `gpu_backend="nvidia"` path (`nvidia-smi`), both strictly additive —
   the Linux/macOS default paths (`card_key="card0"`, ROCm) are untouched, confirmed
   by inspecting the diff (every change is either inside a `sys.platform == "win32"`
   branch or a new parameter whose default reproduces the exact prior call signature).

**No Windows-specific change was needed anywhere in `demucs_shift_wrapper.py`** (pure
numpy/`random`, already platform-generic) or in the core device-selection/session-
patching logic of `webgpu_adapter.py` — exactly the outcome L7's own "isolate the
platform-specific pieces behind one function" design predicted, now confirmed a third
time (Linux → macOS → Windows).

**New dependencies / packaging requirements**: none beyond what L1-L8 already
identified (`onnxruntime` + `onnxruntime-ep-webgpu`, ~83 MB combined) — no Windows
SDK, no separate D3D12/DXC toolchain install (the Dawn build ships its own
`dxcompiler.dll`/`dxil.dll`/`d3dcompiler_47.dll`), no Vulkan loader needed on this
path since D3D12 is what's actually selected.

**Can the same inference adapter serve AMD, NVIDIA, Intel, and Apple Silicon without
four separate implementations?** For the WebGPU/ONNX inference layer specifically:
**yes, now demonstrated on three of the four** (AMD/Linux, Apple/macOS, NVIDIA/Windows)
with the *same* `webgpu_adapter.py` device-selection/session-verification core and
*zero* platform-specific code in the actual inference path
(`demucs_shift_wrapper.py`, `demucs_onnx`, `audio-separator`'s MDX pipeline). **Intel
GPU compatibility is not claimed — not tested, on any platform, by this experiment.**
**Windows AMD compatibility is not claimed based on this Windows/NVIDIA result** — a
genuinely different vendor's D3D12/Vulkan driver stack, untested. **The documented
macOS Intel (x86_64) `onnxruntime`-wheel gap from L3/L4 stands, unaffected by this
phase** (this machine is Windows, not macOS, so it neither confirms nor changes that
finding).

## 11. Windows-specific code changes made (all on `experiment/webgpu-ep`, no new branch)

Small, isolated, kept to what was genuinely necessary — verified with direct
before/after evidence in every case, per the brief's own "verify, don't assume"
standard used throughout L1-L8:

1. **`webgpu_adapter.py` — `ctypes.CDLL(None)` fflush crash (real bug, not
   cosmetic).** `_capture_stderr_fd()`'s cleanup (`finally`) block called
   `ctypes.CDLL(None)` to flush C stdio buffers before restoring the real stderr fd.
   `CDLL(None)` is a POSIX-only pattern (`dlopen(NULL)`); on Windows it raises
   `TypeError` immediately — **and because this happened inside `finally`, the
   original stderr fd was never restored**, a genuine correctness bug beyond just
   this experiment's own log capture. Fixed with a `_libc_for_fflush()` helper:
   `ctypes.CDLL("msvcrt")` on Windows (Python's own linked CRT, the standard stand-in
   for exactly this purpose), unchanged `ctypes.CDLL(None)` elsewhere.
2. **`webgpu_adapter.py` — UTF-16LE vs UTF-8 log decoding.** Confirmed via raw hex
   dump: onnxruntime's C++ core writes its verbose log to the redirected Windows
   stderr fd as pure UTF-16LE (every ASCII byte followed by a literal `0x00`), not
   UTF-8 like Linux/macOS. The original single-byte-codec read
   (`open(path, "r", errors="replace")`) silently interleaved NULs between every
   character, so the node-placement regex never matched even though the real
   placement line was present in the file — this would have made *every* Windows
   `GpuExecutionNotProvenError` a false negative. Fixed with a shared
   `_read_captured_log()` helper, platform-branched on decode codec only; both call
   sites (`create_verified_webgpu_session`, `patch_inference_session_for_provider_swap`)
   now use it.
3. **`webgpu_ep_probe.py` — hardcoded `/tmp/...` path.** Resolves to a
   non-existent `C:\tmp\...` on Windows. Replaced with `tempfile.gettempdir()`, a
   platform-generic correctness fix (matches the class of fix L8 itself made for the
   hardcoded-`20.0`-second RTF bug — not a Windows-only accommodation, just a latent
   bug this platform happened to expose).
4. **`webgpu_ep_probe.py`, `end_to_end_pipeline_test.py`, `benchmark_resources.py` —
   additive `--device-id` CLI flag.** `select_device()` already supported
   `device_id` (added originally for Linux's own device disambiguation); Windows has
   no `pci_bus_id` metadata at all under Dawn/D3D12, so this flag exposes the
   already-existing selector rather than adding new adapter logic. Mirrors the macOS
   phase's own precedent of adding a CLI flag for platform parity.
5. **`resource_sampler.py` — Windows RSS reader.** `GetProcessMemoryInfo` via
   `ctypes`, explicit `argtypes`/`restype`. **A second real, confirmed bug along the
   way**: the initial implementation used bare `ctypes.windll.psapi.GetProcessMemoryInfo(...)`
   with no declared signature, which returned a falsy result *without raising* on
   this exact Windows 11/Python 3.11 combination — a silent-failure ctypes pitfall,
   not a Windows API limitation. Fixed by declaring `argtypes`/`restype` explicitly
   via `ctypes.WinDLL(..., use_last_error=True)`; verified directly (16188 KB
   returned, plausible) before use in the actual benchmark.
6. **`resource_sampler.py` — optional `nvidia-smi`-based whole-GPU VRAM/utilization
   reader.** New `gpu_backend` parameter (`"rocm"`, the unchanged default, or
   `"nvidia"`), strictly additive; every existing call site's behavior is unchanged
   unless the new parameter is explicitly passed. Same honesty class as the existing
   `rocm-smi` reader (whole-GPU, not per-process, explicitly labeled as such).
7. **`benchmark_resources.py`** — one `sys.platform` check selecting the sampler
   kwargs (`gpu_backend="nvidia"` on Windows, the original `card_key="card0"`
   elsewhere) — no other change.

**Everything else — `demucs_shift_wrapper.py`, `webgpu_adapter.py`'s
`select_device()`/EP-registration/session-patching core, `end_to_end_pipeline_test.py`'s
comparison/validation logic, `l3_model_compatibility_test.py` — is byte-identical to
what L1-L8 committed.** `l3_model_compatibility_test.py` (the multi-ONNX-model
compatibility matrix) was not re-run this phase — out of scope per the brief's six
required W1 sections, and L3.7's own reasoning for deprioritizing broader
same-model-family testing applies here too (low new-information value versus the
Demucs/production-comparison work that was the actual point of this phase).

## 12. Regression check — verified by construction, not by re-running Linux/macOS

This machine has no Linux or macOS hardware available, so unlike the macOS phase's
own Linux re-run (§"Cross-platform regression check" in `README.md`), this phase
cannot literally re-execute the prior platforms' test suites. Instead, every code
change (§11) was verified to be either (a) inside an explicit `sys.platform ==
"win32"` branch, with the non-Windows branch byte-identical to the pre-existing code,
or (b) a new, optional parameter whose default reproduces the exact prior call
signature and behavior. This was confirmed directly by inspecting the full diff
before writing this report — **by construction, no Linux or macOS code path was
altered**, though this claim has not been re-verified on physical Linux/macOS
hardware in this phase. Flagged as a real limitation of this phase's regression
coverage, not silently assumed away.

## 13. Remaining compatibility problems and open questions

- **§6e**: this phase's fixture's vocals/other stems are dominated by near-silence
  (a mostly-instrumental track), so the PT-vs-ONNX parity numbers for those two stems
  are not a clean test of export fidelity here — root-caused, not merely disclosed,
  but not resolved with a second fixture this phase.
- **§8**: no ONNX Runtime CUDA execution-provider reference was attempted (optional
  per the brief) — the practical question ("is WebGPU worth it on Windows NVIDIA")
  is already decisively answered by the real production PyTorch/CUDA comparison, but
  a pure onnxruntime-CUDA-vs-onnxruntime-WebGPU backend comparison (distinct from the
  pipeline comparison this phase made) remains untested.
- **§9**: per-process RSS/VRAM were not separately re-instrumented for the Demucs
  routes (only for MDX-Net, via the dedicated benchmark harness).
- **§10**: whether Demucs-WebGPU would also lose to PyTorch+ROCm on Linux (the one
  platform where this specific comparison has never been made, on any phase to date)
  remains open.
- **§12**: Linux/macOS regression coverage for this phase's code changes is
  verified by code-path isolation, not by re-execution on that hardware.
- The `ConvActivationFusion` bug (§6a) is now confirmed on all three onnxruntime
  WebGPU EP backends (Vulkan, Metal, D3D12) — worth raising upstream with this
  cross-platform confirmation, per L4/L8's own "worth flagging" notes.

## Practical implications for STEMwerk

**MDX-Net**: the shared WebGPU route is now proven correct and fast on all three
major desktop platforms/vendors STEMwerk could plausibly target (AMD/Linux,
Apple Silicon/macOS, NVIDIA/Windows), with identical graph placement and
near-identical numerical fidelity everywhere — but per L3.1's own finding
(reconfirmed, not re-derived, this phase), **zero current STEMwerk workflows use any
`.onnx` model**, so this remains a capability proof, not something with a current
user-facing beneficiary.

**Demucs (the model STEMwerk's default workflow actually uses)**: technically
correct and zero-fallback on Windows/NVIDIA, exactly as on Linux and macOS — but,
like macOS, **not competitive with STEMwerk's existing production accelerated route
(PyTorch/CUDA) on this hardware.** Combined with L8's identical macOS/MPS
conclusion, the practical case for adopting ONNX/WebGPU-Demucs specifically to
replace an existing first-party-accelerated PyTorch path is now negative on **two**
platforms, not one — Linux remains the only platform where this exact comparison
(WebGPU vs. the platform's own best available PyTorch GPU backend for Demucs) has
never actually been made.

## Reproducing this phase

```powershell
# Main venv (WebGPU EP experiment)
py -3.11 -m venv C:\path\to\.venv-webgpu
C:\path\to\.venv-webgpu\Scripts\pip install -r requirements-webgpu-experiment.txt

# Isolated Demucs-ONNX venv
py -3.11 -m venv C:\path\to\.venv-demucsonnx
C:\path\to\.venv-demucsonnx\Scripts\pip install demucs-onnx onnxruntime==1.30.0 onnxruntime-ep-webgpu==0.3.0 onnx==1.23.0 soundfile numpy

# Find your GPU's device_id (Windows has no pci_bus_id under Dawn/D3D12)
C:\path\to\.venv-webgpu\Scripts\python webgpu_ep_probe.py
#   lists every WebGPU device with its numeric device_id; pick the discrete GPU's.

# MDX-Net regression + benchmark
C:\path\to\.venv-webgpu\Scripts\python end_to_end_pipeline_test.py <input.wav> --device-id <id> --model-cache <dir> --out-dir <dir>
C:\path\to\.venv-webgpu\Scripts\python benchmark_resources.py <input.wav> --device-id <id> --model-cache <dir> --out-dir <dir> --runs 4

# Demucs: fetch the exact model L4-L8 used
C:\path\to\.venv-demucsonnx\Scripts\python -c "from demucs_onnx._hub import download_single_model; print(download_single_model('htdemucs'))"
# Expected SHA256: 68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74

# ORT_ENABLE_BASIC workaround is required (confirmed on D3D12, see 6a) -- see
# webgpu_adapter.py's create_verified_webgpu_session()/patch_inference_session_for_provider_swap()
# for the exact construction pattern; demucs_shift_wrapper.run_with_seed() for
# shift-averaged production-parity inference.
```
