-- STEMwerk: simple REAPER Lua script to launch STEM separation
-- Select a file and call the Python wrapper: tools/separate.py

local reaper = reaper

local retval, input = reaper.GetUserFileNameForRead("", "Select audio file to separate", "")
if not retval or input == "" then return end

-- Adjust this `script_path` if you place the repo somewhere REAPER can't see.
local script_path = reaper.GetResourcePath() .. "/Scripts/STEMwerk/tools/separate.py"
local python = "python"

local cmd = string.format('"%s" "%s" "%s"', python, script_path, input)
reaper.ShowConsoleMsg("Running: " .. cmd .. "\n")
os.execute(cmd)
reaper.ShowMessageBox("Separation started. Check the output folder.", "STEMwerk", 0)
