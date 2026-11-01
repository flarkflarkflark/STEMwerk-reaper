"""Files of one installation operation under ``<root>/logs/<op>/``.

Format of the events file (``events.ndjson``), the result file
(``result.json``) and the startup acknowledgement (``started``) from design
section 7.2, with writers and readers. This is a library: no command writes
these files yet. The outer layer creates the operation directory and writes
the first events (G1); Core accepts the directory and continues the sequence.

Encoding is UTF-8 without a byte order mark; non-ASCII text is written as is.
Every events line is one JSON object terminated by ``\\n`` and written with a
single write; readers ignore an incomplete last line. The result and started
files are written once: to a temporary file in the same directory, then
published with the native no-replace rename, so they are never partially
visible and never replaced.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
from typing import Any, Dict, List, Mapping, Optional
import uuid

from . import asset_materialization as materialization


EVENT_PROTOCOL = "stemwerk-install-events/1"
RESULT_PROTOCOL = "stemwerk-install-result/1"
STARTED_PROTOCOL = "stemwerk-install-started/1"

EVENTS_FILENAME = "events.ndjson"
RESULT_FILENAME = "result.json"
STARTED_FILENAME = "started"

SOURCE_OUTER_LAYER = "outer_layer"
SOURCE_CORE = "core"
SOURCES = (SOURCE_OUTER_LAYER, SOURCE_CORE)

# Design section 7.2, in order. `bootstrap` belongs to the outer layer only.
PHASES = (
    "bootstrap",
    "preflight",
    "lock",
    "create_environment",
    "install_packages",
    "fetch_ffmpeg",
    "verify_ffmpeg",
    "fetch_assets",
    "verify_assets",
    "publish",
    "activate",
    "verify_module",
)
OUTER_LAYER_PHASES = ("bootstrap",)

# Required fields per state besides `phase` (design section 7.2).
STATE_FIELDS: Mapping[str, tuple[str, ...]] = {
    "active_determinate": ("done", "total", "unit"),
    "active_indeterminate": ("since_seconds",),
    "possibly_stalled": ("silent_seconds",),
    "retrying": ("error_code", "attempt", "max_attempts"),
    "failed": ("error_code", "detail", "action"),
    "done": ("verified",),
}

EXIT_STREAMS = {0: "stdout", 2: "stderr", 3: "stderr"}

_BASE_EVENT_KEYS = ("protocol", "operation_id", "seq", "ts", "source", "state", "phase")
_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\Z")
_BOM = b"\xef\xbb\xbf"


class InstallFileError(Exception):
    """A malformed, refused or failed operation file. ``code`` is stable."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def utc_timestamp(moment: Optional[datetime] = None) -> str:
    """RFC 3339 UTC timestamp with microseconds and a ``Z`` suffix."""

    moment = datetime.now(timezone.utc) if moment is None else moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _require(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise InstallFileError(code, message)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (_is_int(value) or isinstance(value, float)) and value == value and value >= 0


def _check_operation_id(value: Any, code: str) -> None:
    try:
        canonical = str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        canonical = None
    _require(canonical == value, code, "operation_id must be a lowercase canonical UUID")


def _check_timestamp(value: Any, code: str) -> None:
    ok = isinstance(value, str) and bool(_TIMESTAMP.match(value))
    if ok:
        try:
            datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            ok = False
    _require(ok, code, "ts must be an RFC 3339 UTC timestamp ending in Z")


def _non_empty_text(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def validate_event(event: Any) -> None:
    """Raise ``InstallFileError("invalid_event", ...)`` unless ``event`` is valid."""

    code = "invalid_event"
    _require(isinstance(event, dict), code, "an event is a JSON object")
    _require(event.get("protocol") == EVENT_PROTOCOL, code, "unknown event protocol")
    _check_operation_id(event.get("operation_id"), code)
    _require(_is_int(event.get("seq")) and event["seq"] >= 1, code, "seq must be an integer >= 1")
    _check_timestamp(event.get("ts"), code)
    source = event.get("source")
    _require(source in SOURCES, code, "source must be outer_layer or core")
    state = event.get("state")
    _require(state in STATE_FIELDS, code, f"unknown state {state!r}")
    phase = event.get("phase")
    _require(phase in PHASES, code, f"unknown phase {phase!r}")
    _require(
        (phase in OUTER_LAYER_PHASES) == (source == SOURCE_OUTER_LAYER),
        code,
        "the bootstrap phase belongs to the outer layer, every other phase to Core",
    )
    expected = set(_BASE_EVENT_KEYS) | set(STATE_FIELDS[state])
    _require(set(event) == expected, code, f"fields of a {state} event must be {sorted(expected)}")
    if state == "active_determinate":
        _require(
            _is_int(event["done"]) and _is_int(event["total"]) and 0 <= event["done"] <= event["total"],
            code,
            "done and total must be integers with 0 <= done <= total",
        )
        _require(_non_empty_text(event["unit"]), code, "unit must be a non-empty string")
    elif state == "active_indeterminate":
        _require(_is_number(event["since_seconds"]), code, "since_seconds must be >= 0")
    elif state == "possibly_stalled":
        _require(_is_number(event["silent_seconds"]), code, "silent_seconds must be >= 0")
    elif state == "retrying":
        _require(_non_empty_text(event["error_code"]), code, "error_code must be a non-empty string")
        _require(
            _is_int(event["attempt"])
            and _is_int(event["max_attempts"])
            and 1 <= event["attempt"] <= event["max_attempts"],
            code,
            "attempt and max_attempts must satisfy 1 <= attempt <= max_attempts",
        )
    elif state == "failed":
        for name in ("error_code", "detail", "action"):
            _require(_non_empty_text(event[name]), code, f"{name} must be a non-empty string")
    elif state == "done":
        _require(isinstance(event["verified"], bool), code, "verified must be a boolean")


def encode_line(event: Mapping[str, Any]) -> bytes:
    """Validated, deterministic UTF-8 encoding of one events line."""

    validate_event(event)
    text = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return (text + "\n").encode("utf-8")


def _decode_strict(data: bytes, code: str) -> str:
    _require(not data.startswith(_BOM), code, "file starts with a byte order mark")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InstallFileError(code, "file is not valid UTF-8") from exc


def parse_events(data: bytes) -> List[Dict[str, Any]]:
    """Events from the bytes of an events file.

    An incomplete last line (no terminating newline yet) is ignored; every
    complete line must be valid, belong to the same operation and continue
    the sequence by exactly one, starting at 1.
    """

    code = "invalid_event"
    _require(not data.startswith(_BOM), code, "events file starts with a byte order mark")
    complete = data[: data.rfind(b"\n") + 1]
    events: List[Dict[str, Any]] = []
    for raw in complete.split(b"\n")[:-1]:
        try:
            event = json.loads(_decode_strict(raw, code))
        except json.JSONDecodeError as exc:
            raise InstallFileError(code, "events line is not JSON") from exc
        validate_event(event)
        expected_seq = len(events) + 1
        _require(event["seq"] == expected_seq, code, f"seq {event['seq']} where {expected_seq} was expected")
        if events:
            _require(
                event["operation_id"] == events[0]["operation_id"],
                code,
                "events of another operation in the same file",
            )
            _require(
                not (events[-1]["source"] == SOURCE_CORE and event["source"] == SOURCE_OUTER_LAYER),
                code,
                "outer-layer event after Core took over",
            )
        events.append(event)
    return events


def read_events(operation_dir: Path) -> List[Dict[str, Any]]:
    """Events of an operation; ``FileNotFoundError`` if there is no events file."""

    return parse_events((Path(operation_dir) / EVENTS_FILENAME).read_bytes())


class EventWriter:
    """Appends validated events to one operation's events file.

    Each event is one ``os.write`` of a complete line to a file opened for
    append. Use ``start_operation`` (outer layer, reference behavior) or
    ``accept_handover`` (Core) to obtain a writer.
    """

    def __init__(self, operation_dir: Path, operation_id: str, source: str, next_seq: int) -> None:
        _check_operation_id(operation_id, "invalid_event")
        _require(source in SOURCES, "invalid_event", "source must be outer_layer or core")
        self.operation_dir = Path(operation_dir)
        self.operation_id = operation_id
        self.source = source
        self.next_seq = next_seq

    @property
    def path(self) -> Path:
        return self.operation_dir / EVENTS_FILENAME

    def append(self, state: str, phase: str, *, ts: Optional[str] = None, **fields: Any) -> Dict[str, Any]:
        event: Dict[str, Any] = {
            "protocol": EVENT_PROTOCOL,
            "operation_id": self.operation_id,
            "seq": self.next_seq,
            "ts": utc_timestamp() if ts is None else ts,
            "source": self.source,
            "state": state,
            "phase": phase,
            **fields,
        }
        line = encode_line(event)
        flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
        handle = os.open(self.path, flags)
        try:
            written = os.write(handle, line)
        finally:
            os.close(handle)
        _require(written == len(line), "write_failed", "events line was written partially")
        self.next_seq += 1
        return event

    @classmethod
    def start_operation(cls, logs_dir: Path, operation_id: str) -> "EventWriter":
        """Create ``<logs>/<op>/`` exclusively with an empty events file (outer layer, G1)."""

        _check_operation_id(operation_id, "invalid_event")
        operation_dir = Path(logs_dir) / operation_id
        try:
            os.mkdir(operation_dir)
        except FileExistsError as exc:
            raise InstallFileError("operation_exists", "operation directory already exists") from exc
        handle = os.open(
            operation_dir / EVENTS_FILENAME,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0),
            0o644,
        )
        os.close(handle)
        return cls(operation_dir, operation_id, SOURCE_OUTER_LAYER, 1)

    @classmethod
    def accept_handover(cls, operation_dir: Path, operation_id: str) -> "EventWriter":
        """Core's writer for a directory the outer layer prepared (G1).

        The directory must hold at least one outer-layer event of the same
        operation, only outer-layer events, a complete last line and no
        result file. Core continues at the next sequence number.
        """

        code = "handover_refused"
        _check_operation_id(operation_id, code)
        operation_dir = Path(operation_dir)
        _require(operation_dir.name == operation_id, code, "directory name differs from the operation id")
        _require(not (operation_dir / RESULT_FILENAME).exists(), code, "the operation already has a result")
        try:
            data = (operation_dir / EVENTS_FILENAME).read_bytes()
        except FileNotFoundError as exc:
            raise InstallFileError(code, "the operation has no events file") from exc
        _require(data.endswith(b"\n"), code, "the events file ends with an incomplete line")
        try:
            events = parse_events(data)
        except InstallFileError as exc:
            raise InstallFileError(code, f"the events file is invalid: {exc}") from exc
        _require(bool(events), code, "the outer layer wrote no events")
        _require(events[0]["operation_id"] == operation_id, code, "events belong to another operation")
        _require(
            all(event["source"] == SOURCE_OUTER_LAYER for event in events),
            code,
            "another writer already took over",
        )
        return cls(operation_dir, operation_id, SOURCE_CORE, events[-1]["seq"] + 1)


def _encode_document(document: Mapping[str, Any]) -> bytes:
    text = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return (text + "\n").encode("utf-8")


def _write_once(operation_dir: Path, filename: str, data: bytes) -> Path:
    """Write ``data`` to a same-directory temporary file and publish it no-replace."""

    operation_dir = Path(operation_dir)
    target = operation_dir / filename
    _require(not os.path.lexists(target), "already_written", f"{filename} already exists")
    temporary = operation_dir / f".{filename}.{uuid.uuid4().hex}.tmp"
    handle = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0),
        0o644,
    )
    try:
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(handle, view):]
            os.fsync(handle)
        finally:
            os.close(handle)
        materialization._publish_noreplace(temporary, target)
    except materialization.MaterializationError as exc:
        _remove_quietly(temporary)
        if exc.code == "publication_conflict":
            raise InstallFileError("already_written", f"{filename} already exists") from exc
        raise InstallFileError("write_failed", f"{filename} could not be published") from exc
    except BaseException:
        _remove_quietly(temporary)
        raise
    return target


def _remove_quietly(path: Path) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def validate_result(document: Any) -> None:
    code = "invalid_result"
    _require(isinstance(document, dict), code, "a result is a JSON object")
    _require(
        set(document) == {"protocol", "operation_id", "exit_code", "stream", "document"},
        code,
        "result fields must be protocol, operation_id, exit_code, stream, document",
    )
    _require(document["protocol"] == RESULT_PROTOCOL, code, "unknown result protocol")
    _check_operation_id(document["operation_id"], code)
    exit_code = document["exit_code"]
    _require(_is_int(exit_code) and exit_code in EXIT_STREAMS, code, "exit_code must be 0, 2 or 3")
    _require(
        document["stream"] == EXIT_STREAMS[exit_code],
        code,
        "exit 0 is printed to stdout, exit 2 and 3 to stderr",
    )
    _require(isinstance(document["document"], dict), code, "document must be a JSON object")


def write_result(
    operation_dir: Path, operation_id: str, exit_code: int, document: Mapping[str, Any]
) -> Path:
    """Write ``result.json`` once, before the same document is printed (design 7.2)."""

    result = {
        "protocol": RESULT_PROTOCOL,
        "operation_id": operation_id,
        "exit_code": exit_code,
        "stream": EXIT_STREAMS.get(exit_code) if _is_int(exit_code) else None,
        "document": dict(document) if isinstance(document, Mapping) else document,
    }
    validate_result(result)
    return _write_once(operation_dir, RESULT_FILENAME, _encode_document(result))


def _read_document(path: Path, code: str) -> Any:
    data = Path(path).read_bytes()
    _require(data.endswith(b"\n"), code, f"{Path(path).name} is incomplete")
    try:
        return json.loads(_decode_strict(data, code))
    except json.JSONDecodeError as exc:
        raise InstallFileError(code, f"{Path(path).name} is not JSON") from exc


def read_result(operation_dir: Path) -> Dict[str, Any]:
    """The operation's result; ``FileNotFoundError`` while there is none."""

    result = _read_document(Path(operation_dir) / RESULT_FILENAME, "invalid_result")
    validate_result(result)
    return result


def validate_started(document: Any) -> None:
    code = "invalid_started"
    _require(isinstance(document, dict), code, "started is a JSON object")
    _require(set(document) == {"protocol", "operation_id", "pid", "ts"}, code, "started fields must be protocol, operation_id, pid, ts")
    _require(document["protocol"] == STARTED_PROTOCOL, code, "unknown started protocol")
    _check_operation_id(document["operation_id"], code)
    _require(_is_int(document["pid"]) and document["pid"] > 0, code, "pid must be a positive integer")
    _check_timestamp(document["ts"], code)


def write_started(
    operation_dir: Path, operation_id: str, *, pid: Optional[int] = None, ts: Optional[str] = None
) -> Path:
    """Write the startup acknowledgement once (design 6.5, F9)."""

    started = {
        "protocol": STARTED_PROTOCOL,
        "operation_id": operation_id,
        "pid": os.getpid() if pid is None else pid,
        "ts": utc_timestamp() if ts is None else ts,
    }
    validate_started(started)
    return _write_once(operation_dir, STARTED_FILENAME, _encode_document(started))


def read_started(operation_dir: Path) -> Dict[str, Any]:
    """The startup acknowledgement; ``FileNotFoundError`` while there is none."""

    started = _read_document(Path(operation_dir) / STARTED_FILENAME, "invalid_started")
    validate_started(started)
    return started
