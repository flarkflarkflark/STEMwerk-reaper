-- @description Stemwerk: Setup Toolbar
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1.7
-- @changelog
--   Adds/refreshes STEMwerk scripts in the Action List and guides toolbar setup.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local scriptDir = getScriptDir()

local scriptFiles = {
    "STEMwerk.lua",
    "STEMwerk-SETUP.lua",
    "STEMwerk_Karaoke.lua",
    "STEMwerk_Vocals_Only.lua",
    "STEMwerk_Drums_Only.lua",
    "STEMwerk_Bass_Only.lua",
    "STEMwerk_All_Stems.lua",
}

if reaper and reaper.AddRemoveReaScript then
    for _, name in ipairs(scriptFiles) do
        reaper.AddRemoveReaScript(true, 0, scriptDir .. name, false)
    end
    -- Commit changes
    reaper.AddRemoveReaScript(true, 0, scriptDir .. scriptFiles[#scriptFiles], true)
end

msgBox(
    "Stemwerk: Setup Toolbar",
    "Scripts are ready.\n\nTo add toolbar buttons:\n1) Open Actions → Show action list\n2) Filter for 'STEMwerk:'\n3) Select a script (e.g. 'STEMwerk: Karaoke')\n4) Add it to a toolbar (right-click toolbar → Customize)\n\nTip: Run 'STEMwerk: Setup' if separation fails or components are missing.",
    0
)
