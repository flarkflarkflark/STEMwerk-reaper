# WebGPU EP experiment — native ONNX Runtime WebGPU Execution Provider (Linux/AMD+NVIDIA, macOS/Apple Silicon, Windows/AMD+NVIDIA)

Status date: 2026-09-21. Experimental, opt-in, isolated. Not integrated into STEMwerk.

## Phase W6 — native patch hardening and experimental Windows distribution

W6 turned the W5 proof of concept into a coherent, independently installable
experimental Windows wheel, changing no runtime behavior. The W4 and W5 patches
are preserved as evidence and consolidated into one reviewable patch,
[`patches/W6-consolidated-WebGPU-Windows-D3D12-adapter-LUID-selection.patch`](patches/W6-consolidated-WebGPU-Windows-D3D12-adapter-LUID-selection.patch),
whose tree is byte-identical to the proven W5 fixed source (`git diff` empty)
and which applies cleanly to the pinned upstream base.

The wheel `onnxruntime_ep_webgpu-0.3.0+w6consolidated-py3-none-win_amd64.whl`
(SHA-256 `be602b7153e0a563e2e9e315f975423a9eab900f86769dd2828d8515c88ade16`)
was packaged with the plugin's own build script and installed into a fresh venv
as a normal package — no DLL swapping. In-process module enumeration proved the
loaded provider DLL is the wheel's own file (SHA-256 `ee58f6d3...`; not
bit-identical to the W5 DLL — same source, same toolchain, non-deterministic
LTO link — so no bit-for-bit reproducibility is claimed).

On the W6 wheel, both physical-selection directions re-passed with
same-process OS counters (RTX LUID `64318`: 963 inferences, only RTX active,
peak 36.92%; AMD LUID `59967`: 775 inferences, only AMD active, peak 55.94%),
and full MDX-Net validation passed on both GPUs: 185/185 nodes on WebGPU, zero
CPU fallback, correlation 1.00000000, max abs ≈ `1.1e-6`, file diff ≤ 1 PCM16
LSB, routing PASS. Regressions are green: first-inference crash repro (both
GPUs), invalid/cross-GPU/malformed LUID rejection, same-GPU context reuse,
resolver 40/40 with 2 expected Linux-only skips, adapter selection 9+5,
capability matrix 14 entries byte-identical, compileall clean.

Full provenance, the machine-readable build manifest
([`w6_build_manifest.json`](w6_build_manifest.json)), distribution and licensing
findings, and the independent AMD-workstation handoff procedure are in
[`WINDOWS_NATIVE_DISTRIBUTION.md`](WINDOWS_NATIVE_DISTRIBUTION.md).

## Phase W5 — native build, crash correction, and physical RTX/AMD validation

W5 built the W4 native DXGI-LUID patch from the pinned ORT/Dawn source in an isolated
local tree. The first patched build exposed a reproducible first-inference abort on
both GPUs. An identical-source/configuration unpatched control passed, proving the
regression was introduced by W4 rather than by the toolchain or Dawn build.

Native dumps showed that `0xC0000409` was fast-fail subcode 7 after an uncaught
`OnnxRuntimeException`, not demonstrated buffer corruption. The first internal tensor
transfer called `DefaultContext()` with an empty config; that path incorrectly
re-initialized the already LUID-constrained context and triggered W4's cross-GPU cache
guard. Dawn request-chain lifetime and ABI hypotheses were checked and did not match
the observed exception or controlled A/B.

The minimal correction makes `DefaultContext()` retain and return an existing context
ID 0 without re-running `Initialize`; explicit caller-created contexts still enforce
LUID identity. It is committed only in the isolated source checkout as
`1070be0cf9b10ea9e45d42d30d307ba459e673e5` and preserved as
[`patches/0002-WebGPU-retain-selected-default-context.patch`](patches/0002-WebGPU-retain-selected-default-context.patch).
Only the affected provider target was rebuilt, with the four-job limit.

The fixed DLL is 10,443,264 bytes with SHA-256
`b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248`.
Fresh-process live-module verification matched that exact file. First Conv inference
passed. Independent per-PID Windows GPU Engine counters then proved both selection
directions using dense workloads:

- RTX request LUID `64318`: only the RTX LUID was active, peak 38.65%, 714 inferences.
- AMD request LUID `59967`: only the AMD LUID was active, peak 59.37%, 618 inferences.

Full 25-second MDX-Net/audio runs also passed independently on both GPUs: 185/185
nodes on WebGPU, raw CPU/WebGPU correlation 1.00000000, maximum absolute error about
`1.1e-6`, valid stereo stems, correct routing, and exported differences no greater
than one PCM16 LSB. AMD PASS therefore rests on positive AMD physical activity plus
model/numerical/audio success—not session creation alone.

Regressions are green: selector 9/9, resolver 29/29 non-skipped with 2 expected
Linux-only skips, capability matrix/schema 11×24, and Python compilation. The
capability matrix upgrades only the two actually tested Windows MDX-Net rows; AMD is
still excluded from Auto pending repeated performance/stability work, and Demucs is
unchanged. Full provenance and evidence are in
[`WINDOWS_NATIVE_BUILD_VALIDATION.md`](WINDOWS_NATIVE_BUILD_VALIDATION.md).

## Phase W4 — Windows native DXGI LUID proof of concept

W4 implements a minimal native patch against the exact
`plugin-ep-webgpu/v0.3.0` source (`caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`).
It propagates the selected Windows hardware device's existing DXGI `LUID` metadata to
the pinned Dawn `RequestAdapterOptionsLUID`, verifies requested versus returned
adapter identity, and prevents WebGPU context-cache reuse across physical GPUs. The
full patch and evidence are in
[`WINDOWS_NATIVE_LUID_POC.md`](WINDOWS_NATIVE_LUID_POC.md).

At the end of W4 this machine still lacked Visual Studio/MSVC, a Windows SDK, and
CMake. Consequently the patch was then reviewable but unbuilt: no patched DLL was
loaded and RTX-to-AMD physical
switching remains **NOT VERIFIED**. The installed 0.3.0 runtime and production
STEMwerk remain untouched; no capability-matrix claim was added. Experiment CLIs now
accept `--adapter-luid` and reject ambiguous selectors, ready for the isolated build
and fresh-process A/B validation described in the W4 report.

The original Linux work began with two phases:
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
- `select_device(pci_bus_id=..., device_id=..., adapter_luid=...)` — explicit device selection;
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

## Phase L3: Model Compatibility & Cross-Platform Runtime Feasibility

Status date: 2026-09-19. Starting commit: `1a3d4f9796e0936c4d6e0893d2cfe2ff8cd5fd68`
(verified, matched expectation). Mission shift from L1/L2/M1 ("can WebGPU run one
model") to: **how much of STEMwerk could realistically share one native ONNX/WebGPU
inference route, and what would it cost?** Performance is explicitly secondary this
phase; correctness, maintainability, and distribution simplicity are the design goals.

### L3.1 Model inventory — the central finding

Full matrix: **`MODEL_COMPATIBILITY_MATRIX.md`** (companion file, built from direct
repo inspection + the live `audio-separator` catalog, not memory). Headline finding,
confirmed by tracing all seven REAPER-facing workflow scripts back through
`STEMwerk.lua`'s actual dispatch logic:

**No currently-reachable STEMwerk workflow uses any `.onnx` model at all.** Every real
workflow (All Stems, Vocals/Bass/Drums Only, Karaoke, AI Separate, Drum Kit Split) runs
either Demucs (`htdemucs`/`htdemucs_ft`/`htdemucs_6s`, native PyTorch, no ONNX
involvement whatsoever) or, for Drum Kit Split's second stage, a single MDX23C `.ckpt`
(also PyTorch). "Karaoke" does not select a dedicated karaoke model — it's a
stem-selection preset on top of the default Demucs separation. `Kim_Vocal_2.onnx` (an
MDX-Net ONNX model) is mentioned only inside unreachable `--list-models` CLI help text.
The `audio-separator` catalog does contain 39 real `.onnx` MDX-Net models (including
`UVR_MDXNET_KARA_2`, the model this whole experiment has used since Phase L1), but
**none of them are wired into any STEMwerk-reaper UI path today** — they are, in the
brief's terminology, entirely "catalog" or "external," never "production."

**Consequence for the whole feasibility question**: a native WebGPU EP integration
would not accelerate anything STEMwerk currently does. Before WebGPU can help a real
user, STEMwerk would need to either (a) introduce a new ONNX-based workflow/model
option (straightforward — the catalog already has usable `.onnx` models), or (b) get
an ONNX export of the models STEMwerk actually uses today (Demucs, MDX23C DrumSep) —
which, per §L3.5 below, is unverified/uncertain for both. This reframes "WebGPU
feasibility" from a backend-swap question into a **model-strategy** question.

### L3.2 Additional ONNX models tested — shape diversity, not architectural diversity

Selected `Reverb_HQ_By_FoxJoy.onnx` (66.8 MB, reverb removal — a different task, not
just a different vocals/instrumental split), `kuielab_a_bass.onnx` (29.7 MB, bass
isolation, different training lineage/n_fft=16384), and `UVR-MDX-NET-Inst_HQ_5.onnx`
(59.1 MB, latest general instrumental/vocals HQ tier — closest of the catalog to a
"Normal Stems"-relevant model). **Honest finding, exactly the kind the brief warned
against inventing away**: all 4 tested `.onnx` models (these 3 plus `UVR_MDXNET_KARA_2`
from L1/L2) share the **identical graph topology** — 178 raw nodes, the same 8 op types
in the same counts (`Conv:40, Relu:66, BatchNormalization:27, MatMul:22, Add:11,
ConvTranspose:5, Mul:5, Transpose:2`) — differing only in input/output tensor shape
(`dim_f`×`dim_t`, driven by `n_fft`/`mdx_dim_t_set`), trained weights, and target stem.
The `audio-separator` ONNX catalog is architecturally a single MDX-Net template
reused across ~39 fine-tunes, not 39 distinct architectures. Shape diversity is still a
meaningful WebGPU test dimension (different tensor sizes can hit different shader
compilation paths, buffer-size limits, etc.) — this experiment tested it honestly as
that, not overstated as operator-coverage diversity.

Real, non-obvious finding discovered *during* this phase's own testing (not predicted
in advance): the **segment_size / dim_t routing trap** — see
`MODEL_COMPATIBILITY_MATRIX.md` for the full writeup. Two of the three new models
(`Reverb_HQ_By_FoxJoy`, `kuielab_a_bass`, both `dim_t=512`) initially appeared to "pass"
graph placement with zero code changes, but a first test run silently produced identical
numeric results to `UVR_MDXNET_KARA_2` for all three models — impossible for three
differently-trained models, and the giveaway that something was wrong (traced to a
model-filename-parametrization bug in the test harness itself, fixed). Once fixed, a
second, deeper bug surfaced: `audio-separator`'s `MDXSeparator` silently routes
inference through `onnx2torch`→PyTorch instead of onnxruntime whenever the model's
native `dim_t` doesn't match the configured `segment_size` (default 256) — with only a
debug-level log line as evidence, `get_providers()` never even gets called because no
`InferenceSession` is created at all. **A model that produces valid output entirely via
PyTorch must not be reported as a WebGPU pass** — this experiment classifies it
separately (`webgpu_uses_pytorch_inference` field in `l3_model_compatibility_test.py`'s
report), matching the brief's explicit requirement in §6.

### L3.3 Test evidence — all 4 tested `.onnx` models, real hardware, real pipeline

Test script: `l3_model_compatibility_test.py` (reuses `webgpu_adapter.py` and
`end_to_end_pipeline_test.py`'s functions directly — no second implementation, per the
brief). Auto-detects the `segment_size`/`dim_t` trap per model (§L3.2) rather than
hardcoding it. Run against the RX 9070 (`--pci-bus-id 0000:03:00.0`, explicit — this
workstation has 2 GPUs, never auto-guessed), same 20 s test clip as L1/L2.

| Model | A: inspect | B: CPU baseline | C: WebGPU init | D: graph placement | E: inference | F: end-to-end audio | Raw numeric (max abs diff) |
|---|---|---|---|---|---|---|---|
| `UVR_MDXNET_KARA_2.onnx` (L1/L2 regression) | PASS | PASS | PASS | **PASS — 185/185 WebGPU, 0 CPU** | PASS | PASS (validation+routing+raw+file) | 7.08e-08 / 6.61e-08 |
| `Reverb_HQ_By_FoxJoy.onnx` | PASS | PASS | PASS (after `segment_size=512` override) | **PASS — 185/185 WebGPU, 0 CPU** | PASS | PASS | 1.49e-08 / 5.78e-09 |
| `kuielab_a_bass.onnx` | PASS | PASS | PASS (after `segment_size=512` override) | **PASS — 185/185 WebGPU, 0 CPU** | PASS | PASS | 1.49e-08 / 4.03e-09 |
| `UVR-MDX-NET-Inst_HQ_5.onnx` | PASS | PASS | PASS | **PASS — 185/185 WebGPU, 0 CPU** | PASS | PASS | 1.04e-07 / 1.08e-07 |

All within the pre-declared L2 raw tolerance (correlation ≥0.999, max_abs_diff ≤5e-3) by
4+ orders of magnitude margin. Note per the brief's own warning: onnxruntime's
*optimized* graph has 185 nodes for every model (post graph-transformer fusion), not
the raw file's 178 — this is expected EP-specific graph optimization, not a
discrepancy, and this phase's test script explicitly does not compare raw-vs-optimized
counts as a pass/fail criterion (an earlier draft of the test incorrectly did, and
produced a false "PARTIAL/FAIL" until corrected — see git history on this branch for
the fix).

**Basic performance reference** (single run per provider, load separate from run,
performance secondary this phase — not a repeated/warm benchmark like L2's):

| Model | CPU load / run | WebGPU load / run | Speedup (single run) |
|---|---|---|---|
| `Reverb_HQ_By_FoxJoy.onnx` | 0.07 s / 13.04 s | 0.12 s / 1.83 s | 7.1× |
| `kuielab_a_bass.onnx` | 0.04 s / 5.47 s | 0.06 s / 1.61 s | 3.4× |
| `UVR-MDX-NET-Inst_HQ_5.onnx` | 0.05 s / 9.26 s | 0.08 s / 1.48 s | 6.2× |

No obviously impractical performance found (all WebGPU runs comfortably faster than
real-time for a 20 s clip); no shader-tuning or kernel-level optimization attempted, per
the brief's instruction to keep this basic.

### L3.4 Cross-platform backend matrix

| Platform | GPU family | Officially documented (Dawn/onnxruntime docs) | Package available (pip wheel exists) | Tested by STEMwerk (this project) | Known limitation |
|---|---|---|---|---|---|
| Linux x86-64 | AMD | Yes (Vulkan) | Yes (`manylinux_2_28_x86_64`) | **Yes — PASS** (RX 9070, L1/L2/L3) | Multi-GPU systems need explicit device selection (§L3.4a) |
| Linux x86-64 | NVIDIA | Yes (Vulkan) | Yes (same wheel, vendor-agnostic) | **Not tested** — no NVIDIA hardware available in this project | Unverified; Vulkan/NVIDIA is a very common, well-trodden combination industry-wide, but not verified by STEMwerk specifically |
| Linux x86-64 | Intel | Yes (Vulkan) | Yes (same wheel) | **Not tested** | Unverified |
| Linux ARM64 (aarch64) | any | Not documented for this specific plugin | **No** — `onnxruntime-ep-webgpu` 0.3.0 ships no `aarch64`/`arm64` Linux wheel (only `manylinux_2_28_x86_64`) despite base `onnxruntime` itself shipping a `manylinux_2_28_aarch64` wheel | Not tested, and not currently installable via pip regardless | Confirmed via direct PyPI wheel listing, not assumed |
| Windows x86-64 | AMD/NVIDIA/Intel | Yes (D3D12 primary, Vulkan available) | Yes (`win_amd64`) | **Not tested** — no Windows hardware in this project | Do not read this as "tested" — deliberately excluded per the brief |
| Windows ARM64 | Qualcomm/etc. | Yes (D3D12) | Yes (`win_arm64`) | Not tested | Unverified |
| macOS Apple Silicon | Apple | Yes (Metal) | Yes (`macosx_14_0_universal2`) | **Yes — PASS** (M1, this branch) | 8 GB unified-memory models show real swap pressure under load (documented in Phase M1) |
| macOS Intel (x86_64) | AMD (eGPU/iGPU) | Nominally yes (universal2 wheel tag covers x86_64) | **Verified NOT actually installable** — base `onnxruntime` (a hard `onnxruntime-ep-webgpu` dependency, required `>=1.24.4`) has published **only `macosx_14_0_arm64` wheels for every version from 1.24.4 through the current 1.30.0** — no macOS x86_64 wheel exists for the required base package at all, confirmed by checking every minor release on PyPI | **Not tested, and currently blocked** | This is exactly the "don't assume ARM64 proves Intel" trap the brief warned about — confirmed with real data, not assumed either way. STEMwerk does maintain a real macOS Intel production constraints file (`scripts/reaper/constraints/macos-intel.txt`), so this is a real, non-hypothetical gap for any future WebGPU work, not a hardware STEMwerk doesn't otherwise support |

#### L3.4a Device selection strategy

Directly informed by this project's own dual-GPU Linux workstation (RX 9070 discrete +
Phoenix iGPU) — this was never a hypothetical edge case:

- **Multiple GPUs / integrated vs discrete**: `ort.get_ep_devices()` enumerates every
  WebGPU-capable adapter with no notion of "best" or "default" discrete GPU.
  `webgpu_adapter.select_device()` (unchanged since L1, reused verbatim through L2/M1/L3)
  **refuses to guess** — raises `GpuExecutionNotProvenError` when more than one device
  exists and no explicit selector is given, and auto-selects only when exactly one
  device exists (which is what happened, correctly, on the single-GPU M1). A production
  integration would need either an explicit user-facing GPU picker (mirroring how
  STEMwerk's existing `devices.py` already handles CUDA/ROCm/DirectML device choice) or
  a documented heuristic (e.g. prefer the device with the most VRAM, or the one with a
  non-zero `pci_bus_id` distinct from a known iGPU ID range) — this experiment
  deliberately does not invent that heuristic, since it would be an unverified guess.
- **Multi-vendor systems** (e.g. AMD iGPU + NVIDIA discrete, common on gaming laptops):
  not tested; the same "explicit selection, no guessing" principle applies, but which
  device is genuinely "best" cross-vendor is a real open question this project has no
  data on.
- **Systems without a suitable GPU**: `list_webgpu_devices()` returning an empty list is
  already a defined, handled state (`GpuExecutionNotProvenError` with a clear message)
  — a production integration should treat this as "fall back to the existing CPU/torch
  route," exactly as STEMwerk's existing device resolver already does for missing
  CUDA/ROCm.
- **EP loads but the requested adapter is unavailable** (e.g. eGPU unplugged mid-session,
  requested `pci_bus_id` no longer present): `select_device()` already raises cleanly
  in this case (tested directly in L2 with a deliberately wrong `pci_bus_id`) rather than
  silently falling back to a different device or to CPU — a production integration
  would need to decide whether that should be a hard error (current adapter behavior) or
  a soft fallback with a user-visible warning; this experiment intentionally kept it
  strict, since silent fallback is exactly the failure mode the whole project has been
  guarding against.

### L3.5 Runtime packaging and dependencies

**The WebGPU EP itself is small: `onnxruntime` (67 MB installed) +
`onnxruntime-ep-webgpu` (16 MB installed) = ~83 MB, ~30 MB combined compressed wheel
download.** This is the actual, isolated marginal cost of the WebGPU pieces, verified by
directly measuring `du -sh` on the installed package directories — not estimated.

**The real packaging risk is not WebGPU-specific at all.** A naive `pip install -r
requirements-webgpu-experiment.txt` (i.e. `pip install audio-separator` without an
`--index-url` override) pulled in **3.2 GB of NVIDIA CUDA libraries and 897 MB of
Triton** on this AMD-only Linux workstation with no NVIDIA hardware present — because
generic PyPI `torch` wheels bundle the full CUDA runtime unconditionally, and none of
that is used by (or relevant to) the WebGPU/CPU code paths this experiment actually
exercises. **This is not evidence against WebGPU** — it's evidence that `audio-separator`
+ generic `torch` is expensive regardless of inference backend, and this cost already
exists in STEMwerk's production Demucs/DrumSep paths today. STEMwerk's actual Linux
bootstrap (`STEMwerk_Bootstrap_Linux.sh`) already solves this correctly, installing torch
via explicit `--index-url https://download.pytorch.org/whl/cpu` (or the matching
`rocm6.4`/`rocm7.0`/`rocm7.1`/`rocm7.2` index once hardware is detected) specifically to
avoid this bloat — this experiment's own venv did not replicate that flag (out of scope
for a throwaway research venv), so the 4+ GB figure should be read as "what happens
without STEMwerk's existing installer discipline," not as a WebGPU cost. **A real
integration should reuse STEMwerk's existing `--index-url` pattern for the WebGPU
venv/route too.**

**Distribution requirements**: no system GPU drivers, Vulkan loader, or Dawn libraries
need separate installation — `libvulkan.so.1` (Linux) was already present as part of the
existing Mesa/RADV stack (confirmed in L1: `no system packages, drivers, or kernel
changes were needed or made`), and Metal is a macOS system framework (confirmed in M1
via `otool -L`). This is a genuine potential *advantage* over CUDA/ROCm (which need
much larger, vendor-specific driver/runtime stacks) — but this experiment did not
measure CUDA/ROCm's own driver-stack size for a fair side-by-side, so this is noted as a
plausible advantage, not a quantified one.

**ONNX Runtime distribution conflicts — verified, not assumed**: `onnxruntime-rocm`
installs its own `onnxruntime/` package directory at the exact same import path as the
base `onnxruntime` package (confirmed via `pip show onnxruntime-rocm` → same
`site-packages/onnxruntime/__init__.py` location) — these **cannot coexist reliably in
one venv**; whichever installs last silently overwrites the other's files. This is why
L2's ROCm reference and the main WebGPU venv have been kept in two fully separate venvs
since Phase L2, and this phase confirms that separation was a real technical necessity,
not just caution. The monolithic `onnxruntime-webgpu` alternative (§3, not used in this
project) would very likely have the same conflict with base `onnxruntime` +
`onnxruntime-ep-webgpu` for the same reason (same top-level import path), though this
was not directly tested since the plugin-EP route was used throughout.

**Could WebGPU reduce vendor-specific dependency duplication?** Partially, and only for
the *inference* layer: STEMwerk's current architecture needs separate CUDA/ROCm/
DirectML/MPS-specific torch builds today (confirmed in `STEMwerk_Bootstrap_*` scripts —
different `--index-url` per platform/vendor). A WebGPU EP route, if adopted for
ONNX-format models, would need only one `onnxruntime` + `onnxruntime-ep-webgpu` pair
across AMD/NVIDIA/Intel/Apple, *for the ONNX-model portion of inference only* — it would
not replace the vendor-specific torch builds STEMwerk still needs for Demucs (PyTorch,
not ONNX). **Could it introduce new conflicts?** Yes — the confirmed `onnxruntime` vs
`onnxruntime-rocm` conflict above means a STEMwerk venv that wants both an accelerated
ROCm path (for Demucs, via torch+ROCm — unaffected, separate from onnxruntime entirely)
*and* a WebGPU-accelerated ONNX-model path would be fine (they use different underlying
libraries: torch-ROCm vs onnxruntime-WebGPU, no shared package name) — the conflict only
arises if STEMwerk ever wanted *both* `onnxruntime-rocm` (ROCm-accelerated ONNX,
STEMwerk does not currently use this) *and* `onnxruntime-ep-webgpu` in the same venv,
which would need the same two-venv isolation this project already uses.

**Not investigated**: exact installed-size delta for Windows/macOS (only measured on
this Linux machine); whether `onnxruntime-webgpu` (monolithic) has a smaller total
footprint than `onnxruntime`+`onnxruntime-ep-webgpu` (plugin) — plausible but unverified.

### L3.6 Demucs, RoFormer, and DrumSep feasibility (research only — nothing exported)

**Demucs / htdemucs**: A web search this phase surfaced a cluster of very recent (2026)
community sources (a GitHub repo, a Hugging Face upload, and a blog post, all from the
same "StemSplit"/"StemSplitio" author) claiming a first successful, parity-verified
ONNX export of `htdemucs_ft`, citing four specific technical blockers: complex64 `torch.stft`
output (ONNX has no native complex dtype), non-tensor Python control flow
(`fractions.Fraction`, `random.randrange` used in Demucs' own code), and
`aten::_native_multi_head_attention` having no ONNX symbolic (worked around by
substituting a Linear/bmm/softmax-based attention implementation). **This experiment
did not independently verify this claim** — no download, no export attempt, no
execution, per the brief's explicit instruction not to convert models this phase. Report
it as an unverified but specific, technically-plausible lead (the four blockers are
consistent with Demucs' known architecture) worth an independent read-through before
committing to it as a strategy, not as confirmed feasibility. If real, it would directly
resolve §L3.1's biggest gap (STEMwerk's actual default model, `htdemucs`, having no
ONNX path).

**RoFormer / MDXC**: No community ONNX export project was found for BS-RoFormer or
Mel-RoFormer via this phase's research (in contrast to Demucs, where at least an
unverified claim exists). Architecturally, RoFormer's core operations (MatMul, Softmax,
rotary-embedding rotation — expressible as elementwise Mul/Add/Concat) are individually
ONNX-exportable in principle, and RoFormer/MDXC's STFT/iSTFT preprocessing could
plausibly live outside the ONNX graph the same way MDX-Net's does (§2a) — but this is
architectural reasoning, not a verified path; audio-separator's own MDXC pipeline uses
`.ckpt`+PyTorch exclusively today with no ONNX variant anywhere in its dependency chain.
**Higher uncertainty than Demucs, not lower**, despite the seemingly simpler math —
there is no existing artifact to point to at all.

**DrumSep / Direct Kit / Kit Split**: STEMwerk's actual DrumSep model
(`MDX23C-DrumSep-aufr33-jarredou`) is itself an MDX23C model — same family as MDXC/
RoFormer above, inheriting the same "no existing ONNX artifact, plausible in principle,
unverified in practice" status. The two-stage workflow (Demucs stage 1 → DrumSep stage
2) means a WebGPU path here would need **both** stages converted for any real user-facing
benefit — converting only stage 2 (DrumSep) while stage 1 (Demucs) stays PyTorch/torch-only
would still leave the dominant-cost stage un-accelerated by WebGPU, and would add a
second model-maintenance burden (two independently-versioned exports) rather than
reducing one, cutting against this phase's own "reduce platform-specific complexity"
goal.

**Overall**: none of the three identified as a clear, low-risk proof-of-concept
candidate this phase — Demucs has the most promising (if unverified) lead; RoFormer/
MDXC/DrumSep have no existing lead at all. Do not read this as "not worth pursuing" —
read it as "the next phase, if it goes this direction, starts from independent
verification of the Demucs claim, not from a blank slate," per §L3.7.

### L3.7 Next-phase decision

Based on the evidence above, not a predetermined outcome:

**Recommended next experiment: independently verify the Demucs-to-ONNX community claim
(§L3.6) as a small, separately-scoped proof of concept — before any broader Windows/
NVIDIA/Intel hardware validation.** Rationale: L3's central finding (§L3.1) is that
WebGPU currently cannot help STEMwerk's *actual* users at all, because zero production
workflows use ONNX models — validating WebGPU on more platforms (Windows/NVIDIA/Intel)
would prove the backend works more broadly, which is real and valuable, but would still
leave the "helps zero current users" problem completely unsolved. A verified,
correctness-checked Demucs ONNX export (reusing this project's existing
`end_to_end_pipeline_test.py`/`webgpu_adapter.py` verification standard: real per-node
placement proof, raw-vs-file numeric comparison, stem routing, output validation) would
be the single highest-leverage next step, because it's the one finding that would let
WebGPU accelerate the workflow STEMwerk users actually run today (`htdemucs`/`All
Stems`), on any of the three already-proven platforms (Linux/AMD, macOS/Apple Silicon),
without waiting on new hardware.

Other candidates considered and explicitly deprioritized, with reasoning:
- *Broader ONNX model validation (remaining ~35 catalog models)*: low new-information
  value — §L3.2 already established they share one graph template; would mostly
  re-confirm what's already known rather than surface new risk.
- *Windows AMD/NVIDIA/Intel validation*: valuable for the cross-platform-vendor claim,
  but doesn't address §L3.1's core problem (still zero current STEMwerk users
  benefiting), and requires hardware this project doesn't have access to right now.
- *macOS validation of additional models*: same low-new-information issue as the first
  bullet, on the platform side instead of the model side.
- *Runtime packaging PoC*: §L3.5 already answered the open packaging questions with
  real data; a PoC installer change isn't blocked on new information, it's blocked on a
  product decision to actually adopt WebGPU for *something* — which circles back to
  needing §L3.1 solved first.
- *Experimental GPU backend integration (wiring WebGPU into STEMwerk's actual runtime
  resolver)*: premature — integrating a backend that cannot yet accelerate any real
  workflow would add maintenance surface for zero user-facing benefit, directly
  contradicting this phase's stated "reduce complexity" design goal.

### L3.8 Scope discipline (this phase)

No production venv, installer pin, model registry, GPU resolver, release branch, or
REAPER UI file was modified — all workflow/model tracing in §L3.1 was read-only
inspection via a background research agent plus direct `grep`/`Read`. No new branch was
created (continued on `experiment/webgpu-ep` as instructed). Both existing venvs
(`.venv-webgpu`, `.venv-rocmref`) remained functional throughout and were not otherwise
modified beyond downloading the 3 new `.onnx` model files (185.6 MB total) into the
experiment-local model cache — never STEMwerk's production model cache. No system
driver, Vulkan, or ROCm changes. No models were exported or converted (§L3.6 stayed
research-only, as instructed). No large audio/model files, benchmark JSON output, or
caches were committed.

## Phase L4: Demucs ONNX Feasibility

Status date: 2026-09-19. Starting HEAD `a9a274217` (pushed to origin before this phase
began, verified). Full report: **`DEMUCS_ONNX_FEASIBILITY.md`**. Central question:
Phase L3 found that zero current STEMwerk workflows use ONNX models — can the actual
model behind them (`htdemucs`, PyTorch, via `audio-separator`'s `DemucsSeparator`) run
through native WebGPU instead, using the exact same unmodified weights?

**Headline result: yes.** An independently-verified, real, unmodified community
`htdemucs` ONNX export (`StemSplit/demucs-onnx` on GitHub/PyPI, `StemSplitio/htdemucs-onnx`
on Hugging Face — checked out and run directly, not taken on faith: real repo, real
package, SHA256-verified artifact `68d0bf16...59a53`) runs on the RX 9070 with **1594/1594
graph nodes on WebGpuExecutionProvider, zero CPU fallback**, after finding and fixing a
real onnxruntime WebGPU-EP bug (`ConvActivationFusion` + the WebGPU `Conv` kernel;
worked around with `graph_optimization_level=ORT_ENABLE_BASIC`, now an optional
parameter on `webgpu_adapter.py`'s `patch_inference_session_for_provider_swap`,
backward-compatible with L1–L3). WebGPU output matches CPU-onnxruntime output on the
identical ONNX graph to within 1e-6–7e-6 (correlation ≥0.99999, all 4 stems) — a clean,
decisive pass. **Confirmed empirically**: this ONNX route needs no PyTorch at inference
at all (pure numpy + onnxruntime), a real potential path to replacing STEMwerk's
current per-vendor torch builds (CUDA/ROCm/MPS/DirectML) with one onnxruntime+WebGPU
install, for the Demucs-family workflow specifically.

**One real open question, not glossed over**: comparing the ONNX output against
STEMwerk's actual production PyTorch model showed a clean match on the dominant signal
(`other` stem, correlation 0.999990) but a noisy match on `drums`/`bass`/`vocals`.
Investigated directly — this repo's available test audio turned out to be a synthetic,
near-flat-energy clip with no real musical transients (confirmed by measuring
frame-to-frame energy variance, not assumed), making those three stems near-silent in
*every* run regardless of backend. The WebGPU-vs-CPU-ONNX comparison (same graph,
different EP) stayed clean on all 4 stems using the exact same signal, which points to
a test-signal artifact rather than a WebGPU-specific defect — but this experiment could
not fully rule out a real fidelity gap without a genuine multi-instrument test clip,
which wasn't available in this environment. **This is the recommended next step**,
ahead of any further hardware/platform validation.

## Phase L5: Demucs Real-Music Parity

Status date: 2026-09-19. Starting HEAD `008f7ebc8` (pushed to origin before this phase
began, verified). Full report: **`DEMUCS_REAL_MUSIC_PARITY.md`**. Directly resolves L4's
flagged open question by re-running the same PyTorch/ONNX-CPU/ONNX-WebGPU comparison on
genuine, dynamic multi-instrument content instead of L4's synthetic near-flat signal.

**Headline result: real-music parity holds, cleanly, once settings are controlled.**
Found real dynamic content in the user's own private local test fixtures (never
committed — `local/` is fully gitignored) and reconstructed a proxy mix from 4 already-
separated real stems (115× more dynamic than L4's signal, measured not assumed). With
`shifts=0` on both sides (a controlled, deterministic setting — Demucs' shift-averaging
isn't implemented in the community ONNX package at all, see below), **PyTorch and ONNX
CPU agree with correlation 0.997–0.9997 across all 4 stems**, and **ONNX CPU and ONNX
WebGPU agree with correlation ≥0.99999** — both a materially cleaner result than L4's
noisy synthetic-signal numbers. Graph placement re-confirmed: **1594/1594 nodes on
WebGPU, zero CPU fallback**, matching L4 exactly on real content. Stem routing is now
unambiguous (routing-matrix diagonal ≥0.9967 vs off-diagonal ≤0.062, vs L4's noisier
matrix). Also strengthened L4's model-identity question: STEMwerk's actual PyTorch
checkpoint (`955717e8-8726e21a.th`) carries Meta/FAIR's own self-checksummed filename
convention, directly verified to match its content hash.

**One real, disclosed gap remains**: comparing against STEMwerk's actual *production*
setting (`shifts=2`, Demucs' shift-based test-time averaging) rather than the controlled
`shifts=0` shows a larger gap — but a dedicated PyTorch-only diagnostic (`shifts=2` vs
`shifts=0`, no ONNX involved at all) produces a gap of nearly identical size, pointing
squarely at the missing shift-averaging feature in the community ONNX package (not an
export or WebGPU defect) as the explanation. Recommended next step: implement
shift-averaging around the existing ONNX session (a calling-code-only change, no model
edits) and re-verify — before further hardware/platform validation.

## Phase L6: Demucs Production Shift Parity

Status date: 2026-09-19. Starting HEAD `4a3809098` (pushed to origin before this phase
began, verified). Full report: **`DEMUCS_SHIFT_PARITY.md`**. Implements L5's identified
fix (Demucs shift-based test-time averaging, `shifts=2`, STEMwerk's actual production
default) as a small wrapper around the existing unmodified ONNX session, and re-measures
production parity with it enabled.

**Headline result: shift-averaging closes the gap to within PyTorch's own natural
run-to-run variance.** Demucs' shift-averaging is a Monte-Carlo technique — even real
production PyTorch doesn't produce bit-identical output run to run (verified directly:
two independent seeded PyTorch `shifts=2` runs differ from each other by
correlation 0.9975–0.9993). Measured against that honest noise floor rather than
against zero, the PyTorch-vs-ONNX-WebGPU gap with shifts enabled lands at **1.0×–1.7×
the noise floor** across the four stems (drums 1.01×, bass 1.11×, other 1.22×,
vocals 1.67×) — materially closer than L5's uncontrolled `shifts=2`-vs-`shifts=0`
comparison, and, for drums/bass, statistically indistinguishable from "just another
random realization" of production's own output.

**A genuinely interesting complication surfaced and fully root-caused, not glossed
over**: exact offset matching between PyTorch and ONNX via simple `random.seed()`
turned out to be impossible — HTDemucs' own positional-embedding code
(`transformer.py:559`) draws from the *same* global Python `random` stream during every
forward pass (a training-time augmentation left active at inference — the same
mechanism L4 identified as an ONNX-export blocker), so the two routes' RNG streams
drift apart after the first shift. Confirmed exactly: inserting the precise number of
intervening calls (3, matching the number of internal segments that particular shifted
window splits into) reproduces PyTorch's actual second offset bit-for-bit. Rather than
engineering a fragile RNG-lockstep workaround, this phase used the brief's own sanctioned
fallback — a repeated-run statistical comparison — which turned out to be the more
scientifically honest framing anyway, given `shifts=2` is inherently non-deterministic
in production itself.

WebGPU backend fidelity holds unchanged under shift-averaging (ONNX CPU vs WebGPU with
shifts: correlation 1.000000, all 4 stems; graph placement re-verified: 1594/1594 nodes,
0 CPU fallback, one session reused across all 6 internal inference calls across 3 repeated
runs). Speedup vs actual production settings drops from L4/L5's ~2.2× to **1.74×**
(shift-averaging roughly doubles ONNX-side inference work; the GPU's relative advantage
compresses somewhat, measured directly rather than assumed to persist). One residual,
honestly unresolved: `vocals`/`other` show a larger gap (1.22–1.67× the noise floor)
than `drums`/`bass` (1.01–1.11×) — plausibly the same export-fidelity pattern L5 already
found even without shifts, not a new shift-specific defect, but not proven either way.
Recommended next step: re-run this same methodology on a second, independent real-music
fixture to distinguish "a property of this model/export" from "a property of this one
clip," before macOS M1 validation.

## Phase L7: Independent Music Validation

Status date: 2026-09-19. Starting HEAD `0fae0d613` (pushed to origin before this phase
began, verified). Full report: **`DEMUCS_INDEPENDENT_MUSIC_VALIDATION.md`**. Does exactly
what L6 recommended: re-runs L6's methodology on a second, genuinely independent
real-music source, to test whether L6's `vocals`/`other` residual (1.22×–1.67× PyTorch's
own noise floor) is a property of the model/export or an artifact of L5/L6's one fixture
(itself a stem-sum reconstruction, not an original mix).

**Headline result: the L6 residual does not reproduce.** Found a second fixture
(`/home/flark/Music/modeltest.wav`, a personal STEMwerk test render, 25 s excerpt,
genuine original mix — a strictly better provenance category than L5/L6's
reconstructed one) and ran the identical repeated-run (3 seeds × PyTorch/ONNX-CPU/
WebGPU × `shifts=0`/`shifts=2`) design. Result: **every one of the four stems**,
including vocals and other, now shows a PyTorch-vs-ONNX-WebGPU gap *smaller* than
PyTorch's own run-to-run noise floor (ratio 0.66×–0.73×, uniformly — compare L6's
1.01×–1.67× with vocals as the worst case). This is evidence against, not proof against,
a general vocals/other weakness — two fixtures is more information than one, not a
statistical guarantee across all music — but it does support the hypothesis (raised as
a caveat back in L5) that the reconstructed-mix provenance of the earlier fixture, not
a structural property of the ONNX export, was the more likely driver of that residual.

**A real bug in this phase's own analysis code was caught before trusting any result**:
the first pass showed alarming negative correlations for `drums` even in the fully
deterministic `shifts=0` case, traced to a shape-orientation bug in the comparison
helper (computing array length from the wrong axis for PyTorch's `(samples, channels)`
arrays vs ONNX's `(channels, samples)`) — fixed and re-verified before any numbers were
reported, documented in full in the report rather than silently corrected.

WebGPU backend fidelity, graph placement (1594/1594 nodes, 0 fallback, 1 session reused
across all 7 internal inference calls), and regression against both L5 and L6 all hold
unchanged on this new fixture. Speedup vs actual production settings measured at 1.43×
on this clip (vs L6's 1.74× on the other — different absolute number, not reconciled,
reported honestly). Recommended next step: macOS M1 validation of this same
shift-averaging + real-music methodology, since the model-identity/export-fidelity
question is now reasonably well-characterized on this platform and further same-platform
fixtures have declining marginal value compared to testing a new GPU vendor/OS.

## Phase L8: macOS Apple Silicon Validation

Status date: 2026-09-19. Starting HEAD `c59c8e421` (L7, pushed to origin, verified
before this phase began — including that the earlier "Phase M1" MDX-Net commit,
`467c7ce`, is an ancestor). Full report: **`DEMUCS_MACOS_APPLE_SILICON.md`**. Does what
L7 recommended: validates the same, unmodified `demucs-onnx`/`webgpu_adapter.py`/
`demucs_shift_wrapper.py` implementation on macOS/Apple Silicon/Metal (MacBook Air M1,
8 GB unified memory) instead of accumulating further same-platform Linux fixtures.

**Headline result: technically works end-to-end, identically to Linux — but is
*slower* than STEMwerk's existing macOS production route, not faster.** Same
1594/1594-node zero-fallback WebGPU graph placement as L4 (the `ConvActivationFusion`
EP bug and its `ORT_ENABLE_BASIC` workaround both reproduce identically on Metal — an
onnxruntime-internal issue, not Vulkan-specific). Numerical parity is as strong as or
stronger than every prior Linux phase: `shifts=0` correlation 0.9967–0.9996 vs PyTorch
(comparable to L5), and — using a different, well-characterized substitute fixture
since L7's exact `modeltest.wav` isn't present on this machine, disclosed explicitly as
a real limitation — the L6 residual again fails to reproduce (all four stems' `shifts=2`
PT-vs-WebGPU gap below PyTorch's own noise floor, ratio 0.67×–0.80×, a *third*
independent piece of evidence against it being a general model property, now also
cross-platform).

**Where this phase diverges sharply from every prior one: performance.** WebGPU (49.08 s
warm, `shifts=2`) is ≈5.9× *slower* than STEMwerk's actual current production route
(PyTorch MPS, 8.28 s) on this machine, and even slower than plain ONNX CPU (28.14 s) —
the opposite of L4's Linux/RX-9070 result (WebGPU 2.2× faster than CPU there). This is
not treated as a regression or an implementation defect: no macOS-specific code change
was needed anywhere (every file used is byte-identical to what L4–L7 committed), and
WebGPU's own CPU-vs-WebGPU internal fidelity is untouched (correlation 1.000000,
matching L4/L6/L7 exactly) — the finding is that **WebGPU's advantage on Apple Silicon
is model/graph-dependent, not a platform-wide property**: the much simpler 185-node
MDX-Net graph *was* faster than CPU on this same M1 (see "Phase M1" above, 1.68×), while
Demucs' 1594-node graph is not. `demucs-onnx`'s own native CoreML provider was also
checked directly (not silently substituted for WebGPU) and fails to compile this
model's graph entirely — a separate, genuine compatibility gap.

**Practical conclusion: do not adopt ONNX/WebGPU-Demucs for STEMwerk's macOS production
path on the basis of this phase's evidence** — the existing PyTorch/MPS route already
wins on both speed and being the current, already-shipping reference. Recommended next
steps: root-cause the WebGPU-slower-than-CPU-on-M1 result before drawing a stronger
platform-level conclusion, and — if a cross-vendor WebGPU-Demucs route is still of
interest — pursue it on non-Apple-Silicon platforms where no comparably mature
first-party GPU backend already exists to lose to.

## Phase W1: Windows NVIDIA Validation

Status date: 2026-09-20. Starting HEAD `0e8d825fc` (L8, verified against
`origin/experiment/webgpu-ep` before this phase began). Full report:
**`DEMUCS_WINDOWS_NVIDIA.md`**. Validates the same, unmodified (three small,
Windows-only bug fixes aside — see below) `demucs-onnx`/`webgpu_adapter.py`/
`demucs_shift_wrapper.py` implementation on Windows/NVIDIA (RTX 3060 Laptop GPU),
this project's first Windows hardware and first genuinely new GPU-vendor validation
(NVIDIA) since L1.

**Headline result: technically works end-to-end on the actually-confirmed D3D12
backend (proven via live module-load evidence, not assumed from "it's Windows") —
185/185 MDX-Net nodes and 1594/1594 Demucs nodes on WebGPU, zero CPU fallback,
bit-for-bit-identical graph node counts to both Linux and macOS. But exactly like
macOS/MPS in L8, Demucs-WebGPU is measurably slower (≈4.8×) than STEMwerk's existing
production PyTorch/CUDA route on this hardware — the practical case for adopting it
over an already-shipping accelerated backend is now negative on two platforms, not
one.** Three genuine, previously-latent bugs in the shared adapter code were found
and fixed, none of them Vulkan- or Metal-specific: a `ctypes.CDLL(None)` fflush
crash that also silently left the process's real stderr fd un-restored, a UTF-16LE-
vs-UTF-8 log-decoding mismatch that would have made every Windows GPU-execution
proof a false negative, and a `ctypes.GetProcessMemoryInfo` call that silently
returned failure without a declared function signature. All three confirmed with
direct before/after evidence; none guessed. `select_device()`'s own device-matching
logic needed zero changes despite this being the project's first genuinely new
scenario (NVIDIA discrete + AMD integrated GPU on one machine) — the existing
`device_id` selector (added originally for Linux) was sufficient.

MDX-Net: WebGPU 5.17× faster than CPU (4-run warm benchmark), identical 185-node
placement to Linux/macOS. Demucs: WebGPU 1.39–1.75× faster than plain ONNX CPU (so
not "broken," just uncompetitive against CUDA specifically), 1594/1594 nodes, zero
fallback, numerical parity within the established tolerances (with one disclosed,
root-caused caveat: this phase's real-music fixture happens to be a mostly-
instrumental track, so its vocals/other-stem parity numbers are dominated by
near-silence, not export fidelity — see `DEMUCS_WINDOWS_NVIDIA.md` §6e).

See `DEMUCS_WINDOWS_NVIDIA.md` for full hardware/driver/version details, the D3D12
backend proof methodology, the complete numerical/performance tables, all code
changes with before/after evidence, and the cross-platform architecture assessment
(now covering Linux/AMD, macOS/Apple Silicon, and Windows/NVIDIA).

## Phase L9: AMD Radeon 780M Integrated GPU Validation

Status date: 2026-09-20. Starting HEAD `c59c8e421`; synchronized L8 (macOS) + W1
(Windows) first (`git merge --ff-only` to `2d1ed69d7`), then re-verified the RX 9070
baseline by actual execution (not diff-reading) before touching the 780M — no Linux
regression from W1's changes. Full report: **`RADEON_780M_IGPU_VALIDATION.md`**.

**Headline result: a genuine, reproducible, vendor-documented plugin limitation was
found, not a Radeon 780M defect — and not silently reported as a pass.** Device
*enumeration* correctly identifies the 780M (`vendor_id=0x1002 device_id=0x15bf
pci_bus_id=0000:69:00.0`, cross-verified against `lspci`/`vulkaninfo`). Device
*selection* — passing that exact device object to `add_provider_for_devices()`,
exactly as every prior phase has done — is **silently not honored**:
`onnxruntime-ep-webgpu` 0.3.0's own packaged README states plainly, *"The WebGPU EP
currently accepts one EP device and selects the physical GPU independently."*
Independent, kernel-level verification (`/sys/class/drm/card{N}/device/gpu_busy_percent`
— outside onnxruntime/Dawn/Vulkan entirely) confirms it: requesting the 780M for
either MDX-Net or Demucs still executes on the RX 9070 every time (93–98% RX 9070
engine load, 0% on the 780M), while onnxruntime's own log claims success regardless.
**Per the brief's explicit instruction, this is classified BLOCKED, not substituted
with RX 9070 numbers and reported as a pass** — no 780M performance, correctness, or
memory figures are reported, because none could be genuinely obtained.

A real memory/resource preflight was still completed (43 GB available RAM, 0 swap
configured, 780M's 512 MB dedicated VRAM backed by ~31 GB of GTT/system-RAM headroom)
and found no blocking constraint — moot once the selection blocker was established,
but retained for whenever a fixed plugin version becomes available.

**A genuinely important, disclosed methodological question this raises**: every prior
phase's "explicit GPU selection" (RX 9070 over the Phoenix iGPU on Linux, RTX 3060
over an AMD iGPU on Windows) requested the *same* adapter Dawn's own internal
default/power-preference logic would plausibly pick anyway — this phase is the first
case where the requested device diverges from that plausible default, and it's
exactly the case that failed. Prior results are not invalidated (their own regression
re-checks this phase and W1 both still hold), but "explicit selection genuinely
worked" cannot be fully distinguished from "coincided with the plugin's own default"
using only the evidence gathered so far. Recommended next step: apply this same
kernel/OS-level independent-verification technique to a prior platform (Windows, via
`nvidia-smi`) to check whether that selection was genuine or coincidental, before any
further hardware validation.

## Phase L10: Radeon 780M GPU Isolation

Status date: 2026-09-20. Starting HEAD `9faca2881` (L9); `git fetch origin` found no
new commits, no reconciliation needed. Full report: **`RADEON_780M_DEVICE_ISOLATION.md`**.

L9 found device *selection* silently unhonored by `onnxruntime-ep-webgpu` 0.3.0 on
this multi-GPU Linux box — requesting the 780M still executed on the RX 9070. This
phase asked whether a mechanism *outside* that broken API could force it anyway,
without touching the RX 9070's availability or any system-wide config.

**Result: yes, via `VK_LOADER_DEVICE_ID_FILTER`** — an official Vulkan-Loader env var
that genuinely hides the non-target GPU from a subprocess's Vulkan device list
(unlike `MESA_VK_DEVICE_SELECT`, confirmed to only *reorder* enumeration with zero
effect on actual execution). Confirmed at three independent levels — raw
`vulkaninfo`, real ONNX Runtime session creation, and kernel-level
(`/sys/class/drm/card{N}/device/gpu_busy_percent`) monitoring outside
onnxruntime/Dawn/Vulkan entirely — bidirectionally, in fresh processes.

**MDX-Net: full PASS on the genuine, physical Radeon 780M** — graph placement (185
nodes), numeric parity (bit-identical to every prior phase), stem routing, and output
validation all passed, with the RX 9070 confirmed idle throughout via independent
kernel monitoring. **Demucs: BLOCKED, root-caused rather than left unexplained** —
the full-length (16.7s) clip crashed with `VK_ERROR_DEVICE_LOST` partway through
genuine, correctly-isolated 780M execution; a 2s diagnostic clip completed
successfully on the same mechanism but took 221.5s (~114× slower than CPU on the same
clip), pointing to a Vulkan/kernel GPU-hang-detection timeout on an oversized
dispatch — a real hardware/driver throughput limit of this 1594-node graph on this
iGPU, not an isolation, compatibility, or memory failure. The RX 9070 was unaffected
and remained fully operational after the crash, as required.

**This is a Linux-specific, Vulkan-Loader-level workaround, not a portable fix** — no
claim is made about Windows (D3D12/DXGI) or macOS (Metal, and no multi-GPU case has
even arisen there — L8 was single-GPU). If ever adopted, it would need to be a
Linux-only device-selection adapter around the existing shared inference code, with
per-model capability gating (this phase's own evidence: fine for MDX-Net-class
graphs, not currently viable for Demucs-class graphs on a modest iGPU), not
implemented here per the brief's "no production integration" instruction.

## Phase L11: Capability Matrix & Experimental Backend Resolver

Status date: 2026-09-20. Starting HEAD `df1f4fe26` (L10, published in the prior turn);
`git fetch origin` found no new commits, both before starting and before committing.
Full report: **`BACKEND_CAPABILITY_RESOLVER.md`**.

Moves from isolated hardware tests to a working, model-aware **backend resolver**
prototype: given a model, platform, and the physical GPUs actually present, decides
whether STEMwerk's shared WebGPU route should be offered at all — not just whether it
technically runs. Not a CUDA/ROCm/MPS/DirectML replacement; WebGPU is offered only
where L1–L11 and N1's own evidence proves it correct, stable, and at least as fast as CPU.

**Built**: a machine-readable capability matrix (`capability_matrix.py`/`.json`,
originally 8 entries from L1–L10 and now 10 after adding N1's two Linux RTX rows,
distinguishing theoretical support,
actually-tested, found-correct, and suitable-for-Auto as four separate facts, never
collapsed); an experimental resolver (`backend_resolver.py`) that never silently
substitutes a different physical GPU than requested, never claims a GPU selection
succeeded without evidence, and lets Auto prefer an already-proven-superior vendor
backend (MPS on Apple M1, CUDA on RTX 3060) over WebGPU even where WebGPU itself would
otherwise qualify; a Linux-specific device-isolation adapter
(`linux_vulkan_isolation.py`) formalizing L10's proven `VK_LOADER_DEVICE_ID_FILTER`
mechanism; and `kernel_gpu_monitor.py`, L9/L10's own independent kernel-level
verification tooling promoted from scratch script to a reusable, committed module.

**22/22 automated policy tests pass** after focused N1 additions, covering every case
the brief required —
including the load-bearing one: Radeon 780M + Demucs under `Auto` resolves to
`BLOCKED`, not `PASS`, and an explicit request for that same combination is also
refused rather than silently rerouted to the RX 9070.

**Real Linux/AMD hardware validation**: RX 9070 + MDX-Net and Radeon 780M + MDX-Net
were both resolver-selected, actually executed, and independently kernel-verified in
this phase (a genuine mid-phase methodological fix was needed and disclosed: this
session's desktop background load was noisier than L9/L10's, so a fixed detection
threshold gave a false positive — fixed by measuring a fresh idle baseline immediately
before every test, exactly the discipline L9/L10 already used elsewhere). RX 9070 +
Demucs was resolver-selected; execution reuses L9's already-live-verified run rather
than repeating it. Radeon 780M + Demucs was, per the brief's explicit instruction, a
**negative policy test only** — confirmed BLOCKED without attempting execution, since
L10 already proved the crash and re-triggering it would add no new information.

**Architecture question answered**: technically feasible for a future STEMwerk runtime
to use one shared inference implementation with only limited platform-specific code
for device selection/packaging/monitoring — this is not speculative, L1–L11
collectively demonstrate it (the audio pipeline itself never changed across three
OSes; every genuine platform difference was small and isolated). Vendor backends can
stay available at STEMwerk's existing execution-provider injection point without
duplicating the pipeline. **Explicitly not the same as proven production
readiness**: Windows/macOS device-selection enforceability remains unverified, the
matrix covers only 2 of STEMwerk's many supported models, and the resolver itself is
experimental Python with no production wiring — see `BACKEND_CAPABILITY_RESOLVER.md`
for the full, undiluted limitations list.

## Phase N1: Linux NVIDIA/Vulkan Validation

Status date: 2026-09-20. Starting HEAD
`2d1ed69d76428bc04c47cdf16b273b2485a36aef` (W1 exactly), on the isolated local
branch `slice/webgpu-n1-linux-nvidia` while AMD Radeon 780M work proceeded concurrently.
Full report: **`DEMUCS_LINUX_NVIDIA.md`**. This controlled integration preserves the
subsequent L9-L11 history and adds N1 as separate Linux/NVIDIA/Vulkan evidence.

**Headline result: the exact shared native WebGPU implementation works on the NVIDIA
RTX 3060 Laptop GPU under Linux/Vulkan, with no NVIDIA/Linux-specific inference code.**
Explicit PCI selection requested `0000:01:00.0` rather than the AMD Renoir iGPU;
runtime process maps showed the Vulkan loader, NVIDIA ICD libraries, and NVIDIA device
nodes, and live `nvidia-smi` attributed the Demucs process to the RTX 3060. That proves
physical RTX execution, but not that the request causally selected it rather than
Dawn's default. L10 separately proved that `VK_LOADER_DEVICE_ID_FILTER` can enforce a
non-default Linux/Vulkan device. Negative tests for ambiguous and nonexistent devices
both failed loudly as designed.

- MDX-Net: 185/185 WebGPU nodes, zero fallback, full two-stem pipeline and routing
  PASS, raw CPU/WebGPU max error `4.77e-07`; warm WebGPU 2.083 s vs CPU EP 12.045 s
  on a 20 s fixture (5.78x, RTF 9.6x).
- Demucs: exact established artifact SHA-256 `68d0bf16...fcc5e74`, 1594/1594 WebGPU
  nodes, zero fallback, four-stem export/routing PASS, CPU/WebGPU correlation at least
  0.999999996. The cross-backend `ConvActivationFusion` failure reproduces under
  NVIDIA/Vulkan with `ORT_ENABLE_ALL`; the existing `ORT_ENABLE_BASIC` workaround
  remains required and sufficient.
- Demucs performance: warm `shifts=2` WebGPU 14.144 s vs ONNX CPU 28.578 s (2.02x,
  RTF 1.41x), but about 5.9x slower than the installed warm PyTorch/CUDA production
  route (~2.40 s). This matches W1/L8's practical conclusion: keep mature vendor
  routes where they exist; WebGPU's demonstrated value is one maintainable optional
  cross-platform implementation, not maximum vendor-specific performance.

N1 added an explicit optional MDX `--torch-device` control because current Linux
`torch==2.14.0` auto-selected CUDA for STFT/iSTFT, an explicit Linux NVIDIA resource
monitor choice in `benchmark_resources.py`, and a reusable SHA-gated
`demucs_validation.py`. Defaults remain backward-compatible. No model, production
runtime, installer, driver, or shared adapter/shift algorithm was changed.

## Phase W2: Windows Multi-GPU Physical Device Selection

Status date: 2026-09-20. Starting HEAD `f8588f7b4` (N1 integration), verified against
`origin/experiment/webgpu-ep` before this phase began. Full report:
**`WINDOWS_MULTI_GPU_SELECTION.md`**. Directly resolves the question W1 explicitly left
open (§4 of `DEMUCS_WINDOWS_NVIDIA.md`: "did NOT prove that the explicit GPU selector
caused the RTX 3060 to be selected rather than Dawn's default choice") and that L9
explicitly recommended as its most actionable next step: re-verify a prior "successful"
device selection with independent, kernel/OS-level tooling, now that its value had been
demonstrated on Linux.

**Headline result: Dawn's own default, not the request.** This laptop has two real,
distinct GPUs — NVIDIA GeForce RTX 3060 Laptop GPU (discrete) and AMD Radeon(TM)
Graphics (integrated, PCI `VEN_1002&DEV_1638`) — confirmed via WMI, the DXGI adapter
registry, `nvidia-smi`, and `webgpu_adapter.list_webgpu_devices()`, all agreeing. An
explicit, correctly-resolved request for the AMD iGPU (`select_device(device_id=5688)`)
still executed on the RTX 3060 — independently confirmed by OS-level per-process GPU
Engine performance counters keyed to DXGI adapter LUID (0 samples on the iGPU's LUID,
sustained RTX 3060 activity, reproduced in 2 fresh processes), by `nvidia-smi` whole-GPU
utilization jumping 0%→52.3% specifically during the iGPU-requested WebGPU phase (nearly
identical to the RTX-3060-requested run's 53.2%), and by bit-identical raw numeric output
and statistically indistinguishable timing between the two requests. This is the
Windows/D3D12 counterpart to L9's Linux/Vulkan finding, for the same `onnxruntime-ep-webgpu`
0.3.0 package, whose own packaged README states, platform-generically: *"The WebGPU EP
currently accepts one EP device and selects the physical GPU independently."*
**Device-selection enforcement is FAIL on Windows/D3D12 for this plugin version.**

A dedicated Windows monitoring methodology was built for this (`windows_gpu_monitor.py`,
`w2_monitored_run.py`, `w2_device_selection_probe.py`) — the closest Windows analogue to
L9/L10's Linux kernel-sysfs monitoring, reading the same `\GPU Engine(*)` performance-
counter object Task Manager's own GPU column uses, cross-checked against
`HKLM\SOFTWARE\Microsoft\DirectX`'s independent adapter-LUID registry. A real, disclosed
tool limitation was found along the way: this per-process counter reliably caught a dense,
repeated-inference workload, but did not reliably catch the real MDX-Net pipeline's
shorter, burstier WebGPU calls — the decisive finding rests on the dense-probe method
(same real device-selection code) plus `nvidia-smi` whole-GPU correlation and the
numeric/timing identity check for the full pipeline, not on a single all-purpose tool.

W1's own RTX 3060 baseline was re-confirmed first (185/185 nodes, numerics bit-identical
to W1's own recorded figures, 5.10× warm speedup) — no regression. A binary-level search
of the installed `onnxruntime_providers_webgpu.dll` confirmed no Windows analogue of
Linux's `VK_LOADER_DEVICE_ID_FILTER` environment variable exists (explicitly refuted, not
assumed) — but did find that Dawn's own D3D12 backend natively supports LUID-based adapter
targeting (`RequestAdapterOptionsLUID`, `EnumAdapterByLuid`) which `onnxruntime-ep-webgpu`
0.3.0's Python-facing device-selection API simply does not thread through to. The Windows
per-app Graphics Settings preference registry key was identified as a real but
out-of-scope mechanism (persistent, per-executable-path, not process-local) and was
investigated but not applied. Because iGPU execution was never positively established —
it was affirmatively disproven — full iGPU MDX-Net validation and conditional Demucs
validation are both **BLOCKED / NOT TESTED**, per the mission's own instruction not to
substitute RTX 3060 results and report them as an iGPU pass.

The capability matrix's two existing Windows RTX 3060 rows were updated from "UNKNOWN /
NOT PROVEN" to a `DISPROVEN` device-selection-enforcement verdict (their correctness/
performance facts are unchanged — the RTX 3060 genuinely does execute both models
correctly); a new row records the Windows AMD iGPU MDX-Net result as `found_correct=False`
with a `FAIL` selector verdict. `backend_resolver.py` needed no code change — its existing
platform-based isolation check already treated Windows multi-GPU selection as
unenforceable by default, now backed by a confirmed rather than absent-evidence reason;
7 new W2 policy tests assert this against the real hardware's `GpuInfo` objects. Running
the full test suite on Windows for the first time also surfaced a genuine, previously-
latent test/module coupling (two pre-existing Linux-isolation-plan tests assume a real
Linux host to build their env-var plan) — fixed by skipping those two specific cases on a
non-Linux host with the reasoning printed, not by changing `backend_resolver.py` or
`linux_vulkan_isolation.py`'s own logic. 27/27 non-skipped policy tests pass.

See `WINDOWS_MULTI_GPU_SELECTION.md` for the full hardware/driver/version inventory, the
monitoring methodology and its disclosed limits, the decisive test's complete evidence
(§5, with per-claim PASS/FAIL verdicts kept separate rather than one ambiguous "GPU
selection PASS"), the negative controls, the full device-isolation mechanism search
(§7), and the capability-matrix/resolver implications (§10).

## Phase W3: Windows Native Device-Selection Source Investigation

Status date: 2026-09-20. Full report: **`WINDOWS_NATIVE_DEVICE_SELECTION.md`**. Goes
one level deeper than W2's binary-only scan: locates and reads the **actual upstream
source** for the installed `onnxruntime-ep-webgpu` 0.3.0 package, at the exact tagged
release (`plugin-ep-webgpu/v0.3.0`, commit `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`),
not current `main`.

**Root cause confirmed at the exact source line.** `Factory::CreateEpImpl`
(`onnxruntime/core/providers/webgpu/ep/factory.cc:150-219`) reads the caller-selected
`OrtHardwareDevice` exactly once — to check an `IsVirtual` metadata flag — and never
again; its vendor id/device id/LUID is never copied into the config passed down to
`WebGpuContext::Initialize()` (`webgpu_context.cc:42-104`), which builds Dawn's
`wgpu::RequestAdapterOptions` with only `backendType` and `powerPreference` populated
(default `WGPUPowerPreference_HighPerformance`). Dawn's D3D12 backend then always
returns the platform's high-performance-ranked adapter — the RTX 3060 on this machine,
matching W2's own `DxgiHighPerformanceIndex=0` finding — regardless of which device
Python selected. A pre-existing, confusingly-named provider option
(`ep.webgpuexecutionprovider.deviceId`) was traced and confirmed to be a **logical
WebGpuContext cache-slot index for cross-session device sharing**, not a physical
hardware selector — explaining why W2's empirical `extra_options` probing of
`device_id`-shaped keys had no effect.

Dawn's own D3D12 native API already supports the missing capability: reading Dawn's
actual pinned-tag source (`google/dawn@v20260714.215939`, the exact revision pinned in
onnxruntime's own `cmake/deps.txt` at the tagged commit, not Dawn `main`) confirms
`dawn::native::d3d::RequestAdapterOptionsLUID` (`include/dawn/native/D3DBackend.h`) is
a real, exported, chainable struct (`::LUID adapterLUID`) — and is already compiled
into the installed DLL (confirmed independently via binary string extraction, since
Dawn source paths and the `RequestAdapterOptionsLUID` symbol are both embedded in it).
It is simply never constructed or chained anywhere in the EP's call path.

A minimal, source-grounded patch (one new provider-option key, one new optional config
field, ~15-20 lines across 4 existing upstream files, reusing the EP's existing
fail-closed `ORT_ENFORCE` on adapter-request failure) is proposed and documented in
full, but **not implemented or built**: this machine has no CMake and no Visual Studio
installation at all (checked directly, not assumed), so a native ONNX Runtime/Dawn
build is not feasible in this session. No new GPU-execution tests were run this
phase — W2 already obtained decisive, reproduced, per-process evidence for the
underlying selection-enforcement question using the exact code path this phase's
source reading confirms is the only call path into the plugin EP; re-running it against
the same unmodified binary would add no new information. `capability_matrix.json`/`.py`
are **unchanged** this phase — no new hardware/model combination was actually
validated (source-level investigation only), consistent with the mission's own
instruction not to mark anything PASS without real execution proof.

**Classification: NOT VERIFIED** (source-level root cause and patch proposal
established; no native build attempted or tested; L1-L11/N1/W1/W2 results all
preserved unchanged). See `WINDOWS_NATIVE_DEVICE_SELECTION.md` for the full traced data
flow with exact file/line references, the Dawn API availability findings, the complete
patch proposal, cross-platform compatibility analysis (Linux/L10 and macOS/M1
unaffected), and the explicit list of unverified assumptions and open items (most
notably: the exact core-ORT function that attaches a Windows LUID to `OrtHardwareDevice`
metadata was not located this session, and whether Dawn's D3D12 backend actually
rejects a non-matching LUID rather than silently ignoring it was not empirically
tested).

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
