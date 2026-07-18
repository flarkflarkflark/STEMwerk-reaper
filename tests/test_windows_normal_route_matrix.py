import importlib.util
import sys
import types
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import separator as separator_module


WINDOWS_BACKENDS = [
    ("cpu", "cpu", "CPU"),
    ("directml", "directml", "DirectML"),
    ("cuda:0", "cuda:0", "CUDA"),
]
NORMAL_MODELS = ["htdemucs", "htdemucs_ft", "htdemucs_6s"]


def _load_audio_separator_process():
    spec = importlib.util.spec_from_file_location("audio_separator_process", PROCESS_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _fake_drumsep_stems(stage2_root: Path):
    stems = {}
    for stem_name in ("kick", "snare", "hihat", "tom", "cymbals", "room"):
        stem_path = stage2_root / f"{stem_name}.wav"
        stem_path.parent.mkdir(parents=True, exist_ok=True)
        stem_path.write_bytes(b"")
        stems[stem_name] = str(stem_path)
    return stems


@pytest.mark.parametrize("model_name", NORMAL_MODELS)
@pytest.mark.parametrize("requested_device,resolved_device,device_label", WINDOWS_BACKENDS)
def test_windows_backends_load_supported_demucs_yaml_contract_for_normal_routes(
    monkeypatch, tmp_path, requested_device, resolved_device, device_label, model_name
):
    load_calls = []

    class FakeLogger:
        def info(self, _msg):
            return None

    class FakeSeparator:
        def __init__(
            self,
            output_dir=".",
            output_format="WAV",
            normalization_threshold=0.9,
            log_level=10,
            mdx_params=None,
            model_file_dir="",
            use_soundfile=False,
            use_directml=False,
            demucs_params=None,
        ):
            self.output_dir = output_dir
            self.output_format = output_format
            self.normalization_threshold = normalization_threshold
            self.log_level = log_level
            self.mdx_params = mdx_params or {}
            self.model_file_dir = model_file_dir
            self.use_soundfile = use_soundfile
            self.use_directml = use_directml
            self.demucs_params = demucs_params or {}
            self.logger = FakeLogger()
            self.torch_device = "cpu"
            self.torch_device_cpu = "cpu"
            self.torch_device_mps = "mps"
            self.onnx_execution_provider = []
            self.output_bitrate = None
            self.output_single_stem = None
            self.invert_using_spec = False
            self.sample_rate = 44100
            self.model_instance = None
            self.model_friendly_name = ""
            self.arch_specific_params = {"Demucs": {}}

        @staticmethod
        def list_supported_model_files():
            yaml_name = f"{model_name}.yaml"
            return {"Demucs": {"Demucs v4": {yaml_name: f"https://example.invalid/{yaml_name}"}}}

        def load_model(self, requested_model):
            load_calls.append(requested_model)

        def separate(self, _input_path):
            outputs = []
            for stem_name in ("vocals", "drums", "bass", "other"):
                stem_path = Path(self.output_dir) / f"{stem_name}.wav"
                stem_path.write_bytes(b"")
                outputs.append(str(stem_path))
            return outputs

    audio_separator_pkg = types.ModuleType("audio_separator")
    audio_separator_separator_pkg = types.ModuleType("audio_separator.separator")
    audio_separator_separator_pkg.Separator = FakeSeparator
    audio_separator_pkg.separator = audio_separator_separator_pkg

    monkeypatch.setitem(sys.modules, "audio_separator", audio_separator_pkg)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", audio_separator_separator_pkg)
    monkeypatch.setitem(
        sys.modules,
        "torch",
        SimpleNamespace(
            device=lambda name: name,
            cuda=SimpleNamespace(set_device=lambda _idx: None),
        ),
    )
    monkeypatch.setitem(sys.modules, "soundfile", SimpleNamespace(info=lambda _path: SimpleNamespace(duration=1.0)))
    monkeypatch.setattr(separator_module, "select_device", lambda _requested: (resolved_device, device_label))
    monkeypatch.setattr(
        separator_module,
        "_resolve_directml_device",
        lambda _requested: ("privateuseone:0", True, 0),
    )
    monkeypatch.setitem(
        sys.modules,
        "torch_directml",
        SimpleNamespace(device=lambda index: f"directml:{index}"),
    )
    monkeypatch.setattr(separator_module, "_default_model_cache_dir", lambda: str(tmp_path / "models"))

    separator_module._SEPARATOR_CACHE.clear()

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")

    separator = separator_module.StemSeparator(model=model_name, device=requested_device)
    result = separator.separate(input_path, output_dir)

    assert result.stems["vocals"] == output_dir / "vocals.wav"
    assert load_calls == [f"{model_name}.yaml"]
    assert all(call not in NORMAL_MODELS for call in load_calls)


@pytest.mark.parametrize("model_name", NORMAL_MODELS)
@pytest.mark.parametrize("requested_device,resolved_device,_device_label", WINDOWS_BACKENDS)
def test_windows_dks_extract_stage1_reuses_normal_route_mapping_across_backends(
    monkeypatch, tmp_path, requested_device, resolved_device, _device_label, model_name
):
    module = _load_audio_separator_process()
    monkeypatch.setattr(module.sys, "platform", "win32")
    stem_separator_inits = []
    helper_calls = []

    class FakeStemSeparator:
        def __init__(self, model, device):
            stem_separator_inits.append((model, device))
            self.model = model
            self.device = device
            self.on_progress = None

        def separate(self, _input_path, output_dir, stems=None):
            drums_path = Path(output_dir) / "drums.wav"
            drums_path.write_bytes(b"")
            return SimpleNamespace(stems={"drums": drums_path}, device_used=self.device, elapsed=0.01)

    monkeypatch.setattr(module, "_setup_reaper_io", lambda _output_dir: (lambda _status: None))
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    monkeypatch.setattr(module, "emit_phase", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_configure_ffmpeg_runtime", lambda: (None, None, None))
    monkeypatch.setattr(module, "_configure_model_cache_runtime", lambda: str(tmp_path / "models"))
    monkeypatch.setattr(
        module,
        "_resolve_normal_runtime_device",
        lambda requested: (requested, resolved_device, f"{resolved_device}|Preview", [resolved_device]),
    )
    monkeypatch.setattr(module, "_select_drumsep_runtime", lambda _requested: ("python", requested_device, {}))
    monkeypatch.setattr(module, "_should_use_drumsep_mps_direct_demix", lambda *_args, **_kwargs: (False, ""))
    monkeypatch.setattr(
        module,
        "_direct_dks_preflight_check",
        lambda requested_model, _model_cache_dir, **_kwargs: (True, requested_model, requested_model, ""),
    )
    monkeypatch.setattr(module, "_emit_runtime_diagnostics", lambda _device: {})
    monkeypatch.setattr(module, "_configure_mps_runtime_fallback", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_apply_mps_experimental_policy", lambda _req, device, _model: device)
    monkeypatch.setattr(module, "_enable_torch_weights_only_compat", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_map_reaper_stems_from_result", lambda result, _output_root: result.stems)
    monkeypatch.setattr(module, "_detect_dks_extract_stage2_backend", lambda runtime_kind, *_args: runtime_kind)
    monkeypatch.setattr(module, "_resolve_benchmark_drumsep_helper_device", lambda *_args, **_kwargs: (requested_device, ""))
    monkeypatch.setattr(module, "_dks_extract_stage2_lock", lambda *_args, **_kwargs: nullcontext())
    monkeypatch.setattr(
        module,
        "_run_direct_dks_drumsep_helper",
        lambda *args, **kwargs: (
            helper_calls.append(kwargs),
            True,
            _fake_drumsep_stems(Path(args[1])),
            "",
            "",
        )[1:],
    )
    monkeypatch.setattr(module, "_working_directory", lambda _path: nullcontext())
    monkeypatch.setattr(module, "_finish_benchmark_run", lambda _sampler, code: code)
    monkeypatch.setattr(module, "StemSeparator", FakeStemSeparator)
    monkeypatch.setattr(module, "stemwerk_core_file", str(CORE_SRC / "stemwerk_core" / "__init__.py"))

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")

    argv = [
        "audio_separator_process.py",
        str(input_path),
        str(output_dir),
        "--model",
        model_name,
        "--device",
        requested_device,
        "--workflow-mode",
        "drumkit",
        "--workflow-source",
        "dks_extract",
    ]
    monkeypatch.setattr(sys, "argv", argv)

    exit_code = module.main()

    assert exit_code == 0
    assert stem_separator_inits == [(model_name, resolved_device)]
    assert helper_calls[0]["backend_runtime"] == requested_device


@pytest.mark.parametrize("requested_device,_resolved_device,_device_label", WINDOWS_BACKENDS)
def test_windows_direct_dks_route_stays_on_drumsep_helper_per_backend(
    monkeypatch, tmp_path, requested_device, _resolved_device, _device_label
):
    module = _load_audio_separator_process()
    monkeypatch.setattr(module.sys, "platform", "win32")
    helper_calls = []

    def fail_if_normal_route_used(*_args, **_kwargs):
        raise AssertionError("Direct DKS should not construct the normal StemSeparator route")

    monkeypatch.setattr(module, "_setup_reaper_io", lambda _output_dir: (lambda _status: None))
    monkeypatch.setattr(module, "_require_core", lambda: None)
    module._core_loaded = True
    monkeypatch.setattr(module, "emit_phase", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_configure_ffmpeg_runtime", lambda: (None, None, None))
    monkeypatch.setattr(module, "_configure_model_cache_runtime", lambda: str(tmp_path / "models"))
    monkeypatch.setattr(module, "_select_drumsep_runtime", lambda _requested: ("python", requested_device, {}))
    monkeypatch.setattr(module, "_should_use_drumsep_mps_direct_demix", lambda *_args, **_kwargs: (False, ""))
    monkeypatch.setattr(
        module,
        "_direct_dks_preflight_check",
        lambda requested_model, _model_cache_dir, **_kwargs: (True, requested_model, requested_model, ""),
    )
    monkeypatch.setattr(module, "_detect_dks_extract_stage2_backend", lambda runtime_kind, *_args: runtime_kind)
    monkeypatch.setattr(module, "_resolve_benchmark_drumsep_helper_device", lambda *_args, **_kwargs: (requested_device, ""))
    monkeypatch.setattr(
        module,
        "_run_direct_dks_drumsep_helper",
        lambda *args, **kwargs: (
            helper_calls.append((args, kwargs)),
            True,
            _fake_drumsep_stems(Path(args[1])),
            "",
            "",
        )[1:],
    )
    monkeypatch.setattr(module, "_finish_benchmark_run", lambda _sampler, code: code)
    monkeypatch.setattr(module, "StemSeparator", fail_if_normal_route_used)
    monkeypatch.setattr(module, "stemwerk_core_file", str(CORE_SRC / "stemwerk_core" / "__init__.py"))

    input_path = tmp_path / "input.wav"
    output_dir = tmp_path / "out"
    input_path.write_bytes(b"RIFF")

    argv = [
        "audio_separator_process.py",
        str(input_path),
        str(output_dir),
        "--model",
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "--device",
        requested_device,
        "--workflow-mode",
        "drumkit",
        "--workflow-source",
        "dks_direct",
    ]
    monkeypatch.setattr(sys, "argv", argv)

    exit_code = module.main()

    assert exit_code == 0
    helper_args, helper_kwargs = helper_calls[0]
    assert helper_kwargs["backend_runtime"] == requested_device
    assert helper_args[5] == "MDX23C-DrumSep-aufr33-jarredou.ckpt"
