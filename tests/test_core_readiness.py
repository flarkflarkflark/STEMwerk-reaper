"""Focused tests for the first Core readiness slice (stemwerk_core.readiness).

Covers the client-neutral API, the ``python -m stemwerk_core.readiness`` CLI
and the REAPER-side Python adapter against identical injected evidence.
Simulated (fixture) evaluations are fully deterministic; live-collection
tests monkeypatch the bounded-subprocess collectors so no hardware, managed
runtime, or network is ever touched.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
INTERNAL = ROOT / "scripts" / "reaper" / "_internal"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"

for _path in (str(CORE_SRC), str(INTERNAL)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from stemwerk_core import readiness  # noqa: E402
from stemwerk_core.readiness import ReadinessError, ReadinessRequest  # noqa: E402
from stemwerk_core.verdicts import FAIL, PASS, SKIPPED, UNAVAILABLE  # noqa: E402

import stemwerk_readiness_adapter as adapter  # noqa: E402


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------


def _normal_capability(requested="auto", device_id="cuda:0", name="NVIDIA RTX", backend="cuda"):
    return {
        "verdict": PASS,
        "resolution": {
            "requested": requested,
            "resolved_device_id": device_id,
            "resolved_device_name": name,
            "resolved_backend": backend,
            "available_devices": [{"id": device_id, "name": name}],
        },
    }


def _drumsep_capability(requested="auto", kind="cuda", selection_info=None):
    return {
        "verdict": PASS,
        "resolution": {
            "requested": requested,
            "resolved_device_id": kind,
            "resolved_device_name": kind,
            "resolved_backend": kind,
            "selection_info": dict(selection_info or {}),
        },
    }


def _pass_component():
    return {"verdict": PASS}


def _fixture_normal_stems(**capability_kwargs):
    return {
        "kind": readiness.FIXTURE_KIND,
        "schema_version": "1.0.0",
        "platform_system": "linux",
        "stages": [
            {
                "stage_id": "separate_normal",
                "runtime": _pass_component(),
                "capability": _normal_capability(**capability_kwargs),
                "model": _pass_component(),
            }
        ],
        "ffmpeg": _pass_component(),
    }


def _fixture_drum_kit_direct(**capability_kwargs):
    return {
        "kind": readiness.FIXTURE_KIND,
        "schema_version": "1.0.0",
        "platform_system": "linux",
        "stages": [
            {
                "stage_id": "drumsep_direct",
                "runtime": _pass_component(),
                "capability": _drumsep_capability(**capability_kwargs),
                "model": _pass_component(),
            }
        ],
        "ffmpeg": _pass_component(),
    }


def _fixture_drum_kit_split():
    return {
        "kind": readiness.FIXTURE_KIND,
        "schema_version": "1.0.0",
        "platform_system": "linux",
        "stages": [
            {
                "stage_id": "separate_normal_for_kit",
                "runtime": _pass_component(),
                "capability": _normal_capability(),
                "model": _pass_component(),
            },
            {
                "stage_id": "drumsep_kit",
                "runtime": _pass_component(),
                "capability": _drumsep_capability(),
                "model": _pass_component(),
            },
        ],
        "ffmpeg": _pass_component(),
    }


def _assess_fixture(workflow_id, fixture, **request_kwargs):
    request = ReadinessRequest(workflow_id=workflow_id, evidence_mode="fixture", **request_kwargs)
    return readiness.assess_readiness(request, fixture=fixture, catalog_dir=CATALOG_DIR)


def _walk_evidence(node):
    """Yield every evidence mapping in a report, wherever it appears."""
    if isinstance(node, dict):
        if set(node) >= {"source", "evidence_kind"}:
            yield node
        for value in node.values():
            yield from _walk_evidence(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_evidence(item)


# ---------------------------------------------------------------------------
# Import boundary and isolation
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_import_boundary_no_reaper_torch_yaml():
    """Core import + injected-evidence evaluation must not pull in REAPER
    code, Torch, YAML, or the legacy processor."""
    code = (
        "import sys, json\n"
        "from stemwerk_core import readiness\n"
        "fixture = json.load(open(sys.argv[1]))\n"
        "report = readiness.assess_readiness(\n"
        "    readiness.ReadinessRequest(workflow_id='drum_kit_split', evidence_mode='fixture'),\n"
        "    fixture=fixture, catalog_dir=sys.argv[2])\n"
        "banned = [m for m in sys.modules\n"
        "          if m.split('.')[0] in ('torch', 'yaml', 'reaper', 'torchaudio',\n"
        "                                 'audio_separator', 'onnxruntime',\n"
        "                                 'stemwerk_runtime_seam')]\n"
        "assert not banned, banned\n"
        "assert report['readiness']['verdict'] == 'PASS'\n"
        "print('boundary-ok')\n"
    )
    fixture_path = Path("/tmp") / f"sw_boundary_fixture_{os.getpid()}.json"
    fixture_path.write_text(json.dumps(_fixture_drum_kit_split()), encoding="utf-8")
    try:
        proc = subprocess.run(
            [sys.executable, "-c", code, str(fixture_path), str(CATALOG_DIR)],
            capture_output=True, text=True, env={**os.environ, "PYTHONPATH": str(CORE_SRC)},
            timeout=60,
        )
    finally:
        fixture_path.unlink(missing_ok=True)
    assert proc.returncode == 0, proc.stderr
    assert "boundary-ok" in proc.stdout


@pytest.mark.portable
def test_isolated_package_catalog_loading(tmp_path):
    """The packaged catalog must load with neither the repository tree nor a
    REAPER installation present (importlib.resources fallback)."""
    isolated = tmp_path / "iso"
    shutil.copytree(CORE_SRC / "stemwerk_core", isolated / "stemwerk_core")
    for pycache in isolated.rglob("__pycache__"):
        shutil.rmtree(pycache)
    fixture_path = tmp_path / "fixture.json"
    fixture_path.write_text(json.dumps(_fixture_normal_stems()), encoding="utf-8")
    proc = subprocess.run(
        [
            sys.executable, "-m", "stemwerk_core.readiness",
            "--workflow", "normal_stems", "--fixture", str(fixture_path),
        ],
        capture_output=True, text=True,
        env={"PYTHONPATH": str(isolated), "PATH": os.environ.get("PATH", "")},
        cwd=str(tmp_path),
        timeout=60,
    )
    assert proc.returncode == readiness.EXIT_SIMULATED_PASS, proc.stderr
    report = json.loads(proc.stdout)
    assert report["catalog"]["source"] == "package"
    assert report["readiness"]["verdict"] == PASS
    assert report["readiness"]["scope"] == "simulated_policy_evaluation"


# ---------------------------------------------------------------------------
# Simulated (fixture) evaluations across all three workflows
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_normal_stems_simulated_pass_scope_and_exit():
    report = _assess_fixture("normal_stems", _fixture_normal_stems())
    assert report["evaluation_mode"] == "simulated"
    assert report["readiness"]["verdict"] == PASS
    assert report["readiness"]["scope"] == "simulated_policy_evaluation"
    assert report["readiness"]["authoritative_gate"] == "execution_time_recheck"
    assert "no_inference_evidence" in report["readiness"]["limits"]
    assert "fixture_evidence_not_local_observation" in report["readiness"]["limits"]
    assert readiness.exit_code_for_report(report) == readiness.EXIT_SIMULATED_PASS
    plan = report["components"]["feasibility"]["evidence"]["plans"][0]
    assert plan["resolved_backend"] == "cuda"
    assert plan["reason_code"] == "auto_resolved"


@pytest.mark.portable
def test_four_stem_and_six_stem_routes_with_selective_deliverables():
    four = _assess_fixture("normal_stems", _fixture_normal_stems())
    assert four["deliverables"]["promised"] == ["vocals", "drums", "bass", "other"]
    assert four["deliverables"]["requested"] == ["vocals", "drums", "bass", "other"]
    assert four["stages"][0]["capability_id"] == "normal_stems_4"

    six = _assess_fixture(
        "normal_stems",
        _fixture_normal_stems(),
        model_id="htdemucs_6s",
        deliverable_ids=["vocals", "piano"],
    )
    assert six["deliverables"]["promised"] == [
        "vocals", "drums", "bass", "other", "guitar", "piano",
    ]
    assert six["deliverables"]["requested"] == ["vocals", "piano"]
    assert six["stages"][0]["capability_id"] == "normal_stems_6"


@pytest.mark.portable
def test_deliverable_not_promised_rejected():
    fixture = _fixture_normal_stems()
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", fixture, deliverable_ids=["kick"])
    assert excinfo.value.code == readiness.REASON_DELIVERABLE_NOT_PROMISED
    # Out-of-order subsets violate the promised route order.
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", fixture, deliverable_ids=["bass", "vocals"])
    assert excinfo.value.code == readiness.REASON_DELIVERABLE_NOT_PROMISED
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", fixture, deliverable_ids=["vocals", "vocals"])
    assert excinfo.value.code == readiness.REASON_DELIVERABLE_NOT_PROMISED


@pytest.mark.portable
def test_drum_kit_direct_simulated():
    report = _assess_fixture("drum_kit_direct", _fixture_drum_kit_direct())
    assert report["readiness"]["verdict"] == PASS
    assert report["stages"][0]["model_id"] == "drumsep_mdx23c"
    assert report["deliverables"]["promised"] == ["kick", "snare", "toms", "hi-hat", "ride", "crash"]


@pytest.mark.portable
def test_drum_kit_split_both_stages():
    report = _assess_fixture("drum_kit_split", _fixture_drum_kit_split())
    assert report["readiness"]["verdict"] == PASS
    assert [s["stage_id"] for s in report["stages"]] == ["separate_normal_for_kit", "drumsep_kit"]
    assert [s["model_id"] for s in report["stages"]] == ["htdemucs", "drumsep_mdx23c"]
    plans = report["components"]["feasibility"]["evidence"]["plans"]
    assert len(plans) == 2
    assert plans[0]["capability_id"] == "normal_stems_4"
    assert plans[1]["capability_id"] == "drum_kit_6"


@pytest.mark.portable
def test_kit_split_stage1_invalid_despite_valid_stage2():
    """Stage-1 (Normal-Stems) rejection must fail the whole workflow even
    with a fully valid DrumSep stage 2."""
    fixture = _fixture_drum_kit_split()
    fixture["stages"][0]["capability"] = _normal_capability(
        requested="cuda", device_id="cpu", name="CPU", backend="cpu"
    )
    report = _assess_fixture("drum_kit_split", fixture, requested_device="cuda")
    assert report["readiness"]["verdict"] == FAIL
    assert report["components"]["feasibility"]["reason_code"] == "backend_unavailable"
    assert readiness.exit_code_for_report(report) == readiness.EXIT_NOT_READY


# ---------------------------------------------------------------------------
# Missing / malformed / failed / skipped evidence
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_absent_fixture_evidence_is_unavailable_not_pass():
    report = _assess_fixture("normal_stems", {"kind": readiness.FIXTURE_KIND})
    assert report["readiness"]["verdict"] == UNAVAILABLE
    assert readiness.exit_code_for_report(report) == readiness.EXIT_UNAVAILABLE_OR_ERROR
    reasons = " ".join(report["readiness"]["failure_reasons"])
    assert readiness.REASON_FIXTURE_INCOMPLETE in reasons


@pytest.mark.portable
def test_malformed_fixture_rejected_with_stable_code():
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", {"kind": "something_else"})
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", "not-a-mapping")
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID
    fixture = _fixture_normal_stems()
    fixture["stages"][0]["capability"] = {"verdict": PASS}  # PASS without resolution
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", fixture)
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID
    fixture = _fixture_normal_stems()
    fixture["stages"][0]["runtime"] = {"verdict": "MAYBE"}
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", fixture)
    assert excinfo.value.code == readiness.REASON_FIXTURE_INVALID


@pytest.mark.portable
def test_failed_required_evidence_fails_overall():
    fixture = _fixture_normal_stems()
    fixture["stages"][0]["runtime"] = {
        "verdict": FAIL,
        "reason_code": "runtime_evidence_broken",
        "reason": "required package import validation failed",
    }
    report = _assess_fixture("normal_stems", fixture)
    assert report["readiness"]["verdict"] == FAIL
    assert any("runtime" in reason for reason in report["readiness"]["failure_reasons"])


@pytest.mark.portable
def test_skipped_evidence_does_not_fall_through_to_pass():
    fixture = _fixture_normal_stems()
    fixture["stages"][0]["model"] = {"verdict": SKIPPED, "reason": "not checked"}
    report = _assess_fixture("normal_stems", fixture)
    assert report["readiness"]["verdict"] == UNAVAILABLE
    assert readiness.exit_code_for_report(report) == readiness.EXIT_UNAVAILABLE_OR_ERROR


# ---------------------------------------------------------------------------
# Fixture labeling and provenance
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_fixture_evidence_never_acquires_live_labels():
    fixture = _fixture_drum_kit_split()
    # Attempt to smuggle live-looking provenance into the fixture.
    fixture["stages"][0]["runtime"] = {
        "verdict": PASS,
        "evidence": {"source": "collected", "evidence_kind": "real_probe_resolution"},
    }
    fixture["stages"][1]["capability"]["evidence"] = {
        "source": "collected",
        "evidence_kind": "real_execution",
        "selector_provenance": "production_select_drumsep_runtime",
    }
    report = _assess_fixture("drum_kit_split", fixture)
    assert report["evaluation_mode"] == "simulated"
    assert report["readiness"]["scope"] == "simulated_policy_evaluation"
    for evidence in _walk_evidence(report):
        assert evidence["source"] == "simulated_fixture"
        assert evidence["evidence_kind"] in ("fixture_supplied", "simulated_policy_evaluation")
    assert readiness.exit_code_for_report(report) == readiness.EXIT_SIMULATED_PASS


@pytest.mark.portable
def test_fixture_timestamps_pass_through_as_provenance():
    fixture = _fixture_normal_stems()
    fixture["stages"][0]["runtime"] = {
        "verdict": PASS,
        "evidence": {"observed_at_utc": "2020-01-01T00:00:00Z"},
    }
    report = _assess_fixture("normal_stems", fixture)
    evidence = report["stages"][0]["components"]["runtime"]["evidence"]
    assert evidence["observed_at_utc"] == "2020-01-01T00:00:00Z"
    # An old supplied success record is labeled simulated; the overall claim
    # still cannot become local readiness.
    assert report["readiness"]["scope"] == "simulated_policy_evaluation"


# ---------------------------------------------------------------------------
# Linux attributed fallback: accepted only with real attribution on Linux
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_linux_attributed_cpu_fallback_accepted():
    fixture = _fixture_drum_kit_direct(
        requested="cuda",
        kind="cpu",
        selection_info={
            "selection_policy": "fallback_cpu",
            "fallback_reason": "cuda_skipped: no genuine NVIDIA runtime",
        },
    )
    report = _assess_fixture("drum_kit_direct", fixture, requested_device="cuda")
    assert report["readiness"]["verdict"] == PASS
    plan = report["components"]["feasibility"]["evidence"]["plans"][0]
    assert plan["requested_device"] == "cuda"
    assert plan["resolved_backend"] == "cpu"
    assert plan["fallback_applied"] is True
    assert plan["fallback_reason"] == "cuda_skipped: no genuine NVIDIA runtime"
    assert report["readiness"]["scope"] == "simulated_policy_evaluation"


@pytest.mark.portable
@pytest.mark.parametrize(
    "platform_system,selection_info",
    [
        ("linux", {}),  # unattributed downgrade
        ("linux", {"selection_policy": "fallback_cpu"}),  # missing cuda_skipped reason
        ("darwin", {"selection_policy": "fallback_cpu", "fallback_reason": "cuda_skipped: x"}),
        ("win32", {"selection_policy": "fallback_cpu", "fallback_reason": "cuda_skipped: x"}),
    ],
)
def test_invalid_cpu_fallback_rejected(platform_system, selection_info):
    fixture = _fixture_drum_kit_direct(requested="cuda", kind="cpu", selection_info=selection_info)
    fixture["platform_system"] = platform_system
    report = _assess_fixture("drum_kit_direct", fixture, requested_device="cuda")
    assert report["readiness"]["verdict"] == FAIL
    assert report["components"]["feasibility"]["reason_code"] == "backend_unavailable"


# ---------------------------------------------------------------------------
# Platform/backend fixtures (Windows / macOS / Linux)
# ---------------------------------------------------------------------------


@pytest.mark.portable
@pytest.mark.parametrize(
    "platform_system,device_id,backend",
    [
        ("win32", "directml", "directml"),
        ("win32", "cuda:0", "cuda"),
        ("darwin", "mps", "mps"),
        ("linux", "cuda:0", "cuda"),
        ("linux", "rocm", "rocm"),
        ("linux", "cpu", "cpu"),
    ],
)
def test_normal_stems_platform_backend_fixtures(platform_system, device_id, backend):
    fixture = _fixture_normal_stems(device_id=device_id, name=device_id, backend=backend)
    fixture["platform_system"] = platform_system
    report = _assess_fixture("normal_stems", fixture)
    assert report["readiness"]["verdict"] == PASS
    plan = report["components"]["feasibility"]["evidence"]["plans"][0]
    assert plan["resolved_backend"] == backend


@pytest.mark.portable
@pytest.mark.parametrize("kind", ["cpu", "cuda", "rocm", "mps", "directml"])
def test_drumsep_backend_kind_fixtures(kind):
    report = _assess_fixture("drum_kit_direct", _fixture_drum_kit_direct(kind=kind))
    assert report["readiness"]["verdict"] == PASS
    plan = report["components"]["feasibility"]["evidence"]["plans"][0]
    assert plan["resolved_backend"] == kind


# ---------------------------------------------------------------------------
# Request / catalog errors
# ---------------------------------------------------------------------------


@pytest.mark.portable
def test_unknown_workflow_and_model_have_stable_codes():
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("not_a_workflow", _fixture_normal_stems())
    assert excinfo.value.code == "unknown_workflow"
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", _fixture_normal_stems(), model_id="not_a_model")
    assert excinfo.value.code == "unknown_model"
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("drum_kit_split", _fixture_drum_kit_split(), model_id=["htdemucs"])
    assert excinfo.value.code == readiness.REASON_MALFORMED_REQUEST
    with pytest.raises(ReadinessError) as excinfo:
        _assess_fixture("normal_stems", _fixture_normal_stems(), model_id="drumsep_mdx23c")
    assert excinfo.value.code == "model_capability_mismatch"


@pytest.mark.portable
def test_catalog_unavailable_is_stable_error(tmp_path):
    with pytest.raises(ReadinessError) as excinfo:
        readiness.assess_readiness(
            ReadinessRequest(workflow_id="normal_stems", evidence_mode="fixture"),
            fixture=_fixture_normal_stems(),
            catalog_dir=tmp_path / "empty",
        )
    assert excinfo.value.code == readiness.REASON_CATALOG_UNAVAILABLE


# ---------------------------------------------------------------------------
# CLI behavior: stdout JSON only, stderr diagnostics, exit codes
# ---------------------------------------------------------------------------


def _run_cli(args, **kwargs):
    return subprocess.run(
        [sys.executable, "-m", "stemwerk_core.readiness", *args],
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(CORE_SRC)},
        cwd=str(ROOT),
        timeout=60,
        **kwargs,
    )


@pytest.mark.portable
def test_cli_stdout_is_machine_readable_and_exit_codes(tmp_path):
    fixture_path = tmp_path / "fixture.json"
    fixture_path.write_text(json.dumps(_fixture_normal_stems()), encoding="utf-8")
    proc = _run_cli(
        [
            "--workflow", "normal_stems",
            "--catalog-dir", str(CATALOG_DIR),
            "--fixture", str(fixture_path),
            "--deliverables", "vocals,drums",
        ]
    )
    assert proc.returncode == readiness.EXIT_SIMULATED_PASS
    report = json.loads(proc.stdout)  # stdout must be exactly the report
    assert report["deliverables"]["requested"] == ["vocals", "drums"]
    assert proc.stderr.strip()  # diagnostics only on stderr

    proc = _run_cli(
        ["--workflow", "nope", "--catalog-dir", str(CATALOG_DIR), "--fixture", str(fixture_path)]
    )
    assert proc.returncode == readiness.EXIT_UNAVAILABLE_OR_ERROR
    document = json.loads(proc.stdout)
    assert document["kind"] == "stemwerk_readiness_error"
    assert document["error"]["code"] == "unknown_workflow"

    bad_fixture = tmp_path / "bad.json"
    bad_fixture.write_text("{not json", encoding="utf-8")
    proc = _run_cli(
        ["--workflow", "normal_stems", "--catalog-dir", str(CATALOG_DIR), "--fixture", str(bad_fixture)]
    )
    assert proc.returncode == readiness.EXIT_UNAVAILABLE_OR_ERROR
    assert json.loads(proc.stdout)["error"]["code"] == readiness.REASON_FIXTURE_INVALID


# ---------------------------------------------------------------------------
# API / CLI / adapter semantic equivalence on identical injected evidence
# ---------------------------------------------------------------------------


def _strip_generated(report):
    stripped = json.loads(json.dumps(report))
    stripped.pop("generated_at_utc", None)
    for evidence in _walk_evidence(stripped):
        evidence.pop("observed_at_utc", None)
    return stripped


@pytest.mark.portable
def test_api_cli_adapter_equivalence(tmp_path, monkeypatch):
    fixture = _fixture_drum_kit_split()
    request = ReadinessRequest(
        workflow_id="drum_kit_split", requested_device="auto", evidence_mode="fixture"
    )

    # Fixture evaluation through the adapter must never touch the legacy
    # processor, regardless of what other suites already imported.
    def _forbidden_legacy_load():
        raise AssertionError("fixture evaluation loaded the legacy module")

    monkeypatch.setattr(adapter, "_load_legacy_module", _forbidden_legacy_load)

    api_report = readiness.assess_readiness(request, fixture=fixture, catalog_dir=CATALOG_DIR)

    adapter_report = adapter.assess(request, fixture=fixture)

    fixture_path = tmp_path / "fixture.json"
    fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
    proc = _run_cli(
        [
            "--workflow", "drum_kit_split",
            "--catalog-dir", str(CATALOG_DIR),
            "--fixture", str(fixture_path),
        ]
    )
    assert proc.returncode == readiness.EXIT_SIMULATED_PASS
    cli_report = json.loads(proc.stdout)

    assert _strip_generated(api_report) == _strip_generated(cli_report)
    assert _strip_generated(api_report) == _strip_generated(adapter_report)


# ---------------------------------------------------------------------------
# Live collection with controlled (monkeypatched) collectors
# ---------------------------------------------------------------------------


@pytest.fixture
def canned_live(monkeypatch):
    """Force live collection to deterministic canned evidence (no subprocess,
    no hardware, no filesystem discovery outside tmp overrides)."""
    from stemwerk_core import readiness_collect

    monkeypatch.setattr(
        readiness_collect,
        "collect_runtime_imports",
        lambda python_exe, *, source_label, runtime_profile="main": {
            "verdict": PASS,
            "evidence": {
                "source": "collected",
                "evidence_kind": "required_imports",
                "runtime_source": source_label,
                "runtime_profile": runtime_profile,
            },
        },
    )
    monkeypatch.setattr(
        readiness_collect,
        "collect_normal_stems_resolution",
        lambda requested_device, python_exe, *, source_label: {
            "verdict": PASS,
            "resolution": {
                "requested": requested_device,
                "resolved_device_id": "cpu",
                "resolved_device_name": "CPU",
                "resolved_backend": "cpu",
                "available_devices": [],
            },
            "evidence": {
                "source": "collected",
                "evidence_kind": "real_probe_resolution",
                "runtime_source": source_label,
            },
        },
    )
    monkeypatch.setattr(
        readiness_collect,
        "collect_ffmpeg",
        lambda: {
            "verdict": PASS,
            "path": "/fake/ffmpeg",
            "evidence": {"source": "collected", "evidence_kind": "ffmpeg_usability_probe"},
        },
    )


@pytest.mark.portable
def test_live_local_preflight_pass_exit_zero(canned_live, tmp_path, monkeypatch):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    (model_dir / "htdemucs.yaml").write_text("models: ['abc123']\n", encoding="utf-8")
    (model_dir / "abc123def.th").write_bytes(b"weights")
    monkeypatch.setenv("AUDIO_SEPARATOR_MODEL_DIR", str(model_dir))

    report = readiness.assess_readiness(
        ReadinessRequest(workflow_id="normal_stems"), catalog_dir=CATALOG_DIR
    )
    assert report["evaluation_mode"] == "live"
    assert report["readiness"]["verdict"] == PASS
    assert report["readiness"]["scope"] == "local_preflight"
    assert readiness.exit_code_for_report(report) == readiness.EXIT_LIVE_READY
    model = report["stages"][0]["components"]["model"]
    assert model["evidence"]["integrity"] == "unverified"
    assert "demucs_model_integrity_unverified" in report["readiness"]["limits"]


@pytest.mark.portable
def test_live_model_assets_missing_fails(canned_live, tmp_path, monkeypatch):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    (model_dir / "htdemucs.yaml").write_text("models: ['abc123']\n", encoding="utf-8")
    monkeypatch.setenv("AUDIO_SEPARATOR_MODEL_DIR", str(model_dir))
    report = readiness.assess_readiness(
        ReadinessRequest(workflow_id="normal_stems"), catalog_dir=CATALOG_DIR
    )
    model = report["stages"][0]["components"]["model"]
    assert model["verdict"] == FAIL
    assert model["reason_code"] == readiness.REASON_MODEL_ASSETS_MISSING
    assert report["readiness"]["verdict"] == FAIL


@pytest.mark.portable
def test_standalone_drumsep_live_collection_unavailable(canned_live):
    """Standalone Core (no adapter collectors) must report DrumSep as
    UNAVAILABLE with the stable reason -- never substituting ambient CPU."""
    report = readiness.assess_readiness(
        ReadinessRequest(workflow_id="drum_kit_direct"), catalog_dir=CATALOG_DIR
    )
    assert report["evaluation_mode"] == "live"
    assert report["readiness"]["verdict"] == UNAVAILABLE
    capability = report["stages"][0]["components"]["capability"]
    assert capability["reason_code"] == readiness.REASON_DRUMSEP_LIVE_COLLECTION_UNSUPPORTED
    assert report["components"]["feasibility"]["reason_code"] == (
        readiness.REASON_DRUMSEP_LIVE_COLLECTION_UNSUPPORTED
    )
    assert readiness.exit_code_for_report(report) == readiness.EXIT_UNAVAILABLE_OR_ERROR


@pytest.mark.portable
def test_drumsep_model_integrity_via_provider(canned_live, tmp_path):
    good = tmp_path / "good.ckpt"
    good.write_bytes(b"ckpt-bytes")
    good_yaml = tmp_path / "good.yaml"
    good_yaml.write_bytes(b"yaml-bytes")
    assets = [
        {"name": "good.ckpt", "sha256": hashlib.sha256(b"ckpt-bytes").hexdigest()},
        {"name": "good.yaml", "sha256": hashlib.sha256(b"yaml-bytes").hexdigest()},
    ]
    collector = lambda requested: {
        "capability": {
            "verdict": PASS,
            "resolution": {
                "requested": requested,
                "resolved_device_id": "cpu",
                "resolved_device_name": "cpu",
                "resolved_backend": "cpu",
                "selection_info": {},
            },
            "evidence": {
                "source": "collected",
                "evidence_kind": "production_selector_result",
                "selector_provenance": "production_select_drumsep_runtime",
            },
        },
        "runtime": {"verdict": PASS, "evidence": {"source": "collected"}},
    }

    def run(provider_assets, base_dir):
        return readiness.assess_readiness(
            ReadinessRequest(workflow_id="drum_kit_direct"),
            catalog_dir=CATALOG_DIR,
            collectors={"drum_kit": collector},
            model_asset_providers={
                "drumsep_mdx23c": lambda: {"base_dir": str(base_dir), "assets": provider_assets}
            },
        )

    report = run(assets, tmp_path)
    model = report["stages"][0]["components"]["model"]
    assert model["verdict"] == PASS
    assert model["evidence"]["integrity"] == "sha256_verified"
    assert report["readiness"]["verdict"] == PASS
    assert report["readiness"]["scope"] == "local_preflight"

    bad = run([{**assets[0], "sha256": "0" * 64}, assets[1]], tmp_path)
    model = bad["stages"][0]["components"]["model"]
    assert model["verdict"] == FAIL
    assert model["reason_code"] == readiness.REASON_ASSET_INTEGRITY_MISMATCH

    missing = run(assets, tmp_path / "elsewhere")
    model = missing["stages"][0]["components"]["model"]
    assert model["verdict"] == FAIL
    assert model["reason_code"] == readiness.REASON_MODEL_ASSETS_MISSING


@pytest.mark.portable
def test_exit_code_mapping():
    assert readiness.exit_code_for_report(
        {"evaluation_mode": "live", "readiness": {"verdict": PASS}}
    ) == 0
    assert readiness.exit_code_for_report(
        {"evaluation_mode": "simulated", "readiness": {"verdict": PASS}}
    ) == 3
    assert readiness.exit_code_for_report(
        {"evaluation_mode": "live", "readiness": {"verdict": FAIL}}
    ) == 1
    assert readiness.exit_code_for_report(
        {"evaluation_mode": "simulated", "readiness": {"verdict": FAIL}}
    ) == 1
    assert readiness.exit_code_for_report(
        {"evaluation_mode": "live", "readiness": {"verdict": UNAVAILABLE}}
    ) == 2


# ---------------------------------------------------------------------------
# Read-only behavior: no mutation, no network, parent + subprocess scope
# ---------------------------------------------------------------------------


def _snapshot_tree(root: Path):
    snapshot = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        stat = path.lstat()
        if path.is_file():
            snapshot[relative] = (
                "file",
                hashlib.sha256(path.read_bytes()).hexdigest(),
                stat.st_mode,
                stat.st_size,
            )
        elif path.is_dir():
            snapshot[relative] = ("dir", stat.st_mode)
        else:
            snapshot[relative] = ("other", stat.st_mode)
    return snapshot


@pytest.mark.portable
def test_live_assessment_is_read_only_and_no_network(
    canned_live, tmp_path, monkeypatch
):
    """A live assessment must not create caches/directories, write logs or
    config, mutate the environment, or touch the network. The snapshot
    compares relative inventory, file content hashes, mode and size (not
    mtimes). Scope note: the bounded-subprocess collectors are monkeypatched
    here; subprocess-level invariance is covered separately by
    test_probe_subprocess_does_not_write."""
    home = tmp_path / "home"
    home.mkdir()
    for variable, value in {
        "HOME": str(home),
        "USERPROFILE": str(home),
        "XDG_DATA_HOME": str(home / "xdg"),
        "XDG_CACHE_HOME": str(home / "cache"),
        "LOCALAPPDATA": str(home / "local"),
        "STEMWERK_RUNTIME_ROOT": str(tmp_path / "runtime"),
        "AUDIO_SEPARATOR_MODEL_DIR": str(tmp_path / "models"),
    }.items():
        monkeypatch.setenv(variable, value)
    (tmp_path / "models").mkdir()
    (tmp_path / "models" / "htdemucs.yaml").write_text("models: ['abc123']\n", encoding="utf-8")
    (tmp_path / "models" / "abc123def.th").write_bytes(b"weights")

    def _no_network(*args, **kwargs):
        raise AssertionError("network access attempted during readiness evaluation")

    monkeypatch.setattr(socket, "create_connection", _no_network)
    monkeypatch.setattr(socket.socket, "connect", _no_network)
    monkeypatch.setattr(socket.socket, "connect_ex", _no_network)

    before = _snapshot_tree(tmp_path)
    report = readiness.assess_readiness(
        ReadinessRequest(workflow_id="normal_stems"), catalog_dir=CATALOG_DIR
    )
    after = _snapshot_tree(tmp_path)
    assert before == after
    assert report["readiness"]["verdict"] == PASS


@pytest.mark.portable
def test_probe_subprocess_does_not_write(tmp_path):
    """The bounded probe helper itself must leave no trace: run it with an
    isolated HOME/PYTHONDONTWRITEBYTECODE and verify the tree is unchanged
    (inventory + content + mode/size). This pins the subprocess-side scope;
    it deliberately does not claim third-party imports (torch/drivers) can
    never write -- those probes stay behind the same helper and are covered
    by the diagnostics harness, not re-probed here."""
    from stemwerk_core import readiness_collect

    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_CACHE_HOME": str(home / "cache"),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    before = _snapshot_tree(tmp_path)
    original_run = subprocess.run

    def run_with_env(*args, **kwargs):
        kwargs["env"] = env
        return original_run(*args, **kwargs)

    import stemwerk_core.readiness_collect as rc

    original = rc.subprocess.run
    rc.subprocess.run = run_with_env
    try:
        payload = rc._run_probe(Path(sys.executable), "import json; print(json.dumps({'ok': True}))")
    finally:
        rc.subprocess.run = original
    assert payload == {"ok": True}
    assert _snapshot_tree(tmp_path) == before


@pytest.mark.skipif(
    importlib.util.find_spec("torch") is not None,
    reason="ambient interpreter has torch; the no-torch real-subprobe path is "
    "covered on machines without an ambient torch install",
)
def test_live_normal_stems_real_subprobe_without_torch():
    """On an interpreter without torch, the real bounded resolution probe
    must still return a structured snapshot (CPU-class), never raise."""
    from stemwerk_core import readiness_collect

    result = readiness_collect.collect_normal_stems_resolution(
        "auto", Path(sys.executable), source_label="ambient"
    )
    assert result["verdict"] == PASS
    assert result["resolution"]["resolved_device_id"] == "cpu"
    assert result["resolution"]["resolved_backend"] == "cpu"
    assert Path(result["evidence"]["core_origin"]).resolve() == (
        CORE_SRC / "stemwerk_core" / "__init__.py"
    ).resolve()
    assert Path(result["evidence"]["python_executable"]).resolve() == Path(sys.executable).resolve()
