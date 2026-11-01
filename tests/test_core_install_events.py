"""Tests for the operation files: events.ndjson, result.json and started."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_materialization as materialization  # noqa: E402
from stemwerk_core import install_events as events  # noqa: E402
from tests.cli_harness import run_cli  # noqa: E402

pytestmark = pytest.mark.portable

TS = "2026-10-31T23:00:00.000000Z"
OP = "5f0c8a52-4e5b-4c7e-9a0e-2b7d1c3e4f60"
UNICODE_PATHS = [
    "C:\\Users\\Testgerät\\AppData\\Local\\STEMwerk",
    "/home/beñat/.local/share/STEMwerk",
    "/Users/Testgera\u0308t/Library/Application Support/STEMwerk",  # decomposed form
]


def event(**changes):
    base = {
        "protocol": events.EVENT_PROTOCOL,
        "operation_id": OP,
        "seq": 1,
        "ts": TS,
        "source": "core",
        "state": "active_indeterminate",
        "phase": "lock",
        "since_seconds": 0,
    }
    base.update(changes)
    return {key: value for key, value in base.items() if value is not ...}


def logs_dir(tmp_path):
    # Non-ASCII parents, as for user names in issues #128 and #134.
    directory = tmp_path / "Testgerät" / "beñat" / "logs"
    directory.mkdir(parents=True)
    return directory


def outer_layer_events(logs, operation_id=OP, count=3):
    writer = events.EventWriter.start_operation(logs, operation_id)
    writer.append("active_indeterminate", "bootstrap", since_seconds=0)
    for done in range(1, count - 1):
        writer.append("active_determinate", "bootstrap", done=done, total=count, unit="bytes")
    writer.append("done", "bootstrap", verified=True)
    return writer


# --- schema ---------------------------------------------------------------------

VALID_EVENTS = [
    event(state="active_determinate", since_seconds=..., done=5, total=10, unit="bytes"),
    event(state="active_indeterminate"),
    event(state="possibly_stalled", since_seconds=..., silent_seconds=31.5),
    event(state="retrying", since_seconds=..., error_code="http_503", attempt=1, max_attempts=3),
    event(state="failed", since_seconds=..., error_code="lock_held", detail="pid 42", action="retry later"),
    event(state="done", since_seconds=..., verified=False),
    event(source="outer_layer", phase="bootstrap"),
    event(ts="2026-10-31T23:00:00Z"),
]


@pytest.mark.parametrize("valid", VALID_EVENTS)
def test_valid_events(valid):
    events.validate_event(valid)


INVALID_EVENTS = [
    event(protocol="stemwerk-install-events/2"),
    event(operation_id=OP.upper()),
    event(operation_id="not-a-uuid"),
    event(seq=0),
    event(seq=True),
    event(seq="1"),
    event(ts="2026-10-31T23:00:00+00:00"),
    event(ts="2026-10-31 23:00:00Z"),
    event(ts="2026-02-30T23:00:00Z"),
    event(ts=...),
    event(source="front_end"),
    event(source=...),
    event(state="waiting"),
    event(phase="download"),
    event(phase="bootstrap"),  # bootstrap belongs to the outer layer
    event(source="outer_layer", phase="preflight"),  # the outer layer only bootstraps
    event(since_seconds=...),
    event(extra="field"),
    event(since_seconds=-1),
    event(state="active_determinate", since_seconds=..., done=11, total=10, unit="bytes"),
    event(state="retrying", since_seconds=..., error_code="x", attempt=4, max_attempts=3),
    event(state="failed", since_seconds=..., error_code="x", detail="", action="y"),
    event(state="done", since_seconds=..., verified="yes"),
    ["not", "an", "object"],
]


@pytest.mark.parametrize("invalid", INVALID_EVENTS)
def test_invalid_events(invalid):
    with pytest.raises(events.InstallFileError) as raised:
        events.validate_event(invalid)
    assert raised.value.code == "invalid_event"


def test_phases_follow_the_design_and_include_lock():
    assert events.PHASES == (
        "bootstrap", "preflight", "lock", "create_environment", "install_packages",
        "fetch_ffmpeg", "verify_ffmpeg", "fetch_assets", "verify_assets", "publish",
        "activate", "verify_module",
    )
    assert set(events.STATE_FIELDS) == {
        "active_determinate", "active_indeterminate", "possibly_stalled",
        "retrying", "failed", "done",
    }


def test_utc_timestamp_is_rfc3339_utc():
    stamp = events.utc_timestamp(datetime(2026, 11, 1, 1, 2, 3, 4, tzinfo=timezone(timedelta(hours=1))))
    assert stamp == "2026-11-01T00:02:03.000004Z"
    events.validate_event(event(ts=events.utc_timestamp()))


# --- encoding -------------------------------------------------------------------


def test_line_encoding_is_deterministic_utf8_without_escapes():
    line = events.encode_line(event(state="failed", since_seconds=..., error_code="x",
                                    detail=UNICODE_PATHS[0] + "\nsecond line", action="y"))
    assert line == events.encode_line(json.loads(line))
    assert line.endswith(b"\n") and line.count(b"\n") == 1
    assert not line.startswith(b"\xef\xbb\xbf")
    assert "Testgerät".encode("utf-8") in line
    assert b"\\u00e4" not in line
    keys = list(json.loads(line))
    assert keys == sorted(keys)


def test_parse_ignores_an_incomplete_last_line():
    complete = events.encode_line(event(seq=1)) + events.encode_line(event(seq=2))
    partial = events.encode_line(event(seq=3))[:-7]
    parsed = events.parse_events(complete + partial)
    assert [e["seq"] for e in parsed] == [1, 2]
    assert events.parse_events(b"") == []


@pytest.mark.parametrize(
    "data",
    [
        events.encode_line(event(seq=2)),
        events.encode_line(event(seq=1)) + events.encode_line(event(seq=3)),
        events.encode_line(event(seq=1)) + events.encode_line(event(seq=1)),
        events.encode_line(event(seq=1))
        + events.encode_line(event(seq=2, operation_id=str(uuid.UUID(int=1)))),
        events.encode_line(event(seq=1))
        + events.encode_line(event(seq=2, source="outer_layer", phase="bootstrap")),
        b"\xef\xbb\xbf" + events.encode_line(event(seq=1)),
        b"{not json}\n",
        b'{"detail":"\xff"}\n',
    ],
)
def test_parse_rejects_broken_sequences_and_encodings(data):
    with pytest.raises(events.InstallFileError) as raised:
        events.parse_events(data)
    assert raised.value.code == "invalid_event"


# --- writers and handover (G1) ---------------------------------------------------


@pytest.mark.native_publication
def test_sequence_continues_across_the_outer_layer_handover(tmp_path):
    logs = logs_dir(tmp_path)
    outer = outer_layer_events(logs)
    assert outer.next_seq == 4

    core = events.EventWriter.accept_handover(logs / OP, OP)
    assert (core.source, core.next_seq) == ("core", 4)
    core.append("active_indeterminate", "preflight", since_seconds=0)
    core.append("active_indeterminate", "lock", since_seconds=0)
    core.append("failed", "lock", error_code="lock_held",
                detail=f"held by {UNICODE_PATHS[1]}", action="retry later")

    parsed = events.read_events(logs / OP)
    assert [e["seq"] for e in parsed] == list(range(1, 7))
    assert [e["source"] for e in parsed] == ["outer_layer"] * 3 + ["core"] * 3
    assert [e["phase"] for e in parsed] == ["bootstrap"] * 3 + ["preflight", "lock", "lock"]
    assert all(e["operation_id"] == OP and e["protocol"] == events.EVENT_PROTOCOL for e in parsed)
    for e in parsed:
        datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%S.%fZ")
    assert parsed[-1]["detail"] == f"held by {UNICODE_PATHS[1]}"
    raw = (logs / OP / events.EVENTS_FILENAME).read_bytes()
    assert raw.endswith(b"\n") and raw.count(b"\n") == 6
    assert not raw.startswith(b"\xef\xbb\xbf")


@pytest.mark.native_publication
def test_handover_from_a_shell_written_events_file(tmp_path):
    # The outer layer is Inno or sh, not Python: it writes the bytes itself.
    operation = logs_dir(tmp_path) / OP
    operation.mkdir()
    lines = [
        '{"operation_id":"%s","phase":"bootstrap","protocol":"stemwerk-install-events/1",'
        '"seq":%d,"since_seconds":0,"source":"outer_layer","state":"active_indeterminate",'
        '"ts":"2026-10-31T23:00:0%dZ"}' % (OP, seq, seq)
        for seq in (1, 2)
    ]
    (operation / events.EVENTS_FILENAME).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    core = events.EventWriter.accept_handover(operation, OP)
    core.append("done", "preflight", verified=True)
    assert [e["seq"] for e in events.read_events(operation)] == [1, 2, 3]


def _prepared_operation(tmp_path):
    logs = logs_dir(tmp_path)
    outer_layer_events(logs)
    return logs / OP


HANDOVER_REFUSALS = {
    "no events file": lambda d: (d / events.EVENTS_FILENAME).unlink(),
    "no events": lambda d: (d / events.EVENTS_FILENAME).write_bytes(b""),
    "incomplete last line": lambda d: (d / events.EVENTS_FILENAME).write_bytes(
        (d / events.EVENTS_FILENAME).read_bytes() + b'{"seq":4'
    ),
    "result exists": lambda d: (d / events.RESULT_FILENAME).write_bytes(b"{}\n"),
    "invalid line": lambda d: (d / events.EVENTS_FILENAME).write_bytes(
        (d / events.EVENTS_FILENAME).read_bytes() + b"{}\n"
    ),
    "core already took over": lambda d: events.EventWriter(d, OP, "core", 4).append(
        "active_indeterminate", "preflight", since_seconds=0
    ),
}


@pytest.mark.native_publication
@pytest.mark.parametrize("case", sorted(HANDOVER_REFUSALS))
def test_handover_is_refused(tmp_path, case):
    operation = _prepared_operation(tmp_path)
    HANDOVER_REFUSALS[case](operation)
    before = {p.name: p.read_bytes() for p in operation.iterdir()}
    with pytest.raises(events.InstallFileError) as raised:
        events.EventWriter.accept_handover(operation, OP)
    assert raised.value.code == "handover_refused"
    assert {p.name: p.read_bytes() for p in operation.iterdir()} == before


@pytest.mark.native_publication
def test_handover_is_refused_for_another_operation(tmp_path):
    operation = _prepared_operation(tmp_path)
    other = str(uuid.UUID(int=7))
    renamed = operation.parent / other
    operation.rename(renamed)
    for directory, operation_id in ((renamed, other), (renamed, OP)):
        with pytest.raises(events.InstallFileError) as raised:
            events.EventWriter.accept_handover(directory, operation_id)
        assert raised.value.code == "handover_refused"


@pytest.mark.native_publication
def test_start_operation_is_exclusive(tmp_path):
    logs = logs_dir(tmp_path)
    events.EventWriter.start_operation(logs, OP)
    with pytest.raises(events.InstallFileError) as raised:
        events.EventWriter.start_operation(logs, OP)
    assert raised.value.code == "operation_exists"


@pytest.mark.native_publication
def test_reader_tolerates_a_line_being_written(tmp_path):
    operation = _prepared_operation(tmp_path)
    path = operation / events.EVENTS_FILENAME
    line = events.encode_line(event(seq=4, phase="preflight"))
    with open(path, "ab") as handle:
        handle.write(line[:20])
    assert [e["seq"] for e in events.read_events(operation)] == [1, 2, 3]
    with open(path, "ab") as handle:
        handle.write(line[20:])
    assert [e["seq"] for e in events.read_events(operation)] == [1, 2, 3, 4]


def test_invalid_event_is_never_written(tmp_path):
    operation = _prepared_operation(tmp_path)
    before = (operation / events.EVENTS_FILENAME).read_bytes()
    core = events.EventWriter.accept_handover(operation, OP)
    with pytest.raises(events.InstallFileError):
        core.append("active_determinate", "fetch_assets", done=2, total=1, unit="bytes")
    assert (operation / events.EVENTS_FILENAME).read_bytes() == before
    assert core.next_seq == 4


# --- result and started -----------------------------------------------------------


def _document():
    return {"kind": "stemwerk_module_verification", "paths": list(UNICODE_PATHS)}


@pytest.mark.native_publication
def test_result_is_written_once_and_round_trips(tmp_path):
    operation = _prepared_operation(tmp_path)
    path = events.write_result(operation, OP, 0, _document())
    assert path == operation / events.RESULT_FILENAME
    raw = path.read_bytes()
    assert raw.endswith(b"\n") and not raw.startswith(b"\xef\xbb\xbf")
    assert "Testgerät".encode("utf-8") in raw and "beñat".encode("utf-8") in raw
    result = events.read_result(operation)
    assert result == {
        "protocol": events.RESULT_PROTOCOL,
        "operation_id": OP,
        "exit_code": 0,
        "stream": "stdout",
        "document": _document(),
    }
    assert result["document"]["paths"] == UNICODE_PATHS
    with pytest.raises(events.InstallFileError) as raised:
        events.write_result(operation, OP, 3, {"kind": "late"})
    assert raised.value.code == "already_written"
    assert path.read_bytes() == raw
    assert not [p for p in operation.iterdir() if p.name.endswith(".tmp")]


@pytest.mark.parametrize(
    ("exit_code", "document"),
    [(1, {}), (True, {}), (0, ["not", "an", "object"]), (2, "text")],
)
def test_invalid_result_is_never_written(tmp_path, exit_code, document):
    with pytest.raises(events.InstallFileError) as raised:
        events.write_result(tmp_path, OP, exit_code, document)
    assert raised.value.code == "invalid_result"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize(("exit_code", "stream"), [(0, "stdout"), (2, "stderr"), (3, "stderr")])
def test_result_stream_follows_the_exit_code(tmp_path, exit_code, stream):
    events.write_result(tmp_path, OP, exit_code, {})
    assert events.read_result(tmp_path)["stream"] == stream


@pytest.mark.native_publication
def test_result_is_complete_before_it_becomes_visible(tmp_path, monkeypatch):
    operation = _prepared_operation(tmp_path)
    target = operation / events.RESULT_FILENAME
    real_publish = materialization._publish_noreplace
    observed = {}

    def checked_publish(staging, destination):
        observed["visible_before"] = os.path.lexists(target)
        observed["staging"] = Path(staging)
        observed["staging_bytes"] = Path(staging).read_bytes()
        real_publish(staging, destination)

    monkeypatch.setattr(materialization, "_publish_noreplace", checked_publish)
    events.write_result(operation, OP, 2, _document())
    assert observed["visible_before"] is False
    assert observed["staging"].parent == operation
    assert observed["staging_bytes"] == target.read_bytes()
    assert not observed["staging"].exists()


@pytest.mark.native_publication
def test_failed_publication_leaves_no_result_and_no_temporary_file(tmp_path, monkeypatch):
    operation = _prepared_operation(tmp_path)

    def fail(staging, destination):
        raise OSError("simulated failure before rename")

    monkeypatch.setattr(materialization, "_publish_noreplace", fail)
    with pytest.raises(OSError):
        events.write_result(operation, OP, 0, _document())
    assert sorted(p.name for p in operation.iterdir()) == [events.EVENTS_FILENAME]


@pytest.mark.native_publication
def test_result_that_appears_concurrently_is_not_replaced(tmp_path, monkeypatch):
    operation = _prepared_operation(tmp_path)
    target = operation / events.RESULT_FILENAME
    real_publish = materialization._publish_noreplace

    def race(staging, destination):
        target.write_bytes(b"other writer\n")
        real_publish(staging, destination)

    monkeypatch.setattr(materialization, "_publish_noreplace", race)
    with pytest.raises(events.InstallFileError) as raised:
        events.write_result(operation, OP, 0, _document())
    assert raised.value.code == "already_written"
    assert target.read_bytes() == b"other writer\n"
    assert sorted(p.name for p in operation.iterdir()) == [
        events.EVENTS_FILENAME,
        events.RESULT_FILENAME,
    ]


CRASH_CHILD = """
import os
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from stemwerk_core import asset_materialization, install_events

asset_materialization._publish_noreplace = lambda staging, destination: os._exit(17)
install_events.write_result(Path(sys.argv[2]), sys.argv[3], 0, {"kind": "crash"})
"""


@pytest.mark.native_publication
def test_crash_before_rename_never_exposes_a_result(tmp_path):
    operation = _prepared_operation(tmp_path)
    result = run_cli(["-c", CRASH_CHILD, str(CORE_SRC), str(operation), OP])
    assert result.returncode == 17
    assert not (operation / events.RESULT_FILENAME).exists()
    with pytest.raises(FileNotFoundError):
        events.read_result(operation)
    leftovers = [p.name for p in operation.iterdir() if p.name != events.EVENTS_FILENAME]
    assert len(leftovers) == 1 and leftovers[0].startswith(".result.json.")
    assert leftovers[0].endswith(".tmp")
    # A later, honest writer is not blocked by the crashed one.
    events.write_result(operation, OP, 3, {"kind": "after crash"})
    assert events.read_result(operation)["exit_code"] == 3


@pytest.mark.parametrize(
    "content",
    [b"", b'{"protocol":"stemwerk-install-result/1"', b"\xef\xbb\xbf{}\n", b"[]\n", b"{\xff}\n"],
)
def test_read_result_rejects_partial_or_malformed_files(tmp_path, content):
    (tmp_path / events.RESULT_FILENAME).write_bytes(content)
    with pytest.raises(events.InstallFileError) as raised:
        events.read_result(tmp_path)
    assert raised.value.code == "invalid_result"


@pytest.mark.native_publication
def test_started_is_written_once_with_pid_and_timestamp(tmp_path):
    operation = _prepared_operation(tmp_path)
    events.write_started(operation, OP)
    started = events.read_started(operation)
    assert started["protocol"] == events.STARTED_PROTOCOL
    assert started["operation_id"] == OP
    assert started["pid"] == os.getpid()
    datetime.strptime(started["ts"], "%Y-%m-%dT%H:%M:%S.%fZ")
    with pytest.raises(events.InstallFileError) as raised:
        events.write_started(operation, OP, pid=1, ts=TS)
    assert raised.value.code == "already_written"


@pytest.mark.parametrize(("pid", "ts"), [(0, TS), (True, TS), (1, "yesterday")])
def test_invalid_started_is_never_written(tmp_path, pid, ts):
    with pytest.raises(events.InstallFileError) as raised:
        events.write_started(tmp_path, OP, pid=pid, ts=ts)
    assert raised.value.code == "invalid_started"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.native_publication
def test_non_ascii_operation_directories_round_trip(tmp_path):
    # One parent per name: APFS treats the composed and decomposed forms alike.
    for index, name in enumerate(("Testgerät", "beñat", "Testgera\u0308t")):
        logs = tmp_path / str(index) / name / "logs"
        logs.mkdir(parents=True)
        writer = outer_layer_events(logs)
        core = events.EventWriter.accept_handover(logs / OP, OP)
        core.append("failed", "preflight", error_code="path", detail=str(logs), action="none")
        events.write_result(logs / OP, OP, 2, {"root": str(logs)})
        assert events.read_events(logs / OP)[-1]["detail"] == str(logs)
        assert events.read_result(logs / OP)["document"] == {"root": str(logs)}
        assert writer.next_seq == 4


# --- U1: files stay UTF-8; the rename is made durable on POSIX -------------------

U1_TEXT = "Testger\u00e4t be\u00f1at e\u0301 \u041f\u0440\u0438\u0432\u0435\u0442 \u6587\u5b57 \U0001F39B"


@pytest.mark.native_publication
def test_operation_files_stay_unescaped_utf8(tmp_path):
    operation = _prepared_operation(tmp_path)
    core = events.EventWriter.accept_handover(operation, OP)
    core.append("failed", "preflight", error_code="path", detail=U1_TEXT, action=U1_TEXT)
    events.write_result(operation, OP, 2, {"path": U1_TEXT})
    for name in (events.EVENTS_FILENAME, events.RESULT_FILENAME):
        raw = (operation / name).read_bytes()
        assert U1_TEXT.encode("utf-8") in raw
        assert b"\\u" not in raw
    assert events.read_events(operation)[-1]["detail"] == U1_TEXT
    assert events.read_result(operation)["document"] == {"path": U1_TEXT}


def _record_fsyncs(monkeypatch, target):
    import stat

    calls = []
    real_fsync = os.fsync

    def recording(fd):
        calls.append((stat.S_ISDIR(os.fstat(fd).st_mode), os.fstat(fd).st_ino, target.exists()))
        return real_fsync(fd)

    monkeypatch.setattr(os, "fsync", recording)
    return calls


@pytest.mark.skipif(os.name == "nt", reason="directory fsync exists only on POSIX")
@pytest.mark.parametrize("write", ["result", "started"])
def test_directory_is_synced_after_the_rename(tmp_path, monkeypatch, write):
    operation = _prepared_operation(tmp_path)
    name = events.RESULT_FILENAME if write == "result" else events.STARTED_FILENAME
    calls = _record_fsyncs(monkeypatch, operation / name)
    if write == "result":
        events.write_result(operation, OP, 0, {})
    else:
        events.write_started(operation, OP)
    assert events._SYNC_DIRECTORIES is True
    assert calls == [
        (False, calls[0][1], False),  # the temporary file, before publication
        (True, os.stat(operation).st_ino, True),  # the directory, after the rename
    ]


@pytest.mark.skipif(os.name == "nt", reason="directory fsync exists only on POSIX")
def test_directory_sync_failure_is_reported(tmp_path, monkeypatch):
    import stat

    operation = _prepared_operation(tmp_path)
    real_fsync = os.fsync

    def failing_for_directories(fd):
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError(5, "simulated I/O error")
        return real_fsync(fd)

    monkeypatch.setattr(os, "fsync", failing_for_directories)
    with pytest.raises(events.InstallFileError) as raised:
        events.write_result(operation, OP, 0, {"kind": "published"})
    assert raised.value.code == "write_failed"
    assert events.read_result(operation)["document"] == {"kind": "published"}
    with pytest.raises(events.InstallFileError) as again:
        events.write_result(operation, OP, 0, {"kind": "retry"})
    assert again.value.code == "already_written"


@pytest.mark.parametrize(("os_name", "supported"), [("nt", False), ("posix", True)])
def test_directory_sync_is_posix_only(os_name, supported):
    assert events._directory_sync_supported(os_name) is supported


@pytest.mark.native_publication
def test_directory_sync_is_not_attempted_where_unsupported(tmp_path, monkeypatch):
    assert events._SYNC_DIRECTORIES is (os.name != "nt")
    operation = _prepared_operation(tmp_path)
    calls = _record_fsyncs(monkeypatch, operation / events.RESULT_FILENAME)
    monkeypatch.setattr(events, "_SYNC_DIRECTORIES", False)
    events.write_result(operation, OP, 0, {})
    assert [is_directory for is_directory, _, _ in calls] == [False]
