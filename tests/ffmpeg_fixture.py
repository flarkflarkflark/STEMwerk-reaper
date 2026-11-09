"""A synthetic FFmpeg pair for the Core tests: a vendor-shaped archive, its pin, and
stand-in ``ffmpeg``/``ffprobe`` programs.

The stand-ins are small Python scripts. Their "FLAC" is the WAV bytes behind a
marker, so the real probe's WAV-FLAC-WAV round trip is exact without a codec.
``mode`` selects a defect: ``lossy`` (the decode flips a bit), ``nocodec`` (the
encoder is missing), ``crash`` (the program dies by SIGSEGV), ``badprobe`` (ffprobe
describes the FLAC file as MP3), ``badcopy`` (a WAV-to-WAV copy is not exact).
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
from typing import Dict, Mapping, Optional

from stemwerk_core import managed_ffmpeg

TAG = "autobuild-2026-01-01-00-00"
VERSION = "n0.0-test-20260101"
TOP = "ffmpeg-n0.0-test-linux64-lgpl-0.0"
CONFIGURATION = "--prefix=/test --enable-version3 --disable-debug"
COMMIT = "0123456789abcdef0123456789abcdef01234567"

_TOOL = '''#!@@PYTHON@@
import json, os, signal, sys
MODE = "@@MODE@@"
TOOL = "@@TOOL@@"
args = sys.argv[1:]
if "-version" in args:
    print(TOOL + " version @@VERSION@@ Copyright (c) test")
    print("built with a fake compiler")
    print("configuration: @@CONFIGURATION@@")
    sys.exit(0)
if MODE == "crash":
    os.kill(os.getpid(), signal.SIGSEGV)
if TOOL == "ffprobe":
    print(json.dumps({"streams": [{"codec_name": "mp3" if MODE == "badprobe" else "flac", "sample_rate": "44100", "channels": 2}],
                      "format": {"format_name": "flac"}}))
    sys.exit(0)
source = args[args.index("-i") + 1]
codec = args[args.index("-c:a") + 1]
target = args[-1]
data = open(source, "rb").read()
if codec == "flac":
    if MODE == "nocodec":
        sys.stderr.write("Unknown encoder 'flac'\\n")
        sys.exit(1)
    open(target, "wb").write(b"FAKEFLAC\\n" + data)
else:
    was_flac = data.startswith(b"FAKEFLAC\\n")
    if was_flac:
        data = data[9:]
    if MODE == "lossy" and codec == "pcm_s16le":
        data = data[:-1] + bytes([data[-1] ^ 1])
    if MODE == "badcopy" and not was_flac:
        data = data[:-1] + bytes([data[-1] ^ 1])
    open(target, "wb").write(data)
'''


def tool_script(tool: str, mode: str = "ok", *, version: str = VERSION, configuration: str = CONFIGURATION) -> bytes:
    text = (
        _TOOL.replace("@@PYTHON@@", sys.executable)
        .replace("@@MODE@@", mode)
        .replace("@@TOOL@@", tool)
        .replace("@@VERSION@@", version)
        .replace("@@CONFIGURATION@@", configuration)
    )
    return text.encode("ascii")


@dataclass(frozen=True)
class FakePair:
    pin: managed_ffmpeg.FFmpegPin
    cache_dir: Path  # holds the archive under its pinned name
    archive: Path
    members: Mapping[str, bytes]  # the kept members' bytes


def _add(tar: tarfile.TarFile, name: str, data: Optional[bytes] = None, *, mode: int = 0o644) -> None:
    info = tarfile.TarInfo(name)
    info.mtime = 0
    info.mode = mode
    if data is None:
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        tar.addfile(info)
    else:
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))


def archive_bytes(entries: list[tuple[str, Optional[bytes], int, Optional[tuple[bytes, str]]]]) -> bytes:
    """A tar.xz of ``(name, data, mode, special)``; ``special`` is ``(type, linkname)`` for links etc."""

    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:xz") as tar:
        for name, data, mode, special in entries:
            if special is not None:
                info = tarfile.TarInfo(name)
                info.type, info.linkname = special
                tar.addfile(info)
            else:
                _add(tar, name, data, mode=mode)
    return buffer.getvalue()


def vendor_entries(members: Mapping[str, bytes], extra: Optional[list] = None) -> list:
    entries: list = [(TOP, None, 0o755, None), (f"{TOP}/bin", None, 0o755, None)]
    entries += [(f"{TOP}/bin/ffplay", b"ffplay is never installed", 0o755, None)]
    entries += [(f"{TOP}/{path}", data, 0o755 if path.startswith("bin/") else 0o644, None)
                for path, data in members.items()]
    entries += [(f"{TOP}/doc", None, 0o755, None), (f"{TOP}/doc/readme.txt", b"docs are never installed", 0o644, None)]
    return entries + list(extra or [])


def pin_for(archive: bytes, members: Mapping[str, bytes], entries: list, *, name: str = f"{TOP}.tar.xz") -> managed_ffmpeg.FFmpegPin:
    regular = [data for _name, data, _mode, special in entries if special is None and data is not None]
    document = {
        "schema": managed_ffmpeg.PIN_SCHEMA,
        "platforms": {"linux-x86_64": {
            "pin_id": "test-n0.0-test-20260101-linux64-lgpl",
            "vendor": "Test/Builds",
            "release_tag": TAG,
            "version": VERSION,
            "archive": {
                "url": f"{managed_ffmpeg.DOWNLOAD_BASE}{TAG}/{name}",
                "size": len(archive),
                "sha256": hashlib.sha256(archive).hexdigest(),
                "top_directory": TOP,
                "member_count": len(entries),
                "member_bytes": sum(len(data) for data in regular),
            },
            "files": {
                path: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                       "mode": "0755" if path.startswith("bin/") else "0644"}
                for path, data in members.items()
            },
            "configuration": CONFIGURATION,
            "license": "LGPL test",
            "sources": {"ffmpeg_repository": "https://example.invalid/ffmpeg", "ffmpeg_commit": COMMIT,
                        "recipe_repository": "https://example.invalid/recipe", "recipe_commit": COMMIT},
        }},
    }
    data = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("ascii")
    return managed_ffmpeg.parse_pin(data, "linux-x86_64")


def build_pair(directory: Path, mode: str = "ok") -> FakePair:
    members: Dict[str, bytes] = {
        "bin/ffmpeg": tool_script("ffmpeg", mode),
        "bin/ffprobe": tool_script("ffprobe", mode),
        "LICENSE.txt": b"The vendor licence text, unchanged.\n",
    }
    entries = vendor_entries(members)
    archive = archive_bytes(entries)
    pin = pin_for(archive, members, entries)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / pin.archive_name
    path.write_bytes(archive)
    return FakePair(pin, directory, path, members)


def stub_probe(monkeypatch, calls: Optional[list] = None) -> None:
    """For tests that must run on every OS: the stand-ins cannot run on Windows."""

    def probe(directory, pin, **_kwargs):
        if calls is not None:
            calls.append(Path(directory))
        return {"timings": {}, "total_seconds": 0.0, "cases": ["s16", "s24"], "limits": {}}

    monkeypatch.setattr(managed_ffmpeg, "probe_pair", probe)
