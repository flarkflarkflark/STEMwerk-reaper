local M = {}

M.DIRECT_DKS_PRESET = "dks_direct"
M.DIRECT_DKS_MODE = "dks_direct"
M.DIRECT_DKS_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"

function M.isDirectPreset(preset)
    return tostring(preset or "") == M.DIRECT_DKS_PRESET
end

function M.buildDirectRunOptions()
    return {
        workflowMode = M.DIRECT_DKS_MODE,
        requestedStage2Model = M.DIRECT_DKS_MODEL,
    }
end

return M
