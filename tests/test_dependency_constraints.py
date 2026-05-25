"""Regression smoke for the v2.2.2.1 macOS/Linux torch pin hotfix."""

import json
import platform
import subprocess
import sys
import tarfile
from importlib.metadata import PackageNotFoundError, distribution, version
from pathlib import Path

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


def test_runtime_setup_binds_trim_before_compat_probe_use():
    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()
    line_no = lambda needle: next(i for i, line in enumerate(runtime_setup.splitlines(), 1) if needle in line)

    assert "local trim" in runtime_setup
    assert "trim = function(s)" in runtime_setup
    assert line_no("trim = function(s)") < line_no("local function checkDemucsRuntimeCompatibility")
    assert line_no("trim = function(s)") < line_no("local text = trim(out or \"\")")


def test_runtime_setup_demucs_probe_uses_temp_script_not_fragile_c_escaping():
    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()

    assert 'local tmpPy = os.tmpname()' in runtime_setup
    assert 'wf:write(script)' in runtime_setup
    assert 'local cmd = commandQuote(pythonPath) .. " " .. commandQuote(tmpPy)' in runtime_setup
    assert 'pcall(os.remove, tmpPy)' in runtime_setup
    assert 'split(\\\\' not in runtime_setup


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
    assert "System Python ${UNSUPPORTED_PYTHON_VERSION} is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild." in script
    assert 'set_status "missing_python" "managed_python_unavailable"' in script
    assert "STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer." in script
    assert 'SUPPORTED_PYTHON_FOUND="no"' in script
    assert "SUPPORTED_PYTHON_RANGE=3.10-3.12" in script


def test_linux_bootstrap_prefers_supported_explicit_minor_before_python3():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert script.index('"/usr/local/bin/python3.12"') < script.index('"/usr/local/bin/python3"')
    assert script.index('"/usr/bin/python3.12"') < script.index('"/usr/bin/python3"')
    assert script.index("for cmd in python3.12 python3.11 python3.10 python3; do") < script.index('candidate="$(command_path python3')


def test_macos_bootstrap_reports_unsupported_python_without_python_missing_ambiguity():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '"python3.12"' in script
    assert '"python3.11"' in script
    assert '"python3.10"' in script
    assert script.index('"python3.12"') < script.index('"python3"')
    assert "System Python ${FIRST_UNSUPPORTED_PYTHON_VERSION} is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild." in script
    assert 'set_status "missing_python" "managed_python_unavailable"' in script
    assert "STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer." in script
    assert "SUPPORTED_PYTHON_FOUND=no" in script
    assert "SUPPORTED_PYTHON_RANGE=3.10-3.12" in script


def test_setup_internal_prefers_macos_venv_python_for_runtime_verification():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'local pythonCandidate = state.PYTHON_PATH or ""' in script
    assert 'if OS == "macOS" then' in script
    assert 'local venvCandidate = trim(state.VENV_PYTHON_PATH or state.VENV_PYTHON or "")' in script
    assert "pythonCandidate = venvCandidate" in script
    assert 'pythonPath = resolvePath(pythonCandidate ~= "" and pythonCandidate or state.VENV_PYTHON or "")' in script


def test_setup_internal_marks_intel_macos_cpu_fallback_success_as_expected():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'if OS == "macOS" and MAC_ARCH == "x86_64" and profile == "mac-cpu" and backend == "cpu" then' in script
    assert "Setup completed using Intel macOS CPU fallback." in script
    assert "MPS is unavailable on Intel Macs; CPU processing is expected." in script
    assert "CPU fallback: MPS unavailable" in script
    assert 'and (trim(backendReason or "") == "" or trim(backendReason or "") == "mps_unavailable")' in script


def test_setup_internal_treats_macos_cpu_mps_unavailable_as_info_not_failure():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'and profile == "mac-cpu"' in script
    assert 'and backend == "cpu"' in script
    assert 'and trim(state.STATUS or "") == "ok"' in script
    assert 'and verification.pythonOk' in script
    assert 'and verification.ffmpegOk' in script
    assert 'and #errors == 0' in script
    assert 'and (trim(backendReason or "") == "" or trim(backendReason or "") == "mps_unavailable")' in script
    assert 'and trim(state.AUDIO_SEPARATOR_IMPORT or "") == "ok"' in script
    assert 'and trim(state.AUDIO_SEPARATOR_DEPS_COMPLETE or "") == "yes"' in script
    assert 'and trim(state.BACKEND_DEPS_COMPLETE or "") ~= "no"' in script
    assert 'and trim(verification.pythonPath or "") ~= ""' in script
    assert 'and trim(verification.ffmpegPath or "") ~= ""' in script


def test_setup_internal_still_flags_real_failures_and_linux_deps_failed():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'and trim(state.STATUS or "") == "ok"' in script
    assert "and verification.pythonOk" in script
    assert "and verification.ffmpegOk" in script
    assert "and #errors == 0" in script
    assert "Setup was not completely successful." in script


def test_setup_capabilities_do_not_mark_imports_ok_without_runtime():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'f:write("SUPPORTED_PYTHON_FOUND="' in script
    assert 'f:write("DETECTED_PYTHON_VERSION="' in script
    assert 'f:write("SUPPORTED_PYTHON_RANGE="' in script
    assert 'audioStatus = venvExists and "not_checked" or "no_runtime"' in script
    assert 'coreStatus = venvExists and "not_checked" or "no_runtime"' in script
    assert '"System Python " .. detected .. " is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."' in script


def test_support_bundle_surfaces_python_support_and_unknown_import_status():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'appendKey(diagnostics, "supported_python_found"' in script
    assert 'appendKey(diagnostics, "detected_python_version"' in script
    assert 'appendKey(diagnostics, "supported_python_range"' in script
    assert 'appendKey(diagnostics, "Capability audio_separator"' in script
    assert 'appendKey(diagnostics, "Capability stemwerk_core"' in script
    assert 'appendKey(diagnostics, "MANAGED_PYTHON_STATUS"' in script
    assert 'appendKey(diagnostics, "MANAGED_PYTHON_SHA256_OK"' in script
    assert 'appendKey(diagnostics, "MANAGED_PYTHON_REPLACED"' in script
    assert 'appendKey(diagnostics, "MANAGED_PYTHON_ROLLBACK"' in script


def test_service_line_torch_runtime_policy_rejects_unsupported_versions():
    assert _service_line_torch_runtime_status("2.2.2") == {
        "ok": True,
        "torch_supported": "yes",
        "torchaudio_present": "yes",
        "drift_detected": "no",
        "reason": "",
    }
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


def test_linux_bootstrap_uses_managed_python_before_unsupported_system_python():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert script.index("if find_managed_python; then") < script.index('"/usr/local/bin/python3.12"')
    assert 'if install_managed_python_runtime && find_managed_python; then' in script
    assert script.index("if install_managed_python_runtime && find_managed_python; then") < script.index('"/usr/local/bin/python3.12"')
    assert "Using managed Python after acquisition" in script
    assert '"${PYTHON}" -m venv "${RUNTIME_BASE}/.venv"' in script
    assert "Runtime verification passed." in script
    assert "python3.14" not in script
    assert "pkexec" not in script


def test_macos_bootstrap_uses_managed_python_before_unsupported_system_python():
    from pathlib import Path

    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert script.index('find_managed_python; then') < script.index('"/opt/homebrew/bin/python3.12"')
    assert 'if install_managed_python_runtime && find_managed_python; then' in script
    assert script.index("if install_managed_python_runtime && find_managed_python; then") < script.index('"/opt/homebrew/bin/python3.12"')
    assert "Selected STEMwerk-managed Python interpreter after acquisition" in script
    assert '"${PYTHON}" -m venv "${RUNTIME_BASE}/.venv"' in script
    assert "Runtime verification passed." in script
    assert "brew install" not in script
    assert "${BREW}" not in script


def test_managed_python_failure_messages_are_specific():
    from pathlib import Path

    linux_script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    mac_script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    download_failure = "STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
    unsupported = "STEMwerk managed Python is not available for this platform yet."
    sha_failure = "Managed Python download failed verification and was not installed."
    assert linux_script.index("Attempting STEMwerk-managed Python runtime acquisition") < linux_script.index(download_failure)
    assert mac_script.index("Attempting STEMwerk-managed Python runtime acquisition") < mac_script.index(download_failure)
    assert unsupported in linux_script
    assert unsupported in mac_script
    assert sha_failure in linux_script
    assert sha_failure in mac_script
    assert "Unsupported Python found: ${UNSUPPORTED_PYTHON_VERSION}. Install Python" not in linux_script
    assert "Unsupported Python found: ${FIRST_UNSUPPORTED_PYTHON_VERSION}. Install Python" not in mac_script


def test_reapack_payload_includes_managed_python_runtime_files():
    from pathlib import Path

    index = Path("index.xml").read_text()

    assert "STEMwerk-SETUP.lua" in index
    assert "STEMwerk_Bootstrap_Linux.sh" in index
    assert "STEMwerk_Bootstrap_macOS.sh" in index
    assert "_internal/STEMwerk_Managed_Python.lua" in index
    assert "_internal/STEMwerk_Managed_Python.sh" in index


def test_managed_python_manifest_pins_astral_python_31213():
    from pathlib import Path

    manifest = Path("scripts/reaper/_internal/STEMwerk_Managed_Python.lua").read_text()
    helper = Path("scripts/reaper/_internal/STEMwerk_Managed_Python.sh").read_text()

    assert 'version = "3.12.13"' in manifest
    assert 'release = "20260408"' in manifest
    assert "python-build-standalone/releases/download/20260408" in manifest
    assert "ddd48f521f79395d9b8b094d34a86d7ec86772ab66c96b0de65a3b561ea7cf10" in manifest
    assert "1fee0596ba791fd83c33babf2ae8e00b0a1056b957955f2a34f7178ca8b80525" in manifest
    assert "ac167e74961316ceabdbe4839f19aa6000c592b08e5a1fab4646cb225ede13d5" in manifest
    assert 'STEMWERK_MANAGED_PYTHON_VERSION="3.12.13"' in helper
    assert "latest" not in helper.lower()


def test_managed_python_helper_rejects_sha_mismatch_and_unsupported_platform():
    from pathlib import Path

    helper = Path("scripts/reaper/_internal/STEMwerk_Managed_Python.sh").read_text()

    assert 'MANAGED_PYTHON_ERROR="sha256_mismatch"' in helper
    assert 'MANAGED_PYTHON_ERROR="unsupported_platform"' in helper
    assert "Managed Python download failed verification and was not installed." in helper
    assert "STEMwerk managed Python is not available for this platform yet." in helper
    assert "apt-get" not in helper
    assert "dnf" not in helper
    assert "pacman" not in helper
    assert "yay" not in helper
    assert "sudo" not in helper
    assert "pkexec" not in helper
    assert "brew" not in helper


def test_managed_python_archive_path_traversal_is_rejected(tmp_path):
    helper = "scripts/reaper/_internal/STEMwerk_Managed_Python.sh"
    archive = tmp_path / "bad.tar.gz"
    payload = tmp_path / "payload.txt"
    payload.write_text("bad", encoding="utf-8")
    with tarfile.open(archive, "w:gz") as tf:
        tf.add(payload, arcname="../escape.txt")

    script = (
        f'. "{helper}"; '
        "LOG_FILE=/dev/null; "
        f'managed_python_archive_safe "{archive}"'
    )
    result = subprocess.run(["/bin/sh", "-c", script], cwd=Path.cwd())
    assert result.returncode != 0


def _write_fake_managed_python(root, version="3.12.13", marker="new"):
    bin_dir = root / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    python = bin_dir / "python3"
    python.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' '{version}'\n",
        encoding="utf-8",
    )
    python.chmod(0o755)
    (root / "MARKER").write_text(marker, encoding="utf-8")


def _make_managed_python_archive(tmp_path, name="managed.tar.gz", version="3.12.13", marker="new"):
    payload = tmp_path / f"payload-{marker}"
    python_root = payload / "python"
    _write_fake_managed_python(python_root, version=version, marker=marker)
    archive = tmp_path / name
    with tarfile.open(archive, "w:gz") as tf:
        tf.add(python_root, arcname="python")
    return archive


def _run_managed_python_helper(script, runtime_base):
    helper = "scripts/reaper/_internal/STEMwerk_Managed_Python.sh"
    shell = (
        f'RUNTIME_BASE="{runtime_base}"; '
        "LOG_FILE=/dev/null; "
        f'. "{helper}"; '
        "managed_python_init_state; "
        f"{script}"
    )
    return subprocess.run(
        ["/bin/sh", "-c", shell],
        cwd=Path.cwd(),
        text=True,
        capture_output=True,
    )


def test_managed_python_install_no_existing_python_succeeds(tmp_path):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    archive = _make_managed_python_archive(tmp_path, marker="fresh")

    result = _run_managed_python_helper(
        f'managed_python_install_archive "{archive}"; '
        'printf "replaced=%s rollback=%s marker=%s\\n" '
        '"$MANAGED_PYTHON_REPLACED" "$MANAGED_PYTHON_ROLLBACK" "$(cat "$RUNTIME_BASE/python/MARKER")"',
        runtime,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert "replaced=no rollback=no marker=fresh" in result.stdout
    assert (runtime / "python" / "bin" / "python3").exists()


def test_managed_python_existing_python_replacement_succeeds(tmp_path):
    runtime = tmp_path / "runtime"
    _write_fake_managed_python(runtime / "python", marker="old")
    archive = _make_managed_python_archive(tmp_path, marker="new")

    result = _run_managed_python_helper(
        f'managed_python_install_archive "{archive}"; '
        'printf "replaced=%s rollback=%s marker=%s prev=%s\\n" '
        '"$MANAGED_PYTHON_REPLACED" "$MANAGED_PYTHON_ROLLBACK" '
        '"$(cat "$RUNTIME_BASE/python/MARKER")" "$([ -e "$RUNTIME_BASE/python.prev" ] && echo yes || echo no)"',
        runtime,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert "replaced=yes rollback=no marker=new prev=no" in result.stdout


def test_managed_python_replacement_failure_restores_existing_python(tmp_path):
    runtime = tmp_path / "runtime"
    _write_fake_managed_python(runtime / "python", marker="old")
    archive = _make_managed_python_archive(tmp_path, marker="new")

    result = _run_managed_python_helper(
        "mv() { "
        'if [ "$1" = "$RUNTIME_BASE/python.next" ] && [ "$2" = "$RUNTIME_BASE/python" ]; then return 1; fi; '
        'command mv "$@"; '
        "}; "
        f'managed_python_install_archive "{archive}"; rc=$?; '
        'printf "rc=%s rollback=%s marker=%s exists=%s\\n" '
        '"$rc" "$MANAGED_PYTHON_ROLLBACK" "$(cat "$RUNTIME_BASE/python/MARKER")" '
        '"$([ -d "$RUNTIME_BASE/python" ] && echo yes || echo no)"; '
        "exit 0",
        runtime,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert "rc=1 rollback=yes marker=old exists=yes" in result.stdout


def test_managed_python_stale_next_cleanup_preserves_current_python(tmp_path):
    runtime = tmp_path / "runtime"
    _write_fake_managed_python(runtime / "python", marker="old")
    _write_fake_managed_python(runtime / "python.next", marker="stale")
    archive = _make_managed_python_archive(tmp_path, marker="new")

    result = _run_managed_python_helper(
        f'managed_python_install_archive "{archive}"; '
        'printf "marker=%s stale=%s\\n" "$(cat "$RUNTIME_BASE/python/MARKER")" '
        '"$([ -e "$RUNTIME_BASE/python.next" ] && echo yes || echo no)"',
        runtime,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert "marker=new stale=no" in result.stdout


def test_managed_python_replacement_paths_stay_under_runtime_base():
    helper = Path("scripts/reaper/_internal/STEMwerk_Managed_Python.sh").read_text()

    for path in [
        '"${RUNTIME_BASE}/python.tmp"',
        '"${RUNTIME_BASE}/python.next"',
        '"${RUNTIME_BASE}/python.prev"',
        '"${RUNTIME_BASE}/python"',
    ]:
        assert path in helper
    assert 'rm -rf "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python.next"' in helper
    assert 'mv "${RUNTIME_BASE}/python" "${RUNTIME_BASE}/python.prev"' in helper
    assert 'mv "${RUNTIME_BASE}/python.next" "${RUNTIME_BASE}/python"' in helper
    assert 'rm -rf "${RUNTIME_BASE}/python.prev"' in helper
    assert 'rm -rf "${RUNTIME_BASE}/python"\n    if mv "${RUNTIME_BASE}/python.prev" "${RUNTIME_BASE}/python"; then' in helper


def test_managed_python_state_fields_are_written_to_capabilities():
    from pathlib import Path

    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    linux_script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    mac_script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    for field in [
        "MANAGED_PYTHON_ENABLED",
        "MANAGED_PYTHON_STATUS",
        "MANAGED_PYTHON_VERSION",
        "MANAGED_PYTHON_RELEASE",
        "MANAGED_PYTHON_PLATFORM",
        "MANAGED_PYTHON_ARCH",
        "MANAGED_PYTHON_URL",
        "MANAGED_PYTHON_SHA256_OK",
        "MANAGED_PYTHON_PATH",
        "MANAGED_PYTHON_REPLACED",
        "MANAGED_PYTHON_ROLLBACK",
        "SYSTEM_PYTHON_PATH",
        "SYSTEM_PYTHON_VERSION",
        "SYSTEM_PYTHON_USED",
        "VENV_PYTHON_PATH",
    ]:
        assert field in setup_internal
        assert field in linux_script
        assert field in mac_script


def test_rebuild_venv_safety_allows_missing_target_under_safe_parent():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "allowMissingTarget and not pathExists(targetPath)" in script
    assert 'validateCanonicalDeleteTarget(runtime.venvDir, expectedVenv, "venv", true)' in script
    assert 'return false, "target_mismatch", targetCanon, expectedCanon' in script


def test_command_path_noise_is_ignored_for_python_resolution():
    from pathlib import Path

    linux_script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    mac_script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()
    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()
    support_bundle = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'case "${line}" in' in linux_script
    assert '/*)' in linux_script
    assert 'candidate="$(command_path "${cmd}" || true)"' in linux_script
    assert 'case "${_line}" in' in mac_script
    assert '_resolved=$(command_path "$1" || true)' in mac_script
    assert 'candidate:match("^/") and fileExists(candidate)' in runtime_setup
    assert 'candidate:match("^/") and fileExists(candidate)' in support_bundle


def test_linux_managed_flow_installs_audio_separator_runtime_deps_after_torch():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'PINNED_NUMPY_VERSION="1.26.4"' in script
    assert 'PINNED_NUMBA_VERSION="0.59.1"' in script
    assert 'PINNED_LLVM_VERSION="0.42.0"' in script
    assert "enforce_runtime_python_pins" in script
    assert '"numpy==${PINNED_NUMPY_VERSION}"' in script
    assert '"llvmlite==${PINNED_LLVM_VERSION}"' in script
    assert '"numba==${PINNED_NUMBA_VERSION}"' in script
    assert 'log_stage "Checking/installing audio_separator"' in script
    assert 'Installing audio-separator 0.23.0 with constraints (torch pinned)' in script
    assert '"${VENV_PY}" -m pip install --no-deps "${PACKAGE}"' in script
    assert script.index('install_linux_torch_stack "cpu"') < script.index('log_stage "Checking/installing audio_separator"')
    assert script.index('log_stage "Checking/installing audio_separator"') < script.index("Final verification")


def test_linux_constraints_use_public_torch_versions_and_runtime_pins():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'str(getattr(m, "__version__", "")).split("+", 1)[0]' in script
    assert 'echo "numpy==${PINNED_NUMPY_VERSION}"' in script
    assert 'echo "llvmlite==${PINNED_LLVM_VERSION}"' in script
    assert 'echo "numba==${PINNED_NUMBA_VERSION}"' in script
    assert 'for name in ("torch","torchvision","torchaudio"):' in script


def test_linux_backend_reason_not_python_missing_after_valid_venv():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "clear_stale_python_backend_reason" in script
    assert "Clearing stale backend reason after valid venv Python" in script
    assert "stalePythonBackendReason" in setup_internal
    assert "Ignore stale Python discovery failures once managed/venv Python verifies" in setup_internal


def test_audio_separator_missing_maps_to_dependency_failure_not_python_missing():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'lower == "audio_separator_install_failed"' in script
    assert 'part = "audio-separator install failed"' in script
    assert 'backendReason = "audio_separator_install_failed"' in script
    assert 'backendReason = "audio_separator_missing"' in script


def test_linux_deps_failed_with_python_diagnostics_does_not_map_to_python_missing():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "knownRuntimeFailureState" in script
    assert "hasPythonDiagnosticPath" in script
    assert 'errors[#errors + 1] = "runtime_incomplete"' in script
    assert 'errors[#errors + 1] = "python_missing"' in script
    assert "if knownRuntimeFailureState(state) and hasPythonDiagnosticPath(state) then" in script
    assert 'backendReason = "runtime_incomplete"' in script


def test_linux_runtime_failure_backend_reason_strips_stale_python_missing_tokens():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'if knownRuntimeFailureState(state) and hasPythonDiagnosticPath(state) then' in script
    assert 'for raw in tostring(backendReason or ""):gmatch("[^;]+") do' in script
    assert "not stalePythonBackendReason(part)" in script
    assert "local statusReason = trim(state.STATUS_REASON or \"\")" in script
    assert "local savedReason = trim(state.BACKEND_REASON or \"\")" in script


def test_linux_genuine_no_python_case_still_uses_python_missing():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "elseif knownRuntimeFailureState(state) and hasPythonDiagnosticPath(state) then" in script
    assert 'errors[#errors + 1] = "python_missing"' in script


def test_linux_no_deps_audio_separator_fallback_requires_runtime_deps():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert '"${VENV_PY}" -m pip install --no-deps "${PACKAGE}"' in script
    assert "verify_audio_separator_runtime_deps || audio_install_rc=1" in script
    assert 'log_step "audio-separator runtime dependencies incomplete; attempting full dependency repair install"' in script
    assert 'audio_repair_attempted=1' in script
    assert 'PACKAGE="audio-separator==0.23.0"' in script
    assert 'if [ "${audio_repair_rc}" -eq 0 ]; then' in script
    assert "verify_audio_separator_runtime_deps || audio_repair_rc=1" in script
    assert "AUDIO_SEPARATOR_DEPS_COMPLETE=\"no\"" in script
    assert "BACKEND_DEPS_COMPLETE=\"no\"" in script
    assert "audio_separator_dep_import_failed:" in script
    assert script.index('"${VENV_PY}" -m pip install --no-deps "${PACKAGE}"') < script.index("verify_audio_separator_runtime_deps || audio_install_rc=1")
    assert "Skipping torch pin repair and ONNX install after audio-separator dependency failure" in script
    assert 'if [ "${audio_install_rc}" -eq 0 ] && [ "${STATUS}" = "ok" ]; then' in script
    assert script.index('set_status "deps_failed" "audio_separator_install_failed"') < script.index('if [ "${audio_install_rc}" -eq 0 ] && [ "${STATUS}" = "ok" ]; then')


def test_linux_final_verification_requires_audio_separator_dependency_imports():
    linux_script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    mac_script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    for module in [
        "diffq",
        "librosa",
        "beartype",
        "einops",
        "julius",
        "ml_collections",
        "onnx",
        "onnx2torch",
        "pydub",
        "requests",
        "resampy",
        "rotary_embedding_torch",
        "samplerate",
        "scipy",
        "six",
        "tqdm",
        "yaml",
    ]:
        assert f'"{module}"' in linux_script
        assert f'"{module}"' in mac_script
    assert "if ! verify_audio_separator_runtime_deps; then" in linux_script
    assert 'set_status "deps_failed" "audio_separator_install_failed"' in linux_script
    assert 'verify_audio_separator_runtime_deps || set_status "deps_failed" "audio_separator_install_failed"' in mac_script
    assert '[ "${AUDIO_SEPARATOR_DEPS_COMPLETE}" = "yes" ]' in linux_script
    assert 'log_step "Venv runtime incomplete; refusing to set PYTHON_PATH"' in linux_script
    assert 'log_step "Venv runtime verified; PYTHON_PATH set to venv"' in linux_script
    assert linux_script.index('[ "${AUDIO_SEPARATOR_DEPS_COMPLETE}" = "yes" ]') < linux_script.index('log_step "Venv runtime verified; PYTHON_PATH set to venv"')


def test_linux_failure_status_prevents_python_path_writeout():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'py_path_out="${PYTHON_PATH}"' in script
    assert 'deps_failed:*|venv_failed:*|*:audio_separator_install_failed)' in script
    assert 'echo "PYTHON_PATH=${py_path_out}"' in script


def test_linux_half_installed_audio_separator_triggers_full_dependency_repair_attempt():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert '"${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1 || audio_import_rc=$?' in script
    assert 'if [ "${audio_import_rc}" -ne 0 ] && [ "${audio_install_rc}" -eq 0 ]; then' in script
    assert 'if [ "${audio_install_rc}" -ne 0 ]; then' in script
    assert 'log_step "audio-separator runtime dependencies incomplete; attempting full dependency repair install"' in script
    assert 'audio_repair_attempted=1' in script


def test_linux_audio_separator_repair_failure_stays_deps_failed_and_blocks_python_path():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'BACKEND_REASON="${BACKEND_REASON:-audio_separator_install_failed}"' in script
    assert 'set_status "deps_failed" "audio_separator_install_failed"' in script
    assert 'py_path_out="${PYTHON_PATH}"' in script
    assert 'deps_failed:*|venv_failed:*|*:audio_separator_install_failed)' in script


def test_linux_audio_separator_repair_success_keeps_runtime_verification_path():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'if [ "${audio_repair_rc}" -eq 0 ]; then' in script
    assert "verify_audio_separator_runtime_deps || audio_repair_rc=1" in script
    assert 'log_step "Venv runtime verified; PYTHON_PATH set to venv"' in script


def test_linux_missing_compiler_for_diffq_reports_build_tools_message():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "detect_build_tools_missing_log" in script
    assert "command 'clang' failed: No such file or directory" in script
    assert "command 'gcc' failed: No such file or directory" in script
    assert "command 'cc' failed: No such file or directory" in script
    message = "Backend dependency build failed because no C compiler was found. Install clang/gcc/build tools, then run Repair/Rebuild again."
    assert message in script
    assert message in setup_internal
    assert 'BACKEND_DEPS_REASON="missing_diffq_or_build_tools"' in script
    assert 'BUILD_TOOLS_MISSING="yes"' in script


def test_linux_managed_diffq_wheelhouse_flow_is_enforced_for_managed_py312():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "is_managed_python_312_linux_x86_64" in script
    assert "find_managed_diffq_wheel" in script
    assert "install_managed_diffq_wheel" in script
    assert "vendor/wheels/linux-x86_64-cp312" in script
    assert '"${RUNTIME_BASE}/wheels/linux-x86_64-cp312"' in script
    assert '"${RUNTIME_BASE}/cache/wheels"' in script
    assert "--only-binary=diffq" in script
    assert 'log_step "Managed dependency wheel missing for diffq on Linux Python 3.12. Repair/Rebuild could not complete."' in script
    assert 'BACKEND_DEPS_REASON="managed_diffq_wheel_missing"' in script
    assert 'BACKEND_REASON="managed_diffq_wheel_missing"' in script
    assert "Managed dependency wheel missing for diffq on Linux Python 3.12" in setup_internal
    assert '_os_name="${OS_NAME:-}"' in script
    assert '_arch="${ARCH:-}"' in script
    assert '_os_name="$(uname -s 2>/dev/null | tr \'[:upper:]\' \'[:lower:]\')"' in script
    assert '_arch="$(uname -m 2>/dev/null)"' in script


def test_linux_managed_wheel_missing_skips_no_deps_fallback_and_fails_clear():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'if [ "${audio_install_rc}" -ne 0 ] && [ "${managed_diffq_required}" -eq 0 ]; then' in script
    assert 'log_step "Managed wheel path required for Linux managed Python 3.12; skipping no-deps fallback"' in script
    assert 'log_step "Managed wheel path required for Linux managed Python 3.12; full dependency repair cannot continue without diffq wheel"' in script


def test_linux_managed_wheel_lookup_is_nounset_safe_for_platform_vars():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert '[ "${_os_name}" = "linux" ] || return 1' in script
    assert '[ "${_arch}" = "x86_64" ] || return 1' in script
    assert '${OS_NAME:-}' in script
    assert '${ARCH:-}' in script


def test_audio_separator_dependency_status_fields_are_reported():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    support_bundle = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()
    linux_script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    for field in [
        "AUDIO_SEPARATOR_IMPORT",
        "AUDIO_SEPARATOR_DEPS_COMPLETE",
        "BACKEND_DEPS_COMPLETE",
        "BACKEND_DEPS_REASON",
        "BUILD_TOOLS_MISSING",
    ]:
        assert field in setup_internal
        assert field in support_bundle
        assert field in linux_script


def test_linux_venv_create_failure_stops_before_dependency_pipeline():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "create_venv_with_selected_python" in script
    assert "Stopping setup after venv creation failure; dependency installation will not run." in script
    assert 'if [ "${STATUS}" = "ok" ] && [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then' in script
    assert script.index("Stopping setup after venv creation failure") < script.index("Upgrading pip/setuptools/wheel")
    assert script.index("Upgrading pip/setuptools/wheel") < script.index('install_linux_torch_stack "cpu"')


def test_linux_venv_missing_ensurepip_gets_specific_reason_and_message():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    message = (
        "Could not create Python virtual environment because Python venv/ensurepip is missing. "
        "STEMwerk could not use or install a managed Python runtime. Install python3.12-venv "
        "or use the STEMwerk Linux/macOS package with managed runtime, then run Repair/Rebuild."
    )

    assert "classify_venv_failure" in script
    assert "ensurepip is not available" in script
    assert "venv_create_failed_missing_ensurepip" in script
    assert message in script
    assert message in setup_internal


def test_linux_broken_system_python_falls_back_to_managed_python_for_venv():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "try_managed_python_after_venv_failure" in script
    assert "System Python could not create a venv; trying STEMwerk-managed Python fallback." in script
    assert "Using managed Python after system venv failure" in script
    assert "selected_python_is_managed" in script


def test_setup_cannot_report_runtime_ok_after_venv_create_failed():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'set_status "venv_failed" "${VENV_CREATE_REASON:-venv_create_failed}"' in script
    assert 'if [ "${STATUS}" = "ok" ] && [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then' in script
    assert script.index('set_status "venv_failed" "${VENV_CREATE_REASON:-venv_create_failed}"') < script.index("Upgrading pip/setuptools/wheel")
