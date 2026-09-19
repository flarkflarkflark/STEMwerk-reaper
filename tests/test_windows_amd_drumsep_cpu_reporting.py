"""Windows AMD: Direct Kit / Kit Split explicit CPU served from the
DirectML DrumSep runtime (.venv-drumsep-directml) must be reported as CPU --
never DirectML -- in both the live progress footer and the completion
dialog's "Method" label.

This is the Windows-side sibling of test_linux_amd_drumsep_cpu_reporting.py.
That file fixed a real bug: STEMwerk.lua's parseRuntimeMetadataFromLogFile
unconditionally set info.runtimeSelected = "rocm" whenever it saw a
torch_version=...+rocm... or drumsep_torch_hip=... line, which are capability
signals (the Torch BUILD is ROCm-capable), not execution signals (this job
ran on the GPU) -- and a real CPU-via-ROCm run always prints those
capability lines *after* the execution marker.

Code-inspection audit of the same function for the Windows/DirectML
equivalent found no analogous bug to fix:

  - There is no DirectML "capability" line comparable to
    torch_version=...+rocm... / drumsep_torch_hip=... that
    parseRuntimeMetadataFromLogFile parses into info.runtimeSelected --
    "directml" only ever reaches info.runtimeSelected via the genuine
    execution markers (backend=directml, drumsep_runtime_selected=directml),
    which are exactly the markers this fix ensures report "cpu" for a
    CPU-via-DirectML run.
  - drumsep_runtime_selected=<kind> (line ~4579/~4768 in
    audio_separator_process.py) is printed unconditionally and parsed by
    parseRuntimeMetadataFromLogFile with an unconditional assignment
    (info.runtimeSelected = selected, no guard) -- so it always reflects
    whatever _select_drumsep_runtime returned as `kind`, which after this
    fix is "cpu" for the DirectML-as-CPU-host case exactly like the
    ROCm-as-CPU-host case.
  - preferredRuntimeSelection / resolveResultMethodLabel /
    buildDksFooterDeviceIntent / activeDrumsepCpuFallbackLabel all treat an
    explicit "cpu" requested device or a resolved runtimeSelected=="cpu" as
    authoritative ahead of (or independently of) any "directml" substring
    check.

These tests exercise the real, unmodified STEMwerk.lua reporting functions
(extracted verbatim by line range, same technique as
test_linux_amd_drumsep_cpu_reporting.py) against synthetic logs shaped like
a genuine Windows AMD CPU-via-DirectML run, to prove this Windows path was
never broken and stays that way.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"

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


def _extract_reporting_functions() -> str:
    """Pull the exact, unmodified function bodies under test straight out of
    the real production STEMwerk.lua by their real top-level function
    boundaries (verified via `grep -n "^function \\|^local function "`),
    rather than re-implementing or approximating their logic here."""
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
-- functions were already written to return (e.g. "CPU", "DirectML").
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


def _parse_log_text(tmp_path: Path, text: str, max_lines: int = 0) -> dict:
    log_path = tmp_path / "synthetic.log"
    log_path.write_text(text, encoding="utf-8")
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


# A synthetic but realistic Direct Kit / Kit Split explicit-CPU-via-DirectML
# log, shaped exactly like what audio_separator_process.py now emits for the
# clean bundled Windows AMD layout (.venv-drumsep-directml present,
# .venv-drumsep absent): the explicit_cpu policy line, a missing dedicated
# CPU probe, then the new directml-as-cpu probe succeeding, followed by the
# unconditional drumsep_runtime_selected=cpu execution marker and the
# build_drumsep_subprocess_env diagnostics for backend="cpu".
DIRECT_KIT_CPU_VIA_DIRECTML_LOG = """\
STEMWERK_DIAG ffmpeg_path=C:\\Program Files\\STEMwerk\\ffmpeg.exe
normalized_device_request=cpu
drumsep_runtime_selection_policy=explicit_cpu
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_cpu_start
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_cpu_end detail=missing
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_directml_as_cpu_start
timing_utc=2026-09-19T05:27:09 drumsep_runtime_probe_directml_as_cpu_end detail=ok
drumsep_runtime_selected=cpu
drumsep_runtime_selection_policy=explicit_cpu_via_directml_runtime
drumsep_python=C:\\Users\\flark\\AppData\\Local\\STEMwerk\\.venv-drumsep-directml\\Scripts\\python.exe
drumsep_gpu_capable=no
drumsep_torch_version=2.4.1+cpu
drumsep_torch_hip=
drumsep_device_names=
drumsep_runtime_fallback_reason=cpu_skipped:missing
drumsep_helper_device=cpu
drumsep_helper_requested_device=cpu
drumsep_helper_backend_runtime=cpu
drumsep_subprocess_env_profile=cpu_isolated
drumsep_helper_device_arg=cpu
backend_runtime=cpu
requested_device=cpu
effective_device=cpu
model_device=cpu
timing_utc=2026-09-19T05:29:01 drumsep_helper_ok=true
"""

DIRECT_KIT_GPU_VIA_DIRECTML_LOG = """\
STEMWERK_DIAG ffmpeg_path=C:\\Program Files\\STEMwerk\\ffmpeg.exe
normalized_device_request=auto
drumsep_runtime_selection_policy=auto_prefer_cuda
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_cuda_start
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_cuda_end detail=missing
timing_utc=2026-09-19T05:27:07 drumsep_runtime_probe_directml_start
timing_utc=2026-09-19T05:27:09 drumsep_runtime_probe_directml_end detail=ok
drumsep_runtime_selected=directml
drumsep_runtime_selection_policy=fallback_directml
drumsep_python=C:\\Users\\flark\\AppData\\Local\\STEMwerk\\.venv-drumsep-directml\\Scripts\\python.exe
drumsep_gpu_capable=yes
drumsep_device_names=AMD Radeon RX 9070
drumsep_helper_device=directml
drumsep_helper_requested_device=auto
drumsep_helper_backend_runtime=directml
drumsep_subprocess_env_profile=directml_isolated
drumsep_helper_device_arg=directml
backend_runtime=directml
requested_device=auto
effective_device=directml
timing_utc=2026-09-19T05:28:31 drumsep_helper_ok=true
"""


@requires_lua
def test_direct_kit_cpu_via_directml_reports_cpu_in_completion(tmp_path):
    result = _parse_log_text(tmp_path, DIRECT_KIT_CPU_VIA_DIRECTML_LOG)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_direct_kit_cpu_via_directml_progress_window_is_correct_early(tmp_path):
    # Simulates an early progress poll: only the lines up to and including
    # the drumsep_runtime_selected=cpu execution marker exist yet.
    partial_lines = 8  # up to and including "drumsep_runtime_selected=cpu"
    result = _parse_log_text(tmp_path, DIRECT_KIT_CPU_VIA_DIRECTML_LOG, max_lines=partial_lines)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_kit_split_cpu_via_directml_reports_cpu_in_completion(tmp_path):
    # Kit Split shares the exact same marker shape as Direct Kit for stage2.
    result = _parse_log_text(tmp_path, DIRECT_KIT_CPU_VIA_DIRECTML_LOG)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_direct_kit_gpu_via_directml_completion_unchanged(tmp_path):
    result = _parse_log_text(tmp_path, DIRECT_KIT_GPU_VIA_DIRECTML_LOG)
    assert result["runtimeSelected"] == "directml"
    assert result["methodLabel"] == "DirectML"


@requires_lua
def test_explicit_cpu_execution_marker_wins_over_directml_provenance(tmp_path):
    """Even if a directml_python path or DirectML-capability detail were to
    appear anywhere in the log (e.g. via drumsep_python=...directml...), the
    explicit drumsep_runtime_selected=cpu execution marker must be
    authoritative for the completion label -- mirrors
    test_explicit_cpu_execution_marker_wins_over_rocm_capability_metadata in
    the Linux reporting tests."""
    log_text = (
        "drumsep_runtime_selected=cpu\n"
        "drumsep_python=C:\\Users\\flark\\AppData\\Local\\STEMwerk\\.venv-drumsep-directml\\Scripts\\python.exe\n"
        "drumsep_helper_device_arg=cpu\n"
    )
    result = _parse_log_text(tmp_path, log_text)
    assert result["runtimeSelected"] == "cpu"
    assert result["methodLabel"] == "CPU"


@requires_lua
def test_explicit_directml_execution_marker_still_wins_no_regression(tmp_path):
    log_text = (
        "drumsep_runtime_selected=directml\n"
        "drumsep_python=C:\\Users\\flark\\AppData\\Local\\STEMwerk\\.venv-drumsep-directml\\Scripts\\python.exe\n"
    )
    result = _parse_log_text(tmp_path, log_text)
    assert result["runtimeSelected"] == "directml"
    assert result["methodLabel"] == "DirectML"


# --- structural: progress consumes the exact same parser output -----------


def test_progress_state_is_wired_from_the_same_parser_output():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "local info = parseRuntimeMetadataFromLogFile(progressState.logFile, 400)" in src
    assert "progressState._runtimeSelected = info.runtimeSelected or progressState._runtimeSelected" in src
    assert "progressState._backendRuntime = info.backendRuntime or progressState._backendRuntime" in src


def test_no_directml_capability_line_unconditionally_overwrites_runtime_selected():
    """Guards against ever re-introducing the class of bug fixed for ROCm:
    parseRuntimeMetadataFromLogFile must not gain a DirectML-capability-based
    assignment to info.runtimeSelected that isn't guarded by "only if not
    already set" (the same discipline info.backendRuntime already follows
    next to the ROCm capability lines)."""
    src = MAIN_LUA.read_text(encoding="utf-8")
    parse_fn = _extract_lines(src, 14943, 15099)
    for line in parse_fn.splitlines():
        if "directml" in line.lower() and "info.runtimeSelected" in line:
            assert "not info.runtimeSelected" in parse_fn or "info.runtimeSelected ==" in line, (
                f"found an unguarded DirectML-based info.runtimeSelected assignment: {line!r}"
            )
