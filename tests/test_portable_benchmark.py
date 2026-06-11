import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools" / "benchmark" / "stemwerk_benchmark.py"
PRESETS = ROOT / "tools" / "benchmark" / "presets"


def _load_runner():
    module_name = "stemwerk_portable_benchmark_test"
    spec = importlib.util.spec_from_file_location(module_name, RUNNER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_presets_are_valid_and_reference_expected_audio():
    module = _load_runner()
    expected = {
        "smoke": "stemwerk-benchmark-30s.wav",
        "standard": "stemwerk-benchmark-2min.wav",
        "full": "stemwerk-benchmark-4min.wav",
    }
    for name, audio_file in expected.items():
        preset = module.load_preset(PRESETS / f"{name}.json")
        assert preset["name"] == name
        assert preset["audio_file"] == audio_file


def test_x_realtime_and_result_folder_name():
    module = _load_runner()
    assert module.calculate_x_realtime(30.0, 12.0) == pytest.approx(2.5)
    assert module.calculate_x_realtime(30.0, 0.0) == 0.0
    name = module.result_folder_name("bench host", datetime(2026, 6, 11, 7, 8, 9))
    assert name == "bench-host-20260611-070809"


@pytest.mark.parametrize(
    ("system", "expected"),
    [
        ("Linux", ".local/share/STEMwerk"),
        ("Darwin", "Library/Application Support/STEMwerk"),
    ],
)
def test_runtime_root_detection_candidates(system, expected, tmp_path):
    module = _load_runner()
    candidates = module.runtime_root_candidates(system=system, home=tmp_path)
    assert expected in str(candidates[0])


def test_detect_runtime_uses_existing_managed_python_and_state(monkeypatch, tmp_path):
    module = _load_runner()
    root = tmp_path / "STEMwerk"
    python_path = root / ".venv" / "bin" / "python"
    python_path.parent.mkdir(parents=True)
    python_path.write_text("", encoding="utf-8")
    state = root / "state" / "bootstrap.env"
    state.parent.mkdir()
    state.write_text("STATUS=ok\n", encoding="utf-8")
    process_script = tmp_path / "audio_separator_process.py"
    process_script.write_text("", encoding="utf-8")
    monkeypatch.setattr(module, "_live_script_candidates", lambda _system, _home: [process_script])

    runtime = module.detect_runtime(system="Linux", home=tmp_path, roots=[root])

    assert runtime.root == root
    assert runtime.python == python_path
    assert runtime.state_files["bootstrap.env"]["STATUS"] == "ok"


def test_dry_run_command_planning_for_all_workflows(tmp_path):
    module = _load_runner()
    runtime = module.RuntimeInfo(
        root=tmp_path / "runtime",
        python=tmp_path / "runtime" / ".venv" / "bin" / "python",
        process_script=tmp_path / "audio_separator_process.py",
        model_cache=tmp_path / "runtime" / "models",
        state_files={},
    )
    audio = tmp_path / "input.wav"
    output = tmp_path / "output"

    normal = module.build_command(runtime, audio, output, "normal", "htdemucs", "auto")
    direct = module.build_command(runtime, audio, output, "dks_direct", "DrumSep", "rocm")
    extract = module.build_command(runtime, audio, output, "dks_extract", "Quality", "auto")

    assert ["--workflow-mode", "stems", "--workflow-source", "normal"] == normal[-4:]
    assert "MDX23C-DrumSep-aufr33-jarredou.ckpt" in direct
    assert "dks_direct" in direct
    assert "htdemucs_ft" in extract
    assert "dks_extract" in extract


def test_load_preset_rejects_invalid_workflow(tmp_path):
    module = _load_runner()
    path = tmp_path / "bad.json"
    path.write_text(
        json.dumps({
            "schema_version": 1,
            "name": "bad",
            "audio_file": "test.wav",
            "jobs": [{"workflow": "reaper_gui", "mode": "x", "runs": ["cold"]}],
        }),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="unsupported workflow"):
        module.load_preset(path)
