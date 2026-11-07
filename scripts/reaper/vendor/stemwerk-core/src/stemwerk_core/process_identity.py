"""Is a process running, and is it still the process that was recorded?

A PID alone does not identify a process: once it exits, the PID can be given
to another one. A recorded PID is therefore paired with a start token, an
opaque string derived from the process's start time, so a reused PID is
recognized by a different token.

Start tokens, standard library only:

- Linux: field 22 of ``/proc/<pid>/stat`` (start time in clock ticks since
  boot) together with ``/proc/sys/kernel/random/boot_id``.
- macOS: ``proc_pidinfo(PROC_PIDTBSDINFO)`` through ctypes, the start time in
  seconds and microseconds.
- Windows: ``GetProcessTimes`` creation time through ctypes, on a handle
  from ``OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE)``;
  ``SYNCHRONIZE`` lets ``WaitForSingleObject`` tell whether it has exited.

``os.kill(pid, 0)`` is used only on POSIX. On Windows it is never called:
CPython maps every signal other than CTRL_C_EVENT and CTRL_BREAK_EVENT to
``TerminateProcess``, so it would kill the process it asks about.

Every answer may be unknown (``None``); callers must treat an unknown answer
as "cannot prove the process is gone".
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import socket
import sys
from typing import Any, Optional


@dataclass(frozen=True)
class ProcessProbe:
    """``running`` is ``None`` when it cannot be determined; ``start_token``
    is ``None`` when the process is not running or its start time is unknown."""

    running: Optional[bool]
    start_token: Optional[str]


def host_name() -> str:
    return socket.gethostname()


def _check_pid(pid: Any) -> int:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise ValueError("pid must be a positive integer")
    return pid


# --- POSIX -------------------------------------------------------------------


def _posix_running(pid: int) -> Optional[bool]:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return None
    return True


def _linux_probe(pid: int, proc: str = "/proc") -> ProcessProbe:
    try:
        with open(f"{proc}/{pid}/stat", "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        return ProcessProbe(False, None)
    except OSError:
        return ProcessProbe(_posix_running(pid), None)
    # The command name (field 2) is in parentheses and may contain spaces or
    # parentheses itself, so fields are counted after the last ')'.
    fields = data[data.rfind(b")") + 2 :].split()
    if len(fields) < 20:
        return ProcessProbe(_posix_running(pid), None)
    if fields[0] in (b"Z", b"X"):
        # Exited, not yet reaped: it holds no files or locks any more.
        return ProcessProbe(False, None)
    try:
        start_ticks = int(fields[19])
        with open(f"{proc}/sys/kernel/random/boot_id", "rb") as handle:
            boot_id = handle.read().decode("ascii").strip()
    except (OSError, ValueError, UnicodeDecodeError):
        return ProcessProbe(True, None)
    if not boot_id:
        return ProcessProbe(True, None)
    return ProcessProbe(True, f"linux:{boot_id}:{start_ticks}")


# struct proc_bsdinfo from <sys/proc_info.h>.
_PROC_PIDTBSDINFO = 3
_MAXCOMLEN = 16
_SZOMB = 5


def _darwin_bsdinfo_type() -> Any:
    import ctypes

    class ProcBsdInfo(ctypes.Structure):
        _fields_ = [
            ("pbi_flags", ctypes.c_uint32),
            ("pbi_status", ctypes.c_uint32),
            ("pbi_xstatus", ctypes.c_uint32),
            ("pbi_pid", ctypes.c_uint32),
            ("pbi_ppid", ctypes.c_uint32),
            ("pbi_uid", ctypes.c_uint32),
            ("pbi_gid", ctypes.c_uint32),
            ("pbi_ruid", ctypes.c_uint32),
            ("pbi_rgid", ctypes.c_uint32),
            ("pbi_svuid", ctypes.c_uint32),
            ("pbi_svgid", ctypes.c_uint32),
            ("rfu_1", ctypes.c_uint32),
            ("pbi_comm", ctypes.c_char * _MAXCOMLEN),
            ("pbi_name", ctypes.c_char * (2 * _MAXCOMLEN)),
            ("pbi_nfiles", ctypes.c_uint32),
            ("pbi_pgid", ctypes.c_uint32),
            ("pbi_pjobc", ctypes.c_uint32),
            ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32),
            ("pbi_nice", ctypes.c_int32),
            ("pbi_start_tvsec", ctypes.c_uint64),
            ("pbi_start_tvusec", ctypes.c_uint64),
        ]

    return ProcBsdInfo


def _darwin_proc_pidinfo() -> Any:
    import ctypes

    error: Optional[Exception] = None
    # libproc is a re-export of libSystem; either name resolves the symbol.
    for name in ("/usr/lib/libproc.dylib", "/usr/lib/libSystem.B.dylib"):
        try:
            return ctypes.CDLL(name, use_errno=True).proc_pidinfo
        except (OSError, AttributeError) as exc:
            error = exc
    raise OSError(f"proc_pidinfo is unavailable: {error}")


def _darwin_probe(pid: int) -> ProcessProbe:
    running = _posix_running(pid)
    if running is not True:
        return ProcessProbe(running, None)
    try:
        import ctypes

        proc_pidinfo = _darwin_proc_pidinfo()
        proc_pidinfo.argtypes = (
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        )
        proc_pidinfo.restype = ctypes.c_int
        info = _darwin_bsdinfo_type()()
        size = ctypes.sizeof(info)
        written = proc_pidinfo(pid, _PROC_PIDTBSDINFO, 0, ctypes.byref(info), size)
    except (OSError, AttributeError):
        return ProcessProbe(True, None)
    if written != size:
        # ESRCH here means it exited between the two calls.
        if written <= 0 and ctypes.get_errno() == 3:
            return ProcessProbe(False, None)
        return ProcessProbe(True, None)
    if info.pbi_status == _SZOMB:
        return ProcessProbe(False, None)
    return ProcessProbe(True, f"darwin:{info.pbi_start_tvsec}.{info.pbi_start_tvusec:06d}")


# --- Windows -----------------------------------------------------------------

_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_SYNCHRONIZE = 0x00100000
_ERROR_ACCESS_DENIED = 5
_ERROR_INVALID_PARAMETER = 87
_WAIT_OBJECT_0 = 0
_WAIT_TIMEOUT = 0x102


class _WindowsProcessApi:
    """The four kernel32 calls the Windows probe needs, through ctypes."""

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._wintypes = wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        filetime = ctypes.POINTER(wintypes.FILETIME)
        kernel32.GetProcessTimes.argtypes = (wintypes.HANDLE, filetime, filetime, filetime, filetime)
        kernel32.GetProcessTimes.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL
        self._kernel32 = kernel32

    def open(self, pid: int) -> tuple[Any, int]:
        handle = self._kernel32.OpenProcess(
            _PROCESS_QUERY_LIMITED_INFORMATION | _SYNCHRONIZE, False, pid
        )
        if handle:
            return handle, 0
        return None, self._ctypes.get_last_error()

    def has_exited(self, handle: Any) -> Optional[bool]:
        result = self._kernel32.WaitForSingleObject(handle, 0)
        if result == _WAIT_OBJECT_0:
            return True
        if result == _WAIT_TIMEOUT:
            return False
        return None

    def creation_time(self, handle: Any) -> Optional[int]:
        times = [self._wintypes.FILETIME() for _ in range(4)]
        ok = self._kernel32.GetProcessTimes(handle, *(self._ctypes.byref(t) for t in times))
        if not ok:
            return None
        return (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime

    def close(self, handle: Any) -> None:
        self._kernel32.CloseHandle(handle)


def _windows_probe(pid: int, api: Any = None) -> ProcessProbe:
    try:
        api = _WindowsProcessApi() if api is None else api
    except (OSError, AttributeError):
        return ProcessProbe(None, None)
    handle, error = api.open(pid)
    if handle is None:
        if error == _ERROR_INVALID_PARAMETER:
            return ProcessProbe(False, None)
        if error == _ERROR_ACCESS_DENIED:
            return ProcessProbe(True, None)
        return ProcessProbe(None, None)
    try:
        exited = api.has_exited(handle)
        if exited is None:
            return ProcessProbe(None, None)
        if exited:
            return ProcessProbe(False, None)
        created = api.creation_time(handle)
        return ProcessProbe(True, None if created is None else f"win32:{created}")
    finally:
        api.close(handle)


# --- dispatch ----------------------------------------------------------------


def probe_process(pid: int, *, platform: Optional[str] = None) -> ProcessProbe:
    """Whether ``pid`` is running and its start token, for this host only."""

    pid = _check_pid(pid)
    platform = sys.platform if platform is None else platform
    if platform == "win32":
        return _windows_probe(pid)
    if platform.startswith("linux") and os.path.exists("/proc/self/stat"):
        return _linux_probe(pid)
    if platform == "darwin":
        return _darwin_probe(pid)
    if os.name == "posix":
        return ProcessProbe(_posix_running(pid), None)
    return ProcessProbe(None, None)


def current_start_token() -> Optional[str]:
    """The start token of this process, or ``None`` when it cannot be read."""

    return probe_process(os.getpid()).start_token
