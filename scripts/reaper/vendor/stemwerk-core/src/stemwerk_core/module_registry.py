"""Module installation registry, receipt persistence, and tree integrity for S6."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
import time
from typing import Any, Dict, Mapping, Optional, Tuple

from ._install_paths import sync_directory
from . import install_bootstrap
from . import managed_python
from . import model_assets
from . import runtime_manifest
from . import wheel_lock

REGISTRY_SCHEMA_VERSION = 1
RECEIPT_SCHEMA_VERSION = 1
REGISTRY_KIND = "stemwerk_module_registry"
RECEIPT_KIND = "stemwerk_module_receipt"
PUBLICATION_SCHEMA_VERSION = 1
PUBLICATION_KIND = "stemwerk_module_venv_publication"
REGISTRY_RELPATH = Path("state") / "module-registry.v1.json"
DRUMSEP_ASSET_SET_ID = "drumsep-mdx23c-aufr33-jarredou"


class RegistryError(RuntimeError):
    """Structured error raised when registry or receipt state is invalid."""

    def __init__(self, code: str, message: str, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = dict(details)


@dataclass(frozen=True)
class TreeIdentity:
    tree_sha256: str
    entry_count: int
    total_bytes: int
    pyc_count: int
    s5b_tree_sha256: str = ""


def registry_path(runtime_root: Path) -> Path:
    return Path(runtime_root) / REGISTRY_RELPATH


def receipt_relpath(module_id: str) -> Path:
    return Path("state") / "modules" / f"{module_id}.receipt.json"


def receipt_path(runtime_root: Path, module_id: str) -> Path:
    return Path(runtime_root) / receipt_relpath(module_id)


def publication_record_path(runtime_root: Path, module_id: str) -> Path:
    return Path(runtime_root) / "state" / "modules" / f"{module_id}.venv-publication.json"


def expected_drumsep_assets_dir(runtime_root: Path) -> Path:
    """Return ``<root>/assets/drumsep-mdx23c-aufr33-jarredou``."""
    return Path(runtime_root) / "assets" / DRUMSEP_ASSET_SET_ID


def compute_venv_pin_id(python_pin_name: str, wheel_lock_sha256: str) -> str:
    """Return the deterministic short pin identifier used in
    ``<root>/runtimes/<module>/<short-pin-id>/``.
    """
    payload = f"v1\0{python_pin_name}\0{wheel_lock_sha256}".encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest()[:16]
    return f"cpu-py312-{digest}"


def expected_module_venv_dir(
    runtime_root: Path,
    module_id: str = "drum_kit",
    platform_key: str = "linux-x86_64",
    backend: str = "cpu",
) -> Tuple[Path, str, wheel_lock.WheelLockManifest]:
    """Return ``(venv_dir, pin_id, wheel_lock_manifest)`` for the pinned S6 runtime."""
    py_rec = runtime_manifest.python_record(platform_key)
    lock_manifest = wheel_lock.load_wheel_lock(module_id, platform_key, backend)
    pin_id = compute_venv_pin_id(py_rec.name, lock_manifest.manifest_sha256)
    return Path(runtime_root) / "runtimes" / module_id / pin_id, pin_id, lock_manifest


def _raise_walk_error(exc: OSError) -> None:
    raise exc


def compute_tree_identity(root: Path, *, check_safe_modes: bool = True) -> TreeIdentity:
    """Compute a deterministic content, mode, and structure digest for ``root``.

    Hashes every relative path, entry kind (dir, symlink, regular file), exact
    permission bits (``st_mode & 0o777``), symlink target, file size, and full
    SHA-256 content of every regular file. Never follows symlinks. An
    unreadable file or directory raises ``OSError``: it is never skipped.
    """
    root_path = Path(root)
    try:
        root_stat = os.lstat(root_path)
    except OSError as exc:
        raise RegistryError("tree_missing", f"directory is missing: {root_path}: {exc}") from exc
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise RegistryError("tree_not_directory", f"path is not a regular directory: {root_path}")
    enforce_posix_modes = check_safe_modes and os.name != "nt"
    if enforce_posix_modes and (root_stat.st_mode & 0o022):
        raise RegistryError("tree_unsafe_mode", f"directory is group/world-writable: {root_path}")

    resolved_root = root_path.resolve()
    tree_hash = hashlib.sha256()
    tree_hash.update(f"root-mode\0{stat.S_IMODE(root_stat.st_mode):04o}\n".encode("utf-8"))
    s5b_records: list[tuple[tuple[str, ...], bytes]] = []
    entry_count = 0
    total_bytes = 0
    pyc_count = 0

    for current_root, dirnames, filenames in os.walk(
        root_path, topdown=True, followlinks=False, onerror=_raise_walk_error
    ):
        dirnames.sort()
        filenames.sort()
        current_path = Path(current_root)
        for name in [*dirnames, *filenames]:
            entry = current_path / name
            rel_path = entry.relative_to(root_path)
            rel = rel_path.as_posix()
            st = os.lstat(entry)
            mode = stat.S_IMODE(st.st_mode)
            entry_count += 1
            if name.endswith(".pyc") or name.endswith(".pyo"):
                pyc_count += 1

            s5b_prefix = rel.encode("utf-8") + b"\0" + str(mode).encode("utf-8") + b"\0"
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(entry)
                target_path = (entry.parent / target).resolve()
                within_tree = False
                try:
                    target_path.relative_to(resolved_root)
                    within_tree = True
                except ValueError:
                    if (
                        rel_path.parts[0] == "bin"
                        and len(rel_path.parts) == 2
                        and rel_path.parts[1].startswith("python")
                        and (root_path / "pyvenv.cfg").is_file()
                        and len(target_path.parts) >= 5
                        and target_path.parts[-5] == "runtimes"
                        and target_path.parts[-4] == "python"
                        and target_path.parts[-3].startswith(("python-", "cpython-"))
                        and target_path.parts[-2] == "bin"
                        and target_path.parts[-1].startswith("python")
                    ):
                        within_tree = True
                if not within_tree:
                    raise RegistryError(
                        "tree_symlink_escape",
                        f"symlink escapes runtime tree: {rel} -> {target}",
                    )
                tree_hash.update(f"L\0{rel}\0{target}\n".encode("utf-8"))
                s5b_records.append((rel_path.parts, s5b_prefix + b"L" + target.encode("utf-8")))
            elif stat.S_ISDIR(st.st_mode):
                if enforce_posix_modes and (mode & 0o022):
                    raise RegistryError(
                        "tree_unsafe_mode",
                        f"directory in runtime tree is group/world-writable: {rel}",
                    )
                tree_hash.update(f"D\0{rel}\0{mode:04o}\n".encode("utf-8"))
                s5b_records.append((rel_path.parts, s5b_prefix + b"D"))
            elif stat.S_ISREG(st.st_mode):
                if enforce_posix_modes and (mode & 0o022):
                    raise RegistryError(
                        "tree_unsafe_mode",
                        f"file in runtime tree is group/world-writable: {rel}",
                    )
                file_hash = hashlib.sha256()
                with entry.open("rb") as handle:
                    while True:
                        chunk = handle.read(1024 * 1024)
                        if not chunk:
                            break
                        file_hash.update(chunk)
                total_bytes += st.st_size
                tree_hash.update(
                    f"F\0{rel}\0{mode:04o}\0{st.st_size}\0{file_hash.hexdigest()}\n".encode("utf-8")
                )
                s5b_records.append((rel_path.parts, s5b_prefix + b"F" + file_hash.digest()))
            else:
                raise RegistryError(
                    "tree_unsupported_entry",
                    f"unsupported filesystem entry in runtime tree: {rel}",
                )

    s5b_hash = hashlib.sha256()
    for _, payload in sorted(s5b_records, key=lambda item: item[0]):
        s5b_hash.update(payload)

    return TreeIdentity(
        tree_sha256=tree_hash.hexdigest(),
        entry_count=entry_count,
        total_bytes=total_bytes,
        pyc_count=pyc_count,
        s5b_tree_sha256=s5b_hash.hexdigest(),
    )


def _atomic_write_json(target: Path, payload: Mapping[str, Any]) -> bytes:
    target.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    tmp_path = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp_path, target)
    return encoded


def write_publication_record(
    runtime_root: Path,
    module_id: str,
    *,
    operation_id: str,
    module_venv_dir: Path,
    module_venv_pin_id: str,
    identity: TreeIdentity,
) -> Path:
    """Durably record the staged tree identity BEFORE its no-replace rename.

    An interrupted operation may leave the published directory without a
    receipt. This record, not the directory's current content, is what a later
    operation compares against before it may adopt that directory. It outlives
    journal recovery and is removed only after the registry commit.
    """
    path = publication_record_path(runtime_root, module_id)
    _atomic_write_json(
        path,
        {
            "schema_version": PUBLICATION_SCHEMA_VERSION,
            "kind": PUBLICATION_KIND,
            "module_id": module_id,
            "operation_id": operation_id,
            "relpath": Path(module_venv_dir).relative_to(runtime_root).as_posix(),
            "pin_id": module_venv_pin_id,
            "tree_sha256": identity.tree_sha256,
            "entry_count": identity.entry_count,
            "total_bytes": identity.total_bytes,
        },
    )
    sync_directory(path.parent)
    return path


def read_publication_record(
    runtime_root: Path, module_id: str, module_venv_dir: Path
) -> Optional[Mapping[str, Any]]:
    """Return the record only if it is well formed and names this destination."""
    try:
        record = json.loads(
            publication_record_path(runtime_root, module_id).read_text(encoding="utf-8")
        )
        expected_relpath = Path(module_venv_dir).relative_to(runtime_root).as_posix()
    except (OSError, ValueError):
        return None
    if (
        not isinstance(record, Mapping)
        or record.get("schema_version") != PUBLICATION_SCHEMA_VERSION
        or record.get("kind") != PUBLICATION_KIND
        or record.get("module_id") != module_id
        or record.get("relpath") != expected_relpath
        or not isinstance(record.get("tree_sha256"), str)
    ):
        return None
    return record


def matches_publication_record(runtime_root: Path, module_id: str, module_venv_dir: Path) -> bool:
    """True only when the directory is byte-for-byte what was sealed for publication."""
    record = read_publication_record(runtime_root, module_id, module_venv_dir)
    if record is None:
        return False
    try:
        identity = compute_tree_identity(module_venv_dir)
    except (RegistryError, OSError):
        return False
    return (
        identity.tree_sha256 == record["tree_sha256"]
        and identity.entry_count == record.get("entry_count")
        and identity.total_bytes == record.get("total_bytes")
        and identity.pyc_count == 0
    )


def remove_publication_record(runtime_root: Path, module_id: str) -> None:
    publication_record_path(runtime_root, module_id).unlink(missing_ok=True)


def build_s6_receipt(
    runtime_root: Path,
    *,
    module_id: str,
    operation_id: str,
    plan_fingerprint: str,
    platform_key: str,
    backend: str,
    managed_python_dir: Path,
    managed_python_pin_id: str,
    managed_python_archive_sha256: str,
    managed_python_identity: TreeIdentity,
    managed_python_s5b_tree_sha256: str,
    managed_python_ownership: str,
    module_venv_dir: Path,
    module_venv_pin_id: str,
    wheel_lock_id: str,
    wheel_lock_sha256: str,
    module_venv_identity: TreeIdentity,
    installed_packages: Mapping[str, str],
    drumsep_assets_dir: Path,
    drumsep_bundle_id: str,
    drumsep_artifacts: Mapping[str, Mapping[str, Any]],
    drumsep_assets_ownership: str,
    created_at_utc: Optional[str] = None,
) -> Dict[str, Any]:
    """Construct the canonical S6 module receipt payload."""
    root = Path(runtime_root)
    ts = created_at_utc or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return {
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "kind": RECEIPT_KIND,
        "module_id": module_id,
        "operation_id": operation_id,
        "plan_fingerprint": plan_fingerprint,
        "platform_key": platform_key,
        "backend": backend,
        "installed_state": "partial",
        "pending_slices": ["s7_managed_ffmpeg", "s9_activation"],
        "created_at_utc": ts,
        "components": {
            "managed_python": {
                "path": str(managed_python_dir),
                "relpath": managed_python_dir.relative_to(root).as_posix(),
                "pin_id": managed_python_pin_id,
                "archive_sha256": managed_python_archive_sha256,
                "tree_sha256": managed_python_identity.tree_sha256,
                "s5b_tree_sha256": managed_python_s5b_tree_sha256,
                "entry_count": managed_python_identity.entry_count,
                "total_bytes": managed_python_identity.total_bytes,
                "pyc_count": managed_python_identity.pyc_count,
                "ownership": managed_python_ownership,
            },
            "module_venv": {
                "path": str(module_venv_dir),
                "relpath": module_venv_dir.relative_to(root).as_posix(),
                "pin_id": module_venv_pin_id,
                "python_pin_id": managed_python_pin_id,
                "wheel_lock_id": wheel_lock_id,
                "wheel_lock_sha256": wheel_lock_sha256,
                "tree_sha256": module_venv_identity.tree_sha256,
                "entry_count": module_venv_identity.entry_count,
                "total_bytes": module_venv_identity.total_bytes,
                "pyc_count": module_venv_identity.pyc_count,
                "packages": dict(sorted(installed_packages.items())),
                "ownership": "core_managed",
            },
            "drumsep_assets": {
                "path": str(drumsep_assets_dir),
                "relpath": drumsep_assets_dir.relative_to(root).as_posix(),
                "bundle_id": drumsep_bundle_id,
                "artifacts": {k: dict(v) for k, v in sorted(drumsep_artifacts.items())},
                "ownership": drumsep_assets_ownership,
            },
            "ffmpeg": None,
            "reaper_activation": None,
        },
    }


def write_receipt(runtime_root: Path, module_id: str, receipt_payload: Mapping[str, Any]) -> Tuple[Path, str]:
    """Atomically write ``state/modules/<module_id>.receipt.json`` and return ``(path, sha256)``."""
    path = receipt_path(runtime_root, module_id)
    raw_bytes = _atomic_write_json(path, receipt_payload)
    return path, hashlib.sha256(raw_bytes).hexdigest()


def write_registry_from_receipt(
    runtime_root: Path,
    module_id: str,
    receipt_payload: Mapping[str, Any],
    receipt_sha256: str,
    *,
    updated_at_utc: Optional[str] = None,
) -> Path:
    """Atomically update ``state/module-registry.v1.json`` from a written receipt."""
    reg_path = registry_path(runtime_root)
    existing_modules: Dict[str, Any] = {}
    if reg_path.exists():
        try:
            existing = json.loads(reg_path.read_text(encoding="utf-8"))
            if isinstance(existing, Mapping) and isinstance(existing.get("modules"), Mapping):
                existing_modules = dict(existing["modules"])
        except Exception:
            existing_modules = {}

    components = receipt_payload.get("components")
    if not isinstance(components, Mapping):
        raise RegistryError("receipt_invalid", "receipt payload missing components object")

    mp = components.get("managed_python") or {}
    mv = components.get("module_venv") or {}
    da = components.get("drumsep_assets") or {}
    ts = updated_at_utc or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    existing_modules[module_id] = {
        "module_id": module_id,
        "installed_state": str(receipt_payload.get("installed_state") or "partial"),
        "operation_id": str(receipt_payload.get("operation_id") or ""),
        "plan_fingerprint": str(receipt_payload.get("plan_fingerprint") or ""),
        "platform_key": str(receipt_payload.get("platform_key") or ""),
        "backend": str(receipt_payload.get("backend") or ""),
        "receipt_relpath": receipt_relpath(module_id).as_posix(),
        "receipt_sha256": receipt_sha256,
        "updated_at_utc": ts,
        "components": {
            "managed_python": {
                "path": mp.get("path"),
                "relpath": mp.get("relpath"),
                "pin_id": mp.get("pin_id"),
                "tree_sha256": mp.get("tree_sha256"),
                "s5b_tree_sha256": mp.get("s5b_tree_sha256"),
                "ownership": mp.get("ownership"),
            }
            if isinstance(mp, Mapping)
            else None,
            "module_venv": {
                "path": mv.get("path"),
                "relpath": mv.get("relpath"),
                "pin_id": mv.get("pin_id"),
                "wheel_lock_id": mv.get("wheel_lock_id"),
                "wheel_lock_sha256": mv.get("wheel_lock_sha256"),
                "tree_sha256": mv.get("tree_sha256"),
                "ownership": mv.get("ownership"),
            }
            if isinstance(mv, Mapping)
            else None,
            "drumsep_assets": {
                "path": da.get("path"),
                "relpath": da.get("relpath"),
                "bundle_id": da.get("bundle_id"),
                "ownership": da.get("ownership"),
            }
            if isinstance(da, Mapping)
            else None,
            "ffmpeg": components.get("ffmpeg"),
            "reaper_activation": components.get("reaper_activation"),
        },
    }

    registry_payload = {
        "schema_version": REGISTRY_SCHEMA_VERSION,
        "kind": REGISTRY_KIND,
        "updated_at_utc": ts,
        "modules": existing_modules,
    }
    _atomic_write_json(reg_path, registry_payload)
    return reg_path


def _validate_receipt_structure(receipt: Any, module_id: str) -> Mapping[str, Any]:
    if not isinstance(receipt, Mapping):
        raise RegistryError("receipt_invalid", "receipt must be a JSON object")
    if receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION or receipt.get("kind") != RECEIPT_KIND:
        raise RegistryError("receipt_invalid", "unsupported receipt schema_version or kind")
    if receipt.get("module_id") != module_id:
        raise RegistryError("receipt_invalid", f"receipt module_id mismatch: {receipt.get('module_id')!r}")
    components = receipt.get("components")
    if not isinstance(components, Mapping):
        raise RegistryError("receipt_invalid", "receipt missing components mapping")
    for required_comp in ("managed_python", "module_venv", "drumsep_assets"):
        comp = components.get(required_comp)
        if not isinstance(comp, Mapping) or not comp.get("path"):
            raise RegistryError("receipt_invalid", f"receipt component {required_comp} missing or invalid")
    return receipt


def read_and_validate_module_record(
    runtime_root: Path,
    module_id: str,
) -> Tuple[str, Optional[Mapping[str, Any]], Optional[str]]:
    """Inspect ``state/module-registry.v1.json`` and ``state/modules/<module_id>.receipt.json``.

    Returns ``(status, receipt_payload, error_reason)``:
    - ``("absent", None, None)`` when neither registry nor receipt exists for ``module_id``.
    - ``("valid", receipt_payload, None)`` when both exist, parse cleanly, and
      agree on ``receipt_sha256`` and component paths/digests.
    - ``("unverifiable", None, reason)`` when only one exists, either is
      corrupt/unreadable, or they disagree.
    """
    root = Path(runtime_root)
    state_dir = root / "state"
    try:
        st = os.lstat(state_dir)
    except FileNotFoundError:
        return "absent", None, None
    except OSError as exc:
        return "unverifiable", None, f"state_dir_unreadable:{type(exc).__name__}"
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        return "unverifiable", None, "state_dir_not_directory"

    reg_file = registry_path(root)
    rec_file = receipt_path(root, module_id)

    reg_exists = False
    rec_exists = False
    try:
        reg_stat = os.lstat(reg_file)
        if stat.S_ISLNK(reg_stat.st_mode) or not stat.S_ISREG(reg_stat.st_mode):
            return "unverifiable", None, "registry_not_regular_file"
        reg_exists = True
    except FileNotFoundError:
        reg_exists = False
    except OSError as exc:
        return "unverifiable", None, f"registry_unreadable:{type(exc).__name__}"

    try:
        rec_stat = os.lstat(rec_file)
        if stat.S_ISLNK(rec_stat.st_mode) or not stat.S_ISREG(rec_stat.st_mode):
            return "unverifiable", None, "receipt_not_regular_file"
        rec_exists = True
    except FileNotFoundError:
        rec_exists = False
    except OSError as exc:
        return "unverifiable", None, f"receipt_unreadable:{type(exc).__name__}"

    if not reg_exists and not rec_exists:
        return "absent", None, None
    if reg_exists and not rec_exists:
        return "unverifiable", None, "receipt_missing"
    if rec_exists and not reg_exists:
        return "unverifiable", None, "registry_missing"

    try:
        reg_bytes = reg_file.read_bytes()
        reg_data = json.loads(reg_bytes.decode("utf-8"))
    except Exception as exc:
        return "unverifiable", None, f"registry_corrupt:{type(exc).__name__}"

    if (
        not isinstance(reg_data, Mapping)
        or reg_data.get("schema_version") != REGISTRY_SCHEMA_VERSION
        or reg_data.get("kind") != REGISTRY_KIND
        or not isinstance(reg_data.get("modules"), Mapping)
    ):
        return "unverifiable", None, "registry_schema_invalid"

    mod_entry = reg_data["modules"].get(module_id)
    if mod_entry is None:
        return "unverifiable", None, "registry_entry_missing_for_receipt"
    if not isinstance(mod_entry, Mapping):
        return "unverifiable", None, "registry_entry_invalid"

    try:
        rec_bytes = rec_file.read_bytes()
        rec_sha256 = hashlib.sha256(rec_bytes).hexdigest()
        rec_data = json.loads(rec_bytes.decode("utf-8"))
        validated_receipt = _validate_receipt_structure(rec_data, module_id)
    except RegistryError as exc:
        return "unverifiable", None, exc.code
    except Exception as exc:
        return "unverifiable", None, f"receipt_corrupt:{type(exc).__name__}"

    if mod_entry.get("receipt_sha256") != rec_sha256:
        return "unverifiable", None, "registry_receipt_sha256_mismatch"
    if mod_entry.get("operation_id") != validated_receipt.get("operation_id"):
        return "unverifiable", None, "registry_receipt_operation_mismatch"
    if mod_entry.get("plan_fingerprint") != validated_receipt.get("plan_fingerprint"):
        return "unverifiable", None, "registry_receipt_fingerprint_mismatch"

    reg_comps = mod_entry.get("components")
    rec_comps = validated_receipt.get("components")
    if not isinstance(reg_comps, Mapping) or not isinstance(rec_comps, Mapping):
        return "unverifiable", None, "registry_components_invalid"

    for comp_id in ("managed_python", "module_venv", "drumsep_assets"):
        reg_c = reg_comps.get(comp_id)
        rec_c = rec_comps.get(comp_id)
        if not isinstance(reg_c, Mapping) or not isinstance(rec_c, Mapping):
            return "unverifiable", None, f"registry_component_invalid:{comp_id}"
        for key in ("path", "relpath", "ownership"):
            if reg_c.get(key) != rec_c.get(key):
                return "unverifiable", None, f"registry_component_mismatch:{comp_id}:{key}"
        if comp_id in {"managed_python", "module_venv"}:
            if reg_c.get("pin_id") != rec_c.get("pin_id") or reg_c.get("tree_sha256") != rec_c.get("tree_sha256"):
                return "unverifiable", None, f"registry_component_mismatch:{comp_id}:digest"

    return "valid", validated_receipt, None
