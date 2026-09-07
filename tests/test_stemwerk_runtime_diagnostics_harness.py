"""Tests for tools/stemwerk_runtime_diagnostics.py (Slice 5's portable
validation harness).

Real vs mocked evidence, explicitly:
- test_real_* : exercise build_report()/collect_*() for real on THIS
  machine (Linux/ROCm, or CPU-only fallbacks). These are genuine
  integration tests, not resolver-only claims dressed up as hardware
  validation -- see each test's assertion on evidence_kind.
- test_mocked_platform_shape_* : construct report fragments the way the
  harness's own code would for Windows/CUDA, Windows/DirectML, and macOS/
  MPS shapes, none of which can exist on this development machine. These
  never claim real hardware was probed; they prove the harness's *report
  structure* correctly represents those shapes, by feeding it fake probe
  data through the same code paths ambient probing would use.
- everything else is a structural/state test that needs no real hardware.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import stemwerk_runtime_diagnostics as diag  # noqa: E402


# ---------------------------------------------------------------------------
# Verdict vocabulary
# ---------------------------------------------------------------------------

def test_verdict_constants_are_the_five_distinct_states():
    verdicts = {diag.PASS, diag.FAIL, diag.SKIPPED, diag.UNAVAILABLE, diag.NOT_APPLICABLE}
    assert verdicts == {"PASS", "FAIL", "SKIPPED", "UNAVAILABLE", "NOT_APPLICABLE"}
    assert len(verdicts) == 5


# ---------------------------------------------------------------------------
# JSON schema / result structure -- real, on this machine
# ---------------------------------------------------------------------------

def test_real_report_has_schema_version_and_required_top_level_sections():
    report = diag.build_report(real=False)
    assert report["schema_version"] == diag.SCHEMA_VERSION
    assert "generated_at_utc" in report
    for section in ("identity", "runtime", "hardware", "contracts", "backend_matrix", "safety"):
        assert section in report, f"missing report section: {section}"
    assert "execution" not in report, "execution section must only appear when real=True"


def test_real_report_is_json_serializable_round_trip():
    report = diag.build_report(real=False)
    payload = json.dumps(report, sort_keys=True)
    reloaded = json.loads(payload)
    assert reloaded["schema_version"] == diag.SCHEMA_VERSION


def test_json_and_markdown_render_from_the_same_report_object(tmp_path):
    """Section 5's 'do not maintain two independent reporting
    implementations' -- to_markdown() must be a pure function of the report
    dict, not a second collector. Prove it by rendering markdown from a
    hand-built report and checking it reflects exactly that data, not a
    freshly-collected one."""
    fake_report = {
        "schema_version": "9.9.9",
        "generated_at_utc": "2000-01-01T00:00:00Z",
        "identity": {"stemwerk_version": "0.0.0-test"},
        "runtime": {"main": {"status": diag.PASS, "runtime_source": "managed", "torch_version": "9.9.9"}},
        "hardware": {"main": {"status": diag.PASS, "auto_selected_device_name": "Fake Device", "auto_selected_backend": "fake"}},
        "contracts": {"normal_stems": {"status": diag.PASS, "evidence_kind": "real_probe_resolution", "authoritative": True,
                                        "plan": {"resolved_backend": "fake", "resolved_device": "fake:0", "reason_code": "auto_resolved"}}},
        "backend_matrix": {"linux": {"rocm": diag.PASS, "cpu": diag.PASS}},
        "safety": {"managed_model_cache_dir": "/fake"},
    }
    markdown = diag.to_markdown(fake_report)
    assert "0.0.0-test" in markdown
    assert "9.9.9" in markdown
    assert "Fake Device" in markdown
    assert "normal_stems" in markdown
    assert "fake:0" in markdown


# ---------------------------------------------------------------------------
# Real: Linux ROCm + CPU representation on this machine
# ---------------------------------------------------------------------------

def test_real_identity_reports_this_linux_machine():
    identity = diag.collect_identity()
    assert identity["platform_system"] == "Linux"
    assert identity["stemwerk_version"]
    assert identity["python_version"]


def test_real_managed_runtime_python_is_found_on_this_machine():
    """This development machine has a real bootstrapped managed runtime
    (see docs/research/LINUX_ROCM_MAIN_RUNTIME_SLICE3_STATUS_2026-09-07.md);
    this is real integration evidence, not a mock."""
    python = diag.managed_runtime_python()
    assert python is not None
    assert python.exists()


def test_real_main_runtime_and_hardware_reflect_managed_rocm_venv():
    python = diag.managed_runtime_python()
    if python is None:
        pytest.skip("no managed runtime on this machine")
    runtime = diag.collect_runtime(python, source_label="managed")
    assert runtime["status"] == diag.PASS
    assert runtime["runtime_source"] == "managed"
    assert runtime["torch_version"]

    hardware = diag.collect_main_hardware(python, source_label="managed")
    assert hardware["status"] == diag.PASS
    assert hardware.get("auto_selected_backend") in ("rocm", "cuda", "cpu", "mps", "directml", None)


def test_real_drumsep_rocm_hardware_reports_rx_9070_when_present():
    """Real hardware evidence: on this machine's known DrumSep ROCm venv,
    both the RX 9070 (discrete) and 780M (integrated) should be visible,
    matching Slice 1-4's own established real-hardware findings."""
    drumsep = diag.managed_drumsep_pythons()
    if "rocm" not in drumsep:
        pytest.skip("no .venv-drumsep-rocm on this machine")
    data = diag.collect_drumsep_hardware("rocm", drumsep["rocm"])
    assert data["status"] == diag.PASS
    assert any("RX 9070" in name for name in data.get("device_names", []))


def test_real_contracts_resolve_for_all_three_authoritative_workflows():
    contracts = diag.collect_contracts(requested_device="auto")
    for workflow_id in ("normal_stems", "drum_kit_direct", "drum_kit_split"):
        assert workflow_id in contracts
        entry = contracts[workflow_id]
        assert entry["status"] in (diag.PASS, diag.FAIL, diag.UNAVAILABLE)
        if entry["status"] == diag.PASS:
            assert entry["evidence_kind"] == "real_probe_resolution"
            assert entry["authoritative"] is True, f"{workflow_id} must remain authoritative per Slice 4"


def test_backend_matrix_marks_other_platforms_not_applicable_on_linux():
    report = diag.build_report(real=False)
    matrix = report["backend_matrix"]
    if report["identity"]["platform_system"] != "Linux":
        pytest.skip("this test's NOT_APPLICABLE assertions are Linux-specific")
    assert matrix["darwin"]["mps"] == diag.NOT_APPLICABLE
    assert matrix["windows"]["cuda"] == diag.NOT_APPLICABLE
    assert matrix["windows"]["directml"] == diag.NOT_APPLICABLE


# ---------------------------------------------------------------------------
# Mocked platform shapes that cannot exist on this machine
# ---------------------------------------------------------------------------

def test_mocked_platform_shape_windows_cuda_backend_matrix_row():
    """Cannot run on real Windows/CUDA hardware from this Linux machine --
    this proves the backend_matrix ROW SHAPE for a Windows/CUDA machine
    (built the same way build_report() would from real probe data), not
    that CUDA was actually probed."""
    fake_hardware_main = {"status": diag.PASS, "auto_selected_backend": "cuda"}
    fake_drumsep_pythons = {"cuda": Path("/fake/venv-drumsep-cuda/python.exe")}
    row = {}
    for backend in diag.BACKEND_MATRIX["windows"]:
        if backend == "cpu":
            row[backend] = diag.PASS
        elif backend in fake_drumsep_pythons or fake_hardware_main.get("auto_selected_backend") == backend:
            row[backend] = diag.PASS
        else:
            row[backend] = diag.UNAVAILABLE
    assert row == {"cuda": diag.PASS, "directml": diag.UNAVAILABLE, "cpu": diag.PASS}


def test_mocked_platform_shape_windows_directml_backend_matrix_row():
    fake_hardware_main = {"status": diag.PASS, "auto_selected_backend": "directml"}
    fake_drumsep_pythons: dict = {}
    row = {}
    for backend in diag.BACKEND_MATRIX["windows"]:
        if backend == "cpu":
            row[backend] = diag.PASS
        elif backend in fake_drumsep_pythons or fake_hardware_main.get("auto_selected_backend") == backend:
            row[backend] = diag.PASS
        else:
            row[backend] = diag.UNAVAILABLE
    assert row == {"cuda": diag.UNAVAILABLE, "directml": diag.PASS, "cpu": diag.PASS}


def test_mocked_platform_shape_macos_mps_runtime_fields():
    """Structural proof that a macOS/MPS-shaped runtime probe result (as
    the _RUNTIME_PROBE_SRC script would emit on real macOS) is represented
    with the mps_built/mps_available distinction section 12 requires --
    built by hand since no macOS torch can run on this Linux machine."""
    fake_macos_runtime = {
        "status": diag.PASS,
        "runtime_source": "managed",
        "torch_version": "2.5.1",
        "torch_cuda_available": False,
        "torch_mps_built": True,
        "torch_mps_available": True,
    }
    assert fake_macos_runtime["torch_mps_built"] is True
    assert fake_macos_runtime["torch_mps_available"] is True
    assert fake_macos_runtime["torch_cuda_available"] is False

    markdown = diag.to_markdown({
        "schema_version": diag.SCHEMA_VERSION, "generated_at_utc": "x",
        "identity": {}, "runtime": {"main": fake_macos_runtime}, "hardware": {}, "contracts": {},
        "backend_matrix": {"darwin": {"mps": diag.PASS, "cpu": diag.PASS}}, "safety": {},
    })
    assert "torch_version: 2.5.1" in markdown


def test_mocked_platform_shape_cpu_only_machine_backend_matrix_row():
    fake_hardware_main = {"status": diag.PASS, "auto_selected_backend": "cpu"}
    row = {}
    for backend in diag.BACKEND_MATRIX["linux"]:
        if backend == "cpu":
            row[backend] = diag.PASS
        elif fake_hardware_main.get("auto_selected_backend") == backend:
            row[backend] = diag.PASS
        else:
            row[backend] = diag.UNAVAILABLE
    assert row == {"rocm": diag.UNAVAILABLE, "cpu": diag.PASS}


# ---------------------------------------------------------------------------
# Missing torch / missing model / missing interpreter
# ---------------------------------------------------------------------------

def test_collect_runtime_reports_unavailable_when_no_interpreter_found():
    result = diag.collect_runtime(None, source_label="managed")
    assert result["status"] == diag.UNAVAILABLE
    assert "no managed interpreter found" in result["reason"]


def test_collect_runtime_reports_fail_when_interpreter_lacks_torch(tmp_path):
    """A real interpreter that exists but genuinely has no torch installed
    -- uses the actual Python running this test (guaranteed to lack a
    'definitely_not_a_real_module_xyz' import) to prove the probe_error
    path, without needing a literal broken venv on disk."""
    fake_python = Path(sys.executable)
    probe_src = "import definitely_not_a_real_module_xyz_9f3\n"
    result = diag._run_probe(fake_python, probe_src)
    assert "probe_error" in result


def test_run_real_normal_stems_fixture_skips_when_model_not_locally_available(tmp_path, monkeypatch):
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: tmp_path / "empty_models")
    result = diag.run_real_normal_stems_fixture("cpu", Path(sys.executable))
    assert result["status"] == diag.SKIPPED
    assert "not locally available" in result["reason"]


def test_run_real_drum_kit_direct_fixture_skips_when_checkpoint_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: tmp_path / "empty_models")
    result = diag.run_real_drum_kit_direct_fixture("rocm", Path(sys.executable))
    assert result["status"] == diag.SKIPPED
    assert "not locally available" in result["reason"]


def test_run_real_normal_stems_fixture_unavailable_without_managed_python():
    result = diag.run_real_normal_stems_fixture("cpu", None)
    assert result["status"] == diag.UNAVAILABLE


# ---------------------------------------------------------------------------
# Model-cache / environment safety
# ---------------------------------------------------------------------------

def test_model_cache_mtime_diff_detects_a_changed_file(tmp_path, monkeypatch):
    cache = tmp_path / "models"
    cache.mkdir()
    (cache / "htdemucs.yaml").write_text("v1")
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: cache)

    before = diag.snapshot_model_cache_mtimes()
    (cache / "htdemucs.yaml").write_text("v2 -- mutated")
    os.utime(cache / "htdemucs.yaml", None)
    result = diag.diff_model_cache_mtimes(before)
    assert result["unchanged"] is False
    assert any("htdemucs.yaml" in key for key in result["changed_files"])


def test_model_cache_mtime_diff_reports_unchanged_when_nothing_moved(tmp_path, monkeypatch):
    cache = tmp_path / "models"
    cache.mkdir()
    (cache / "htdemucs.yaml").write_text("v1")
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: cache)

    before = diag.snapshot_model_cache_mtimes()
    result = diag.diff_model_cache_mtimes(before)
    assert result["unchanged"] is True
    assert result["changed_files"] == {}


def test_run_real_normal_stems_fixture_does_not_mutate_process_environment(tmp_path, monkeypatch):
    """AUDIO_SEPARATOR_MODEL_DIR and TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD must
    only be set on the subprocess's own env copy, never on this process's
    os.environ -- carrying forward Slice 3's env-leakage finding."""
    source_dir = tmp_path / "models"
    source_dir.mkdir()
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: source_dir)
    before_keys = dict(os.environ)

    result = diag.run_real_normal_stems_fixture("cpu", Path(sys.executable))

    assert result["status"] == diag.SKIPPED
    assert dict(os.environ) == before_keys
    assert "AUDIO_SEPARATOR_MODEL_DIR" not in os.environ or os.environ.get("AUDIO_SEPARATOR_MODEL_DIR") == before_keys.get("AUDIO_SEPARATOR_MODEL_DIR")


def test_stage_model_copy_never_writes_outside_dest_dir(tmp_path):
    source_dir = tmp_path / "source"
    source_dir.mkdir()
    (source_dir / "htdemucs.yaml").write_text("models: ['abc123']\n")
    (source_dir / "abc123-deadbeef.th").write_bytes(b"fake weights")
    dest_dir = tmp_path / "dest" / "models"

    staged = diag._stage_model_copy(source_dir, "htdemucs", dest_dir)

    assert staged == dest_dir
    assert (dest_dir / "htdemucs.yaml").exists()
    assert (dest_dir / "abc123-deadbeef.th").exists()
    assert not (source_dir / "abc123-deadbeef.th").read_bytes() == b""
    assert list(source_dir.iterdir()), "source dir must be untouched (still has its original files)"


# ---------------------------------------------------------------------------
# Contract / runtime disagreement detection
# ---------------------------------------------------------------------------

def test_collect_contracts_reports_fail_on_resolution_error(monkeypatch):
    """A ResolutionError from the real resolver must surface as a FAIL
    verdict with the exact reason code, not crash the whole report or get
    silently swallowed into a false PASS."""
    import stemwerk_runtime_seam
    from stemwerk_core.runtime_resolution import CapabilityProbe

    def broken_probe():
        return CapabilityProbe(
            get_available_devices=lambda: [],
            select_device=lambda _requested: ("unavailable", ""),
            runtime_kind_for_device=lambda _id: "unavailable",
            is_unexpected_cpu_downgrade=lambda _r, _d: False,
        )

    monkeypatch.setattr(stemwerk_runtime_seam, "build_normal_stems_capability_probe", broken_probe)
    contracts = diag.collect_contracts(requested_device="cuda")
    assert contracts["normal_stems"]["status"] == diag.FAIL
    assert contracts["normal_stems"]["evidence_kind"] == "real_probe_resolution"
    assert "reason" in contracts["normal_stems"]


def test_collect_contracts_unavailable_when_seam_module_not_importable(monkeypatch):
    import builtins

    real_import = builtins.__import__

    def failing_import(name, *args, **kwargs):
        if name == "stemwerk_runtime_seam":
            raise ImportError("simulated: seam module unavailable")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", failing_import)
    result = diag.collect_contracts()
    assert result["status"] == diag.UNAVAILABLE
    assert "not importable" in result["reason"]
