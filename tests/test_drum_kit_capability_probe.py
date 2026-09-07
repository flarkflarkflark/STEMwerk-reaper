"""Tests for the DrumSep-backed CapabilityProbe adapter in
scripts/reaper/_internal/stemwerk_runtime_seam.py -- the seam that lets the
2.4 resolver reach the real _select_drumsep_runtime for Direct Kit / Drum
Split, mirroring how build_normal_stems_capability_probe reaches
_resolve_normal_runtime_device.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
INTERNAL = ROOT / "scripts" / "reaper" / "_internal"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"

for path in (CORE_SRC, INTERNAL):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from stemwerk_core.runtime_resolution import ResolutionError, resolve_execution_plan  # noqa: E402
import stemwerk_runtime_seam  # noqa: E402


@pytest.fixture
def legacy_module():
    return stemwerk_runtime_seam._load_legacy_module()


def test_drumsep_probe_explicit_rocm_success(monkeypatch, legacy_module):
    monkeypatch.setattr(
        legacy_module, "_select_drumsep_runtime", lambda requested, runtime_base=None: (Path("/fake/python"), "rocm", {})
    )
    probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()

    plan = resolve_execution_plan(
        "drum_kit_direct", "drumsep_mdx23c", "rocm", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "rocm"
    assert plan.fallback_applied is False


def test_drumsep_probe_explicit_rocm_failure_fails_closed(monkeypatch, legacy_module):
    monkeypatch.setattr(
        legacy_module, "_select_drumsep_runtime", lambda requested, runtime_base=None: (None, "broken", {})
    )
    probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()

    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("drum_kit_direct", "drumsep_mdx23c", "rocm", catalog_dir=CATALOG_DIR, probe=probe)
    assert excinfo.value.code == "backend_unavailable"


def test_drumsep_probe_auto_falls_back_to_cpu_without_failing(monkeypatch, legacy_module):
    monkeypatch.setattr(
        legacy_module, "_select_drumsep_runtime", lambda requested, runtime_base=None: (Path("/fake/python"), "cpu", {})
    )
    probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()

    plan = resolve_execution_plan("drum_kit_direct", "drumsep_mdx23c", "auto", catalog_dir=CATALOG_DIR, probe=probe)
    assert plan.resolved_backend == "cpu"
    assert plan.fallback_applied is True


def test_drumsep_probe_auto_total_failure_fails_closed(monkeypatch, legacy_module):
    monkeypatch.setattr(
        legacy_module, "_select_drumsep_runtime", lambda requested, runtime_base=None: (None, "missing", {})
    )
    probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()

    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("drum_kit_direct", "drumsep_mdx23c", "auto", catalog_dir=CATALOG_DIR, probe=probe)
    assert excinfo.value.code == "backend_not_permitted"


def test_drumsep_probe_explicit_cpu_success(monkeypatch, legacy_module):
    monkeypatch.setattr(
        legacy_module, "_select_drumsep_runtime", lambda requested, runtime_base=None: (Path("/fake/python"), "cpu", {})
    )
    probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()

    plan = resolve_execution_plan("drum_kit_direct", "drumsep_mdx23c", "cpu", catalog_dir=CATALOG_DIR, probe=probe)
    assert plan.resolved_backend == "cpu"
    assert plan.fallback_applied is False


def test_legacy_model_id_mapping_covers_both_accepted_spellings():
    mapping = stemwerk_runtime_seam.LEGACY_TO_CONTRACT_DRUMSEP_MODEL_ID
    assert mapping["MDX23C-DrumSep-aufr33-jarredou.ckpt"] == "drumsep_mdx23c"
    assert mapping["aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"] == "drumsep_mdx23c"
