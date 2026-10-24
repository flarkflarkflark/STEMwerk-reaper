"""Contract-driven runtime resolver (Slice 1 + Slice 2).

Bridges the declarative catalogs (see ``workflow_contracts``) to backend/
device capability resolution, producing small immutable execution plans
that runtime code can validate ahead of expensive processing.

Like ``workflow_contracts``, this module is intentionally pure: it never
imports ``audio_separator_process.py`` or any other legacy runtime script,
never probes real hardware itself, and never encodes GPU backend-priority
policy. All hardware-facing behaviour is supplied by the caller through a
``CapabilityProbe`` -- production wiring that reproduces the exact legacy
Auto device-preference policy (e.g. the Linux AMD-name scoring in
``audio_separator_process._prefer_linux_amd_device``, or the DrumSep
runtime-selection policy in ``audio_separator_process._select_drumsep_runtime``)
lives in ``scripts/reaper/_internal/stemwerk_runtime_seam.py``, not here.

Backend permission (``permitted_backends``) is read directly from each
resolved capability's catalog entry -- there is no separate Python-side
policy table to keep in sync with the catalog.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

from . import devices as _devices
from . import workflow_contracts

REASON_OK_AUTO = "auto_resolved"
REASON_OK_EXPLICIT = "explicit_resolved"
REASON_UNKNOWN_WORKFLOW = "unknown_workflow"
REASON_UNKNOWN_MODEL = "unknown_model"
REASON_UNKNOWN_CAPABILITY = "unknown_capability"
REASON_MODEL_CAPABILITY_MISMATCH = "model_capability_mismatch"
REASON_UNSUPPORTED_STAGE_COUNT = "unsupported_stage_count"
REASON_STAGE_REQUEST_COUNT_MISMATCH = "stage_request_count_mismatch"
REASON_CONTRACT_LOAD_ERROR = "contract_load_error"
REASON_BACKEND_NOT_PERMITTED = "backend_not_permitted"
REASON_BACKEND_UNAVAILABLE = "backend_unavailable"

CONTRACT_SOURCE = "2.4_contract"


class ResolutionError(ValueError):
    """Fail-closed resolution failure with a stable machine-readable code."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class ExecutionPlan:
    """Immutable, contract-resolved plan for one workflow stage."""

    workflow_id: str
    schema_version: str
    stage_id: str
    capability_id: str
    model_id: str
    requested_device: str
    resolved_backend: str
    resolved_device: str
    fallback_applied: bool
    reason_code: str
    detail: str
    contract_source: str = CONTRACT_SOURCE


@dataclass(frozen=True)
class WorkflowExecutionPlan:
    """Immutable, contract-resolved plan for every stage of a workflow, in order."""

    workflow_id: str
    schema_version: str
    stages: tuple
    contract_source: str = CONTRACT_SOURCE


def _default_is_unexpected_cpu_downgrade(requested_device: str, resolved_device: str) -> bool:
    requested = str(requested_device or "auto").strip().lower()
    resolved = str(resolved_device or "").strip().lower()
    if resolved != "cpu":
        return False
    return requested not in ("", "auto", "cpu")


@dataclass(frozen=True)
class CapabilityProbe:
    """Injectable hardware-facing primitives the resolver composes.

    ``resolve_auto_device`` must return the *fully* resolved preferred
    device for ``requested_device="auto"`` (i.e. any legacy re-resolution
    such as ROCm-Tensile-skip fallback already applied), or ``None`` to fall
    through to the generic ``select_device("auto")`` priority. Returning
    ``None`` unconditionally is a legitimate, honest default: it means "no
    capability-specific Auto preference known," not "no GPU available."
    """

    get_available_devices: Callable[[], Sequence[Mapping[str, str]]]
    select_device: Callable[[str], tuple]
    runtime_kind_for_device: Callable[[Optional[str]], str]
    is_unexpected_cpu_downgrade: Callable[[str, str], bool] = _default_is_unexpected_cpu_downgrade
    resolve_auto_device: Callable[[Sequence[Mapping[str, str]]], Optional[Mapping[str, str]]] = field(
        default=lambda live_devices: None
    )


DEFAULT_CAPABILITY_PROBE = CapabilityProbe(
    get_available_devices=_devices.get_available_devices,
    select_device=_devices.select_device,
    runtime_kind_for_device=_devices.runtime_kind_for_device,
)


@dataclass(frozen=True)
class StageRequest:
    """One stage's concrete model/device request, paired with the probe that
    resolves its backend/device. Different stages typically need different
    probes -- e.g. a Normal-Stems-style stage and a DrumSep-style stage use
    entirely different hardware-selection machinery."""

    model_id: str
    requested_device: str
    probe: CapabilityProbe = DEFAULT_CAPABILITY_PROBE


def _load_catalogs(catalog_dir: str | Path) -> Mapping[str, Sequence[Mapping[str, Any]]]:
    try:
        return workflow_contracts.validate_catalogs(catalog_dir)
    except workflow_contracts.ContractError as exc:
        raise ResolutionError(REASON_CONTRACT_LOAD_ERROR, str(exc)) from exc


def _lookup(
    entries: Sequence[Mapping[str, Any]], key: str, value: str, reason_code: str, detail: str
) -> Mapping[str, Any]:
    for entry in entries:
        if entry.get(key) == value:
            return entry
    raise ResolutionError(reason_code, detail)


def _resolve_backend_and_device(requested: str, probe: CapabilityProbe) -> tuple:
    if requested == "auto":
        live_devices = probe.get_available_devices()
        preferred = probe.resolve_auto_device(live_devices)
        if preferred is not None:
            resolved_device = str(preferred.get("id") or "auto")
            detail = f"auto resolved to preferred device {resolved_device} ({preferred.get('name', '')})"
        else:
            resolved_device, name = probe.select_device("auto")
            detail = f"auto resolved to {resolved_device} ({name}) via generic backend priority"
        resolved_backend = probe.runtime_kind_for_device(resolved_device)
        fallback_applied = resolved_backend == "cpu"
        return resolved_device, resolved_backend, fallback_applied, detail

    resolved_device, name = probe.select_device(requested)
    resolved_backend = probe.runtime_kind_for_device(resolved_device)
    fallback_applied = resolved_device != requested
    detail = f"requested device {requested!r} resolved to {resolved_device} ({name})"
    return resolved_device, resolved_backend, fallback_applied, detail


def _resolve_single_stage(
    catalogs: Mapping[str, Sequence[Mapping[str, Any]]],
    workflow_id: str,
    stage: Mapping[str, Any],
    model_id: str,
    requested_device: str,
    probe: CapabilityProbe,
) -> ExecutionPlan:
    stage_id = stage["stage_id"]
    permitted_capability_ids = list(stage["capability_ids"])

    model = _lookup(
        catalogs["models"], "model_id", model_id,
        REASON_UNKNOWN_MODEL, f"unknown model_id: {model_id!r}",
    )
    model_capability_id = model["capability_id"]
    if model_capability_id not in permitted_capability_ids:
        raise ResolutionError(
            REASON_MODEL_CAPABILITY_MISMATCH,
            f"model {model_id!r} provides capability {model_capability_id!r}, which is not "
            f"among stage {stage_id!r}'s permitted capabilities {sorted(permitted_capability_ids)}",
        )

    capability = _lookup(
        catalogs["capabilities"], "capability_id", model_capability_id,
        REASON_UNKNOWN_CAPABILITY,
        f"workflow {workflow_id!r} stage {stage_id!r} references unknown capability_id: {model_capability_id!r}",
    )

    requested = str(requested_device or "auto")
    resolved_device, resolved_backend, fallback_applied, detail = _resolve_backend_and_device(requested, probe)

    if probe.is_unexpected_cpu_downgrade(requested, resolved_device):
        raise ResolutionError(
            REASON_BACKEND_UNAVAILABLE,
            f"requested device {requested!r} is not available on this machine; "
            "refusing to silently downgrade to cpu",
        )

    permitted_backends = frozenset(capability.get("permitted_backends") or ())
    if resolved_backend not in permitted_backends:
        raise ResolutionError(
            REASON_BACKEND_NOT_PERMITTED,
            f"backend {resolved_backend!r} is not permitted for capability {model_capability_id!r} "
            f"(permitted: {sorted(permitted_backends)})",
        )

    return ExecutionPlan(
        workflow_id=workflow_id,
        schema_version=workflow_contracts.SCHEMA_VERSION,
        stage_id=stage_id,
        capability_id=model_capability_id,
        model_id=model["model_id"],
        requested_device=requested,
        resolved_backend=resolved_backend,
        resolved_device=resolved_device,
        fallback_applied=fallback_applied,
        reason_code=REASON_OK_AUTO if requested == "auto" else REASON_OK_EXPLICIT,
        detail=detail,
    )


def resolve_execution_plan(
    workflow_id: str,
    model_id: str,
    requested_device: str,
    *,
    catalog_dir: str | Path,
    probe: CapabilityProbe = DEFAULT_CAPABILITY_PROBE,
) -> ExecutionPlan:
    """Resolve a single-stage workflow to a concrete backend/device plan.

    Fails closed (raises ``ResolutionError``) for any unknown or
    contradictory contract reference, and for any backend that is either not
    permitted for the resolved capability or not actually available on this
    machine. Never guesses: an explicit non-auto/non-cpu request that would
    silently downgrade to CPU is rejected rather than substituted, mirroring
    the existing 2.3 ``_is_unexpected_cpu_downgrade`` guard.

    Raises ``ResolutionError(REASON_UNSUPPORTED_STAGE_COUNT, ...)`` for a
    workflow with more than one stage -- use ``resolve_workflow_plan`` for
    those (e.g. Drum Split).
    """

    catalogs = _load_catalogs(catalog_dir)
    workflow = _lookup(
        catalogs["workflows"], "workflow_id", workflow_id,
        REASON_UNKNOWN_WORKFLOW, f"unknown workflow_id: {workflow_id!r}",
    )
    stages = workflow.get("ordered_stages") or []
    if len(stages) != 1:
        raise ResolutionError(
            REASON_UNSUPPORTED_STAGE_COUNT,
            f"workflow {workflow_id!r} has {len(stages)} stage(s); resolve_execution_plan only "
            "supports single-stage workflows -- use resolve_workflow_plan for multi-stage workflows",
        )
    return _resolve_single_stage(catalogs, workflow["workflow_id"], stages[0], model_id, requested_device, probe)


def resolve_workflow_plan(
    workflow_id: str,
    stage_requests: Sequence[StageRequest],
    *,
    catalog_dir: str | Path,
) -> WorkflowExecutionPlan:
    """Resolve every stage of a (possibly multi-stage) workflow, in order.

    Each stage resolves independently against its own ``StageRequest``
    (model/device/probe); ``validate_catalogs`` has already proven, at
    catalog-load time, that any ``stage_output``-kind stage's producer
    reference is valid, so no additional inter-stage plumbing is needed here
    beyond resolving each stage against its own catalog entry.
    """

    catalogs = _load_catalogs(catalog_dir)
    workflow = _lookup(
        catalogs["workflows"], "workflow_id", workflow_id,
        REASON_UNKNOWN_WORKFLOW, f"unknown workflow_id: {workflow_id!r}",
    )
    stages = workflow.get("ordered_stages") or []
    if len(stage_requests) != len(stages):
        raise ResolutionError(
            REASON_STAGE_REQUEST_COUNT_MISMATCH,
            f"workflow {workflow_id!r} has {len(stages)} stage(s); {len(stage_requests)} "
            "stage request(s) were provided",
        )

    resolved_stages = tuple(
        _resolve_single_stage(
            catalogs, workflow["workflow_id"], stage,
            stage_request.model_id, stage_request.requested_device, stage_request.probe,
        )
        for stage, stage_request in zip(stages, stage_requests)
    )
    return WorkflowExecutionPlan(
        workflow_id=workflow["workflow_id"],
        schema_version=workflow_contracts.SCHEMA_VERSION,
        stages=resolved_stages,
    )
