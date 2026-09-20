"""
Linux-specific, process-local Vulkan physical-device isolation -- Phase L11.

Wraps the exact mechanism proven in L10 (`RADEON_780M_DEVICE_ISOLATION.md` Section 4/6):
`VK_LOADER_DEVICE_ID_FILTER`, an official Vulkan-Loader environment variable that hides
every non-matching physical device from `vkEnumeratePhysicalDevices()` for the process
it is set on -- confirmed via raw `vulkaninfo`, real ONNX Runtime session creation, and
independent kernel-level GPU-busy monitoring, bidirectionally (L10 Experiments C/D).

This module deliberately does ONE thing: build the environment dict for a *fresh
subprocess*. It never sets `os.environ` on the calling process, never touches any
global/system Vulkan configuration, and never assumes the isolation is in effect
until the target process is actually started with it -- consistent with L10's own
safety constraints ("no global environment changes", "fresh subprocesses so every
isolation experiment starts before Dawn initializes").

`backend_resolver.py` calls this only on `sys.platform.startswith("linux")` and treats
every other platform as `IsolationNotAvailableError` -- the shared resolver must never
assume this Vulkan-Loader technique generalizes to Windows (D3D12/DXGI) or macOS
(Metal), per L10 Section 12's explicit no-portability-claim.
"""
from __future__ import annotations

import dataclasses
import sys


class IsolationNotAvailableError(RuntimeError):
    """Raised when Linux Vulkan-Loader device isolation is requested on a platform
    (or in a situation) where it has not been proven -- callers must not fall back to
    a silent no-op, per L11's 'never silently pick a different GPU' requirement."""


@dataclasses.dataclass(frozen=True)
class IsolationPlan:
    mechanism: str          # human-readable name, for reporting/evidence
    env: dict                # env vars to set on the fresh subprocess, nothing else
    target_device_id_hex: str
    excludes_device_ids_hex: tuple  # informational: what this positively excludes, per L10 Section 6


def build_isolation_plan(target_device_id_hex: str) -> IsolationPlan:
    """
    Returns the environment dict to set on a FRESH subprocess (never on the calling
    process, never globally) so that only the physical Vulkan device with this hex
    device ID (e.g. "0x15bf" for the Radeon 780M) is visible to it.

    `target_device_id_hex` must be a "0x"-prefixed hex string matching the device's
    PCI device ID, exactly as reported by `vulkaninfo`/`webgpu_adapter.list_webgpu_devices()`
    -- this function does not look up or guess an ID; the caller must supply the exact
    value confirmed for the target hardware (L10 Section 3's re-verification discipline:
    never assume identifiers are still correct without checking).

    Raises IsolationNotAvailableError on any non-Linux platform -- there is no proven
    equivalent mechanism for D3D12 (Windows) or Metal (macOS) in this project's
    evidence base (L10 Section 12).
    """
    if not sys.platform.startswith("linux"):
        raise IsolationNotAvailableError(
            f"Linux Vulkan-Loader device isolation (VK_LOADER_DEVICE_ID_FILTER) has no proven "
            f"equivalent on {sys.platform!r}. Do not silently skip isolation and proceed anyway -- "
            f"the caller must treat device selection as unenforceable on this platform."
        )
    if not (isinstance(target_device_id_hex, str) and target_device_id_hex.lower().startswith("0x")):
        raise ValueError(f"target_device_id_hex must be a '0x'-prefixed hex string, got {target_device_id_hex!r}")

    return IsolationPlan(
        mechanism="VK_LOADER_DEVICE_ID_FILTER (Khronos Vulkan-Loader env var; proven in L10, "
                  "NOT MESA_VK_DEVICE_SELECT, which only reorders enumeration and has zero effect "
                  "on actual physical execution -- L10 Section 4/8 Experiment B)",
        env={"VK_LOADER_DEVICE_ID_FILTER": target_device_id_hex},
        target_device_id_hex=target_device_id_hex,
        excludes_device_ids_hex=(),  # filter is inclusive-by-ID, not an explicit exclude list
    )


def merged_subprocess_env(base_env: dict, target_device_id_hex: str) -> dict:
    """Convenience: returns a COPY of base_env with the isolation var added, for direct
    use as `subprocess.run(..., env=merged_subprocess_env(os.environ.copy(), "0x15bf"))`.
    Never mutates base_env in place, never touches the calling process's own os.environ."""
    plan = build_isolation_plan(target_device_id_hex)
    merged = dict(base_env)
    merged.update(plan.env)
    return merged
