-- STEMwerk_UI_PathInput.lua
-- Reusable path / text-input helpers: keyboard handling, clipboard, folder picker.
-- No rendering — rendering lives in the calling context (STEMwerk.lua).
-- Loaded once at startup; safe to use from any REAPER Lua context.

local M = {}

-- ── Clipboard (SWS extension) ─────────────────────────────────────────────────

function M.hasClipboard()
    return type(reaper.CF_GetClipboard) == "function"
        and type(reaper.CF_SetClipboard) == "function"
end

local function _getClip()
    if M.hasClipboard() then
        local v = reaper.CF_GetClipboard("")
        return type(v) == "string" and v or ""
    end
    return nil  -- unavailable
end

local function _setClip(text)
    if M.hasClipboard() then
        reaper.CF_SetClipboard(tostring(text or ""))
        return true
    end
    return false
end

-- ── Folder picker (js_ReaScriptAPI) ──────────────────────────────────────────

function M.hasBrowse()
    return type(reaper.JS_Dialog_BrowseForOpenFiles) == "function"
end

-- Opens a native file picker and extracts the parent directory of the selected
-- file. Returns the directory string on success, nil on cancel or unavailability.
-- The caption tells the user to navigate to their desired folder and select any
-- file inside it; this avoids needing a folder-picker API that REAPER lacks.
function M.browseForFolder(initialPath)
    if not M.hasBrowse() then return nil end
    local start = tostring(initialPath or "")
    if start == "" and type(reaper.GetProjectPath) == "function" then
        start = reaper.GetProjectPath("") or ""
    end
    local ok, files = reaper.JS_Dialog_BrowseForOpenFiles(
        "Navigate to folder, then select any file inside it", start, "", "", false)
    if ok and ok ~= 0 and type(files) == "string" and files ~= "" then
        local nul = files:find("\0", 1, true)
        if nul then files = files:sub(1, nul - 1) end
        local dir = files:match("^(.*)[/\\][^/\\]+$")
        return (dir and dir ~= "") and dir or files
    end
    return nil
end

-- ── Input state ───────────────────────────────────────────────────────────────

-- Creates a new input state. Cursor starts at end of the initial value.
function M.newState(initialValue)
    local v = tostring(initialValue or "")
    return { value = v, cursor = #v, allSelected = false }
end

-- ── Key handling ──────────────────────────────────────────────────────────────

-- Processes one raw key code from gfx.getchar() into the input state.
-- Returns true when the state was modified (caller should redraw).
function M.handleKey(state, char)
    if not state or not char or char <= 0 then return false end
    local v      = state.value or ""
    local cursor = math.max(0, math.min(state.cursor or #v, #v))

    -- ── All-selected mode ──────────────────────────────────────────────────
    if state.allSelected then
        if char == 1 then                                        -- Ctrl+A: no-op
            return false
        elseif char == 3 then                                    -- Ctrl+C: copy
            _setClip(v); return false
        elseif char == 24 then                                   -- Ctrl+X: cut
            _setClip(v)
            state.value = ""; state.cursor = 0; state.allSelected = false
            return true
        elseif char == 22 then                                   -- Ctrl+V: paste replaces all
            local clip = _getClip()
            if clip ~= nil then
                state.value = clip; state.cursor = #clip; state.allSelected = false
                return true
            end
            return false
        elseif char == 8 or char == 127 or char == 6579564 then -- Backspace / Delete
            state.value = ""; state.cursor = 0; state.allSelected = false
            return true
        elseif char >= 32 and char <= 126 then                   -- Printable: replace all
            state.value = string.char(char); state.cursor = 1; state.allSelected = false
            return true
        end
        return false
    end

    -- ── Normal mode ────────────────────────────────────────────────────────
    if char == 1 then                                            -- Ctrl+A
        if #v > 0 then state.allSelected = true; return true end
        return false
    elseif char == 3 then                                        -- Ctrl+C: copy
        _setClip(v); return false
    elseif char == 24 then                                       -- Ctrl+X: cut whole value
        _setClip(v)
        state.value = ""; state.cursor = 0; return true
    elseif char == 22 then                                       -- Ctrl+V: paste at cursor
        local clip = _getClip()
        if clip ~= nil then
            state.value  = v:sub(1, cursor) .. clip .. v:sub(cursor + 1)
            state.cursor = cursor + #clip
            return true
        end
        return false
    elseif char == 8 then                                        -- Backspace
        if cursor > 0 then
            state.value  = v:sub(1, cursor - 1) .. v:sub(cursor + 1)
            state.cursor = cursor - 1
            return true
        end
        return false
    elseif char == 127 or char == 6579564 then                   -- Delete (forward)
        if cursor < #v then
            state.value = v:sub(1, cursor) .. v:sub(cursor + 2)
            return true
        end
        return false
    elseif char >= 32 and char <= 126 then                       -- Printable char
        state.value  = v:sub(1, cursor) .. string.char(char) .. v:sub(cursor + 1)
        state.cursor = cursor + 1
        return true
    end
    return false
end

-- ── Display helper ────────────────────────────────────────────────────────────

-- Compute the display string and cursor pixel offset for rendering.
--   state:      path input state table
--   availableW: pixel width available for text (not including any side padding)
--   measureFn:  function(str) -> pixel width (pass gfx.measurestr, font must be set)
-- Returns: displayStr, cursorPx (relative to text start), isAllSelected
function M.getDisplayInfo(state, availableW, measureFn)
    local v      = state.value or ""
    local cursor = math.max(0, math.min(state.cursor or #v, #v))

    if state.allSelected then
        local display = v
        while #display > 0 and measureFn(display) > availableW do
            display = display:sub(2)
        end
        if display ~= v then display = "..." .. display end
        return display, measureFn(display), true
    end

    local before  = v:sub(1, cursor)
    local after   = v:sub(cursor + 1)
    local beforeW = measureFn(before)

    if beforeW <= availableW then
        -- Cursor fits; trim right side if text overflows.
        local display = v
        while #display > cursor and measureFn(display) > availableW do
            display = display:sub(1, -2)
        end
        local suffix = (#display < #v) and "..." or ""
        return display .. suffix, beforeW, false
    else
        -- Cursor past right edge; scroll left until cursor is visible.
        local sb = before
        while #sb > 0 and measureFn("..." .. sb) > availableW do
            sb = sb:sub(2)
        end
        local prefix  = (#sb < #before) and "..." or ""
        local dbefore = prefix .. sb
        local dbW     = measureFn(dbefore)
        local dafter  = after
        while #dafter > 0 and measureFn(dbefore .. dafter) > availableW do
            dafter = dafter:sub(1, -2)
        end
        local dsuffix = (#dafter < #after) and "..." or ""
        return dbefore .. dafter .. dsuffix, dbW, false
    end
end

return M
