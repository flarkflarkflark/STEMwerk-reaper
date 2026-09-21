# AMD Windows validation report — WebGPU EP, RX 9070 + Radeon 780M

Status date: 2026-09-21. Supersedes the stop-gate status in
`AMD_WINDOWS_VALIDATION_STATUS.md` (which remains as the historical record of the
Phase 0–2 preflight). Validation branch `validate/webgpu-amd-windows`, worktree
`P:\GIT\STEMwerk-worktrees\webgpu-amd-windows`, base `11c616125e227be325ec5978fef3a1d2f9a18ac5`
(= `origin/experiment/webgpu-ep` HEAD at the time of validation; the branch has not
been pushed to or modified by this slice).

## 1. Hardware, OS, drivers

| Item | Value |
|---|---|
| CPU | AMD Ryzen 7 7840HS |
| dGPU | AMD Radeon RX 9070 16 GB (eGPU), DXGI LUID **87436**, device_id 0x744c |
| iGPU | AMD Radeon 780M Graphics, DXGI LUID **96109**, device_id 0x15bf |
| Driver (both GPUs) | 32.0.31041.1004 (Adrenalin) |
| OS | Windows 11 Pro, build 26200 |
| RAM | 64 GB (≈50 GiB free at preflight), 4 GiB pagefile |

Because both GPUs are AMD (vendor 0x1002), all physical-execution claims below rest
on per-process `\GPU Engine` performance-counter samples keyed by DXGI adapter LUID
(read from the registry's live DXGI adapter table), never on vendor-level monitoring.

## 2. Runtime provenance (all hash-verified on this machine)

| Artifact | Identity |
|---|---|
| Provider wheel | `onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl`, 12,724,115 B, SHA-256 `e1469a3623609c10382839a07103b37a37600055673ca26642e42104e68dd74d` — transferred from the W5 laptop's share (`S:\packages\fix1\`), identical to the W5 record |
| Live-loaded DLL proof | `psutil.memory_maps()` in the running process → `onnxruntime_providers_webgpu.dll` SHA-256 `b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248` — exact W5 fixed-build hash |
| Base runtime | onnxruntime 1.30.0 (matches W5), CPython 3.11.0 x64 |
| Unpatched reference (not used for selection claims) | 10,522,976 B, `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| Venvs | `C:\stemwerk-amd-win\venvs\runtime` (MDX), `...\venvs\demucsonnx` (Demucs) — isolated; production STEMwerk untouched |
| MDX model | `UVR_MDXNET_KARA_2.onnx`, 52,786,726 B, `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4` (re-downloaded via audio-separator, hash matches W5 pin) |
| Demucs model | `htdemucs.onnx` (StemSplitio HF), 316,446,953 B, `68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74` (matches harness pin) |
| Fixture | `w1_fixture_25s.wav`, 4,410,044 B, `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` (transferred from laptop via `P:\GIT`, identical to W5 pin) |

## 3. Physical GPU selection (decisive, per-PID per-LUID)

Dense repeated-Conv probe (`w2_device_selection_probe.py`, same-process
`GpuEngineMonitor`, fresh process + 2 s idle segment per direction):

| Requested | PID | Calls | Per-PID GPU Engine result | Verdict |
|---|---|---|---|---|
| RX 9070, LUID 87436 | 9704 | 371 | only LUID 87436: 6 nonzero samples, peak 37.0 %, engine 3d; nothing on 96109 | **PASS** |
| 780M, LUID 96109 | 7600 | 994 | only LUID 96109: 6 nonzero samples, peak 54.2 %, engine 3d; nothing on 87436 | **PASS** |

Placement in both: `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 3`.
Logs: `C:\stemwerk-amd-win\evidence\probe_*.log`, summary `SUMMARY_physical_ab.md`.

## 4. MDX-Net (same model/fixture/boundaries everywhere)

Harness `end_to_end_pipeline_test.py`; each leg ran CPU + WebGPU in one process.
Audio: torch_device=cpu (STFT path identical across providers); 185/185 nodes on
WebGPU in both legs; stem routing PASS; output WAVs 44.1 kHz stereo 25.00 s valid.

| Leg | CPU run | WebGPU run | Raw vs CPU (vocals / instrumental) | File diff | Exit |
|---|---|---|---|---|---|
| WebGPU RX 9070 (LUID 87436) | 20.61 s | **2.51 s** (8.2×) | corr 1.00000000; max abs 1.13e-06 / 1.07e-06 | ≤ 1.00× PCM16 LSB | 0 |
| WebGPU 780M (LUID 96109) | 10.27 s (warm) | **6.11 s** (1.7× vs warm CPU) | corr 1.00000000; max abs 1.13e-06 / 1.07e-06 | ≤ 1.00× PCM16 LSB | 0 |

- The first CPU leg (20.61 s) vs second (10.27 s) shows the large warm-cache effect
  on this 7840HS; the WebGPU figures are first-pass-in-process times.
- Repeated warm performance: RX 9070 WebGPU runs measured 2.51 s (first leg) and
  3.03–3.24 s across three later fresh-process probe runs; 780M 6.11 s (leg) vs
  6.79 s (probe). WebGPU numerics were bit-identical across every repeat.
- Cross-machine corroboration: W5 laptop RTX 3060 raw max abs 1.095e-06/1.028e-06,
  laptop AMD iGPU 1.073e-06/1.013e-06 — this machine's 780M instrumental matches
  the laptop's AMD iGPU to the last bit (1.0728836059570312e-06).

## 5. Demucs (htdemucs ONNX, ORT_ENABLE_BASIC retained)

Harness `demucs_validation.py --adapter-luid 87436` (RX 9070 only; no 780M Demucs in
this slice). Providers: CPU / WebGPU(+CPU fallback listed). Input = same 25 s fixture
(chunked by demucs-onnx's own overlap-add).

| Metric | CPU | WebGPU RX 9070 |
|---|---|---|
| Placement | — | **1594/1594 nodes WebGPU, zero fallback** |
| Warm median (3 seeds, shifts=2) | 18.59 s | **9.72 s (1.91×)** |
| shifts=0 raw parity | — | corr ≥ 0.99999948, max abs ≤ 5.5e-04 (drums/bass/other/vocals) |
| Seeded runs worst comparison | — | max abs 1.80e-04, corr 0.999999996 |
| Stem routing | — | PASS (diagonal dominant) |
| Session init | 3.86 s | 7.90 s |

Reported as-is: the harness's exported-WAV **clipping gate trips on the drums stem
(peak exactly 1.0) for BOTH providers identically**. Root cause is a property of the
model+fixture, not of the backend: the raw float32 drums stem peaks at **1.363**
(CPU and WebGPU agree to 2e-5); PCM16 export clamps the overshoot to full scale.
Production pipelines apply normalization/limiting; this validation exports raw
stems. All backend-comparison, routing, and array-validation gates PASS; only the
`peak > 0.999` WAV check fails, symmetrically, so the overall harness exit was 1.
Full data: `C:\stemwerk-amd-win\evidence\demucs_rx9070\demucs_validation.json`.

## 6. Memory findings

| Probe (MDX, one 25 s separation) | Warm run | Peak RSS |
|---|---|---|
| CPU EP | 10.67 s | 2209 MiB |
| WebGPU RX 9070 | 3.03–3.24 s across repeated runs | 715 MiB |
| WebGPU 780M | 6.79 s (780M runs: 6.11 s in the dedicated leg) | 1566 MiB |
| Demucs (either provider, in-harness sampler) | — | ≈ 5.2 GB (316 MB model + numpy/ORT working set) |

- WebGPU cuts MDX peak RSS by ~2/3 vs CPU (activations live in GPU-accessible
  memory, not process RAM).
- Per-process GPU memory: Windows' `\GPU Process Memory(pid_…luid…)` counter
  creates **no instance at all** for these WebGPU/Dawn processes (verified
  dedicated-only and all-counter wildcard queries against the live PID during
  MDX and Conv-probe runs) — per-process VRAM attribution is unavailable for
  this Dawn allocation path on this system; reported as a measurement gap, not
  estimated. Adapter-level VRAM metadata: RX 9070 16,253 MB, 780M 421 MB
  (shared, from EP device enumeration).
- The Demucs harness's own VRAM sampler is nvidia-smi-based and correctly
  self-reports unreliable/None on AMD; nothing claimed from it.
- Evidence: `C:\stemwerk-amd-win\evidence\memprobe_*.json`, `memprobe_*.log`,
  `demucs_rx9070/demucs_validation.json`.

## 7. Comparison with Linux — only where genuinely comparable

Not directly comparable (different OS/driver/Dawn backend: Linux Vulkan vs Windows
D3D12, different GPUs), and per the slice rules Linux ROCm numbers are not presented
as Windows GPU benchmarks. The one legitimate cross-machine comparison is the W5
laptop (same OS, same patched DLL hash, same model/fixture hashes): numerics in §4
agree to the 1e-06 band; timings differ by hardware class (laptop RTX 3060/iGPU vs
desktop-class RX 9070) and are reported per-machine, not pooled.

## 8. Remaining blockers, gaps, unknowns

1. Per-process GPU VRAM attribution unavailable (see §6): the Windows counter
   creates no instance for the Dawn/WebGPU allocation path; RSS is solid.
2. Demucs raw drums stem overshoots to 1.363 float on this fixture: benign for
   backend validation (symmetric across providers) but production export paths
   should confirm their normalization/limiting handles it.
3. `onnx-weekly 1.24.0.dev20260914` was pulled transitively into the MDX venv; the
   `onnx` import resolves to the pinned 1.23.0 (verified). Recorded for reproducibility.
4. This workstation still lacks MSVC/VS Build Tools; the W5 source tree on `M:\` and
   the reproducible build plan remain the fallback if the wheel ever needs rebuilding.
5. Demucs on the 780M was explicitly out of scope for this slice — unknown.
6. The stale `P:\GIT\STEMwerk-worktrees\webgpu-ep` copied tree (broken git pointer)
   is still untouched; recommend cleanup coordinated with the W6 work.

## 9. What was committed

Locally on `validate/webgpu-amd-windows` (not pushed, shared branch untouched):
`demucs_validation.py` gains `--adapter-luid` (mirrors the MDX harness; the only
code change), plus this report.
