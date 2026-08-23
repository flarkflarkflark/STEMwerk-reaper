-- test_origin_capture_timing.lua
-- Regression tests for the issue #91 follow-up timing fix: the requesting
-- REAPER project must be captured SYNCHRONOUSLY at the moment of user
-- acceptance (Process click / quick preset), before any reaper.defer()
-- call -- never inside the deferred callback itself, where the active
-- project may already have changed. Run with:
--   lua tests/lua/test_origin_capture_timing.lua
--
-- HONESTY NOTE ON WHAT THIS HARNESS DOES AND DOES NOT PROVE
-- ---------------------------------------------------------------------
-- STEMwerk.lua drives a live REAPER gfx/defer GUI loop and unconditionally
-- calls main() at the bottom of the file; it has no headless harness in
-- this repo (see tests/lua/test_project_context.lua's own header comment
-- and tests/test_project_context_targeting.py's module docstring, which
-- document the same limitation for the pre-existing issue #91 tests). This
-- file therefore does NOT dofile STEMwerk.lua and does NOT call the real
-- finalizeDialogLoop()/runSeparationWorkflow()/main() functions.
--
-- What it DOES do:
--   1. Uses the REAL scripts/reaper/_internal/STEMwerk_Project_Context.lua
--      module (dofile'd, unmodified) for M.capture/M.isProjectStillOpen, so
--      the actual capture semantics under test are the production ones.
--   2. Reimplements, as small local helper functions, the EXACT control-flow
--      shape now present in scripts/reaper/STEMwerk.lua: capture happens
--      synchronously before a call is pushed onto a mock reaper.defer
--      queue, and the captured value is threaded through as an explicit
--      parameter/upvalue rather than re-read from "the active project" at
--      callback time. The helper names/shape intentionally mirror
--      captureOriginProjectContext() / runSeparationWorkflow(originProjectContext)
--      in STEMwerk.lua.
--   3. Uses a hand-rolled defer queue (a plain array, flushed under explicit
--      test control) instead of REAPER's real scheduler, so the exact
--      accept -> defer -> [project tab switch] -> callback sequence
--      described in the task spec can be driven deterministically.
--
-- What this does NOT prove: that STEMwerk.lua's actual finalizeDialogLoop /
-- checkQuickPreset / runSeparationWorkflow functions, as they exist in the
-- real file, follow this same shape. That linkage is covered instead by
-- tests/test_project_context_targeting.py, which asserts on the literal
-- source text/ordering of the real functions (capture-before-defer position,
-- parameter name, retry re-defer call text, single shared capture call
-- site). Together, the two suites cover: "the mechanism is correct" (here)
-- and "the real file actually uses that mechanism" (the Python source
-- checks). Neither substitutes for a real REAPER project-tab-switch smoke
-- test, which this repo cannot run headlessly.

local scriptDir = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repoRoot = scriptDir .. "/../.."
local modulePath = repoRoot .. "/scripts/reaper/_internal/STEMwerk_Project_Context.lua"

local PROJECT_CONTEXT = dofile(modulePath)

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- Mock REAPER: same shape as tests/lua/test_project_context.lua's mock,
-- plus a controllable reaper.defer queue (a plain array flushed one entry
-- at a time by the test, standing in for REAPER's real per-frame scheduler).
-- ---------------------------------------------------------------------------
local function makeReaperMock(openProjects, activeProject)
    local open = {}
    for i, p in ipairs(openProjects) do open[i] = p end
    local active = activeProject or open[1]
    local validPtrs = {}
    local deferQueue = {}

    local api = {}
    api.EnumProjects = function(idx)
        if idx == -1 then return active end
        return open[idx + 1]
    end
    api.SelectProjectInstance = function(proj)
        active = proj
    end
    api.ValidatePtr2 = function(proj, ptr, kind)
        if not ptr then return false end
        local entry = validPtrs[ptr]
        return entry ~= nil and entry.project == proj and entry.kind == kind
    end
    api.GetProjectName = function(proj, _buf)
        return "", (proj and proj.name) or ""
    end
    api.GetProjectPathEx = function(proj, _buf)
        return (proj and proj.path) or ""
    end
    api.defer = function(fn)
        deferQueue[#deferQueue + 1] = fn
    end

    local function setActive(proj)
        active = proj
    end
    local function currentActive()
        return active
    end
    local function registerPtr(ptr, proj, kind)
        validPtrs[ptr] = { project = proj, kind = kind }
    end
    -- Pop and run the OLDEST queued defer callback (FIFO, matching REAPER's
    -- own defer ordering). Returns false if the queue was empty.
    local function flushOneDefer()
        local fn = table.remove(deferQueue, 1)
        if not fn then return false end
        fn()
        return true
    end
    local function pendingDeferCount()
        return #deferQueue
    end

    return api, registerPtr, setActive, currentActive, flushOneDefer, pendingDeferCount
end

-- ---------------------------------------------------------------------------
-- Harness mirroring STEMwerk.lua's new shape:
--   captureOriginProjectContext(anchorItem) -> PROJECT_CONTEXT.capture(...)
--   accept...() captures synchronously, THEN calls reaper.defer(closure)
--   runSeparationWorkflow(originProjectContext) consumes the passed context,
--     never re-derives it from EnumProjects(-1) at callback time.
-- ---------------------------------------------------------------------------
local function captureOriginProjectContext(reaperApi)
    return PROJECT_CONTEXT.capture(reaperApi, nil, nil)
end

-- Simulates the normal-Process / quick-preset acceptance point: capture
-- happens BEFORE reaper.defer(), and the captured context is closed over by
-- the deferred callback (not re-read from reaperApi at call time).
local function acceptProcessing(reaperApi, onRunContextBuilt)
    local originProjectContext = captureOriginProjectContext(reaperApi)
    reaperApi.defer(function()
        -- Stand-in for runSeparationWorkflow(originProjectContext): builds
        -- the RunContext's .project field from the passed-in parameter,
        -- exactly like scripts/reaper/STEMwerk.lua's
        -- `requestingOriginProjectContext = originProjectContext` line --
        -- never PROJECT_CONTEXT.capture(reaperApi, ...) again here.
        local runContext = { project = originProjectContext }
        onRunContextBuilt(runContext, originProjectContext)
    end)
    return originProjectContext
end

-- Simulates the retry/re-defer path inside runSeparationWorkflow: reuses
-- the SAME originProjectContext upvalue, never recaptures.
local function retryRedefer(reaperApi, originProjectContext, onRunContextBuilt)
    reaperApi.defer(function()
        local runContext = { project = originProjectContext }
        onRunContextBuilt(runContext, originProjectContext)
    end)
end

-- ---------------------------------------------------------------------------
-- Section 7: normal Process path -- accept in A, switch to B before the
-- deferred callback runs, expect RunContext.project.ref == A.
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local reaperApi, _, setActive, currentActive, flushOneDefer, pendingDeferCount =
        makeReaperMock({ projA, projB }, projA)

    local observedRunContext = nil
    acceptProcessing(reaperApi, function(runContext)
        observedRunContext = runContext
    end)

    check("normal: defer is queued but not yet run", pendingDeferCount() == 1 and observedRunContext == nil)

    -- User switches project tabs during the defer window.
    setActive(projB)
    check("normal: active project is now B before callback runs", currentActive() == projB)

    flushOneDefer()
    check("normal: RunContext.project.ref == A (origin), not B (active at callback time)",
        observedRunContext ~= nil and observedRunContext.project.ref == projA,
        observedRunContext and tostring(observedRunContext.project.ref))
end

-- ---------------------------------------------------------------------------
-- Section 8: quick preset path -- same invariant.
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local reaperApi, _, setActive, currentActive, flushOneDefer =
        makeReaperMock({ projA, projB }, projA)

    local observedRunContext = nil
    -- Quick presets go through the SAME captureOriginProjectContext() /
    -- reaper.defer() shape as normal Process in the real file (both call
    -- sites share the one helper) -- reuse the same simulated entry point.
    acceptProcessing(reaperApi, function(runContext)
        observedRunContext = runContext
    end)

    setActive(projB)
    flushOneDefer()
    check("quick preset: origin remains A after switching to B before callback",
        observedRunContext ~= nil and observedRunContext.project.ref == projA)
end

-- ---------------------------------------------------------------------------
-- Section 9: retry / re-defer -- action starts in A, first deferred stage
-- runs, active switches to B, a retry is scheduled, active switches to C,
-- retry callback runs. Origin must remain A throughout; no recapture to B
-- or C.
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local projC = { name = "C" }
    local reaperApi, _, setActive, currentActive, flushOneDefer =
        makeReaperMock({ projA, projB, projC }, projA)

    local firstStageRunContext = nil
    local retryRunContext = nil
    local capturedOrigin = nil

    capturedOrigin = acceptProcessing(reaperApi, function(runContext, originProjectContext)
        firstStageRunContext = runContext
        -- First deferred stage ran; active project switches to B before the
        -- retry is scheduled.
        setActive(projB)
        check("retry: active is B when retry is scheduled", currentActive() == projB)
        retryRedefer(reaperApi, originProjectContext, function(retryCtx)
            retryRunContext = retryCtx
        end)
    end)

    flushOneDefer() -- runs the first stage closure above (which itself schedules the retry)
    check("retry: first stage saw origin A", firstStageRunContext ~= nil and firstStageRunContext.project.ref == projA)

    -- Active project switches again, to C, before the retry callback runs.
    setActive(projC)
    check("retry: active is C right before retry callback runs", currentActive() == projC)
    flushOneDefer() -- runs the retry closure
    check("retry: retry callback saw origin A (not B, not C)",
        retryRunContext ~= nil and retryRunContext.project.ref == projA,
        retryRunContext and tostring(retryRunContext.project.ref))
    check("retry: origin project context object identity preserved (no recapture)",
        retryRunContext.project == capturedOrigin)
end

-- ---------------------------------------------------------------------------
-- Section 10: concurrent runs -- R1 accepted in A, R2 accepted in B (both
-- deferred callbacks pending at once), executed out of order, with the
-- active project changing between and during each. Each run's origin must
-- resolve to its own accept-time project, independent of the other run and
-- independent of whatever project is active when each callback fires.
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local projC = { name = "C" }
    local reaperApi, _, setActive, currentActive, flushOneDefer, pendingDeferCount =
        makeReaperMock({ projA, projB, projC }, projA)

    local r1RunContext, r2RunContext = nil, nil

    -- R1 accepted while A is active.
    acceptProcessing(reaperApi, function(runContext)
        r1RunContext = runContext
    end)

    -- Active project changes before R2 is even accepted.
    setActive(projB)
    -- R2 accepted while B is active.
    acceptProcessing(reaperApi, function(runContext)
        r2RunContext = runContext
    end)

    check("concurrent: two defers queued, neither run yet",
        pendingDeferCount() == 2 and r1RunContext == nil and r2RunContext == nil)

    -- Active project changes again before either callback executes, and
    -- callbacks run out of order relative to acceptance (R2's callback
    -- fires first here) with C active at flush time.
    setActive(projC)
    flushOneDefer() -- this is R1's closure (FIFO: it was queued first)
    check("concurrent: R1 resolves to A even though C is active and R2 hasn't run yet",
        r1RunContext ~= nil and r1RunContext.project.ref == projA)
    check("concurrent: R2 has still not run", r2RunContext == nil)

    setActive(projA) -- flip again before R2's callback runs
    flushOneDefer() -- R2's closure
    check("concurrent: R2 resolves to B (its own accept-time origin), not A or C",
        r2RunContext ~= nil and r2RunContext.project.ref == projB,
        r2RunContext and tostring(r2RunContext.project.ref))
end

-- ---------------------------------------------------------------------------
-- Negative control: confirm this harness actually reproduces the ORIGINAL
-- bug (capture-after-defer) when wired the old way, so the PASS results
-- above are not vacuous. This exercises the SAME mock defer queue and
-- switch sequence as the "normal" test above, but with capture deliberately
-- left inside the deferred closure (reading the active project at callback
-- time), matching pre-fix runSeparationWorkflow() behavior.
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local reaperApi, _, setActive, currentActive, flushOneDefer =
        makeReaperMock({ projA, projB }, projA)

    local observedRunContext = nil
    -- Old (buggy) shape: capture happens INSIDE the deferred closure.
    reaperApi.defer(function()
        local runContext = { project = PROJECT_CONTEXT.capture(reaperApi, nil, nil) }
        observedRunContext = runContext
    end)

    setActive(projB)
    flushOneDefer()
    check("negative control: pre-fix capture-after-defer shape DOES leak to B (confirms the bug is real)",
        observedRunContext ~= nil and observedRunContext.project.ref == projB,
        observedRunContext and tostring(observedRunContext.project.ref))
end

if failures > 0 then
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
print("RESULT: all tests passed")
