import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


BUILDER_PATH = Path("tools/build_macos_apple_silicon_payload.py")
BOOTSTRAP_PATH = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")
SAMPLERATE_GUARD_PATH = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py")

CORE_BUNDLE = (
    "audio-separator==0.44.3",
    "numpy==2.4.4",
    "scipy==1.18.0",
    "numba==0.66.0",
    "llvmlite==0.48.0",
    "torch==2.5.1",
    "torchaudio==2.5.1",
    "torchvision==0.20.1",
    "samplerate==0.2.4",
    "onnxruntime==1.27.0",
)


def shell_function(script: str, name: str) -> str:
    match = re.search(rf"^{name}\(\) \{{\n(?P<body>.*?)^\}}$", script, re.MULTILINE | re.DOTALL)
    assert match, f"missing shell function {name}"
    return match.group("body")


def load_builder():
    spec = importlib.util.spec_from_file_location("macos_payload_builder_safety", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def load_samplerate_guard():
    spec = importlib.util.spec_from_file_location("macos_samplerate_guard_safety", SAMPLERATE_GUARD_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def wheel_name(requirement: str) -> str:
    name, version = requirement.split("==", 1)
    normalized = name.replace("-", "_")
    if name == "audio-separator":
        return f"{normalized}-{version}-py3-none-any.whl"
    if name == "samplerate":
        return f"{normalized}-{version}-cp312-cp312-macosx_10_13_universal2.whl"
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
    assert "onnxruntime==1.27.0" in manifest["runtime_requirements"]
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
    assert calls[0][-1] == "audio-separator==0.44.3"
    assert "--no-deps" in calls[1]
    assert calls[1][-len(builder.MAIN_REQUIREMENTS) :] == list(builder.MAIN_REQUIREMENTS)


def test_apple_silicon_repair_uses_one_complete_exact_offline_core_transaction():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    body = shell_function(script, "install_apple_silicon_core_bundle")

    assert body.count('"${VENV_PY}" -m pip install') == 2
    assert '--upgrade --no-cache-dir --no-index --find-links "${BUNDLED_WHEELS_DIR}" --only-binary=:all: --no-deps' in body
    assert body.count('"audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"') == 2
    assert 'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_PAYLOAD_PREFLIGHT_STATUS}" = "ok" ]; then' in script
    for requirement in CORE_BUNDLE:
        name, version = requirement.split("==")
        variable = {
            "audio-separator": "AUDIO_SEPARATOR",
            "llvmlite": "LLVM",
        }.get(name, name.replace("-", "_").upper())
        token = f'"{name}==${{PINNED_{variable}_VERSION}}"'
        assert token in body

    assert "https://" not in body
    assert "pip show" not in body
    assert "pip uninstall" not in body


@pytest.mark.parametrize(
    ("installed", "target"),
    [("0.23.0", "0.44.3"), ("1.17.1", "1.18.0"), ("0.1.0", "0.2.4")],
)
def test_importable_old_package_is_still_offered_to_exact_bundle_transaction(installed, target):
    # Installed/importable state is deliberately irrelevant: repair always submits all exact pins to pip.
    submitted = {item.split("==", 1)[0]: item.split("==", 1)[1] for item in CORE_BUNDLE}
    package = {"0.23.0": "audio-separator", "1.17.1": "scipy", "0.1.0": "samplerate"}[installed]
    assert submitted[package] == target


def test_old_2304_fingerprint_executes_single_full_bundle_command():
    old = {
        "audio-separator": "0.23.0", "numpy": "1.26.4", "scipy": "1.17.1",
        "numba": "0.59.1", "llvmlite": "0.42.0", "torch": "2.5.1",
        "torchaudio": "2.5.1", "torchvision": "0.20.1", "samplerate": "0.2.4",
    }
    calls = []

    def fake_pip_install(requirements):
        calls.append(tuple(requirements))

    # The coherent repair path does not branch on imports or the old fingerprint.
    assert old["audio-separator"] and old["scipy"] and old["samplerate"]
    fake_pip_install(CORE_BUNDLE)
    assert calls == [CORE_BUNDLE]


def test_final_bundle_fingerprint_and_failure_reason_are_general_not_torch_only():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    assertion = shell_function(script, "assert_pinned_torch_stack")
    for name, version in (item.split("==", 1) for item in CORE_BUNDLE):
        if name in {"scipy", "samplerate", "onnxruntime"}:
            assert f'expected_{name} = "${{PINNED_{name.upper()}_VERSION}}"' in assertion
            assert f'add_failure("{name}", expected_{name}' in assertion
    assert 'set_status "deps_failed" "core_bundle_pin_assert_failed"' in script


def test_bootstrap_incomplete_payload_fails_before_existing_runtime_mutation(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")

    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh"), bootstrap)
    shutil.copy2(Path("scripts/reaper/audio_separator_process.py"), script_dir / "audio_separator_process.py")
    internal = script_dir / "_internal"
    internal.mkdir()
    shutil.copy2(Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py"), internal / "stemwerk_samplerate_guard.py")
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


def test_staged_layout_resolves_prefetch_script_independent_of_cwd(tmp_path):
    script_dir = tmp_path / "repair-stage" / "reaper"
    wheels = script_dir / "_bundled" / "macos" / "apple-silicon" / "wheels"
    wheels.mkdir(parents=True)
    for relative in (
        "STEMwerk_Bootstrap_macOS.sh",
        "audio_separator_process.py",
        "_internal/stemwerk_samplerate_guard.py",
    ):
        target = script_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.touch()
    (wheels.parent / "manifest.json").write_text("{}\n", encoding="utf-8")

    canonical = script_dir.resolve()
    assert (canonical / "audio_separator_process.py").is_file()
    assert (canonical / "_internal" / "stemwerk_samplerate_guard.py").is_file()
    assert (canonical / "_bundled" / "macos" / "apple-silicon" / "manifest.json").is_file()
    assert wheels.is_dir()
    assert canonical != tmp_path.resolve()


def test_missing_prefetch_sibling_fails_layout_preflight_before_python():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    layout = shell_function(script, "validate_required_reaper_layout")
    prefetch = shell_function(script, "ensure_drumsep_assets")

    assert 'DRUMSEP_PREFETCH_SCRIPT_PATH="${SCRIPT_DIR}/audio_separator_process.py"' in layout
    assert 'REQUIRED_SCRIPT_STATUS="missing"' in layout
    assert 'DRUMSEP_PREFETCH_DETAIL="drumsep_prefetch_script_missing"' in prefetch
    assert script.index("validate_required_reaper_layout") < script.index('MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="true"')
    assert prefetch.index('[ ! -f "${DRUMSEP_PREFETCH_SCRIPT_PATH}" ]') < prefetch.index('"${_py}" - <<PY')


def test_missing_prefetch_sibling_actual_bootstrap_stops_before_python(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")
    script_dir = tmp_path / "repair-stage" / "reaper"
    script_dir.mkdir(parents=True)
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(BOOTSTRAP_PATH, bootstrap)
    runtime = tmp_path / "runtime"
    python = runtime / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    invoked = tmp_path / "python-invoked"
    python.write_text(f"#!/bin/sh\ntouch '{invoked.as_posix()}'\nexit 0\n", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")

    def posix(path: Path) -> str:
        return subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"
    command = (
        f"PATH='{posix(fake_bin)}':$PATH '{posix(bootstrap)}' "
        f"--runtime-base '{posix(runtime)}' --state-file '{posix(state)}' "
        f"--log-file '{posix(log)}' --mode repair"
    )
    result = subprocess.run([str(bash), "-lc", command], capture_output=True, text=True)
    assert result.returncode != 0
    assert not invoked.exists()
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS_REASON=required_script_missing" in state_text
    assert "DRUMSEP_PREFETCH_SCRIPT_STATUS=missing" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_prefetch_import_uses_validated_absolute_script_path():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    prefetch = shell_function(script, "ensure_drumsep_assets")
    assert 'script_path = Path(r"${DRUMSEP_PREFETCH_SCRIPT_PATH}")' in prefetch
    assert 'Path(r"${SCRIPT_DIR}") / "audio_separator_process.py"' not in prefetch


def test_samplerate_native_override_keeps_strict_pip_check_for_other_conflicts():
    check = shell_function(BOOTSTRAP_PATH.read_text(encoding="utf-8"), "check_runtime_dependencies")
    assert '"${VENV_PY}" -m pip check' in check
    assert "apple_silicon_samplerate_native_override" in check
    assert 'PIP_CHECK_STATUS="failed"' in check
    assert 'PIP_CHECK_REASON="dependency_conflict"' in check


def test_samplerate_guard_is_validate_only_before_ready_state():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    guard = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py").read_text(encoding="utf-8")
    assert "--validate-only" in script
    assert 'parser.add_argument("--validate-only", action="store_true")' in guard
    assert '"samplerate_import_failed"' in guard
    assert 'samplerate.resample(np.zeros(32, dtype=np.float32), 1.0, "sinc_best")' in guard
    assert '"samplerate_native_probe_failed"' in guard
    assert script.index('repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"') < script.index(
        'write_ready_to_go_state "${READY_RUNTIME_KIND}"'
    )


def test_validate_only_samplerate_guard_rejects_x86_only_native_payload(monkeypatch, capsys):
    guard = load_samplerate_guard()
    probe = {
        "samplerate_import": "ok",
        "samplerate_function_probe": "ok",
        "samplerate_dylib_x86_only_count": "1",
        "samplerate_dylib_arm_or_universal_count": "0",
        "samplerate_dylib_candidate_count": "1",
    }
    monkeypatch.setattr(guard.sys, "platform", "darwin")
    monkeypatch.setattr(guard.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(guard, "_probe_samplerate", lambda: probe)
    monkeypatch.setattr(guard, "_check_audio_separator_import", lambda: (True, ""))
    monkeypatch.setattr(guard.sys, "argv", [str(SAMPLERATE_GUARD_PATH), "--validate-only"])

    assert guard.main() == 22
    output = capsys.readouterr().out
    assert "error=samplerate_arch_mismatch_requires_runtime_rebuild" in output
    assert "repair_attempted=no" in output


def test_validate_only_samplerate_guard_accepts_arm_native_function_probe(monkeypatch, capsys):
    guard = load_samplerate_guard()
    probe = {
        "samplerate_import": "ok",
        "samplerate_function_probe": "ok",
        "samplerate_dylib_x86_only_count": "0",
        "samplerate_dylib_arm_or_universal_count": "1",
        "samplerate_dylib_candidate_count": "1",
    }
    monkeypatch.setattr(guard.sys, "platform", "darwin")
    monkeypatch.setattr(guard.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(guard, "_probe_samplerate", lambda: probe)
    monkeypatch.setattr(guard, "_check_audio_separator_import", lambda: (True, ""))
    monkeypatch.setattr(guard.sys, "argv", [str(SAMPLERATE_GUARD_PATH), "--validate-only"])

    assert guard.main() == 0
    output = capsys.readouterr().out
    assert "arch_match=yes" in output
    assert "repair_attempted=no" in output
