import io
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
PROCESS_SCRIPT = ROOT / "scripts/reaper/audio_separator_process.py"
FORBIDDEN_BUILD_HOST_PATHS = (
    "/home/flark",
    "/Users/flark",
    "/mnt/PRODUCTION/GIT",
)
COLLECTED_HOST_PLATFORM = sys.platform
COLLECTED_SUBPROCESS_RUN = subprocess.run
COLLECTED_SUBPROCESS_POPEN = subprocess.Popen
COLLECTED_ENVIRONMENT = dict(os.environ)


@pytest.fixture(autouse=True)
def _isolate_host_process_state(monkeypatch):
    monkeypatch.setattr(sys, "platform", COLLECTED_HOST_PLATFORM)
    monkeypatch.setattr(subprocess, "run", COLLECTED_SUBPROCESS_RUN)
    monkeypatch.setattr(subprocess, "Popen", COLLECTED_SUBPROCESS_POPEN)
    monkeypatch.setattr(os, "environ", COLLECTED_ENVIRONMENT.copy())
    monkeypatch.chdir(ROOT)


def _run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd or ROOT,
        check=True,
        text=True,
        capture_output=True,
    )


def test_tracked_python_shebangs_are_not_user_specific():
    tracked = _run("git", "ls-files", "*.py").stdout.splitlines()
    offenders = []
    for relative in tracked:
        first_line = (ROOT / relative).read_text(encoding="utf-8", errors="replace").splitlines()[:1]
        if first_line and first_line[0].startswith("#!") and any(
            path in first_line[0] for path in FORBIDDEN_BUILD_HOST_PATHS
        ):
            offenders.append(f"{relative}:{first_line[0]}")
    assert offenders == []


def test_audio_process_has_no_user_specific_interpreter_path():
    script = PROCESS_SCRIPT.read_text(encoding="utf-8")
    assert "/home/flark" not in script
    assert not script.startswith("#!")


def test_linux_staged_payload_has_no_build_checkout_or_user_paths(tmp_path):
    staged = tmp_path / "payload"
    command = (
        f'source "{ROOT / "installer/linux/stage_payload.sh"}"; '
        f'copy_linux_payload "{ROOT}" "{staged}"'
    )
    _run("bash", "-c", command)

    offenders = []
    for path in staged.rglob("*"):
        if not path.is_file():
            continue
        content = path.read_bytes()
        for forbidden in FORBIDDEN_BUILD_HOST_PATHS:
            if forbidden.encode() in content:
                offenders.append(f"{path.relative_to(staged)}:{forbidden}")
    assert offenders == []


def test_linux_staged_payload_contains_all_statically_detected_or_dynamic_dependencies(tmp_path):
    from tools import release_gate

    staged = tmp_path / "payload"
    command = (
        f'source "{ROOT / "installer/linux/stage_payload.sh"}"; '
        f'copy_linux_payload "{ROOT}" "{staged}"'
    )
    _run("bash", "-c", command)

    deps: set[str] = set()
    for lua_file in release_gate.iter_lua_files(ROOT):
        text = release_gate.read_text(lua_file)
        found, _ = release_gate.extract_internal_deps(ROOT, lua_file, text)
        deps.update(found)
    deps.update(release_gate.collect_dynamic_production_dependencies(ROOT))

    missing = sorted(
        dep
        for dep in deps
        if not (staged / dep[len("scripts/reaper/"):]).exists()
    )
    assert not missing, f"Linux staged payload missing statically detected or declared dynamic-dispatch runtime deps: {missing}"


def test_managed_python_invocation_remains_explicit_across_platforms():
    main_lua = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    setup_lua = (ROOT / "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(
        encoding="utf-8"
    )
    assert "quoteArg(PYTHON_PATH),\n        quoteArg(SEPARATOR_SCRIPT)," in main_lua
    assert 'set -- "$PY" -u "$SEP"' in main_lua
    assert "Start-Process -FilePath $py -ArgumentList $args" in main_lua
    assert 'quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript)' in setup_lua


def test_macos_and_windows_bootstraps_still_select_python_explicitly():
    macos = (ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text(encoding="utf-8")
    windows = (ROOT / "scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    assert '"${_py}" - <<PY' in macos
    assert "PythonPath" in windows
    assert "audio_separator_process.py" not in windows or "python" in windows.lower()


@pytest.mark.skipif(
    shutil.which("rpmbuild") is None or shutil.which("rpm") is None,
    reason="RPM tools unavailable",
)
def test_rpm_autorequires_and_content_have_no_user_home_dependency(tmp_path):
    top = tmp_path / "rpmbuild"
    for name in ("BUILD", "RPMS", "SOURCES", "SPECS", "SRPMS"):
        (top / name).mkdir(parents=True)
    source_root = tmp_path / "stemwerk-portability-1"
    source_root.mkdir()
    shutil.copy2(PROCESS_SCRIPT, source_root / PROCESS_SCRIPT.name)
    archive = top / "SOURCES/stemwerk-portability-1.tar.gz"
    _run("tar", "-C", str(tmp_path), "-czf", str(archive), source_root.name)
    spec = top / "SPECS/stemwerk-portability.spec"
    spec.write_text(
        """Name: stemwerk-portability
Version: 1
Release: 1
Summary: STEMwerk portability fixture
License: MIT
Source0: stemwerk-portability-1.tar.gz
BuildArch: noarch
%description
fixture
%prep
%setup -q
%install
mkdir -p %{buildroot}/usr/share/stemwerk
cp -a audio_separator_process.py %{buildroot}/usr/share/stemwerk/
%files
/usr/share/stemwerk/audio_separator_process.py
""",
        encoding="utf-8",
    )
    _run("rpmbuild", "--define", f"_topdir {top}", "-bb", str(spec))
    rpm_path = next((top / "RPMS").rglob("*.rpm"))
    requires = _run("rpm", "-qp", "--requires", str(rpm_path)).stdout.splitlines()
    assert not any(requirement.startswith("/home/") for requirement in requires)
    rpm_stream = subprocess.Popen(("rpm2cpio", str(rpm_path)), stdout=subprocess.PIPE)
    process = subprocess.run(
        ("cpio", "-i", "--quiet", "--to-stdout", "./usr/share/stemwerk/audio_separator_process.py"),
        stdin=rpm_stream.stdout,
        check=True,
        capture_output=True,
    )
    assert rpm_stream.stdout is not None
    rpm_stream.stdout.close()
    assert rpm_stream.wait() == 0
    assert not any(path.encode() in process.stdout for path in FORBIDDEN_BUILD_HOST_PATHS)


def test_deb_builder_enforces_root_archive_ownership():
    builder = (ROOT / "installer/linux/build_deb.sh").read_text(encoding="utf-8")
    assert "dpkg-deb --root-owner-group --build" in builder


@pytest.mark.skipif(shutil.which("dpkg-deb") is None, reason="dpkg-deb unavailable")
def test_dpkg_root_owner_group_contract_produces_root_owned_data(tmp_path):
    package_root = tmp_path / "root"
    (package_root / "DEBIAN").mkdir(parents=True)
    (package_root / "usr/share/stemwerk").mkdir(parents=True)
    (package_root / "DEBIAN/control").write_text(
        "Package: stemwerk-portability\nVersion: 1\nArchitecture: all\n"
        "Maintainer: STEMwerk\nDescription: fixture\n",
        encoding="utf-8",
    )
    (package_root / "usr/share/stemwerk/payload.txt").write_text("fixture\n", encoding="utf-8")
    package = tmp_path / "fixture.deb"
    _run("dpkg-deb", "--root-owner-group", "--build", str(package_root), str(package))
    archive = subprocess.run(
        ("dpkg-deb", "--fsys-tarfile", str(package)),
        check=True,
        capture_output=True,
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:*") as data:
        assert all(member.uid == 0 and member.gid == 0 for member in data.getmembers())
