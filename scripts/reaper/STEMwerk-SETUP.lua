-- @description Stemwerk: Installation & Setup
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1
-- @changelog
--   2026-03-15: Route setup to the new first-run bootstrap flow.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local scriptDir = getScriptDir()
local setupScript = scriptDir .. "STEMwerk_First_Run_Setup.lua"

if fileExists(setupScript) then
    dofile(setupScript)
else
    reaper.ShowMessageBox(
        "Missing setup script:\n\n" .. tostring(setupScript) .. "\n\nReinstall STEMwerk.",
        "STEMwerk Setup",
        0
    )
end
