"""Tests for the S7 Linux managed FFmpeg slice (pinned pair, archive safety, probe,
install, verify, recovery, worker contract, scheduled pin check)."""

from __future__ import annotations

import dataclasses
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import (  # noqa: E402
    install_journal,
    install_preflight,
    managed_ffmpeg,
    managed_runtime,
    module_installer,
    module_registry,
    module_verify,
    readiness,
    readiness_collect,
    runtime_manifest,
)
from stemwerk_core.readiness import ReadinessRequest  # noqa: E402
from stemwerk_core.verdicts import FAIL, PASS  # noqa: E402
from tests import ffmpeg_fixture  # noqa: E402
from tests.test_core_s6_linux_install import _prepare_fake_install  # noqa: E402

pytestmark = pytest.mark.portable
POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="the stand-in programs and POSIX modes")
REAL_PROBE = managed_ffmpeg.probe_pair  # before any fixture stubs it
REAL_RUN = subprocess.run  # the S6 fixture replaces subprocess.run for the installer
REAL_ARCHIVE_ENV = "STEMWERK_TEST_FFMPEG_ARCHIVE"
PIN_PATH = CORE_SRC / "stemwerk_core" / managed_ffmpeg.PIN_FILENAME


# --- 1. The pin file -------------------------------------------------------


def _pin_document() -> dict:
    return json.loads(PIN_PATH.read_bytes())


def _parse(document, platform="linux-x86_64"):
    return managed_ffmpeg.parse_pin((json.dumps(document, indent=2, sort_keys=True) + "\n").encode("ascii"), platform)


@pytest.mark.native_publication
def test_shipped_pin_is_the_owner_decided_btbn_build_and_matches_preflight_constants():
    pin = managed_ffmpeg.load_pin()
    assert pin.release_tag == "autobuild-2026-10-31-12-59"
    assert pin.version == "n9.0.2-39-g7adfbe40dc-20261031"
    assert pin.archive_url == (
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-31-12-59/"
        "ffmpeg-n9.0.2-39-g7adfbe40dc-linux64-lgpl-9.0.tar.xz"
    )
    assert (pin.archive_size, pin.archive_sha256) == (
        136_027_168, "6046d6731b26f58887e953561551d254a6eec9fbca4100dfeab56e19af8328d5"
    )
    assert pin.ffmpeg_commit == "7adfbe40dcde598f93a6963d2f7b22cd75202ccc"
    assert pin.recipe_commit == "5031c6f1082414e53688d39e521849905071070d"
    assert "--enable-gpl" not in pin.configuration.split() and "--enable-nonfree" not in pin.configuration.split()
    # The preflight space table is measured from this pin; they must not drift apart.
    sizes = {record.path: record.size for record in pin.files}
    assert install_preflight.FFMPEG_ARCHIVE_BYTES["linux-x86_64"] == pin.archive_size
    assert install_preflight.LINUX_FFMPEG_PAIR_BYTES == sizes["bin/ffmpeg"] + sizes["bin/ffprobe"]
    installed = managed_ffmpeg.installed_records(pin)
    assert install_preflight.LINUX_FFMPEG_INSTALLED_LOGICAL_BYTES == sum(r.size for r in installed.values())
    storage = install_preflight.OBSERVED_S6_LINUX_CPU_STORAGE
    assert storage["s7_ffmpeg_archive_bytes"] == pin.archive_size


def test_preflight_strings_cite_the_measured_allocated_bytes_not_the_calculation(tmp_path):
    facts = install_preflight.HostFacts("linux-x86_64", "6.6.0", "2.39", 20 * install_preflight.GIB, None)
    measured = f"{install_preflight.LINUX_FFMPEG_INSTALLED_ALLOCATED_BYTES:,}"
    plan = install_preflight.plan("drum_kit", root=tmp_path / "root", facts=facts)
    assert measured in plan["space"]["estimate_provenance"]["ffmpeg_static_pair_bytes"]
    assert measured in plan["space"]["storage"]["final"]["coexistence"]
    assert "280,768,512" not in json.dumps(plan)  # the superseded 4 KiB-block calculation


@pytest.mark.native_publication
def test_pin_is_core_only_and_the_shared_runtime_manifest_stays_python_only():
    manifest = (CORE_SRC / "stemwerk_core" / runtime_manifest.MANIFEST_FILENAME).read_text(encoding="ascii")
    assert "ffmpeg" not in manifest.lower()
    assert runtime_manifest.COMPONENTS == ("python",)
    assert managed_ffmpeg.PIN_FILENAME != runtime_manifest.MANIFEST_FILENAME
    data = PIN_PATH.read_bytes()
    assert b"\r" not in data and data.endswith(b"\n") and data.isascii()
    attributes = (ROOT / ".gitattributes").read_bytes().decode("ascii").splitlines()
    assert "scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/ffmpeg-pin.v1.json text eol=lf" in attributes
    assert '"ffmpeg-pin.v1.json"' in (CORE_SRC.parent / "pyproject.toml").read_text(encoding="utf-8")


def _break_url(d):
    d["platforms"]["linux-x86_64"]["archive"]["url"] += "x"


def _break_sha(d):
    d["platforms"]["linux-x86_64"]["files"]["bin/ffmpeg"]["sha256"] = "A" * 64


def _break_mode(d):
    d["platforms"]["linux-x86_64"]["files"]["bin/ffmpeg"]["mode"] = "0777"


def _extra_member(d):
    d["platforms"]["linux-x86_64"]["files"]["bin/ffplay"] = d["platforms"]["linux-x86_64"]["files"]["bin/ffmpeg"]


def _extra_key(d):
    d["platforms"]["linux-x86_64"]["surprise"] = 1


def _zero_size(d):
    d["platforms"]["linux-x86_64"]["archive"]["size"] = 0


def _bad_commit(d):
    d["platforms"]["linux-x86_64"]["sources"]["ffmpeg_commit"] = "main"


def _other_platform(d):
    d["platforms"]["win-x86_64"] = d["platforms"]["linux-x86_64"]


@pytest.mark.native_publication
@pytest.mark.parametrize("damage", [_break_url, _break_sha, _break_mode, _extra_member, _extra_key, _zero_size,
                                    _bad_commit, _other_platform])
def test_pin_loader_refuses_any_deviation_from_the_strict_grammar(damage):
    document = _pin_document()
    damage(document)
    with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
        _parse(document)
    assert refused.value.code == "pin_invalid"


@pytest.mark.native_publication
def test_pin_loader_refuses_crlf_bom_and_unsupported_platforms():
    good = PIN_PATH.read_bytes()
    for data in (good.replace(b"\n", b"\r\n"), b"\xef\xbb\xbf" + good, good.rstrip(b"\n"), b"{not json\n"):
        with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
            managed_ffmpeg.parse_pin(data, "linux-x86_64")
        assert refused.value.code == "pin_invalid"
    with pytest.raises(managed_ffmpeg.FFmpegError) as unsupported:
        managed_ffmpeg.parse_pin(good, "win-x86_64")
    assert unsupported.value.code == "platform_unsupported"
    with pytest.raises(managed_ffmpeg.FFmpegError) as missing:
        managed_ffmpeg.load_pin(path=Path("/nonexistent/ffmpeg-pin.v1.json"))
    assert missing.value.code == "pin_unavailable"


@pytest.mark.native_publication
def test_notice_names_the_source_pointers_and_is_lf_only_ascii():
    pin = managed_ffmpeg.load_pin()
    notice = managed_ffmpeg.render_notice(pin)
    text = notice.decode("ascii")
    assert b"\r" not in notice and notice.endswith(b"\n")
    for pointer in (pin.ffmpeg_commit, pin.recipe_commit, pin.archive_url, pin.archive_sha256,
                    "https://github.com/FFmpeg/FFmpeg", "https://github.com/BtbN/FFmpeg-Builds", pin.configuration):
        assert pointer in text
    assert managed_ffmpeg.render_notice(pin) == notice  # deterministic


# --- 2. Archive: size and hash before open; unsafe members -----------------


def _stage_archive(tmp_path, extra=None, *, members=None, mutate_pin=None):
    members = members or {
        "bin/ffmpeg": ffmpeg_fixture.tool_script("ffmpeg"),
        "bin/ffprobe": ffmpeg_fixture.tool_script("ffprobe"),
        "LICENSE.txt": b"licence\n",
    }
    entries = ffmpeg_fixture.vendor_entries(members, extra)
    archive = ffmpeg_fixture.archive_bytes(entries)
    pin = ffmpeg_fixture.pin_for(archive, members, entries)
    if mutate_pin is not None:
        pin = mutate_pin(pin)
    path = tmp_path / pin.archive_name
    path.write_bytes(archive)
    stage = tmp_path / "stage"
    stage.mkdir(exist_ok=True)
    return path, stage, pin


@pytest.mark.native_publication
def test_a_clean_vendor_shaped_archive_extracts_only_the_kept_members(tmp_path):
    path, stage, pin = _stage_archive(tmp_path)
    managed_ffmpeg.extract_archive(path, stage, pin)
    assert sorted(p.relative_to(stage).as_posix() for p in stage.rglob("*")) == [
        "LICENSE.txt", "NOTICE.txt", "bin", "bin/ffmpeg", "bin/ffprobe"]
    report = managed_ffmpeg.inspect_tree(stage, pin)
    assert report.ok, report.problems
    assert report.tree_sha256 == managed_ffmpeg.expected_tree_sha256(pin)
    assert (stage / "NOTICE.txt").read_bytes() == managed_ffmpeg.render_notice(pin)


@pytest.mark.native_publication
def test_truncated_and_altered_archives_are_refused_before_the_archive_is_opened(tmp_path, monkeypatch):
    path, stage, pin = _stage_archive(tmp_path)
    opened = []
    real_open = tarfile.open
    monkeypatch.setattr(tarfile, "open", lambda *a, **k: opened.append(a) or real_open(*a, **k))
    original = path.read_bytes()

    path.write_bytes(original[:-1])  # truncated
    with pytest.raises(managed_ffmpeg.FFmpegError) as short:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert short.value.code == "archive_size_mismatch"

    path.write_bytes(original + b"\0")  # grown
    with pytest.raises(managed_ffmpeg.FFmpegError) as grown:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert grown.value.code == "archive_size_mismatch"

    path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))  # same size, one bit
    with pytest.raises(managed_ffmpeg.FFmpegError) as altered:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert altered.value.code == "archive_sha256_mismatch"

    path.unlink()
    with pytest.raises(managed_ffmpeg.FFmpegError) as missing:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert missing.value.code == "archive_missing"
    assert not opened and not list(stage.iterdir())


@pytest.mark.native_publication
def test_cached_and_downloaded_archives_are_verified_and_a_bad_one_leaves_nothing(tmp_path):
    members = {"bin/ffmpeg": b"a\n", "bin/ffprobe": b"b\n", "LICENSE.txt": b"c\n"}
    entries = ffmpeg_fixture.vendor_entries(members)
    archive = ffmpeg_fixture.archive_bytes(entries)
    pin = ffmpeg_fixture.pin_for(archive, members, entries)
    cache, work = tmp_path / "cache", tmp_path / "work"
    cache.mkdir()
    work.mkdir()
    (cache / pin.archive_name).write_bytes(archive[:-1] + bytes([archive[-1] ^ 1]))
    with pytest.raises(managed_ffmpeg.FFmpegError) as bad_cache:
        managed_ffmpeg.fetch_archive(pin, work, source_dir=cache)
    assert bad_cache.value.code == "archive_sha256_mismatch"
    assert not list(work.iterdir())

    class Response:
        def __init__(self, data, length=None):
            self._data, self.headers = data, {"Content-Length": str(len(data) if length is None else length)}
        def read(self, n=-1):
            chunk, self._data = self._data[:n], self._data[n:]
            return chunk
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False

    good = managed_ffmpeg.fetch_archive(pin, work, opener=lambda request, timeout: Response(archive))
    assert good.read_bytes() == archive and not list(work.glob("*.part"))
    good.unlink()
    oversize = Response(archive + b"x", length=len(archive))  # announced length lies
    with pytest.raises(managed_ffmpeg.FFmpegError) as grown:
        managed_ffmpeg.fetch_archive(pin, work, opener=lambda request, timeout: oversize)
    assert grown.value.code == "archive_size_mismatch" and not list(work.iterdir())
    with pytest.raises(managed_ffmpeg.FFmpegError) as announced:
        managed_ffmpeg.fetch_archive(pin, work, opener=lambda request, timeout: Response(archive, length=len(archive) + 5))
    assert announced.value.code == "archive_size_mismatch" and not list(work.iterdir())

    def broken(request, timeout):
        raise OSError("connection reset")

    with pytest.raises(managed_ffmpeg.FFmpegError) as failed:
        managed_ffmpeg.fetch_archive(pin, work, opener=broken)
    assert failed.value.code == "download_failed" and not list(work.iterdir())


@pytest.mark.native_publication
def test_download_follows_only_allowlisted_https_redirects(monkeypatch):
    guard = managed_ffmpeg._RedirectGuard()
    request = managed_ffmpeg.urllib.request.Request(managed_ffmpeg.load_pin().archive_url)
    for url in ("http://github.com/x", "https://evil.example/x", "https://objects.githubusercontent.com.evil.example/x"):
        with pytest.raises(managed_ffmpeg.urllib.error.URLError):
            guard.redirect_request(request, None, 302, "Found", {}, url)
    allowed = guard.redirect_request(request, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/x")
    assert allowed is not None
    monkeypatch.setattr(managed_ffmpeg, "DOWNLOAD_HOSTS", ("example.invalid",))
    with pytest.raises(managed_ffmpeg.FFmpegError) as forbidden:
        managed_ffmpeg.fetch_archive(managed_ffmpeg.load_pin(), Path("/nonexistent"))
    assert forbidden.value.code == "download_host_forbidden"


def _link(kind, target):
    return (f"{ffmpeg_fixture.TOP}/doc/{kind}", None, 0o777, (kind_type[kind], target))


kind_type = {
    "symlink": tarfile.SYMTYPE,
    "hardlink": tarfile.LNKTYPE,
    "chardev": tarfile.CHRTYPE,
    "blockdev": tarfile.BLKTYPE,
    "fifo": tarfile.FIFOTYPE,
}


@pytest.mark.native_publication
@pytest.mark.parametrize(
    "extra",
    [
        pytest.param([_link("symlink", "/etc/passwd")], id="symlink-out"),
        pytest.param([_link("symlink", "bin/ffmpeg")], id="symlink-inside"),
        pytest.param([_link("hardlink", f"{ffmpeg_fixture.TOP}/bin/ffmpeg")], id="hardlink"),
        pytest.param([_link("chardev", "")], id="character-device"),
        pytest.param([_link("blockdev", "")], id="block-device"),
        pytest.param([_link("fifo", "")], id="fifo"),
        pytest.param([("/absolute/evil", b"x", 0o644, None)], id="absolute"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/../evil", b"x", 0o644, None)], id="dotdot"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/doc/../../evil", b"x", 0o644, None)], id="dotdot-deep"),
        pytest.param([("other-top/bin/ffmpeg", b"x", 0o644, None)], id="wrong-top"),
        pytest.param([(f"{ffmpeg_fixture.TOP}\\evil", b"x", 0o644, None)], id="backslash"),
        pytest.param([(f"{ffmpeg_fixture.TOP}//evil", b"x", 0o644, None)], id="empty-component"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/./evil", b"x", 0o644, None)], id="dot-component"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/doc/a\\..\\evil", b"x", 0o644, None)], id="deep-backslash"),
        pytest.param([("other-top/unique-file", b"x", 0o644, None)], id="wrong-top-unique-name"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/LICENSE.txt", b"again", 0o644, None)], id="duplicate-kept-name"),
        pytest.param([(f"{ffmpeg_fixture.TOP}/doc/readme.txt", b"again", 0o644, None)], id="duplicate-ignored-name"),
    ],
)
def test_any_unsafe_member_rejects_the_whole_archive_even_when_it_would_be_ignored(tmp_path, extra):
    path, stage, pin = _stage_archive(tmp_path, extra)
    with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert refused.value.code == "archive_unsafe_member"
    assert not list(stage.iterdir())  # whatever was written before the member was reached is gone
    assert not (tmp_path / "evil").exists() and not (tmp_path.parent / "evil").exists()


@pytest.mark.native_publication
def test_member_name_rules_cover_nul_and_empty_names_and_layout_must_match_the_pin(tmp_path):
    for name in ("", "a\0b", "/abs", "x\\y", "..", "top/../x"):
        with pytest.raises(managed_ffmpeg.FFmpegError):
            managed_ffmpeg._member_path(name, "top")
    assert managed_ffmpeg._member_path("top/", "top") == ""
    assert managed_ffmpeg._member_path("top/bin/", "top") == "bin"

    path, stage, pin = _stage_archive(tmp_path)
    for changed in (dataclasses.replace(pin, member_count=pin.member_count - 1),
                    dataclasses.replace(pin, member_count=pin.member_count + 1),
                    dataclasses.replace(pin, member_bytes=pin.member_bytes - 1),
                    dataclasses.replace(pin, member_bytes=pin.member_bytes + 1)):
        with pytest.raises(managed_ffmpeg.FFmpegError) as mismatch:
            managed_ffmpeg.extract_archive(path, stage, changed)
        assert mismatch.value.code == "archive_layout_mismatch"
        assert not list(stage.iterdir())

    other_members = {"bin/ffmpeg": b"x", "bin/ffprobe": b"y", "LICENSE.txt": b"z"}
    entries = ffmpeg_fixture.vendor_entries(other_members)
    entries = [e for e in entries if not e[0].endswith("/bin/ffprobe")]  # a pinned member is absent
    archive = ffmpeg_fixture.archive_bytes(entries)
    pin2 = dataclasses.replace(ffmpeg_fixture.pin_for(archive, other_members, ffmpeg_fixture.vendor_entries(other_members)),
                               archive_size=len(archive), archive_sha256=hashlib.sha256(archive).hexdigest(),
                               member_count=len(entries),
                               member_bytes=sum(len(e[1]) for e in entries if e[1] is not None))
    path2 = tmp_path / "second.tar.xz"
    path2.write_bytes(archive)
    with pytest.raises(managed_ffmpeg.FFmpegError) as absent:
        managed_ffmpeg.extract_archive(path2, stage, pin2)
    assert absent.value.code == "archive_member_missing" and not list(stage.iterdir())


@pytest.mark.native_publication
@pytest.mark.parametrize("bound", ["member_count", "member_bytes"])
def test_member_count_and_size_bounds_stop_the_stream_before_it_is_read_to_the_end(tmp_path, bound):
    members = {"bin/ffmpeg": b"a\n", "bin/ffprobe": b"b\n", "LICENSE.txt": b"c\n"}
    # A last, incompressible member the pin does not allow for: only reading on to the end finds the damage.
    big = (f"{ffmpeg_fixture.TOP}/doc/big.bin", random.Random(7).randbytes(600_000), 0o644, None)
    entries = ffmpeg_fixture.vendor_entries(members, [big])
    good = ffmpeg_fixture.archive_bytes(entries)
    corrupt = good[:-6] + bytes(b ^ 0xFF for b in good[-6:])  # damage the stream footer: only reading to the end notices
    pin = ffmpeg_fixture.pin_for(corrupt, members, entries)
    path = tmp_path / pin.archive_name
    path.write_bytes(corrupt)
    stage = tmp_path / "stage"
    stage.mkdir()
    with pytest.raises(managed_ffmpeg.FFmpegError) as unreadable:
        managed_ffmpeg.extract_archive(path, stage, pin)  # the pin is honest: the damage is found at the end
    assert unreadable.value.code == "archive_unreadable"
    # A pin that says there is less than the archive holds must be refused as soon as that is seen.
    smaller = (dataclasses.replace(pin, member_count=pin.member_count - 1) if bound == "member_count"
               else dataclasses.replace(pin, member_bytes=pin.member_bytes - 1))
    with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
        managed_ffmpeg.extract_archive(path, stage, smaller)
    assert refused.value.code == "archive_layout_mismatch" and not list(stage.iterdir())


@pytest.mark.native_publication
def test_a_download_is_cut_off_at_the_pinned_size_instead_of_being_read_on(tmp_path):
    members = {"bin/ffmpeg": b"a\n", "bin/ffprobe": b"b\n", "LICENSE.txt": b"c\n"}
    entries = ffmpeg_fixture.vendor_entries(members)
    archive = ffmpeg_fixture.archive_bytes(entries)
    pin = ffmpeg_fixture.pin_for(archive, members, entries)

    class Endless:
        headers = {}
        served = 0
        def read(self, n=-1):
            self.served += n
            assert self.served <= len(archive) + 4 * 256 * 1024, "the download was read far past the pinned size"
            return b"x" * n
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False

    work = tmp_path / "work"
    work.mkdir()
    with pytest.raises(managed_ffmpeg.FFmpegError) as cut_off:
        managed_ffmpeg.fetch_archive(pin, work, opener=lambda request, timeout: Endless())
    assert cut_off.value.code == "archive_size_mismatch" and not list(work.iterdir())


@pytest.mark.native_publication
def test_a_kept_member_that_differs_from_its_own_pin_is_refused_although_the_archive_hash_matches(tmp_path):
    def wrong_file_hash(pin):
        files = tuple(dataclasses.replace(r, sha256="0" * 64) if r.path == "bin/ffprobe" else r for r in pin.files)
        return dataclasses.replace(pin, files=files)

    path, stage, pin = _stage_archive(tmp_path, mutate_pin=wrong_file_hash)
    managed_ffmpeg.verify_archive_file(path, pin)  # the archive itself is exactly what the pin says
    with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert refused.value.code == "extracted_file_mismatch" and not list(stage.iterdir())

    def wrong_file_size(pin):
        files = tuple(dataclasses.replace(r, size=r.size + 1) if r.path == "LICENSE.txt" else r for r in pin.files)
        return dataclasses.replace(pin, files=files)

    path, stage, pin = _stage_archive(tmp_path, mutate_pin=wrong_file_size)
    with pytest.raises(managed_ffmpeg.FFmpegError) as sized:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert sized.value.code == "extracted_file_mismatch" and not list(stage.iterdir())


@pytest.mark.native_publication
def test_extraction_needs_an_empty_stage(tmp_path):
    path, stage, pin = _stage_archive(tmp_path)
    (stage / "leftover").write_bytes(b"x")
    with pytest.raises(managed_ffmpeg.FFmpegError) as refused:
        managed_ffmpeg.extract_archive(path, stage, pin)
    assert refused.value.code == "stage_not_empty"
    assert (stage / "leftover").read_bytes() == b"x"  # not ours to remove


@pytest.mark.native_publication
def test_a_full_disk_while_copying_or_extracting_is_a_named_failure_that_leaves_nothing(tmp_path, monkeypatch):
    path, stage, pin = _stage_archive(tmp_path)
    cache, work = tmp_path / "cache", tmp_path / "work"
    cache.mkdir()
    work.mkdir()
    shutil.copy(path, cache / pin.archive_name)

    def disk_full(_descriptor, _data):
        raise OSError(errno.ENOSPC, "No space left on device")

    with monkeypatch.context() as full:
        full.setattr(os, "write", disk_full)
        with pytest.raises(managed_ffmpeg.FFmpegError) as copying:
            managed_ffmpeg.fetch_archive(pin, work, source_dir=cache)
        assert copying.value.code == "archive_copy_failed" and not list(work.iterdir())
        with pytest.raises(managed_ffmpeg.FFmpegError) as extracting:
            managed_ffmpeg.extract_archive(path, stage, pin)
        assert extracting.value.code == "extract_failed" and not list(stage.iterdir())


@POSIX_ONLY
def test_extraction_sets_explicit_modes_whatever_the_archive_says(tmp_path):
    members = {"bin/ffmpeg": b"a\n", "bin/ffprobe": b"b\n", "LICENSE.txt": b"c\n"}
    entries = [(name, data, 0o4777 if name.endswith("bin/ffmpeg") else 0o666, special)
               for name, data, _mode, special in ffmpeg_fixture.vendor_entries(members)]
    archive = ffmpeg_fixture.archive_bytes(entries)
    pin = ffmpeg_fixture.pin_for(archive, members, entries)
    path = tmp_path / pin.archive_name
    path.write_bytes(archive)
    stage = tmp_path / "stage"
    stage.mkdir()
    previous = os.umask(0o077)  # a hostile umask changes nothing either
    try:
        managed_ffmpeg.extract_archive(path, stage, pin)
    finally:
        os.umask(previous)
    modes = {p.relative_to(stage).as_posix(): stat.S_IMODE(p.lstat().st_mode) for p in [stage, *stage.rglob("*")]}
    assert modes == {".": 0o755, "bin": 0o755, "bin/ffmpeg": 0o755, "bin/ffprobe": 0o755,
                     "LICENSE.txt": 0o644, "NOTICE.txt": 0o644}


@POSIX_ONLY
def test_files_core_writes_ask_for_binary_descriptors_so_windows_text_mode_cannot_alter_them(tmp_path, monkeypatch):
    """Emulates the Windows C runtime: without O_BINARY every LF becomes CRLF. The
    members and NOTICE.txt contain LF, so only exact bytes keep their hashes."""
    binary = 0x40000000
    text_mode = set()
    real_open, real_write, real_close = os.open, os.write, os.close

    def open_like_windows(path, flags, *args, **kwargs):
        descriptor = real_open(path, flags & ~binary, *args, **kwargs)
        if not flags & binary:
            text_mode.add(descriptor)
        return descriptor

    def write_like_windows(descriptor, data):
        data = bytes(data)
        if descriptor in text_mode:
            real_write(descriptor, data.replace(b"\n", b"\r\n"))
            return len(data)
        return real_write(descriptor, data)

    def close_like_windows(descriptor):
        text_mode.discard(descriptor)
        return real_close(descriptor)

    path, stage, pin = _stage_archive(tmp_path)
    cache, work = tmp_path / "cache", tmp_path / "work"
    cache.mkdir()
    work.mkdir()
    shutil.copy(path, cache / pin.archive_name)
    with monkeypatch.context() as windows:
        windows.setattr(os, "O_BINARY", binary, raising=False)
        windows.setattr(os, "open", open_like_windows)
        windows.setattr(os, "write", write_like_windows)
        windows.setattr(os, "close", close_like_windows)
        plain = tmp_path / "plain.txt"
        descriptor = os.open(plain, os.O_WRONLY | os.O_CREAT, 0o644)
        os.write(descriptor, b"a\nb\n")
        os.close(descriptor)
        assert plain.read_bytes() == b"a\r\nb\r\n"  # the emulation really converts
        fetched = managed_ffmpeg.fetch_archive(pin, work, source_dir=cache)
        managed_ffmpeg.extract_archive(fetched, stage, pin)
    assert managed_ffmpeg.inspect_tree(stage, pin).ok
    for written in stage.rglob("*"):
        if written.is_file():
            assert b"\r" not in written.read_bytes(), written.name


# --- 3. The installed tree -------------------------------------------------


def _staged_tree(tmp_path, mode="ok"):
    pair = ffmpeg_fixture.build_pair(tmp_path / "cache", mode)
    stage = tmp_path / "tree"
    stage.mkdir()
    managed_ffmpeg.extract_archive(pair.archive, stage, pair.pin)
    return pair, stage


@POSIX_ONLY
@pytest.mark.parametrize(
    "tamper,code",
    [
        ("flip_byte", "ffmpeg_file_hash_mismatch"),
        ("truncate", "ffmpeg_file_size_mismatch"),
        ("append", "ffmpeg_file_size_mismatch"),
        ("delete", "ffmpeg_file_missing"),
        ("extra_file", "ffmpeg_unexpected_entry"),
        ("extra_in_bin", "ffmpeg_unexpected_entry"),
        ("symlink_binary", "ffmpeg_not_regular_file"),
        ("notice", "ffmpeg_file_hash_mismatch"),
        ("licence", "ffmpeg_file_hash_mismatch"),
        ("mode_file", "ffmpeg_mode_mismatch"),
        ("mode_dir", "ffmpeg_mode_mismatch"),
    ],
)
def test_tree_inspection_names_each_way_the_installed_pair_can_differ_from_its_pin(tmp_path, tamper, code):
    pair, stage = _staged_tree(tmp_path)
    ffmpeg = stage / "bin" / "ffmpeg"
    if tamper == "flip_byte":
        data = ffmpeg.read_bytes()
        ffmpeg.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
    elif tamper == "truncate":
        ffmpeg.write_bytes(ffmpeg.read_bytes()[:-1])
    elif tamper == "append":
        ffmpeg.write_bytes(ffmpeg.read_bytes() + b"\n")
    elif tamper == "delete":
        ffmpeg.unlink()
    elif tamper == "extra_file":
        (stage / "ffplay").write_bytes(b"x")
    elif tamper == "extra_in_bin":
        (stage / "bin" / "ffplay").write_bytes(b"x")
    elif tamper == "symlink_binary":
        ffmpeg.unlink()
        ffmpeg.symlink_to("/bin/true")
    elif tamper in ("notice", "licence"):  # same size, one byte: only the hash can tell
        target = stage / ("NOTICE.txt" if tamper == "notice" else "LICENSE.txt")
        data = target.read_bytes()
        target.write_bytes(bytes([data[0] ^ 1]) + data[1:])
    elif tamper == "mode_file":
        ffmpeg.chmod(0o775)
    elif tamper == "mode_dir":
        (stage / "bin").chmod(0o777)
    report = managed_ffmpeg.inspect_tree(stage, pair.pin)
    assert not report.ok and report.reason == code, report.problems
    assert not managed_ffmpeg.matches_pin(stage, pair.pin)


@POSIX_ONLY
def test_tree_inspection_reports_missing_and_unreadable_locations_separately(tmp_path):
    pair, stage = _staged_tree(tmp_path)
    assert managed_ffmpeg.inspect_tree(tmp_path / "absent", pair.pin).reason == "location_missing"
    (tmp_path / "file").write_bytes(b"x")
    assert managed_ffmpeg.inspect_tree(tmp_path / "file", pair.pin).reason == "location_not_directory"
    if os.geteuid() != 0:
        (stage / "bin" / "ffmpeg").chmod(0o000)
        try:
            with pytest.raises(managed_ffmpeg.FFmpegError) as unreadable:
                managed_ffmpeg.inspect_tree(stage, pair.pin)
            assert unreadable.value.code == "tree_unreadable"
            assert not managed_ffmpeg.matches_pin(stage, pair.pin)
        finally:
            (stage / "bin" / "ffmpeg").chmod(0o755)


# --- 4. The probe (C20) ----------------------------------------------------


def _riff(chunks):
    body = b"WAVE" + b"".join(cid + len(data).to_bytes(4, "little") + data + (b"\0" if len(data) & 1 else b"") for cid, data in chunks)
    return b"RIFF" + len(body).to_bytes(4, "little") + body


@pytest.mark.native_publication
def test_wav_reader_handles_the_headers_ffmpeg_writes_on_every_python(tmp_path):
    """24-bit output from FFmpeg is WAVE_FORMAT_EXTENSIBLE with a LIST chunk before the data;
    the standard `wave` module cannot read that before Python 3.12, which Core still supports."""
    pcm = bytes(range(240))
    plain = struct.pack("<HHIIHH", 1, 2, 44100, 44100 * 6, 6, 24)
    guid = bytes.fromhex("0100000000001000800000aa00389b71")
    extensible = struct.pack("<HHIIHH", 0xFFFE, 2, 44100, 44100 * 6, 6, 24) + struct.pack("<HHI", 22, 24, 3) + guid
    info = b"INFO" + b"ISFT" + (14).to_bytes(4, "little") + b"Lavf61.1.100\0\0"
    for index, (fmt, extra) in enumerate(((plain, []), (extensible, [(b"LIST", info)]), (extensible, []))):
        path = tmp_path / f"{index}.wav"
        path.write_bytes(_riff([(b"fmt ", fmt), *extra, (b"data", pcm)]))
        assert managed_ffmpeg._read_pcm(path) == (2, 3, 44100, pcm)
    odd = tmp_path / "odd.wav"  # an odd-sized chunk is padded to an even boundary
    odd.write_bytes(_riff([(b"fmt ", plain), (b"junk", b"abc"), (b"data", pcm)]))
    assert managed_ffmpeg._read_pcm(odd)[3] == pcm
    float_tag = struct.pack("<HHIIHH", 3, 2, 44100, 44100 * 8, 8, 32)
    broken = {
        "float": _riff([(b"fmt ", float_tag), (b"data", pcm)]),
        "no data": _riff([(b"fmt ", plain)]),
        "no fmt": _riff([(b"data", pcm)]),
        "truncated": _riff([(b"fmt ", plain), (b"data", pcm)])[:-5],
        "not riff": b"RIFX" + b"\0" * 40,
        "other extensible subformat": _riff([(b"fmt ", extensible[:24] + b"\x03\x00" + extensible[26:]), (b"data", pcm)]),
    }
    for name, blob in broken.items():
        path = tmp_path / "broken.wav"
        path.write_bytes(blob)
        with pytest.raises(ValueError):
            managed_ffmpeg._read_pcm(path)


@POSIX_ONLY
def test_probe_round_trips_wav_flac_wav_bit_exact_at_16_and_24_bit(tmp_path):
    pair, stage = _staged_tree(tmp_path)
    calls = []

    def recording_run(command, **kwargs):
        calls.append((list(command), kwargs))
        return subprocess.run(command, **kwargs)

    result = managed_ffmpeg.probe_pair(stage, pair.pin, run=recording_run)
    assert result["cases"] == ["s16", "s24"]
    labels = [c[0][-1] for c in calls]
    assert any(label.endswith("s16.flac") for label in labels) and any(label.endswith("s24.flac") for label in labels)
    codecs = {c[0][c[0].index("-c:a") + 1] for c in calls if "-c:a" in c[0]}
    assert codecs == {"flac", "pcm_s16le", "pcm_s24le"}
    for command, kwargs in calls:
        # minimal explicit environment, our directory only, bounded in time, run from scratch
        assert kwargs["env"].keys() == {"PATH", "LC_ALL", "TMPDIR"}
        assert kwargs["env"]["PATH"] == str(stage / "bin") and kwargs["env"]["LC_ALL"] == "C"
        assert kwargs["timeout"] <= managed_ffmpeg.PROBE_COMMAND_TIMEOUT_SECONDS
        assert Path(kwargs["cwd"]) == Path(kwargs["env"]["TMPDIR"])
        assert stage not in Path(kwargs["cwd"]).parents and Path(command[0]).parent == stage / "bin"
    assert not Path(calls[0][1]["cwd"]).exists()  # scratch removed
    assert not list(stage.rglob("*.wav")) and not list(stage.rglob("*.flac"))  # nothing written into the tree


@POSIX_ONLY
@pytest.mark.parametrize(
    "mode,code",
    [
        ("lossy", "probe_roundtrip_mismatch"),   # a decode that is not bit-exact
        ("nocodec", "probe_command_failed"),     # the encoder is missing
        ("crash", "probe_command_failed"),       # the binary dies by signal
        ("badprobe", "probe_ffprobe_mismatch"),  # ffprobe does not describe the FLAC file
        ("badcopy", "probe_roundtrip_mismatch"), # a WAV-to-WAV copy is not exact
    ],
)
def test_probe_fails_for_a_corrupt_binary_a_missing_codec_or_a_lossy_decode(tmp_path, mode, code):
    pair, stage = _staged_tree(tmp_path, mode)
    assert managed_ffmpeg.inspect_tree(stage, pair.pin).ok  # the hashes are fine: only running it shows
    with pytest.raises(managed_ffmpeg.FFmpegError) as failed:
        managed_ffmpeg.probe_pair(stage, pair.pin)
    assert failed.value.code in ({code, "probe_version_mismatch"} if mode == "crash" else {code})


@POSIX_ONLY
def test_probe_checks_the_pinned_build_and_refuses_gpl_or_nonfree_flags(tmp_path):
    pair, stage = _staged_tree(tmp_path)
    other_build = dataclasses.replace(pair.pin, version="n9.9-other-20260101")
    with pytest.raises(managed_ffmpeg.FFmpegError) as version:
        managed_ffmpeg.probe_pair(stage, other_build)
    assert version.value.code == "probe_version_mismatch"
    other_flags = dataclasses.replace(pair.pin, configuration=pair.pin.configuration + " --enable-gpl")
    with pytest.raises(managed_ffmpeg.FFmpegError) as flags:
        managed_ffmpeg.probe_pair(stage, other_flags)
    assert flags.value.code == "probe_version_mismatch"  # the build differs from the pin first

    pair2 = ffmpeg_fixture.build_pair(tmp_path / "cache2")
    gpl_configuration = pair.pin.configuration + " --enable-gpl"
    members = {
        "bin/ffmpeg": ffmpeg_fixture.tool_script("ffmpeg", configuration=gpl_configuration),
        "bin/ffprobe": ffmpeg_fixture.tool_script("ffprobe", configuration=gpl_configuration),
        "LICENSE.txt": b"licence\n",
    }
    gpl_dir = tmp_path / "gpl"
    (gpl_dir / "bin").mkdir(parents=True)
    for name, data in members.items():
        (gpl_dir / name).write_bytes(data)
        (gpl_dir / name).chmod(0o755)
    gpl_pin = dataclasses.replace(pair2.pin, configuration=gpl_configuration)
    with pytest.raises(managed_ffmpeg.FFmpegError) as gpl:
        managed_ffmpeg.probe_pair(gpl_dir, gpl_pin)
    assert gpl.value.code == "probe_license_flags"


@POSIX_ONLY
@pytest.mark.parametrize(
    "reported",
    [
        f"{ffmpeg_fixture.VERSION}-unexpected",  # the pinned version is only a prefix of the report
        f"pre-{ffmpeg_fixture.VERSION}",         # the pinned version is not at the start
    ],
)
def test_probe_version_match_is_a_strict_prefix_with_a_trailing_space(tmp_path, reported):
    pair, stage = _staged_tree(tmp_path)
    for tool in ("ffmpeg", "ffprobe"):
        stand_in = stage / "bin" / tool
        stand_in.write_bytes(ffmpeg_fixture.tool_script(tool, version=reported))
    with pytest.raises(managed_ffmpeg.FFmpegError) as mismatch:
        managed_ffmpeg.probe_pair(stage, pair.pin)
    assert mismatch.value.code == "probe_version_mismatch"


@POSIX_ONLY
def test_probe_is_bounded_in_time_and_never_scratches_inside_the_tree(tmp_path, monkeypatch):
    pair, stage = _staged_tree(tmp_path)
    slow = stage / "bin" / "ffprobe"
    slow.write_bytes(b"#!/bin/sh\nexec /bin/sleep 30\n")
    monkeypatch.setattr(managed_ffmpeg, "PROBE_COMMAND_TIMEOUT_SECONDS", 1)
    with pytest.raises(managed_ffmpeg.FFmpegError) as timed_out:
        managed_ffmpeg.probe_pair(stage, pair.pin)
    assert timed_out.value.code == "probe_timeout"

    pair, stage = _staged_tree(tmp_path / "again")
    with pytest.raises(managed_ffmpeg.FFmpegError) as unsafe:
        managed_ffmpeg.probe_pair(stage, pair.pin, scratch_parent=stage)
    assert unsafe.value.code == "probe_scratch_unsafe"
    with pytest.raises(managed_ffmpeg.FFmpegError) as below:
        managed_ffmpeg.probe_pair(stage, pair.pin, scratch_parent=stage / "bin")
    assert below.value.code == "probe_scratch_unsafe"

    missing = tmp_path / "nobinary"
    (missing / "bin").mkdir(parents=True)
    with pytest.raises(managed_ffmpeg.FFmpegError) as no_binary:
        managed_ffmpeg.probe_pair(missing, pair.pin)
    assert no_binary.value.code == "probe_spawn_failed"

    monkeypatch.setattr(managed_ffmpeg, "PROBE_TOTAL_TIMEOUT_SECONDS", 0)
    with pytest.raises(managed_ffmpeg.FFmpegError) as total:
        managed_ffmpeg.probe_pair(stage, pair.pin)
    assert total.value.code == "probe_timeout"


@pytest.mark.skipif(not os.environ.get(REAL_ARCHIVE_ENV) or not sys.platform.startswith("linux"),
                    reason=f"set {REAL_ARCHIVE_ENV} to the vendor archive to run the real binaries")
def test_real_vendor_pair_extracts_verifies_and_round_trips_bit_exact(tmp_path):
    pin = managed_ffmpeg.load_pin()
    cache = Path(os.environ[REAL_ARCHIVE_ENV])
    work, stage = tmp_path / "work", tmp_path / "stage"
    work.mkdir()
    stage.mkdir()
    report = managed_ffmpeg.stage_pair(pin, work, stage, source_dir=cache if cache.is_dir() else cache.parent)
    assert report.ok and report.tree_sha256 == managed_ffmpeg.expected_tree_sha256(pin)
    assert managed_ffmpeg.probe_pair(stage, pin)["cases"] == ["s16", "s24"]
    assert not list(work.iterdir())  # the archive is deleted after extraction


# --- 5. Environment of a process that uses the pair (C19) ------------------


def test_pair_environment_replaces_overrides_and_puts_our_directory_first(tmp_path):
    pair_dir = tmp_path / "pair"
    env = {
        "PATH": os.pathsep.join(["/usr/bin", str(pair_dir / "bin"), "/opt/system-ffmpeg"]),
        "STEMWERK_FFMPEG_PATH": "/opt/system-ffmpeg/ffmpeg", "FFMPEG_PATH": "/x", "IMAGEIO_FFMPEG_EXE": "/y",
        "FFMPEG_BINARY": "/z", "FFPROBE_BINARY": "/w", "FFPROBE_PATH": "/v", "UNRELATED": "kept",
    }
    result = managed_ffmpeg.pair_environment(env, pair_dir)
    bin_dir = str(pair_dir / "bin")
    assert result["PATH"].split(os.pathsep) == [bin_dir, "/usr/bin", "/opt/system-ffmpeg"]
    for name in managed_ffmpeg.FFMPEG_ENV_VARS:
        assert result[name] == str(pair_dir / "bin" / "ffmpeg")
    for name in managed_ffmpeg.FFPROBE_ENV_VARS:
        assert result[name] == str(pair_dir / "bin" / "ffprobe")
    assert result["UNRELATED"] == "kept" and env["PATH"].startswith("/usr/bin")  # input untouched
    assert managed_ffmpeg.pair_environment({}, pair_dir)["PATH"] == bin_dir


# --- 6. Install, verify, registry, receipt ---------------------------------


def _plan(root, facts):
    return install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")


def _install(root, facts, **kwargs):
    return module_installer.install_module("drum_kit", _plan(root, facts)["fingerprint"], root=root, facts=facts, **kwargs)


def _components(doc):
    return {c["component_id"]: c for c in doc["components"]}


def _fresh(tmp_path, monkeypatch, *, mode="ok", real_probe=False):
    facts, root, unrelated, commands = _prepare_fake_install(tmp_path, monkeypatch)
    if mode != "ok":
        pair = ffmpeg_fixture.build_pair(tmp_path / "ffmpeg-cache-defective", mode)
        monkeypatch.setattr(managed_ffmpeg, "load_pin", lambda platform_key="linux-x86_64", **_kw: pair.pin)
        monkeypatch.setenv(managed_ffmpeg.ARCHIVE_CACHE_ENV, str(pair.cache_dir))
    if real_probe:
        monkeypatch.setattr(managed_ffmpeg, "probe_pair", REAL_PROBE)
    return facts, root, unrelated


@pytest.mark.native_publication
def test_fresh_install_publishes_the_pair_and_records_it_in_receipt_and_registry(tmp_path, monkeypatch):
    facts, root, unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    plan = _plan(root, facts)
    assert plan["actions"]["ffmpeg"]["pin_id"] == pin.pin_id
    assert plan["actions"]["destinations"]["ffmpeg"] == str(root / "runtimes" / "ffmpeg" / pin.pin_id)
    assert [s["phase"] for s in plan["actions"]["steps"]] == [
        "create_environment", "install_packages", "fetch_ffmpeg", "verify_ffmpeg",
        "fetch_assets", "verify_assets", "publish", "verify_module"]
    assert {"github.com", *managed_ffmpeg.REDIRECT_HOSTS} <= set(plan["network_hosts"])

    code, doc = module_installer.install_module("drum_kit", plan["fingerprint"], root=root, facts=facts)
    assert code == 0, doc
    assert doc["outcome"] == "installed_s6_partial" and doc["installation_state"] == "partial"
    assert doc["decided_by_rule"] == 4 and doc["readiness"] == "not_ready"
    assert doc["pending_slices"] == ["s9_activation"]
    classes = {k: v["class"] for k, v in _components(doc["verification"]).items()}
    assert classes == {"managed_python": "present_passing", "module_venv": "present_passing",
                       "ffmpeg": "present_passing", "drumsep_assets": "present_passing",
                       "reaper_activation": "absent"}

    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    assert managed_ffmpeg.inspect_tree(published, pin).ok
    assert sorted(p.name for p in published.iterdir()) == ["LICENSE.txt", "NOTICE.txt", "bin"]
    assert (published / "LICENSE.txt").read_bytes() == b"The vendor licence text, unchanged.\n"
    assert not list(root.glob("tmp/*/journal.ndjson")) and not list(root.glob("tmp/*/core"))  # stage and archive gone
    assert unrelated.read_text(encoding="utf-8") == "do not delete"

    receipt = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))
    entry = receipt["components"]["ffmpeg"]
    assert receipt["pending_slices"] == ["s9_activation"]
    assert entry["pin_id"] == pin.pin_id and entry["version"] == pin.version and entry["ownership"] == "core_managed"
    assert entry["archive"] == {"url": pin.archive_url, "size_bytes": pin.archive_size, "sha256": pin.archive_sha256}
    notice = managed_ffmpeg.installed_records(pin)["NOTICE.txt"]
    assert entry["files"]["NOTICE.txt"]["sha256"] == notice.sha256
    for record in pin.files:  # per-file size and SHA-256 of what was extracted
        assert entry["files"][record.path] == {"size_bytes": record.size, "sha256": record.sha256, "mode": f"{record.mode:04o}"}
    assert entry["sources"]["ffmpeg_commit"] == pin.ffmpeg_commit and entry["sources"]["recipe_commit"] == pin.recipe_commit
    assert entry["tree_sha256"] == managed_ffmpeg.expected_tree_sha256(pin)
    registry = json.loads(module_registry.registry_path(root).read_text(encoding="utf-8"))
    registered = registry["modules"]["drum_kit"]["components"]["ffmpeg"]
    assert registered["pin_id"] == pin.pin_id and registered["tree_sha256"] == entry["tree_sha256"]
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[0] == "valid"


@pytest.mark.native_publication
def test_repeating_the_install_reuses_the_verified_pair_without_fetching(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    before = module_registry.receipt_path(root, "drum_kit").read_bytes()
    published = next((root / "runtimes" / "ffmpeg").iterdir())
    inode = published.stat().st_ino
    monkeypatch.delenv(managed_ffmpeg.ARCHIVE_CACHE_ENV)

    def no_network(*_a, **_k):
        raise AssertionError("a reused pair must not be fetched")

    code, doc = _install(root, facts, ffmpeg_opener=no_network)
    assert code == 0 and doc["outcome"] == "reused" and doc["pending_slices"] == ["s9_activation"]
    assert module_registry.receipt_path(root, "drum_kit").read_bytes() == before
    assert published.stat().st_ino == inode


def _make_s6_only_root(root):
    """What an S6 install left before S7: the same root with the pair removed from receipt and registry."""
    receipt = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))
    pair_dir = Path(receipt["components"]["ffmpeg"]["path"])
    receipt["components"]["ffmpeg"] = None
    receipt["pending_slices"] = ["s7_managed_ffmpeg", "s9_activation"]
    _path, sha = module_registry.write_receipt(root, "drum_kit", receipt)
    module_registry.write_registry_from_receipt(root, "drum_kit", receipt, sha)
    shutil.rmtree(pair_dir)
    shutil.rmtree(pair_dir.parent)
    return receipt


@pytest.mark.native_publication
def test_the_pair_is_added_to_an_existing_s6_root_without_touching_anything_else(tmp_path, monkeypatch):
    facts, root, unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    s6_receipt = _make_s6_only_root(root)
    state = module_verify.verify_module("drum_kit", root=root)
    assert state["installation_state"] == "partial" and _components(state)["ffmpeg"]["class"] == "absent"
    # Registered, pair pending: refused for a job (never "unregistered", which would mean legacy discovery).
    assert module_verify.s6_ffmpeg_pair(root) == ("refused", "managed_ffmpeg_pending", None)

    runtime_dirs = {
        name: Path(s6_receipt["components"][name]["path"]) for name in ("managed_python", "module_venv", "drumsep_assets")
    }
    identities = {name: module_registry.compute_tree_identity(path) for name, path in runtime_dirs.items()}
    inodes = {name: path.stat().st_ino for name, path in runtime_dirs.items()}
    commands = []
    real_run = subprocess.run
    monkeypatch.setattr(module_installer.subprocess, "run", lambda cmd, *a, **k: commands.append(cmd) or real_run(cmd, *a, **k))

    plan = _plan(root, facts)
    assert plan["preflight_result"] == "no_blocker_found" and plan["installation"]["ffmpeg"] == "absent"
    code, doc = module_installer.install_module("drum_kit", plan["fingerprint"], root=root, facts=facts)
    assert code == 0, doc
    assert doc["outcome"] == "ffmpeg_added" and doc["installation_state"] == "partial"
    assert doc["pending_slices"] == ["s9_activation"] and set(doc["components"]) == {"ffmpeg"}
    assert not commands  # no venv, no pip: only the pair, the receipt and the registry were written

    for name, path in runtime_dirs.items():
        assert module_registry.compute_tree_identity(path) == identities[name]
        assert path.stat().st_ino == inodes[name]
    new_receipt = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))
    for name in ("managed_python", "module_venv", "drumsep_assets", "reaper_activation"):
        assert new_receipt["components"][name] == s6_receipt["components"][name]  # not re-described
    assert new_receipt["created_at_utc"] == s6_receipt["created_at_utc"]
    assert new_receipt["operation_id"] == doc["operation_id"] != s6_receipt["operation_id"]
    assert new_receipt["components"]["ffmpeg"]["pin_id"] == managed_ffmpeg.load_pin().pin_id
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[0] == "valid"
    assert _components(module_verify.verify_module("drum_kit", root=root))["ffmpeg"]["class"] == "present_passing"
    assert unrelated.read_text(encoding="utf-8") == "do not delete"


@pytest.mark.native_publication
def test_a_failed_probe_publishes_nothing_and_registers_nothing(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, mode="lossy")

    def run_for_real(directory, pin, **kwargs):
        if os.name == "nt":
            raise managed_ffmpeg.FFmpegError("probe_roundtrip_mismatch", "the stand-in cannot run here")
        return REAL_PROBE(directory, pin, **kwargs)

    monkeypatch.setattr(managed_ffmpeg, "probe_pair", run_for_real)
    code, refused = _install(root, facts)
    assert code == 2 and refused["phase"] == "verify_ffmpeg"
    assert refused["error"]["code"] == "probe_roundtrip_mismatch"
    assert not (root / "runtimes" / "ffmpeg").exists() or not list((root / "runtimes" / "ffmpeg").iterdir())
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()


@pytest.mark.native_publication
@pytest.mark.parametrize("fault", ["after_ffmpeg_staging", "after_ffmpeg_publish"])
def test_a_fault_around_the_pair_blesses_nothing_and_the_retry_recovers(tmp_path, monkeypatch, fault):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", fault)
    code, failed = _install(root, facts)
    monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
    assert code == 2 and failed["error"]["code"] == f"fault_injected_{fault}"
    # Nothing names the pair: no receipt, no registry, so no state can call it installed.
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()
    assert published.exists() == (fault == "after_ffmpeg_publish")
    assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "not_installed"

    plan = _plan(root, facts)
    assert ("recoverable_ffmpeg_publication" in plan["warnings"]) == (fault == "after_ffmpeg_publish")
    opened = []
    code, ok = _install(root, facts, ffmpeg_opener=lambda *a, **k: opened.append(1))
    assert code == 0, ok
    assert managed_ffmpeg.inspect_tree(published, pin).ok
    entry = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))["components"]["ffmpeg"]
    assert entry["ownership"] == ("unknown" if fault == "after_ffmpeg_publish" else "core_managed")
    assert not opened  # the cache served it; an adopted directory needed no fetch at all


@pytest.mark.native_publication
def test_adopting_an_already_published_pair_re_probes_it_before_trusting_it(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", "after_ffmpeg_publish")
    code, failed = _install(root, facts)
    monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
    assert code == 2 and published.exists()  # published but not receipted: the retry adopts it

    calls = []
    ffmpeg_fixture.stub_probe(monkeypatch, calls)  # re-arm with a recording probe
    code, adopted = _install(root, facts)
    assert code == 0, adopted
    # One probe when the adoption branch re-verifies the pair, one from the post-publication verify.
    assert calls == [published, published]


class _Killed(BaseException):
    """Ends an install at an exact point, past Core's ``except Exception`` handlers."""


def _kill_at_pair_publication(monkeypatch, published, *, after_rename):
    real_rename = install_journal.Journal.rename

    def rename(journal, source, destination, *args, **kwargs):
        if Path(destination) != published:
            return real_rename(journal, source, destination, *args, **kwargs)
        if after_rename:
            real_rename(journal, source, destination, *args, **kwargs)
        journal.close()
        raise _Killed()

    monkeypatch.setattr(install_journal.Journal, "rename", rename)


@pytest.mark.native_publication
@pytest.mark.parametrize("after_rename", [False, True])
def test_a_kill_during_the_pairs_no_replace_publication_is_recoverable_and_blesses_nothing(
    tmp_path, monkeypatch, after_rename
):
    facts, root, unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    with monkeypatch.context() as kill:
        _kill_at_pair_publication(kill, published, after_rename=after_rename)
        with pytest.raises(_Killed):
            _install(root, facts)
    assert published.is_dir() == after_rename
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()
    assert list(root.glob("tmp/*/journal.ndjson"))  # the dead operation's journal awaits recovery

    code, doc = _install(root, facts)
    assert code == 0, doc
    assert doc["installation_state"] == "partial"
    assert _components(doc["verification"])["ffmpeg"]["class"] == "present_passing"
    assert not list(root.glob("tmp/*/journal.ndjson")) and unrelated.exists()


@pytest.mark.native_publication
def test_a_published_pair_that_is_not_exactly_the_pin_is_refused_and_preserved(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id

    # A foreign directory at the destination: conflict in the plan and in the installer.
    published.mkdir(parents=True)
    (published / "mine.txt").write_bytes(b"user data")
    assert "runtime_conflict" in _plan(root, facts)["blockers"]
    code, refused = _install(root, facts)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert (published / "mine.txt").read_bytes() == b"user data"
    shutil.rmtree(published)

    # A dead operation's published directory that was altered in the window is not adopted.
    monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", "after_ffmpeg_publish")
    assert _install(root, facts)[0] == 2
    monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
    victim = published / "LICENSE.txt"
    victim.write_bytes(victim.read_bytes() + b"tampered\n")
    assert "runtime_conflict" in _plan(root, facts)["blockers"]
    assert "recoverable_ffmpeg_publication" not in _plan(root, facts)["warnings"]
    assert module_installer._verify_published_object(root, "drum_kit", published) is False
    assert victim.read_bytes().endswith(b"tampered\n")
    assert not module_registry.receipt_path(root, "drum_kit").exists()


@pytest.mark.native_publication
def test_published_object_hook_accepts_only_the_exact_tree_at_the_pins_destination(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    assert module_installer._verify_published_object(root, "drum_kit", published) is True
    other = published.with_name("some-other-pin")
    shutil.copytree(published, other)
    assert module_installer._verify_published_object(root, "drum_kit", other) is False
    monkeypatch.setattr(managed_ffmpeg, "load_pin", lambda *a, **k: (_ for _ in ()).throw(managed_ffmpeg.FFmpegError("pin_invalid", "x")))
    assert module_installer._verify_published_object(root, "drum_kit", published) is False


@pytest.mark.native_publication
def test_a_stage_changed_after_it_was_verified_is_not_published_into_a_receipt(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()

    def change_the_stage(point):
        if point == "after_ffmpeg_staging":
            notice = next(root.glob("tmp/*/core/ffmpeg/stage/NOTICE.txt"))
            data = notice.read_bytes()
            notice.write_bytes(bytes([data[0] ^ 1]) + data[1:])  # same size: only the hash can tell

    code, refused = _install(root, facts, fault_hook=change_the_stage)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    assert published.exists()  # kept for inspection, never named by a receipt
    assert module_installer._verify_published_object(root, "drum_kit", published) is False


@pytest.mark.native_publication
def test_publication_never_replaces_and_adoption_needs_the_exact_tree(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    pin = managed_ffmpeg.load_pin()
    destination = root / "runtimes" / "ffmpeg" / pin.pin_id
    op = str(uuid.uuid4())
    journal = install_journal.open_journal(root, op)
    try:
        stage = journal.create_directory(journal.core_directory / "stage")
        (stage / "payload").write_bytes(b"x")
        destination.mkdir(parents=True)  # an EMPTY directory is still somebody's: no-replace means no replace
        with pytest.raises(module_installer.S6InstallError) as refused:
            module_installer._publish_ffmpeg(journal, root, pin, stage)
        assert refused.value.code == "runtime_conflict"
        assert destination.is_dir() and not list(destination.iterdir()) and (stage / "payload").exists()

        # Adoption is only for a tree that is exactly the pin.
        (destination / "stranger.txt").write_bytes(b"not ours")

        class Writer:
            def append(self, *_a, **_k):
                pass

        with pytest.raises(module_installer.S6InstallError) as foreign:
            module_installer._acquire_ffmpeg(Writer(), journal, root, pin, source_dir=None, opener=None,
                                             trigger_fault=lambda _point: None)
        assert foreign.value.code == "runtime_conflict"
        assert (destination / "stranger.txt").read_bytes() == b"not ours"
    finally:
        journal.close()


@pytest.mark.native_publication
def test_the_pair_is_part_of_the_consent_fingerprint(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    consent = _plan(root, facts)["fingerprint"]
    pin = managed_ffmpeg.load_pin()
    for changed in (dataclasses.replace(pin, archive_sha256="1" * 64),
                    dataclasses.replace(pin, release_tag="autobuild-2026-02-02-00-00"),
                    dataclasses.replace(pin, pin_id="another-n0.0-test-20260101-linux64-lgpl")):
        monkeypatch.setattr(managed_ffmpeg, "load_pin", lambda *_a, _pin=changed, **_k: _pin)
        assert _plan(root, facts)["fingerprint"] != consent
    monkeypatch.setattr(managed_ffmpeg, "load_pin", lambda *_a, **_k: pin)
    assert _plan(root, facts)["fingerprint"] == consent
    code, refused = module_installer.install_module("drum_kit", "0" * 64, root=root, facts=facts)
    assert code == 2 and refused["error"]["code"] == "plan_changed"


@pytest.mark.native_publication
def test_reconciliation_after_a_kill_between_receipt_and_registry_verifies_the_pair_too(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    _make_s6_only_root(root)
    monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", "between_receipt_and_registry")
    code, failed = _install(root, facts)
    monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
    assert code == 2 and failed["error"]["code"] == "fault_injected_between_receipt_and_registry"
    # The new receipt names the pair; the registry still holds the old entry.
    assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "unknown"
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id

    # Changed bytes in that window are not blessed by reconciliation.
    data = (published / "bin" / "ffprobe").read_bytes()
    (published / "bin" / "ffprobe").write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
    receipt_before = module_registry.receipt_path(root, "drum_kit").read_bytes()
    assert module_installer._reconcile_interrupted_receipt_under_lock(root, "drum_kit") is False
    assert module_registry.receipt_path(root, "drum_kit").read_bytes() == receipt_before
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[0] == "unverifiable"

    (published / "bin" / "ffprobe").write_bytes(data)  # restored: the registry is written from the receipt
    assert module_installer._reconcile_interrupted_receipt_under_lock(root, "drum_kit") is True
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[0] == "valid"


# --- 7. Integrity after install: the vendor hash covers the archive only ---


@POSIX_ONLY
@pytest.mark.parametrize("tamper", ["flip_ffprobe", "truncate_ffmpeg", "remove_notice", "extra_ffplay", "chmod"])
def test_a_changed_installed_file_is_repair_required_never_passing(tmp_path, monkeypatch, tamper):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "partial"
    if tamper == "flip_ffprobe":
        data = (published / "bin" / "ffprobe").read_bytes()
        (published / "bin" / "ffprobe").write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
    elif tamper == "truncate_ffmpeg":
        (published / "bin" / "ffmpeg").write_bytes((published / "bin" / "ffmpeg").read_bytes()[:-5])
    elif tamper == "remove_notice":
        (published / "NOTICE.txt").unlink()
    elif tamper == "extra_ffplay":
        (published / "bin" / "ffplay").write_bytes(b"x")
    else:
        (published / "bin" / "ffmpeg").chmod(0o775)
    doc = module_verify.verify_module("drum_kit", root=root)
    component = _components(doc)["ffmpeg"]
    assert doc["installation_state"] == "repair_required" and doc["decided_by_rule"] == 1
    assert component["class"] == "present_failing"
    assert component["reason_code"].startswith("ffmpeg_")
    # The plan refuses to build on it and the worker guard refuses to start a job with it.
    assert "runtime_conflict" in _plan(root, facts)["blockers"]
    state, reason, directory = module_verify.s6_ffmpeg_pair(root)
    assert state == "refused" and directory is None and reason.startswith("ffmpeg_")
    ok, why, none = module_verify.verify_s6_ffmpeg_for_interpreter(
        Path(json.loads(module_registry.receipt_path(root, "drum_kit").read_text())["components"]["module_venv"]["path"]) / "bin" / "python")
    assert ok is False and none is None and why.startswith("s6_ffmpeg_refused:")


@pytest.mark.native_publication
def test_a_receipt_that_disagrees_with_the_pin_or_the_files_fails_verification(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    path = module_registry.receipt_path(root, "drum_kit")
    original = json.loads(path.read_text(encoding="utf-8"))

    def reseal(receipt):
        _p, sha = module_registry.write_receipt(root, "drum_kit", receipt)
        module_registry.write_registry_from_receipt(root, "drum_kit", receipt, sha)
        return _components(module_verify.verify_module("drum_kit", root=root))["ffmpeg"]

    other_hash = json.loads(json.dumps(original))
    other_hash["components"]["ffmpeg"]["files"]["bin/ffmpeg"]["sha256"] = "1" * 64
    assert reseal(other_hash)["reason_code"] == "ffmpeg_receipt_mismatch"
    other_archive = json.loads(json.dumps(original))
    other_archive["components"]["ffmpeg"]["archive"]["sha256"] = "2" * 64
    assert reseal(other_archive)["reason_code"] == "ffmpeg_pin_mismatch"
    other_pin = json.loads(json.dumps(original))
    other_pin["components"]["ffmpeg"]["pin_id"] = "somebody-elses-build-linux64"
    assert reseal(other_pin)["reason_code"] == "ffmpeg_pin_mismatch"
    other_tree = json.loads(json.dumps(original))
    other_tree["components"]["ffmpeg"]["tree_sha256"] = "3" * 64
    assert reseal(other_tree)["reason_code"] == "ffmpeg_receipt_mismatch"
    assert reseal(original)["class"] == "present_passing"


@pytest.mark.native_publication
def test_a_pair_receipted_at_another_location_is_not_the_pins_pair(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    elsewhere = root / "runtimes" / "ffmpeg" / "a-copy-somewhere-else"
    shutil.copytree(published, elsewhere)
    receipt = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))
    receipt["components"]["ffmpeg"]["path"] = str(elsewhere)
    receipt["components"]["ffmpeg"]["relpath"] = elsewhere.relative_to(root).as_posix()
    _p, sha = module_registry.write_receipt(root, "drum_kit", receipt)
    module_registry.write_registry_from_receipt(root, "drum_kit", receipt, sha)
    component = _components(module_verify.verify_module("drum_kit", root=root))["ffmpeg"]
    assert component["class"] == "present_failing" and component["reason_code"] == "ffmpeg_pin_mismatch"
    assert module_verify.s6_ffmpeg_pair(root)[0] == "refused"


@pytest.mark.native_publication
def test_registry_validation_and_torn_state_know_the_pair(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch)
    assert _install(root, facts)[0] == 0
    registry_path = module_registry.registry_path(root)
    registry = json.loads(registry_path.read_text(encoding="utf-8"))

    for key in ("path", "relpath", "ownership", "pin_id", "tree_sha256"):
        torn = json.loads(json.dumps(registry))
        torn["modules"]["drum_kit"]["components"]["ffmpeg"][key] = "different"
        registry_path.write_text(json.dumps(torn), encoding="utf-8")
        status, receipt, reason = module_registry.read_and_validate_module_record(root, "drum_kit")
        assert (status, receipt, reason) == ("unverifiable", None, f"registry_component_mismatch:ffmpeg:{key}")
    torn = json.loads(json.dumps(registry))
    torn["modules"]["drum_kit"]["components"]["ffmpeg"] = None
    registry_path.write_text(json.dumps(torn), encoding="utf-8")
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[2] == "registry_component_invalid:ffmpeg"
    torn["modules"]["drum_kit"]["components"]["ffmpeg"] = "text"
    registry_path.write_text(json.dumps(torn), encoding="utf-8")
    assert module_registry.read_and_validate_module_record(root, "drum_kit")[2] == "registry_component_invalid:ffmpeg"

    # Unreadable state makes the pair UNVERIFIABLE, not absent.
    doc = module_verify.verify_module("drum_kit", root=root)
    assert doc["installation_state"] == "unknown"
    assert _components(doc)["ffmpeg"]["class"] == "unverifiable"
    assert module_verify.UnverifiableRegistryLookup("x")
    with pytest.raises(module_verify.ComponentLookupError):
        module_verify.UnverifiableRegistryLookup("x").locate("drum_kit", "ffmpeg")
    assert module_verify.s6_ffmpeg_pair(root)[0] == "refused"

    # A receipt whose pair entry is not an object is not a receipt.
    registry_path.write_text(json.dumps(registry), encoding="utf-8")
    receipt = json.loads(module_registry.receipt_path(root, "drum_kit").read_text(encoding="utf-8"))
    for bad in ({"no": "path"}, "text", 7):
        receipt["components"]["ffmpeg"] = bad
        with pytest.raises(module_registry.RegistryError):
            module_registry._validate_receipt_structure(receipt, "drum_kit")
    receipt["components"]["ffmpeg"] = None
    assert module_registry._validate_receipt_structure(receipt, "drum_kit")


@POSIX_ONLY
def test_verify_runs_the_probe_so_a_hash_correct_but_broken_pair_is_repair_required(tmp_path, monkeypatch):
    # The installer's own probe is stubbed for this defective pair, as if only the hashes had been checked.
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, mode="nocodec")
    assert _install(root, facts)[0] == 0
    monkeypatch.setattr(managed_ffmpeg, "probe_pair", REAL_PROBE)
    doc = module_verify.verify_module("drum_kit", root=root)
    component = _components(doc)["ffmpeg"]
    assert doc["installation_state"] == "repair_required"
    assert component["class"] == "present_failing" and component["reason_code"] == "probe_command_failed"
    # The guard used by the worker does not run the probe; readiness does.
    assert module_verify.s6_ffmpeg_pair(root)[0] == "verified"
    assert module_verify.s6_ffmpeg_pair(root, probe=True)[0] == "refused"
    broken = _readiness_for(root, tmp_path, monkeypatch)["components"]["ffmpeg"]
    assert broken["verdict"] == FAIL and "probe_command_failed" in broken["reason"]


@pytest.mark.native_publication
def test_an_unreceipted_pair_location_is_unverifiable_not_adopted(tmp_path):
    component = next(c for c in module_verify.module_descriptors.DIRECT_KIT.components if c.component_id == "ffmpeg")
    verdict = module_verify.verify_ffmpeg_component(component, module_verify.ComponentLocation(tmp_path))
    assert verdict.component_class == module_verify.UNVERIFIABLE
    assert verdict.reason_code == module_verify.REASON_VERIFIER_UNAVAILABLE


# --- 8. Worker and helper use our pair and nothing else (C19) ---------------


def _fake_system_ffmpeg(tmp_path):
    system = tmp_path / "system-bin"
    system.mkdir()
    for tool in ("ffmpeg", "ffprobe"):
        script = system / tool
        script.write_text(f"#!/bin/sh\necho SYSTEM-{tool}\n", encoding="utf-8")
        script.chmod(0o755)
    return system


def _load_worker(tmp_path, monkeypatch):
    script = ROOT / "scripts/reaper/audio_separator_process.py"
    spec = importlib.util.spec_from_file_location(f"stemwerk_s7_worker_{uuid.uuid4().hex}", script)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    helper = tmp_path / "helper.py"
    helper.write_text("# test helper\n", encoding="utf-8")
    monkeypatch.setattr(worker, "_drumsep_helper_path", lambda: helper)
    (tmp_path / "output").mkdir(exist_ok=True)
    return worker


def _banner(env, tool):
    done = REAL_RUN([tool, "-version"], env=env, capture_output=True, text=True, check=False)
    assert done.stdout, (done.returncode, done.stderr, env.get("PATH"))
    return done.stdout.splitlines()[0]


@POSIX_ONLY
def test_worker_and_helper_use_our_pair_with_a_system_ffmpeg_first_on_path_and_user_overrides_set(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, real_probe=True)
    assert _install(root, facts)[0] == 0
    pin = managed_ffmpeg.load_pin()
    pair_bin = root / "runtimes" / "ffmpeg" / pin.pin_id / "bin"
    system = _fake_system_ffmpeg(tmp_path)
    monkeypatch.setenv("STEMWERK_RUNTIME_ROOT", str(root))
    monkeypatch.setenv("PATH", os.pathsep.join([str(system), "/usr/bin", "/bin"]))
    for name in (*managed_ffmpeg.FFMPEG_ENV_VARS, *managed_ffmpeg.FFPROBE_ENV_VARS):
        monkeypatch.setenv(name, str(system / "ffmpeg"))
    assert _banner(os.environ, "ffmpeg") == "SYSTEM-ffmpeg"  # the trap is set

    worker = _load_worker(tmp_path, monkeypatch)
    path, wrapper, prefix = worker._configure_ffmpeg_runtime()
    assert path == pair_bin / "ffmpeg" and wrapper is None and prefix == str(pair_bin)
    assert os.environ["PATH"].split(os.pathsep)[0] == str(pair_bin)
    for name in managed_ffmpeg.FFMPEG_ENV_VARS:
        assert os.environ[name] == str(pair_bin / "ffmpeg")
    for name in managed_ffmpeg.FFPROBE_ENV_VARS:
        assert os.environ[name] == str(pair_bin / "ffprobe")
    for tool in ("ffmpeg", "ffprobe"):
        assert shutil.which(tool) == str(pair_bin / tool)
        assert _banner(os.environ, tool).startswith(f"{tool} version {pin.version} ")

    # The Direct Kit helper: its own PATH and variables, not the worker's.
    venv_python = Path(json.loads(module_registry.receipt_path(root, "drum_kit").read_text())["components"]["module_venv"]["path"]) / "bin" / "python"
    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", lambda _p: (True, "verified"))
    monkeypatch.setenv("PATH", os.pathsep.join([str(system), "/usr/bin", "/bin"]))  # as if the worker had not set it
    for name in (*managed_ffmpeg.FFMPEG_ENV_VARS, *managed_ffmpeg.FFPROBE_ENV_VARS):
        monkeypatch.setenv(name, str(system / "ffmpeg"))

    class Spawned(Exception):
        def __init__(self, env):
            self.env = env

    def fake_popen(cmd, **kwargs):
        raise Spawned(kwargs["env"])

    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(worker.tempfile, "tempdir", str(scratch))
    with monkeypatch.context() as spawning:  # worker.subprocess is the shared module: restore Popen afterwards
        spawning.setattr(worker.subprocess, "Popen", fake_popen)
        with pytest.raises(Spawned) as spawned:
            worker._run_direct_dks_drumsep_helper(tmp_path / "in.wav", tmp_path / "output", tmp_path / "models",
                                                  venv_python, "model", "model", device="cpu")
    env = spawned.value.env
    assert env["PATH"].split(os.pathsep)[0] == str(pair_bin)
    for tool in ("ffmpeg", "ffprobe"):
        assert _banner(env, tool).startswith(f"{tool} version {pin.version} ")
    for name in managed_ffmpeg.FFMPEG_ENV_VARS:
        assert env[name] == str(pair_bin / "ffmpeg")
    for name in managed_ffmpeg.FFPROBE_ENV_VARS:
        assert env[name] == str(pair_bin / "ffprobe")


@POSIX_ONLY
def test_helper_refuses_to_start_without_a_verified_pair_and_never_falls_back_to_the_system(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, real_probe=True)
    assert _install(root, facts)[0] == 0
    pin = managed_ffmpeg.load_pin()
    published = root / "runtimes" / "ffmpeg" / pin.pin_id
    system = _fake_system_ffmpeg(tmp_path)
    monkeypatch.setenv("PATH", os.pathsep.join([str(system), "/usr/bin", "/bin"]))
    monkeypatch.setenv("STEMWERK_FFMPEG_PATH", str(system / "ffmpeg"))
    venv_python = Path(json.loads(module_registry.receipt_path(root, "drum_kit").read_text())["components"]["module_venv"]["path"]) / "bin" / "python"
    worker = _load_worker(tmp_path, monkeypatch)
    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", lambda _p: (True, "verified"))
    monkeypatch.setattr(worker.subprocess, "Popen", lambda *a, **k: pytest.fail("a job started without a verified pair"))

    def run():
        return worker._run_direct_dks_drumsep_helper(tmp_path / "in.wav", tmp_path / "output", tmp_path / "models",
                                                     venv_python, "model", "model", device="cpu")

    (published / "bin" / "ffmpeg").write_bytes((published / "bin" / "ffmpeg").read_bytes() + b"x")  # tampered
    ok, _stems, code, detail = run()
    assert not ok and code == "drumsep_helper_failed" and "S6 FFmpeg verification failed" in detail
    assert "s6_ffmpeg_refused:ffmpeg_" in detail

    shutil.rmtree(published)  # missing altogether: still no system fallback
    ok, _stems, code, detail = run()
    assert not ok and "S6 FFmpeg verification failed" in detail

    monkeypatch.setattr(module_verify, "verify_s6_ffmpeg_for_interpreter", lambda _p: (_ for _ in ()).throw(RuntimeError("boom")))
    ok, _stems, code, detail = run()
    assert not ok and "verification_unavailable:RuntimeError" in detail


@POSIX_ONLY
def test_worker_main_process_keeps_legacy_discovery_only_when_the_registered_pair_is_refused(tmp_path, monkeypatch, capsys):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, real_probe=True)
    assert _install(root, facts)[0] == 0
    published = next((root / "runtimes" / "ffmpeg").iterdir())
    (published / "NOTICE.txt").write_bytes(b"changed\n")
    system = _fake_system_ffmpeg(tmp_path)
    monkeypatch.setenv("STEMWERK_RUNTIME_ROOT", str(root))
    monkeypatch.setenv("PATH", os.pathsep.join([str(system), "/usr/bin"]))
    monkeypatch.setenv("STEMWERK_FFMPEG_PATH", str(system / "ffmpeg"))
    worker = _load_worker(tmp_path, monkeypatch)
    assert worker._registered_ffmpeg_pair()[0] == "refused"
    # Documented limit: the main worker process keeps legacy discovery for a module
    # whose pair did not verify (non-Direct-Kit workflows still use it). The Direct Kit
    # job itself is stopped at the helper (previous test) and by readiness.
    path, _wrapper, _prefix = worker._configure_ffmpeg_runtime()
    assert path == (system / "ffmpeg").resolve()
    assert "ffmpeg_registered_pair_refused=" in capsys.readouterr().err


def test_unregistered_roots_keep_the_legacy_discovery_unchanged(tmp_path, monkeypatch):
    monkeypatch.setenv("STEMWERK_RUNTIME_ROOT", str(tmp_path / "no-registry"))
    worker = _load_worker(tmp_path, monkeypatch)
    assert worker._registered_ffmpeg_pair()[0] == "unregistered"
    legacy = tmp_path / "legacy-ffmpeg"
    legacy.write_bytes(b"#!/bin/sh\n")
    monkeypatch.setenv("STEMWERK_FFMPEG_PATH", str(legacy))
    monkeypatch.setattr(managed_runtime, "candidate_ffmpeg_paths", lambda: [legacy])
    path, _wrapper, _prefix = worker._configure_ffmpeg_runtime()
    assert path == legacy.resolve()
    assert module_verify.verify_s6_ffmpeg_for_interpreter(tmp_path / "venv" / "bin" / "python") == (True, "not_s6_managed", None)


# --- 9. Readiness: no system fallback for a registered module --------------


def _readiness_for(root, tmp_path, monkeypatch):
    asset = tmp_path / "model.ckpt"
    asset.write_bytes(b"model")
    monkeypatch.setattr(managed_runtime, "managed_runtime_root", lambda: root)
    monkeypatch.setattr(readiness_collect, "collect_ffmpeg", lambda: pytest.fail("a registered module must not probe a system FFmpeg"))
    return readiness.assess_readiness(
        ReadinessRequest(workflow_id="drum_kit_direct", requested_device="cpu"),
        catalog_dir=ROOT / "scripts" / "reaper" / "catalog",
        collectors={"drum_kit": lambda _requested: {
            "runtime": {"verdict": PASS, "evidence": {"source": "collected"}},
            "capability": {"verdict": PASS, "resolution": {
                "requested": "cpu", "resolved_device_id": "cpu", "resolved_device_name": "cpu",
                "resolved_backend": "cpu", "selection_info": {"selection_policy": "explicit_cpu"}},
                "evidence": {"source": "collected"}},
        }},
        model_asset_providers={"drumsep_mdx23c": lambda: {
            "base_dir": str(tmp_path),
            "assets": [{"name": asset.name, "sha256": hashlib.sha256(b"model").hexdigest()}]}},
    )


@POSIX_ONLY
def test_readiness_of_a_registered_module_comes_from_its_own_verified_pair(tmp_path, monkeypatch):
    facts, root, _unrelated = _fresh(tmp_path, monkeypatch, real_probe=True)
    assert _install(root, facts)[0] == 0
    report = _readiness_for(root, tmp_path, monkeypatch)
    ffmpeg = report["components"]["ffmpeg"]
    assert ffmpeg["verdict"] == PASS
    assert ffmpeg["evidence"]["evidence_kind"] == "managed_ffmpeg_verification"
    assert ffmpeg["evidence"]["usability"] == "pinned_pair_verified_with_probe"
    assert ffmpeg["path"].endswith("/bin/ffmpeg") and str(root) in ffmpeg["path"]

    published = next((root / "runtimes" / "ffmpeg").iterdir())
    (published / "bin" / "ffprobe").write_bytes(b"#!/bin/sh\nexit 0\n")
    broken = _readiness_for(root, tmp_path, monkeypatch)["components"]["ffmpeg"]
    assert broken["verdict"] == FAIL and broken["reason_code"] == readiness.REASON_FFMPEG_UNAVAILABLE
    assert "ffmpeg_file_size_mismatch" in broken["reason"]


# --- 10. The scheduled pin check (C21) -------------------------------------


def _load_checker():
    spec = importlib.util.spec_from_file_location("check_ffmpeg_pins_under_test", ROOT / "tools" / "check_ffmpeg_pins.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.native_publication
def test_pin_check_passes_on_vendor_data_and_is_red_on_a_broken_pin(monkeypatch, capsys):
    checker = _load_checker()
    pin = managed_ffmpeg.load_pin()
    vendor = f"{pin.archive_sha256}  {pin.archive_name}\n{'f' * 64}  other-file.tar.xz\n"
    calls = []

    def request(url, method="GET"):
        calls.append((method, url))
        if method == "GET":
            return vendor.encode("ascii")
        return 200, {"Content-Length": str(pin.archive_size)}

    monkeypatch.setattr(checker, "_request", request)
    assert checker.main() == 0
    out = capsys.readouterr().out
    assert "pin match" in out and "broken-pin self-test: rejected" in out
    assert calls[0] == ("GET", f"{managed_ffmpeg.DOWNLOAD_BASE}{pin.release_tag}/checksums.sha256")
    assert calls[1] == ("HEAD", pin.archive_url)

    # Red: the vendor's checksum differs from the shipped pin.
    monkeypatch.setattr(checker, "_request", lambda url, method="GET": (
        f"{'0' * 64}  {pin.archive_name}\n".encode("ascii") if method == "GET" else (200, {"Content-Length": str(pin.archive_size)})))
    with pytest.raises(ValueError, match="checksum differs"):
        checker.main()
    # Red: the asset is gone, or its length changed.
    monkeypatch.setattr(checker, "_request", lambda url, method="GET": (
        vendor.encode("ascii") if method == "GET" else (200, {"Content-Length": str(pin.archive_size + 1)})))
    with pytest.raises(ValueError, match="byte length"):
        checker.main()
    monkeypatch.setattr(checker, "_request", lambda url, method="GET": (
        vendor.encode("ascii") if method == "GET" else (404, {"Content-Length": str(pin.archive_size)})))
    with pytest.raises(ValueError, match="byte length"):
        checker.main()
    # Red: a broken shipped pin is rejected by the comparison itself, and a missing entry is not a match.
    with pytest.raises(ValueError):
        checker.check_checksum(dataclasses.replace(pin, archive_sha256="0" * 64), checker.parse_checksums(vendor))
    with pytest.raises(ValueError):
        checker.check_checksum(pin, {})
    # Red: if the comparison were ineffective the self-test would say so.
    monkeypatch.setattr(checker, "check_checksum", lambda *_a: None)
    monkeypatch.setattr(checker, "_request", request)
    with pytest.raises(ValueError, match="self-test unexpectedly passed"):
        checker.main()
    assert checker.parse_checksums("a  b\nnot a line\n\n") == {"b": "a"}


@pytest.mark.native_publication
def test_weekly_workflow_runs_the_ffmpeg_check_as_a_second_step():
    workflow = (ROOT / ".github/workflows/managed-python-pin-check.yml").read_text(encoding="utf-8")
    first = workflow.index("python tools/check_managed_python_pins.py")
    second = workflow.index("python tools/check_ffmpeg_pins.py")
    assert first < second
    assert workflow.count("schedule:") == 1 and workflow.count("jobs:") == 1  # same workflow, no new one
    assert not (ROOT / ".github/workflows/ffmpeg-pin-check.yml").exists()
