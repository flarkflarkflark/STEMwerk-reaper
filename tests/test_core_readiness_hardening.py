"""Hardening regressions for the first Core readiness slice.

These tests use only temporary interpreters, files, and controlled evidence.
They never inspect installed ML packages or hardware.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import venv
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"
INTERNAL = ROOT / "scripts" / "reaper" / "_internal"

for _path in (CORE_SRC, INTERNAL):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from stemwerk_core import readiness, readiness_collect  # noqa: E402
from stemwerk_core.readiness import ReadinessError, ReadinessRequest  # noqa: E402
from stemwerk_core.verdicts import FAIL, NOT_APPLICABLE, PASS, UNAVAILABLE  # noqa: E402
import stemwerk_readiness_adapter as adapter  # noqa: E402


def _normal_fixture():
    return {
        "kind": readiness.FIXTURE_KIND,
        "schema_version": readiness.SCHEMA_VERSION,
        "platform_system": "linux",
        "stages": [
            {
                "stage_id": "separate_normal",
                "runtime": {"verdict": PASS},
                "capability": {
                    "verdict": PASS,
                    "resolution": {
                        "requested": "auto",
                        "resolved_device_id": "cpu",
                        "resolved_device_name": "CPU",
                        "resolved_backend": "cpu",
                        "available_devices": [
                            {"id": "cpu", "name": "CPU", "type": "cpu"}
                        ],
                    },
                },
                "model": {"verdict": PASS},
            }
        ],
        "ffmpeg": {"verdict": PASS},
    }


def _assess_fixture(fixture):
    return readiness.assess_readiness(
        ReadinessRequest(workflow_id="normal_stems", evidence_mode="fixture"),
        fixture=fixture,
        catalog_dir=CATALOG_DIR,
    )


def _tree_inventory(root: Path):
    inventory = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        stat = path.lstat()
        if path.is_file():
            inventory[relative] = (
                "file",
                hashlib.sha256(path.read_bytes()).hexdigest(),
                stat.st_mode,
                stat.st_size,
            )
        elif path.is_dir():
            inventory[relative] = ("directory", stat.st_mode)
        else:
            inventory[relative] = ("other", stat.st_mode)
    return inventory


def _make_probe_venv(root: Path) -> Path:
    venv.EnvBuilder(with_pip=False).create(root)
    python = root / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    purelib = subprocess.check_output(
        [str(python), "-c", "import sysconfig; print(sysconfig.get_path('purelib'))"],
        text=True,
    ).strip()
    packages = Path(purelib)
    packages.joinpath("sitecustomize.py").write_text(
        """
import socket
def _blocked(*args, **kwargs):
    raise AssertionError('network access attempted')
socket.create_connection = _blocked
socket.socket.connect = _blocked
socket.socket.connect_ex = _blocked
""".lstrip(),
        encoding="utf-8",
    )
    simple_modules = ("audio_separator", "numpy", "onnx", "onnx2torch", "torchaudio", "torchvision")
    for name in simple_modules:
        packages.joinpath(f"{name}.py").write_text("__version__ = 'test'\n", encoding="utf-8")
    packages.joinpath("audio_separator.py").write_text(
        "import socket\n"
        "assert socket.create_connection.__name__ == '_blocked'\n"
        "__version__ = 'test'\n",
        encoding="utf-8",
    )
    packages.joinpath("onnxruntime.py").write_text(
        "__version__ = 'test'\ndef get_available_providers():\n    return ['CPUExecutionProvider']\n",
        encoding="utf-8",
    )
    packages.joinpath("torch.py").write_text(
        """
class _Cuda:
    @staticmethod
    def is_available(): return False
    @staticmethod
    def device_count(): return 0
    @staticmethod
    def get_device_name(index): raise IndexError(index)
cuda = _Cuda()
class _Version:
    cuda = None
    hip = None
version = _Version()
class _Mps:
    @staticmethod
    def is_built(): return False
    @staticmethod
    def is_available(): return False
class _Backends:
    mps = _Mps()
backends = _Backends()
__version__ = 'test'
""".lstrip(),
        encoding="utf-8",
    )
    return python


@pytest.mark.portable
def test_probe_helper_owns_environment_scratch_and_bytecode_policy(tmp_path, monkeypatch):
    protected = tmp_path / "protected"
    protected.mkdir()
    protected.joinpath("probe_dependency.py").write_text("VALUE = 7\n", encoding="utf-8")
    inherited_path = str(protected)
    monkeypatch.setenv("PYTHONPATH", inherited_path)
    monkeypatch.delenv("PYTHONDONTWRITEBYTECODE", raising=False)
    before = _tree_inventory(protected)
    source = f"""
import json, os, sys
sys.path.insert(0, {str(protected)!r})
import probe_dependency
print(json.dumps({{
    'value': probe_dependency.VALUE,
    'cwd': os.getcwd(),
    'pythonpath': os.environ.get('PYTHONPATH'),
    'dont_write_bytecode': os.environ.get('PYTHONDONTWRITEBYTECODE'),
}}))
"""
    payload = readiness_collect._run_probe(Path(sys.executable), source)
    assert payload["value"] == 7
    assert payload["pythonpath"] is None
    assert payload["dont_write_bytecode"] == "1"
    assert Path(payload["cwd"]).parent != ROOT
    assert _tree_inventory(protected) == before


@pytest.mark.portable
@pytest.mark.parametrize(
    "source,timeout,detail",
    [
        ("pass", 10, "probe produced no output"),
        ("raise RuntimeError('controlled failure')", 10, "controlled failure"),
        ("import time; time.sleep(1)", 0.01, "TimeoutExpired"),
    ],
)
def test_unmocked_probe_failure_timeout_and_silent_payloads_fail_closed(
    tmp_path, source, timeout, detail
):
    protected = tmp_path / "protected"
    protected.mkdir()
    protected.joinpath("sentinel").write_bytes(b"unchanged")
    before = _tree_inventory(protected)
    payload = readiness_collect._run_probe(Path(sys.executable), source, timeout=timeout)
    assert detail in payload["probe_error"]
    assert _tree_inventory(protected) == before


@pytest.mark.portable
def test_collectors_are_unavailable_without_a_supported_interpreter():
    runtime = readiness_collect.collect_runtime_imports(
        None, source_label="unsupported", runtime_profile="main"
    )
    capability = readiness_collect.collect_normal_stems_resolution(
        "auto", None, source_label="unsupported"
    )
    assert runtime["verdict"] == UNAVAILABLE
    assert capability["verdict"] == UNAVAILABLE


@pytest.mark.portable
def test_real_core_probes_bootstrap_current_core_in_selected_interpreter(tmp_path, monkeypatch):
    probe_root = tmp_path / "probe-venv"
    python = _make_probe_venv(probe_root)
    unrelated = tmp_path / "unrelated"
    unrelated_package = unrelated / "stemwerk_core"
    unrelated_package.mkdir(parents=True)
    unrelated_package.joinpath("__init__.py").write_text(
        "raise AssertionError('unrelated stemwerk_core imported')\n", encoding="utf-8"
    )
    monkeypatch.setenv("PYTHONPATH", str(unrelated))
    before = _tree_inventory(tmp_path)

    imports = readiness_collect.collect_runtime_imports(
        python, source_label="managed", runtime_profile="main"
    )
    resolution = readiness_collect.collect_normal_stems_resolution(
        "auto", python, source_label="managed"
    )

    assert imports["verdict"] == PASS, imports
    assert resolution["verdict"] == PASS, resolution
    expected_core = (CORE_SRC / "stemwerk_core" / "__init__.py").resolve()
    assert Path(imports["evidence"]["core_origin"]).resolve() == expected_core
    assert Path(resolution["evidence"]["core_origin"]).resolve() == expected_core
    assert Path(imports["evidence"]["python_executable"]).resolve() == python.resolve()
    assert Path(resolution["evidence"]["python_executable"]).resolve() == python.resolve()
    after = _tree_inventory(tmp_path)
    assert not any("__pycache__" in name or name.endswith(".pyc") for name in after)
    assert {name: digest for name, digest in after.items() if name in before} == before


@pytest.mark.portable
def test_core_probe_rejects_wrong_origin_and_interpreter_identity(tmp_path):
    wrong_core = tmp_path / "wrong" / "stemwerk_core"
    wrong_core.mkdir(parents=True)
    wrong_core.joinpath("__init__.py").write_text("\n", encoding="utf-8")
    payload = readiness_collect._run_core_probe(
        Path(sys.executable),
        "import json; print(json.dumps({'ok': True}))",
        core_source_dir=wrong_core.parent,
    )
    assert "probe_error" in payload
    assert "Core origin mismatch" in payload["probe_error"]

    payload = readiness_collect._run_core_probe(
        Path(sys.executable),
        "import json; print(json.dumps({'ok': True}))",
        expected_python_executable=tmp_path / "different-python",
    )
    assert "probe_error" in payload
    assert "interpreter identity mismatch" in payload["probe_error"]


@pytest.mark.portable
@pytest.mark.parametrize("location", ["runtime", "model", "ffmpeg"])
def test_required_not_applicable_evidence_cannot_pass(location):
    fixture = _normal_fixture()
    if location == "ffmpeg":
        fixture["ffmpeg"] = {"verdict": NOT_APPLICABLE}
    else:
        fixture["stages"][0][location] = {"verdict": NOT_APPLICABLE}
    report = _assess_fixture(fixture)
    assert report["readiness"]["verdict"] == UNAVAILABLE


@pytest.mark.portable
def test_fixture_normalization_is_recursive_and_removes_selector_provenance():
    fixture = _normal_fixture()
    fixture["stages"][0]["capability"]["evidence"] = {
        "source": "collected",
        "evidence_kind": "real_execution",
        "event_id": "keep-this-id",
        "nested": {
            "source": "collected",
            "evidence_kind": "real_probe_resolution",
            "selector_provenance": "production_select_drumsep_runtime",
        },
    }
    fixture["stages"][0]["capability"]["resolution"]["selection_info"] = {
        "selector_provenance": "production_select_drumsep_runtime",
        "nested": {"source": "collected", "evidence_kind": "real_execution"},
    }
    report = _assess_fixture(fixture)
    serialized = json.dumps(report, sort_keys=True)
    assert "selector_provenance" not in serialized
    assert "real_execution" not in serialized
    assert "real_probe_resolution" not in serialized
    assert '"source": "collected"' not in serialized
    assert "keep-this-id" in serialized


@pytest.mark.portable
def test_malformed_fixture_evidence_has_stable_error():
    fixture = _normal_fixture()
    fixture["stages"][0]["runtime"]["evidence"] = ["not", "a", "mapping"]
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture(fixture)
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID

    fixture = _normal_fixture()
    fixture["stages"][0]["runtime"]["evidence"] = []
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture(fixture)
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID

    fixture = _normal_fixture()
    fixture["stages"][0]["capability"]["resolution"] = []
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture(fixture)
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID


@pytest.mark.portable
def test_demucs_descriptor_and_weight_checks_fail_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(readiness.managed_runtime, "managed_model_cache_dir", lambda: tmp_path)
    descriptor = tmp_path / "htdemucs.yaml"

    descriptor.write_text("not a model descriptor\n", encoding="utf-8")
    component = readiness._demucs_presence_component("htdemucs", {"source": "collected"})
    assert component["verdict"] == FAIL

    descriptor.write_text("models: []\n", encoding="utf-8")
    component = readiness._demucs_presence_component("htdemucs", {"source": "collected"})
    assert component["verdict"] == FAIL

    descriptor.write_text("models: ['../outside']\n", encoding="utf-8")
    component = readiness._demucs_presence_component("htdemucs", {"source": "collected"})
    assert component["verdict"] == FAIL

    descriptor.write_text("models: ['abc123']\n", encoding="utf-8")
    weight = tmp_path / "abc123-test.th"
    weight.write_bytes(b"weights")
    component = readiness._demucs_presence_component("htdemucs", {"source": "collected"})
    assert component["verdict"] == PASS

    monkeypatch.setattr(
        readiness.model_assets,
        "demucs_yaml_weight_prefixes",
        lambda path: (_ for _ in ()).throw(OSError("unreadable descriptor")),
    )
    component = readiness._demucs_presence_component("htdemucs", {"source": "collected"})
    assert component["verdict"] == FAIL


@pytest.mark.portable
def test_supplied_model_asset_evidence_requires_readable_nonempty_verified_set(
    tmp_path, monkeypatch
):
    base = {"source": "collected"}
    empty = readiness._verify_supplied_assets(
        "drumsep_mdx23c", {"base_dir": str(tmp_path), "assets": []}, base
    )
    assert empty["verdict"] == FAIL

    asset = tmp_path / "model.ckpt"
    asset.write_bytes(b"model")
    expected = hashlib.sha256(b"model").hexdigest()
    valid = {"base_dir": str(tmp_path), "assets": [{"name": asset.name, "sha256": expected}]}
    assert readiness._verify_supplied_assets("drumsep_mdx23c", valid, base)["verdict"] == PASS

    monkeypatch.setattr(
        readiness.model_assets,
        "file_sha256",
        lambda path: (_ for _ in ()).throw(OSError("unreadable weight")),
    )
    unreadable = readiness._verify_supplied_assets("drumsep_mdx23c", valid, base)
    assert unreadable["verdict"] == FAIL
    assert unreadable["reason_code"] == readiness.REASON_RUNTIME_EVIDENCE_BROKEN


def _adapter_live_report(
    tmp_path,
    monkeypatch,
    *,
    requested="cuda",
    runtime_kind="cpu",
    selection_info=None,
    runtime_verdict=PASS,
    workflow_id="drum_kit_direct",
):
    checkpoint = tmp_path / "drumsep.ckpt"
    checkpoint.write_bytes(b"checkpoint")
    digest = hashlib.sha256(b"checkpoint").hexdigest()
    calls = []

    def core_probe(python_exe, src, timeout=60, **kwargs):
        calls.append((requested, tmp_path / "runtime"))
        return {
            "selected_python": (
                "" if runtime_kind in {"missing", "broken"} else str(sys.executable)
            ),
            "runtime_kind": runtime_kind,
            "selection_info": dict(selection_info or {}),
            "core_origin": str(CORE_SRC / "stemwerk_core" / "__init__.py"),
            "python_executable": str(python_exe),
        }

    monkeypatch.setattr(readiness_collect, "_run_core_probe", core_probe)
    monkeypatch.setattr(
        adapter.model_assets,
        "DIRECT_DKS_MODEL_EXPECTED_SHA256",
        {checkpoint.name: digest},
    )
    monkeypatch.setattr(
        readiness_collect,
        "collect_runtime_imports",
        lambda python_exe, *, source_label, runtime_profile="main": {
            "verdict": runtime_verdict if runtime_profile == "drumsep" else PASS,
            "reason": "controlled broken runtime" if runtime_profile == "drumsep" else "",
            "evidence": {
                "source": "collected",
                "evidence_kind": "required_imports",
                "runtime_source": source_label,
            },
        },
    )
    monkeypatch.setattr(
        readiness_collect,
        "collect_ffmpeg",
        lambda: {
            "verdict": PASS,
            "path": "/controlled/ffmpeg",
            "evidence": {"source": "collected", "evidence_kind": "ffmpeg_usability_probe"},
        },
    )
    report = readiness.assess_readiness(
        ReadinessRequest(workflow_id=workflow_id, requested_device=requested),
        catalog_dir=CATALOG_DIR,
        collectors={"drum_kit": adapter.build_drum_kit_collector(tmp_path / "runtime")},
        model_asset_providers={
            "drumsep_mdx23c": adapter.build_drum_kit_model_asset_provider(tmp_path)
        },
    )
    return report, calls


@pytest.mark.portable
def test_real_adapter_collector_accepts_linux_attributed_fallback(tmp_path, monkeypatch):
    monkeypatch.setattr(readiness, "sys", SimpleNamespace(platform="linux"))
    report, calls = _adapter_live_report(
        tmp_path,
        monkeypatch,
        selection_info={
            "selection_policy": "fallback_cpu",
            "fallback_reason": "cuda_skipped: controlled unavailable runtime",
        },
    )
    assert calls == [("cuda", tmp_path / "runtime")]
    assert report["readiness"]["verdict"] == PASS
    capability = report["stages"][0]["components"]["capability"]
    assert capability["evidence"]["selector_provenance"] == adapter.SELECTOR_PROVENANCE


@pytest.mark.portable
@pytest.mark.parametrize("platform_system", ["linux", "darwin"])
def test_real_adapter_collector_rejects_invalid_or_off_linux_fallback(
    tmp_path, monkeypatch, platform_system
):
    selection_info = {"selection_policy": "fallback_cpu"}
    if platform_system == "darwin":
        selection_info["fallback_reason"] = "cuda_skipped: controlled unavailable runtime"
        monkeypatch.setattr(readiness, "sys", SimpleNamespace(platform="darwin"))
    else:
        monkeypatch.setattr(readiness, "sys", SimpleNamespace(platform="linux"))
    report, _ = _adapter_live_report(
        tmp_path, monkeypatch, selection_info=selection_info
    )
    assert report["readiness"]["verdict"] == FAIL
    assert report["components"]["feasibility"]["reason_code"] == "backend_unavailable"


@pytest.mark.portable
def test_real_adapter_collector_broken_runtime_fails_closed(tmp_path, monkeypatch):
    report, _ = _adapter_live_report(
        tmp_path,
        monkeypatch,
        requested="cpu",
        runtime_kind="broken",
        selection_info={"detail": "controlled broken selector runtime"},
    )
    assert report["stages"][0]["components"]["capability"]["verdict"] == FAIL
    assert report["stages"][0]["components"]["runtime"]["verdict"] == UNAVAILABLE
    assert report["readiness"]["verdict"] == FAIL


@pytest.mark.portable
def test_real_adapter_collector_does_not_mask_kit_split_stage1_failure(
    tmp_path, monkeypatch
):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    model_dir.joinpath("htdemucs.yaml").write_text("models: ['abc123']\n", encoding="utf-8")
    model_dir.joinpath("abc123-test.th").write_bytes(b"weights")
    monkeypatch.setenv("AUDIO_SEPARATOR_MODEL_DIR", str(model_dir))
    monkeypatch.setattr(
        readiness_collect,
        "collect_normal_stems_resolution",
        lambda requested, python_exe, *, source_label: {
            "verdict": FAIL,
            "reason": "controlled stage-1 resolution failure",
            "evidence": {"source": "collected", "evidence_kind": "real_probe_resolution"},
        },
    )
    report, calls = _adapter_live_report(
        tmp_path,
        monkeypatch,
        requested="cpu",
        workflow_id="drum_kit_split",
    )
    assert calls == [("cpu", tmp_path / "runtime")]
    assert report["stages"][0]["components"]["capability"]["verdict"] == FAIL
    assert report["stages"][1]["components"]["capability"]["verdict"] == PASS
    assert report["readiness"]["verdict"] == FAIL
