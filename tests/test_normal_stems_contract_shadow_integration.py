"""End-to-end proof that the Slice-1 contract shadow-diagnostics call inside
`main()`'s default (plain Normal Stems) branch can never affect a real run.

No existing test exercises `main()` through this exact branch (the existing
`test_windows_normal_route_matrix.py` main()-based tests both use
`--workflow-mode drumkit`), so this closes that gap specifically for the new
`_emit_contract_resolution_shadow_diagnostics` call site added at the tail of
the default branch, right after `_resolve_normal_runtime_device`.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_shadow_diag_test", PROCESS_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


class _FakeStemSeparator:
    def __init__(self, model, device):
        self.model = model
        self.device = device
        self.on_progress = None
        self.runtime_evidence = {}

    def separate(self, _input_path, output_dir, stems=None):
        outputs = {}
        for stem in ("vocals", "drums", "bass", "other"):
            path = Path(output_dir) / f"{stem}.wav"
            path.write_bytes(b"")
            outputs[stem] = path
        return SimpleNamespace(stems=outputs, device_used=self.device, elapsed=0.01)


def _run_main(monkeypatch, tmp_path, *, model_name, device):
    module = _load_module()
    monkeypatch.setattr(module, "_setup_reaper_io", lambda _output_dir: (lambda _status: None))
    monkeypatch.setattr(module, "_write_worker_context", lambda _output_dir: None)
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    from stemwerk_core import devices as _core_devices

    module.core_devices = _core_devices
    monkeypatch.setattr(module, "emit_phase", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "_configure_ffmpeg_runtime", lambda: (None, None, None))
    monkeypatch.setattr(module, "_configure_model_cache_runtime", lambda: str(tmp_path / "models"))
    monkeypatch.setattr(
        module,
        "_resolve_normal_runtime_device",
        lambda requested: (requested, device, f"{device}|Fake", [device]),
    )
    monkeypatch.setattr(module, "_emit_runtime_diagnostics", lambda _device: {})
    monkeypatch.setattr(module, "_configure_mps_runtime_fallback", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "_apply_mps_experimental_policy", lambda _req, dev, _model: dev)
    monkeypatch.setattr(module, "_enable_torch_weights_only_compat", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "StemSeparator", _FakeStemSeparator)
    monkeypatch.setattr(
        module,
        "_map_reaper_stems_from_result",
        lambda result, _output_root: {k: str(v) for k, v in result.stems.items()},
    )

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")

    argv = [
        "audio_separator_process.py", str(input_path), str(output_dir),
        "--model", model_name, "--device", device,
    ]
    monkeypatch.setattr(sys, "argv", argv)
    exit_code = module.main()
    return exit_code


def test_catalogued_model_runs_and_emits_agreeing_contract_diagnostics(monkeypatch, tmp_path, capsys):
    exit_code = _run_main(monkeypatch, tmp_path, model_name="htdemucs", device="cpu")
    assert exit_code == 0
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_source=2.4_contract" in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=cpu" in stderr
    assert "STEMWERK_DIAG contract_reason_code=explicit_resolved" in stderr
    assert "contract_resolution_error" not in stderr
    assert "contract_resolution_failed_code" not in stderr


def test_uncatalogued_model_still_completes_the_real_run_untouched(monkeypatch, tmp_path, capsys):
    """htdemucs_6s is a real, currently-supported model that Slice-0's
    catalog does not (yet) list. The shadow contract layer must report this
    as out-of-scope, not interfere with the actual separation."""

    exit_code = _run_main(monkeypatch, tmp_path, model_name="htdemucs_6s", device="cpu")
    assert exit_code == 0
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_resolution_failed_code=unknown_model" in stderr
    assert "contract_resolution_error" not in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=" not in stderr


def test_shadow_diagnostics_helper_never_raises_for_arbitrary_input(monkeypatch, tmp_path, capsys):
    module = _load_module()
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    module.core_devices = SimpleNamespace(runtime_kind_for_device=lambda device_id: "cpu" if device_id == "cpu" else "unknown")

    module._emit_contract_resolution_shadow_diagnostics("not_a_real_workflow", "htdemucs", "auto", "cpu")
    module._emit_contract_resolution_shadow_diagnostics("normal_stems", "totally_bogus_model", "auto", "cpu")
    module._emit_contract_resolution_shadow_diagnostics("normal_stems", "htdemucs", "auto", "cpu")

    stderr = capsys.readouterr().err
    assert stderr.count("contract_resolution_failed_code=unknown_workflow") == 1
    assert stderr.count("contract_resolution_failed_code=unknown_model") == 1
    assert stderr.count("contract_source=2.4_contract") == 1
