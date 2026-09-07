"""Hardware-facing integration test: resolver + real legacy seam.

Unlike tests/test_runtime_resolution.py (pure, fully mocked), this file
wires stemwerk_core.runtime_resolution to the REAL
stemwerk_runtime_seam.build_normal_stems_capability_probe(), which loads
the actual audio_separator_process.py and stemwerk_core.devices. It
requires torch to be importable and is skipped otherwise -- see CLAUDE
Slice-1 instructions section 8: "Backend tests must not require an actual
GPU unless explicitly marked as hardware/integration tests."
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

torch = pytest.importorskip("torch")

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
INTERNAL = ROOT / "scripts" / "reaper" / "_internal"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"

for path in (CORE_SRC, INTERNAL):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from stemwerk_core.runtime_resolution import resolve_execution_plan  # noqa: E402
from stemwerk_runtime_seam import build_normal_stems_capability_probe  # noqa: E402


def _machine_is_rocm_torch() -> bool:
    try:
        hip = getattr(getattr(torch, "version", None), "hip", None)
    except Exception:
        hip = None
    return bool(hip) or "rocm" in str(getattr(torch, "__version__", "")).lower()


def test_seam_auto_resolution_matches_legacy_runtime_intent():
    probe = build_normal_stems_capability_probe()
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "auto", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend in {"cpu", "cuda", "rocm", "mps", "directml"}
    if sys.platform.startswith("linux") and _machine_is_rocm_torch() and torch.cuda.is_available():
        assert plan.resolved_backend == "rocm", (
            "this machine has ROCm-flavored torch with a visible device; "
            "Auto must resolve to rocm, not silently fall back to cpu"
        )
        assert plan.fallback_applied is False


def test_seam_explicit_cpu_resolution():
    probe = build_normal_stems_capability_probe()
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
    assert plan.fallback_applied is False
