"""Regression smoke for the v2.2.2.1 macOS/Linux torch pin hotfix."""

import json
import platform
import sys
from importlib.metadata import PackageNotFoundError, distribution, version

import pytest


EXPECTED_TORCH = "2.5.1"
EXPECTED_TORCHAUDIO = "2.5.1"
EXPECTED_AUDIO_SEPARATOR = "0.23.0"


def _version_or_fail(dist_name):
    try:
        return version(dist_name)
    except PackageNotFoundError:
        pytest.fail(f"{dist_name} is not installed")


def test_dependency_diagnostics():
    import audio_separator
    import onnxruntime
    import stemwerk_core
    import torch
    import torchaudio

    print()
    print(f"python_executable={sys.executable}")
    print(f"python_version={platform.python_version()}")
    print(f"platform_system={platform.system()}")
    print(f"platform_machine={platform.machine()}")
    print(f"torch_version={torch.__version__}")
    print(f"torchaudio_version={torchaudio.__version__}")
    print(f"audio_separator_version={_version_or_fail('audio-separator')}")
    print(f"onnxruntime_version={onnxruntime.__version__}")
    print(f"mps_built={torch.backends.mps.is_built()}")
    print(f"mps_available={torch.backends.mps.is_available()}")
    print(f"audio_separator_import={audio_separator.__name__}")
    print(f"stemwerk_core_import={stemwerk_core.__name__}")


def test_runner_is_macos_arm64():
    assert platform.system() == "Darwin", (
        f"Expected Darwin runner, got {platform.system()!r}"
    )
    assert platform.machine() == "arm64", (
        f"Expected arm64 runner, got {platform.machine()!r}"
    )


def test_torch_pin():
    import torch

    assert torch.__version__.split("+", 1)[0] == EXPECTED_TORCH, (
        f"torch drifted from {EXPECTED_TORCH}: {torch.__version__}"
    )


def test_torchaudio_pin_and_abi_match():
    import torch
    import torchaudio

    torch_version = torch.__version__.split("+", 1)[0]
    torchaudio_version = torchaudio.__version__.split("+", 1)[0]

    assert torchaudio_version == EXPECTED_TORCHAUDIO, (
        f"torchaudio drifted from {EXPECTED_TORCHAUDIO}: {torchaudio.__version__}"
    )
    assert torchaudio_version.rsplit(".", 1)[0] == torch_version.rsplit(".", 1)[0], (
        f"torch {torch.__version__} and torchaudio {torchaudio.__version__} "
        "major.minor mismatch"
    )


def test_audio_separator_pin_and_import():
    assert _version_or_fail("audio-separator") == EXPECTED_AUDIO_SEPARATOR
    import audio_separator  # noqa: F401


def test_stemwerk_core_imports_from_local_install():
    import stemwerk_core  # noqa: F401

    direct_url = distribution("stemwerk-core").read_text("direct_url.json")
    assert direct_url, "stemwerk-core install is missing direct_url.json metadata"

    direct_url_data = json.loads(direct_url)
    assert "scripts/reaper/vendor/stemwerk-core" in direct_url_data.get("url", ""), (
        "stemwerk-core was not installed from the vendored source bundle"
    )


def test_onnxruntime_imports():
    import onnxruntime  # noqa: F401


def test_torch_wheel_has_mps_support_built():
    import torch

    assert torch.backends.mps.is_built() is True, (
        "Expected torch wheel with MPS support built in"
    )
