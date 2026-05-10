-- @description Stemwerk: REAPER Native Theme Test (LOCAL TEST ONLY - not shipped in ReaPack)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.1.9
-- @changelog
--   Initial local test version.

_G.FORCE_THEME_PRESET = "reaper_native"
_G.STEMWERK_REAPER_NATIVE_UTILITY = true

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
local main_path = script_path .. "STEMwerk.lua"

local f = io.open(main_path, "r")
if not f then
    reaper.MB("Could not find normal STEMwerk.lua at:\n" .. main_path, "STEMwerk Test Entrypoint Error", 0)
    return
end
f:close()

dofile(main_path)
