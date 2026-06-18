from __future__ import annotations

from typing import Dict

AVAILABLE_MODELS: Dict[str, str] = {
    "htdemucs": "htdemucs",
    "htdemucs_ft": "htdemucs_ft",
    "htdemucs_6s": "htdemucs_6s",
    "hdemucs_mmi": "hdemucs_mmi",
}


def resolve_model_name(model_name: str) -> str:
    """Resolve a friendly model name to the audio-separator model file."""
    return AVAILABLE_MODELS.get(model_name, model_name)
