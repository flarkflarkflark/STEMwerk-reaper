from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
FIXTURES = ROOT / "tests" / "fixtures"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.workflow_contracts import (  # noqa: E402
    ContractError,
    load_json,
    validate_bundle,
    validate_catalogs,
)


GOLDENS = (
    FIXTURES / "golden_2310" / "normal_stems_new_tracks.json",
    FIXTURES / "golden_2310" / "normal_stems_in_place.json",
)


def _bundle() -> dict:
    return load_json(GOLDENS[0])["contracts"]


def _artifact_path(bundle: dict, path: str) -> None:
    bundle["workflow_result"]["artifacts"][0]["relative_path"] = path


def _reference_stage_output(bundle: dict, stage_id: str) -> None:
    bundle["workflow_request"]["stages"][0]["input"] = {
        "kind": "stage_output",
        "stage_id": stage_id,
        "port_id": "vocals",
        "artifact_kind": "audio",
    }


def _add_future_stage(bundle: dict) -> None:
    future = copy.deepcopy(bundle["workflow_request"]["stages"][0])
    future.update(stage_id="separate_future_002", order=2)
    bundle["workflow_request"]["stages"].append(future)


def test_public_2310_goldens_validate_as_identical_contract_bundles():
    for path in GOLDENS:
        payload = load_json(path)
        assert payload["characterizes_version"] == "2.3.1.0"
        assert payload["manual_reaper_smoke"] == "NOT TESTED"
        validate_bundle(payload["contracts"])


def test_catalogs_cover_exactly_the_known_2_3_production_routes():
    """Slice 2 completeness lock: growing the catalog requires updating this
    test consciously, mirroring Slice 0's original minimality lock now that
    the catalog covers every 2.3 production route relevant to resolution."""

    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    catalogs = validate_catalogs(catalog_dir)

    assert {entry["capability_id"] for entry in catalogs["capabilities"]} == {
        "normal_stems_4",
        "normal_stems_6",
        "drum_kit_6",
    }
    assert {entry["model_id"] for entry in catalogs["models"]} == {
        "htdemucs",
        "htdemucs_ft",
        "htdemucs_6s",
        "hdemucs_mmi",
        "drumsep_mdx23c",
    }
    assert {entry["workflow_id"] for entry in catalogs["workflows"]} == {
        "normal_stems",
        "drum_kit_direct",
        "drum_kit_split",
    }

    by_workflow = {entry["workflow_id"]: entry for entry in catalogs["workflows"]}
    assert by_workflow["normal_stems"]["deliverable_ids"] == [
        "vocals",
        "drums",
        "bass",
        "other",
    ]
    assert by_workflow["drum_kit_direct"]["deliverable_ids"] == [
        "kick",
        "snare",
        "toms",
        "hi-hat",
        "ride",
        "crash",
    ]
    assert by_workflow["drum_kit_split"]["deliverable_ids"] == [
        "kick",
        "snare",
        "toms",
        "hi-hat",
        "ride",
        "crash",
    ]
    assert len(by_workflow["drum_kit_split"]["ordered_stages"]) == 2


def test_model_catalog_role_field_marks_user_selectable_vs_internal():
    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    catalogs = validate_catalogs(catalog_dir)
    by_model = {entry["model_id"]: entry for entry in catalogs["models"]}

    assert by_model["htdemucs"]["role"] == "user_selectable"
    assert by_model["htdemucs_ft"]["role"] == "user_selectable"
    assert by_model["htdemucs_6s"]["role"] == "user_selectable"
    assert by_model["hdemucs_mmi"]["role"] == "internal"
    assert by_model["drumsep_mdx23c"]["role"] == "internal"


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda b: b["workflow_request"].update(schema_version="2.0.0"), "schema_version"),
        (
            lambda b: b["workflow_request"]["source_plan"]["sources"].append(
                copy.deepcopy(b["workflow_request"]["source_plan"]["sources"][0])
            ),
            "duplicate source_id",
        ),
        (
            lambda b: b["workflow_request"]["stages"][0]["outputs"].append(
                copy.deepcopy(b["workflow_request"]["stages"][0]["outputs"][0])
            ),
            "duplicate output port_id",
        ),
        (
            lambda b: b["workflow_request"]["stages"][0]["input"].update(
                source_id="source_missing"
            ),
            "missing source",
        ),
        (
            lambda b: b["workflow_result"]["deliverables"][0].update(
                semantic_id="guitar"
            ),
            "undeclared deliverable",
        ),
        (
            lambda b: b["workflow_result"].update(request_id="request_other"),
            "request identity mismatch",
        ),
        (
            lambda b: b["workflow_result"].update(state="maybe_finished"),
            "invalid processing state",
        ),
        (
            lambda b: b["workflow_result"]["artifacts"][0]["producer"].update(
                stage_id="stage_missing"
            ),
            "missing producer stage",
        ),
        (
            lambda b: b["import_plan"]["imports"][0].update(
                artifact_id="artifact_missing"
            ),
            "invalid artifact reference",
        ),
        (
            lambda b: b["workflow_request"].update(
                reaproject_pointer="ReaProject* 0x1234"
            ),
            "serialized REAPER pointer",
        ),
        (
            lambda b: b["workflow_request"].update(deliverable_ids=["Vocals"]),
            "stable semantic id",
        ),
        (
            lambda b: b["workflow_request"]["stages"][0].update(predicate="always"),
            "unsupported field",
        ),
    ],
)
def test_invalid_contract_bundles_fail_closed(mutate, message):
    bundle = copy.deepcopy(_bundle())
    mutate(bundle)

    with pytest.raises(ContractError, match=message):
        validate_bundle(bundle)


@pytest.mark.parametrize(
    "path",
    [
        "..",
        ".",
        "outputs/../x.wav",
        "outputs/./x.wav",
        "outputs//x.wav",
        "outputs/x.wav/",
        "../outputs/x.wav",
        "./outputs/x.wav",
        "/tmp/x.wav",
    ],
)
def test_artifact_paths_reject_raw_invalid_segments(path: str):
    bundle = copy.deepcopy(_bundle())
    _artifact_path(bundle, path)

    with pytest.raises(ContractError, match="relative_path"):
        validate_bundle(bundle)


@pytest.mark.parametrize(
    "path",
    ["outputs/vocals.wav", "stages/01-normal/vocals.wav"],
)
def test_artifact_paths_accept_normal_workspace_relative_paths(path: str):
    bundle = copy.deepcopy(_bundle())
    _artifact_path(bundle, path)

    validate_bundle(bundle)


def test_forward_stage_reference_is_rejected():
    bundle = copy.deepcopy(_bundle())
    _add_future_stage(bundle)
    _reference_stage_output(bundle, "separate_future_002")

    with pytest.raises(ContractError, match="non-earlier producer stage"):
        validate_bundle(bundle)


def test_self_cycle_stage_reference_is_rejected():
    bundle = copy.deepcopy(_bundle())
    _reference_stage_output(bundle, "separate_normal_001")

    with pytest.raises(ContractError, match="non-earlier producer stage"):
        validate_bundle(bundle)


def test_json_reader_rejects_duplicate_object_keys(tmp_path: Path):
    path = tmp_path / "duplicate.json"
    path.write_text('{"schema_version":"1.0.0","schema_version":"1.0.0"}', encoding="utf-8")

    with pytest.raises(ContractError, match="duplicate JSON key"):
        load_json(path)


def _real_catalog_documents() -> dict[str, dict]:
    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    return {
        "capabilities": load_json(catalog_dir / "capabilities.v1.json"),
        "models": load_json(catalog_dir / "models.v1.json"),
        "workflows": load_json(catalog_dir / "workflows.v1.json"),
    }


def _write_catalog_dir(tmp_path: Path, documents: dict[str, dict]) -> Path:
    for name, document in documents.items():
        (tmp_path / f"{name}.v1.json").write_text(json.dumps(document), encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda docs: docs["workflows"]["workflows"][2]["ordered_stages"][1].update(
                input_stage_id="stage_does_not_exist"
            ),
            "must reference an earlier",
        ),
        (
            lambda docs: docs["workflows"]["workflows"][2]["ordered_stages"][1].update(
                input_port_id="kick"
            ),
            "is not produced by stage",
        ),
        (
            lambda docs: docs["models"]["models"][0].update(capability_id="no_such_capability"),
            "references unknown capability",
        ),
        (
            lambda docs: docs["workflows"]["workflows"][0]["ordered_stages"][0].update(
                capability_ids=["no_such_capability"]
            ),
            "references unknown capability",
        ),
        (
            lambda docs: docs["capabilities"]["capabilities"][0].pop("permitted_backends"),
            "permitted_backends",
        ),
        (
            lambda docs: docs["models"]["models"][0].pop("role"),
            "role",
        ),
        (
            lambda docs: docs["models"]["models"][0].update(
                output_semantic_ids=["vocals", "drums", "bass", "other", "extra"]
            ),
            "output_semantic_ids must match capability",
        ),
        (
            lambda docs: docs["capabilities"]["capabilities"][0]["permitted_backends"].append("tpu"),
            "unknown backend kind",
        ),
    ],
)
def test_catalog_cross_references_fail_closed(tmp_path: Path, mutate, message):
    documents = copy.deepcopy(_real_catalog_documents())
    mutate(documents)
    catalog_dir = _write_catalog_dir(tmp_path, documents)

    with pytest.raises(ContractError, match=message):
        validate_catalogs(catalog_dir)


def test_missing_workflow_referenced_by_nothing_still_requires_known_set(tmp_path: Path):
    documents = copy.deepcopy(_real_catalog_documents())
    documents["workflows"]["workflows"].pop()
    catalog_dir = _write_catalog_dir(tmp_path, documents)

    with pytest.raises(ContractError, match="workflow catalog must contain exactly"):
        validate_catalogs(catalog_dir)


def test_schemas_are_valid_json_and_cover_exactly_six_contracts():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    names = sorted(path.name for path in schema_dir.glob("*.schema.json"))
    assert names == [
        "artifact.v1.schema.json",
        "import-plan.v1.schema.json",
        "source-plan.v1.schema.json",
        "stage-spec.v1.schema.json",
        "workflow-request.v1.schema.json",
        "workflow-result.v1.schema.json",
    ]
    for path in schema_dir.glob("*.schema.json"):
        schema = json.loads(path.read_text(encoding="utf-8"))
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert schema["properties"]["schema_version"]["const"] == "1.0.0"
