"""Shared device/backend selection policy for STEMwerk runtimes.

This module is the single home for the selection-policy helpers that used to
live inside the monolithic ``audio_separator_process.py`` runtime script.
It is deliberately importable without Torch, YAML, REAPER, or any other
optional processing dependency: ``stemwerk_core.devices`` only imports Torch
inside function bodies, and this module never imports anything heavier.

Extraction contract
-------------------
The implementations here are moved verbatim (modulo the injectable ``emit``
diagnostics callback and the optional ``platform_system`` parameter on
:func:`drum_kit_is_unexpected_cpu_downgrade`) from
``scripts/reaper/audio_separator_process.py``:

- ``prefer_linux_amd_device``            <- ``_prefer_linux_amd_device``
- ``is_unexpected_cpu_downgrade``        <- ``_is_unexpected_cpu_downgrade``
- ``resolve_normal_runtime_device``      <- ``_resolve_normal_runtime_device``
- ``DRUMSEP_RUNTIME_KINDS``              <- ``_DRUMSEP_RUNTIME_KINDS``
- ``drumsep_backend_classifier``         <- ``_drumsep_backend_classifier``
- ``drumsep_is_unexpected_cpu_downgrade`` <- ``_drumsep_is_unexpected_cpu_downgrade``
- ``drum_kit_is_unexpected_cpu_downgrade`` <- ``_drum_kit_is_unexpected_cpu_downgrade``

The legacy script keeps same-named thin wrappers delegating here, so
production call sites, authoritative gates, and existing tests that
monkeypatch the legacy names are unaffected. Do not fork these rules:
there is exactly one Auto-selection, CPU-downgrade, and fallback policy.
"""

from __future__ import annotations

import platform
import re
import sys
from typing import Callable, Dict, List, Optional, Set, Tuple

from . import devices as _devices

DRUMSEP_RUNTIME_KINDS = frozenset({"cpu", "cuda", "rocm", "mps", "directml"})


def _is_darwin_arm64() -> bool:
    return sys.platform == "darwin" and platform.machine().lower() in {"arm64", "aarch64"}


def _skip_ids() -> Set[str]:
    ids: Set[str] = set()
    skips = getattr(_devices, "_DEVICE_SKIPS", None) or []
    for entry in skips:
        skip_id = entry.get("id", "")
        if skip_id:
            ids.add(skip_id)
    return ids


def prefer_linux_amd_device(
    devices: List[Dict[str, str]], skip_ids: Set[str]
) -> Optional[Dict[str, str]]:
    if not devices:
        return None
    candidates = [d for d in devices if d.get("id") not in skip_ids]
    if not candidates:
        return None

    def score(dev: Dict[str, str]) -> int:
        name = (dev.get("name") or "").lower()
        sc = 0
        if "radeon rx" in name or " rx " in name or name.startswith("rx "):
            sc += 3
        if "radeon" in name and "graphics" not in name:
            sc += 1
        if "graphics" in name and "rx" not in name:
            sc -= 1
        if "780m" in name:
            sc -= 2
        return sc

    return max(candidates, key=score)


def is_unexpected_cpu_downgrade(requested_device: str, preview_device: str) -> bool:
    requested = str(requested_device or "auto").strip().lower()
    effective = str(preview_device or "").strip().lower()
    if effective != "cpu":
        return False
    return requested not in ("", "auto", "cpu")


def resolve_normal_runtime_device(
    device_preference: str,
    emit: Optional[Callable[[str], None]] = None,
    *,
    get_devices: Optional[Callable[[], List[Dict[str, str]]]] = None,
    select_device_fn: Optional[Callable[[str], Tuple[str, str]]] = None,
    is_darwin_arm64_fn: Optional[Callable[[], bool]] = None,
    prefer_linux_amd_fn: Optional[Callable[[List[Dict[str, str]], Set[str]], Optional[Dict[str, str]]]] = None,
    skip_ids_fn: Optional[Callable[[], Set[str]]] = None,
) -> Tuple[str, str, str, List[str]]:
    """Resolve the Normal-Stems runtime device exactly as the 2.3 runtime does.

    ``emit`` receives the same STEMWERK_DIAG diagnostic lines the legacy
    implementation prints to stderr; pass ``None`` to suppress them (the
    default, used by read-only readiness collection).

    The hardware-facing callables default to this package's own
    ``stemwerk_core.devices`` functions and policy helpers. The legacy
    runtime script passes its own module globals explicitly so that its
    established monkeypatch/injection surface keeps working unchanged --
    the *rule* lives here, the *wiring* stays with the caller.
    """

    emit_line = emit if emit is not None else (lambda _line: None)
    get_devices_fn = get_devices if get_devices is not None else _devices.get_available_devices
    select_fn = select_device_fn if select_device_fn is not None else _devices.select_device
    darwin_arm64_fn = is_darwin_arm64_fn if is_darwin_arm64_fn is not None else _is_darwin_arm64
    prefer_fn = prefer_linux_amd_fn if prefer_linux_amd_fn is not None else prefer_linux_amd_device
    get_skip_ids_fn = skip_ids_fn if skip_ids_fn is not None else _skip_ids

    requested = str(device_preference or "auto")
    resolved = requested
    live_devices = get_devices_fn()
    live_device_ids = [str(dev.get("id", "")) for dev in live_devices]
    emit_line(f"STEMWERK_DIAG requested_device={requested}")

    if requested == "auto":
        preferred = None
        if darwin_arm64_fn():
            preferred = next((dev for dev in live_devices if str(dev.get("id", "")).strip().lower() == "mps"), None)
        if sys.platform.startswith("linux"):
            preferred = preferred or prefer_fn(live_devices, get_skip_ids_fn())
        if preferred:
            resolved = preferred.get("id") or "auto"
            emit_line(
                f"STEMWERK_DIAG auto_selected_preferred={resolved} ({preferred.get('name','')})"
            )
        else:
            try:
                dev_id, dev_name = select_fn("auto")
                emit_line(f"STEMWERK_DIAG auto_selected={dev_id} ({dev_name})")
                resolved = dev_id
            except Exception:
                resolved = "auto"
    preview_device_id = resolved
    preview_device_name = ""
    try:
        preview_device_id, preview_device_name = select_fn(resolved)
    except Exception as exc:
        emit_line(f"normal_workflow_backend_preview_error={type(exc).__name__}:{exc}")

    return requested, resolved, f"{preview_device_id}|{preview_device_name}", live_device_ids


def drumsep_backend_classifier(device_id) -> str:
    device = str(device_id or "")
    return device if device in DRUMSEP_RUNTIME_KINDS else "unavailable"


def drumsep_is_unexpected_cpu_downgrade(requested_device: str, resolved_device: str) -> bool:
    requested = str(requested_device or "auto").strip().lower()
    resolved = str(resolved_device or "").strip().lower()
    if resolved not in ("cpu", "unavailable"):
        return False
    return requested not in ("", "auto", "cpu")


def drum_kit_is_unexpected_cpu_downgrade(
    selection_info, platform_system: Optional[str] = None
):
    """Selection-aware downgrade check for the DKS contract gates.

    Default is the source Slice-4 rule (drumsep_is_unexpected_cpu_downgrade):
    any explicit non-cpu request resolving to cpu/unavailable is rejected.
    One bounded exception, decided for the 2.4.0.0-r1 candidate: the
    preserved 2.3.1.3 Linux explicit_cuda production chain may deliver its
    *attributed* CPU fallback (explicit cuda/cuda:N request, no genuine
    NVIDIA runtime, no provisioned ROCm runtime). That route stays
    permitted and is reported truthfully (resolved_backend=cpu,
    fallback_applied=True, real fallback_reason). The exception requires
    the actual selector attribution -- selection_policy="fallback_cpu"
    with a "cuda_skipped:" reason on an explicit cuda request resolving to
    "cpu" -- and is guarded to Linux explicitly (same
    sys.platform convention as the chain it preserves), not merely
    relying on non-Linux selectors never emitting that attribution. A
    bare non-empty fallback_reason, any other request, or an
    "unavailable" result never qualifies: missing/broken runtimes and
    unattributed downgrades remain fail-closed.

    ``platform_system`` defaults to the host ``sys.platform``; simulated
    (fixture) evaluations pass their declared platform explicitly so the
    Linux guard evaluates against the fixture's platform, not the host's.
    """

    info = selection_info or {}
    effective_platform = sys.platform if platform_system is None else str(platform_system)

    def _check(requested_device: str, resolved_device: str) -> bool:
        if not drumsep_is_unexpected_cpu_downgrade(requested_device, resolved_device):
            return False
        requested = str(requested_device or "").strip().lower()
        resolved = str(resolved_device or "").strip().lower()
        if (
            effective_platform.startswith("linux")
            and re.fullmatch(r"cuda(:\d+)?", requested)
            and resolved == "cpu"
            and info.get("selection_policy") == "fallback_cpu"
            and str(info.get("fallback_reason") or "").startswith("cuda_skipped:")
        ):
            return False
        return True

    return _check
