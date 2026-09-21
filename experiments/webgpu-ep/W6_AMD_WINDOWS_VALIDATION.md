# W6 AMD Windows validation — independent clean-install and end-to-end report

Status date: 2026-09-21. Machine: **AMD Windows workstation** (Ryzen 7 7840HS,
RX 9070 16 GB eGPU + Radeon 780M iGPU, driver 32.0.31041.1004, Windows 11 Pro
26200) — the second, independent machine; the W6 wheel was built and first
validated on the NVIDIA RTX 3060 laptop. Local validation branch
`validate/w6-amd-windows`, worktree `P:\GIT\STEMwerk-worktrees\webgpu-w6-amd-validation`,
base = published shared HEAD `314e870c5a9387b0422a263912ca82cd7d7474fb`
("W6 patch consolidation and experimental Windows wheel distribution").
Nothing was built from source here; no W5 runtime was reused; no manual DLL
swaps; production STEMwerk untouched.

## 1. Verdict

**PASS — the W6 experimental wheel independently passed clean installation and
end-to-end validation on BOTH AMD GPUs (RX 9070 and Radeon 780M).**

## 2. Wheel receipt and provenance (STOP gates)

| Gate | Expected (W6 manifest) | Actual on this machine | Result |
|---|---|---|---|
| Wheel SHA-256 | `be602b7153e0a563e2e9e315f975423a9eab900f86769dd2828d8515c88ade16` | identical | PASS |
| Wheel size | 12,724,222 B | 12,724,222 B | PASS |
| Provider DLL (disk + live-loaded) | `ee58f6d3312d076b02fb8962fdc7bff4f05e1d27d68a345d9fc382a4a21eb1aa` | identical | PASS |
| dxcompiler.dll | `16ed38884fe62999877b14678178ebacb2909c412652d6f05efad3c501a1d912` | identical | PASS |
| dxil.dll | `77e039c905030a641e53658a008b74e90635a5ea9b6b79eabd0f2003bdfca59a` | identical | PASS |

The manifest's full DLL hash was used (not the `ee58f6d3` prefix). Transfer
route: laptop share `S:\packages\w6\` → local `C:\stemwerk-w6-amd\packages\`,
hash re-verified after copy.

## 3. Clean install (fresh, isolated from all W5 environments)

- New venv: `C:\stemwerk-w6-amd\venvs\runtime` (CPython 3.11.0 x64) — separate
  from `C:\stemwerk-amd-win\venvs\*` (W5) and the canonical `.venv`.
- Normal pip only: `onnxruntime==1.30.0`, the W6 wheel,
  `audio-separator==0.47.0`, `psutil`. No DLL copying.
- Installed: `onnxruntime 1.30.0`, `onnxruntime-ep-webgpu 0.3.0+w6consolidated`
  at `C:\stemwerk-w6-amd\venvs\runtime\Lib\site-packages`.
- ffmpeg was already on PATH (winget yt-dlp.FFmpeg); audio-separator's startup
  check passed without shims.
- Loaded-DLL proof (`evidence/w6amd_loaded_dll_proof.log`): exactly ONE
  `onnxruntime_providers_webgpu.dll` loaded in the live process, from the W6
  venv site-packages, SHA-256 `ee58f6d3…eb1aa` — not the W5 DLL
  (`b7a1c623…`), not stock 0.3.0 (`b05a6d51…`).

## 4. Physical device identities (rediscovered, not assumed)

Live `list_webgpu_devices()` in the W6 venv: RX 9070 → LUID **87436**
(device 0x744c), Radeon 780M → LUID **96109** (device 0x15bf). Unchanged from
the W5 validation, but re-confirmed on the W6 runtime.

## 5. Physical GPU execution (decisive, per-PID per-LUID)

Dense repeated-Conv probe (`w2_device_selection_probe.py`, same-process
GPU Engine monitor, fresh process + 2 s idle baseline per direction; both GPUs
are AMD so LUID-keyed per-process counters are the discriminating proof):

| Requested | PID | Calls | Counter evidence | Verdict |
|---|---|---|---|---|
| RX 9070, LUID 87436 | 9120 | 371 | only LUID 87436: 6 nonzero 3D samples, peak 38.6 %, avg-of-nonzero 43.6 %; nothing on 96109 | **PASS** |
| 780M, LUID 96109 | 7816 | 410 | only LUID 96109: 6 nonzero 3D samples, peak 42.3 %, avg-of-nonzero 42.9 %; nothing on 87436 | **PASS** |

Placement in both: `All nodes placed on [WebGpuExecutionProvider]. Number of
nodes: 3`. The first inference of each probe also constitutes the W5
DefaultContext crash-regression surviving on the W6 DLL (see §7).

## 6. MDX-Net end-to-end (same model/fixture/boundaries everywhere)

Model `UVR_MDXNET_KARA_2.onnx` `bf32e151…` (re-hashed), fixture
`w1_fixture_25s.wav` `658380a5…` (re-hashed), torch_device=cpu. Each leg = one
fresh process running CPU then WebGPU through the identical pipeline.

| Leg | Placement | Raw corr / max abs | File diff | Routing | Exit |
|---|---|---|---|---|---|
| RX 9070 (LUID 87436) | 185/185 WebGPU, 0 fallback | 1.00000000 / 1.13e-06 voc, 1.07e-06 inst | 1.00× PCM16 LSB | PASS | 0 |
| 780M (LUID 96109) | 185/185 WebGPU, 0 fallback | identical to RX leg, bit-for-bit | 1.00× PCM16 LSB | PASS | 0 |
| RX 9070 warm repeat | 185/185 WebGPU, 0 fallback | bit-identical again | 1.00× PCM16 LSB | PASS | 0 |

Output WAVs: 44.1 kHz stereo 25.00 s, valid, routed correctly. The loaded W6
DLL identity (`ee58f6d3…`) is proven in §3 and the probes ran in the same venv;
the harness's own placement proof (185/185, zero fallback) is per-leg.

## 7. Rejection and regression checks (`w6_rejection_tests.py`, 8/8 PASS)

- Malformed selectors `-1`, `notanumber`, `2^65`: rejected at the Python adapter.
- Mismatched explicit LUID vs selected device: native rejection; the production
  wrapper raised `GpuExecutionNotProvenError` instead of allowing the silent
  CPU fallback (`CPUExecutionProvider`-only session detected and refused).
- Cross-GPU default-context reuse: native `EP_FAIL` at
  `webgpu_context.cc:289` with the patch's exact message ("WebGPU context ID 0
  is already initialized for a different D3D12 adapter LUID"), surfaced by the
  wrapper. (Build-path prefix `C:\stemwerk-w5-local\…` in the message is the
  documented upstream build-path artifact, not a local file dependency.)
- Same-GPU context reuse: accepted, session works.
- First-inference on RX 9070 survived (the W5 `DefaultContext` crash sequence)
  — and the 780M leg's first inference likewise survived in §5–§6.

## 8. Performance (boundaries explicit; no cold-CPU vs warm-GPU mixing)

Boundary definitions (same as the audited W5 report): `load` =
`Separator.load_model()` — ORT session init + Dawn context/device setup;
`run` = complete `separate()` — WAV decode, torch STFT (CPU), chunked ONNX
inference, overlap-add, export — **not inference-only**; the first WebGPU
`run` in a process also includes one-time WGSL kernel compilation.

| Measurement | Value | n | Classification |
|---|---|---|---|
| RX 9070 WebGPU `load` | 0.46–0.51 s | 3 | session init (incl. Dawn setup) |
| RX 9070 WebGPU `run` | 2.33 / 2.37 s | 2 | warm full pipeline (first-run compile included; runs 3 min apart, bit-identical) |
| 780M WebGPU `run` | 6.67 s | 1 | warm full pipeline, fresh process |
| CPU `run`, first leg | 22.59 s | 1 | **cold** (first separation in this venv) |
| CPU `run`, warm | 10.95 / 11.42 s | 2 | warm-cache, fresh processes |

Warm-vs-warm on identical boundaries: RX 9070 ≈ **4.8×** CPU (CPU warm median
11.19 s / GPU 2.35 s); 780M ≈ **1.7×** CPU (11.19 / 6.67). The cold CPU 22.59 s
is reported separately and not ratioed against warm GPU numbers.

Historical comparison (same machine, same fixture, same boundaries, different
DLL build): W5 warm RX 9070 median 3.09 s (n=6) vs W6 2.35 s (n=2) — W6 is not
slower; numerics are bit-identical across the two builds. Not a benchmark
upgrade claim, just distribution-parity evidence. Laptop numbers (RTX 4.03 s /
AMD 12.10 s) are different hardware and not pooled.

## 9. Installation/dependency observations

- Clean install produced zero dependency conflicts; `onnx-weekly` was again
  pulled transitively (same as the W5 venv); the `onnx` import resolves to the
  pinned release used by audio-separator.
- Native rejection messages embed the laptop's build paths (documented W6
  limitation); functionally harmless.

## 10. Remaining distribution limitations (unchanged from W6 docs)

Not bit-for-bit reproducible across rebuilds (W6 vs W5 DLL differ at the byte
level, functionally equivalent — re-confirmed here by identical numerics);
native C++ unit tests not runnable in plugin build mode; per-PID GPU Engine
counters only attribute dense workloads (MDX physical selection rests on the
dense probes + placement/numerics/audio, exactly as on the laptop); Windows-only
LUID option; experimental artifact — not upstreamed, no production STEMwerk
integration. **Radeon 780M Demucs remains untested** — no support inferred.

## 11. Evidence index (all outside Git)

`C:\stemwerk-w6-amd\evidence\`: `w6amd_loaded_dll_proof.log`,
`w6amd_probe_rx9070.log`, `w6amd_probe_780m.log`, `w6amd_mdx_rx9070.log`,
`w6amd_mdx_780m.log`, `w6amd_mdx_rx9070_repeat.log`, `w6amd_rejection_tests.log`,
plus `mdx_*/e2e_report.json` output dirs. Venv/wheel under
`C:\stemwerk-w6-amd\`. W5 evidence under `C:\stemwerk-amd-win\` is preserved
unmodified.
