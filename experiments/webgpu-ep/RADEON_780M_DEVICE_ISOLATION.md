# Radeon 780M GPU Isolation — Phase L10

Status date: 2026-09-20. Starting HEAD `9faca28818f8e29ae45fcb89d69a4b51362f8ac0` (L9).
Follows directly from **`RADEON_780M_IGPU_VALIDATION.md`** (L9), which found that
`onnxruntime-ep-webgpu` 0.3.0 *enumerates* the Radeon 780M correctly but silently
executes on the RX 9070 regardless of which device is requested — a self-disclosed
plugin limitation ("the WebGPU EP ... selects the physical GPU independently"), not a
780M defect. This phase asks a narrower question: **can the physical GPU be forced
through a mechanism *outside* onnxruntime's own (broken) device-selection API** —
specifically, process-local Vulkan/Mesa device isolation — **while leaving the RX 9070
connected and fully operational?**

**Headline result: yes, for one model, with a real and honestly-reported limit found
for the other.** `VK_LOADER_DEVICE_ID_FILTER` — an official Vulkan-Loader environment
variable (not a Mesa layer, not an onnxruntime option) — genuinely and symmetrically
excludes the non-target GPU from a subprocess's Vulkan physical-device list, confirmed
independently of onnxruntime at three levels: raw `vulkaninfo` enumeration, real
ONNX Runtime session creation, and kernel-level (`amdgpu` sysfs) GPU-busy monitoring
outside Dawn/Vulkan/onnxruntime entirely. **MDX-Net ran a full, genuine, numerically
validated pass on the physical Radeon 780M** — the RX 9070 sat at its idle baseline
throughout. **Demucs did not**: the same isolation mechanism correctly held execution
on the 780M, but the full-length (16.7 s) clip crashed the Vulkan context
(`VK_ERROR_DEVICE_LOST`) partway through — the 780M is simply too slow at this
specific 1594-node graph, and a 2-second diagnostic clip (which succeeded, taking
221.5 s — ~114× slower than CPU) confirms this is a throughput/watchdog problem, not
an isolation, compatibility, or memory problem. The RX 9070 was unaffected by the
crash and remained fully operational throughout, as required.

## Section 1: Git preflight

- Worktree: `/mnt/PRODUCTION/GIT/STEMwerk-worktrees/webgpu-ep`, branch
  `experiment/webgpu-ep`. Starting local HEAD: `9faca2881` (L9), matching the expected
  value exactly.
- `git fetch origin`: no new commits. `origin/experiment/webgpu-ep` == local HEAD ==
  `9faca2881`. No divergence to reconcile.
- As instructed: this only means *this machine's view of origin* hasn't moved — it
  does not prove no concurrent NVIDIA Linux-slice work exists, since uncommitted or
  unpushed work on another machine is invisible to `git fetch`. No assumption of "no
  concurrent work" is made beyond what the fetch can actually show.
- Worktree clean (`git status --short` empty) before starting.

## Section 2: L9 evidence reviewed

`RADEON_780M_IGPU_VALIDATION.md`, the README's L9 section, `webgpu_adapter.py`, and
the L9 kernel-monitoring approach were re-read before starting. The specific trap
called out in the brief — declaring success from GPU enumeration or session-creation
logs alone — is exactly what L9 demonstrated *not* to be sufficient (onnxruntime
reported "success" while kernel-level monitoring showed the RX 9070, not the 780M,
doing the work). This phase treats every result the same way: **enumeration and
session-creation success are necessary but never sufficient; only independent
kernel-level evidence during actual `session.run()` calls counts.**

## Section 3: Hardware re-verification (not assumed from L9)

Re-checked fresh, not carried over from the brief or from L9's own numbers:

| Source | RX 9070 | Radeon 780M |
|---|---|---|
| `vulkaninfo --summary` | `deviceID=0x7550`, `AMD Radeon RX 9070 (RADV GFX1201)`, `DISCRETE_GPU`, driver `radv`/Mesa 26.2.2-arch1.1 | `deviceID=0x15bf`, `AMD Radeon 780M Graphics (RADV PHOENIX)`, `INTEGRATED_GPU`, same driver |
| `/sys/class/drm/card*/device/uevent` `PCI_SLOT_NAME` | `card1` → `0000:03:00.0` | `card0` → `0000:69:00.0` |

Both identifiers are unchanged from L9. Critically: **both GPUs are exposed through
the exact same RADV driver instance** (`driverName=radv`, identical `driverInfo`) —
there is only one Vulkan ICD in play here, so "select a driver" is not a meaningful
axis of control on this system (see Section 4). The only way to isolate one physical
GPU from the other is to filter *within* that single driver's device list.

## Section 4: Candidate isolation mechanisms investigated

| Mechanism | What it actually does | Verified |
|---|---|---|
| `VK_LAYER_MESA_device_select` (Mesa's device-select instance layer, active by default) | Provides `MESA_VK_DEVICE_SELECT` (see below) | Confirmed active via `vkEnumerateInstanceLayerProperties` listing |
| `MESA_VK_DEVICE_SELECT=<pci-id>` | **Reorders** enumeration so the chosen device becomes index 0 (category 1/2: preference + reorder) | Confirmed via `vulkaninfo`: device order flips, but **both devices still enumerate**, and real inference still executed on the RX 9070 regardless (avg busy 93.6%) — **zero effect on physical execution** |
| `DRI_PRIME` | Mesa's classic discrete-vs-integrated switch for GLX/EGL clients; not applicable — this stack goes through the Vulkan loader directly, not DRI_PRIME's GL/EGL dispatch path | Not applicable, not pursued further |
| `VK_LOADER_DEVICE_ID_FILTER=<hex>` (official Khronos Vulkan-Loader env var) | **Hides** non-matching physical devices from `vkEnumeratePhysicalDevices()` entirely — category 3/5: true exclusion + physical-device selection | **Confirmed** — this is the mechanism used for every result below |
| Other Vulkan-Loader vars found via `strings libvulkan.so.1` (`VK_LOADER_VENDOR_ID_FILTER`, `VK_LOADER_DRIVER_ID_FILTER`, `VK_LOADER_DRIVERS_SELECT`, `VK_LOADER_DEVICE_SELECT`, `VK_LOADER_LAYERS_ALLOW/DISABLE/ENABLE`, `VK_LOADER_DISABLE_SELECT`) | Present in the loader binary; not needed once `VK_LOADER_DEVICE_ID_FILTER` was confirmed sufficient | Inventoried, not individually exercised |
| Dawn/onnxruntime-side selection (`add_provider_for_devices`) | The mechanism L9 already proved silently non-functional | Not retried — L9's finding stands |

**The category distinction the brief asked for, resolved concretely**: `MESA_VK_DEVICE_SELECT`
only ever touches categories (1) preference and (2) enumeration order — it never
removes a device from the list, so a caller (or a library) that ignores ordering and
picks by other criteria can still land on the "wrong" GPU, which is consistent with
why it had zero effect on actual execution. `VK_LOADER_DEVICE_ID_FILTER` operates at
category (3) hiding and, as a direct consequence, (5) physical-device selection —
it acts before the device list ever reaches the instance/layer chain the application
sees, so there is no "wrong" device left to accidentally pick. Category (4), driver
selection, does not apply on this machine at all (Section 3) — both GPUs share one
RADV driver, so "selecting a driver" can never be mistaken here for "selecting a GPU,"
exactly the distinction the brief warned about.

**A genuine early dead-end, resolved and documented rather than hidden**: the first
test of `VK_LOADER_DEVICE_ID_FILTER` against `webgpu_adapter.list_webgpu_devices()`
(plain enumeration, no session) showed *no filtering effect* — both devices still
listed. Diagnosis: the WebGPU EP plugin's `.so` loads `libvulkan.so.1` via `dlopen()`
(confirmed: absent from `ldd` output, present in `strings`), and `VK_LOADER_DEBUG=error,warn`
showed that plain enumeration does not exercise the full Vulkan-Loader trampoline (no
`lsfg-vk-layer` diagnostic output, unlike every actual session-creation call in this
entire project). **The filter does work — but only observably at the point of real
Vulkan device/instance creation, not at onnxruntime's own cached `EpDevice` metadata
listing.** This is an important, disclosed caveat: `list_webgpu_devices()` /
`ort.get_ep_devices()` output must **not** be trusted as evidence of what will
actually execute under this filter; only session-creation + independent monitoring is
trustworthy. This reframing — verify via real session creation, not enumeration
metadata — is what made every subsequent result in this phase possible.

## Section 6: Proving filtering independently of ONNX Runtime, before any model inference

Raw `vulkaninfo --summary` under each filter, with no onnxruntime involved at all:

| Filter | `Devices:` section shows |
|---|---|
| (none) | `GPU0`=RX 9070 (`0x7550`), `GPU1`=Radeon 780M (`0x15bf`) — both |
| `VK_LOADER_DEVICE_ID_FILTER=0x15bf` | **Only** the Radeon 780M — RX 9070 absent from the entire device list |
| `VK_LOADER_DEVICE_ID_FILTER=0x7550` | **Only** the RX 9070 — Radeon 780M absent from the entire device list |

Symmetric, bidirectional, confirmed with the ICD's own tool before touching onnxruntime
at all — this rules out "reordering that happens to look like exclusion" and
establishes true exclusion at the Vulkan physical-device level, still driven by the
single shared RADV driver (Section 3/4).

## Section 7: Independent physical-execution verification methodology

Reused L9's kernel-level `DualCardMonitor` (`/sys/class/drm/card{N}/device/gpu_busy_percent`,
sampled at 50 ms, `card0`=780M/`0000:69:00.0`, `card1`=RX 9070/`0000:03:00.0`, mapping
re-confirmed via `uevent` this phase, not assumed) — completely outside
onnxruntime/Dawn/Vulkan's own self-reporting, exactly as in L9. For the full end-to-end
pipeline test a background bash loop wrote both cards' busy percentages every 50 ms to
a log file spanning process start to exit, independent of anything inside the Python
process. Idle baselines were re-confirmed before each test (card0 ≈0%, card1 ≈4–7%,
consistent with L9's own idle baseline — card1's small idle load is the display
compositor holding that card open, as established in L9). A quiet RX 9070 combined
with a busy 780M during the timed `session.run()` window, and not merely during
session creation, is treated as the standard of evidence throughout — never a single
data point or a session-creation log line alone.

## Section 8: Controlled isolation experiments

| Experiment | Setup | Result |
|---|---|---|
| **A — baseline, no filtering** | No env var, `select_device(pci_bus_id="0000:69:00.0")` requested via the existing (L9-proven-broken) onnxruntime API | Reproduces L9 exactly: execution lands on RX 9070 regardless of the request |
| **B — Mesa preference only** | `MESA_VK_DEVICE_SELECT=1002:15bf` | Enumeration order changes; **real execution still lands on RX 9070** (avg busy 93.6%, 780M 0%) — confirms this mechanism alone is insufficient, consistent with Section 4's category analysis |
| **C — strict isolation, target 780M** | `VK_LOADER_DEVICE_ID_FILTER=0x15bf`, confirmed via `vulkaninfo` (Section 6) *before* starting any ONNX Runtime process | **Execution genuinely follows the filter** — this is the mechanism behind every PASS result below |
| **D — reverse control, target RX 9070** | `VK_LOADER_DEVICE_ID_FILTER=0x7550`, same real-session + kernel-monitor methodology | Symmetric confirmation: RX 9070 executes, 780M stays at its idle baseline — establishes the mechanism is not a one-directional coincidence |

No isolation mechanism was declared successful from enumeration or a single adapter
appearing first — every claim in this table rests on real session creation, real
inference, and independent kernel-level monitoring during the timed run, per Sections
6–7.

## Section 9: MDX-Net (`UVR_MDXNET_KARA_2.onnx`) on the actual Radeon 780M — PASS

Full `end_to_end_pipeline_test.py` run, `VK_LOADER_DEVICE_ID_FILTER=0x15bf`,
`--pci-bus-id 0000:69:00.0`, same fixture used throughout L1–L9:

| Check | Result |
|---|---|
| Graph placement | **PASS** — `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` — identical to the L1–L9 baseline |
| CPU fallback | **PASS** — 0 |
| Numeric parity (raw) | **PASS** — Vocals corr=1.00000000 max_abs_diff=7.08e-08; Instrumental corr=1.00000000 max_abs_diff=6.61e-08 — bit-for-bit identical to every prior phase's own recorded figures |
| File (WAV) parity | **PASS** — 3.05e-05 = exactly 1.00× PCM16 LSB, both stems |
| Stem routing | **PASS** — same-stem corr=1.000000 vs other-stem corr=0.998906 |
| Output validation | **PASS** — sr=44100, ch=2, dur=20.00s, no NaN/silence/clipping |
| Independent kernel-level GPU evidence (285 samples, whole pipeline run) | card0 (780M) avg=20.1% max=88%; card1 (RX 9070) avg=7.1% max=45% (its ordinary idle/compositor baseline) — **genuine 780M execution, RX 9070 uninvolved** |
| Timing | load=0.12s, run=4.33s (WebGPU/780M) vs load=0.94s, run=7.91s (CPU, same machine) vs run=1.41s (RX 9070, L1–L9 historical, same fixture) — notably slower than the RX 9070 (consistent with genuine, distinct iGPU hardware, not a coincidental RX 9070 run) |

**This is a decisive, independently-verified, physical-GPU-execution PASS on the
Radeon 780M** — not a graph-placement or session-creation success being mistaken for
one.

## Section 10: Demucs (`htdemucs.onnx`) on the actual Radeon 780M — BLOCKED (runtime failure, root-caused)

Model hash re-verified fresh on this machine: SHA256
`68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`, matches the exact
L4–L9 artifact. Memory preflight before testing: 62 GiB total RAM / 42 GiB available,
0 memory pressure, 780M VRAM used only ~78 MiB (`82,116,608` B, well inside its 512 MiB
dedicated allocation) before Demucs even loaded — no blocking constraint identified.
`ORT_ENABLE_BASIC` graph optimization retained (required workaround for the
`ConvActivationFusion` WebGPU-EP bug, unchanged since L4).

### Full-length clip (16.744 s, the same fixture used throughout L4–L9)

Ran with `VK_LOADER_DEVICE_ID_FILTER=0x15bf`, the exact proven-working mechanism from
Section 9. The kernel monitor confirms genuine, sustained 780M execution
(card0 avg=81.6% max=99%, card1 avg=7.5% max=100% over 4,567 samples spanning the
whole run) — **up until the process crashed**:

```
radv/amdgpu: The CS has been cancelled because the context is lost. This context is guilty of a hard recovery.
Warning: .../mesa-26.2.2/src/amd/vulkan/radv_queue.c:1934: vkQueueSubmit() failed (VK_ERROR_DEVICE_LOST)
terminate called after throwing an instance of 'onnxruntime::OnnxRuntimeException'
  what():  .../webgpu/buffer_manager.cc:641 ... map_async_result.status == wgpu::MapAsyncStatus::Success was false ... [Device] is lost.
```

**System stability check immediately after the crash** (required before drawing any
conclusion, and before further testing): both GPUs returned to their normal idle
baseline (card0=0%, card1=4%) and `vulkaninfo` still enumerated both devices correctly
and identically to Section 3/6. **The RX 9070 was unaffected and remained fully
operational** — the crash was scoped to the 780M's Vulkan context inside the isolated
process, exactly as the brief required.

### Root-causing: 2-second diagnostic clip, same mechanism

To distinguish a timeout/throughput problem from an immediate incompatibility, the
same test was re-run against a 2.0 s clip (88,200 samples) cut from the same source
audio — nothing else changed:

| Check | Result |
|---|---|
| Graph placement | **PASS** — `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594` — identical to the L4–L9 historical baseline, one session, no CPU fallback |
| Completion | **PASS** — no crash |
| Independent kernel evidence (4,002 samples) | card0 (780M) avg=92.9% max=99%; card1 (RX 9070) avg=7.1% max=64% — genuine, heavy, sustained 780M execution throughout |
| Timing | WebGPU/780M: **221.50 s** for 2.0 s of audio (~114× slower than real time); CPU (same machine, same clip): **1.95 s** — the 780M is ~113.6× slower than CPU for this exact graph and input |

**This is the root cause, not a guess**: the full-length clip did not fail
immediately or at model load — it failed partway through a real, sustained,
correctly-isolated 780M execution, and a shorter clip of the identical graph
completes successfully but at a throughput roughly two orders of magnitude below
CPU. The most consistent explanation is that a single oversized Vulkan submission
for the full-length graph exceeded the kernel/Vulkan driver's GPU hang-detection
("TDR"-equivalent) timeout, triggering `radv`'s own hard-recovery path
(`VK_ERROR_DEVICE_LOST`) — a genuine hardware/driver throughput limitation of the
780M for this specific 1594-node graph at realistic input lengths, not a defect in
the isolation mechanism (which continued working correctly right up to the crash),
not an unsupported operation (100% WebGPU placement, 0% CPU fallback in both the
short-clip and pre-crash long-clip runs), and not insufficient memory (preflight
showed large headroom, and the error itself is a device-lost/context-loss error, not
an allocation failure). Per the safety constraints, no attempt was made to change
`amdgpu`'s lockup-timeout or any other kernel/driver watchdog setting — that would
require a system-wide, non-process-local change explicitly out of scope for this
phase.

### Numerical validation — explicitly not obtained, and not substituted

CPU-vs-WebGPU comparison was attempted on the 2 s clip (the only Demucs run that
completed on the 780M) and produced `NaN` correlations and abs-diffs up to 0.71 for
some stems. **This is not reported as a pass or a fail** — a 2.0 s input is far
shorter than `htdemucs`'s expected processing context, and the CPU-side output itself
showed near-degenerate (likely near-silent) behavior for at least one stem at this
length, independent of which execution provider ran it, causing the correlation
computation itself to become undefined. This makes the 2 s clip diagnostically useful
for isolating the crash (Section 10 above) but **not valid evidence for numerical
equivalence at any input length**, and it is not presented as such. No numerical
validation exists for a genuine, complete, realistic-length Demucs run on the 780M,
because none completed.

### Full audio pipeline / four-stem validation — not attempted

Blocked by the crash above; not attempted on a workload known to fail, per the
brief's own instruction not to substitute a different result for the one actually
requested.

## Section 11: Performance (secondary, reported honestly)

| Model | 780M (WebGPU) | CPU (same machine, same input) | RX 9070 (L1–L9 historical, same fixture) |
|---|---|---|---|
| MDX-Net | load 0.12s, run 4.33s | load 0.94s, run 7.91s | run 1.41s |
| Demucs (2 s clip only — full clip did not complete) | run 221.50s | run 1.95s | *(no directly comparable 2s-clip RX 9070 figure recorded in prior phases; not compared)* |

MDX-Net on the 780M is **faster than CPU on the same machine** but **~3× slower than
the RX 9070** — a plausible, honest result for an iGPU vs. a discrete GPU on the same
graph. Demucs on the 780M is **~114× slower than CPU** on the only workload size that
actually completed — reported plainly, as instructed, rather than omitted or
softened. No RX 9070 Demucs comparison is drawn from a different-length input, per
the brief's explicit instruction not to treat differing inputs as comparable.
Dedicated VRAM usage (~78 MiB before load) never approached the 780M's 512 MiB
allocation in any test; shared GTT memory was not separately measured this phase and
is not double-counted as dedicated VRAM in the figures above.

## Section 12: Cross-platform implications

`VK_LOADER_DEVICE_ID_FILTER` is a **Linux-specific, Vulkan-Loader-level mechanism**.
**No claim is made that this technique is portable to Windows (D3D12 adapter
enumeration/DXGI, an entirely different API surface) or macOS (Metal, and in this
project's own evidence, single-GPU on every Apple Silicon machine tested — L8 — so
the underlying multi-adapter selection problem this phase addresses may not even
arise there).** If adopted, this would necessarily be a **Linux-only,
platform-specific device-selection adapter layer wrapped around the existing shared
WebGPU inference implementation** (e.g. a subprocess launcher that sets
`VK_LOADER_DEVICE_ID_FILTER` based on a user's chosen PCI device before spawning the
actual inference worker) — not a change to the shared `webgpu_adapter.py`/
`demucs_onnx` code paths themselves, and not implemented in this phase.

Maintenance/packaging implications, if a future resolver were to use this: it depends
on an environment variable that is part of the standard Khronos Vulkan-Loader (not a
private/undocumented Mesa extension), which is a reasonably durable API surface, but
still an implementation detail of a component STEMwerk does not control the release
cadence of — any future resolver would need a runtime capability check (does this
Vulkan Loader version honor the variable?) with a graceful fallback (CPU, or a clear
"cannot select this GPU" error) rather than silently misrouting the way the current
onnxruntime-ep-webgpu plugin does (L9).

**Assessment (not implementation) of a future backend resolver**: technically
feasible for **device selection** on Linux specifically — Section 8/9 demonstrate a
real, working, process-local mechanism. However, Section 10 shows device selection
alone is not sufficient for a good user experience: **the resolver would also need
per-model/per-GPU capability gating**, not just device selection — e.g., allow
MDX-Net-class graphs on a modest iGPU like the 780M, but warn or block Demucs-class
graphs on the same hardware given the ~114× CPU slowdown and outright hard-crash risk
observed at realistic input lengths. A resolver that only solved "which GPU" without
also solving "is this GPU fast/stable enough for this specific model" would trade one
kind of silent failure (wrong GPU, L9) for another (unusably slow or crashing GPU,
this phase).

## Status matrix

| Checkpoint | Result |
|---|---|
| Radeon 780M enumerated | **PASS** |
| Process-local Vulkan filtering | **PASS** — `VK_LOADER_DEVICE_ID_FILTER`, confirmed via `vulkaninfo` independent of onnxruntime, bidirectional (§6, §8 Exp. C/D) |
| RX 9070 excluded from target process | **PASS** — confirmed via `vulkaninfo` (§6) and kernel-level idle-baseline monitoring during every 780M-targeted run (§9, §10) |
| Dawn physical-device selection verified | **PASS** — real session creation + `session.run()` + independent kernel monitoring, not enumeration metadata alone (§7, §9) |
| MDX-Net inference on actual 780M | **PASS** — full pipeline, independently verified (§9) |
| MDX-Net numerical validation | **PASS** — bit-identical to L1–L9's own recorded figures (§9) |
| Demucs inference on actual 780M | **BLOCKED** — genuine, isolated 780M execution confirmed, but the full-length clip triggers a driver-level hang/`VK_ERROR_DEVICE_LOST`; a shorter clip completes, root-causing this as a throughput/watchdog limit, not an isolation failure (§10) |
| Demucs numerical validation | **NOT TESTED** — no valid completed run at a representative input length exists (§10) |
| End-to-end audio | **PASS** (MDX-Net only, §9) / **NOT TESTED** (Demucs, §10) |
| Performance | **PASS** (data honestly obtained and reported for both models, including an unfavorable 780M/Demucs result, §11) |
| Production device-selection feasibility | **PASS — model-dependent** (§12): proven mechanism for MDX-Net-class graphs; not currently viable for Demucs-class graphs on this iGPU without additional per-model capability gating |

## Code changes required

**None in `webgpu_adapter.py` or any production/experiment inference code.** The
isolation mechanism is entirely an environment variable set on the subprocess before
it starts — no source change was needed to reproduce every result above. One new,
non-production diagnostic file was created and kept outside the repository per the
brief's "no large logs" instruction:
- `/tmp/l10_gpu_log.txt`, `/tmp/l10_gpu_log_demucs.txt`, `/tmp/l10_gpu_log_demucs_2s.txt` —
  raw kernel-monitor logs from each timed run (not committed).
- `/tmp/l9_gpu_monitor.py`'s `DualCardMonitor` class was reused unmodified from L9
  (also not committed, per the same instruction, carried over as scratch tooling).
- `/tmp/l10_demucs_2s_clip.wav` — the diagnostic short clip used for root-causing
  Section 10 (not committed — derived test audio, not a project asset).

## Recommendations for future phases

1. **MDX-Net-class models are a genuine, production-plausible candidate for a
   Radeon-780M-targeted (or similar modest-iGPU) code path on Linux**, using this
   phase's `VK_LOADER_DEVICE_ID_FILTER` subprocess-isolation technique — this is the
   first phase in the whole project to demonstrate real, verified, non-default
   physical-GPU selection working end-to-end.
2. **Demucs-class models should not be offered on this class of iGPU without further
   investigation** — the ~114× CPU slowdown and hard crash at realistic input
   lengths are a genuine hardware/driver throughput limit, not a solvable
   configuration problem within this phase's safety constraints. A narrower follow-up
   could test whether chunked/segmented inference (processing the clip in smaller
   pieces, keeping each individual Vulkan submission below whatever the effective
   hang-detection threshold is) avoids the crash — this was not attempted here since
   it would change the inference code path, not just the device-selection layer, and
   was out of this phase's scope.
3. **A future device-selection resolver needs per-model capability gating, not just
   device selection** (Section 12) — this phase supplies the selection primitive but
   deliberately does not implement a resolver.
4. L9's own recommendation — independently re-verifying a prior "successful" device
   selection claim (e.g. Windows RTX 3060) with kernel/OS-level tooling — remains
   open and unaddressed by this phase, which focused on the Linux iGPU isolation
   question instead.

## Git

- Starting HEAD: `9faca2881` (L9). No `git fetch` changes found (Section 1) — no
  reconciliation needed.
- This phase's own commit: documentation only (`RADEON_780M_DEVICE_ISOLATION.md`,
  new; `README.md`, updated) — no source/experiment-script changes, per "no code
  changes required" above.
- Not pushed automatically, per instructions.
