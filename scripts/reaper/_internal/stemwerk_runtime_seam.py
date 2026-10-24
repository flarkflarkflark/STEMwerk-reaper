"""Production wiring between the Slice-1 resolver and the 2.3 legacy runtime.

``stemwerk_core.runtime_resolution`` is deliberately pure and knows nothing
about ``audio_separator_process.py``. This module is the one place that
bridges the two: it builds a ``CapabilityProbe`` whose Auto-device
preference reproduces the *exact* existing Linux AMD-name-scoring policy
from ``audio_separator_process._prefer_linux_amd_device`` /
``_resolve_normal_runtime_device``, instead of re-deriving or approximating
that priority order.

This is temporary compatibility glue, not a permanent architecture: a later
slice should hoist ``_prefer_linux_amd_device`` and
``_resolve_normal_runtime_device`` out of the monolithic
``audio_separator_process.py`` script and into ``stemwerk_core.devices`` as
a first-class, directly importable policy. Once that happens, this seam
file can be deleted and ``stemwerk_core.runtime_resolution`` wired to it
directly. Until then, this module loads ``audio_separator_process.py``
dynamically via ``importlib`` -- the same mechanism the existing test suite
already uses to reach its private functions (see e.g.
``tests/test_windows_normal_route_matrix.py``).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Mapping, Optional, Sequence

CORE_SRC = Path(__file__).resolve().parents[1] / "vendor" / "stemwerk-core" / "src"
PROCESS_SCRIPT = Path(__file__).resolve().parents[1] / "audio_separator_process.py"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.runtime_resolution import CapabilityProbe  # noqa: E402

_legacy_module = None


def _load_legacy_module():
    global _legacy_module
    if _legacy_module is not None:
        return _legacy_module
    spec = importlib.util.spec_from_file_location("stemwerk_runtime_seam_legacy", PROCESS_SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._require_core()
    _legacy_module = module
    return module


def build_normal_stems_capability_probe() -> CapabilityProbe:
    """Return a CapabilityProbe backed by the real 2.3 normal-stems runtime."""

    legacy = _load_legacy_module()

    def resolve_auto_device(_live_devices: Sequence[Mapping[str, str]]) -> Optional[Mapping[str, str]]:
        _requested, _resolved, preview, _live_ids = legacy._resolve_normal_runtime_device("auto")
        preview_id, _, preview_name = preview.partition("|")
        return {"id": preview_id, "name": preview_name}

    return CapabilityProbe(
        get_available_devices=legacy.core_devices.get_available_devices,
        select_device=legacy.select_device,
        runtime_kind_for_device=legacy.core_devices.runtime_kind_for_device,
        is_unexpected_cpu_downgrade=legacy._is_unexpected_cpu_downgrade,
        resolve_auto_device=resolve_auto_device,
    )
