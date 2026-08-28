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
STEMWERK_SETUP_TEST_HOOKS = {}
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
assertf(type(splitHistoricalLogBanner) == "function", "splitHistoricalLogBanner was not exposed as a global function")
assertf(type(historicalCheckOnlyLogMarkerText) == "function", "historicalCheckOnlyLogMarkerText was not exposed as a global function")
assertf(type(syncLinuxLogScroll) == "function", "syncLinuxLogScroll was not exposed as a global function")
assertf(type(setLinuxLogScrollManual) == "function", "setLinuxLogScrollManual was not exposed as a global function")
assertf(type(adjustLinuxLogScroll) == "function", "adjustLinuxLogScroll was not exposed as a global function")
assertf(type(STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines) == "function",
    "the namespaced test hook did not expose the real production display-line builder")

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

    -- BLOCKER 2 (original fix, 2.3.1.0): labelling alone was not enough --
    -- the live AMD retest showed the historical marker line 1 with NO
    -- visible marker on screen, because the log panel's default scroll
    -- position (logScroll=0) shows the BOTTOM (most recent) end of a long
    -- buffer, scrolling the marker (prepended at the top/oldest position)
    -- out of view. The original fix made a Check-only final window default
    -- to the TOP of the buffer instead -- but that traded the marker's
    -- visibility for hiding the actual current end-lines behind a full
    -- scroll (Finding 3, 2.3.1.1 adversarial review).
    --
    -- NEW DUAL CONTRACT (2.3.1.1): both properties must hold at once --
    -- (1) the historical-provenance marker stays visible regardless of
    -- scroll position, and (2) the console's initial position shows the
    -- actual current end-lines, same as any other log panel. This is now
    -- solved structurally, not via scroll position: drawLinuxLogPanel calls
    -- splitHistoricalLogBanner to peel the marker off the scrollable buffer
    -- and renders it as a fixed banner instead. Because
    -- splitHistoricalLogBanner's signature takes no scroll offset at all,
    -- its result -- and therefore the marker's visibility -- cannot vary
    -- with scroll position by construction.
    local sampleVerdict = { isCheckOnly = true, verifiedRuntimeOk = false, notProvenOnly = true }
    assertf(linuxLogPanelDefaultScrollToTop(sampleVerdict) == false,
        "part 2 of the dual contract: a Check-only final window must now default its log panel to the bottom (actual current end-lines), same as a live run")
    assertf(linuxLogPanelDefaultScrollToTop(nil) == false,
        "a live (non-Check) run must keep the log panel's normal bottom/most-recent default")
end

-- =======================================================================
-- Fixture G: HISTORICAL BANNER PEELING -- part 1 of the Finding 3 dual
-- contract: splitHistoricalLogBanner must reliably recover the exact marker
-- text prepended by labelHistoricalCheckOnlyLogLines, and the untouched body
-- lines behind it, from the real production marker text -- not a
-- reimplementation or a source-text assertion. A live run's lines (never
-- marker-prefixed) must be returned with no banner and byte-identical body.
-- =======================================================================
local function testFixtureG_HistoricalBannerPeeledStructurallyFromScroll()
    local rawLines = {
        "Setup run started (repair)",
        "Mode: repair",
        "Successfully installed pip-26.2.1",
    }

    -- Check-only path: labelHistoricalCheckOnlyLogLines prepends the real
    -- marker; splitHistoricalLogBanner must peel exactly that marker back
    -- off and reproduce the original body verbatim.
    local labelled = labelHistoricalCheckOnlyLogLines(rawLines, true)
    local banner, body = splitHistoricalLogBanner(labelled)
    assertf(banner == historicalCheckOnlyLogMarkerText(),
        "splitHistoricalLogBanner must recover the exact marker text prepended by labelHistoricalCheckOnlyLogLines, got: " .. tostring(banner))
    assertf(#body == #rawLines, "peeled body must have exactly the original line count, got " .. tostring(#body))
    for i, line in ipairs(rawLines) do
        assertf(body[i] == line, "peeled body content must be preserved verbatim (line " .. i .. ")")
    end

    -- Live (non-Check) path: labelHistoricalCheckOnlyLogLines never prepends
    -- a marker, so splitHistoricalLogBanner must report no banner at all and
    -- return the original lines unchanged -- proving live runs never get the
    -- banner treatment.
    local unlabelled = labelHistoricalCheckOnlyLogLines(rawLines, false)
    local liveBanner, liveBody = splitHistoricalLogBanner(unlabelled)
    assertf(liveBanner == nil, "a live run's lines must never be treated as carrying a historical banner")
    assertf(#liveBody == #rawLines, "a live run's body must be returned with its original line count")
    for i, line in ipairs(rawLines) do
        assertf(liveBody[i] == line, "a live run's body line " .. i .. " must be byte-identical to the source")
    end

    -- Empty/nil input must not error and must report no banner.
    local emptyBanner, emptyBody = splitHistoricalLogBanner({})
    assertf(emptyBanner == nil and #emptyBody == 0, "an empty log buffer must report no banner and an empty body")
    local nilBanner, nilBody = splitHistoricalLogBanner(nil)
    assertf(nilBanner == nil and #nilBody == 0, "a nil log buffer must report no banner and an empty body")
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

-- =======================================================================
-- Fixture H: Finding 5 (2.3.1.1 adversarial review) -- keyboard scroll must
-- update followTail exactly like wheel/scrollbar, through the one shared
-- helper (syncLinuxLogScroll / setLinuxLogScrollManual / adjustLinuxLogScroll)
-- all scroll input now routes through. These are the REAL production
-- functions (not a reimplementation) -- their `target` parameter exists
-- purely so this exact logic can be driven against a synthetic state table
-- headlessly, instead of the real module-local LINUX_SETUP window, which
-- only a live gfx/REAPER window can construct. Every call below mirrors
-- exactly what a real input handler in linuxSetupTick does:
--   Up/Down arrow  -> adjustLinuxLogScroll(+-5, total, visible, target)
--   Page Up/Down   -> adjustLinuxLogScroll(+-visible, total, visible, target)
--   Home           -> setLinuxLogScrollManual(math.huge, total, visible, target)
--   End            -> setLinuxLogScrollManual(0, total, visible, target)
--   wheel/scrollbar -> adjustLinuxLogScroll / setLinuxLogScrollManual likewise
-- =======================================================================
local function testFixtureH_KeyboardScrollUpdatesFollowTailLikeWheelScrollbar()
    -- 1) Start at the bottom, following the tail (matches a freshly opened
    -- running window: logScroll = 0, followTail = true).
    local target = { logScroll = 0, followTail = true }
    local total, visible = 50, 10
    local raw = {}
    for i = 1, total do raw[i] = "line-" .. i end
    syncLinuxLogScroll(STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(raw, 80), visible, target)
    assertf(target.logScroll == 0, "sanity: must start at the bottom")
    assertf(target.followTail == true, "sanity: must start following the tail")

    -- 2) Keyboard scroll up (mirrors the real Up-arrow handler, key 30064).
    adjustLinuxLogScroll(5, total, visible, target)
    assertf(target.logScroll == 5, "Up-arrow must move the scroll position, got " .. tostring(target.logScroll))
    assertf(target.followTail == false,
        "keyboard scroll away from the bottom must clear followTail just like wheel/scrollbar do -- this is the exact bug Finding 5 fixes")

    -- 3) New log lines arrive (totalLines grows). This mirrors linuxSetupTick's
    -- per-tick resync (drawLinuxLogPanel always calls syncLinuxLogScroll) --
    -- with followTail already false, growing totalLines must not silently
    -- pull the scroll position back down.
    total = 60
    for i = 51, total do raw[i] = "line-" .. i end
    syncLinuxLogScroll(STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(raw, 80), visible, target)

    -- 4) Position stays put: Finding 3 (second review) -- logScroll is a
    -- distance-from-bottom, so preserving its raw NUMBER while the bottom
    -- itself moved 10 lines further away would silently drag the viewport
    -- toward the new content. The CONTENT the user was looking at stays
    -- anchored only if logScroll advances by exactly the same 10 lines that
    -- were appended (5 -> 15); followTail is still false (nothing here
    -- silently re-enabled it).
    assertf(target.logScroll == 15, "new log lines must advance the anchor by the same amount so the same content stays visible, got " .. tostring(target.logScroll))
    assertf(target.followTail == false, "new log lines must not silently resume follow-tail on their own")

    -- 5) End explicitly returns to live-follow (mirrors the new End-key
    -- handler, key 6647396).
    setLinuxLogScrollManual(0, total, visible, target)
    assertf(target.logScroll == 0, "End must jump back to the bottom, got " .. tostring(target.logScroll))
    assertf(target.followTail == true, "End must explicitly resume live-follow")

    -- 6) New log lines are followed again: once followTail is true,
    -- linuxSetupTick's own per-tick rule (`if followTail then logScroll = 0
    -- end`, unchanged by this fix and covered by
    -- test_console_autoscroll_follows_tail_and_respects_manual_scroll)
    -- keeps pinning the view to the bottom as content grows; the scroll
    -- helper itself must not fight that by drifting off zero on a mere
    -- resync.
    total = 70
    for i = 61, total do raw[i] = "line-" .. i end
    if target.followTail then target.logScroll = 0 end
    syncLinuxLogScroll(STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(raw, 80), visible, target)
    assertf(target.logScroll == 0, "once following again, new log lines must keep the view pinned to the bottom, got " .. tostring(target.logScroll))

    -- 7) Completion behavior: the deferred finalize transition
    -- (`pendingFinalScrollReset`, unchanged by this fix) always resets to
    -- the bottom with follow-tail resumed, matching exactly what
    -- setLinuxLogScrollManual(0, ...) itself produces -- proving the
    -- keyboard-scroll fix and the completion transition converge on the
    -- same final state instead of two different ideas of "the bottom".
    local completionTarget = { logScroll = 5, followTail = false }
    setLinuxLogScrollManual(0, total, visible, completionTarget)
    assertf(completionTarget.logScroll == 0 and completionTarget.followTail == true,
        "completion must land on the same (logScroll=0, followTail=true) state as an explicit End keypress")

    -- Page Up / Page Down (mirrors the new key handlers, keys 1885828464 /
    -- 1885824110) must also update followTail through the same helper.
    local pageTarget = { logScroll = 0, followTail = true }
    adjustLinuxLogScroll(visible, total, visible, pageTarget)
    assertf(pageTarget.followTail == false, "Page Up must clear followTail like every other manual scroll input")
    adjustLinuxLogScroll(-visible, total, visible, pageTarget)
    assertf(pageTarget.followTail == true, "Page Down back to the bottom must resume followTail")

    -- Home (mirrors key 1752132965) must jump to the top and clear followTail.
    local homeTarget = { logScroll = 0, followTail = true }
    setLinuxLogScrollManual(math.huge, total, visible, homeTarget)
    local expectedMax = total - visible
    assertf(homeTarget.logScroll == expectedMax, "Home must jump to the top of the buffer, got " .. tostring(homeTarget.logScroll))
    assertf(homeTarget.followTail == false, "Home must clear followTail (the top is never the bottom)")
end

-- =======================================================================
-- Fixture I: Finding 3 (2.3.1.1 second adversarial review) -- manual scroll
-- must anchor the same VISIBLE CONTENT, not just preserve a numeric
-- distance-from-bottom. This drives the real syncLinuxLogScroll /
-- setLinuxLogScrollManual production functions and independently recomputes
-- the first-visible-line INDEX using the exact same formula drawLinuxLogPanel
-- itself uses (startIdx = totalLines - visibleLines - logScroll + 1, pinned
-- below by a source-text cross-check against the real renderer so this
-- helper cannot silently drift from production) -- then confirms that index
-- still names the same synthetic line CONTENT (a stable "line-N" identity
-- array modeling the growing display-line buffer) before and after growth,
-- not just that logScroll itself moved by a plausible-looking amount.
-- =======================================================================
local function startIdxFor(totalLines, visibleLines, logScroll)
    return math.max(1, totalLines - visibleLines - logScroll + 1)
end

local function testFixtureI_ManualScrollAnchorsSameVisibleContentThroughGrowth()
    local rendererText = _G.__setup_internal_source_for_fixture_i
    if not rendererText then
        local f = io.open(TARGET, "r")
        rendererText = f:read("*a")
        f:close()
        _G.__setup_internal_source_for_fixture_i = rendererText
    end
    assertf(rendererText:find("totalLines - visibleLines - (LINUX_SETUP.logScroll or 0) + 1", 1, true) ~= nil,
        "startIdxFor above must match the exact formula drawLinuxLogPanel uses to pick the first visible display line")

    -- 1) 50 display lines, modeled as a stable identity array; line 50 is
    -- the newest/bottom-most.
    local lines = {}
    for i = 1, 50 do lines[i] = "line-" .. i end
    local total, visible = 50, 10
    local target = { logScroll = 0, followTail = true }
    local display = STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(lines, 80)
    syncLinuxLogScroll(display, visible, target)

    -- 2) User scrolls up to view line 36 (startIdx=36 <=> logScroll=5, since
    -- 50-10-5+1=36).
    adjustLinuxLogScroll(5, total, visible, target)
    local firstVisibleBefore = startIdxFor(total, visible, target.logScroll)
    assertf(firstVisibleBefore == 36, "sanity: expected to be viewing line 36, computed startIdx=" .. tostring(firstVisibleBefore))
    assertf(lines[firstVisibleBefore] == "line-36", "sanity check on the identity array itself")

    -- 3) follow-tail is off (set by the manual scroll above).
    assertf(target.followTail == false, "sanity: manual scroll must have cleared followTail")

    -- 4) 10 new display lines arrive at the bottom.
    for i = 51, 60 do lines[i] = "line-" .. i end
    total = 60
    display = STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(lines, 80)
    syncLinuxLogScroll(display, visible, target)

    -- 5) The first visible line must still be line 36 -- the same CONTENT,
    -- not merely a similar-looking offset number.
    local firstVisibleAfter = startIdxFor(total, visible, target.logScroll)
    assertf(lines[firstVisibleAfter] == "line-36",
        "the first visible line must still be the SAME content (line-36) after growth, got " .. tostring(lines[firstVisibleAfter]) .. " (startIdx=" .. tostring(firstVisibleAfter) .. ", logScroll=" .. tostring(target.logScroll) .. ")")

    -- 6) End returns to the bottom and resumes follow-tail.
    setLinuxLogScrollManual(0, total, visible, target)
    assertf(target.followTail == true, "End must resume follow-tail")
    assertf(startIdxFor(total, visible, target.logScroll) == total - visible + 1, "End must show the true bottom of the buffer")

    -- 7) New lines are followed again: as more content arrives while
    -- followTail is true, linuxSetupTick's own per-tick rule (logScroll=0
    -- whenever followTail) keeps the viewport pinned to the newest content,
    -- i.e. the first visible line keeps advancing forward, not staying put.
    for i = 61, 65 do lines[i] = "line-" .. i end
    total = 65
    if target.followTail then target.logScroll = 0 end
    display = STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(lines, 80)
    syncLinuxLogScroll(display, visible, target)
    local firstVisibleFollowing = startIdxFor(total, visible, target.logScroll)
    assertf(lines[firstVisibleFollowing] == "line-56",
        "while following, the first visible line must advance with new content (expected line-56, the new tail's top row), got " .. tostring(lines[firstVisibleFollowing]))

    -- 8) Truncation of the anchored line clamps predictably: scroll away
    -- from the bottom again, anchor onto a specific line, then simulate the
    -- buffer being truncated (e.g. readTail's sliding window dropping old
    -- lines) so that anchored line no longer exists -- logScroll must clamp
    -- to the new maxScroll rather than pointing past the (now smaller)
    -- buffer, landing predictably at the new top of the buffer.
    local truncTarget = { logScroll = 0, followTail = true }
    syncLinuxLogScroll(display, visible, truncTarget)
    adjustLinuxLogScroll(50, 65, visible, truncTarget)
    assertf(truncTarget.logScroll == 50, "sanity: scrolled 50 lines up from the bottom of a 65-line buffer")
    assertf(truncTarget.followTail == false, "sanity: manual scroll must have cleared followTail")
    -- Buffer truncated down to 20 lines (older content fell off the top of
    -- a sliding readTail() window); the anchored line is long gone.
    local maxScrollAfterTruncation = math.max(0, 20 - visible)
    local truncated = {}
    for i = 46, 65 do truncated[#truncated + 1] = "line-" .. i end
    syncLinuxLogScroll(STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines(truncated, 80), visible, truncTarget)
    assertf(truncTarget.logScroll == maxScrollAfterTruncation,
        "truncation must clamp logScroll predictably to the new maxScroll, got " .. tostring(truncTarget.logScroll) .. " expected " .. tostring(maxScrollAfterTruncation))
    assertf(startIdxFor(20, visible, truncTarget.logScroll) == 1, "a clamped-after-truncation view must land at the new top of the buffer")
end

-- =======================================================================
-- Fixture J: final-review content anchor. This drives the real production
-- display builder and scroll synchronizer. Assertions use the first visible
-- display item's source identity and character offset, never logScroll alone.
-- =======================================================================
local function testFixtureJ_ContentAnchorSurvivesReflowResizeAndSlidingTail()
    local buildDisplay = STEMWERK_SETUP_TEST_HOOKS.buildLinuxLogDisplayLines

    local function numbered(first, last)
        local lines = {}
        for i = first, last do lines[#lines + 1] = "line-" .. i end
        return lines
    end

    local function render(target, raw, width, visible)
        local display = buildDisplay(raw, width)
        syncLinuxLogScroll(display, visible, target)
        local idx = math.max(1, #display - visible - (target.logScroll or 0) + 1)
        return display, display[idx], idx
    end

    local function anchorAt(target, display, visible, index)
        local scroll = math.max(0, #display - visible - index + 1)
        setLinuxLogScrollManual(scroll, #display, visible, target)
        syncLinuxLogScroll(display, visible, target)
    end

    -- 1) 50 -> 60 append and 2) viewport height changes keep line 36.
    local raw = numbered(1, 50)
    local target = { logScroll = 0, followTail = true }
    local display = render(target, raw, 80, 10)
    anchorAt(target, display, 10, 36)
    for i = 51, 60 do raw[#raw + 1] = "line-" .. i end
    local grown, first = render(target, raw, 80, 10)
    assertf(first.source == "line-36", "append must retain line-36, got " .. tostring(first.source))
    local _, taller = render(target, raw, 80, 15)
    assertf(taller.source == "line-36", "taller viewport must retain line-36, got " .. tostring(taller.source))
    local _, shorter = render(target, raw, 80, 6)
    assertf(shorter.source == "line-36", "shorter viewport must retain line-36, got " .. tostring(shorter.source))

    -- 3/10) Width reflow keeps both the source and the wrapped character
    -- position for an anchor in the third segment of a long line.
    local wrappedRaw = numbered(1, 20)
    wrappedRaw[12] = "line-12 " .. string.rep("alpha beta gamma delta ", 8)
    local wrappedTarget = { logScroll = 0, followTail = true }
    local wide = render(wrappedTarget, wrappedRaw, 24, 8)
    local thirdSegment
    for i, item in ipairs(wide) do
        if item.sourceIndex == 12 and item.segmentIndex == 3 then thirdSegment = i break end
    end
    assertf(thirdSegment ~= nil, "sanity: long line must have a third wrapped segment")
    anchorAt(wrappedTarget, wide, 8, thirdSegment)
    local _, beforeWrap = render(wrappedTarget, wrappedRaw, 24, 8)
    local _, afterWrap = render(wrappedTarget, wrappedRaw, 15, 8)
    assertf(afterWrap.sourceIndex == 12 and afterWrap.source == wrappedRaw[12], "reflow must retain the same source line")
    assertf(afterWrap.charStart <= beforeWrap.charStart,
        "reflow must select the segment containing the old character offset")
    assertf((afterWrap.charEnd or math.huge) >= beforeWrap.charStart,
        "reflowed segment must cover the old wrapped character offset")

    -- 4) Duplicate line text is disambiguated by neighboring source context.
    local duplicateRaw = numbered(1, 50)
    duplicateRaw[20] = "repeated-status"
    duplicateRaw[36] = "repeated-status"
    duplicateRaw[19], duplicateRaw[21] = "first-before", "first-after"
    duplicateRaw[35], duplicateRaw[37] = "anchor-before", "anchor-after"
    local duplicateTarget = { logScroll = 0, followTail = true }
    local duplicates = render(duplicateTarget, duplicateRaw, 80, 10)
    anchorAt(duplicateTarget, duplicates, 10, 36)
    for _ = 1, 5 do table.remove(duplicateRaw, 1) end
    for i = 51, 55 do duplicateRaw[#duplicateRaw + 1] = "line-" .. i end
    local _, duplicateFirst = render(duplicateTarget, duplicateRaw, 80, 10)
    assertf(duplicateFirst.source == "repeated-status" and duplicateFirst.sourceIndex == 31,
        "duplicate anchor must follow its anchor-before/anchor-after context, got sourceIndex=" .. tostring(duplicateFirst.sourceIndex))

    -- 5) Growth plus head truncation keeps a retained anchor.
    local sliding = numbered(1, 50)
    local slidingTarget = { logScroll = 0, followTail = true }
    local slidingDisplay = render(slidingTarget, sliding, 80, 10)
    anchorAt(slidingTarget, slidingDisplay, 10, 36)
    sliding = numbered(11, 60)
    local _, slidingFirst = render(slidingTarget, sliding, 80, 10)
    assertf(slidingFirst.source == "line-36", "sliding tail must retain line-36, got " .. tostring(slidingFirst.source))

    -- 6) If the anchor itself was truncated, clamp predictably to new top.
    local removed = numbered(1, 50)
    local removedTarget = { logScroll = 0, followTail = true }
    local removedDisplay = render(removedTarget, removed, 80, 10)
    anchorAt(removedTarget, removedDisplay, 10, 6)
    removed = numbered(11, 60)
    local _, removedFirst = render(removedTarget, removed, 80, 10)
    assertf(removedFirst.source == "line-11", "removed anchor must clamp to retained head line-11, got " .. tostring(removedFirst.source))

    -- 7) Repeated rapid append+truncation updates do not accumulate drift.
    local rapid = numbered(1, 50)
    local rapidTarget = { logScroll = 0, followTail = true }
    local rapidDisplay = render(rapidTarget, rapid, 80, 10)
    anchorAt(rapidTarget, rapidDisplay, 10, 36)
    for step = 1, 8 do
        table.remove(rapid, 1)
        rapid[#rapid + 1] = "line-" .. (50 + step)
        local _, rapidFirst = render(rapidTarget, rapid, 80, 10)
        assertf(rapidFirst.source == "line-36", "rapid update " .. step .. " drifted to " .. tostring(rapidFirst.source))
    end

    -- 8) End resumes tail; 9) Home remains anchored after the next update.
    setLinuxLogScrollManual(0, #grown, 10, target)
    raw[#raw + 1] = "line-61"
    local _, endFirst = render(target, raw, 80, 10)
    assertf(target.followTail and endFirst.source == "line-52", "End must resume tail-follow at the newest content")

    setLinuxLogScrollManual(math.huge, #grown + 1, 10, target)
    raw[#raw + 1] = "line-62"
    local _, homeFirst = render(target, raw, 80, 10)
    assertf(not target.followTail and homeFirst.source == "line-1", "Home must remain anchored to the retained head")

    print("PASS fixture-j-content-anchor-survives-reflow-resize-and-sliding-tail")
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
    { "fixture-g-historical-banner-peeled-structurally-from-scroll", testFixtureG_HistoricalBannerPeeledStructurallyFromScroll },
    { "fixture-f-copy-summary-matches-visible-rows-for-both-verdicts", testFixtureF_CopySummaryMatchesVisibleRowsForBothVerdicts },
    { "live-regression-shape-amd-case", testLiveRegressionShapeAmdCase },
    { "fixture-h-keyboard-scroll-updates-follow-tail-like-wheel-scrollbar", testFixtureH_KeyboardScrollUpdatesFollowTailLikeWheelScrollbar },
    { "fixture-i-manual-scroll-anchors-same-visible-content-through-growth", testFixtureI_ManualScrollAnchorsSameVisibleContentThroughGrowth },
    { "fixture-j-content-anchor-survives-reflow-resize-and-sliding-tail", testFixtureJ_ContentAnchorSurvivesReflowResizeAndSlidingTail },
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
