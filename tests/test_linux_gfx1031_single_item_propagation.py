"""gfx1031 override propagation through the single-item processing launcher.

Issue #123: a clean 2.3.1.3 candidate on a gfx1031 machine, REAPER started
from the desktop (no HSA_OVERRIDE_GFX_VERSION in its environment), ran
Normal Stems -> All / Fast / Auto on one item. The worker selected ROCm and
failed with "HIP error: invalid device function"; its separation_log had no
hsa_override/gfx1031 diagnostics at all and the exec log had no resolver
entry. The run was a single-item job (worker_context job_id "single"),
launched by WORKFLOW.startSeparationProcess in _internal/STEMwerk_Workflow.lua,
whose Unix run_bg.sh never consulted resolveGfx1031RocmOverrideEnv(); only the
multi-track launcher in STEMwerk.lua did.

These tests load the real Workflow.lua module and the real resolver from
STEMwerk.lua into a plain Lua interpreter, call the real
WORKFLOW.startSeparationProcess() with Normal Stems run options, let the
generated launcher run under /bin/sh, and assert on the environment the
spawned worker process actually received.
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
STEMWERK_SRC = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
SYSTEM_SRC = (ROOT / "scripts/reaper/_internal/STEMwerk_System.lua").read_text(encoding="utf-8")
WORKFLOW_PATH = ROOT / "scripts/reaper/_internal/STEMwerk_Workflow.lua"
WORKER_SRC = (ROOT / "scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")

LUA_CANDIDATES = ("lua5.4", "lua", "luajit", "lua5.1")

GFX1031_PROBE = (
    "STEMWERK_GFX_ARCH_PROBE hip=6.1.40091-a8dbc0c19 count=1\n"
    "STEMWERK_GFX_ARCH_DEVICE 0 gfx1031\n"
    "STEMWERK_GFX_ARCH_PROBE_END\n"
    "STEMWERK_GFX_ARCH_PROBE_RC=0\n"
)


def _rocminfo(*gpu_archs) -> str:
    blocks = ["ROCk module is loaded", "*******", "Agent 1", "*******",
              "  Name:                    AMD Ryzen 7 5800X", "  Device Type:             CPU"]
    for i, arch in enumerate(gpu_archs, start=2):
        blocks += ["*******", f"Agent {i}", "*******",
                   f"  Name:                    {arch}",
                   "  Marketing Name:          AMD Radeon RX",
                   "  Device Type:             GPU",
                   "  ISA Info:",
                   "    ISA 1",
                   f"      Name:                    amdgcn-amd-amdhsa--{arch}"]
    return "\n".join(blocks) + "\n"


def _lua() -> str:
    for name in LUA_CANDIDATES:
        path = shutil.which(name)
        if path:
            return path
    pytest.skip("no Lua interpreter available")


def _resolver_chunk() -> str:
    start = STEMWERK_SRC.index("function resolveGfx1031RocmOverrideEnv()")
    end = STEMWERK_SRC.index("-- Start a separation process for one job", start)
    return STEMWERK_SRC[start:end]


def _quote_arg() -> str:
    start = SYSTEM_SRC.index("function M.quoteArg(s)")
    end = SYSTEM_SRC.index("\nend\n", start) + len("\nend\n")
    return SYSTEM_SRC[start:end].replace("function M.quoteArg(s)", "function quoteArg(s)", 1)


HARNESS = r"""
OS = "Linux"
PATH_SEP = "/"
multiTrackQueue = {}
PYTHON_PATH = [==[__PY__]==]
SEPARATOR_SCRIPT = [==[__SEP__]==]
FFMPEG_PATH = nil
SETTINGS = { device = "auto", model = "htdemucs" }
RUNTIME_DEVICES = { { id = "auto", type = "auto" }, { id = "cpu", type = "cpu" }, { id = "cuda:0", type = "cuda" } }
local fakeUserEnv = [==[__USER_ENV__]==]
local fakeBackend = [==[__BACKEND__]==]
local fakeProbe = [==[__PROBE__]==]
local fakeRocminfo = [==[__ROCMINFO__]==]
local logLines = {}
SW_LOG = {
    logExecResult = function(cmd) logLines[#logLines + 1] = tostring(cmd) end,
    getLogPath = function() return [==[__OUT__/exec.log]==] end,
    writeExitCode = function(path, rc)
        local f = io.open(path, "w"); if f then f:write(tostring(rc)); f:close() end
    end,
}
function debugLog() end
function getExtStateValue() return nil end
function checkNumpyCompat() return true end
function canRunFfmpeg() return true end
function normalizeRequestedDeviceForRuntime(d) return d end
__QUOTE_ARG__
function readCapabilities()
    if fakeBackend == "" then return nil end
    return { kv = { BACKEND = fakeBackend } }
end
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
    if cmd:find("rocminfo", 1, true) then
        local isGlob = cmd:find("ls %-d ") ~= nil
        local h = {}
        function h.read() return isGlob and "" or fakeRocminfo end
        function h.lines() return function() return nil end end
        function h.close() end
        return h
    end
    return realPopen(cmd, mode)
end

__RESOLVER__

dofile([==[__WORKFLOW__]==])
WORKFLOW.configure({
    progressState = { runContext = { run_id = "run1", run_dir_name = "dir1", started_utc = "2026-10-02T16:09:44Z" } },
    refreshPythonPathFromExtState = function() end,
    T = function() return nil end,
    isAbsolutePath = function(p) return tostring(p):sub(1, 1) == "/" end,
    canRunPython = function() return true end,
    quoteArg = quoteArg,
    suppressStderr = function() return " 2>/dev/null" end,
    effectiveRunDevice = function() return "auto" end,
})

local ok = WORKFLOW.startSeparationProcess(
    [==[__OUT__/input.wav]==], [==[__OUT__]==], "htdemucs",
    { workflowMode = [==[__WFMODE__]==], workflowSource = [==[__WFSOURCE__]==] })
print("STARTED=" .. tostring(ok))
print("LUA_PROCESS_HSA=" .. tostring(realGetenv("HSA_OVERRIDE_GFX_VERSION")))
local sib = realPopen("printenv HSA_OVERRIDE_GFX_VERSION; printenv STEMWERK_GFX1031_OVERRIDE_SOURCE; echo END")
print("SIBLING=" .. (sib:read("*a"):gsub("\n", "|")))
sib:close()
print("LOG=" .. table.concat(logLines, " || "))
"""

FAKE_WORKER = r"""#!/bin/sh
if [ "$1" = "-c" ]; then exit 0; fi
env > "$(dirname "$0")/worker_env.txt"
printf '%s\n' "$@" > "$(dirname "$0")/worker_argv.txt"
echo "worker ok"
"""


def _run(
    tmp_path,
    *,
    probe: str = "",
    rocminfo: str = "",
    user_env: str = "",
    backend: str = "rocm",
    workflow_mode: str = "stems",
    workflow_source: str = "normal",
    block_launcher: bool = False,
) -> dict:
    bindir = tmp_path / "venv" / "bin"
    bindir.mkdir(parents=True)
    fake_py = bindir / "python"
    fake_py.write_text(FAKE_WORKER, encoding="utf-8")
    fake_py.chmod(0o755)
    out = tmp_path / "STEMwerk_1790957384_946250922_1"
    out.mkdir()
    (out / "input.wav").write_bytes(b"RIFF" + b"\0" * 4096)
    if block_launcher:
        (out / "run_bg.sh").mkdir()
    sep = tmp_path / "audio_separator_process.py"
    sep.write_text("# placeholder\n", encoding="utf-8")
    harness = (
        HARNESS.replace("__PY__", str(fake_py))
        .replace("__SEP__", str(sep))
        .replace("__OUT__", str(out))
        .replace("__USER_ENV__", user_env)
        .replace("__BACKEND__", backend)
        .replace("__PROBE__", probe)
        .replace("__ROCMINFO__", rocminfo)
        .replace("__WFMODE__", workflow_mode)
        .replace("__WFSOURCE__", workflow_source)
        .replace("__WORKFLOW__", str(WORKFLOW_PATH))
        .replace("__RESOLVER__", _resolver_chunk())
        .replace("__QUOTE_ARG__", _quote_arg())
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HSA_", "STEMWERK_"))}
    if user_env:
        env["HSA_OVERRIDE_GFX_VERSION"] = user_env
    before = dict(os.environ)
    proc = subprocess.run([_lua(), "-"], input=harness, capture_output=True, text=True, timeout=60, env=env)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert dict(os.environ) == before
    worker_env_file = bindir / "worker_env.txt"
    for _ in range(200):
        if worker_env_file.exists() and (out / "exit_code.txt").exists():
            break
        time.sleep(0.05)
    assert worker_env_file.exists(), "worker was never spawned:\n" + proc.stdout
    worker_env = {}
    for line in worker_env_file.read_text(encoding="utf-8").splitlines():
        key, sep_, value = line.partition("=")
        if sep_:
            worker_env[key] = value
    result = dict(line.partition("=")[::2] for line in proc.stdout.splitlines() if "=" in line)
    script = out / "run_bg.sh"
    result["env"] = worker_env
    result["argv"] = (bindir / "worker_argv.txt").read_text(encoding="utf-8").splitlines()
    result["script"] = script.read_text(encoding="utf-8") if script.is_file() else ""
    return result


def _worker_diag_lines(child_env: dict) -> list:
    """Run the worker's own startup diagnostic block against the env the
    spawned child actually received."""
    start = WORKER_SRC.index('    if sys.platform.startswith("linux"):\n        _hsa_override_gfx_version')
    end = WORKER_SRC.index("    ffmpeg_path, ffmpeg_wrapper, ffmpeg_path_prefix = _configure_ffmpeg_runtime()", start)
    block = "\n".join(line[4:] for line in WORKER_SRC[start:end].splitlines())
    code = "import os, sys\nsys.stderr = sys.stdout\n" + block
    env = {k: v for k, v in child_env.items() if k != "PYTHONPATH"}
    env["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")
    proc = subprocess.run(["python3", "-c", code], capture_output=True, text=True, env=env, timeout=30)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.splitlines()


# --- the exact real-user failure -------------------------------------------


def test_real_user_repro_runtime_probe_gfx1031_reaches_single_item_worker(tmp_path):
    """No user override, no rocminfo, managed runtime reports gfx1031 (the
    Fedora/pip-wheel #123 machine): the spawned Normal Stems worker itself
    must receive HSA_OVERRIDE_GFX_VERSION=10.3.0."""
    result = _run(tmp_path, probe=GFX1031_PROBE)
    env = result["env"]
    assert env.get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0"
    assert env.get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == "stemwerk_compatibility_rule_runtime_probe"
    assert env.get("STEMWERK_GFX1031_DETECTION_DETAIL") == "rocminfo=no_output runtime_probe=all_gfx1031 archs=gfx1031"
    assert "--workflow-mode" in result["argv"] and "stems" in result["argv"]
    assert "gfx1031_override: value=10.3.0 source=stemwerk_compatibility_rule_runtime_probe" in result["LOG"]
    assert "PYTHONPATH" not in env


def test_structured_rocminfo_gfx1031_reaches_single_item_worker(tmp_path):
    result = _run(tmp_path, rocminfo=_rocminfo("gfx1031"))
    env = result["env"]
    assert env.get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0"
    assert env.get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == "stemwerk_compatibility_rule"
    assert env.get("STEMWERK_GFX1031_DETECTION_DETAIL") == "rocminfo=all_gfx1031 archs=gfx1031"


def test_foreground_fallback_also_carries_override(tmp_path):
    result = _run(tmp_path, probe=GFX1031_PROBE, block_launcher=True)
    env = result["env"]
    assert result["script"] == ""
    assert env.get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0"
    assert env.get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == "stemwerk_compatibility_rule_runtime_probe"


def test_direct_kit_single_item_uses_same_launcher_and_gets_override(tmp_path):
    result = _run(tmp_path, probe=GFX1031_PROBE, workflow_mode="drumkit", workflow_source="direct")
    assert result["env"].get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0"


# --- user environment wins --------------------------------------------------


def test_explicit_user_override_is_preserved_exactly(tmp_path):
    result = _run(tmp_path, probe=GFX1031_PROBE, user_env="10.3.0-user")
    env = result["env"]
    assert env.get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0-user"
    assert "HSA_OVERRIDE_GFX_VERSION=" not in result["script"]


def test_explicit_user_override_reports_user_environment_source(tmp_path):
    result = _run(tmp_path, probe=GFX1031_PROBE, user_env="11.0.0")
    assert result["env"].get("HSA_OVERRIDE_GFX_VERSION") == "11.0.0"
    assert result["env"].get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == "user_environment"


# --- no override where it is not safe or not applicable ---------------------


@pytest.mark.parametrize(
    "rocminfo, source",
    [
        (_rocminfo("gfx1201", "gfx1103"), "rocm_backend_not_gfx1031"),
        (_rocminfo("gfx1030"), "rocm_backend_not_gfx1031"),
        (_rocminfo("gfx1031", "gfx1103"), "mixed_gpu_archs_not_overridden"),
    ],
    ids=["gfx1201+gfx1103", "gfx1030", "gfx1031+gfx1103"],
)
def test_non_gfx1031_and_mixed_gpus_get_no_override(tmp_path, rocminfo, source):
    result = _run(tmp_path, rocminfo=rocminfo, probe=GFX1031_PROBE)
    env = result["env"]
    assert "HSA_OVERRIDE_GFX_VERSION" not in env
    assert env.get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == source


def test_runtime_probe_mixed_archs_get_no_override(tmp_path):
    probe = (
        "STEMWERK_GFX_ARCH_PROBE hip=6.1 count=2\n"
        "STEMWERK_GFX_ARCH_DEVICE 0 gfx1031\n"
        "STEMWERK_GFX_ARCH_DEVICE 1 gfx1103\n"
        "STEMWERK_GFX_ARCH_PROBE_END\n"
        "STEMWERK_GFX_ARCH_PROBE_RC=0\n"
    )
    result = _run(tmp_path, probe=probe)
    assert "HSA_OVERRIDE_GFX_VERSION" not in result["env"]
    assert result["env"].get("STEMWERK_GFX1031_OVERRIDE_SOURCE") == "mixed_gpu_archs_not_overridden"


@pytest.mark.parametrize("backend", ["cuda", "cpu", ""])
def test_non_rocm_backends_launcher_unchanged(tmp_path, backend):
    result = _run(tmp_path, probe=GFX1031_PROBE, backend=backend)
    assert "HSA_OVERRIDE_GFX_VERSION" not in result["env"]
    assert "STEMWERK_GFX1031" not in result["script"]
    assert not any(k.startswith("STEMWERK_GFX1031") for k in result["env"])


# --- diagnostics as the worker reports them ---------------------------------


def test_worker_diagnostics_report_automatic_source(tmp_path):
    lines = _worker_diag_lines(_run(tmp_path, probe=GFX1031_PROBE)["env"])
    assert "STEMWERK_DIAG hsa_override_gfx_version=10.3.0" in lines
    assert "STEMWERK_DIAG hsa_override_gfx_version_source=stemwerk_compatibility_rule_runtime_probe" in lines


def test_worker_diagnostics_report_user_source(tmp_path):
    lines = _worker_diag_lines(_run(tmp_path, probe=GFX1031_PROBE, user_env="10.3.0")["env"])
    assert "STEMWERK_DIAG hsa_override_gfx_version=10.3.0" in lines
    assert "STEMWERK_DIAG hsa_override_gfx_version_source=user_environment" in lines


def test_worker_diagnostics_report_why_absent(tmp_path):
    lines = _worker_diag_lines(_run(tmp_path, rocminfo=_rocminfo("gfx1201", "gfx1103"))["env"])
    assert not any(l.startswith("STEMWERK_DIAG hsa_override_gfx_version=") for l in lines)
    assert "STEMWERK_DIAG gfx1031_override_not_applied_source=rocm_backend_not_gfx1031" in lines


# --- isolation --------------------------------------------------------------


def test_override_is_scoped_to_the_worker_child_only(tmp_path):
    result = _run(tmp_path, probe=GFX1031_PROBE)
    assert result["env"].get("HSA_OVERRIDE_GFX_VERSION") == "10.3.0"
    assert result["LUA_PROCESS_HSA"] == "nil"
    assert result["SIBLING"] == "END|"
