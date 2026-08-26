#!/usr/bin/env python3
"""Fail-closed hygiene checks for STEMwerk macOS release inputs."""

from __future__ import annotations

import zipfile
import zlib
from pathlib import Path, PurePosixPath


WHEEL_PYCACHE_REASON = "macos_wheel_pycache_entry"
WHEEL_PYC_REASON = "macos_wheel_pyc_entry"
WHEEL_PYO_REASON = "macos_wheel_pyo_entry"
WHEEL_CORRUPT_REASON = "macos_wheel_corrupt_zip"
WHEEL_UNREADABLE_REASON = "macos_wheel_unreadable_zip"

SOURCE_BUILD_REASON = "macos_stemwerk_core_build_dir"
SOURCE_DIST_REASON = "macos_stemwerk_core_dist_dir"
SOURCE_EGG_INFO_REASON = "macos_stemwerk_core_egg_info"
SOURCE_PYCACHE_REASON = "macos_stemwerk_core_pycache"
SOURCE_PYC_REASON = "macos_stemwerk_core_pyc"
SOURCE_PYO_REASON = "macos_stemwerk_core_pyo"


class MacOSReleaseHygieneError(RuntimeError):
    """A release input contains a forbidden or unreadable artifact."""

    def __init__(self, reason: str, *, artifact: Path, entry: str, detail: str = "") -> None:
        self.reason = reason
        self.artifact = artifact
        self.entry = entry
        self.detail = detail
        message = f"reason={reason} artifact={artifact} entry={entry}"
        if detail:
            message += f" detail={detail}"
        super().__init__(message)


def _wheel_entry_reason(entry: str) -> str | None:
    normalized = entry.replace("\\", "/")
    path = PurePosixPath(normalized)
    if "__pycache__" in path.parts:
        return WHEEL_PYCACHE_REASON
    suffix = path.suffix.lower()
    if suffix == ".pyc":
        return WHEEL_PYC_REASON
    if suffix == ".pyo":
        return WHEEL_PYO_REASON
    return None


def validate_macos_release_wheel(wheel: Path) -> int:
    """Open and fully CRC-check one wheel, rejecting Python build byproducts."""
    try:
        with zipfile.ZipFile(wheel) as archive:
            entries = archive.infolist()
            for info in entries:
                reason = _wheel_entry_reason(info.filename)
                if reason:
                    raise MacOSReleaseHygieneError(
                        reason, artifact=wheel, entry=info.filename
                    )
            try:
                corrupt_entry = archive.testzip()
            except (EOFError, RuntimeError, OSError, zlib.error, zipfile.BadZipFile, NotImplementedError) as exc:
                raise MacOSReleaseHygieneError(
                    WHEEL_CORRUPT_REASON,
                    artifact=wheel,
                    entry="<archive>",
                    detail=str(exc),
                ) from exc
            if corrupt_entry is not None:
                raise MacOSReleaseHygieneError(
                    WHEEL_CORRUPT_REASON, artifact=wheel, entry=corrupt_entry
                )
    except MacOSReleaseHygieneError:
        raise
    except (OSError, zipfile.BadZipFile) as exc:
        raise MacOSReleaseHygieneError(
            WHEEL_UNREADABLE_REASON,
            artifact=wheel,
            entry="<archive>",
            detail=str(exc),
        ) from exc
    return len(entries)


def validate_macos_release_wheelhouse(wheels_dir: Path) -> dict[str, int]:
    """Validate every wheel in a release wheelhouse using the shared policy."""
    return {
        wheel.relative_to(wheels_dir).as_posix(): validate_macos_release_wheel(wheel)
        for wheel in sorted(wheels_dir.rglob("*.whl"))
    }


def _source_violation_reason(relative: Path) -> str | None:
    parts = relative.parts
    if "build" in parts:
        return SOURCE_BUILD_REASON
    if "dist" in parts:
        return SOURCE_DIST_REASON
    if any(part.endswith(".egg-info") for part in parts):
        return SOURCE_EGG_INFO_REASON
    if "__pycache__" in parts:
        return SOURCE_PYCACHE_REASON
    suffix = relative.suffix.lower()
    if suffix == ".pyc":
        return SOURCE_PYC_REASON
    if suffix == ".pyo":
        return SOURCE_PYO_REASON
    return None


def validate_stemwerk_core_source_tree(
    source_root: Path, *, release_mode: bool
) -> tuple[tuple[str, str], ...]:
    """Reject dirty local wheel inputs in release mode without deleting anything.

    Development builds intentionally retain their previous permissive behavior.
    """
    if not release_mode:
        return ()
    violations: list[tuple[str, str]] = []
    for candidate in sorted(source_root.rglob("*")):
        relative = candidate.relative_to(source_root)
        reason = _source_violation_reason(relative)
        if reason:
            violations.append((reason, relative.as_posix()))
    if violations:
        detail = ";".join(f"reason={reason},path={path}" for reason, path in violations)
        first_reason, first_path = violations[0]
        raise MacOSReleaseHygieneError(
            first_reason, artifact=source_root, entry=first_path, detail=detail
        )
    return tuple(violations)
