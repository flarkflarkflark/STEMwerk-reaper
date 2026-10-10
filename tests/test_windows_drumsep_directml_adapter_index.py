"""Windows AMD multi-GPU: the DrumSep helper must run on the DirectML adapter
that was explicitly requested.

Reproduced on real hardware (RX 9070 = directml:0, Radeon 780M = directml:1):
Normal Stems honored explicit directml:1 (separator_torch_device=privateuseone:1),
but Direct Kit and Kit Split stage 2 reported requested_device=directml:1 with
effective_device=model_device=privateuseone:0 -- silently running on the RX 9070.

Root cause: the caller launches the helper with ``--device directml`` (backend
class) plus ``--requested-device directml:1``, but the helper used the latter
only for observability. audio-separator's ``configure_dml()`` binds bare
``torch_directml.device()``, which is always adapter 0. directml:0 "worked"
only because it coincides with that default.

The fakes below mirror those two real behaviours exactly (bare device() ->
adapter 0; load_model() reads torch_device at load time), so these tests fail
against the pre-fix helper.
"""

import importlib.util
import json
import sys
import types
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
DRUMSEP_HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"
AUDIO_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_helper():
    return _load(DRUMSEP_HELPER, "stemwerk_drumsep_process_directml_index_test")


class _Device:
    def __init__(self, text: str):
        self.text = text

    def __str__(self) -> str:
        return self.text


def _install_fake_torch_directml(monkeypatch, adapter_count: int = 2):
    names = ["AMD Radeon RX 9070\x00", "AMD Radeon 780M Graphics\x00"]
    module = types.ModuleType("torch_directml")
    module.calls = []

    def device(device_id=None):
        module.calls.append(device_id)
        index = 0 if device_id is None else int(device_id)
        if index >= adapter_count:
            raise Exception(
                f"Invalid device_id argument supplied {index}. device_id must be in range [0, {adapter_count})."
            )
        return _Device(f"privateuseone:{index}")

    module.device = device
    module.device_count = lambda: adapter_count
    module.is_available = lambda: True
    module.device_name = lambda index: names[index]
    monkeypatch.setitem(sys.modules, "torch_directml", module)
    return module


def _install_fake_torch_and_ort(monkeypatch):
    torch = types.ModuleType("torch")
    torch.__version__ = "2.4.1"
    torch.ones = lambda shape, device=None: SimpleNamespace(device=device)
    torch.nn = SimpleNamespace(functional=SimpleNamespace(conv2d=lambda tensor, weight: SimpleNamespace(device=tensor.device)))
    ort = types.ModuleType("onnxruntime")
    ort.get_available_providers = lambda: ["DmlExecutionProvider", "CPUExecutionProvider"]
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "onnxruntime", ort)


class _StopBeforeSeparation(RuntimeError):
    pass


def _install_fake_audio_separator(monkeypatch):
    """audio-separator 0.34.1-shaped Separator (see its configure_dml/load_model)."""

    class FakeSeparator:
        instances: list = []

        def __init__(self, use_directml=False, **kwargs):
            self.init_kwargs = dict(kwargs, use_directml=use_directml)
            self.amplification_threshold = 0.0
            self.model_instance = None
            if use_directml:
                import torch_directml

                self.torch_device_dml = torch_directml.device()
                self.torch_device = self.torch_device_dml
                self.onnx_execution_provider = ["DmlExecutionProvider"]
            else:
                self.torch_device = _Device("cpu")
                self.onnx_execution_provider = ["CPUExecutionProvider"]
            FakeSeparator.instances.append(self)

        def load_model(self, model_filename):
            parameter = SimpleNamespace(device=self.torch_device)
            self.model_instance = SimpleNamespace(model_run=SimpleNamespace(parameters=lambda: iter([parameter])))

    fake_module = types.ModuleType("audio_separator.separator")
    fake_module.Separator = FakeSeparator
    fake_package = types.ModuleType("audio_separator")
    fake_package.separator = fake_module
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_module)
    return FakeSeparator


def _prepare_helper_run(module, monkeypatch, *, real_adapter_probe=False):
    monkeypatch.setattr(
        module,
        "_resolve_managed_drumsep_checkpoint",
        lambda model_dir, requested_model: module.ManagedDrumSepResolution(
            "fake_model.ckpt", model_dir / "fake_model.ckpt", model_dir / "fake_model.yaml", "none"
        ),
    )

    def stop(*_args, **_kwargs):
        raise _StopBeforeSeparation("stop after device binding")

    monkeypatch.setattr(module, "_run_uvr_equivalent_mdxc_separation", stop)
    probes = {"generic": [], "adapter": []}

    def generic_probe(device):
        probes["generic"].append(device)
        return True, "ok", {}

    monkeypatch.setattr(module, "_probe_gpu_device", generic_probe)
    if not real_adapter_probe:

        def adapter_probe(index):
            probes["adapter"].append(index)
            return True, "ok", {}

        # raising=False keeps the device assertions meaningful against a helper
        # that predates _probe_directml_adapter.
        monkeypatch.setattr(module, "_probe_directml_adapter", adapter_probe, raising=False)
    return probes


def _helper_args(tmp_path: Path, *, device: str, requested_device: str):
    return SimpleNamespace(
        input=str(tmp_path / "in.wav"),
        output_dir=str(tmp_path / "out"),
        model_dir=str(tmp_path / "models"),
        model="fake_model.ckpt",
        result_json=str(tmp_path / "result.json"),
        log_file="",
        route="wrapper",
        device=device,
        requested_device=requested_device,
        backend_runtime=device,
    )


def _model_device(separator) -> str:
    return str(next(separator.model_instance.model_run.parameters()).device)


def _read_result(tmp_path: Path) -> dict:
    return json.loads((tmp_path / "result.json").read_text(encoding="utf-8"))


# --- adapter-index contract ---------------------------------------------------


@pytest.mark.parametrize(
    "device, requested, expected",
    [
        ("directml", "directml:0", 0),
        ("directml", "directml:1", 1),
        ("directml", " DirectML:1 ", 1),
        ("directml", "auto", None),
        ("directml", "gpu", None),
        ("directml", "directml", None),
        ("directml", "", None),
        ("directml", "directml:x", None),
        ("cpu", "cpu", None),
        ("cpu", "directml:1", None),
        ("cuda", "cuda:0", None),
        ("rocm", "auto", None),
        ("mps", "mps", None),
    ],
)
def test_requested_directml_adapter_index(device, requested, expected):
    module = _load_helper()
    assert module._requested_directml_adapter_index(device, requested) == expected


# --- explicit DirectML adapters reach their own index -------------------------


@pytest.mark.parametrize("index", [0, 1])
def test_explicit_directml_adapter_binds_requested_index(tmp_path, monkeypatch, index):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    probes = _prepare_helper_run(module, monkeypatch)

    rc = module.run(_helper_args(tmp_path, device="directml", requested_device=f"directml:{index}"))

    assert rc == 1, "stops at the separation fake, after device binding"
    assert probes["adapter"] == [index], "the requested adapter itself must be probed"
    assert probes["generic"] == [], "the generic probe only exercises the default adapter"
    (sep,) = fake_separator.instances
    assert sep.init_kwargs["use_directml"] is True
    assert str(sep.torch_device) == f"privateuseone:{index}"
    assert str(sep.torch_device_dml) == f"privateuseone:{index}"
    assert _model_device(sep) == f"privateuseone:{index}"
    assert index in dml.calls
    result = _read_result(tmp_path)
    assert result["requested_device"] == f"directml:{index}"
    assert result["effective_device"] == f"privateuseone:{index}"
    assert result["model_device"] == f"privateuseone:{index}"


# --- Auto keeps its existing default-adapter semantics -------------------------


def test_auto_directml_keeps_default_adapter_unchanged(tmp_path, monkeypatch):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    probes = _prepare_helper_run(module, monkeypatch)

    module.run(_helper_args(tmp_path, device="directml", requested_device="auto"))

    assert probes["generic"] == ["directml"]
    assert probes["adapter"] == []
    assert dml.calls == [None], "Auto must not rebind to an explicit adapter"
    (sep,) = fake_separator.instances
    assert str(sep.torch_device) == "privateuseone:0"
    assert _read_result(tmp_path)["requested_device"] == "auto"


# --- explicit CPU stays CPU even inside the DirectML runtime -------------------


def test_explicit_cpu_never_touches_directml(tmp_path, monkeypatch):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    probes = _prepare_helper_run(module, monkeypatch)

    module.run(_helper_args(tmp_path, device="cpu", requested_device="cpu"))

    assert probes["adapter"] == []
    assert dml.calls == []
    (sep,) = fake_separator.instances
    assert sep.init_kwargs["use_directml"] is False
    assert sep.init_kwargs["mdxc_params"] == {"device": "cpu"}
    assert str(sep.torch_device) == "cpu"
    assert _model_device(sep) == "cpu"


# --- Linux ROCm / NVIDIA CUDA / macOS MPS are unaffected -----------------------


@pytest.mark.parametrize("device, requested", [("cuda", "cuda:0"), ("rocm", "auto"), ("rocm", "rocm"), ("mps", "mps")])
def test_non_directml_backends_are_unaffected(tmp_path, monkeypatch, device, requested):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    probes = _prepare_helper_run(module, monkeypatch)

    def forbidden_bind(*_args, **_kwargs):
        raise AssertionError("DirectML adapter binding must not run for non-DirectML backends")

    monkeypatch.setattr(module, "_bind_separator_directml_adapter", forbidden_bind, raising=False)

    module.run(_helper_args(tmp_path, device=device, requested_device=requested))

    assert probes["generic"] == [device]
    assert probes["adapter"] == []
    assert dml.calls == []
    (sep,) = fake_separator.instances
    assert sep.init_kwargs["use_directml"] is False
    assert sep.init_kwargs["mdxc_params"] == {"device": device}


# --- an adapter that cannot be honored fails explicitly ------------------------


def test_unavailable_adapter_fails_explicitly_without_fallback(tmp_path, monkeypatch):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch, adapter_count=2)
    _install_fake_torch_and_ort(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    _prepare_helper_run(module, monkeypatch, real_adapter_probe=True)

    rc = module.run(_helper_args(tmp_path, device="directml", requested_device="directml:3"))

    assert rc == 1
    assert fake_separator.instances == [], "must not construct a separator on some other adapter"
    assert None not in dml.calls, "must never fall back to the default adapter"
    result = _read_result(tmp_path)
    assert result["ok"] is False
    assert result["error_reason"] == "drumsep_directml_adapter_unavailable"
    assert result["error_stage"] == "stage2_runtime"
    assert "directml_adapter_index_out_of_range:requested=3,available=2" in result["message"]


def test_adapter_that_does_not_stick_after_load_fails_explicitly(tmp_path, monkeypatch):
    module = _load_helper()
    _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    _prepare_helper_run(module, monkeypatch)

    def load_onto_default_adapter(self, model_filename):
        parameter = SimpleNamespace(device=_Device("privateuseone:0"))
        self.model_instance = SimpleNamespace(model_run=SimpleNamespace(parameters=lambda: iter([parameter])))

    monkeypatch.setattr(fake_separator, "load_model", load_onto_default_adapter)

    rc = module.run(_helper_args(tmp_path, device="directml", requested_device="directml:1"))

    assert rc == 1
    result = _read_result(tmp_path)
    assert result["error_reason"] == "drumsep_directml_adapter_mismatch"
    assert result["requested_device"] == "directml:1"
    assert result["model_device"] == "privateuseone:0"


def test_adapter_probe_runs_on_requested_adapter(monkeypatch):
    module = _load_helper()
    dml = _install_fake_torch_directml(monkeypatch)
    _install_fake_torch_and_ort(monkeypatch)

    ok, reason, detail = module._probe_directml_adapter(1)

    assert (ok, reason) == (True, "ok")
    assert detail["conv_device"] == "privateuseone:1"
    assert detail["device_name"] == "AMD Radeon 780M Graphics"
    assert dml.calls == [1]


# --- caller -> helper argv contract (Direct Kit and Kit Split stage 2) --------


def _capture_helper_argv(tmp_path, monkeypatch, output_root: Path, requested_device: str):
    audio = _load(AUDIO_PROCESS, "audio_separator_process_directml_index_test")
    captured = {}

    class FakePopen:
        def __init__(self, cmd, **_kwargs):
            captured["cmd"] = [str(part) for part in cmd]
            result_json = Path(cmd[cmd.index("--result-json") + 1])
            result_json.write_text(json.dumps({"ok": False, "error_reason": "captured"}), encoding="utf-8")
            self.returncode = 1

        def poll(self):
            return 1

        def kill(self):
            pass

        def wait(self, timeout=None):
            return 1

    monkeypatch.setattr(audio.subprocess, "Popen", FakePopen)
    output_root.mkdir(parents=True, exist_ok=True)
    audio._run_direct_dks_drumsep_helper(
        tmp_path / "input.wav",
        output_root,
        tmp_path / "models",
        Path(sys.executable),
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "fake_model.ckpt",
        route="wrapper",
        device="directml",
        requested_device=requested_device,
        backend_runtime="directml",
    )
    return captured["cmd"]


@pytest.mark.parametrize(
    "workflow_dir, index",
    [
        ("item_1", 0),
        ("item_1", 1),
        (str(Path("item_1") / "stage2_drumsep"), 1),
    ],
    ids=["direct_kit_directml0", "direct_kit_directml1", "kit_split_stage2_directml1"],
)
def test_caller_argv_reaches_helper_adapter_index(tmp_path, monkeypatch, workflow_dir, index):
    cmd = _capture_helper_argv(tmp_path, monkeypatch, tmp_path / workflow_dir, f"directml:{index}")

    assert cmd[cmd.index("--device") + 1] == "directml"
    assert cmd[cmd.index("--requested-device") + 1] == f"directml:{index}", (
        "the adapter index must survive in the helper invocation, not collapse to bare 'directml'"
    )

    helper = _load_helper()
    _install_fake_torch_directml(monkeypatch)
    fake_separator = _install_fake_audio_separator(monkeypatch)
    _prepare_helper_run(helper, monkeypatch)
    monkeypatch.setattr(sys, "argv", [cmd[1], *cmd[2:]])

    helper.main()

    (sep,) = fake_separator.instances
    assert str(sep.torch_device) == f"privateuseone:{index}"
    assert _model_device(sep) == f"privateuseone:{index}"


def test_direct_kit_and_kit_split_pass_the_unmodified_device_request():
    text = AUDIO_PROCESS.read_text(encoding="utf-8")
    call = "_run_direct_dks_drumsep_helper("
    starts = [i for i in range(len(text)) if text.startswith(call, i) and not text[:i].endswith("def ")]
    assert len(starts) == 2, "expected exactly the Direct Kit and Kit Split stage 2 call sites"
    for start in starts:
        block = text[start : start + 900]
        assert "requested_device=device_preference," in block
