"""The per-user install lock (design section 8; owner decisions 2026-11-01).

Files in ``<root>/state/locks/``:

- ``install.lock``: created exclusively by the operation that holds the lock,
  with its metadata written once (protocol, operation_id, pid, start_token,
  host, created). The holder keeps the file open and holds an OS lock on it
  (``fcntl.flock`` on POSIX; on Windows ``msvcrt.locking`` on one byte far
  beyond the metadata, so readers can still read the metadata). The OS
  releases that lock when the process dies.
- ``install.heartbeat``: the holder's heartbeat, replaced atomically with
  ``os.replace`` every heartbeat interval (default 5 s).
- ``install.guard``: permanent, never removed. Acquiring and breaking happen
  only while holding an OS lock on it, so two operations can never judge and
  break the same lock at once.
- ``broken/``: each broken lock, moved here, with a ``<name>.break.json``
  record; at most 10 records are kept.

A lock is stale only if ALL hold: it was written on this host; its OS lock is
free; its PID is not running, or the running process has a different start
token (PID reuse); and its last heartbeat is older than the stale bound
(default 30 s). Anything that cannot be decided counts as live, so a live lock
is never broken; a lock from another host is never broken.

One narrow exception covers a creator that died between creating
``install.lock`` and writing its metadata: a lock whose content is empty,
truncated or unparseable is abandoned, and may be broken, if its OS lock is
free and the file is older than the stale bound. The creator takes the OS lock
right after the exclusive create and before writing, so a free OS lock proves
it is gone. A lock with complete but invalid metadata is never broken. A file system that
cannot take an OS lock fails with ``lock_unsupported``; there is no fallback.

Read-only callers (``verify``) use :func:`inspect_lock`: it reads the files,
never creates anything and never takes an OS lock. Its judgement cannot check
the OS lock, so it rests on the PID, the start token and the heartbeat.

After every acquisition :func:`acquire` runs journal recovery
(``install_journal.recover``) for interrupted operations, then removes the
stale bootstrap staging of crashed outer layers
(``install_bootstrap.remove_stale_staging``).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import re
import stat
import threading
import time
from typing import Any, Callable, Dict, List, Mapping, Optional
import uuid

from . import asset_materialization as materialization
from . import install_bootstrap, install_events, install_journal, process_identity
from ._install_paths import (
    Identity,
    InstallPathError,
    absolute_root,
    check_existing_directories,
    create_file,
    ensure_directories,
    lstat_inside,
)


LOCK_PROTOCOL = "stemwerk-install-lock/1"
HEARTBEAT_PROTOCOL = "stemwerk-install-heartbeat/1"
BREAK_PROTOCOL = "stemwerk-install-lock-break/1"

LOCK_DIRECTORY_PARTS = ("state", "locks")
LOCK_FILENAME = "install.lock"
HEARTBEAT_FILENAME = "install.heartbeat"
GUARD_FILENAME = "install.guard"
BROKEN_DIRECTORY = "broken"

DEFAULT_HEARTBEAT_INTERVAL = 5.0
DEFAULT_STALE_AFTER = 30.0
DEFAULT_GUARD_TIMEOUT = 10.0
MAX_BROKEN_RECORDS = 10
# Windows byte-range locks are mandatory: lock one byte far beyond the
# metadata so the metadata stays readable.
WINDOWS_LOCK_OFFSET = 1 << 30
_READ_LIMIT = 64 * 1024

# lock_status values
FREE = "free"
HELD = "held"
STALE = "stale"
UNREADABLE = "unreadable"
UNSUPPORTED = "unsupported"
FOREIGN_HOST = "foreign_host"
LOCK_STATUSES = (FREE, HELD, STALE, UNREADABLE, UNSUPPORTED, FOREIGN_HOST)

_LOCK_KEYS = ("created", "host", "operation_id", "pid", "protocol", "start_token")
_HEARTBEAT_KEYS = ("operation_id", "pid", "protocol", "ts")
_BROKEN_NAME = re.compile(
    r"\Ainstall\.(\d{8}T\d{12}Z)\.([0-9a-f-]{36}|abandoned)(?:\.(\d+))?\.lock(\.break\.json)?\Z"
)

# Reasons in a break record.
STALE_OWNER = "stale_owner"
ABANDONED_DURING_CREATION = "abandoned_during_creation"
ABANDONED_LABEL = "abandoned"  # replaces the operation ID in the broken lock's name
_TEMP_HEARTBEAT = re.compile(r"\Ainstall\.heartbeat\.\d+\.[0-9a-f]{32}\.tmp\Z")


class LockError(Exception):
    """``code`` is stable: lock_held, lock_unreadable, lock_unsupported,
    lock_guard_timeout, lock_break_failed, lock_path_ineligible,
    lock_path_unavailable, lock_failed or lock_invalid."""

    def __init__(self, code: str, message: str, details: Optional[Mapping[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = dict(details or {})


class _OsLockUnsupported(Exception):
    pass


# --- OS locks -------------------------------------------------------------


def _os_lock(descriptor: int) -> bool:
    """Try the OS lock without waiting: ``True`` if taken, ``False`` if another
    open file holds it; ``_OsLockUnsupported`` if the file system cannot."""

    if os.name == "nt":
        import msvcrt

        os.lseek(descriptor, WINDOWS_LOCK_OFFSET, os.SEEK_SET)
        try:
            msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            if exc.errno in (errno.EACCES, getattr(errno, "EDEADLOCK", 36)):
                return False
            raise _OsLockUnsupported(str(exc)) from exc
        return True
    import fcntl

    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    except OSError as exc:
        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
            return False
        raise _OsLockUnsupported(str(exc)) from exc
    return True


def _os_unlock(descriptor: int) -> None:
    if os.name == "nt":
        import msvcrt

        os.lseek(descriptor, WINDOWS_LOCK_OFFSET, os.SEEK_SET)
        msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
        return
    import fcntl

    fcntl.flock(descriptor, fcntl.LOCK_UN)


def _open_existing(path: Path) -> int:
    return os.open(
        path,
        os.O_RDWR | materialization._binary_flag() | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )


def os_lock_is_free(path: Path) -> Optional[bool]:
    """Whether nobody holds the OS lock on ``path`` (``None``: file absent).

    Takes and immediately releases the OS lock; not for read-only callers.
    """

    try:
        descriptor = _open_existing(path)
    except FileNotFoundError:
        return None
    try:
        free = _os_lock(descriptor)
        if free:
            _os_unlock(descriptor)
        return free
    finally:
        os.close(descriptor)


@dataclass(frozen=True)
class LockPaths:
    directory: Path
    lock: Path
    heartbeat: Path
    guard: Path
    broken: Path

    @classmethod
    def for_root(cls, root: Path) -> "LockPaths":
        directory = root.joinpath(*LOCK_DIRECTORY_PARTS)
        return cls(
            directory,
            directory / LOCK_FILENAME,
            directory / HEARTBEAT_FILENAME,
            directory / GUARD_FILENAME,
            directory / BROKEN_DIRECTORY,
        )


class _Guard:
    """OS lock on the permanent ``install.guard`` for the duration of a ``with``."""

    def __init__(self, path: Path, timeout: float) -> None:
        self.path = path
        self.timeout = timeout
        self._descriptor: Optional[int] = None

    def _open(self) -> int:
        if lstat_inside(self.path) is None:
            try:
                return create_file(self.path)
            except FileExistsError:
                pass
        path_stat = lstat_inside(self.path)
        if path_stat is None or not stat.S_ISREG(path_stat.st_mode):
            raise InstallPathError("path_ineligible", f"{self.path} is not a regular file")
        return _open_existing(self.path)

    def __enter__(self) -> "_Guard":
        try:
            descriptor = self._open()
        except InstallPathError as exc:
            raise LockError(f"lock_{exc.code}", str(exc)) from exc
        except OSError as exc:
            raise LockError("lock_path_unavailable", f"cannot open the guard: {exc}") from exc
        deadline = time.monotonic() + self.timeout
        try:
            while not _os_lock(descriptor):
                if time.monotonic() >= deadline:
                    raise LockError("lock_guard_timeout", "another operation holds the lock guard")
                time.sleep(0.01)
        except _OsLockUnsupported as exc:
            os.close(descriptor)
            raise LockError(
                "lock_unsupported", f"this file system cannot take an OS lock: {exc}"
            ) from exc
        except BaseException:
            os.close(descriptor)
            raise
        self._descriptor = descriptor
        return self

    def __exit__(self, *exc_info: Any) -> None:
        descriptor, self._descriptor = self._descriptor, None
        if descriptor is not None:
            try:
                _os_unlock(descriptor)
            except OSError:
                pass
            os.close(descriptor)


# --- records ----------------------------------------------------------------


def _encode(document: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _epoch(value: Any) -> float:
    install_events._check_timestamp(value, "lock_unreadable")
    text = value if "." in value else value[:-1] + ".0Z"
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def _timestamp(epoch: float) -> str:
    return install_events.utc_timestamp(datetime.fromtimestamp(epoch, timezone.utc))


def validate_metadata(document: Any) -> None:
    """Raise ``LockError("lock_unreadable")`` unless ``document`` is lock metadata."""

    def require(condition: bool, message: str) -> None:
        if not condition:
            raise LockError("lock_unreadable", message)

    require(isinstance(document, dict) and sorted(document) == list(_LOCK_KEYS), "lock fields")
    require(document["protocol"] == LOCK_PROTOCOL, "unknown lock protocol")
    try:
        install_events._check_operation_id(document["operation_id"], "lock_unreadable")
        _epoch(document["created"])
    except install_events.InstallFileError as exc:
        raise LockError("lock_unreadable", str(exc)) from exc
    pid = document["pid"]
    require(isinstance(pid, int) and not isinstance(pid, bool) and pid > 0, "lock pid")
    require(isinstance(document["host"], str) and bool(document["host"]), "lock host")
    token = document["start_token"]
    require(token is None or (isinstance(token, str) and bool(token)), "lock start_token")


def _read_file(path: Path) -> bytes:
    descriptor = os.open(
        path,
        os.O_RDONLY | materialization._binary_flag() | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        chunks: List[bytes] = []
        size = 0
        while size <= _READ_LIMIT:
            chunk = os.read(descriptor, _READ_LIMIT + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _decode(data: bytes) -> Any:
    if len(data) > _READ_LIMIT or not data.endswith(b"\n") or data.startswith(b"\xef\xbb\xbf"):
        raise ValueError("not one complete record")
    return json.loads(data.decode("utf-8"))  # strict: undecodable bytes fail


def read_metadata(path: Path) -> Dict[str, Any]:
    try:
        path_stat = lstat_inside(path)
        if path_stat is None:
            raise LockError("lock_unreadable", "the lock disappeared")
        if not stat.S_ISREG(path_stat.st_mode):
            raise LockError("lock_unreadable", "the lock is not a regular file")
        document = _decode(_read_file(path))
    except (OSError, ValueError, InstallPathError) as exc:
        raise LockError("lock_unreadable", f"cannot read the lock: {exc}") from exc
    validate_metadata(document)
    return document


def read_heartbeat(path: Path) -> Optional[Dict[str, Any]]:
    """The heartbeat record, or ``None`` if absent or not a valid record."""

    try:
        path_stat = lstat_inside(path)
        if path_stat is None or not stat.S_ISREG(path_stat.st_mode):
            return None
        document = _decode(_read_file(path))
        if not isinstance(document, dict) or sorted(document) != list(_HEARTBEAT_KEYS):
            return None
        if document["protocol"] != HEARTBEAT_PROTOCOL:
            return None
        _epoch(document["ts"])
    except (OSError, ValueError, InstallPathError, install_events.InstallFileError):
        return None
    return document


def creation_defect(path: Path) -> Optional[str]:
    """``empty``, ``truncated`` or ``unparseable`` if the lock's content is what a
    creator that died before or during its single metadata write leaves;
    ``None`` otherwise (including complete JSON with invalid fields)."""

    try:
        path_stat = lstat_inside(path)
        if path_stat is None or not stat.S_ISREG(path_stat.st_mode):
            return None
        data = _read_file(path)
    except (OSError, InstallPathError):
        return None
    if not data:
        return "empty"
    if len(data) > _READ_LIMIT:
        return None
    if not data.endswith(b"\n"):
        return "truncated"  # every complete record ends with a newline
    try:
        json.loads(data.decode("utf-8"))
    except ValueError:  # includes UnicodeDecodeError
        return "unparseable"
    return None


# --- judgement --------------------------------------------------------------


@dataclass(frozen=True)
class Judgement:
    status: str  # HELD, STALE, FOREIGN_HOST or UNSUPPORTED
    conditions: Dict[str, Any]


def last_heartbeat(metadata: Mapping[str, Any], heartbeat: Optional[Mapping[str, Any]]) -> float:
    """Epoch of the owner's last sign of life: its heartbeat, else lock creation."""

    last = _epoch(metadata["created"])
    if (
        heartbeat is not None
        and heartbeat.get("operation_id") == metadata["operation_id"]
        and heartbeat.get("pid") == metadata["pid"]
    ):
        last = max(last, _epoch(heartbeat["ts"]))
    return last


def judge(
    metadata: Mapping[str, Any],
    heartbeat: Optional[Mapping[str, Any]],
    *,
    os_lock_free: Optional[bool],
    stale_after: float,
    now: float,
    host: str,
    probe: Callable[[int], process_identity.ProcessProbe],
) -> Judgement:
    """Apply the stale rule. ``os_lock_free=None``: not checked (read-only)."""

    same_host = metadata["host"] == host
    age = now - last_heartbeat(metadata, heartbeat)
    conditions: Dict[str, Any] = {
        "same_host": same_host,
        "os_lock_free": os_lock_free,
        "pid_running": None,
        "start_time_matches": None,
        "heartbeat_age_seconds": age,
        "stale_after_seconds": stale_after,
    }
    if not same_host:
        return Judgement(FOREIGN_HOST, conditions)
    if os_lock_free is False:
        return Judgement(HELD, conditions)
    found = probe(metadata["pid"])
    conditions["pid_running"] = found.running
    if found.running is None:
        return Judgement(UNSUPPORTED, conditions)
    if found.running:
        recorded = metadata["start_token"]
        if recorded is not None and found.start_token is not None:
            conditions["start_time_matches"] = recorded == found.start_token
        if conditions["start_time_matches"] is not False:
            # The same process, or one that cannot be told apart from it.
            return Judgement(HELD, conditions)
    if age <= stale_after:
        return Judgement(HELD, conditions)
    return Judgement(STALE, conditions)


def judge_abandoned(
    path: Path,
    path_stat: os.stat_result,
    *,
    os_lock_free: Optional[bool],
    stale_after: float,
    now: float,
) -> Optional[Judgement]:
    """A ``STALE`` judgement for a lock abandoned during creation, else ``None``.

    ``os_lock_free=None``: not checked (read-only callers).
    """

    defect = creation_defect(path)
    age = now - path_stat.st_mtime
    if defect is None or os_lock_free is False or age <= stale_after:
        return None
    return Judgement(
        STALE,
        {
            "metadata": defect,
            "os_lock_free": os_lock_free,
            "lock_age_seconds": round(age, 3),
            "stale_after_seconds": stale_after,
        },
    )


# --- read-only inspection (verify) -----------------------------------------


@dataclass(frozen=True)
class LockReport:
    lock_status: str
    operation_in_progress: Optional[bool]
    operation_id: Optional[str]
    conditions: Optional[Dict[str, Any]] = None


def inspect_lock(
    root: os.PathLike | str,
    *,
    stale_after: float = DEFAULT_STALE_AFTER,
    now: Optional[float] = None,
    host: Optional[str] = None,
    probe: Optional[Callable[[int], process_identity.ProcessProbe]] = None,
) -> LockReport:
    """Report the lock without taking it, creating or changing anything.

    ``operation_in_progress`` is ``True`` for a held lock, ``False`` when the
    lock is free or stale, and ``None`` when it cannot be judged (unreadable,
    another host, or this platform cannot probe the owner). A lock abandoned
    during creation and older than the bound is ``stale`` with no operation ID;
    without the OS lock this judgement rests on its content and age only.
    """

    now = time.time() if now is None else now
    try:
        directory = check_existing_directories(absolute_root(root), LOCK_DIRECTORY_PARTS)
        if directory is None:
            return LockReport(FREE, False, None)
        lock_path = directory / LOCK_FILENAME
        path_stat = lstat_inside(lock_path)
        if path_stat is None:
            return LockReport(FREE, False, None)
    except InstallPathError:
        return LockReport(UNREADABLE, None, None)
    try:
        metadata = read_metadata(lock_path)
    except LockError:
        abandoned = judge_abandoned(
            lock_path, path_stat, os_lock_free=None, stale_after=stale_after, now=now
        )
        if abandoned is not None:
            return LockReport(STALE, False, None, abandoned.conditions)
        return LockReport(UNREADABLE, None, None)
    judgement = judge(
        metadata,
        read_heartbeat(directory / HEARTBEAT_FILENAME),
        os_lock_free=None,
        stale_after=stale_after,
        now=now,
        host=process_identity.host_name() if host is None else host,
        probe=process_identity.probe_process if probe is None else probe,
    )
    in_progress = {HELD: True, STALE: False}.get(judgement.status)
    return LockReport(judgement.status, in_progress, metadata["operation_id"], judgement.conditions)


# --- the held lock ------------------------------------------------------------


def _write_heartbeat(paths: LockPaths, operation_id: str, pid: int, epoch: float) -> None:
    temp = paths.directory / f"{HEARTBEAT_FILENAME}.{pid}.{uuid.uuid4().hex}.tmp"
    record = {
        "protocol": HEARTBEAT_PROTOCOL,
        "operation_id": operation_id,
        "pid": pid,
        "ts": _timestamp(epoch),
    }
    descriptor = create_file(temp)
    try:
        try:
            os.write(descriptor, _encode(record))
        finally:
            os.close(descriptor)
        os.replace(temp, paths.heartbeat)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


class InstallLock:
    """The held install lock. Release it with :meth:`release` or ``with``."""

    def __init__(
        self,
        root: Path,
        paths: LockPaths,
        metadata: Dict[str, Any],
        descriptor: int,
        identity: Identity,
        heartbeat_interval: float,
        guard_timeout: float,
        clock: Callable[[], float],
    ) -> None:
        self.root = root
        self.paths = paths
        self.metadata = metadata
        self.operation_id: str = metadata["operation_id"]
        self.recovery: Optional[install_journal.RecoveryReport] = None
        self.bootstrap_cleanup: Optional[install_bootstrap.StagingReport] = None
        self.broken: List[Path] = []
        self.last_heartbeat_error: Optional[str] = None
        self.released = False
        self.release_complete: Optional[bool] = None
        self._descriptor: Optional[int] = descriptor
        self._identity = identity
        self._interval = heartbeat_interval
        self._guard_timeout = guard_timeout
        self._clock = clock
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._beat, name="stemwerk-install-heartbeat", daemon=True
        )
        self._thread.start()

    def heartbeat(self) -> None:
        _write_heartbeat(self.paths, self.operation_id, self.metadata["pid"], self._clock())

    def _beat(self) -> None:
        while not self._stop.wait(self._interval):
            try:
                self.heartbeat()
                self.last_heartbeat_error = None
            except Exception as exc:  # retried at the next interval
                self.last_heartbeat_error = f"{type(exc).__name__}: {exc}"

    def _remove_own_heartbeat(self) -> None:
        record = read_heartbeat(self.paths.heartbeat)
        if record is not None and record["operation_id"] == self.operation_id:
            try:
                os.unlink(self.paths.heartbeat)
            except OSError:
                pass

    def _remove_own_lock(self) -> bool:
        for attempt in range(50):
            try:
                path_stat = lstat_inside(self.paths.lock)
            except InstallPathError:
                return False
            if path_stat is None:
                return True
            if not self._identity.matches(path_stat):
                return False
            try:
                os.unlink(self.paths.lock)
                return True
            except PermissionError:
                # Windows: a reader has the file open; it closes it shortly.
                time.sleep(0.02)
            except OSError:
                return False
        return False

    def release(self) -> bool:
        """Release the lock; ``True`` if the lock file was removed too.

        If it could not be removed, the lock stays until this process exits
        and then becomes stale after the bound.
        """

        if self.released:
            return bool(self.release_complete)
        self.released = True
        self._stop.set()
        self._thread.join(self._interval + 5.0)
        descriptor, self._descriptor = self._descriptor, None
        try:
            guard: Any = _Guard(self.paths.guard, self._guard_timeout).__enter__()
        except LockError:
            guard = None  # still safe: a live holder is never judged stale
        try:
            self._remove_own_heartbeat()
            if os.name == "nt":
                # An open handle cannot be removed on Windows: close it first.
                if descriptor is not None:
                    try:
                        _os_unlock(descriptor)
                    except OSError:
                        pass
                    os.close(descriptor)
                self.release_complete = self._remove_own_lock()
            else:
                self.release_complete = self._remove_own_lock()
                if descriptor is not None:
                    os.close(descriptor)  # closing releases the flock
        finally:
            if guard is not None:
                guard.__exit__(None, None, None)
        return bool(self.release_complete)

    def __enter__(self) -> "InstallLock":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.release()


# --- acquiring and breaking -------------------------------------------------


def _broken_records(broken: Path) -> Dict[tuple, List[Path]]:
    groups: Dict[tuple, List[Path]] = {}
    for name in os.listdir(broken):
        match = _BROKEN_NAME.match(name)
        if match is None:
            continue
        key = (match.group(1), match.group(2), int(match.group(3) or 0))
        groups.setdefault(key, []).append(broken / name)
    return groups


def _prune_broken(broken: Path) -> None:
    groups = _broken_records(broken)
    for key in sorted(groups)[: max(len(groups) - MAX_BROKEN_RECORDS, 0)]:
        for path in groups[key]:
            try:
                path_stat = lstat_inside(path)
                if path_stat is not None and stat.S_ISREG(path_stat.st_mode):
                    os.unlink(path)
            except (OSError, InstallPathError):
                pass


def _break(
    root: Path,
    paths: LockPaths,
    identity: Identity,
    metadata: Optional[Mapping[str, Any]],
    heartbeat: Optional[Mapping[str, Any]],
    judgement: Judgement,
    breaker: Mapping[str, Any],
    epoch: float,
    reason: str,
) -> Path:
    """Move a stale lock to ``broken/`` with its record. Call under the guard.

    ``metadata`` is ``None`` for a lock abandoned during creation.
    """

    try:
        ensure_directories(root, (*LOCK_DIRECTORY_PARTS, BROKEN_DIRECTORY))
    except InstallPathError as exc:
        raise LockError(f"lock_{exc.code}", str(exc)) from exc
    stamp = datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    label = ABANDONED_LABEL if metadata is None else metadata["operation_id"]
    base = f"install.{stamp}.{label}"
    name, counter = f"{base}.lock", 0
    while os.path.lexists(paths.broken / name) or os.path.lexists(
        paths.broken / f"{name}.break.json"
    ):
        counter += 1
        name = f"{base}.{counter}.lock"
    target = paths.broken / name
    for attempt in range(50):
        try:
            current = lstat_inside(paths.lock)
        except InstallPathError as exc:
            raise LockError("lock_break_failed", str(exc)) from exc
        if current is None or not identity.matches(current):
            raise LockError("lock_break_failed", "the stale lock changed while it was broken")
        try:
            os.rename(paths.lock, target)
            break
        except PermissionError:
            time.sleep(0.02)  # Windows: a reader has the file open
        except OSError as exc:
            raise LockError("lock_break_failed", f"cannot move the stale lock: {exc}") from exc
    else:
        raise LockError("lock_break_failed", "the stale lock stayed open by a reader")
    record = {
        "protocol": BREAK_PROTOCOL,
        "broken_at": _timestamp(epoch),
        "lock_file": name,
        "reason": reason,
        "lock": None if metadata is None else dict(metadata),
        "heartbeat": None if heartbeat is None else dict(heartbeat),
        "conditions": judgement.conditions,
        "breaker": dict(breaker),
    }
    descriptor = create_file(paths.broken / f"{name}.break.json")
    try:
        os.write(descriptor, _encode(record))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if (
        metadata is not None
        and heartbeat is not None
        and heartbeat.get("operation_id") == metadata["operation_id"]
    ):
        try:
            os.unlink(paths.heartbeat)
        except OSError:
            pass
    _prune_broken(paths.broken)
    return target


def _remove_temp_heartbeats(paths: LockPaths) -> None:
    """Remove heartbeat temporaries of earlier holders; call as the new holder."""

    for name in os.listdir(paths.directory):
        if _TEMP_HEARTBEAT.match(name):
            path = paths.directory / name
            try:
                path_stat = lstat_inside(path)
                if path_stat is not None and stat.S_ISREG(path_stat.st_mode):
                    os.unlink(path)
            except (OSError, InstallPathError):
                pass


def _positive(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not value > 0:
        raise LockError("lock_invalid", f"{name} must be a positive number")
    return float(value)


def acquire(
    root: os.PathLike | str,
    operation_id: str,
    *,
    heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL,
    stale_after: float = DEFAULT_STALE_AFTER,
    guard_timeout: float = DEFAULT_GUARD_TIMEOUT,
    verify_published: Optional[install_journal.PublishedVerifier] = None,
    host: Optional[str] = None,
    probe: Optional[Callable[[int], process_identity.ProcessProbe]] = None,
    clock: Callable[[], float] = time.time,
    on_stale: Optional[Callable[[Judgement], None]] = None,
    before_recovery: Optional[Callable[[], None]] = None,
) -> InstallLock:
    """Take the install lock for ``operation_id``, run journal recovery, then
    remove stale bootstrap staging of crashed outer layers (design O55).

    Fails with ``LockError("lock_held")`` (``details`` has ``lock_status``,
    ``owner`` and ``conditions``) while another operation holds it. A stale
    lock is broken first. ``on_stale`` is a test seam, called under the guard
    after a lock was judged stale and before it is broken. before_recovery
    runs under the lock while the journals of dead operations still exist; if
    it raises, the lock is released and nothing else is recovered.
    """

    try:
        install_events._check_operation_id(operation_id, "lock_invalid")
        root = absolute_root(root)
    except install_events.InstallFileError as exc:
        raise LockError("lock_invalid", str(exc)) from exc
    except InstallPathError as exc:
        raise LockError(f"lock_{exc.code}", str(exc)) from exc
    heartbeat_interval = _positive(heartbeat_interval, "heartbeat_interval")
    stale_after = _positive(stale_after, "stale_after")
    guard_timeout = _positive(guard_timeout, "guard_timeout")
    host = process_identity.host_name() if host is None else host
    probe = process_identity.probe_process if probe is None else probe
    paths = LockPaths.for_root(root)
    pid = os.getpid()
    metadata = {
        "protocol": LOCK_PROTOCOL,
        "operation_id": operation_id,
        "pid": pid,
        "start_token": process_identity.current_start_token(),
        "host": host,
        "created": "",
    }
    breaker = {key: metadata[key] for key in ("operation_id", "pid", "start_token", "host")}
    try:
        ensure_directories(root, LOCK_DIRECTORY_PARTS)
    except InstallPathError as exc:
        raise LockError(f"lock_{exc.code}", str(exc)) from exc

    broken: List[Path] = []
    with _Guard(paths.guard, guard_timeout):
        descriptor: Optional[int] = None
        while descriptor is None:
            try:
                descriptor = create_file(paths.lock)
            except FileExistsError:
                target = _handle_existing(
                    root, paths, stale_after, host, probe, clock, on_stale, breaker
                )
                if target is not None:
                    broken.append(target)
            except InstallPathError as exc:
                raise LockError(f"lock_{exc.code}", str(exc)) from exc
            except OSError as exc:
                raise LockError("lock_path_unavailable", f"cannot create the lock: {exc}") from exc
        try:
            identity = Identity.of(os.lstat(paths.lock))
            try:
                taken = _os_lock(descriptor)
            except _OsLockUnsupported as exc:
                raise LockError(
                    "lock_unsupported", f"this file system cannot take an OS lock: {exc}"
                ) from exc
            if not taken:
                raise LockError("lock_failed", "a new lock file was already locked")
            metadata["created"] = _timestamp(clock())
            os.lseek(descriptor, 0, os.SEEK_SET)
            data = _encode(metadata)
            if os.write(descriptor, data) != len(data):
                raise LockError("lock_failed", "short write to the lock")
            os.fsync(descriptor)
        except BaseException:
            os.close(descriptor)
            try:
                os.unlink(paths.lock)
            except OSError:
                pass
            raise
        _remove_temp_heartbeats(paths)
        try:
            _write_heartbeat(paths, operation_id, pid, clock())
        except OSError:
            pass  # the lock's creation time counts until the next heartbeat
        lock = InstallLock(
            root, paths, metadata, descriptor, identity, heartbeat_interval, guard_timeout, clock
        )
        lock.broken = broken
    try:
        if before_recovery is not None:
            before_recovery()
        lock.recovery = install_journal.recover(
            root, current_operation_id=operation_id, verify_published=verify_published
        )
        lock.bootstrap_cleanup = install_bootstrap.remove_stale_staging(
            root, current_operation_id=operation_id, probe=probe, clock=clock
        )
    except BaseException:
        lock.release()
        raise
    return lock


def _handle_existing(
    root: Path,
    paths: LockPaths,
    stale_after: float,
    host: str,
    probe: Callable[[int], process_identity.ProcessProbe],
    clock: Callable[[], float],
    on_stale: Optional[Callable[[Judgement], None]],
    breaker: Mapping[str, Any],
) -> Optional[Path]:
    """Judge an existing lock under the guard; break it if stale.

    Returns the broken lock's new path, or ``None`` if the lock vanished.
    """

    try:
        path_stat = lstat_inside(paths.lock)
    except InstallPathError as exc:
        raise LockError(f"lock_{exc.code}", str(exc)) from exc
    if path_stat is None:
        return None
    if not stat.S_ISREG(path_stat.st_mode):
        raise LockError("lock_unreadable", "the lock is not a regular file")
    identity = Identity.of(path_stat)
    try:
        free = os_lock_is_free(paths.lock)
    except _OsLockUnsupported as exc:
        raise LockError("lock_unsupported", f"this file system cannot take an OS lock: {exc}") from exc
    except OSError as exc:
        raise LockError("lock_unreadable", f"cannot open the lock: {exc}") from exc
    if free is None:
        return None
    try:
        metadata = read_metadata(paths.lock)
    except LockError as exc:
        abandoned = judge_abandoned(
            paths.lock, path_stat, os_lock_free=free, stale_after=stale_after, now=clock()
        )
        if abandoned is None:
            exc.details.update({"lock_status": UNREADABLE, "os_lock_free": free})
            raise
        if on_stale is not None:
            on_stale(abandoned)
        return _break(root, paths, identity, None, None, abandoned, breaker, clock(),
                      ABANDONED_DURING_CREATION)
    heartbeat = read_heartbeat(paths.heartbeat)
    judgement = judge(
        metadata,
        heartbeat,
        os_lock_free=free,
        stale_after=stale_after,
        now=clock(),
        host=host,
        probe=probe,
    )
    if judgement.status != STALE:
        raise LockError(
            "lock_held",
            f"operation {metadata['operation_id']} holds the install lock",
            {"lock_status": judgement.status, "owner": metadata, "conditions": judgement.conditions},
        )
    if on_stale is not None:
        on_stale(judgement)
    return _break(root, paths, identity, metadata, heartbeat, judgement, breaker, clock(),
                  STALE_OWNER)
