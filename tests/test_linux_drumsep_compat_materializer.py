from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
REQUIRED_LAYOUT = (
    "audio_separator_process.py",
    "_internal/STEMwerk_Managed_Python.sh",
    "vendor/stemwerk-core/pyproject.toml",
    "vendor/stemwerk-core/src/stemwerk_core/__init__.py",
    "vendor/stemwerk-core/src/stemwerk_core/separator.py",
)
CONTRACT = json.loads(
    (ROOT / "tools/assets/drumsep/compatibility_config_contract.json").read_text(encoding="utf-8")
)
CANONICAL = (ROOT / "tools/assets/drumsep" / CONTRACT["filename"]).read_bytes()
LEGACY = CANONICAL.replace(b"\n", b"\r\n")


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


@pytest.fixture
def materializer(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    scripts_dir = tmp_path / "scripts"
    source_dir = scripts_dir / "assets/drumsep"
    source_dir.mkdir(parents=True)
    bootstrap = scripts_dir / BOOTSTRAP.name
    shutil.copy2(BOOTSTRAP, bootstrap)
    for relative in REQUIRED_LAYOUT:
        target = scripts_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture\n", encoding="utf-8")
    source = source_dir / CONTRACT["filename"]
    source.write_bytes(CANONICAL)
    data_home = tmp_path / "data"
    target = data_home / "STEMwerk/models" / CONTRACT["filename"]
    log = tmp_path / "materializer.log"
    return bootstrap, source, target, log


def _run(bootstrap: Path, log: Path, data_home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(bootstrap),
            "--runtime-base",
            str(data_home / "STEMwerk"),
            "--log-file",
            str(log),
            "--mode",
            "materialize-drumsep-compat-only",
        ],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "XDG_DATA_HOME": str(data_home)},
    )


@pytest.mark.parametrize(
    ("initial", "expected_status", "expected_reason"),
    [
        (None, "created", "materialized_from_online_inventory"),
        (CANONICAL, "no_op", "already_materialized"),
        (LEGACY, "migrated_legacy_crlf", "migrated_known_legacy_crlf"),
    ],
    ids=["missing", "canonical", "legacy"],
)
def test_materializer_success_cases(
    materializer: tuple[Path, Path, Path, Path],
    initial: bytes | None,
    expected_status: str,
    expected_reason: str,
) -> None:
    bootstrap, source, target, log = materializer
    if initial is not None:
        target.parent.mkdir(parents=True)
        target.write_bytes(initial)

    result = _run(bootstrap, log, target.parents[2])

    assert result.returncode == 0, result.stderr
    assert target.read_bytes() == CANONICAL
    markers = log.read_text(encoding="utf-8")
    assert f"linux_drumsep_config_source_path={source}" in markers
    assert f"linux_drumsep_config_source_size={len(CANONICAL)}" in markers
    assert f"linux_drumsep_config_source_sha256={_sha(CANONICAL)}" in markers
    assert "linux_drumsep_config_source_status=canonical" in markers
    assert f"linux_drumsep_config_target_status={expected_status}" in markers
    assert f"linux_drumsep_config_target_reason={expected_reason}" in markers


def test_materializer_rejects_unknown_target_without_mutation(
    materializer: tuple[Path, Path, Path, Path],
) -> None:
    bootstrap, _source, target, log = materializer
    unknown = b"user-owned-unknown-config\n"
    target.parent.mkdir(parents=True)
    target.write_bytes(unknown)

    result = _run(bootstrap, log, target.parents[2])

    assert result.returncode != 0
    assert target.read_bytes() == unknown
    assert not list(target.parent.glob(f"{target.name}.tmp.*"))
    markers = log.read_text(encoding="utf-8")
    assert "linux_drumsep_config_source_status=canonical" in markers
    assert "linux_drumsep_config_target_status=failed" in markers
    assert "linux_drumsep_config_target_reason=existing_checksum_mismatch" in markers


@pytest.mark.parametrize("bad_source", [None, b"invalid-source\n"], ids=["missing", "invalid"])
def test_materializer_validates_source_before_target_and_fails_closed(
    materializer: tuple[Path, Path, Path, Path], bad_source: bytes | None
) -> None:
    bootstrap, source, target, log = materializer
    original = LEGACY
    target.parent.mkdir(parents=True)
    target.write_bytes(original)
    before_stat = target.stat()
    if bad_source is None:
        source.unlink()
    else:
        source.write_bytes(bad_source)

    result = _run(bootstrap, log, target.parents[2])

    assert result.returncode != 0
    assert target.read_bytes() == original
    assert not list(target.parent.glob(f"{target.name}.tmp.*"))
    after_stat = target.stat()
    assert after_stat.st_mtime_ns == before_stat.st_mtime_ns
    markers = log.read_text(encoding="utf-8")
    if bad_source is None:
        assert "staged_layout_validation=failed:assets/drumsep/config_drumsep_mdx23c.yaml" in markers
        assert "linux_drumsep_config_source_status=" not in markers
    else:
        assert "linux_drumsep_config_source_status=integrity_mismatch" in markers
    assert "linux_drumsep_config_target_" not in markers


def test_generated_legacy_fixture_matches_closed_contract() -> None:
    assert len(LEGACY) == CONTRACT["legacy_crlf"]["size"]
    assert _sha(LEGACY) == CONTRACT["legacy_crlf"]["sha256"]
