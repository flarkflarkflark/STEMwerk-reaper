-- STEMwerk_Project_Context.lua
-- Issue #91: origin-project capture/validation for import targeting.
--
-- When a separation run is started from REAPER project A and the user
-- switches to project B/C while it is still processing, completed stems must
-- be imported back into A -- never into whatever project happens to be
-- active when the run finishes. This module captures the requesting
-- ReaProject* once (see M.capture), validates it is still live immediately
-- before any import/mutation (M.validateOriginProjectContext), and provides
-- a minimal scoped select/run/restore wrapper (M.withProjectInstance) so the
-- existing import code (which implicitly operates on "the active project")
-- does not need to be rewritten to explicit-project REAPER API variants.
--
-- This is entirely separate from run_id/job_id diagnostics identity
-- (STEMwerk_Log.lua RunContext authority) -- that module/contract is not
-- touched or reopened here. run_id/job_id keep meaning "which worker
-- run/job produced this evidence"; ReaProject* here only ever means "which
-- REAPER project should receive the import". The two may live on the same
-- per-run RunContext table, but neither drives the other.
--
-- The ReaProject* pointer captured here is a same-live-REAPER-session
-- handle only. It is never serialized, never written to disk, never passed
-- to the Python worker, and never used after a REAPER restart.
--
-- Every function here takes the `reaper` API table as an explicit first
-- argument (dependency injection) rather than reading a global, so this
-- module can be unit-tested with a small mocked reaper table and a plain
-- Lua interpreter, with no gfx/io/REAPER-host dependency.

local M = {}

-- Capture the REAPER project that is requesting this processing action,
-- plus a small set of best-effort validation anchors. Must be called
-- exactly once per accepted processing action (Process click / quick
-- preset), before any async work is launched -- never re-captured in a
-- progress loop, completion callback, or import function.
--
-- anchorItem: a MediaItem* already known to belong to the requesting
--   selection (e.g. the workflow's selectedItem/sourceItem), or nil.
-- anchorTracks: an optional list of MediaTrack* already known to belong to
--   the requesting selection, or nil.
--
-- Anchors are optional and additive: some workflows (e.g. a pure time
-- selection with no item/track naturally pinned to it) never have a stable
-- anchor, and that's fine -- project handle membership
-- (M.isProjectStillOpen) is always the primary, sufficient check.
function M.capture(reaperApi, anchorItem, anchorTracks)
    if not reaperApi or not reaperApi.EnumProjects then
        return { ref = nil, anchors = {}, display_name = nil, display_path = nil }
    end

    local ref = reaperApi.EnumProjects(-1)
    local anchors = {}

    if ref and anchorItem and reaperApi.ValidatePtr2
        and reaperApi.ValidatePtr2(ref, anchorItem, "MediaItem*") then
        anchors[#anchors + 1] = { ptr = anchorItem, kind = "MediaItem*" }
    end

    if ref and anchorTracks then
        for _, tr in ipairs(anchorTracks) do
            if tr and reaperApi.ValidatePtr2
                and reaperApi.ValidatePtr2(ref, tr, "MediaTrack*") then
                anchors[#anchors + 1] = { ptr = tr, kind = "MediaTrack*" }
            end
        end
    end

    -- Display-only metadata for support/error messages. Never used to
    -- (re)identify a project -- only the live ref and anchors above are.
    local displayName = nil
    if ref and reaperApi.GetProjectName then
        local a, b = reaperApi.GetProjectName(ref, "")
        if type(b) == "string" and b ~= "" then
            displayName = b
        elseif type(a) == "string" and a ~= "" then
            displayName = a
        end
    end

    local displayPath = nil
    if ref and reaperApi.GetProjectPathEx then
        local p = reaperApi.GetProjectPathEx(ref, "")
        if type(p) == "string" and p ~= "" then
            displayPath = p
        end
    end

    return {
        ref = ref,
        anchors = anchors,
        display_name = displayName,
        display_path = displayPath,
    }
end

-- Is this exact ReaProject* still among REAPER's currently open projects?
-- This is the primary liveness check. A project stays valid across rename,
-- save-as (untitled -> path), and tab reordering -- the handle itself does
-- not change. A closed-and-reopened project (even the same file) is a new
-- instance and will not match.
function M.isProjectStillOpen(reaperApi, projectRef)
    if not projectRef or not reaperApi or not reaperApi.EnumProjects then
        return false
    end
    local idx = 0
    while true do
        local proj = reaperApi.EnumProjects(idx)
        if not proj then
            return false
        end
        if proj == projectRef then
            return true
        end
        idx = idx + 1
    end
end

-- Absolute fail-closed gate: is it proven safe to import into this
-- RunContext's captured origin project right now?
--
-- ok=true  only when the captured project handle is still open AND (if any
--          anchors were captured) at least one anchor still validates
--          against that same project.
-- ok=false for every other case, including a missing/never-captured
--          project ref -- callers must never fall back to the active
--          project when this returns false.
function M.validateOriginProjectContext(reaperApi, runContext)
    local project = runContext and runContext.project
    if not project or not project.ref then
        return false, "project_ref_missing"
    end
    if not M.isProjectStillOpen(reaperApi, project.ref) then
        return false, "project_closed"
    end
    local anchors = project.anchors
    if anchors and #anchors > 0 then
        local anyValid = false
        for _, anchor in ipairs(anchors) do
            if reaperApi.ValidatePtr2 and reaperApi.ValidatePtr2(project.ref, anchor.ptr, anchor.kind) then
                anyValid = true
                break
            end
        end
        if not anyValid then
            return false, "anchor_invalid"
        end
    end
    return true, "ok"
end

-- Restore whichever project was active before a scoped switch, but only if
-- it is still open. Never falls back to an arbitrary/different project.
-- Returns true if a restore was actually performed.
function M.restoreProjectInstance(reaperApi, previousRef)
    if not reaperApi or not reaperApi.SelectProjectInstance then
        return false
    end
    if not previousRef or not M.isProjectStillOpen(reaperApi, previousRef) then
        return false
    end
    reaperApi.SelectProjectInstance(previousRef)
    return true
end

-- Run fn() with projectRef temporarily selected as REAPER's active project,
-- then restore whatever was active before (see M.restoreProjectInstance).
-- Restoration always runs, even if fn() raises -- callers must not rely on
-- fn() returning normally for cleanup.
--
-- Returns pcallOk, result: pcallOk is false only if fn() raised; result is
-- fn()'s own single return value when pcallOk is true, or the error object
-- when pcallOk is false.
function M.withProjectInstance(reaperApi, projectRef, fn)
    local previousRef = (reaperApi and reaperApi.EnumProjects) and reaperApi.EnumProjects(-1) or nil
    if reaperApi and reaperApi.SelectProjectInstance then
        reaperApi.SelectProjectInstance(projectRef)
    end
    local ok, result = pcall(fn)
    M.restoreProjectInstance(reaperApi, previousRef)
    return ok, result
end

return M
