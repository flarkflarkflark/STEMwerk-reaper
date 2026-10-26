"""Offline, copy-only materialization of Core-pinned DrumSep assets.

This module does not discover sources, download content, provision runtimes,
or infer work from an installation preview. Callers must provide the complete
local source set and a new absolute destination.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from typing import Any, Callable, Mapping, Sequence
import uuid

from . import model_assets


SCHEMA_VERSION = "1.0.0"
RECEIPT_FILENAME = "stemwerk-materialization-receipt.v1.json"
PRODUCTION_POLICY_ID = (
    "stemwerk_core.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256"
)
_MACOS_RENAME_EXCL = 0x00000004
_WINDOWS_DESTINATION_EXISTS = {80, 183}
_WINDOWS_PUBLICATION_UNSUPPORTED = {1, 17, 50, 120}
_WINDOWS_SHARING_VIOLATION = 32


class MaterializationError(Exception):
    """A bounded validation, copy, publication, or cleanup failure."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        cleanup_remaining: Sequence[str] = (),
        published: bool | None = False,
        destination: str | None = None,
        receipt_path: str | None = None,
        operation_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.cleanup_remaining = tuple(cleanup_remaining)
        self.published = published
        self.destination = destination
        self.receipt_path = receipt_path
        self.operation_id = operation_id


@dataclass(frozen=True)
class MaterializationRequest:
    """Explicit local sources and a new destination directory."""

    sources: Mapping[str, os.PathLike[str] | str]
    destination: Path


@dataclass(frozen=True)
class _TrustedAssetPolicy:
    """Trusted specifications supplied by Core, or injected by focused tests."""

    policy_id: str
    assets: tuple[tuple[str, str], ...]

    def __post_init__(self) -> None:
        if not self.policy_id or not isinstance(self.policy_id, str):
            raise ValueError("policy_id must be a non-empty string")
        if not self.assets:
            raise ValueError("trusted policy must contain assets")
        names: set[str] = set()
        for name, expected in self.assets:
            if (
                not isinstance(name, str)
                or not name
                or Path(name).name != name
                or name in {".", "..", RECEIPT_FILENAME}
                or name in names
            ):
                raise ValueError("trusted policy contains an invalid asset name")
            if (
                not isinstance(expected, str)
                or len(expected) != 64
                or any(char not in "0123456789abcdefABCDEF" for char in expected)
            ):
                raise ValueError("trusted policy contains an invalid SHA-256")
            names.add(name)

    @property
    def fingerprint(self) -> str:
        payload = {
            "policy_id": self.policy_id,
            "assets": [
                {"name": name, "sha256": expected.lower()}
                for name, expected in self.assets
            ],
        }
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class _ValidatedSource:
    name: str
    path: Path
    sha256: str
    device: int
    inode: int
    size: int


@dataclass(frozen=True)
class _ValidatedRequest:
    destination: Path
    parent_device: int
    parent_inode: int
    sources: tuple[_ValidatedSource, ...]
    policy: _TrustedAssetPolicy


@dataclass(frozen=True)
class _ValidatedDestination:
    path: Path
    parent_device: int
    parent_inode: int


def _production_policy() -> _TrustedAssetPolicy:
    return _TrustedAssetPolicy(
        policy_id=PRODUCTION_POLICY_ID,
        assets=tuple(
            (name, expected)
            for name, expected in model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256.items()
        ),
    )


def _binary_flag() -> int:
    """Windows opens descriptors in text mode unless O_BINARY is requested."""

    return getattr(os, "O_BINARY", 0)


def _absolute_path(value: Any, label: str) -> Path:
    if not isinstance(value, (str, os.PathLike)) or not str(value):
        raise MaterializationError("invalid_path", f"{label} must be a path")
    try:
        path = Path(value)
    except (TypeError, ValueError, OSError) as exc:
        raise MaterializationError("invalid_path", f"{label} is invalid") from exc
    if "\x00" in str(path):
        raise MaterializationError("invalid_path", f"{label} is invalid")
    if not path.is_absolute() or ".." in path.parts:
        raise MaterializationError(
            "invalid_path", f"{label} must be absolute and contain no '..' segment"
        )
    return path


def _is_reparse_point(path_stat: os.stat_result) -> bool:
    """Return whether a Windows stat result identifies a reparse point."""

    attributes = getattr(path_stat, "st_file_attributes", 0)
    reparse_attribute = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & reparse_attribute)


def _is_link_or_reparse(path_stat: os.stat_result) -> bool:
    return stat.S_ISLNK(path_stat.st_mode) or _is_reparse_point(path_stat)


def _reject_symlink_components(path: Path, label: str) -> None:
    components = [path, *path.parents]
    for component in reversed(components):
        try:
            component_stat = os.lstat(component)
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise MaterializationError(
                "path_unreadable", f"cannot inspect {label}: {exc}"
            ) from exc
        if _is_link_or_reparse(component_stat):
            raise MaterializationError(
                "symlink_not_allowed",
                f"{label} contains a symbolic link or reparse point",
            )


def _hash_open_file(handle: int) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = os.read(handle, 1024 * 1024)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def _validate_source(name: str, value: Any, expected: str) -> _ValidatedSource:
    path = _absolute_path(value, f"source for {name}")
    _reject_symlink_components(path, f"source for {name}")
    flags = (
        os.O_RDONLY
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        handle = os.open(path, flags)
    except FileNotFoundError as exc:
        raise MaterializationError(
            "source_missing", f"source for {name} does not exist"
        ) from exc
    except OSError as exc:
        raise MaterializationError(
            "source_unreadable", f"source for {name} cannot be opened: {exc}"
        ) from exc
    try:
        source_stat = os.fstat(handle)
        if not stat.S_ISREG(source_stat.st_mode):
            raise MaterializationError(
                "source_not_regular", f"source for {name} is not a regular file"
            )
        actual = _hash_open_file(handle)
    except OSError as exc:
        raise MaterializationError(
            "source_unreadable", f"source for {name} cannot be read: {exc}"
        ) from exc
    finally:
        os.close(handle)
    if actual.lower() != expected.lower():
        raise MaterializationError(
            "source_integrity_mismatch", f"source for {name} does not match Core's pin"
        )
    return _ValidatedSource(
        name=name,
        path=path,
        sha256=actual.lower(),
        device=source_stat.st_dev,
        inode=source_stat.st_ino,
        size=source_stat.st_size,
    )


def _validate_asset_set(
    request: MaterializationRequest, policy: _TrustedAssetPolicy
) -> _ValidatedRequest:
    if not isinstance(request, MaterializationRequest):
        raise MaterializationError(
            "invalid_request", "request must be a MaterializationRequest"
        )
    if not isinstance(request.sources, Mapping):
        raise MaterializationError("invalid_request", "sources must be a mapping")
    expected_names = [name for name, _ in policy.assets]
    if set(request.sources) != set(expected_names) or any(
        not isinstance(name, str) for name in request.sources
    ):
        raise MaterializationError(
            "incomplete_asset_set",
            "sources must provide the complete trusted asset set exactly once",
        )
    destination = _absolute_path(request.destination, "destination")
    for name in expected_names:
        source_path = _absolute_path(request.sources[name], f"source for {name}")
        if source_path == destination or destination in source_path.parents:
            raise MaterializationError(
                "source_destination_alias",
                "an asset source aliases or is contained by the destination",
            )
    validated_destination = _validate_destination(destination)
    sources = tuple(
        _validate_source(name, request.sources[name], expected)
        for name, expected in policy.assets
    )
    identities = {(source.device, source.inode) for source in sources}
    if len(identities) != len(sources):
        raise MaterializationError(
            "source_conflict", "asset sources must be distinct regular files"
        )
    for source in sources:
        if source.path == destination or destination in source.path.parents:
            raise MaterializationError(
                "source_destination_alias",
                "an asset source aliases or is contained by the destination",
            )
    return _ValidatedRequest(
        destination=destination,
        parent_device=validated_destination.parent_device,
        parent_inode=validated_destination.parent_inode,
        sources=sources,
        policy=policy,
    )


def _validate_destination(value: Any) -> _ValidatedDestination:
    destination = _absolute_path(value, "destination")
    _reject_symlink_components(destination.parent, "destination parent")
    try:
        parent_stat = os.stat(destination.parent, follow_symlinks=False)
    except FileNotFoundError as exc:
        raise MaterializationError(
            "destination_parent_missing", "destination parent does not exist"
        ) from exc
    except OSError as exc:
        raise MaterializationError(
            "destination_ineligible", f"cannot inspect destination parent: {exc}"
        ) from exc
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise MaterializationError(
            "destination_ineligible", "destination parent is not a directory"
        )
    if hasattr(os, "geteuid"):
        if parent_stat.st_uid != os.geteuid():
            raise MaterializationError(
                "destination_ineligible", "destination parent is not owned by this user"
            )
        if parent_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise MaterializationError(
                "destination_ineligible",
                "destination parent must not be group- or world-writable",
            )
    try:
        os.lstat(destination)
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise MaterializationError(
            "destination_ineligible", f"cannot inspect destination: {exc}"
        ) from exc
    else:
        raise MaterializationError(
            "destination_exists", "destination already contains filesystem content"
        )

    return _ValidatedDestination(
        path=destination,
        parent_device=parent_stat.st_dev,
        parent_inode=parent_stat.st_ino,
    )


def validate_drumsep_materialization(request: MaterializationRequest) -> dict[str, Any]:
    """Validate the production DrumSep request without creating content."""

    validated = _validate_asset_set(request, _production_policy())
    return {
        "kind": "stemwerk_asset_materialization_validation",
        "schema_version": SCHEMA_VERSION,
        "outcome": "validated",
        "destination": str(validated.destination),
        "policy": {
            "policy_id": validated.policy.policy_id,
            "policy_sha256": validated.policy.fingerprint,
        },
        "artifacts": [
            {"name": source.name, "sha256": source.sha256}
            for source in validated.sources
        ],
    }


def preflight_drumsep_materialization(destination: Path) -> dict[str, Any]:
    """Validate publication support and a new destination without source I/O."""

    publication_platform = _publication_platform()
    validated = _validate_destination(destination)
    return {
        "kind": "stemwerk_asset_materialization_preflight",
        "schema_version": SCHEMA_VERSION,
        "outcome": "validated",
        "destination": str(validated.path),
        "publication_platform": publication_platform,
    }


@dataclass(frozen=True)
class _OwnedPath:
    path: Path
    device: int
    inode: int
    is_directory: bool


def _set_interruption_context(
    exc: BaseException,
    *,
    cleanup_remaining: Sequence[str],
    published: bool | None,
    destination: Path,
    receipt_path: Path | None,
    operation_id: str | None,
) -> None:
    """Attach recovery facts without replacing a cancellation exception."""

    exc.cleanup_remaining = tuple(cleanup_remaining)  # type: ignore[attr-defined]
    exc.published = published  # type: ignore[attr-defined]
    exc.destination = str(destination)  # type: ignore[attr-defined]
    exc.receipt_path = (  # type: ignore[attr-defined]
        str(receipt_path) if receipt_path is not None else None
    )
    exc.operation_id = operation_id  # type: ignore[attr-defined]
    if hasattr(exc, "add_note"):
        exc.add_note(
            "STEMwerk materialization state: "
            f"published={published}, destination={destination}, "
            f"receipt_path={receipt_path}, "
            f"operation_id={operation_id}, "
            f"cleanup_remaining={list(cleanup_remaining)}"
        )


def _open_lock(validated: _ValidatedRequest, operation_id: str) -> tuple[int, _OwnedPath]:
    lock_path = validated.destination.parent / (
        f".{validated.destination.name}.stemwerk-materialize.lock"
    )
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        handle = os.open(lock_path, flags, 0o600)
    except FileExistsError as exc:
        raise MaterializationError(
            "publication_conflict", "another materialization owns the destination lock"
        ) from exc
    except OSError as exc:
        raise MaterializationError(
            "destination_ineligible", f"cannot create destination lock: {exc}"
        ) from exc
    lock_stat = os.fstat(handle)
    owned = _OwnedPath(
        lock_path, lock_stat.st_dev, lock_stat.st_ino, is_directory=False
    )
    try:
        os.write(handle, (operation_id + "\n").encode("ascii"))
    except BaseException as exc:
        try:
            os.close(handle)
        except OSError:
            pass
        remaining = _cleanup_owned(owned)
        _set_interruption_context(
            exc,
            cleanup_remaining=remaining,
            published=False,
            destination=validated.destination,
            receipt_path=None,
            operation_id=operation_id,
        )
        raise
    return handle, owned


def _create_staging(validated: _ValidatedRequest) -> _OwnedPath:
    try:
        path = Path(
            tempfile.mkdtemp(
                prefix=f".{validated.destination.name}.stemwerk-stage-",
                dir=validated.destination.parent,
            )
        )
    except OSError as exc:
        raise MaterializationError(
            "staging_failed",
            f"cannot create owned staging directory: {exc}",
        ) from exc
    try:
        stage_stat = os.lstat(path)
    except OSError as exc:
        raise MaterializationError(
            "staging_failed",
            f"cannot identify owned staging directory: {exc}",
            cleanup_remaining=(str(path),),
        ) from exc
    return _OwnedPath(path, stage_stat.st_dev, stage_stat.st_ino, is_directory=True)


def _cleanup_owned(owned: _OwnedPath | None) -> list[str]:
    if owned is None:
        return []
    try:
        current = os.lstat(owned.path)
    except FileNotFoundError:
        return []
    except OSError:
        return [str(owned.path)]
    if not (
        current.st_dev == owned.device
        and current.st_ino == owned.inode
        and stat.S_ISDIR(current.st_mode) == owned.is_directory
        and stat.S_ISREG(current.st_mode) != owned.is_directory
        and not _is_link_or_reparse(current)
    ):
        return [str(owned.path)]
    try:
        if owned.is_directory:
            shutil.rmtree(owned.path)
        else:
            owned.path.unlink()
    except OSError:
        return [str(owned.path)]
    return []


def _copy_validated_source(source: _ValidatedSource, target: Path) -> None:
    source_flags = (
        os.O_RDONLY
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    target_flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
    )
    source_handle = os.open(source.path, source_flags)
    try:
        current = os.fstat(source_handle)
        if (
            current.st_dev != source.device
            or current.st_ino != source.inode
            or current.st_size != source.size
            or not stat.S_ISREG(current.st_mode)
        ):
            raise MaterializationError(
                "source_changed", f"source for {source.name} changed after validation"
            )
        target_handle = os.open(target, target_flags, 0o600)
        try:
            while True:
                chunk = os.read(source_handle, 1024 * 1024)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(target_handle, view)
                    if written <= 0:
                        raise OSError("copy made no progress")
                    view = view[written:]
            os.fsync(target_handle)
        finally:
            os.close(target_handle)
    finally:
        os.close(source_handle)


def _receipt(
    validated: _ValidatedRequest, operation_id: str
) -> dict[str, Any]:
    artifact_names = [source.name for source in validated.sources]
    return {
        "kind": "stemwerk_asset_materialization_receipt",
        "schema_version": SCHEMA_VERSION,
        "operation": {
            "operation_id": operation_id,
            "operation_type": "offline_materialize_pinned_asset_set",
            "destination": str(validated.destination),
        },
        "policy": {
            "policy_id": validated.policy.policy_id,
            "policy_sha256": validated.policy.fingerprint,
        },
        "artifacts": [
            {"name": source.name, "sha256": source.sha256}
            for source in validated.sources
        ],
        "created": [*artifact_names, RECEIPT_FILENAME],
        "verification": {
            "outcome": "sha256_verified",
            "verified_artifacts": artifact_names,
        },
        "limits": {
            "signed": False,
            "source_licensing_established": False,
            "parent_directory_authority": False,
            "future_mutation_authority": False,
            "runtime_readiness_established": False,
            "complete_module_installation": False,
        },
    }


def _write_receipt(path: Path, receipt: Mapping[str, Any]) -> None:
    payload = (
        json.dumps(receipt, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
    )
    handle = os.open(path, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(handle, view)
            if written <= 0:
                raise OSError("receipt write made no progress")
            view = view[written:]
        os.fsync(handle)
    finally:
        os.close(handle)


def _verify_staging(
    staging: Path, validated: _ValidatedRequest, expected_receipt: Mapping[str, Any]
) -> None:
    expected_names = {source.name for source in validated.sources} | {RECEIPT_FILENAME}
    actual_names = {entry.name for entry in staging.iterdir()}
    if actual_names != expected_names:
        raise MaterializationError(
            "staging_incomplete", "staging does not contain exactly the complete asset set"
        )
    for source in validated.sources:
        target = staging / source.name
        target_stat = os.lstat(target)
        if not stat.S_ISREG(target_stat.st_mode):
            raise MaterializationError(
                "staging_incomplete", f"staged asset {source.name} is not a regular file"
            )
        if model_assets.file_sha256(target) != source.sha256:
            raise MaterializationError(
                "staged_integrity_mismatch",
                f"staged asset {source.name} failed SHA-256 verification",
            )
    receipt_path = staging / RECEIPT_FILENAME
    try:
        stored_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise MaterializationError(
            "receipt_verification_failed", f"staged receipt cannot be verified: {exc}"
        ) from exc
    if stored_receipt != expected_receipt:
        raise MaterializationError(
            "receipt_verification_failed", "staged receipt content is inconsistent"
        )


def _parent_still_matches(validated: _ValidatedRequest) -> None:
    current = os.stat(validated.destination.parent, follow_symlinks=False)
    if (
        current.st_dev != validated.parent_device
        or current.st_ino != validated.parent_inode
        or not stat.S_ISDIR(current.st_mode)
        or _is_link_or_reparse(current)
    ):
        raise MaterializationError(
            "destination_changed", "destination parent changed after validation"
        )


def _publication_status(
    validated: _ValidatedRequest, staging: _OwnedPath | None
) -> bool | None:
    """Identify a completed rename by the staging directory's identity."""

    if staging is None:
        return False
    try:
        destination_stat = os.lstat(validated.destination)
    except FileNotFoundError:
        return False
    except OSError:
        return None
    return (
        stat.S_ISDIR(destination_stat.st_mode)
        and not _is_link_or_reparse(destination_stat)
        and destination_stat.st_dev == staging.device
        and destination_stat.st_ino == staging.inode
    )


def _linux_renameat2():
    """Return the Linux no-replace publication syscall or fail explicitly."""

    if not sys.platform.startswith("linux"):
        raise MaterializationError(
            "publication_unsupported",
            "Linux renameat2 publication is unavailable on this platform",
        )
    try:
        renameat2 = ctypes.CDLL(None, use_errno=True).renameat2
    except AttributeError as exc:
        raise MaterializationError(
            "publication_unsupported", "the platform does not expose renameat2"
        ) from exc
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    return renameat2


def _macos_renamex_np():
    """Return the macOS exclusive-rename function or fail explicitly."""

    if sys.platform != "darwin":
        raise MaterializationError(
            "publication_unsupported",
            "macOS exclusive directory publication is unavailable on this platform",
        )
    try:
        renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
    except AttributeError as exc:
        raise MaterializationError(
            "publication_unsupported", "macOS does not expose renamex_np"
        ) from exc
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    return renamex_np


def _windows_move_file_ex():
    """Return the Windows Unicode directory-move function or fail explicitly."""

    if sys.platform != "win32":
        raise MaterializationError(
            "publication_unsupported",
            "Windows no-replace directory publication is unavailable on this platform",
        )
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        move_file_ex = kernel32.MoveFileExW
    except (AttributeError, OSError) as exc:
        raise MaterializationError(
            "publication_unsupported", "Windows does not expose MoveFileExW"
        ) from exc
    move_file_ex.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
    move_file_ex.restype = ctypes.c_int
    return move_file_ex


def _publication_platform() -> str:
    """Check native API availability without claiming filesystem support."""

    if sys.platform.startswith("linux"):
        _linux_renameat2()
        return "linux_renameat2_noreplace"
    if sys.platform == "darwin":
        _macos_renamex_np()
        return "macos_renamex_np_exclusive"
    if sys.platform == "win32":
        _windows_move_file_ex()
        return "windows_movefileexw_noreplace"
    raise MaterializationError(
        "publication_unsupported",
        "atomic no-replace directory publication is unsupported on this platform",
    )


def _publication_context(
    operation: str, code: str, staging: Path, destination: Path
) -> str:
    return f"{operation} failed with {code}: staging={staging}, destination={destination}"


def _raise_posix_publication_error(
    error: int, operation: str, staging: Path, destination: Path
) -> None:
    name = errno.errorcode.get(error, "UNKNOWN")
    context = _publication_context(
        operation, f"{name} ({error}: {os.strerror(error)})", staging, destination
    )
    if error in {errno.EEXIST, errno.ENOTEMPTY}:
        raise MaterializationError(
            "publication_conflict",
            f"destination appeared before publication; {context}",
        )
    if error in {
        errno.ENOSYS,
        errno.EINVAL,
        errno.EOPNOTSUPP,
        getattr(errno, "ENOTSUP", errno.EOPNOTSUPP),
        errno.EXDEV,
    }:
        raise MaterializationError(
            "publication_unsupported",
            "filesystem does not support same-filesystem atomic no-replace "
            f"directory publication; {context}",
        )
    raise MaterializationError(
        "publication_failed", f"atomic destination publication failed; {context}"
    )


def _publish_linux_noreplace(
    staging: Path, destination: Path, *, renameat2=None, get_errno=None
) -> None:
    renameat2 = renameat2 or _linux_renameat2()
    get_errno = get_errno or ctypes.get_errno

    result = renameat2(
        -100,
        os.fsencode(staging),
        -100,
        os.fsencode(destination),
        1,
    )
    if result == 0:
        return
    _raise_posix_publication_error(
        get_errno(), "renameat2(RENAME_NOREPLACE)", staging, destination
    )


def _publish_macos_noreplace(
    staging: Path, destination: Path, *, renamex_np=None, get_errno=None
) -> None:
    renamex_np = renamex_np or _macos_renamex_np()
    get_errno = get_errno or ctypes.get_errno
    # RENAME_EXCL from Apple's <sys/stdio.h>.
    result = renamex_np(
        os.fsencode(staging), os.fsencode(destination), _MACOS_RENAME_EXCL
    )
    if result == 0:
        return
    _raise_posix_publication_error(
        get_errno(), "renamex_np(RENAME_EXCL)", staging, destination
    )


def _publish_windows_noreplace(
    staging: Path,
    destination: Path,
    *,
    move_file_ex=None,
    get_last_error=None,
) -> None:
    move_file_ex = move_file_ex or _windows_move_file_ex()
    # No flags: no replacement, cross-volume copy, delayed move, or hard link.
    if move_file_ex(str(staging), str(destination), 0):
        return
    get_last_error = get_last_error or ctypes.get_last_error
    error = get_last_error()
    context = _publication_context(
        "MoveFileExW(flags=0)", f"GetLastError={error}", staging, destination
    )
    # ERROR_FILE_EXISTS and ERROR_ALREADY_EXISTS.
    if error in _WINDOWS_DESTINATION_EXISTS:
        raise MaterializationError(
            "publication_conflict",
            f"destination appeared before publication; {context}",
        )
    try:
        os.lstat(destination)
    except OSError:
        pass
    else:
        # Some Windows filesystems report an existing directory as access
        # denied instead of ERROR_ALREADY_EXISTS. The failed native call and
        # observed destination still establish a no-replace collision.
        raise MaterializationError(
            "publication_conflict",
            f"destination appeared before publication; {context}",
        )
    # ERROR_INVALID_FUNCTION, ERROR_NOT_SAME_DEVICE, ERROR_NOT_SUPPORTED, and
    # ERROR_CALL_NOT_IMPLEMENTED.
    if error in _WINDOWS_PUBLICATION_UNSUPPORTED:
        raise MaterializationError(
            "publication_unsupported",
            "filesystem does not support same-filesystem atomic no-replace "
            f"directory publication; {context}",
        )
    if error == _WINDOWS_SHARING_VIOLATION:
        raise MaterializationError(
            "publication_failed",
            "atomic destination publication failed: another process holds a "
            f"handle on the staging directory (ERROR_SHARING_VIOLATION); {context}",
        )
    raise MaterializationError(
        "publication_failed", f"atomic destination publication failed; {context}"
    )


def _publish_noreplace(staging: Path, destination: Path) -> None:
    """Publish a directory with the platform's native no-replace rename."""

    if sys.platform.startswith("linux"):
        _publish_linux_noreplace(staging, destination)
        return
    if sys.platform == "darwin":
        _publish_macos_noreplace(staging, destination)
        return
    if sys.platform == "win32":
        _publish_windows_noreplace(staging, destination)
        return
    raise MaterializationError(
        "publication_unsupported",
        "atomic no-replace directory publication is unsupported on this platform",
    )


def _materialize_asset_set(
    request: MaterializationRequest,
    policy: _TrustedAssetPolicy,
    *,
    copy_file: Callable[[_ValidatedSource, Path], None] | None = None,
    publish: Callable[[Path, Path], None] | None = None,
) -> dict[str, Any]:
    validated = _validate_asset_set(request, policy)
    copy_file = copy_file or _copy_validated_source
    publish = publish or _publish_noreplace
    operation_id = str(uuid.uuid4())
    lock_handle: int | None = None
    lock: _OwnedPath | None = None
    staging: _OwnedPath | None = None
    published = False
    receipt: dict[str, Any] | None = None
    cleanup_remaining: list[str] = []
    try:
        lock_handle, lock = _open_lock(validated, operation_id)
        os.close(lock_handle)
        lock_handle = None
        staging = _create_staging(validated)
        for source in validated.sources:
            copy_file(source, staging.path / source.name)
        receipt = _receipt(validated, operation_id)
        _write_receipt(staging.path / RECEIPT_FILENAME, receipt)
        _verify_staging(staging.path, validated, receipt)
        _parent_still_matches(validated)
        publish(staging.path, validated.destination)
        published = True
        staging = None
        cleanup_remaining = _cleanup_owned(lock)
        if not cleanup_remaining:
            lock = None
    except MaterializationError as exc:
        observed = True if published or exc.published is True else _publication_status(
            validated, staging
        )
        published = observed
        if published is True:
            staging = None
        remaining = [
            *exc.cleanup_remaining,
            *_cleanup_owned(staging),
            *_cleanup_owned(lock),
        ]
        exc.cleanup_remaining = tuple(dict.fromkeys(remaining))
        exc.published = published
        exc.destination = str(validated.destination)
        exc.receipt_path = (
            str(validated.destination / RECEIPT_FILENAME)
            if published is not False
            else None
        )
        exc.operation_id = operation_id
        raise
    except Exception as exc:
        observed = True if published else _publication_status(validated, staging)
        published = observed
        if published is True:
            staging = None
        remaining = [
            *getattr(exc, "cleanup_remaining", ()),
            *_cleanup_owned(staging),
            *_cleanup_owned(lock),
        ]
        raise MaterializationError(
            "materialization_failed",
            f"asset materialization failed: {type(exc).__name__}: {exc}",
            cleanup_remaining=tuple(dict.fromkeys(remaining)),
            published=published,
            destination=str(validated.destination),
            receipt_path=(
                str(validated.destination / RECEIPT_FILENAME)
                if published is not False
                else None
            ),
            operation_id=operation_id,
        ) from exc
    except BaseException as exc:
        observed = (
            True
            if published or getattr(exc, "published", False) is True
            else _publication_status(validated, staging)
        )
        published = observed
        if published is True:
            staging = None
        remaining = [
            *getattr(exc, "cleanup_remaining", ()),
            *_cleanup_owned(staging),
            *_cleanup_owned(lock),
        ]
        receipt_path = (
            validated.destination / RECEIPT_FILENAME
            if published is not False
            else None
        )
        _set_interruption_context(
            exc,
            cleanup_remaining=tuple(dict.fromkeys(remaining)),
            published=published,
            destination=validated.destination,
            receipt_path=receipt_path,
            operation_id=operation_id,
        )
        raise
    finally:
        if lock_handle is not None:
            os.close(lock_handle)

    return {
        "kind": "stemwerk_asset_materialization_result",
        "schema_version": SCHEMA_VERSION,
        "outcome": "success",
        "destination": str(validated.destination),
        "receipt_path": str(validated.destination / RECEIPT_FILENAME),
        "receipt": receipt,
        "cleanup": {
            "complete": not cleanup_remaining,
            "remaining_paths": cleanup_remaining,
        },
    }


def materialize_drumsep_assets(request: MaterializationRequest) -> dict[str, Any]:
    """Validate, copy, verify, and publish Core's pinned DrumSep asset set."""

    return _materialize_asset_set(request, _production_policy())


def _error_document(exc: MaterializationError) -> dict[str, Any]:
    return {
        "kind": "stemwerk_asset_materialization_error",
        "schema_version": SCHEMA_VERSION,
        "error": {
            "code": exc.code,
            "message": str(exc),
            "published": exc.published,
            "destination": exc.destination,
            "receipt_path": exc.receipt_path,
            "cleanup_remaining": list(exc.cleanup_remaining),
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint-source", required=True)
    parser.add_argument("--config-source", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args(argv)
    request = MaterializationRequest(
        sources={
            model_assets.DIRECT_DKS_MODEL_FILENAME: Path(args.checkpoint_source),
            model_assets.DIRECT_DKS_MODEL_YAML: Path(args.config_source),
        },
        destination=Path(args.destination),
    )
    try:
        result = materialize_drumsep_assets(request)
    except MaterializationError as exc:
        print(
            json.dumps(
                _error_document(exc),
                sort_keys=True,
                ensure_ascii=False,
                allow_nan=False,
            ),
            file=sys.stderr,
        )
        return 2
    print(
        json.dumps(
            result,
            indent=2 if args.pretty else None,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
            separators=None if args.pretty else (",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
