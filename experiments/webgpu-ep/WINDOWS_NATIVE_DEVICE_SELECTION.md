# Windows Native WebGPU EP Device Selection — Phase W3 (source-level)

Status date: 2026-09-20. Companion to `WINDOWS_MULTI_GPU_SELECTION.md` (W2), whose
binary-only scan this phase goes one level deeper on: **actual upstream source**, at
the exact tagged release matching the installed package, not current `main`.

**Headline result: root cause confirmed at the exact source line, not just inferred
from binary strings.** `onnxruntime-ep-webgpu` 0.3.0's plugin-EP factory
(`Factory::CreateEpImpl`, `onnxruntime/core/providers/webgpu/ep/factory.cc`) reads the
caller-selected `OrtHardwareDevice` exactly once — to check a single `IsVirtual`
metadata flag — and never again. The device's identity (vendor id / device id / LUID)
is never copied into the `ConfigOptions` passed to `WebGpuProviderFactoryCreator::Create()`,
and `WebGpuContext::Initialize()` (`webgpu_context.cc`) builds Dawn's
`wgpu::RequestAdapterOptions` with only `backendType` and `powerPreference` populated
(default `WGPUPowerPreference_HighPerformance`). Dawn's D3D12 backend then enumerates
adapters via `IDXGIFactory6::EnumAdapterByGpuPreference(...HIGH_PERFORMANCE...)` and
returns the top-ranked one — the RTX 3060 on this machine (`DxgiHighPerformanceIndex=0`,
per W2 §1) — regardless of which `OrtHardwareDevice` Python selected. Dawn's own D3D12
native API (`dawn::native::d3d::RequestAdapterOptionsLUID`, confirmed present at the
exact pinned Dawn revision and compiled into the installed DLL) could constrain this,
but nothing in the plugin EP's call path ever constructs or chains it.

**No native build was attempted.** This machine has no CMake and no Visual Studio
installation of any kind — confirmed by direct check (`where cmake` empty,
`Program Files\Microsoft Visual Studio` absent), not assumed. Step 6 is therefore
**not feasible in this session** and this report stops at a source-grounded patch
proposal (step 5), exactly as the mission brief anticipates as the likely, acceptable
outcome. **Classification: NOT VERIFIED (no build/native test performed this phase).**
No new GPU-execution tests were run this phase — W2 already obtained decisive,
reproduced, per-process evidence for the same question, and the mission brief
explicitly says not to re-run that for no new information. This phase's entire
contribution is source-level.

## 1. Installed package and native DLL provenance

| Artifact | Value |
|---|---|
| Venv | `C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep\.venv-webgpu` (existing W1/W2 venv, reused unchanged) |
| `onnxruntime-ep-webgpu` | `0.3.0` (`pip show`) |
| `onnxruntime` | `1.30.0` (`pip show`) |
| Wheel tag (installed `WHEEL` file) | `py3-none-win_amd64`, built by `setuptools 84.0.0` |
| Wheel filename (PyPI JSON API, `pypi.org/pypi/onnxruntime-ep-webgpu/0.3.0/json`) | `onnxruntime_ep_webgpu-0.3.0-py3-none-win_amd64.whl` |
| PyPI wheel SHA-256 (from PyPI's own JSON API, not recomputed locally — no cached `.whl` file exists in this venv's pip cache to re-hash end-to-end) | `f25ed449a8f152176a20bc9b2f959a16511f16ff0f962a37979799d1b2d56bf7` |
| PyPI upload time | `2026-08-24T21:28:23Z` |
| `onnxruntime_providers_webgpu.dll` SHA-256 (installed, independently recomputed twice: `sha256sum` and Windows `certutil -hashfile`, both agree) | `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| Same hash, as recorded in the wheel's own `RECORD` file (base64, decoded and cross-checked byte-for-byte against the independent recompute above — matches exactly) | `sFptUYeIW-kTOsOD1Sca8gt28oHnLYv-kz81oj0FuU8` → `b05a6d5187885be9133ac383d5271af20b76f281e72d8bfe933f35a23d05b94f` |
| `onnxruntime_providers_webgpu.dll` size | 10,522,976 bytes |
| `dxcompiler.dll` SHA-256 (from `RECORD`, base64) | `o1uTOgtjOYPAzEggWHn-ets3_oJ0pcdun3Sy-pZ6Bg4` (17,986,400 bytes) |
| `dxil.dll` SHA-256 (from `RECORD`, base64) | `Z2gSj7rGtmCIp8RmQSrEEg7513AeALQ_psH_cGPfoEI` (1,508,704 bytes) |
| Package metadata `Project-URL: Source` | `https://github.com/microsoft/onnxruntime` |
| Package metadata `Project-URL: Download` | `https://github.com/microsoft/onnxruntime/tags` |
| License | MIT (Microsoft), `LICENSE` + `ThirdPartyNotices.txt` present under `onnxruntime_ep_webgpu-0.3.0.dist-info/licenses/` |
| ThirdPartyNotices Dawn entry | `https://dawn.googlesource.com/dawn`, BSD-3-Clause, "Copyright 2017-2023 The Dawn & Tint Authors" — **no specific Dawn commit/tag is recorded in this notice file**; the exact pin was found separately, in ONNX Runtime's own build config (§2) |

**Provenance caveat, stated explicitly**: I verified the installed DLL's hash matches
the wheel's own manifest (`RECORD`), and that the PyPI-hosted wheel for this exact
version/platform has a recorded upload date matching the GitHub release date found in
§2. I did **not** independently re-download and hash the raw `.whl` file end-to-end
(no cached copy exists in this venv's pip cache — `pip cache list` shows only unrelated
packages), and I did not check any cryptographic build-provenance/attestation (e.g.
SLSA) tying the published wheel to the exact commit in §2. This is standard-diligence
provenance (hash-in-manifest cross-check + matching dates), not cryptographic proof of
build reproducibility.

## 2. Exact upstream source located

- **PyPI metadata → GitHub**: `Project-URL: Source` and `Download` both point at
  `github.com/microsoft/onnxruntime`. A web search (not current-main guessing) located
  the WebGPU-plugin-EP-specific release tag: **`plugin-ep-webgpu/v0.3.0`**.
- **Exact commit**: `caf2ed32972b8848277b2b9bcc8917e07bcfdb5c` (release date 2026-08-24
  — the same day, hours before, the PyPI wheel's own recorded upload time §1, which is
  consistent with an automated tag→build→publish release pipeline, not proof of
  bit-identical rebuild).
- **This is the exact tagged release, not current `main`** — every file fetched below
  was fetched at this pinned commit SHA (`raw.githubusercontent.com/microsoft/onnxruntime/caf2ed32972.../...`),
  confirmed by the URL itself resolving and returning coherent, cross-referencing C++
  source (matching class/struct/function names across files fetched independently).
- **Dawn's exact pinned revision**, from `cmake/deps.txt` at this exact onnxruntime
  commit (not inferred, not assumed to match current Dawn main):
  ```
  dawn;https://github.com/google/dawn/archive/refs/tags/v20260714.215939.zip;3056ed22d1606258ab43221b8c85b55b88614137
  ```
  Dawn tag `v20260714.215939`, archive SHA-1 `3056ed22d1606258ab43221b8c85b55b88614137`.
  All Dawn source references in §3 below were fetched at this exact tag, not Dawn
  `main`.
- Files actually fetched and read (raw, via direct `curl` to `raw.githubusercontent.com`,
  not a summarizing fetch, for the load-bearing ones):
  - `onnxruntime/core/providers/webgpu/ep/factory.cc` (288 lines)
  - `onnxruntime/core/providers/webgpu/ep/factory.h`
  - `onnxruntime/core/providers/webgpu/ep/ep.cc`
  - `onnxruntime/core/providers/webgpu/webgpu_context.cc` (1299 lines)
  - `onnxruntime/core/providers/webgpu/webgpu_context.h` (455 lines)
  - `onnxruntime/core/providers/webgpu/webgpu_provider_factory.cc` (515 lines)
  - `onnxruntime/core/providers/webgpu/webgpu_provider_options.h`
  - `cmake/deps.txt`
  - Dawn `include/dawn/native/D3DBackend.h` at tag `v20260714.215939`

## 3. Device-selection data flow, as actually traced through source

```
Python: webgpu_adapter.select_device(device_id=5688)
  -> ort.get_ep_devices() / list_webgpu_devices()  (core ORT's OWN Windows hardware
     enumeration -- NOT this plugin's code -- populates real vendor_id/device_id per
     OrtHardwareDevice; this is why W2's Python-level vendor_id/device_id table (§1 of
     WINDOWS_MULTI_GPU_SELECTION.md) is real, live Windows device identity, not
     synthetic)
  -> SessionOptions.add_provider_for_devices([device], extra_options)
  -> [ORT core / C API] Factory::CreateEpImpl(devices, ep_metadata, num_devices=1,
     session_options, logger, &ep)      <-- onnxruntime/core/providers/webgpu/ep/factory.cc:150

       factory.cc:159-162   reject if num_devices != 1  (matches the Python API's
                             "exactly one device" contract)
       factory.cc:164-178   read SESSION config entries (extra_options / SessionOptions
                             config, e.g. preferredLayout, powerPreference, deviceId --
                             see §4) into a generic ConfigOptions key/value bag
       factory.cc:184       device_metadata = HardwareDevice_Metadata(devices[0])
                             <-- THE ONLY READ OF THE SELECTED DEVICE'S IDENTITY
       factory.cc:185-193   ...used ONLY to check the "IsVirtual" metadata flag
                             (reject virtual-GPU + non-compile-only combination)
       factory.cc:195       auto webgpu_ep_factory =
                             WebGpuProviderFactoryCreator::Create(config_options);
                             <-- devices[0]'s vendor_id/device_id/LUID is NEVER passed
                             into config_options or anywhere else past this point.
                             The selected OrtHardwareDevice pointer goes out of scope
                             with nothing more read from it.
       factory.cc:196       webgpu_ep_factory->CreateProvider(*session_options, *logger)

  -> [webgpu_provider_factory.cc] ParseWebGpuContextConfig(config_options)
       :155-162  kDeviceId ("ep.webgpuexecutionprovider.deviceId") parses into
                 config.context_id -- an int used ONLY as a WebGpuContextFactory cache
                 key for SHARING one Dawn device across multiple ORT sessions/EPs in
                 the same process (see WebGpuDataTransferImpl, factory.cc's own
                 GetDeviceId() call at line 199-203). NOT a physical-adapter selector
                 -- confirmed by its only other use site (data-transfer same-device
                 check, factory.cc §4 below), never passed to RequestAdapterOptions.
       (no LUID/vendor/device-id parsing exists anywhere in this function)
     -> WebGpuContextFactory::CreateContext(config)   :350
     -> new WebGpuProviderFactory(config.context_id, context, ...)   :353

  -> [webgpu_context.cc] WebGpuContext::Initialize(const WebGpuContextConfig& config)
       :63-65   wgpu::RequestAdapterOptions req_adapter_options = {};
                req_adapter_options.backendType = config.backend_type;
                req_adapter_options.powerPreference = config.power_preference;
                     (power_preference defaults to WGPUPowerPreference_HighPerformance
                     -- webgpu_context.h:153 -- unless the caller sets the
                     "powerPreference" string option to "low-power"; NOTHING sets a
                     specific adapter/LUID)
       :67-75   chains a DawnTogglesDescriptor (debug/feature toggles only) onto
                req_adapter_options.nextInChain -- no adapter-identity struct chained
       :87-104  instance_.RequestAdapter(&req_adapter_options, WaitAnyOnly, callback)
                ORT_ENFORCE(status == Success, "Failed to get a WebGPU adapter: ...")
                     <-- this ENFORCE already fails loudly/throws on adapter-request
                     failure; it just never gets a chance to fail on a bad LUID today,
                     because no LUID is ever supplied

  -> Dawn (google/dawn @ v20260714.215939) native D3D12 backend
       dawn::native::d3d::Backend::DiscoverPhysicalDevices(...)  (present, confirmed
       via mangled symbol AND via string-scan of the installed DLL, §5)
       enumerates adapters via IDXGIFactory6::EnumAdapterByGpuPreference(...,
       DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, ...) per W2 §1/§7's own
       DxgiHighPerformanceIndex finding (RTX 3060 = index 0 on this machine) and Dawn
       picks the top-ranked adapter -- the RTX 3060 -- independent of which
       OrtHardwareDevice Python selected.
```

**Precise point of loss**: `Factory::CreateEpImpl`, `onnxruntime/core/providers/webgpu/ep/factory.cc`,
between line 184 (last read of the selected device's identity) and line 195 (device
identity never referenced again). A second, corroborating signal in the same file:
`GetSupportedDevicesImpl` (line 102-106) wraps each real GPU `OrtHardwareDevice` into
an `OrtEpDevice` via `Api().ep.CreateEpDevice(this_ptr, &device, nullptr, nullptr,
&ep_device)` — the two `nullptr` arguments are EP-specific metadata/options, both
unset — with a literal source comment directly above it: `// TODO: any metadata or
options to add?`. The plugin EP's own authors flagged, in-source, that no
device-specific metadata/options plumbing exists yet.

## 4. Root cause — summary

**Not a Dawn limitation, not a missing capability, not a Windows platform limitation.**
It is a specific, narrow, upstream `onnxruntime-ep-webgpu` gap: the plugin-EP factory
(`ep/factory.cc`) discards the caller's selected `OrtHardwareDevice` after checking one
unrelated flag, and the context layer (`webgpu_context.cc`) constructs Dawn's adapter
request using only backend type and power preference — both platform/session-level
settings, neither of which is a physical-device selector. Dawn's own D3D12 backend
supports exactly the missing capability (`dawn::native::d3d::RequestAdapterOptionsLUID`,
§5) and is already linked into the installed binary; it is simply never invoked from
this call path. A confusingly-named existing option, `deviceId`
(`ep.webgpuexecutionprovider.deviceId`), already exists in the provider-options surface
but is a **logical WebGpuContext cache-slot index for cross-session device sharing**,
unrelated to physical hardware identity — this is a genuine landmine: it is very
plausible a caller (or W2's own empirical `extra_options` probing of `device_id`/
`deviceId`-shaped keys, which found they were "silently accepted with no effect") could
reasonably but incorrectly assume this key selects hardware. It does not, and this
report is the first place in this project's evidence trail that pins down *why* those
probes had no effect: the key exists and is consumed, just for an unrelated purpose.

## 5. Dawn API availability in the bundled revision

Direct binary string-extraction (Python-based ASCII + UTF-16LE scan, `strings` itself
is not installed in this Git Bash environment; script written this phase,
`extract_strings.py`, kept in the scratchpad, not committed) of the installed
`onnxruntime_providers_webgpu.dll` confirms, independent of the GitHub source fetch:

| Symbol / string | Present in installed DLL |
|---|---|
| `RequestAdapterOptionsLUID` | Yes (literal type name string) |
| `EnumAdapterByLuid` | Yes |
| `adapterLuidHighPart` / `adapterLuidLowPart` | Yes (almost certainly the `::LUID` struct's own `HighPart`/`LowPart` fields surfacing through some logging/serialization path, consistent with `RequestAdapterOptionsLUID`'s single `::LUID adapterLUID` field found in source, §below — not a separate struct) |
| `DiscoverPhysicalDevices` (mangled: `?DiscoverPhysicalDevices@Backend@d3d@native@dawn@@...URequestAdapterOptions@native@dawn@@`) | Yes |
| `N:\_work\...\dawn-src\...` compiled-in debug paths | Yes (confirms Dawn was built from source as part of this CI pipeline, at path pattern typical of Microsoft's Azure Pipelines ORT build agents) |
| `N:\_work\1\s\onnxruntime\core/providers/webgpu/...` compiled-in debug paths (e.g. `webgpu_context.h`, `compute_context.h`) | Yes — direct confirmation the fetched GitHub source tree layout (§2) matches what was actually compiled into this binary |

**And, confirmed by reading Dawn's actual pinned-tag source** (`include/dawn/native/D3DBackend.h`
at `google/dawn@v20260714.215939`), verbatim:

```cpp
namespace dawn::native::d3d {

DAWN_NATIVE_EXPORT Microsoft::WRL::ComPtr<IDXGIAdapter> GetDXGIAdapter(WGPUAdapter adapter);

// Can be chained in WGPURequestAdapterOptions
struct DAWN_NATIVE_EXPORT RequestAdapterOptionsLUID : wgpu::ChainedStruct {
    RequestAdapterOptionsLUID();
    ::LUID adapterLUID;
};

}  // namespace dawn::native::d3d
```

This is a **native-only** (non-wire, non-WASM) chained struct — it does not appear in
Dawn's portable `dawn.json` webgpu.h API generator IDL (checked directly; `dawn.json`'s
`"request adapter options"` structure has only `feature level`, `power preference`,
`force fallback adapter`, `backend type`, `compatible surface` — no LUID field). It is
part of Dawn's native C++ embedding API, exactly the kind of header a native EP
(onnxruntime's WebGPU EP, which already links `dawn_native`/Dawn statically per the
binary evidence) is positioned to use directly, by including
`dawn/native/D3DBackend.h` and chaining a `RequestAdapterOptionsLUID` instance onto
`req_adapter_options.nextInChain` in `WebGpuContext::Initialize()` before or alongside
the existing `DawnTogglesDescriptor` chain link.

**Answering the mission's specific questions**:
- Exists in bundled Dawn revision? **Yes**, confirmed both by binary symbol presence
  and by reading the actual pinned-tag header source.
- `RequestAdapter` vs `EnumerateAdapters`? The EP uses `wgpu::Instance::RequestAdapter`
  (async, callback-based, waited via `WaitAny`) — not Dawn's native
  `EnumerateAdapters`/`GetPhysicalDevices` (also present in Dawn per `DiscoverPhysicalDevices`,
  but not called from this EP's code path).
- Accessible at the EP's actual call site? **Yes, structurally** — `webgpu_context.cc`
  already includes `dawn/native/DawnNative.h` and already builds a chained
  `DawnTogglesDescriptor`; adding a second chained struct is the same pattern already
  used in this exact function, not a new mechanism.
- Does Dawn receive an explicit adapter constraint today? **No** — confirmed, only
  `backendType`/`powerPreference` are set.
- Does the EP discard or ignore its requested device? **Discards** — confirmed at the
  exact line (factory.cc:184-195).
- Equivalent supported mechanism already exists? **No** — `kDeviceId` exists but is
  unrelated (§4); no other candidate key exists in `webgpu_provider_options.h`.
- Failure reporting if requested adapter unavailable? Today, moot (no adapter is ever
  requested by identity). If a LUID constraint were added, Dawn's `RequestAdapter`
  async callback already has a `status != Success` path, and
  `WebGpuContext::Initialize()` already `ORT_ENFORCE`s on it (throws with the message)
  — this existing fail-closed plumbing would very likely cover the "invalid LUID"/
  "unavailable device" cases for free, *if* Dawn's own D3D12 `DiscoverPhysicalDevices`
  correctly rejects/filters an unmatched LUID rather than silently ignoring the chained
  struct — **this specific behavior was not verified this session** (no build was
  performed to test it) and is flagged as the primary unverified assumption in §13.

## 6. Proposed minimal patch (source-grounded, not built or tested this phase)

Smallest change that threads the caller's selected physical device through to Dawn's
D3D12 adapter request, using only APIs already compiled into the installed binary:

1. **`onnxruntime/core/providers/webgpu/webgpu_provider_options.h`**: add one new key,
   distinct from the already-taken, differently-scoped `kDeviceId`:
   ```cpp
   constexpr const char* kPreferredAdapterLUID = "ep.webgpuexecutionprovider.preferredAdapterLuid";
   ```
2. **`onnxruntime/core/providers/webgpu/ep/factory.cc`, `CreateEpImpl`**: immediately
   after the existing `device_metadata` read (line 184), on Windows only, read the
   selected `OrtHardwareDevice`'s real LUID (core ORT's own Windows hardware-device
   enumeration is the actual source of the vendor_id/device_id values W2 already
   observed at the Python level — the exact core-ORT function that attaches a LUID to
   `OrtHardwareDevice` metadata on Windows was not located this session and is the
   single biggest open item before this patch could be written for real, see §13) and
   inject it as a decimal/hex string into `config_options` under
   `options::kPreferredAdapterLUID`, following the exact parsing pattern
   `kDeviceId`/`context_id` already uses (`webgpu_provider_factory.cc:158-162`,
   `std::from_chars`).
3. **`onnxruntime/core/providers/webgpu/webgpu_context.h`, `WebGpuContextConfig`**: add
   `#ifdef _WIN32` `std::optional<LUID> preferred_adapter_luid{};` alongside the
   existing `power_preference`/`backend_type` fields (~line 153-156).
4. **`webgpu_provider_factory.cc`, `ParseWebGpuContextConfig`**: parse
   `kPreferredAdapterLUID` into `config.preferred_adapter_luid` when present
   (`#ifdef _WIN32`), mirroring the existing `kDeviceId` block.
5. **`webgpu_context.cc`, `WebGpuContext::Initialize()`**: immediately after line 74
   (`req_adapter_options.nextInChain = &adapter_toggles_desc;`), on Windows, when
   `config.preferred_adapter_luid` has a value: construct a
   `dawn::native::d3d::RequestAdapterOptionsLUID`, set `.adapterLUID =
   *config.preferred_adapter_luid`, and chain it onto the existing toggles descriptor
   (`adapter_toggles_desc.nextInChain = &luid_options;`) before calling
   `instance_.RequestAdapter(...)`. No new Dawn build/vendoring is required — this
   struct is already compiled into the linked Dawn native library, confirmed §5.
6. **Fallback semantics**: an invalid/unavailable LUID should surface through the
   existing `ORT_ENFORCE(adapter_result.status == wgpu::RequestAdapterStatus::Success, ...)`
   at `webgpu_context.cc:101-102` — already fail-closed, already throws with a message,
   requires no new error-handling code *if* Dawn's D3D12 `DiscoverPhysicalDevices`
   itself rejects a non-matching LUID rather than silently falling back (unverified
   this session, §13).
7. **No general GPU-selection framework, no Dawn fork, no new Python-facing API beyond
   one new `extra_options`/provider-option string key** — this is deliberately as small
   as the mission requires, and reuses every existing fail-closed code path rather than
   adding new ones.

This patch was **not implemented, built, or tested** — see §7 and §13.

## 7. Native build feasibility — checked directly, found infeasible this session

- `where cmake` → no result (CMake not installed).
- `Program Files\Microsoft Visual Studio` and `Program Files (x86)\Microsoft Visual
  Studio` → both absent (no Visual Studio / MSVC toolchain installed).
- Building the patch in §6 for real would require: installing Visual Studio Build
  Tools (MSVC + Windows SDK), CMake, Python build dependencies, a full ~multi-GB
  `onnxruntime` source checkout plus its CMake-fetched `_deps` (including the ~pinned
  Dawn source tree itself, another large checkout), and a native build that typically
  takes well over an hour even on capable hardware for this component — none of which
  was attempted, consistent with the mission's explicit permission to stop here rather
  than fake or partially attempt a build.
- **No isolated build directory was created** (there was nothing to build). If a build
  is attempted in a future phase, it must live outside this git-tracked worktree per
  the mission's own instruction (e.g. under a scratch location, not
  `C:\Users\Administrator\Documents\GIT\STEMwerk-worktrees\...`), and must load the
  experimental DLL only from an explicit separate path — never overwriting the
  installed, working `onnxruntime_providers_webgpu.dll` this venv (and W1/W2's
  evidence) depends on.

## 8. Test contract (step 7) — not re-run, and why

No new GPU-execution tests were run this phase. W2 already obtained decisive,
independently-reproduced, per-process evidence for exactly the question this phase's
tests would re-ask (does an explicit AMD-iGPU request execute on the AMD iGPU?) using
the same unmodified `webgpu_adapter.select_device()`/`create_verified_webgpu_session()`
code this phase's source reading confirms is the actual, only call path into the
plugin EP. Re-running W2's A–E test matrix against the *same installed binary* would
exercise the identical code path already proven, byte-for-byte, to drop device
identity at `factory.cc:184-195` — it would reproduce W2's result with no new
information, which the mission brief explicitly says to avoid ("don't just re-run W2's
exact tests for no new information — focus effort on the source investigation
instead"). This phase's only tool addition is `extract_strings.py` (Python ASCII/UTF-16LE
string scanner, since `strings` is not installed in this environment), kept in the
scratchpad directory, not committed to the worktree (not a test script, a one-off
inspection utility).

## 9. Cross-platform compatibility — analysis only

- **Linux/Vulkan (L9/L10)**: this Windows finding does not change L10's conclusion.
  L10's `VK_LOADER_DEVICE_ID_FILTER` process-local isolation remains the only proven
  Linux mechanism and is untouched by this phase. The proposed §6 patch is explicitly
  D3D12/`_WIN32`-scoped (`dawn::native::d3d::RequestAdapterOptionsLUID` is a D3D-only
  struct); a Vulkan analogue would chain a different Dawn native Vulkan struct (if one
  exists — not investigated this phase, out of scope) or continue relying on L10's
  already-proven, separate, process-local loader-filter mechanism, which does not
  require any onnxruntime/Dawn source change at all. **A Windows LUID patch does not
  solve, and is not claimed to solve, Linux.**
- **macOS/Metal (M1)**: M1's hardware has exactly one WebGPU-capable adapter (§M1.3 of
  README.md) — no multi-adapter ambiguity exists to require a selector at all on this
  hardware class. No change needed or proposed.
- **Existing capability resolver (`backend_resolver.py`, L11)**: unaffected. Its
  existing `_isolation_for()` platform check already treats non-Linux multi-GPU as
  unenforceable by default; that conservative default remains correct until/unless a
  built, tested Windows LUID patch is actually merged upstream and available in a
  released `onnxruntime-ep-webgpu` version — a source-level patch proposal in this repo
  does not change installed runtime behavior anywhere.
- **Existing CUDA/ROCm/MPS/DirectML routes**: untouched, not investigated this phase,
  not relevant to the WebGPU EP's own internal device-selection code path.
- **Design note**: a generic EP-level "physical device identity" contract could
  reasonably have platform-specific selector payloads behind one logical key (e.g. a
  discriminated `{platform, selector}` pair — DXGI LUID on Windows, PCI/Vulkan device
  UUID on Linux, "N/A, single adapter" on current Apple Silicon) — but implementing
  that generalized contract across platforms was explicitly out of scope for this
  phase and is not attempted here; §6's patch targets only the concrete Windows gap
  actually found.

## 10. Packaging and maintenance implications

- The proposed patch is entirely additive (one new provider-option key, one new
  optional config field, ~15-20 lines across 4 existing files) — no existing behavior
  changes for callers that don't set the new key; `power_preference`'s existing
  default (`HighPerformance`) is preserved exactly for the no-explicit-request case,
  matching the mission's contract requirement that "no explicit GPU request" behavior
  is unchanged.
- It is squarely an upstream `onnxruntime-ep-webgpu`/`onnxruntime` change — nothing in
  this project's own code can implement it; STEMwerk/this experiment can only consume
  a future release that includes it, or carry a local patched build (not attempted
  this phase, §7).
- The `kDeviceId` naming collision (§4) is worth raising upstream on its own, even
  independent of this patch — it is a real trap for any caller (this project included)
  who assumes it selects hardware.

## 11. Explicit blockers and unverified assumptions

- **Biggest open item**: the exact core-ORT function/file that attaches a Windows
  LUID (or equivalent identity) onto `OrtHardwareDevice` metadata for GPU devices was
  **not located this session** — `factory.cc`'s `GetSupportedDevicesImpl` receives
  already-populated `OrtHardwareDevice*` pointers from core ORT's own enumeration
  (outside the `webgpu/` provider directory entirely, likely under
  `onnxruntime/core/session/` or a platform-specific `ep_library_*` path) — locating
  it was out of this phase's time budget. §6 step 2 depends on this and is the
  patch's weakest, least-verified link.
- Whether Dawn's D3D12 `DiscoverPhysicalDevices` actually **rejects** a non-matching
  LUID (fail-closed) versus silently ignoring an unmatched `RequestAdapterOptionsLUID`
  chain (silent fallback) was **not verified** — no build was performed to test either
  behavior. This is the single most important unverified assumption for the "no silent
  substitution" success criterion, and must be confirmed before this patch could be
  trusted, not assumed from the struct's existence alone.
- The GitHub release commit (`caf2ed32972b8848277b2b9bcc8917e07bcfdb5c`) was obtained
  via a web-search-driven page fetch, not a `git log`/`git show` against a local clone
  of `onnxruntime` (no local clone exists in this session) — corroborated by matching
  release/upload dates and by every subsequently-fetched source file at that exact
  commit SHA returning coherent, cross-referencing real C++ source, but not
  independently re-verified against a second authoritative source (e.g. the GitHub API
  with authenticated access, which returned 401 unauthenticated in this session).
- No new GPU-execution test was run this phase (§8) — all execution-proof claims in
  this document are inherited from W2, cited, not re-obtained.
- The `adapterLuidHighPart`/`adapterLuidLowPart` binary strings were inferred to be the
  `::LUID` struct's own field names surfacing through logging/serialization, based on
  `RequestAdapterOptionsLUID`'s single `::LUID adapterLUID` field in the actual header
  — a reasonable but not 100%-traced inference (the exact call site producing those two
  specific strings in the binary was not located).
- Step 6 (native POC) was not attempted; step 7's decisive A–E test matrix was not
  re-run against a patched binary because no patched binary exists. Full W3 PASS
  criteria (§8 of the mission brief) are therefore **not met** — this phase's honest
  classification is **NOT VERIFIED**, with a source-grounded patch proposal in hand,
  exactly the outcome the mission brief identifies as the likely, acceptable result.

## 12. Scope discipline

No production STEMwerk venv, model registry, runtime resolver, installer/bootstrap, or
REAPER UI file was modified. No system-wide Windows graphics setting, Device Manager
entry, or driver was changed. `capability_matrix.json`/`.py` were **not modified** this
phase — no new hardware/model combination was actually validated (this phase is
source-level only), so per the mission's own instruction not to mark anything PASS
without real execution proof, the matrix is left exactly as W2 left it. No Dawn/ONNX
Runtime fork was started; no native build directory was created (none was attempted,
§7). The installed `onnxruntime_providers_webgpu.dll` used by W1/W2 was read-only
inspected (independent hash recompute, string extraction) — never modified. The only
new file this phase adds under `experiments/webgpu-ep/` (git-tracked) is this document
and the README.md Phase W3 section; `extract_strings.py` lives in the session
scratchpad, outside the worktree, not committed.
