"""Tests for the per-user install lock: contention, stale detection, breaking."""
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import install_events, install_lock, process_identity  # noqa: E402
from tests.asset_link_helpers import make_directory_link  # noqa: E402
from tests.cli_harness import child_env  # noqa: E402

pytestmark = pytest.mark.portable

DEADLINE = 60.0
NON_ASCII_ROOTS = ("Testgerät", "beñat")

# A Core process taking the lock. argv: core_src, mode, root, operation_id,
# control directory, JSON options. It reports to <control>/result-<op>.
CHILD = r"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from stemwerk_core import install_lock

mode, root, op, control = sys.argv[2], Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5])
options = json.loads(sys.argv[6])


def wait_for(name):
    deadline = time.monotonic() + 120
    while not (control / name).exists():
        if time.monotonic() > deadline:
            raise SystemExit(9)
        time.sleep(0.005)


def report(document):
    temp = control / f"result-{op}.tmp"
    temp.write_text(json.dumps(document), encoding="utf-8")
    os.replace(temp, control / f"result-{op}")


on_stale = None
if options.get("pause_on_stale"):
    def on_stale(judgement):
        (control / f"judged-{op}").write_text("judged", encoding="utf-8")
        deadline = time.monotonic() + options["pause_on_stale"]
        while len(list(control.glob("judged-*"))) < 2 and time.monotonic() < deadline:
            time.sleep(0.005)

if mode == "create_only":
    # A creator between the exclusive create and the metadata write.
    lock_paths = install_lock.LockPaths.for_root(root)
    lock_paths.directory.mkdir(parents=True, exist_ok=True)
    descriptor = install_lock.create_file(lock_paths.lock)
    assert install_lock._os_lock(descriptor)
    report({"ok": True, "pid": os.getpid()})
    wait_for(f"release-{op}")
    raise SystemExit(0)
if mode == "hang_before_metadata":
    # The real acquire, stopped where it writes the lock metadata.
    real_encode = install_lock._encode

    def hang(document):
        if document.get("protocol") == install_lock.LOCK_PROTOCOL:
            lock_file = install_lock.LockPaths.for_root(root).lock
            report({"ok": "hung", "os_lock_free_at_write": install_lock.os_lock_is_free(lock_file),
                    "size": lock_file.stat().st_size})
            while True:
                time.sleep(1)
        return real_encode(document)

    install_lock._encode = hang

if options.get("wait_for"):
    (control / f"ready-{op}").write_text("ready", encoding="utf-8")
    wait_for(options["wait_for"])
    time.sleep(options.get("delay", 0.0))
try:
    lock = install_lock.acquire(
        root,
        op,
        heartbeat_interval=options.get("interval", 5.0),
        stale_after=options.get("stale_after", 30.0),
        guard_timeout=options.get("guard_timeout", 30.0),
        on_stale=on_stale,
    )
except install_lock.LockError as exc:
    report({"ok": False, "code": exc.code, "lock_status": exc.details.get("lock_status")})
    raise SystemExit(0)
report({"ok": True, "pid": os.getpid(), "broken": [p.name for p in lock.broken]})
if mode == "try":
    lock.release()
    raise SystemExit(0)
with lock:
    wait_for(f"release-{op}")
    if mode == "raise":
        raise RuntimeError("failure while holding the lock")
"""


def new_op() -> str:
    return str(uuid.uuid4())


def spawn(mode, root, op, control, **options):
    control.mkdir(exist_ok=True)
    return subprocess.Popen(
        [sys.executable, "-B", "-c", CHILD, str(CORE_SRC), mode, str(root), op, str(control),
         json.dumps(options)],
        env=child_env(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def result(control, op, child=None):
    path = control / f"result-{op}"
    deadline = time.monotonic() + DEADLINE
    while not path.exists():
        if child is not None and child.poll() is not None and not path.exists():
            raise AssertionError(f"child exited {child.returncode}: {child.stderr.read()!r}")
        assert time.monotonic() < deadline, "child did not report"
        time.sleep(0.005)
    return json.loads(path.read_text(encoding="utf-8"))


def start_together(control, ops, children):
    """Write the start signal only when every child waits for it."""

    deadline = time.monotonic() + DEADLINE
    while not all((control / f"ready-{op}").exists() for op in ops):
        for child in children:
            assert child.poll() is None, child.stderr.read()
        assert time.monotonic() < deadline, "children did not start"
        time.sleep(0.005)
    (control / "go").write_text("go", encoding="utf-8")


def finish(child, control, op):
    (control / f"release-{op}").write_text("go", encoding="utf-8")
    return child.wait(timeout=DEADLINE)


def paths(root) -> install_lock.LockPaths:
    return install_lock.LockPaths.for_root(Path(root))


def dead_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait(timeout=DEADLINE)
    return child.pid


def write_lock(root, *, pid=None, start_token="linux:other:1", host=None, age=3600.0,
               heartbeat_age=None, op=None):
    """Write a lock as a (former) holder left it; nobody holds its OS lock."""

    lock_paths = paths(root)
    lock_paths.directory.mkdir(parents=True, exist_ok=True)
    now = time.time()
    op = new_op() if op is None else op
    metadata = {
        "protocol": install_lock.LOCK_PROTOCOL,
        "operation_id": op,
        "pid": dead_pid() if pid is None else pid,
        "start_token": start_token,
        "host": process_identity.host_name() if host is None else host,
        "created": install_lock._timestamp(now - age),
    }
    lock_paths.lock.write_bytes(install_lock._encode(metadata))
    if heartbeat_age is not None:
        lock_paths.heartbeat.write_bytes(install_lock._encode({
            "protocol": install_lock.HEARTBEAT_PROTOCOL,
            "operation_id": op,
            "pid": metadata["pid"],
            "ts": install_lock._timestamp(now - heartbeat_age),
        }))
    return metadata


def broken_records(root):
    broken = paths(root).broken
    if not broken.exists():
        return []
    return sorted(p.name for p in broken.iterdir() if p.name.endswith(".break.json"))


def acquire(root, **options):
    options.setdefault("guard_timeout", 30.0)
    return install_lock.acquire(root, new_op(), **options)


# --- real multi-process contention ------------------------------------------


@pytest.mark.native_publication
def test_only_one_of_two_processes_holds_the_lock_until_release(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    first, second, third = new_op(), new_op(), new_op()
    holder = spawn("hold", root, first, control, interval=0.05)
    assert result(control, first, holder)["ok"] is True
    contender = spawn("try", root, second, control)
    assert result(control, second, contender) == {
        "ok": False, "code": "lock_held", "lock_status": "held"}
    assert contender.wait(timeout=DEADLINE) == 0
    assert finish(holder, control, first) == 0
    assert not paths(root).lock.exists()
    assert not paths(root).heartbeat.exists()
    later = spawn("try", root, third, control)
    assert result(control, third, later)["ok"] is True
    assert later.wait(timeout=DEADLINE) == 0


@pytest.mark.native_publication
def test_two_simultaneous_processes_exactly_one_wins(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    ops = [new_op(), new_op()]
    children = [spawn("hold", root, op, control, wait_for="go") for op in ops]
    start_together(control, ops, children)
    results = [result(control, op, child) for op, child in zip(ops, children)]
    assert sorted(r["ok"] for r in results) == [False, True]
    loser = next(r for r in results if not r["ok"])
    assert (loser["code"], loser["lock_status"]) == ("lock_held", "held")
    for op, child in zip(ops, children):
        assert finish(child, control, op) == 0


@pytest.mark.native_publication
def test_lock_is_released_when_the_holder_raises(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    holder = spawn("raise", root, op, control)
    assert result(control, op, holder)["ok"] is True
    assert finish(holder, control, op) == 1
    assert b"failure while holding the lock" in holder.stderr.read()
    assert not paths(root).lock.exists()
    assert install_lock.inspect_lock(root).lock_status == install_lock.FREE
    with acquire(root) as lock:
        assert lock.broken == []


@pytest.mark.native_publication
def test_hard_kill_frees_the_os_lock_and_is_stale_only_after_the_bound(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op, interval, bound = new_op(), 0.05, 2.0
    holder = spawn("hold", root, op, control, interval=interval)
    assert result(control, op, holder)["ok"] is True
    holder.kill()  # SIGKILL / TerminateProcess: no cleanup runs
    holder.wait(timeout=DEADLINE)
    killed_at = time.time()
    assert paths(root).lock.exists()

    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=bound)
    assert refused.value.code == "lock_held"

    deadline = time.monotonic() + DEADLINE
    while install_lock.os_lock_is_free(paths(root).lock) is not True:
        assert time.monotonic() < deadline, "the OS did not release the dead holder's lock"
        time.sleep(0.02)
    while True:
        try:
            lock = acquire(root, stale_after=bound)
            break
        except install_lock.LockError as exc:
            assert exc.code == "lock_held"
            assert exc.details["conditions"]["pid_running"] is not True
            assert time.monotonic() < deadline
            time.sleep(0.05)
    with lock:
        assert len(lock.broken) == 1
        record = json.loads(Path(f"{lock.broken[0]}.break.json").read_text(encoding="utf-8"))
        assert record["lock"]["operation_id"] == op
        last_heartbeat = install_lock._epoch(record["heartbeat"]["ts"])
        assert install_lock._epoch(record["broken_at"]) - last_heartbeat > bound
        assert last_heartbeat <= killed_at
        assert record["conditions"]["pid_running"] is False
        assert record["conditions"]["os_lock_free"] is True
        assert record["conditions"]["heartbeat_age_seconds"] > bound


@pytest.mark.native_publication
def test_live_owner_is_never_broken_even_with_an_old_heartbeat(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    holder = spawn("hold", root, op, control, interval=600.0)
    assert result(control, op, holder)["ok"] is True
    before = os.lstat(paths(root).lock)
    time.sleep(0.3)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.05)
    conditions = refused.value.details["conditions"]
    assert refused.value.code == "lock_held"
    assert conditions["os_lock_free"] is False
    assert conditions["heartbeat_age_seconds"] > 0.05
    after = os.lstat(paths(root).lock)
    assert (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino)
    assert broken_records(root) == []
    assert finish(holder, control, op) == 0


@pytest.mark.native_publication
def test_a_held_os_lock_alone_prevents_breaking(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    holder = spawn("hold", root, op, control, interval=600.0)
    assert result(control, op, holder)["ok"] is True
    time.sleep(0.3)  # the holder's only heartbeat is now older than the bound
    try:
        with pytest.raises(install_lock.LockError) as refused:
            acquire(root, stale_after=0.05,
                    probe=lambda pid: process_identity.ProcessProbe(False, None))
        assert refused.value.details["conditions"]["os_lock_free"] is False
        assert install_lock.read_metadata(paths(root).lock)["operation_id"] == op
        assert broken_records(root) == []
    finally:
        assert finish(holder, control, op) == 0


@pytest.mark.native_publication
def test_racing_breakers_at_most_one_wins(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    stale = write_lock(root)
    ops = [new_op(), new_op()]
    # The second starts later, so it never meets the first's momentary OS-lock
    # probe of the stale lock; with the guard it waits at the guard instead.
    children = [
        spawn("hold", root, op, control, wait_for="go", pause_on_stale=2.0, delay=delay)
        for op, delay in zip(ops, (0.0, 0.1))
    ]
    start_together(control, ops, children)
    results = {op: result(control, op, child) for op, child in zip(ops, children)}
    winners = [op for op, r in results.items() if r["ok"]]
    assert len(winners) == 1
    loser = next(r for r in results.values() if not r["ok"])
    assert (loser["code"], loser["lock_status"]) == ("lock_held", "held")
    # Only the winner judged the stale lock; the other waited at the guard.
    assert sorted(p.name for p in control.glob("judged-*")) == [f"judged-{winners[0]}"]
    assert len(broken_records(root)) == 1
    assert install_lock.read_metadata(paths(root).lock)["operation_id"] == winners[0]
    record = json.loads((paths(root).broken / broken_records(root)[0]).read_text("utf-8"))
    assert record["lock"] == stale
    for op, child in zip(ops, children):
        assert finish(child, control, op) == 0


# --- stale rule, in process ---------------------------------------------------


@pytest.mark.native_publication
def test_dead_pid_with_old_heartbeat_is_broken_and_recorded(tmp_path):
    root = tmp_path / "root"
    stale = write_lock(root, heartbeat_age=600.0)
    original = paths(root).lock.read_bytes()
    with acquire(root, stale_after=30.0) as lock:
        assert [p.name for p in lock.broken] == [p.name for p in paths(root).broken.glob("*.lock")]
        moved = lock.broken[0]
        assert moved.read_bytes() == original
        record = json.loads(Path(f"{moved}.break.json").read_text(encoding="utf-8"))
        assert sorted(record) == [
            "breaker", "broken_at", "conditions", "heartbeat", "lock", "lock_file", "protocol",
            "reason"]
        assert record["protocol"] == install_lock.BREAK_PROTOCOL
        assert record["reason"] == "stale_owner"
        assert record["lock"] == stale
        assert record["lock_file"] == moved.name
        assert record["heartbeat"]["operation_id"] == stale["operation_id"]
        assert record["breaker"] == {
            "operation_id": lock.operation_id,
            "pid": os.getpid(),
            "start_token": process_identity.current_start_token(),
            "host": process_identity.host_name(),
        }
        conditions = record["conditions"]
        assert conditions["same_host"] is True
        assert conditions["os_lock_free"] is True
        assert conditions["pid_running"] is False
        assert conditions["heartbeat_age_seconds"] > 30.0
        assert install_lock.read_heartbeat(paths(root).heartbeat)["operation_id"] == lock.operation_id


@pytest.mark.native_publication
def test_dead_pid_with_fresh_heartbeat_is_not_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root, heartbeat_age=1.0)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=30.0)
    assert refused.value.code == "lock_held"
    assert refused.value.details["conditions"]["pid_running"] is False
    assert broken_records(root) == []


@pytest.mark.native_publication
def test_heartbeat_of_another_operation_does_not_keep_a_lock_alive(tmp_path):
    root = tmp_path / "root"
    write_lock(root)
    other = write_lock(tmp_path / "other", heartbeat_age=0.0)
    paths(root).heartbeat.write_bytes(paths(tmp_path / "other").heartbeat.read_bytes())
    assert other["operation_id"] != install_lock.read_metadata(paths(root).lock)["operation_id"]
    with acquire(root, stale_after=30.0) as lock:
        assert len(lock.broken) == 1


@pytest.mark.native_publication
def test_heartbeat_counts_only_for_the_same_operation_and_pid():
    created = install_lock._timestamp(1_000.0)
    fresh = install_lock._timestamp(2_000.0)
    metadata = {"operation_id": new_op(), "pid": 4242, "created": created}

    def heartbeat(**changes):
        return {"operation_id": metadata["operation_id"], "pid": 4242, "ts": fresh, **changes}

    assert install_lock.last_heartbeat(metadata, heartbeat()) == 2_000.0
    assert install_lock.last_heartbeat(metadata, heartbeat(operation_id=new_op())) == 1_000.0
    assert install_lock.last_heartbeat(metadata, heartbeat(pid=4343)) == 1_000.0
    assert install_lock.last_heartbeat(metadata, None) == 1_000.0


def test_stale_decision_and_evidence_use_the_unrounded_heartbeat_age():
    bound = 2.0
    metadata = {
        "operation_id": new_op(),
        "pid": 4242,
        "start_token": "test:dead",
        "host": "test-host",
        "created": install_lock._timestamp(1_000.0),
    }
    cases = (
        (1.999999, install_lock.HELD),
        (2.0, install_lock.HELD),
        (2.000001, install_lock.STALE),
        (2.0004, install_lock.STALE),  # rounds to the bound at three decimals
    )

    for age, expected_status in cases:
        judgement = install_lock.judge(
            metadata,
            None,
            os_lock_free=True,
            stale_after=bound,
            now=1_000.0 + age,
            host="test-host",
            probe=lambda pid: process_identity.ProcessProbe(False, None),
        )

        assert judgement.status == expected_status
        reported_age = judgement.conditions["heartbeat_age_seconds"]
        assert reported_age == pytest.approx(age)
        assert (reported_age > bound) is (expected_status == install_lock.STALE)


@pytest.mark.native_publication
def test_fresh_heartbeat_of_another_operation_with_the_same_pid_does_not_keep_a_lock_alive(
    tmp_path,
):
    root = tmp_path / "root"
    stale = write_lock(root)  # dead PID, created an hour ago
    paths(root).heartbeat.write_bytes(install_lock._encode({
        "protocol": install_lock.HEARTBEAT_PROTOCOL,
        "operation_id": new_op(),  # same PID, another operation
        "pid": stale["pid"],
        "ts": install_lock._timestamp(time.time()),
    }))
    report = install_lock.inspect_lock(root)
    assert (report.lock_status, report.operation_id) == ("stale", stale["operation_id"])
    assert report.conditions["heartbeat_age_seconds"] > 3000
    with acquire(root, stale_after=30.0) as lock:
        record = json.loads(Path(f"{lock.broken[0]}.break.json").read_text(encoding="utf-8"))
        assert record["lock"] == stale
        assert record["conditions"]["heartbeat_age_seconds"] > 3000


@pytest.mark.native_publication
def test_pid_reuse_with_a_different_start_time_is_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root, pid=os.getpid(), start_token="reused:different-start")
    with acquire(root, stale_after=30.0) as lock:
        record = json.loads(Path(f"{lock.broken[0]}.break.json").read_text(encoding="utf-8"))
        assert record["conditions"]["pid_running"] is True
        assert record["conditions"]["start_time_matches"] is False


@pytest.mark.native_publication
def test_running_owner_with_the_same_start_time_is_not_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root, pid=os.getpid(), start_token=process_identity.current_start_token())
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.01)
    conditions = refused.value.details["conditions"]
    assert (conditions["pid_running"], conditions["start_time_matches"]) == (True, True)
    assert broken_records(root) == []


@pytest.mark.native_publication
def test_running_owner_without_a_recorded_start_time_is_not_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root, pid=os.getpid(), start_token=None)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.01)
    assert refused.value.details["conditions"]["start_time_matches"] is None
    assert broken_records(root) == []


@pytest.mark.native_publication
def test_foreign_host_lock_is_never_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root, host="another-host.example", heartbeat_age=10_000.0)
    original = paths(root).lock.read_bytes()
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.01)
    assert refused.value.code == "lock_held"
    assert refused.value.details["lock_status"] == install_lock.FOREIGN_HOST
    assert refused.value.details["conditions"]["same_host"] is False
    assert paths(root).lock.read_bytes() == original
    assert broken_records(root) == []


@pytest.mark.native_publication
def test_unprobeable_owner_is_never_broken(tmp_path):
    root = tmp_path / "root"
    write_lock(root)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.01, probe=lambda pid: process_identity.ProcessProbe(None, None))
    assert refused.value.details["lock_status"] == install_lock.UNSUPPORTED
    assert broken_records(root) == []


# Content a creator that died before or during its single metadata write leaves.
ABANDONED_CONTENT = {
    "empty": b"",
    "truncated": b'{"created":"2026-11-01T',
    "truncated-record": b'{"protocol":',
    "unparseable": b"not json\n",
    "undecodable": b"\xff\xfe\n",
}
# Complete, parseable content with invalid metadata: never a creation crash.
INVALID_CONTENT = [b'{"protocol": "stemwerk-install-lock/1"}\n', b"{}\n", b"[]\n", b"null\n"]


def write_raw_lock(root, content):
    paths(root).directory.mkdir(parents=True, exist_ok=True)
    paths(root).lock.write_bytes(content)


@pytest.mark.native_publication
@pytest.mark.parametrize("content", list(ABANDONED_CONTENT.values()), ids=list(ABANDONED_CONTENT))
def test_abandoned_lock_younger_than_the_bound_is_not_broken(tmp_path, content):
    root = tmp_path / "root"
    write_raw_lock(root, content)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=30.0)
    assert refused.value.code == "lock_unreadable"
    assert refused.value.details["os_lock_free"] is True
    assert paths(root).lock.read_bytes() == content
    assert broken_records(root) == []
    assert install_lock.inspect_lock(root) == install_lock.LockReport("unreadable", None, None)


@pytest.mark.native_publication
@pytest.mark.parametrize("content", INVALID_CONTENT)
def test_lock_with_complete_but_invalid_metadata_is_never_broken(tmp_path, content):
    root = tmp_path / "root"
    write_raw_lock(root, content)
    time.sleep(0.2)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=0.05)
    assert refused.value.code == "lock_unreadable"
    assert refused.value.details["os_lock_free"] is True
    assert paths(root).lock.read_bytes() == content
    assert broken_records(root) == []
    assert install_lock.inspect_lock(root, stale_after=0.05).lock_status == "unreadable"


@pytest.mark.native_publication
@pytest.mark.parametrize("defect", list(ABANDONED_CONTENT))
def test_abandoned_lock_older_than_the_bound_is_broken(tmp_path, defect):
    root = tmp_path / "root"
    content = ABANDONED_CONTENT[defect]
    write_raw_lock(root, content)
    time.sleep(0.2)
    report = install_lock.inspect_lock(root, stale_after=0.05)
    assert (report.lock_status, report.operation_in_progress, report.operation_id) == (
        "stale", False, None)
    with acquire(root, stale_after=0.05) as lock:
        [moved] = lock.broken
        assert ".abandoned." in moved.name
        assert moved.read_bytes() == content
        record = json.loads(Path(f"{moved}.break.json").read_text(encoding="utf-8"))
        assert record["reason"] == "abandoned_during_creation"
        assert (record["lock"], record["heartbeat"]) == (None, None)
        assert record["breaker"]["operation_id"] == lock.operation_id
        conditions = record["conditions"]
        assert conditions["metadata"] == defect.split("-")[0].replace("undecodable", "unparseable")
        assert conditions["os_lock_free"] is True
        assert conditions["lock_age_seconds"] > 0.05 == conditions["stale_after_seconds"]
        assert install_lock.read_metadata(paths(root).lock)["operation_id"] == lock.operation_id


@pytest.mark.native_publication
def test_abandoned_records_are_pruned_with_the_others(tmp_path):
    root = tmp_path / "root"
    for index in range(12):
        if index % 2:
            write_raw_lock(root, b"")
            time.sleep(0.06)
        else:
            write_lock(root)
        with acquire(root, stale_after=0.05):
            pass
    assert len(broken_records(root)) == 10
    assert len(list(paths(root).broken.glob("*.lock"))) == 10


@pytest.mark.native_publication
def test_creator_holding_the_os_lock_without_metadata_is_never_broken(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    creator = spawn("create_only", root, op, control)
    assert result(control, op, creator)["ok"] is True
    try:
        time.sleep(0.3)
        assert paths(root).lock.read_bytes() == b""
        with pytest.raises(install_lock.LockError) as refused:
            acquire(root, stale_after=0.05)
        assert refused.value.code == "lock_unreadable"
        assert refused.value.details["os_lock_free"] is False
        assert paths(root).lock.exists()
        assert broken_records(root) == []
    finally:
        assert finish(creator, control, op) == 0


@pytest.mark.native_publication
def test_creator_killed_before_its_metadata_write_is_broken_after_the_bound(tmp_path):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    creator = spawn("hang_before_metadata", root, op, control)
    hung = result(control, op, creator)
    # Precondition of the rule: the OS lock is taken before the metadata write.
    assert hung == {"ok": "hung", "os_lock_free_at_write": False, "size": 0}
    assert install_lock.os_lock_is_free(paths(root).lock) is False
    creator.kill()  # SIGKILL / TerminateProcess at that point
    creator.wait(timeout=DEADLINE)
    assert paths(root).lock.read_bytes() == b""

    with pytest.raises(install_lock.LockError) as refused:
        acquire(root, stale_after=30.0)  # younger than the bound
    assert refused.value.code == "lock_unreadable"
    deadline = time.monotonic() + DEADLINE
    while True:
        try:
            lock = acquire(root, stale_after=0.5)
            break
        except install_lock.LockError as exc:
            assert exc.code == "lock_unreadable"  # the OS has not released it yet
            assert time.monotonic() < deadline
            time.sleep(0.05)
    with lock:
        [moved] = lock.broken
        record = json.loads(Path(f"{moved}.break.json").read_text(encoding="utf-8"))
        assert record["reason"] == "abandoned_during_creation"
        assert record["conditions"]["metadata"] == "empty"
        assert record["conditions"]["lock_age_seconds"] > 0.5


@pytest.mark.native_publication
def test_os_lock_unsupported_fails_without_fallback(tmp_path, monkeypatch):
    root = tmp_path / "root"

    def unsupported(descriptor):
        raise install_lock._OsLockUnsupported("ENOLCK")

    monkeypatch.setattr(install_lock, "_os_lock", unsupported)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root)
    assert refused.value.code == "lock_unsupported"
    assert not paths(root).lock.exists()


@pytest.mark.native_publication
def test_unsupported_on_the_lock_file_removes_the_new_lock(tmp_path, monkeypatch):
    root = tmp_path / "root"
    real = install_lock._os_lock
    calls = []

    def guard_only(descriptor):
        calls.append(descriptor)
        if len(calls) == 1:
            return real(descriptor)
        raise install_lock._OsLockUnsupported("EOPNOTSUPP")

    monkeypatch.setattr(install_lock, "_os_lock", guard_only)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root)
    assert refused.value.code == "lock_unsupported"
    assert not paths(root).lock.exists()


@pytest.mark.native_publication
def test_broken_records_are_pruned_to_ten(tmp_path):
    root = tmp_path / "root"
    stale_ops = []
    for _ in range(12):
        stale_ops.append(write_lock(root)["operation_id"])
        with acquire(root):
            pass
    records = broken_records(root)
    assert len(records) == install_lock.MAX_BROKEN_RECORDS == 10
    kept = [json.loads((paths(root).broken / r).read_text("utf-8"))["lock"]["operation_id"]
            for r in records]
    assert kept == stale_ops[2:]
    moved = sorted(p.name for p in paths(root).broken.glob("*.lock"))
    assert [f"{name}.break.json" for name in moved] == records
    (paths(root).broken / "unrelated.txt").write_text("kept", encoding="utf-8")
    write_lock(root)
    with acquire(root):
        pass
    assert (paths(root).broken / "unrelated.txt").exists()
    assert len(broken_records(root)) == 10


# --- the held lock --------------------------------------------------------------


@pytest.mark.native_publication
def test_metadata_is_written_once_with_the_decided_fields(tmp_path):
    root = tmp_path / "root"
    with acquire(root) as lock:
        metadata = install_lock.read_metadata(paths(root).lock)
        assert metadata == lock.metadata
        assert sorted(metadata) == ["created", "host", "operation_id", "pid", "protocol",
                                    "start_token"]
        assert metadata["protocol"] == "stemwerk-install-lock/1"
        assert metadata["pid"] == os.getpid()
        assert metadata["start_token"] == process_identity.current_start_token()
        assert metadata["host"] == process_identity.host_name()
        install_events._check_timestamp(metadata["created"], "x")
        assert install_lock.os_lock_is_free(paths(root).lock) is False
    assert not paths(root).lock.exists()
    assert paths(root).guard.exists()  # permanent


@pytest.mark.native_publication
def test_heartbeat_is_replaced_every_interval_and_removed_on_release(tmp_path):
    root = tmp_path / "root"
    deadline = time.monotonic() + DEADLINE

    def heartbeat():
        # On Windows a read can meet the replace; the next read succeeds.
        while (record := install_lock.read_heartbeat(paths(root).heartbeat)) is None:
            assert time.monotonic() < deadline
            time.sleep(0.01)
        return record

    with acquire(root, heartbeat_interval=0.05) as lock:
        first = heartbeat()
        assert first["operation_id"] == lock.operation_id and first["pid"] == os.getpid()
        while heartbeat()["ts"] == first["ts"]:
            assert time.monotonic() < deadline
            time.sleep(0.01)
    assert not paths(root).heartbeat.exists()
    assert sorted(p.name for p in paths(root).directory.iterdir()) == ["install.guard"]


@pytest.mark.native_publication
def test_leftover_heartbeat_temporaries_are_removed_by_the_next_holder(tmp_path):
    root = tmp_path / "root"
    paths(root).directory.mkdir(parents=True)
    leftover = paths(root).directory / f"install.heartbeat.4242.{uuid.uuid4().hex}.tmp"
    leftover.write_bytes(b"{")
    unrelated = paths(root).directory / "notes.tmp"
    unrelated.write_bytes(b"kept")
    with acquire(root):
        assert not leftover.exists()
        assert unrelated.exists()


@pytest.mark.native_publication
def test_release_is_idempotent_and_survives_exceptions(tmp_path):
    root = tmp_path / "root"
    with pytest.raises(KeyError):
        with acquire(root) as lock:
            raise KeyError("inside")
    assert lock.released and lock.release_complete is True
    assert lock.release() is True
    assert not paths(root).lock.exists()


@pytest.mark.native_publication
@pytest.mark.parametrize("value", [0, -1, True, "5"])
def test_invalid_intervals_are_refused(tmp_path, value):
    with pytest.raises(install_lock.LockError) as refused:
        acquire(tmp_path / "root", heartbeat_interval=value)
    assert refused.value.code == "lock_invalid"


@pytest.mark.native_publication
@pytest.mark.parametrize("operation_id", ["", "not-a-uuid", str(uuid.uuid4()).upper()])
def test_invalid_operation_ids_are_refused(tmp_path, operation_id):
    with pytest.raises(install_lock.LockError) as refused:
        install_lock.acquire(tmp_path / "root", operation_id)
    assert refused.value.code == "lock_invalid"


@pytest.mark.native_publication
@pytest.mark.parametrize("name", NON_ASCII_ROOTS)
def test_non_ascii_roots(tmp_path, name):
    root = tmp_path / name / "STEMwerk"
    root.parent.mkdir()
    with acquire(root) as lock:
        report = install_lock.inspect_lock(root)
        assert (report.lock_status, report.operation_id) == ("held", lock.operation_id)
    write_lock(root)
    with acquire(root) as lock:
        assert len(lock.broken) == 1
    assert install_lock.inspect_lock(root).lock_status == install_lock.FREE


# --- path policy -------------------------------------------------------------


@pytest.mark.native_publication
@pytest.mark.parametrize("linked", [("state",), ("state", "locks")])
def test_link_inside_root_is_refused(tmp_path, linked):
    root = tmp_path / "root"
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    root.joinpath(*linked[:-1]).mkdir(parents=True)
    make_directory_link(root.joinpath(*linked), elsewhere)
    with pytest.raises(install_lock.LockError) as refused:
        acquire(root)
    assert refused.value.code == "lock_path_ineligible"
    assert list(elsewhere.iterdir()) == []
    assert install_lock.inspect_lock(root).lock_status == install_lock.UNREADABLE


@pytest.mark.native_publication
def test_linked_root_and_ancestor_are_allowed(tmp_path):
    real = tmp_path / "real"
    (real / "home").mkdir(parents=True)
    linked_ancestor = tmp_path / "linked"
    make_directory_link(linked_ancestor, real)
    root = linked_ancestor / "home" / "STEMwerk"
    with acquire(root):
        assert (real / "home" / "STEMwerk" / "state" / "locks" / "install.lock").exists()
    linked_root = tmp_path / "linked-root"
    make_directory_link(linked_root, real / "home" / "STEMwerk")
    with acquire(linked_root):
        pass


@pytest.mark.native_publication
def test_relative_root_is_refused():
    with pytest.raises(install_lock.LockError) as refused:
        install_lock.acquire(Path("relative") / "root", new_op())
    assert refused.value.code == "lock_path_ineligible"


@pytest.mark.skipif(os.name != "posix", reason="POSIX permission bits")
def test_created_directories_are_0700_and_files_0600(tmp_path):
    root = tmp_path / "root"
    old_umask = os.umask(0o022)
    try:
        with acquire(root) as lock:
            for directory in (root, root / "state", paths(root).directory):
                assert stat.S_IMODE(os.lstat(directory).st_mode) == 0o700, directory
            lock.heartbeat()
            for file in (paths(root).lock, paths(root).guard, paths(root).heartbeat):
                assert stat.S_IMODE(os.lstat(file).st_mode) == 0o600, file
        write_lock(root)
        with acquire(root) as lock:
            assert stat.S_IMODE(os.lstat(paths(root).broken).st_mode) == 0o700
            record = Path(f"{lock.broken[0]}.break.json")
            assert stat.S_IMODE(os.lstat(record).st_mode) == 0o600
    finally:
        os.umask(old_umask)


@pytest.mark.skipif(os.name != "posix", reason="POSIX permission bits")
def test_created_modes_hold_under_a_restrictive_umask(tmp_path):
    root = tmp_path / "root"
    old_umask = os.umask(0o077 | 0o200)
    try:
        with acquire(root):
            assert stat.S_IMODE(os.lstat(paths(root).directory).st_mode) == 0o700
            assert stat.S_IMODE(os.lstat(paths(root).lock).st_mode) == 0o600
    finally:
        os.umask(old_umask)


@pytest.mark.skipif(os.name != "posix", reason="POSIX permission bits")
def test_existing_root_and_legacy_directories_keep_their_permissions(tmp_path):
    root = tmp_path / "root"
    (root / "state").mkdir(parents=True)
    (root / "state" / "bootstrap.env").write_text("LEGACY=1\n", encoding="utf-8")
    os.chmod(root, 0o751)
    os.chmod(root / "state", 0o755)
    os.chmod(root / "state" / "bootstrap.env", 0o644)
    with acquire(root):
        assert stat.S_IMODE(os.lstat(paths(root).directory).st_mode) == 0o700
    assert stat.S_IMODE(os.lstat(root).st_mode) == 0o751
    assert stat.S_IMODE(os.lstat(root / "state").st_mode) == 0o755
    assert stat.S_IMODE(os.lstat(root / "state" / "bootstrap.env").st_mode) == 0o644


# --- read-only inspection -----------------------------------------------------


def snapshot(root):
    if not root.exists():
        return None
    return sorted(
        (str(p.relative_to(root)), p.is_dir(), None if p.is_dir() else p.read_bytes())
        for p in root.rglob("*")
    )


def forbid_os_locks(monkeypatch):
    def refuse(*args):
        raise AssertionError("inspect_lock must never take an OS lock")

    monkeypatch.setattr(install_lock, "_os_lock", refuse)
    monkeypatch.setattr(install_lock, "_os_unlock", refuse)


@pytest.mark.native_publication
@pytest.mark.parametrize("prepare, expected", [
    (lambda root: None, ("free", False, False)),
    (lambda root: root.mkdir(parents=True), ("free", False, False)),
    (lambda root: paths(root).directory.mkdir(parents=True), ("free", False, False)),
    (lambda root: write_lock(root, heartbeat_age=600.0), ("stale", False, True)),
    (lambda root: write_lock(root, heartbeat_age=1.0), ("held", True, True)),
    (lambda root: write_lock(root, pid=os.getpid(),
                             start_token=process_identity.current_start_token()),
     ("held", True, True)),
    (lambda root: write_lock(root, pid=os.getpid(), start_token="reused"), ("stale", False, True)),
    (lambda root: write_lock(root, host="another-host.example"), ("foreign_host", None, True)),
])
def test_inspect_reports_without_taking_or_creating(tmp_path, monkeypatch, prepare, expected):
    root = tmp_path / "root"
    written = prepare(root)
    before = snapshot(root)
    forbid_os_locks(monkeypatch)
    report = install_lock.inspect_lock(root)
    assert snapshot(root) == before
    status, in_progress, has_id = expected
    assert (report.lock_status, report.operation_in_progress) == (status, in_progress)
    assert report.operation_id == (written["operation_id"] if has_id else None)


@pytest.mark.native_publication
@pytest.mark.parametrize("content", [b"", b"garbage\n", b"{}\n"])
def test_inspect_unreadable_lock(tmp_path, monkeypatch, content):
    root = tmp_path / "root"
    paths(root).directory.mkdir(parents=True)
    paths(root).lock.write_bytes(content)
    forbid_os_locks(monkeypatch)
    assert install_lock.inspect_lock(root) == install_lock.LockReport("unreadable", None, None)


@pytest.mark.native_publication
def test_inspect_lock_that_is_a_directory_is_unreadable(tmp_path):
    root = tmp_path / "root"
    paths(root).lock.mkdir(parents=True)
    assert install_lock.inspect_lock(root).lock_status == install_lock.UNREADABLE


@pytest.mark.native_publication
def test_inspect_unsupported_when_the_owner_cannot_be_probed(tmp_path, monkeypatch):
    root = tmp_path / "root"
    written = write_lock(root)
    forbid_os_locks(monkeypatch)
    report = install_lock.inspect_lock(
        root, probe=lambda pid: process_identity.ProcessProbe(None, None)
    )
    assert (report.lock_status, report.operation_in_progress, report.operation_id) == (
        "unsupported", None, written["operation_id"])


@pytest.mark.native_publication
def test_inspect_a_lock_held_by_another_process(tmp_path, monkeypatch):
    root, control = tmp_path / "root", tmp_path / "control"
    op = new_op()
    holder = spawn("hold", root, op, control, interval=0.05)
    assert result(control, op, holder)["ok"] is True
    try:
        with monkeypatch.context() as patch:
            forbid_os_locks(patch)
            report = install_lock.inspect_lock(root)
        assert (report.lock_status, report.operation_in_progress, report.operation_id) == (
            "held", True, op)
        assert install_lock.os_lock_is_free(paths(root).lock) is False
    finally:
        assert finish(holder, control, op) == 0
