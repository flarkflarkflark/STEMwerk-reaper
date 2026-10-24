from __future__ import annotations

import sys
from pathlib import Path
from typing import Mapping, Optional, Sequence

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import workflow_contracts  # noqa: E402
from stemwerk_core.runtime_resolution import (  # noqa: E402
    CapabilityProbe,
    ExecutionPlan,
    ResolutionError,
    StageRequest,
    WorkflowExecutionPlan,
    REASON_BACKEND_NOT_PERMITTED,
    REASON_BACKEND_UNAVAILABLE,
    REASON_CONTRACT_LOAD_ERROR,
    REASON_MODEL_CAPABILITY_MISMATCH,
    REASON_OK_AUTO,
    REASON_OK_EXPLICIT,
    REASON_STAGE_REQUEST_COUNT_MISMATCH,
    REASON_UNKNOWN_CAPABILITY,
    REASON_UNKNOWN_MODEL,
    REASON_UNKNOWN_WORKFLOW,
    REASON_UNSUPPORTED_STAGE_COUNT,
    _resolve_single_stage,
    resolve_execution_plan,
    resolve_workflow_plan,
)


# ---------------------------------------------------------------------------
# Fake probes -- no torch, no GPU, no real device enumeration anywhere below.
# ---------------------------------------------------------------------------


def _fake_probe(
    *,
    devices: Sequence[Mapping[str, str]] = (),
    select_device_map: Mapping[str, tuple] = None,
    kind_map: Mapping[str, str] = None,
    auto_preferred: Optional[Mapping[str, str]] = None,
    unexpected_cpu_downgrade=None,
) -> CapabilityProbe:
    select_device_map = dict(select_device_map or {})
    kind_map = dict(kind_map or {})

    def select_device(requested: str) -> tuple:
        return select_device_map[requested]

    def runtime_kind_for_device(device_id) -> str:
        return kind_map.get(str(device_id), "unknown")

    def resolve_auto_device(_live_devices):
        return auto_preferred

    def default_downgrade(requested: str, resolved: str) -> bool:
        req = str(requested or "auto").strip().lower()
        res = str(resolved or "").strip().lower()
        if res != "cpu":
            return False
        return req not in ("", "auto", "cpu")

    return CapabilityProbe(
        get_available_devices=lambda: list(devices),
        select_device=select_device,
        runtime_kind_for_device=runtime_kind_for_device,
        is_unexpected_cpu_downgrade=unexpected_cpu_downgrade or default_downgrade,
        resolve_auto_device=resolve_auto_device,
    )


ROCM_DEVICE = {"id": "cuda:0", "name": "AMD Radeon RX 9070", "type": "cuda"}
CPU_PROBE = _fake_probe(select_device_map={"cpu": ("cpu", "CPU"), "auto": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})


def _rocm_capable_probe(**overrides) -> CapabilityProbe:
    base = dict(
        devices=[ROCM_DEVICE],
        select_device_map={"auto": ("cuda:0", "AMD Radeon RX 9070"), "cuda:0": ("cuda:0", "AMD Radeon RX 9070")},
        kind_map={"cuda:0": "rocm"},
    )
    base.update(overrides)
    return _fake_probe(**base)


# ---------------------------------------------------------------------------
# 1. known workflow resolves successfully
# ---------------------------------------------------------------------------


def test_known_workflow_resolves_successfully():
    plan = resolve_execution_plan("normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert isinstance(plan, ExecutionPlan)
    assert plan.workflow_id == "normal_stems"
    assert plan.capability_id == "normal_stems_4"
    assert plan.model_id == "htdemucs"
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
    assert plan.contract_source == "2.4_contract"
    assert plan.fallback_applied is False
    assert plan.reason_code == REASON_OK_EXPLICIT


# ---------------------------------------------------------------------------
# 2. unknown workflow fails closed
# ---------------------------------------------------------------------------


def test_unknown_workflow_fails_closed():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("does_not_exist", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert excinfo.value.code == REASON_UNKNOWN_WORKFLOW


# ---------------------------------------------------------------------------
# 3. valid workflow -> model reference resolves, for EVERY catalogued model
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("model_id", ["htdemucs", "htdemucs_ft", "htdemucs_6s", "hdemucs_mmi"])
def test_every_normal_stems_model_resolves(model_id):
    plan = resolve_execution_plan("normal_stems", model_id, "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert plan.model_id == model_id
    assert plan.capability_id in ("normal_stems_4", "normal_stems_6")


def test_htdemucs_6s_resolves_to_the_6_stem_capability():
    plan = resolve_execution_plan("normal_stems", "htdemucs_6s", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert plan.capability_id == "normal_stems_6"


def test_drumsep_model_resolves_for_both_drum_kit_workflows():
    for workflow_id in ("drum_kit_direct", "drum_kit_split"):
        stages = workflow_contracts.validate_catalogs(CATALOG_DIR)["workflows"]
        stage_count = next(w for w in stages if w["workflow_id"] == workflow_id)["ordered_stages"]
        if len(stage_count) == 1:
            plan = resolve_execution_plan(
                workflow_id, "drumsep_mdx23c", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE
            )
            assert plan.capability_id == "drum_kit_6"


# ---------------------------------------------------------------------------
# 4. broken workflow -> model reference fails closed
# ---------------------------------------------------------------------------


def test_broken_workflow_model_reference_fails_closed():
    catalogs = {
        "capabilities": [
            {"capability_id": "cap_a", "permitted_backends": ["cpu"]},
            {"capability_id": "cap_b", "permitted_backends": ["cpu"]},
        ],
        "models": [{"model_id": "model_x", "capability_id": "cap_b"}],
        "workflows": [{"workflow_id": "wf"}],
    }
    stage = {"stage_id": "stage1", "capability_ids": ["cap_a"]}
    with pytest.raises(ResolutionError) as excinfo:
        _resolve_single_stage(catalogs, "wf", stage, "model_x", "cpu", CPU_PROBE)
    assert excinfo.value.code == REASON_MODEL_CAPABILITY_MISMATCH


def test_unknown_model_fails_closed():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "not_a_real_model", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE
        )
    assert excinfo.value.code == REASON_UNKNOWN_MODEL


def test_stage_referencing_unknown_capability_fails_closed():
    catalogs = {
        "capabilities": [{"capability_id": "cap_a", "permitted_backends": ["cpu"]}],
        "models": [{"model_id": "model_x", "capability_id": "cap_missing"}],
        "workflows": [{"workflow_id": "wf"}],
    }
    stage = {"stage_id": "stage1", "capability_ids": ["cap_missing"]}
    with pytest.raises(ResolutionError) as excinfo:
        _resolve_single_stage(catalogs, "wf", stage, "model_x", "cpu", CPU_PROBE)
    assert excinfo.value.code == REASON_UNKNOWN_CAPABILITY


def test_multi_stage_workflow_rejected_by_single_stage_resolver():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "drum_kit_split", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE
        )
    assert excinfo.value.code == REASON_UNSUPPORTED_STAGE_COUNT


# ---------------------------------------------------------------------------
# 5. explicit ROCm + supported model/workflow -> ROCm
# ---------------------------------------------------------------------------


def test_explicit_rocm_supported_resolves_to_rocm():
    probe = _rocm_capable_probe()
    plan = resolve_execution_plan("normal_stems", "htdemucs", "cuda:0", catalog_dir=CATALOG_DIR, probe=probe)
    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "cuda:0"
    assert plan.fallback_applied is False
    assert plan.reason_code == REASON_OK_EXPLICIT


# ---------------------------------------------------------------------------
# 6. Auto on mocked AMD Linux/ROCm capability set -> intended ROCm result
# ---------------------------------------------------------------------------


def test_auto_on_amd_linux_rocm_resolves_to_rocm_not_cpu():
    probe = _rocm_capable_probe(auto_preferred=ROCM_DEVICE)
    plan = resolve_execution_plan("normal_stems", "htdemucs", "auto", catalog_dir=CATALOG_DIR, probe=probe)
    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "cuda:0"
    assert plan.fallback_applied is False
    assert plan.reason_code == REASON_OK_AUTO


def test_auto_with_no_gpu_falls_back_to_cpu_deterministically():
    plan = resolve_execution_plan("normal_stems", "htdemucs", "auto", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert plan.resolved_backend == "cpu"
    assert plan.fallback_applied is True
    assert plan.reason_code == REASON_OK_AUTO


# ---------------------------------------------------------------------------
# 7. explicit unsupported backend -> deterministic rejection
# ---------------------------------------------------------------------------


def test_explicit_rocm_rejected_when_capability_policy_forbids_it():
    catalogs = workflow_contracts.validate_catalogs(CATALOG_DIR)
    restricted_capabilities = [
        dict(entry, permitted_backends=["cpu"]) if entry["capability_id"] == "normal_stems_4" else entry
        for entry in catalogs["capabilities"]
    ]
    restricted = dict(catalogs, capabilities=restricted_capabilities)
    stage = catalogs["workflows"][0]["ordered_stages"][0]
    probe = _rocm_capable_probe()

    with pytest.raises(ResolutionError) as excinfo:
        _resolve_single_stage(restricted, "normal_stems", stage, "htdemucs", "cuda:0", probe)
    assert excinfo.value.code == REASON_BACKEND_NOT_PERMITTED


# ---------------------------------------------------------------------------
# 8. ROCm unavailable on machine -> correct unavailable result
# ---------------------------------------------------------------------------


def test_explicit_rocm_unavailable_on_machine_is_rejected_not_downgraded():
    probe = _fake_probe(select_device_map={"cuda:0": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("normal_stems", "htdemucs", "cuda:0", catalog_dir=CATALOG_DIR, probe=probe)
    assert excinfo.value.code == REASON_BACKEND_UNAVAILABLE


# ---------------------------------------------------------------------------
# 9. CPU route where supported
# ---------------------------------------------------------------------------


def test_cpu_explicit_request_resolves_correctly():
    plan = resolve_execution_plan("normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=CPU_PROBE)
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
    assert plan.fallback_applied is False


# ---------------------------------------------------------------------------
# Multi-stage: Drum Split resolves each stage independently, per-stage probes
# ---------------------------------------------------------------------------


def test_drum_kit_split_resolves_both_stages_independently():
    stage1_probe = _fake_probe(select_device_map={"cpu": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    stage2_probe = _rocm_capable_probe()

    plan = resolve_workflow_plan(
        "drum_kit_split",
        [
            StageRequest(model_id="htdemucs_6s", requested_device="cpu", probe=stage1_probe),
            StageRequest(model_id="drumsep_mdx23c", requested_device="cuda:0", probe=stage2_probe),
        ],
        catalog_dir=CATALOG_DIR,
    )
    assert isinstance(plan, WorkflowExecutionPlan)
    assert plan.workflow_id == "drum_kit_split"
    assert len(plan.stages) == 2
    assert plan.stages[0].stage_id == "separate_normal_for_kit"
    assert plan.stages[0].capability_id == "normal_stems_6"
    assert plan.stages[0].resolved_backend == "cpu"
    assert plan.stages[1].stage_id == "drumsep_kit"
    assert plan.stages[1].capability_id == "drum_kit_6"
    assert plan.stages[1].resolved_backend == "rocm"


def test_drum_kit_direct_resolves_single_stage():
    plan = resolve_workflow_plan(
        "drum_kit_direct",
        [StageRequest(model_id="drumsep_mdx23c", requested_device="cpu", probe=CPU_PROBE)],
        catalog_dir=CATALOG_DIR,
    )
    assert len(plan.stages) == 1
    assert plan.stages[0].capability_id == "drum_kit_6"
    assert plan.stages[0].resolved_backend == "cpu"


def test_stage_request_count_mismatch_fails_closed():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_workflow_plan(
            "drum_kit_split",
            [StageRequest(model_id="htdemucs", requested_device="cpu", probe=CPU_PROBE)],
            catalog_dir=CATALOG_DIR,
        )
    assert excinfo.value.code == REASON_STAGE_REQUEST_COUNT_MISMATCH


def test_wrong_model_for_drum_kit_stage_fails_closed():
    """A Demucs model cannot satisfy the DrumSep stage's capability, and vice versa."""
    with pytest.raises(ResolutionError) as excinfo:
        resolve_workflow_plan(
            "drum_kit_split",
            [
                StageRequest(model_id="htdemucs", requested_device="cpu", probe=CPU_PROBE),
                StageRequest(model_id="htdemucs_ft", requested_device="cpu", probe=CPU_PROBE),
            ],
            catalog_dir=CATALOG_DIR,
        )
    assert excinfo.value.code == REASON_MODEL_CAPABILITY_MISMATCH


# ---------------------------------------------------------------------------
# Direct Drum Kit workflow ids are now catalogued (Slice 2)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("workflow_id", ["drum_kit_direct", "drum_kit_split"])
def test_direct_drum_kit_workflow_ids_are_now_catalogued(workflow_id):
    catalogs = workflow_contracts.validate_catalogs(CATALOG_DIR)
    ids = {w["workflow_id"] for w in catalogs["workflows"]}
    assert workflow_id in ids


def test_unknown_drum_kit_style_workflow_id_still_fails_closed():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "dks_direct", "drumsep_mdx23c", "auto", catalog_dir=CATALOG_DIR, probe=CPU_PROBE
        )
    assert excinfo.value.code == REASON_UNKNOWN_WORKFLOW


# ---------------------------------------------------------------------------
# 11. contract/schema corruption is not silently ignored
# ---------------------------------------------------------------------------


def test_corrupt_catalog_directory_fails_closed_without_raw_traceback(tmp_path):
    (tmp_path / "capabilities.v1.json").write_text('{"schema_version": "1.0.0", "capabilities": [', encoding="utf-8")
    (tmp_path / "models.v1.json").write_text(
        (CATALOG_DIR / "models.v1.json").read_text(encoding="utf-8"), encoding="utf-8"
    )
    (tmp_path / "workflows.v1.json").write_text(
        (CATALOG_DIR / "workflows.v1.json").read_text(encoding="utf-8"), encoding="utf-8"
    )
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("normal_stems", "htdemucs", "cpu", catalog_dir=tmp_path, probe=CPU_PROBE)
    assert excinfo.value.code == REASON_CONTRACT_LOAD_ERROR
    assert "Traceback" not in excinfo.value.detail


def test_missing_catalog_directory_fails_closed():
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "htdemucs", "cpu", catalog_dir=Path("/nonexistent/catalog/dir"), probe=CPU_PROBE
        )
    assert excinfo.value.code == REASON_CONTRACT_LOAD_ERROR


# ---------------------------------------------------------------------------
# 12. existing Slice-0/1 contract tests remain green -- sanity: the real
# catalogs this module loads still pass validate_catalogs on its own.
# ---------------------------------------------------------------------------


def test_real_catalogs_still_pass_validation():
    workflow_contracts.validate_catalogs(CATALOG_DIR)


# ---------------------------------------------------------------------------
# Default probe wiring sanity (no fakes): resolving with the real
# DEFAULT_CAPABILITY_PROBE against stemwerk_core.devices must not explode.
# ---------------------------------------------------------------------------


def test_default_probe_cpu_request_resolves_without_gpu_hardware():
    from stemwerk_core.runtime_resolution import DEFAULT_CAPABILITY_PROBE

    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=DEFAULT_CAPABILITY_PROBE
    )
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
