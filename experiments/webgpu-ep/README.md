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

**NOT TESTED / BLOCKED on hardware access** — no macOS execution occurred in either
phase, per the brief's instruction not to report a Metal PASS without running on the
actual M1.

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
| macOS readiness | **READY** (code is platform-generic except one isolated device-selection function) / execution itself **BLOCKED** on M1 hardware access |

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

## Reproducing this experiment

```bash
# 1. venvs (must be on a POSIX filesystem, NOT exFAT)
python3.11 -m venv /path/to/.venv-webgpu
source /path/to/.venv-webgpu/bin/activate
pip install -r requirements-webgpu-experiment.txt

# 2. cheap sanity probe (no real model / audio needed)
python webgpu_ep_probe.py

# 3. full pipeline test with real GPU-execution proof + output validation
python end_to_end_pipeline_test.py /path/to/some.wav --pci-bus-id 0000:xx:00.0

# 4. fair CPU-vs-WebGPU benchmark with resource sampling
python benchmark_resources.py /path/to/some.wav --pci-bus-id 0000:xx:00.0 --runs 4

# 5. (optional, separate venv) same-graph ROCm reference
python3.11 -m venv /path/to/.venv-rocmref
source /path/to/.venv-rocmref/bin/activate
pip install onnxruntime-rocm numpy soundfile audio-separator
python rocm_reference_benchmark.py /path/to/some.wav --runs 4
```

Find your GPU's PCI bus id with `lspci -nn | grep -i vga`. If your machine has only one
WebGPU-capable GPU, `select_device()` will pick it automatically without `--pci-bus-id`.
