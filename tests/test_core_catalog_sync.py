"""Tests for the packaged stemwerk_core catalog copy and its sync tool."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
CANONICAL_DIR = ROOT / "scripts" / "reaper" / "catalog"
PACKAGED_DIR = CORE_SRC / "stemwerk_core" / "catalog"
SYNC_TOOL = ROOT / "tools" / "sync_core_catalog.py"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.workflow_contracts import validate_catalogs  # noqa: E402

sys.path.insert(0, str(ROOT / "tools"))
import sync_core_catalog  # noqa: E402


@pytest.mark.portable
def test_packaged_catalog_is_in_sync():
    drift = sync_core_catalog.collect_drift()
    assert drift == [], f"packaged catalog drift: {drift}"


@pytest.mark.portable
def test_sync_check_cli_passes():
    proc = subprocess.run(
        [sys.executable, str(SYNC_TOOL), "--check"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, proc.stderr


@pytest.mark.portable
def test_drift_is_detected_and_write_resyncs(tmp_path, monkeypatch):
    canonical = tmp_path / "canonical"
    packaged = tmp_path / "packaged"
    shutil.copytree(CANONICAL_DIR, canonical)
    shutil.copytree(CANONICAL_DIR, packaged)
    monkeypatch.setattr(sync_core_catalog, "CANONICAL_DIR", canonical)
    monkeypatch.setattr(sync_core_catalog, "PACKAGED_DIR", packaged)
    assert sync_core_catalog.collect_drift() == []

    # Content drift.
    models = json.loads((packaged / "models.v1.json").read_text(encoding="utf-8"))
    models["models"][0]["label"] = "Edited Copy"
    (packaged / "models.v1.json").write_text(json.dumps(models, indent=2), encoding="utf-8")
    drift = sync_core_catalog.collect_drift()
    assert any("content drift" in line for line in drift)

    # Missing file drift.
    (packaged / "capabilities.v1.json").unlink()
    drift = sync_core_catalog.collect_drift()
    assert any("missing" in line for line in drift)

    # Extra file drift.
    shutil.copytree(CANONICAL_DIR, packaged, dirs_exist_ok=True)
    (packaged / "extra.v1.json").write_text("{}", encoding="utf-8")
    drift = sync_core_catalog.collect_drift()
    assert any("untracked" in line for line in drift)

    # --write resynchronizes byte-identically and removes the extra file.
    synced = sync_core_catalog.write()
    assert sync_core_catalog.collect_drift() == []
    assert not (packaged / "extra.v1.json").exists()
    assert "workflows.v1.json" in synced
    assert "schemas/workflow-request.v1.schema.json" in synced


@pytest.mark.portable
def test_packaged_copy_loads_standalone(tmp_path):
    """The packaged copy alone (no repository catalog dir) must satisfy the
    canonical catalog validators, schemas included in the file set."""
    isolated = tmp_path / "catalog"
    shutil.copytree(PACKAGED_DIR, isolated)
    catalogs = validate_catalogs(isolated)
    assert {w["workflow_id"] for w in catalogs["workflows"]} == {
        "normal_stems",
        "drum_kit_direct",
        "drum_kit_split",
    }
    schema_files = {path.name for path in (isolated / "schemas").glob("*.json")}
    assert schema_files == {
        "artifact.v1.schema.json",
        "import-plan.v1.schema.json",
        "source-plan.v1.schema.json",
        "stage-spec.v1.schema.json",
        "workflow-request.v1.schema.json",
        "workflow-result.v1.schema.json",
    }
