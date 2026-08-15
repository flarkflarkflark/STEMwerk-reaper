-- Headless behavioral tests for deriveLinuxFinalPresentation, the small pure
-- three-state (ok/failed/not_proven) presentation mapping introduced to close
-- the remaining gap after the 2.3.1.0 "distinguish incomplete checks from
-- failures" fix (see tests/support/run_setup_linux_not_proven_headless.lua):
-- that fix corrected buildLinuxFinalRows' Reason row and Copy Summary
-- (buildCheckOnlyFinalMessage), but the visible gfx final window's headline,
-- Backend row color, and Repair-button gating still consumed only a raw
-- finalSuccess boolean, so a genuinely not-proven (incomplete verification,
-- nothing found broken) Check still rendered identically to a real failure:
-- "Setup was not completely successful." with a red Runtime segment and a
-- Repair recommendation, even though Copy Summary already read correctly.
--
-- linuxDrawFinal itself is gfx.*-only and cannot be executed headlessly (no
-- host to run it against) -- that limitation is unchanged and disclosed here
-- as it was in the prior round. What IS headlessly provable, and what these
-- tests cover, is the actual decision logic: deriveLinuxFinalPresentation
-- (the pure mapping) and buildLinuxFinalRows/buildCheckOnlyFinalMessage (the
-- two consumers that must agree with each other and with it). Reading
-- linuxDrawFinal's diff confirms it only renders presentation.headline/
-- overallState/state -- it computes no success/failure logic of its own.
--
-- This dofile()s the real production script exactly like the other
-- tests/support/*_headless.lua files (see run_setup_final_rows_headless.lua's
-- header for the headless-load mechanism).

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
assertf(type(deriveLinuxFinalPresentation) == "function", "deriveLinuxFinalPresentation was not exposed as a global function")
assertf(type(buildCheckOnlyVerdict) == "function", "buildCheckOnlyVerdict was not exposed as a global function")
assertf(type(buildLinuxFinalRows) == "function", "buildLinuxFinalRows was not exposed as a global function")
assertf(type(buildCheckOnlyFinalMessage) == "function", "buildCheckOnlyFinalMessage was not exposed as a global function")
assertf(type(reconcileCheckVerification) == "function", "reconcileCheckVerification was not exposed as a global function")

local function containsSubstring(text, needle)
    return tostring(text or ""):find(needle, 1, true) ~= nil
end

local function findRow(rows, label)
    for _, row in ipairs(rows) do
        if row.label == label then return row end
    end
    return nil
end

local ALL_OK_CHECKS = {
    { label = "bootstrap.env",       ok = true, detail = "Status: ok" },
    { label = "capabilities.env",    ok = true, detail = "/state/capabilities.env" },
    { label = "Python path",         ok = true, detail = "/venv/bin/python3" },
    { label = "FFmpeg path",         ok = true, detail = "/usr/bin/ffmpeg" },
    { label = "Virtual environment", ok = true, detail = "/venv" },
}

-- =======================================================================
-- A. NOT_PROVEN -- runtime probe incomplete, no other current failure.
-- =======================================================================
local function testA_NotProven()
    local verdict = {
        isCheckOnly = true,
        verifiedRuntimeOk = false,
        notProvenOnly = true,
        adjustedErrors = { "torch_runtime_probe_failed" },
        backend = "rocm",
        staleProvenance = {},
    }
    local presentation = deriveLinuxFinalPresentation(false, true, verdict)
    assertf(presentation.state == "not_proven", "expected state=not_proven, got: " .. tostring(presentation.state))
    assertf(presentation.headline == "Setup verification was incomplete."
        or containsSubstring(presentation.headline, "incomplete"),
        "expected a truthful incomplete-verification headline, got: " .. tostring(presentation.headline))
    assertf(presentation.runtimeState == "not_proven", "expected runtimeState=not_proven, got: " .. tostring(presentation.runtimeState))
    assertf(presentation.overallState == "not_proven", "expected overallState=not_proven, got: " .. tostring(presentation.overallState))
    assertf(presentation.overallState ~= "failed", "not_proven must not render as the same semantic state as failed")
    assertf(presentation.state ~= "failed", "not_proven must not imply Repair guidance (Repair is gated on state==failed)")

    -- Row-level: Backend/Reason rows must not use the red status_fail kind.
    local rows = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.kind == "note",
        "not_proven Backend row must render with the neutral/warning 'note' kind, got: " .. tostring(backendRow and backendRow.kind))
    local reasonRow = findRow(rows, "Reason")
    assertf(reasonRow ~= nil and reasonRow.kind == "note",
        "not_proven Reason row must render with the neutral/warning 'note' kind, got: " .. tostring(reasonRow and reasonRow.kind))
    assertf(reasonRow.kind ~= "status_fail", "not_proven Reason row must not render red (status_fail)")
end

-- =======================================================================
-- B. FAILED -- current runtime failure.
-- =======================================================================
local function testB_Failed()
    local verdict = {
        isCheckOnly = true,
        verifiedRuntimeOk = false,
        notProvenOnly = false,
        adjustedErrors = { "torch_too_new_for_demucs" },
        backend = "rocm",
        staleProvenance = {},
    }
    local presentation = deriveLinuxFinalPresentation(false, true, verdict)
    assertf(presentation.state == "failed", "expected state=failed, got: " .. tostring(presentation.state))
    assertf(presentation.headline == "Setup was not completely successful.",
        "expected the existing failure headline, got: " .. tostring(presentation.headline))
    assertf(presentation.runtimeState == "failed", "expected runtimeState=failed, got: " .. tostring(presentation.runtimeState))
    assertf(presentation.overallState == "failed", "expected overallState=failed, got: " .. tostring(presentation.overallState))

    local rows = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.kind == "status_fail",
        "a genuine failure Backend row must render red (status_fail), got: " .. tostring(backendRow and backendRow.kind))
    local reasonRow = findRow(rows, "Reason")
    assertf(reasonRow ~= nil and reasonRow.kind == "status_fail",
        "a genuine failure Reason row must render red (status_fail), got: " .. tostring(reasonRow and reasonRow.kind))

    -- Repair guidance must still be present in Copy Summary for a genuine failure.
    local text = table.concat(buildCheckOnlyFinalMessage(ALL_OK_CHECKS, false, verdict, "rocm", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(text, "Run Repair / rerun setup"), "genuine failure must keep its Repair guidance:\n" .. text)
end

-- =======================================================================
-- C. OK -- current runtime healthy.
-- =======================================================================
local function testC_Ok()
    local verdict = {
        isCheckOnly = true,
        verifiedRuntimeOk = true,
        notProvenOnly = false,
        adjustedErrors = {},
        backend = "rocm",
        staleProvenance = {},
    }
    local presentation = deriveLinuxFinalPresentation(true, true, verdict)
    assertf(presentation.state == "ok", "expected state=ok, got: " .. tostring(presentation.state))
    assertf(presentation.headline == "Setup complete.", "expected the existing success headline, got: " .. tostring(presentation.headline))
    assertf(presentation.runtimeState == "ok", "expected runtimeState=ok, got: " .. tostring(presentation.runtimeState))
    assertf(presentation.overallState == "ok", "expected overallState=ok, got: " .. tostring(presentation.overallState))

    local rows = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", true, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.kind == "status_ok",
        "a healthy Backend row must render as status_ok, got: " .. tostring(backendRow and backendRow.kind))
    assertf(findRow(rows, "Reason") == nil, "no Reason/failure row should appear for a healthy verdict")
end

-- =======================================================================
-- D. MIXED -- runtime not_proven, but another CURRENT basic check fails
-- (e.g. FFmpeg missing). Overall must read failed (a genuine unrelated
-- failure must never be hidden behind not_proven), but the Runtime state
-- itself must remain not_proven, not be folded into "failed" too.
-- =======================================================================
local function testD_MixedNotProvenPlusGenuineFailure()
    local verdict = {
        isCheckOnly = true,
        verifiedRuntimeOk = false,
        notProvenOnly = true, -- Torch probe itself: incomplete, nothing found broken
        adjustedErrors = { "torch_runtime_probe_failed" },
        backend = "rocm",
        staleProvenance = {},
    }
    local mixedChecks = {
        { label = "bootstrap.env", ok = true, detail = "Status: ok" },
        { label = "FFmpeg path",   ok = false, detail = "Not set in bootstrap.env/capabilities.env" },
    }
    local allBasicChecksOk = false -- FFmpeg path check above failed
    local presentation = deriveLinuxFinalPresentation(false, allBasicChecksOk, verdict)

    assertf(presentation.overallState == "failed",
        "an unrelated genuine basic-check failure must force overall=failed even though the Torch probe was only not_proven, got: " .. tostring(presentation.overallState))
    assertf(presentation.state == "failed", "expected state=failed for the mixed case, got: " .. tostring(presentation.state))
    assertf(presentation.runtimeState == "not_proven",
        "the Runtime's OWN state must remain not_proven in the mixed case (must not be hidden nor folded into failed), got: " .. tostring(presentation.runtimeState))

    -- Copy Summary must show the failure headline/Repair guidance for the
    -- unrelated genuine failure (buildCheckOnlyFinalMessage already covers
    -- this text-wise; re-confirmed here as it now shares deriveLinuxFinalPresentation).
    local text = table.concat(buildCheckOnlyFinalMessage(mixedChecks, false, verdict, "rocm", "unknown", "unknown", "unknown"), "\n")
    assertf(containsSubstring(text, "one or more checks failed"), "mixed case must show the failure headline:\n" .. text)
    assertf(containsSubstring(text, "Run Repair / rerun setup"), "mixed case must keep Repair guidance:\n" .. text)

    -- Row-level: the Backend/Reason (Runtime-specific) rows must still use
    -- the not_proven 'note' kind, independent of the unrelated FFmpeg
    -- failure -- buildLinuxFinalRows intentionally does not know about
    -- allBasicChecksOk, only about the verdict's own runtime state.
    local rows = buildLinuxFinalRows({}, {}, { runtimeState = "/state" }, "/logs/bootstrap.log", false, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.kind == "note",
        "Runtime-specific Backend row must stay not_proven-colored ('note') in the mixed case, got: " .. tostring(backendRow and backendRow.kind))
end

-- =======================================================================
-- E. COPY SUMMARY CONSISTENCY -- the normalized presentation state and the
-- Copy Summary verdict text must agree, for all three states.
-- =======================================================================
local function testE_CopySummaryConsistency()
    local function summaryText(finalSuccess, allBasicChecksOk, verdict, checks)
        return table.concat(buildCheckOnlyFinalMessage(checks, finalSuccess, verdict, "rocm", "unknown", "unknown", "unknown"), "\n")
    end

    -- not_proven. The standalone window headline ("Setup verification was
    -- incomplete.") and the Copy Summary line ("Verify only: setup
    -- verification was incomplete.") are worded for different contexts (one
    -- stands alone, the other continues "Verify only: ") and so are not
    -- byte-identical -- what must agree is the underlying STATE: both must
    -- read as incomplete/not_proven, and neither may carry a Repair
    -- recommendation.
    local verdictNotProven = { isCheckOnly = true, verifiedRuntimeOk = false, notProvenOnly = true, adjustedErrors = { "torch_runtime_probe_failed" } }
    local pNotProven = deriveLinuxFinalPresentation(false, true, verdictNotProven)
    local textNotProven = summaryText(false, true, verdictNotProven, ALL_OK_CHECKS)
    assertf(pNotProven.state == "not_proven", "expected presentation.state=not_proven")
    assertf(containsSubstring(textNotProven, "incomplete"), "Copy Summary text must also read as incomplete/not_proven:\n" .. textNotProven)
    assertf(not containsSubstring(textNotProven, "Run Repair"),
        "presentation.state=not_proven must agree with Copy Summary showing no Repair recommendation")

    -- failed
    local verdictFailed = { isCheckOnly = true, verifiedRuntimeOk = false, notProvenOnly = false, adjustedErrors = { "torch_too_new_for_demucs" } }
    local pFailed = deriveLinuxFinalPresentation(false, true, verdictFailed)
    local textFailed = summaryText(false, true, verdictFailed, ALL_OK_CHECKS)
    assertf(containsSubstring(textFailed, "one or more checks failed"), "Copy Summary must agree with presentation.state=failed:\n" .. textFailed)
    assertf(pFailed.state == "failed" and containsSubstring(textFailed, "Run Repair"),
        "presentation.state=failed must agree with Copy Summary's Repair recommendation")

    -- ok
    local verdictOk = { isCheckOnly = true, verifiedRuntimeOk = true, notProvenOnly = false, adjustedErrors = {} }
    local pOk = deriveLinuxFinalPresentation(true, true, verdictOk)
    local textOk = summaryText(true, true, verdictOk, ALL_OK_CHECKS)
    assertf(containsSubstring(textOk, "runtime checks passed"), "Copy Summary must agree with presentation.state=ok:\n" .. textOk)
    assertf(pOk.state == "ok", "expected presentation.state=ok")
end

-- =======================================================================
-- Live AMD repro target (section 12): backend=rocm, RX 9070, probe could
-- not be re-verified, no current runtime failure, cached July readiness
-- historical only. Confirms the full production path (reconcileCheckVerification
-- -> buildCheckOnlyVerdict -> deriveLinuxFinalPresentation) produces the
-- truthful not_proven presentation end-to-end, not just the already-fixed
-- Copy Summary text.
-- =======================================================================
local function testLiveAmdReproPresentation()
    local readyState = {
        READY_TO_GO_STATUS = "broken",
        READY_TO_GO_DETAIL = "target_free_space_insufficient",
        READY_TO_GO_LAST_CHECK_UTC = "2026-07-26T10:00:00Z",
    }
    local capState = { BACKEND = "rocm" }
    local state = {}
    local verification = { pythonOk = true, ffmpegOk = true, errors = { "torch_runtime_probe_failed" } }
    local checkProbe = reconcileCheckVerification(state, capState, readyState, verification, "", "AMD Radeon RX 9070", "rocm", "", "/nonexistent/bootstrap.log")
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "rocm", "", "", "AMD Radeon RX 9070", capState, state)
    assertf(verdict.notProvenOnly == true, "live AMD case must classify as not-proven-only")

    local allBasicChecksOk = true -- all 5 basic file/dir checks pass in the live repro
    local allOk = allBasicChecksOk and verdict.verifiedRuntimeOk
    local presentation = deriveLinuxFinalPresentation(allOk, allBasicChecksOk, verdict)

    assertf(presentation.state == "not_proven", "live AMD case must present as not_proven, got: " .. tostring(presentation.state))
    assertf(presentation.headline == "Setup verification was incomplete.", "unexpected live headline: " .. tostring(presentation.headline))
    assertf(presentation.runtimeState == "not_proven", "live AMD Runtime state must be not_proven, got: " .. tostring(presentation.runtimeState))
    assertf(presentation.overallState ~= "failed", "live AMD case must not render as the failed overall state")
    assertf(presentation.state ~= "failed", "live AMD case must not carry Repair implication")

    local rows = buildLinuxFinalRows(state, capState, { runtimeState = "/state" }, "/logs/bootstrap.log", allOk, verdict)
    local backendRow = findRow(rows, "Backend")
    assertf(backendRow ~= nil and backendRow.value == "rocm", "live Backend row must show the detected rocm backend")
    assertf(backendRow.kind ~= "status_fail", "live AMD Backend row must not render red -- this is the exact bug being closed")
    assertf(backendRow.kind == "note", "live AMD Backend row must use the neutral/warning kind, got: " .. tostring(backendRow.kind))
end

local tests = {
    { "a-not-proven", testA_NotProven },
    { "b-failed", testB_Failed },
    { "c-ok", testC_Ok },
    { "d-mixed-not-proven-plus-genuine-failure", testD_MixedNotProvenPlusGenuineFailure },
    { "e-copy-summary-consistency", testE_CopySummaryConsistency },
    { "live-amd-repro-presentation", testLiveAmdReproPresentation },
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

print("All headless Linux Setup final-presentation (ok/failed/not_proven) tests passed.")
