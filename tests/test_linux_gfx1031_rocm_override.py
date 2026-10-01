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

A first real-user validation of the override mechanism itself (manually
setting HSA_OVERRIDE_GFX_VERSION before launching REAPER) passed end-to-end
on issue #123 hardware. A *subsequent* real-user run relying on this file's
*automatic* detection -- without manually setting the variable -- did not
apply the override, even though the patched files were installed correctly.
The root cause: the original implementation located `rocminfo` via a bare
`io.popen("... rocminfo ...")` PATH lookup done inside REAPER's own running
process. A GUI-launched REAPER (desktop icon/taskbar) commonly does not
carry a ROCm-aware PATH (e.g. `/opt/rocm/bin`) the way an interactive shell
that has sourced a ROCm install script does, so the probe silently returned
no output -- indistinguishable in diagnostics from "genuinely not gfx1031"
-- and the override was never applied. The fix broadens detection to also
try well-known absolute rocminfo locations (ROCM_PATH, /opt/rocm/bin, and
versioned /opt/rocm-*/bin installs) when the bare PATH lookup comes up
empty, and gives the true "could not run rocminfo anywhere" case its own
diagnostic value distinct from "ran fine, hardware just isn't gfx1031".

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

SYSTEM_SRC = (ROOT / "scripts/reaper/_internal/STEMwerk_System.lua").read_text(encoding="utf-8")

CHUNK_START = "function resolveGfx1031RocmOverrideEnv()"
CHUNK_END = "-- Start a separation process for one job"

LUA_CANDIDATES = ("lua5.4", "lua", "luajit", "lua5.1")


def _chunk() -> str:
    start = SRC.index(CHUNK_START)
    end = SRC.index(CHUNK_END, start)
    return SRC[start:end]


def _production_quote_arg() -> str:
    """STEMwerk.lua binds quoteArg = SYSTEM.quoteArg; use that exact code."""
    start = SYSTEM_SRC.index("function M.quoteArg(s)")
    end = SYSTEM_SRC.index("\nend\n", start) + len("\nend\n")
    return SYSTEM_SRC[start:end].replace("function M.quoteArg(s)", "function quoteArg(s)", 1)


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
local fakeRocmPathEnv = [==[__ROCM_PATH_ENV__]==]
-- Ordered outputs for successive rocminfo-style probe attempts (bare PATH
-- first, then ROCM_PATH/bin, then /opt/rocm/bin, then any glob-discovered
-- versioned installs) -- probing stops at the first non-empty one, exactly
-- like the real candidate loop.
local fakeRocminfoOutputs = __ROCMINFO_OUTPUTS__
-- Extra candidate paths the /opt/rocm-*/bin/rocminfo glob "discovers".
local fakeGlobLines = __GLOB_LINES__
local fakePopenFails = __POPEN_FAILS__
-- Output of the managed-runtime torch architecture probe (nil = that
-- popen itself fails).
local fakeRuntimeProbeOutput = __RUNTIME_PROBE_OUTPUT__
PYTHON_PATH = [==[__PYTHON_PATH__]==]
local popenCalls = 0
local rocminfoCallIndex = 0
local runtimeProbeCalls = 0
local runtimeProbeCmd = ""
local logLines = {}
SW_LOG = { logExecResult = function(cmd) logLines[#logLines + 1] = tostring(cmd) end }

os.getenv = function(name)
    if name == "HSA_OVERRIDE_GFX_VERSION" and fakeUserEnv ~= "" then
        return fakeUserEnv
    end
    if name == "ROCM_PATH" and fakeRocmPathEnv ~= "" then
        return fakeRocmPathEnv
    end
    return nil
end

function readCapabilities()
    if fakeBackend == "" then return nil end
    return { kv = { BACKEND = fakeBackend } }
end

-- STEMwerk.lua binds quoteArg = SYSTEM.quoteArg outside the extracted
-- chunk; the harness injects that production implementation.
__QUOTE_ARG__

io.popen = function(cmd)
    popenCalls = popenCalls + 1
    if cmd:find("STEMWERK_GFX_ARCH_PROBE", 1, true) then
        runtimeProbeCalls = runtimeProbeCalls + 1
        runtimeProbeCmd = cmd
        if fakePopenFails or fakeRuntimeProbeOutput == nil then return nil end
        local handle = {}
        function handle.read(self, fmt) return fakeRuntimeProbeOutput end
        function handle.close(self) end
        return handle
    end
    if fakePopenFails then
        return nil
    end
    if cmd:find("ls %-d ") then
        local idx = 0
        local handle = {}
        function handle.lines(self)
            return function()
                idx = idx + 1
                return fakeGlobLines[idx]
            end
        end
        function handle.read(self, fmt) return "" end
        function handle.close(self) end
        return handle
    end
    rocminfoCallIndex = rocminfoCallIndex + 1
    local output = fakeRocminfoOutputs[rocminfoCallIndex] or ""
    local handle = {}
    function handle.read(self, fmt)
        return output
    end
    function handle.close(self) end
    return handle
end

__CHUNK__

local value, source, detail = resolveGfx1031RocmOverrideEnv()
print("VALUE=" .. tostring(value))
print("SOURCE=" .. tostring(source))
print("DETAIL=" .. tostring(detail))
print("POPEN_CALLS=" .. tostring(popenCalls))
print("ROCMINFO_CALLS=" .. tostring(rocminfoCallIndex))
print("RUNTIME_PROBE_CALLS=" .. tostring(runtimeProbeCalls))
print("RUNTIME_PROBE_CMD=" .. runtimeProbeCmd:gsub("\n", "\\n"))
print("LOG=" .. table.concat(logLines, " | "))

-- Second call in the same process must hit the multiTrackQueue cache and
-- must not invoke rocminfo again.
local value2, source2 = resolveGfx1031RocmOverrideEnv()
print("VALUE2=" .. tostring(value2))
print("SOURCE2=" .. tostring(source2))
print("POPEN_CALLS_AFTER_SECOND_CALL=" .. tostring(popenCalls))
"""


def _lua_list(values) -> str:
    return "{" + ", ".join("[==[" + v + "]==]" for v in values) + "}"


def _run_case(
    os_name: str,
    backend: str = "",
    rocminfo_outputs=(),
    glob_lines=(),
    user_env: str = "",
    rocm_path_env: str = "",
    cache_table: str = "{}",
    popen_fails: bool = False,
    runtime_probe_output=None,
    python_path: str = "",
) -> dict:
    harness = (
        HARNESS_TEMPLATE.replace("__OS__", os_name)
        .replace("__CACHE__", cache_table)
        .replace("__USER_ENV__", user_env)
        .replace("__ROCM_PATH_ENV__", rocm_path_env)
        .replace("__BACKEND__", backend)
        .replace("__ROCMINFO_OUTPUTS__", _lua_list(rocminfo_outputs))
        .replace("__GLOB_LINES__", _lua_list(glob_lines))
        .replace("__POPEN_FAILS__", "true" if popen_fails else "false")
        .replace(
            "__RUNTIME_PROBE_OUTPUT__",
            "nil" if runtime_probe_output is None else "[==[" + runtime_probe_output + "]==]",
        )
        .replace("__PYTHON_PATH__", python_path)
        .replace("__CHUNK__", _chunk())
        .replace("__QUOTE_ARG__", _production_quote_arg())
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


def _rocminfo(*gpu_archs, banner=True, cpu=True, npu=False) -> str:
    """rocminfo output in the real layout: an "Agent N" block per agent with
    its own Name/Marketing Name/Device Type, and ISA sub-entries whose Name
    lines (full ISA and generic target) must never count as the agent."""
    parts = []
    if banner:
        parts.append("ROCk module is loaded\n=====================\nHSA System Attributes\n")
    agent = 1
    if cpu:
        parts.append(
            f"*******\nAgent {agent}\n*******\n"
            "  Name:                    AMD Ryzen 7 7840HS w/ Radeon 780M Graphics\n"
            "  Marketing Name:          AMD Ryzen 7 7840HS w/ Radeon 780M Graphics\n"
            "  Vendor Name:             CPU\n"
            "  Device Type:             CPU\n"
        )
        agent += 1
    for arch in gpu_archs:
        family = arch[:-2] if len(arch) > 6 else arch
        parts.append(
            f"*******\nAgent {agent}\n*******\n"
            f"  Name:                    {arch}\n"
            "  Uuid:                    GPU-XX\n"
            "  Marketing Name:          AMD Radeon Graphics\n"
            "  Vendor Name:             AMD\n"
            "  Device Type:             GPU\n"
            "  ISA Info:\n"
            "    ISA 1\n"
            f"      Name:                    amdgcn-amd-amdhsa--{arch}\n"
            "    ISA 2\n"
            f"      Name:                    amdgcn-amd-amdhsa--{family}-generic\n"
        )
        agent += 1
    if npu:
        parts.append(
            f"*******\nAgent {agent}\n*******\n"
            "  Name:                    aie2\n"
            "  Marketing Name:          RyzenAI-npu1\n"
            "  Device Type:             DSP\n"
        )
    parts.append("*** Done ***\n")
    return "".join(parts)


def test_gfx1031_rocm_linux_gets_compat_override():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["Agent 2\n  Name: gfx1031\n  Marketing Name: AMD Radeon RX 6600 XT\n"],
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"


def test_other_amd_gpu_gfx1201_rx9070_is_not_touched():
    """RX 9070 / gfx1201 (the dev machine) must never receive this override."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["Agent 2\n  Name: gfx1201\n  Marketing Name: AMD Radeon RX 9070\n"],
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocm_backend_not_gfx1031"


def test_nvidia_cuda_backend_gets_no_override():
    result = _run_case(os_name="Linux", backend="cuda")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"
    assert result["POPEN_CALLS"] == "0"


def test_cpu_backend_gets_no_override():
    result = _run_case(os_name="Linux", backend="cpu")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"
    assert result["POPEN_CALLS"] == "0"


def test_missing_capabilities_gets_no_override():
    """No capabilities file yet (fresh install) must fail closed: no override."""
    result = _run_case(os_name="Linux", backend="", rocminfo_outputs=["gfx1031"])
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_applicable"
    assert result["POPEN_CALLS"] == "0"


def test_windows_gets_no_override_even_with_rocm_backend():
    result = _run_case(
        os_name="Windows",
        backend="rocm",
        rocminfo_outputs=["Name: gfx1031\n"],
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_linux"
    assert result["POPEN_CALLS"] == "0"


def test_macos_gets_no_override_even_with_rocm_backend():
    result = _run_case(
        os_name="macOS",
        backend="rocm",
        rocminfo_outputs=["Name: gfx1031\n"],
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_linux"
    assert result["POPEN_CALLS"] == "0"


def test_existing_user_override_is_never_replaced():
    """A user-set HSA_OVERRIDE_GFX_VERSION must survive untouched."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["Name: gfx1031\n"],
        user_env="11.0.0",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "user_environment"
    # Detection must not even run rocminfo once a user value is present.
    assert result["POPEN_CALLS"] == "0"


def test_rocminfo_unreachable_anywhere_fails_closed_with_distinct_marker():
    """When nothing can be spawned at all (io.popen itself fails for every
    rocminfo candidate and for the runtime probe), the result must still
    fail closed (no override), and must be distinguishable in diagnostics
    from "checked and it's genuinely not gfx1031"."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        popen_fails=True,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=spawn_failed"


def test_result_is_cached_for_the_life_of_the_session():
    """A second call in the same run must reuse the cached result and must
    not spawn rocminfo (or the glob probe) again (avoids repeated subprocess
    spawns per job in a multi-track batch)."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[_rocminfo("gfx1031")],
    )
    assert result["VALUE"] == "10.3.0"
    # 1 glob-listing popen call + 1 successful bare-PATH rocminfo call.
    assert result["POPEN_CALLS"] == "2"
    assert result["ROCMINFO_CALLS"] == "1"
    assert result["VALUE2"] == "10.3.0"
    assert result["SOURCE2"] == "stemwerk_compatibility_rule"
    assert result["POPEN_CALLS_AFTER_SECOND_CALL"] == "2"


def test_cache_disabled_when_multitrack_queue_absent():
    """When multiTrackQueue is nil the function must still resolve safely
    (no crash) even though it can't cache the result."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[_rocminfo("gfx1031")],
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
    # Decisions come from parsed architectures, never a substring search.
    assert 'find("gfx1031"' not in chunk
    assert 'arch == "gfx1031"' in chunk


# --- Regression coverage for the PATH-miss auto-detection fix -------------
#
# These prove the actual bug fix: a GUI-launched REAPER whose process PATH
# lacks the ROCm install directory must still detect gfx1031 hardware (and
# must still correctly exclude non-gfx1031 hardware) by falling back to
# well-known absolute rocminfo locations.


def test_bare_path_miss_falls_back_to_opt_rocm_bin_and_still_detects_gfx1031():
    """Core fix scenario: bare `rocminfo` produces nothing (not on PATH, the
    real-world GUI-launch bug), but the absolute /opt/rocm/bin/rocminfo
    candidate finds the real gfx1031 agent. The override must still apply."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["", "Agent 2\n  Name: gfx1031\n  Marketing Name: AMD Radeon RX 6600 XT\n"],
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"
    assert result["ROCMINFO_CALLS"] == "2"


def test_bare_and_opt_rocm_bin_miss_but_rocm_path_env_candidate_hits():
    """When ROCM_PATH is set (custom/non-default ROCm install location) and
    neither bare PATH nor /opt/rocm/bin has rocminfo, the ROCM_PATH/bin
    candidate (tried before /opt/rocm/bin) must still be found."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocm_path_env="/custom/rocm-install",
        rocminfo_outputs=["", "Agent 2\n  Name: gfx1031\n  Marketing Name: AMD Radeon RX 6600 XT\n"],
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"
    assert result["ROCMINFO_CALLS"] == "2"


def test_versioned_rocm_install_discovered_via_glob_still_detects_gfx1031():
    """A versioned install with no /opt/rocm symlink (e.g.
    /opt/rocm-6.1.0/bin/rocminfo) must still be found via the glob fallback
    once bare PATH and /opt/rocm/bin both come up empty."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        glob_lines=["/opt/rocm-6.1.0/bin/rocminfo"],
        rocminfo_outputs=["", "", "Agent 2\n  Name: gfx1031\n  Marketing Name: AMD Radeon RX 6600 XT\n"],
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"
    assert result["ROCMINFO_CALLS"] == "3"


def test_fallback_candidates_still_correctly_exclude_non_gfx1031_hardware():
    """Negative isolation must hold even when the broadened PATH-fallback
    search is what actually locates rocminfo: an RX 9070/gfx1201 machine
    found only via /opt/rocm/bin must still not receive the override."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["", "Agent 2\n  Name: gfx1201\n  Marketing Name: AMD Radeon RX 9070\n"],
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocm_backend_not_gfx1031"


def test_rocminfo_empty_everywhere_is_not_a_real_negative():
    """io.popen returns a handle even when the rocminfo executable does not
    exist (the shell starts and its "not found" goes to /dev/null), so empty
    output at every candidate means rocminfo was not found -- the issue #123
    Fedora case. That must NOT be classified as "not gfx1031"; it must hand
    over to the runtime probe, and with no runtime available fail closed."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["", "", ""],
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=no_python_path"


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


# --- Managed-runtime architecture probe fallback (issue #123, Fedora) ------
#
# Issue #123's real machine (Fedora 44, ROCm from distro packages + the pip
# ROCm torch wheel) has no rocminfo anywhere the resolver looks, while the
# managed PyTorch runtime itself reports gcn_arch='gfx1031'. When rocminfo
# yields nothing, the resolver asks that same runtime (PYTHON_PATH) for the
# per-device gfx architecture in a short-lived child process.

GFX1031_PROBE = (
    "STEMWERK_GFX_ARCH_PROBE hip=6.1.40091-a8dbc0c19 count=1\n"
    "STEMWERK_GFX_ARCH_DEVICE 0 gfx1031\n"
    "STEMWERK_GFX_ARCH_PROBE_END\n"
    "STEMWERK_GFX_ARCH_PROBE_RC=0\n"
)


def _probe_output(*archs, rc=0, end=True, hip="6.1.40091-a8dbc0c19", count=None):
    lines = [f"STEMWERK_GFX_ARCH_PROBE hip={hip} count={len(archs) if count is None else count}"]
    lines += [f"STEMWERK_GFX_ARCH_DEVICE {i} {a}" for i, a in enumerate(archs)]
    if end:
        lines.append("STEMWERK_GFX_ARCH_PROBE_END")
    lines.append(f"STEMWERK_GFX_ARCH_PROBE_RC={rc}")
    return "\n".join(lines) + "\n"


def test_a_rocminfo_gfx1031_wins_without_running_runtime_probe():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[_rocminfo("gfx1031")],
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"
    assert result["DETAIL"] == "rocminfo=all_gfx1031 archs=gfx1031"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_b_rocminfo_silent_runtime_probe_gfx1031_applies_override():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["", "", ""],
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule_runtime_probe"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=all_gfx1031 archs=gfx1031"
    assert result["RUNTIME_PROBE_CALLS"] == "1"


def test_b2_rocminfo_negative_is_trusted_and_skips_runtime_probe():
    """rocminfo that really ran and reported another GPU stays a real
    negative; the runtime probe must not second-guess it."""
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[_rocminfo("gfx1201")],
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocm_backend_not_gfx1031"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_runtime_probe_uses_managed_python_and_clean_env_without_model_load():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    cmd = result["RUNTIME_PROBE_CMD"]
    assert __file__ + " -c " in cmd
    assert "env -u HSA_OVERRIDE_GFX_VERSION -u PYTHONPATH -u PYTHONHOME" in cmd
    assert "timeout -k 5 30" in cmd
    assert "gcnArchName" in cmd
    for forbidden in ("audio_separator", "Separator", "load_model", "download"):
        assert forbidden not in cmd


@pytest.mark.parametrize(
    "archs",
    [("gfx1100",), ("gfx1101",), ("gfx1201",), ("gfx1200",), ("gfx1030",), ("gfx1032",), ("gfx1201", "gfx1103")],
)
def test_d_runtime_probe_non_gfx1031_devices_get_no_override(archs):
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=_probe_output(*archs),
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_not_gfx1031"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=non_gfx1031 archs=" + ",".join(archs)


@pytest.mark.parametrize("archs", [("gfx1031", "gfx1036"), ("gfx1031", "gfx1103"), ("gfx1103", "gfx1031", "gfx1031")])
def test_10_runtime_probe_mixed_archs_get_no_override(archs):
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=_probe_output(*archs),
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "mixed_gpu_archs_not_overridden"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=mixed_archs archs=" + ",".join(archs)


def test_d2_runtime_probe_with_no_rocm_devices_gets_no_override():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=_probe_output(hip="none"),
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_not_gfx1031"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=no_devices archs=none"


def test_gfx1031_with_feature_suffix_is_still_gfx1031():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=_probe_output("gfx1031:xnack-"),
        python_path=__file__,
    )
    assert result["VALUE"] == "10.3.0"


@pytest.mark.parametrize(
    "output,reason",
    [
        (_probe_output(rc=3).replace("STEMWERK_GFX_ARCH_PROBE_END\n", "STEMWERK_GFX_ARCH_PROBE_ERROR RuntimeError\n"),
         "exit_rc=3,error=RuntimeError"),
        ("STEMWERK_GFX_ARCH_PROBE_RC=124\n", "timeout_rc=124"),
        ("STEMWERK_GFX_ARCH_PROBE_RC=127\n", "exit_rc=127"),
        ("", "exit_rc=none"),
    ],
)
def test_e_runtime_probe_failure_gets_no_override(output, reason):
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=output,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=" + reason
    assert "source=runtime_probe_unavailable" in result["LOG"]


def test_e2_missing_managed_python_fails_closed_without_spawning():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=GFX1031_PROBE,
        python_path="/nonexistent/stemwerk/.venv/bin/python",
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=python_missing"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


@pytest.mark.parametrize(
    "output,reason",
    [
        (_probe_output("gfx1031", end=False), "malformed_output"),
        ("garbage gfx1031\nSTEMWERK_GFX_ARCH_PROBE_RC=0\n", "malformed_output"),
        (_probe_output("gfx1031", count=2), "malformed_device_count"),
        (_probe_output("unknown"), "malformed_arch"),
        (_probe_output("Navi22 gfx1031"), "malformed_arch"),
    ],
)
def test_f_malformed_runtime_probe_output_gets_no_override(output, reason):
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=output,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=" + reason


def test_g_user_value_wins_and_no_probe_runs():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        user_env="10.3.0-custom",
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "user_environment"
    assert result["POPEN_CALLS"] == "0"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


@pytest.mark.parametrize("os_name", ["Windows", "macOS"])
def test_j_non_linux_never_runs_runtime_probe(os_name):
    result = _run_case(
        os_name=os_name,
        backend="rocm",
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "not_linux"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_runtime_probe_result_is_cached_for_the_session():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE2"] == "10.3.0"
    assert result["SOURCE2"] == "stemwerk_compatibility_rule_runtime_probe"
    assert result["RUNTIME_PROBE_CALLS"] == "1"
    assert result["POPEN_CALLS_AFTER_SECOND_CALL"] == result["POPEN_CALLS"]


# --- Real shell, fake runtime executable -----------------------------------
#
# These run the resolver with the real io.popen/sh/env/timeout, a PATH with
# no rocminfo, and /opt/rocm-style candidates redirected to a non-existent
# prefix, so detection can only come from the fake managed-runtime python.

REAL_SHELL_HARNESS = r"""
OS = "Linux"
multiTrackQueue = {}
PYTHON_PATH = [==[__PYTHON_PATH__]==]
function readCapabilities() return { kv = { BACKEND = "rocm" } } end
__QUOTE_ARG__
local realPopen = io.popen
io.popen = function(cmd, mode)
    return realPopen((cmd:gsub("/opt/rocm", [==[__NO_OPT_ROCM__]==])), mode)
end
local realGetenv = os.getenv
os.getenv = function(name)
    if name == "ROCM_PATH" or name == "HSA_OVERRIDE_GFX_VERSION" then return nil end
    return realGetenv(name)
end
__CHUNK__
local value, source, detail = resolveGfx1031RocmOverrideEnv()
print("VALUE=" .. tostring(value))
print("SOURCE=" .. tostring(source))
print("DETAIL=" .. tostring(detail))
"""

FAKE_RUNTIME_PYTHON = r"""#!/bin/sh
# Fake managed-runtime python: records how it was invoked, then answers the
# architecture probe like torch would on the configured hardware.
{
  echo "argv1=$1"
  echo "hsa=${HSA_OVERRIDE_GFX_VERSION:-<unset>}"
  echo "pythonpath=${PYTHONPATH:-<unset>}"
} >> "$(dirname "$0")/probe_invocations.txt"
case "$2" in *gcnArchName*) ;; *) echo "unexpected probe code" >&2; exit 9 ;; esac
__BODY__
"""


def _run_real_shell_case(tmp_path, body: str, env_extra=None) -> dict:
    bindir = tmp_path / "venv" / "bin"
    bindir.mkdir(parents=True)
    fake_py = bindir / "python"
    fake_py.write_text(FAKE_RUNTIME_PYTHON.replace("__BODY__", body), encoding="utf-8")
    fake_py.chmod(0o755)
    empty_path = tmp_path / "empty-path"
    empty_path.mkdir()
    harness = (
        REAL_SHELL_HARNESS.replace("__PYTHON_PATH__", str(fake_py))
        .replace("__NO_OPT_ROCM__", str(tmp_path / "no-opt-rocm"))
        .replace("__CHUNK__", _chunk())
        .replace("__QUOTE_ARG__", _production_quote_arg())
    )
    sys_path = ":".join(p for p in ("/usr/bin", "/bin") if Path(p).is_dir())
    tools = tmp_path / "tools"
    tools.mkdir()
    for tool in ("env", "timeout", "ls", "dirname", "cat", "sh"):
        found = shutil.which(tool, path=sys_path)
        if found:
            (tools / tool).symlink_to(found)
    env = {
        "PATH": f"{empty_path}:{tools}",
        "HSA_OVERRIDE_GFX_VERSION": "",
        "PYTHONPATH": "/should/be/removed",
        "HOME": str(tmp_path),
    }
    env.update(env_extra or {})
    assert shutil.which("rocminfo", path=env["PATH"]) is None
    proc = subprocess.run(
        [_lua_interpreter(), "-"], input=harness, capture_output=True, text=True, timeout=120, env=env
    )
    assert proc.returncode == 0, proc.stderr
    result = dict(line.partition("=")[::2] for line in proc.stdout.splitlines())
    inv = bindir / "probe_invocations.txt"
    result["INVOCATIONS"] = inv.read_text(encoding="utf-8") if inv.exists() else ""
    return result


def test_c_no_rocminfo_anywhere_fake_runtime_reports_gfx1031(tmp_path):
    body = (
        'echo "STEMWERK_GFX_ARCH_PROBE hip=6.1.40091-a8dbc0c19 count=1"\n'
        'echo "STEMWERK_GFX_ARCH_DEVICE 0 gfx1031"\n'
        'echo "STEMWERK_GFX_ARCH_PROBE_END"\n'
    )
    result = _run_real_shell_case(tmp_path, body)
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule_runtime_probe"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=all_gfx1031 archs=gfx1031"
    assert "argv1=-c" in result["INVOCATIONS"]
    assert "hsa=<unset>" in result["INVOCATIONS"]
    assert "pythonpath=<unset>" in result["INVOCATIONS"]


def test_c2_real_shell_fake_runtime_non_gfx1031(tmp_path):
    body = (
        'echo "STEMWERK_GFX_ARCH_PROBE hip=7.0.51831 count=2"\n'
        'echo "STEMWERK_GFX_ARCH_DEVICE 0 gfx1201"\n'
        'echo "STEMWERK_GFX_ARCH_DEVICE 1 gfx1103"\n'
        'echo "STEMWERK_GFX_ARCH_PROBE_END"\n'
    )
    result = _run_real_shell_case(tmp_path, body)
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_not_gfx1031"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=non_gfx1031 archs=gfx1201,gfx1103"


def test_c3_real_shell_fake_runtime_crashes(tmp_path):
    body = 'echo "Segmentation fault" >&2\nexit 139\n'
    result = _run_real_shell_case(tmp_path, body)
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "runtime_probe_unavailable"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=exit_rc=139"


# --- H/I: the real Normal Stems Unix launcher ------------------------------

LAUNCHER_START = "        -- Unix: background sh launcher that writes pid.txt and done.txt."
LAUNCHER_END = "        else\n            -- Fallback: run in foreground\n"


def _launcher_chunk() -> str:
    start = SRC.index(LAUNCHER_START)
    end = SRC.index(LAUNCHER_END, start)
    return SRC[start:end] + "        end\n"


LAUNCHER_HARNESS = r"""
OS = "Linux"
PATH_SEP = "/"
multiTrackQueue = {}
PYTHON_PATH = [==[__PYTHON_PATH__]==]
SEPARATOR_SCRIPT = [==[__SEPARATOR__]==]
FFMPEG_PATH = nil
local fakeUserEnv = [==[__USER_ENV__]==]
local fakeProbe = [==[__PROBE__]==]
local fakeRocminfo = [==[__ROCMINFO__]==]
function getExtStateValue() return nil end
function suppressStderr() return " 2>/dev/null" end
function debugLog() end
__QUOTE_ARG__
function readCapabilities() return { kv = { BACKEND = [==[__BACKEND__]==] } } end
local realGetenv = os.getenv
os.getenv = function(name)
    if name == "HSA_OVERRIDE_GFX_VERSION" then return fakeUserEnv ~= "" and fakeUserEnv or nil end
    if name == "ROCM_PATH" then return nil end
    return realGetenv(name)
end
local realPopen = io.popen
io.popen = function(cmd, mode)
    if cmd:find("STEMWERK_GFX_ARCH_PROBE", 1, true) then
        local h = {}
        function h.read() return fakeProbe end
        function h.close() end
        return h
    end
    if cmd:find("rocminfo", 1, true) or cmd:find("ls %-d ") then
        local h = {}
        local isRocminfo = not cmd:find("ls %-d ")
        function h.read() return isRocminfo and fakeRocminfo or "" end
        function h.lines() return function() return nil end end
        function h.close() end
        return h
    end
    return realPopen(cmd, mode)
end
__RESOLVER__
local job = { index = 1, inputFile = [==[__TRACKDIR__/in.wav]==], trackDir = [==[__TRACKDIR__]==] }
local execLogPath, jobTag = [==[__TRACKDIR__/exec.log]==], "job1"
local runIdArg, jobIdArg, runDirNameArg, runStartedUtcArg = "run1", "job1", "dir1", "2026-10-01T00:00:00Z"
local modelArg, deviceArg = "htdemucs.yaml", "auto"
local workflowModeArg, workflowSourceArg, requestedStage2ModelArg = "stems", "normal", ""
local stdoutFile = [==[__TRACKDIR__/stdout.txt]==]
local logFile = [==[__TRACKDIR__/separation_log.txt]==]
local doneFile = [==[__TRACKDIR__/done.txt]==]
local pidFile = [==[__TRACKDIR__/pid.txt]==]
local exitCodeFile = [==[__TRACKDIR__/exit_code.txt]==]
do
__LAUNCHER__
end
"""

FAKE_WORKER_PYTHON = r"""#!/bin/sh
if [ "$1" = "-c" ]; then exit 0; fi
env > "$(dirname "$0")/worker_env.txt"
echo "worker ok"
"""


def _run_launcher(
    tmp_path, probe_output: str, user_env: str = "", backend: str = "rocm", rocminfo_output: str = ""
) -> dict:
    bindir = tmp_path / "venv" / "bin"
    bindir.mkdir(parents=True)
    fake_py = bindir / "python"
    fake_py.write_text(FAKE_WORKER_PYTHON, encoding="utf-8")
    fake_py.chmod(0o755)
    track = tmp_path / "track"
    track.mkdir()
    resolver = _chunk()
    harness = (
        LAUNCHER_HARNESS.replace("__PYTHON_PATH__", str(fake_py))
        .replace("__SEPARATOR__", str(tmp_path / "audio_separator_process.py"))
        .replace("__USER_ENV__", user_env)
        .replace("__PROBE__", probe_output)
        .replace("__ROCMINFO__", rocminfo_output)
        .replace("__BACKEND__", backend)
        .replace("__RESOLVER__", resolver)
        .replace("__TRACKDIR__", str(track))
        .replace("__LAUNCHER__", _launcher_chunk())
        .replace("__QUOTE_ARG__", _production_quote_arg())
    )
    env = {k: v for k, v in __import__("os").environ.items() if not k.startswith(("HSA_", "STEMWERK_"))}
    if user_env:
        env["HSA_OVERRIDE_GFX_VERSION"] = user_env
    proc = subprocess.run([_lua_interpreter(), "-"], input=harness, capture_output=True, text=True, timeout=60, env=env)
    assert proc.returncode == 0, proc.stderr
    done = track / "done.txt"
    import time

    for _ in range(100):
        if done.exists():
            break
        time.sleep(0.05)
    assert done.read_text(encoding="utf-8").strip() == "DONE"
    worker_env = {}
    for line in (bindir / "worker_env.txt").read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        worker_env[key] = value
    return {"env": worker_env, "script": (track / "run_bg.sh").read_text(encoding="utf-8")}


def test_h_normal_stems_child_receives_runtime_probe_override(tmp_path):
    result = _run_launcher(tmp_path, GFX1031_PROBE)
    env = result["env"]
    assert env["HSA_OVERRIDE_GFX_VERSION"] == "10.3.0"
    assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "stemwerk_compatibility_rule_runtime_probe"
    assert env["STEMWERK_GFX1031_DETECTION_DETAIL"] == "rocminfo=no_output runtime_probe=all_gfx1031 archs=gfx1031"
    assert "PYTHONPATH" not in env


def test_i_normal_stems_child_reports_why_no_override_was_applied(tmp_path):
    result = _run_launcher(tmp_path, "STEMWERK_GFX_ARCH_PROBE_RC=124\n")
    env = result["env"]
    assert "HSA_OVERRIDE_GFX_VERSION" not in env
    assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "runtime_probe_unavailable"
    assert env["STEMWERK_GFX1031_DETECTION_DETAIL"] == "rocminfo=no_output runtime_probe=timeout_rc=124"


def test_g2_user_value_reaches_child_unchanged(tmp_path):
    result = _run_launcher(tmp_path, GFX1031_PROBE, user_env="10.3.0-user")
    env = result["env"]
    assert "HSA_OVERRIDE_GFX_VERSION=" not in result["script"]
    assert env["HSA_OVERRIDE_GFX_VERSION"] == "10.3.0-user"
    assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "user_environment"


def test_non_rocm_linux_launcher_is_unchanged(tmp_path):
    result = _run_launcher(tmp_path, GFX1031_PROBE, backend="cuda")
    assert "HSA_OVERRIDE_GFX_VERSION" not in result["env"]
    assert "STEMWERK_GFX1031" not in result["script"]


def test_i2_worker_logs_detection_route_into_separation_log():
    src = (ROOT / "scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")
    assert "STEMWERK_DIAG gfx1031_override_not_applied_source=" in src
    assert "STEMWERK_DIAG gfx1031_detection_detail=" in src


def test_runtime_probe_code_survives_production_double_quote_quoting():
    """quoteArg wraps in double quotes and only escapes '"', so the inline
    probe code must not contain characters sh would still expand there."""
    chunk = _chunk()
    start = chunk.index("local code = table.concat({")
    end = chunk.index('}, "\\n")', start)
    code_lines = [line.strip() for line in chunk[start:end].splitlines()[1:] if line.strip()]
    assert len(code_lines) >= 10
    for line in code_lines:
        body = line[1:-2]
        assert line.startswith('"') and line.endswith('",'), line
        for ch in ('"', "$", "`", "\\"):
            assert ch not in body, (ch, line)


# --- rocminfo architecture parsing (global-override safety) ----------------
#
# HSA_OVERRIDE_GFX_VERSION retargets every ROCm device in the worker, so the
# rocminfo route must follow the same rule as the runtime probe: override
# only when every positively identified GPU agent is gfx1031. Output with no
# readable GPU agent is inconclusive and hands over to the runtime probe.


def _rocminfo_case(rocminfo_output, probe=None, **kw):
    return _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[rocminfo_output],
        runtime_probe_output=probe,
        python_path=__file__,
        **kw,
    )


def test_1_rocminfo_single_gfx1031_overrides():
    result = _rocminfo_case(_rocminfo("gfx1031"), probe=_probe_output("gfx1201"))
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule"
    assert result["DETAIL"] == "rocminfo=all_gfx1031 archs=gfx1031"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_2_rocminfo_repeated_gfx1031_overrides():
    result = _rocminfo_case(_rocminfo("gfx1031", "gfx1031"))
    assert result["VALUE"] == "10.3.0"
    assert result["DETAIL"] == "rocminfo=all_gfx1031 archs=gfx1031,gfx1031"


@pytest.mark.parametrize("archs", [("gfx1031", "gfx1103"), ("gfx1031", "gfx1036"), ("gfx1036", "gfx1031")])
def test_3_4_rocminfo_mixed_archs_get_no_override_and_no_fallback(archs):
    result = _rocminfo_case(_rocminfo(*archs), probe=GFX1031_PROBE)
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "mixed_gpu_archs_not_overridden"
    assert result["DETAIL"] == "rocminfo=mixed_archs archs=" + ",".join(archs)
    # Positive evidence of a mixed system must not be overruled by a
    # runtime that might expose only a subset of the GPUs.
    assert result["RUNTIME_PROBE_CALLS"] == "0"


@pytest.mark.parametrize("archs", [("gfx1103",), ("gfx1201", "gfx1103"), ("gfx1030",)])
def test_5_rocminfo_non_gfx1031_is_a_real_negative_without_fallback(archs):
    result = _rocminfo_case(_rocminfo(*archs, npu=True), probe=GFX1031_PROBE)
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "rocm_backend_not_gfx1031"
    assert result["DETAIL"] == "rocminfo=non_gfx1031 archs=" + ",".join(archs)
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_5b_isa_and_generic_lines_never_count_as_agents():
    """Each GPU agent also lists ISA names (amdgcn-amd-amdhsa--gfxNNNN,
    gfxNN-generic); only the agent's own Name decides, so one gfx1201 card
    is one architecture, not three."""
    result = _rocminfo_case(_rocminfo("gfx1201"))
    assert result["DETAIL"] == "rocminfo=non_gfx1031 archs=gfx1201"


@pytest.mark.parametrize(
    "output",
    [
        _rocminfo(cpu=True),  # CPU agent only, no GPU agent
        _rocminfo(cpu=True, npu=True),  # CPU + NPU, no GPU agent
        "ROCk module is loaded\nHSA System Attributes\n  Runtime Version: 1.1\n",
    ],
)
def test_6_rocminfo_without_gpu_architecture_runs_fallback(output):
    result = _rocminfo_case(output, probe=GFX1031_PROBE)
    assert result["VALUE"] == "10.3.0"
    assert result["SOURCE"] == "stemwerk_compatibility_rule_runtime_probe"
    assert result["DETAIL"] == "rocminfo=no_arch_evidence runtime_probe=all_gfx1031 archs=gfx1031"
    assert result["RUNTIME_PROBE_CALLS"] == "1"


@pytest.mark.parametrize(
    "output",
    [
        "hsa api call failure at: rocminfo.cc:1306\nCall returned HSA_STATUS_ERROR_OUT_OF_RESOURCES\n",
        "ROCk module is NOT loaded, possibly no GPU devices\n",
        "warning: gfx1031 is not officially supported by this ROCm release\n",
        "Name: gfx1031\n",  # no agent block: not rocminfo agent evidence
        "  amdgcn-amd-amdhsa--gfx1031\n",
    ],
)
def test_7_rocminfo_error_or_banner_text_is_inconclusive_and_never_overrides_by_itself(output):
    no_runtime = _rocminfo_case(output, probe=None)
    assert no_runtime["VALUE"] == "nil"
    assert no_runtime["SOURCE"] == "runtime_probe_unavailable"
    assert no_runtime["DETAIL"] == "rocminfo=no_arch_evidence runtime_probe=spawn_failed"
    other_gpu = _rocminfo_case(output, probe=_probe_output("gfx1201"))
    assert other_gpu["VALUE"] == "nil"
    assert other_gpu["SOURCE"] == "runtime_probe_not_gfx1031"
    assert other_gpu["RUNTIME_PROBE_CALLS"] == "1"


def test_7b_gpu_agent_with_unreadable_name_is_inconclusive():
    output = _rocminfo("gfx1031")
    output += "*******\nAgent 9\n*******\n  Name:                    \n  Device Type:             GPU\n"
    result = _rocminfo_case(output, probe=_probe_output("gfx1031", "gfx1103"))
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "mixed_gpu_archs_not_overridden"
    assert result["DETAIL"] == "rocminfo=no_arch_evidence runtime_probe=mixed_archs archs=gfx1031,gfx1103"


def test_7c_failing_candidate_does_not_hide_a_later_good_rocminfo():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=["hsa api call failure\n", _rocminfo("gfx1031")],
        runtime_probe_output=_probe_output("gfx1201"),
        python_path=__file__,
    )
    assert result["VALUE"] == "10.3.0"
    assert result["DETAIL"] == "rocminfo=all_gfx1031 archs=gfx1031"
    assert result["ROCMINFO_CALLS"] == "2"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_8_rocminfo_absent_runs_fallback():
    result = _run_case(
        os_name="Linux",
        backend="rocm",
        rocminfo_outputs=[],
        runtime_probe_output=GFX1031_PROBE,
        python_path=__file__,
    )
    assert result["VALUE"] == "10.3.0"
    assert result["DETAIL"] == "rocminfo=no_output runtime_probe=all_gfx1031 archs=gfx1031"


def test_11_user_value_beats_mixed_rocminfo_and_no_probe_runs():
    result = _rocminfo_case(_rocminfo("gfx1031", "gfx1103"), probe=GFX1031_PROBE, user_env="10.3.0")
    assert result["VALUE"] == "nil"
    assert result["SOURCE"] == "user_environment"
    assert result["POPEN_CALLS"] == "0"
    assert result["RUNTIME_PROBE_CALLS"] == "0"


def test_12_launcher_mixed_rocminfo_exports_no_override(tmp_path):
    result = _run_launcher(tmp_path, GFX1031_PROBE, rocminfo_output=_rocminfo("gfx1031", "gfx1103"))
    env = result["env"]
    assert "HSA_OVERRIDE_GFX_VERSION" not in env
    assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "mixed_gpu_archs_not_overridden"
    assert env["STEMWERK_GFX1031_DETECTION_DETAIL"] == "rocminfo=mixed_archs archs=gfx1031,gfx1103"


def test_12b_launcher_rocminfo_gfx1031_exports_override(tmp_path):
    result = _run_launcher(tmp_path, _probe_output("gfx1201"), rocminfo_output=_rocminfo("gfx1031"))
    env = result["env"]
    assert env["HSA_OVERRIDE_GFX_VERSION"] == "10.3.0"
    assert env["STEMWERK_GFX1031_OVERRIDE_SOURCE"] == "stemwerk_compatibility_rule"
    assert env["STEMWERK_GFX1031_DETECTION_DETAIL"] == "rocminfo=all_gfx1031 archs=gfx1031"
