"""
Automated policy tests for backend_resolver.py -- Phase L11 Section 5.

These are POLICY tests: they exercise the resolver's decision logic against the
capability matrix's existing evidence (capability_matrix.py). Cases built on Windows
or macOS data (Apple M1, RTX 3060) verify the resolver's REASONING against evidence
already gathered in M1/L8/W1 -- they are NOT new hardware validation and must not be
reported as such (L11 brief, explicit instruction). Real, new hardware validation
happens separately in `l11_hardware_validation.py`, on this Linux/AMD machine only.
The N1 Linux RTX cases added during controlled integration likewise assert policy and
the preserved machine-readable N1 facts; they do not claim to rerun the GPU benchmark.

Plain assert-based, no pytest dependency (consistent with this experiment's existing
script style, and avoids adding a new dependency to any venv). Run directly:
    python test_backend_resolver.py
"""
import dataclasses
import sys

from backend_resolver import GpuInfo, ResolveRequest, resolve
import capability_matrix as cm

RX9070 = GpuInfo("AMD", "Radeon RX 9070", "0x7550", "0000:03:00.0")
R780M = GpuInfo("AMD", "Radeon 780M", "0x15bf", "0000:69:00.0")
M1 = GpuInfo("Apple", "Apple M1")
RTX3060 = GpuInfo("NVIDIA", "RTX 3060")
RTX3060_LINUX = GpuInfo("NVIDIA", "RTX 3060", "0x2520", "0000:01:00.0")
RENOIR = GpuInfo("AMD", "Renoir iGPU", "0x1636", "0000:06:00.0")
INTEL_UNKNOWN = GpuInfo("Intel", "Intel Arc A770")
NONEXISTENT = GpuInfo("NVIDIA", "RTX 4090")

_failures = []
_count = 0


def check(label, condition, detail=""):
    global _count
    _count += 1
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" -- {detail}" if detail and not condition else ""))
    if not condition:
        _failures.append(label)


# Genuine, previously-undetected finding from running this suite on Windows for the
# first time (W2): a FEW specific cases below simulate a Linux scenario purely via
# `os_arch="linux"` (the string backend_resolver.py's own docstring says drives its
# policy logic, deliberately host-independent per this file's own module docstring
# -- "verify the resolver's REASONING ... NOT new hardware validation"). But those
# specific cases also exercise linux_vulkan_isolation.build_isolation_plan(), which
# has its OWN, stricter, real `sys.platform` check (by design -- it must never
# fabricate a real VK_LOADER_DEVICE_ID_FILTER env-var plan on a host where that
# mechanism cannot possibly apply). The two checks disagree when the actual test
# runner isn't Linux: `_isolation_for()`'s "is this a Linux scenario" branch fires
# (os_arch says so), but `build_isolation_plan()` then correctly refuses (sys.platform
# says otherwise) and raises. This is not a Windows-specific resolver bug -- it is a
# real fact about this test file that no prior phase (all run on the Linux dev
# machine) had occasion to notice. Skipped (not silently passed, not miscounted as a
# failure) on any non-Linux host, with this reasoning printed; unaffected everywhere
# else in this file, and unaffected on Linux.
ON_LINUX = sys.platform.startswith("linux")


_skipped = []


def check_linux_isolation_plan(label, fn):
    """Runs `fn()` (which calls resolve() with a >1-GPU Linux isolation scenario) only
    on a real Linux host; otherwise records an explicit SKIP (tracked separately from
    both pass and fail counts) so the final summary stays honest rather than silently
    dropping the case or miscounting it as a pass."""
    if not ON_LINUX:
        _skipped.append(label)
        print(f"[SKIP] {label} -- requires a real Linux host to build a genuine "
              f"VK_LOADER_DEVICE_ID_FILTER plan (linux_vulkan_isolation.py's own "
              f"sys.platform check, by design); this run's host is {sys.platform!r}. "
              f"See the module-level comment above ON_LINUX.")
        return
    check(label, fn())


# 1. RX 9070 + MDX-Net -- known-good, single GPU
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="Auto"))
check("RX 9070 + MDX-Net: Auto selects WebGPU on the RX 9070",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == RX9070)

# 2. RX 9070 + Demucs -- known-good
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="Auto"))
check("RX 9070 + Demucs: Auto selects WebGPU on the RX 9070",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == RX9070)

# 3. Radeon 780M + MDX-Net -- proven-good via isolation, single GPU present
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(R780M,), desired_backend="Auto"))
check("780M + MDX-Net (alone): Auto selects WebGPU on the 780M",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == R780M)

# 3b. Radeon 780M + MDX-Net, with RX 9070 ALSO present -- isolation plan must be built
def _t3b():
    r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                                available_gpus=(RX9070, R780M), desired_backend="WebGPU", explicit_gpu=R780M))
    return r.status == "PASS" and r.required_process_isolation == {"VK_LOADER_DEVICE_ID_FILTER": "0x15bf"}
check_linux_isolation_plan("780M + MDX-Net (explicit, RX 9070 also present): isolation env is built and targets the 780M", _t3b)

# 4. Radeon 780M + Demucs -- WebGPU Auto MUST be refused (the required test, verbatim from the brief)
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="linux",
                            available_gpus=(R780M,), desired_backend="Auto"))
check("780M + Demucs: Auto REFUSES WebGPU (BLOCKED, not PASS)",
      r.status == "BLOCKED" and r.selected_backend != "WebGPU")
# Also: explicit request must not silently execute a known-crashing combination either.
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="linux",
                            available_gpus=(RX9070, R780M), desired_backend="WebGPU", explicit_gpu=R780M))
check("780M + Demucs: explicit WebGPU request is ALSO BLOCKED, and does not silently swap to the RX 9070",
      r.status == "BLOCKED" and r.selected_gpu is None)

# 5. Apple M1 + Demucs -- known MPS performance advantage must be preserved (Auto prefers vendor)
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="macos",
                            available_gpus=(M1,), desired_backend="Auto"))
check("Apple M1 + Demucs: Auto prefers the existing PyTorch/MPS route over WebGPU",
      r.status == "PASS" and r.selected_backend is not None and r.selected_backend.startswith("Vendor:"))

# 6. RTX 3060 + Demucs -- known CUDA performance advantage must be preserved
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="windows",
                            available_gpus=(RTX3060,), desired_backend="Auto"))
check("RTX 3060 + Demucs: Auto prefers the existing PyTorch/CUDA route over WebGPU",
      r.status == "PASS" and r.selected_backend is not None and r.selected_backend.startswith("Vendor:"))

# 6b. N1 Linux/Vulkan RTX 3060 + MDX-Net -- physically proven and faster than CPU.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(RTX3060_LINUX,), desired_backend="Auto"))
check("Linux RTX 3060 + MDX-Net: Auto selects the separately tested Vulkan/WebGPU row",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == RTX3060_LINUX)

# 6c. N1 did not prove that its ordinary PCI selector caused the RTX choice. When a
# second GPU is present, the resolver therefore relies on L10's separate, proven
# Vulkan-Loader isolation mechanism rather than treating nvidia-smi as causal proof.
def _t6c():
    r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                                available_gpus=(RTX3060_LINUX, RENOIR), desired_backend="WebGPU",
                                explicit_gpu=RTX3060_LINUX))
    return r.status == "PASS" and r.required_process_isolation == {"VK_LOADER_DEVICE_ID_FILTER": "0x2520"}
check_linux_isolation_plan("Linux RTX 3060 + MDX-Net (dual GPU): explicit selection uses L10 loader isolation", _t6c)

# 6d/e. N1 Linux/Vulkan RTX 3060 + Demucs is correct and faster than ONNX CPU, so an
# explicit single-GPU WebGPU request can succeed; Auto must still keep the established
# ~5.9x-faster PyTorch/CUDA production route.
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="linux",
                            available_gpus=(RTX3060_LINUX,), desired_backend="WebGPU",
                            explicit_gpu=RTX3060_LINUX))
check("Linux RTX 3060 + Demucs: explicit WebGPU remains available from N1 evidence",
      r.status == "PASS" and r.selected_backend == "WebGPU")
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="linux",
                            available_gpus=(RTX3060_LINUX,), desired_backend="Auto"))
check("Linux RTX 3060 + Demucs: Auto preserves the proven faster PyTorch/CUDA route",
      r.status == "PASS" and r.selected_backend == "Vendor:PyTorch/CUDA")

# 6f. Linux/Vulkan and Windows/D3D12 are distinct matrix rows, not one NVIDIA result.
linux_entry = cm.lookup("linux", "RTX 3060", "MDXNET")
windows_entry = cm.lookup("windows", "RTX 3060", "MDXNET")
check("RTX 3060 Linux/Vulkan evidence is distinct from Windows/D3D12 evidence",
      linux_entry is not None and windows_entry is not None and linux_entry is not windows_entry and
      "Vulkan" in linux_entry.underlying_graphics_backend and
      "D3D12" in windows_entry.underlying_graphics_backend)
linux_demucs = cm.lookup("linux", "RTX 3060", "htdemucs")
check("Linux RTX 3060 evidence separates physical execution from selector enforcement",
      linux_entry is not None and linux_demucs is not None and
      linux_entry.model_sha256 == "bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4" and
      "185/185" in linux_entry.graph_placement and "NOT PROVED BY N1" in linux_entry.device_selection_enforceable and
      "1594/1594" in linux_demucs.graph_placement and "ORT_ENABLE_BASIC" in linux_demucs.inference_backend and
      "5.9x" in linux_demucs.practical_performance and
      "NOT PROVED BY N1" in linux_demucs.device_selection_enforceable)

# 7. Unknown Intel GPU -- no evidence exists; must not claim success
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(INTEL_UNKNOWN,), desired_backend="Auto"))
check("Unknown Intel GPU: status is UNKNOWN, not PASS", r.status == "UNKNOWN")

# 8. Unknown ONNX model -- no evidence exists for this model at all
r = resolve(ResolveRequest(model_name="some_new_model.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="Auto"))
check("Unknown ONNX model: status is UNKNOWN, not PASS", r.status == "UNKNOWN")

# 9. Nonexistent GPU (explicit request for hardware not present)
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="WebGPU", explicit_gpu=NONEXISTENT))
check("Nonexistent GPU: status is FAIL, no substitute silently selected",
      r.status == "FAIL" and r.selected_gpu is None)

# 10. Multiple GPUs without reliable/enforceable selection (Windows: no proven isolation mechanism)
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060, GpuInfo("AMD", "AMD iGPU")), desired_backend="Auto"))
check("Multiple GPUs, no enforceable selection on Windows: BLOCKED, not a guessed PASS",
      r.status == "BLOCKED" and r.selected_gpu is None)

# 11. EP missing at runtime
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="WebGPU", webgpu_ep_available=False))
check("WebGPU EP missing at runtime: FAIL, explicit request not silently downgraded to a false PASS",
      r.status == "FAIL")

# 12a. CPU fallback allowed, on a combination with no evidence
r = resolve(ResolveRequest(model_name="unknown.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="Auto", allow_fallback=True))
check("CPU fallback allowed: resolver falls back to CPU", r.selected_backend == "CPU")

# 12b. CPU fallback forbidden, same combination
r = resolve(ResolveRequest(model_name="unknown.onnx", os_arch="linux",
                            available_gpus=(RX9070,), desired_backend="Auto", allow_fallback=False))
check("CPU fallback forbidden: resolver selects nothing rather than silently falling back",
      r.selected_backend is None)

# 13. Contradictory/outdated capability evidence -- caller passes a stale matrix where the
#     780M+Demucs entry has been (incorrectly) marked found_correct=True; the resolver must
#     still respect device_selection_enforceable / whatever the (bad) evidence says, since
#     its job is to apply evidence, not silently re-verify it -- this test instead confirms
#     that swapping in *different* capability_matrix evidence actually changes the resolver's
#     decision (proving the resolver reads its evidence parameter and doesn't hardcode
#     conclusions), which is the actual risk "contradictory/outdated evidence" tests for.
_orig_780m_mdxnet = cm.lookup("linux", "780M", "MDXNET")
assert _orig_780m_mdxnet is not None, "matrix lookup itself is broken -- fix before trusting this test"
_stale_entry = dataclasses.replace(
    _orig_780m_mdxnet,
    found_correct=False, suitable_for_auto=False, stability="BLOCKED -- stale synthetic test evidence",
)
_stale_matrix = tuple(e for e in cm.MATRIX if e is not _orig_780m_mdxnet) + (_stale_entry,)
r_live = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                                 available_gpus=(R780M,), desired_backend="Auto"))
r_stale = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                                  available_gpus=(R780M,), desired_backend="Auto",
                                  capability_matrix=_stale_matrix))
check("Resolver decision changes when the evidence it's given changes (not hardcoded)",
      r_live.status == "PASS" and r_stale.status == "BLOCKED")

# --- W2: Windows multi-GPU physical-selection-enforcement tests -----------------
# Phase W2 (WINDOWS_MULTI_GPU_SELECTION.md) ran the decisive reversed-selection test
# this project's own L9/L10 recommended: on a real Windows/D3D12 laptop with an
# NVIDIA RTX 3060 (discrete) + an AMD Radeon iGPU, an explicit request for the AMD
# iGPU still executed on the RTX 3060 -- independently confirmed via OS-level GPU
# Engine performance counters (keyed to DXGI adapter LUID) and nvidia-smi whole-GPU
# utilization, in two separate fresh processes. This directly disproves W1's
# unverified assumption that the RTX 3060 selection in W1 was caused by the request
# rather than coinciding with Dawn's own high-performance-adapter default. These
# tests assert the resolver's policy correctly reflects that finding: never PASS an
# explicit Windows multi-GPU selection, and never silently substitute a different
# physical GPU than what was asked for.

RTX3060_WIN = GpuInfo("NVIDIA", "RTX 3060 Laptop GPU")
AMD_IGPU_WIN = GpuInfo("AMD", "AMD Radeon(TM) Graphics", "0x1638", None)
INTEL_IGPU_WIN = GpuInfo("Intel", "Intel Iris Xe Graphics")

# W2a. Windows multi-GPU selection: with two real GPUs present and no Linux-style
# isolation mechanism available (W2's Section 7 finding), Auto must NOT claim a
# WebGPU PASS on this model even though the RTX 3060 alone is otherwise a proven,
# suitable_for_auto candidate -- selection cannot be safely enforced with a second
# GPU in the picture, so the resolver falls back rather than guessing (mirrors the
# pre-existing test #10, restated here with the real W2-derived GpuInfo objects and
# explicit reference to the finding that produced this policy).
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="Auto"))
check("W2a Windows RTX3060+iGPU present, MDX-Net, Auto: BLOCKED, no enforced-selection PASS claimed",
      r.status == "BLOCKED" and r.selected_gpu is None and r.device_selection_enforceable is False)

# W2b. Physical-GPU-proof vs. claimed-selection distinction: the capability matrix
# itself must record W1's Windows RTX 3060 rows as DISPROVEN/not-enforced (not a
# bare "PASS"), now that W2 has actual reversed-selection evidence -- guards against
# ever re-collapsing "GPU executed" and "selector caused it" back into one claim.
win_rtx_mdx = cm.lookup("windows", "RTX 3060", "MDXNET")
check("W2b Windows RTX3060 MDX-Net matrix row: device_selection_enforceable is DISPROVEN, not PASS/UNKNOWN",
      win_rtx_mdx is not None and "DISPROVEN" in win_rtx_mdx.device_selection_enforceable)

# W2c. Requested GPU differing from observed GPU: the new Windows AMD iGPU matrix
# row itself must record found_correct=False and a FAIL selector verdict -- this is
# the "requested != observed" case the brief asked for, backed by the real W2 result
# (RTX 3060 executed despite the iGPU being requested), not a hypothetical.
win_igpu_mdx = cm.lookup("windows", "AMD Radeon(TM) Graphics", "MDXNET")
check("W2c Windows AMD iGPU MDX-Net matrix row: found_correct is False and selector verdict is FAIL",
      win_igpu_mdx is not None and win_igpu_mdx.found_correct is False and
      "FAIL" in win_igpu_mdx.device_selection_enforceable and
      "RTX 3060" in win_igpu_mdx.physical_gpu_verification)

# W2d. Explicit GPU request failing closed: an explicit request for the Windows AMD
# iGPU (the disproven combination) must be refused outright (BLOCKED), and with
# fallback disabled must select nothing -- never silently rerouted to the RTX 3060
# that W2 showed actually executes instead.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=AMD_IGPU_WIN, allow_fallback=False))
check("W2d Windows explicit iGPU request fails closed: BLOCKED, no fallback, no silent RTX 3060 substitution",
      r.status == "BLOCKED" and r.selected_backend is None and r.selected_gpu is None)

# W2e. No-safe-isolation-mechanism case, explicit RTX 3060 request this time (the
# GPU that DID physically execute in W1/W2): even the "right" GPU on a multi-GPU
# Windows system cannot be marked as an ENFORCED selection, because W2 proved this
# platform has no mechanism to guarantee the opposite outcome either -- the matrix's
# own DISPROVEN verdict (W2b) means backend_resolver.py must still refuse to promise
# enforcement even for a request that happens to match what actually ran.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=RTX3060_WIN))
check("W2e Windows explicit RTX3060 request (2 GPUs present): still BLOCKED, no enforcement promised",
      r.status == "BLOCKED" and r.selected_gpu is None)

# W2f. Unknown iGPU capability: a different, never-tested Windows iGPU vendor
# (Intel) must resolve UNKNOWN, not PASS -- no evidence exists for it at all.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(INTEL_IGPU_WIN,), desired_backend="Auto"))
check("W2f Unknown Windows Intel iGPU: status is UNKNOWN, not PASS", r.status == "UNKNOWN")

# W2g. Correct handling of DISPROVEN iGPU evidence (the "if obtained" case from the
# brief -- W2 obtained real evidence, but it disproves rather than validates iGPU
# execution): Auto with ONLY the AMD iGPU present (no RTX 3060 to fall back to
# in the available_gpus list) must still refuse WebGPU as BLOCKED, distinguishing
# "known bad" from "no evidence" (UNKNOWN) -- this is a genuinely different failure
# reason than the Radeon 780M/Linux BLOCKED case (device-loss crash) or the Windows
# multi-GPU-present case (W2a/e, unenforceable selection): here it is disproven
# physical correctness for this GPU specifically.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(AMD_IGPU_WIN,), desired_backend="Auto"))
check("W2g Windows AMD iGPU alone, Auto: BLOCKED (disproven-correct), not silently PASS",
      r.status == "BLOCKED" and r.selected_backend != "WebGPU")

print(f"\n{_count - len(_failures)}/{_count} policy tests passed"
      f"{f' ({len(_skipped)} skipped, non-Linux host -- see ON_LINUX above)' if _skipped else ''}.")
if _skipped:
    print("SKIPPED:", _skipped)
if _failures:
    print("FAILED:", _failures)
    sys.exit(1)
sys.exit(0)
