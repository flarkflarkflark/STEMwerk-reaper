-- Headless behavioral test for the macOS Intel DKS policy-removal slice:
-- resolveDrumsepPolicyState() (STEMwerk_Setup_Internal.lua) used to invent
-- drumsepStatus = "unsupported_mac_intel" purely from
-- OS == "macOS" and MAC_ARCH == "x86_64", whenever the cached ready_to_go
-- state was blank/incomplete -- independent of any real runtime/model
-- readiness evidence. That architecture-only synthesis is removed here:
-- a blank/incomplete state must now fall through to the same generic
-- ready/skipped/missing derivation used for every other platform.
--
-- Loads the REAL, unmodified STEMwerk_Setup_Internal.lua via dofile() (the
-- same convention as tests/support/run_setup_macos_ready_state_fallback_
-- headless.lua) with a stubbed `reaper` table, then calls the real
-- resolveDrumsepPolicyState() global it exposes.

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
assertf(type(resolveDrumsepPolicyState) == "function", "resolveDrumsepPolicyState was not exposed as a global function")

-- resolveDrumsepPolicyState() reads the bare global MAC_ARCH (never declared
-- local in this file); the real bootstrap/Lua runtime sets it elsewhere.
-- Setting it directly here is the correct headless equivalent.

local function testX86_64BlankStateIsMissingNotUnsupported()
    MAC_ARCH = "x86_64"
    -- This exact fixture (DRUMSEP_STATUS absent, runtime/model reported
    -- "skipped", READY_TO_GO_DETAIL "unsupported_mac_intel") is what the
    -- OLD, blanket-blocked bootstrap actually wrote for every Intel run --
    -- and what used to make resolveDrumsepPolicyState() invent
    -- drumsepStatus = "unsupported_mac_intel" from architecture alone. The
    -- fixed bootstrap no longer produces "skipped"/"unsupported_mac_intel"
    -- for Intel, but this fallback function's OWN contract must independently
    -- no longer synthesize that verdict from MAC_ARCH == x86_64 either, in
    -- case an incomplete/legacy-shaped state is ever read again.
    local readyState = {
        DRUMSEP_READY_RUNTIME_STATUS = "skipped",
        DRUMSEP_READY_MODEL_STATUS = "skipped",
        READY_TO_GO_DETAIL = "unsupported_mac_intel",
    }
    local drumsepStatus, dksSupported, normalStemsSupported = resolveDrumsepPolicyState(readyState, "mac-cpu", "cpu")
    assertf(drumsepStatus == "skipped",
        "this state must no longer be architecture-only-synthesized into 'unsupported_mac_intel' -- it must fall through to the same generic 'skipped' derivation every other platform gets -- got " .. tostring(drumsepStatus))
    assertf(dksSupported == "true",
        "platform support (DKS_SUPPORTED) must no longer be false purely because MAC_ARCH == x86_64 -- got " .. tostring(dksSupported))
end

local function testX86_64RealReadinessProducesReady()
    MAC_ARCH = "x86_64"
    local readyState = {
        DRUMSEP_READY_RUNTIME_STATUS = "ok",
        DRUMSEP_READY_MODEL_STATUS = "ok",
        MAIN_RUNTIME_STATUS = "ok",
    }
    local drumsepStatus, dksSupported, normalStemsSupported = resolveDrumsepPolicyState(readyState, "mac-cpu", "cpu")
    assertf(drumsepStatus == "ready",
        "real Intel CPU DrumSep readiness (runtime=ok, model=ok) must resolve to 'ready', not be blocked by architecture -- got " .. tostring(drumsepStatus))
    assertf(dksSupported == "true", "expected dksSupported=true, got " .. tostring(dksSupported))
end

local function testX86_64GenuinePreflightFailureStaysMissing()
    MAC_ARCH = "x86_64"
    local readyState = {
        DRUMSEP_READY_RUNTIME_STATUS = "missing",
        DRUMSEP_READY_MODEL_STATUS = "missing",
        MAIN_RUNTIME_STATUS = "ok",
    }
    local drumsepStatus, dksSupported = resolveDrumsepPolicyState(readyState, "mac-cpu", "cpu")
    assertf(drumsepStatus == "missing",
        "a genuine real-world preflight/model-download failure must still resolve to 'missing', never fabricated into 'ready' -- got " .. tostring(drumsepStatus))
    -- Platform support and current readiness are distinct: DKS is still
    -- SUPPORTED on this architecture even though it is not currently ready.
    assertf(dksSupported == "true", "expected dksSupported=true (platform supported, just not ready yet), got " .. tostring(dksSupported))
end

local function testX86_64StaleLiteralUnsupportedValueStillHonored()
    MAC_ARCH = "x86_64"
    -- Backward compatibility: a stale pre-fix ready_to_go.env still on disk
    -- may literally contain DRUMSEP_STATUS=unsupported_mac_intel. That
    -- explicit, already-present value is passed through as-is (it is not
    -- invented by this function), and still maps to dksSupported=false.
    local readyState = { DRUMSEP_STATUS = "unsupported_mac_intel" }
    local drumsepStatus, dksSupported = resolveDrumsepPolicyState(readyState, "mac-cpu", "cpu")
    assertf(drumsepStatus == "unsupported_mac_intel", "an explicit stale DRUMSEP_STATUS value must be preserved as-is, got " .. tostring(drumsepStatus))
    assertf(dksSupported == "false", "expected dksSupported=false for the stale literal value, got " .. tostring(dksSupported))
end

local function testArm64ParityUnaffected()
    MAC_ARCH = "arm64"
    local blankStatus = resolveDrumsepPolicyState({}, "mac-mps", "mps")
    assertf(blankStatus == "missing", "arm64 blank-state behavior must be unchanged (missing), got " .. tostring(blankStatus))
    local readyState = {
        DRUMSEP_READY_RUNTIME_STATUS = "ok",
        DRUMSEP_READY_MODEL_STATUS = "ok",
    }
    local readyStatus, dksSupported = resolveDrumsepPolicyState(readyState, "mac-mps", "mps")
    assertf(readyStatus == "ready", "arm64 real-readiness behavior must be unchanged (ready), got " .. tostring(readyStatus))
    assertf(dksSupported == "true", "arm64 dksSupported must remain true, got " .. tostring(dksSupported))
end

local tests = {
    { "x86_64-blank-state-is-missing-not-unsupported", testX86_64BlankStateIsMissingNotUnsupported },
    { "x86_64-real-readiness-produces-ready", testX86_64RealReadinessProducesReady },
    { "x86_64-genuine-preflight-failure-stays-missing", testX86_64GenuinePreflightFailureStaysMissing },
    { "x86_64-stale-literal-unsupported-value-still-honored", testX86_64StaleLiteralUnsupportedValueStillHonored },
    { "arm64-parity-unaffected", testArm64ParityUnaffected },
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

print("All headless Intel DKS policy-removal tests passed.")
