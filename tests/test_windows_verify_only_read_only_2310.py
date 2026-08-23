"""Regression tests for the 2.3.1.0 Windows Check-only non-mutation contract
and the Windows-safe capabilities.env replacement fix in
STEMwerk_Setup_Internal.lua.

Background: os.rename() maps to the C runtime rename(), which on Windows
(unlike POSIX) fails whenever the destination already exists. writeCapabilities
used a plain os.rename(tmpPath, path), so it only ever succeeded on the very
first write -- every write after that (e.g. once PowerShell or an earlier
Setup run had already created capabilities.env) logged "WARN: failed to write
capabilities file" and silently discarded the fresh probe results. Separately,
Windows Check-only (windowsVerifyTick) called the same
writeCapabilities/updateBootstrapEnv persistence path that mutating
Setup/Repair flows use, violating the intended non-mutating Check-only
contract.

This file follows the same style as
tests/test_macos_verify_only_read_only_2306.py: source-slicing based
forbidden-token checks for the non-mutation contract, plus a behavioral Lua
subprocess harness (using the real system `lua` interpreter, with os.rename
shadowed to reproduce Windows' fail-on-existing-destination semantics, since
POSIX rename() on this Linux test runner does not exhibit that bug natively)
for the replacement helper itself.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")


def _slice(source: str, start: str, end: str) -> str:
    return source[source.index(start) : source.index(end, source.index(start))]


def _windows_verify_tick_body(source: str) -> str:
    return _slice(
        source,
        "local function windowsVerifyTick()",
        "\nlocal function windowsVerifyStart(runtime, separatorScript, reuseWindow)",
    )


def _replace_helper_source(source: str) -> str:
    return _slice(
        source,
        "local function replaceFileWindowsSafe(tmpPath, destPath)",
        "\nfunction readReadyState(runtime)",
    )


# --- E/F/H/I/J: source-level non-mutation / mutation-preserved contract ----


def test_check_only_source_has_no_persistent_writes():
    """E/F: windowsVerifyTick (the "Check only" menu action -- id == "verify",
    labeled "Check only" in the UI) must never call any of the
    state-persisting primitives, on any step of its multi-tick flow."""
    body = _windows_verify_tick_body(SETUP.read_text(encoding="utf-8"))
    forbidden = ("updateBootstrapEnv(", "writeCapabilities(", 'setExt("ffmpegPath"', 'setExt("pythonPath"')
    found = [token for token in forbidden if token in body]
    assert not found, f"Check only source still contains persistent writes: {found}"


def test_check_only_still_computes_and_displays_live_probe_truth():
    """G: Check only must still compute and surface the current live probe
    result even though it no longer persists it -- the in-memory `state`
    table mutations (used only for this tick's own display/finalMessage) are
    intentionally preserved; only the disk/ExtState publication is removed."""
    body = _windows_verify_tick_body(SETUP.read_text(encoding="utf-8"))
    assert 'state.STATUS = "ok"' in body
    assert 'state.STATUS = "missing_ffmpeg"' in body
    assert "safePerformPostBootstrap(runtime, stateFile, logFile, true, state, WINDOWS_VERIFY.separatorScript, false)" in body
    assert "finalizeWindowsVerify(true, result.finalMessage)" in body
    assert "canRunFfmpegPair(WINDOWS_VERIFY.ffmpegPath)" in body
    assert "canImportStemwerkCore(WINDOWS_VERIFY.pythonPath)" in body
    assert "canImportAudioSeparator(WINDOWS_VERIFY.pythonPath)" in body


def test_perform_post_bootstrap_publish_flag_gates_persistence():
    """The publish parameter (default true, so every existing mutating
    caller is unaffected) must actually gate both persistence calls."""
    source = SETUP.read_text(encoding="utf-8")
    perform_body = _slice(
        source,
        "local function performPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript, publish)",
        "\nsafePerformPostBootstrap = function(",
    )
    assert "if publish == nil then publish = true end" in perform_body
    assert "if publish then" in perform_body
    assert "local wroteCaps, capsErr = writeCapabilities(capPath, {" in perform_body
    assert "local synced = updateBootstrapEnv(stateFile, syncKv)" in perform_body
    assert perform_body.index("if publish then") < perform_body.index("local wroteCaps, capsErr = writeCapabilities(capPath, {")
    assert perform_body.index("local synced = updateBootstrapEnv(stateFile, syncKv)") < perform_body.rindex("end -- publish")

    safe_body = _slice(source, "safePerformPostBootstrap = function(", "\nappendLogLine = function(")
    assert "safePerformPostBootstrap = function(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript, publish)" in safe_body
    assert "pcall(performPostBootstrap, runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript, publish)" in safe_body


def test_mutating_setup_and_repair_callers_still_publish_by_default():
    """H: every OTHER safePerformPostBootstrap call site (Setup/Repair/macOS/
    Linux finalize flows) must be unaffected by this fix -- none of them pass
    publish=false, so they keep the pre-existing default (true) behavior."""
    source = SETUP.read_text(encoding="utf-8")
    call_lines = [
        line.strip() for line in source.splitlines() if "safePerformPostBootstrap(" in line and "function" not in line
    ]
    assert len(call_lines) >= 8, "expected many safePerformPostBootstrap call sites"
    false_calls = [line for line in call_lines if line.rstrip().endswith(", false)")]
    assert len(false_calls) == 1, f"exactly one call site should opt out of publishing, found: {false_calls}"
    assert "WINDOWS_VERIFY.separatorScript, false)" in false_calls[0]


def test_windows_check_only_read_only_matches_macos_verify_only_contract():
    """Cross-platform consistency: macOS's equivalent verify-only path
    (verifyExistingSetup) already enforces the same zero-mutation contract
    (see test_macos_verify_only_read_only_2306.py) -- confirm neither this
    fix nor unrelated future edits have removed that macOS guarantee."""
    source = SETUP.read_text(encoding="utf-8")
    macos_verify_body = _slice(
        source,
        "verifyExistingSetup = function(runtime, separatorScript)",
        "\n-- (showExistingRuntimeSetupMenu removed",
    )
    forbidden = ("writeCapabilities(", "updateBootstrapEnv(", "setExt(")
    assert not [token for token in forbidden if token in macos_verify_body]


# --- A-D: Windows-safe replacement helper (behavioral, real Lua interpreter) -


pytestmark_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")


def _run_replace_harness(tmp_path: Path, script_body: str) -> dict[str, str]:
    source = SETUP.read_text(encoding="utf-8")
    functions = _replace_helper_source(source)
    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
local fileExists = function(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end
{functions}
{script_body}
""",
        encoding="utf-8",
    )
    result = subprocess.run([LUA, str(harness)], cwd=tmp_path, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


@pytestmark_lua
def test_replace_succeeds_when_destination_does_not_exist_yet(tmp_path: Path):
    state = _run_replace_harness(
        tmp_path,
        """
local tmp = io.open("new.tmp", "w"); tmp:write("fresh contents"); tmp:close()
local ok, err = replaceFileWindowsSafe("new.tmp", "dest.env")
print("OK=" .. tostring(ok))
local f = io.open("dest.env", "r"); print("CONTENTS=" .. f:read("*a")); f:close()
""",
    )
    assert state["OK"] == "true"
    assert state["CONTENTS"] == "fresh contents"


@pytestmark_lua
def test_replace_windows_style_succeeds_over_existing_destination(tmp_path: Path):
    """A: existing capabilities.env + replacement on Windows => succeeds.
    os.rename is shadowed here to reproduce the real Windows C-runtime
    behavior (fails when the destination already exists) that POSIX
    rename() on this Linux test runner does not naturally exhibit."""
    state = _run_replace_harness(
        tmp_path,
        """
local real_rename = os.rename
os.rename = function(src, dst)
    local d = io.open(dst, "rb")
    if d then d:close(); return nil, "EEXIST (simulated Windows rename semantics)" end
    return real_rename(src, dst)
end
local existing = io.open("dest.env", "w"); existing:write("stale contents"); existing:close()
local tmp = io.open("new.tmp", "w"); tmp:write("fresh contents"); tmp:close()
local ok, err = replaceFileWindowsSafe("new.tmp", "dest.env")
print("OK=" .. tostring(ok))
local f = io.open("dest.env", "r"); print("CONTENTS=" .. f:read("*a")); f:close()
print("TMP_GONE=" .. tostring(io.open("new.tmp", "rb") == nil))
print("BACKUP_GONE=" .. tostring(io.open("dest.env.bak", "rb") == nil))
""",
    )
    assert state["OK"] == "true"
    assert state["CONTENTS"] == "fresh contents"
    assert state["TMP_GONE"] == "true"
    assert state["BACKUP_GONE"] == "true"


@pytestmark_lua
def test_replace_failure_preserves_original_file_and_cleans_up_temp(tmp_path: Path):
    """B/D: if the final move into place fails (even after a successful
    backup-aside step), the original destination content must be restored
    and the temp file must not be left behind."""
    state = _run_replace_harness(
        tmp_path,
        """
local real_rename = os.rename
local rename_calls = 0
os.rename = function(src, dst)
    rename_calls = rename_calls + 1
    if rename_calls == 2 then
        return nil, "simulated disk full"  -- only the final move fails
    end
    return real_rename(src, dst)  -- backup-aside and restore both succeed
end
local existing = io.open("dest.env", "w"); existing:write("stale but known-good"); existing:close()
local tmp = io.open("new.tmp", "w"); tmp:write("new contents"); tmp:close()
local ok, err = replaceFileWindowsSafe("new.tmp", "dest.env")
print("OK=" .. tostring(ok))
print("ERR=" .. tostring(err))
local f = io.open("dest.env", "r"); print("CONTENTS=" .. f:read("*a")); f:close()
print("TMP_GONE=" .. tostring(io.open("new.tmp", "rb") == nil))
""",
    )
    assert state["OK"] == "false"
    assert "replace_failed" in state["ERR"]
    assert state["CONTENTS"] == "stale but known-good"
    assert state["TMP_GONE"] == "true"


@pytestmark_lua
def test_replace_backup_failure_preserves_original_and_cleans_temp(tmp_path: Path):
    """C: if even the initial backup-aside step fails, the original
    destination must be untouched and the temp file cleaned up -- the
    replacement must never be attempted against an unbacked-up destination."""
    state = _run_replace_harness(
        tmp_path,
        """
os.rename = function(src, dst)
    return nil, "simulated backup failure"
end
local existing = io.open("dest.env", "w"); existing:write("stale but known-good"); existing:close()
local tmp = io.open("new.tmp", "w"); tmp:write("new contents"); tmp:close()
local ok, err = replaceFileWindowsSafe("new.tmp", "dest.env")
print("OK=" .. tostring(ok))
print("ERR=" .. tostring(err))
local f = io.open("dest.env", "r"); print("CONTENTS=" .. f:read("*a")); f:close()
print("TMP_GONE=" .. tostring(io.open("new.tmp", "rb") == nil))
""",
    )
    assert state["OK"] == "false"
    assert "backup_failed" in state["ERR"]
    assert state["CONTENTS"] == "stale but known-good"
    assert state["TMP_GONE"] == "true"


@pytestmark_lua
def test_write_capabilities_checks_flush_and_close_before_replacing(tmp_path: Path):
    """writeCapabilities must not attempt to replace the destination with a
    file whose write/flush/close did not actually succeed."""
    source = SETUP.read_text(encoding="utf-8")
    replace_fn = _replace_helper_source(source)
    write_caps_fn = _slice(source, "local function writeCapabilities(path, data, deviceOut)", "\nfunction readReadyState(runtime)")
    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
local fileExists = function(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end
{replace_fn}
{write_caps_fn}
local ok, err = writeCapabilities("dest.env", {{ profile = "windows-cpu", backend = "cpu" }}, nil)
print("OK=" .. tostring(ok))
local f = io.open("dest.env", "r")
print("EXISTS=" .. tostring(f ~= nil))
if f then print("HAS_PROFILE=" .. tostring((f:read("*a")):find("PROFILE=windows%-cpu") ~= nil)); f:close() end
""",
        encoding="utf-8",
    )
    result = subprocess.run([LUA, str(harness)], cwd=tmp_path, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    state = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    assert state["OK"] == "true"
    assert state["EXISTS"] == "true"
    assert state["HAS_PROFILE"] == "true"
