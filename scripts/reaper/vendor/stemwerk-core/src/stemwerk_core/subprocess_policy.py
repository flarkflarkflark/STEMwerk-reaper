"""Shared subprocess and bytecode-suppression policy for STEMwerk Core.

Controlled Python invocations in Core installation, verification, readiness
probes, and worker launches must never write ``__pycache__`` or ``.pyc`` files
into the managed Python runtime or published module virtual environments.

Because Python's ``-I`` (isolated mode) ignores ``PYTHONDONTWRITEBYTECODE`` in
the environment, isolated invocations must pass ``-I -B`` on the command line
AND set ``PYTHONDONTWRITEBYTECODE=1`` in ``env`` so any child Python processes
spawned without ``-I`` also inherit bytecode suppression.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional

STRIPPED_PYTHON_ENV_VARS: tuple[str, ...] = (
    "PYTHONPATH",
    "PYTHONHOME",
    "PYTHONSTARTUP",
    "PYTHONINSPECT",
    "PYTHONPYCACHEPREFIX",
    "NUMBA_CACHE_DIR",
)


def clean_python_env(
    base_env: Optional[Mapping[str, str]] = None,
    *,
    extra_strip: Iterable[str] = (),
) -> Dict[str, str]:
    """Return an environment mapping with unsafe Python overrides removed and
    ``PYTHONDONTWRITEBYTECODE=1`` enforced.
    """
    env = dict(os.environ if base_env is None else base_env)
    for key in STRIPPED_PYTHON_ENV_VARS:
        env.pop(key, None)
    for key in extra_strip:
        env.pop(key, None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def clean_pip_env(base_env: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Isolate pip from caller configuration and destination overrides.

    ``pip --isolated`` skips ``PIP_*`` and the user file but still loads the
    global and site files (``/etc/pip.conf``, ``XDG_CONFIG_DIRS``, the venv's
    own ``pip.conf``). Only ``PIP_CONFIG_FILE=<devnull>`` skips all of them.
    """
    env = clean_python_env(base_env)
    for key in tuple(env):
        if key.upper().startswith("PIP_"):
            env.pop(key, None)
    for key in ("VIRTUAL_ENV", "PYTHONUSERBASE", "PYTHONNOUSERSITE"):
        env.pop(key, None)
    env["PIP_CONFIG_FILE"] = os.devnull
    return env


def isolated_python_cmd(python_exe: Path | str, *args: str) -> List[str]:
    """Build an isolated, bytecode-disabled Python command (``python -I -B ...``)."""
    return [str(python_exe), "-I", "-B", *(str(arg) for arg in args)]


def bytecode_disabled_python_cmd(python_exe: Path | str, *args: str) -> List[str]:
    """Build a bytecode-disabled Python command (``python -B ...``)."""
    return [str(python_exe), "-B", *(str(arg) for arg in args)]


def strip_pycache_tree(root: Path) -> int:
    """Remove ``__pycache__`` directories and ``.pyc``/``.pyo`` files inside a
    staged directory tree before immutable publication.

    Never follows symlinks. Returns the number of removed bytecode files.
    """
    target = Path(root)
    if not target.exists() or target.is_symlink():
        return 0
    removed_files = 0
    pycache_dirs: List[Path] = []
    for current_root, dirnames, filenames in os.walk(target, topdown=False, followlinks=False):
        current_path = Path(current_root)
        for filename in filenames:
            candidate = current_path / filename
            if candidate.suffix in {".pyc", ".pyo"} or current_path.name == "__pycache__":
                try:
                    candidate.unlink()
                    removed_files += 1
                except FileNotFoundError:
                    pass
        for dirname in dirnames:
            dir_path = current_path / dirname
            if dirname == "__pycache__" and not dir_path.is_symlink():
                pycache_dirs.append(dir_path)
    for pycache_dir in pycache_dirs:
        try:
            pycache_dir.rmdir()
        except OSError:
            pass
    return removed_files
