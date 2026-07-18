import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


PROCESS_SCRIPT = Path("scripts/reaper/audio_separator_process.py")


def _load_process_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_numba_cache_test", PROCESS_SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_linux_runtime_policy_creates_controlled_numba_cache_before_processing(monkeypatch, tmp_path, capsys):
    module = _load_process_module()
    runtime_base = tmp_path / "STEMwerk"
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module, "_runtime_base_candidates", lambda: [runtime_base])
    monkeypatch.delenv("NUMBA_CACHE_DIR", raising=False)

    policy = module._configure_linux_numba_cache_runtime()

    expected = runtime_base / "cache" / "numba"
    assert policy == {
        "numba_cache_dir": str(expected),
        "numba_cache_source": "runtime_policy",
        "numba_cache_status": "created",
        "numba_cache_inside_venv": "false",
    }
    assert expected.is_dir()
    assert os.environ["NUMBA_CACHE_DIR"] == str(expected)
    stderr = capsys.readouterr().err
    assert f"numba_cache_dir={expected}" in stderr
    assert "numba_cache_source=runtime_policy" in stderr
    assert "numba_cache_status=created" in stderr
    assert "numba_cache_inside_venv=false" in stderr


def test_linux_runtime_policy_overrides_safe_and_unsafe_user_paths(monkeypatch, tmp_path):
    module = _load_process_module()
    runtime_base = tmp_path / "STEMwerk"
    controlled = runtime_base / "cache" / "numba"
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module, "_runtime_base_candidates", lambda: [runtime_base])

    for override in (tmp_path / "user-cache", runtime_base / ".venv" / "numba"):
        monkeypatch.setenv("NUMBA_CACHE_DIR", str(override))
        policy = module._configure_linux_numba_cache_runtime()
        assert policy["numba_cache_status"] == "rejected_override"
        assert policy["numba_cache_source"] == "runtime_policy"
        assert policy["numba_cache_inside_venv"] == "false"
        assert os.environ["NUMBA_CACHE_DIR"] == str(controlled)
        assert not module._path_is_within_root(controlled, runtime_base / ".venv")
        assert not module._path_is_within_root(controlled, runtime_base / ".venv-drumsep-rocm")
        assert not module._path_is_within_root(controlled, runtime_base / "models")


def test_non_linux_launch_behavior_does_not_change_numba_environment(monkeypatch, tmp_path):
    module = _load_process_module()
    existing = tmp_path / "platform-cache"
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setenv("NUMBA_CACHE_DIR", str(existing))

    policy = module._configure_linux_numba_cache_runtime(tmp_path / "STEMwerk")

    assert policy == {}
    assert os.environ["NUMBA_CACHE_DIR"] == str(existing)
    assert not (tmp_path / "STEMwerk" / "cache" / "numba").exists()


def _assert_cli_route_does_not_configure_numba_cache(monkeypatch, argv, route_stub=None):
    module = _load_process_module()
    configured = []
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module.sys, "argv", ["audio_separator_process.py", *argv])
    monkeypatch.setattr(module, "_setup_reaper_io", lambda _output_dir: None)
    monkeypatch.setattr(module, "emit_phase", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_configure_ffmpeg_runtime", lambda: (None, None, None))
    monkeypatch.setattr(module, "_configure_model_cache_runtime", lambda: Path("models"))
    monkeypatch.setattr(module, "_configure_linux_numba_cache_runtime", lambda: configured.append(True))
    if route_stub:
        route_stub(module)

    return module, configured


def test_list_models_does_not_configure_linux_numba_cache(monkeypatch, capsys):
    module, configured = _assert_cli_route_does_not_configure_numba_cache(monkeypatch, ["--list-models"])

    assert module.main() == 0
    assert configured == []
    assert "Popular models:" in capsys.readouterr().out


def test_environment_probe_does_not_configure_linux_numba_cache(monkeypatch):
    module, configured = _assert_cli_route_does_not_configure_numba_cache(
        monkeypatch,
        ["--env-json"],
        lambda loaded: monkeypatch.setattr(loaded, "list_devices_machine", lambda _skips: None),
    )

    assert module.main() == 0
    assert configured == []


def test_help_does_not_configure_linux_numba_cache(monkeypatch):
    module, configured = _assert_cli_route_does_not_configure_numba_cache(monkeypatch, ["--help"])

    with pytest.raises(SystemExit) as exc_info:
        module.main()

    assert exc_info.value.code == 0
    assert configured == []


def test_normal_direct_and_kit_split_share_policy_and_helper_inherits_exact_path(monkeypatch, tmp_path):
    module = _load_process_module()
    runtime_base = tmp_path / "STEMwerk"
    main_python = runtime_base / ".venv" / "bin" / "python"
    helper_python = runtime_base / ".venv-drumsep-rocm" / "bin" / "python"
    main_python.parent.mkdir(parents=True)
    helper_python.parent.mkdir(parents=True)
    main_python.write_text("#!/bin/sh\n", encoding="utf-8")
    helper_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module.sys, "executable", str(main_python))
    monkeypatch.setattr(module, "_runtime_base_candidates", lambda: [runtime_base])

    policy = module._configure_linux_numba_cache_runtime()
    parent_env = module._clean_env()
    helper_env, diagnostics = module.build_drumsep_subprocess_env(
        parent_env,
        helper_python,
        helper_python.parent.parent,
        "rocm",
    )

    expected = str(runtime_base / "cache" / "numba")
    assert os.environ["NUMBA_CACHE_DIR"] == expected
    assert parent_env["NUMBA_CACHE_DIR"] == expected
    assert helper_env["NUMBA_CACHE_DIR"] == expected
    assert diagnostics["numba_cache_dir"] == expected
    assert diagnostics["numba_cache_inherited"] == "yes"
    source = PROCESS_SCRIPT.read_text(encoding="utf-8")
    assert source.index("_configure_linux_numba_cache_runtime()") < source.index("_require_core()", source.index("def main()"))
    assert "NUMBA_DISABLE_JIT" not in source
    assert "NUMBA_DISABLE_CACHING" not in source
    assert "rglob(\"*.nbc\")" not in source
    assert "rglob(\"*.nbi\")" not in source


def test_real_librosa_jit_cache_is_outside_site_packages_and_results_match(monkeypatch, tmp_path):
    module = _load_process_module()
    runtime_base = tmp_path / "STEMwerk"
    models = runtime_base / "models"
    venv_fixture = runtime_base / ".venv" / "fixture.txt"
    model_fixture = models / "fixture-model.bin"
    venv_fixture.parent.mkdir(parents=True)
    models.mkdir(parents=True)
    venv_fixture.write_text("venv-stable", encoding="utf-8")
    model_fixture.write_text("model-stable", encoding="utf-8")
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module, "_runtime_base_candidates", lambda: [runtime_base])
    module._configure_linux_numba_cache_runtime()

    runtime_python = Path.home() / ".local" / "share" / "STEMwerk" / ".venv" / "bin" / "python"
    if not runtime_python.is_file():
        runtime_python = Path(sys.executable)
    probe = subprocess.run(
        [str(runtime_python), "-c", "import librosa, numba; print(librosa.__file__)"],
        capture_output=True,
        text=True,
        env=dict(os.environ),
    )
    assert probe.returncode == 0, probe.stderr
    librosa_root = Path(probe.stdout.strip()).resolve().parent
    site_cache_before = {p.resolve() for pattern in ("*.nbc", "*.nbi") for p in librosa_root.rglob(pattern)}
    env = dict(os.environ)
    code = """
import json
import librosa
import numpy as np
samples = np.array([0.0, 1.0, -1.0, 0.5, -0.5, 0.0] * 256, dtype=np.float32)
zero_crossings = librosa.zero_crossings(samples)
peaks = librosa.util.peak_pick(np.abs(samples), pre_max=2, post_max=2, pre_avg=2, post_avg=2, delta=0.01, wait=1)
print(json.dumps({"zero_crossings": int(zero_crossings.sum()), "peak_count": int(peaks.size)}))
"""
    completed = subprocess.run(
        [str(runtime_python), "-c", code],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )

    assert json.loads(completed.stdout) == {"zero_crossings": 1025, "peak_count": 256}
    runtime_cache = runtime_base / "cache" / "numba"
    cache_files = {p for pattern in ("*.nbc", "*.nbi") for p in runtime_cache.rglob(pattern)}
    assert cache_files
    site_cache_after = {p.resolve() for pattern in ("*.nbc", "*.nbi") for p in librosa_root.rglob(pattern)}
    assert site_cache_after == site_cache_before
    assert venv_fixture.read_text(encoding="utf-8") == "venv-stable"
    assert model_fixture.read_text(encoding="utf-8") == "model-stable"
