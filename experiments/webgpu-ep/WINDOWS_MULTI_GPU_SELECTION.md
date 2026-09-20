# Windows Multi-GPU Physical Device Selection — Phase W2

Status date: 2026-09-20. Companion to `DEMUCS_WINDOWS_NVIDIA.md` (W1),
`RADEON_780M_IGPU_VALIDATION.md` (L9), `RADEON_780M_DEVICE_ISOLATION.md` (L10),
`BACKEND_CAPABILITY_RESOLVER.md` (L11), `DEMUCS_LINUX_NVIDIA.md` (N1). Resolves the
question W1 explicitly left open and L9 explicitly flagged as its recommended
follow-up: **did W1's RTX 3060 selection actually happen because it was requested, or
because it coincided with Dawn's own internal default on this dual-GPU laptop?**

**Headline result: Dawn's own default, not the request.** An explicit, valid request
for this machine's *other* GPU — the integrated AMD Radeon graphics — still executed
on the NVIDIA RTX 3060, independently confirmed by three separate methods (OS-level
per-process GPU Engine performance counters keyed to DXGI adapter LUID, whole-GPU
`nvidia-smi` utilization/VRAM correlated to the exact test window, and near-bit-
identical numeric/timing output across both requests), reproduced in multiple fresh
processes. This is the Windows/D3D12 counterpart to L9's Linux/Vulkan finding for the
same `onnxruntime-ep-webgpu` 0.3.0 package, whose own packaged README states,
platform-generically: *"The WebGPU EP currently accepts one EP device and selects the
physical GPU independently."* **Device-selection enforcement is FAIL on Windows/D3D12
for this plugin version.** No Windows process-local mechanism analogous to Linux's
`VK_LOADER_DEVICE_ID_FILTER` was found to exist (verified by binary inspection, not
assumed). Because the AMD iGPU was never proven to physically execute anything, Steps
8 (full iGPU MDX-Net validation) and 9 (conditional Demucs-on-iGPU) are **BLOCKED /
NOT TESTED**, per the mission brief's own instruction not to substitute the RTX 3060's
results and report them as an iGPU pass.

## 1. Hardware inventory (this machine, verified via real Windows tooling)

| Property | GPU 0 (NVIDIA, discrete) | GPU 1 (AMD, integrated) |
|---|---|---|
| Name (`Get-CimInstance Win32_VideoController`) | NVIDIA GeForce RTX 3060 Laptop GPU | AMD Radeon(TM) Graphics |
| PNP Hardware ID | `PCI\VEN_10DE&DEV_2520&SUBSYS_104C1043&REV_A1` | `PCI\VEN_1002&DEV_1638&SUBSYS_104C1043&REV_C5` |
| `AdapterCompatibility` | NVIDIA | Advanced Micro Devices, Inc. |
| Windows driver version (`Win32_VideoController.DriverVersion`) | 32.0.16.1692 | 31.0.21923.11000 |
| `nvidia-smi` driver version | 616.92 | N/A (not an NVIDIA device) |
| DXGI `AdapterLuid` (decimal / hex low-32) | 64318 / `0x0000fb3e` | 59967 / `0x0000ea3f` |
| DXGI `VendorId`/`DeviceId` (`HKLM\SOFTWARE\Microsoft\DirectX`) | `0x10de` / `0x2520` | `0x1002` / `0x1638` |
| Dedicated VRAM (DirectX registry) | 6,285,164,544 B (≈5994 MB) | 519,847,936 B (≈495 MB) |
| `webgpu_adapter.list_webgpu_devices()` `vendor_id`/`device_id` | `4318` (0x10DE) / `9504` | `4098` (0x1002) / `5688` |
| `DxgiHighPerformanceIndex` (Dawn's own metadata) | **0** (preferred) | 1 |
| `nvidia-smi -L` | `GPU 0: NVIDIA GeForce RTX 3060 Laptop GPU (UUID: GPU-0c61372c-1d56-bd51-b28f-3f8784ef539c)` | — |

Both GPUs are real, distinct, physically present devices — confirmed via WMI, DXGI
registry, `nvidia-smi`, and `webgpu_adapter.list_webgpu_devices()`, four independent
sources that all agree. `device_id=9504`/`5688` (decimal) are `0x2520`/`0x1638` in hex
— i.e. **identical to the PCI DEV_ ids WMI reports**, confirming `webgpu_adapter.py`'s
Windows `device_id` metadata maps to real Windows device identity, not an arbitrary
enumeration index. `DxgiHighPerformanceIndex=0` for the RTX 3060 (vs `1` for the
iGPU) is Dawn's own record of `IDXGIFactory6::EnumAdapterByGpuPreference(...,
DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, ...)` ordering — this is the mechanistic reason
the RTX 3060, not the iGPU, is the platform's "default" adapter (see §7).

OS: Windows 11 Pro, build 10.0.26200 (`Windows-10-10.0.26200-SP0`).
Runtime: `onnxruntime==1.30.0`, `onnxruntime-ep-webgpu==0.3.0`, CPython 3.11.8
(`C:\Users\Administrator\stemwerk-rnd\venvs\webgpu-ep\.venv-webgpu`, the existing W1
venv, reused unchanged — no new venv was needed).

## 2. Monitoring methodology and its limits

**Method chosen: `\GPU Engine(*)\Utilization Percentage`, the same Windows
performance-counter object Task Manager's own "GPU Engine" column reads**, sampled
per-process, cross-checked against DXGI adapter identity. This is the closest Windows
analogue to L9/L10's Linux `/sys/class/drm/card*/device/gpu_busy_percent` kernel
counters: populated by the OS graphics kernel subsystem (`dxgkrnl`) itself, completely
independent of onnxruntime/Dawn's own self-reported device metadata.

- **Adapter identity, independent of onnxruntime**: `windows_gpu_monitor.py`'s
  `enumerate_dxgi_adapters()` reads `HKLM\SOFTWARE\Microsoft\DirectX` — Windows' own
  live per-adapter registry, populated by the OS/driver stack, not by this experiment
  or by onnxruntime — to map each counter's LUID to a vendor/device id and
  description. This was cross-checked against `webgpu_adapter.py`'s own metadata (§1
  table) and found to agree exactly.
- **Real, disclosed limitation found and fixed during development**: `Get-Counter`'s
  `-Continuous` streaming mode resolves the `(*)` wildcard's instance list **once, at
  query-open time** — a process that opens its D3D12 device *after* the continuous
  query has already started is silently never added to the stream, confirmed directly
  (a controlled repeated-inference test launched after `-Continuous` had started
  produced zero samples for the target process, every time). Looping independent
  single-shot `Get-Counter` calls (which re-resolve the wildcard fresh on every call)
  reliably caught it instead, at the cost of coarser (~1.3–1.6 s per call) resolution.
  `windows_gpu_monitor.py` uses the single-shot-loop form for this reason — the same
  "don't trust cached enumeration, verify live" discipline L10 established for Linux's
  `list_webgpu_devices()`/`vkEnumeratePhysicalDevices()` gap.
- **A second, real, disclosed limitation**: with that ~1.3–1.6 s polling resolution, a
  **sustained, dense workload** (hundreds of repeated `session.run()` calls back-to-
  back with no idle gaps — `w2_device_selection_probe.py`) was reliably caught every
  time (5+ nonzero samples per ~8–10 s window, in every run). The **real MDX-Net
  pipeline's bursty, single-shot WebGPU calls (2.6–2.9 s total per provider, spread
  across model load, chunked STFT/iSTFT on CPU, and file I/O) were NOT reliably caught
  by per-process GPU Engine sampling** in this phase's testing, despite the same
  underlying device-selection code path and despite independent confirmation (via
  `nvidia-smi`, below) that real GPU execution did occur. This is reported honestly as
  a tool-resolution gap for that specific invocation pattern, not glossed over or
  silently worked around by inflating sample density until it happened to "pass."
- **Second independent method, used to cover this gap for the real pipeline**:
  `nvidia-smi --query-gpu=memory.used,utilization.gpu` (already used for whole-GPU
  sampling in W1/N1's `resource_sampler.py`), sampled continuously during the exact
  timed benchmark window and compared against a **fresh idle baseline** immediately
  before each run (avg 0.0% during the CPU-only phase in every run this phase). This
  is whole-GPU, not per-process — per L9's own caution, *"a busy NVIDIA GPU only
  proves NVIDIA activity when correlated with the actual inference process and
  interval"* — but the correlation here is exact: 0% throughout the CPU-only phase,
  then a sharp, sustained jump for exactly the WebGPU phase's duration, in every run,
  regardless of which device was requested (§5).
- **Third corroborating signal**: raw numeric output and wall-clock timing, compared
  between the RTX-3060-requested and iGPU-requested runs of the *identical* pipeline
  and input. Two different physical GPUs producing bit-identical float32 output and
  statistically indistinguishable timing would be a remarkable coincidence — every
  prior cross-hardware comparison in this project (Linux vs Windows, RX 9070 vs
  RTX 3060, RX 9070 vs Radeon 780M) shows *some* measurable numeric or timing
  difference between genuinely different hardware. Its absence here is itself
  evidence, not proof on its own.
- **Fresh idle baseline**: captured for 4–5 s immediately before every monitored run
  (both adapters), per the brief's explicit instruction that L11 found stale baselines
  cause false positives. Idle baseline in every run: AMD iGPU max 0.40–0.44% (2–4
  nonzero samples, ordinary desktop/compositor background load), RTX 3060 max
  0.03–0.07% (1–2 nonzero samples).
- **Tooling added this phase** (new files, `experiments/webgpu-ep/`):
  `windows_gpu_monitor.py` (the OS-counter sampler + DXGI-registry adapter map),
  `w2_monitored_run.py` (fresh-process wrapper: idle baseline + monitored child +
  `nvidia-smi --query-compute-apps` per-process cross-check), and
  `w2_device_selection_probe.py` (the dense repeated-inference probe that produced
  this phase's decisive per-process, per-adapter evidence — see §5).

**Verdict on monitoring adequacy**: **PASS for the decisive device-selection question**
(§5, via `w2_device_selection_probe.py`, using the real, unmodified `select_device()`/
`create_verified_webgpu_session()` adapter code) — reproduced in 2 independent fresh
processes. **PARTIAL for the full real-pipeline invocations** — `nvidia-smi` whole-GPU
correlation plus the numeric/timing cross-check are strong, consistent, multi-source
circumstantial evidence, but per-process GPU-Engine attribution specifically did not
register for those shorter/burstier calls; this gap is disclosed rather than hidden,
consistent with the mission's "if adequate monitoring can't be established, classify
as BLOCKED — do not guess" instruction (applied here to the *monitoring claim itself*,
not to the underlying decisive finding, which rests on the probe's clean, reproduced,
per-process result using the identical device-selection code).

## 3. Model and fixture identity

| Artifact | SHA-256 | Notes |
|---|---|---|
| `UVR_MDXNET_KARA_2.onnx` | `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4` | **Byte-identical** to the hash N1 recorded on a separate Linux machine (`capability_matrix.json`) — same catalog artifact, confirmed not assumed |
| `w1_fixture_25s.wav` (25.0 s / 44.1 kHz / stereo / PCM16) | `658380a556000aaf38e8502cf3276ba2b9291f4b6eeffc82d48863fd91385b32` | **Exactly** W1's own recorded excerpt hash (`DEMUCS_WINDOWS_NVIDIA.md` §7) — the identical W1 fixture was reused, not a new file |

Both existing artifacts from `C:\Users\Administrator\stemwerk-rnd\model-cache\` and
`C:\Users\Administrator\stemwerk-rnd\evidence\` (the existing W1 venv/evidence tree)
were reused as-is — no new download, no production model registry touched.

## 4. Step 4 — W1 regression baseline (RTX 3060, `device_id=9504`)

`end_to_end_pipeline_test.py --device-id 9504`, fresh process, monitored:

| Check | Result |
|---|---|
| WebGPU session creation | **PASS** |
| Graph placement | **PASS** — `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` |
| CPU fallback | **PASS** — 0 nodes |
| Stem routing | **PASS** — Vocals/Instrumental same-stem corr=1.000000 vs other-stem corr=0.178299/0.178300 |
| Raw numeric vs CPU | **PASS** — Vocals corr=1.00000000 max_abs_diff=**1.10e-06**; Instrumental corr=1.00000000 max_abs_diff=**1.03e-06** — matches W1's own recorded figures exactly |
| File (WAV) numeric vs CPU | **PASS** — both stems 3.05e-05 = 1.00× PCM16 LSB |
| Full audio pipeline | **PASS** — both providers, no crash, complete export |
| 4-run warm benchmark (`benchmark_resources.py --device-id 9504`) | CPU warm median 13.76 s, WebGPU warm median 2.70 s (**5.10× speedup**, RTF 9.3×) |
| Physical RTX 3060 execution, independent evidence | **PASS** — `nvidia-smi` whole-GPU utilization jumped 0.0% (CPU phase) → avg **53.2%** (WebGPU phase), VRAM attributable delta **1082 MB**; `w2_device_selection_probe.py` (dense-probe methodology) independently confirms per-process, per-LUID RTX 3060 3D-engine activity up to 45.8% for this exact `device_id` selection, reproduced twice |
| Selector *causation* (does the request, not just the GPU, matter?) | Addressed decisively in §5 below — not claimed here |

This reproduces W1's own numbers essentially bit-for-bit (same raw max_abs_diff
values), confirming no regression, and establishes the W2 baseline before reversing
the request.

## 5. Step 5 — the decisive test: explicit AMD iGPU request (`device_id=5688`)

Same model, same fixture, same unmodified `select_device()`/
`create_verified_webgpu_session()` adapter code — only the requested `device_id`
changed, in fresh processes each time.

### 5a. `w2_device_selection_probe.py` — dense workload, per-process OS-counter proof

A small Conv graph (same op family as MDX-Net's UNet), run **1,400+ times
back-to-back over ~8 s** inside a single process, so the OS counter's ~1.3–1.6 s
polling resolution has ample opportunity to sample genuine, sustained activity.
Run twice, independently:

| Run | Requested device | `select_device()` returned | Placement log | RTX 3060 (0x0000fb3e) evidence | AMD iGPU (0x0000ea3f) evidence |
|---|---|---|---|---|---|
| 1 | `device_id=5688` (AMD iGPU) | `vendor_id=4098 device_id=5688` (AMD, correct object) | `All nodes placed on [WebGpuExecutionProvider]` | **max=45.4%, avg=43.5%, 5 nonzero samples** | **0 samples, 0%** |
| 2 (repeat) | `device_id=5688` (AMD iGPU) | `vendor_id=4098 device_id=5688` (AMD, correct object) | `All nodes placed on [WebGpuExecutionProvider]` | **max=45.8%, avg=45.7%, 5 nonzero samples** | **0 samples, 0%** |

For comparison, requesting the RTX 3060 (`device_id=9504`) in the same probe shows
the identical pattern in the other direction: RTX 3060 max 43.1–45.2%, iGPU 0 samples
— i.e. **every single tested combination executed on the RTX 3060, regardless of which
device was requested.**

### 5b. Full MDX-Net pipeline, iGPU requested

`end_to_end_pipeline_test.py --device-id 5688`, fresh process:

| Check | Result |
|---|---|
| `select_device()` | Returns the correct AMD iGPU `EpDevice` object (`vendor_id=4098 device_id=5688`, metadata confirms `Description=AMD Radeon(TM) Graphics`) |
| Graph placement (onnxruntime's own claim) | `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` — **claims success, proves nothing about which physical GPU** (per L9's own established distinction) |
| Raw numeric vs CPU | Vocals corr=1.00000000 max_abs_diff=**1.10e-06**; Instrumental max_abs_diff=**1.03e-06** — **bit-for-bit identical to the RTX-3060-requested run (§4)** |
| File (WAV) numeric vs CPU | Both stems 3.05e-05 = 1.00× PCM16 LSB — identical to §4 |
| `benchmark_resources.py --device-id 5688 --gpu-monitor-backend nvidia`, warm median | **2.61 s** — statistically indistinguishable from the RTX-3060-requested run's 2.70 s (§4) / W1's 2.67 s |
| `nvidia-smi` whole-GPU utilization during this exact WebGPU phase | 0.0% (CPU phase) → avg **52.3%**, VRAM attributable delta **1081 MB** — statistically indistinguishable from §4's 53.2%/1082MB |
| Per-process GPU-Engine counter (real pipeline invocation) | **Inconclusive by this specific tool** — 0 samples attributed to either adapter for the target PID in this shorter/burstier invocation (see §2's disclosed resolution gap); NOT relied upon as the decisive evidence here |

### 5c. Verdict

**(B) — RTX 3060 performs the work despite the valid, correctly-resolved AMD iGPU
request.** Per-claim verdicts, kept separate as the mission requires:

| Claim | Verdict |
|---|---|
| AMD iGPU enumerated | **PASS** |
| AMD iGPU requested via `select_device(device_id=5688)` | **PASS** — correct object returned |
| onnxruntime accepted the request / session created | **PASS** (claims success) |
| A WebGPU graph executed | **PASS** — 185/185 nodes, confirmed by log and by real GPU activity (§5a/§5b) |
| **The requested physical GPU (AMD iGPU) executed the graph** | **FAIL** — independently disproven (§5a: 0 samples on the iGPU's LUID across 2 reproductions; §5b: `nvidia-smi` shows the RTX 3060 active, not the iGPU; numeric/timing identity with the RTX-3060-requested run) |
| The selector *caused* whichever GPU executed | **FAIL** — the RTX 3060 executed regardless of which device was requested; selection has no observed causal effect |

**Device-selection enforcement: FAIL for this route on this platform/plugin version.**

## 6. Negative controls

All run in fresh processes, using the real, unmodified `webgpu_adapter.select_device()`:

| Test | Result |
|---|---|
| No GPU preference, 2 devices present | **PASS (correctly rejected)** — raises `GpuExecutionNotProvenError`: *"2 WebGPU devices found and no selector given -- refusing to guess."* Matches L9/L10's own established Linux behavior for this same code path |
| Explicit NVIDIA request (`device_id=9504`) | **PASS** — RTX 3060 executes (§4) |
| Explicit iGPU request (`device_id=5688`) | **Accepted by the adapter, but silently NOT honored by execution** (§5) — a genuinely different behavior from the two rows below, and disclosed as such per the brief's explicit instruction |
| Invalid GPU identifier (`device_id=999999`) | **PASS (correctly rejected)** — raises `GpuExecutionNotProvenError`: *"No WebGPU device with device_id=999999."* |
| Ambiguous GPU identifier | **N/A on this platform** — Windows/Dawn exposes no `pci_bus_id` metadata (only unique numeric `device_id`s), so there is no substring/partial-match selector surface on which "ambiguous" could apply the way it might on a differently-keyed selector; the only ambiguity this platform has is "no selector with >1 device," already covered above |

**Key finding, stated explicitly per the brief's own framing**: requesting the two
different valid devices does **not** change which physical GPU executes the same
graph — both land on the RTX 3060. Per the brief's own instruction ("If both valid
requests lead to the same physical GPU, do not mark selection as enforced"), selection
is **not enforced** on this platform for this plugin version. The adapter's own
input-validation layer (rejecting nonexistent/no-selector cases) is a **separate,
correctly-functioning behavior** from the underlying EP's silent non-enforcement of a
*valid* selection — exactly the two-behaviors distinction the brief asked to be kept
separate.

## 7. Windows process-local device-isolation mechanism — investigated, not found

**Verdict: no supported, process-local Windows/D3D12 mechanism to constrain Dawn's
physical-adapter choice was found, reachable from this project's Python-level
`onnxruntime-ep-webgpu` usage, within the mission's constraints.**

- **Environment variable, Linux-`VK_LOADER_DEVICE_ID_FILTER`-style**: **refuted, not
  assumed.** `onnxruntime_providers_webgpu.dll` was scanned for every printable ASCII
  string ≥6 characters (149 adapter/GPU/LUID/preference-related candidates found and
  reviewed). No environment-variable name referencing adapter, GPU, device, or LUID
  selection exists anywhere in the binary. (`ORT_WEBGPU_EP_SHADER_DUMP_FILE` and
  `DAWN_DEBUG_BREAK_ON_ERROR` do exist as real env vars in this binary, confirming
  Dawn/onnxruntime's env-var mechanism works in general — just not for this purpose.)
- **Dawn's own native LUID-targeting capability exists, but is not exposed to this
  project's caller.** The binary contains `RequestAdapterOptionsLUID`,
  `adapterLuidHighPart`/`adapterLuidLowPart`, `EnumAdapterByLuid`, and
  `IDXGIAdapter::GetDesc`/`IDXGIAdapter3::GetDesc` symbols — Dawn's D3D12 backend
  (`dawn::native::d3d::Backend::DiscoverPhysicalDevices`, also present by mangled
  name) genuinely can enumerate and target one specific adapter by LUID at the
  C++/Dawn-native level. **This capability is real, but `onnxruntime-ep-webgpu`
  0.3.0's Python-facing API (`add_provider_for_devices([device], extra_options)`) does
  not thread the caller's chosen `EpDevice`'s LUID through to it** — consistent with,
  and the likely root technical cause of, the plugin's own documented "selects the
  physical GPU independently" behavior confirmed in §5. Five plausible `extra_options`
  key names (`luid`, `adapter_luid`, `deviceLuid`, `device_luid`, `preferred_adapter`)
  were tried empirically against the iGPU target; all were silently accepted (no
  error) with no observed effect on which GPU executed — consistent with the plugin
  simply ignoring unrecognized `extra_options` keys rather than using any of them.
- **`DXGI_GPU_PREFERENCE`/`IDXGIFactory6::EnumAdapterByGpuPreference`**: confirmed
  in use *by Dawn internally*, for **enumeration ordering only** (this is exactly what
  populates the `DxgiHighPerformanceIndex` metadata in §1 — RTX 3060=0, iGPU=1) — not
  exposed to this project's caller, and enumeration order is a different thing from
  which adapter Dawn actually opens a device against (the same "preference/ordering
  vs. actual physical isolation" distinction L10 drew for Linux's
  `MESA_VK_DEVICE_SELECT` vs. `VK_LOADER_DEVICE_ID_FILTER`).
- **Windows per-app Graphics Settings preference**
  (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, keyed by the full `python.exe`
  path, e.g. `GpuPreference=1;` for power-saving/integrated): a real, documented
  Windows mechanism that plausibly *could* influence which adapter is "preferred" for
  a given executable — **investigated, not applied.** This is a **persistent,
  per-user, per-executable-path registry setting**, not a process-local environment
  variable — it would affect every future launch of that exact `python.exe` by this
  user, not just this experiment's process, and is exactly the kind of "system-wide
  graphics setting change" the mission explicitly prohibits. No attempt was made to
  set it, confirm its effect, or revert it.
- **A genuine native-glue path exists but was not pursued, by design**: the binary
  also references `webgpu_device`/`webgpu_instance`/`dawn_proc_table` string-parsed
  `extra_options` keys (`std::from_chars(...)` on their values) — apparently meant for
  a caller that already owns a raw Dawn `WGPUDevice`/`WGPUInstance` native handle and
  wants to hand it to onnxruntime directly. Exploiting this would require building a
  separate ctypes/native shim that calls Dawn's own exported C API
  (`wgpuInstanceRequestAdapter`, `wgpuAdapterRequestDevice`, etc., using
  `RequestAdapterOptionsLUID` to force the iGPU) entirely outside onnxruntime's own
  device-selection surface — this is real, but is architecturally equivalent to
  writing a small Dawn-embedding application, which crosses into "starting a Dawn
  fork"-adjacent territory the mission explicitly rules out. **Not attempted.**

**Smallest plausible upstream API change** (per the mission's own request for this if
no mechanism is found): `onnxruntime-ep-webgpu` should thread the selected
`OrtEpDevice`'s DXGI LUID (Windows) / PCI device ID (Linux) through into Dawn's
`RequestAdapterOptions` (via the `RequestAdapterOptionsLUID` chained struct on
Windows, and the Vulkan analogue — `VkPhysicalDeviceIDPropertiesKHR`/device UUID — on
Linux) when constructing the adapter request, instead of calling `RequestAdapter`
without adapter-specific constraints and letting Dawn's own default/power-preference
logic choose independently of the caller's selection. This is a genuinely small,
well-scoped change (the capability already exists natively in Dawn on both backends,
per the binary evidence above) — but it is squarely an upstream `onnxruntime-ep-webgpu`
change, not something fixable from this project's calling code.

## 8/9. MDX-Net full iGPU validation / Demucs on iGPU

**BLOCKED / NOT TESTED, per the mission's explicit instruction.** §5 did not
positively establish iGPU execution — it affirmatively disproved it. No iGPU-specific
performance, memory, or numerical-correctness figures are reported, because none were
genuinely obtained; every number produced during an "iGPU-requested" run is RTX 3060
output/timing mislabeled by the request (§5b), and reporting it as an iGPU result
would misattribute NVIDIA behavior to different hardware — exactly the trap L9
identified on Linux and this phase's own instructions repeat.

## 10. Implications for the L11 capability matrix / resolver

- `capability_matrix.py`/`.json`: the two existing Windows RTX 3060 rows (MDX-Net,
  Demucs) had their `device_selection_enforceable` field updated from "UNKNOWN / NOT
  PROVEN" to a `DISPROVEN` verdict with this phase's evidence pointer — their
  `found_correct`/`suitable_for_auto`/numeric/performance facts are **unchanged**
  (the RTX 3060 genuinely does execute both models correctly and fast; only the
  *causal-selection* claim changed). A new row was added: Windows AMD iGPU + MDX-Net,
  `found_correct=False`, with a `FAIL` selector verdict and full evidence pointer to
  this document. No row was fabricated for Demucs-on-iGPU (never attempted, §8/9) or
  claimed as validated iGPU evidence (§9) — both explicitly absent from the matrix,
  matching L9's own "don't invent a row for an untested combination" discipline. All
  10 pre-existing rows are otherwise unmodified (11 total rows now).
- `backend_resolver.py`: **no code change was needed.** Its existing `_isolation_for()`
  already treats any non-Linux platform with >1 GPU as unenforceable, structurally
  (a `sys.platform`/`os_arch` check, not one that reads the matrix's advisory text) —
  this was already correct *before* W2 ran, as a conservative default, and W2's result
  now gives it a positive, confirmed reason rather than an absence-of-evidence one.
  This was verified, not assumed: 7 new W2-specific tests were added to
  `test_backend_resolver.py` (§11) asserting exactly this behavior against the real
  W2-derived `GpuInfo` objects, all passing without touching `backend_resolver.py`'s
  logic.
- A genuine, previously-undetected test-suite finding surfaced while running the full
  suite on Windows for the first time: two pre-existing Linux-isolation-plan test
  cases (`os_arch="linux"`, simulated on any host per this file's own design intent)
  crash when the actual host isn't Linux, because `linux_vulkan_isolation.py`'s
  `build_isolation_plan()` has its own, stricter, real `sys.platform` check (by
  design — it must never fabricate a real env-var plan for a mechanism that cannot
  possibly apply on the host actually running it). Fixed by skipping (not silently
  passing, not counted as a failure) those two specific sub-tests on a non-Linux host,
  with the reasoning printed — `backend_resolver.py`/`linux_vulkan_isolation.py`
  themselves were not changed. See §11.

## 11. Test suite results

`python test_backend_resolver.py`, run in this Windows venv:

```
27/27 policy tests passed (2 skipped, non-Linux host -- see ON_LINUX above).
SKIPPED: ['780M + MDX-Net (explicit, RX 9070 also present): isolation env is built and targets the 780M',
          'Linux RTX 3060 + MDX-Net (dual GPU): explicit selection uses L10 loader isolation']
```

All 22 pre-existing policy tests are preserved verbatim (Radeon 780M MDX-Net PASS,
Radeon 780M Demucs BLOCKED, Linux RTX 3060 N1 results, Apple M1 results, existing
Windows RTX 3060 W1 results — none deleted or weakened); 2 of them are environment-
gated skips explained in §10, not failures, and not present in any prior phase's
Linux-only test run because this is the first time this suite has been executed on a
non-Linux host. 7 new, focused W2 tests were added (Windows multi-GPU selection,
physical-GPU-proof-vs-claimed-selection distinction, requested-GPU-differs-from-
observed, no-safe-isolation-mechanism, explicit-request-fails-closed, unknown-iGPU
capability, and correct handling of the *disproven* — not validated — iGPU evidence
this phase actually obtained). All pass.

## 12. Scope discipline

No production STEMwerk venv, model registry, runtime resolver, installer/bootstrap,
REAPER UI file, or existing CUDA/ROCm/MPS/DirectML route was modified. No system-wide
Windows graphics setting, Device Manager entry, or driver was changed (§7's registry
mechanism was investigated and explicitly not applied). No ONNX Runtime binary was
patched (§7's DLL inspection was read-only `strings` extraction). No Dawn/ONNX Runtime
fork was started. The existing W1 venv (`C:\Users\Administrator\stemwerk-rnd\venvs\
webgpu-ep\.venv-webgpu`) was reused unmodified — no new venv was required. No models,
audio, stems, caches, or large logs were committed — all evidence JSON/WAV output was
written under `C:\Users\Administrator\stemwerk-rnd\evidence\w2\`, outside git, exactly
mirroring W1/N1's own convention.

## 13. Explicit limitations

- The per-process OS-counter methodology (§2) did not independently confirm which
  physical GPU executed the *real, full MDX-Net pipeline* invocations specifically —
  only the dense-probe methodology (same device-selection code, smaller/repeated
  graph) achieved reliable per-process attribution. The full-pipeline conclusion in
  §5b rests on `nvidia-smi` whole-GPU correlation plus numeric/timing identity, not
  the same per-process rigor as §5a. This is disclosed, not hidden.
- Only `UVR_MDXNET_KARA_2.onnx` was used for the decisive test; Demucs (`htdemucs.onnx`)
  device-selection enforcement was not independently re-tested this phase (the
  device-selection layer is shared/model-independent at the session-construction
  level, so this is a reasoned inference, not a separately-obtained result — recorded
  as such in the capability matrix, §10).
- §7's mechanism search was read-only binary inspection and empirical `extra_options`
  probing; it does not constitute a complete audit of every possible Dawn/D3D12 API
  surface, and does not rule out a mechanism reachable only through source-level Dawn
  API access (out of scope per the mission's own constraints).
- This machine's AMD integrated GPU was never proven to execute *anything* via this
  plugin — its own standalone capability (throughput, stability, memory behavior) as
  an execution target is genuinely unknown, not merely "not chosen." No claim, positive
  or negative, is made about the iGPU's own WebGPU capability independent of this
  selection-enforcement finding.
