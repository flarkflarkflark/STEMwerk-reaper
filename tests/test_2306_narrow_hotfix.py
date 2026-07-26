import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

import pytest


MACOS_BOOTSTRAP = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")
DRUMSEP_HELPER = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
SETUP_INTERNAL = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")


def _load_drumsep_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_2306_drumsep", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_apple_silicon_missing_payload_fails_before_runtime_cleanup(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / MACOS_BOOTSTRAP.name
    shutil.copy2(MACOS_BOOTSTRAP, bootstrap)

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    uname = fake_bin / "uname"
    uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
    uname.chmod(0o755)

    runtime = tmp_path / "runtime"
    sentinel = runtime / ".venv" / "sentinel"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text("preserved\n", encoding="utf-8")
    ready = runtime / "state" / "ready_to_go.env"
    ready.parent.mkdir(parents=True)
    ready.write_text("READY_TO_GO_STATUS=ok\nMAIN_RUNTIME_STATUS=ok\n", encoding="utf-8")
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = subprocess.run(
        [
            "/bin/sh",
            str(bootstrap),
            "--runtime-base",
            str(runtime),
            "--state-file",
            str(state),
            "--log-file",
            str(log),
            "--mode",
            "rebuild-venv",
        ],
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    ready_text = ready.read_text(encoding="utf-8")
    assert "READY_TO_GO_STATUS=missing" in ready_text
    assert "MAIN_RUNTIME_STATUS=missing" in ready_text
    assert "apple_silicon_requires_bundled_payload" in ready_text
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS_REASON=apple_silicon_requires_bundled_payload" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=bundled_payload_missing_or_incomplete" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text
    assert not (runtime / "bin").exists()
    assert not (runtime / "ffmpeg").exists()
    assert not (runtime / "python").exists()


def test_apple_silicon_preflight_contract_precedes_runtime_mutation():
    script = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    gate = script.index(
        'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_BUNDLED_PAYLOAD_STATUS}" != "present" ]; then'
    )
    failure_marker = script.index('log "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false"', gate)
    readiness = script.index(
        'write_ready_to_go_state "mps" "missing" "missing" '
        '"apple_silicon_requires_bundled_payload" "missing"',
        gate,
    )
    runtime_dirs = script.index(
        'mkdir -p "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"'
    )
    assert gate < failure_marker < readiness < runtime_dirs


def _complete_payload_fixture(script_dir):
    payload = script_dir / "_bundled/macos/apple-silicon"
    for name in ("wheels", "python", "models", "drumsep", "ffmpeg"):
        (payload / name).mkdir(parents=True, exist_ok=True)
    (payload / "manifest.json").write_text("{}\n", encoding="utf-8")
    ffmpeg = payload / "ffmpeg/ffmpeg"
    ffmpeg.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    ffmpeg.chmod(0o755)


def test_healthy_repair_policy_mismatch_preserves_existing_runtime(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / MACOS_BOOTSTRAP.name
    shutil.copy2(MACOS_BOOTSTRAP, bootstrap)
    _complete_payload_fixture(script_dir)

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    uname = fake_bin / "uname"
    uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
    uname.chmod(0o755)

    runtime = tmp_path / "runtime"
    python = runtime / ".venv/bin/python"
    python.parent.mkdir(parents=True)
    python.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' 'mismatch|python=3.12;architecture=arm64;"
        "audio-separator=0.44.3;numpy=2.4.4;numba=0.66.0;llvmlite=0.48.0;"
        "torch=2.5.1;torchaudio=2.5.1;samplerate=0.2.4'\n",
        encoding="utf-8",
    )
    python.chmod(0o755)
    sentinel = runtime / ".venv/STEMWERK_MACOS_REPAIR_TEST_SENTINEL"
    sentinel.write_text("preserved\n", encoding="utf-8")
    inventory = runtime / ".venv/inventory.txt"
    inventory.write_text(
        "audio-separator==0.44.3\nnumpy==2.4.4\nnumba==0.66.0\nllvmlite==0.48.0\n",
        encoding="utf-8",
    )
    ready = runtime / "state/ready_to_go.env"
    ready.parent.mkdir(parents=True)
    ready.write_text("READY_TO_GO_STATUS=ok\nMAIN_RUNTIME_STATUS=ok\n", encoding="utf-8")
    before = {path.relative_to(runtime): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = subprocess.run(
        [
            "/bin/sh",
            str(bootstrap),
            "--runtime-base",
            str(runtime),
            "--state-file",
            str(state),
            "--log-file",
            str(log),
            "--mode",
            "repair",
        ],
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    after = {path.relative_to(runtime): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
    # Bootstrap state/log are outside this managed-runtime inventory comparison.
    assert after == before
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    assert inventory.read_text(encoding="utf-8").startswith("audio-separator==0.44.3")
    assert ready.read_text(encoding="utf-8") == "READY_TO_GO_STATUS=ok\nMAIN_RUNTIME_STATUS=ok\n"
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS=repair_required" in state_text
    assert "STATUS_REASON=runtime_policy_mismatch_requires_rebuild" in state_text
    assert "MACOS_RUNTIME_POLICY_STATUS=mismatch" in state_text
    assert "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_runtime_policy_gate_preserves_matching_and_missing_recovery_paths():
    script = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    policy_gate = script.index('if [ "${MODE}" = "repair" ] && [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then')
    match = script.index('MACOS_RUNTIME_POLICY_STATUS="match"', policy_gate)
    mismatch_branch = script.index('mismatch\\|*)', match)
    mismatch_exit = script.index('set_status "repair_required" "${MACOS_RUNTIME_POLICY_REASON}"', match)
    missing = script.index('MACOS_RUNTIME_POLICY_REASON="missing_runtime_recovery"', mismatch_exit)
    explicit_rebuild = script.index(
        'MACOS_RUNTIME_POLICY_REASON="explicit_rebuild_after_payload_preflight"', missing
    )
    mutation = script.index('MACOS_RUNTIME_POLICY_MUTATION_STARTED="true"', explicit_rebuild)
    venv_create = script.index('log "Creating STEMwerk virtual environment..."', mutation)
    assert policy_gate < match < mismatch_exit < missing < explicit_rebuild < mutation < venv_create
    assert "exit 1" not in script[match:mismatch_branch]


def test_explicit_rebuild_remains_after_complete_payload_preflight():
    script = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    payload_gate = script.index(
        'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_BUNDLED_PAYLOAD_STATUS}" != "present" ]; then'
    )
    payload_failure_exit = script.index("exit 1", payload_gate)
    explicit_rebuild = script.index('MACOS_RUNTIME_POLICY_STATUS="explicit_rebuild"', payload_failure_exit)
    removal = script.index('if [ "${MODE}" = "rebuild-venv" ] && [ -d "${RUNTIME_BASE}/.venv" ]; then')
    assert payload_gate < payload_failure_exit < explicit_rebuild < removal


def test_setup_does_not_normalize_runtime_policy_mismatch_back_to_ok():
    script = SETUP_INTERNAL.read_text(encoding="utf-8")
    assert 'local function runtimePolicyRequiresRebuild(state)' in script
    assert 'reason == "runtime_policy_mismatch_requires_rebuild"' in script
    assert 'reason == "runtime_broken_requires_rebuild"' in script
    assert 'local runtimePolicyBlocked = runtimePolicyRequiresRebuild(state)' in script
    assert 'if verifiedRuntimeOk and not runtimePolicyBlocked then' in script
    assert 'if authoritativeRuntimeVerified and not runtimePolicyBlocked then' in script
    assert 'local authoritativeRuntimeVerified = authoritativeBootstrapVerified' in script
    assert 'and not windowsTorchaudioVerificationFailed' in script
    assert 'and readyHealthy and bootstrapComplete and not runtimePolicyRequiresRebuild(state)' in script


def _managed_cache(tmp_path, alias_bytes=None):
    helper = _load_drumsep_helper()
    canonical = tmp_path / helper.DRUMSEP_MODEL_FILENAME
    canonical.write_bytes(b"managed-checkpoint")
    yaml_path = tmp_path / helper.DRUMSEP_MODEL_YAML
    yaml_path.write_text("audio: {}\nmodel: {}\ntraining: {}\n", encoding="utf-8")
    if alias_bytes is not None:
        (tmp_path / helper.DRUMSEP_MODEL_ALIAS).write_bytes(alias_bytes)
    return helper, canonical, yaml_path


def test_asep_0443_catalog_alias_uses_canonical_checkpoint_without_copy(tmp_path):
    helper, canonical, yaml_path = _managed_cache(tmp_path)
    before = {path.name: path.read_bytes() for path in tmp_path.iterdir()}

    resolution = helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)

    assert resolution.model_name == helper.DRUMSEP_MODEL_FILENAME
    assert resolution.model_path == canonical
    assert resolution.config_path == yaml_path
    assert {path.name: path.read_bytes() for path in tmp_path.iterdir()} == before
    assert not (tmp_path / helper.DRUMSEP_MODEL_ALIAS).exists()


def test_conflicting_catalog_alias_fails_closed_without_mutation(tmp_path):
    helper, _canonical, _yaml_path = _managed_cache(tmp_path, alias_bytes=b"different")
    before = {path.name: path.read_bytes() for path in tmp_path.iterdir()}

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)

    assert exc_info.value.reason == "drumsep_checkpoint_alias_checksum_mismatch"
    assert {path.name: path.read_bytes() for path in tmp_path.iterdir()} == before


def test_catalog_adapter_returns_existing_managed_files_without_network(tmp_path):
    helper, canonical, yaml_path = _managed_cache(tmp_path)
    resolution = helper._resolve_managed_drumsep_checkpoint(tmp_path, helper.DRUMSEP_MODEL_ALIAS)
    fallback_calls = []

    class FakeSeparator:
        def download_model_files(self, model_filename):
            fallback_calls.append(model_filename)
            raise AssertionError("managed DrumSep must not use catalog/network fallback")

    separator = FakeSeparator()
    helper._configure_managed_drumsep_checkpoint(separator, resolution)
    result = separator.download_model_files(helper.DRUMSEP_MODEL_ALIAS)

    assert result == (
        helper.DRUMSEP_MODEL_FILENAME,
        "MDXC",
        "STEMwerk managed DrumSep 6stem",
        str(canonical),
        yaml_path.name,
    )
    assert fallback_calls == []
