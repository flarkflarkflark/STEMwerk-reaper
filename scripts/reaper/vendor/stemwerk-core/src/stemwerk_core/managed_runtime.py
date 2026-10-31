"""Managed-runtime discovery helpers for STEMwerk Core.

Single home for the per-user runtime-location conventions that previously
existed in two parallel implementations:
``audio_separator_process.py`` (``_runtime_base_candidates`` /
``_read_simple_env_file`` / ``_candidate_ffmpeg_paths``) and
``tools/stemwerk_runtime_diagnostics.py`` (``managed_runtime_root`` family).
Both call sites now import from here. Everything is read-only path
discovery: no directories are created, no state files written, no
environment mutated.

Note the two root conventions are deliberately NOT merged:
``runtime_base_candidates`` (legacy runtime/FFmpeg discovery) does not honor
``STEMWERK_RUNTIME_ROOT`` and returns an ordered candidate list, while
``managed_runtime_root`` (diagnostics/readiness evidence) honors that
override and returns one root. Changing either semantic would change
production FFmpeg discovery behavior.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set


def _is_windows_runtime() -> bool:
    return os.name == "nt" or sys.platform.startswith("win")


def read_simple_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return values
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        if key:
            values[key] = value
    return values


def runtime_base_candidates() -> List[Path]:
    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(path_value: Optional[Path | str]) -> None:
        if not path_value:
            return
        try:
            path = Path(path_value).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    if _is_windows_runtime():
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            add(Path(local_appdata) / "STEMwerk")
    elif sys.platform == "darwin":
        add(Path.home() / "Library" / "Application Support" / "STEMwerk")
    else:
        xdg_data_home = os.environ.get("XDG_DATA_HOME")
        if xdg_data_home:
            add(Path(xdg_data_home) / "STEMwerk")
        add(Path.home() / ".local" / "share" / "STEMwerk")

    return candidates


def candidate_ffmpeg_paths() -> List[Path]:
    """Ordered FFmpeg candidate paths. Discovery only -- never executes,
    never creates the runtime wrapper that _configure_ffmpeg_runtime()
    (kept in the legacy worker, not reused here) would create."""

    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(path_value: Optional[str | Path]) -> None:
        if not path_value:
            return
        try:
            path = Path(path_value).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    for env_key in ("STEMWERK_FFMPEG_PATH", "FFMPEG_PATH", "IMAGEIO_FFMPEG_EXE"):
        add(os.environ.get(env_key))

    for runtime_base in runtime_base_candidates():
        add(runtime_base / "ffmpeg" / "bin" / "ffmpeg.exe")
        add(runtime_base / "ffmpeg" / "ffmpeg.exe")
        add(runtime_base / "bin" / "ffmpeg.exe")
        add(runtime_base / "ffmpeg" / "bin" / "ffmpeg")
        add(runtime_base / "ffmpeg" / "ffmpeg")
        add(runtime_base / "bin" / "ffmpeg")
        bootstrap_values = read_simple_env_file(runtime_base / "state" / "bootstrap.env")
        add(bootstrap_values.get("FFMPEG_PATH"))
        add(bootstrap_values.get("FFMPEG"))
        add(bootstrap_values.get("MANAGED_FFMPEG_PATH"))
        capabilities_values = read_simple_env_file(runtime_base / "state" / "capabilities.env")
        add(capabilities_values.get("FFMPEG_PATH"))
        add(capabilities_values.get("FFMPEG"))
        add(capabilities_values.get("MANAGED_FFMPEG_PATH"))

    exe_dir = Path(sys.executable).resolve().parent
    add(exe_dir / "ffmpeg.exe")
    add(exe_dir.parent / "ffmpeg" / "bin" / "ffmpeg.exe")

    found = shutil.which("ffmpeg")
    add(found)

    return candidates


# ---------------------------------------------------------------------------
# Diagnostics/readiness evidence locations (moved from
# tools/stemwerk_runtime_diagnostics.py; that harness imports them back).
# ---------------------------------------------------------------------------

def managed_runtime_root() -> Path:
    """Per-user STEMwerk managed-runtime root on this platform. Mirrors
    audio_separator_process.py's _default_model_cache_dir() root (that
    function returns <this>/models; this returns <this>)."""
    override = os.environ.get("STEMWERK_RUNTIME_ROOT")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "STEMwerk"
    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return Path(local_appdata) / "STEMwerk"
        return Path.home() / "AppData" / "Local" / "STEMwerk"
    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return Path(xdg_data_home) / "STEMwerk"
    return Path.home() / ".local" / "share" / "STEMwerk"


def _first_existing(root: Path, venv_name: str) -> Optional[Path]:
    for rel in ("bin/python3", "bin/python", "Scripts/python.exe"):
        candidate = root / venv_name / rel
        if candidate.exists():
            return candidate
    return None


def managed_runtime_python() -> Optional[Path]:
    """The main STEMwerk managed venv's interpreter, if bootstrapped."""
    return _first_existing(managed_runtime_root(), ".venv")


def managed_drumsep_pythons() -> Dict[str, Path]:
    """Every installed DrumSep venv on this machine, keyed by backend name.
    Only backends that actually have a venv present are included -- this is
    real filesystem state, not a claim about what *should* be installed."""
    root = managed_runtime_root()
    found: Dict[str, Path] = {}
    for backend, venv_name in (
        ("rocm", ".venv-drumsep-rocm"),
        ("cuda", ".venv-drumsep-cuda"),
        ("directml", ".venv-drumsep-directml"),
        ("cpu", ".venv-drumsep"),
    ):
        python = _first_existing(root, venv_name)
        if python is not None:
            found[backend] = python
    return found


def managed_model_cache_dir() -> Path:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override).expanduser()
    return managed_runtime_root() / "models"
