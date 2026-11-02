"""Tests for the operation journal and recovery after lock acquisition."""
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import install_journal as journal_module  # noqa: E402
from stemwerk_core import install_lock  # noqa: E402
from tests.asset_link_helpers import make_directory_link  # noqa: E402

pytestmark = pytest.mark.portable


def new_op() -> str:
    return str(uuid.uuid4())


def records(path: Path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def interrupted(root: Path, op: str = None):
    """An operation that staged a directory and a file, then crashed."""

    op = new_op() if op is None else op
    journal = journal_module.open_journal(root, op)
    directory = journal.create_directory(journal.core_directory / "venv")
    journal.create_file(directory / "pyvenv.cfg", b"home = x\n")
    journal.close()
    return journal


def acquire(root, **options):
    return install_lock.acquire(root, new_op(), guard_timeout=30.0, **options)


def tree(root: Path):
    return sorted(str(p.relative_to(root)).replace(os.sep, "/") for p in root.rglob("*"))


@pytest.mark.native_publication
def test_open_creates_the_journal_and_core_staging(tmp_path):
    root, op = tmp_path / "root", new_op()
    with journal_module.open_journal(root, op) as journal:
        assert journal.path == root / "tmp" / op / "journal.ndjson"
        assert journal.core_directory == root / "tmp" / op / "core"
        assert journal.core_directory.is_dir()
    lines = records(journal.path)
    assert [line["record"] for line in lines] == ["open", "intent", "completion"]
    assert [line["seq"] for line in lines] == [1, 2, 3]
    assert lines[0]["operation_directory_created"] is True
    assert lines[1]["action"] == "create_directory"
    assert lines[1]["path"] == f"tmp/{op}/core"
    for line in lines:
        assert line["protocol"] == "stemwerk-install-journal/1"
        assert line["operation_id"] == op
    with pytest.raises(journal_module.JournalError) as refused:
        journal_module.open_journal(root, op)
    assert refused.value.code == "journal_exists"


@pytest.mark.native_publication
def test_existing_operation_directory_of_the_outer_layer_is_kept(tmp_path):
    root, op = tmp_path / "root", new_op()
    bootstrap = root / "tmp" / op / "python-staging"
    bootstrap.mkdir(parents=True)
    with journal_module.open_journal(root, op) as journal:
        pass
    assert records(journal.path)[0]["operation_directory_created"] is False
    assert bootstrap.is_dir()


@pytest.mark.native_publication
def test_intent_then_completion_with_identity(tmp_path):
    root = tmp_path / "root"
    with journal_module.open_journal(root, new_op()) as journal:
        directory = journal.create_directory(journal.core_directory / "staged")
        file = journal.create_file(directory / "a.bin", b"payload")
    lines = records(journal.path)[3:]
    assert [(l["record"], l.get("action"), l.get("intent_seq")) for l in lines] == [
        ("intent", "create_directory", None),
        ("completion", None, 4),
        ("intent", "create_file", None),
        ("completion", None, 6),
    ]
    for completion, path in ((lines[1], directory), (lines[3], file)):
        path_stat = os.lstat(path)
        assert completion["identity"] == {
            "device": path_stat.st_dev,
            "inode": path_stat.st_ino,
            "is_directory": stat.S_ISDIR(path_stat.st_mode),
        }
    assert file.read_bytes() == b"payload"


@pytest.mark.native_publication
def test_intent_is_on_disk_and_synced_before_the_mutation(tmp_path, monkeypatch):
    root = tmp_path / "root"
    journal = journal_module.open_journal(root, new_op())
    target = journal.core_directory / "staged"
    events = []
    real_fsync, real_mkdir = os.fsync, os.mkdir

    def fsync(descriptor):
        events.append(("fsync", descriptor))
        return real_fsync(descriptor)

    def mkdir(path, *args, **kwargs):
        last = records(journal.path)[-1]
        events.append(("mkdir", Path(path), last["record"], last.get("path")))
        return real_mkdir(path, *args, **kwargs)

    monkeypatch.setattr(os, "fsync", fsync)
    monkeypatch.setattr(os, "mkdir", mkdir)
    try:
        journal.create_directory(target)
    finally:
        monkeypatch.undo()
        journal.close()
    mkdir_at = next(i for i, e in enumerate(events) if e[0] == "mkdir")
    assert events[mkdir_at][1:] == (target, "intent", f"{target.relative_to(root).as_posix()}")
    assert any(e[0] == "fsync" for e in events[:mkdir_at])
    assert any(e[0] == "fsync" for e in events[mkdir_at + 1:])  # the completion


@pytest.mark.native_publication
def test_failed_journal_sync_stops_the_mutation(tmp_path, monkeypatch):
    root = tmp_path / "root"
    journal = journal_module.open_journal(root, new_op())
    target = journal.core_directory / "never"

    def failing(descriptor):
        raise OSError("disk full")

    monkeypatch.setattr(os, "fsync", failing)
    with pytest.raises(journal_module.JournalError) as refused:
        journal.create_directory(target)
    monkeypatch.undo()
    journal.close()
    assert refused.value.code == "journal_write_failed"
    assert not target.exists()


@pytest.mark.native_publication
def test_mutations_outside_core_are_refused(tmp_path):
    root = tmp_path / "root"
    with journal_module.open_journal(root, new_op()) as journal:
        for path in (journal.directory / "bootstrap", root / "assets" / "x", journal.core_directory,
                     tmp_path / "outside"):
            with pytest.raises(journal_module.JournalError) as refused:
                journal.create_directory(path)
            assert refused.value.code == "journal_action_refused"
            assert not path.exists() or path == journal.core_directory
        with pytest.raises(journal_module.JournalError):
            journal.intent("chmod", journal.core_directory / "x")
        with pytest.raises(journal_module.JournalError):
            journal.intent("remove", journal.core_directory / "x", destination=root / "y")


@pytest.mark.native_publication
def test_incomplete_last_line_is_ignored(tmp_path):
    root = tmp_path / "root"
    journal = interrupted(root)
    data = journal.path.read_bytes()
    complete = journal_module.parse_journal(data, journal.operation_id)
    torn = data + b'{"protocol":"stemwerk-install-journal/1","seq":'
    assert journal_module.parse_journal(torn, journal.operation_id) == complete
    assert journal_module.parse_journal(data[:-1], journal.operation_id) == complete[:-1]


@pytest.mark.native_publication
@pytest.mark.parametrize("damage", ["middle", "bom", "operation", "seq", "no_open"])
def test_invalid_journals_are_refused(tmp_path, damage):
    root = tmp_path / "root"
    journal = interrupted(root)
    lines = journal.path.read_bytes().split(b"\n")
    if damage == "middle":
        lines[2] = b"not json"
    elif damage == "bom":
        lines[0] = b"\xef\xbb\xbf" + lines[0]
    elif damage == "operation":
        lines[1] = lines[1].replace(journal.operation_id.encode(), new_op().encode())
    elif damage == "seq":
        lines[1] = lines[1].replace(b'"seq":2', b'"seq":7')
    else:
        lines = lines[1:]
    with pytest.raises(journal_module.JournalError) as refused:
        journal_module.parse_journal(b"\n".join(lines), journal.operation_id)
    assert refused.value.code == "journal_invalid"


# --- recovery -------------------------------------------------------------------


@pytest.mark.native_publication
def test_recovery_after_acquisition_touches_only_journaled_items(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    shared = root / "tmp" / crashed.operation_id
    (shared / "python-staging").mkdir()  # outer-layer bootstrap staging, same op
    (shared / "python-staging" / "python.tar").write_bytes(b"archive")
    bootstrap_only = root / "tmp" / new_op() / "python-staging"
    bootstrap_only.mkdir(parents=True)
    (root / "tmp" / "not-an-operation").mkdir()
    (root / "tmp" / "loose-file").write_bytes(b"kept")
    (root / "assets").mkdir()
    (root / "assets" / "unrelated").write_bytes(b"kept")
    before = [p for p in tree(root) if f"{crashed.operation_id}/core" not in p
              and not p.endswith("journal.ndjson")]

    with acquire(root) as lock:
        report = lock.recovery.to_json()
    assert report["complete"] is True
    [operation] = report["operations"]
    assert operation["operation_id"] == crashed.operation_id
    assert [(i["action"], i["outcome"]) for i in operation["items"]] == [
        ("create_file", "removed"),
        ("create_directory", "removed"),
        ("create_directory", "removed"),
    ]
    assert not crashed.core_directory.exists()
    assert not crashed.path.exists()
    after = [p for p in tree(root) if not p.startswith("state")]
    assert after == [p for p in before if not p.startswith("state")]
    assert (shared / "python-staging" / "python.tar").read_bytes() == b"archive"


@pytest.mark.native_publication
def test_recovery_removes_an_operation_directory_core_created_when_empty(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    with acquire(root) as lock:
        assert lock.recovery.complete
    assert not crashed.directory.exists()
    assert (root / "tmp").is_dir()


@pytest.mark.native_publication
def test_recovery_runs_after_every_acquisition_and_skips_the_current_operation(tmp_path):
    root = tmp_path / "root"
    with acquire(root) as lock:
        own = journal_module.open_journal(root, lock.operation_id)
        own.create_directory(own.core_directory / "mine")
        own.close()
        again = journal_module.recover(root, current_operation_id=lock.operation_id)
        assert again.operations == []
        assert (own.core_directory / "mine").is_dir()
    with acquire(root) as second:
        assert [o.operation_id for o in second.recovery.operations] == [lock.operation_id]
    assert not own.directory.exists()


@pytest.mark.native_publication
def test_recovery_follows_a_stale_lock_break(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    paths = install_lock.LockPaths.for_root(root)
    paths.directory.mkdir(parents=True)
    paths.lock.write_bytes(install_lock._encode({
        "protocol": install_lock.LOCK_PROTOCOL,
        "operation_id": crashed.operation_id,
        "pid": os.getpid(),
        "start_token": "reused",
        "host": install_lock.process_identity.host_name(),
        "created": install_lock._timestamp(0.0),
    }))
    with acquire(root) as lock:
        assert len(lock.broken) == 1
        assert [o.operation_id for o in lock.recovery.operations] == [crashed.operation_id]
    assert not crashed.core_directory.exists()


@pytest.mark.native_publication
def test_replaced_item_is_kept_and_the_journal_retained(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    staged = crashed.core_directory / "venv" / "pyvenv.cfg"
    replacement = crashed.core_directory / "replacement"
    replacement.write_bytes(b"someone else's file")
    os.replace(replacement, staged)  # same path, new identity
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert operation.complete is False
    assert [i["outcome"] for i in operation.items] == [
        journal_module.KEPT_IDENTITY_MISMATCH,
        journal_module.KEPT_CONTAINS_KEPT_ITEM,
        journal_module.KEPT_CONTAINS_KEPT_ITEM,
    ]
    assert staged.read_bytes() == b"someone else's file"
    assert crashed.path.exists()
    with acquire(root) as again:
        assert again.recovery.operations[0].items == operation.items


@pytest.mark.native_publication
def test_intent_without_completion_inside_core_is_removed(tmp_path):
    root = tmp_path / "root"
    journal = journal_module.open_journal(root, new_op())
    half = journal.core_directory / "half-written.whl"
    journal.intent(journal_module.CREATE_FILE, half)
    half.write_bytes(b"partial")  # the crash came before the completion record
    journal.intent(journal_module.CREATE_DIRECTORY, journal.core_directory / "never-created")
    journal.close()
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    outcomes = {i["path"].rsplit("/", 1)[-1]: i["outcome"] for i in operation.items}
    assert outcomes["never-created"] == journal_module.ALREADY_ABSENT
    assert outcomes["half-written.whl"] == journal_module.REMOVED
    assert operation.complete is True


@pytest.mark.native_publication
def test_incomplete_last_line_does_not_stop_recovery(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    with open(crashed.path, "ab") as handle:
        handle.write(b'{"protocol":"stemwerk-install-journal/1","rec')
    with acquire(root) as lock:
        assert lock.recovery.complete
    assert not crashed.core_directory.exists()


@pytest.mark.native_publication
def test_unreadable_journal_is_reported_and_nothing_is_touched(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    crashed.path.write_bytes(b"garbage\n" + crashed.path.read_bytes())
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert (operation.complete, operation.error) == (False, "journal_invalid")
    assert (crashed.core_directory / "venv" / "pyvenv.cfg").exists()


def staged_set(journal):
    directory = journal.create_directory(journal.core_directory / "set")
    journal.create_file(directory / "model.ckpt", b"weights")
    return directory


@pytest.mark.native_publication
@pytest.mark.parametrize("verdict, outcome", [
    (None, "published_unverified"), (True, "published_verified"), (False, "published_failed"),
])
def test_published_results_are_verified_never_deleted(tmp_path, verdict, outcome):
    root = tmp_path / "root"
    (root / "assets").mkdir(parents=True)
    journal = journal_module.open_journal(root, new_op())
    destination = root / "assets" / "set-1"
    journal.rename(staged_set(journal), destination)
    journal.close()
    seen = []

    def verify(path):
        seen.append(path)
        return verdict

    with acquire(root, verify_published=None if verdict is None else verify) as lock:
        [operation] = lock.recovery.operations
    assert operation.items[0]["outcome"] == outcome
    assert seen == ([] if verdict is None else [destination])
    assert (destination / "model.ckpt").read_bytes() == b"weights"
    assert not journal.core_directory.exists()


@pytest.mark.native_publication
def test_rename_that_happened_before_its_completion_counts_as_published(tmp_path):
    root = tmp_path / "root"
    (root / "assets").mkdir(parents=True)
    journal = journal_module.open_journal(root, new_op())
    source = staged_set(journal)
    destination = root / "assets" / "set-2"
    journal.intent(journal_module.RENAME, source, destination=destination)
    install_lock.install_journal.materialization._publish_noreplace(source, destination)
    journal.close()  # crash: no completion record
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert operation.items[0]["outcome"] == journal_module.PUBLISHED_UNVERIFIED
    assert (destination / "model.ckpt").exists()


@pytest.mark.native_publication
def test_rename_that_did_not_happen_leaves_staging_to_be_removed(tmp_path):
    root = tmp_path / "root"
    journal = journal_module.open_journal(root, new_op())
    source = staged_set(journal)
    destination = root / "assets" / "set-3"
    journal.intent(journal_module.RENAME, source, destination=destination)
    journal.close()
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert operation.items[0]["outcome"] == journal_module.NOT_APPLICABLE
    assert not source.exists() and not destination.exists()


@pytest.mark.native_publication
def test_linked_core_directory_is_not_followed(tmp_path):
    root = tmp_path / "root"
    crashed = interrupted(root)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "precious").write_bytes(b"kept")
    os.rename(crashed.core_directory, tmp_path / "moved-core")
    make_directory_link(crashed.core_directory, elsewhere)
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert operation.complete is False
    assert {i["outcome"] for i in operation.items} == {journal_module.KEPT_IDENTITY_MISMATCH,
                                                       journal_module.KEPT_CONTAINS_KEPT_ITEM}
    assert (elsewhere / "precious").read_bytes() == b"kept"
    assert crashed.path.exists()


@pytest.mark.native_publication
def test_intent_only_item_behind_a_linked_directory_is_not_removed(tmp_path):
    root = tmp_path / "root"
    journal = journal_module.open_journal(root, new_op())
    inner = journal.create_directory(journal.core_directory / "inner")
    target = inner / "victim"
    journal.intent(journal_module.CREATE_FILE, target)
    journal.close()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "victim").write_bytes(b"kept")
    os.rmdir(inner)
    make_directory_link(inner, elsewhere)
    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert operation.complete is False
    assert (elsewhere / "victim").read_bytes() == b"kept"


@pytest.mark.native_publication
@pytest.mark.parametrize("name", ["Testgerät", "beñat"])
def test_non_ascii_roots(tmp_path, name):
    root = tmp_path / name / "STEMwerk"
    root.parent.mkdir()
    crashed = interrupted(root)
    assert records(crashed.path)[1]["path"] == f"tmp/{crashed.operation_id}/core"
    with acquire(root) as lock:
        assert lock.recovery.complete
    assert not crashed.directory.exists()


@pytest.mark.skipif(os.name != "posix", reason="POSIX permission bits")
def test_journal_creates_0700_directories_and_0600_files(tmp_path):
    root = tmp_path / "root"
    root.mkdir(mode=0o755)
    os.chmod(root, 0o755)
    old_umask = os.umask(0o022)
    try:
        with journal_module.open_journal(root, new_op()) as journal:
            directory = journal.create_directory(journal.core_directory / "d")
            file = journal.create_file(directory / "f", b"x")
    finally:
        os.umask(old_umask)
    for path in (root / "tmp", journal.directory, journal.core_directory, directory):
        assert stat.S_IMODE(os.lstat(path).st_mode) == 0o700, path
    for path in (journal.path, file):
        assert stat.S_IMODE(os.lstat(path).st_mode) == 0o600, path
    assert stat.S_IMODE(os.lstat(root).st_mode) == 0o755


# --- journal paths that would escape <root> -----------------------------------


def escaping_paths(op: str, sentinel: Path) -> dict:
    """Journal paths aimed at ``sentinel`` (``<root>/../outside/sentinel``)."""

    drive_path = sentinel.as_posix() if sentinel.drive else f"C:/outside/{sentinel.name}"
    return {
        "dotdot": f"tmp/{op}/core/../../../../outside/{sentinel.name}",
        "absolute": sentinel.as_posix() if not sentinel.drive else "/outside/" + sentinel.name,
        "backslash": f"tmp\\{op}\\core\\..\\..\\..\\..\\outside\\{sentinel.name}",
        "drive": drive_path,
    }


def plant(tmp_path: Path):
    outside = tmp_path / "outside"
    outside.mkdir()
    sentinel = outside / "sentinel"
    sentinel.write_bytes(b"a user's file, outside <root>")
    return outside, sentinel


def identity_of(path: Path) -> dict:
    path_stat = os.lstat(path)
    return {"device": path_stat.st_dev, "inode": path_stat.st_ino,
            "is_directory": stat.S_ISDIR(path_stat.st_mode)}


@pytest.mark.native_publication
@pytest.mark.parametrize("kind", ["dotdot", "absolute", "backslash", "drive"])
@pytest.mark.parametrize("completed", [True, False], ids=["completed", "intent_only"])
def test_journal_path_escaping_root_is_invalid_and_touches_nothing(tmp_path, kind, completed):
    root = tmp_path / "root"
    outside, sentinel = plant(tmp_path)
    journal = journal_module.open_journal(root, new_op())
    staged = journal.create_file(journal.core_directory / "staged.bin", b"staged")
    path = escaping_paths(journal.operation_id, sentinel)[kind]
    # Written past intent()'s own checks, as a corrupted or crafted journal would be.
    seq = journal._append({"record": "intent", "action": "create_file", "path": path})
    if completed:
        # The sentinel's real identity: only the path check stands between it and removal.
        journal._append({"record": "completion", "intent_seq": seq,
                         "identity": identity_of(sentinel)})
    journal.close()
    before = sorted(p.name for p in outside.iterdir())

    with acquire(root) as lock:
        [operation] = lock.recovery.operations
    assert (operation.complete, operation.error) == (False, "journal_invalid")
    assert sentinel.read_bytes() == b"a user's file, outside <root>"
    assert sorted(p.name for p in outside.iterdir()) == before
    assert staged.read_bytes() == b"staged"  # nothing removed once the journal is invalid
    assert journal.path.exists()


@pytest.mark.native_publication
@pytest.mark.parametrize("kind", ["dotdot", "absolute", "backslash", "drive"])
def test_rename_destination_escaping_root_is_invalid(tmp_path, kind):
    root = tmp_path / "root"
    outside, sentinel = plant(tmp_path)
    journal = journal_module.open_journal(root, new_op())
    source = journal.create_directory(journal.core_directory / "set")
    seq = journal._append({
        "record": "intent", "action": "rename",
        "path": source.relative_to(root).as_posix(),
        "destination": escaping_paths(journal.operation_id, sentinel)[kind],
    })
    journal._append({"record": "completion", "intent_seq": seq, "identity": identity_of(sentinel)})
    journal.close()
    verified = []
    with acquire(root, verify_published=lambda path: verified.append(path) or True) as lock:
        [operation] = lock.recovery.operations
    assert (operation.complete, operation.error) == (False, "journal_invalid")
    assert verified == []
    assert sentinel.read_bytes() == b"a user's file, outside <root>"
    assert source.is_dir()
