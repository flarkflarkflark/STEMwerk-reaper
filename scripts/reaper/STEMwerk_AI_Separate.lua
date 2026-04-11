-- @description STEMwerk (compat wrapper)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1.8
-- @changelog
--   Wrapper: old script name kept for backwards compatibility.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk
--
-- This file exists to avoid breaking existing REAPER actions that still
-- point to STEMwerk_AI_Separate.lua. The actual implementation lives in:
--   scripts/reaper/STEMwerk.lua

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""

local main_file = script_path .. "STEMwerk.lua"
local f = io.open(main_file, "r")
if f then
  f:close()
  dofile(main_file)
else
  reaper.ShowMessageBox(
    "Missing main script:\n\n" .. tostring(main_file) .. "\n\nReinstall STEMwerk or update your script paths.",
    "STEMwerk",
    0
  )
end
