# Windows native LUID selection proof of concept (W4)

Status date: 2026-09-20. Experimental only. No production STEMwerk code, runtime,
environment, capability record, or installed WebGPU binary was changed.

## Executive result

W4 produced a source-grounded, reviewable patch against the exact
`plugin-ep-webgpu/v0.3.0` source. The patch carries the selected Windows
`OrtHardwareDevice`'s existing DXGI `LUID` metadata through the plugin configuration,
constrains Dawn with `dawn::native::d3d::RequestAdapterOptionsLUID`, verifies the
adapter returned by Dawn, and refuses cache reuse across different physical identities.

The machine still has no Visual Studio/MSVC, Windows SDK, CMake, Ninja, or alternate
C/C++ compiler. A native build therefore stopped at the explicit toolchain boundary.
No patched DLL exists, no patched DLL was loaded, and physical RTX/iGPU switching is
**not verified**. This is a patch and reproducible validation contract, not a runtime
PASS.

## Verdicts

| Requirement | Verdict | Evidence / boundary |
|---|---|---|
| 1. Root cause | **PASS** | Exact ORT and pinned Dawn sources confirm that ORT discovers a per-adapter LUID, but the released WebGPU plugin drops it before Dawn. Dawn's exact pinned D3D backend accepts an LUID and uses `EnumAdapterByLuid`. |
| 2. Patch implementation | **PASS** | Six-file, 202-line native patch committed in the isolated source checkout; `git diff --check` passed; full format-patch is preserved in this experiment. This means implemented/reviewable, not compiled. |
| 3. Native build | **BLOCKED** | MSVC/VS Build Tools, Windows SDK, CMake, and Ninja are absent. |
| 4. Patched runtime loading | **NOT TESTED** | No patched binary was built. |
| 5. Explicit RTX selection | **NOT VERIFIED** | Patched process was unavailable. |
| 6. Explicit AMD selection | **NOT VERIFIED** | Patched process was unavailable. |
| 7. Actual physical RTX execution | **NOT VERIFIED** | The unpatched baseline proves the monitoring method and existing RTX execution only. |
| 8. Actual physical AMD execution | **NOT VERIFIED** | No patched AMD run occurred. |
| 9. MDX-Net correctness on RTX | **NOT VERIFIED** | Unpatched 0.3.0 baseline passed; patched runtime did not run. |
| 10. MDX-Net correctness on AMD | **NOT VERIFIED** | No patched AMD run occurred. |
| 11. Invalid-device rejection | **NOT VERIFIED** | Fail-closed source path and tests were added, but the native tests could not be compiled or run. |
| 12. Cache correctness | **NOT VERIFIED** | Identity equality is enforced in source and compile-only tests were added; no native test binary ran. |
| 13. Production readiness | **BLOCKED** | No native build, patched load proof, or fresh-process physical A/B proof. Do not integrate. |

Demucs: **NOT TESTED**. W4 never reached the prerequisite of successful patched
MDX-Net selection on both GPUs.

## Git and workspace preflight

- Canonical checkout: `C:\Users\Administrator\Documents\GIT\STEMwerk`, branch
  `integration/2.4.0.0`, HEAD
  `af7a8572758e862e180f0677fbe0028ea5c7a748`. Its unrelated untracked `Microsoft/`
  and `pip/` entries were left untouched.
- Experiment worktree:
  `C:\Users\Administrator\Documents\GIT\STEMwerk-worktrees\experiment-webgpu-ep-win-nvidia`.
- Experiment branch starting HEAD and fetched `origin/experiment/webgpu-ep`:
  `350c8613393bc025efd845972b2620cbca1732df`; divergence before work: `0 0`.
- W3 and the requested W2/Demucs/resolver reports were read before patching.
- The upstream source work was isolated under `M:\stemwerk-w4`; nothing was put in
  either installed runtime or a global DLL search path.
- No reset, rebase, force operation, or push was performed.

## Exact provenance

### Installed, unmodified runtime

| Item | Exact value |
|---|---|
| Python environment | `C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep\.venv-webgpu` |
| Base ONNX Runtime | `onnxruntime 1.30.0` |
| Plugin package | `onnxruntime-ep-webgpu 0.3.0` |
| Published Windows wheel | `onnxruntime_ep_webgpu-0.3.0-py3-none-win_amd64.whl` |
| PyPI wheel SHA-256 recorded by W3 | `f25ed449a8f152176a20bc9b2f959a16511f16ff0f962a37979799d1b2d56bf7` |
| Installed DLL | `...\Lib\site-packages\onnxruntime_ep_webgpu\onnxruntime_providers_webgpu.dll` |
| Installed DLL size / SHA-256 | `10,522,976` bytes / `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| Wheel `RECORD` digest | `sFptUYeIW-kTOsOD1Sca8gt28oHnLYv-kz81oj0FuU8`, decoded and matched by W3 |

The installed DLL remained byte-for-byte untouched. As W3 noted, the release tag,
package date, version, and wheel manifest form coherent provenance, but they are not a
cryptographic build attestation tying the PyPI artifact to the Git commit.

### Exact isolated source and dependency

| Item | Exact value |
|---|---|
| ORT tag | `plugin-ep-webgpu/v0.3.0` |
| ORT base commit | `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c` |
| Isolated checkout | `M:\stemwerk-w4\onnxruntime-plugin-ep-webgpu-v0.3.0` |
| Local source branch | `w4-native-luid-poc` |
| Local patch commit | `ab4ae2d6888f1a7f383427ca0701944c3a0954f3` |
| Dawn tag | `v20260714.215939` |
| Dawn tag commit | `a192e3019a9a20db23329e631328b39b9867049a` |
| Dawn archive pin from `cmake/deps.txt` | SHA-1 `3056ed22d1606258ab43221b8c85b55b88614137` |
| Dawn inspection checkout | `M:\stemwerk-w4\dawn-v20260714.215939` |

The reviewable full diff is
[`patches/0001-WebGPU-enforce-selected-Windows-adapter-LUID.patch`](patches/0001-WebGPU-enforce-selected-Windows-adapter-LUID.patch).
Its SHA-256 is
`ebf88909a5023182005dccf46aea0d2d42e5073a20e777fb719e0978416c00ca`.

## Source finding and minimal mapping

The exact call chain is now closed:

1. `onnxruntime/core/platform/windows/device_discovery.cc` obtains each DXGI
   `DXGI_ADAPTER_DESC::AdapterLuid`, packs its high/low halves as a unique `uint64_t`,
   and stores the decimal value in `OrtHardwareDevice` metadata key `LUID`.
2. `OrtHardwareDevice::device_id` is explicitly only the hardware type/model ID; it
   is not unique. No ABI addition is necessary for W4.
3. Released `Factory::CreateEpImpl` receives the selected hardware device but only
   reads `IsVirtual`; the `LUID` dies at this boundary.
4. Released `WebGpuContext::Initialize` asks Dawn for a high-performance D3D12 adapter
   without a physical identity.
5. Pinned Dawn's `BackendD3D.cpp` reads `RequestAdapterOptionsLUID`, calls
   `EnumAdapterByLuid`, and returns no physical device if it fails. It does not fall
   back to another adapter in that branch.

The minimum correct mapping is therefore the existing selected hardware metadata
`LUID` -> strict decimal `uint64_t` plugin config -> Win32 `LUID` -> Dawn's native
request chain. Vendor ID + device ID is deliberately not used as physical identity,
and logical WebGPU `deviceId` remains only a context-cache slot.

## Patch behavior

The patch:

- adds internal option `ep.webgpuexecutionprovider.d3d12AdapterLuid`;
- derives it automatically from the selected real Windows `OrtHardwareDevice`;
- rejects missing device metadata and conflicting caller-supplied values;
- strictly parses an unsigned decimal 64-bit identity;
- rejects use with virtual devices, non-D3D12 backends, external Dawn, or an externally
  supplied WebGPU device where the constraint cannot be guaranteed;
- chains `dawn::native::d3d::RequestAdapterOptionsLUID` only for Windows bundled-Dawn
  D3D12 construction;
- obtains the actual returned `IDXGIAdapter`, reads its `AdapterLuid`, and enforces
  requested == observed before device creation proceeds;
- records requested/observed identities and refuses default-context cache reuse when
  an existing context has a different identity, including constrained vs unconstrained;
- leaves the existing unconstrained default behavior unchanged when no physical
  device was selected through the plugin-EP factory;
- leaves Linux/Vulkan and macOS/Metal adapter behavior unchanged.

Focused native tests were added for default semantics, propagation, matching cache
reuse, malformed input, non-D3D12 use, and constrained/unconstrained or cross-LUID
cache rejection. They are present in the patch but are **not run** because no native
test binary could be built.

The experiment-side `select_device()` and all relevant CLIs now accept
`adapter_luid`. The selector rejects multiple selector types, absent identities,
out-of-range identities, duplicate LUIDs, and ambiguous `device_id` matches. This is
the caller-side validation contract; the native patch remains the enforcement point.

## Toolchain preflight and build result

Current machine observation:

| Check | Result |
|---|---|
| Visual Studio / Build Tools directories | **MISSING** |
| `vswhere`, `cl`, `msbuild` | **MISSING** |
| Windows SDK installed-roots registry entry | **MISSING** |
| `cmake`, `ninja` | **MISSING** |
| `clang-cl`, `clang++`, `clang`, `g++`, `gcc` | **MISSING** |
| Python | 3.11.8 |
| Git | 2.52.0.windows.1 |
| RAM at preflight | 31.42 GiB total, 18.41 GiB free |
| Free disk at preflight | C: 71.07 GiB; M: 302.55 GiB |
| ORT CMake minimum | 3.28 |

The exact upstream Windows plugin job uses the
`onnxruntime-Win-CPU-VS2022-Latest` pool, generator `Visual Studio 17 2022`, vcpkg,
D3D12+Vulkan Dawn backends, Release/LTO, static WGSL templates, RTTI disabled, and a
six-hour job timeout. Its separately downloaded DXC is v1.8.2502 with zip SHA-256
`70B1913A1BFCE4A3E1A5311D16246F4ECDF3A3E613ABEC8AA529E57668426F85`.

The source checkout's submodules are not initialized, matching the plugin CI's
`checkout: submodules: none` plus `--skip_submodule_sync`; recorded pins are emsdk
`c0bb220cb6e6f4e0fabb6f6db9efd53390ef5e56`, libprotobuf-mutator
`7a2ed51a6b682a83e345ff49fc4cfd7ca47550db`, and ONNX
`2bb50465112feca9003e1ed654d77f01ff1415ca`. CMake/vcpkg still need to fetch a
multi-GB dependency/build footprint. Disk and RAM are plausible; the compiler, SDK,
and CMake are the hard blockers.

No system software was silently installed. Visual Studio Build Tools with the Desktop
development with C++ workload (MSVC v143 x64/x86 tools and a Windows 10/11 SDK) is a
material machine-level installation, so W4 stopped there. **Native build result:
BLOCKED; no build directory, DLL, wheel, warning log, or binary hash was produced.**

## Reproducible build procedure after the prerequisite is supplied

Run from the isolated source in an x64 VS 2022 developer shell. Use CMake >=3.28 and
keep build/package/test outputs under `M:\stemwerk-w4`; do not copy over the installed
wheel. This mirrors the pinned CI while enabling the focused unit tests and omitting
Microsoft's internal vcpkg cache switch:

```powershell
py -3.11 tools\ci_build\build.py `
  --config Release `
  --build_dir M:\stemwerk-w4\build\ort-webgpu-luid `
  --skip_submodule_sync `
  --cmake_generator "Visual Studio 17 2022" `
  --parallel --use_vcpkg --update --build --enable_onnx_tests `
  --use_webgpu shared_lib --wgsl_template static --disable_rtti --enable_lto `
  --cmake_extra_defines `
    onnxruntime_BUILD_UNIT_TESTS=ON `
    onnxruntime_ENABLE_DAWN_BACKEND_D3D12=1 `
    onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=1 `
    onnxruntime_PLUGIN_EP_VERSION=0.3.0

& M:\stemwerk-w4\build\ort-webgpu-luid\Release\Release\onnxruntime_test_all.exe `
  --gtest_filter=WebGpuContextTest.D3D12AdapterLuid*
```

Then obtain/verify CI's exact DXC package, place its x64 `dxcompiler.dll` and
`dxil.dll` beside the plugin, and build a complete isolated wheel rather than mixing
one new DLL with old wheel contents:

```powershell
py -3.11 -m pip install -r plugin-ep-webgpu\python\requirements-build-wheel.txt
py -3.11 plugin-ep-webgpu\python\build_wheel.py `
  --binary_dir M:\stemwerk-w4\build\ort-webgpu-luid\Release\Release `
  --version 0.3.0+w4luid `
  --output_dir M:\stemwerk-w4\packages
```

Install that wheel with a matching isolated base `onnxruntime` into a new W4 venv.
Record the hashes of the wheel, plugin DLL, DXC DLLs, and all loaded copies. Do not
reuse the current W3 venv and do not replace its DLL in place.

## Loaded-DLL and fresh-process verification contract

Each patched test must start a new Python process from the isolated W4 venv. After EP
registration and session creation, enumerate that process's loaded modules (for
example with `psutil.Process().memory_maps()`), resolve the absolute
`onnxruntime_providers_webgpu.dll` path, and hash the loaded file. The path and hash
must equal the newly built artifact, not the installed W3 DLL hash above. The log must
show both requested and selected LUID messages added by the patch and D3D12 as the
backend.

Run the no-selector, RTX LUID `64318`, AMD LUID `59967`, invalid, stale/unavailable,
and ambiguity cases in separate processes. Wrap the positive cases with
`w2_monitored_run.py` for a fresh idle baseline and use the dense
`w2_device_selection_probe.py --adapter-luid ...` for per-process attribution. A
selection PASS requires all of: requested LUID, Dawn/observed LUID, loaded patched
DLL, WebGPU placement, and positive activity on that same physical adapter. A quiet
other GPU is only negative corroboration.

The MDX command surface is now:

```powershell
py experiments\webgpu-ep\end_to_end_pipeline_test.py `
  C:\Users\Administrator\stemwerk-rnd\evidence\w1_fixture_25s.wav `
  --adapter-luid 64318 `
  --model-cache C:\Users\Administrator\stemwerk-rnd\model-cache `
  --out-dir M:\stemwerk-w4\evidence\patched-rtx --torch-device cpu
```

Repeat with `--adapter-luid 59967` and a new output directory/process. The invalid and
stale cases must terminate clearly before any alternative GPU work. Within one process,
create same-LUID contexts (allowed), cross-LUID contexts (rejected), and constrained vs
unconstrained reuse (rejected). A deliberate requested/observed mismatch must fail the
new equality assertion. Do not proceed to Demucs until both MDX physical paths pass.

## Physical identity map on this machine

| Adapter | Vendor/device | ORT `device_id` | DXGI LUID decimal / low hex |
|---|---|---:|---|
| NVIDIA GeForce RTX 3060 Laptop GPU | `0x10de:0x2520` | 9504 | `64318` / `0x0000fb3e` |
| AMD Radeon(TM) Graphics (integrated; not the separate Linux 780M) | `0x1002:0x1638` | 5688 | `59967` / `0x0000ea3f` |
| Microsoft Basic Render Driver | `0x1414:0x008c` | not exposed as WebGPU device | `64235` / `0x0000faeb` |

The two real adapters were cross-mapped through DXGI registry discovery, ORT device
metadata, and GPU Engine counter LUIDs. `device_id` is shown only for model identity
and legacy W1/W2 comparison; W4's physical contract uses the LUID.

## Unpatched 0.3.0 baseline

Model: `UVR_MDXNET_KARA_2.onnx`, 52,786,726 bytes, SHA-256
`bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4`.
Fixture: `w1_fixture_25s.wav`, 4,410,044 bytes, SHA-256
`658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32`.

The first attempt stopped before inference because `ffmpeg` was not on the process
PATH; it is not evidence. The retry added only the already installed STEMwerk ffmpeg
directory to that child process's PATH and exited 0:

- CPU load/run: 2.28 s / 17.49 s; WebGPU load/run: 0.83 s / 3.93 s.
- ORT: `185/185` nodes on `WebGpuExecutionProvider`; no hidden CPU node placement.
- Both outputs: 25.0 s, 44.1 kHz, stereo, finite, non-silent, no validation issue.
- Raw CPU/WebGPU correlation rounded to 1.0; max absolute difference was
  `1.10e-6` vocals and `1.03e-6` instrumental.
- File max absolute difference was `3.0517578125e-5`, one PCM16 LSB.
- Stem routing passed: same-stem correlation ~1.0 vs cross-stem ~0.1783.

The short E2E wrapper's per-process GPU Engine sampler did not catch the burst and its
fresh idle window had desktop noise (AMD max 9.04%, RTX max 36.78%); it is therefore
not used as physical attribution. The established dense probe in a fresh process did:
PID 7036 requested legacy `device_id=9504`, ORT returned LUID `64318`, placed 3 nodes
on WebGPU, and completed 1,249 repeated calls. Its own PID had five non-zero samples
only on RTX LUID `0000fb3e` (max 41.47%, average 34.36%, `3d` engine) and none on AMD.
This proves the unpatched RTX baseline and the monitor still work; it does not prove
the patch.

Evidence is kept outside Git under `M:\stemwerk-w4\evidence`. Models, audio, stems,
logs, venvs, binaries, and build outputs are not committed.

## Automated checks actually run

- `test_webgpu_adapter_selection.py`: **9/9 PASS**.
- Live selector enumeration returned RTX device `9504` for LUID `64318` and AMD
  device `5688` for LUID `59967`. This validates caller-side identity matching only,
  not which adapter the unpatched Dawn runtime executes on.
- `test_backend_resolver.py`: **27/27 non-skipped PASS**, with the same two expected
  Linux-only isolation cases skipped on Windows.
- Python compilation check for the modified selector and CLI scripts: **PASS**.
- Native patch `git diff --check`: **PASS** before the isolated commit.
- Native C++ tests: **NOT TESTED** (no compiler/build system).
- Capability matrix: unchanged; W4 generated no new patched hardware/model execution.

## ABI, packaging, and upstream scope

No public ORT hardware ABI change is needed because the stable physical identity is
already present in Windows metadata. The new key is internal plugin configuration;
the normal device-targeted API populates it from the selected hardware. The patch
depends on bundled Dawn's native D3D API and intentionally rejects configurations in
which enforcement cannot be guaranteed. Before upstreaming, maintainers should decide
whether the internal option name should be public/documented and add a factory-level
test with synthetic `OrtHardwareDevice` metadata if their test fixtures support it.

The smallest viable upstream contribution is the six-file patch plus Windows CI that
builds the unit tests and performs real dual-adapter A/B coverage where available.
Distribution requires a full matching plugin package (plugin DLL + DXC runtime and
matching base ORT), not an ad-hoc DLL swap.

## Recommended next slice

Provision an isolated VS 2022 Build Tools environment with MSVC v143, Windows SDK, and
CMake >=3.28; build and run the focused native tests; package a complete W4 wheel;
prove its loaded DLL path/hash; then run fresh-process RTX and AMD MDX tests with
positive per-LUID activity. Only after both physical paths and the invalid/cache cases
pass should production-readiness or conditional AMD Demucs feasibility be revisited.
