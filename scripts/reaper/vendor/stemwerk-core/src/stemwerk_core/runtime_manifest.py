"""The pinned managed-runtime manifest (design section 6.2; D9, F5, F6, G4).

``runtime-manifest.v1.tsv`` next to this module is the one source of truth
for the managed Python. The outer layers (Inno Setup's Pascal script on
Windows, the POSIX ``sh`` bootstrap on macOS and Linux) and Core read the
same file. Its grammar is strict, so that every reader either agrees or
refuses:

- the file is ASCII, without a byte order mark, and every line, the last
  one included, ends with a single LF (no CR);
- the first line is exactly ``stemwerk-runtime-manifest/1``;
- every further line is one record of exactly five fields separated by
  single TABs: ``platform``, ``name``, ``url``, ``size``, ``sha256``;
- no empty lines, comments, spaces or extra fields.

Record rules (this module refuses anything else with ``manifest_invalid``):

- ``platform`` is a route platform (``linux-x86_64``, ``darwin-arm64``,
  ``win-x86_64``); each has exactly one ``python`` record.
- ``name`` is the pin id and the published directory name
  ``<root>/runtimes/python/<name>/``: ``python-<version>-<build>``, where the
  version is CPython 3.12.x (D2) and the build is the python-build-standalone
  release date ``YYYYMMDD``. Patch and build are both pinned, never "latest"
  (F6).
- ``url`` is exactly the python-build-standalone release asset of that
  version, build and platform in the ``install_only_stripped`` flavour, so a
  record whose name and URL disagree is refused.
- ``size`` is a positive decimal byte count without leading zeros; ``sha256``
  is 64 lowercase hexadecimal digits.

Integrity order (design section 6.2): size first, then SHA-256, then unpack;
a mismatch is a named failure and nothing is unpacked. The hashes are trusted
because they are pinned in this versioned repository file and were checked
against the upstream release checksums when the pin was chosen; TLS to the
vendor host establishes transport only, never content identity.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from importlib import resources
import os
from pathlib import Path
import re
import stat
from typing import Any, Dict, Iterable, Optional, Tuple

from . import asset_materialization as materialization


MANIFEST_PROTOCOL = "stemwerk-runtime-manifest/1"
MANIFEST_FILENAME = "runtime-manifest.v1.tsv"
FIELDS = ("platform", "name", "url", "size", "sha256")

# Route platforms (design section 10.3); equal to module_install.PLATFORMS.
PLATFORMS = ("linux-x86_64", "darwin-arm64", "win-x86_64")
PYTHON = "python"
COMPONENTS = (PYTHON,)

PBS_DOWNLOAD_BASE = "https://github.com/astral-sh/python-build-standalone/releases/download/"
PBS_FLAVOUR = "install_only_stripped"
PBS_TARGETS = {
    "linux-x86_64": "x86_64-unknown-linux-gnu",
    "darwin-arm64": "aarch64-apple-darwin",
    "win-x86_64": "x86_64-pc-windows-msvc",
}

_PYTHON_NAME = re.compile(r"python-(3\.12\.(?:0|[1-9][0-9]{0,2}))-([0-9]{8})\Z")
_SIZE = re.compile(r"[1-9][0-9]{0,11}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_CHUNK = 1024 * 1024


class ManifestError(Exception):
    """``code`` is stable: ``manifest_invalid``, ``manifest_unavailable``,
    ``platform_unsupported``, ``archive_unavailable``, ``archive_size_mismatch``
    or ``archive_sha256_mismatch``. ``line`` is the 1-based manifest line, if any."""

    def __init__(self, code: str, message: str, *, line: Optional[int] = None,
                 details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message if line is None else f"line {line}: {message}")
        self.code = code
        self.line = line
        self.details = dict(details or {})


@dataclass(frozen=True)
class RuntimeRecord:
    platform: str
    name: str
    url: str
    size: int
    sha256: str
    component: str
    version: str
    build: str

    def to_json(self) -> Dict[str, Any]:
        return {
            "platform": self.platform,
            "name": self.name,
            "url": self.url,
            "size": self.size,
            "sha256": self.sha256,
            "component": self.component,
            "version": self.version,
            "build": self.build,
        }


def python_archive_url(platform_id: str, version: str, build: str) -> str:
    """The only URL a ``python`` record of these values may carry."""

    return (
        f"{PBS_DOWNLOAD_BASE}{build}/cpython-{version}%2B{build}-"
        f"{PBS_TARGETS[platform_id]}-{PBS_FLAVOUR}.tar.gz"
    )


def _invalid(message: str, line: Optional[int] = None) -> ManifestError:
    return ManifestError("manifest_invalid", message, line=line)


def _record(fields: Tuple[str, ...], line: int) -> RuntimeRecord:
    platform_id, name, url, size, sha256 = fields
    if platform_id not in PLATFORMS:
        raise _invalid(f"unknown platform {platform_id!r}", line)
    match = _PYTHON_NAME.match(name)
    if match is None:
        raise _invalid(
            f"name {name!r} is not python-<3.12.x>-<YYYYMMDD> (the only component of this version)",
            line,
        )
    version, build = match.group(1), match.group(2)
    if url != python_archive_url(platform_id, version, build):
        raise _invalid(f"url does not match the pinned {PBS_FLAVOUR} asset of {name}", line)
    if not _SIZE.match(size):
        raise _invalid("size must be a positive decimal integer without leading zeros", line)
    if not _SHA256.match(sha256):
        raise _invalid("sha256 must be 64 lowercase hexadecimal digits", line)
    return RuntimeRecord(platform_id, name, url, int(size), sha256, PYTHON, version, build)


def parse_manifest(data: bytes) -> Tuple[RuntimeRecord, ...]:
    """All records of a manifest, in file order; ``manifest_invalid`` otherwise."""

    if not isinstance(data, bytes):
        raise _invalid("the manifest must be bytes")
    if data.startswith(b"\xef\xbb\xbf"):
        raise _invalid("the manifest starts with a byte order mark")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise _invalid("the manifest is not ASCII") from exc
    if "\r" in text:
        raise _invalid("the manifest contains a carriage return; lines end with LF only")
    if not text.endswith("\n"):
        raise _invalid("the last line does not end with LF")
    lines = text[:-1].split("\n")
    if lines[0] != MANIFEST_PROTOCOL:
        raise _invalid(f"the first line must be {MANIFEST_PROTOCOL!r}", 1)
    records = []
    seen = set()
    for number, line in enumerate(lines[1:], start=2):
        if line == "":
            raise _invalid("empty line", number)
        if " " in line or any(ord(char) < 0x20 and char != "\t" for char in line):
            raise _invalid("spaces and control characters other than TAB are not allowed", number)
        fields = tuple(line.split("\t"))
        if len(fields) != len(FIELDS) or any(field == "" for field in fields):
            raise _invalid(f"a record has exactly {len(FIELDS)} non-empty TAB-separated fields", number)
        record = _record(fields, number)
        key = (record.platform, record.component)
        if key in seen:
            raise _invalid(f"a second {record.component} record for {record.platform}", number)
        seen.add(key)
        records.append(record)
    missing = [p for p in PLATFORMS if (p, PYTHON) not in seen]
    if missing:
        raise _invalid(f"no {PYTHON} record for {', '.join(missing)}")
    return tuple(records)


def manifest_bytes() -> bytes:
    """The bytes of the manifest shipped with this Core."""

    try:
        return resources.files(__package__).joinpath(MANIFEST_FILENAME).read_bytes()
    except OSError as exc:
        raise ManifestError("manifest_unavailable", f"cannot read {MANIFEST_FILENAME}: {exc}") from exc


def load_manifest(data: Optional[bytes] = None) -> Tuple[RuntimeRecord, ...]:
    return parse_manifest(manifest_bytes() if data is None else data)


def python_record(
    platform_id: Optional[str], records: Optional[Iterable[RuntimeRecord]] = None
) -> RuntimeRecord:
    """The pinned Python of a route platform; ``platform_unsupported`` otherwise."""

    for record in load_manifest() if records is None else records:
        if record.platform == platform_id and record.component == PYTHON:
            return record
    raise ManifestError(
        "platform_unsupported",
        f"no managed Python is pinned for platform {platform_id!r}",
        details={"platform": platform_id, "supported": list(PLATFORMS)},
    )


def check_archive(path: os.PathLike | str, record: RuntimeRecord) -> Dict[str, Any]:
    """Check a downloaded archive against its record: size first, then SHA-256.

    Read-only. The archive must be a regular file, not a link or reparse
    point. The file is hashed only when its size matches, so a truncated or
    oversized download is refused without reading it.
    """

    path = Path(path)
    try:
        path_stat = os.lstat(path)
    except OSError as exc:
        raise ManifestError("archive_unavailable", f"cannot inspect the archive: {exc}") from exc
    if materialization._is_link_or_reparse(path_stat) or not stat.S_ISREG(path_stat.st_mode):
        raise ManifestError("archive_unavailable", "the archive is not a regular file")
    flags = os.O_RDONLY | materialization._binary_flag() | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ManifestError("archive_unavailable", f"cannot open the archive: {exc}") from exc
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (path_stat.st_dev, path_stat.st_ino) and os.name != "nt":
            raise ManifestError("archive_unavailable", "the archive changed while it was opened")
        if opened.st_size != record.size:
            raise ManifestError(
                "archive_size_mismatch",
                f"archive has {opened.st_size} bytes, the manifest pins {record.size}",
                details={"observed": opened.st_size, "expected": record.size},
            )
        digest = hashlib.sha256()
        read = 0
        while True:
            chunk = os.read(descriptor, _CHUNK)
            if not chunk:
                break
            read += len(chunk)
            digest.update(chunk)
    finally:
        os.close(descriptor)
    observed = digest.hexdigest()
    if read != record.size:
        raise ManifestError(
            "archive_size_mismatch",
            f"read {read} bytes, the manifest pins {record.size}",
            details={"observed": read, "expected": record.size},
        )
    if observed != record.sha256:
        raise ManifestError(
            "archive_sha256_mismatch",
            "archive SHA-256 differs from the manifest pin",
            details={"observed": observed, "expected": record.sha256},
        )
    return {"size": read, "sha256": observed}


def published_directory(root: os.PathLike | str, record: RuntimeRecord) -> Path:
    """``<root>/runtimes/python/<name>``, where the outer layer publishes (G1 step 4)."""

    return Path(root) / "runtimes" / record.component / record.name
