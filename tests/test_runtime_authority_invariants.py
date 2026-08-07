"""Regression contracts for issue #110: verified runtime state must stay
authoritative for interpreter selection across a transient probe failure.

Root cause: canRunPython() (STEMwerk.lua) runs two probes for macOS/Linux --
an os.execute-based basic runnability check, then a *separate*,
reaper.ExecProcess-based version-string probe used only to confirm the
Python 3.10-3.12 range. The second probe had no retry: a single
failed/timed-out ExecProcess call (e.g. the observed rc=-999 sentinel) could
declare an interpreter unrunnable even though the first probe, in the same
call, had already proven it launches. findPython()'s ordered candidate loop
then silently fell through to an unrelated Homebrew/system Python, which
correctly lacks the STEMwerk packages, producing a false "setup failed" in
the live UI/interactive verifier while processing (which has its own,
already-trusted capabilities.env fast path) kept working fine.

These tests pin:
- the version probe retry (STEMwerk.lua canRunPython)
- the capabilities.env-verified-state trust added to the live/interactive
  resolver (STEMwerk_Runtime_Setup.lua), matching the fast path
  verifyDependenciesReadyForProcessing() already had
- the behavioral Lua regression suite covering the full set of issue-#110
  scenarios (tests/lua/test_runtime_authority.lua)
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REAPER_DIR = ROOT / "scripts" / "reaper"
MAIN_LUA = REAPER_DIR / "STEMwerk.lua"
RUNTIME_SETUP_LUA = REAPER_DIR / "_internal" / "STEMwerk_Runtime_Setup.lua"
LUA_TEST = ROOT / "tests" / "lua" / "test_runtime_authority.lua"

LUA_CANDIDATES = [
    shutil.which("lua"),
    shutil.which("lua5.4"),
    shutil.which("luajit"),
    r"C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe",
]


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _lua_interpreter():
    for candidate in LUA_CANDIDATES:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def test_can_run_python_retries_version_probe_before_rejecting():
    src = _read(MAIN_LUA)
    assert "local function canRunPython(pythonCmd)" in src

    fn_start = src.index("local function canRunPython(pythonCmd)")
    fn_end = src.index("\nend", fn_start)
    fn_src = src[fn_start:fn_end]

    assert "for attempt = 1, 2 do" in fn_src, (
        "canRunPython must retry the version probe once before giving up"
    )
    assert "transient probe failure, not runtime-invalid" in fn_src

    retry_pos = fn_src.index("for attempt = 1, 2 do")
    exec_pos = fn_src.index("execProcess(versionCmd, 12000)")
    popen_pos = fn_src.index('io.popen(versionCmd .. " 2>&1")')
    break_pos = fn_src.index("break")
    reject_pos = fn_src.index('debugLog("canRunPython " .. tostring(OS) .. ": version probe failed')

    assert retry_pos < exec_pos < popen_pos < break_pos < reject_pos, (
        "retry loop must wrap the existing ExecProcess-then-popen probe and "
        "run before the final rejection, not after it"
    )


def test_can_run_python_retry_reuses_quoted_version_command():
    # The retry must not rebuild the command unsafely; it must keep using the
    # single quoteArg()-quoted versionCmd built once at the top of the probe
    # (this is what keeps paths containing spaces correctly quoted).
    src = _read(MAIN_LUA)
    fn_start = src.index("local function canRunPython(pythonCmd)")
    fn_end = src.index("\nend", fn_start)
    fn_src = src[fn_start:fn_end]

    assert (
        'local versionCmd = quoteArg(pythonCmd) .. " -c " .. quoteArg('
        in fn_src
    )
    assert fn_src.count("local versionCmd = quoteArg(pythonCmd)") == 1, (
        "versionCmd must be built once (quoted) and reused by both probe attempts"
    )
    exec_calls = fn_src.count("execProcess(versionCmd, 12000)")
    assert exec_calls == 1, "the retry loop must call execProcess once per iteration via the shared versionCmd"


def test_verify_runtime_after_bootstrap_trusts_coherent_capabilities():
    src = _read(RUNTIME_SETUP_LUA)
    assert "local function resolveVerifiedCapabilitiesPython()" in src
    assert 'caps.kv.VERIFICATION == "ok"' in src

    fn_start = src.index("function M.verifyRuntimeAfterBootstrap()")
    fn_end = src.index("\nend", fn_start)
    fn_src = src[fn_start:fn_end]
    assert "resolveVerifiedCapabilitiesPython()" in fn_src, (
        "the live/interactive verifier must consult the verified capabilities "
        "state before falling back to a fresh live probe"
    )
    assert "pythonVerifiedByCapabilities" in fn_src, (
        "a path resolved from verified capabilities.env must skip the redundant "
        "live re-probe (isPythonAvailable), or the same flaky probe defeats the fix"
    )


def test_resolve_runtime_python_path_also_trusts_verified_capabilities():
    # getFastStartupPythonPath() (STEMwerk.lua) calls resolveRuntimePythonPath()
    # directly at startup; it must get the same authoritative trust as
    # verifyRuntimeAfterBootstrap(), not just the interactive verifier.
    src = _read(RUNTIME_SETUP_LUA)
    fn_start = src.index("function M.resolveRuntimePythonPath()")
    fn_end = src.index("\nend", fn_start)
    fn_src = src[fn_start:fn_end]
    assert "resolveVerifiedCapabilitiesPython()" in fn_src


def test_managed_python_status_is_a_distinct_field_from_verification():
    # ACTIVE_VERIFIED_VENV (capabilities.env VERIFICATION/PYTHON_PATH) and
    # MANAGED_PYTHON_STATUS (a separate managed-standalone-Python bootstrap
    # concept) must never be conflated by the trust helper.
    src = _read(RUNTIME_SETUP_LUA)
    fn_start = src.index("local function resolveVerifiedCapabilitiesPython()")
    fn_end = src.index("\nend", fn_start)
    fn_src = src[fn_start:fn_end]
    assert "MANAGED_PYTHON" not in fn_src


def test_lua_regression_suite():
    lua = _lua_interpreter()
    if not lua:
        pytest.skip("no Lua interpreter available")
    proc = subprocess.run(
        [lua, str(LUA_TEST)],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        timeout=120,
    )
    output = proc.stdout + proc.stderr
    assert proc.returncode == 0, f"Lua regression suite failed:\n{output}"
    assert ", 0 failed" in output, f"expected all-passing summary, got:\n{output}"
