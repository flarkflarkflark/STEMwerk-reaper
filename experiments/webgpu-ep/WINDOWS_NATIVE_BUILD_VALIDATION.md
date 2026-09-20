# Windows isolated native build and physical GPU A/B validation (W5)

Status date: 2026-09-20. Experimental only. W5 stopped at the explicitly required
administrator installation boundary. No build tool was installed, no native build was
started, and no production or existing experiment runtime was changed.

## Executive result

The W4 source patch and every pinned identity remain reproducible and clean, but this
workstation still has no supported Windows native compiler/SDK toolchain. An exhaustive
standard/nonstandard-location preflight found no Visual Studio, MSVC, MSBuild, Windows
SDK, CMake, Ninja, LLVM/clang-cl, GCC, or MinGW toolchain. The current shell is a
medium-integrity, non-elevated token; although the account belongs to Administrators,
that group is deny-only until UAC elevation.

The exact pinned ORT job builds with Visual Studio 17 2022. Microsoft states that
administrator rights are required to install or update Visual Studio. The supported
Build Tools installation is machine-registered and installs shared compiler/SDK
components, so changing `--installPath` would not make it a portable or user-scoped
toolchain. W5 therefore stopped before installation and before all build/runtime A/B
steps, as the mission requires.

No compiled DLL exists. Consequently explicit RTX-to-AMD switching remains **NOT
VERIFIED**; this report does not upgrade W4's source patch into a runtime claim.

## Layered W5 status

| Layer | Verdict | Evidence / boundary |
|---|---|---|
| SOURCE PATCHED | **PASS** | Isolated ORT checkout is clean at W4 commit `ab4ae2d6888f1a7f383427ca0701944c3a0954f3`. |
| BUILT | **BLOCKED** | Supported VS 2022/MSVC/Windows SDK installation requires administrator approval; none is installed. |
| LOADED | **NOT TESTED** | No W5 binary or package was produced. |
| DEVICE SELECTION VERIFIED | **NOT VERIFIED** | No patched RTX/AMD fresh-process A/B run was possible. |
| MODEL EXECUTION VERIFIED | **NOT TESTED** | Patched MDX-Net did not run. W4's unpatched control remains separate evidence. |
| FULL AUDIO VERIFIED | **NOT TESTED** | No patched audio run occurred. |

Demucs: **NOT TESTED**. Capability evidence: **UNCHANGED**.

## Git and environment preflight

After fetching origin:

- experiment local HEAD: `50f52a276adb9100c27c7607fead26ae3d1376de`;
- `origin/experiment/webgpu-ep`: the same full SHA;
- divergence: `0/0`; experiment worktree clean;
- canonical checkout: `af7a8572758e862e180f0677fbe0028ea5c7a748` on
  `integration/2.4.0.0`; its pre-existing untracked `Microsoft/` and `pip/` remain
  untouched;
- isolated ORT path recovered from W4, not guessed:
  `M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0`;
- isolated ORT source clean at
  `ab4ae2d6888f1a7f383427ca0701944c3a0954f3`, whose parent is exact base
  `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`;
- Dawn inspection checkout clean at
  `a192e3019a9a20db23329e631328b39b9867049a`;
- no W5 build/package/venv directories exist under `M:\stemwerk-w4`.

Existing experiment environments found under
`C:\Users\Administrator\stemwerk-rnd\venvs` are `webgpu-ep` and
`webgpu-ep-demucsonnx`. Neither was modified. The known WebGPU environment still has
CPython 3.11.8, `onnxruntime 1.30.0`, and `onnxruntime-ep-webgpu 0.3.0`.

## Exact source, dependency, and artifact provenance

| Item | Exact identity |
|---|---|
| ORT release tag | `plugin-ep-webgpu/v0.3.0` |
| ORT base | `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c` |
| W4 patch commit | `ab4ae2d6888f1a7f383427ca0701944c3a0954f3` |
| Dawn tag / commit | `v20260714.215939` / `a192e3019a9a20db23329e631328b39b9867049a` |
| Dawn archive SHA-1 from `cmake/deps.txt` | `3056ed22d1606258ab43221b8c85b55b88614137` |
| Preserved patch SHA-256 | `ebf88909a5023182005dccf46aea0d2d42e5073a20e777fb719e0978416c00ca` |
| Installed unpatched DLL size | 10,522,976 bytes |
| Installed unpatched DLL SHA-256 | `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| MDX model size / SHA-256 | 52,786,726 bytes / `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4` |
| 25-second fixture size / SHA-256 | 4,410,044 bytes / `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` |

The installed DLL hash, model hash, fixture hash, and patch hash were recomputed in
W5. They match W4. No file was replaced.

## W4 patch review before build

The actual isolated commit and preserved format-patch were reviewed. W5 found no new
source defect and did not redesign or edit the patch. It still:

- reads the selected real Windows `OrtHardwareDevice` metadata key `LUID`;
- keeps the physical LUID separate from logical WebGPU context `deviceId`;
- injects the decimal identity into internal WebGPU configuration;
- strictly parses a `uint64_t` and restricts it to bundled-Dawn D3D12 construction;
- chains `dawn::native::d3d::RequestAdapterOptionsLUID` into Dawn's adapter request;
- obtains the returned adapter's `IDXGIAdapter`, reads `AdapterLuid`, and enforces
  requested == observed;
- relies on pinned Dawn's `EnumAdapterByLuid` branch, which returns no adapter instead
  of falling back when lookup fails;
- rejects missing/conflicting metadata and unenforceable external-device/Dawn cases;
- rejects reuse of an active context whose physical identity differs, including
  constrained versus unconstrained reuse;
- retains unconstrained default behavior for callers that did not select a physical
  device through the plugin-EP factory; and
- leaves Linux/Vulkan and macOS/Metal behavior unchanged.

The reviewable patch remains at
`experiments/webgpu-ep/patches/0001-WebGPU-enforce-selected-Windows-adapter-LUID.patch`.

## Toolchain preflight

### Actual workstation state

| Check | Result |
|---|---|
| `cl`, MSVC linker, `msbuild`, `vswhere` | **MISSING** |
| Visual Studio standard directories and setup registry | **MISSING** |
| Windows SDK registry and standard directories | **MISSING** |
| `cmake` / Python `cmake` module | **MISSING** |
| `ninja` / Python `ninja` module | **MISSING** |
| `clang-cl`, `clang`, `clang++`, `gcc`, `g++` | **MISSING** |
| Searched user-local/AppData, Program Files, BuildTools/VS/Tools, Scoop, Chocolatey, MSYS2, Cygwin, LLVM, PortableApps, and M: tool locations | No usable toolchain found |
| `C:\Program Files\Git\usr\bin\link.exe` | Present, but this is the Unix `link` utility, not MSVC LINK.EXE |
| Python | 3.11.8 |
| Installed wheel build requirements | `setuptools 84.0.0`; `wheel` is not installed in the existing runtime venv (it must be installed only in a new W5 build venv) |
| Physical RAM | 31.42 GiB total; 18.42 GiB free at preflight |
| Pagefile | 2,048 MiB allocated; 24 MiB used/peak at preflight |
| Free disk | C: 71.06 GiB; M: 302.55 GiB |
| Isolated ORT checkout size | approximately 0.536 GiB |

The small 2 GiB pagefile means a full parallel Dawn/ORT build should use bounded
parallelism initially rather than all logical CPUs. Disk on M: is ample for an
isolated multi-GB dependency/build tree; C: has enough for the expected Build Tools
workload but should be rechecked after installation.

### Exact pinned build requirements

The pinned WebGPU plugin CI uses:

- pool `onnxruntime-Win-CPU-VS2022-Latest`;
- generator `Visual Studio 17 2022` (Ninja is optional, not required for this route);
- CMake minimum 3.28 (`cmake/CMakeLists.txt`);
- MSVC v143 x64/x86 compiler/linker, MSBuild, and a Windows SDK;
- Python plus the pinned CI requirements for configuring/tests;
- vcpkg mode; submodules intentionally absent with `checkout: submodules: none` and
  `--skip_submodule_sync`;
- dependency restoration through CMake/vcpkg, including Dawn from the exact archive
  pin above;
- Release, LTO, static WGSL templates, RTTI disabled, D3D12 and Vulkan Dawn backends;
- DXC v1.8.2502 package `dxc_2025_02_20.zip`, whose pinned CI SHA-256 is
  `70b1913a1bfce4a3e1a5311d16246f4ecdf3a3e613abec8aa529e57668426f85`;
- `setuptools>=77.0` and `wheel` for the complete plugin wheel.

The recorded but uninitialized submodule pins are emsdk
`c0bb220cb6e6f4e0fabb6f6db9efd53390ef5e56`, libprotobuf-mutator
`7a2ed51a6b682a83e345ff49fc4cfd7ca47550db`, and ONNX
`2bb50465112feca9003e1ed654d77f01ff1415ca`.

A coherent complete plugin wheel is required for W5 isolation. Swapping only a new
DLL into the existing 0.3.0 wheel would assume ABI/dependency compatibility and make
loaded-runtime provenance ambiguous, so W5 will not do that.

## Administrator installation boundary

`winget show --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget`
currently resolves to the Microsoft-published package:

| Field | Value |
|---|---|
| Package | `Microsoft.VisualStudio.2022.BuildTools` |
| Version | `17.14.41` |
| Publisher | Microsoft Corporation |
| Official installer URL | `https://download.visualstudio.microsoft.com/download/pr/bc92e2cb-33de-4a0c-995d-efa817f16b16/37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb/vs_BuildTools.exe` |
| Bootstrapper SHA-256 in winget manifest | `37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb` |
| Required workload | `Microsoft.VisualStudio.Workload.VCTools` — Desktop development with C++ |
| Required/recommended components | MSBuild; `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` (MSVC v143); `Microsoft.VisualStudio.Component.Windows11SDK.26100`; CMake tools; vcpkg |

Authoritative Microsoft references:

- `https://visualstudio.microsoft.com/downloads/`
- `https://learn.microsoft.com/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022`
- `https://learn.microsoft.com/visualstudio/releases/2022/system-requirements`

Microsoft documents 2.3–60 GB for Build Tools depending on selected features and
20–50 GB for a typical Visual Studio installation. Administrator rights are explicitly
required for installation/update. A minimal C++ Build Tools workload is expected to
be toward the lower part of that range, but the installer must display the exact
selected footprint before confirmation.

Exact user action required: open an elevated PowerShell and install the Microsoft
Build Tools package with the C++ workload and recommended components, for example:

```powershell
winget install --exact --id Microsoft.VisualStudio.2022.BuildTools `
  --source winget --accept-source-agreements --accept-package-agreements `
  --override "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

This action intentionally requires UAC elevation and must be performed or explicitly
approved by the user. W5 did not run it. Afterward, the next session must independently
verify the installed compiler, linker, MSBuild, SDK, CMake version (>=3.28), component
paths, signatures, remaining disk, RAM/pagefile, and a minimal compiler smoke test.
If the bundled CMake is absent or too old, install CMake only into a dedicated W5
build venv; do not change global PATH. Ninja is unnecessary for the supported Visual
Studio generator.

Why an isolated alternative is insufficient: ORT's pinned supported Windows job and
project generation target Visual Studio 17 2022/MSVC. A standalone LLVM executable
would still need Windows SDK/UCRT headers, import libraries, MSBuild/CMake integration,
and a tested generator/toolchain configuration that the pinned WebGPU plugin job does
not provide. Visual Studio Build Tools can use a custom payload/install directory,
but its installer and shared SDK/compiler registrations remain machine-level. No
official portable build container or prebuilt patched artifact exists for this local
commit.

## Reproducible build plan after approval

No command below was executed in W5. After the toolchain preflight succeeds, create a
new build venv and build/package entirely under `M:\stemwerk-w5`; do not modify the
existing WebGPU venv or DLL:

```powershell
py -3.11 -m venv M:\stemwerk-w5\venvs\build
& M:\stemwerk-w5\venvs\build\Scripts\python.exe -m pip install --upgrade pip
& M:\stemwerk-w5\venvs\build\Scripts\python.exe -m pip install `
  -r M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0\tools\ci_build\github\windows\python\requirements.txt

& M:\stemwerk-w5\venvs\build\Scripts\python.exe `
  M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0\tools\ci_build\build.py `
  --config Release `
  --build_dir M:\stemwerk-w5\build\ort-webgpu-luid `
  --skip_submodule_sync `
  --cmake_generator "Visual Studio 17 2022" `
  --parallel 4 --use_vcpkg --update --build --enable_onnx_tests `
  --use_webgpu shared_lib --wgsl_template static --disable_rtti --enable_lto `
  --cmake_extra_defines `
    onnxruntime_BUILD_UNIT_TESTS=ON `
    onnxruntime_ENABLE_DAWN_BACKEND_D3D12=1 `
    onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=1 `
    onnxruntime_PLUGIN_EP_VERSION=0.3.0

& M:\stemwerk-w5\build\ort-webgpu-luid\Release\Release\onnxruntime_test_all.exe `
  --gtest_filter=WebGpuContextTest.D3D12AdapterLuid*
```

Before packaging, download DXC only from the pinned Microsoft GitHub release and
verify its SHA-256 above. Place its x64 `dxcompiler.dll` and `dxil.dll` alongside the
built provider. Build a coherent experimental wheel:

```powershell
& M:\stemwerk-w5\venvs\build\Scripts\python.exe -m pip install `
  -r M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0\plugin-ep-webgpu\python\requirements-build-wheel.txt
& M:\stemwerk-w5\venvs\build\Scripts\python.exe `
  M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0\plugin-ep-webgpu\python\build_wheel.py `
  --binary_dir M:\stemwerk-w5\build\ort-webgpu-luid\Release\Release `
  --version 0.3.0+w5luid `
  --output_dir M:\stemwerk-w5\packages
```

Then create a separate runtime venv, install the matching base ORT plus this complete
wheel, and record hashes of the wheel, provider DLL, DXC DLLs, and loaded files.

## Runtime verification still required

Because no patched binary exists, every W5 runtime control is **NOT TESTED**:

- actual patched module path/hash;
- default-selection fresh process;
- explicit RTX LUID `64318` fresh process;
- explicit AMD LUID `59967` fresh process;
- independent positive RTX and AMD per-LUID GPU Engine activity;
- NVIDIA utilization/VRAM corroboration;
- D3D12 and WebGPU graph placement/no CPU fallback;
- patched numerical and full-audio correctness;
- invalid/stale/unavailable LUID rejection;
- repeated same-GPU use, cross-GPU active-context rejection, and constrained versus
  unconstrained cache behavior;
- ambiguous mapping where representable.

The short unpatched MDX control was not rerun after the installation boundary was
encountered. W4's immediately preceding control remains valid historical evidence:
185/185 WebGPU placement, correct numerical/audio output, and independent dense-probe
RTX activity on LUID `64318`. It is not patched-runtime evidence and is not counted as
a W5 selection result.

Once a build exists, each A/B case must start before Dawn initialization in a fresh
process. Loaded-module inspection must resolve and hash the actual live
`onnxruntime_providers_webgpu.dll`; matching a Python import is insufficient. Physical
selection requires positive activity on the requested LUID, not merely a provider
listing, session success, adapter name, graph-placement log, or quiet alternate GPU.

## Safe automated checks completed

- W4 selector tests: **9/9 PASS**.
- L11/W2 resolver policy: **27/27 non-skipped PASS**, with the same two expected
  Linux-only cases skipped on Windows.
- Capability matrix/schema: **PASS**, JSON exactly matches the Python source (11
  entries, 24 fields); no matrix file was regenerated or changed.
- Windows DXGI regression check: **PASS** — live map still reports RTX LUID `64318`,
  AMD iGPU LUID `59967`, and Basic Render Driver LUID `64235`.
- Python compilation checks for selector, probes, monitoring, resolver, and matrix:
  **PASS**.
- Native C++ tests: **NOT TESTED** — no compiler/build system.
- Hardware A/B tests: **NOT TESTED** — no patched runtime.

No new hardware/model fact was established, so `capability_matrix.py` and
`capability_matrix.json` remain unchanged.

## Next step (superseded by the section below)

Obtain explicit approval and complete the elevated Build Tools installation above.
Then resume W5 from toolchain verification—not from a claimed build—and execute the
isolated build, native tests, complete-wheel packaging, loaded-DLL proof, and fresh
default/RTX/AMD/negative/cache matrix. Production integration remains out of scope.

By the time the session below ran, Build Tools 2022 (MSVC v143, Windows SDK, CMake,
Ninja, vcpkg) had already been installed with user approval in an intervening session,
so this "Next step" (obtain approval, install) was already satisfied. It is kept here
verbatim as the historical record of what W5 originally asked for.

## W5 continued — network-share root cause, local-disk relocation, first real build attempt

Status date: 2026-09-20, same day, later session. Toolchain preflight from the
sections above is no longer current: VS Build Tools 2022 (MSVC 14.44.35207, Windows
SDK, CMake, Ninja, vcpkg at
`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\vcpkg\vcpkg.exe`)
was installed and confirmed working by an intervening session. This session picks up
from there.

### What happened on the network share (for the record; not used going forward)

An intervening session attempted the isolated build directly on `M:` (the SMB share
`\\192.168.68.99\music`, mapped `M:`) under `M:\stemwerk-w5\build\ort-webgpu-luid`. It
root-caused a real, systemic problem: Git's "dubious ownership" check (the
CVE-2022-24765 mitigation) silently rejected every one of Dawn's 19 fetched
`third_party/*` checkouts under that build tree, because SMB reports file ownership in
a way that does not match the local Windows user's SID. That session applied a
user-authorized, narrowly scoped fix — 19 individual
`git config --global --add safe.directory` entries for the exact 19 affected paths, no
wildcard — and cleared the 19 stale/broken checkouts, then was blocked by this
environment's own permission system from verifying the fix or relaunching the build in
that session.

This session independently reproduced the same class of failure directly against the
W4 source checkout itself (not just the build tree) before touching anything:

```
$ git -C M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0 status
fatal: detected dubious ownership in repository at
'//192.168.68.99/music/stemwerk-w4/onnxruntime-plugin-ep-webgpu-v0.3.0'
```

That confirms the SMB-ownership problem is systemic to `M:`, not confined to the one
build tree the prior session found. Given that, and given the user's decision to stop
fighting the share, this session did not add any further `safe.directory` entries
(no additional git config changes were made anywhere, global or local) and instead
copied the source to local disk, where a normal local owner SID makes the whole
problem moot.

`M:\stemwerk-w5\build\ort-webgpu-luid` (the prior network-share build tree) was left
untouched, as instructed — it is historical evidence of the SMB root-cause finding,
not a live build.

### Local working area

New local root: `C:\stemwerk-w5-local\`. Chosen because it is clearly outside
`C:\Users\Administrator\Documents\GIT\STEMwerk` (the canonical checkout), outside any
worktree, and outside both protected venvs
(`C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep` and
`...\webgpu-ep-demucsonnx`, neither of which was opened, imported from in a way that
mutates them, or modified — see verification below).

Free space before starting: 59.07 GiB on `C:`. Plan (source copy + build venv + full
vcpkg/Dawn/ORT build tree) was judged to fit comfortably against the 2.3–60 GB Build
Tools range already spent and the 10–20 GB estimated for the build tree itself, so the
work proceeded without asking first, per the standing free-space guidance in the brief.

### Source copy (not re-clone)

`M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0` was copied with
`robocopy /E /COPY:DAT /R:2 /W:2 /MT:8` (multi-threaded, data+attributes+timestamps,
includes `.git`) to
`C:\stemwerk-w5-local\onnxruntime-plugin-ep-webgpu-v0.3.0`. Robocopy's own summary:

```
Dirs :      1328      1328         0         0         0         0
Files :     10971     10971         0         0         0         0
Bytes :  778.01 m  778.01 m         0         0         0         0
```

(Robocopy's process exit code was `1`, which in Robocopy's own bitmask convention means
"one or more files copied successfully," not failure — verified against the log
above, which shows 0 Failed for both dirs and files.)

Post-copy verification, all independently checked, not assumed:

- `git -C C:\stemwerk-w5-local\onnxruntime-plugin-ep-webgpu-v0.3.0 status`: clean
  working tree, branch `w4-native-luid-poc`, **no dubious-ownership error** (confirms
  the local-disk relocation actually fixes the SMB ownership problem, as expected —
  the local copy is owned by the local user SID).
- `git rev-parse HEAD`: `ab4ae2d6888f1a7f383427ca0701944c3a0954f3` — matches the
  required W4 patch commit exactly.
- `git log --oneline -3` shows the patch commit directly on top of upstream base
  `caf2ed3` (`caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`), i.e. exactly the reviewed W4
  history, not a re-clone or re-applied patch.

### Independent re-verification of every pinned identity (before building)

All of the following were recomputed fresh in this session, not copied from prior
reports:

| Item | Recorded reference | Recomputed this session | Match |
|---|---|---|---|
| Installed unpatched DLL SHA-256 | `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` | same (10,522,976 bytes) | **YES** |
| MDX model SHA-256 | `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4` | same (52,786,726 bytes) | **YES** |
| 25s fixture SHA-256 | `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` | same (4,410,044 bytes) | **YES** |
| W4 patch file SHA-256 | `ebf88909a5023182005dccf46aea0d2d42e5073a20e777fb719e0978416c00ca` | same | **YES** |
| RTX 3060 DXGI LUID | `64318` | same, via live `webgpu_adapter.list_webgpu_devices()` against the existing unpatched venv (read-only import; venv not modified) | **YES** |
| AMD iGPU DXGI LUID | `59967` | same, via the same live enumeration | **YES** |

The DLL hash check reads the file only (`Get-FileHash`); the device enumeration only
imports `webgpu_adapter` and calls `list_webgpu_devices()` in the existing
`webgpu-ep` venv's own interpreter, which performs no writes. Neither protected venv
was installed into, upgraded, or had its DLL touched.

### Build venv and launch

```
py -3.11 -m venv C:\stemwerk-w5-local\venvs\build
C:\stemwerk-w5-local\venvs\build\Scripts\python.exe -m pip install --upgrade pip
C:\stemwerk-w5-local\venvs\build\Scripts\python.exe -m pip install -r C:\stemwerk-w5-local\onnxruntime-plugin-ep-webgpu-v0.3.0\tools\ci_build\github\windows\python\requirements.txt
```

installed cleanly (onnx 1.22.0, onnxscript 0.6.2, numpy 2.4.2, etc., matching the
pinned CI requirements file for this ORT revision).

The build was launched via a small `run_build.bat` under `C:\stemwerk-w5-local\` that
calls `VsDevCmd.bat -arch=x64` and then the exact build command from the brief,
adapted only for local paths (`--build_dir C:\stemwerk-w5-local\build\ort-webgpu-luid`,
same `--parallel 4` and all other flags unchanged), launched with
`run_in_background: true` and its own log redirected to
`C:\stemwerk-w5-local\build_log.txt` — the same proven pattern used successfully by
the prior session.

### Build result: real progress, then a genuine new failure (not a timeout, not "needs more time")

This is materially further than any prior W4/W5 session reached: the build was never
blocked at a toolchain-absence boundary this time. vcpkg fetched and built its
dependency set (e.g. abseil), CMake configuration completed (`-- Generating done`),
and MSBuild successfully compiled a large number of real ORT/Dawn targets, including
MLAS's hand-written x64 assembly kernels (`SgemmKernelFma3.asm`,
`SconvKernelAvx512F.asm`, etc.), `onnxruntime_flatbuffers.lib`, and Dawn's bundled
`LLVMTableGen.lib` (part of the DirectXShaderCompiler dependency tree). `cl.exe` and
`MSBuild.exe` processes were confirmed actively running via `Get-Process` during this
window.

The build then failed with exactly one root-cause compiler error (confirmed to be the
only `error C####`/`error LNK`/`error MSB` line anywhere in the 4,664-line build log):

```
C:\stemwerk-w5-local\build\ort-webgpu-luid\Release\_deps\dawn-src\third_party\directx-shader-compiler\src\include\dxc\Support\WinIncludes.h(44,10):
error C1083: Cannot open include file: 'atlbase.h': No such file or directory
[...LLVMMSSupport.vcxproj]
```

`tools\ci_build\build.py` correctly propagated this as a fatal failure
(`subprocess.CalledProcessError` from the `cmake --build` invocation, non-zero exit),
and no `onnxruntime_providers_webgpu.dll` exists anywhere under
`C:\stemwerk-w5-local\build` (confirmed by filesystem search of the whole build tree,
not just the expected output path).

This was independently root-caused, not just trusted from the compiler message:

```
Get-ChildItem "...\BuildTools\VC\Tools\MSVC\*\include\atlbase.h"   -> no results
vswhere -requires Microsoft.VisualStudio.Component.VC.ATL          -> no results
```

The installed VS Build Tools 2022 instance does not have the **"C++ ATL for latest
v143 build tools (x86 & x64)"** optional component. Dawn's bundled
DirectXShaderCompiler (which Dawn needs for D3D12 HLSL/DXC shader compilation) links
an `MSSupport` helper library that requires ATL headers on Windows; that component was
not part of the originally installed Build Tools workload.

### Why this stops here instead of being pushed through

Fixing this requires modifying the machine's Visual Studio Build Tools installation
(adding the ATL component via the Visual Studio Installer, which needs elevation) —
the same class of machine-level, outside-the-build-tree action the brief explicitly
reserves for user check-in, not something this session is authorized to do
unilaterally. No such installation was attempted. No other git config, global config,
or system-wide change was made in this session (the SMB `safe.directory` question
above was investigated read-only, and resolved by not needing any such entries at all,
since the local copy has no ownership problem to begin with).

This was checked, not assumed: the current process's Windows token was independently
inspected (`WindowsIdentity`/`WindowsPrincipal`, read-only) and confirmed **not
elevated** (`IsInRole(Administrator)` = `False`), even though the account name is
`FLARKTOP25\Administrator` — matching the same deny-only-until-UAC pattern recorded in
the original W4/W5 preflight. So even setting policy aside, this session has no
technical path to run the Visual Studio Installer's elevated modify operation itself.
Re-confirmed the error count at this point too: exactly one distinct
`error C`/`error LNK`/`error MSB` line exists anywhere in the 4,664-line build log —
the single `C1083` on `atlbase.h` above. There is no second failure hiding behind it
yet; whether one exists can only be known after the ATL component is added and the
build is resumed.

### Disk

Free space check before the build (`C:`): 58.07 GiB (after the ~0.78 GiB source copy
and build venv). After the failed build attempt: 45.28 GiB free — the partial
vcpkg+Dawn+ORT build tree under `C:\stemwerk-w5-local\build` consumed about 19.6 GiB
by itself. No exhaustion occurred and none was imminent; there is ample remaining
headroom (~45 GiB) for a resumed build after the ATL component is added, especially
since vcpkg's already-built packages and CMake's configured build tree should mostly
be reusable (only the Dawn/DXC portion needs to re-run past its current failure
point), so a resumed build is expected to need meaningfully less fresh work than this
first attempt.

### Updated layered status

| Layer | Verdict | Evidence / boundary |
|---|---|---|
| NETWORK-SHARE ROOT CAUSE | **PASS** (diagnostic only) | SMB dubious-ownership reproduced directly against the W4 source checkout on `M:`; confirmed systemic, not build-tree-specific. |
| LOCAL RELOCATION | **PASS** | Source copied via robocopy (10,971/10,971 files, 0 failed); local copy clean at exact required commit `ab4ae2d6888f1a7f383427ca0701944c3a0954f3`; no dubious-ownership error locally. |
| SOURCE PATCHED | **PASS** | Same as W4: isolated local checkout clean at the reviewed patch commit. |
| BUILT | **BLOCKED (new, different reason)** | Toolchain is present and the build ran for real this time; it fails deterministically on a missing VS Build Tools ATL component needed by Dawn's bundled DirectXShaderCompiler. No `onnxruntime_providers_webgpu.dll` was produced. |
| LOADED | **NOT TESTED** | No W5 binary exists yet. |
| DEVICE SELECTION VERIFIED | **NOT VERIFIED** | Unchanged — no patched runtime. |
| MODEL EXECUTION VERIFIED | **NOT TESTED** | Unchanged. |
| FULL AUDIO VERIFIED | **NOT TESTED** | Unchanged. |

Demucs: **NOT TESTED**. Capability evidence: **UNCHANGED** — no new hardware/model
execution fact was established this session, so `capability_matrix.py` and
`capability_matrix.json` are intentionally left unmodified.

### Next step (superseded by the section below)

Install the "C++ ATL for latest v143 build tools (x86 & x64)" component into the
existing VS Build Tools 2022 instance (Visual Studio Installer, requires elevation —
explicit user action, same as the original Build Tools installation). Then re-run
`C:\stemwerk-w5-local\run_build.bat` unchanged (build_dir and vcpkg state are already
local and warm); on success, proceed directly to the loaded-DLL hash proof, fresh
default/RTX/AMD/invalid/cache A/B matrix, and MDX-Net correctness exactly as scoped in
the W4/W5 runtime-verification contracts above. `C:\stemwerk-w5-local\` and
`M:\stemwerk-w5\build\ort-webgpu-luid` (historical) are unaffected by each other and
can coexist.

## W5 continued — build succeeds, then a new blocking execution-time crash

Status date: 2026-09-20, same day, later still. The user installed the "C++ ATL for
latest v143 build tools (x86 & x64)" component and this session independently
re-verified it before touching anything: `vswhere -requires
Microsoft.VisualStudio.Component.VC.ATL` resolved to the installed Build Tools
instance, `atlbase.h` was found on disk at the exact expected MSVC-toolset path with a
fresh timestamp, and no installer/build process was left running.

### Build resumed and completed successfully

`C:\stemwerk-w5-local\run_build.bat` was re-run unchanged (same flags, same
`--build_dir`, same `run_in_background: true` + VsDevCmd method). The prior failing
target now compiles cleanly — `LLVMMSSupport.vcxproj -> ...\LLVMMSSupport.lib` appears
in the log with no `atlbase` error anywhere in the new log. The build proceeded through
linking `onnxruntime_providers_webgpu.dll` itself and building
`onnxruntime_test_all.exe`, `onnxruntime_provider_test.exe`, and
`onnxruntime_perf_test.exe`, and finished with **`BUILD_EXIT_CODE=0`** — the first
fully successful native build in this experiment's entire history (W1 through W5).

**New patched DLL, independently hashed:**

| | Size | SHA-256 |
|---|---|---|
| Unpatched reference (unchanged) | 10,522,976 B | `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| **New patched build** | **10,443,264 B** | **`d5ed4d5ed6d53a384594f626c7d2090fbc3ea8a53897507747226d6065bd422b`** |

Different size, completely different hash, as expected for a real independent build
(not merely a copy) of materially different (patched) source.

### Packaging and loaded-module proof

A coherent wheel was built with the plugin's own `build_wheel.py` (not an ad-hoc DLL
swap into the old 0.3.0 wheel, per this experiment's own stated principle) from
`C:\stemwerk-w5-local\build\ort-webgpu-luid\Release\Release`, which already contained
matching `onnxruntime_providers_webgpu.dll`, `dxcompiler.dll`, and `dxil.dll` built
together in the same compile (this build compiles DXC from Dawn's bundled
`third_party/directx-shader-compiler` source rather than needing the separately
downloaded pinned DXC release package): `onnxruntime_ep_webgpu-0.3.0+w5local-py3-none-win_amd64.whl`.

A new isolated runtime venv, `C:\stemwerk-w5-local\venvs\runtime`, separate from both
protected production venvs (neither of which was opened, imported into, or modified),
was created with the matching base `onnxruntime==1.30.0` (confirmed via a read-only
`pip show` against the existing `webgpu-ep` venv, not assumed) plus this new wheel.

Loaded-module proof, in a real running process (not just "importable"): resolved via
`psutil.Process().memory_maps()`, the actually-loaded
`onnxruntime_providers_webgpu.dll` in that live process was re-read from disk and
re-hashed:

```
LIVE LOADED PATH:   C:\stemwerk-w5-local\venvs\runtime\Lib\site-packages\onnxruntime_ep_webgpu\onnxruntime_providers_webgpu.dll
LIVE LOADED SHA256: d5ed4d5ed6d53a384594f626c7d2090fbc3ea8a53897507747226d6065bd422b
```

This matches the newly built artifact exactly and differs from the unpatched
reference. **LOADED: PASS.** The same process's live device enumeration re-confirmed
the LUID map yet again: AMD iGPU `LUID=59967`, RTX 3060 `LUID=64318`.

### Session creation, adapter matching, and placement: PASS on both physical GPUs

Using `webgpu_adapter.select_device(adapter_luid=...)` and
`create_verified_webgpu_session(...)` (the exact production wrapper used throughout
this experiment) against a small ONNX Conv graph, in fresh Python processes:

- **RTX 3060 (LUID 64318):** session created successfully; `report['all_nodes_placed_line']`
  = `"All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 3"`. The native
  patch's internal adapter-match assertion (requested LUID == Dawn-observed LUID) did
  not fire, meaning Dawn genuinely returned the RTX adapter when RTX was requested.
- **AMD iGPU (LUID 59967):** same result — session created, same placement line, same
  adapter-match success.

This is real, new evidence beyond anything in W1-W5 to date: it is the first time the
patch's actual compiled adapter-selection code has run against real hardware for
either GPU.

### The decisive execution test: BLOCKED by a new, reproducible crash — not a PASS

Per this experiment's own explicit rule, session creation and graph placement are
**not sufficient** to claim GPU-selection PASS; physical execution must be positively
observed. Attempting that decisive step surfaced a new, serious, reproducible problem:

The very first `session.run()` call after a successful, correctly-placed WebGPU
session — for a trivial single-`Conv`-node graph, not MDX-Net's full graph — crashes
the Python process. The crash was captured with the real Windows exit code (not
bash's lossy translation, which reported a confusing `127`):

```
EXITCODE = -1073740791  =  0xC0000409  =  STATUS_STACK_BUFFER_OVERRUN
```

This was reproduced **identically on both physical adapters** (RTX 3060 LUID `64318`
and AMD iGPU LUID `59967`), both times immediately on the first inference call, after
session creation and correct WebGPU placement had already succeeded without error.
Because the crash occurs strictly *after* `WebGpuContext::Initialize()`'s new
LUID-matching code has already run to completion (session creation returns
successfully with a correct placement report before any `session.run()` is called),
this points at the general compute-kernel-dispatch path in this specific from-source
build, not at the 202-line LUID patch's own code — but that is a hypothesis, not a
proven root cause; it was not feasible in this session to build a non-patched control
from the exact same from-source toolchain/dependency versions to confirm the patch is
uninvolved.

The W2 dense GPU-monitoring probe (`w2_device_selection_probe.py`, the tool that
produced this whole experiment's decisive Linux/N1/W1/W2 physical-execution evidence)
was the first thing that hit this crash; it was then reproduced with a minimal,
hand-written single-inference repro to rule out the probe script or its concurrent
PowerShell `Get-Counter` monitor subprocess as the cause (a version with no monitor
and no loop, just one `session.run()` call, crashes identically). **Consequently: no
GPU-Engine-counter/nvidia-smi physical-execution evidence could be collected for
either GPU, because the process does not survive long enough to be sampled**, and
**MDX-Net was not attempted at all** — a graph orders of magnitude more complex than
the single-node probe that already crashes reliably would not be a meaningful
additional data point.

**Per this experiment's explicit rule, this is reported as-is: DEVICE SELECTION
VERIFIED remains NOT VERIFIED. Build success, correct placement, and a differing DLL
hash are real and reported as such, but are explicitly not treated as, or conflated
with, a GPU-selection PASS.**

### What *did* get proven safely (no kernel execution involved)

Session creation/placement (above) and the following rejection-path tests all
complete before reaching the crashing kernel-dispatch code, so they were run safely
and are real, positive evidence about the patch's own logic, independent of the
execution-crash question:

| Test | Result |
|---|---|
| Mismatched explicit LUID vs. selected hardware device (via the production `create_verified_webgpu_session(..., extra_options={"d3d12AdapterLuid": "999999"})` path) | **PASS** — native EP creation fails with exactly the patch's own message, `"The requested D3D12 adapter LUID does not match the selected OrtHardwareDevice."`; ORT's generic provider-creation-failure behavior silently falls back to CPU (a stock ONNX Runtime behavior, not a patch defect), and the production wrapper's own `get_providers()` safety check correctly catches that silent fallback and raises `GpuExecutionNotProvenError` rather than reporting a false PASS. |
| Cross-GPU active-context reuse: a second session targeting the AMD device in the same default WebGPU context (`context ID 0`) already initialized for RTX | **PASS** — native rejection with exactly the patch's own message, `"WebGPU context ID 0 is already initialized for a different D3D12 adapter LUID; refusing to reuse a physical GPU context for another request."`; correctly surfaced as a wrapper-level rejection. |
| Same-GPU repeated context reuse (two RTX sessions, same context) | **PASS** — second session succeeds, matching cached identity, as designed. |
| Malformed/out-of-range LUID selector strings (`"-1"`, `"notanumber"`, `1<<65`) at the Python selector layer | **PASS** — all three rejected with the expected messages (same behavior the 9/9 unit tests already covered; re-confirmed live). |

These four results are genuine, first-time confirmations that the patch's native
rejection logic — the parts of the 202-line patch that run at `CreateEpImpl`/
`Initialize` time, before any GPU kernel executes — behaves exactly as the source
review and W4's compile-only unit tests (never previously run, see below) predicted.

### Native C++ unit tests: still not executable, for a different, now-understood reason

`onnxruntime_test_all.exe --gtest_filter=WebGpuContextTest.D3D12AdapterLuid*` matched
zero tests. This is not a build failure — the tests exist in
`onnxruntime/test/providers/webgpu/webgpu_context_test.cc` in the source tree, and a
full `--gtest_list_tests` scan of the two candidate binaries
(`onnxruntime_test_all.exe`, `onnxruntime_provider_test.exe`) confirms neither
contains any `WebGpuContextTest`-suite test at all. The reason is a real, independently
confirmed detail in this ORT revision's `cmake/onnxruntime_unittests.cmake`: the
`${TEST_SRC_DIR}/providers/webgpu/*` test-source glob (which is where
`webgpu_context_test.cc` lives) is only added when
`onnxruntime_USE_WEBGPU AND NOT onnxruntime_USE_EP_API_ADAPTERS` (lines ~722 and
~794). The exact pinned CI/W4/W5 build command uses `--use_webgpu shared_lib`, which
sets `onnxruntime_USE_EP_API_ADAPTERS` (the plugin-EP build mode) — the same mode the
patch itself targets (`Factory::CreateEpImpl` in `ep/factory.cc` only exists in plugin
builds). So under the exact build configuration this whole experiment is required to
use, `webgpu_context_test.cc` — and therefore every native unit test the W4 patch
added to it — is unconditionally excluded from compilation, regardless of toolchain.
This was not knowable before a build actually succeeded; W4/W5 had always attributed
"native tests not run" to "no compiler," which was true but incomplete — even with a
working compiler, these specific tests are excluded by this project's own CMake
source-partitioning logic under the mandated plugin-EP build mode. This is reported as
a real limitation, not something this session altered (no test-source-inclusion
CMake logic was changed to try to force them in, since that would deviate from the
exact pinned/reviewed build configuration).

### Updated layered status

| Layer | Verdict | Evidence / boundary |
|---|---|---|
| BUILT | **PASS** | `BUILD_EXIT_CODE=0`. New DLL, 10,443,264 B, SHA-256 `d5ed4d5e...` — differs from unpatched `b05a6d51...`. |
| PACKAGED | **PASS** | Coherent wheel built via `build_wheel.py`, includes matching `dxcompiler.dll`/`dxil.dll` from the same build. |
| LOADED | **PASS** | Live-process `psutil` module resolution + re-hash matches the new build exactly, in a runtime venv separate from both protected production venvs. |
| SESSION CREATION / ADAPTER MATCH / PLACEMENT | **PASS (both GPUs)** | RTX 3060 and AMD iGPU each: session created, Dawn-observed LUID matched requested LUID, all nodes placed on `WebGpuExecutionProvider`. |
| INVALID-LUID REJECTION | **PASS** | Native `EP_FAIL`/`INVALID_ARGUMENT` with the patch's exact source message; correctly surfaced past ORT's own CPU-fallback behavior by the production wrapper. |
| CROSS-GPU CONTEXT REJECTION | **PASS** | Native `ORT_ENFORCE` failure with the patch's exact source message; correctly surfaced by the wrapper. |
| SAME-GPU CONTEXT REUSE | **PASS** | Second same-adapter session succeeds as designed. |
| **DEVICE SELECTION VERIFIED (decisive physical-execution proof)** | **BLOCKED — NEW CRASH, NOT VERIFIED** | First `session.run()` call crashes the process with `STATUS_STACK_BUFFER_OVERRUN` (`0xC0000409`), identically on both RTX and AMD, for even a single-node graph. No GPU-Engine-counter or nvidia-smi evidence could be collected. |
| MODEL EXECUTION VERIFIED (MDX-Net) | **NOT TESTED** | Not attempted — the simpler synthetic-graph crash already reproduces reliably; running MDX-Net would not add information and would only consume further time against the same blocking crash. |
| FULL AUDIO VERIFIED | **NOT TESTED** | Unchanged. |
| NATIVE C++ UNIT TESTS | **NOT RUNNABLE IN THIS BUILD MODE** | Real CMake source-partitioning behavior, independently confirmed; not a toolchain gap this time. |

Demucs: **NOT TESTED**. Capability evidence: **UNCHANGED** — a crash blocking the
decisive physical-execution proof is not new positive hardware/model evidence, so
`capability_matrix.py`/`capability_matrix.json` are intentionally left unmodified.

### Why this stops here instead of being pushed through

`STATUS_STACK_BUFFER_OVERRUN` indicates real memory corruption (a `/GS` security-cookie
failure or an explicit `__fastfail`), not a benign or recoverable error. Retrying
blindly, disabling `/GS`, changing optimization/LTO flags, or otherwise altering the
build configuration to "get past" a memory-safety crash are all more than a narrow,
build-tree-local fix, and diagnosing a stack-corruption bug in a multi-hundred-MB
freshly-compiled Dawn/DXC/ORT tree is a substantial new investigation in its own
right — squarely the kind of new, non-obvious problem this experiment's own rules say
to stop and report rather than push through. No build configuration was changed, no
flags were altered, and no further build was attempted after this was found.

### Next step

Decide, with the user, how to pursue root-causing the execution-time crash: candidates
worth investigating include building a non-LTO / non-`/GS`-affecting configuration for
comparison, checking whether this is a known Dawn/DirectXShaderCompiler issue for the
pinned Dawn tag `v20260714.215939` combined with locally-resolved (not CI-pinned-exact)
vcpkg dependency versions, capturing a crash dump (`WerFault`/`procdump`) for a full
stack trace rather than only the NTSTATUS code, or testing whether the crash is
specific to `--enable_lto`/`--wgsl_template static` by building one variant without
each flag. Until the crash is root-caused and fixed, the decisive physical-execution
proof — the central question the whole W1-W5 arc has been building toward — remains
open, despite this session's real progress (first successful build, first loaded
patched DLL, first confirmed-correct adapter selection and placement on real hardware
for both hardware paths, and first confirmed-correct native rejection-path behavior).
