-- STEMwerk_Window.lua
-- Window geometry helpers (monitor bounds, sizing, and position persistence).
-- Loaded via dofile() from STEMwerk.lua; returns a helper table.

local M = {}

-- Get monitor bounds at a specific screen position (for multi-monitor support)
-- Returns screenLeft, screenTop, screenRight, screenBottom
function M.getMonitorBoundsAt(x, y)
    local screenLeft, screenTop, screenRight, screenBottom = nil, nil, nil, nil

    -- Ensure integer coordinates
    x = math.floor(x)
    y = math.floor(y)

    -- Method 1: SWS BR_Win32_GetMonitorRectFromRect (most reliable for multi-monitor)
    if reaper.BR_Win32_GetMonitorRectFromRect then
        local retval, mLeft, mTop, mRight, mBottom = reaper.BR_Win32_GetMonitorRectFromRect(true, x, y, x+1, y+1)
        if retval and mLeft and mTop and mRight and mBottom and mRight > mLeft and mBottom > mTop then
            return mLeft, mTop, mRight, mBottom
        end
    end

    -- Method 2: JS_Window API to find monitor from point
    if reaper.JS_Window_GetRect then
        local mainHwnd = reaper.GetMainHwnd()
        if mainHwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(mainHwnd)
            if retval and left and top and right and bottom then
                -- Check if mouse is within REAPER main window area
                if x >= left and x <= right and y >= top and y <= bottom then
                    screenLeft, screenTop = left, top
                    screenRight, screenBottom = right, bottom
                else
                    -- Mouse is on a different monitor - estimate based on mouse position
                    -- Assume standard monitor size around the mouse position
                    local monitorW, monitorH = 1920, 1080
                    screenLeft = math.floor(x / monitorW) * monitorW
                    screenTop = math.floor(y / monitorH) * monitorH
                    screenRight = screenLeft + monitorW
                    screenBottom = screenTop + monitorH
                end
            end
        end
    end

    -- Fallback: estimate monitor based on mouse position
    if not screenLeft then
        local monitorW, monitorH = 1920, 1080
        -- Handle negative coordinates (monitors to the left/above primary)
        if x >= 0 then
            screenLeft = math.floor(x / monitorW) * monitorW
        else
            screenLeft = math.floor((x + 1) / monitorW) * monitorW - monitorW
        end
        if y >= 0 then
            screenTop = math.floor(y / monitorH) * monitorH
        else
            screenTop = math.floor((y + 1) / monitorH) * monitorH - monitorH
        end
        screenRight = screenLeft + monitorW
        screenBottom = screenTop + monitorH
    end

    return screenLeft, screenTop, screenRight, screenBottom
end

-- Clamp window position to stay fully on screen
function M.clampToScreen(winX, winY, winW, winH, refX, refY)
    local screenLeft, screenTop, screenRight, screenBottom = M.getMonitorBoundsAt(refX, refY)
    local margin = 20

    winX = math.max(screenLeft + margin, winX)
    winY = math.max(screenTop + margin, winY)
    winX = math.min(screenRight - winW - margin, winX)
    winY = math.min(screenBottom - winH - margin, winY)

    return winX, winY
end

function M.getLiveGeometry(defaultW, defaultH)
    local winW = (lastDialogW and lastDialogW > 0) and lastDialogW or (defaultW or 840)
    local winH = (lastDialogH and lastDialogH > 0) and lastDialogH or (defaultH or 600)
    local winX, winY = lastDialogX, lastDialogY
    if not winX or not winY then
        local mouseX, mouseY = reaper.GetMousePosition()
        winX = mouseX - winW / 2
        winY = mouseY - winH / 2
        winX, winY = M.clampToScreen(winX, winY, winW, winH, mouseX, mouseY)
    end
    return winW, winH, winX, winY
end

function M.applyLiveGeometry(defaultW, defaultH)
    local winW, winH, winX, winY = M.getLiveGeometry(defaultW, defaultH)
    lastDialogX, lastDialogY, lastDialogW, lastDialogH = winX, winY, winW, winH
    return winW, winH, winX, winY
end

function M.snapshotMainGeometry()
    if lastDialogX and lastDialogY and lastDialogW and lastDialogH then
        GUI.mainSnapshot = {
            x = lastDialogX,
            y = lastDialogY,
            w = lastDialogW,
            h = lastDialogH,
        }
    else
        GUI.mainSnapshot = nil
    end
end

function M.restoreMainSnapshot()
    if GUI.mainSnapshot then
        lastDialogX = GUI.mainSnapshot.x
        lastDialogY = GUI.mainSnapshot.y
        lastDialogW = GUI.mainSnapshot.w
        lastDialogH = GUI.mainSnapshot.h
    end
end

local function estimateTitlebarHeight()
    if OS == "Windows" then return 30 end
    if OS == "macOS" then return 24 end
    return 28
end

local function isGfxWindowVisible()
    if not (gfx and gfx.getchar) then return true end
    local ok, flags = pcall(gfx.getchar, 65537)
    if not ok or type(flags) ~= "number" then return true end
    if flags < 0 then return false end
    -- Only trust the visibility bit when present.
    if flags > 255 and (flags & 4) ~= 4 then return false end
    return true
end

local function rememberDialogGeometry(x, y, w, h)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    if not x or not y or not w or not h then return false end
    if w <= 0 or h <= 0 then return false end

    x = math.floor(x)
    y = math.floor(y)
    w = math.floor(w)
    h = math.floor(h)

    -- Ignore the classic late-close bogus reset to 0,0 if we already had a
    -- more plausible previous position.
    if x == 0 and y == 0 and lastDialogX and lastDialogY and (lastDialogX ~= 0 or lastDialogY ~= 0) then
        return false
    end

    lastDialogX = x
    lastDialogY = y
    lastDialogW = w
    lastDialogH = h
    return true
end

function M.rememberDialogGeometryFromRect(left, top, right, bottom)
    -- Keep X/Y from the native window rect, but prefer gfx.w/gfx.h for W/H so
    -- we store the same client/framebuffer size that gfx.init() expects.
    local w = (gfx and gfx.w and gfx.w > 0) and gfx.w or ((lastDialogW and lastDialogW > 0) and lastDialogW or ((right and left) and (right - left) or nil))
    local h = (gfx and gfx.h and gfx.h > 0) and gfx.h or ((lastDialogH and lastDialogH > 0) and lastDialogH or ((bottom and top) and (bottom - top) or nil))
    return rememberDialogGeometry(left, top, w, h)
end

local function persistWindowPos()
    return SETTINGS_MOD.persistWindowPos()
end

function M.updateDialogPosFromGfx()
    if not (gfx and gfx.w and gfx.h and gfx.w > 0 and gfx.h > 0) then return false end
    if not isGfxWindowVisible() then return false end

    -- Best source inside REAPER: ask gfx itself for the undocked window rect.
    if gfx.dock then
        local dockState, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
        if dockState and wx and wy and ww and wh and ww > 0 and wh > 0 then
            if rememberDialogGeometry(wx, wy, ww, wh) then
                persistWindowPos()
                return true
            end
        end
    end

    if gfx.clienttoscreen then
        local points = {
            {0, 0},
            {1, 1},
            {math.floor(gfx.w / 2), math.floor(gfx.h / 2)},
        }
        for _, pt in ipairs(points) do
            local px, py = pt[1], pt[2]
            local sx, sy = gfx.clienttoscreen(px, py)
            if sx and sy and not (sx == 0 and sy == 0) then
                if rememberDialogGeometry(sx - px, math.max(0, (sy - py) - estimateTitlebarHeight()), gfx.w, gfx.h) then
                    persistWindowPos()
                    return true
                end
            end
        end
    end

    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx and my and mx >= 0 and my >= 0 and mx <= gfx.w and my <= gfx.h then
        local sx, sy = reaper.GetMousePosition()
        if sx and sy then
            return rememberDialogGeometry(sx - mx, math.max(0, (sy - my) - estimateTitlebarHeight()), gfx.w, gfx.h)
        end
    end
    return false
end

function M.captureWindowGeometry(title)
    if M.updateDialogPosFromGfx() then return true end

    if title and reaper and reaper.JS_Window_Find and reaper.JS_Window_GetRect then
        local hwnd = reaper.JS_Window_Find(title, true)
        if hwnd then
            local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if ok then
                return M.rememberDialogGeometryFromRect(left, top, right, bottom)
            end
        end
    end

    return false
end

return M
