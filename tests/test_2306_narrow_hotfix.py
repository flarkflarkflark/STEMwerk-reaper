import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

import pytest


MACOS_BOOTSTRAP = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")
DRUMSEP_HELPER = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")


def _load_drumsep_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_2306_drumsep", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_apple_silicon_missing_payload_fails_before_runtime_cleanup(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / MACOS_BOOTSTRAP.name
    shutil.copy2(MACOS_BOOTSTRAP, bootstrap)

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    uname = fake_bin / "uname"
    uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
    uname.chmod(0o755)

    runtime = tmp_path / "runtime"
    sentinel = runtime / ".venv" / "sentinel"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text("preserved\n", encoding="utf-8")
    ready = runtime / "state" / "ready_to_go.env"
    ready.parent.mkdir(parents=True)
    ready.write_text("READY_TO_GO_STATUS=ok\nMAIN_RUNTIME_STATUS=ok\n", encoding="utf-8")
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = subprocess.run(
        [
            "/bin/sh",
            str(bootstrap),
            "--runtime-base",
            str(runtime),
            "--state-file",
            str(state),
            "--log-file",
            str(log),
            "--mode",
            "rebuild-venv",
        ],
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    ready_text = ready.read_text(encoding="utf-8")
    assert "READY_TO_GO_STATUS=missing" in ready_text
    assert "MAIN_RUNTIME_STATUS=missing" in ready_text
    assert "apple_silicon_requires_bundled_payload" in ready_text
    assert "STATUS_REASON=apple_silicon_requires_bundled_payload" in state.read_text(encoding="utf-8")


def _managed_cache(tmp_path, alias_bytes=None):
    helper = _load_drumsep_helper()
    canonical = tmp_path / helper.DRUMSEP_MODEL_FILENAME
    canonical.write_bytes(b"managed-checkpoint")
    yaml_path = tmp_path / helper.DRUMSEP_MODEL_YAML
    yaml_path.write_text("audio: {}\nmodel: {}\ntraining: {}\n", encoding="utf-8")
    if alias_bytes is not None:
        (tmp_path / helper.DRUMSEP_MODEL_ALIAS).write_bytes(alias_bytes)
    return helper, canonical, yaml_path


def test_asep_0443_catalog_alias_uses_canonical_checkpoint_without_copy(tmp_path):
    helper, canonical, yaml_path = _managed_cache(tmp_path)
    before = {path.name: path.read_bytes() for path in tmp_path.iterdir()}

    resolution = helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)

    assert resolution.model_name == helper.DRUMSEP_MODEL_FILENAME
    assert resolution.model_path == canonical
    assert resolution.config_path == yaml_path
    assert {path.name: path.read_bytes() for path in tmp_path.iterdir()} == before
    assert not (tmp_path / helper.DRUMSEP_MODEL_ALIAS).exists()


def test_conflicting_catalog_alias_fails_closed_without_mutation(tmp_path):
    helper, _canonical, _yaml_path = _managed_cache(tmp_path, alias_bytes=b"different")
    before = {path.name: path.read_bytes() for path in tmp_path.iterdir()}

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)

    assert exc_info.value.reason == "drumsep_checkpoint_alias_checksum_mismatch"
    assert {path.name: path.read_bytes() for path in tmp_path.iterdir()} == before


def test_catalog_adapter_returns_existing_managed_files_without_network(tmp_path):
    helper, canonical, yaml_path = _managed_cache(tmp_path)
    resolution = helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)
    fallback_calls = []

    class FakeSeparator:
        def download_model_files(self, model_filename):
            fallback_calls.append(model_filename)
            raise AssertionError("managed DrumSep must not use catalog/network fallback")

    separator = FakeSeparator()
    helper._configure_managed_drumsep_checkpoint(separator, resolution)
    result = separator.download_model_files(helper.DRUMSEP_MODEL_ALIAS)

    assert result == (
        helper.DRUMSEP_MODEL_FILENAME,
        "MDXC",
        "STEMwerk managed DrumSep 6stem",
        str(canonical),
        yaml_path.name,
    )
    assert fallback_calls == []
