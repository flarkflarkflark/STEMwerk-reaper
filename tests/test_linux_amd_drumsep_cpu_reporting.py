"""AMD Linux: a ROCm-capable Torch build must never by itself cause a real
CPU run to be displayed as GPU, in either the live progress footer or the
completion dialog's "Method" label.

Root cause (proven against real captured logs from the AMD RX 9070 machine):
STEMwerk.lua's parseRuntimeMetadataFromLogFile unconditionally overwrote
info.runtimeSelected = "rocm" whenever it saw a torch_version=...+rocm...
or a non-empty drumsep_torch_hip=... line -- facts that only prove the
Python/Torch BUILD is ROCm-capable, not that the current job executed on
the GPU. Both progress (which polls this same function on the growing log
file every ~0.5s, see the "progressState._runtimeSelected = info.runtimeSelected"
wiring below) and completion (which parses the full final log) feed off this
one function, so a single fix here addresses both surfaces. Normal Stems was
wrong in progress AND completion because its capability-announcing
"STEMWERK_DIAG torch_version=..." line is printed within microseconds of
startup -- before any poll could ever see a "clean" log. Direct Kit/Kit
Split progress was already correct because drumsep_runtime_selected=<kind>
is printed by the parent process well before the DrumSep subprocess's own
torch/hip diagnostic lines land in the log, so an early poll sees a clean
value; only the final, full-log completion parse was corrupted.

The fix (in scripts/reaper/STEMwerk.lua, parseRuntimeMetadataFromLogFile)
guards the two capability-based assignments to info.runtimeSelected with
"only if not already set" -- the exact same guard the adjacent
info.backendRuntime assignment in the same two blocks already used. This
makes actual execution markers (backend=cpu, drumsep_runtime_selected=cpu/
rocm) authoritative whenever they appear (and they always appear before the
capability lines in every real log observed), while still falling back to
the capability signal when no execution marker exists at all (preserving
the existing conservative default for genuine GPU runs).

This is a pure Lua-source fix. Nothing in the Python resolver
(_select_drumsep_runtime, build_drumsep_subprocess_env, the DrumSep helper)
is touched or exercised differently by these tests.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
FIXTURES = ROOT / "tests" / "fixtures" / "amd_rocm_logs"

LUA_CANDIDATES = [
    shutil.which("lua"),
    shutil.which("lua5.4"),
    shutil.which("luajit"),
]


def _lua_interpreter():
    for candidate in LUA_CANDIDATES:
        if candidate and Path(candidate).exists():
            return candidate
    return None


LUA = _lua_interpreter()
requires_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")


def _extract_lines(text: str, start_line: int, end_line_exclusive: int) -> str:
    """1-indexed, matching the line numbers a plain text editor/grep would show."""
    lines = text.splitlines(keepends=True)
    return "".join(lines[start_line - 1 : end_line_exclusive - 1])


def test_trsafevalue_stub_matches_real_production_implementation():
    """Guards against silent drift between T_STUB's reproduced trSafeValue and
    the real one at STEMwerk.lua:9121, which lies outside the extracted
    ranges these tests otherwise pull verbatim from production."""
    src = MAIN_LUA.read_text(encoding="utf-8")
    real = _extract_lines(src, 9121, 9131)
    assert real.startswith("function trSafeValue(key, fallback)")
    assert real.rstrip().endswith("end")
    assert real.strip() in T_STUB


def _extract_reporting_functions() -> str:
    """Pull the exact, unmodified function bodies under test straight out of the
    real production STEMwerk.lua by their real top-level function boundaries
    (verified via `grep -n "^function \\|^local function "`), rather than
    re-implementing or approximating their logic here. Boundaries are the
    start of the next top-level function declaration, which is unambiguous
    for well-formed top-level Lua function definitions."""
    src = MAIN_LUA.read_text(encoding="utf-8", errors="replace")

    format_label_fn = _extract_lines(src, 1126, 1196)
    assert format_label_fn.startswith("function formatUserFacingProcessingDeviceLabel(...)")
    assert format_label_fn.rstrip().endswith("end")

    method_label_fns = _extract_lines(src, 9366, 9457)
    assert method_label_fns.startswith("function sanitizeUserFacingMethodLabel(candidate)")
    assert "function preferredRuntimeSelection(" in method_label_fns
    assert "function resolveResultMethodLabel(data)" in method_label_fns
    assert method_label_fns.rstrip().endswith("end")

    parse_fn = _extract_lines(src, 14943, 15099)
    assert parse_fn.startswith("function parseRuntimeMetadataFromLogFile(logFile, maxLines)")
    assert parse_fn.rstrip().endswith("end")

    return format_label_fn + "\n" + method_label_fns + "\n" + parse_fn


T_STUB = """
-- Minimal stand-in for STEMwerk's i18n lookup: always miss, so
-- trSafeValue(key, fallback) falls back to the English default text these
-- functions were already written to return (e.g. "CPU", "AMD ROCm").
function T(key) return nil end
-- trSafeValue itself (real implementation at STEMwerk.lua:9121) is outside
-- the extracted ranges below; reproduced verbatim here rather than widening
-- the extraction, since its own logic is not under test.
function trSafeValue(key, fallback)
    local v = T(key)
    if not v or v == "" then return fallback end
    local raw = tostring(key or "")
    local value = tostring(v)
    if value == raw or value == raw:gsub("_", " ") then
        return fallback
    end
    return value
end
"""


def _run_lua(driver: str) -> str:
    assert LUA is not None
    script = T_STUB + "\n" + _extract_reporting_functions() + "\n" + driver
    completed = subprocess.run(
        [LUA, "-"],
        input=script,
        text=True,
        capture_output=True,
        timeout=15,
    )
    assert completed.returncode == 0, (
        f"lua script failed (rc={completed.returncode}):\n"
        f"--- stdout ---\n{completed.stdout}\n--- stderr ---\n{completed.stderr}"
    )
    return completed.stdout


def _parse_log_fixture(name: str, max_lines: int = 0) -> dict:
    log_path = FIXTURES / name
    assert log_path.exists(), f"missing fixture: {log_path}"
    driver = f"""
local info = parseRuntimeMetadataFromLogFile({log_path.as_posix()!r}, {max_lines})
print("runtimeSelected=" .. tostring(info.runtimeSelected or ""))
print("backendRuntime=" .. tostring(info.backendRuntime or ""))
print("effectiveDevice=" .. tostring(info.effectiveDevice or ""))
print("methodLabel=" .. tostring(sanitizeUserFacingMethodLabel(preferredRuntimeSelection(
    info.runtimeSelected, info.stage2Runtime, info.stage1Runtime, info.backendRuntime, info.effectiveDevice
))))
"""
    out = _run_lua(driver)
    result = {}
    for line in out.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            result[key] = value
    return result


# --- A: Normal Stems CPU -- progress and completion share one parse -------


@requires_lua
def test_normal_stems_cpu_reports_cpu_not_rocm():
    result = _parse_log_fixture("normal_stems_cpu.log")
    assert result["runtimeSelected"] == "cpu", (
        "torch_version=...+rocm... must not clobber the explicit backend=cpu marker"
    )
    assert result["methodLabel"] == "CPU"


# --- B: Normal Stems Auto/ROCm ---------------------------------------------


@requires_lua
def test_normal_stems_auto_rocm_still_reports_gpu():
    result = _parse_log_fixture("normal_stems_auto_rocm.log")
    assert result["runtimeSelected"] == "rocm", (
        "with no execution marker overriding it (backend=gpu is generic), the capability "
        "signal must still be trusted -- this is the existing conservative fallback"
    )
    assert result["methodLabel"] == "AMD ROCm"


# --- C: Normal Stems explicit AMD GPU/ROCm ---------------------------------
# STEMwerk's Python side collapses every GPU backend (rocm/cuda/directml/mps)
# to the same generic "backend=gpu" marker for Normal Stems regardless of
# whether the request was Auto or an explicit device name -- there is no
# separate code path to test here; explicit-GPU Normal Stems runs the exact
# same parser logic exercised by test B above.


# --- D: Direct Kit CPU using .venv-drumsep-rocm ----------------------------


@requires_lua
def test_direct_kit_cpu_via_rocm_reports_cpu_in_completion():
    result = _parse_log_fixture("direct_kit_cpu_via_rocm.log")
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_direct_kit_cpu_via_rocm_progress_window_was_already_correct_and_remains_so():
    # Simulates an early progress poll: only the first ~24 lines exist yet,
    # i.e. before the DrumSep subprocess's own torch/hip diagnostic lines
    # have been written. This was already correct pre-fix and must remain so.
    result = _parse_log_fixture("direct_kit_cpu_via_rocm.log", max_lines=24)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


# --- E: Kit Split CPU using .venv-drumsep-rocm -----------------------------


@requires_lua
def test_kit_split_cpu_via_rocm_reports_cpu_in_completion():
    result = _parse_log_fixture("kit_split_cpu_via_rocm.log")
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_kit_split_cpu_via_rocm_progress_window_was_already_correct_and_remains_so():
    result = _parse_log_fixture("kit_split_cpu_via_rocm.log", max_lines=38)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


# --- F / G: Direct Kit / Kit Split GPU-via-ROCm completion unchanged ------


@requires_lua
def test_direct_kit_gpu_via_rocm_completion_unchanged():
    result = _parse_log_fixture("direct_kit_gpu_rocm.log")
    assert result["runtimeSelected"] == "rocm"
    assert result["methodLabel"] == "AMD ROCm"


# --- H: explicit CPU execution marker must win over ROCm capability -------


@requires_lua
def test_explicit_cpu_execution_marker_wins_over_rocm_capability_metadata(tmp_path):
    log = tmp_path / "synthetic.log"
    log.write_text(
        "drumsep_runtime_selected=cpu\n"
        "drumsep_torch_version=2.10.0+rocm7.0\n"
        "drumsep_torch_hip=7.0.51831\n",
        encoding="utf-8",
    )
    driver = f"""
local info = parseRuntimeMetadataFromLogFile({str(log).__repr__()}, 0)
print("runtimeSelected=" .. tostring(info.runtimeSelected or ""))
"""
    out = _run_lua(driver)
    assert "runtimeSelected=cpu" in out


# --- I: explicit ROCm execution marker still wins (no regression) ---------


@requires_lua
def test_explicit_rocm_execution_marker_still_wins(tmp_path):
    log = tmp_path / "synthetic.log"
    log.write_text(
        "drumsep_torch_version=2.10.0+rocm7.0\n"
        "drumsep_torch_hip=7.0.51831\n"
        "drumsep_runtime_selected=rocm\n",
        encoding="utf-8",
    )
    driver = f"""
local info = parseRuntimeMetadataFromLogFile({str(log).__repr__()}, 0)
print("runtimeSelected=" .. tostring(info.runtimeSelected or ""))
"""
    out = _run_lua(driver)
    assert "runtimeSelected=rocm" in out


# --- J: capability-only metadata, no execution marker at all ---------------


@requires_lua
def test_capability_only_metadata_with_no_execution_marker_falls_back_to_rocm(tmp_path):
    # Documents the intentional, unchanged conservative default: if nothing
    # ever reports an actual execution device/backend, a ROCm-capable torch
    # build is still assumed to mean ROCm/GPU, exactly as before this fix.
    log = tmp_path / "synthetic.log"
    log.write_text("drumsep_torch_version=2.10.0+rocm7.0\n", encoding="utf-8")
    driver = f"""
local info = parseRuntimeMetadataFromLogFile({str(log).__repr__()}, 0)
print("runtimeSelected=" .. tostring(info.runtimeSelected or ""))
"""
    out = _run_lua(driver)
    assert "runtimeSelected=rocm" in out


# --- structural: progress consumes the exact same parser output -----------


def test_progress_state_is_wired_from_the_same_parser_output():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "local info = parseRuntimeMetadataFromLogFile(progressState.logFile, 400)" in src
    assert "progressState._runtimeSelected = info.runtimeSelected or progressState._runtimeSelected" in src
    assert "progressState._backendRuntime = info.backendRuntime or progressState._backendRuntime" in src
