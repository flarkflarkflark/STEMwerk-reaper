import importlib.util
import os
import sys
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))


def _load_audio_separator_process_module():
    path = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
    spec = importlib.util.spec_from_file_location("audio_separator_process_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _fake_torch(mps_available=True):
    return SimpleNamespace(
        backends=SimpleNamespace(
            mps=SimpleNamespace(
                is_available=lambda: mps_available,
                is_built=lambda: True,
            )
        )
    )


def test_select_device_auto_prefers_cpu_on_macos_apple_silicon(monkeypatch):
    import stemwerk_core.devices as devices

    monkeypatch.setitem(sys.modules, "torch", _fake_torch(mps_available=True))
    monkeypatch.setattr(devices.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(devices.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "mps", "name": "Apple MPS", "type": "mps"},
        ],
    )

    device_id, device_name = devices.select_device("auto")

    assert (device_id, device_name) == ("cpu", "CPU")


def test_select_device_explicit_mps_still_uses_mps(monkeypatch):
    import stemwerk_core.devices as devices

    monkeypatch.setitem(sys.modules, "torch", _fake_torch(mps_available=True))
    monkeypatch.setattr(devices.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(devices.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "mps", "name": "Apple MPS", "type": "mps"},
        ],
    )

    device_id, device_name = devices.select_device("mps")

    assert (device_id, device_name) == ("mps", "Apple MPS")


def test_enable_mps_runtime_fallback_sets_env(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv(module.MPS_FALLBACK_ENV, raising=False)

    changed = module._enable_mps_runtime_fallback("mps", "mps")

    assert changed is True
    assert os.environ[module.MPS_FALLBACK_ENV] == "1"


def test_classify_runtime_failure_marks_known_mps_limitation():
    module = _load_audio_separator_process_module()
    exc = NotImplementedError(
        "Output channels > 65536 not supported at the MPS device. "
        "As a temporary fix, you can set the environment variable "
        "PYTORCH_ENABLE_MPS_FALLBACK=1 to use the CPU as a fallback for this op."
    )
    env = {
        "torch_version": "2.5.1",
        "platform": "Darwin",
        "platform_machine": "arm64",
        "mps_built": True,
        "mps_available": True,
        "mps_fallback_env": "1",
    }

    classified = module._classify_runtime_failure(
        exc,
        "traceback...",
        requested_device="mps",
        selected_device="mps",
        model_name="htdemucs_ft",
        env=env,
    )

    assert classified is not None
    assert classified["marker"] == module.MPS_UNSUPPORTED_MARKER
    assert classified["details"]["requested_device"] == "mps"
    assert classified["details"]["selected_device"] == "mps"
    assert classified["details"]["model"] == "htdemucs_ft"


def test_failure_message_uses_mps_marker():
    script = (ROOT / "scripts" / "reaper" / "STEMwerk.lua").read_text(encoding="utf-8")

    assert "STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536" in script
    assert "Apple MPS failed because this model hits a PyTorch MPS limitation." in script
