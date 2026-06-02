local M = {}

M.WORKFLOW_DRUMKIT = "drumkit"
M.SOURCE_DIRECT = "dks_direct"
M.SOURCE_EXTRACT = "dks_extract"
M.DIRECT_DKS_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
M.KIT_STEMS = { "Kick", "Snare", "Toms", "Hi-Hat", "Ride", "Crash" }

function M.isDirectPreset(preset)
    local v = tostring(preset or "")
    return v == M.SOURCE_DIRECT or v == M.WORKFLOW_DRUMKIT
end

function M.isExtractPreset(preset)
    return tostring(preset or "") == M.SOURCE_EXTRACT
end

function M.isDrumKitSource(source)
    local v = tostring(source or "")
    return v == M.SOURCE_DIRECT or v == M.SOURCE_EXTRACT or M.isDirectPreset(v)
end

function M.buildDirectRunOptions()
    return {
        workflowMode = M.WORKFLOW_DRUMKIT,
        workflowSource = M.SOURCE_DIRECT,
        requestedStage2Model = M.DIRECT_DKS_MODEL,
    }
end

function M.buildExtractRunOptions()
    return {
        workflowMode = M.WORKFLOW_DRUMKIT,
        workflowSource = M.SOURCE_EXTRACT,
        requestedStage2Model = M.DIRECT_DKS_MODEL,
    }
end

return M
