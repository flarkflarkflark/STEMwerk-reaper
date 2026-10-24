"""Pure v1 readers and validators for STEMwerk workflow contracts.

This module is intentionally disconnected from production dispatch.  It uses
only the Python standard library and never probes a runtime, loads a model, or
mutates the filesystem.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping


SCHEMA_VERSION = "1.0.0"
_SEMANTIC_ID = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
_PROCESSING_STATES = frozenset({"queued", "running", "succeeded", "failed", "cancelled", "blocked"})
_DESTINATIONS = frozenset({"new_tracks", "in_place_takes"})
_GROUPINGS = frozenset({"per_item", "source_track"})
_SOURCE_AFTER = frozenset({"keep", "mute_item", "delete_item", "mute_track", "delete_track"})

# The v1 catalogs are a closed, deliberately-complete set covering every 2.3
# production separation route relevant to runtime resolution (Slice 2). This
# mirrors Slice 0's original minimality lock: growing the catalog requires a
# conscious update here, not silent drift.
_KNOWN_CAPABILITY_IDS = frozenset({"normal_stems_4", "normal_stems_6", "drum_kit_6"})
_KNOWN_MODEL_IDS = frozenset({"htdemucs", "htdemucs_ft", "htdemucs_6s", "hdemucs_mmi", "drumsep_mdx23c"})
_KNOWN_WORKFLOW_IDS = frozenset({"normal_stems", "drum_kit_direct", "drum_kit_split"})
_BACKEND_KINDS = frozenset({"cpu", "cuda", "rocm", "mps", "directml"})
_MODEL_ROLES = frozenset({"user_selectable", "internal"})


class ContractError(ValueError):
    """Raised when untrusted contract data violates the v1 boundary."""


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: str | Path) -> Any:
    """Read JSON without accepting ambiguous duplicate object keys."""

    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=_object_without_duplicate_keys)
    except ContractError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"invalid JSON file {path}: {exc}") from exc


def _mapping(value: Any, where: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ContractError(f"{where} must be an object")
    return value


def _list(value: Any, where: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractError(f"{where} must be an array")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise ContractError(f"{where} must be a non-empty string")
    return value


def _boolean(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        raise ContractError(f"{where} must be a boolean")
    return value


def _schema(document: Mapping[str, Any], where: str) -> None:
    version = _string(document.get("schema_version"), f"{where}.schema_version")
    if version != SCHEMA_VERSION:
        raise ContractError(
            f"{where}.schema_version {version!r} is unsupported; expected {SCHEMA_VERSION!r}"
        )


def _only_keys(document: Mapping[str, Any], allowed: set[str], where: str) -> None:
    unknown = set(document) - allowed
    if unknown:
        raise ContractError(f"{where} contains unsupported field: {sorted(unknown)[0]}")


def _stable_id(value: Any, where: str) -> str:
    identifier = _string(value, where)
    if not _SEMANTIC_ID.fullmatch(identifier):
        raise ContractError(f"{where} must be a stable semantic id")
    return identifier


def _unique(items: Iterable[Mapping[str, Any]], key: str, where: str) -> dict[str, Mapping[str, Any]]:
    result: dict[str, Mapping[str, Any]] = {}
    for index, item in enumerate(items):
        identity = _stable_id(item.get(key), f"{where}[{index}].{key}")
        if identity in result:
            raise ContractError(f"duplicate {key}: {identity}")
        result[identity] = item
    return result


def _reject_reaper_pointers(value: Any, where: str = "contract") -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            lowered = str(key).lower()
            if "reaproject" in lowered or lowered.endswith("_pointer"):
                raise ContractError(f"serialized REAPER pointer at {where}.{key}")
            _reject_reaper_pointers(child, f"{where}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_reaper_pointers(child, f"{where}[{index}]")
    elif isinstance(value, str):
        lowered = value.lower()
        if "reaproject*" in lowered or lowered.startswith("userdata: 0x"):
            raise ContractError(f"serialized REAPER pointer at {where}")


def _relative_path(value: Any, where: str) -> str:
    path = _string(value, where)
    raw_segments = path.split("/")
    if (
        path.startswith(("/", "\\"))
        or "\\" in path
        or re.match(r"^[A-Za-z]:", path)
        or any(segment in {"", ".", ".."} for segment in raw_segments)
    ):
        raise ContractError(f"{where} must be a workspace-contained relative_path")
    return path


def validate_source_plan(document: Any) -> Mapping[str, Any]:
    plan = _mapping(document, "source_plan")
    _only_keys(plan, {"schema_version", "source_plan_id", "sources"}, "source_plan")
    _schema(plan, "source_plan")
    _stable_id(plan.get("source_plan_id"), "source_plan.source_plan_id")
    sources = [_mapping(item, "source_plan.sources item") for item in _list(plan.get("sources"), "source_plan.sources")]
    if not sources:
        raise ContractError("source_plan.sources must not be empty")
    identities = _unique(sources, "source_id", "source_plan.sources")
    orders: set[int] = set()
    for source_id, source in identities.items():
        _only_keys(source, {"source_id", "order", "kind", "project_identity", "track_identity", "item_identity"}, f"source {source_id}")
        if source.get("kind") != "selected_item":
            raise ContractError(f"source {source_id} kind must be selected_item")
        order = source.get("order")
        if not isinstance(order, int) or isinstance(order, bool) or order < 1 or order in orders:
            raise ContractError("source ordering must contain unique positive integers")
        orders.add(order)
        _stable_id(source.get("project_identity"), f"source {source_id}.project_identity")
        _stable_id(source.get("track_identity"), f"source {source_id}.track_identity")
        _stable_id(source.get("item_identity"), f"source {source_id}.item_identity")
    if orders != set(range(1, len(sources) + 1)):
        raise ContractError("source ordering must be contiguous")
    return plan


def validate_stage_spec(document: Any) -> Mapping[str, Any]:
    stage = _mapping(document, "stage_spec")
    _only_keys(stage, {"schema_version", "stage_id", "order", "capability_id", "model_id", "input", "outputs"}, "stage_spec")
    _schema(stage, "stage_spec")
    _stable_id(stage.get("stage_id"), "stage_spec.stage_id")
    order = stage.get("order")
    if not isinstance(order, int) or isinstance(order, bool) or order < 1:
        raise ContractError("stage_spec.order must be a positive integer")
    _stable_id(stage.get("capability_id"), "stage_spec.capability_id")
    _stable_id(stage.get("model_id"), "stage_spec.model_id")
    input_ref = _mapping(stage.get("input"), "stage_spec.input")
    if input_ref.get("kind") == "source":
        _only_keys(input_ref, {"kind", "source_id", "artifact_kind"}, "stage_spec.input")
        _stable_id(input_ref.get("source_id"), "stage_spec.input.source_id")
    elif input_ref.get("kind") == "stage_output":
        _only_keys(input_ref, {"kind", "stage_id", "port_id", "artifact_kind"}, "stage_spec.input")
        _stable_id(input_ref.get("stage_id"), "stage_spec.input.stage_id")
        _stable_id(input_ref.get("port_id"), "stage_spec.input.port_id")
    else:
        raise ContractError("stage_spec.input.kind must be source or stage_output")
    if input_ref.get("artifact_kind") != "audio":
        raise ContractError("stage_spec.input.artifact_kind must be audio")
    outputs = [_mapping(item, "stage_spec.outputs item") for item in _list(stage.get("outputs"), "stage_spec.outputs")]
    if not outputs:
        raise ContractError("stage_spec.outputs must not be empty")
    ports: dict[str, Mapping[str, Any]] = {}
    for index, output in enumerate(outputs):
        port_id = _stable_id(output.get("port_id"), f"stage_spec.outputs[{index}].port_id")
        if port_id in ports:
            raise ContractError(f"duplicate output port_id: {port_id}")
        ports[port_id] = output
    semantics: set[str] = set()
    for port_id, output in ports.items():
        _only_keys(output, {"port_id", "semantic_id", "kind"}, f"output {port_id}")
        semantic_id = _stable_id(output.get("semantic_id"), f"output {port_id}.semantic_id")
        if semantic_id in semantics:
            raise ContractError(f"duplicate output semantic_id: {semantic_id}")
        semantics.add(semantic_id)
        if output.get("kind") != "audio":
            raise ContractError(f"output {port_id}.kind must be audio")
    return stage


def validate_artifact(document: Any) -> Mapping[str, Any]:
    artifact = _mapping(document, "artifact")
    _only_keys(artifact, {"schema_version", "artifact_id", "kind", "semantic_id", "relative_path", "producer"}, "artifact")
    _schema(artifact, "artifact")
    _stable_id(artifact.get("artifact_id"), "artifact.artifact_id")
    if artifact.get("kind") != "audio":
        raise ContractError("artifact.kind must be audio")
    _stable_id(artifact.get("semantic_id"), "artifact.semantic_id")
    _relative_path(artifact.get("relative_path"), "artifact.relative_path")
    producer = _mapping(artifact.get("producer"), "artifact.producer")
    _only_keys(producer, {"kind", "stage_id", "port_id"}, "artifact.producer")
    if producer.get("kind") != "stage_output":
        raise ContractError("artifact.producer.kind must be stage_output")
    _stable_id(producer.get("stage_id"), "artifact.producer.stage_id")
    _stable_id(producer.get("port_id"), "artifact.producer.port_id")
    return artifact


def validate_workflow_result(document: Any) -> Mapping[str, Any]:
    result = _mapping(document, "workflow_result")
    _only_keys(result, {"schema_version", "request_id", "workflow_id", "state", "actual_runtime", "artifacts", "deliverables"}, "workflow_result")
    _schema(result, "workflow_result")
    _stable_id(result.get("request_id"), "workflow_result.request_id")
    _stable_id(result.get("workflow_id"), "workflow_result.workflow_id")
    state = _string(result.get("state"), "workflow_result.state")
    if state not in _PROCESSING_STATES:
        raise ContractError(f"invalid processing state: {state}")
    runtime = _mapping(result.get("actual_runtime"), "workflow_result.actual_runtime")
    _only_keys(runtime, {"model_id", "requested_device", "actual_device", "fallback_applied"}, "workflow_result.actual_runtime")
    _stable_id(runtime.get("model_id"), "workflow_result.actual_runtime.model_id")
    _string(runtime.get("requested_device"), "workflow_result.actual_runtime.requested_device")
    _string(runtime.get("actual_device"), "workflow_result.actual_runtime.actual_device")
    _boolean(runtime.get("fallback_applied"), "workflow_result.actual_runtime.fallback_applied")
    artifacts = [_mapping(item, "workflow_result.artifacts item") for item in _list(result.get("artifacts"), "workflow_result.artifacts")]
    _unique(artifacts, "artifact_id", "workflow_result.artifacts")
    for artifact in artifacts:
        validate_artifact(artifact)
    deliverables = [_mapping(item, "workflow_result.deliverables item") for item in _list(result.get("deliverables"), "workflow_result.deliverables")]
    _unique(deliverables, "semantic_id", "workflow_result.deliverables")
    for item in deliverables:
        _only_keys(item, {"semantic_id", "artifact_id"}, "workflow_result.deliverable")
        _stable_id(item.get("artifact_id"), "workflow_result.deliverable.artifact_id")
    return result


def validate_import_plan(document: Any) -> Mapping[str, Any]:
    plan = _mapping(document, "import_plan")
    _only_keys(plan, {"schema_version", "request_id", "workflow_id", "destination", "grouping", "create_folder", "source_after", "origin_project_policy", "imports"}, "import_plan")
    _schema(plan, "import_plan")
    _stable_id(plan.get("request_id"), "import_plan.request_id")
    _stable_id(plan.get("workflow_id"), "import_plan.workflow_id")
    if plan.get("destination") not in _DESTINATIONS:
        raise ContractError("import_plan.destination is invalid")
    if plan.get("grouping") not in _GROUPINGS:
        raise ContractError("import_plan.grouping is invalid")
    _boolean(plan.get("create_folder"), "import_plan.create_folder")
    if plan.get("source_after") not in _SOURCE_AFTER:
        raise ContractError("import_plan.source_after is invalid")
    if plan.get("origin_project_policy") != "fail_closed":
        raise ContractError("import_plan.origin_project_policy must be fail_closed")
    imports = [_mapping(item, "import_plan.imports item") for item in _list(plan.get("imports"), "import_plan.imports")]
    semantics = _unique(imports, "semantic_id", "import_plan.imports")
    orders: set[int] = set()
    for semantic_id, item in semantics.items():
        _only_keys(item, {"order", "semantic_id", "artifact_id", "name_template"}, f"import {semantic_id}")
        _stable_id(item.get("artifact_id"), f"import {semantic_id}.artifact_id")
        order = item.get("order")
        if not isinstance(order, int) or isinstance(order, bool) or order < 1 or order in orders:
            raise ContractError("import ordering must contain unique positive integers")
        orders.add(order)
        _string(item.get("name_template"), f"import {semantic_id}.name_template")
    if orders != set(range(1, len(imports) + 1)):
        raise ContractError("import ordering must be contiguous")
    return plan


def validate_workflow_request(document: Any) -> Mapping[str, Any]:
    request = _mapping(document, "workflow_request")
    _only_keys(request, {"schema_version", "request_id", "workflow_id", "source_plan", "stages", "deliverable_ids", "requested_runtime"}, "workflow_request")
    _schema(request, "workflow_request")
    _stable_id(request.get("request_id"), "workflow_request.request_id")
    _stable_id(request.get("workflow_id"), "workflow_request.workflow_id")
    validate_source_plan(request.get("source_plan"))
    stages = [_mapping(item, "workflow_request.stages item") for item in _list(request.get("stages"), "workflow_request.stages")]
    if not stages:
        raise ContractError("workflow_request.stages must not be empty")
    _unique(stages, "stage_id", "workflow_request.stages")
    for stage in stages:
        validate_stage_spec(stage)
    orders = [stage.get("order") for stage in stages]
    if orders != list(range(1, len(stages) + 1)):
        raise ContractError("stages must be in contiguous execution order")
    deliverables = [_stable_id(item, "workflow_request.deliverable_ids item") for item in _list(request.get("deliverable_ids"), "workflow_request.deliverable_ids")]
    if len(set(deliverables)) != len(deliverables):
        raise ContractError("duplicate deliverable identity")
    runtime = _mapping(request.get("requested_runtime"), "workflow_request.requested_runtime")
    _only_keys(runtime, {"model_id", "device", "processing_may_download"}, "workflow_request.requested_runtime")
    _stable_id(runtime.get("model_id"), "workflow_request.requested_runtime.model_id")
    _string(runtime.get("device"), "workflow_request.requested_runtime.device")
    if runtime.get("processing_may_download") is not False:
        raise ContractError("requested_runtime.processing_may_download must be false")
    return request


def validate_bundle(document: Any) -> Mapping[str, Any]:
    """Validate the six contracts together, including cross-references."""

    bundle = _mapping(document, "bundle")
    _reject_reaper_pointers(bundle)
    _only_keys(bundle, {"workflow_request", "workflow_result", "import_plan"}, "bundle")
    request = validate_workflow_request(bundle.get("workflow_request"))
    result = validate_workflow_result(bundle.get("workflow_result"))
    import_plan = validate_import_plan(bundle.get("import_plan"))

    request_id = request["request_id"]
    workflow_id = request["workflow_id"]
    if result["request_id"] != request_id or import_plan["request_id"] != request_id:
        raise ContractError("request identity mismatch")
    if result["workflow_id"] != workflow_id or import_plan["workflow_id"] != workflow_id:
        raise ContractError("workflow identity mismatch")

    source_ids = {source["source_id"] for source in request["source_plan"]["sources"]}
    stages = request["stages"]
    stage_by_id = {stage["stage_id"]: stage for stage in stages}
    stage_order = {stage["stage_id"]: stage["order"] for stage in stages}
    output_ports = {
        stage["stage_id"]: {output["port_id"] for output in stage["outputs"]}
        for stage in stages
    }
    for stage in stages:
        input_ref = stage["input"]
        if input_ref["kind"] == "source":
            if input_ref["source_id"] not in source_ids:
                raise ContractError(f"missing source: {input_ref['source_id']}")
        else:
            producer = input_ref["stage_id"]
            if producer not in stage_by_id or stage_order[producer] >= stage["order"]:
                raise ContractError(f"missing or non-earlier producer stage: {producer}")
            if input_ref["port_id"] not in output_ports[producer]:
                raise ContractError(f"missing producer output port: {input_ref['port_id']}")

    artifacts = {artifact["artifact_id"]: artifact for artifact in result["artifacts"]}
    for artifact in artifacts.values():
        producer = artifact["producer"]
        stage_id = producer["stage_id"]
        if stage_id not in stage_by_id:
            raise ContractError(f"missing producer stage: {stage_id}")
        port_id = producer["port_id"]
        if port_id not in output_ports[stage_id]:
            raise ContractError(f"missing producer output port: {port_id}")
        declared_semantic = next(
            output["semantic_id"]
            for output in stage_by_id[stage_id]["outputs"]
            if output["port_id"] == port_id
        )
        if artifact["semantic_id"] != declared_semantic:
            raise ContractError("artifact semantic identity does not match producer port")

    declared = request["deliverable_ids"]
    delivered = result["deliverables"]
    for item in delivered:
        if item["semantic_id"] not in declared:
            raise ContractError(f"undeclared deliverable: {item['semantic_id']}")
        artifact = artifacts.get(item["artifact_id"])
        if artifact is None:
            raise ContractError(f"invalid artifact reference: {item['artifact_id']}")
        if artifact["semantic_id"] != item["semantic_id"]:
            raise ContractError("deliverable semantic identity does not match artifact")
    if [item["semantic_id"] for item in delivered] != declared:
        raise ContractError("deliverables must exactly preserve declared order")

    imports = import_plan["imports"]
    if [item["semantic_id"] for item in imports] != declared:
        raise ContractError("imports must exactly preserve declared deliverable order")
    for item in imports:
        artifact = artifacts.get(item["artifact_id"])
        if artifact is None:
            raise ContractError(f"invalid artifact reference: {item['artifact_id']}")
        if artifact["semantic_id"] != item["semantic_id"]:
            raise ContractError("import semantic identity does not match artifact")
    return bundle


def _validate_capability_entry(entry: Any, where: str) -> Mapping[str, Any]:
    capability = _mapping(entry, where)
    _only_keys(
        capability,
        {"capability_id", "label", "input_kind", "output_semantic_ids", "permitted_backends"},
        where,
    )
    _stable_id(capability.get("capability_id"), f"{where}.capability_id")
    _string(capability.get("label"), f"{where}.label")
    if capability.get("input_kind") != "audio":
        raise ContractError(f"{where}.input_kind must be audio")
    outputs = [
        _stable_id(item, f"{where}.output_semantic_ids item")
        for item in _list(capability.get("output_semantic_ids"), f"{where}.output_semantic_ids")
    ]
    if not outputs or len(set(outputs)) != len(outputs):
        raise ContractError(f"{where}.output_semantic_ids must be a non-empty list of unique semantic ids")
    backends = [
        _string(item, f"{where}.permitted_backends item")
        for item in _list(capability.get("permitted_backends"), f"{where}.permitted_backends")
    ]
    if not backends or len(set(backends)) != len(backends):
        raise ContractError(f"{where}.permitted_backends must be a non-empty list of unique backend kinds")
    for backend in backends:
        if backend not in _BACKEND_KINDS:
            raise ContractError(f"{where}.permitted_backends contains unknown backend kind: {backend}")
    return capability


def _validate_model_entry(entry: Any, where: str) -> Mapping[str, Any]:
    model = _mapping(entry, where)
    _only_keys(model, {"model_id", "label", "capability_id", "output_semantic_ids", "role"}, where)
    _stable_id(model.get("model_id"), f"{where}.model_id")
    _string(model.get("label"), f"{where}.label")
    _stable_id(model.get("capability_id"), f"{where}.capability_id")
    outputs = [
        _stable_id(item, f"{where}.output_semantic_ids item")
        for item in _list(model.get("output_semantic_ids"), f"{where}.output_semantic_ids")
    ]
    if not outputs or len(set(outputs)) != len(outputs):
        raise ContractError(f"{where}.output_semantic_ids must be a non-empty list of unique semantic ids")
    if model.get("role") not in _MODEL_ROLES:
        raise ContractError(f"{where}.role must be one of {sorted(_MODEL_ROLES)}")
    return model


def _validate_workflow_stage_entry(entry: Any, where: str) -> Mapping[str, Any]:
    stage = _mapping(entry, where)
    kind = stage.get("input_kind")
    if kind == "source":
        _only_keys(stage, {"order", "stage_id", "capability_ids", "input_kind", "input_artifact_kind"}, where)
    elif kind == "stage_output":
        _only_keys(
            stage,
            {
                "order", "stage_id", "capability_ids", "input_kind", "input_artifact_kind",
                "input_stage_id", "input_port_id",
            },
            where,
        )
    else:
        raise ContractError(f"{where}.input_kind must be source or stage_output")
    order = stage.get("order")
    if not isinstance(order, int) or isinstance(order, bool) or order < 1:
        raise ContractError(f"{where}.order must be a positive integer")
    _stable_id(stage.get("stage_id"), f"{where}.stage_id")
    capability_ids = [
        _stable_id(item, f"{where}.capability_ids item")
        for item in _list(stage.get("capability_ids"), f"{where}.capability_ids")
    ]
    if not capability_ids or len(set(capability_ids)) != len(capability_ids):
        raise ContractError(f"{where}.capability_ids must be a non-empty list of unique capability ids")
    if stage.get("input_artifact_kind") != "audio":
        raise ContractError(f"{where}.input_artifact_kind must be audio")
    if kind == "stage_output":
        _stable_id(stage.get("input_stage_id"), f"{where}.input_stage_id")
        _stable_id(stage.get("input_port_id"), f"{where}.input_port_id")
    return stage


def validate_catalogs(catalog_dir: str | Path) -> dict[str, list[Mapping[str, Any]]]:
    """Load the three v1 catalogs and enforce the v1 completeness boundary."""

    root = Path(catalog_dir)
    documents = {
        "capabilities": load_json(root / "capabilities.v1.json"),
        "models": load_json(root / "models.v1.json"),
        "workflows": load_json(root / "workflows.v1.json"),
    }
    for name, document in documents.items():
        mapping = _mapping(document, f"{name} catalog")
        _schema(mapping, f"{name} catalog")
        _reject_reaper_pointers(mapping, f"{name} catalog")
        entries = _list(mapping.get(name), f"{name} catalog.{name}")
        if not entries:
            raise ContractError(f"{name} catalog must not be empty")

    capabilities = documents["capabilities"]["capabilities"]
    models = documents["models"]["models"]
    workflows = documents["workflows"]["workflows"]

    capabilities_by_id = _unique(capabilities, "capability_id", "capabilities")
    models_by_id = _unique(models, "model_id", "models")
    workflows_by_id = _unique(workflows, "workflow_id", "workflows")

    if set(capabilities_by_id) != _KNOWN_CAPABILITY_IDS:
        raise ContractError(f"v1 capability catalog must contain exactly: {sorted(_KNOWN_CAPABILITY_IDS)}")
    if set(models_by_id) != _KNOWN_MODEL_IDS:
        raise ContractError(f"v1 model catalog must contain exactly: {sorted(_KNOWN_MODEL_IDS)}")
    if set(workflows_by_id) != _KNOWN_WORKFLOW_IDS:
        raise ContractError(f"v1 workflow catalog must contain exactly: {sorted(_KNOWN_WORKFLOW_IDS)}")

    for capability_id, entry in capabilities_by_id.items():
        _validate_capability_entry(entry, f"capabilities.{capability_id}")

    for model_id, entry in models_by_id.items():
        validated = _validate_model_entry(entry, f"models.{model_id}")
        capability_id = validated["capability_id"]
        if capability_id not in capabilities_by_id:
            raise ContractError(f"models.{model_id}.capability_id references unknown capability: {capability_id}")
        if list(validated["output_semantic_ids"]) != list(capabilities_by_id[capability_id]["output_semantic_ids"]):
            raise ContractError(
                f"models.{model_id}.output_semantic_ids must match capability {capability_id} output_semantic_ids"
            )

    for workflow_id, workflow in workflows_by_id.items():
        where = f"workflows.{workflow_id}"
        _only_keys(workflow, {"workflow_id", "label", "ordered_stages", "deliverable_ids"}, where)
        _string(workflow.get("label"), f"{where}.label")
        stages = _list(workflow.get("ordered_stages"), f"{where}.ordered_stages")
        if not stages:
            raise ContractError(f"{where}.ordered_stages must not be empty")

        validated_stages: dict[str, Mapping[str, Any]] = {}
        for index, raw_stage in enumerate(stages, start=1):
            stage = _validate_workflow_stage_entry(raw_stage, f"{where}.ordered_stages[{index}]")
            if stage["order"] != index:
                raise ContractError(f"{where}.ordered_stages must be in contiguous order")
            stage_id = stage["stage_id"]
            if stage_id in validated_stages:
                raise ContractError(f"duplicate stage_id in workflow {workflow_id}: {stage_id}")
            for capability_id in stage["capability_ids"]:
                if capability_id not in capabilities_by_id:
                    raise ContractError(
                        f"{where}.ordered_stages[{index}] references unknown capability: {capability_id}"
                    )
            if stage.get("input_kind") == "stage_output":
                producer_stage_id = stage["input_stage_id"]
                producer = validated_stages.get(producer_stage_id)
                if producer is None:
                    raise ContractError(
                        f"{where}.ordered_stages[{index}].input_stage_id must reference an earlier "
                        f"stage in the same workflow: {producer_stage_id}"
                    )
                producer_outputs: set[str] = set()
                for producer_capability_id in producer["capability_ids"]:
                    producer_outputs.update(capabilities_by_id[producer_capability_id]["output_semantic_ids"])
                if stage["input_port_id"] not in producer_outputs:
                    raise ContractError(
                        f"{where}.ordered_stages[{index}].input_port_id "
                        f"{stage['input_port_id']!r} is not produced by stage {producer_stage_id!r}"
                    )
            validated_stages[stage_id] = stage

        deliverables = [
            _stable_id(item, f"{where}.deliverable_ids item")
            for item in _list(workflow.get("deliverable_ids"), f"{where}.deliverable_ids")
        ]
        if not deliverables or len(set(deliverables)) != len(deliverables):
            raise ContractError(f"{where}.deliverable_ids must be a non-empty list of unique semantic ids")

    return {name: document[name] for name, document in documents.items()}
