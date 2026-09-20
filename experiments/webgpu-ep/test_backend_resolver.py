"""
Automated policy tests for backend_resolver.py -- Phase L11 Section 5.

These are POLICY tests: they exercise the resolver's decision logic against the
capability matrix's existing evidence (capability_matrix.py). Cases built on Windows
or macOS data (Apple M1, RTX 3060) verify the resolver's REASONING against evidence
already gathered in M1/L8/W1 -- they are NOT new hardware validation and must not be
reported as such (L11 brief, explicit instruction). Real, new hardware validation
happens separately in `l11_hardware_validation.py`, on this Linux/AMD machine only.

Plain assert-based, no pytest dependency (consistent with this experiment's existing
script style, and avoids adding a new dependency to any venv). Run directly:
    python test_backend_resolver.py
"""
import sys

from backend_resolver import GpuInfo, ResolveRequest, resolve

RX9070 = GpuInfo("AMD", "Radeon RX 9070", "0x7550", "0000:03:00.0")
R780M = GpuInfo("AMD", "Radeon 780M", "0x15bf", "0000:69:00.0")
M1 = GpuInfo("Apple", "Apple M1")
RTX3060 = GpuInfo("NVIDIA", "RTX 3060")
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
r = resolve(ResolveRequest(model_name="UVR_MDXNET_KARA_2.onnx", os_arch="linux",
                            available_gpus=(RX9070, R780M), desired_backend="WebGPU", explicit_gpu=R780M))
check("780M + MDX-Net (explicit, RX 9070 also present): isolation env is built and targets the 780M",
      r.status == "PASS" and r.required_process_isolation == {"VK_LOADER_DEVICE_ID_FILTER": "0x15bf"})

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
import dataclasses  # noqa: E402
import capability_matrix as cm  # noqa: E402

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

print(f"\n{_count - len(_failures)}/{_count} policy tests passed.")
if _failures:
    print("FAILED:", _failures)
    sys.exit(1)
sys.exit(0)
