"""Regression tests for the 2.3.1.0 stale-ExtState runtime-presence bug.

Live evidence: a macOS clean-install retest removed every actual STEMwerk
install/runtime file (REAPER Scripts, Application Support/STEMwerk,
/Users/Shared/STEMwerk-reaper, the pkg receipt) but REAPER's persistent
ExtState still held stale cached pythonPath/ffmpegPath values from the
prior install. runtimeLooksPresent() in STEMwerk_Setup_Internal.lua
treated `getExt("pythonPath") ~= ""` / `getExt("ffmpegPath") ~= ""` as
sufficient evidence of an existing runtime, all on their own -- without
ever confirming those cached paths still exist on disk. This routed a
genuinely-uninstalled machine into startExistingRuntimeSetupMenu()
instead of the first-time/welcome flow, and the stale pythonPath (now
pointing at a deleted file) later surfaced as "Python path is missing".

Root cause: cached ExtState strings were used as standalone,
unconditional runtime-presence authority instead of supporting evidence
that must itself be checked against the filesystem. cached ffmpegPath is
additionally unsound even when validated: STEMwerk's ffmpegPath cache is
frequently populated from a SYSTEM-WIDE FFmpeg search
(resolveUnixFfmpegFallback()), not a STEMwerk-specific artifact -- a
machine with e.g. Homebrew ffmpeg installed but STEMwerk never set up
would have a perfectly valid, existing ffmpegPath that says nothing
about whether STEMwerk's own runtime exists. So this fix removes
ffmpegPath from runtime-presence authority entirely (existence-checked
or not), while pythonPath remains supporting evidence but only when the
cached file actually still exists.

These tests run the real runtimeLooksPresent() function (and its real
getModelCacheDir/getHome/normalizePlatformPath/fileExists/pathExists
dependencies), extracted verbatim from the actual source and executed
under a real lua5.4 -- never a re-implementation.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _lua_function(source: str, name: str) -> str:
    start = source.index(f"local function {name}(")
    return _slice_from(source, start)


def _lua_global_function(source: str, name: str) -> str:
    start = source.index(f"{name} = function(")
    return _slice_from(source, start)


def _slice_from(source: str, start: int) -> str:
    depth = 0
    pos = start
    opened = False
    while True:
        m = re.search(r"\b(function|if|for|while|end)\b", source[pos:])
        if not m:
            raise AssertionError(source[start:start + 40])
        word = m.group(1)
        pos = pos + m.end()
        if word in ("function", "if", "for", "while"):
            depth += 1
            opened = True
        elif word == "end":
            depth -= 1
            if opened and depth == 0:
                return source[start:pos]


_DEPS = (
    "normalizePlatformPath",
    "ensureWritableDir",
    "getHome",
    "getModelCacheDir",
    "runtimeLooksPresent",
)
_GLOBAL_DEPS = (
    "fileExists",
    "pathExists",
)


def _build_harness(
    tmp_path: Path,
    *,
    os_name: str,
    home_dir: Path,
    venv_python_exists: bool,
    ext_python_path: str,
    ext_ffmpeg_path: str,
) -> Path:
    text = _read(SETUP)
    deps = "\n".join(_lua_global_function(text, name) for name in _GLOBAL_DEPS)
    deps += "\n" + "\n".join(_lua_function(text, name) for name in _DEPS)

    runtime_base = home_dir / (".local/share/STEMwerk" if os_name != "macOS" else "Library/Application Support/STEMwerk")
    venv_dir = runtime_base / ".venv"
    venv_python = venv_dir / "bin" / "python"
    if venv_python_exists:
        venv_python.parent.mkdir(parents=True)
        venv_python.write_text("#!/bin/sh\n", encoding="utf-8")

    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
OS = "{os_name}"
PATH_SEP = "/"
EXT_SECTION = "STEMwerk"
reaper = {{}}
local extState = {{
    pythonPath = {ext_python_path!r},
    ffmpegPath = {ext_ffmpeg_path!r},
}}
local setExtCalls = 0
getExt = function(key) return extState[key] or "" end
setExt = function(key, value) setExtCalls = setExtCalls + 1; extState[key] = tostring(value) end

{deps}

local runtime = {{
    base = "{runtime_base}",
    runtimeState = "{runtime_base}/state",
    runtimeLogs = "{runtime_base}/logs",
    venvDir = "{venv_dir}",
    venvPython = "{venv_python}",
}}

local result = runtimeLooksPresent(runtime)
print("RESULT=" .. tostring(result))
print("SET_EXT_CALLS=" .. tostring(setExtCalls))
""",
        encoding="utf-8",
    )
    return harness


def _run(harness: Path, home_dir: Path) -> dict:
    env = {"HOME": str(home_dir), "PATH": "/usr/bin:/bin"}
    result = subprocess.run([LUA, str(harness)], text=True, capture_output=True, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    out = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


@pytestmark_lua
@pytest.mark.parametrize("os_name", ["Linux", "macOS"])
def test_completely_fresh_reports_absent(tmp_path: Path, os_name: str):
    """A: no physical runtime, no cached ExtState -> false."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name=os_name, home_dir=home, venv_python_exists=False,
        ext_python_path="", ext_ffmpeg_path="",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "false", out


@pytestmark_lua
@pytest.mark.parametrize("os_name", ["Linux", "macOS"])
def test_stale_python_extstate_alone_reports_absent(tmp_path: Path, os_name: str):
    """B: THE key live regression -- stale pythonPath pointing at a
    deleted file, with no physical runtime, must not count as present."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name=os_name, home_dir=home, venv_python_exists=False,
        ext_python_path="/deleted/STEMwerk/.venv/bin/python", ext_ffmpeg_path="",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "false", (
        f"stale pythonPath ExtState masqueraded as an existing runtime: {out}"
    )


@pytestmark_lua
@pytest.mark.parametrize("os_name", ["Linux", "macOS"])
def test_stale_ffmpeg_extstate_alone_reports_absent(tmp_path: Path, os_name: str):
    """C: stale ffmpegPath alone must not count as present."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name=os_name, home_dir=home, venv_python_exists=False,
        ext_python_path="", ext_ffmpeg_path="/deleted/STEMwerk/ffmpeg",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "false", out


@pytestmark_lua
def test_both_stale_extstate_reports_absent(tmp_path: Path):
    """D: both cached strings non-empty, neither exists, no runtime -> false."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name="macOS", home_dir=home, venv_python_exists=False,
        ext_python_path="/deleted/STEMwerk/.venv/bin/python",
        ext_ffmpeg_path="/deleted/STEMwerk/ffmpeg",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "false", out


@pytestmark_lua
def test_valid_existing_venv_reports_present(tmp_path: Path):
    """E: a genuinely existing runtime (.venv/bin/python present) must
    still be detected, even with empty ExtState."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name="macOS", home_dir=home, venv_python_exists=True,
        ext_python_path="", ext_ffmpeg_path="",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "true", out


@pytestmark_lua
def test_valid_cached_python_path_reports_present(tmp_path: Path):
    """F: no standard runtime evidence, but the cached pythonPath points
    at a file that genuinely still exists -- supported as evidence per
    current product semantics (unlike ffmpegPath, pythonPath is a
    STEMwerk-specific artifact, not a generic system utility)."""
    home = tmp_path / "home"
    home.mkdir()
    real_python = tmp_path / "some" / "other" / "python"
    real_python.parent.mkdir(parents=True)
    real_python.write_text("#!/bin/sh\n", encoding="utf-8")
    harness = _build_harness(
        tmp_path, os_name="macOS", home_dir=home, venv_python_exists=False,
        ext_python_path=str(real_python), ext_ffmpeg_path="",
    )
    out = _run(harness, home)
    assert out["RESULT"] == "true", out


@pytestmark_lua
def test_valid_cached_ffmpeg_path_alone_does_not_report_present(tmp_path: Path):
    """G: an existing, valid FFmpeg path alone must NOT be treated as
    proof of a STEMwerk runtime -- a system-wide FFmpeg (e.g. Homebrew)
    can exist on a machine that has never had STEMwerk's own runtime
    installed. ffmpegPath is removed from standalone runtime-presence
    authority entirely (not merely existence-checked)."""
    home = tmp_path / "home"
    home.mkdir()
    real_ffmpeg = tmp_path / "opt" / "homebrew" / "bin" / "ffmpeg"
    real_ffmpeg.parent.mkdir(parents=True)
    real_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    harness = _build_harness(
        tmp_path, os_name="macOS", home_dir=home, venv_python_exists=False,
        ext_python_path="", ext_ffmpeg_path=str(real_ffmpeg),
    )
    out = _run(harness, home)
    assert out["RESULT"] == "false", (
        f"a valid but STEMwerk-unrelated system FFmpeg path was treated as runtime evidence: {out}"
    )


@pytestmark_lua
def test_detection_never_mutates_extstate(tmp_path: Path):
    """H: runtimeLooksPresent must be read-only -- it must never call
    setExt(), regardless of outcome."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_harness(
        tmp_path, os_name="macOS", home_dir=home, venv_python_exists=False,
        ext_python_path="/deleted/STEMwerk/.venv/bin/python",
        ext_ffmpeg_path="/deleted/STEMwerk/ffmpeg",
    )
    out = _run(harness, home)
    assert out["SET_EXT_CALLS"] == "0", out


# --- Higher-level decision-path regression: proves the actual auto-invoke
# branch selection (startExistingRuntimeSetupMenu vs the first-time-setup
# prompt), not just runtimeLooksPresent() in isolation. -----------------

_DECISION_DEPS = _DEPS


def _decision_block(source: str) -> str:
    anchor = source.index('    if OS == "Windows" then\n        startExistingRuntimeSetupMenu(runtime, separatorScript)\n        return\n    end\n')
    start = source.index('    if OS == "Linux" or OS == "macOS" then\n', anchor)
    end = source.index('\n        if OS == "macOS" and showSkippedMacBootstrapFinalWindow', start)
    block = source[start:end]
    assert block.count("startExistingRuntimeSetupMenu(runtime, separatorScript)") == 1
    assert block.count('if msgBox("STEMwerk Setup",') == 1
    # Deliberately truncated before showSkippedMacBootstrapFinalWindow --
    # close the outer `if OS == "Linux" or OS == "macOS" then` ourselves.
    return block + "\n    end\n"


def _build_decision_harness(
    tmp_path: Path,
    *,
    os_name: str,
    home_dir: Path,
    venv_python_exists: bool,
    ext_python_path: str,
    ext_ffmpeg_path: str,
) -> Path:
    text = _read(SETUP)
    deps = "\n".join(_lua_global_function(text, name) for name in _GLOBAL_DEPS)
    deps += "\n" + "\n".join(_lua_function(text, name) for name in _DECISION_DEPS)
    decision = _decision_block(text)

    runtime_base = home_dir / (".local/share/STEMwerk" if os_name != "macOS" else "Library/Application Support/STEMwerk")
    venv_dir = runtime_base / ".venv"
    venv_python = venv_dir / "bin" / "python"
    if venv_python_exists:
        venv_python.parent.mkdir(parents=True)
        venv_python.write_text("#!/bin/sh\n", encoding="utf-8")

    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
OS = "{os_name}"
PATH_SEP = "/"
EXT_SECTION = "STEMwerk"
reaper = {{}}
local extState = {{
    pythonPath = {ext_python_path!r},
    ffmpegPath = {ext_ffmpeg_path!r},
}}
getExt = function(key) return extState[key] or "" end
setExt = function(key, value) extState[key] = tostring(value) end

local calledExisting = false
local calledFirstTimePrompt = false
function startExistingRuntimeSetupMenu(runtime, separatorScript)
    calledExisting = true
end
function msgBox(title, text, flags)
    calledFirstTimePrompt = true
    return 0  -- simulate the user cancelling, so nothing further runs
end

{deps}

local separatorScript = "/does/not/matter/audio_separator_process.py"
local runtime = {{
    base = "{runtime_base}",
    runtimeState = "{runtime_base}/state",
    runtimeLogs = "{runtime_base}/logs",
    venvDir = "{venv_dir}",
    venvPython = "{venv_python}",
}}
-- wrapped: the extracted block contains bare `return` statements that
-- must return from a function, not terminate this whole harness script.
(function()
{decision}
end)()

print("CALLED_EXISTING=" .. tostring(calledExisting))
print("CALLED_FIRST_TIME_PROMPT=" .. tostring(calledFirstTimePrompt))
""",
        encoding="utf-8",
    )
    return harness


@pytestmark_lua
@pytest.mark.parametrize("os_name", ["Linux", "macOS"])
def test_stale_extstate_with_no_runtime_reaches_first_time_flow(tmp_path: Path, os_name: str):
    """Section 7: the actual decision path. Stale pythonPath/ffmpegPath
    ExtState with no physical runtime must route to the first-time-setup
    prompt, NOT startExistingRuntimeSetupMenu()."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_decision_harness(
        tmp_path, os_name=os_name, home_dir=home, venv_python_exists=False,
        ext_python_path="/deleted/STEMwerk/.venv/bin/python",
        ext_ffmpeg_path="/deleted/STEMwerk/ffmpeg",
    )
    out = _run(harness, home)
    assert out["CALLED_EXISTING"] == "false", (
        f"stale ExtState incorrectly routed to the existing-runtime menu: {out}"
    )
    assert out["CALLED_FIRST_TIME_PROMPT"] == "true", out


@pytestmark_lua
@pytest.mark.parametrize("os_name", ["Linux", "macOS"])
def test_genuine_existing_runtime_reaches_existing_runtime_menu(tmp_path: Path, os_name: str):
    """Section 8: a genuinely existing runtime must still route to
    startExistingRuntimeSetupMenu(), never the first-time prompt -- this
    fix must not force returning users through first-time setup."""
    home = tmp_path / "home"
    home.mkdir()
    harness = _build_decision_harness(
        tmp_path, os_name=os_name, home_dir=home, venv_python_exists=True,
        ext_python_path="", ext_ffmpeg_path="",
    )
    out = _run(harness, home)
    assert out["CALLED_EXISTING"] == "true", (
        f"a genuinely existing runtime failed to route to the existing-runtime menu: {out}"
    )
    assert out["CALLED_FIRST_TIME_PROMPT"] == "false", out
