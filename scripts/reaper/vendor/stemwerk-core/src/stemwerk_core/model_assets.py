"""Read-only model-asset helpers for STEMwerk Core.

Everything here is a pure filesystem/content inspection: no downloads, no
eviction, no cache initialization, no model loading. The DrumSep asset
*metadata* (filenames, download URLs, pinned hashes and the eviction path)
remains owned by ``audio_separator_process.py`` -- callers that need DrumSep
asset evidence receive the authoritative filename/hash pairs from the
REAPER-side adapter and evaluate them here read-only. This module therefore
carries no DrumSep constants and cannot drift from them.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import List


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
