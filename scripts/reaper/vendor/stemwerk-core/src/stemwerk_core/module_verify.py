"""Read-only verification of a module's installation state.

``verify_module`` asks a component lookup where each component of a module
descriptor lives, classifies every component and derives the installation
state with the precedence rules of design section 2.1. It never writes,
never takes a lock and never repairs.

The lookup is the only source of locations. The default lookup has no
registry and finds nothing, so every component is absent; the registry
reader replaces it later. Legacy 2.3 layouts are never consulted here.

Only asset components have a verifier today. A component of another kind
that a lookup does find is ``unverifiable``, so the module is ``unknown``
and never ``installed``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import stat
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Protocol, Tuple

from . import asset_materialization as materialization
from . import module_descriptors
from .module_descriptors import AssetPin, ComponentDescriptor, ModuleDescriptor


SCHEMA_VERSION = "1.0.0"
DOCUMENT_KIND = "stemwerk_module_verification"

ABSENT = "absent"
PRESENT_FAILING = "present_failing"
PRESENT_PASSING = "present_passing"
UNVERIFIABLE = "unverifiable"
COMPONENT_CLASSES = (ABSENT, PRESENT_FAILING, PRESENT_PASSING, UNVERIFIABLE)

NOT_INSTALLED = "not_installed"
PARTIAL = "partial"
INSTALLED = "installed"
REPAIR_REQUIRED = "repair_required"
UNKNOWN = "unknown"

REASON_NOT_FOUND = "not_found"
REASON_LOOKUP_FAILED = "lookup_failed"
REASON_VERIFIER_UNAVAILABLE = "verifier_unavailable"
REASON_VERIFIED = "verified"

# Per-file results of the asset verifier, by the component class they imply.
_FILE_FAILING = frozenset(
    {
        "asset_file_missing",
        "asset_not_regular_file",
        "asset_size_mismatch",
        "asset_integrity_mismatch",
        "symlink_not_allowed",
    }
)
_FILE_UNVERIFIABLE = frozenset({"asset_unreadable", "location_invalid"})

# Codes raised by the shared materialization source check.
_MATERIALIZATION_FILE_CODES = {
    "source_missing": "asset_file_missing",
    "source_not_regular": "asset_not_regular_file",
    "source_integrity_mismatch": "asset_integrity_mismatch",
    "source_unreadable": "asset_unreadable",
    "path_unreadable": "asset_unreadable",
    "symlink_not_allowed": "symlink_not_allowed",
    "invalid_path": "location_invalid",
}


class ComponentLookupError(Exception):
    """Raised by a lookup that cannot answer, for example an unreadable registry."""


@dataclass(frozen=True)
class ComponentLocation:
    """Where a lookup says a component lives."""

    path: Path


class ComponentLookup(Protocol):
    """Source of component locations.

    ``locate`` returns ``None`` when the component is not found and raises
    ``ComponentLookupError`` when the lookup itself cannot be read.
    """

    lookup_id: str

    def locate(self, module_id: str, component_id: str) -> Optional[ComponentLocation]:
        ...


class NoRegistryLookup:
    """Default lookup until the module registry exists: finds nothing.

    It touches no file system path; legacy 2.3 layouts are deliberately not
    consulted, so the result of a real verification is ``not_installed``.
    """

    lookup_id = "no_registry"

    def locate(self, module_id: str, component_id: str) -> Optional[ComponentLocation]:
        return None


@dataclass(frozen=True)
class ComponentVerdict:
    """Outcome of verifying one located component."""

    component_class: str
    reason_code: str
    details: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.component_class not in (PRESENT_FAILING, PRESENT_PASSING, UNVERIFIABLE):
            raise ValueError(
                f"a located component cannot be classified {self.component_class!r}"
            )
        if not isinstance(self.reason_code, str) or not self.reason_code:
            raise ValueError("a verdict needs a reason code")


Verifier = Callable[[ComponentDescriptor, ComponentLocation], ComponentVerdict]


def installation_state(classes: Iterable[str]) -> Tuple[str, int]:
    """Module state and the number of the design section 2.1 rule that decided it.

    1. any present-failing component: ``repair_required`` (a missing
       component never hides a corrupt one);
    2. any unverifiable component: ``unknown``;
    3. all components absent: ``not_installed``;
    4. any component absent: ``partial``;
    5. otherwise: ``installed``.
    """

    observed = tuple(classes)
    if not observed:
        raise ValueError("a module has at least one component")
    unexpected = [value for value in observed if value not in COMPONENT_CLASSES]
    if unexpected:
        raise ValueError(f"unknown component class {unexpected[0]!r}")
    if PRESENT_FAILING in observed:
        return REPAIR_REQUIRED, 1
    if UNVERIFIABLE in observed:
        return UNKNOWN, 2
    if all(value == ABSENT for value in observed):
        return NOT_INSTALLED, 3
    if ABSENT in observed:
        return PARTIAL, 4
    return INSTALLED, 5


def _file_result(
    pin: AssetPin, result: str, observed_size: Optional[int] = None
) -> Dict[str, Any]:
    return {
        "name": pin.name,
        "result": result,
        "expected_size": pin.size,
        "observed_size": observed_size,
        "expected_sha256": pin.sha256,
    }


def _verify_asset_file(directory: Path, pin: AssetPin) -> Dict[str, Any]:
    path = directory / pin.name
    try:
        path_stat = os.lstat(path)
    except FileNotFoundError:
        return _file_result(pin, "asset_file_missing")
    except OSError:
        return _file_result(pin, "asset_unreadable")
    if materialization._is_link_or_reparse(path_stat):
        return _file_result(pin, "symlink_not_allowed")
    if not stat.S_ISREG(path_stat.st_mode):
        return _file_result(pin, "asset_not_regular_file")
    if path_stat.st_size != pin.size:
        # Size first: a wrong-sized file is never hashed.
        return _file_result(pin, "asset_size_mismatch", path_stat.st_size)
    try:
        validated = materialization._validate_source(pin.name, path, pin.sha256)
    except materialization.MaterializationError as exc:
        return _file_result(
            pin, _MATERIALIZATION_FILE_CODES.get(exc.code, "asset_unreadable"), path_stat.st_size
        )
    if validated.size != pin.size:
        return _file_result(pin, "asset_size_mismatch", validated.size)
    return _file_result(pin, REASON_VERIFIED, validated.size)


def verify_asset_component(
    component: ComponentDescriptor, location: ComponentLocation
) -> ComponentVerdict:
    """Exact size and SHA-256 of every pinned file in the located directory.

    The directory and its ancestors must not be symbolic links or reparse
    points, matching the asset materialization policy. Files are opened
    read-only without following links; nothing is created or changed.
    """

    label = f"location of {component.component_id}"
    try:
        directory = materialization._absolute_path(location.path, label)
        materialization._reject_symlink_components(directory, label)
    except materialization.MaterializationError as exc:
        if exc.code == "symlink_not_allowed":
            return ComponentVerdict(PRESENT_FAILING, "symlink_not_allowed")
        if exc.code == "invalid_path":
            return ComponentVerdict(UNVERIFIABLE, "location_invalid")
        return ComponentVerdict(UNVERIFIABLE, "location_unreadable")
    try:
        directory_stat = os.lstat(directory)
    except FileNotFoundError:
        return ComponentVerdict(PRESENT_FAILING, "location_missing")
    except OSError:
        return ComponentVerdict(UNVERIFIABLE, "location_unreadable")
    if not stat.S_ISDIR(directory_stat.st_mode):
        return ComponentVerdict(PRESENT_FAILING, "location_not_directory")

    files = [_verify_asset_file(directory, pin) for pin in component.assets]
    details = {"files": files}
    for file in files:
        if file["result"] in _FILE_FAILING:
            return ComponentVerdict(PRESENT_FAILING, file["result"], details)
    for file in files:
        if file["result"] in _FILE_UNVERIFIABLE:
            return ComponentVerdict(UNVERIFIABLE, file["result"], details)
    return ComponentVerdict(PRESENT_PASSING, REASON_VERIFIED, details)


DEFAULT_VERIFIERS: Mapping[str, Verifier] = {
    module_descriptors.KIND_ASSET: verify_asset_component,
}


def _component_entry(
    component: ComponentDescriptor,
    component_class: str,
    reason_code: str,
    location: Optional[ComponentLocation],
    details: Mapping[str, Any],
) -> Dict[str, Any]:
    entry: Dict[str, Any] = {
        "component_id": component.component_id,
        "kind": component.kind,
        "class": component_class,
        "reason_code": reason_code,
        "location": None if location is None else str(location.path),
    }
    entry.update(details)
    return entry


def _classify(
    module_id: str,
    component: ComponentDescriptor,
    lookup: ComponentLookup,
    verifiers: Mapping[str, Verifier],
) -> Dict[str, Any]:
    try:
        location = lookup.locate(module_id, component.component_id)
    except ComponentLookupError:
        return _component_entry(component, UNVERIFIABLE, REASON_LOOKUP_FAILED, None, {})
    if location is None:
        return _component_entry(component, ABSENT, REASON_NOT_FOUND, None, {})
    if not isinstance(location, ComponentLocation):
        raise TypeError("a lookup must return a ComponentLocation or None")
    verifier = verifiers.get(component.kind)
    if verifier is None:
        return _component_entry(
            component, UNVERIFIABLE, REASON_VERIFIER_UNAVAILABLE, location, {}
        )
    verdict = verifier(component, location)
    if not isinstance(verdict, ComponentVerdict):
        raise TypeError("a verifier must return a ComponentVerdict")
    return _component_entry(
        component, verdict.component_class, verdict.reason_code, location, verdict.details
    )


def verify_descriptor(
    descriptor: ModuleDescriptor,
    *,
    lookup: Optional[ComponentLookup] = None,
    verifiers: Optional[Mapping[str, Verifier]] = None,
) -> Dict[str, Any]:
    """Verify ``descriptor`` and return a ``stemwerk_module_verification`` document.

    ``verifiers`` adds to or replaces the default verifiers by component kind.
    """

    if not isinstance(descriptor, ModuleDescriptor):
        raise TypeError("descriptor must be a ModuleDescriptor")
    active_lookup = NoRegistryLookup() if lookup is None else lookup
    active_verifiers = {**DEFAULT_VERIFIERS, **(verifiers or {})}
    components: List[Dict[str, Any]] = [
        _classify(descriptor.module_id, component, active_lookup, active_verifiers)
        for component in descriptor.components
    ]
    state, rule = installation_state(entry["class"] for entry in components)
    return {
        "kind": DOCUMENT_KIND,
        "schema_version": SCHEMA_VERSION,
        "descriptor_version": module_descriptors.DESCRIPTOR_VERSION,
        "module_id": descriptor.module_id,
        "workflow_id": descriptor.workflow_id,
        "engine_id": descriptor.engine_id,
        "display_name": descriptor.display_name,
        "lookup": active_lookup.lookup_id,
        "installation_state": state,
        "decided_by_rule": rule,
        "components": components,
    }


def verify_module(
    module_id: str,
    *,
    lookup: Optional[ComponentLookup] = None,
    verifiers: Optional[Mapping[str, Verifier]] = None,
) -> Dict[str, Any]:
    """Verify the module ``module_id``; ``ValueError`` for an unknown module."""

    return verify_descriptor(
        module_descriptors.get_module_descriptor(module_id),
        lookup=lookup,
        verifiers=verifiers,
    )
