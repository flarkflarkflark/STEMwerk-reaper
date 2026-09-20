# ONNX Runtime WebGPU — Linux NVIDIA Validation (Phase N1)

Status date: 2026-09-20. This phase validates the W1 implementation on the same
NVIDIA RTX 3060 Laptop GPU under Linux/Vulkan rather than Windows/D3D12. It was
performed on the isolated local branch `slice/webgpu-n1-linux-nvidia`, starting at
exactly W1 commit `2d1ed69d76428bc04c47cdf16b273b2485a36aef`. The concurrent AMD
Radeon 780M/L9 result became available at remote commit `9faca288` only after N1's
first completion commit. Its report was then read without merging/cherry-picking it;
the post-completion coordination implications are included below. During the later
controlled integration, L10 and L11 were preserved: L10 proved that Linux/Vulkan can
enforce a non-default physical GPU with `VK_LOADER_DEVICE_ID_FILTER`, while keeping
the separate N1 conclusion that its requested-PCI selector was not causally proved.

**Result: PASS for both MDX-Net and Demucs.** The existing adapter required no
NVIDIA/Linux-specific inference change. Explicit PCI selection requested the RTX 3060,
and independent runtime evidence proved execution actually occurred there; after L9,
this is not claimed to prove the plugin honored the request rather than independently
choosing the same discrete GPU. Runtime evidence confirmed Vulkan plus NVIDIA's
ICD/device nodes, MDX-Net placed
185/185 nodes and Demucs placed 1594/1594 nodes on WebGPU, and both performed real
inference with zero CPU fallback. Demucs WebGPU was 2.02x faster than ONNX CPU but
about 5.9x slower than STEMwerk's existing warm PyTorch/CUDA production route.

## 1. Git and host isolation

- Canonical checkout: `/home/flark/GIT/STEMwerk`, left untouched, including its
  pre-existing untracked `.worktrees/` and `gpu_check.json`.
- The configured `origin` URL is `git@github.com:flarkflarkflark/STEMwerk.git`.
  The requested repository was queried and fetched explicitly as
  `git@github.com:flarkflarkflark/STEMwerk-reaper.git`.
- Requested remote experiment SHA at preflight:
  `2d1ed69d76428bc04c47cdf16b273b2485a36aef`, exactly W1. It had not advanced to
  L9 and had not moved backward or diverged.
- Final coordination check: the remote advanced concurrently to `9faca28818f8e29ae45fcb89d69a4b51362f8ac0`
  (L9). N1 remained based on W1 exactly; no L9 file or commit was integrated.
- N1 worktree: `/home/flark/GIT/STEMwerk-worktrees/webgpu-n1-linux-nvidia`.
- Local-only branch: `slice/webgpu-n1-linux-nvidia`, created directly from W1.
- No push, merge, rebase, cherry-pick, reset, or edit to `experiment/webgpu-ep`.
- All environments, models, audio, JSON, WAVs, and logs were kept under
  `/home/flark/stemwerk-n1/`, outside Git.

One output-path trap was caught during the production CUDA reference: the installed
production `audio-separator==0.23.0` wrote four generated Demucs WAVs to the process
working directory despite the supplied `output_dir`. They were detected immediately,
moved to `/home/flark/stemwerk-n1/outputs/cuda-reference/`, and the reference was
re-run with that external directory as its working directory. No generated audio
remained in the worktree and no tracked/pre-existing file was overwritten.

## 2. Hardware and software

| Property | Actual value |
|---|---|
| Distribution | Arch Linux (rolling) |
| Kernel | `7.2.4-arch1-2`, x86-64 |
| CPU / RAM | Ryzen 7 5800H, 16 logical CPUs / 30 GiB RAM, no swap |
| Target GPU | NVIDIA GeForce RTX 3060 Laptop GPU, GA106M, PCI `0000:01:00.0`, device `10de:2520` |
| NVIDIA memory | 6144 MiB reported by `nvidia-smi` |
| NVIDIA driver | `610.57.04`; CUDA UMD 13.3 |
| NVIDIA Vulkan ICD | `/usr/share/vulkan/icd.d/nvidia_icd.json` -> `libGLX_nvidia.so.0` |
| Vulkan | loader instance 1.4.357; NVIDIA physical-device API 1.4.341, conformance 1.4.3.3 |
| Other GPU | AMD Radeon Graphics (Renoir/Vega iGPU), PCI `0000:06:00.0`, RADV/Mesa 26.2.2 |
| Experiment Python | CPython 3.11.16, x86-64 |

The target and iGPU were both left enabled. No driver, kernel module, CUDA install,
Vulkan ICD, or system Python was modified.

## 3. Isolated environments and dependency footprint

| Environment | Contents | Installed size |
|---|---|---:|
| `/home/flark/stemwerk-n1/venvs/webgpu` | checked-in MDX requirements | 6.1 GiB |
| `/home/flark/stemwerk-n1/venvs/demucs-onnx` | Demucs ONNX/WebGPU only, no torch | 255 MiB |

The MDX environment contains `onnxruntime==1.30.0`,
`onnxruntime-ep-webgpu==0.3.0`, `onnx==1.23.0`, `numpy==2.4.6`,
`audio-separator==0.47.0`, and `torch==2.14.0`. Important 2026 Linux packaging
observation: the generic PyPI torch wheel now pulled CUDA 13 packages. Installed
footprints were approximately 1.2 GiB for torch and 3.2 GiB for its `nvidia/`
components, versus 67 MiB for onnxruntime and 16 MiB for the WebGPU plugin. Relevant
compressed wheel downloads included torch 554.6 MB, cuDNN 553.1 MB, onnxruntime
23.6 MB, and the WebGPU plugin 6.6 MB. This explains the unexpectedly large 6.1 GiB
environment; those CUDA packages are not a WebGPU requirement in principle.

The Demucs environment contains `demucs-onnx==0.3.4`, onnxruntime/WebGPU/ONNX,
numpy, soundfile, soxr, and Hugging Face download support. It contains no torch and
still completed all separation runs.

## 4. Device selection and Vulkan proof

WebGPU enumeration returned two adapters:

```
vendor_id=4318 device_id=9504 pci_bus_id=0000:01:00.0 Discrete=1
vendor_id=4098 device_id=5688 pci_bus_id=0000:06:00.0
```

Both negative paths passed: no selector raised rather than guessing between the two
GPUs, and `0000:ff:00.0` was rejected as nonexistent. Every positive run requested
`0000:01:00.0` explicitly.

The cheap Conv probe passed: three optimized nodes on WebGPU, CPU/WebGPU correlation
1.0, max absolute difference `1.91e-06`. Process maps after real session creation and
inference newly contained:

- `libonnxruntime_providers_webgpu.so`;
- `/usr/lib/libvulkan.so.1.4.357`;
- NVIDIA's `libGLX_nvidia`, `libnvidia-glvkspirv`, `libnvidia-gpucomp`, and related
  driver libraries;
- `/dev/nvidia0` and `/dev/nvidiactl`.

Enumeration also loaded RADV's ICD, which is expected when discovering both physical
devices; explicit ORT metadata selected the NVIDIA PCI device. During Demucs,
`nvidia-smi` independently attributed about 3548 MiB to the validation Python PID.
Together with placement logs and named Dawn dispatches, this proves NVIDIA/Vulkan
execution rather than merely the presence of `libvulkan.so` or a provider name.

Post-completion L9 caveat: the plugin's packaged documentation says it accepts one EP
device but selects the physical GPU independently; L9 proved a Radeon 780M request
silently executed on the RX 9070. N1 therefore establishes **actual correct RTX 3060
execution**, independently, but cannot distinguish "the request was honored" from
"the plugin independently chose the same plausible default." This does not weaken
N1's execution/correctness result, but it is a real limitation for user-selectable
multi-GPU targeting and changes the causal device-selection claim.

L10 later established a separate enforcement mechanism: a fresh subprocess using
`VK_LOADER_DEVICE_ID_FILTER` can expose only the requested Vulkan device. That makes
the Radeon 780M reachable for MDX-Net, but does not retroactively prove that N1's
ordinary `add_provider_for_devices()` request selected the RTX 3060; the NVIDIA
execution proof and selector-enforcement proof remain deliberately separate.

## 5. Fixture

A local, personally-held music file was used without copying it from another machine
or committing it. The controlled excerpt was 20.000 s, stereo PCM16, 44.1 kHz,
SHA-256 `f4414730fe28a2e54228b3400bb46634d79d65258e3d128d05944430dc22f1db`.
The same excerpt was used for MDX CPU/WebGPU, Demucs ONNX CPU/WebGPU, and production
PyTorch/CUDA. Every output path was external to Git.

## 6. MDX-Net (`UVR_MDXNET_KARA_2.onnx`)

The model was obtained through `audio-separator`'s existing catalog into the isolated
cache. Its SHA-256 was
`bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4`;
prior experiment documentation did not publish an independent MDX hash to compare,
so identity is established by the same catalog name/source plus this N1-local hash,
not claimed as a cross-machine byte-hash match. `uses_pytorch_inference` was false,
proving the L3 segment-size trap did not silently route this model through onnx2torch.

The first run revealed that current Linux torch auto-selected CUDA for the surrounding
MDX STFT/iSTFT. That did not invalidate the initial CPU-EP/WebGPU-EP comparison because
both routes used the same pre/post device, but it made NVIDIA utilization ambiguous and
differed from the historical CPU-STFT boundary. An optional `--torch-device cpu`
control was therefore added and the full validation and benchmark were repeated. The
reported results below are the controlled CPU-STFT runs; both routes recorded
`torch_device=cpu`.

| Check | Result |
|---|---|
| Explicit RTX 3060 selection | PASS |
| Vulkan/NVIDIA proof | PASS |
| Graph placement | PASS — 185/185 WebGPU nodes, zero fallback |
| Full two-stem export | PASS — 20.000 s, stereo, 44.1 kHz, finite, non-silent, no clipping |
| Routing | PASS — same-stem correlation 1.0; cross-stem 0.1644 |
| Raw CPU/WebGPU parity | PASS — corr 1.0; max diff `4.77e-07` vocals / `4.47e-07` instrumental |
| Exported WAV parity | PASS — max diff one PCM16 LSB (`3.05e-05`) |

Four-run benchmark, same process and input:

| Metric | CPU EP | WebGPU/Vulkan |
|---|---:|---:|
| Session/model load | 1.221 s | 0.445 s |
| First run | 13.119 s | 2.098 s |
| Warm median (3) | 12.045 s | 2.083 s |
| Warm range / stdev | 12.000-12.057 s / 0.030 s | 2.076-2.091 s / 0.008 s |
| Real-time factor | 1.7x | 9.6x |
| Warm speedup | reference | **5.78x** |
| Sampled peak RSS | 3029 MiB | 1700 MiB |
| Whole-GPU attributable memory delta | 0 MiB | 1087 MiB on first run |
| Average whole-GPU utilization | 0% | 46.0% |

Later WebGPU runs began with the session's allocation already resident, so their
per-run peak-minus-baseline VRAM delta was zero; the 1087 MiB first-run delta is the
useful allocation figure. GPU counters remain whole-GPU, while RSS is per-process.

## 7. Demucs ONNX

Artifact: `htdemucs.onnx`, 316,446,953 bytes, SHA-256
`68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`, exactly
matching L4-L8 and W1.

Default `ORT_ENABLE_ALL` reproduced the known failure on NVIDIA/Vulkan:

```
EP_FAIL ... webgpu/nn/conv.h:21 ...
GetFusedActivationAttr(info, activation_).IsOK() was false
```

`ORT_ENABLE_BASIC` was then used for both CPU and WebGPU ONNX sessions. Session
creation succeeded in 3.829 s (CPU) and 4.135 s (WebGPU), followed by real inference.

```
All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594
```

No CPU node fallback occurred. Deterministic `shifts=0` CPU/WebGPU results:

| Stem | Correlation | Max abs diff | Relative RMS error |
|---|---:|---:|---:|
| drums | 0.999999999 | 1.47e-4 | 0.0046% |
| bass | 0.999999995 | 1.27e-4 | 0.0098% |
| other | 0.999999995 | 1.15e-4 | 0.0098% |
| vocals | 0.999999998 | 9.93e-5 | 0.0067% |

Production-setting `shifts=2`, seeds 111/222/333, reused one verified session. The
offsets exactly matched prior phases: `[6971,10353]`, `[3535,7708]`, and
`[18180,11495]`. Across all seeds and stems, CPU/WebGPU correlations were at least
0.999999996; relative RMS error was 0.0042%-0.0084%; max absolute difference was
`8.17e-05`-`3.11e-04`.

| Metric | ONNX CPU | ONNX WebGPU/Vulkan |
|---|---:|---:|
| `shifts=2` warm median | 28.578 s | 14.144 s |
| Observed range | 28.186-28.889 s | 14.123-14.260 s |
| Real-time factor | 0.70x | 1.41x |
| Speedup | reference | **2.02x** |
| Process CPU use | about 800-900% while CPU inference was active | materially lower, with GPU saturated |
| Sampled GPU utilization | about 1.4%-1.8% average (brief unrelated spikes possible) | 97.1%-98.4% average, 100% max |

Both CPU and WebGPU exported four 20.000 s stereo/44.1 kHz WAVs. Every array and WAV
was finite and non-silent; peaks ranged from 0.56 to 0.87, so none clipped. Routing
passed with diagonal correlations effectively 1.0 and maximum off-diagonal 0.0742.

Memory: the validation intentionally kept CPU and WebGPU sessions plus comparison
arrays alive together, reaching approximately 6.13 GiB process RSS. Live
`nvidia-smi` attributed about 3548 MiB to the process, within the 6144 MiB device.
No OOM or failed allocation occurred. Per-run VRAM deltas were zero after session
initialization because the large allocation remained resident; this is a measurement
boundary limitation, not a claim of zero WebGPU memory use.

## 8. Existing PyTorch/CUDA production reference

The installed STEMwerk environment was used read-only:

- Python 3.12.13 x86-64;
- `audio-separator==0.23.0`;
- `torch==2.5.1+cu124`, CUDA available on the RTX 3060;
- real `htdemucs` checkpoint `955717e8-8726e21a.th`, SHA-256
  `8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4`;
- production settings: default segment, shifts 2, overlap 0.25.

The first full CUDA export took 4.145 s (RTF 4.82x), peaked near 1671 MiB RSS and
showed a best-effort 919 MiB whole-GPU memory delta. In a loaded-session seeded series,
the first run took 4.178 s and warm runs took 2.425/2.374 s (warm median 2.399 s).
Comparable WebGPU seeded runs took 14.147/13.942/13.932 s. WebGPU is therefore about
**5.9x slower than the existing warm CUDA route**, while remaining about 2.0x faster
than ONNX CPU. This is a pipeline comparison, not a pure same-graph backend comparison;
the ONNX CPU/WebGPU table above is the controlled same-graph comparison.

The established shift-parity methodology was also repeated. Mean PyTorch/CUDA vs
ONNX-WebGPU error relative to PyTorch's own three-run noise floor was 1.14x (drums),
1.00x (bass), 1.51x (other), and 1.40x (vocals); correlations were 0.9928-0.9989.
Thus the L6-style vocals/other residual can recur on a healthy, non-silent fixture,
while L7/L8 showed that it does not recur universally. This phase does not overturn
either finding: export-to-production parity is fixture/stochastic-path sensitive.
Crucially, CPU ONNX and WebGPU ONNX remained near-exact on the same offsets, so the
residual is not a Vulkan/WebGPU correctness defect.

ONNX Runtime CUDA was not installed or tested; it was optional and would require a
third isolated runtime. The existing production CUDA route already answered the
practical NVIDIA comparison without risking either working environment.

## 9. Deliverable matrix

| Test | MDX-Net | Demucs |
|---|---|---|
| RTX 3060 detected | PASS | PASS |
| Correct adapter actually executed | PASS — independent NVIDIA evidence; selector causality unproven | PASS — same caveat |
| Vulkan backend confirmed | PASS | PASS |
| Model loaded | PASS | PASS |
| GPU graph execution | PASS — 185/185 | PASS — 1594/1594 |
| CPU fallback | PASS — zero | PASS — zero |
| Actual inference | PASS | PASS |
| Numerical validation | PASS | PASS |
| Full audio pipeline | PASS — 2 stems | PASS — 4 stems |
| CUDA reference | NOT TESTED — no production MDX route | PASS — PyTorch/CUDA |
| Performance | PASS | PASS |
| Memory validation | PASS with whole-GPU caveats | PASS with retained-session caveats |

## 10. Code changes

All changes are experiment-only:

1. `end_to_end_pipeline_test.py`: optional `--torch-device`, recorded in JSON, to
   prevent current Linux torch packaging from silently moving MDX STFT/iSTFT to CUDA.
2. `benchmark_resources.py`: the same optional torch-device control plus explicit
   `--gpu-monitor-backend`, NVIDIA index, and ROCm card-key options. Defaults preserve
   prior Windows/Linux behavior.
3. `resource_sampler.py`: documentation now states that the existing `nvidia-smi`
   implementation is also used on Linux; measurement logic is unchanged.
4. `demucs_validation.py`: reusable SHA-gated CPU/WebGPU runner using the existing
   shift wrapper and adapter, with placement proof, audio/routing/numeric validation,
   repeated timing, RSS, process CPU, and NVIDIA monitoring.

No change was needed in `webgpu_adapter.py`, `demucs_shift_wrapper.py`, model weights,
graph precision, or production source. The only NVIDIA/Linux-specific choices are
runtime selectors and monitoring arguments, not inference implementations.

## 11. Cross-platform assessment

| Platform | GPU | Backend | MDX / Demucs placement | Practical Demucs comparison |
|---|---|---|---|---|
| Linux | AMD RX 9070 | Vulkan/RADV | 185 / 1594, zero fallback | WebGPU 2.2x vs ONNX CPU; no production ROCm reference recorded |
| Linux | NVIDIA RTX 3060 Laptop | Vulkan/NVIDIA | 185 / 1594, zero fallback | WebGPU 2.02x vs ONNX CPU; ~5.9x slower than production CUDA |
| macOS | Apple M1 | Metal | 185 / 1594, zero fallback | ~5.9x slower than production MPS |
| Windows | NVIDIA RTX 3060 Laptop | D3D12 | 185 / 1594, zero fallback | ~4.8x slower than production CUDA |
| Linux | AMD Radeon 780M | Vulkan/RADV | MDX 185/185 PASS via L10 loader isolation; Demucs 1594/1594 before failure | MDX faster than CPU; Demucs **BLOCKED** by device loss and ~114x slowdown on the only diagnostic size that completed |

Linux/NVIDIA required no vendor-specific inference code. The same RTX 3060 runs the
same node counts under Vulkan and D3D12, strongly supporting a maintainable optional
cross-platform WebGPU implementation. L9 shows that the plugin API itself does not
honor non-default selection; L10 shows that Linux/Vulkan can enforce it externally via
loader isolation. The 780M is therefore genuinely testable for MDX-Net, while Demucs
remains impractical/blocked on that GPU. Portability and selector enforcement must not
be conflated. Performance evidence equally strongly supports
retaining CUDA/ROCm/MPS production routes: WebGPU's value is portability and a common
implementation, not replacing a mature vendor backend where one already works.

## 12. Reproduction

```bash
# Explicit selector is mandatory on this dual-GPU Linux laptop.
python webgpu_ep_probe.py --pci-bus-id 0000:01:00.0

python end_to_end_pipeline_test.py INPUT.wav \
  --pci-bus-id 0000:01:00.0 --torch-device cpu \
  --model-cache /external/model-cache --out-dir /external/mdx-e2e

python benchmark_resources.py INPUT.wav --runs 4 \
  --pci-bus-id 0000:01:00.0 --torch-device cpu \
  --gpu-monitor-backend nvidia --nvidia-gpu-index 0 \
  --model-cache /external/model-cache --out-dir /external/mdx-benchmark

python demucs_validation.py INPUT.wav /external/htdemucs.onnx \
  --pci-bus-id 0000:01:00.0 --nvidia-gpu-index 0 \
  --shifts 2 --seeds 111 222 333 --out-dir /external/demucs-validation
```

This report was later reconciled into `experiment/webgpu-ep` after L11 without
rewriting or moving the original `slice/webgpu-n1-linux-nvidia` commits.
