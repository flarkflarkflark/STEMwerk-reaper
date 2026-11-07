"""Read-only verification of a module's installation state.

``verify_module`` asks a component lookup where each component of a module
descriptor lives, classifies every component and derives the installation
state with the precedence rules of design section 2.1. It never writes,
never takes a lock and never repairs.

The lookup is the only source of locations. When ``state/module-registry.v1.json``
and ``state/modules/<module>.receipt.json`` are absent, ``NoRegistryLookup`` is
used and every component is ``absent``; when either exists, ``RegistryLookup``
validates their consistency and locates the receipted S6 components
(``managed_python``, ``module_venv``, ``drumsep_assets``). Legacy 2.3 layouts
are never consulted here.

The document also reports whether an installation operation is running
(design section 2.1): ``operation_in_progress``, ``operation_id`` and
``lock_status`` from ``install_lock.inspect_lock``. Reading the lock never
takes it, and a held lock never changes ``installation_state``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Protocol, Tuple

from . import asset_materialization as materialization
from . import install_lock, managed_python, managed_runtime, module_descriptors, module_registry
from . import runtime_manifest, subprocess_policy, wheel_lock
from .module_descriptors import AssetPin, ComponentDescriptor, ModuleDescriptor


SCHEMA_VERSION = "1.1.0"
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
    receipt_entry: Optional[Mapping[str, Any]] = None
    runtime_root: Optional[Path] = None


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


_DEFAULT_NO_REGISTRY_LOCATE = NoRegistryLookup.locate


class RegistryLookup:
    """Lookup backed by a validated ``module-registry.v1.json`` and module receipt."""

    lookup_id = "module_registry"

    def __init__(self, runtime_root: Path, receipt: Mapping[str, Any]) -> None:
        self._runtime_root = Path(runtime_root)
        self._receipt = receipt

    def locate(self, module_id: str, component_id: str) -> Optional[ComponentLocation]:
        if self._receipt.get("module_id") != module_id:
            return None
        components = self._receipt.get("components")
        if not isinstance(components, Mapping):
            raise ComponentLookupError("receipt_components_invalid")
        entry = components.get(component_id)
        if entry is None:
            return None
        if not isinstance(entry, Mapping) or not entry.get("path"):
            raise ComponentLookupError(f"receipt_component_invalid:{component_id}")
        return ComponentLocation(
            path=Path(str(entry["path"])),
            receipt_entry=entry,
            runtime_root=self._runtime_root,
        )


class UnverifiableRegistryLookup:
    """Lookup used when registry or receipt state exists on disk but is torn,
    corrupt, or inconsistent. Never implicitly adopts unreceipted components.
    """

    lookup_id = "module_registry"

    def __init__(self, reason: str) -> None:
        self.reason = reason

    def locate(self, module_id: str, component_id: str) -> Optional[ComponentLocation]:
        if component_id in {"managed_python", "module_venv", "drumsep_assets"}:
            raise ComponentLookupError(self.reason)
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
    details: Dict[str, Any] = {"files": files}
    if location.receipt_entry is not None:
        details["ownership"] = str(location.receipt_entry.get("ownership") or "core_managed")
        bundle_id = location.receipt_entry.get("bundle_id")
        if bundle_id:
            details["bundle_id"] = str(bundle_id)
    for file in files:
        if file["result"] in _FILE_FAILING:
            return ComponentVerdict(PRESENT_FAILING, file["result"], details)
    for file in files:
        if file["result"] in _FILE_UNVERIFIABLE:
            return ComponentVerdict(UNVERIFIABLE, file["result"], details)
    return ComponentVerdict(PRESENT_PASSING, REASON_VERIFIED, details)


_MODULE_VENV_PROBE_SRC = r"""
import importlib
import importlib.metadata as metadata
import json
import sys

required_modules = (
    "audio_separator",
    "librosa",
    "numpy",
    "onnx",
    "onnx2torch",
    "onnxruntime",
    "soundfile",
    "stemwerk_core",
    "torch",
    "torchvision",
)
missing = {}
loaded = {}
for name in required_modules:
    try:
        loaded[name] = importlib.import_module(name)
    except Exception as exc:
        missing[name] = f"{type(exc).__name__}: {exc}"

try:
    from audio_separator.separator import Separator
    separator_ok = Separator is not None
except Exception as exc:
    separator_ok = False
    missing["audio_separator.separator.Separator"] = f"{type(exc).__name__}: {exc}"

torch_mod = loaded.get("torch")
ort_mod = loaded.get("onnxruntime")
torch_cuda = bool(torch_mod.cuda.is_available()) if torch_mod is not None else None
torch_cuda_ver = getattr(getattr(torch_mod, "version", None), "cuda", None) if torch_mod is not None else None
torch_hip_ver = getattr(getattr(torch_mod, "version", None), "hip", None) if torch_mod is not None else None
providers = list(ort_mod.get_available_providers()) if ort_mod is not None else []

installed_versions = {}
for dist in metadata.distributions():
    name = dist.metadata.get("Name")
    if name:
        installed_versions[name.lower().replace("_", "-")] = dist.version

print(json.dumps({
    "dont_write_bytecode": bool(sys.dont_write_bytecode),
    "missing": missing,
    "separator_ok": separator_ok,
    "torch_cuda_available": torch_cuda,
    "torch_cuda_version": torch_cuda_ver,
    "torch_hip_version": torch_hip_ver,
    "onnx_version": getattr(loaded.get("onnx"), "__version__", None),
    "onnxruntime_providers": providers,
    "installed_versions": installed_versions,
}, sort_keys=True))
"""


def _verify_managed_python_with_receipt(
    component: ComponentDescriptor, location: ComponentLocation
) -> ComponentVerdict:
    receipt = location.receipt_entry or {}
    ownership = str(receipt.get("ownership") or "unknown")
    label = f"location of {component.component_id}"
    try:
        directory = materialization._absolute_path(location.path, label)
        materialization._reject_symlink_components(directory, label)
    except materialization.MaterializationError as exc:
        if exc.code == "symlink_not_allowed":
            return ComponentVerdict(PRESENT_FAILING, "symlink_not_allowed", {"ownership": ownership})
        return ComponentVerdict(UNVERIFIABLE, "location_invalid", {"ownership": ownership})

    runtime_root = location.runtime_root or directory.parent.parent.parent
    try:
        py_rec = runtime_manifest.python_record("linux-x86_64")
    except Exception:
        return ComponentVerdict(UNVERIFIABLE, "manifest_unavailable", {"ownership": ownership})

    expected_dir = runtime_manifest.published_directory(runtime_root, py_rec)
    if receipt.get("pin_id") != py_rec.name or directory != expected_dir:
        return ComponentVerdict(
            PRESENT_FAILING,
            "managed_python_pin_mismatch",
            {"ownership": ownership, "expected_pin_id": py_rec.name, "observed_pin_id": receipt.get("pin_id")},
        )

    mp_doc = managed_python.verify_managed_python(runtime_root, py_rec)
    mp_status = mp_doc.get("status")
    if mp_status == managed_python.ABSENT:
        return ComponentVerdict(PRESENT_FAILING, "location_missing", {"ownership": ownership})
    if mp_status != managed_python.VERIFIED:
        reasons = mp_doc.get("reasons") or []
        first_reason = (
            str(reasons[0].get("code") or "managed_python_invalid")
            if reasons and isinstance(reasons[0], Mapping)
            else "managed_python_invalid"
        )
        return ComponentVerdict(
            PRESENT_FAILING,
            first_reason,
            {"ownership": ownership},
        )

    try:
        identity = module_registry.compute_tree_identity(directory)
    except module_registry.RegistryError as exc:
        return ComponentVerdict(PRESENT_FAILING, exc.code, {"ownership": ownership, "detail": str(exc)})
    except OSError as exc:
        return ComponentVerdict(UNVERIFIABLE, "tree_unreadable", {"ownership": ownership, "detail": type(exc).__name__})

    expected_s5b = receipt.get("s5b_tree_sha256")
    if (
        identity.tree_sha256 != receipt.get("tree_sha256")
        or identity.entry_count != receipt.get("entry_count")
        or identity.pyc_count != receipt.get("pyc_count")
        or (expected_s5b and identity.s5b_tree_sha256 != expected_s5b)
    ):
        return ComponentVerdict(
            PRESENT_FAILING,
            "managed_python_tree_modified",
            {
                "ownership": ownership,
                "expected_tree_sha256": receipt.get("tree_sha256"),
                "observed_tree_sha256": identity.tree_sha256,
                "expected_pyc_count": receipt.get("pyc_count"),
                "observed_pyc_count": identity.pyc_count,
            },
        )

    return ComponentVerdict(
        PRESENT_PASSING,
        REASON_VERIFIED,
        {
            "ownership": ownership,
            "pin_id": py_rec.name,
            "tree_sha256": identity.tree_sha256,
            "s5b_tree_sha256": identity.s5b_tree_sha256,
            "pyc_count": identity.pyc_count,
        },
    )


def _probe_module_venv_interpreter(
    python_exe: Path, expected_packages: Mapping[str, Any]
) -> Tuple[bool, str, Dict[str, Any]]:
    env = subprocess_policy.clean_python_env(
        extra_strip=("CUDA_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES")
    )
    env["CUDA_VISIBLE_DEVICES"] = ""
    try:
        with tempfile.TemporaryDirectory(prefix="stemwerk-venv-verify-") as scratch:
            env["NUMBA_CACHE_DIR"] = str(Path(scratch) / "numba")
            completed = subprocess.run(
                subprocess_policy.isolated_python_cmd(python_exe, "-c", _MODULE_VENV_PROBE_SRC),
                capture_output=True,
                text=True,
                timeout=60,
                cwd=scratch,
                env=env,
                check=False,
            )
    except Exception as exc:
        return False, "venv_probe_spawn_failed", {"error": f"{type(exc).__name__}: {exc}"}

    if completed.returncode != 0:
        return (
            False,
            "venv_probe_failed",
            {"stderr": (completed.stderr or completed.stdout)[-500:]},
        )

    try:
        probe_data = json.loads((completed.stdout or "").strip().splitlines()[-1])
    except Exception:
        return False, "venv_probe_malformed", {}

    if (
        not probe_data.get("dont_write_bytecode")
        or probe_data.get("missing")
        or not probe_data.get("separator_ok")
        or probe_data.get("torch_cuda_available") is not False
        or probe_data.get("torch_cuda_version") is not None
        or probe_data.get("torch_hip_version") is not None
        or "CPUExecutionProvider" not in (probe_data.get("onnxruntime_providers") or [])
    ):
        return False, "venv_runtime_validation_failed", {"probe": probe_data}

    installed_versions = probe_data.get("installed_versions") or {}
    for pkg_name, expected_ver in expected_packages.items():
        norm_name = str(pkg_name).lower().replace("_", "-")
        if installed_versions.get(norm_name) != expected_ver:
            return (
                False,
                "venv_package_version_mismatch",
                {
                    "package": pkg_name,
                    "expected": expected_ver,
                    "observed": installed_versions.get(norm_name),
                },
            )
    return True, REASON_VERIFIED, {}


def _verify_module_venv_with_receipt(
    component: ComponentDescriptor, location: ComponentLocation
) -> ComponentVerdict:
    receipt = location.receipt_entry or {}
    ownership = str(receipt.get("ownership") or "unknown")
    label = f"location of {component.component_id}"
    try:
        directory = materialization._absolute_path(location.path, label)
        materialization._reject_symlink_components(directory, label)
    except materialization.MaterializationError as exc:
        if exc.code == "symlink_not_allowed":
            return ComponentVerdict(PRESENT_FAILING, "symlink_not_allowed", {"ownership": ownership})
        return ComponentVerdict(UNVERIFIABLE, "location_invalid", {"ownership": ownership})

    try:
        dir_stat = os.lstat(directory)
    except FileNotFoundError:
        return ComponentVerdict(PRESENT_FAILING, "location_missing", {"ownership": ownership})
    except OSError:
        return ComponentVerdict(UNVERIFIABLE, "location_unreadable", {"ownership": ownership})
    if not stat.S_ISDIR(dir_stat.st_mode):
        return ComponentVerdict(PRESENT_FAILING, "location_not_directory", {"ownership": ownership})

    try:
        lock_manifest = wheel_lock.load_wheel_lock("drum_kit", "linux-x86_64", "cpu")
    except wheel_lock.WheelLockError as exc:
        return ComponentVerdict(UNVERIFIABLE, exc.code, {"ownership": ownership})

    if receipt.get("wheel_lock_sha256") != lock_manifest.manifest_sha256:
        return ComponentVerdict(
            PRESENT_FAILING,
            "wheel_lock_mismatch",
            {"ownership": ownership, "expected": lock_manifest.manifest_sha256, "observed": receipt.get("wheel_lock_sha256")},
        )

    try:
        identity = module_registry.compute_tree_identity(directory)
    except module_registry.RegistryError as exc:
        return ComponentVerdict(PRESENT_FAILING, exc.code, {"ownership": ownership, "detail": str(exc)})
    except OSError as exc:
        return ComponentVerdict(UNVERIFIABLE, "tree_unreadable", {"ownership": ownership, "detail": type(exc).__name__})

    if identity.pyc_count != 0:
        return ComponentVerdict(
            PRESENT_FAILING,
            "module_venv_bytecode_pollution",
            {"ownership": ownership, "pyc_count": identity.pyc_count},
        )

    if (
        identity.tree_sha256 != receipt.get("tree_sha256")
        or identity.entry_count != receipt.get("entry_count")
        or identity.total_bytes != receipt.get("total_bytes")
    ):
        return ComponentVerdict(
            PRESENT_FAILING,
            "module_venv_tree_modified",
            {
                "ownership": ownership,
                "expected_tree_sha256": receipt.get("tree_sha256"),
                "observed_tree_sha256": identity.tree_sha256,
            },
        )

    python_exe = directory / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not python_exe.exists() or not os.access(python_exe, os.X_OK):
        return ComponentVerdict(PRESENT_FAILING, "venv_interpreter_missing", {"ownership": ownership})

    expected_packages = receipt.get("packages") or {}
    probe_ok, probe_reason, probe_details = _probe_module_venv_interpreter(python_exe, expected_packages)
    if not probe_ok:
        return ComponentVerdict(
            PRESENT_FAILING,
            probe_reason,
            {"ownership": ownership, **probe_details},
        )

    return ComponentVerdict(
        PRESENT_PASSING,
        REASON_VERIFIED,
        {
            "ownership": ownership,
            "pin_id": str(receipt.get("pin_id") or ""),
            "wheel_lock_id": str(receipt.get("wheel_lock_id") or ""),
            "tree_sha256": identity.tree_sha256,
            "pyc_count": 0,
        },
    )


def verify_runtime_component(
    component: ComponentDescriptor, location: ComponentLocation
) -> ComponentVerdict:
    """Verify a runtime component (``managed_python`` or ``module_venv``) when
    backed by a validated Core receipt; unreceipted locations remain
    ``unverifiable`` (never implicitly adopted).
    """
    if location.receipt_entry is None:
        return ComponentVerdict(UNVERIFIABLE, REASON_VERIFIER_UNAVAILABLE)
    if component.component_id == "managed_python":
        return _verify_managed_python_with_receipt(component, location)
    if component.component_id == "module_venv":
        return _verify_module_venv_with_receipt(component, location)
    return ComponentVerdict(UNVERIFIABLE, REASON_VERIFIER_UNAVAILABLE)


def verify_s6_runtime_interpreter(python_path: Path) -> Tuple[bool, str]:
    """Verify that an S6 module_venv interpreter under ``<root>/runtimes/<module>/<pin>/``
    matches a valid module receipt and unmodified tree before execution uses it.

    Returns ``(True, "not_s6_managed")`` for paths outside ``<root>/runtimes/<module>/<pin>``.
    """
    try:
        abs_path = Path(os.path.abspath(python_path))
    except OSError as exc:
        return False, f"s6_runtime_unresolvable:{exc}"
    parts = abs_path.parts
    if len(parts) < 6 or parts[-5] != "runtimes":
        return True, "not_s6_managed"
    module_id = parts[-4]
    runtime_root = Path(*parts[:-5])
    try:
        doc = verify_module(module_id, root=runtime_root)
    except Exception as exc:
        return False, f"s6_runtime_unverifiable:{type(exc).__name__}"
    comp = next(
        (c for c in doc.get("components", ()) if c.get("component_id") == "module_venv"),
        None,
    )
    if comp is None or comp.get("class") != PRESENT_PASSING:
        reason = comp.get("reason_code") if isinstance(comp, Mapping) else "missing"
        return False, f"s6_runtime_refused:{doc.get('installation_state')}:{reason}"
    registered_dir = comp.get("location")
    if (
        not registered_dir
        or abs_path.parent.parent != Path(str(registered_dir))
        or (abs_path.parent.name, abs_path.name)
        not in {
            ("bin", "python"),
            ("bin", "python3"),
            ("bin", "python3.12"),
            ("Scripts", "python.exe"),
        }
    ):
        return False, "s6_runtime_refused:interpreter_path_mismatch"
    return True, "verified"


DEFAULT_VERIFIERS: Mapping[str, Verifier] = {
    module_descriptors.KIND_ASSET: verify_asset_component,
    module_descriptors.KIND_RUNTIME: verify_runtime_component,
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


def _default_lookup_for_root(runtime_root: Path, module_id: str) -> ComponentLookup:
    if NoRegistryLookup.locate is not _DEFAULT_NO_REGISTRY_LOCATE:
        return NoRegistryLookup()
    status, receipt, reason = module_registry.read_and_validate_module_record(
        runtime_root, module_id
    )
    if status == "absent":
        return NoRegistryLookup()
    if status == "valid" and receipt is not None:
        return RegistryLookup(runtime_root, receipt)
    return UnverifiableRegistryLookup(reason or "registry_unverifiable")


def verify_descriptor(
    descriptor: ModuleDescriptor,
    *,
    lookup: Optional[ComponentLookup] = None,
    verifiers: Optional[Mapping[str, Verifier]] = None,
    root: Optional[Path] = None,
) -> Dict[str, Any]:
    """Verify ``descriptor`` and return a ``stemwerk_module_verification`` document.

    ``verifiers`` adds to or replaces the default verifiers by component kind.
    ``root`` is where the install lock and registry are read; default ``managed_runtime_root()``.
    """

    if not isinstance(descriptor, ModuleDescriptor):
        raise TypeError("descriptor must be a ModuleDescriptor")
    active_root = managed_runtime.managed_runtime_root() if root is None else Path(root)
    active_lookup = (
        _default_lookup_for_root(active_root, descriptor.module_id)
        if lookup is None
        else lookup
    )
    active_verifiers = {**DEFAULT_VERIFIERS, **(verifiers or {})}
    components: List[Dict[str, Any]] = [
        _classify(descriptor.module_id, component, active_lookup, active_verifiers)
        for component in descriptor.components
    ]
    state, rule = installation_state(entry["class"] for entry in components)
    lock = install_lock.inspect_lock(active_root)
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
        "operation_in_progress": lock.operation_in_progress,
        "operation_id": lock.operation_id,
        "lock_status": lock.lock_status,
        "components": components,
    }


def verify_module(
    module_id: str,
    *,
    lookup: Optional[ComponentLookup] = None,
    verifiers: Optional[Mapping[str, Verifier]] = None,
    root: Optional[Path] = None,
) -> Dict[str, Any]:
    """Verify the module ``module_id``; ``ValueError`` for an unknown module."""

    return verify_descriptor(
        module_descriptors.get_module_descriptor(module_id),
        lookup=lookup,
        verifiers=verifiers,
        root=root,
    )
