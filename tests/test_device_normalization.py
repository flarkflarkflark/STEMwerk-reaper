import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
import warnings

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))


def _load_audio_separator_process_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_test", PROCESS_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class Probe:
    def __init__(
        self,
        cuda_available=False,
        cuda_count=0,
        cuda_names=None,
        hip=None,
        mps_available=False,
        platform_system="Linux",
        platform_machine="x86_64",
    ):
        self.cuda_available = cuda_available
        self.cuda_count = cuda_count
        self.cuda_names = list(cuda_names or [])
        self.hip = hip
        self.mps_available = mps_available
        self.platform_system = platform_system
        self.platform_machine = platform_machine
        self.calls = []

    def torch_cuda_is_available(self):
        self.calls.append("torch_cuda_is_available")
        return self.cuda_available

    def torch_cuda_device_count(self):
        self.calls.append("torch_cuda_device_count")
        return self.cuda_count

    def torch_cuda_get_device_name(self, index):
        self.calls.append(("torch_cuda_get_device_name", index))
        return self.cuda_names[index] if index < len(self.cuda_names) else f"GPU {index}"

    def torch_hip_version(self):
        self.calls.append("torch_hip_version")
        return self.hip

    def torch_mps_is_available(self):
        self.calls.append("torch_mps_is_available")
        return self.mps_available

    def system(self):
        self.calls.append("system")
        return self.platform_system

    def machine(self):
        self.calls.append("machine")
        return self.platform_machine


def test_cuda_request_normalizes_to_cuda_zero_when_available():
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device("cuda", Probe(cuda_available=True, cuda_count=1, cuda_names=["RX 9070"]))

    assert result.requested_device == "cuda"
    assert result.normalized_device == "cuda:0"
    assert result.effective_backend == "cuda"
    assert result.device_normalized is True
    assert result.error_reason == ""


def test_cuda_request_fails_when_unavailable_without_cpu_fallback():
    from stemwerk_core.devices import DeviceNormalizationError, normalize_torch_device

    with pytest.raises(DeviceNormalizationError) as excinfo:
        normalize_torch_device("cuda", Probe(cuda_available=False, cuda_count=0), strict=True)

    assert excinfo.value.result.error_reason == "torch_cuda_unavailable"
    assert excinfo.value.result.normalized_device == "cuda"


def test_cuda_request_on_hip_runtime_uses_cuda_device_string_and_rocm_backend():
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device("cuda", Probe(cuda_available=True, cuda_count=1, hip="7.0.51831"))

    assert result.normalized_device == "cuda:0"
    assert result.effective_backend == "rocm"
    assert result.device_normalized is True


def test_cuda_zero_request_is_unchanged_when_available():
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device("cuda:0", Probe(cuda_available=True, cuda_count=1))

    assert result.normalized_device == "cuda:0"
    assert result.effective_backend == "cuda"
    assert result.device_normalized is False


def test_cuda_index_out_of_range_is_hard_error():
    from stemwerk_core.devices import DeviceNormalizationError, normalize_torch_device

    with pytest.raises(DeviceNormalizationError) as excinfo:
        normalize_torch_device("cuda:9", Probe(cuda_available=True, cuda_count=1), strict=True)

    assert excinfo.value.result.error_reason.startswith("cuda_index_out_of_range")
    assert "count=1" in excinfo.value.result.error_reason


def test_cpu_request_does_not_probe_torch():
    from stemwerk_core.devices import normalize_torch_device

    probe = Probe(cuda_available=True, cuda_count=1, hip="7.0.51831")

    result = normalize_torch_device("cpu", probe)

    assert result.normalized_device == "cpu"
    assert result.effective_backend == "cpu"
    assert result.device_normalized is False
    assert probe.calls == []


@pytest.mark.parametrize("device_request", ["directml", "directml:1"])
def test_directml_requests_are_pass_through(device_request):
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device(device_request, Probe())

    assert result.normalized_device == device_request
    assert result.effective_backend == "directml"
    assert result.device_normalized is False


def test_mps_request_passes_through_on_apple_silicon_with_mps():
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device(
        "mps",
        Probe(mps_available=True, platform_system="Darwin", platform_machine="arm64"),
    )

    assert result.normalized_device == "mps"
    assert result.effective_backend == "mps"
    assert result.device_normalized is False


@pytest.mark.parametrize(
    "probe",
    [
        Probe(mps_available=False, platform_system="Darwin", platform_machine="arm64"),
        Probe(mps_available=True, platform_system="Linux", platform_machine="x86_64"),
    ],
)
def test_mps_request_without_availability_is_hard_error(probe):
    from stemwerk_core.devices import DeviceNormalizationError, normalize_torch_device

    with pytest.raises(DeviceNormalizationError) as excinfo:
        normalize_torch_device("mps", probe, strict=True)

    assert excinfo.value.result.error_reason == "mps_unavailable"


def test_unknown_device_request_is_hard_error():
    from stemwerk_core.devices import DeviceNormalizationError, normalize_torch_device

    with pytest.raises(DeviceNormalizationError) as excinfo:
        normalize_torch_device("gpu0", Probe(), strict=True)

    assert excinfo.value.result.error_reason == "unknown_device_request"


def test_non_strict_cuda_unavailable_reports_error_without_raising():
    from stemwerk_core.devices import normalize_torch_device

    result = normalize_torch_device("cuda", Probe(cuda_available=False, cuda_count=0))

    assert result.normalized_device == "cuda"
    assert result.error_reason == "torch_cuda_unavailable"


def test_explicit_cuda_cpu_preview_still_counts_as_unexpected_cpu_downgrade():
    module = _load_audio_separator_process_module()

    assert module._is_unexpected_cpu_downgrade("cuda", "cpu") is True


def test_select_device_normalizes_bare_cuda_for_direct_consumers(monkeypatch):
    import stemwerk_core.devices as devices

    fake_torch = SimpleNamespace(
        version=SimpleNamespace(hip=None),
        cuda=SimpleNamespace(
            is_available=lambda: True,
            device_count=lambda: 1,
            get_device_name=lambda _index: "CUDA GPU",
        ),
    )
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "cuda:0", "name": "CUDA GPU", "type": "cuda"},
        ],
    )

    assert devices.select_device("cuda") == ("cuda:0", "CUDA GPU")


def test_select_device_keeps_warning_cpu_fallback_for_unavailable_cuda(monkeypatch):
    import stemwerk_core.devices as devices

    fake_torch = SimpleNamespace(
        version=SimpleNamespace(hip=None),
        cuda=SimpleNamespace(
            is_available=lambda: False,
            device_count=lambda: 0,
            get_device_name=lambda _index: "",
        ),
    )
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
        ],
    )

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        result = devices.select_device("cuda")

    assert result == ("cpu", "CPU")
    assert any("Requested device 'cuda' not available; using CPU." in str(item.message) for item in caught)
