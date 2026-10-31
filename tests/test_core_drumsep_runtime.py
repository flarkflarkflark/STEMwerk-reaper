"""Portable regressions for the Core-owned DrumSep selector boundary."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
PROCESSOR = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import drumsep_runtime, model_assets  # noqa: E402


def _load_processor():
    spec = importlib.util.spec_from_file_location("core_drumsep_wrapper_test", PROCESSOR)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _touch_python(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
    return path


@pytest.mark.portable
def test_core_selector_executes_without_legacy_import(tmp_path):
    source = Path(drumsep_runtime.__file__).read_text(encoding="utf-8")
    assert "audio_separator_process" not in source
    cpu = _touch_python(tmp_path / ".venv-drumsep" / "bin" / "python")

    selected, kind, info = drumsep_runtime.select_drumsep_runtime(
        "cpu",
        tmp_path,
        platform_name="linux",
        os_name="posix",
        machine="x86_64",
        environ={},
        verify_runtime=lambda path, **kwargs: (path == cpu, "ok", {"ok": True}),
        sleep=lambda _seconds: None,
    )

    assert (selected, kind) == (cpu, "cpu")
    assert info["selection_policy"] == "explicit_cpu"


@pytest.mark.portable
def test_legacy_wrapper_and_core_selector_are_equivalent(tmp_path, monkeypatch):
    legacy = _load_processor()
    assert legacy.DIRECT_DKS_MODEL_EXPECTED_SHA256 == model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256
    cpu = _touch_python(tmp_path / ".venv-drumsep" / "bin" / "python")

    def verify(path, **kwargs):
        return (path == cpu, "ok" if path == cpu else "missing", {"ok": True})

    monkeypatch.setattr(legacy, "_verify_drumsep_runtime", verify)
    monkeypatch.setattr(legacy.sys, "platform", "linux")
    monkeypatch.setattr(legacy.platform, "machine", lambda: "x86_64")
    wrapped = legacy._select_drumsep_runtime("cpu", tmp_path)
    direct = drumsep_runtime.select_drumsep_runtime(
        "cpu",
        tmp_path,
        platform_name="linux",
        os_name=legacy.os.name,
        machine="x86_64",
        environ=legacy.os.environ,
        verify_runtime=verify,
        sleep=lambda _seconds: None,
    )
    assert wrapped == direct


@pytest.mark.portable
def test_candidate_order_and_missing_versus_broken_are_preserved(tmp_path):
    state_python = _touch_python(tmp_path / "state-python")
    fallback = _touch_python(tmp_path / "fallback-python")
    calls = []

    def verify(path, **kwargs):
        calls.append(path)
        if path == state_python:
            return False, "ImportError: controlled", {}
        return False, "missing", {}

    selected, detail, payload, attempts = drumsep_runtime.probe_drumsep_runtime_candidates(
        [state_python, fallback], verify_runtime=verify
    )
    assert selected is None
    assert detail == "ImportError: controlled"
    assert payload == {}
    assert calls == [state_python, fallback]
    assert [attempt["detail"] for attempt in attempts] == [
        "ImportError: controlled",
        "missing",
    ]


@pytest.mark.portable
def test_linux_cuda_request_accepts_only_attributed_cpu_fallback(tmp_path):
    cpu = _touch_python(tmp_path / ".venv-drumsep" / "bin" / "python")

    def verify(path, require_cuda=False, require_gpu=False, **kwargs):
        if path == cpu and not require_cuda and not require_gpu:
            return True, "ok", {"ok": True}
        return False, "missing", {}

    selected, kind, info = drumsep_runtime.select_drumsep_runtime(
        "cuda:0",
        tmp_path,
        platform_name="linux",
        os_name="posix",
        machine="x86_64",
        environ={},
        verify_runtime=verify,
        sleep=lambda _seconds: None,
    )
    assert (selected, kind) == (cpu, "cpu")
    assert info["selection_policy"] == "fallback_cpu"
    assert info["fallback_reason"].startswith("cuda_skipped:missing")

    selected, reason, info = drumsep_runtime.select_drumsep_runtime(
        "cuda:0",
        tmp_path,
        platform_name="win32",
        os_name="nt",
        machine="AMD64",
        environ={},
        verify_runtime=verify,
        sleep=lambda _seconds: None,
    )
    assert selected is None
    assert reason in {"missing", "broken"}
    assert info["selection_policy"] == "explicit_cuda"


@pytest.mark.portable
def test_apple_silicon_mps_acceptance(tmp_path):
    main = _touch_python(tmp_path / ".venv" / "bin" / "python")
    state = tmp_path / "state"
    state.mkdir()
    state.joinpath("ready_to_go.env").write_text(
        "DRUMSEP_READY_RUNTIME=mps\n"
        "DRUMSEP_READY_RUNTIME_STATUS=ok\n"
        "DRUMSEP_READY_MODEL_STATUS=ok\n"
        "MAIN_RUNTIME_STATUS=ok\n"
        "READY_TO_GO_STATUS=ok\n",
        encoding="utf-8",
    )

    selected, kind, info = drumsep_runtime.select_drumsep_runtime(
        "mps",
        tmp_path,
        platform_name="darwin",
        os_name="posix",
        machine="arm64",
        environ={},
        verify_runtime=lambda path, require_mps=False, **kwargs: (
            path == main and require_mps,
            "ok",
            {"ok": True, "mps_built": True, "mps_available": True},
        ),
        sleep=lambda _seconds: None,
    )
    assert (selected, kind) == (main, "mps")
    assert info["selection_policy"] == "explicit_mps"


@pytest.mark.portable
def test_verifier_rejects_malformed_success_and_uses_isolated_boundary(tmp_path):
    python = _touch_python(tmp_path / "python")
    calls = []

    class ControlledSubprocess:
        PIPE = subprocess.PIPE
        TimeoutExpired = subprocess.TimeoutExpired

        @staticmethod
        def run(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, "{}", "")

    ok, detail, payload = drumsep_runtime.verify_drumsep_runtime(
        python,
        subprocess_module=ControlledSubprocess,
        environ={"PYTHONPATH": "/controlled", "PYTHONHOME": "/controlled"},
        os_name="posix",
    )
    assert not ok
    assert detail == "verify_malformed_output:missing_ok"
    assert payload == {}
    command, kwargs = calls[0]
    assert command[1:4] == ["-I", "-B", "-c"]
    assert kwargs["timeout"] == drumsep_runtime.DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS
    assert kwargs["cwd"]
    assert "PYTHONPATH" not in kwargs["env"]
    assert "PYTHONHOME" not in kwargs["env"]
    assert kwargs["env"]["PYTHONDONTWRITEBYTECODE"] == "1"
