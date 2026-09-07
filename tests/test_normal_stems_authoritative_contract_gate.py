"""End-to-end proof of the Slice-2 authoritative contract gate inside
`main()`'s default (plain Normal Stems) branch.

Supersedes the Slice-1 file of a similar name: Normal Stems is no longer
shadow-only (see `_enforce_normal_stems_contract` in
scripts/reaper/audio_separator_process.py) -- a run whose model/backend
can't be resolved through the 2.4 contract layer, or whose resolved plan
disagrees with what the legacy engine actually picked, now aborts (exit
code 2) rather than merely logging. No existing test exercises `main()`
through this exact branch (`test_windows_normal_route_matrix.py`'s
main()-based tests both use `--workflow-mode drumkit`), so this file closes
that gap.
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
    spec = importlib.util.spec_from_file_location("audio_separator_process_authoritative_gate_test", PROCESS_SCRIPT)
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
    module.select_device = _core_devices.select_device
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
    assert "STEMWERK_DIAG contract_runtime_agrees=True" in stderr
    assert "contract_resolution_error" not in stderr
    assert "contract_resolution_failed_code" not in stderr


def test_htdemucs_6s_now_resolves_through_the_contract_path(monkeypatch, tmp_path, capsys):
    """Slice 1 left htdemucs_6s out of the catalog (shadow-mode gap); Slice 2
    closes that gap, so it must now resolve successfully end-to-end, to the
    6-stem capability, exactly like htdemucs/htdemucs_ft resolve to the
    4-stem one."""

    exit_code = _run_main(monkeypatch, tmp_path, model_name="htdemucs_6s", device="cpu")
    assert exit_code == 0
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_source=2.4_contract" in stderr
    assert "STEMWERK_DIAG contract_capability_id=normal_stems_6" in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=cpu" in stderr
    assert "STEMWERK_DIAG contract_runtime_agrees=True" in stderr
    assert "contract_resolution_error" not in stderr
    assert "contract_resolution_failed_code" not in stderr


def test_hdemucs_mmi_now_resolves_through_the_contract_path(monkeypatch, tmp_path, capsys):
    """hdemucs_mmi is not user-selectable in the REAPER UI, but the runtime
    accepts it via --model like any other Demucs id; the contract layer must
    resolve it (role=internal, 4-stem capability) rather than reject it."""

    exit_code = _run_main(monkeypatch, tmp_path, model_name="hdemucs_mmi", device="cpu")
    assert exit_code == 0
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_source=2.4_contract" in stderr
    assert "STEMWERK_DIAG contract_capability_id=normal_stems_4" in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=cpu" in stderr
    assert "contract_resolution_error" not in stderr
    assert "contract_resolution_failed_code" not in stderr


def test_genuinely_unknown_model_is_now_rejected_before_processing(monkeypatch, tmp_path, capsys):
    """Normal Stems is authoritative now: a model the contract layer has
    never heard of must abort the run before any separation work starts,
    not silently proceed as it did in Slice 1's shadow mode."""

    exit_code = _run_main(monkeypatch, tmp_path, model_name="some_future_model_not_yet_catalogued", device="cpu")
    assert exit_code == 2
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_resolution_failed_code=unknown_model" in stderr
    assert "STEMWERK_DIAG contract_abort_reason=" in stderr
    assert "contract_resolution_error" not in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=" not in stderr


def test_enforce_contract_helper_never_raises_for_arbitrary_input(monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    module.core_devices = SimpleNamespace(
        runtime_kind_for_device=lambda device_id: "cpu" if device_id == "cpu" else "unknown",
        get_available_devices=lambda: [{"id": "cpu", "name": "CPU", "type": "cpu"}],
    )
    module.select_device = lambda requested: ("cpu", "CPU")
    monkeypatch.setattr(module, "_is_unexpected_cpu_downgrade", lambda _requested, _resolved: False)

    assert module._enforce_normal_stems_contract("htdemucs", "cpu", "cpu") is None

    reason = module._enforce_normal_stems_contract("totally_bogus_model", "cpu", "cpu")
    assert reason is not None
    assert "unknown_model" in reason

    reason = module._enforce_normal_stems_contract("htdemucs", "cpu", "some_other_device")
    assert reason is not None
    assert "disagrees" in reason
