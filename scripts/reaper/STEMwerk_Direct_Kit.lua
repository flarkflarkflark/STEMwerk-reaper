-- @description Stemwerk: Direct Kit
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.3.0.5
-- @changelog
--   Quick preset: direct drum kit split.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"

reaper.SetExtState(EXT_SECTION, "quick_run", "1", false)
reaper.SetExtState(EXT_SECTION, "quick_preset", "dks_direct", false)
reaper.SetExtState(EXT_SECTION, "active_workflow_mode", "drumkit", false)
reaper.SetExtState(EXT_SECTION, "active_workflow_source", "dks_direct", false)

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
dofile(script_path .. "STEMwerk.lua")
