"""Read-only model-asset helpers for STEMwerk Core.

Everything here is a pure filesystem/content inspection: no downloads, no
eviction, no cache initialization, no model loading. Core owns the validated
DrumSep filename/hash pairs needed for client-neutral readiness. Download URLs
and every provisioning or eviction operation remain outside this module.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any, Dict, List, Optional

DIRECT_DKS_MODEL_FILENAME = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
DIRECT_DKS_MODEL_YAML = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
DIRECT_DKS_MODEL_CKPT_SHA256 = "d2a4aa53eb584d21eead358a4e66d1882ad182911be018f052b5da73be9096d0"
DIRECT_DKS_MODEL_YAML_SHA256 = "440a13f67461b2cdad2bb1cb86c08ff27a8ec53093c4a24d4d7fc2c19cb9f5f5"
DIRECT_DKS_MODEL_EXPECTED_SHA256 = {
    DIRECT_DKS_MODEL_FILENAME: DIRECT_DKS_MODEL_CKPT_SHA256,
    DIRECT_DKS_MODEL_YAML: DIRECT_DKS_MODEL_YAML_SHA256,
}


def drumsep_asset_evidence(model_cache_dir: Optional[Path] = None) -> Dict[str, Any]:
    """Return Core's pinned DrumSep assets without touching their contents."""

    from . import managed_runtime

    base_dir = (
        Path(model_cache_dir).expanduser()
        if model_cache_dir is not None
        else managed_runtime.managed_model_cache_dir()
    )
    return {
        "base_dir": str(base_dir),
        "assets": [
            {"name": name, "sha256": expected}
            for name, expected in sorted(DIRECT_DKS_MODEL_EXPECTED_SHA256.items())
        ],
    }


def demucs_yaml_weight_prefixes(yaml_path: Path) -> List[str]:
    """Weight-file prefixes referenced by a Demucs model descriptor.

    Moved verbatim from ``tools/stemwerk_runtime_diagnostics.py``'s
    ``_referenced_model_hashes`` so the diagnostics harness and Core
    readiness share one implementation.
    """

    text = Path(yaml_path).read_text(encoding="utf-8")
    match = re.search(r"models:\s*\[([^\]]*)\]", text)
    if not match:
        return []
    return [h.strip("'\" ") for h in match.group(1).split(",") if h.strip("'\" ")]


def file_sha256(path: Path) -> str:
    """Content hash of a local file. Read-only; raises OSError if unreadable."""

    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
