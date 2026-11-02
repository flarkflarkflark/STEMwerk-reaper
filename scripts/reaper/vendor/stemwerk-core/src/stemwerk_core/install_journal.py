"""Operation journal and crash recovery (design section 8, owner decision D1).

Each mutating operation journals what it is about to do in
``<root>/tmp/<op>/journal.ndjson`` and builds everything in its own staging
directory ``<root>/tmp/<op>/core/``, separate from the outer layer's bootstrap
staging in the same operation directory. The journal is append-only NDJSON,
UTF-8 without a byte order mark, one JSON object per line:

- an ``open`` record, first;
- an ``intent`` record BEFORE each mutation, flushed and fsynced before the
  mutation starts;
- a ``completion`` record after it, with the identity (device, inode, kind)
  of what now exists.

A reader ignores an incomplete last line, as left by a crash in the middle of
a write. Recovery runs after every acquisition of the install lock
(``install_lock.acquire``). For every other operation directory that has a
journal it removes unpublished staging and reports published results, which
it verifies through a caller-supplied hook and never deletes. It touches
nothing that is not journaled; an operation directory without a journal (for
example the outer layer's bootstrap staging) is never touched.

This is a library. No operation writes a journal yet; the first writer comes
with the runtime build (slice S6).
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
from typing import Any, Callable, Dict, List, Optional

from . import asset_materialization as materialization
from . import install_events
from ._install_paths import (
    DIRECTORY_MODE,
    Identity,
    InstallPathError,
    check_existing_directories,
    create_file,
    ensure_directories,
    lstat_inside,
    sync_directory,
)


JOURNAL_PROTOCOL = "stemwerk-install-journal/1"
JOURNAL_FILENAME = "journal.ndjson"
TMP_DIRECTORY = "tmp"
CORE_DIRECTORY = "core"

CREATE_DIRECTORY = "create_directory"
CREATE_FILE = "create_file"
RENAME = "rename"
REMOVE = "remove"
ACTIONS = (CREATE_DIRECTORY, CREATE_FILE, RENAME, REMOVE)

_RECORDS = ("open", "intent", "completion")

# Outcomes per journaled item in a recovery report.
REMOVED = "removed"
ALREADY_ABSENT = "already_absent"
KEPT_IDENTITY_MISMATCH = "kept_identity_mismatch"
KEPT_REMOVE_FAILED = "kept_remove_failed"
KEPT_CONTAINS_KEPT_ITEM = "kept_contains_kept_item"
PUBLISHED_VERIFIED = "published_verified"
PUBLISHED_FAILED = "published_failed"
PUBLISHED_UNVERIFIED = "published_unverified"
NOT_APPLICABLE = "not_applicable"
_KEPT = (KEPT_IDENTITY_MISMATCH, KEPT_REMOVE_FAILED, KEPT_CONTAINS_KEPT_ITEM)


class JournalError(Exception):
    """``code`` is stable: journal_exists, journal_invalid, journal_path_ineligible,
    journal_path_unavailable, journal_write_failed or journal_action_refused."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _path_error(exc: InstallPathError) -> JournalError:
    return JournalError(f"journal_{exc.code}", str(exc))


def _relative(root: Path, path: Path) -> str:
    try:
        relative = Path(path).relative_to(root)
    except ValueError as exc:
        raise JournalError("journal_action_refused", f"{path} is not under <root>") from exc
    if not relative.parts or ".." in relative.parts:
        raise JournalError("journal_action_refused", f"{path} is not a path below <root>")
    return relative.as_posix()


def _resolve(root: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative:
        raise JournalError("journal_invalid", "a journal path must be a non-empty string")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or "\\" in relative or ":" in relative:
        raise JournalError("journal_invalid", "a journal path must stay below <root>")
    return root.joinpath(*pure.parts)


def operation_directory(root: Path, operation_id: str) -> Path:
    install_events._check_operation_id(operation_id, "journal_invalid")
    return Path(root) / TMP_DIRECTORY / operation_id


class Journal:
    """Writer for one operation's journal. Use :func:`open_journal`."""

    def __init__(self, root: Path, operation_id: str, descriptor: int, directory: Path) -> None:
        self.root = root
        self.operation_id = operation_id
        self.directory = directory
        self.core_directory = directory / CORE_DIRECTORY
        self.path = directory / JOURNAL_FILENAME
        self._descriptor: Optional[int] = descriptor
        self._seq = 0
        self._core_pending = True  # core/ itself is created once, by open_journal

    # -- records ---------------------------------------------------------

    def _append(self, record: Dict[str, Any]) -> int:
        if self._descriptor is None:
            raise JournalError("journal_write_failed", "the journal is closed")
        self._seq += 1
        line = {
            "protocol": JOURNAL_PROTOCOL,
            "operation_id": self.operation_id,
            "seq": self._seq,
            "ts": install_events.utc_timestamp(),
            **record,
        }
        data = (
            json.dumps(line, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
        try:
            written = os.write(self._descriptor, data)
            if written != len(data):
                raise OSError("short write to the journal")
            os.fsync(self._descriptor)
        except OSError as exc:
            raise JournalError("journal_write_failed", f"cannot write the journal: {exc}") from exc
        return self._seq

    def intent(self, action: str, path: Path, *, destination: Optional[Path] = None) -> int:
        """Record and sync an intent BEFORE the mutation; returns its ``seq``."""

        if action not in ACTIONS:
            raise JournalError("journal_action_refused", f"unknown action {action!r}")
        if action == RENAME:
            if destination is None:
                raise JournalError("journal_action_refused", "a rename needs a destination")
        elif destination is not None:
            raise JournalError("journal_action_refused", "only a rename has a destination")
        if self._core_pending and action == CREATE_DIRECTORY and path == self.core_directory:
            self._core_pending = False
        else:
            self._require_in_core(path)
        record: Dict[str, Any] = {"record": "intent", "action": action, "path": _relative(self.root, path)}
        if destination is not None:
            record["destination"] = _relative(self.root, destination)
        return self._append(record)

    def completion(self, intent_seq: int, path: Optional[Path]) -> int:
        """Record what exists after the mutation; ``path=None`` for a removal."""

        identity = None
        if path is not None:
            try:
                path_stat = lstat_inside(path)
            except InstallPathError as exc:
                raise _path_error(exc) from exc
            if path_stat is None:
                raise JournalError("journal_write_failed", f"{path} does not exist after the mutation")
            identity = Identity.of(path_stat).to_json()
        return self._append({"record": "completion", "intent_seq": intent_seq, "identity": identity})

    def _require_in_core(self, path: Path) -> None:
        relative = Path(_relative(self.root, path))
        core = Path(_relative(self.root, self.core_directory))
        if relative == core or core not in relative.parents:
            raise JournalError(
                "journal_action_refused", f"{path} is not inside the operation's core/ staging"
            )

    # -- journaled mutations ---------------------------------------------

    def create_directory(self, path: Path) -> Path:
        seq = self.intent(CREATE_DIRECTORY, path)
        try:
            os.mkdir(path, DIRECTORY_MODE)
            if os.name == "posix":
                os.chmod(path, DIRECTORY_MODE)  # exactly 0o700 whatever the umask
        except OSError as exc:
            raise JournalError("journal_write_failed", f"cannot create {path}: {exc}") from exc
        self.completion(seq, path)
        return path

    def create_file(self, path: Path, data: bytes) -> Path:
        seq = self.intent(CREATE_FILE, path)
        try:
            descriptor = create_file(path)
            try:
                os.write(descriptor, data)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        except OSError as exc:
            raise JournalError("journal_write_failed", f"cannot create {path}: {exc}") from exc
        self.completion(seq, path)
        return path

    def rename(
        self,
        source: Path,
        destination: Path,
        publish: Callable[[Path, Path], None] = materialization._publish_noreplace,
    ) -> Path:
        """Journal and perform a no-replace rename out of staging (a publication)."""

        seq = self.intent(RENAME, source, destination=destination)
        publish(source, destination)
        self.completion(seq, destination)
        return destination

    def remove(self, path: Path) -> None:
        seq = self.intent(REMOVE, path)
        try:
            if stat.S_ISDIR(os.lstat(path).st_mode):
                shutil.rmtree(path)
            else:
                os.unlink(path)
        except OSError as exc:
            raise JournalError("journal_write_failed", f"cannot remove {path}: {exc}") from exc
        self.completion(seq, None)

    def close(self) -> None:
        if self._descriptor is not None:
            descriptor, self._descriptor = self._descriptor, None
            os.close(descriptor)

    def __enter__(self) -> "Journal":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()


def open_journal(root: os.PathLike | str, operation_id: str) -> Journal:
    """Create ``<root>/tmp/<op>/journal.ndjson`` and the ``core/`` staging.

    The operation directory may already exist (the outer layer's bootstrap
    staging, G1); a second journal for the same operation is refused. Call
    only while holding the install lock.
    """

    root = Path(root)
    directory = operation_directory(root, operation_id)
    try:
        tmp = ensure_directories(root, (TMP_DIRECTORY,))
        directory_created = lstat_inside(directory) is None
        ensure_directories(root, (TMP_DIRECTORY, operation_id))
        sync_directory(tmp)
        descriptor = create_file(directory / JOURNAL_FILENAME, os.O_APPEND)
    except InstallPathError as exc:
        raise _path_error(exc) from exc
    except FileExistsError as exc:
        raise JournalError("journal_exists", f"operation {operation_id} already has a journal") from exc
    except OSError as exc:
        raise JournalError("journal_path_unavailable", f"cannot create the journal: {exc}") from exc
    journal = Journal(root, operation_id, descriptor, directory)
    try:
        sync_directory(directory)
        journal._append({"record": "open", "operation_directory_created": directory_created})
        journal.create_directory(journal.core_directory)
    except BaseException:
        journal.close()
        raise
    return journal


# --- reading -------------------------------------------------------------


def parse_journal(data: bytes, operation_id: str) -> List[Dict[str, Any]]:
    """Records of a journal; an incomplete last line is ignored."""

    if data.startswith(b"\xef\xbb\xbf"):
        raise JournalError("journal_invalid", "the journal starts with a byte order mark")
    lines = data.split(b"\n")
    lines.pop()  # the incomplete last line, or b"" after a final newline
    records: List[Dict[str, Any]] = []
    for number, raw in enumerate(lines, 1):
        try:
            record = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise JournalError("journal_invalid", f"journal line {number} is not JSON") from exc
        if (
            not isinstance(record, dict)
            or record.get("protocol") != JOURNAL_PROTOCOL
            or record.get("operation_id") != operation_id
            or record.get("seq") != number
            or record.get("record") not in _RECORDS
        ):
            raise JournalError("journal_invalid", f"journal line {number} is not a journal record")
        if (number == 1) != (record["record"] == "open"):
            raise JournalError("journal_invalid", "the journal must start with exactly one open record")
        records.append(record)
    return records


@dataclass
class OperationRecovery:
    operation_id: str
    complete: bool
    error: Optional[str] = None
    items: List[Dict[str, Any]] = field(default_factory=list)


@dataclass
class RecoveryReport:
    operations: List[OperationRecovery] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return all(operation.complete for operation in self.operations)

    def to_json(self) -> Dict[str, Any]:
        return {
            "complete": self.complete,
            "operations": [
                {
                    "operation_id": o.operation_id,
                    "complete": o.complete,
                    "error": o.error,
                    "items": o.items,
                }
                for o in self.operations
            ],
        }


PublishedVerifier = Callable[[Path], bool]


def _identity(value: Any) -> Optional[Identity]:
    if not isinstance(value, dict):
        return None
    device, inode, is_directory = value.get("device"), value.get("inode"), value.get("is_directory")
    if not (isinstance(device, int) and isinstance(inode, int) and isinstance(is_directory, bool)):
        return None
    return Identity(device, inode, is_directory)


def _remove_owned(
    path: Path, identity: Optional[Identity], inside_core: bool, kept: List[Path], core: Path
) -> str:
    """Remove ``path`` if it is the journaled object; ``identity=None`` means the
    mutation never completed, which is acceptable only inside ``core/``. A
    directory that contains a kept item is kept too."""

    if any(path in item.parents for item in kept):
        return KEPT_CONTAINS_KEPT_ITEM
    try:
        for ancestor in reversed(path.parents):
            if ancestor == core or core in ancestor.parents:
                lstat_inside(ancestor)  # never reach the item through a link
        path_stat = lstat_inside(path)
    except InstallPathError:
        return KEPT_IDENTITY_MISMATCH
    if path_stat is None:
        return ALREADY_ABSENT
    if identity is None:
        if not inside_core or not (stat.S_ISDIR(path_stat.st_mode) or stat.S_ISREG(path_stat.st_mode)):
            return KEPT_IDENTITY_MISMATCH
    elif not identity.matches(path_stat):
        return KEPT_IDENTITY_MISMATCH
    try:
        if stat.S_ISDIR(path_stat.st_mode):
            shutil.rmtree(path)
        else:
            os.unlink(path)
    except OSError:
        return KEPT_REMOVE_FAILED
    return REMOVED


def _recover_operation(
    root: Path, directory: Path, operation_id: str, verify_published: Optional[PublishedVerifier]
) -> OperationRecovery:
    result = OperationRecovery(operation_id, complete=False)
    journal_path = directory / JOURNAL_FILENAME
    try:
        if lstat_inside(journal_path) is None:
            result.error = "journal_missing"
            return result
        with open(journal_path, "rb") as handle:
            records = parse_journal(handle.read(), operation_id)
    except (OSError, InstallPathError) as exc:
        result.error = "journal_unreadable"
        result.items.append({"detail": str(exc)})
        return result
    except JournalError as exc:
        result.error = exc.code
        return result
    if not records:
        result.error = "journal_empty"
        return result

    core = directory / CORE_DIRECTORY
    completions = {
        record.get("intent_seq"): record for record in records if record["record"] == "completion"
    }
    published_sources = set()
    kept: List[Path] = []
    for record in reversed([r for r in records if r["record"] == "intent"]):
        action = record.get("action")
        try:
            path = _resolve(root, record.get("path"))
        except JournalError:
            result.error = "journal_invalid"
            return result
        if action == CREATE_DIRECTORY and path == core:
            continue  # core/ itself is removed last, below
        completion = completions.get(record["seq"])
        item: Dict[str, Any] = {"seq": record["seq"], "action": action, "path": record.get("path")}
        inside_core = core in path.parents or path == core
        if action == RENAME:
            try:
                destination = _resolve(root, record.get("destination"))
            except JournalError:
                result.error = "journal_invalid"
                return result
            item["destination"] = record.get("destination")
            published = completion is not None
            if not published:
                # The rename may have happened just before a crash.
                created = next(
                    (
                        completions.get(r["seq"])
                        for r in records
                        if r["record"] == "intent"
                        and r.get("path") == record.get("path")
                        and r.get("action") in (CREATE_DIRECTORY, CREATE_FILE)
                    ),
                    None,
                )
                source_identity = _identity(created.get("identity")) if created else None
                try:
                    destination_stat = lstat_inside(destination)
                except InstallPathError:
                    destination_stat = None
                published = bool(
                    source_identity and destination_stat and source_identity.matches(destination_stat)
                )
            if published:
                published_sources.add(record.get("path"))
                if verify_published is None:
                    item["outcome"] = PUBLISHED_UNVERIFIED
                else:
                    item["outcome"] = (
                        PUBLISHED_VERIFIED if verify_published(destination) else PUBLISHED_FAILED
                    )
            else:
                item["outcome"] = NOT_APPLICABLE
        elif action in (CREATE_DIRECTORY, CREATE_FILE):
            if record.get("path") in published_sources:
                item["outcome"] = NOT_APPLICABLE
            else:
                identity = _identity(completion.get("identity")) if completion else None
                item["outcome"] = _remove_owned(path, identity, inside_core, kept, core)
        else:
            item["outcome"] = NOT_APPLICABLE
        if item["outcome"] in _KEPT:
            kept.append(path)
        result.items.append(item)

    core_record = next(
        (r for r in records if r["record"] == "intent" and r.get("action") == CREATE_DIRECTORY
         and _resolve(root, r.get("path")) == core),
        None,
    )
    if core_record is not None:
        completion = completions.get(core_record["seq"])
        identity = _identity(completion.get("identity")) if completion else None
        outcome = _remove_owned(core, identity, True, kept, core)
        result.items.append({"seq": core_record["seq"], "action": CREATE_DIRECTORY,
                             "path": core_record.get("path"), "outcome": outcome})
        if outcome in _KEPT:
            kept.append(core)

    if kept:
        return result  # the journal stays, so the next recovery reports it again
    try:
        os.unlink(journal_path)
    except OSError:
        result.error = "journal_remove_failed"
        return result
    if records[0].get("operation_directory_created") is True:
        try:
            os.rmdir(directory)  # only if empty: outer-layer content stays
        except OSError:
            pass
    result.complete = True
    return result


def recover(
    root: os.PathLike | str,
    *,
    current_operation_id: Optional[str] = None,
    verify_published: Optional[PublishedVerifier] = None,
) -> RecoveryReport:
    """Recover every journaled operation under ``<root>/tmp`` except the current one.

    Call only while holding the install lock: no other Core operation is then
    running, so every other journal belongs to an interrupted operation.
    """

    root = Path(root)
    report = RecoveryReport()
    try:
        tmp = check_existing_directories(root, (TMP_DIRECTORY,))
    except InstallPathError as exc:
        raise _path_error(exc) from exc
    if tmp is None:
        return report
    for entry in sorted(os.listdir(tmp)):
        if entry == current_operation_id:
            continue
        try:
            install_events._check_operation_id(entry, "journal_invalid")
        except install_events.InstallFileError:
            continue  # not an operation directory: never touched
        directory = tmp / entry
        try:
            directory_stat = lstat_inside(directory)
            journal_stat = lstat_inside(directory / JOURNAL_FILENAME) if directory_stat else None
        except InstallPathError:
            continue
        if directory_stat is None or not stat.S_ISDIR(directory_stat.st_mode) or journal_stat is None:
            continue  # no journal: nothing here is Core's to remove
        report.operations.append(_recover_operation(root, directory, entry, verify_published))
    return report
