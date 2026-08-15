-- Headless behavioral test for fixture L (task spec section 15): the macOS
-- "shared cached fallback" in reconcileCheckVerification
-- (STEMwerk_Setup_Internal.lua) must not let a cached ready_to_go.env/
-- capabilities.env "healthy" reading silently override a genuinely current
-- Torch probe failure without at least disclosing that cached state was
-- used. This must run on the real macOS-specific code path
-- (canAcceptMacReadyHealthyState requires OS == "macOS"), which the main
-- tests/support/run_setup_final_rows_headless.lua cannot reach because it
-- loads the script once with OS resolved to "Linux" -- OS is a module-level
-- local computed once at load time, so a second, separate dofile() with a
-- different reaper.GetOS() stub is required to exercise this branch at all.

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
    GetOS = function() return "OSX64" end,
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
assertf(ok, "failed to load " .. TARGET .. " in headless macOS test mode: " .. tostring(err))
assertf(type(reconcileCheckVerification) == "function", "reconcileCheckVerification was not exposed as a global function")

local function containsSubstring(text, needle)
    return tostring(text or ""):find(needle, 1, true) ~= nil
end

-- Fixture L, part 1 (revised for the 2.3.1.0 "keep current failures
-- authoritative" follow-up): cached RTG/capabilities look fully healthy, but
-- the CURRENT Torch probe reports torch_runtime_probe_failed. Without any
-- same-invocation identity linking the cached ready_to_go/capabilities
-- snapshot to this specific current probe, cached "healthy" evidence may
-- never remove, suppress, downgrade, or overwrite that current negative
-- result -- it may only be disclosed as historical/cached provenance
-- alongside the still-failed verdict.
--
-- The previous version of this test asserted the OPPOSITE: that the cached
-- fallback was allowed to waive torch_runtime_probe_failed as long as the
-- waiver was "disclosed" via usedCachedReadyStateFallback. That was wrong --
-- disclosure does not make a false current success truthful. This is the
-- adversarial-review fixture that closes that bypass.
local function testMacCachedFallbackDisclosesItsUse()
    local readyState = {
        READY_TO_GO_STATUS = "ok",
        MAIN_RUNTIME_STATUS = "ok",
        READY_TO_GO_LAST_CHECK_UTC = "2026-08-01T00:00:00Z",
    }
    local capState = {
        AUDIO_SEPARATOR = "ok",
        STEMWERK_CORE = "ok",
        BOOTSTRAP_STATUS = "ok",
        VERIFICATION = "ok",
        STATUS = "ok",
    }
    local state = { STATUS = "ok" }
    local verification = {
        pythonOk = true,
        ffmpegOk = true,
        errors = { "torch_runtime_probe_failed" },
        torchVersion = "2.10.0",
        torchaudioVersion = "2.10.0",
    }
    local result = reconcileCheckVerification(state, capState, readyState, verification, "", "", "cpu", "", "/nonexistent/bootstrap.log")

    -- The current negative probe result must survive intact: no success
    -- headline/current-ready verdict, and the exact current reason preserved.
    assertf(result.verifiedRuntimeOk == false,
        "a current torch_runtime_probe_failed must remain a failure even when cached ready_to_go/capabilities look healthy")
    local hasError = false
    for _, e in ipairs(result.adjustedErrors) do
        if e == "torch_runtime_probe_failed" then hasError = true end
    end
    assertf(hasError, "torch_runtime_probe_failed must remain in adjustedErrors -- it must not be waived by cached healthy state")
    assertf(result.runtimeVerifyDetail ~= "ok" and result.runtimeVerifyDetail ~= "not_checked",
        "runtimeVerifyDetail must preserve the exact current failure reason, not be hidden behind ok/not_checked: got " .. tostring(result.runtimeVerifyDetail))

    -- Cached healthy state may still be disclosed as cached/historical
    -- provenance -- that disclosure alone must never flip the verdict above.
    assertf(result.usedCachedReadyStateFallback == true,
        "cached ready_to_go/capabilities healthy state may still be disclosed as provenance")

    local checkProbe = {
        verifiedRuntimeOk = result.verifiedRuntimeOk,
        adjustedErrors = result.adjustedErrors,
        usedCachedReadyStateFallback = result.usedCachedReadyStateFallback,
    }
    local verdict = buildCheckOnlyVerdict(verification, checkProbe, "cpu", "", "", "", capState, state)
    assertf(verdict.verifiedRuntimeOk == false,
        "the resolved Check-only verdict must not show a success headline/current-ready verdict for a current torch probe failure")
end

-- Fixture L, part 2: cached state looks healthy, but the current probe has a
-- HARD failure unrelated to the narrow Torch-probe-inconclusive case (e.g.
-- audio_separator itself is missing right now). The cached fallback's own
-- guard (not hasHardImportFailures) must not fire, and the current failure
-- must remain a failure -- cached healthy state must never manufacture
-- success out of an unrelated current hard failure.
local function testMacCachedStateCannotOverrideHardCurrentFailure()
    local readyState = {
        READY_TO_GO_STATUS = "ok",
        MAIN_RUNTIME_STATUS = "ok",
        READY_TO_GO_LAST_CHECK_UTC = "2026-08-01T00:00:00Z",
    }
    local capState = {
        AUDIO_SEPARATOR = "ok",
        STEMWERK_CORE = "ok",
        BOOTSTRAP_STATUS = "ok",
        VERIFICATION = "ok",
        STATUS = "ok",
    }
    local state = { STATUS = "ok" }
    local verification = {
        pythonOk = true,
        ffmpegOk = true,
        errors = { "audio_separator_missing" },
    }
    local result = reconcileCheckVerification(state, capState, readyState, verification, "", "", "cpu", "", "/nonexistent/bootstrap.log")
    assertf(result.verifiedRuntimeOk == false,
        "cached healthy ready_to_go/capabilities state must never override a current hard import failure")
    local hasError = false
    for _, e in ipairs(result.adjustedErrors) do
        if e == "audio_separator_missing" then hasError = true end
    end
    assertf(hasError, "the real current failure (audio_separator_missing) must remain in adjustedErrors")
end

local tests = {
    { "mac-cached-fallback-discloses-its-use", testMacCachedFallbackDisclosesItsUse },
    { "mac-cached-state-cannot-override-hard-current-failure", testMacCachedStateCannotOverrideHardCurrentFailure },
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

print("All headless macOS ready-state fallback tests passed.")
