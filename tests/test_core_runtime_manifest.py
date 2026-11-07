"""Tests for the pinned managed-runtime manifest (design 6.2; D9, F6, G4)."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import module_install, runtime_manifest as manifest  # noqa: E402

pytestmark = pytest.mark.portable

MANIFEST_PATH = CORE_SRC / "stemwerk_core" / manifest.MANIFEST_FILENAME
BASE = "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/"

# Independent copy of the F6 candidate (design appendix A.3), checked against
# upstream SHA256SUMS and the release API for build 20261026 when pinned.
EXPECTED = {
    "linux-x86_64": (
        BASE + "cpython-3.12.16%2B20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
        34_505_639,
        "ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20",
    ),
    "darwin-arm64": (
        BASE + "cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz",
        25_035_343,
        "353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e",
    ),
    "win-x86_64": (
        BASE + "cpython-3.12.16%2B20261026-x86_64-pc-windows-msvc-install_only_stripped.tar.gz",
        22_014_416,
        "1f2ab53880fc67ea323398c6388e05af28addc99a8e389209f08a51fdff4b149",
    ),
}


def committed() -> bytes:
    return MANIFEST_PATH.read_bytes()


def lines(data: bytes) -> list:
    return data.decode("ascii").split("\n")[:-1]


def rebuild(header: str, records: list) -> bytes:
    return ("\n".join([header, *records]) + "\n").encode("ascii")


# --- the committed manifest -----------------------------------------------


@pytest.mark.native_publication
def test_committed_manifest_is_exactly_the_f6_pins_with_lf_endings():
    data = committed()
    assert b"\r" not in data  # holds on a Windows checkout too (.gitattributes)
    records = manifest.parse_manifest(data)
    assert [record.platform for record in records] == list(manifest.PLATFORMS)
    for record in records:
        assert record.name == "python-3.12.16-20261026"
        assert (record.version, record.build, record.component) == ("3.12.16", "20261026", "python")
        assert (record.url, record.size, record.sha256) == EXPECTED[record.platform]


@pytest.mark.native_publication
def test_shipped_manifest_is_read_through_the_package():
    assert manifest.manifest_bytes() == committed()
    assert manifest.load_manifest() == manifest.parse_manifest(committed())


def test_route_platforms_are_the_module_cli_platforms():
    assert manifest.PLATFORMS == module_install.PLATFORMS
    assert set(manifest.PBS_TARGETS) == set(manifest.PLATFORMS)


def test_gitattributes_keeps_the_manifest_lf():
    rules = (ROOT / ".gitattributes").read_bytes().decode("ascii").splitlines()
    assert (
        "scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/runtime-manifest.v1.tsv text eol=lf"
        in rules
    )


def test_manifest_is_package_data():
    pyproject = (CORE_SRC.parent / "pyproject.toml").read_text(encoding="utf-8")
    assert (
        '"stemwerk_core" = ["runtime-manifest.v1.tsv", "wheel-lock-linux-x86_64-cpu.v1.json"]'
        in pyproject
    )


@pytest.mark.skipif(shutil.which("sh") is None, reason="needs a POSIX sh")
def test_posix_sh_reads_the_same_records_without_extra_tools():
    # G4: the outer layer reads the file with sh builtins only.
    script = (
        'tab=$(printf "\\t")\n'
        "{ IFS= read -r header; printf 'H|%s\\n' \"$header\";"
        ' while IFS="$tab" read -r platform name url size sha; do'
        " printf 'R|%s|%s|%s|%s|%s\\n' \"$platform\" \"$name\" \"$url\" \"$size\" \"$sha\"; done; } < \"$1\"\n"
    )
    result = subprocess.run(
        ["sh", "-c", script, "sh", str(MANIFEST_PATH)], capture_output=True, timeout=30, check=True
    )
    rows = result.stdout.decode("ascii").splitlines()
    assert rows[0] == f"H|{manifest.MANIFEST_PROTOCOL}"
    expected = [
        f"R|{r.platform}|{r.name}|{r.url}|{r.size}|{r.sha256}" for r in manifest.load_manifest()
    ]
    assert rows[1:] == expected


# --- grammar ------------------------------------------------------------------


def _swap(field: int, value: str, line: int = 0):
    def change(records):
        fields = records[line].split("\t")
        fields[field] = value
        records[line] = "\t".join(fields)
        return records

    return change


MALFORMED = {
    "bom": lambda data: b"\xef\xbb\xbf" + data,
    "crlf": lambda data: data.replace(b"\n", b"\r\n"),
    "no_final_lf": lambda data: data[:-1],
    "non_ascii": lambda data: data.replace(b"python-3.12.16", "pythön-3.12.16".encode(), 1),
    "empty_line": lambda data: data + b"\n",
    "trailing_space": lambda data: data[:-1] + b" \n",
}
RECORD_CHANGES = {
    "extra_field": lambda records: [records[0] + "\textra", *records[1:]],
    "missing_field": lambda records: ["\t".join(records[0].split("\t")[:4]), *records[1:]],
    "empty_field": _swap(1, ""),
    "unknown_platform": _swap(0, "linux-aarch64"),
    "intel_mac_parked": _swap(0, "darwin-x86_64"),
    "python_313": _swap(1, "python-3.13.1-20261026"),
    "latest": _swap(1, "python-latest"),
    "unpinned_build": _swap(1, "python-3.12.16"),
    "other_build_in_url": _swap(2, EXPECTED["linux-x86_64"][0].replace("download/20261026", "download/20261027")),
    "other_flavour": _swap(2, EXPECTED["linux-x86_64"][0].replace("install_only_stripped", "install_only")),
    "other_target": _swap(2, EXPECTED["darwin-arm64"][0]),
    "plain_http": _swap(2, EXPECTED["linux-x86_64"][0].replace("https://", "http://")),
    "other_host": _swap(2, EXPECTED["linux-x86_64"][0].replace("github.com", "example.com")),
    "unescaped_plus": _swap(2, EXPECTED["linux-x86_64"][0].replace("%2B", "+")),
    "size_zero": _swap(3, "0"),
    "size_leading_zero": _swap(3, "034505639"),
    "size_negative": _swap(3, "-1"),
    "size_not_decimal": _swap(3, "34_505_639"),
    "sha_uppercase": _swap(4, EXPECTED["linux-x86_64"][2].upper()),
    "sha_short": _swap(4, EXPECTED["linux-x86_64"][2][:63]),
    "duplicate_platform": lambda records: [records[0], records[0], *records[1:]],
    "missing_platform": lambda records: records[:2],
}


@pytest.mark.parametrize("change", sorted(MALFORMED))
def test_malformed_files_are_refused(change):
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.parse_manifest(MALFORMED[change](committed()))
    assert refused.value.code == "manifest_invalid"


@pytest.mark.parametrize("change", sorted(RECORD_CHANGES))
def test_malformed_records_are_refused(change):
    header, *records = lines(committed())
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.parse_manifest(rebuild(header, RECORD_CHANGES[change](list(records))))
    assert refused.value.code == "manifest_invalid"


@pytest.mark.parametrize("header", ["stemwerk-runtime-manifest/2", "stemwerk-runtime-manifest/1\t", ""])
def test_only_the_version_1_header_is_accepted(header):
    _, *records = lines(committed())
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.parse_manifest(rebuild(header, records))
    assert refused.value.code == "manifest_invalid"
    assert refused.value.line == 1


def test_record_order_does_not_matter_and_line_numbers_are_reported():
    header, *records = lines(committed())
    reordered = manifest.parse_manifest(rebuild(header, list(reversed(records))))
    assert {r.platform for r in reordered} == set(manifest.PLATFORMS)
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.parse_manifest(rebuild(header, [records[0], records[1], _swap(3, "0")([records[2]])[0]]))
    assert refused.value.line == 4


# --- record selection --------------------------------------------------------


@pytest.mark.parametrize("platform_id", ["linux-x86_64", "darwin-arm64", "win-x86_64"])
def test_python_record_per_route_platform(platform_id):
    record = manifest.python_record(platform_id)
    assert record.platform == platform_id
    assert (record.url, record.size, record.sha256) == EXPECTED[platform_id]


@pytest.mark.parametrize("platform_id", [None, "darwin-x86_64", "linux-aarch64", "win-arm64"])
def test_platform_outside_the_route_has_no_python(platform_id):
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.python_record(platform_id)
    assert refused.value.code == "platform_unsupported"
    assert refused.value.details["supported"] == list(manifest.PLATFORMS)


def test_published_directory_is_named_after_the_record(tmp_path):
    record = manifest.python_record("linux-x86_64")
    assert manifest.published_directory(tmp_path, record) == (
        tmp_path / "runtimes" / "python" / "python-3.12.16-20261026"
    )


# --- archive check: size, then SHA-256 ----------------------------------------


def record_for(data: bytes) -> manifest.RuntimeRecord:
    pinned = manifest.python_record("linux-x86_64")
    return manifest.RuntimeRecord(
        pinned.platform, pinned.name, pinned.url, len(data), hashlib.sha256(data).hexdigest(),
        pinned.component, pinned.version, pinned.build,
    )


PAYLOAD = b"pinned archive bytes\x00" * 4096


@pytest.mark.native_publication
def test_exact_archive_passes(tmp_path):
    archive = tmp_path / "python.tar.gz"
    archive.write_bytes(PAYLOAD)
    record = record_for(PAYLOAD)
    assert manifest.check_archive(archive, record) == {"size": len(PAYLOAD), "sha256": record.sha256}


@pytest.mark.native_publication
@pytest.mark.parametrize("data", [PAYLOAD[:-1], PAYLOAD + b"x", b""], ids=["truncated", "oversized", "empty"])
def test_wrong_size_is_refused_before_hashing(tmp_path, monkeypatch, data):
    archive = tmp_path / "python.tar.gz"
    archive.write_bytes(data)
    record = record_for(PAYLOAD)

    def no_hashing(*args):
        raise AssertionError("a wrong size must be refused without hashing")

    monkeypatch.setattr(manifest.hashlib, "sha256", no_hashing)
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.check_archive(archive, record)
    assert refused.value.code == "archive_size_mismatch"
    assert refused.value.details == {"observed": len(data), "expected": len(PAYLOAD)}


@pytest.mark.native_publication
def test_same_size_other_bytes_is_a_hash_mismatch(tmp_path):
    archive = tmp_path / "python.tar.gz"
    tampered = bytearray(PAYLOAD)
    tampered[len(tampered) // 2] ^= 1
    archive.write_bytes(bytes(tampered))
    record = record_for(PAYLOAD)
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.check_archive(archive, record)
    assert refused.value.code == "archive_sha256_mismatch"
    assert refused.value.details["expected"] == record.sha256
    assert refused.value.details["observed"] == hashlib.sha256(bytes(tampered)).hexdigest()


@pytest.mark.native_publication
def test_missing_archive_or_directory_is_unavailable(tmp_path):
    record = record_for(PAYLOAD)
    for path in (tmp_path / "absent.tar.gz", tmp_path):
        with pytest.raises(manifest.ManifestError) as refused:
            manifest.check_archive(path, record)
        assert refused.value.code == "archive_unavailable"


@pytest.mark.skipif(os.name == "nt", reason="symbolic links need privileges on Windows")
def test_linked_archive_is_refused(tmp_path):
    real = tmp_path / "real.tar.gz"
    real.write_bytes(PAYLOAD)
    link = tmp_path / "python.tar.gz"
    link.symlink_to(real)
    with pytest.raises(manifest.ManifestError) as refused:
        manifest.check_archive(link, record_for(PAYLOAD))
    assert refused.value.code == "archive_unavailable"
