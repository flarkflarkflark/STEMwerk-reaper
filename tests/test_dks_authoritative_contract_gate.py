"""Slice-4 end-to-end proof of the authoritative DKS contract gate inside
`main()`'s dks_direct / dks_extract branches.

Supersedes Slice 2's shadow-only behavior for drum_kit_direct /
drum_kit_split: a run whose model/backend can't be resolved through the 2.4
contract layer now aborts (exit code 1, via _finish_benchmark_run) *before*
any expensive processing -- for Drum Split specifically, before stage 1's
Demucs separation even starts, not just before stage 2 -- rather than
merely logging and proceeding as Slice 2 did.

Mirrors tests/test_normal_stems_authoritative_contract_gate.py's structure
and tests/test_windows_normal_route_matrix.py's DKS mocking conventions.
"""

from __future__ import annotations

import importlib.util
import sys
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_dks_gate_test", PROCESS_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _fake_drumsep_stems(stage_root: Path):
    stems = {}
    for stem_name in ("kick", "snare", "hihat", "tom", "cymbals", "room"):
        stem_path = stage_root / f"{stem_name}.wav"
        stem_path.parent.mkdir(parents=True, exist_ok=True)
        stem_path.write_bytes(b"")
        stems[stem_name] = str(stem_path)
    return stems


def _common_mocks(monkeypatch, module, tmp_path):
    monkeypatch.setattr(module, "_setup_reaper_io", lambda _output_dir: (lambda _status: None))
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    from stemwerk_core import devices as _core_devices

    module.core_devices = _core_devices
    module.select_device = _core_devices.select_device
    monkeypatch.setattr(module, "emit_phase", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "_configure_ffmpeg_runtime", lambda: (None, None, None))
    monkeypatch.setattr(module, "_configure_model_cache_runtime", lambda: str(tmp_path / "models"))
    monkeypatch.setattr(module, "_should_use_drumsep_mps_direct_demix", lambda *_a, **_k: (False, ""))
    monkeypatch.setattr(
        module, "_direct_dks_preflight_check",
        lambda requested_model, _model_cache_dir, **_k: (True, requested_model, requested_model, ""),
    )
    monkeypatch.setattr(module, "_detect_dks_extract_stage2_backend", lambda runtime_kind, *_a: runtime_kind)
    monkeypatch.setattr(module, "_resolve_benchmark_drumsep_helper_device", lambda *_a, **_k: ("cpu", ""))
    monkeypatch.setattr(module, "_finish_benchmark_run", lambda _sampler, code: code)
    monkeypatch.setattr(module, "stemwerk_core_file", str(CORE_SRC / "stemwerk_core" / "__init__.py"))


def _run_dks_direct(monkeypatch, tmp_path, *, requested_device, drumsep_runtime_kind, expect_helper_called):
    module = _load_module()
    _common_mocks(monkeypatch, module, tmp_path)

    helper_calls = []

    def helper(*args, **kwargs):
        helper_calls.append((args, kwargs))
        return True, _fake_drumsep_stems(Path(args[1])), "", ""

    monkeypatch.setattr(module, "_select_drumsep_runtime", lambda _requested: ("python", drumsep_runtime_kind, {}))
    monkeypatch.setattr(module, "_run_direct_dks_drumsep_helper", helper)
    monkeypatch.setattr(
        module, "StemSeparator",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("Direct Kit must never construct the normal StemSeparator route")),
    )

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")

    argv = [
        "audio_separator_process.py", str(input_path), str(output_dir),
        "--model", "MDX23C-DrumSep-aufr33-jarredou.ckpt", "--device", requested_device,
        "--workflow-mode", "drumkit", "--workflow-source", "dks_direct",
    ]
    monkeypatch.setattr(sys, "argv", argv)
    exit_code = module.main()
    assert (len(helper_calls) > 0) == expect_helper_called
    return module, exit_code, helper_calls


def test_drum_kit_direct_authoritative_success_cpu(monkeypatch, tmp_path, capsys):
    module, exit_code, helper_calls = _run_dks_direct(
        monkeypatch, tmp_path, requested_device="cpu", drumsep_runtime_kind="cpu", expect_helper_called=True,
    )
    assert exit_code == 0
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_source=2.4_contract" in stderr
    assert "STEMWERK_DIAG contract_workflow_id=drum_kit_direct" in stderr
    assert "STEMWERK_DIAG contract_resolved_backend=cpu" in stderr
    assert "contract_abort_reason" not in stderr
    assert helper_calls[0][1]["backend_runtime"] == "cpu"


def test_drum_kit_direct_unavailable_explicit_backend_fails_closed_before_processing(monkeypatch, tmp_path, capsys):
    """explicit cuda request, but the real _select_drumsep_runtime couldn't
    find a usable runtime at all (python_path=None) -- must reject before
    the demix helper is ever invoked, not silently fall back to CPU."""
    module = _load_module()
    _common_mocks(monkeypatch, module, tmp_path)

    helper_calls = []
    monkeypatch.setattr(module, "_select_drumsep_runtime", lambda _requested: (None, "broken", {}))
    monkeypatch.setattr(module, "_run_direct_dks_drumsep_helper", lambda *a, **k: helper_calls.append((a, k)))
    monkeypatch.setattr(
        module, "_emit_direct_dks_stage2_runtime_markers", lambda *a, **k: None,
    )

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")
    argv = [
        "audio_separator_process.py", str(input_path), str(output_dir),
        "--model", "MDX23C-DrumSep-aufr33-jarredou.ckpt", "--device", "cuda:0",
        "--workflow-mode", "drumkit", "--workflow-source", "dks_direct",
    ]
    monkeypatch.setattr(sys, "argv", argv)
    exit_code = module.main()

    # drumsep_python is None -&gt; the pre-existing runtime-missing gate fires
    # first (legacy behavior, unchanged); the contract gate is never reached
    # for this specific failure mode since main() already returns.
    assert exit_code == 1
    assert helper_calls == []


def test_drum_kit_direct_contract_rejects_when_probe_returns_unrealistic_backend(monkeypatch, tmp_path, capsys):
    """A python_path IS returned (legacy's own missing-runtime gate would
    pass), but the runtime_kind isn't in the known backend vocabulary --
    the contract gate must still reject before the helper runs."""
    module, exit_code, helper_calls = _run_dks_direct(
        monkeypatch, tmp_path, requested_device="cuda:0", drumsep_runtime_kind="cuda:0", expect_helper_called=False,
    )
    assert exit_code == 1
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_resolution_failed_code=backend_unavailable" in stderr
    assert "STEMWERK_DIAG contract_abort_reason=" in stderr
    assert "error_reason=drumsep_contract_rejected" in stderr


def _run_dks_extract(
    monkeypatch, tmp_path, *,
    stage1_requested_device, stage1_resolved_device, stage1_select_device_result,
    drumsep_runtime_kind, expect_stage1_called, expect_helper_called,
):
    module = _load_module()
    _common_mocks(monkeypatch, module, tmp_path)

    stage1_inits = []
    helper_calls = []

    class FakeStemSeparator:
        def __init__(self, model, device):
            stage1_inits.append((model, device))
            self.model = model
            self.device = device
            self.on_progress = None

        def separate(self, _input_path, output_dir, stems=None):
            drums_path = Path(output_dir) / "drums.wav"
            drums_path.write_bytes(b"stage1-drums-content")
            return SimpleNamespace(stems={"drums": drums_path}, device_used=self.device, elapsed=0.01)

    def helper(*args, **kwargs):
        helper_calls.append((args, kwargs))
        return True, _fake_drumsep_stems(Path(args[1])), "", ""

    monkeypatch.setattr(
        module, "_resolve_normal_runtime_device",
        lambda requested: (requested, stage1_resolved_device, f"{stage1_resolved_device}|Preview", [stage1_resolved_device]),
    )
    monkeypatch.setattr(module, "select_device", lambda _requested: stage1_select_device_result)
    monkeypatch.setattr(module, "_select_drumsep_runtime", lambda _requested: ("python", drumsep_runtime_kind, {}))
    monkeypatch.setattr(module, "_emit_runtime_diagnostics", lambda _device: {})
    monkeypatch.setattr(module, "_configure_mps_runtime_fallback", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "_apply_mps_experimental_policy", lambda _req, device, _model: device)
    monkeypatch.setattr(module, "_enable_torch_weights_only_compat", lambda *_a, **_k: None)
    monkeypatch.setattr(module, "_map_reaper_stems_from_result", lambda result, _output_root: result.stems)
    monkeypatch.setattr(module, "_dks_extract_stage2_lock", lambda *_a, **_k: nullcontext())
    monkeypatch.setattr(module, "_working_directory", lambda _path: nullcontext())
    monkeypatch.setattr(module, "_run_direct_dks_drumsep_helper", helper)
    monkeypatch.setattr(module, "StemSeparator", FakeStemSeparator)
    monkeypatch.setattr(
        module, "_emit_direct_dks_stage2_runtime_markers", lambda *a, **k: None,
    )

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")
    argv = [
        "audio_separator_process.py", str(input_path), str(output_dir),
        "--model", "htdemucs", "--device", stage1_requested_device,
        "--workflow-mode", "drumkit", "--workflow-source", "dks_extract",
    ]
    monkeypatch.setattr(sys, "argv", argv)
    exit_code = module.main()

    assert (len(stage1_inits) > 0) == expect_stage1_called
    assert (len(helper_calls) > 0) == expect_helper_called
    return module, exit_code, stage1_inits, helper_calls


def test_drum_kit_split_authoritative_success(monkeypatch, tmp_path, capsys):
    module, exit_code, stage1_inits, helper_calls = _run_dks_extract(
        monkeypatch, tmp_path,
        stage1_requested_device="cpu", stage1_resolved_device="cpu", stage1_select_device_result=("cpu", "CPU"),
        drumsep_runtime_kind="cpu", expect_stage1_called=True, expect_helper_called=True,
    )
    assert exit_code == 0
    assert stage1_inits == [("htdemucs", "cpu")]
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_workflow_id=drum_kit_split" in stderr
    assert stderr.count("STEMWERK_DIAG contract_source=2.4_contract") == 2  # one per stage
    assert "STEMWERK_DIAG contract_stage1_runtime_agrees=True" in stderr
    assert "contract_abort_reason" not in stderr


def test_drum_kit_split_stage2_unavailable_fails_before_stage1_separation(monkeypatch, tmp_path, capsys):
    """The whole point of gating early: if DrumSep stage 2 can't possibly
    run, stage 1's real (expensive) Demucs separation must never start."""
    module, exit_code, stage1_inits, helper_calls = _run_dks_extract(
        monkeypatch, tmp_path,
        stage1_requested_device="cpu", stage1_resolved_device="cpu", stage1_select_device_result=("cpu", "CPU"),
        drumsep_runtime_kind="cuda:0",  # unrealistic -&gt; classified "unavailable"
        expect_stage1_called=False, expect_helper_called=False,
    )
    assert exit_code == 1
    stderr = capsys.readouterr().err
    # requested_device is "cpu" here (both stages share --device), so an
    # "unavailable" DrumSep resolution isn't a downgrade-from-explicit-GPU
    # case -- it's simply not a permitted backend for drum_kit_6.
    assert "STEMWERK_DIAG contract_resolution_failed_code=backend_not_permitted" in stderr
    assert "error_reason=drumsep_contract_rejected" in stderr


def test_drum_kit_split_stage1_disagreement_fails_closed(monkeypatch, tmp_path, capsys):
    """Stage 1 uses a real, independently re-derived probe (unlike stage 2).
    If the contract's independent resolution disagrees with what the legacy
    engine already picked, that must abort, not silently continue."""
    module, exit_code, stage1_inits, helper_calls = _run_dks_extract(
        monkeypatch, tmp_path,
        stage1_requested_device="cpu", stage1_resolved_device="cpu",
        stage1_select_device_result=("directml", "DirectML"),  # disagrees with "cpu"
        drumsep_runtime_kind="cpu", expect_stage1_called=False, expect_helper_called=False,
    )
    assert exit_code == 1
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG contract_stage1_runtime_agrees=False" in stderr
    assert "disagrees with the legacy runtime" in stderr


def test_drum_kit_split_stage2_receives_stage1_drums_artifact(monkeypatch, tmp_path):
    """Proves stage 2's input is exactly the file stage 1 produced as its
    "drums" output -- the inter-stage dependency the drum_kit_split catalog
    entry declares (stage 2 consumes stage 1's "drums" port)."""
    module, exit_code, stage1_inits, helper_calls = _run_dks_extract(
        monkeypatch, tmp_path,
        stage1_requested_device="cpu", stage1_resolved_device="cpu", stage1_select_device_result=("cpu", "CPU"),
        drumsep_runtime_kind="cpu", expect_stage1_called=True, expect_helper_called=True,
    )
    assert exit_code == 0
    helper_args, _helper_kwargs = helper_calls[0]
    stage2_input_path = Path(helper_args[0])
    assert stage2_input_path.name == "drums.wav"
    assert stage2_input_path.read_bytes() == b"stage1-drums-content"
