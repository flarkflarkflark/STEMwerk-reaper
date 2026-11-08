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
active one.

Writer group (S8 fix3). The Linux outer layer runs every process that can
write the staging in ONE dedicated process group, held behind a pipe release
gate: the group starts with only the read end and writes nothing until the
controller has durably published ``bootstrap/group`` (one line, six TAB-
separated fields: ``stemwerk-bootstrap-group/1``, the operation id, the
absolute staging path, the process group id, the Linux boot id, the PID
namespace or empty) and then sent ``go``. The owner record of such an outer
layer is protocol ``/2``; a ``/2`` owner without a group record therefore
means no worker was ever released. On Linux a staging directory that is
otherwise stale is removed only when its evidence is complete: a ``/2`` owner
and a group record whose boot id positively differs from the current one, or
whose group answers ``ESRCH`` to an observer in the recorded PID namespace on
positively the same boot, with ``/proc`` numbering that namespace (S8 fix4).
A live group, a missing or unreadable boot id, a missing, malformed or
different PID namespace, a malformed or mismatching record, a ``/2`` owner
without a group record (the controller's absence was judged by PID only), a
legacy PID-only (``/1``) owner or no readable owner at all keeps the staging
(``kept_writer_*``), with the reason in the entry's ``detail``. Core only
reads these records and probes the group; it writes nothing before the lock.
A writer that left the group with ``setsid()`` is not reachable by this rule
(documented limit). Core removes stale staging while it holds the install lock
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
import sys
import time
from typing import Any, Callable, Dict, List, Optional

from . import install_cancel, install_events, process_identity
from ._install_paths import Identity, InstallPathError, check_existing_directories, lstat_inside


OWNER_PROTOCOL = "stemwerk-bootstrap-owner/1"
OWNER_PROTOCOL_V2 = "stemwerk-bootstrap-owner/2"  # writers are released only after the group record is published
GROUP_PROTOCOL = "stemwerk-bootstrap-group/1"
GROUP_FILENAME = "group"
_GROUP_LIMIT = 1024
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
# Writer-group verdicts (Linux; see the module docstring): the staging stays.
KEPT_WRITER_GROUP_ALIVE = "kept_writer_group_alive"
KEPT_WRITER_UNPROVEN = "kept_writer_unproven"
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


def owner_line(operation_id: str, pid: int, version: int = 1) -> bytes:
    """The exact owner record an outer layer writes (reference encoding).

    ``version`` 1 is the PID-only record (Windows, macOS, legacy Linux);
    version 2 is the Linux writer-group record family (see the docstring)."""

    install_events._check_operation_id(operation_id, "invalid_owner")
    if not isinstance(pid, int) or isinstance(pid, bool) or not 0 < pid <= _PID_MAX:
        raise ValueError("pid must be a positive 31-bit integer")
    protocol = {1: OWNER_PROTOCOL, 2: OWNER_PROTOCOL_V2}[version]
    return f"{protocol}\t{operation_id}\t{pid}\n".encode("ascii")


def group_line(
    operation_id: str, staging: str, pgid: int, boot_id: str, pid_namespace: str = ""
) -> bytes:
    """The exact group record a Linux outer layer publishes before it releases
    its writer group (reference encoding)."""

    install_events._check_operation_id(operation_id, "invalid_group")
    return (
        f"{GROUP_PROTOCOL}\t{operation_id}\t{staging}\t{pgid}\t{boot_id}\t{pid_namespace}\n"
    ).encode("utf-8")


def parse_group(data: bytes) -> Optional[Dict[str, Any]]:
    """The fields of a group record, or ``None`` when malformed."""

    if len(data) > _GROUP_LIMIT or not data.endswith(b"\n") or b"\r" in data or b"\n" in data[:-1]:
        return None
    try:
        fields = data[:-1].decode("utf-8").split("\t")
    except UnicodeDecodeError:
        return None
    if len(fields) != 6 or fields[0] != GROUP_PROTOCOL:
        return None
    operation_id, staging, pgid_text, boot_id, pid_namespace = fields[1:]
    try:
        install_events._check_operation_id(operation_id, "invalid_group")
    except install_events.InstallFileError:
        return None
    if not pgid_text.isdigit() or pgid_text.startswith("0") or len(pgid_text) > 10:
        return None
    pgid = int(pgid_text)
    if pgid <= 1 or pgid > _PID_MAX or not boot_id or not staging.startswith("/"):
        return None
    return {
        "operation_id": operation_id, "staging": staging, "pgid": pgid,
        "boot_id": boot_id, "pid_namespace": pid_namespace or None,
    }


def parse_owner(data: bytes) -> Optional[Dict[str, Any]]:
    """``{"operation_id", "pid"}`` from an owner record, or ``None`` if malformed."""

    if len(data) > _OWNER_LIMIT or not data.endswith(b"\n") or b"\r" in data:
        return None
    try:
        fields = data[:-1].decode("ascii").split("\t")
    except UnicodeDecodeError:
        return None
    if len(fields) != 3 or fields[0] not in (OWNER_PROTOCOL, OWNER_PROTOCOL_V2):
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
    return {"operation_id": operation_id, "pid": pid, "version": 2 if fields[0] == OWNER_PROTOCOL_V2 else 1}


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


def _default_group_rule() -> bool:
    """The writer-group evidence applies where the Linux outer layer runs."""

    return sys.platform.startswith("linux")


def _read_group(staging: Path) -> "tuple[str, Optional[bytes]]":
    """``("absent", None)``, ``("ok", bytes)`` or ``("unreadable", None)``."""

    path = staging / GROUP_FILENAME
    try:
        group_stat = lstat_inside(path)
    except InstallPathError:
        return "unreadable", None
    if group_stat is None:
        return "absent", None
    if not stat.S_ISREG(group_stat.st_mode) or group_stat.st_size > _GROUP_LIMIT:
        return "unreadable", None
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return "unreadable", None
    try:
        return "ok", os.read(descriptor, _GROUP_LIMIT + 1)
    except OSError:
        return "unreadable", None
    finally:
        os.close(descriptor)


def _writer_verdict(
    root: Path, operation_id: str, staging: Path, owner: Optional[Dict[str, Any]]
) -> "tuple[Optional[str], Optional[str]]":
    """``(None, None)`` when the evidence allows removal, else ``(status, detail)``."""

    if owner is None:
        return KEPT_WRITER_UNPROVEN, "no readable owner record: writers cannot be ruled out"
    if owner.get("version") != 2:
        return KEPT_WRITER_UNPROVEN, "legacy PID-only owner record: writers cannot be ruled out"
    kind, raw = _read_group(staging)
    if kind == "absent":
        # S8 fix4: a /2 outer layer releases no worker before it publishes the
        # group record, but the controller itself writes the staging, and its
        # absence was judged by PID alone: the owner record carries no PID
        # namespace and no boot, so that absence is no proof.
        return KEPT_WRITER_UNPROVEN, (
            "no group record: the owner's absence is no proof (the owner record names "
            "no PID namespace and no boot)"
        )
    if kind != "ok" or raw is None:
        return KEPT_WRITER_UNPROVEN, "the group record is unreadable"
    group = parse_group(raw)
    if group is None:
        return KEPT_WRITER_UNPROVEN, "the group record is malformed"
    expected = os.path.realpath(staging)
    if group["operation_id"] != operation_id or os.path.realpath(group["staging"]) != expected:
        return KEPT_WRITER_UNPROVEN, "the group record names another operation or staging path"
    state, reason = install_cancel.writer_state(group["pgid"], group["boot_id"], group["pid_namespace"])
    if state == install_cancel.WRITER_GONE:
        if reason != "boot_id_changed" and not install_cancel.proc_view_is_own():
            # The group answered ESRCH in the recorded namespace, but the owner
            # (the controller, also a staging writer) was judged "not running"
            # through /proc, which here numbers another PID namespace.
            return KEPT_WRITER_UNPROVEN, (
                f"writer group {group['pgid']}: gone, but this process's /proc is not its own "
                "PID namespace, so the owner's absence proves nothing"
            )
        return None, None
    if state == install_cancel.WRITER_ALIVE:
        return KEPT_WRITER_GROUP_ALIVE, f"writer group {group['pgid']}: {reason}"
    return KEPT_WRITER_UNPROVEN, f"writer group {group['pgid']}: {reason}"


def _classify(
    root: Path, operation_id: str, *, stale_after: float, now: float, probe: Probe,
    group_rule: bool = False,
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
    elif group_rule:
        verdict, detail = _writer_verdict(root, operation_id, staging, owner)
        if verdict is not None:
            entry.status, entry.detail = verdict, detail
    return entry


def inspect_staging(
    root: os.PathLike | str,
    *,
    current_operation_id: Optional[str] = None,
    stale_after: float = DEFAULT_STALE_AFTER,
    probe: Optional[Probe] = None,
    clock: Callable[[], float] = time.time,
    group_rule: Optional[bool] = None,
) -> StagingReport:
    """Classify every ``<root>/tmp/<op>/bootstrap`` read-only.

    ``group_rule`` enables the Linux writer-group evidence (module docstring);
    the default follows the platform. Tests set it explicitly."""

    if group_rule is None:
        group_rule = _default_group_rule()
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
        entry = _classify(root, name, stale_after=stale_after, now=now, probe=probe, group_rule=group_rule)
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
    group_rule: Optional[bool] = None,
) -> StagingReport:
    """Remove stale bootstrap staging; call only while holding the install lock."""

    root = Path(root)
    report = inspect_staging(
        root,
        current_operation_id=current_operation_id,
        stale_after=stale_after,
        probe=probe,
        clock=clock,
        group_rule=group_rule,
    )
    for entry in report.entries:
        if entry.status == STALE:
            entry.outcome = _remove(root, entry)
    return report
