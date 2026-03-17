-- @description Stemwerk: Vocals Only
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1
-- @changelog
--   Quick preset: vocals only.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"

reaper.SetExtState(EXT_SECTION, "quick_run", "1", false)
reaper.SetExtState(EXT_SECTION, "quick_preset", "vocals", false)

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
dofile(script_path .. "STEMwerk.lua")
