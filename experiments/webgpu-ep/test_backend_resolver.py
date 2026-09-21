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

# 10. Multiple GPUs with the W5 native DXGI-LUID enforcement evidence.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060, GpuInfo("AMD", "AMD iGPU")), desired_backend="Auto",
                            windows_native_luid_selection_available=True))
check("W5 native Windows LUID enforcement lets Auto select the proven RTX row",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == RTX3060 and
      r.device_selection_enforceable is True)

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

# --- W5: Windows native DXGI-LUID selection regression tests ---------------------
# W2 proved the stock 0.3.0 plugin ignored its Windows device request. W5's isolated
# native build passes the selected hardware device's DXGI LUID to Dawn, verifies the
# returned adapter identity, and was physically validated in both directions. These
# policy tests capture the new evidence while retaining a stale-W2 negative control.

RTX3060_WIN = GpuInfo("NVIDIA", "RTX 3060 Laptop GPU")
AMD_IGPU_WIN = GpuInfo("AMD", "AMD Radeon(TM) Graphics", "0x1638", None)
INTEL_IGPU_WIN = GpuInfo("Intel", "Intel Iris Xe Graphics")

# W5a. Auto prefers the already Auto-suitable RTX row and may enforce that choice.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="Auto",
                            windows_native_luid_selection_available=True))
check("W5a Windows RTX3060+iGPU present, MDX-Net, Auto: enforced RTX PASS",
      r.status == "PASS" and r.selected_gpu == RTX3060_WIN and r.device_selection_enforceable is True)

# W5b. The matrix must distinguish the patched-build result from W2's stock-plugin
# failure and record the independently proven LUID selection.
win_rtx_mdx = cm.lookup("windows", "RTX 3060", "MDXNET")
check("W5b Windows RTX3060 MDX-Net matrix row: native LUID selection is PASS",
      win_rtx_mdx is not None and win_rtx_mdx.device_selection_enforceable.startswith("PASS") and
      "LUID 64318" in win_rtx_mdx.physical_gpu_verification)

# W5c. The reversed AMD request must be a positive physical AMD result, not session
# creation alone and not the old W2 RTX substitution.
win_igpu_mdx = cm.lookup("windows", "AMD Radeon(TM) Graphics", "MDXNET")
check("W5c Windows AMD iGPU MDX-Net row: correct, LUID-enforced, physically AMD",
      win_igpu_mdx is not None and win_igpu_mdx.found_correct is True and
      win_igpu_mdx.device_selection_enforceable.startswith("PASS") and
      "LUID 59967" in win_igpu_mdx.physical_gpu_verification)

# W5d. An explicit AMD request is allowed even though the row remains unsuitable for
# Auto pending repeated performance/stability characterization.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=AMD_IGPU_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True))
check("W5d Windows explicit AMD request: enforced WebGPU PASS with no substitution",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == AMD_IGPU_WIN and
      r.device_selection_enforceable is True)

# W5e. The opposite explicit direction is also enforceable.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=RTX3060_WIN,
                            windows_native_luid_selection_available=True))
check("W5e Windows explicit RTX3060 request: enforced WebGPU PASS",
      r.status == "PASS" and r.selected_gpu == RTX3060_WIN and r.device_selection_enforceable is True)

# W2f. Unknown iGPU capability: a different, never-tested Windows iGPU vendor
# (Intel) must resolve UNKNOWN, not PASS -- no evidence exists for it at all.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(INTEL_IGPU_WIN,), desired_backend="Auto"))
check("W2f Unknown Windows Intel iGPU: status is UNKNOWN, not PASS", r.status == "UNKNOWN")

# W5g. AMD is correct but intentionally not Auto-suitable from a single timing run.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(AMD_IGPU_WIN,), desired_backend="Auto"))
check("W5g Windows AMD iGPU alone, Auto: UNKNOWN/not WebGPU pending Auto qualification",
      r.status == "UNKNOWN" and r.selected_backend != "WebGPU")

# W5h. Regress the old W2 evidence explicitly: without a PASS/LUID matrix verdict,
# Windows multi-GPU selection must still fail closed.
stale_windows_matrix = tuple(
    dataclasses.replace(e, device_selection_enforceable="DISPROVEN (W2 stock plugin)")
    if "windows" in e.os_arch.lower() and "RTX 3060" in e.gpu_model and "MDXNET" in e.model_name
    else dataclasses.replace(e, found_correct=False, suitable_for_auto=False,
                             device_selection_enforceable="FAIL (W2 stock plugin)")
    if "windows" in e.os_arch.lower() and "AMD Radeon(TM) Graphics" in e.gpu_model
       and "MDXNET" in e.model_name
    else e
    for e in cm.MATRIX
)
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=RTX3060_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True,
                            capability_matrix=stale_windows_matrix))
check("W5h stale W2 stock-plugin evidence remains fail-closed",
      r.status == "BLOCKED" and r.selected_backend is None and r.selected_gpu is None)

# W5i. A matching matrix row is not enough: the caller must also prove that the
# actually loaded runtime has the native LUID patch/fix rather than stock 0.3.0.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RTX3060_WIN, AMD_IGPU_WIN), desired_backend="WebGPU",
                            explicit_gpu=RTX3060_WIN, allow_fallback=False))
check("W5i Windows LUID capability absent at runtime remains fail-closed",
      r.status == "BLOCKED" and r.selected_backend is None and r.selected_gpu is None)

# --- AW: AMD Windows workstation validation integration -----------------------------
# Policy assertions for the matrix rows added from validate/webgpu-amd-windows
# @ 4ca1fcf68 (full report: AMD_WINDOWS_VALIDATION_REPORT.md; distinct physical
# devices from the W5 laptop rows: RX 9070 0x744c/LUID 87436, Phoenix 780M
# 0x15bf/LUID 96109, Windows 11 Pro 26200). POLICY tests against recorded
# evidence -- not new hardware validation.

RX9070_WIN = GpuInfo("AMD", "Radeon RX 9070", "0x744c", None)
R780M_WIN = GpuInfo("AMD", "Radeon 780M (iGPU, Phoenix)", "0x15bf", None)

# AWa. RX 9070 MDX-Net: actually tested, correct, LUID-enforced, physically verified,
# and now Auto-suitable (repeated warm benchmarks, 3.4x vs CPU).
win_rx_mdx = cm.lookup("windows", "Radeon RX 9070", "MDXNET")
check("AWa Windows RX 9070 MDX-Net row: tested + correct + LUID-enforced + suitable_for_auto",
      win_rx_mdx is not None and win_rx_mdx.actually_tested is True and
      win_rx_mdx.found_correct is True and win_rx_mdx.suitable_for_auto is True and
      win_rx_mdx.device_selection_enforceable.startswith("PASS") and
      "LUID 87436" in win_rx_mdx.physical_gpu_verification and
      "185/185" in win_rx_mdx.graph_placement)

# AWb. Auto with both workstation GPUs prefers the Auto-suitable RX 9070 and enforces it.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RX9070_WIN, R780M_WIN), desired_backend="Auto",
                            windows_native_luid_selection_available=True))
check("AWb RX 9070 + 780M present, MDX-Net, Auto: enforced RX 9070 WebGPU PASS",
      r.status == "PASS" and r.selected_backend == "WebGPU" and r.selected_gpu == RX9070_WIN and
      r.device_selection_enforceable is True)

# AWc. 780M MDX-Net: correct and LUID-enforced, but deliberately NOT Auto-suitable
# (only n=2 uncontended warm samples; same conservative iGPU policy as W5's laptop row).
win_780m_mdx = cm.lookup("windows", "Radeon 780M", "MDXNET")
check("AWc Windows 780M MDX-Net row: correct + LUID-enforced, NOT suitable_for_auto",
      win_780m_mdx is not None and win_780m_mdx.found_correct is True and
      win_780m_mdx.suitable_for_auto is False and
      "LUID 96109" in win_780m_mdx.physical_gpu_verification)

# AWd. Bare Auto with only the 780M must not promote it to WebGPU.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(R780M_WIN,), desired_backend="Auto"))
check("AWd Windows 780M alone, MDX-Net, Auto: UNKNOWN/not WebGPU (not Auto-qualified)",
      r.status == "UNKNOWN" and r.selected_backend != "WebGPU")

# AWe. RX 9070 Demucs: correct, ORT_ENABLE_BASIC retained, faster than CPU,
# Auto-suitable -- with the WAV clipping caveat explicitly recorded (not an
# unqualified audio PASS, and symmetric across providers by the recorded evidence).
win_rx_demucs = cm.lookup("windows", "Radeon RX 9070", "htdemucs")
check("AWe Windows RX 9070 Demucs row: 1594/1594 + ORT_ENABLE_BASIC + suitable_for_auto + clipping caveat disclosed",
      win_rx_demucs is not None and win_rx_demucs.found_correct is True and
      win_rx_demucs.suitable_for_auto is True and
      "1594/1594" in win_rx_demucs.graph_placement and
      "ORT_ENABLE_BASIC" in win_rx_demucs.inference_backend and
      "CAVEAT" in win_rx_demucs.end_to_end_audio_correctness.upper() and
      "1.363" in win_rx_demucs.end_to_end_audio_correctness)

# AWf. Windows 780M Demucs was NOT TESTED: no matrix row, explicit request is UNKNOWN,
# never a silent PASS, and compatibility must not be inferred from the RX 9070 row.
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="windows",
                            available_gpus=(R780M_WIN,), desired_backend="WebGPU",
                            explicit_gpu=R780M_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True))
check("AWf Windows 780M Demucs explicit WebGPU: UNKNOWN (not tested), no silent PASS",
      r.status == "UNKNOWN" and r.selected_backend is None and r.selected_gpu is None)

# AWg. Regression guard: Linux 780M Demucs (VK_ERROR_DEVICE_LOST crash row) must
# remain blocked from Auto.
linux_780m_demucs = cm.lookup("linux", "Radeon 780M", "htdemucs")
check("AWg Linux 780M Demucs remains blocked from Auto (regression guard)",
      linux_780m_demucs is not None and linux_780m_demucs.suitable_for_auto is False and
      linux_780m_demucs.found_correct is False)

# AWh. Stale-evidence negative control for the new row: regress the RX 9070 MDX row to
# a W2-style stock-plugin verdict and demand fail-closed, exactly as W5h does for the
# laptop rows.
stale_amd_matrix = tuple(
    dataclasses.replace(e, found_correct=False, suitable_for_auto=False,
                        device_selection_enforceable="DISPROVEN (W2 stock plugin)")
    if "windows" in e.os_arch.lower() and "Radeon RX 9070" in e.gpu_model and "MDXNET" in e.model_name
    else e
    for e in cm.MATRIX
)
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RX9070_WIN,), desired_backend="WebGPU",
                            explicit_gpu=RX9070_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True,
                            capability_matrix=stale_amd_matrix))
check("AWh stale stock-plugin RX 9070 evidence remains fail-closed",
      r.status == "BLOCKED" and r.selected_backend is None and r.selected_gpu is None)

# AWi. Clipping-visibility invariant: suitable_for_auto=True must NOT read as
# unconditional end-to-end audio correctness. The RX 9070 Demucs row's WAV clipping
# caveat (float drums peak 1.363, symmetric CPU/WebGPU) must be visible in the
# resolver decision output itself, on both the explicit and Auto/direct paths.
r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="windows",
                            available_gpus=(RX9070_WIN,), desired_backend="WebGPU",
                            explicit_gpu=RX9070_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True))
check("AWi explicit RX 9070 Demucs: PASS and clipping caveat visible in suitability",
      r.status == "PASS" and r.selected_backend == "WebGPU" and
      "Suitable for Auto" in r.model_gpu_suitability and
      "audio-output:" in r.model_gpu_suitability and "1.363" in r.model_gpu_suitability)

r = resolve(ResolveRequest(model_name="htdemucs.onnx", os_arch="windows",
                            available_gpus=(RX9070_WIN,), desired_backend="Auto",
                            windows_native_luid_selection_available=True))
check("AWj Auto RX 9070 Demucs: PASS and clipping caveat visible in suitability",
      r.status == "PASS" and r.selected_backend == "WebGPU" and
      "audio-output:" in r.model_gpu_suitability and "1.363" in r.model_gpu_suitability)

# AWk. No-noise control: a row with an unqualified PASS must NOT gain an audio note.
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="windows",
                            available_gpus=(RX9070_WIN,), desired_backend="WebGPU",
                            explicit_gpu=RX9070_WIN, allow_fallback=False,
                            windows_native_luid_selection_available=True))
check("AWk explicit RX 9070 MDX-Net (clean PASS row): no audio caveat suffix",
      r.status == "PASS" and "audio-output:" not in r.model_gpu_suitability)

print(f"\n{_count - len(_failures)}/{_count} policy tests passed"
      f"{f' ({len(_skipped)} skipped, non-Linux host -- see ON_LINUX above)' if _skipped else ''}.")
if _skipped:
    print("SKIPPED:", _skipped)
if _failures:
    print("FAILED:", _failures)
    sys.exit(1)
sys.exit(0)
