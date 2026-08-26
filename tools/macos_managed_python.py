#!/usr/bin/env python3
"""Pinned managed-Python artifact identity, preparation, and payload audit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


MANAGED_PYTHON_RELEASE = "20260408"
MANAGED_PYTHON_VERSION = "3.12.13"
MANAGED_PYTHON_ARTIFACT_FILENAME = (
    "cpython-3.12.13+20260408-aarch64-apple-darwin-install_only_stripped.tar.gz"
)
MANAGED_PYTHON_ARTIFACT_URL = (
    "https://github.com/astral-sh/python-build-standalone/releases/download/20260408/"
    "cpython-3.12.13%2B20260408-aarch64-apple-darwin-install_only_stripped.tar.gz"
)
MANAGED_PYTHON_ARTIFACT_SHA256 = (
    "ac167e74961316ceabdbe4839f19aa6000c592b08e5a1fab4646cb225ede13d5"
)
MANAGED_PYTHON_PLATFORM = "aarch64-apple-darwin"
MANAGED_PYTHON_ARCHITECTURE = "arm64"
MANAGED_PYTHON_IMPLEMENTATION = "CPython"
MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY: dict[str, object] = {
    "sha256": "594934eba86fbd78749f30e185dd3e3d1a4da73ad440d370d3e474a55c26cf86",
    "entry_count": 2057,
    "file_count": 1889,
    "directory_count": 159,
    "symlink_count": 9,
}
MANAGED_PYTHON_EXCLUDED_NON_MACOS_PATHS = (
    "lib/python3.12/ctypes/macholib/fetch_macholib.bat",
    "lib/python3.12/idlelib/idle.bat",
    "lib/python3.12/site-packages/pip/_vendor/distlib/t32.exe",
    "lib/python3.12/site-packages/pip/_vendor/distlib/t64-arm.exe",
    "lib/python3.12/site-packages/pip/_vendor/distlib/t64.exe",
    "lib/python3.12/site-packages/pip/_vendor/distlib/w32.exe",
    "lib/python3.12/site-packages/pip/_vendor/distlib/w64-arm.exe",
    "lib/python3.12/site-packages/pip/_vendor/distlib/w64.exe",
    "lib/python3.12/venv/scripts/common/Activate.ps1",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def authoritative_artifact_identity() -> dict[str, str]:
    return {
        "managed_python_release": MANAGED_PYTHON_RELEASE,
        "managed_python_version": MANAGED_PYTHON_VERSION,
        "managed_python_artifact_filename": MANAGED_PYTHON_ARTIFACT_FILENAME,
        "managed_python_artifact_url": MANAGED_PYTHON_ARTIFACT_URL,
        "managed_python_artifact_sha256": MANAGED_PYTHON_ARTIFACT_SHA256,
        "managed_python_platform": MANAGED_PYTHON_PLATFORM,
        "managed_python_architecture": MANAGED_PYTHON_ARCHITECTURE,
        "managed_python_implementation": MANAGED_PYTHON_IMPLEMENTATION,
    }


def _normalized_archive_path(path: PurePosixPath) -> PurePosixPath:
    parts: list[str] = []
    for part in path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not parts:
                raise RuntimeError(f"Unsafe managed-Python archive path: {path}")
            parts.pop()
        else:
            parts.append(part)
    return PurePosixPath(*parts)


def safe_extract_artifact(artifact: Path, destination: Path) -> Path:
    if not artifact.is_file():
        raise RuntimeError(f"Managed-Python artifact is missing: {artifact}")
    actual_sha256 = sha256_file(artifact)
    if actual_sha256 != MANAGED_PYTHON_ARTIFACT_SHA256:
        raise RuntimeError(
            "Managed-Python artifact SHA-256 mismatch: "
            f"{actual_sha256}, expected {MANAGED_PYTHON_ARTIFACT_SHA256}"
        )
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(artifact, "r:gz") as archive:
        for member in archive.getmembers():
            member_path = PurePosixPath(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise RuntimeError(f"Unsafe managed-Python archive path: {member.name}")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise RuntimeError(f"Unsupported managed-Python archive entry: {member.name}")
            if member.issym() or member.islnk():
                link_path = PurePosixPath(member.linkname)
                if link_path.is_absolute():
                    raise RuntimeError(f"Unsafe managed-Python archive link: {member.name}")
                base = member_path.parent if member.issym() else PurePosixPath()
                _normalized_archive_path(base / link_path)
        archive.extractall(destination, filter="fully_trusted")
    python_root = destination / "python"
    if not python_root.is_dir():
        raise RuntimeError("Managed-Python artifact does not contain the expected python/ root")
    return python_root


def inspect_managed_python_runtime(python_root: Path) -> dict[str, str]:
    executable = python_root / "bin/python3.12"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError("Managed-Python runtime has no executable bin/python3.12")
    code = (
        "import json,platform,sys; "
        "print(json.dumps({'implementation': platform.python_implementation(), "
        "'python_version': platform.python_version(), 'sys_platform': sys.platform, "
        "'architecture': platform.machine()}, sort_keys=True))"
    )
    result = subprocess.run(
        [str(executable), "-I", "-B", "-c", code],
        check=True,
        capture_output=True,
        text=True,
    )
    try:
        identity = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Managed-Python runtime returned invalid identity output") from exc
    expected = {
        "implementation": MANAGED_PYTHON_IMPLEMENTATION,
        "python_version": MANAGED_PYTHON_VERSION,
        "sys_platform": "darwin",
        "architecture": MANAGED_PYTHON_ARCHITECTURE,
    }
    if identity != expected:
        raise RuntimeError(f"Unexpected managed-Python runtime identity: {identity}, expected {expected}")
    return identity


def payload_tree_identity(root: Path) -> dict[str, object]:
    if not root.is_dir():
        raise RuntimeError(f"Managed-Python payload directory is missing: {root}")
    records: list[dict[str, object]] = []
    counts = {"file_count": 0, "directory_count": 0, "symlink_count": 0}
    for path in [root, *sorted(root.rglob("*"))]:
        metadata = path.lstat()
        mode = metadata.st_mode
        relative = "." if path == root else path.relative_to(root).as_posix()
        if stat.S_ISDIR(mode):
            entry_type = "directory"
            counts["directory_count"] += 1
        elif stat.S_ISLNK(mode):
            entry_type = "symlink"
            counts["symlink_count"] += 1
        elif stat.S_ISREG(mode):
            entry_type = "file"
            counts["file_count"] += 1
        else:
            raise RuntimeError(f"Unsupported managed-Python payload entry: {relative}")
        records.append({
            "path": relative,
            "type": entry_type,
            "mode": format(stat.S_IMODE(mode), "04o"),
            "size": metadata.st_size if entry_type in {"file", "symlink"} else None,
            "sha256": sha256_file(path) if entry_type == "file" else None,
            "link_target": os.readlink(path) if entry_type == "symlink" else None,
        })
    serialized = json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "sha256": hashlib.sha256(serialized).hexdigest(),
        "entry_count": len(records),
        **counts,
    }


def prune_non_macos_runtime_files(root: Path) -> list[str]:
    removed: list[str] = []
    for relative in MANAGED_PYTHON_EXCLUDED_NON_MACOS_PATHS:
        candidate = root / relative
        if not candidate.is_file() or candidate.is_symlink():
            raise RuntimeError(
                f"Managed-Python artifact is missing expected non-macOS helper: {relative}"
            )
        candidate.unlink()
        removed.append(relative)
    return removed


def prepare_managed_python_payload(
    destination: Path,
    *,
    artifact: Path | None = None,
    development_source: Path | None = None,
    release_mode: bool = False,
) -> dict[str, object]:
    if artifact is not None and development_source is not None:
        raise RuntimeError("Choose either the official managed-Python artifact or a development directory")
    if release_mode and artifact is None:
        raise RuntimeError("Release mode requires the official pinned managed-Python artifact")
    if release_mode and development_source is not None:
        raise RuntimeError("Release mode refuses managed-Python development directory overrides")
    if destination.exists():
        shutil.rmtree(destination)

    if artifact is not None:
        with tempfile.TemporaryDirectory(prefix="stemwerk-managed-python-artifact-") as temp_name:
            source = safe_extract_artifact(artifact, Path(temp_name))
            artifact_tree = payload_tree_identity(source)
            if artifact_tree != MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY:
                raise RuntimeError(
                    "Managed-Python artifact tree identity mismatch: "
                    f"{artifact_tree}, expected {MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY}"
                )
            excluded_non_macos_paths = prune_non_macos_runtime_files(source)
            runtime_identity = inspect_managed_python_runtime(source)
            shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
        provenance: dict[str, object] = {
            **authoritative_artifact_identity(),
            "build_mode": "official-prebuilt-artifact",
            "official_artifact": True,
            "artifact_verified": True,
            "release_eligible": True,
            "artifact_payload_tree": artifact_tree,
            "excluded_non_macos_paths": excluded_non_macos_paths,
            "runtime_validation": runtime_identity,
            "payload_tree": payload_tree_identity(destination),
        }
    else:
        if development_source is None or not development_source.is_dir():
            raise RuntimeError("A managed-Python development directory is required outside release mode")
        runtime_identity = inspect_managed_python_runtime(development_source)
        shutil.copytree(development_source, destination, symlinks=True, copy_function=shutil.copy2)
        provenance = {
            "managed_python_release": "development-override",
            "managed_python_version": runtime_identity["python_version"],
            "managed_python_artifact_filename": None,
            "managed_python_artifact_url": "development-directory-override",
            "managed_python_artifact_sha256": None,
            "managed_python_platform": runtime_identity["sys_platform"],
            "managed_python_architecture": runtime_identity["architecture"],
            "managed_python_implementation": runtime_identity["implementation"],
            "build_mode": "development-directory-override",
            "official_artifact": False,
            "artifact_verified": False,
            "release_eligible": False,
            "artifact_payload_tree": None,
            "excluded_non_macos_paths": [],
            "runtime_validation": runtime_identity,
            "payload_tree": payload_tree_identity(destination),
        }
    return provenance


def validate_official_managed_python_provenance(
    python_root: Path, manifest: dict[str, object]
) -> dict[str, object]:
    provenance = manifest.get("managed_python")
    if not isinstance(provenance, dict):
        raise RuntimeError("Missing managed-Python provenance in payload manifest")
    expected_fields: dict[str, object] = {
        **authoritative_artifact_identity(),
        "build_mode": "official-prebuilt-artifact",
        "official_artifact": True,
        "artifact_verified": True,
        "release_eligible": True,
    }
    for field, expected in expected_fields.items():
        if field not in provenance:
            raise RuntimeError(f"Missing managed-Python provenance field: {field}")
        if provenance[field] != expected:
            raise RuntimeError(
                f"Invalid managed-Python provenance field {field}: {provenance[field]!r}, expected {expected!r}"
            )
    if provenance.get("artifact_payload_tree") != MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY:
        raise RuntimeError("Invalid managed-Python provenance field artifact_payload_tree")
    if provenance.get("excluded_non_macos_paths") != list(MANAGED_PYTHON_EXCLUDED_NON_MACOS_PATHS):
        raise RuntimeError("Invalid managed-Python provenance field excluded_non_macos_paths")
    runtime_identity = inspect_managed_python_runtime(python_root)
    if provenance.get("runtime_validation") != runtime_identity:
        raise RuntimeError("Managed-Python runtime identity differs from manifest provenance")
    tree_identity = payload_tree_identity(python_root)
    if provenance.get("payload_tree") != tree_identity:
        raise RuntimeError("Managed-Python payload tree differs from manifest provenance")
    return provenance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-artifact-json", action="store_true")
    parser.add_argument(
        "--print-artifact-field",
        choices=sorted(authoritative_artifact_identity()),
    )
    args = parser.parse_args()
    identity = authoritative_artifact_identity()
    if args.print_artifact_field:
        print(identity[args.print_artifact_field])
    elif args.print_artifact_json:
        print(json.dumps(identity, sort_keys=True))
    else:
        parser.error("choose --print-artifact-json or --print-artifact-field")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
