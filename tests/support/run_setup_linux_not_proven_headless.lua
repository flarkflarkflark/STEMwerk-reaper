-- Headless behavioral tests for the 2.3.1.0 "distinguish incomplete checks
-- from failures" fix in STEMwerk_Setup_Internal.lua (Linux Setup->Check
-- presentation only -- see the release-gate investigation this closes).
--
-- Background bug this pins:
--   checkPinnedTorchRuntime() seeds result.driftReason with the DEFAULT
--   "torch_runtime_probe_failed" and only overwrites it if its python
--   subprocess produces a parseable RUNTIME_DRIFT_REASON= line before
--   timeout/exit. If the subprocess times out, crashes, or produces
--   unparseable output, that seeded default silently survives and was
--   previously treated identically to a genuine detected failure (e.g.
--   torch_too_new_for_demucs) -- conflating "we could not complete
--   verification" (NOT_PROVEN) with "we verified and it's broken" (FAILED).
--   Separately, prettyCheckError's text for torch_runtime_probe_failed was
--   stale/false: it claimed "current ready-to-go state remains
--   authoritative" long after every removeError("torch_runtime_probe_failed")
--   gate that used to grant that authority was removed from the surrounding
--   accept-conditions (canAcceptRocm7Torch210 / bootstrapVerified-or-
--   canAcceptMacIntelCpuFallback / canAcceptMacReadyHealthyState, already
--   stripped of its removeError call).
--
-- This dofile()s the real production script exactly like
-- tests/support/run_setup_final_rows_headless.lua (see that file's header
-- for the headless-load mechanism). checkPinnedTorchRuntime is exercised via
-- REAL subprocess invocation against small fixture "python" shell scripts
-- (not a Lua-level mock) -- checkPinnedTorchRuntime only cares that its
-- `path` argument runs `<path> -B -c <script>` and produces parseable
-- stdout, so a controlled shell script standing in for python is a faithful,
-- non-mocked way to force each of the two subprocess outcomes deterministically.

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
assertf(type(checkPinnedTorchRuntime) == "function", "checkPinnedTorchRuntime was not exposed as a global function")
assertf(type(reconcileCheckVerification) == "function", "reconcileCheckVerification was not exposed as a global function")
assertf(type(buildCheckOnlyVerdict) == "function", "buildCheckOnlyVerdict was not exposed as a global function")
assertf(type(buildLinuxFinalRows) == "function", "buildLinuxFinalRows was not exposed as a global function")
assertf(type(buildCheckOnlyFinalMessage) == "function", "buildCheckOnlyFinalMessage was not exposed as a global function")
assertf(type(labelHistoricalCheckOnlyLogLines) == "function", "labelHistoricalCheckOnlyLogLines was not exposed as a global function")
assertf(type(linuxLogPanelDefaultScrollToTop) == "function", "linuxLogPanelDefaultScrollToTop was not exposed as a global function")

local function containsSubstring(text, needle)
    return tostring(text or ""):find(needle, 1, true) ~= nil
end

local function findRow(rows, label)
    for _, row in ipairs(rows) do
        if row.label == label then return row end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Fixture fake-python helpers: real (tiny, non-python) executables that
-- stand in for a python interpreter purely as far as checkPinnedTorchRuntime
-- is concerned (it only runs `<path> -B -c <script>` and parses stdout).
-- ---------------------------------------------------------------------
local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. TMP_ROOT .. "\"")

local function writeFakePython(name, body)
    local path = TMP_ROOT .. SEP .. name
    local f = io.open(path, "w")
    assertf(f ~= nil, "could not open fixture fake-python for writing: " .. tostring(path))
    f:write(body)
    f:close()
    os.execute("chmod +x \"" .. path .. "\"")
    return path
end

-- Never produces a parseable RUNTIME_DRIFT_REASON= line and exits non-zero --
-- models a crashed/garbled subprocess. The seeded default driftReason
-- ("torch_runtime_probe_failed") must survive untouched.
local FAKE_PYTHON_INCOMPLETE = writeFakePython("fake_python_incomplete.sh",
    "#!/bin/sh\necho 'unexpected garbled output, no drift markers here'\nexit 2\n")

-- Explicitly reports RUNTIME_DRIFT_REASON=torch_import_failed and exits
-- non-zero -- models the python script's own `except Exception` branch when
-- `import torch` itself raises. The subprocess DID complete and DID
-- establish a negative result; this must not be folded into the same
-- "probe incomplete" bucket as the default above.
local FAKE_PYTHON_IMPORT_FAILED = writeFakePython("fake_python_import_failed.sh",
    "#!/bin/sh\n"
    .. "echo 'TORCH_VERSION='\n"
    .. "echo 'TORCHAUDIO_VERSION='\n"
    .. "echo 'TORCH_SUPPORTED=no'\n"
    .. "echo 'TORCHAUDIO_PRESENT=no'\n"
    .. "echo 'RUNTIME_DRIFT_DETECTED=yes'\n"
    .. "echo 'RUNTIME_DRIFT_REASON=torch_import_failed'\n"
    .. "exit 1\n")

-- Explicitly reports RUNTIME_DRIFT_REASON=torch_too_new_for_demucs -- an
-- existing, already-established genuine-failure code, confirming the
-- incomplete/import_failed split above does not disturb it.
local FAKE_PYTHON_TOO_NEW = writeFakePython("fake_python_too_new.sh",
    "#!/bin/sh\n"
    .. "echo 'TORCH_VERSION=2.9.0'\n"
    .. "echo 'TORCHAUDIO_VERSION=2.9.0'\n"
    .. "echo 'TORCH_SUPPORTED=no'\n"
    .. "echo 'TORCHAUDIO_PRESENT=yes'\n"
    .. "echo 'RUNTIME_DRIFT_DETECTED=yes'\n"
    .. "echo 'RUNTIME_DRIFT_REASON=torch_too_new_for_demucs'\n"
    .. "exit 1\n")

-- =======================================================================
-- checkPinnedTorchRuntime: real-subprocess proof that an incomplete probe
-- and an explicit detected failure now produce distinct result.error codes.
-- =======================================================================

local function testIncompleteProbeStaysNotProvenCode()
    local result = checkPinnedTorchRuntime(FAKE_PYTHON_INCOMPLETE)
    assertf(result.ok == false, "an incomplete/garbled probe must not report ok=true")
    assertf(result.driftReason == "torch_runtime_probe_failed",
        "an incomplete probe must retain the seeded default driftReason, got: " .. tostring(result.driftReason))
    assertf(result.error == "torch_runtime_probe_failed",
        "an incomplete probe must map to the torch_runtime_probe_failed (not-proven) error code, got: " .. tostring(result.error))
end

local function testExplicitImportFailureGetsOwnFailedCode()
    local result = checkPinnedTorchRuntime(FAKE_PYTHON_IMPORT_FAILED)
    assertf(result.ok == false, "an explicit torch import failure must not report ok=true")
    assertf(result.driftReason == "torch_import_failed",
        "an explicit failure must parse RUNTIME_DRIFT_REASON=torch_import_failed, got: " .. tostring(result.driftReason))
    assertf(result.error == "torch_import_failed",
        "a genuinely completed-and-failed probe must map to its OWN error code (torch_import_failed), " ..
        "not be folded into the not-proven torch_runtime_probe_failed bucket, got: " .. tostring(result.error))
    assertf(result.error ~= "torch_runtime_probe_failed",
        "torch_import_failed must be distinguishable from the incomplete-probe code")
end

local function testExplicitTooNewStillWorksUnaffectedBySplit()
    local result = checkPinnedTorchRuntime(FAKE_PYTHON_TOO_NEW)
    assertf(result.error == "torch_too_new_for_demucs",
        "an existing genuine-failure code must survive the incomplete/import_failed split unchanged, got: " .. tostring(result.error))
end

-- =======================================================================
-- Fixture A: NOT RE-VERIFIED -- runtime probe cannot complete, cached RTG
-- broken. Expected: runtime status=not_proven, no stale authority wording,
-- no current-failure claim, no Repair recommendation.
-- =======================================================================
local function testFixtureA_NotReverifiedProducesNotProvenVerdict()
    local readyState = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_DETAIL = "target_free_space_insufficient",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
    }
    local capState = {}
    local state = {}
    local verification = {
        pythonOk = true,
        ffmpegOk = true,
        errors = { "torch_runtime_probe_failed" },
        torchVersion = "2.10.0",
        torchaudioVersion = "2.10.0",
    }
    local checkProbe = reconcileCheckVerification(state, capState, readyState, verification, "", "AMD Radeon RX 9070", "rocm", "", "/nonexistent/bootstrap.log")
    assertf(checkProbe.verifiedRuntimeOk == false, "a not-yet-proven torch probe must not be reported as verified-ok")

    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.verifiedRuntimeOk == false, "verdict must not claim current success")
    assertf(verdict.notProvenOnly == true, "verdict.notProvenOnly must be true when the sole adjusted error is the incomplete-probe code")

    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }
    local finalMessage = buildCheckOnlyFinalMessage(checks, false, verdict, "rocm", "unknown", "unknown", "unknown")
    local text = table.concat(finalMessage, "\n")

    assertf(not containsSubstring(text, "ready-to-go state remains authoritative"),
        "stale authority wording must not appear anywhere in Copy Summary:\n" .. text)
    assertf(containsSubstring(text, "not proven"), "truthful not-proven wording must be present:\n" .. text)
    assertf(not containsSubstring(text, "one or more checks failed"),
        "a not-proven-only verdict must not claim a genuine current failure:\n" .. text)
    assertf(not containsSubstring(text, "Run Repair / rerun setup"),
        "a not-proven-only verdict must not carry a Repair recommendation:\n" .. text)

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local reasonRow = findRow(rows, "Reason")
    assertf(reasonRow ~= nil, "not-proven Reason must still be visible in the drawn rows")
    assertf(reasonRow.kind ~= "status_fail", "a not-proven-only Reason row must not render with the same red kind as a genuine failure, got: " .. tostring(reasonRow.kind))
end

-- =======================================================================
-- Fixture B: REAL FAILURE -- runtime probe actually fails with a known
-- reason. Expected: runtime status=failed, exact reason preserved, failure
-- headline preserved, existing Repair guidance preserved.
-- =======================================================================
local function testFixtureB_GenuineFailureStaysFailed()
    local capState, state, readyState = {}, {}, {}
    local verification = {
        pythonOk = true,
        ffmpegOk = true,
        errors = { "torch_too_new_for_demucs" },
    }
    local checkProbe = reconcileCheckVerification(state, capState, readyState, verification, "", "AMD Radeon RX 9070", "rocm", "", "/nonexistent/bootstrap.log")
    assertf(checkProbe.verifiedRuntimeOk == false, "a genuine current failure must not be verified-ok")

    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.notProvenOnly == false, "a genuine detected failure must NOT be classified as notProvenOnly")

    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }
    local finalMessage = buildCheckOnlyFinalMessage(checks, false, verdict, "rocm", "unknown", "unknown", "unknown")
    local text = table.concat(finalMessage, "\n")
    assertf(containsSubstring(text, "one or more checks failed"), "a genuine current failure must keep its failure headline:\n" .. text)
    assertf(containsSubstring(text, "Run Repair / rerun setup"), "a genuine current failure must keep its Repair guidance:\n" .. text)
    assertf(containsSubstring(text, "torch") or containsSubstring(text, "Torch"), "the exact current failure reason must be visible:\n" .. text)

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local reasonRow = findRow(rows, "Reason")
    assertf(reasonRow ~= nil and reasonRow.kind == "status_fail", "a genuine failure Reason row must render as a failure (status_fail)")
end

-- =======================================================================
-- Fixture C: NOT_PROVEN OVERALL headline, with no other current failures.
-- =======================================================================
local function testFixtureC_NotProvenOverallHeadline()
    local verdict = { adjustedErrors = { "torch_runtime_probe_failed" }, notProvenOnly = true }
    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }
    local finalMessage = buildCheckOnlyFinalMessage(checks, false, verdict, "cpu", "unknown", "unknown", "unknown")
    local text = table.concat(finalMessage, "\n")
    assertf(containsSubstring(text, "Verify only: setup verification was incomplete."), "expected the truthful incomplete-verification headline:\n" .. text)
    assertf(not containsSubstring(text, "Verify only: one or more checks failed."), "must NOT show the failure headline:\n" .. text)
end

-- =======================================================================
-- Fixture D: REPAIR GUIDANCE -- not_proven-only => no Repair recommendation;
-- a genuinely current failure (including a failing BASIC check, not just an
-- adjusted-error) => existing valid Repair guidance preserved.
-- =======================================================================
local function testFixtureD_RepairGuidanceOnlyForGenuineFailure()
    -- Not-proven-only, all basic checks pass: no Repair guidance.
    local verdictNotProven = { adjustedErrors = { "torch_runtime_probe_failed" }, notProvenOnly = true }
    local allOkChecks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
    }
    local msgNotProven = table.concat(buildCheckOnlyFinalMessage(allOkChecks, false, verdictNotProven, "cpu", "unknown", "unknown", "unknown"), "\n")
    assertf(not containsSubstring(msgNotProven, "Run Repair"), "not-proven-only must not recommend Repair:\n" .. msgNotProven)

    -- Not-proven torch probe AND a failing basic check (e.g. FFmpeg path
    -- missing): the basic-check failure is a genuine, concrete current
    -- problem unrelated to probe incompleteness, so this must NOT be treated
    -- as not-proven-only -- it must fall back to the genuine-failure
    -- headline/Repair guidance.
    local mixedChecks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "FFmpeg path", ok = false, detail = "Not set in bootstrap.env/capabilities.env" },
    }
    local msgMixed = table.concat(buildCheckOnlyFinalMessage(mixedChecks, false, verdictNotProven, "cpu", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(msgMixed, "Run Repair / rerun setup"),
        "a real basic-check failure alongside an incomplete torch probe must still recommend Repair:\n" .. msgMixed)
    assertf(containsSubstring(msgMixed, "one or more checks failed"),
        "a real basic-check failure alongside an incomplete torch probe must show the failure headline:\n" .. msgMixed)

    -- Genuine current failure: Repair guidance preserved.
    local verdictFailed = { adjustedErrors = { "torch_too_new_for_demucs" }, notProvenOnly = false }
    local msgFailed = table.concat(buildCheckOnlyFinalMessage(allOkChecks, false, verdictFailed, "cpu", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(msgFailed, "Run Repair / rerun setup"), "a genuine current failure must recommend Repair:\n" .. msgFailed)
end

-- =======================================================================
-- Fixture E: HISTORICAL LOG -- persisted bootstrap.log contains old
-- "Mode: repair" / pip install lines from a genuinely earlier run; the
-- current invocation is Check (no bootstrap process runs during Check). Old
-- content must be visibly labelled historical, and must never be
-- interpretable as current Check mutation. A live (non-Check) run's log
-- lines must be left completely untouched (regression).
-- =======================================================================
local function testFixtureE_HistoricalLogLabelledForCheckOnly()
    local rawLines = {
        "Setup run started (repair)",
        "Mode: repair",
        "Keeping downloaded models: /home/user/.cache/STEMwerk/models",
        "Collecting pip",
        "Successfully installed pip-26.2.1",
    }
    local labelled = labelHistoricalCheckOnlyLogLines(rawLines, true)
    assertf(#labelled == #rawLines + 1, "expected exactly one marker line prepended, got " .. tostring(#labelled) .. " lines")
    assertf(containsSubstring(labelled[1], "historical"), "the first line must disclose the content is historical, got: " .. tostring(labelled[1]))
    for i, line in ipairs(rawLines) do
        assertf(labelled[i + 1] == line, "historical log content must be preserved verbatim (line " .. i .. ")")
    end
    assertf(containsSubstring(table.concat(labelled, "\n"), "Mode: repair"),
        "historical content must still be visible (not deleted), only labelled")

    -- Regression: a live (non-Check) run must never have its log lines
    -- relabelled or altered.
    local unchanged = labelHistoricalCheckOnlyLogLines(rawLines, false)
    assertf(#unchanged == #rawLines, "a live run's log lines must not be relabelled")
    for i, line in ipairs(rawLines) do
        assertf(unchanged[i] == line, "a live run's log line " .. i .. " must be byte-identical to the source")
    end

    -- BLOCKER 2: labelling alone is not enough -- the live AMD retest showed
    -- the historical marker line 1 with NO visible marker on screen, because
    -- the log panel's default scroll position (logScroll=0) shows the BOTTOM
    -- (most recent) end of a long buffer, scrolling the marker (prepended at
    -- the top/oldest position) out of view. linuxLogPanelDefaultScrollToTop is
    -- the pure decision drawn on to fix this: a Check-only final window
    -- (checkVerdict ~= nil) must default to showing the TOP of the buffer so
    -- the marker is visible without the user having to scroll; a live run's
    -- log panel (checkVerdict == nil, no marker is ever prepended) is
    -- unaffected and keeps its normal bottom/most-recent default.
    local sampleVerdict = { isCheckOnly = true, verifiedRuntimeOk = false, notProvenOnly = true }
    assertf(linuxLogPanelDefaultScrollToTop(sampleVerdict) == true,
        "a Check-only final window (marker always present) must default its log panel to the top of the buffer")
    assertf(linuxLogPanelDefaultScrollToTop(nil) == false,
        "a live (non-Check) run (no marker ever prepended) must keep the log panel's normal bottom/most-recent default")
end

-- =======================================================================
-- Fixture F: COPY SUMMARY consistency -- Copy Summary text must agree with
-- the visible Reason row (same runtime state, same headline semantics, same
-- Repair/no-Repair decision) for both the not-proven-only and genuine-
-- failure verdicts.
-- =======================================================================
local function testFixtureF_CopySummaryMatchesVisibleRowsForBothVerdicts()
    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }

    -- Not-proven-only case.
    local verification1 = { pythonOk = true, ffmpegOk = true, errors = { "torch_runtime_probe_failed" } }
    local checkProbe1 = reconcileCheckVerification({}, {}, {}, verification1, "", "", "cpu", "", "/nonexistent/bootstrap.log")
    local verdict1 = buildCheckOnlyVerdict(verification1, checkProbe1, "cpu", "", "", "", {}, {})
    local rows1 = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict1)
    local reasonRow1 = findRow(rows1, "Reason")
    local text1 = table.concat(buildCheckOnlyFinalMessage(checks, false, verdict1, "cpu", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(text1, reasonRow1.value), "Copy Summary must contain the same reason text as the visible Reason row (not-proven case)")
    assertf(containsSubstring(text1, "incomplete") and not containsSubstring(text1, "Run Repair"),
        "Copy Summary's Repair/no-Repair decision must match the not-proven row's kind (" .. tostring(reasonRow1.kind) .. "):\n" .. text1)

    -- Genuine failure case.
    local verification2 = { pythonOk = true, ffmpegOk = true, errors = { "torch_too_new_for_demucs" } }
    local checkProbe2 = reconcileCheckVerification({}, {}, {}, verification2, "", "", "cpu", "", "/nonexistent/bootstrap.log")
    local verdict2 = buildCheckOnlyVerdict(verification2, checkProbe2, "cpu", "", "", "", {}, {})
    local rows2 = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict2)
    local reasonRow2 = findRow(rows2, "Reason")
    local text2 = table.concat(buildCheckOnlyFinalMessage(checks, false, verdict2, "cpu", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(text2, reasonRow2.value), "Copy Summary must contain the same reason text as the visible Reason row (failure case)")
    assertf(containsSubstring(text2, "Run Repair / rerun setup"),
        "Copy Summary's Repair recommendation must match the failure row's kind (" .. tostring(reasonRow2.kind) .. "):\n" .. text2)
    assertf(reasonRow2.kind == "status_fail", "the genuine-failure row must render as status_fail")
end

-- =======================================================================
-- Section 8: LIVE REGRESSION SHAPE -- models the actual AMD live case:
-- current Check where the runtime probe did not complete, cached Aug-12
-- bootstrap/capabilities, cached July ready_to_go broken, and a historical
-- bootstrap.log containing old repair/pip lines.
-- =======================================================================
local function testLiveRegressionShapeAmdCase()
    local readyState = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_DETAIL = "target_free_space_insufficient",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
    }
    local capState = { BACKEND = "rocm" }
    local state = {}
    local verification = {
        pythonOk = true,
        ffmpegOk = true,
        errors = { "torch_runtime_probe_failed" },
    }
    local checkProbe = reconcileCheckVerification(state, capState, readyState, verification, "", "AMD Radeon RX 9070", "rocm", "", "/nonexistent/bootstrap.log")
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.backend == "rocm", "live device probe backend (rocm) must be shown, got: " .. tostring(verdict.backend))
    assertf(verdict.notProvenOnly == true, "the AMD live case (probe not completed, nothing else broken) must classify as not-proven-only")

    local checks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "capabilities.env", ok = true, detail = "/state/capabilities.env" },
        { label = "Python path", ok = true, detail = "/venv/bin/python3" },
        { label = "FFmpeg path", ok = true, detail = "/usr/bin/ffmpeg" },
        { label = "Virtual environment", ok = true, detail = "/venv" },
    }
    local readyClassification = classifyReadyState(readyState)
    assertf(readyClassification.currentness == "cached", "cached July readiness must classify as cached/historical, not current")
    local finalMessage = buildCheckOnlyFinalMessage(checks, false, verdict, "rocm", "unknown", "unknown", "unknown", readyClassification)
    local text = table.concat(finalMessage, "\n")
    assertf(containsSubstring(text, "Verify only: setup verification was incomplete."), "headline must read as verification-incomplete:\n" .. text)
    assertf(not containsSubstring(text, "Run Repair / rerun setup"), "no Repair recommendation for the not-proven-only AMD case:\n" .. text)
    assertf(containsSubstring(text, "Detected backend: rocm"), "backend must be shown as currently-detected rocm:\n" .. text)
    assertf(containsSubstring(text, "cached/historical readiness above is not current"), "cached July readiness must be clearly labelled historical/cached:\n" .. text)

    -- Historical bootstrap.log containing old repair/pip lines must be
    -- labelled, not shown as unlabeled current Check output.
    local oldLogLines = {
        "Mode: repair",
        "Collecting pip",
        "Successfully installed pip-26.2.1",
    }
    local labelled = labelHistoricalCheckOnlyLogLines(oldLogLines, true)
    assertf(containsSubstring(labelled[1], "historical"), "old repair/pip log content must be clearly labelled historical")
end

local tests = {
    { "incomplete-probe-stays-not-proven-code", testIncompleteProbeStaysNotProvenCode },
    { "explicit-import-failure-gets-own-failed-code", testExplicitImportFailureGetsOwnFailedCode },
    { "explicit-too-new-still-works-unaffected-by-split", testExplicitTooNewStillWorksUnaffectedBySplit },
    { "fixture-a-not-reverified-produces-not-proven-verdict", testFixtureA_NotReverifiedProducesNotProvenVerdict },
    { "fixture-b-genuine-failure-stays-failed", testFixtureB_GenuineFailureStaysFailed },
    { "fixture-c-not-proven-overall-headline", testFixtureC_NotProvenOverallHeadline },
    { "fixture-d-repair-guidance-only-for-genuine-failure", testFixtureD_RepairGuidanceOnlyForGenuineFailure },
    { "fixture-e-historical-log-labelled-for-check-only", testFixtureE_HistoricalLogLabelledForCheckOnly },
    { "fixture-f-copy-summary-matches-visible-rows-for-both-verdicts", testFixtureF_CopySummaryMatchesVisibleRowsForBothVerdicts },
    { "live-regression-shape-amd-case", testLiveRegressionShapeAmdCase },
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

print("All headless Linux Setup not-proven/failed presentation tests passed.")
