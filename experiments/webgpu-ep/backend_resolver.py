"""
Experimental, model-aware WebGPU backend resolver -- Phase L11.

NOT a replacement for CUDA/ROCm/MPS/DirectML (see the L11 brief's own "Doel"). This
resolver decides ONLY whether STEMwerk's shared WebGPU inference route should be
offered for a given (model, platform, physical GPU) combination -- and if so, which
physical GPU, whether that selection can actually be enforced, and what process
isolation that requires. It never silently swaps to a different GPU than what was
explicitly requested, and it never reports a successful GPU selection unless GPU
execution was independently proven for that exact combination (per capability_matrix.py).

This module contains no model-execution code and starts no subprocess itself --
`required_process_isolation` is returned as a plan (env dict) for the CALLER to apply
when it actually launches inference, exactly as L10's own proven pattern requires
(isolation env vars set before a fresh subprocess starts, never globally).
"""
from __future__ import annotations

import dataclasses
import sys
from typing import Optional

import capability_matrix as cm
import linux_vulkan_isolation as lvi


@dataclasses.dataclass(frozen=True)
class GpuInfo:
    vendor: str
    model: str
    device_id_hex: Optional[str] = None
    pci_bus_id: Optional[str] = None


@dataclasses.dataclass(frozen=True)
class ResolveRequest:
    model_name: str
    os_arch: str                       # substring, e.g. "linux", "macos", "windows"
    available_gpus: tuple               # tuple[GpuInfo, ...]
    desired_backend: str                # "Auto" | "CPU" | "WebGPU" | "Vendor"
    explicit_gpu: Optional[GpuInfo] = None
    allow_fallback: bool = True
    webgpu_ep_available: bool = True    # runtime signal: did the plugin EP actually register on THIS machine
    windows_native_luid_selection_available: bool = False  # exact W5-patched runtime capability, not stock 0.3.0
    capability_matrix: tuple = tuple(cm.MATRIX)


@dataclasses.dataclass(frozen=True)
class ResolveResult:
    selected_backend: Optional[str]           # "CPU" | "WebGPU" | "Vendor:<name>" | None
    selected_gpu: Optional[GpuInfo]
    device_selection_enforceable: bool
    required_process_isolation: Optional[dict]  # env vars for the caller's fresh subprocess, or None
    model_gpu_suitability: str
    fallback_decision: str
    reason: str
    evidence: list
    status: str                                # "PASS" | "FAIL" | "BLOCKED" | "UNKNOWN"


def _lookup(matrix, os_arch: str, gpu_model: str, model_name: str) -> Optional[cm.CapabilityEntry]:
    for e in matrix:
        if (gpu_model.lower() in e.gpu_model.lower()
                and model_name.lower() in e.model_name.lower()
                and os_arch.lower() in e.os_arch.lower()):
            return e
    return None


def _vendor_alternative_is_proven_better(entry: cm.CapabilityEntry) -> bool:
    v = entry.vendor_alternative_available
    return bool(v) and "proven" in v.lower()


def _audio_correctness_note(entry: cm.CapabilityEntry) -> str:
    """Empty string when the entry's end-to-end audio correctness is an unqualified
    PASS; otherwise the full field, prefixed for appending to a suitability string.

    suitable_for_auto must never be read as unconditional end-to-end audio
    correctness: a row can be the fastest correct backend (Windows RX 9070 Demucs,
    1.91x vs CPU) while its exported-WAV output still carries a disclosed clipping
    caveat (raw float drums peak 1.363, PCM16 clamps to 1.0, harness peak>0.999 gate
    fails symmetrically on CPU and WebGPU). Downstream consumers of a resolver PASS
    must see that limitation in the decision itself, not only in the matrix row."""
    v = entry.end_to_end_audio_correctness.strip()
    if v == "PASS" or v.startswith("PASS --"):
        return ""
    return f" -- audio-output: {v}"


def _isolation_for(req: ResolveRequest, gpu: GpuInfo, entry: Optional[cm.CapabilityEntry]):
    """
    Returns (enforceable: bool, plan_env: Optional[dict], note: str).

    Single-GPU systems need no isolation at all (nothing to isolate FROM). Multi-GPU
    systems need a PROVEN platform-specific mechanism. Linux uses
    VK_LOADER_DEVICE_ID_FILTER (L10); the exact experimental Windows native build
    recorded by W5 uses Dawn's DXGI-LUID request and returned-adapter verification.
    Anything else is reported as unenforceable, never assumed to work.
    """
    if len(req.available_gpus) <= 1:
        return True, None, "N/A -- single GPU present, no isolation needed"

    if sys.platform.startswith("linux") or "linux" in req.os_arch.lower():
        if gpu.device_id_hex is None:
            return False, None, "Multiple GPUs present but target device_id_hex unknown -- cannot build isolation plan"
        plan = lvi.build_isolation_plan(gpu.device_id_hex)
        return True, plan.env, f"PASS -- {plan.mechanism}"

    if ("windows" in req.os_arch.lower() and
            req.windows_native_luid_selection_available and entry is not None):
        verdict = entry.device_selection_enforceable.strip()
        if verdict.startswith("PASS") and "LUID" in verdict:
            return True, None, verdict

    # macOS, stock Windows plugin builds, and other configurations have no proven
    # multi-GPU mechanism in this project's evidence base.
    enforceable_note = entry.device_selection_enforceable if entry else "no capability evidence for this platform"
    return False, None, f"NOT ENFORCEABLE -- {enforceable_note}"


def resolve(req: ResolveRequest) -> ResolveResult:
    matrix = req.capability_matrix

    # --- Trivial cases ---
    if not req.webgpu_ep_available and req.desired_backend in ("Auto", "WebGPU"):
        if req.desired_backend == "WebGPU":
            return ResolveResult(
                selected_backend=None, selected_gpu=None, device_selection_enforceable=False,
                required_process_isolation=None,
                model_gpu_suitability="N/A -- WebGPU EP did not register on this system",
                fallback_decision="No fallback attempted -- explicit WebGPU was requested, not Auto",
                reason="onnxruntime-ep-webgpu did not register/load on this machine at runtime",
                evidence=["runtime signal: webgpu_ep_available=False"], status="FAIL",
            )
        # Auto: fall through to CPU/vendor below by pretending no matrix hit is usable.

    if req.desired_backend == "CPU":
        return ResolveResult(
            selected_backend="CPU", selected_gpu=None, device_selection_enforceable=True,
            required_process_isolation=None, model_gpu_suitability="N/A -- CPU explicitly requested",
            fallback_decision="N/A", reason="CPU explicitly requested",
            evidence=["CPUExecutionProvider is always available"], status="PASS",
        )

    # --- Explicit GPU requested: never silently substitute a different one ---
    if req.explicit_gpu is not None:
        gpu = req.explicit_gpu
        if gpu not in req.available_gpus:
            return ResolveResult(
                selected_backend=None, selected_gpu=None, device_selection_enforceable=False,
                required_process_isolation=None,
                model_gpu_suitability="N/A -- requested GPU is not present on this system",
                fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
                reason=f"Explicit GPU {gpu.model!r} not found in available_gpus -- refusing to guess "
                       f"a substitute (never silently select a different physical GPU)",
                evidence=[], status="FAIL",
            )
        entry = _lookup(matrix, req.os_arch, gpu.model, req.model_name)
        if entry is None:
            return ResolveResult(
                selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
                device_selection_enforceable=False, required_process_isolation=None,
                model_gpu_suitability="UNKNOWN -- no capability evidence for this exact "
                                       "(OS, GPU, model) combination",
                fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
                reason="No matrix entry -- cannot report a successful GPU selection without evidence "
                       "(never claim PASS on an untested combination)",
                evidence=[], status="UNKNOWN",
            )
        if not entry.found_correct:
            return ResolveResult(
                selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
                device_selection_enforceable=False, required_process_isolation=None,
                model_gpu_suitability=f"NOT SUITABLE -- {entry.stability}",
                fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted; "
                                    "explicit GPU/model combination is known-unstable/incorrect"),
                reason="Explicit GPU/model combination is known, from prior evidence, to be unstable or "
                       "incorrect -- refusing to execute it regardless of explicit request "
                       "(will not cause a repeat GPU hang to re-obtain an already-proven conclusion)",
                evidence=[entry.evidence], status="BLOCKED",
            )
        enforceable, iso_env, iso_note = _isolation_for(req, gpu, entry)
        if not enforceable:
            return ResolveResult(
                selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
                device_selection_enforceable=False, required_process_isolation=None,
                model_gpu_suitability=f"Correct when reached ({entry.numerical_correctness}), but physical "
                                       f"selection of this exact GPU cannot be guaranteed on this platform",
                fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
                reason=f"Multiple GPUs present and device selection is not provably enforceable here: {iso_note}",
                evidence=[entry.evidence], status="BLOCKED",
            )
        suitability = ("Suitable for Auto" + _audio_correctness_note(entry)) if entry.suitable_for_auto else \
            f"Correct and stable, but NOT suitable as an automatic default: {entry.practical_performance}"
        return ResolveResult(
            selected_backend="WebGPU", selected_gpu=gpu, device_selection_enforceable=True,
            required_process_isolation=iso_env, model_gpu_suitability=suitability,
            fallback_decision="N/A -- explicit request succeeded",
            reason=f"Explicit GPU {gpu.model!r} requested and proven correct/stable for {req.model_name} "
                   f"({iso_note})",
            evidence=[entry.evidence], status="PASS",
        )

    # --- Auto or bare "WebGPU" (no explicit GPU): pick among available_gpus ---
    if req.desired_backend not in ("Auto", "WebGPU"):
        return ResolveResult(
            selected_backend=None, selected_gpu=None, device_selection_enforceable=False,
            required_process_isolation=None, model_gpu_suitability="N/A",
            fallback_decision="N/A", reason=f"Unrecognized desired_backend={req.desired_backend!r}",
            evidence=[], status="FAIL",
        )

    if not req.available_gpus:
        return ResolveResult(
            selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
            device_selection_enforceable=False, required_process_isolation=None,
            model_gpu_suitability="N/A -- no GPUs available",
            fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
            reason="No physical GPUs reported available", evidence=[], status="UNKNOWN",
        )

    candidates = []
    for gpu in req.available_gpus:
        entry = _lookup(matrix, req.os_arch, gpu.model, req.model_name)
        candidates.append((gpu, entry))

    # Auto specifically: prefer an already-proven-superior vendor backend over WebGPU,
    # per the brief's "Doel" (WebGPU supplements vendor backends, does not replace them).
    if req.desired_backend == "Auto":
        for gpu, entry in candidates:
            if entry is not None and _vendor_alternative_is_proven_better(entry):
                return ResolveResult(
                    selected_backend=f"Vendor:{entry.vendor_alternative_available.split(' ')[0]}",
                    selected_gpu=gpu, device_selection_enforceable=True, required_process_isolation=None,
                    model_gpu_suitability="WebGPU itself may be correct here, but an already-proven-superior "
                                           "vendor backend exists and Auto must prefer it",
                    fallback_decision="N/A -- vendor backend selected, not a fallback",
                    reason=f"{entry.vendor_alternative_available} -- Auto keeps the existing accelerated "
                           f"route rather than switching to WebGPU",
                    evidence=[entry.evidence], status="PASS",
                )

    # Otherwise: pick the best WebGPU-suitable candidate, preferring a non-integrated GPU
    # when more than one is technically suitable (mirrors real-world "prefer the discrete
    # GPU" expectation; matches this project's own RX 9070-over-780M evidence).
    suitable = [(g, e) for g, e in candidates if e is not None and
                (e.suitable_for_auto if req.desired_backend == "Auto" else e.found_correct)]
    if not suitable:
        # Distinguish "known bad" (BLOCKED) from "no evidence" (UNKNOWN).
        any_known_bad = any(e is not None and not e.found_correct for _, e in candidates)
        status = "BLOCKED" if any_known_bad else "UNKNOWN"
        reasons = [f"{g.model}: {(e.stability if e else 'no capability evidence')}" for g, e in candidates]
        return ResolveResult(
            selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
            device_selection_enforceable=False, required_process_isolation=None,
            model_gpu_suitability="; ".join(reasons),
            fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
            reason="No available GPU is proven suitable for WebGPU with this model on this platform",
            evidence=[e.evidence for _, e in candidates if e is not None], status=status,
        )

    suitable.sort(key=lambda ge: ("igpu" in ge[0].model.lower() or "integrated" in ge[0].model.lower()))
    gpu, entry = suitable[0]

    enforceable, iso_env, iso_note = _isolation_for(req, gpu, entry)
    if not enforceable:
        return ResolveResult(
            selected_backend=("CPU" if req.allow_fallback else None), selected_gpu=None,
            device_selection_enforceable=False, required_process_isolation=None,
            model_gpu_suitability=f"{gpu.model} is correct/suitable, but selection is not enforceable here",
            fallback_decision=("Fallback to CPU" if req.allow_fallback else "No fallback permitted"),
            reason=f"Multiple GPUs present ({[g.model for g, _ in candidates]}) and device selection is "
                   f"not provably enforceable on this platform: {iso_note}",
            evidence=[entry.evidence], status="BLOCKED",
        )

    return ResolveResult(
        selected_backend="WebGPU", selected_gpu=gpu, device_selection_enforceable=True,
        required_process_isolation=iso_env,
        model_gpu_suitability=(("Suitable for Auto" + _audio_correctness_note(entry))
                                if entry.suitable_for_auto else
                                f"Correct/stable but not Auto-suitable: {entry.practical_performance}"),
        fallback_decision="N/A -- WebGPU selected directly",
        reason=f"{gpu.model} proven correct and stable for {req.model_name} on this platform ({iso_note})",
        evidence=[entry.evidence], status="PASS",
    )
