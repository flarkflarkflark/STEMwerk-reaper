"""
Minimal, explicit WebGPU EP adapter for the audio-separator MDX pipeline.

Injection point (see README.md section 2 for the full pipeline trace):
    audio_separator.separator.architectures.mdx_separator.MDXSeparator.load_model()
    creates `self.model_run = lambda spek: ort_inference_session.run(...)` via
    `ort.InferenceSession(self.model_path, providers=self.onnx_execution_provider, ...)`.
    This is the ONLY place ONNX Runtime is invoked in the whole pipeline -- STFT/iSTFT
    (uvr_lib_v5/stft.py) run via plain torch (torch.stft/torch.istft) on
    `self.torch_device`, completely independent of `onnx_execution_provider`. On this
    machine `torch_device` is CPU in both the CPU-EP and WebGPU-EP runs (this venv's
    torch has no CUDA/ROCm build), so STFT/windowing/overlap-add is byte-identical
    between the two runs -- only the neural-net inference call differs.

This module does NOT modify the installed audio-separator package. It works by
monkeypatching `onnxruntime.InferenceSession` at the Python level, which is picked up
transparently by `mdx_separator.py`'s `import onnxruntime as ort; ort.InferenceSession(...)`
call, since both names reference the same module object.

Design goals (per Phase L2 brief):
  - Explicitly check the actual (not just requested) provider list.
  - Select a specific GPU device deliberately -- this machine has two WebGPU-capable
    adapters (RX 9070 discrete + Phoenix iGPU); nothing defaults to the "right" one.
  - Distinguish "available" from "actually used": capture onnxruntime's own verbose
    C++ log (which is written directly to the process's stderr fd, bypassing Python's
    logging module entirely -- so this redirects fd 2, not logging.disable()) and
    parse the real per-node placement line.
  - Raise loudly (not warn) when GPU execution was required but not achieved.
  - Never touch model inputs/outputs.
  - Keep the Linux/Vulkan/PCI-bus-id specifics isolated behind one function so a
    macOS/Metal port only needs to replace `select_device()`.
"""
import contextlib
import ctypes
import os
import re
import tempfile

import onnxruntime as ort
import onnxruntime_ep_webgpu as webgpu_ep

# Captured once, at import time, before anything in this process has a chance to
# monkeypatch onnxruntime.InferenceSession -- this is the class every code path in
# this module actually constructs, regardless of what `ort.InferenceSession` is
# later reassigned to by patch_inference_session_for_provider_swap().
_ORIGINAL_INFERENCE_SESSION_CLASS = ort.InferenceSession

_LIBRARY_REGISTERED = False
_REGISTRATION_KEY = "webgpu"


class GpuExecutionNotProvenError(RuntimeError):
    """Raised when WebGPU execution was required but onnxruntime's own logs don't prove it."""


def ensure_webgpu_library_registered():
    global _LIBRARY_REGISTERED
    if not _LIBRARY_REGISTERED:
        ort.register_execution_provider_library(_REGISTRATION_KEY, webgpu_ep.get_library_path())
        _LIBRARY_REGISTERED = True


def list_webgpu_devices():
    """All WebGPU-capable adapters onnxruntime's plugin EP can see, available or not."""
    ensure_webgpu_library_registered()
    return [d for d in ort.get_ep_devices() if d.ep_name == webgpu_ep.get_ep_name()]


def select_device(pci_bus_id=None, device_id=None):
    """
    Linux/Vulkan device selection. Matches by PCI bus id (preferred, cross-checkable
    against `lspci -nn`) or numeric PCI device id.

    macOS/Metal port note: neither `pci_bus_id` nor `device_id` metadata exists for
    Apple Silicon's integrated GPU under Dawn/Metal. A macOS variant of this function
    would need to match on a different key (e.g. `ep_metadata`/`device` name string,
    or simply take the single available device since Apple Silicon has one GPU) --
    everything else in this module (registration, session patching, log verification)
    is platform-generic and should not need changes.
    """
    devices = list_webgpu_devices()
    if not devices:
        raise GpuExecutionNotProvenError("No WebGPU EP devices found at all -- EP not available on this system.")
    if pci_bus_id is not None:
        for d in devices:
            if d.device.metadata.get("pci_bus_id") == pci_bus_id:
                return d
        raise GpuExecutionNotProvenError(f"No WebGPU device with pci_bus_id={pci_bus_id!r}. Found: "
                                          f"{[dict(d.device.metadata) for d in devices]}")
    if device_id is not None:
        for d in devices:
            if d.device.device_id == device_id:
                return d
        raise GpuExecutionNotProvenError(f"No WebGPU device with device_id={device_id!r}.")
    if len(devices) > 1:
        raise GpuExecutionNotProvenError(
            f"{len(devices)} WebGPU devices found and no selector given -- refusing to guess. "
            f"Pass pci_bus_id or device_id explicitly. Found: {[dict(d.device.metadata) for d in devices]}"
        )
    return devices[0]


@contextlib.contextmanager
def _capture_stderr_fd():
    """
    Redirects the process's real fd 2 (not sys.stderr, not Python logging) to a temp
    file and yields its path. Needed because onnxruntime's C++ core writes verbose
    logs directly to the OS-level stderr file descriptor, bypassing anything set up
    through Python's `logging` module.
    """
    tmp = tempfile.NamedTemporaryFile(mode="w+", suffix=".ortlog", delete=False)
    saved_fd = os.dup(2)
    try:
        os.dup2(tmp.fileno(), 2)
        yield tmp.name
    finally:
        libc = ctypes.CDLL(None)
        libc.fflush(None)
        os.dup2(saved_fd, 2)
        os.close(saved_fd)
        tmp.close()


_NODE_PLACEMENT_RE = re.compile(r"All nodes placed on \[(?P<ep>[^\]]+)\]\. Number of nodes: (?P<n>\d+)")
_FALLBACK_HINTS = ("kernel not found in registries", "not supported", "falls back", "fallback")


def _parse_placement_log(log_text, session_providers):
    """Shared log-parsing/verification logic used by both the standalone and patched paths."""
    placement_match = _NODE_PLACEMENT_RE.search(log_text)
    fallback_hits = [line for line in log_text.splitlines() if any(h in line for h in _FALLBACK_HINTS)]

    report = {
        "requested_ep": webgpu_ep.get_ep_name(),
        "session_providers": session_providers,
        "log_bytes_captured": len(log_text),
        "all_nodes_placed_line": placement_match.group(0) if placement_match else None,
        "all_nodes_ep": placement_match.group("ep") if placement_match else None,
        "all_nodes_count": int(placement_match.group("n")) if placement_match else None,
        "fallback_related_lines": fallback_hits,
    }

    if webgpu_ep.get_ep_name() not in session_providers:
        raise GpuExecutionNotProvenError(
            f"WebGpuExecutionProvider not in session.get_providers() ({session_providers}) "
            f"-- session silently fell back. Fallback-related log lines: {fallback_hits}"
        )
    if placement_match is None:
        raise GpuExecutionNotProvenError(
            "onnxruntime's verbose log did not contain an 'All nodes placed on [...]' line -- "
            "cannot prove any node actually ran on WebGPU (this can happen with mixed "
            "CPU/GPU placement, which prints a per-node table instead of the single-EP "
            "summary line; report['session_providers'] and the raw log should be inspected "
            "manually in that case)."
        )
    if placement_match.group("ep") != webgpu_ep.get_ep_name():
        raise GpuExecutionNotProvenError(f"All nodes were placed on {placement_match.group('ep')!r}, not WebGPU.")

    return report


def create_verified_webgpu_session(model_path, device, extra_options=None):
    """
    Standalone entry point: creates a plain InferenceSession (always of the true
    original onnxruntime class, regardless of whether patching is active elsewhere)
    pinned to `device`, and returns (session, placement_report).

    Raises GpuExecutionNotProvenError if onnxruntime's own log doesn't show an
    unambiguous "All nodes placed on [WebGpuExecutionProvider]" line -- a provider
    appearing in get_providers()/get_available_providers() is NOT accepted as proof
    on its own (that only proves the EP loaded, not that it executed any node).
    """
    so = ort.SessionOptions()
    so.log_severity_level = 0  # verbose -- required to emit the node-placement line
    so.add_provider_for_devices([device], extra_options or {})

    with _capture_stderr_fd() as log_path:
        session = _ORIGINAL_INFERENCE_SESSION_CLASS(model_path, sess_options=so)

    with open(log_path, "r", errors="replace") as f:
        log_text = f.read()
    try:
        os.unlink(log_path)
    except OSError:
        pass

    report = _parse_placement_log(log_text, session.get_providers())
    return session, report


def patch_inference_session_for_provider_swap(target_device_selector):
    """
    Monkeypatches onnxruntime.InferenceSession so that any code (e.g. audio-separator's
    MDXSeparator.load_model()) requesting providers=["WebGpuExecutionProvider"] via the
    classic string-list API gets transparently routed through a verified,
    device-targeted construction instead of silently falling back to CPU (the classic
    API does not activate plugin EPs at all -- confirmed in Phase L1). Requests for any
    other provider list are passed through unmodified to the real original class --
    this does not touch the CPU, CUDA, DirectML, etc. code paths in any way.

    `target_device_selector` is a zero-arg callable returning the EpDevice to target,
    e.g. `lambda: select_device(pci_bus_id="0000:03:00.0")`.

    Returns (original_cls, reports): `original_cls` so a caller can restore
    `ort.InferenceSession = original_cls` later, and `reports`, a list that
    accumulates one placement-report dict per WebGPU session actually created (so a
    caller can inspect placement across every InferenceSession construction in a
    run -- audio-separator's MDXSeparator creates exactly one session per
    `separate()` call, but nothing here assumes that).
    """
    ensure_webgpu_library_registered()
    reports = []

    class VerifiedWebGpuInferenceSession(_ORIGINAL_INFERENCE_SESSION_CLASS):
        def __init__(self, path_or_bytes, sess_options=None, providers=None, provider_options=None, **kwargs):
            if providers and webgpu_ep.get_ep_name() in providers:
                device = target_device_selector()
                so = ort.SessionOptions()
                so.log_severity_level = 0
                so.add_provider_for_devices([device], {})
                with _capture_stderr_fd() as log_path:
                    super().__init__(path_or_bytes, sess_options=so)
                with open(log_path, "r", errors="replace") as f:
                    log_text = f.read()
                try:
                    os.unlink(log_path)
                except OSError:
                    pass
                report = _parse_placement_log(log_text, self.get_providers())
                reports.append(report)
            else:
                super().__init__(path_or_bytes, sess_options=sess_options, providers=providers,
                                  provider_options=provider_options, **kwargs)

    ort.InferenceSession = VerifiedWebGpuInferenceSession
    return _ORIGINAL_INFERENCE_SESSION_CLASS, reports
