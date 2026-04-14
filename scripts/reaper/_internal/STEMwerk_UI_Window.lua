-- STEMwerk_UI_Window.lua: Window/UI utility helpers extracted from STEMwerk.lua

local M = {}

local MIN_TRACK_HEIGHT = 72

function M.ensureTrackHeight(track)
    if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then return end
    local current = reaper.GetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE") or 0
    if current < MIN_TRACK_HEIGHT then
        reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", MIN_TRACK_HEIGHT)
    end
end

function M.adjustTrackLayout()
    if reaper.TrackList_AdjustWindows then
        reaper.TrackList_AdjustWindows(false)
    end
    if reaper.UpdateTimeline then
        reaper.UpdateTimeline()
    end
    reaper.UpdateArrange()
end

function M.handleArtAdvance(state, mouseDown, char)
    state = state or {}
    local uiClicked = (GUI and GUI.uiClickedThisFrame) or false
    if char == 32 then
        generateNewArt()
        return
    end
    if mouseDown and not state.artMouseDown then
        state.artMouseDown = true
        state.artClickBlocked = uiClicked
    elseif not mouseDown and state.artMouseDown then
        if not state.artClickBlocked and not uiClicked then
            generateNewArt()
        end
        state.artMouseDown = false
        state.artClickBlocked = nil
    elseif mouseDown and state.artMouseDown and uiClicked then
        state.artClickBlocked = true
    end
end

return M
