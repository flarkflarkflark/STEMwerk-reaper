"""Bounded Linux publication helper, run only by the pinned managed Python.

The outer shell has already checked the archive's size and SHA-256 before
unpacking. This helper never downloads, extracts or repairs a destination.
"""

import hashlib
import os
from pathlib import Path
import stat
import sys

sys.path.insert(0, str(Path(__file__).parent))

from stemwerk_core import asset_materialization, managed_python, runtime_manifest


def _private_directory(path: Path) -> bool:
    """Require a user-owned target and safe ancestors, including sticky /tmp."""

    uid = os.geteuid()
    target = True
    current = path
    while True:
        try:
            metadata = os.lstat(current)
        except OSError:
            return False
        if not stat.S_ISDIR(metadata.st_mode):
            return False
        writable_by_others = bool(metadata.st_mode & 0o022)
        if target:
            if metadata.st_uid != uid or writable_by_others:
                return False
        elif metadata.st_uid not in (0, uid) or (writable_by_others and not metadata.st_mode & stat.S_ISVTX):
            return False
        if current == current.parent:
            return True
        current = current.parent
        target = False


def _tree_identity(root: Path) -> dict[str, tuple]:
    """Describe every byte and entry without following links or running code."""

    uid = os.geteuid()
    entries: dict[str, tuple] = {}
    pending = [root]
    while pending:
        path = pending.pop()
        metadata = os.lstat(path)
        if metadata.st_uid != uid:
            raise ValueError("runtime entry has another owner")
        relative = "." if path == root else path.relative_to(root).as_posix()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            if mode & 0o022:
                raise ValueError("runtime directory is writable by another user")
            entries[relative] = ("directory", mode)
            with os.scandir(path) as listing:
                pending.extend(Path(entry.path) for entry in listing)
        elif stat.S_ISREG(metadata.st_mode):
            if mode & 0o022 or metadata.st_nlink != 1:
                raise ValueError("runtime file is writable or hard-linked")
            flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
            handle = os.open(path, flags)
            try:
                opened = os.fstat(handle)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise ValueError("runtime file changed during comparison")
                digest = hashlib.sha256()
                while block := os.read(handle, 1024 * 1024):
                    digest.update(block)
            finally:
                os.close(handle)
            entries[relative] = ("file", mode, metadata.st_size, digest.hexdigest())
        elif stat.S_ISLNK(metadata.st_mode):
            entries[relative] = ("link", os.readlink(path))
        else:
            raise ValueError("runtime contains a special file")
    return entries


def _staging_verified(staging, record):
    if not staging.is_dir() or staging.is_symlink():
        return False
    if managed_python._scan_tree(staging, posix_links=True):
        return False
    executable = managed_python.interpreter_path(staging, record.platform)
    probe = managed_python.probe_interpreter(executable)
    if "report" not in probe:
        return False
    return not managed_python._probe_problems(probe["report"], record, staging)


def main():
    if len(sys.argv) != 4:
        return 3
    root = Path(sys.argv[1])
    staging = Path(sys.argv[2])
    expected_name = sys.argv[3]
    try:
        record = runtime_manifest.python_record("linux-x86_64")
        if record.name != expected_name:
            print("manifest_invalid")
            return 2
        destination = runtime_manifest.published_directory(root, record)
        if any(not _private_directory(path) for path in (root, root / "runtimes", destination.parent)):
            print("root_not_private")
            return 2
        if not _staging_verified(staging, record):
            print("verification_failed")
            return 2
        try:
            asset_materialization._publish_noreplace(staging, destination)
            outcome = "new"
        except asset_materialization.MaterializationError as exc:
            if exc.code != "publication_conflict":
                print(exc.code)
                return 2
            try:
                if _tree_identity(staging) != _tree_identity(destination):
                    print("runtime_conflict")
                    return 2
            except (OSError, ValueError):
                print("runtime_conflict")
                return 2
            outcome = "reused"
        verified = managed_python.verify_managed_python(root, record)
        if verified["status"] != managed_python.VERIFIED:
            print("verification_failed")
            return 2
        print(outcome)
        return 0
    except (OSError, runtime_manifest.ManifestError, ValueError):
        print("publication_failed")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
