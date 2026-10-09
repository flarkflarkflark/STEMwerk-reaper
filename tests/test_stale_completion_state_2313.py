"""Regression coverage for stale single-job completion runtime metadata.

The production failure was sequential: an accelerator Direct Kit run left
runtime fields on the persistent ``progressState`` table, then a Direct Kit
CPU run completed before its late final metadata had been polled.  The primary
test drives the extracted production start, DONE loop, finish callback, import,
final metadata refresh and completion renderer in one persistent Lua state.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = Path(os.environ.get("STEMWERK_TEST_SOURCE_ROOT", ROOT))
MAIN_LUA = SOURCE_ROOT / "scripts" / "reaper" / "STEMwerk.lua"
WORKFLOW_LUA = SOURCE_ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Workflow.lua"
LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")


def _extract_lua_function(source: str, name: str) -> str:
    lines = source.splitlines(keepends=True)
    declaration = f"function {name}("
    start = next(
        (index for index, line in enumerate(lines) if line.startswith(declaration)),
        None,
    )
    assert start is not None, f"no top-level declaration of {name}()"
    for index in range(start + 1, len(lines)):
        if lines[index].rstrip("\r\n") == "end":
            return "".join(lines[start : index + 1])
    raise AssertionError(f"no column-0 end terminates {name}()")


def _find_lua_declaration(lines: list[str], name: str) -> int | None:
    declarations = (f"function {name}(", f"local function {name}(")
    return next(
        (index for index, line in enumerate(lines) if line.startswith(declarations)),
        None,
    )


def _extract_lua_span(source: str, first_name: str, last_name: str) -> str:
    lines = source.splitlines(keepends=True)
    first = _find_lua_declaration(lines, first_name)
    last = _find_lua_declaration(lines, last_name)
    assert first is not None and last is not None and last >= first
    for index in range(last + 1, len(lines)):
        if lines[index].rstrip("\r\n") == "end":
            return "".join(lines[first : index + 1])
    raise AssertionError(f"no column-0 end terminates {last_name}()")


def _extract_optional_lua_function(source: str, name: str) -> str:
    if f"function {name}(" not in source:
        return ""
    return _extract_lua_function(source, name)


def _start_reset_function() -> str:
    source = WORKFLOW_LUA.read_text(encoding="utf-8")
    function = _extract_lua_function(source, "WORKFLOW.startSeparationProcess")
    reset_tail = "    C.progressState._deviceInfoLastAt = nil\n"
    assert function.count(reset_tail) == 1
    # Execute the unmodified production prologue and reset assignments, then
    # stop before any launcher/file side effects occur.
    return function.replace(reset_tail, reset_tail + "    do return true end\n", 1)


def _production_harness() -> str:
    source = MAIN_LUA.read_text(encoding="utf-8")
    return "\n".join(
        [
            "function T(key) return nil end",
            _extract_lua_function(source, "trSafeValue"),
            _extract_lua_function(source, "formatUserFacingProcessingDeviceLabel"),
            _extract_lua_function(source, "attachResultRuntimeMetadata"),
            _extract_lua_span(source, "sanitizeUserFacingMethodLabel", "resolveSingleTrackMethodLabel"),
            _extract_lua_function(source, "parseRuntimeMetadataFromLogFile"),
            _extract_lua_function(source, "refreshProgressRuntimeMetadataFromLogFile"),
        ]
    )


def _completion_harness() -> str:
    main = MAIN_LUA.read_text(encoding="utf-8")
    workflow = WORKFLOW_LUA.read_text(encoding="utf-8")
    return "\n".join(
        [
            _extract_lua_function(main, "trSafeValue"),
            _extract_lua_function(main, "formatUserFacingProcessingDeviceLabel"),
            _extract_lua_function(main, "normalizeStemPathKey"),
            _extract_lua_function(main, "normalizeStemPathMap"),
            _extract_lua_function(main, "renderResultMessageBox"),
            _extract_lua_function(main, "attachResultRuntimeMetadata"),
            _extract_lua_span(main, "sanitizeUserFacingMethodLabel", "resolveSingleTrackMethodLabel"),
            _extract_lua_function(main, "resultMethodReportingText"),
            _extract_lua_function(main, "buildResultMessageLines"),
            _extract_lua_function(main, "parseRuntimeMetadataFromLogFile"),
            _extract_optional_lua_function(main, "refreshProgressRuntimeMetadataFromLogFile"),
            _extract_lua_function(main, "processStemsResult"),
            _extract_lua_function(main, "resultWindowLoop"),
            _extract_lua_function(main, "showResultWindow"),
            _extract_lua_function(workflow, "WORKFLOW.checkSeparationDone"),
            _extract_lua_function(workflow, "WORKFLOW.startSeparationProcess"),
            _extract_lua_function(workflow, "WORKFLOW.progressLoop"),
            _extract_lua_span(
                workflow,
                "importStemsRespectingOriginProject",
                "WORKFLOW.finishSeparationCallback",
            ),
        ]
    )


def _lua_path(path: Path) -> str:
    return repr(str(path))


def _real_completion_driver(*, job_dir: Path, input_file: Path, python_file: Path, separator_file: Path) -> str:
    return f"""
local trace = {{}}
local renderedLines = {{}}
local parsedLogPath = ""
local function event(name) trace[#trace + 1] = name end
local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

WORKFLOW = {{}}
OS = "Linux"
PATH_SEP = "/"
PYTHON_PATH = {_lua_path(python_file)}
SEPARATOR_SCRIPT = {_lua_path(separator_file)}
WORKFLOW_TEMP_DIR = {_lua_path(job_dir)}
WINDOW_PROCESSING = "processing"
PROGRESS_IDLE_STALE_SECONDS = 3600
UI_PACING = {{ progressPollInterval = 1 }}
DKS_WORKFLOW = {{ SOURCE_DIRECT = "dks_direct", SOURCE_EXTRACT = "dks_extract" }}
SETTINGS = {{
    device = "cpu",
    model = "drumsep",
    createNewTracks = true,
    darkMode = true,
    deleteOriginalTrack = false,
    muteOriginalTrack = false,
    deleteOriginal = false,
    deleteSelection = false,
    muteOriginal = false,
    muteSelection = false,
}}
STEMS = {{
    {{ name = "Kick", file = "kick.wav", selected = true, sixStemOnly = false, color = {{230, 120, 70}} }},
    {{ name = "Snare", file = "snare.wav", selected = true, sixStemOnly = false, color = {{240, 190, 80}} }},
    {{ name = "Toms", file = "toms.wav", selected = true, sixStemOnly = false, color = {{120, 200, 120}} }},
    {{ name = "Hi-Hat", file = "hi-hat.wav", selected = true, sixStemOnly = false, color = {{90, 190, 230}} }},
    {{ name = "Ride", file = "ride.wav", selected = true, sixStemOnly = false, color = {{150, 130, 240}} }},
    {{ name = "Crash", file = "crash.wav", selected = true, sixStemOnly = false, color = {{240, 120, 180}} }},
}}
DKS_IMPORT = {{
    normalizeStemPathKey = function(name) return tostring(name or ""):lower() end,
    validateImportResult = function(expected, actual)
        return expected == actual, expected == actual and "ok" or "count_mismatch"
    end,
}}
progressState = {{
    _effectiveDevice = "cuda:0",
    _backendRuntime = "cuda",
    _drumsepHelperDeviceArg = "cuda:0",
    _runtimeSelected = "cuda",
    _normalizedDeviceRequest = "gpu",
    _deviceName = "NVIDIA GeForce RTX 4090",
    workflowMode = "drumkit",
    workflowSource = "dks_direct",
    runContext = {{ project = {{ ref = {{}} }}, run_id = "regression", run_dir_name = "current-job" }},
}}
C = {{
    progressState = progressState,
    refreshPythonPathFromExtState = function() end,
    T = function(_key) return nil end,
    isAbsolutePath = function(_path) return true end,
    canRunPython = function(_path) return true end,
    effectiveRunDevice = function() return "cpu" end,
    quoteArg = function(value) return string.format("%q", tostring(value or "")) end,
    suppressStderr = function() return "" end,
    drawProgressWindow = function() return false end,
    handleArtAdvance = function() end,
    captureWindowGeometry = function() end,
    saveSettings = function() end,
    cleanupTempWorkDir = function() end,
    showMessage = function(title, message) error(title .. ": " .. tostring(message)) end,
}}
HELPERS = {{
    getNoAudibleTargetsMessage = function() return "" end,
    getStemNamingContextForItem = function() return "Source", "input" end,
    finalizeStemFiles = function(stems) return stems end,
    forceArrangeRefresh = function() end,
    scheduleResultWindowRefresh = function() end,
    killProcessFromPidFile = function() end,
}}
SW_LOG = {{
    getLogPath = function() return WORKFLOW_TEMP_DIR .. "/exec.log" end,
    logExecResult = function() end,
    writeExitCode = function(path, code) writeFile(path, tostring(code)) end,
    readExitCode = function(path)
        local f = io.open(path or "", "r")
        if not f then return nil end
        local value = tonumber(f:read("*a")); f:close(); return value
    end,
    persistRunDiagnostics = function() end,
    preserveDiagnosticsForRun = function() end,
    writeCurrentProcessingState = function() end,
    readFileSnippet = function() return "" end,
}}
PROJECT_CONTEXT = {{
    validateOriginProjectContext = function() return true, "ok" end,
    withProjectInstance = function(_reaper, _project, callback)
        return pcall(callback)
    end,
}}
GUI = {{ _lastThemeRefresh = "", applyLiveGeometry = function(w, h) return w, h, 0, 0 end }}
THEME = {{ text = {{1, 1, 1}}, inputBg = {{0, 0, 0}}, border = {{1, 1, 1}} }}
UI_TOKENS = {{ result = {{ padding = {{}}, fonts = {{}} }} }}
gfx = {{
    mouse_cap = 0,
    x = 0,
    y = 0,
    getchar = function() return 0 end,
    quit = function() end,
    init = function() end,
    set = function() end,
    setfont = function() end,
    measurestr = function(text) return #tostring(text) end,
    drawstr = function(text) renderedLines[#renderedLines + 1] = tostring(text) end,
}}
reaper = {{
    UpdateArrange = function() end,
    GetExtState = function() return "" end,
    defer = function(callback) callback() end,
}}
resultWindowState = {{ selectedStems = {{}}, message = "", running = false, confetti = {{}}, rings = {{}} }}
multiTrackQueue = {{}}
selectedItem = {{}}
timeSelectionMode = false
timeSelectionSourceItem = nil
itemSubSelection = false
itemPos = 0
itemLen = 10
isProcessingActive = true
SW_TIMING = nil

function T(_key) return nil end
function trPlural(count, _oneKey, _manyKey, oneFallback, manyFallback)
    return count == 1 and oneFallback or manyFallback
end
function getFileSizeSafe(path)
    local f = io.open(path or "", "rb")
    if not f then return 0 end
    local size = f:seek("end") or 0; f:close(); return size
end
function checkNumpyCompat(_python) return true end
function canRunFfmpeg() return true end
function normalizeRequestedDeviceForRuntime(value) return value end
function isDirectDrumKitRoute(_options) return true end
function resolveGfx1031RocmOverrideEnv() return nil, "not_applicable", "" end
function append_diag_log(_message) end
function debugLog(_message) end
function refreshProgressActivityFromFiles() end
function uiNow() return 0 end
function pacingFrameInterval() return 1 end
function recordTimingEvent(_name) end
function writeTimingEvent() end
function resolveStemSetForPaths(_stems) return STEMS, true end
function createStemTracks(_item, _stems) return #STEMS end
function isEffectiveRun6Stem() return true end
function effectiveRunRequestedParallel() return false end
function logNormalFinalMethodDiagnostics() end
function isDrumKitWorkflowActive() return true end
function isDrumKitResultCopy() return true end
function updateTheme() end
function initCelebration() end
function getCompleteWindowTitle() return "STEMwerk - Complete" end
function getThemeRadius(_ps, fallback) return fallback end
function getThemeBorderWeight(_ps, fallback) return fallback end
function drawThemeSurfaceBox() end
function captureWindowGeometry() end
function saveSettings() end
function showStemSelectionDialog() end
function collectStemPathsFromStdoutJson() return {{}} end

{_completion_harness()}

WORKFLOW.updateProgressFromFile = function() end

local productionCheckDone = WORKFLOW.checkSeparationDone
WORKFLOW.checkSeparationDone = function(...)
    local done = productionCheckDone(...)
    if done then event("DONE_DETECTED") end
    return done
end
local productionFinish = WORKFLOW.finishSeparationCallback
WORKFLOW.finishSeparationCallback = function(...)
    event("FINISH_CALLBACK_ENTER")
    return productionFinish(...)
end
local productionProcess = processStemsResult
processStemsResult = function(...)
    event("PROCESS_STEMS_RESULT_ENTER")
    return productionProcess(...)
end
if type(refreshProgressRuntimeMetadataFromLogFile) == "function" then
    local productionRefresh = refreshProgressRuntimeMetadataFromLogFile
    refreshProgressRuntimeMetadataFromLogFile = function(force, ...)
        if force then event("FINAL_METADATA_REFRESH") end
        return productionRefresh(force, ...)
    end
end
local productionParse = parseRuntimeMetadataFromLogFile
parseRuntimeMetadataFromLogFile = function(path, maxLines, ...)
    if tonumber(maxLines) == 0 then parsedLogPath = tostring(path or "") end
    return productionParse(path, maxLines, ...)
end
local productionShowResult = showResultWindow
showResultWindow = function(selectedStems, message)
    event("RESULT_DATA_CREATED")
    return productionShowResult(selectedStems, message)
end
local productionRenderMessage = renderResultMessageBox
renderResultMessageBox = function(...)
    local result = productionRenderMessage(...)
    event("COMPLETION_RENDERED")
    return result
end
function drawResultWindow()
    renderResultMessageBox({{ w = 840, h = 600, PS = function(value) return value end }})
    return true
end

local originalExecute = os.execute
os.execute = function(_command) return true, "exit", 0 end
assert(WORKFLOW.startSeparationProcess(
    {_lua_path(input_file)}, WORKFLOW_TEMP_DIR, "drumsep",
    {{ workflowMode = "drumkit", workflowSource = "dks_direct" }}
))
os.execute = originalExecute

local resetObserved = progressState._effectiveDevice == nil
    and progressState._backendRuntime == nil
    and progressState._drumsepHelperDeviceArg == nil

local logFileEstablishedByStart = progressState.logFile
local logLines = {{}}
for index = 1, 405 do logLines[#logLines + 1] = "poll_filler_" .. index .. "=x" end
logLines[#logLines + 1] = "requested_device=cpu"
logLines[#logLines + 1] = "normalized_device_request=cpu"
logLines[#logLines + 1] = "drumsep_runtime_selected=cpu"
logLines[#logLines + 1] = "drumsep_helper_device_arg=cpu"
logLines[#logLines + 1] = "backend_runtime=cpu"
logLines[#logLines + 1] = "effective_device=cpu"
logLines[#logLines + 1] = "model_device=cpu"
logLines[#logLines + 1] = 'separator_onnx_provider=["CPUExecutionProvider"]'
writeFile(logFileEstablishedByStart, table.concat(logLines, "\\n") .. "\\n")
for _, stem in ipairs(STEMS) do
    writeFile(WORKFLOW_TEMP_DIR .. "/" .. stem.file, "fixture")
end
writeFile(WORKFLOW_TEMP_DIR .. "/exit_code.txt", "0\\n")
writeFile(WORKFLOW_TEMP_DIR .. "/done.txt", "DONE\\n")

progressState.nextPollAt = math.huge
progressState.nextFrameAt = math.huge
progressState.running = true
progressState.windowOpen = true
WORKFLOW.progressLoop()

print("RESET=" .. tostring(resetObserved))
print("ESTABLISHED_LOG=" .. tostring(logFileEstablishedByStart))
print("PARSED_LOG=" .. tostring(parsedLogPath))
print("TRACE=" .. table.concat(trace, ">"))
for _, line in ipairs(renderedLines) do print("RENDERED=" .. line) end
"""


def _parse_completion_output(output: str) -> dict[str, object]:
    scalar: dict[str, str] = {}
    rendered: list[str] = []
    for line in output.splitlines():
        if line.startswith("RENDERED="):
            rendered.append(line.removeprefix("RENDERED="))
        elif "=" in line:
            key, value = line.split("=", 1)
            scalar[key] = value
    rendered_text = "\n".join(rendered)
    method_match = re.search(r"(?:^|\|\s*)Method:\s*([^|\n]+)", rendered_text)
    backend_match = re.search(r"(?:^|\|\s*)Backend:\s*([^|\n]+)", rendered_text)
    return {
        **scalar,
        "rendered": rendered,
        "method": method_match.group(1).strip() if method_match else "",
        "backend": backend_match.group(1).strip() if backend_match else "",
    }


def _run_lua(script: str) -> str:
    assert LUA is not None
    completed = subprocess.run(
        [LUA, "-"], input=script, text=True, capture_output=True, timeout=20
    )
    assert completed.returncode == 0, (
        f"lua failed (rc={completed.returncode})\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
    )
    return completed.stdout.rstrip("\r\n")


def _lua_stubs_and_state(*, effective: str, backend: str, helper: str) -> str:
    return f"""
WORKFLOW = {{}}
C = {{
    progressState = {{
        _effectiveDevice = {effective!r},
        _backendRuntime = {backend!r},
        _drumsepHelperDeviceArg = {helper!r},
        _deviceInfoLastAt = os.clock(),
    }},
    refreshPythonPathFromExtState = function() end,
    T = function(_key) return nil end,
}}
progressState = C.progressState
SETTINGS = {{ device = "cpu" }}
multiTrackQueue = {{}}
OS = "Linux"
PATH_SEP = "/"
PYTHON_PATH = "/unused/python"
SEPARATOR_SCRIPT = "/unused/separator.py"
append_diag_log = function(_message) end
debugLog = function(_message) end
"""


@pytest.mark.parametrize(
    "effective, backend, helper",
    [
        ("cuda:0", "cuda", "cuda:0"),
        ("privateuseone:0", "directml", "privateuseone:0"),
        ("mps", "mps", "mps"),
    ],
    ids=["linux-cuda-namespace", "windows-directml", "macos-mps"],
)
def test_real_start_reset_clears_all_stale_result_determining_fields(
    effective: str, backend: str, helper: str
):
    script = _lua_stubs_and_state(effective=effective, backend=backend, helper=helper)
    script += "\n" + _start_reset_function()
    script += """
assert(WORKFLOW.startSeparationProcess("/unused/input.wav", "/current-job", "model", {}))
print(tostring(progressState._effectiveDevice or "") .. "|"
    .. tostring(progressState._backendRuntime or "") .. "|"
    .. tostring(progressState._drumsepHelperDeviceArg or ""))
"""
    assert _run_lua(script) == "||"


def _write_late_log(path: Path, lines: list[str]) -> None:
    path.write_text(
        "".join(f"poll_filler_{index}=x\n" for index in range(405))
        + "".join(f"{line}\n" for line in lines),
        encoding="utf-8",
    )


def test_real_gpu_then_direct_kit_cpu_completion_chain(tmp_path: Path):
    job_dir = tmp_path / "current-job"
    job_dir.mkdir()
    input_file = tmp_path / "input.wav"
    input_file.write_bytes(b"RIFF" + (b"\0" * 2048))
    python_file = tmp_path / "python"
    python_file.write_text("test runtime", encoding="utf-8")
    separator_file = tmp_path / "separator.py"
    separator_file.write_text("# test separator\n", encoding="utf-8")

    output = _run_lua(
        _real_completion_driver(
            job_dir=job_dir,
            input_file=input_file,
            python_file=python_file,
            separator_file=separator_file,
        )
    )
    result = _parse_completion_output(output)
    expected_log = str(job_dir / "separation_log.txt")
    expected_trace = ">".join(
        [
            "DONE_DETECTED",
            "FINISH_CALLBACK_ENTER",
            "PROCESS_STEMS_RESULT_ENTER",
            "FINAL_METADATA_REFRESH",
            "RESULT_DATA_CREATED",
            "COMPLETION_RENDERED",
        ]
    )

    assert result["method"] == "CPU", output
    assert result["backend"] == "", output
    assert result["method"] != "GPU"
    assert result["backend"] != "NVIDIA CUDA"
    assert not any("NVIDIA" in line or "CUDA" in line for line in result["rendered"])
    assert result["RESET"] == "true"
    assert result["ESTABLISHED_LOG"] == expected_log
    assert result["PARSED_LOG"] == expected_log
    assert result["TRACE"] == expected_trace


@pytest.mark.parametrize(
    "effective, backend, helper",
    [
        ("cuda:0", "cuda", "cuda:0"),
        ("privateuseone:0", "directml", "privateuseone:0"),
        ("mps", "mps", "mps"),
    ],
    ids=["linux-rocm-cuda-token", "windows-directml-token", "macos-mps-token"],
)
def test_stale_platform_token_then_cpu_uses_late_current_run_metadata(
    tmp_path: Path, effective: str, backend: str, helper: str
):
    log = tmp_path / "separation_log.txt"
    _write_late_log(
        log,
        [
            "normalized_device_request=cpu",
            "drumsep_runtime_selected=cpu",
            "drumsep_helper_device_arg=cpu",
            "backend_runtime=cpu",
            "effective_device=cpu",
        ],
    )

    script = _production_harness()
    script += _lua_stubs_and_state(effective=effective, backend=backend, helper=helper)
    script += "\n" + _start_reset_function()
    script += f"""
assert(WORKFLOW.startSeparationProcess("/unused/input.wav", "/current-job", "model", {{}}))
assert(progressState._effectiveDevice == nil, "start reset left stale effective device")
assert(progressState._backendRuntime == nil, "start reset left stale backend")
assert(progressState._drumsepHelperDeviceArg == nil, "start reset left stale helper device")

-- The normal poll saw only early CPU evidence and was throttled before the
-- authoritative effective_device line arrived after line 400.
progressState.logFile = {str(log)!r}
progressState._runtimeSelected = "cpu"
progressState._backendRuntime = "cpu"
progressState._normalizedDeviceRequest = "cpu"
progressState._deviceInfoLastAt = os.clock()

refreshProgressRuntimeMetadataFromLogFile(true)
local data = attachResultRuntimeMetadata({{}})
local method, resultBackend = resolveResultReportingTriple(data)
print(method .. "|" .. resultBackend)
"""
    method, result_backend = _run_lua(script).split("|")
    assert method == "CPU"
    assert result_backend == ""
    assert method != "GPU"
    assert result_backend != "NVIDIA CUDA"


@pytest.mark.parametrize(
    "metadata, expected_backend",
    [
        (["drumsep_runtime_selected=cuda", "backend_runtime=cuda", "effective_device=cuda:0"], "NVIDIA CUDA"),
        (["drumsep_runtime_selected=rocm", "backend_runtime=rocm", "effective_device=cuda:0"], "AMD ROCm"),
        (["drumsep_runtime_selected=directml", "backend_runtime=directml", "effective_device=privateuseone:0"], "DirectML"),
        (["drumsep_runtime_selected=mps", "backend_runtime=mps", "effective_device=mps"], "Apple MPS"),
    ],
    ids=["cuda", "rocm", "directml", "mps"],
)
def test_final_snapshot_preserves_current_accelerator_reporting(
    tmp_path: Path, metadata: list[str], expected_backend: str
):
    log = tmp_path / "separation_log.txt"
    _write_late_log(log, metadata)
    script = _production_harness()
    script += _lua_stubs_and_state(effective="cpu", backend="cpu", helper="cpu")
    script += f"""
progressState.logFile = {str(log)!r}
refreshProgressRuntimeMetadataFromLogFile(true)
local data = attachResultRuntimeMetadata({{}})
local method, resultBackend = resolveResultReportingTriple(data)
print(method .. "|" .. resultBackend)
"""
    assert _run_lua(script) == f"GPU|{expected_backend}"


def test_start_reset_lists_the_exact_stale_completion_fields():
    workflow = WORKFLOW_LUA.read_text(encoding="utf-8")
    start = _extract_lua_function(workflow, "WORKFLOW.startSeparationProcess")
    for field in ("_effectiveDevice", "_backendRuntime", "_drumsepHelperDeviceArg"):
        assert f"C.progressState.{field} = nil" in start
