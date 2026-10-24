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
    REASON_BACKEND_NOT_PERMITTED,
    REASON_BACKEND_UNAVAILABLE,
    REASON_CONTRACT_LOAD_ERROR,
    REASON_MODEL_CAPABILITY_MISMATCH,
    REASON_OK_AUTO,
    REASON_OK_EXPLICIT,
    REASON_UNKNOWN_CAPABILITY,
    REASON_UNKNOWN_MODEL,
    REASON_UNKNOWN_WORKFLOW,
    REASON_UNSUPPORTED_STAGE_COUNT,
    _resolve_from_catalogs,
    resolve_execution_plan,
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
    probe = _fake_probe(select_device_map={"cpu": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=probe
    )
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
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "does_not_exist", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=probe
        )
    assert excinfo.value.code == REASON_UNKNOWN_WORKFLOW


# ---------------------------------------------------------------------------
# 3. valid workflow -> model reference resolves
# ---------------------------------------------------------------------------


def test_valid_workflow_model_reference_resolves():
    probe = _fake_probe(select_device_map={"cpu": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs_ft", "cpu", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.model_id == "htdemucs_ft"
    assert plan.capability_id == "normal_stems_4"


# ---------------------------------------------------------------------------
# 4. broken workflow -> model reference fails closed
#
# The real on-disk catalogs are hard-locked (see
# workflow_contracts.validate_catalogs) to a single capability that every
# model already matches, so a mismatch cannot be reproduced through real
# catalog files. Exercise the cross-reference check directly against a
# hand-built (but schema-shaped) catalog to prove the mechanism.
# ---------------------------------------------------------------------------


def test_broken_workflow_model_reference_fails_closed():
    catalogs = {
        "capabilities": [{"capability_id": "cap_a"}, {"capability_id": "cap_b"}],
        "models": [{"model_id": "model_x", "capability_id": "cap_b"}],
        "workflows": [
            {
                "workflow_id": "wf",
                "ordered_stages": [{"stage_id": "stage1", "capability_id": "cap_a"}],
            }
        ],
    }
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        _resolve_from_catalogs(
            catalogs, "wf", "model_x", "cpu",
            probe=probe, backend_policy={"cap_a": frozenset({"cpu"})},
        )
    assert excinfo.value.code == REASON_MODEL_CAPABILITY_MISMATCH


def test_unknown_model_fails_closed():
    probe = _fake_probe(select_device_map={"cpu": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "not_a_real_model", "cpu", catalog_dir=CATALOG_DIR, probe=probe
        )
    assert excinfo.value.code == REASON_UNKNOWN_MODEL


def test_workflow_stage_referencing_unknown_capability_fails_closed():
    catalogs = {
        "capabilities": [{"capability_id": "cap_a"}],
        "models": [{"model_id": "model_x", "capability_id": "cap_a"}],
        "workflows": [
            {
                "workflow_id": "wf",
                "ordered_stages": [{"stage_id": "stage1", "capability_id": "cap_missing"}],
            }
        ],
    }
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        _resolve_from_catalogs(
            catalogs, "wf", "model_x", "cpu",
            probe=probe, backend_policy={},
        )
    assert excinfo.value.code == REASON_UNKNOWN_CAPABILITY


def test_multi_stage_workflow_is_out_of_slice1_scope():
    catalogs = {
        "capabilities": [{"capability_id": "cap_a"}],
        "models": [{"model_id": "model_x", "capability_id": "cap_a"}],
        "workflows": [
            {
                "workflow_id": "wf",
                "ordered_stages": [
                    {"stage_id": "stage1", "capability_id": "cap_a"},
                    {"stage_id": "stage2", "capability_id": "cap_a"},
                ],
            }
        ],
    }
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        _resolve_from_catalogs(
            catalogs, "wf", "model_x", "cpu",
            probe=probe, backend_policy={"cap_a": frozenset({"cpu"})},
        )
    assert excinfo.value.code == REASON_UNSUPPORTED_STAGE_COUNT


# ---------------------------------------------------------------------------
# 5. explicit ROCm + supported model/workflow -> ROCm
# ---------------------------------------------------------------------------


def test_explicit_rocm_supported_resolves_to_rocm():
    probe = _rocm_capable_probe()
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "cuda:0", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "cuda:0"
    assert plan.fallback_applied is False
    assert plan.reason_code == REASON_OK_EXPLICIT


# ---------------------------------------------------------------------------
# 6. Auto on mocked AMD Linux/ROCm capability set -> intended ROCm result
# ---------------------------------------------------------------------------


def test_auto_on_amd_linux_rocm_resolves_to_rocm_not_cpu():
    probe = _rocm_capable_probe(auto_preferred=ROCM_DEVICE)
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "auto", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "cuda:0"
    assert plan.fallback_applied is False
    assert plan.reason_code == REASON_OK_AUTO


def test_auto_with_no_gpu_falls_back_to_cpu_deterministically():
    probe = _fake_probe(
        select_device_map={"auto": ("cpu", "CPU")},
        kind_map={"cpu": "cpu"},
        auto_preferred=None,
    )
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "auto", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "cpu"
    assert plan.fallback_applied is True
    assert plan.reason_code == REASON_OK_AUTO


# ---------------------------------------------------------------------------
# 7. explicit unsupported ROCm combination -> deterministic rejection
# ---------------------------------------------------------------------------


def test_explicit_rocm_rejected_when_capability_policy_forbids_it():
    probe = _rocm_capable_probe()
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "htdemucs", "cuda:0",
            catalog_dir=CATALOG_DIR, probe=probe,
            backend_policy={"normal_stems_4": frozenset({"cpu"})},
        )
    assert excinfo.value.code == REASON_BACKEND_NOT_PERMITTED


# ---------------------------------------------------------------------------
# 8. ROCm unavailable on machine -> correct unavailable result
# ---------------------------------------------------------------------------


def test_explicit_rocm_unavailable_on_machine_is_rejected_not_downgraded():
    probe = _fake_probe(
        select_device_map={"cuda:0": ("cpu", "CPU")},
        kind_map={"cpu": "cpu"},
    )
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "htdemucs", "cuda:0", catalog_dir=CATALOG_DIR, probe=probe
        )
    assert excinfo.value.code == REASON_BACKEND_UNAVAILABLE


# ---------------------------------------------------------------------------
# 9. CPU-compatible workflow still resolves correctly
# ---------------------------------------------------------------------------


def test_cpu_explicit_request_resolves_correctly():
    probe = _fake_probe(select_device_map={"cpu": ("cpu", "CPU")}, kind_map={"cpu": "cpu"})
    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "cpu", catalog_dir=CATALOG_DIR, probe=probe
    )
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
    assert plan.fallback_applied is False


# ---------------------------------------------------------------------------
# 10. Direct Drum Kit is not represented in the Slice-0 catalog: the resolver
# must refuse it (fail closed) rather than silently misrouting it, proving
# it stays entirely on its existing legacy dispatch. See
# tests/test_linux_drumsep_rocm_fallback_chain.py for direct coverage of
# that legacy dispatch itself.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("drum_kit_workflow_id", ["drum_kit_split", "drumkit", "dks_direct", "dks_extract"])
def test_direct_drum_kit_workflow_ids_are_not_in_the_slice0_catalog(drum_kit_workflow_id):
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            drum_kit_workflow_id, "MDX23C-DrumSep-aufr33-jarredou.ckpt", "auto",
            catalog_dir=CATALOG_DIR, probe=probe,
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
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan("normal_stems", "htdemucs", "cpu", catalog_dir=tmp_path, probe=probe)
    assert excinfo.value.code == REASON_CONTRACT_LOAD_ERROR
    assert "Traceback" not in excinfo.value.detail


def test_missing_catalog_directory_fails_closed():
    probe = _fake_probe()
    with pytest.raises(ResolutionError) as excinfo:
        resolve_execution_plan(
            "normal_stems", "htdemucs", "cpu", catalog_dir=Path("/nonexistent/catalog/dir"), probe=probe
        )
    assert excinfo.value.code == REASON_CONTRACT_LOAD_ERROR


# ---------------------------------------------------------------------------
# 12. existing Slice-0 contract tests remain green -- sanity: the real
# catalogs this module loads still pass validate_catalogs on its own.
# ---------------------------------------------------------------------------


def test_real_catalogs_still_pass_slice0_validation():
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
