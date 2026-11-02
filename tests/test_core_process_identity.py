"""Tests for the process liveness and start-token probe used by the install lock."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import process_identity as identity  # noqa: E402

pytestmark = pytest.mark.portable


def dead_pid() -> int:
    """The PID of a child that has exited and been reaped."""

    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait(timeout=60)
    return child.pid


def forbid_os_kill(monkeypatch):
    calls = []

    def refuse(*args):
        calls.append(args)
        raise AssertionError("os.kill must never be used on the Windows path")

    monkeypatch.setattr(os, "kill", refuse)
    return calls


@pytest.mark.native_publication
def test_current_process_has_a_stable_start_token():
    first = identity.probe_process(os.getpid())
    second = identity.probe_process(os.getpid())
    assert first.running is True
    assert first.start_token is not None
    assert first == second
    assert identity.current_start_token() == first.start_token
    prefix = {"win32": "win32:", "darwin": "darwin:"}.get(sys.platform, "linux:")
    assert first.start_token.startswith(prefix)


@pytest.mark.native_publication
def test_a_running_child_has_its_own_token_and_none_after_exit():
    child = subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE
    )
    try:
        running = identity.probe_process(child.pid)
        assert running.running is True
        assert running.start_token is not None
        assert running.start_token != identity.current_start_token()
        assert identity.probe_process(child.pid) == running
    finally:
        child.stdin.close()
        child.wait(timeout=60)
    gone = identity.probe_process(child.pid)
    assert gone == identity.ProcessProbe(False, None)


@pytest.mark.native_publication
def test_a_non_existent_pid_is_not_running():
    assert identity.probe_process(dead_pid()) == identity.ProcessProbe(False, None)


@pytest.mark.native_publication
@pytest.mark.parametrize("pid", [0, -1, True, 1.5, "12"])
def test_invalid_pids_are_rejected(pid):
    with pytest.raises(ValueError):
        identity.probe_process(pid)


@pytest.mark.native_publication
def test_windows_dispatch_never_calls_os_kill(monkeypatch):
    calls = forbid_os_kill(monkeypatch)
    found = identity.probe_process(os.getpid(), platform="win32")
    assert calls == []
    if sys.platform == "win32":
        assert found.running is True and found.start_token.startswith("win32:")
    else:
        assert found == identity.ProcessProbe(None, None)  # no kernel32 here


class FakeWindowsApi:
    def __init__(self, *, open_error=0, exited=False, created=132_000_000_000_000_000):
        self.open_error = open_error
        self.exited = exited
        self.created = created
        self.closed = []

    def open(self, pid):
        return (None, self.open_error) if self.open_error else ("handle", 0)

    def has_exited(self, handle):
        return self.exited

    def creation_time(self, handle):
        return self.created

    def close(self, handle):
        self.closed.append(handle)


@pytest.mark.native_publication
@pytest.mark.parametrize(
    "api, expected, closed",
    [
        (FakeWindowsApi(), identity.ProcessProbe(True, "win32:132000000000000000"), ["handle"]),
        (FakeWindowsApi(created=None), identity.ProcessProbe(True, None), ["handle"]),
        (FakeWindowsApi(exited=True), identity.ProcessProbe(False, None), ["handle"]),
        (FakeWindowsApi(exited=None), identity.ProcessProbe(None, None), ["handle"]),
        (FakeWindowsApi(open_error=87), identity.ProcessProbe(False, None), []),
        (FakeWindowsApi(open_error=5), identity.ProcessProbe(True, None), []),
        (FakeWindowsApi(open_error=6), identity.ProcessProbe(None, None), []),
    ],
)
def test_windows_probe_mapping_without_os_kill(monkeypatch, api, expected, closed):
    calls = forbid_os_kill(monkeypatch)
    assert identity._windows_probe(1234, api) == expected
    assert api.closed == closed
    assert calls == []


def fake_proc(tmp_path, pid, stat_line, boot_id="0d1c-boot\n"):
    proc = tmp_path / "proc"
    (proc / str(pid)).mkdir(parents=True)
    (proc / str(pid) / "stat").write_bytes(stat_line)
    if boot_id is not None:
        (proc / "sys" / "kernel" / "random").mkdir(parents=True)
        (proc / "sys" / "kernel" / "random" / "boot_id").write_bytes(boot_id.encode())
    return str(proc)


def stat_line(comm: bytes, state: bytes, start: int) -> bytes:
    # pid (comm) state, then fields 4..21, field 22 = start time, then more.
    rest = [b"1"] * 18 + [str(start).encode()] + [b"0"] * 10
    return b"4242 (" + comm + b") " + state + b" " + b" ".join(rest) + b"\n"


@pytest.mark.native_publication
@pytest.mark.parametrize("comm", [b"python", b"a b", b"x) (y", b")"])
def test_linux_start_token_is_field_22_after_the_last_parenthesis(tmp_path, comm):
    proc = fake_proc(tmp_path, 4242, stat_line(comm, b"S", 987654))
    assert identity._linux_probe(4242, proc) == identity.ProcessProbe(
        True, "linux:0d1c-boot:987654"
    )


@pytest.mark.native_publication
@pytest.mark.parametrize("state", [b"Z", b"X"])
def test_linux_exited_but_unreaped_process_is_not_running(tmp_path, state):
    proc = fake_proc(tmp_path, 4242, stat_line(b"python", state, 1))
    assert identity._linux_probe(4242, proc) == identity.ProcessProbe(False, None)


@pytest.mark.native_publication
def test_linux_missing_process_and_missing_boot_id(tmp_path):
    proc = fake_proc(tmp_path, 4242, stat_line(b"python", b"R", 5), boot_id=None)
    assert identity._linux_probe(4242, proc) == identity.ProcessProbe(True, None)
    assert identity._linux_probe(4343, proc) == identity.ProcessProbe(False, None)


@pytest.mark.native_publication
def test_host_name_is_text():
    assert isinstance(identity.host_name(), str) and identity.host_name()
