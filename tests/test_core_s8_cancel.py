"""Tests for the S8 cancellation slice (design D6, section 7.4).

The marker ``<root>/logs/<op>/cancel.request`` is probed with ``os.lstat``
only, long subprocesses run in an operation-owned process group, downloads
wait interruptibly, and a honoured cancel ends in exit 2 with
``error.code == "cancelled"`` and exactly one terminal result.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import (  # noqa: E402
    install_bootstrap,
    install_cancel,
    install_events,
    install_journal,
    install_lock,
    install_preflight,
    managed_ffmpeg,
    module_installer,
    module_registry,
    module_verify,
    process_identity,
    runtime_manifest,
    wheel_lock,
)
from tests import ffmpeg_fixture  # noqa: E402
from tests.test_core_s6_linux_install import _prepare_fake_install  # noqa: E402
from tests.test_core_s7_linux_ffmpeg import _make_s6_only_root  # noqa: E402

pytestmark = pytest.mark.portable
POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="process groups, signals and POSIX links")


def _plan(root, facts):
    return install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")


def _read_result(op_dir):
    return json.loads((op_dir / install_events.RESULT_FILENAME).read_bytes().decode("utf-8"))


# --- 1. The marker probe (owner decision a) -----------------------------------


def test_guard_reports_absent_file_and_directory_markers(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    guard = install_cancel.CancelGuard(op_dir)
    assert guard.requested() is None

    marker = op_dir / install_cancel.CANCEL_FILENAME
    marker.touch()
    hit = guard.requested()
    assert hit is not None and hit["reason"] == "marker" and hit["marker_mtime"] > 0
    with pytest.raises(install_cancel.CancelRequested) as raised:
        guard.check("publish")
    assert raised.value.phase == "publish" and raised.value.reason == "marker"
    # Core never removes the marker (decision a).
    assert marker.exists()

    marker.unlink()
    marker.mkdir()
    directory_hit = guard.requested()
    # A directory counts as a marker, not as a failed check: the probe must
    # not open or read the entry (owner decision a).
    assert directory_hit is not None and directory_hit["reason"] == "marker"


@POSIX_ONLY
def test_guard_counts_a_dangling_symlink_without_following_it(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    target = tmp_path / "does-not-exist"
    os.symlink(target, op_dir / install_cancel.CANCEL_FILENAME)
    guard = install_cancel.CancelGuard(op_dir)
    hit = guard.requested()
    assert hit is not None and hit["reason"] == "marker"
    assert not target.exists()  # never followed, opened or read


def test_a_lookup_error_stops_the_operation_conservatively(tmp_path, monkeypatch):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    guard = install_cancel.CancelGuard(op_dir)
    real_lstat = os.lstat

    def denied(path, *args, **kwargs):
        if Path(path) == guard.marker_path:
            raise PermissionError("simulated EACCES on the marker directory")
        return real_lstat(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", denied)
    with pytest.raises(install_cancel.CancelRequested) as raised:
        guard.check("fetch_assets")
    assert raised.value.reason == "check_failed"
    assert "PermissionError" in raised.value.check_error
    details = raised.value.details()
    assert "cancel_check_error" in details


def test_the_hook_fires_with_the_point_name_before_the_probe(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    seen = []
    guard = install_cancel.CancelGuard(op_dir, hook=seen.append)
    guard.check("lock", "before_lock")
    guard.check("lock")  # unnamed checks never call the hook
    assert seen == ["before_lock"]
    (op_dir / install_cancel.CANCEL_FILENAME).touch()
    with pytest.raises(install_cancel.CancelRequested):
        guard.check("lock", "after_lock")
    assert seen == ["before_lock", "after_lock"]


def test_the_signal_flag_is_a_fast_path_onto_the_same_check(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    guard = install_cancel.CancelGuard(op_dir)
    guard.signal_received(int(signal.SIGTERM))
    hit = guard.requested()
    assert hit is not None and hit["reason"] == "sigterm"
    with pytest.raises(install_cancel.CancelRequested) as raised:
        guard.check("install_packages")
    assert raised.value.reason == "sigterm"


@POSIX_ONLY
def test_installed_handlers_map_sigint_and_sigterm_and_restore_cleanly(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    guard = install_cancel.CancelGuard(op_dir)
    previous = signal.getsignal(signal.SIGTERM)
    guard.install_signal_handlers()
    guard.install_signal_handlers()  # idempotent
    try:
        os.kill(os.getpid(), signal.SIGTERM)
        assert guard.requested() is not None
    finally:
        guard.restore_signal_handlers()
        guard.restore_signal_handlers()  # safe twice
    assert signal.getsignal(signal.SIGTERM) is previous


# --- 2. Long subprocesses in an operation-owned process group (decision c) -----


def _guard(tmp_path):
    op_dir = tmp_path / "logs" / str(uuid.uuid4())
    op_dir.mkdir(parents=True)
    return install_cancel.CancelGuard(op_dir)


def test_cancellable_run_matches_subprocess_run_for_kwargs(tmp_path):
    guard = _guard(tmp_path)
    completed = install_cancel.cancellable_run(
        guard, "install_packages", [sys.executable, "-c", "print('ok')"],
        capture_output=True, text=True, check=True,
    )
    assert isinstance(completed, subprocess.CompletedProcess)
    assert completed.returncode == 0 and completed.stdout.strip() == "ok"
    with pytest.raises(subprocess.CalledProcessError):
        install_cancel.cancellable_run(
            guard, "install_packages", [sys.executable, "-c", "import sys; sys.exit(3)"],
            capture_output=True, check=True,
        )


def test_cancellable_run_preserves_the_timeout_semantics(tmp_path):
    guard = _guard(tmp_path)
    started = time.monotonic()
    with pytest.raises(subprocess.TimeoutExpired):
        install_cancel.cancellable_run(
            guard, "install_packages",
            [sys.executable, "-c", "import time; time.sleep(30)"],
            timeout=1.0, grace=0.5,
        )
    assert time.monotonic() - started < 20


@POSIX_ONLY
def test_a_pre_existing_marker_stops_a_running_child_group(tmp_path):
    guard = _guard(tmp_path)
    guard.marker_path.touch()
    started = time.monotonic()
    with pytest.raises(install_cancel.CancelRequested) as raised:
        install_cancel.cancellable_run(
            guard, "install_packages", ["sleep", "30"], capture_output=True,
        )
    exc = raised.value
    assert exc.phase == "install_packages" and exc.reason == "marker"
    assert time.monotonic() - started < install_cancel.TERM_GRACE_SECONDS + 5
    assert exc.child_stop is not None and exc.child_stop["command"] == ["sleep"]
    assert exc.child_stop["survivors_suspected"] is False
    assert exc.details()["detection_seconds"] < 2.0


@POSIX_ONLY
def test_a_marker_appearing_mid_run_is_honoured_and_the_group_dies(tmp_path):
    guard = _guard(tmp_path)
    sentinel = subprocess.Popen(["sleep", "30"], start_new_session=True)
    child_holder = {}

    real_popen = subprocess.Popen

    class RecordingPopen(real_popen):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            child_holder["pid"] = self.pid

    threading.Timer(0.4, guard.marker_path.touch).start()
    try:
        with pytest.raises(install_cancel.CancelRequested) as raised:
            with pytest.MonkeyPatch.context() as mp:
                mp.setattr(install_cancel.subprocess, "Popen", RecordingPopen)
                install_cancel.cancellable_run(
                    guard, "verify_ffmpeg", ["sleep", "30"], grace=1.0,
                )
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)
    assert raised.value.details()["detection_seconds"] < 2.0
    # The operation-owned group is empty; the unrelated sentinel was not in it
    # and kept running until terminated above.
    with pytest.raises(ProcessLookupError):
        os.killpg(child_holder["pid"], 0)


@POSIX_ONLY
def test_a_child_that_ignores_term_is_killed_within_the_grace(tmp_path):
    guard = _guard(tmp_path)
    guard.marker_path.touch()
    started = time.monotonic()
    with pytest.raises(install_cancel.CancelRequested) as raised:
        install_cancel.cancellable_run(
            guard, "install_packages",
            ["sh", "-c", "trap '' TERM; while :; do sleep 1; done"],
            grace=0.5,
        )
    stop = raised.value.child_stop
    assert stop is not None and stop["shutdown_seconds"] >= 0.5
    assert stop["survivors_suspected"] is False  # the KILL escalation emptied the group
    assert time.monotonic() - started < 10


@POSIX_ONLY
def test_a_term_responsive_leader_does_not_shield_a_term_ignoring_grandchild(tmp_path):
    """Sol's review fixture: the leader exits on TERM while its grandchild in
    the same group ignores TERM; escalation must still empty the group, the
    unrelated sentinel in another session must survive, and no false survivor
    may be reported once the group is empty."""

    grandchild_pid_file = tmp_path / "grandchild.pid"
    child_program_file = tmp_path / "child.py"
    child_program_file.write_text(
        "import os, signal, subprocess, sys, time\n"
        "g = subprocess.Popen([sys.executable, '-c',\n"
        "    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])\n"
        f"open({str(grandchild_pid_file)!r}, 'w').write(str(g.pid))\n"
        "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
        "while True:\n"
        "    time.sleep(1)\n"
    )
    child = subprocess.Popen([sys.executable, str(child_program_file)], start_new_session=True)
    sentinel = subprocess.Popen(["sleep", "30"], start_new_session=True)
    try:
        deadline = time.monotonic() + 3
        while not grandchild_pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        grandchild_pid = int(grandchild_pid_file.read_text())
        time.sleep(0.1)
        started = time.monotonic()
        stop = install_cancel.stop_process_group(child, grace=0.25, reap=0.5)
        shutdown = time.monotonic() - started
        with pytest.raises(ProcessLookupError):
            os.kill(grandchild_pid, 0)  # the TERM-ignoring grandchild is gone
        assert sentinel.poll() is None  # the unrelated sentinel survives
        assert stop["survivors_suspected"] is False
        assert shutdown < 10  # the local shutdown limit
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        sentinel.terminate()
        sentinel.wait(timeout=5)
        if child.poll() is None:
            child.wait(timeout=5)


def test_a_suspected_survivor_retains_its_journaled_staging_across_cleanup(tmp_path):
    """Sol's review finding: when a cancelled subprocess may have survived,
    ``_finalize_cancelled`` must not delete anything — journal recovery is
    skipped, the staged bytes stay on disk and are named in
    ``staging_entries``, and the remains record the uncertainty so a later
    operation recovers the staging once the writer is gone."""

    root = tmp_path / "root"
    root.mkdir()
    op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial-bytes")
    journal.close()
    (root / "logs").mkdir()
    writer = install_events.EventWriter.start_operation(root / "logs", op)
    op_log_dir = root / "logs" / op
    exc = install_cancel.CancelRequested(
        "install_wheels",
        "marker",
        child_stop={"command": ["pip"], "survivors_suspected": True},
    )
    exit_code, doc = module_installer._finalize_cancelled(
        writer, op_log_dir, root, op, "s6_cpu", exc, lock_held=True
    )
    assert exit_code == 2
    assert doc["error"]["code"] == "cancelled"
    assert staged.exists()  # nothing was deleted despite the journal entry
    remains = doc["error"]["remains"]
    assert str(staged.relative_to(root)) in remains["staging_entries"]
    assert remains["cleanup"] == []
    assert any("may have survived" in line for line in remains["uncertainty"])


# --- 3. The interruptible download wait (decision b) ---------------------------


class _ScriptedReader:
    def __init__(self, script):
        self._script = list(script)

    def read(self, size=-1):
        action = self._script.pop(0)
        if isinstance(action, BaseException):
            raise action
        return action


def test_read_download_chunk_waits_out_a_stall_and_checks_each_time():
    cancellations = []
    reader = _ScriptedReader([socket.timeout(), TimeoutError(), b"data"])
    chunk = install_cancel.read_download_chunk(
        reader, 4, lambda: cancellations.append(1),
        idle_deadline=time.monotonic() + 60,
        idle_error=lambda: ValueError("idle"),
    )
    assert chunk == b"data"
    assert len(cancellations) == 4  # before every read attempt, once after the data


def test_read_download_chunk_enforces_the_idle_deadline_with_the_callers_error():
    reader = _ScriptedReader([socket.timeout()])
    with pytest.raises(ValueError, match="idle"):
        install_cancel.read_download_chunk(
            reader, 4, lambda: None,
            idle_deadline=time.monotonic() - 1,
            idle_error=lambda: ValueError("idle"),
        )


def test_read_download_chunk_propagates_a_cancel_from_the_probe():
    def cancelling():
        raise install_cancel.CancelRequested("fetch_ffmpeg", "marker")

    reader = _ScriptedReader([socket.timeout(), b"never-reached"])
    with pytest.raises(install_cancel.CancelRequested):
        install_cancel.read_download_chunk(
            reader, 4, cancelling,
            idle_deadline=time.monotonic() + 60,
            idle_error=lambda: ValueError("idle"),
        )
    # A fast reader is checked after the read as well.
    reader = _ScriptedReader([b"x"])
    with pytest.raises(install_cancel.CancelRequested):
        install_cancel.read_download_chunk(
            reader, 4, cancelling,
            idle_deadline=time.monotonic() + 60,
            idle_error=lambda: ValueError("idle"),
        )


def test_cancel_from_hit_rebuilds_the_exception_with_the_recorded_fields():
    exc = install_cancel.cancel_from_hit(
        "lock", {"reason": "check_failed", "check_error": "PermissionError: denied"}
    )
    assert exc.phase == "lock" and exc.reason == "check_failed"
    assert exc.check_error == "PermissionError: denied"


# --- 3b. Real local HTTP behaviour (Sol's review fixtures: pause/resume, trickle)


class _ScriptedHttpServer:
    """A real local HTTP server whose handler streams a scripted body."""

    def __init__(self, body, script):
        import http.server

        chunks = script  # list of (bytes, pause_seconds_after)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    for data, pause in chunks:
                        self.wfile.write(data)
                        self.wfile.flush()
                        if pause:
                            time.sleep(pause)
                except OSError:
                    pass

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}/"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def _read_whole_response(response, check, *, idle_seconds=5.0, overall_seconds=None):
    """The production-shaped loop: repeated read_download_chunk until EOF."""

    import urllib.request  # noqa: F401  (response type comes from the caller)

    overall = None if overall_seconds is None else time.monotonic() + overall_seconds
    collected = bytearray()
    while True:
        chunk = install_cancel.read_download_chunk(
            response,
            256 * 1024,
            check,
            idle_deadline=time.monotonic() + idle_seconds,
            idle_error=lambda: TimeoutError("idle"),
            overall_deadline=overall,
            overall_error=lambda: TimeoutError("overall"),
        )
        if not chunk:
            return bytes(collected)
        collected += chunk


def test_real_http_pause_and_resume_yields_the_exact_bytes_and_digest(tmp_path):
    import hashlib
    import urllib.request

    body = b"abcdefgh"
    server = _ScriptedHttpServer(body, [(body[:3], 1.3), (body[3:], 0)])
    try:
        with urllib.request.urlopen(server.url, timeout=5) as response:
            started = time.monotonic()
            result = _read_whole_response(response, lambda: None)
            elapsed = time.monotonic() - started
    finally:
        server.close()
    assert result == body
    assert hashlib.sha256(result).hexdigest() == hashlib.sha256(body).hexdigest()
    assert elapsed >= 1.2  # the pause really happened and was waited out
    assert elapsed < 5


def test_real_http_trickle_does_not_postpone_cancellation(tmp_path):
    import urllib.request

    body = b"abcdefghijkl"
    server = _ScriptedHttpServer(body, [(bytes([byte]), 0.35) for byte in body])
    guard = install_cancel.CancelGuard(tmp_path)
    try:
        with urllib.request.urlopen(server.url, timeout=5) as response:
            timer = threading.Timer(0.4, guard.marker_path.touch)
            timer.start()
            started = time.monotonic()
            try:
                _read_whole_response(response, lambda: guard.check("fetch_ffmpeg"),
                                       idle_seconds=120)
                outcome = "ignored"
            except install_cancel.CancelRequested as exc:
                outcome = exc.reason
            detected = time.monotonic() - started
            timer.join()
    finally:
        server.close()
    assert outcome == "marker"
    assert detected <= 2.0  # the local detection limit, from marker creation


def test_real_http_trickle_hits_the_overall_deadline_not_the_idle_one(tmp_path):
    import urllib.request

    body = b"abcdefghijkl"
    server = _ScriptedHttpServer(body, [(bytes([byte]), 0.35) for byte in body])
    try:
        with urllib.request.urlopen(server.url, timeout=5) as response:
            started = time.monotonic()
            with pytest.raises(TimeoutError, match="overall"):
                _read_whole_response(response, lambda: None, idle_seconds=120,
                                     overall_seconds=2.0)
            elapsed = time.monotonic() - started
    finally:
        server.close()
    assert elapsed < 4.2  # the trickle (4.2 s total) did not finish
    assert elapsed >= 1.9


def test_real_http_stall_hits_the_idle_deadline(tmp_path):
    import urllib.request

    body = b"abcdefgh"
    server = _ScriptedHttpServer(body, [(body[:3], 30.0), (body[3:], 0)])
    try:
        with urllib.request.urlopen(server.url, timeout=5) as response:
            with pytest.raises(TimeoutError, match="idle"):
                _read_whole_response(response, lambda: None, idle_seconds=1.5)
    finally:
        server.close()


# --- 4. Owner decision C: v1-reader compatibility and the outcome contract ----

# The unmodified base v1 reader (base adf37cc5) knows exactly six states; the
# candidate ships that same reader byte-identical, so ``validate_event`` here
# IS the base reader's grammar. The terminal event for a cancellation is the
# existing ``failed`` state with error_code ``cancelled``; the result document
# (error.code "cancelled") is the authority a future frontend reads first.

BASE_V1_STATES = {
    "active_determinate", "active_indeterminate", "possibly_stalled",
    "retrying", "failed", "done",
}


def test_the_event_reader_is_the_unmodified_base_v1_grammar():
    assert set(install_events.STATE_FIELDS) == BASE_V1_STATES
    with pytest.raises(install_events.InstallFileError):
        install_events.validate_event({
            "protocol": "stemwerk-install-events/1",
            "operation_id": str(uuid.uuid4()),
            "seq": 1, "ts": install_events.utc_timestamp(),
            "source": "core", "state": "cancelled", "phase": "publish",
            "detail": "d", "action": "a",
        })


def _frontend_outcome(result_document):
    """The specified future-frontend rule: read result.json FIRST.

    The module-install frontend is not implemented yet (no Lua or diagnostic
    reader consumes the install events/result protocol today); the contract it
    must implement is: error.code "cancelled" -> Cancelled, any other error
    document -> Failed, success document -> per the success fields.
    """

    error = result_document.get("error")
    if error is None:
        return "Success"
    if error.get("code") == "cancelled":
        prior = (error.get("cancel") or {}).get("prior_error")
        return ("Cancelled", prior) if prior else ("Cancelled", None)
    return ("Failed", error.get("code"))


def test_a_cancelled_operations_whole_stream_is_accepted_by_the_base_reader(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    op = str(uuid.uuid4())
    outer = install_events.EventWriter.start_operation(logs, op)
    outer.append("done", "bootstrap", verified=True)
    op_dir = logs / op
    core = install_events.EventWriter.accept_handover(op_dir, op)
    core.append("failed", "publish", error_code="cancelled",
                detail="cancellation requested during publish (marker)",
                action="Start a new operation to retry")
    doc = {
        "kind": "stemwerk_module_install_error",
        "schema_version": "1.0.0",
        "operation": "install",
        "operation_id": op,
        "module_id": "drum_kit",
        "phase": "publish",
        "error": {"code": "cancelled", "action": "Start a new operation", "detail": "..."},
    }
    install_events.write_result(op_dir, op, 2, doc)

    raw = (op_dir / install_events.EVENTS_FILENAME).read_bytes()
    events = install_events.parse_events(raw)
    for event in events:
        install_events.validate_event(event)
    assert events[-1]["state"] == "failed" and events[-1]["phase"] == "publish"
    assert events[-1]["error_code"] == "cancelled"
    assert events[-1]["source"] == "core"
    read_back = install_events.read_events(op_dir)
    assert read_back[-1]["state"] == "failed"
    result = install_events.read_result(op_dir)
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    assert result["document"]["error"]["code"] == "cancelled"
    assert _frontend_outcome(result["document"]) == ("Cancelled", None)


# --- 5. Deterministic cancellation at every safe point (decisions b, d-g) -----

# point -> (expected terminal phase, outcome class)
SAFE_POINTS = {
    "preflight_entry": ("preflight", "pre_lock"),
    "before_lock": ("lock", "pre_lock"),
    "after_lock": ("lock", "early"),
    "before_pre_verify": ("create_environment", "early"),
    "create_environment_entry": ("create_environment", "staged"),
    "install_packages_entry": ("install_packages", "staged"),
    "fetch_ffmpeg_entry": ("fetch_ffmpeg", "staged"),
    "fetch_ffmpeg_download": ("fetch_ffmpeg", "staged"),
    "fetch_assets_entry": ("fetch_assets", "staged"),
    "verify_assets_entry": ("verify_assets", "staged"),
    "after_asset_publish": ("verify_assets", "assets_published"),
    "publish_entry": ("publish", "assets_published"),
    "after_venv_publish": ("publish", "venv_published"),
    "after_ffmpeg_publish": ("publish", "components_published"),
    "before_receipt": ("publish", "components_published"),
    "between_receipt_and_registry": ("publish", "receipt_published"),
    "before_result": ("verify_module", "registered"),
}

REMAINS_KEYS = {
    "staging_entries",
    "cleanup",
    "cleanup_failures",
    "published_not_registered",
    "retained_downloads",
    "uncertainty",
    "module_status",
}

PASSING = {
    "managed_python": "present_passing",
    "module_venv": "present_passing",
    "ffmpeg": "present_passing",
    "drumsep_assets": "present_passing",
    "reaper_activation": "absent",
}


def _install_with_marker_at(root, facts, fingerprint, point, *, op=None):
    op = op or str(uuid.uuid4())
    op_dir = root / "logs" / op
    hits = []

    def hook(seen_point):
        hits.append(seen_point)
        if seen_point == point:
            (op_dir / install_cancel.CANCEL_FILENAME).touch()

    code, doc = module_installer.install_module(
        "drum_kit", fingerprint, root=root, facts=facts, operation_id=op, cancel_hook=hook
    )
    return op, op_dir, hits, code, doc


@pytest.mark.native_publication
@pytest.mark.parametrize("point", sorted(SAFE_POINTS))
def test_cancel_at_every_safe_point_leaves_a_honest_retriable_state(tmp_path, monkeypatch, point):
    phase, kind = SAFE_POINTS[point]
    facts, root, unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    plan = _plan(root, facts)
    op, op_dir, hits, code, doc = _install_with_marker_at(root, facts, plan["fingerprint"], point)
    assert point in hits

    # Terminal outcome: exit 2, exactly one result, error.code cancelled.
    assert code == 2
    assert doc["phase"] == phase
    error = doc["error"]
    assert error["code"] == "cancelled"
    assert error["cancel"]["cancel_reason"] == "marker"
    assert error["cancel"]["detection_seconds"] <= 2.0
    remains = error["remains"]
    assert set(remains) == REMAINS_KEYS
    assert remains["cleanup_failures"] == [] and remains["uncertainty"] == []

    events = install_events.read_events(op_dir)
    for event in events:
        install_events.validate_event(event)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"
    assert events[-1]["phase"] == phase
    result = _read_result(op_dir)
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    assert result["document"]["error"]["code"] == "cancelled"
    # Owner decision C, case 1: cancellation alone -> Cancelled.
    assert _frontend_outcome(result["document"]) == ("Cancelled", None)
    # Core never removes the marker; the user's unrelated data is untouched.
    assert (op_dir / install_cancel.CANCEL_FILENAME).exists()
    assert unrelated.read_text(encoding="utf-8") == "do not delete"
    assert not list(root.glob("tmp/**/*"))  # staging is cleaned under the lock

    destinations = plan["actions"]["destinations"]
    venv_dir = Path(destinations["module_venv"])
    ffmpeg_dir = managed_ffmpeg.published_directory(root, managed_ffmpeg.load_pin())
    assets_dir = module_registry.expected_drumsep_assets_dir(root)
    receipt = module_registry.receipt_path(root, "drum_kit")
    published = remains["published_not_registered"]
    status = remains["module_status"]["components"]
    # Defect 8 (Sol): a physical managed-Python runtime left by the bootstrap
    # is named without being trusted. It sits there in every class until the
    # module is fully registered.
    runtime_name = runtime_manifest.python_record("linux-x86_64").name
    runtime_entry = f"runtimes/python/{runtime_name}: present_not_registered"
    if kind != "registered":
        assert runtime_entry in published
        published = [entry for entry in published if entry != runtime_entry]

    if kind in ("pre_lock", "early", "staged"):
        assert published == []
        assert not venv_dir.exists() and not ffmpeg_dir.exists() and not assets_dir.exists()
        assert not receipt.exists()
    elif kind == "assets_published":
        assert assets_dir.exists() and not venv_dir.exists() and not ffmpeg_dir.exists()
        assert any(entry.startswith("assets/") for entry in published)
    elif kind == "venv_published":
        assert assets_dir.exists() and venv_dir.exists() and not ffmpeg_dir.exists()
        assert any("runtimes/drum_kit" in entry for entry in published)
        assert any(entry.startswith("assets/") for entry in published)
    elif kind == "components_published":
        assert venv_dir.exists() and ffmpeg_dir.exists() and not receipt.exists()
        assert any("runtimes/ffmpeg" in entry for entry in published)
    elif kind == "receipt_published":
        assert receipt.exists() and venv_dir.exists() and ffmpeg_dir.exists()
        assert any("receipt.json" in entry for entry in published)
        # Receipted but never committed to the registry: honest, not trusted.
        assert status["module_venv"] == "unverifiable"
    elif kind == "registered":
        assert published == []
        assert dict(status) == PASSING

    # A retry is a new operation; the old operation's marker is not its concern.
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0, doc2
    expected = {"registered": "reused", "receipt_published": "reused_after_recovery"}.get(
        kind, "installed_s6_partial"
    )
    assert doc2["outcome"] == expected
    final = module_verify.verify_module("drum_kit", root=root)
    assert {c["component_id"]: c["class"] for c in final["components"]} == PASSING
    assert unrelated.read_text(encoding="utf-8") == "do not delete"


@pytest.mark.native_publication
def test_cancel_while_a_wheel_is_staged(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)

    def fake_stage(manifest, wheelhouse_dir, **kwargs):
        wheelhouse_dir.mkdir(parents=True, exist_ok=True)
        req = wheelhouse_dir / "requirements-locked.txt"
        req.write_text("# locked\n", encoding="utf-8")
        on_wheel = kwargs.get("on_wheel_verified")
        if on_wheel is not None and manifest.wheels:
            on_wheel(manifest.wheels[0])  # the hook below raises CancelRequested here
        return tuple(manifest.wheels), req

    monkeypatch.setattr(wheel_lock, "stage_and_verify_wheelhouse", fake_stage)
    plan = _plan(root, facts)
    _op, _op_dir, hits, code, doc = _install_with_marker_at(
        root, facts, plan["fingerprint"], "wheel_staged"
    )
    assert "wheel_staged" in hits
    assert code == 2 and doc["error"]["code"] == "cancelled"
    assert doc["phase"] == "install_packages"
    assert not list(root.glob("tmp/**/*"))
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0 and doc2["outcome"] == "installed_s6_partial"


# --- 6. Handover, coincidence, write-once and lock interplay (decisions e-g) ---


@pytest.mark.native_publication
def test_a_marker_present_before_core_starts_is_honoured_at_handover(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    op = str(uuid.uuid4())
    logs = root / "logs"
    logs.mkdir(parents=True)
    outer = install_events.EventWriter.start_operation(logs, op)
    outer.append("done", "bootstrap", verified=True)
    (logs / op / install_cancel.CANCEL_FILENAME).touch()

    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts, operation_id=op
    )
    assert code == 2 and doc["error"]["code"] == "cancelled" and doc["phase"] == "preflight"
    events = install_events.read_events(logs / op)
    assert events[0]["source"] == "outer_layer"
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"
    assert events[-1]["source"] == "core"


@pytest.mark.native_publication
def test_a_real_error_coinciding_with_the_marker_reports_cancelled(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    op = str(uuid.uuid4())
    op_dir = root / "logs" / op

    def fault(point):
        if point == "after_venv_staging":
            (op_dir / install_cancel.CANCEL_FILENAME).touch()

    monkeypatch.setenv(module_installer.FAULT_INJECT_ENV, "after_venv_staging")
    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts,
        operation_id=op, fault_hook=fault,
    )
    assert code == 2
    error = doc["error"]
    assert error["code"] == "cancelled"
    prior = error["cancel"]["prior_error"]
    assert prior["phase"] == "install_packages"
    assert prior["code"] == "fault_injected_after_venv_staging"
    events = install_events.read_events(op_dir)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"
    for event in events:  # the whole stream parses under the base v1 grammar
        install_events.validate_event(event)
    # Owner decision C, case 2: cancellation concurrent with a real pip-phase
    # failure -> Cancelled, with the failure retained as a diagnostic detail.
    outcome, detail = _frontend_outcome(doc)
    assert outcome == "Cancelled"
    assert detail["code"] == "fault_injected_after_venv_staging"
    assert not Path(_plan(root, facts)["actions"]["destinations"]["module_venv"]).exists()
    monkeypatch.delenv(module_installer.FAULT_INJECT_ENV)
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0 and doc2["outcome"] == "installed_s6_partial"


@pytest.mark.native_publication
def test_a_real_error_without_the_marker_stays_an_ordinary_failure(tmp_path, monkeypatch):
    """Owner decision C, case 3: pip failure without cancellation -> Failed,
    with pip as the cause; nothing about the outcome says cancelled."""

    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    op = str(uuid.uuid4())
    monkeypatch.setenv(module_installer.FAULT_INJECT_ENV, "after_venv_staging")
    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts,
        operation_id=op,
    )
    assert code == 2
    error = doc["error"]
    assert error["code"] == "fault_injected_after_venv_staging"
    assert "cancel" not in error and "prior_error" not in error
    events = install_events.read_events(root / "logs" / op)
    assert events[-1]["state"] == "failed"
    assert events[-1]["error_code"] == "fault_injected_after_venv_staging"
    for event in events:
        install_events.validate_event(event)
    assert _frontend_outcome(doc) == ("Failed", "fault_injected_after_venv_staging")
    monkeypatch.delenv(module_installer.FAULT_INJECT_ENV)
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0 and doc2["outcome"] == "installed_s6_partial"


@pytest.mark.native_publication
def test_an_existing_terminal_result_is_preserved(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    op = str(uuid.uuid4())
    op_dir = root / "logs" / op
    sentinel = {
        "kind": "stemwerk_module_install_result",
        "schema_version": "1.0.0",
        "operation": "install",
        "operation_id": op,
        "sentinel": True,
    }

    def hook(point):
        if point == "before_result":
            install_events.write_result(op_dir, op, 0, sentinel)
            (op_dir / install_cancel.CANCEL_FILENAME).touch()

    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts,
        operation_id=op, cancel_hook=hook,
    )
    assert code == 2 and doc["error"]["code"] == "cancelled"
    on_disk = _read_result(op_dir)
    assert on_disk["document"].get("sentinel") is True  # never overwritten
    assert on_disk["exit_code"] == 0


@pytest.mark.native_publication
def test_a_retry_while_the_first_operation_holds_the_lock_is_refused(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    plan = _plan(root, facts)
    entered = threading.Event()
    release = threading.Event()

    def blocking_hook(point):
        if point == "after_lock":
            entered.set()
            assert release.wait(30)

    outcome = {}

    def first():
        outcome["first"] = module_installer.install_module(
            "drum_kit", plan["fingerprint"], root=root, facts=facts, cancel_hook=blocking_hook
        )

    worker = threading.Thread(target=first)
    worker.start()
    assert entered.wait(30)
    try:
        code, doc = module_installer.install_module(
            "drum_kit", plan["fingerprint"], root=root, facts=facts
        )
        assert code == 2 and doc["error"]["code"] == "lock_held"
    finally:
        release.set()
        worker.join(60)
    assert not worker.is_alive()
    assert outcome["first"][0] == 0


@pytest.mark.native_publication
def test_another_operations_marker_is_ignored(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    logs = root / "logs"
    logs.mkdir(parents=True)
    other = str(uuid.uuid4())
    install_events.EventWriter.start_operation(logs, other)
    (logs / other / install_cancel.CANCEL_FILENAME).touch()
    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code == 0 and doc["outcome"] == "installed_s6_partial"
    assert (logs / other / install_cancel.CANCEL_FILENAME).exists()


@pytest.mark.native_publication
@pytest.mark.parametrize("form", ["file", "directory"])
def test_any_entry_at_the_marker_path_counts(tmp_path, monkeypatch, form):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    op = str(uuid.uuid4())
    op_dir = root / "logs" / op

    def hook(point):
        if point == "before_lock":
            marker = op_dir / install_cancel.CANCEL_FILENAME
            if form == "directory":
                marker.mkdir()
            else:
                marker.touch()

    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts,
        operation_id=op, cancel_hook=hook,
    )
    assert code == 2 and doc["error"]["code"] == "cancelled" and doc["phase"] == "lock"


@POSIX_ONLY
def test_sigterm_mid_install_ends_cancelled_and_restores_handlers(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    previous = signal.getsignal(signal.SIGTERM)

    def hook(point):
        if point == "install_packages_entry":
            os.kill(os.getpid(), signal.SIGTERM)

    code, doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts, cancel_hook=hook
    )
    assert code == 2 and doc["error"]["code"] == "cancelled"
    assert doc["error"]["cancel"]["cancel_reason"] == "sigterm"
    assert signal.getsignal(signal.SIGTERM) is previous
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0


# --- 7. The other two install paths (reused, ffmpeg-added) ---------------------


@pytest.mark.native_publication
def test_cancel_on_the_reused_path_reports_the_committed_state(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    code, _doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code == 0
    _op, _op_dir, _hits, code, doc = _install_with_marker_at(
        root, facts, _plan(root, facts)["fingerprint"], "before_result"
    )
    assert code == 2 and doc["error"]["code"] == "cancelled" and doc["phase"] == "verify_module"
    remains = doc["error"]["remains"]
    assert remains["published_not_registered"] == []
    assert dict(remains["module_status"]["components"]) == PASSING
    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0 and doc2["outcome"] == "reused"


@pytest.mark.native_publication
def test_cancel_while_adding_the_pair_keeps_the_s6_state_and_the_untrusted_pair(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    code, _doc = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code == 0
    s6_receipt = _make_s6_only_root(root)
    receipt_bytes = module_registry.receipt_path(root, "drum_kit").read_bytes()

    _op, _op_dir, _hits, code, doc = _install_with_marker_at(
        root, facts, _plan(root, facts)["fingerprint"], "after_ffmpeg_publish"
    )
    assert code == 2 and doc["error"]["code"] == "cancelled" and doc["phase"] == "publish"
    published = doc["error"]["remains"]["published_not_registered"]
    assert any("runtimes/ffmpeg" in entry for entry in published)
    # The pair sits on disk but nothing was receipted; the S6 receipt is untouched.
    assert module_registry.receipt_path(root, "drum_kit").read_bytes() == receipt_bytes
    assert module_verify.s6_ffmpeg_pair(root)[0] == "refused"

    code2, doc2 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code2 == 0 and doc2["outcome"] == "ffmpeg_added"
    assert s6_receipt["components"]["managed_python"] is not None


@pytest.mark.native_publication
def test_a_cancel_during_the_adoption_reprobe_keeps_the_pair_untrusted(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    plan = _plan(root, facts)
    _op, _od, _h, code, _doc = _install_with_marker_at(
        root, facts, plan["fingerprint"], "after_ffmpeg_publish"
    )
    assert code == 2
    ffmpeg_dir = managed_ffmpeg.published_directory(root, managed_ffmpeg.load_pin())
    assert ffmpeg_dir.exists()

    # The retry reaches the adoption branch and is cancelled at its re-probe.
    _op2, _od2, hits2, code2, doc2 = _install_with_marker_at(
        root, facts, _plan(root, facts)["fingerprint"], "ffmpeg_inspect"
    )
    assert "ffmpeg_inspect" in hits2
    assert code2 == 2 and doc2["error"]["code"] == "cancelled" and doc2["phase"] == "fetch_ffmpeg"
    assert not module_registry.receipt_path(root, "drum_kit").exists()

    code3, doc3 = module_installer.install_module(
        "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
    )
    assert code3 == 0 and doc3["outcome"] == "installed_s6_partial"
    final = module_verify.verify_module("drum_kit", root=root)
    assert {c["component_id"]: c["class"] for c in final["components"]} == PASSING


# --- 8. Interruptible FFmpeg fetch and extract (decision b) --------------------


def test_ffmpeg_archive_copy_is_cancellable_and_leaves_no_partial(tmp_path):
    pair = ffmpeg_fixture.build_pair(tmp_path / "ffmpeg-cache")
    download = tmp_path / "download"
    download.mkdir()
    calls = []

    def cancel():
        calls.append(1)
        if len(calls) >= 2:
            raise install_cancel.CancelRequested("fetch_ffmpeg", "marker")

    with pytest.raises(install_cancel.CancelRequested):
        managed_ffmpeg.fetch_archive(pair.pin, download, source_dir=pair.cache_dir, cancel=cancel)
    assert not list(download.rglob("*"))  # no partial copy is kept


def test_ffmpeg_extraction_is_cancellable_between_members(tmp_path):
    pair = ffmpeg_fixture.build_pair(tmp_path / "ffmpeg-cache")
    stage = tmp_path / "stage"
    stage.mkdir()
    archive = pair.cache_dir / pair.pin.archive_name
    calls = []

    def cancel():
        calls.append(1)
        if len(calls) >= 2:
            raise install_cancel.CancelRequested("fetch_ffmpeg", "marker")

    with pytest.raises(install_cancel.CancelRequested):
        managed_ffmpeg.extract_archive(archive, stage, pair.pin, cancel=cancel)
    # Whatever was written is removed with the refusal; nothing is blessed.
    assert managed_ffmpeg.inspect_tree(stage, pair.pin).ok is False


# --- 9. A suspected writer's staging across cancel -> retry -> recovery -------
#
# Delta review blocker 1: the retry's lock acquisition runs journal recovery,
# which used to assume every other journal belonged to a stopped operation.
# A cancelled operation that cannot rule out a writer now records the
# suspected process group, boot id and PID namespace in its journal; recovery
# removes the staging only when the group is gone (ESRCH) or the boot changed.


def _live_writer(path):
    """A writer in its own session and process group that keeps appending to ``path``."""
    process = subprocess.Popen(
        [
            sys.executable, "-c",
            "import sys,time\n"
            "f = open(sys.argv[1], 'ab', buffering=0)\n"
            "while True:\n"
            "    f.write(b'w')\n"
            "    time.sleep(0.05)\n",
            str(path),
        ],
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size > 0:
            return process
        time.sleep(0.02)
    process.kill()
    process.wait()
    raise AssertionError("the writer never wrote")


def _stop_writer(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)  # reaped: the group is really empty afterwards


def _sha(path):
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


@POSIX_ONLY
def test_a_retry_keeps_the_staging_of_a_live_suspected_writer_until_it_is_gone(tmp_path, monkeypatch):
    """Sol's blocker 1, end to end through the real installer: cancel with a
    live writer in the suspected group -> retry with a NEW operation id (lock
    acquisition, journal recovery) -> the old staging and a control file in it
    stay byte-identical and the writer keeps writing into it; the retry builds
    in its own staging and succeeds; the old staging is named in the retry's
    recovery report; once the writer is gone a later run cleans it up."""

    facts, root, unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    plan = _plan(root, facts)
    old_op = str(uuid.uuid4())
    old_staging = root / "tmp" / old_op / "core"
    live = {}

    def hook(point):
        if point != "install_packages_entry":
            return
        control = old_staging / "control.bin"
        control.write_bytes(b"control-bytes-never-touched")
        live["control"] = control
        live["output"] = old_staging / "writer-output"
        live["writer"] = _live_writer(live["output"])
        raise install_cancel.CancelRequested(
            "install_packages", "marker",
            child_stop={"command": ["pip"], "survivors_suspected": True, "pgid": live["writer"].pid},
        )

    try:
        code, doc = module_installer.install_module(
            "drum_kit", plan["fingerprint"], root=root, facts=facts, operation_id=old_op, cancel_hook=hook
        )
        assert code == 2 and doc["error"]["code"] == "cancelled"
        remains = doc["error"]["remains"]
        # The cancelled operation names the retained staging and the suspect.
        assert any(entry.startswith(f"tmp/{old_op}/core") for entry in remains["staging_entries"])
        assert remains["cleanup"] == []
        suspect = remains["suspected_writer"]
        assert suspect["pgid"] == live["writer"].pid
        assert suspect["boot_id"] == install_cancel.current_boot_id()
        records = install_journal.parse_journal(
            (root / "tmp" / old_op / install_journal.JOURNAL_FILENAME).read_bytes(), old_op
        )
        assert records[-1]["record"] == "suspect" and records[-1]["pgid"] == live["writer"].pid

        control_before = _sha(live["control"])
        size_before = live["output"].stat().st_size
        names_before = sorted(p.name for p in old_staging.iterdir())

        # Retry: a new operation id acquires the lock and runs recovery.
        code2, doc2 = module_installer.install_module(
            "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
        )
        assert code2 == 0, doc2  # the retry is not blocked by the kept staging
        assert live["writer"].poll() is None  # the writer was alive throughout
        assert old_staging.is_dir()
        assert _sha(live["control"]) == control_before
        assert sorted(p.name for p in old_staging.iterdir()) == names_before
        time.sleep(0.2)
        assert live["output"].stat().st_size > size_before  # still writing into intact staging
        deferred = [
            op for op in doc2["recovery"]["operations"] if op["operation_id"] == old_op
        ]
        assert len(deferred) == 1
        assert deferred[0]["complete"] is False
        assert deferred[0]["deferred_writer"]["pgid"] == live["writer"].pid
        assert deferred[0]["items"][0]["outcome"] == install_journal.KEPT_WRITER_MAY_BE_ALIVE
        assert unrelated.read_text(encoding="utf-8") == "do not delete"

        # The writer is gone: the next run proves it (ESRCH) and cleans up.
        _stop_writer(live["writer"])
        code3, doc3 = module_installer.install_module(
            "drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts
        )
        assert code3 == 0, doc3
        assert not old_staging.exists()
        assert not (root / "tmp" / old_op).exists()
        gone = [op for op in doc3["recovery"]["operations"] if op["operation_id"] == old_op]
        assert gone and gone[0]["complete"] is True
    finally:
        if "writer" in live:
            _stop_writer(live["writer"])


@POSIX_ONLY
def test_a_changed_boot_id_proves_a_suspected_writer_gone(tmp_path, monkeypatch):
    """Second proof of death: the recorded boot id differs from the current one
    (simulated here), so the group id is meaningless and recovery proceeds even
    though a process with that group id still exists."""

    root = tmp_path / "root"
    root.mkdir()
    old_op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, old_op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    journal.close()
    writer = _live_writer(tmp_path / "unrelated-output")
    try:
        install_journal.record_suspected_writer(
            root, old_op, pgid=writer.pid, boot_id=str(uuid.uuid4()),  # SIMULATED previous boot
            pid_namespace=install_cancel.current_pid_namespace(),
        )
        # The recorded boot id differs from the real one: the recorded group id
        # belongs to a boot that is over, and here it names an unrelated live
        # process. The boot id decides, so removal is allowed.
        new_op = str(uuid.uuid4())
        lock = install_lock.acquire(root, new_op)
        try:
            op = [o for o in lock.recovery.operations if o.operation_id == old_op][0]
            assert op.deferred_writer is None and op.complete is True
        finally:
            lock.release()
        assert not staged.exists()
        assert writer.poll() is None  # the unrelated process was never touched
    finally:
        _stop_writer(writer)


@POSIX_ONLY
def test_the_same_boot_with_a_live_group_keeps_the_staging(tmp_path):
    """The mirror of the boot-id test: same boot id, live group -> kept."""

    root = tmp_path / "root"
    root.mkdir()
    old_op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, old_op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    journal.close()
    writer = _live_writer(tmp_path / "output")
    try:
        install_journal.record_suspected_writer(root, old_op, pgid=writer.pid)
        lock = install_lock.acquire(root, str(uuid.uuid4()))
        try:
            op = [o for o in lock.recovery.operations if o.operation_id == old_op][0]
            assert op.deferred_writer is not None and op.deferred_writer["reason"] == "process_group_alive"
        finally:
            lock.release()
        assert staged.read_bytes() == b"partial"
    finally:
        _stop_writer(writer)


@POSIX_ONLY
def test_writer_state_follows_the_namespace_and_boot_rule(monkeypatch):
    """The fix4 decision table. ESRCH is proof only when the observer's PID namespace is
    positively the recorded one, on positively the same boot; a positively different boot
    proves the writer gone on its own; everything else keeps the staging and says why."""
    unknown, gone, alive = install_cancel.WRITER_UNKNOWN, install_cancel.WRITER_GONE, install_cancel.WRITER_ALIVE
    boot, ns = install_cancel.current_boot_id(), install_cancel.current_pid_namespace()
    assert install_cancel.valid_boot_id(boot) and install_cancel.valid_pid_namespace(ns)
    for pgid in (None, 0, 1, -5, True, "7"):
        # Group 0 would signal our own group and 1 is init's: never "alive" by accident, never "gone".
        assert install_cancel.writer_state(pgid, boot, ns) == (unknown, "no_process_group_recorded")

    def denied(pgid, sig):
        raise PermissionError(1, "denied")

    monkeypatch.setattr(os, "killpg", denied)
    assert install_cancel.writer_state(4242, boot, ns) == (alive, "process_group_exists_not_signalable")

    def other_error(pgid, sig):
        raise OSError(5, "simulated EIO")

    monkeypatch.setattr(os, "killpg", other_error)
    assert install_cancel.writer_state(4242, boot, ns)[0] == unknown

    def missing(pgid, sig):
        raise ProcessLookupError(3, "no such process")

    monkeypatch.setattr(os, "killpg", missing)
    # positive control: same namespace, same boot, ESRCH -> gone
    assert install_cancel.writer_state(4242, boot, ns) == (gone, "process_group_gone")
    # a record without a usable namespace (missing, empty, malformed; earlier candidates)
    for recorded in (None, "", "pid:[]", "pid:[0]", "pid:[12", "net:[4026531840]", " pid:[1]", 4026531836):
        assert install_cancel.writer_state(4242, boot, recorded) == (unknown, "pid_namespace_unrecorded"), recorded
    # a different namespace: ESRCH there says nothing about the writer
    other = "pid:[1]" if ns != "pid:[1]" else "pid:[2]"
    assert install_cancel.writer_state(4242, boot, other) == (unknown, "pid_namespace_differs")
    # the observer cannot read or parse its own namespace
    for observed in (None, "", "garbage"):
        monkeypatch.setattr(install_cancel, "current_pid_namespace", lambda value=observed: value)
        assert install_cancel.writer_state(4242, boot, ns) == (unknown, "pid_namespace_unreadable"), observed
    monkeypatch.setattr(install_cancel, "current_pid_namespace", lambda: ns)
    # the boot is not positively the same: no proof (a missing boot id is never a reboot)
    for recorded_boot in (None, "", "recorded-boot"):
        assert install_cancel.writer_state(4242, recorded_boot, ns) == (unknown, "boot_id_unavailable"), recorded_boot
    monkeypatch.setattr(install_cancel, "current_boot_id", lambda: None)
    assert install_cancel.writer_state(4242, boot, ns) == (unknown, "boot_id_unavailable")
    # SIMULATED boot change: both boot ids well formed and different -> gone, even with
    # no group and no namespace recorded
    monkeypatch.setattr(install_cancel, "current_boot_id", lambda: str(uuid.uuid4()))
    assert install_cancel.writer_state(None, str(uuid.uuid4()), None) == (gone, "boot_id_changed")
    # a malformed recorded boot id is not a positively different boot
    assert install_cancel.writer_state(None, "before", None) == (unknown, "no_process_group_recorded")


@POSIX_ONLY
def test_stop_process_group_reports_the_group_id_it_probed(tmp_path):
    child = subprocess.Popen(["sleep", "30"], start_new_session=True)
    stop = install_cancel.stop_process_group(child, grace=0.25, reap=0.5)
    assert stop["pgid"] == child.pid
    assert stop["survivors_suspected"] is False


@POSIX_ONLY
def test_the_asset_materialization_recovery_leaves_a_suspected_writers_stage_and_lock(tmp_path):
    """The second cleanup path that runs at lock acquisition, before journal
    recovery: it removes the destination lock and stage named after a stopped
    operation. For a suspected live writer both stay."""

    root = tmp_path / "root"
    root.mkdir()
    old_op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, old_op)
    journal.close()
    destination = module_registry.expected_drumsep_assets_dir(root)
    destination.parent.mkdir(parents=True)
    stage = destination.parent / f".{destination.name}.stemwerk-stage-{old_op}"
    stage.mkdir()
    (stage / "marker.txt").write_text("not an allowed name, but never reached", encoding="utf-8")
    lock_file = destination.parent / f".{destination.name}.stemwerk-materialize.lock"
    lock_file.write_bytes(f"{old_op}\n".encode("ascii"))
    writer = _live_writer(tmp_path / "output")
    try:
        install_journal.record_suspected_writer(root, old_op, pgid=writer.pid)
        module_installer._recover_s6_asset_materializations(root, str(uuid.uuid4()))
        assert stage.is_dir() and (stage / "marker.txt").exists()
        assert lock_file.read_bytes() == f"{old_op}\n".encode("ascii")
        _stop_writer(writer)
        # Writer gone: the same path now proceeds (this stage holds an unknown
        # entry, so it refuses loudly instead of deleting - proof it is reached).
        with pytest.raises(install_lock.LockError) as refused:
            module_installer._recover_s6_asset_materializations(root, str(uuid.uuid4()))
        assert refused.value.code == "recovery_incomplete"
    finally:
        _stop_writer(writer)


@POSIX_ONLY
def test_stale_bootstrap_cleanup_cannot_reach_a_suspected_writers_core_staging(tmp_path):
    """The third path: the outer layer's stale bootstrap cleanup removes only
    ``bootstrap/`` and rmdirs the operation directory when empty."""

    root = tmp_path / "root"
    root.mkdir()
    old_op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, old_op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    journal.close()
    bootstrap = root / "tmp" / old_op / install_bootstrap.BOOTSTRAP_DIRECTORY
    bootstrap.mkdir()
    (bootstrap / install_bootstrap.OWNER_FILENAME).write_bytes(install_bootstrap.owner_line(old_op, 999999))
    writer = _live_writer(tmp_path / "output")
    try:
        install_journal.record_suspected_writer(root, old_op, pgid=writer.pid)
        report = install_bootstrap.remove_stale_staging(
            root, stale_after=0.0, probe=lambda pid: process_identity.ProcessProbe(False, None),
            group_rule=False,  # the baseline rule: this test is about what the removal can reach
        )
        assert [entry.outcome for entry in report.entries] == [install_bootstrap.REMOVED]
        assert not bootstrap.exists()
        assert staged.read_bytes() == b"partial"  # the operation directory had content: kept
    finally:
        _stop_writer(writer)


def test_an_unrecordable_suspect_is_reported_not_hidden(tmp_path):
    """If the suspect record cannot be appended the result must say so (a later
    operation may then remove the staging) rather than claim it is protected."""

    root = tmp_path / "root"
    root.mkdir()
    op = str(uuid.uuid4())  # no journal at all
    (root / "logs").mkdir()
    writer = install_events.EventWriter.start_operation(root / "logs", op)
    exc = install_cancel.CancelRequested(
        "install_wheels", "marker", child_stop={"survivors_suspected": True, "pgid": 4242}
    )
    code, doc = module_installer._finalize_cancelled(
        writer, root / "logs" / op, root, op, "s6_cpu", exc, lock_held=True
    )
    assert code == 2
    remains = doc["error"]["remains"]
    assert "suspected_writer" not in remains
    assert any("could not be recorded" in line for line in remains["uncertainty"])


def test_a_suspect_record_does_not_break_the_base_journal_grammar(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, op)
    journal.create_file(journal.core_directory / "a.bin", b"a")
    journal.close()
    record = install_journal.record_suspected_writer(root, op, pgid=4242, boot_id="b", pid_namespace="n")
    records = install_journal.parse_journal(
        (root / "tmp" / op / install_journal.JOURNAL_FILENAME).read_bytes(), op
    )
    # open, intent+completion for core/, intent+completion for the file, suspect
    assert [r["record"] for r in records] == [
        "open", "intent", "completion", "intent", "completion", "suspect"
    ]
    assert record["seq"] == len(records)
    assert records[-1]["staging"] == f"tmp/{op}/core"


# --- 10. Write-ahead writer records (fix3) -------------------------------------------
#
# Safety must not depend on a last-minute ``suspect`` append: the intent is durable
# BEFORE the process exists, the group id follows right after, and the record is closed
# only after the child was reaped and the group answered ESRCH.


def _ledger_root(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    guard = install_cancel.CancelGuard(root / "logs" / op)
    guard.writers = journal
    return root, op, journal, staged, guard


def _records(root, op):
    return install_journal.parse_journal(
        (root / "tmp" / op / install_journal.JOURNAL_FILENAME).read_bytes(), op
    )


def _kinds(root, op):
    return [r["record"] for r in _records(root, op)]


def _recover(root, op):
    return install_journal._recover_operation(
        root, install_journal.operation_directory(root, op), op, verify_published=None
    )


def _recovery_via_new_lock(root, op):
    lock = install_lock.acquire(root, str(uuid.uuid4()))
    try:
        return [o for o in lock.recovery.operations if o.operation_id == op]
    finally:
        lock.release()


@POSIX_ONLY
def test_cancellable_run_writes_intent_then_pgid_then_close_and_ordinary_cleanup_follows(tmp_path):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    completed = install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", "print('ok')"],
                                               capture_output=True, text=True)
    assert completed.stdout.strip() == "ok"
    kinds = _kinds(root, op)
    assert kinds[-3:] == ["writer_intent", "writer_pgid", "writer_closed"]
    records = _records(root, op)
    intent, pgid_record, closed = records[-3:]
    assert intent["staging"] == f"tmp/{op}/core" and intent["boot_id"] == install_cancel.current_boot_id()
    assert pgid_record["writer_id"] == closed["writer_id"] == intent["writer_id"]
    journal.close()
    # positive control: writer completion is established, so ordinary cleanup proceeds
    result = _recover(root, op)
    assert result.deferred_writer is None and result.complete is True
    assert not staged.exists()


@POSIX_ONLY
def test_a_failed_intent_append_starts_nothing(tmp_path, monkeypatch):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    ran = tmp_path / "ran"
    real_write = os.write

    def failing(fd, data):
        if b'"writer_intent"' in bytes(data):
            raise OSError(5, "simulated EIO")
        return real_write(fd, data)

    monkeypatch.setattr(os, "write", failing)
    with pytest.raises(install_cancel.WriterIntentError) as raised:
        install_cancel.cancellable_run(guard, "create_environment",
                                       [sys.executable, "-c", f"open({str(ran)!r}, 'w').write('x')"])
    assert raised.value.phase == "create_environment"
    time.sleep(0.3)
    assert not ran.exists(), "the process must not have been started"
    monkeypatch.setattr(os, "write", real_write)
    assert "writer_intent" not in _kinds(root, op)
    journal.writer_closed("unrelated")  # the journal is still usable and gap-free
    _records(root, op)


def test_the_installer_maps_a_failed_intent_to_a_failure_not_a_crash(tmp_path, monkeypatch):
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    plan = _plan(root, facts)

    def refuse(guard, phase, command, **kwargs):
        raise install_cancel.WriterIntentError("simulated: the intent could not be recorded", phase)

    monkeypatch.setattr(module_installer.install_cancel, "cancellable_run", refuse)
    code, doc = module_installer.install_module("drum_kit", plan["fingerprint"], root=root, facts=facts)
    assert code == 2
    assert doc["error"]["code"] == "writer_intent_unavailable"
    assert doc["phase"] == "create_environment"


@POSIX_ONLY
def test_interrupted_after_spawn_before_pgid_the_open_intent_protects_staging(tmp_path):
    """Core dies between the spawn and the PGID append: only the intent exists."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    token = journal.begin_writer(["writer"])
    live = _live_writer(tmp_path / "writer-output")
    journal.close()  # "Core died" here: no writer_pgid, no writer_closed
    try:
        assert _kinds(root, op)[-1] == "writer_intent"
        for _ in range(2):  # fresh lock acquisitions
            [rec] = _recovery_via_new_lock(root, op)
            assert rec.deferred_writer["reason"] == "no_process_group_recorded"
            assert rec.deferred_writer["source"] == "writer_intent"
        assert staged.read_bytes() == b"partial"
        # Even after the writer is gone, nothing proves it on the same boot: still retained.
        _stop_writer(live)
        [rec] = _recovery_via_new_lock(root, op)
        assert rec.deferred_writer is not None and staged.exists()
        assert token
    finally:
        _stop_writer(live)
    # SIMULATED boot change: a positively different boot id resolves the old writer.
    records = (root / "tmp" / op / install_journal.JOURNAL_FILENAME)
    records.write_bytes(records.read_bytes().replace(
        install_cancel.current_boot_id().encode(), str(uuid.uuid4()).encode()))  # SIMULATED previous boot
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer is None and rec.complete is True and not staged.exists()


@POSIX_ONLY
def test_solis_unrecordable_suspect_case_the_staging_and_a_new_file_survive_a_retry(tmp_path):
    """Sol's fix2 blocker: the supplementary ``suspect`` append fails (mode-0400 journal).
    The write-ahead intent keeps the staging: after a NEW operation takes the real lock and
    recovery runs, the still-live ORIGINAL writer creates a NEW file through the original
    staging pathname, and a SEPARATE process reads it."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    stage_dir = journal.core_directory
    trigger, status = tmp_path / "trigger", tmp_path / "status"
    program = (
        "import os,sys,time\n"
        "stage,trigger,status = sys.argv[1:4]\n"
        "while not os.path.exists(trigger): time.sleep(0.02)\n"
        "try:\n"
        "    open(os.path.join(stage,'created-after-retry.bin'),'wb').write(b'new file via the original pathname')\n"
        "    open(status,'w').write('created')\n"
        "except OSError as e:\n"
        "    open(status,'w').write('failed: %s' % e)\n"
        "time.sleep(30)\n"
    )
    token = journal.begin_writer(["writer"])
    live = subprocess.Popen([sys.executable, "-c", program, str(stage_dir), str(trigger), str(status)],
                            start_new_session=True)
    journal.writer_spawned(token, live.pid)
    (root / "logs").mkdir(exist_ok=True)
    events = install_events.EventWriter.start_operation(root / "logs", op)
    journal.close()
    journal_file = root / "tmp" / op / install_journal.JOURNAL_FILENAME
    try:
        journal_file.chmod(0o400)  # the supplementary suspect append gets a real EACCES
        exc = install_cancel.CancelRequested(
            "install_packages", "marker", child_stop={"survivors_suspected": True, "pgid": live.pid})
        status_code, doc = module_installer._finalize_cancelled(
            events, root / "logs" / op, root, op, "drum_kit", exc, lock_held=True)
        journal_file.chmod(0o600)
        assert status_code == 2 and doc["error"]["code"] == "cancelled"
        remains = doc["error"]["remains"]
        assert "suspect" not in _kinds(root, op)  # the append really failed
        assert remains["suspected_writer"]["pgid"] == live.pid  # but the intent still names the writer
        assert any("write-ahead" in line for line in remains["uncertainty"])
        assert staged.exists()

        [rec] = _recovery_via_new_lock(root, op)  # a new operation, the real lock, the real recovery
        assert rec.deferred_writer is not None and rec.deferred_writer["reason"] == "process_group_alive"
        assert live.poll() is None and stage_dir.is_dir() and staged.exists()

        trigger.write_text("go")
        _wait = time.monotonic() + 5
        while not status.exists() and time.monotonic() < _wait:
            time.sleep(0.02)
        assert status.read_text() == "created"
        created = stage_dir / "created-after-retry.bin"
        read_back = subprocess.run(["cat", str(created)], capture_output=True)
        assert read_back.returncode == 0 and read_back.stdout == b"new file via the original pathname"
    finally:
        journal_file.chmod(0o600)
        _stop_writer(live)
    # the writer is gone and its group answers ESRCH: the pgid was recorded, so ordinary cleanup resumes
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer is None and rec.complete is True
    assert not stage_dir.exists()


@POSIX_ONLY
def test_a_failed_close_append_leaves_the_intent_open_but_a_gone_group_still_proves_it(tmp_path, monkeypatch):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    monkeypatch.setattr(journal, "writer_closed", lambda token: (_ for _ in ()).throw(
        install_journal.JournalError("journal_write_failed", "simulated: the close append failed")))
    install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", "pass"])
    journal.close()
    assert _kinds(root, op)[-2:] == ["writer_intent", "writer_pgid"]  # never closed
    [rec] = _recovery_via_new_lock(root, op)
    # the recorded group is gone (ESRCH): that proof stands without the close record
    assert rec.deferred_writer is None and rec.complete is True and not staged.exists()


@POSIX_ONLY
def test_neither_pgid_nor_close_recorded_keeps_the_staging_on_the_same_boot(tmp_path, monkeypatch):
    root, op, journal, staged, guard = _ledger_root(tmp_path)

    def failing(*_args):
        raise install_journal.JournalError("journal_write_failed", "simulated append failure")

    monkeypatch.setattr(journal, "writer_spawned", failing)
    monkeypatch.setattr(journal, "writer_closed", failing)
    install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", "pass"])  # tolerated
    journal.close()
    assert _kinds(root, op)[-1] == "writer_intent"
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["reason"] == "no_process_group_recorded"
    assert staged.read_bytes() == b"partial"


@POSIX_ONLY
def test_an_unavailable_boot_id_is_not_evidence_of_a_reboot_for_writer_records(tmp_path, monkeypatch):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    monkeypatch.setattr(install_cancel, "current_boot_id", lambda: None)
    token = journal.begin_writer(["writer"])
    live = _live_writer(tmp_path / "output")
    journal.writer_spawned(token, live.pid)
    journal.close()
    try:
        assert _records(root, op)[-2]["boot_id"] is None
        [rec] = _recovery_via_new_lock(root, op)
        assert rec.deferred_writer["reason"] == "process_group_alive"  # no boot id: the group decides
        assert staged.exists()
    finally:
        _stop_writer(live)
    # fix4 rule: ESRCH proves nothing unless the boot is positively the same. The group is
    # really gone here, but neither boot id is known, so the staging stays and says why.
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["reason"] == "boot_id_unavailable" and staged.exists()
    # The current boot id readable again does not help: the RECORD has none.
    monkeypatch.undo()
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["reason"] == "boot_id_unavailable" and staged.exists()


@POSIX_ONLY
def test_two_writers_sharing_the_staging_each_hold_their_own_protection(tmp_path):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    first = journal.begin_writer(["a"])
    live_a = _live_writer(tmp_path / "a-output")
    journal.writer_spawned(first, live_a.pid)
    second = journal.begin_writer(["b"])
    live_b = _live_writer(tmp_path / "b-output")
    journal.writer_spawned(second, live_b.pid)
    try:
        _stop_writer(live_a)
        journal.writer_closed(first)  # writer A is done and closed
        journal.close()
        [rec] = _recovery_via_new_lock(root, op)
        assert rec.deferred_writer["pgid"] == live_b.pid  # B still holds the staging
        assert staged.exists()
    finally:
        _stop_writer(live_b)
    [rec] = _recovery_via_new_lock(root, op)  # B gone (ESRCH) although never closed: proven by its group
    assert rec.deferred_writer is None and not staged.exists()


@POSIX_ONLY
def test_a_cancel_closes_the_writer_only_after_the_group_is_gone(tmp_path):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    (root / "logs" / op).mkdir(parents=True)
    (root / "logs" / op / install_cancel.CANCEL_FILENAME).touch()
    program = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
    started = time.monotonic()
    with pytest.raises(install_cancel.CancelRequested) as raised:
        install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", program], poll=0.05, grace=0.3)
    assert raised.value.child_stop["survivors_suspected"] is False
    assert raised.value.child_stop["pgid"] > 1
    assert time.monotonic() - started < 10
    assert _kinds(root, op)[-3:] == ["writer_intent", "writer_pgid", "writer_closed"]
    journal.close()
    result = _recover(root, op)
    assert result.deferred_writer is None and result.complete is True and not staged.exists()


@POSIX_ONLY
def test_a_finalizer_without_child_stop_still_reports_an_open_writer(tmp_path):
    """Recovery inside the finalizer sees the open intent even when the stop result did not."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    token = journal.begin_writer(["writer"])
    live = _live_writer(tmp_path / "output")
    journal.writer_spawned(token, live.pid)
    journal.close()
    (root / "logs").mkdir(exist_ok=True)
    events = install_events.EventWriter.start_operation(root / "logs", op)
    try:
        exc = install_cancel.CancelRequested("install_packages", "marker")
        code, doc = module_installer._finalize_cancelled(events, root / "logs" / op, root, op, "drum_kit", exc, lock_held=True)
        remains = doc["error"]["remains"]
        assert remains["suspected_writer"]["pgid"] == live.pid
        assert any("not proven gone" in line for line in remains["uncertainty"])
        assert staged.exists() and remains["cleanup"][0]["outcome"] == install_journal.KEPT_WRITER_MAY_BE_ALIVE
    finally:
        _stop_writer(live)


@POSIX_ONLY
def test_the_close_is_not_written_unless_the_group_is_confirmed_gone(tmp_path, monkeypatch):
    """The direct child was reaped, but emptiness of the group cannot be shown: the record
    stays open, so the staging stays protected."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    monkeypatch.setattr(install_cancel, "confirm_group_gone", lambda pgid, **kwargs: False)
    install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", "pass"])
    assert _kinds(root, op)[-2:] == ["writer_intent", "writer_pgid"]
    journal.close()
    # the real group is in fact gone, so recovery may resolve it by ESRCH; the point of this
    # test is only that the close append itself is gated on the confirmation
    assert "writer_closed" not in _kinds(root, op)[-3:]


# --- 11. The PID-namespace rule for ESRCH (fix4) ----------------------------------------
#
# A PGID is a number in one PID namespace. ESRCH proves a writer gone only when the
# observer's /proc/self/ns/pid is positively the namespace recorded with the PGID, on the
# same boot. Missing, malformed, different or unreadable identities keep the staging, and
# the current operation's recovery report says why. Real foreign-namespace runs (unshare,
# docker) are in tests/test_core_install_bootstrap.py and the fix4 evidence; here the
# observer's namespace is SIMULATED where named.


def _reaped_group():
    """A real process group that existed and is now gone (killed and reaped): ESRCH."""
    process = subprocess.Popen(["sleep", "60"], start_new_session=True)
    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    return process.pid


def _writer_records(journal, pgid, *, namespace="real"):
    """Record a writer (intent + pgid) whose PGID is ``pgid``; ``namespace=None`` is
    FAULT-INJECTED: the identity could not be read when the records were written."""
    real = install_cancel.current_pid_namespace
    if namespace is None:
        install_journal.install_cancel.current_pid_namespace = lambda: None
    try:
        token = journal.begin_writer(["writer"])
        journal.writer_spawned(token, pgid)
    finally:
        install_journal.install_cancel.current_pid_namespace = real
    return token


@POSIX_ONLY
def test_fix4_writer_records_carry_the_namespace_of_the_pgid_viewpoint(tmp_path):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    install_cancel.cancellable_run(guard, "install_packages", [sys.executable, "-c", "pass"])
    intent, pgid_record = [r for r in _records(root, op) if r["record"] in ("writer_intent", "writer_pgid")]
    assert intent["pid_namespace"] == pgid_record["pid_namespace"] == install_cancel.current_pid_namespace()
    assert install_cancel.valid_pid_namespace(pgid_record["pid_namespace"])


@POSIX_ONLY
def test_fix4_esrch_without_a_recorded_namespace_keeps_the_staging(tmp_path):
    """Sol's fix3 blocker, Core route, without the foreign observer: the group is REALLY
    gone (ESRCH) but the records name no namespace, so nothing proves it was observed
    from here; the fresh lock's recovery keeps the operation and reports the reason."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    _writer_records(journal, _reaped_group(), namespace=None)
    journal.close()
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.complete is False and rec.deferred_writer["reason"] == "pid_namespace_unrecorded"
    assert rec.items[0]["outcome"] == install_journal.KEPT_WRITER_MAY_BE_ALIVE
    assert staged.read_bytes() == b"partial"


@POSIX_ONLY
def test_fix4_a_suspect_record_without_a_namespace_keeps_the_staging(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    journal.close()
    install_journal.record_suspected_writer(root, op, pgid=_reaped_group(), pid_namespace="")
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["reason"] == "pid_namespace_unrecorded" and staged.exists()


@POSIX_ONLY
@pytest.mark.parametrize("observer, reason", [
    ("pid:[1]", "pid_namespace_differs"),   # SIMULATED: another, well-formed namespace
    (None, "pid_namespace_unreadable"),     # SIMULATED: /proc/self/ns/pid could not be read
    ("pid:[x]", "pid_namespace_unreadable"),  # SIMULATED: unparseable
])
def test_fix4_an_observer_in_another_or_unknown_namespace_keeps_the_staging(tmp_path, monkeypatch, observer, reason):
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    _writer_records(journal, _reaped_group())
    journal.close()
    if observer == install_cancel.current_pid_namespace():
        observer = "pid:[2]"
    monkeypatch.setattr(install_cancel, "current_pid_namespace", lambda: observer)
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["reason"] == reason and staged.exists()
    # positive control: the same records, observed from the recorded namespace -> cleaned
    monkeypatch.undo()
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer is None and rec.complete is True and not staged.exists()


@POSIX_ONLY
def test_fix4_intent_and_pgid_records_must_name_the_same_namespace(tmp_path):
    """A PGID record from an earlier candidate (no namespace field) or one naming another
    namespace than its intent is no proof."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    gone = _reaped_group()
    token = journal.begin_writer(["earlier-format"])
    journal._append({"record": "writer_pgid", "writer_id": token, "pgid": gone})  # fix3 format: no namespace
    other = journal.begin_writer(["inconsistent"])
    journal._append({"record": "writer_pgid", "writer_id": other, "pgid": gone, "pid_namespace": "pid:[1]"})
    journal.close()
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["writer_id"] == token and rec.deferred_writer["reason"] == "pid_namespace_unrecorded"
    # close the first; the second still blocks, now for its own reason
    journal = install_journal.Journal(root, op, os.open(root / "tmp" / op / install_journal.JOURNAL_FILENAME, os.O_WRONLY | os.O_APPEND),
                                      root / "tmp" / op)
    journal._seq = len(_records(root, op))
    journal.writer_closed(token)
    journal.close()
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer["writer_id"] == other and rec.deferred_writer["reason"] == "pid_namespace_inconsistent"
    assert staged.exists()


@POSIX_ONLY
def test_fix4_a_positively_different_boot_still_resolves_an_unrecorded_namespace(tmp_path):
    """Positive control, SIMULATED boot change: the recorded boot id is a well-formed other
    boot. The writer-liveness objection falls even though no namespace was recorded; the
    journal-driven recovery then runs under its usual rules."""
    root, op, journal, staged, guard = _ledger_root(tmp_path)
    _writer_records(journal, _reaped_group(), namespace=None)
    journal.close()
    path = root / "tmp" / op / install_journal.JOURNAL_FILENAME
    path.write_bytes(path.read_bytes().replace(install_cancel.current_boot_id().encode(), str(uuid.uuid4()).encode()))
    [rec] = _recovery_via_new_lock(root, op)
    assert rec.deferred_writer is None and rec.complete is True and not staged.exists()


@POSIX_ONLY
def test_fix4_the_retry_reports_why_it_kept_unproven_staging(tmp_path, monkeypatch):
    """The reason travels through the CURRENT operation's existing reporting path (its
    result document's recovery report); the old operation's files are not amended."""
    facts, root, _unrelated, _seen = _prepare_fake_install(tmp_path, monkeypatch)
    old_op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, old_op)
    staged = journal.create_file(journal.core_directory / "payload.bin", b"partial")
    _writer_records(journal, _reaped_group(), namespace=None)
    journal.close()
    journal_bytes = (root / "tmp" / old_op / install_journal.JOURNAL_FILENAME).read_bytes()
    code, doc = module_installer.install_module("drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts)
    assert code == 0, doc  # the retry proceeds in its own staging
    [kept] = [o for o in doc["recovery"]["operations"] if o["operation_id"] == old_op]
    assert kept["deferred_writer"]["reason"] == "pid_namespace_unrecorded"
    assert staged.exists()
    assert (root / "tmp" / old_op / install_journal.JOURNAL_FILENAME).read_bytes() == journal_bytes
    assert not (root / "logs" / old_op).exists()  # nothing was written for the old operation
