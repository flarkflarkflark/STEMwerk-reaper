-- STEMwerk_ExtState.lua
-- ExtState helper layer for STEMwerk (read/write wrappers).
-- Loaded via dofile() from STEMwerk.lua; returns a small helper table.

local M = {}

local function getExtSection()
    if type(EXT_SECTION) == "string" and EXT_SECTION ~= "" then
        return EXT_SECTION
    end
    return "STEMwerk"
end

function M.getExtStateValue(key)
    if reaper and reaper.GetExtState then
        local v = reaper.GetExtState(getExtSection(), key)
        if v ~= nil and v ~= "" then
            return v
        end
    end
    return nil
end

function M.setExtStateValue(key, value)
    if reaper and reaper.SetExtState then
        reaper.SetExtState(getExtSection(), tostring(key), tostring(value), true)
    end
end

return M
