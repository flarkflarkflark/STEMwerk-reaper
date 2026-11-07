"""Production wiring between the Slice-1 resolver and the 2.3 legacy runtime.

``stemwerk_core.runtime_resolution`` is deliberately pure and knows nothing
about ``audio_separator_process.py``. This module is the one place that
bridges the two for callers that need the real legacy-backed probes.

Normal Stems no longer needs the legacy module at all: the Auto-device
preference (Linux AMD-name scoring, Darwin MPS preference) and the
CPU-downgrade guard now live in ``stemwerk_core.device_policy`` (extracted
verbatim from the legacy script, which delegates back to it), so
:func:`build_normal_stems_capability_probe` composes them directly.

DrumSep runtime selection now lives in ``stemwerk_core.drumsep_runtime``.
This older resolver seam still reaches it through the processor's thin
``_select_drumsep_runtime`` compatibility wrapper so existing processing and
monkeypatch surfaces remain intact; standalone readiness does not use this
seam or import the processor.
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

from stemwerk_core import device_policy  # noqa: E402
from stemwerk_core import devices as core_devices  # noqa: E402
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
    """Return a CapabilityProbe backed by the real 2.3 normal-stems runtime
    policy (stemwerk_core.devices enumeration + device_policy selection)."""

    def resolve_auto_device(_live_devices: Sequence[Mapping[str, str]]) -> Optional[Mapping[str, str]]:
        _requested, _resolved, preview, _live_ids = device_policy.resolve_normal_runtime_device("auto")
        preview_id, _, preview_name = preview.partition("|")
        return {"id": preview_id, "name": preview_name}

    return CapabilityProbe(
        get_available_devices=core_devices.get_available_devices,
        select_device=core_devices.select_device,
        runtime_kind_for_device=core_devices.runtime_kind_for_device,
        is_unexpected_cpu_downgrade=device_policy.is_unexpected_cpu_downgrade,
        resolve_auto_device=resolve_auto_device,
    )


# Slice 2: the 2.4 contract layer's model_id must be a lowercase stable id
# (see stemwerk_core.workflow_contracts._SEMANTIC_ID), which the real
# checkpoint filename is not ("MDX23C-DrumSep-aufr33-jarredou.ckpt" starts
# with an uppercase letter). "drumsep_mdx23c" is the 2.4 canonical id for
# this single fixed DrumSep model; both legacy spellings
# _resolve_direct_dks_model_catalog_entry() already accepts
# (DIRECT_DKS_MODEL_ALIAS and DIRECT_DKS_MODEL_FILENAME) map to it.
LEGACY_TO_CONTRACT_DRUMSEP_MODEL_ID = {
    "MDX23C-DrumSep-aufr33-jarredou.ckpt": "drumsep_mdx23c",
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt": "drumsep_mdx23c",
}

# DrumSep's Core-owned selector, exposed here through the legacy compatibility
# wrapper, resolves directly to a
# backend *kind* (cpu/cuda/rocm/mps/directml) plus a venv python path -- there is
# no separate "device id" concept (no cuda:N GPU index) the way
# stemwerk_core.devices has. The kind string doubles as both the resolved
# device and the resolved backend for this probe. The kind set and the
# downgrade/classifier rules are shared via stemwerk_core.device_policy.


def _drumsep_select_device(legacy, requested: str) -> tuple:
    python_path, kind_or_reason, _info = legacy._select_drumsep_runtime(requested)
    if python_path is not None and kind_or_reason in device_policy.DRUMSEP_RUNTIME_KINDS:
        return kind_or_reason, kind_or_reason
    # _select_drumsep_runtime returns (None, "missing"|"broken", info) when
    # nothing usable was found at all (not even a CPU fallback, for the
    # explicit branches that now fail closed). "unavailable" is never a
    # member of any capability's permitted_backends, so the resolver's
    # existing fail-closed checks reject it without any DrumSep-specific
    # logic in stemwerk_core.runtime_resolution itself.
    return "unavailable", ""


def build_drum_kit_capability_probe() -> CapabilityProbe:
    """Return a CapabilityProbe backed by the Core-owned DrumSep selector via
    its legacy wrapper, used by both Direct Kit and Drum Split stage 2.
    """

    legacy = _load_legacy_module()

    return CapabilityProbe(
        get_available_devices=lambda: [],
        select_device=lambda requested: _drumsep_select_device(legacy, requested),
        runtime_kind_for_device=device_policy.drumsep_backend_classifier,
        is_unexpected_cpu_downgrade=device_policy.drumsep_is_unexpected_cpu_downgrade,
    )
