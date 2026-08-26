-- test_project_context.lua
-- Regression tests for GitHub issue #91: origin-project capture/validation
-- (scripts/reaper/_internal/STEMwerk_Project_Context.lua).
--
-- Pure Lua harness against the real module via a mocked `reaper` API table
-- (no gfx/dofile of the full STEMwerk.lua main chunk -- that file drives a
-- REAPER GUI loop and has no headless harness in this repo). Run with:
--   lua tests/lua/test_project_context.lua

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
-- Mock REAPER: projects are plain tables (each one is a distinct ReaProject*
-- identity, exactly like REAPER's own userdata equality semantics). Items
-- and tracks are plain tables too, registered against a project+kind so
-- ValidatePtr2 can approve/reject them.
-- ---------------------------------------------------------------------------
local function makeReaperMock(openProjects, activeProject)
    local open = {}
    for i, p in ipairs(openProjects) do open[i] = p end
    local active = activeProject or open[1]
    local validPtrs = {} -- ptr -> { project = proj, kind = kind }
    local selectCalls = {}

    local api = {}
    api.EnumProjects = function(idx)
        if idx == -1 then return active end
        return open[idx + 1]
    end
    api.SelectProjectInstance = function(proj)
        active = proj
        selectCalls[#selectCalls + 1] = proj
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

    local function registerPtr(ptr, proj, kind)
        validPtrs[ptr] = { project = proj, kind = kind }
    end
    local function closeProject(proj)
        for i = #open, 1, -1 do
            if open[i] == proj then table.remove(open, i) end
        end
        if active == proj then active = open[1] end
    end
    local function currentActive()
        return active
    end

    return api, registerPtr, closeProject, currentActive, selectCalls
end

-- ---------------------------------------------------------------------------
-- M.capture
-- ---------------------------------------------------------------------------
do
    local projA = { name = "SongA", path = "/proj/a.rpp" }
    local projB = { name = "SongB", path = "/proj/b.rpp" }
    local reaper, registerPtr = makeReaperMock({ projA, projB }, projA)
    local item = {}
    registerPtr(item, projA, "MediaItem*")

    local captured = PROJECT_CONTEXT.capture(reaper, item, nil)
    check("capture: ref is the active project at capture time", captured.ref == projA)
    check("capture: valid anchor item retained", #captured.anchors == 1 and captured.anchors[1].ptr == item)
    check("capture: display_name populated", captured.display_name == "SongA")
    check("capture: display_path populated", captured.display_path == "/proj/a.rpp")

    -- An item that does not validate against the active project must not be
    -- captured as an anchor (do not invent an anchor that isn't real).
    local foreignItem = {}
    registerPtr(foreignItem, projB, "MediaItem*")
    local captured2 = PROJECT_CONTEXT.capture(reaper, foreignItem, nil)
    check("capture: foreign-project item is not retained as an anchor", #captured2.anchors == 0)

    -- No anchor available at all (e.g. pure time-selection run): capture
    -- must still succeed with an empty anchor list, not fail.
    local captured3 = PROJECT_CONTEXT.capture(reaper, nil, nil)
    check("capture: nil anchor item yields empty anchors, not an error", type(captured3.anchors) == "table" and #captured3.anchors == 0)
    check("capture: nil anchor item still captures ref", captured3.ref == projA)

    -- Selected-track anchors.
    local trackX = {}
    registerPtr(trackX, projA, "MediaTrack*")
    local captured4 = PROJECT_CONTEXT.capture(reaper, nil, { trackX })
    check("capture: selected-track anchor retained", #captured4.anchors == 1 and captured4.anchors[1].kind == "MediaTrack*")
end

-- ---------------------------------------------------------------------------
-- M.isProjectStillOpen
-- ---------------------------------------------------------------------------
do
    local projA = { name = "A" }
    local projB = { name = "B" }
    local projC = { name = "C" }
    local reaper, _, closeProject = makeReaperMock({ projA, projB, projC }, projA)

    check("isProjectStillOpen: true while still open", PROJECT_CONTEXT.isProjectStillOpen(reaper, projA))

    -- Scenario B: user opens/reorders other tabs -- membership must survive
    -- reordering (index changes, identity does not).
    local reaper2, _, _, _ = makeReaperMock({ projC, projA, projB }, projC)
    check("isProjectStillOpen: survives tab reordering", PROJECT_CONTEXT.isProjectStillOpen(reaper2, projA))

    -- Scenario C: origin closed before completion.
    closeProject(projA)
    check("isProjectStillOpen: false once closed", not PROJECT_CONTEXT.isProjectStillOpen(reaper, projA))

    check("isProjectStillOpen: nil ref is never open", not PROJECT_CONTEXT.isProjectStillOpen(reaper, nil))
end

-- ---------------------------------------------------------------------------
-- M.validateOriginProjectContext
-- ---------------------------------------------------------------------------
do
    -- Scenario E: renamed/saved during processing -- same live handle (same
    -- table identity) must still validate, even though display fields on
    -- the captured snapshot are now stale (display-only, never re-read).
    local projA = { name = "Untitled1" }
    local reaper = makeReaperMock({ projA }, projA)
    local runCtx = { project = { ref = projA, anchors = {} } }
    projA.name = "MySong (renamed and saved)" -- mutate in place, same identity
    local ok, reason = PROJECT_CONTEXT.validateOriginProjectContext(reaper, runCtx)
    check("validateOriginProjectContext: rename/save keeps same instance valid", ok == true and reason == "ok")

    -- Scenario D: closed and the same file reopened as a NEW project
    -- instance (a distinct table even though it represents the same path).
    local projAReopened = { name = "MySong (renamed and saved)" }
    local reaper2 = makeReaperMock({ projAReopened }, projAReopened)
    local ok2, reason2 = PROJECT_CONTEXT.validateOriginProjectContext(reaper2, runCtx)
    check("validateOriginProjectContext: reopened-by-path instance is NOT the original", ok2 == false and reason2 == "project_closed")

    -- Scenario C: origin closed, no import into whatever else is open.
    local projB = { name = "B" }
    local reaper3 = makeReaperMock({ projB }, projB)
    local ok3, reason3 = PROJECT_CONTEXT.validateOriginProjectContext(reaper3, runCtx)
    check("validateOriginProjectContext: origin closed => fail closed", ok3 == false and reason3 == "project_closed")

    -- No captured project at all (never captured / defensive nil) must fail
    -- closed, never fall back to the active project.
    local ok4, reason4 = PROJECT_CONTEXT.validateOriginProjectContext(reaper3, { project = { ref = nil, anchors = {} } })
    check("validateOriginProjectContext: missing ref => fail closed", ok4 == false and reason4 == "project_ref_missing")
    local ok5, reason5 = PROJECT_CONTEXT.validateOriginProjectContext(reaper3, nil)
    check("validateOriginProjectContext: nil runContext => fail closed", ok5 == false and reason5 == "project_ref_missing")

    -- Scenario J: project handle still open, but the captured anchor no
    -- longer validates (e.g. the source item was deleted). Must fail
    -- closed even though the project itself is provably still open.
    local projD = { name = "D" }
    local reaperD, registerPtrD = makeReaperMock({ projD }, projD)
    local liveItem = {}
    registerPtrD(liveItem, projD, "MediaItem*")
    local runCtxD = { project = { ref = projD, anchors = { { ptr = liveItem, kind = "MediaItem*" } } } }
    local okD1, reasonD1 = PROJECT_CONTEXT.validateOriginProjectContext(reaperD, runCtxD)
    check("validateOriginProjectContext: live project + live anchor => ok", okD1 == true and reasonD1 == "ok")
    -- Now the anchor stops validating (item deleted) without the project closing.
    local reaperD2 = makeReaperMock({ projD }, projD) -- fresh mock: nothing registered => ValidatePtr2 always false
    local okD2, reasonD2 = PROJECT_CONTEXT.validateOriginProjectContext(reaperD2, runCtxD)
    check("validateOriginProjectContext: project open but anchor invalid => fail closed", okD2 == false and reasonD2 == "anchor_invalid")

    -- No anchors captured at all (legitimate for some workflows): handle
    -- membership alone must be sufficient and authoritative.
    local runCtxNoAnchor = { project = { ref = projD, anchors = {} } }
    local okD3, reasonD3 = PROJECT_CONTEXT.validateOriginProjectContext(reaperD, runCtxNoAnchor)
    check("validateOriginProjectContext: no anchors captured => membership alone is sufficient", okD3 == true and reasonD3 == "ok")

    -- Scenario F: two concurrent runs, each with its own origin project,
    -- validate completely independently of one another.
    local runA = { name = "RunA-origin" }
    local runB = { name = "RunB-origin" }
    local reaperConcurrent = makeReaperMock({ runA, runB }, runA)
    local ctxR1 = { project = { ref = runA, anchors = {} } }
    local ctxR2 = { project = { ref = runB, anchors = {} } }
    local okR1 = PROJECT_CONTEXT.validateOriginProjectContext(reaperConcurrent, ctxR1)
    local okR2 = PROJECT_CONTEXT.validateOriginProjectContext(reaperConcurrent, ctxR2)
    check("validateOriginProjectContext: concurrent run R1 validates against A", okR1 == true)
    check("validateOriginProjectContext: concurrent run R2 validates against B independently", okR2 == true)
end

-- ---------------------------------------------------------------------------
-- M.withProjectInstance / M.restoreProjectInstance
-- ---------------------------------------------------------------------------
do
    -- Scenario A: origin A, active B at completion -> import runs scoped to
    -- A, then B is restored.
    local projA = { name = "A" }
    local projB = { name = "B" }
    local reaper, _, _, currentActive = makeReaperMock({ projA, projB }, projB)

    local sawActiveDuringFn = nil
    local ok, result = PROJECT_CONTEXT.withProjectInstance(reaper, projA, function()
        sawActiveDuringFn = currentActive()
        return "import-ok"
    end)
    check("withProjectInstance: fn runs with A selected", sawActiveDuringFn == projA)
    check("withProjectInstance: returns fn's result on success", ok == true and result == "import-ok")
    check("withProjectInstance: previously-active B is restored afterward", currentActive() == projB)

    -- Scenario G: import throws while temporarily in A -> B still restored,
    -- and the error is surfaced rather than silently swallowed.
    local reaper2, _, _, currentActive2 = makeReaperMock({ projA, projB }, projB)
    local ok2, err2 = PROJECT_CONTEXT.withProjectInstance(reaper2, projA, function()
        error("boom: import raised")
    end)
    check("withProjectInstance: pcall failure is reported (ok=false)", ok2 == false)
    check("withProjectInstance: error message surfaced", tostring(err2):find("boom", 1, true) ~= nil)
    check("withProjectInstance: B restored even though fn raised", currentActive2() == projB)

    -- If the previously-active project closes during the scoped window,
    -- restoration must be skipped (never fall back to an arbitrary project).
    local projC = { name = "C" }
    local reaper3, _, closeProject3, currentActive3 = makeReaperMock({ projA, projB, projC }, projB)
    local ok3 = PROJECT_CONTEXT.withProjectInstance(reaper3, projA, function()
        closeProject3(projB) -- B closes mid-import
        return true
    end)
    check("withProjectInstance: fn success still reported when previous project later closes", ok3 == true)
    check("withProjectInstance: closed previous project is not restored; A stays selected", currentActive3() == projA)

    -- restoreProjectInstance in isolation.
    local reaper4, _, _, currentActive4 = makeReaperMock({ projA, projB }, projA)
    local restored = PROJECT_CONTEXT.restoreProjectInstance(reaper4, projB)
    check("restoreProjectInstance: restores an open previous project", restored == true and currentActive4() == projB)
    local reaper5, _, closeProject5, currentActive5 = makeReaperMock({ projA, projB }, projA)
    closeProject5(projB)
    local restored2 = PROJECT_CONTEXT.restoreProjectInstance(reaper5, projB)
    check("restoreProjectInstance: refuses to restore a closed project", restored2 == false and currentActive5() == projA)
end

if failures > 0 then
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
print("RESULT: all tests passed")
