"""Client-neutral Core readiness API (first Core-owned readiness slice).

Answers one question for the three catalogued workflows (Normal Stems,
Direct Kit, Drum Split): "does the evidence available right now support
running this workflow with this model/device request?" -- without REAPER,
without importing Torch/YAML/the legacy processor into this process, and
without intentionally provisioning, downloading, repairing, or changing
installed runtime/model state.

Boundary contract
-----------------
- Selection *policy* is never re-implemented here. Backend/device resolution
  is composed by ``stemwerk_core.runtime_resolution`` from probes that wrap
  already-computed selection results:

  - Normal-Stems stages: the real
    ``device_policy.resolve_normal_runtime_device`` runs inside the *intended*
    interpreter via a bounded subprocess (``readiness_collect``); this module
    only receives its result.
  - DrumSep stages: the Core-owned production selector runs in the intended
    interpreter and the selected interpreter is validated separately. Core
    never locates or imports ``audio_separator_process.py``.

- Evidence modes are explicit. ``evaluation_mode="live"`` means every
  component verdict is backed by evidence collected on this machine just now
  (``evidence.source="collected"``). ``evaluation_mode="simulated"`` means
  the evidence came from a caller-supplied fixture document: every component
  is relabeled ``evidence.source="simulated_fixture"`` /
  ``evidence_kind="fixture_supplied"`` and the overall scope is
  ``simulated_policy_evaluation``. Fixture evidence can demonstrate a
  successful *policy evaluation*; it can never produce a claim that this
  machine is ready, and it gets a distinct CLI exit code (3, not 0).
  User-supplied JSON never confers production-selector provenance; the Linux
  attributed-fallback exception in fixture mode evaluates against the
  fixture's declared ``platform_system`` and remains labeled simulated.

- A resolved plan alone is not readiness. Feasibility (the resolver outcome)
  is one required component alongside per-stage runtime/capability/model
  evidence and FFmpeg usability. The aggregator fails closed: PASS requires
  every required component at PASS; FAIL dominates; UNAVAILABLE, SKIPPED and
  absent evidence never fall through to PASS. NOT_APPLICABLE may only be
  excluded when the workflow genuinely does not require that component (no
  current workflow has such components).

- Side-effect boundary. Live probes create an owned temporary working
  directory, disable subprocess bytecode writes, and clean that directory
  afterward. Readiness does not intentionally provision, download, repair,
  evict, or mutate installed runtime/model state. Controlled tests establish
  filesystem invariance for their tested payloads and environments; they do
  not universally rule out cache/config writes, network activity, or other
  initialization effects from arbitrary real third-party imports. Torch/GPU
  observation remains out of this process and inside bounded subprocesses
  (see ``readiness_collect``). Model checks distinguish presence from
  integrity from usability; a PASS here is a documented preflight that still
  requires execution-time revalidation by the authoritative production gates
  (``authoritative_gate`` field).

CLI exit codes (see ``exit_code_for_report``): 0 = live local preflight
PASS, 1 = FAIL (any mode), 2 = UNAVAILABLE or request/catalog/fixture
errors, 3 = simulated PASS. Machine-readable output goes to stdout only;
diagnostics go to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from importlib import resources as importlib_resources
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, Mapping, Optional, Sequence

from . import device_policy, managed_runtime, model_assets, readiness_collect, workflow_contracts
from .models import DEMUCS_AUDIO_SEPARATOR_MODEL_IDS
from .runtime_resolution import (
    REASON_CONTRACT_LOAD_ERROR,
    REASON_MODEL_CAPABILITY_MISMATCH,
    REASON_UNKNOWN_MODEL,
    REASON_UNKNOWN_WORKFLOW,
    CapabilityProbe,
    ResolutionError,
    StageRequest,
    resolve_execution_plan,
    resolve_workflow_plan,
)
from .verdicts import FAIL, NOT_APPLICABLE, PASS, SKIPPED, UNAVAILABLE

SCHEMA_VERSION = "1.0.0"
REPORT_KIND = "stemwerk_readiness_report"
ERROR_KIND = "stemwerk_readiness_error"
FIXTURE_KIND = "stemwerk_readiness_fixture"

# Core-owned workflow/model defaults (moved from
# tools/stemwerk_runtime_diagnostics.py, which imports them back). Values are
# catalog model_ids; drum_kit_split is (stage-1 model, stage-2 model).
DEFAULT_MODEL_BY_WORKFLOW: Dict[str, Any] = {
    "normal_stems": "htdemucs",
    "drum_kit_direct": "drumsep_mdx23c",
    "drum_kit_split": ("htdemucs", "drumsep_mdx23c"),
}

# Readiness-level stable reason codes. Resolver codes
# (runtime_resolution.REASON_*) pass through unchanged on the feasibility
# component; asset_integrity_mismatch intentionally reuses the legacy
# DRUMSEP_ASSET_INTEGRITY_MISMATCH_REASON string.
REASON_CATALOG_UNAVAILABLE = "catalog_unavailable"
REASON_MODEL_ASSETS_MISSING = "model_assets_missing"
REASON_ASSET_INTEGRITY_MISMATCH = "asset_integrity_mismatch"
REASON_FFMPEG_UNAVAILABLE = "ffmpeg_unavailable"
REASON_RUNTIME_EVIDENCE_MISSING = "runtime_evidence_missing"
REASON_RUNTIME_EVIDENCE_BROKEN = "runtime_evidence_broken"
REASON_DEVICE_IDENTITY_MISMATCH = "device_identity_mismatch"
REASON_FIXTURE_INVALID = "evidence_fixture_invalid"
REASON_FIXTURE_INCOMPLETE = "evidence_fixture_incomplete"
REASON_DRUMSEP_LIVE_COLLECTION_UNSUPPORTED = "drumsep_live_collection_unsupported"
REASON_DELIVERABLE_NOT_PROMISED = "deliverable_not_promised"
REASON_MALFORMED_REQUEST = "malformed_request"

_VERDICTS = frozenset({PASS, FAIL, SKIPPED, UNAVAILABLE, NOT_APPLICABLE})
_DRUMSEP_CAPABILITY_ID = "drum_kit_6"

EXIT_LIVE_READY = 0
EXIT_NOT_READY = 1
EXIT_UNAVAILABLE_OR_ERROR = 2
EXIT_SIMULATED_PASS = 3


class ReadinessError(ValueError):
    """Stable machine-readable request/catalog/fixture failure."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class ReadinessRequest:
    """One readiness evaluation request.

    ``model_id`` is a single catalog model id for single-stage workflows or a
    sequence of per-stage model ids for drum_kit_split; ``None`` selects the
    Core-owned defaults. ``deliverable_ids`` is an ordered subset of the
    promised route deliverables; ``None`` means the full promise.
    """

    workflow_id: str
    model_id: Any = None
    requested_device: str = "auto"
    deliverable_ids: Optional[Sequence[str]] = None
    evidence_mode: str = "collect"  # "collect" | "fixture"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _component(
    verdict: str,
    *,
    reason: Optional[str] = None,
    reason_code: Optional[str] = None,
    evidence: Optional[Mapping[str, Any]] = None,
    required: bool = True,
    **extra: Any,
) -> Dict[str, Any]:
    component: Dict[str, Any] = {"verdict": verdict, "required": required}
    if reason_code:
        component["reason_code"] = reason_code
    if reason:
        component["reason"] = reason
    if evidence is not None:
        component["evidence"] = dict(evidence)
    component.update(extra)
    return component


def _unavailable(reason_code: str, reason: str, *, evidence: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    return _component(UNAVAILABLE, reason_code=reason_code, reason=reason, evidence=evidence)


def _coerce_request(request: Any) -> ReadinessRequest:
    if isinstance(request, ReadinessRequest):
        coerced = request
    elif isinstance(request, Mapping):
        allowed = {"workflow_id", "model_id", "requested_device", "deliverable_ids", "evidence_mode"}
        unknown = set(request) - allowed
        if unknown:
            raise ReadinessError(
                REASON_MALFORMED_REQUEST, f"unsupported request field: {sorted(unknown)[0]}"
            )
        coerced = ReadinessRequest(
            workflow_id=request.get("workflow_id"),
            model_id=request.get("model_id"),
            requested_device=request.get("requested_device", "auto"),
            deliverable_ids=request.get("deliverable_ids"),
            evidence_mode=request.get("evidence_mode", "collect"),
        )
    else:
        raise ReadinessError(REASON_MALFORMED_REQUEST, "request must be a ReadinessRequest or mapping")
    if not isinstance(coerced.workflow_id, str) or not coerced.workflow_id:
        raise ReadinessError(REASON_MALFORMED_REQUEST, "workflow_id must be a non-empty string")
    if coerced.evidence_mode not in ("collect", "fixture"):
        raise ReadinessError(
            REASON_MALFORMED_REQUEST,
            f"evidence_mode must be 'collect' or 'fixture', got {coerced.evidence_mode!r}",
        )
    return coerced


# ---------------------------------------------------------------------------
# Catalog discovery and request validation (no evidence involved)
# ---------------------------------------------------------------------------


@contextmanager
def _catalog_dir(explicit: Optional[str | Path]) -> Iterator[tuple[Path, str]]:
    """Resolve the workflow catalog location.

    Order: explicit argument > STEMWERK_CATALOG_DIR > the byte-identical
    packaged copy (importlib.resources; works without a REAPER install or a
    repository checkout). Never searches REAPER install trees.
    """

    if explicit is not None:
        yield Path(explicit).expanduser(), "explicit"
        return
    env_value = os.environ.get("STEMWERK_CATALOG_DIR")
    if env_value:
        yield Path(env_value).expanduser(), "environment"
        return
    unavailable_message = (
        "no workflow catalog available: no --catalog-dir/STEMWERK_CATALOG_DIR and no "
        "packaged stemwerk_core catalog resource"
    )
    with ExitStack() as resource_stack:
        try:
            resource = importlib_resources.files("stemwerk_core").joinpath("catalog")
            packaged = resource_stack.enter_context(importlib_resources.as_file(resource))
            is_directory = packaged.is_dir()
        except Exception as exc:
            raise ReadinessError(REASON_CATALOG_UNAVAILABLE, unavailable_message) from exc
        if not is_directory:
            raise ReadinessError(REASON_CATALOG_UNAVAILABLE, unavailable_message)
        yield packaged, "package"


def _load_catalogs(catalog_dir: Path) -> Mapping[str, Any]:
    try:
        return workflow_contracts.validate_catalogs(catalog_dir)
    except workflow_contracts.ContractError as exc:
        raise ReadinessError(REASON_CATALOG_UNAVAILABLE, str(exc)) from exc


def _resolve_stage_infos(
    request: ReadinessRequest, catalogs: Mapping[str, Any]
) -> tuple[Mapping[str, Any], list[Dict[str, Any]]]:
    workflows_by_id = {w["workflow_id"]: w for w in catalogs["workflows"]}
    workflow = workflows_by_id.get(request.workflow_id)
    if workflow is None:
        raise ReadinessError(REASON_UNKNOWN_WORKFLOW, f"unknown workflow_id: {request.workflow_id!r}")

    stages = list(workflow["ordered_stages"])
    defaults = DEFAULT_MODEL_BY_WORKFLOW[request.workflow_id]
    default_list = list(defaults) if isinstance(defaults, tuple) else [defaults]

    model_ids = request.model_id
    if model_ids is None:
        model_list = default_list
    elif isinstance(model_ids, str):
        model_list = [model_ids]
    elif isinstance(model_ids, Sequence):
        model_list = list(model_ids)
    else:
        raise ReadinessError(REASON_MALFORMED_REQUEST, "model_id must be a string or sequence of strings")
    if len(model_list) != len(stages):
        raise ReadinessError(
            REASON_MALFORMED_REQUEST,
            f"workflow {request.workflow_id!r} has {len(stages)} stage(s); "
            f"{len(model_list)} model_id(s) supplied",
        )

    models_by_id = {m["model_id"]: m for m in catalogs["models"]}
    capabilities_by_id = {c["capability_id"]: c for c in catalogs["capabilities"]}
    infos: list[Dict[str, Any]] = []
    for stage, model_id in zip(stages, model_list):
        model = models_by_id.get(model_id)
        if model is None:
            raise ReadinessError(REASON_UNKNOWN_MODEL, f"unknown model_id: {model_id!r}")
        capability_id = model["capability_id"]
        if capability_id not in stage["capability_ids"]:
            raise ReadinessError(
                REASON_MODEL_CAPABILITY_MISMATCH,
                f"model {model_id!r} provides capability {capability_id!r}, which is not among "
                f"stage {stage['stage_id']!r}'s permitted capabilities {sorted(stage['capability_ids'])}",
            )
        infos.append(
            {
                "stage": stage,
                "model_id": model_id,
                "model": model,
                "capability_id": capability_id,
                "capability": capabilities_by_id[capability_id],
                "flavor": "drumsep" if capability_id == _DRUMSEP_CAPABILITY_ID else "normal",
            }
        )
    return workflow, infos


def _promised_deliverables(workflow: Mapping[str, Any], final_capability_id: str) -> list[str]:
    routes = [
        route for route in workflow["deliverable_routes"] if route["capability_id"] == final_capability_id
    ]
    # validate_catalogs guarantees exactly one route per final-stage capability.
    return list(routes[0]["deliverable_ids"])


def _requested_deliverables(
    requested: Optional[Sequence[str]], promised: Sequence[str]
) -> list[str]:
    if requested is None:
        return list(promised)
    if isinstance(requested, str) or not isinstance(requested, Sequence):
        raise ReadinessError(REASON_MALFORMED_REQUEST, "deliverable_ids must be a sequence of semantic ids")
    requested_list = [str(item) for item in requested]
    if not requested_list or len(set(requested_list)) != len(requested_list):
        raise ReadinessError(
            REASON_DELIVERABLE_NOT_PROMISED, "deliverable_ids must be non-empty and unique"
        )
    unsupported = [item for item in requested_list if item not in promised]
    if unsupported:
        raise ReadinessError(
            REASON_DELIVERABLE_NOT_PROMISED,
            f"deliverable {unsupported[0]!r} is not promised by the selected route "
            f"(promised: {list(promised)})",
        )
    # Same order-preservation rule as workflow_contracts.validate_bundle.
    if requested_list != [item for item in promised if item in requested_list]:
        raise ReadinessError(
            REASON_DELIVERABLE_NOT_PROMISED,
            "deliverable_ids must preserve the promised route order",
        )
    return requested_list


# ---------------------------------------------------------------------------
# Probe construction from already-resolved capability evidence
# ---------------------------------------------------------------------------


def _probe_from_resolution(
    flavor: str, resolution: Mapping[str, Any], *, platform_system: Optional[str]
) -> CapabilityProbe:
    """Wrap an already-computed selection result as a resolver probe.

    Mirrors the production gate's ``_drum_kit_capability_probe_from_result``:
    the probe never re-selects; it presents the one authoritative result so
    the resolver composes it against the catalog. No selection policy lives
    here.
    """

    backend = str(resolution.get("resolved_backend") or "")
    if flavor == "normal":
        device_id = str(resolution.get("resolved_device_id") or backend)
        device_name = str(resolution.get("resolved_device_name") or device_id)
        available = list(resolution.get("available_devices") or [])
        preferred = {"id": device_id, "name": device_name}
        return CapabilityProbe(
            get_available_devices=lambda: available,
            select_device=lambda _requested: (device_id, device_name),
            runtime_kind_for_device=lambda _device: backend,
            is_unexpected_cpu_downgrade=device_policy.is_unexpected_cpu_downgrade,
            resolve_auto_device=lambda _live: preferred,
        )
    kind = backend
    device_id = str(resolution.get("resolved_device_id") or kind)
    device_name = str(resolution.get("resolved_device_name") or device_id)
    already_resolved = {"id": device_id, "name": device_name}
    selection_info = resolution.get("selection_info") or {}
    return CapabilityProbe(
        get_available_devices=lambda: [already_resolved],
        select_device=lambda _requested: (device_id, device_name),
        runtime_kind_for_device=lambda _device: device_policy.drumsep_backend_classifier(kind),
        is_unexpected_cpu_downgrade=device_policy.drum_kit_is_unexpected_cpu_downgrade(
            selection_info, platform_system=platform_system
        ),
        resolve_auto_device=lambda _live: already_resolved,
    )


# ---------------------------------------------------------------------------
# Fixture evidence (simulated policy evaluation)
# ---------------------------------------------------------------------------


def _validate_fixture_document(fixture: Any) -> Mapping[str, Any]:
    if not isinstance(fixture, Mapping):
        raise ReadinessError(REASON_FIXTURE_INVALID, "fixture must be a JSON object")
    if fixture.get("kind") != FIXTURE_KIND:
        raise ReadinessError(
            REASON_FIXTURE_INVALID, f"fixture kind must be {FIXTURE_KIND!r}"
        )
    version = fixture.get("schema_version")
    if version is not None and version != SCHEMA_VERSION:
        raise ReadinessError(
            REASON_FIXTURE_INVALID,
            f"fixture schema_version {version!r} is unsupported; expected {SCHEMA_VERSION!r}",
        )
    stages = fixture.get("stages")
    if stages is not None and not isinstance(stages, list):
        raise ReadinessError(REASON_FIXTURE_INVALID, "fixture.stages must be an array")
    return fixture


def _fixture_component(raw: Any, where: str) -> Optional[Dict[str, Any]]:
    """Convert a fixture-supplied component, forcing simulated labels.

    Fixture evidence never keeps or acquires live labels
    (real_probe_resolution/real_execution): source and evidence_kind are
    overwritten unconditionally. Supplied timestamps pass through as
    provenance; no expiry threshold is applied.
    """

    if raw is None:
        return None
    if not isinstance(raw, Mapping):
        raise ReadinessError(REASON_FIXTURE_INVALID, f"{where} must be an object")
    verdict = raw.get("verdict")
    if verdict not in _VERDICTS:
        raise ReadinessError(
            REASON_FIXTURE_INVALID, f"{where}.verdict must be one of {sorted(_VERDICTS)}"
        )
    raw_evidence = raw.get("evidence", {})
    if not isinstance(raw_evidence, Mapping):
        raise ReadinessError(REASON_FIXTURE_INVALID, f"{where}.evidence must be an object")
    evidence = _sanitize_fixture_value(raw_evidence)
    evidence["source"] = "simulated_fixture"
    evidence["evidence_kind"] = "fixture_supplied"
    return _component(
        verdict,
        reason=raw.get("reason"),
        reason_code=raw.get("reason_code"),
        evidence=evidence,
    )


def _fixture_capability(raw: Any, where: str) -> Optional[Dict[str, Any]]:
    component = _fixture_component(raw, where)
    if component is None:
        return None
    resolution = raw.get("resolution")
    if resolution is not None and not isinstance(resolution, Mapping):
        raise ReadinessError(REASON_FIXTURE_INVALID, f"{where}.resolution must be an object")
    if component["verdict"] == PASS:
        if not isinstance(resolution, Mapping) or not resolution.get("resolved_backend"):
            raise ReadinessError(
                REASON_FIXTURE_INVALID,
                f"{where}: a PASS capability fixture must supply resolution.resolved_backend",
            )
        component["resolution"] = _sanitize_fixture_value(resolution)
    elif isinstance(resolution, Mapping):
        component["resolution"] = _sanitize_fixture_value(resolution)
    return component


def _sanitize_fixture_value(value: Any, *, key: str = "") -> Any:
    """Recursively remove live authority labels from untrusted fixtures."""

    if isinstance(value, Mapping):
        sanitized: Dict[str, Any] = {}
        for raw_key, nested in value.items():
            nested_key = str(raw_key)
            if "selector_provenance" in nested_key.lower():
                continue
            sanitized[nested_key] = _sanitize_fixture_value(nested, key=nested_key)
        return sanitized
    if isinstance(value, list):
        return [_sanitize_fixture_value(item) for item in value]
    if isinstance(value, tuple):
        return [_sanitize_fixture_value(item) for item in value]
    if key == "source" and value == "collected":
        return "simulated_fixture"
    if key == "evidence_kind" and value in {
        "real_execution",
        "real_probe_resolution",
        "production_selector_result",
    }:
        return "fixture_supplied"
    return value


def _incomplete(where: str) -> Dict[str, Any]:
    return _unavailable(
        REASON_FIXTURE_INCOMPLETE,
        f"fixture supplies no evidence for {where}",
        evidence={"source": "simulated_fixture", "evidence_kind": "fixture_supplied"},
    )


def _fixture_stage_components(
    stage_fixture: Optional[Mapping[str, Any]], info: Mapping[str, Any]
) -> Dict[str, Any]:
    stage_id = info["stage"]["stage_id"]
    if stage_fixture is None:
        return {
            "runtime": _incomplete(f"stage {stage_id} runtime"),
            "capability": _incomplete(f"stage {stage_id} capability"),
            "model": _incomplete(f"stage {stage_id} model"),
        }
    if not isinstance(stage_fixture, Mapping):
        raise ReadinessError(REASON_FIXTURE_INVALID, f"fixture stage {stage_id} must be an object")
    supplied_id = stage_fixture.get("stage_id")
    if supplied_id is not None and supplied_id != stage_id:
        raise ReadinessError(
            REASON_FIXTURE_INVALID,
            f"fixture stage_id {supplied_id!r} does not match workflow stage {stage_id!r}",
        )
    where = f"fixture stage {stage_id}"
    runtime = _fixture_component(stage_fixture.get("runtime"), f"{where}.runtime")
    capability = _fixture_capability(stage_fixture.get("capability"), f"{where}.capability")
    model = _fixture_component(stage_fixture.get("model"), f"{where}.model")
    return {
        "runtime": runtime or _incomplete(f"stage {stage_id} runtime"),
        "capability": capability or _incomplete(f"stage {stage_id} capability"),
        "model": model or _incomplete(f"stage {stage_id} model"),
    }


# ---------------------------------------------------------------------------
# Live evidence collection (bounded side effects; see readiness_collect)
# ---------------------------------------------------------------------------


def _intended_interpreter() -> tuple[Path, str]:
    managed = managed_runtime.managed_runtime_python()
    if managed is not None:
        return managed, "managed"
    return Path(sys.executable), "ambient"


def _finalize_collected(component: Mapping[str, Any], *, reason_code: str) -> Dict[str, Any]:
    verdict = component.get("verdict")
    evidence = dict(component.get("evidence") or {})
    evidence.setdefault("observed_at_utc", _utc_now())
    result = _component(
        verdict if verdict in _VERDICTS else UNAVAILABLE,
        reason=component.get("reason"),
        reason_code=component.get("reason_code") or (None if verdict == PASS else reason_code),
        evidence=evidence,
    )
    if "resolution" in component:
        result["resolution"] = dict(component["resolution"])
    if "path" in component:
        result["path"] = component["path"]
    return result


def _live_model_component(
    model_id: str, flavor: str, providers: Optional[Mapping[str, Callable[[], Mapping[str, Any]]]]
) -> Dict[str, Any]:
    evidence_base = {"source": "collected", "observed_at_utc": _utc_now()}
    provider = (providers or {}).get(model_id)
    if provider is not None:
        try:
            supplied = provider()
        except Exception as exc:
            return _component(
                UNAVAILABLE,
                reason_code=REASON_RUNTIME_EVIDENCE_MISSING,
                reason=f"model asset provider raised {type(exc).__name__}: {exc}",
                evidence={**evidence_base, "evidence_kind": "model_asset_integrity"},
            )
        return _verify_supplied_assets(model_id, supplied, evidence_base)
    if flavor == "drumsep":
        return _verify_supplied_assets(
            model_id, model_assets.drumsep_asset_evidence(), evidence_base
        )
    if model_id in DEMUCS_AUDIO_SEPARATOR_MODEL_IDS:
        return _demucs_presence_component(model_id, evidence_base)
    return _unavailable(
        REASON_RUNTIME_EVIDENCE_MISSING,
        f"no model asset evidence source for model {model_id!r}",
        evidence={**evidence_base, "evidence_kind": "model_asset_presence"},
    )


def _demucs_presence_component(model_id: str, evidence_base: Mapping[str, Any]) -> Dict[str, Any]:
    """Demucs model check: yaml + referenced weight file(s) present in the
    managed model cache. Presence only -- integrity is unverified (no pinned
    hashes exist for these assets) and runtime usability is not established
    by a file existing."""

    cache_dir = managed_runtime.managed_model_cache_dir()
    yaml_name = DEMUCS_AUDIO_SEPARATOR_MODEL_IDS[model_id]
    yaml_path = cache_dir / yaml_name
    evidence = {
        **evidence_base,
        "evidence_kind": "model_asset_presence",
        "model_cache_dir": str(cache_dir),
        "integrity": "unverified",
    }
    if not yaml_path.is_file():
        return _component(
            FAIL,
            reason_code=REASON_MODEL_ASSETS_MISSING,
            reason=f"model definition {yaml_name} not present under {cache_dir}",
            evidence=evidence,
        )
    missing: list[str] = []
    files: list[str] = [yaml_name]
    try:
        prefixes = model_assets.demucs_yaml_weight_prefixes(yaml_path)
    except (OSError, UnicodeError) as exc:
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason=f"model definition {yaml_name} is unreadable: {type(exc).__name__}: {exc}",
            evidence=evidence,
        )
    if not prefixes:
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason=f"model definition {yaml_name} contains no weight references",
            evidence=evidence,
        )
    invalid_prefixes = [
        prefix
        for prefix in prefixes
        if not isinstance(prefix, str)
        or not prefix
        or len(prefix) > 64
        or any(char not in "0123456789abcdefABCDEF" for char in prefix)
    ]
    if invalid_prefixes:
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason=f"model definition {yaml_name} contains an invalid weight reference",
            evidence=evidence,
        )
    try:
        for prefix in prefixes:
            matches = sorted(cache_dir.glob(f"{prefix}*.th"))
            readable = None
            for match in matches:
                if not match.is_file():
                    continue
                with match.open("rb") as handle:
                    handle.read(1)
                readable = match
                break
            if readable is not None:
                files.append(readable.name)
            else:
                missing.append(f"{prefix}*.th")
    except OSError as exc:
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason=f"model weight evidence is unreadable: {type(exc).__name__}: {exc}",
            evidence={**evidence, "files_present": files},
        )
    if missing:
        return _component(
            FAIL,
            reason_code=REASON_MODEL_ASSETS_MISSING,
            reason=f"model weight file(s) not present under {cache_dir}: {', '.join(missing)}",
            evidence={**evidence, "files_present": files, "files_missing": missing},
        )
    return _component(PASS, evidence={**evidence, "files_present": files})


def _verify_supplied_assets(
    model_id: str, supplied: Any, evidence_base: Mapping[str, Any]
) -> Dict[str, Any]:
    """Integrity check against adapter-supplied pins. Never downloads,
    evicts, or repairs: read-only hashing of files that must already exist."""

    evidence = {**evidence_base, "evidence_kind": "model_asset_integrity"}
    if not isinstance(supplied, Mapping) or not isinstance(supplied.get("assets"), list):
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason="model asset provider returned malformed evidence",
            evidence=evidence,
        )
    raw_base_dir = supplied.get("base_dir")
    if not isinstance(raw_base_dir, (str, os.PathLike)) or not str(raw_base_dir).strip():
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason="model asset provider returned no base directory",
            evidence=evidence,
        )
    base_dir = Path(raw_base_dir).expanduser()
    assets = supplied["assets"]
    evidence["model_cache_dir"] = str(base_dir)
    if not assets:
        return _component(
            FAIL,
            reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
            reason="model asset provider returned an empty asset set",
            evidence=evidence,
        )
    missing: list[str] = []
    mismatched: list[str] = []
    verified: list[str] = []
    for asset in assets:
        name = str(asset.get("name") or "") if isinstance(asset, Mapping) else ""
        expected = str(asset.get("sha256") or "") if isinstance(asset, Mapping) else ""
        if not name or Path(name).name != name:
            return _component(
                FAIL,
                reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
                reason="model asset provider supplied an invalid asset name",
                evidence=evidence,
            )
        target = base_dir / name
        if len(expected) != 64 or any(char not in "0123456789abcdefABCDEF" for char in expected):
            return _component(
                FAIL,
                reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
                reason=f"model asset provider supplied an invalid SHA-256 for {name}",
                evidence=evidence,
            )
        try:
            if not target.is_file():
                missing.append(name)
                continue
            actual = model_assets.file_sha256(target)
        except OSError as exc:
            return _component(
                FAIL,
                reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
                reason=f"model asset {name} is unreadable: {type(exc).__name__}: {exc}",
                evidence={**evidence, "files_verified": verified},
            )
        if actual.lower() != expected.lower():
            mismatched.append(name)
            continue
        verified.append(name)
    if missing:
        return _component(
            FAIL,
            reason_code=REASON_MODEL_ASSETS_MISSING,
            reason=f"model asset(s) not present under {base_dir}: {', '.join(missing)}",
            evidence={**evidence, "files_missing": missing, "files_verified": verified},
        )
    if mismatched:
        return _component(
            FAIL,
            reason_code=REASON_ASSET_INTEGRITY_MISMATCH,
            reason=f"model asset hash mismatch: {', '.join(mismatched)}",
            evidence={**evidence, "files_mismatched": mismatched, "files_verified": verified},
        )
    return _component(
        PASS, evidence={**evidence, "files_verified": verified, "integrity": "sha256_verified"}
    )


def _live_stage_components(
    info: Mapping[str, Any],
    requested_device: str,
    collectors: Optional[Mapping[str, Callable[[str], Mapping[str, Any]]]],
    providers: Optional[Mapping[str, Callable[[], Mapping[str, Any]]]],
    collector_cache: Dict[str, Any],
) -> Dict[str, Any]:
    stage_id = info["stage"]["stage_id"]
    if info["flavor"] == "normal":
        python_exe, source_label = _intended_interpreter()
        runtime = _finalize_collected(
            readiness_collect.collect_runtime_imports(
                python_exe, source_label=source_label, runtime_profile="main"
            ),
            reason_code=REASON_RUNTIME_EVIDENCE_MISSING,
        )
        capability = _finalize_collected(
            readiness_collect.collect_normal_stems_resolution(
                requested_device, python_exe, source_label=source_label
            ),
            reason_code=REASON_RUNTIME_EVIDENCE_MISSING,
        )
    else:
        collector = (collectors or {}).get("drum_kit") or readiness_collect.build_drum_kit_collector()
        if "drum_kit" not in collector_cache:
            try:
                collector_cache["drum_kit"] = collector(requested_device)
            except Exception as exc:
                collector_cache["drum_kit"] = exc
        collected = collector_cache["drum_kit"]
        if isinstance(collected, Exception) or not isinstance(collected, Mapping):
            detail = (
                f"drum_kit collector raised {type(collected).__name__}: {collected}"
                if isinstance(collected, Exception)
                else "drum_kit collector returned malformed evidence"
            )
            runtime = _unavailable(REASON_RUNTIME_EVIDENCE_MISSING, detail)
            capability = _unavailable(REASON_RUNTIME_EVIDENCE_MISSING, detail)
        else:
            runtime_raw = collected.get("runtime")
            capability_raw = collected.get("capability")
            runtime = (
                _finalize_collected(runtime_raw, reason_code=REASON_RUNTIME_EVIDENCE_MISSING)
                if isinstance(runtime_raw, Mapping)
                else _unavailable(
                    REASON_RUNTIME_EVIDENCE_MISSING,
                    "drum_kit collector supplied no runtime-imports evidence",
                )
            )
            capability = (
                _finalize_collected(capability_raw, reason_code=REASON_RUNTIME_EVIDENCE_MISSING)
                if isinstance(capability_raw, Mapping)
                else _unavailable(
                    REASON_RUNTIME_EVIDENCE_MISSING,
                    "drum_kit collector supplied no capability evidence",
                )
            )
    model = _live_model_component(info["model_id"], info["flavor"], providers)
    return {"stage_id": stage_id, "runtime": runtime, "capability": capability, "model": model}


# ---------------------------------------------------------------------------
# Feasibility: the real resolver against the real catalog
# ---------------------------------------------------------------------------


def _plan_dict(plan: Any, fallback_reason: str = "") -> Dict[str, Any]:
    return {
        "stage_id": plan.stage_id,
        "model_id": plan.model_id,
        "capability_id": plan.capability_id,
        "requested_device": plan.requested_device,
        "resolved_backend": plan.resolved_backend,
        "resolved_device": plan.resolved_device,
        "fallback_applied": plan.fallback_applied,
        "fallback_reason": str(fallback_reason or ""),
        "reason_code": plan.reason_code,
        "detail": plan.detail,
        "contract_source": plan.contract_source,
    }


def _evaluate_feasibility(
    request: ReadinessRequest,
    infos: Sequence[Mapping[str, Any]],
    stage_components: Sequence[Mapping[str, Any]],
    *,
    catalog_dir: Path,
    platform_system: Optional[str],
    simulated: bool,
) -> Dict[str, Any]:
    evidence_kind = "simulated_policy_evaluation" if simulated else "real_probe_resolution"
    evidence: Dict[str, Any] = {
        "source": "simulated_fixture" if simulated else "collected",
        "evidence_kind": evidence_kind,
        "observed_at_utc": _utc_now(),
    }

    for info, components in zip(infos, stage_components):
        capability = components["capability"]
        stage_id = info["stage"]["stage_id"]
        if capability["verdict"] == FAIL:
            return _component(
                FAIL,
                reason_code=capability.get("reason_code") or REASON_RUNTIME_EVIDENCE_BROKEN,
                reason=f"stage {stage_id} capability evidence failed: "
                f"{capability.get('reason') or capability['verdict']}",
                evidence=evidence,
            )
        if capability["verdict"] != PASS:
            return _component(
                UNAVAILABLE,
                reason_code=capability.get("reason_code") or REASON_RUNTIME_EVIDENCE_MISSING,
                reason=f"stage {stage_id} capability evidence unavailable: "
                f"{capability.get('reason') or capability['verdict']}",
                evidence=evidence,
            )

    cuda_stage_identities = []
    for info, components in zip(infos, stage_components):
        resolution = components["capability"].get("resolution") or {}
        resolved_id = str(resolution.get("resolved_device_id") or "").strip().lower()
        if not re.fullmatch(r"cuda:\d+", resolved_id):
            continue
        identity = resolution.get("resolved_device_identity") or {}
        stable = {
            key: str(identity.get(key) or "").strip().lower()
            for key in ("uuid", "pci_bus_id")
            if str(identity.get(key) or "").strip()
        }
        cuda_stage_identities.append((str(info["stage"]["stage_id"]), stable))
    if len(cuda_stage_identities) > 1:
        if any(not identity for _, identity in cuda_stage_identities):
            return _component(
                FAIL,
                reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
                reason="CUDA workflow stages supplied no stable physical identity for comparison",
                evidence=evidence,
            )
        reference_stage, reference = cuda_stage_identities[0]
        for stage_id, identity in cuda_stage_identities[1:]:
            common_keys = set(reference).intersection(identity)
            if not common_keys:
                return _component(
                    FAIL,
                    reason_code=REASON_RUNTIME_EVIDENCE_BROKEN,
                    reason=(
                        f"CUDA workflow stages {reference_stage!r} and {stage_id!r} "
                        "supplied no common stable physical identity"
                    ),
                    evidence=evidence,
                )
            if any(reference[key] != identity[key] for key in common_keys):
                return _component(
                    FAIL,
                    reason_code=REASON_DEVICE_IDENTITY_MISMATCH,
                    reason=(
                        f"CUDA workflow stages {reference_stage!r} and {stage_id!r} "
                        "resolve to different physical devices"
                    ),
                    evidence=evidence,
                )

    stage_fallback_reasons = []
    for info, components in zip(infos, stage_components):
        resolution = components["capability"].get("resolution") or {}
        selection_info = resolution.get("selection_info") or {}
        stage_fallback_reasons.append(str(selection_info.get("fallback_reason") or ""))

    try:
        if len(infos) == 1:
            probe = _probe_from_resolution(
                infos[0]["flavor"],
                stage_components[0]["capability"]["resolution"],
                platform_system=platform_system,
            )
            plan = resolve_execution_plan(
                request.workflow_id,
                infos[0]["model_id"],
                request.requested_device,
                catalog_dir=catalog_dir,
                probe=probe,
            )
            plans = [_plan_dict(plan, stage_fallback_reasons[0])]
        else:
            stage_requests = [
                StageRequest(
                    model_id=info["model_id"],
                    requested_device=request.requested_device,
                    probe=_probe_from_resolution(
                        info["flavor"],
                        components["capability"]["resolution"],
                        platform_system=platform_system,
                    ),
                )
                for info, components in zip(infos, stage_components)
            ]
            workflow_plan = resolve_workflow_plan(
                request.workflow_id, stage_requests, catalog_dir=catalog_dir
            )
            plans = [
                _plan_dict(stage_plan, fallback_reason)
                for stage_plan, fallback_reason in zip(workflow_plan.stages, stage_fallback_reasons)
            ]
    except ResolutionError as exc:
        code = REASON_CATALOG_UNAVAILABLE if exc.code == REASON_CONTRACT_LOAD_ERROR else exc.code
        return _component(FAIL, reason_code=code, reason=exc.detail, evidence=evidence)

    return _component(PASS, evidence={**evidence, "plans": plans})


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------


def _aggregate(components: Sequence[tuple[str, Mapping[str, Any]]]) -> tuple[str, list[str]]:
    """Fail-closed readiness aggregation.

    PASS requires every required component at PASS. FAIL dominates.
    UNAVAILABLE, SKIPPED, NOT_APPLICABLE, and any other non-PASS state
    aggregate to UNAVAILABLE -- they never fall through to PASS. A component
    is excluded only when Core itself marks it ``required=False``; fixture
    input cannot change that flag.
    """

    failure_reasons: list[str] = []
    saw_fail = False
    saw_unavailable = False
    for path, component in components:
        if not component.get("required", True):
            continue
        verdict = component.get("verdict")
        if verdict == PASS:
            continue
        label = component.get("reason_code") or component.get("reason") or str(verdict)
        failure_reasons.append(f"{path}: {label}")
        if verdict == FAIL:
            saw_fail = True
        else:
            saw_unavailable = True
    if saw_fail:
        return FAIL, failure_reasons
    if saw_unavailable:
        return UNAVAILABLE, failure_reasons
    return PASS, []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def assess_readiness(
    request: Any,
    *,
    fixture: Any = None,
    catalog_dir: Optional[str | Path] = None,
    collectors: Optional[Mapping[str, Callable[[str], Mapping[str, Any]]]] = None,
    model_asset_providers: Optional[Mapping[str, Callable[[], Mapping[str, Any]]]] = None,
) -> Dict[str, Any]:
    """Evaluate readiness for one workflow request and return the report dict.

    ``fixture`` is a parsed fixture document (see module docstring); when
    supplied, the request's evidence_mode must be "fixture" and the whole
    evaluation is labeled simulated. ``collectors``/``model_asset_providers``
    are explicit override points for clients and controlled tests; Core never
    locates the legacy processor itself.
    """

    coerced = _coerce_request(request)
    simulated = coerced.evidence_mode == "fixture"
    if fixture is not None and not simulated:
        raise ReadinessError(
            REASON_MALFORMED_REQUEST, "fixture evidence requires evidence_mode='fixture'"
        )
    if simulated and fixture is None:
        raise ReadinessError(
            REASON_MALFORMED_REQUEST, "evidence_mode='fixture' requires a fixture document"
        )

    with _catalog_dir(catalog_dir) as (resolved_catalog_dir, catalog_source):
        catalogs = _load_catalogs(resolved_catalog_dir)
        workflow, infos = _resolve_stage_infos(coerced, catalogs)
        promised = _promised_deliverables(workflow, infos[-1]["capability_id"])
        requested_deliverables = _requested_deliverables(coerced.deliverable_ids, promised)

        if simulated:
            fixture_doc = _validate_fixture_document(fixture)
            fixture_stages = list(fixture_doc.get("stages") or [])
            if len(fixture_stages) > len(infos):
                raise ReadinessError(
                    REASON_FIXTURE_INVALID,
                    f"fixture has {len(fixture_stages)} stage(s); workflow "
                    f"{coerced.workflow_id!r} has {len(infos)}",
                )
            platform_system = str(fixture_doc.get("platform_system") or sys.platform)
            stage_components = [
                _fixture_stage_components(
                    fixture_stages[index] if index < len(fixture_stages) else None, info
                )
                for index, info in enumerate(infos)
            ]
            ffmpeg = _fixture_component(fixture_doc.get("ffmpeg"), "fixture.ffmpeg") or _incomplete(
                "ffmpeg"
            )
        else:
            platform_system = sys.platform
            collector_cache: Dict[str, Any] = {}
            stage_components = [
                _live_stage_components(
                    info, coerced.requested_device, collectors, model_asset_providers, collector_cache
                )
                for info in infos
            ]
            ffmpeg = _finalize_collected(
                readiness_collect.collect_ffmpeg(), reason_code=REASON_FFMPEG_UNAVAILABLE
            )

        feasibility = _evaluate_feasibility(
            coerced,
            infos,
            stage_components,
            catalog_dir=resolved_catalog_dir,
            platform_system=platform_system,
            simulated=simulated,
        )

        aggregate_components: list[tuple[str, Mapping[str, Any]]] = []
        stage_entries: list[Dict[str, Any]] = []
        for info, components in zip(infos, stage_components):
            stage_id = info["stage"]["stage_id"]
            aggregate_components.extend(
                [
                    (f"stage[{stage_id}].runtime", components["runtime"]),
                    (f"stage[{stage_id}].capability", components["capability"]),
                    (f"stage[{stage_id}].model", components["model"]),
                ]
            )
            stage_entries.append(
                {
                    "stage_id": stage_id,
                    "order": info["stage"]["order"],
                    "model_id": info["model_id"],
                    "capability_id": info["capability_id"],
                    "components": {
                        "runtime": components["runtime"],
                        "capability": components["capability"],
                        "model": components["model"],
                    },
                }
            )
        aggregate_components.append(("ffmpeg", ffmpeg))
        aggregate_components.append(("feasibility", feasibility))
        verdict, failure_reasons = _aggregate(aggregate_components)

        limits = ["no_inference_evidence"]
        if simulated:
            limits.append("fixture_evidence_not_local_observation")
        demucs_presence_only = any(
            (components["model"].get("evidence") or {}).get("integrity") == "unverified"
            and components["model"].get("verdict") == PASS
            for components in stage_components
        )
        if demucs_presence_only:
            limits.append("demucs_model_integrity_unverified")

        return {
            "schema_version": SCHEMA_VERSION,
            "kind": REPORT_KIND,
            "evaluation_mode": "simulated" if simulated else "live",
            "generated_at_utc": _utc_now(),
            "request": {
                "workflow_id": coerced.workflow_id,
                "model_ids": [info["model_id"] for info in infos],
                "requested_device": coerced.requested_device,
                "deliverable_ids": (
                    list(coerced.deliverable_ids) if coerced.deliverable_ids is not None else None
                ),
                "evidence_mode": coerced.evidence_mode,
            },
            "catalog": {
                "source": catalog_source,
                "path": str(resolved_catalog_dir),
                "schema_version": workflow_contracts.SCHEMA_VERSION,
            },
            "stages": stage_entries,
            "components": {"ffmpeg": ffmpeg, "feasibility": feasibility},
            "deliverables": {"promised": promised, "requested": requested_deliverables},
            "readiness": {
                "verdict": verdict,
                "scope": "simulated_policy_evaluation" if simulated else "local_preflight",
                "failure_reasons": failure_reasons,
                "authoritative_gate": "execution_time_recheck",
                "limits": limits,
            },
        }


def exit_code_for_report(report: Mapping[str, Any]) -> int:
    """Map a readiness report to the CLI/adapter exit code.

    A simulated PASS deliberately does not share the meaning of a verified
    live local preflight PASS (3, not 0).
    """

    readiness = report.get("readiness") or {}
    verdict = readiness.get("verdict")
    if verdict == PASS:
        return EXIT_SIMULATED_PASS if report.get("evaluation_mode") == "simulated" else EXIT_LIVE_READY
    if verdict == FAIL:
        return EXIT_NOT_READY
    return EXIT_UNAVAILABLE_OR_ERROR


def error_document(code: str, detail: str) -> Dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": ERROR_KIND,
        "error": {"code": code, "detail": detail},
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m stemwerk_core.readiness",
        description=(
            "Evaluate STEMwerk workflow readiness. stdout carries only the "
            "machine-readable report (or error document); diagnostics go to stderr. "
            "Exit codes: 0=live preflight PASS, 1=FAIL, 2=UNAVAILABLE/error, "
            "3=simulated PASS."
        ),
    )
    parser.add_argument("--workflow", required=True, help="catalog workflow_id")
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        default=None,
        help="catalog model_id; repeat per stage for drum_kit_split (default: Core defaults)",
    )
    parser.add_argument("--device", default="auto", help="requested device (default: auto)")
    parser.add_argument(
        "--deliverables",
        default=None,
        help="comma-separated ordered subset of the promised route deliverables",
    )
    parser.add_argument("--catalog-dir", default=None, help="explicit catalog directory")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--collect",
        action="store_true",
        help="collect current local evidence (default)",
    )
    mode.add_argument(
        "--fixture",
        default=None,
        help="path to a stemwerk_readiness_fixture JSON document (simulated evaluation)",
    )
    parser.add_argument("--pretty", action="store_true", help="indent JSON output")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    deliverable_ids = None
    if args.deliverables:
        deliverable_ids = [item.strip() for item in args.deliverables.split(",") if item.strip()]

    fixture = None
    evidence_mode = "collect"
    if args.fixture:
        evidence_mode = "fixture"
        try:
            fixture = workflow_contracts.load_json(args.fixture)
        except workflow_contracts.ContractError as exc:
            document = error_document(REASON_FIXTURE_INVALID, str(exc))
            json.dump(document, sys.stdout, indent=2 if args.pretty else None)
            sys.stdout.write("\n")
            print(f"readiness: {REASON_FIXTURE_INVALID}: {exc}", file=sys.stderr)
            return EXIT_UNAVAILABLE_OR_ERROR

    request = ReadinessRequest(
        workflow_id=args.workflow,
        model_id=args.models,
        requested_device=args.device,
        deliverable_ids=deliverable_ids,
        evidence_mode=evidence_mode,
    )
    try:
        report = assess_readiness(
            request, fixture=fixture, catalog_dir=args.catalog_dir
        )
    except ReadinessError as exc:
        document = error_document(exc.code, exc.detail)
        json.dump(document, sys.stdout, indent=2 if args.pretty else None)
        sys.stdout.write("\n")
        print(f"readiness: {exc.code}: {exc.detail}", file=sys.stderr)
        return EXIT_UNAVAILABLE_OR_ERROR

    json.dump(report, sys.stdout, indent=2 if args.pretty else None)
    sys.stdout.write("\n")
    verdict = report["readiness"]["verdict"]
    scope = report["readiness"]["scope"]
    print(f"readiness: {verdict} ({scope})", file=sys.stderr)
    return exit_code_for_report(report)


if __name__ == "__main__":
    sys.exit(main())
