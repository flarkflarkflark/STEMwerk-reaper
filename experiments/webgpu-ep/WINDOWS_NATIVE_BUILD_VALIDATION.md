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

## Next step

Obtain explicit approval and complete the elevated Build Tools installation above.
Then resume W5 from toolchain verification—not from a claimed build—and execute the
isolated build, native tests, complete-wheel packaging, loaded-DLL proof, and fresh
default/RTX/AMD/negative/cache matrix. Production integration remains out of scope.
