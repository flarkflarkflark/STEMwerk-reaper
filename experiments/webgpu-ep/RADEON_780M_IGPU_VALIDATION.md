# AMD Radeon 780M Integrated GPU Validation — Phase L9

Status date: 2026-09-20. Companion to every prior report in `experiments/webgpu-ep/`.
Tests whether the same shared `webgpu_adapter.py`/`demucs_onnx`/`demucs_shift_wrapper.py`
implementation, already proven on AMD RX 9070 (Linux/Vulkan), Apple M1 (macOS/Metal),
and NVIDIA RTX 3060 (Windows/D3D12), can also serve users with **no discrete GPU at
all** — the AMD Radeon 780M integrated GPU present on this same Linux workstation.

**Headline result: a genuine, reproducible, vendor-documented limitation was found —
not a Radeon 780M defect.** Device *enumeration* correctly identifies the 780M with
accurate metadata. Device *selection* — passing that specific device object to
`add_provider_for_devices()`, exactly as every prior phase has done — is silently
**not honored** on this multi-GPU Linux configuration: `onnxruntime-ep-webgpu` 0.3.0's
own packaged documentation states plainly, "*The WebGPU EP currently accepts one EP
device and selects the physical GPU independently*" — and independent, kernel-level
verification (outside onnxruntime entirely) confirms execution silently lands on the
RX 9070 every time, for both MDX-Net and Demucs, regardless of which device was
requested. **This is classified as BLOCKED per the brief's own explicit rule ("if the
device cannot be identified unambiguously... classify as BLOCKED instead of
substituting the RX 9070") — no 780M performance or correctness numbers are reported,
because none could be genuinely obtained.** This also raises a real, disclosed
question about whether prior phases' "explicit device selection" claims were ever
truly exercised, addressed in §10.

## Phase 0: Git synchronization

- Worktree: `/mnt/PRODUCTION/GIT/STEMwerk-worktrees/webgpu-ep`, branch
  `experiment/webgpu-ep`. Starting local HEAD: `c59c8e421` (L7).
- `git fetch origin` found two new commits: `0e8d825fc` (L8, macOS) and `2d1ed69d7`
  (W1, Windows/NVIDIA) — exactly matching the expected post-W1 HEAD
  `2d1ed69d76428bc04c47cdf16b273b2485a36aef`, no discrepancy.
- `git merge --ff-only origin/experiment/webgpu-ep`: clean fast-forward, no conflicts.
  Worktree clean before and after.
- W1's changes reviewed via `git diff` before trusting anything (not just read as
  prose): both genuine Windows bug fixes in `webgpu_adapter.py` (POSIX-only
  `ctypes.CDLL(None)` fflush call, UTF-16LE vs UTF-8 log decoding) are strictly inside
  `sys.platform == "win32"` branches; the non-Windows branches are byte-identical to
  pre-W1 code. `--device-id` CLI flags added to three scripts are new, optional,
  default-`None` parameters — `select_device(pci_bus_id=..., device_id=None)`
  reproduces the exact prior call when omitted. `resource_sampler.py`'s Windows RSS
  reader and `nvidia-smi` path are behind a new `gpu_backend` parameter defaulting to
  `"rocm"` (unchanged). Confirmed by diff inspection, then **re-verified by actual
  execution, not assumed** — see §3.

## Section 3: RX 9070 regression baseline (re-verified by execution, not diff-reading)

### MDX-Net (`UVR_MDXNET_KARA_2.onnx`, `--pci-bus-id 0000:03:00.0`)

Ran `end_to_end_pipeline_test.py` unchanged, same fixture/model as every prior Linux
phase:

| Check | Result |
|---|---|
| Graph placement | **PASS** — `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` — identical to the L1–L8 baseline |
| CPU fallback | **PASS** — 0 |
| Numeric parity (raw) | **PASS** — Vocals corr=1.00000000 max_abs_diff=7.08e-08; Instrumental corr=1.00000000 max_abs_diff=6.61e-08 — **bit-for-bit identical to every prior Linux phase's own recorded figures** |
| File (WAV) parity | **PASS** — 3.05e-05 = exactly 1.00× PCM16 LSB, both stems |
| Stem routing | **PASS** — same-stem corr=1.000000 vs other-stem corr=0.998906 |
| Output validation | **PASS** — sr=44100, ch=2, dur=20.00s, no NaN/silence/clipping |

**No Linux regression from W1.**

### Demucs (`htdemucs.onnx`, SHA256 `68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74`)

Hash re-verified fresh on this machine (matches L4–L8/W1's artifact exactly). Ran the
same `demucs_shift_wrapper.py` + `webgpu_adapter.py` pattern used throughout L4–L8:

| Check | Result |
|---|---|
| Graph placement | **PASS** — `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594`, one session (`gpu_reports: 1`) |
| CPU fallback | **PASS** — 0 |
| CPU-ONNX bit-identity vs L5's own saved baseline | **PASS** — `np.array_equal` true, all 4 stems |
| ONNX CPU vs WebGPU numeric parity | **PASS** — drums/bass/vocals corr=1.00000000, other corr=0.99999999; max abs diff 5.56e-05–2.01e-04 — **the same exact figures already recorded in L5/L6/L7** |

**No Linux regression from W1.** Both models fully re-verified by real execution
before proceeding to the 780M.

## Section 4: Radeon 780M identification — where the real finding is

### Hardware, re-verified fresh (not assumed from the brief's "historical" values)

| Source | RX 9070 | Radeon 780M |
|---|---|---|
| `lspci -nnk` | `03:00.0`, `[1002:7550]`, driver `amdgpu` | `69:00.0`, `[1002:15bf]` ("Phoenix1"), driver `amdgpu` |
| `vulkaninfo` | `deviceID=0x7550`, `deviceName="AMD Radeon RX 9070 (RADV GFX1201)"`, `driverInfo="Mesa 26.2.2-arch1.1"` | `deviceID=0x15bf`, `deviceName="AMD Radeon 780M Graphics (RADV PHOENIX)"`, same driver |
| `webgpu_adapter.list_webgpu_devices()` | `vendor_id=4098(0x1002) device_id=30032(0x7550) pci_bus_id=0000:03:00.0 card_idx=1` | `vendor_id=4098(0x1002) device_id=5567(0x15bf) pci_bus_id=0000:69:00.0 card_idx=0` |

All three sources agree exactly — device identification/enumeration is **correct**.
Both historical PCI addresses from the brief were confirmed current, not assumed.

### Negative controls

| Test | Result |
|---|---|
| `select_device(pci_bus_id="0000:99:00.0")` (nonexistent) | **PASS** — raises `GpuExecutionNotProvenError` with the full device list, does not guess |
| `select_device()` with no selector, 2 devices present | **PASS** — raises, refuses to guess, unchanged from L1–L8 |
| `select_device(pci_bus_id="0000:69:00.0")` (explicit 780M) | Returns the correct `EpDevice` object with correct metadata — **but see below: this is where the problem actually is** |

### The core finding: selection is accepted but not honored

`select_device()` returning the *correct object* is not the same as onnxruntime
actually *executing on that object's physical GPU* — the brief's own instruction
("GPU enumeration alone is insufficient... prove that actual inference runs on the
Radeon 780M rather than the RX 9070") anticipated exactly this gap. Independent,
kernel-level verification was used — `/sys/class/drm/card{N}/device/gpu_busy_percent`
(amdgpu's own driver-reported per-physical-GPU engine utilization, confirmed via
`/sys/class/drm/card*/device/uevent`'s `PCI_SLOT_NAME` to be `card0`=780M/`69:00.0`,
`card1`=RX 9070/`03:00.0` — completely outside onnxruntime, Dawn, or Vulkan's own
self-reporting):

| Test | onnxruntime's own claim | Independent kernel-level evidence |
|---|---|---|
| MDX-Net, `pci_bus_id="0000:03:00.0"` (RX 9070) requested | `All nodes placed on [WebGpuExecutionProvider]` | card1 (RX 9070) avg busy **93.8%**, card0 (780M) **0%** — consistent with the request |
| MDX-Net, `pci_bus_id="0000:69:00.0"` (**780M**) requested | `All nodes placed on [WebGpuExecutionProvider]` | card1 (RX 9070) avg busy **95.1%**, card0 (780M) **0%** — **execution silently landed on the RX 9070 instead** |
| Demucs, `pci_bus_id="0000:69:00.0"` (**780M**) requested | `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 1594` | card1 (RX 9070) avg busy **98.0%**, card0 (780M) **0%** — **same misrouting, second model, fully reproduced** |

Idle-baseline sanity check performed first (ruling out a coincidental/background
explanation): card1 idles at 7–17% (this is the machine's actual *display* GPU — `kwin_wayland`
and `Xwayland` were confirmed via `fuser -v /dev/dri/card1` to hold it open — ordinary
desktop-compositor load), card0 idles at 0%. The 93–98% sustained spikes during the
timed inference calls are categorically different from that baseline and align
precisely with the timing of each test's `session.run()` calls.

**Root cause, confirmed from the vendor's own shipped documentation** (not inferred):
`onnxruntime_ep_webgpu`'s packaged `README.md`, line 42 — *"The WebGPU EP currently
accepts one EP device and selects the physical GPU independently."* PyPI confirms
0.3.0 is still the current, latest release (checked directly; no newer version
exists to upgrade to). This is a **current, self-disclosed limitation of the plugin
EP itself**, not a defect in `webgpu_adapter.py`'s `select_device()`/
`add_provider_for_devices()` usage, not a Radeon 780M hardware/driver problem (RADV
enumerates and names it correctly, per §4's table), and not something fixable by any
combination of `SessionOptions`, environment variables, or `extra_options` dict
content — none of the plugin's binary symbols (`strings` on the `.so`) reference any
device-select environment variable, and the README documents no override mechanism.
No system driver, Vulkan configuration, or firmware change was attempted or would
plausibly help, consistent with the brief's own constraint.

## Sections 5 & 7: MDX-Net and Demucs "on the Radeon 780M" — BLOCKED

Per the brief's explicit instruction ("if the device cannot be identified
unambiguously, classify the test as BLOCKED instead of substituting the RX 9070"):
**both models' inference-on-780M claims are classified BLOCKED, not PASS and not
FAIL.** Real inference did occur in both attempts (§4's table) — but demonstrably on
the RX 9070, not the requested device, so none of it constitutes evidence about the
Radeon 780M's own capability, correctness, or performance. Reporting timing, memory,
or numerical figures from these runs as "780M results" would misattribute RX 9070
behavior to different hardware — none are reported here for that reason.

## Section 6: Demucs memory/resource preflight — completed, moot given §4, retained for the record

Performed before attempting Demucs (per the brief's required ordering), independent of
the device-selection finding:

| Resource | Value |
|---|---|
| Total system RAM | 62 GiB |
| Available RAM (at test time) | 43 GiB |
| Swap configured | **0 B** (pre-existing system state — not disabled by this experiment) |
| Memory pressure (`/proc/pressure/memory`) | `avg10=0.00 avg60=0.00 avg300=0.00` — no pressure |
| 780M dedicated VRAM (`mem_info_vram_total`) | 512 MiB (536,870,912 B) — small, typical carved-out iGPU BIOS framebuffer reservation |
| 780M GTT (system-RAM-backed GPU-accessible memory) | 33,335,652,352 B ≈ **31 GiB** |

**Conclusion: memory would not have been the limiting factor.** The 780M's tiny
dedicated VRAM allocation is a non-issue in practice on this Linux/amdgpu stack — GTT
(GPU-visible system RAM, the mechanism Vulkan/Dawn actually uses for iGPU buffer
allocation on Linux) provides far more headroom than Demucs's ONNX graph needs (L4–L8
observed roughly 1–2 GB of GPU-side allocation on the RX 9070 for this exact model).
This finding is retained for future reference (e.g. if a fixed version of the plugin
EP becomes available) even though it did not end up gating anything this phase.

## Section 8: Full audio/numerical validation on the 780M — NOT TESTED

Not attempted, per the brief's own guidance not to substitute the RX 9070 and report
it as a Radeon 780M result. No stem, routing, or numerical data for genuine 780M
execution exists to report.

## Section 9: Performance — NOT TESTED (genuinely, not by omission)

No timing, RTF, RSS, or GPU-memory figures are reported for the 780M, because every
attempt to collect them would have measured the RX 9070 instead (§4). This section is
intentionally empty rather than backfilled with the (already-collected, but
mislabeled-if-used) RX-9070-via-780M-request numbers.

## Section 10: Cross-platform implications — including a retroactive methodological question

Confirmed inventory, updated:

| Hardware | Platform | Backend | Status |
|---|---|---|---|
| AMD RX 9070 | Linux | Vulkan | **Proven** — L1–L7, re-verified §3 this phase |
| Apple M1 | macOS | Metal | **Proven** — L8 |
| NVIDIA RTX 3060 Laptop | Windows | D3D12 | **Proven** — W1 |
| **AMD Radeon 780M (iGPU)** | **Linux** | **Vulkan** | **BLOCKED — device selection not honored by the current plugin EP** |

**What this phase actually demonstrates about integrated-GPU compatibility**: nothing
about the 780M's own capability, positive or negative — the blocker is entirely in
the `onnxruntime-ep-webgpu` 0.3.0 plugin's single-device/independent-selection
behavior on a multi-adapter Linux system, a software limitation that would equally
affect *any* attempt to target a non-default adapter on this stack, iGPU or
otherwise.

**A genuinely important, disclosed methodological question this finding raises**: was
device selection ever truly exercised in L1–L8/W1, or did every prior "explicit
selection" request simply happen to coincide with Dawn's own internal default/
power-preference choice? This cannot be fully answered retroactively without
re-running those phases with the *opposite* selection request (their own discrete
GPU vs. an alternative), which was outside this phase's scope — but the evidence
available is suggestive: on this machine, requesting the RX 9070 explicitly produces
RX 9070 execution (§3), and RX 9070 is very plausibly Dawn's own default "high
performance"/first-enumerated choice too (Vulkan itself lists it as "GPU id = 0",
ahead of the 780M's "GPU id = 1") — so **L1–L8's own RX 9070 selection claims remain
most likely correct, but not now fully distinguishable from "happened to match the
plugin's own default" using only this machine's evidence.** The Windows W1 case
(RTX 3060 discrete vs. AMD iGPU) is analogous — a discrete GPU is the plausible
default there too. **This phase is the first case across L1–W1 where the requested
device diverges from the plausible default, and it is exactly the case that failed.**
Recommended as a explicit follow-up: re-verify at least one prior "successful"
selection (e.g. Windows RTX 3060) with this same kernel/OS-level independent
verification technique, now that its value has been demonstrated.

**Implications for the sections the brief asked to address**:
- **AMD integrated graphics**: not validated as a distinct case from AMD discrete —
  this phase could not get past the shared multi-GPU-selection blocker to test
  anything iGPU-specific (memory sharing, lower compute throughput, etc.).
- **Systems with multiple GPUs**: now the confirmed limiting case — any multi-adapter
  system where the desired GPU is *not* the plugin's own internal default cannot
  currently be reliably targeted at all, regardless of vendor or OS.
- **Systems without a dedicated GPU** (single-adapter laptops, e.g. many Windows/Intel
  or lower-end AMD-only machines): **unaffected by this specific finding** — with
  only one WebGPU-capable adapter present, "selects independently" and "the caller's
  only choice" are the same thing, so `select_device()`'s existing single-device
  auto-pick path (already proven correct on macOS M1) would very plausibly work fine.
  This phase's finding is specifically about **choosing among multiple GPUs**, not
  about integrated GPUs inherently.
- **Automatic device selection**: cannot currently be made safe/correct for
  multi-GPU systems where the non-default adapter is wanted — a real, practical
  blocker for any future STEMwerk feature that would let a user pick a specific GPU
  on such a system.
- **CPU fallback**: unaffected — the existing `webgpu_adapter.py` machinery still
  correctly detects and reports when the CPU path is used instead of any GPU; this
  finding is orthogonal to that mechanism.
- **Future Intel iGPU validation**: **not tested, not claimed** — this finding
  predicts that Intel iGPU selection would face the identical plugin-level obstacle
  on a multi-GPU Intel+discrete system, but says nothing about a single-Intel-iGPU
  system, and nothing about Intel hardware/driver correctness itself, since no Intel
  hardware was involved in reaching this conclusion at all.
- **No claim of Windows-AMD-iGPU behavior** is made from this Linux-only result, and
  no generalization to "AMD iGPUs never work with WebGPU" is made — the failure mode
  identified is specific to the plugin EP's current multi-adapter selection logic on
  this OS/API combination, not to the 780M silicon or its Vulkan driver, both of
  which enumerate and identify themselves correctly (§4).

## Deliverables — checkpoint table

| Checkpoint | MDX-Net | Demucs |
|---|---|---|
| Radeon 780M detected | **PASS** — correct PCI/vendor/device ID, cross-verified against `lspci`/`vulkaninfo`/`webgpu_adapter` | **PASS** — same adapter enumeration, model-independent |
| Correct GPU selected | **FAIL** — `select_device()` returns the correct object, but the underlying plugin EP does not honor it (documented limitation, §4) | **FAIL** — identical root cause |
| WebGPU session created | **PASS** (technically — a session was created and reported success) | **PASS** (same caveat) |
| Model loaded | **PASS** | **PASS** |
| Graph placement | **N/A — placement was on the RX 9070, not the requested 780M; the 185/1594-node "success" is not evidence about the 780M** | Same |
| CPU fallback | **PASS (0), but on the wrong GPU** — not a meaningful 780M result | Same |
| Real inference | **BLOCKED** — real inference occurred, but proven (kernel-level) to be on the RX 9070, not the 780M | **BLOCKED** — same |
| Numerical validation | **NOT TESTED** — no genuine 780M output exists to validate | **NOT TESTED** |
| Full audio pipeline | **NOT TESTED** | **NOT TESTED** |
| Performance | **NOT TESTED** (genuinely, not omitted — see §9) | **NOT TESTED** |
| Memory validation | **N/A** — preflight completed (§6) and found no blocking constraint, but this became moot once §4's blocker was established | Same preflight result applies |

## Code changes required

**None to fix the underlying issue** — no code change in `webgpu_adapter.py` can work
around a limitation the plugin EP itself documents as current behavior with no
override. One new, non-production file was added for this phase's own investigation:
a small (~50 line) independent kernel-level GPU-activity monitor
(`/tmp/l9_gpu_monitor.py`, reads `/sys/class/drm/card{N}/device/gpu_busy_percent` —
this is scratch/investigation tooling, kept outside the repository per the brief's
"large logs/caches outside Git" instruction, not committed).

## Recommendation for L10

1. **File or search for an upstream issue against `microsoft/onnxruntime`
   (`onnxruntime-ep-webgpu`)** describing this exact multi-adapter selection gap, with
   this phase's reproduction (two models, kernel-level evidence, exact README quote)
   as supporting material — this is a plugin-level limitation blocking a real,
   documented use case (STEMwerk's own "let a user pick which GPU to use" scenario),
   not something any downstream caller can work around.
2. **Re-verify at least one prior platform's device selection with this phase's
   kernel/OS-level independent-verification technique** (§10's methodological
   question) — Windows (`nvidia-smi`'s per-process/per-GPU query, or Task Manager's
   GPU engine view) is the most practical next target, since that machine also has
   two GPUs and the question ("was RTX 3060 selection genuine or coincidental") is
   directly answerable there with tooling already available (`nvidia-smi` was already
   used for VRAM sampling in W1).
3. **Track the upstream plugin EP's release notes** for a version that adds real
   multi-device selection support, and re-run this exact phase's test sequence
   against it when available — the moment device selection is honored, this phase's
   existing test scripts and the resource preflight (§6, already favorable) are
   sufficient to complete the 780M validation with no further design work.

Given (1) and (2) are both low-cost, high-value, and (3) is blocked on an external
release, **(2) is the most actionable next step available right now.**

## Git

- Starting HEAD: `c59c8e421` (L7). After Phase 0 sync: `2d1ed69d7` (W1).
- This phase's own commit (documentation only — no code changes, per "no code change
  can fix this" above): see repository log.
- Not pushed automatically, per instructions.
