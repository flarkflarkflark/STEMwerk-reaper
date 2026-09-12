"""Regression tests for the Linux gfx1031 ROCm compatibility override (issue #123).

Some gfx1031 AMD GPUs only run real GPU kernels under the current
ROCm/PyTorch stack when HSA_OVERRIDE_GFX_VERSION=10.3.0 is set before
HIP/ROCm initializes; without it, torch raises "HIP error: invalid device
function" because gfx1031 isn't in that stack's officially supported gfx
target list.

resolveGfx1031RocmOverrideEnv() in scripts/reaper/STEMwerk.lua decides
whether STEMwerk should apply that override for the current job launch. It
must stay narrowly scoped:
    Linux + ROCm backend + gfx1031 hardware -> HSA_OVERRIDE_GFX_VERSION=10.3.0
and must leave every other platform/backend/GPU (including RX 9070/gfx1201,
NVIDIA/CUDA, CPU, Windows, macOS) exactly as before, and must never override
a value the user already set.

The test executes the real function with a plain Lua interpreter, stubbing
the REAPER-facing globals (OS, readCapabilities, io.popen, os.getenv) the
same way the other STEMwerk.lua guard tests in this suite do.
"""

import importlib.util
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")


def _load_audio_separator_process_module():
    path = ROOT / "scripts/reaper/audio_separator_process.py"
    spec = importlib.util.spec_from_file_location("audio_separator_process_gfx1031_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module

CHUNK_START = "function resolveGfx1031RocmOverrideEnv()"
CHUNK_END = "-- Start a separation process for one job"

LUA_CANDIDATES = ("lua5.4", "lua", "luajit", "lua5.1")


def _chunk() -> str:
    start = SRC.index(CHUNK_START)
    end = SRC.index(CHUNK_END, start)
    return SRC[start:end]


def _lua_interpreter() -> str:
    for name in LUA_CANDIDATES:
        path = shutil.which(name)
        if path:
            return path
    pytest.skip("no Lua interpreter available")


HARNESS_TEMPLATE = r"""
OS = "__OS__"
multiTrackQueue = __CACHE__

local fakeUserEnv = [==[__USER_ENV__]==]
local fakeBackend = [==[__BACKEND__]==]
local fakeRocminfoOutput = [==[__ROCMINFO__]==]
local fakePopenFails = __POPEN_FAILS__
local popenCalls = 0

os.getenv = function(name)
    if name == "HSA_OVERRIDE_GFX_VERSION" and fakeUserEnv ~= "" then
        return fakeUserEnv
    end
    return nil
end

function readCapabilities()
    if fakeBackend == "" then return nil end
    return { kv = { BACKEND = fakeBackend } }
end

io.popen = function(cmd)
    popenCalls = popenCalls + 1
    if fakePopenFails then
        return nil
    end
    local handle = {}
    function handle.read(self, fmt)
        return fakeRocminfoOutput
    end
    function handle.close(self) end
    return handle
end

__CHUNK__

local value, source = resolveGfx1031RocmOverrideEnv()
print("VALUE=" .. tostring(value))
print("SOURCE=" .. tostring(source))
print("POPEN_CALLS=" .. tostring(popenCalls))

-- Second call in the same process must hit the multiTrackQueue cache and
-- must not invoke rocminfo again.
local value2, source2 = resolveGfx1031RocmOverrideEnv()
print("VALUE2=" .. tostring(value2))
print("SOURCE2=" .. tostring(source2))
print("POPEN_CALLS_AFTER_SECOND_CALL=" .. tostring(popenCalls))
"""


def _run_case(
    os_name: str,
    backend: str = "",
    rocminfo_output: str = "",
    user_env: str = "",
    cache_table: str = "{}",
    popen_fails: bool = False,
) -> dict:
    harness = (
        HARNESS_TEMPLATE.replace("__OS__", os_name)
        .replace("__CACHE__", cache_table)
        .replace("__USER_ENV__", user_env)
        .replace("__BACKEND__", backend)
        .replace("__ROCMINFO__", rocminfo_output)
        .replace("__POPEN_FAILS__", "true" if popen_fails else "false")
        .replace("__CHUNK__", _chunk())
    )
    proc = subprocess.run(
        [_lua_interpreter(), "-"],
        input=harness,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, f"lua harness failed:\n{proc.stdout}\n{proc.stderr}"
    result = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("=")
        result[key] = value
    return result


def test_gfx1031_rocm_linux_gets_compat_override():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="Agent 2\n  Name: gfx1031\n  Marketing Name: AMD Radeon RX 6600 XT\n",
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"


def test_other_amd_gpu_gfx1201_rx9070_is_not_touched():
    """RX 9070 / gfx1201 (the dev machine) must never receive this override."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="Agent 2\n  Name: gfx1201\n  Marketing Name: AMD Radeon RX 9070\n",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocm_backend_not_gfx1031"


def test_nvidia_cuda_backend_gets_no_override():
    result = _run_case(os_name="Linux", backend="cuda", rocminfo_output="")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"


def test_cpu_backend_gets_no_override():
    result = _run_case(os_name="Linux", backend="cpu", rocminfo_output="")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"


def test_missing_capabilities_gets_no_override():
    """No capabilities file yet (fresh install) must fail closed: no override."""
    result = _run_case(os_name="Linux", backend="", rocminfo_output="gfx1031")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"


def test_windows_gets_no_override_even_with_rocm_backend():
    result = _run_case(
        os_name="Windows",
        backend="rocm",
        rocminfo_output="Name: gfx1031\n",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_linux"
    assert result["POPEN_CALLS"] == "0"


def test_macos_gets_no_override_even_with_rocm_backend():
    result = _run_case(
        os_name="macOS",
        backend="rocm",
        rocminfo_output="Name: gfx1031\n",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_linux"
    assert result["POPEN_CALLS"] == "0"


def test_existing_user_override_is_never_replaced():
    """A user-set HSA_OVERRIDE_GFX_VERSION must survive untouched."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="Name: gfx1031\n",
        user_env="11.0.0",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "user_environment"
    # Detection must not even run rocminfo once a user value is present.
    assert result["POPEN_CALLS"] == "0"


def test_rocminfo_probe_failure_fails_closed():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="",
        popen_fails=True,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocminfo_probe_failed"


def test_result_is_cached_for_the_life_of_the_session():
    """A second call in the same run must reuse the cached result and must
    not spawn rocminfo again (avoids repeated subprocess spawns per job in a
    multi-track batch)."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="Name: gfx1031\n",
    )
    assert result["VALUE"] == "10.3.0"
    assert result["POPEN_CALLS"] == "1"
    assert result["VALUE2"] == "10.3.0"
    assert result["SOURCE2"] == "stemwerk_compatibility_rule"
    assert result["POPEN_CALLS_AFTER_SECOND_CALL"] == "1"


def test_cache_disabled_when_multitrack_queue_absent():
    """When multiTrackQueue is nil the function must still resolve safely
    (no crash) even though it can't cache the result."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_output="Name: gfx1031\n",
        cache_table="nil",
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"


def test_rocminfo_probe_excludes_stale_env_overrides():
    """The detection probe must clear HSA_OVERRIDE_GFX_VERSION and the other
    ROCm visibility variables before calling rocminfo, mirroring the existing
    ROCM_GFX1201 detection in STEMwerk_Bootstrap_Linux.sh, so a leftover
    override never masks the real underlying gfx target."""
    chunk = _chunk()
    assert "env -u HSA_OVERRIDE_GFX_VERSION" in chunk
    assert "-u HIP_VISIBLE_DEVICES" in chunk
    assert "-u ROCR_VISIBLE_DEVICES" in chunk
    assert "-u CUDA_VISIBLE_DEVICES" in chunk
    assert "rocminfo" in chunk


def test_override_value_is_only_ever_the_pinned_gfx1031_compat_value():
    """Guards against the override value ever being widened to a variable or
    a blanket assignment that could apply to any AMD GPU."""
    chunk = _chunk()
    assert chunk.count('"10.3.0"') == 1
    assert 'backend == "rocm"' in chunk
    assert 'find("gfx1031"' in chunk


def test_drumsep_helper_subprocess_on_rocm_backend_keeps_gfx1031_override(tmp_path):
    """The main worker process gets HSA_OVERRIDE_GFX_VERSION from the Lua
    launcher's environment; when it in turn spawns the isolated DrumSep
    helper subprocess on the rocm backend, that override must survive into
    the helper's environment too (its own torch/HIP init needs it just as
    much), before the helper's runtime initializes."""
    module = _load_audio_separator_process_module()

    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    real_executable = module.sys.executable
    module.sys.executable = str(fake_sys_executable)
    try:
        runtime_python = tmp_path / "helper" / ".venv-drumsep-rocm" / "bin" / "python"
        runtime_python.parent.mkdir(parents=True, exist_ok=True)
        runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
        runtime_venv = runtime_python.parent.parent

        base_env = {
            "PATH": f"{fake_sys_executable.parent}:/usr/local/bin:/usr/bin",
            "HSA_OVERRIDE_GFX_VERSION": "10.3.0",
            "STEMWERK_GFX1031_OVERRIDE_SOURCE": "stemwerk_compatibility_rule",
        }

        env, _diag = module.build_drumsep_subprocess_env(base_env, runtime_python, runtime_venv, "rocm")

        assert env["HSA_OVERRIDE_GFX_VERSION"] == "10.3.0"
        assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "stemwerk_compatibility_rule"
    finally:
        module.sys.executable = real_executable


def test_drumsep_helper_subprocess_on_cpu_backend_still_strips_override(tmp_path):
    """Existing safety behavior must remain unchanged: a CPU-routed DrumSep
    helper must never see HSA_OVERRIDE_GFX_VERSION, gfx1031-related or not."""
    module = _load_audio_separator_process_module()

    fake_sys_executable = tmp_path / "main" / ".venv" / "bin" / "python"
    fake_sys_executable.parent.mkdir(parents=True, exist_ok=True)
    fake_sys_executable.write_text("#!/bin/sh\n", encoding="utf-8")
    real_executable = module.sys.executable
    module.sys.executable = str(fake_sys_executable)
    try:
        runtime_python = tmp_path / "helper" / ".venv-drumsep-cpu" / "bin" / "python"
        runtime_python.parent.mkdir(parents=True, exist_ok=True)
        runtime_python.write_text("#!/bin/sh\n", encoding="utf-8")
        runtime_venv = runtime_python.parent.parent

        base_env = {
            "PATH": f"{fake_sys_executable.parent}:/usr/local/bin:/usr/bin",
            "HSA_OVERRIDE_GFX_VERSION": "10.3.0",
        }

        env, _diag = module.build_drumsep_subprocess_env(base_env, runtime_python, runtime_venv, "cpu")

        assert "HSA_OVERRIDE_GFX_VERSION" not in env
    finally:
        module.sys.executable = real_executable
