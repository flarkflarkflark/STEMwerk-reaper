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

import errno
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

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
    seen_inputs = []
    seen_input_contents = []
    seen_input_identities = []
    seen_working_directories = []

    def __init__(self, model, device):
        self.model = model
        self.device = device
        self.on_progress = None
        self.runtime_evidence = {}

    def separate(self, input_path, output_dir, stems=None):
        input_path = Path(input_path)
        self.seen_inputs.append(input_path)
        self.seen_working_directories.append(Path.cwd())
        if not input_path.exists():
            raise FileNotFoundError(f"Input file not found: {input_path}")
        self.seen_input_contents.append(input_path.read_bytes())
        input_stat = input_path.stat()
        self.seen_input_identities.append((input_stat.st_dev, input_stat.st_ino))
        outputs = {}
        for stem in ("vocals", "drums", "bass", "other"):
            path = Path(output_dir) / f"{stem}.wav"
            path.write_bytes(b"")
            outputs[stem] = path
        return SimpleNamespace(stems=outputs, device_used=self.device, elapsed=0.01)


def _run_main(
    monkeypatch,
    tmp_path,
    *,
    model_name,
    device,
    input_path=None,
    input_argument=None,
    output_dir=None,
    create_input=True,
):
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
    _FakeStemSeparator.seen_inputs.clear()
    _FakeStemSeparator.seen_input_contents.clear()
    _FakeStemSeparator.seen_input_identities.clear()
    _FakeStemSeparator.seen_working_directories.clear()
    monkeypatch.setattr(
        module,
        "_map_reaper_stems_from_result",
        lambda result, _output_root: {k: str(v) for k, v in result.stems.items()},
    )

    input_path = input_path or tmp_path / "input.wav"
    output_dir = output_dir or tmp_path / "out"
    if create_input:
        input_path.parent.mkdir(parents=True, exist_ok=True)
        input_path.write_bytes(b"RIFF")

    argv = [
        "audio_separator_process.py", input_argument or str(input_path), str(output_dir),
        "--model", model_name, "--device", device,
    ]
    monkeypatch.setattr(sys, "argv", argv)
    exit_code = module.main()
    return exit_code


def test_relative_input_is_anchored_before_output_working_directory_change(monkeypatch, tmp_path):
    caller_dir = tmp_path / "caller directory"
    input_path = caller_dir / "input files" / "töne 测试.wav"
    output_dir = tmp_path / "separate output directory"
    caller_dir.mkdir()
    monkeypatch.chdir(caller_dir)

    exit_code = _run_main(
        monkeypatch,
        tmp_path,
        model_name="htdemucs",
        device="cpu",
        input_path=input_path,
        input_argument=str(input_path.relative_to(caller_dir)),
        output_dir=output_dir,
    )

    assert exit_code == 0
    assert _FakeStemSeparator.seen_inputs == [input_path]
    assert _FakeStemSeparator.seen_working_directories == [output_dir]


def test_relative_input_preserves_symlink_parent_traversal_across_working_directory_change(
    monkeypatch, tmp_path
):
    caller_dir = tmp_path / "caller directory"
    symlink_target = tmp_path / "symlink target" / "nested directory"
    intended_input = symlink_target.parent / "selected.wav"
    lexical_decoy = caller_dir / "selected.wav"
    output_dir = tmp_path / "separate output directory"
    caller_dir.mkdir()
    symlink_target.mkdir(parents=True)
    intended_input.write_bytes(b"selected through symlink parent")
    lexical_decoy.write_bytes(b"lexically collapsed decoy")
    try:
        (caller_dir / "input link").symlink_to(symlink_target, target_is_directory=True)
    except OSError as exc:
        unavailable_errors = {
            errno.EACCES,
            errno.ENOSYS,
            errno.EPERM,
            getattr(errno, "EOPNOTSUPP", -1),
        }
        if exc.errno not in unavailable_errors and getattr(exc, "winerror", None) != 1314:
            raise
        pytest.skip(f"directory symlinks are unavailable: {exc}")
    input_argument = "input link/../selected.wav"
    monkeypatch.chdir(caller_dir)
    selected_before = Path(input_argument).stat()

    exit_code = _run_main(
        monkeypatch,
        tmp_path,
        model_name="htdemucs",
        device="cpu",
        input_path=intended_input,
        input_argument=input_argument,
        output_dir=output_dir,
        create_input=False,
    )

    assert exit_code == 0
    assert _FakeStemSeparator.seen_input_contents == [b"selected through symlink parent"]
    assert _FakeStemSeparator.seen_input_identities == [(selected_before.st_dev, selected_before.st_ino)]
    assert _FakeStemSeparator.seen_working_directories == [output_dir]


def test_missing_relative_input_reports_the_original_caller_argument(monkeypatch, tmp_path, capsys):
    caller_dir = tmp_path / "caller directory"
    caller_dir.mkdir()
    monkeypatch.chdir(caller_dir)

    exit_code = _run_main(
        monkeypatch,
        tmp_path,
        model_name="htdemucs",
        device="cpu",
        input_path=caller_dir / "missing files" / "not here.wav",
        input_argument="missing files/not here.wav",
        output_dir=tmp_path / "separate output directory",
        create_input=False,
    )

    assert exit_code == 1
    assert "ERROR: Input file not found: missing files/not here.wav" in capsys.readouterr().err
    assert _FakeStemSeparator.seen_inputs == []


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
