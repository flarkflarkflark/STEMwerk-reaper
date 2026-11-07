from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

try:
    from jsonschema import Draft202012Validator
    from jsonschema.exceptions import ValidationError as JsonSchemaValidationError
    from referencing import Registry, Resource
except ImportError:
    Draft202012Validator = None
    import fastjsonschema


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
    validate_workflow_request,
    validate_workflow_result,
)


GOLDENS = (
    FIXTURES / "golden_2310" / "normal_stems_new_tracks.json",
    FIXTURES / "golden_2310" / "normal_stems_in_place.json",
)

PARITY_CORPUS = FIXTURES / "workflow_result_validator_parity.v1.json"


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
    normal_routes = {
        route["capability_id"]: route["deliverable_ids"]
        for route in by_workflow["normal_stems"]["deliverable_routes"]
    }
    assert normal_routes == {
        "normal_stems_4": ["vocals", "drums", "bass", "other"],
        "normal_stems_6": ["vocals", "drums", "bass", "other", "guitar", "piano"],
    }
    for workflow_id in ("drum_kit_direct", "drum_kit_split"):
        assert by_workflow[workflow_id]["deliverable_routes"] == [
            {
                "capability_id": "drum_kit_6",
                "deliverable_ids": ["kick", "snare", "toms", "hi-hat", "ride", "crash"],
            }
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
        (
            lambda docs: docs["workflows"]["workflows"][0]["deliverable_routes"][1][
                "deliverable_ids"
            ].remove("piano"),
            "must exactly match capability",
        ),
        (
            lambda docs: docs["workflows"]["workflows"][0]["deliverable_routes"][0][
                "deliverable_ids"
            ].append("guitar"),
            "must exactly match capability",
        ),
        (
            lambda docs: docs["workflows"]["workflows"][0]["deliverable_routes"].append(
                copy.deepcopy(docs["workflows"]["workflows"][0]["deliverable_routes"][0])
            ),
            "exactly one deliverable route",
        ),
        (
            lambda docs: docs["workflows"]["workflows"][0]["deliverable_routes"].pop(),
            "exactly one deliverable route",
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


def _catalog_copy(tmp_path: Path, **overrides) -> Path:
    """Write a mutable copy of the real v1 catalog dir, applying overrides.

    Each keyword is one of "capabilities" | "models" | "workflows" mapped to
    a callable that mutates the parsed document in place.
    """

    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    dest = tmp_path / "catalog"
    dest.mkdir()
    for name in ("capabilities", "models", "workflows"):
        doc = json.loads((catalog_dir / f"{name}.v1.json").read_text(encoding="utf-8"))
        if name in overrides:
            overrides[name](doc)
        (dest / f"{name}.v1.json").write_text(json.dumps(doc), encoding="utf-8")
    return dest


# ---------------------------------------------------------------------------
# Astra Slice-0 hardening regressions
# ---------------------------------------------------------------------------


def test_catalog_rejects_model_referencing_unknown_capability_id(tmp_path):
    catalog_dir = _catalog_copy(
        tmp_path, models=lambda doc: doc["models"][0].__setitem__("capability_id", "no_such_capability")
    )
    # s2 wording: "models.<id>.capability_id references unknown capability: ..."
    with pytest.raises(ContractError, match="references unknown capability"):
        validate_catalogs(catalog_dir)


def test_catalog_rejects_model_output_semantic_ids_disagreeing_with_capability(tmp_path):
    catalog_dir = _catalog_copy(
        tmp_path, models=lambda doc: doc["models"][0].__setitem__("output_semantic_ids", ["vocals"])
    )
    # s2 wording: "models.<id>.output_semantic_ids must match capability ..."
    with pytest.raises(ContractError, match="output_semantic_ids must match capability"):
        validate_catalogs(catalog_dir)


def test_catalog_rejects_workflow_with_zero_ordered_stages(tmp_path):
    catalog_dir = _catalog_copy(
        tmp_path, workflows=lambda doc: doc["workflows"][0].__setitem__("ordered_stages", [])
    )
    with pytest.raises(ContractError, match="ordered_stages must not be empty"):
        validate_catalogs(catalog_dir)


def test_catalog_rejects_workflow_stage_referencing_unknown_capability_id(tmp_path):
    # s2 workflow-stage schema uses capability_ids (a list of stable ids).
    catalog_dir = _catalog_copy(
        tmp_path,
        workflows=lambda doc: doc["workflows"][0]["ordered_stages"][0].__setitem__(
            "capability_ids", ["no_such_capability"]
        ),
    )
    with pytest.raises(ContractError, match="references unknown capability"):
        validate_catalogs(catalog_dir)


def test_bundle_accepts_golden_fixture_against_real_catalog_relational_closure():
    catalog_dir = ROOT / "scripts" / "reaper" / "catalog"
    catalogs = validate_catalogs(catalog_dir)
    for path in GOLDENS:
        payload = load_json(path)
        validate_bundle(payload["contracts"], catalogs=catalogs)


def test_bundle_rejects_stage_unknown_model_id_when_catalogs_supplied():
    catalogs = validate_catalogs(ROOT / "scripts" / "reaper" / "catalog")
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_request"]["stages"][0]["model_id"] = "totally_unknown_model"
    with pytest.raises(ContractError, match="unknown model_id"):
        validate_bundle(bundle, catalogs=catalogs)


def test_bundle_rejects_stage_unknown_capability_id_when_catalogs_supplied():
    catalogs = validate_catalogs(ROOT / "scripts" / "reaper" / "catalog")
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_request"]["stages"][0]["capability_id"] = "totally_unknown_capability"
    with pytest.raises(ContractError, match="unknown capability_id"):
        validate_bundle(bundle, catalogs=catalogs)


def test_bundle_allows_ordered_selective_deliverables_supported_by_selected_route():
    catalogs = validate_catalogs(ROOT / "scripts" / "reaper" / "catalog")
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_request"]["deliverable_ids"] = ["vocals"]
    bundle["workflow_result"]["artifacts"] = bundle["workflow_result"]["artifacts"][:1]
    bundle["workflow_result"]["deliverables"] = bundle["workflow_result"]["deliverables"][:1]
    bundle["import_plan"]["imports"] = bundle["import_plan"]["imports"][:1]

    validate_bundle(bundle, catalogs=catalogs)


def test_bundle_rejects_deliverable_unsupported_by_selected_route():
    catalogs = validate_catalogs(ROOT / "scripts" / "reaper" / "catalog")
    bundle = copy.deepcopy(_bundle())
    stage = bundle["workflow_request"]["stages"][0]
    stage["outputs"] = [{"port_id": "guitar", "semantic_id": "guitar", "kind": "audio"}]
    bundle["workflow_request"]["deliverable_ids"] = ["guitar"]

    artifact = copy.deepcopy(bundle["workflow_result"]["artifacts"][0])
    artifact.update(artifact_id="artifact_guitar_001", semantic_id="guitar", relative_path="outputs/guitar.wav")
    artifact["producer"]["port_id"] = "guitar"
    bundle["workflow_result"]["artifacts"] = [artifact]
    bundle["workflow_result"]["deliverables"] = [
        {"semantic_id": "guitar", "artifact_id": "artifact_guitar_001"}
    ]

    imported = copy.deepcopy(bundle["import_plan"]["imports"][0])
    imported.update(semantic_id="guitar", artifact_id="artifact_guitar_001")
    bundle["import_plan"]["imports"] = [imported]

    with pytest.raises(ContractError, match="unsupported deliverable"):
        validate_bundle(bundle, catalogs=catalogs)


def test_bundle_without_catalogs_stays_structural_only_for_stage_ids():
    # Documents the current, deliberate legacy behavior: relational closure is
    # opt-in via the `catalogs=` parameter so bundle validation stays pure and
    # catalog-agnostic when a caller has none available.
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_request"]["stages"][0]["model_id"] = "totally_unknown_model"
    validate_bundle(bundle)


def test_bundle_rejects_actual_runtime_model_disagreement_without_fallback():
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_result"]["actual_runtime"]["model_id"] = "htdemucs_ft"
    with pytest.raises(ContractError, match="actual_runtime.model_id disagrees"):
        validate_bundle(bundle)


def test_bundle_allows_actual_runtime_model_disagreement_with_fallback_applied():
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_result"]["actual_runtime"]["model_id"] = "htdemucs_ft"
    bundle["workflow_result"]["actual_runtime"]["fallback_applied"] = True
    validate_bundle(bundle)


@pytest.mark.parametrize("state", ["failed", "cancelled", "running", "queued", "blocked"])
def test_bundle_rejects_non_succeeded_state_with_nonempty_import_plan(state):
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_result"]["state"] = state
    with pytest.raises(ContractError, match="deliverables must be empty|imports must be empty"):
        validate_bundle(bundle)


@pytest.mark.parametrize("state", ["failed", "cancelled", "running", "queued", "blocked"])
def test_non_succeeded_result_is_representable_without_fabricated_runtime_or_outputs(state):
    """Core invariant: only a completed, successful result may authorize
    import, but every other state must remain representable without
    fabricating execution/runtime evidence that never existed."""

    bundle = copy.deepcopy(_bundle())
    bundle["workflow_result"]["state"] = state
    del bundle["workflow_result"]["actual_runtime"]
    bundle["workflow_result"]["deliverables"] = []
    bundle["workflow_result"]["artifacts"] = []
    bundle["import_plan"]["imports"] = []
    validate_bundle(bundle)


def test_succeeded_result_still_requires_actual_runtime():
    bundle = copy.deepcopy(_bundle())
    del bundle["workflow_result"]["actual_runtime"]
    with pytest.raises(ContractError, match="actual_runtime"):
        validate_bundle(bundle)


def test_workflow_request_rejects_empty_deliverable_ids():
    bundle = copy.deepcopy(_bundle())
    bundle["workflow_request"]["deliverable_ids"] = []
    with pytest.raises(ContractError, match="deliverable_ids must not be empty"):
        validate_workflow_request(bundle["workflow_request"])


def test_source_plan_rejects_more_than_one_source():
    bundle = copy.deepcopy(_bundle())
    second = copy.deepcopy(bundle["workflow_request"]["source_plan"]["sources"][0])
    second["source_id"] = "source_002"
    second["order"] = 2
    second["item_identity"] = "source_item_002"
    bundle["workflow_request"]["source_plan"]["sources"].append(second)
    with pytest.raises(ContractError, match="exactly one source"):
        validate_bundle(bundle)


def test_import_plan_rejects_order_field_disagreeing_with_array_position():
    bundle = copy.deepcopy(_bundle())
    imports = bundle["import_plan"]["imports"]
    imports[0]["order"], imports[1]["order"] = imports[1]["order"], imports[0]["order"]
    with pytest.raises(ContractError, match="import order must match array position"):
        validate_bundle(bundle)


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


# Field vocabularies the hand validators accept via their `_only_keys(...)`
# calls in workflow_contracts.py. Kept here as an explicit cross-check so a
# field added to one representation but not the other is caught, closing the
# gap where "schemas are valid JSON" was previously the only schema test.
_VALIDATOR_FIELDS = {
    "source-plan.v1.schema.json": {"schema_version", "source_plan_id", "sources"},
    "stage-spec.v1.schema.json": {"schema_version", "stage_id", "order", "capability_id", "model_id", "input", "outputs"},
    "artifact.v1.schema.json": {"schema_version", "artifact_id", "kind", "semantic_id", "relative_path", "producer"},
    "workflow-request.v1.schema.json": {"schema_version", "request_id", "workflow_id", "source_plan", "stages", "deliverable_ids", "requested_runtime"},
    "workflow-result.v1.schema.json": {"schema_version", "request_id", "workflow_id", "state", "actual_runtime", "artifacts", "deliverables"},
    "import-plan.v1.schema.json": {"schema_version", "request_id", "workflow_id", "destination", "grouping", "create_folder", "source_after", "origin_project_policy", "imports"},
}

_CONDITIONALLY_REQUIRED_FIELDS = {
    "workflow-result.v1.schema.json": {"actual_runtime"},
}


def test_schema_field_vocabulary_matches_hand_validators():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    for filename, expected_fields in _VALIDATOR_FIELDS.items():
        schema = json.loads((schema_dir / filename).read_text(encoding="utf-8"))
        schema_fields = set(schema["properties"])
        assert schema_fields == expected_fields, f"{filename}: schema properties {schema_fields} != validator fields {expected_fields}"
        conditional = _CONDITIONALLY_REQUIRED_FIELDS.get(filename, set())
        assert set(schema["required"]) == expected_fields - conditional, f"{filename}: required fields drifted"
        assert schema["additionalProperties"] is False, f"{filename}: must reject unknown fields like the hand validators do"


def test_workflow_request_schema_composes_nested_contract_schemas():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    request_schema = json.loads((schema_dir / "workflow-request.v1.schema.json").read_text(encoding="utf-8"))
    assert request_schema["properties"]["source_plan"]["$ref"] == "source-plan.v1.schema.json"
    assert request_schema["properties"]["stages"]["items"]["$ref"] == "stage-spec.v1.schema.json"

    result_schema = json.loads((schema_dir / "workflow-result.v1.schema.json").read_text(encoding="utf-8"))
    assert result_schema["properties"]["artifacts"]["items"]["$ref"] == "artifact.v1.schema.json"


def test_workflow_request_schema_types_selected_deliverable_ids():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    schema = json.loads((schema_dir / "workflow-request.v1.schema.json").read_text(encoding="utf-8"))
    deliverables = schema["properties"]["deliverable_ids"]

    assert deliverables["items"] == {"type": "string"}
    assert "selected subset" in deliverables["description"]


def test_source_plan_schema_matches_slice0_single_source_restriction():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    schema = json.loads((schema_dir / "source-plan.v1.schema.json").read_text(encoding="utf-8"))
    assert schema["properties"]["sources"]["maxItems"] == 1


def _shared_parity_document(case: dict) -> dict:
    if "document" in case:
        return case["document"]
    payload = load_json(FIXTURES / case["fixture"])
    for key in case["document_path"]:
        payload = payload[key]
    return payload


def _workflow_result_schema_validator():
    schema_dir = ROOT / "scripts" / "reaper" / "catalog" / "schemas"
    schema = json.loads((schema_dir / "workflow-result.v1.schema.json").read_text(encoding="utf-8"))

    if Draft202012Validator is not None:
        resources = []
        for path in schema_dir.glob("*.schema.json"):
            document = json.loads(path.read_text(encoding="utf-8"))
            resources.append((document["$id"], Resource.from_contents(document)))
        validator = Draft202012Validator(schema, registry=Registry().with_resources(resources))
        return validator.validate, JsonSchemaValidationError

    def load_schema(uri: str) -> dict:
        return json.loads((schema_dir / uri.rsplit("/", 1)[-1]).read_text(encoding="utf-8"))

    return (
        fastjsonschema.compile(schema, handlers={"https": load_schema}),
        fastjsonschema.JsonSchemaException,
    )


@pytest.mark.parametrize(
    "case",
    load_json(PARITY_CORPUS)["cases"],
    ids=lambda case: case["id"],
)
def test_shared_workflow_result_corpus_matches_python_and_json_schema(case):
    document = _shared_parity_document(case)

    try:
        validate_workflow_result(document)
        python_accepted = True
    except ContractError:
        python_accepted = False

    schema_validator, schema_error = _workflow_result_schema_validator()
    try:
        schema_validator(document)
        schema_accepted = True
    except schema_error:
        schema_accepted = False

    assert python_accepted is case["expected"]["python"]
    assert schema_accepted is case["expected"]["schema"]
