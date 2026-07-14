"""Regression smoke for the v2.2.2.1 macOS/Linux torch pin hotfix."""

import importlib.util
import json
import ntpath
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile
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


class _OsProxy:
    def __init__(self, real_os, *, name: str):
        self._real_os = real_os
        self.name = name
        self.pathsep = ":" if name == "posix" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


def _read_utf8(path: str | Path) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


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
    audio_install_marker = 'install_with_optional_bundled_wheels "${VENV_PY}" -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}"'
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
    assert "Unsupported Torch runtime detected. STEMwerk requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime." in script
    assert 'elseif lower == "core_model_download_failed" then' in script
    assert "Core model download/cache failed during setup. Check network, FFmpeg, and model cache permissions." in script
    assert 'if trim(state.STATUS_REASON or "") ~= "core_model_download_failed" and (hasError("torch_too_new_for_demucs") or hasError("torch_runtime_unsupported")) then' in script


def test_macos_setup_runtime_messages_do_not_ship_stale_2222_version_text():
    from pathlib import Path

    shipped_scripts = [
        Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"),
        Path("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua"),
    ]

    for script_path in shipped_scripts:
        script = script_path.read_text()
        assert "STEMwerk 2.2.2.2.x requires" not in script


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
    assert "Offline bundled installer is missing a local STEMwerk-managed Python runtime payload." in script
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
    assert script.index('ACTIVE_TORCH_VERSION="${PINNED_TORCH_VERSION}"') < script.index('install_linux_torch_stack "cpu" || true')
    assert script.index('ACTIVE_TORCHVISION_VERSION="${PINNED_TORCHVISION_VERSION}"') < script.index('install_linux_torch_stack "cpu" || true')
    assert script.index('ACTIVE_TORCHAUDIO_VERSION="${PINNED_TORCHAUDIO_VERSION}"') < script.index('install_linux_torch_stack "cpu" || true')


def test_linux_bootstrap_gfx1201_requires_rx9070_or_gfx1201_device_visibility():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'if printf "%s %s\\n" "${device_names}" "${device_props}" | grep -Eiq "rx 9070|gfx1201"; then' in script
    assert 'ROCM_SELECTED_DEVICE="rx9070_gfx1201"' in script
    assert 'rocm_fail_reason="rocm_gfx1201_device_not_selected"' in script
    assert 'ROCM_DETECTED_DEVICES="${device_names}"' in script
    assert 'SELECTED_TORCH_STACK="torch==${ACTIVE_TORCH_VERSION}+$(basename "${idx}") torchvision==${ACTIVE_TORCHVISION_VERSION}+$(basename "${idx}") torchaudio==${ACTIVE_TORCHAUDIO_VERSION}+$(basename "${idx}")"' in script


def test_linux_drumsep_rocm_runtime_aligns_gfx1201_with_rocm7_main_runtime_policy():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'DRUMSEP_ROCM7_GFX1201_TORCH_VERSION="2.10.0+rocm7.0"' in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCHVISION_VERSION="0.25.0+rocm7.0"' in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCHAUDIO_VERSION="2.10.0+rocm7.0"' in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm7.0"' in script
    assert 'select_drumsep_rocm_torch_stack() {' in script
    assert 'DRUMSEP_ACTIVE_ROCM_STACK_POLICY="rocm7_gfx1201_align_main_runtime"' in script
    assert 'DRUMSEP_ACTIVE_ROCM_TORCH_VERSION="${DRUMSEP_ROCM7_GFX1201_TORCH_VERSION}"' in script
    assert 'DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL="${DRUMSEP_ROCM7_GFX1201_TORCH_INDEX_URL}"' in script
    assert 'printf "%s\\n" "${_device_names}" | grep -Eiq "rx 9070|gfx1201"' in script
    assert 'torch==${DRUMSEP_ACTIVE_ROCM_TORCH_VERSION}' in script
    assert 'torchvision==${DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION}' in script
    assert 'torchaudio==${DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION}' in script


def test_linux_setup_reports_five_top_level_steps_when_ready_runtime_runs():
    bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    launcher = Path("scripts/reaper/STEMwerk_Bootstrap_Linux_Launcher.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'STEP_TOTAL="5"' in bootstrap
    assert 'set_progress "1" "${STEP_TOTAL}" "Preparing runtime"' in bootstrap
    assert 'set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"' in bootstrap
    assert 'set_progress "3" "${STEP_TOTAL}" "Installing STEMwerk runtime"' in bootstrap
    assert 'set_progress "4" "${STEP_TOTAL}" "Checking FFmpeg"' in bootstrap
    assert 'set_progress "5" "${STEP_TOTAL}" "Preparing Drum Kit runtime"' in bootstrap
    assert 'set_status "running" "launcher_started" "1" "5" "Launching bootstrap"' in launcher
    assert 'local segment = 100 / total' in setup_internal
    assert '"3. STEMwerk runtime"' in setup_internal
    assert '"4. FFmpeg"' in setup_internal
    assert '"5. Drum Kit runtime"' in setup_internal


def test_macos_setup_reports_five_top_level_steps_for_reapack_bootstrap():
    bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'STEP_TOTAL="5"' in bootstrap
    assert 'set_progress "1" "${STEP_TOTAL}" "Preparing runtime"' in bootstrap
    assert 'set_progress "2" "${STEP_TOTAL}" "Installing Python runtime"' in bootstrap
    assert 'set_progress "3" "${STEP_TOTAL}" "Installing STEMwerk runtime"' in bootstrap
    assert 'set_progress "4" "${STEP_TOTAL}" "Checking FFmpeg"' in bootstrap
    assert 'set_progress "5" "${STEP_TOTAL}" "Preparing Drum Kit runtime"' in bootstrap
    assert 'set_progress "4" "${STEP_TOTAL}" "Finalizing setup"' not in bootstrap


def test_linux_cuda_drumsep_path_uses_shared_five_step_setup_and_stays_out_of_rocm_runtime():
    bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()
    launcher = Path("scripts/reaper/STEMwerk_Bootstrap_Linux_Launcher.sh").read_text()
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()
    drumsep_install = bootstrap.split("install_drumsep_runtime() {", 1)[1].split("\n\nresolve_core_target()", 1)[0]

    assert 'STEP_TOTAL="5"' in bootstrap
    assert 'set_status "running" "launcher_started" "1" "5" "Launching bootstrap"' in launcher
    assert 'if OS ~= "Windows" then' in setup_internal
    assert '{ id = "drumsep-runtime", accent = { 0.22, 0.62, 0.70 } }' in setup_internal
    assert '{ id = "drumsep-rocm-runtime", accent = { 0.16, 0.56, 0.78 } }' in setup_internal
    assert 'mode ~= "repair" and mode ~= "rebuild-venv" and mode ~= "drumsep-runtime" and mode ~= "drumsep-rocm-runtime" and mode ~= "ready-to-go-verify"' in setup_internal

    assert 'clear_drumsep_substep_state() {' in bootstrap
    assert 'set_drumsep_substep_progress() {' in bootstrap
    assert 'echo "DRUMSEP_STEP_INDEX=${DRUMSEP_STEP_INDEX}"' in bootstrap
    assert 'echo "DRUMSEP_STEP_TOTAL=${DRUMSEP_STEP_TOTAL}"' in bootstrap
    assert 'echo "DRUMSEP_STEP_LABEL=${DRUMSEP_STEP_LABEL}"' in bootstrap
    assert 'log "DRUMSEP STEP ${DRUMSEP_STEP_INDEX}/${DRUMSEP_STEP_TOTAL}: ${DRUMSEP_STEP_LABEL}"' in bootstrap
    assert 'if [ "${MODE}" = "drumsep-runtime" ]; then' in bootstrap
    assert '_drumsep_step_total="4"' in drumsep_install
    assert '"torch==${DRUMSEP_TORCH_VERSION}"' in drumsep_install
    assert '"torchvision==${DRUMSEP_TORCHVISION_VERSION}"' in drumsep_install
    assert 'set_drumsep_substep_progress "1" "${_drumsep_step_total}" "Creating DrumSep runtime"' in drumsep_install
    assert 'set_drumsep_substep_progress "4" "${_drumsep_step_total}" "Verifying DrumSep runtime"' in drumsep_install
    assert 'set_progress "1" "${STEP_TOTAL}" "Creating DrumSep runtime"' not in drumsep_install
    assert 'set_progress "4" "${STEP_TOTAL}" "Verifying DrumSep runtime"' not in drumsep_install
    assert 'select_drumsep_rocm_torch_stack' not in drumsep_install
    assert 'DRUMSEP_ACTIVE_ROCM_TORCH_VERSION' not in drumsep_install
    assert 'DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL' not in drumsep_install
    assert 'drumsep_rocm_runtime.env' not in drumsep_install


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
    assert "NORMAL_CPU_MAX_PARALLEL = 2" in script
    assert "local function detectLogicalCpuCount()" in script
    assert 'local h = io.popen("getconf _NPROCESSORS_ONLN 2>/dev/null")' in script
    assert "local function detectSystemRamGiB()" in script
    assert 'if OS == "Linux" then' in script
    assert "local minCpuForParallel = 8" in script
    assert "local minRamGiBForParallel = 8" in script
    assert 'if route == "normal" then' in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.NORMAL_CPU_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_normal_cpu_cap2"' in script
    assert 'return "cpu_threads_low"' in script
    assert 'return "cpu_threads_unknown"' in script
    assert 'return "cpu_ram_low"' in script
    assert 'return "cpu_ram_unknown"' in script
    assert 'policy.reason = "directml_multi_track"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_long_cap4"' in script
    assert 'timing:workers_launched count=' in script
    assert ' .. " reason=" .. tostring(multiTrackQueue.executionModeReason or multiTrackQueue.forceSequentialReason or "none")' in script


def test_gpu_scheduler_policy_defaults_to_cap4_for_capable_backends():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "NORMAL_GPU_MAX_PARALLEL = 4" in script
    assert "DKS_DIRECT_GPU_SHORT_MAX_PARALLEL = 4" in script
    assert "DKS_DIRECT_GPU_LONG_MAX_PARALLEL = 4" in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_long_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_long_cap4"' in script
    assert '"scheduler_dks_extract_stage1_normal_gpu_cap4"' in script
    assert '"scheduler_normal_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_windows_cuda_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_windows_cuda_cap2"' in script


def test_windows_cuda_scheduler_uses_cuda_state_and_directml_fallback_markers():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function schedulerRuntimeStateFile(kind)' in script
    assert 'return "drumsep_runtime_cuda.env"' in script
    assert 'return "drumsep_runtime_directml.env"' in script
    assert 'function schedulerRuntimePythonDefaultForKind(kind)' in script
    assert 'tostring(state and state.DRUMSEP_CUDA_PYTHON or "")' in script
    assert 'tostring(state and state.DRUMSEP_DIRECTML_PYTHON or "")' in script
    assert 'schedulerRuntimeStateOk(state, "DRUMSEP_CUDA_RUNTIME_STATUS", "STATUS")' in script
    assert 'or (state and state.ORT_CUDA_PROVIDER)' in script
    assert 'or explicitAvailable == "ok"' in script
    assert 'function schedulerRuntimeHasDirectmlCapability(state, runtimePython, capabilityState)' in script
    assert 'schedulerRuntimeStateOk(state, "DRUMSEP_DIRECTML_RUNTIME_STATUS", "STATUS")' in script
    assert 'return "directml", "fallback_directml"' in script
    assert 'return "directml", "explicit_directml"' in script


def test_scheduler_cuda_runtime_files_are_platform_agnostic_for_linux_dks_routes():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'if runtimeKind == "cuda" then' in script
    assert 'return schedulerRuntimePythonDefault(".venv-drumsep-cuda")' in script
    assert 'if runtimeKind == "cuda" and OS == "Windows" then' not in script


def test_runtime_scheduler_benchmark_gpu_cap_override_is_benchmark_only_and_logged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "STEMWERK_BENCH_GPU_CAP" in script
    assert "function readBenchmarkGpuCapRequest()" in script
    assert "if requested == 2 or requested == 4 or requested == 8 then" in script
    assert "function appendBenchmarkGpuCapDiagnostics(logFile)" in script
    assert "function benchmarkGpuCapIgnoredReasonForPolicy(policy)" in script
    assert "benchmarkGpuCapRequested" in script
    assert "benchmarkGpuCapApplied" in script
    assert "benchmarkGpuCapIgnoredReason" in script
    assert "if benchmarkGpuCapRequested and benchmarkGpuCapEligible then" in script
    assert "local requestedBenchmarkCap = math.floor(tonumber(benchmarkGpuCapRequested or 0) or 0)" in script
    assert "local routeAllowsBenchmarkCap = requestedBenchmarkCap <= 4" in script
    assert "and not benchmarkGpuCapRequested" in script
    assert 'schedulerPolicy.backend == "gpu"' in script
    assert "schedulerPolicy.cap >= 2" in script
    assert "directml_fixed_cap1" in script
    assert "mps_fixed_cap1" in script
    assert "scheduler_dks_direct_gpu_long_cap4" in script
    assert "cap8_normal_gpu_only" in script
    assert 'requestedBenchmarkCap == 8' in script
    assert 'and schedulerPolicy.route == "normal"' in script
    assert 'and (schedulerPolicy.stage == "" or schedulerPolicy.stage == "single_stage")' in script
    assert "not_gpu_parallel_eligible" in script
    assert "bench_gpu_cap_requested=" in script
    assert "bench_gpu_cap_applied=" in script
    assert "bench_gpu_cap_ignored_reason=" in script
    assert 'runOptions = {' in script
    assert 'workflowMode = "stems"' in script
    assert 'workflowSource = "normal"' in script
    assert 'local benchmarkWorkflowSource = tostring(multiTrackQueue.workflowSource or workflowSourceArg or "")' in script
    assert 'local benchmarkWorkflowMode = tostring(multiTrackQueue.workflowMode or workflowModeArg or "")' in script
    assert 'local benchmarkRoute = tostring(multiTrackQueue.schedulerPolicyRoute or schedulerRoute or "")' in script
    assert 'local benchmarkStage = tostring(multiTrackQueue.schedulerPolicyStage or schedulerStage or "")' in script
    assert 'local benchmarkModelName = tostring(effectiveRunModel() or (SETTINGS and SETTINGS.model) or "")' in script
    assert 'local benchmarkDevice = tostring(effectiveRunDevice() or (SETTINGS and SETTINGS.device) or "")' in script
    assert 'local benchmarkBackend = tostring(multiTrackQueue.schedulerPolicyBackend or schedulerBackend or "")' in script
    assert 'route=" .. benchmarkRoute' in script
    assert 'stage=" .. benchmarkStage' in script
    assert 'model_name=" .. benchmarkModelName' in script
    assert 'backend=" .. benchmarkBackend' in script
    assert 'local f = io.open(logFile, "a")' in script
    assert "appendBenchmarkGpuCapDiagnostics(logFile)" in script
    assert "_sep.ensureBenchmarkGpuCapDiagnosticsPersisted = function(logFile)" in script
    assert 'local hasGpu = content:find("bench_gpu_cap_requested=", 1, true) ~= nil' in script
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
    assert 'setWorkflowContextForRun(runOptions)' in script
    assert 'workflow_source=" .. benchmarkWorkflowSource' in script
    assert 'workflow_mode=" .. benchmarkWorkflowMode' in script
    assert 'device=" .. benchmarkDevice' in script


def test_runtime_scheduler_benchmark_mps_cap_override_is_benchmark_only_stage_aware_and_logged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "STEMWERK_BENCH_MPS_CAP" in script
    assert "STEMWERK_BENCH_DKS_STAGE1_MPS_CAP" in script
    assert "function readBenchmarkMpsCapRequest(envName)" in script
    assert "function readBenchmarkMpsCapRequestForPolicy(route, stage)" in script
    assert 'return stageRequested, stageRaw, "STEMWERK_BENCH_DKS_STAGE1_MPS_CAP"' in script
    assert 'return globalRequested, globalRaw, "STEMWERK_BENCH_MPS_CAP"' in script
    assert "function benchmarkMpsCapIgnoredReasonForPolicy(policy, requestedParallel)" in script
    assert 'return "parallel_not_requested"' in script
    assert 'return "directml_not_mps"' in script
    assert 'return backend == "" and "backend_unknown" or "backend_not_mps"' in script
    assert "function applyBenchmarkMpsCapToPolicy(policy, opts)" in script
    assert 'policy.reason = "bench_mps_cap" .. tostring(requestedCap)' in script
    assert 'policy.reason = "bench_dks_stage1_mps_cap" .. tostring(requestedCap)' in script
    assert "benchmarkMpsCapRequested" in script
    assert "benchmarkMpsCapApplied" in script
    assert "benchmarkMpsCapIgnoredReason" in script
    assert "benchmarkMpsCapEnv" in script
    assert "bench_mps_cap_requested=" in script
    assert "bench_mps_cap_applied=" in script
    assert "bench_mps_cap_ignored_reason=" in script
    assert "bench_dks_stage1_mps_cap_requested=" in script
    assert "bench_dks_stage1_mps_cap_applied=" in script
    assert "bench_dks_stage1_mps_cap_ignored_reason=" in script
    assert 'local hasMps = content:find("bench_mps_cap_requested=", 1, true) ~= nil' in script
    assert "appendBenchmarkMpsCapDiagnostics(logFile)" in script


def test_runtime_scheduler_benchmark_cpu_cap_override_is_cpu_only_stage_aware_and_logged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "STEMWERK_BENCH_CPU_CAP" in script
    assert "STEMWERK_BENCH_DKS_STAGE1_CPU_CAP" in script
    assert "function readBenchmarkCpuCapRequest(envName)" in script
    assert "function readBenchmarkCpuCapRequestForPolicy(route, stage)" in script
    assert 'if policyRoute == "dks_extract" and policyStage == "stage1_normal" then' in script
    assert 'return stageRequested, stageRaw, "STEMWERK_BENCH_DKS_STAGE1_CPU_CAP"' in script
    assert 'return globalRequested, globalRaw, "STEMWERK_BENCH_CPU_CAP"' in script
    assert "function benchmarkCpuCapIgnoredReasonForPolicy(policy, cpuCount, ramGiB, requestedParallel)" in script
    assert 'return "parallel_not_requested"' in script
    assert 'return backend == "" and "backend_unknown" or "backend_not_cpu"' in script
    assert 'return "directml_fixed_cap1"' in script
    assert 'return "mps_fixed_cap1"' in script
    assert "function applyBenchmarkCpuCapToPolicy(policy, opts)" in script
    assert 'return requestedCap, rawCap, appliedCap, "invalid_request", envName' not in script
    assert 'if requestedCap == 4 then' in script
    assert 'return requestedCap, rawCap, appliedCap, "cpu_threads_unknown_for_cap4", envName' in script
    assert 'return requestedCap, rawCap, appliedCap, "cpu_threads_low_for_cap4", envName' in script
    assert 'return requestedCap, rawCap, appliedCap, "cpu_ram_unknown_for_cap4", envName' in script
    assert 'return requestedCap, rawCap, appliedCap, "cpu_ram_low_for_cap4", envName' in script
    assert 'policy.reason = "bench_cpu_cap" .. tostring(requestedCap)' in script
    assert "benchmarkCpuCapRequested" in script
    assert "benchmarkCpuCapApplied" in script
    assert "benchmarkCpuCapIgnoredReason" in script
    assert "benchmarkCpuCapEnv" in script
    assert "bench_cpu_cap_requested=" in script
    assert "bench_cpu_cap_applied=" in script
    assert "bench_cpu_cap_ignored_reason=" in script
    assert "workflow_mode=" in script
    assert 'and not benchmarkCpuCapRequested' in script
    assert "_sep.ensureBenchmarkGpuCapDiagnosticsPersisted = function(logFile)" in script
    assert 'local hasCpu = content:find("bench_cpu_cap_requested=", 1, true) ~= nil' in script


def test_scheduler_policy_cpu_override_slice_keeps_default_normal_cpu_cap2_without_env():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'policy.reason = "scheduler_normal_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_unknown_backend_conservative"' in script
    assert 'local benchmarkCpuCapRequested, benchmarkCpuCapRaw, benchmarkCpuCapApplied, benchmarkCpuCapIgnoredReason, benchmarkCpuCapEnv =' in script
    assert "applyBenchmarkCpuCapToPolicy(schedulerPolicy" in script


def test_drumsep_cpu_fallback_scheduler_prediction_is_logged_and_uses_cpu_policy():
    script = _read_utf8("scripts/reaper/STEMwerk.lua")
    support = _read_utf8("scripts/reaper/STEMwerk_Save_Support_Bundle.lua")

    assert "function predictDrumsepSchedulerRuntime(requestedDevice, route, modelName)" in script
    assert 'if policyRoute == "dks_direct" then' in script
    assert 'return "mps", "explicit_mps_direct_demix"' in script
    assert 'return "mps", "auto_mps_direct_demix"' in script
    assert 'return "cpu", "fallback_cpu"' in script
    assert 'return "rocm", "explicit_rocm"' in script
    assert 'return "rocm", "auto_prefer_rocm"' in script
    assert 'return "rocm", "gpu_prefer_rocm"' in script
    assert 'return "cuda", "bench_helper_cuda"' in script
    assert 'return "cpu", "bench_helper_cuda_fallback_cpu"' in script
    assert 'return "cuda", "explicit_cuda"' in script
    assert 'return "cuda", "auto_prefer_cuda"' in script
    assert 'return "directml", "explicit_directml"' in script
    assert 'return "directml", "fallback_directml"' in script
    assert 'drumsepSchedulerBackend, drumsepSchedulerPolicy = predictDrumsepSchedulerRuntime(' in script
    assert "            requestedStage2ModelArg\n        )" in script
    assert 'isDrumKitMultiRun and schedulerRoute == "dks_direct"' in script
    assert 'drumsepSchedulerUsesCpuFallback = drumsepSchedulerBackend == "cpu"' in script
    assert 'drumsepSchedulerPolicy == "fallback_cpu"' in script
    assert 'drumsepSchedulerPolicy == "bench_helper_cuda_fallback_cpu"' in script
    assert 'if drumsepSchedulerUsesCpuFallback then' in script
    assert 'schedulerBackend = "cpu"' in script
    assert 'schedulerPolicy.reason = schedulerPolicy.sequentialMode' in script
    assert '"scheduler_dks_direct_drumsep_cpu_fallback_cap1"' in script
    assert '"scheduler_dks_extract_drumsep_cpu_fallback_cap1"' in script
    assert '"scheduler_dks_direct_drumsep_cpu_fallback_cap" .. tostring(schedulerPolicy.cap or 1)' in script
    assert '"scheduler_dks_extract_drumsep_cpu_fallback_cap" .. tostring(schedulerPolicy.cap or 1)' in script
    assert 'multiTrackQueue.drumsepSchedulerBackend = drumsepSchedulerBackend' in script
    assert 'multiTrackQueue.drumsepSchedulerPolicy = drumsepSchedulerPolicy' in script
    assert 'multiTrackQueue.drumsepSchedulerUsesCpuFallback = drumsepSchedulerUsesCpuFallback and "yes" or "no"' in script
    assert 'drumsepStage2SchedulerBackend = select(1, predictDrumsepSchedulerRuntime(' in script
    assert 'drumsep_scheduler_backend=' in script
    assert 'drumsep_scheduler_policy=' in script
    assert 'drumsep_scheduler_uses_cpu_fallback=' in script
    assert '"drumsep_scheduler_backend", "drumsep_scheduler_policy", "drumsep_scheduler_uses_cpu_fallback"' in support


def test_drumsep_benchmark_helper_device_override_is_probe_only_and_scheduler_visible():
    script = _read_utf8("scripts/reaper/STEMwerk.lua")
    process = _read_utf8("scripts/reaper/audio_separator_process.py")
    helper = _read_utf8("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    support = _read_utf8("scripts/reaper/STEMwerk_Save_Support_Bundle.lua")

    assert 'os.getenv("STEMWERK_BENCH_DRUMSEP_HELPER_DEVICE")' in script
    assert 'return "rocm", "bench_helper_rocm"' in script
    assert 'return "rocm", "auto_prefer_rocm"' in script
    assert 'return "cuda", "bench_helper_cuda"' in script
    assert 'return "cpu", "bench_helper_cuda_fallback_cpu"' in script
    assert 'drumsepSchedulerPolicy == "bench_helper_rocm"' in script
    assert 'multiTrackQueue.benchDrumsepHelperDeviceApplied = tostring(benchDrumsepHelperDevice or "")' in script
    assert 'drumsepSchedulerPolicy == "bench_helper_cuda"' in script
    assert 'drumsepSchedulerPolicy == "bench_helper_cuda_fallback_cpu"' in script
    assert 'multiTrackQueue.benchDrumsepHelperDeviceApplied = "cuda"' in script
    assert 'multiTrackQueue.benchDrumsepHelperDeviceApplied = "fallback_cpu"' in script
    assert 'multiTrackQueue.benchDrumsepHelperDeviceApplied = "none"' in script
    assert 'schedulerBackend = "gpu"' in script
    assert 'BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV = "STEMWERK_BENCH_DRUMSEP_HELPER_DEVICE"' in process
    assert 'return "cpu", "not_requested"' in process
    assert 'require_cuda=True' in process
    assert 'route="direct-demix" if use_direct_demix else "wrapper"' in process
    assert 'device=direct_demix_device if use_direct_demix else helper_device' in process
    assert 'def _probe_gpu_device(device: str)' in helper
    assert 'choices=["cpu", "cuda", "rocm", "mps", "directml"]' in helper
    assert '"drumsep_helper_gpu_probe_status"' in support


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
    assert "Normal stems benchmark matrix (GPU cap 2 / 4 / 8)" in doc
    assert "STEMWERK_BENCH_GPU_CAP=8" in doc
    assert "experimental high-throughput benchmark only" in doc


def test_scheduler_policy_route_backend_defaults_are_explicit():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "NORMAL_GPU_MAX_PARALLEL = 4" in script
    assert "NORMAL_CPU_MAX_PARALLEL = 2" in script
    assert "NORMAL_DIRECTML_MAX_PARALLEL = 1" in script
    assert "NORMAL_MPS_MAX_PARALLEL = 2" in script
    assert "DKS_DIRECT_GPU_SHORT_MAX_PARALLEL = 4" in script
    assert "DKS_DIRECT_GPU_LONG_MAX_PARALLEL = 4" in script
    assert "DKS_DIRECT_CPU_MAX_PARALLEL = 2" in script
    assert "DKS_EXTRACT_STAGE2_MAX_PARALLEL = 4" in script
    assert 'if route == "dks_direct" then' in script
    assert 'schedulerRoute = "dks_direct"' in script
    assert 'schedulerRoute = "dks_extract"' in script
    assert 'schedulerStage = "stage1_normal"' in script
    assert 'and hasRuntimeBackendType("mps")' in script
    assert 'schedulerBackend = "mps"' in script
    assert 'schedulerBackend = "cpu"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_long_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_long_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_windows_cuda_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_unknown_cap1"' in script
    assert '"scheduler_dks_direct_" .. cpuParallelFallbackReason() .. "_cap1"' in script
    assert '"scheduler_dks_extract_stage1_normal_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_windows_cuda_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_cpu_cap2"' in script
    assert '"scheduler_dks_extract_stage1_normal_" .. cpuParallelFallbackReason() .. "_cap1"' in script
    assert '"scheduler_normal_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_normal_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_normal_mps_cap2"' in script
    assert 'policy.reason = "scheduler_mps_conservative"' in script
    assert 'policy.reason = "scheduler_unknown_backend_conservative"' in script
    assert 'benchmarkGpuCapIgnoredReason = requestedBenchmarkCap == 8 and "cap8_normal_gpu_only" or "invalid_request"' in script
    assert 'scheduler_policy_route=' in script
    assert 'scheduler_policy_backend=' in script
    assert 'scheduler_policy_cap=' in script
    assert 'lua_dks_scheduler_policy_route=' in script


def test_normal_cpu_policy_cap2_slice_keeps_other_backend_caps_unchanged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'if backend == "cpu" then' in script
    assert 'if route == "normal" then' in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.NORMAL_CPU_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_normal_cpu_cap2"' in script
    assert 'if backend == "directml" then' in script
    assert 'if route == "dks_direct" then' in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.DKS_DIRECT_GPU_SHORT_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_directml_long_cap4"' in script
    assert 'policy.cap = _sep.SCHEDULER_POLICY.NORMAL_DIRECTML_MAX_PARALLEL' in script
    assert 'if backend == "mps" then' in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.NORMAL_MPS_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_normal_mps_cap2"' in script
    assert 'policy.cap = _sep.SCHEDULER_POLICY.NORMAL_MPS_MAX_PARALLEL' in script
    assert 'policy.reason = "scheduler_mps_conservative"' in script
    assert 'if route == "dks_direct" then' in script
    assert 'policy.cap = _sep.SCHEDULER_POLICY.DKS_DIRECT_CPU_MAX_PARALLEL' in script
    assert 'policy.reason = "scheduler_dks_direct_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_unknown_backend_conservative"' in script
    assert 'schedulerPolicy.backend == "gpu"' in script
    assert "not_gpu_parallel_eligible" in script


def test_normal_mps_scheduler_cap2_slice_preserves_parallel_launch_limiter():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'if backend == "mps" then' in script
    assert 'if route == "normal" then' in script
    assert 'policy.sequentialMode = false' in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.NORMAL_MPS_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_normal_mps_cap2"' in script
    assert 'multiTrackQueue.parallelJobLimit = (not multiTrackQueue.sequentialMode) and schedulerPolicy.cap or nil' in script
    assert 'launchCount = math.min(#trackJobs, multiTrackQueue.parallelJobLimit)' in script
    assert '"timing:workers_launched count=" .. tostring(#trackJobs)' in script
    assert ' .. " mode=" .. (multiTrackQueue.sequentialMode and "sequential" or "parallel")' in script
    assert ' .. " cap=" .. tostring(multiTrackQueue.parallelJobLimit or "none")' in script


def test_normal_auto_mps_slice_prefers_mps_without_changing_dks_routes():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'if string.lower(tostring(effectiveRunDevice() or "")) == "auto"' in script
    assert 'and hasRuntimeBackendType("mps")' in script
    assert 'if schedulerRoute == "normal" or schedulerRoute == "dks_extract" then' in script
    assert 'schedulerBackend = "mps"' in script
    assert 'schedulerBackend = "cpu"' in script
    assert 'if isDrumKitMultiRun and workflowSourceArg == "dks_direct" then' in script
    assert 'elseif isDrumKitMultiRun and workflowSourceArg == "dks_extract" then' in script


def test_dks_extract_mps_scheduler_markers_match_actual_parent_policy():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert 'requestedDevice = effectiveRunDevice()' in script
    assert 'elseif route == "dks_extract" and tostring(opts.requestedDevice or ""):lower() == "auto" then' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_mps_cap2"' in script
    assert 'elseif route == "dks_extract" then' in script
    assert 'policy.cap = 1' in script
    assert 'policy.reason = "scheduler_dks_extract_mps_sequential"' in script
    assert 'multiTrackQueue.parallelJobLimit = (not multiTrackQueue.sequentialMode) and schedulerPolicy.cap or nil' in script
    assert ' .. " cap=" .. tostring(multiTrackQueue.parallelJobLimit or "none")' in script


def test_drumkit_cpu_default_policy_applies_cap2_only_when_safety_gate_passes():
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    assert "local function cpuParallelAllowed()" in script
    assert "local function cpuParallelFallbackReason()" in script
    assert 'policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.DKS_DIRECT_CPU_MAX_PARALLEL)' in script
    assert 'policy.reason = "scheduler_dks_direct_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_cpu_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_" .. cpuParallelFallbackReason() .. "_cap1"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_" .. cpuParallelFallbackReason() .. "_cap1"' in script


def test_drumkit_stage2_cpu_default_stays_cap1_without_benchmark_override(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_CPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", raising=False)

    with module._dks_extract_stage2_lock(tmp_path, "cpu"):
        pass
    captured = capsys.readouterr()
    assert "bench_cpu_cap_requested=unset" in captured.err
    assert "bench_cpu_cap_applied=1" in captured.err
    assert "bench_cpu_cap_ignored_reason=not_requested" in captured.err
    assert "dks_extract_stage2_effective_cap=1" in captured.err
    assert "lua_dks_extract_stage2_concurrency_cap=1" in captured.err


def test_drumkit_stage2_gpu_default_policy_uses_cap4_without_benchmark_override(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_CPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", raising=False)

    with module._dks_extract_stage2_lock(tmp_path, "rocm"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_cap_requested=unset" in captured.err
    assert "bench_dks_stage2_cap_applied=4" in captured.err
    assert "bench_dks_stage2_cap_ignored_reason=not_requested" in captured.err
    assert "dks_extract_stage2_effective_cap=4" in captured.err
    assert "lua_dks_extract_stage2_concurrency_cap=4" in captured.err


def test_normal_workflow_provenance_is_explicit_in_lua_summary_and_python_stderr():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    py_script = Path("scripts/reaper/audio_separator_process.py").read_text()

    assert 'runOptions = {' in main_script
    assert 'workflowMode = "stems"' in main_script
    assert 'workflowSource = "normal"' in main_script
    assert 'local schedulerRoute = "normal"' in main_script
    assert 'local schedulerStage = "single_stage"' in main_script
    assert 'route=" .. benchmarkRoute' in main_script
    assert 'stage=" .. benchmarkStage' in main_script
    assert 'model_name=' in main_script
    assert 'device=' in main_script
    assert 'backend=' in main_script
    assert 'workflow_source=" .. benchmarkWorkflowSource' in main_script
    assert 'workflow_mode=" .. benchmarkWorkflowMode' in main_script
    assert 'model_name=" .. benchmarkModelName' in main_script
    assert 'backend=" .. benchmarkBackend' in main_script
    assert 'def _resolve_normal_workflow_backend(selected_device: Optional[str]) -> str:' in py_script
    assert 'print(f"workflow_source={workflow_source}", file=sys.stderr)' in py_script
    assert 'print(f"workflow_mode={workflow_mode}", file=sys.stderr)' in py_script
    assert 'print(f"route={route}", file=sys.stderr)' in py_script
    assert 'print(f"stage={stage}", file=sys.stderr)' in py_script
    assert 'print(f"model_name={run_model}", file=sys.stderr)' in py_script
    assert 'print(f"device={resolved_device}", file=sys.stderr)' in py_script
    assert 'print(f"backend={backend}", file=sys.stderr)' in py_script


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
    assert 'local base = sanitizeFriendlyName(dev.fullName or dev.name or dev.id) or ""' in script
    assert 'base = sanitizeFriendlyName(dev.name or dev.id) or ""' in script


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
    setup_internal = _read_utf8("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")

    assert "local staleFailedVerification = (" in setup_internal
    assert "and verification == \"failed\"" in setup_internal
    assert "if staleFailedVerification then" in setup_internal
    assert "verification = \"\"" in setup_internal


def test_windows_setup_overview_ignores_stale_running_and_failed_bootstrap_state_when_ready_is_ok():
    setup_internal = _read_utf8("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")

    assert 'local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"' in setup_internal
    assert 'local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"' in setup_internal
    assert 'local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)' in setup_internal
    assert 'local readyHealthy = (' in setup_internal
    assert 'trim(readyState.READY_TO_GO_STATUS or "") == "ok"' in setup_internal
    assert 'trim(readyState.MAIN_RUNTIME_STATUS or "") == "ok"' in setup_internal
    assert 'local staleRunning = (status == "running") and (not pid) and (not guardBusy) and readyHealthy' in setup_internal
    assert 'local staleGuardFailed = (trim(guard.STATUS or "") == "failed") and readyHealthy and bootstrapComplete and (not guardBusy)' in setup_internal
    assert 'local staleFailedState = (status ~= "" and status ~= "ok" and status ~= "running") and readyHealthy and bootstrapComplete' in setup_internal
    assert 'if staleRunning or staleGuardFailed or staleFailedState then' in setup_internal
    assert 'status = "ok"' in setup_internal
    assert 'reason = ""' in setup_internal


def test_windows_setup_overview_labels_unchecked_deps_and_keeps_homebrew_ffmpeg_guidance_off_windows():
    setup_internal = _read_utf8("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")

    assert 'if v == "" or v == "not_checked" then deps[k] = "not checked" end' in setup_internal
    assert 'verification = verification ~= "" and verification or "not checked"' in setup_internal
    assert 'if OS == "macOS" and (hasError("ffmpeg_missing") or hasError("ffmpeg_unusable") or trim(state.STATUS or "") == "missing_ffmpeg") then' in setup_internal


def test_setup_language_hover_uses_change_language_tooltip_with_right_click_hint():
    ui_controls = _read_utf8("scripts/reaper/_internal/STEMwerk_UI_Controls.lua")

    assert 'ctx.tooltipText = T("tooltip_change_language") or (T("tooltip_change_language") or "Change language. Right-click: toggle tooltips.")' in ui_controls
    assert 'tooltipText = T("tooltip_change_language") or "Change language. Right-click: toggle tooltips."' in ui_controls
    assert 'tooltipText = T("tooltip_change_language") or (T("tooltip_change_language") or "Change language. Right-click: toggle tooltips.")' in ui_controls


def test_tooltip_lang_strings_keep_23_0_2_right_click_hint_compatibility():
    script_lang = _read_utf8("scripts/reaper/i18n/languages.lua")
    root_lang = _read_utf8("i18n/languages.lua")

    for text in (script_lang, root_lang):
        assert 'tooltip_lang = "Change language. Right-click: toggle tooltips.",' in text
        assert 'tooltip_lang = "Taal wijzigen. Rechtsklik: tooltips aan/uit.",' in text
        assert 'tooltip_lang = "Sprache wechseln. Rechtsklick: Tooltips ein/aus.",' in text


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

    assert "function reconcileCheckVerification(state, capState, readyState, verification, envJson, deviceNames, backend, backendReason, logFile)" in setup_internal
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


def test_setup_internal_writes_drumsep_policy_capabilities():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")

    assert 'f:write("DRUMSEP_STATUS=" .. tostring(data.drumsepStatus or "") .. "\\n")' in setup_internal
    assert 'f:write("DKS_SUPPORTED=" .. tostring(data.dksSupported or "") .. "\\n")' in setup_internal
    assert 'f:write("NORMAL_STEMS_SUPPORTED=" .. tostring(data.normalStemsSupported or "") .. "\\n")' in setup_internal
    assert "function resolveDrumsepPolicyState(readyState, profile, backend)" in setup_internal
    assert 'drumsepStatus = "unsupported_mac_intel"' in setup_internal
    assert 'dksSupported = drumsepStatus == "unsupported_mac_intel" and "false" or "true"' in setup_internal
    assert 'normalStemsSupported = "true"' in setup_internal
    assert 'drumsepStatus = drumsepStatus,' in setup_internal
    assert 'dksSupported = dksSupported,' in setup_internal
    assert 'normalStemsSupported = normalStemsSupported,' in setup_internal


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


def test_verify_only_prefers_current_macos_ffmpeg_and_python_over_stale_bootstrap_values():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local function resolveVerifyOnlyPythonPath(runtime, state, capState)" in setup_internal
    assert "local function resolveVerifyOnlyFfmpegPath(state, capState)" in setup_internal
    assert 'capState.FFMPEG_PATH or ""' in setup_internal
    assert "resolveUnixFfmpegFallback()" in setup_internal
    assert "local effectiveState = buildVerifyOnlyState(runtime, state, capState, readyState)" in setup_internal
    assert "local verification = verifyRuntimePaths(effectiveState)" in setup_internal


def test_verify_only_uses_ready_to_go_health_to_avoid_stale_macos_runtime_failures():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local function readyStateIndicatesHealthyRuntime(readyState, capState)" in setup_internal
    assert 'trim(readyState.READY_TO_GO_STATUS or "") == "ok"' in setup_internal
    assert 'trim(readyState.MAIN_RUNTIME_STATUS or "") == "ok"' in setup_internal
    assert "local canAcceptMacReadyHealthyState = (" in setup_internal
    assert 'result.runtimeVerifyDetail = "not_checked"' in setup_internal


def test_torch_probe_failures_are_not_labeled_unsupported_without_specific_version_drift():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'elseif result.driftReason == "torch_import_failed" or result.driftReason == "torch_runtime_probe_failed" then' in setup_internal
    assert 'result.error = "torch_runtime_probe_failed"' in setup_internal
    assert 'if lower == "torch_runtime_probe_failed" then return "Torch runtime was not re-verified during this check; current ready-to-go state remains authoritative" end' in setup_internal


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
    offline_payload_missing = "Offline bundled installer is missing a local STEMwerk-managed Python runtime payload."
    unsupported = "STEMwerk managed Python is not available for this platform yet."
    sha_failure = "Managed Python download failed verification and was not installed."
    assert linux_script.index("Attempting STEMwerk-managed Python runtime acquisition") < linux_script.index(download_failure)
    assert mac_script.index("Attempting STEMwerk-managed Python runtime acquisition") < mac_script.index(download_failure)
    assert unsupported in linux_script
    assert unsupported in mac_script
    assert offline_payload_missing in mac_script
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
    assert "scripts/reaper/i18n/languages.lua" in index
    assert "scripts/reaper/i18n/stemwerk_language_wrapper.lua" in index


def test_intel_mac_drumsep_policy_blocks_dks_before_runtime_setup():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local function intelMacDrumsepUnsupported()' in main_script
    assert 'return OS == "macOS" and (ARCH == "x86_64" or ARCH == "amd64")' in main_script
    assert 'trSafeValue("drumsep_intel_mac_unsupported_title", "Drum Kit Split unavailable on Intel Mac")' in main_script
    assert '"drumsep_intel_mac_unsupported_body",' in main_script
    assert 'if isDrumKitWorkflow and intelMacDrumsepUnsupported() then' in main_script
    assert 'showIntelMacDrumsepUnsupportedMessage()' in main_script
    assert main_script.index('if isDrumKitWorkflow and intelMacDrumsepUnsupported() then') < main_script.index('if isDirectDKS then')


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


def test_windows_path_helper_normalizes_local_drive_paths_without_breaking_unc_or_extended_prefixes():
    lua_script = r"""
local helper = dofile("scripts/reaper/_internal/STEMwerk_Path_Helper.lua")
print(helper.normalizeWindowsPath([[C:\Users\Ferro\AppData\Roaming\REAPER\Scripts\STEMwerk-reaper\_bundled\python\\python-3.11.8-amd64.exe]]))
print(helper.normalizeWindowsPath([[C:\\Users\\Ferro\\AppData\\Local\\STEMwerk\\.venv\\Scripts\\python.exe]]))
print(helper.normalizeWindowsPath([[\\server\share\\STEMwerk\\models\\]]))
print(helper.normalizeWindowsPath([[\\?\C:\Users\Ferro\\STEMwerk\\python\\python.exe]]))
"""
    proc = subprocess.run(
        ["lua", "-"],
        input=lua_script,
        text=True,
        capture_output=True,
        check=True,
        cwd=Path(__file__).resolve().parents[1],
    )
    lines = proc.stdout.splitlines()

    assert lines[0] == r"C:\Users\Ferro\AppData\Roaming\REAPER\Scripts\STEMwerk-reaper\_bundled\python\python-3.11.8-amd64.exe"
    assert lines[1] == r"C:\Users\Ferro\AppData\Local\STEMwerk\.venv\Scripts\python.exe"
    assert lines[2] == r"\\server\share\STEMwerk\models"
    assert lines[3] == r"\\?\C:\Users\Ferro\STEMwerk\python\python.exe"


def test_windows_setup_internal_normalizes_windows_runtime_paths_before_safety_checks():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert "local function normalizePlatformPath(path, preserveTrailing)" in script
    assert 'if OS == "Windows" and PATH_HELPER and PATH_HELPER.normalizeWindowsPath then' in script
    assert 'return PATH_HELPER.normalizeWindowsPath(value, { preserveTrailing = preserveTrailing == true })' in script
    assert 'local canon = normalizePathForSafety(raw)' in script
    assert 'if OS == "Windows" then' in script
    assert "return canon, nil" in script


def test_windows_repair_and_rebuild_menu_actions_launch_bootstrap_instead_of_verify_only():
    script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'elseif chosen == "repair" or chosen == "rebuild-venv" or chosen == "drumsep-runtime" or chosen == "drumsep-cuda-runtime" or chosen == "drumsep-rocm-runtime" or chosen == "drumsep-directml-runtime" then' in script
    assert 'if OS == "Windows" then\n                startWindowsSetup(runtime, separatorScript, chosen, true)' in script


def test_windows_bootstrap_normalizes_bundled_python_and_ffmpeg_paths():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    installer = Path("installer/windows/STEMwerk_Installer_Windows.ps1").read_text(encoding="utf-8")

    assert "function Normalize-WindowsPath" in windows_bootstrap
    assert "function Join-NormalizedWindowsPath" in windows_bootstrap
    assert '$bundledPythonInstaller = Join-NormalizedWindowsPath $bundledRuntimeDir @("python", $pythonInstallerFileName)' in windows_bootstrap
    assert '$bundledFfmpegZip = Join-NormalizedWindowsPath $bundledRuntimeDir @("ffmpeg", $ffmpegArchiveFileName)' in windows_bootstrap
    assert '$StateFile = Normalize-WindowsPath $StateFile' in windows_bootstrap
    assert '$LogFile = Normalize-WindowsPath $LogFile' in windows_bootstrap
    assert "function Normalize-WindowsPath" in installer
    assert '$RuntimeBase = Normalize-WindowsPath $RuntimeBase' in installer


def test_system_helper_resolves_path_separator_without_caller_global():
    from pathlib import Path

    script = Path("scripts/reaper/_internal/STEMwerk_System.lua").read_text()
    setup_script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text()

    assert 'local SYSTEM_PATH_SEP = rawget(_G, "PATH_SEP")' in script
    assert 'or ((package.config and package.config:sub(1, 1)) or (SYSTEM_OS == "Windows" and "\\\\" or "/"))' in script
    assert 'local function currentPathSep()' in script
    assert 'return a .. currentPathSep() .. b' in script
    assert 'I18N = dofile(RAW_SCRIPT_DIR .. "STEMwerk_I18N.lua")' in setup_script


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
    assert 'pip_install_with_scope main "${VENV_PY}" --no-deps "${PACKAGE}"' in script
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


def test_linux_repair_skips_torch_pin_reapply_after_successful_same_run_install():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'TORCH_STACK_INSTALLED_THIS_RUN=0' in script
    assert 'if verify_current_torch_stack "${VENV_PY}" "${BACKEND}" "before_reapply"; then' in script
    assert 'if [ "${TORCH_STACK_INSTALLED_THIS_RUN}" = "1" ]; then' in script
    assert 'TORCH_PIN_REAPPLY_REASON="already_installed_this_run"' in script
    assert 'log_step "torch_pin_reapply_skipped=already_installed_this_run"' in script
    assert 'TORCH_PIN_REAPPLY_REASON="current_stack_already_matches_requested_pin"' in script
    assert 'log_step "torch_pin_reapply_skipped=current_stack_already_matches_requested_pin"' in script
    assert 'TORCH_PIN_REAPPLY_REASON="current_stack_verify_failed"' in script
    assert 'log_stage "Re-applying pinned torch stack"' in script
    assert script.index('torch_pin_reapply_skipped=already_installed_this_run') < script.index('log_stage "Re-applying pinned torch stack"')


def test_linux_torch_stack_verify_helper_checks_backend_and_all_three_packages():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert "verify_current_torch_stack()" in script
    assert "import torchvision" in script
    assert "import torchaudio" in script
    assert 'if core(torchvision_ver) != expected_torchvision:' in script
    assert 'if expected_backend == "rocm" and (hip is None or str(hip) == ""):' in script
    assert 'if expected_backend == "cuda" and (cuda is None or str(cuda) == ""):' in script
    assert 'log_step "torch_stack_verify_after_install=ok context=${_label} detail=${_probe}"' in script
    assert 'log_step "torch_stack_verify_after_install=failed context=${_label} detail=${_probe}"' in script


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

    assert 'pip_install_with_scope main "${VENV_PY}" --no-deps "${PACKAGE}"' in script
    assert "verify_audio_separator_runtime_deps || audio_install_rc=1" in script
    assert 'log_step "audio-separator runtime dependencies incomplete; attempting full dependency repair install"' in script
    assert 'audio_repair_attempted=1' in script
    assert 'PACKAGE="audio-separator==0.23.0"' in script
    assert 'if [ "${audio_repair_rc}" -eq 0 ]; then' in script
    assert "verify_audio_separator_runtime_deps || audio_repair_rc=1" in script
    assert "AUDIO_SEPARATOR_DEPS_COMPLETE=\"no\"" in script
    assert "BACKEND_DEPS_COMPLETE=\"no\"" in script
    assert "audio_separator_dep_import_failed:" in script
    assert script.index('pip_install_with_scope main "${VENV_PY}" --no-deps "${PACKAGE}"') < script.index("verify_audio_separator_runtime_deps || audio_install_rc=1")
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
    assert "checks_data = {}" in script
    assert "DIRECT_DKS_MODEL_DEAD_CKPT_URL" in script
    assert "DIRECT_DKS_MODEL_MIRROR_CKPT_URL" in script
    assert "def _preferred_direct_dks_asset_url(" in script
    assert "def _normalize_direct_dks_asset_map(" in script
    assert "def _direct_dks_yaml_filename(" in script
    assert "def _direct_dks_assets_ready(" in script
    assert "def _validate_direct_dks_yaml(" in script
    assert "def _download_direct_dks_assets(" in script
    assert "def _is_known_drumsep_runtime_unsupported_error(exc: Exception, traceback_text: str, model_name: str) -> bool:" in script
    assert "def _emit_direct_dks_runtime_unsupported_markers(" in script
    assert 'print("error_stage=stage2_model_load", file=sys.stderr)' in script
    assert 'print("error_reason=drumsep_model_runtime_unsupported", file=sys.stderr)' in script
    assert "audio_separator mdxc loader missing expected config field 'model'" in script
    assert 'print(f"drumsep_cache_source={url}", file=sys.stderr)' in script
    assert 'print(f"drumsep_cache_error={filename}|{url}|{type(exc).__name__}: {exc}", file=sys.stderr)' in script
    assert 'print(f"yaml_path={yaml_path}", file=sys.stderr)' in script
    assert 'print(f"yaml_source={yaml_source or \'unknown\'}", file=sys.stderr)' in script
    assert 'print(f"yaml_top_level_keys={\',\'.join(top_keys)}", file=sys.stderr)' in script
    assert 'print("expected_schema=audio,model,training", file=sys.stderr)' in script
    assert 'print("drumsep_model_files_ready=yes", file=sys.stderr)' in script
    assert "resolved_model=" in script
    assert "Direct Drum Kit Split route detected: workflow_mode=" in script
    assert "workflow_source=" in script
    assert "DRUMSEP_RUNTIME_DIRNAME = \".venv-drumsep\"" in script
    assert "DRUMSEP_RUNTIME_ROCM_DIRNAME = \".venv-drumsep-rocm\"" in script
    assert "DRUMSEP_RUNTIME_GUIDANCE = \"Run Setup/Repair Drum Kit Split runtime.\"" in script
    assert "def _drumsep_runtime_python_path(" in script
    assert "def _main_runtime_python_path(" in script
    assert "def _macos_ready_drumsep_main_runtime_candidates(" in script
    assert "DRUMSEP_READY_RUNTIME_STATUS" in script
    assert "DRUMSEP_READY_MODEL_STATUS" in script
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
    assert "_direct_dks_preflight_check(" in script
    assert "runtime_info=runtime_info" in script
    assert after_direct_route.index("drumsep_python, runtime_kind, runtime_info = _select_drumsep_runtime(device_preference)") < after_direct_route.index("_direct_dks_preflight_check(")
    assert "drumsep_runtime_selection_policy=explicit_cpu" in script
    assert 'selection_policy = "gpu_prefer_rocm" if normalized_request == "gpu" else "auto_prefer_rocm"' in script
    assert "drumsep_runtime_selection_policy=explicit_cuda" in script
    assert 'cuda_selection_policy = "gpu_prefer_cuda" if normalized_request == "gpu" else "auto_prefer_cuda"' in script
    assert "normalized_device_request=" in script
    assert 'info["selection_policy"] = "fallback_cpu"' in script
    assert after_direct_route.index("_direct_dks_preflight_check(") < after_direct_route.index("helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(")
    assert 'print("error_stage=stage2_preflight", file=sys.stderr)' in script
    assert 'print(f"error_reason={reason}", file=sys.stderr)' in script
    assert 'print(f"requested_model={requested_model}", file=sys.stderr)' in script
    assert 'print(f"Direct Drum Kit Split preflight failed: {reason}", file=sys.stderr)' in script
    assert "drumsep_model_download_failed" in script
    assert "catalog_" in script
    assert "unsupported_" in script
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
    assert "DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 4" in script
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
    assert "_direct_dks_preflight_check(" in script
    assert "requested_stage2_model," in script
    assert "requested_stage2_model = _resolve_requested_stage2_model(args)" in script
    assert "unsupported_" in script
    assert "print(json.dumps(final_stems))" in script
    assert "workflow_source=dks_extract" not in support_script
    assert 'SW_LOG.readFileSnippet(C.progressState.logFile, 12000)' in Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")
    assert '"dks_extract_stage1_runtime", "dks_extract_stage1_requested_device"' in support_script
    assert '"dks_extract_stage2_requested_device", "dks_extract_stage2_device", "dks_extract_stage2_backend"' in support_script
    assert '"dks_extract_stage2_effective_cap", "bench_dks_stage2_cap_requested", "bench_dks_stage2_cap_applied",' in support_script
    assert '"bench_dks_stage2_cap_ignored_reason", "dks_extract_intermediate_dir"' in support_script
    assert '"drumsep_subprocess_env_profile", "drumsep_helper_device_arg", "drumsep_virtual_env"' in support_script
    assert '"drumsep_cuda_visible_devices", "drumsep_nvidia_visible_devices"' in support_script
    assert '"drumsep_ld_library_path_contains_main_venv", "drumsep_path_starts_with_drumsep_venv"' in support_script
    assert '"lua_dks_extract_outputs_detected", "lua_dks_extract_output_count"' in support_script
    assert '"expected_drum_outputs", "actual_drum_outputs", "output_count_mismatch"' in support_script
    assert '"drumsep_scheduler_backend", "drumsep_scheduler_policy", "drumsep_scheduler_uses_cpu_fallback"' in support_script


def test_drumkit_stage2_benchmark_cap_parser_accepts_only_allowed_values_and_respects_backend_safety(monkeypatch):
    module = _load_audio_separator_process_module()

    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    assert module._read_benchmark_dks_stage2_cap_request() == (None, "unset")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (None, "unset", 4, "not_requested")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "2")
    assert module._read_benchmark_dks_stage2_cap_request() == (2, "2")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (2, "2", 2, "")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cpu") == (2, "2", 1, "backend_not_rocm_cuda")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "4")
    assert module._read_benchmark_dks_stage2_cap_request() == (4, "4")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cuda") == (4, "4", 4, "")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "8")
    assert module._read_benchmark_dks_stage2_cap_request() == (None, "8")
    assert module._resolve_dks_extract_stage2_benchmark_cap("rocm") == (None, "8", 4, "invalid_request")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "1")
    assert module._read_benchmark_dks_stage2_cap_request() == (1, "1")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cpu") == (1, "1", 1, "")


def test_drumkit_stage2_mps_benchmark_cap_parser_prefers_mps_specific_env_and_keeps_generic_precedence_clear(monkeypatch):
    module = _load_audio_separator_process_module()

    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    assert module._read_benchmark_dks_stage2_mps_cap_request() == (None, "unset", "STEMWERK_BENCH_DKS_STAGE2_CAP")
    assert module._resolve_dks_extract_stage2_mps_benchmark_cap("mps") == (None, "unset", 1, "not_requested", "STEMWERK_BENCH_DKS_STAGE2_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CAP", "2")
    assert module._read_benchmark_dks_stage2_mps_cap_request() == (2, "2", "STEMWERK_BENCH_DKS_STAGE2_CAP")
    assert module._resolve_dks_extract_stage2_mps_benchmark_cap("mps") == (2, "2", 2, "", "STEMWERK_BENCH_DKS_STAGE2_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", "4")
    assert module._read_benchmark_dks_stage2_mps_cap_request() == (4, "4", "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")
    assert module._resolve_dks_extract_stage2_mps_benchmark_cap("mps") == (4, "4", 4, "", "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", "9")
    assert module._read_benchmark_dks_stage2_mps_cap_request() == (None, "9", "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")
    assert module._resolve_dks_extract_stage2_mps_benchmark_cap("mps") == (None, "9", 1, "invalid_request", "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", "2")
    assert module._resolve_dks_extract_stage2_mps_benchmark_cap("cpu") == (2, "2", 1, "backend_not_mps", "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP")


def test_drumkit_stage2_cpu_benchmark_cap_parser_accepts_stage_override_and_global_fallback(monkeypatch):
    module = _load_audio_separator_process_module()

    monkeypatch.delenv("STEMWERK_BENCH_CPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", raising=False)
    assert module._read_benchmark_dks_stage2_cpu_cap_request() == (None, "unset", "STEMWERK_BENCH_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (None, "unset", 1, "not_requested", "STEMWERK_BENCH_CPU_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_CPU_CAP", "2")
    assert module._read_benchmark_dks_stage2_cpu_cap_request() == (2, "2", "STEMWERK_BENCH_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (2, "2", 2, "", "STEMWERK_BENCH_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("rocm") == (2, "2", 1, "backend_not_cpu", "STEMWERK_BENCH_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("directml") == (2, "2", 1, "directml_fixed_cap1", "STEMWERK_BENCH_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("mps") == (2, "2", 1, "mps_fixed_cap1", "STEMWERK_BENCH_CPU_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", "4")
    monkeypatch.setattr(module, "_benchmark_cpu_count", lambda: 8)
    monkeypatch.setattr(module, "_benchmark_ram_gib", lambda: 16.0)
    assert module._read_benchmark_dks_stage2_cpu_cap_request() == (4, "4", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (4, "4", 4, "", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")

    monkeypatch.setattr(module, "_benchmark_cpu_count", lambda: None)
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (4, "4", 1, "cpu_threads_unknown_for_cap4", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")

    monkeypatch.setattr(module, "_benchmark_cpu_count", lambda: 4)
    monkeypatch.setattr(module, "_benchmark_ram_gib", lambda: 16.0)
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (4, "4", 1, "cpu_threads_low_for_cap4", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")

    monkeypatch.setattr(module, "_benchmark_cpu_count", lambda: 8)
    monkeypatch.setattr(module, "_benchmark_ram_gib", lambda: None)
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (4, "4", 1, "cpu_ram_unknown_for_cap4", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")

    monkeypatch.setattr(module, "_benchmark_ram_gib", lambda: 4.0)
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (4, "4", 1, "cpu_ram_low_for_cap4", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", "3")
    assert module._read_benchmark_dks_stage2_cpu_cap_request() == (None, "3", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")
    assert module._resolve_dks_extract_stage2_cpu_benchmark_cap("cpu") == (None, "3", 1, "invalid_request", "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP")


def test_drumkit_stage2_default_cap_stays_conservative_for_mps_and_unknown_backends(monkeypatch):
    module = _load_audio_separator_process_module()

    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    assert module._resolve_dks_extract_stage2_benchmark_cap("mps") == (None, "unset", 1, "not_requested")
    assert module._resolve_dks_extract_stage2_benchmark_cap("directml") == (None, "unset", 1, "not_requested")
    assert module._resolve_dks_extract_stage2_benchmark_cap("cpu") == (None, "unset", 1, "not_requested")


def test_dks_extract_stage2_lock_prefers_mps_benchmark_cap_for_mps_backend(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_CPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", raising=False)
    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", "2")

    with module._dks_extract_stage2_lock(tmp_path, "mps"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_mps_cap_requested=2" in captured.err
    assert "bench_dks_stage2_mps_cap_applied=2" in captured.err
    assert "bench_dks_stage2_mps_cap_ignored_reason=" in captured.err
    assert "dks_extract_stage2_effective_cap=2" in captured.err
    assert "lua_dks_extract_stage2_concurrency_cap=2" in captured.err
    assert "dks_extract_stage2_backend=mps" in captured.err

    monkeypatch.setenv("STEMWERK_BENCH_DKS_STAGE2_MPS_CAP", "bad")
    with module._dks_extract_stage2_lock(tmp_path, "mps"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_mps_cap_requested=bad" in captured.err
    assert "bench_dks_stage2_mps_cap_applied=1" in captured.err
    assert "bench_dks_stage2_mps_cap_ignored_reason=invalid_request" in captured.err
    assert "dks_extract_stage2_effective_cap=1" in captured.err


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
    monkeypatch.delenv("STEMWERK_BENCH_CPU_CAP", raising=False)
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CPU_CAP", raising=False)

    with module._dks_extract_stage2_lock(tmp_path, "rocm"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_cap_requested=2" in captured.err
    assert "bench_dks_stage2_cap_applied=2" in captured.err
    assert "bench_dks_stage2_cap_ignored_reason=" in captured.err
    assert "bench_cpu_cap_requested=unset" in captured.err
    assert "bench_cpu_cap_applied=1" in captured.err
    assert "dks_extract_stage2_backend=rocm" in captured.err

    with module._dks_extract_stage2_lock(tmp_path, "cpu"):
        pass
    captured = capsys.readouterr()
    assert "bench_dks_stage2_cap_applied=1" in captured.err
    assert "bench_dks_stage2_cap_ignored_reason=backend_not_rocm_cuda" in captured.err
    assert "bench_cpu_cap_requested=unset" in captured.err
    assert "bench_cpu_cap_applied=1" in captured.err
    assert "dks_extract_stage2_backend=cpu" in captured.err


def test_dks_extract_stage2_lock_prefers_cpu_benchmark_cap_for_cpu_backend(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv("STEMWERK_BENCH_DKS_STAGE2_CAP", raising=False)
    monkeypatch.setenv("STEMWERK_BENCH_CPU_CAP", "2")
    monkeypatch.setattr(module, "_benchmark_cpu_count", lambda: 8)
    monkeypatch.setattr(module, "_benchmark_ram_gib", lambda: 16.0)

    with module._dks_extract_stage2_lock(tmp_path, "cpu"):
        pass
    captured = capsys.readouterr()
    assert "bench_cpu_cap_requested=2" in captured.err
    assert "bench_cpu_cap_applied=2" in captured.err
    assert "bench_cpu_cap_ignored_reason=" in captured.err
    assert "dks_extract_stage2_effective_cap=2" in captured.err
    assert "lua_dks_extract_stage2_concurrency_cap=2" in captured.err


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
    monkeypatch.setenv("STEMWERK_BENCH_MPS_CAP", "2")
    assert module._benchmark_resource_sampling_requested() is True
    monkeypatch.delenv("STEMWERK_BENCH_MPS_CAP", raising=False)
    monkeypatch.setenv("STEMWERK_BENCH_RESOURCE_SAMPLING", "1")
    assert module._benchmark_resource_sampling_requested() is True

    monkeypatch.setattr(module.shutil, "which", lambda name: None)
    metrics, available, reason, detail = module._collect_rocm_smi_metrics()
    assert available is False
    assert reason == "rocm-smi_missing"
    assert metrics == {}
    assert "not found" in detail


def test_rocm_smi_parser_handles_current_rx9070_concise_output():
    module = _load_audio_separator_process_module()
    metrics = module._parse_rocm_smi_metrics_text(
        """
============================ ROCm System Management Interface ============================
====================================== Temperature =======================================
GPU[0]        : Temperature (Sensor edge) (C): 55.0
GPU[0]        : Temperature (Sensor junction) (C): 58.0
GPU[1]        : Temperature (Sensor edge) (C): 74.0
==========================================================================================
=================================== Power Consumption ====================================
GPU[0]        : Average Graphics Package Power (W): 40.0
GPU[1]        : Current Socket Graphics Package Power (W): 44.179
==========================================================================================
=================================== % time GPU is busy ===================================
GPU[0]        : GPU use (%): 1
GPU[1]        : GPU use (%): 0
==========================================================================================
=================================== Current Memory Use ===================================
GPU[0]        : GPU Memory Allocated (VRAM%): 28
GPU[1]        : GPU Memory Allocated (VRAM%): 15
==========================================================================================
================================== Memory Usage (Bytes) ==================================
GPU[0]        : VRAM Total Memory (B): 17095983104
GPU[0]        : VRAM Total Used Memory (B): 4930617344
GPU[1]        : VRAM Total Memory (B): 536870912
GPU[1]        : VRAM Total Used Memory (B): 80547840
==========================================================================================
""",
        """
GPU[0]        : Card Series:         AMD Radeon RX 9070
GPU[1]        : Card Series:         AMD Radeon 780M Graphics
""",
    )

    assert metrics["gpu_name"] == "AMD Radeon RX 9070"
    assert metrics["gpu_util_percent"] == 1.0
    assert metrics["gpu_temp_c"] == 58.0
    assert metrics["gpu_power_w"] == 40.0
    assert metrics["gpu_vram_total_mb"] == pytest.approx(16304.0, rel=0.001)
    assert metrics["gpu_vram_used_mb"] == pytest.approx(4702.203125, rel=0.001)


def test_rocm_smi_parser_keeps_partial_metrics_without_failing_summary():
    module = _load_audio_separator_process_module()
    metrics = module._parse_rocm_smi_metrics_text(
        """
GPU[0]        : GPU use (%): 87
GPU[0]        : Temperature (Sensor edge) (C): 61.5
""",
        "",
    )

    assert metrics["gpu_util_percent"] == 87.0
    assert metrics["gpu_temp_c"] == 61.5
    assert metrics["gpu_vram_used_mb"] is None
    assert metrics["gpu_vram_total_mb"] is None


def test_collect_rocm_smi_metrics_handles_command_failure_gracefully(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module.shutil, "which", lambda name: "/opt/rocm/bin/rocm-smi")
    monkeypatch.setattr(module, "_run_command_capture_text", lambda cmd, timeout=10: (2, "permission denied"))

    metrics, available, reason, detail = module._collect_rocm_smi_metrics()

    assert metrics == {}
    assert available is False
    assert reason == "rocm-smi_failed"
    assert "permission denied" in detail


def test_benchmark_resource_sampler_summary_keeps_cpu_ram_and_adds_rocm_gpu_fields(tmp_path):
    module = _load_audio_separator_process_module()
    sampler = module.BenchmarkResourceSampler(tmp_path)
    sampler.resource_sampling_available = True
    sampler.resource_sampling_reason = ""
    sampler.gpu_backend = "rocm-smi"
    sampler.sample_index = 3
    sampler.started_at = 0.0
    sampler.ended_at = 1.0

    sampler._update_summary(
        {
            "gpu_util_percent": 82.0,
            "gpu_vram_used_mb": 4096.0,
            "gpu_vram_total_mb": 16304.0,
            "gpu_temp_c": 67.0,
            "gpu_power_w": 123.4,
            "gpu_name": "AMD Radeon RX 9070",
            "cpu_util_percent": 44.0,
            "system_ram_used_mb": 24576.0,
            "process_rss_mb": 512.0,
        }
    )
    payload = sampler._summary_payload()

    assert payload["resource_sampling_available"] == "yes"
    assert payload["gpu_backend"] == "rocm-smi"
    assert payload["gpu_util_peak_percent"] == 82.0
    assert payload["gpu_util_avg_percent"] == 82.0
    assert payload["vram_peak_mb"] == 4096.0
    assert payload["vram_total_mb"] == 16304.0
    assert payload["gpu_temp_peak_c"] == 67.0
    assert payload["gpu_power_peak_w"] == 123.4
    assert payload["gpu_name"] == "AMD Radeon RX 9070"
    assert payload["system_ram_peak_mb"] == 24576.0
    assert payload["cpu_avg_percent"] == 44.0
    assert payload["process_rss_peak_mb"] == 512.0


def test_drumkit_extract_stage2_uses_requested_drumsep_model_not_stage1_demucs_model():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "def _resolve_requested_stage2_model(args: argparse.Namespace) -> str:" in script
    assert "return DIRECT_DKS_MODEL_ALIAS" in script
    assert "requested_stage2_model = _resolve_requested_stage2_model(args)" in script
    assert "_direct_dks_preflight_check(" in script
    assert "requested_stage2_model," in script
    assert "_emit_direct_dks_backend_limited_markers(" in script


def test_drumsep_runtime_verify_and_helper_use_clean_subprocess_env():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "env=_clean_env()," in script
    assert script.count("env=_clean_env(),") >= 2
    assert "build_drumsep_subprocess_env(" in script
    assert '"drumsep_subprocess_env_profile": profile' in script
    assert '"drumsep_helper_device_arg": backend or "unknown"' in script
    assert '"drumsep_ld_library_path_contains_main_venv": "yes"' in script


def test_drumsep_helper_subprocess_env_cpu_isolated_strips_main_venv_paths_and_gpu_vars(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", fake_sys_executable)

    runtime_python = tmp_path / "helper" / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    runtime_venv = runtime_python.parent.parent
    (runtime_venv / "lib" / "python3.12" / "site-packages" / "torch" / "lib").mkdir(parents=True, exist_ok=True)
    (runtime_venv / "lib" / "python3.12" / "site-packages" / "nvidia" / "cudnn" / "lib").mkdir(parents=True, exist_ok=True)
    main_venv_root = module._path_text(fake_sys_executable.parent.parent)
    base_env = {
        "PATH": f"{fake_sys_executable.parent}:{'/usr/local/bin:/usr/bin:/bin:/opt/custom/bin'}",
        "LD_LIBRARY_PATH": f"{fake_sys_executable.parent.parent}/lib/python3.12/site-packages/nvidia/cudnn/lib:/usr/lib:{runtime_venv}/lib",
        "PYTHONPATH": f"{fake_sys_executable.parent.parent}/lib/python3.12/site-packages",
        "PYTHONHOME": str(fake_sys_executable.parent.parent),
        "VIRTUAL_ENV": str(fake_sys_executable.parent.parent),
        "CUDA_VISIBLE_DEVICES": "0",
        "NVIDIA_VISIBLE_DEVICES": "all",
        "HIP_VISIBLE_DEVICES": "0",
        "ROCR_VISIBLE_DEVICES": "0",
        "HSA_OVERRIDE_GFX_VERSION": "11.0.0",
    }

    env, diag = module.build_drumsep_subprocess_env(base_env, runtime_python, runtime_venv, "cpu")

    assert env["VIRTUAL_ENV"] == str(runtime_venv)
    assert env["PATH"].startswith(str(module._runtime_bin_dir(runtime_venv)))
    assert env["CUDA_VISIBLE_DEVICES"] == ""
    assert env["NVIDIA_VISIBLE_DEVICES"] == ""
    assert "PYTHONPATH" not in env
    assert "PYTHONHOME" not in env
    assert "HIP_VISIBLE_DEVICES" not in env
    assert "ROCR_VISIBLE_DEVICES" not in env
    assert "HSA_OVERRIDE_GFX_VERSION" not in env
    assert env.get("LD_LIBRARY_PATH", "") in {"", str(runtime_venv / "lib")} or "/usr/lib" in env.get("LD_LIBRARY_PATH", "")
    assert "site-packages/torch/lib" not in module._path_text(env.get("LD_LIBRARY_PATH", ""))
    assert diag["drumsep_subprocess_env_profile"] == "cpu_isolated"
    assert diag["drumsep_helper_device_arg"] == "cpu"
    assert diag["drumsep_virtual_env"] == str(runtime_venv)
    assert diag["drumsep_ld_library_path_contains_main_venv"] == "no"


def test_drumsep_helper_subprocess_env_cuda_isolated_uses_raw_venv_roots(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    runtime_base = tmp_path / "STEMwerk"
    fake_sys_executable = runtime_base / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))

    runtime_python = runtime_base / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    runtime_venv = runtime_python.parent.parent
    runtime_torch_lib = runtime_venv / "lib" / "python3.12" / "site-packages" / "torch" / "lib"
    runtime_cuda_lib = runtime_venv / "lib" / "python3.12" / "site-packages" / "nvidia" / "cudnn" / "lib"
    runtime_torch_lib.mkdir(parents=True, exist_ok=True)
    runtime_cuda_lib.mkdir(parents=True, exist_ok=True)
    main_venv = fake_sys_executable.parent.parent
    base_env = {
        "PATH": f"{main_venv}/bin:/usr/bin",
        "LD_LIBRARY_PATH": (
            f"{main_venv}/lib/python3.12/site-packages/nvidia/cudnn/lib:"
            f"{main_venv}/lib/python3.12/site-packages/torch/lib:/usr/lib"
        ),
        "PYTHONPATH": f"{main_venv}/lib/python3.12/site-packages",
        "PYTHONHOME": str(main_venv),
        "VIRTUAL_ENV": str(main_venv),
    }

    env, diag = module.build_drumsep_subprocess_env(base_env, runtime_python, runtime_venv, "cuda")

    assert module._runtime_venv_root(runtime_python) == runtime_venv
    assert env["VIRTUAL_ENV"] == str(runtime_venv)
    assert env["PATH"].startswith(str(module._runtime_bin_dir(runtime_venv)))
    assert module._first_path_within_root(module._split_path_value(env["PATH"]), main_venv) == ""
    assert module._ld_path_entry_within_root(env.get("LD_LIBRARY_PATH", ""), main_venv) == ""
    assert str(runtime_torch_lib) in env.get("LD_LIBRARY_PATH", "")
    assert str(runtime_cuda_lib) in env.get("LD_LIBRARY_PATH", "")
    assert "PYTHONPATH" not in env
    assert "PYTHONHOME" not in env
    assert diag["drumsep_subprocess_env_profile"] == "cuda_isolated"
    assert diag["drumsep_cuda_ld_library_path_contains_main_venv"] == "no"
    assert diag["drumsep_cuda_main_venv_leak_path"] == ""
    assert diag["drumsep_cuda_helper_runtime_venv"] == str(runtime_venv)
    assert str(runtime_torch_lib) in diag["drumsep_cuda_runtime_lib_dirs"]
    assert str(runtime_cuda_lib) in diag["drumsep_cuda_runtime_lib_dirs"]


def test_cuda_path_containment_distinguishes_main_and_drumsep_venvs(tmp_path):
    module = _load_audio_separator_process_module()
    runtime_base = tmp_path / "STEMwerk"
    main_venv = runtime_base / ".venv"
    drumsep_venv = runtime_base / ".venv-drumsep"
    main_cudnn = main_venv / "lib" / "python3.12" / "site-packages" / "nvidia" / "cudnn" / "lib"
    drumsep_cudnn = drumsep_venv / "lib" / "python3.12" / "site-packages" / "nvidia" / "cudnn" / "lib"

    assert module._path_is_within_root(drumsep_cudnn, main_venv) is False
    assert module._path_is_within_root(main_cudnn, main_venv) is True
    assert module._ld_path_entry_within_root(f"{drumsep_cudnn}{os.pathsep}/usr/lib", main_venv) == ""
    assert module._ld_path_entry_within_root(f"{drumsep_cudnn}{os.pathsep}{main_cudnn}", main_venv) == str(main_cudnn)


def test_cuda_helper_probe_accepts_drumsep_cudnn_prefix_path(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    runtime_base = tmp_path / "STEMwerk"
    main_python = runtime_base / ".venv" / "bin" / "python"
    runtime_python = runtime_base / ".venv-drumsep" / "bin" / "python"
    runtime_cudnn = (
        runtime_base
        / ".venv-drumsep"
        / "lib"
        / "python3.12"
        / "site-packages"
        / "nvidia"
        / "cudnn"
        / "lib"
        / "libcudnn.so.9"
    )
    main_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    main_python.write_text("#!/bin/sh\n", encoding="utf-8")
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(main_python))

    class Completed:
        returncode = 0
        stderr = ""
        stdout = json.dumps(
            {
                "torch_file": str(runtime_base / ".venv-drumsep" / "lib" / "python3.12" / "site-packages" / "torch" / "__init__.py"),
                "torch_cuda": "13.0",
                "device_name": "NVIDIA GeForce RTX 3060 Laptop GPU",
                "cudnn_version": "92000",
                "cudnn_paths": [str(runtime_cudnn)],
                "virtual_env": str(runtime_base / ".venv-drumsep"),
            }
        )

    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: Completed())
    ok, reason, detail = module._probe_cuda_helper_isolation(runtime_python)

    assert ok is True
    assert reason == "ok"
    assert str(runtime_cudnn) in json.loads(detail)["cudnn_paths"]


def test_cuda_helper_probe_rejects_loaded_main_venv_cudnn_path(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    runtime_base = tmp_path / "STEMwerk"
    main_python = runtime_base / ".venv" / "bin" / "python"
    runtime_python = runtime_base / ".venv-drumsep" / "bin" / "python"
    main_cudnn = (
        runtime_base
        / ".venv"
        / "lib"
        / "python3.12"
        / "site-packages"
        / "nvidia"
        / "cudnn"
        / "lib"
        / "libcudnn.so.9"
    )
    main_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    main_python.write_text("#!/bin/sh\n", encoding="utf-8")
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(main_python))

    class Completed:
        returncode = 0
        stderr = ""
        stdout = json.dumps(
            {
                "torch_file": str(runtime_base / ".venv-drumsep" / "lib" / "python3.12" / "site-packages" / "torch" / "__init__.py"),
                "torch_cuda": "13.0",
                "device_name": "NVIDIA GeForce RTX 3060 Laptop GPU",
                "cudnn_version": "92000",
                "cudnn_paths": [str(main_cudnn)],
                "virtual_env": str(runtime_base / ".venv-drumsep"),
            }
        )

    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: Completed())
    ok, reason, detail = module._probe_cuda_helper_isolation(runtime_python)

    assert ok is False
    assert reason == "cuda_helper_isolation_failed_main_venv_cudnn_leak"
    assert detail == str(main_cudnn)


def test_drumsep_helper_subprocess_env_rocm_isolated_keeps_gpu_visibility(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))

    runtime_python = tmp_path / "helper" / ".venv-drumsep-rocm" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    runtime_venv = runtime_python.parent.parent
    base_env = {
        "PATH": f"{fake_sys_executable.parent}:{'/usr/local/bin:/usr/bin'}",
        "LD_LIBRARY_PATH": f"{fake_sys_executable.parent.parent}/lib/python3.12/site-packages/torch/lib:/usr/lib",
        "PYTHONPATH": f"{fake_sys_executable.parent.parent}/lib/python3.12/site-packages",
        "PYTHONHOME": str(fake_sys_executable.parent.parent),
        "VIRTUAL_ENV": str(fake_sys_executable.parent.parent),
        "HIP_VISIBLE_DEVICES": "0",
        "ROCR_VISIBLE_DEVICES": "0",
    }

    env, diag = module.build_drumsep_subprocess_env(base_env, runtime_python, runtime_venv, "rocm")

    assert env["VIRTUAL_ENV"] == str(runtime_venv)
    assert env["PATH"].startswith(str(module._runtime_bin_dir(runtime_venv)))
    assert "PYTHONPATH" not in env
    assert "PYTHONHOME" not in env
    assert env["HIP_VISIBLE_DEVICES"] == "0"
    assert env["ROCR_VISIBLE_DEVICES"] == "0"
    assert diag["drumsep_subprocess_env_profile"] == "rocm_isolated"
    assert diag["drumsep_helper_device_arg"] == "rocm"


def test_cuda_helper_probe_rejects_cudnn_symbol_failure(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")

    class Completed:
        returncode = -6
        stdout = ""
        stderr = "Could not load symbol cudnnGetLibConfig: undefined symbol"

    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: Completed())
    ok, reason, _detail = module._probe_cuda_helper_isolation(runtime_python)

    assert ok is False
    assert reason == "cuda_helper_probe_failed_cudnn_symbol"


def test_cuda_benchmark_override_falls_back_to_cpu_when_isolation_probe_fails(monkeypatch, tmp_path, capsys):
    module = _load_audio_separator_process_module()
    runtime_python = tmp_path / ".venv-drumsep" / "bin" / "python"
    runtime_python.parent.mkdir(parents=True, exist_ok=True)
    runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, "cuda")
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(
        module,
        "_probe_cuda_helper_isolation",
        lambda _runtime: (False, "cuda_helper_probe_failed_cudnn_symbol", "undefined symbol"),
    )

    assert module._resolve_benchmark_drumsep_helper_device("auto", "cuda", runtime_python) == (
        "cpu",
        "cuda_helper_probe_failed_cudnn_symbol",
    )
    stderr = capsys.readouterr().err
    assert "bench_drumsep_helper_device_applied=none" in stderr
    assert "bench_drumsep_helper_device_ignored_reason=cuda_helper_probe_failed_cudnn_symbol" in stderr


def test_rocm_runtime_defaults_auto_helper_to_rocm_without_benchmark_override(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)
    monkeypatch.setattr(module.sys, "platform", "linux")

    assert module._resolve_benchmark_drumsep_helper_device("auto", "rocm") == ("rocm", "auto_rocm_default")
    assert module._resolve_benchmark_drumsep_helper_device("cpu", "rocm") == ("cpu", "not_requested")
    module._probe_cuda_helper_isolation = lambda _runtime: (True, "ok", "{}")
    assert module._resolve_benchmark_drumsep_helper_device("auto", "cuda", Path("/tmp/runtime-python")) == ("cuda", "auto_cuda_default")


def test_run_direct_dks_drumsep_helper_uses_cpu_device_and_isolated_env(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py").resolve()
    input_path = tmp_path / "input.wav"
    output_root = tmp_path / "stage2_drumsep"
    model_cache_dir = tmp_path / "models"
    result_json = output_root / "drumsep_result.json"
    helper_stdout = output_root / "drumsep_helper_stdout.txt"
    helper_stderr = output_root / "drumsep_helper_stderr.txt"
    helper_log = output_root / "drumsep_helper.log"
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))
    drumsep_python = tmp_path / "helper" / ".venv-drumsep" / "bin" / "python"
    drumsep_python.parent.mkdir(parents=True, exist_ok=True)
    drumsep_python.write_text("#!/bin/sh\n", encoding="utf-8")
    expected_runtime_venv = str(module._runtime_venv_root(drumsep_python))
    input_path.write_bytes(b"RIFF0000WAVE")
    output_root.mkdir(parents=True, exist_ok=True)
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    for stem_name in ("kick", "snare", "toms", "hihat", "ride", "crash"):
        (output_root / f"{stem_name}.wav").write_bytes(b"data")
    result_json.write_text(
        json.dumps(
            {
                "ok": True,
                "stems": {
                    "kick": str(output_root / "kick.wav"),
                    "snare": str(output_root / "snare.wav"),
                    "toms": str(output_root / "toms.wav"),
                    "hihat": str(output_root / "hihat.wav"),
                    "ride": str(output_root / "ride.wav"),
                    "crash": str(output_root / "crash.wav"),
                },
                "raw_outputs": [str(output_root / f"{stem}.wav") for stem in ("kick", "snare", "toms", "hihat", "ride", "crash")],
                "expected_drum_outputs": 6,
                "actual_drum_outputs": 6,
                "output_count_mismatch": False,
                "drumsep_mps_all_targets_route": "",
                "mps_fallback_enabled": "",
                "pytorch_mps_fallback_env": "",
                "output_validation_reason": "ok",
                "expected_stems": ["kick", "snare", "toms", "hihat", "ride", "crash"],
                "found_stems": ["kick", "snare", "toms", "hihat", "ride", "crash"],
                "backend_runtime": "cpu",
                "audio_separator_version": "0.34.1",
                "requested_device": "auto",
                "effective_device": "cpu",
                "model_device": "cpu",
                "direct_demix_keys": [],
            }
        ),
        encoding="utf-8",
    )

    captured = {}

    class FakeProcess:
        def __init__(self):
            self.returncode = 0

        def poll(self):
            return 0

        def kill(self):
            return None

    def fake_popen(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["env"] = kwargs.get("env", {})
        return FakeProcess()

    monkeypatch.setattr(module.subprocess, "Popen", fake_popen)
    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
        route="wrapper",
        device="cpu",
        requested_device="auto",
        backend_runtime="cpu",
    )

    assert ok is True
    assert reason == ""
    assert detail == ""
    assert stems["kick"].endswith("kick.wav")
    assert captured["cmd"][0] == str(drumsep_python)
    assert captured["cmd"][2] == "--input"
    assert captured["cmd"][16] == "--device"
    assert captured["cmd"][17] == "cpu"
    assert captured["env"]["VIRTUAL_ENV"] == expected_runtime_venv
    assert captured["env"]["CUDA_VISIBLE_DEVICES"] == ""
    assert captured["env"]["NVIDIA_VISIBLE_DEVICES"] == ""
    assert "PYTHONPATH" not in captured["env"]
    assert "PYTHONHOME" not in captured["env"]
    assert module._path_text(fake_sys_executable.parent.parent) not in module._path_text(captured["env"].get("LD_LIBRARY_PATH", ""))
    assert captured["env"]["PATH"].startswith(str(module._runtime_bin_dir(Path(expected_runtime_venv))))


def test_run_direct_dks_drumsep_helper_uses_rocm_device_and_isolated_env(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    input_path = tmp_path / "input.wav"
    output_root = tmp_path / "stage2_drumsep"
    model_cache_dir = tmp_path / "models"
    result_json = output_root / "drumsep_result.json"
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))
    drumsep_python = tmp_path / "helper" / ".venv-drumsep-rocm" / "bin" / "python"
    drumsep_python.parent.mkdir(parents=True, exist_ok=True)
    drumsep_python.write_text("#!/bin/sh\n", encoding="utf-8")
    expected_runtime_venv = str(module._runtime_venv_root(drumsep_python))
    input_path.write_bytes(b"RIFF0000WAVE")
    output_root.mkdir(parents=True, exist_ok=True)
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    for stem_name in ("kick", "snare", "toms", "hihat", "ride", "crash"):
        (output_root / f"{stem_name}.wav").write_bytes(b"data")
    result_json.write_text(
        json.dumps(
            {
                "ok": True,
                "stems": {
                    "kick": str(output_root / "kick.wav"),
                    "snare": str(output_root / "snare.wav"),
                    "toms": str(output_root / "toms.wav"),
                    "hihat": str(output_root / "hihat.wav"),
                    "ride": str(output_root / "ride.wav"),
                    "crash": str(output_root / "crash.wav"),
                },
                "raw_outputs": [str(output_root / f"{stem}.wav") for stem in ("kick", "snare", "toms", "hihat", "ride", "crash")],
                "expected_drum_outputs": 6,
                "actual_drum_outputs": 6,
                "output_count_mismatch": False,
                "output_validation_reason": "ok",
                "backend_runtime": "rocm",
                "audio_separator_version": "0.34.1",
                "requested_device": "cuda:0",
                "effective_device": "cuda",
                "model_device": "cuda:0",
            }
        ),
        encoding="utf-8",
    )

    captured = {}

    class FakeProcess:
        def __init__(self):
            self.returncode = 0

        def poll(self):
            return 0

        def kill(self):
            return None

    def fake_popen(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["env"] = kwargs.get("env", {})
        return FakeProcess()

    monkeypatch.setattr(module.subprocess, "Popen", fake_popen)
    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
        route="wrapper",
        device="rocm",
        requested_device="cuda:0",
        backend_runtime="rocm",
    )

    assert ok is True
    assert reason == ""
    assert detail == ""
    assert stems["kick"].endswith("kick.wav")
    assert captured["cmd"][17] == "rocm"
    assert captured["env"]["VIRTUAL_ENV"] == expected_runtime_venv
    assert "CUDA_VISIBLE_DEVICES" not in captured["env"] or captured["env"]["CUDA_VISIBLE_DEVICES"] != ""
    assert "NVIDIA_VISIBLE_DEVICES" not in captured["env"] or captured["env"]["NVIDIA_VISIBLE_DEVICES"] != ""


def test_run_direct_dks_drumsep_helper_uses_cuda_device_and_isolated_env(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    input_path = tmp_path / "input.wav"
    output_root = tmp_path / "stage2_drumsep"
    model_cache_dir = tmp_path / "models"
    result_json = output_root / "drumsep_result.json"
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))
    drumsep_python = tmp_path / "helper" / ".venv-drumsep" / "bin" / "python"
    drumsep_python.parent.mkdir(parents=True, exist_ok=True)
    drumsep_python.write_text("#!/bin/sh\n", encoding="utf-8")
    expected_runtime_venv = str(module._runtime_venv_root(drumsep_python))
    input_path.write_bytes(b"RIFF0000WAVE")
    output_root.mkdir(parents=True, exist_ok=True)
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    for stem_name in ("kick", "snare", "toms", "hihat", "ride", "crash"):
        (output_root / f"{stem_name}.wav").write_bytes(b"data")
    result_json.write_text(
        json.dumps(
            {
                "ok": True,
                "stems": {
                    "kick": str(output_root / "kick.wav"),
                    "snare": str(output_root / "snare.wav"),
                    "toms": str(output_root / "toms.wav"),
                    "hihat": str(output_root / "hihat.wav"),
                    "ride": str(output_root / "ride.wav"),
                    "crash": str(output_root / "crash.wav"),
                },
                "raw_outputs": [str(output_root / f"{stem}.wav") for stem in ("kick", "snare", "toms", "hihat", "ride", "crash")],
                "expected_drum_outputs": 6,
                "actual_drum_outputs": 6,
                "output_count_mismatch": False,
                "output_validation_reason": "ok",
                "backend_runtime": "cuda",
                "audio_separator_version": "0.34.1",
                "requested_device": "auto",
                "effective_device": "cuda",
                "model_device": "cuda:0",
            }
        ),
        encoding="utf-8",
    )

    captured = {}

    class FakeProcess:
        def __init__(self):
            self.returncode = 0

        def poll(self):
            return 0

        def kill(self):
            return None

    def fake_popen(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["env"] = kwargs.get("env", {})
        return FakeProcess()

    monkeypatch.setattr(module.subprocess, "Popen", fake_popen)
    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
        route="wrapper",
        device="cuda",
        requested_device="auto",
        backend_runtime="cuda",
    )

    assert ok is True
    assert reason == ""
    assert detail == ""
    assert stems["kick"].endswith("kick.wav")
    assert captured["cmd"][17] == "cuda"
    assert captured["env"]["VIRTUAL_ENV"] == expected_runtime_venv
    assert captured["env"].get("CUDA_VISIBLE_DEVICES", None) != ""
    assert captured["env"].get("NVIDIA_VISIBLE_DEVICES", None) != ""
    assert "PYTHONPATH" not in captured["env"]
    assert "PYTHONHOME" not in captured["env"]
    assert module._path_text(fake_sys_executable.parent.parent) not in module._path_text(captured["env"].get("LD_LIBRARY_PATH", ""))
    assert captured["env"]["PATH"].startswith(str(module._runtime_bin_dir(Path(expected_runtime_venv))))


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


def test_drumsep_runtime_broken_reports_import_error(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    runtime_python = module._drumsep_runtime_python_path(tmp_path)
    runtime_python.parent.mkdir(parents=True)
    runtime_python.write_text("", encoding="utf-8")
    runtime_python.chmod(0o755)

    class Completed:
        returncode = 1
        stdout = ""
        stderr = "ImportError: audio_separator missing"

    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: Completed())

    ok, detail, _payload = module._verify_drumsep_runtime(runtime_python)

    assert ok is False
    assert "ImportError: audio_separator missing" in detail


def test_drumsep_runtime_selector_prefers_rocm_when_gpu_capable(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="posix")
    monkeypatch.setattr(module.sys, "platform", "linux")
    base = tmp_path
    rocm_python = module._drumsep_rocm_runtime_python_path(base)
    cpu_python = module._drumsep_runtime_python_path(base)
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False, require_mps=False, require_directml=False):
        assert require_directml is False
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == rocm_python
    assert kind == "rocm"
    assert info["torch_hip"] == "6.4"
    assert info["selection_policy"] == "auto_prefer_rocm"


def test_drumsep_runtime_selector_uses_state_python_path_on_macos_cpu_runtime(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    state_dir = base / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    shared_python = base / ".venv" / "bin" / "python"
    shared_python.parent.mkdir(parents=True, exist_ok=True)
    shared_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    shared_python.chmod(0o755)
    (state_dir / "drumsep_runtime.env").write_text(
        f"STATUS=ok\nPYTHON_PATH={shared_python}\nVENV_PYTHON_PATH={shared_python}\n",
        encoding="utf-8",
    )

    def fake_verify(path, require_gpu=False):
        return (True, "ok", {"versions": {"torch": "2.5.1"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("cpu", base)
    assert selected == shared_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu"


def test_drumsep_runtime_selector_reports_missing_for_stale_ok_without_existing_python(tmp_path):
    module = _load_audio_separator_process_module()
    base = tmp_path
    state_dir = base / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    missing_python = base / ".venv" / "bin" / "python"
    (state_dir / "drumsep_runtime.env").write_text(
        f"STATUS=ok\nPYTHON_PATH={missing_python}\nVENV_PYTHON_PATH={missing_python}\n",
        encoding="utf-8",
    )

    selected, kind, info = module._select_drumsep_runtime("cpu", base)
    assert selected is None
    assert kind == "missing"
    assert info["cpu_detail"] == "missing"


def test_direct_dks_preflight_rewrites_dead_ckpt_url_and_downloads_assets(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    repo_checks = tmp_path / "download_checks.json"
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)

    requests = []

    class FakeResponse:
        def __init__(self, payload: bytes):
            self.payload = payload

        def read(self) -> bytes:
            return self.payload

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    payloads = {
        module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: b"fake-ckpt-bytes",
        yaml_url: b"audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n",
    }

    def fake_urlopen(url, timeout=120):
        requests.append((str(url), timeout))
        return FakeResponse(payloads[str(url)])

    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
    )

    assert ok is True
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert detail is None
    assert [url for url, _timeout in requests] == [module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL, yaml_url]
    assert (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).read_bytes() == b"fake-ckpt-bytes"
    assert "model:" in (model_cache_dir / yaml_name).read_text(encoding="utf-8")

    runtime_checks = json.loads((model_cache_dir / "download_checks.json").read_text(encoding="utf-8"))
    written_entry = runtime_checks["mdx23c_download_list"][module.DIRECT_DKS_MODEL_ENTRY_NAME]
    assert written_entry == {module.DIRECT_DKS_MODEL_FILENAME: yaml_name}
    persisted_sources = runtime_checks["other_network_list_new"][module.DIRECT_DKS_MODEL_ENTRY_NAME]
    assert persisted_sources[module.DIRECT_DKS_MODEL_FILENAME] == module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL
    assert persisted_sources[yaml_name] == yaml_url


def test_direct_dks_preflight_uses_builtin_catalog_fallback_when_download_checks_are_missing(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "fresh model cache"
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)

    requests = []

    class FakeResponse:
        def __init__(self, payload: bytes):
            self.payload = payload

        def read(self) -> bytes:
            return self.payload

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    payloads = {
        module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: b"fresh-ckpt-bytes",
        module.DIRECT_DKS_MODEL_YAML_URL: b"audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n",
    }

    def fake_urlopen(url, timeout=120):
        requests.append((str(url), timeout))
        return FakeResponse(payloads[str(url)])

    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
    )

    assert ok is True
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert detail is None
    assert [url for url, _timeout in requests] == [module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL, module.DIRECT_DKS_MODEL_YAML_URL]
    runtime_checks = json.loads((model_cache_dir / "download_checks.json").read_text(encoding="utf-8"))
    written_entry = runtime_checks["mdx23c_download_list"][module.DIRECT_DKS_MODEL_ENTRY_NAME]
    assert written_entry == {module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_YAML}
    persisted_sources = runtime_checks["other_network_list_new"][module.DIRECT_DKS_MODEL_ENTRY_NAME]
    assert persisted_sources[module.DIRECT_DKS_MODEL_FILENAME] == module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL
    assert persisted_sources[module.DIRECT_DKS_MODEL_YAML] == module.DIRECT_DKS_MODEL_YAML_URL


def test_direct_dks_preflight_skips_download_when_assets_already_exist(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks = tmp_path / "download_checks.json"
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).write_bytes(b"existing-ckpt")
    (model_cache_dir / yaml_name).write_text(
        "audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)
    monkeypatch.setattr(
        module.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("urlopen should not be called")),
    )

    ok, _requested_model, _resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
    )

    assert ok is True
    assert detail is None


def test_direct_dks_preflight_flags_audio_separator_0230_runtime_as_backend_limited(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks = tmp_path / "download_checks.json"
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).write_bytes(b"existing-ckpt")
    (model_cache_dir / yaml_name).write_text(
        "audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n    - Snare\n    - Toms\n    - Hh\n    - Ride\n    - Crash\n  target_instrument: drums\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)
    runtime_info = {"versions": {"audio-separator": "0.23.0"}}

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
        runtime_info=runtime_info,
    )

    assert ok is False
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert str(detail).startswith("backend_limited:")
    assert "audio_separator_version=0.23.0" in str(detail)
    assert "expected_stems=kick,snare,toms,hihat,ride,crash" in str(detail)
    assert "found_stems=kick,snare" in str(detail)
    assert f"yaml_path={model_cache_dir / yaml_name}" in str(detail)
    assert "output_validation_reason=audio_separator_mdxc_runtime_primary_secondary_only" in str(detail)


def test_direct_dks_preflight_allows_linux_rocm_runtime_with_six_output_capable_backend(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks = tmp_path / "download_checks.json"
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).write_bytes(b"existing-ckpt")
    (model_cache_dir / yaml_name).write_text(
        "audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n    - Snare\n    - Toms\n    - Hh\n    - Ride\n    - Crash\n  target_instrument: drums\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)
    runtime_info = {
        "kind": "rocm",
        "torch_hip": "6.4",
        "device_names": ["AMD Radeon RX 9070"],
        "versions": {"audio-separator": "0.34.1", "torch": "2.9.1+rocm6.4"},
    }

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
        runtime_info=runtime_info,
    )

    assert ok is True
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert detail is None


def test_direct_dks_preflight_reports_source_and_target_on_download_failure(tmp_path, monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    repo_checks = tmp_path / "download_checks.json"
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)

    def fake_urlopen(url, timeout=120):
        raise OSError("ssl cert verify failed")

    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
    )

    assert ok is False
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert "asset_download_failed:aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt" in str(detail)
    assert f"target={model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME}" in str(detail)
    assert f"source={module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL}" in str(detail)
    stderr = capsys.readouterr().err
    assert f"drumsep_cache_source={module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL}" in stderr
    assert "drumsep_cache_error=aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt|" in stderr


def test_direct_dks_preflight_reports_yaml_schema_details_on_invalid_yaml(tmp_path, monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    model_cache_dir = tmp_path / "model cache with spaces"
    repo_checks = tmp_path / "download_checks.json"
    yaml_name = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_url = (
        "https://raw.githubusercontent.com/TRvlvr/application_data/main/"
        "mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    repo_checks.write_text(
        json.dumps(
            {
                "other_network_list_new": {
                    module.DIRECT_DKS_MODEL_ENTRY_NAME: {
                        module.DIRECT_DKS_MODEL_FILENAME: module.DIRECT_DKS_MODEL_DEAD_CKPT_URL,
                        yaml_name: yaml_url,
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: repo_checks)

    class FakeResponse:
        def __init__(self, payload: bytes):
            self.payload = payload

        def read(self) -> bytes:
            return self.payload

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    payloads = {
        module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: b"fake-ckpt-bytes",
        yaml_url: b"audio:\n  dim_f: 1024\ntraining:\n  instruments:\n    - Kick\n",
    }

    monkeypatch.setattr(module.urllib.request, "urlopen", lambda url, timeout=120: FakeResponse(payloads[str(url)]))

    ok, requested_model, resolved_model, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
    )

    assert ok is False
    assert requested_model == module.DIRECT_DKS_MODEL_ALIAS
    assert resolved_model == module.DIRECT_DKS_MODEL_FILENAME
    assert "yaml_schema_invalid:" in str(detail)
    assert "missing=model" in str(detail)
    stderr = capsys.readouterr().err
    assert f"yaml_path={model_cache_dir / yaml_name}" in stderr
    assert f"yaml_source={yaml_url}" in stderr
    assert "yaml_top_level_keys=audio,training" in stderr
    assert "expected_schema=audio,model,training" in stderr


def test_drumsep_runtime_selector_falls_back_to_cpu_when_rocm_invalid(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="posix")
    monkeypatch.setattr(module.sys, "platform", "linux")
    base = tmp_path
    rocm_python = module._drumsep_rocm_runtime_python_path(base)
    cpu_python = module._drumsep_runtime_python_path(base)
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        assert require_directml is False
        if "drumsep-rocm" in str(path):
            return (False, "rocm_no_hip", {})
        if require_cuda:
            return (False, "cuda_unavailable", {})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == cpu_python
    assert kind == "cpu"
    assert info["fallback_reason"] == "rocm_skipped:rocm_no_hip;cuda_skipped:cuda_unavailable"
    assert info["selection_policy"] == "fallback_cpu"


def test_drumsep_runtime_selector_respects_explicit_cpu_even_when_rocm_valid(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="posix")
    monkeypatch.setattr(module.sys, "platform", "linux")
    base = tmp_path
    rocm_python = module._drumsep_rocm_runtime_python_path(base)
    cpu_python = module._drumsep_runtime_python_path(base)
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        assert require_directml is False
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    verify_calls = []
    def fake_verify_with_calls(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        verify_calls.append((str(path), require_gpu, require_mps, require_cuda, require_directml))
        return fake_verify(path, require_gpu=require_gpu, require_mps=require_mps, require_cuda=require_cuda, require_directml=require_directml)

    module._verify_drumsep_runtime = fake_verify_with_calls
    selected, kind, info = module._select_drumsep_runtime("cpu", base)
    assert selected == cpu_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu"
    assert info["fallback_reason"] == ""
    assert all("drumsep-rocm" not in p for p, _, _, _, _ in verify_calls)
    assert verify_calls and verify_calls[0][1] is False


def test_drumsep_runtime_selector_supports_explicit_linux_cuda(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="posix")
    monkeypatch.setattr(module.sys, "platform", "linux")
    base = tmp_path
    rocm_python = module._drumsep_rocm_runtime_python_path(base)
    cpu_python = module._drumsep_runtime_python_path(base)
    rocm_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    rocm_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    rocm_python.chmod(0o755)
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        assert require_directml is False
        if "drumsep-rocm" in str(path):
            return (True, "ok", {"versions": {"torch": "2.9.1+rocm6.4"}, "torch_hip": "6.4", "device_names": ["AMD Radeon RX 9070"]})
        if require_cuda:
            return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "torch_cuda_available": True, "device_names": ["NVIDIA GeForce RTX 3060 Laptop GPU"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("cuda:0", base)
    assert selected == cpu_python
    assert kind == "cuda"
    assert info["selection_policy"] == "explicit_cuda"


def test_drumsep_runtime_selector_prefers_verified_linux_cuda_when_rocm_missing(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="posix")
    monkeypatch.setattr(module.sys, "platform", "linux")
    base = tmp_path
    cpu_python = module._drumsep_runtime_python_path(base)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    cpu_python.chmod(0o755)

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        assert require_directml is False
        if require_gpu:
            return (False, "missing", {})
        if require_cuda:
            return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "torch_cuda_available": True, "device_names": ["NVIDIA GeForce RTX 3060 Laptop GPU"]})
        return (True, "ok", {"versions": {"torch": "2.12.0+cu130"}, "torch_hip": "", "device_names": []})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == cpu_python
    assert kind == "cuda"
    assert info["selection_policy"] == "auto_prefer_cuda"


def test_drumsep_runtime_selector_prefers_directml_on_windows_when_cuda_runtime_is_missing(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="nt")
    monkeypatch.setattr(module.sys, "platform", "win32")
    base = tmp_path
    directml_python = base / ".venv-drumsep-directml" / "Scripts" / "python.exe"
    directml_python.parent.mkdir(parents=True, exist_ok=True)
    directml_python.write_text("", encoding="utf-8")

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        if require_cuda:
            return (False, "missing", {})
        assert path == directml_python
        assert require_directml is True
        return (
            True,
            "ok",
            {
                "versions": {"torch": "2.12.0"},
                "directml_available": True,
                "directml_device_count": 1,
                "onnxruntime_providers": ["DmlExecutionProvider", "CPUExecutionProvider"],
            },
        )

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == directml_python
    assert kind == "directml"
    assert info["selection_policy"] == "fallback_directml"
    assert info["fallback_reason"] == "cuda_skipped:missing"


def test_drumsep_runtime_selector_falls_back_to_cpu_when_windows_directml_probe_fails(tmp_path, monkeypatch):
    module = _load_audio_separator_process_module()
    module.os = _OsProxy(module.os, name="nt")
    monkeypatch.setattr(module.sys, "platform", "win32")
    base = tmp_path
    directml_python = base / ".venv-drumsep-directml" / "Scripts" / "python.exe"
    cpu_python = base / ".venv-drumsep" / "Scripts" / "python.exe"
    directml_python.parent.mkdir(parents=True, exist_ok=True)
    cpu_python.parent.mkdir(parents=True, exist_ok=True)
    directml_python.write_text("", encoding="utf-8")
    cpu_python.write_text("", encoding="utf-8")

    def fake_verify(path, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        if require_cuda:
            return (False, "missing", {})
        if path == directml_python:
            assert require_directml is True
            return (
                False,
                "onnxruntime_dml_provider_missing",
                {
                    "directml_available": True,
                    "directml_device_count": 1,
                    "onnxruntime_providers": ["CPUExecutionProvider"],
                },
            )
        assert path == cpu_python
        return (True, "ok", {"versions": {"torch": "2.12.0"}})

    module._verify_drumsep_runtime = fake_verify
    selected, kind, info = module._select_drumsep_runtime("auto", base)
    assert selected == cpu_python
    assert kind == "cpu"
    assert info["selection_policy"] == "fallback_cpu"
    assert info["fallback_reason"] == "cuda_skipped:missing;directml_skipped:onnxruntime_dml_provider_missing"


def test_drumsep_runtime_selector_reports_missing_when_both_absent(tmp_path):
    module = _load_audio_separator_process_module()
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)
    assert selected is None
    assert kind == "missing"
    if module.sys.platform == "darwin":
        assert info["mps_detail"] == "missing"
    elif module.os.name == "nt":
        assert info["directml_detail"] == "missing"
    else:
        assert info["rocm_detail"] == "missing"
    assert info["cpu_detail"] == "missing"


def test_normal_stem_workflows_do_not_reference_drumsep_runtime():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()
    marker = 'if _is_direct_dks_source(args.workflow_mode, args.workflow_source):'
    assert marker in script
    _, after_direct_dks = script.split(marker, 1)

    assert "_select_drumsep_runtime(" in after_direct_dks
    assert after_direct_dks.index("_select_drumsep_runtime(") < after_direct_dks.index("_direct_dks_preflight_check(")
    assert after_direct_dks.index("_select_drumsep_runtime(") < after_direct_dks.index('emit_phase("model_setup_start")')
    assert after_direct_dks.index("helper_ok, helper_stems, helper_reason, helper_detail = _run_direct_dks_drumsep_helper(") < after_direct_dks.index('emit_phase("model_setup_start")')
    assert "_enable_torch_weights_only_compat(run_model, resolved_device)" in script
    assert 'error_reason=drumsep_backend_runtime_limited' in script
    assert 'audio_separator_mdxc_runtime_primary_secondary_only' in script
    assert 'PROGRESS:0:Checking Drum Kit backend...' in script


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
    assert "error_reason=drumsep_backend_runtime_limited" in main_script
    assert "error_reason=drumsep_helper_failed" in main_script
    assert "error_reason=drumsep_model_load_failed" in main_script
    assert "error_reason=drumsep_separate_failed" in main_script
    assert "error_reason=drumsep_output_count_mismatch" in main_script
    assert 'trSafeValue("drumsep_backend_limited_title", "Drum Kit backend not yet supported.")' in main_script
    assert 'file = "hi-hat.wav"' in main_script
    assert "activateWorkflowStemSet(isDirectDKS)" in main_script
    assert "Run Setup/Repair Drum Kit Split runtime." in main_script
    assert "Run Setup/Repair to install the Apple MPS Drum Kit Split runtime." in main_script
    assert 'elseif OS == "Linux" then' in main_script
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
    assert 'pip_install_with_scope drumsep "${_drumsep_py}" --upgrade pip setuptools wheel' in script
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
    setup_internal = _read_utf8("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua")
    linux_bootstrap = _read_utf8("scripts/reaper/STEMwerk_Bootstrap_Linux.sh")

    assert 'mode ~= "repair" and mode ~= "rebuild-venv" and mode ~= "drumsep-runtime" and mode ~= "drumsep-rocm-runtime"' in setup_internal
    assert '((isDrumsepRuntime and "drumsep_runtime.env") or (isDrumsepRocmRuntime and "drumsep_runtime_rocm.env") or "bootstrap.env")' in setup_internal
    assert '((isDrumsepRuntime and "drumsep_install.log") or (isDrumsepRocmRuntime and "drumsep_rocm_install.log") or "bootstrap.log")' in setup_internal
    assert '{ id = "drumsep-runtime", accent = { 0.22, 0.62, 0.70 } }' in setup_internal
    assert '{ id = "drumsep-rocm-runtime", accent = { 0.16, 0.56, 0.78 } }' in setup_internal
    assert 'refreshSetupMenuChoiceLabels({ choices = choices })' in setup_internal
    assert 'startLinuxSetup(runtime, separatorScript, chosen)' in setup_internal
    assert 'if [ "${MODE}" = "drumsep-runtime" ]; then' in linux_bootstrap
    assert 'write_drumsep_state "install_failed" "missing" "python_missing"' in linux_bootstrap
    assert 'elif [ "${MODE}" = "drumsep-rocm-runtime" ]; then' in linux_bootstrap
    assert 'write_drumsep_rocm_state "install_failed" "missing" "python_missing"' in linux_bootstrap


def test_windows_setup_exposes_directml_drumsep_runtime_action_and_state_files():
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8", errors="replace")

    assert 'WINDOWS_SETUP.mode == "drumsep-cuda-runtime"' in setup_internal
    assert 'WINDOWS_SETUP.mode == "drumsep-directml-runtime"' in setup_internal
    assert '(isDrumsepCudaRuntime and "drumsep_runtime_cuda.env")' in setup_internal
    assert '(isDrumsepCudaRuntime and "drumsep_cuda_install.log")' in setup_internal
    assert '(isDrumsepCudaRuntime and "drumsep_cuda_runtime.pid")' in setup_internal
    assert '{ id = "drumsep-cuda-runtime", accent = { 0.22, 0.62, 0.70 } }' in setup_internal
    assert '(isDrumsepDirectmlRuntime and "drumsep_runtime_directml.env")' in setup_internal
    assert '(isDrumsepDirectmlRuntime and "drumsep_directml_install.log")' in setup_internal
    assert '(isDrumsepDirectmlRuntime and "drumsep_directml_runtime.pid")' in setup_internal
    assert '{ id = "drumsep-directml-runtime", accent = { 0.12, 0.58, 0.76 } }' in setup_internal
    assert 'refreshSetupMenuChoiceLabels({ choices = choices })' in setup_internal
    assert 'startWindowsSetup(runtime, separatorScript, chosen, true)' in setup_internal


def test_linux_drumsep_rocm_runtime_installer_has_disk_preflight_and_rocm_pins():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'DRUMSEP_ROCM_TORCH_VERSION="2.9.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCHVISION_VERSION="0.24.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCHAUDIO_VERSION="2.9.1+rocm6.4"' in script
    assert 'DRUMSEP_ROCM_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm6.4"' in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCH_VERSION="2.10.0+rocm7.0"' in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCH_INDEX_URL="https://download.pytorch.org/whl/rocm7.0"' in script
    assert 'DRUMSEP_ROCM_MIN_FREE_GB="20"' in script
    assert "drumsep_rocm_disk_preflight()" in script
    assert "resolve_drumsep_rocm_tmpdir()" in script
    assert 'write_drumsep_rocm_state "disk_space_insufficient" "missing"' in script
    assert 'select_drumsep_rocm_torch_stack() {' in script
    assert 'pip_install_with_scope drumsep "${_py}" --no-cache-dir --index-url "${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}"' in script
    assert '"torch==${DRUMSEP_ACTIVE_ROCM_TORCH_VERSION}"' in script
    assert 'pip_install_with_scope drumsep "${_py}" --no-cache-dir --no-deps' in script
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
        expected_drum_outputs=6,
        actual_drum_outputs=1,
        expected_stems=list(helper.EXPECTED_STEMS),
        found_stems=["kick"],
        found_files=raw_outputs,
        output_count_mismatch=True,
    )

    assert stems == {"kick": str(tmp_path / "kick.wav")}
    assert payload["ok"] is False
    assert payload["error_stage"] == "stage2_output_validation"
    assert payload["error_reason"] == "drumsep_output_count_mismatch"
    assert payload["expected_drum_outputs"] == 6
    assert payload["actual_drum_outputs"] == 1
    assert payload["output_count_mismatch"] is True


def test_drumsep_helper_reads_yaml_metadata_from_runtime_download_checks(tmp_path):
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_meta_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(helper)

    model_dir = tmp_path / "model dir with spaces"
    model_dir.mkdir(parents=True, exist_ok=True)
    (model_dir / "download_checks.json").write_text(
        json.dumps(
            {
                "mdx23c_download_list": {
                    "MDX23C Model: DrumSep 6stem | (by aufr33 & jarredou)": {
                        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt": "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    yaml_path = model_dir / "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    yaml_path.write_text(
        "audio:\n  dim_f: 1024\nmodel:\n  act: gelu\ntraining:\n  instruments:\n    - Kick\n    - Snare\n    - Toms\n    - Hh\n    - Ride\n    - Crash\n  target_instrument: null\n",
        encoding="utf-8",
    )

    meta = helper._load_model_metadata(
        model_dir,
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
    )

    assert meta["yaml_path"] == str(yaml_path)
    assert meta["yaml_resolution"] in {"download_checks", "known_drumsep_yaml"}
    assert meta["yaml_top_level_keys"] == ["audio", "model", "training"]
    assert meta["training_instruments"] == ["Kick", "Snare", "Toms", "Hh", "Ride", "Crash"]


def test_drumsep_helper_flags_audio_separator_mdxc_two_stem_runtime_limit():
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_limit_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(helper)

    reason = helper._runtime_two_stem_limit_reason(
        ["kick", "snare"],
        {"training_instruments": ["Kick", "Snare", "Toms", "Hh", "Ride", "Crash"]},
    )

    assert reason == "audio_separator_mdxc_runtime_primary_secondary_only"


def test_drumsep_helper_classifies_cuda_illegal_memory_access_with_guidance():
    helper_path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_cuda_failure_test", helper_path)
    helper = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(helper)

    reason, guidance = helper._classify_runtime_exception(
        RuntimeError("CUDA error: an illegal memory access was encountered"),
        "cuda",
        {"low_vram": "yes", "total_memory_gib": "4.0", "device_name": "NVIDIA GeForce GTX 1650"},
    )

    assert reason == "cuda_illegal_memory_access"
    assert "Try CPU/low-VRAM mode" in guidance


def test_run_direct_dks_drumsep_helper_preserves_cuda_illegal_memory_access_reason(monkeypatch, tmp_path):
    module = _load_audio_separator_process_module()
    input_path = tmp_path / "input.wav"
    output_root = tmp_path / "stage2_drumsep"
    model_cache_dir = tmp_path / "models"
    result_json = output_root / "drumsep_result.json"
    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    monkeypatch.setattr(module.sys, "executable", str(fake_sys_executable))
    drumsep_python = tmp_path / "helper" / ".venv-drumsep" / "bin" / "python"
    drumsep_python.parent.mkdir(parents=True, exist_ok=True)
    drumsep_python.write_text("#!/bin/sh\n", encoding="utf-8")
    input_path.write_bytes(b"RIFF0000WAVE")
    output_root.mkdir(parents=True, exist_ok=True)
    model_cache_dir.mkdir(parents=True, exist_ok=True)
    result_json.write_text(
        json.dumps(
            {
                "ok": False,
                "error_stage": "stage2_separate",
                "error_reason": "cuda_illegal_memory_access",
                "message": "RuntimeError: CUDA error: an illegal memory access was encountered",
                "guidance": "CUDA Drum Kit Split failed on this GPU. Try CPU/low-VRAM mode or rebuild/repair runtime.",
                "gpu_low_vram": "yes",
                "gpu_total_memory_gib": "4.0",
                "gpu_device_name": "NVIDIA GeForce GTX 1650",
            }
        ),
        encoding="utf-8",
    )

    class FakeProcess:
        returncode = 1

        def poll(self):
            return 1

        def kill(self):
            return None

    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: FakeProcess())

    ok, stems, reason, detail = module._run_direct_dks_drumsep_helper(
        input_path,
        output_root,
        model_cache_dir,
        drumsep_python,
        "MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
        route="wrapper",
        device="cuda",
        requested_device="auto",
        backend_runtime="cuda",
    )

    assert ok is False
    assert stems == {}
    assert reason == "cuda_illegal_memory_access"
    assert "Try CPU/low-VRAM mode" in detail
    assert "gpu_low_vram=yes" in detail


def test_direct_dks_cpu_runtime_missing_guidance_is_explicit(capsys):
    module = _load_audio_separator_process_module()
    module._emit_direct_dks_stage2_runtime_markers(
        "drumsep_cpu_runtime_missing",
        Path("C:/Users/Test/AppData/Local/STEMwerk/.venv-drumsep/Scripts/python.exe"),
        "",
    )
    stderr = capsys.readouterr().err
    assert "error_reason=drumsep_cpu_runtime_missing" in stderr
    assert "CPU Drum Kit Split runtime is missing or broken." in stderr


def test_source_contamination_diagnostics_flag_unc_and_pythonpath(monkeypatch, capsys):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv("PYTHONPATH", r"\\Laptop\VST\H_DUMP\Installers\Music\Music Tools\StemWerk\vendor")
    monkeypatch.setattr(module, "_drumsep_helper_path", lambda: Path(r"\\Laptop\VST\H_DUMP\Installers\Music\Music Tools\StemWerk\_internal\stemwerk_drumsep_process.py"))
    monkeypatch.setattr(module, "stemwerk_core_file", r"\\Laptop\VST\H_DUMP\Installers\Music\Music Tools\StemWerk\vendor\stemwerk-core\src\stemwerk_core\__init__.py")
    monkeypatch.setattr(module, "__file__", r"\\Laptop\VST\H_DUMP\Installers\Music\Music Tools\StemWerk\audio_separator_process.py")

    module._emit_source_contamination_diagnostics()

    stderr = capsys.readouterr().err
    assert "STEMWERK_DIAG source_contamination_detected=yes" in stderr
    assert "pythonpath_env_present" in stderr
    assert "drumsep_helper_unc" in stderr
    assert "stemwerk_core_unc" in stderr


def test_direct_dks_helper_invocation_uses_optional_runtime_not_main_runtime():
    script = Path("scripts/reaper/audio_separator_process.py").read_text()
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    workflow_script = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text()
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

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
    assert "output_validation_reason" in script
    assert "expected_stems" in script
    assert "found_stems" in script
    assert "found_files" in script
    assert "yaml_top_level_keys" in script
    assert "Ignoring separatorScript override outside current install" in main_script
    assert 'setExtStateValue("separatorScript", "")' in main_script
    assert "Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue;" in main_script
    assert 'script:write("unset PYTHONPATH PYTHONHOME\\n")' in main_script
    assert "Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue;" in workflow_script
    assert 'script:write("unset PYTHONPATH PYTHONHOME\\n")' in workflow_script
    assert "normalize_arcname(os.path.relpath(src, parent))" in support_script
    assert "normalize_arcname(os.path.relpath(timing_path, parent))" in support_script


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
    assert "[DirectML runtime]" in script
    assert "[Latest Direct DKS markers]" in script
    assert "drumsep_runtime_selected" in script
    assert "drumsep_gpu_capable" in script
    assert "output_validation_reason" in script
    assert "found_files" in script
    assert "drumsep_install.log" in script
    assert "drumsep_cuda_install.log" in script
    assert "drumsep_rocm_install.log" in script
    assert "drumsep_runtime_cuda.env" in script
    assert "CUDA runtime state" in script
    assert "drumsep_cuda_runtime_status" in script
    assert "drumsep_cuda_python" in script
    assert "ort_cuda_provider" in script
    assert "cuda_runtime_state_file" in script
    assert "drumsep_directml_install.log" in script
    assert "drumsep_runtime_directml.env" in script
    assert "DirectML runtime state" in script
    assert "drumsep_directml_runtime_status" in script
    assert "drumsep_directml_python" in script
    assert "torch_directml_status" in script
    assert "ort_directml_provider" in script
    assert "directml_runtime_state_file" in script
    assert script.index('writeFile(joinPath(bundleDir, "diagnostics.txt"') < script.index('local zipStartedAt = phaseStart("create_zip")')
    assert "local function updateZipTimingFile(" in script
    assert "updateZipTimingFile(zipPath, bundleDir, timingsFile, detectedPythonPath)" in script
    assert 'lines[#lines + 1] = "Latest run summary:"' in script
    assert 'lines[#lines + 1] = "Status: " .. statusSummaryLabel(entry)' in script
    assert 'lines[#lines + 1] = "Workflow: " .. workflowSummaryLabel(entry)' in script
    assert "return tostring((entry and entry.friendly_device) or \"unknown\")" in script
    assert 'lines[#lines + 1] = "Output validation: " .. tostring(entry.output_validation_reason or "unknown")' in script
    assert 'lines[#lines + 1] = "summary: " .. statusSummaryLabel(entry)' in script
    assert 'lines[#lines + 1] = "runtime_selected: " .. tostring(entry.runtime_selected or "unknown")' in script
    assert 'lines[#lines + 1] = "backend_runtime: " .. tostring(entry.backend_runtime or "unknown")' in script
    assert 'lines[#lines + 1] = "workflow_source: " .. tostring(entry.workflow_source or "unknown")' in script
    assert 'lines[#lines + 1] = "exit_code: " .. tostring(entry.exit_code or "unknown")' in script


def test_windows_bootstrap_has_drumsep_directml_runtime_mode_and_state_fields():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text()

    assert 'function GetDrumsepCudaRuntimePythonPath' in script
    assert 'function WriteDrumsepCudaState' in script
    assert 'function VerifyDrumsepCudaRuntime' in script
    assert 'function InstallDrumsepCudaRuntime' in script
    assert 'function GetDrumsepDirectmlRuntimePythonPath' in script
    assert 'function WriteDrumsepDirectmlState' in script
    assert 'function VerifyDrumsepDirectmlRuntime' in script
    assert 'function InstallDrumsepDirectmlRuntime' in script
    assert '$Mode -eq "drumsep-runtime" -or $Mode -eq "drumsep-cuda-runtime" -or $Mode -eq "drumsep-directml-runtime"' in script
    assert 'WriteDrumsepCudaState "error" "missing" "python_missing"' in script
    assert 'WriteDrumsepCudaState "ok" "ok" "ok"' in script
    assert 'LogProgress "Verifying existing DrumSep CUDA runtime"' in script
    assert 'onnxruntime-gpu==$onnxRuntimeGpuVersion' in script
    assert 'DRUMSEP_CUDA_RUNTIME_STATUS=' in script
    assert 'DRUMSEP_CUDA_PYTHON=' in script
    assert 'DRUMSEP_CUDA_MODEL_STATUS=' in script
    assert 'TORCH_CUDA_STATUS=' in script
    assert 'ORT_CUDA_PROVIDER=' in script
    assert 'CUDA_DEVICE=' in script
    assert 'CUDA_DEVICE_ID=' in script
    assert 'WriteDrumsepDirectmlState "error" "missing" "python_missing"' in script
    assert 'WriteDrumsepDirectmlState "ok" "ok" "ok"' in script
    assert 'LogProgress "Verifying existing DrumSep DirectML runtime"' in script
    assert 'torch-directml==$torchDirectMlVersion' in script
    assert 'onnxruntime-directml==$onnxRuntimeDirectMlVersion' in script
    assert 'DRUMSEP_DIRECTML_RUNTIME_STATUS=' in script
    assert 'DRUMSEP_DIRECTML_PYTHON=' in script
    assert 'DRUMSEP_DIRECTML_MODEL_STATUS=' in script
    assert 'TORCH_DIRECTML_STATUS=' in script
    assert 'DIRECTML_DEVICE=' in script
    assert 'DIRECTML_DEVICE_COUNT=' in script
    assert 'ORT_DIRECTML_PROVIDER=' in script
    assert 'function ResolveWindowsFfmpegPath' in script
    assert 'function InvokeWithResolvedFfmpegEnvironment' in script
    assert 'DrumSep DirectML verify using FFmpeg: ' in script
    assert '$env:IMAGEIO_FFMPEG_EXE = $FfmpegPath' in script
    assert 'WriteDrumsepDirectmlState "error" "ok" "ffmpeg_missing"' in script
    assert '$drumsepModelCkptMinimumBytes = 104857600' in script
    assert 'Downloading " + $Label + " with curl (preferred for large assets): ' in script
    assert '"--connect-timeout", "30"' in script
    assert '"--max-time", "1800"' in script
    assert 'curl download failed for " + $Label + " exit=' in script
    assert 'Invoke-WebRequest failed for " + $Label + " attempt " + $attempt + ": " + $_.Exception.Message + " url=" + $Url' in script


def test_windows_offline_drumsep_payload_builder_and_inno_wiring_present():
    shell = Path("installer/windows/build_bundled_model_installers.sh").read_text()
    ps1 = Path("installer/windows/build_bundled_model_installers.ps1").read_text()
    iss = Path("installer/windows/STEMwerk.iss").read_text()
    prep = Path("tools/build_windows_drumsep_payload.py").read_text()

    assert 'tools/build_windows_drumsep_payload.py' in shell
    assert 'STEMWERK_DRUMSEP_WHEEL_PAYLOAD_SUBDIR' in shell
    assert 'STEMWERK_DRUMSEP_MODEL_PAYLOAD_SUBDIR' in shell
    assert 'STEMWERK_OFFLINE_BUNDLED_ALLMODELS=1' in shell
    assert 'drumsep-wheels-nvidia' in shell
    assert 'drumsep-wheels-directml' in shell
    assert 'drumsep-wheels-cpu' in shell

    assert '$env:STEMWERK_DRUMSEP_WHEEL_PAYLOAD_SUBDIR' in ps1
    assert '$env:STEMWERK_DRUMSEP_MODEL_PAYLOAD_SUBDIR' in ps1
    assert '$env:STEMWERK_OFFLINE_BUNDLED_ALLMODELS = "1"' in ps1

    assert "#define DrumsepWheelPayloadSubdir GetEnv('STEMWERK_DRUMSEP_WHEEL_PAYLOAD_SUBDIR')" in iss
    assert "#define DrumsepModelPayloadSubdir GetEnv('STEMWERK_DRUMSEP_MODEL_PAYLOAD_SUBDIR')" in iss
    assert 'DestDir: "{app}\\_bundled\\drumsep-wheels"' in iss
    assert 'DestDir: "{app}\\_bundled\\drumsep-models"' in iss
    assert "Result := Result + ' -OfflineBundledAllmodels';" in iss

    assert 'drumsep-wheels-nvidia' in prep
    assert 'audio-separator==0.34.1' in prep
    assert 'onnxruntime==1.26.0' in prep
    assert 'torchaudio==2.4.1+cu121' in prep
    assert 'torch-directml==0.2.5.dev240914' in prep
    assert 'torch==2.12.0' in prep


def test_windows_installers_remove_stemwerk_owned_runtime_and_reaper_scripts_on_uninstall():
    iss = Path("installer/windows/STEMwerk.iss").read_text(encoding="utf-8")
    patch_iss = Path("installer/windows/STEMwerk_Offline_Patch.iss").read_text(encoding="utf-8")
    bundled_shell = Path("installer/windows/build_bundled_installer.sh").read_text(encoding="utf-8")
    bundled_models_shell = Path("installer/windows/build_bundled_model_installers.sh").read_text(encoding="utf-8")
    online_ps1 = Path("installer/windows/build_online_installers.ps1").read_text(encoding="utf-8")
    patch_shell = Path("installer/windows/build_offline_patch_installer.sh").read_text(encoding="utf-8")

    assert "[UninstallDelete]" in iss
    assert 'Type: filesandordirs; Name: "{localappdata}\\STEMwerk"' in iss
    assert 'Type: filesandordirs; Name: "{userappdata}\\REAPER\\Scripts\\STEMwerk-reaper"' in iss
    assert 'Type: files; Name: "{userappdata}\\REAPER\\Scripts\\STEMwerk.lua"' in iss
    assert 'Type: files; Name: "{userappdata}\\REAPER\\Scripts\\STEMwerk_Drum_Kit_Split.lua"' in iss
    assert 'Type: files; Name: "{userappdata}\\REAPER\\Scripts\\STEMwerk_Save_Support_Bundle.lua"' in iss

    assert 'DefaultDirName={userappdata}\\REAPER\\Scripts\\STEMwerk-reaper' in iss
    assert 'AppId={{9A6BDA0D-6A2A-4B36-9C3B-1D4C77E5D0A3}' in iss
    assert 'STEMwerk.iss' in bundled_shell
    assert 'STEMwerk.iss' in bundled_models_shell
    assert 'installer\\\\windows\\\\STEMwerk.iss' in online_ps1

    assert 'Uninstallable=no' in patch_iss
    assert 'STEMwerk_Offline_Patch.iss' in patch_shell
    assert "#define MyAppVersion GetEnv('STEMWERK_VERSION')" in patch_iss
    assert 'OutputBaseFilename=STEMwerk-{#MyAppVersion}-update-patch' in patch_iss
    assert 'export STEMWERK_VERSION="${STEMWERK_VERSION:-$(tr -d \'\\r\\n\' < "$REPO_DIR/VERSION")}"' in patch_shell
    assert 'Source: "..\\..\\scripts\\reaper\\*"; DestDir: "{app}"' in patch_iss
    assert 'Source: "..\\..\\i18n\\*"; DestDir: "{app}\\i18n"' in patch_iss
    assert '[Run]' not in patch_iss
    assert 'STEMwerk_Installer_Windows.ps1' not in patch_iss


def test_release_docs_retire_windows_update_patch_for_2304():
    readme = Path("README.md").read_text(encoding="utf-8")
    release_notes = Path("docs/RELEASE_2.3.0.4.md").read_text(encoding="utf-8")
    installer_readme = Path("installer/README.md").read_text(encoding="utf-8")

    assert "Windows users should uninstall older STEMwerk versions first" in readme
    assert "latest Windows setup/runtime fixes" in readme
    assert "STEMwerk-2.3.0.4-update-patch.exe" not in readme
    assert "The Windows update-patch asset remains retired and is not published." in release_notes
    assert "supersedes the original `2.3.0.0` Windows full installers" in release_notes
    assert "publish only `STEMwerk-Setup-<version>.exe` and `STEMwerk-Setup-<version>-bundled.exe`" in installer_readme
    assert "keep `STEMwerk-<version>-update-patch.exe` retired and unpublished" in installer_readme


def test_release_workflow_uploads_only_supported_windows_installers():
    workflow = Path(".github/workflows/release-installers.yml").read_text(encoding="utf-8")

    assert "Windows update patch remains retired for 2.3.0.4" in workflow
    assert "installer/windows/dist/STEMwerk-Setup-*.exe" in workflow
    assert "STEMwerk_Offline_Patch.iss" not in workflow
    assert 'files: installer/windows/dist/*.exe' not in workflow


def test_ci_fast_quick_script_smoke_installs_pyyaml():
    workflow = Path(".github/workflows/ci-full.yml").read_text(encoding="utf-8")

    assert "Install test dependencies" in workflow
    assert "python -m pip install pytest pyyaml soundfile" in workflow
    assert "python scripts/reaper/audio_separator_process.py --list-models" in workflow


def test_ci_fast_runs_curated_pytest_coverage():
    workflow = Path(".github/workflows/ci-full.yml").read_text(encoding="utf-8")

    assert "Run curated fast pytest coverage" in workflow
    assert "python -m pytest -q" in workflow
    assert "tests/test_device_normalization.py" in workflow
    assert "tests/test_macos_mps_fallback.py" in workflow
    assert "tests/test_model_registry_schema.py" in workflow
    assert "tests/test_windows_normal_route_matrix.py" in workflow
    assert "tests/test_vocals_hq_runtime_proof.py" in workflow
    assert "python -m pytest -q \\\n            tests" in workflow


def test_no_stale_onnxruntime_ci_pins():
    requirements = Path("requirements-ci.txt").read_text(encoding="utf-8")
    smoke = Path(".github/workflows/macos-apple-silicon-backend-smoke.yml").read_text(
        encoding="utf-8"
    )
    workflow = Path(".github/workflows/ci-full.yml").read_text(encoding="utf-8")

    assert "onnxruntime>=1.21,<1.22" not in requirements
    assert "onnxruntime>=1.21,<1.22" not in smoke
    assert "\nonnxruntime\n" in requirements
    assert "pip install onnxruntime-silicon || pip install onnxruntime" in smoke
    assert "tests/test_dependency_constraints.py::test_no_stale_onnxruntime_ci_pins" in workflow


def test_onnxruntime_runtime_pin_policy_is_documented():
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text(
        encoding="utf-8"
    )
    linux_wheelhouse = Path("tools/build_linux_wheelhouse.py").read_text(encoding="utf-8")
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(
        encoding="utf-8"
    )
    directml_constraints = Path("scripts/reaper/constraints/directml.txt").read_text(
        encoding="utf-8"
    )
    macos_payload = Path("tools/build_macos_apple_silicon_payload.py").read_text(
        encoding="utf-8"
    )
    ci_workflow = Path(".github/workflows/ci-full.yml").read_text(encoding="utf-8")

    # Policy: CI Fast runs Python 3.11, production payloads generally use
    # Python 3.12, Linux main keeps generic onnxruntime unpinned pending the
    # ASEP 0.44.3 pin matrix, and DrumSep/DirectML pins remain platform-scoped.
    assert "python-version: 3.11" in ci_workflow
    assert 'ONNX_PACKAGE="onnxruntime"' in linux_bootstrap
    assert 'DRUMSEP_ONNXRUNTIME_VERSION="1.26.0"' in linux_bootstrap
    assert '"onnxruntime"' in linux_wheelhouse
    assert '"onnxruntime==1.26.0"' in linux_wheelhouse
    assert '"onnxruntime-gpu==1.24.4"' in linux_wheelhouse
    assert "onnxruntime-directml==1.24.4" in directml_constraints
    assert '$onnxRuntimeDirectMlVersion = "1.24.4"' in windows_bootstrap
    assert '"onnxruntime"' in macos_payload
    assert '"onnxruntime-silicon"' not in macos_payload
    assert "tests/test_dependency_constraints.py::test_onnxruntime_runtime_pin_policy_is_documented" in ci_workflow


def test_setup_internal_luac_compiles_under_reaper_limits():
    luac = shutil.which("luac")
    if not luac:
        pytest.skip("luac not available")
    result = subprocess.run(
        [luac, "-p", "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_support_bundle_windows_zip_helper_prefers_python_and_writes_clean_entries(tmp_path):
    script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")

    python_call = 'ok, err, method = tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)'
    powershell_call = 'ok, err, method = tryCreateZipWithPowerShell(bundleDir, zipPath)'
    assert script.index(python_call) < script.index(powershell_call)
    assert "normalize_arcname(os.path.relpath(root, parent))" in script
    assert "normalize_arcname(os.path.relpath(src, parent))" in script
    assert "normalize_arcname(os.path.relpath(timing_path, parent))" in script

    bundle_parent = tmp_path / "support"
    bundle_dir = bundle_parent / "STEMwerk-support-bundle-20260707-181043"
    nested_dir = bundle_dir / "nested"
    nested_dir.mkdir(parents=True)

    processing_summary = bundle_dir / "processing_summary.txt"
    timings_path = nested_dir / "support_bundle_timings.txt"
    processing_summary.write_text("summary ok\n", encoding="utf-8")
    timings_path.write_text("timings ok\n", encoding="utf-8")

    zip_path = tmp_path / "bundle.zip"
    windows_parent = r"C:\Users\Ferro\AppData\Roaming\REAPER\STEMwerk-support-bundles"
    windows_bundle = windows_parent + r"\STEMwerk-support-bundle-20260707-181043"

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for root, _dirs, files in os.walk(bundle_dir):
            root_path = Path(root)
            rel_root = os.path.relpath(root_path, bundle_dir)
            windows_root = windows_bundle if rel_root == "." else ntpath.join(windows_bundle, *Path(rel_root).parts)
            if not files:
                arc_dir = ntpath.relpath(windows_root, windows_parent).replace("\\", "/").strip("/")
                zf.writestr(arc_dir + "/", "")
            for name in files:
                src = root_path / name
                windows_src = ntpath.join(windows_root, name)
                arcname = ntpath.relpath(windows_src, windows_parent).replace("\\", "/").strip("/")
                zf.write(src, arcname)

    with zipfile.ZipFile(zip_path, "r") as zf:
        assert zf.testzip() is None
        names = zf.namelist()
        assert all("\\" not in name for name in names)
        assert "STEMwerk-support-bundle-20260707-181043/processing_summary.txt" in names
        assert zf.read("STEMwerk-support-bundle-20260707-181043/processing_summary.txt").decode("utf-8") == "summary ok\n"


def test_windows_main_wheelhouse_builder_keeps_cuda_torch_stack_and_numba_llvm_consistent():
    script = Path("tools/build_windows_wheelhouse.py").read_text()

    assert "def seeded_requirements(include_cuda: bool, include_directml: bool)" in script
    assert '"llvmlite==0.48.0"' in script
    assert '"numba==0.66.0"' in script
    assert 'if include_cuda:' in script
    assert '"torch==2.4.1+cu121"' in script
    assert '"torchvision==0.19.1+cu121"' in script
    assert 'else:' in script
    assert '"torch==2.4.1"' in script
    assert '"torchvision==0.19.1"' in script
    assert 'CUDA_INDEX_URL = "https://download.pytorch.org/whl/cu121"' in script
    assert 'if "+cu121" in spec:' in script
    assert "pip_download_with_index(spec, out_dir, args, CUDA_INDEX_URL)" in script


def test_windows_bootstrap_cuda_runtime_preserves_cu121_local_version_suffix():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text()

    assert '$torchCudaSuffix = "+cu121"' in script
    assert '$torchCudaReq = "torch==$torchVersion$torchCudaSuffix"' in script
    assert '$torchVisionCudaReq = "torchvision==$torchVisionVersion$torchCudaSuffix"' in script
    assert '"torch==$torchVersion$torchCudaSuffix"' in script
    assert '"torchvision==$torchVisionVersion$torchCudaSuffix"' in script
    assert '"torchaudio==$torchAudioVersion$torchCudaSuffix"' in script


def test_windows_nvidia_offline_drumsep_payload_carries_required_runtime_wheels():
    prep = Path("tools/build_windows_drumsep_payload.py").read_text()

    nvidia_block = prep.split('backend="nvidia"', 1)[1].split('BackendSpec(', 1)[0]
    assert 'output_dir="drumsep-wheels-nvidia"' in nvidia_block
    assert '"audio-separator==0.34.1"' in nvidia_block
    assert '"onnxruntime==1.26.0"' in nvidia_block
    assert '"onnxruntime-gpu==1.24.4"' in nvidia_block
    assert '"torch==2.4.1+cu121"' in nvidia_block
    assert '"torchvision==0.19.1+cu121"' in nvidia_block
    assert '"torchaudio==2.4.1+cu121"' in nvidia_block


def test_windows_bootstrap_offline_drumsep_mode_uses_local_payload_only():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text()
    installer = Path("installer/windows/STEMwerk_Installer_Windows.ps1").read_text()

    assert '$offlineBundledAllmodelsMode = ($env:STEMWERK_OFFLINE_BUNDLED_ALLMODELS -eq "1")' in script
    assert '$bundledDrumsepWheelsDir = Join-NormalizedWindowsPath $bundledRuntimeDir @("drumsep-wheels")' in script
    assert '$bundledDrumsepModelsDir = Join-NormalizedWindowsPath $bundledRuntimeDir @("drumsep-models")' in script
    assert 'function HasBundledDrumsepWheels' in script
    assert 'function InstallWithPipOfflineSources' in script
    assert 'function InstallBundledDrumsepPackages' in script
    assert 'InstallWithPipOfflineSources $PythonPath $InstallArgs $Description @($bundledWheelsDir, $bundledDrumsepWheelsDir)' in script
    assert 'LogProgress "Installing bundled Drum Kit runtime..."' in script
    assert 'LogProgress "Installing bundled Drum Kit model assets..."' in script
    assert 'LogProgress "Verifying bundled Drum Kit runtime..."' in script
    assert 'Step "step_5_drumkit" "drum kit runtime and offline models"' in script
    assert 'LogStatusDetail "Preparing Drum Kit separation runtime and offline models. This can take several minutes..."' in script
    assert 'Offline installer is missing bundled DrumSep wheel payload.' in script
    assert 'Offline installer is missing bundled DrumSep model assets.' in script
    assert 'DRUMSEP_OFFLINE_PAYLOAD_STATUS=$script:DrumsepOfflinePayloadStatus' in script
    assert 'DRUMSEP_OFFLINE_PAYLOAD_SOURCE=$script:DrumsepOfflinePayloadSource' in script
    assert 'DRUMSEP_MODEL_SOURCE=$script:DrumsepModelSource' in script
    assert 'DRUMSEP_RUNTIME_WHEEL_SOURCE=$script:DrumsepRuntimeWheelSource' in script
    assert 'LogProgress "Drum Kit Splitter ready."' in script
    assert '[switch]$OfflineBundledAllmodels' in installer
    assert '$env:STEMWERK_OFFLINE_BUNDLED_ALLMODELS = "1"' in installer


def test_linux_variant_matrix_scripts_and_payload_builder_present():
    rebuild = Path("installer/linux/rebuild_linux_artifacts.sh").read_text()
    appimage = Path("installer/linux/build_appimage.sh").read_text()
    deb = Path("installer/linux/build_deb.sh").read_text()
    rpm = Path("installer/linux/build_rpm.sh").read_text()
    arch = Path("installer/linux/build_archpkg.sh").read_text()
    stage = Path("installer/linux/stage_payload.sh").read_text()
    payload_builder = Path("tools/build_linux_variant_payload.py").read_text()
    wheel_builder = Path("tools/build_linux_wheelhouse.py").read_text()

    assert "--matrix" in rebuild
    assert "offline-bundled-cuda-allmodels" in rebuild
    assert "offline-bundled-rocm-allmodels" in rebuild
    assert "offline-bundled-cpu-allmodels" in rebuild
    assert "tools/build_linux_variant_payload.py" in rebuild
    assert "STEMWERK_BUNDLED_PAYLOAD_DIR" in rebuild

    assert 'STEMwerk-$VERSION-x86_64${OUTPUT_SUFFIX}.AppImage' in appimage
    assert 'stemwerk_${VERSION}_${ARCH}${OUTPUT_SUFFIX}.deb' in deb
    assert '${stem}${OUTPUT_SUFFIX}${ext}' in rpm
    assert '${stem}${OUTPUT_SUFFIX}${ext}' in arch
    assert 'Variant $variant requires STEMWERK_BUNDLED_PAYLOAD_DIR.' in stage
    assert 'mkdir -p "$dest_dir/_bundled"' in stage

    assert "model_allowlist.txt" in payload_builder
    assert 'build_wheelhouse(repo_root, "drumsep", spec["backend"]' in payload_builder
    assert 'offline-bundled-rocm-allmodels' in payload_builder
    assert '("drumsep", "rocm")' in wheel_builder
    assert '("main", "cuda")' in wheel_builder


def test_linux_rebuild_matrix_skips_rocm_offline_deb_but_keeps_other_targets():
    rebuild = Path("installer/linux/rebuild_linux_artifacts.sh").read_text()

    assert 'if [[ "$variant" == "offline-bundled-rocm-allmodels" ]]; then' in rebuild
    assert 'if [[ "$target" != "deb" ]]; then' in rebuild
    assert 'Skipping Debian package for $variant: dpkg-deb cannot emit the >10GB ROCm offline allmodels artifact.' in rebuild
    assert 'rm -f "$OUT_DIR"/stemwerk_"$VERSION"_*"${suffix}".deb' in rebuild
    assert 'payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/stemwerk-linux-payload-${variant//[^A-Za-z0-9]/_}-XXXXXX")"' in rebuild


def test_linux_bootstrap_uses_bundled_payloads_for_models_and_offline_pip():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text()

    assert 'BUNDLED_PAYLOAD_DIR="${SCRIPT_DIR}/_bundled"' in script
    assert 'bundled_main_wheelhouse_dir()' in script
    assert 'bundled_drumsep_wheelhouse_dir()' in script
    assert 'pip_install_with_scope()' in script
    assert 'copy_bundled_models_to_cache "${BUNDLED_PAYLOAD_DIR}/models"' in script
    assert 'copy_bundled_models_to_cache "${BUNDLED_PAYLOAD_DIR}/drumsep-models"' in script
    assert 'pip_install_with_scope main "${VENV_PY}" --upgrade pip setuptools wheel' in script
    assert 'pip_install_with_scope drumsep "${_drumsep_py}" --upgrade pip setuptools wheel' in script
    assert 'pip_install_with_scope drumsep "${_py}" --no-cache-dir --index-url "${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}"' in script
    assert '"${BUNDLED_PAYLOAD_DIR}/wheels/main" \\' in script
    assert "bundled_main_has_required_torch_stack()" in script
    assert 'log_step "Bundled main wheelhouse does not contain the requested torch stack; using CPU index fallback"' in script
    assert 'log_step "Bundled main wheelhouse does not contain the requested torch stack; using ROCm index fallback"' in script
    assert 'log_step "Bundled main wheelhouse does not contain the requested torch stack; using default pip index fallback"' in script
    assert '[ -f "${_dir}/torch-${ACTIVE_TORCH_VERSION:-${PINNED_TORCH_VERSION}}-"*.whl ] || return 1' in script
    assert '[ -f "${_dir}/torchvision-${ACTIVE_TORCHVISION_VERSION:-${PINNED_TORCHVISION_VERSION}}-"*.whl ] || return 1' in script
    assert '[ -f "${_dir}/torchaudio-${ACTIVE_TORCHAUDIO_VERSION:-${PINNED_TORCHAUDIO_VERSION}}-"*.whl ] || return 1' in script


def test_linux_wheelhouse_builder_separates_bootstrap_downloads_from_pytorch_index():
    script = Path("tools/build_linux_wheelhouse.py").read_text()
    payload_builder = Path("tools/build_linux_variant_payload.py").read_text()

    assert "BOOTSTRAP_REQUIREMENTS = (" in script
    assert "TORCH_REQUIREMENTS = (" in script
    assert "TORCH_INDEX_DEPENDENCY_PREFIXES = (" in script
    assert "TARGET_PLATFORM_ARGS = [" in script
    assert "TORCH_PLATFORM_ARGS = [" in script
    assert '"--only-binary=:all:"' in script
    assert '"manylinux2014_x86_64"' in script
    assert '"manylinux_2_28_x86_64"' in script
    assert '"linux_x86_64"' in script


def test_linux_main_wheelhouse_pins_scipy_below_numpy_2_breakpoint():
    script = Path("tools/build_linux_wheelhouse.py").read_text()

    assert '("main", "cpu")' in script
    assert '("main", "cuda")' in script
    assert '("main", "rocm")' in script
    assert script.count('"scipy==1.17.1"') >= 3
    assert '"numpy==1.26.4"' in script


def test_linux_rocm_main_wheelhouse_skips_bundled_torch_transitives():
    script = Path("tools/build_linux_wheelhouse.py").read_text()

    assert 'skipped_dependency_names=(' in script
    assert '"torch"' in script
    assert '"torchaudio"' in script
    assert '"torchvision"' in script
    assert '"pytorch-triton-rocm"' in script
    assert 'if dep_name in skipped_dependency_names:' in script


def test_linux_stage_payload_copies_runtime_python_files(tmp_path):
    dest_dir = tmp_path / "payload"
    subprocess.run(
        [
            "bash",
            "-lc",
            f'source installer/linux/stage_payload.sh && copy_linux_payload "$PWD" "{dest_dir}"',
        ],
        check=True,
        cwd=Path.cwd(),
    )

    assert (dest_dir / "audio_separator_process.py").is_file()
    assert (dest_dir / "_internal" / "stemwerk_drumsep_process.py").is_file()
    assert (dest_dir / "vendor" / "stemwerk-core" / "pyproject.toml").is_file()


def test_linux_wheelhouse_builder_targets_cp312_manylinux_and_uses_name_preload():
    script = Path("tools/build_linux_wheelhouse.py").read_text()
    payload_builder = Path("tools/build_linux_variant_payload.py").read_text()

    assert '"--python-version"' in script
    assert '"312"' in script
    assert '"--abi"' in script
    assert '"cp312"' in script
    assert 'def run_bootstrap_downloads(out_dir: Path) -> None:' in script
    assert 'run_bootstrap_downloads(out_dir)' in script
    assert 'for requirement in BOOTSTRAP_REQUIREMENTS:' in script
    assert 'def requirement_name(requirement: str) -> str:' in script
    assert 'def uses_torch_index(requirement: str) -> bool:' in script
    assert 'def wheel_distribution_name(wheel_path: Path) -> Optional[str]:' in script
    assert 'def preloaded_wheel_names(out_dir: Path) -> Dict[str, str]:' in script
    assert 'name = requirement_name(requirement)' in script
    assert 'name in TORCH_REQUIREMENTS' in script
    assert 'TORCH_INDEX_DEPENDENCY_PREFIXES' in script
    assert 'name.startswith(prefix)' in script
    assert 'if uses_torch_index(requirement):' in script
    assert 'cmd += TORCH_PLATFORM_ARGS' in script
    assert 'if spec.index_url and uses_torch_index(requirement):' in script
    assert '*TARGET_PLATFORM_ARGS' in script
    assert 'resolved_names: Dict[str, str] = preloaded_wheel_names(out_dir)' in script

    main_cpu_block = script.split('("main", "cpu"): WheelhouseSpec(', 1)[1].split('),', 1)[0]
    assert '"pip"' not in main_cpu_block
    assert '"setuptools"' not in main_cpu_block
    assert '"wheel"' not in main_cpu_block
    assert '"audio-separator==0.23.0"' in main_cpu_block

    torch_requirements_block = script.split("TORCH_REQUIREMENTS = (", 1)[1].split(")", 1)[0]
    assert '"torch"' in torch_requirements_block
    assert '"torchaudio"' in torch_requirements_block
    assert '"torchvision"' in torch_requirements_block
    assert '"audio-separator"' not in torch_requirements_block
    assert '"onnxruntime"' not in torch_requirements_block
    assert '"samplerate"' not in torch_requirements_block
    assert '"onnxruntime"' in main_cpu_block
    assert '"torch==2.5.1"' in main_cpu_block
    assert '"torch==2.5.1+cpu"' not in main_cpu_block

    drumsep_cpu_block = script.split('("drumsep", "cpu"): WheelhouseSpec(', 1)[1].split('("drumsep", "cuda")', 1)[0]
    assert '"torch==2.12.0+cpu"' in drumsep_cpu_block
    assert '"torchvision==0.27.0+cpu"' in drumsep_cpu_block
    assert 'index_url="https://download.pytorch.org/whl/cpu"' in drumsep_cpu_block
    assert "nvidia-cublas" not in drumsep_cpu_block
    assert "cuda-toolkit" not in drumsep_cpu_block

    assert '"linux-x86_64-cp312"' in payload_builder


def test_macos_build_script_supports_package_variants_without_wiping_dist():
    script = Path("installer/macos/build_pkg.sh").read_text()

    assert 'VARIANT="online"' in script
    assert '--variant online|bundled-apple-silicon|offline-bundled-apple-silicon-mps-allmodels' in script
    assert 'bundled-apple-silicon)' in script
    assert 'offline-bundled-apple-silicon-mps-allmodels)' in script
    assert 'STAGE="$ROOT_DIR/installer/macos/build/$VARIANT/root"' in script
    assert 'mkdir -p "$OUT_DIR" "$STAGE/Users/Shared/STEMwerk-reaper"' in script
    assert 'rm -rf "$STAGE"' in script
    assert 'rm -rf "$OUT_DIR"' not in script
    assert 'OUTPUT_PKG="$OUT_DIR/STEMwerk-$VERSION$OUTPUT_SUFFIX.pkg"' in script
    assert 'Built: $OUTPUT_PKG' in script


def test_macos_build_script_uses_expected_variant_artifact_names():
    script = Path("installer/macos/build_pkg.sh").read_text()

    assert 'OUTPUT_SUFFIX="-bundled-apple-silicon"' in script
    assert 'OUTPUT_SUFFIX="-offline-bundled-apple-silicon-mps-allmodels"' in script
    assert 'OUTPUT_PKG="$OUT_DIR/STEMwerk-$VERSION$OUTPUT_SUFFIX.pkg"' in script


def test_macos_online_variant_excludes_bundled_payload_and_other_variants_stage_it():
    script = Path("installer/macos/build_pkg.sh").read_text()

    assert 'BUNDLED_PAYLOAD_ROOT="$ROOT_DIR/scripts/reaper/_bundled/macos/apple-silicon"' in script
    assert 'rm -rf "$STAGE/Users/Shared/STEMwerk-reaper/_bundled/macos/apple-silicon"' in script
    assert 'rsync -a --delete "$BUNDLED_PAYLOAD_ROOT/" "$PAYLOAD_DEST/"' in script
    assert 'cat > "$PAYLOAD_DEST/.variant-placeholder" <<EOF' in script
    assert 'payload_status=missing' in script


def test_macos_payload_builder_declares_expected_layout_and_manifest():
    script = Path("tools/build_macos_apple_silicon_payload.py").read_text()

    assert '"platform": "macos-apple-silicon"' in script
    assert '"runtime_policy": "mps_preferred_cpu_fallback"' in script
    assert 'output_dir / "ffmpeg"' in script
    assert 'output_dir / "wheels"' in script
    assert 'output_dir / "models"' in script
    assert 'output_dir / "drumsep"' in script
    assert 'ensure_wheelhouse_complete(output_dir / "wheels")' in script
    assert '(output_dir / "manifest.json").write_text' in script


def test_macos_payload_builder_uses_native_python312_wheel_downloads():
    script = Path("tools/build_macos_apple_silicon_payload.py").read_text()

    assert 'Path("/opt/homebrew/bin/python3.12")' in script
    assert 'Path("/usr/local/bin/python3.12")' in script
    assert 'if version == (3, 12):' in script
    assert 'raise RuntimeError("Missing native Python 3.12 interpreter for macOS Apple Silicon payload wheel downloads")' in script
    assert '"audio-separator==0.23.0"' in script
    assert '"torch==2.5.1"' in script
    assert '"torchaudio==2.5.1"' in script
    assert '"onnxruntime"' in script
    assert 'SAMPLERATE_REPAIR_REQUIREMENT = "samplerate==0.2.4"' in script
    assert '"onnxruntime-silicon"' not in script
    assert '"--only-binary=:all:"' in script
    assert '"--find-links"' in script
    assert '"--platform"' not in script
    assert '"--abi"' not in script
    assert 'subprocess.run(cmd, check=True, env=command_env())' in script
    assert 'DIFFQ_REQUIREMENT = "diffq==0.2.4"' in script
    assert 'ensure_diffq_wheel(output_dir / "wheels")' in script
    assert 'ensure_samplerate_repair_wheel(output_dir / "wheels")' in script


def test_macos_payload_builder_requires_local_ffmpeg_and_model_sources():
    script = Path("tools/build_macos_apple_silicon_payload.py").read_text()

    assert 'default="/opt/homebrew/bin/ffmpeg"' in script
    assert 'default="/opt/homebrew/bin/ffprobe"' in script
    assert 'default=str(Path.home() / "Library" / "Application Support" / "STEMwerk" / "python")' in script
    assert 'Library" / "Application Support" / "STEMwerk" / "models"' in script
    assert 'Missing required {label}' in script
    assert '"ffmpeg binary"' in script
    assert '"managed Python runtime payload"' in script
    assert '"core model payload file"' in script
    assert '"drumsep payload file"' in script
    assert 'Incomplete wheelhouse for offline Apple Silicon payload' in script
    assert 'REQUIRED_WHEEL_PREFIXES = (' in script
    assert 'REQUIRED_WHEEL_PATTERNS = (' in script
    assert '"samplerate-0.2.4-*.whl"' in script
    assert '"stemwerk_core-"' in script
    assert '"--no-build-isolation"' in script
    assert 'copy_tree(managed_python_dir, output_dir / "python", "managed Python runtime payload")' in script
    assert 'build_stemwerk_core_wheel(repo_root, output_dir / "wheels", python_executable)' in script


def test_macos_bootstrap_uses_bundled_apple_silicon_payloads_when_present():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'BUNDLED_PAYLOAD_DIR="${SCRIPT_DIR}/_bundled/macos/apple-silicon"' in script
    assert 'bundled_payload_available()' in script
    assert 'bundled_ffmpeg_path()' in script
    assert 'bundled_managed_python_dir()' in script
    assert 'bundled_stemwerk_core_wheel()' in script
    assert 'bundled_wheels_dir()' in script
    assert 'bundled_models_dir()' in script
    assert 'bundled_drumsep_dir()' in script
    assert 'copy_bundled_models_to_cache()' in script
    assert 'install_with_optional_bundled_wheels()' in script


def test_macos_bootstrap_records_bundled_payload_status_markers():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert 'MACOS_BUNDLED_PAYLOAD_STATUS="missing"' in script
    assert 'MACOS_BUNDLED_FFMPEG_STATUS="missing"' in script
    assert 'MACOS_BUNDLED_WHEELHOUSE_STATUS="missing"' in script
    assert 'MACOS_BUNDLED_MODELS_STATUS="missing"' in script
    assert 'MACOS_BUNDLED_DRUMSEP_STATUS="missing"' in script
    assert 'echo "MACOS_BUNDLED_PAYLOAD_STATUS=${MACOS_BUNDLED_PAYLOAD_STATUS}"' in script
    assert 'echo "MACOS_BUNDLED_FFMPEG_STATUS=${MACOS_BUNDLED_FFMPEG_STATUS}"' in script
    assert 'echo "MACOS_BUNDLED_WHEELHOUSE_STATUS=${MACOS_BUNDLED_WHEELHOUSE_STATUS}"' in script
    assert 'echo "MACOS_BUNDLED_MODELS_STATUS=${MACOS_BUNDLED_MODELS_STATUS}"' in script
    assert 'echo "MACOS_BUNDLED_DRUMSEP_STATUS=${MACOS_BUNDLED_DRUMSEP_STATUS}"' in script
    assert script.index('MACOS_BUNDLED_PAYLOAD_STATUS="missing"') < script.index("if bundled_payload_available; then")
    assert script.index('MACOS_BUNDLED_WHEELHOUSE_STATUS="missing"') < script.index("if bundled_payload_available; then")
    assert script.index('MACOS_BUNDLED_PAYLOAD_STATUS="present"') < script.index('mkdir -p "${RUNTIME_BASE}/state"')
    assert script.index('MACOS_BUNDLED_PAYLOAD_STATUS="present"') < script.index('log "MACOS_BUNDLED_PAYLOAD_STATUS=${MACOS_BUNDLED_PAYLOAD_STATUS}"')
    assert script.rindex('MACOS_BUNDLED_PAYLOAD_STATUS="missing"') < script.index("if bundled_payload_available; then")
    assert script.rindex('MACOS_BUNDLED_WHEELHOUSE_STATUS="missing"') < script.index("if bundled_payload_available; then")


def test_macos_bootstrap_prefers_bundled_ffmpeg_and_offline_wheelhouse():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '_bundled_ffmpeg="$(bundled_ffmpeg_path || true)"' in script
    assert 'FFMPEG="${_bundled_ffmpeg}"' in script
    assert 'MACOS_BUNDLED_FFMPEG_STATUS="ok"' in script
    assert '"${_py}" -m pip install --no-index --find-links "${BUNDLED_WHEELS_DIR}" "$@"' in script
    assert 'bundled_managed_python_dir()' in script
    assert 'install_with_optional_bundled_wheels "${VENV_PY}" --upgrade pip' in script
    assert 'install_with_optional_bundled_wheels "${VENV_PY}" -c "${MACOS_CONSTRAINTS_FILE}" "${PACKAGE}"' in script
    assert 'Offline bundled installer is missing a local STEMwerk-managed Python runtime payload.' in script


def test_macos_bootstrap_prefers_bundled_stemwerk_core_wheel_and_avoids_build_isolation_for_source_fallback():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '_bundled_core_wheel="$(bundled_stemwerk_core_wheel || true)"' in script
    assert 'CORE_TARGET_DESC="bundled wheel"' in script
    assert 'install_with_optional_bundled_wheels "${_py}" --no-deps "${_target}"' in script
    assert 'install_with_optional_bundled_wheels "${_py}" --no-build-isolation --no-deps "${_target}"' in script
    assert 'install_stemwerk_core_target "${VENV_PY}" "${CORE_TARGET}" "${CORE_TARGET_DESC}"' in script


def test_macos_bootstrap_seeds_bundled_models_and_drumsep_before_ready_checks():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert '_bundled_models_dir="$(bundled_models_dir || true)"' in script
    assert 'copy_bundled_models_to_cache "${_bundled_models_dir}" "$(model_cache_dir)"' in script
    assert 'MACOS_BUNDLED_MODELS_STATUS="seeded"' in script
    assert '_bundled_drumsep_dir="$(bundled_drumsep_dir || true)"' in script
    assert 'copy_bundled_models_to_cache "${_bundled_drumsep_dir}" "$(model_cache_dir)"' in script
    assert 'MACOS_BUNDLED_DRUMSEP_STATUS="seeded"' in script
    assert 'if [ "${MAC_ARCH}" = "x86_64" ]; then' in script
    assert 'READY_RUNTIME_STATUS="skipped"' in script
    assert 'READY_DRUMSEP_MODEL_STATUS="skipped"' in script
    assert 'READY_DETAIL="unsupported_mac_intel"' in script
    assert 'log "drumsep_ready_status=unsupported_mac_intel"' in script
    assert Path("installer/linux/payload/wheels/linux-x86_64-cp312/diffq-0.2.4-cp312-cp312-linux_x86_64.whl").is_file()


def test_drumkit_completion_copy_has_localized_title_and_source_item_words():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    i18n_internal = Path("scripts/reaper/_internal/STEMwerk_i18n.lua").read_text()

    assert 'trSafeValue("drumkit_complete_title", "Direct Kit completed successfully!")' in main_script
    assert 'trPlural(srcCount, "drumkit_result_source_item_one", "drumkit_result_source_item_many"' in main_script
    assert 'trPlural(sourceCount, "drumkit_result_source_item_one", "drumkit_result_source_item_many"' in main_script
    assert 'trPlural(stemsCreated, "drumkit_result_track_one", "drumkit_result_track_many", "drum track", "drum tracks")' in main_script

    assert 'drumkit_complete_title = "Direct Kit completed successfully!"' in langs
    assert 'drumkit_complete_title = "Direct Kit succesvol voltooid!"' in langs
    assert 'drumkit_complete_title = "Direct Kit erfolgreich abgeschlossen!"' in langs
    assert 'drumsep_backend_limited_title = "Drum Kit backend not yet supported."' in langs
    assert 'drumsep_backend_limited_title = "Drum Kit-backend wordt nog niet ondersteund."' in langs
    assert 'drumsep_backend_limited_title = "Drum-Kit-Backend wird noch nicht unterstützt."' in langs
    assert 'drumsep_backend_limited_body = "This DrumSep backend currently returned only Kick and Snare; 6 drum parts are required for Direct Kit / Kit Split."' in langs
    assert 'drumsep_intel_mac_unsupported_title = "Drum Kit Split unavailable on Intel Mac"' in langs
    assert 'drumsep_intel_mac_unsupported_body = "Drum Kit Split is not enabled on Intel Mac in this release. Normal CPU stem separation is available. For Drum Kit Split, use Apple Silicon or a supported GPU/accelerated platform."' in langs
    assert 'drumsep_intel_mac_unsupported_title = "Drum Kit Split niet beschikbaar op Intel Mac"' in langs
    assert 'drumsep_intel_mac_unsupported_body = "Drum Kit Split is in deze release niet ingeschakeld op Intel Mac. Normale CPU-stems zijn beschikbaar. Gebruik voor Drum Kit Split Apple Silicon of een ondersteund GPU/versneld platform."' in langs
    assert 'drumsep_intel_mac_unsupported_title = "Drum Kit Split auf Intel Mac nicht verfügbar"' in langs
    assert 'drumsep_intel_mac_unsupported_body = "Drum Kit Split ist in dieser Version auf Intel Macs nicht aktiviert. Normale CPU-Stems sind verfügbar. Verwende für Drum Kit Split Apple Silicon oder eine unterstützte GPU-/beschleunigte Plattform."' in langs
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

    assert 'local presetLabelDrumKit = trSafe("workflow_drumkit_short_label", "Direct Kit") .. " (Z)"' in main_script
    assert 'local presetLabelEdks    = trSafe("workflow_edks_short_label", "Kit Split") .. " (X)"' in main_script
    assert 'local stemsHeader = ((dialogWorkflowSource == DKS_WORKFLOW.SOURCE_DIRECT) or (dialogWorkflowSource == DKS_WORKFLOW.SOURCE_EXTRACT))' in main_script
    assert 'and trSafe("drum_stems_label", "Drum Stems:")' in main_script
    assert 'if drawPresetBtn(presetY, presetLabelDrumKit, {170, 150, 240}, _pa.drumkit) then selectDirectDrumKitWorkflow() end' in main_script
    assert 'if drawPresetBtn(presetY, presetLabelEdks, {150, 132, 228}, _pa.edks) then selectExtractDrumKitWorkflow() end' in main_script
    assert "showExtractKitPlannedNotice()" not in main_script
    assert "local function selectExtractDrumKitWorkflow()" in main_script
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", DKS_WORKFLOW.SOURCE_EXTRACT, false)' in main_script
    assert 'reaper.SetExtState(EXT_SECTION, "active_workflow_source", DKS_WORKFLOW.SOURCE_DIRECT, false)' in main_script
    assert 'activateWorkflowStemSet(isDrumKitWorkflow)' in main_script

    assert 'workflow_drumkit_label = "Direct Kit"' in langs
    assert 'workflow_drumkit_short_label = "Direct Kit"' in langs
    assert 'workflow_edks_label = "Kit Split"' in langs
    assert 'workflow_edks_short_label = "Kit Split"' in langs
    assert 'drum_stems_label = "Drum Stems:"' in langs
    assert 'tooltip_preset_drumkit = "For drum-only tracks or samples. Splits the drum signal directly into kit parts."' in langs
    assert 'tooltip_preset_edks = "Quality mode for full mixes. Separates drums first, then splits them into kit parts."' in langs
    assert 'tooltip_preset_drumkit = "Voor drum-only tracks of samples. Splitst het drumsignaal direct in kitdelen."' in langs
    assert 'tooltip_preset_edks = "Twee-staps kit-split voor meer gedetailleerdere drumscheiding."' not in langs
    assert 'tooltip_preset_edks = "Kwaliteitsmodus voor volledige mixes. Isoleert eerst drums en splitst daarna in kitdelen."' in langs
    assert 'tooltip_preset_drumkit = "Für reine Drum-Tracks oder Samples. Teilt das Drum-Signal direkt in Kit-Teile."' in langs
    assert 'tooltip_preset_edks = "Qualitätsmodus für komplette Mixes. Separiert zuerst Drums und teilt sie dann in Kit-Teile."' in langs
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
    assert 'drum_stems_label = "Drum-Stems:"' in langs
    assert 'drum_stems_label = "Drum-Stems:"' in langs
    assert 'model_label_expanded = "Expanded"' in langs
    assert 'model_expanded_drumkit_desc = "Expanded Drum Kit model for more detailed drum-kit splitting."' in langs
    assert 'model_expanded_drumkit_desc = "Uitgebreid Drum Kit-model voor gedetailleerdere drumkit-splitsing."' in langs
    assert 'model_expanded_drumkit_desc = "Erweitertes Drum-Kit-Modell für detailliertere Drumkit-Trennung."' in langs
    assert 'device = "Gerät:"' in langs
    assert 'selected = "Ausgewählt:"' in langs
    assert 'delete_original = "Original löschen"' in langs
    assert 'tooltip_close = "STEMwerk schließen (ESC)"' in langs
    assert 'progress_stage_splitting_drum_kit = "Stage 2/2: Creating drum parts…"' in langs
    assert 'progress_stage_splitting_drum_kit = "Stap 2/2: Drumpartijen maken…"' in langs
    assert 'progress_stage_splitting_drum_kit = "Schritt 2/2: Drum-Parts werden erstellt…"' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Creating drum parts…"' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Drumpartijen maken…"' in langs
    assert 'progress_stage_preparing_direct_drum_kit = "Drum-Parts werden erstellt…"' in langs
    assert 'progress_stage_extracting_drums = "Isolating drums…"' in langs
    assert 'progress_stage_extracting_drums = "Drums isoleren…"' in langs
    assert 'progress_stage_extracting_drums = "Drums werden isoliert…"' in langs
    assert 'progress_stage_queued_drumsep = "Queued for drum kit..."' in langs
    assert 'progress_stage_queued_drumsep = "In wachtrij voor drumkit..."' in langs
    assert 'progress_stage_queued_drumsep = "In Warteschlange für Drumkit..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Preparing Kit Split stage 2..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Kit Split stap 2 voorbereiden..."' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Kit Split Stufe 2 vorbereiten..."' in langs
    assert 'mt_parallel_cap = "Parallel cap %d"' in langs
    assert 'mt_parallel_cap = "Parallel limiet %d"' in langs
    assert 'mt_parallel_cap = "Parallel-Limit %d"' in langs
    assert 'progress_stage_label_1_of_2 = "Stage 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Stage 2/2"' in langs
    assert 'progress_stage_label_1_of_2 = "Stap 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Stap 2/2"' in langs
    assert 'progress_stage_label_1_of_2 = "Schritt 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Schritt 2/2"' in langs
    assert 'progress_stage2_serialized_caption = "Stage 2 serialized for stability"' in langs
    assert 'progress_stage2_serialized_caption = "Stap 2 serieel voor stabiliteit"' in langs
    assert 'progress_stage2_serialized_caption = "Stufe 2 seriell für Stabilität"' in langs
    assert 'progress_dks_extract_route_summary = "Drums extract → Kit Split"' in langs
    assert 'progress_dks_extract_route_summary = "Drums extraheren → Kit Split"' in langs
    assert 'progress_dks_extract_route_summary = "Drums extrahieren → Kit Split"' in langs
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
    assert 'direct_drum_kit_folder_suffix = "Direct Kit"' in langs
    assert 'drum_kit_split_folder_suffix = "Kit Split"' in langs
    assert 'edks_complete_title = "Kit Split completed successfully!"' in langs
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
    assert 'trSafe("workflow_drumkit_label", "Direct Kit") .. "\\n" .. trSafe("tooltip_preset_drumkit", "For drum-only tracks or samples. Splits the drum signal directly into kit parts.")' in main_script
    assert 'trSafe("workflow_edks_label", "Kit Split") .. "\\n" .. trSafe("tooltip_preset_edks", "Quality mode for full mixes. Separates drums first, then splits them into kit parts.")' in main_script
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
    assert 'progress_stage2_serialized_caption' not in main_script
    assert 'pctText = trSafeValue("progress_stage_label_2_of_2", "Stage 2/2")' not in main_script


def test_drumkit_direct_route_uses_drum_specific_folder_suffix_and_runtime_device_breadcrumbs():
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text()
    workflow_script = Path("scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text()

    assert 'function activeDrumKitFolderSuffix()' in main_script
    assert 'return trSafeValue("drum_kit_split_folder_suffix", "Kit Split")' in main_script
    assert 'return trSafeValue("direct_drum_kit_folder_suffix", "Direct Kit")' in main_script
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
    assert 'if multiTrackQueue and multiTrackQueue.active and SETTINGS and SETTINGS.parallelProcessing then' not in script
    assert 'stage2Compact = stage2Compact .. " " .. tostring(deviceDetail)' not in script
    assert 'progress_dks_extract_route_summary' in script
    assert 'local routeSummaryLeft, routeSummaryRight = buildProgressRouteSummary(deviceDetail)' in script
    assert 'inlineStageText = inlineStageText .. " [" .. tostring(footerDeviceDetail) .. "]"' not in script
    assert "function normalizeStemPathMap(stemPaths)" in script
    assert "function resolveStemSetForPaths(stemPaths)" in script
    assert 'if stemPathMapLooksLikeDrumKit(stemPaths) then' in script
    assert 'function activeDrumKitWorkflowTitle()' in script
    assert 'return trSafeValue("workflow_edks_label", "Kit Split")' in script
    assert 'return trSafeValue("workflow_drumkit_label", "Direct Kit")' in script
    assert 'return trSafeValue("workflow_edks_short_label", "Kit Split")' in script
    assert 'return trSafeValue("workflow_drumkit_short_label", "Direct Kit")' in script
    assert 'return trSafeValue("route_badge_normal", "Normal STEMwerk")' in script
    assert 'setTooltipWithShortcut(col2X, stemY, colW, btnH, trSafe(tooltipKey, displayName .. " [" .. stem.key .. "]"), stem.key, stem.color)' in script
    assert 'function activeDrumKitFolderSuffix()' in script
    assert 'function activeDrumKitCompleteTitle()' in script
    assert 'return trSafeValue("edks_complete_title", "Kit Split completed successfully!")' in script
    assert 'return trSafeValue("drumkit_complete_title", "Direct Kit completed successfully!")' in script
    assert 'T("drumkit_result_time_selection_created") or "%d %s created from time selection."' in script
    assert 'T("drumkit_result_created_generic") or "%d %s created."' in script
    assert 'local drumKitFooterMode = workflowModeFooter == DKS_WORKFLOW.WORKFLOW_DRUMKIT' in script
    assert 'local footerStemSet = drumKitFooterMode and DRUMKIT_STEMS or STEMS' in script
    assert 'locLine = trFmt("footer_line_location_simple", "Location: %s", baseLoc)' in script
    assert 'locLine = trFmt("footer_line_location_simple", "Location: %s", trSafe("in_place", "In-place"))' in script
    assert 'tooltipText = progressState.showTerminal and trSafeValue("tooltip_terminal_close_output", "Close output")' in script
    assert 'textStr = textStr:gsub("%s*%[" .. shortcutEsc .. "%]%s*$", "")' in script
    assert 'footer_drum_stem_folder = "drum-map"' in langs


def test_single_track_footer_hides_normal_route_badge_and_shows_method_line():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local routeBadge = drumKitMode and "" or activeProcessingRouteBadge()' not in script
    assert 'gfx.drawstr(routeBadge)' not in script
    assert 'drawThemeSurfaceBox(routeBadgeX, routeBadgeY, routeBadgeW, routeBadgeH' not in script
    assert 'if isDrumKitWorkflowActive() then' in script
    assert 'local routeSummaryLeft, routeSummaryRight = buildProgressRouteSummary(deviceDetail)' in script
    assert 'local singleTrackMethodLabel = ""' in script
    assert 'singleTrackMethodLabel = "CPU"' in script
    assert 'singleTrackMethodLabel = "GPU"' in script
    assert 'leftParts[#leftParts + 1] = string.format(trSafeValue("result_method_line", "Method: %s"), singleTrackMethodLabel)' in script
    assert 'return trSafeValue("route_badge_normal", "Normal STEMwerk")' in script


def test_single_track_footer_uses_shared_runtime_resolution_without_rocm_cuda_regression():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'footerDeviceDetail = deriveResolvedRuntimeFooter(footerDeviceDetail)' in script
    assert 'function formatUserFacingProcessingDeviceLabel(...)' in script
    assert 'local speedFmt = T("mt_footer_speed_line") or "Speed %.2fx realtime"' in script
    assert 'local mtCancel = T("mt_cancel") or "ESC=cancel"' in script
    assert 'local footerMethod = sanitizeUserFacingMethodLabel(footerDeviceDetail)' in script
    assert 'elseif footerMethod ~= "" or tostring(footerDeviceDetail or "") ~= "" then' in script
    assert 'leftParts[#leftParts + 1] = string.format(trSafeValue("result_method_line", "Method: %s"), singleTrackMethodLabel)' in script
    assert 'local mtSeg = T("mt_seg") or "Seg"' not in script
    assert 'summaryLeft = summaryLeft .. " | " .. segText' not in script
    assert 'return formatUserFacingProcessingDeviceLabel(' in script
    assert 'or lower:find("radeon", 1, true)' in script
    assert 'or lower:match("%f[%a]rtx%s*%d")' in script
    assert 'or lower:match("%f[%a]gtx%s*%d")' in script
    assert 'or lower:match("%f[%a]rx%s*%d")' in script


def test_german_visible_strings_and_fallbacks_do_not_use_ascii_transliterations():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    helpers = Path("scripts/reaper/_internal/STEMwerk_Helpers.lua").read_text(encoding="utf-8")
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
    assert 'device = "Gerät:"' in langs
    assert 'selected = "Ausgewählt:"' in langs
    assert 'tooltip_close = "STEMwerk schließen (ESC)"' in langs


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
    assert "function deriveMultiTrackRuntimeFooter(job)" in script
    assert "function preferredRuntimeSelection(runtimeSelected, stage2Runtime, stage1Runtime, backendRuntime, fallbackDevice)" in script
    assert "progressState._runtimeSelected" in script
    assert "progressState._stage2Runtime" in script
    assert "progressState._stage1Runtime" in script
    assert "progressState._backendRuntime" in script
    assert "progressState._stage2Device" in script
    assert "progressState._stage1Device" in script
    assert "progressState._normalizedDeviceRequest" in script
    assert "progressState._drumsepRuntimeSelectionPolicy" in script
    assert "progressState._drumsepSubprocessEnvProfile" in script
    assert "progressState._drumsepHelperDeviceArg" in script
    assert "progressState._drumsepSchedulerPolicy" in script
    assert "progressState._drumsepSchedulerUsesCpuFallback" in script
    assert "progressState._runtimeGpuCapable" in script
    assert "progressState._runtimeDeviceNames" in script
    assert "function formatUserFacingProcessingDeviceLabel(...)" in script
    assert "local preferred = formatUserFacingProcessingDeviceLabel(" in script
    assert 'if preferred ~= "" then' in script
    assert "function activeDrumsepCpuFallbackLabel()" in script
    assert "function buildDksFooterDeviceIntent(deviceDetail)" in script
    assert "local helperLabel = activeDrumsepCpuFallbackLabel()" in script
    assert 'trSafeValue("progress_drumsep_cpu_fallback", "CPU fallback")' in script
    assert 'trSafeValue("progress_drumsep_helper_cpu", "CPU")' in script
    assert 'local helperCpu = helperDevice == "cpu" or helperEnvProfile == "cpu_isolated"' in script
    assert 'trSafeValue("footer_device_auto_gpu_intent", "Auto [GPU]")' in script
    assert 'trSafeValue("footer_device_auto_cpu_intent", "Auto [CPU]")' in script
    assert 'trSafeValue("footer_device_gpu_intent", "GPU")' in script
    assert 'local gpuResolved = runtimeSel == "mps" or runtimeSel == "rocm" or runtimeSel == "cuda"' in script
    assert "gpuRequested or gpuResolved" in script
    assert "trSafeValue(\"footer_device_auto_gpu_intent\", \"Auto [GPU]\")" in script
    assert "or req:find(\"directml\", 1, true)" in script

    assert "if not isDrumKitWorkflowActive() then" in script
    assert "if not isDrumKitWorkflowActive() then" in script
    assert 'local singleTrackMethodLabel = ""' in script
    assert 'leftParts[#leftParts + 1] = string.format(trSafeValue("result_method_line", "Method: %s"), singleTrackMethodLabel)' in script
    assert 'local segText = string.format("%s: %s", mtSeg, "30")' not in script
    assert "progress_drumsep_cpu_fallback = " in langs
    assert "progress_drumsep_helper_cpu = " in langs
    assert 'footer_device_auto_resolved_gpu = "Auto → GPU runtime: %s"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU runtime"' in langs
    assert 'footer_device_auto_gpu_intent = "Auto [GPU]"' in langs
    assert 'footer_device_auto_cpu_intent = "Auto [CPU]"' in langs
    assert 'footer_device_gpu_intent = "GPU"' in langs
    assert 'footer_device_rocm_label = "AMD ROCm"' in langs
    assert 'footer_device_cuda_label = "NVIDIA CUDA"' in langs
    assert 'footer_device_cpu_label = "CPU"' in langs
    assert 'footer_device_cpu_runtime = "CPU runtime"' in langs
    assert 'footer_device_gpu_runtime = "GPU runtime: %s"' in langs
    assert 'footer_device_cuda_runtime = "NVIDIA CUDA: %s"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU-runtime"' in langs
    assert 'footer_device_cpu_runtime = "CPU-runtime"' in langs
    assert 'footer_device_auto_resolved_cpu = "Auto -> CPU-Runtime"' in langs
    assert 'footer_device_cpu_runtime = "CPU-Runtime"' in langs
    assert 'return formatUserFacingProcessingDeviceLabel(' in script
    assert 'progressState._deviceName' in script
    assert 'local raw = tostring(rawDevice or ""):gsub("^%s+", ""):gsub("%s+$", "")' in script
    assert 'local resolved = formatUserFacingProcessingDeviceLabel(' in script
    assert 'return trSafeValue("footer_device_rocm_label", "AMD ROCm")' in script
    assert 'return trSafeValue("footer_device_cuda_label", "NVIDIA CUDA")' in script
    assert 'return trSafeValue("footer_device_cpu_label", "CPU")' in script
    assert 'if resolved == rocmLabel or resolved == "DirectML" or resolved == mpsLabel or resolved == cpuLabel then' in script
    assert 'compactProgressDeviceToken(deviceDetail, deviceDetail)' in script
    assert 'progressState._stage2Runtime,' in script
    assert 'progressState._stage1Runtime,' in script
    assert 'progressState._backendRuntime,' in script


def test_result_and_progress_labels_prefer_explicit_runtime_over_cuda_device_tokens():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    support = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")

    assert 'local runtimeSelected = preferredRuntimeSelection(' in script
    assert 'data and data.stage2Runtime,' in script
    assert 'data and data.stage1Runtime,' in script
    assert 'data and data.backendRuntime,' in script
    assert 'local explicitLabel = formatUserFacingProcessingDeviceLabel(' in script
    assert 'if explicitLabel == rocmLabel or explicitLabel == cudaLabel or explicitLabel == "DirectML" or explicitLabel == mpsLabel or explicitLabel == cpuLabel then' in script
    explicit_label_block = script.split('local explicitLabel = formatUserFacingProcessingDeviceLabel(', 1)[1].split('local rocmLabel =', 1)[0]
    assert 'data and data.methodLabel' not in explicit_label_block
    assert 'if runtimeSelected == "rocm" or deviceRequest == "rocm" then' in script
    assert 'return sanitizeUserFacingMethodLabel("rocm")' in script
    assert 'function sanitizeUserFacingMethodLabel(candidate)' in script
    assert 'return formatUserFacingProcessingDeviceLabel(candidate)' in script
    assert 'if sawCudaToken and sawAmdRocmLike and not sawNvidiaCuda then' in script
    assert 'if lower == "rocm" or lower:find("rocm", 1, true) or lower:find("hip", 1, true) then' in script
    assert 'if lower == "mps" or lower:find("apple mps", 1, true) or lower:find("mps", 1, true) then' in script
    assert 'return trSafeValue("device_mps_label", "Apple MPS")' in script
    assert 'return trSafeValue("footer_device_rocm_label", "AMD ROCm")' in script
    assert 'return trSafeValue("footer_device_cuda_label", "NVIDIA CUDA")' in script
    assert '"backend_runtime", "audio_separator_version", "requested_device", "effective_device",' in support
    assert '"model_device", "direct_demix_keys", "drumsep_direct_demix_gate",' in support
    assert '"drumsep_direct_demix_gate_reason", "drumsep_mps_direct_demix_gate",' in support
    assert 'appendKey(lines, "torch.version.hip"' in support
    assert 'appendKey(lines, "torch.cuda.is_available"' in support
    assert 'appendKey(lines, "torch_device_names"' in support
    assert 'progressState._stage2Runtime,' in script
    assert 'progressState._stage1Runtime,' in script
    assert 'progressState._backendRuntime,' in script
    assert 'local backendRuntime = line:match("backend_runtime=([%w_:%-]+)")' in script
    assert 'function parseRuntimeMetadataFromLogFile(logFile, maxLines)' in script
    assert 'if lineCap > 0 and n >= lineCap then break end' in script


def test_multitrack_progress_scroll_uses_mouse_wheel_delta_tracking():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "lastMouseWheel = 0," in script
    assert 'local wheelDelta = (tonumber(mouseWheel) or 0) - (tonumber(multiTrackQueue.lastMouseWheel) or 0)' in script
    assert 'multiTrackQueue.lastMouseWheel = tonumber(mouseWheel) or 0' in script


def test_multitrack_footer_hides_internal_stage2_scheduling_copy():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "progress_stage2_serialized_caption" not in script
    assert 'local mtTime = T("mt_time") or "Time"' in script
    assert 'local etaText = ""' in script
    assert 'local capLabel = T("mt_parallel_cap") or "Parallel cap %d"' in script
    assert "deriveMultiTrackRuntimeFooter(activeJob)" in script
    assert 'local speedFmt = trSafeProgress("mt_footer_speed_line", "Speed %.2fx realtime")' in script
    assert 'rightParts[#rightParts + 1] = string.format("%s (%s, %d:%02d)", currentLabel, audioDurStr, jobMins, jobSecs)' in script


def test_multitrack_progress_uses_route_aware_monotonic_units():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    progress_render = Path("scripts/reaper/_internal/STEMwerk_Progress_Render.lua").read_text(encoding="utf-8")

    assert "_sep.getProgressTotalUnits = function()" in script
    assert "UI_PROGRESS.multiTrackProgressTotalUnits(sourceCount" in script
    assert "_sep.normalizeJobProgress = function(job, rawPercent, stage)" in script
    assert "UI_PROGRESS.normalizeMultiTrackProgress(rawPercent, stage, workflowSource, job and job.percent)" in script
    assert 'return workflowSource == "dks_extract" and count * 2 or count' in progress_render
    assert "percent = math.min(49, percent)" in progress_render
    assert "percent = 50 + math.floor(percent * 0.45)" in progress_render
    assert "percent = math.max(50, percent)" in progress_render
    assert "job.rawPercent = lastProgress.percent" in script
    assert "job.percent = _sep.normalizeJobProgress(job, lastProgress.percent, lastProgress.stage)" in script


def test_multitrack_progress_mapping_sequences_execute_monotonically():
    lua = subprocess.run(
        [
            "lua",
            "-",
        ],
        input="""
local p = dofile("scripts/reaper/_internal/STEMwerk_Progress_Render.lua")
assert(p.multiTrackProgressTotalUnits(8, "normal") == 8)
assert(p.multiTrackProgressTotalUnits(8, "dks_direct") == 8)
assert(p.multiTrackProgressTotalUnits(8, "dks_extract") == 16)
assert(p.normalizeMultiTrackProgress(25, "Processing", "normal", 0) == 25)
assert(p.normalizeMultiTrackProgress(25, "Splitting drum kit...", "dks_direct", 0) == 25)
local s1 = p.normalizeMultiTrackProgress(48, "Extracting drums...", "dks_extract", 0)
local queued = p.normalizeMultiTrackProgress(50, "Stage 2 queued for DrumSep...", "dks_extract", s1)
local s2start = p.normalizeMultiTrackProgress(1, "Starting Drum Kit runtime...", "dks_extract", queued)
local s2mid = p.normalizeMultiTrackProgress(50, "Splitting drum kit...", "dks_extract", s2start)
local s2end = p.normalizeMultiTrackProgress(99, "Splitting drum kit...", "dks_extract", s2mid)
local writing = p.normalizeMultiTrackProgress(95, "Writing drum tracks...", "dks_extract", s2end)
assert(s1 == 48)
assert(queued == 50)
assert(s2start == 50)
assert(s2mid == 72)
assert(s2end == 94)
assert(writing == 95)
""",
        text=True,
        capture_output=True,
        check=False,
    )
    assert lua.returncode == 0, lua.stderr


def test_multitrack_done_and_overall_progress_are_visually_complete_and_monotonic():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "job.done = true\n                    job.percent = 100" in script
    assert "job.rawPercent = 0\n            job.percent = 0" in script
    assert "local totalUnits = _sep.getProgressTotalUnits()" in script
    assert "local unitsPerSource = tostring(multiTrackQueue.workflowSource or \"\") == DKS_WORKFLOW.SOURCE_EXTRACT and 2 or 1" in script
    assert "local percent = job.done and 100 or math.max(0, math.min(99, tonumber(job.percent) or 0))" in script
    assert "completedUnits = completedUnits + (percent / 100) * unitsPerSource" in script
    assert "local current = allDone and 100 or math.floor((completedUnits / math.max(1, totalUnits)) * 100)" in script
    assert "current = math.max(tonumber(multiTrackQueue.lastOverallProgress) or 0, current)" in script
    assert "multiTrackQueue.lastOverallProgress = 0" in script


def test_multitrack_row_right_column_always_shows_bounded_percentage():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local doneText = T("mt_done_label") or "Done"' in script
    assert "drawProgressText(doneText, tBarX + PS(5), yPos + PS(3), 0.95)" in script
    assert "local rowPercent = job.done and 100 or math.max(0, math.min(99, tonumber(job.percent) or 0))" in script
    assert 'gfx.drawstr(string.format("%d%%", rowPercent))' in script
    assert 'pctText = trSafeValue("progress_stage_label_2_of_2", "Stage 2/2")' not in script
    assert 'gfx.drawstr(isWaiting and (T("progress_waiting") or "Waiting") or (T("mt_done_label") or "Done"))' not in script


def test_multitrack_drumkit_prestart_rows_show_loading_while_waiting_rows_stay_queued():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "job.rawPercent = 0\n    job.percent = 0" in script
    assert "local hasProgressActivity = (tonumber(job.rawPercent) or 0) > 0" in script
    assert "or (tonumber(job.percent) or 0) > 0" in script
    assert "local isActiveDrumKitPrestart = job.startTime ~= nil" in script
    assert "and not job.done" in script
    assert "and not hasProgressActivity" in script
    assert "and DKS_WORKFLOW.isDrumKitSource(workflowSource)" in script
    assert "if hasProgressActivity then\n                    stageText = normalizeProgressStage(job.stage)" in script
    assert 'elseif isActiveDrumKitPrestart then\n                    stageText = T("progress_stage_loading_drum_model") or "Loading drum model..."' in script
    assert 'stageText = T("progress_queued") or "Queued"' in script
    assert "local rowPercent = job.done and 100 or math.max(0, math.min(99, tonumber(job.percent) or 0))" in script


def test_drumkit_prestart_loading_copy_is_localized_without_stage_or_debug_text():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'progress_stage_loading_drum_model = "Loading drum model..."' in langs
    assert 'progress_stage_loading_drum_model = "Drummodel laden..."' in langs
    assert 'progress_stage_loading_drum_model = "Drum-Modell wird geladen..."' in langs
    assert 'T("progress_stage_loading_drum_model")' in script
    assert 'progress_stage_loading_drum_model = "Stage 2/2' not in langs
    assert 'progress_stage_loading_drum_model = "Stap 2/2' not in langs
    assert 'progress_stage_loading_drum_model = "Schritt 2/2' not in langs
    assert "Stage 2 serialized for stability" not in script


def test_drumkit_visible_progress_and_support_summary_hide_raw_cuda_devices():
    py_script = Path("scripts/reaper/audio_separator_process.py").read_text()
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text()

    assert 'print("PROGRESS:1:Extracting drums...", flush=True)' in py_script
    assert 'emit_progress(bounded, "Extracting drums...")' in py_script
    assert 'Extracting drums [{stage1_runtime_device}]' not in py_script
    assert 'lines[#lines + 1] = "device: " .. tostring(entry.device or "unknown")' in support_script
    assert 'lines[#lines + 1] = "friendly_device: " .. tostring(entry.friendly_device or "unknown")' in support_script
    assert "local function friendlyDeviceLabel(rawDevice, runtimeState, entry)" in support_script
    assert 'return "AMD ROCm"' in support_script
    assert 'return "NVIDIA CUDA"' in support_script


def test_runtime_selection_prefers_explicit_rocm_over_cuda_device_fallback():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function preferredRuntimeSelection(runtimeSelected, stage2Runtime, stage1Runtime, backendRuntime, fallbackDevice)' in script
    assert 'if lower == "rocm" or lower:find("rocm", 1, true) or lower:find("hip", 1, true) then' in script
    assert 'return "rocm"' in script
    assert 'if lower == "cuda" or lower:match("^cuda:%d+$") then' in script


def test_drumkit_progress_copy_uses_explicit_stage2_and_kit_split_wording():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    langs = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    progress_render = Path("scripts/reaper/_internal/STEMwerk_Progress_Render.lua").read_text(encoding="utf-8")

    assert 'local routeSummary = trSafeValue("progress_dks_extract_route_summary", "Drums extract → Kit Split")' in script
    assert 'if isDirectDrumKitProgress() then' in progress_render
    assert 'return progressUiLabel("progress_stage_preparing_direct_drum_kit", "Creating drum parts…")' in progress_render
    assert 'if isExtractDrumKitProgress() then' in progress_render
    assert 'return progressUiLabel("progress_stage_extracting_drums", "Isolating drums…")' in progress_render
    assert 'return progressUiLabel("progress_stage_splitting_drum_kit", "Stage 2/2: Creating drum parts…")' in progress_render
    assert 'progress_stage_starting_drum_kit_runtime = "Preparing Kit Split stage 2..."' in langs
    assert 'progress_stage_splitting_drum_kit = "Stage 2/2: Creating drum parts…"' in langs
    assert 'progress_dks_extract_route_summary = "Drums extract → Kit Split"' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Kit Split stap 2 voorbereiden..."' in langs
    assert 'progress_stage_splitting_drum_kit = "Stap 2/2: Drumpartijen maken…"' in langs
    assert 'progress_dks_extract_route_summary = "Drums extraheren → Kit Split"' in langs
    assert 'progress_stage_starting_drum_kit_runtime = "Kit Split Stufe 2 vorbereiten..."' in langs
    assert 'progress_stage_splitting_drum_kit = "Schritt 2/2: Drum-Parts werden erstellt…"' in langs
    assert 'progress_stage_label_1_of_2 = "Schritt 1/2"' in langs
    assert 'progress_stage_label_2_of_2 = "Schritt 2/2"' in langs
    assert 'progress_stage_label_1_of_2 = "Stufe 1/2"' not in langs
    assert 'progress_stage_label_2_of_2 = "Stufe 2/2"' not in langs
    assert 'progress_stage_extracting_drums = "Isolating drums…"' in langs
    assert 'progress_stage_extracting_drums = "Drums isoleren…"' in langs
    assert 'progress_stage_extracting_drums = "Drums werden isoliert…"' in langs
    assert 'Creating drum parts…' in langs
    assert 'Stage 2/2: Creating drum parts…' in langs
    assert 'Splitting kit with DrumSep' not in langs
    assert 'Kit splitten met DrumSep' not in langs
    assert 'Kit mit DrumSep aufteilen' not in langs
    assert 'stage = stage:gsub("^[Ss]tage%s+%d+/%d+:%s*", "")' in progress_render
    assert 'stage = stage:gsub("^[Ss]tap%s+%d+/%d+:%s*", "")' in progress_render
    assert 'stage = stage:gsub("^[Ss]chritt%s+%d+/%d+:%s*", "")' in progress_render
    assert 'local flat = lower:gsub("[%s%.:]+$", "")' in progress_render
    assert 'if flat == "starting backend"' in progress_render
    assert 'or flat == "splitting drum kit"' in progress_render
    assert 'elseif isExtractDrumKitProgress() and (stageIndex or flat == "starting backend") then' in progress_render


def test_german_kit_split_stage_prefixes_are_consistent_and_not_duplicated():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")

    stage1_prefix = 'progress_stage_label_1_of_2 = "Schritt 1/2"'
    stage2_prefix = 'progress_stage_label_2_of_2 = "Schritt 2/2"'
    stage2_copy = 'progress_stage_splitting_drum_kit = "Schritt 2/2: Drum-Parts werden erstellt…"'
    assert stage1_prefix in langs
    assert stage2_prefix in langs
    assert stage2_copy in langs
    assert 'progress_stage_label_1_of_2 = "Stufe 1/2"' not in langs
    assert 'progress_stage_label_2_of_2 = "Stufe 2/2"' not in langs
    assert "Stufe 1/2: Schritt 1/2" not in langs
    assert "Stufe 2/2: Schritt 2/2" not in langs


def test_direct_kit_running_rows_strip_prefixed_stage2_copy_but_extract_keeps_it():
    progress_render = Path("scripts/reaper/_internal/STEMwerk_Progress_Render.lua").read_text(encoding="utf-8")
    main_script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'stage = stage:gsub("^[Ss]tage%s+%d+/%d+:%s*", "")' in progress_render
    assert 'stage = stage:gsub("^[Ss]tap%s+%d+/%d+:%s*", "")' in progress_render
    assert 'stage = stage:gsub("^[Ss]chritt%s+%d+/%d+:%s*", "")' in progress_render
    assert 'if isDirectDrumKitProgress() and stage ~= "" then' in progress_render
    assert 'or flat == "splitting drum kit"' in progress_render
    assert 'return progressUiLabel("progress_stage_preparing_direct_drum_kit", "Creating drum parts…")' in progress_render
    assert 'return progressUiLabel("progress_stage_splitting_drum_kit", "Stage 2/2: Creating drum parts…")' in progress_render
    assert 'local stageIdx = inferProgressStageIndex(progressState.stage)' in main_script
    assert 'local stageBadge = stageIdx == 1' in main_script
    assert 'pctText = trSafeValue("progress_stage_label_2_of_2", "Stage 2/2")' not in main_script


def test_sync_to_reaper_does_not_overwrite_script_local_i18n_with_repo_root_i18n():
    sync_script = Path("scripts/reaper/sync_to_reaper.sh").read_text()
    assert '"${src_dir}/"' in sync_script
    assert '"${repo_root}/i18n/"' not in sync_script


def test_german_visual_and_help_copy_uses_umlauts_for_direct_dks_paths():
    langs = Path("scripts/reaper/i18n/languages.lua").read_text()
    assert "Audio in REAPER auswählen" in langs
    assert "Tracks, Medien-Items oder Zeitauswahl wählen" in langs
    assert "Ausgewählte Multi-Take Items" in langs
    assert "Mehrere Modi (Fast, Quality, Expanded)" in langs
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
    assert 'lower:find("error_reason=drumsep_backend_runtime_limited", 1, true)' in log_script
    assert 'lower:find("output_validation_reason=audio_separator_mdxc_runtime_primary_secondary_only", 1, true)' in log_script

    assert 'print(f"STEMWERK_ERROR_CLASS={model_failure[\'error_class\']}", file=sys.stderr)' in py_script
    assert 'print(f"STEMWERK_ERROR_HINT={model_failure[\'error_hint\']}", file=sys.stderr)' in py_script


def test_backend_limited_drumsep_message_preempts_model_failure_and_generic_no_stems():
    main_script = _read_utf8("scripts/reaper/STEMwerk.lua")

    assert 'lowerLog:find("error_reason=drumsep_backend_runtime_limited", 1, true)' in main_script
    assert 'lowerLog:find("output_validation_reason=audio_separator_mdxc_runtime_primary_secondary_only", 1, true)' in main_script
    assert 'trSafeValue("drumsep_backend_limited_body", "This DrumSep backend currently returned only Kick and Snare; 6 drum parts are required for Direct Kit / Kit Split.")' in main_script
    assert main_script.index('trSafeValue("drumsep_backend_limited_title", "Drum Kit backend not yet supported.")') < main_script.index('local msg = "Drum Kit Split separation failed.\\n"')
    assert 'SW_LOG.readFileSnippet(logPath, 12000)' in main_script


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
    assert 'elseif key == "output_validation_reason" then' in script
    assert 'elseif key == "expected_stems" then' in script
    assert 'elseif key == "found_stems" then' in script
    assert 'elseif key == "found_files" then' in script
    assert 'elseif key == "drumsep_runtime_selected" or key == "runtime_selected" then' in script
    assert 'elseif key == "backend_runtime" then' in script
    assert 'elseif key == "workflow_mode" then' in script
    assert 'elseif key == "workflow_source" then' in script
    assert 'kvAssignLast(entry, "exit_code", tostring(rc))' in script
    assert 'return "Apple MPS"' in script
    assert 'return "AMD ROCm"' in script
    assert 'return "NVIDIA CUDA"' in script
    assert 'return "CPU"' in script
    assert 'return "CPU fallback (supported, slower)"' in script


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
    assert '_guard_out="$("${VENV_PY}" "${_guard_script}" --python "${VENV_PY}" --find-links "${BUNDLED_WHEELS_DIR}" 2>&1)"' in script
    assert '_guard_out="$(${VENV_PY} "${_guard_script}" --python "${VENV_PY}" 2>&1)"' not in script
    assert '"${VENV_PY}" -m pip show audio-separator >/dev/null 2>&1' in script
    assert 'if ! repair_samplerate_if_arch_mismatch "post_audio_separator_install"; then' in script
    assert "samplerate_arch_mismatch_requires_runtime_rebuild" in script
    assert "samplerate_reinstall_failed" in script
    assert 'f"samplerate=={args.repair_version}"' in guard
    assert 'parser.add_argument("--find-links", action="append", default=[])' in guard
    assert 'install_args.append("--no-index")' in guard
    assert 'install_args.extend(["--find-links", link_dir])' in guard
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
    assert 'if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ]; then' in script
    assert 'torch_install_failed|torch_pin_repair_failed|torch_pin_assert_failed)' in script
    assert 'STATUS="ok"' in script
    assert 'STATUS_REASON=""' in script
    assert 'Cleared stale STATUS from earlier pinned torch failure after final runtime verification success' in script


def test_macos_bootstrap_only_clears_stale_torch_pin_status_after_real_final_checks():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    line_no = lambda needle: next(i for i, line in enumerate(script.splitlines(), 1) if needle in line)
    assert line_no('if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ]; then') > line_no('if ! "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then')
    assert line_no('if [ "${FINAL_RUNTIME_VERIFIED}" = "yes" ]; then') > line_no('if ! assert_pinned_torch_stack "${VENV_PY}"; then')


def test_macos_bootstrap_skips_reinstall_when_pinned_torch_stack_already_ok():
    script = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text()

    assert "pinned_torch_stack_already_ok()" in script
    assert 'if pinned_torch_stack_already_ok "${VENV_PY}"; then' in script
    assert "Pinned torch stack already satisfies" in script
    skip_block = script.split('if pinned_torch_stack_already_ok "${VENV_PY}"; then', 1)[1].split("  fi\n", 1)[0]
    assert 'return 0' in skip_block
    assert script.index('if pinned_torch_stack_already_ok "${VENV_PY}"; then') < script.index('"${VENV_PY}" -m pip uninstall -y torch torchvision torchaudio')


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
    assert "if _is_unexpected_cpu_downgrade(device_preference, preview_device_id):" in script


def test_audio_separator_runtime_diagnostics_include_cuda_visibility():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert 'print(f"STEMWERK_DIAG cuda_available={env.get(\'cuda_available\')}", file=sys.stderr)' in script
    assert 'print(f"STEMWERK_DIAG cuda_count={env.get(\'cuda_count\')}", file=sys.stderr)' in script


def test_main_dialog_uses_fresh_live_device_cache_before_async_probe():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    devices = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")

    assert 'local liveProbeCacheApplied, liveProbeCacheReason = applyFreshDeviceProbeCache(cacheOpts)' in script
    assert 'if liveProbeCacheApplied then' in script
    assert 'perfMark("showStemSelectionDialog(): fresh live device cache applied")' in script
    assert 'perfMark("showStemSelectionDialog(): live device probe skipped reason=fresh_cache")' in script
    assert 'local probeStarted = startRuntimeDeviceProbeAsync(true)' in script
    assert 'perfMark("showStemSelectionDialog(): live device probe started")' in script
    assert 'local DEVICE_PROBE_CACHE_TTL_SECONDS = 600' in devices
    assert 'STEMWERK_DEVICE_PROBE_CACHE_PYTHON=' in devices
    assert 'STEMWERK_DEVICE_PROBE_CACHE_SEPARATOR=' in devices
    assert 'if devices then' in devices
    assert 'writeSuccessfulDeviceProbeCache(out, os.time())' in devices
    assert 'function DEVICE_RUNTIME.applyFreshDeviceProbeCache(opts)' in devices
    assert 'return nil, "expired"' in devices
    assert 'return nil, "python_changed"' in devices
    assert 'return nil, "separator_changed"' in devices


def test_device_column_uses_route_aware_runtime_sources_and_can_add_explicit_mps_for_drumkit():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local runtimeDevicesForUi = directDksRoute and buildDirectDksDeviceList() or RUNTIME_DEVICES' in script
    assert 'stateDir .. PATH_SEP .. schedulerRuntimeStateFile("rocm")' in script
    assert 'stateDir .. PATH_SEP .. schedulerRuntimeStateFile("cuda")' in script
    assert 'stateDir .. PATH_SEP .. schedulerRuntimeStateFile("directml")' in script
    assert 'local function isOkState(state, primaryKey, fallbackKey)' in script
    assert 'local function resolveRuntimePython(state, defaultPath)' in script
    assert 'local rocmReady = isOkState(rocmState, "DRUMSEP_ROCM_RUNTIME_STATUS", "STATUS")' in script
    assert 'local rocmPython = resolveRuntimePython(rocmState, defaultRuntimePython(".venv-drumsep-rocm"))' in script
    assert 'local cpuPython = resolveRuntimePython(cpuState, defaultRuntimePython(".venv-drumsep"))' in script
    assert 'local cudaPython = resolveRuntimePython(cudaState, defaultRuntimePython(".venv-drumsep-cuda"))' in script
    assert 'local directmlPython = resolveRuntimePython(directmlState, defaultRuntimePython(".venv-drumsep-directml"))' in script
    assert 'local capabilityState = readEnvFile(stateDir .. PATH_SEP .. "capabilities.env") or {}' in script
    assert 'local cudaStateForUi = cudaState' in script
    assert 'local cudaPythonForUi = cudaPython' in script
    assert 'and schedulerRuntimeHasCudaCapability(cpuState, genericCudaPython, capabilityState)' in script
    assert 'local cudaReady = schedulerRuntimeHasCudaCapability(cudaStateForUi, cudaPythonForUi, capabilityState)' in script
    assert 'local directmlReady = schedulerRuntimeHasDirectmlCapability(directmlState, directmlPython, capabilityState)' in script
    assert 'local cudaDeviceNames = schedulerRuntimeCudaDeviceNames(cudaStateForUi, capabilityState)' in script
    assert 'local directmlDeviceNames = schedulerRuntimeDirectmlDeviceNames(directmlState, capabilityState)' in script
    assert 'rocmReady = rocmReady and rocmPython ~= ""' in script
    assert 'local cpuReady = isOkState(cpuState, "DRUMSEP_RUNTIME_STATUS", "STATUS") and cpuPython ~= ""' in script
    assert 'rocmState.DRUMSEP_ROCM_DEVICE_NAMES' in script
    assert 'local mpsAvailable = false' in script
    assert 'if OS == "macOS" and (ARCH == "arm64" or ARCH == "aarch64") then' in script
    assert 'if id == "mps" or devType == "mps" then' in script
    assert 'if mpsAvailable and cpuReady then' in script
    assert 'add("mps", "Apple MPS", "mps", "device_mps_desc")' in script
    assert 'add("auto", "Auto", "auto", "device_auto_dks_desc")' in script
    assert 'if directmlReady then' in script
    assert 'add("directml:" .. tostring(idx), rawName, "directml", "device_directml_desc")' in script
    assert 'add("directml:0", "DirectML 0", "directml", "device_directml_desc")' in script


def test_scheduler_runtime_directml_device_names_prefers_friendly_names_and_ignores_privateuseone_ids():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function schedulerRuntimeDirectmlDeviceNames(state, capabilityState)' in script
    assert 'state and (state.DRUMSEP_DIRECTML_DEVICE_NAMES or state.DRUMSEP_DEVICE_NAMES or state.DIRECTML_DEVICE_NAMES)' in script
    assert 'if lower == "directml" or lower:match("^directml:%d+$") or lower:match("^privateuseone:%d+$") then' in script
    assert 'if devType == "directml" or id:match("^directml:") then' in script
    assert 'addName(dev.fullName or dev.name or dev.uiName or "")' in script
    assert 'for _, rawName in ipairs(schedulerSplitDeviceNameList(capabilityState and capabilityState.DEVICE_NAMES or "")) do' in script
    assert 'd.uiName = T("device_mps_label") or "Apple MPS"' in script
    assert 'SETTINGS.device = directDksRoute and "auto" or "cpu"' in script


def test_i18n_device_copy_matches_normal_auto_mps_behavior_without_experimental_label():
    languages = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    devices = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")
    main = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'device_auto_desc = "Automatically chooses the best available processing. On Apple Silicon, Auto uses Apple MPS for normal stems."' in languages
    assert 'device_auto_desc = "Kiest automatisch de beste beschikbare verwerking. Op Apple Silicon gebruikt Auto Apple MPS voor normale stems."' in languages
    assert 'device_auto_desc = "Wählt automatisch die beste verfügbare Verarbeitung. Auf Apple Silicon verwendet Auto Apple MPS für normale Stems."' in languages
    assert 'device_auto_dks_desc = "Automatically chooses the best available Drum Kit processing.' in languages
    assert 'device_auto_dks_desc = "Kiest automatisch de beste beschikbare Drum Kit-verwerking.' in languages
    assert 'device_auto_dks_desc = "Wählt automatisch die beste verfügbare Drum-Kit-Verarbeitung.' in languages
    assert 'device_mps_label = "Apple MPS"' in languages
    assert 'device_mps_desc = "Use Apple MPS on Apple Silicon. Recommended for normal stems."' in languages
    assert 'device_mps_desc = "Gebruik Apple MPS op Apple Silicon. Aanbevolen voor normale stems."' in languages
    assert 'device_mps_desc = "Apple MPS auf Apple Silicon verwenden. Empfohlen für normale Stems."' in languages
    assert "Apple MPS (Experimental)" not in languages
    assert "Apple MPS (Experimenteel)" not in languages
    assert "Apple MPS (Experimentell)" not in languages
    assert '"Automatically chooses the best available processing."' in devices
    assert 'OS ~= "Windows" and OS ~= "macOS"' in devices
    assert 'noteKey = noteKey or "device_note_cuda_unavailable"' in devices
    assert 'return T("device_mps_label") or "Apple MPS"' in main
    assert 'if (not directDksRoute) and OS == "macOS" and (ARCH == "arm64" or ARCH == "aarch64") then' in main
    assert 'if sawMps then return "CPU" end' not in main


def test_drumsep_runtime_selector_reads_state_python_candidates_before_dedicated_runtime_paths():
    script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert "def _drumsep_runtime_state(" in script
    assert "def _drumsep_state_python_candidates(" in script
    assert 'add(state.get("PYTHON_PATH"))' in script
    assert 'add(state.get("VENV_PYTHON_PATH"))' in script
    assert 'add(state.get("VENV_PYTHON"))' in script
    assert "selected_cpu_python, cpu_detail, cpu_payload, cpu_attempts = _probe_drumsep_runtime_candidates(cpu_candidates, require_gpu=False)" in script
    assert "selected_rocm_python, rocm_detail, rocm_payload, rocm_attempts = _probe_drumsep_runtime_candidates(rocm_candidates, require_gpu=True)" in script


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


def test_result_window_sanitizes_legacy_backend_lines_and_raw_scheduler_tokens():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local function isRawResultBackendToken(line)' in script
    assert 'local isBackendLine = lower:match("^backend%s*:")' in script
    assert 'not isBackendLine and not isRawResultBackendToken(trimmed)' in script
    assert 'lower:find("scheduler_", 1, true)' in script
    assert 'lower:find("backend_not_gpu", 1, true)' in script
    assert 'lower:find("directml_fixed_cap", 1, true)' in script
    assert 'lower:find("mps_fixed_cap", 1, true)' in script
    assert 'lower:find("_cap", 1, true)' in script
    assert 'lower:find("_reason", 1, true)' in script


def test_result_window_keeps_method_line_and_uses_runtime_metadata_sanitizer():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function attachResultRuntimeMetadata(data)' in script
    assert 'local state = type(progressState) == "table" and progressState or nil' in script
    assert 'data.deviceName = tostring((state and state._deviceName) or "")' in script
    assert 'data.effectiveDevice = tostring((state and (state._effectiveDevice or state._drumsepHelperDeviceArg)) or "")' in script
    assert 'function sanitizeUserFacingMethodLabel(candidate)' in script
    assert 'function resolveSingleTrackMethodLabel(data)' in script
    assert 'if methodLabel == "CPU" then return "CPU" end' in script
    assert 'if methodLabel ~= "" then return "GPU" end' in script
    assert 'return sanitizeUserFacingMethodLabel(data and data.methodLabel or "")' in script
    assert 'string.format(trSafeValue("result_method_line", "Method: %s"), methodLabel)' in script
    assert 'local methodLabel = resolveSingleTrackMethodLabel(data)' in script
    assert 'line2 = line2 .. " | " .. string.format(trSafeValue("result_method_line", "Method: %s"), methodLabel)' in script
    assert 'resultData.methodLabel = tostring(resolveResultMethodLabel(resultData) or resultData.methodLabel or "")' in script
    assert 'local resolvedMethod = resolveResultMethodLabel(data)' in script
    assert 'if resolvedMethod ~= "" then' in script
    assert 'data.methodLabel = tostring(resolvedMethod)' in script
    assert 'data.methodLabel = sanitizeUserFacingMethodLabel("gpu")' in script
    assert 'return trSafeValue("footer_device_auto_cpu_intent", "Auto [CPU]")' in script
    assert 'return trSafeValue("footer_device_auto_gpu_intent", "Auto [GPU]")' in script
    assert 'local preferredId, preferredName = line:match("auto_selected_preferred=([%w%-%_:%.]+)%s*%((.+)%)")' in script
    assert 'local effectiveDevice = line:match("effective_device=([%w_:%-]+)")' in script
    assert 'if torchVersion and tostring(torchVersion):lower():find("rocm", 1, true) then' in script
    assert 'progressState._effectiveDevice = info.effectiveDevice' in script
    assert 'progressState._stage2Device or progressState._stage1Device or progressState._effectiveDevice' in script
    assert 'resultData.deviceName = tostring(progressState._deviceName or resultData.deviceName or "")' in script


def test_linux_rocm_labels_do_not_collapse_to_nvidia_when_device_id_is_cuda_token():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function parseRuntimeMetadataFromLogFile(logFile, maxLines)' in script
    assert 'progressState._backendRuntime,' in script
    assert 'progressState._runtimeDeviceNames,' in script
    assert 'local previewDeviceName = line:match("normal_workflow_backend_preview_name=([^\\r\\n]+)")' in script
    assert 'info.devName = previewDeviceName' in script
    assert 'local backend = line:match("^backend=([%w_:%-]+)")' in script
    assert 'info.backendRuntime = backend' in script
    assert 'local drumsepTorchHip = line:match("drumsep_torch_hip=([^\\r\\n]+)")' in script
    assert 'info.runtimeSelected = "rocm"' in script
    assert 'if lower:match("^cuda:%d+") or lower == "cuda" then' in script
    assert 'if resolved == rocmLabel or resolved == "DirectML" or resolved == mpsLabel or resolved == cpuLabel then' in script
    assert 'if sawCudaToken and sawAmdRocmLike and not sawNvidiaCuda then' in script
    assert 'data and data.backendRuntime,' in script
    assert 'data and data.effectiveDevice,' in script
    assert 'data and data.deviceName' in script
    assert 'if explicitLabel == rocmLabel or explicitLabel == cudaLabel or explicitLabel == "DirectML" or explicitLabel == mpsLabel or explicitLabel == cpuLabel then' in script
    assert 'progressState._deviceName = info.devName or progressState._deviceName' in script
    assert 'progressState._backendRuntime = info.backendRuntime or progressState._backendRuntime' in script
    assert 'progressState._runtimeSelected = info.runtimeSelected or progressState._runtimeSelected' in script


def test_normal_workflow_parser_reads_backend_preview_name_for_live_rocm_labels():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    py_script = Path("scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

    assert 'print(f"normal_workflow_backend_preview_device={preview_device_id}", file=sys.stderr)' in py_script
    assert 'print(f"normal_workflow_backend_preview_name={preview_device_name}", file=sys.stderr)' in py_script
    assert 'print(f"backend={backend}", file=sys.stderr)' in py_script
    assert 'local previewDeviceId = line:match("normal_workflow_backend_preview_device=([%w%-%_:%.]+)")' in script
    assert 'local previewDeviceName = line:match("normal_workflow_backend_preview_name=([^\\r\\n]+)")' in script
    assert 'if previewDeviceName and previewDeviceName ~= "" and (not info.devName or info.devName == "") then' in script
    assert 'local backend = line:match("^backend=([%w_:%-]+)")' in script
    assert 'local drumsepTorchHip = line:match("drumsep_torch_hip=([^\\r\\n]+)")' in script


def test_linux_setup_existing_runtime_view_uses_compact_top_right_mode_summary():
    setup_script = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")
    langs = Path("scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    root_langs = Path("i18n/languages.lua").read_text(encoding="utf-8")
    controls_script = Path("scripts/reaper/_internal/STEMwerk_UI_Controls.lua").read_text(encoding="utf-8")

    assert 'local humanized = keyText:gsub("_", " ")' in setup_script
    assert 'if value ~= "" and value ~= keyText and value ~= humanized then' in setup_script
    assert 'local function compactModeSummaryLabel(choice)' in setup_script
    assert 'if id == "support-bundle" then return setupSummaryLabel(id, "Save bundle") end' in setup_script
    assert 'if id == "open-logs" then return setupSummaryLabel(id, "Open logs") end' in setup_script
    assert 'if id == "drumsep-rocm-runtime" then return setupSummaryLabel(id, "DrumKit ROCm") end' in setup_script
    assert 'UI_CONTROLS = dofile(RAW_SCRIPT_DIR .. "STEMwerk_UI_Controls.lua")' in setup_script
    assert 'UI_CONTROLS.drawUtilityControls({' in setup_script
    assert 'setLanguageFn = setLanguage,' in setup_script
    assert 'local topColGap = math.max(12, linuxLineHeight(10))' in setup_script
    assert 'local utilityBottom = utilityY + utilitySize' in setup_script
    assert 'local leftColW = bodyW - summaryW - topColGap' in setup_script
    assert 'local summaryX = bodyX + leftColW + topColGap' in setup_script
    assert 'local summaryY = utilityBottom + utilityGap' in setup_script
    assert 'drawLinuxPanel(summaryX, midPanelY, summaryW, midPanelH' in setup_script
    assert 'gfx.drawstr(setupText("setup_modes_title", "Modes"))' in setup_script
    assert 'local summaryLabel = compactModeSummaryLabel(c)' in setup_script
    assert 'summaryLabel .. " · " .. tostring(c.sub or "")' not in setup_script
    assert 'ellipsizeToWidth(summaryLabel, summaryInnerW - 22' in setup_script
    assert 'local headerBottom = math.max(y, midPanelY + midPanelH)' in setup_script
    assert 'layout.btnY = math.max(layout.btnY, headerBottom + headerGap)' in setup_script
    assert 'setup_summary_drumkit_rocm = "DrumKit ROCm"' in langs
    assert 'setup_modes_title = "Modes"' in langs
    assert 'setup_modes_title = "Modi"' in langs
    assert 'setup_modes_title = "Modes"' in root_langs
    assert 'setup_existing_runtime_found = "Existing runtime found. Choose what to do:"' in root_langs
    assert 'setup_footer_zoom = "Ctrl+wheel zooms text. Use +/- or 0 for text size. Esc = cancel.  Text %.0f%%"' in root_langs
    assert 'state.wasMouseDown = mouseDown' in controls_script
    assert 'state.wasRightMouseDown = rightMouseDown' in controls_script
    assert 'setup_summary_check_only = "Controle"' in langs
    assert 'setup_summary_check_only = "Prüfen"' in langs
    assert 'setup_choice_open_logs_label = "Logs-map openen"' in langs
    assert 'setup_choice_open_logs_label = "Logs öffnen"' in langs
    assert langs == root_langs


def test_native_help_tabs_keep_dedicated_control_click_state():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'helpState.utilityControlsState = helpState.utilityControlsState or {}' in script
    assert 'state = helpState.utilityControlsState,' in script
    assert 'if hover and mouseDown and not helpState.wasMouseDown then clickedTab = i end' in script


def test_ui_click_state_matrix_uses_dedicated_top_right_control_substates():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'GUI.utilityControlsState = GUI.utilityControlsState or {}' in script
    assert 'state = GUI.utilityControlsState,' in script
    assert 'resultWindowState.utilityControlsState = resultWindowState.utilityControlsState or {}' in script
    assert 'ctx.state = resultWindowState.utilityControlsState' in script
    assert 'messageWindowState.utilityControlsState = messageWindowState.utilityControlsState or {}' in script
    assert 'state = messageWindowState.utilityControlsState,' in script
    assert 'progressState.utilityControlsState = progressState.utilityControlsState or {}' in script
    assert 'state = progressState.utilityControlsState,' in script
    assert 'multiTrackQueue.utilityControlsState = multiTrackQueue.utilityControlsState or {}' in script
    assert 'state = multiTrackQueue.utilityControlsState,' in script


def test_multi_track_footer_and_result_use_observed_job_runtime():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert "function updateMultiTrackJobRuntimeMetadata(job)" in script
    assert 'local info = parseRuntimeMetadataFromLogFile(job.logFile, 400)' in script
    assert 'info.backendRuntime,' in script
    assert 'info.directDemixDevice,' in script
    assert 'info.drumsepHelperDeviceArg,' in script
    assert 'info.effectiveDevice' in script
    assert "updateMultiTrackJobRuntimeMetadata(job)" in script
    assert "job and job.runtimeSelected" in script
    assert "multiTrackQueue and multiTrackQueue.runtimeSelected" in script
    assert 'local predictedDrumsepBackend = tostring((multiTrackQueue and multiTrackQueue.drumsepSchedulerBackend) or ""):lower()' in script
    assert 'if requestedDevice == "auto" and predictedDrumsepBackend ~= "" and not runtimeConfirmed then' in script
    assert "job.runtimeMetadataConfirmed = true" in script
    assert "multiTrackQueue.runtimeMetadataConfirmed = true" in script
    assert 'job.deviceName = info.devName or job.deviceName' in script
    assert 'multiTrackQueue.deviceName = job.deviceName' in script
    assert 'resultData.runtimeSelected = tostring(multiTrackQueue.runtimeSelected or "")' in script
    assert 'resultData.backendRuntime = tostring(multiTrackQueue.backendRuntime or "")' in script
    assert 'resultData.effectiveDevice = tostring(multiTrackQueue.effectiveDevice or multiTrackQueue.drumsepHelperDeviceArg or "")' in script
    assert 'resultData.deviceName = tostring(multiTrackQueue.deviceName or "")' in script
    assert 'logNormalFinalMethodDiagnostics("normal_completion", resultData, resultData.methodLabel)' in script


def test_normal_completion_logs_backend_aware_final_method_inputs():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local function logNormalFinalMethodDiagnostics(tag, data, resolvedLabel)' in script
    assert 'SW_LOG.logExecResult(prefix .. "_label_input_device="' in script
    assert 'SW_LOG.logExecResult(prefix .. "_label_input_device_name="' in script
    assert 'SW_LOG.logExecResult(prefix .. "_label_input_backend="' in script
    assert 'SW_LOG.logExecResult(prefix .. "_label_input_runtime_selected="' in script
    assert 'SW_LOG.logExecResult(prefix .. "_label_resolved="' in script
    assert 'logNormalFinalMethodDiagnostics("normal_final", resultData, resultData.methodLabel)' in script


def test_result_window_hides_user_facing_reason_lines_for_backend_tokens():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'elseif sanitizeUserFacingMethodLabel(reasonCode) ~= "" then' in script
    assert 'reason = ""' in script


def test_direct_dks_device_labels_use_shared_user_facing_normalizer():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'function normalizeUserFacingDeviceLabel(name)' in script
    assert 'lbl = lbl:gsub("([Rr][Xx])(%d%d%d%d+)", "%1 %2")' in script
    assert 'local rawName = tostring(name or "")' in script
    assert 'local uiLabel = normalizeUserFacingDeviceLabel(name)' in script
    assert 'name = uiLabel ~= "" and uiLabel or rawName' in script
    assert 'fullName = rawName ~= "" and rawName or (uiLabel ~= "" and uiLabel or rawName)' in script
    assert 'uiName = uiLabel ~= "" and uiLabel or rawName' in script
    assert 'return normalizeUserFacingDeviceLabel(name)' in script
    assert 'function formatUserFacingProcessingDeviceLabel(...)' in script
    assert 'if lower == "mps" or lower:find("apple mps", 1, true) or lower:find("mps", 1, true) then' in script
    assert 'if lower == "cpu" or lower:find("cpu", 1, true) or lower:find("fallback_cpu", 1, true)' in script
    assert 'or lower:find("radeon", 1, true)' in script


def test_direct_dks_device_labels_keep_runtime_ids_unchanged():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'add("cuda:" .. tostring(idx), trimmed, "cuda", "device_cuda_desc")' in script
    assert 'add("cuda:0", "GPU 0", "cuda", "device_cuda_desc")' in script


def test_direct_dks_linux_cuda_device_list_reads_dedicated_cuda_state_and_runtime():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'local cudaState = readEnvFile(stateDir .. PATH_SEP .. schedulerRuntimeStateFile("cuda")) or {}' in script
    assert 'local cudaPython = resolveRuntimePython(cudaState, defaultRuntimePython(".venv-drumsep-cuda"))' in script
    assert 'local genericCudaPython = resolveRuntimePython(cpuState, defaultRuntimePython(".venv-drumsep"))' in script
    assert 'local cudaStateForUi = cudaState' in script
    assert 'and schedulerRuntimeHasCudaCapability(cpuState, genericCudaPython, capabilityState)' in script
    assert 'local cudaReady = schedulerRuntimeHasCudaCapability(cudaStateForUi, cudaPythonForUi, capabilityState)' in script
    assert 'local cudaDeviceNames = schedulerRuntimeCudaDeviceNames(cudaStateForUi, capabilityState)' in script
    assert 'if runtimeKind == "cuda" then' in script
    assert 'return "drumsep_runtime_cuda.env"' in script
    assert 'return schedulerRuntimePythonDefault(".venv-drumsep-cuda")' in script


def test_direct_dks_integrated_amd_filter_uses_raw_runtime_name():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'if lower:find("780m graphics", 1, true) then return true end' in script
    assert 'if lower:find("760m graphics", 1, true) then return true end' in script
    assert 'if not isIntegratedAmdGraphicsName(dev.fullName or dev.name or "") then return false end' in script
    assert 'local cname = tostring(candidate.fullName or candidate.name or "")' in script
    assert 'fullName = rawName ~= "" and rawName or (uiLabel ~= "" and uiLabel or rawName)' in script


def test_direct_dks_integrated_amd_filter_hides_780m_when_discrete_gpu_exists():
    def normalize_user_label(name: str) -> str:
        raw = " ".join(str(name or "").split())
        lbl = raw
        lbl = lbl.replace("(TM)", "").replace("(tm)", "")
        lbl = lbl.replace("(R)", "").replace("(r)", "")
        import re
        lbl = re.sub(r"(?i)amd\s*radeon\s*", "", lbl)
        lbl = re.sub(r"(?i)nvidia\s*geforce\s*", "", lbl)
        lbl = re.sub(r"(?i)nvidia\s*", "", lbl)
        lbl = re.sub(r"(?i)intel\s*", "", lbl)
        lbl = re.sub(r"(?i)\(\s*external\s*\)", "eGPU", lbl)
        lbl = re.sub(r"(?i)\(\s*internal\s*\)", "iGPU", lbl)
        lbl = re.sub(r"(?i)\s*laptop\s*gpu\s*$", "", lbl)
        lbl = re.sub(r"(?i)\s*graphics\s*$", "", lbl)
        lbl = re.sub(r"(?i)\s*gpu\s*$", "", lbl)
        lbl = re.sub(r"([Rr][Xx])(\d\d\d\d+)", r"\1 \2", lbl)
        lbl = " ".join(lbl.split()).strip()
        return lbl or raw

    def is_integrated_amd_graphics_name(name: str) -> bool:
        lower = str(name or "").lower()
        if lower == "":
            return False
        if "780m graphics" in lower:
            return True
        if "760m graphics" in lower:
            return True
        if "graphics" in lower and "radeon" in lower and "rx" not in lower:
            return True
        return False

    def build_direct_dks_devices(names):
        devices = [
            {"id": "auto", "name": "Auto", "fullName": "Auto", "uiName": "Auto"},
            {"id": "cpu", "name": "CPU", "fullName": "CPU", "uiName": "CPU"},
        ]
        for idx, raw_name in enumerate(names):
            raw_name = str(raw_name).strip()
            if not raw_name:
                continue
            ui_label = normalize_user_label(raw_name)
            devices.append(
                {
                    "id": f"cuda:{idx}",
                    "name": ui_label,
                    "fullName": raw_name,
                    "uiName": ui_label,
                }
            )
        return devices

    def should_hide(dev, all_devices):
        if not str(dev["id"]).startswith("cuda:"):
            return False
        if not is_integrated_amd_graphics_name(dev.get("fullName") or dev.get("name") or ""):
            return False
        for candidate in all_devices:
            if candidate is dev:
                continue
            if str(candidate["id"]).startswith("cuda:") and not is_integrated_amd_graphics_name(
                candidate.get("fullName") or candidate.get("name") or ""
            ):
                return True
        return False

    devices = build_direct_dks_devices(["AMD Radeon RX 9070", "AMD Radeon 780M Graphics"])
    visible = [d["uiName"] for d in devices if not should_hide(d, devices)]

    assert visible == ["Auto", "CPU", "RX 9070"]


def test_direct_dks_integrated_amd_filter_keeps_same_behavior_for_direct_and_extract_routes():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'return workflowMode == DKS_WORKFLOW.WORKFLOW_DRUMKIT' in script
    assert 'and DKS_WORKFLOW.isDrumKitSource(workflowSource)' in script


def test_linux_auto_prefers_rx9070_and_ignores_skipped_780m():
    module = _load_audio_separator_process_module()

    devices = [
        {"id": "cuda:0", "name": "AMD Radeon RX 9070"},
        {"id": "cuda:1", "name": "AMD Radeon 780M Graphics"},
    ]

    preferred = module._prefer_linux_amd_device(devices, {"cuda:1"})

    assert preferred is not None
    assert preferred["id"] == "cuda:0"


def test_windows_normal_device_ui_shows_explicit_cuda_label():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    device_section = script.split('local function buildDeviceUiLabel(dev)', 1)[1].split('-- Apply friendly names from deviceMap', 1)[0]
    devices_module = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")

    assert 'local function windowsExplicitGpuLabel(dev, gpuCount)' in script
    assert 'local function nvidiaShortName(base)' in script
    assert 'return short .. suffix' in script
    assert 'return trSafeValue("footer_device_cuda_label", "NVIDIA CUDA") .. suffix' in script
    assert 'if backend == "DML" then' in script
    assert 'return base' in script
    assert 'return "AMD DirectML" .. suffix .. " (" .. base .. ")"' not in script
    assert 'local explicit = windowsExplicitGpuLabel(dev, gpuCount)' in script
    assert 'if explicit ~= "" then' in script
    assert 'return explicit' in script
    assert 'if gpuCount <= 1 then' not in device_section
    assert 'return "GPU"' not in device_section
    assert 'return "GPU" .. tostring(idx)' not in device_section
    assert 'local function buildRuntimeGpuUiLabel(dev, gpuCount)' in devices_module
    assert 'return base' in devices_module
    assert 'return "AMD DirectML" .. suffix .. " (" .. base .. ")"' not in devices_module


def test_windows_directml_short_labels_keep_technical_tooltip_mapping():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")

    assert 'lbl = lbl:gsub("([Rr][Xx])(%d%d%d%d+)", "%1 %2")' in script
    assert 'lbl = lbl:gsub("%s*[Gg]raphics%s*$", "")' in script
    assert 'return base' in script
    assert 'tip = tostring(tip or "") .. "\\n\\n" .. tostring(device.id) .. " - " .. tostring(device.fullName)' in script
    assert 'backend_prefix .. ": " .. backend_label' in script


def test_windows_startup_prefers_fresh_probe_cache_before_generic_capability_devices():
    script = Path("scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    devices = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")

    assert 'trustedWindowsRuntime = getTrustedWindowsRuntimeState()' in script
    assert 'applyTrustedWindowsRuntimeState(trustedWindowsRuntime)' in script
    assert 'local liveProbeCacheApplied, liveProbeCacheReason = applyFreshDeviceProbeCache(cacheOpts)' in script
    assert 'if not liveProbeCacheApplied then' in script
    assert 'cachedDevicesApplied = applyCachedRuntimeDevices(cacheOpts)' in script
    assert 'RUNTIME_DEVICE_UI_SEED_SOURCE = "fallback"' in script
    assert 'function DEVICE_RUNTIME.applyFreshDeviceProbeCache(opts)' in devices
    assert 'markDeviceUiSource("probe")' in devices
    assert 'markDeviceUiSource("runtime_state")' in devices
    assert 'return nil, "python_changed"' in devices


def test_runtime_device_ui_refresh_marks_changed_vs_unchanged_lists():
    devices = Path("scripts/reaper/_internal/STEMwerk_Devices.lua").read_text(encoding="utf-8")

    assert 'local function runtimeDeviceListSignature(devices)' in devices
    assert 'RUNTIME_DEVICE_UI_SEED_SOURCE = source' in devices
    assert 'RUNTIME_DEVICE_UI_REFRESH_REASON = reason' in devices
    assert 'device_ui_seed_source=' in devices
    assert 'device_ui_refresh_reason=' in devices
    assert 'if previousSignature == nextSignature then' in devices
    assert 'markDeviceUiRefreshReason("unchanged")' in devices
    assert 'markDeviceUiRefreshReason("changed")' in devices


def test_ready_to_go_state_is_wired_across_bootstraps_setup_and_support_bundle():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text(encoding="utf-8")
    macos_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh").read_text(encoding="utf-8")
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")
    support_script = Path("scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")
    release_notes = Path("docs/RELEASE_2.3.0.4.md").read_text(encoding="utf-8")

    assert "WriteReadyToGoState" in windows_bootstrap
    assert "EnsureCoreModelCache $python $readyModelDir" in windows_bootstrap
    assert "InstallDrumsepCudaRuntime $python" in windows_bootstrap
    assert "InstallDrumsepDirectmlRuntime $python" in windows_bootstrap
    assert "WriteReadyToGoState $readyRuntime $readyRuntimeStatus $readyDrumsepModelStatus $readyCoreStatus $readyDetail" in windows_bootstrap

    assert "ensure_core_model_cache" in linux_bootstrap
    assert "ensure_drumsep_assets" in linux_bootstrap
    assert 'from stemwerk_core.models import resolve_audio_separator_model_id' in linux_bootstrap
    assert 'sep.load_model(resolve_audio_separator_model_id(model_name))' in linux_bootstrap
    assert 'CORE_MODEL_PREFETCH_STATUS="skipped"' in linux_bootstrap
    assert 'log_step "core_model_prefetch_skipped=${CORE_MODEL_PREFETCH_DETAIL}"' in linux_bootstrap
    assert 'set_status "deps_failed" "core_model_prefetch_failed"' not in linux_bootstrap
    assert 'set_status "deps_failed" "drumsep_ready_runtime_failed"' in linux_bootstrap
    assert 'echo "MAIN_RUNTIME_STATUS=${_main_runtime_status}"' in linux_bootstrap
    assert 'echo "CORE_MODEL_PREFETCH_STATUS=${_core_prefetch_status}"' in linux_bootstrap
    assert 'write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "ok" "${CORE_MODEL_PREFETCH_STATUS}" "${CORE_MODEL_PREFETCH_DETAIL}"' in linux_bootstrap

    assert "ready_to_go_state_file()" in macos_bootstrap
    assert "ensure_core_model_cache" in macos_bootstrap
    assert "ensure_drumsep_assets" in macos_bootstrap
    core_section = macos_bootstrap.split("ensure_drumsep_assets()", 1)[0]
    assert 'STEMWERK_DRUMSEP_DETAIL_FILE="${_detail_file}" "${_py}" - <<PY >> "${LOG_FILE}" 2>&1' not in core_section
    assert 'core_model_prefetch_ffmpeg_path=${_prefetch_ffmpeg_path}' in macos_bootstrap
    assert 'core_model_prefetch_path_prefix=${_prefetch_ffmpeg_dir}' in macos_bootstrap
    assert 'PATH="${_prefetch_path}" FFMPEG_PATH="${_prefetch_ffmpeg_path}" STEMWERK_FFMPEG_PATH="${_prefetch_ffmpeg_path}" IMAGEIO_FFMPEG_EXE="${_prefetch_ffmpeg_path}" "${_py}" - <<PY >> "${LOG_FILE}" 2>&1' in macos_bootstrap
    assert 'STEMWERK_DRUMSEP_DETAIL_FILE="${_detail_file}" "${_py}" - <<PY >> "${LOG_FILE}" 2>&1' in macos_bootstrap
    assert 'detail_path = os.environ.get("STEMWERK_DRUMSEP_DETAIL_FILE", "").strip()' in macos_bootstrap
    assert 'if detail_path:' in macos_bootstrap
    assert 'from stemwerk_core.models import resolve_audio_separator_model_id' in macos_bootstrap
    assert 'sep.load_model(resolve_audio_separator_model_id(model_name))' in macos_bootstrap
    assert 'READY_MAIN_RUNTIME_STATUS="missing"' in macos_bootstrap
    assert 'echo "MAIN_RUNTIME_STATUS=${_main_runtime_status}"' in macos_bootstrap
    assert 'READY_DETAIL="core_model_download_failed"' in macos_bootstrap
    assert 'log "core_model_prefetch_failed=core_model_download_failed"' in macos_bootstrap
    assert 'set_status "deps_failed" "core_model_download_failed"' in macos_bootstrap
    assert 'set_status "deps_failed" "core_model_prefetch_failed"' not in macos_bootstrap
    assert 'DRUMSEP_PREFETCH_DETAIL="$(cat "${_detail_file}" 2>/dev/null || true)"' in macos_bootstrap
    assert 'log "drumsep_model_prefetch_detail=${DRUMSEP_PREFETCH_DETAIL:-unknown}"' in macos_bootstrap
    assert 'set_status "deps_failed" "drumsep_model_download_failed"' in macos_bootstrap
    assert 'set_status "deps_failed" "drumsep_model_prefetch_failed"' in macos_bootstrap
    assert 'write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "${READY_MAIN_RUNTIME_STATUS}"' in macos_bootstrap
    assert 'echo "DRUMSEP_STATUS=${_drumsep_status}"' in macos_bootstrap
    assert 'echo "DKS_SUPPORTED=${_dks_supported}"' in macos_bootstrap
    assert 'echo "NORMAL_STEMS_SUPPORTED=${_normal_stems_supported}"' in macos_bootstrap

    assert 'local readyFile = runtime.runtimeState .. PATH_SEP .. "ready_to_go.env"' in setup_internal
    assert 'if trim(readyState.READY_TO_GO_STATUS or "") ~= "ok" then needsRepair = true end' in setup_internal
    assert 'readyToGoStatus = trim(readyState.READY_TO_GO_STATUS or "") ~= "" and trim(readyState.READY_TO_GO_STATUS or "") or "unknown"' in setup_internal

    assert 'local readyStatePath = joinPath(runtimeStateDir, "ready_to_go.env")' in support_script
    assert 'appendKey(lines, "ready_to_go_status"' in support_script
    assert 'appendKey(lines, "drumsep_status"' in support_script
    assert 'appendKey(lines, "dks_supported"' in support_script
    assert 'appendKey(lines, "normal_stems_supported"' in support_script
    assert 'appendKey(diagnostics, "Capability drumsep_status"' in support_script
    assert 'appendKey(diagnostics, "Capability dks_supported"' in support_script
    assert 'appendKey(diagnostics, "Capability normal_stems_supported"' in support_script
    assert 'collectExpectedFileStatus(statusLines, "ready_to_go.env", readyToGoEnvPath)' in support_script
    assert 'modelDir = getModelCacheDir()' in support_script

    assert "## Pre-release live smoke plan" in release_notes
    assert "READY_TO_GO_SMOKE_PASS" in release_notes
    assert "PRE_RELEASE_SMOKE_MATRIX_BLOCKED" in release_notes


def test_linux_ready_to_go_verify_mode_is_non_destructive_and_reuses_existing_runtime_states():
    linux_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text(encoding="utf-8")
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")

    assert 'if [ "${MODE}" = "ready-to-go-verify" ]; then' in linux_bootstrap
    assert "run_ready_to_go_verify_only()" in linux_bootstrap
    assert "ready_to_go_output_file()" in linux_bootstrap
    assert '_out_file="$(ready_to_go_output_file)"' in linux_bootstrap
    assert 'echo "READY_TO_GO_STATUS=${_ready}"' in linux_bootstrap
    assert 'echo "MAIN_RUNTIME_STATUS=${_main_runtime_status}"' in linux_bootstrap
    assert 'echo "DRUMSEP_READY_RUNTIME_STATUS=${_runtime_status}"' in linux_bootstrap
    assert 'log_step "ready_to_go_state_written=1"' in linux_bootstrap
    assert 'log_step "ready_to_go_state_file=${_out_file}"' in linux_bootstrap
    assert 'log_step "ready_to_go_status=${_ready}"' in linux_bootstrap
    assert 'READY_STATE_FILE="$(ready_to_go_output_file)"' in linux_bootstrap
    assert 'if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" = "${READY_STATE_FILE}" ]; then' in linux_bootstrap
    assert 'log_step "ready_to_go_state_persists_in_state_file=1"' in linux_bootstrap
    assert 'STATE_FILE=""' in linux_bootstrap
    assert 'verify_existing_ready_runtime "${READY_BACKEND}" || true' in linux_bootstrap
    assert 'probe_main_runtime_ready "$(main_runtime_python)" "${BACKEND}"' in linux_bootstrap
    assert 'log_step "Existing DrumSep runtime detected; running verification before reinstall"' in linux_bootstrap
    assert 'log_step "Existing DrumSep ROCm runtime detected; running verification before reinstall"' in linux_bootstrap
    assert 'MODE="ready-to-go-verify"' not in linux_bootstrap
    assert 'if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" != "${READY_STATE_FILE}" ]; then' in linux_bootstrap
    assert linux_bootstrap.index('write_ready_to_go_state "${READY_RUNTIME_KIND}" "${READY_RUNTIME_STATUS}" "${READY_DRUMSEP_MODEL_STATUS}" "${READY_DETAIL}" "${MAIN_READY_STATUS}"') < linux_bootstrap.index('if [ -n "${STATE_FILE}" ] && [ "${STATE_FILE}" = "${READY_STATE_FILE}" ]; then')

    assert 'mode ~= "repair" and mode ~= "rebuild-venv" and mode ~= "drumsep-runtime" and mode ~= "drumsep-rocm-runtime" and mode ~= "ready-to-go-verify"' in setup_internal
    assert 'appendSetupLog(runtime, "Mode: ready-to-go-verify", false)' in setup_internal
    assert 'appendSetupLog(runtime, "Non-destructive: verify cached models/runtimes and write ready_to_go.env only", false)' in setup_internal


def test_windows_ready_to_go_verify_mode_is_non_destructive_and_reuses_existing_runtime_states():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    setup_internal = Path("scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")

    assert 'if ($Mode -eq "ready-to-go-verify") {' in windows_bootstrap
    assert "RunReadyToGoVerifyOnly" in windows_bootstrap
    assert 'function ProbeMainRuntimeReady' in windows_bootstrap
    assert 'function VerifyExistingReadyRuntime' in windows_bootstrap
    assert 'function GetDrumsepRuntimeStatePath' in windows_bootstrap
    assert 'function GetDrumsepDirectmlRuntimeStatePath' in windows_bootstrap
    assert 'function GetDrumsepCudaRuntimeStatePath' in windows_bootstrap
    assert 'function GetMainRuntimePythonPath' in windows_bootstrap
    assert 'function ReadEnvMap' in windows_bootstrap
    assert '"MAIN_RUNTIME_STATUS=$mainRuntimeStatus"' in windows_bootstrap
    assert 'LogProgress ("ready_to_go_state_file=" + $readyStatePath)' in windows_bootstrap
    assert 'LogProgress "ready_to_go_state_written=1"' in windows_bootstrap
    assert 'LogProgress ("ready_to_go_status=" + [string]$readyState["READY_TO_GO_STATUS"])' in windows_bootstrap
    assert '$normalizedReadyStatePath = [System.IO.Path]::GetFullPath($readyStatePath)' in windows_bootstrap
    assert '$normalizedStateFile = if ([string]::IsNullOrWhiteSpace($StateFile)) { "" } else { [System.IO.Path]::GetFullPath($StateFile) }' in windows_bootstrap
    assert 'if ($normalizedStateFile -and ($normalizedStateFile -ieq $normalizedReadyStatePath)) {' in windows_bootstrap
    assert 'LogProgress "ready_to_go_state_persists_in_state_file=1"' in windows_bootstrap
    assert 'WriteReadyToGoState $readyRuntime $readyRuntimeStatus $readyDrumsepModelStatus $readyCoreStatus $readyDetail $mainReadyStatus' in windows_bootstrap
    assert '$env:STEMWERK_BACKEND = $probeBackend' in windows_bootstrap
    assert '$probeResultPath = Join-Path $RuntimeBase "state\\\\main_runtime_ready_probe.txt"' in windows_bootstrap
    assert 'for mod_name in ("audio_separator", "onnxruntime", "stemwerk_core"):' in windows_bootstrap
    assert 'RunHidden $PythonPath @("-c", $probeCode) "Probe main runtime ready" | Out-Null' in windows_bootstrap
    assert 'if ($LASTEXITCODE -eq 0 -and $probeText -eq "ok") {' in windows_bootstrap
    assert 'WriteBootstrapGuard "running" "ready_to_go_verify"' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepRuntimeStatePath) -Encoding ascii' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepDirectmlRuntimeStatePath) -Encoding ascii' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepCudaRuntimeStatePath) -Encoding ascii' in windows_bootstrap
    assert '$resolvedFfmpeg = ResolveWindowsFfmpegPath' in windows_bootstrap
    assert 'LogStatusDetail "FFmpeg already installed"' in windows_bootstrap
    assert 'LogProgress "FFMPEG_SOURCE=existing"' in windows_bootstrap
    assert 'LogProgress ("ffmpeg_existing_ok=" + $resolvedFfmpeg)' in windows_bootstrap
    assert 'LogProgress "ffmpeg_download_skipped=existing_ok"' in windows_bootstrap
    assert "ResolveWindowsFfmpegPath -AllowInstall" in windows_bootstrap
    assert windows_bootstrap.index('$ffmpeg = ResolveWindowsFfmpegPath') < windows_bootstrap.index('$ffmpeg = ResolveWindowsFfmpegPath -AllowInstall'), (
        "Windows repair must probe existing FFmpeg before downloading"
    )

    assert 'local isReadyToGoVerify = mode == "ready-to-go-verify"' in setup_internal
    assert 'local stateFile = runtime.runtimeState .. PATH_SEP .. ((isDrumsepRuntime and "drumsep_runtime.env") or (isDrumsepCudaRuntime and "drumsep_runtime_cuda.env") or (isDrumsepRocmRuntime and "drumsep_runtime_rocm.env") or (isDrumsepDirectmlRuntime and "drumsep_runtime_directml.env") or (isReadyToGoVerify and "ready_to_go.env") or "bootstrap.env")' in setup_internal
    assert 'local launchMode = (isDrumsepRuntime or isDrumsepCudaRuntime or isDrumsepRocmRuntime or isDrumsepDirectmlRuntime or isReadyToGoVerify) and mode or "repair"' in setup_internal


def test_windows_drumsep_runtime_writers_persist_to_dedicated_state_files():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")

    assert 'return Join-Path $RuntimeBase "state\\\\drumsep_runtime.env"' in windows_bootstrap
    assert 'return Join-Path $RuntimeBase "state\\\\drumsep_runtime_directml.env"' in windows_bootstrap
    assert 'return Join-Path $RuntimeBase "state\\\\drumsep_runtime_cuda.env"' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepRuntimeStatePath) -Encoding ascii' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepDirectmlRuntimeStatePath) -Encoding ascii' in windows_bootstrap
    assert '$lines | Out-File -FilePath (GetDrumsepCudaRuntimeStatePath) -Encoding ascii' in windows_bootstrap


def test_windows_bootstrap_prefetch_uses_supported_demucs_model_ids():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")

    assert 'Core model prefetch using FFmpeg: ' in windows_bootstrap
    assert 'Core model prefetch could not prepare download_checks.json' in windows_bootstrap
    assert 'STEMWERK_CORE_MODEL_SUPPORTED_DEMUCS=' in windows_bootstrap
    assert 'ResolveWindowsFfmpegPath -AllowInstall' in windows_bootstrap
    assert 'InvokeWithResolvedFfmpegEnvironment $resolvedFfmpeg {' in windows_bootstrap
    assert 'from stemwerk_core.models import resolve_audio_separator_model_id' in windows_bootstrap
    assert 'sep.load_model(resolve_audio_separator_model_id(model_name))' in windows_bootstrap
    assert '"Demucs v4: htdemucs"' in windows_bootstrap
    assert '"htdemucs.yaml"' in windows_bootstrap
    assert 'function EnsureSharedModelDownloadChecks([string]$ModelDir)' in windows_bootstrap


def test_windows_ffmpeg_status_text_is_context_aware_for_existing_bundled_and_download_paths():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    windows_iss = Path("installer/windows/STEMwerk.iss").read_text(encoding="utf-8")

    assert '$script:FfmpegSource = "missing"' in windows_bootstrap
    assert '$script:FfmpegSource = "bundled"' in windows_bootstrap
    assert '$script:FfmpegSource = "download"' in windows_bootstrap
    assert '$script:FfmpegSource = "existing"' in windows_bootstrap
    assert 'LogStatusDetail "Installing bundled FFmpeg..."' in windows_bootstrap
    assert 'LogStatusDetail "Extracting bundled FFmpeg..."' in windows_bootstrap
    assert 'LogStatusDetail "Downloading FFmpeg..."' in windows_bootstrap
    assert 'LogStatusDetail "Extracting FFmpeg..."' in windows_bootstrap
    assert 'LogProgress "FFMPEG_SOURCE=bundled"' in windows_bootstrap
    assert 'LogProgress "FFMPEG_SOURCE=download"' in windows_bootstrap
    assert 'LogProgress "FFMPEG_SOURCE=existing"' in windows_bootstrap
    assert 'LogProgress "FFmpeg not found; preparing install"' in windows_bootstrap
    assert 'LogProgress "FFmpeg not found; downloading and installing"' not in windows_bootstrap
    assert 'LogProgress ("Bundled FFmpeg archive ready: " + $zipMb + " MB")' in windows_bootstrap
    assert 'LogProgress ("Downloaded FFmpeg archive: " + $zipMb + " MB")' in windows_bootstrap
    assert 'LogProgress "Extracting bundled FFmpeg archive (this can take a moment)"' in windows_bootstrap
    assert 'LogProgress "Extracting FFmpeg archive (this can take a moment)"' in windows_bootstrap
    assert 'if ($script:FfmpegSource) { $lines += "FFMPEG_SOURCE=$script:FfmpegSource" }' in windows_bootstrap

    assert "Detail = 'Installing bundled FFmpeg...'" in windows_iss
    assert "Detail = 'Extracting bundled FFmpeg...'" in windows_iss
    assert "Detail = 'Downloading FFmpeg...'" in windows_iss
    assert "Detail = 'Extracting FFmpeg...'" in windows_iss
    assert "Detail = 'FFmpeg already installed'" in windows_iss
    assert 'RestartIfNeededByRun=no' in windows_iss
    assert 'english.RunOpenGuide=Open Windows setup guide' in windows_iss
    assert 'english.RunOpenLog=Open setup log' in windows_iss


def test_windows_capabilities_write_failure_clears_stale_state_and_fails_bootstrap():
    windows_bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")

    assert '$tmpPath = $Path + ".tmp"' in windows_bootstrap
    assert 'for ($attempt = 1; $attempt -le 3; $attempt++) {' in windows_bootstrap
    assert '[System.IO.File]::Copy($tmpPath, $Path, $true)' in windows_bootstrap
    assert 'LogLine ("WARN: failed to write capabilities file: " + $Path + " (" + $lastErrorMessage + ")")' in windows_bootstrap
    assert 'Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue' not in windows_bootstrap
    assert 'Set-Status "deps_failed" "capabilities_write_failed"' in windows_bootstrap
    assert '$lines += "SAMPLERATE=$SamplerateValue"' in windows_bootstrap
    assert '$lines += "JULIUS=$JuliusValue"' in windows_bootstrap
    assert 'WriteBootstrapGuard $guardStatus $guardReason ""' in windows_bootstrap
    assert 'Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue' in windows_bootstrap


def test_windows_installer_license_text_matches_23_release():
    text = Path("installer/windows/STEMwerk_License_Agreement.txt").read_text(encoding="utf-8")

    assert "Version: 2.3.0.4" in text
    assert "Date: 2026-07-11" in text
    assert "Version: 2.2.2" not in text


def test_windows_installer_keeps_finish_actions_without_forcing_restart_page():
    script = Path("installer/windows/STEMwerk.iss").read_text(encoding="utf-8")

    assert "RestartIfNeededByRun=no" in script
    assert "AlwaysRestart=yes" not in script
    assert 'Description: "{cm:RunOpenGuide}"; Flags: postinstall shellexec skipifsilent' in script
    assert 'Description: "{cm:RunOpenLog}"; Flags: postinstall skipifsilent unchecked' in script


def test_windows_cpu_offline_drumkit_wheelhouse_keeps_numba_and_llvmlite_compatible():
    prep = Path("tools/build_windows_drumsep_payload.py").read_text(encoding="utf-8")
    bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")

    cpu_block = prep.split('backend="cpu"', 1)[1].split("),", 1)[0]
    assert '"llvmlite==0.47.0"' in cpu_block
    assert '"numba==0.65.1"' in cpu_block
    assert '$drumsepLlvmliteVersion = "0.47.0"' in bootstrap
    assert '"llvmlite==$drumsepLlvmliteVersion"' in bootstrap
    assert '"numba==$drumsepNumbaVersion"' in bootstrap


def test_windows_installer_uses_five_step_progress_and_drumkit_finish_copy():
    script = Path("installer/windows/STEMwerk.iss").read_text(encoding="utf-8")

    assert "StepLabelW: TNewStaticText;" in script
    assert "StepTrackW: TPanel;" in script
    assert "StepFillW: TPanel;" in script
    assert "StepLabelW.Caption := '5. Drum Kit';" in script
    assert "SetStepLabelState(StepLabelW, Step = 5, RGBColor(255, 180, 90));" in script
    assert "SetStepBarState(StepTrackW, StepFillW, 5, Step, RGBColor(255, 180, 90));" in script
    assert "FindLastPos('[5/5]', Text)" in script
    assert "FindLastPos('[4/5]', Text)" in script
    assert "FindLastPos('[3/5]', Text)" in script
    assert "FindLastPos('[2/5]', Text)" in script
    assert "FindLastPos('[1/5]', Text)" in script
    assert "What was installed:" in script
    assert "Installed locations:" in script
    assert "Next step:" in script
    assert "%APPDATA%\\REAPER\\Scripts\\STEMwerk-reaper" in script
    assert "%LOCALAPPDATA%\\STEMwerk" in script


def test_windows_update_patch_forces_current_runtime_repair_after_script_update():
    patch_iss = Path("installer/windows/STEMwerk_Offline_Patch.iss").read_text(encoding="utf-8")
    installer = Path("installer/windows/STEMwerk_Installer_Windows.ps1").read_text(encoding="utf-8")
    bootstrap = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    patch_build_ps1 = Path("installer/windows/build_offline_patch_installer.ps1").read_text(encoding="utf-8")

    assert "WizardForm.WelcomeLabel1.Caption := 'STEMwerk update patch';" in patch_iss
    assert "'- STEMwerk for REAPER: previous install -> v' + NewVersion" in patch_iss
    assert "'Patch completed successfully.'" in patch_iss
    assert "Result := '- STEMwerk for REAPER: v' + Trim(DetectedOldVersion) + ' -> v' + NewVersion;" in patch_iss
    assert "ShowReleaseNotesCheckbox.Caption := 'Show what changed in v{#MyAppVersion}';" in patch_iss
    assert 'Source: "..\\..\\scripts\\reaper\\*"; DestDir: "{app}"' in patch_iss
    assert "#define MyAppVersion GetEnv('STEMWERK_VERSION')" in patch_iss
    assert 'OutputBaseFilename=STEMwerk-{#MyAppVersion}-update-patch' in patch_iss
    assert 'STEMwerk_Installer_Windows.ps1' not in patch_iss
    assert '[Run]' not in patch_iss
    assert "BuildVersionTransitionText" in patch_iss
    assert "BuildPatchFinishedSummary" in patch_iss
    assert '$env:STEMWERK_VERSION = $version' in patch_build_ps1
    assert 'STEMWERK_RELEASE_ASSET_VERSION' not in patch_build_ps1
    assert '$bootstrap = Join-NormalizedWindowsPath $scriptRoot @("STEMwerk_Bootstrap_Windows.ps1")' in installer
    assert '$env:STEMWERK_INSTALLER = "1"' in installer
    assert 'if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }' in installer
    assert 'if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }' in installer
    assert 'Step "step_5_drumkit" "drum kit runtime and offline models"' in bootstrap
    assert 'WriteReadyToGoState $readyRuntime $readyRuntimeStatus $readyDrumsepModelStatus $readyCoreStatus $readyDetail $mainRuntimeStatus' in bootstrap
    assert 'WriteDrumsepCudaState "running" "missing" "creating_venv"' in bootstrap
    assert 'WriteDrumsepCudaState "running" "missing" "model_download"' in bootstrap
    assert 'WriteDrumsepCudaState "ok" "ok" "ok" $verifyResult.Probe $verifyResult.FfmpegPath' in bootstrap


def test_windows_setup_guides_are_release_clean_and_describe_offline_allmodels_payloads():
    for path in (
        Path("installer/windows/STEMwerk_Windows_Setup_Guide.md"),
        Path("installer/windows/STEMwerk_Windows_Setup_Guide.nl.md"),
        Path("installer/windows/STEMwerk_Windows_Setup_Guide.de.md"),
    ):
        text = path.read_text(encoding="utf-8")
        assert "95013e6" not in text
        assert "21a59cd" not in text
        assert "e06507c" not in text
        assert "328c614" not in text
        assert "pre-release" not in text.lower()
        assert "offline-bundled-cpu-allmodels" in text
        assert "offline-bundled-nvidia-gpu-allmodels" in text
        assert "offline-bundled-amd-gpu-allmodels" in text
        assert (
            "offline allmodels installers remain on the `2.3.0.0` release line" in text
            or "grote offline allmodels-installers blijven op de `2.3.0.0`-release" in text
            or "großen Offline-Allmodels-Installer bleiben auf der `2.3.0.0`-Release-Linie" in text
            or "volledig offline" in text
            or "vollstaendig offline" in text
        )
        assert "Uninstall removes STEMwerk runtime data and installed STEMwerk REAPER scripts." in text or "De-installeren verwijdert STEMwerk-runtime-data en geinstalleerde STEMwerk REAPER-scripts." in text or "Die Deinstallation entfernt STEMwerk-Runtime-Daten und installierte STEMwerk-REAPER-Skripte." in text
