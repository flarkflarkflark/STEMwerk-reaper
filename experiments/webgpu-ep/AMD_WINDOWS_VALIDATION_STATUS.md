# AMD Windows validation — preflight, runtime-provenance verdict, and test plan

Status date: 2026-09-21. Validation slice: **STOPPED BEFORE GPU BENCHMARKING** —
the W5 fixed native WebGPU runtime is **not present anywhere on this workstation**.
This document is the Phase 0/1/2 record and the exact plan for unblocking Phase 3.

Machine: Windows 11 Pro workstation, AMD Ryzen 7 7840HS, AMD Radeon RX 9070 16 GB
eGPU + AMD Radeon 780M integrated GPU. Both target GPUs are AMD; vendor-level
monitoring cannot distinguish them, so all physical-execution proof must be
per-process GPU Engine activity correlated with DXGI LUIDs.

## Phase 0 — preflight (independently verified this session)

| Check | Result |
|---|---|
| Canonical repo | `P:\GIT\STEMwerk`, origin `https://github.com/flarkflarkflark/STEMwerk-reaper.git` |
| Canonical branch | `ci/repair-stale-release-checks` @ `57434e97f`, tracking origin, many pre-existing untracked files. Not touched beyond `git fetch`. |
| Fetch result | `origin/experiment/webgpu-ep` advanced `c760b8acb..11c616125` — expected HEAD `11c616125e227be325ec5978fef3a1d2f9a18ac5` **matches**; no newer commits exist. |
| Shared HEAD content | `11c616125` "fix W5 context crash and verify GPU selection" — includes `patches/0001-WebGPU-enforce-selected-Windows-adapter-LUID.patch` and `patches/0002-WebGPU-retain-selected-default-context.patch`. |
| Existing worktrees (Windows) | 4 under `P:\GIT\STEMwerk-worktrees\`; none suitable for this slice. Stale Linux-machine entries (`/mnt/PRODUCTION/...`, `/home/flark/...`) are administrative leftovers marked prunable. |
| `P:\GIT\STEMwerk-worktrees\webgpu-ep` | **Stale copied tree, not a git worktree here**: its `.git` file points to `/mnt/PRODUCTION/GIT/STEMwerk/.git/worktrees/webgpu-ep`, which does not exist on this machine. Content provenance unknown (references an unpushed HEAD `df1f4fe26`). Left untouched; not used. |
| Python on this machine | `py -3.11` (3.11.0) and `py -3.12` (3.12.0); canonical `.venv` is an empty 3.12 venv (pip only). The `C:\Users\Administrator\stemwerk-rnd\venvs\{webgpu-ep,webgpu-ep-demucsonnx}` environments referenced in W5 docs are **on the laptop, not here**. |
| GPU / driver | RX 9070 (eGPU) + Radeon 780M, both driver `32.0.31041.1004`; DXGI LUIDs not yet enumerated (Phase 3, blocked). |
| Toolchain here | **No VS/MSVC**: vswhere and `cl.exe` MISSING (same boundary the original W5 preflight recorded for this workstation). `cmake.exe` present on PATH. 64 GB RAM (≈50.6 GiB free), 4 GiB pagefile. Local rebuild from source is possible only after a user-approved VS Build Tools install. |

Fetch was performed as instructed; canonical branch, working tree, and untracked
files were not modified. The shared experiment branch was not checked out, pushed,
or committed to.

## Phase 1 — isolated worktree (done)

- `P:\GIT\STEMwerk-worktrees\webgpu-amd-windows` on new local branch
  `validate/webgpu-amd-windows`, based on `11c616125e227be325ec5978fef3a1d2f9a18ac5`.
- No checkout of `experiment/webgpu-ep` in the canonical directory; no interference
  with the W6 native-distribution work on the other machine.
- Models, audio, venvs, and large outputs stay outside Git (planned under `C:\` /
  `P:\MODELS` / `M:\`, never inside the worktree).

## Phase 2 — runtime provenance verdict

### What the W5 documentation (read at `11c616125`, `WINDOWS_NATIVE_BUILD_VALIDATION.md`)
records as the fixed runtime

Built on the Windows **laptop** at `C:\stemwerk-w5-local\` from ORT tag
`plugin-ep-webgpu/v0.3.0`, base `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`, W4 patch
commit `ab4ae2d6888f1a7f383427ca0701944c3a0954f3`, plus incremental fix commit
`1070be0cf9b10ea9e45d42d30d307ba459e673e5` (patch 0002, SHA-256
`fa3f51aaaf858fc68834481049b85fd01932ad0af7cb908a6df32d349c7f7f8a`):

| Artifact | Size | SHA-256 |
|---|---:|---|
| Fixed provider DLL `onnxruntime_providers_webgpu.dll` | 10,443,264 B | `b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248` |
| Fixed wheel `onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl` | 12,724,115 B | `e1469a3623609c10382839a07103b37a37600055673ca26642e42104e68dd74d` |

References (for detecting impostors): unpatched official 0.3.0 DLL is 10,522,976 B,
SHA-256 `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f`;
the pre-fix W4-patch DLL (crashes, do not use) is 10,443,264 B,
`d5ed4d5ed6d53a384594f626c7d2090fbc3ea8a53897507747226d6065bd422b`.
The wheel is coherent: provider DLL + `dxcompiler.dll` + `dxil.dll` built together.

### Search of THIS workstation (all negative)

- `C:\stemwerk-w5-local` — **does not exist**.
- `M:\stemwerk-w5\` (same SMB share the W5 doc used) — has `evidence/` (logs,
  crash dumps, MDX audio WAVs), `build/` logs, `preflight/`, `venvs/build`, but
  **no `*.whl` and no provider DLL anywhere** under `M:\stemwerk-w5` or
  `M:\stemwerk-w4`.
- Full-name searches for `*w5fix1*`, `onnxruntime_ep_webgpu*`,
  `onnxruntime_providers_webgpu.dll` across `P:\GIT`, `P:\stemwerk-rnd`,
  `P:\stemwerk-build-*`, `P:\TEMP`, `P:\WORK`, `P:\Download`, `P:\MODELS`,
  `P:\PROGRAMS`, `P:\CACHE`, `C:\Users\Administrator` (incl. pip cache) — nothing.
- No `onnxruntime_ep_webgpu` package installed in any accessible site-packages.

**Verdict: the W5 fixed native package is NOT available on this machine. Per the
slice rules, all GPU benchmarking (Phase 3) is STOPPED.** No MDX-Net or Demucs run
in this slice, and the official unpatched EP 0.3.0 is not being used to claim
explicit physical GPU selection.

## What is required from the other Windows machine (exact)

Transfer **one file** (the coherent wheel, preferred over a bare DLL swap):

1. `onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl`
   — expected 12,724,115 bytes, SHA-256
   `e1469a3623609c10382839a07103b37a37600055673ca26642e42104e68dd74d`.
   On the laptop it should be under `C:\stemwerk-w5-local\packages\` (built with
   `--output_dir M:\stemwerk-w5\packages`; if absent there, search
   `C:\stemwerk-w5-local` for `*.whl`).

Acceptable alternative if the wheel is lost but the build tree survives:
`onnxruntime_providers_webgpu.dll` (10,443,264 B, SHA-256
`b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248`) **plus its
co-built** `dxcompiler.dll`/`dxil.dll` from
`C:\stemwerk-w5-local\build\ort-webgpu-luid\Release\Release\`, with the wheel
rebuilt here via `plugin-ep-webgpu/python/build_wheel.py` — but transferring the
already-built wheel is strongly preferred. Do **not** mix the patched DLL with
DXC DLLs or base-ORT dependencies from any other wheel.

Transfer channel: copy to the shared SMB share (`M:\stemwerk-w5\packages\`) or any
`P:\` location; then verify the SHA-256 below before anything is installed.

## Reproducible isolated installation plan (this workstation, after transfer)

```powershell
# 0. Verify artifact integrity FIRST (must match exactly)
Get-FileHash <transfer-path>\onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl -Algorithm SHA256
# expect: e1469a3623609c10382839a07103b37a37600055673ca26642e42104e68dd74d

# 1. Fresh isolated runtime venv (outside the worktree; C: local NTFS)
py -3.11 -m venv C:\stemwerk-amd-win\venvs\runtime
C:\stemwerk-amd-win\venvs\runtime\Scripts\python.exe -m pip install --upgrade pip

# 2. Matching base runtime + the fixed wheel (base pin taken from W5: onnxruntime 1.30.0)
C:\stemwerk-amd-win\venvs\runtime\Scripts\python.exe -m pip install onnxruntime==1.30.0
C:\stemwerk-amd-win\venvs\runtime\Scripts\python.exe -m pip install <transfer-path>\onnxruntime_ep_webgpu-0.3.0+w5fix1-py3-none-win_amd64.whl
C:\stemwerk-amd-win\venvs\runtime\Scripts\python.exe -m pip install -r P:\GIT\STEMwerk-worktrees\webgpu-amd-windows\experiments\webgpu-ep\requirements-webgpu-experiment.txt
# if pip resolves onnxruntime-ep-webgpu==0.3.0 over the local wheel, use --no-deps for the
# local wheel and confirm: pip show onnxruntime-ep-webgpu must report 0.3.0+w5fix1

# 3. Loaded-module proof (import alone is NOT proof): in a fresh process, resolve the
#    actually-loaded DLL via psutil memory_maps and re-hash it from disk — must equal
#    b7a1c62395a5ae953cd362528d9856184fe231e9337289265d84397c963d3248.
```

Nothing is installed into production STEMwerk or the canonical `.venv` at any point.

## Phase 3 — prepared test matrix (executes only after step 3 passes)

Boundary: identical model + fixture + benchmark harness for every case.
- Model: MDX-Net, SHA-256 `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4` (52,786,726 B).
- Fixture: 25 s clip, SHA-256 `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` (4,410,044 B); located on this machine — to be confirmed and hashed before use.
- LUID discovery: `webgpu_adapter.list_webgpu_devices()` in the runtime venv to map RX 9070 and 780M to their DXGI LUIDs (fresh process; read-only).
- Physical-execution proof: `windows_gpu_monitor.py` (per-PID GPU Engine sampling,
  single-shot re-resolving loop — not `-Continuous`) correlated with the registry
  DXGI LUID table; fresh processes, fresh idle baselines per GPU; both GPUs are AMD
  so LUID-keyed per-process evidence is mandatory.
- MDX-Net: (a) CPU ONNX baseline, (b) WebGPU RX 9070, (c) WebGPU 780M — verify graph
  placement line, CPU-fallback rejection via `GpuExecutionNotProvenError`, numerical
  correctness vs CPU, stem routing, output WAV validity, memory, warm-repeat runs.
- Demucs: (a) CPU ONNX, (b) WebGPU RX 9070 only. **No Demucs on the 780M in this
  slice.** `ORT_ENABLE_BASIC` graph optimization retained (per slice rules).
- No Linux ROCm numbers will be presented as Windows GPU benchmarks.

## Remaining blockers and unknowns

1. **Blocker (stop-gate):** fixed W5 wheel/DLL absent from this workstation; one
   artifact transfer from the laptop unblocks everything.
2. This workstation has no MSVC/VS Build Tools; local source rebuild is a fallback
   only after a user-approved install (W5 documented the full procedure; the W4
   source copy exists at `M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0`, but
   note its SMB dubious-ownership issue — W5 relocated to local disk for that reason).
3. MDX model/fixture presence and hashes on this machine not yet verified.
4. Demucs-on-WebGPU dependency set for the isolated venv (beyond the MDX
   requirements file) to be confirmed when unblocked.
5. `git worktree list` in the canonical repo carries many stale Linux entries;
   harmless, but a cleanup pass should be coordinated with the W6 work.
