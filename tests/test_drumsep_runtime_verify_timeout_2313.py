"""DrumSep runtime verification timeout vs. a proven broken runtime (issue #127).

_verify_drumsep_runtime() cold-starts the DrumSep interpreter and imports
audio_separator/torch/onnx. On a healthy but slow Windows CPU machine that took
7-30 s, and the old 30 s bound turned the slow successes into
drumsep_runtime_broken. Running out of time is inconclusive: it must be
reported as a verification timeout, while concrete failures stay "broken".
"""

import importlib.util
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
AUDIO_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"

OK_PAYLOAD = {
    "ok": True,
    "versions": {"audio-separator": "0.34.1", "torch": "2.12.0", "onnxruntime": "1.26.0"},
    "torch_hip": "",
    "torch_cuda_available": False,
    "device_names": [],
    "mps_built": False,
    "mps_available": False,
    "directml_available": False,
    "directml_device_count": 0,
    "onnxruntime_providers": ["CPUExecutionProvider"],
}


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_verify_timeout_test", AUDIO_PROCESS)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _make_python(path: Path, body: str = "#!/bin/sh\nexit 0\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


class _SubprocessProxy:
    """The module's own `subprocess`, with run() replaced by a simulated probe."""

    def __init__(self, run):
        self.run = run

    def __getattr__(self, attr):
        return getattr(subprocess, attr)


def _simulated_probe(duration_s: float, returncode: int = 0, stdout: str = "", stderr: str = "", calls=None):
    """Behave like subprocess.run for a probe that needs `duration_s` seconds."""

    def run(cmd, **kwargs):
        timeout = kwargs.get("timeout")
        if calls is not None:
            calls.append(timeout)
        if timeout is None:
            raise AssertionError("runtime verification must always be bounded")
        if duration_s > timeout:
            raise subprocess.TimeoutExpired(cmd, timeout)
        return subprocess.CompletedProcess(cmd, returncode, stdout, stderr)

    return run


def _patch_probe(module, monkeypatch, run):
    monkeypatch.setattr(module, "subprocess", _SubprocessProxy(run))


# --- constants: verification bound is separate from the processing watchdog --


def test_verification_timeout_is_named_finite_and_separate_from_the_watchdog():
    module = _load_module()
    assert module.DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS == 120
    assert module.DRUMSEP_HELPER_NO_OUTPUT_STALL_SECONDS == 60 * 60
    source = AUDIO_PROCESS.read_text(encoding="utf-8")
    verify = source[source.index("def _verify_drumsep_runtime("):source.index("def _clean_env(")]
    assert "timeout=DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS" in verify
    assert "timeout=30" not in verify


# --- 1/2: slow-but-healthy and fast probes verify successfully ---------------


@pytest.mark.parametrize("duration_s", [31.0, 45.0, 90.0, 119.0])
def test_probe_crossing_the_old_30s_boundary_still_verifies(tmp_path, monkeypatch, duration_s):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    calls = []
    _patch_probe(module, monkeypatch, _simulated_probe(duration_s, stdout=json.dumps(OK_PAYLOAD), calls=calls))

    ok, detail, payload = module._verify_drumsep_runtime(python)

    assert ok is True
    assert payload["versions"]["torch"] == "2.12.0"
    assert calls == [120]


def test_fast_probe_is_unchanged(tmp_path, monkeypatch):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    calls = []
    _patch_probe(module, monkeypatch, _simulated_probe(7.0, stdout=json.dumps(OK_PAYLOAD), calls=calls))

    ok, _detail, payload = module._verify_drumsep_runtime(python)

    assert ok is True
    assert payload["ok"] is True
    assert len(calls) == 1


# --- 3/4: concrete failures stay broken --------------------------------------


def test_import_failure_is_still_a_concrete_failure(tmp_path, monkeypatch):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    failure = json.dumps({"ok": False, "module": "torch", "error": "ImportError: DLL load failed"})
    _patch_probe(module, monkeypatch, _simulated_probe(5.0, returncode=1, stdout=failure))

    ok, detail, _payload = module._verify_drumsep_runtime(python)

    assert ok is False
    assert "DLL load failed" in detail
    assert not detail.startswith(module.DRUMSEP_RUNTIME_VERIFY_TIMEOUT_DETAIL_PREFIX)


def test_nonzero_exit_without_output_keeps_its_exit_detail(tmp_path, monkeypatch):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    _patch_probe(module, monkeypatch, _simulated_probe(2.0, returncode=3))

    ok, detail, _payload = module._verify_drumsep_runtime(python)

    assert ok is False
    assert detail == "verify_exit_3"


def test_spawn_failure_is_still_reported_as_spawn_failure(tmp_path, monkeypatch):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")

    def run(cmd, **kwargs):
        raise OSError("[WinError 193] %1 is not a valid Win32 application")

    _patch_probe(module, monkeypatch, run)
    ok, detail, _payload = module._verify_drumsep_runtime(python)

    assert ok is False
    assert detail.startswith("verify_spawn_failed:OSError:")


# --- 5/6: a true hang is bounded, killed, reaped and never retried -----------


def test_true_hang_is_reported_as_verification_timeout(tmp_path, monkeypatch):
    module = _load_module()
    python = _make_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    calls = []
    _patch_probe(module, monkeypatch, _simulated_probe(10_000.0, calls=calls))

    ok, detail, payload = module._verify_drumsep_runtime(python)

    assert ok is False
    assert detail == "verify_timeout:120s"
    assert payload == {}
    assert calls == [120], "exactly one bounded attempt, no retry"


@pytest.mark.skipif(os.name != "posix" or shutil.which("sleep") is None, reason="needs a POSIX sleep")
def test_real_hung_probe_is_killed_and_reaped_before_returning(tmp_path, monkeypatch):
    module = _load_module()
    pid_file = tmp_path / "probe.pid"
    python = _make_python(
        tmp_path / ".venv-drumsep" / "bin" / "python",
        f'#!/bin/sh\necho $$ > "{pid_file}"\nexec sleep 60\n',
    )
    monkeypatch.setattr(module, "DRUMSEP_RUNTIME_VERIFY_TIMEOUT_SECONDS", 1)

    started = time.monotonic()
    ok, detail, _payload = module._verify_drumsep_runtime(python)
    elapsed = time.monotonic() - started

    assert ok is False
    assert detail == "verify_timeout:1s"
    assert elapsed < 15
    pid = int(pid_file.read_text(encoding="utf-8").strip())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


def test_each_candidate_interpreter_is_probed_at_most_once(tmp_path, monkeypatch):
    module = _load_module()
    first = tmp_path / "a" / "python"
    second = tmp_path / "b" / "python"
    calls = []

    def fake_verify(path, require_gpu=False, **kwargs):
        calls.append(path)
        return False, "verify_timeout:120s", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, detail, _payload, attempts = module._probe_drumsep_runtime_candidates([first, second])

    assert selected is None
    assert detail == "verify_timeout:120s"
    assert calls == [first, second]
    assert [a["detail"] for a in attempts] == ["verify_timeout:120s", "verify_timeout:120s"]


# --- 7: timeout alone never becomes drumsep_runtime_broken -------------------


def _attempts(*details):
    return [{"python": f"/p{i}", "ok": False, "detail": d} for i, d in enumerate(details)]


@pytest.mark.parametrize("requested", ["auto", "cpu", "directml", "cuda"])
def test_timeout_only_selection_is_reported_as_verify_timeout(requested):
    module = _load_module()
    info = {"cpu_python_attempts": _attempts("verify_timeout:120s"), "directml_python_attempts": _attempts("missing")}

    assert module._drumsep_runtime_unavailable_reason("broken", info, requested) == "drumsep_runtime_verify_timeout"


@pytest.mark.parametrize(
    "requested,expected",
    [("auto", "drumsep_runtime_broken"), ("cpu", "drumsep_cpu_runtime_broken")],
)
def test_any_concrete_failure_keeps_the_runtime_broken(requested, expected):
    module = _load_module()
    info = {
        "cuda_python_attempts": _attempts("cuda_unavailable"),
        "cpu_python_attempts": _attempts("verify_timeout:120s"),
    }

    assert module._drumsep_runtime_unavailable_reason("broken", info, requested) == expected


@pytest.mark.parametrize(
    "requested,expected",
    [("auto", "drumsep_runtime_missing"), ("cpu", "drumsep_cpu_runtime_missing")],
)
def test_missing_runtime_is_unchanged(requested, expected):
    module = _load_module()
    info = {"cpu_python_attempts": _attempts("missing")}

    assert module._drumsep_runtime_unavailable_reason("missing", info, requested) == expected


def test_broken_without_attempt_records_stays_broken():
    module = _load_module()

    assert module._drumsep_runtime_unavailable_reason("broken", {}, "auto") == "drumsep_runtime_broken"
    assert module._drumsep_runtime_unavailable_reason("broken", {"cpu_detail": "verify_timeout:120s"}, "auto") == "drumsep_runtime_broken"


def test_timeout_markers_name_a_timeout_and_do_not_ask_for_repair(tmp_path, capsys):
    module = _load_module()
    module._emit_direct_dks_stage2_runtime_markers(
        "drumsep_runtime_verify_timeout", tmp_path / ".venv-drumsep" / "python.exe", '{"cpu_detail": "verify_timeout:120s"}'
    )
    err = capsys.readouterr().err

    assert "error_stage=stage2_runtime" in err
    assert "error_reason=drumsep_runtime_verify_timeout" in err
    assert "Direct Drum Kit Split runtime check timed out." in err
    assert "Direct Drum Kit Split runtime is broken." not in err
    assert "Run Setup/Repair Drum Kit Split runtime before" not in err
    assert "Run the job again" in err


def test_broken_markers_are_unchanged(tmp_path, capsys):
    module = _load_module()
    module._emit_direct_dks_stage2_runtime_markers("drumsep_runtime_broken", tmp_path / "python", "import failed")
    err = capsys.readouterr().err

    assert "error_reason=drumsep_runtime_broken" in err
    assert "Direct Drum Kit Split runtime is broken." in err
    assert f"guidance={module.DRUMSEP_RUNTIME_GUIDANCE}" in err


# --- 10: issue #127 layout through the real runtime selection ----------------


class _OsProxy:
    def __init__(self, real_os, *, name: str):
        self._real_os = real_os
        self.name = name
        self.pathsep = ";" if name == "nt" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


def _set_windows(module, monkeypatch):
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="nt"))
    monkeypatch.setattr(module.sys, "platform", "win32")
    monkeypatch.setattr(module.platform, "machine", lambda: "AMD64")


def _issue_127_layout(tmp_path):
    return _make_python(tmp_path / ".venv-drumsep" / "Scripts" / "python.exe")


@pytest.mark.parametrize("requested", ["auto", "cpu"])
def test_issue_127_slow_cpu_runtime_is_selected(tmp_path, monkeypatch, requested):
    module = _load_module()
    _set_windows(module, monkeypatch)
    cpu_python = _issue_127_layout(tmp_path)
    calls = []

    def run(cmd, **kwargs):
        calls.append((cmd[0], kwargs.get("timeout")))
        if kwargs.get("timeout") < 31:
            raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout"))
        return subprocess.CompletedProcess(cmd, 0, json.dumps(OK_PAYLOAD), "")

    _patch_probe(module, monkeypatch, run)
    selected, kind, info = module._select_drumsep_runtime(requested, tmp_path)

    assert selected == cpu_python
    assert kind == "cpu"
    assert info["versions"]["audio-separator"] == "0.34.1"
    assert [c for c in calls if c[0] == str(cpu_python)] == [(str(cpu_python), 120)]


@pytest.mark.parametrize("requested", ["auto", "cpu"])
def test_issue_127_runtime_that_never_answers_is_a_timeout_not_broken(tmp_path, monkeypatch, requested):
    module = _load_module()
    _set_windows(module, monkeypatch)
    _issue_127_layout(tmp_path)
    _patch_probe(module, monkeypatch, _simulated_probe(10_000.0))

    selected, kind, info = module._select_drumsep_runtime(requested, tmp_path)

    assert selected is None
    assert kind == "broken"
    assert module._drumsep_runtime_unavailable_reason(kind, info, requested) == "drumsep_runtime_verify_timeout"


@pytest.mark.parametrize("requested,expected", [("auto", "drumsep_runtime_broken"), ("cpu", "drumsep_cpu_runtime_broken")])
def test_issue_127_runtime_with_import_error_is_still_broken(tmp_path, monkeypatch, requested, expected):
    module = _load_module()
    _set_windows(module, monkeypatch)
    _issue_127_layout(tmp_path)
    failure = json.dumps({"ok": False, "module": "onnxruntime", "error": "ImportError: DLL load failed"})
    _patch_probe(module, monkeypatch, _simulated_probe(5.0, returncode=1, stdout=failure))

    selected, kind, info = module._select_drumsep_runtime(requested, tmp_path)

    assert selected is None
    assert module._drumsep_runtime_unavailable_reason(kind, info, requested) == expected


# --- 8/9: Setup / Repair / Check use their own, unbounded verifiers ----------


def test_setup_repair_and_check_do_not_use_the_processing_verifier():
    reaper = ROOT / "scripts" / "reaper"
    for rel in (
        "STEMwerk_Bootstrap_Windows.ps1",
        "STEMwerk_Bootstrap_Linux.sh",
        "STEMwerk_Bootstrap_macOS.sh",
        "_internal/STEMwerk_Setup_Internal.lua",
        "_internal/STEMwerk_Runtime_Setup.lua",
        "STEMwerk-SETUP.lua",
    ):
        text = (reaper / rel).read_text(encoding="utf-8", errors="replace")
        assert "_verify_drumsep_runtime" not in text, rel
        assert "DRUMSEP_RUNTIME_VERIFY_TIMEOUT" not in text, rel


def test_processing_verification_does_not_persist_runtime_state():
    source = AUDIO_PROCESS.read_text(encoding="utf-8")
    start = source.index("def _probe_drumsep_runtime_candidates(")
    end = source.index("def _resolve_benchmark_drumsep_helper_device(")
    selection = source[start:end]
    for forbidden in ("write_text(", 'open(', "_write_env", "ready_to_go"):
        assert forbidden not in selection.replace("_ready_to_go_state", ""), forbidden


# --- user-facing message (real Lua) ------------------------------------------


def _lua():
    for name in ("lua5.4", "lua", "luajit", "lua5.1"):
        path = shutil.which(name)
        if path:
            return path
    pytest.skip("no Lua interpreter available")


def _render_lua_failure(tmp_path, log_text: str, os_name: str = "Windows") -> str:
    src = MAIN_LUA.read_text(encoding="utf-8")
    start = src.index("local function buildKnownSeparationFailureMessage(")
    end = src.index("\nend\n", start) + len("\nend\n")
    chunk = src[start:end]
    harness = (
        f'OS = "{os_name}"\n'
        "DKS_WORKFLOW = { DIRECT_DKS_MODEL = 'model' }\n"
        "SW_LOG = { getLogPath = function() return 'debug.log' end }\n"
        "function trSafeValue(_, default) return default end\n"
        + chunk
        + "\nlocal f = io.open(arg[1], 'r'); local text = f:read('*a'); f:close()\n"
        "io.write(tostring(buildKnownSeparationFailureMessage(text, 1, 'cmd', 'log.txt', 'debug.log', '')))\n"
    )
    script = tmp_path / "render.lua"
    script.write_text(harness, encoding="utf-8")
    log = tmp_path / "log.txt"
    log.write_text(log_text, encoding="utf-8")
    proc = subprocess.run([_lua(), str(script), str(log)], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


@pytest.mark.parametrize("os_name", ["Windows", "Linux", "macOS"])
def test_ui_reports_a_timeout_without_calling_the_runtime_broken(tmp_path, os_name):
    message = _render_lua_failure(
        tmp_path,
        "error_stage=stage2_runtime\nerror_reason=drumsep_runtime_verify_timeout\n"
        'detail={"cpu_detail": "verify_timeout:120s"}\n',
        os_name,
    )

    assert message.startswith("Drum Kit Split runtime check timed out.")
    assert "is broken" not in message
    assert "Re-run the STEMwerk installer" not in message
    assert "Run the job again" in message
    assert "verify_timeout:120s" in message


def test_ui_broken_runtime_message_is_unchanged(tmp_path):
    message = _render_lua_failure(
        tmp_path,
        "error_stage=stage2_runtime\nerror_reason=drumsep_runtime_broken\ndetail=ImportError\n",
        "Windows",
    )

    assert message.startswith("Drum Kit Split runtime is broken.")
    assert "Re-run the STEMwerk installer to repair the Drum Kit Split runtime." in message
