-- STEMwerk Glue/State/UI Helpers
-- Extracted from STEMwerk.lua for modularity and maintainability.
-- Only contains orchestration, glue, and simple UI/state helpers (NO workflow/processing logic).

local M = {}

-- Preset application helpers
function M.applyPresetKaraoke(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = true
    STEMS[3].selected = true
    STEMS[4].selected = true
    if STEMS[5] then STEMS[5].selected = true end
    if STEMS[6] then STEMS[6].selected = true end
end

function M.applyPresetInstrumental(STEMS)
    M.applyPresetKaraoke(STEMS)
end

function M.applyPresetDrumsOnly(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = true
    STEMS[3].selected = false
    STEMS[4].selected = false
    if STEMS[5] then STEMS[5].selected = false end
    if STEMS[6] then STEMS[6].selected = false end
end

function M.applyPresetVocalsOnly(STEMS)
    STEMS[1].selected = true
    STEMS[2].selected = false
    STEMS[3].selected = false
    STEMS[4].selected = false
    if STEMS[5] then STEMS[5].selected = false end
    if STEMS[6] then STEMS[6].selected = false end
end

function M.applyPresetBassOnly(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = false
    STEMS[3].selected = true
    STEMS[4].selected = false
    if STEMS[5] then STEMS[5].selected = false end
    if STEMS[6] then STEMS[6].selected = false end
end

function M.applyPresetOtherOnly(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = false
    STEMS[3].selected = false
    STEMS[4].selected = true
    if STEMS[5] then STEMS[5].selected = false end
    if STEMS[6] then STEMS[6].selected = false end
end

function M.applyPresetGuitarOnly(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = false
    STEMS[3].selected = false
    STEMS[4].selected = false
    STEMS[5].selected = true
    STEMS[6].selected = false
end

function M.applyPresetPianoOnly(STEMS)
    STEMS[1].selected = false
    STEMS[2].selected = false
    STEMS[3].selected = false
    STEMS[4].selected = false
    STEMS[5].selected = false
    STEMS[6].selected = true
end

function M.applyPresetAll(STEMS)
    for i = 1, #STEMS do
        STEMS[i].selected = true
    end
end

-- Post-process candidate helpers
function M.clearPostProcessCandidates()
    _G.postProcessCandidates = {}
end

function M.addPostProcessCandidate(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return end
    for _, existing in ipairs(_G.postProcessCandidates or {}) do
        if existing == item then return end
    end
    table.insert(_G.postProcessCandidates, item)
end

return M
