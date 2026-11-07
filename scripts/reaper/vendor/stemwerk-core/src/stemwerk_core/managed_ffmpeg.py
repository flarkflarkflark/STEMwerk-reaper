"""STEMwerk's own pinned FFmpeg pair (design D11, F1-F5; slice S7, Linux).

``ffmpeg-pin.v1.json`` next to this module is the one source of truth for the
pair. It is a Core-only file: the outer layers never read it, and the shared
``runtime-manifest.v1.tsv`` stays Python-only.

Integrity has two layers, and neither replaces the other:

- the vendor SHA-256 in the pin covers the ARCHIVE only, so the archive's size
  and SHA-256 are checked before it is opened;
- the extracted ``ffmpeg``, ``ffprobe`` and licence files are pinned one by one,
  and the installed tree (exact entries, kinds, modes, sizes and SHA-256) is
  compared with the pin and with the receipt on every verification.

Nothing here falls back to a system FFmpeg, reads a user override or consults
``PATH`` to find the pair.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import time
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple
import urllib.error
import urllib.parse
import urllib.request
import wave

PIN_SCHEMA = "stemwerk-ffmpeg-pin/1"
PIN_FILENAME = "ffmpeg-pin.v1.json"
PLATFORMS = ("linux-x86_64",)
NOTICE_NAME = "NOTICE.txt"
LICENSE_NAME = "LICENSE.txt"
FFMPEG_MEMBER = "bin/ffmpeg"
FFPROBE_MEMBER = "bin/ffprobe"
KEPT_MEMBERS = (FFMPEG_MEMBER, FFPROBE_MEMBER, LICENSE_NAME)
INSTALLED_FILES = (FFMPEG_MEMBER, FFPROBE_MEMBER, LICENSE_NAME, NOTICE_NAME)
INSTALLED_DIRECTORIES = ("bin",)
DIRECTORY_MODE = 0o755
NOTICE_MODE = 0o644

DOWNLOAD_BASE = "https://github.com/BtbN/FFmpeg-Builds/releases/download/"
DOWNLOAD_HOSTS = ("github.com",)
REDIRECT_HOSTS = ("objects.githubusercontent.com", "release-assets.githubusercontent.com")
ARCHIVE_CACHE_ENV = "STEMWERK_FFMPEG_SOURCE_DIR"

# Environment variables that name the pair for the tools the worker's libraries
# use. They are set from the verified pair and never read from the user.
FFMPEG_ENV_VARS = ("STEMWERK_FFMPEG_PATH", "FFMPEG_PATH", "IMAGEIO_FFMPEG_EXE", "FFMPEG_BINARY")
FFPROBE_ENV_VARS = ("STEMWERK_FFPROBE_PATH", "FFPROBE_PATH", "FFPROBE_BINARY")

PROBE_COMMAND_TIMEOUT_SECONDS = 30
PROBE_TOTAL_TIMEOUT_SECONDS = 60
PROBE_SEED = 20261107
PROBE_RATE = 44100
PROBE_SECONDS = 2

_PIN_ID = re.compile(r"[a-z0-9][a-z0-9._-]{3,95}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_COMMIT = re.compile(r"[0-9a-f]{40}\Z")
_MODE = re.compile(r"0[0-7]{3}\Z")
_CHUNK = 1024 * 1024


class FFmpegError(RuntimeError):
    """Structured failure. ``code`` is stable and names the broken rule."""

    def __init__(self, code: str, message: str, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = dict(details)


# --- the pin ---------------------------------------------------------------


@dataclass(frozen=True)
class FileRecord:
    path: str
    size: int
    sha256: str
    mode: int


@dataclass(frozen=True)
class FFmpegPin:
    platform: str
    pin_id: str
    vendor: str
    release_tag: str
    version: str
    archive_url: str
    archive_size: int
    archive_sha256: str
    top_directory: str
    member_count: int
    member_bytes: int
    files: Tuple[FileRecord, ...]
    configuration: str
    license: str
    ffmpeg_repository: str
    ffmpeg_commit: str
    recipe_repository: str
    recipe_commit: str

    @property
    def archive_name(self) -> str:
        return self.archive_url.rsplit("/", 1)[-1]

    def member(self, path: str) -> FileRecord:
        for record in self.files:
            if record.path == path:
                return record
        raise KeyError(path)

    def to_json(self) -> Dict[str, Any]:
        return {
            "platform": self.platform,
            "pin_id": self.pin_id,
            "release_tag": self.release_tag,
            "version": self.version,
            "archive_url": self.archive_url,
            "archive_size": self.archive_size,
            "archive_sha256": self.archive_sha256,
        }


def default_pin_path() -> Path:
    return Path(__file__).resolve().parent / PIN_FILENAME


def _invalid(message: str) -> FFmpegError:
    return FFmpegError("pin_invalid", message)


def _exact_keys(value: Any, keys: Tuple[str, ...], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != set(keys):
        raise _invalid(f"{label} must be an object with exactly the keys {', '.join(keys)}")
    return value


def _positive_int(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise _invalid(f"{label} must be a positive integer")
    return value


def _text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or not value.isascii() or "\n" in value or "\r" in value:
        raise _invalid(f"{label} must be one line of non-empty ASCII text")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or not _SHA256.match(value):
        raise _invalid(f"{label} must be 64 lowercase hexadecimal digits")
    return value


def _parse_platform(platform_key: str, raw: Any) -> FFmpegPin:
    body = _exact_keys(
        raw,
        ("pin_id", "vendor", "release_tag", "version", "archive", "files", "configuration", "license", "sources"),
        f"platform {platform_key}",
    )
    archive = _exact_keys(
        body["archive"],
        ("url", "size", "sha256", "top_directory", "member_count", "member_bytes"),
        "archive",
    )
    sources = _exact_keys(
        body["sources"],
        ("ffmpeg_repository", "ffmpeg_commit", "recipe_repository", "recipe_commit"),
        "sources",
    )
    pin_id = _text(body["pin_id"], "pin_id")
    version = _text(body["version"], "version")
    release_tag = _text(body["release_tag"], "release_tag")
    if not _PIN_ID.match(pin_id) or version.lower() not in pin_id:
        raise _invalid("pin_id must be a lowercase directory name that contains the version")
    top = _text(archive["top_directory"], "archive.top_directory")
    if "/" in top or top in (".", ".."):
        raise _invalid("archive.top_directory must be one path component")
    url = _text(archive["url"], "archive.url")
    if url != f"{DOWNLOAD_BASE}{release_tag}/{top}.tar.xz":
        raise _invalid("archive.url must be the vendor release asset of release_tag and top_directory")
    files_raw = body["files"]
    if not isinstance(files_raw, dict) or set(files_raw) != set(KEPT_MEMBERS):
        raise _invalid(f"files must name exactly {', '.join(KEPT_MEMBERS)}")
    records = []
    for path in KEPT_MEMBERS:
        entry = _exact_keys(files_raw[path], ("size", "sha256", "mode"), f"files[{path}]")
        mode = _text(entry["mode"], f"files[{path}].mode")
        if not _MODE.match(mode):
            raise _invalid(f"files[{path}].mode must be an octal mode such as 0755")
        wanted = 0o755 if path.startswith("bin/") else 0o644
        if int(mode, 8) != wanted:
            raise _invalid(f"files[{path}].mode must be {wanted:04o}")
        records.append(
            FileRecord(path, _positive_int(entry["size"], f"files[{path}].size"),
                       _sha256(entry["sha256"], f"files[{path}].sha256"), int(mode, 8))
        )
    for key in ("ffmpeg_commit", "recipe_commit"):
        if not _COMMIT.match(_text(sources[key], f"sources.{key}")):
            raise _invalid(f"sources.{key} must be a 40-digit commit id")
    return FFmpegPin(
        platform=platform_key,
        pin_id=pin_id,
        vendor=_text(body["vendor"], "vendor"),
        release_tag=release_tag,
        version=version,
        archive_url=url,
        archive_size=_positive_int(archive["size"], "archive.size"),
        archive_sha256=_sha256(archive["sha256"], "archive.sha256"),
        top_directory=top,
        member_count=_positive_int(archive["member_count"], "archive.member_count"),
        member_bytes=_positive_int(archive["member_bytes"], "archive.member_bytes"),
        files=tuple(records),
        configuration=_text(body["configuration"], "configuration"),
        license=_text(body["license"], "license"),
        ffmpeg_repository=_text(sources["ffmpeg_repository"], "sources.ffmpeg_repository"),
        ffmpeg_commit=sources["ffmpeg_commit"],
        recipe_repository=_text(sources["recipe_repository"], "sources.recipe_repository"),
        recipe_commit=sources["recipe_commit"],
    )


def parse_pin(data: bytes, platform_key: str) -> FFmpegPin:
    """Validate pin-file bytes strictly and return the record of ``platform_key``."""

    if b"\r" in data or not data.endswith(b"\n") or data.startswith(b"\xef\xbb\xbf"):
        raise _invalid("the pin file must be LF-terminated JSON without a byte order mark")
    try:
        document = json.loads(data.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise _invalid(f"the pin file is not ASCII JSON: {type(exc).__name__}") from exc
    top = _exact_keys(document, ("schema", "platforms"), "pin file")
    if top["schema"] != PIN_SCHEMA or not isinstance(top["platforms"], dict):
        raise _invalid("unsupported pin schema")
    if not set(top["platforms"]) <= set(PLATFORMS):
        raise _invalid("the pin file names a platform this slice does not support")
    if platform_key not in top["platforms"]:
        raise FFmpegError("platform_unsupported", f"no FFmpeg pin for platform {platform_key!r}")
    return _parse_platform(platform_key, top["platforms"][platform_key])


def load_pin(platform_key: str = "linux-x86_64", *, path: Optional[Path] = None) -> FFmpegPin:
    """The pin of ``platform_key``; ``FFmpegError`` when it is missing or invalid."""

    pin_path = default_pin_path() if path is None else Path(path)
    try:
        data = pin_path.read_bytes()
    except OSError as exc:
        raise FFmpegError("pin_unavailable", f"cannot read {pin_path.name}: {type(exc).__name__}") from exc
    return parse_pin(data, platform_key)


def published_directory(runtime_root: Path, pin: FFmpegPin) -> Path:
    """``<root>/runtimes/ffmpeg/<pin-id>``."""

    return Path(runtime_root) / "runtimes" / "ffmpeg" / pin.pin_id


def bin_directory(directory: Path) -> Path:
    return Path(directory) / "bin"


def render_notice(pin: FFmpegPin) -> bytes:
    """The Core-written ``NOTICE.txt``: source pointers beside the vendor licence."""

    lines = [
        "STEMwerk managed FFmpeg",
        "",
        "This directory holds an unmodified static build of FFmpeg and ffprobe that",
        "STEMwerk downloaded from the vendor below and verified against the pins in",
        f"{PIN_FILENAME}. LICENSE.txt is the vendor's licence text, unchanged.",
        "",
        f"Build:           {pin.version}",
        f"Pin id:          {pin.pin_id}",
        f"Vendor build:    {pin.vendor}, release {pin.release_tag}",
        f"Archive:         {pin.archive_url}",
        f"Archive size:    {pin.archive_size} bytes",
        f"Archive SHA-256: {pin.archive_sha256}",
        f"Licence:         {pin.license}",
        "",
        "Source",
        f"  FFmpeg:        {pin.ffmpeg_repository} (commit {pin.ffmpeg_commit})",
        f"  Build recipe:  {pin.recipe_repository} (commit {pin.recipe_commit})",
        "",
        "The vendor build links third-party libraries statically. They are named by",
        "the configuration below and by the build recipe; their licence texts are not",
        "part of this directory.",
        "",
        "Build configuration (ffmpeg -version, verbatim)",
        pin.configuration,
        "",
    ]
    return ("\n".join(lines)).encode("ascii")


def installed_records(pin: FFmpegPin) -> Dict[str, FileRecord]:
    """Every file the installed tree must hold, with its expected size and SHA-256."""

    records = {record.path: record for record in pin.files}
    notice = render_notice(pin)
    records[NOTICE_NAME] = FileRecord(NOTICE_NAME, len(notice), hashlib.sha256(notice).hexdigest(), NOTICE_MODE)
    return records


def _binary_flag() -> int:
    return getattr(os, "O_BINARY", 0)


# --- the archive -----------------------------------------------------------


def verify_archive_file(path: Path, pin: FFmpegPin) -> None:
    """Size first, then SHA-256, of the vendor archive. Nothing is opened before both pass."""

    try:
        path_stat = os.lstat(path)
    except FileNotFoundError as exc:
        raise FFmpegError("archive_missing", f"archive {path.name} is missing") from exc
    except OSError as exc:
        raise FFmpegError("archive_unreadable", f"cannot inspect {path.name}: {type(exc).__name__}") from exc
    if not stat.S_ISREG(path_stat.st_mode):
        raise FFmpegError("archive_not_regular", f"archive {path.name} is not a regular file")
    if path_stat.st_size != pin.archive_size:
        raise FFmpegError(
            "archive_size_mismatch",
            f"archive {path.name} has {path_stat.st_size} bytes, expected {pin.archive_size}",
            expected=pin.archive_size,
            observed=path_stat.st_size,
        )
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(_CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        raise FFmpegError("archive_unreadable", f"cannot read {path.name}: {type(exc).__name__}") from exc
    if digest.hexdigest() != pin.archive_sha256:
        raise FFmpegError(
            "archive_sha256_mismatch",
            f"archive {path.name} failed SHA-256 verification",
            expected=pin.archive_sha256,
            observed=digest.hexdigest(),
        )


class _RedirectGuard(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname not in (*DOWNLOAD_HOSTS, *REDIRECT_HOSTS):
            raise urllib.error.URLError(f"redirect to a host outside the allowlist: {parsed.hostname!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _default_opener() -> Callable[..., Any]:
    return urllib.request.build_opener(_RedirectGuard()).open


def _copy_bounded(reader: Any, part: Path, limit: int, name: str) -> None:
    """Write at most ``limit`` bytes; one more byte is a size mismatch, not a partial success."""

    total = 0
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _binary_flag()
    descriptor = os.open(part, flags, 0o600)
    try:
        while True:
            chunk = reader.read(256 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise FFmpegError("archive_size_mismatch", f"{name} is larger than the pinned {limit} bytes")
            view = memoryview(chunk)
            while view:
                view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fetch_archive(
    pin: FFmpegPin,
    directory: Path,
    *,
    source_dir: Optional[Path] = None,
    opener: Optional[Callable[..., Any]] = None,
    timeout: float = 120.0,
) -> Path:
    """Place the verified vendor archive in ``directory`` and return its path.

    ``source_dir`` is a read-only cache (tests, offline runs); a file there is
    copied and then verified exactly like a download. Otherwise the pinned URL
    is fetched over HTTPS, redirects included, from the allowlisted hosts only.
    """

    directory = Path(directory)
    target = directory / pin.archive_name
    part = directory / f"{pin.archive_name}.part"
    try:
        cached = None if source_dir is None else Path(source_dir) / pin.archive_name
        if cached is not None and cached.is_file() and not cached.is_symlink():
            try:
                with open(cached, "rb") as reader:
                    _copy_bounded(reader, part, pin.archive_size, pin.archive_name)
            except OSError as exc:
                raise FFmpegError("archive_copy_failed", f"cannot copy the cached archive: {type(exc).__name__}") from exc
        else:
            parsed = urllib.parse.urlparse(pin.archive_url)
            if parsed.scheme != "https" or parsed.hostname not in DOWNLOAD_HOSTS:
                raise FFmpegError("download_host_forbidden", f"refusing to download from {parsed.hostname!r}")
            request = urllib.request.Request(pin.archive_url, headers={"User-Agent": "STEMwerk-Core-Installer/2.4"})
            try:
                with (opener or _default_opener())(request, timeout=timeout) as response:
                    length = response.headers.get("Content-Length") if hasattr(response, "headers") else None
                    if length is not None and length.isdigit() and int(length) != pin.archive_size:
                        raise FFmpegError(
                            "archive_size_mismatch",
                            f"the server announced {length} bytes, expected {pin.archive_size}",
                        )
                    _copy_bounded(response, part, pin.archive_size, pin.archive_name)
            except FFmpegError:
                raise
            except (OSError, urllib.error.URLError, ValueError) as exc:
                raise FFmpegError(
                    "download_failed", f"download of {pin.archive_name} failed: {type(exc).__name__}"
                ) from exc
        verify_archive_file(part, pin)
        os.replace(part, target)
        return target
    except BaseException:
        try:
            part.unlink()
        except OSError:
            pass
        raise


def _member_path(name: Any, top: str) -> str:
    """The path of a tar member below the top directory ('' for the directory itself)."""

    if not isinstance(name, str) or not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise FFmpegError("archive_unsafe_member", "an archive member has an unsafe name")
    parts = name[:-1].split("/") if name.endswith("/") else name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise FFmpegError("archive_unsafe_member", "an archive member path has an empty, '.' or '..' component")
    if parts[0] != top:
        raise FFmpegError("archive_unsafe_member", "an archive member lies outside the pinned top directory")
    return "/".join(parts[1:])


def _write_file(path: Path, source: Any, record: FileRecord) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _binary_flag()
    descriptor = os.open(path, flags, 0o600)
    digest = hashlib.sha256()
    total = 0
    try:
        while True:
            chunk = source.read(_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > record.size:
                raise FFmpegError("extracted_file_mismatch", f"{record.path} is larger than its pinned size")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if total != record.size or digest.hexdigest() != record.sha256:
        raise FFmpegError(
            "extracted_file_mismatch",
            f"{record.path} differs from its pin",
            expected_sha256=record.sha256,
            observed_sha256=digest.hexdigest(),
        )
    os.chmod(path, record.mode)


def write_notice(directory: Path, pin: FFmpegPin) -> None:
    record = installed_records(pin)[NOTICE_NAME]
    notice = render_notice(pin)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _binary_flag()  # binary: the bytes are hashed
    descriptor = os.open(Path(directory) / NOTICE_NAME, flags, 0o600)
    try:
        view = memoryview(notice)
        while view:
            view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(Path(directory) / NOTICE_NAME, record.mode)


def extract_archive(archive: Path, stage: Path, pin: FFmpegPin) -> None:
    """Stream the vendor archive into the empty directory ``stage``.

    The archive's size and SHA-256 are verified before it is opened. The whole
    archive is refused when ANY member is a link, device, FIFO, sparse file, has
    an absolute or ``..`` path, repeats a name, lies outside the pinned top
    directory, or when the member count or total size differs from the pin, even
    for members that would be ignored. Only the three kept members are written,
    each with its pinned size, SHA-256 and an explicit mode; ``NOTICE.txt`` is
    written by Core. A refusal removes whatever was written.
    """

    stage = Path(stage)
    verify_archive_file(Path(archive), pin)
    if not stage.is_dir() or any(stage.iterdir()):
        raise FFmpegError("stage_not_empty", f"{stage} must be an empty directory")
    try:
        _extract_verified(Path(archive), stage, pin)
    except BaseException:
        for entry in list(stage.iterdir()):
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry, ignore_errors=True)
            else:
                try:
                    entry.unlink()
                except OSError:
                    pass
        raise


def _extract_verified(archive: Path, stage: Path, pin: FFmpegPin) -> None:
    import lzma  # not imported at module level: the check is only needed here

    kept = {record.path: record for record in pin.files}
    seen_names = set()
    written = set()
    count = 0
    total = 0
    try:
        with tarfile.open(archive, "r|xz") as tar:
            for member in tar:
                count += 1
                if count > pin.member_count:
                    raise FFmpegError("archive_layout_mismatch", "the archive has more members than its pin")
                relative = _member_path(member.name, pin.top_directory)
                if relative in seen_names:
                    raise FFmpegError("archive_unsafe_member", "an archive member name is repeated")
                seen_names.add(relative)
                if member.isdir():
                    continue
                if not member.isreg() or member.issparse():
                    raise FFmpegError("archive_unsafe_member", "an archive member is not a plain file or directory")
                total += member.size
                if total > pin.member_bytes:
                    raise FFmpegError("archive_layout_mismatch", "the archive holds more data than its pin")
                record = kept.get(relative)
                if record is None:
                    continue
                if member.size != record.size:
                    raise FFmpegError("extracted_file_mismatch", f"{relative} has an unexpected size")
                destination = stage.joinpath(*relative.split("/"))
                if len(relative.split("/")) > 1 and not destination.parent.is_dir():
                    os.mkdir(destination.parent, 0o700)
                    os.chmod(destination.parent, DIRECTORY_MODE)
                source = tar.extractfile(member)
                if source is None:
                    raise FFmpegError("archive_unsafe_member", "a kept member has no data")
                _write_file(destination, source, record)
                written.add(relative)
    except (tarfile.TarError, lzma.LZMAError, EOFError) as exc:
        raise FFmpegError("archive_unreadable", f"the archive cannot be read: {type(exc).__name__}") from exc
    except OSError as exc:  # for example no space left on the device
        raise FFmpegError("extract_failed", f"the archive cannot be extracted: {type(exc).__name__}") from exc
    if count != pin.member_count or total != pin.member_bytes:
        raise FFmpegError("archive_layout_mismatch", "the archive differs from its pinned layout")
    if written != set(kept):
        raise FFmpegError("archive_member_missing", "the archive lacks a pinned member")
    write_notice(stage, pin)
    os.chmod(stage, DIRECTORY_MODE)


# --- the installed tree ----------------------------------------------------


@dataclass(frozen=True)
class TreeReport:
    """Result of comparing a directory with the pin. ``reason`` is ``verified`` or a code."""

    reason: str
    problems: Tuple[Mapping[str, Any], ...]
    files: Mapping[str, Mapping[str, Any]]
    tree_sha256: str
    entry_count: int
    total_bytes: int

    @property
    def ok(self) -> bool:
        return self.reason == "verified"


def _tree_digest(pin: FFmpegPin, records: Mapping[str, FileRecord]) -> str:
    digest = hashlib.sha256()
    digest.update(f"stemwerk-ffmpeg-tree/1\0{pin.pin_id}\n".encode("ascii"))
    for directory in ("",) + INSTALLED_DIRECTORIES:
        digest.update(f"D\0{directory}\0{DIRECTORY_MODE:04o}\n".encode("ascii"))
    for path in sorted(records):
        record = records[path]
        digest.update(f"F\0{path}\0{record.mode:04o}\0{record.size}\0{record.sha256}\n".encode("ascii"))
    return digest.hexdigest()


def expected_tree_sha256(pin: FFmpegPin) -> str:
    return _tree_digest(pin, installed_records(pin))


def _hash_regular_file(path: Path, expected_size: int) -> Tuple[str, int]:
    flags = os.O_RDONLY | _binary_flag() | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise FFmpegError("ffmpeg_not_regular_file", f"{path.name} is not a regular file")
        if opened.st_size != expected_size:
            return "", opened.st_size  # a wrong-sized file is never hashed
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, _CHUNK)
            if not chunk:
                break
            digest.update(chunk)
        return digest.hexdigest(), opened.st_size
    finally:
        os.close(descriptor)


def inspect_tree(directory: Path, pin: FFmpegPin) -> TreeReport:
    """Compare ``directory`` with the pin: exact entries, kinds, modes, sizes, SHA-256.

    Never follows links. ``FFmpegError('tree_unreadable')`` when something cannot
    be read (the caller reports that as unverifiable, never as passing).
    """

    directory = Path(directory)
    expected = installed_records(pin)
    problems: List[Dict[str, Any]] = []
    observed: Dict[str, Dict[str, Any]] = {}
    check_modes = os.name == "posix"

    def problem(code: str, path: str, **extra: Any) -> None:
        problems.append({"code": code, "path": path, **extra})

    try:
        root_stat = os.lstat(directory)
    except FileNotFoundError:
        return TreeReport("location_missing", ({"code": "location_missing", "path": ""},), {}, "", 0, 0)
    except OSError as exc:
        raise FFmpegError("tree_unreadable", f"cannot inspect the FFmpeg directory: {type(exc).__name__}") from exc
    if not stat.S_ISDIR(root_stat.st_mode):
        return TreeReport("location_not_directory", ({"code": "location_not_directory", "path": ""},), {}, "", 0, 0)

    try:
        names = {"": sorted(os.listdir(directory))}
        if "bin" in names[""] and stat.S_ISDIR(os.lstat(directory / "bin").st_mode):
            names["bin"] = sorted(os.listdir(directory / "bin"))
    except OSError as exc:
        raise FFmpegError("tree_unreadable", f"cannot list the FFmpeg directory: {type(exc).__name__}") from exc

    allowed_top = {"bin", LICENSE_NAME, NOTICE_NAME}
    for name in names[""]:
        if name not in allowed_top:
            problem("ffmpeg_unexpected_entry", name)
    for name in names.get("bin", ()):
        if f"bin/{name}" not in expected:
            problem("ffmpeg_unexpected_entry", f"bin/{name}")

    for relative, directory_path in (("", directory), ("bin", directory / "bin")):
        try:
            dir_stat = os.lstat(directory_path)
        except FileNotFoundError:
            problem("ffmpeg_file_missing", relative or ".")
            continue
        except OSError as exc:
            raise FFmpegError("tree_unreadable", f"cannot inspect {relative or '.'}: {type(exc).__name__}") from exc
        if not stat.S_ISDIR(dir_stat.st_mode):
            problem("ffmpeg_not_regular_file", relative or ".")
        elif check_modes and stat.S_IMODE(dir_stat.st_mode) != DIRECTORY_MODE:
            problem("ffmpeg_mode_mismatch", relative or ".", expected=f"{DIRECTORY_MODE:04o}",
                    observed=f"{stat.S_IMODE(dir_stat.st_mode):04o}")

    for relative in sorted(expected):
        record = expected[relative]
        path = directory.joinpath(*relative.split("/"))
        try:
            file_stat = os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            problem("ffmpeg_file_missing", relative)
            continue
        except OSError as exc:
            raise FFmpegError("tree_unreadable", f"cannot inspect {relative}: {type(exc).__name__}") from exc
        if not stat.S_ISREG(file_stat.st_mode):
            problem("ffmpeg_not_regular_file", relative)
            continue
        if check_modes and stat.S_IMODE(file_stat.st_mode) != record.mode:
            problem("ffmpeg_mode_mismatch", relative, expected=f"{record.mode:04o}",
                    observed=f"{stat.S_IMODE(file_stat.st_mode):04o}")
        try:
            sha256, size = _hash_regular_file(path, record.size)
        except FFmpegError as exc:
            problem(exc.code, relative)
            continue
        except OSError as exc:
            raise FFmpegError("tree_unreadable", f"cannot read {relative}: {type(exc).__name__}") from exc
        observed[relative] = {"size_bytes": size, "sha256": sha256, "mode": f"{record.mode:04o}"}
        if size != record.size:
            problem("ffmpeg_file_size_mismatch", relative, expected=record.size, observed=size)
        elif sha256 != record.sha256:
            problem("ffmpeg_file_hash_mismatch", relative, expected=record.sha256, observed=sha256)

    if problems:
        return TreeReport(problems[0]["code"], tuple(problems), observed, "", len(observed) + 2,
                          sum(v["size_bytes"] for v in observed.values()))
    return TreeReport(
        "verified", (), observed, _tree_digest(pin, expected), len(expected) + 2,
        sum(record.size for record in expected.values()),
    )


def matches_pin(directory: Path, pin: FFmpegPin) -> bool:
    """True only when ``directory`` is exactly the pinned tree."""

    try:
        return inspect_tree(directory, pin).ok
    except (FFmpegError, OSError):
        return False


def stage_pair(
    pin: FFmpegPin,
    download_dir: Path,
    stage: Path,
    *,
    source_dir: Optional[Path] = None,
    opener: Optional[Callable[..., Any]] = None,
) -> TreeReport:
    """Fetch, verify and extract the pair into ``stage``; the archive is removed.

    Returns the report of the staged tree, which must be ``ok``.
    """

    archive = fetch_archive(pin, Path(download_dir), source_dir=source_dir, opener=opener)
    try:
        extract_archive(archive, Path(stage), pin)
    finally:
        try:
            archive.unlink()
        except OSError:
            pass
    report = inspect_tree(Path(stage), pin)
    if not report.ok:
        raise FFmpegError("extracted_file_mismatch", f"the staged tree differs from its pin: {report.reason}",
                          problems=list(report.problems))
    return report


def receipt_entry(
    runtime_root: Path, directory: Path, pin: FFmpegPin, report: TreeReport, ownership: str
) -> Dict[str, Any]:
    """The ``components.ffmpeg`` receipt entry for a verified tree."""

    if not report.ok:
        raise FFmpegError("receipt_refused", "a receipt is only written for a verified tree")
    return {
        "path": str(directory),
        "relpath": Path(directory).relative_to(runtime_root).as_posix(),
        "pin_id": pin.pin_id,
        "platform_key": pin.platform,
        "version": pin.version,
        "release_tag": pin.release_tag,
        "vendor": pin.vendor,
        "archive": {"url": pin.archive_url, "size_bytes": pin.archive_size, "sha256": pin.archive_sha256},
        "files": {path: dict(report.files[path]) for path in sorted(report.files)},
        "tree_sha256": report.tree_sha256,
        "entry_count": report.entry_count,
        "total_bytes": report.total_bytes,
        "configuration_sha256": hashlib.sha256(pin.configuration.encode("ascii")).hexdigest(),
        "license": pin.license,
        "sources": {
            "ffmpeg_repository": pin.ffmpeg_repository,
            "ffmpeg_commit": pin.ffmpeg_commit,
            "recipe_repository": pin.recipe_repository,
            "recipe_commit": pin.recipe_commit,
        },
        "ownership": ownership,
    }


def receipt_matches_report(entry: Mapping[str, Any], pin: FFmpegPin, report: TreeReport) -> Optional[str]:
    """``None`` when the receipt agrees with the pin and the observed tree, else a reason code."""

    archive = entry.get("archive")
    if (
        entry.get("pin_id") != pin.pin_id
        or not isinstance(archive, Mapping)
        or archive.get("sha256") != pin.archive_sha256
        or archive.get("size_bytes") != pin.archive_size
    ):
        return "ffmpeg_pin_mismatch"
    recorded = entry.get("files")
    if not isinstance(recorded, Mapping) or set(recorded) != set(INSTALLED_FILES):
        return "ffmpeg_receipt_mismatch"
    for path in INSTALLED_FILES:
        item = recorded.get(path)
        seen = report.files.get(path)
        if (
            not isinstance(item, Mapping)
            or seen is None
            or item.get("sha256") != seen.get("sha256")
            or item.get("size_bytes") != seen.get("size_bytes")
        ):
            return "ffmpeg_receipt_mismatch"
    if entry.get("tree_sha256") != report.tree_sha256:
        return "ffmpeg_receipt_mismatch"
    return None


# --- the probe -------------------------------------------------------------


def _probe_audio(width: int) -> bytes:
    rng = random.Random(PROBE_SEED + width)
    out = bytearray()
    frames = PROBE_RATE * PROBE_SECONDS
    if width == 2:
        for i in range(frames):
            left = int(9000 * math.sin(2 * math.pi * 220 * i / PROBE_RATE)) + rng.randint(-600, 600)
            right = int(7000 * math.sin(2 * math.pi * 330 * i / PROBE_RATE)) + rng.randint(-600, 600)
            out += struct.pack("<hh", max(-32768, min(32767, left)), max(-32768, min(32767, right)))
    else:
        for i in range(frames):
            for frequency in (220, 330):
                value = int(3_000_000 * math.sin(2 * math.pi * frequency * i / PROBE_RATE)) + rng.randint(-40_000, 40_000)
                out += struct.pack("<i", value << 8)[1:]
    return bytes(out)


def _read_pcm(path: Path) -> Tuple[int, int, int, bytes]:
    """``(channels, bytes per sample, rate, PCM bytes)`` of a RIFF/WAVE file.

    Written by hand because the standard ``wave`` module refuses WAVE_FORMAT_EXTENSIBLE
    before Python 3.12, and FFmpeg writes that header for 24-bit audio. Core may run
    under any supported interpreter, not only the managed 3.12.
    """

    blob = Path(path).read_bytes()
    if blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    layout = None
    payload = None
    position = 12
    while position + 8 <= len(blob):
        chunk_id = blob[position:position + 4]
        (size,) = struct.unpack_from("<I", blob, position + 4)
        body = blob[position + 8:position + 8 + size]
        if len(body) != size:
            raise ValueError("truncated chunk")
        if chunk_id == b"fmt " and size >= 16:
            tag, channels, rate, _byte_rate, _align, bits = struct.unpack_from("<HHIIHH", body)
            if tag == 0xFFFE and size >= 26:  # extensible: the sub-format GUID starts with the real tag
                (tag,) = struct.unpack_from("<H", body, 24)
            if tag != 1 or bits % 8:
                raise ValueError(f"not integer PCM (format tag {tag}, {bits} bits)")
            layout = (channels, bits // 8, rate)
        elif chunk_id == b"data":
            payload = body
        position += 8 + size + (size & 1)
    if layout is None or payload is None:
        raise ValueError("no fmt or data chunk")
    return layout[0], layout[1], layout[2], payload


def _inside(path: Path, parent: Path) -> bool:
    try:
        Path(os.path.realpath(path)).relative_to(Path(os.path.realpath(parent)))
        return True
    except ValueError:
        return False


def probe_pair(
    directory: Path,
    pin: FFmpegPin,
    *,
    scratch_parent: Optional[Path] = None,
    run: Callable[..., Any] = subprocess.run,
) -> Dict[str, Any]:
    """Run the installed pair: versions, build flags and lossless WAV-FLAC-WAV round trips.

    16- and 24-bit deterministic stereo, 2 s; the decoded PCM must be
    bit-exact. Every command is limited to 30 s and the probe to 60 s. The
    scratch directory is private and never inside the runtime tree. The
    environment is minimal and explicit; nothing is inherited from the user.
    """

    bin_dir = bin_directory(directory)
    ffmpeg, ffprobe = bin_dir / "ffmpeg", bin_dir / "ffprobe"
    parent = Path(tempfile.gettempdir() if scratch_parent is None else scratch_parent)
    if _inside(parent, directory):
        raise FFmpegError("probe_scratch_unsafe", "the probe scratch directory is inside the FFmpeg tree")
    deadline = time.monotonic() + PROBE_TOTAL_TIMEOUT_SECONDS
    started = time.monotonic()
    timings: Dict[str, float] = {}

    with tempfile.TemporaryDirectory(prefix="stemwerk-ffmpeg-probe-", dir=str(parent)) as scratch_name:
        scratch = Path(scratch_name)
        env = {"PATH": str(bin_dir), "LC_ALL": "C", "TMPDIR": str(scratch)}

        def execute(label: str, command: List[str]) -> Any:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise FFmpegError("probe_timeout", f"the probe exceeded {PROBE_TOTAL_TIMEOUT_SECONDS} s before {label}")
            begun = time.monotonic()
            try:
                completed = run(
                    command, env=env, cwd=str(scratch), capture_output=True, text=True,
                    timeout=min(PROBE_COMMAND_TIMEOUT_SECONDS, remaining), check=False,
                )
            except subprocess.TimeoutExpired as exc:
                raise FFmpegError("probe_timeout", f"{label} did not finish in time") from exc
            except (OSError, ValueError) as exc:
                raise FFmpegError("probe_spawn_failed", f"{label} could not run: {type(exc).__name__}") from exc
            timings[label] = round(time.monotonic() - begun, 3)
            if completed.returncode != 0:  # includes death by signal (negative)
                raise FFmpegError(
                    "probe_command_failed", f"{label} exited with {completed.returncode}",
                    returncode=completed.returncode, stderr=(completed.stderr or "")[-300:],
                )
            return completed

        for tool, path in (("ffmpeg", ffmpeg), ("ffprobe", ffprobe)):
            banner = execute(f"{tool}_version", [str(path), "-version"]).stdout.splitlines()
            if not banner or not banner[0].startswith(f"{tool} version {pin.version} "):
                raise FFmpegError("probe_version_mismatch", f"{tool} does not report the pinned build {pin.version}")
            if tool == "ffmpeg":
                configuration = next((line for line in banner if line.startswith("configuration:")), "")
                if configuration != f"configuration: {pin.configuration}":
                    raise FFmpegError("probe_version_mismatch", "ffmpeg reports a different build configuration")
                if "--enable-gpl" in configuration.split() or "--enable-nonfree" in configuration.split():
                    raise FFmpegError("probe_license_flags", "ffmpeg was built with --enable-gpl or --enable-nonfree")

        quiet = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        for label, width, codec in (("s16", 2, "pcm_s16le"), ("s24", 3, "pcm_s24le")):
            frames = _probe_audio(width)
            source = scratch / f"{label}.wav"
            with wave.open(str(source), "wb") as writer:
                writer.setnchannels(2)
                writer.setsampwidth(width)
                writer.setframerate(PROBE_RATE)
                writer.writeframes(frames)
            flac, decoded, copied = scratch / f"{label}.flac", scratch / f"{label}-back.wav", scratch / f"{label}-copy.wav"
            execute(f"{label}_encode", [str(ffmpeg), *quiet, "-i", str(source), "-c:a", "flac", str(flac)])
            execute(f"{label}_decode", [str(ffmpeg), *quiet, "-i", str(flac), "-c:a", codec, str(decoded)])
            execute(f"{label}_copy", [str(ffmpeg), *quiet, "-i", str(source), "-c:a", codec, str(copied)])
            described = execute(
                f"{label}_ffprobe",
                [str(ffprobe), "-v", "error", "-show_entries",
                 "stream=codec_name,sample_rate,channels:format=format_name", "-of", "json", str(flac)],
            )
            try:
                info = json.loads(described.stdout)
                stream = info["streams"][0]
                container = info["format"]["format_name"]
            except (ValueError, KeyError, IndexError, TypeError) as exc:
                raise FFmpegError("probe_ffprobe_mismatch", "ffprobe did not describe the FLAC file") from exc
            if (stream.get("codec_name"), str(stream.get("sample_rate")), stream.get("channels"), container) != (
                "flac", str(PROBE_RATE), 2, "flac"
            ):
                raise FFmpegError("probe_ffprobe_mismatch", "ffprobe describes the FLAC file differently")
            for output in (decoded, copied):
                try:
                    shape = _read_pcm(output)
                except (OSError, ValueError, struct.error) as exc:
                    raise FFmpegError("probe_roundtrip_mismatch", f"{output.name} is not a readable WAV file") from exc
                if shape != (2, width, PROBE_RATE, frames):
                    raise FFmpegError("probe_roundtrip_mismatch", f"{output.name} is not bit-exact")
    return {"timings": timings, "total_seconds": round(time.monotonic() - started, 3),
            "cases": ["s16", "s24"], "limits": {"command_seconds": PROBE_COMMAND_TIMEOUT_SECONDS,
                                                  "total_seconds": PROBE_TOTAL_TIMEOUT_SECONDS}}


# --- how a process is pointed at the pair ----------------------------------


def pair_environment(env: Mapping[str, str], directory: Path) -> Dict[str, str]:
    """``env`` with the verified pair named explicitly and ahead of everything on ``PATH``.

    User overrides of the pair are replaced, not kept. The user's own ``PATH``
    entries stay behind ours, so unrelated tools still resolve.
    """

    bin_dir = str(bin_directory(directory))
    result = dict(env)
    for name in FFMPEG_ENV_VARS:
        result[name] = str(Path(bin_dir) / "ffmpeg")
    for name in FFPROBE_ENV_VARS:
        result[name] = str(Path(bin_dir) / "ffprobe")
    others = [part for part in (result.get("PATH") or "").split(os.pathsep) if part and part != bin_dir]
    result["PATH"] = os.pathsep.join([bin_dir, *others])
    return result
