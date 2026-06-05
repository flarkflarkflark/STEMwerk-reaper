"""Regression smoke for the v2.2.2.1 macOS/Linux torch pin hotfix."""

import importlib.util
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


def _load_audio_separator_process_module():
    path = Path("scripts/reaper/audio_separator_process.py")
    spec = importlib.util.spec_from_file_location("audio_separator_process_dependency_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


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


def _rocm_gfx1201_runtime_status(
    torch_version,
    torchaudio_version="2.10.0",
    hip_present=True,
    cuda_available=True,
    cuda_count=1,
    device_text="amd radeon rx 9070|gfx1201",
):
    core = str(torch_version).split("+", 1)[0]
    major, minor = [int(x) for x in core.split(".")[:2]]
    allow = (
        (major, minor) == (2, 10)
        and bool(torchaudio_version)
        and hip_present
        and cuda_available
        and int(cuda_count) > 0
        and ("rx 9070" in device_text.lower() or "gfx1201" in device_text.lower())
    )
    return allow


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
    try:
        installed = version("audio-separator")
    except PackageNotFoundError:
        pytest.skip("audio-separator is not installed in this local test environment")
    assert installed == EXPECTED_AUDIO_SEPARATOR
    import audio_separator  # noqa: F401


def test_stemwerk_core_imports_from_local_install():
    if importlib.util.find_spec("stemwerk_core") is None:
        pytest.skip("stemwerk_core is not installed in this local test environment")
    import stemwerk_core  # noqa: F401

    direct_url = distribution("stemwerk-core").read_text("direct_url.json")
    assert direct_url, "stemwerk-core install is missing direct_url.json metadata"

    direct_url_data = json.loads(direct_url)
    assert "scripts/reaper/vendor/stemwerk-core" in direct_url_data.get("url", ""), (
        "stemwerk-core was not installed from the vendored source bundle"
    )


def test_onnxruntime_imports():
    pytest.importorskip("onnxruntime")
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


def test_setup_internal_treats_linux_cpu_no_gpu_detected_as_info_not_failure():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'or (OS == "Linux"' in script
    assert 'and profile == "linux-cpu"' in script
    assert 'and backend == "cpu"' in script
    assert 'and trim(state.STATUS or "") == "ok"' in script
    assert 'and trim(state.STATUS_REASON or "") == ""' in script
    assert 'and trim(state.AUDIO_SEPARATOR_IMPORT or "") == "ok"' in script
    assert 'and trim(state.AUDIO_SEPARATOR_DEPS_COMPLETE or "") == "yes"' in script
    assert 'and trim(state.BACKEND_DEPS_COMPLETE or "") ~= "no"' in script
    assert 'and trim(verification.pythonPath or "") ~= ""' in script
    assert 'and trim(verification.ffmpegPath or "") ~= ""' in script
    assert 'and (trim(backendReason or "") == "" or trim(backendReason or "") == "no_gpu_detected")' in script


def test_setup_internal_preserves_linux_rocm_backend_detection_and_reasoning():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'local hipPresent = envJson' in script
    assert 'local rocmHost = envJson and envJson:find(\'"rocm_path_exists"%s*:%s*true\') ~= nil' in script
    assert "local rocmOk = hipPresent and cudaAvail and cudaCount > 0" in script
    assert "if rocmOk then" in script
    assert 'backend = "rocm"' in script
    assert "if rocmHost then" in script
    assert 'reason = "rocm_probe_failed"' in script
    assert 'reason = "no_gpu_detected"' in script


def test_linux_cpu_success_gate_does_not_match_rocm_backend_profiles():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'or (OS == "Linux"' in script
    assert 'and profile == "linux-cpu"' in script
    assert 'and backend == "cpu"' in script
    assert 'and (trim(backendReason or "") == "" or trim(backendReason or "") == "no_gpu_detected")' in script


def test_linux_bootstrap_rocm_failures_are_explicit_not_no_gpu_detected():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'rocm_fail_reason="rocm_probe_failed"' in script
    assert 'rocm_fail_reason="rocm_torch_cpu_fallback"' in script
    assert 'rocm_fail_reason="rocm_runtime_no_device"' in script
    assert 'BACKEND_REASON="${rocm_fail_reason}"' in script
    assert 'log_step "ROCm torch install/probe failed; falling back to CPU (reason=${rocm_fail_reason})"' in script


def test_linux_bootstrap_gpu_override_env_clear_keeps_explicit_rocm_detection_probe():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "unset HIP_VISIBLE_DEVICES HSA_OVERRIDE_GFX_VERSION ROCR_VISIBLE_DEVICES CUDA_VISIBLE_DEVICES" in script
    assert "if command -v rocminfo >/dev/null 2>&1; then" in script
    assert "env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES \\" in script
    assert 'rocminfo 2>/dev/null | grep -E "Name:|Marketing Name:|gfx|Device Type|Vendor Name"' in script
    assert 'if [ "${BACKEND}" = "rocm" ]; then' in script
    assert 'STEMWERK_BACKEND="${BACKEND}" "${VENV_PY}" - <<\'PY\'' in script


def test_linux_bootstrap_gfx1201_prefers_rocm7_stack_not_251_pin():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'ROCM7_GFX1201_TORCH_VERSION="2.10.0"' in script
    assert 'ROCM7_GFX1201_TORCHAUDIO_VERSION="2.10.0"' in script
    assert 'ROCM7_GFX1201_TORCHVISION_VERSION="0.25.0"' in script
    assert 'ACTIVE_TORCH_VERSION="${ROCM7_GFX1201_TORCH_VERSION}"' in script
    assert 'ACTIVE_TORCHVISION_VERSION="${ROCM7_GFX1201_TORCHVISION_VERSION}"' in script
    assert 'ACTIVE_TORCHAUDIO_VERSION="${ROCM7_GFX1201_TORCHAUDIO_VERSION}"' in script
    assert 'IDX_LIST="https://download.pytorch.org/whl/rocm7.0 https://download.pytorch.org/whl/rocm7.1 https://download.pytorch.org/whl/rocm7.2"' in script
    assert 'case "${ROCM_MM}" in' in script
    assert '7.*)' in script
    assert 'if [ "${ROCM_GFX1201}" -eq 1 ]; then' in script
    assert 'if [ "${ROCM_GFX1201}" -eq 1 ] && [ "${rocm_fail_reason}" = "rocm_wheel_not_found" ]; then' in script
    assert 'rocm_fail_reason="rocm7_stack_unavailable_for_gfx1201"' in script
    assert 'TORCH_RUNTIME_POLICY="rocm_gfx1201_allow_2_10_rocm7"' in script


def test_linux_bootstrap_gfx1201_requires_rx9070_or_gfx1201_device_visibility():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'if printf "%s %s\\n" "${device_names}" "${device_props}" | grep -Eiq "rx 9070|gfx1201"; then' in script
    assert 'ROCM_SELECTED_DEVICE="rx9070_gfx1201"' in script
    assert 'rocm_fail_reason="rocm_gfx1201_device_not_selected"' in script
    assert 'ROCM_DETECTED_DEVICES="${device_names}"' in script
    assert 'SELECTED_TORCH_STACK="torch==${ACTIVE_TORCH_VERSION}+$(basename "${idx}") torchvision==${ACTIVE_TORCHVISION_VERSION}+$(basename "${idx}") torchaudio==${ACTIVE_TORCHAUDIO_VERSION}+$(basename "${idx}")"' in script


def test_support_bundle_reports_rocm_selected_stack_and_devices():
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'appendKey(diagnostics, "ROCm selected index"' in script
    assert 'appendKey(diagnostics, "ROCm selected torch stack"' in script
    assert 'appendKey(diagnostics, "ROCm detected devices"' in script
    assert 'appendKey(diagnostics, "ROCm selected device"' in script
    assert 'appendKey(diagnostics, "ROCm fallback reason"' in script
    assert 'appendKey(diagnostics, "ROCm torch policy"' in script
    assert 'appendKey(diagnostics, "Runtime verify detail"' in script


def test_setup_internal_still_flags_real_failures_and_linux_deps_failed():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'and trim(state.STATUS or "") == "ok"' in script
    assert "and verification.pythonOk" in script
    assert "and verification.ffmpegOk" in script
    assert "and #errors == 0" in script
    assert "Setup was not completely successful." in script


def test_setup_window_has_default_size_and_minimum_clamp_without_forced_reinit():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local SETUP_MENU_DEFAULT_W = 1260" in script
    assert "local SETUP_MENU_DEFAULT_H = 904" in script
    assert "function enforceSetupWindowMinimum(state)" in script
    assert "if not (gfx and gfx.dock) then return end" in script
    assert "local needW = ww < 1120" in script
    assert "local needH = wh < 760" in script
    assert "gfx.dock(dockState or 0, wx or 0, wy or 0, targetW, targetH)" in script
    assert "enforceSetupWindowMinimum(LINUX_SETUP)" in script
    assert "enforceSetupWindowMinimum(m)" in script
    assert "gfx.init(setupWindowTitle(setupUiLabel()), SETUP_MENU_DEFAULT_W, SETUP_MENU_DEFAULT_H, 0, 120, 80)" in script


def test_helpers_module_defines_local_file_exists_and_does_not_use_global_fileExists():
    script = Path("scripts/reaper/_internal/STEMwerk_Helpers.lua").read_text()

    assert "local function helperFileExists(path)" in script
    assert "while helperFileExists(candidate) do" in script
    assert "while fileExists(candidate) do" not in script
    assert "SW_LOG, debugLog" in script
    assert "SW_LOG, fileExists, debugLog" not in script


def test_runtime_adaptive_cpu_parallel_policy_present_and_gpu_paths_unchanged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "_sep.SCHEDULER_POLICY = {" in script
    assert "_sep.resolveSchedulerConcurrencyPolicy = function(opts)" in script
    assert "local function detectLogicalCpuCount()" in script
    assert 'local h = io.popen("getconf _NPROCESSORS_ONLN 2>/dev/null")' in script
    assert "local function detectSystemRamGiB()" in script
    assert 'if OS == "Linux" then' in script
    assert "local minCpuForParallel = 8" in script
    assert "local minRamGiBForParallel = 8" in script
    assert 'policy.reason = "cpu_threads_ok"' in script
    assert 'policy.reason = "cpu_threads_low"' in script
    assert 'policy.reason = "cpu_threads_unknown"' in script
    assert 'policy.reason = "cpu_ram_low"' in script
    assert 'policy.reason = "cpu_ram_unknown"' in script
    assert 'policy.cap = math.min(jobCount, adaptiveCap)' in script
    assert 'policy.reason = "directml_multi_track"' in script
    assert 'timing:workers_launched count=' in script
    assert ' .. " reason=" .. tostring(multiTrackQueue.executionModeReason or multiTrackQueue.forceSequentialReason or "none")' in script


def test_runtime_scheduler_benchmark_gpu_cap_override_is_benchmark_only_and_logged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "STEMWERK_BENCH_GPU_CAP" in script
    assert "local function readBenchmarkGpuCapRequest()" in script
    assert "local function appendBenchmarkGpuCapDiagnostics(logFile)" in script
    assert "local function benchmarkGpuCapIgnoredReasonForPolicy(policy)" in script
    assert "benchmarkGpuCapRequested" in script
    assert "benchmarkGpuCapApplied" in script
    assert "benchmarkGpuCapIgnoredReason" in script
    assert "if benchmarkGpuCapRequested and benchmarkGpuCapEligible then" in script
    assert "and not benchmarkGpuCapRequested" in script
    assert 'schedulerPolicy.backend == "gpu"' in script
    assert "schedulerPolicy.cap >= 2" in script
    assert "directml_fixed_cap1" in script
    assert "mps_fixed_cap1" in script
    assert "dks_direct_long_cap1" in script
    assert "not_gpu_parallel_eligible" in script
    assert "bench_gpu_cap_requested=" in script
    assert "bench_gpu_cap_applied=" in script
    assert "bench_gpu_cap_ignored_reason=" in script
    assert 'local f = io.open(logFile, "a")' in script
    assert "appendBenchmarkGpuCapDiagnostics(logFile)" in script
    assert "_sep.ensureBenchmarkGpuCapDiagnosticsPersisted = function(logFile)" in script
    assert 'if content:find("bench_gpu_cap_requested=", 1, true) then' in script
    assert "_sep.ensureBenchmarkGpuCapDiagnosticsPersisted(job.logFile)" in script
    assert "workflow_source=" in script
    assert "route=" in script
    assert "stage=" in script
    assert "device=" in script
    assert "backend=" in script
    assert "effective_parallel_cap=" in script
    assert "lua_dks_scheduler_policy_cap=" in script
    assert 'SW_LOG.writeRunRootArtifact(' in script
    assert '"benchmark_scheduler_summary.txt"' in script
    assert '"parallelJobLimit=" .. tostring(multiTrackQueue.parallelJobLimit or "none")' in script


def test_dev_project_state_snapshot_helper_handles_benchmark_prep_request_and_defaults_to_read_only():
    script = Path("scripts/reaper/STEMwerk_Dev_Project_State_Snapshot.lua").read_text()

    assert 'local MCP_SECTION = "STEMwerk"' in script
    assert 'local SNAPSHOT_SECTION = "STEMwerkDevSnapshot"' in script
    assert 'local PREP_SECTION = "STEMwerkDevBenchmarkPrep"' in script
    assert 'local LEGACY_MCP_SECTION = "STEMwerkDevMCP"' in script
    assert 'local REQUEST_PREPARE_BENCHMARK_STATE = "prepare_benchmark_state"' in script
    assert "local function readBenchmarkRequest()" in script
    assert "local function getMcpExtState(key)" in script
    assert "if request ~= REQUEST_PREPARE_BENCHMARK_STATE then" in script
    assert "local function runBenchmarkPrep(requestState)" in script
    assert "local function selectExactItems(items, expectedCount)" in script
    assert "selection_mismatch: expected=%d actual=%d" in script
    assert "insufficient_media_items" in script
    assert "writePrepResult(fields)" in script
    assert "clearBenchmarkRequest(requestState.request)" in script
    assert "writeSnapshot(snapshot)" in script
    assert "snapshot_ok = \"1\"" in script
    assert "snapshot_ok = \"0\"" in script
    assert "prep_ok" in script
    assert "requested_item_count" in script
    assert "selected_media_item_count" in script
    assert "selection_source" in script
    assert "time_selection_start" in script
    assert "time_selection_end" in script
    assert "workflow_source_set" in script
    assert "workflow_mode_set" in script
    assert "device_set" in script
    assert "last_error" in script
    assert 'workflow_source = requestState.workflow_source' in script
    assert 'quick_preset = requestState.workflow_source' in script
    assert "Main_OnCommand" not in script
    assert "separation" not in script.lower()


def test_dev_prepare_benchmark_state_helper_is_compatibility_wrapper_for_snapshot_dispatcher():
    script = Path("scripts/reaper/STEMwerk_Dev_Prepare_Benchmark_State.lua").read_text()

    assert 'local MCP_SECTION = "STEMwerk"' in script
    assert 'local SNAPSHOT_COMMAND_ID = 71254' in script
    assert 'setTransientExtState("dev_mcp_request", "prepare_benchmark_state")' in script
    assert 'setTransientExtState("dev_mcp_requested_item_count", "8")' in script
    assert 'setTransientExtState("dev_mcp_workflow_source", "dks_direct")' in script
    assert 'setTransientExtState("dev_mcp_workflow_mode", "drumkit")' in script
    assert 'setTransientExtState("dev_mcp_device", "auto")' in script
    assert "reaper.Main_OnCommand(SNAPSHOT_COMMAND_ID, 0)" in script


def test_reaper_mcp_benchmark_runbook_documents_fixed_dispatcher_and_request_flow():
    doc = Path("docs/dev/STEMwerk_23_REAPER_MCP_Smoke_Benchmark.md").read_text()

    assert "Custom: STEMwerk_Dev_Project_State_Snapshot.lua" in doc
    assert "_RS6591f55c0e89376ce59cc3be252bf722305ed9e0" in doc
    assert "71254" in doc
    assert "STEMwerk/dev_mcp_request = prepare_benchmark_state" in doc
    assert "STEMwerk/dev_mcp_requested_item_count = 8" in doc
    assert "STEMwerk/dev_mcp_workflow_source = dks_direct" in doc
    assert "STEMwerk/dev_mcp_workflow_mode = drumkit" in doc
    assert "STEMwerk/dev_mcp_device = auto" in doc
    assert "STEMWERK_BENCH_DKS_STAGE2_CAP=2" in doc
    assert "STEMWERK_BENCH_DKS_STAGE2_CAP=4" in doc
    assert "STEMwerkDevBenchmarkPrep/*" in doc
    assert "STEMwerkDevSnapshot/*" in doc
    assert "STEMwerk/dev_mcp_request_handled" in doc
    assert "STEMwerkDevMCP" in doc
    assert "bench_dks_stage2_cap_requested=" in doc
    assert "bench_dks_stage2_cap_applied=" in doc
    assert "bench_dks_stage2_cap_ignored_reason=" in doc


def test_scheduler_policy_route_backend_defaults_are_explicit():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "NORMAL_GPU_MAX_PARALLEL = 2" in script
    assert "NORMAL_DIRECTML_MAX_PARALLEL = 1" in script
    assert "NORMAL_MPS_MAX_PARALLEL = 1" in script
    assert "DKS_DIRECT_GPU_SHORT_MAX_PARALLEL = 2" in script
    assert "DKS_DIRECT_GPU_LONG_MAX_PARALLEL = 1" in script
    assert "DKS_DIRECT_CPU_MAX_PARALLEL = 1" in script
    assert "DKS_EXTRACT_STAGE2_MAX_PARALLEL = 1" in script
    assert 'if route == "dks_direct" then' in script
    assert 'schedulerRoute = "dks_direct"' in script
    assert 'schedulerRoute = "dks_extract"' in script
    assert 'schedulerStage = "stage1_normal"' in script
    assert 'and hasRuntimeBackendType("mps")' in script
    assert 'schedulerBackend = "mps"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_long_cap1"' in script
    assert 'policy.reason = "scheduler_dks_direct_cpu_or_unknown_cap1"' in script
    assert '"scheduler_dks_extract_stage1_normal_gpu_cap2"' in script
    assert '"scheduler_normal_gpu_cap2"' in script
    assert 'policy.reason = "scheduler_mps_conservative"' in script
    assert 'policy.reason = "scheduler_unknown_backend_conservative"' in script
    assert 'scheduler_policy_route=' in script
    assert 'scheduler_policy_backend=' in script
    assert 'scheduler_policy_cap=' in script
    assert 'lua_dks_scheduler_policy_route=' in script


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


def test_rocm_gfx1201_policy_allows_known_rocm7_stack_only_with_expected_signals():
    assert _rocm_gfx1201_runtime_status("2.10.0", "2.10.0", True, True, 2, "AMD Radeon RX 9070|AMD Radeon 780M Graphics")
    assert not _rocm_gfx1201_runtime_status("2.10.0", "2.10.0", True, True, 2, "AMD Radeon 780M Graphics")
    assert not _rocm_gfx1201_runtime_status("2.11.0", "2.11.0", True, True, 2, "AMD Radeon RX 9070")
    assert not _rocm_gfx1201_runtime_status("2.10.0", "", True, True, 2, "AMD Radeon RX 9070")


def test_setup_runtime_drift_capabilities_cannot_report_ok():
    from pathlib import Path

    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    runtime_setup = Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua").read_text()
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    support_bundle = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'f:write("TORCH_VERSION="' in setup_internal
    assert 'f:write("TORCHAUDIO_VERSION="' in setup_internal
    assert 'f:write("TORCHVISION_VERSION="' in setup_internal
    assert 'f:write("NUMPY_VERSION="' in setup_internal
    assert 'f:write("NUMBA_VERSION="' in setup_internal
    assert 'f:write("LLVMLITE_VERSION="' in setup_internal
    assert 'f:write("AUDIO_SEPARATOR_VERSION="' in setup_internal
    assert 'f:write("ONNXRUNTIME_VERSION="' in setup_internal
    assert 'f:write("TORCH_SUPPORTED="' in setup_internal
    assert 'f:write("TORCHAUDIO_PRESENT="' in setup_internal
    assert 'f:write("RUNTIME_DRIFT_DETECTED="' in setup_internal
    assert 'f:write("RUNTIME_DRIFT_REASON="' in setup_internal
    assert 'f:write("RUNTIME_VERIFY_DETAIL="' in setup_internal
    assert 'f:write("TORCH_RUNTIME_POLICY="' in setup_internal
    assert 'f:write("CUDA_AVAILABLE="' in setup_internal
    assert 'f:write("CUDA_COUNT="' in setup_internal
    assert 'f:write("TORCH_HIP="' in setup_internal
    assert 'f:write("STATUS="' in setup_internal
    assert "allow_rocm7_gfx1201 = (" in setup_internal
    assert 'and ("rx 9070" in dev_text or "gfx1201" in dev_text)' in setup_internal
    assert 'local tmpPath = tostring(path) .. ".tmp"' in setup_internal
    assert "os.rename(tmpPath, path)" in setup_internal
    assert "runtimeDriftDetected = \"no\"" in setup_internal
    assert "runtimeDriftReason = \"\"" in setup_internal
    assert "state.STATUS_REASON = \"\"" in setup_internal
    assert "state.RUNTIME_VERIFY_DETAIL = \"ok\"" in setup_internal
    assert 'if verificationSuccess and trim(state.BACKEND_DEPS_COMPLETE or "") == "yes" then' in setup_internal
    assert 'verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #errors == 0' in setup_internal
    assert 'errors[#errors + 1] = torchRuntime.error' in setup_internal
    assert 'pythonOk and ffmpegOk and audioOk and runtimeOk' in runtime_setup
    assert 'torchaudio_missing_for_demucs' in runtime_setup
    assert 'major > 2 or (major == 2 and minor >= 6)' in linux_bootstrap
    assert "allow_rocm7_gfx1201 = (" in linux_bootstrap
    assert 'and ("rx 9070" in dev_text or "gfx1201" in dev_text)' in linux_bootstrap
    assert 'import torchaudio  # noqa: F401' in linux_bootstrap
    assert 'appendKey(diagnostics, "TORCH_VERSION"' in support_bundle
    assert 'appendKey(diagnostics, "RUNTIME_DRIFT_DETECTED"' in support_bundle


def test_device_refresh_has_module_scope_friendly_name_sanitizer():
    script = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text()

    assert "local function sanitizeFriendlyName(name)" in script
    assert 'if not name then return "" end' in script
    assert 'raw = tostring(name):gsub("%c", " ")' in script
    assert script.index("local function sanitizeFriendlyName(name)") < script.index("function DEVICE_RUNTIME.refreshRuntimeDevices(force)")
    assert 'local short = sanitizeFriendlyName(d.fullName or d.name)' in script


def test_early_stem_resolver_uses_safe_drumkit_route_helper_before_progress_init():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "local function safeDrumKitWorkflowActive()" in script
    assert 'mode = tostring(progressState.workflowMode or "")' in script
    assert 'mode = tostring(SETTINGS.workflowMode or "")' in script
    assert 'source = tostring(SETTINGS.workflowSource or "")' in script
    assert 'source == directSource or source == extractSource' in script
    resolver = script[
        script.index("function resolveStemSetForPaths(stemPaths)") :
        script.index("-- Available processing devices")
    ]
    assert "safeDrumKitWorkflowActive()" in resolver
    assert "isDrumKitWorkflowActive()" not in resolver
    assert "isDrumKitWorkflowActive = function()\n    return safeDrumKitWorkflowActive()" in script


def test_setup_authoritative_bootstrap_accepts_current_linux_torch_assertion_marker():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'text:find("Pinned runtime assertion passed", 1, true)' in script
    assert 'text:find("Pinned torch assertion passed", 1, true)' in script
    assert 'local pinnedRuntimeOk = text:find("Pinned runtime assertion passed", 1, true) ~= nil' in script
    assert 'and pinnedRuntimeOk' in script


def test_support_bundle_ignores_stale_capabilities_failed_verification_when_bootstrap_ok():
    support_bundle = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert "local capabilityStaleFailedVerification = (" in support_bundle
    assert 'and capabilityVerification == "failed"' in support_bundle
    assert "local function resolvedCapabilityValue(key, fallback)" in support_bundle
    assert 'or key == "TORCH_SUPPORTED"' in support_bundle
    assert 'or key == "TORCH_VERSION"' in support_bundle
    assert 'or key == "TORCHAUDIO_VERSION"' in support_bundle
    assert 'appendKey(diagnostics, "Capability verification", resolvedCapabilityValue("VERIFICATION", "missing")' in support_bundle


def test_windows_setup_overview_ignores_stale_failed_capabilities_when_bootstrap_ok():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local staleFailedVerification = (" in setup_internal
    assert "and verification == \"failed\"" in setup_internal
    assert "if staleFailedVerification then" in setup_internal
    assert "verification = \"\"" in setup_internal


def test_verify_only_rewrites_capabilities_from_current_runtime_probe():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "function firstNonEmpty(...)" in setup_internal
    assert 'if envJson:match(\'"\' .. key .. \'"%s*:%s*true\') then return "true" end' in setup_internal
    assert 'if envJson:match(\'"\' .. key .. \'"%s*:%s*false\') then return "false" end' in setup_internal
    assert "true|false" not in setup_internal
    assert "local verification = verifyRuntimePaths(state)" in setup_internal
    assert "local adjustedErrors = {}" in setup_internal
    assert "local canAcceptRocm7Torch210 = (" in setup_internal
    assert "removeError(\"torch_runtime_probe_failed\")" in setup_internal
    assert "removeError(\"torch_runtime_unsupported\")" in setup_internal
    assert "removeError(\"torchaudio_missing_for_demucs\")" in setup_internal
    assert "local verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #adjustedErrors == 0" in setup_internal
    assert "writeCapabilities(capFile, {" in setup_internal
    assert "verification = verifiedRuntimeOk and \"ok\" or \"failed\"" in setup_internal
    assert "torchVersion = checkProbe.torchVersion" in setup_internal
    assert "torchaudioVersion = checkProbe.torchaudioVersion" in setup_internal
    assert "runtimeDriftDetected = checkProbe.runtimeDriftDetected" in setup_internal
    assert "runtimeDriftDetected = runtimeDriftDetected" in setup_internal
    assert "runtimeDriftReason = runtimeDriftReason" in setup_internal
    assert "updateBootstrapEnv(stateFile, {" in setup_internal


def test_post_bootstrap_trusts_verified_bootstrap_log_over_stale_probe_failures():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local function hasBootstrapRuntimeVerificationPass()" in setup_internal
    assert 'text:find("Runtime verification passed.", 1, true)' in setup_internal
    assert 'text:find("Pinned runtime assertion passed", 1, true)' in setup_internal
    assert "local authoritativeBootstrapVerified = (" in setup_internal
    assert "trim(state.STATUS or \"\") == \"ok\"" in setup_internal
    assert "local effectiveBootstrapSuccess = bootstrapSuccess or verifiedRuntimeOk or authoritativeBootstrapVerified" in setup_internal
    assert "runtimeDriftDetected = \"no\"" in setup_internal
    assert "runtimeDriftReason = \"\"" in setup_internal
    assert "runtimeVerifyDetail = resolvedRuntimeVerifyDetail" in setup_internal
    assert "status = (verificationSuccess or authoritativeBootstrapVerified) and \"ok\" or (state.STATUS or \"\")" in setup_internal
    assert "verification = (verificationSuccess or authoritativeBootstrapVerified) and \"ok\" or verificationStatus" in setup_internal
    assert "audioSeparator = (verificationSuccess or authoritativeBootstrapVerified) and \"ok\" or audioStatus" in setup_internal
    assert "stemwerkCore = (verificationSuccess or authoritativeBootstrapVerified) and \"ok\" or coreStatus" in setup_internal


def test_verify_only_accepts_intel_macos_cpu_fallback_when_imports_and_paths_are_ok():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "function reconcileCheckVerification(state, verification, envJson, deviceNames, backend, backendReason, logFile)" in setup_internal
    assert "local canAcceptMacIntelCpuFallback = (" in setup_internal
    assert 'OS == "macOS"' in setup_internal
    assert 'MAC_ARCH == "x86_64"' in setup_internal
    assert 'and backend == "cpu"' in setup_internal
    assert "and mpsInformational" in setup_internal
    assert "and verification.pythonOk" in setup_internal
    assert "and verification.ffmpegOk" in setup_internal
    assert "and torchVersionPinnedCompatible(torchVersion)" in setup_internal
    assert 'and torchaudioVersion ~= ""' in setup_internal


def test_verify_only_keeps_mps_unavailable_as_informational_reason_for_intel_macos():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local mpsInformational = (" in setup_internal
    assert 'trim(backendReason or "") == "mps_unavailable"' in setup_internal
    assert "backendReason = backendReason" in setup_internal


def test_verify_only_avoids_torch_runtime_unsupported_for_verified_intel_macos_cpu_fallback():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "if canAcceptMacIntelCpuFallback or bootstrapVerified then" in setup_internal
    assert 'removeError("torch_runtime_unsupported")' in setup_internal
    assert 'removeError("torch_runtime_probe_failed")' in setup_internal
    assert 'result.runtimeVerifyDetail = "ok"' in setup_internal


def test_verify_only_normalizes_state_before_bootstrap_check_rows():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'if verifiedRuntimeOk then\n        state.STATUS = "ok"' in setup_internal
    assert setup_internal.index('local stateStatus = state.STATUS or ""') > setup_internal.index("if verifiedRuntimeOk then")
    assert setup_internal.index("local checks = {") > setup_internal.index('local stateStatus = state.STATUS or ""')


def test_verify_only_intel_macos_cpu_fallback_does_not_hide_real_missing_torch_failures():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local hasHardImportFailures = (" in setup_internal
    assert 'hasError("audio_separator_missing")' in setup_internal
    assert 'hasError("stemwerk_core_missing")' in setup_internal
    assert "and not hasHardImportFailures" in setup_internal


def test_setup_open_capabilities_uses_dedicated_reveal_helper_and_safe_quoting():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "function openCapabilitiesPath(path)" in setup_internal
    assert 'tryExec("open -R " .. quoteArg(capPath) .. " >/dev/null 2>&1 &")' in setup_internal
    assert 'msgBox("STEMwerk Setup", "Capabilities file not found:\\n\\n" .. tostring(capPath), 0)' in setup_internal
    assert "openCapabilitiesPath(LINUX_SETUP.capFile)" in setup_internal


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


def test_rebuild_venv_canonicalization_rejects_crash_text_as_path():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "function stemwerkSetupCanonicalOutputToPath(out)" in script
    assert 'lower:find("terminate called", 1, true)' in script
    assert 'lower:find("traceback", 1, true)' in script
    assert 'lower:find("error", 1, true)' in script
    assert 'return nil, "canonical_multiline_output"' in script
    assert 'return nil, "canonical_not_absolute"' in script
    assert "function stemwerkSetupDirectShellCapture(cmd)" in script
    assert 'return nil, canonErr or "canonical_invalid_output"' in script


def test_rebuild_venv_safety_reports_canonical_failure_without_using_raw_output_as_path():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "Could not verify runtime path safety. Rebuild was blocked." in script
    assert '"Reason: " .. tostring(venvReason or "path_safety")' in script
    assert '"Canonical target: " .. tostring(venvCanon or "(unresolved)")' in script
    assert '"Canonical expected: " .. tostring(expectedVenvCanon or "(unresolved)")' in script
    assert "terminate called without an active exception/.venv" not in script


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


def test_linux_torch_stack_install_propagates_pip_failures_before_runtime_pins():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "_pip_rc=1" in script
    assert "_pip_rc=$?" in script
    assert 'if [ "${_pip_rc}" -ne 0 ]; then' in script
    assert 'log_step "${_mode} torch pip install failed with exit code ${_pip_rc}"' in script
    assert 'return 1' in script[
        script.index('if [ "${_pip_rc}" -ne 0 ]; then') :
        script.index("enforce_runtime_python_pins")
    ]
    assert script.index('if [ "${_pip_rc}" -ne 0 ]; then') < script.index("enforce_runtime_python_pins")


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
    assert "if ! verify_audio_separator_runtime_deps; then" in mac_script
    assert 'set_status "deps_failed" "audio_separator_install_failed"' in mac_script
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
    assert "../../installer/linux/payload/wheels/linux-x86_64-cp312" in script
    assert '"${RUNTIME_BASE}/wheels/linux-x86_64-cp312"' in script
    assert '"${RUNTIME_BASE}/cache/wheels"' in script
    assert '"${VENV_PY}" -m pip install --no-deps "${diffq_wheel}"' in script
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


def test_linux_managed_diffq_install_does_not_resolve_cython_or_build_deps():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert '"${VENV_PY}" -m pip install --no-deps "${diffq_wheel}"' in script
    assert "--find-links" not in script.split("install_managed_diffq_wheel()", 1)[1].split("clear_stale_python_backend_reason()", 1)[0]
    assert "--only-binary=:all:" not in script.split("install_managed_diffq_wheel()", 1)[1].split("clear_stale_python_backend_reason()", 1)[0]


def test_linux_managed_ffmpeg_fallback_installs_when_system_ffmpeg_missing():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'PINNED_IMAGEIO_FFMPEG_VERSION="0.6.0"' in script
    assert "install_managed_ffmpeg()" in script
    assert "resolve_managed_ffmpeg_from_venv()" in script
    assert 'imageio-ffmpeg==${PINNED_IMAGEIO_FFMPEG_VERSION}' in script
    assert 'log_step "System FFmpeg missing; installing managed FFmpeg runtime (imageio-ffmpeg==${PINNED_IMAGEIO_FFMPEG_VERSION})"' in script
    assert 'log_step "Using managed FFmpeg from Python runtime: ${FFMPEG}"' in script


def test_linux_managed_ffmpeg_missing_path_still_fails_safely():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'managed_ffmpeg="$(resolve_managed_ffmpeg_from_venv || true)"' in script
    assert 'if [ -n "${managed_ffmpeg}" ] && [ -x "${managed_ffmpeg}" ]; then' in script
    assert 'set_status "missing_ffmpeg" "ffmpeg_not_found"' in script


def test_runtime_launcher_exports_managed_ffmpeg_for_unix_processing():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'local ffmpegPath = FFMPEG_PATH or getExtStateValue("ffmpegPath") or getExtStateValue("FFMPEG_PATH")' in script
    assert 'script:write("STEMWERK_FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\\n")' in script
    assert 'script:write("FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\\n")' in script
    assert 'script:write("IMAGEIO_FFMPEG_EXE=" .. quoteArg(ffmpegPath) .. "\\n")' in script
    assert 'script:write("export STEMWERK_FFMPEG_PATH FFMPEG_PATH IMAGEIO_FFMPEG_EXE\\n")' in script
    assert 'script:write("PATH=\\"$FFMPEG_DIR:${PATH}\\"\\n")' in script


def test_audio_separator_process_consumes_managed_ffmpeg_env_and_reports_it():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()

    assert 'for env_key in ("STEMWERK_FFMPEG_PATH", "FFMPEG_PATH", "IMAGEIO_FFMPEG_EXE")' in script
    assert "def _runtime_base_candidates() -> List[Path]:" in script
    assert 'add(Path.home() / ".local" / "share" / "STEMwerk")' in script
    assert 'bootstrap_values = _read_simple_env_file(runtime_base / "state" / "bootstrap.env")' in script
    assert 'add(bootstrap_values.get("FFMPEG_PATH"))' in script
    assert 'add(bootstrap_values.get("FFMPEG"))' in script
    assert 'add(bootstrap_values.get("MANAGED_FFMPEG_PATH"))' in script
    assert 'capabilities_values = _read_simple_env_file(runtime_base / "state" / "capabilities.env")' in script
    assert 'add(capabilities_values.get("FFMPEG_PATH"))' in script
    assert 'add(capabilities_values.get("FFMPEG"))' in script
    assert 'add(capabilities_values.get("MANAGED_FFMPEG_PATH"))' in script
    assert "def _ensure_runtime_ffmpeg_wrapper(runtime_base: Path, ffmpeg_path: Path) -> Optional[Path]:" in script
    assert "wrapper_path = wrapper_dir / \"ffmpeg\"" in script
    assert "os.symlink(target, wrapper_path)" in script
    assert "exec " in script and '\\"$@\\"' in script
    assert 'os.environ["PATH"] = path_value + (os.pathsep + current_path if current_path else "")' in script
    assert "ffmpeg_path, ffmpeg_wrapper, ffmpeg_path_prefix = _configure_ffmpeg_runtime()" in script
    assert 'os.environ["STEMWERK_FFMPEG_PATH"] = candidate_str' in script
    assert 'os.environ["IMAGEIO_FFMPEG_EXE"] = candidate_str' in script
    assert 'print(f"STEMWERK_DIAG ffmpeg_path={ffmpeg_path}", file=sys.stderr)' in script
    assert "STEMWERK_DIAG ffmpeg_wrapper=" in script
    assert "ffmpeg_wrapper if ffmpeg_wrapper is not None else 'none'" in script
    assert "STEMWERK_DIAG path_prefix=" in script
    assert "ffmpeg_path_prefix if ffmpeg_path_prefix else 'none'" in script
    assert 'print("STEMWERK_DIAG ffmpeg_path=NOT_FOUND", file=sys.stderr)' in script


def test_audio_separator_process_enables_torch26_demucs_checkpoint_compatibility():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()

    assert "def _enable_torch_weights_only_compat(model_name: str, selected_device: str) -> bool:" in script
    assert 'if not _is_demucs_model(model_name):' in script
    assert 'if major < 2 or (major == 2 and minor < 6):' in script
    assert 'os.environ["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"' in script
    assert "STEMWERK_DIAG torch_weights_only_compat=enabled mode=TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD" in script
    assert "_enable_torch_weights_only_compat(run_model, resolved_device)" in script


def test_drumkit_direct_dks_mode_wires_stage2_preflight_markers():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()
    _, after_direct_route = script.split("if _is_direct_dks_source(args.workflow_mode, args.workflow_source):", 1)

    assert 'parser.add_argument("--workflow-mode", default=""' in script
    assert 'parser.add_argument("--workflow-source", default=""' in script
    assert 'parser.add_argument("--requested-stage2-model", default=""' in script
    assert "if _is_direct_dks_source(args.workflow_mode, args.workflow_source):" in script
    assert 'emit_phase("stage2_preflight")' in script
    assert "DIRECT_DKS_MODEL_ALIAS = \"MDX23C-DrumSep-aufr33-jarredou.ckpt\"" in script
    assert "DIRECT_DKS_MODEL_FILENAME = \"aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt\"" in script
    assert "def _resolve_direct_dks_model_catalog_entry(requested_model: str, model_cache_dir: Path)" in script
    assert "catalog_paths_checked=" in script
    assert "catalog_lookup_status=" in script
    assert "resolved_default = DIRECT_DKS_MODEL_FILENAME" in script
    assert "other_network_list_new" in script
    assert "def _ensure_runtime_download_checks_has_drumsep(" in script
    assert "mdx23c_download_list" in script
    assert "def _download_direct_dks_assets(" in script
    assert "def _is_known_drumsep_runtime_unsupported_error(exc: Exception, traceback_text: str, model_name: str) -> bool:" in script
    assert "def _emit_direct_dks_runtime_unsupported_markers(" in script
    assert 'print("error_stage=stage2_model_load", file=sys.stderr)' in script
    assert 'print("error_reason=drumsep_model_runtime_unsupported", file=sys.stderr)' in script
    assert "audio_separator mdxc loader missing expected config field 'model'" in script
    assert "sep.download_model_files(resolved_model)" in script
    assert "resolved_model=" in script
    assert "Direct Drum Kit Split route detected: workflow_mode=" in script
    assert "workflow_source=" in script
    assert "DRUMSEP_RUNTIME_DIRNAME = \".venv-drumsep\"" in script
    assert "DRUMSEP_RUNTIME_ROCM_DIRNAME = \".venv-drumsep-rocm\"" in script
    assert "DRUMSEP_RUNTIME_GUIDANCE = \"Run Setup/Repair Drum Kit Split runtime.\"" in script
    assert "def _drumsep_runtime_python_path(" in script
    assert "def _drumsep_rocm_runtime_python_path(" in script
    assert "def _verify_drumsep_runtime(" in script
    assert "def _select_drumsep_runtime(" in script
    assert "def _run_direct_dks_drumsep_helper(" in script
    assert "stemwerk_drumsep_process.py" in script
    assert "drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime(device_preference)" in script
    assert "reason = \"drumsep_runtime_missing\" if runtime_kind == \"missing\" else \"drumsep_runtime_broken\"" in script
    assert "_emit_direct_dks_stage2_runtime_markers(reason, runtime_path, json.dumps(runtime_info, sort_keys=True))" in script
    assert "drumsep_runtime_selected=" in script
    assert "drumsep_runtime_fallback_reason=" in script
    assert "helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(" in script
    assert "drumsep_helper_python=" in script
    assert "drumsep_helper_ok=true" in script
    assert "_direct_dks_preflight_check(run_model, model_cache_dir)" in script
    assert script.index("drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime(device_preference)") < script.index("_direct_dks_preflight_check(run_model, model_cache_dir)")
    assert "drumsep_runtime_selection_policy=explicit_cpu" in script
    assert 'selection_policy = "gpu_prefer_rocm" if normalized_request == "gpu" else "auto_prefer_rocm"' in script
    assert "normalized_device_request=" in script
    assert 'info["selection_policy"] = "fallback_cpu"' in script
    assert after_direct_route.index("_direct_dks_preflight_check(run_model, model_cache_dir)") < after_direct_route.index("helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(")
    assert 'print("error_stage=stage2_preflight", file=sys.stderr)' in script
    assert 'print(f"error_reason={reason}", file=sys.stderr)' in script
    assert 'print(f"requested_model={requested_model}", file=sys.stderr)' in script
    assert 'print(f"Direct Drum Kit Split preflight failed: {reason}", file=sys.stderr)' in script
    assert "drumsep_model_download_failed" in script
    assert "known_err_text.startswith(\"catalog_\")" in script
    assert 'known_err_text.startswith("unsupported_")' in script
    assert "if not ok:" in script
    assert 'emit_phase("model_setup_start")' in script
    assert '_is_direct_dks_source(getattr(args, "workflow_mode", ""), getattr(args, "workflow_source", ""))' in script


def test_drumkit_extract_route_runs_normal_stage1_before_drumsep_stage2():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")
    helper_script = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py").read_text(encoding="utf-8")
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")

    assert 'def _is_extract_dks_source(workflow_mode: Optional[str], workflow_source: Optional[str]) -> bool:' in script
    assert 'return mode == "drumkit" and source == "dks_extract"' in script
    assert "if _is_extract_dks_source(args.workflow_mode, args.workflow_source):" in script
    assert 'stage1_root = output_root / "stage1_normal"' in script
    assert 'stage2_root = output_root / "stage2_drumsep"' in script
    assert "stage1_model = run_model" in script
    assert 'stage1_result = stage1_sep.separate(args.input, str(stage1_root), stems=["drums"])' in script
    assert 'drums_input = Path(stage1_stems.get("drums", stage1_root / "drums.wav")).resolve()' in script
    assert "dks_extract_stage1_runtime=normal" in script
    assert "dks_extract_stage1_device=" in script
    assert "dks_extract_stage1_output=" in script
    assert "dks_extract_stage2_runtime=drumsep" in script
    assert "dks_extract_stage2_device=" in script
    assert "dks_extract_stage2_backend=" in script
    assert "dks_extract_stage2_requested_device=" in script
    assert "STEMWERK_BENCH_DKS_STAGE2_CAP" in script
    assert "bench_dks_stage2_cap_requested=" in script
    assert "bench_dks_stage2_cap_applied=" in script
    assert "bench_dks_stage2_cap_ignored_reason=" in script
    assert "dks_extract_stage2_effective_cap=" in script
    assert "DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 1" in script
    assert 'def _dks_extract_stage2_lock(output_root: Path, stage2_backend: str = ""):' in script
    assert "stage2_backend = _detect_dks_extract_stage2_backend(runtime_kind, runtime_info, drumsep_python)" in script
    assert "with _dks_extract_stage2_lock(output_root, stage2_backend):" in script
    assert "lua_dks_extract_stage2_concurrency_cap=" in script
    assert "lua_dks_extract_stage2_queue_wait_start" in script
    assert "lua_dks_extract_stage2_queue_wait_end wait_seconds=" in script
    assert "dks_extract_stage2_throttled=yes" in script
    assert "expected_drum_outputs=" in helper_script
    assert "actual_drum_outputs=" in helper_script
    assert "output_count_mismatch=yes" in helper_script
    assert 'dst = output_root / src.name' in script
    assert "_direct_dks_preflight_check(requested_stage2_model, model_cache_dir)" in script
    assert "requested_stage2_model = _resolve_requested_stage2_model(args)" in script
    assert "known_err_text.startswith(\"unsupported_\")" in script
    assert "print(json.dumps(final_stems))" in script
    assert "workflow_source=dks_extract" not in support_script
    assert '"dks_extract_stage1_runtime", "dks_extract_stage1_requested_device"' in support_script
    assert '"dks_extract_stage2_requested_device", "dks_extract_stage2_device", "dks_extract_stage2_backend"' in support_script
    assert '"dks_extract_stage2_effective_cap", "bench_dks_stage2_cap_requested", "bench_dks_stage2_cap_applied",' in support_script
    assert '"bench_dks_stage2_cap_ignored_reason", "dks_extract_intermediate_dir"' in support_script
    assert '"lua_dks_extract_outputs_detected", "lua_dks_extract_output_count"' in support_script
    assert '"expected_drum_outputs", "actual_drum_outputs", "output_count_mismatch"' in support_script


def test_drumkit_stage2_benchmark_cap_parser_accepts_only_allowed_values_and_respects_backend_safety(monkeypatch):
    module = _load_audio_separator_process_module()

    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    assert module._read_benchmark_dks_stage2_cap_request() == (None, "unset")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (None, "unset", 1, "not_requested")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "2")
    assert module._read_benchmark_dks_stage2_cap_request() == (2, "2")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (2, "2", 2, "")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cpu") == (2, "2", 1, "backend_not_rocm_cuda")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "4")
    assert module._read_benchmark_dks_stage2_cap_request() == (4, "4")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cuda") == (4, "4", 4, "")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "8")
    assert module._read_benchmark_dks_stage2_cap_request() == (None, "8")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (None, "8", 1, "invalid_request")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "1")
    assert module._read_benchmark_dks_stage2_cap_request() == (1, "1")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cpu") == (1, "1", 1, "")


def test_drumkit_stage2_backend_detection_prefers_selected_runtime_markers_over_parent_executable():
    module = _load_audio_separator_process_module()

    assert module._detect_dks_extract_stage2_backend(
        "rocm",
        {"kind": "cpu", "versions": {"torch": "2.12.0+cu130"}, "torch_hip": ""},
    ) == "rocm"
    assert module._detect_dks_extract_stage2_backend(
        "",
        {"kind": "rocm", "versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4"},
    ) == "rocm"
    assert module._detect_dks_extract_stage2_backend(
        "",
        {"versions": {"torch": "2.12.0+cu130"}, "torch_cuda_available": True, "torch_hip": ""},
    ) == "cuda"
    assert module._detect_dks_extract_stage2_backend(
        "",
        {"kind": "cpu", "versions": {"torch": "2.12.0+cpu"}, "torch_cuda_available": False, "torch_hip": ""},
    ) == "cpu"


def test_dks_extract_stage2_lock_uses_explicit_runtime_backend_for_benchmark_cap(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "2")

    with module._dks_extract_stage2_lock(tmp_path, "rocm"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_cap_requested=2" in captured.err
    assert "bench_dks_stage2_cap_applied=2" in captured.err
    assert "bench_dks_stage2_cap_ignored_reason=" in captured.err
    assert "dks_extract_stage2_backend=rocm" in captured.err

    with module._dks_extract_stage2_lock(tmp_path, "cpu"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_cap_applied=1" in captured.err
    assert "bench_dks_stage2_cap_ignored_reason=backend_not_rocm_cuda" in captured.err
    assert "dks_extract_stage2_backend=cpu" in captured.err


def test_benchmark_resource_sampler_code_path_exposes_expected_files_and_graceful_rocm_fallback(monkeypatch):
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")
    module = _load_audio_separator_process_module()

    assert "class BenchmarkResourceSampler" in script
    assert "benchmark_resource_samples.jsonl" in script
    assert "benchmark_resource_summary.json" in script
    assert "benchmark_resource_summary.txt" in script
    assert "_benchmark_resource_sampling_requested()" in script
    assert "resource_sampling_available" in script
    assert "resource_sampling_reason" in script
    assert "_collect_rocm_smi_metrics()" in script
    assert "_collect_nvidia_smi_metrics()" in script
    assert '"rocm-smi_missing"' in script
    assert '"benchmark_resource_samples.jsonl"] = true' in support_script
    assert '"benchmark_resource_summary.json"] = true' in support_script
    assert '"benchmark_resource_summary.txt"] = true' in support_script

    monkeypatch.delenv("STEMWERK_BENCH_GPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_RESOURCE_SAMPLING", raising=False)
    assert module._benchmark_resource_sampling_requested() is False
    monkeypatch.setenv("STEMWERK_BENCH_GPU_CAP", "4")
    assert module._benchmark_resource_sampling_requested() is True
    monkeypatch.delenv("STEMWERK_BENCH_GPU_CAP", raising=False)
    monkeypatch.setenv("STEMWERK_BENCH_RESOURCE_SAMPLING", "1")
    assert module._benchmark_resource_sampling_requested() is True

    monkeypatch.setattr(module.shutil, "which", lambda name: None)
    metrics, available, reason, detail = module._collect_rocm_smi_metrics()
    assert available is False
    assert reason == "rocm-smi_missing"
    assert metrics == {}
    assert "not found" in detail


def test_drumkit_extract_stage2_uses_requested_drumsep_model_not_stage1_demucs_model():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "def _resolve_requested_stage2_model(args: argparse.Namespace) -> str:" in script
    assert "return DIRECT_DKS_MODEL_ALIAS" in script
    assert "requested_stage2_model = _resolve_requested_stage2_model(args)" in script
    assert "_direct_dks_preflight_check(requested_stage2_model, model_cache_dir)" in script
    assert "_emit_direct_dks_preflight_markers(reason, requested_model or requested_stage2_model, resolved_model or \"\", str(known_err or \"\"))" in script


def test_drumsep_runtime_verify_and_helper_use_clean_subprocess_env():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "env=_clean_env()," in script
    assert script.count("env=_clean_env(),") >= 2


def test_single_workflow_accepts_dks_extract_stdout_json_and_logs_import_markers():
    workflow = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")
    main = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "local function collectStemPathsFromStdoutJson(stdoutFile)" in workflow
    assert 'if key == "hihat" or key == "hihat" or key == "hh" then' in workflow
    assert 'trimmed:find(\'"%s*:%s*"\', 1)' in workflow
    assert 'local stdoutStems = collectStemPathsFromStdoutJson(C.progressState.stdoutFile)' in workflow
    assert 'debugLog("lua_result_probe_start")' in workflow
    assert 'debugLog("lua_result_probe_stdout_json_attempt=yes")' in workflow
    assert 'debugLog("lua_result_probe_stdout_json_ok=yes")' in workflow
    assert 'debugLog("lua_result_probe_stdout_json_count=" .. tostring(outputCount))' in workflow
    assert 'debugLog("lua_dks_extract_outputs_detected=yes")' in workflow
    assert 'SW_LOG.logExecResult("lua_dks_extract_outputs_detected=yes", nil, "lua_dks_extract_output_count=" .. tostring(outputCount))' in workflow
    assert 'SW_LOG.logExecResult("lua_dks_extract_import_start", nil, "")' in workflow
    assert 'SW_LOG.logExecResult("lua_dks_extract_import_end", nil, "")' in workflow
    assert 'SW_LOG.logExecResult("lua_dks_extract_import_candidate_count=" .. tostring(selectedCount), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_extract_import_selected_count=" .. tostring(selectedImportCount), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_extract_import_created=" .. tostring(importedCount), nil, "")' in main
    assert '"import_stem_key=" .. tostring(stemKey)' in main
    assert "local function buildTakeImportStemEntries(stemPaths)" in workflow
    assert "C.resolveStemSetForPaths(sourcePaths)" in workflow
    assert "local stemEntries = buildTakeImportStemEntries(stemPaths)" in workflow
    assert "return 0, item" in workflow
    assert "resolveStemSetForPaths        = resolveStemSetForPaths" in main
    assert 'SW_LOG.logExecResult("lua_dks_single_in_place_import_created=0", nil, "lua_dks_single_in_place_no_takes_reason=drum_output_map_not_imported")' in main
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")
    assert '"lua_dks_extract_import_candidate_count",' in support_script
    assert '"lua_dks_extract_import_selected_count", "lua_dks_extract_import_created"' in support_script
    assert '"lua_dks_single_in_place_import_created"' in support_script
    assert '"lua_dks_single_in_place_no_takes_reason"' in support_script


def test_dks_multi_workers_preserve_workflow_args_and_import_drum_json_outputs():
    main = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")

    assert 'multiTrackQueue.workflowMode = workflowModeArg' in main
    assert 'multiTrackQueue.workflowSource = workflowSourceArg' in main
    assert 'multiTrackQueue.requestedStage2Model = requestedStage2ModelArg' in main
    assert 'job.workflowMode = workflowModeArg' in main
    assert 'job.workflowSource = workflowSourceArg' in main
    assert 'job.requestedStage2Model = requestedStage2ModelArg' in main
    assert 'pythonCmd = pythonCmd .. " --workflow-mode " .. quoteArg(workflowModeArg)' in main
    assert 'pythonCmd = pythonCmd .. " --workflow-source " .. quoteArg(workflowSourceArg)' in main
    assert 'pythonCmd = pythonCmd .. " --requested-stage2-model " .. quoteArg(requestedStage2ModelArg)' in main
    assert 'script:write("WORKFLOW_MODE=" .. quoteArg(workflowModeArg) .. "\\n")' in main
    assert 'script:write(\'  if [ -n "$WORKFLOW_SOURCE" ]; then set -- "$@" --workflow-source "$WORKFLOW_SOURCE"; fi\\n\')' in main
    assert 'local stdoutStems = collectStemPathsFromStdoutJson(job.stdoutFile)' in main
    assert 'local stemSetForJob = isDrumKitJob and DRUMKIT_STEMS or STEMS' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_stdout_json_ok=yes", nil, "lua_dks_multi_output_count=" .. tostring(stdoutCount))' in main
    assert 'job.expectedOutputCount = expectedOutputCount' in main
    assert 'job.detectedOutputCount = foundCount' in main
    assert 'job.workerExitCode = SW_LOG.readExitCode(job.exitCodeFile)' in main
    assert 'job.importedOutputCount = count' in main
    assert 'local ok = expected > 0 and imported >= expected and detected >= expected and exitCode == 0' in main
    assert 'multiTrackQueue.dksResultStatus = status' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_expected_total_outputs=" .. tostring(expected), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_successful_jobs=" .. tostring(dksSuccessfulJobs), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_failed_jobs=" .. tostring(dksFailedJobs), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_failed_job_indices=" .. tostring(multiTrackQueue.dksFailedJobIndices), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_partial_success=" .. (status == "partial" and "yes" or "no"), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_result_status=" .. tostring(status), nil, "")' in main
    assert 'SW_LOG.logExecResult("lua_dks_multi_import_total_created=" .. tostring(totalStemsCreated), nil, "")' in main
    assert 'lua_dks_multi_no_stems_reason=zero_imported_after_worker_completion' in main
    assert 'resultData.resultStatus = multiTrackQueue.dksResultStatus or "success"' in main
    assert 'trSafeValue("dks_multi_partial_takes", "%d of %d items processed; %d of %d drum takes created.")' in main
    assert 'trSafeValue("dks_multi_partial_created", "%d of %d sources processed; %d of %d drum outputs created.")' in main

    log_script = Path("scripts/reaper/_internal/STEMwerk_Log.lua").read_text(encoding="utf-8")
    assert '"stage2_drumsep" .. sep .. "drumsep_helper_stdout.txt"' in log_script
    assert '"stage2_drumsep" .. sep .. "drumsep_helper_stderr.txt"' in log_script
    assert '"stage2_drumsep" .. sep .. "drumsep_helper_result.json"' in log_script
    assert '"stage2_drumsep" .. sep .. "drumsep_result.json"' in log_script
    assert '"benchmark_resource_samples.jsonl"' in log_script
    assert '"benchmark_resource_summary.json"' in log_script
    assert '"benchmark_resource_summary.txt"' in log_script
    assert "function SW_LOG.writeRunRootArtifact(outputDir, relativePath, content)" in log_script
    assert 'reason == "partial_dks_multi"' in log_script
    assert 'error_class = tostring(opts.errorClass or dksReason)' in log_script
    assert 'lines[#lines + 1] = "failed_jobs: " .. tostring(opts.failedJobIndices)' in log_script
    assert 'lines[#lines + 1] = "expected_outputs: " .. tostring(opts.expectedOutputs)' in log_script
    assert 'lines[#lines + 1] = "created_outputs: " .. tostring(opts.createdOutputs)' in log_script

    assert '"lua_dks_multi_start", "lua_dks_multi_workflow_source", "lua_dks_multi_source_count",' in support_script
    assert '"lua_dks_multi_output_count", "lua_dks_multi_import_created", "lua_dks_multi_import_total_created",' in support_script
    assert '"scheduler_policy_route", "scheduler_policy_stage", "scheduler_policy_backend",' in support_script
    assert '"lua_dks_scheduler_policy_route", "lua_dks_scheduler_policy_stage", "lua_dks_scheduler_policy_cap",' in support_script
    assert '"lua_dks_extract_stage2_concurrency_cap", "lua_dks_extract_stage2_queue_wait_start",' in support_script
    assert '"lua_dks_extract_stage2_queue_wait_end", "dks_extract_stage2_throttled",' in support_script
    assert 'for i = 1, math.min(8, #runDirs) do' in support_script
    assert 'for i = 1, math.min(8, #tempRuns) do' in support_script
    assert 'local maxRunsToInclude = 8' in support_script
    assert 'joinPath("stage2_drumsep", "drumsep_helper_stdout.txt")' in support_script
    assert 'joinPath("stage2_drumsep", "drumsep_helper_stderr.txt")' in support_script
    assert 'joinPath("stage2_drumsep", "drumsep_result.json")' in support_script


def test_support_bundle_excludes_dev_matrix_temp_dirs_and_reports_temp_log_budget():
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")

    assert 'if lower:match("^stemwerk[_%-]mdxc[_%-]matrix") then' in script
    assert 'if lower:match("^stemwerk%-slice%-") then' in script
    assert 'appendKey(diagnostics, "support_bundle_temp_logs_count", tostring((tempMeta and tempMeta.copiedCount) or 0))' in script
    assert 'appendKey(diagnostics, "support_bundle_temp_logs_bytes", tostring((tempMeta and tempMeta.copiedBytes) or 0))' in script
    assert 'local drumsepDiagnosticsStartedAt = phaseStart("collect_drumsep_runtime")' in script
    assert 'phaseDone("collect_drumsep_runtime", drumsepDiagnosticsStartedAt)' in script
    assert 'appendKey(diagnostics, "collect_drumsep_runtime", string.format("%.3f", phaseTimings.collect_drumsep_runtime or 0))' in script
    assert 'local phaseTimingsWall = {}' in script
    assert '"cpu_elapsed=%.3f wall_elapsed=%d"' in script
    assert '"cpu_duration=%.3f wall_duration=%d"' in script
    assert 'appendKey(diagnostics, "collect_drumsep_runtime_wall", tostring(phaseTimingsWall.collect_drumsep_runtime or 0))' in script
    assert 'appendKey(lines, "collect_drumsep_runtime_source", "cached")' in script
    assert 'appendKey(lines, "collect_drumsep_runtime_live_probe", "skipped")' in script
    assert 'local cpuProbe = nil' in script
    assert 'local rocmProbe = nil' in script
    assert 'kvAssignLast(entry, "error_reason", "partial_dks_multi")' in script
    assert 'setRunResult(entry, "partial", 6)' in script


def test_drumsep_runtime_missing_is_detected_before_stage2_model_load(tmp_path, capsys):
    module = _load_audio_separator_process_module()
    missing_python = tmp_path / ".venv-drumsep" / "bin" / "python"

    ok, detail, _payload = module._verify_drumsep_runtime(missing_python)
    module._emit_direct_dks_stage2_runtime_markers("drumsep_runtime_missing", missing_python, detail)

    captured = capsys.readouterr()
    assert ok is False
    assert detail == "missing"
    assert "error_stage=stage2_runtime" in captured.err
    assert "error_reason=drumsep_runtime_missing" in captured.err
    assert "guidance=Run Setup/Repair Drum Kit Split runtime." in captured.err
    assert "stage2_model_load" not in captured.err


def test_drumsep_runtime_broken_reports_import_error(tmp_path):
    module = _load_audio_separator_process_module()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True)
    runtime_python.write_text("#!/bin/sh\necho 'ImportError: audio_separator missing' >&2\nexit 1\n", encoding="utf-8")
    runtime_python.chmod(0o755)

    ok, detail, _payload = module._verify_drumsep_runtime(runtime_python)

    assert ok is False
    assert "ImportError: audio_separator missing" in detail


def test_drumsep_runtime_selector_prefers_rocm_when_gpu_capable(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    rocm_python = base / ".venv-drumsep-rocm" / "bin" / "python"
    cpu_python = base / ".venv-drumsep" / "bin" / "python"
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False):
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == rocm_python
    assert kind == "rocm"
    assert info["torch_hip"] == "6.4"
    assert info["selection_policy"] == "auto_prefer_rocm"


def test_drumsep_runtime_selector_falls_back_to_cpu_when_rocm_invalid(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    rocm_python = base / ".venv-drumsep-rocm" / "bin" / "python"
    cpu_python = base / ".venv-drumsep" / "bin" / "python"
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False):
        if "drumsep-rocm" in str(path):
            return (False, "rocm_no_hip", {})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == cpu_python
    assert kind == "cpu"
    assert info["fallback_reason"] == "rocm_skipped:rocm_no_hip"
    assert info["selection_policy"] == "fallback_cpu"


def test_drumsep_runtime_selector_respects_explicit_cpu_even_when_rocm_valid(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    rocm_python = base / ".venv-drumsep-rocm" / "bin" / "python"
    cpu_python = base / ".venv-drumsep" / "bin" / "python"
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False):
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    verify_calls = []
    def fake_verify_with_calls(path, require_gpu=False):
        verify_calls.append((str(path), require_gpu))
        return fake_verify(path, require_gpu=require_gpu)

    module._verify_drumsep_runtime = fake_verify_with_calls
    selected, kind, info = module._select_drumsep_runtime("cpu", base)
    assert selected == cpu_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu"
    assert info["fallback_reason"] == ""
    assert all("drumsep-rocm" not in p for p, _ in verify_calls)
    assert verify_calls and verify_calls[0][1] is False


def test_drumsep_runtime_selector_treats_gpu_request_as_rocm_preferred(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    rocm_python = base / ".venv-drumsep-rocm" / "bin" / "python"
    cpu_python = base / ".venv-drumsep" / "bin" / "python"
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False):
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("cuda:0", base)
    assert selected == rocm_python
    assert kind == "rocm"
    assert info["selection_policy"] == "gpu_prefer_rocm"


def test_drumsep_runtime_selector_reports_missing_when_both_absent(tmp_path):
    module = _load_audio_separator_process_module()
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)
    assert selected is None
    assert kind == "missing"
    assert info["rocm_detail"] == "missing"
    assert info["cpu_detail"] == "missing"


def test_normal_stem_workflows_do_not_reference_drumsep_runtime():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()
    marker = 'if _is_direct_dks_source(args.workflow_mode, args.workflow_source):'
    assert marker in script
    _, after_direct_dks = script.split(marker, 1)

    assert "_select_drumsep_runtime(" in after_direct_dks
    assert after_direct_dks.index("_select_drumsep_runtime(") < after_direct_dks.index("_direct_dks_preflight_check(run_model, model_cache_dir)")
    assert after_direct_dks.index("_select_drumsep_runtime(") < after_direct_dks.index('emit_phase("model_setup_start")')
    assert after_direct_dks.index("helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(") < after_direct_dks.index('emit_phase("model_setup_start")')
    assert "_enable_torch_weights_only_compat(run_model, resolved_device)" in script


def test_drumkit_direct_dks_mode_wires_lua_launch_and_failure_mapping():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    workflow_script = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text()
    dks_script = Path("scripts/reaper/_internal/STEMwerk_DrumKit_Workflow.lua").read_text()

    assert 'local DKS_WORKFLOW = dofile(script_path .. "_internal/STEMwerk_DrumKit_Workflow.lua")' in main_script
    assert 'if (not trustedWindowsRuntime) and (not isDirectDKS) and (not ensureDependenciesInteractive()) then' in main_script
    assert "error_stage=stage2_preflight" in main_script
    assert "error_reason=drumsep_model_missing" in main_script
    assert "error_reason=drumsep_model_download_failed" in main_script
    assert "error_stage=stage2_runtime" in main_script
    assert "error_reason=drumsep_runtime_missing" in main_script
    assert "error_reason=drumsep_runtime_broken" in main_script
    assert "error_reason=drumsep_helper_failed" in main_script
    assert "error_reason=drumsep_model_load_failed" in main_script
    assert "error_reason=drumsep_separate_failed" in main_script
    assert "error_reason=drumsep_output_count_mismatch" in main_script
    assert 'file = "hi-hat.wav"' in main_script
    assert "activateWorkflowStemSet(isDirectDKS)" in main_script
    assert "Run Setup/Repair Drum Kit Split runtime." in main_script
    assert "error_stage=stage2_model_load" in main_script
    assert "error_reason=drumsep_model_runtime_unsupported" in main_script
    assert "not found in supported model files" in main_script
    assert "workflow%-source" in main_script
    assert 'WORKFLOW.runSeparationWithProgress(WORKFLOW_TEMP_INPUT, WORKFLOW_TEMP_DIR, workflowModel, runOptions)' in main_script
    assert 'pythonCmd = pythonCmd .. " --workflow-mode " .. C.quoteArg(workflowModeArg)' in workflow_script
    assert 'pythonCmd = pythonCmd .. " --workflow-source " .. C.quoteArg(workflowSourceArg)' in workflow_script
    assert 'pythonCmd = pythonCmd .. " --requested-stage2-model " .. C.quoteArg(requestedStage2ModelArg)' in workflow_script
    assert 'M.WORKFLOW_DRUMKIT = "drumkit"' in dks_script
    assert 'M.SOURCE_DIRECT = "dks_direct"' in dks_script
    assert 'M.DIRECT_DKS_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"' in dks_script


def test_linux_drumsep_runtime_installer_is_isolated_and_pinned():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'DRUMSEP_AUDIO_SEPARATOR_VERSION="0.34.1"' in script
    assert 'DRUMSEP_NUMPY_VERSION="2.4.6"' in script
    assert 'DRUMSEP_ONNXRUNTIME_VERSION="1.26.0"' in script
    assert 'DRUMSEP_ONNX_VERSION="1.21.0"' in script
    assert 'DRUMSEP_ONNX2TORCH_VERSION="1.5.15"' in script
    assert 'DRUMSEP_ONNX2TORCH_PY313_VERSION="1.6.0"' in script
    assert 'DRUMSEP_TORCH_VERSION="2.12.0"' in script
    assert 'DRUMSEP_TORCHVISION_VERSION="0.27.0"' in script
    assert 'DRUMSEP_NUMBA_VERSION="0.65.1"' in script
    assert 'printf "%s/.venv-drumsep/bin/python\\n" "${RUNTIME_BASE}"' in script
    assert '"${PYTHON}" -m venv "${RUNTIME_BASE}/.venv-drumsep"' in script
    assert '"${_drumsep_py}" -m pip install' in script
    assert '"audio-separator==${DRUMSEP_AUDIO_SEPARATOR_VERSION}"' in script
    assert '"numpy==${DRUMSEP_NUMPY_VERSION}"' in script
    assert '"torch==${DRUMSEP_TORCH_VERSION}"' in script
    assert "create_venv_with_selected_python" in script
    assert script.index('if [ "${MODE}" = "drumsep-runtime" ]; then') < script.index('log_stage "Creating venv"')


def test_linux_drumsep_runtime_state_fields_are_written():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    for field in (
        "DRUMSEP_RUNTIME_STATUS=",
        "DRUMSEP_PYTHON=",
        "DRUMSEP_AUDIO_SEPARATOR_VERSION=",
        "DRUMSEP_NUMPY_VERSION=",
        "DRUMSEP_TORCH_VERSION=",
        "DRUMSEP_ONNX_VERSION=",
        "DRUMSEP_ONNXRUNTIME_VERSION=",
        "DRUMSEP_ONNX2TORCH_VERSION=",
        "DRUMSEP_LAST_CHECK_UTC=",
        "DRUMSEP_MODEL_STATUS=",
        "DRUMSEP_MODEL_FILE=",
        "DRUMSEP_MODEL_YAML=",
    ):
        assert field in script
    assert 'printf "%s/state/drumsep_runtime.env\\n" "${RUNTIME_BASE}"' in script
    assert 'printf "%s/logs/drumsep_install.log\\n" "${RUNTIME_BASE}"' in script


def test_linux_setup_exposes_explicit_drumsep_runtime_action_without_normal_setup_autoinstall():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'mode ~= "repair" and mode ~= "rebuild-venv" and mode ~= "drumsep-runtime" and mode ~= "drumsep-rocm-runtime"' in setup_internal
    assert '((isDrumsepRuntime and "drumsep_runtime.env") or (isDrumsepRocmRuntime and "drumsep_runtime_rocm.env") or "bootstrap.env")' in setup_internal
    assert '((isDrumsepRuntime and "drumsep_install.log") or (isDrumsepRocmRuntime and "drumsep_rocm_install.log") or "bootstrap.log")' in setup_internal
    assert '{ id = "drumsep-runtime", label = "Drum Kit Split runtime"' in setup_internal
    assert '{ id = "drumsep-rocm-runtime", label = "Drum Kit Split ROCm runtime"' in setup_internal
    assert 'startLinuxSetup(runtime, separatorScript, chosen)' in setup_internal
    assert 'if [ "${MODE}" = "drumsep-runtime" ]; then' in linux_bootstrap
    assert 'write_drumsep_state "install_failed" "missing" "python_missing"' in linux_bootstrap
    assert 'elif [ "${MODE}" = "drumsep-rocm-runtime" ]; then' in linux_bootstrap
    assert 'write_drumsep_rocm_state "install_failed" "missing" "python_missing"' in linux_bootstrap


def test_linux_drumsep_rocm_runtime_installer_has_disk_preflight_and_rocm_pins():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'DRUMSEP_ROCM_TORCH_VERSION="2.9.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCHVISION_VERSION="0.24.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCHAUDIO_VERSION="2.9.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm6.4"' in script
    assert 'DRUMSEP_ROCM_MIN_FREE_GB="20"' in script
    assert "drumsep_rocm_disk_preflight()" in script
    assert "resolve_drumsep_rocm_tmpdir()" in script
    assert 'write_drumsep_rocm_state "disk_space_insufficient" "missing"' in script
    assert '"${_py}" -m pip install --no-cache-dir --index-url "${DRUMSEP_ROCM_TORCH_INDEX_URL}"' in script
    assert '"torch==${DRUMSEP_ROCM_TORCH_VERSION}"' in script
    assert '"${_py}" -m pip install --no-cache-dir --no-deps' in script
    assert '"audio-separator==${DRUMSEP_AUDIO_SEPARATOR_VERSION}"' in script
    assert '"${_py}" -m pip check' in script
    assert "verify_drumsep_rocm_runtime()" in script


def test_linux_drumsep_rocm_state_fields_are_written():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    for field in (
        "DRUMSEP_ROCM_RUNTIME_STATUS=",
        "DRUMSEP_ROCM_PYTHON=",
        "DRUMSEP_ROCM_AUDIO_SEPARATOR_VERSION=",
        "DRUMSEP_ROCM_TORCH_VERSION=",
        "DRUMSEP_ROCM_TORCH_HIP=",
        "DRUMSEP_ROCM_CUDA_AVAILABLE=",
        "DRUMSEP_ROCM_DEVICE_NAMES=",
        "DRUMSEP_ROCM_NUMPY_VERSION=",
        "DRUMSEP_ROCM_ONNX_VERSION=",
        "DRUMSEP_ROCM_ONNXRUNTIME_VERSION=",
        "DRUMSEP_ROCM_ONNX2TORCH_VERSION=",
        "DRUMSEP_ROCM_MODEL_STATUS=",
        "DRUMSEP_ROCM_LAST_CHECK_UTC=",
        "DRUMSEP_ROCM_TEMP_DIR=",
    ):
        assert field in script
    assert 'printf "%s/state/drumsep_runtime_rocm.env\\n" "${RUNTIME_BASE}"' in script
    assert 'printf "%s/logs/drumsep_rocm_install.log\\n" "${RUNTIME_BASE}"' in script


def test_drumsep_helper_payload_and_stem_normalization():
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    index_xml = Path("index.xml").read_text()

    assert helper_path.exists()
    assert "_internal/stemwerk_drumsep_process.py" in index_xml

    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(helper)

    assert helper.normalize_stem_name("Kick") == "kick"
    assert helper.normalize_stem_name("Snare") == "snare"
    assert helper.normalize_stem_name("Toms") == "toms"
    assert helper.normalize_stem_name("Hh") == "hihat"
    assert helper.normalize_stem_name("Hi-Hat") == "hihat"
    assert helper.normalize_stem_name("Ride") == "ride"
    assert helper.normalize_stem_name("Crash") == "crash"
    assert helper.REAPER_FILENAMES["hihat"] == "hi-hat.wav"


def test_drumsep_helper_wrong_output_count_schema(tmp_path):
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_count_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(helper)

    raw_file = tmp_path / "input_(Kick).wav"
    raw_file.write_bytes(b"RIFF")
    stems, raw_outputs = helper.normalize_outputs(tmp_path, [str(raw_file)], set())
    payload = helper._error_payload(
        "drumsep_output_count_mismatch",
        "stage2_output_validation",
        "expected 6 stems, got 1",
        stems=stems,
        raw_outputs=raw_outputs,
    )

    assert stems == {"kick": str(tmp_path / "kick.wav")}
    assert payload["ok"] is False
    assert payload["error_stage"] == "stage2_output_validation"
    assert payload["error_reason"] == "drumsep_output_count_mismatch"
    assert payload["expected_drum_outputs"] == 6
    assert payload["actual_drum_outputs"] == 1
    assert payload["output_count_mismatch"] is True


def test_direct_dks_helper_invocation_uses_optional_runtime_not_main_runtime():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()

    assert 'DRUMSEP_RUNTIME_DIRNAME = ".venv-drumsep"' in script
    assert 'DRUMSEP_RUNTIME_ROCM_DIRNAME = ".venv-drumsep-rocm"' in script
    assert "drumsep_runtime_selected=" in script
    assert 'str(drumsep_python),' in script
    assert '"--result-json",' in script
    assert 'drumsep_helper_stdout.txt' in script
    assert 'drumsep_helper_stderr.txt' in script
    assert 'print("PROGRESS:1:Starting Drum Kit runtime...", flush=True)' in script
    assert 'print("PROGRESS:0:Preparing Direct Drum Kit...", flush=True)' in script
    assert 'print("PROGRESS:95:Writing drum tracks...", flush=True)' in script
    assert "Splitting drum kit..." in script
    assert "timing_utc=" in script
    assert 'error_reason=drumsep_stage2_delegation_not_implemented' not in script
    assert 'drumsep_output_count_mismatch' in script


def test_drumkit_wrapper_selects_integrated_mode_and_extract_source():
    wrapper = Path("scripts/reaper/STEMwerk_Drum_Kit_Split.lua").read_text()
    assert 'reaper.SetExtState(EXT_SECTION, "quick_preset", "dks_extract", false)' in wrapper
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_mode", "drumkit", false)' in wrapper
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", "dks_extract", false)' in wrapper


def test_support_bundle_prefers_newest_runtime_run_over_stale_timing_summary():
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'local firstFromRuntimeRuns = tostring(first.log_path or ""):find("runtime_runs/", 1, true) ~= nil' in script
    assert "if not firstFromRuntimeRuns then" in script


def test_support_bundle_includes_drumsep_runtime_diagnostics_sections_and_files():
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert "buildDrumsepRuntimeDiagnostics(" in script
    assert "drumsep_runtime_status.txt" in script
    assert "[CPU fallback runtime]" in script
    assert "[ROCm runtime]" in script
    assert "[Latest Direct DKS markers]" in script
    assert "drumsep_runtime_selected" in script
    assert "drumsep_gpu_capable" in script
    assert "drumsep_install.log" in script
    assert "drumsep_rocm_install.log" in script
    assert script.index('writeFile(joinPath(bundleDir, "diagnostics.txt"') < script.index('local zipStartedAt = phaseStart("create_zip")')
    assert "local function updateZipTimingFile(" in script
    assert "updateZipTimingFile(zipPath, bundleDir, timingsFile, detectedPythonPath)" in script


def test_drumkit_completion_copy_has_localized_title_and_source_item_words():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    i18n_internal = Path("scripts/reaper/_internal/STEMwerk_i18n.lua").read_text()

    assert 'trSafeValue("drumkit_complete_title", "Direct Drum Kit completed successfully!")' in main_script
    assert 'trPlural(srcCount, "drumkit_result_source_item_one", "drumkit_result_source_item_many"' in main_script
    assert 'trPlural(sourceCount, "drumkit_result_source_item_one", "drumkit_result_source_item_many"' in main_script
    assert 'trPlural(stemsCreated, "drumkit_result_track_one", "drumkit_result_track_many", "drum track", "drum tracks")' in main_script

    assert 'drumkit_complete_title = "Direct Drum Kit completed successfully!"' in langs
    assert 'drumkit_complete_title = "Direct Drum Kit succesvol voltooid!"' in langs
    assert 'drumkit_complete_title = "Direct Drum Kit erfolgreich abgeschlossen!"' in langs
    assert 'drumkit_result_track_many = "drum tracks"' in langs
    assert 'drumkit_result_track_many = "drumtracks"' in langs
    assert 'drumkit_result_track_many = "Drum-Tracks"' in langs
    assert 'drumkit_result_multi_created = "%d %s created from %d %s."' in langs
    assert 'drumkit_result_multi_created = "%d %s gemaakt van %d %s."' in langs
    assert 'drumkit_result_multi_created = "%d %s aus %d %s erstellt."' in langs
    assert 'drumkit_result_items_replaced = "%d %s replaced with drum takes."' in langs
    assert 'drumkit_result_items_replaced = "%d %s vervangen door drumtakes."' in langs
    assert 'drumkit_result_items_replaced = "%d %s durch Drum-Takes ersetzt."' in langs
    assert 'dks_single_no_drum_takes = "No drum takes were imported."' in langs
    assert 'dks_single_no_drum_takes = "Er zijn geen drumtakes geïmporteerd."' in langs
    assert 'dks_single_no_drum_takes = "Es wurden keine Drum-Takes importiert."' in langs
    assert 'drumkit_result_item_muted = "Original source item muted."' in langs
    assert 'drumkit_result_item_muted = "Origineel bronitem gedempt."' in langs
    assert 'drumkit_result_item_muted = "Ursprüngliches Quellelement stummgeschaltet."' in langs
    assert 'drumkit_result_added_takes_hint = "%d %s added as takes (press T to switch)."' in langs
    assert 'drumkit_result_added_takes_hint = "%d %s toegevoegd als takes (druk T om te wisselen)."' in langs
    assert 'drumkit_result_added_takes_hint = "%d %s als Takes hinzugefügt (T zum Wechseln)."' in langs
    assert 'drumkit_result_source_item_one = "bronitem"' in langs
    assert 'drumkit_result_source_item_one = "Quellelement"' in langs
    assert "local function resolveOrFallback(key, fallback)" in i18n_internal
    assert "if value == \"\" or value == keyText or value == humanized then" in i18n_internal
    assert "terminal_hint_return_to_art = \"Klik >_ om terug te gaan naar voortgang\"" in langs
    assert "terminal_hint_return_to_art = \"Klick >_ für Fortschritt\"" in langs
    assert "terminal_hint_return_to_art = \"Click >_ to return to progress\"" in langs
    assert 'tooltip_terminal_close_output = "Close output"' in langs
    assert 'tooltip_terminal_close_output = "Sluit uitvoer"' in langs
    assert 'tooltip_terminal_close_output = "Ausgabe schließen"' in langs
    assert "Art-Ansicht" not in langs


def test_drumkit_split_wrapper_selects_integrated_extract_route():
    wrapper = Path("scripts/reaper/STEMwerk_Drum_Kit_Split.lua").read_text(encoding="utf-8")
    workflow = Path("scripts/reaper/_internal/STEMwerk_DrumKit_Workflow.lua").read_text(encoding="utf-8")

    assert 'reaper.SetExtState(EXT_SECTION, "quick_preset", "dks_extract", false)' in wrapper
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_mode", "drumkit", false)' in wrapper
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", "dks_extract", false)' in wrapper
    assert 'M.SOURCE_EXTRACT = "dks_extract"' in workflow
    assert "function M.buildExtractRunOptions()" in workflow
    assert "workflowSource = M.SOURCE_EXTRACT" in workflow
    assert "requestedStage2Model = M.DIRECT_DKS_MODEL" in workflow


def test_main_ui_exposes_direct_and_extract_drumkit_presets():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    progress_render = Path("scripts/reaper/_internal/STEMwerk_Progress_Render.lua").read_text()

    assert 'local presetLabelDrumKit = trSafe("workflow_drumkit_short_label", "Direct Drum Kit") .. " (Z)"' in main_script
    assert 'local presetLabelEdks    = trSafe("workflow_edks_short_label", "Drum Kit Split") .. " (X)"' in main_script
    assert 'local stemsHeader = ((dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT) or (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT))' in main_script
    assert 'and trSafe("drum_stems_label", "Drum Stems:")' in main_script
    assert 'if drawPresetBtn(presetY, presetLabelDrumKit, {170, 150, 240}, _pa.drumkit) then selectDirectDrumKitWorkflow() end' in main_script
    assert 'if drawPresetBtn(presetY, presetLabelEdks, {150, 132, 228}, _pa.edks) then selectExtractDrumKitWorkflow() end' in main_script
    assert "showExtractKitPlannedNotice()" not in main_script
    assert "local function selectExtractDrumKitWorkflow()" in main_script
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", DKS_WORKFLOW.SOURCE_EXTRACT, false)' in main_script
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", DKS_WORKFLOW.SOURCE_DIRECT, false)' in main_script
    assert 'activateWorkflowStemSet(isDrumKitWorkflow)' in main_script

    assert 'workflow_drumkit_label = "Direct Drum Kit"' in langs
    assert 'workflow_drumkit_short_label = "Direct Drum Kit"' in langs
    assert 'workflow_edks_label = "Drum Kit Split"' in langs
    assert 'workflow_edks_short_label = "Drum Kit Split"' in langs
    assert 'drum_stems_label = "Drum Stems:"' in langs
    assert 'tooltip_preset_drumkit = "Split already-drum material into Kick, Snare, Toms, Hi-Hat, Ride and Crash."' in langs
    assert 'tooltip_preset_edks = "Extract drums from a full mix, then split the kit into Kick, Snare, Toms, Hi-Hat, Ride and Crash."' in langs
    assert 'tooltip_preset_drumkit = "Splitst drum-only materiaal naar Kick, Snare, Toms, Hi-Hat, Ride en Crash."' in langs
    assert 'tooltip_preset_edks = "Haal eerst drums uit een volledige mix en split daarna de kit naar Kick, Snare, Toms, Hi-Hat, Ride en Crash."' in langs
    assert 'tooltip_preset_drumkit = "Teilt Drum-Material in Kick, Snare, Toms, Hi-Hat, Ride und Crash."' in langs
    assert 'tooltip_preset_edks = "Extrahiert zuerst Drums aus einem vollständigen Mix und teilt danach das Kit in Kick, Snare, Toms, Hi-Hat, Ride und Crash auf."' in langs
    assert 'tooltip_stem_drumkit_kick = "Kick drum / bass drum"' in langs
    assert 'tooltip_stem_drumkit_snare = "Snare drum"' in langs
    assert 'tooltip_stem_drumkit_toms = "Toms"' in langs
    assert 'tooltip_stem_drumkit_hihat = "Hi-hat"' in langs
    assert 'tooltip_stem_drumkit_ride = "Ride cymbal"' in langs
    assert 'tooltip_stem_drumkit_crash = "Crash cymbal"' in langs
    assert 'tooltip_stem_drumkit_kick = "Kickdrum / bassdrum"' in langs
    assert 'tooltip_stem_drumkit_crash = "Crash-bekken"' in langs
    assert 'tooltip_stem_drumkit_kick = "Kickdrum / Bassdrum"' in langs
    assert 'tooltip_stem_drumkit_crash = "Crash-Becken"' in langs
    assert 'drum_stems_label = "Drumstems:"' in langs
    assert 'drum_stems_label = "Drum-Stems:"' in langs
    assert 'model_label_expanded = "Expanded"' in langs
    assert 'model_expanded_drumkit_desc = "Expanded Drum Kit model for more detailed drum-kit splitting."' in langs
    assert 'model_expanded_drumkit_desc = "Uitgebreid Drum Kit-model voor gedetailleerdere drumkit-splitsing."' in langs
    assert 'model_expanded_drumkit_desc = "Erweitertes Drum-Kit-Modell für detailliertere Drumkit-Trennung."' in langs
    assert 'device = "Gerät:"' in langs
    assert 'selected = "Ausgewählt:"' in langs
    assert 'delete_original = "Original löschen"' in langs
    assert 'tooltip_close = "STEMwerk schließen (ESC)"' in langs
    assert 'progress_stage_splitting_drum_kit = "Creating Drum Kit Split..."' in langs
    assert 'progress_stage_splitting_drum_kit = "Drum Kit Split maken..."' in langs
    assert 'progress_stage_splitting_drum_kit = "Drum Kit Split erstellen..."' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Creating Direct Drum Kit..."' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Direct Drum Kit maken..."' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Direct Drum Kit erstellen..."' in langs
    assert 'progress_stage_extracting_drums = "Extracting drums..."' in langs
    assert 'progress_stage_extracting_drums = "Drums extraheren..."' in langs
    assert 'progress_stage_extracting_drums = "Drums extrahieren..."' in langs
    assert 'progress_stage_queued_drumsep = "Queued for drum kit..."' in langs
    assert 'progress_stage_queued_drumsep = "In wachtrij voor drumkit..."' in langs
    assert 'progress_stage_queued_drumsep = "In Warteschlange für Drumkit..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Preparing drum kit..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Drumkit voorbereiden..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Drumkit vorbereiten..."' in langs
    assert 'mt_parallel_cap = "cap %d"' in langs
    assert 'mt_parallel_cap = "limiet %d"' in langs
    assert 'mt_parallel_cap = "Limit %d"' in langs
    assert 'progress_stage_label_1_of_2 = "Stage 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Stage 2/2"' in langs
    assert 'progress_stage_label_1_of_2 = "Stap 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Stap 2/2"' in langs
    assert 'progress_stage_label_1_of_2 = "Stufe 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Stufe 2/2"' in langs
    assert 'progress_stage2_serialized_caption = "Stage 2 serialized for stability"' in langs
    assert 'progress_stage2_serialized_caption = "Stap 2 serieel voor stabiliteit"' in langs
    assert 'progress_stage2_serialized_caption = "Stufe 2 seriell für Stabilität"' in langs
    assert 'progress_dks_extract_route_summary = "Normal stems → Drum Kit"' in langs
    assert 'progress_dks_extract_route_summary = "Normale stems → Drum Kit"' in langs
    assert 'progress_dks_extract_route_summary = "Normale Stems → Drum Kit"' in langs
    assert 'progress_stage_writing_drum_tracks = "Writing drum tracks..."' in langs
    assert 'progress_stage_writing_drum_tracks = "Drumtracks schrijven..."' in langs
    assert 'progress_stage_writing_drum_tracks = "Drum-Spuren werden geschrieben..."' in langs
    assert 'tooltip_nerd_mode_hide = "Back to progress view"' in langs
    assert 'tooltip_nerd_mode_hide = "Terug naar voortgang"' in langs
    assert 'tooltip_nerd_mode_hide = "Zurück zur Fortschrittsansicht"' in langs
    assert 'tooltip_terminal_close_output = "Close output"' in langs
    assert 'tooltip_terminal_close_output = "Sluit uitvoer"' in langs
    assert 'tooltip_terminal_close_output = "Ausgabe schließen"' in langs
    assert 'footer_drum_tracks = "drum tracks"' in langs
    assert 'footer_drum_tracks = "drumtracks"' in langs
    assert 'footer_drum_tracks = "Drum-Spuren"' in langs
    assert 'footer_drum_stem_folder = "drum folder"' in langs
    assert 'footer_drum_stem_folder = "drum-map"' in langs
    assert 'footer_drum_stem_folder = "Drum-Ordner"' in langs
    assert 'direct_drum_kit_folder_suffix = "Direct Drum Kit"' in langs
    assert 'drum_kit_split_folder_suffix = "Drum Kit Split"' in langs
    assert 'edks_complete_title = "Drum Kit Split completed successfully!"' in langs
    assert 'route_badge_normal = "Normal STEMwerk"' in langs
    assert 'route_badge_normal = "Normale STEMwerk"' in langs
    assert 'route_badge_normal = "Normales STEMwerk"' in langs
    assert 'drumkit_result_time_selection_created = "%d %s created from time selection."' in langs
    assert 'drumkit_result_time_selection_created = "%d %s aangemaakt uit tijdselectie."' in langs
    assert 'drumkit_result_time_selection_created = "%d %s aus Zeitauswahl erstellt."' in langs
    assert 'drumkit_result_created_generic = "%d %s created."' in langs
    assert 'drumkit_result_created_generic = "%d %s aangemaakt."' in langs
    assert 'drumkit_result_created_generic = "%d %s erstellt."' in langs
    assert 'model_label_quality = "Qualität"' in langs
    assert 'local displayName = ((dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT) or (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT))' in main_script
    assert 'and stem.name' in main_script
    assert 'local tooltipKey = ((dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT) or (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT))' in main_script
    assert 'and (drumStemTooltipKeys[stem.name] or "tooltip_stem_other")' in main_script
    assert 'trSafe("workflow_drumkit_label", "Direct Drum Kit") .. "\\n" .. trSafe("tooltip_preset_drumkit", "Split already-drum material into Kick, Snare, Toms, Hi-Hat, Ride and Crash.")' in main_script
    assert 'trSafe("workflow_edks_label", "Drum Kit Split") .. "\\n" .. trSafe("tooltip_preset_edks", "Extract drums from a full mix, then split the kit into Kick, Snare, Toms, Hi-Hat, Ride and Crash.")' in main_script
    assert 'if model.id == "htdemucs"' in main_script
    assert 'modelDisplayName = trSafe("model_label_expanded", "Expanded")' in main_script
    assert 'if (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT or dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT) and model.id == "htdemucs_6s" then' in main_script
    assert 'descKey = "model_expanded_drumkit_desc"' in main_script
    assert "return drawToggleButton(col1X, py, colW, btnH, label, isActive == true, rawColor, presetsBtnFontSize)" in main_script
    assert "local presetBottomLimit = footerRow4Y - S(6)" in main_script
    assert "if estimatePresetBottom(presetStartY, presetStep, presetSectionGap, presetButtonCount) > presetBottomLimit then" in main_script
    assert "_pa.all = false" in main_script
    assert "_pa.vocals = false" in main_script
    assert "_pa.edks    = workflowSource == DKS_WORKFLOW.SOURCE_EXTRACT" in main_script
    assert "local inDrumKitWorkflow = workflowMode == DKS_WORKFLOW.WORKFLOW_DRUMKIT" in main_script
    assert 'preparing direct drum kit' in progress_render
    assert 'extracting drums' in progress_render
    assert 'starting drum kit runtime' in progress_render
    assert 'writing drum tracks' in progress_render
    assert 'drumsep stage2 separating kit stems' in progress_render
    assert 'stage 2 queued for drumsep' in progress_render
    assert 'progress_stage_queued_drumsep' in progress_render
    assert 'progress_stage_splitting_drum_kit' in progress_render
    assert 'progress_stage_label_1_of_2' in progress_render
    assert 'progress_stage_label_2_of_2' in progress_render
    assert 'isExtractDrumKitProgress()' in progress_render
    assert 'progress_stage2_serialized_caption' in main_script
    assert 'pctText = trSafeValue("progress_stage_label_2_of_2", "Stage 2/2")' in main_script


def test_drumkit_direct_route_uses_drum_specific_folder_suffix_and_runtime_device_breadcrumbs():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    workflow_script = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text()

    assert 'function activeDrumKitFolderSuffix()' in main_script
    assert 'return trSafeValue("drum_kit_split_folder_suffix", "Drum Kit Split")' in main_script
    assert 'return trSafeValue("direct_drum_kit_folder_suffix", "Direct Drum Kit")' in main_script
    assert 'sourceTrackName .. " - " .. folderLabel' in main_script
    assert "ui_device_selected_before_run=" in workflow_script
    assert "backend_device_arg=" in workflow_script
    assert "effectiveRunDevice            = effectiveRunDevice," in main_script


def test_single_track_workflow_uses_run_snapshot_device_and_resets_progress_device_state():
    workflow_script = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text()

    assert 'local requestedDeviceArg = (type(C.effectiveRunDevice) == "function" and C.effectiveRunDevice()) or SETTINGS.device or "auto"' in workflow_script
    assert 'local requestedDeviceArg = tostring((type(C.effectiveRunDevice) == "function" and C.effectiveRunDevice()) or SETTINGS.device or "auto")' in workflow_script
    assert "C.progressState._deviceId = nil" in workflow_script
    assert "C.progressState._deviceName = nil" in workflow_script
    assert "C.progressState._runtimeSelected = nil" in workflow_script
    assert "C.progressState._normalizedDeviceRequest = nil" in workflow_script
    assert "C.progressState._runtimeGpuCapable = nil" in workflow_script
    assert "C.progressState._runtimeDeviceNames = nil" in workflow_script
    assert "C.progressState._stage1Runtime = nil" in workflow_script
    assert "C.progressState._stage1Device = nil" in workflow_script
    assert "C.progressState._stage2Runtime = nil" in workflow_script
    assert "C.progressState._stage2Device = nil" in workflow_script
    assert "C.progressState._deviceInfoLastAt = nil" in workflow_script


def test_drumkit_ui_strings_use_safe_translation_resolution():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    assert "function trSafeValue(key, fallback)" in script
    assert 'function activeProcessingRouteBadge()' in script
    assert 'function buildProgressRouteSummary(deviceDetail)' in script
    assert 'function buildDksFooterDeviceIntent(deviceDetail)' in script
    assert 'function compactProgressDeviceToken(rawDevice, friendlyDetail)' in script
    assert 'local routeLeft = activeProcessingRouteBadge() .. " · " .. stageBadge' in script
    assert 'routeLeft = routeLeft .. " · " .. deviceIntent' in script
    assert 'routeLeft = routeLeft .. " · " .. tostring(deviceDetail)' not in script
    assert 'directSummary = directSummary .. " · " .. deviceIntent' in script
    assert 'local routeBadge = drumKitMode and "" or activeProcessingRouteBadge()' in script
    assert 'if multiTrackQueue and multiTrackQueue.active and SETTINGS and SETTINGS.parallelProcessing then' in script
    assert 'stage2Compact = stage2Compact .. " " .. tostring(deviceDetail)' not in script
    assert 'progress_dks_extract_route_summary' in script
    assert 'local routeSummaryLeft, routeSummaryRight = buildProgressRouteSummary(deviceDetail)' in script
    assert 'inlineStageText = inlineStageText .. " [" .. tostring(footerDeviceDetail) .. "]"' not in script
    assert "function normalizeStemPathMap(stemPaths)" in script
    assert "function resolveStemSetForPaths(stemPaths)" in script
    assert 'if stemPathMapLooksLikeDrumKit(stemPaths) then' in script
    assert 'function activeDrumKitWorkflowTitle()' in script
    assert 'return trSafeValue("workflow_edks_label", "Drum Kit Split")' in script
    assert 'return trSafeValue("workflow_drumkit_label", "Direct Drum Kit")' in script
    assert 'return trSafeValue("workflow_edks_short_label", "Drum Kit Split")' in script
    assert 'return trSafeValue("workflow_drumkit_short_label", "Direct Drum Kit")' in script
    assert 'return trSafeValue("route_badge_normal", "Normal STEMwerk")' in script
    assert 'setTooltipWithShortcut(col2X, stemY, colW, btnH, trSafe(tooltipKey, displayName .. " [" .. stem.key .. "]"), stem.key, stem.color)' in script
    assert 'function activeDrumKitFolderSuffix()' in script
    assert 'function activeDrumKitCompleteTitle()' in script
    assert 'return trSafeValue("edks_complete_title", "Drum Kit Split completed successfully!")' in script
    assert 'return trSafeValue("drumkit_complete_title", "Direct Drum Kit completed successfully!")' in script
    assert 'T("drumkit_result_time_selection_created") or "%d %s created from time selection."' in script
    assert 'T("drumkit_result_created_generic") or "%d %s created."' in script
    assert 'local drumKitFooterMode = workflowModeFooter == DKS_WORKFLOW.WORKFLOW_DRUMKIT' in script
    assert 'local footerStemSet = drumKitFooterMode and DRUMKIT_STEMS or STEMS' in script
    assert 'locLine = trFmt("footer_line_location_simple", "Location: %s", baseLoc)' in script
    assert 'locLine = trFmt("footer_line_location_simple", "Location: %s", trSafe("in_place", "In-place"))' in script
    assert 'tooltipText = progressState.showTerminal and trSafeValue("tooltip_terminal_close_output", "Close output")' in script
    assert 'textStr = textStr:gsub("%s*%[" .. shortcutEsc .. "%]%s*$", "")' in script
    assert 'footer_drum_stem_folder = "drum-map"' in langs


def test_german_visible_strings_and_fallbacks_do_not_use_ascii_transliterations():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    helpers = Path("scripts/reaper/_internal/STEMwerk_Helpers.lua").read_text()
    combined = langs + "\n" + helpers

    forbidden = [
        "fuer",
        "waehlen",
        "auswaehlen",
        "enthaelt",
        "Geraet",
        "Qualitaet",
        "Loeschen",
        "loeschen",
        "Schliessen",
        "schliessen",
        "Zurueck",
        "Ausgewaehlt",
    ]
    for token in forbidden:
        assert token not in combined

    assert "Zielordner für die finalen Stem-Dateien eingeben." in helpers
    assert "Audio auswählen oder Tracks/Items in REAPER hörbar machen." in helpers
    assert '"device = "Gerät:"' in langs
    assert '"selected = "Ausgewählt:"' in langs
    assert '"tooltip_close = "STEMwerk schließen (ESC)"' in langs


def test_direct_drumkit_tooltips_use_single_shortcut_and_route_scoped_expanded_copy():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()

    assert "[1] [1]" not in langs
    assert 'tooltip_stem_drumkit_kick = "Kickdrum / Bassdrum"' in langs
    assert 'tooltip_stem_drumkit_snare = "Snaredrum"' in langs
    assert 'textStr = textStr:gsub("%s*%[" .. shortcutEsc .. "%]%s*$", "")' in main_script
    assert 'model_6stem_desc = "htdemucs_6s - Adds Guitar & Piano separation"' in langs
    assert 'model_6stem_desc = "htdemucs_6s - Voegt Gitaar & Piano separatie toe"' in langs
    assert 'model_6stem_desc = "htdemucs_6s - Fügt Gitarre & Klavier Trennung hinzu"' in langs
    assert 'model_expanded_drumkit_desc = "Expanded Drum Kit model for more detailed drum-kit splitting."' in langs
    assert 'model_expanded_drumkit_desc = "Uitgebreid Drum Kit-model voor gedetailleerdere drumkit-splitsing."' in langs
    assert 'model_expanded_drumkit_desc = "Erweitertes Drum-Kit-Modell für detailliertere Drumkit-Trennung."' in langs
    assert 'if (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT or dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT) and model.id == "htdemucs_6s" then' in main_script
    assert 'descKey = "model_expanded_drumkit_desc"' in main_script


def test_drumkit_workflow_state_persists_and_restores_on_reopen():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    settings_script = Path("scripts/reaper/_internal/STEMwerk_Settings.lua").read_text()

    assert 'workflowMode = ""' in main_script
    assert 'workflowSource = ""' in main_script
    assert "restoreDialogWorkflowSelection = function()" in main_script
    assert "restoreDialogWorkflowSelection()" in main_script
    assert 'SETTINGS.workflowMode = DKS_WORKFLOW.WORKFLOW_DRUMKIT' in main_script
    assert 'SETTINGS.workflowSource = DKS_WORKFLOW.SOURCE_DIRECT' in main_script
    assert 'SETTINGS.workflowMode = ""' in main_script
    assert 'SETTINGS.workflowSource = ""' in main_script

    assert 'local workflowMode = C.reaper.GetExtState(C.EXT_SECTION, "workflow_mode")' in settings_script
    assert 'local workflowSource = C.reaper.GetExtState(C.EXT_SECTION, "workflow_source")' in settings_script
    assert 'C.reaper.SetExtState(C.EXT_SECTION, "workflow_mode", tostring(C.SETTINGS.workflowMode or ""), true)' in settings_script
    assert 'C.reaper.SetExtState(C.EXT_SECTION, "workflow_source", tostring(C.SETTINGS.workflowSource or ""), true)' in settings_script
    assert "if C.activateWorkflowStemSet then" in settings_script


def test_drumkit_expanded_model_stays_route_scoped_and_does_not_force_normal_stems():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "local function activateWorkflowStemSet(isDirectDKS)" in main_script
    assert "STEMS = isDirectDKS and DRUMKIT_STEMS or STANDARD_STEMS" in main_script
    assert 'if dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT or dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT then' in main_script
    assert 'modelDisplayName = trSafe("model_label_expanded", "Expanded")' in main_script
    assert 'local stemsHeader = ((dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT) or (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT))' in main_script
    assert 'and trSafe("drum_stems_label", "Drum Stems:")' in main_script


def test_drumkit_progress_footer_shows_resolved_runtime_without_raw_keys():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()

    assert "function deriveResolvedRuntimeFooter(footerDeviceDetail)" in script
    assert "progressState._runtimeSelected" in script
    assert "progressState._stage2Device" in script
    assert "progressState._stage1Device" in script
    assert "progressState._normalizedDeviceRequest" in script
    assert "progressState._runtimeGpuCapable" in script
    assert "progressState._runtimeDeviceNames" in script
    assert "function shortRuntimeGpuName(name)" in script
    assert "function buildDksFooterDeviceIntent(deviceDetail)" in script
    assert "local first = s:match(\"^([^|,;]+)\") or s" in script
    assert "first = first:gsub(\"^AMD Radeon%s+\", \"\")" in script
    assert 'trSafeValue("footer_device_auto_resolved_gpu", "Auto → GPU/ROCm: %s")' in script
    assert 'trSafeValue("footer_device_auto_gpu_intent", "Auto [GPU]")' in script
    assert 'trSafeValue("footer_device_auto_cpu_intent", "Auto [CPU]")' in script
    assert 'trSafeValue("footer_device_gpu_intent", "GPU")' in script
    assert "gpuRequested or gpuResolved" in script
    assert "trSafeValue(\"footer_device_auto_gpu_intent\", \"Auto [GPU]\")" in script
    assert "or req:find(\"directml\", 1, true)" in script

    assert 'trSafeValue("footer_device_cpu_runtime", "CPU runtime")' in script
    assert "if not isDrumKitWorkflowActive() then" in script
    assert "if not isDrumKitWorkflowActive() then" in script
    assert 'leftParts[#leftParts + 1] = string.format("%s: %s", mtSeg, "30")' in script
    assert 'footer_device_auto_resolved_gpu = "Auto → GPU/ROCm: %s"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU runtime"' in langs
    assert 'footer_device_auto_gpu_intent = "Auto [GPU]"' in langs
    assert 'footer_device_auto_cpu_intent = "Auto [CPU]"' in langs
    assert 'footer_device_gpu_intent = "GPU"' in langs
    assert 'footer_device_cpu_runtime = "CPU runtime"' in langs
    assert 'footer_device_gpu_runtime = "GPU/ROCm: %s"' in langs
    assert 'footer_device_cuda_runtime = "CUDA: %s"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU-runtime"' in langs
    assert 'footer_device_cpu_runtime = "CPU-runtime"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU-Runtime"' in langs
    assert 'footer_device_cpu_runtime = "CPU-Runtime"' in langs
    assert 'rawLower:match("^cuda:%d+")' in script
    assert 'return trSafeValue("footer_device_gpu_intent", "GPU")' in script
    assert 'rawDeviceName:lower():find("amd", 1, true)' in script

    assert 'trSafeValue("footer_device_cuda_runtime", "CUDA: %s")' in script
    assert 'local raw = tostring(rawDevice or ""):gsub("^%s+", ""):gsub("%s+$", "")' in script
    assert 'if lower:match("^cuda:%d+") then return "GPU" end' in script
    assert 'return compactProgressDeviceToken(rawDetail)' in script
    assert 'compactProgressDeviceToken(deviceDetail, deviceDetail)' in script


def test_drumkit_visible_progress_and_support_summary_hide_raw_cuda_devices():
    py_script = Path("scripts/reaper/audio_separator_process.py").read_text()
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'print("PROGRESS:1:Extracting drums...", flush=True)' in py_script
    assert 'emit_progress(bounded, "Extracting drums...")' in py_script
    assert 'Extracting drums [{stage1_runtime_device}]' not in py_script
    assert 'lines[#lines + 1] = "device: " .. tostring(entry.device or "unknown")' in support_script
    assert 'lines[#lines + 1] = "friendly_device: " .. tostring(entry.friendly_device or "unknown")' in support_script
    assert "local function friendlyDeviceLabel(rawDevice, runtimeState, entry)" in support_script
    assert 'return "Auto [GPU]"' in support_script


def test_sync_to_reaper_does_not_overwrite_script_local_i18n_with_repo_root_i18n():
    sync_script = Path("scripts/reaper/sync_to_reaper.sh").read_text()
    assert '"${src_dir}/"' in sync_script
    assert '"${repo_root}/i18n/"' not in sync_script


def test_german_visual_and_help_copy_uses_umlauts_for_direct_dks_paths():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    assert "Audio in REAPER auswählen" in langs
    assert "Tracks, Medien-Items oder Zeitauswahl wählen" in langs
    assert "Ausgewählte Multi-Take Items" in langs
    assert "Mehrere Qualitätsmodi" in langs
    assert "Was jeder Stem enthält" in langs


def test_selected_items_take_precedence_over_unrelated_time_selection_for_no_audio_and_dispatch():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    monitor = script.split("function HELPERS.getSelectionMonitorState()", 1)[1].split("-- Message window state", 1)[0]
    selected_items_branch = monitor.split("if selItemCount > 0 then", 1)[1].split("if selTrackCount > 0 then", 1)[0]
    selected_tracks_branch = monitor.split("if selTrackCount > 0 then", 1)[1].split("if hasTimeSel then", 1)[0]
    time_selection_branch = monitor.split("if hasTimeSel then", 1)[1]

    assert 'if item and reaper.ValidatePtr(item, "MediaItem*") then' in selected_items_branch
    assert "itemOverlapsTimeSelection(item)" not in selected_items_branch
    assert 'anyAudibleItemOnTrack(track, false)' in selected_tracks_branch
    assert 'anyAudibleItemOnTrack(track, true)' in time_selection_branch

    footer = script.split("buildFooterLines = function()", 1)[1].split("local function previewOutputSummary()", 1)[0]
    assert "local useTimeSel = hasTimeSel and rawSelTrackCount == 0 and rawSelItemCount == 0" in script
    assert "local useTimeSel = hasTimeSel and selTrackCount == 0 and selItemCount == 0" in script
    assert "local useTimeSel = hasTimeSelection() and selTrackCount == 0 and selItemCount == 0" in script
    assert "HELPERS.hasExplicitOverlapSelection(currentTimeStart, currentTimeEnd)" not in footer

    run_workflow = script.split("function runSeparationWorkflow()", 1)[1].split("-- Check for quick preset mode", 1)[0]
    assert "local useTimeSel = hasTimeSel and selTrackCount == 0 and selItemCount == 0" in run_workflow
    assert "HELPERS.hasExplicitOverlapSelection(ts0, ts1)" not in run_workflow

    main_startup = script.split("-- Main", 1)[1]
    assert 'if checkQuickPreset() then' in main_startup
    assert "HELPERS.getSelectionMonitorState()" in script


def test_model_download_failure_reason_codes_are_wired_for_runtime_and_bundle():
    log_script = Path("scripts/reaper/_internal/STEMwerk_Log.lua").read_text()
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    py_script = Path("scripts/reaper/audio_separator_process.py").read_text()

    assert 'error_class = "model_download_timeout"' in log_script
    assert 'error_class = "model_download_failed"' in log_script
    assert 'error_class = "model_checksum_failed"' in log_script
    assert 'reason = "model_cache_corrupt"' in log_script
    assert 'reason = "model_load_failed"' in log_script
    assert "STEMWERK_ERROR_CLASS=" in log_script
    assert "STEMWERK_ERROR_HINT=" in log_script
    assert "STEMWERK_MODEL_CACHE_HINT=" in log_script
    assert 'local runSucceeded = tonumber(exitCode) == 0 and tostring(doneText):find("DONE", 1, true) ~= nil' in log_script
    assert 'if reason == "partial_dks_multi" then' in log_script
    assert "elseif not runSucceeded then" in log_script
    assert 'if failure and failure.reason and reason == "no_stems" then' in log_script

    assert 'key == "error_class" or key == "stemwerk_error_class"' in support_script
    assert 'kvAssignLast(entry, "error_class", "model_download_timeout")' in support_script
    assert 'kvAssignLast(entry, "error_class", "model_download_failed")' in support_script
    assert 'kvAssignLast(entry, "error_class", "model_checksum_failed")' in support_script
    assert 'lines[#lines + 1] = "error_class: " .. tostring(entry.error_class or "unknown")' in support_script
    assert 'lines[#lines + 1] = "error_hint: " .. tostring(entry.error_hint or "unknown")' in support_script

    assert "Model download/load failed." in main_script
    assert "Model cache folder:" in main_script
    assert "SW_LOG.classifyModelFailure" in main_script

    assert 'print(f"STEMWERK_ERROR_CLASS={model_failure[\'error_class\']}", file=sys.stderr)' in py_script
    assert 'print(f"STEMWERK_ERROR_HINT={model_failure[\'error_hint\']}", file=sys.stderr)' in py_script


def test_support_bundle_processing_summary_prefers_current_success_and_guards_cancel():
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert "local function finalizeRunClassification(entry)" in script
    assert "local strongSuccess = (hasExitZero and hasDoneSuccess)" in script
    assert "setRunResult(entry, \"success\", 100)" in script
    assert "entry.error_class = \"unknown\"" in script
    assert "entry.error_hint = \"unknown\"" in script
    assert "entry.error_reason = \"unknown\"" in script
    assert "if hasCancel and not hasModelEvidence then" in script
    assert "setRunResult(entry, \"cancelled\", 90)" in script
    assert "if pathExists(stemsJsonPath) then" in script
    assert "finalizeRunClassification(entry)" in script


def test_lua_wav_render_path_guards_unsigned_pack_overflow_and_invalid_samples():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "local function clampSampleFloat(v)" in script
    assert "if not isFiniteNumber(v) then return 0.0 end" in script
    assert "if v > 1.0 then return 1.0 end" in script
    assert "if v < -1.0 then return -1.0 end" in script
    assert "local function safeUint(name, v, bits)" in script
    assert "local function safeWritePack(fileHandle, fmt, value, label, bits)" in script
    assert 'string.pack("<I4", safeRiffBytes' not in script
    assert 'safeWritePack(f, "<I4", safeRiffBytes, "riff_size", 32)' in script
    assert 'safeWritePack(f, "<I4", safeDataBytes, "data_size", 32)' in script
    assert 'parts[i] = string.pack("<f", clampSampleFloat(buf[i] or 0.0))' in script
    assert "WAV render failed:" in script
    assert "out of range for uint%d" in script


def test_lua_wav_render_failures_log_context_in_item_and_time_selection_paths():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "renderTakeAccessorToWav failed (partial transform)" in script
    assert "renderTakeAccessorToWav failed (partial default)" in script
    assert "renderTakeAccessorToWav failed (full item)" in script
    assert "renderTakeAccessorToWav failed (time selection single item)" in script
    assert "renderTakeAccessorToWav failed (time selection)" in script


def test_linux_managed_diffq_wheel_payload_is_present_and_resolvable():
    scripts_wheel_dir = Path("scripts/reaper/vendor/wheels/linux-x86_64-cp312")
    scripts_wheels = sorted(scripts_wheel_dir.glob("diffq-*-cp312-cp312-linux_x86_64.whl"))

    assert scripts_wheel_dir.is_dir(), f"missing managed wheel directory: {scripts_wheel_dir}"
    assert scripts_wheels, "missing managed diffq cp312 linux_x86_64 wheel payload in scripts vendor wheel path"


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


def test_reapack_registers_expected_user_actions_and_keeps_internal_files_non_actions():
    index = Path("index.xml").read_text()
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    setup_script = Path("scripts/reaper/STEMwerk-SETUP.lua").read_text()
    toolbar_script = Path("scripts/reaper/STEMwerk_Setup_Toolbar.lua").read_text()

    assert '<source file="../STEMwerk.lua" type="script" main="main">' in index
    assert '<source file="../STEMwerk-SETUP.lua" type="script" main="main">' in index
    assert '<source file="../STEMwerk_Setup_Toolbar.lua" type="script" main="main">' in index

    assert "-- @description STEMwerk - AI Stem Separation" in main_script
    assert "-- @description STEMwerk - Setup" in setup_script
    assert "-- @description STEMwerk - Setup Toolbar Actions" in toolbar_script

    assert '<source file="../_internal/STEMwerk_Setup_Internal.lua" type="file">' in index
    assert '<source file="../audio_separator_process.py" type="file">' in index
    assert '<source file="../STEMwerk_Bootstrap_Linux.sh" type="file">' in index
    assert '<source file="../STEMwerk_Bootstrap_macOS.sh" type="file">' in index
    assert '<source file="../STEMwerk_Bootstrap_Windows.ps1" type="file">' in index

def test_macos_bootstrap_detects_and_repairs_samplerate_arch_mismatch_on_arm64():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()
    guard = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py").read_text()

    assert "repair_samplerate_if_arch_mismatch" in script
    assert "stemwerk_samplerate_guard.py" in script
    assert '_guard_out="$("${VENV_PY}" "${_guard_script}" --python "${VENV_PY}" 2>&1)"' in script
    assert '_guard_out="$(${VENV_PY} "${_guard_script}" --python "${VENV_PY}" 2>&1)"' not in script
    assert '"${VENV_PY}" -m pip show audio-separator >/dev/null 2>&1' in script
    assert 'if ! repair_samplerate_if_arch_mismatch "post_audio_separator_install"; then' in script
    assert "samplerate_arch_mismatch_requires_runtime_rebuild" in script
    assert "samplerate_reinstall_failed" in script
    assert 'f"samplerate=={args.repair_version}"' in guard
    assert "--no-deps" in guard
    assert "samplerate_dylib_not_found_after_repair_but_import_ok" in guard
    assert "after_audio_separator_import" in guard
    assert "audio_separator_import_failed_after_samplerate_repair" in guard


def test_samplerate_guard_discovers_dylibs_recursively_and_does_not_require_legacy_path():
    guard = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py").read_text()

    assert "for path in root.rglob(\"*.dylib\")" in guard
    assert "samplerate_dylib_candidate_count" in guard
    assert "samplerate_dylib_candidate_" in guard
    assert "if dylib_count == 0:" in guard
    assert "samplerate_dylib_not_found_after_repair_but_import_ok" in guard


def test_samplerate_guard_requires_repair_on_x86_only_or_import_failure_and_fails_on_post_repair_import_error():
    guard = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py").read_text()

    assert "if probe.get(\"samplerate_import\") != \"ok\":" in guard
    assert "if x86_only > 0 and arm_ok == 0:" in guard
    assert "samplerate_import_failed_after_repair" in guard
    assert "_print_diag(\"before_audio_separator_import\"" in guard
    assert "_print_diag(\"after_audio_separator_import\"" in guard


def test_macos_bootstrap_runs_samplerate_guard_before_final_dependency_verification():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert script.index('if ! repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"; then') < script.index('if ! "${VENV_PY}" -c "import audio_separator" >/dev/null 2>&1; then')
    assert script.index('if ! repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"; then') < script.index('if ! verify_audio_separator_runtime_deps; then')
    assert script.index('if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then') < script.index('if ! repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"; then')
    assert 'if ! repair_samplerate_if_arch_mismatch "post_audio_separator_install"; then' in script


def test_macos_bootstrap_clears_stale_torch_pin_assert_failure_after_final_runtime_success():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'FINAL_RUNTIME_VERIFIED="yes"' in script
    assert 'if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ] && [ "${STATUS_REASON}" = "torch_pin_assert_failed" ]; then' in script
    assert 'STATUS="ok"' in script
    assert 'STATUS_REASON=""' in script
    assert 'Cleared stale STATUS from earlier pinned runtime assertion failure after final runtime verification success' in script


def test_macos_bootstrap_only_clears_stale_torch_pin_status_after_real_final_checks():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    line_no = lambda needle: next(i for i, line in enumerate(script.splitlines(), 1) if needle in line)
    assert line_no('if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ] && [ "${STATUS_REASON}" = "torch_pin_assert_failed" ]; then') > line_no('if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then')
    assert line_no('if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ] && [ "${STATUS_REASON}" = "torch_pin_assert_failed" ]; then') > line_no('if ! assert_pinned_torch_stack "${VENV_PY}"; then')


def test_macos_bootstrap_samplerate_repair_attempt_status_is_monotonic_yes():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'if [ "${_guard_repair_attempted}" = "yes" ]; then' in script
    assert 'SAMPLERATE_REPAIR_ATTEMPTED="yes"' in script
    assert 'elif [ "${SAMPLERATE_REPAIR_ATTEMPTED}" != "yes" ]; then' in script


def test_macos_bootstrap_persists_samplerate_arch_diagnostics_into_state():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    for field in [
        "SAMPLERATE_VERSION",
        "SAMPLERATE_MODULE_PATH",
        "SAMPLERATE_DYLIB_PATH",
        "SAMPLERATE_DYLIB_ARCH",
        "SAMPLERATE_PLATFORM_MACHINE",
        "SAMPLERATE_SYSCONFIG_PLATFORM",
        "SAMPLERATE_ARCH_MATCH",
        "SAMPLERATE_REPAIR_ATTEMPTED",
    ]:
        assert f'echo "{field}=' in script


def test_setup_internal_surfaces_samplerate_arch_mismatch_reason_and_capabilities_fields():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'elseif lower == "samplerate_arch_mismatch_requires_runtime_rebuild" then' in script
    assert 'elseif lower == "samplerate_reinstall_failed" then' in script
    assert "SAMPLERATE_DYLIB_ARCH" in script
    assert "SAMPLERATE_ARCH_MATCH" in script
    assert "SAMPLERATE_REPAIR_ATTEMPTED" in script


def test_macos_apple_silicon_sanity_workflow_asserts_samplerate_dylib_architecture():
    workflow = Path(".github/workflows/macos-apple-silicon-backend-sanity.yml").read_text()

    assert "Run samplerate arm64 repair guard (bootstrap parity)" in workflow
    assert "python scripts/reaper/_internal/stemwerk_samplerate_guard.py" in workflow
    assert "import samplerate" in workflow
    assert 'samplerate_root.rglob("*.dylib")' in workflow
    assert 'payload["samplerate_dylib_file_outputs"]' in workflow
    assert 'assert len(payload["samplerate_dylib_x86_only"]) == 0' in workflow
    assert 'if payload["samplerate_dylib_candidates"]:' in workflow
    assert 'assert len(payload["samplerate_dylib_arm_or_universal"]) > 0' in workflow
    assert workflow.index("Run samplerate arm64 repair guard (bootstrap parity)") < workflow.index("Run Apple Silicon dependency and backend assertions")


def test_normal_workflow_device_preflight_blocks_silent_cpu_fallback():
    workflow = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")

    assert "normal_workflow_device_ui=" in workflow
    assert "normal_workflow_device_snapshot=" in workflow
    assert "normal_workflow_live_device_ids=" in workflow
    assert "normal_workflow_live_gpu_available=" in workflow
    assert "normal_workflow_fallback_reason=live_runtime_cpu_only" in workflow
    assert "silent fallback to CPU" in workflow
    assert "normal_workflow_command_device=" in workflow


def test_normal_workflow_python_logs_live_device_preview_and_blocks_cpu_only_gpu_requests():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "normal_workflow_backend_seen_device_request=" in script
    assert "normal_workflow_live_device_ids=" in script
    assert "normal_workflow_backend_seen_device_resolved=" in script
    assert "normal_workflow_backend_preview_device=" in script
    assert "normal_workflow_backend_preview_name=" in script
    assert "normal_workflow_backend_fallback_reason=live_runtime_cpu_only" in script
    assert 'if str(device_preference or "auto").strip().lower() != "cpu" and str(preview_device_id) == "cpu":' in script


def test_audio_separator_runtime_diagnostics_include_cuda_visibility():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert 'print(f"STEMWERK_DIAG cuda_available={env.get(\'cuda_available\')}", file=sys.stderr)' in script
    assert 'print(f"STEMWERK_DIAG cuda_count={env.get(\'cuda_count\')}", file=sys.stderr)' in script


def test_main_dialog_prefers_live_runtime_probe_and_only_falls_back_to_cached_devices():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local probeStarted = startRuntimeDeviceProbeAsync(true)' in script
    assert 'perfMark("showStemSelectionDialog(): live device probe started")' in script
    assert 'if applyCachedRuntimeDevices(cacheOpts) then' in script


def test_device_column_uses_route_aware_runtime_sources_and_sanitizes_cpu_only_normal_mode():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local runtimeDevicesForUi = directDksRoute and buildDirectDksDeviceList() or RUNTIME_DEVICES' in script
    assert 'stateDir .. PATH_SEP .. "drumsep_runtime_rocm.env"' in script
    assert 'rocmState.DRUMSEP_ROCM_DEVICE_NAMES' in script
    assert 'if not directDksRoute and not listHasGpuDevice(deviceList) then' in script
    assert 'SETTINGS.device = directDksRoute and "auto" or "cpu"' in script


def test_cached_capability_devices_ignore_stale_raw_gpu_blocks_when_runtime_is_cpu_only():
    script = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")

    assert 'local rawLooksStale = driftDetected' in script
    assert 'or backend == "cpu"' in script
    assert 'lines[#lines + 1] = "STEMWERK_DEVICE\\tauto\\tAuto\\tauto"' in script
    assert 'lines[#lines + 1] = "STEMWERK_DEVICE\\tcpu\\tCPU\\tcpu"' in script


def test_normal_runtime_cpu_only_message_distinguishes_direct_drumkit_runtime():
    workflow = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")

    assert "live normal runtime reports CPU-only devices" in workflow
    assert "Direct Drum Kit uses a separate Drum Kit runtime" in workflow
    assert "repair/rebuild the normal runtime" in workflow
