-- STEMwerk_Messages.lua: message/dialog helpers extracted from STEMwerk.lua
-- Globals (GUI, gfx, SCRIPT_NAME, OS, reaper, HELPERS, isProcessingActive,
--   updateTheme) are accessed directly.
-- Locals from STEMwerk.lua are injected via MESSAGES.configure(ctx).

local MESSAGES = {}
local C = {}

function MESSAGES.configure(ctx)
    for k, v in pairs(ctx) do C[k] = v end
end

local messageWindowState = {
    title = "",
    message = "",
    icon = "info",  -- "info", "warning", "error"
    wasMouseDown = false,
    startTime = 0,
    monitorSelection = false,  -- When true, auto-close and open main dialog on selection
}

local function showMessage(title, message, icon, monitorSelection, onClose)
    if C.loadSettings then C.loadSettings() end
    updateTheme()

    if monitorSelection then
        isProcessingActive = false
        if C.multiTrackQueue then
            C.multiTrackQueue.active = false
        end
    end

    messageWindowState.title = title or "STEMwerk"
    if type(message) == "table" then
        messageWindowState.messageData = message
        messageWindowState.message = ""
        messageWindowState.resultContext = true
    else
        messageWindowState.messageData = nil
        messageWindowState.message = message or ""
        messageWindowState.resultContext = false
    end
    messageWindowState.icon = icon or "info"
    messageWindowState.wasMouseDown = false
    messageWindowState.startTime = os.clock()
    messageWindowState.nextFrameAt = 0
    messageWindowState.nextSelectionCheckAt = 0
    messageWindowState.monitorSelection = monitorSelection or false
    messageWindowState.onClose = onClose

    if messageWindowState.monitorSelection then
        local overrideTitle = nil
        local overrideMessage = nil
        if C.hasTimeSelection and C.hasTimeSelection() then
            local res = C.resolveTimeSelectionTargets and C.resolveTimeSelectionTargets() or nil
            if res and (res.rawOverlap or 0) > 0 and #(res.items or {}) == 0 then
                overrideTitle = HELPERS.getNoAudibleTargetsTitle()
                overrideMessage = HELPERS.getNoAudibleTargetsMessage()
            end
        end
        if not overrideTitle and (reaper.CountSelectedTracks(0) or 0) > 0 then
            local soloActive = C.getProcessingSoloActive and C.getProcessingSoloActive() or false
            local anyAudibleTrack = false
            for t = 0, (reaper.CountSelectedTracks(0) or 0) - 1 do
                local tr = reaper.GetSelectedTrack(0, t)
                if tr and C.AUDIBILITY and C.AUDIBILITY.isTrackAudible(tr, soloActive) then
                    anyAudibleTrack = true
                    break
                end
            end
            if not anyAudibleTrack then
                overrideTitle = HELPERS.getNoAudibleTargetsTitle()
                overrideMessage = HELPERS.getNoAudibleTargetsMessage()
            end
        end
        if overrideTitle then
            messageWindowState.title = overrideTitle
            messageWindowState.message = overrideMessage
            messageWindowState.icon = "info"
        end
    end

    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    gfx.init(SCRIPT_NAME, winW, winH, 0, winX, winY)

    if monitorSelection then
        reaper.defer(function()
            local mainHwnd = reaper.GetMainHwnd()
            if mainHwnd and reaper.JS_Window_SetFocus then
                reaper.JS_Window_SetFocus(mainHwnd)
            end
        end)
    end

    if C.messageWindowLoop then
        if OS == "Windows" then
            C.messageWindowLoop()
        else
            reaper.defer(C.messageWindowLoop)
        end
    end
end

MESSAGES.messageWindowState = messageWindowState
MESSAGES.showMessage = showMessage

return MESSAGES
