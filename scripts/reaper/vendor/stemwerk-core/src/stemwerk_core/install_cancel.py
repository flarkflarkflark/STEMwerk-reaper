"""Cancellation of a Core installation operation (design D6, section 7.4; slice S8).

The cancel marker ``<root>/logs/<op>/cancel.request`` is the single primary
mechanism on all platforms. Only the front end creates it; Core never
follows, opens, reads or removes it. The probe is ``os.lstat`` only: any
entry at that path counts, including a directory or a dangling symlink, and
only ``ENOENT`` means absent. Another lookup error stops the operation
conservatively and is recorded as a failed check. ``SIGINT``/``SIGTERM`` set
the same internal flag (POSIX fast path); a kill is a crash, not a cancel
(design section 8).

Long subprocesses run in an operation-owned process group (Linux:
``start_new_session``). On cancel the group receives ``SIGTERM``, has at
most ``TERM_GRACE_SECONDS`` to finish, and survivors get ``SIGKILL``; reaping
the direct child and the ``killpg(pgid, 0)`` emptiness check are bounded. A
grandchild that escaped the group with ``setsid()`` cannot be reached — a
documented limitation; the staging it may still write is retained and named
in the result. That retention is durable: the cancelled operation records the
suspected process group, the Linux boot id and the PID namespace in its
journal (``suspect`` record), and every later cleanup path asks
:func:`writer_state` before it removes anything (see there for the rule).
The future Windows implementation maps the group to a Job
Object (``CREATE_NEW_PROCESS_GROUP`` plus ``TerminateProcess`` is the
fallback); there is no ``CTRL_BREAK_EVENT`` dependency.

Downloads poll the marker with a roughly one second interruptible wait: the
response socket is made non-blocking and readability is awaited with
``select`` in ``READ_POLL_SECONDS`` slices (never a socket timeout — a
timed-out ``http.client`` response is unusable afterwards), and data is taken
with ``read1`` so a trickling server neither postpones the marker probe nor
counts as progress. The previous per-read worst case is preserved as the idle
deadline (``IDLE_TIMEOUT_SECONDS``): a server that sends nothing for that
long is a download failure, cancel or not. ``OVERALL_TIMEOUT_SECONDS`` is a
separate fixed ceiling for one whole transfer; callers pass one
``overall_deadline`` per transfer so a trickle cannot extend it indefinitely.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import select
import signal
import socket
import ssl
import subprocess
import threading
import time
from typing import Any, Callable, Dict, Mapping, Optional

CANCEL_FILENAME = "cancel.request"
CANCELLED = "cancelled"

POLL_SECONDS = 0.5  # marker poll quantum while a child process runs
READ_POLL_SECONDS = 1.0  # download readability wait slice (select), not a socket timeout
IDLE_TIMEOUT_SECONDS = 120.0  # previous per-read worst case, kept as the idle deadline
OVERALL_TIMEOUT_SECONDS = 1800.0  # fixed ceiling for one transfer, distinct from idle
TERM_GRACE_SECONDS = 5.0  # at most this long between TERM and KILL
REAP_SECONDS = 5.0  # bounded reaping of the direct child and the group check

_SIGNAL_NAMES = {
    int(signal.SIGINT): "sigint",
    int(signal.SIGTERM): "sigterm",
}


class CancelRequested(Exception):
    """Raised at a safe point when cancellation was requested.

    Deliberately not an ``S6InstallError``: the terminal outcome is
    ``cancelled`` (exit 2), not a failure, and a coincident real error is
    retained as a detail instead (owner decision e).
    """

    def __init__(
        self,
        phase: str,
        reason: str,
        *,
        marker_mtime: Optional[float] = None,
        detected_at: Optional[float] = None,
        check_error: Optional[str] = None,
        child_stop: Optional[Mapping[str, Any]] = None,
    ) -> None:
        super().__init__(f"cancellation requested during {phase} ({reason})")
        self.phase = phase
        self.reason = reason
        self.marker_mtime = marker_mtime
        self.detected_at = detected_at
        self.check_error = check_error
        self.child_stop = dict(child_stop) if child_stop else None

    def details(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"cancel_reason": self.reason}
        if self.marker_mtime is not None and self.detected_at is not None:
            out["detection_seconds"] = round(max(0.0, self.detected_at - self.marker_mtime), 3)
        if self.check_error is not None:
            out["cancel_check_error"] = self.check_error
        if self.child_stop is not None:
            out["child_stop"] = dict(self.child_stop)
        return out


class CancelGuard:
    """One operation's cancellation state: the marker probe and the signal flag."""

    def __init__(
        self,
        operation_dir: Path,
        *,
        hook: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.operation_dir = Path(operation_dir)
        self.marker_path = self.operation_dir / CANCEL_FILENAME
        # Test-only deterministic injection, like the installer's fault_hook:
        # called with the safe-point name just before that point is probed.
        self._hook = hook
        self._signal_reason: Optional[str] = None
        self._marker_mtime: Optional[float] = None
        self._previous_handlers: Optional[Dict[int, Any]] = None
        # The operation's writer ledger (a journal) once staging exists. Every
        # process started through cancellable_run is registered in it BEFORE it
        # is spawned (write-ahead, S8 fix3). ``None`` before staging exists.
        self.writers: Optional[Any] = None

    # -- signal side (optional POSIX fast path, D6) -------------------------

    def signal_received(self, signum: int) -> None:
        self._signal_reason = _SIGNAL_NAMES.get(int(signum), f"signal_{int(signum)}")

    def install_signal_handlers(self) -> None:
        """Map SIGINT/SIGTERM to the flag, remembering the previous handlers.

        Only on POSIX in the main thread; everywhere else the marker stays
        the only mechanism, which D6 allows. Idempotent: a second install
        keeps the first set of previous handlers.
        """

        if self._previous_handlers is not None:
            return
        if os.name == "posix" and threading.current_thread() is threading.main_thread():
            previous: Dict[int, Any] = {}
            for signum in (signal.SIGINT, signal.SIGTERM):
                previous[int(signum)] = signal.getsignal(signum)
                signal.signal(signum, lambda num, _frame: self.signal_received(num))
            self._previous_handlers = previous

    def restore_signal_handlers(self) -> None:
        """Restore the handlers captured by :meth:`install_signal_handlers`.

        Safe to call more than once and safe without a prior install.
        """

        previous = self._previous_handlers
        self._previous_handlers = None
        if not previous:
            return
        if os.name != "posix" or threading.current_thread() is not threading.main_thread():
            return
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except (OSError, ValueError):
                pass

    # -- marker side ----------------------------------------------------------

    def requested(self) -> Optional[Dict[str, Any]]:
        """``None`` when no cancel is pending, else the reason record.

        The marker is probed with ``os.lstat`` only: any entry counts, only
        ``ENOENT`` means absent, and the entry is never followed, opened,
        read or removed. Another lookup error stops the operation
        conservatively and is recorded as a failed check.
        """

        if self._signal_reason is not None:
            return {"reason": self._signal_reason}
        try:
            probe = os.lstat(self.marker_path)
        except FileNotFoundError:
            return None
        except OSError as exc:
            return {"reason": "check_failed", "check_error": f"{type(exc).__name__}: {exc}"}
        if self._marker_mtime is None:
            self._marker_mtime = probe.st_mtime
        return {"reason": "marker", "marker_mtime": self._marker_mtime}

    def check(self, phase: str, point: Optional[str] = None) -> None:
        """Safe point: raise :class:`CancelRequested` when a cancel is pending."""

        if point is not None and self._hook is not None:
            self._hook(point)
        hit = self.requested()
        if hit is not None:
            raise CancelRequested(
                phase,
                hit["reason"],
                marker_mtime=hit.get("marker_mtime"),
                detected_at=time.time(),
                check_error=hit.get("check_error"),
            )


def cancel_from_hit(phase: str, hit: Mapping[str, Any]) -> CancelRequested:
    """Rebuild the exception for a pending request found after a real error.

    Used when a real error and the marker coincide before the terminal
    result is decided: cancelled wins and the error rides along as a detail
    (owner decision e).
    """

    return CancelRequested(
        phase,
        str(hit.get("reason", "marker")),
        marker_mtime=hit.get("marker_mtime"),
        detected_at=time.time(),
        check_error=hit.get("check_error"),
    )


class WriterIntentError(Exception):
    """The durable writer intent could not be recorded, so the process was not started."""

    def __init__(self, message: str, phase: str = "install_packages") -> None:
        super().__init__(message)
        self.phase = phase


# -- suspected writers: when may a later operation clean up? ---------------

WRITER_GONE = "gone"
WRITER_ALIVE = "alive"
WRITER_UNKNOWN = "unknown"

_BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"
_PID_NAMESPACE_PATH = "/proc/self/ns/pid"


def current_boot_id() -> Optional[str]:
    """The Linux boot id, or ``None`` where it cannot be read."""

    try:
        with open(_BOOT_ID_PATH, "rb") as handle:
            value = handle.read(256).decode("ascii").strip()
    except (OSError, UnicodeDecodeError):
        return None
    return value or None


def current_pid_namespace() -> Optional[str]:
    """Identity of this process's PID namespace (``pid:[inode]``), or ``None``."""

    try:
        return os.readlink(_PID_NAMESPACE_PATH) or None
    except OSError:
        return None


_PID_NAMESPACE_FORM = re.compile(r"pid:\[[1-9][0-9]*\]")
_BOOT_ID_FORM = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def valid_pid_namespace(value: Any) -> bool:
    """A usable PID-namespace identity: exactly ``pid:[<inode>]``. Empty, malformed
    or unreadable identities never count, in a record or for the observer."""

    return isinstance(value, str) and _PID_NAMESPACE_FORM.fullmatch(value) is not None


def valid_boot_id(value: Any) -> bool:
    """A usable Linux boot id (the kernel's lowercase UUID)."""

    return isinstance(value, str) and _BOOT_ID_FORM.fullmatch(value) is not None


def proc_view_is_own() -> bool:
    """Whether ``/proc`` numbers processes in this process's own PID namespace.

    ``/proc/self/status`` ``NSpid`` lists this process's id in every namespace
    from the one ``/proc`` belongs to down to its own: exactly one entry, equal
    to :func:`os.getpid`, means the two are the same. A ``/proc`` lookup of a
    recorded PID proves absence only then; a missing line (kernel before 4.1)
    or an unreadable file counts as not established."""

    try:
        with open("/proc/self/status", "rb") as handle:
            for raw in handle.read(65536).decode("ascii", "replace").splitlines():
                if raw.startswith("NSpid:"):
                    return raw.split()[1:] == [str(os.getpid())]
    except OSError:
        return False
    return False


def writer_state(
    pgid: Any,
    boot_id: Optional[str],
    pid_namespace: Optional[str] = None,
) -> "tuple[str, str]":
    """May the writer a cancelled operation could not rule out still run?

    Returns ``(state, reason)``. Staging a writer may still write is removed
    only on ``WRITER_GONE``, which needs one of two proofs (S8 fix4 rule):

    - the recorded boot id and the current one are both well formed and
      differ: every process of that boot is gone. This removes the
      writer-liveness objection only; ownership, age and journal conditions
      stay with the callers.
    - ``killpg(pgid, 0)`` answers ``ESRCH`` AND the observer's PID namespace
      (``/proc/self/ns/pid`` of this process) is positively identical to the
      namespace recorded with the PGID AND the boot is positively the same.
      A PGID is a number in one PID namespace: from any other namespace
      ``ESRCH`` says nothing about the writer.

    Everything else keeps the staging and names why: a live group, ``EPERM``
    or any other probe error (the writer may exist), a recorded or observer
    namespace that is missing, malformed or different, a boot that is not
    positively the same, an unusable group id, a platform without process
    groups. Records from earlier candidates without a namespace are no proof.
    The rule can only keep staging longer, never remove it earlier. A reused
    group id likewise only keeps staging longer. A writer that left the group
    with ``setsid()`` is invisible to this check, as it is to
    :func:`stop_process_group` (documented limitation).
    """

    current_boot = current_boot_id()
    boots_known = valid_boot_id(boot_id) and valid_boot_id(current_boot)
    if boots_known and boot_id != current_boot:
        return WRITER_GONE, "boot_id_changed"
    if os.name != "posix":
        return WRITER_UNKNOWN, "process_groups_unavailable"
    # Group 0 would signal our own group and group 1 is init's: neither can
    # be a recorded cancelled child, so such a record is unusable, not "alive".
    if not isinstance(pgid, int) or isinstance(pgid, bool) or pgid <= 1:
        return WRITER_UNKNOWN, "no_process_group_recorded"
    if not valid_pid_namespace(pid_namespace):
        return WRITER_UNKNOWN, "pid_namespace_unrecorded"
    current_namespace = current_pid_namespace()
    if not valid_pid_namespace(current_namespace):
        return WRITER_UNKNOWN, "pid_namespace_unreadable"
    if pid_namespace != current_namespace:
        return WRITER_UNKNOWN, "pid_namespace_differs"
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        if boots_known:  # and equal: a different boot returned above
            return WRITER_GONE, "process_group_gone"
        return WRITER_UNKNOWN, "boot_id_unavailable"
    except PermissionError:
        return WRITER_ALIVE, "process_group_exists_not_signalable"
    except OSError as exc:
        return WRITER_UNKNOWN, f"process_group_probe_failed: {type(exc).__name__}"
    return WRITER_ALIVE, "process_group_alive"


def group_gone(pgid: int) -> Optional[bool]:
    """``True`` when ``killpg(pgid, 0)`` answers ``ESRCH``; ``False`` while the
    group has members (or is not ours: ``EPERM``); ``None`` when unanswerable."""

    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except OSError:
        return None
    return False


def confirm_group_gone(
    pgid: int,
    *,
    term_grace: float = 2.0,
    kill_wait: float = 3.0,
) -> bool:
    """Bounded: is the group empty, after asking its remaining members to stop?

    Used after a writer's direct child was reaped. A normal exit leaves the
    group empty at once; a daemonised leftover gets TERM, a short grace, then
    KILL and a short wait. ``False`` means emptiness could not be shown within
    ``term_grace + kill_wait`` seconds.
    """

    if pgid <= 1:
        return False
    if group_gone(pgid):
        return True
    for sig, wait in ((signal.SIGTERM, term_grace), (signal.SIGKILL, kill_wait)):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.monotonic() + wait
        while True:
            state = group_gone(pgid)
            if state:
                return True
            if state is None or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
    return bool(group_gone(pgid))


def stop_process_group(
    proc: "subprocess.Popen[Any]",
    *,
    grace: float = TERM_GRACE_SECONDS,
    reap: float = REAP_SECONDS,
) -> Dict[str, Any]:
    """TERM the child's process group, then KILL survivors; bounded reaping.

    Returns the measured shutdown time and whether survivors are suspected
    (the group still non-empty, or the direct child would not reap). The
    caller keeps the staging a suspected survivor may still write.
    """

    started = time.monotonic()
    survivors_suspected = False
    if os.name == "posix":
        pgid = proc.pid  # start_new_session made the child the group leader
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = started + grace
        while proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        # Escalate against the GROUP, not only against a live leader: a
        # TERM-responsive leader may exit while a TERM-ignoring grandchild
        # still sits in the group. killpg(pgid, 0) answers ESRCH once empty.
        try:
            os.killpg(pgid, 0)
            group_alive = True
        except ProcessLookupError:
            group_alive = False
        except PermissionError:
            group_alive = False
            survivors_suspected = True
        if group_alive:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            proc.wait(timeout=reap)
        except subprocess.TimeoutExpired:
            survivors_suspected = True
        # killpg(pgid, 0) answers ESRCH once the group is empty; bound the check.
        group_deadline = time.monotonic() + reap
        while True:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                break
            except PermissionError:
                survivors_suspected = True
                break
            if time.monotonic() >= group_deadline:
                survivors_suspected = True
                break
            time.sleep(0.05)
    else:  # Windows: TerminateProcess fallback until the Job Object design lands
        proc.terminate()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=reap)
            except subprocess.TimeoutExpired:
                survivors_suspected = True
    return {
        "shutdown_seconds": round(time.monotonic() - started, 3),
        "survivors_suspected": survivors_suspected,
        "pgid": proc.pid if os.name == "posix" else None,
    }


def _finish_writer(
    registry: Any, token: Any, proc: "subprocess.Popen[Any]", *, escalate: bool
) -> None:
    """Close the writer record, but only once the direct child is reaped AND the
    group is confirmed empty (``ESRCH``). Anything less leaves the intent open,
    which keeps the staging protected. Never raises: a failed append (or an
    unreaped child) simply leaves the writer unresolved."""

    try:
        if proc.poll() is None:
            return  # not reaped: the writer is not proven gone
        pgid = proc.pid  # start_new_session made the child its own group leader
        if os.name == "posix":
            gone = confirm_group_gone(pgid) if escalate else bool(group_gone(pgid))
            if not gone:
                return
        registry.writer_closed(token)
    except Exception:
        return


def cancellable_run(
    guard: CancelGuard,
    phase: str,
    command: Any,
    *,
    timeout: Optional[float] = None,
    grace: float = TERM_GRACE_SECONDS,
    poll: float = POLL_SECONDS,
    **popen_kwargs: Any,
) -> subprocess.CompletedProcess:
    """``subprocess.run`` that honours the cancel guard while the child runs.

    The child is isolated in an operation-owned process group
    (``start_new_session`` on POSIX); the marker is polled every ``poll``
    seconds; on cancel the group is TERMed then KILLed and the measured stop
    rides along in :class:`CancelRequested`. The ``timeout`` and ``check``
    semantics of ``subprocess.run`` are preserved.

    Write-ahead (S8 fix3): when the guard carries a writer ledger (the
    operation's journal), the writer's intent is made durable BEFORE the child
    is spawned (:class:`WriterIntentError` and no spawn if that fails); the
    group id is recorded right after the spawn (a failure there is tolerated:
    the open intent already protects the staging); and the record is closed
    only after the direct child was reaped and the group is gone.
    """

    check = bool(popen_kwargs.pop("check", False))
    if popen_kwargs.pop("capture_output", False):
        popen_kwargs.setdefault("stdout", subprocess.PIPE)
        popen_kwargs.setdefault("stderr", subprocess.PIPE)
    if os.name == "posix":
        popen_kwargs.setdefault("start_new_session", True)
    registry = guard.writers if os.name == "posix" and popen_kwargs.get("start_new_session") else None
    token = None
    if registry is not None:
        try:
            token = registry.begin_writer([str(part) for part in command[:1]])
        except Exception as exc:
            raise WriterIntentError(
                f"the writer intent could not be recorded, so nothing was started: {type(exc).__name__}: {exc}",
                phase,
            ) from exc
    try:
        proc = subprocess.Popen(command, **popen_kwargs)
    except BaseException:
        if token is not None:
            try:
                registry.writer_closed(token)  # nothing was spawned: provably no writer
            except Exception:
                pass
        raise
    if token is not None:
        try:
            registry.writer_spawned(token, proc.pid)
        except Exception:
            pass  # the open intent protects the staging until the group is proven gone
    escalate = True
    try:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            try:
                stdout, stderr = proc.communicate(timeout=poll)
                break
            except subprocess.TimeoutExpired:
                pass
            hit = guard.requested()
            if hit is not None:
                escalate = False  # stop_process_group already escalated and measured
                stop = stop_process_group(proc, grace=grace)
                raise CancelRequested(
                    phase,
                    hit["reason"],
                    marker_mtime=hit.get("marker_mtime"),
                    detected_at=time.time(),
                    check_error=hit.get("check_error"),
                    child_stop={"command": [str(part) for part in command[:1]], **stop},
                )
            if deadline is not None and time.monotonic() >= deadline:
                escalate = False
                stop_process_group(proc, grace=grace)
                raise subprocess.TimeoutExpired(command, timeout)
    finally:
        if token is not None:
            _finish_writer(registry, token, proc, escalate=escalate)
    completed = subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
    if check and completed.returncode:
        raise subprocess.CalledProcessError(
            completed.returncode, command, output=completed.stdout, stderr=completed.stderr
        )
    return completed


def _response_socket(reader: Any) -> "Optional[socket.socket]":
    """The socket under a urllib/http.client response; ``None`` for a regular
    file or a test double."""

    try:
        return reader.fp.raw._sock  # http.client.HTTPResponse down to the socket
    except AttributeError:
        return None


def _has_buffered(reader: Any) -> bool:
    """Whether the response's buffered reader already holds bytes locally."""

    fp = getattr(reader, "fp", None)
    peek = getattr(fp, "peek", None)
    if peek is None:
        return False
    try:
        return bool(peek(1))
    except (BlockingIOError, ssl.SSLWantReadError, OSError, ValueError):
        return False


def read_download_chunk(
    reader: Any,
    size: int,
    check: Callable[[], None],
    *,
    idle_deadline: float,
    idle_error: Callable[[], Exception],
    overall_deadline: Optional[float] = None,
    overall_error: Optional[Callable[[], Exception]] = None,
) -> bytes:
    """One download chunk with the roughly-one-second interruptible wait.

    ``check`` is the cancel probe (it raises when a cancel is pending). On a
    real HTTP response the socket is made non-blocking for the duration of the
    call and readability is awaited with ``select`` in ``READ_POLL_SECONDS``
    slices — never with a socket timeout, because a timed-out
    ``http.client`` response object is unusable afterwards. Data is taken with
    ``read1``, which returns what has arrived (down to a single byte) instead
    of waiting to fill ``size``, so a trickling server neither postpones the
    marker probe nor looks like progress forever: ``idle_deadline`` fires only
    when nothing at all arrives, and ``overall_deadline`` (a fixed point for
    the whole transfer, supplied by the caller) bounds the transfer as a
    whole. Readers without a reachable socket (regular files, test doubles)
    keep the pre-S8 blocking read with the probe before and after.
    """

    sock = _response_socket(reader)
    if sock is None:
        while True:
            check()
            if time.monotonic() >= idle_deadline:
                raise idle_error()
            try:
                chunk = reader.read(size)
                break
            except (socket.timeout, TimeoutError):
                continue
        check()
        return chunk

    read1 = getattr(reader, "read1", None) or reader.read
    try:
        previous = sock.gettimeout()
    except OSError:
        previous = None
    try:
        sock.setblocking(False)
        while True:
            check()
            now = time.monotonic()
            if now >= idle_deadline:
                raise idle_error()
            if overall_deadline is not None and now >= overall_deadline:
                raise (overall_error or idle_error)()
            # read1 on a non-blocking socket answers b"" both at EOF and on
            # would-block, so only read when the buffer holds bytes or select
            # reports readability; then b"" can only mean EOF.
            if not _has_buffered(reader):
                readable, _, _ = select.select([sock], [], [], READ_POLL_SECONDS)
                if not readable:
                    continue
            try:
                chunk = read1(size)
            except (BlockingIOError, ssl.SSLWantReadError):
                # a partial TLS record: not really readable yet
                continue
            break
    finally:
        try:
            sock.settimeout(previous)  # also restores blocking mode
        except OSError:
            pass
    check()
    return chunk


def idle_deadline_from_now() -> float:
    return time.monotonic() + IDLE_TIMEOUT_SECONDS
