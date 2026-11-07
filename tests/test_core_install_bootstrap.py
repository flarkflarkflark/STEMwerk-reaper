"""Tests for the outer layer's bootstrap staging (O55, C24) and for starting
Core from its shipped source under ``-I`` before any venv exists (O54)."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
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
    assert bootstrap.parse_owner(line) == {"operation_id": op, "pid": 4242}


@pytest.mark.parametrize(
    "line",
    [
        "stemwerk-bootstrap-owner/1\t{op}\t4242",
        "stemwerk-bootstrap-owner/1\t{op}\t4242\r\n",
        "stemwerk-bootstrap-owner/2\t{op}\t4242\n",
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
    assert entry.owner == {"operation_id": op, "pid": 4242}
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
