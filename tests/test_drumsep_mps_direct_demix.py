import importlib.util
import inspect
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
AUDIO_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
DRUMSEP_HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"


def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_audio_process():
    return _load_module(AUDIO_PROCESS, "audio_separator_process_mps_direct_demix_test")


def _load_helper():
    return _load_module(DRUMSEP_HELPER, "stemwerk_drumsep_process_mps_direct_demix_test")


def _valid_runtime_info():
    return {
        "kind": "mps",
        "mps_built": True,
        "mps_available": True,
        "mps_experimental": True,
        "versions": {
            "audio-separator": "0.23.0",
            "torch": "2.5.1",
            "onnxruntime": "1.26.0",
        },
    }


def _gate(module, runtime_info=None, requested_device="mps", model=None):
    return module._should_use_drumsep_mps_direct_demix(
        "dks_direct",
        "dks_direct",
        requested_device,
        _valid_runtime_info() if runtime_info is None else runtime_info,
        model or module.DIRECT_DKS_MODEL_ALIAS,
    )


def test_gate_accepts_only_explicit_apple_silicon_mps(monkeypatch):
    module = _load_audio_process()
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    monkeypatch.delenv(module.MPS_FALLBACK_ENV, raising=False)

    assert _gate(module) == (True, "ok")


@pytest.mark.parametrize(
    ("mutation", "reason"),
    [
        ("route", "not_direct_kit_stage2"),
        ("platform", "platform_not_darwin"),
        ("machine", "machine_not_apple_silicon"),
        ("auto", "requested_device_not_explicit_mps"),
        ("runtime", "effective_runtime_not_mps"),
        ("built", "mps_not_built"),
        ("available", "mps_not_available"),
        ("version", "audio_separator_version_not_0_23_0"),
        ("model", "unsupported_drumsep_model"),
        ("fallback", "pytorch_mps_fallback_env_set"),
        ("experimental", "mps_experimental_policy_inactive"),
    ],
)
def test_gate_rejects_each_failed_condition(monkeypatch, mutation, reason):
    module = _load_audio_process()
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    monkeypatch.delenv(module.MPS_FALLBACK_ENV, raising=False)
    info = _valid_runtime_info()
    workflow_mode = "dks_direct"
    workflow_source = "dks_direct"
    requested_device = "mps"
    model = module.DIRECT_DKS_MODEL_ALIAS

    if mutation == "route":
        workflow_mode, workflow_source = "stems", "normal"
    elif mutation == "platform":
        monkeypatch.setattr(module.sys, "platform", "linux")
    elif mutation == "machine":
        monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    elif mutation == "auto":
        requested_device = "auto"
    elif mutation == "runtime":
        info["kind"] = "cpu"
    elif mutation == "built":
        info["mps_built"] = False
    elif mutation == "available":
        info["mps_available"] = False
    elif mutation == "version":
        info["versions"]["audio-separator"] = "0.34.1"
    elif mutation == "model":
        model = module.DIRECT_DKS_MODEL_FILENAME
    elif mutation == "fallback":
        monkeypatch.setenv(module.MPS_FALLBACK_ENV, "1")
    elif mutation == "experimental":
        info["mps_experimental"] = False

    assert module._should_use_drumsep_mps_direct_demix(
        workflow_mode,
        workflow_source,
        requested_device,
        info,
        model,
    ) == (False, reason)


def test_auto_linux_and_rocm_do_not_activate_direct_demix(monkeypatch):
    module = _load_audio_process()
    monkeypatch.delenv(module.MPS_FALLBACK_ENV, raising=False)
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(module.sys, "platform", "darwin")
    assert _gate(module, requested_device="auto") == (False, "requested_device_not_explicit_mps")

    monkeypatch.setattr(module.sys, "platform", "linux")
    rocm = _valid_runtime_info()
    rocm["kind"] = "rocm"
    assert _gate(module, runtime_info=rocm) == (False, "platform_not_darwin")
    helper_signature = inspect.signature(module._run_direct_dks_drumsep_helper)
    assert helper_signature.parameters["route"].default == "wrapper"
    assert helper_signature.parameters["device"].default == "cpu"
    source = AUDIO_PROCESS.read_text(encoding="utf-8")
    assert 'device="mps" if use_mps_direct_demix else "cpu"' in source


def test_explicit_mps_runtime_selection_uses_normal_runtime_candidates(tmp_path, monkeypatch):
    module = _load_audio_process()
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    shared_python = tmp_path / ".venv" / "bin" / "python"
    shared_python.parent.mkdir(parents=True)
    shared_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shared_python.chmod(0o755)
    (state_dir / "drumsep_runtime.env").write_text(f"PYTHON_PATH={shared_python}\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")

    def fake_verify(path, require_gpu=False, require_mps=False):
        assert path == shared_python
        assert require_gpu is False
        assert require_mps is True
        return True, "ok", {
            "mps_built": True,
            "mps_available": True,
            "versions": {"audio-separator": "0.23.0"},
        }

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("mps", tmp_path)

    assert selected == shared_python
    assert kind == "mps"
    assert info["selection_policy"] == "explicit_mps"
    assert info["mps_experimental"] is True


def test_wrapper_0230_backend_limit_remains_when_override_is_inactive():
    module = _load_audio_process()
    payload = module._direct_dks_backend_limit_payload(
        {"versions": {"audio-separator": "0.23.0"}},
        module.DIRECT_DKS_MODEL_FILENAME,
        {"yaml_training_instruments": ["Kick", "Snare", "Toms", "Hh", "Ride", "Crash"]},
    )

    assert payload is not None
    assert payload["output_validation_reason"] == module.DRUMSEP_RUNTIME_LIMIT_REASON
    assert payload["found_stems"] == ["kick", "snare"]


def test_hh_mapping_uses_hihat_internal_name_and_hi_hat_filename():
    helper = _load_helper()

    assert helper.normalize_stem_name("Hh") == "hihat"
    assert helper.REAPER_FILENAMES["hihat"] == "hi-hat.wav"


def test_found_stems_use_canonical_contract_order():
    helper = _load_helper()
    stems = {
        "crash": "crash.wav",
        "hihat": "hi-hat.wav",
        "kick": "kick.wav",
        "ride": "ride.wav",
        "snare": "snare.wav",
        "toms": "toms.wav",
    }

    assert helper._ordered_found_stems(stems) == list(helper.EXPECTED_STEMS)


def _complete_sources():
    return {
        "Kick": np.full((2, 64), 0.10, dtype=np.float32),
        "Snare": np.full((2, 64), 0.20, dtype=np.float32),
        "Toms": np.full((2, 64), 0.30, dtype=np.float32),
        "Hh": np.full((2, 64), 0.04, dtype=np.float32),
        "Ride": np.full((2, 64), 0.05, dtype=np.float32),
        "Crash": np.full((2, 64), 0.06, dtype=np.float32),
    }


def test_direct_demix_key_contract_rejects_missing_unknown_and_duplicate():
    helper = _load_helper()

    missing = _complete_sources()
    missing.pop("Crash")
    with pytest.raises(helper.DirectDemixValidationError, match="Missing direct-demix keys"):
        helper._validate_direct_demix_sources(missing)

    unknown = _complete_sources()
    unknown["Cowbell"] = unknown.pop("Crash")
    with pytest.raises(helper.DirectDemixValidationError, match="Unknown direct-demix keys"):
        helper._validate_direct_demix_sources(unknown)

    duplicate = _complete_sources()
    duplicate["Hi-Hat"] = duplicate["Hh"]
    with pytest.raises(helper.DirectDemixValidationError, match="normalize to hihat"):
        helper._validate_direct_demix_sources(duplicate)


class _FakeParameter:
    def __init__(self, device):
        self.device = device


class _FakeModelRun:
    def __init__(self, device):
        self.device = device

    def parameters(self):
        return iter([_FakeParameter(self.device)])


class _FakeModel:
    def __init__(self, sources, device="mps:0"):
        self.sources = sources
        self.model_run = _FakeModelRun(device)

    def prepare_mix(self, _path):
        return np.zeros((2, 64), dtype=np.float32)

    def demix(self, mix):
        assert mix.shape == (2, 64)
        return self.sources


class _FakeSeparator:
    def __init__(self, sources, torch_device="mps", model_device="mps:0"):
        self.torch_device = torch_device
        self.model_instance = _FakeModel(sources, model_device)
        self.normalization_threshold = 0.9
        self.amplification_threshold = 0.0
        self.sample_rate = 44100


def _install_fake_spec_utils(monkeypatch):
    spec_utils = SimpleNamespace(normalize=lambda wave, max_peak, min_peak: wave)
    monkeypatch.setitem(
        sys.modules,
        "audio_separator.separator.uvr_lib_v5",
        SimpleNamespace(spec_utils=spec_utils),
    )


@pytest.mark.parametrize(
    ("torch_device", "model_device", "reason"),
    [
        ("cpu", "cpu", "effective_device_not_mps"),
        ("mps", "unknown", "model_device_not_mps"),
    ],
)
def test_direct_demix_rejects_cpu_or_unknown_model_device(
    tmp_path,
    monkeypatch,
    torch_device,
    model_device,
    reason,
):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    monkeypatch.delenv("PYTORCH_ENABLE_MPS_FALLBACK", raising=False)
    separator = _FakeSeparator(_complete_sources(), torch_device, model_device)

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._run_drumsep_mps_all_targets_direct_demix(
            separator,
            tmp_path / "input.wav",
            tmp_path,
            {},
        )

    assert exc_info.value.reason == reason


def test_direct_demix_rejects_enabled_pytorch_fallback(tmp_path, monkeypatch):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    monkeypatch.setenv("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._run_drumsep_mps_all_targets_direct_demix(
            _FakeSeparator(_complete_sources()),
            tmp_path / "input.wav",
            tmp_path,
            {},
        )

    assert exc_info.value.reason == "pytorch_mps_fallback_env_set"


def test_synthetic_direct_demix_writes_six_valid_outputs(tmp_path, monkeypatch):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    monkeypatch.delenv("PYTORCH_ENABLE_MPS_FALLBACK", raising=False)
    separator = _FakeSeparator(_complete_sources())

    stems = helper._run_drumsep_mps_all_targets_direct_demix(
        separator,
        tmp_path / "input.wav",
        tmp_path,
        {"training_instruments": list(helper.DIRECT_DEMIX_KEYS)},
    )

    assert set(stems) == set(helper.EXPECTED_STEMS)
    assert Path(stems["hihat"]).name == "hi-hat.wav"
    for stem_name, path_text in stems.items():
        path = Path(path_text)
        info = sf.info(path)
        assert path.name == helper.REAPER_FILENAMES[stem_name]
        assert info.samplerate == 44100
        assert info.channels == 2
        assert info.frames == 64
        assert path.stat().st_size > 44
