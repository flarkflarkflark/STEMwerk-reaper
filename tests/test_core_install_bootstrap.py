"""Tests for the outer layer's bootstrap staging (O55, C24) and for starting
Core from its shipped source under ``-I`` before any venv exists (O54)."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import install_bootstrap as bootstrap  # noqa: E402
from stemwerk_core import install_journal, install_lock, module_install  # noqa: E402
from stemwerk_core.process_identity import ProcessProbe  # noqa: E402

pytestmark = pytest.mark.portable


@pytest.fixture(autouse=True)
def _baseline_without_the_linux_group_rule(monkeypatch):
    """The tests of the S5a baseline (PID-only owner, silence) describe the rule
    every platform keeps. The Linux writer-group evidence (S8 fix3) has its own
    tests below, which pass ``group_rule=True`` or switch the default back on."""

    monkeypatch.setattr(bootstrap, "_default_group_rule", lambda: False)

OLD = 3600.0  # seconds of silence, beyond the default stale bound
CLI_TIMEOUT = 60


def new_op() -> str:
    return str(uuid.uuid4())


def probe_answer(running):
    calls = []

    def probe(pid):
        calls.append(pid)
        return ProcessProbe(running, None)

    probe.calls = calls
    return probe


def age(paths, seconds: float) -> None:
    moment = time.time() - seconds
    for path in paths:
        os.utime(path, (moment, moment))


def make_staging(root: Path, op: str, *, pid=None, owner_bytes=None, silent=OLD, events=True) -> Path:
    """An outer layer's operation: events file plus tmp/<op>/bootstrap/ with an archive part."""

    staging = root / "tmp" / op / "bootstrap"
    staging.mkdir(parents=True)
    paths = [staging]
    if owner_bytes is None and pid is not None:
        owner_bytes = bootstrap.owner_line(op, pid)
    if owner_bytes is not None:
        (staging / "owner").write_bytes(owner_bytes)
        paths.append(staging / "owner")
    (staging / "python.tar.gz.part").write_bytes(b"x" * 1024)
    (staging / "python").mkdir()
    (staging / "python" / "bin").mkdir()
    paths += [staging / "python.tar.gz.part", staging / "python"]
    if events:
        log = root / "logs" / op
        log.mkdir(parents=True)
        (log / "events.ndjson").write_bytes(b"")
        paths.append(log / "events.ndjson")
    age(paths, silent)
    return staging


def inspect(root, probe, **kwargs):
    report = bootstrap.inspect_staging(root, probe=probe, **kwargs)
    return {entry.operation_id: entry for entry in report.entries}


# --- owner record ------------------------------------------------------------


def test_owner_record_round_trip():
    op = new_op()
    line = bootstrap.owner_line(op, 4242)
    assert line == f"stemwerk-bootstrap-owner/1\t{op}\t4242\n".encode("ascii")
    assert bootstrap.parse_owner(line) == {"operation_id": op, "pid": 4242, "version": 1}
    v2 = bootstrap.owner_line(op, 4242, version=2)
    assert v2 == f"stemwerk-bootstrap-owner/2\t{op}\t4242\n".encode("ascii")
    assert bootstrap.parse_owner(v2) == {"operation_id": op, "pid": 4242, "version": 2}


@pytest.mark.parametrize(
    "line",
    [
        "stemwerk-bootstrap-owner/1\t{op}\t4242",
        "stemwerk-bootstrap-owner/1\t{op}\t4242\r\n",
        "stemwerk-bootstrap-owner/3\t{op}\t4242\n",
        "stemwerk-bootstrap-owner/1\t{op}\t4242\textra\n",
        "stemwerk-bootstrap-owner/1\t{op}\t0\n",
        "stemwerk-bootstrap-owner/1\t{op}\t04242\n",
        "stemwerk-bootstrap-owner/1\t{op}\t-1\n",
        "stemwerk-bootstrap-owner/1\t{op}\t42a\n",
        "stemwerk-bootstrap-owner/1\t{op}\t2147483648\n",
        "stemwerk-bootstrap-owner/1\t{upper}\t4242\n",
        "stemwerk-bootstrap-owner/1\tnot-a-uuid\t4242\n",
        "stemwerk-bootstrap-owner/1\t{op}\t٤٢\n",
    ],
)
def test_malformed_owner_records_are_not_trusted(line):
    op = new_op()
    data = line.format(op=op, upper=op.upper()).encode("utf-8")
    assert bootstrap.parse_owner(data) is None


def test_owner_line_refuses_invalid_values():
    with pytest.raises(ValueError):
        bootstrap.owner_line(new_op(), 0)
    with pytest.raises(Exception):
        bootstrap.owner_line("NOT-A-UUID", 1)


# --- liveness classification (read-only) ---------------------------------------


@pytest.mark.native_publication
def test_silent_staging_of_a_dead_owner_is_stale(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, pid=4242)
    probe = probe_answer(False)
    entry = inspect(tmp_path, probe)[op]
    assert entry.status == bootstrap.STALE
    assert entry.owner == {"operation_id": op, "pid": 4242, "version": 1}
    assert entry.owner_running is False
    assert entry.silent_seconds >= OLD - 5
    assert probe.calls == [4242]


@pytest.mark.native_publication
@pytest.mark.parametrize(
    "running, status",
    [(True, bootstrap.ACTIVE_OWNER_RUNNING), (None, bootstrap.OWNER_UNKNOWN)],
)
def test_a_running_or_undeterminable_owner_keeps_silent_staging(tmp_path, running, status):
    op = new_op()
    make_staging(tmp_path, op, pid=4242)
    assert inspect(tmp_path, probe_answer(running))[op].status == status


@pytest.mark.native_publication
def test_a_failing_probe_keeps_the_staging(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, pid=4242)

    def probe(pid):
        raise RuntimeError("cannot ask")

    entry = inspect(tmp_path, probe)[op]
    assert (entry.status, entry.owner_running) == (bootstrap.OWNER_UNKNOWN, None)


@pytest.mark.native_publication
def test_recent_activity_keeps_staging_even_when_the_owner_is_gone(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, pid=4242, silent=10)
    assert inspect(tmp_path, probe_answer(False))[op].status == bootstrap.ACTIVE_RECENT


@pytest.mark.native_publication
@pytest.mark.parametrize("fresh", ["events", "entry", "staging"])
def test_each_activity_source_counts(tmp_path, fresh):
    op = new_op()
    staging = make_staging(tmp_path, op, pid=4242)
    path = {
        "events": tmp_path / "logs" / op / "events.ndjson",
        "entry": staging / "python.tar.gz.part",
        "staging": staging,
    }[fresh]
    age([path], 1)
    assert inspect(tmp_path, probe_answer(False))[op].status == bootstrap.ACTIVE_RECENT


@pytest.mark.native_publication
def test_without_an_owner_record_only_silence_decides(tmp_path):
    old, recent = new_op(), new_op()
    make_staging(tmp_path, old, events=False)
    make_staging(tmp_path, recent, silent=5, events=False)
    probe = probe_answer(True)
    entries = inspect(tmp_path, probe)
    assert entries[old].status == bootstrap.STALE
    assert entries[recent].status == bootstrap.ACTIVE_RECENT
    assert probe.calls == []


@pytest.mark.native_publication
def test_malformed_owner_is_reported_and_silence_decides(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, owner_bytes=b"garbage\n")
    entry = inspect(tmp_path, probe_answer(True))[op]
    assert entry.status == bootstrap.STALE
    assert entry.owner is None
    assert entry.detail == "owner record is malformed"


@pytest.mark.native_publication
def test_owner_record_of_another_operation_keeps_the_staging(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, owner_bytes=bootstrap.owner_line(new_op(), 4242))
    assert inspect(tmp_path, probe_answer(False))[op].status == bootstrap.OWNER_OTHER_OPERATION


@pytest.mark.native_publication
def test_current_operation_and_foreign_entries_are_never_judged(tmp_path):
    current = new_op()
    current_staging = make_staging(tmp_path, current, pid=4242)
    # Change a hex digit as well as case: this is a different directory on Windows too.
    foreign_upper = ("B" if current[0] == "a" else "A") + current[1:].upper()
    assert foreign_upper.casefold() != current
    foreign_staging = [
        tmp_path / "tmp" / "not-an-operation" / "bootstrap",
        tmp_path / "tmp" / foreign_upper / "bootstrap",
    ]
    for staging in foreign_staging:
        staging.mkdir(parents=True)
        (staging / "keep").write_bytes(b"keep")
    without_staging = tmp_path / "tmp" / new_op()  # canonical operation without bootstrap
    without_staging.mkdir()
    probe = probe_answer(False)
    report = bootstrap.inspect_staging(tmp_path, current_operation_id=current, probe=probe)
    assert [(e.operation_id, e.status) for e in report.entries] == [(current, bootstrap.CURRENT_OPERATION)]
    assert probe.calls == []
    assert (current_staging / "python.tar.gz.part").read_bytes() == b"x" * 1024
    assert all((staging / "keep").read_bytes() == b"keep" for staging in foreign_staging)
    assert without_staging.is_dir()


@pytest.mark.native_publication
def test_inspection_writes_nothing(tmp_path):
    for _ in range(2):
        make_staging(tmp_path, new_op(), pid=4242)

    def snapshot():
        return sorted((str(p), p.stat().st_mtime_ns) for p in tmp_path.rglob("*"))

    before = snapshot()
    bootstrap.inspect_staging(tmp_path, probe=probe_answer(False))
    assert snapshot() == before


def test_no_tmp_directory_is_an_empty_report(tmp_path):
    assert bootstrap.inspect_staging(tmp_path / "absent").entries == []


# --- removal --------------------------------------------------------------------


@pytest.mark.native_publication
def test_only_stale_staging_is_removed(tmp_path):
    stale, running, recent = new_op(), new_op(), new_op()
    for op in (stale, running):
        make_staging(tmp_path, op, pid=4242 if op == stale else 4343)
    make_staging(tmp_path, recent, pid=4444, silent=5)

    def probe(pid):
        return ProcessProbe(pid == 4343, None)

    report = bootstrap.remove_stale_staging(tmp_path, probe=probe)
    outcomes = {e.operation_id: (e.status, e.outcome) for e in report.entries}
    assert outcomes == {
        stale: (bootstrap.STALE, bootstrap.REMOVED),
        running: (bootstrap.ACTIVE_OWNER_RUNNING, None),
        recent: (bootstrap.ACTIVE_RECENT, None),
    }
    assert report.complete
    assert not (tmp_path / "tmp" / stale).exists()  # empty operation directory goes too
    assert (tmp_path / "logs" / stale / "events.ndjson").exists()  # logs are kept
    for op in (running, recent):
        assert (tmp_path / "tmp" / op / "bootstrap" / "python.tar.gz.part").exists()
    assert json.loads(json.dumps(report.to_json()))["complete"] is True


@pytest.mark.native_publication
def test_core_journal_and_staging_beside_bootstrap_are_untouched(tmp_path):
    op = new_op()
    staging = make_staging(tmp_path, op, pid=4242)
    (staging.parent / install_journal.JOURNAL_FILENAME).write_bytes(b"{}\n")
    (staging.parent / install_journal.CORE_DIRECTORY).mkdir()
    (staging.parent / install_journal.CORE_DIRECTORY / "venv").write_bytes(b"core")
    report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False))
    assert report.entries[0].outcome == bootstrap.REMOVED
    assert not staging.exists()
    assert (staging.parent / install_journal.JOURNAL_FILENAME).read_bytes() == b"{}\n"
    assert (staging.parent / "core" / "venv").read_bytes() == b"core"


@pytest.mark.native_publication
def test_replaced_staging_is_kept(tmp_path):
    op = new_op()
    staging = make_staging(tmp_path, op, pid=4242)
    entry = bootstrap.inspect_staging(tmp_path, probe=probe_answer(False)).entries[0]
    staging.rename(staging.parent / "moved")
    staging.mkdir()
    (staging / "new").write_bytes(b"new")
    assert bootstrap._remove(tmp_path, entry) == bootstrap.KEPT_IDENTITY_MISMATCH
    assert (staging / "new").read_bytes() == b"new"


def _link_directory(link: Path, target: Path) -> None:
    if os.name == "nt":
        import _winapi

        _winapi.CreateJunction(str(target), str(link))
    else:
        link.symlink_to(target, target_is_directory=True)


@pytest.mark.native_publication
def test_links_inside_stale_staging_are_removed_without_following(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_bytes(b"keep")
    root = tmp_path / "root"
    op = new_op()
    staging = make_staging(root, op, pid=4242)
    _link_directory(staging / "python" / "escape", outside)
    age([staging / "python", staging], OLD)
    report = bootstrap.remove_stale_staging(root, probe=probe_answer(False))
    assert report.entries[0].outcome == bootstrap.REMOVED
    assert not (root / "tmp" / op).exists()
    assert (outside / "keep.txt").read_bytes() == b"keep"


@pytest.mark.native_publication
@pytest.mark.parametrize("linked", ["bootstrap", "operation"])
def test_linked_staging_or_operation_directory_is_kept(tmp_path, linked):
    outside = tmp_path / "outside"
    (outside / "bootstrap").mkdir(parents=True)
    (outside / "bootstrap" / "keep.txt").write_bytes(b"keep")
    root = tmp_path / "root"
    op = new_op()
    (root / "tmp").mkdir(parents=True)
    if linked == "bootstrap":
        (root / "tmp" / op).mkdir()
        _link_directory(root / "tmp" / op / "bootstrap", outside / "bootstrap")
    else:
        _link_directory(root / "tmp" / op, outside)
    report = bootstrap.remove_stale_staging(root, probe=probe_answer(False))
    assert [(e.status, e.outcome) for e in report.entries] == [(bootstrap.INELIGIBLE, None)]
    assert report.complete
    assert (outside / "bootstrap" / "keep.txt").read_bytes() == b"keep"


# --- real processes ---------------------------------------------------------------


@pytest.mark.native_publication
def test_real_probe_keeps_staging_of_a_live_outer_layer(tmp_path):
    op = new_op()
    make_staging(tmp_path, op, pid=os.getpid())
    report = bootstrap.remove_stale_staging(tmp_path)
    assert [(e.status, e.owner_running) for e in report.entries] == [
        (bootstrap.ACTIVE_OWNER_RUNNING, True)
    ]
    assert (tmp_path / "tmp" / op / "bootstrap").is_dir()


@pytest.mark.native_publication
def test_real_probe_removes_staging_of_an_exited_outer_layer(tmp_path):
    child = subprocess.run([sys.executable, "-c", "import os; print(os.getpid())"],
                           capture_output=True, timeout=CLI_TIMEOUT, check=True)
    pid = int(child.stdout)
    op = new_op()
    make_staging(tmp_path, op, pid=pid)
    report = bootstrap.remove_stale_staging(tmp_path)
    assert [(e.status, e.owner_running, e.outcome) for e in report.entries] == [
        (bootstrap.STALE, False, bootstrap.REMOVED)
    ]


# --- next start of Core: lock acquisition -----------------------------------------


@pytest.mark.native_publication
def test_acquiring_the_lock_removes_stale_and_keeps_active_staging(tmp_path):
    root = tmp_path / "root"
    stale, active, current = new_op(), new_op(), new_op()
    make_staging(root, stale, pid=4242)
    make_staging(root, active, pid=os.getpid())
    make_staging(root, current, pid=4242)

    def probe(pid):
        return ProcessProbe(pid == os.getpid(), None)

    lock = install_lock.acquire(root, current, probe=probe)
    try:
        statuses = {e.operation_id: (e.status, e.outcome) for e in lock.bootstrap_cleanup.entries}
    finally:
        lock.release()
    assert statuses == {
        stale: (bootstrap.STALE, bootstrap.REMOVED),
        active: (bootstrap.ACTIVE_OWNER_RUNNING, None),
        current: (bootstrap.CURRENT_OPERATION, None),
    }
    assert not (root / "tmp" / stale).exists()
    assert (root / "tmp" / active / "bootstrap").is_dir()
    assert (root / "tmp" / current / "bootstrap").is_dir()


@pytest.mark.native_publication
def test_failing_cleanup_releases_the_lock(tmp_path, monkeypatch):
    root = tmp_path / "root"

    def boom(*args, **kwargs):
        raise bootstrap.BootstrapStagingError("bootstrap_path_unavailable", "boom")

    monkeypatch.setattr(install_lock.install_bootstrap, "remove_stale_staging", boom)
    with pytest.raises(bootstrap.BootstrapStagingError):
        install_lock.acquire(root, new_op())
    monkeypatch.undo()
    install_lock.acquire(root, new_op()).release()  # the lock was released


# --- O54: Core from its shipped source under -I, before any venv ------------------


def run_entry(source: Path, arguments, *, cwd: Path, env=None, flags=("-I", "-B")):
    return subprocess.run(
        [sys.executable, *flags, str(source), *arguments],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=CLI_TIMEOUT,
    )


def shipped_copy(destination: Path) -> Path:
    """The tracked Core source as a front end ships it (no build metadata, no caches)."""

    shutil.copytree(
        CORE_SRC, destination,
        ignore=shutil.ignore_patterns("__pycache__", "*.egg-info", "*.pyc"),
    )
    return destination


@pytest.mark.native_publication
def test_isolated_directory_entry_starts_core(tmp_path):
    source = shipped_copy(tmp_path / "Scripts" / "Jürgen ñ 名" / "src")
    elsewhere = tmp_path / "cwd"
    (elsewhere / "stemwerk_core").mkdir(parents=True)
    (elsewhere / "stemwerk_core" / "__init__.py").write_text("raise SystemExit(99)\n", encoding="utf-8")
    env = {**os.environ, "PYTHONPATH": str(elsewhere), "PYTHONSTARTUP": str(elsewhere / "x.py")}
    result = run_entry(source, ["--describe"], cwd=elsewhere, env=env)
    assert result.returncode == 0, result.stderr
    assert result.stderr == b""
    document = json.loads(result.stdout)
    assert document["kind"] == module_install.DESCRIBE_KIND
    assert document["operations"] == list(module_install.OPERATIONS)
    assert document["core_version"] is None  # a shipped source tree has no distribution metadata
    assert not list(source.rglob("__pycache__"))  # -B: the shipped source stays unchanged


@pytest.mark.native_publication
def test_isolated_directory_entry_keeps_the_cli_contract(tmp_path):
    source = shipped_copy(tmp_path / "src")
    root = tmp_path / "runtime-root"
    env = {**os.environ, "STEMWERK_RUNTIME_ROOT": str(root)}
    plan = run_entry(source, ["plan", "--module", "drum_kit"], cwd=tmp_path, env=env)
    assert plan.returncode == 0, plan.stderr
    assert json.loads(plan.stdout)["kind"] == "stemwerk_module_install_plan"
    assert not root.exists()
    unknown = run_entry(source, ["verify", "--module", "nope"], cwd=tmp_path, env=env)
    assert unknown.returncode == 2
    assert unknown.stdout == b""
    assert json.loads(unknown.stderr)["error"]["code"] == "unknown_module"


@pytest.mark.native_publication
def test_core_bootstrap_modules_import_only_the_standard_library(tmp_path):
    # -S: no site-packages at all, as in a fresh managed Python before any venv.
    script = (
        "import sys; sys.path.insert(0, sys.argv[1])\n"
        "import stemwerk_core.module_install, stemwerk_core.install_lock\n"
        "import stemwerk_core.install_bootstrap, stemwerk_core.managed_python\n"
        "import stemwerk_core.runtime_manifest as m; m.load_manifest()\n"
        "extra = {n.split('.')[0] for n in sys.modules} - set(sys.stdlib_module_names)\n"
        "print(sorted(extra - {'stemwerk_core', '__main__'}))\n"
    )
    result = subprocess.run(
        [sys.executable, "-I", "-S", "-B", "-c", script, str(shipped_copy(tmp_path / "src"))],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=CLI_TIMEOUT,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == b"[]"


# --- the Linux writer-group evidence (S8 fix3) ---------------------------------
#
# Core only reads ``bootstrap/owner`` (protocol /2) and ``bootstrap/group`` and
# probes the recorded group; it writes nothing before the lock. A /2 owner
# without a group record means no writer was ever released.

from stemwerk_core import install_cancel  # noqa: E402

POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="process groups")


def make_group_staging(root, op, *, group_bytes=None, owner_version=2, owner_pid=4242):
    staging = make_staging(root, op, owner_bytes=bootstrap.owner_line(op, owner_pid, version=owner_version))
    if group_bytes is not None:
        (staging / "group").write_bytes(group_bytes)
    # make_staging aged only what it knew about; age the new file as well
    age([staging, staging / "group"] if group_bytes is not None else [staging], OLD)
    return staging


def group_for(root, op, pgid, *, boot=None, namespace=None):
    return bootstrap.group_line(
        op, str(root / "tmp" / op / "bootstrap"), pgid,
        boot if boot is not None else (install_cancel.current_boot_id() or "no-boot"),
        namespace if namespace is not None else (install_cancel.current_pid_namespace() or ""),
    )


def _inspect(root, **kwargs):
    report = bootstrap.inspect_staging(root, probe=probe_answer(False), group_rule=True, **kwargs)
    return {entry.operation_id: entry for entry in report.entries}


def _live_group():
    process = subprocess.Popen(["sleep", "60"], start_new_session=True)
    return process


def _end_group(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


def test_group_record_round_trips_and_rejects_malformed_lines(tmp_path):
    op = new_op()
    line = bootstrap.group_line(op, "/r/tmp/x/bootstrap", 4321, "boot-1", "pid:[1]")
    assert line == f"stemwerk-bootstrap-group/1\t{op}\t/r/tmp/x/bootstrap\t4321\tboot-1\tpid:[1]\n".encode()
    assert bootstrap.parse_group(line) == {
        "operation_id": op, "staging": "/r/tmp/x/bootstrap", "pgid": 4321,
        "boot_id": "boot-1", "pid_namespace": "pid:[1]",
    }
    assert bootstrap.parse_group(bootstrap.group_line(op, "/r/s", 4321, "b", ""))["pid_namespace"] is None
    for bad in (line[:-1], line.replace(b"4321", b"1"), line.replace(b"4321", b"0123"),
                line.replace(b"/r/tmp/x/bootstrap", b"relative"), line.replace(b"boot-1", b""),
                line.replace(b"stemwerk-bootstrap-group/1", b"stemwerk-bootstrap-group/2"), line + b"x\n"):
        assert bootstrap.parse_group(bad) is None, bad


def test_legacy_pid_only_and_missing_owner_keep_the_staging_on_linux(tmp_path):
    legacy, bare = new_op(), new_op()
    make_group_staging(tmp_path, legacy, owner_version=1)
    make_staging(tmp_path, bare)  # no owner record at all
    entries = _inspect(tmp_path)
    assert entries[legacy].status == bootstrap.KEPT_WRITER_UNPROVEN
    assert entries[bare].status == bootstrap.KEPT_WRITER_UNPROVEN
    report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False), group_rule=True)
    assert all(entry.outcome is None for entry in report.entries)
    assert (tmp_path / "tmp" / legacy / "bootstrap").is_dir() and (tmp_path / "tmp" / bare / "bootstrap").is_dir()


def test_a_v2_owner_without_a_group_record_is_kept_because_its_absence_is_no_proof(tmp_path):
    """fix4: no worker was released, but the controller writes the staging itself and was
    judged gone by PID alone; the owner record names no PID namespace and no boot."""
    op = new_op()
    make_group_staging(tmp_path, op)
    entry = _inspect(tmp_path)[op]
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and "no group record" in entry.detail
    report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False), group_rule=True)
    assert [e.outcome for e in report.entries] == [None]
    assert (tmp_path / "tmp" / op / "bootstrap" / "owner").is_file()


@POSIX_ONLY
def test_a_live_group_keeps_the_staging_and_a_gone_group_releases_it(tmp_path):
    op = new_op()
    writer = _live_group()
    try:
        make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, writer.pid))
        entry = _inspect(tmp_path)[op]
        assert entry.status == bootstrap.KEPT_WRITER_GROUP_ALIVE and "process_group_alive" in entry.detail
        report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False), group_rule=True)
        assert [e.outcome for e in report.entries] == [None]
        assert (tmp_path / "tmp" / op / "bootstrap" / "group").is_file()
        # The writer can still create a new file through the original pathname.
        probe_file = tmp_path / "tmp" / op / "bootstrap" / "late-write"
        subprocess.run(["sh", "-c", f"echo late > {probe_file}"], check=True)
        assert probe_file.read_text() == "late\n"
        age([probe_file, probe_file.parent], OLD)  # the late write counts as activity; let it go quiet again
    finally:
        _end_group(writer)
    # Positive control: after the group is gone (reaped, ESRCH) the same staging is released.
    report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False), group_rule=True)
    assert [e.outcome for e in report.entries] == [bootstrap.REMOVED]
    assert not (tmp_path / "tmp" / op / "bootstrap").exists()


@POSIX_ONLY
def test_a_different_boot_resolves_the_group_SIMULATED_BOOT_CHANGE(tmp_path):
    """SIMULATED: the record carries another boot id, as after a reboot. The group
    id now names an unrelated live process, which the boot id makes irrelevant."""

    op = new_op()
    unrelated = _live_group()
    try:
        make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, unrelated.pid, boot=str(uuid.uuid4())))  # SIMULATED previous boot
        assert _inspect(tmp_path)[op].status == bootstrap.STALE
    finally:
        _end_group(unrelated)


@POSIX_ONLY
def test_an_unavailable_boot_id_is_not_evidence_of_a_reboot(tmp_path, monkeypatch):
    op = new_op()
    writer = _live_group()
    try:
        monkeypatch.setattr(install_cancel, "current_boot_id", lambda: None)
        make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, writer.pid, boot=str(uuid.uuid4())))  # recorded boot from elsewhere
        assert _inspect(tmp_path)[op].status == bootstrap.KEPT_WRITER_GROUP_ALIVE
    finally:
        _end_group(writer)
    # fix4 rule: the group answers ESRCH, but without a positively identical boot that is
    # no proof: the staging stays and the reason is reported.
    entry = _inspect(tmp_path)[op]
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and "boot_id_unavailable" in entry.detail


@pytest.mark.parametrize(
    "mutate",
    [
        lambda line, op: line[:-1],                                   # incomplete
        lambda line, op: b"garbage\n",                                # malformed
        lambda line, op: line.replace(op.encode(), new_op().encode()),  # another operation
        lambda line, op: line.replace(b"/tmp/", b"/other/"),            # another staging path
    ],
)
def test_malformed_or_mismatching_group_records_keep_the_staging(tmp_path, mutate):
    op = new_op()
    make_group_staging(tmp_path, op, group_bytes=mutate(group_for(tmp_path, op, 999999), op))
    assert _inspect(tmp_path)[op].status == bootstrap.KEPT_WRITER_UNPROVEN


def test_an_unreadable_group_record_keeps_the_staging(tmp_path):
    op = new_op()
    staging = make_group_staging(tmp_path, op, group_bytes=b"x")
    (staging / "group").unlink()
    (staging / "group").symlink_to(tmp_path / "elsewhere")
    os.utime(staging / "group", (time.time() - OLD, time.time() - OLD), follow_symlinks=False)
    age([staging], OLD)
    assert _inspect(tmp_path)[op].status == bootstrap.KEPT_WRITER_UNPROVEN


@POSIX_ONLY
def test_the_lock_acquisition_honours_the_group_rule(tmp_path, monkeypatch):
    """Under the real install lock; the 15 minutes of silence are SIMULATED with a clock offset."""

    monkeypatch.setattr(bootstrap, "_default_group_rule", lambda: True)
    op = new_op()
    writer = _live_group()
    try:
        make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, writer.pid))
        lock = install_lock.acquire(tmp_path, new_op(), clock=lambda: time.time() + 1000, probe=probe_answer(False))
        try:
            assert [e.status for e in lock.bootstrap_cleanup.entries] == [bootstrap.KEPT_WRITER_GROUP_ALIVE]
        finally:
            lock.release()
        assert (tmp_path / "tmp" / op / "bootstrap").is_dir()
    finally:
        _end_group(writer)
    lock = install_lock.acquire(tmp_path, new_op(), clock=lambda: time.time() + 1000, probe=probe_answer(False))
    try:
        assert [e.outcome for e in lock.bootstrap_cleanup.entries] == [bootstrap.REMOVED]
    finally:
        lock.release()


# --- the PID-namespace rule for ESRCH (S8 fix4) ----------------------------------------
#
# ESRCH (an empty group) proves a writer gone only when the observer's /proc/self/ns/pid is
# positively the namespace recorded with the PGID, on the same boot, and - for the owner's
# absence judged through /proc - when /proc numbers the observer's own namespace. The
# simulated variants say so; the "REAL" tests run the observer in a separate PID namespace
# with unshare and skip only where user namespaces are not available.

import json as _json  # noqa: E402

PY = sys.executable
SRC = str(CORE_SRC)


def _reaped_group():
    process = subprocess.Popen(["sleep", "60"], start_new_session=True)
    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    return process.pid


def _stale_entry(root, op):
    return _inspect(root)[op]


def test_fix4_a_group_record_without_a_namespace_is_no_proof(tmp_path):
    op = new_op()
    make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, _reaped_group(), namespace=""))
    entry = _stale_entry(tmp_path, op)
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and "pid_namespace_unrecorded" in entry.detail
    report = bootstrap.remove_stale_staging(tmp_path, probe=probe_answer(False), group_rule=True)
    assert [e.outcome for e in report.entries] == [None]  # the reason is in this run's report; nothing removed


@pytest.mark.parametrize("observer, reason", [
    ("pid:[1]", "pid_namespace_differs"),       # SIMULATED other namespace
    (None, "pid_namespace_unreadable"),         # SIMULATED unreadable /proc/self/ns/pid
])
def test_fix4_an_observer_in_another_or_unknown_namespace_is_no_proof(tmp_path, monkeypatch, observer, reason):
    op = new_op()
    make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, _reaped_group()))
    if observer == install_cancel.current_pid_namespace():
        observer = "pid:[2]"
    monkeypatch.setattr(install_cancel, "current_pid_namespace", lambda: observer)
    entry = _stale_entry(tmp_path, op)
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and reason in entry.detail
    monkeypatch.undo()
    monkeypatch.setattr(bootstrap, "_default_group_rule", lambda: False)
    # positive control: same namespace, same boot, the group really gone -> stale
    assert _stale_entry(tmp_path, op).status == bootstrap.STALE


def test_fix4_the_owners_absence_needs_a_proc_view_of_the_own_namespace(tmp_path, monkeypatch):
    """SIMULATED foreign /proc view: the group answered ESRCH in the recorded namespace,
    but the owner was judged 'not running' through a /proc that numbers another
    namespace; that is no proof."""
    op = new_op()
    make_group_staging(tmp_path, op, group_bytes=group_for(tmp_path, op, _reaped_group()))
    monkeypatch.setattr(install_cancel, "proc_view_is_own", lambda: False)
    entry = _stale_entry(tmp_path, op)
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and "/proc is not its own" in entry.detail


def _unshare(*, mount_proc=True):
    base = ["unshare", "--user", "--map-root-user", "--pid", "--fork"]
    return base + ["--mount-proc"] if mount_proc else base


def _foreign_namespaces_available():
    if os.name == "nt" or shutil.which("unshare") is None:
        return False
    try:
        return subprocess.run(_unshare() + ["true"], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


REAL_FOREIGN_NS = pytest.mark.skipif(not _foreign_namespaces_available(),
                                     reason="unprivileged user + PID namespaces are not available here")

_WRITER = ("import pathlib,sys,time\n"
           "stage,trig,st=map(pathlib.Path,sys.argv[1:])\n"
           "while not trig.exists(): time.sleep(.02)\n"
           "try:\n    (stage/'created-after-retry').write_text('created via original staging path'); st.write_text('created')\n"
           "except OSError as e:\n    st.write_text(type(e).__name__+': '+str(e))\n"
           "time.sleep(30)\n")


def _run_in_foreign_ns(code, *args, mount_proc=True):
    run = subprocess.run(_unshare(mount_proc=mount_proc) + [PY, "-I", "-c", code, SRC, *map(str, args)],
                         capture_output=True, text=True, timeout=60)
    assert run.returncode == 0, run.stderr[-2000:]
    return _json.loads(run.stdout.strip().splitlines()[-1])


def _late_write_by_original_path(root, stage, writer):
    """Let the still-live writer create a NEW file through its original staging path and
    read it from a separate process."""
    (root / "trigger").touch()
    deadline = time.monotonic() + 5
    while not (root / "status").exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert writer.poll() is None
    assert (root / "status").read_text() == "created"
    read = subprocess.run(["cat", str(stage / "created-after-retry")], capture_output=True, text=True)
    assert read.returncode == 0 and read.stdout == "created via original staging path"


_CORE_RETRY = '''import json,sys,uuid
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from stemwerk_core import install_cancel, install_lock
root=Path(sys.argv[2]); op=sys.argv[3]
lock=install_lock.acquire(root,str(uuid.uuid4()))
try: rec=[{"complete":o.complete,"deferred":o.deferred_writer} for o in lock.recovery.operations if o.operation_id==op]
finally: lock.release()
print(json.dumps({"observer":install_cancel.current_pid_namespace(),"recovery":rec}))
'''


@REAL_FOREIGN_NS
@pytest.mark.parametrize("record_namespace", ["missing", "recorded"])
def test_fix4_REAL_foreign_namespace_retry_keeps_a_live_writers_core_staging(tmp_path, record_namespace):
    """Core route, real separate PID namespace: a host writer is alive; the retry takes the
    real lock and runs recovery from another namespace, where the writer's group answers
    ESRCH. 'missing' FAULT-INJECTS a record without a namespace (Sol's case)."""
    root = tmp_path / "root"
    root.mkdir(mode=0o700)
    op = new_op()
    journal = install_journal.open_journal(root, op)
    stage = journal.create_directory(journal.core_directory / "stage")
    journal.create_file(stage / "sentinel", b"original pathname")
    real = install_cancel.current_pid_namespace
    if record_namespace == "missing":
        install_journal.install_cancel.current_pid_namespace = lambda: None
    writer = None
    try:
        token = journal.begin_writer(["live-writer"])
        writer = subprocess.Popen([PY, "-c", _WRITER, str(stage), str(root / "trigger"), str(root / "status")], start_new_session=True)
        journal.writer_spawned(token, writer.pid)
    finally:
        install_journal.install_cancel.current_pid_namespace = real
    journal.close()
    try:
        out = _run_in_foreign_ns(_CORE_RETRY, root, op)
        assert out["observer"] != real()
        [rec] = out["recovery"]
        expected = "pid_namespace_unrecorded" if record_namespace == "missing" else "pid_namespace_differs"
        assert rec["complete"] is False and rec["deferred"]["reason"] == expected
        assert (stage / "sentinel").read_bytes() == b"original pathname"
        _late_write_by_original_path(root, stage, writer)
    finally:
        os.killpg(writer.pid, signal.SIGKILL)
        writer.wait(timeout=5)
    # positive control: same namespace, same boot, the group really gone -> ordinary cleanup
    if record_namespace == "recorded":
        lock = install_lock.acquire(root, new_op())
        try:
            [rec] = [o for o in lock.recovery.operations if o.operation_id == op]
        finally:
            lock.release()
        assert rec.complete is True and not stage.exists()


_BOOT_RETRY = '''import json,sys,time,uuid
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from stemwerk_core import install_cancel, install_lock
root=Path(sys.argv[2]); op=sys.argv[3]
lock=install_lock.acquire(root,str(uuid.uuid4()),clock=lambda:time.time()+1000)
try: entries=[e.to_json() for e in lock.bootstrap_cleanup.entries if e.operation_id==op]
finally: lock.release()
print(json.dumps({"observer":install_cancel.current_pid_namespace(),"entries":entries}))
'''


@REAL_FOREIGN_NS
@pytest.mark.parametrize("namespace_field", ["empty", "recorded"])
def test_fix4_REAL_foreign_namespace_stale_cleanup_keeps_a_live_writers_bootstrap_staging(tmp_path, namespace_field):
    """Bootstrap route, real separate PID namespace: /2 owner + group record of a live host
    group ('empty' = readlink was unavailable, so the field is blank). Stale cleanup runs
    under a real lock in another namespace (15 minutes of silence SIMULATED by a clock offset)."""
    root = tmp_path / "root"
    root.mkdir(mode=0o700)
    op = new_op()
    stage = root / "tmp" / op / "bootstrap"
    stage.mkdir(parents=True, mode=0o700)
    (stage / "sentinel").write_text("same path")
    writer = subprocess.Popen([PY, "-c", _WRITER, str(stage), str(root / "trigger"), str(root / "status")], start_new_session=True)
    try:
        (stage / "owner").write_bytes(bootstrap.owner_line(op, 999999999, version=2))
        ns = "" if namespace_field == "empty" else install_cancel.current_pid_namespace()
        (stage / "group").write_bytes(bootstrap.group_line(op, str(stage), writer.pid, install_cancel.current_boot_id(), ns))
        out = _run_in_foreign_ns(_BOOT_RETRY, root, op)
        [entry] = out["entries"]
        expected = "pid_namespace_unrecorded" if namespace_field == "empty" else "pid_namespace_differs"
        assert entry["status"] == bootstrap.KEPT_WRITER_UNPROVEN and expected in entry["detail"] and entry["outcome"] is None
        assert (stage / "sentinel").read_text() == "same path"
        _late_write_by_original_path(root, stage, writer)
    finally:
        os.killpg(writer.pid, signal.SIGKILL)
        writer.wait(timeout=5)


_PROC_VIEW = '''import json,os,signal,subprocess,sys,time,uuid
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from stemwerk_core import install_bootstrap as b, install_cancel as c
root=Path(sys.argv[2]); op=str(uuid.uuid4()); stage=root/"tmp"/op/"bootstrap"; stage.mkdir(parents=True,mode=0o700)
p=subprocess.Popen(["sleep","60"],start_new_session=True); os.killpg(p.pid,signal.SIGKILL); p.wait()
(stage/"owner").write_bytes(b.owner_line(op,999999999,version=2))
(stage/"group").write_bytes(b.group_line(op,str(stage),p.pid,c.current_boot_id(),c.current_pid_namespace() or ""))
past=time.time()-3600
for x in (stage,stage/"owner",stage/"group"): os.utime(x,(past,past))
report=b.remove_stale_staging(root,probe=lambda pid:__import__("stemwerk_core.process_identity",fromlist=["x"]).ProcessProbe(False,None),group_rule=True)
print(json.dumps({"proc_view_is_own":c.proc_view_is_own(),"entries":[e.to_json() for e in report.entries],"stage_exists":stage.exists()}))
'''


@REAL_FOREIGN_NS
@pytest.mark.parametrize("mount_proc", [False, True])
def test_fix4_REAL_proc_view_of_another_namespace_is_no_proof_of_the_owners_absence(tmp_path, mount_proc):
    """Real namespace, record and group made from inside it (the group really gone). Without
    --mount-proc, /proc numbers the OUTER namespace, so the owner's absence judged through
    /proc proves nothing and the staging stays; with --mount-proc the same evidence is
    complete and the staging is removed."""
    root = tmp_path / "root"
    root.mkdir(mode=0o700)
    out = _run_in_foreign_ns(_PROC_VIEW, root, mount_proc=mount_proc)
    [entry] = out["entries"]
    assert out["proc_view_is_own"] is mount_proc
    if mount_proc:
        assert entry["outcome"] == bootstrap.REMOVED and not out["stage_exists"]
    else:
        assert entry["status"] == bootstrap.KEPT_WRITER_UNPROVEN and "/proc is not its own" in entry["detail"]
        assert out["stage_exists"]


def test_fix4_a_legacy_owner_next_to_a_complete_group_record_is_still_kept(tmp_path):
    """The legacy check still decides where the new rules would allow removal: a PID-only
    /1 owner (which never promised to publish a group record before releasing writers)
    next to a group record whose group is really gone, same namespace and boot."""
    op = new_op()
    make_group_staging(tmp_path, op, owner_version=1, group_bytes=group_for(tmp_path, op, _reaped_group()))
    entry = _stale_entry(tmp_path, op)
    assert entry.status == bootstrap.KEPT_WRITER_UNPROVEN and "legacy PID-only" in entry.detail
