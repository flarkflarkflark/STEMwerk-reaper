#!/usr/bin/env python3
"""Native, fail-closed MAC-001 filesystem capability probe for macOS."""

from __future__ import annotations

import argparse
import ctypes
import errno as errno_module
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


EXPECTED_CASE_NAME = "apfs-active-replace"
ARTIFACT_NAMES = (
    "probe-summary.json",
    "filesystem-metadata.json",
    "mount-metadata.json",
    "syscall-trace.jsonl",
    "errno.json",
    "timeline.jsonl",
    "cleanup.json",
    "errors.txt",
)


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class ProbeFailure(RuntimeError):
    step: str
    operation: str
    path: str
    errno: int | None
    message: str
    result: dict[str, Any] | None = None

    def __str__(self) -> str:
        return f"MAC-001 {self.step}: {self.operation}({self.path}): {self.message} errno={self.errno}"


class ProbeOps:
    def mkdir_probe(self, parent: Path) -> Path:
        return Path(tempfile.mkdtemp(prefix="macos-mac001-", dir=parent))

    def open_file(self, path: Path) -> int:
        return os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)

    def write(self, descriptor: int, payload: bytes) -> None:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError(errno_module.EIO, "short write")
            view = view[written:]

    def fsync(self, descriptor: int) -> None:
        os.fsync(descriptor)

    def close(self, descriptor: int) -> None:
        os.close(descriptor)

    def replace(self, source: Path, destination: Path) -> None:
        os.replace(source, destination)

    def open_directory(self, path: Path) -> int:
        return os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))

    def device(self, path: Path) -> int:
        return os.stat(path).st_dev

    def read(self, path: Path) -> bytes:
        return path.read_bytes()

    def cleanup(self, path: Path) -> None:
        shutil.rmtree(path)


def legacy_stat_percent_t_output(path: Path) -> str:
    completed = subprocess.run(
        ["stat", "-f", "%T", str(path)], text=True, capture_output=True, check=False
    )
    return completed.stdout.strip()


def filesystem_metadata(path: Path) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "path": str(path.resolve()),
        "device": os.stat(path).st_dev,
        "filesystem_type": "unknown",
    }
    if sys.platform != "darwin":
        return metadata

    class StatFs(ctypes.Structure):
        _fields_ = [
            ("f_bsize", ctypes.c_uint32), ("f_iosize", ctypes.c_int32),
            ("f_blocks", ctypes.c_uint64), ("f_bfree", ctypes.c_uint64),
            ("f_bavail", ctypes.c_uint64), ("f_files", ctypes.c_uint64),
            ("f_ffree", ctypes.c_uint64), ("f_fsid", ctypes.c_int32 * 2),
            ("f_owner", ctypes.c_uint32), ("f_type", ctypes.c_uint32),
            ("f_flags", ctypes.c_uint32), ("f_fssubtype", ctypes.c_uint32),
            ("f_fstypename", ctypes.c_char * 16),
            ("f_mntonname", ctypes.c_char * 1024),
            ("f_mntfromname", ctypes.c_char * 1024),
            ("f_reserved", ctypes.c_uint32 * 8),
        ]

    native = StatFs()
    libc = ctypes.CDLL(None, use_errno=True)
    encoded = os.fsencode(path.resolve())
    if libc.statfs(ctypes.c_char_p(encoded), ctypes.byref(native)) != 0:
        captured = ctypes.get_errno()
        raise OSError(captured, os.strerror(captured), str(path))
    decode = lambda value: bytes(value).split(b"\0", 1)[0].decode("utf-8", "replace")
    metadata.update(
        filesystem_type=decode(native.f_fstypename),
        mount_point=decode(native.f_mntonname),
        mounted_from=decode(native.f_mntfromname),
        mount_flags=native.f_flags,
    )
    return metadata


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def _record_artifacts(artifact_dir: Path, result: dict[str, Any], error: ProbeFailure | None) -> None:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    _write_json(artifact_dir / "probe-summary.json", result)
    _write_json(artifact_dir / "filesystem-metadata.json", result.get("filesystem", {}))
    _write_json(artifact_dir / "mount-metadata.json", result.get("mount", {}))
    with (artifact_dir / "syscall-trace.jsonl").open("w") as stream:
        for item in result.get("syscalls", []):
            stream.write(json.dumps(item, sort_keys=True) + "\n")
    with (artifact_dir / "timeline.jsonl").open("w") as stream:
        for item in result.get("timeline", []):
            stream.write(json.dumps(item, sort_keys=True) + "\n")
    _write_json(
        artifact_dir / "errno.json",
        {"errno": error.errno if error else None, "name": errno_module.errorcode.get(error.errno) if error and error.errno else None},
    )
    _write_json(artifact_dir / "cleanup.json", result.get("cleanup", {"result": "NOT_RUN"}))
    (artifact_dir / "errors.txt").write_text((str(error) + "\n") if error else "")


def run_probe(
    parent: Path,
    artifact_dir: Path,
    *,
    expected_arch: str = "test",
    implementation: str = "test",
    ops: ProbeOps | None = None,
) -> dict[str, Any]:
    ops = ops or ProbeOps()
    parent = Path(parent)
    artifact_dir = Path(artifact_dir)
    result: dict[str, Any] = {
        "schema_version": 1, "case_id": "MAC-001", "case_name": EXPECTED_CASE_NAME,
        "result": "FAIL", "expected_arch": expected_arch, "implementation": implementation,
        "root_path": "none", "temp_path": "none", "same_volume": False,
        "destination_existed": False, "steps": {}, "syscalls": [], "timeline": [],
        "cleanup": {"result": "NOT_RUN"},
    }
    root: Path | None = None
    failure: ProbeFailure | None = None

    def action(step: str, operation: str, path: Path, function, *arguments):
        result["timeline"].append({"time": now(), "step": step, "event": "start"})
        try:
            value = function(*arguments)
        except OSError as error:
            captured = error.errno
            result["steps"][step] = "FAIL"
            result["syscalls"].append({"step": step, "api": operation, "path": str(path), "result": "FAIL", "errno": captured})
            raise ProbeFailure(step, operation, str(path), captured, str(error)) from error
        result["steps"][step] = "PASS"
        result["syscalls"].append({"step": step, "api": operation, "path": str(path), "result": "PASS", "errno": None})
        result["timeline"].append({"time": now(), "step": step, "event": "pass"})
        return value

    try:
        if not parent.is_dir():
            raise ProbeFailure("root_create", "mkdtemp", str(parent), errno_module.ENOENT, "parent directory does not exist")
        root = action("root_create", "mkdtemp", parent, ops.mkdir_probe, parent)
        result["root_path"] = str(root)
        destination = root / "selector.active"
        temporary = root / "selector.tmp"
        result["temp_path"] = str(temporary)
        result["filesystem"] = filesystem_metadata(root)
        if sys.platform == "darwin" and result["filesystem"]["filesystem_type"] != "apfs":
            raise ProbeFailure(
                "filesystem_type", "statfs", str(root), None,
                f"expected apfs, got {result['filesystem']['filesystem_type']}",
            )
        statvfs = os.statvfs(root)
        result["mount"] = {"flags": statvfs.f_flag, "block_size": statvfs.f_bsize}

        for step, path, payload in (("source_write", destination, b"old\n"), ("temporary_write", temporary, b"new\n")):
            descriptor = action(step, "open", path, ops.open_file, path)
            try:
                action(step, "write", path, ops.write, descriptor, payload)
                action("file_flush", "fsync", path, ops.fsync, descriptor)
            finally:
                ops.close(descriptor)
        result["destination_existed"] = destination.exists()
        target_device = ops.device(destination)
        temporary_device = ops.device(temporary)
        if target_device != temporary_device:
            raise ProbeFailure("same_volume", "stat.st_dev", str(temporary), errno_module.EXDEV, f"target={target_device} temp={temporary_device}")
        result["same_volume"] = True
        result["steps"]["same_volume"] = "PASS"
        action("rename_replace", "rename", temporary, ops.replace, temporary, destination)
        directory_fd = action("directory_open", "open(O_RDONLY|O_DIRECTORY)", root, ops.open_directory, root)
        try:
            action("directory_flush", "fsync", root, ops.fsync, directory_fd)
        finally:
            ops.close(directory_fd)
        observed = action("observation", "read", destination, ops.read, destination)
        if observed != b"new\n" or temporary.exists():
            result["steps"]["observation"] = "FAIL"
            raise ProbeFailure("observation", "read", str(destination), None, "replacement state not observed")
        result["result"] = "PASS"
    except ProbeFailure as error:
        failure = error
    finally:
        if root is not None and root.exists():
            try:
                ops.cleanup(root)
                root_absent = not root.exists()
                if not root_absent:
                    raise OSError(errno_module.EIO, "cleanup returned with probe root present")
                result["cleanup"] = {"result": "PASS", "root_absent": root_absent}
            except OSError as error:
                captured = error.errno
                result["cleanup"] = {"result": "FAIL", "errno": captured, "message": str(error)}
                failure = ProbeFailure("cleanup", "rmtree", str(root), captured, str(error))
                result["result"] = "FAIL"
        _record_artifacts(artifact_dir, result, failure)
    if failure:
        failure.result = result
        raise failure
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--expected-arch", choices=("x86_64", "arm64"), required=True)
    parser.add_argument("--implementation", choices=("rust", "go"), required=True)
    parser.add_argument("--platform-tsv", type=Path)
    arguments = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != arguments.expected_arch:
        print("MAC-001 native platform mismatch", file=sys.stderr)
        return 1
    try:
        result = run_probe(arguments.parent, arguments.artifact_dir, expected_arch=arguments.expected_arch, implementation=arguments.implementation)
    except ProbeFailure as error:
        print(error, file=sys.stderr)
        return 1
    if arguments.platform_tsv:
        arguments.platform_tsv.parent.mkdir(parents=True, exist_ok=True)
        arguments.platform_tsv.write_text(f"case_id\tresult\tdetail\nMAC-001\tPASS\t{EXPECTED_CASE_NAME}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
