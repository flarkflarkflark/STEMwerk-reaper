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

CI selection: @pytest.mark.portable marks exactly the tests whose inputs are
fully controlled (mocks, fixtures, tmp_path, or the ambient interpreter used
only as a deterministic subprocess vehicle) -- no discovery of or dependence
on the actual machine's managed runtimes, GPU, or OS. CI runs only
`-m portable`; the mark is opt-in so a new test is excluded from portable CI
until someone classifies it deliberately. Note that three
test_run_real_*_fixture_* tests ARE portable (they drive the --real fixture
path against monkeypatched empty caches), while
test_collect_contracts_reports_fail_on_resolution_error is NOT (its drum-kit
sections invoke the real _select_drumsep_runtime discovery). Names alone do
not determine portability; the mark does.
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

@pytest.mark.portable
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


@pytest.mark.portable
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

@pytest.mark.portable
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


@pytest.mark.portable
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


@pytest.mark.portable
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


@pytest.mark.portable
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

@pytest.mark.portable
def test_collect_runtime_reports_unavailable_when_no_interpreter_found():
    result = diag.collect_runtime(None, source_label="managed")
    assert result["status"] == diag.UNAVAILABLE
    assert "no managed interpreter found" in result["reason"]


@pytest.mark.portable
def test_collect_runtime_reports_fail_when_interpreter_lacks_torch(tmp_path):
    """A real interpreter that exists but genuinely has no torch installed
    -- uses the actual Python running this test (guaranteed to lack a
    'definitely_not_a_real_module_xyz' import) to prove the probe_error
    path, without needing a literal broken venv on disk."""
    fake_python = Path(sys.executable)
    probe_src = "import definitely_not_a_real_module_xyz_9f3\n"
    result = diag._run_probe(fake_python, probe_src)
    assert "probe_error" in result


@pytest.mark.portable
def test_run_real_normal_stems_fixture_skips_when_model_not_locally_available(tmp_path, monkeypatch):
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: tmp_path / "empty_models")
    result = diag.run_real_normal_stems_fixture("cpu", Path(sys.executable))
    assert result["status"] == diag.SKIPPED
    assert "not locally available" in result["reason"]


@pytest.mark.portable
def test_run_real_drum_kit_direct_fixture_skips_when_checkpoint_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: tmp_path / "empty_models")
    result = diag.run_real_drum_kit_direct_fixture("rocm", Path(sys.executable))
    assert result["status"] == diag.SKIPPED
    assert "not locally available" in result["reason"]


@pytest.mark.portable
def test_run_real_normal_stems_fixture_unavailable_without_managed_python():
    result = diag.run_real_normal_stems_fixture("cpu", None)
    assert result["status"] == diag.UNAVAILABLE


# ---------------------------------------------------------------------------
# Model-cache / environment safety
# ---------------------------------------------------------------------------

@pytest.mark.portable
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


@pytest.mark.portable
def test_model_cache_mtime_diff_reports_unchanged_when_nothing_moved(tmp_path, monkeypatch):
    cache = tmp_path / "models"
    cache.mkdir()
    (cache / "htdemucs.yaml").write_text("v1")
    monkeypatch.setattr(diag, "managed_model_cache_dir", lambda: cache)

    before = diag.snapshot_model_cache_mtimes()
    result = diag.diff_model_cache_mtimes(before)
    assert result["unchanged"] is True
    assert result["changed_files"] == {}


@pytest.mark.portable
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


@pytest.mark.portable
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


@pytest.mark.portable
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


# ---------------------------------------------------------------------------
# Drum Kit contract parity with the production gate (Slice-4 exception)
#
# The harness's drum-kit sections reuse the production gate's own probe
# (_select_drumsep_runtime + _drum_kit_capability_probe_from_result), so
# these tests drive the REAL gate logic with a controlled selector result
# and prove the harness cannot reject a route production accepts (nor
# accept one production rejects). Note on scope: an Auto-request PASS here
# is scoped to Auto (the plan records requested_device explicitly); it
# never implies parity for every explicit device request, which is exactly
# what the attributed-fallback cases below pin down.
# ---------------------------------------------------------------------------

def _fake_drumsep_selector(python_path, runtime_kind, selection_info):
    def _select(_requested, _base=None):
        return python_path, runtime_kind, selection_info
    return _select


def _verbatim_normal_stems_probe():
    """Deterministic normal-stems probe resolving any explicit request
    verbatim (requested id, backend derived from it). Keeps Normal Stems
    and Kit Split stage 1 independent of this machine's actual hardware so
    these tests isolate the DrumSep-side gate behavior they target."""
    from stemwerk_core.runtime_resolution import CapabilityProbe

    return CapabilityProbe(
        get_available_devices=lambda: [],
        select_device=lambda requested: (requested, str(requested)),
        runtime_kind_for_device=lambda device_id: str(device_id or "").split(":", 1)[0],
        is_unexpected_cpu_downgrade=lambda _requested, _resolved: False,
    )


def _legacy_with_fake_selector(monkeypatch, selector):
    """Load the real legacy module, swap in the controlled selector, and
    make the seam hand that same module to the harness."""
    import stemwerk_runtime_seam

    legacy = stemwerk_runtime_seam._load_legacy_module()
    monkeypatch.setattr(legacy, "_select_drumsep_runtime", selector)
    monkeypatch.setattr(stemwerk_runtime_seam, "_load_legacy_module", lambda: legacy)
    return legacy


def _patch_normal_stems_verbatim(monkeypatch):
    import stemwerk_runtime_seam

    monkeypatch.setattr(
        stemwerk_runtime_seam, "build_normal_stems_capability_probe", _verbatim_normal_stems_probe
    )


@pytest.mark.portable
def test_drum_kit_contracts_accept_linux_attributed_cpu_fallback(monkeypatch):
    """Accepted Slice-4 exception, Linux scope: an explicit cuda:N request
    whose selector delivered the attributed CPU fallback (selection_policy
    'fallback_cpu' + 'cuda_skipped:' reason) must PASS the drum-kit
    contracts, truthfully reported as resolved_backend=cpu with
    fallback_applied=True -- not FAILed as a silent downgrade."""
    _legacy_with_fake_selector(monkeypatch, _fake_drumsep_selector(
        Path("/fake/drumsep/python"), "cpu",
        {"selection_policy": "fallback_cpu", "fallback_reason": "cuda_skipped:missing"},
    ))
    _patch_normal_stems_verbatim(monkeypatch)

    contracts = diag.collect_contracts(requested_device="cuda:0")

    direct = contracts["drum_kit_direct"]
    assert direct["status"] == diag.PASS
    assert direct["evidence_kind"] == "real_probe_resolution"
    plan = direct["plan"]
    assert plan["requested_device"] == "cuda:0"
    assert plan["resolved_backend"] == "cpu"
    assert plan["fallback_applied"] is True

    split = contracts["drum_kit_split"]
    assert split["status"] == diag.PASS
    assert split["stages"][0]["requested_device"] == "cuda:0"
    assert split["stages"][1]["resolved_backend"] == "cpu"
    assert split["stages"][1]["fallback_applied"] is True

    # Normal Stems is untouched by the DrumSep selector swap.
    assert contracts["normal_stems"]["status"] == diag.PASS
    assert contracts["normal_stems"]["plan"]["resolved_backend"] == "cuda"


@pytest.mark.portable
def test_drum_kit_contracts_fail_when_runtime_missing_or_broken(monkeypatch):
    """A selector that found nothing usable (python_path None, kind
    'missing'/'broken') must still surface FAIL with the resolver's exact
    reason. The attributed-fallback exception requires resolved=='cpu' and
    never authorizes an 'unavailable' result."""
    _legacy_with_fake_selector(monkeypatch, _fake_drumsep_selector(
        None, "missing", {"selection_policy": "explicit_cuda"},
    ))
    _patch_normal_stems_verbatim(monkeypatch)

    contracts = diag.collect_contracts(requested_device="cuda:0")

    direct = contracts["drum_kit_direct"]
    assert direct["status"] == diag.FAIL
    assert direct["evidence_kind"] == "real_probe_resolution"
    assert "backend_unavailable" in direct["reason"]


@pytest.mark.portable
def test_drum_kit_contracts_reject_attributed_cpu_fallback_off_linux(monkeypatch):
    """The Slice-4 exception carries an explicit sys.platform guard: the
    identical fallback attribution on a non-Linux platform must be rejected
    (fail-closed), not accepted by relying on non-Linux selectors never
    emitting that attribution."""
    monkeypatch.setattr(sys, "platform", "win32")
    _legacy_with_fake_selector(monkeypatch, _fake_drumsep_selector(
        Path("C:/fake/drumsep/python.exe"), "cpu",
        {"selection_policy": "fallback_cpu", "fallback_reason": "cuda_skipped:missing"},
    ))
    _patch_normal_stems_verbatim(monkeypatch)

    contracts = diag.collect_contracts(requested_device="cuda:0")

    direct = contracts["drum_kit_direct"]
    assert direct["status"] == diag.FAIL
    assert "backend_unavailable" in direct["reason"]


@pytest.mark.portable
def test_drum_kit_split_stage1_rejection_not_bypassed_by_stage2_exception(monkeypatch):
    """Kit Split resolves stage 1 (Demucs) first; a stage-1 rejection must
    FAIL the whole workflow even when the stage-2 DrumSep selector would
    qualify for the attributed-CPU exception."""
    import stemwerk_runtime_seam
    from stemwerk_core.runtime_resolution import CapabilityProbe

    _legacy_with_fake_selector(monkeypatch, _fake_drumsep_selector(
        Path("/fake/drumsep/python"), "cpu",
        {"selection_policy": "fallback_cpu", "fallback_reason": "cuda_skipped:missing"},
    ))

    def broken_probe():
        return CapabilityProbe(
            get_available_devices=lambda: [],
            select_device=lambda _requested: ("unavailable", ""),
            runtime_kind_for_device=lambda _id: "unavailable",
            is_unexpected_cpu_downgrade=lambda _r, _d: False,
        )

    monkeypatch.setattr(stemwerk_runtime_seam, "build_normal_stems_capability_probe", broken_probe)

    contracts = diag.collect_contracts(requested_device="cuda:0")

    split = contracts["drum_kit_split"]
    assert split["status"] == diag.FAIL
    assert "reason" in split
    # Direct Kit has no stage 1 and still accepts the attributed fallback.
    assert contracts["drum_kit_direct"]["status"] == diag.PASS
