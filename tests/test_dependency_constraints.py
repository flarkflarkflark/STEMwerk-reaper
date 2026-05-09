"""Regression smoke for the v2.2.2.1 macOS/Linux torch pin hotfix."""

import json
import platform
import sys
from importlib.metadata import PackageNotFoundError, distribution, version

import pytest


EXPECTED_TORCH = "2.5.1"
EXPECTED_TORCHVISION = "0.20.1"
EXPECTED_TORCHAUDIO = "2.5.1"
EXPECTED_AUDIO_SEPARATOR = "0.23.0"


def _core_version(ver):
    return ver.split("+", 1)[0]


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
    import torchvision
    import torchaudio

    print()
    print(f"python_executable={sys.executable}")
    print(f"python_version={platform.python_version()}")
    print(f"platform_system={platform.system()}")
    print(f"platform_machine={platform.machine()}")
    print(f"torch_version={torch.__version__}")
    print(f"torchvision_version={torchvision.__version__}")
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

    assert _core_version(torch.__version__) == EXPECTED_TORCH, (
        f"torch drifted from {EXPECTED_TORCH}: {torch.__version__}"
    )


def test_torchvision_pin_and_abi_match():
    import torch
    import torchvision

    torch_version = _core_version(torch.__version__)
    torchvision_version = _core_version(torchvision.__version__)
    torchvision_requires = distribution("torchvision").requires or []

    assert torchvision_version == EXPECTED_TORCHVISION, (
        f"torchvision drifted from {EXPECTED_TORCHVISION}: {torchvision.__version__}"
    )
    assert torch_version == EXPECTED_TORCH, (
        f"torch drifted from {EXPECTED_TORCH}: {torch.__version__}"
    )
    assert any(
        req.replace(" ", "") == f"torch(=={EXPECTED_TORCH})"
        for req in torchvision_requires
    ), (
        f"torchvision {torchvision.__version__} does not declare torch=={EXPECTED_TORCH}; "
        f"requires={torchvision_requires!r}"
    )


def test_torchaudio_pin_and_abi_match():
    import torch
    import torchaudio

    torch_version = _core_version(torch.__version__)
    torchaudio_version = _core_version(torchaudio.__version__)

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


def test_macos_arm_constraints_include_matching_torchvision_pin():
    from pathlib import Path

    constraints_lines = Path("scripts/reaper/constraints/macos.txt").read_text().splitlines()
    assert "torch==2.5.1" in constraints_lines
    assert "torchvision==0.20.1" in constraints_lines
    assert "torchaudio==2.5.1" in constraints_lines


def test_macos_bootstrap_repairs_after_audio_separator_install():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()
    audio_install_marker = 'pip install -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}"'
    repair_marker = 'install_pinned_torch_stack || set_status "deps_failed" "torch_pin_repair_failed"'

    assert 'PINNED_TORCHVISION_VERSION_ARM64="0.20.1"' in script
    assert '"torchvision==${PINNED_TORCHVISION_VERSION}"' in script
    assert audio_install_marker in script
    assert repair_marker in script
    assert script.index(repair_marker) > script.index(audio_install_marker), (
        "macOS bootstrap must re-apply the pinned torch stack after audio-separator install"
    )
