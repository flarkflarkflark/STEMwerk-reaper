"""Read-only verification of a published managed Python (design 6.1, G1 step 4).

The outer layer publishes the ``python/`` directory of the pinned
python-build-standalone archive as ``<root>/runtimes/python/<name>/`` with a
no-replace rename (slice S5b). This module verifies such a directory without
changing it. The checks run in this order, and the interpreter is started only
when the tree passes the earlier ones:

1. Location: every path component from ``<root>`` down to the runtime
   directory is a real directory, not a link or reparse point.
2. Tree: every entry is a directory, a regular file with a single link, or
   (POSIX only) a relative symbolic link whose resolved target stays inside
   the runtime directory. Absolute or escaping links, hard-linked files,
   reparse points and special files are refused.
3. Interpreter: ``bin/python3.12`` (POSIX) or ``python.exe`` (Windows) is a
   regular file. Started as ``-I -B -c <probe>`` with a timeout, it must report
   CPython, exactly the pinned version, the platform's architecture, 64-bit
   pointers, isolated mode, and ``sys.prefix`` equal to the runtime directory.

The result is ``verified``, ``absent`` or ``invalid`` with stable reason
codes. Verification proves the published tree runs as the pinned
interpreter; the archive's integrity is established before unpacking
(``runtime_manifest.check_archive``), never by this module.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
from typing import Any, Callable, Dict, List

from . import asset_materialization as materialization
from . import runtime_manifest
from ._install_paths import InstallPathError, absolute_root, check_existing_directories


SCHEMA_VERSION = "1.0.0"
VERIFIED = "verified"
ABSENT = "absent"
INVALID = "invalid"
DEFAULT_TIMEOUT = 60.0

INTERPRETERS = {
    "linux-x86_64": ("bin", "python3.12"),
    "darwin-arm64": ("bin", "python3.12"),
    "win-x86_64": ("python.exe",),
}
MACHINES = {
    "linux-x86_64": {"x86_64", "amd64"},
    "darwin-arm64": {"arm64"},
    "win-x86_64": {"amd64", "x86_64"},
}

# Runs in the candidate interpreter; ASCII-only output survives any code page.
PROBE = (
    "import json, platform, struct, sys\n"
    "print(json.dumps({'implementation': sys.implementation.name,"
    " 'version': platform.python_version(), 'machine': platform.machine(),"
    " 'pointer_bits': struct.calcsize('P') * 8, 'prefix': sys.prefix,"
    " 'isolated': sys.flags.isolated}, ensure_ascii=True, sort_keys=True))\n"
)

Runner = Callable[..., subprocess.CompletedProcess]


def interpreter_path(runtime_dir: os.PathLike | str, platform_id: str) -> Path:
    return Path(runtime_dir).joinpath(*INTERPRETERS[platform_id])


def _scan_tree(runtime_dir: Path, posix_links: bool) -> List[Dict[str, Any]]:
    """Problems found in the tree; walks without following any link."""

    problems: List[Dict[str, Any]] = []
    real_root = os.path.realpath(runtime_dir)
    pending = [runtime_dir]
    while pending and len(problems) < 20:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                children = list(entries)
        except OSError as exc:
            problems.append({"code": "runtime_unreadable", "path": str(directory), "detail": str(exc)})
            continue
        for entry in children:
            path = Path(entry.path)
            relative = path.relative_to(runtime_dir).as_posix()
            try:
                entry_stat = entry.stat(follow_symlinks=False)
            except OSError as exc:
                problems.append({"code": "runtime_unreadable", "path": relative, "detail": str(exc)})
                continue
            if materialization._is_reparse_point(entry_stat):
                problems.append({"code": "reparse_point", "path": relative})
            elif stat.S_ISLNK(entry_stat.st_mode):
                if not posix_links:
                    problems.append({"code": "link_not_allowed", "path": relative})
                    continue
                try:
                    target = os.readlink(path)
                except OSError as exc:
                    problems.append({"code": "runtime_unreadable", "path": relative, "detail": str(exc)})
                    continue
                if os.path.isabs(target):
                    problems.append({"code": "absolute_link", "path": relative, "target": target})
                    continue
                resolved = os.path.realpath(path)
                if resolved != real_root and not resolved.startswith(real_root + os.sep):
                    problems.append({"code": "link_escapes_runtime", "path": relative, "target": target})
            elif stat.S_ISDIR(entry_stat.st_mode):
                pending.append(path)
            elif stat.S_ISREG(entry_stat.st_mode):
                if entry_stat.st_nlink > 1:
                    problems.append({"code": "hard_link", "path": relative})
            else:
                problems.append({"code": "special_file", "path": relative})
    return problems


def _probe_problems(document: Any, record: runtime_manifest.RuntimeRecord, runtime_dir: Path) -> List[str]:
    problems = []
    if document.get("implementation") != "cpython":
        problems.append("implementation_mismatch")
    if document.get("version") != record.version:
        problems.append("version_mismatch")
    machine = document.get("machine")
    if not isinstance(machine, str) or machine.lower() not in MACHINES[record.platform]:
        problems.append("architecture_mismatch")
    if document.get("pointer_bits") != 64:
        problems.append("pointer_size_mismatch")
    if document.get("isolated") != 1:
        problems.append("not_isolated")
    prefix = document.get("prefix")
    if not isinstance(prefix, str) or os.path.normcase(os.path.realpath(prefix)) != os.path.normcase(
        os.path.realpath(runtime_dir)
    ):
        problems.append("prefix_mismatch")
    return problems


def probe_interpreter(
    executable: os.PathLike | str, *, timeout: float = DEFAULT_TIMEOUT, run: Runner = subprocess.run
) -> Dict[str, Any]:
    """Start ``executable -I -B -c PROBE``; the parsed report or a failure code."""

    try:
        completed = run(
            [str(executable), "-I", "-B", "-c", PROBE],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        return {"error": "interpreter_timeout"}
    except OSError as exc:
        return {"error": "interpreter_failed", "detail": f"{type(exc).__name__}: {exc}"}
    if completed.returncode != 0:
        return {"error": "interpreter_failed", "detail": f"exit status {completed.returncode}"}
    try:
        document = json.loads(completed.stdout.decode("ascii"))
    except (UnicodeDecodeError, ValueError):
        return {"error": "interpreter_output_invalid"}
    if not isinstance(document, dict):
        return {"error": "interpreter_output_invalid"}
    return {"report": document}


def verify_managed_python(
    root: os.PathLike | str,
    record: runtime_manifest.RuntimeRecord,
    *,
    timeout: float = DEFAULT_TIMEOUT,
    run: Runner = subprocess.run,
    os_name: str = os.name,
) -> Dict[str, Any]:
    """Verify ``<root>/runtimes/python/<record.name>`` read-only (see the module doc)."""

    document: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": INVALID,
        "name": record.name,
        "platform": record.platform,
        "path": None,
        "reasons": [],
        "interpreter": None,
    }
    try:
        root = absolute_root(root)
    except InstallPathError as exc:
        document["reasons"] = [{"code": f"runtime_{exc.code}", "detail": str(exc)}]
        return document
    runtime_dir = runtime_manifest.published_directory(root, record)
    document["path"] = str(runtime_dir)
    try:
        found = check_existing_directories(root, ("runtimes", record.component, record.name))
    except InstallPathError as exc:
        document["reasons"] = [{"code": f"runtime_{exc.code}", "detail": str(exc)}]
        return document
    if found is None:
        document["status"] = ABSENT
        return document
    problems = _scan_tree(runtime_dir, posix_links=os_name != "nt")
    executable = interpreter_path(runtime_dir, record.platform)
    try:
        executable_stat = os.lstat(executable)
    except OSError:
        executable_stat = None
    if executable_stat is None or not stat.S_ISREG(executable_stat.st_mode):
        problems.append({"code": "interpreter_missing", "path": executable.relative_to(runtime_dir).as_posix()})
    if problems:
        document["reasons"] = problems
        return document
    probe = probe_interpreter(executable, timeout=timeout, run=run)
    if "error" in probe:
        document["reasons"] = [{"code": probe["error"], **({"detail": probe["detail"]} if "detail" in probe else {})}]
        return document
    report = probe["report"]
    document["interpreter"] = {"executable": str(executable), **report}
    mismatches = _probe_problems(report, record, runtime_dir)
    if mismatches:
        document["reasons"] = [{"code": code} for code in mismatches]
        return document
    document["status"] = VERIFIED
    return document
