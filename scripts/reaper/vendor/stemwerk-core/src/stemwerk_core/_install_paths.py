"""Path policy for the files Core keeps under ``<root>`` (lock, journal).

- Directories Core creates get mode 0o700 and files it creates get 0o600
  (POSIX; Windows ignores the mode). Permissions of ``<root>`` itself and of
  directories or files that already exist (for example from 2.3) are never
  changed.
- No path component below ``<root>`` may be a symbolic link or a reparse
  point. ``<root>`` itself and its ancestors may be (a symlinked home
  directory is common).
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import stat
from typing import Iterable, Optional

from . import asset_materialization as materialization


DIRECTORY_MODE = 0o700
FILE_MODE = 0o600


class InstallPathError(Exception):
    """``code`` is ``path_ineligible`` or ``path_unavailable``."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Identity:
    device: int
    inode: int
    is_directory: bool

    @classmethod
    def of(cls, path_stat: os.stat_result) -> "Identity":
        return cls(path_stat.st_dev, path_stat.st_ino, stat.S_ISDIR(path_stat.st_mode))

    def matches(self, path_stat: os.stat_result) -> bool:
        return (
            path_stat.st_dev == self.device
            and path_stat.st_ino == self.inode
            and stat.S_ISDIR(path_stat.st_mode) == self.is_directory
            and (stat.S_ISDIR(path_stat.st_mode) or stat.S_ISREG(path_stat.st_mode))
            and not materialization._is_link_or_reparse(path_stat)
        )

    def to_json(self) -> dict:
        return {"device": self.device, "inode": self.inode, "is_directory": self.is_directory}


def absolute_root(root: os.PathLike | str) -> Path:
    path = Path(root)
    if not path.is_absolute() or ".." in path.parts:
        raise InstallPathError("path_ineligible", "<root> must be an absolute path without '..'")
    return path


def lstat_inside(path: Path) -> Optional[os.stat_result]:
    """``lstat`` of a path below ``<root>``; ``None`` if absent; links refused."""

    try:
        path_stat = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise InstallPathError("path_unavailable", f"cannot inspect {path}: {exc}") from exc
    if materialization._is_link_or_reparse(path_stat):
        raise InstallPathError(
            "path_ineligible", f"{path} is a symbolic link or reparse point inside <root>"
        )
    return path_stat


def check_existing_directories(root: Path, parts: Iterable[str]) -> Optional[Path]:
    """Read-only walk below ``root``: the directory, or ``None`` if one is absent."""

    current = root
    for part in parts:
        current = current / part
        path_stat = lstat_inside(current)
        if path_stat is None:
            return None
        if not stat.S_ISDIR(path_stat.st_mode):
            raise InstallPathError("path_ineligible", f"{current} is not a directory")
    return current


def _make_directory(path: Path) -> None:
    try:
        os.mkdir(path, DIRECTORY_MODE)
    except FileExistsError:
        return
    except OSError as exc:
        raise InstallPathError("path_unavailable", f"cannot create {path}: {exc}") from exc
    created = lstat_inside(path)
    if created is None or not stat.S_ISDIR(created.st_mode):
        raise InstallPathError("path_unavailable", f"{path} disappeared after creation")
    if os.name == "posix" and stat.S_IMODE(created.st_mode) != DIRECTORY_MODE:
        # The umask may have removed bits; set exactly the mode we created it with.
        os.chmod(path, DIRECTORY_MODE)


def ensure_directories(root: Path, parts: Iterable[str]) -> Path:
    """Create the missing directories ``root/parts...``; return the last one.

    ``root`` is created when absent (its parent must exist); an existing
    ``root`` may be a link and keeps its permissions.
    """

    try:
        root_stat = os.stat(root)
    except FileNotFoundError:
        root_stat = None
    except OSError as exc:
        raise InstallPathError("path_unavailable", f"cannot inspect <root>: {exc}") from exc
    if root_stat is None:
        _make_directory(root)
    elif not stat.S_ISDIR(root_stat.st_mode):
        raise InstallPathError("path_ineligible", "<root> is not a directory")
    current = root
    for part in parts:
        current = current / part
        path_stat = lstat_inside(current)
        if path_stat is None:
            _make_directory(current)
            path_stat = lstat_inside(current)
        if path_stat is None or not stat.S_ISDIR(path_stat.st_mode):
            raise InstallPathError("path_ineligible", f"{current} is not a directory")
    return current


def create_file(path: Path, flags: int = 0) -> int:
    """Create ``path`` exclusively with mode 0o600 and return the descriptor."""

    descriptor = os.open(
        path,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | materialization._binary_flag()
        | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | flags,
        FILE_MODE,
    )
    if os.name == "posix":
        try:
            os.fchmod(descriptor, FILE_MODE)
        except BaseException:
            os.close(descriptor)
            raise
    return descriptor


def sync_directory(path: Path) -> None:
    """Make a creation or rename in ``path`` durable (POSIX; no-op on Windows)."""

    if os.name != "posix":
        return
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
