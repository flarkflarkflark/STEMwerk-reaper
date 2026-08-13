-- Headless behavioral tests for the 2.3.1.0 follow-up "resolved Check-only
-- verdict" fix in STEMwerk_Setup_Internal.lua: buildLinuxFinalRows must
-- never independently re-derive Python/backend/device state from stale
-- bootstrap.env/capabilities.env once a Check-only run has produced a
-- resolved verdict, and Copy Summary must be built from that same verdict
-- so a FAIL always shows the reason it failed for.
--
-- This dofile()s the real production script with STEMWERK_SETUP_HEADLESS_TEST
-- set, which (via a small guard added right before the real auto-invoking
-- setup flow at the bottom of the file) makes the script only define its
-- functions/globals and skip the actual REAPER-driven setup flow. A minimal
-- `reaper` stub satisfies the handful of incidental top-level calls the
-- script makes while loading (install-location resolution, theme setup).
-- The functions under test here (buildCheckOnlyVerdict, buildLinuxFinalRows,
-- buildCheckOnlyFinalMessage) are pure data transforms with no further
-- REAPER/gfx/process dependencies, so no further mocking is required.

local SEP = package.config:sub(1, 1)
local IS_WINDOWS = SEP == "\\"

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local source = (info and info.source) or ""
    local path = source:match("^@(.*)$") or source
    return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local REPO_ROOT = scriptDir() .. "/../.."
local TARGET = REPO_ROOT .. "/scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"

STEMWERK_SETUP_HEADLESS_TEST = true
reaper = {
    ShowMessageBox = function() return 0 end,
    GetOS = function() return "Other" end,
    GetExtState = function() return "" end,
    SetExtState = function() end,
    HasExtState = function() return false end,
    DeleteExtState = function() end,
    ShowConsoleMsg = function() end,
    defer = function() end,
    GetResourcePath = function() return "/tmp" end,
    get_action_context = function() return "", "" end,
}

local ok, err = pcall(dofile, TARGET)
assertf(ok, "failed to load " .. TARGET .. " in headless test mode: " .. tostring(err))
assertf(type(buildCheckOnlyVerdict) == "function", "buildCheckOnlyVerdict was not exposed as a global function")
assertf(type(buildLinuxFinalRows) == "function", "buildLinuxFinalRows was not exposed as a global function")
assertf(type(buildCheckOnlyFinalMessage) == "function", "buildCheckOnlyFinalMessage was not exposed as a global function")

local function findRow(rows, label)
    for _, row in ipairs(rows) do
        if row.label == label then return row end
    end
    return nil
end

local function containsSubstring(text, needle)
    return tostring(text or ""):find(needle, 1, true) ~= nil
end

-- ---------------------------------------------------------------------
-- Section 1: resolved Check-only verdict, required fixture from the task
-- spec verbatim -- stale capabilities said python_missing/backend=cpu, but
-- current evidence (Python probe exit=0, Torch OK, MPS available, live
-- backend=metal) proves the runtime is healthy. buildLinuxFinalRows must
-- show the CURRENT truth, not the stale one, and must not independently
-- re-derive it from capState/state.
-- ---------------------------------------------------------------------
local function testResolvedVerdictWinsOverStaleState()
    local verification = {
        pythonPath = "/opt/stemwerk/venv/bin/python3",
        pythonOk = true,
        ffmpegPath = "/usr/bin/ffmpeg",
        ffmpegOk = true,
    }
    local checkProbe = {
        verifiedRuntimeOk = true,
        adjustedErrors = {},
    }
    -- Stale recorded state: an old failed run left python_missing behind,
    -- and the last recorded backend was cpu.
    local state = {
        STATUS_REASON = "python_missing",
        BACKEND = "cpu",
    }
    local capState = {
        BACKEND = "cpu",
        PYTHON_PATH = "",
        FFMPEG_PATH = "",
    }

    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "metal", "", "", "Apple M2 (MPS)", capState, state)
    assertf(verdict.verifiedRuntimeOk == true, "resolved verdict must be verifiedRuntimeOk=true")
    assertf(#verdict.staleProvenance >= 1, "stale python_missing/backend=cpu conflict was not recorded as provenance")

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/opt/stemwerk/state" }, "/opt/stemwerk/logs/bootstrap.log", true, verdict)
    local pythonRow = findRow(rows, "Python")
    local backendRow = findRow(rows, "Backend")
    assertf(pythonRow ~= nil and pythonRow.value == "/opt/stemwerk/venv/bin/python3",
        "Python row did not reflect the resolved live verdict's pythonPath")
    assertf(not containsSubstring(pythonRow.value, "python_missing"),
        "Python row leaked the stale python_missing state")
    assertf(backendRow ~= nil and backendRow.value == "metal",
        "Backend row did not reflect the resolved live verdict's backend (metal), got: " .. tostring(backendRow and backendRow.value))
    assertf(backendRow.value ~= "cpu", "Backend row leaked the stale capabilities backend=cpu")

    local historicalRow = findRow(rows, "Historical")
    assertf(historicalRow ~= nil, "stale conflict was not preserved anywhere as historical/stale provenance")
    assertf(containsSubstring(historicalRow.value, "python_missing") or containsSubstring(historicalRow.value, "cpu"),
        "historical provenance row does not mention the stale conflict it is supposed to record")
end

-- ---------------------------------------------------------------------
-- Section 1 (M1): buildLinuxFinalRows must not independently re-resolve
-- stale state even when called multiple times / when capState disagrees in
-- a different way (backend reason/note also stale).
-- ---------------------------------------------------------------------
local function testBuildLinuxFinalRowsDoesNotReresolveStaleState()
    local verification = { pythonPath = "/venv/bin/python3", pythonOk = true, ffmpegPath = "/usr/bin/ffmpeg", ffmpegOk = true }
    local checkProbe = { verifiedRuntimeOk = true, adjustedErrors = {} }
    local state = { BACKEND = "cpu", BACKEND_REASON = "device_probe_failed" }
    local capState = { BACKEND = "cpu", BACKEND_REASON = "device_probe_failed" }
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "cuda", "", "", "NVIDIA RTX 4090", capState, state)

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/state" }, "/logs/bootstrap.log", true, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow.value == "cuda", "buildLinuxFinalRows re-derived Backend from stale state instead of using the resolved verdict")
    -- Stale backend reason (device_probe_failed) must not appear as if it
    -- were the CURRENT backend reason once the verdict is healthy with no
    -- current backend reason of its own.
    local reasonRow = findRow(rows, "Backend reason")
    assertf(reasonRow == nil, "stale backend reason (device_probe_failed) leaked into the current Backend reason row")
end

-- ---------------------------------------------------------------------
-- Section 2: Copy Summary must show the actual FAIL reason, not just "one
-- or more checks failed" followed only by [OK] rows.
-- ---------------------------------------------------------------------
local function testCopySummaryShowsRealFailureReason()
    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }
    -- All 5 basic checks are OK, but the resolved verdict is a genuine
    -- current failure (e.g. an unsupported Torch runtime) that those 5
    -- basic file/dir checks cannot see on their own.
    local verdict = {
        isCheckOnly = true,
        verifiedRuntimeOk = false,
        adjustedErrors = { "torch_too_new_for_demucs" },
        staleProvenance = {},
    }
    local allOk = false -- allOk = all 5 checks AND verifiedRuntimeOk; verifiedRuntimeOk is false here
    local finalMessage = buildCheckOnlyFinalMessage(checks, allOk, verdict, "cuda", "unknown", "unknown", "unknown")
    local text = table.concat(finalMessage, "\n")

    assertf(containsSubstring(text, "one or more checks failed"), "FAIL summary text missing:\n" .. text)
    for _, c in ipairs(checks) do
        assertf(containsSubstring(text, "[OK]  " .. c.label), "expected visible [OK] row for " .. c.label .. ":\n" .. text)
    end
    -- The actual failing reason must be visibly present, not hidden.
    assertf(containsSubstring(text, "torch") or containsSubstring(text, "Torch"),
        "the actual FAIL reason (torch_too_new_for_demucs) is not visible in Copy Summary text:\n" .. text)
    -- It must not read as "one or more checks failed" with ONLY [OK] rows
    -- and nothing else explaining why.
    local onlyOkRows = true
    for line in text:gmatch("[^\n]+") do
        if line:find("^%[%-%-%]") then onlyOkRows = false end
    end
    assertf(not onlyOkRows, "Copy Summary said FAIL but every visible row was [OK], hiding the real reason:\n" .. text)
end

local tests = {
    { "resolved-verdict-wins-over-stale-state", testResolvedVerdictWinsOverStaleState },
    { "build-linux-final-rows-does-not-reresolve-stale-state", testBuildLinuxFinalRowsDoesNotReresolveStaleState },
    { "copy-summary-shows-real-failure-reason", testCopySummaryShowsRealFailureReason },
}

for _, t in ipairs(tests) do
    local name, fn = t[1], t[2]
    local testOk, testErr = pcall(fn)
    if not testOk then
        io.stderr:write("FAIL " .. name .. ": " .. tostring(testErr) .. "\n")
        os.exit(1)
    end
    print("PASS " .. name)
end

print("All headless Setup final-rows/Copy-Summary tests passed.")
