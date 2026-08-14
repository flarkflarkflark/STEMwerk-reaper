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
--
-- Section 2 onward (below the original 3 tests) adds the ready_to_go.env
-- currentness fixtures for the 2.3.1.0 "separate current readiness from
-- cached state" fix: classifyReadyState, buildCheckOnlyFinalMessage's cached-
-- readiness line, buildLinuxFinalRows' new Check-only Reason row, and
-- buildWindowsSetupOverview (now a global function specifically so it is
-- reachable here) all run as real production code against real temp
-- bootstrap.env/capabilities.env/ready_to_go.env files -- not just pattern
-- assertions on source text.

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
assertf(type(classifyReadyState) == "function", "classifyReadyState was not exposed as a global function")
assertf(type(resolveDrumsepPolicyState) == "function", "resolveDrumsepPolicyState was not exposed as a global function")
assertf(type(buildWindowsSetupOverview) == "function", "buildWindowsSetupOverview was not exposed as a global function")

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
-- Small filesystem fixture helpers for the buildWindowsSetupOverview
-- fixtures below (it reads real bootstrap.env/capabilities.env/
-- ready_to_go.env/bootstrap.log files from disk; there is no way to drive
-- its real behavior without real files).
-- ---------------------------------------------------------------------
local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. TMP_ROOT .. "\"")

local function writeFixtureFile(path, content)
    local f = io.open(path, "w")
    assertf(f ~= nil, "could not open fixture file for writing: " .. tostring(path))
    f:write(content)
    f:close()
end

local function mkFixtureRuntime(name)
    local base = TMP_ROOT .. SEP .. name
    local stateDir = base .. SEP .. "state"
    local logsDir = base .. SEP .. "logs"
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. stateDir .. "\"")
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. logsDir .. "\"")
    return { base = base, runtimeState = stateDir, runtimeLogs = logsDir }
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

-- =======================================================================
-- Section 2: ready_to_go.env currentness fixtures (task spec section 15,
-- fixtures A-M). classifyReadyState is the single shared currentness
-- policy; per the spec it must NEVER report "current_for_this_invocation"
-- from an ordinary Check/Repair read, because no invocation-identity link
-- exists in the bootstrap writers today (out of scope for this reader-side
-- fix) -- only "cached" (status + timestamp), "historical" (status, no
-- timestamp) or "invalid" (no status at all).
-- =======================================================================

-- Fixture H (and the classifier's core contract): a July timestamp does not
-- make an August read "current" -- it is still "cached", never promoted by
-- age/recency alone.
local function testClassifyReadyStateNeverReportsCurrent()
    local julyState = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_DETAIL = "target_free_space_insufficient",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
    }
    local classified = classifyReadyState(julyState)
    assertf(classified.currentness == "cached",
        "a dated ready_to_go snapshot must classify as cached, got: " .. tostring(classified.currentness))
    assertf(classified.currentness ~= "current_for_this_invocation",
        "classifyReadyState must never report current_for_this_invocation from an ordinary read (no invocation identity exists)")
    assertf(classified.status == "broken", "classified status did not round-trip")

    -- A freshly-written (today) but equally unlinked file must classify
    -- identically to the July one -- age/recency is explicitly NOT identity.
    local freshUnlinked = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_LAST_CHECK_UTC = "2026-08-15T09:00:00Z",
    }
    local classifiedFresh = classifyReadyState(freshUnlinked)
    assertf(classifiedFresh.currentness == "cached",
        "a same-day but unlinked ready_to_go snapshot must still classify as cached, not current")

    -- No timestamp at all: historical, not cached (weaker provenance).
    local noTimestamp = { READY_TO_GO_STATUS = "ok" }
    assertf(classifyReadyState(noTimestamp).currentness == "historical",
        "a status with no timestamp must classify as historical")

    -- No status at all: invalid.
    assertf(classifyReadyState({}).currentness == "invalid",
        "an empty/missing ready_to_go read must classify as invalid")
end

-- Fixture A: cached RTG=broken (July) + current runtime healthy. The
-- Check-only verdict (buildCheckOnlyVerdict/buildLinuxFinalRows) must never
-- even see readyState -- it is driven only by the live checkProbe -- so a
-- stale broken snapshot cannot produce a false current Runtime failure row.
local function testStaleBrokenRtgCannotFailCurrentHealthyRuntime()
    local readyState = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_DETAIL = "target_free_space_insufficient",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
        DRUMSEP_READY_RUNTIME_STATUS = "disk_space_insufficient",
        DRUMSEP_READY_MODEL_STATUS = "missing",
    }
    local verification = { pythonPath = "/opt/stemwerk/venv/bin/python3", pythonOk = true, ffmpegPath = "/usr/bin/ffmpeg", ffmpegOk = true }
    local checkProbe = { verifiedRuntimeOk = true, adjustedErrors = {} }
    local capState = {}
    local state = {}
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.verifiedRuntimeOk == true, "current healthy runtime probe must win regardless of stale RTG=broken")

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/opt/stemwerk/state" }, "/opt/stemwerk/logs/bootstrap.log", true, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.kind == "status_ok", "Backend row must render as healthy (status_ok), not a stale red failure")
    assertf(findRow(rows, "Reason") == nil, "no Reason/failure row should appear when the current verdict is healthy")

    -- Copy Summary text: DrumSep line must be explicitly labelled cached,
    -- and the separate "Previous readiness check" line must not read as a
    -- current failure.
    local drumsepStatus, dksSupported, normalStemsSupported = resolveDrumsepPolicyState(readyState, "linux-rocm", "rocm")
    local finalMessage = buildCheckOnlyFinalMessage(
        { { label = "bootstrap.env", ok = true, detail = "Status: ok" } },
        true, verdict, "rocm", drumsepStatus, dksSupported, normalStemsSupported, classifyReadyState(readyState))
    local text = table.concat(finalMessage, "\n")
    assertf(containsSubstring(text, "not re-verified by this Check"), "DrumSep line must disclose it is cached, not current:\n" .. text)
    assertf(containsSubstring(text, "Previous readiness check"), "cached readiness must be shown separately:\n" .. text)
    assertf(not containsSubstring(text, "currently insufficient") and not containsSubstring(text, "currently broken"),
        "cached readiness must never be phrased as a CURRENT failure:\n" .. text)
end

-- Fixture C: stale DrumSep/model failure in readyState + a current healthy
-- Check-only verdict -- current wins, old failure only ever labelled cached.
local function testStaleDrumsepFailureLabelledCachedNotCurrent()
    local readyState = {
        DRUMSEP_READY_RUNTIME_STATUS = "disk_space_insufficient",
        DRUMSEP_READY_MODEL_STATUS = "missing",
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
    }
    local checkProbe = { verifiedRuntimeOk = true, adjustedErrors = {} }
    local verification = { pythonPath = "/venv/bin/python3", pythonOk = true, ffmpegPath = "/usr/bin/ffmpeg", ffmpegOk = true }
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", {}, {})
    assertf(verdict.verifiedRuntimeOk == true, "current healthy component probe must win over cached DrumSep/model failure")
    local classified = classifyReadyState(readyState)
    assertf(classified.currentness == "cached", "stale DrumSep/model failure must classify as cached, not current")
end

-- Fixture E / M: a genuinely CURRENT runtime failure must be visible both in
-- the drawn UI row (buildLinuxFinalRows) and Copy Summary
-- (buildCheckOnlyFinalMessage), using the identical reason text.
local function testCurrentRuntimeFailureVisibleInRowsAndCopySummary()
    local verification = { pythonPath = "/venv/bin/python3", pythonOk = true, ffmpegPath = "/usr/bin/ffmpeg", ffmpegOk = true }
    local checkProbe = { verifiedRuntimeOk = false, adjustedErrors = { "torch_runtime_unsupported" } }
    local capState, state = {}, {}
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.verifiedRuntimeOk == false, "current failure must remain a failure")

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local reasonRow = findRow(rows, "Reason")
    assertf(reasonRow ~= nil, "a Check-only current failure must produce a visible Reason row, not just Copy Summary text")
    assertf(reasonRow.kind == "status_fail", "current failure Reason row must render as a failure, not muted/neutral")
    assertf(containsSubstring(reasonRow.value, "torch") or containsSubstring(reasonRow.value, "Torch"),
        "Reason row must name the actual current failure:\n" .. tostring(reasonRow.value))

    local finalMessage = buildCheckOnlyFinalMessage(
        { { label = "bootstrap.env", ok = true, detail = "Status: ok" } },
        false, verdict, "rocm", "unknown", "unknown", "unknown")
    local text = table.concat(finalMessage, "\n")
    assertf(containsSubstring(text, "torch") or containsSubstring(text, "Torch"), "Copy Summary must name the same current failure reason:\n" .. text)
    -- Fixture F: what the UI row says and what Copy Summary says must be the
    -- same underlying reason text (both derived from verdict.adjustedErrors).
    assertf(containsSubstring(text, reasonRow.value), "Copy Summary reason text must match the visible Reason row exactly:\nrow=" .. tostring(reasonRow.value) .. "\nsummary=\n" .. text)
end

-- Fixture I: stale/cached healthy state must never override a genuinely
-- current failure -- buildCheckOnlyVerdict takes checkProbe.verifiedRuntimeOk
-- directly and never re-derives it from stale state/capState, so this is
-- true by construction; assert it explicitly.
local function testStaleHealthyCannotOverrideCurrentFailure()
    local verification = { pythonPath = "/venv/bin/python3", pythonOk = true, ffmpegPath = "/usr/bin/ffmpeg", ffmpegOk = true }
    -- state/capState both look like a prior fully-healthy run.
    local state = { STATUS = "ok", STATUS_REASON = "" }
    local capState = { VERIFICATION = "ok", AUDIO_SEPARATOR = "ok", STEMWERK_CORE = "ok" }
    local checkProbe = { verifiedRuntimeOk = false, adjustedErrors = { "torch_runtime_probe_failed" } }
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.verifiedRuntimeOk == false, "a current failure must win even when every cached field looks healthy")
end

-- Fixture J: Windows overview -- cached RTG=broken (July) + every current
-- signal (status/verification/deps/python/ffmpeg) healthy must NOT force
-- needsRepair. Runs the real buildWindowsSetupOverview against real files.
local function testWindowsStaleBrokenRtgDoesNotForceNeedsRepair()
    local runtime = mkFixtureRuntime("windows-case-a")
    local pyPath = runtime.base .. SEP .. "python3"
    local ffPath = runtime.base .. SEP .. "ffmpeg"
    writeFixtureFile(pyPath, "#!/bin/sh\n")
    writeFixtureFile(ffPath, "#!/bin/sh\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "bootstrap.env",
        "STATUS=ok\nPYTHON_PATH=" .. pyPath .. "\nFFMPEG_PATH=" .. ffPath .. "\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "capabilities.env",
        "AUDIO_SEPARATOR=ok\nSTEMWERK_CORE=ok\nVERIFICATION=ok\nPYTHON_PATH=" .. pyPath .. "\nFFMPEG_PATH=" .. ffPath .. "\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "ready_to_go.env",
        "READY_TO_GO_STATUS=broken\nREADY_TO_GO_DETAIL=target_free_space_insufficient\nREADY_TO_GO_LAST_CHECK_UTC=2026-07-26T10:00:00Z\nMAIN_RUNTIME_STATUS=ok\n")
    writeFixtureFile(runtime.runtimeLogs .. SEP .. "bootstrap.log", "Bootstrap complete\n")

    local overview = buildWindowsSetupOverview(runtime, "2.3.1.0", "2.3.1.0")
    assertf(overview.needsRepair == false,
        "cached July RTG=broken must not force needsRepair when every current signal is healthy, got needsRepair=" .. tostring(overview.needsRepair))
    assertf(overview.readyToGoCurrentness == "cached", "readyToGoCurrentness must classify the dated snapshot as cached")
    assertf(overview.readyToGoStatus == "broken", "raw readyToGoStatus must still be visible as provenance, not erased")
end

-- Fixture K: Windows overview -- cached RTG=ok must not manufacture a false
-- "healthy" verdict when the CURRENT bootstrap/capabilities state records a
-- real current failure with no evidence of a later success.
local function testWindowsStaleHealthyRtgDoesNotHideCurrentFailure()
    local runtime = mkFixtureRuntime("windows-case-b")
    local pyPath = runtime.base .. SEP .. "python3"
    writeFixtureFile(pyPath, "#!/bin/sh\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "bootstrap.env",
        "STATUS=missing_ffmpeg\nSTATUS_REASON=ffmpeg_validation_failed\nPYTHON_PATH=" .. pyPath .. "\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "capabilities.env",
        "AUDIO_SEPARATOR=ok\nSTEMWERK_CORE=ok\nVERIFICATION=failed\nBOOTSTRAP_STATUS=failed\nPYTHON_PATH=" .. pyPath .. "\n")
    writeFixtureFile(runtime.runtimeState .. SEP .. "ready_to_go.env",
        "READY_TO_GO_STATUS=ok\nREADY_TO_GO_LAST_CHECK_UTC=2026-08-01T10:00:00Z\nMAIN_RUNTIME_STATUS=ok\n")
    -- Deliberately no bootstrap.log: this run has no "Bootstrap complete"
    -- evidence of its own, so there is nothing suggesting the failure is
    -- stale/superseded.

    local overview = buildWindowsSetupOverview(runtime, "2.3.1.0", "2.3.1.0")
    assertf(overview.needsRepair == true, "a genuinely current failure must still require Repair despite cached RTG=ok")
    assertf(overview.setupStatus == "missing_ffmpeg", "the current failure status must not be overwritten to ok by cached RTG healthy state")
    assertf(overview.verification == "failed", "current verification=failed must not be hidden by cached RTG=ok")
end

local tests = {
    { "resolved-verdict-wins-over-stale-state", testResolvedVerdictWinsOverStaleState },
    { "build-linux-final-rows-does-not-reresolve-stale-state", testBuildLinuxFinalRowsDoesNotReresolveStaleState },
    { "copy-summary-shows-real-failure-reason", testCopySummaryShowsRealFailureReason },
    { "classify-ready-state-never-reports-current", testClassifyReadyStateNeverReportsCurrent },
    { "stale-broken-rtg-cannot-fail-current-healthy-runtime", testStaleBrokenRtgCannotFailCurrentHealthyRuntime },
    { "stale-drumsep-failure-labelled-cached-not-current", testStaleDrumsepFailureLabelledCachedNotCurrent },
    { "current-runtime-failure-visible-in-rows-and-copy-summary", testCurrentRuntimeFailureVisibleInRowsAndCopySummary },
    { "stale-healthy-cannot-override-current-failure", testStaleHealthyCannotOverrideCurrentFailure },
    { "windows-stale-broken-rtg-does-not-force-needs-repair", testWindowsStaleBrokenRtgDoesNotForceNeedsRepair },
    { "windows-stale-healthy-rtg-does-not-hide-current-failure", testWindowsStaleHealthyRtgDoesNotHideCurrentFailure },
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

os.execute((IS_WINDOWS and "rmdir /s /q " or "rm -rf ") .. "\"" .. TMP_ROOT .. "\"" .. (IS_WINDOWS and "" or " 2>/dev/null"))

print("All headless Setup final-rows/Copy-Summary tests passed.")
