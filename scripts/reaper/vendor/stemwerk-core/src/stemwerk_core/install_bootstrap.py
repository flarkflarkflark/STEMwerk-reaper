"""The outer layer's bootstrap staging and its cleanup (design O55, C24).

Layout. Within an operation's directory ``<root>/tmp/<op>/`` the outer layer
(G1) writes only ``bootstrap/``; Core's journal and ``core/`` staging live
beside it (``install_journal``). Download, unpack and the owner record all go
into ``bootstrap/``, which the outer layer removes itself after it published
or failed. Only a crashed outer layer leaves it behind.

Owner record. The first file the outer layer writes into ``bootstrap/`` is
``owner``: one LF-terminated line of three TAB-separated fields,
``stemwerk-bootstrap-owner/1``, the operation id and the outer layer's
process id. ``sh`` writes it with one ``printf``, Inno with one
``SaveStringToFile``.

Liveness signal. An active outer layer appends an event to
``<root>/logs/<op>/events.ndjson`` at least every 5 seconds while it works
(design 7.2), except during one blocking unpack step. A staging directory
is stale only when both hold:

- it has been silent for at least ``stale_after`` seconds (default 15
  minutes): no modification of the events file, of ``bootstrap/`` itself or
  of any of its direct entries;
- the recorded process is proven gone on this host. A running process, or
  one whose state cannot be determined, keeps the staging; so does a record
  that names another operation. Without a readable owner record only the
  silence decides.

A reused process id can therefore only keep staging longer, never remove an
active one. Core removes stale staging while it holds the install lock
(``install_lock.acquire`` calls :func:`remove_stale_staging` after journal
recovery). It never follows a link: an operation directory or ``bootstrap/``
that is a link or reparse point is reported and kept, and the identity found
at inspection is checked again right before removal. Nothing else under
``<root>`` is touched, and the registry and receipts never reference
``<root>/tmp``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
import stat
import time
from typing import Any, Callable, Dict, List, Optional

from . import install_events, process_identity
from ._install_paths import Identity, InstallPathError, check_existing_directories, lstat_inside


OWNER_PROTOCOL = "stemwerk-bootstrap-owner/1"
BOOTSTRAP_DIRECTORY = "bootstrap"
OWNER_FILENAME = "owner"
TMP_DIRECTORY = "tmp"
LOGS_DIRECTORY = "logs"
DEFAULT_STALE_AFTER = 15 * 60.0
_OWNER_LIMIT = 256
_PID_MAX = 2**31 - 1

# Classification of one operation's bootstrap staging.
ACTIVE_RECENT = "kept_recent"
ACTIVE_OWNER_RUNNING = "kept_owner_running"
OWNER_UNKNOWN = "kept_owner_unknown"
OWNER_OTHER_OPERATION = "kept_owner_other_operation"
CURRENT_OPERATION = "kept_current_operation"
INELIGIBLE = "kept_ineligible"
STALE = "stale"
# Outcomes of a removal attempt.
REMOVED = "removed"
KEPT_IDENTITY_MISMATCH = "kept_identity_mismatch"
KEPT_REMOVE_FAILED = "kept_remove_failed"

Probe = Callable[[int], process_identity.ProcessProbe]


class BootstrapStagingError(Exception):
    """``code`` is ``bootstrap_path_ineligible`` or ``bootstrap_path_unavailable``."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def owner_line(operation_id: str, pid: int) -> bytes:
    """The exact owner record an outer layer writes (reference encoding)."""

    install_events._check_operation_id(operation_id, "invalid_owner")
    if not isinstance(pid, int) or isinstance(pid, bool) or not 0 < pid <= _PID_MAX:
        raise ValueError("pid must be a positive 31-bit integer")
    return f"{OWNER_PROTOCOL}\t{operation_id}\t{pid}\n".encode("ascii")


def parse_owner(data: bytes) -> Optional[Dict[str, Any]]:
    """``{"operation_id", "pid"}`` from an owner record, or ``None`` if malformed."""

    if len(data) > _OWNER_LIMIT or not data.endswith(b"\n") or b"\r" in data:
        return None
    try:
        fields = data[:-1].decode("ascii").split("\t")
    except UnicodeDecodeError:
        return None
    if len(fields) != 3 or fields[0] != OWNER_PROTOCOL:
        return None
    operation_id, pid_text = fields[1], fields[2]
    try:
        install_events._check_operation_id(operation_id, "invalid_owner")
    except install_events.InstallFileError:
        return None
    if not pid_text.isdigit() or pid_text.startswith("0") or len(pid_text) > 10:
        return None
    pid = int(pid_text)
    if pid > _PID_MAX:
        return None
    return {"operation_id": operation_id, "pid": pid}


@dataclass
class StagingEntry:
    operation_id: str
    status: str
    silent_seconds: Optional[float] = None
    owner: Optional[Dict[str, Any]] = None
    owner_running: Optional[bool] = None
    detail: Optional[str] = None
    outcome: Optional[str] = None
    identity: Optional[Identity] = field(default=None, repr=False)

    def to_json(self) -> Dict[str, Any]:
        return {
            "operation_id": self.operation_id,
            "status": self.status,
            "silent_seconds": self.silent_seconds,
            "owner": self.owner,
            "owner_running": self.owner_running,
            "detail": self.detail,
            "outcome": self.outcome,
        }


@dataclass
class StagingReport:
    entries: List[StagingEntry] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        """No stale staging was left behind (kept active staging is fine)."""

        return all(entry.status != STALE or entry.outcome == REMOVED for entry in self.entries)

    def to_json(self) -> Dict[str, Any]:
        return {"complete": self.complete, "entries": [entry.to_json() for entry in self.entries]}


def _mtime(path: Path) -> Optional[float]:
    try:
        path_stat = lstat_inside(path)
    except InstallPathError:
        return None
    return None if path_stat is None else path_stat.st_mtime


def _last_activity(root: Path, operation_id: str, staging: Path, staging_mtime: float) -> float:
    times = [staging_mtime]
    events = _mtime(root / LOGS_DIRECTORY / operation_id / install_events.EVENTS_FILENAME)
    if events is not None:
        times.append(events)
    try:
        with os.scandir(staging) as entries:
            for entry in entries:
                try:
                    times.append(entry.stat(follow_symlinks=False).st_mtime)
                except OSError:
                    pass
    except OSError:
        pass
    return max(times)


def _read_owner(staging: Path) -> Optional[bytes]:
    path = staging / OWNER_FILENAME
    try:
        owner_stat = lstat_inside(path)
    except InstallPathError:
        return None
    if owner_stat is None or not stat.S_ISREG(owner_stat.st_mode) or owner_stat.st_size > _OWNER_LIMIT:
        return None
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None
    try:
        return os.read(descriptor, _OWNER_LIMIT + 1)
    except OSError:
        return None
    finally:
        os.close(descriptor)


def _classify(
    root: Path, operation_id: str, *, stale_after: float, now: float, probe: Probe
) -> Optional[StagingEntry]:
    directory = root / TMP_DIRECTORY / operation_id
    staging = directory / BOOTSTRAP_DIRECTORY
    try:
        directory_stat = lstat_inside(directory)
        if directory_stat is None:
            return None
        if not stat.S_ISDIR(directory_stat.st_mode):
            return StagingEntry(operation_id, INELIGIBLE, detail="operation path is not a directory")
        staging_stat = lstat_inside(staging)
    except InstallPathError as exc:
        return StagingEntry(operation_id, INELIGIBLE, detail=str(exc))
    if staging_stat is None:
        return None
    if not stat.S_ISDIR(staging_stat.st_mode):
        return StagingEntry(operation_id, INELIGIBLE, detail="bootstrap staging is not a directory")
    entry = StagingEntry(operation_id, STALE, identity=Identity.of(staging_stat))
    entry.silent_seconds = round(now - _last_activity(root, operation_id, staging, staging_stat.st_mtime), 3)
    raw_owner = _read_owner(staging)
    owner = parse_owner(raw_owner) if raw_owner is not None else None
    entry.owner = owner
    if raw_owner is not None and owner is None:
        entry.detail = "owner record is malformed"
    if owner is not None:
        if owner["operation_id"] != operation_id:
            entry.status = OWNER_OTHER_OPERATION
            return entry
        try:
            entry.owner_running = probe(owner["pid"]).running
        except Exception:  # an unanswerable probe keeps the staging
            entry.owner_running = None
        if entry.owner_running is True:
            entry.status = ACTIVE_OWNER_RUNNING
            return entry
        if entry.owner_running is None:
            entry.status = OWNER_UNKNOWN
            return entry
    if entry.silent_seconds < stale_after:
        entry.status = ACTIVE_RECENT
    return entry


def inspect_staging(
    root: os.PathLike | str,
    *,
    current_operation_id: Optional[str] = None,
    stale_after: float = DEFAULT_STALE_AFTER,
    probe: Optional[Probe] = None,
    clock: Callable[[], float] = time.time,
) -> StagingReport:
    """Classify every ``<root>/tmp/<op>/bootstrap`` read-only."""

    root = Path(root)
    probe = process_identity.probe_process if probe is None else probe
    report = StagingReport()
    try:
        tmp = check_existing_directories(root, (TMP_DIRECTORY,))
    except InstallPathError as exc:
        raise BootstrapStagingError(f"bootstrap_{exc.code}", str(exc)) from exc
    if tmp is None:
        return report
    now = clock()
    try:
        names = sorted(os.listdir(tmp))
    except OSError as exc:
        raise BootstrapStagingError("bootstrap_path_unavailable", f"cannot list {tmp}: {exc}") from exc
    for name in names:
        try:
            install_events._check_operation_id(name, "invalid_operation")
        except install_events.InstallFileError:
            continue  # not an operation directory: never touched
        if name == current_operation_id:
            try:
                present = lstat_inside(tmp / name / BOOTSTRAP_DIRECTORY) is not None
            except InstallPathError:
                present = True
            if present:
                report.entries.append(StagingEntry(name, CURRENT_OPERATION))
            continue
        entry = _classify(root, name, stale_after=stale_after, now=now, probe=probe)
        if entry is not None:
            report.entries.append(entry)
    return report


def _remove(root: Path, entry: StagingEntry) -> str:
    directory = root / TMP_DIRECTORY / entry.operation_id
    staging = directory / BOOTSTRAP_DIRECTORY
    try:
        directory_stat = lstat_inside(directory)
        current = lstat_inside(staging) if directory_stat is not None else None
    except InstallPathError:
        return KEPT_IDENTITY_MISMATCH
    if (
        directory_stat is None
        or not stat.S_ISDIR(directory_stat.st_mode)
        or current is None
        or entry.identity is None
        or not entry.identity.matches(current)
    ):
        return KEPT_IDENTITY_MISMATCH
    try:
        shutil.rmtree(staging)
    except OSError:
        return KEPT_REMOVE_FAILED
    try:
        os.rmdir(directory)  # only when empty: a journal or core/ staging stays
    except OSError:
        pass
    return REMOVED


def remove_stale_staging(
    root: os.PathLike | str,
    *,
    current_operation_id: Optional[str] = None,
    stale_after: float = DEFAULT_STALE_AFTER,
    probe: Optional[Probe] = None,
    clock: Callable[[], float] = time.time,
) -> StagingReport:
    """Remove stale bootstrap staging; call only while holding the install lock."""

    root = Path(root)
    report = inspect_staging(
        root,
        current_operation_id=current_operation_id,
        stale_after=stale_after,
        probe=probe,
        clock=clock,
    )
    for entry in report.entries:
        if entry.status == STALE:
            entry.outcome = _remove(root, entry)
    return report
