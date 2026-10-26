"""Directory-link helpers shared by the DrumSep asset tests."""
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys


def make_directory_link(link: Path, target: Path) -> None:
    """Create a directory link at ``link`` pointing to the existing ``target``.

    Windows gets a directory junction through ``_winapi.CreateJunction``; every
    other platform gets a directory symlink. There is no fallback between
    mechanisms: a failure to create the link, or a result of the wrong type,
    fails the calling test. ``_winapi.CreateJunction`` was chosen over
    ``cmd /c mklink /J`` because it needs no subprocess or shell quoting and no
    symlink privilege, and CPython's own test suite creates junctions with it.
    """

    assert target.is_dir(), f"link target must be an existing directory: {target}"
    if sys.platform == "win32":
        import _winapi

        _winapi.CreateJunction(str(target), str(link))
        attributes = os.lstat(link).st_file_attributes
        assert attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT, (
            f"expected a reparse point at {link}"
        )
    else:
        link.symlink_to(target, target_is_directory=True)
        assert link.is_symlink(), f"expected a symbolic link at {link}"


def is_directory_link(path: Path) -> bool:
    if sys.platform == "win32":
        return bool(os.lstat(path).st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)
    return path.is_symlink()
