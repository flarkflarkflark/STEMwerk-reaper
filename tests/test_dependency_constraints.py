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


def _service_line_torch_runtime_status(torch_version, torchaudio_version="2.5.1"):
    core = str(torch_version).split("+", 1)[0]
    major, minor = [int(x) for x in core.split(".")[:2]]
    if major > 2 or (major == 2 and minor >= 6):
        return {
            "ok": False,
            "torch_supported": "no",
            "torchaudio_present": "yes" if torchaudio_version else "no",
            "drift_detected": "yes",
            "reason": "torch_too_new_for_demucs",
        }
    if not torchaudio_version:
        return {
            "ok": False,
            "torch_supported": "yes",
            "torchaudio_present": "no",
            "drift_detected": "yes",
            "reason": "torchaudio_missing_for_demucs",
        }
    return {
        "ok": True,
        "torch_supported": "yes",
        "torchaudio_present": "yes",
        "drift_detected": "no",
        "reason": "",
    }


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
    if platform.system() != "Darwin":
        pytest.skip("macOS Apple Silicon runtime smoke only")
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
    assert "numpy==1.26.4" in constraints_lines
    assert "torch==2.5.1" in constraints_lines
    assert "torchvision==0.20.1" in constraints_lines
    assert "torchaudio==2.5.1" in constraints_lines


def test_macos_intel_constraints_include_matching_cpu_fallback_stack():
    from pathlib import Path

    constraints_lines = Path("scripts/reaper/constraints/macos-intel.txt").read_text().splitlines()
    assert "numpy==1.26.4" in constraints_lines
    assert "torch==2.2.2" in constraints_lines
    assert "torchvision==0.17.2" in constraints_lines
    assert "torchaudio==2.2.2" in constraints_lines


def test_macos_bootstrap_repairs_after_audio_separator_install():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()
    audio_install_marker = 'pip install -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}"'
    repair_marker = 'set_status "deps_failed" "torch_pin_repair_failed"'

    assert 'PINNED_NUMPY_VERSION="1.26.4"' in script
    assert '"numpy==${PINNED_NUMPY_VERSION}"' in script
    assert 'if core(numpy_ver) != expected_numpy:' in script
    assert 'import numba' in script
    assert 'import_module_version("llvmlite")' in script
    assert 'for name in ("numpy", "numba", "llvmlite")' in script
    assert 'set_status "deps_failed" "numba_missing_after_setup"' in script
    assert 'PINNED_TORCH_VERSION_ARM64="2.5.1"' in script
    assert 'PINNED_TORCHVISION_VERSION_ARM64="0.20.1"' in script
    assert 'PINNED_TORCHAUDIO_VERSION_ARM64="2.5.1"' in script
    assert 'PINNED_TORCH_VERSION_INTEL="2.2.2"' in script
    assert 'PINNED_TORCHVISION_VERSION_INTEL="0.17.2"' in script
    assert 'PINNED_TORCHAUDIO_VERSION_INTEL="2.2.2"' in script
    assert 'PINNED_TORCH_VERSION="${PINNED_TORCH_VERSION_INTEL}"' in script
    assert 'PINNED_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION_INTEL}"' in script
    assert 'PINNED_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION_INTEL}"' in script
    assert 'PINNED_TORCH_VERSION="${PINNED_TORCH_VERSION_ARM64}"' in script
    assert 'PINNED_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION_ARM64}"' in script
    assert 'PINNED_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION_ARM64}"' in script
    assert 'MACOS_CONSTRAINTS_FILE="${MACOS_INTEL_CONSTRAINTS_FILE}"' in script
    assert 'MACOS_CONSTRAINTS_FILE="${MACOS_ARM_CONSTRAINTS_FILE}"' in script
    assert '"torchvision==${PINNED_TORCHVISION_VERSION}"' in script
    assert audio_install_marker in script
    assert repair_marker in script
    assert script.index(repair_marker) > script.index(audio_install_marker), (
        "macOS bootstrap must re-apply the pinned torch stack after audio-separator install"
    )


def test_macos_bootstrap_assertion_uses_audio_separator_metadata():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'version("audio-separator")' in script
    assert 'audio_separator.__version__' not in script


def test_macos_bootstrap_assertion_does_not_require_mps_availability_on_intel():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'record("mps_available"' in script
    assert 'add_failure("mps_available"' not in script
    assert 'failures.append("mps_available' not in script


def test_macos_bootstrap_assertion_reports_clear_failure_output():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '_probe_output="$("${_venv_py}" - <<PY 2>&1' in script
    assert '_probe=$(printf "%s\\n" "${_probe_output}" | tail -n 1)' in script
    assert 'failures=' in script
    assert 'Pinned runtime assertion failed: ${_probe}' in script
    assert 'STEMwerk bootstrap failed: pinned runtime assertion failed (%s): %s\\n' in script


def test_macos_runtime_verification_rejects_torch_26_plus():
    from pathlib import Path

    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "torch_too_new_for_demucs" in runtime_setup
    assert "torch_too_new_for_demucs" in setup_internal
    assert "numpy_too_new_for_demucs" in runtime_setup
    assert "numpy_too_new_for_demucs" in setup_internal
    assert "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime." in runtime_setup
    assert "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime." in setup_internal


def test_macos_setup_internal_append_log_helper_is_guarded():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local appendLogLine" in script
    assert "if appendLogLine then" in script
    assert "appendLogLine = function(logFile, line)" in script


def test_macos_setup_internal_reports_torch_drift_repair_guidance():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "torch_too_new_for_demucs" in script
    assert "torch_pin_repair_failed" in script
    assert "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime." in script


def test_setup_internal_postbootstrap_helpers_are_locally_bound():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local execProcess" in script
    assert "local trim" in script
    assert "execProcess = function(cmd, timeoutMs)" in script
    assert "trim = function(s)" in script

    lines = script.splitlines()

    def line_no(prefix: str) -> int:
        for idx, line in enumerate(lines, start=1):
            if line.strip().startswith(prefix):
                return idx
        raise AssertionError(f"missing marker: {prefix}")

    # Guard against accidental global fallback: declare these locals before
    # any setup action/runtime verification closure is defined.
    assert line_no("local execProcess") < line_no("local function runSupportBundleAction")
    assert line_no("local trim") < line_no("local function runSupportBundleAction")
    assert line_no("execProcess = function(cmd, timeoutMs)") < line_no("local function verifyRuntimePaths")
    assert line_no("trim = function(s)") < line_no("local function verifyRuntimePaths")
    assert line_no("execProcess = function(cmd, timeoutMs)") < line_no("local function performPostBootstrap")
    assert line_no("trim = function(s)") < line_no("local function performPostBootstrap")


def test_stemwerk_setup_runtime_helpers_use_local_bindings():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "local fileExists = SYSTEM.fileExists" in script
    assert "local quoteArg = SYSTEM.quoteArg" in script
    assert "local execProcess = SYSTEM.execProcess" in script
    assert "\nfileExists = SYSTEM.fileExists" not in script


def test_linux_bootstrap_rejects_python_314_with_clear_repair_guidance():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "3.10|3.11|3.12)" in script
    assert "3.14" not in script
    assert 'set_status "missing_python" "python_unsupported"' in script
    assert "Unsupported Python found: ${UNSUPPORTED_PYTHON_VERSION}. Install Python 3.10, 3.11, or 3.12, then run Repair/Rebuild." in script
    assert 'SUPPORTED_PYTHON_FOUND="no"' in script
    assert "SUPPORTED_PYTHON_RANGE=3.10-3.12" in script


def test_linux_bootstrap_prefers_supported_explicit_minor_before_python3():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert script.index('"/usr/local/bin/python3.12"') < script.index('"/usr/local/bin/python3"')
    assert script.index('"/usr/bin/python3.12"') < script.index('"/usr/bin/python3"')
    assert script.index("for cmd in python3.12 python3.11 python3.10 python3; do") < script.index('candidate="$(command -v python3)"')


def test_macos_bootstrap_reports_unsupported_python_without_python_missing_ambiguity():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '"python3.12"' in script
    assert '"python3.11"' in script
    assert '"python3.10"' in script
    assert script.index('"python3.12"') < script.index('"python3"')
    assert 'set_status "missing_python" "python_unsupported"' in script
    assert "Unsupported Python found: ${FIRST_UNSUPPORTED_PYTHON_VERSION}. Install Python 3.10, 3.11, or 3.12, then run Repair/Rebuild." in script
    assert "SUPPORTED_PYTHON_FOUND=no" in script
    assert "SUPPORTED_PYTHON_RANGE=3.10-3.12" in script


def test_setup_capabilities_do_not_mark_imports_ok_without_runtime():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'f:write("SUPPORTED_PYTHON_FOUND="' in script
    assert 'f:write("DETECTED_PYTHON_VERSION="' in script
    assert 'f:write("SUPPORTED_PYTHON_RANGE="' in script
    assert 'audioStatus = venvExists and "not_checked" or "no_runtime"' in script
    assert 'coreStatus = venvExists and "not_checked" or "no_runtime"' in script
    assert '"Unsupported Python found: " .. detected .. ". Install Python 3.10, 3.11, or 3.12, then run Repair/Rebuild."' in script


def test_support_bundle_surfaces_python_support_and_unknown_import_status():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'appendKey(diagnostics, "supported_python_found"' in script
    assert 'appendKey(diagnostics, "detected_python_version"' in script
    assert 'appendKey(diagnostics, "supported_python_range"' in script
    assert 'appendKey(diagnostics, "Capability audio_separator"' in script
    assert 'appendKey(diagnostics, "Capability stemwerk_core"' in script


def test_service_line_torch_runtime_policy_rejects_unsupported_versions():
    assert _service_line_torch_runtime_status("2.5.1") == {
        "ok": True,
        "torch_supported": "yes",
        "torchaudio_present": "yes",
        "drift_detected": "no",
        "reason": "",
    }
    assert _service_line_torch_runtime_status("2.6.0")["reason"] == "torch_too_new_for_demucs"
    assert _service_line_torch_runtime_status("2.6.0")["ok"] is False
    assert _service_line_torch_runtime_status("2.11.0")["reason"] == "torch_too_new_for_demucs"
    assert _service_line_torch_runtime_status("2.11.0")["ok"] is False


def test_service_line_torch_runtime_policy_rejects_missing_torchaudio():
    status = _service_line_torch_runtime_status("2.5.1", torchaudio_version="")

    assert status["ok"] is False
    assert status["torch_supported"] == "yes"
    assert status["torchaudio_present"] == "no"
    assert status["drift_detected"] == "yes"
    assert status["reason"] == "torchaudio_missing_for_demucs"


def test_setup_runtime_drift_capabilities_cannot_report_ok():
    from pathlib import Path

    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    support_bundle = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'f:write("TORCH_VERSION="' in setup_internal
    assert 'f:write("TORCHAUDIO_VERSION="' in setup_internal
    assert 'f:write("TORCH_SUPPORTED="' in setup_internal
    assert 'f:write("TORCHAUDIO_PRESENT="' in setup_internal
    assert 'f:write("RUNTIME_DRIFT_DETECTED="' in setup_internal
    assert 'f:write("RUNTIME_DRIFT_REASON="' in setup_internal
    assert 'verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #errors == 0' in setup_internal
    assert 'errors[#errors + 1] = torchRuntime.error' in setup_internal
    assert 'pythonOk and ffmpegOk and audioOk and runtimeOk' in runtime_setup
    assert 'torchaudio_missing_for_demucs' in runtime_setup
    assert 'major > 2 or (major == 2 and minor >= 6)' in linux_bootstrap
    assert 'import torchaudio  # noqa: F401' in linux_bootstrap
    assert 'appendKey(diagnostics, "TORCH_VERSION"' in support_bundle
    assert 'appendKey(diagnostics, "RUNTIME_DRIFT_DETECTED"' in support_bundle
