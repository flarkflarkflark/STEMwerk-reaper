-- @description STEMwerk - Setup
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.3.0.6
-- @changelog
--   2026-03-15: Route setup to the internal setup bootstrap flow.
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

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local rawScriptDir = getScriptDir()
local PATH_HELPER = nil
local helperOk, helperMod = pcall(dofile, rawScriptDir .. "_internal/STEMwerk_Path_Helper.lua")
if helperOk and type(helperMod) == "table" then
    PATH_HELPER = helperMod
end
local INSTALL = PATH_HELPER and PATH_HELPER.resolveInstallRoot(rawScriptDir) or {
    ok = true,
    root = rawScriptDir,
    scriptsDir = rawScriptDir,
    actual = rawScriptDir,
    canonicalMismatch = false,
    canonical = "",
}

if INSTALL.ok and INSTALL.canonicalMismatch and INSTALL.canonical ~= "" then
    msgBox(
        "STEMwerk Setup",
        "STEMwerk is not installed in the canonical REAPER Scripts path.\n\n"
            .. "Preferred:\n" .. tostring(INSTALL.canonical or "(unknown)") .. "\n\n"
            .. "Current runtime install:\n" .. tostring(INSTALL.root or rawScriptDir) .. "\n\n"
            .. "Setup continues using the current location.\n"
            .. "Run STEMwerk-SETUP.lua before using STEMwerk.lua.",
        0
    )
elseif not INSTALL.ok then
    msgBox(
        "STEMwerk Setup",
        "STEMwerk is not installed in the REAPER Scripts folder.\n\nExpected:\n"
            .. tostring(INSTALL.canonical or "(unknown)")
            .. "\n\nCurrent script location:\n" .. tostring(rawScriptDir)
            .. "\n\nReinstall STEMwerk and run STEMwerk-SETUP.lua from REAPER.",
        0
    )
    return
end

local scriptDir = INSTALL.scriptsDir or rawScriptDir
local setupScript = scriptDir .. "_internal/STEMwerk_Setup_Internal.lua"

if fileExists(setupScript) then
    dofile(setupScript)
else
    msgBox(
        "STEMwerk Setup",
        "Missing setup script:\n\n" .. tostring(setupScript) .. "\n\nReinstall STEMwerk.",
        0
    )
end
