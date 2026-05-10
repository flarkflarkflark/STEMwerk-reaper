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

-- Take/item playback-state snapshot helpers (used by separation result processing)

function M.snapshotTakePlaybackState(take)
    if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then return nil end
    local playrate = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")) or 1.0
    if playrate < 0.0001 then playrate = 1.0 end
    local pitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")) or 0.0
    local preservePitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")) or 0
    preservePitch = (preservePitch ~= 0) and 1 or 0
    return { playrate = playrate, pitch = pitch, preservePitch = preservePitch }
end

function M.snapshotItemPlaybackState(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return nil end
    return M.snapshotTakePlaybackState(reaper.GetActiveTake(item))
end

function M.applyTakePlaybackState(take, state, itemLen)
    if not take or not state then return end
    if not reaper.ValidatePtr(take, "MediaItem_Take*") then return end

    local source = reaper.GetMediaItemTake_Source(take)
    local sourceLen = nil
    if source and reaper.GetMediaSourceLength then
        local len = reaper.GetMediaSourceLength(source)
        sourceLen = tonumber(len)
    end

    if sourceLen and itemLen and itemLen > 0 then
        local expected = itemLen * (state.playrate or 1.0)
        local tolerance = math.max(0.01, expected * 0.01)
        if math.abs(sourceLen - expected) > tolerance then
            return
        end
    end

    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", state.playrate or 1.0)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", state.pitch or 0.0)
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", state.preservePitch or 0)
end

return M
