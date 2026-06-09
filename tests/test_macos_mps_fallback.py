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


def test_select_device_explicit_mps_requires_apple_silicon(monkeypatch):
    import stemwerk_core.devices as devices

    monkeypatch.setitem(sys.modules, "torch", _fake_torch(mps_available=True))
    monkeypatch.setattr(devices.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(devices.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
        ],
    )

    assert devices.select_device("mps") == ("cpu", "CPU")


def test_select_device_auto_skips_mps_even_if_listed(monkeypatch):
    import stemwerk_core.devices as devices

    monkeypatch.setitem(sys.modules, "torch", _fake_torch(mps_available=True))
    monkeypatch.setattr(devices.platform, "system", lambda: "Linux")
    monkeypatch.setattr(devices.platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(
        devices,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "mps", "name": "Apple MPS", "type": "mps"},
        ],
    )

    assert devices.select_device("auto") == ("cpu", "CPU")


def test_normal_auto_prefers_mps_on_macos_apple_silicon(monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "_is_darwin_arm64", lambda: True)
    monkeypatch.setattr(
        module,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "mps", "name": "Apple MPS", "type": "mps"},
        ],
    )
    monkeypatch.setattr(module, "select_device", lambda requested: ("mps", "Apple MPS"))

    requested, resolved, preview, _live_ids = module._resolve_normal_runtime_device("auto")
    preview_device, _sep, _name = preview.partition("|")

    assert requested == "auto"
    assert resolved == "mps"
    assert preview_device == "mps"
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG requested_device=auto" in stderr
    assert "STEMWERK_DIAG auto_selected_preferred=mps (Apple MPS)" in stderr
    assert module._is_unexpected_cpu_downgrade(requested, preview_device) is False


def test_auto_cpu_is_not_an_unexpected_runtime_downgrade(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "_is_darwin_arm64", lambda: False)
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(
        module,
        "get_available_devices",
        lambda: [
            {"id": "auto", "name": "Auto", "type": "auto"},
            {"id": "cpu", "name": "CPU", "type": "cpu"},
            {"id": "mps", "name": "Apple MPS", "type": "mps"},
        ],
    )
    monkeypatch.setattr(module, "select_device", lambda requested: ("cpu", "CPU"))

    requested, resolved, preview, _live_ids = module._resolve_normal_runtime_device("auto")
    preview_device, _sep, _name = preview.partition("|")

    assert requested == "auto"
    assert resolved == "cpu"
    assert preview_device == "cpu"
    assert module._is_unexpected_cpu_downgrade(requested, preview_device) is False
    assert module._is_unexpected_cpu_downgrade("cpu", "cpu") is False
    assert module._is_unexpected_cpu_downgrade("mps", "cpu") is True
    assert module._is_unexpected_cpu_downgrade("cuda:0", "cpu") is True
    assert module._is_unexpected_cpu_downgrade("directml", "cpu") is True


def test_separator_uses_safe_mps_segment_and_default_elsewhere(monkeypatch):
    import stemwerk_core.separator as separator_module

    captured = []

    class FakeSeparator:
        def __init__(self, demucs_params=None, **_kwargs):
            captured.append(demucs_params)

    fake_package = SimpleNamespace(separator=SimpleNamespace(Separator=FakeSeparator))
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_package.separator)
    separator_module._SEPARATOR_CACHE.clear()

    mps = separator_module.StemSeparator(model="htdemucs", device="mps")
    mps._get_separator("htdemucs", "mps", False)
    cpu = separator_module.StemSeparator(model="htdemucs", device="cpu")
    cpu._get_separator("htdemucs", "cpu", False)

    assert captured[0]["segment_size"] == 2
    assert captured[1]["segment_size"] == "Default"


def test_explicit_mps_policy_keeps_mps_and_logs_segment(monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "_is_darwin_arm64", lambda: True)

    effective = module._apply_mps_experimental_policy("mps", "mps", "htdemucs_ft")

    assert effective == "mps"
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG mps_experimental=yes" in stderr
    assert "STEMWERK_DIAG mps_segment_size=2" in stderr
    assert "STEMWERK_DIAG mps_segment_policy=universal_safe_segment_2" in stderr


def test_explicit_mps_disables_pytorch_runtime_fallback(monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.MPS_FALLBACK_ENV, "1")

    changed = module._configure_mps_runtime_fallback("mps", "mps")

    assert changed is True
    assert module.MPS_FALLBACK_ENV not in os.environ
    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG mps_fallback_enabled=0" in stderr
    assert "STEMWERK_DIAG pytorch_mps_fallback_env=unset" in stderr


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
    assert "MPS processing failed on this Mac. Please switch Device to CPU and try again." in script
    assert 'T("mps_failure_message")' in script
    assert 'tostring(logSnippet or "(no log output found)")' not in script[
        script.index("if not isKnownMpsUnsupportedFailure") :
        script.index("local function isEffectiveRun6Stem")
    ]


def test_lua_and_i18n_expose_only_explicit_experimental_mps():
    devices = (ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Devices.lua").read_text(
        encoding="utf-8"
    )
    settings = (ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Settings.lua").read_text(
        encoding="utf-8"
    )
    languages = (ROOT / "scripts" / "reaper" / "i18n" / "languages.lua").read_text(
        encoding="utf-8"
    )
    support = (ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua").read_text(
        encoding="utf-8"
    )
    main = (ROOT / "scripts" / "reaper" / "STEMwerk.lua").read_text(encoding="utf-8")

    assert "filterExplicitMpsDevices" in devices
    assert 'SETTINGS.device == "mps" and not hasMpsDevice(RUNTIME_DEVICES)' in devices
    assert 'if req == "mps" then' in devices
    assert 'return "cpu"' in devices
    assert "ARCH = SYSTEM.getArch()" in main
    assert "ARCH = ARCH," in main
    assert 'C.ARCH == "arm64" or C.ARCH == "aarch64"' in settings
    assert 'device_mps_label = "Apple MPS (Experimental)"' in languages
    assert 'device_mps_label = "Apple MPS (Experimenteel)"' in languages
    assert 'device_mps_label = "Apple MPS (Experimentell)"' in languages
    assert "MPS/CPU" not in "\n".join(
        line for line in languages.splitlines() if "device_auto_desc" in line
    )
    assert 'local cachedDevicesApplied = applyCachedRuntimeDevices(cacheOpts)' in main
    assert 'if not cachedDevicesApplied and not RUNTIME_DEVICES then' in main
    assert 'local mpsAvailable = false' in main
    assert 'if mpsAvailable and cpuReady then' in main
    assert 'add("mps", "Apple MPS", "mps", "device_mps_desc")' in main
    assert 'if sawMps then return "CPU" end' in main
    assert 'schedulerBackend = "cpu"' in main
    for field in (
        "requested_device",
        "selected_device",
        "effective_device",
        "mps_experimental",
        "mps_segment_size",
        "mps_segment_policy",
        "mps_fallback_used",
        "mps_fallback_reason",
    ):
        assert field in support
