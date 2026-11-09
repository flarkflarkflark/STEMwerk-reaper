from __future__ import annotations

import importlib

from .devices import get_available_devices, select_device
from .models import AVAILABLE_MODELS, DEMUCS_AUDIO_SEPARATOR_MODEL_IDS
from .progress import ProgressCallback

__all__ = [
    "StemSeparator",
    "SeparationResult",
    "get_available_devices",
    "select_device",
    "AVAILABLE_MODELS",
    "DEMUCS_AUDIO_SEPARATOR_MODEL_IDS",
    "ProgressCallback",
]

# separator.py imports third-party processing dependencies (yaml, and the
# audio-separator stack downstream) at module level. Keep it lazy so that
# importing lightweight modules such as stemwerk_core.readiness,
# stemwerk_core.device_policy or stemwerk_core.workflow_contracts never pulls
# those optional dependencies into a process that only evaluates contracts.
_LAZY_EXPORTS = {
    "StemSeparator": "separator",
    "SeparationResult": "separator",
}


def __getattr__(name: str):
    module_name = _LAZY_EXPORTS.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module = importlib.import_module(f".{module_name}", __name__)
    value = getattr(module, name)
    globals()[name] = value
    return value
