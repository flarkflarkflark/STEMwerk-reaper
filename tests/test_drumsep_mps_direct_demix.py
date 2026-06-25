import importlib.util
import inspect
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest


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


class _OsProxy:
    def __init__(self, real_os, *, name: str):
        self._real_os = real_os
        self.name = name
        self.pathsep = ":" if name == "posix" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


def _set_posix_platform(module, monkeypatch, sys_platform: str, machine: str = "x86_64"):
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    monkeypatch.setattr(module.sys, "platform", sys_platform)
    monkeypatch.setattr(module.platform, "machine", lambda: machine)


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
        ("runtime", "effective_runtime_not_direct_demix_capable"),
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
    elif mutation == "runtime":
        info["kind"] = "rocm"
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
    auto_mps = _valid_runtime_info()
    auto_mps["kind"] = "mps"
    assert _gate(module, runtime_info=auto_mps, requested_device="auto") == (True, "ok")

    cpu_runtime = _valid_runtime_info()
    cpu_runtime["kind"] = "cpu"
    cpu_runtime["mps_built"] = False
    cpu_runtime["mps_available"] = False
    cpu_runtime["mps_experimental"] = False
    assert _gate(module, runtime_info=cpu_runtime, requested_device="cpu") == (True, "ok")

    monkeypatch.setattr(module.sys, "platform", "linux")
    rocm = _valid_runtime_info()
    rocm["kind"] = "rocm"
    assert _gate(module, runtime_info=rocm) == (False, "platform_not_darwin")
    helper_signature = inspect.signature(module._run_direct_dks_drumsep_helper)
    assert helper_signature.parameters["route"].default == "wrapper"
    assert helper_signature.parameters["device"].default == "cpu"
    source = AUDIO_PROCESS.read_text(encoding="utf-8")
    assert 'route="direct-demix" if use_direct_demix else "wrapper"' in source
    assert 'device=direct_demix_device if use_direct_demix else helper_device' in source


def test_benchmark_helper_device_defaults_to_cpu_and_rejects_invalid(monkeypatch, capsys):
    module = _load_audio_process()
    _set_posix_platform(module, monkeypatch, "linux")
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)
    assert module._resolve_benchmark_drumsep_helper_device("auto", "rocm") == ("rocm", "auto_rocm_default")
    assert module._resolve_benchmark_drumsep_helper_device("cuda:0", "rocm") == ("rocm", "explicit_rocm_default")
    assert module._resolve_benchmark_drumsep_helper_device("auto", "cpu") == ("cpu", "not_requested")

    monkeypatch.setenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "vulkan")
    assert module._resolve_benchmark_drumsep_helper_device("auto", "rocm") == ("cpu", "invalid_request")
    assert "bench_drumsep_helper_device_ignored_reason=invalid_request" in capsys.readouterr().err


def test_verified_linux_cuda_helper_device_defaults_to_cuda_without_benchmark_override(monkeypatch, tmp_path, capsys):
    module = _load_audio_process()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module, "_probe_cuda_helper_isolation", lambda _runtime: (True, "ok", "{}"))

    assert module._resolve_benchmark_drumsep_helper_device("auto", "cuda", runtime_python) == (
        "cuda",
        "auto_cuda_default",
    )
    stderr = capsys.readouterr().err
    assert "bench_drumsep_helper_device_applied=cuda" in stderr
    assert "bench_drumsep_helper_device_ignored_reason=auto_cuda_default" in stderr


def test_verified_linux_cuda_helper_device_falls_back_to_cpu_when_probe_fails(monkeypatch, tmp_path, capsys):
    module = _load_audio_process()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(
        module,
        "_probe_cuda_helper_isolation",
        lambda _runtime: (False, "cuda_helper_probe_runtime_missing", "missing"),
    )

    assert module._resolve_benchmark_drumsep_helper_device("auto", "cuda", runtime_python) == (
        "cpu",
        "cuda_helper_probe_runtime_missing",
    )
    stderr = capsys.readouterr().err
    assert "bench_drumsep_helper_device_applied=none" in stderr
    assert "bench_drumsep_helper_device_ignored_reason=cuda_helper_probe_runtime_missing" in stderr


def test_benchmark_rocm_helper_device_requires_matching_linux_runtime(monkeypatch):
    module = _load_audio_process()
    monkeypatch.setenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "rocm")
    monkeypatch.setattr(module.sys, "platform", "linux")
    assert module._resolve_benchmark_drumsep_helper_device("auto", "rocm") == ("rocm", "")
    assert module._resolve_benchmark_drumsep_helper_device("cpu", "rocm") == ("cpu", "explicit_cpu")
    assert module._resolve_benchmark_drumsep_helper_device("auto", "cpu") == ("cpu", "runtime_backend_mismatch")


def test_benchmark_cuda_helper_device_requires_successful_isolation_probe(monkeypatch, tmp_path):
    module = _load_audio_process()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "cuda")
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module, "_probe_cuda_helper_isolation", lambda _runtime: (True, "ok", "{}"))

    assert module._resolve_benchmark_drumsep_helper_device("auto", "cuda", runtime_python) == ("cuda", "")


def test_benchmark_directml_helper_device_defaults_to_directml_on_windows_auto(monkeypatch, capsys):
    module = _load_audio_process()
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="nt"))
    assert module._resolve_benchmark_drumsep_helper_device("auto", "directml") == ("directml", "auto_directml_default")
    stderr = capsys.readouterr().err
    assert "bench_drumsep_helper_device_applied=directml" in stderr
    assert "bench_drumsep_helper_device_ignored_reason=auto_directml_default" in stderr


def test_helper_gpu_probe_accepts_rocm_tensor(monkeypatch):
    helper = _load_helper()

    class FakeVersion:
        hip = "6.4"
        cuda = None

    class FakeCuda:
        @staticmethod
        def is_available():
            return True

        @staticmethod
        def get_device_name(_index):
            return "AMD Test GPU"

    class FakeTensor:
        device = "cuda:0"

    fake_torch = SimpleNamespace(
        version=FakeVersion(),
        cuda=FakeCuda(),
        ones=lambda *_args, **_kwargs: FakeTensor(),
    )
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    ok, reason, payload = helper._probe_gpu_device("rocm")
    assert ok is True
    assert reason == "ok"
    assert payload["tensor_device"] == "cuda:0"


def test_helper_gpu_probe_rejects_cuda_request_on_rocm(monkeypatch):
    helper = _load_helper()
    fake_torch = SimpleNamespace(
        version=SimpleNamespace(hip="6.4", cuda=None),
        cuda=SimpleNamespace(is_available=lambda: True),
    )
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    ok, reason, _payload = helper._probe_gpu_device("cuda")
    assert ok is False
    assert reason == "cuda_runtime_is_rocm"


def test_explicit_mps_runtime_selection_uses_normal_runtime_candidates(tmp_path, monkeypatch):
    module = _load_audio_process()
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    shared_python = tmp_path / ".venv" / "bin" / "python"
    shared_python.parent.mkdir(parents=True)
    shared_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shared_python.chmod(0o755)
    (state_dir / "drumsep_runtime.env").write_text(f"PYTHON_PATH={shared_python}\n", encoding="utf-8")
    _set_posix_platform(module, monkeypatch, "darwin", "arm64")

    def fake_verify(path, require_gpu=False, require_mps=False, require_directml=False):
        assert path == shared_python
        assert require_gpu is False
        assert require_mps is True
        assert require_directml is False
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


def test_drumsep_runtime_selector_prefers_mps_for_auto_on_apple_silicon(tmp_path, monkeypatch):
    module = _load_audio_process()
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    shared_python = tmp_path / ".venv" / "bin" / "python"
    shared_python.parent.mkdir(parents=True, exist_ok=True)
    shared_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shared_python.chmod(0o755)
    (state_dir / "ready_to_go.env").write_text(
        "READY_TO_GO_STATUS=ok\n"
        "MAIN_RUNTIME_STATUS=ok\n"
        "DRUMSEP_READY_RUNTIME=mps\n"
        "DRUMSEP_READY_RUNTIME_STATUS=ok\n"
        "DRUMSEP_READY_MODEL_STATUS=ok\n",
        encoding="utf-8",
    )
    _set_posix_platform(module, monkeypatch, "darwin", "arm64")

    def fake_verify(path, require_gpu=False, require_mps=False, require_directml=False):
        assert path == shared_python
        assert require_directml is False
        if require_mps:
            return True, "ok", {"mps_built": True, "mps_available": True, "versions": {"audio-separator": "0.23.0"}}
        return True, "ok", {"versions": {"audio-separator": "0.23.0"}}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert selected == shared_python
    assert kind == "mps"
    assert info["selection_policy"] == "auto_prefer_mps"


def test_drumsep_runtime_selector_falls_back_to_cpu_direct_demix_when_mps_missing(tmp_path, monkeypatch):
    module = _load_audio_process()
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    shared_python = tmp_path / ".venv" / "bin" / "python"
    shared_python.parent.mkdir(parents=True, exist_ok=True)
    shared_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shared_python.chmod(0o755)
    (state_dir / "ready_to_go.env").write_text(
        "READY_TO_GO_STATUS=ok\n"
        "MAIN_RUNTIME_STATUS=ok\n"
        "DRUMSEP_READY_RUNTIME=mps\n"
        "DRUMSEP_READY_RUNTIME_STATUS=ok\n"
        "DRUMSEP_READY_MODEL_STATUS=ok\n",
        encoding="utf-8",
    )
    _set_posix_platform(module, monkeypatch, "darwin", "arm64")

    def fake_verify(path, require_gpu=False, require_mps=False, require_directml=False):
        assert path == shared_python
        assert require_directml is False
        if require_mps:
            return False, "mps_not_available", {"versions": {"audio-separator": "0.23.0"}}
        return True, "ok", {"versions": {"audio-separator": "0.23.0"}}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert selected == shared_python
    assert kind == "cpu"
    assert info["selection_policy"] == "fallback_cpu_direct_demix"
    assert info["fallback_reason"] == "mps_skipped:mps_not_available"


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


def _install_fake_soundfile(monkeypatch):
    monkeypatch.setitem(sys.modules, "soundfile", SimpleNamespace())


class _FakeSoundFileInfo:
    def __init__(self, samplerate=44100, frames=64, channels=2):
        self.samplerate = samplerate
        self.frames = frames
        self.channels = channels


def _install_fake_soundfile_module(monkeypatch):
    written = {}

    def write(path, data, samplerate):
        path_obj = Path(path)
        path_obj.write_bytes(b"RIFF" + (b"0" * 64))
        written[str(path_obj)] = _FakeSoundFileInfo(
            samplerate=int(samplerate),
            frames=int(data.shape[0]),
            channels=int(data.shape[1]) if len(data.shape) > 1 else 1,
        )

    def info(path):
        return written[str(Path(path))]

    monkeypatch.setitem(sys.modules, "soundfile", SimpleNamespace(write=write, info=info))
    return written


def _fake_audio_separator_package(separator_cls):
    separator_module = SimpleNamespace(Separator=separator_cls)
    return SimpleNamespace(separator=separator_module), separator_module


@pytest.mark.parametrize(
    ("torch_device", "model_device", "requested_device", "reason"),
    [
        ("cpu", "cpu", "mps", "effective_device_not_mps"),
        ("mps", "unknown", "mps", "model_device_not_mps"),
        ("mps", "mps:0", "cpu", "effective_device_not_cpu"),
        ("cpu", "unknown", "cpu", "model_device_not_cpu"),
    ],
)
def test_direct_demix_rejects_cpu_or_unknown_model_device(
    tmp_path,
    monkeypatch,
    torch_device,
    model_device,
    requested_device,
    reason,
):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    _install_fake_soundfile(monkeypatch)
    monkeypatch.delenv("PYTORCH_ENABLE_MPS_FALLBACK", raising=False)
    separator = _FakeSeparator(_complete_sources(), torch_device, model_device)

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._run_drumsep_all_targets_direct_demix(
            separator,
            tmp_path / "input.wav",
            tmp_path,
            {},
            requested_device,
        )

    assert exc_info.value.reason == reason


def test_direct_demix_rejects_enabled_pytorch_fallback(tmp_path, monkeypatch):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    _install_fake_soundfile(monkeypatch)
    monkeypatch.setenv("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        helper._run_drumsep_mps_all_targets_direct_demix(
            _FakeSeparator(_complete_sources()),
            tmp_path / "input.wav",
            tmp_path,
            {},
        )

    assert exc_info.value.reason == "pytorch_mps_fallback_env_set"


def test_direct_demix_accepts_cpu_device_and_writes_outputs(tmp_path, monkeypatch):
    helper = _load_helper()
    _install_fake_spec_utils(monkeypatch)
    written = _install_fake_soundfile_module(monkeypatch)
    monkeypatch.delenv("PYTORCH_ENABLE_MPS_FALLBACK", raising=False)
    separator = _FakeSeparator(_complete_sources(), torch_device="cpu", model_device="cpu")

    stems = helper._run_drumsep_all_targets_direct_demix(
        separator,
        tmp_path / "input.wav",
        tmp_path,
        {},
        "cpu",
    )

    assert set(stems) == set(helper.EXPECTED_STEMS)
    assert written[str(Path(stems["kick"]))].samplerate == 44100


def test_wrapper_helper_result_uses_runtime_and_requested_device_markers(tmp_path, monkeypatch):
    helper = _load_helper()

    class FakeSeparator:
        def __init__(self, **kwargs):
            self.output_dir = Path(kwargs["output_dir"])
            self.torch_device = "cuda"
            self.model_instance = _FakeModel(_complete_sources(), "cuda:0")

        def load_model(self, _model_name):
            return None

        def separate(self, _input_path):
            outputs = []
            for stem_name, filename in helper.REAPER_FILENAMES.items():
                path = self.output_dir / filename
                path.write_bytes(stem_name.encode("ascii"))
                outputs.append(str(path))
            return outputs

    fake_package, fake_separator_module = _fake_audio_separator_package(FakeSeparator)
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_separator_module)
    monkeypatch.setattr(helper.metadata, "version", lambda _name: "0.23.0")

    result_json = tmp_path / "result.json"
    args = SimpleNamespace(
        input=str(tmp_path / "input.wav"),
        output_dir=str(tmp_path / "out"),
        model_dir=str(tmp_path / "models"),
        model="MDX23C",
        result_json=str(result_json),
        log_file="",
        route="wrapper",
        device="cpu",
        requested_device="gpu",
        backend_runtime="rocm",
    )

    rc = helper.run(args)
    payload = json.loads(result_json.read_text(encoding="utf-8"))

    assert rc == 0
    assert payload["ok"] is True
    assert payload["requested_device"] == "gpu"
    assert payload["backend_runtime"] == "rocm"
    assert payload["effective_device"] == "cuda"
    assert payload["model_device"] == "cuda:0"
    assert payload["drumsep_mps_all_targets_route"] == ""
    assert payload["direct_demix_keys"] == []


def test_direct_demix_helper_result_keeps_mps_markers(tmp_path, monkeypatch):
    helper = _load_helper()
    monkeypatch.setattr(helper.metadata, "version", lambda _name: "0.23.0")
    captured = {}

    class FakeSeparator:
        def __init__(self, **kwargs):
            captured["kwargs"] = kwargs
            self.output_dir = Path(kwargs["output_dir"])
            self.torch_device = "mps"
            self.model_instance = _FakeModel(_complete_sources(), "mps:0")

        def load_model(self, _model_name):
            return None

    fake_package, fake_separator_module = _fake_audio_separator_package(FakeSeparator)
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_separator_module)

    def fake_direct_demix(_sep, _input_path, output_dir, _model_meta):
        stems = {}
        for stem_name, filename in helper.REAPER_FILENAMES.items():
            path = Path(output_dir) / filename
            path.write_bytes(stem_name.encode("ascii"))
            stems[stem_name] = str(path)
        return stems

    monkeypatch.setattr(helper, "_run_drumsep_all_targets_direct_demix", lambda sep, input_path, output_dir, model_meta, device: fake_direct_demix(sep, input_path, output_dir, model_meta))

    result_json = tmp_path / "result.json"
    args = SimpleNamespace(
        input=str(tmp_path / "input.wav"),
        output_dir=str(tmp_path / "out"),
        model_dir=str(tmp_path / "models"),
        model="MDX23C",
        result_json=str(result_json),
        log_file="",
        route="direct-demix",
        device="mps",
        requested_device="mps",
        backend_runtime="mps",
    )

    rc = helper.run(args)
    payload = json.loads(result_json.read_text(encoding="utf-8"))

    assert rc == 0
    assert payload["ok"] is True
    assert payload["requested_device"] == "mps"
    assert payload["backend_runtime"] == "mps"
    assert payload["effective_device"] == "mps"
    assert payload["model_device"] == "mps:0"
    assert captured["kwargs"]["mdx_params"]["device"] == "mps"
    assert captured["kwargs"]["mdxc_params"]["device"] == "mps"
    assert payload["direct_demix_enabled"] == 1
    assert payload["direct_demix_device"] == "mps"
    assert payload["drumsep_direct_demix_route"] == "direct_demix"
    assert payload["drumsep_mps_all_targets_route"] == "direct_demix"
    assert payload["direct_demix_keys"] == list(helper.DIRECT_DEMIX_KEYS)


def test_direct_demix_helper_result_keeps_cpu_markers(tmp_path, monkeypatch):
    helper = _load_helper()
    monkeypatch.setattr(helper.metadata, "version", lambda _name: "0.23.0")
    captured = {}

    class FakeSeparator:
        def __init__(self, **kwargs):
            captured["kwargs"] = kwargs
            self.output_dir = Path(kwargs["output_dir"])
            self.torch_device = "cpu"
            self.model_instance = _FakeModel(_complete_sources(), "cpu")

        def load_model(self, _model_name):
            return None

    fake_package, fake_separator_module = _fake_audio_separator_package(FakeSeparator)
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_separator_module)

    def fake_direct_demix_cpu(_sep, _input_path, output_dir, _model_meta, _device):
        stems = {}
        for stem_name, filename in helper.REAPER_FILENAMES.items():
            path = Path(output_dir) / filename
            path.write_bytes(stem_name.encode("ascii"))
            stems[stem_name] = str(path)
        return stems

    monkeypatch.setattr(helper, "_run_drumsep_all_targets_direct_demix", fake_direct_demix_cpu)

    result_json = tmp_path / "result.json"
    args = SimpleNamespace(
        input=str(tmp_path / "input.wav"),
        output_dir=str(tmp_path / "out"),
        model_dir=str(tmp_path / "models"),
        model="MDX23C",
        result_json=str(result_json),
        log_file="",
        route="direct-demix",
        device="cpu",
        requested_device="cpu",
        backend_runtime="cpu",
    )

    rc = helper.run(args)
    payload = json.loads(result_json.read_text(encoding="utf-8"))

    assert rc == 0
    assert payload["ok"] is True
    assert payload["requested_device"] == "cpu"
    assert payload["backend_runtime"] == "cpu"
    assert payload["effective_device"] == "cpu"
    assert payload["model_device"] == "cpu"
    assert captured["kwargs"]["mdx_params"]["device"] == "cpu"
    assert captured["kwargs"]["mdxc_params"]["device"] == "cpu"
    assert payload["direct_demix_enabled"] == 1
    assert payload["direct_demix_device"] == "cpu"
    assert payload["drumsep_direct_demix_route"] == "direct_demix"
    assert payload["drumsep_mps_all_targets_route"] == "direct_demix"
    assert payload["mps_fallback_enabled"] == ""
    assert payload["pytorch_mps_fallback_env"] == ""


def test_synthetic_direct_demix_writes_six_valid_outputs(tmp_path, monkeypatch):
    sf = pytest.importorskip("soundfile")
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
