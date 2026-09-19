# WebGPU EP experiment — native ONNX Runtime WebGPU Execution Provider on Linux/AMD

Status date: 2026-09-19. Experimental, opt-in, isolated. Not integrated into STEMwerk.

Two phases so far:
- **Phase L1** — prove the native WebGPU EP can run a real STEMwerk ONNX model at all
  (single inference call, no real audio pipeline).
- **Phase L2** (this update) — run the *same* model through STEMwerk's actual
  `audio-separator` audio pipeline end to end, with rigorous GPU-execution proof,
  output validation, a raw-vs-quantization-aware numeric comparison, a fair
  CPU/WebGPU/ROCm benchmark with resource sampling, and macOS readiness notes.

## 1. Repository, branch, worktree, base SHA

- Canonical checkout (untouched): `/mnt/PRODUCTION/GIT/STEMwerk` (left exactly as found,
  including its pre-existing uncommitted changes on `ci/repair-stale-release-checks`).
- Branch: `experiment/webgpu-ep` (still the only branch used — L2 continued on it rather
  than creating a new one, since it was clean and suitable).
- Worktree: `/mnt/PRODUCTION/GIT/STEMwerk-worktrees/webgpu-ep`
- Base SHA: `c0f1d3294` (`origin/main`, PR #124 "2.3.1.2-main-reconcile"), unchanged
  since Phase L1.
- No merges, rebases, cherry-picks, or edits to any existing branch were performed at
  any point. No `git push`.
- Venvs (both outside the exFAT `/mnt/PRODUCTION` mount — see Phase L1 note below):
  - `/home/flark/stemwerk-rnd/venvs/webgpu-ep/.venv-webgpu` — main experiment venv
    (`onnxruntime` + `onnxruntime-ep-webgpu`, CPU EP + WebGPU EP).
  - `/home/flark/stemwerk-rnd/venvs/webgpu-ep-rocmref/.venv-rocmref` — **new in L2**,
    a second, fully separate venv with `onnxruntime-rocm` installed instead, used only
    for the ROCm reference benchmark (§6). Kept separate specifically so installing a
    ROCm-specific onnxruntime build could never destabilize the already-verified
    WebGPU venv (these two onnxruntime builds are not designed to coexist in one venv).
  - Neither touches any production STEMwerk venv, Python installation, or ROCm
    component. `/opt/rocm` (system ROCm 7.2.3, already installed) was only *read from*
    (dynamic libraries), never modified.

## 2. STEMwerk architecture findings

*(Unchanged from Phase L1; repeated here for context.)* STEMwerk itself never
constructs an ONNX Runtime `InferenceSession` or references a GPU-vendor onnxruntime
execution provider anywhere in its own source. All inference is delegated to the
third-party `audio-separator` PyPI package:

- `scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/separator.py` and
  `scripts/reaper/_internal/stemwerk_drumsep_process.py` only *configure* the
  `Separator` instance (`separator.onnx_execution_provider = [...]`, `torch_device`);
  they never call `InferenceSession` directly.
- Only `CPUExecutionProvider` and `DmlExecutionProvider` strings appear anywhere in
  STEMwerk source. On Linux, the CUDA/ROCm GPU path goes through PyTorch
  (`torch.cuda`/HIP) plus `onnx2torch` graph conversion, not an onnxruntime GPU EP —
  MDXC/Roformer models in particular are `.ckpt` files run entirely via PyTorch.
- No WebGPU reference of any kind exists in STEMwerk source.
- **Correction to the original brief's candidate list**: `UVR_MDXNET_KARA_2` is
  confirmed as a real ONNX model (`UVR_MDXNET_KARA_2.onnx`, MDX-Net family, run via
  onnxruntime). `MDX23C-8KFFT-InstVoc_HQ` is **not** ONNX — it is
  `MDX23C-8KFFT-InstVoc_HQ.ckpt` (PyTorch checkpoint). `UVR_MDXNET_KARA_2.onnx` was
  used throughout both phases.

### 2a. The full MDX-Net audio pipeline, traced (new in L2)

Full call path for `Separator.separate(input_wav)` on an MDX model
(`audio_separator/separator/architectures/mdx_separator.py` +
`audio_separator/separator/common_separator.py` +
`audio_separator/separator/uvr_lib_v5/stft.py`, package version `0.47.0`):

1. **`prepare_mix()`** (`common_separator.py:248`) — loads the file via
   `librosa.load(mix, mono=False, sr=self.sample_rate)` (resamples to the target rate,
   here 44100 Hz), captures the input's bit depth/subtype via `soundfile.info()`,
   validates it's non-empty and finite, converts mono→stereo if needed
   (`np.asfortranarray([mix, mix])`).
2. **Normalization** (`mdx_separator.py:167-169`) — `spec_utils.normalize(wave=mix,
   max_peak=self.normalization_threshold, ...)`, default `normalization_threshold=0.9`.
3. **`demix()`** (`mdx_separator.py:306`) — chunks the (padded) mix using
   `chunk_size = hop_length * (segment_size - 1)` with Hann-window overlap-add
   (`overlap=0.25` by default for the primary pass, a separate `overlap=0.02` pass for
   the "match_mix" secondary-stem estimate), accumulating results into `result`/
   `divider` arrays that are divided at the end to undo the window overlap.
4. **Per chunk, `run_model()`** (`mdx_separator.py:427`):
   a. **STFT** — `STFT.__call__` (`uvr_lib_v5/stft.py:22`): `torch.stft(..., n_fft,
      hop_length, window=hann_window, center=True)`, reshapes real/imag into the
      channel dimension (stereo × real/imag = 4 channels), crops to `dim_f` frequency
      bins. **Runs on `torch_device`** — plain PyTorch, not onnxruntime.
   b. Zeroes the first 3 frequency bins (low-frequency noise suppression).
   c. **`self.model_run(spek)`** — **the only ONNX Runtime call in the whole
      pipeline**, `lambda spek: ort_inference_session.run(None, {"input":
      spek.cpu().numpy()})[0]`, set up in `load_model()` (`mdx_separator.py:123`).
      For `UVR_MDXNET_KARA_2.onnx`: input/output tensor shape
      `[batch_size, 4, 2048, 256]` (verified via `onnx.checker` in this experiment).
   d. **Inverse STFT** — `STFT.inverse()` (`uvr_lib_v5/stft.py:101`):
      `torch.istft(..., center=True)`, also on `torch_device`.
5. **`final_process()`** (`common_separator.py:196`) — calls `write_audio()`
   (pydub/ffmpeg by default, or `soundfile` if `use_soundfile=True`) for each stem.

**Injection point, confirmed**: `self.model_run` (step 4c) is the *only* place to swap
in a different onnxruntime provider. `torch_device` (steps 4a/4d) is a **separate,
independent** setting — on this machine, this venv's plain PyPI `torch` has no
CUDA/ROCm build, so `torch_device` is CPU in every run regardless of the ONNX
execution provider chosen. **This means STFT/windowing/chunking/overlap-add is
byte-identical between the CPU-EP and WebGPU-EP runs in this experiment** — only the
neural-net inference call differs, which is exactly the controlled comparison §5/§6
need. audio-separator's own provider-selection code was **not** modified on disk;
`experiments/webgpu-ep/webgpu_adapter.py` reuses it unchanged and only monkeypatches
`onnxruntime.InferenceSession` at the Python level (see §3).

## 3. Native WebGPU EP — what actually exists (2026-09-19)

Two distribution routes exist on PyPI for Linux x86-64:

1. **`onnxruntime` + `onnxruntime-ep-webgpu`** (plugin-EP architecture, the officially
   documented route — <https://onnxruntime.ai/docs/execution-providers/WebGPU-ExecutionProvider.html>).
   Requires base `onnxruntime>=1.24.4`. `onnxruntime-ep-webgpu` 0.3.0 ships a
   `manylinux_2_28_x86_64` wheel (Python ≥3.11) containing a standalone
   `libonnxruntime_providers_webgpu.so`, registered at runtime via
   `ort.register_execution_provider_library(...)`. **This is the route used here.**
2. **`onnxruntime-webgpu`** 1.27.0 — a monolithic alternative build with WebGPU baked
   in. Not used; noted as a fallback worth trying if the plugin route regresses.

On Linux, Dawn (Google's WebGPU implementation) dispatches through **Vulkan**. A system
Vulkan loader (`libvulkan.so.1`) is required — already present (part of the existing
Mesa/RADV stack) — **no system packages, drivers, or kernel changes were needed or
made, in either phase.**

System stack (read-only, unmodified):
- GPU: AMD Radeon RX 9070 (Navi 48, RDNA4 / gfx1201), PCI `0000:03:00.0`, plus a
  Phoenix1 iGPU at `0000:69:00.0` (must be explicitly excluded by PCI bus id).
- Driver: Mesa 26.2.2 (RADV), Vulkan instance 1.4.357, kernel 6.18.52-lts, EndeavourOS
  (rolling). ROCm 7.2.3 also installed system-wide (used read-only for §6's ROCm venv).
- `vulkaninfo` reports RADV's own disclaimer: *"radv is not a conformant Vulkan
  implementation, testing use only."* Standard Mesa self-declared conformance-suite
  status, not a fault of this experiment — WebGPU EP functioned correctly regardless
  (see §5) — but understand this before making GPU-vendor-parity claims from Linux/RADV
  testing specifically.

**Multi-GPU caveat (undocumented pitfall, worth flagging upstream):**
`ort.get_ep_devices()` enumerates *all* WebGPU-capable adapters; nothing defaults to
the discrete one. Must select explicitly, e.g. by `device.metadata['pci_bus_id']`
(confirmed against `lspci`) or `device.device_id` (`30032`/`0x7550` = RX 9070 vs
`5567`/`0x15BF` = Phoenix iGPU). `webgpu_adapter.select_device()` (§3 below, code)
**raises** rather than guesses when more than one device exists and no selector is
given — verified with a negative test (see §7).

**Confirmed incompatibility with audio-separator's own provider selection API:**
`MDXSeparator.load_model()` creates its session with the classic
`ort.InferenceSession(path, providers=self.onnx_execution_provider, ...)` call.
Passing `["WebGpuExecutionProvider"]` through this **legacy string-list API does NOT
activate the plugin EP** — it silently falls back to `CPUExecutionProvider`
(audio-separator does emit a warning, but the wording incorrectly blames "CUDA/cuDNN").
The plugin-EP architecture requires the newer device-targeted
`SessionOptions.add_provider_for_devices([...], {})` call. This is exactly the
"looks like GPU, silently runs on CPU" trap flagged in
[microsoft/onnxruntime#22077](https://github.com/microsoft/onnxruntime/issues/22077).
`webgpu_adapter.py` (new in L2, superseding L1's inline monkeypatch) works around it.

## `webgpu_adapter.py` — the reusable adapter (new in L2)

A small, tested module, not tied to any one script:

- `ensure_webgpu_library_registered()` / `list_webgpu_devices()` — registration +
  enumeration.
- `select_device(pci_bus_id=..., device_id=...)` — explicit device selection;
  **raises `GpuExecutionNotProvenError`** if the requested device doesn't exist, or if
  more than one WebGPU device exists and no selector was given (no silent guessing).
  The Linux/PCI-bus-id logic is isolated in this one function — see §8 for the macOS
  port note.
- `create_verified_webgpu_session(model_path, device)` — standalone session
  construction with **real proof**: redirects the process's actual stderr file
  descriptor (not Python `logging` — onnxruntime's C++ core writes verbose logs
  directly to the OS-level fd, bypassing `logging` entirely) into a temp file for the
  duration of session creation, parses the `"All nodes placed on [...]"` line, and
  raises `GpuExecutionNotProvenError` if that line is missing, or names a different EP,
  or if `WebGpuExecutionProvider` isn't even in `session.get_providers()`. Returns a
  `report` dict with the raw counts and any fallback-hint log lines, so a caller can
  inspect further rather than trust a boolean.
- `patch_inference_session_for_provider_swap(target_device_selector)` — the
  monkeypatch used by the end-to-end scripts: any `providers=["WebGpuExecutionProvider"]`
  request is transparently routed through the verified path above; every other
  provider request (`CPUExecutionProvider`, etc.) passes straight through to the real,
  original `onnxruntime.InferenceSession` unmodified. Returns the original class (for
  restoration) and a `reports` list that accumulates one verified-placement report per
  WebGPU session actually created during the patched period — used to assert
  "exactly one session was created and reused across every chunk/run", not just "the
  first one looked fine" (§7).

Validated with both positive and negative tests before use in the real pipeline
(nonexistent device correctly refused; ambiguous multi-GPU selection correctly
refused; CPU-provider requests confirmed to pass through untouched; a real WebGPU
session confirmed end to end with the real 185-node model). See git history on this
branch for the exact commands.

## Phase L1 summary — inference-only proof (unchanged, kept for the record)

A single ONNX Runtime session (no real audio pipeline) with `UVR_MDXNET_KARA_2.onnx`:

| Checkpoint | Result |
|---|---|
| EP beschikbaar | **PASS** |
| EP initialisatie geslaagd | **PASS** |
| Model geladen | **PASS** |
| GPU-inferentie aangetoond | **PASS** — 185/185 nodes on WebGPU |
| Numerieke output gevalideerd | **PASS** — corr ≈ 1.0 vs CPU, but see §5 below: this
  comparison was file-based (WAV), and turned out to be dominated by PCM_16 export
  quantization, not a measurement of raw inference difference. Superseded by §5. |

## Phase L2 — full pipeline

### 4. Real end-to-end audio test

`end_to_end_pipeline_test.py`: runs the complete `audio-separator` pipeline (§2a) on a
real 20 s / 44.1 kHz / stereo WAV (an existing local smoke-test artifact, not committed
— substitute your own, see "Reproducing"), once with `CPUExecutionProvider`, once with
the verified `WebGpuExecutionProvider`, via `webgpu_adapter.py`.

| Check | Result |
|---|---|
| WebGPU graph execution | **PASS** — `"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185"`, verified via real stderr-fd log capture (not just `get_providers()`) |
| CPU fallback detection | **PASS** — 0 fallback nodes; the adapter's negative-path tests (nonexistent device, ambiguous multi-GPU, ordinary `CPUExecutionProvider` pass-through) all behaved correctly |
| End-to-end audio | **PASS** — both providers produced 2 stems each, no crash, no incomplete export |
| Output validation | **PASS** for both providers on: correct stem count (2), sample rate (44100), channel count (2), duration match (20.00s, within 0.05s tolerance), no NaN/Inf, no unexpected silence (RMS 0.11/0.03 for Vocals/Instrumental, both ≫ the 1e-6 silence floor), no clipping (peak 0.164/0.041, both ≪ the 0.999 ceiling) |
| Stem routing | **PASS** — cross-correlation check: CPU-Vocals ↔ GPU-Vocals corr=1.000000 vs CPU-Vocals ↔ GPU-Instrumental corr=0.998906 (and symmetrically for Instrumental) — same-stem correlation is higher, confirming no vocals↔instrumental swap between the two runs. (Note: both correlations are high because Vocals/Instrumental are complementary decompositions of the same mix, not because routing is ambiguous — the *difference* between them, not their absolute value, is what proves correct routing.) |

"A complete WAV export without demonstrable WebGPU execution is not a WebGPU PASS" —
enforced structurally: `end_to_end_pipeline_test.py` calls
`GpuExecutionNotProvenError` on any placement anomaly and exits with a non-zero code;
it does not just print a warning.

### 5. Numerical and audio comparison — two comparisons, kept explicitly separate

**Why two comparisons.** Phase L1's file-based numeric "PASS" (max abs diff 3.05e-5)
turned out to equal **exactly one PCM_16 quantization step** (`1/32767 = 3.0518e-5`).
`audio-separator`'s default `write_audio()` path (pydub/ffmpeg) force-converts to
`int16` before export regardless of source bit depth. That 3.05e-5 was measuring the
WAV export's quantization floor, not a CPU-vs-WebGPU inference difference — it would
appear even comparing a provider against itself, run to run. The brief explicitly warns
against exactly this conflation ("Gebruik geen correlatie als enige kwaliteitsmaatstaf"
/ "Maak onderscheid tussen model-inferentieverschillen en... audiobewerking"), so L2
captures the **raw model output** (via a temporary patch of `CommonSeparator.
final_process`, the one place that receives the unexported float array — see
`end_to_end_pipeline_test.py`) *in addition to* the exported file, and reports both.

**Pre-declared tolerances** (declared and motivated in `end_to_end_pipeline_test.py`
*before* running, not fitted after the fact):
- **Raw (pre-export float)**: `correlation ≥ 0.999`, `max_abs_diff ≤ 5e-3`. Rationale:
  CPU (MLAS) and WebGPU (Dawn/Vulkan shaders) use different kernel implementations and
  floating-point accumulation order for the same Conv/MatMul math; float32 is not
  bit-reproducible across backends even for identical math, so some difference is
  structurally expected, not a bug. 5e-3 is a generous ceiling relative to typical
  signal peaks here (~0.1–0.2) — a tight, not a loose, standard.
- **File (exported WAV)**: `correlation ≥ 0.999`, `max_abs_diff ≤ 1.5e-4` (≈5× one
  PCM_16 LSB). Rationale: dominated by quantization, not inference; allows a small
  margin above the theoretical 1-LSB floor for normal rounding-boundary cases.

**Actual measured results** (`end_to_end_pipeline_test.py`, full run, exit code 0):

| Comparison | Stem | Correlation | Max abs diff | MAE | RMS diff % |
|---|---|---|---|---|---|
| Raw (pre-export) | Vocals | 1.00000000 | **7.08e-08** | 9.35e-09 | 0.0000% |
| Raw (pre-export) | Instrumental | 1.00000000 | **6.61e-08** | 8.79e-09 | 0.0000% |
| File (exported WAV) | Vocals | 1.00000000 | 3.05e-05 (**1.00× PCM16 LSB**) | 9.76e-09 | 0.0000% |
| File (exported WAV) | Instrumental | 1.00000000 | 3.05e-05 (**1.00× PCM16 LSB**) | 9.31e-09 | 0.0000% |

Both comparisons pass their pre-declared tolerance by a wide margin. The raw comparison
(7e-8) is ~430× smaller than the file comparison (3e-5), confirming the file-level
number really was almost entirely export quantization, and that the *true* CPU-vs-
WebGPU inference difference is close to float32 noise-floor — about as good an outcome
as is physically possible for two different compute backends.

### 6. Benchmark

Same ONNX model, same audio, same `audio-separator` pre/post-processing (§2a) across
all three backends below — a genuine same-graph backend comparison, not a comparison
of different STEMwerk pipelines.

`benchmark_resources.py` (CPU vs WebGPU, main venv, 4 runs) +
`rocm_reference_benchmark.py` (ROCm, separate `.venv-rocmref`, 4 runs) +
`resource_sampler.py` (shared RAM/VRAM/GPU-util sampler, both venvs).

| Metric | CPU EP | WebGPU EP (RX 9070) | ROCm EP (RX 9070) |
|---|---|---|---|
| Session/model load | 0.87 s | 0.11 s | 0.06 s |
| First ("cold") run | 9.03 s | 1.42 s | 4.66 s¹ |
| Warm runs (3 repeats), min–max | 8.09–8.74 s | 1.41–1.43 s | 1.12–1.14 s |
| Warm median | 8.13 s | 1.41 s | 1.13 s |
| Warm stdev | 0.362 s | 0.007 s | 0.011 s |
| Real-time factor (20s clip, warm) | 2.5× | 14.1× | 17.7× |
| Speedup vs CPU (warm median) | 1.0× (ref) | **5.75×** | **7.19×** |
| Graph placement | 100% CPU (by definition) | **185/185 nodes on GPU, 0 fallback** | **139/139 nodes on GPU, 0 fallback** |
| Raw-output correlation vs CPU | reference | 1.00000000 (§5) | 1.00000000 |
| Raw-output max abs diff vs CPU | reference | 7.08e-08 / 6.61e-08 | 4.47e-08 / 4.10e-08 |

¹ ROCm's *very first ever* invocation on this machine took 21.6 s — MIOpen (ROCm's
kernel library) autotunes and disk-caches convolution kernel implementations on first
use per shape/hardware combination; every run after that (including this table's
"cold" figure, from a second fresh process) benefits from that persistent cache and
drops to ~4.7 s. This is a one-time, machine-local cost, not a per-run cost, and not
something either onnxruntime provider directly controls.

**GPU-fallback / graph-placement re-verification (§7 of the brief, repeated inside the
real pipeline, not just Phase L1's synthetic probe):** `benchmark_resources.py` asserts
`len(gpu_reports) == 1` after all 4 WebGPU `separate()` calls — i.e. exactly **one**
`InferenceSession` was constructed for the whole benchmark (in `load_model()`) and
**reused, unchanged, across all 4 runs and all 11 audio chunks per run** (6 chunks for
the primary pass + 5 for the match-mix secondary-stem pass, per the `tqdm` progress
bars in the raw log) — i.e. every chunk provably followed the same, single, verified
GPU session; nothing silently created a second, unverified session partway through. Ran
and passed; script exits non-zero if this assertion ever fails.

**RAM/VRAM/GPU-utilization measurement reliability — reported honestly, not as a clean
PASS:**

| Metric | CPU EP | WebGPU EP | ROCm EP |
|---|---|---|---|
| Peak process RSS | 2985 MB | 1549 MB | 2099 MB |
| Peak VRAM, "attributable delta" (best-effort) | **1863 MB** ⚠️ | 1527 MB | 2233 MB (first run only; ~0 MB thereafter) |
| Avg whole-GPU utilization | 6.1% | 47.3% | ~40–75% |

⚠️ **The CPU EP's 1863 MB "VRAM delta" is a measurement artifact, not real GPU memory
used by a CPU-only process, and is reported specifically to demonstrate why this number
is unreliable rather than to claim CPU inference touches the GPU.** `rocm-smi` reports
*whole-GPU* memory (desktop compositor + any other GPU client), not per-process; on
this desktop machine that background usage fluctuates by more than the actual signal
we're trying to measure. The ROCm numbers look more plausible (a real ~2.2 GB jump on
the very first run when buffers/workspace are first allocated, then ~0 MB delta on
warm runs once already allocated) but are still whole-GPU, not validated per-process
peaks. **Conclusion: VRAM/GPU-utilization figures above are informational only, not a
rigorous PASS** — no per-process VRAM accounting tool for this AMD/Linux stack was
available without installing something system-wide, which was out of scope. RSS
(process RAM) readings are the one metric here that's genuinely per-process and
reliable.

### 6a. ROCm reference — is it a fair comparison?

**Yes, for this specific test** — unlike STEMwerk's actual production ROCm path (which
the §2 architecture trace confirms goes through PyTorch/`onnx2torch`, not onnxruntime,
for MDXC/Roformer models), this experiment ran the exact same `UVR_MDXNET_KARA_2.onnx`
graph through `ROCMExecutionProvider` directly, confirmed via the same log-capture
verification standard as WebGPU (§3 adapter). So §6's CPU/WebGPU/ROCm table is a
genuine same-model, same-graph, same-pipeline backend comparison, not the "broader
pipeline reference" fallback the brief allows — no time was spent converting any model
just to produce this number; `onnxruntime-rocm` already ships a working, verified ROCm
EP for this exact ONNX file.

### 7. macOS M1 readiness

**Superseded — see "Phase M1: native macOS Metal validation" below.** Actual execution
on a physical M1 has now occurred and is reported there, per the brief's instruction not
to report a Metal PASS without running on the actual hardware. This section is kept
for historical context (what was predicted before that run, and how close the
prediction was).

What's ready:
- `webgpu_adapter.select_device()` isolates the one genuinely Linux/Vulkan-specific
  piece (PCI-bus-id device matching) behind a single function. A macOS variant needs a
  different match key — Apple Silicon's integrated GPU has no `pci_bus_id` metadata
  under Dawn/Metal, and there's only one GPU to pick, so the macOS version is likely
  *simpler* (no multi-GPU disambiguation needed), not harder.
- `onnxruntime-ep-webgpu` 0.3.0 ships a `macosx_14_0_universal2` wheel — the install
  step (`pip install "onnxruntime>=1.24.4" onnxruntime-ep-webgpu`) should carry over
  unchanged.
- `resource_sampler.py`'s `rocm-smi` calls already fail closed to `reliable: False`
  (via a blanket `except Exception`, including `FileNotFoundError` when the binary
  doesn't exist) rather than crashing — confirmed this degrades gracefully without any
  macOS-specific code path having been written yet. A real macOS pass would want an
  `ioreg`/`powermetrics`-based equivalent for GPU/memory stats instead, but the script
  will run and simply report "not reliable" without one.
- `end_to_end_pipeline_test.py`, `benchmark_resources.py`, and the numeric-comparison
  logic are already platform-generic Python/numpy/soundfile/torch — no known
  Linux-specific assumptions beyond device selection.

What's still missing before a real M1 run: the M1 has 8 GB unified memory shared
between CPU and GPU — this experiment's peak RSS alone was up to ~3 GB on a 20 s clip
on a 16 GB discrete-GPU desktop; whether the full PyTorch + audio-separator dependency
stack plus a WebGPU/Metal session fits comfortably in 8 GB unified memory is genuinely
unknown and should be the first thing checked on the M1, before any performance claim.

## 8. Scope discipline

No production venv, installer pin, model registry, GPU resolver, release branch, or
REAPER UI file was modified, in either phase. No CUDA/ROCm/DirectML/MPS code was
touched or removed. No new dependency was added to the existing STEMwerk distribution —
`onnxruntime-ep-webgpu`, `onnxruntime-rocm`, `audio-separator`, etc. exist only inside
the two isolated venvs listed in §1. `/opt/rocm` (system-wide, pre-existing) was read
from, never modified, and no `rocm-smi`/driver/kernel configuration was changed to
make measurement possible — where a reliable measurement wasn't achievable without
such a change, it's reported as unreliable instead (§6). Nothing was pushed, merged, or
opened as a PR in either phase.

## 9. Open issues / upstream limitations

- Operator coverage beyond what this one model exercises (Conv2d family, BatchNorm,
  MatMul, Transpose, STFT-adjacent elementwise ops) is unverified for WebGPU — the
  upstream GitHub issue reports CPU fallback for Reshape/Gather/Concat/Slice/Where/Equal
  in *other* models; those ops didn't appear as separate graph nodes in this model's
  exported graph (likely fused away), so this PASS should **not** be generalized to
  every MDX/MDXC/VR-Arch model in STEMwerk's catalog without testing each individually.
- MDXC/Roformer models (`.ckpt`, PyTorch/onnx2torch path) remain entirely outside
  either EP's scope as currently used by `audio-separator`.
- `audio-separator`'s own provider-selection code still cannot activate a plugin EP
  without the adapter's patch — worth raising upstream.
- Mesa RADV self-reports as non-Khronos-conformant; results here should not be read as
  proof of behavior on a conformant Vulkan/Dawn stack.
- VRAM/GPU-utilization measurement is not per-process reliable on this stack without
  further tooling (§6) — flagged, not silently reported as clean numbers.
- ROCm's first-ever-run MIOpen autotuning cost (21.6 s here) is a one-time,
  machine/shape-specific artifact worth knowing about before reading any ROCm cold-start
  benchmark number at face value.

## 10. Deliverables summary

| Onderdeel | Status |
|---|---|
| WebGPU graph execution | **PASS** (185/185 nodes, log-verified) |
| CPU fallback detection | **PASS** (0 fallback nodes; adapter negative-tests pass) |
| End-to-end audio | **PASS** (both providers, no crash, complete export) |
| Stem routing | **PASS** (cross-correlation same-stem > other-stem for both stems) |
| Numerical validation | **PASS** (raw: corr 1.0, max diff 7.08e-08; file: corr 1.0, max diff 1 PCM16 LSB — both within pre-declared tolerance) |
| CPU benchmark | **PASS** (warm median 8.13 s, stdev 0.362 s, 4 runs) |
| WebGPU benchmark | **PASS** (warm median 1.41 s, stdev 0.007 s, 4 runs, 5.75× vs CPU) |
| ROCm comparison | **PASS** — genuine same-graph comparison (139/139 nodes, warm median 1.13 s, 7.19× vs CPU) |
| RAM/VRAM measurements | **RSS: PASS** (per-process, reliable) / **VRAM & GPU-util: BLOCKED** (whole-GPU only, not per-process attributable without more tooling — reported with explicit reliability caveats, not as clean numbers) |
| macOS readiness | See "Phase M1: native macOS Metal validation" below — actual M1 execution now done |

### Branch / commits / files (this update)

- Branch: `experiment/webgpu-ep`, HEAD before this update: `dbfeab59f`.
- New files added in this update (all under `experiments/webgpu-ep/`):
  `webgpu_adapter.py`, `end_to_end_pipeline_test.py`, `benchmark_resources.py`,
  `resource_sampler.py`, `rocm_reference_benchmark.py`. `README.md` rewritten in
  place; `requirements-webgpu-experiment.txt` and `.gitignore` unchanged from L1.
- Exact test commands used (all from `experiments/webgpu-ep/`, with the respective
  venv activated):
  ```bash
  # main venv (/home/flark/stemwerk-rnd/venvs/webgpu-ep/.venv-webgpu)
  python end_to_end_pipeline_test.py <input.wav> --model-cache <cache-dir> --out-dir <dir>
  python benchmark_resources.py <input.wav> --model-cache <cache-dir> --out-dir <dir> --runs 4

  # separate ROCm-reference venv (/home/flark/stemwerk-rnd/venvs/webgpu-ep-rocmref/.venv-rocmref)
  python rocm_reference_benchmark.py <input.wav> --model-cache <cache-dir> --out-dir <dir> --runs 4
  ```
- Test results: see §4, §5, §6, §10 above; raw JSON reports are written by each script
  (`e2e_report.json`, `resource_benchmark.json`, `rocm_result.json`) but not committed
  (machine-specific, regenerable, gitignored via the existing `*.wav`/output-dir rules
  — extend `.gitignore` if you keep JSON reports locally alongside the scripts).
- Concrete technical limitations: see §9.
- What's missing for macOS M1: see §7 (mainly: actual hardware execution, and an 8 GB
  unified-memory feasibility check before any perf claim).

## Phase M1: native macOS Metal validation

Status date: 2026-09-19. **These are macOS/Apple Silicon results, on different hardware,
a different input clip, and a different CPU/GPU/memory architecture than Phase L1/L2's
Linux/AMD RX 9070 results above — they are not directly comparable as absolute numbers
and must not be read as a cross-platform speed ranking.** Same shared codebase, same
branch, same ONNX model, same `audio-separator` pipeline.

### M1.1 Hardware and environment

- Machine: MacBook Air (MacBookAir10,1), Apple M1, **8 GB unified memory** (shared
  CPU+GPU, not separate VRAM — see M1.6).
- macOS 26.7 (build 25G229), native arm64 throughout — **no Rosetta/x86_64 anywhere**.
- Python: the existing STEMwerk-managed Python 3.12.13 (arm64, already installed at
  `~/Library/Application Support/STEMwerk/python/`, read-only — used only as the
  interpreter to create a brand-new, fully separate venv; never modified). Homebrew's
  only `python3` on this machine is 3.14, too new for reliable ARM64 wheel coverage
  across this dependency set at the time of testing — the managed 3.12.13 was used
  instead, consistent with "avoid improvising with an incompatible build."
- Venv: `/Users/flark/stemwerk-m1-validation/venvs/webgpu-ep/` (outside git, outside
  any STEMwerk production venv, local APFS).
- Repo: canonical checkout `/Users/flark/GIT/STEMwerk` untouched; worktree
  `/Users/flark/stemwerk-m1-validation/worktrees/webgpu-ep`, branch `experiment/webgpu-ep`
  checked out from `origin/experiment/webgpu-ep` (HEAD `ae75db926`, the documented L2
  commit) — same branch, no new branch, existing history preserved and confirmed present
  (`dbfeab5` L1 + `ae75db9` L2 both verified as ancestors before any work started). All
  other existing M1 STEMwerk worktrees (standalone, core, other STEMwerk checkouts)
  confirmed untouched.

### M1.2 Dependency install

`pip install -r requirements-webgpu-experiment.txt` into the fresh venv: **every package
resolved to a native `macosx_*_arm64`/`universal2` wheel** — `onnxruntime-ep-webgpu==0.3.0`,
`onnxruntime==1.30.0`, `torch==2.14.0`, all of it. No source compilation needed except a
small Cython extension (`diffq`, unrelated to this experiment's actual code path, pulled
in transitively by `audio-separator`), which built natively without issue. **This alone
already resolves the biggest open unknown**: the README's own §3 prediction of a
`macosx_14_0_universal2` wheel for `onnxruntime-ep-webgpu` was correct, and no
ARM64-compatibility blocker was hit.

One real gap found and fixed: `audioread` (imported by
`audio_separator.separator.uvr_lib_v5.spec_utils`) was **not** pulled in automatically by
pip's resolver on this install, causing an immediate `ModuleNotFoundError` on the very
first `import audio_separator`. Pinned explicitly in `requirements-webgpu-experiment.txt`
(`audioread==3.1.0`) — a plain missing transitive dependency, not a platform-specific
workaround, so this fix applies to both platforms' requirements file equally.

### M1.3 WebGPU EP availability and device selection — zero code changes needed

```
EP beschikbaar: True (1 GPU device(s) found)
  - vendor_id=4203 device_id=0 metadata={}
```

`vendor_id=4203` = `0x106B` = Apple Inc.'s registered PCI vendor id. Exactly **one**
WebGPU-capable device, with **no `pci_bus_id` metadata at all** (as the README's own §3
macOS port note predicted) — `webgpu_adapter.select_device()`'s existing "auto-pick the
only device when none is given" branch handled this with **zero changes to
`webgpu_adapter.py` itself**. The only device-selection code that needed touching was two
scripts' CLI *default value*, not the shared adapter (§M1.7).

### M1.4 Metal backend proof (objective, binary-level)

The brief requires more than "WebGPU EP works" — it requires evidence the backend
actually dispatching is Metal specifically. Two independent, verifiable proofs, not just
an assumption:

1. **Binary linkage**: `otool -L` on the installed
   `libonnxruntime_providers_webgpu.dylib` shows exactly one linked framework:
   `/System/Library/Frameworks/Metal.framework` — no Vulkan/MoltenVK library linked at
   all. This `.dylib` architecturally *cannot* dispatch through anything but Metal on
   this machine.
2. **Embedded Dawn source paths**: `strings` on the same binary contains compiled-in
   debug paths from Dawn's own Metal backend implementation
   (`dawn-src/src/dawn/native/metal/DeviceMTL.mm`, `ComputePipelineMTL.mm`,
   `ShaderModuleMTL.mm`, etc.) — the actual backend code that shipped in this build.
3. (Runtime, weaker on its own but corroborating) onnxruntime's verbose C++ log during
   a real session shows Dawn's `webgpu_context.cc` dispatching real named GPU programs
   (`"Conv2dMM[...]"`, `"Transpose[...]"`, `"BatchNormalization[...]"`, `"MatMul[...]"`
   — real MDX-Net UNet op names, not synthetic).

**Metal-backend bewezen: PASS**, on binary/architectural evidence, not inference from
"WebGPU probably means Metal on macOS."

### M1.5 L1-equivalent probe (`webgpu_ep_probe.py`)

Real run, unmodified conv-op test model, **PASS on every checkpoint**:

| Checkpoint | Result |
|---|---|
| EP beschikbaar | **PASS** — 1 device found |
| EP initialisatie geslaagd | **PASS** |
| GPU-inferentie aangetoond | **PASS** — `"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 3"`, verified via the same stderr-fd log-capture standard as Linux (not just `get_providers()`) |
| Numeriek gevalideerd | **PASS** — `max_abs_diff=1.91e-06 correlation=1.0000000000` vs CPU EP |

### M1.6 L2-equivalent: full end-to-end audio pipeline (`end_to_end_pipeline_test.py`)

**Input differs from Linux, documented explicitly per the brief's own allowance**: Linux
L2 used a 20 s clip that was never committed to git (not reproducible from this repo).
macOS M1 used an existing real 6.00 s / 44.1 kHz / stereo / PCM16 clip already present on
this machine from prior STEMwerk validation work
(`stemwerk-m1-validation/evidence/audio/m1a-test-clip-6s.wav`) — one single controlled
file, used identically for both the CPU and WebGPU runs below, so the CPU-vs-WebGPU
comparison *within* this table is still apples-to-apples; only the absolute Linux-vs-macOS
numbers are not.

Model: `UVR_MDXNET_KARA_2.onnx`, not present in the local STEMwerk model cache — fetched
fresh by `audio-separator`'s own model catalog/download mechanism (the same "existing
reliable model source" the Linux phases used) into an isolated cache dir outside git and
outside the production STEMwerk model cache. No manual file copying between machines.

| Check | Result |
|---|---|
| WebGPU graph execution | **PASS** — `"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185"` — **identical node count to Linux** (same model, same graph, confirms the plugin-EP graph placement is hardware-independent for this model) |
| CPU fallback detection | **PASS** — 0 fallback nodes |
| End-to-end audio | **PASS** — both providers produced 2 stems (Vocals, Instrumental) each, no crash, complete export |
| Output validation | **PASS** for both providers: sr=44100, ch=2, duration=6.00s, no NaN/Inf, no silence, no clipping |
| Stem routing | **PASS** — same-stem corr ≈ 1.000000 vs other-stem corr ≈ 0.917 for both stems (cf. Linux's 0.999) |
| Raw (pre-export) numeric comparison | **PASS** — Vocals: corr=1.00000000, max_abs_diff=**3.58e-07**; Instrumental: corr=1.00000000, max_abs_diff=**3.28e-07** — same order of magnitude as Linux's 7.08e-08/6.61e-08, both far inside the pre-declared 5e-3 ceiling |
| File (exported WAV) numeric comparison | **PASS** — both stems: max_abs_diff=3.05e-05 = **exactly 1.00× PCM16 LSB**, identical pattern to Linux |

Both comparisons pass their pre-declared tolerance by a wide margin, same as Linux;
CPU-vs-WebGPU inference difference is again close to the float32 noise floor.

### M1.7 Benchmark (`benchmark_resources.py`, 4 runs)

**A real correctness bug was found and fixed while running this**: the script's
real-time-factor line was hardcoded to `20.0` (seconds) — correct by coincidence for
Linux's actual 20 s clip, silently wrong for any other input duration. Fixed to read the
real input file's duration via `soundfile.info(...).duration`; this is a platform-generic
correctness fix (§9), not a macOS-specific change, and benefits any future Linux run with
a differently-sized clip too.

| Metric | CPU EP | WebGPU EP (Apple M1) |
|---|---|---|
| Session/model load | 0.98 s | 0.10 s |
| First ("cold") run | 7.87 s | 4.39 s |
| Warm runs (3 repeats), min–max | 6.72–7.18 s | 4.08–4.12 s |
| Warm median | 6.90 s | 4.11 s |
| Warm stdev | 0.229 s | 0.023 s |
| Real-time factor (6.00 s clip, warm) | 0.9× (sub-real-time) | 1.5× |
| Speedup vs CPU (warm median) | 1.0× (ref) | **1.68×** |
| Graph placement | 100% CPU (by definition) | **185/185 nodes on GPU, 0 fallback** |

**This 1.68× speedup is real but modest compared to Linux's 5.75× (WebGPU) — read this
as an M1-vs-RX-9070 hardware-and-clip-length comparison, not as evidence WebGPU EP
"works less well" on Metal.** Plausible, undistinguished-in-this-experiment contributing
factors: (a) discrete RX 9070 vs. M1's unified/lower-power GPU is a large raw-throughput
gap in general; (b) the 6 s clip is short enough that fixed per-call overhead (STFT/iSTFT
setup, Python/audio-separator dispatch overhead) is a much larger fraction of total time
than on a 20 s clip, compressing the ratio between backends. No attempt was made here to
separate these factors quantitatively — flagged as a genuine open question, not resolved.

**RSS (process memory), reliable, macOS-specific implementation** — `resource_sampler.py`
had no macOS RSS reader at all (`/proc/self/status` doesn't exist on macOS); added a
`sys.platform == "darwin"` branch using `resource.getrusage(RUSAGE_SELF).ru_maxrss`
(Linux path byte-for-byte unchanged). **Honesty caveat specific to this
implementation**: unlike the Linux `/proc`-based reader (an instantaneous point-in-time
reading, repeatedly sampled), `ru_maxrss` is the process's **peak-ever-reached** RSS,
monotonically non-decreasing for the process's whole lifetime. Since both the CPU and
WebGPU benchmark phases ran in the same process, the WebGPU phase's reported
`peak_rss_mb` can never be *lower* than the CPU phase's — in this run both read exactly
**1440.75 MB**, meaning the process-wide peak was reached during (or by the end of) the
CPU phase and the WebGPU phase never exceeded it. This is a correct "peak RSS touched by
the process up to this point" reading, but it is **not** a clean per-phase-isolated peak
the way the Linux reader can approximate one — read the two phases' numbers as a shared
running maximum, not as two independent measurements.

VRAM / whole-GPU utilization: **BLOCKED**, exactly as predicted in the original §7 — no
`rocm-smi` equivalent exists on macOS, `_rocm_smi_json()`'s existing blanket
`except Exception` already degrades this to `"reliable": false` with an honest note,
with zero macOS-specific code required. No `ioreg`/`powermetrics`-based replacement was
implemented (`powermetrics` needs elevated privileges to read GPU counters — out of
scope for this experiment's "no system changes" constraint) — reported as an honest gap,
not silently as zero or omitted.

### M1.8 Memory pressure and swap — real pressure observed, no OOM

The M1's 8 GB unified memory is shared between the OS, every other running app, and this
experiment — unlike Phase L2's 16 GB *discrete-GPU-plus-separate-system-RAM* desktop.
Measured with `memory_pressure`/`vm_stat`/`sysctl vm.swapusage` before and after the full
benchmark run (this machine had other normal background load throughout, not a clean
dedicated test box):

| | Before | After |
|---|---|---|
| System-wide free memory | 37% | 71%¹ |
| Swap file size | 2048 MB | 4096 MB |
| Swap used | 988 MB | ~3300–3400 MB |

¹ Higher *after* than *before* only because the benchmark's own process had exited and
its memory was reclaimed by the time this was sampled — not evidence the run itself was
memory-light. **The swap file itself grew (macOS dynamically resizes swap) and swap usage
roughly tripled during the run** — real memory pressure did occur. **No crash, no OOM
kill, no failed allocation** — the full benchmark (both providers, 4 runs each) completed
successfully with peak process RSS of ~1.4 GB, comfortably under 8 GB on its own, but the
system as a whole was clearly under real pressure from the combination of this process
plus everything else already running. This machine should not be assumed to have comfortable
headroom for a longer clip or additional concurrent load without re-checking swap/pressure.

### M1.9 CoreML reference (closest real "MPS-equivalent" route for this ONNX model)

Per the brief: no new model conversion was performed to get a PyTorch/MPS number (out of
scope) — the *existing*, no-conversion-needed Apple-Silicon-native onnxruntime EP for
this exact `.onnx` file is `CoreMLExecutionProvider` (onnxruntime's real name for it;
there is no separate onnxruntime EP literally named "MPS" — PyTorch's MPS backend is a
different, unrelated technology that would require converting the ONNX model to a
PyTorch module, which the brief explicitly disallows). `ort.get_available_providers()`
confirms it ships in the standard macOS onnxruntime wheel with zero extra installation.

Ran once (not a full 4-run benchmark — this is an exploratory supplementary data point,
not a required deliverable; "a CPU-vs-WebGPU comparison is sufficient for this phase to
pass" per the brief) through the real `Separator`/`audio-separator` pipeline, same model,
same input clip:

- `get_providers()` confirms `CoreMLExecutionProvider` is first/active (not silently
  falling back to CPU) — but **verification stops there**: no per-node placement log
  parser equivalent to `webgpu_adapter.py`'s was built or attempted for CoreML, so this
  is confirmed *active*, not confirmed *every node ran on GPU/ANE* the way the WebGPU
  numbers are. Report this distinction honestly rather than implying equal rigor.
- Single cold run: load=2.52 s, run=8.96 s — **slower than both the CPU and WebGPU warm
  medians above** in this one uncontrolled comparison (no warm-up repeats were run, so
  this may include CoreML's own first-call graph-compilation cost, similar to WebGPU's
  cold-start effect — not established either way here).
- Numeric comparison vs CPU: Vocals corr=0.999986, max_abs_diff=6.41e-04; Instrumental
  corr=0.9999998, max_abs_diff=5.80e-04 — correct and well within any audible-difference
  threshold, but **visibly looser than the WebGPU-vs-CPU raw comparison** (3.58e-07 /
  3.28e-07) by roughly three orders of magnitude, consistent with CoreML using a
  different internal numeric path (e.g. reduced precision on ANE) rather than a bug.

**Conclusion: informational only, not a rigorous PASS/FAIL** — real, unmodified-model,
unmodified-pipeline execution confirmed, but neither the execution-proof rigor nor the
run-count of the CPU/WebGPU comparison above. Not required for M1 phase success per the
brief, included because it was available at essentially no extra cost.

### M1.10 Deliverables summary

| Test | Resultaat |
|---|---|
| macOS ARM64 runtime | **PASS** — native arm64 throughout, no Rosetta |
| Native WebGPU EP | **PASS** — registers, 1 device found |
| Apple M1 GPU-detectie | **PASS** — vendor_id 0x106B (Apple), single device |
| Metal-backend bewezen | **PASS** — binary-level (Metal.framework-only linkage + embedded Dawn Metal backend source paths), corroborated by runtime dispatch log |
| ONNX-model geladen | **PASS** — real `UVR_MDXNET_KARA_2.onnx`, fetched via audio-separator's own catalog |
| Graph execution | **PASS** — 185/185 nodes on WebGPU, identical count to Linux |
| CPU fallback | **PASS** — 0 fallback nodes |
| End-to-end audio | **PASS** — both providers, no crash, complete export |
| Stem routing | **PASS** |
| Numerieke gelijkwaardigheid | **PASS** — raw and file comparisons both within pre-declared tolerance |
| CPU benchmark | **PASS** — warm median 6.90 s, stdev 0.229 s, 4 runs |
| WebGPU benchmark | **PASS** — warm median 4.11 s, stdev 0.023 s, 4 runs, 1.68× vs CPU |
| Memory validation | **PASS with caveats** — RSS reliable (~1.4 GB peak, no OOM); VRAM/GPU-util BLOCKED (no macOS tooling, as predicted); real swap pressure observed and documented, not hidden |
| CoreML/MPS reference | **INFORMATIONAL** — real execution confirmed, lower verification rigor and single-run only, not a required PASS |

### M1.11 Code changes made (all on `experiment/webgpu-ep`, no new branch)

Small, isolated, and where the fix was genuinely cross-platform (not macOS-specific),
applied identically for Linux too:

1. `webgpu_ep_probe.py` — replaced its own inline, AMD-PCI-bus-id-hardcoded device
   selection with the existing, already cross-platform `webgpu_adapter.select_device()` /
   `create_verified_webgpu_session()` (adds an optional `--pci-bus-id` flag for parity
   with the other two scripts). Removes duplicated device-matching logic rather than
   adding new platform-specific code.
2. `end_to_end_pipeline_test.py`, `benchmark_resources.py` — `--pci-bus-id` default
   changed from the hardcoded RX 9070 bus id (`"0000:03:00.0"`) to `None`, so
   `select_device()`'s existing "auto-pick the only device" behavior applies on any
   single-GPU system (macOS included) without an override; Linux multi-GPU users
   already pass `--pci-bus-id` explicitly per the documented reproduction commands, so
   this is not a behavior change for them.
3. `resource_sampler.py` — added a `sys.platform == "darwin"` branch to `_read_rss_kb()`
   using `resource.getrusage(RUSAGE_SELF).ru_maxrss` (macOS has no `/proc`); Linux path
   completely unchanged. See M1.7 for the peak-vs-instantaneous semantic caveat this
   introduces.
4. `requirements-webgpu-experiment.txt` — added missing transitive dependency
   `audioread==3.1.0` (§M1.2); applies to both platforms.
5. `benchmark_resources.py` — fixed the hardcoded-`20.0`-second real-time-factor bug
   (§M1.7); a genuine cross-platform correctness fix, not a macOS accommodation.

No production STEMwerk venv, model registry, GPU resolver, release branch, or REAPER UI
file was touched. No CUDA/ROCm/DirectML code was touched. `rocm_reference_benchmark.py`
was not run or modified on macOS (Linux/ROCm-only, out of scope here per the brief's own
§8 MPS-reference guidance). Nothing pushed in this phase.

## Cross-platform regression check (Linux, after the macOS merge)

Status date: 2026-09-19. After Phase M1's commit (`467c7ce2a`) was fast-forward-merged
into the Linux worktree (`git merge --ff-only`, no rebase/reset), every Linux L1/L2 test
was re-run unchanged, same model (`UVR_MDXNET_KARA_2.onnx`), same test clip, same
`--pci-bus-id 0000:03:00.0` (still required explicitly — the CLI default change in §M1.11
item 2 only affects single-GPU systems). Purpose: confirm the macOS-driven code changes
(§M1.11 — all isolated to `resource_sampler.py`'s macOS-only branch, two CLI defaults, one
dependency pin, one cross-platform bug fix) did not alter Linux/AMD/Vulkan behavior.
`webgpu_adapter.py` — the module that actually does provider selection, device matching,
and graph-placement verification — was not touched by the macOS work at all.

| Check | Original L1/L2 (pre-merge) | Re-run (post-merge) | Regression? |
|---|---|---|---|
| RX 9070 correctly selected (of 2 GPUs) | PASS | PASS | No |
| WebGPU dispatches via Vulkan | PASS (RADV) | PASS (RADV) | No |
| Graph placement, real model | 185/185 nodes on WebGPU | **185/185 nodes on WebGPU** | No |
| CPU fallback | 0 nodes | **0 nodes** | No |
| End-to-end audio + output validation | PASS | PASS | No |
| Stem routing | PASS (corr 1.0 vs 0.9989) | **PASS (corr 1.0 vs 0.9989, identical)** | No |
| Raw numeric diff vs CPU (Vocals/Instr.) | 7.08e-08 / 6.61e-08 | **7.08e-08 / 6.61e-08 (bit-identical)** | No |
| File numeric diff vs CPU | 1.00× PCM16 LSB (both stems) | **1.00× PCM16 LSB (both stems, bit-identical)** | No |
| WebGPU warm median (4 runs) | 1.41 s | **1.41 s** | No |
| CPU warm median (4 runs) | 8.13 s | 7.55 s | Within documented noise band (5.98–9.1 s across prior runs); not WebGPU-related |
| Speedup vs CPU | 5.75× | 5.34× | Tracks the CPU-side noise above, not a WebGPU change |
| ROCm graph placement | 139/139 nodes | **139/139 nodes** | No |
| ROCm warm avg (4 runs) | 1.13 s | 1.12 s | No (within run-to-run stdev already documented, ~0.01 s) |
| ROCm raw numeric diff vs CPU | 4.47e-08 / 4.10e-08 | **4.47e-08 / 4.10e-08 (bit-identical)** | No |

**Conclusion: no regression.** Every GPU-execution-proof, correctness, and routing check
reproduced exactly (several numbers bit-for-bit identical, which is expected — the code
paths that produce them, `webgpu_adapter.py` and the ONNX graph/model itself, were not
touched by the macOS commit). The only figures that moved at all are CPU-side wall-clock
timings, and they moved by an amount already characterized as ordinary desktop
scheduling noise in the original L2 report — not attributable to any code change.

### Combined Linux/macOS status

| Onderdeel | Linux AMD (RX 9070, Vulkan) | macOS M1 (Metal) |
|---|---|---|
| Native WebGPU EP | **PASS** — registers, 2 devices found, RX 9070 selected explicitly via `pci_bus_id` | **PASS** — registers, 1 device found, auto-selected |
| Vulkan/Metal | **PASS** — Dawn→Vulkan via RADV (Mesa 26.2.2; RADV self-reports non-conformant, functioned correctly regardless) | **PASS** — Dawn→Metal, binary-verified (`otool -L`: Metal.framework only, no Vulkan/MoltenVK; embedded Dawn Metal-backend source paths) |
| GPU graph execution | **PASS** — 185/185 nodes on WebGPU (log-verified) | **PASS** — 185/185 nodes on WebGPU (log-verified, identical node count) |
| CPU fallback | **PASS** — 0/185 nodes | **PASS** — 0/185 nodes |
| End-to-end audio | **PASS** — 2 stems, validated (sr/ch/duration/NaN/silence/clipping), stem routing correct | **PASS** — 2 stems, validated, stem routing correct |
| Numerical validation | **PASS** — raw 7.08e-08/6.61e-08, file 1.00× PCM16 LSB, both within pre-declared tolerance | **PASS** — raw 3.58e-07/3.28e-07, file 1.00× PCM16 LSB, both within the same pre-declared tolerance |
| Benchmark | **PASS** — warm median 1.41 s WebGPU vs 7.55–8.13 s CPU (5.3–5.75×); ROCm reference 1.12–1.13 s (7.2×) | **PASS** — warm median 4.11 s WebGPU vs 6.90 s CPU (1.68×); CoreML reference informational only (lower rigor) |
| Memory validation | **RSS: PASS** (reliable, per-process) — **VRAM/GPU-util: BLOCKED** (whole-GPU only, not per-process attributable) | **RSS: PASS with caveat** (peak-since-process-start semantics, not per-phase) — **VRAM/GPU-util: BLOCKED** (no macOS tooling without privileged `powermetrics`, out of scope); real swap pressure observed on 8 GB unified memory, no OOM |

Different hardware, different test clip lengths (20 s Linux vs 6 s macOS — the macOS clip
was a separately-sourced file, not copied over git, per the "no large audio in Git" rule)
and different GPU architectures mean the **absolute** benchmark numbers are not a
head-to-head speed ranking. What *is* directly comparable: both platforms independently
prove correct, log-verified, zero-fallback GPU execution and numerically-within-tolerance
output for the same unmodified ONNX model and pipeline code.

**First proven cross-platform WebGPU route for this model.** With Linux/AMD (RX 9070,
Vulkan/RADV) and macOS/Apple Silicon (M1, Metal/Dawn) both independently confirmed —
same branch, same unmodified ONNX graph, same `webgpu_adapter.py`, same verification
standard (real per-node placement proof, not just "EP loaded") — `UVR_MDXNET_KARA_2.onnx`
has now demonstrably run correctly and with real GPU execution, via the same experimental
code, on two different GPU vendors and two different operating systems. **This is a
statement about one tested model on two tested machines, not a production-readiness
claim for WebGPU EP in general or for STEMwerk's wider model catalog** — see §9's
operator-coverage caveat (untested ops may still fall back to CPU on other models) and
the M1 report's own caveats (8 GB unified-memory pressure, CoreML-reference-only rigor,
etc.) before drawing any broader conclusion.

## Reproducing this experiment

```bash
# 1. venvs (must be on a POSIX filesystem, NOT exFAT; on macOS, any local APFS path is fine)
python3.11 -m venv /path/to/.venv-webgpu     # or python3.12 -- see "Phase M1" for the
source /path/to/.venv-webgpu/bin/activate    # macOS interpreter choice and why
pip install -r requirements-webgpu-experiment.txt

# 2. cheap sanity probe (no real model / audio needed)
python webgpu_ep_probe.py                    # macOS/single-GPU: no flags needed

# 3. full pipeline test with real GPU-execution proof + output validation
python end_to_end_pipeline_test.py /path/to/some.wav                       # macOS/single-GPU
python end_to_end_pipeline_test.py /path/to/some.wav --pci-bus-id 0000:xx:00.0  # Linux/multi-GPU

# 4. fair CPU-vs-WebGPU benchmark with resource sampling
python benchmark_resources.py /path/to/some.wav --runs 4                       # macOS/single-GPU
python benchmark_resources.py /path/to/some.wav --pci-bus-id 0000:xx:00.0 --runs 4  # Linux/multi-GPU

# 5. (optional, separate venv, Linux/ROCm only -- not applicable on macOS) same-graph ROCm reference
python3.11 -m venv /path/to/.venv-rocmref
source /path/to/.venv-rocmref/bin/activate
pip install onnxruntime-rocm numpy soundfile audio-separator
python rocm_reference_benchmark.py /path/to/some.wav --runs 4
```

`--pci-bus-id` is optional everywhere now (all three scripts default to `None` and let
`webgpu_adapter.select_device()` auto-pick the only device on a single-GPU system, which
is what every macOS machine is). Pass it explicitly only when more than one WebGPU device
exists (e.g. a Linux desktop with a discrete GPU + an iGPU) — `select_device()` refuses to
guess in that case rather than silently picking one.

Find your GPU's PCI bus id with `lspci -nn | grep -i vga`. If your machine has only one
WebGPU-capable GPU, `select_device()` will pick it automatically without `--pci-bus-id`.
