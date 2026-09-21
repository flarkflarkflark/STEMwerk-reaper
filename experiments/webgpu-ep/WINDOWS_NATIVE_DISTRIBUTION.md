# W6 — Windows native WebGPU distribution: patch hardening and experimental wheel

Status date: 2026-09-21. Experimental, opt-in, isolated. Not integrated into
STEMwerk. No production environments, installers, or vendor GPU backends were
touched. Nothing was pushed or published.

W6 turns the W5 proof of concept (physical DXGI-LUID GPU selection, proven by
real inference on both the RTX 3060 and the AMD integrated GPU) into a coherent,
reproducible, independently installable experimental Windows wheel. It changes
no runtime behavior relative to W5: the native code is bit-for-bit identical in
source, consolidated into one reviewable patch.

## 1. Git preflight and reconciliation

Starting state of `experiment-webgpu-ep-win-nvidia`: clean working tree at W5
HEAD `11c616125e227be325ec5978fef3a1d2f9a18ac5`, no stashes, no uncommitted or
unpublished W6 changes anywhere. `git fetch origin` showed the shared branch had
advanced by the two AMD Windows validation integration commits; the local branch
was fast-forwarded to `ad237d680cff313f03bc62893566b016fb5566f6` with no
conflict. Nothing was reset, stashed, discarded, or force-pushed. The canonical
checkout and all unrelated worktrees were not modified.

The expected W5 artifact hashes were re-verified against actual files before any
build work:

- W5 wheel `packages/fix1/onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl`:
  SHA-256 `e1469a3623609c10382839a07103b37a37600055673ca26642e42104e68dd74d` — matches
  the recorded value (the W5 report's transcription dropped one `a` nibble).
- W5 provider DLL inside that wheel and in the build tree:
  `b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248` — exact match.
- ORT source checkout clean at `1070be0cf9b10ea9e45d42d30d307ba459e673e5`
  (base `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c` + W4 `ab4ae2d...` + W5 fix).
  The pristine control checkout at `caf2ed3` is intact and unmodified.

## 2. Consolidated native patch

The W4 patch (`patches/0001-...`, SHA-256 `ebf88909...`) and the W5
DefaultContext fix (`patches/0002-...`, SHA-256 `fa3f51aa...`) are preserved
unchanged as evidence. For review and upstream submission they are consolidated
into a single patch:

- `patches/W6-consolidated-WebGPU-Windows-D3D12-adapter-LUID-selection.patch`
- SHA-256 `16f6b9af1551451d302fb9ab0782be1db8b99751baa0bb8b892a45a5bf68e08d`
- Base: `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c` (tag `plugin-ep-webgpu/v0.3.0`,
  Dawn pinned at `a192e3019a9a20db23329e631328b39b9867049a`)

The consolidation is a pure squash: in the isolated ORT clone, branch
`w6/consolidated-luid-selection` commit
`4b10ceeb416c5323a6901ed9618f1074a32a748b` was produced by cherry-picking both
original commits without modification; `git diff 1070be0 4b10cee` is empty, so
the consolidated tree is byte-identical to the proven W5 fixed tree. The patch
passes `git apply --check` against the pristine control checkout.

The consolidated patch retains all W5 invariants:

- Explicit DXGI LUID propagation from the selected `OrtHardwareDevice` metadata
  (`factory.cc`), refusing adapters with no LUID rather than substituting.
- Dawn D3D12 physical-adapter selection via `RequestAdapterOptionsLUID`
  (`webgpu_context.cc`).
- Returned-adapter identity verification: the selected adapter's DXGI LUID is
  re-queried and compared to the request; mismatch is a hard failure
  ("Refusing physical-GPU substitution").
- Rejection of invalid or unavailable LUIDs (`webgpu_provider_factory.cc`:
  malformed values, non-D3D12 backends, external devices all rejected).
- No silent alternate-GPU selection; no cross-GPU context reuse (context cache
  refuses reuse with a different LUID).
- Correct `DefaultContext()` lifetime: internal transfer paths retain the
  existing context (refcount++) instead of re-initializing with an empty config
  (the W5 first-inference crash fix).
- Unchanged default behavior when no GPU is requested: `d3d12_adapter_luid`
  stays empty and the code path is inert.

## 3. Reproducible isolated build

The existing W5 build tree, vcpkg/Dawn dependency caches, and source checkout
were reused; no large dependency was deleted or rebuilt. One build ran at a
time, four parallel jobs. Host state before build: 31.4 GiB RAM (18.6 GiB free),
2 GiB pagefile, C: free space 11 GiB (rose to 29 GiB after transient pressure
cleared; builds were monitored against it).

Toolchain (verified live): VS Build Tools 2022 17.14.41, MSVC 14.44.35207,
Windows SDK 10.0.26100.0, VS-bundled CMake 3.31.6-msvc6, Python 3.11.8.

Because the consolidated commit's tree is identical to `1070be0`, the existing
build tree already corresponded to it; checking the branch out only refreshed
the six patched files' timestamps, so the W6 build genuinely recompiled them:

```
cmake --build C:\stemwerk-w5-local\build\ort-webgpu-luid\Release --config Release \
  --target onnxruntime_providers_webgpu -- /maxcpucount:4 /p:CL_MPCount=4 /nodeReuse:False
```

Result: `INCREMENTAL_BUILD_EXIT_CODE=0`, zero warnings in the incremental log,
LTO recompiled 5 of 183410 functions (only the patched files). Log:
`M:\stemwerk-w6\evidence\build_log_w6_consolidated.txt`.

Native artifacts:

| File | SHA-256 |
|---|---|
| `onnxruntime_providers_webgpu.dll` | `ee58f6d3312d076b02fb8962fdc7bff4f05e1d27d68a345d9fc382a4a21eb1aa` |
| `dxcompiler.dll` | `16ed38884fe62999877b14678178ebacb2909c412652d6f05efad3c501a1d912` |
| `dxil.dll` | `77e039c905030a641e53658a008b74e90635a5ea9b6b79eabd0f2003bdfca59a` |

Reproducibility limitation, stated plainly: the W6 DLL is **not** byte-identical
to the W5 DLL (`ee58f6d3...` vs `b7a1c623...`) despite byte-identical source and
the same toolchain — the LTO link is not deterministic at the byte level.
`dxcompiler.dll` and `dxil.dll` are byte-identical to the W5 wheel. No
bit-for-bit reproducibility is claimed; functional equivalence is established by
the full validation matrix in section 5, which reproduces every W5 pass
criterion on the W6 binary.

## 4. Experimental wheel

Built with the plugin's own packaging script (not a DLL swap into an unrelated
package):

```
python plugin-ep-webgpu/python/build_wheel.py \
  --binary_dir C:\stemwerk-w5-local\build\ort-webgpu-luid\Release\Release \
  --version 0.3.0+w6consolidated --output_dir C:\stemwerk-w5-local\packages\w6
```

- File: `onnxruntime_ep_webgpu-0.3.0+w6consolidated-py3-none-win_amd64.whl`
- Size: 12,724,222 bytes
- SHA-256: `be602b7153e0a563e2e9e315f975423a9eab900f86769dd2828d8515c88ade16`
- Handoff copy: `M:\stemwerk-w6\packages\` (hash re-verified after copy)

Metadata verified: `Name: onnxruntime-ep-webgpu`, `Version: 0.3.0+w6consolidated`,
`Requires-Python: >=3.11`, `License-Expression: MIT`, wheel ships `LICENSE` and
`ThirdPartyNotices.txt` and all three native DLLs. The `+w6consolidated` local
version tag marks it unambiguously as a non-upstream experimental build; it must
never be presented as an official ONNX Runtime release.

Runtime dependency: a matching base `onnxruntime==1.30.0` from PyPI. The wheel
is a plugin EP; it does not replace or modify the base package.

Machine-readable provenance: [`w6_build_manifest.json`](w6_build_manifest.json)
(source SHAs, patch hashes, toolchain, exact build/wheel commands, all artifact
hashes, install procedure, limitations).

## 5. Clean-install validation on the NVIDIA laptop

Fresh venv `C:\stemwerk-w5-local\venvs\runtime-w6` (CPython 3.11.8), installed as
normal packages only:

```
pip install onnxruntime==1.30.0 onnxruntime_ep_webgpu-0.3.0+w6consolidated-...whl \
  audio-separator==0.47.0 psutil pytest
```

No DLL was copied or swapped by hand. `audio-separator`'s startup check requires
an `ffmpeg` executable on `PATH`; the run environment supplied one via an
`imageio-ffmpeg` binary shim (`use_soundfile=True` means ffmpeg is never used
for the actual audio I/O — same condition as the W5 runs).

### Loaded-DLL proof (both GPUs, fresh processes)

`C:\stemwerk-w5-local\w6_loaded_dll_proof.py` verifies, inside the live process
via `psutil.memory_maps`, that no provider DLL is loaded before session
creation, and that exactly one `onnxruntime_providers_webgpu.dll` is loaded
afterwards — from the runtime-w6 `site-packages` path, SHA-256
`ee58f6d3...` — then runs the W5 first-inference crash sequence twice and checks
repeat determinism. Result: **PASS for LUID 64318 and LUID 59967**
(`w6_proof_rtx.log`, `w6_proof_amd.log`). Model/fixture identities re-verified:
`UVR_MDXNET_KARA_2.onnx` `bf32e151...`, `w1_fixture_25s.wav` `658380a5...`.

### Physical GPU execution (same-process OS counters)

`w2_device_selection_probe.py` self-monitors `\GPU Engine(*)` counters for its
own PID, keyed by registry-enumerated DXGI LUIDs:

| Requested | Inferences | Counter evidence | Verdict |
|---|---|---|---|
| RTX 3060 LUID `64318` | 963 Conv | 6 nonzero 3D samples, **only** LUID 64318, peak 36.92% | PASS |
| AMD iGPU LUID `59967` | 775 Conv | 6 nonzero 3D samples, **only** LUID 59967, peak 55.94% | PASS |

(`w6_rtx_dense_direct.log`, `w6_amd_dense_direct.log`.) A nested outer-monitor
capture was also run and, exactly as W5 recorded, attributed nothing — it is
kept as a negative artifact (`w6_rtx_dense_monitor.json`), not as evidence.

### MDX-Net numerical and audio validation (25 s fixture, fresh processes)

| GPU | Placement | Raw corr / max abs | File diff | Routing | Timing (load / run) |
|---|---|---|---|---|---|
| RTX 64318 | 185/185 WebGPU, 0 CPU fallback | 1.00000000 / 1.10e-06 voc, 1.03e-06 inst | 3.05e-05 = 1.00 PCM16 LSB | PASS | CPU 37.54 s → WebGPU 4.03 s |
| AMD 59967 | 185/185 WebGPU, 0 CPU fallback | 1.00000000 / 1.07e-06 voc, 1.01e-06 inst | 3.05e-05 = 1.00 PCM16 LSB | PASS | CPU 21.39 s → WebGPU 12.10 s |

Session initialization (`load=0.72 s` / `0.61 s`, including first shader
compilation) is measured separately from warm processing. Outputs are valid
44.1 kHz stereo 25.00 s stems. Audio/logs: `M:\stemwerk-w6\evidence\w6_*_mdx*`.
The AMD leg's PASS rests on positive AMD counter evidence plus numerics/audio —
not on session creation.

## 6. Regressions and distribution safety

- First-inference crash regression: `diag_single_run.py` (RTX) and
  `diag_single_run_amd.py` (AMD) both pass on the W6 DLL; the loaded-DLL proof
  also exercises the exact original crash sequence on both GPUs.
- Invalid/mismatched LUID: native `INVALID_ARGUMENT` ("does not match the
  selected OrtHardwareDevice"); through the adapter wrapper this surfaces as
  `GpuExecutionNotProvenError` instead of a silent CPU fallback
  (`w6_diag_test1_retry.log`).
- Cross-GPU context reuse: rejected, `EP_FAIL` at `webgpu_context.cc:289`.
- Same-GPU context reuse: accepted and functional.
- Malformed selectors `-1`, `notanumber`, `2^65`: rejected at the Python adapter.
  (`w6_rejection_tests.log`.)
- Resolver policy suite: **40/40 PASS**, 2 expected non-Linux skips.
- Adapter-selection unit tests: 9 passed + 5 subtests.
- Capability matrix: 14 entries preserved; `capability_matrix.py` regeneration
  is byte-identical (the RX 9070 Windows Demucs row keeps its qualification:
  execution/numerical/routing PASS, drums WAV-clipping criterion FAIL on CPU and
  WebGPU alike — a model/fixture property the resolver continues to surface when
  Auto selects that route; AMD iGPU Demucs support is not inferred from MDX-Net).
- `python -m compileall` clean over the experiment tree.
- Native `webgpu_context_test.cc` unit tests remain unrunnable in the plugin
  (`shared_lib`) build mode — a pre-existing upstream build-system limitation
  documented in W5; equivalent behavior is covered by the Python-level tests
  above.
- The optional short RTX Demucs regression was not run in W6; Demucs claims
  remain exactly as W1/N1 and the AMD workstation report recorded them.

Distribution assessment: 12.7 MB wheel; clean install into a fresh venv
verified; rollback is `pip uninstall onnxruntime-ep-webgpu` (base `onnxruntime`
is never modified); MIT license and third-party notices ship inside the wheel;
native dependency set is only the three bundled DLLs; support diagnostics are
the hash-verification one-liner in the manifest plus the adapter's explicit
error messages.

## 7. Independent AMD workstation handoff

Target machine: Windows 11, AMD RX 9070 + Radeon 780M, repo at `P:\GIT\STEMwerk`.
This phase did not access or modify that machine. A pass on the NVIDIA laptop
does **not** by itself prove distribution readiness; the point of the handoff is
independent verification.

Transfer: `onnxruntime_ep_webgpu-0.3.0+w6consolidated-py3-none-win_amd64.whl`
(SHA-256 `be602b7153e0a563e2e9e315f975423a9eab900f86769dd2828d8515c88ade16`),
also staged at `M:\stemwerk-w6\packages\`.

Install (fresh venv, no DLL copying):

```powershell
py -3.11 -m venv C:\path\to\venv-w6
C:\path\to\venv-w6\Scripts\python.exe -m pip install onnxruntime==1.30.0
C:\path\to\venv-w6\Scripts\python.exe -m pip install <path\to>\onnxruntime_ep_webgpu-0.3.0+w6consolidated-py3-none-win_amd64.whl
# optional, for the full MDX-Net pipeline validation:
C:\path\to\venv-w6\Scripts\python.exe -m pip install audio-separator==0.47.0 psutil pytest
```

Verify the installed native module before any GPU test:

```powershell
C:\path\to\venv-w6\Scripts\python.exe -c "import onnxruntime_ep_webgpu, hashlib, pathlib; print(hashlib.sha256(pathlib.Path(onnxruntime_ep_webgpu.__file__).with_name('onnxruntime_providers_webgpu.dll').read_bytes()).hexdigest())"
# must print: ee58f6d3312d076b02fb8962fdc7bff4f05e1d27d68a345d9fc382a4a21eb1aa
```

Then discover that machine's own LUIDs (`webgpu_ep_probe.py` /
`list_webgpu_devices()` — never reuse this laptop's LUIDs) and repeat the
section-5 sequence: loaded-DLL proof per GPU, dense probe per GPU, MDX-Net
end-to-end per GPU. Requirements: Windows 10/11 x64, CPython >= 3.11,
D3D12-capable Adrenalin driver, `onnxruntime==1.30.0`, and any `ffmpeg` binary
on `PATH` for audio-separator's startup check.

## 8. Remaining limitations

- No bit-for-bit binary reproducibility across rebuilds (section 3).
- Native C++ unit tests for the new behavior are compiled into the tree but
  cannot run in the plugin build mode.
- Per-PID GPU Engine counters only attribute dense workloads; bursty MDX
  inference is proven by placement + numerics + audio instead.
- Stock native log lines carry upstream CI build paths (`N:\_work\1\s\...`).
- The LUID option is Windows-only; other platforms are unchanged.
- Experimental artifact: not upstreamed, not an official release, not
  integrated into STEMwerk; AMD GPUs remain excluded from resolver Auto pending
  more performance/stability evidence.
