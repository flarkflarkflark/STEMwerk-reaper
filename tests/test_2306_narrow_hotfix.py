import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

import pytest


MACOS_BOOTSTRAP = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")
DRUMSEP_HELPER = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
SETUP_INTERNAL = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")


def _load_audio_separator_process_module():
    path = Path("scripts/reaper/audio_separator_process.py")
    spec = importlib.util.spec_from_file_location("audio_separator_process_2306_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_drumsep_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_2306_drumsep", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _arm64_fake_bin(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    uname = fake_bin / "uname"
    uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
    uname.chmod(0o755)
    sw_vers = fake_bin / "sw_vers"
    sw_vers.write_text("#!/bin/sh\nprintf '26.5.2\\n'\n", encoding="utf-8")
    sw_vers.chmod(0o755)
    # Blokkeer elke echte download in de fixture (managed python e.d.).
    for tool in ("curl", "wget"):
        shim = fake_bin / tool
        shim.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        shim.chmod(0o755)
    return fake_bin


def _sentinel_runtime(tmp_path):
    runtime = tmp_path / "runtime"
    sentinel = runtime / ".venv" / "sentinel"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text("preserved\n", encoding="utf-8")
    ready = runtime / "state" / "ready_to_go.env"
    ready.parent.mkdir(parents=True)
    ready.write_text("READY_TO_GO_STATUS=ok\nMAIN_RUNTIME_STATUS=ok\n", encoding="utf-8")
    return runtime, sentinel


def _run_bootstrap(script_dir, runtime, state, log, env, mode="repair"):
    return subprocess.run(
        [
            "/bin/sh",
            str(script_dir / MACOS_BOOTSTRAP.name),
            "--runtime-base",
            str(runtime),
            "--state-file",
            str(state),
            "--log-file",
            str(log),
            "--mode",
            mode,
        ],
        env=env,
        capture_output=True,
        text=True,
    )


def test_apple_silicon_missing_payload_uses_online_fallback_without_early_exit(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    shutil.copy2(MACOS_BOOTSTRAP, script_dir / MACOS_BOOTSTRAP.name)

    fake_bin = _arm64_fake_bin(tmp_path)
    runtime, sentinel = _sentinel_runtime(tmp_path)
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = _run_bootstrap(script_dir, runtime, state, log, env, mode="repair")

    # 2.3.1.0: een afwezige payload is géén vroege apple_silicon_requires_bundled_payload
    # meer; de run valt door naar het online-pad, maar faalt in de diepe preflight
    # voordat managed-Python acquisitie of runtime-mutatie mag starten.
    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS_REASON=apple_silicon_requires_bundled_payload" not in state_text
    assert "STATUS=deps_failed" in state_text
    assert "STATUS_REASON=online_fallback_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=online_fallback_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_apple_silicon_missing_payload_offline_preflight_is_zero_mutation(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    shutil.copy2(MACOS_BOOTSTRAP, script_dir / MACOS_BOOTSTRAP.name)

    fake_bin = _arm64_fake_bin(tmp_path)
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    before = sorted(str(path.relative_to(runtime)) for path in runtime.rglob("*"))
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["HTTP_PROXY"] = "http://127.0.0.1:9"
    env["HTTPS_PROXY"] = "http://127.0.0.1:9"
    env["PIP_INDEX_URL"] = "http://127.0.0.1:9/simple"
    env["NO_PROXY"] = ""
    env["no_proxy"] = ""
    result = _run_bootstrap(script_dir, runtime, state, log, env, mode="repair")
    after = sorted(str(path.relative_to(runtime)) for path in runtime.rglob("*"))

    assert result.returncode != 0
    assert after == before == []
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS=deps_failed" in state_text
    assert "STATUS_REASON=online_fallback_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=online_fallback_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_direct_dks_processing_preflight_blocks_without_download(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()

    def fail_download(*_args, **_kwargs):
        raise AssertionError("processing preflight must not download Direct Kit assets")

    monkeypatch.setattr(module, "_download_direct_dks_assets", fail_download)
    ok, requested, resolved, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        tmp_path,
        allow_downloads=False,
    )
    assert ok is False
    assert requested == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved == module.DIRECT_DKS_MODEL_FILENAME
    assert str(detail).startswith("processing_download_blocked:asset_ready_check_failed:")


def test_apple_silicon_corrupt_payload_fails_before_runtime_cleanup(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    shutil.copy2(MACOS_BOOTSTRAP, script_dir / MACOS_BOOTSTRAP.name)
    # _bundled aanwezig maar incompleet/corrupt (geen manifest/wheels/python/ffmpeg).
    corrupt = script_dir / "_bundled/macos/apple-silicon"
    corrupt.mkdir(parents=True)
    (corrupt / "junk.txt").write_text("broken\n", encoding="utf-8")

    fake_bin = _arm64_fake_bin(tmp_path)
    runtime, sentinel = _sentinel_runtime(tmp_path)
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    result = _run_bootstrap(script_dir, runtime, state, log, env, mode="rebuild-venv")

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    ready_text = (runtime / "state" / "ready_to_go.env").read_text(encoding="utf-8")
    assert "READY_TO_GO_STATUS=missing" in ready_text
    assert "MAIN_RUNTIME_STATUS=missing" in ready_text
    assert "apple_silicon_requires_bundled_payload" in ready_text
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS_REASON=apple_silicon_requires_bundled_payload" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=bundled_payload_incomplete_or_corrupt" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text
    assert not (runtime / "bin").exists()
    assert not (runtime / "ffmpeg").exists()
    assert not (runtime / "python").exists()


def test_apple_silicon_preflight_contract_precedes_runtime_mutation():
    script = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    gate = script.index(
        'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_BUNDLED_PAYLOAD_STATUS}" = "present" ]; then'
    )
    corrupt_gate = script.index(
        'elif [ "${MAC_ARCH}" = "arm64" ] && [ -d "${BUNDLED_PAYLOAD_DIR}" ]; then',
        gate,
    )
    failure_marker = script.index('log "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false"', corrupt_gate)
    readiness = script.index(
        'write_ready_to_go_state "mps" "missing" "missing" '
        '"apple_silicon_requires_bundled_payload" "missing"',
        corrupt_gate,
    )
    online_branch = script.index(
        'MACOS_PAYLOAD_PREFLIGHT_REASON="online_fallback"',
        readiness,
    )
    runtime_dirs = script.index(
        'mkdir -p "${RUNTIME_BASE}/bin" "${RUNTIME_BASE}/ffmpeg" "${RUNTIME_BASE}/python"'
    )
    assert gate < corrupt_gate < failure_marker < readiness < online_branch < runtime_dirs


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
    match_status = script.index('set_status "ok" ""', match)
    match_write = script.index("write_state", match_status)
    match_exit = script.index("exit 0", match_write)
    mismatch_branch = script.index('mismatch\\|*)', match)
    mismatch_exit = script.index('set_status "repair_required" "${MACOS_RUNTIME_POLICY_REASON}"', match)
    missing = script.index('MACOS_RUNTIME_POLICY_REASON="missing_runtime_recovery"', mismatch_exit)
    explicit_rebuild = script.index(
        'MACOS_RUNTIME_POLICY_REASON="explicit_rebuild_after_payload_preflight"', missing
    )
    mutation = script.index('MACOS_RUNTIME_POLICY_MUTATION_STARTED="true"', explicit_rebuild)
    venv_create = script.index('log "Creating STEMwerk virtual environment..."', mutation)
    assert policy_gate < match < match_status < match_write < match_exit < mismatch_exit
    assert policy_gate < match < mismatch_exit < missing < explicit_rebuild < mutation < venv_create
    assert "exit 1" not in script[match:mismatch_branch]


def test_runtime_policy_match_repair_short_circuits_without_mutation(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX bootstrap fixture")
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    shutil.copy2(MACOS_BOOTSTRAP, script_dir / MACOS_BOOTSTRAP.name)

    fake_bin = _arm64_fake_bin(tmp_path)
    runtime = tmp_path / "runtime"
    python = runtime / ".venv/bin/python"
    python.parent.mkdir(parents=True)
    python.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' 'match|python=3.12;architecture=arm64;"
        "audio-separator=0.23.0;numpy=1.26.4;numba=0.59.1;llvmlite=0.42.0;"
        "torch=2.5.1;torchaudio=2.5.1;samplerate=0.1.0'\n",
        encoding="utf-8",
    )
    python.chmod(0o755)
    sentinel = runtime / ".venv/STEMWERK_MACOS_MATCH_TEST_SENTINEL"
    sentinel.write_text("preserved\n", encoding="utf-8")
    before = {path.relative_to(runtime): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"

    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["HTTP_PROXY"] = "http://127.0.0.1:9"
    env["HTTPS_PROXY"] = "http://127.0.0.1:9"
    env["PIP_INDEX_URL"] = "http://127.0.0.1:9/simple"
    env["NO_PROXY"] = ""
    env["no_proxy"] = ""
    result = _run_bootstrap(script_dir, runtime, state, log, env, mode="repair")

    assert result.returncode == 0
    after = {path.relative_to(runtime): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
    assert after == before
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS=ok" in state_text
    assert "STATUS_REASON=" not in state_text
    assert "MACOS_RUNTIME_POLICY_STATUS=match" in state_text
    assert "MACOS_RUNTIME_POLICY_MUTATION_STARTED=false" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text
    log_text = log.read_text(encoding="utf-8")
    assert "STEP 3/5: Installing STEMwerk runtime" not in log_text
    assert "127.0.0.1:9" not in log_text


def test_explicit_rebuild_remains_after_complete_payload_preflight():
    script = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    payload_ok_branch = script.index(
        'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_BUNDLED_PAYLOAD_STATUS}" = "present" ]; then'
    )
    corrupt_exit = script.index("exit 1", payload_ok_branch)
    explicit_rebuild = script.index('MACOS_RUNTIME_POLICY_STATUS="explicit_rebuild"', corrupt_exit)
    removal = script.index('if [ "${MODE}" = "rebuild-venv" ] && [ -d "${RUNTIME_BASE}/.venv" ]; then')
    assert payload_ok_branch < corrupt_exit < explicit_rebuild < removal


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
    # The 2.3.1.0 "keep current failures authoritative" follow-up removed
    # buildWindowsSetupOverview's separate staleRunning/staleGuardFailed/
    # staleFailedState cached-state-to-ok normalization entirely (see
    # tests/support/run_setup_final_rows_headless.lua's
    # windows-deps-failed-cannot-be-overridden-by-old-success-log and
    # windows-running-cannot-be-finalized-by-old-success-log fixtures for the
    # real behavioral coverage) -- a current runtime-policy mismatch (or any
    # other current failure) can no longer be silently normalized back to ok
    # by that path, by construction, since the path no longer exists.
    assert 'local staleFailedState' not in script


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
