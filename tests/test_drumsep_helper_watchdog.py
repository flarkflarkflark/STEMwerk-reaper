import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_drumsep_watchdog_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


class _FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def _prepare_helper_environment(tmp_path, monkeypatch, module):
    input_path = tmp_path / "input.wav"
    input_path.write_bytes(b"wav")
    output_root = tmp_path / "out"
    output_root.mkdir()
    model_cache_dir = tmp_path / "models"
    model_cache_dir.mkdir()
    drumsep_python = tmp_path / "python"
    drumsep_python.write_text("", encoding="utf-8")
    helper_path = tmp_path / "stemwerk_drumsep_process.py"
    helper_path.write_text("# helper\n", encoding="utf-8")

    monkeypatch.setattr(module, "_drumsep_helper_path", lambda: helper_path)
    monkeypatch.setattr(module, "build_drumsep_subprocess_env", lambda env, *_args, **_kwargs: (env, {}))
    monkeypatch.setattr(module, "_emit_drumsep_subprocess_env_diagnostics", lambda _diag: None)
    monkeypatch.setattr(module, "_windows_no_window_kwargs", lambda: {})

    return input_path, output_root, model_cache_dir, drumsep_python


def _write_success_result(output_root):
    result = {
        "ok": True,
        "stems": {
            "kick": "kick_source.wav",
            "snare": "snare_source.wav",
            "toms": "toms_source.wav",
            "hihat": "hihat_source.wav",
            "ride": "ride_source.wav",
            "crash": "crash_source.wav",
        },
    }
    (output_root / "drumsep_result.json").write_text(json.dumps(result), encoding="utf-8")
    for stem_file in result["stems"].values():
        (output_root / stem_file).write_bytes(b"wav")


def test_drumsep_helper_progress_updates_allow_runs_past_old_3600s_limit(tmp_path, monkeypatch):
    module = _load_module()
    input_path, output_root, model_cache_dir, drumsep_python = _prepare_helper_environment(tmp_path, monkeypatch, module)
    clock = _FakeClock()
    monkeypatch.setattr(module.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(module.time, "sleep", clock.sleep)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_NO_OUTPUT_STALL_SECONDS", 10)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_POLL_INTERVAL_SECONDS", 1.0)

    helper_log = output_root / "drumsep_helper.log"
    helper_log.write_text("1%|\n", encoding="utf-8")
    _write_success_result(output_root)

    class FakeProcess:
        returncode = None
        killed = False

        def poll(self):
            if int(clock.now) in {3, 7, 11}:
                helper_log.write_text(f"{10 + int(clock.now)}%| tick={int(clock.now)}\n", encoding="utf-8")
            if clock.now >= 15:
                self.returncode = 0
                return 0
            return None

        def kill(self):
            self.killed = True
            self.returncode = -9

        def wait(self, timeout=None):
            return self.returncode

    fake_process = FakeProcess()
    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: fake_process)

    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
    )

    assert ok is True
    assert reason == ""
    assert detail == ""
    assert fake_process.killed is False
    assert stems["kick"].endswith("kick.wav")


def test_drumsep_helper_watchdog_fails_only_after_no_output_window(tmp_path, monkeypatch):
    module = _load_module()
    input_path, output_root, model_cache_dir, drumsep_python = _prepare_helper_environment(tmp_path, monkeypatch, module)
    clock = _FakeClock()
    monkeypatch.setattr(module.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(module.time, "sleep", clock.sleep)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_NO_OUTPUT_STALL_SECONDS", 10)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_POLL_INTERVAL_SECONDS", 1.0)

    helper_log = output_root / "drumsep_helper.log"
    helper_log.write_text("42%|\n", encoding="utf-8")

    class FakeProcess:
        returncode = None
        killed = False

        def poll(self):
            return None

        def kill(self):
            self.killed = True
            self.returncode = -9

        def wait(self, timeout=None):
            return self.returncode

    fake_process = FakeProcess()
    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: fake_process)

    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
    )

    assert ok is False
    assert stems == {}
    assert reason == "drumsep_helper_failed"
    assert fake_process.killed is True
    assert "DrumSep helper produced no progress/log output for" in detail
    assert "last progress 42%" in detail


def test_drumsep_helper_log_updates_reset_watchdog_without_percent_change(tmp_path, monkeypatch):
    module = _load_module()
    input_path, output_root, model_cache_dir, drumsep_python = _prepare_helper_environment(tmp_path, monkeypatch, module)
    clock = _FakeClock()
    monkeypatch.setattr(module.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(module.time, "sleep", clock.sleep)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_NO_OUTPUT_STALL_SECONDS", 10)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_POLL_INTERVAL_SECONDS", 1.0)

    helper_log = output_root / "drumsep_helper.log"
    helper_log.write_text("42%|\n", encoding="utf-8")
    _write_success_result(output_root)

    class FakeProcess:
        returncode = None
        killed = False

        def poll(self):
            if int(clock.now) in {4, 8, 12}:
                helper_log.write_text(f"42%|\nheartbeat={int(clock.now)}\n", encoding="utf-8")
            if clock.now >= 15:
                self.returncode = 0
                return 0
            return None

        def kill(self):
            self.killed = True
            self.returncode = -9

        def wait(self, timeout=None):
            return self.returncode

    fake_process = FakeProcess()
    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: fake_process)

    ok, _stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
    )

    assert ok is True
    assert reason == ""
    assert detail == ""
    assert fake_process.killed is False


def test_drumsep_helper_nonzero_exit_still_reports_failure(tmp_path, monkeypatch):
    module = _load_module()
    input_path, output_root, model_cache_dir, drumsep_python = _prepare_helper_environment(tmp_path, monkeypatch, module)
    clock = _FakeClock()
    monkeypatch.setattr(module.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(module.time, "sleep", clock.sleep)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_NO_OUTPUT_STALL_SECONDS", 10)
    monkeypatch.setattr(module, "DRUMSEP_HELPER_POLL_INTERVAL_SECONDS", 1.0)

    helper_log = output_root / "drumsep_helper.log"
    helper_log.write_text("42%|\n", encoding="utf-8")
    (output_root / "drumsep_result.json").write_text(
        json.dumps({"ok": False, "error_reason": "drumsep_crash", "message": "boom"}),
        encoding="utf-8",
    )

    class FakeProcess:
        returncode = None

        def poll(self):
            if clock.now >= 2:
                self.returncode = 7
                return 7
            return None

        def kill(self):
            self.returncode = -9

        def wait(self, timeout=None):
            return self.returncode

    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: FakeProcess())

    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
    )

    assert ok is False
    assert stems == {}
    assert reason == "drumsep_crash"
    assert "boom" in detail
