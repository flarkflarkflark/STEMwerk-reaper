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


def test_normal_stems_catalog_is_deliberately_minimal():
    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    catalogs = validate_catalogs(catalog_dir)

    assert [entry["capability_id"] for entry in catalogs["capabilities"]] == [
        "normal_stems_4"
    ]
    assert [entry["model_id"] for entry in catalogs["models"]] == [
        "htdemucs",
        "htdemucs_ft",
    ]
    assert [entry["workflow_id"] for entry in catalogs["workflows"]] == [
        "normal_stems"
    ]
    assert catalogs["workflows"][0]["deliverable_ids"] == [
        "vocals",
        "drums",
        "bass",
        "other",
    ]


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
