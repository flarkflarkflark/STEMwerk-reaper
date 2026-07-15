import importlib.util
import json
import shutil
import subprocess
from pathlib import Path

import pytest


BUILDER_PATH = Path("tools/build_macos_apple_silicon_payload.py")


def load_builder():
    spec = importlib.util.spec_from_file_location("macos_payload_builder_safety", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def wheel_name(requirement: str) -> str:
    name, version = requirement.split("==", 1)
    normalized = name.replace("-", "_")
    if name in {"audio-separator", "samplerate"}:
        return f"{normalized}-{version}-py3-none-any.whl"
    return f"{normalized}-{version}-cp312-cp312-macosx_12_0_arm64.whl"


def complete_fake_wheelhouse(tmp_path: Path, builder) -> Path:
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    for requirement in builder.MAIN_REQUIREMENTS:
        if "==" in requirement:
            (wheels / wheel_name(requirement)).touch()
    for prefix in builder.REQUIRED_WHEEL_PREFIXES:
        if not any(wheels.glob(f"{prefix}*.whl")):
            (wheels / f"{prefix}1.0-py3-none-any.whl").touch()
    return wheels


@pytest.mark.parametrize("missing", ["numpy==2.4.4", "llvmlite==0.48.0"])
def test_exact_core_wheel_missing_fails_payload_audit(tmp_path, missing):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    (wheels / wheel_name(missing)).unlink()

    with pytest.raises(RuntimeError, match=missing):
        builder.ensure_wheelhouse_complete(wheels)


def test_wrong_python_or_architecture_wheel_fails_payload_audit(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    wanted = wheels / wheel_name("numba==0.66.0")
    wanted.unlink()
    (wheels / "numba-0.66.0-cp311-cp311-macosx_12_0_x86_64.whl").touch()

    with pytest.raises(RuntimeError, match="wrong_platform"):
        builder.ensure_wheelhouse_complete(wheels)


def test_complete_exact_cp312_arm64_wheelhouse_passes_and_manifest_is_fingerprinted(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)

    builder.ensure_wheelhouse_complete(wheels)
    builder.write_manifest(tmp_path, "2.3.0.5")

    manifest = json.loads((tmp_path / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["python_tag"] == "cp312"
    assert manifest["architecture"] == "arm64"
    assert manifest["runtime_requirements"] == list(builder.MAIN_REQUIREMENTS)
    assert {entry["filename"] for entry in manifest["wheel_inventory"]} == {
        path.name for path in wheels.glob("*.whl")
    }
    assert all(len(entry["sha256"]) == 64 for entry in manifest["wheel_inventory"])
    builder.audit_existing_manifest(tmp_path)


def test_manifest_audit_rejects_missing_wheel_and_checksum_drift(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    victim = wheels / wheel_name("numpy==2.4.4")
    victim.write_bytes(b"changed")

    with pytest.raises(RuntimeError, match="checksum mismatch"):
        builder.audit_existing_manifest(tmp_path)

    victim.unlink()
    with pytest.raises(RuntimeError, match="inventory does not match"):
        builder.audit_existing_manifest(tmp_path)


def test_resolver_audit_is_non_mutating_and_uses_only_wheelhouse(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    sentinel = tmp_path / "existing-torch-stack.sentinel"
    sentinel.write_text("torch=2.5.1\n", encoding="utf-8")
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        raise builder.subprocess.CalledProcessError(1, cmd, "missing llvmlite")

    monkeypatch.setattr(builder.subprocess, "run", fake_run)
    with pytest.raises(builder.subprocess.CalledProcessError):
        builder.audit_wheelhouse_resolution(wheels, "python3.12")

    command = calls[0]
    assert "--dry-run" in command
    assert "--ignore-installed" in command
    assert "--no-index" in command
    assert "--find-links" in command
    assert "uninstall" not in command
    assert sentinel.read_text(encoding="utf-8") == "torch=2.5.1\n"


def test_complete_wheelhouse_resolver_preflight_allows_install_path_to_start(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(builder.subprocess, "run", fake_run)
    builder.audit_wheelhouse_resolution(wheels, "python3.12")

    assert calls
    assert calls[0][-len(builder.MAIN_REQUIREMENTS) :] == list(builder.MAIN_REQUIREMENTS)


def test_bootstrap_incomplete_payload_fails_before_existing_runtime_mutation(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")

    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh"), bootstrap)
    wheelhouse = script_dir / "_bundled" / "macos" / "apple-silicon" / "wheels"
    wheelhouse.mkdir(parents=True)
    (wheelhouse / "torch-2.5.1-cp312-none-macosx_11_0_arm64.whl").touch()

    runtime = tmp_path / "runtime"
    fake_python = runtime / ".venv" / "bin" / "python"
    fake_python.parent.mkdir(parents=True)
    sentinel = runtime / ".venv" / "existing-torch-stack.sentinel"
    sentinel.write_text("torch=2.5.1\n", encoding="utf-8")
    pip_log = tmp_path / "fake-pip.log"
    fake_python.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$*" >> "$FAKE_PIP_LOG"\n'
        "exit 23\n",
        encoding="utf-8",
    )

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_uname = fake_bin / "uname"
    fake_uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")

    def git_bash_path(path: Path) -> str:
        result = subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"
    command = (
        f"PATH='{git_bash_path(fake_bin)}':$PATH "
        f"FAKE_PIP_LOG='{git_bash_path(pip_log)}' "
        f"'{git_bash_path(bootstrap)}' "
        f"--runtime-base '{git_bash_path(runtime)}' "
        f"--state-file '{git_bash_path(state)}' "
        f"--log-file '{git_bash_path(log)}' --mode repair"
    )
    result = subprocess.run([str(bash), "-lc", command], capture_output=True, text=True)

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "torch=2.5.1\n"
    assert fake_python.is_file()
    pip_command = pip_log.read_text(encoding="utf-8")
    assert "pip install --dry-run --ignore-installed --no-cache-dir --no-index --find-links" in pip_command
    assert "pip uninstall" not in pip_command
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS=deps_failed" in state_text
    assert "STATUS_REASON=payload_preflight_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=offline_resolve_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text
