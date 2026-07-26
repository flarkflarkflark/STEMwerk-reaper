"""Regression test for the normal-workflow device-route guard (2.3.0.6).

The guard in scripts/reaper/_internal/STEMwerk_Workflow.lua
(preflightNormalWorkflowDeviceRoute) must allow "auto" on CPU-only runtimes
(auto resolves to the best available device), keep allowing "cpu", keep
blocking explicit GPU requests (cuda/directml/...) when no GPU is present,
and leave drumkit routes untouched.

The test executes the real guard chunk with a plain Lua interpreter using
stubs for the REAPER-facing globals, and additionally pins the guard shape
with static source assertions in the style of the other 2306 tests.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")

CHUNK_START = "local function isDirectDrumKitRoute"
CHUNK_END = "local function snapshotActiveTakePlaybackState"

LUA_CANDIDATES = ("lua5.4", "lua", "luajit", "lua5.1")


def _guard_chunk() -> str:
    start = SRC.index(CHUNK_START)
    end = SRC.index(CHUNK_END)
    return SRC[start:end]


def _lua_interpreter() -> str:
    for name in LUA_CANDIDATES:
        path = shutil.which(name)
        if path:
            return path
    pytest.skip("no Lua interpreter available")


HARNESS_TEMPLATE = r"""
C = {}
SETTINGS = {}
RUNTIME_DEVICES = {}
C.__messages = {}
function debugLog(_) end
C.showMessage = function(title, body, kind, modal)
    C.__messages[#C.__messages + 1] = tostring(title)
end
-- C.effectiveRunDevice and C.refreshRuntimeDevices intentionally absent:
-- the guard must fall back to SETTINGS.device and the static RUNTIME_DEVICES.

__CHUNK__

local function run_case(name, devices, requested, runOptions)
    RUNTIME_DEVICES = devices
    SETTINGS = { device = requested }
    C.__messages = {}
    local allowed = preflightNormalWorkflowDeviceRoute(runOptions)
    print("CASE " .. name .. " allowed=" .. tostring(allowed)
        .. " messages=" .. tostring(#C.__messages))
end

local cpu_only = { { id = "auto" }, { id = "cpu" } }
local with_gpu = { { id = "auto" }, { id = "cpu" }, { id = "cuda:0", type = "cuda" } }

run_case("auto_cpu_only", cpu_only, "auto", nil)
run_case("cpu_cpu_only", cpu_only, "cpu", nil)
run_case("cuda_cpu_only", cpu_only, "cuda:0", nil)
run_case("dml_cpu_only", cpu_only, "directml:0", nil)
run_case("auto_with_gpu", with_gpu, "auto", nil)
run_case("drumkit_cpu_only", cpu_only, "auto", { workflowMode = "drumkit" })
"""


def _run_guard_cases() -> dict:
    chunk = _guard_chunk()
    assert "]==]" not in chunk
    harness = HARNESS_TEMPLATE.replace("__CHUNK__", chunk)
    proc = subprocess.run(
        [_lua_interpreter(), "-"],
        input=harness,
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "LUA_PATH": ";;"},
    )
    assert proc.returncode == 0, f"lua harness failed:\n{proc.stdout}\n{proc.stderr}"
    results = {}
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "CASE":
            results[parts[1]] = {
                "allowed": parts[2] == "allowed=true",
                "messages": int(parts[3].split("=")[1]),
            }
    return results


def test_guard_allows_auto_on_cpu_only_runtime():
    case = _run_guard_cases()["auto_cpu_only"]
    assert case["allowed"] is True
    assert case["messages"] == 0


def test_guard_still_allows_explicit_cpu_request():
    case = _run_guard_cases()["cpu_cpu_only"]
    assert case["allowed"] is True
    assert case["messages"] == 0


def test_guard_blocks_explicit_gpu_requests_on_cpu_only_runtime():
    results = _run_guard_cases()
    for name in ("cuda_cpu_only", "dml_cpu_only"):
        assert results[name]["allowed"] is False, name
        assert results[name]["messages"] == 1, name


def test_guard_allows_auto_when_gpu_present():
    case = _run_guard_cases()["auto_with_gpu"]
    assert case["allowed"] is True
    assert case["messages"] == 0


def test_drumkit_route_bypasses_guard_unchanged():
    case = _run_guard_cases()["drumkit_cpu_only"]
    assert case["allowed"] is True
    assert case["messages"] == 0


def test_guard_shape_static():
    assert 'normalizedRequest ~= "cpu" and normalizedRequest ~= "auto" and not gpuAvailable' in SRC
    assert "if isDirectDrumKitRoute(runOptions) then" in SRC
    guard_call = SRC.index("if preflightNormalWorkflowDeviceRoute(runOptions) == false then")
    start_call = SRC.index(
        "WORKFLOW.startSeparationProcess(inputFile, outputDir, model, runOptions)",
        guard_call,
    )
    assert guard_call < start_call
