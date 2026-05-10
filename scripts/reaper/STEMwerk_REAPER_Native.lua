-- @description Stemwerk: REAPER Native Theme Test (LOCAL TEST ONLY - not shipped in ReaPack)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.1.9
-- @changelog
--   Initial local test version.

_G.FORCE_THEME_PRESET = "reaper_native"

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
dofile(script_path .. "STEMwerk.lua")
