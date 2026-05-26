-- @description Stemwerk: Explode Takes (In Place)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.2.3
-- @changelog
--   Quick action: explode selected multi-take items in place.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"

reaper.SetExtState(EXT_SECTION, "quick_command", "explode_in_place", false)

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
dofile(script_path .. "STEMwerk.lua")
