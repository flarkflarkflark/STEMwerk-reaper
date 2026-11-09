"""Tests for the read-only verification of a published managed Python."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import managed_python as mp, runtime_manifest  # noqa: E402

pytestmark = pytest.mark.portable

POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="POSIX links and special files")


def record(platform_id: str = "linux-x86_64") -> runtime_manifest.RuntimeRecord:
    return runtime_manifest.python_record(platform_id)


def runtime(root: Path, platform_id: str = "linux-x86_64") -> Path:
    """A published tree with the pinned layout (contents are not executed)."""

    directory = runtime_manifest.published_directory(root, record(platform_id))
    (directory / "lib" / "python3.12").mkdir(parents=True)
    (directory / "lib" / "python3.12" / "os.py").write_text("# stdlib\n", encoding="utf-8")
    interpreter = mp.interpreter_path(directory, platform_id)
    interpreter.parent.mkdir(parents=True, exist_ok=True)
    interpreter.write_bytes(b"\x7fELF")
    return directory


class Runner:
    """Stands in for subprocess.run and records its calls."""

    def __init__(self, report=None, *, returncode=0, stdout=None, raises=None):
        self.report, self.returncode, self.stdout, self.raises = report, returncode, stdout, raises
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if self.raises is not None:
            raise self.raises
        out = self.stdout if self.stdout is not None else json.dumps(self.report).encode("ascii")
        return subprocess.CompletedProcess(command, self.returncode, out, b"")


def good_report(directory: Path, platform_id: str = "linux-x86_64", **changes):
    machine = {"linux-x86_64": "x86_64", "darwin-arm64": "arm64", "win-x86_64": "AMD64"}[platform_id]
    report = {
        "implementation": "cpython",
        "version": "3.12.16",
        "machine": machine,
        "pointer_bits": 64,
        "prefix": str(directory),
        "isolated": 1,
    }
    report.update(changes)
    return report


def codes(document):
    return [reason["code"] for reason in document["reasons"]]


# --- location and tree, before anything runs -----------------------------------


def test_absent_runtime_is_reported_and_nothing_runs(tmp_path):
    runner = Runner()
    document = mp.verify_managed_python(tmp_path / "root", record(), run=runner)
    assert document["status"] == mp.ABSENT
    assert document["path"] == str(tmp_path / "root" / "runtimes" / "python" / "python-3.12.16-20261026")
    assert runner.calls == []


def test_relative_root_is_ineligible():
    document = mp.verify_managed_python("relative/root", record(), run=Runner())
    assert document["status"] == mp.INVALID
    assert codes(document) == ["runtime_path_ineligible"]


@POSIX_ONLY
def test_linked_runtime_directory_is_refused(tmp_path):
    root = tmp_path / "root"
    elsewhere = runtime(tmp_path / "elsewhere")
    target = runtime_manifest.published_directory(root, record())
    target.parent.mkdir(parents=True)
    target.symlink_to(elsewhere, target_is_directory=True)
    runner = Runner(good_report(elsewhere))
    document = mp.verify_managed_python(root, record(), run=runner)
    assert codes(document) == ["runtime_path_ineligible"]
    assert runner.calls == []


@pytest.mark.native_publication
def test_missing_interpreter_is_refused_without_running(tmp_path):
    directory = runtime(tmp_path)
    mp.interpreter_path(directory, "linux-x86_64").unlink()
    runner = Runner(good_report(directory))
    document = mp.verify_managed_python(tmp_path, record(), run=runner)
    assert codes(document) == ["interpreter_missing"]
    assert runner.calls == []


@POSIX_ONLY
def test_internal_relative_links_are_allowed(tmp_path):
    directory = runtime(tmp_path)
    (directory / "bin" / "python3").symlink_to("python3.12")
    (directory / "lib" / "libpython.so").symlink_to("python3.12/os.py")
    (directory / "lib" / "self").symlink_to("..")
    runner = Runner(good_report(directory))
    assert mp.verify_managed_python(tmp_path, record(), run=runner)["status"] == mp.VERIFIED


@POSIX_ONLY
@pytest.mark.parametrize(
    "name, target, code",
    [
        ("escape", "../../../outside", "link_escapes_runtime"),
        ("absolute", "/etc/passwd", "absolute_link"),
        # lib/up resolves to the runtime itself, so up/../x is outside at run time
        # although "lib/up/../../x" looks inside lexically.
        ("chained", "up/../../x", "link_escapes_runtime"),
    ],
)
def test_links_that_leave_the_runtime_are_refused_without_running(tmp_path, name, target, code):
    directory = runtime(tmp_path)
    (directory / "lib" / "up").symlink_to("..")
    (directory / "lib" / name).symlink_to(target)
    runner = Runner(good_report(directory))
    document = mp.verify_managed_python(tmp_path, record(), run=runner)
    assert code in codes(document)
    assert runner.calls == []


@POSIX_ONLY
def test_hard_links_and_special_files_are_refused(tmp_path):
    directory = runtime(tmp_path)
    os.link(directory / "lib" / "python3.12" / "os.py", directory / "lib" / "copy.py")
    os.mkfifo(directory / "lib" / "fifo")
    runner = Runner(good_report(directory))
    document = mp.verify_managed_python(tmp_path, record(), run=runner)
    assert sorted(codes(document)) == ["hard_link", "hard_link", "special_file"]
    assert runner.calls == []


@POSIX_ONLY
def test_windows_runtime_allows_no_links_at_all(tmp_path):
    directory = runtime(tmp_path, "win-x86_64")
    (directory / "lib" / "inner").symlink_to("python3.12")
    runner = Runner(good_report(directory, "win-x86_64"))
    document = mp.verify_managed_python(tmp_path, record("win-x86_64"), run=runner, os_name="nt")
    assert codes(document) == ["link_not_allowed"]
    assert runner.calls == []


# --- interpreter identity -------------------------------------------------------


@pytest.mark.native_publication
def test_pinned_interpreter_is_verified(tmp_path):
    directory = runtime(tmp_path)
    runner = Runner(good_report(directory))
    document = mp.verify_managed_python(tmp_path, record(), run=runner)
    assert document["status"] == mp.VERIFIED
    assert document["reasons"] == []
    assert document["interpreter"]["version"] == "3.12.16"
    (command, kwargs), = runner.calls
    assert command[:4] == [str(mp.interpreter_path(directory, "linux-x86_64")), "-I", "-B", "-c"]
    assert kwargs["stdin"] == subprocess.DEVNULL
    assert kwargs["timeout"] == mp.DEFAULT_TIMEOUT


@pytest.mark.parametrize(
    "changes, code",
    [
        ({"implementation": "pypy"}, "implementation_mismatch"),
        ({"version": "3.12.13"}, "version_mismatch"),
        ({"version": "3.12.16+"}, "version_mismatch"),
        ({"machine": "aarch64"}, "architecture_mismatch"),
        ({"machine": None}, "architecture_mismatch"),
        ({"pointer_bits": 32}, "pointer_size_mismatch"),
        ({"isolated": 0}, "not_isolated"),
        ({"prefix": "/usr"}, "prefix_mismatch"),
    ],
)
def test_interpreter_identity_mismatches_are_named(tmp_path, changes, code):
    directory = runtime(tmp_path)
    document = mp.verify_managed_python(tmp_path, record(), run=Runner(good_report(directory, **changes)))
    assert document["status"] == mp.INVALID
    assert codes(document) == [code]


@pytest.mark.parametrize("platform_id", ["linux-x86_64", "darwin-arm64", "win-x86_64"])
def test_architecture_names_per_platform(tmp_path, platform_id):
    directory = runtime(tmp_path, platform_id)
    accepted = mp.verify_managed_python(
        tmp_path, record(platform_id), run=Runner(good_report(directory, platform_id)), os_name="posix"
    )
    assert accepted["status"] == mp.VERIFIED
    refused = mp.verify_managed_python(
        tmp_path, record(platform_id), run=Runner(good_report(directory, platform_id, machine="i686")),
        os_name="posix",
    )
    assert codes(refused) == ["architecture_mismatch"]


@pytest.mark.parametrize(
    "runner, code",
    [
        (Runner(returncode=1, stdout=b""), "interpreter_failed"),
        (Runner(raises=OSError(8, "Exec format error")), "interpreter_failed"),
        (Runner(raises=subprocess.TimeoutExpired("python", 60)), "interpreter_timeout"),
        (Runner(stdout=b"not json"), "interpreter_output_invalid"),
        (Runner(stdout=b"[1, 2]"), "interpreter_output_invalid"),
        (Runner(stdout="{\"version\": \"3.12.16é\"}".encode("utf-8")), "interpreter_output_invalid"),
    ],
)
def test_interpreter_failures_are_named(tmp_path, runner, code):
    runtime(tmp_path)
    document = mp.verify_managed_python(tmp_path, record(), run=runner)
    assert document["status"] == mp.INVALID
    assert codes(document) == [code]


@pytest.mark.native_publication
def test_real_probe_reports_this_interpreter():
    probe = mp.probe_interpreter(sys.executable, timeout=60)
    report = probe["report"]
    assert report["implementation"] == sys.implementation.name
    assert report["version"] == platform.python_version()
    assert report["machine"] == platform.machine()
    assert report["isolated"] == 1
    assert os.path.realpath(report["prefix"]) == os.path.realpath(sys.prefix)


@pytest.mark.native_publication
def test_real_probe_of_a_missing_executable_fails_cleanly(tmp_path):
    assert mp.probe_interpreter(tmp_path / "no-python")["error"] == "interpreter_failed"


@pytest.mark.native_publication
def test_verification_writes_nothing(tmp_path):
    directory = runtime(tmp_path)

    def snapshot():
        return sorted((str(p.relative_to(tmp_path)), p.stat().st_mtime_ns) for p in tmp_path.rglob("*"))

    before = snapshot()
    mp.verify_managed_python(tmp_path, record(), run=Runner(good_report(directory)))
    mp.verify_managed_python(tmp_path / "other", record(), run=Runner())
    assert snapshot() == before
