# WebGPU EP experiment — native ONNX Runtime WebGPU Execution Provider on Linux/AMD

Status date: 2026-09-19. Experimental, opt-in, isolated. Not integrated into STEMwerk.

## 1. Repository, branch, worktree, base SHA

- Canonical checkout (untouched): `/mnt/PRODUCTION/GIT/STEMwerk` (left exactly as found,
  including its pre-existing uncommitted changes on `ci/repair-stale-release-checks`).
- Branch: `experiment/webgpu-ep`
- Worktree: `/mnt/PRODUCTION/GIT/STEMwerk-worktrees/webgpu-ep`
- Base SHA: `c0f1d3294` (`origin/main`, PR #124 "2.3.1.2-main-reconcile"). Chosen over the
  local `main` ref (`c1db7042c`, stale/behind) and over the current CI branch HEAD
  (`57434e97f`, which is actually an ancestor of `main` — fully merged already) because
  `origin/main` is the most current published, stable state and includes the 2.3.1.2
  MDXC-reconstruction fixes relevant to ONNX/DrumSep code.
- No merges, rebases, cherry-picks, or edits to any existing branch were performed.
  No `git push`.
- Venv: **not** at the brief's suggested in-worktree path. `/mnt/PRODUCTION` is an
  **exFAT** filesystem (`mount` confirms `type exfat`) and does not support symlinks;
  `python -m venv` unconditionally symlinks `lib64 -> lib` on Linux, so venv creation
  fails there regardless of `--copies`. The venv instead lives at
  `/home/flark/stemwerk-rnd/venvs/webgpu-ep/.venv-webgpu` (ext4), matching the existing
  project convention of keeping R&D worktrees/venvs under `/home/flark/stemwerk-rnd/`.
  No production venv, Python installation, or ROCm component was touched.

## 2. STEMwerk architecture findings relevant to this experiment

STEMwerk itself never constructs an ONNX Runtime `InferenceSession` or references a
GPU-vendor onnxruntime execution provider anywhere in its own source. All inference is
delegated to the third-party `audio-separator` PyPI package:

- `scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/separator.py` and
  `scripts/reaper/_internal/stemwerk_drumsep_process.py` only *configure* the
  `Separator` instance (`separator.onnx_execution_provider = [...]`, `torch_device`);
  they never call `InferenceSession` directly.
- Only `CPUExecutionProvider` and `DmlExecutionProvider` strings appear anywhere in
  STEMwerk source. On Linux, the CUDA/ROCm GPU path goes through PyTorch
  (`torch.cuda`/HIP) plus `onnx2torch` graph conversion, not an onnxruntime GPU EP —
  MDXC/Roformer models in particular are `.ckpt` files run entirely via PyTorch.
- No WebGPU reference of any kind exists in STEMwerk source (only inside a vendored
  `.venv` snapshot under `validation-backups/`, i.e. generic upstream onnxruntime
  wheel internals, not STEMwerk code).
- There is no single "GPU resolver" module; device selection is split across
  `stemwerk_core/devices.py` (`get_available_devices`/`select_device`),
  `audio_separator_process.py` (backend-token mapping), and
  `stemwerk_drumsep_process.py` (`_probe_gpu_device`, `_apply_separator_requested_device`).
- **Correction to the brief's candidate list**: `UVR_MDXNET_KARA_2` is confirmed as a
  real ONNX model (`UVR_MDXNET_KARA_2.onnx`, MDX-Net family, run via onnxruntime).
  `MDX23C-8KFFT-InstVoc_HQ` is **not** ONNX — it is `MDX23C-8KFFT-InstVoc_HQ.ckpt`
  (PyTorch checkpoint), part of the MDXC/Roformer family that `audio-separator` runs
  via `onnx2torch`/PyTorch, not onnxruntime. It was therefore out of scope for an
  onnxruntime-EP test and `UVR_MDXNET_KARA_2.onnx` was used instead.

**Because STEMwerk never touches onnxruntime provider selection directly**, this
experiment runs entirely standalone, outside STEMwerk's production code path, using
`audio-separator` (the same library, same version family STEMwerk depends on) directly,
with `onnxruntime.InferenceSession` monkeypatched at the Python level (see
`benchmark_mdx_kara2.py`) so that CPU and WebGPU runs share byte-identical
preprocessing/postprocessing (STFT, chunking, overlap-add) — only the execution
provider differs.

## 3. Native WebGPU EP — what actually exists (2026-09-19)

Two distribution routes exist on PyPI for Linux x86-64:

1. **`onnxruntime` + `onnxruntime-ep-webgpu`** (plugin-EP architecture, the officially
   documented route — <https://onnxruntime.ai/docs/execution-providers/WebGPU-ExecutionProvider.html>).
   Requires base `onnxruntime>=1.24.4`. `onnxruntime-ep-webgpu` 0.3.0 ships a
   `manylinux_2_28_x86_64` wheel (Python ≥3.11) containing a standalone
   `libonnxruntime_providers_webgpu.so`, registered at runtime via
   `ort.register_execution_provider_library(...)`. **This is the route used here.**
2. **`onnxruntime-webgpu`** 1.27.0 — a monolithic alternative build with WebGPU baked
   in (analogous to how `onnxruntime-gpu` bundles CUDA). Not used in this experiment;
   noted as an alternative worth trying if the plugin route regresses in a future
   onnxruntime release.

On Linux, Dawn (Google's WebGPU implementation) dispatches through **Vulkan**. A system
Vulkan loader (`libvulkan.so.1`) is required — already present on this machine
(`ldconfig -p` confirms it, part of the existing Mesa/RADV stack) — **no system
packages, drivers, or kernel changes were needed or made.**

System stack found (read-only, unmodified):
- GPU: AMD Radeon RX 9070 (Navi 48, RDNA4), PCI `0000:03:00.0`, plus a Phoenix1 iGPU
  at `0000:69:00.0` (must be explicitly excluded by PCI bus id — see below).
- Driver: Mesa 26.2.2 (RADV), Vulkan instance 1.4.357, kernel 6.18.52-lts, EndeavourOS
  (rolling). Current enough to have full RDNA4 support.
- `vulkaninfo` reports RADV's own disclaimer: *"radv is not a conformant Vulkan
  implementation, testing use only."* This is Mesa's standard self-declared
  conformance-suite status, not a fault produced by this experiment — WebGPU EP
  functioned correctly regardless (see §5 numerical validation) — but it should be
  understood before making any GPU-vendor-parity claims from Linux/RADV testing.

**Multi-GPU caveat (undocumented pitfall, worth flagging upstream):** `ort.get_ep_devices()`
enumerates *all* WebGPU-capable adapters. On this dual-GPU machine it returned two
`WebGpuExecutionProvider` devices; nothing defaults to the "best"/discrete one. The
device must be selected explicitly and deliberately, e.g. by matching
`device.metadata['pci_bus_id']` (confirmed against `lspci`) or `device.device_id`
(`30032` / `0x7550` = RX 9070 vs `5567` / `0x15BF` = Phoenix iGPU). A benchmark that
picks `ep_devices[0]` naively could silently run on the iGPU.

**Confirmed incompatibility with audio-separator's own provider selection API:**
`MDXSeparator.load_model()` (in `audio_separator/separator/architectures/mdx_separator.py`)
creates its session with the classic `ort.InferenceSession(path, providers=self.onnx_execution_provider, ...)`
call. Passing `["WebGpuExecutionProvider"]` through this **legacy string-list API does
NOT activate the plugin EP** — it silently falls back to `CPUExecutionProvider` (audio-separator
does at least emit a warning about the mismatch, though the wording incorrectly blames
"CUDA/cuDNN"). The plugin-EP architecture requires the newer device-targeted
`SessionOptions.add_provider_for_devices([...], {})` call. This is exactly the kind of
"looks like GPU, silently runs on CPU" trap flagged in
[microsoft/onnxruntime#22077](https://github.com/microsoft/onnxruntime/issues/22077) (multiple
users report ops like Reshape/Gather/Concat/Slice falling back to CPU with *worse* than
CPU performance) — this experiment's `benchmark_mdx_kara2.py` works around it with a
monkeypatch (documented in the script's docstring); a real STEMwerk integration would
need an equivalent patch or an upstream fix to `audio-separator`.

## 4. First experiment — Linux RX 9070

Model: `UVR_MDXNET_KARA_2.onnx` (MDX-Net, 52.8 MB), downloaded through
`audio-separator`'s normal model-catalog mechanism into an experiment-local cache dir
(`model_file_dir`), not STEMwerk's production model cache.
Input: a real 20 s / 44.1 kHz / stereo WAV (an existing local smoke-test artifact
output, not committed to this repo — see "Reproducing" below for how to substitute
your own).

| Checkpoint | Result |
|---|---|
| EP beschikbaar | **PASS** — plugin registers; 2 GPU devices enumerated (RX 9070 + iGPU) |
| EP initialisatie geslaagd | **PASS** — `InferenceSession` succeeds targeting `pci_bus_id=0000:03:00.0` |
| Model geladen | **PASS** — real 52.8 MB MDX-Net ONNX model loads without error |
| GPU-inferentie aangetoond | **PASS, verified per-node** — onnxruntime's own verbose log: *"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185"* for the full real model graph. Zero CPU-fallback nodes. GPU kernel dispatch log shows real `Conv2dMM`, `ConvTranspose2D`, `BatchNormalization`, `MatMul`, `Transpose` programs running (not just session creation) |
| End-to-end audioseparatie geslaagd | **PASS** — produced `(Vocals)` and `(Instrumental)` WAV stems, same file count/naming as the CPU EP run |
| Numerieke output gevalideerd | **PASS** — vs CPU EP baseline: max abs diff 3.05e-5, mean abs diff ~1e-8, RMS difference 0.0000%, correlation 1.0000000000 (Vocals) / 0.9999999998 (Instrumental) — well within float32 accumulation-order tolerance |

A synthetic single-Conv-node sanity probe (`webgpu_ep_probe.py`) was run first as a
smaller, independent confirmation before the real model, with the same PASS pattern
(all 3 nodes on WebGPU, max abs diff 1.9e-6 vs CPU).

## 5. Benchmark

Same ONNX model, same audio input, same `audio-separator` preprocessing/postprocessing
for both providers (this is a **backend comparison on an identical ONNX graph**, not a
comparison of different STEMwerk pipelines — the existing torch/ROCm production path
uses a different model family and different code entirely, so it is *not* directly
comparable here and no such comparison is claimed).

| Metric | CPU EP | WebGPU EP (RX 9070) |
|---|---|---|
| Initialisatietijd (session load) | ~0.9–4.7 s (varied run to run) | ~0.9–1.0 s |
| Processing time, cold (first run incl. shader compile) | ~8.2 s | ~2.0 s |
| Processing time, warm (steady-state avg of 3 repeats) | ~6.0–9.1 s (see note) | ~1.45–1.49 s |
| Real-time factor, warm (20 s audio) | ~2.2–3.3x | ~13.4–13.8x |
| RMS / correlation vs CPU | reference | corr ≈ 1.0, RMS diff 0.0000% |
| CPU-fallback nodes | n/a (100% CPU by definition) | **0 / 185** |

Note on CPU timing variance: two separate benchmark runs on this machine gave warm CPU
averages of ~5.98 s and ~9.1 s for the same model/input; this looks like ordinary
background system load/scheduling noise on a desktop machine, not a methodology
difference (thread pool config, input, and model were identical). Reported as a range
rather than a single number for honesty. The WebGPU numbers were stable (~1.45–1.49 s)
across the same runs.

**VRAM**: `rocm-smi` shows ~1.5 GB used on the RX 9070 immediately after a run
completed (idle baseline includes desktop compositor usage, not isolated to this
process) — a peak-during-inference sampler was not built, so this is a rough
post-hoc reading, not a validated peak measurement. **NOT TESTED** to a rigorous
standard; flagged rather than reported as a clean PASS number.

**System RAM**: not instrumented in this pass. **NOT TESTED.**

## 6. Second platform (macOS M1) — preparation only

**NOT TESTED** — no macOS execution occurred, in line with the brief's instruction not
to report a macOS PASS without running on the actual M1.

What this experiment did to stay portable:
- `TARGET_PCI_BUS_ID` in `benchmark_mdx_kara2.py` is the only Linux/AMD-specific
  assumption (device selection); on macOS, WebGPU EP devices would need to be selected
  differently since Dawn dispatches through Metal, not Vulkan, and there is no
  `pci_bus_id` metadata field for Apple Silicon's integrated GPU — this selection logic
  will need a platform branch.
- `onnxruntime-ep-webgpu` 0.3.0 does ship a `macosx_14_0_universal2` wheel, so the pip
  install step should carry over unchanged (`pip install "onnxruntime>=1.24.4" onnxruntime-ep-webgpu`).
- 8 GB unified memory on the M1 is a real constraint against this 52.8 MB model plus a
  full PyTorch/audio-separator dependency stack; not evaluated here.
- The rest of the benchmark script (model loading, timing, numeric comparison) is
  already platform-generic Python/numpy/soundfile and should need no changes.

## 7. Scope discipline

No production venv, installer pin, model registry, GPU resolver, release branch, or
REAPER UI file was modified. No CUDA/ROCm/DirectML/MPS code was touched or removed. No
new dependency was added to the existing STEMwerk distribution — `onnxruntime-ep-webgpu`,
`onnxruntime`, `audio-separator`, etc. exist only inside the isolated
`/home/flark/stemwerk-rnd/venvs/webgpu-ep/.venv-webgpu` venv. Nothing was pushed,
merged, or opened as a PR.

## 8. Open issues / upstream limitations

- Operator coverage beyond what this one model exercises (Conv2d family, BatchNorm,
  MatMul, Transpose, elementwise) is unverified — the GitHub tracking issue reports
  CPU fallback for Reshape/Gather/Concat/Slice/Where/Equal in *other* models; those ops
  did not appear as separate graph nodes in this particular MDX-Net model's exported
  graph (likely fused away by onnxruntime's graph transformers), so this PASS should
  **not** be generalized to every MDX/MDXC/VR-Arch model in STEMwerk's catalog without
  testing each one individually.
- MDXC/Roformer models (`.ckpt`, PyTorch/onnx2torch path) are entirely outside this
  EP's scope as currently used by `audio-separator` — a WebGPU EP path for those would
  require either exporting them to ONNX first or a different integration point
  entirely (out of scope here, per the brief).
- `audio-separator`'s own provider-selection code cannot activate a plugin EP without
  a patch (§3) — this is worth raising upstream with the `audio-separator` maintainers
  rather than treating it as WebGPU EP's fault.
- Mesa RADV self-reports as a non-Khronos-conformant Vulkan implementation; results
  here should not be read as proof of behavior on a conformant Vulkan/Dawn stack.

## Reproducing this experiment

```bash
# 1. venv (must be on a POSIX filesystem, NOT exFAT)
python3.11 -m venv /path/to/.venv-webgpu
source /path/to/.venv-webgpu/bin/activate
pip install -r requirements-webgpu-experiment.txt

# 2. cheap sanity probe (no real model / audio needed)
python webgpu_ep_probe.py

# 3. real model benchmark (needs a real WAV file as input)
python benchmark_mdx_kara2.py /path/to/some.wav --runs 4
```

If your machine has more than one GPU, or a different AMD card, override the target
device: `WEBGPU_EP_TARGET_PCI_BUS_ID=0000:xx:00.0 python benchmark_mdx_kara2.py ...`
(find the right bus id with `lspci -nn | grep -i vga`).
