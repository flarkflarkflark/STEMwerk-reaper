from __future__ import annotations

from typing import Dict

AVAILABLE_MODELS: Dict[str, str] = {
    "htdemucs": "htdemucs",
    "htdemucs_ft": "htdemucs_ft",
    "htdemucs_6s": "htdemucs_6s",
    "hdemucs_mmi": "hdemucs_mmi",
}

DEMUCS_AUDIO_SEPARATOR_MODEL_IDS: Dict[str, str] = {
    "htdemucs": "htdemucs.yaml",
    "htdemucs_ft": "htdemucs_ft.yaml",
    "htdemucs_6s": "htdemucs_6s.yaml",
    "hdemucs_mmi": "hdemucs_mmi.yaml",
}


def resolve_model_name(model_name: str) -> str:
    """Resolve a friendly model name to the audio-separator model file."""
    return AVAILABLE_MODELS.get(model_name, model_name)


def resolve_audio_separator_model_id(model_name: str) -> str:
    """Resolve a friendly model name to the concrete audio-separator model id."""
    resolved = resolve_model_name(model_name)
    return DEMUCS_AUDIO_SEPARATOR_MODEL_IDS.get(resolved, resolved)
