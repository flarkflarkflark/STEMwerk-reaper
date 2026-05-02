-- @description Stemwerk: Setup Toolbar
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.0
-- @changelog
--   Adds/refreshes STEMwerk scripts in the Action List and guides toolbar setup.
--   Registers the dedicated "Stemwerk: Explode Takes (In Place)" quick action.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local function getPathSep()
    local osName = reaper and reaper.GetOS and tostring(reaper.GetOS() or "") or ""
    if osName:match("Win") then return "\\" end
    return "/"
end

local function joinPath(...)
    local sep = getPathSep()
    local parts = {...}
    for i = 1, #parts do
        local part = tostring(parts[i] or "")
        if i > 1 then
            part = part:gsub("^[/\\]+", "")
        end
        if i < #parts then
            part = part:gsub("[/\\]+$", "")
        end
        parts[i] = part
    end
    return table.concat(parts, sep)
end

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function copyFile(src, dst)
    local inFile = io.open(src, "rb")
    if not inFile then return false, "unable to open source: " .. tostring(src) end
    local data = inFile:read("*all")
    inFile:close()
    local outFile = io.open(dst, "wb")
    if not outFile then return false, "unable to open destination: " .. tostring(dst) end
    outFile:write(data)
    outFile:close()
    return true
end

local function ensureDir(path)
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return true
    end
    return false
end

local scriptDir = getScriptDir()
local pathSep = getPathSep()
local toolbarAssetDir = joinPath(scriptDir, "assets", "toolbar_icons")

local scriptFiles = {
    "STEMwerk.lua",
    "STEMwerk-SETUP.lua",
    "STEMwerk_Explode_Takes.lua",
    "STEMwerk_Karaoke.lua",
    "STEMwerk_Vocals_Only.lua",
    "STEMwerk_Drums_Only.lua",
    "STEMwerk_Bass_Only.lua",
    "STEMwerk_All_Stems.lua",
}

local toolbarIcons = {
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_main_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_main_180x60.png"),
        targets = {"stemwerk_main.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_setup_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_setup_180x60.png"),
        targets = {"stemwerk_setup.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_karaoke_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_karaoke_180x60.png"),
        targets = {"stemwerk_karaoke.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_vocals_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_vocals_only_180x60.png"),
        targets = {"stemwerk_vocals_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_drums_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_drums_only_180x60.png"),
        targets = {"stemwerk_drums_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_bass_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_bass_only_180x60.png"),
        targets = {"stemwerk_bass_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_all_stems_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_all_stems_180x60.png"),
        targets = {"stemwerk_all_stems.png", "toolbar_6stem.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_explode_takes_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_explode_takes_180x60.png"),
        targets = {"stemwerk_explode_takes.png"},
    },
}

local function installToolbarIcons()
    local resourcePath = reaper and reaper.GetResourcePath and reaper.GetResourcePath() or ""
    if resourcePath == "" then
        return false, "REAPER resource path is unavailable."
    end

    local toolbarRoot = joinPath(resourcePath, "Data", "toolbar_icons")
    local toolbar150 = joinPath(toolbarRoot, "150")
    local toolbar200 = joinPath(toolbarRoot, "200")
    ensureDir(toolbarRoot)
    ensureDir(toolbar150)
    ensureDir(toolbar200)

    local installed = {}
    local missing = {}

    for _, icon in ipairs(toolbarIcons) do
        local have1x = fileExists(icon.source1x)
        local have2x = fileExists(icon.source2x)
        if not have1x or not have2x then
            missing[#missing + 1] = (not have1x and icon.source1x or icon.source2x)
        else
            for _, name in ipairs(icon.targets) do
                local okBase, errBase = copyFile(icon.source1x, joinPath(toolbarRoot, name))
                local ok150, err150 = copyFile(icon.source2x, joinPath(toolbar150, name))
                local ok200, err200 = copyFile(icon.source2x, joinPath(toolbar200, name))
                if okBase and ok150 and ok200 then
                    installed[#installed + 1] = name
                else
                    return false, errBase or err150 or err200 or ("failed to install " .. tostring(name))
                end
            end
        end
    end

    if #missing > 0 then
        return false, "Missing toolbar icon strip(s):\n" .. table.concat(missing, "\n")
    end

    return true, toolbarRoot, installed
end

if reaper and reaper.AddRemoveReaScript then
    for _, name in ipairs(scriptFiles) do
        reaper.AddRemoveReaScript(true, 0, scriptDir .. name, false)
    end
    -- Commit changes
    reaper.AddRemoveReaScript(true, 0, scriptDir .. scriptFiles[#scriptFiles], true)
end

local installOk, installInfo = installToolbarIcons()
local installSummary
if installOk then
    installSummary =
        "Toolbar icon strips installed to:\n" .. installInfo ..
        "\n- 1x: stemwerk_*.png in toolbar_icons" ..
        "\n- hiDPI: matching names in 150/ and 200/" ..
        "\n- compatibility alias: toolbar_6stem.png"
else
    installSummary =
        "Toolbar icon install skipped:\n" .. tostring(installInfo) ..
        "\n\nYou can still use the shipped strip files manually from:\n" ..
        toolbarAssetDir .. pathSep .. "strips_90x30\n" ..
        toolbarAssetDir .. pathSep .. "strips_180x60"
end

msgBox(
    "Stemwerk: Setup Toolbar",
    "Scripts are ready.\n\nTo add toolbar buttons:\n1) Open Actions -> Show action list\n2) Filter for 'STEMwerk:'\n3) Select a script (e.g. 'STEMwerk: Karaoke')\n4) Add it to a toolbar (right-click toolbar -> Customize)\n\n" ..
    installSummary ..
    "\n\nTip: Run 'STEMwerk: Setup' if separation fails or components are missing.",
    0
)
