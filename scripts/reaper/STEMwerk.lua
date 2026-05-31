-- Minimal debug stub so early callers won't fail; real debugLog defined later.
function debugLog(msg) end
function clearDebugLog() end
-- @description STEMwerk - AI Stem Separation
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.2.11
-- @changelog
--   2026-04-24: Added quick-command path for toolbar explode actions that run without opening Main UI.
--   2026-04-24: Fixed playback-state transfer for imported stem takes with source-length guard (prevents double-stretch/content mismatch).
--   2026-03-24: Local working build saved as v2.2.1.1 for installer follow-up.
--   2026-03-13: Release v2.2.1: Major UI Polish & Engine Refactor.
--   2026-03-13: Comprehensive UI synchronization: footers and tooltips now accurately mirror button states (In-place/Takes).
--   2026-03-13: Improved target reporting: footer now detects tracks via time selection across multiple tracks.
--   2026-03-13: Fixed misleading GPU status reporting in progress windows; added active device info.
--   2026-03-13: Improved help screen legibility (Quick Start/Reaper tabs) with theme-aware background panels.
--   2026-03-13: Added pro-active footer warnings and informative popups for empty selections.
--   2026-03-13: Refactor to STEMwerk-reaper: uses stemwerk-core engine, REAPER-focused workflow.
--   2026-01-12: Linux CUDA cuDNN path fix, selection rules clarified, help window positioning/persistence
--   2026-01-12: Fixed importlib.util import for Linux/Arch compatibility, improved Python venv detection
--   2025-12-26: Glossy UI buttons + text shadow, KITT LED FX tweaks, playhead stays put while playing.
--   v2.0.0: i18n support + UI polish + device selection
--   v1.0.0: Initial release
-- @link Repository https://github.com/flarkflarkflark/STEMwerk
-- @about
--   # STEMwerk - Stem Separation
--
--   High-quality AI-powered stem separation using Demucs/audio-separator.
--   Separates the selected media item (or time selection) into stems:
--   Vocals, Drums, Bass, Other (and optionally Guitar, Piano with 6-stem model).
--
--   ## Features
--   - Processes ONLY the selected item portion (respects splits!)
--   - Choose which stems to extract via checkboxes or presets
--   - Quick presets: Karaoke, Instrumental, Drums Only
--   - Keyboard shortcuts for fast workflow
--   - Settings persist between sessions
--   - Option to create new tracks or replace in-place (as takes)
--   - GPU acceleration support (NVIDIA CUDA, AMD ROCm)
--
--   ## Keyboard Shortcuts (in dialog)
--   - 1-4: Toggle Vocals/Drums/Bass/Other
--   - K: Karaoke preset (instrumental only)
--   - I: Instrumental preset (no vocals)
--   - D: Drums Only preset
--   - Enter: Start separation
--   - Escape: Cancel
--
--   ## Requirements
--   - Python 3.9+ with audio-separator:
--     `pip install audio-separator[gpu]`
--   - ffmpeg installed and in PATH
--
--   ## License
--   MIT License - https://opensource.org/licenses/MIT

-- Keep in sync with repo VERSION via tools/version_sync.py.
local APP_VERSION = "2.2.2.2.11"
SCRIPT_NAME = "STEMwerk (v" .. APP_VERSION .. ")"
WINDOW_ART_GALLERY = "STEMwerk Art Gallery (v" .. APP_VERSION .. ")"
WINDOW_PROCESSING = "STEMwerk - Processing.. (v" .. APP_VERSION .. ")"
WINDOW_COMPLETE = "STEMwerk - Complete (v" .. APP_VERSION .. ")"
WINDOW_MULTI_TRACK = "STEMwerk - Multi-Track Progress (v" .. APP_VERSION .. ")"
local EXT_SECTION = "STEMwerk"  -- For ExtState persistence (keep old name for compatibility)
_G.EXT_SECTION = EXT_SECTION
local DEBUG = { enabled = false, logPath = nil }
WORKFLOW = WORKFLOW or {}
HELPERS = HELPERS or {}
UI = UI or {}
-- STEMwerk.lua

-- repo root bepalen (werkt ook als Reaper het via een symlink laadt)
 local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[/\\])")
if not script_path then script_path = "" end
local repo_root = script_path:match("(.*/)") or ""

local PATH_STATE = { helper = nil, installCache = nil }
do
    local ok, helper = pcall(dofile, script_path .. "_internal/STEMwerk_Path_Helper.lua")
    if ok and type(helper) == "table" then
        PATH_STATE.helper = helper
    end
end

-- Lua module search paths uitbreiden
package.path =
  package.path
  .. ";" .. repo_root .. "?.lua"
  .. ";" .. repo_root .. "scripts/?.lua"
  .. ";" .. repo_root .. "scripts/reaper/?.lua"
  .. ";" .. repo_root .. "scripts/reaper/?/init.lua"

local EXTSTATE = dofile(script_path .. "_internal/STEMwerk_ExtState.lua")
local getExtStateValue = EXTSTATE.getExtStateValue
local setExtStateValue = EXTSTATE.setExtStateValue

local function loadModule(path, label)
    local ok, mod = pcall(dofile, path)
    if not ok then
        error("STEMwerk: failed loading " .. tostring(label) .. ": " .. tostring(mod))
    end
    if type(mod) ~= "table" then
        error("STEMwerk: module " .. tostring(label) .. " did not return a table (got " .. type(mod) .. ")")
    end
    return mod
end

local SW_SETUP = dofile(script_path .. "_internal/STEMwerk_Runtime_Setup.lua")
local DKS_WORKFLOW = dofile(script_path .. "_internal/STEMwerk_DrumKit_Workflow.lua")
local SYSTEM = dofile(script_path .. "_internal/STEMwerk_System.lua")
local getOS = SYSTEM.getOS
local isAbsolutePath = SYSTEM.isAbsolutePath
local fileExists = SYSTEM.fileExists
local quoteArg = SYSTEM.quoteArg
local shellQuoteSingle = SYSTEM.shellQuoteSingle
local getHome = SYSTEM.getHome
local isFlatpak = SYSTEM.isFlatpak
local getFlatpakTempBase = SYSTEM.getFlatpakTempBase
local getTempDir = SYSTEM.getTempDir
local makeDir = SYSTEM.makeDir
local suppressStderr = SYSTEM.suppressStderr
local normalizePath = SYSTEM.normalizePath
local pathJoin = SYSTEM.pathJoin
local execProcess = SYSTEM.execProcess
execHidden = SYSTEM.execHidden
exec_capture = SYSTEM.exec_capture

dofile(script_path .. "_internal/STEMwerk_Log.lua")
dofile(script_path .. "_internal/STEMwerk_Timing.lua")

SELF_CHECK_LOGGED = false
function logSelfCheckOnce()
    if SELF_CHECK_LOGGED then return end
    SELF_CHECK_LOGGED = true
    local lines = {}
    lines[#lines + 1] = "script_path=" .. tostring(script_path)
    lines[#lines + 1] = "repo_root=" .. tostring(repo_root)
    lines[#lines + 1] = "log_path=" .. tostring(SW_LOG.getLogPath())
    lines[#lines + 1] = "os=" .. tostring(OS)
    lines[#lines + 1] = "python=" .. tostring(PYTHON_PATH)
    lines[#lines + 1] = "separator=" .. tostring(SEPARATOR_SCRIPT)
    SW_LOG.logExecResult("self_check", 0, table.concat(lines, "\n"))
end

-- Debug mode
-- Default: OFF (to avoid writing logs for normal users)
-- Enable by setting:
--   - Environment variable: STEMWERK_DEBUG=1
--   - REAPER ExtState: section "STEMwerk" key "debugMode" or "debug" to "1"
function DEBUG.isTruthy(v)
    v = tostring(v or ""):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

function DEBUG.getDebugMode()
    if DEBUG.isTruthy(os.getenv("STEMWERK_DEBUG")) then
        return true
    end
    if reaper and reaper.GetExtState then
        local v = reaper.GetExtState(EXT_SECTION, "debugMode")
        if v ~= "" then return v == "1" end
        v = reaper.GetExtState(EXT_SECTION, "debug")
        if v ~= "" then return v == "1" end
    end
    return false
end

DEBUG.enabled = DEBUG.getDebugMode()
DEBUG.logPath = nil

function debugLog(msg)
    if not DEBUG.enabled then return end
    if not DEBUG.logPath then
        local tempDir = getFlatpakTempBase() or os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
        DEBUG.logPath = tempDir .. (package.config:sub(1, 1) == "\\" and "\\" or "/") .. "STEMwerk_debug.log"
    end
    local f = io.open(DEBUG.logPath, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\n")
        f:close()
    end
end

local function clearDebugLog()
    if not DEBUG.enabled then return end
    local tempDir = getFlatpakTempBase() or os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
    DEBUG.logPath = tempDir .. (package.config:sub(1, 1) == "\\" and "\\" or "/") .. "STEMwerk_debug.log"
    local f = io.open(DEBUG.logPath, "w")
    if f then
        f:write("=== STEMwerk Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        f:close()
    end
end

clearDebugLog()
debugLog("Script loaded")

PERF_T0 = os.clock()
function perfMark(label)
    if not DEBUG.enabled then return end
    debugLog(string.format("PERF +%.3fs %s", os.clock() - PERF_T0, tostring(label)))
end

local function getCrashLogPath()
    if DEBUG.logPath and DEBUG.logPath ~= "" then
        return DEBUG.logPath
    end
    if SW_LOG and SW_LOG.getLogPath then
        return SW_LOG.getLogPath()
    end
    return "unavailable"
end

OS = getOS()
PATH_SEP = OS == "Windows" and "\\" or "/"

function uiNow()
    if reaper and reaper.time_precise then
        return reaper.time_precise()
    end
    return os.clock()
end

UI_PACING = UI_PACING or {
    dialogFrameInterval = 1 / 18,
    dialogFrameIntervalFx = 1 / 14,
    messageFrameInterval = 1 / 15,
    messageFrameIntervalFx = 1 / 8,
    messageSelectionCheckInterval = 0.25,
    progressFrameInterval = 1 / 20,
    progressFrameIntervalFx = 1 / 10,
    progressPollInterval = 0.33,
    multiTrackFrameInterval = 1 / 15,
    multiTrackFrameIntervalFx = 1 / 8,
    multiTrackPollInterval = 0.40,
    terminalReadInterval = 0.75,
}

function pacingFrameInterval(baseKey, fxKey)
    local useFx = SETTINGS and SETTINGS.visualFX
    if useFx and UI_PACING[fxKey] then
        return UI_PACING[fxKey]
    end
    return UI_PACING[baseKey]
end

local function getInstallScriptsDir()
    if PATH_STATE.helper then
        if not PATH_STATE.installCache then
            PATH_STATE.installCache = PATH_STATE.helper.resolveInstallRoot(script_path, { os = OS })
        end
        if PATH_STATE.installCache and PATH_STATE.installCache.scriptsDir and PATH_STATE.installCache.scriptsDir ~= "" then
            return PATH_STATE.installCache.scriptsDir
        end
    end
    return script_path
end

function PATH_STATE.getInstallPathState()
    if PATH_STATE.helper then
        if not PATH_STATE.installCache then
            PATH_STATE.installCache = PATH_STATE.helper.resolveInstallRoot(script_path, { os = OS })
        end
        return PATH_STATE.installCache
    end
    return nil
end

function PATH_STATE.allowNonCanonicalLaunch()
    if os.getenv("STEMWERK_ALLOW_NONCANONICAL") == "1" then
        return true
    end
    return getExtStateValue("allowNonCanonicalLaunch") == "1"
end

function PATH_STATE.joinPathLocal(sep, ...)
    if PATH_STATE.helper and PATH_STATE.helper.joinPath then
        return PATH_STATE.helper.joinPath(sep, ...)
    end
    local parts = { ... }
    local out = ""
    for _, part in ipairs(parts) do
        if part and part ~= "" then
            local p = tostring(part):gsub("[/\\]+", sep)
            p = p:gsub(sep .. "+$", "")
            if out == "" then
                out = p
            else
                p = p:gsub("^" .. sep .. "+", "")
                out = out .. sep .. p
            end
        end
    end
    return out
end

function PATH_STATE.shouldBlockNonCanonicalLaunch()
    if PATH_STATE.allowNonCanonicalLaunch() then
        return nil
    end

    local install = PATH_STATE.getInstallPathState()
    if not install or not install.ok or not install.canonicalMismatch or install.canonical == "" then
        return nil
    end

    local canonicalScript = PATH_STATE.joinPathLocal(install.sep or PATH_SEP, install.canonical, "scripts", "reaper", "STEMwerk.lua")
    if canonicalScript == "" or not fileExists(canonicalScript) then
        return nil
    end

    local currentScript = script_path .. "STEMwerk.lua"
    if PATH_STATE.helper and PATH_STATE.helper.pathEquals and PATH_STATE.helper.pathEquals(currentScript, canonicalScript, OS) then
        return nil
    end

    return {
        currentScript = currentScript,
        canonicalScript = canonicalScript,
        install = install,
    }
end

function PATH_STATE.formatNonCanonicalLaunchMessage(details)
    local install = details and details.install or {}
    return table.concat({
        "STEMwerk was launched from a non-canonical script copy.",
        "",
        "Current script:",
        tostring(details and details.currentScript or "(unknown)"),
        "",
        "Installed REAPER script:",
        tostring(details and details.canonicalScript or install.canonical or "(unknown)"),
        "",
        "This usually means REAPER is running a stale copy, which can trigger false 'missing components' checks and CPU-only processing.",
        "",
        "Run STEMwerk from the REAPER Scripts/STEMwerk-reaper install, or reinstall STEMwerk.",
        "",
        "Development override: set STEMWERK_ALLOW_NONCANONICAL=1 or ExtState allowNonCanonicalLaunch=1."
    }, "\n")
end

function PATH_STATE.guardNonCanonicalLaunch()
    local details = PATH_STATE.shouldBlockNonCanonicalLaunch()
    if not details then
        return true
    end
    debugLog("Blocking non-canonical launch: current=" .. tostring(details.currentScript) .. " canonical=" .. tostring(details.canonicalScript))
    reaper.ShowMessageBox(
        PATH_STATE.formatNonCanonicalLaunchMessage(details),
        "STEMwerk install mismatch",
        0
    )
    return false
end

-- Runtime/setup helper functions are now delegated to a dedicated module.
local ensureWritableDir
local getRuntimeBase
local getRuntimePaths
local resolveCommandPath
local readCapabilities
local persistPythonPath
local canImportAudioSeparator
local safeDofile
local isPythonAvailable
local runSetup
local verifyRuntimeAfterBootstrap
local ensureDependenciesInteractive

WINDOWS_GPU_NAMES = nil
WINDOWS_GPU_NAME_STATUS = nil

local function canRunPython(pythonCmd)
    if not pythonCmd or pythonCmd == "" then return false end
    local runnable = false

    -- If the user provided an absolute path, check if file exists
    if isAbsolutePath(pythonCmd) and fileExists(pythonCmd) then
        -- On Windows, actually try to run python.exe --version and log output/errors
        if OS == "Windows" then
            local cmd = quoteArg(pythonCmd) .. " --version"
            local rc, out = execProcess(cmd, 12000)
            debugLog("canRunPython Windows: cmd=" .. tostring(cmd) .. " rc=" .. tostring(rc) .. " out=" .. tostring(out))
            if rc == 0 and out and out:find("Python") then
                runnable = true
            else
                debugLog("canRunPython Windows: failed to run python, output: " .. tostring(out))
                return false
            end
        else
            -- Best effort executable bit check (Unix)
            local ok, _, code = os.execute(quoteArg(pythonCmd) .. " --version >/dev/null 2>&1")
            runnable = (ok == true or ok == 0)
        end
    end

    if not runnable then
        -- Avoid nested quotes; simplest cross-platform check.
        local cmd = quoteArg(pythonCmd) .. " --version"
        local rc, out = execProcess(cmd, 12000)
        debugLog("canRunPython: cmd=" .. tostring(cmd) .. " rc=" .. tostring(rc) .. " out=" .. tostring(out))
        if rc == 0 then
            -- Some ExecProcess implementations return a successful rc but no captured output.
            -- Try a popen fallback to capture stdout/stderr; if that isn't available, treat rc==0 as success.
            if out and out:find("Python") then
                runnable = true
            elseif OS == "Windows" then
                local captureCmd = SW_LOG.isWindows() and SW_LOG.wrapCmdForWindows(cmd) or (cmd .. " 2>&1")
                local h = io.popen(captureCmd)
                if h then
                    local content = h:read("*a") or ""
                    local ok, _, code = h:close()
                    debugLog("canRunPython popen rc=" .. tostring(code) .. " outLen=" .. tostring(#content))
                    if content and content:find("Python") then
                        runnable = true
                    end
                end
                if not runnable then
                    -- No output but exit code 0 -> treat as runnable
                    runnable = true
                end
            else
                -- On Unix, use exit code as primary indicator
                runnable = true
            end
        end
    end

    -- Final fallback for Unix shells if ExecProcess is problematic
    if not runnable and OS ~= "Windows" then
        local finalCmd = quoteArg(pythonCmd) .. " --version"
        local ok = os.execute(finalCmd .. " >/dev/null 2>&1")
        runnable = (ok == true or ok == 0)
    end

    if not runnable then
        return false
    end

    if OS ~= "macOS" and OS ~= "Linux" then
        return true
    end

    local versionCmd = quoteArg(pythonCmd) .. " -c " .. quoteArg("import sys; print('{}.{}.{}'.format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))")
    local versionRc, versionOut = execProcess(versionCmd, 12000)
    if versionRc ~= 0 or not versionOut or versionOut == "" then
        local h = io.popen(versionCmd .. " 2>&1")
        if h then
            versionOut = h:read("*a") or ""
            local ok, _, code = h:close()
            versionRc = (ok == true or code == 0) and 0 or (tonumber(code) or -1)
        end
    end

    local major, minor, patch = tostring(versionOut or ""):match("(%d+)%.(%d+)%.(%d+)")
    if not major or not minor then
        major, minor = tostring(versionOut or ""):match("(%d+)%.(%d+)")
    end
    local versionText = tostring(versionOut or ""):match("(%d+%.%d+%.%d+)") or tostring(versionOut or ""):match("(%d+%.%d+)")
    if versionRc ~= 0 or not major or not minor then
        debugLog("canRunPython " .. tostring(OS) .. ": version probe failed for " .. tostring(pythonCmd) .. " output=" .. tostring(versionOut))
        return false
    end
    major = tonumber(major) or 0
    minor = tonumber(minor) or 0
    if major == 3 and minor >= 10 and minor <= 12 then
        return true
    end
    debugLog("Rejecting unsupported " .. tostring(OS) .. " Python: " .. tostring(pythonCmd) .. " version=" .. tostring(versionText or (major .. "." .. minor)))
    return false
end

FFMPEG_PATH = nil

function canRunFfmpeg(path)
    local function tryPath(p)
        if not p or p == "" then return false end
        if isAbsolutePath(p) and not fileExists(p) then return false end
        local cmd = quoteArg(p) .. " -version"
        local rc, out = execProcess(cmd, 8000)
        if rc == 0 then
            local store = p
            if not isAbsolutePath(store) then
                local resolved = resolveCommandPath(store)
                if resolved then
                    store = resolved
                end
            end
            FFMPEG_PATH = store
            if reaper and reaper.SetExtState then
                reaper.SetExtState(EXT_SECTION, "ffmpegPath", tostring(store), true)
            end
            return true
        end
        return false
    end

    if path and path ~= "" then
        if tryPath(path) then
            return true
        end
    end

    local override = getExtStateValue("ffmpegPath")
    if override then
        local resolved = override
        if (not isAbsolutePath(resolved)) and resolved:find("[/\\]") then
            resolved = script_path .. resolved
        end
        if DEBUG.enabled then
            debugLog("canRunFfmpeg: override=" .. tostring(resolved))
        end
        -- Trust a valid absolute path without ExecProcess (avoids capture quirks).
        if isAbsolutePath(resolved) and fileExists(resolved) then
            FFMPEG_PATH = resolved
            if reaper and reaper.SetExtState then
                reaper.SetExtState(EXT_SECTION, "ffmpegPath", tostring(resolved), true)
            end
            return true
        end
        if tryPath(resolved) then
            return true
        end
    end

    if FFMPEG_PATH and tryPath(FFMPEG_PATH) then
        return true
    end

    local runtime = getRuntimePaths()
    local runtimeCandidates = {}
    if OS == "Windows" then
        table.insert(runtimeCandidates, runtime.runtimeBin .. "\\ffmpeg.exe")
        table.insert(runtimeCandidates, runtime.runtimeFfmpeg .. "\\bin\\ffmpeg.exe")
    else
        table.insert(runtimeCandidates, runtime.runtimeBin .. "/ffmpeg")
        table.insert(runtimeCandidates, runtime.runtimeFfmpeg .. "/bin/ffmpeg")
    end
    for _, p in ipairs(runtimeCandidates) do
        if tryPath(p) then return true end
    end

    if OS == "macOS" then
        local candidates = {
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
            "/usr/local/opt/ffmpeg/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        }
        for _, p in ipairs(candidates) do
            if tryPath(p) then return true end
        end
    elseif OS ~= "Windows" then
        local candidates = {
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/snap/bin/ffmpeg",
        }
        for _, p in ipairs(candidates) do
            if tryPath(p) then return true end
        end
    end

    if tryPath("ffmpeg") then
        return true
    end

    if OS ~= "Windows" then
        local ok = os.execute("ffmpeg -version >/dev/null 2>&1")
        if ok == true or ok == 0 then
            FFMPEG_PATH = resolveCommandPath("ffmpeg") or "ffmpeg"
            return true
        end
        return false
    end

    local candidates = {}
    local localAppData = os.getenv("LOCALAPPDATA") or ""
    local programFiles = os.getenv("ProgramFiles") or "C:\\Program Files"
    local programFilesX86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    table.insert(candidates, localAppData .. "\\Programs\\ffmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, localAppData .. "\\ffmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, "C:\\ffmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, programFiles .. "\\FFmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, programFiles .. "\\ffmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, programFilesX86 .. "\\FFmpeg\\bin\\ffmpeg.exe")
    table.insert(candidates, programFilesX86 .. "\\ffmpeg\\bin\\ffmpeg.exe")

    for _, p in ipairs(candidates) do
        if tryPath(p) then return true end
    end

    if reaper and reaper.EnumerateSubdirectories then
        local winGetBase = localAppData .. "\\Microsoft\\WinGet\\Packages"
        local idx = 0
        while true do
            local dir = reaper.EnumerateSubdirectories(winGetBase, idx)
            if not dir then break end
            if dir:match("^Gyan%.FFmpeg_") then
                local base = winGetBase .. "\\" .. dir
                local j = 0
                while true do
                    local sub = reaper.EnumerateSubdirectories(base, j)
                    if not sub then break end
                    if sub:match("^ffmpeg%-%d") then
                        local candidate = base .. "\\" .. sub .. "\\bin\\ffmpeg.exe"
                        if tryPath(candidate) then
                            return true
                        end
                    end
                    j = j + 1
                end
            end
            idx = idx + 1
        end
    end

    local function listDirs(pattern)
        local baseTemp = (SW_LOG and SW_LOG.getTempBase and SW_LOG.getTempBase()) or os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
        local outPath = baseTemp .. "\\STEMwerk_dir_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
        local cmd = 'cmd.exe /S /C dir /b /ad ' .. quoteArg(pattern) .. ' > ' .. quoteArg(outPath)
        if DEBUG.enabled then
            debugLog("canRunFfmpeg: dir cmd=" .. tostring(cmd))
        end
        execHidden(cmd)
        local f = io.open(outPath, "r")
        if not f then return nil end
        local out = f:read("*a") or ""
        f:close()
        os.remove(outPath)
        if out == "" then return nil end
        local dirs = {}
        for line in out:gmatch("[^\r\n]+") do
            if line and line ~= "" and not line:match("[Ff]ile Not Found") then
                dirs[#dirs + 1] = line
            end
        end
        if #dirs == 0 then return nil end
        return dirs
    end

    local winGetBase = localAppData .. "\\Microsoft\\WinGet\\Packages"
    local pkgDirs = listDirs(winGetBase .. "\\Gyan.FFmpeg_*")
    if pkgDirs then
        for _, pkg in ipairs(pkgDirs) do
            local base = pkg:match("^%a:[/\\]") and pkg or (winGetBase .. "\\" .. pkg)
            local subDirs = listDirs(base .. "\\ffmpeg-*")
            if subDirs then
                for _, sub in ipairs(subDirs) do
                    local subBase = sub:match("^%a:[/\\]") and sub or (base .. "\\" .. sub)
                    local candidate = subBase .. "\\bin\\ffmpeg.exe"
                    if tryPath(candidate) then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function checkNumpyCompat(pythonPath)
    if not pythonPath or pythonPath == "" then return true, nil end
    local function escapePythonString(s)
        s = tostring(s or "")
        s = s:gsub("\\", "\\\\")
        s = s:gsub("'", "\\'")
        return s
    end
    local tempBase
    if OS == "Windows" then
        tempBase = (SW_LOG and SW_LOG.getTempBase and SW_LOG.getTempBase()) or os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
    else
        tempBase = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    end
    local sep = PATH_SEP or (OS == "Windows" and "\\" or "/")
    local outPath = tempBase .. sep .. "STEMwerk_numpy_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
    local py = "import numpy,sys; f=open('" .. escapePythonString(outPath) .. "','w'); f.write(numpy.__version__); f.close()"
    local cmd = quoteArg(pythonPath) .. " -c " .. quoteArg(py)
    local rc, out = execProcess(cmd, 12000)
    out = out or ""
    local ver = nil
    local f = io.open(outPath, "r")
    if f then
        local line = f:read("*l") or ""
        f:close()
        os.remove(outPath)
        if line ~= "" then ver = line:match("(%d+%.%d+%.%d+)") end
    end
    if rc ~= 0 or not ver then
        if out:lower():find("no module named 'numpy'", 1, true) then
            return false, "NumPy is not installed."
        end
        if rc == 0 and not ver then return true, nil end
        local extra = out ~= "" and ("\nOutput:\n" .. tostring(out)) or "\nOutput: (none)"
        return false, "Unable to detect NumPy version." .. extra
    end
    local major, minor = ver:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if major and minor and (major > 2 or (major == 2 and minor >= 4)) then
        return false, "NumPy " .. tostring(ver) .. " is not supported by Numba (requires < 2.4)."
    end
    return true, nil
end

-- Configuration - Auto-detect paths (cross-platform)
local function findPython()
    local override = getExtStateValue("pythonPath")
    if override then
        local resolved = override
        if (not isAbsolutePath(resolved)) and resolved:find("[/\\]") then
            -- Allow relative overrides (relative to this script folder)
            resolved = script_path .. resolved
        end

        -- On macOS, still verify the version: a bare python3 symlink can jump to 3.13+.
        if isAbsolutePath(resolved) and fileExists(resolved) then
            if canRunPython(resolved) then
                debugLog("pythonPath override exists, accepting: " .. tostring(resolved))
                return resolved
            end
            debugLog("pythonPath override exists but is not supported: " .. tostring(resolved))
        end

        if not isAbsolutePath(resolved) then
            local resolvedCmd = resolveCommandPath(resolved)
            if resolvedCmd and fileExists(resolvedCmd) and canRunPython(resolvedCmd) then
                return resolvedCmd
            end
        end

        -- Otherwise fall back to attempting to run the command to verify it.
        if (not isAbsolutePath(resolved) and canRunPython(resolved)) or (isAbsolutePath(resolved) and fileExists(resolved) and canRunPython(resolved)) then
            return resolved
        end
        debugLog("pythonPath override not runnable: " .. tostring(resolved))
        -- Save detailed override diagnostics to repo-visible file for debugging permissions/quoting issues
        local dbgPath = script_path .. "python_override_test.txt"
        local f = io.open(dbgPath, "w")
        if f then
            f:write("python override: " .. tostring(resolved) .. "\n")
            f:write("fileExists: " .. tostring(fileExists(resolved)) .. "\n")
            -- Attempt to run via reaper.ExecProcess if available
            if reaper and reaper.ExecProcess then
                local raw = reaper.ExecProcess(quoteArg(resolved) .. " --version", 8000)
                local rc, out = nil, ""
                if type(raw) == "string" then
                    local firstLine, rest = raw:match("^([^\r\n]*)\r?\n?(.*)$")
                    rc = tonumber(firstLine)
                    out = (rc ~= nil) and (rest or "") or raw
                end
                f:write("ExecProcess rc=" .. tostring(rc) .. " outLen=" .. tostring(out and #out or 0) .. "\n")
                f:write("ExecProcess out:\n" .. tostring(out) .. "\n")
            end
            -- Try io.popen (may be blocked in some environments)
            local okOut = nil
            local h = io.popen('"' .. tostring(resolved) .. '" --version 2>&1')
            if h then
                okOut = h:read("*a") or ""
                local ok, _, code = h:close()
                f:write("io.popen rc=" .. tostring(code) .. " outLen=" .. tostring(#okOut) .. "\n")
                f:write("io.popen out:\n" .. tostring(okOut) .. "\n")
            else
                f:write("io.popen not available\n")
            end
            f:close()
        end
    end

    local paths = {}
    local home = getHome()
    local runtime = getRuntimePaths()

    if OS == "Windows" then
        table.insert(paths, runtime.venvPython)
        -- Conda (recommended on Windows): if REAPER was started from an activated env,
        -- CONDA_PREFIX points to it.
        local condaPrefix = os.getenv("CONDA_PREFIX") or ""
        if condaPrefix ~= "" then
            table.insert(paths, condaPrefix .. "\\python.exe")
        end
        -- Common Miniconda env fallback (adjust env name if needed)
        table.insert(paths, home .. "\\Miniconda3\\envs\\stemwerk\\python.exe")
        -- Windows paths - check venvs first
        -- Prefer workspace GPU venv first, then regular venv: allow .venv-gpu for GPU-capable env
        table.insert(paths, script_path .. "..\\..\\.venv-gpu\\Scripts\\python.exe")
        -- Prefer workspace venv: <repo>/.venv (two levels up from scripts/reaper/)
        table.insert(paths, script_path .. "..\\..\\.venv\\Scripts\\python.exe")
        table.insert(paths, script_path .. ".venv\\Scripts\\python.exe")
        table.insert(paths, home .. "\\Documents\\STEMwerk\\.venv\\Scripts\\python.exe")
        table.insert(paths, "C:\\Users\\Administrator\\Documents\\STEMwerk\\.venv-gpu\\Scripts\\python.exe")
        table.insert(paths, "C:\\Users\\Administrator\\Documents\\STEMwerk\\.venv\\Scripts\\python.exe")
        table.insert(paths, home .. "\\.STEMwerk\\.venv\\Scripts\\python.exe")
        table.insert(paths, script_path .. "..\\..\\..\\venv\\Scripts\\python.exe")
        -- Standard Python locations
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        table.insert(paths, localAppData .. "\\Programs\\Python\\Python311\\python.exe")
        table.insert(paths, localAppData .. "\\Programs\\Python\\Python310\\python.exe")
        table.insert(paths, localAppData .. "\\Programs\\Python\\Python312\\python.exe")
        -- Program Files (system installs)
        local programFiles = os.getenv("ProgramFiles") or "C:\\Program Files"
        local programFilesX86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
        table.insert(paths, programFiles .. "\\Python311\\python.exe")
        table.insert(paths, programFiles .. "\\Python310\\python.exe")
        table.insert(paths, programFilesX86 .. "\\Python311\\python.exe")
        table.insert(paths, programFilesX86 .. "\\Python310\\python.exe")
        -- Windows Store/App Execution Alias (if enabled)
        table.insert(paths, localAppData .. "\\Microsoft\\WindowsApps\\python.exe")
        table.insert(paths, localAppData .. "\\Microsoft\\WindowsApps\\python3.exe")
        table.insert(paths, "python")
    else
        -- Linux/macOS paths - check venvs first
        -- Prefer workspace venv: <repo>/.venv (two levels up from scripts/reaper/)
        table.insert(paths, runtime.venvPython)
        table.insert(paths, script_path .. "../../.venv/bin/python")
        table.insert(paths, script_path .. ".venv/bin/python")
        table.insert(paths, home .. "/.STEMwerk/.venv/bin/python")
        table.insert(paths, script_path .. "../.venv/bin/python")
        -- Homebrew on macOS
        if OS == "macOS" then
            table.insert(paths, "/opt/homebrew/opt/python@3.12/libexec/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.12/libexec/bin/python3")
            table.insert(paths, "/opt/homebrew/opt/python@3.12/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.12/bin/python3")
            table.insert(paths, "/opt/homebrew/bin/python3.12")
            table.insert(paths, "/usr/local/bin/python3.12")
            table.insert(paths, "python3.12")
            table.insert(paths, "/opt/homebrew/opt/python@3.11/libexec/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.11/libexec/bin/python3")
            table.insert(paths, "/opt/homebrew/opt/python@3.11/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.11/bin/python3")
            table.insert(paths, "/opt/homebrew/bin/python3.11")
            table.insert(paths, "/usr/local/bin/python3.11")
            table.insert(paths, "python3.11")
            table.insert(paths, "/opt/homebrew/opt/python@3.10/libexec/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.10/libexec/bin/python3")
            table.insert(paths, "/opt/homebrew/opt/python@3.10/bin/python3")
            table.insert(paths, "/usr/local/opt/python@3.10/bin/python3")
            table.insert(paths, "/opt/homebrew/bin/python3.10")
            table.insert(paths, "/usr/local/bin/python3.10")
            table.insert(paths, "python3.10")
            table.insert(paths, "/usr/local/opt/python@3.11/bin/python3")
            table.insert(paths, "/opt/homebrew/bin/python3")
            table.insert(paths, "/usr/local/bin/python3")
            table.insert(paths, "/usr/bin/python3")
            table.insert(paths, "python3")
        end
        -- User local and system paths
        if OS ~= "macOS" then
            table.insert(paths, home .. "/.local/bin/python3")
            table.insert(paths, "/usr/local/bin/python3.11")
            table.insert(paths, "/usr/bin/python3.11")
            table.insert(paths, "/usr/local/bin/python3.12")
            table.insert(paths, "/usr/bin/python3.12")
            table.insert(paths, "/usr/local/bin/python3")
            table.insert(paths, "/usr/bin/python3")
            table.insert(paths, "/snap/bin/python3")
            table.insert(paths, "python3")
            table.insert(paths, "python")
        end
    end

    for _, p in ipairs(paths) do
        if p == "python" or p == "python3" then
            local resolved = resolveCommandPath(p)
            if resolved and fileExists(resolved) and canRunPython(resolved) then
                return resolved
            end
            if canRunPython(p) then return p end
        else
            if fileExists(p) and canRunPython(p) then return p end
        end
    end

    local fallback = OS == "Windows" and "python" or (OS == "macOS" and "" or "python3")
    return fallback
end

function getFastStartupPythonPath()
    if OS ~= "Windows" then
        local detected = findPython()
        if type(SW_SETUP.resolveRuntimePythonPath) == "function" then
            local resolved = SW_SETUP.resolveRuntimePythonPath()
            if resolved and resolved ~= "" then
                detected = resolved
            end
        end
        return detected
    end

    -- Windows cold-start must stay cheap: prefer already-known runtime paths and
    -- avoid eager `python --version` checks before the first UI frame is visible.
    if type(SW_SETUP.resolveRuntimePythonPath) == "function" then
        local resolved = SW_SETUP.resolveRuntimePythonPath()
        if resolved and resolved ~= "" then
            return resolved
        end
    end

    local override = getExtStateValue("pythonPath")
    if override and override ~= "" then
        return override
    end

    local runtime = getRuntimePaths()
    if runtime and runtime.venvPython and runtime.venvPython ~= "" and fileExists(runtime.venvPython) then
        return runtime.venvPython
    end

    return "python"
end

local function findSeparatorScript()
    local override = getExtStateValue("separatorScript")
    if override then
        local resolved = override
        if not isAbsolutePath(resolved) then
            resolved = script_path .. resolved
        end
        if fileExists(resolved) then
            return resolved
        end
        debugLog("separatorScript override not found: " .. tostring(resolved))
    end

    local scriptsDir = getInstallScriptsDir()
    local paths = {
        script_path .. "audio_separator_process.py",
        scriptsDir .. "audio_separator_process.py",
    }
    for _, p in ipairs(paths) do
        if fileExists(p) then return p end
    end
    return script_path .. "audio_separator_process.py"
end

function refreshPythonPathFromExtState()
    if OS ~= "macOS" then return end
    local override = getExtStateValue("pythonPath")
    if not override or override == "" then return end
    local resolved = override
    if (not isAbsolutePath(resolved)) and resolved:find("[/\\]") then
        resolved = script_path .. resolved
    end
    if isAbsolutePath(resolved) and fileExists(resolved) and canRunPython(resolved) then
        if resolved ~= PYTHON_PATH then
            PYTHON_PATH = resolved
            debugLog("Refreshed pythonPath from ExtState: " .. tostring(PYTHON_PATH))
        end
    end
end

PYTHON_PATH = nil
SEPARATOR_SCRIPT = nil

local BOOTSTRAP_ACTIVE = false
local DEP_STATUS = { state = "unknown", detail = nil, prompted = false, updatedAt = nil }

local function setDepState(state, detail)
    DEP_STATUS.state = state or "unknown"
    DEP_STATUS.detail = detail
    DEP_STATUS.updatedAt = os.time()
    DEP_STATUS.prompted = DEP_STATUS.prompted or false
end

SW_SETUP.configure({
    OS = OS,
    PATH_SEP = PATH_SEP,
    script_path = script_path,
    debugLog = debugLog,
    logExecResult = SW_LOG.logExecResult,
    fileExists = fileExists,
    getHome = getHome,
    getExtStateValue = getExtStateValue,
    setExtStateValue = setExtStateValue,
    isAbsolutePath = isAbsolutePath,
    quoteArg = quoteArg,
    execProcess = execProcess,
    canRunPython = canRunPython,
    canRunFfmpeg = canRunFfmpeg,
    findPython = findPython,
    findSeparatorScript = findSeparatorScript,
    setPythonPath = function(path)
        PYTHON_PATH = path
    end,
    setSeparatorScript = function(path)
        SEPARATOR_SCRIPT = path
    end,
    getPythonPath = function()
        return PYTHON_PATH
    end,
    getDepState = function()
        return DEP_STATUS
    end,
    setDepState = setDepState,
    getBootstrapActive = function()
        return BOOTSTRAP_ACTIVE
    end,
    setBootstrapActive = function(active)
        BOOTSTRAP_ACTIVE = active and true or false
    end,
    showMessageBox = function(title, text, type)
        if reaper and reaper.ShowMessageBox then
            return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
        end
        return 0
    end,
    SW_LOG = SW_LOG,
})

ensureWritableDir = SW_SETUP.ensureWritableDir
getRuntimeBase = SW_SETUP.getRuntimeBase
getRuntimePaths = SW_SETUP.getRuntimePaths
resolveCommandPath = SW_SETUP.resolveCommandPath
canImportAudioSeparator = SW_SETUP.canImportAudioSeparator
safeDofile = SW_SETUP.safeDofile
isPythonAvailable = SW_SETUP.isPythonAvailable
runSetup = SW_SETUP.runSetup
verifyRuntimeAfterBootstrap = SW_SETUP.verifyRuntimeAfterBootstrap
ensureDependenciesInteractive = SW_SETUP.ensureDependenciesInteractive
persistPythonPath = SW_SETUP.persistPythonPath
readCapabilities = SW_SETUP.readCapabilities

PYTHON_PATH = getFastStartupPythonPath()
SEPARATOR_SCRIPT = findSeparatorScript()

debugLog("Detected Python: " .. tostring(PYTHON_PATH))
debugLog("Detected separator script: " .. tostring(SEPARATOR_SCRIPT))

-- Persist the chosen Python path into REAPER ExtState so the launcher uses it
if OS ~= "Windows" then
    persistPythonPath(PYTHON_PATH)
end

-- Shorten vendor-prefixed GPU names for UI (e.g. "AMD Radeon RX 9070" -> "RX 9070").
local function sanitizeFriendlyName(name)
    if not name then return name end
    local raw = tostring(name)
    local lbl = raw
    lbl = lbl:gsub("^%s+", "")
    lbl = lbl:gsub("%(%s*[Tt][Mm]%s*%)", "")
    lbl = lbl:gsub("%(%s*[Rr]%s*%)", "")
    lbl = lbl:gsub("[Aa][Mm][Dd]%s*[Rr]adeon%s*", "")
    lbl = lbl:gsub("[Nn][Vv][Ii][Dd][Ii][Aa]%s*[Gg]e[Ff]orce%s*", "")
    lbl = lbl:gsub("[Nn][Vv][Ii][Dd][Ii][Aa]%s*", "")
    lbl = lbl:gsub("[Ii][Nn][Tt][Ee][Ll]%s*", "")
    lbl = lbl:gsub("%(%s*[Ee]xternal%s*%)", "eGPU")
    lbl = lbl:gsub("%(%s*[Ii]nternal%s*%)", "iGPU")
    lbl = lbl:gsub("%s*[Ll]aptop%s*[Gg]PU%s*$", "")
    lbl = lbl:gsub("%s*[Gg]raphics%s*$", "")
    lbl = lbl:gsub("%s*[Gg]PU%s*$", "")
    lbl = lbl:gsub("%s+", " ")
    lbl = lbl:gsub("^%s+", ""):gsub("%s+$", "")
    if lbl == "" or lbl:match("^%(%s*[Tt][Mm]%s*%)$") or #lbl < 3 then
        local fallback = raw
        fallback = fallback:gsub("%(%s*[Tt][Mm]%s*%)", "")
        fallback = fallback:gsub("%(%s*[Rr]%s*%)", "")
        fallback = fallback:gsub("^%s+", ""):gsub("%s+$", "")
        fallback = fallback:gsub("^[Aa][Mm][Dd]%s+", "")
        fallback = fallback:gsub("^[Nn][Vv][Ii][Dd][Ii][Aa]%s+", "")
        fallback = fallback:gsub("%s+", " ")
        lbl = fallback ~= "" and fallback or raw
    end
    return lbl
end

-- Stem configuration (with selection state)
-- First 4 are always shown, Guitar/Piano only for 6-stem model
STEMS = {
    { name = "Vocals", color = {255, 100, 100}, file = "vocals.wav", selected = true, key = "1", sixStemOnly = false },
    { name = "Drums",  color = {100, 200, 255}, file = "drums.wav", selected = true, key = "2", sixStemOnly = false },
    { name = "Bass",   color = {150, 100, 255}, file = "bass.wav", selected = true, key = "3", sixStemOnly = false },
    { name = "Other",  color = {100, 255, 150}, file = "other.wav", selected = true, key = "4", sixStemOnly = false },
    { name = "Guitar", color = {255, 180, 80},  file = "guitar.wav", selected = true, key = "5", sixStemOnly = true },
    { name = "Piano",  color = {255, 120, 200}, file = "piano.wav", selected = true, key = "6", sixStemOnly = true },
}

-- Available processing devices
DEVICES = {
    { id = "auto", name = "Auto", desc = "Automatically select best GPU" },
    { id = "cpu", name = "CPU", desc = "Force CPU processing (slower)" },
    -- Generic GPU entries (unverified) so users can manually choose a GPU
    -- when the runtime probe fails.
    { id = "directml:0", name = "DirectML 0", type = "directml", desc = "DirectML GPU 0 (unverified)" },
    { id = "directml:1", name = "DirectML 1", type = "directml", desc = "DirectML GPU 1 (unverified)" },
    { id = "cuda:0", name = "CUDA 0", type = "cuda", desc = "CUDA GPU 0 (unverified)" },
    { id = "cuda:1", name = "CUDA 1", type = "cuda", desc = "CUDA GPU 1 (unverified)" },
}

RUNTIME_DEVICES = nil
RUNTIME_DEVICE_LAST_PROBE = 0
RUNTIME_DIRECTML_POSSIBLE = nil
RUNTIME_CUDA_COUNT = nil
RUNTIME_DEVICE_NOTE_KEY = nil
RUNTIME_DEVICE_SKIP_NOTE = nil
RUNTIME_DEVICE_PROBE_DEBUG = nil
RUNTIME_DEVICE_PROBE = nil

-- Available models
local MODELS = {
    { id = "htdemucs", name = "Fast", desc = "htdemucs - Fastest model, good quality (4 stems)" },
    { id = "htdemucs_ft", name = "Quality", desc = "htdemucs_ft - Best quality, slower (4 stems)" },
    { id = "htdemucs_6s", name = "6-Stem", desc = "htdemucs_6s - Adds Guitar & Piano separation" },
}

MODEL_AVAILABILITY = {
    bundledLimited = false,
    byId = {},
}

do
    local KNOWN_MODEL_IDS = {
        htdemucs = true,
        htdemucs_ft = true,
        htdemucs_6s = true,
    }

    local function parseModelAllowlist(raw)
        if not raw or raw == "" then return nil end
        local out = {}
        for token in tostring(raw):gmatch("[^,%s]+") do
            local modelId = tostring(token):gsub("^['\"]", ""):gsub("['\"]$", "")
            if KNOWN_MODEL_IDS[modelId] then
                out[modelId] = true
            end
        end
        if next(out) then
            return out
        end
        return nil
    end

    local function readModelAllowlistFromFile(path)
        if not path or path == "" then return nil end
        local f = io.open(path, "r")
        if not f then return nil end
        local raw = f:read("*a") or ""
        f:close()
        return parseModelAllowlist(raw)
    end

    local function getInstallerModelAllowlist()
        -- Restrict models only when an explicit allowlist is present.
        local envAllow = parseModelAllowlist(os.getenv("STEMWERK_MODEL_ALLOWLIST"))
        if envAllow then
            return envAllow
        end

        local bundledRoot = script_path .. "_bundled"
        local allowlist = readModelAllowlistFromFile(bundledRoot .. PATH_SEP .. "model_allowlist.txt")
            or readModelAllowlistFromFile(bundledRoot .. PATH_SEP .. "model-allowlist.txt")
        return allowlist
    end

    local function getFirstAvailableModelId()
        for _, model in ipairs(MODELS) do
            if isModelAvailableInCurrentMode(model.id) then
                return model.id
            end
        end
        return MODELS[1] and MODELS[1].id or "htdemucs"
    end

    function refreshModelAvailability()
        local allowlist = getInstallerModelAllowlist()
        local limitToAllowlist = allowlist ~= nil
        MODEL_AVAILABILITY.bundledLimited = limitToAllowlist

        local byId = {}
        if limitToAllowlist then
            for _, model in ipairs(MODELS) do
                byId[model.id] = allowlist[model.id] and true or false
            end
        else
            for _, model in ipairs(MODELS) do
                byId[model.id] = true
            end
        end

        MODEL_AVAILABILITY.byId = byId
    end

    function isModelAvailableInCurrentMode(modelId)
        if not MODEL_AVAILABILITY.bundledLimited then
            return true
        end
        return MODEL_AVAILABILITY.byId[tostring(modelId or "")] and true or false
    end

    function ensureSelectedModelIsAvailable()
        if isModelAvailableInCurrentMode(SETTINGS and SETTINGS.model) then
            return false
        end
        return false
    end

    function ensureSelectedModelIsAvailableAndFallback()
        if isModelAvailableInCurrentMode(SETTINGS and SETTINGS.model) then
            return false
        end
        SETTINGS.model = getFirstAvailableModelId()
        return true
    end

    function unavailableModelTooltipSuffix()
        return T("model_unavailable_variant_suffix") or "Not included in this installer variant."
    end
end

SETTINGS = {
    model = "htdemucs",
    createNewTracks = true,
    createFolder = false,
    outputGrouping = "per_item", -- "per_item" (default) or "source_track" (New Tracks grouping)
    applyTrackColors = true,
    colorMode = "both", -- "both", "no_track", "no_media", "off"
    stemFileDestination = "temp", -- "temp", "project_media", "custom"
    customStemDir = "",
    -- Post-processing for in-place output (treat the resulting multi-take item)
    -- Values: "none", "explode_new_tracks", "explode_in_place", "explode_in_order"
    postProcessTakes = "none",
    muteOriginal = false,      -- Mute original item(s) after separation
    muteSelection = false,     -- Mute only the selection portion (splits item)
    deleteOriginal = false,
    deleteSelection = false,   -- Delete only the selection portion (splits item)
    deleteOriginalTrack = false,
    muteOriginalTrack = false, -- Mute original track(s) after separation
    darkMode = true,           -- Dark/Light theme toggle
    themePreset = "reaper_native", -- Default: REAPER Native. User can switch to Visual via [UI].
    parallelProcessing = true, -- Process multiple tracks in parallel (uses more GPU memory)
    language = "en",           -- UI language: en, nl, de
    visualFX = true,           -- Enable/disable visual effects (procedural art backgrounds)
    tooltips = true,           -- Global tooltip toggle
    keepTempFiles = false,     -- Keep temp audio/work files after a run (logs always preserved)
    device = "auto",           -- Device selection: "auto", "cpu", "cuda:0", "cuda:1", "directml"
}

local function normalizeOutputGrouping(value)
    local v = tostring(value or ""):lower()
    if v == "source_track" then
        return "source_track"
    end
    return "per_item"
end

-- ========== INTERNATIONALIZATION (i18n) ==========

-- i18n: load from extracted module
local I18N = dofile(script_path .. "_internal/STEMwerk_I18N.lua")
local loadLanguages = I18N.loadLanguages
local _setLanguageRaw = I18N.setLanguage
local function setLanguage(code)
    if SETTINGS then SETTINGS.language = code end
    return _setLanguageRaw(code)
end
T = I18N.T
local trPlural = I18N.trPlural
local getAvailableLanguages = I18N.getAvailableLanguages

local function getProcessingWindowTitle()
    local label = (type(T) == "function" and T("window_title_processing")) or "Processing.."
    return "STEMwerk - " .. tostring(label) .. " (v" .. APP_VERSION .. ")"
end

local function getCompleteWindowTitle()
    local label = (type(T) == "function" and T("window_title_complete")) or "Complete"
    return "STEMwerk - " .. tostring(label) .. " (v" .. APP_VERSION .. ")"
end

local function getMultiTrackWindowTitle()
    local label = (type(T) == "function" and T("window_title_multi_track")) or "Multi-Track Progress"
    return "STEMwerk - " .. tostring(label) .. " (v" .. APP_VERSION .. ")"
end

-- Forward declare GUI so early helpers (e.g. handleArtAdvance) can reference it safely.

local UI_Window = dofile(script_path .. "_internal/STEMwerk_UI_Window.lua")
local UI_TOKENS = dofile(script_path .. "_internal/STEMwerk_UI_Tokens.lua")
local UI_CONTROLS = dofile(script_path .. "_internal/STEMwerk_UI_Controls.lua")
local UI_BACKGROUNDS = dofile(script_path .. "_internal/STEMwerk_UI_Backgrounds.lua")
local UI_HELP_LAYOUT    = dofile(script_path .. "_internal/STEMwerk_UI_HelpLayout.lua")
local UI_PROGRESS       = dofile(script_path .. "_internal/STEMwerk_Progress_Render.lua")
local UI_PATH_INPUT     = dofile(script_path .. "_internal/STEMwerk_UI_PathInput.lua")

-- Get list of available languages
local function getAvailableLanguages()
    if not LANGUAGES then loadLanguages() end
    local langs = {}
    if LANGUAGES then
        for code, _ in pairs(LANGUAGES) do
            table.insert(langs, code)
        end
    end
    table.sort(langs)
    return langs
end

SETTINGS_MOD = loadModule(script_path .. "_internal/STEMwerk_Settings.lua", "STEMwerk_Settings")
DEVICE_RUNTIME = loadModule(script_path .. "_internal/STEMwerk_Devices.lua", "STEMwerk_Devices")
local SW_UI = dofile(script_path .. "_internal/STEMwerk_UI.lua")
-- No configure() needed: THEME, updateTheme, saveSettings, T, SETTINGS, LANG are globals.

normalizeColorMode = SETTINGS_MOD.normalizeColorMode
runtimeDeviceSafeList = DEVICE_RUNTIME.runtimeDeviceSafeList
backendTypeLabel = DEVICE_RUNTIME.backendTypeLabel
applyRuntimeDevicesFromParsed = DEVICE_RUNTIME.applyRuntimeDevicesFromParsed
startRuntimeDeviceProbeAsync = DEVICE_RUNTIME.startRuntimeDeviceProbeAsync
pollRuntimeDeviceProbe = DEVICE_RUNTIME.pollRuntimeDeviceProbe
refreshRuntimeDevices = DEVICE_RUNTIME.refreshRuntimeDevices
applyCachedRuntimeDevices = DEVICE_RUNTIME.applyCachedRuntimeDevices
getTrustedWindowsRuntimeState = DEVICE_RUNTIME.getTrustedWindowsRuntimeState
applyTrustedWindowsRuntimeState = DEVICE_RUNTIME.applyTrustedWindowsRuntimeState
normalizeRequestedDeviceForRuntime = DEVICE_RUNTIME.normalizeRequestedDeviceForRuntime

-- Initialize theme (must run after SETTINGS is loaded)
updateTheme()

-- GUI state
GUI = {
    running = false,
    result = nil,
    wasMouseDown = false,
    logoWasClicked = false,
    -- Scaling
    baseW = 340,
    baseH = 346,
    minW = 340,
    minH = 346,
    maxW = 1360,  -- Up to 4x scale
    maxH = 1384,
    scale = 1.0,
    -- Tooltip
    tooltip = nil,
    tooltipX = 0,
    tooltipY = 0,
}
_G.GUI = GUI

-- Store last dialog position for subsequent windows (progress, result, messages)
lastDialogX, lastDialogY, lastDialogW, lastDialogH = nil, nil, 840, 600

-- Track auto-selected items and tracks for restore on cancel
autoSelectedItems = {}
autoSelectionTracks = {}  -- Tracks that were selected when we auto-selected items

-- Store playback state to restore after processing
savedPlaybackState = 0  -- 0=stopped, 1=playing, 2=paused, 5=recording, 6=record paused

-- Guard against multiple concurrent runs (MUST be defined before any functions use it)
isProcessingActive = false

-- Time selection mode state (declared early for visibility in dialogLoop)
timeSelectionMode = false  -- true when processing time selection instead of item
timeSelectionStart = nil   -- Start time of selection
timeSelectionEnd = nil     -- End time of selection

-- One-shot: after in-place processing that keeps takes, shift keyboard focus back to REAPER
-- when the main dialog re-opens so the user can press T to cycle takes.
focusReaperAfterMainOpenOnce = false

-- Items eligible for one-shot post-processing after in-place separation
-- (lets user choose an explode mode after the run, without re-processing).
postProcessCandidates = {}

-- Forward declaration for run-config helpers (actual table is initialized later).
local multiTrackQueue

-- Run configuration snapshot: keeps model/device/mode stable for one workflow run.
local ACTIVE_RUN_CONFIG = nil
local function captureActiveRunConfig()
    ACTIVE_RUN_CONFIG = {
        model = tostring(SETTINGS and SETTINGS.model or "htdemucs"),
        device = tostring(SETTINGS and SETTINGS.device or "auto"),
        requestedParallel = (SETTINGS and SETTINGS.parallelProcessing) and true or false,
    }
end

local function hasActiveRunConfig()
    if not ACTIVE_RUN_CONFIG then return false end
    if isProcessingActive then return true end
    if multiTrackQueue and multiTrackQueue.active then return true end
    return false
end

local function effectiveRunModel()
    if hasActiveRunConfig() then
        return tostring(ACTIVE_RUN_CONFIG.model or "htdemucs")
    end
    return tostring(SETTINGS and SETTINGS.model or "htdemucs")
end

local function effectiveRunDevice()
    if hasActiveRunConfig() then
        return tostring(ACTIVE_RUN_CONFIG.device or "auto")
    end
    return tostring(SETTINGS and SETTINGS.device or "auto")
end

local function effectiveRunRequestedParallel()
    if hasActiveRunConfig() then
        return ACTIVE_RUN_CONFIG.requestedParallel and true or false
    end
    return (SETTINGS and SETTINGS.parallelProcessing) and true or false
end

local KNOWN_MPS_UNSUPPORTED_MARKER = "STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536"

local function isKnownMpsUnsupportedFailure(logSnippet)
    local text = string.lower(tostring(logSnippet or ""))
    if text == "" then return false end
    if text:find(string.lower(KNOWN_MPS_UNSUPPORTED_MARKER), 1, true) then
        return true
    end
    return text:find("output channels > 65536 not supported at the mps device", 1, true) ~= nil
end

local function buildKnownSeparationFailureMessage(logSnippet, exitCode, cmdLine, logPath, debugLogPath, stdoutSnippet)
    local lowerLog = string.lower(tostring(logSnippet or ""))
    if lowerLog:find("error_stage=stage2_preflight", 1, true)
        and lowerLog:find("error_reason=drumsep_model_missing", 1, true) then
        local requested = tostring(logSnippet or ""):match("requested_model=([^\r\n]+)") or DKS_WORKFLOW.DIRECT_DKS_MODEL
        local msg = "Direct Drum Kit Split preflight failed.\n"
            .. "Reason: drumsep_model_missing\n"
            .. "Requested model: " .. tostring(requested)
            .. "\nerror_stage=stage2_preflight\n"
            .. "error_reason=drumsep_model_missing"
            .. "\n\nThe current audio-separator model catalog/runtime cannot resolve this DrumSep model.\n"
            .. "Update/repair the STEMwerk runtime model catalog, then retry."
            .. "\n\nExit code: " .. tostring(exitCode or "unknown")
            .. "\nCommand: " .. tostring(cmdLine or "unknown")
            .. "\nPython log (" .. tostring(logPath or "unknown") .. "):\n"
            .. tostring(logSnippet or "(no log output found)")
            .. "\n\nDebug log: " .. tostring(debugLogPath or SW_LOG.getLogPath())
        if stdoutSnippet and stdoutSnippet ~= "" then
            msg = msg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
        end
        return msg
    end

    local function modelCachePathHint()
        if OS == "macOS" then
            return "~/Library/Application Support/STEMwerk/models/"
        end
        if OS == "Windows" then
            return "%APPDATA%/STEMwerk/models/ (or current runtime app-data path)"
        end
        return "~/.local/share/STEMwerk/models/"
    end

    if SW_LOG and SW_LOG.classifyModelFailure then
        local failure = SW_LOG.classifyModelFailure(logSnippet, stdoutSnippet)
        if failure then
            local msg = "Model download/load failed.\n"
                .. tostring(failure.error_hint or "Model download failed or timed out. Check your internet connection and retry.")
                .. "\n\nModel cache folder:\n"
                .. modelCachePathHint()
                .. "\n\n"
                .. tostring(failure.model_cache_hint or "Delete corrupted/partial files in the STEMwerk models folder and retry.")
                .. "\n\nExit code: " .. tostring(exitCode or "unknown")
                .. "\nCommand: " .. tostring(cmdLine or "unknown")
                .. "\nPython log (" .. tostring(logPath or "unknown") .. "):\n"
                .. tostring(logSnippet or "(no log output found)")
                .. "\n\nDebug log: " .. tostring(debugLogPath or SW_LOG.getLogPath())
            if failure.model_url then
                msg = msg .. "\n\nModel URL: " .. tostring(failure.model_url)
            end
            if failure.model_path then
                msg = msg .. "\nModel file: " .. tostring(failure.model_path)
            end
            if stdoutSnippet and stdoutSnippet ~= "" then
                msg = msg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
            end
            return msg
        end
    end

    if not isKnownMpsUnsupportedFailure(logSnippet) then
        return nil
    end

    local msg = "Apple MPS failed because this model hits a PyTorch MPS limitation.\n"
        .. "Please use CPU for now.\n\n"
        .. "Exit code: " .. tostring(exitCode or "unknown") .. "\n"
        .. "Command: " .. tostring(cmdLine or "unknown") .. "\n"
        .. "Python log (" .. tostring(logPath or "unknown") .. "):\n"
        .. tostring(logSnippet or "(no log output found)")
        .. "\n\nDebug log: " .. tostring(debugLogPath or SW_LOG.getLogPath())

    if stdoutSnippet and stdoutSnippet ~= "" then
        msg = msg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
    end

    return msg
end

local function isEffectiveRun6Stem()
    return effectiveRunModel() == "htdemucs_6s"
end

stemIsSelectableForCurrentModel = function(stem)
    return stem and ((not stem.sixStemOnly) or isEffectiveRun6Stem())
end

countSelectableSelectedStems = function(skipIndex)
    local count = 0
    for i, stem in ipairs(STEMS or {}) do
        if i ~= skipIndex and stem.selected and stemIsSelectableForCurrentModel(stem) then
            count = count + 1
        end
    end
    return count
end

ensureAtLeastOneStemSelected = function()
    if countSelectableSelectedStems(nil) > 0 then
        return false
    end
    for _, stem in ipairs(STEMS or {}) do
        if stemIsSelectableForCurrentModel(stem) then
            stem.selected = true
            return true
        end
    end
    return false
end

toggleStemSelection = function(index)
    local stem = STEMS and STEMS[index]
    if not stem or not stemIsSelectableForCurrentModel(stem) then
        return false
    end

    if stem.selected then
        if countSelectableSelectedStems(index) <= 0 then
            return false
        end
        stem.selected = false
        return true
    end

    stem.selected = true
    return true
end

areAllSelectableStemsSelected = function()
    local selectableCount = 0
    for _, stem in ipairs(STEMS or {}) do
        if stemIsSelectableForCurrentModel(stem) then
            selectableCount = selectableCount + 1
            if not stem.selected then
                return false
            end
        end
    end
    return selectableCount > 0
end

selectAllSelectableStems = function()
    for _, stem in ipairs(STEMS or {}) do
        if stemIsSelectableForCurrentModel(stem) then
            stem.selected = true
        elseif stem.sixStemOnly then
            stem.selected = false
        end
    end
end

setModelPreservingStemIntent = function(modelId)
    if not modelId or SETTINGS.model == modelId then
        return false
    end

    local wasAllSelected = areAllSelectableStemsSelected()
    SETTINGS.model = modelId

    if wasAllSelected then
        selectAllSelectableStems()
    else
        if tostring(SETTINGS.model or "") ~= "htdemucs_6s" then
            for _, st in ipairs(STEMS or {}) do
                if st.sixStemOnly then st.selected = false end
            end
        end
        ensureAtLeastOneStemSelected()
    end

    saveSettings()
    return true
end


local GLUE_HELPERS = dofile(script_path .. "_internal/STEMwerk_Glue_Helpers.lua")

clearPostProcessCandidates = GLUE_HELPERS.clearPostProcessCandidates
addPostProcessCandidate = GLUE_HELPERS.addPostProcessCandidate

SETTINGS_MOD.configure({
    reaper = reaper,
    EXT_SECTION = EXT_SECTION,
    GUI = GUI,
    SETTINGS = SETTINGS,
    STEMS = STEMS,
    refreshModelAvailability = refreshModelAvailability,
    normalizeThemePreset = normalizeThemePreset,
    updateTheme = updateTheme,
    setLanguage = setLanguage,
    ensureSelectedModelIsAvailable = ensureSelectedModelIsAvailable,
    getWindowState = function()
        return lastDialogX, lastDialogY, lastDialogW, lastDialogH
    end,
    setWindowState = function(x, y, w, h)
        lastDialogX, lastDialogY, lastDialogW, lastDialogH = x, y, w, h
    end,
})
DEVICE_RUNTIME.configure({
    DEVICES = DEVICES,
    T = T,
    PATH_SEP = PATH_SEP,
    script_path = script_path,
    repo_root = repo_root,
    getHome = getHome,
    getFlatpakTempBase = getFlatpakTempBase,
    exec_capture = exec_capture,
    quoteArg = quoteArg,
    fileExists = fileExists,
    isAbsolutePath = isAbsolutePath,
    readCapabilities = readCapabilities,
})
SETTINGS_MOD.loadSavedMainWindowPos()

local function loadSettings()
    return SETTINGS_MOD.load()
end

saveSettings = function()
    return SETTINGS_MOD.save()
end

-- Register exit function (now that saveSettings is defined)
reaper.atexit(saveSettings)

-- Preset functions

applyPresetKaraoke = function() GLUE_HELPERS.applyPresetKaraoke(STEMS) end
applyPresetInstrumental = function() GLUE_HELPERS.applyPresetInstrumental(STEMS) end
applyPresetDrumsOnly = function() GLUE_HELPERS.applyPresetDrumsOnly(STEMS) end
applyPresetVocalsOnly = function() GLUE_HELPERS.applyPresetVocalsOnly(STEMS) end
applyPresetBassOnly = function() GLUE_HELPERS.applyPresetBassOnly(STEMS) end
applyPresetOtherOnly = function() GLUE_HELPERS.applyPresetOtherOnly(STEMS) end
applyPresetGuitarOnly = function() GLUE_HELPERS.applyPresetGuitarOnly(STEMS) end
applyPresetPianoOnly = function() GLUE_HELPERS.applyPresetPianoOnly(STEMS) end
applyPresetAll = function() GLUE_HELPERS.applyPresetAll(STEMS) end

local function rgbToReaperColor(r, g, b)
    return reaper.ColorToNative(r, g, b) | 0x1000000
end

local WINDOW = loadModule(script_path .. "_internal/STEMwerk_Window.lua", "STEMwerk_Window")
local clampToScreen = WINDOW.clampToScreen

GUI.getLiveGeometry = WINDOW.getLiveGeometry
GUI.applyLiveGeometry = WINDOW.applyLiveGeometry
GUI.snapshotMainGeometry = WINDOW.snapshotMainGeometry
GUI.restoreMainSnapshot = WINDOW.restoreMainSnapshot

-- Check if there's a valid time selection
local function hasTimeSelection()
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if endTime > startTime then
        return true
    end
    if reaper.GetSet_LoopTimeRange2 then
        local s2, e2 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
        if (e2 or 0) > (s2 or 0) then
            return true
        end
    end
    -- Fallback: if loop points are set but time selection isn't linked, mirror loop points.
    local loopStart, loopEnd = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
    if loopEnd > loopStart then
        reaper.GetSet_LoopTimeRange(true, false, loopStart, loopEnd, false)
        return true
    end
    if reaper.GetSet_LoopTimeRange2 then
        local l2s, l2e = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
        if (l2e or 0) > (l2s or 0) then
            reaper.GetSet_LoopTimeRange(true, false, l2s, l2e, false)
            return true
        end
    end
    return false
end

-- Audibility helpers (mute/solo filtering)
local AUDIBILITY = {}

function AUDIBILITY.anySoloActive()
    local n = reaper.CountTracks(0) or 0
    for t = 0, n - 1 do
        local tr = reaper.GetTrack(0, t)
        if tr and (reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") or 0) > 0 then
            return true
        end
    end
    return false
end

function AUDIBILITY.isTrackMuted(track)
    return track and (reaper.GetMediaTrackInfo_Value(track, "B_MUTE") or 0) > 0.5
end

function AUDIBILITY.isTrackSoloed(track)
    return track and (reaper.GetMediaTrackInfo_Value(track, "I_SOLO") or 0) > 0
end

function AUDIBILITY.isTrackAudible(track, soloActive)
    if not track or not reaper.ValidatePtr(track, "MediaTrack*") then return false end
    if AUDIBILITY.isTrackMuted(track) then return false end
    if soloActive then
        return AUDIBILITY.isTrackSoloed(track)
    end
    return true
end

function AUDIBILITY.isItemMuted(item)
    return item and (reaper.GetMediaItemInfo_Value(item, "B_MUTE") or 0) > 0.5
end

function AUDIBILITY.isItemAudible(item, soloActive)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return false end
    local track = reaper.GetMediaItem_Track(item)
    if not AUDIBILITY.isTrackAudible(track, soloActive) then return false end
    if AUDIBILITY.isItemMuted(item) then return false end
    return true
end

function AUDIBILITY.filterTracks(tracks, soloActive)
    local out = {}
    for _, tr in ipairs(tracks or {}) do
        if AUDIBILITY.isTrackAudible(tr, soloActive) then
            out[#out + 1] = tr
        end
    end
    return out
end

function AUDIBILITY.filterItems(items, soloActive)
    local out = {}
    for _, it in ipairs(items or {}) do
        if AUDIBILITY.isItemAudible(it, soloActive) then
            out[#out + 1] = it
        end
    end
    return out
end

-- Use processing-time solo state if available (keeps filtering consistent during a run).
PROCESS_AUDIBILITY_SOLO_ACTIVE = nil
local function getProcessingSoloActive()
    if PROCESS_AUDIBILITY_SOLO_ACTIVE ~= nil then
        return PROCESS_AUDIBILITY_SOLO_ACTIVE
    end
    return AUDIBILITY.anySoloActive()
end

function HELPERS.getSelectionMonitorState()
    local soloActive = getProcessingSoloActive()
    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    local selTrackCount = reaper.CountSelectedTracks(0) or 0
    local timeSelStart, timeSelEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local hasTimeSel = (timeSelEnd or 0) > (timeSelStart or 0)

    local function itemOverlapsTimeSelection(item)
        if not hasTimeSel then return true end
        if not item or not reaper.ValidatePtr(item, "MediaItem*") then return false end
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = pos + len
        return pos < timeSelEnd and itemEnd > timeSelStart
    end

    local function anyAudibleItemOnTrack(track)
        if not track or not reaper.ValidatePtr(track, "MediaTrack*") then return false, false end
        local anyOverlap = false
        local itemCount = reaper.CountTrackMediaItems(track) or 0
        for i = 0, itemCount - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item and itemOverlapsTimeSelection(item) then
                anyOverlap = true
                if AUDIBILITY.isItemAudible(item, soloActive) then
                    return true, true
                end
            end
        end
        return false, anyOverlap
    end

    if selItemCount > 0 then
        local anySelectedOverlap = false
        for i = 0, selItemCount - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            if item and itemOverlapsTimeSelection(item) then
                anySelectedOverlap = true
                if AUDIBILITY.isItemAudible(item, soloActive) then
                    return { actionable = true, hasSource = true, reason = "selected_items_audible" }
                end
            end
        end
        if anySelectedOverlap then
            return { actionable = false, hasSource = true, reason = "selected_items_inaudible" }
        end
    end

    if selTrackCount > 0 then
        local anyTrackOverlap = false
        for t = 0, selTrackCount - 1 do
            local track = reaper.GetSelectedTrack(0, t)
            local audibleOnTrack, overlapOnTrack = anyAudibleItemOnTrack(track)
            if overlapOnTrack then anyTrackOverlap = true end
            if audibleOnTrack then
                return { actionable = true, hasSource = true, reason = "selected_tracks_audible" }
            end
        end
        if anyTrackOverlap then
            return { actionable = false, hasSource = true, reason = "selected_tracks_inaudible" }
        end
    end

    if hasTimeSel then
        local anyOverlap = false
        local trackCount = reaper.CountTracks(0) or 0
        for t = 0, trackCount - 1 do
            local track = reaper.GetTrack(0, t)
            local audibleOnTrack, overlapOnTrack = anyAudibleItemOnTrack(track)
            if overlapOnTrack then anyOverlap = true end
            if audibleOnTrack then
                return { actionable = true, hasSource = true, reason = "time_selection_audible" }
            end
        end
        if anyOverlap then
            return { actionable = false, hasSource = true, reason = "time_selection_inaudible" }
        end
    end

    return { actionable = false, hasSource = false, reason = "none" }
end

-- Message window state (for errors, warnings, info)

-- Message/dialog helpers extracted to module
local MESSAGES = dofile(script_path .. "_internal/STEMwerk_Messages.lua")
messageWindowState = MESSAGES.messageWindowState

-- Forward declarations (functions defined later in file)
local main
local showMessage
local drawHelpQuickStartHeader
local drawHelpReaperHeader
local getRuntimeModeLabel
local buildFooterLines

-- STEM colors for window borders (used by all windows)
STEM_BORDER_COLORS = {
    {255, 100, 100},  -- Red (Vocals)
    {100, 200, 255},  -- Blue (Drums)
    {150, 100, 255},  -- Purple (Bass)
    {100, 255, 150},  -- Green (Other)
}

-- Shared tooltip helpers (used across windows) --------------------------------

-- Draw/tooltip helpers extracted to module
local UI_DRAW = dofile(script_path .. "_internal/STEMwerk_UI_Draw.lua")
_wrapTextToWidth = UI_DRAW._wrapTextToWidth

local function getTooltipPalette()
    if SETTINGS and SETTINGS.darkMode then
        return {0.14, 0.14, 0.17}, {0.55, 0.55, 0.60}, {0.96, 0.96, 0.98}, 0.985
    end
    return {0.95, 0.95, 0.97}, {0.42, 0.42, 0.46}, {0.10, 0.10, 0.12}, 0.995
end

local function getActiveThemeColors()
    return (ACTIVE_THEME and ACTIVE_THEME.colors) or {}
end

local function getActiveThemeStyle()
    return (ACTIVE_THEME and ACTIVE_THEME.style) or {}
end

local function getThemeStyleNumber(key, fallback)
    local style = getActiveThemeStyle()
    local value = style[key]
    if type(value) == "number" then
        return value
    end
    return fallback
end

local function getThemeRadius(scaleFn, fallback, maxRadius)
    local radius = getThemeStyleNumber("cornerRadius", fallback or 0) or 0
    if scaleFn then
        radius = scaleFn(radius)
    end
    radius = math.max(0, math.floor(radius + 0.5))
    if maxRadius then
        radius = math.min(radius, maxRadius)
    end
    return radius
end

local function getThemeBorderWeight(scaleFn, fallback)
    local weight = getThemeStyleNumber("borderWeight", fallback or 1) or 1
    if scaleFn then
        weight = scaleFn(weight)
    end
    return math.max(1, math.floor(weight + 0.5))
end

-- glossStrength
local function getThemeGlossStrength(fallback)
    local value = getThemeStyleNumber("glossStrength", fallback or 1) or 1
    if value < 0 then return 0 end
    if value > 1.5 then return 1.5 end
    return value
end

local function mixColor(a, b, t)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    }
end

local function getThemeShadowColor()
    local colors = getActiveThemeColors()
    local accent = colors.accent or THEME.accent or {0.35, 0.65, 0.95}
    local muted = colors.iconMuted or colors.textMuted or THEME.textHint or {0.45, 0.45, 0.5}
    local mode = (ACTIVE_THEME and ACTIVE_THEME.meta and ACTIVE_THEME.meta.mode) or ((SETTINGS and SETTINGS.darkMode) and "dark" or "light")
    if mode == "light" then
        return mixColor({0.22, 0.20, 0.18}, accent, 0.12)
    end
    return mixColor({0.00, 0.00, 0.00}, mixColor(muted, accent, 0.25), 0.75)
end

local function isThemeLightMode()
    local mode = (ACTIVE_THEME and ACTIVE_THEME.meta and ACTIVE_THEME.meta.mode)
    if mode == "light" then
        return true
    end
    if mode == "dark" then
        return false
    end
    return not (SETTINGS and SETTINGS.darkMode)
end

local function getThemePresetId()
    if ACTIVE_THEME and ACTIVE_THEME.meta and ACTIVE_THEME.meta.presetId then
        return tostring(ACTIVE_THEME.meta.presetId)
    end
    if SETTINGS and SETTINGS.themePreset then
        return tostring(SETTINGS.themePreset)
    end
    return "classic"
end

local function getLightElevationProfile(role)
    if not isThemeLightMode() then
        return nil
    end

    local profiles = {
        tooltip = { shadow = 1.95, rim = 0.23, highlight = 0.16, bevel = 0.14 },
        card = { shadow = 1.55, rim = 0.18, highlight = 0.11, bevel = 0.11 },
        button = { shadow = 1.34, rim = 0.16, highlight = 0.10, bevel = 0.13 },
        process = { shadow = 1.18, rim = 0.10, highlight = 0.06, bevel = 0.08 },
        ["default"] = { shadow = 1.08, rim = 0.07, highlight = 0.04, bevel = 0.06 },
    }
    local src = profiles[tostring(role or "")] or profiles["default"]
    local profile = {
        shadow = src.shadow,
        rim = src.rim,
        highlight = src.highlight,
        bevel = src.bevel,
    }

    -- Keep mono visibly more restrained than other themes in light mode.
    if getThemePresetId() == "mono" then
        profile.shadow = profile.shadow * 0.78
        profile.rim = profile.rim * 0.72
        profile.highlight = profile.highlight * 0.70
        profile.bevel = profile.bevel * 0.75
    end
    return profile
end

local function drawRoundedFill(x, y, w, h, radius)
    w = math.floor(w or 0)
    h = math.floor(h or 0)
    if w <= 0 or h <= 0 then return end
    radius = math.max(0, math.min(radius or 0, math.floor(math.min(w, h) / 2)))
    if radius <= 0 then
        gfx.rect(x, y, w, h, 1)
        return
    end
    for i = 0, h - 1 do
        local inset = 0
        if i < radius then
            inset = radius - math.sqrt(math.max(0, radius * radius - (radius - i) * (radius - i)))
        elseif i > h - 1 - radius then
            local di = i - (h - 1 - radius)
            inset = radius - math.sqrt(math.max(0, radius * radius - di * di))
        end
        gfx.line(x + inset, y + i, x + w - inset, y + i)
    end
end

local function drawThemeShadow(x, y, w, h, radius, alphaMult, role)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then return end
    local shadowStrength = getThemeStyleNumber("shadowStrength", 0) or 0
    if shadowStrength <= 0.001 or w <= 0 or h <= 0 then
        return
    end
    local profile = getLightElevationProfile(role)
    local roleMult = (profile and profile.shadow) or 1
    local shadowColor = getThemeShadowColor()
    local sr, sg, sb = shadowColor[1], shadowColor[2], shadowColor[3]
    local passes = math.max(1, math.min(4, math.floor(1 + shadowStrength * 18)))
    local offset = math.max(1, math.floor(1 + shadowStrength * 10))
    local baseAlpha = math.max(0.015, shadowStrength * 0.22) * (alphaMult or 1) * roleMult
    for i = passes, 1, -1 do
        local passAlpha = baseAlpha * (i / passes) * 0.7
        gfx.set(sr, sg, sb, passAlpha)
        drawRoundedFill(x + offset, y + offset + math.floor(i / 2), w, h, radius)
    end
end

local function drawLightSurfaceFinish(innerX, innerY, innerW, innerH, innerRadius, role, alphaMult)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then return end
    local profile = getLightElevationProfile(role)
    if not profile or innerW <= 2 or innerH <= 2 then
        return
    end
    local alpha = alphaMult or 1

    -- Lifted top rim + short highlight rolloff.
    gfx.set(1, 1, 1, math.min(0.22, profile.rim) * alpha)
    drawRoundedFill(innerX, innerY, innerW, 1, math.min(innerRadius, 1))
    local topLines = math.max(1, math.min(3, math.floor(innerH * 0.14)))
    for i = 1, topLines do
        local t = 1 - ((i - 1) / math.max(1, topLines - 1))
        gfx.set(1, 1, 1, math.min(0.18, profile.highlight * t) * alpha)
        drawRoundedFill(innerX, innerY + i, innerW, 1, math.max(0, math.min(innerRadius, i + 1)))
    end

    -- Subtle lower-face separation / bevel.
    local bevelLines = math.max(1, math.min(3, math.floor(innerH * 0.16)))
    for i = 0, bevelLines - 1 do
        local t = (i / math.max(1, bevelLines - 1))
        gfx.set(0, 0, 0, math.min(0.14, profile.bevel * (0.55 + 0.45 * t)) * alpha)
        drawRoundedFill(
            innerX,
            innerY + innerH - 1 - i,
            innerW,
            1,
            math.max(0, math.min(innerRadius, innerH - 1 - i))
        )
    end
end

local function drawThemeSurfaceBox(x, y, w, h, fillColor, borderColor, fillAlpha, borderAlpha, radius, borderWeight, shadowAlpha, shadowRole)
    if w <= 0 or h <= 0 then return end
    radius = math.max(0, math.min(radius or 0, math.floor(math.min(w, h) / 2)))
    borderWeight = math.max(1, math.floor(borderWeight or 1))
    drawThemeShadow(x, y, w, h, radius, shadowAlpha or 1, shadowRole)
    gfx.set(borderColor[1], borderColor[2], borderColor[3], borderAlpha or 1)
    drawRoundedFill(x, y, w, h, radius)
    local innerX = x + borderWeight
    local innerY = y + borderWeight
    local innerW = w - borderWeight * 2
    local innerH = h - borderWeight * 2
    if innerW > 0 and innerH > 0 then
        gfx.set(fillColor[1], fillColor[2], fillColor[3], fillAlpha or 1)
        local innerRadius = math.max(0, radius - borderWeight)
        drawRoundedFill(innerX, innerY, innerW, innerH, innerRadius)
        drawLightSurfaceFinish(innerX, innerY, innerW, innerH, innerRadius, shadowRole, fillAlpha or 1)
    end
end

-- Draw a tooltip box with stem-color top bar. Caller must set font before calling.
-- padding/lineH/maxTextW are already scaled (S/UI/PS).
local function drawTooltipStyled(tooltipText, tooltipX, tooltipY, winW, winH, padding, lineH, maxTextW)
    return UI_DRAW.drawTooltipStyled(tooltipText, tooltipX, tooltipY, winW, winH, padding, lineH, maxTextW)
end

local function updateControlsOpacity(state, mouseInControls)
    if not state then
        return mouseInControls and 1.0 or 0.0
    end
    if state.controlsOpacity == nil then
        state.controlsOpacity = mouseInControls and 1.0 or 0.0
    end
    local target = mouseInControls and 1.0 or 0.0
    local speed = mouseInControls and 0.25 or 0.08
    state.controlsOpacity = state.controlsOpacity + (target - state.controlsOpacity) * speed
    if state.controlsOpacity < 0 then state.controlsOpacity = 0 end
    if state.controlsOpacity > 1 then state.controlsOpacity = 1 end
    return state.controlsOpacity
end

local STEMWERK_LOGO_LETTERS = {"S", "T", "E", "M", "w", "e", "r", "k"}

local function measureStemwerkLogo(fontSize, fontName, bold)
    fontName = fontName or "Arial"
    local flags = bold and string.byte('b') or 0
    gfx.setfont(1, fontName, fontSize, flags)
    local totalW = 0
    for _, letter in ipairs(STEMWERK_LOGO_LETTERS) do
        totalW = totalW + gfx.measurestr(letter)
    end
    return totalW
end

-- Draw the waving "STEMwerk" logo. Returns (x, y, w, h) bounds.
local function drawWavingStemwerkLogo(opts)
    opts = opts or {}
    local x = opts.x
    local y = opts.y or 0
    local containerW = opts.w or gfx.w
    local fontSize = opts.fontSize or 24
    local fontName = opts.fontName or "Arial"
    local bold = (opts.bold ~= false)
    local time = opts.time or os.clock()
    local speed = opts.speed or 3
    local phase = opts.phase or 0.5
    local amp = opts.amp
    local alphaStem = opts.alphaStem or 1
    local alphaRest = opts.alphaRest or 0.9

    local flags = bold and string.byte('b') or 0
    gfx.setfont(1, fontName, fontSize, flags)

    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()

    if utilityMode then
        local fullText = "STEMwerk"
        local fullW = gfx.measurestr(fullText)
        if x == nil then x = (containerW - fullW) / 2 end
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], alphaRest)
        gfx.x, gfx.y = x, y
        gfx.drawstr(fullText)
        return x, y, fullW, gfx.texth
    end

    local widths = {}
    local totalW = 0
    for i, letter in ipairs(STEMWERK_LOGO_LETTERS) do
        local lw = gfx.measurestr(letter)
        widths[i] = lw
        totalW = totalW + lw
    end

    if x == nil then
        x = (containerW - totalW) / 2
    end

    if amp == nil then
        amp = math.max(1, math.floor(fontSize * 0.08 + 0.5))
    end

    local startX = x
    local logoH = gfx.texth
    for i, letter in ipairs(STEMWERK_LOGO_LETTERS) do
        local yOffset = math.sin(time * speed + i * phase) * amp
        if i <= 4 then
            local c = STEM_BORDER_COLORS[i]
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, alphaStem)
        else
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], alphaRest)
        end
        gfx.x = x
        gfx.y = y + yOffset
        gfx.drawstr(letter)
        x = x + widths[i]
    end

    return startX, y, totalW, logoH
end

-- Draw colored STEM gradient border at top of window
local function drawStemBorder(x, y, w, thickness)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then return end
    thickness = thickness or 3
    for i = 0, w - 1 do
        local colorIdx = math.floor(i / w * 4) + 1
        colorIdx = math.min(4, math.max(1, colorIdx))
        local c = STEM_BORDER_COLORS[colorIdx]
        gfx.set(c[1]/255, c[2]/255, c[3]/255, 0.9)
        gfx.line(x + i, y, x + i, y + thickness - 1)
    end
end

-- Help system state (replaces Art Gallery)
local helpState = {
    currentTab = 1,  -- 1=Welcome, 2=Quick Start, 3=Stems, 4=Reaper, 5=Gallery, 6=About
    wasMouseDown = false,
    wasRightMouseDown = false,
    startTime = 0,
    -- Art gallery sub-state
    currentArt = 1,
    -- Camera controls for art gallery
    zoom = 1.0,
    panX = 0,
    panY = 0,
    targetZoom = 1.0,
    targetPanX = 0,
    targetPanY = 0,
    isDragging = false,
    dragStartX = 0,
    dragStartY = 0,
    dragStartPanX = 0,
    dragStartPanY = 0,
    lastMouseWheel = 0,
    -- Rotation (right-click drag)
    rotation = 0,
    targetRotation = 0,
    isRotating = false,
    rotateStartX = 0,
    rotateStartY = 0,
    rotateStartAngle = 0,
    -- Click vs drag detection
    clickStartX = 0,
    clickStartY = 0,
    wasDrag = false,
    -- Text zoom for non-gallery tabs
    textZoom = 1.0,
    targetTextZoom = 1.0,
    -- Text pan for non-gallery tabs (left-click drag)
    textPanX = 0,
    textPanY = 0,
    targetTextPanX = 0,
    targetTextPanY = 0,
    textDragging = false,
    textDragStartX = 0,
    textDragStartY = 0,
    textDragStartPanX = 0,
    textDragStartPanY = 0,
    -- Track where help was opened from (for correct return)
    openedFrom = "start",  -- "start" or "dialog"
    -- Gallery controls fade (for immersive mode)
    controlsOpacity = 1.0,
    targetControlsOpacity = 1.0,
}

-- Keep artGalleryState as alias for compatibility
local artGalleryState = helpState

-- Main dialog background art state
local mainDialogArt = {
    -- Camera controls
    zoom = 1.0,
    targetZoom = 1.0,
    panX = 0,
    panY = 0,
    targetPanX = 0,
    targetPanY = 0,
    rotation = 0,
    targetRotation = 0,
    -- Mouse interaction state
    isDragging = false,
    isRotating = false,
    dragStartX = 0,
    dragStartY = 0,
    dragStartPanX = 0,
    dragStartPanY = 0,
    rotateStartX = 0,
    rotateStartAngle = 0,
    lastMouseWheel = 0,
    -- Click vs drag detection
    clickStartX = 0,
    clickStartY = 0,
    clickStartTime = 0,
    wasDrag = false,
    wasMouseDown = false,
    wasRightMouseDown = false,
}

-- ============================================
-- AUDIO REACTIVITY SYSTEM (real-time peak detection)
-- ============================================
local audioReactive = {
    enabled = true,
    peakL = 0,          -- Current left channel peak (0-1)
    peakR = 0,          -- Current right channel peak (0-1)
    peakMono = 0,       -- Combined mono peak
    smoothPeakL = 0,    -- Smoothed left peak (for animation)
    smoothPeakR = 0,    -- Smoothed right peak
    smoothPeakMono = 0, -- Smoothed mono peak
    bass = 0,           -- Simulated bass (low freq) energy
    mid = 0,            -- Simulated mid freq energy
    high = 0,           -- Simulated high freq energy
    smoothBass = 0,
    smoothMid = 0,
    smoothHigh = 0,
    beatDetected = false,
    lastBeatTime = 0,
    beatDecay = 0,      -- Visual decay after beat
    history = {},       -- Peak history for beat detection
    historySize = 20,
    -- MilkDrop-style waveform buffer (circular display)
    waveformHistory = {},    -- 120 samples for circular waveform display
    waveformSize = 120,      -- Number of points in waveform ring
    waveformIndex = 1,       -- Current write position (circular buffer)
}

-- Update audio reactivity from master track
local function updateAudioReactivity()
    if not audioReactive.enabled then return end

    -- Get master track
    local masterTrack = reaper.GetMasterTrack(0)
    if not masterTrack then return end

    -- Get peak info for left and right channels
    -- Channel 0 = left, channel 1 = right
    local peakL = reaper.Track_GetPeakInfo(masterTrack, 0) or 0
    local peakR = reaper.Track_GetPeakInfo(masterTrack, 1) or 0

    -- Store raw peaks
    audioReactive.peakL = peakL
    audioReactive.peakR = peakR
    audioReactive.peakMono = (peakL + peakR) / 2

    -- Smooth interpolation (fast attack, slow decay)
    local attackSpeed = 0.5
    local decaySpeed = 0.08

    -- Left channel
    if peakL > audioReactive.smoothPeakL then
        audioReactive.smoothPeakL = audioReactive.smoothPeakL + (peakL - audioReactive.smoothPeakL) * attackSpeed
    else
        audioReactive.smoothPeakL = audioReactive.smoothPeakL + (peakL - audioReactive.smoothPeakL) * decaySpeed
    end

    -- Right channel
    if peakR > audioReactive.smoothPeakR then
        audioReactive.smoothPeakR = audioReactive.smoothPeakR + (peakR - audioReactive.smoothPeakR) * attackSpeed
    else
        audioReactive.smoothPeakR = audioReactive.smoothPeakR + (peakR - audioReactive.smoothPeakR) * decaySpeed
    end

    -- Mono
    local mono = audioReactive.peakMono
    if mono > audioReactive.smoothPeakMono then
        audioReactive.smoothPeakMono = audioReactive.smoothPeakMono + (mono - audioReactive.smoothPeakMono) * attackSpeed
    else
        audioReactive.smoothPeakMono = audioReactive.smoothPeakMono + (mono - audioReactive.smoothPeakMono) * decaySpeed
    end

    -- Simulate frequency bands from peak variations (pseudo-spectral)
    -- This is an approximation - real FFT would need more complex setup
    local now = os.clock()
    table.insert(audioReactive.history, mono)
    if #audioReactive.history > audioReactive.historySize then
        table.remove(audioReactive.history, 1)
    end

    -- Calculate variance for "energy" simulation
    if #audioReactive.history >= 5 then
        local avg = 0
        for _, v in ipairs(audioReactive.history) do avg = avg + v end
        avg = avg / #audioReactive.history

        -- Bass = slower changes (low variance in recent samples)
        local recentAvg = (audioReactive.history[#audioReactive.history] +
                          (audioReactive.history[#audioReactive.history - 1] or 0) +
                          (audioReactive.history[#audioReactive.history - 2] or 0)) / 3
        audioReactive.bass = math.min(1, recentAvg * 1.5)

        -- High = fast changes (difference between consecutive samples)
        local diff = math.abs((audioReactive.history[#audioReactive.history] or 0) -
                              (audioReactive.history[#audioReactive.history - 1] or 0))
        audioReactive.high = math.min(1, diff * 5)

        -- Mid = everything else
        audioReactive.mid = math.min(1, avg * 1.2)
    end

    -- Smooth frequency bands
    audioReactive.smoothBass = audioReactive.smoothBass + (audioReactive.bass - audioReactive.smoothBass) * 0.15
    audioReactive.smoothMid = audioReactive.smoothMid + (audioReactive.mid - audioReactive.smoothMid) * 0.2
    audioReactive.smoothHigh = audioReactive.smoothHigh + (audioReactive.high - audioReactive.smoothHigh) * 0.3

    -- Simple beat detection (sudden increase in mono peak)
    if #audioReactive.history >= 3 then
        local current = audioReactive.history[#audioReactive.history] or 0
        local previous = audioReactive.history[#audioReactive.history - 2] or 0
        local threshold = 0.15

        if current - previous > threshold and (now - audioReactive.lastBeatTime) > 0.1 then
            audioReactive.beatDetected = true
            audioReactive.lastBeatTime = now
            audioReactive.beatDecay = 1.0
        else
            audioReactive.beatDetected = false
        end
    end

    -- Decay beat visual
    audioReactive.beatDecay = audioReactive.beatDecay * 0.9

    -- Update waveform history (circular buffer for MilkDrop-style display)
    audioReactive.waveformHistory[audioReactive.waveformIndex] = mono
    audioReactive.waveformIndex = (audioReactive.waveformIndex % audioReactive.waveformSize) + 1
end

-- ============================================
-- PROCEDURAL ART GENERATOR (shared across all windows)
-- ============================================
local proceduralArt = {
    seed = 0,
    style = 0,  -- Start at 0 so first generation picks any style
    lastClick = 0,
    elements = {},
    time = 0,
    title = "",
    subtitle = "",
    subtitleIdx = 0,  -- Track subtitle to avoid repeats
}

-- ============================================
-- MEGA ANIMATION NAME GENERATOR (1000+ unique names!)
-- Combines adjectives + nouns + modifiers for infinite variety
-- ============================================
local animNameParts = {
    -- Adjectives (will be combined)
    adjectives = {
        EN = {"Cosmic", "Quantum", "Neural", "Crystal", "Spiral", "Fractal", "Harmonic",
              "Digital", "Neon", "Electric", "Psychedelic", "Hypnotic", "Ethereal", "Astral",
              "Prismatic", "Holographic", "Bioluminescent", "Chromatic", "Kinetic", "Pulsating",
              "Shimmering", "Cascading", "Orbiting", "Floating", "Dancing", "Swirling",
              "Glitching", "Morphing", "Breathing", "Dreaming", "Exploding", "Imploding",
              "Infinite", "Chaotic", "Serene", "Turbulent", "Liquid", "Crystalline", "Molten",
              "Frozen", "Temporal", "Spatial", "Dimensional", "Parallel", "Inverted", "Mirrored"},
        NL = {"Kosmische", "Quantum", "Neurale", "Kristallen", "Spiraal", "Fractale", "Harmonische",
              "Digitale", "Neon", "Elektrische", "Psychedelische", "Hypnotische", "Etherische", "Astrale",
              "Prismatische", "Holografische", "Bioluminescente", "Chromatische", "Kinetische", "Pulserende",
              "Glinsterende", "Vallende", "Orbiterende", "Zwevende", "Dansende", "Wervelende",
              "Glitchende", "Morfende", "Ademende", "Dromende", "Exploderende", "Imploderende",
              "Oneindige", "Chaotische", "Serene", "Turbulente", "Vloeibare", "Kristallijne", "Gesmolten",
              "Bevroren", "Temporele", "Ruimtelijke", "Dimensionale", "Parallelle", "Omgekeerde", "Gespiegelde"},
        DE = {"Kosmische", "Quanten", "Neurale", "Kristall", "Spiral", "Fraktale", "Harmonische",
              "Digitale", "Neon", "Elektrische", "Psychedelische", "Hypnotische", "Ätherische", "Astrale",
              "Prismatische", "Holographische", "Biolumineszente", "Chromatische", "Kinetische", "Pulsierende",
              "Schimmernde", "Kaskadierende", "Orbitierende", "Schwebende", "Tanzende", "Wirbelnde",
              "Glitchende", "Morphende", "Atmende", "Träumende", "Explodierende", "Implodierende",
              "Unendliche", "Chaotische", "Ruhige", "Turbulente", "Flüssige", "Kristalline", "Geschmolzene",
              "Gefrorene", "Temporale", "Räumliche", "Dimensionale", "Parallele", "Invertierte", "Gespiegelte"},
    },
    -- Nouns (the main thing)
    nouns = {
        EN = {"Waves", "Network", "Formation", "Galaxy", "Dream", "Storm", "Pulse", "Light",
              "Flow", "Sculpture", "Rain", "Field", "Ripples", "Echo", "Bloom", "Stream",
              "Vortex", "Nebula", "Matrix", "Cascade", "Aurora", "Plasma", "Waveform", "Spectrum",
              "Lattice", "Constellation", "Supernova", "Helix", "Mandala", "Tessellation", "Geometry",
              "Particles", "Ribbons", "Threads", "Filaments", "Bubbles", "Orbs", "Crystals", "Flames",
              "Shadows", "Reflections", "Fractals", "Patterns", "Symmetry", "Chaos", "Order", "Entropy",
              "Resonance", "Vibration", "Oscillation", "Frequency", "Amplitude", "Phase", "Harmonics"},
        NL = {"Golven", "Netwerk", "Formatie", "Melkweg", "Droom", "Storm", "Puls", "Licht",
              "Stroom", "Sculptuur", "Regen", "Veld", "Rimpelingen", "Echo", "Bloei", "Stroom",
              "Vortex", "Nevel", "Matrix", "Cascade", "Noorderlicht", "Plasma", "Golfvorm", "Spectrum",
              "Rooster", "Sterrenbeeld", "Supernova", "Helix", "Mandala", "Tessellatie", "Geometrie",
              "Deeltjes", "Linten", "Draden", "Filamenten", "Bellen", "Bollen", "Kristallen", "Vlammen",
              "Schaduwen", "Reflecties", "Fractals", "Patronen", "Symmetrie", "Chaos", "Orde", "Entropie",
              "Resonantie", "Trilling", "Oscillatie", "Frequentie", "Amplitude", "Fase", "Harmonieën"},
        DE = {"Wellen", "Netzwerk", "Formation", "Galaxie", "Traum", "Sturm", "Puls", "Licht",
              "Fluss", "Skulptur", "Regen", "Feld", "Wellen", "Echo", "Blüte", "Strom",
              "Wirbel", "Nebel", "Matrix", "Kaskade", "Polarlicht", "Plasma", "Wellenform", "Spektrum",
              "Gitter", "Sternbild", "Supernova", "Helix", "Mandala", "Tessellation", "Geometrie",
              "Partikel", "Bänder", "Fäden", "Filamente", "Blasen", "Kugeln", "Kristalle", "Flammen",
              "Schatten", "Reflexionen", "Fraktale", "Muster", "Symmetrie", "Chaos", "Ordnung", "Entropie",
              "Resonanz", "Schwingung", "Oszillation", "Frequenz", "Amplitude", "Phase", "Harmonien"},
    },
    -- Fun modifiers (sometimes added)
    modifiers = {
        EN = {"of Infinity", "from Beyond", "in Motion", "Reborn", "Unleashed", "Awakening",
              "X", "2.0", "Redux", "Remixed", "Evolved", "Transcendent", "Ultimate", "Prime",
              "at Dawn", "at Dusk", "in Flux", "Ascending", "Descending", "Converging", "Diverging",
              "Amplified", "Distorted", "Filtered", "Unfiltered", "Raw", "Pure", "Mixed", "Blended"},
        NL = {"van Oneindigheid", "uit het Niets", "in Beweging", "Herboren", "Ontketend", "Ontwakend",
              "X", "2.0", "Redux", "Geremixt", "Geëvolueerd", "Transcendent", "Ultiem", "Prime",
              "bij Dageraad", "bij Schemering", "in Flux", "Stijgend", "Dalend", "Convergerend", "Divergerend",
              "Versterkt", "Vervormd", "Gefilterd", "Ongefilterd", "Rauw", "Puur", "Gemixt", "Gemengd"},
        DE = {"der Unendlichkeit", "aus dem Nichts", "in Bewegung", "Wiedergeboren", "Entfesselt", "Erwachend",
              "X", "2.0", "Redux", "Remixed", "Evolviert", "Transzendent", "Ultimativ", "Prime",
              "bei Morgengrauen", "bei Dämmerung", "im Fluss", "Aufsteigend", "Absteigend", "Konvergierend", "Divergierend",
              "Verstärkt", "Verzerrt", "Gefiltert", "Ungefiltert", "Roh", "Rein", "Gemischt", "Vermischt"},
    },
    -- Silly/funny prefixes (rarely added for humor)
    sillyPrefixes = {
        EN = {"Mega", "Ultra", "Super", "Hyper", "Turbo", "Giga", "Über", "Extra", "Meta", "Proto",
              "Neo", "Retro", "Pseudo", "Quasi", "Semi", "Anti", "Counter", "Post", "Pre", "Trans"},
        NL = {"Mega", "Ultra", "Super", "Hyper", "Turbo", "Giga", "Über", "Extra", "Meta", "Proto",
              "Neo", "Retro", "Pseudo", "Quasi", "Semi", "Anti", "Contra", "Post", "Pre", "Trans"},
        DE = {"Mega", "Ultra", "Super", "Hyper", "Turbo", "Giga", "Über", "Extra", "Meta", "Proto",
              "Neo", "Retro", "Pseudo", "Quasi", "Semi", "Anti", "Kontra", "Post", "Prä", "Trans"},
    },
}

-- Generate a unique random art name based on seed
local function generateArtName(seed, lang)
    lang = lang or "EN"
    local adj = animNameParts.adjectives[lang] or animNameParts.adjectives.EN
    local noun = animNameParts.nouns[lang] or animNameParts.nouns.EN
    local mod = animNameParts.modifiers[lang] or animNameParts.modifiers.EN
    local silly = animNameParts.sillyPrefixes[lang] or animNameParts.sillyPrefixes.EN

    -- Use seed to pick consistently but randomly
    local adjIdx = math.floor(seed % #adj) + 1
    local nounIdx = math.floor((seed / 100) % #noun) + 1
    local modIdx = math.floor((seed / 10000) % #mod) + 1
    local sillyIdx = math.floor((seed / 1000000) % #silly) + 1

    local name = adj[adjIdx] .. " " .. noun[nounIdx]

    -- 30% chance to add modifier
    if (seed % 10) < 3 then
        name = name .. " " .. mod[modIdx]
    end

    -- 10% chance to add silly prefix
    if (seed % 100) < 10 then
        name = silly[sillyIdx] .. "-" .. name
    end

    -- Add unique number suffix (always different)
    local uniqueNum = seed % 10000
    if (seed % 5) == 0 then
        name = name .. " #" .. uniqueNum
    end

    return name
end

-- Legacy art style names (for backwards compatibility, now generated dynamically)
local artStyles = {
    "Cosmic Waves", "Neural Network", "Crystal Formation", "Spiral Galaxy",
    "Mandala Dream", "Particle Storm", "Geometric Pulse", "Prism Light",
    "Abstract Flow", "Sound Sculpture", "Digital Rain", "Quantum Field",
    "Harmonic Ripples", "Fractal Echo", "Neon Bloom", "Data Stream",
}

-- Seeded random number generator
local function seededRandom(seed, index)
    local x = math.sin(seed * 12.9898 + index * 78.233) * 43758.5453
    return x - math.floor(x)
end

-- Generate new random art with unique procedurally generated name!
function generateNewArt()
    -- Save old art for crossfade transition
    if proceduralArt.seed and proceduralArt.seed ~= 0 then
        proceduralArt.oldSeed = proceduralArt.seed
        proceduralArt.oldStyle = proceduralArt.style
        proceduralArt.oldElements = proceduralArt.elements
        proceduralArt.oldTime = proceduralArt.time
        proceduralArt.transitionProgress = 0  -- Start crossfade
        proceduralArt.transitionDuration = 1.5  -- 1.5 seconds crossfade
    end

    proceduralArt.seed = os.time() * 1000 + math.random(1, 999999)

    -- Pick a DIFFERENT style than the current one (now 1-1000 for 100 MilkDrop-inspired patterns!)
    local oldStyle = proceduralArt.style or 0
    local newStyle
    repeat
        newStyle = math.random(1, 1000)
    until newStyle ~= oldStyle

    proceduralArt.style = newStyle
    proceduralArt.time = 0

    -- Generate unique art name based on current language!
    local lang = SETTINGS and SETTINGS.language or "EN"
    proceduralArt.title = generateArtName(proceduralArt.seed, lang)

    -- Generate subtitle with variation
    local subtitleParts = {
        EN = {"by STEMwerk", "flarkAUDIO creation", "Algorithmic beauty",
              "Digital impression", "Sound visualization", "Audio to visual",
              "Stem separation art", "Processing dreams", "Infinite creativity",
              "Unique vision", "Generated moment", "Ephemeral beauty",
              "Sonic canvas", "Frequency art", "Waveform poetry"},
        NL = {"door STEMwerk", "flarkAUDIO creatie", "Algoritmische schoonheid",
              "Digitale impressie", "Geluidsvisualisatie", "Audio naar beeld",
              "Stem separatie kunst", "Verwerkingsdromen", "Oneindige creativiteit",
              "Unieke visie", "Gegenereerd moment", "Vergankelijke schoonheid",
              "Sonisch canvas", "Frequentie kunst", "Golfvorm poëzie"},
        DE = {"von STEMwerk", "flarkAUDIO Kreation", "Algorithmische Schönheit",
              "Digitaler Eindruck", "Klangvisualisierung", "Audio zu Bild",
              "Stem Trennungskunst", "Verarbeitungsträume", "Unendliche Kreativität",
              "Einzigartige Vision", "Generierter Moment", "Vergängliche Schönheit",
              "Sonische Leinwand", "Frequenzkunst", "Wellenformpoesie"},
    }
    local subs = subtitleParts[lang] or subtitleParts.EN
    local subIdx = (proceduralArt.seed % #subs) + 1
    proceduralArt.subtitle = subs[subIdx] .. " #" .. (proceduralArt.seed % 10000)

    -- Pre-generate elements based on style (more elements for richer animations)
    proceduralArt.elements = {}
    local seed = proceduralArt.seed

    -- Generate 80 elements for more complex animations
    for i = 1, 80 do
        -- Clamp random values to prevent out-of-bounds array access
        local colorVal = math.min(3.999, seededRandom(seed, i * 13) * 4)
        local shapeVal = math.min(5.999, seededRandom(seed, i * 17) * 6)  -- More shape variety
        local elem = {
            x = seededRandom(seed, i * 3) * 2 - 1,
            y = seededRandom(seed, i * 3 + 1) * 2 - 1,
            size = seededRandom(seed, i * 3 + 2) * 0.4 + 0.03,
            speed = seededRandom(seed, i * 7) * 3 + 0.3,
            phase = seededRandom(seed, i * 11) * math.pi * 2,
            colorIdx = math.floor(colorVal) + 1,  -- 1-4
            shape = math.floor(shapeVal) + 1,     -- 1-6 (more shapes!)
            rotation = seededRandom(seed, i * 19) * math.pi * 2,
            rotSpeed = (seededRandom(seed, i * 23) - 0.5) * 3,
            -- New parameters for audio reactivity
            audioSensitivity = seededRandom(seed, i * 29) * 2,  -- How much it reacts to audio
            frequencyBand = math.floor(seededRandom(seed, i * 31) * 3) + 1,  -- 1=bass, 2=mid, 3=high
            pulseRate = seededRandom(seed, i * 37) * 4 + 1,
            trailLength = math.floor(seededRandom(seed, i * 41) * 5),
        }
        table.insert(proceduralArt.elements, elem)
    end
end

-- Draw procedural art in a given area (MEGA VERSION with 100+ styles + audio reactivity!)
-- rotation: optional rotation angle in radians (applied to animated elements)
-- skipBackground: if true, don't draw the dark background (caller handles it)
-- alphaMult: optional alpha multiplier for crossfade transitions (0-1)
-- overrideSeed/overrideStyle: optional overrides for drawing old pattern during crossfade
local function drawProceduralArtInternal(x, y, w, h, time, rotation, skipBackground, alphaMult, overrideSeed, overrideStyle)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
        if not skipBackground then
            gfx.set(THEME.bg[1], THEME.bg[2], THEME.bg[3], alphaMult or 1)
            gfx.rect(x, y, w, h, 1)
        end
        return
    end

    rotation = rotation or 0
    alphaMult = alphaMult or 1.0
    local seed = overrideSeed or proceduralArt.seed
    local style = overrideStyle or proceduralArt.style
    local cx, cy = x + w/2, y + h/2
    local radius = math.min(w, h) / 2 * 0.9

    -- Get audio reactive values (if available)
    updateAudioReactivity()
    local audioPeak = audioReactive.smoothPeakMono or 0
    local audioBass = audioReactive.smoothBass or 0
    local audioMid = audioReactive.smoothMid or 0
    local audioHigh = audioReactive.smoothHigh or 0
    local audioBeat = audioReactive.beatDecay or 0

    -- Helper: rotate point around center
    local function rotatePoint(px, py)
        if rotation == 0 then return px, py end
        local dx, dy = px - cx, py - cy
        local cos_r, sin_r = math.cos(rotation), math.sin(rotation)
        return cx + dx * cos_r - dy * sin_r, cy + dx * sin_r + dy * cos_r
    end

    -- Rainbow color cycling (psychedelic!)
    local function rainbowShift(baseColor, phase)
        if not baseColor or not baseColor[1] then
            baseColor = colors[1]
        end
        local r = baseColor[1] + math.sin(phase) * 0.3
        local g = baseColor[2] + math.sin(phase + 2.1) * 0.3
        local b = baseColor[3] + math.sin(phase + 4.2) * 0.3
        return math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b))
    end

    -- STEM colors for art (synced with STEM_BORDER_COLORS which is global)
    local colors = {}
    if STEM_BORDER_COLORS then
        for i=1, 4 do
            local c = STEM_BORDER_COLORS[i]
            colors[i] = {c[1]/255, c[2]/255, c[3]/255}
        end
    else
        colors = {
            {1.0, 0.4, 0.4},   -- Vocals red
            {0.4, 0.8, 1.0},   -- Drums blue
            {0.6, 0.4, 1.0},   -- Bass purple
            {0.4, 1.0, 0.6},   -- Other green
        }
    end

    -- Dark semi-transparent background for art area (unless caller handles it)
    if not skipBackground then
        local bg = THEME and THEME.bg or {0.05, 0.05, 0.08}
        gfx.set(bg[1], bg[2], bg[3], 0.95)
        gfx.rect(x, y, w, h, 1)
    end

    -- Decompose style into components for 1000 combinations (100 MilkDrop-inspired patterns!)
    -- style 1-1000 maps to: basePattern (1-100) x variation (1-10)
    local basePattern = ((style - 1) % 100) + 1
    local variation = math.floor((style - 1) / 100) + 1

    -- Audio-responsive modifiers based on variation
    local audioMult = 1 + (variation / 10) * audioPeak * 2
    local speedMult = 1 + (variation % 3) * 0.3 + audioMid * 0.5
    local sizeMult = 1 + (variation % 4) * 0.2 + audioBass * 0.6
    local colorShift = time * (variation % 5) * 0.5 + audioPeak * 3

    -- === BASE PATTERN 1: Cosmic Waves ===
    if basePattern == 1 then
        local layers = 6 + (variation % 5)
        for layer = 1, layers do
            local col = colors[(layer % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + layer * 0.5)
            local alpha = (0.1 + (layer / layers) * 0.25 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.8, alpha))

            local waveFreq = 4 + (variation % 4) * 2
            local waveAmp = radius * (0.2 + audioBass * 0.3)

            for i = 0, w, 2 do
                local wave = math.sin((i / w) * waveFreq * math.pi + time * speedMult * 2 + layer * 0.5) * waveAmp
                local wave2 = math.cos((i / w) * (waveFreq - 2) * math.pi - time * speedMult * 1.5) * waveAmp * 0.6
                local yPos = cy + wave + wave2 + (layer - layers/2) * (12 + audioHigh * 10)
                local px, py = rotatePoint(x + i, yPos)
                local dotSize = (2 + layer * 0.3 + audioPeak * 3) * sizeMult
                gfx.circle(px, py, dotSize, 1, 1)
            end
        end

    -- === BASE PATTERN 2: Neural Network ===
    elseif basePattern == 2 then
        local nodeCount = 15 + variation * 3
        local nodes = {}
        for i = 1, nodeCount do
            local nx = cx + seededRandom(seed, i) * w * 0.8 - w * 0.4
            local ny = cy + seededRandom(seed, i + 100) * h * 0.8 - h * 0.4
            -- Audio-reactive node movement
            nx = nx + math.sin(time * speedMult + i) * (20 + audioBass * 30)
            ny = ny + math.cos(time * speedMult * 0.7 + i) * (15 + audioMid * 25)
            local px, py = rotatePoint(nx, ny)
            nodes[i] = {x = px, y = py, col = colors[(i % 4) + 1]}
        end

        local connectionDist = 100 + variation * 20 + audioPeak * 50
        for i = 1, #nodes do
            for j = i + 1, #nodes do
                local dist = math.sqrt((nodes[i].x - nodes[j].x)^2 + (nodes[i].y - nodes[j].y)^2)
                if dist < connectionDist then
                    local alpha = (1 - dist / connectionDist) * 0.4 * (0.5 + 0.5 * math.sin(time * 3 + i + j)) + audioBeat * 0.2
                    local r, g, b = rainbowShift(nodes[i].col, colorShift + i)
                    gfx.set(r, g, b, math.min(0.6, alpha))
                    gfx.line(nodes[i].x, nodes[i].y, nodes[j].x, nodes[j].y)
                end
            end
        end

        for i, node in ipairs(nodes) do
            local pulse = 1 + 0.4 * math.sin(time * 4 + i) + audioPeak * 0.5
            local r, g, b = rainbowShift(node.col, colorShift + i * 0.3)
            gfx.set(r, g, b, 0.7 + audioBeat * 0.3)
            gfx.circle(node.x, node.y, (4 + variation) * pulse * sizeMult, 1, 1)
        end

    -- === BASE PATTERN 3: Crystal Formation ===
    elseif basePattern == 3 then
        local crystalCount = 20 + variation * 5
        for i = 1, crystalCount do
            local angle = seededRandom(seed, i) * math.pi * 2 + time * 0.1 * speedMult
            local dist = seededRandom(seed, i + 50) * radius * (0.7 + audioBass * 0.4)
            local size = (seededRandom(seed, i + 100) * 25 + 8 + audioPeak * 20) * sizeMult
            local col = colors[(i % 4) + 1]
            local px = cx + math.cos(angle) * dist
            local py = cy + math.sin(angle) * dist
            px, py = rotatePoint(px, py)
            local rot = angle + time * 0.3 * speedMult

            local r, g, b = rainbowShift(col, colorShift + i * 0.2)
            local sides = 4 + (variation % 3)
            gfx.set(r, g, b, 0.35 + audioBeat * 0.2)

            for j = 0, sides - 1 do
                local a1 = rot + (j / sides) * math.pi * 2
                local a2 = rot + ((j + 1) / sides) * math.pi * 2
                local stretch = 0.4 + (variation % 4) * 0.15
                gfx.line(px + math.cos(a1) * size, py + math.sin(a1) * size * stretch,
                         px + math.cos(a2) * size, py + math.sin(a2) * size * stretch)
            end
        end

    -- === BASE PATTERN 4: Spiral Galaxy ===
    elseif basePattern == 4 then
        local arms = 2 + (variation % 4)
        local spiralTightness = 3 + variation
        for arm = 1, arms do
            local col = colors[(arm % 4) + 1]
            local armOffset = (arm - 1) * (math.pi * 2 / arms)
            local starCount = 150 + variation * 30

            for i = 0, starCount do
                local t = i / starCount
                local angle = t * math.pi * spiralTightness + armOffset + time * 0.2 * speedMult
                local dist = t * radius * (1 + audioBass * 0.3)
                local px = cx + math.cos(angle) * dist
                local py = cy + math.sin(angle) * dist * 0.5
                px, py = rotatePoint(px, py)

                local r, g, b = rainbowShift(col, colorShift + t * 2)
                local alpha = (1 - t) * 0.5 + audioBeat * 0.2
                local size = ((1 - t) * 3 + 1 + audioPeak * 2) * sizeMult
                gfx.set(r, g, b, math.min(0.8, alpha))
                gfx.circle(px, py, size, 1, 1)
            end
        end

        -- Audio-reactive center glow
        local glowSize = 25 + audioBass * 30
        for r = glowSize, 5, -3 do
            local glowAlpha = 0.08 + audioBeat * 0.1
            gfx.set(1, 0.9 + audioHigh * 0.1, 0.6 + audioPeak * 0.2, glowAlpha)
            gfx.circle(cx, cy, r, 1, 1)
        end

    -- === BASE PATTERN 5: Mandala Dream ===
    elseif basePattern == 5 then
        local segments = 8 + variation * 2
        local rings = 5 + (variation % 4)

        for ring = 1, rings do
            local ringRadius = ring * radius / (rings + 1) * (1 + audioBass * 0.3)
            local col = colors[(ring % 4) + 1]
            local ringSpeed = (ring % 2 == 0 and 1 or -1) * speedMult

            for seg = 0, segments - 1 do
                local angle = (seg / segments) * math.pi * 2 + time * 0.15 * ringSpeed
                local px = cx + math.cos(angle) * ringRadius
                local py = cy + math.sin(angle) * ringRadius
                px, py = rotatePoint(px, py)

                local r, g, b = rainbowShift(col, colorShift + ring + seg * 0.1)
                gfx.set(r, g, b, 0.4 + audioBeat * 0.2)
                local nodeSize = (4 + ring * 1.5 + audioPeak * 5) * sizeMult
                gfx.circle(px, py, nodeSize, 1, 1)

                -- Connecting lines
                if ring > 1 then
                    local innerRadius = (ring - 1) * radius / (rings + 1) * (1 + audioBass * 0.3)
                    local ix = cx + math.cos(angle) * innerRadius
                    local iy = cy + math.sin(angle) * innerRadius
                    ix, iy = rotatePoint(ix, iy)
                    gfx.set(r, g, b, 0.15 + audioMid * 0.1)
                    gfx.line(px, py, ix, iy)
                end
            end
        end

    -- === BASE PATTERN 6: Particle Storm ===
    elseif basePattern == 6 then
        for idx, elem in ipairs(proceduralArt.elements) do
            if idx > 60 then break end  -- Limit for performance
            local col = colors[elem.colorIdx]
            local audioBoost = elem.audioSensitivity * (
                elem.frequencyBand == 1 and audioBass or
                elem.frequencyBand == 2 and audioMid or audioHigh
            )

            local px = cx + elem.x * w * 0.45 + math.sin(time * elem.speed * speedMult + elem.phase) * (25 + audioBoost * 40)
            local py = cy + elem.y * h * 0.45 + math.cos(time * elem.speed * speedMult * 0.7 + elem.phase) * (20 + audioBoost * 30)
            px, py = rotatePoint(px, py)

            local size = elem.size * 18 * (1 + 0.4 * math.sin(time * elem.pulseRate + elem.phase) + audioBoost * 0.8) * sizeMult
            local r, g, b = rainbowShift(col, colorShift + elem.phase)
            gfx.set(r, g, b, 0.5 + audioBeat * 0.3)
            gfx.circle(px, py, size, 1, 1)

            -- Trails
            local trails = elem.trailLength + math.floor(audioPeak * 3)
            for trail = 1, trails do
                local tx = px - math.sin(time * elem.speed * speedMult + elem.phase) * trail * (6 + audioHigh * 4)
                local ty = py - math.cos(time * elem.speed * speedMult * 0.7 + elem.phase) * trail * (6 + audioHigh * 4)
                gfx.set(r, g, b, (0.15 + audioBeat * 0.1) / trail)
                gfx.circle(tx, ty, size * 0.6, 1, 1)
            end
        end

    -- === BASE PATTERN 7: Geometric Pulse ===
    elseif basePattern == 7 then
        local shapes = 6 + variation
        for i = 1, shapes do
            local col = colors[(i % 4) + 1]
            local pulse = 1 + 0.25 * math.sin(time * 2 * speedMult + i * 0.5) + audioBass * 0.4
            local size = (radius / shapes) * i * pulse * sizeMult
            local rot = time * 0.2 * speedMult * (i % 2 == 0 and 1 or -1) + i * 0.2 + rotation
            local sides = 3 + ((i + variation) % 5)

            local r, g, b = rainbowShift(col, colorShift + i * 0.4)
            gfx.set(r, g, b, 0.25 + audioBeat * 0.2)

            for j = 0, sides - 1 do
                local a1 = rot + (j / sides) * math.pi * 2
                local a2 = rot + ((j + 1) / sides) * math.pi * 2
                local x1, y1 = cx + math.cos(a1) * size, cy + math.sin(a1) * size
                local x2, y2 = cx + math.cos(a2) * size, cy + math.sin(a2) * size
                gfx.line(x1, y1, x2, y2)
            end
        end

    -- === BASE PATTERN 8: Prism Light ===
    elseif basePattern == 8 then
        local rays = 15 + variation * 3
        for ray = 1, rays do
            local angle = seededRandom(seed, ray) * math.pi * 2
            local col = colors[(ray % 4) + 1]
            local rayLen = radius * (0.4 + seededRandom(seed, ray + 50) * 0.5 + audioPeak * 0.3)
            local wobble = math.sin(time * 2 * speedMult + ray) * 0.15

            for band = 0, 4 do
                local bandAngle = angle + band * 0.04 + wobble + rotation
                local alpha = (0.12 - band * 0.02 + audioBeat * 0.1) * audioMult
                local r, g, b = rainbowShift(col, colorShift + band + ray * 0.1)
                gfx.set(r, g, b, math.min(0.5, alpha))
                gfx.line(cx, cy, cx + math.cos(bandAngle) * rayLen, cy + math.sin(bandAngle) * rayLen)
            end
        end

        -- Pulsing center
        local centerSize = 12 + audioBass * 15
        gfx.set(1, 1, 1, 0.25 + audioBeat * 0.3)
        gfx.circle(cx, cy, centerSize, 1, 1)

    -- === BASE PATTERN 9: Fluid Blobs ===
    elseif basePattern == 9 then
        local blobs = 4 + (variation % 4)
        for layer = 1, blobs do
            local col = colors[(layer % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + layer)
            gfx.set(r, g, b, 0.12 + audioBeat * 0.1)

            local offsetX = math.sin(time * speedMult + layer * 1.3) * (40 + audioBass * 50)
            local offsetY = math.cos(time * speedMult * 0.8 + layer * 1.7) * (30 + audioMid * 40)
            local blobSize = radius * (0.3 + layer * 0.08 + audioPeak * 0.2) * sizeMult

            local blobCx = cx + offsetX
            local blobCy = cy + offsetY

            local points = 60 + variation * 10
            for i = 0, points do
                local angle = (i / points) * math.pi * 2
                local noise = math.sin(angle * (3 + variation) + time * 2 * speedMult + layer) * 0.35
                local blobR = blobSize * (1 + noise + audioHigh * 0.3)
                local bx = blobCx + math.cos(angle + rotation) * blobR
                local by = blobCy + math.sin(angle + rotation) * blobR
                gfx.circle(bx, by, 2 + audioPeak * 2, 1, 1)
            end
        end

    -- === BASE PATTERN 10: Hypnotic Rings ===
    elseif basePattern == 10 then
        local ringCount = 8 + variation
        for i = 1, ringCount do
            local ringRadius = (radius / ringCount) * i * (1 + audioBass * 0.2)
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.3)

            local phase = time * speedMult * (i % 2 == 0 and 1 or -1) + i * 0.3
            local thickness = 2 + (variation % 3) + audioPeak * 3
            local alpha = 0.2 + (i / ringCount) * 0.2 + audioBeat * 0.15

            gfx.set(r, g, b, math.min(0.7, alpha))

            -- Draw ring as series of points for rotation support
            local segments = 60
            for j = 0, segments - 1 do
                local a1 = (j / segments) * math.pi * 2 + phase + rotation
                local wobble = math.sin(a1 * (3 + variation % 4) + time * 3) * (5 + audioHigh * 10)
                local x1 = cx + math.cos(a1) * (ringRadius + wobble)
                local y1 = cy + math.sin(a1) * (ringRadius + wobble)
                gfx.circle(x1, y1, thickness, 1, 1)
            end
        end

    -- === BASE PATTERN 11: Feedback Tunnel (MilkDrop-inspired) ===
    elseif basePattern == 11 then
        -- Concentric rings zooming inward with warp
        local ringCount = 12 + variation
        local maxRadius = radius * (1.5 + audioBass * 0.5)

        for ring = 1, ringCount do
            -- Ring position oscillates based on time (zoom feedback effect)
            local ringPhase = (time * speedMult * 0.5 + ring * 0.15) % 1
            local ringRadius = maxRadius * ringPhase

            -- MilkDrop-style warp based on distance from center
            local warpAmount = 0.2 + audioMid * 0.3

            local col = colors[(ring % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ring * 0.2 + ringPhase * 2)
            local alpha = (1 - ringPhase) * 0.4 + audioBeat * 0.2
            gfx.set(r, g, b, math.min(0.8, alpha))

            -- Draw ring with warp distortion
            local segments = 60
            for j = 0, segments - 1 do
                local angle = (j / segments) * math.pi * 2
                -- Warp effect: radius varies with angle
                local warp = 1 + math.sin(angle * (3 + variation) + time * 2) * warpAmount
                local warpedRadius = ringRadius * warp

                local x1 = cx + math.cos(angle + rotation) * warpedRadius
                local y1 = cy + math.sin(angle + rotation) * warpedRadius
                local dotSize = (3 - ringPhase * 2 + audioPeak * 2) * sizeMult
                gfx.circle(x1, y1, math.max(1, dotSize), 1, 1)
            end
        end

        -- Center glow (MilkDrop-style bright center)
        local centerGlow = 20 + audioBass * 30 + audioBeat * 20
        for r = centerGlow, 5, -3 do
            local glowAlpha = 0.1 + audioBeat * 0.15
            gfx.set(1, 0.9, 0.7, glowAlpha)
            gfx.circle(cx, cy, r, 1, 1)
        end

    -- === BASE PATTERN 12: Waveform Ring (MilkDrop-inspired audio visualization) ===
    elseif basePattern == 12 then
        -- Circular audio waveform display
        local waveRings = 3 + (variation % 3)

        for ring = 1, waveRings do
            local baseRadius = radius * (0.3 + ring * 0.2) * (1 + audioBass * 0.2)
            local col = colors[(ring % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ring)

            -- Draw waveform ring using history buffer
            local points = audioReactive.waveformSize or 60
            local prevX, prevY

            for i = 0, points - 1 do
                local angle = (i / points) * math.pi * 2 + time * 0.3 * speedMult * (ring % 2 == 0 and 1 or -1)

                -- Get waveform value from history
                local histIdx = ((audioReactive.waveformIndex or 1) + i) % (audioReactive.waveformSize or 60) + 1
                local waveVal = (audioReactive.waveformHistory and audioReactive.waveformHistory[histIdx]) or audioPeak * 0.5

                -- Waveform modulates radius
                local waveRadius = baseRadius * (1 + waveVal * 0.5 * (1 + variation * 0.1))

                local wx = cx + math.cos(angle + rotation) * waveRadius
                local wy = cy + math.sin(angle + rotation) * waveRadius

                local alpha = 0.3 + waveVal * 0.4 + audioBeat * 0.2
                gfx.set(r, g, b, math.min(0.8, alpha))

                local dotSize = (2 + waveVal * 4 + audioPeak * 3) * sizeMult
                gfx.circle(wx, wy, dotSize, 1, 1)

                -- Connect dots with lines
                if prevX and i > 0 then
                    gfx.set(r, g, b, alpha * 0.5)
                    gfx.line(prevX, prevY, wx, wy)
                end
                prevX, prevY = wx, wy
            end

            -- Close the ring
            if prevX then
                local angle = rotation + time * 0.3 * speedMult * (ring % 2 == 0 and 1 or -1)
                local histIdx = ((audioReactive.waveformIndex or 1)) % (audioReactive.waveformSize or 60) + 1
                local waveVal = (audioReactive.waveformHistory and audioReactive.waveformHistory[histIdx]) or audioPeak * 0.5
                local waveRadius = baseRadius * (1 + waveVal * 0.5)
                local wx = cx + math.cos(angle + rotation) * waveRadius
                local wy = cy + math.sin(angle + rotation) * waveRadius
                gfx.set(r, g, b, 0.2)
                gfx.line(prevX, prevY, wx, wy)
            end
        end

    -- === BASE PATTERN 13: Supernova Burst ===
    elseif basePattern == 13 then
        -- Explosive rays from center with beat-triggered bursts
        local rayCount = 20 + variation * 4
        local burstIntensity = audioBeat > 0.3 and (audioBeat * 2) or 1

        for ray = 1, rayCount do
            local baseAngle = (ray / rayCount) * math.pi * 2 + time * 0.1 * speedMult
            local col = colors[(ray % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ray * 0.15)

            -- Ray length pulses with audio
            local rayLen = radius * (0.3 + seededRandom(seed, ray) * 0.7)
            rayLen = rayLen * (1 + audioPeak * 0.5) * burstIntensity

            -- Multi-layered glow rays
            for layer = 1, 3 do
                local layerAngle = baseAngle + (layer - 2) * 0.02
                local layerLen = rayLen * (1 - layer * 0.1)
                local alpha = (0.3 / layer + audioBeat * 0.15) * audioMult

                gfx.set(r, g, b, math.min(0.6, alpha))

                local endX = cx + math.cos(layerAngle + rotation) * layerLen
                local endY = cy + math.sin(layerAngle + rotation) * layerLen
                gfx.line(cx, cy, endX, endY)
            end

            -- Particle debris at ray ends
            if audioBeat > 0.2 then
                local debrisAngle = baseAngle + seededRandom(seed, ray + 100) * 0.3
                local debrisLen = rayLen * (0.8 + seededRandom(seed, ray + 200) * 0.4)
                local dx = cx + math.cos(debrisAngle + rotation) * debrisLen
                local dy = cy + math.sin(debrisAngle + rotation) * debrisLen
                local debrisSize = (2 + audioPeak * 4) * sizeMult
                gfx.set(1, 1, 1, audioBeat * 0.5)
                gfx.circle(dx, dy, debrisSize, 1, 1)
            end
        end

        -- Pulsing center core
        local coreSize = 15 + audioBass * 25 + audioBeat * 30
        for r = coreSize, 5, -3 do
            local coreAlpha = 0.15 + audioBeat * 0.2
            gfx.set(1, 0.9 + audioHigh * 0.1, 0.5 + audioPeak * 0.3, coreAlpha)
            gfx.circle(cx, cy, r, 1, 1)
        end

    -- === BASE PATTERN 14: DNA Helix ===
    elseif basePattern == 14 then
        -- Double helix structure with connecting rungs
        local helixPoints = 40 + variation * 5
        local helixHeight = h * 0.8
        local helixWidth = radius * (0.6 + audioBass * 0.3)
        local startY = cy - helixHeight / 2

        for i = 0, helixPoints do
            local t = i / helixPoints
            local phase = t * math.pi * (3 + variation) + time * speedMult

            -- Two strands of the helix
            for strand = 1, 2 do
                local strandPhase = phase + (strand - 1) * math.pi
                local xOffset = math.sin(strandPhase) * helixWidth
                local zDepth = math.cos(strandPhase)  -- Simulated depth

                local hx = cx + xOffset + rotation * 50
                local hy = startY + t * helixHeight
                hx, hy = rotatePoint(hx, hy)

                -- Size and alpha based on "depth"
                local depthScale = 0.5 + (zDepth + 1) * 0.25
                local col = colors[strand == 1 and 1 or 3]  -- Red and Purple strands
                local r, g, b = rainbowShift(col, colorShift + t * 2)
                local alpha = (0.3 + depthScale * 0.4 + audioPeak * 0.2) * audioMult

                gfx.set(r, g, b, math.min(0.8, alpha))
                local dotSize = (4 + depthScale * 4 + audioPeak * 3) * sizeMult
                gfx.circle(hx, hy, dotSize, 1, 1)
            end

            -- Connecting rungs (base pairs) - every few points
            if i % 4 == 0 then
                local phase1 = (i / helixPoints) * math.pi * (3 + variation) + time * speedMult
                local phase2 = phase1 + math.pi

                local x1 = cx + math.sin(phase1) * helixWidth + rotation * 50
                local x2 = cx + math.sin(phase2) * helixWidth + rotation * 50
                local hy = startY + t * helixHeight

                local rungCol = colors[(math.floor(i / 4) % 4) + 1]
                local r, g, b = rainbowShift(rungCol, colorShift + i * 0.1)
                gfx.set(r, g, b, 0.2 + audioMid * 0.15)

                local rx1, ry1 = rotatePoint(x1, hy)
                local rx2, ry2 = rotatePoint(x2, hy)
                gfx.line(rx1, ry1, rx2, ry2)
            end
        end

    -- === BASE PATTERN 15: Fractal Tree ===
    elseif basePattern == 15 then
        -- Recursive branching structure with audio-reactive angles
        local maxDepth = 5 + (variation % 3)
        local branchAngle = math.pi / (4 + audioMid * 2)  -- Angle varies with mid frequencies
        local lengthRatio = 0.7 + audioBass * 0.15

        -- Iterative tree drawing (avoid actual recursion for performance)
        local branches = {{x = cx, y = cy + radius * 0.4, angle = -math.pi/2, len = radius * 0.4, depth = 0}}
        local drawnBranches = {}

        while #branches > 0 and #drawnBranches < 200 do
            local branch = table.remove(branches, 1)

            if branch.depth < maxDepth then
                local endX = branch.x + math.cos(branch.angle + rotation) * branch.len
                local endY = branch.y + math.sin(branch.angle + rotation) * branch.len

                -- Draw branch
                local col = colors[(branch.depth % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + branch.depth * 0.5)
                local alpha = (0.4 - branch.depth * 0.05 + audioPeak * 0.2) * audioMult
                local thickness = math.max(1, (maxDepth - branch.depth) * 1.5 * sizeMult)

                gfx.set(r, g, b, math.min(0.7, alpha))
                -- Draw thick line as multiple parallel lines
                for t = -thickness/2, thickness/2 do
                    gfx.line(branch.x + t * 0.3, branch.y, endX + t * 0.3, endY)
                end

                table.insert(drawnBranches, {x = endX, y = endY, depth = branch.depth})

                -- Add child branches
                local newLen = branch.len * lengthRatio
                local angleVar = (seededRandom(seed, #drawnBranches) - 0.5) * 0.3 + audioHigh * 0.2

                -- Left branch
                table.insert(branches, {
                    x = endX, y = endY,
                    angle = branch.angle - branchAngle + angleVar,
                    len = newLen, depth = branch.depth + 1
                })
                -- Right branch
                table.insert(branches, {
                    x = endX, y = endY,
                    angle = branch.angle + branchAngle - angleVar,
                    len = newLen, depth = branch.depth + 1
                })
            end
        end

        -- Draw leaves/particles at branch ends on beats
        if audioBeat > 0.2 then
            for _, branch in ipairs(drawnBranches) do
                if branch.depth >= maxDepth - 1 then
                    local col = colors[(branch.depth % 4) + 1]
                    local r, g, b = rainbowShift(col, colorShift + branch.depth)
                    gfx.set(r, g, b, audioBeat * 0.4)
                    local leafSize = (3 + audioPeak * 4) * sizeMult
                    gfx.circle(branch.x, branch.y, leafSize, 1, 1)
                end
            end
        end

    -- === BASE PATTERN 16: Plasma Field (MilkDrop classic) ===
    elseif basePattern == 16 then
        -- Classic plasma effect with sine wave interference
        local cellSize = math.max(4, 12 - variation) * sizeMult
        for px = x, x + w, cellSize do
            for py = y, y + h, cellSize do
                local dx = (px - cx) / radius
                local dy = (py - cy) / radius

                -- Multiple sine waves create plasma
                local v1 = math.sin(dx * 3 + time * speedMult)
                local v2 = math.sin(dy * 3 + time * speedMult * 0.7)
                local v3 = math.sin((dx + dy) * 2 + time * speedMult * 1.3)
                local v4 = math.sin(math.sqrt(dx*dx + dy*dy) * 4 - time * speedMult * 0.5 + audioBass * 2)
                local plasma = (v1 + v2 + v3 + v4) / 4

                local colorIdx = math.floor((plasma + 1) * 2) % 4 + 1
                local col = colors[colorIdx]
                local r, g, b = rainbowShift(col, colorShift + plasma * 2)
                local alpha = (0.3 + plasma * 0.2 + audioPeak * 0.2) * audioMult
                gfx.set(r, g, b, math.min(0.7, math.abs(alpha)))
                gfx.rect(px, py, cellSize - 1, cellSize - 1, 1)
            end
        end

    -- === BASE PATTERN 17: Starfield (MilkDrop 3D stars) ===
    elseif basePattern == 17 then
        local starCount = 100 + variation * 20
        for i = 1, starCount do
            -- 3D star position using seed
            local starSeed = seed + i * 7
            local starAngle = seededRandom(starSeed, 1) * math.pi * 2
            local starZ = ((seededRandom(starSeed, 2) + time * 0.1 * speedMult + i * 0.01) % 1)
            local starDist = seededRandom(starSeed, 3) * 0.8 + 0.1

            -- Project 3D to 2D (perspective)
            local perspective = 1 / (starZ + 0.3)
            local sx = cx + math.cos(starAngle) * starDist * radius * perspective
            local sy = cy + math.sin(starAngle) * starDist * radius * 0.5 * perspective

            if sx > x and sx < x + w and sy > y and sy < y + h then
                local starSize = (1 + (1 - starZ) * 3 + audioPeak * 2) * sizeMult
                local starAlpha = (1 - starZ) * 0.6 + audioBeat * 0.2

                local col = colors[(i % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + starZ * 3)
                gfx.set(r, g, b, math.min(0.9, starAlpha))
                gfx.circle(sx, sy, starSize, 1, 1)

                -- Star trail
                if starZ < 0.5 then
                    local trailLen = (0.5 - starZ) * 20 * sizeMult
                    gfx.set(r, g, b, starAlpha * 0.3)
                    local trailX = sx - math.cos(starAngle) * trailLen * perspective
                    local trailY = sy - math.sin(starAngle) * trailLen * 0.5 * perspective
                    gfx.line(sx, sy, trailX, trailY)
                end
            end
        end

    -- === BASE PATTERN 18: Tunnel Warp (MilkDrop zoom) ===
    elseif basePattern == 18 then
        local segments = 24 + variation * 4
        local rings = 15
        for ring = rings, 1, -1 do
            local ringZ = ((ring / rings) + time * 0.3 * speedMult) % 1
            local ringRadius = radius * (1 - ringZ) * 1.5

            -- Warp amount increases with distance
            local warp = 0.1 + ringZ * 0.3 + audioMid * 0.2

            local col = colors[(ring % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ringZ * 4)
            local alpha = ringZ * 0.4 + audioBeat * 0.15
            gfx.set(r, g, b, math.min(0.6, alpha))

            for seg = 0, segments - 1 do
                local angle1 = (seg / segments) * math.pi * 2 + time * 0.2
                local angle2 = ((seg + 1) / segments) * math.pi * 2 + time * 0.2

                local warp1 = 1 + math.sin(angle1 * 3 + time * 2) * warp * (1 + audioBass)
                local warp2 = 1 + math.sin(angle2 * 3 + time * 2) * warp * (1 + audioBass)

                local x1 = cx + math.cos(angle1 + rotation) * ringRadius * warp1
                local y1 = cy + math.sin(angle1 + rotation) * ringRadius * warp1 * 0.6
                local x2 = cx + math.cos(angle2 + rotation) * ringRadius * warp2
                local y2 = cy + math.sin(angle2 + rotation) * ringRadius * warp2 * 0.6

                gfx.line(x1, y1, x2, y2)
            end
        end

    -- === BASE PATTERN 19: Kaleidoscope (MilkDrop symmetry) ===
    elseif basePattern == 19 then
        local symmetry = 6 + (variation % 4) * 2  -- 6, 8, 10, or 12 fold
        local elementCount = 20 + variation * 5

        for elem = 1, elementCount do
            local elemPhase = time * speedMult + elem * 0.3
            local elemDist = (seededRandom(seed, elem) * 0.7 + 0.2) * radius * (1 + audioBass * 0.3)
            local elemAngle = seededRandom(seed, elem + 100) * math.pi * 2 / symmetry + elemPhase * 0.1
            local elemSize = (seededRandom(seed, elem + 200) * 15 + 5 + audioPeak * 10) * sizeMult

            local col = colors[(elem % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + elem * 0.2)
            local alpha = (0.3 + math.sin(elemPhase * 2) * 0.15 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.7, alpha))

            -- Draw element at all symmetry positions
            for sym = 0, symmetry - 1 do
                local symAngle = elemAngle + (sym / symmetry) * math.pi * 2
                local ex = cx + math.cos(symAngle + rotation) * elemDist
                local ey = cy + math.sin(symAngle + rotation) * elemDist
                gfx.circle(ex, ey, elemSize, 1, 1)
            end
        end

    -- === BASE PATTERN 20: Electric Arcs ===
    elseif basePattern == 20 then
        local arcCount = 8 + variation
        for arc = 1, arcCount do
            local arcPhase = time * speedMult * 0.5 + arc * 0.8
            local startAngle = (arc / arcCount) * math.pi * 2 + time * 0.1
            local arcLen = math.pi * (0.3 + seededRandom(seed, arc) * 0.5)

            local col = colors[(arc % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + arc)

            -- Draw jagged electric arc
            local segments = 20 + math.floor(audioPeak * 10)
            local prevX, prevY
            local arcRadius = radius * (0.5 + seededRandom(seed, arc + 50) * 0.4 + audioBass * 0.2)

            for seg = 0, segments do
                local t = seg / segments
                local angle = startAngle + t * arcLen
                local jitter = (seededRandom(seed, arc * 100 + seg) - 0.5) * 30 * (1 + audioHigh)
                local segRadius = arcRadius + jitter + math.sin(arcPhase + t * 10) * 10

                local ax = cx + math.cos(angle + rotation) * segRadius
                local ay = cy + math.sin(angle + rotation) * segRadius

                local alpha = (0.4 + math.sin(arcPhase + t * 5) * 0.2 + audioBeat * 0.3) * audioMult
                gfx.set(r, g, b, math.min(0.8, alpha))

                if prevX then
                    gfx.line(prevX, prevY, ax, ay)
                    -- Glow
                    gfx.set(r, g, b, alpha * 0.3)
                    gfx.line(prevX + 1, prevY + 1, ax + 1, ay + 1)
                end
                prevX, prevY = ax, ay
            end
        end

    -- === BASE PATTERN 21: Morphing Shapes ===
    elseif basePattern == 21 then
        local shapeCount = 5 + variation
        for shape = 1, shapeCount do
            local shapePhase = time * speedMult * 0.3 + shape * 1.2
            local shapeDist = radius * (0.2 + shape * 0.12) * (1 + audioBass * 0.3)

            -- Morph between different polygon sides
            local sidesBase = 3 + (shape % 5)
            local sidesMorph = sidesBase + math.sin(shapePhase) * 2
            local sides = math.max(3, math.floor(sidesMorph + 0.5))

            local col = colors[(shape % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + shape * 0.5)
            local alpha = (0.25 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.6, alpha))

            local shapeRot = shapePhase * 0.5 + rotation
            for side = 0, sides do
                local a1 = shapeRot + (side / sides) * math.pi * 2
                local a2 = shapeRot + ((side + 1) / sides) * math.pi * 2

                local breathe = 1 + math.sin(shapePhase * 2 + side * 0.5) * 0.2 + audioPeak * 0.3
                local x1 = cx + math.cos(a1) * shapeDist * breathe
                local y1 = cy + math.sin(a1) * shapeDist * breathe
                local x2 = cx + math.cos(a2) * shapeDist * breathe
                local y2 = cy + math.sin(a2) * shapeDist * breathe

                gfx.line(x1, y1, x2, y2)
            end
        end

    -- === BASE PATTERN 22: Particle Vortex ===
    elseif basePattern == 22 then
        local particleCount = 150 + variation * 30
        for p = 1, particleCount do
            local pSeed = seed + p * 13
            local pAngle = seededRandom(pSeed, 1) * math.pi * 2
            local pDist = seededRandom(pSeed, 2)
            local pSpeed = seededRandom(pSeed, 3) * 0.5 + 0.5

            -- Spiral inward motion
            local spiralAngle = pAngle + time * pSpeed * speedMult + pDist * 3
            local spiralDist = pDist * radius * (1 + audioBass * 0.3)

            local px = cx + math.cos(spiralAngle + rotation) * spiralDist
            local py = cy + math.sin(spiralAngle + rotation) * spiralDist * 0.6

            local pSize = ((1 - pDist) * 4 + 1 + audioPeak * 3) * sizeMult
            local col = colors[(p % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + pDist * 2)
            local alpha = ((1 - pDist) * 0.4 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.7, alpha))
            gfx.circle(px, py, pSize, 1, 1)
        end

    -- === BASE PATTERN 23: Liquid Metal ===
    elseif basePattern == 23 then
        local blobCount = 6 + variation
        for blob = 1, blobCount do
            local blobPhase = time * speedMult * 0.4 + blob * 1.5
            local blobCX = cx + math.sin(blobPhase * 0.7 + blob) * radius * 0.3 * (1 + audioBass * 0.5)
            local blobCY = cy + math.cos(blobPhase * 0.5 + blob * 0.7) * radius * 0.2 * (1 + audioMid * 0.5)
            local blobSize = radius * (0.15 + blob * 0.03 + audioPeak * 0.1)

            local col = colors[(blob % 4) + 1]

            -- Draw blob with noise distortion
            local points = 40 + variation * 5
            for i = 0, points do
                local angle = (i / points) * math.pi * 2
                local noise1 = math.sin(angle * 3 + blobPhase * 2) * 0.3
                local noise2 = math.sin(angle * 5 - blobPhase * 1.5 + audioHigh * 2) * 0.2
                local noise3 = math.sin(angle * 7 + blobPhase * 3) * 0.15
                local distort = 1 + noise1 + noise2 + noise3 + audioBass * 0.2

                local bx = blobCX + math.cos(angle + rotation) * blobSize * distort
                local by = blobCY + math.sin(angle + rotation) * blobSize * distort

                local r, g, b = rainbowShift(col, colorShift + angle + blob)
                local alpha = (0.15 + audioBeat * 0.1) * audioMult
                gfx.set(r, g, b, math.min(0.4, alpha))
                gfx.circle(bx, by, (3 + audioPeak * 2) * sizeMult, 1, 1)
            end
        end

    -- === BASE PATTERN 24: Grid Warp ===
    elseif basePattern == 24 then
        local gridSize = math.max(8, 25 - variation) * sizeMult
        local cols = math.ceil(w / gridSize)
        local rows = math.ceil(h / gridSize)

        for col = 0, cols do
            for row = 0, rows do
                local gx = x + col * gridSize
                local gy = y + row * gridSize

                -- Warp based on distance from center and audio
                local dx = (gx - cx) / radius
                local dy = (gy - cy) / radius
                local dist = math.sqrt(dx * dx + dy * dy)

                local warpX = math.sin(dist * 3 - time * speedMult + audioBass * 2) * gridSize * 0.3
                local warpY = math.cos(dist * 3 - time * speedMult * 0.8 + audioMid) * gridSize * 0.3

                local wx = gx + warpX * (1 + audioPeak * 0.5)
                local wy = gy + warpY * (1 + audioPeak * 0.5)

                local colorIdx = ((col + row) % 4) + 1
                local col = colors[colorIdx]
                local r, g, b = rainbowShift(col, colorShift + dist)
                local alpha = (0.2 + math.sin(dist * 5 + time * 2) * 0.1 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, math.min(0.5, alpha))

                local dotSize = (2 + math.sin(dist * 4 + time * 3) * 1 + audioPeak * 2) * sizeMult
                gfx.circle(wx, wy, dotSize, 1, 1)
            end
        end

    -- === BASE PATTERN 25: Aurora Borealis ===
    elseif basePattern == 25 then
        local curtains = 5 + variation
        for curtain = 1, curtains do
            local curtainPhase = time * speedMult * 0.3 + curtain * 0.8
            local curtainX = x + (curtain / (curtains + 1)) * w
            local col = colors[(curtain % 4) + 1]

            -- Draw vertical wavy curtain
            local segments = 40
            local prevX, prevY
            for seg = 0, segments do
                local t = seg / segments
                local segY = y + t * h

                -- Multiple wave layers for aurora effect
                local wave1 = math.sin(t * 4 + curtainPhase + audioBass) * 30
                local wave2 = math.sin(t * 7 - curtainPhase * 1.3 + audioMid * 2) * 20
                local wave3 = math.sin(t * 2 + curtainPhase * 0.5) * 50
                local segX = curtainX + (wave1 + wave2 + wave3) * (1 + audioPeak * 0.5)

                local r, g, b = rainbowShift(col, colorShift + t * 2 + curtain)
                local alpha = (0.15 + math.sin(t * math.pi) * 0.2 + audioBeat * 0.1) * audioMult
                gfx.set(r, g, b, math.min(0.5, alpha))

                if prevX then
                    gfx.line(prevX, prevY, segX, segY)
                    -- Glow effect
                    for glow = 1, 3 do
                        gfx.set(r, g, b, alpha * (0.3 / glow))
                        gfx.line(prevX + glow * 2, prevY, segX + glow * 2, segY)
                        gfx.line(prevX - glow * 2, prevY, segX - glow * 2, segY)
                    end
                end
                prevX, prevY = segX, segY
            end
        end

    -- === CATEGORY: HYPNOTIC (26-35) ===

    -- === BASE PATTERN 26: Hypnotic Spiral ===
    elseif basePattern == 26 then
        local arms = 3 + (variation % 5)
        local spiralTightness = 0.15 + variation * 0.02
        for arm = 0, arms - 1 do
            local armAngle = (arm / arms) * math.pi * 2
            local col = colors[(arm % 4) + 1]
            for t = 0, 1, 0.008 do
                local spiralAngle = armAngle + t * math.pi * 8 + time * speedMult
                local spiralRadius = t * radius * (1 + audioBass * 0.3)
                local px = cx + math.cos(spiralAngle + rotation) * spiralRadius
                local py = cy + math.sin(spiralAngle + rotation) * spiralRadius
                local r, g, b = rainbowShift(col, colorShift + t * 3)
                local alpha = (0.4 + t * 0.3 + audioBeat * 0.2) * audioMult
                gfx.set(r, g, b, math.min(0.8, alpha))
                local dotSize = (2 + t * 4 + audioPeak * 3) * sizeMult
                gfx.circle(px, py, dotSize, 1, 1)
            end
        end

    -- === BASE PATTERN 27: Pulsing Rings ===
    elseif basePattern == 27 then
        local ringCount = 15 + variation * 2
        for ring = 1, ringCount do
            local ringPhase = time * speedMult + ring * 0.3
            local ringRadius = (ring / ringCount) * radius * (1 + math.sin(ringPhase) * 0.2 + audioBass * 0.3)
            local thickness = 2 + (variation % 3) + audioPeak * 2
            local col = colors[(ring % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ring * 0.2)
            local alpha = (0.3 + math.sin(ringPhase * 2) * 0.15 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.7, alpha))
            for angle = 0, math.pi * 2, 0.05 do
                local px = cx + math.cos(angle + rotation) * ringRadius
                local py = cy + math.sin(angle + rotation) * ringRadius
                gfx.circle(px, py, thickness * sizeMult, 1, 1)
            end
        end

    -- === BASE PATTERN 28: Moiré Interference ===
    elseif basePattern == 28 then
        local lineSpacing = 8 + variation
        local offset1 = time * 20 * speedMult
        local offset2 = time * 15 * speedMult + audioBass * 30
        -- First set of lines
        for i = -20, 20 do
            local lx = cx + i * lineSpacing + offset1
            local col = colors[(math.abs(i) % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.1)
            gfx.set(r, g, b, 0.15 * audioMult)
            gfx.line(lx, y, lx + h * 0.3, y + h)
        end
        -- Second set (creates interference)
        for i = -20, 20 do
            local lx = cx + i * lineSpacing - offset2
            local col = colors[((math.abs(i) + 2) % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.15)
            gfx.set(r, g, b, 0.15 * audioMult)
            gfx.line(lx, y, lx - h * 0.3, y + h)
        end

    -- === BASE PATTERN 29: Breathing Mandala ===
    elseif basePattern == 29 then
        local petals = 8 + (variation % 6) * 2
        local layers = 5 + variation
        for layer = layers, 1, -1 do
            local layerRadius = (layer / layers) * radius * (1 + audioBass * 0.2)
            local breathe = 1 + math.sin(time * 2 + layer * 0.5) * 0.15
            for petal = 0, petals - 1 do
                local petalAngle = (petal / petals) * math.pi * 2 + time * 0.2 * speedMult + layer * 0.1
                local px = cx + math.cos(petalAngle + rotation) * layerRadius * breathe
                local py = cy + math.sin(petalAngle + rotation) * layerRadius * breathe
                local col = colors[(petal % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + layer * 0.3)
                local alpha = (0.25 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, math.min(0.6, alpha))
                local petalSize = (5 + layer * 2 + audioPeak * 5) * sizeMult
                gfx.circle(px, py, petalSize, 1, 1)
            end
        end

    -- === BASE PATTERN 30: Lissajous Curves ===
    elseif basePattern == 30 then
        local freqA = 3 + (variation % 4)
        local freqB = 2 + ((variation + 1) % 5)
        local curves = 4
        for curve = 1, curves do
            local phaseOffset = (curve / curves) * math.pi * 2
            local col = colors[curve]
            local prevX, prevY
            for t = 0, math.pi * 2, 0.02 do
                local lx = cx + math.sin(freqA * t + time * speedMult + phaseOffset + audioBass) * radius * 0.8
                local ly = cy + math.sin(freqB * t + time * speedMult * 0.7) * radius * 0.5
                local r, g, b = rainbowShift(col, colorShift + t)
                local alpha = (0.4 + audioBeat * 0.2) * audioMult
                gfx.set(r, g, b, math.min(0.7, alpha))
                if prevX then gfx.line(prevX, prevY, lx, ly) end
                prevX, prevY = lx, ly
            end
        end

    -- === BASE PATTERN 31: Concentric Polygons ===
    elseif basePattern == 31 then
        local sides = 3 + (variation % 6)
        local layers = 12 + variation
        for layer = layers, 1, -1 do
            local layerRadius = (layer / layers) * radius
            local layerRot = time * 0.3 * speedMult * (layer % 2 == 0 and 1 or -1) + rotation
            local col = colors[(layer % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + layer * 0.2)
            local alpha = (0.2 + audioPeak * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.5, alpha))
            for side = 0, sides do
                local a1 = layerRot + (side / sides) * math.pi * 2
                local a2 = layerRot + ((side + 1) / sides) * math.pi * 2
                local x1 = cx + math.cos(a1) * layerRadius * (1 + audioBass * 0.2)
                local y1 = cy + math.sin(a1) * layerRadius * (1 + audioBass * 0.2)
                local x2 = cx + math.cos(a2) * layerRadius * (1 + audioBass * 0.2)
                local y2 = cy + math.sin(a2) * layerRadius * (1 + audioBass * 0.2)
                gfx.line(x1, y1, x2, y2)
            end
        end

    -- === BASE PATTERN 32: Eye of the Storm ===
    elseif basePattern == 32 then
        -- Swirling particles around calm center
        local particleCount = 100 + variation * 20
        for p = 1, particleCount do
            local pSeed = seed + p * 17
            local pAngle = seededRandom(pSeed, 1) * math.pi * 2
            local pDist = seededRandom(pSeed, 2) * 0.9 + 0.1
            local swirlSpeed = (1 - pDist) * 2 + 0.5  -- Faster near edge
            local currentAngle = pAngle + time * swirlSpeed * speedMult
            local px = cx + math.cos(currentAngle + rotation) * pDist * radius
            local py = cy + math.sin(currentAngle + rotation) * pDist * radius * 0.7
            local col = colors[(p % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + pDist * 2)
            local alpha = (pDist * 0.5 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.7, alpha))
            local pSize = ((1 - pDist) * 3 + 1 + audioPeak * 2) * sizeMult
            gfx.circle(px, py, pSize, 1, 1)
        end
        -- Calm glowing center
        for glow = 5, 1, -1 do
            local glowSize = (15 + glow * 8 + audioBass * 10) * sizeMult
            gfx.set(1, 1, 1, 0.1 / glow + audioBeat * 0.05)
            gfx.circle(cx, cy, glowSize, 1, 1)
        end

    -- === BASE PATTERN 33: Infinity Loop ===
    elseif basePattern == 33 then
        local loops = 3 + (variation % 3)
        for loop = 1, loops do
            local loopPhase = (loop / loops) * math.pi * 2
            local col = colors[((loop - 1) % #colors) + 1]
            local prevX, prevY
            for t = 0, math.pi * 2, 0.02 do
                -- Figure-8 / infinity shape
                local scale = radius * (0.6 + loop * 0.1) * (1 + audioBass * 0.2)
                local ix = cx + math.sin(t + time * speedMult + loopPhase) * scale
                local iy = cy + math.sin(2 * t + time * speedMult * 0.5) * scale * 0.4
                local r, g, b = rainbowShift(col, colorShift + t + loop)
                local alpha = (0.4 + audioBeat * 0.2) * audioMult
                gfx.set(r, g, b, math.min(0.7, alpha))
                if prevX then gfx.line(prevX, prevY, ix, iy) end
                prevX, prevY = ix, iy
            end
        end

    -- === BASE PATTERN 34: Ripple Effect ===
    elseif basePattern == 34 then
        local ripples = 8 + variation
        for ripple = 1, ripples do
            local ripplePhase = (time * 2 * speedMult + ripple * 0.5) % (math.pi * 2)
            local rippleRadius = (ripplePhase / (math.pi * 2)) * radius * 1.2
            local rippleAlpha = (1 - ripplePhase / (math.pi * 2)) * 0.4 + audioBeat * 0.1
            local col = colors[(ripple % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ripple * 0.3)
            gfx.set(r, g, b, math.min(0.5, rippleAlpha * audioMult))
            -- Draw ripple circle
            for angle = 0, math.pi * 2, 0.03 do
                local rx = cx + math.cos(angle) * rippleRadius * (1 + audioBass * 0.1)
                local ry = cy + math.sin(angle) * rippleRadius * (1 + audioBass * 0.1)
                gfx.circle(rx, ry, (2 + audioPeak) * sizeMult, 1, 1)
            end
        end

    -- === BASE PATTERN 35: Rotating Squares ===
    elseif basePattern == 35 then
        local squares = 10 + variation
        for sq = 1, squares do
            local sqSize = (sq / squares) * radius * 0.9 * (1 + audioBass * 0.2)
            local sqRot = time * (0.5 + sq * 0.1) * speedMult * (sq % 2 == 0 and 1 or -1) + rotation
            local col = colors[(sq % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + sq * 0.25)
            local alpha = (0.25 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.6, alpha))
            -- Draw rotated square
            local corners = {}
            for corner = 0, 3 do
                local cornerAngle = sqRot + (corner / 4) * math.pi * 2 + math.pi / 4
                corners[corner + 1] = {
                    x = cx + math.cos(cornerAngle) * sqSize,
                    y = cy + math.sin(cornerAngle) * sqSize
                }
            end
            for i = 1, 4 do
                local next = (i % 4) + 1
                gfx.line(corners[i].x, corners[i].y, corners[next].x, corners[next].y)
            end
        end

    -- === CATEGORY: FRACTAL-LIKE (36-45) ===

    -- === BASE PATTERN 36: Sierpinski Triangle ===
    elseif basePattern == 36 then
        local depth = 4 + (variation % 3)
        local triangles = {{cx, cy - radius * 0.8, cx - radius * 0.7, cy + radius * 0.5, cx + radius * 0.7, cy + radius * 0.5}}
        for d = 1, depth do
            local newTriangles = {}
            for _, tri in ipairs(triangles) do
                local mx1 = (tri[1] + tri[3]) / 2
                local my1 = (tri[2] + tri[4]) / 2
                local mx2 = (tri[3] + tri[5]) / 2
                local my2 = (tri[4] + tri[6]) / 2
                local mx3 = (tri[5] + tri[1]) / 2
                local my3 = (tri[6] + tri[2]) / 2
                table.insert(newTriangles, {tri[1], tri[2], mx1, my1, mx3, my3})
                table.insert(newTriangles, {mx1, my1, tri[3], tri[4], mx2, my2})
                table.insert(newTriangles, {mx3, my3, mx2, my2, tri[5], tri[6]})
            end
            triangles = newTriangles
            if #triangles > 500 then break end
        end
        for i, tri in ipairs(triangles) do
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.05)
            local alpha = (0.3 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.6, alpha))
            gfx.line(tri[1], tri[2], tri[3], tri[4])
            gfx.line(tri[3], tri[4], tri[5], tri[6])
            gfx.line(tri[5], tri[6], tri[1], tri[2])
        end

    -- === BASE PATTERN 37: Koch Snowflake ===
    elseif basePattern == 37 then
        local iterations = 3 + (variation % 2)
        local scale = radius * 0.7 * (1 + audioBass * 0.2)
        -- Start with triangle
        local points = {}
        for i = 0, 2 do
            local angle = (i / 3) * math.pi * 2 - math.pi / 2 + time * 0.2 * speedMult + rotation
            table.insert(points, {cx + math.cos(angle) * scale, cy + math.sin(angle) * scale})
        end
        -- Koch iterations
        for iter = 1, iterations do
            local newPoints = {}
            for i = 1, #points do
                local p1 = points[i]
                local p2 = points[(i % #points) + 1]
                local dx, dy = p2[1] - p1[1], p2[2] - p1[2]
                local a = {p1[1], p1[2]}
                local b = {p1[1] + dx/3, p1[2] + dy/3}
                local d = {p1[1] + 2*dx/3, p1[2] + 2*dy/3}
                local angle = math.atan(dy, dx) - math.pi/3
                local c = {b[1] + math.cos(angle) * math.sqrt(dx*dx+dy*dy)/3, b[2] + math.sin(angle) * math.sqrt(dx*dx+dy*dy)/3}
                table.insert(newPoints, a)
                table.insert(newPoints, b)
                table.insert(newPoints, c)
                table.insert(newPoints, d)
            end
            points = newPoints
            if #points > 1000 then break end
        end
        for i = 1, #points do
            local p1 = points[i]
            local p2 = points[(i % #points) + 1]
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.02)
            local alpha = (0.4 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.7, alpha))
            gfx.line(p1[1], p1[2], p2[1], p2[2])
        end

    -- === BASE PATTERN 38: Julia Set Approximation ===
    elseif basePattern == 38 then
        local gridSize = 6 + variation
        local cReal = math.sin(time * 0.3 * speedMult) * 0.4
        local cImag = math.cos(time * 0.2 * speedMult) * 0.4 + audioBass * 0.1
        for gx = 0, w, gridSize do
            for gy = 0, h, gridSize do
                local zr = (gx - cx) / radius * 2
                local zi = (gy - cy) / radius * 2
                local iterations = 0
                for i = 1, 20 do
                    local zr2 = zr * zr - zi * zi + cReal
                    local zi2 = 2 * zr * zi + cImag
                    zr, zi = zr2, zi2
                    if zr * zr + zi * zi > 4 then break end
                    iterations = i
                end
                if iterations > 3 then
                    local col = colors[(iterations % 4) + 1]
                    local r, g, b = rainbowShift(col, colorShift + iterations * 0.2)
                    local alpha = (iterations / 20 * 0.5 + audioBeat * 0.1) * audioMult
                    gfx.set(r, g, b, math.min(0.6, alpha))
                    local dotSize = (2 + iterations * 0.2 + audioPeak) * sizeMult
                    gfx.circle(x + gx, y + gy, dotSize, 1, 1)
                end
            end
        end

    -- === BASE PATTERN 39: Barnsley Fern Points ===
    elseif basePattern == 39 then
        local px, py = 0, 0
        local fernPoints = {}
        for i = 1, 2000 do
            local r = seededRandom(seed + i, 1)
            local nx, ny
            if r < 0.01 then
                nx, ny = 0, 0.16 * py
            elseif r < 0.86 then
                nx = 0.85 * px + 0.04 * py
                ny = -0.04 * px + 0.85 * py + 1.6
            elseif r < 0.93 then
                nx = 0.2 * px - 0.26 * py
                ny = 0.23 * px + 0.22 * py + 1.6
            else
                nx = -0.15 * px + 0.28 * py
                ny = 0.26 * px + 0.24 * py + 0.44
            end
            px, py = nx, ny
            table.insert(fernPoints, {px, py})
        end
        local scale = radius * 0.08 * (1 + audioBass * 0.2)
        for i, pt in ipairs(fernPoints) do
            local fx = cx + pt[1] * scale
            local fy = cy + radius * 0.8 - pt[2] * scale
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + pt[2] * 0.3)
            local alpha = (0.3 + audioBeat * 0.1) * audioMult
            gfx.set(r, g, b, math.min(0.5, alpha))
            gfx.circle(fx, fy, sizeMult, 1, 1)
        end

    -- === BASE PATTERN 40: Recursive Circles ===
    elseif basePattern == 40 then
        local circles = {}
        local function addCircle(ccx, ccy, cr, depth)
            if depth > 5 + variation or cr < 5 or #circles > 200 then return end
            table.insert(circles, {ccx, ccy, cr, depth})
            local childR = cr * 0.45
            for i = 0, 3 do
                local angle = (i / 4) * math.pi * 2 + time * 0.3 * speedMult + rotation
                local childX = ccx + math.cos(angle) * (cr - childR) * (1 + audioBass * 0.1)
                local childY = ccy + math.sin(angle) * (cr - childR) * (1 + audioBass * 0.1)
                addCircle(childX, childY, childR, depth + 1)
            end
        end
        addCircle(cx, cy, radius * 0.8, 0)
        for _, c in ipairs(circles) do
            local col = colors[(c[4] % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + c[4] * 0.5)
            local alpha = (0.3 - c[4] * 0.04 + audioBeat * 0.1) * audioMult
            gfx.set(r, g, b, math.min(0.5, alpha))
            gfx.circle(c[1], c[2], c[3], 0, 1)
        end

    -- === BASE PATTERN 41: Dragon Curve ===
    elseif basePattern == 41 then
        local iterations = 10 + variation
        local sequence = {1}
        for i = 1, iterations do
            local newSeq = {1}
            for j = #sequence, 1, -1 do
                table.insert(newSeq, 1 - sequence[j])
            end
            for _, v in ipairs(sequence) do table.insert(newSeq, v) end
            sequence = newSeq
            if #sequence > 2000 then break end
        end
        local segLen = radius * 0.01 * (1 + audioBass * 0.2)
        local angle = time * 0.5 * speedMult + rotation
        local dx, dy = cx - radius * 0.3, cy
        for i, turn in ipairs(sequence) do
            local nx = dx + math.cos(angle) * segLen
            local ny = dy + math.sin(angle) * segLen
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.01)
            local alpha = (0.4 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.6, alpha))
            gfx.line(dx, dy, nx, ny)
            dx, dy = nx, ny
            angle = angle + (turn == 1 and math.pi/2 or -math.pi/2)
        end

    -- === BASE PATTERN 42: Penrose Tiling ===
    elseif basePattern == 42 then
        local tileSize = 20 + variation * 3
        local phi = (1 + math.sqrt(5)) / 2
        for tx = 0, w + tileSize, tileSize do
            for ty = 0, h + tileSize, tileSize * 0.866 do
                local offset = (math.floor(ty / (tileSize * 0.866)) % 2) * tileSize * 0.5
                local px = x + tx + offset + math.sin(time * speedMult + tx * 0.01) * 5 * audioBass
                local py = y + ty + math.cos(time * speedMult + ty * 0.01) * 5 * audioBass
                local tileType = math.floor(seededRandom(seed + tx + ty * 100, 1) * 2)
                local col = colors[(tileType + math.floor(tx / tileSize)) % 4 + 1]
                local r, g, b = rainbowShift(col, colorShift + tx * 0.01)
                local alpha = (0.25 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, math.min(0.5, alpha))
                -- Draw rhombus
                local angles = tileType == 0 and {0, math.pi/5, math.pi, math.pi + math.pi/5} or {0, 2*math.pi/5, math.pi, math.pi + 2*math.pi/5}
                for i = 1, 4 do
                    local a1 = angles[i] + time * 0.1 + rotation
                    local a2 = angles[(i % 4) + 1] + time * 0.1 + rotation
                    gfx.line(px + math.cos(a1) * tileSize * 0.4, py + math.sin(a1) * tileSize * 0.4,
                             px + math.cos(a2) * tileSize * 0.4, py + math.sin(a2) * tileSize * 0.4)
                end
            end
        end

    -- === BASE PATTERN 43: Fibonacci Spiral ===
    elseif basePattern == 43 then
        local fib = {1, 1}
        for i = 3, 12 do fib[i] = fib[i-1] + fib[i-2] end
        local scale = radius * 0.015 * (1 + audioBass * 0.2)
        local spiralX, spiralY = cx, cy
        local angle = time * 0.3 * speedMult + rotation
        for i = 1, #fib do
            local boxSize = fib[i] * scale
            local col = colors[(i % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + i * 0.3)
            local alpha = (0.3 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.5, alpha))
            -- Draw arc
            local startAngle = angle + (i - 1) * math.pi / 2
            for a = 0, math.pi / 2, 0.05 do
                local ax = spiralX + math.cos(startAngle + a) * boxSize
                local ay = spiralY + math.sin(startAngle + a) * boxSize
                gfx.circle(ax, ay, (1 + audioPeak) * sizeMult, 1, 1)
            end
            -- Move to next corner
            spiralX = spiralX + math.cos(angle) * boxSize
            spiralY = spiralY + math.sin(angle) * boxSize
            angle = angle + math.pi / 2
        end

    -- === BASE PATTERN 44: Cellular Automata ===
    elseif basePattern == 44 then
        local cellSize = 8 + variation
        local cols = math.ceil(w / cellSize)
        local rows = math.ceil(h / cellSize)
        local timeStep = math.floor(time * 5 * speedMult)
        for row = 0, rows do
            for col = 0, cols do
                -- Rule 110 inspired pattern
                local cellSeed = seed + col + row * cols + timeStep
                local alive = seededRandom(cellSeed, 1) > 0.5
                local neighbors = 0
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        if dx ~= 0 or dy ~= 0 then
                            local ns = seededRandom(seed + (col+dx) + (row+dy) * cols + timeStep, 1)
                            if ns > 0.5 then neighbors = neighbors + 1 end
                        end
                    end
                end
                if (alive and (neighbors == 2 or neighbors == 3)) or (not alive and neighbors == 3) then
                    local cx = x + col * cellSize + cellSize / 2
                    local cy = y + row * cellSize + cellSize / 2
                    local colIdx = (col + row) % 4 + 1
                    local r, g, b = rainbowShift(colors[colIdx], colorShift + col * 0.1)
                    local alpha = (0.4 + audioBeat * 0.2) * audioMult
                    gfx.set(r, g, b, math.min(0.6, alpha))
                    gfx.rect(x + col * cellSize + 1, y + row * cellSize + 1, cellSize - 2, cellSize - 2, 1)
                end
            end
        end

    -- === BASE PATTERN 45: L-System Plant ===
    elseif basePattern == 45 then
        -- Simple L-system: F -> F[+F]F[-F]F
        local angle = -math.pi / 2 + rotation
        local len = radius * 0.15 * (1 + audioBass * 0.2)
        local stack = {}
        local px, py = cx, cy + radius * 0.5
        local depth = 3 + (variation % 2)
        local instructions = "F"
        for d = 1, depth do
            local newInst = ""
            for i = 1, #instructions do
                local c = instructions:sub(i, i)
                if c == "F" then newInst = newInst .. "F[+F]F[-F]F"
                else newInst = newInst .. c end
            end
            instructions = newInst
            if #instructions > 1000 then break end
        end
        local branchCount = 0
        for i = 1, math.min(#instructions, 500) do
            local c = instructions:sub(i, i)
            if c == "F" then
                local nx = px + math.cos(angle) * len
                local ny = py + math.sin(angle) * len
                local col = colors[(branchCount % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + branchCount * 0.1)
                local alpha = (0.4 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, math.min(0.6, alpha))
                gfx.line(px, py, nx, ny)
                px, py = nx, ny
                branchCount = branchCount + 1
            elseif c == "+" then
                angle = angle + math.pi / 6 + audioHigh * 0.1
            elseif c == "-" then
                angle = angle - math.pi / 6 - audioHigh * 0.1
            elseif c == "[" then
                table.insert(stack, {px, py, angle, len})
                len = len * 0.7
            elseif c == "]" then
                local state = table.remove(stack)
                if state then px, py, angle, len = state[1], state[2], state[3], state[4] end
            end
        end

    -- === CATEGORY: PARTICLES & SPARKLE (46-55) ===

    -- === BASE PATTERN 46: Fireflies ===
    elseif basePattern == 46 then
        local fireflyCount = 50 + variation * 10
        for f = 1, fireflyCount do
            local fSeed = seed + f * 23
            local fx = cx + (seededRandom(fSeed, 1) - 0.5) * w * 0.9
            local fy = cy + (seededRandom(fSeed, 2) - 0.5) * h * 0.9
            fx = fx + math.sin(time * seededRandom(fSeed, 3) * 2 + f) * 30 * (1 + audioMid * 0.5)
            fy = fy + math.cos(time * seededRandom(fSeed, 4) * 1.5 + f) * 20 * (1 + audioMid * 0.5)
            local blink = (math.sin(time * 3 + seededRandom(fSeed, 5) * 10) + 1) / 2
            local col = colors[(f % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + f * 0.1)
            local alpha = blink * (0.6 + audioBeat * 0.3) * audioMult
            gfx.set(r, g, b, math.min(0.9, alpha))
            local fSize = (2 + blink * 4 + audioPeak * 3) * sizeMult
            gfx.circle(fx, fy, fSize, 1, 1)
            -- Glow
            gfx.set(r, g, b, alpha * 0.3)
            gfx.circle(fx, fy, fSize * 2, 1, 1)
        end

    -- === BASE PATTERN 47: Shooting Stars ===
    elseif basePattern == 47 then
        local starCount = 20 + variation * 5
        for s = 1, starCount do
            local sSeed = seed + s * 31
            local startX = x + seededRandom(sSeed, 1) * w
            local startY = y + seededRandom(sSeed, 2) * h * 0.3
            local angle = math.pi * 0.6 + (seededRandom(sSeed, 3) - 0.5) * 0.5
            local speed = 200 + seededRandom(sSeed, 4) * 300
            local startTime = seededRandom(sSeed, 5) * 5
            local t = (time * speedMult + startTime) % 3
            local sx = startX + math.cos(angle) * t * speed
            local sy = startY + math.sin(angle) * t * speed
            if sx > x and sx < x + w and sy > y and sy < y + h then
                local col = colors[(s % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + s * 0.2)
                local alpha = (1 - t / 3) * (0.7 + audioBeat * 0.2) * audioMult
                -- Trail
                local trailLen = 30 + audioPeak * 20
                for trail = 0, trailLen, 2 do
                    local tx = sx - math.cos(angle) * trail
                    local ty = sy - math.sin(angle) * trail
                    local tAlpha = alpha * (1 - trail / trailLen)
                    gfx.set(r, g, b, math.min(0.8, tAlpha))
                    gfx.circle(tx, ty, (2 - trail / trailLen) * sizeMult, 1, 1)
                end
            end
        end

    -- === BASE PATTERN 48: Confetti ===
    elseif basePattern == 48 then
        local confettiCount = 100 + variation * 20
        for c = 1, confettiCount do
            local cSeed = seed + c * 37
            local cx = x + seededRandom(cSeed, 1) * w
            local fallSpeed = 50 + seededRandom(cSeed, 2) * 100
            local cy = y + ((time * fallSpeed * speedMult + seededRandom(cSeed, 3) * h) % (h + 50)) - 25
            local wobble = math.sin(time * 3 + c) * 20 * (1 + audioHigh * 0.5)
            cx = cx + wobble
            local rot = time * 5 + seededRandom(cSeed, 4) * 10
            local col = colors[(c % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + c * 0.05)
            local alpha = (0.6 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, math.min(0.8, alpha))
            local cSize = (4 + seededRandom(cSeed, 5) * 4 + audioPeak * 2) * sizeMult
            -- Rectangle confetti
            local cosR, sinR = math.cos(rot), math.sin(rot)
            for dx = -cSize/2, cSize/2, 1 do
                for dy = -cSize/4, cSize/4, 1 do
                    local rx = cx + dx * cosR - dy * sinR
                    local ry = cy + dx * sinR + dy * cosR
                    gfx.circle(rx, ry, 1, 1, 1)
                end
            end
        end

    -- === BASE PATTERN 49: Bubbles ===
    elseif basePattern == 49 then
        local bubbleCount = 30 + variation * 8
        for b = 1, bubbleCount do
            local bSeed = seed + b * 41
            local bx = x + seededRandom(bSeed, 1) * w
            local riseSpeed = 30 + seededRandom(bSeed, 2) * 60
            local by = y + h - ((time * riseSpeed * speedMult + seededRandom(bSeed, 3) * h) % (h + 100))
            local wobble = math.sin(time * 2 + b * 0.5) * 15 * (1 + audioMid * 0.3)
            bx = bx + wobble
            local bubbleSize = (10 + seededRandom(bSeed, 4) * 20 + audioBass * 10) * sizeMult
            local col = colors[(b % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + b * 0.1)
            -- Bubble outline
            local alpha = (0.4 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, math.min(0.6, alpha))
            gfx.circle(bx, by, bubbleSize, 0, 1)
            -- Highlight
            gfx.set(1, 1, 1, alpha * 0.5)
            gfx.circle(bx - bubbleSize * 0.3, by - bubbleSize * 0.3, bubbleSize * 0.2, 1, 1)
        end

    -- === BASE PATTERN 50: Sparkle Dust ===
    elseif basePattern == 50 then
        local dustCount = 200 + variation * 50
        for d = 1, dustCount do
            local dSeed = seed + d * 43
            local dx = x + seededRandom(dSeed, 1) * w
            local dy = y + seededRandom(dSeed, 2) * h
            local drift = time * (10 + seededRandom(dSeed, 3) * 20) * speedMult
            dx = x + ((dx - x + drift + math.sin(time + d) * 10) % w)
            dy = y + ((dy - y + drift * 0.3 + math.cos(time * 0.7 + d) * 5) % h)
            local twinkle = (math.sin(time * 8 + seededRandom(dSeed, 4) * 20) + 1) / 2
            local col = colors[(d % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + d * 0.02)
            local alpha = twinkle * (0.5 + audioBeat * 0.3) * audioMult
            gfx.set(r, g, b, math.min(0.8, alpha))
            local dSize = (1 + twinkle * 2 + audioPeak * 2) * sizeMult
            gfx.circle(dx, dy, dSize, 1, 1)
        end

    -- === PATTERNS 51-100 CONTINUE.. ===

    -- === BASE PATTERN 51: Smoke ===
    elseif basePattern == 51 then
        local puffCount = 30 + variation * 5
        for p = 1, puffCount do
            local pSeed = seed + p * 47
            local age = (time * speedMult + seededRandom(pSeed, 1) * 10) % 5
            local px = cx + (seededRandom(pSeed, 2) - 0.5) * 100 + math.sin(time + p) * age * 20
            local py = cy + radius * 0.3 - age * 50 * (1 + audioBass * 0.3)
            local pSize = (age * 20 + 5 + audioPeak * 10) * sizeMult
            local alpha = (1 - age / 5) * 0.3 * audioMult
            gfx.set(0.7, 0.7, 0.8, alpha)
            gfx.circle(px, py, pSize, 1, 1)
        end

    -- === BASE PATTERN 52: Rain ===
    elseif basePattern == 52 then
        local dropCount = 100 + variation * 30
        for d = 1, dropCount do
            local dSeed = seed + d * 53
            local dx = x + seededRandom(dSeed, 1) * w
            local fallSpeed = 300 + seededRandom(dSeed, 2) * 200
            local dy = y + ((time * fallSpeed * speedMult + seededRandom(dSeed, 3) * h) % h)
            local col = colors[(d % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift)
            local alpha = (0.3 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, alpha)
            local dropLen = (10 + audioPeak * 10) * sizeMult
            gfx.line(dx, dy, dx, dy + dropLen)
        end

    -- === BASE PATTERN 53: Snow ===
    elseif basePattern == 53 then
        local flakeCount = 80 + variation * 20
        for f = 1, flakeCount do
            local fSeed = seed + f * 59
            local fx = x + seededRandom(fSeed, 1) * w
            local fallSpeed = 20 + seededRandom(fSeed, 2) * 40
            local fy = y + ((time * fallSpeed * speedMult + seededRandom(fSeed, 3) * h) % h)
            local wobble = math.sin(time * 2 + f * 0.5) * 30
            fx = fx + wobble
            local flakeSize = (2 + seededRandom(fSeed, 4) * 4 + audioPeak * 2) * sizeMult
            local alpha = (0.5 + audioBeat * 0.2) * audioMult
            gfx.set(1, 1, 1, alpha)
            gfx.circle(fx, fy, flakeSize, 1, 1)
        end

    -- === BASE PATTERN 54: Embers ===
    elseif basePattern == 54 then
        local emberCount = 60 + variation * 15
        for e = 1, emberCount do
            local eSeed = seed + e * 61
            local age = (time * speedMult + seededRandom(eSeed, 1) * 8) % 4
            local ex = cx + (seededRandom(eSeed, 2) - 0.5) * 200 + math.sin(time * 2 + e) * age * 30
            local ey = cy + radius * 0.4 - age * 80 * (1 + audioBass * 0.2)
            local eSize = ((1 - age / 4) * 4 + 1 + audioPeak * 2) * sizeMult
            local heat = 1 - age / 4
            gfx.set(1, 0.3 + heat * 0.5, 0, heat * (0.7 + audioBeat * 0.2) * audioMult)
            gfx.circle(ex, ey, eSize, 1, 1)
        end

    -- === BASE PATTERN 55: Glitter ===
    elseif basePattern == 55 then
        local glitterCount = 150 + variation * 40
        for g = 1, glitterCount do
            local gSeed = seed + g * 67
            local gx = x + seededRandom(gSeed, 1) * w
            local gy = y + seededRandom(gSeed, 2) * h
            local sparkleBase = (math.sin(time * 10 + seededRandom(gSeed, 3) * 50) + 1) / 2
            local sparkle = sparkleBase * sparkleBase * sparkleBase  -- ^3
            if sparkle > 0.3 then
                local col = colors[(g % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + g * 0.03)
                local alpha = sparkle * (0.8 + audioBeat * 0.2) * audioMult
                gfx.set(r, g, b, alpha)
                local gSize = (sparkle * 3 + audioPeak * 2) * sizeMult
                gfx.circle(gx, gy, gSize, 1, 1)
            end
        end

    -- === CATEGORY: GEOMETRIC (56-65) ===

    -- === BASE PATTERN 56: Hexagon Grid ===
    elseif basePattern == 56 then
        local hexSize = 20 + variation * 3
        local hexH = hexSize * math.sqrt(3)
        for row = -1, math.ceil(h / hexH) + 1 do
            for col = -1, math.ceil(w / (hexSize * 1.5)) + 1 do
                local hx = x + col * hexSize * 1.5
                local hy = y + row * hexH + (col % 2) * hexH / 2
                local pulse = math.sin(time * 2 + col * 0.3 + row * 0.3 + audioBass * 2) * 0.3
                local colIdx = (col + row) % 4 + 1
                local r, g, b = rainbowShift(colors[colIdx], colorShift + col * 0.1)
                local alpha = (0.2 + pulse + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, math.min(0.5, alpha))
                for side = 0, 5 do
                    local a1 = (side / 6) * math.pi * 2 + rotation
                    local a2 = ((side + 1) / 6) * math.pi * 2 + rotation
                    gfx.line(hx + math.cos(a1) * hexSize, hy + math.sin(a1) * hexSize,
                             hx + math.cos(a2) * hexSize, hy + math.sin(a2) * hexSize)
                end
            end
        end

    -- === BASE PATTERN 57: Voronoi ===
    elseif basePattern == 57 then
        local pointCount = 15 + variation * 3
        local points = {}
        for p = 1, pointCount do
            local pSeed = seed + p * 71
            table.insert(points, {
                x = x + seededRandom(pSeed, 1) * w + math.sin(time + p) * 20,
                y = y + seededRandom(pSeed, 2) * h + math.cos(time * 0.7 + p) * 20,
                col = (p % 4) + 1
            })
        end
        local gridStep = 10 + variation
        for gx = 0, w, gridStep do
            for gy = 0, h, gridStep do
                local minDist = 999999
                local closestCol = 1
                local px, py = x + gx, y + gy
                for _, pt in ipairs(points) do
                    local dist = math.sqrt((px - pt.x)^2 + (py - pt.y)^2)
                    if dist < minDist then
                        minDist = dist
                        closestCol = pt.col
                    end
                end
                local r, g, b = rainbowShift(colors[closestCol], colorShift + minDist * 0.01)
                local alpha = (0.3 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, alpha)
                gfx.rect(px, py, gridStep - 1, gridStep - 1, 1)
            end
        end

    -- === BASE PATTERN 58: Checkerboard Wave ===
    elseif basePattern == 58 then
        local tileSize = 15 + variation * 2
        for tx = 0, w, tileSize do
            for ty = 0, h, tileSize do
                local wave = math.sin(tx * 0.05 + ty * 0.05 + time * 3 * speedMult + audioBass * 2)
                local checker = ((math.floor(tx / tileSize) + math.floor(ty / tileSize)) % 2)
                if (wave > 0) == (checker == 1) then
                    local colIdx = (math.floor(tx / tileSize) % 4) + 1
                    local r, g, b = rainbowShift(colors[colIdx], colorShift + tx * 0.02)
                    local alpha = (0.4 + audioBeat * 0.2) * audioMult
                    gfx.set(r, g, b, alpha)
                    gfx.rect(x + tx, y + ty, tileSize - 1, tileSize - 1, 1)
                end
            end
        end

    -- === BASE PATTERN 59: Triangular Mesh ===
    elseif basePattern == 59 then
        local triSize = 25 + variation * 4
        local triH = triSize * math.sqrt(3) / 2
        for row = 0, math.ceil(h / triH) do
            for col = 0, math.ceil(w / triSize) do
                local tx = x + col * triSize + (row % 2) * triSize / 2
                local ty = y + row * triH
                local offset = math.sin(time * 2 + col * 0.3 + row * 0.3 + audioBass) * 5
                local colIdx = (col + row) % 4 + 1
                local r, g, b = rainbowShift(colors[colIdx], colorShift + col * 0.1)
                local alpha = (0.25 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, alpha)
                gfx.line(tx + offset, ty, tx + triSize / 2 + offset, ty + triH)
                gfx.line(tx + triSize / 2 + offset, ty + triH, tx - triSize / 2 + offset, ty + triH)
                gfx.line(tx - triSize / 2 + offset, ty + triH, tx + offset, ty)
            end
        end

    -- === BASE PATTERN 60: Radial Burst ===
    elseif basePattern == 60 then
        local rays = 24 + variation * 4
        for ray = 0, rays - 1 do
            local rayAngle = (ray / rays) * math.pi * 2 + time * 0.3 * speedMult + rotation
            local rayLen = radius * (0.3 + seededRandom(seed + ray, 1) * 0.7) * (1 + audioBass * 0.3)
            local pulseLen = rayLen * (1 + math.sin(time * 4 + ray * 0.5) * 0.2 + audioPeak * 0.3)
            local col = colors[(ray % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ray * 0.15)
            local alpha = (0.4 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, alpha)
            gfx.line(cx, cy, cx + math.cos(rayAngle) * pulseLen, cy + math.sin(rayAngle) * pulseLen)
        end

    -- === PATTERNS 61-100: More variety ===

    elseif basePattern == 61 then -- Rotating Gears
        local gearCount = 3 + (variation % 4)
        for gear = 1, gearCount do
            local gearX = cx + (gear - (gearCount + 1) / 2) * radius * 0.5
            local gearRadius = radius * (0.2 + gear * 0.05) * (1 + audioBass * 0.2)
            local teeth = 8 + gear * 2
            local gearRot = time * (gear % 2 == 0 and 1 or -1) * speedMult + rotation
            local col = colors[(gear % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + gear)
            local alpha = (0.35 + audioBeat * 0.15) * audioMult
            gfx.set(r, g, b, alpha)
            for tooth = 0, teeth - 1 do
                local a1 = gearRot + (tooth / teeth) * math.pi * 2
                local a2 = gearRot + ((tooth + 0.3) / teeth) * math.pi * 2
                local a3 = gearRot + ((tooth + 0.7) / teeth) * math.pi * 2
                local a4 = gearRot + ((tooth + 1) / teeth) * math.pi * 2
                gfx.line(gearX + math.cos(a1) * gearRadius, cy + math.sin(a1) * gearRadius,
                         gearX + math.cos(a2) * gearRadius * 1.2, cy + math.sin(a2) * gearRadius * 1.2)
                gfx.line(gearX + math.cos(a2) * gearRadius * 1.2, cy + math.sin(a2) * gearRadius * 1.2,
                         gearX + math.cos(a3) * gearRadius * 1.2, cy + math.sin(a3) * gearRadius * 1.2)
                gfx.line(gearX + math.cos(a3) * gearRadius * 1.2, cy + math.sin(a3) * gearRadius * 1.2,
                         gearX + math.cos(a4) * gearRadius, cy + math.sin(a4) * gearRadius)
            end
        end

    elseif basePattern == 62 then -- Wave Grid
        local gridW, gridH = 20 + variation, 15 + variation
        for gx = 0, gridW do
            for gy = 0, gridH do
                local px = x + (gx / gridW) * w
                local py = y + (gy / gridH) * h
                local wave = math.sin(gx * 0.5 + time * 3 * speedMult) * 10 + math.sin(gy * 0.3 + time * 2) * 10
                py = py + wave * (1 + audioBass * 0.5)
                local col = colors[((gx + gy) % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + gx * 0.1)
                local alpha = (0.4 + audioBeat * 0.2) * audioMult
                gfx.set(r, g, b, alpha)
                gfx.circle(px, py, (2 + audioPeak * 2) * sizeMult, 1, 1)
            end
        end

    elseif basePattern == 63 then -- Orbital Paths
        local orbits = 5 + variation
        for orb = 1, orbits do
            local orbRadius = (orb / orbits) * radius * 0.9
            local col = colors[(orb % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + orb * 0.3)
            local alpha = (0.2 + audioBeat * 0.1) * audioMult
            gfx.set(r, g, b, alpha)
            -- Orbit path
            for angle = 0, math.pi * 2, 0.05 do
                local ox = cx + math.cos(angle + rotation) * orbRadius
                local oy = cy + math.sin(angle + rotation) * orbRadius * 0.5
                gfx.circle(ox, oy, sizeMult, 1, 1)
            end
            -- Planet
            local planetAngle = time * (1 + orb * 0.2) * speedMult + orb
            local planetX = cx + math.cos(planetAngle + rotation) * orbRadius
            local planetY = cy + math.sin(planetAngle + rotation) * orbRadius * 0.5
            gfx.set(r, g, b, (0.7 + audioBeat * 0.2) * audioMult)
            gfx.circle(planetX, planetY, (5 + orb + audioPeak * 3) * sizeMult, 1, 1)
        end

    elseif basePattern == 64 then -- Diamond Pattern
        local diamondSize = 20 + variation * 3
        for dx = -diamondSize, w + diamondSize, diamondSize do
            for dy = -diamondSize, h + diamondSize, diamondSize do
                local offset = (math.floor(dy / diamondSize) % 2) * diamondSize / 2
                local px = x + dx + offset + math.sin(time + dx * 0.01) * 5 * audioBass
                local py = y + dy + math.cos(time + dy * 0.01) * 5 * audioBass
                local col = colors[(math.floor(dx / diamondSize + dy / diamondSize) % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + dx * 0.02)
                local alpha = (0.3 + audioBeat * 0.15) * audioMult
                gfx.set(r, g, b, alpha)
                local ds = diamondSize * 0.4 * (1 + audioPeak * 0.2)
                gfx.line(px, py - ds, px + ds, py)
                gfx.line(px + ds, py, px, py + ds)
                gfx.line(px, py + ds, px - ds, py)
                gfx.line(px - ds, py, px, py - ds)
            end
        end

    elseif basePattern == 65 then -- Flower of Life
        local circleRadius = 25 + variation * 5
        local layers = 3 + (variation % 3)
        local drawn = {}
        local function drawFlowerCircle(fcx, fcy)
            local key = math.floor(fcx) .. "," .. math.floor(fcy)
            if drawn[key] then return end
            drawn[key] = true
            local col = colors[(#drawn % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + #drawn * 0.1)
            local alpha = (0.25 + audioBeat * 0.1) * audioMult
            gfx.set(r, g, b, alpha)
            for angle = 0, math.pi * 2, 0.05 do
                local ox = fcx + math.cos(angle) * circleRadius * (1 + audioBass * 0.1)
                local oy = fcy + math.sin(angle) * circleRadius * (1 + audioBass * 0.1)
                gfx.circle(ox, oy, sizeMult, 1, 1)
            end
        end
        drawFlowerCircle(cx, cy)
        for layer = 1, layers do
            for i = 0, 5 do
                local angle = (i / 6) * math.pi * 2 + time * 0.1 + rotation
                local dist = layer * circleRadius * (1 + audioBass * 0.1)
                drawFlowerCircle(cx + math.cos(angle) * dist, cy + math.sin(angle) * dist)
            end
        end

    -- === CATEGORY: WAVEFORMS & AUDIO (66-75) ===

    elseif basePattern == 66 then -- Spectrum Bars
        local bars = 32 + variation * 8
        local barW = w / bars
        for bar = 0, bars - 1 do
            local barPhase = time * 3 + bar * 0.2
            local barH = (math.sin(barPhase) * 0.5 + 0.5) * h * 0.8 * (1 + audioPeak * 0.5)
            if audioReactive.waveformHistory and #audioReactive.waveformHistory > 0 then
                local idx = math.floor(bar / bars * #audioReactive.waveformHistory) + 1
                barH = (audioReactive.waveformHistory[idx] or 0.5) * h * (1 + audioBass * 0.3)
            end
            local col = colors[(bar % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + bar * 0.1)
            local alpha = (0.5 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, alpha)
            gfx.rect(x + bar * barW, y + h - barH, barW - 1, barH, 1)
        end

    elseif basePattern == 67 then -- Circular Spectrum
        local segments = 60 + variation * 10
        for seg = 0, segments - 1 do
            local segAngle = (seg / segments) * math.pi * 2 + rotation
            local segH = radius * 0.3 * (1 + math.sin(time * 3 + seg * 0.3) * 0.5 + audioPeak * 0.5)
            if audioReactive.waveformHistory and #audioReactive.waveformHistory > 0 then
                local idx = math.floor(seg / segments * #audioReactive.waveformHistory) + 1
                segH = radius * 0.2 + (audioReactive.waveformHistory[idx] or 0.3) * radius * 0.6
            end
            local innerR = radius * 0.3
            local outerR = innerR + segH
            local col = colors[(seg % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + seg * 0.05)
            local alpha = (0.5 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, alpha)
            gfx.line(cx + math.cos(segAngle) * innerR, cy + math.sin(segAngle) * innerR,
                     cx + math.cos(segAngle) * outerR, cy + math.sin(segAngle) * outerR)
        end

    elseif basePattern == 68 then -- Oscilloscope
        local points = 200 + variation * 50
        local prevX, prevY
        for i = 0, points do
            local t = i / points
            local px = x + t * w
            local py = cy
            local wave1 = math.sin(t * 10 + time * 5 * speedMult) * h * 0.2
            local wave2 = math.sin(t * 15 - time * 3 * speedMult) * h * 0.1
            py = py + (wave1 + wave2) * (1 + audioPeak * 0.5)
            if audioReactive.waveformHistory and #audioReactive.waveformHistory > 0 then
                local idx = math.floor(t * #audioReactive.waveformHistory) + 1
                py = cy + (audioReactive.waveformHistory[idx] or 0) * h * 0.8 - h * 0.4
            end
            local col = colors[(math.floor(t * 4) % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + t * 2)
            local alpha = (0.6 + audioBeat * 0.2) * audioMult
            gfx.set(r, g, b, alpha)
            if prevX then gfx.line(prevX, prevY, px, py) end
            prevX, prevY = px, py
        end

    elseif basePattern == 69 then -- VU Meter
        local meterCount = 8 + variation
        local meterW = w / meterCount * 0.8
        local meterSpacing = w / meterCount
        for m = 0, meterCount - 1 do
            local meterX = x + m * meterSpacing + (meterSpacing - meterW) / 2
            local meterVal = math.sin(time * 2 + m * 0.5) * 0.5 + 0.5 + audioPeak * 0.3
            local segments = 10
            for seg = 0, segments - 1 do
                local segY = y + h - (seg + 1) * (h / segments)
                local lit = (seg / segments) < meterVal
                local col
                if seg < segments * 0.6 then col = {0.2, 0.8, 0.2}
                elseif seg < segments * 0.8 then col = {0.8, 0.8, 0.2}
                else col = {0.8, 0.2, 0.2} end
                local alpha = lit and (0.7 + audioBeat * 0.2) or 0.1
                gfx.set(col[1], col[2], col[3], alpha * audioMult)
                gfx.rect(meterX, segY, meterW, h / segments - 2, 1)
            end
        end

    elseif basePattern == 70 then -- Bass Kick
        local kickSize = radius * (0.5 + audioBass * 0.8)
        local kickAlpha = audioBass * 0.8 + 0.2
        for ring = 5, 1, -1 do
            local ringSize = kickSize * (1 + ring * 0.15)
            local col = colors[(ring % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + ring)
            gfx.set(r, g, b, kickAlpha / ring * audioMult)
            gfx.circle(cx, cy, ringSize, 1, 1)
        end

    -- === REMAINING PATTERNS (71-100) for variety ===

    elseif basePattern == 71 then -- Neon Signs
        local signCount = 4 + variation
        for sign = 1, signCount do
            local signX = x + (sign / (signCount + 1)) * w
            local signY = cy + math.sin(time + sign) * h * 0.2
            local col = colors[(sign % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + sign)
            local flicker = 0.7 + math.sin(time * 20 + sign * 100) * 0.3
            local alpha = flicker * (0.6 + audioBeat * 0.3) * audioMult
            -- Glow
            for glow = 3, 1, -1 do
                gfx.set(r, g, b, alpha / glow * 0.5)
                gfx.circle(signX, signY, (15 + glow * 5) * sizeMult, 1, 1)
            end
            gfx.set(r, g, b, alpha)
            gfx.circle(signX, signY, 10 * sizeMult, 1, 1)
        end

    elseif basePattern == 72 then -- Laser Show
        local laserCount = 8 + variation * 2
        for laser = 1, laserCount do
            local laserAngle = time * (1 + laser * 0.1) * speedMult + laser * 0.8
            local laserLen = radius * (0.8 + math.sin(time * 3 + laser) * 0.2) * (1 + audioBass * 0.3)
            local col = colors[(laser % 4) + 1]
            local r, g, b = rainbowShift(col, colorShift + laser * 0.2)
            local alpha = (0.5 + audioBeat * 0.3) * audioMult
            gfx.set(r, g, b, alpha)
            local ex = cx + math.cos(laserAngle + rotation) * laserLen
            local ey = cy + math.sin(laserAngle + rotation) * laserLen * 0.6
            gfx.line(cx, cy, ex, ey)
            -- Glow
            gfx.set(r, g, b, alpha * 0.3)
            gfx.line(cx + 1, cy + 1, ex + 1, ey + 1)
        end

    elseif basePattern == 73 then -- Disco Ball
        local facets = 20 + variation * 5
        for fx = 0, facets do
            for fy = 0, facets / 2 do
                local theta = (fx / facets) * math.pi * 2 + time * 0.5 + rotation
                local phi = (fy / (facets / 2)) * math.pi
                local bx = cx + math.sin(phi) * math.cos(theta) * radius * 0.6
                local by = cy + math.cos(phi) * radius * 0.4
                local bz = math.sin(phi) * math.sin(theta)
                if bz > -0.2 then
                    local brightness = (bz + 1) / 2
                    local sparkle = math.sin(time * 10 + fx * 3 + fy * 5) > 0.7 and 1 or 0.3
                    local col = colors[((fx + fy) % 4) + 1]
                    local r, g, b = rainbowShift(col, colorShift + fx * 0.1)
                    local alpha = brightness * sparkle * (0.7 + audioBeat * 0.3) * audioMult
                    gfx.set(r, g, b, alpha)
                    gfx.circle(bx, by, (3 + audioPeak * 2) * sizeMult, 1, 1)
                end
            end
        end

    elseif basePattern == 74 then -- Heartbeat
        local beatPhase = (time * 1.2 * speedMult) % 1
        local beatScale = 1 + (beatPhase < 0.1 and math.sin(beatPhase * 10 * math.pi) * 0.3 or 0)
        beatScale = beatScale + audioBeat * 0.3
        local heartSize = radius * 0.4 * beatScale
        local col = colors[1]  -- Red for heart
        local r, g, b = rainbowShift(col, colorShift)
        local alpha = (0.6 + audioBeat * 0.3) * audioMult
        gfx.set(r, g, b, alpha)
        -- Draw heart shape
        for t = 0, math.pi * 2, 0.02 do
            local sinT = math.sin(t)
            local hx = 16 * sinT * sinT * sinT  -- sin(t)^3
            local hy = -(13 * math.cos(t) - 5 * math.cos(2*t) - 2 * math.cos(3*t) - math.cos(4*t))
            local px = cx + hx * heartSize * 0.05
            local py = cy + hy * heartSize * 0.05
            gfx.circle(px, py, (2 + audioPeak) * sizeMult, 1, 1)
        end

    elseif basePattern == 75 then -- DNA Double Helix (alternative)
        local helixLen = h * 0.8
        local helixY = y + (h - helixLen) / 2
        local twists = 3 + variation
        for t = 0, 1, 0.01 do
            local ty = helixY + t * helixLen
            local phase = t * twists * math.pi * 2 + time * 2 * speedMult
            local x1 = cx + math.sin(phase) * radius * 0.3 * (1 + audioBass * 0.2)
            local x2 = cx + math.sin(phase + math.pi) * radius * 0.3 * (1 + audioBass * 0.2)
            -- Strand 1
            gfx.set(colors[1][1], colors[1][2], colors[1][3], (0.6 + audioBeat * 0.2) * audioMult)
            gfx.circle(x1, ty, (3 + audioPeak * 2) * sizeMult, 1, 1)
            -- Strand 2
            gfx.set(colors[3][1], colors[3][2], colors[3][3], (0.6 + audioBeat * 0.2) * audioMult)
            gfx.circle(x2, ty, (3 + audioPeak * 2) * sizeMult, 1, 1)
            -- Connecting rungs
            if math.floor(t * 50) % 3 == 0 then
                gfx.set(colors[2][1], colors[2][2], colors[2][3], (0.3 + audioBeat * 0.1) * audioMult)
                gfx.line(x1, ty, x2, ty)
            end
        end

    -- === PATTERNS 76-100: Final batch ===

    elseif basePattern >= 76 and basePattern <= 100 then
        -- Generate varied patterns using pattern number as modifier
        local patternType = (basePattern - 76) % 5
        local intensity = 0.5 + (basePattern - 76) / 50

        if patternType == 0 then -- Spinning webs
            local spokes = 12 + variation
            local rings = 8 + (basePattern % 5)
            for spoke = 0, spokes - 1 do
                local spokeAngle = (spoke / spokes) * math.pi * 2 + time * 0.3 * speedMult + rotation
                local col = colors[(spoke % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + spoke * 0.2)
                gfx.set(r, g, b, (0.3 + audioBeat * 0.15) * audioMult)
                gfx.line(cx, cy, cx + math.cos(spokeAngle) * radius, cy + math.sin(spokeAngle) * radius * 0.6)
            end
            for ring = 1, rings do
                local ringR = (ring / rings) * radius * (1 + audioBass * 0.2)
                for spoke = 0, spokes - 1 do
                    local a1 = (spoke / spokes) * math.pi * 2 + time * 0.3 + rotation
                    local a2 = ((spoke + 1) / spokes) * math.pi * 2 + time * 0.3 + rotation
                    gfx.line(cx + math.cos(a1) * ringR, cy + math.sin(a1) * ringR * 0.6,
                             cx + math.cos(a2) * ringR, cy + math.sin(a2) * ringR * 0.6)
                end
            end

        elseif patternType == 1 then -- Bouncing balls
            local ballCount = 10 + variation * 3
            for ball = 1, ballCount do
                local bSeed = seed + ball * (basePattern + 1)
                local bx = x + seededRandom(bSeed, 1) * w
                local bounceSpeed = 1 + seededRandom(bSeed, 2)
                local bouncePhase = (time * bounceSpeed * speedMult + seededRandom(bSeed, 3) * 10) % 2
                local by = y + h - math.abs(math.sin(bouncePhase * math.pi)) * h * 0.7 - 20
                local col = colors[(ball % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + ball * 0.2)
                gfx.set(r, g, b, (0.6 + audioBeat * 0.2) * audioMult)
                local ballSize = (10 + seededRandom(bSeed, 4) * 10 + audioPeak * 5) * sizeMult
                gfx.circle(bx, by, ballSize, 1, 1)
            end

        elseif patternType == 2 then -- Rotating star field
            local starCount = 50 + variation * 15
            for star = 1, starCount do
                local sSeed = seed + star * (basePattern + 1)
                local sAngle = seededRandom(sSeed, 1) * math.pi * 2
                local sDist = seededRandom(sSeed, 2) * radius
                local rotSpeed = (seededRandom(sSeed, 3) - 0.5) * 2
                local currentAngle = sAngle + time * rotSpeed * speedMult + rotation
                local sx = cx + math.cos(currentAngle) * sDist
                local sy = cy + math.sin(currentAngle) * sDist * 0.6
                local twinkle = (math.sin(time * 5 + star) + 1) / 2
                local col = colors[(star % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + star * 0.05)
                gfx.set(r, g, b, twinkle * (0.5 + audioBeat * 0.2) * audioMult)
                gfx.circle(sx, sy, (1 + twinkle * 2 + audioPeak) * sizeMult, 1, 1)
            end

        elseif patternType == 3 then -- Expanding rings
            local ringCount = 5 + variation
            for ring = 1, ringCount do
                local ringPhase = (time * speedMult * 0.5 + ring * 0.3) % 1
                local ringR = ringPhase * radius * 1.2
                local alpha = (1 - ringPhase) * 0.5 + audioBeat * 0.1
                local col = colors[(ring % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + ring * 0.3)
                gfx.set(r, g, b, alpha * audioMult)
                for angle = 0, math.pi * 2, 0.03 do
                    gfx.circle(cx + math.cos(angle) * ringR, cy + math.sin(angle) * ringR * 0.6, sizeMult, 1, 1)
                end
            end

        else -- Morphing blob
            local points = 60 + variation * 10
            local prevX, prevY
            for i = 0, points do
                local angle = (i / points) * math.pi * 2
                local noise = 0
                for harmonic = 1, 5 do
                    noise = noise + math.sin(angle * harmonic + time * (harmonic * 0.5) * speedMult) / harmonic
                end
                local blobR = radius * 0.5 * (1 + noise * 0.3 + audioBass * 0.2)
                local bx = cx + math.cos(angle + rotation) * blobR
                local by = cy + math.sin(angle + rotation) * blobR
                local col = colors[(i % 4) + 1]
                local r, g, b = rainbowShift(col, colorShift + angle)
                gfx.set(r, g, b, (0.5 + audioBeat * 0.2) * audioMult)
                if prevX then gfx.line(prevX, prevY, bx, by) end
                prevX, prevY = bx, by
            end
        end
    end

    -- Beat flash removed from Gallery - was causing visible grey square artifact
end

-- Wrapper function that handles crossfade transitions between patterns
local function drawProceduralArt(x, y, w, h, time, rotation, skipBackground)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
        if not skipBackground then
            local bg = (THEME and THEME.bg) or (SETTINGS.darkMode and {0.18, 0.18, 0.18} or {0.86, 0.86, 0.86})
            gfx.set(bg[1], bg[2], bg[3], 1)
            gfx.rect(x, y, w, h, 1)
        end
        return
    end
    -- Check if visual FX are disabled
    if not SETTINGS.visualFX then
        -- Just draw a simple background when FX are off
        if not skipBackground then
            if SETTINGS.darkMode then
                gfx.set(0.08, 0.08, 0.1, 1)
            else
                gfx.set(0.95, 0.95, 0.97, 1)
            end
            gfx.rect(x, y, w, h, 1)
        end
        return
    end

    -- Update transition progress
    if proceduralArt.transitionProgress and proceduralArt.transitionProgress < 1 then
        proceduralArt.transitionProgress = proceduralArt.transitionProgress + (0.016 / (proceduralArt.transitionDuration or 1.5))

        if proceduralArt.transitionProgress < 1 then
            -- Smooth easing function (ease-in-out)
            local t = proceduralArt.transitionProgress
            local easeVal = -2 * t + 2
            local eased = t < 0.5 and (2 * t * t) or (1 - easeVal * easeVal / 2)

            -- Draw OLD pattern first (with zoom-out effect)
            if proceduralArt.oldSeed and proceduralArt.oldStyle then
                local zoomOut = 1 + eased * 0.2  -- Slight zoom out as it fades
                local oldW, oldH = w * zoomOut, h * zoomOut
                local oldX, oldY = x - (oldW - w) / 2, y - (oldH - h) / 2
                drawProceduralArtInternal(oldX, oldY, oldW, oldH, proceduralArt.oldTime or time, rotation, true, 1, proceduralArt.oldSeed, proceduralArt.oldStyle)

                -- Fade out overlay on old pattern (simulates alpha fade)
                if SETTINGS and SETTINGS.darkMode then
                    gfx.set(0, 0, 0, eased * 0.85)
                else
                    gfx.set(1, 1, 1, eased * 0.85)
                end
                gfx.rect(x, y, w, h, 1)
            end

            -- Draw NEW pattern (with zoom-in effect, starting slightly zoomed)
            local zoomIn = 1.15 - eased * 0.15  -- Start 15% zoomed in, settle to normal
            local newW, newH = w * zoomIn, h * zoomIn
            local newX, newY = x - (newW - w) / 2, y - (newH - h) / 2
            drawProceduralArtInternal(newX, newY, newW, newH, time, rotation, true, 1)

            -- Fade in overlay for new pattern (reverse - starts opaque, becomes transparent)
            if SETTINGS and SETTINGS.darkMode then
                gfx.set(0, 0, 0, (1 - eased) * 0.7)
            else
                gfx.set(1, 1, 1, (1 - eased) * 0.7)
            end
            gfx.rect(x, y, w, h, 1)
        else
            -- Transition complete
            proceduralArt.transitionProgress = nil
            proceduralArt.oldSeed = nil
            proceduralArt.oldStyle = nil
            proceduralArt.oldElements = nil
            proceduralArt.oldTime = nil
            drawProceduralArtInternal(x, y, w, h, time, rotation, skipBackground)
        end
    else
        -- No transition, just draw normally
        drawProceduralArtInternal(x, y, w, h, time, rotation, skipBackground)
    end
end

local function getFxReadabilityOverlayAlpha()
    if SETTINGS.darkMode then
        return 0.50
    end
    -- Keep light-mode FX decorative so they do not compete with progress/log text.
    return 0.66
end

-- Initialize procedural art on first run
generateNewArt()

-- ============================================
-- END PROCEDURAL ART GENERATOR
-- ============================================

-- STEMwerk Art Gallery - Spectacular animated visualizations
-- Each piece is a fully animated graphical artwork (20 masterpieces!)
local STEMwerkArt = {
    {
        title = "The Prism of Sound",
        subtitle = "White light becomes a spectrum of music",
        description = "Audio enters as one, emerges as four distinct colors of sound",
    },
    {
        title = "Neural Separation",
        subtitle = "Deep learning dissects the mix",
        description = "Watch as neurons fire and separate the tangled waveforms",
    },
    {
        title = "The Four Elements",
        subtitle = "Voice, Rhythm, Bass, Harmony",
        description = "Like earth, water, fire and air - four essences of music",
    },
    {
        title = "Waveform Surgery",
        subtitle = "Precision extraction in real-time",
        description = "Surgical separation of intertwined frequencies",
    },
    {
        title = "The Sound Galaxy",
        subtitle = "Stars of audio in cosmic dance",
        description = "Each stem orbits the central mix like planets around a sun",
    },
    {
        title = "Frequency Waterfall",
        subtitle = "Cascading layers of sound",
        description = "High frequencies fall through mid and low, each finding its home",
    },
    {
        title = "The DNA Helix",
        subtitle = "Unraveling the genetic code of music",
        description = "Double helix of sound splits into its component strands",
    },
    {
        title = "Particle Storm",
        subtitle = "Audio atoms in motion",
        description = "Millions of sound particles sorting themselves by type",
    },
    {
        title = "The Mixing Desk",
        subtitle = "Faders of the universe",
        description = "Four channels rising from chaos into clarity",
    },
    {
        title = "Stem Constellation",
        subtitle = "Navigate by the stars of sound",
        description = "Connect the dots to reveal the hidden patterns in music",
    },
    -- NEW ART PIECES
    {
        title = "Harmonic Mandala",
        subtitle = "Sacred geometry of frequency",
        description = "The mathematical beauty underlying all music, visualized",
    },
    {
        title = "The Stem Lotus",
        subtitle = "Petals of pure audio",
        description = "Each stem unfolds like a lotus petal reaching for the light",
    },
    {
        title = "Aurora Borealis",
        subtitle = "Northern lights of sound",
        description = "Stems dance like the aurora across the audio sky",
    },
    {
        title = "Quantum Entanglement",
        subtitle = "Connected across the mix",
        description = "Four particles forever linked, yet beautifully separate",
    },
    {
        title = "The Spiral Tower",
        subtitle = "Ascending frequencies",
        description = "A tower of sound spiraling into the infinite",
    },
    {
        title = "Ocean of Waves",
        subtitle = "Tides of audio",
        description = "Each stem flows like waves in an endless ocean",
    },
    {
        title = "Crystalline Matrix",
        subtitle = "Frozen frequencies",
        description = "Sound crystalized into perfect geometric formations",
    },
    {
        title = "The Heartbeat",
        subtitle = "Pulse of the music",
        description = "Every song has a heartbeat - watch it pulse in four colors",
    },
    {
        title = "Stem Kaleidoscope",
        subtitle = "Infinite reflections",
        description = "Mirrors within mirrors, stems within stems",
    },
    {
        title = "Digital Rain",
        subtitle = "Cascading code of music",
        description = "The matrix of audio flows downward eternally",
    },
}

-- Forward declaration for showMessage
local showMessage
-- Forward declaration for shared font-size cache helper used by earlier UI paths (e.g. About/Gallery).
local getUniformFontSizeCached


local function drawUtilityNativeHelpWindow()
    local w, h = gfx.w, gfx.h
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = (gfx.mouse_cap & 1) == 1
    local rightMouseDown = (gfx.mouse_cap & 2) == 2
    local dark = SETTINGS and SETTINGS.darkMode

    local function col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
    -- Use resolved THEME so Help matches the main Native UI in both Dark and Light.
    -- _tc(primary, fallback): returns primary if it is a valid {r,g,b} table, else fallback.
    local function _tc(p, fb) return (type(p) == "table" and p[1] ~= nil) and p or fb end
    local T_ = (type(THEME) == "table") and THEME or {}
    local bg      = _tc(T_.bg,          dark and {0.11,0.11,0.11} or {0.85,0.85,0.85})
    local panel   = _tc(T_.button,       dark and {0.18,0.18,0.18} or {0.78,0.78,0.78})
    local panel2  = _tc(T_.bg,            dark and {0.11,0.11,0.11} or {0.85,0.85,0.85})
    local border  = _tc(T_.border,       dark and {0.32,0.32,0.32} or {0.60,0.60,0.60})
    local text    = _tc(T_.text,         dark and {0.90,0.90,0.90} or {0.10,0.10,0.10})
    local muted   = _tc(T_.textDim,      dark and {0.70,0.70,0.70} or {0.30,0.30,0.30})
    local hoverBg = _tc(T_.buttonHover,  dark and {0.26,0.26,0.26} or {0.86,0.86,0.86})
    local activeBg = _tc(T_.accent,      dark and {0.30,0.46,0.32} or {0.56,0.68,0.58})

    local function tr(key, fallback)
        if type(T) == "function" then
            local v = T(key)
            if v and v ~= key and v ~= "" then return v end
        end
        return fallback or key
    end

    local function addLine(lines, textLine)
        if textLine and textLine ~= "" then lines[#lines + 1] = tostring(textLine) end
    end

    local function addPair(lines, title, body)
        if title and title ~= "" then addLine(lines, tostring(title)) end
        if body and body ~= "" then addLine(lines, "  " .. tostring(body)) end
    end

    local HEADING_MARKER = "\x01"
    local function addHead(lines, s)
        lines[#lines + 1] = HEADING_MARKER .. tostring(s)
    end

    local tabs = {
        { tr("help_welcome", "Welcome"), function()
            local lines = {}
            addHead(lines, tr("help_welcome_title", "Welcome to STEMwerk"))
            addLine(lines, "  " .. tr("help_native_welcome_sub", "Stem separation workflow utility for REAPER"))
            addLine(lines, "")
            addHead(lines, tr("help_native_common_uses", "Common uses"))
            addPair(lines, tr("help_native_vocals", "Vocals"), tr("help_native_vocals_desc", "Extract for karaoke, remix, or vocal isolation"))
            addPair(lines, tr("help_native_drums", "Drums"), tr("help_native_drums_desc", "Isolate for sampling, practice, or groove analysis"))
            addPair(lines, tr("help_native_bass", "Bass"), tr("help_native_bass_desc", "Separate for transcription or low-end mixing"))
            addPair(lines, tr("help_native_other", "Other"), tr("help_native_other_desc", "Get guitars, keys, synths, and strings cleanly"))
            return lines
        end },
        { tr("help_quickstart", "Quick Start"), function()
            return { __columns = true,
                left = function()
                    local l = {}
                    addHead(l, tr("help_native_steps", "Steps"))
                    addLine(l, "  1. " .. tr("help_native_step_select_audio", "Select audio"))
                    addLine(l, "     " .. tr("help_native_step_select_audio_desc", "Tracks, items, or time selection"))
                    addLine(l, "  2. " .. tr("help_native_step_choose_model", "Choose model and stems"))
                    addLine(l, "     " .. tr("help_native_step_choose_model_desc", "Fast / Quality / 6-Stem"))
                    addLine(l, "  3. " .. tr("help_native_step_set_output", "Set output"))
                    addLine(l, "     " .. tr("help_native_step_set_output_desc", "New tracks or in-place takes"))
                    addLine(l, "  4. " .. tr("help_native_step_click_run", "Click Run"))
                    return l
                end,
                right = function()
                    local l = {}
                    addHead(l, tr("help_native_keyboard", "Keyboard"))
                    addLine(l, "  F1      " .. tr("open_help", "Open Help"))
                    addLine(l, "  Enter   " .. tr("help_native_key_run", "Run"))
                    addLine(l, "  ESC     " .. tr("close_cancel", "Close / Cancel"))
                    addLine(l, "  <- ->   " .. tr("help_native_key_help_tabs", "Help tabs"))
                    addLine(l, "")
                    addHead(l, tr("help_native_presets", "Presets"))
                    addLine(l, "  K / I   Karaoke / Instrumental")
                    addLine(l, "  V D B   Vocals / Drums / Bass")
                    addLine(l, "  F Q S   Fast / Quality / 6-Stem")
                    addLine(l, "  1-4     " .. tr("help_native_key_toggle_stems", "Toggle stems (1-6 in 6-stem)"))
                    return l
                end
            }
        end },
        { tr("help_stems", "Stems"), function()
            return { __columns = true,
                left = function()
                    local l = {}
                    addHead(l, tr("help_native_4stem", "4-Stem"))
                    addLine(l, "  " .. tr("help_native_vocals", "Vocals") .. "    " .. tr("help_native_4stem_vocals_desc", "Lead vocals, speech"))
                    addLine(l, "  " .. tr("help_native_drums", "Drums") .. "     " .. tr("help_native_4stem_drums_desc", "Drums, percussion"))
                    addLine(l, "  " .. tr("help_native_bass", "Bass") .. "      " .. tr("help_native_4stem_bass_desc", "Low end"))
                    addLine(l, "  " .. tr("help_native_other", "Other") .. "     " .. tr("help_native_4stem_other_desc", "Instruments, effects"))
                    addLine(l, "")
                    addHead(l, tr("help_native_6stem", "6-Stem  (htdemucs_6s)"))
                    addLine(l, "  " .. tr("help_native_6stem_guitar", "Guitar") .. "    " .. tr("help_native_6stem_guitar_desc", "Isolated guitar"))
                    addLine(l, "  " .. tr("help_native_6stem_piano", "Piano") .. "     " .. tr("help_native_6stem_piano_desc", "Isolated piano"))
                    addLine(l, "  " .. tr("help_native_6stem_adds", "Adds to the 4-stem set."))
                    return l
                end,
                right = function()
                    local l = {}
                    addHead(l, tr("help_native_models", "Models"))
                    addLine(l, "  htdemucs     Fast")
                    addLine(l, "  htdemucs_ft  Quality")
                    addLine(l, "  htdemucs_6s  6-Stem")
                    addLine(l, "")
                    addHead(l, tr("help_native_output", "Output"))
                    addLine(l, "  " .. tr("new_tracks", "New tracks"))
                    addLine(l, "  " .. tr("help_native_in_place_takes", "In-place as takes"))
                    addLine(l, "")
                    addHead(l, tr("grouping_label", "Grouping:"))
                    addLine(l, "  " .. tr("help_native_grouping_note", "Grouping controls whether selected items get their own output groups or share one group per source track."))
                    return l
                end
            }
        end },
        { tr("help_reaper", "Reaper"), function()
            return { __columns = true,
                left = function()
                    local l = {}
                    addHead(l, tr("help_native_selection", "Selection"))
                    addLine(l, "  " .. tr("help_native_selection_priority", "Items/tracks take priority."))
                    addLine(l, "  " .. tr("help_native_selection_fallback", "Time selection is fallback."))
                    addLine(l, "")
                    addHead(l, tr("help_native_temp_folder", "Temp folder"))
                    addLine(l, "  " .. tr("help_native_temp_per_run", "STEMwerk_* created per run."))
                    addLine(l, "  " .. tr("help_native_temp_io", "Input WAV and output stems."))
                    return l
                end,
                right = function()
                    local l = {}
                    addHead(l, tr("help_native_cleanup_logs", "Cleanup and logs"))
                    addLine(l, "  " .. tr("help_native_logs_preserved", "Logs always preserved."))
                    addLine(l, "  " .. tr("help_native_keep_temp_controls", "Keep temp files controls"))
                    addLine(l, "  " .. tr("help_native_cleanup_scope", "audio/work cleanup only."))
                    addLine(l, "")
                    addHead(l, tr("help_native_support_bundle", "Support bundle"))
                    addLine(l, "  STEMwerk_Save_Support_Bundle")
                    addLine(l, "  " .. tr("help_native_support_bundle_where", "from REAPER Action List."))
                    addLine(l, "  " .. tr("help_native_support_bundle_scope", "Text logs only, no audio."))
                    return l
                end
            }
        end },
        { tr("help_ui_modes", "UI Modes"), function()
            return { __columns = true,
                left = function()
                    local l = {}
                    addHead(l, tr("help_native_ui_mode", "UI mode"))
                    addLine(l, "  " .. tr("help_native_ui_mode_native", "Native") .. "   " .. tr("help_native_ui_mode_native_desc", "Default utility interface"))
                    addLine(l, "  " .. tr("help_native_ui_mode_visual", "Visual") .. "   " .. tr("help_native_ui_mode_visual_desc", "flarkAUDIO animated UI"))
                    addLine(l, "")
                    addHead(l, tr("help_native_switching", "Switching"))
                    addLine(l, "  [UI]           " .. tr("help_native_switch_ui", "Native -> Visual"))
                    addLine(l, "  FX right-click  " .. tr("help_native_switch_fx", "Visual -> Native"))
                    addLine(l, "")
                    addLine(l, "  " .. tr("help_native_choice_saved", "Choice is saved."))
                    return l
                end,
                right = function()
                    local l = {}
                    addHead(l, tr("help_native_visual_only", "Visual mode only"))
                    addLine(l, "  " .. tr("help_native_visual_cycle_1", "Day/night right-click"))
                    addLine(l, "  " .. tr("help_native_visual_cycle_2", "cycles colour presets."))
                    addLine(l, "  " .. tr("help_native_visual_cycle_3", "Native is not in that cycle."))
                    addLine(l, "")
                    addHead(l, tr("help_native_dark_light", "Dark / Light"))
                    addLine(l, "  " .. tr("help_native_dark_light_1", "[D]/[L] changes brightness."))
                    addLine(l, "  " .. tr("help_native_dark_light_2", "Works in both modes."))
                    return l
                end
            }
        end },
        { tr("help_about", "About"), function()
            return { __columns = true,
                left = function()
                    local l = {}
                    addHead(l, "STEMwerk")
                    addLine(l, "  " .. tr("help_native_welcome_sub", "Stem separation workflow utility for REAPER"))
                    addLine(l, "  " .. tr("about_version","Version") .. ": " .. tostring(APP_VERSION or ""))
                    addLine(l, "")
                    addHead(l, tr("help_native_separation", "Separation"))
                    addLine(l, "  " .. tr("help_native_about_4stem", "4-stem: Vocals, Drums, Bass, Other"))
                    addLine(l, "  " .. tr("help_native_about_6stem", "6-stem: adds Guitar, Piano"))
                    addLine(l, "  " .. tr("help_native_about_models", "Fast / Quality / 6-Stem models"))
                    addLine(l, "  " .. tr("help_native_about_output", "New tracks or in-place output"))
                    return l
                end,
                right = function()
                    local l = {}
                    addHead(l, tr("help_native_engine", "Engine"))
                    addLine(l, "  " .. tr("help_native_about_engine", "Demucs / audio-separator"))
                    addLine(l, "")
                    addHead(l, tr("help_native_ui", "UI"))
                    addLine(l, "  " .. tr("help_native_about_ui_default", "REAPER Native by default"))
                    addLine(l, "  " .. tr("help_native_about_ui_visual", "flarkAUDIO Visual via [UI]"))
                    addLine(l, "")
                    addHead(l, tr("help_native_support", "Support"))
                    addLine(l, "  " .. tr("help_native_support_intro", "If setup or processing fails:"))
                    addLine(l, "  - " .. tr("help_native_support_use_bundle", "Use Save Support Bundle."))
                    addLine(l, "  - " .. tr("help_native_support_no_payloads", "Do not send audio, project, or model files unless asked."))
                    addLine(l, "  - " .. tr("help_native_support_context", "Include your OS, REAPER version, selected model/device, and what you tried."))
                    return l
                end
            }
        end },
    }
    if helpState.currentTab < 1 or helpState.currentTab > #tabs then helpState.currentTab = 1 end

    col(bg, 1)
    gfx.rect(0, 0, w, h, 1)

    local pad = math.max(12, math.floor(math.min(w, h) * 0.025))
    local helpScale = math.max(1.0, math.min(1.65, math.min(w / 760, h / 520)))
    local function HS(val) return math.floor(val * helpScale + 0.5) end
    local topH = HS(58)
    col(border, 0.5)
    gfx.line(0, topH, w, topH)

    gfx.setfont(1, "Arial", HS(22), string.byte('b'))
    col(text, 1)
    gfx.x, gfx.y = pad, 12
    gfx.drawstr(tr("help_native_title", "STEMwerk Help"))
    gfx.setfont(1, "Arial", HS(12))
    col(muted, 1)
    gfx.x, gfx.y = pad + HS(185), HS(20)
    gfx.drawstr(tr("help_native_subtitle", "Setup, stems and workflow"))

    local function smallBox(label, x, y, ww, hh)
        local hover = mx >= x and mx <= x + ww and my >= y and my <= y + hh
        col(hover and hoverBg or bg, 1)
        gfx.rect(x, y, ww, hh, 1)
        col(border, 1)
        gfx.rect(x, y, ww, hh, 0)
        gfx.setfont(1, "Arial", HS(10), string.byte('b'))
        col(text, 1)
        local tw = gfx.measurestr(label)
        gfx.x, gfx.y = x + (ww - tw) / 2, y + (hh - gfx.texth) / 2
        gfx.drawstr(label)
        return hover
    end

    local _iconScale = 1.0
    local _themeSize = math.max(HS(18), math.floor(HS(22) * _iconScale + 0.5))
    local _helpUC = {
        S = HS,
        w = w,
        mx = mx, my = my,
        mouseDown = mouseDown,
        rightMouseDown = rightMouseDown,
        state = helpState,
        setLanguageFn = setLanguage,
        themeX = w - _themeSize - HS(10),
        themeY = HS(8),
        themeSize = _themeSize,
    }
    UI_CONTROLS.drawUtilityControls(_helpUC)

    local tabY = topH + pad
    local tabX = pad
    local tabH = HS(36)
    local clickedTab = nil
    for i, tab in ipairs(tabs) do
        gfx.setfont(1, "Arial", HS(13))
        local tabW = math.max(HS(86), gfx.measurestr(tab[1]) + HS(24))
        local hover = mx >= tabX and mx <= tabX + tabW and my >= tabY and my <= tabY + tabH
        col((helpState.currentTab == i) and activeBg or (hover and panel or bg), 1)
        gfx.rect(tabX, tabY, tabW, tabH, 1)
        col(border, (helpState.currentTab == i or hover) and 1 or 0.4)
        gfx.rect(tabX, tabY, tabW, tabH, 0)
        col((helpState.currentTab == i and not dark) and {0.02, 0.02, 0.02} or text, 1)
        local tw = gfx.measurestr(tab[1])
        gfx.x, gfx.y = tabX + (tabW - tw) / 2, tabY + (tabH - gfx.texth) / 2
        gfx.drawstr(tab[1])
        if hover and mouseDown and not helpState.wasMouseDown then clickedTab = i end
        tabX = tabX + tabW + 6
    end
    if clickedTab then helpState.currentTab = clickedTab end

    -- Keyboard hint: right-aligned in the tab row, readable but subtle
    gfx.setfont(1, "Arial", HS(12))
    col(text, 0.55)
    local kbHint = tr("help_native_tabs_hint", "<-/-> tabs  |  ESC back")
    local kbHintW = gfx.measurestr(kbHint)
    gfx.x = w - pad - kbHintW
    gfx.y = tabY + math.floor((tabH - gfx.texth) / 2)
    gfx.drawstr(kbHint)

    local contentX = pad
    local contentY = tabY + tabH + pad
    local contentW = w - pad * 2
    local contentH = h - contentY - 44
    -- Content area: no separate fill — blends into canvas bg. Subtle top border only.
    col(border, 0.3)
    gfx.line(contentX, contentY, contentX + contentW, contentY)

    local tab = tabs[helpState.currentTab]
    local lineH = HS(21)
    local maxW = contentW - 42

    -- Single-column renderer (used when tab returns a plain line array)
    local function drawSingleCol(lines, startY)
        local y = startY
        gfx.setfont(1, "Arial", HS(15))
        for _, rawLine in ipairs(lines) do
            if y > contentY + contentH - 20 then break end
            if rawLine == "" then
                y = y + math.floor(lineH * 0.7)
            else
                local isHead = rawLine:sub(1, 1) == HEADING_MARKER
                local dLine = isHead and rawLine:sub(2) or rawLine
                local isInd = (not isHead) and dLine:match("^%s") ~= nil
                local drawX = contentX + (isInd and 38 or 22)
                local wrapW = maxW - (isInd and 16 or 0)
                local wrapped = _wrapTextToWidth(tostring(dLine):gsub("^%s+", ""), wrapW)
                for _, ln in ipairs(wrapped) do
                    if y > contentY + contentH - 20 then break end
                    col(isHead and activeBg or (isInd and muted or text), 1)
                    gfx.x, gfx.y = drawX, y
                    gfx.drawstr(ln)
                    y = y + lineH
                end
                y = y + 2
            end
        end
    end

    -- Two-column renderer (used when tab returns {__columns=true, left=fn, right=fn})
    local function drawOneCol(lines, startX, colW, startY)
        local y = startY
        gfx.setfont(1, "Arial", HS(15))
        for _, rawLine in ipairs(lines) do
            if y > contentY + contentH - 20 then break end
            if rawLine == "" then
                y = y + math.floor(lineH * 0.5)
            else
                local isHead = rawLine:sub(1, 1) == HEADING_MARKER
                local dLine = isHead and rawLine:sub(2) or rawLine
                local isInd = (not isHead) and dLine:match("^%s") ~= nil
                local dx = startX + (isInd and 14 or 4)
                local ww = colW - (isInd and 18 or 8)
                local wrapped = _wrapTextToWidth(tostring(dLine):gsub("^%s+", ""), ww)
                for _, ln in ipairs(wrapped) do
                    if y > contentY + contentH - 20 then break end
                    col(isHead and activeBg or (isInd and muted or text), 1)
                    gfx.x, gfx.y = dx, y
                    gfx.drawstr(ln)
                    y = y + lineH
                end
                y = y + 1
            end
        end
    end

    local tabContent = tab[2]()
    if type(tabContent) == "table" and tabContent.__columns then
        local colW = math.floor((contentW - pad) / 2)
        local divX = contentX + colW + math.floor(pad * 0.5)
        col(border, 0.35)
        gfx.line(divX, contentY + HS(8), divX, contentY + contentH - HS(8))
        local startY = contentY + HS(12)
        drawOneCol(tabContent.left and tabContent.left() or {}, contentX + HS(6), colW - HS(10), startY)
        drawOneCol(tabContent.right and tabContent.right() or {}, divX + HS(6), colW - HS(10), startY)
    else
        drawSingleCol(type(tabContent) == "table" and tabContent or {}, contentY + HS(14))
    end

    local btnW, btnH = HS(108), HS(34)
    local btnX, btnY = (w - btnW) / 2, h - HS(54)
    local backHover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH
    local backFill = backHover
        and _tc(T_.buttonPrimaryHover, dark and {0.36,0.54,0.38} or {0.62,0.74,0.64})
        or activeBg
    col(backFill, 1)
    gfx.rect(btnX, btnY, btnW, btnH, 1)
    col(border, 1)
    gfx.rect(btnX, btnY, btnW, btnH, 0)
    gfx.setfont(1, "Arial", HS(13), string.byte('b'))
    col(dark and text or {0.04, 0.04, 0.04}, 1)
    local backText = tr("back", "Back")
    local bw = gfx.measurestr(backText)
    gfx.x, gfx.y = btnX + (btnW - bw) / 2, btnY + (btnH - gfx.texth) / 2
    gfx.drawstr(backText)

    if backHover and mouseDown and not helpState.wasMouseDown then return "close" end
    local char = gfx.getchar()
    if char == -1 or char == 27 then return "close" end
    if char == 1818584692 then          -- Left arrow: previous tab
        helpState.currentTab = math.max(1, helpState.currentTab - 1)
    elseif char == 1919379572 then      -- Right arrow: next tab
        helpState.currentTab = math.min(#tabs, helpState.currentTab + 1)
    end

    if _helpUC and _helpUC.tooltipText then
        local function ttS(v)
            return (type(S) == "function" and S(v)) or HS(v)
        end
        local ttPad = ttS(10)
        gfx.setfont(1, "Arial", ttS(13))
        local ttLineH = math.max(gfx.texth + ttS(2), ttS(17))
        drawTooltipStyled(_helpUC.tooltipText, _helpUC.tooltipX, _helpUC.tooltipY, w, h, ttPad, ttLineH, math.min(w * 0.62, ttS(560)))
    end
    helpState.wasMouseDown = mouseDown
    helpState.wasRightMouseDown = rightMouseDown
    gfx.update()
    return nil
end

-- Draw Art Gallery window - SPECTACULAR GRAPHICAL ANIMATIONS
local function drawArtGallery()
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
        return drawUtilityNativeHelpWindow()
    end

    local w, h = gfx.w, gfx.h

    -- Calculate scale for large window (with text zoom for non-gallery tabs)
    -- Base scale is larger (1.5x) for better readability
    local baseScale = math.min(w / 600, h / 450) * 1.5
    baseScale = math.max(0.5, math.min(5.0, baseScale))

    -- Smooth text zoom interpolation
    helpState.textZoom = helpState.textZoom + (helpState.targetTextZoom - helpState.textZoom) * 0.15

    -- UI() = fixed scale for UI elements that should NOT zoom (tabs, buttons, theme toggle, etc.)
    local function UI(val) return math.floor(val * baseScale + 0.5) end

    -- Apply text zoom to scale for non-gallery tabs (content only)
    -- Tab 5 (Gallery) uses art zoom instead
    local scale = baseScale
    if helpState.currentTab ~= 5 then
        scale = baseScale * helpState.textZoom
    end
    -- PS() = zoomed scale for content that CAN zoom
    local function PS(val) return math.floor(val * scale + 0.5) end

    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local middleMouseDown = gfx.mouse_cap & 64 == 64  -- Middle mouse button
    local time = os.clock() - artGalleryState.startTime

    -- Tooltip tracking / UI click tracking for background art click
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0
    GUI.uiClickedThisFrame = false

    -- === MOUSE WHEEL ZOOM ===
    local mouseWheel = gfx.mouse_wheel
    if mouseWheel ~= artGalleryState.lastMouseWheel then
        local delta = (mouseWheel - artGalleryState.lastMouseWheel) / 120

        if helpState.currentTab == 5 then
            -- Gallery tab: zoom art (fly-through effect with huge zoom range)
            local zoomFactor = 1.15
            if delta > 0 then
                artGalleryState.targetZoom = math.min(50.0, artGalleryState.targetZoom * zoomFactor)  -- Much higher max for fly-through
            elseif delta < 0 then
                artGalleryState.targetZoom = math.max(0.1, artGalleryState.targetZoom / zoomFactor)  -- Lower min to zoom way out
            end
            -- Zoom towards mouse position
            local zoomCenterX = mx - w/2
            local zoomCenterY = my - h/2
            if delta > 0 then
                artGalleryState.targetPanX = artGalleryState.targetPanX - zoomCenterX * 0.15
                artGalleryState.targetPanY = artGalleryState.targetPanY - zoomCenterY * 0.15
            else
                artGalleryState.targetPanX = artGalleryState.targetPanX + zoomCenterX * 0.1
                artGalleryState.targetPanY = artGalleryState.targetPanY + zoomCenterY * 0.1
            end
        else
            -- Other tabs: zoom text (larger range now)
            local zoomFactor = 1.15
            if delta > 0 then
                helpState.targetTextZoom = math.min(4.0, helpState.targetTextZoom * zoomFactor)
            elseif delta < 0 then
                helpState.targetTextZoom = math.max(0.4, helpState.targetTextZoom / zoomFactor)
            end
        end
        artGalleryState.lastMouseWheel = mouseWheel
    end

    -- Track click start for click-to-new-art on text tabs
    if mouseDown and not helpState.wasMouseDown then
        helpState.clickStartX = mx
        helpState.clickStartY = my
        helpState.wasDrag = false
    end

    -- Mouse handling depends on tab
    local rightMouseDown = gfx.mouse_cap & 2 == 2

    if helpState.currentTab == 5 then
        -- === GALLERY TAB MOUSE CONTROLS ===
        -- Left-click drag = pan
        -- Right-click drag = rotate
        -- Single left-click (no drag) = new art
        -- Double-click = reset

        -- Left-click drag = pan
        if mouseDown and not artGalleryState.isDragging then
            artGalleryState.isDragging = true
            artGalleryState.dragStartX = mx
            artGalleryState.dragStartY = my
            artGalleryState.dragStartPanX = artGalleryState.targetPanX
            artGalleryState.dragStartPanY = artGalleryState.targetPanY
        elseif mouseDown and artGalleryState.isDragging then
            local dx = mx - artGalleryState.dragStartX
            local dy = my - artGalleryState.dragStartY
            -- Mark as drag if moved more than 5 pixels
            if math.abs(dx) > 5 or math.abs(dy) > 5 then
                helpState.wasDrag = true
            end
            artGalleryState.targetPanX = artGalleryState.dragStartPanX + dx
            artGalleryState.targetPanY = artGalleryState.dragStartPanY + dy
        elseif not mouseDown then
            artGalleryState.isDragging = false
        end

        -- Right-click drag = rotate (ignore top/bottom control areas)
        local topControlArea = UI(45)
        local bottomControlArea = UI(60)
        local bottomY = h - bottomControlArea
        local rightForArt = rightMouseDown and my >= topControlArea and my <= bottomY

        if rightForArt and not helpState.isRotating then
            helpState.isRotating = true
            helpState.rotateStartX = mx
            helpState.rotateStartY = my
            helpState.rotateStartAngle = helpState.targetRotation
        elseif rightForArt and helpState.isRotating then
            -- Rotation based on horizontal mouse movement
            local dx = mx - helpState.rotateStartX
            helpState.targetRotation = helpState.rotateStartAngle + dx * 0.01
        elseif not rightForArt then
            helpState.isRotating = false
        end

        -- Middle mouse drag = pan (alternative)
        if middleMouseDown then
            if not artGalleryState.isDragging then
                artGalleryState.isDragging = true
                artGalleryState.dragStartX = mx
                artGalleryState.dragStartY = my
                artGalleryState.dragStartPanX = artGalleryState.targetPanX
                artGalleryState.dragStartPanY = artGalleryState.targetPanY
            else
                artGalleryState.targetPanX = artGalleryState.dragStartPanX + (mx - artGalleryState.dragStartX)
                artGalleryState.targetPanY = artGalleryState.dragStartPanY + (my - artGalleryState.dragStartY)
            end
        end
    else
        -- === NON-GALLERY TABS: text panning ===
        local inContentArea = my > PS(50) and my < (h - PS(60))  -- Not in tabs or buttons
        local panMouseDown = mouseDown or rightMouseDown or middleMouseDown
        if panMouseDown and inContentArea and not helpState.textDragging then
            helpState.textDragging = true
            helpState.textDragStartX = mx
            helpState.textDragStartY = my
            helpState.textDragStartPanX = helpState.targetTextPanX
            helpState.textDragStartPanY = helpState.targetTextPanY
        elseif panMouseDown and helpState.textDragging then
            local dx = mx - helpState.textDragStartX
            local dy = my - helpState.textDragStartY
            if math.abs(dx) > 5 or math.abs(dy) > 5 then
                helpState.wasDrag = true
            end
            helpState.targetTextPanX = helpState.textDragStartPanX + dx
            helpState.targetTextPanY = helpState.textDragStartPanY + dy
        elseif not panMouseDown then
            helpState.textDragging = false
        end
    end

    -- Smooth interpolation for camera movement
    local smoothing = 0.15
    artGalleryState.zoom = artGalleryState.zoom + (artGalleryState.targetZoom - artGalleryState.zoom) * smoothing
    artGalleryState.panX = artGalleryState.panX + (artGalleryState.targetPanX - artGalleryState.panX) * smoothing
    artGalleryState.panY = artGalleryState.panY + (artGalleryState.targetPanY - artGalleryState.panY) * smoothing
    -- Rotation interpolation
    helpState.rotation = helpState.rotation + (helpState.targetRotation - helpState.rotation) * smoothing

    -- Smooth interpolation for text pan
    helpState.textPanX = helpState.textPanX + (helpState.targetTextPanX - helpState.textPanX) * smoothing
    helpState.textPanY = helpState.textPanY + (helpState.targetTextPanY - helpState.textPanY) * smoothing

    local function resetTextView()
        local defaultZoom = 1.0
        if helpState.currentTab == 1 then
            defaultZoom = 0.92
        elseif helpState.currentTab == 2 then
            defaultZoom = 0.90
        elseif helpState.currentTab == 3 then
            defaultZoom = 0.85
        end
        helpState.targetTextZoom = defaultZoom
        helpState.targetTextPanX = 0
        helpState.targetTextPanY = 0
    end

    -- Double-click to reset view
    -- Skip if this was a drag operation (wasDrag flag set when moved > 5 pixels)
    if mouseDown and not artGalleryState.wasMouseDown then
        local now = os.clock()
        if artGalleryState.lastClickTime and now - artGalleryState.lastClickTime < 0.3 then
            -- Double click - reset view ONLY if not dragging
            if not helpState.wasDrag then
                if helpState.currentTab == 5 then
                    artGalleryState.targetZoom = 1.0
                    artGalleryState.targetPanX = 0
                    artGalleryState.targetPanY = 0
                    helpState.targetRotation = 0
                else
                    resetTextView()
                end
            end
        end
        artGalleryState.lastClickTime = now
    end

    -- Apply zoom and pan to get effective center
    local zoom = artGalleryState.zoom
    local panX = artGalleryState.panX
    local panY = artGalleryState.panY

    -- Transform function: applies zoom and pan to coordinates relative to center
    local function transform(x, y)
        local cx, cy = w/2, h/2
        local tx = cx + (x - cx) * zoom + panX
        local ty = cy + (y - cy) * zoom + panY
        return tx, ty
    end

    -- Scaled size with zoom
    local function ZS(val)
        return PS(val) * zoom
    end

    -- STEM colors
    local stemColors = {
        {1.0, 0.4, 0.4},   -- S = Vocals (red)
        {0.4, 0.8, 1.0},   -- T = Drums (blue)
        {0.6, 0.4, 1.0},   -- E = Bass (purple)
        {0.4, 1.0, 0.6},   -- M = Other (green)
        {1.0, 0.7, 0.3},   -- About (orange/gold)
    }

    -- Background for all tabs - pure black/white
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)  -- Pure black for dark mode
    else
        gfx.set(1, 1, 1, 1)  -- Pure white for light mode
    end
    gfx.rect(0, 0, w, h, 1)

    -- === TAB BAR (uses UI() - does NOT zoom) ===
    local tabY = UI(8)
    local tabH = UI(24)

    -- Header logo removed (requested): keep only tabs + controls.

    -- === CONTROLS FADE LOGIC (all Help tabs) ===
    -- Fade out tabs + top-right icons + Back button when the mouse is not hovering near them.
    local controlsOpacity = 1.0
    do
        local topControlArea = UI(45)    -- Tabs + icons live here
        local bottomControlArea = UI(60) -- Back button + bottom credits/hints
        local bottomY = h - bottomControlArea

        if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
            helpState.controlsOpacity = 1.0
            controlsOpacity = 1.0
        else
            local mouseInControls = (my < topControlArea) or (my > bottomY)
            helpState.targetControlsOpacity = mouseInControls and 1.0 or 0.0

            local fadeSpeed = mouseInControls and 0.25 or 0.08  -- Faster fade-in, slower fade-out
            helpState.controlsOpacity = helpState.controlsOpacity + (helpState.targetControlsOpacity - helpState.controlsOpacity) * fadeSpeed
            helpState.controlsOpacity = math.max(0, math.min(1, helpState.controlsOpacity))
            controlsOpacity = helpState.controlsOpacity
        end
    end
    local tabs = {T("help_welcome"), T("help_quickstart"), T("help_stems"), T("help_reaper"), T("help_gallery"), T("help_about")}

    -- Reserve space for the top-right controls so tabs never overlap EN/FX.
    local iconScale = 0.66
    local themeSize = math.max(UI(12), math.floor(UI(20) * iconScale + 0.5))
    local themeX = w - themeSize - UI(10)
    local themeY = UI(8)
    local langW = UI(22)
    local langX = themeX - langW - UI(6)

    local leftSafe = UI(10)
    local rightSafe = langX - UI(10)
    local availableTabsW = math.max(UI(120), rightSafe - leftSafe)

    -- Tab widths (shrink tab font if needed on small windows)
    local tabWidths = {}
    local totalTabW = 0
    local tabFont = UI(11)
    gfx.setfont(1, "Arial", tabFont)
    for i, tab in ipairs(tabs) do
        tabWidths[i] = gfx.measurestr(tab) + UI(20)
        totalTabW = totalTabW + tabWidths[i]
    end
    if totalTabW > availableTabsW then
        tabFont = UI(10)
        gfx.setfont(1, "Arial", tabFont)
        totalTabW = 0
        for i, tab in ipairs(tabs) do
            tabWidths[i] = gfx.measurestr(tab) + UI(18)
            totalTabW = totalTabW + tabWidths[i]
        end
    end

    local desiredTabStartX = (w - totalTabW) / 2
    local tabStartX = math.min(math.max(desiredTabStartX, leftSafe), rightSafe - totalTabW)
    local tabX = tabStartX
    local tabHovers = {}
    local clickedTab = nil

    for i, tab in ipairs(tabs) do
        local isActive = helpState.currentTab == i
        local hover = mx >= tabX and mx <= tabX + tabWidths[i] and my >= tabY and my <= tabY + tabH
        tabHovers[i] = hover

        -- Tab background (with controlsOpacity for Gallery tab)
        local bgAlpha
        if isActive then
            bgAlpha = 0.8 * controlsOpacity
        elseif hover then
            bgAlpha = 0.4 * controlsOpacity
        else
            bgAlpha = 0.6 * controlsOpacity
        end
        local tabColor = stemColors[i] or {0.45, 0.55, 0.7}
        if isActive or hover then
            gfx.set(tabColor[1], tabColor[2], tabColor[3], bgAlpha)
        else
            if SETTINGS.darkMode then
                gfx.set(0.3, 0.3, 0.35, bgAlpha)
            else
                gfx.set(0.72, 0.72, 0.76, math.max(bgAlpha, 0.72 * controlsOpacity))
            end
        end
        gfx.rect(tabX, tabY, tabWidths[i], tabH, 1)

        -- Tab text
        local textAlpha = (isActive and 1 or 0.82) * controlsOpacity
        if SETTINGS.darkMode then
            gfx.set(1, 1, 1, textAlpha)
        else
            local tc = isActive and {0.10, 0.10, 0.12} or {0.20, 0.20, 0.24}
            gfx.set(tc[1], tc[2], tc[3], textAlpha)
        end
        local textW = gfx.measurestr(tab)
        gfx.x = tabX + (tabWidths[i] - textW) / 2
        gfx.y = tabY + (tabH - gfx.texth) / 2
        gfx.drawstr(tab)

        -- Check click (only if controls are visible enough)
        if hover and mouseDown and not helpState.wasMouseDown and controlsOpacity > 0.3 then
            clickedTab = i
        end

        tabX = tabX + tabWidths[i]
    end

    local topRightControlsCtx = {
        profile = "help",
        w = w,
        S = UI,
        setLanguageFn = setLanguage,
        mx = mx,
        my = my,
        mouseDown = mouseDown,
        rightMouseDown = rightMouseDown,
        state = helpState,
        controlsOpacity = controlsOpacity,
        iconScale = iconScale,
        themeX = themeX,
        themeY = themeY,
        themeSize = themeSize,
        tooltipText = tooltipText,
        tooltipX = tooltipX,
        tooltipY = tooltipY,
    }
    UI_CONTROLS.drawTopRightControls(topRightControlsCtx)
    tooltipText = topRightControlsCtx.tooltipText
    tooltipX = topRightControlsCtx.tooltipX
    tooltipY = topRightControlsCtx.tooltipY

    -- Content area starts below tabs
    local contentY = tabY + tabH + UI(10)
    local contentH = h - contentY - UI(40)

    -- Apply text pan offset for non-gallery tabs
    local textOffsetX = 0
    local textOffsetY = 0
    if helpState.currentTab ~= 5 then
        textOffsetX = helpState.textPanX
        textOffsetY = helpState.textPanY
        -- Apply Y offset directly to content area for text tabs
        contentY = contentY + textOffsetY
    end

    -- === TAB CONTENT ===
    if helpState.currentTab == 5 then
        -- ART GALLERY TAB - Fullscreen procedural art (below tabs)

        -- Tab area height to keep tabs visible
        local tabAreaH = UI(40)

        -- Define art display area (below tabs)
        local artX = 0
        local artY = tabAreaH
        local artW = w
        local artH = h - tabAreaH

        -- Apply zoom and pan to art area
        local zoomedW = artW * zoom
        local zoomedH = artH * zoom
        local zoomedX = artX - (zoomedW - artW) / 2 + panX
        local zoomedY = artY - (zoomedH - artH) / 2 + panY

        -- Draw the procedural art (fullscreen, no separate background) with rotation
        drawProceduralArt(zoomedX, zoomedY, zoomedW, zoomedH, time, helpState.rotation, true)

        -- Show "FX OFF" indicator when visual effects are disabled
        if not SETTINGS.visualFX then
            gfx.setfont(1, "Arial", UI(14))
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.3)
            local offText = T("gallery_fx_off_message")
            local offW = gfx.measurestr(offText)
            gfx.x = (w - offW) / 2
            -- Uniform per column: preset button labels share a stable font size.
            local presetLabels = {
                "Karaoke (K)",
                "All (A)",
                "Vocals (V)",
                "Drums (D)",
                "Bass (B)",
                "Other (O)",
                "Piano (P)",
                "Guitar (G)",
            }
            local presetsColFontSize = getUniformFontSizeCached("main_presets_col", presetLabels, colW)
            gfx.y = h / 2
            gfx.drawstr(offText)
        end

        -- Single click (no drag) generates new art - detect on mouse RELEASE
        if not mouseDown and helpState.wasMouseDown and not helpState.wasDrag then
            -- Only if not clicking on tabs or close button
            local tabAreaBottom = UI(40)
            local closeBtnTop = h - UI(50)
            if helpState.clickStartY > tabAreaBottom and helpState.clickStartY < closeBtnTop then
                generateNewArt()
            end
        end

    -- END OF NEW PROCEDURAL ART CODE - skip old hardcoded art
    if false then
        -- Old hardcoded art code below (disabled)
        local prismX, prismY = w/2, h/2
        local prismSize = PS(80)

        -- Incoming white beam (animated)
        local beamPulse = 0.7 + math.sin(time * 3) * 0.3
        gfx.set(1, 1, 1, beamPulse)
        for i = -2, 2 do
            gfx.line(PS(50), prismY + i, prismX - prismSize/2, prismY + i)
        end

        -- Draw prism (triangle)
        gfx.set(0.3, 0.3, 0.4, 0.8)
        local p1x, p1y = prismX - prismSize/2, prismY + prismSize/2
        local p2x, p2y = prismX + prismSize/2, prismY + prismSize/2
        local p3x, p3y = prismX, prismY - prismSize/2
        -- Fill prism
        for y = p3y, p1y do
            local progress = (y - p3y) / (p1y - p3y)
            local halfWidth = progress * prismSize / 2
            gfx.line(prismX - halfWidth, y, prismX + halfWidth, y)
        end
        -- Prism outline
        gfx.set(0.5, 0.5, 0.6, 1)
        gfx.line(p1x, p1y, p2x, p2y)
        gfx.line(p2x, p2y, p3x, p3y)
        gfx.line(p3x, p3y, p1x, p1y)

        -- Outgoing colored beams (spreading)
        local beamStartX = prismX + prismSize/2
        local beamEndX = w - PS(50)
        for i, color in ipairs(stemColors) do
            local angle = (i - 2.5) * 0.15
            local waveOffset = math.sin(time * 4 + i) * PS(5)
            local alpha = 0.6 + math.sin(time * 3 + i * 0.5) * 0.4

            gfx.set(color[1], color[2], color[3], alpha)
            local endY = prismY + (beamEndX - beamStartX) * math.tan(angle) + waveOffset
            for j = -2, 2 do
                gfx.line(beamStartX, prismY + j, beamEndX, endY + j)
            end

            -- Stem label at end
            gfx.setfont(1, "Arial", PS(14), string.byte('b'))
            local labels = {"V", "D", "B", "O"}
            local lw = gfx.measurestr(labels[i])
            gfx.x = beamEndX + PS(10)
            gfx.y = endY - PS(7)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 2 then
        -- === NEURAL SEPARATION ===
        -- Neural network nodes firing and processing

        local layers = {3, 6, 8, 6, 4}  -- neurons per layer
        local layerSpacing = (w - PS(150)) / (#layers - 1)
        local nodes = {}

        -- Create and draw nodes
        for l, count in ipairs(layers) do
            nodes[l] = {}
            local layerX = PS(75) + (l - 1) * layerSpacing
            local startY = centerY - (count - 1) * PS(25)

            for n = 1, count do
                local nodeY = startY + (n - 1) * PS(50)
                nodes[l][n] = {x = layerX, y = nodeY}

                -- Node pulse animation
                local pulsePhase = time * 3 + l * 0.5 + n * 0.3
                local pulse = 0.5 + math.sin(pulsePhase) * 0.5
                local radius = PS(12) + pulse * PS(5)

                -- Glow effect
                if l == #layers then
                    local color = stemColors[n] or stemColors[1]
                    gfx.set(color[1], color[2], color[3], 0.3 * pulse)
                    gfx.circle(layerX, nodeY, radius + PS(8), 1, 1)
                    gfx.set(color[1], color[2], color[3], 0.8)
                else
                    gfx.set(0.5, 0.6, 0.8, 0.3 * pulse)
                    gfx.circle(layerX, nodeY, radius + PS(5), 1, 1)
                    gfx.set(0.4, 0.5, 0.7, 0.8)
                end
                gfx.circle(layerX, nodeY, radius, 1, 1)

                -- Draw connections to previous layer
                if l > 1 then
                    for pn = 1, #nodes[l-1] do
                        local prevNode = nodes[l-1][pn]
                        local connPulse = math.sin(time * 5 + l + n + pn) * 0.5 + 0.5
                        gfx.set(0.3, 0.4, 0.6, 0.15 + connPulse * 0.2)
                        gfx.line(prevNode.x, prevNode.y, layerX, nodeY)
                    end
                end
            end
        end

        -- Draw labels for output
        local labels = {"Vocals", "Drums", "Bass", "Other"}
        gfx.setfont(1, "Arial", PS(11))
        for i = 1, 4 do
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            local node = nodes[#layers][i]
            gfx.x = node.x + PS(20)
            gfx.y = node.y - PS(5)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 3 then
        -- === THE FOUR ELEMENTS ===
        -- Four orbiting elemental spheres

        local orbitRadius = PS(120)
        local sphereRadius = PS(40)

        -- Central mix sphere
        local centralPulse = 0.8 + math.sin(time * 2) * 0.2
        gfx.set(0.9, 0.9, 0.9, centralPulse * 0.5)
        gfx.circle(centerX, centerY, PS(50), 1, 1)
        gfx.set(1, 1, 1, 0.8)
        gfx.circle(centerX, centerY, PS(45), 0, 1)
        gfx.setfont(1, "Arial", PS(12), string.byte('b'))
        gfx.set(0.3, 0.3, 0.3, 1)
        local mixW = gfx.measurestr("MIX")
        gfx.x = centerX - mixW/2
        gfx.y = centerY - PS(6)
        gfx.drawstr("MIX")

        -- Four orbiting elements
        local elements = {"Vocals", "Drums", "Bass", "Other"}
        local symbols = {"~", "#", "=", "*"}
        for i = 1, 4 do
            local angle = time * 0.5 + (i - 1) * math.pi / 2
            local wobble = math.sin(time * 3 + i) * PS(10)
            local ex = centerX + math.cos(angle) * (orbitRadius + wobble)
            local ey = centerY + math.sin(angle) * (orbitRadius + wobble)

            -- Element glow
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.3)
            gfx.circle(ex, ey, sphereRadius + PS(15), 1, 1)

            -- Element sphere
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.9)
            gfx.circle(ex, ey, sphereRadius, 1, 1)

            -- Element symbol
            gfx.set(1, 1, 1, 1)
            gfx.setfont(1, "Arial", PS(24), string.byte('b'))
            local symW = gfx.measurestr(symbols[i])
            gfx.x = ex - symW/2
            gfx.y = ey - PS(10)
            gfx.drawstr(symbols[i])

            -- Element name
            gfx.setfont(1, "Arial", PS(10))
            local nameW = gfx.measurestr(elements[i])
            gfx.x = ex - nameW/2
            gfx.y = ey + PS(12)
            gfx.drawstr(elements[i])

            -- Connection line to center
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.3)
            gfx.line(centerX, centerY, ex, ey)
        end

    elseif artGalleryState.currentArt == 4 then
        -- === WAVEFORM SURGERY ===
        -- Scalpel cutting through waveform, separating colors

        local waveW = w - PS(100)
        local waveH = PS(150)
        local waveStartX = PS(50)
        local waveY = centerY

        -- Draw mixed waveform (before cut)
        local cutX = waveStartX + (time * 50) % waveW

        -- Before cut - mixed gray
        for x = waveStartX, math.min(cutX, waveStartX + waveW) do
            local t = (x - waveStartX) / waveW * math.pi * 8
            local amp = waveH/2 * (0.5 + math.sin(t * 0.5) * 0.3)
            local y = waveY + math.sin(t + time * 2) * amp
            gfx.set(0.5, 0.5, 0.5, 0.6)
            gfx.line(x, waveY, x, y)
        end

        -- After cut - separated colored stems
        if cutX > waveStartX then
            for i, color in ipairs(stemColors) do
                local offset = (i - 2.5) * PS(35)
                gfx.set(color[1], color[2], color[3], 0.7)
                for x = cutX, waveStartX + waveW do
                    local t = (x - waveStartX) / waveW * math.pi * 8
                    local amp = waveH/4 * (0.3 + math.sin(t * 0.3 + i) * 0.2)
                    local separation = math.min(1, (x - cutX) / PS(100))
                    local y = waveY + offset * separation + math.sin(t + time * 2 + i) * amp
                    gfx.line(x, waveY + offset * separation, x, y)
                end
            end
        end

        -- Draw scalpel
        local scalpelY = waveY - waveH/2 - PS(30) + math.sin(time * 8) * PS(5)
        gfx.set(0.8, 0.8, 0.9, 1)
        -- Blade
        gfx.line(cutX - PS(5), scalpelY, cutX, scalpelY + PS(60))
        gfx.line(cutX, scalpelY + PS(60), cutX + PS(5), scalpelY)
        -- Handle
        gfx.set(0.4, 0.3, 0.2, 1)
        gfx.rect(cutX - PS(8), scalpelY - PS(25), PS(16), PS(25), 1)

    elseif artGalleryState.currentArt == 5 then
        -- === THE SOUND GALAXY ===
        -- Stars orbiting a central sun, particles everywhere

        -- Draw background stars
        math.randomseed(42)  -- Fixed seed for consistent stars
        for i = 1, 100 do
            local sx = math.random() * w
            local sy = math.random() * h
            local twinkle = 0.3 + math.sin(time * 5 + i) * 0.3
            gfx.set(1, 1, 1, twinkle)
            gfx.circle(sx, sy, PS(1), 1, 1)
        end

        -- Central sun (the mix)
        local sunPulse = 1 + math.sin(time * 2) * 0.1
        -- Sun glow
        for r = PS(60), PS(30), -PS(5) do
            local alpha = (PS(60) - r) / PS(30) * 0.3
            gfx.set(1, 0.9, 0.5, alpha)
            gfx.circle(centerX, centerY, r * sunPulse, 1, 1)
        end
        gfx.set(1, 0.95, 0.7, 1)
        gfx.circle(centerX, centerY, PS(30) * sunPulse, 1, 1)

        -- Orbiting stem planets
        local orbits = {PS(100), PS(150), PS(200), PS(250)}
        local speeds = {0.8, 0.6, 0.4, 0.3}
        local labels = {"V", "D", "B", "O"}
        for i = 1, 4 do
            local angle = time * speeds[i] + (i - 1) * math.pi / 2
            local px = centerX + math.cos(angle) * orbits[i]
            local py = centerY + math.sin(angle) * orbits[i] * 0.6  -- Elliptical

            -- Orbit path
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.15)
            for a = 0, math.pi * 2, 0.1 do
                local ox = centerX + math.cos(a) * orbits[i]
                local oy = centerY + math.sin(a) * orbits[i] * 0.6
                gfx.circle(ox, oy, PS(1), 1, 1)
            end

            -- Planet glow
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.4)
            gfx.circle(px, py, PS(25), 1, 1)
            -- Planet
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.circle(px, py, PS(18), 1, 1)
            -- Label
            gfx.set(1, 1, 1, 1)
            gfx.setfont(1, "Arial", PS(14), string.byte('b'))
            local lw = gfx.measurestr(labels[i])
            gfx.x = px - lw/2
            gfx.y = py - PS(6)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 6 then
        -- === FREQUENCY WATERFALL ===
        -- Cascading frequency bands falling and separating

        local bandH = PS(30)
        local bandW = w - PS(100)
        local startX = PS(50)
        local labels = {"HIGH - Vocals", "MID-HIGH - Drums", "MID-LOW - Bass", "LOW - Other"}

        for i = 1, 4 do
            local baseY = PS(80) + (i - 1) * PS(100)
            local flowOffset = (time * 100 + i * 50) % bandW

            -- Draw flowing frequency band
            for x = 0, bandW do
                local xPos = startX + x
                local wavePhase = x / bandW * math.pi * 6 + time * 3
                local amp = bandH/2 * (0.5 + math.sin(wavePhase + i) * 0.3)
                local alpha = 0.3 + math.sin(wavePhase) * 0.2

                -- Waterfall effect - brighter at "current" position
                local distFromFlow = math.abs(x - flowOffset)
                if distFromFlow < PS(50) then
                    alpha = alpha + (1 - distFromFlow / PS(50)) * 0.5
                end

                gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], alpha)
                gfx.line(xPos, baseY - amp, xPos, baseY + amp)
            end

            -- Frequency label
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.setfont(1, "Arial", PS(11), string.byte('b'))
            gfx.x = startX + bandW + PS(10)
            gfx.y = baseY - PS(5)
            gfx.drawstr(labels[i])

            -- Droplets falling
            for d = 1, 5 do
                local dropX = startX + ((time * 80 + d * 100 + i * 30) % bandW)
                local dropY = baseY + (time * 50 + d * 20) % PS(80)
                local dropAlpha = 1 - (dropY - baseY) / PS(80)
                gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], dropAlpha * 0.6)
                gfx.circle(dropX, dropY, PS(3), 1, 1)
            end
        end

    elseif artGalleryState.currentArt == 7 then
        -- === THE DNA HELIX ===
        -- Double helix unraveling into 4 strands

        local helixLength = w - PS(150)
        local helixStartX = PS(75)
        local helixRadius = PS(40)

        -- Draw the double helix splitting into 4
        for x = 0, helixLength do
            local progress = x / helixLength
            local phase = x / PS(30) + time * 2
            local splitFactor = math.min(1, progress * 2)  -- Start splitting at 50%

            if progress < 0.5 then
                -- Before split - double helix
                local y1 = centerY + math.sin(phase) * helixRadius
                local y2 = centerY - math.sin(phase) * helixRadius
                local alpha = 0.5 + math.cos(phase) * 0.3

                gfx.set(0.8, 0.8, 0.8, alpha)
                gfx.circle(helixStartX + x, y1, PS(4), 1, 1)
                gfx.circle(helixStartX + x, y2, PS(4), 1, 1)

                -- Connection bars
                if math.floor(phase) % 2 == 0 then
                    gfx.set(0.6, 0.6, 0.6, 0.4)
                    gfx.line(helixStartX + x, y1, helixStartX + x, y2)
                end
            else
                -- After split - 4 strands separating
                for i = 1, 4 do
                    local separation = (progress - 0.5) * 2  -- 0 to 1
                    local targetOffset = (i - 2.5) * PS(50)
                    local yOffset = targetOffset * separation
                    local y = centerY + yOffset + math.sin(phase + i * 0.5) * helixRadius * (1 - separation * 0.5)
                    local alpha = 0.5 + math.cos(phase + i) * 0.3

                    gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], alpha)
                    gfx.circle(helixStartX + x, y, PS(4), 1, 1)
                end
            end
        end

        -- Labels at the end
        local labels = {"Vocals", "Drums", "Bass", "Other"}
        gfx.setfont(1, "Arial", PS(12), string.byte('b'))
        for i = 1, 4 do
            local yOffset = (i - 2.5) * PS(50)
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.x = helixStartX + helixLength + PS(15)
            gfx.y = centerY + yOffset - PS(6)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 8 then
        -- === PARTICLE STORM ===
        -- Thousands of particles sorting by color

        -- Particle system with sorting animation
        math.randomseed(12345)
        local numParticles = 200

        for p = 1, numParticles do
            local colorIdx = ((p - 1) % 4) + 1
            local baseX = math.random() * w
            local baseY = math.random() * h

            -- Calculate target position (sorted by stem)
            local targetX = PS(100) + (colorIdx - 1) * (w - PS(200)) / 3
            local targetY = PS(100) + math.random() * (h - PS(250))

            -- Interpolate based on time (cycling)
            local sortPhase = (math.sin(time * 0.5) + 1) / 2  -- 0 to 1 cycling
            local px = baseX + (targetX - baseX) * sortPhase
            local py = baseY + (targetY - baseY) * sortPhase

            -- Add some turbulence
            px = px + math.sin(time * 3 + p) * PS(10) * (1 - sortPhase)
            py = py + math.cos(time * 3 + p * 0.7) * PS(10) * (1 - sortPhase)

            -- Draw particle
            local alpha = 0.4 + math.sin(time * 5 + p) * 0.2
            gfx.set(stemColors[colorIdx][1], stemColors[colorIdx][2], stemColors[colorIdx][3], alpha)
            gfx.circle(px, py, PS(3), 1, 1)
        end

        -- Labels when sorted
        local labels = {"Vocals", "Drums", "Bass", "Other"}
        gfx.setfont(1, "Arial", PS(14), string.byte('b'))
        for i = 1, 4 do
            local labelX = PS(100) + (i - 1) * (w - PS(200)) / 3
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            local lw = gfx.measurestr(labels[i])
            gfx.x = labelX - lw/2
            gfx.y = h - PS(100)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 9 then
        -- === THE MIXING DESK ===
        -- Four animated faders rising from darkness

        local faderW = PS(60)
        local faderH = PS(250)
        local faderSpacing = (w - PS(200) - faderW * 4) / 3
        local startX = PS(100)
        local baseY = h - PS(120)

        local labels = {"VOC", "DRM", "BAS", "OTH"}
        local fullLabels = {"Vocals", "Drums", "Bass", "Other"}

        for i = 1, 4 do
            local faderX = startX + (i - 1) * (faderW + faderSpacing)

            -- Fader channel strip background
            gfx.set(0.15, 0.15, 0.18, 1)
            gfx.rect(faderX - PS(10), baseY - faderH - PS(40), faderW + PS(20), faderH + PS(80), 1)

            -- Fader track
            gfx.set(0.1, 0.1, 0.12, 1)
            gfx.rect(faderX + faderW/2 - PS(4), baseY - faderH, PS(8), faderH, 1)

            -- Animated fader level
            local level = 0.3 + math.sin(time * 2 + i * 0.8) * 0.3 + math.sin(time * 5 + i * 1.5) * 0.15
            local faderY = baseY - level * faderH

            -- Level meter (behind fader)
            local meterLevel = level + math.sin(time * 8 + i) * 0.1
            for y = baseY, baseY - meterLevel * faderH, -PS(3) do
                local meterProgress = (baseY - y) / faderH
                local r = stemColors[i][1] * (0.3 + meterProgress * 0.7)
                local g = stemColors[i][2] * (0.3 + meterProgress * 0.7)
                local b = stemColors[i][3] * (0.3 + meterProgress * 0.7)
                gfx.set(r, g, b, 0.8)
                gfx.rect(faderX + PS(5), y, faderW - PS(10), PS(2), 1)
            end

            -- Fader knob
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.rect(faderX, faderY - PS(10), faderW, PS(20), 1)
            gfx.set(1, 1, 1, 0.5)
            gfx.line(faderX + PS(5), faderY, faderX + faderW - PS(5), faderY)

            -- Channel label
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.setfont(1, "Arial", PS(12), string.byte('b'))
            local labelW = gfx.measurestr(labels[i])
            gfx.x = faderX + faderW/2 - labelW/2
            gfx.y = baseY + PS(15)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 10 then
        -- === STEM CONSTELLATION ===
        -- Stars connected forming STEM pattern

        -- Draw constellation background
        math.randomseed(999)
        for i = 1, 80 do
            local sx = math.random() * w
            local sy = math.random() * h
            local twinkle = 0.2 + math.sin(time * 4 + i * 0.5) * 0.2
            gfx.set(1, 1, 1, twinkle)
            gfx.circle(sx, sy, PS(1), 1, 1)
        end

        -- STEM constellation points
        local constellations = {
            -- S shape
            {points = {{0.15, 0.3}, {0.25, 0.25}, {0.15, 0.4}, {0.25, 0.55}, {0.15, 0.5}}, color = 1},
            -- T shape
            {points = {{0.35, 0.25}, {0.45, 0.25}, {0.55, 0.25}, {0.45, 0.35}, {0.45, 0.55}}, color = 2},
            -- E shape
            {points = {{0.65, 0.25}, {0.75, 0.25}, {0.65, 0.4}, {0.72, 0.4}, {0.65, 0.55}, {0.75, 0.55}}, color = 3},
            -- M shape
            {points = {{0.8, 0.55}, {0.8, 0.25}, {0.87, 0.4}, {0.94, 0.25}, {0.94, 0.55}}, color = 4},
        }

        for _, const in ipairs(constellations) do
            local color = stemColors[const.color]
            local points = const.points

            -- Draw connections
            gfx.set(color[1], color[2], color[3], 0.4)
            for i = 1, #points - 1 do
                local x1 = points[i][1] * w
                local y1 = points[i][2] * h
                local x2 = points[i+1][1] * w
                local y2 = points[i+1][2] * h
                gfx.line(x1, y1, x2, y2)
            end

            -- Draw stars with pulse
            for i, point in ipairs(points) do
                local px = point[1] * w
                local py = point[2] * h
                local pulse = 1 + math.sin(time * 3 + i + const.color) * 0.3

                -- Star glow
                gfx.set(color[1], color[2], color[3], 0.3 * pulse)
                gfx.circle(px, py, PS(12) * pulse, 1, 1)

                -- Star core
                gfx.set(color[1], color[2], color[3], 0.9)
                gfx.circle(px, py, PS(5) * pulse, 1, 1)

                -- Star center
                gfx.set(1, 1, 1, 1)
                gfx.circle(px, py, PS(2), 1, 1)
            end
        end

        -- Legend
        local labels = {"Vocals", "Drums", "Bass", "Other"}
        gfx.setfont(1, "Arial", PS(10))
        for i = 1, 4 do
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.circle(PS(30), h - PS(90) + (i-1) * PS(18), PS(5), 1, 1)
            gfx.x = PS(45)
            gfx.y = h - PS(95) + (i-1) * PS(18)
            gfx.drawstr(labels[i])
        end

    elseif artGalleryState.currentArt == 11 then
        -- === HARMONIC MANDALA ===
        -- Rotating sacred geometry with stem colors
        local rings = 8
        local segments = 12
        for ring = 1, rings do
            local ringRadius = (ring / rings) * math.min(w, h) * 0.4
            local col = stemColors[(ring % 4) + 1]
            local rotDir = ring % 2 == 0 and 1 or -1
            for seg = 0, segments - 1 do
                local angle = (seg / segments) * math.pi * 2 + time * 0.5 * rotDir + ring * 0.2
                local px, py = transform(centerX + math.cos(angle) * ringRadius, centerY + math.sin(angle) * ringRadius)
                -- Draw petal shape
                local petalSize = PS(15 + ring * 3)
                gfx.set(col[1], col[2], col[3], 0.3 + ring * 0.05)
                for inner = 0, petalSize, PS(2) do
                    local innerAngle = angle + math.sin(time * 2 + ring) * 0.2
                    local ix = px + math.cos(innerAngle) * inner
                    local iy = py + math.sin(innerAngle) * inner
                    gfx.circle(ix, iy, PS(3), 1, 1)
                end
            end
        end
        -- Center jewel
        for r = PS(40), PS(5), -PS(5) do
            local pulse = 1 + math.sin(time * 3) * 0.2
            gfx.set(1, 0.9, 0.7, 0.3 * pulse)
            local cx, cy = transform(centerX, centerY)
            gfx.circle(cx, cy, r * pulse, 1, 1)
        end

    elseif artGalleryState.currentArt == 12 then
        -- === THE STEM LOTUS ===
        -- Petals unfolding from center
        local numPetals = 16
        for layer = 3, 1, -1 do
            for p = 0, numPetals - 1 do
                local baseAngle = (p / numPetals) * math.pi * 2
                local openAmount = 0.5 + math.sin(time * 0.8 + layer * 0.5) * 0.3
                local angle = baseAngle + time * 0.1 * (layer % 2 == 0 and 1 or -1)
                local dist = PS(50 + layer * 40) * openAmount
                local col = stemColors[(p % 4) + 1]

                local px, py = transform(centerX + math.cos(angle) * dist, centerY + math.sin(angle) * dist * 0.7)
                local petalW = PS(30 + layer * 10)
                local petalH = PS(50 + layer * 15)

                gfx.set(col[1], col[2], col[3], 0.2 + layer * 0.15)
                -- Draw petal as ellipse points
                for t = 0, math.pi, 0.1 do
                    local ew = math.sin(t) * petalW
                    local eh = math.cos(t) * petalH * openAmount
                    local rx = px + math.cos(angle) * eh - math.sin(angle) * ew
                    local ry = py + math.sin(angle) * eh + math.cos(angle) * ew * 0.7
                    gfx.circle(rx, ry, PS(2), 1, 1)
                end
            end
        end
        -- Glowing center
        local cx, cy = transform(centerX, centerY)
        for r = PS(25), PS(5), -PS(3) do
            gfx.set(1, 0.95, 0.8, 0.15)
            gfx.circle(cx, cy, r * (1 + math.sin(time * 4) * 0.1), 1, 1)
        end

    elseif artGalleryState.currentArt == 13 then
        -- === AURORA BOREALIS ===
        -- Wavy curtains of colored light
        for layer = 1, 4 do
            local col = stemColors[layer]
            local yOffset = (layer - 2.5) * PS(60)
            for x = 0, w, PS(3) do
                local wave1 = math.sin((x / w) * 4 + time * 1.5 + layer) * PS(80)
                local wave2 = math.sin((x / w) * 7 - time * 0.8 + layer * 2) * PS(40)
                local wave3 = math.sin((x / w) * 2 + time * 0.5) * PS(30)
                local baseY = centerY + yOffset + wave1 + wave2 + wave3

                -- Vertical curtain effect
                for dy = 0, PS(150), PS(3) do
                    local alpha = (1 - dy / PS(150)) * 0.4
                    local shimmer = math.sin(time * 8 + x * 0.1 + dy * 0.05) * 0.1
                    gfx.set(col[1], col[2], col[3], alpha + shimmer)
                    gfx.rect(x, baseY + dy, PS(2), PS(2), 1)
                end
            end
        end
        -- Stars in background
        math.randomseed(777)
        for i = 1, 50 do
            local sx, sy = math.random() * w, math.random() * h * 0.6
            local twinkle = 0.3 + math.sin(time * 5 + i) * 0.2
            gfx.set(1, 1, 1, twinkle)
            gfx.circle(sx, sy, PS(1), 1, 1)
        end

    elseif artGalleryState.currentArt == 14 then
        -- === QUANTUM ENTANGLEMENT ===
        -- Four connected particles that move together
        local particles = {}
        for i = 1, 4 do
            local angle = (i - 1) * math.pi / 2 + time * 0.3
            local dist = PS(100) + math.sin(time * 2 + i) * PS(30)
            particles[i] = {
                x = centerX + math.cos(angle) * dist,
                y = centerY + math.sin(angle) * dist,
                col = stemColors[i]
            }
        end
        -- Draw quantum connections (wavy lines between all particles)
        for i = 1, 4 do
            for j = i + 1, 4 do
                local p1, p2 = particles[i], particles[j]
                for t = 0, 1, 0.02 do
                    local wave = math.sin(t * math.pi * 6 + time * 10) * PS(10)
                    local px = p1.x + (p2.x - p1.x) * t
                    local py = p1.y + (p2.y - p1.y) * t + wave
                    local tx, ty = transform(px, py)
                    local blend = t
                    gfx.set(
                        p1.col[1] * (1-blend) + p2.col[1] * blend,
                        p1.col[2] * (1-blend) + p2.col[2] * blend,
                        p1.col[3] * (1-blend) + p2.col[3] * blend,
                        0.4
                    )
                    gfx.circle(tx, ty, PS(2), 1, 1)
                end
            end
        end
        -- Draw particles with glow
        for i, p in ipairs(particles) do
            local px, py = transform(p.x, p.y)
            local pulse = 1 + math.sin(time * 5 + i) * 0.3
            for r = PS(25), PS(8), -PS(3) do
                gfx.set(p.col[1], p.col[2], p.col[3], 0.1 * pulse)
                gfx.circle(px, py, r, 1, 1)
            end
            gfx.set(1, 1, 1, 1)
            gfx.circle(px, py, PS(5), 1, 1)
        end

    elseif artGalleryState.currentArt == 15 then
        -- === THE SPIRAL TOWER ===
        -- Ascending spiral of stem colors
        local spiralLevels = 50
        local rotations = 4
        for level = 0, spiralLevels do
            local t = level / spiralLevels
            local angle = t * rotations * math.pi * 2 + time * 0.5
            local radius = PS(150) * (1 - t * 0.5)
            local yPos = centerY + PS(200) - t * PS(400)
            local col = stemColors[(level % 4) + 1]

            local px, py = transform(centerX + math.cos(angle) * radius, yPos)
            local blockSize = PS(20) * (1 - t * 0.5)

            gfx.set(col[1], col[2], col[3], 0.7 - t * 0.3)
            gfx.rect(px - blockSize/2, py - blockSize/2, blockSize, blockSize, 1)

            -- Connecting line to next
            if level < spiralLevels then
                local nextT = (level + 1) / spiralLevels
                local nextAngle = nextT * rotations * math.pi * 2 + time * 0.5
                local nextRadius = PS(150) * (1 - nextT * 0.5)
                local nextY = centerY + PS(200) - nextT * PS(400)
                local nx, ny = transform(centerX + math.cos(nextAngle) * nextRadius, nextY)
                gfx.set(col[1], col[2], col[3], 0.3)
                gfx.line(px, py, nx, ny)
            end
        end

    elseif artGalleryState.currentArt == 16 then
        -- === OCEAN OF WAVES ===
        -- Layered waves in stem colors
        for layer = 4, 1, -1 do
            local col = stemColors[layer]
            local baseY = centerY + (layer - 2.5) * PS(50)
            local amplitude = PS(40 + layer * 10)
            local frequency = 3 + layer * 0.5
            local speed = 1.5 - layer * 0.2

            -- Draw wave as filled area
            for x = 0, w, PS(2) do
                local waveY = baseY + math.sin((x / w) * frequency * math.pi + time * speed) * amplitude
                waveY = waveY + math.sin((x / w) * frequency * 2 * math.pi - time * speed * 0.7) * amplitude * 0.3

                local depth = h - waveY
                for dy = 0, math.min(depth, PS(200)), PS(3) do
                    local alpha = (1 - dy / PS(200)) * 0.3
                    gfx.set(col[1], col[2], col[3], alpha)
                    gfx.rect(x, waveY + dy, PS(2), PS(2), 1)
                end

                -- Wave crest highlight
                gfx.set(1, 1, 1, 0.3)
                gfx.rect(x, waveY - PS(2), PS(2), PS(3), 1)
            end
        end

    elseif artGalleryState.currentArt == 17 then
        -- === CRYSTALLINE MATRIX ===
        -- Geometric crystal formations
        local crystals = 20
        math.randomseed(42)
        for i = 1, crystals do
            local cx = math.random() * w * 0.8 + w * 0.1
            local cy = math.random() * h * 0.6 + h * 0.2
            local size = PS(20 + math.random() * 40)
            local col = stemColors[(i % 4) + 1]
            local rotation = time * 0.3 + i * 0.5

            local tx, ty = transform(cx, cy)

            -- Draw hexagonal crystal
            local sides = 6
            gfx.set(col[1], col[2], col[3], 0.4)
            local points = {}
            for s = 0, sides - 1 do
                local angle = rotation + (s / sides) * math.pi * 2
                table.insert(points, tx + math.cos(angle) * size)
                table.insert(points, ty + math.sin(angle) * size * 0.7)
            end
            for s = 1, sides do
                local next = (s % sides) + 1
                gfx.line(points[s*2-1], points[s*2], points[next*2-1], points[next*2])
                -- Inner lines to center
                gfx.set(col[1], col[2], col[3], 0.2)
                gfx.line(tx, ty, points[s*2-1], points[s*2])
            end
            -- Crystal core glow
            gfx.set(col[1], col[2], col[3], 0.3 + math.sin(time * 3 + i) * 0.1)
            gfx.circle(tx, ty, size * 0.3, 1, 1)
        end

    elseif artGalleryState.currentArt == 18 then
        -- === THE HEARTBEAT ===
        -- Pulsing heart-shaped waveform
        local pulse = math.abs(math.sin(time * 2))
        local heartScale = PS(100) * (1 + pulse * 0.3)

        -- Draw heart shape for each stem
        for layer = 4, 1, -1 do
            local col = stemColors[layer]
            local layerScale = heartScale * (1 + (layer - 2.5) * 0.1)
            local layerOffset = (layer - 2.5) * PS(5)

            gfx.set(col[1], col[2], col[3], 0.15 + layer * 0.1)
            -- Parametric heart
            for t = 0, math.pi * 2, 0.05 do
                local hx = 16 * math.sin(t)^3
                local hy = -(13 * math.cos(t) - 5 * math.cos(2*t) - 2 * math.cos(3*t) - math.cos(4*t))
                local px, py = transform(centerX + hx * layerScale / 16 + layerOffset, centerY + hy * layerScale / 16)
                gfx.circle(px, py, PS(3 + layer), 1, 1)
            end
        end

        -- ECG-style line across
        gfx.set(1, 0.3, 0.3, 0.8)
        local ecgY = h - PS(100)
        local beatPos = (time * 200) % w
        for x = 0, w, PS(2) do
            local y = ecgY
            local relX = (x - beatPos + w) % w
            if relX < PS(20) then
                y = ecgY - PS(30) * math.sin(relX / PS(20) * math.pi)
            elseif relX < PS(40) then
                y = ecgY + PS(50) * math.sin((relX - PS(20)) / PS(20) * math.pi)
            elseif relX < PS(60) then
                y = ecgY - PS(20) * math.sin((relX - PS(40)) / PS(20) * math.pi)
            end
            gfx.rect(x, y, PS(2), PS(2), 1)
        end

    elseif artGalleryState.currentArt == 19 then
        -- === STEM KALEIDOSCOPE ===
        -- Mirrored, rotating patterns
        local mirrors = 8
        local elements = 15
        for m = 0, mirrors - 1 do
            local mirrorAngle = (m / mirrors) * math.pi * 2
            for e = 1, elements do
                local dist = PS(30 + e * 15)
                local angle = time * 0.5 + e * 0.3 + mirrorAngle
                local col = stemColors[(e % 4) + 1]

                local px = centerX + math.cos(angle) * dist
                local py = centerY + math.sin(angle) * dist
                local tx, ty = transform(px, py)

                local size = PS(5 + e * 2)
                local shape = e % 3

                gfx.set(col[1], col[2], col[3], 0.4)
                if shape == 0 then
                    gfx.circle(tx, ty, size, 1, 1)
                elseif shape == 1 then
                    gfx.rect(tx - size/2, ty - size/2, size, size, 1)
                else
                    -- Triangle
                    for i = 0, 2 do
                        local a1 = angle + (i / 3) * math.pi * 2
                        local a2 = angle + ((i + 1) / 3) * math.pi * 2
                        gfx.line(tx + math.cos(a1) * size, ty + math.sin(a1) * size,
                                 tx + math.cos(a2) * size, ty + math.sin(a2) * size)
                    end
                end
            end
        end
        -- Center gem
        local cx, cy = transform(centerX, centerY)
        for i = 1, 4 do
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.5)
            local gemAngle = (i - 1) * math.pi / 2 + time
            gfx.circle(cx + math.cos(gemAngle) * PS(10), cy + math.sin(gemAngle) * PS(10), PS(8), 1, 1)
        end

    elseif artGalleryState.currentArt == 20 then
        -- === DIGITAL RAIN ===
        -- Matrix-style falling code in stem colors
        local columns = math.floor(w / PS(20))
        math.randomseed(123)
        for col = 0, columns do
            local colX = col * PS(20) + PS(10)
            local speed = 50 + math.random() * 100
            local offset = math.random() * 1000
            local stemCol = stemColors[(col % 4) + 1]

            local headY = ((time * speed + offset) % (h + PS(300))) - PS(100)

            -- Draw trail
            for i = 0, 20 do
                local charY = headY - i * PS(18)
                if charY > 0 and charY < h then
                    local alpha = 1 - (i / 20)
                    local char = string.char(48 + ((col * 7 + i * 3 + math.floor(time * 10)) % 74))

                    if i == 0 then
                        gfx.set(1, 1, 1, 1)  -- Bright head
                    else
                        gfx.set(stemCol[1], stemCol[2], stemCol[3], alpha * 0.8)
                    end

                    gfx.setfont(1, "Courier", PS(14))
                    gfx.x = colX
                    gfx.y = charY
                    gfx.drawstr(char)
                end
            end
        end
    end -- end of if false (disabled old art code)

        -- Gallery is now fullscreen with no overlays
        -- The art title is displayed by the procedural art generator itself
        -- Mouse controls: left-click=new art, scroll=zoom, drag=pan, double-click=reset

    elseif helpState.currentTab == 1 then
        -- === WELCOME TAB - FULL WINDOW EXPERIENCE + AUDIO REACTIVE ===
        local welcomeTokens = (UI_TOKENS and UI_TOKENS.welcome) or {}
        local welcomeSpacing = welcomeTokens.spacing or {}
        local welcomeFonts = welcomeTokens.fonts or {}

        UI_BACKGROUNDS.drawWelcomeBackground({
            w = w,
            h = h,
            contentY = contentY,
            contentH = contentH,
            textOffsetY = textOffsetY,
            stemColors = stemColors,
            PS = PS,
            helpStartTime = helpState.startTime,
            updateAudioReactivity = updateAudioReactivity,
            audioReactive = audioReactive,
            SETTINGS = SETTINGS,
        })

        -- === TEXT CONTENT (drawn AFTER background) ===

        -- Large animated STEMwerk title (replaces old "STEMperator" typography)
        do
            local fontSize = PS(welcomeFonts.title or 44)
            local titleW = measureStemwerkLogo(fontSize, "Arial", true)
            local titleX = (w - titleW) / 2 + textOffsetX
            local titleY = contentY + PS(welcomeSpacing.titleTop or 12)
            drawWavingStemwerkLogo({
                x = titleX,
                y = titleY,
                fontSize = fontSize,
                time = os.clock(),
                amp = PS(2),
                speed = 3,
                phase = 0.2,
                alphaStem = 1.0,
                alphaRest = 1.0,
                fontName = "Arial",
                bold = true,
            })
        end

        -- Subtitle
        gfx.setfont(1, "Arial", PS(welcomeFonts.subtitle or 16))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local welcomeSub = T("help_welcome_sub")
        local wsW = gfx.measurestr(welcomeSub)
        gfx.x = (w - wsW) / 2 + textOffsetX
        gfx.y = contentY + PS(welcomeSpacing.subtitleTop or 60)
        gfx.drawstr(welcomeSub)

        -- Divider line
        gfx.set(0.4, 0.4, 0.5, 0.5)
        gfx.line(
            w * (welcomeSpacing.dividerXStartFactor or 0.2) + textOffsetX,
            contentY + PS(welcomeSpacing.dividerTop or 85),
            w * (welcomeSpacing.dividerXEndFactor or 0.8) + textOffsetX,
            contentY + PS(welcomeSpacing.dividerTop or 85)
        )

        -- Features list - LARGER and more descriptive
        local features = {
            {icon = "♪", color = stemColors[1], title = T("help_feature_vocals"), desc = T("help_feature_vocals_desc")},
            {icon = "●", color = stemColors[2], title = T("help_feature_drums"), desc = T("help_feature_drums_desc")},
            {icon = "≡", color = stemColors[3], title = T("help_feature_bass"), desc = T("help_feature_bass_desc")},
            {icon = "✦", color = stemColors[4], title = T("help_feature_other"), desc = T("help_feature_other_desc")},
        }
        local featureY = contentY + PS(welcomeSpacing.featuresTop or 100)
        local featureSpacing = PS(welcomeSpacing.featureSpacing or 50)
        local leftCol = PS(welcomeSpacing.leftCol or 40) + textOffsetX

        for i, feat in ipairs(features) do
            -- Colored icon/badge
            gfx.set(feat.color[1], feat.color[2], feat.color[3], 0.9)
            gfx.circle(
                leftCol + PS(welcomeSpacing.badgeOffsetX or 15),
                featureY + PS(welcomeSpacing.badgeOffsetY or 12),
                PS(welcomeSpacing.badgeRadius or 18),
                1,
                1
            )

            -- Feature title (theme-aware)
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            gfx.setfont(1, "Arial", PS(welcomeFonts.featureTitle or 16), string.byte('b'))
            gfx.x = leftCol + PS(welcomeSpacing.featureTextOffsetX or 45)
            gfx.y = featureY
            gfx.drawstr(feat.title)

            -- Feature description (theme-aware)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.9)
            gfx.setfont(1, "Arial", PS(welcomeFonts.featureDesc or 13))
            gfx.x = leftCol + PS(welcomeSpacing.featureTextOffsetX or 45)
            gfx.y = featureY + PS(welcomeSpacing.featureDescOffsetY or 22)
            gfx.drawstr(feat.desc)

            featureY = featureY + featureSpacing
        end

        -- Version removed from Welcome (requested).

    elseif helpState.currentTab == 2 then
        -- === QUICK START TAB + AUDIO REACTIVE ===
        local helpLayoutTokens = (UI_TOKENS and UI_TOKENS.helpLayout) or {}

        local quickStartAudio = UI_BACKGROUNDS.drawQuickStartBackground({
            w = w,
            h = h,
            contentY = contentY,
            contentH = contentH,
            time = time,
            PS = PS,
            UI = UI,
            stemColors = stemColors,
            helpStartTime = helpState.startTime,
            updateAudioReactivity = updateAudioReactivity,
            audioReactive = audioReactive,
            drawProceduralArtInternal = drawProceduralArtInternal,
            SETTINGS = SETTINGS,
        })
        local audioPeak = quickStartAudio.audioPeak or 0

        UI_BACKGROUNDS.handleStandardHelpBackgroundClick({
            mouseDown = mouseDown,
            wasMouseDown = helpState.wasMouseDown,
            mx = mx,
            my = my,
            clickStartX = helpState.clickStartX,
            clickStartY = helpState.clickStartY,
            h = h,
            UI = UI,
            PS = PS,
            onGenerateArt = generateNewArt,
        })

        drawHelpQuickStartHeader(w, contentY, textOffsetX, PS)

        local quickStartFrame = UI_HELP_LAYOUT.computeContentFrame({
            tokens = helpLayoutTokens,
            S = PS,
            w = w,
            h = h,
            contentY = contentY,
            textOffsetX = textOffsetX,
        })
        local panelX = quickStartFrame.x
        local panelY = quickStartFrame.y
        local panelH = quickStartFrame.h

        -- Steps - LARGER with more detail (all translated)
        local steps = {
            {num = "1", title = T("help_step1_title"), desc = T("help_step1_desc"),
             detail = T("help_step1_detail")},
            {num = "2", title = T("help_step2_title"), desc = T("help_step2_desc"),
             detail = T("help_step2_detail")},
            {num = "3", title = T("help_step3_title"), desc = T("help_step3_desc"),
             detail = T("help_step3_detail")},
        }
        local stepY = panelY + PS(20)
        local stepSpacing = (panelH - PS(40)) / 3

        for i, step in ipairs(steps) do
            -- Step number circle
            local circleX = panelX + PS(40)
            local circleR = PS(22)
            local circleY = stepY + PS(18)

            -- Glow effect behind circle
            for r = circleR + PS(6), circleR, -PS(2) do
                gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 0.15 + audioPeak * 0.2)
                gfx.circle(circleX, circleY, r, 1, 1)
            end

            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
            gfx.circle(circleX, circleY, circleR, 1, 1)
            gfx.set(1, 1, 1, 1) -- White number
            gfx.setfont(1, "Arial", PS(18), string.byte('b'))
            local numW, numH = gfx.measurestr(step.num)
            gfx.x = circleX - numW / 2
            gfx.y = circleY - numH / 2
            gfx.drawstr(step.num)

            -- Step title (high contrast)
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            gfx.setfont(1, "Arial", PS(16), string.byte('b'))
            gfx.x = circleX + circleR + PS(20)
            gfx.y = circleY - PS(18)
            gfx.drawstr(step.title)

            -- Step description (forced contrast)
            gfx.setfont(1, "Arial", PS(13))
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = circleX + circleR + PS(20)
            gfx.y = circleY + PS(4)
            gfx.drawstr(step.desc)

            stepY = stepY + stepSpacing
        end

        -- Pro tip at bottom (blinking text)
        local proTipText = T("help_pro_tip")
        gfx.setfont(1, "Arial", PS(13), string.byte('b'))
        local blink = 0.6 + math.sin(time * 4) * 0.4
        if SETTINGS.darkMode then
            gfx.set(stemColors[4][1], stemColors[4][2], stemColors[4][3], blink)
        else
            gfx.set(stemColors[4][1] * 0.7, stemColors[4][2] * 0.7, stemColors[4][3] * 0.7, 0.9)
        end
        local ptW = gfx.measurestr(proTipText)
        gfx.x = (w - ptW) / 2 + textOffsetX
        gfx.y = panelY + panelH - PS(30)
        gfx.drawstr(proTipText)

    elseif helpState.currentTab == 3 then
        -- === STEMS TAB - COMPREHENSIVE STEM INFO ===
        local helpLayoutTokens = (UI_TOKENS and UI_TOKENS.helpLayout) or {}
        -- Subtle procedural art background (aligned with standard Help tabs)
        UI_BACKGROUNDS.drawStandardHelpBackground({
            w = w,
            h = h,
            time = time,
            UI = UI,
            drawProceduralArt = drawProceduralArt,
            SETTINGS = SETTINGS,
        })

        UI_BACKGROUNDS.handleStandardHelpBackgroundClick({
            mouseDown = mouseDown,
            wasMouseDown = helpState.wasMouseDown,
            mx = mx,
            my = my,
            clickStartX = helpState.clickStartX,
            clickStartY = helpState.clickStartY,
            h = h,
            UI = UI,
            PS = PS,
            onGenerateArt = generateNewArt,
        })

        local stemTitle = T("help_stems_title")
        local subText = T("help_stems_sub")
        local stemsHeader = UI_HELP_LAYOUT.computeHeaderLayout({
            tokens = helpLayoutTokens,
            S = PS,
            w = w,
            contentY = contentY,
            textOffsetX = textOffsetX,
            title = stemTitle,
            subtitle = subText,
        })

        -- Title (theme-aware)
        gfx.setfont(1, "Arial", stemsHeader.titleFont, string.byte('b'))
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = stemsHeader.titleX
        gfx.y = stemsHeader.titleY
        gfx.drawstr(stemTitle)

        -- Subtitle (translated, theme-aware)
        gfx.setfont(1, "Arial", stemsHeader.subtitleFont)
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        gfx.x = stemsHeader.subtitleX
        gfx.y = stemsHeader.subtitleY
        gfx.drawstr(subText)

        local stemsFrame = UI_HELP_LAYOUT.computeContentFrame({
            tokens = helpLayoutTokens,
            S = PS,
            w = w,
            h = h,
            contentY = contentY,
            textOffsetX = textOffsetX,
        })
        local stemsBody = UI_HELP_LAYOUT.computeBodyColumn({
            tokens = helpLayoutTokens,
            S = PS,
            frame = stemsFrame,
            bodyWrapWidth = helpLayoutTokens.stemsBodyWrapWidth or helpLayoutTokens.bodyWrapWidth,
        })
        local cardX = stemsBody.x
        local cardCenterX = cardX + PS(35)
        local textX = cardX + PS(70)

        -- Stem explanations - All translated
        local stems = {
            {name = T("stem_vocals"), color = stemColors[1], desc = T("help_stem_vocals_desc"),
             uses = T("help_stem_vocals_uses")},
            {name = T("stem_drums"), color = stemColors[2], desc = T("help_stem_drums_desc"),
             uses = T("help_stem_drums_uses")},
            {name = T("stem_bass"), color = stemColors[3], desc = T("help_stem_bass_desc"),
             uses = T("help_stem_bass_uses")},
            {name = T("stem_other"), color = stemColors[4], desc = T("help_stem_other_desc"),
             uses = T("help_stem_other_uses")},
        }

        local stemY = stemsFrame.y
        local cardH = PS(65)
        local cardGap = PS(10)

        for i, stem in ipairs(stems) do
            -- Color accent bar on left (no card background)
            gfx.set(stem.color[1], stem.color[2], stem.color[3], 1)
            gfx.rect(cardX, stemY, PS(8), cardH, 1)

            -- Stem icon circle
            gfx.set(stem.color[1], stem.color[2], stem.color[3], 0.9)
            gfx.circle(cardCenterX, stemY + cardH/2, PS(20), 1, 1)

            -- Letter in circle (always white for contrast on colored circle)
            gfx.set(1, 1, 1, 1)
            gfx.setfont(1, "Arial", PS(16), string.byte('b'))
            local letter = stem.name:sub(1, 1)
            local lW = gfx.measurestr(letter)
            gfx.x = cardCenterX - lW/2
            gfx.y = stemY + cardH/2 - PS(9)
            gfx.drawstr(letter)

            -- Stem name - darker in light mode for readability
            if SETTINGS.darkMode then
                gfx.set(stem.color[1], stem.color[2], stem.color[3], 1)
            else
                gfx.set(stem.color[1] * 0.7, stem.color[2] * 0.7, stem.color[3] * 0.7, 1)
            end
            gfx.setfont(1, "Arial", PS(18), string.byte('b'))
            gfx.x = textX
            gfx.y = stemY + PS(8)
            gfx.drawstr(stem.name)

            -- Contains description (theme-aware)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.setfont(1, "Arial", PS(12))
            gfx.x = textX
            gfx.y = stemY + PS(28)
            gfx.drawstr(stem.desc)

            -- Use cases (if space) (theme-aware)
            if contentH > PS(350) then
                gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.9)
                gfx.setfont(1, "Arial", PS(10))
                gfx.x = textX
                gfx.y = stemY + PS(45)
                gfx.drawstr(stem.uses)
            end

            stemY = stemY + cardH + cardGap
        end

        -- 6-stem model note (translated, better styled)
        if contentH > PS(400) then
            local stemsCenterX = stemsBody.x + stemsBody.w / 2
            -- Blinking indicator
            local blink6 = 0.7 + math.sin(time * 3) * 0.3
            gfx.setfont(1, "Arial", PS(13), string.byte('b'))
            gfx.set(stemColors[4][1], stemColors[4][2], stemColors[4][3], blink6)
            local model6Title = T("help_6stem_title")
            local m6W = gfx.measurestr(model6Title)
            gfx.x = stemsCenterX - m6W / 2
            gfx.y = stemY + PS(10)
            gfx.drawstr(model6Title)

            gfx.setfont(1, "Arial", PS(11))
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            local model6Desc = T("help_6stem_desc")
            local m6dW = gfx.measurestr(model6Desc)
            gfx.x = stemsCenterX - m6dW / 2
            gfx.y = stemY + PS(28)
            gfx.drawstr(model6Desc)
        end

    elseif helpState.currentTab == 4 then
        -- === REAPER FILES TAB ===
        local helpLayoutTokens = (UI_TOKENS and UI_TOKENS.helpLayout) or {}

        -- Subtle procedural art background (gated by FX toggle)
        UI_BACKGROUNDS.drawStandardHelpBackground({
            w = w,
            h = h,
            time = time,
            UI = UI,
            drawProceduralArt = drawProceduralArt,
            SETTINGS = SETTINGS,
        })

        -- Click for new art (same area rules as Gallery)
        if not mouseDown and helpState.wasMouseDown then
            local tabAreaBottom = UI(40)
            local closeBtnTop = h - UI(50)
            local startY = helpState.clickStartY or my
            if startY > tabAreaBottom and startY < closeBtnTop then
                local dx = mx - (helpState.clickStartX or mx)
                local dy = my - (helpState.clickStartY or my)
                local dragThreshold = PS(6)
                if (dx * dx + dy * dy) <= (dragThreshold * dragThreshold) then
                    generateNewArt()
                end
            end
        end

        drawHelpReaperHeader(w, contentY, textOffsetX, PS)

        local reaperFrame = UI_HELP_LAYOUT.computeContentFrame({
            tokens = helpLayoutTokens,
            S = PS,
            w = w,
            h = h,
            contentY = contentY,
            textOffsetX = textOffsetX,
        })
        local panelX = reaperFrame.x
        local panelY = reaperFrame.y

        local bodyColumn = UI_HELP_LAYOUT.computeBodyColumn({
            tokens = helpLayoutTokens,
            S = PS,
            frame = reaperFrame,
            bodyWrapWidth = helpLayoutTokens.reaperBodyWrapWidth or helpLayoutTokens.bodyWrapWidth,
        })
        local sectionX = bodyColumn.x
        local sectionY = panelY + PS(helpLayoutTokens.panelInnerPadding or 15)
        local maxW = bodyColumn.w
        local sectionGap = PS(helpLayoutTokens.sectionGap or 12)

        local function drawHelpSection(titleKey, bodyKey)
            local title = T(titleKey)
            local body = T(bodyKey)
            gfx.setfont(1, "Arial", PS(16), string.byte('b'))
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            gfx.x = sectionX
            gfx.y = sectionY
            gfx.drawstr(title)
            sectionY = sectionY + PS(20)

            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.setfont(1, "Arial", PS(12))
            local lines = _wrapTextToWidth(body or "", maxW)
            for _, ln in ipairs(lines) do
                gfx.x = sectionX
                gfx.y = sectionY
                gfx.drawstr(ln)
                sectionY = sectionY + PS(16)
            end
            sectionY = sectionY + sectionGap
        end

        drawHelpSection("help_reaper_selection_title", "help_reaper_selection_body")
        drawHelpSection("help_reaper_temp_title", "help_reaper_temp_body")
        drawHelpSection("help_reaper_logs_title", "help_reaper_logs_body")
        drawHelpSection("help_reaper_cleanup_title", "help_reaper_cleanup_body")

    elseif helpState.currentTab == 6 then
        -- === ABOUT TAB ===
        local aboutTokens = (UI_TOKENS and UI_TOKENS.about) or {}
        local aboutSpacing = aboutTokens.spacing or {}
        local aboutPadding = aboutTokens.padding or {}
        local aboutFonts = aboutTokens.fonts or {}
        -- Fullscreen procedural art background with zoom/pan (like Gallery)
        local tabAreaH = UI(aboutSpacing.tabAreaHeight or 40)

        -- Define art display area (below tabs)
        local artX = 0
        local artY = tabAreaH
        local artW = w
        local artH = h - tabAreaH - UI(aboutSpacing.artBottomReserve or 50)  -- Leave room for close button

        -- Apply zoom and pan to art area (fly-through effect!)
        local zoomedW = artW * zoom
        local zoomedH = artH * zoom
        local zoomedX = artX - (zoomedW - artW) / 2 + panX
        local zoomedY = artY - (zoomedH - artH) / 2 + panY

        -- Draw the procedural art with zoom and rotation
        drawProceduralArt(zoomedX, zoomedY, zoomedW, zoomedH, time, helpState.rotation, true)

        -- Readability overlay removed (requested): avoid large rectangular "panel" look.

        -- Content
        local centerX = w / 2 + textOffsetX
        local contentY = tabAreaH + PS(aboutSpacing.contentTop or 30) + textOffsetY

        -- Title (big animated STEMwerk)
        do
            local fontSize = PS(aboutFonts.title or 34)
            local titleW = measureStemwerkLogo(fontSize, "Arial", true)
            local titleX = centerX - titleW / 2
            local titleY = contentY
            drawWavingStemwerkLogo({
                x = titleX,
                y = titleY,
                fontSize = fontSize,
                time = os.clock(),
                amp = PS(2),
                speed = 3,
                phase = 0.2,
                alphaStem = 1.0,
                alphaRest = 1.0,
                fontName = "Arial",
                bold = true,
            })
        end

        contentY = contentY + PS(aboutSpacing.titleToSubtitleGap or 36)

        -- Subtitle
        gfx.setfont(1, "Arial", PS(aboutFonts.subtitle or 12))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local subtitle = T("about_subtitle")
        local subW = gfx.measurestr(subtitle)
        gfx.x = centerX - subW / 2
        gfx.y = contentY
        gfx.drawstr(subtitle)

        contentY = contentY + PS(aboutSpacing.subtitleToFeaturesGap or 24)
        -- Give the tab title/subtitle area a bit more breathing room before "Features".
        contentY = contentY + PS(aboutSpacing.preFeaturesGap or 10)

        -- (Credits moved to bottom corners - see after content section)

        -- Two-column information layout (Features + Support).
        local leftColX = math.floor(w * 0.08)
        local rightColX = math.floor(w * 0.55)
        local colW = math.max(PS(180), math.floor(w * 0.38))
        local rightColMaxW = math.max(PS(170), w - rightColX - math.floor(w * 0.08))
        colW = math.min(colW, rightColMaxW)
        local leftY = contentY
        local rightY = contentY
        local creditY = h - UI(aboutSpacing.creditsBottom or 18)
        local contentBottom = creditY - PS(24)

        local headingSize = PS(aboutFonts.featuresTitle or 12)
        local bodySize = PS(aboutFonts.feature or 10)
        local rowGap = PS(aboutSpacing.featureRowGap or 16)
        local sectionGap = PS(aboutSpacing.featuresTitleToListGap or 20)

        -- Left column: Features
        do
            gfx.setfont(1, "Arial", headingSize, string.byte('b'))
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            local featuresTitle = T("about_features_title")
            gfx.x = leftColX
            gfx.y = leftY
            gfx.drawstr(featuresTitle)
            leftY = leftY + sectionGap

            gfx.setfont(1, "Arial", bodySize)
            local features = {
                {color = stemColors[1], text = T("about_feature_1")},
                {color = stemColors[2], text = T("about_feature_2")},
                {color = stemColors[3], text = T("about_feature_3")},
                {color = stemColors[4], text = T("about_feature_4")},
                {color = stemColors[5], text = T("about_feature_5")},
            }
            local bullet = "●"
            local bulletW = gfx.measurestr(bullet)
            local bulletGap = PS(aboutSpacing.featureBulletGap or 10)
            local textW = math.max(PS(120), colW - bulletW - bulletGap)

            for _, feat in ipairs(features) do
                local wrapped = _wrapTextToWidth(feat.text or "", textW)
                for i, ln in ipairs(wrapped) do
                    if leftY + rowGap > contentBottom then
                        break
                    end
                    if i == 1 then
                        gfx.set(feat.color[1], feat.color[2], feat.color[3], 0.8)
                        gfx.x = leftColX
                        gfx.y = leftY
                        gfx.drawstr(bullet)
                    end
                    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
                    gfx.x = leftColX + bulletW + bulletGap
                    gfx.y = leftY
                    gfx.drawstr(ln)
                    leftY = leftY + rowGap
                end
            end
        end

        -- Right column: Support
        do
            gfx.setfont(1, "Arial", headingSize, string.byte('b'))
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            local supportTitle = T("help_native_support") or "Support"
            gfx.x = rightColX
            gfx.y = rightY
            gfx.drawstr(supportTitle)
            rightY = rightY + sectionGap

            gfx.setfont(1, "Arial", bodySize)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            local supportLines = {
                T("help_native_support_intro") or "If setup or processing fails:",
                "- " .. (T("help_native_support_use_bundle") or "Use Save Support Bundle."),
                "- " .. (T("help_native_support_no_payloads") or "Do not send audio, project, or model files unless asked."),
                "- " .. (T("help_native_support_context") or "Include your OS, REAPER version, selected model/device, and what you tried."),
            }
            for _, line in ipairs(supportLines) do
                local wrapped = _wrapTextToWidth(tostring(line), colW)
                for _, ln in ipairs(wrapped) do
                    if rightY + rowGap > contentBottom then
                        break
                    end
                    gfx.x = rightColX
                    gfx.y = rightY
                    gfx.drawstr(ln)
                    rightY = rightY + rowGap
                end
            end
        end

        contentY = math.max(leftY, rightY) + PS(aboutSpacing.featuresToCreditsGap or 20)

        -- (Tip removed; replaced by tooltip on the help hint icon)

        -- Bottom credits (left/right corners)
        do
            -- Place credits flush at the very bottom edge of the window.
            local creditY = h - UI(aboutSpacing.creditsBottom or 18)
            gfx.setfont(1, "Arial", UI(aboutFonts.credits or 10))

            -- Left: Conceived by flarkAUDIO
            local conceivedBy = (T("about_conceived") or "by") .. " "
            gfx.x = UI(aboutPadding.creditsLeft or 6)
            gfx.y = creditY
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.85)
            gfx.drawstr(conceivedBy)
            local prefixW = gfx.measurestr(conceivedBy)
            gfx.x = UI(aboutPadding.creditsLeft or 6) + prefixW
            gfx.y = creditY
            gfx.set(1.0, 0.5, 0.3, 0.95)  -- flark orange
            gfx.drawstr("flarkAUDIO")

            -- Right: Powered by Meta's Demucs
            local poweredBy = (T("about_powered_by") or "Powered by") .. " "
            local demucsName = (T("about_demucs") or "Meta's Demucs")
            gfx.setfont(1, "Arial", UI(aboutFonts.credits or 10))
            local poweredW = gfx.measurestr(poweredBy)
            local demucsW = gfx.measurestr(demucsName)
            local totalW = poweredW + demucsW
            local x0 = w - totalW - UI(aboutPadding.creditsRight or 12)
            gfx.x = x0
            gfx.y = creditY
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.85)
            gfx.drawstr(poweredBy)
            gfx.x = x0 + poweredW
            gfx.y = creditY
            gfx.set(0.3, 0.7, 1.0, 0.95)  -- Meta blue
            gfx.drawstr(demucsName)
        end

        -- Click on art generates new art
        if not mouseDown and helpState.wasMouseDown and not helpState.wasDrag then
            local tabAreaBottom = UI(aboutSpacing.tabAreaHeight or 40)
            local closeBtnTop = h - UI(aboutSpacing.artBottomReserve or 50)
            if helpState.clickStartY > tabAreaBottom and helpState.clickStartY < closeBtnTop then
                generateNewArt()
            end
        end
    end
    -- End of tab content

    -- === CLOSE BUTTON (uses UI() - does NOT zoom) ===
    local btnW = UI(70)
    local btnH = UI(24)
    local btnX = (w - btnW) / 2
    local btnY = h - UI(32)
    local closeHover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    local backR, backG, backB = THEME.button[1], THEME.button[2], THEME.button[3]
    if closeHover then
        backR, backG, backB = THEME.buttonHover[1], THEME.buttonHover[2], THEME.buttonHover[3]
    end
    drawGlossyPill(btnX, btnY, btnW, btnH, backR, backG, backB, controlsOpacity)
    gfx.setfont(1, "Arial", UI(11), string.byte('b'))
    local closeText = T("back")
    local closeTextW = gfx.measurestr(closeText)
    local backX = btnX + (btnW - closeTextW) / 2
    local backY = btnY + (btnH - gfx.texth) / 2
    gfx.set(0, 0, 0, 0.4 * controlsOpacity)
    gfx.x, gfx.y = backX + 2, backY + 2; gfx.drawstr(closeText)
    gfx.set(0, 0, 0, 0.6 * controlsOpacity)
    gfx.x, gfx.y = backX + 1, backY + 1; gfx.drawstr(closeText)
    gfx.x, gfx.y = backX - 1, backY + 1; gfx.drawstr(closeText)
    gfx.x, gfx.y = backX + 1, backY - 1; gfx.drawstr(closeText)
    gfx.x, gfx.y = backX - 1, backY - 1; gfx.drawstr(closeText)
    gfx.set(1, 1, 1, 1 * controlsOpacity)
    gfx.x, gfx.y = backX, backY
    gfx.drawstr(closeText)

    -- Close button tooltip
    if closeHover and controlsOpacity > 0.3 then
        tooltipText = T("tooltip_help_close")
        tooltipX, tooltipY = mx + UI(10), my - UI(25)
    end

    -- === HELP HINT ICON (all tabs) ===
    do
        local hintSize = UI(18)
        local hintX = UI(14)
        local hintY = btnY + (btnH - hintSize) / 2
        -- On About, place the hint slightly above the Back button (credits live at the very bottom).
        if helpState.currentTab == 6 then
            local aboutTokens = (UI_TOKENS and UI_TOKENS.about) or {}
            local aboutSpacing = aboutTokens.spacing or {}
            hintY = btnY - UI(aboutSpacing.hintLiftAboveBack or 22)
        end
        local hintHover = mx >= hintX and mx <= hintX + hintSize and my >= hintY and my <= hintY + hintSize

        gfx.set(0.25, 0.25, 0.28, (hintHover and 0.9 or 0.7) * controlsOpacity)
        gfx.circle(hintX + hintSize / 2, hintY + hintSize / 2, hintSize / 2, 1, 1)
        gfx.set(1, 1, 1, 0.95 * controlsOpacity)
        gfx.setfont(1, "Arial", UI(11), string.byte('b'))
        gfx.x = hintX + UI(6)
        gfx.y = hintY + UI(2)
        gfx.drawstr("?")

        if hintHover and controlsOpacity > 0.3 then
            if helpState.currentTab == 5 then
                tooltipText = T("help_gallery_controls_tip")
            else
                tooltipText = T("help_text_controls_tip")
            end
            tooltipX, tooltipY = mx + UI(10), my - UI(25)
        end
    end

    -- === DRAW TOOLTIP (always on top, with STEM colors) ===
    if tooltipText then
        gfx.setfont(1, "Arial", UI(11))
        local padding = UI(8)
        local lineH = UI(14)
        local maxTextW = math.min(w * 0.62, UI(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    gfx.update()

    -- Helper to reset camera when changing art
    local function resetCamera()
        helpState.targetZoom = 1.0
        helpState.targetPanX = 0
        helpState.targetPanY = 0
    end

    -- Handle clicks
    if mouseDown and not helpState.wasMouseDown then
        -- Double-click detection
        local now = os.clock()
        local isDoubleClick = helpState.lastClickTime and (now - helpState.lastClickTime) < 0.3
        helpState.lastClickTime = now

        if clickedTab then
            helpState.currentTab = clickedTab
            resetCamera()
            resetTextView()
            -- Do NOT generate new art when switching tabs
        elseif closeHover and controlsOpacity > 0.3 then
            return "close"
        elseif isDoubleClick and not helpState.wasDrag then
            -- Double-click anywhere resets zoom/pan (only if not dragging)
            if helpState.currentTab == 5 then
                resetCamera()
            else
                resetTextView()
            end
        end
    end
    helpState.wasMouseDown = mouseDown
    helpState.wasRightMouseDown = rightMouseDown

    -- Keyboard navigation
    local char = gfx.getchar()
    if char == -1 or char == 27 then  -- Window closed or ESC
        return "close"
    elseif char == 13 then  -- Enter key = start STEMwerk
        return "start"
    elseif helpState.currentTab == 5 then
        -- Art gallery tab navigation
        if char == 114 or char == 82 then  -- R key to reset camera
            resetCamera()
        elseif char == 32 then  -- Space for new art
            generateNewArt()
            -- Note: Pan and zoom are preserved when switching art
        end
    end
    -- Tab switching with left/right arrow keys
    if char == 1818584692 then  -- Left arrow
        helpState.currentTab = helpState.currentTab - 1
        if helpState.currentTab < 1 then helpState.currentTab = 6 end
        resetCamera()
        resetTextView()
    elseif char == 1919379572 then  -- Right arrow
        helpState.currentTab = helpState.currentTab + 1
        if helpState.currentTab > 6 then helpState.currentTab = 1 end
        resetCamera()
        resetTextView()
    end

    return nil
end

-- Forward declarations for functions defined later
local showStemSelectionDialog
local captureWindowGeometry

local rememberDialogGeometryFromRect = WINDOW.rememberDialogGeometryFromRect
local updateDialogPosFromGfx = WINDOW.updateDialogPosFromGfx
captureWindowGeometry = WINDOW.captureWindowGeometry

local function captureHelpWindowGeometry(currentTitle)
    -- On macOS, prefer gfx/dock-based geometry capture. JS_Window rects can
    -- disagree with gfx.init() expectations (client vs frame/origin mismatch),
    -- which causes visible jumps when switching Main <-> Help.
    if OS == "macOS" then
        if captureWindowGeometry(currentTitle) then return true end
        return captureWindowGeometry(WINDOW_ART_GALLERY)
    end

    if helpState.hwnd and reaper.JS_Window_GetRect then
        local ok, left, top, right, bottom = reaper.JS_Window_GetRect(helpState.hwnd)
        if ok then
            return rememberDialogGeometryFromRect(left, top, right, bottom)
        end
    end

    if captureWindowGeometry(currentTitle) then return true end
    return captureWindowGeometry(WINDOW_ART_GALLERY)
end

-- Art Gallery window loop
local function artGalleryLoop()
    -- Update window title based on current tab
    local tabTitles = {
        "STEMwerk - " .. T("help_welcome"),
        "STEMwerk - " .. T("help_quickstart"),
        "STEMwerk - " .. T("help_stems"),
        "STEMwerk - " .. T("help_reaper"),
        "STEMwerk - " .. T("help_gallery"),
        "STEMwerk - " .. T("help_about")
    }
    local currentTitle = tabTitles[helpState.currentTab] or "STEMwerk Help"

    -- Save window position/size continuously and update title
    if OS ~= "macOS" and reaper.JS_Window_GetRect then
        local hwnd = helpState.hwnd
        if (not hwnd) and reaper.JS_Window_Find then
            -- Title changes dynamically; find by current title first, then by stable prefix.
            hwnd = reaper.JS_Window_Find(currentTitle, true)
                or reaper.JS_Window_Find("STEMwerk -", false)
                or reaper.JS_Window_Find(WINDOW_ART_GALLERY, true)
        end
        if hwnd then
            helpState.hwnd = hwnd
            local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if ok then
                rememberDialogGeometryFromRect(left, top, right, bottom)
            end
            -- Update window title dynamically
            if reaper.JS_Window_SetTitle then
                reaper.JS_Window_SetTitle(hwnd, currentTitle)
            end
        end
    end

    local result = drawArtGallery()
    if result == "close" then
        captureHelpWindowGeometry(currentTitle)
        -- Save settings before closing
        saveSettings()
        gfx.quit()
        helpState.hwnd = nil
        -- Save where we came from before resetting
        local cameFromDialog = (helpState.openedFrom == "dialog")
        local cameFromMonitor = (helpState.openedFrom == "monitor")
        -- Reset help state for next time
        helpState.currentTab = 1  -- Start at Welcome tab next time
        helpState.openedFrom = "start"
        -- Return to where help was opened from
        if cameFromDialog then
            -- Came from main dialog - go back to main dialog
            reaper.defer(function() showStemSelectionDialog() end)
        elseif cameFromMonitor then
            reaper.defer(function()
                local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
                showMessage(promptTitle, promptMessage, "info", true)
            end)
        else
            -- Came from start screen - go back to main (which checks for selection)
            reaper.defer(function() main() end)
        end
        return
    elseif result == "start" then
        -- Enter key pressed - close help and start STEMwerk
        captureHelpWindowGeometry(currentTitle)
        saveSettings()
        gfx.quit()
        helpState.hwnd = nil
        -- Reset help state for next time
        helpState.currentTab = 1  -- Start at Welcome tab next time
        helpState.openedFrom = "start"
        -- Go to main which will show dialog or start workflow
        reaper.defer(function() main() end)
        return
    end
    reaper.defer(artGalleryLoop)
end

-- Show Art Gallery
local function showArtGallery()
    loadSettings()
    updateTheme()

    artGalleryState.currentArt = 1
    artGalleryState.wasMouseDown = false
    artGalleryState.wasRightMouseDown = false
    artGalleryState.startTime = os.clock()
    -- Reset camera
    artGalleryState.zoom = 1.0
    artGalleryState.panX = 0
    artGalleryState.panY = 0
    artGalleryState.targetZoom = 1.0
    artGalleryState.targetPanX = 0
    artGalleryState.targetPanY = 0
    artGalleryState.isDragging = false
    artGalleryState.lastMouseWheel = 0

    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    gfx.init(WINDOW_ART_GALLERY, winW, winH, 0, winX, winY)
    helpState.hwnd = nil
    if reaper.JS_Window_Find then
        helpState.hwnd = reaper.JS_Window_Find(WINDOW_ART_GALLERY, true)
    end
    if OS == "Windows" then
        artGalleryLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(artGalleryLoop)
    end
end

-- Draw message window (replaces reaper.MB for proper positioning)
-- Styled to match main app window
local function drawMessageWindow()
    local w, h = gfx.w, gfx.h

    -- Calculate scale based on window size
    local scale = math.min(w / 380, h / 340)
    scale = math.max(0.5, math.min(4.0, scale))
    local function PS(val) return math.floor(val * scale + 0.5) end

    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local mouseWheel = gfx.mouse_wheel

    -- STEM colors
    local stemColors = {
        {255/255, 100/255, 100/255},  -- S = Vocals (red)
        {100/255, 200/255, 255/255},  -- T = Drums (blue)
        {150/255, 100/255, 255/255},  -- E = Bass (purple)
        {100/255, 255/255, 150/255},  -- M = Other (green)
    }

    -- Initialize procedural art if needed
    if proceduralArt.seed == 0 then
        generateNewArt()
    end

    -- Update animation time
    proceduralArt.time = proceduralArt.time + 0.016

    -- Initialize art state for mouse controls
    if not messageWindowState.artZoom then
        messageWindowState.artZoom = 1.0
        messageWindowState.artPanX = 0
        messageWindowState.artPanY = 0
        messageWindowState.artRotation = 0
        messageWindowState.lastMX = mx
        messageWindowState.lastMY = my
        messageWindowState.wasDragging = false
    end

    -- Mouse wheel zoom
    if mouseWheel ~= 0 then
        local zoomDelta = mouseWheel / 1200
        messageWindowState.artZoom = math.max(0.3, math.min(3.0, messageWindowState.artZoom + zoomDelta))
        gfx.mouse_wheel = 0
    end

    -- Right mouse drag = rotation
    if rightMouseDown then
        local dx = mx - (messageWindowState.lastMX or mx)
        messageWindowState.artRotation = (messageWindowState.artRotation or 0) + dx * 0.01
        messageWindowState.wasDragging = true
    end

    -- Left mouse drag = pan (only in lower area to not interfere with buttons)
    if mouseDown and my > h * 0.3 then
        local dx = mx - (messageWindowState.lastMX or mx)
        local dy = my - (messageWindowState.lastMY or my)
        if math.abs(dx) > 1 or math.abs(dy) > 1 then
            messageWindowState.artPanX = (messageWindowState.artPanX or 0) + dx
            messageWindowState.artPanY = (messageWindowState.artPanY or 0) + dy
            messageWindowState.wasDragging = true
        end
    end

    messageWindowState.lastMX = mx
    messageWindowState.lastMY = my

    local _msgUtility = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local _isErrorMode = (messageWindowState.icon == "error")
    local bundleHover = false

    -- Background
    gfx.set(THEME.bg[1], THEME.bg[2], THEME.bg[3], 1)
    gfx.rect(0, 0, w, h, 1)

    if not _msgUtility then
        -- Draw procedural art background with zoom/pan/rotation
        local artX = messageWindowState.artPanX or 0
        local artY = messageWindowState.artPanY or 0
        local artZoom = messageWindowState.artZoom or 1.0
        local artRot = messageWindowState.artRotation or 0

        local zoomedW = w * artZoom
        local zoomedH = h * artZoom
        local drawX = (w - zoomedW) / 2 + artX
        local drawY = (h - zoomedH) / 2 + artY

        drawProceduralArt(drawX, drawY, zoomedW, zoomedH, proceduralArt.time, artRot, true)

        -- Semi-transparent overlay for UI readability
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, 0.6)
        else
            gfx.set(1, 1, 1, 0.6)
        end
        gfx.rect(0, 0, w, h, 1)
    end

    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0

    local function setTooltip(x, y, ww, hh, text)
        if not text or text == "" then return false end
        if mx >= x and mx <= x + ww and my >= y and my <= y + hh then
            tooltipText = text
            tooltipX = mx + PS(10)
            tooltipY = my + PS(15)
            return true
        end
        return false
    end

    -- Top-right controls
    local iconScale = 0.66
    local themeSize = math.max(PS(12), math.floor(PS(20) * iconScale + 0.5))
    local themeX = w - themeSize - PS(10)
    local themeY = PS(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = _msgUtility and 1.0 or updateControlsOpacity(messageWindowState, mouseInControls)

    local langW = PS(22)
    local langH = PS(14)
    local langX = themeX - langW - PS(6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH
    local fxHover = false

    if _msgUtility then
        local _uc = {
            S = PS, w = w, mx = mx, my = my,
            mouseDown = mouseDown,
            rightMouseDown = rightMouseDown,
            state = messageWindowState,
            setLanguageFn = setLanguage,
            themeX = themeX, themeY = themeY, themeSize = themeSize,
        }
        UI_CONTROLS.drawUtilityControls(_uc)
        if _uc.tooltipText then
            tooltipText = _uc.tooltipText
            tooltipX = _uc.tooltipX
            tooltipY = _uc.tooltipY
        end
    else
        if SETTINGS.darkMode then
            gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.6) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
            gfx.set(0, 0, 0, 1 * controlsOpacity)
            gfx.circle(themeX + themeSize/2 + 4, themeY + themeSize/2 - 3, themeSize/2 - 3, 1, 1)
        else
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/3, 1, 1)
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
            for i = 0, 7 do
                local angle = i * math.pi / 4
                local x1 = themeX + themeSize/2 + math.cos(angle) * (themeSize/3 + 2)
                local y1 = themeY + themeSize/2 + math.sin(angle) * (themeSize/3 + 2)
                local x2 = themeX + themeSize/2 + math.cos(angle) * (themeSize/2 - 1)
                local y2 = themeY + themeSize/2 + math.sin(angle) * (themeSize/2 - 1)
                gfx.line(x1, y1, x2, y2)
            end
        end
        if themeHover and rightMouseDown and not (messageWindowState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            cycleThemePreset()
        end
        if themeHover and mouseDown and not messageWindowState.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local langCode = string.upper(SETTINGS.language or "EN")
        local langTextW = gfx.measurestr(langCode)
        if langHover then
            gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
        else
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
        end
        gfx.x = langX + (langW - langTextW) / 2
        gfx.y = langY
        gfx.drawstr(langCode)
        if langHover and rightMouseDown and not (messageWindowState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            SETTINGS.tooltips = not SETTINGS.tooltips
            saveSettings()
        end
        if langHover and mouseDown and not messageWindowState.wasMouseDown and controlsOpacity > 0.3 then
            local langs = {"en", "nl", "de"}
            local currentIdx = 1
            for i, l in ipairs(langs) do if l == SETTINGS.language then currentIdx = i break end end
            setLanguage(langs[(currentIdx % #langs) + 1])
            saveSettings()
        end
        local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
        local fxX = themeX + (themeSize - fxSize) / 2
        local fxY = themeY + themeSize + PS(3)
        fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)
        local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
        if SETTINGS.visualFX then
            gfx.set(0.4, 0.9, 0.5, fxAlpha)
        else
            gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6)
        end
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2
        gfx.y = fxY + PS(1)
        gfx.drawstr(fxText)
        if SETTINGS.visualFX then
            gfx.set(1, 1, 0.5, fxAlpha * 0.8)
            gfx.circle(fxX - PS(1), fxY + PS(2), PS(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - PS(2), PS(1.5), 1, 1)
        else
            gfx.set(0.8, 0.3, 0.3, fxAlpha)
            gfx.line(fxX - PS(1), fxY + fxSize / 2, fxX + fxSize + PS(1), fxY + fxSize / 2)
        end
        if fxHover and mouseDown and not messageWindowState.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.visualFX = not SETTINGS.visualFX
            saveSettings()
        end
        if fxHover and rightMouseDown and not (messageWindowState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            SETTINGS.themePreset = "reaper_native"
            updateTheme()
            saveSettings()
        end
    end

    -- Track tooltip
    if not _msgUtility then
        if (not _msgUtility) and themeHover and controlsOpacity > 0.3 then
            tooltipText = getThemeToggleTooltip()
            tooltipX = mx + PS(10)
            tooltipY = my + PS(15)
        elseif langHover and controlsOpacity > 0.3 then
            tooltipText = T("tooltip_lang")
            tooltipX = mx + PS(10)
            tooltipY = my + PS(15)
        elseif fxHover and controlsOpacity > 0.3 then
            local fxTip = SETTINGS.visualFX and (T("fx_disable") or "Disable visual effects") or (T("fx_enable") or "Enable visual effects")
            tooltipText = fxTip .. " " .. (T("fx_switch_native_suffix") or "Right-click: switch to REAPER Native UI.")
            tooltipX = mx + PS(10)
            tooltipY = my + PS(15)
        end
    end

    local time = os.clock() - messageWindowState.startTime

    -- === STEMwerk Logo (large, centered, ABOVE waveform) ===
    drawWavingStemwerkLogo({
        w = w,
        y = PS(35),
        fontSize = PS(28),
        time = time,
        amp = PS(2),
        speed = 3,
        phase = 0.5,
        alphaStem = 1,
        alphaRest = 0.9,
    })

    -- === Tagline (ABOVE waveform) ===
    gfx.setfont(1, "Arial", PS(11))
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local tagline = "STEM Separation"
    local tagW = gfx.measurestr(tagline)
    gfx.x = (w - tagW) / 2
    gfx.y = PS(68)
    gfx.drawstr(tagline)

    if not _msgUtility then
        -- === Animated waveform visualization (BELOW tagline) ===
        local waveY = PS(95)
        local waveH = PS(50)
        local waveW = w - PS(60)
        local waveX = PS(30)

        for stemIdx = 1, 4 do
            local color = stemColors[stemIdx]
            gfx.set(color[1], color[2], color[3], 0.4)

            local freq = 2 + stemIdx * 0.7
            local amp = waveH / 4 * (1 - (stemIdx - 1) * 0.15)
            local phase = time * 2 + stemIdx * 1.5

            local prevX, prevY
            for i = 0, waveW do
                local x = waveX + i
                local t = i / waveW * math.pi * freq + phase
                local y = waveY + waveH/2 + math.sin(t) * amp * math.sin(i / waveW * math.pi)
                if prevX then gfx.line(prevX, prevY, x, y) end
                prevX, prevY = x, y
            end
        end
    end

    -- === Message ===
    gfx.setfont(1, "Arial", PS(14), string.byte('b'))

    local r, g, b, pulseAlpha
    if _msgUtility then
        r, g, b = THEME.textDim[1], THEME.textDim[2], THEME.textDim[3]
        pulseAlpha = 1
    else
        pulseAlpha = 0.6 + math.sin(time * 3) * 0.4
        local colorPhase = (time * 0.5) % 4
        local colorIdx = math.floor(colorPhase) + 1
        local nextColorIdx = (colorIdx % 4) + 1
        local colorBlend = colorPhase % 1
        r = stemColors[colorIdx][1] * (1 - colorBlend) + stemColors[nextColorIdx][1] * colorBlend
        g = stemColors[colorIdx][2] * (1 - colorBlend) + stemColors[nextColorIdx][2] * colorBlend
        b = stemColors[colorIdx][3] * (1 - colorBlend) + stemColors[nextColorIdx][3] * colorBlend
    end

    gfx.set(r, g, b, pulseAlpha)

    local msg = tostring(messageWindowState.message or T("select_audio") or "")
    local msgMaxW = math.min(w - PS(70), PS(480))
    local msgLines = _wrapTextToWidth(msg, msgMaxW)
    if #msgLines == 0 then msgLines = { msg } end
    local msgLineH = gfx.texth + PS(4)
    local msgTopY = PS(210)
    local widestMsgW = 0
    for _, line in ipairs(msgLines) do
        widestMsgW = math.max(widestMsgW, gfx.measurestr(line))
    end
    local msgBlockW = math.min(msgMaxW, widestMsgW)
    local msgX = (w - msgBlockW) / 2
    local msgBottomY = msgTopY
    for idx, line in ipairs(msgLines) do
        local lineW = gfx.measurestr(line)
        gfx.x = (w - lineW) / 2
        gfx.y = msgTopY + (idx - 1) * msgLineH
        gfx.drawstr(line)
        msgBottomY = gfx.y + gfx.texth
    end

    -- Tooltip for message area
    local msgHover = mx >= msgX and mx <= msgX + msgBlockW and my >= msgTopY and my <= msgBottomY
    if msgHover and not tooltipText then
        tooltipText = T("select_audio_tooltip")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    end

    -- Subtle underline (animated in normal mode, static separator in utility mode)
    if not _msgUtility then
        local underlineW = msgBlockW * (0.5 + math.sin(time * 2) * 0.3)
        local underlineX = (w - underlineW) / 2
        gfx.set(r, g, b, pulseAlpha * 0.5)
        gfx.line(underlineX, msgBottomY + PS(6), underlineX + underlineW, msgBottomY + PS(6))
    end

    -- Shared button dimensions for consistency
    local btnW = PS(70)
    local btnH = PS(20)
    local btnSpacing = PS(10)
    local totalBtnsW = btnW * 2 + btnSpacing
    local btnY = h - PS(40)

    if _isErrorMode then
        local bundleText = T("save_support_bundle") or "Save Support Bundle"
        local bundleBtnW = totalBtnsW
        local bundleBtnH = btnH
        local bundleBtnX = (w - bundleBtnW) / 2
        local bundleBtnY = btnY - bundleBtnH - PS(8)
        bundleHover = mx >= bundleBtnX and mx <= bundleBtnX + bundleBtnW
            and my >= bundleBtnY and my <= bundleBtnY + bundleBtnH
        local bR = bundleHover and THEME.buttonPrimaryHover[1] or THEME.buttonPrimary[1]
        local bG = bundleHover and THEME.buttonPrimaryHover[2] or THEME.buttonPrimary[2]
        local bB = bundleHover and THEME.buttonPrimaryHover[3] or THEME.buttonPrimary[3]
        drawGlossyPill(bundleBtnX, bundleBtnY, bundleBtnW, bundleBtnH, bR, bG, bB)
        gfx.setfont(1, "Arial", PS(13), string.byte('b'))
        local bTw = gfx.measurestr(bundleText)
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = bundleBtnX + (bundleBtnW - bTw) / 2
        gfx.y = bundleBtnY + (bundleBtnH - gfx.texth) / 2
        gfx.drawstr(bundleText)
        setTooltip(bundleBtnX, bundleBtnY, bundleBtnW, bundleBtnH, T("save_support_bundle_tooltip"))
        if bundleHover and (gfx.mouse_cap & 1 == 1) and not messageWindowState.wasMouseDown then
            reaper.defer(function()
                dofile(script_path .. "STEMwerk_Save_Support_Bundle.lua")
            end)
        end
    end

    -- Help button (left)
    local helpBtnX = (w - totalBtnsW) / 2
    local helpHover = mx >= helpBtnX and mx <= helpBtnX + btnW and my >= btnY and my <= btnY + btnH

    if _msgUtility then
        local hR = helpHover and THEME.buttonPrimaryHover[1] or THEME.buttonPrimary[1]
        local hG = helpHover and THEME.buttonPrimaryHover[2] or THEME.buttonPrimary[2]
        local hB = helpHover and THEME.buttonPrimaryHover[3] or THEME.buttonPrimary[3]
        drawGlossyPill(helpBtnX, btnY, btnW, btnH, hR, hG, hB)
    else
        if helpHover then gfx.set(0.3, 0.5, 0.8, 1) else gfx.set(0.2, 0.4, 0.7, 0.9) end
        for i = 0, btnH - 1 do
            local radius = btnH / 2
            local inset = 0
            if i < radius then
                inset = radius - math.sqrt(math.max(0, radius * radius - (radius - i) * (radius - i)))
            elseif i > btnH - radius then
                inset = radius - math.sqrt(math.max(0, radius * radius - (i - (btnH - radius)) * (i - (btnH - radius))))
            end
            gfx.line(helpBtnX + inset, btnY + i, helpBtnX + btnW - inset, btnY + i)
        end
    end
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(13), string.byte('b'))
    local helpText = T("help")
    local helpTextW = gfx.measurestr(helpText)
    gfx.x = helpBtnX + (btnW - helpTextW) / 2
    gfx.y = btnY + (btnH - gfx.texth) / 2
    if _msgUtility then gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1) end
    gfx.drawstr(helpText)

    if helpHover and not tooltipText then
        tooltipText = T("help_tooltip")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    end

    -- Close button (red, right)
    local btnX = helpBtnX + btnW + btnSpacing
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    local closeR = hover and 0.9 or 0.72
    local closeG = hover and 0.3 or 0.20
    local closeB = hover and 0.3 or 0.20
    if _msgUtility then
        drawGlossyPill(btnX, btnY, btnW, btnH, closeR, closeG, closeB)
    else
        gfx.set(closeR, closeG, closeB, 1)
        for i = 0, btnH - 1 do
            local radius = btnH / 2
            local inset = 0
            if i < radius then
                inset = radius - math.sqrt(radius * radius - (radius - i) * (radius - i))
            elseif i > btnH - radius then
                inset = radius - math.sqrt(radius * radius - (i - (btnH - radius)) * (i - (btnH - radius)))
            end
            gfx.line(btnX + inset, btnY + i, btnX + btnW - inset, btnY + i)
        end
    end

    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(13), string.byte('b'))
    local closeText = T("close")
    local closeW = gfx.measurestr(closeText)
    gfx.x = btnX + (btnW - closeW) / 2
    gfx.y = btnY + (btnH - gfx.texth) / 2
    gfx.drawstr(closeText)

    if hover and not tooltipText then
        tooltipText = T("exit_tooltip")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    end

    -- Hint at very bottom edge (different hint for monitoring mode)
    gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
    gfx.setfont(1, "Arial", PS(9))
    local hint
    if messageWindowState.monitorSelection then
        hint = T("hint_monitor")
    else
        hint = T("hint_keys")
    end
    local hintW = gfx.measurestr(hint)
    gfx.x = (w - hintW) / 2
    gfx.y = h - PS(12)
    gfx.drawstr(hint)

    -- flarkAUDIO logo at top (translucent) - skipped in utility mode
    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
        gfx.setfont(1, "Arial", PS(10))
        local flarkPart = "flark"
        local flarkPartW = gfx.measurestr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        local audioPart = "AUDIO"
        local audioPartW = gfx.measurestr(audioPart)
        local totalLogoW = flarkPartW + audioPartW
        local logoStartX = (w - totalLogoW) / 2
        gfx.set(1.0, 0.5, 0.1, 0.5)
        gfx.setfont(1, "Arial", PS(10))
        gfx.x = logoStartX
        gfx.y = PS(3)
        gfx.drawstr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        gfx.x = logoStartX + flarkPartW
        gfx.y = PS(3)
        gfx.drawstr(audioPart)
    end

    -- Draw tooltip if active (with STEM colors)
    if tooltipText then
        gfx.setfont(1, "Arial", PS(11))
        local padding = PS(8)
        local lineH = PS(14)
        local maxTextW = math.min(w * 0.62, PS(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    gfx.update()

    -- Handle clicks
    if mouseDown and not messageWindowState.wasMouseDown then
        if helpHover then
            return "artgallery"
        elseif hover then
            return "close"
        end
    end

    local clickedBackground = (not mouseDown)
        and messageWindowState.wasMouseDown
        and not (messageWindowState.wasDragging or false)
        and not helpHover
        and not hover
        and not themeHover
        and not langHover
        and not fxHover
    if clickedBackground then
        generateNewArt()
        messageWindowState.artZoom = 1.0
        messageWindowState.artPanX = 0
        messageWindowState.artPanY = 0
        messageWindowState.artRotation = 0
    end

    messageWindowState.wasMouseDown = mouseDown
    messageWindowState.wasRightMouseDown = rightMouseDown
    if not mouseDown and not rightMouseDown then
        messageWindowState.wasDragging = false
    end

    local char = gfx.getchar()

    -- If window is closed (char == -1), exit
    if char == -1 then
        return "close"
    end

    -- ESC always closes
    if char == 27 then
        return "close"
    end

    -- F1 opens art gallery
    if char == 26161 then
        return "artgallery"
    end

    -- Space = generate new animation (like in Gallery)
    if char == 32 then
        generateNewArt()
        -- Reset art view
        messageWindowState.artZoom = 1.0
        messageWindowState.artPanX = 0
        messageWindowState.artPanY = 0
        messageWindowState.artRotation = 0
        return nil
    end

    -- Enter only closes if NOT in selection monitoring mode
    -- (In monitoring mode, user should select audio first, not just press Enter)
    if not messageWindowState.monitorSelection then
        if char == 13 then
            return "close"
        end
    end

    return nil
end

-- Check if there's any valid selection for processing
local function hasAnySelection()
    return HELPERS.getSelectionMonitorState().actionable
end

-- Message window loop
local function messageWindowLoop()
    local loopNow = uiNow()
    local nextFrameAt = messageWindowState.nextFrameAt or 0
    if loopNow < nextFrameAt then
        reaper.defer(messageWindowLoop)
        return
    end
    messageWindowState.nextFrameAt = loopNow + pacingFrameInterval("messageFrameInterval", "messageFrameIntervalFx")

    -- Save window position for next time
    -- On macOS, avoid JS_Window_GetRect for live position updates because its
    -- frame-origin coordinates can drift from gfx.init client expectations.
    if OS ~= "macOS" and reaper.JS_Window_Find then
        local hwnd = reaper.JS_Window_Find(SCRIPT_NAME, true)
        if hwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if retval then
                rememberDialogGeometryFromRect(left, top, right, bottom)
            end
        end
    end

    -- If monitoring for selection, check if user made a selection
    -- But DON'T transition while user is still dragging (mouse button held)
    -- This prevents stealing focus while user is making a time selection
    local hasSel = false
    if messageWindowState.monitorSelection then
        if loopNow >= (messageWindowState.nextSelectionCheckAt or 0) then
            messageWindowState.nextSelectionCheckAt = loopNow + (UI_PACING.messageSelectionCheckInterval or 0.25)
            local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
            messageWindowState.title = promptTitle or "Start"
            messageWindowState.message = promptMessage or "Select audio in REAPER"
            messageWindowState.icon = "info"
            hasSel = hasAnySelection()
            messageWindowState.cachedHasSelection = hasSel
        else
            hasSel = messageWindowState.cachedHasSelection and true or false
        end
    end

    if messageWindowState.monitorSelection and hasSel then
        -- Check if mouse button is currently held down (user still dragging)
        local mouseState = reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) or 0
        local mouseHeld = (mouseState & 1) == 1  -- Left mouse button

        if not mouseHeld then
            -- Mouse released, safe to transition
            -- Save window position/size before transitioning
            captureWindowGeometry("STEMwerk")
            saveSettings()
            gfx.quit()
            messageWindowState.onClose = nil
            messageWindowState.monitorSelection = false
            -- Open the main dialog directly. Re-entering main() adds extra window
            -- checks and can cause visible flashing / delays on some systems.
            reaper.defer(function()
                skipExistingWindowCheckOnce = true
                showStemSelectionDialog()
            end)
            return
        end
        -- If mouse is held, don't transition yet - keep monitoring
    end

    local result = drawMessageWindow()
    if result == "close" then
        local onClose = messageWindowState.onClose
        -- Save window position/size before closing
        captureWindowGeometry("STEMwerk")
        saveSettings()
        gfx.quit()
        messageWindowState.onClose = nil
        messageWindowState.monitorSelection = false
        if messageWindowState.monitorSelection then
            local mainHwnd = reaper.GetMainHwnd()
            if mainHwnd and reaper.JS_Window_SetFocus then
                reaper.JS_Window_SetFocus(mainHwnd)
            end
        end
        if onClose then
            reaper.defer(onClose)
        end
        return
    elseif result == "artgallery" then
        -- Save window position/size before switching to art gallery
        local cameFromMonitor = messageWindowState.monitorSelection and true or false
        captureWindowGeometry("STEMwerk")
        saveSettings()
        gfx.quit()
        messageWindowState.onClose = nil
        messageWindowState.monitorSelection = false
        -- Open Art Gallery - remember whether we came from selection monitoring or a plain start screen
        helpState.openedFrom = cameFromMonitor and "monitor" or "start"
        showArtGallery()
        return
    end
    reaper.defer(messageWindowLoop)
end

-- Show a styled message window (replacement for reaper.MB)
showMessage = MESSAGES.showMessage

-- Scaling helper: converts base coordinates to current scale
local function S(val)
    return math.floor(val * GUI.scale + 0.5)
end

-- Calculate current scale based on window size
local function updateScale()
    -- Use a single reference base dimension so scale doesn't subtly change
    -- when resizing only one axis (e.g. making the window taller).
    local base = math.max(GUI.baseW, GUI.baseH)
    local scaleW = gfx.w / base
    local scaleH = gfx.h / base
    GUI.scale = math.min(scaleW, scaleH)
    -- Clamp scale (1.0 to 4.0)
    GUI.scale = math.max(1.0, math.min(4.0, GUI.scale))
end

-- Track if we've made window resizable
local windowResizableSet = false
local missingJsWindowStyleApiWarnings = {}

local function warnMissingJsWindowStyleApi(context)
    if missingJsWindowStyleApiWarnings[context] then return end
    missingJsWindowStyleApiWarnings[context] = true
    debugLog("WARNING: js_ReaScriptAPI window style functions unavailable; skipping " .. tostring(context))
end

-- Make window resizable using JS_ReaScriptAPI (if available)
local function makeWindowResizable()
    if windowResizableSet then return true end
    if not reaper.JS_Window_Find then return false end
    if not reaper.JS_Window_GetLong or not reaper.JS_Window_SetLong then
        warnMissingJsWindowStyleApi("main window resize setup")
        return false
    end

    -- Find the gfx window
    local hwnd = reaper.JS_Window_Find(SCRIPT_NAME, true)
    if not hwnd then return false end

    -- On Linux/X11, use different approach - set window hints
    if OS == "Linux" then
        -- For Linux, we need to modify GDK window properties
        -- js_ReaScriptAPI doesn't directly support this, but we can try
        local style = reaper.JS_Window_GetLong(hwnd, "STYLE")
        if style then
            -- Try to add resize style bits
            reaper.JS_Window_SetLong(hwnd, "STYLE", style | 0x00040000 | 0x00010000)
        end
    else
        -- Windows: add WS_THICKFRAME and WS_MAXIMIZEBOX
        local style = reaper.JS_Window_GetLong(hwnd, "STYLE")
        if not style then return false end
        local WS_THICKFRAME = 0x00040000
        local WS_MAXIMIZEBOX = 0x00010000
        reaper.JS_Window_SetLong(hwnd, "STYLE", style | WS_THICKFRAME | WS_MAXIMIZEBOX)
    end

    windowResizableSet = true
    return true
end

-- Tooltip helper: set tooltip if mouse is in area
local function setTooltip(x, y, w, h, text)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx >= x and mx <= x + w and my >= y and my <= y + h then
        GUI.tooltip = text
        GUI.tooltipX = mx + S(10)
        GUI.tooltipY = my + S(15)
    end
end

-- Set a rich tooltip for STEMwerk button with colored output stems and target
local function setRichTooltip(x, y, w, h)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx >= x and mx <= x + w and my >= y and my <= y + h then
        GUI.richTooltip = true
        GUI.tooltipX = mx + S(10)
        GUI.tooltipY = my + S(15)
    end
end

-- Set a tooltip with keyboard shortcut highlighted in color
-- shortcut: the key (e.g. "K", "V", "1")
-- color: RGB table for the shortcut color (e.g. {255, 100, 100})
local function setTooltipWithShortcut(x, y, w, h, text, shortcut, color)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx >= x and mx <= x + w and my >= y and my <= y + h then
        GUI.shortcutTooltip = {
            text = text,
            shortcut = shortcut,
            color = color or {255, 200, 100}  -- Default orange/yellow
        }
        GUI.tooltipX = mx + S(10)
        GUI.tooltipY = my + S(15)
    end
end

-- Draw the current tooltip (call at end of frame)
local function drawTooltip()
    return UI_DRAW.drawTooltip()
end

local function fitTextToBox(text, availableW, baseFontSize, minFontSize)
    return UI_DRAW.fitTextToBox(text, availableW, baseFontSize, minFontSize)
end

function isModelLoadingStage(stage)
    if not stage or stage == "" then return false end
    local s = tostring(stage):lower()
    return s:find("loading", 1, true) ~= nil and s:find("model", 1, true) ~= nil
end

function drawModelLoadNoteBox(x, y, w, h, mx, my)
    if not w or w <= 20 then return false end

    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h
    local bg = THEME.inputBg or {0.12, 0.12, 0.14}
    local border = THEME.border or {0.35, 0.35, 0.4}
    local accent = THEME.accent or {0.35, 0.65, 0.95}
    local textColor = THEME.textDim or THEME.text or {0.85, 0.85, 0.9}
    local radius = getThemeRadius(S, 6, math.floor(math.min(w, h) / 2))
    local borderWeight = getThemeBorderWeight(S, 1)

    drawThemeSurfaceBox(x, y, w, h, bg, border, hover and 0.96 or 0.88, hover and 1 or 0.85, radius, borderWeight, 0.8, "card")

    gfx.set(accent[1], accent[2], accent[3], 0.9)
    drawRoundedFill(x + borderWeight, y + borderWeight, math.max(borderWeight + 1, math.floor(h * 0.16)), math.max(1, h - borderWeight * 2), math.max(0, radius - borderWeight))

    local fontSize = math.max(8, math.floor(h * 0.5))
    gfx.setfont(1, "Arial", fontSize)
    local label = T("model_load_note") or "First model load can take longer. Later runs are usually faster."
    local fitted, _, usedFontSize = fitTextToBox(label, w - 14, fontSize, 8)

    gfx.setfont(1, "Arial", usedFontSize)
    gfx.set(textColor[1], textColor[2], textColor[3], 1)
    local textH = gfx.texth
    gfx.x = x + 8
    gfx.y = y + math.max(0, (h - textH) / 2) - 1
    gfx.drawstr(fitted)

    return hover
end

-- Draw a checkbox as a toggle box (like stems/presets) and return if it was clicked (scaled)
-- Optional fixedW parameter to set a fixed width for all boxes
-- Optional fontSizeOverride: when provided, a group of boxes can share the same text size.
local function drawCheckbox(x, y, checked, label, r, g, b, fixedW, fontSizeOverride)
    return UI_DRAW.drawCheckbox(x, y, checked, label, r, g, b, fixedW, fontSizeOverride)
end

local function drawColumnHeader(text, x, width, fontSize, y)
    fontSize = fontSize or S(10)
    y = y or 0
    gfx.setfont(1, "Arial", fontSize)
    local label = text or ""
    local padding = S(2)
    local minFontSize = math.max(S(8), fontSize - S(3))
    local labelText, tw, usedFontSize = fitTextToBox(label, (width or 0) - padding * 2, fontSize, minFontSize)
    gfx.x = x + (width - tw) / 2
    gfx.y = y
    gfx.drawstr(labelText)
    if usedFontSize ~= fontSize then
        gfx.setfont(1, "Arial", fontSize)
    end
end

function drawResultWindowControls(ctx)
    ctx.profile = "result"
    ctx.S = ctx.PS
    ctx.setLanguageFn = setLanguage
    ctx.updateControlsOpacityFn = updateControlsOpacity
    ctx.state = resultWindowState
    UI_CONTROLS.drawTopRightControls(ctx)
end

local getStemDisplayName

function renderResultTitleArea(ctx)
    local w, PS = ctx.w, ctx.PS
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local selectedStems = resultWindowState.selectedStems or {}
    local resultTokens = (UI_TOKENS and UI_TOKENS.result) or {}
    local spacing = resultTokens.spacing or {}
    local fonts = resultTokens.fonts or {}

    local iconX = w / 2
    local iconY = PS(spacing.iconY or 60)
    local iconR = PS(spacing.iconRadius or 28)

    if utilityMode then
        local ur, ug, ub = utilityProgressColor()
        gfx.set(ur, ug, ub, 1)
    else
        gfx.set(0.2, 0.65, 0.35, 1)
    end
    gfx.circle(iconX, iconY, iconR, 1, 1)

    gfx.set(1, 1, 1, 1)
    local cx, cy = iconX, iconY
    local x1, y1 = cx - PS(10), cy
    local x2, y2 = cx - PS(3), cy + PS(8)
    gfx.line(x1, y1, x2, y2)
    gfx.line(x1, y1+1, x2, y2+1)
    local x3, y3 = cx + PS(10), cy - PS(7)
    gfx.line(x2, y2, x3, y3)
    gfx.line(x2, y2+1, x3, y3+1)

    gfx.setfont(1, "Arial", PS(fonts.title or 18), string.byte('b'))
    local stemLetterColors = {
        {255, 100, 100},
        {100, 200, 255},
        {150, 100, 255},
        {100, 255, 150},
    }
    local stemPart = "STEM"
    local restPart = T("complete_title_suffix") or "werk Complete!"
    local stemW = gfx.measurestr(stemPart)
    local restW = gfx.measurestr(restPart)
    local totalW = stemW + restW
    local titleX = (w - totalW) / 2
    local titleY = PS(spacing.titleY or 100)

    if utilityMode then
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = titleX
        gfx.y = titleY
        gfx.drawstr(stemPart .. restPart)
    else
        local charX = titleX
        for i = 1, 4 do
            local char = stemPart:sub(i, i)
            local color = stemLetterColors[i]
            gfx.set(color[1]/255, color[2]/255, color[3]/255, 1)
            gfx.x = charX
            gfx.y = titleY
            gfx.drawstr(char)
            charX = charX + gfx.measurestr(char)
        end

        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = charX
        gfx.y = titleY
        gfx.drawstr(restPart)
    end

    local stemY = PS(spacing.stemRowY or 125)
    local stemBoxSize = PS(14)
    gfx.setfont(1, "Arial", PS(fonts.stem or 11))
    local totalStemWidth = 0
    for _, stem in ipairs(selectedStems) do
        local stemLabel = getStemDisplayName(stem)
        totalStemWidth = totalStemWidth + stemBoxSize + gfx.measurestr(stemLabel) + PS(spacing.stemItemGap or 16)
    end
    local stemX = (w - totalStemWidth) / 2
    for _, stem in ipairs(selectedStems) do
        local stemLabel = getStemDisplayName(stem)
        if utilityMode then
            local ur, ug, ub = utilityProgressMutedColor()
            gfx.set(ur, ug, ub, 1)
        else
            gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
        end
        gfx.rect(stemX, stemY, stemBoxSize, stemBoxSize, 1)
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        gfx.x = stemX + stemBoxSize + PS(spacing.stemLabelGap or 5)
        gfx.y = stemY + PS(1)
        gfx.drawstr(stemLabel)
        stemX = stemX + stemBoxSize + gfx.measurestr(stemLabel) + PS(spacing.stemItemGap or 16)
    end

end

function renderResultMessageBox(ctx)
    local w, h, PS = ctx.w, ctx.h, ctx.PS
    local resultTokens = (UI_TOKENS and UI_TOKENS.result) or {}
    local padding = resultTokens.padding or {}
    local fonts = resultTokens.fonts or {}
    local msgBoxY = PS(padding.messageBoxTop or 170)
    local msgBoxH = PS(padding.messageBoxHeight or 70)
    local msgBoxX = PS(padding.messageBoxX or 20)
    local msgBoxW = w - (msgBoxX * 2)
    local resultBoxAlpha = (SETTINGS and SETTINGS.darkMode) and 0.30 or 0.82
    local msgBoxRadius = getThemeRadius(PS, 10, math.floor(math.min(msgBoxW, msgBoxH) / 2))
    local msgBoxBorderWeight = getThemeBorderWeight(PS, 1)
    drawThemeSurfaceBox(msgBoxX, msgBoxY, msgBoxW, msgBoxH, THEME.inputBg, THEME.border, resultBoxAlpha, (SETTINGS and SETTINGS.darkMode) and 0.6 or 0.9, msgBoxRadius, msgBoxBorderWeight, 0.85, "card")

    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.setfont(1, "Arial", PS(fonts.message or 11))
    local msgLines = buildResultMessageLines()
    local msgY = msgBoxY + PS(padding.messageTextTop or 8)
    for _, line in ipairs(msgLines) do
        local lineW = gfx.measurestr(line)
        gfx.x = (w - lineW) / 2
        gfx.y = msgY
        gfx.drawstr(line)
        msgY = msgY + PS(padding.messageLineStep or 13)
    end
end

function buildResultMessageLines()
    local data = resultWindowState and resultWindowState.messageData or nil
    if not data then
        local msgLines = {}
        local msg = (resultWindowState and resultWindowState.message) or ""
        for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(msgLines, line)
        end
        return msgLines
    end

    -- Dynamic (retranslatable) message
    local lines = {}
    local timeStr = string.format("%d:%02d", math.floor((data.totalTimeSec or 0) / 60), (data.totalTimeSec or 0) % 60)

    if data.kind == "multi_new_tracks" then
        local stemsCreated = data.stemsCreated or 0
        local srcCount = data.sourceCount or 0
        local sourceKind = data.sourceKind or "tracks"
        local stemWord = trPlural(stemsCreated, "result_stem_track_one", "result_stem_track_many", "stem track", "stem tracks")
        local srcWord
        if sourceKind == "items" then
            srcWord = trPlural(srcCount, "result_source_item_one", "result_source_item_many", "source item", "source items")
        else
            srcWord = trPlural(srcCount, "result_source_track_one", "result_source_track_many", "source track", "source tracks")
        end
        local line1 = string.format(T("result_multi_created") or "%d %s created from %d %s.", stemsCreated, stemWord, srcCount, srcWord)

        local speedStr = string.format("%.2fx", data.realtimeFactor or 0)
        local runtimeMode, _, runtimeReason = getRuntimeModeLabel(data)
        local line2 = string.format(T("result_stats") or "Time: %s | Speed: %s realtime | Mode: %s", timeStr, speedStr, runtimeMode)
        table.insert(lines, line1)
        table.insert(lines, line2)
        if runtimeReason ~= "" then
            local reasonLabel = T("mode_reason_label") or "Reason"
            table.insert(lines, string.format("%s: %s", reasonLabel, runtimeReason))
        end
    elseif data.kind == "multi_in_place" then
        local itemCount = data.itemCount or 0
        local itemWord = trPlural(itemCount, "footer_item", "footer_items", "item", "items")
        local line1 = string.format(T("result_items_replaced") or "%d %s replaced with stems as takes.", itemCount, itemWord)
        local speedStr = string.format("%.2fx", data.realtimeFactor or 0)
        local runtimeMode, _, runtimeReason = getRuntimeModeLabel(data)
        local line2 = string.format(T("result_stats") or "Time: %s | Speed: %s realtime | Mode: %s", timeStr, speedStr, runtimeMode)
        table.insert(lines, line1)
        table.insert(lines, line2)
        if runtimeReason ~= "" then
            local reasonLabel = T("mode_reason_label") or "Reason"
            table.insert(lines, string.format("%s: %s", reasonLabel, runtimeReason))
        end
    elseif data.kind == "single" then
        local line1 = nil
        if data.stemsCreated and data.sourceCount and data.sourceKind then
            local stemsCreated = data.stemsCreated or 0
            local sourceCount = data.sourceCount or 0
            local stemWord = trPlural(stemsCreated, "result_stem_track_one", "result_stem_track_many", "stem track", "stem tracks")
            if data.sourceKind == "time_selection" then
                line1 = string.format(T("result_time_selection_created") or "%d stem %s created from time selection.", stemsCreated, stemWord)
            else
                local srcWord = trPlural(sourceCount, "result_source_item_one", "result_source_item_many", "source item", "source items")
                line1 = string.format(T("result_multi_created") or "%d %s created from %d %s.", stemsCreated, stemWord, sourceCount, srcWord)
            end
        elseif data.mainKey then
            if data.mainKey == "result_time_selection_created" or data.mainKey == "result_stems_created_generic" then
                local count = data.count or 0
                local trackWord = trPlural(count, "footer_track", "footer_tracks", "track", "tracks")
                line1 = string.format(T(data.mainKey) or "%d stem %s created.", count, trackWord)
            else
                line1 = T(data.mainKey) or ""
            end
        else
            line1 = data.fallback or ""
        end
        table.insert(lines, line1)
        if data.actionKey then
            table.insert(lines, T(data.actionKey) or "")
        end
        local speed = tonumber(data.realtimeFactor or 0) or 0
        if speed > 0 then
            local speedStr = string.format("%.2fx", speed)
            table.insert(lines, string.format(T("result_time_speed_line") or "Time: %s | Speed: %s realtime", timeStr, speedStr))
        else
            table.insert(lines, string.format(T("result_time_line") or "Time: %s", timeStr))
        end
    end

    if data.action then
        local a = data.action
        if a.kind == "items" then
            local itemWord = trPlural(a.count or 0, "footer_item", "footer_items", "item", "items")
            table.insert(lines, string.format(T(a.key) or "", a.count or 0, itemWord))
        elseif a.kind == "tracks" then
            local trWord = trPlural(a.count or 0, "footer_track", "footer_tracks", "track", "tracks")
            table.insert(lines, string.format(T(a.key) or "", a.count or 0, trWord))
        end
    end

    return lines
end

drawGlossyPill = function(x, y, w, h, baseR, baseG, baseB, baseA)
    baseA = baseA or 1
    local borderWeight = getThemeBorderWeight(nil, 1)
    local radius = getThemeRadius(nil, h / 2, math.floor(h / 2))
    local gloss = getThemeGlossStrength(1)
    local function drawPillLineAt(px, py, pw, ph, pr, i)
        local inset = 0
        if i < pr then
            inset = pr - math.sqrt(math.max(0, pr * pr - (pr - i) * (pr - i)))
        elseif i > ph - pr then
            inset = pr - math.sqrt(math.max(0, pr * pr - (i - (ph - pr)) * (i - (ph - pr))))
        end
        gfx.line(px + inset, py + i, px + pw - inset, py + i)
    end

    drawThemeShadow(x, y, w, h, radius, 0.9, "button")
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], baseA)
    drawRoundedFill(x, y, w, h, radius)

    local innerX = x + borderWeight
    local innerY = y + borderWeight
    local innerW = w - borderWeight * 2
    local innerH = h - borderWeight * 2
    local innerRadius = math.max(0, radius - borderWeight)
    if innerW <= 0 or innerH <= 0 then
        return true
    end

    gfx.set(baseR, baseG, baseB, baseA)
    for i = 0, innerH - 1 do
        drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, i)
    end

    local _utilityModePill = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    if not _utilityModePill then
        local hiR = math.min(1, baseR + 0.3)
        local hiG = math.min(1, baseG + 0.3)
        local hiB = math.min(1, baseB + 0.3)
        local highlightH = math.max(1, math.floor(innerH * 0.42))
        for i = 0, highlightH - 1 do
            local t = 1 - (i / math.max(1, highlightH - 1))
            gfx.set(hiR, hiG, hiB, 0.25 * t * baseA * gloss)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, i)
        end

        local bandY = math.floor(innerH * 0.18)
        local bandH = math.max(1, math.floor(innerH * 0.22))
        for i = 0, bandH - 1 do
            local t = 1 - (i / math.max(1, bandH - 1))
            gfx.set(1, 1, 1, 0.12 * t * baseA * gloss)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, bandY + i)
        end

        local shR, shG, shB = baseR * 0.6, baseG * 0.6, baseB * 0.6
        local shadowH = math.max(1, math.floor(innerH * 0.35))
        for i = 0, shadowH - 1 do
            local t = i / math.max(1, shadowH - 1)
            gfx.set(shR, shG, shB, 0.18 * t * baseA * gloss)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, innerH - 1 - i)
        end

        local innerR, innerG, innerB = baseR * 0.7, baseG * 0.7, baseB * 0.7
        for i = 0, innerH - 1 do
            if i < 2 or i > innerH - 3 then
                gfx.set(innerR, innerG, innerB, 0.2 * baseA * gloss)
                drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, i)
            end
        end
    end

    -- Light-mode technical finish: crisp rim + face separation for clearer depth.
    if not _utilityModePill and isThemeLightMode() then
        local p = getLightElevationProfile("button")
        if p then
            gfx.set(1, 1, 1, math.min(0.18, p.rim * 0.9) * baseA)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, 0)
            if innerH > 3 then
                gfx.set(1, 1, 1, math.min(0.12, p.highlight * 0.8) * baseA)
                drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, 1)
            end
            local midY = math.max(0, math.floor(innerH * 0.48))
            gfx.set(1, 1, 1, math.min(0.08, p.highlight * 0.55) * baseA)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, midY)
            gfx.set(0, 0, 0, math.min(0.12, p.bevel * 0.8) * baseA)
            drawPillLineAt(innerX, innerY, innerW, innerH, innerRadius, math.max(0, innerH - 1))
        end
    end
    return true
end

drawGlossyRect = function(x, y, w, h, baseR, baseG, baseB, baseA)
    baseA = baseA or 1
    local borderWeight = getThemeBorderWeight(nil, 1)
    local radius = getThemeRadius(nil, 0, math.floor(math.min(w, h) / 2))
    local gloss = getThemeGlossStrength(1)
    drawThemeShadow(x, y, w, h, radius, 0.7, "button")
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], baseA)
    drawRoundedFill(x, y, w, h, radius)

    local innerX = x + borderWeight
    local innerY = y + borderWeight
    local innerW = w - borderWeight * 2
    local innerH = h - borderWeight * 2
    local innerRadius = math.max(0, radius - borderWeight)
    if innerW <= 0 or innerH <= 0 then
        return
    end

    gfx.set(baseR, baseG, baseB, baseA)
    drawRoundedFill(innerX, innerY, innerW, innerH, innerRadius)

    local _utilityModeRect = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    if not _utilityModeRect then
        local hiR = math.min(1, baseR + 0.3)
        local hiG = math.min(1, baseG + 0.3)
        local hiB = math.min(1, baseB + 0.3)
        local highlightH = math.max(1, math.floor(innerH * 0.42))
        for i = 0, highlightH - 1 do
            local t = 1 - (i / math.max(1, highlightH - 1))
            gfx.set(hiR, hiG, hiB, 0.25 * t * baseA * gloss)
            drawRoundedFill(innerX, innerY + i, innerW, 1, math.max(0, math.min(innerRadius, i)))
        end

        local bandY = math.floor(innerH * 0.18)
        local bandH = math.max(1, math.floor(innerH * 0.22))
        for i = 0, bandH - 1 do
            local t = 1 - (i / math.max(1, bandH - 1))
            gfx.set(1, 1, 1, 0.12 * t * baseA * gloss)
            drawRoundedFill(innerX, innerY + bandY + i, innerW, 1, math.max(0, math.min(innerRadius, bandY + i)))
        end

        local shR, shG, shB = baseR * 0.6, baseG * 0.6, baseB * 0.6
        local shadowH = math.max(1, math.floor(innerH * 0.35))
        for i = 0, shadowH - 1 do
            local t = i / math.max(1, shadowH - 1)
            gfx.set(shR, shG, shB, 0.18 * t * baseA * gloss)
            drawRoundedFill(innerX, innerY + (innerH - 1 - i), innerW, 1, math.max(0, math.min(innerRadius, innerH - 1 - i)))
        end

        gfx.set(baseR * 0.7, baseG * 0.7, baseB * 0.7, 0.2 * baseA * gloss)
        drawRoundedFill(innerX, innerY, innerW, 1, math.min(innerRadius, 1))
        drawRoundedFill(innerX, innerY + innerH - 1, innerW, 1, math.min(innerRadius, 1))
    end

    -- Light-mode technical finish: top rim and lower-face split to avoid flat controls.
    if not _utilityModeRect and isThemeLightMode() then
        local p = getLightElevationProfile("button")
        if p then
            gfx.set(1, 1, 1, math.min(0.18, p.rim * 0.9) * baseA)
            drawRoundedFill(innerX, innerY, innerW, 1, math.min(innerRadius, 1))
            if innerH > 3 then
                gfx.set(1, 1, 1, math.min(0.11, p.highlight * 0.8) * baseA)
                drawRoundedFill(innerX, innerY + 1, innerW, 1, math.min(innerRadius, 2))
            end
            local midY = innerY + math.max(0, math.floor(innerH * 0.46))
            gfx.set(1, 1, 1, math.min(0.07, p.highlight * 0.5) * baseA)
            drawRoundedFill(innerX, midY, innerW, 1, math.max(0, math.min(innerRadius, midY - innerY)))
            gfx.set(0, 0, 0, math.min(0.12, p.bevel * 0.8) * baseA)
            drawRoundedFill(innerX, innerY + innerH - 1, innerW, 1, math.min(innerRadius, 1))
        end
    end
end

UI_DRAW.configure({
    S = S,
    getTooltipPalette = getTooltipPalette,
    getThemeRadius = getThemeRadius,
    getThemeBorderWeight = getThemeBorderWeight,
    drawThemeSurfaceBox = drawThemeSurfaceBox,
    drawGlossyPill = drawGlossyPill,
    drawGlossyRect = drawGlossyRect,
    buildFooterLines = function()
        if type(buildFooterLines) == "function" then
            return buildFooterLines()
        end
        return nil
    end,
})

-- Draw a radio button as a toggle box (like stems/presets) and return if it was clicked (scaled)
-- Optional fixedW parameter to set a fixed width for all boxes
-- Optional attentionMult: when not selected, draw a subtle accent pulse (used to hint "direct tool" availability)
-- Optional icon: currently supports "explode" (drawn at left; animated when attentionMult > 0)
-- Optional fontSizeOverride: when provided, all radios in a group can share the same text size.
-- Optional lockFontSize: when true, keep the font size fixed and truncate with ellipsis if needed.
local function drawRadio(x, y, selected, label, color, fixedW, attentionMult, icon, fontSizeOverride, lockFontSize)
    return UI_DRAW.drawRadio(x, y, selected, label, color, fixedW, attentionMult, icon, fontSizeOverride, lockFontSize)
end

local function calcUniformRadioFontSize(labels, boxW, reservedLeft)
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local baseFontSize = utilityMode and math.max(S(8), math.floor(S(13) * 0.72 + 0.5)) or S(13)
    local minFontSize = S(9)
    local padding = S(4)
    local availableW = (boxW or 0) - padding * 2 - (reservedLeft or 0)
    if availableW <= 0 then return minFontSize end

    gfx.setfont(1, "Arial", baseFontSize)

    local maxW = 0
    for _, text in ipairs(labels or {}) do
        local w = gfx.measurestr(tostring(text or ""))
        if w > maxW then maxW = w end
    end

    if maxW <= 0 or maxW <= availableW then
        return baseFontSize
    end

    local scale = availableW / maxW
    local fontSize = math.max(minFontSize, math.floor(baseFontSize * scale))
    return fontSize
end

getUniformFontSizeCached = function(cacheId, labels, boxW, reservedLeft)
    GUI.fontSizeCache = GUI.fontSizeCache or {}

    local parts = { tostring(boxW or ""), tostring(reservedLeft or "") }
    for i = 1, #(labels or {}) do
        parts[#parts + 1] = tostring(labels[i] or "")
    end
    local cacheKey = table.concat(parts, "\n")

    local entry = GUI.fontSizeCache[cacheId]
    if entry and entry.key == cacheKey then
        return entry.size
    end

    local size = calcUniformRadioFontSize(labels, boxW, reservedLeft)
    GUI.fontSizeCache[cacheId] = { key = cacheKey, size = size }
    return size
end

local function stripExplodePrefix(label)
    label = tostring(label or "")
    -- Replace a leading localized "Explode" word with an icon, so the UI stays compact.
    -- Keep this conservative: only strip when the string clearly starts with the verb.
    label = label:gsub("^%s*[Ee]xplode%s+", "")      -- EN: Explode ..
    label = label:gsub("^%s*[Ee]xplodeer%s+", "")    -- NL: Explodeer ..
    label = label:gsub("^%s*[Ee]xplodieren%s+", "")  -- DE: Explodieren ..
    label = label:gsub("^%s*[Ee]xploser%s+", "")     -- FR: Exploser ..
    label = label:gsub("^%s*[Ee]xplotar%s+", "")     -- ES: Explotar ..
    label = label:gsub("\226\134\146", "->")
    label = label:gsub("\226\158\156", "->")
    label = label:gsub("\226\158\148", "->")
    label = label:gsub("\226\158\161", "->")
    label = label:gsub("\226\158\158", "->")
    label = label:gsub("\226\158\164", "->")
    return label
end

-- Forward declaration (defined later)
local explodeTakesFromItem

-- Apply a post-process explode mode to selected candidate items (created by the last in-place run).
-- This runs immediately on click, without re-processing audio.
local function applyPostProcessToSelectedCandidates(mode)
    mode = tostring(mode or "none")
    if mode == "none" then return 0 end

    -- Gather selected candidates that are still valid and have multiple takes
    local itemsToProcess = {}
    for i = #postProcessCandidates, 1, -1 do
        local item = postProcessCandidates[i]
        if not item or not reaper.ValidatePtr(item, "MediaItem*") then
            table.remove(postProcessCandidates, i)
        else
            local selected = (reaper.GetMediaItemInfo_Value(item, "B_UISEL") or 0) > 0.5
            local takeCount = reaper.CountTakes(item) or 0
            if selected and takeCount > 1 then
                itemsToProcess[#itemsToProcess + 1] = item
            end
        end
    end

    -- If there are no remembered candidates, allow "direct tool" usage:
    -- explode currently selected multi-take items, optionally restricted to time selection.
    if #itemsToProcess == 0 then
        local selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        local hasTimeSel = selEnd and selStart and selEnd > selStart

        local selItemCount = reaper.CountSelectedMediaItems(0) or 0
        for i = 0, selItemCount - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            if item and reaper.ValidatePtr(item, "MediaItem*") then
                local takeCount = reaper.CountTakes(item) or 0
                if takeCount > 1 then
                    local ok = true
                    if hasTimeSel then
                        local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                        local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                        local itemEnd = itemPos + itemLen
                        ok = (itemPos < selEnd) and (itemEnd > selStart)
                    end
                    if ok then
                        itemsToProcess[#itemsToProcess + 1] = item
                    end
                end
            end
        end
    end

    if #itemsToProcess == 0 then return 0 end
    if not explodeTakesFromItem then return 0 end

    local totalCreated = 0
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    for _, item in ipairs(itemsToProcess) do
        totalCreated = totalCreated + (explodeTakesFromItem(item, mode, true) or 0)
    end
    reaper.Undo_EndBlock("STEMwerk: Explode takes", -1)

    if totalCreated > 0 then
        clearPostProcessCandidates()
        reaper.UpdateArrange()
    end

    return totalCreated
end

-- Count selected multi-take items. If a time selection exists, only count items that overlap it.
-- Returns: count, hasTimeSelection
local function getSelectedMultiTakeCountRespectingTimeSelection()
    local selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local hasTimeSel = selEnd and selStart and selEnd > selStart

    local count = 0
    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    for i = 0, selItemCount - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local takeCount = reaper.CountTakes(item) or 0
            if takeCount > 1 then
                local ok = true
                if hasTimeSel then
                    local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local itemEnd = itemPos + itemLen
                    ok = (itemPos < selEnd) and (itemEnd > selStart)
                end
                if ok then
                    count = count + 1
                end
            end
        end
    end

    return count, hasTimeSel
end

-- Draw a toggle button (like stems) with selected state
-- Optional fontSizeOverride: when provided, a group of buttons can share the same text size (like Output column).
local function drawToggleButton(x, y, w, h, label, selected, color, fontSizeOverride)
    return UI_DRAW.drawToggleButton(x, y, w, h, label, selected, color, fontSizeOverride)
end

-- Draw a small button and return if it was clicked (scaled)
-- Optional fontSizeOverride: when provided, a group of buttons can share the same text size.
local function drawButton(x, y, w, h, label, isDefault, color, fontSizeOverride)
    return UI_DRAW.drawButton(x, y, w, h, label, isDefault, color, fontSizeOverride)
end

-- In-dialog modal overlay ------------------------------------------------------
-- We render this INSIDE dialogLoop() to avoid competing gfx windows / defer loops.
-- Defined as a standalone function to avoid bloating dialogLoop() locals (Lua has a local limit per function).
function drawMainDialogModalOverlay()
    local modal = GUI and GUI.modal or nil
    if not modal then return end

    -- Fade-in (subtle)
    if not modal._t0 then modal._t0 = os.clock() end
    local fade = math.min(1, (os.clock() - (modal._t0 or 0)) / 0.12)

    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = (gfx.mouse_cap & 1) == 1
    local char = gfx.getchar()
    if char == -1 then
        GUI.modal = nil
        return "close"
    end
    GUI.uiClickedThisFrame = true

    -- Keep the "cool background FX" alive even while the modal is open (dialogLoop() returns early).
    -- Match main dialog background color from THEME
    local bg = THEME and THEME.bg or {0.18, 0.18, 0.2}
    gfx.set(bg[1], bg[2], bg[3], 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    if proceduralArt and proceduralArt.seed == 0 then
        generateNewArt()
    end
    if proceduralArt then
        proceduralArt.time = (proceduralArt.time or 0) + 0.016
        -- Subtle: draw art without its own background, so theme (day/night) controls the backdrop.
        drawProceduralArtInternal(0, 0, gfx.w, gfx.h, proceduralArt.time, (mainDialogArt and mainDialogArt.rotation) or 0, true, 0.22)
    end

    -- Theme-aware readability overlay (same idea as main dialog: black in dark mode, white in light mode).
    gfx.set(bg, bg, bg, 0.55 * fade)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    -- ── Path-input modal ──────────────────────────────────────────────────────
    if tostring(modal.mode or "") == "path_input" then
        if not modal.pathInput then
            modal.pathInput = UI_PATH_INPUT.newState(tostring(modal.inputValue or ""))
            modal.openedMouseDown = mouseDown
        end
        local ps = modal.pathInput

        if char == 13 then
            local sv, fn = ps.value, modal.onSubmit
            GUI.modal = nil
            if fn then fn(sv) end
            return
        elseif char == 27 then
            local fn = modal.onCancel
            GUI.modal = nil
            if fn then fn() end
            return
        else
            UI_PATH_INPUT.handleKey(ps, char)
        end

        local piPad    = S(14)
        local piTopBar = S(3)
        local piBtnW   = S(90)
        local piBtnH   = S(28)
        local piInputH = S(32)
        local piIconR  = S(12)
        local piMaxW   = math.min(gfx.w - S(40), S(500))
        local piBoxW   = piMaxW
        local piContW  = piBoxW - piPad * 2
        local piTxtX   = piPad + piIconR * 2 + S(10)
        local piTxtW   = piContW - (piIconR * 2 + S(10))
        local piTitle  = tostring(modal.title or "")
        local piMsg    = tostring(modal.message or "")
        local piIco    = tostring(modal.icon or "info")
        local piLabel  = tostring(modal.inputLabel or "Folder path:")

        gfx.setfont(1, "Arial", S(13), string.byte('b'))
        local piTitleH = gfx.texth
        gfx.setfont(1, "Arial", S(12))
        local piLineH  = gfx.texth + S(2)
        local piLines  = _wrapTextToWidth(piMsg, math.max(S(100), piTxtW))
        if #piLines == 0 then piLines = {piMsg} end

        local piClearW  = S(28)
        local piInputX  = (gfx.w - piBoxW) / 2 + piTxtX
        local piInputW  = piBoxW - piTxtX - piPad        -- full-width inside box
        local piFieldW  = piInputW - piClearW - S(4)
        local piHintH   = UI_PATH_INPUT.hasClipboard() and 0 or piLineH
        local piBoxH    = piPad + piTopBar + S(10) + piTitleH + S(8)
                        + (#piLines * piLineH) + S(10)
                        + piLineH + piInputH + S(4)      -- label + field
                        + piHintH
                        + S(8) + piBtnH + piPad
        piBoxH = math.max(piBoxH, S(190))

        local piBoxX = (gfx.w - piBoxW) / 2
        local piBoxY = (gfx.h - piBoxH) / 2
        local piR    = getThemeRadius(S, 12, math.floor(math.min(piBoxW, piBoxH) / 2))
        local piBW   = getThemeBorderWeight(S, 1)
        drawThemeSurfaceBox(piBoxX, piBoxY, piBoxW, piBoxH, THEME.inputBg, THEME.border, 0.985, 0.95, piR, piBW, 1.25 * fade, "card")

        if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
            gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.5 * fade)
            gfx.line(piBoxX + 1, piBoxY + 1, piBoxX + piBoxW - 2, piBoxY + 1)
        else
            for i = 0, math.floor(piBoxW) - 1 do
                local ci = math.min(4, math.max(1, math.floor(i / piBoxW * 4) + 1))
                local c  = STEM_BORDER_COLORS[ci]
                gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.92 * fade)
                gfx.line(piBoxX + i, piBoxY + 1, piBoxX + i, piBoxY + piTopBar)
            end
        end

        local piIcoX = piBoxX + piPad + piIconR
        local piIcoY = piBoxY + piPad + piTopBar + S(12)
        local piIcoC = (piIco == "error") and {1.0, 0.35, 0.35}
                    or (piIco == "warning") and THEME.accent
                    or (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) and {THEME.border[1], THEME.border[2], THEME.border[3]}
                    or {0.35, 0.75, 1.0}
        gfx.set(piIcoC[1], piIcoC[2], piIcoC[3], 1)
        gfx.circle(piIcoX, piIcoY, piIconR, 1, 1)
        gfx.set(0, 0, 0, 0.65)
        gfx.circle(piIcoX, piIcoY, piIconR, 0, 1)
        gfx.set(1, 1, 1, 1)
        gfx.setfont(1, "Arial", S(14), string.byte('b'))
        local piSym  = (piIco == "info") and "i" or "!"
        local piSymW = gfx.measurestr(piSym)
        gfx.x = piIcoX - piSymW / 2
        gfx.y = piIcoY - gfx.texth / 2 - 1
        gfx.drawstr(piSym)

        local piTX = piBoxX + piTxtX
        local piTY = piBoxY + piPad + piTopBar + S(4)
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.setfont(1, "Arial", S(14), string.byte('b'))
        gfx.x = piTX; gfx.y = piTY
        gfx.drawstr(piTitle)

        gfx.setfont(1, "Arial", S(12))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local piY = piTY + piTitleH + S(8)
        for _, ln in ipairs(piLines) do
            gfx.x = piTX; gfx.y = piY; gfx.drawstr(tostring(ln)); piY = piY + piLineH
        end

        piY = piY + S(10)
        gfx.setfont(1, "Arial", S(11))
        gfx.x = piInputX; gfx.y = piY; gfx.drawstr(piLabel)

        local piFieldY = piY + piLineH
        local piIR     = getThemeRadius(S, math.floor(piInputH / 2), math.floor(piInputH / 2))
        drawThemeSurfaceBox(piInputX, piFieldY, piFieldW, piInputH, THEME.inputBg, THEME.border, 0.98, 0.95, piIR, piBW, 0.5, "card")

        gfx.setfont(1, "Arial", S(12))
        local piPadTX  = S(8)
        local piAvailW = piFieldW - piPadTX * 2
        local piDisp, piCurX, piAllSel = UI_PATH_INPUT.getDisplayInfo(ps, piAvailW, gfx.measurestr)

        if piAllSel then
            local piSelW = math.min(gfx.measurestr(piDisp), piFieldW - piPadTX * 2)
            gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 0.35)
            gfx.rect(piInputX + piPadTX, piFieldY + S(4), piSelW, piInputH - S(8), 1)
        end
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = piInputX + piPadTX
        gfx.y = piFieldY + (piInputH - gfx.texth) / 2
        gfx.drawstr(piDisp)

        if not piAllSel and math.floor(os.clock() * 2) % 2 == 0 then
            local piCaretX = math.min(piInputX + piFieldW - S(4), piInputX + piPadTX + piCurX + S(1))
            gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
            gfx.rect(piCaretX, piFieldY + S(5), math.max(1, S(1.5)), piInputH - S(10), 1)
        end

        local piClearX = piInputX + piFieldW + S(4)
        local piClearHov = mx >= piClearX and mx <= piClearX + piClearW
                       and my >= piFieldY and my <= piFieldY + piInputH
        drawThemeSurfaceBox(piClearX, piFieldY, piClearW, piInputH,
            piClearHov and THEME.buttonHover or THEME.button, THEME.border, 1, 0.95, piIR, piBW, 0.95, "button")
        gfx.setfont(1, "Arial", S(14), string.byte('b'))
        local piXStr = "x"
        local piXW   = gfx.measurestr(piXStr)
        gfx.set(piClearHov and 1 or THEME.textDim[1], piClearHov and 1 or THEME.textDim[2], piClearHov and 1 or THEME.textDim[3], 1)
        gfx.x = piClearX + (piClearW - piXW) / 2
        gfx.y = piFieldY + (piInputH - gfx.texth) / 2
        gfx.drawstr(piXStr)

        if piHintH > 0 then
            gfx.setfont(1, "Arial", S(10))
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.6)
            gfx.x = piInputX; gfx.y = piFieldY + piInputH + S(2)
            gfx.drawstr("Install SWS extension to enable Ctrl+V paste")
        end

        local piBtnY   = piFieldY + piInputH + piHintH + S(8)
        local piBrowseW = S(110)
        local hasBrowse = UI_PATH_INPUT.hasBrowse()
        local piBrowseAlpha = hasBrowse and 1.0 or 0.38
        local piBrowseHov   = hasBrowse and mx >= piInputX and mx <= piInputX + piBrowseW
                           and my >= piBtnY and my <= piBtnY + piBtnH
        drawThemeSurfaceBox(piInputX, piBtnY, piBrowseW, piBtnH,
            piBrowseHov and THEME.buttonHover or THEME.button,
            THEME.border, 1, 0.95 * piBrowseAlpha, piR, piBW, 0.95 * piBrowseAlpha, "button")
        gfx.setfont(1, "Arial", S(12))
        local piBLabel = T("browse") or "Browse"
        local piBLabelW = gfx.measurestr(piBLabel)
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], piBrowseAlpha)
        gfx.x = piInputX + (piBrowseW - piBLabelW) / 2
        gfx.y = piBtnY + (piBtnH - gfx.texth) / 2
        gfx.drawstr(piBLabel)

        if not hasBrowse and mx >= piInputX and mx <= piInputX + piBrowseW
                and my >= piBtnY and my <= piBtnY + piBtnH then
            setTooltip(piInputX, piBtnY, piBrowseW, piBtnH, "Folder picker unavailable. Paste or type a path manually.")
        end

        local piOkX    = piBoxX + piBoxW - piPad - piBtnW
        local piCnlX   = piOkX - piBtnW - S(8)
        local piOkHov  = mx >= piOkX and mx <= piOkX + piBtnW and my >= piBtnY and my <= piBtnY + piBtnH
        local piCnlHov = mx >= piCnlX and mx <= piCnlX + piBtnW and my >= piBtnY and my <= piBtnY + piBtnH
        local piBR     = getThemeRadius(S, math.floor(piBtnH / 2), math.floor(piBtnH / 2))
        drawThemeSurfaceBox(piOkX, piBtnY, piBtnW, piBtnH, piOkHov and THEME.buttonPrimaryHover or THEME.buttonPrimary, THEME.border, 1, 0.95, piBR, piBW, 0.95, "button")
        gfx.set(1, 1, 1, 1)
        gfx.setfont(1, "Arial", S(12), string.byte('b'))
        local piOkTxt = T("ok") or "OK"
        local piOkTW  = gfx.measurestr(piOkTxt)
        gfx.x = piOkX + (piBtnW - piOkTW) / 2; gfx.y = piBtnY + (piBtnH - gfx.texth) / 2
        gfx.drawstr(piOkTxt)
        drawThemeSurfaceBox(piCnlX, piBtnY, piBtnW, piBtnH, piCnlHov and THEME.buttonHover or THEME.button, THEME.border, 1, 0.95, piBR, piBW, 0.95, "button")
        gfx.set(1, 1, 1, 1)
        local piCnlTxt = T("cancel") or "Cancel"
        local piCnlTW  = gfx.measurestr(piCnlTxt)
        gfx.x = piCnlX + (piBtnW - piCnlTW) / 2; gfx.y = piBtnY + (piBtnH - gfx.texth) / 2
        gfx.drawstr(piCnlTxt)

        local piOver   = mx >= piBoxX and mx <= piBoxX + piBoxW and my >= piBoxY and my <= piBoxY + piBoxH
        local piWas    = GUI.modalWasMouseDown
        local piRel    = not mouseDown
        if piClearHov and piRel and piWas then
            ps.value = ""; ps.cursor = 0; ps.allSelected = false
        end
        if piBrowseHov and piRel and piWas then
            GUI.modalWasMouseDown = false
            local dir = UI_PATH_INPUT.browseForFolder(ps.value)
            if dir then ps.value = dir; ps.cursor = #dir; ps.allSelected = false end
        elseif piOkHov and piRel and piWas then
            local sv, fn = ps.value, modal.onSubmit
            GUI.modal = nil
            if fn then fn(sv) end
            return
        elseif (piCnlHov and piRel and piWas) or (piRel and piWas and not piOver and not modal.openedMouseDown) then
            local fn = modal.onCancel
            GUI.modal = nil
            if fn then fn() end
            return
        end

        if modal.openedMouseDown and not mouseDown then modal.openedMouseDown = false end
        GUI.modalWasMouseDown = mouseDown
        return
    end
    -- ── End path-input modal ──────────────────────────────────────────────────

    -- Layout
    local pad = S(14)
    local iconR = S(12)
    local topBarH = S(3)
    local btnW = S(96)
    local btnH = S(28)
    local maxBoxW = S(360)
    local boxW = math.min(gfx.w - S(40), maxBoxW)
    local contentW = boxW - pad * 2
    local textX = pad + iconR * 2 + S(10)
    local textW = contentW - (iconR * 2 + S(10))

    local title = tostring(modal.title or (T("warning") or "Warning"))
    local msg = tostring(modal.message or "")
    local iconKind = tostring(modal.icon or "warning")
    local isInputModal = tostring(modal.mode or "") == "input"
    local inputLabel = tostring(modal.inputLabel or "")
    local inputValue = tostring(modal.inputValue or "")

    -- Measure + wrap
    gfx.setfont(1, "Arial", S(13), string.byte('b'))
    local titleH = gfx.texth
    gfx.setfont(1, "Arial", S(12))
    local lineH = gfx.texth + S(2)
    local lines = _wrapTextToWidth(msg, math.max(S(120), textW))
    if #lines == 0 then lines = {msg} end

    local inputGap = isInputModal and S(10) or 0
    local inputLabelH = isInputModal and lineH or 0
    local inputH = isInputModal and S(28) or 0
    local boxH = pad + topBarH + S(10) + titleH + S(8) + (#lines * lineH) + inputGap + inputLabelH + inputH + S(12) + btnH + pad
    boxH = math.max(boxH, S(150))

    local boxX = (gfx.w - boxW) / 2
    local boxY = (gfx.h - boxH) / 2

    local r = getThemeRadius(S, 12, math.floor(math.min(boxW, boxH) / 2))
    local borderWeight = getThemeBorderWeight(S, 1)
    drawThemeSurfaceBox(boxX, boxY, boxW, boxH, THEME.inputBg, THEME.border, 0.985, 0.95, r, borderWeight, 1.25 * fade, "card")

    -- Stem-color top bar (like tooltips)
    for i = 0, math.floor(boxW) - 1 do
        local colorIdx = math.floor(i / boxW * 4) + 1
        colorIdx = math.min(4, math.max(1, colorIdx))
        local c = STEM_BORDER_COLORS[colorIdx]
        gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.92 * fade)
        gfx.line(boxX + i, boxY + 1, boxX + i, boxY + topBarH)
    end

    -- Icon (warning/info/error)
    local iconX = boxX + pad + iconR
    local iconY = boxY + pad + topBarH + S(12)
    local ic = THEME.accent
    if iconKind == "error" then
        ic = {1.0, 0.35, 0.35}
    elseif iconKind == "info" then
        ic = {0.35, 0.75, 1.0}
    end
    gfx.set(ic[1], ic[2], ic[3], 1)
    gfx.circle(iconX, iconY, iconR, 1, 1)
    gfx.set(0, 0, 0, 0.65)
    gfx.circle(iconX, iconY, iconR, 0, 1)
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", S(14), string.byte('b'))
    local sym = (iconKind == "info") and "i" or "!"
    local symW = gfx.measurestr(sym)
    gfx.x = iconX - symW / 2
    gfx.y = iconY - gfx.texth / 2 - 1
    gfx.drawstr(sym)

    -- Title + message (left aligned)
    local tx = boxX + textX
    local ty = boxY + pad + topBarH + S(4)
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.setfont(1, "Arial", S(14), string.byte('b'))
    gfx.x = tx
    gfx.y = ty
    gfx.drawstr(title)

    gfx.setfont(1, "Arial", S(12))
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local y = ty + titleH + S(8)
    for _, ln in ipairs(lines) do
        gfx.x = tx
        gfx.y = y
        gfx.drawstr(tostring(ln))
        y = y + lineH
    end

    local inputX = tx
    local inputW = math.max(S(120), boxX + boxW - pad - inputX)
    local inputY = y
    if isInputModal then
        gfx.setfont(1, "Arial", S(11))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        gfx.x = inputX
        gfx.y = inputY
        gfx.drawstr(inputLabel)

        local valueY = inputY + inputLabelH
        local ir = getThemeRadius(S, math.floor(inputH / 2), math.floor(inputH / 2))
        local inputBorderWeight = getThemeBorderWeight(S, 1)
        drawThemeSurfaceBox(inputX, valueY, inputW, inputH, THEME.inputBg, THEME.border, 0.98, 0.95, ir, inputBorderWeight, 0.5, "card")

        if char == 8 or char == 127 or char == 6579564 then
            modal.inputValue = inputValue:sub(1, math.max(0, #inputValue - 1))
            inputValue = tostring(modal.inputValue or "")
        elseif char >= 32 and char <= 126 then
            modal.inputValue = inputValue .. string.char(char)
            inputValue = tostring(modal.inputValue or "")
        end

        gfx.setfont(1, "Arial", S(12))
        local displayValue = inputValue
        local maxTextW = inputW - S(16)
        while gfx.measurestr(displayValue) > maxTextW and #displayValue > 4 do
            displayValue = "..." .. displayValue:sub(2)
        end
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = inputX + S(8)
        gfx.y = valueY + (inputH - gfx.texth) / 2
        gfx.drawstr(displayValue)
        if math.floor(os.clock() * 2) % 2 == 0 then
            local caretX = math.min(inputX + inputW - S(8), gfx.x + S(2))
            gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
            gfx.rect(caretX, valueY + S(6), S(1.5), inputH - S(12), 1)
        end
        y = valueY + inputH
    end

    -- OK / Cancel buttons
    local btnGap = S(10)
    local btnX = isInputModal and (boxX + (boxW - ((btnW * 2) + btnGap)) / 2) or (boxX + (boxW - btnW) / 2)
    local btnY = boxY + boxH - btnH - pad
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH
    local col = hover and THEME.buttonPrimaryHover or THEME.buttonPrimary

    local br = getThemeRadius(S, math.floor(btnH / 2), math.floor(btnH / 2))
    local buttonBorderWeight = getThemeBorderWeight(S, 1)
    drawThemeSurfaceBox(btnX, btnY, btnW, btnH, col, THEME.border, 1, 0.95, br, buttonBorderWeight, 0.95, "button")

    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", S(12), string.byte('b'))
    local okText = T("ok") or "OK"
    local okW = gfx.measurestr(okText)
    gfx.x = btnX + (btnW - okW) / 2
    gfx.y = btnY + (btnH - gfx.texth) / 2
    gfx.drawstr(okText)

    local cancelX, cancelHover = nil, false
    if isInputModal then
        cancelX = btnX + btnW + btnGap
        cancelHover = mx >= cancelX and mx <= cancelX + btnW and my >= btnY and my <= btnY + btnH
        local cancelCol = cancelHover and THEME.buttonHover or THEME.button
        drawThemeSurfaceBox(cancelX, btnY, btnW, btnH, cancelCol, THEME.border, 1, 0.95, br, buttonBorderWeight, 0.95, "button")

        local cancelText = T("cancel") or "Cancel"
        local cancelW = gfx.measurestr(cancelText)
        gfx.set(1, 1, 1, 1)
        gfx.x = cancelX + (btnW - cancelW) / 2
        gfx.y = btnY + (btnH - gfx.texth) / 2
        gfx.drawstr(cancelText)
    end

    local overBox = mx >= boxX and mx <= boxX + boxW and my >= boxY and my <= boxY + boxH
    local clickedOk = (not mouseDown) and GUI.modalWasMouseDown and hover
    local clickedCancel = isInputModal and (not mouseDown) and GUI.modalWasMouseDown and cancelHover
    local clickedOutside = (not mouseDown) and GUI.modalWasMouseDown and (not overBox)
    local keyCancel = (char == 27)
    local keySubmit = isInputModal and (char == 13)
    local keyClose = (not isInputModal) and ((char == 27) or (char == 13))
    if clickedOk or keySubmit then
        local onSubmit = modal.onSubmit
        local value = tostring(modal.inputValue or "")
        GUI.modal = nil
        if onSubmit then onSubmit(value) end
    elseif clickedCancel or clickedOutside or keyCancel or keyClose then
        local onCancel = modal.onCancel
        GUI.modal = nil
        if onCancel then onCancel() end
    end
    GUI.modalWasMouseDown = mouseDown
end

local function drawDeviceColumn(col4X, deviceColW, contentTop, btnH, commonBtnFontSize, mainHeaderFont)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("device") or "Device", col4X, deviceColW, mainHeaderFont, contentTop)
    setTooltip(col4X, contentTop, deviceColW, S(16), T("tooltip_section_device") or "Choose CPU, GPU, or automatic backend selection.")
    gfx.setfont(1, "Arial", S(13))

    local deviceBoxW = deviceColW
    local deviceY = contentTop + S(20)

    local deviceList = {}
    local seen = {}
    local function addDevice(base, available)
        if not base or not base.id then return end
        local copy = {
            id = base.id,
            name = base.name or base.id,
            fullName = base.fullName or base.name or base.id,
            uiName = base.uiName or base.name or base.id,
            type = base.type or "",
            desc = base.desc,
            descKey = base.descKey,
            available = available,
        }
        deviceList[#deviceList + 1] = copy
        seen[copy.id] = copy
    end

    local function splitGpuNames(list)
        local nvidia = {}
        local other = {}
        for _, nm in ipairs(list or {}) do
            local lower = tostring(nm):lower()
            if lower:find("nvidia", 1, true) then
                nvidia[#nvidia + 1] = nm
            else
                other[#other + 1] = nm
            end
        end
        return nvidia, other
    end

    if RUNTIME_DEVICES then
        for _, rd in ipairs(RUNTIME_DEVICES) do
            if rd and rd.id then
                local existing = seen[rd.id]
                if existing then
                    existing.name = rd.name or existing.name
                    existing.fullName = rd.fullName or rd.name or existing.fullName
                    existing.uiName = rd.uiName or existing.uiName
                    existing.type = rd.type or existing.type
                    existing.desc = rd.desc or existing.desc
                    existing.descKey = rd.descKey or existing.descKey
                    existing.available = true
                else
                    addDevice(rd, true)
                end
            end
        end
    else
        for _, d in ipairs(DEVICES) do
            addDevice(d, false)
        end
    end

    if RUNTIME_DEVICES and RUNTIME_DEVICE_PROBE_DEBUG == "ok" then
        local filtered = {}
        for _, d in ipairs(deviceList) do
            if d.available or d.id == "auto" or d.id == "cpu" then
                filtered[#filtered + 1] = d
            end
        end
        deviceList = filtered
    end

    if OS == "macOS" and ARCH == "arm64" then
        local filtered = {}
        for _, d in ipairs(deviceList) do
            if d.type ~= "mps" and tostring(d.id or "") ~= "mps" then
                filtered[#filtered + 1] = d
            end
        end
        deviceList = filtered
    end

    local function hasNumberedDevice(prefix)
        for _, d in ipairs(deviceList) do
            if d.id and tostring(d.id):match("^" .. prefix .. ":%d+$") then
                return true
            end
        end
        return false
    end

    local function firstNumberedDeviceId(prefix)
        for _, d in ipairs(deviceList) do
            if d.id and tostring(d.id):match("^" .. prefix .. ":%d+$") then
                return d.id
            end
        end
        return nil
    end

    -- Hide legacy alias devices (directml/cuda) when numbered devices exist.
    local hasDirectmlNumbered = hasNumberedDevice("directml")
    local hasCudaNumbered = hasNumberedDevice("cuda")
    if hasDirectmlNumbered or hasCudaNumbered then
        local filtered = {}
        for _, d in ipairs(deviceList) do
            local id = tostring(d.id or "")
            if (id == "directml" and hasDirectmlNumbered) or (id == "cuda" and hasCudaNumbered) then
                -- skip alias
            else
                filtered[#filtered + 1] = d
            end
        end
        deviceList = filtered
    end

    if SETTINGS and SETTINGS.device then
        if SETTINGS.device == "directml" then
            local mapped = firstNumberedDeviceId("directml")
            if mapped then
                SETTINGS.device = mapped
                if saveSettings then saveSettings() end
            end
        elseif SETTINGS.device == "cuda" then
            local mapped = firstNumberedDeviceId("cuda")
            if mapped then
                SETTINGS.device = mapped
                if saveSettings then saveSettings() end
            end
        end
    end

    -- Load optional device map so placeholders and runtime devices can show friendly names.
    local function loadDeviceMap()
        local map = {}
        local function readMapFile(mapPath)
            local f = io.open(mapPath, "r")
            if not f then return end
            local ok, data = pcall(function() return f:read("*a") end)
            f:close()
            if not (ok and data and data ~= "") then return end
            for k, v in data:gmatch('"([^\"]+)"%s*:%s*"([^\"]+)"') do
                map[k] = v
            end
        end

        local names = {"directml_device_map.json", "device_mapping.json"}
        for _, name in ipairs(names) do
            local candidates = {}
            if type(script_path) == "string" and script_path ~= "" then
                table.insert(candidates, script_path .. name)
                table.insert(candidates, script_path .. ".." .. PATH_SEP .. name)
                table.insert(candidates, script_path .. ".." .. PATH_SEP .. ".." .. PATH_SEP .. name)
            end
            if type(repo_root) == "string" and repo_root ~= "" then
                table.insert(candidates, repo_root .. "scripts" .. PATH_SEP .. "reaper" .. PATH_SEP .. name)
                table.insert(candidates, repo_root .. name)
            end
            local home = getHome()
            if home then
                if PATH_SEP == "\\" then
                    table.insert(candidates, home .. "\\Documents\\STEMwerk\\scripts\\reaper\\" .. name)
                else
                    table.insert(candidates, home .. "/Documents/STEMwerk/scripts/reaper/" .. name)
                end
            end
            table.insert(candidates, name)

            for _, mapPath in ipairs(candidates) do
                readMapFile(mapPath)
            end
        end

        if next(map) then return map end
        return nil
    end
    local deviceMap = loadDeviceMap() or {}
    local function mappedDeviceName(id)
        if not id or not deviceMap then return nil end
        if deviceMap[id] then return deviceMap[id] end
        local idx = tostring(id):match("^directml:(%d+)$")
        if idx then
            return deviceMap["privateuseone:" .. idx]
        end
        return nil
    end

    local function isPlaceholderName(name)
        local n = tostring(name or ""):lower()
        if n == "" then return true end
        if n:match("^cuda%s*%d*$") then return true end
        if n:match("^cuda%s*gpu%s*%d*$") then return true end
        if n:match("^directml%s*%d*$") then return true end
        if n:match("^directml%s*gpu%s*%d*$") then return true end
        if n:match("^gpu%s*%d*$") then return true end
        return false
    end

    local winGpuNames = nil
    if OS == "Windows" then
        -- Avoid synchronous PowerShell/WMI probing during the first UI render.
        -- Under Windows this can stall startup and visibly churn taskbar windows.
        winGpuNames = WINDOWS_GPU_NAMES
    end

    local function applyFriendlyGpuName(dev)
        if not dev or not dev.id then return end
        if dev.type ~= "cuda" and dev.type ~= "directml" and not tostring(dev.id):match("^cuda:%d+$") and not tostring(dev.id):match("^directml:%d+$") then
            return
        end
        local placeholder = isPlaceholderName(dev.fullName) or isPlaceholderName(dev.name)
        if not placeholder then return end
        local names = winGpuNames
        if not names or #names == 0 then return end
        local nvidia, _ = splitGpuNames(names)
        local idx = tonumber(tostring(dev.id):match(":(%d+)$")) or 0
        if tostring(dev.id) == "directml" or tostring(dev.id) == "cuda" then
            idx = 0
        end
        local pick = nil
        if tostring(dev.id):match("^cuda") or dev.type == "cuda" then
            pick = nvidia[idx + 1]
        else
            -- DirectML can map to any Windows GPU; use system ordering.
            pick = names[idx + 1]
        end
        if pick and pick ~= "" then
            dev.fullName = pick
        end
    end

    local function isAmdGpuName(name)
        local n = string.lower(tostring(name or ""))
        if n == "" then return false end
        return n:find("amd", 1, true) or n:find("radeon", 1, true) or n:find("gfx", 1, true)
    end

    local function isGpuLikeDevice(dev)
        if not dev or not dev.id then return false end
        local id = tostring(dev.id or "")
        return dev.type == "cuda" or dev.type == "directml" or id:match("^cuda:%d+$") or id:match("^directml:%d+$")
    end

    local function deviceBackendPrefix(dev)
        if not dev or not dev.id then return nil end
        local id = tostring(dev.id)
        if dev.type == "directml" or id:match("^directml") then return "DML" end
        if dev.type == "cuda" or id:match("^cuda") then
            if OS == "Linux" then
                local nm = dev.fullName or dev.name or ""
                if isAmdGpuName(nm) then
                    return "ROCm"
                end
            end
            return "CUDA"
        end
        return nil
    end

    local function rocmShortName(base)
        if not base or base == "" then return base end
        local b = tostring(base)
        local rx = b:match("RX%s*%d+")
        if rx then return rx end
        local rad = b:match("Radeon%s+RX%s*%d+") or b:match("Radeon%s+[%w%-]+")
        if rad then return rad end
        local amd = b:match("AMD%s+Radeon%s+[%w%-]+")
        if amd then
            return amd:gsub("^AMD%s+", "")
        end
        return b
    end

    local function buildDeviceUiLabel(dev)
        if not dev then return "" end
        if dev.id == "auto" or dev.id == "cpu" then
            return dev.name or dev.id
        end
        if OS == "Windows" and isGpuLikeDevice(dev) then
            local gpuCount = 0
            for _, candidate in ipairs(deviceList) do
                if isGpuLikeDevice(candidate) then
                    gpuCount = gpuCount + 1
                end
            end
            if gpuCount <= 1 then
                return "GPU"
            end
            local idx = tonumber(tostring(dev.id):match(":(%d+)$")) or 0
            return "GPU" .. tostring(idx)
        end
        local base = sanitizeFriendlyName(dev.fullName or dev.name or dev.id) or ""
        if base == "" or isPlaceholderName(base) then
            base = sanitizeFriendlyName(dev.name or dev.id) or ""
        end
        if base == "" or isPlaceholderName(base) then
            local idx = tonumber(tostring(dev.id):match(":(%d+)$")) or 0
            if tostring(dev.id) == "directml" or tostring(dev.id) == "cuda" then
                idx = 0
            end
            base = "GPU" .. tostring(idx)
        end
        if deviceBackendPrefix(dev) == "ROCm" then
            local short = rocmShortName(base)
            if short and short ~= "" then
                return short
            end
        end
        return base ~= "" and base or (dev.name or dev.id)
    end

    -- Apply friendly names from deviceMap and sanitize labels for UI buttons.
    for _, d in ipairs(deviceList) do
        d.fullName = d.fullName or d.name
        local mapped = mappedDeviceName(d.id)
        if mapped then d.fullName = mapped end
        if OS == "Windows" then
            applyFriendlyGpuName(d)
        end
        d.uiName = buildDeviceUiLabel(d)
    end

    local deviceLabels = {}
    for i = 1, #deviceList do
        deviceLabels[#deviceLabels + 1] = deviceList[i].uiName or deviceList[i].name
    end

    -- Device options with tooltips
    local deviceDescKeys = {
        auto = "device_auto_desc",
        cpu = "device_cpu_desc",
        ["cuda:0"] = "device_cuda_desc",
        ["cuda:1"] = "device_cuda_desc",
        ["directml:0"] = "device_directml_desc",
        ["directml:1"] = "device_directml_desc",
        directml = "device_directml_desc",
    }

    local function cleanDeviceLabel(name)
        if not name or name == "" then return "" end
        local lbl = tostring(name)
        lbl = lbl:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        return lbl
    end

    local function chosenDeviceLabel()
        local selId = SETTINGS.device or "auto"
        if selId == "auto" then
            if RUNTIME_DEVICES then
                for _, d in ipairs(RUNTIME_DEVICES) do
                    if d.id and not (d.id == "auto" or d.id == "cpu") then
                        return cleanDeviceLabel(d.fullName or d.name or d.id)
                    end
                end
            end
            return "Auto"
        end
        for _, d in ipairs(deviceList) do
            if d.id == selId then
                local label = cleanDeviceLabel(d.fullName or d.name or d.id)
                return label ~= "" and label or tostring(selId)
            end
        end
        return tostring(selId)
    end

    for _, device in ipairs(deviceList) do
        local label = device.uiName or device.name
        -- Use theme accent color for the selected device (same as Model selection)
        -- Use common fixed font size; drawRadio will handle individual shrink-to-fit if needed.
        if drawRadio(col4X, deviceY, SETTINGS.device == device.id, label, nil, deviceBoxW, nil, nil, commonBtnFontSize) then
            SETTINGS.device = device.id
            saveSettings()
        end
        local descKey = deviceDescKeys[device.id] or "device_auto_desc"
        -- Prefer runtime-probed descriptions when present; they explain the actual backend availability.
        local tip = nil
        if device.descKey and device.descKey ~= "" then
            tip = T(device.descKey)
        else
            tip = T(descKey) or device.desc
        end
        -- Include exact device id + full name in tooltip for clarity (especially when UI label is shortened).
        if device.id and device.fullName and device.fullName ~= "" then
            local labelIsShortened = (device.uiName and device.uiName ~= "" and device.uiName ~= device.fullName)
            local isGpuLike = (tostring(device.id):match("^cuda:%d+$") or tostring(device.id):match("^directml:%d+$") or device.type == "cuda" or device.type == "directml")
            if labelIsShortened or isGpuLike then
                tip = tostring(tip or "") .. "\n\n" .. tostring(device.id) .. " - " .. tostring(device.fullName)
            end
        end
        -- Append a short backend hint for GPU options.
        if device.id then
            local isGpuLike = (tostring(device.id):match("^cuda:%d+$") or tostring(device.id):match("^directml:%d+$") or device.type == "cuda" or device.type == "directml")
            if isGpuLike then
                if WINDOWS_GPU_NAME_STATUS then
                    local nameTip = T(WINDOWS_GPU_NAME_STATUS) or tostring(WINDOWS_GPU_NAME_STATUS)
                    if nameTip and nameTip ~= "" then
                        tip = tostring(tip or "") .. "\n\n" .. tostring(nameTip)
                    end
                end
            end
        end
        -- Append runtime skip note (e.g., ROCm GPU arch unsupported by installed rocBLAS).
        if (device.id == "auto" or device.id == "cpu") and RUNTIME_DEVICE_SKIP_NOTE and RUNTIME_DEVICE_SKIP_NOTE ~= "" then
            tip = tostring(tip or "") .. "\n\n" .. tostring(RUNTIME_DEVICE_SKIP_NOTE)
        end
        if tostring(device.id) == "auto" and RUNTIME_DEVICE_NOTE_KEY and T(RUNTIME_DEVICE_NOTE_KEY)
            and RUNTIME_DEVICE_NOTE_KEY ~= "device_note_probe_failed" then
            tip = tostring(tip or "") .. "\n\n" .. tostring(T(RUNTIME_DEVICE_NOTE_KEY))
        end
        -- Also append the resolved backend string so users see what the separator will use.
        if device.id then
            local backend_label = nil
            if tostring(device.id) == "auto" then
                local bestDevice = nil
                if RUNTIME_DEVICES then
                    for _, d in ipairs(RUNTIME_DEVICES) do
                        if d.id and not (d.id == "auto" or d.id == "cpu") then
                            bestDevice = d
                            break
                        end
                    end
                end
                if bestDevice then
                    local bestLabel = backendTypeLabel(bestDevice)
                    backend_label = (T("best_device_label") or "Best device") .. ": " .. bestLabel
                end
            else
                backend_label = backendTypeLabel(device)
            end

            if backend_label and backend_label ~= "" then
                local backend_prefix = T("backend_label") or "Backend"
                tip = tostring(tip or "") .. "\n\n" .. backend_prefix .. ": " .. backend_label
            end
        end
        local chosen_prefix = T("chosen_device_label") or "Chosen device"
        local chosen_label = chosenDeviceLabel()
        if tostring(device.id) == "auto" and chosen_label and chosen_label ~= "" then
            tip = tostring(tip or "") .. "\n\n" .. chosen_prefix .. ": " .. chosen_label
        end
        setTooltip(col4X, deviceY, deviceBoxW, btnH, tip)
        deviceY = deviceY + S(22)
    end


    -- Device header tooltip: show accurate probe status depending on runtime results.
    local headerTip = nil
    if RUNTIME_DEVICES and #RUNTIME_DEVICES > 0 then
        -- Check if any non-auto/cpu devices are present
        local hasGpu = false
        for _, d in ipairs(RUNTIME_DEVICES) do
            if d.id and not (d.id == "auto" or d.id == "cpu") then hasGpu = true; break end
        end
        headerTip = hasGpu and T("device_note_probe_completed") or T("device_note_no_gpu")
    elseif RUNTIME_DEVICE_NOTE_KEY and T(RUNTIME_DEVICE_NOTE_KEY) then
        headerTip = T(RUNTIME_DEVICE_NOTE_KEY)
    else
        headerTip = T("device_note_probe_failed")
    end
    if WINDOWS_GPU_NAME_STATUS then
        local nameTip = T(WINDOWS_GPU_NAME_STATUS) or tostring(WINDOWS_GPU_NAME_STATUS)
        if nameTip and nameTip ~= "" then
            headerTip = (headerTip and (tostring(headerTip) .. "\n\n") or "") .. tostring(nameTip)
        end
    end
    if RUNTIME_DEVICE_SKIP_NOTE and RUNTIME_DEVICE_SKIP_NOTE ~= "" then
        headerTip = (headerTip and (tostring(headerTip) .. "\n\n") or "") .. tostring(RUNTIME_DEVICE_SKIP_NOTE)
    end
    if headerTip and headerTip ~= "" then
        setTooltip(col4X, contentTop - S(2), deviceBoxW, S(18), headerTip)
    end

end

function GUI._updateFocusHandoff()
    if focusReaperAfterMainOpenOnce then
        focusReaperAfterMainOpenOnce = false
    end
end

function GUI._updateDialogPosition()
    local updatedPos = false
    -- macOS: prefer gfx-derived coordinates for persisted main window placement.
    -- JS rects can report frame-based Y that reopens follow-up windows too high.
    if OS ~= "macOS" and reaper.JS_Window_GetRect then
        local hwnd = reaper.JS_Window_Find(SCRIPT_NAME, true)
        if hwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if retval then
                rememberDialogGeometryFromRect(left, top, right, bottom)
                updatedPos = true
            end
        end
    end
    if not updatedPos then
        updateDialogPosFromGfx()
    end
end

function GUI._throttleSaveSettings()
    if not GUI.lastSaveTime then GUI.lastSaveTime = 0 end
    local now = os.clock()
    if now - GUI.lastSaveTime > 0.5 then  -- Save at most every 0.5 seconds
        saveSettings()
        GUI.lastSaveTime = now
    end
end

function GUI._handleNoSelection()
    -- Cache hasAnySelection() to avoid per-tick REAPER project scan; refresh every 250ms
    local now = uiNow()
    if not GUI._noSelCheckAt or now - GUI._noSelCheckAt >= 0.25 then
        GUI._noSelCheckAt = now
        GUI._noSelCached = hasAnySelection()
    end
    local hasSel = GUI._noSelCached
    if OS == "Windows" and GUI.windowsStartupMonitor then
        if hasSel then
            GUI.windowsStartupMonitor = false
            GUI.hadSelectionOnOpen = true
        end
        GUI.noSelectionFrames = 0
        return false
    end
    if not hasSel then
        GUI.noSelectionFrames = (GUI.noSelectionFrames or 0) + 1
        if GUI.noSelectionFrames > 10 then
            gfx.quit()
            autoSelectedItems = {}
            autoSelectionTracks = {}
            GUI.noSelectionFrames = 0
            reaper.defer(function()
                local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
                showMessage(promptTitle, promptMessage, "info", true)
            end)
            return true
        end
    else
        GUI.noSelectionFrames = 0
    end
    return false
end

drawHelpQuickStartHeader = function(w, contentY, textOffsetX, PS)
    local function PX(val) return (PS and PS(val)) or val end
    local qsTitle = getLangText("help_quickstart_title", "Quick Start")
    local subText = getLangText("help_quickstart_sub", "A fast guide to getting stems in REAPER.")
    local helpLayoutTokens = (UI_TOKENS and UI_TOKENS.helpLayout) or {}
    local header = UI_HELP_LAYOUT.computeHeaderLayout({
        tokens = helpLayoutTokens,
        S = PX,
        w = w,
        contentY = contentY,
        textOffsetX = textOffsetX,
        title = qsTitle,
        subtitle = subText,
    })

    gfx.setfont(1, "Arial", header.titleFont, string.byte('b'))
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.x = header.titleX
    gfx.y = header.titleY
    gfx.drawstr(qsTitle)

    gfx.setfont(1, "Arial", header.subtitleFont)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    gfx.x = header.subtitleX
    gfx.y = header.subtitleY
    gfx.drawstr(subText)
end

drawHelpReaperHeader = function(w, contentY, textOffsetX, PS)
    local function PX(val) return (PS and PS(val)) or val end
    local repTitle = getLangText("help_reaper_title", "REAPER")
    local repSub = getLangText("help_reaper_sub", "Selection, temp files, and cleanup")
    local helpLayoutTokens = (UI_TOKENS and UI_TOKENS.helpLayout) or {}
    local header = UI_HELP_LAYOUT.computeHeaderLayout({
        tokens = helpLayoutTokens,
        S = PX,
        w = w,
        contentY = contentY,
        textOffsetX = textOffsetX,
        title = repTitle,
        subtitle = repSub,
    })

    gfx.setfont(1, "Arial", header.titleFont, string.byte('b'))
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.x = header.titleX
    gfx.y = header.titleY
    gfx.drawstr(repTitle)

    gfx.setfont(1, "Arial", header.subtitleFont)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    gfx.x = header.subtitleX
    gfx.y = header.subtitleY
    gfx.drawstr(repSub)
end

local STEM_NAME_KEY_BY_ID = {
    vocals = "stem_vocals",
    drums = "stem_drums",
    bass = "stem_bass",
    other = "stem_other",
    guitar = "stem_guitar",
    piano = "stem_piano",
}

getStemDisplayName = function(stemOrName)
    local raw = stemOrName
    if type(stemOrName) == "table" then
        raw = stemOrName.name or stemOrName.file or ""
    end
    raw = tostring(raw or "")
    if raw == "" then return "" end

    local id = raw:lower():gsub("%.wav$", "")
    local key = STEM_NAME_KEY_BY_ID[id]
    if key then
        local translated = T(key)
        if translated and translated ~= "" and translated ~= key then
            return translated
        end
    end
    return raw
end

getRuntimeModeLabel = function(queue)
    local runtimeMode = (queue and queue.sequentialMode) and (T("sequential") or "Sequential") or (T("parallel") or "Parallel")
    local runtimeNote = ""
    local runtimeReason = ""
    local requestedParallel = SETTINGS.parallelProcessing
    if queue and queue.requestedParallel ~= nil then
        requestedParallel = queue.requestedParallel and true or false
    end
    if requestedParallel and (queue and queue.sequentialMode) then
        local reasonCode = queue.forceSequentialReason or queue.sequentialReason or queue.sequentialReasonText or ""
        local reason = ""
        if reasonCode == "per_item_jobs" then
            reason = T("mode_reason_per_item_jobs") or "per-item safety mode"
        elseif reasonCode == "directml_multi_track" then
            reason = T("mode_reason_directml_multi_track") or "DirectML multi-track stability mode"
        elseif reasonCode == "auto_no_gpu" then
            reason = T("mode_reason_auto_no_gpu") or "auto device, no GPU"
        elseif reasonCode ~= "" then
            reason = tostring(reasonCode)
        else
            reason = T("mode_fallback") or "fallback"
        end
        runtimeReason = tostring(reason or "")
        if runtimeReason ~= "" then
            runtimeNote = " (" .. runtimeReason .. ")"
        end
    end
    return runtimeMode, runtimeNote, runtimeReason
end

local function resolveTimeSelectionTargets()
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if startTime >= endTime then return nil end
    local minOverlapSec = 1 / 100

    local soloActive = getProcessingSoloActive()
    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    local selTrackCount = reaper.CountSelectedTracks(0) or 0
    local mode = "all_items"
    local items = {}
    local trackItems = {}
    local rawOverlap = 0

    local function addItem(item, track)
        if not item or not track then return end
        local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local iEnd = iPos + iLen
        if iPos < endTime and iEnd > startTime then
            local overlapStart = math.max(iPos, startTime)
            local overlapEnd = math.min(iEnd, endTime)
            local overlapLen = math.max(0, overlapEnd - overlapStart)
            if overlapLen > minOverlapSec then
                rawOverlap = rawOverlap + 1
                if AUDIBILITY.isItemAudible(item, soloActive) then
                items[#items + 1] = { item = item, track = track, start = overlapStart, ["end"] = overlapEnd, len = overlapLen }
                if not trackItems[track] then
                    trackItems[track] = {}
                end
                trackItems[track][#trackItems[track] + 1] = { item = item, track = track, start = overlapStart, ["end"] = overlapEnd, len = overlapLen }
                end
            end
        end
    end

    local selectedItemOverlap = 0
    if selItemCount > 0 then
        for i = 0, selItemCount - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            if item and reaper.ValidatePtr(item, "MediaItem*") then
                local track = reaper.GetMediaItem_Track(item)
                local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                local iEnd = iPos + iLen
                if iPos < endTime and iEnd > startTime then
                    selectedItemOverlap = selectedItemOverlap + 1
                    addItem(item, track)
                end
            end
        end
    end

    if selectedItemOverlap > 0 then
        mode = "selected_items"
    else
        items = {}
        trackItems = {}
        rawOverlap = 0
    end

    local selectedTrackOverlap = 0
    if selectedItemOverlap == 0 and selTrackCount > 0 then
        for t = 0, selTrackCount - 1 do
            local track = reaper.GetSelectedTrack(0, t)
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                local numItems = reaper.CountTrackMediaItems(track)
                for i = 0, numItems - 1 do
                    local item = reaper.GetTrackMediaItem(track, i)
                    local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local iEnd = iPos + iLen
                    if iPos < endTime and iEnd > startTime then
                        selectedTrackOverlap = selectedTrackOverlap + 1
                        addItem(item, track)
                    end
                end
            end
        end
    end

    if selectedItemOverlap == 0 and selectedTrackOverlap > 0 then
        mode = "selected_tracks"
    elseif selectedItemOverlap == 0 and selectedTrackOverlap == 0 then
        items = {}
        trackItems = {}
        rawOverlap = 0
        mode = "all_items"
        local numTracks = reaper.CountTracks(0)
        for t = 0, numTracks - 1 do
            local track = reaper.GetTrack(0, t)
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                local numItems = reaper.CountTrackMediaItems(track)
                for i = 0, numItems - 1 do
                    local item = reaper.GetTrackMediaItem(track, i)
                    addItem(item, track)
                end
            end
        end
    end

    local trackList = {}
    for tr in pairs(trackItems) do
        trackList[#trackList + 1] = tr
    end

    return {
        startTime = startTime,
        endTime = endTime,
        mode = mode,
        items = items,
        trackItems = trackItems,
        trackList = trackList,
        trackCount = #trackList,
        rawOverlap = rawOverlap,
    }
end

FOOTER_TIMESEL_CACHE = FOOTER_TIMESEL_CACHE or {
    key = nil,
    value = nil,
    at = 0,
}

function HELPERS.getCachedTimeSelectionTargets(hasTimeSel, useTimeSel, rawSelTrackCount, rawSelItemCount)
    if not hasTimeSel or not useTimeSel then
        FOOTER_TIMESEL_CACHE.key = nil
        FOOTER_TIMESEL_CACHE.value = nil
        FOOTER_TIMESEL_CACHE.at = 0
        return nil
    end

    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local key = table.concat({
        tostring(startTime or 0),
        tostring(endTime or 0),
        tostring(rawSelTrackCount or 0),
        tostring(rawSelItemCount or 0),
    }, "|")
    local now = os.clock()
    if FOOTER_TIMESEL_CACHE.key == key and FOOTER_TIMESEL_CACHE.value and (now - (FOOTER_TIMESEL_CACHE.at or 0)) < 0.20 then
        return FOOTER_TIMESEL_CACHE.value
    end

    FOOTER_TIMESEL_CACHE.key = key
    FOOTER_TIMESEL_CACHE.value = resolveTimeSelectionTargets()
    FOOTER_TIMESEL_CACHE.at = now
    return FOOTER_TIMESEL_CACHE.value
end

function HELPERS.hasExplicitOverlapSelection(startTime, endTime)
    if not startTime or not endTime or endTime <= startTime then
        return false
    end

    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    for i = 0, selItemCount - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local iEnd = iPos + iLen
            if iPos < endTime and iEnd > startTime then
                return true
            end
        end
    end

    local selTrackCount = reaper.CountSelectedTracks(0) or 0
    for t = 0, selTrackCount - 1 do
        local track = reaper.GetSelectedTrack(0, t)
        if track and reaper.ValidatePtr(track, "MediaTrack*") then
            local numItems = reaper.CountTrackMediaItems(track)
            for i = 0, numItems - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                if item and reaper.ValidatePtr(item, "MediaItem*") then
                    local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                    local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                    local iEnd = iPos + iLen
                    if iPos < endTime and iEnd > startTime then
                        return true
                    end
                end
            end
        end
    end

    return false
end

buildFooterLines = function()
    local is6Stem = (tostring(SETTINGS.model or "") == "htdemucs_6s")
    local rawSelTrackCount = reaper.CountSelectedTracks(0) or 0
    local rawSelItemCount = reaper.CountSelectedMediaItems(0) or 0

    local selectionMode, timeSelectionMode = nil, nil
    if type(resolveSelectionMode) == "function" then
        local mode, timeMode = resolveSelectionMode()
        selectionMode, timeSelectionMode = mode, timeMode
    end

    local soloActiveFooter = getProcessingSoloActive()

    local selTrackCount = 0
    local selectedTrackSet = {}
    for t = 0, rawSelTrackCount - 1 do
        local tr = reaper.GetSelectedTrack(0, t)
        if tr and AUDIBILITY.isTrackAudible(tr, soloActiveFooter) then
            selTrackCount = selTrackCount + 1
            selectedTrackSet[tr] = true
        end
    end

    local currentTimeStart, currentTimeEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local hasTimeSel = currentTimeEnd > currentTimeStart

    local selItemCount = 0
    local selItemDur = 0
    local selItemTrackSet = {}
    local selectedItemsByTrack = {}
    for i = 0, rawSelItemCount - 1 do
        local it = reaper.GetSelectedMediaItem(0, i)
        local tr = it and reaper.GetMediaItem_Track(it)
        if it and tr and AUDIBILITY.isTrackAudible(tr, soloActiveFooter) and AUDIBILITY.isItemAudible(it, soloActiveFooter) then
            local inTimeSel = true
            if hasTimeSel then
                local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local iend = ipos + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                inTimeSel = (ipos < currentTimeEnd and iend > currentTimeStart)
            end
            if inTimeSel then
                selItemCount = selItemCount + 1
                selItemDur = selItemDur + (reaper.GetMediaItemInfo_Value(it, "D_LENGTH") or 0)
                selItemTrackSet[tr] = true
                local items = selectedItemsByTrack[tr]
                if not items then
                    items = {}
                    selectedItemsByTrack[tr] = items
                end
                items[#items + 1] = it
            end
        end
    end
    local selItemTrackCount = 0
    for _ in pairs(selItemTrackSet) do selItemTrackCount = selItemTrackCount + 1 end

    local function formatDuration(seconds)
        if not seconds or seconds <= 0 then return nil end
        local mins = math.floor(seconds / 60)
        local secs = seconds - (mins * 60)
        if mins > 0 then
            return string.format("%d:%04.1f", mins, secs)
        end
        return string.format("%.1fs", secs)
    end

    local timeSelText = nil
    if hasTimeSel then
        timeSelectionStart = currentTimeStart
        timeSelectionEnd = currentTimeEnd
        timeSelectionMode = true
        local duration = currentTimeEnd - currentTimeStart
        timeSelText = formatDuration(duration)
    else
        timeSelectionMode = false
    end

    local useTimeSel = hasTimeSel and not HELPERS.hasExplicitOverlapSelection(currentTimeStart, currentTimeEnd)
    local timeSelResolved = HELPERS.getCachedTimeSelectionTargets(hasTimeSel, useTimeSel, rawSelTrackCount, rawSelItemCount)
    local timeSelItemCount = timeSelResolved and #timeSelResolved.items or 0
    local timeSelTrackCount = timeSelResolved and timeSelResolved.trackCount or 0
    if useTimeSel then
        timeSelTrackCount = timeSelResolved and timeSelResolved.trackCount or timeSelTrackCount
    end
    local timeSelTargetCount = timeSelItemCount
    local timeSelTargetIsItem = true
    if timeSelItemCount == 0 then
        timeSelTargetCount = timeSelTrackCount
        timeSelTargetIsItem = false
    end

    local autoItemCount = 0
    local autoItemDur = 0
    local autoItemsByTrack = {}
    if not useTimeSel and rawSelItemCount == 0 and rawSelTrackCount > 0 then
        for t = 0, rawSelTrackCount - 1 do
            local track = reaper.GetSelectedTrack(0, t)
            if track and AUDIBILITY.isTrackAudible(track, soloActiveFooter) then
                local numItems = reaper.CountTrackMediaItems(track)
                for i = 0, numItems - 1 do
                    local item = reaper.GetTrackMediaItem(track, i)
                    if item and AUDIBILITY.isItemAudible(item, soloActiveFooter) then
                        autoItemCount = autoItemCount + 1
                        autoItemDur = autoItemDur + (reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0)
                        local items = autoItemsByTrack[track]
                        if not items then
                            items = {}
                            autoItemsByTrack[track] = items
                        end
                        items[#items + 1] = item
                    end
                end
            end
        end
    end

    local displayTrackSet = {}
    for tr in pairs(selectedTrackSet) do displayTrackSet[tr] = true end
    for tr in pairs(selItemTrackSet) do displayTrackSet[tr] = true end
    local displayTrackCount = 0
    for _ in pairs(displayTrackSet) do displayTrackCount = displayTrackCount + 1 end
    local displayItemCount = selItemCount
    if not useTimeSel and displayItemCount == 0 and autoItemCount > 0 then
        displayItemCount = autoItemCount
    end

    local selectedStemCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or is6Stem) then
            selectedStemCount = selectedStemCount + 1
        end
    end

    local function trSingularPlural(n, keySingular, keyPlural)
        if (n or 0) == 1 then return T(keySingular) else return T(keyPlural) end
    end

    local function trSafe(key, fallback)
        local v = T(key)
        if not v or v == "" then return fallback end
        if v == key or v == key:gsub("_", " ") then return fallback end
        return v
    end

    local function summarizeNoTimeJobs(trackItemMap)
        local summary = {
            targetCount = 0,
            targetIsItem = false,
            outputStems = 0,
            folderCount = 0,
        }
        local trackCount = 0
        local jobCount = 0
        local anyPerItem = false

        for _, items in pairs(trackItemMap or {}) do
            local itemCount = #items
            if itemCount > 0 then
                trackCount = trackCount + 1
                if SETTINGS.createNewTracks then
                    if itemCount > 1 then
                        anyPerItem = true
                        jobCount = jobCount + itemCount
                    else
                        jobCount = jobCount + 1
                    end
                else
                    jobCount = jobCount + itemCount
                end
            end
        end

        if SETTINGS.createNewTracks then
            summary.targetIsItem = anyPerItem
            summary.targetCount = anyPerItem and jobCount or trackCount
            summary.folderCount = SETTINGS.createFolder and jobCount or 0
        else
            summary.targetIsItem = true
            summary.targetCount = jobCount
        end
        summary.outputStems = jobCount * selectedStemCount
        return summary
    end

    local function previewOutputSummary()
        local summary = {
            targetCount = 0,
            targetIsItem = false,
            outputStems = 0,
            folderCount = 0,
        }
        if selectedStemCount <= 0 then
            return summary
        end

        local useTimeSelNow = useTimeSel
        if timeSelectionMode == "time_selection" or selectionMode == "time_selection" then
            useTimeSelNow = true
        end

        if useTimeSelNow then
            summary.targetIsItem = (timeSelTargetIsItem and timeSelTargetCount > 0) or false
            summary.targetCount = timeSelTargetCount
            summary.outputStems = timeSelItemCount * selectedStemCount
            return summary
        end

        if rawSelItemCount > 0 then
            return summarizeNoTimeJobs(selectedItemsByTrack)
        end

        if rawSelTrackCount > 0 then
            return summarizeNoTimeJobs(autoItemsByTrack)
        end

        return summary
    end

    local summary = previewOutputSummary()
    local effectiveTargets = summary.targetCount
    local viaTimeSelection = useTimeSel
    if timeSelectionMode == "time_selection" or selectionMode == "time_selection" then
        viaTimeSelection = true
    end

    local trackUnit = trSingularPlural(displayTrackCount, "footer_track", "footer_tracks")
    local itemUnit = trSingularPlural(displayItemCount, "footer_item", "footer_items")
    local selLine

    local function trFmt(key, fallback, ...)
        local tpl = trSafe(key, fallback)
        return string.format(tpl, ...)
    end

    if viaTimeSelection then
        local unit = summary.targetIsItem and trSingularPlural(effectiveTargets, "footer_item", "footer_items") or trackUnit
        selLine = trFmt(
            "footer_line_target_time",
            "Target: %d %s (via time selection), %s time selection",
            effectiveTargets,
            unit,
            timeSelText or ""
        )
    else
        if rawSelTrackCount > 0 and rawSelItemCount == 0 then
            local explicitTrackUnit = trSingularPlural(selTrackCount, "footer_track", "footer_tracks")
            if autoItemCount > 0 then
                local autoItemUnit = trSingularPlural(autoItemCount, "footer_item", "footer_items")
                if selTrackCount == 1 then
                    selLine = trFmt(
                        "footer_line_selected_tracks_with_items",
                        "Selected: %d %s (with %d %s)",
                        selTrackCount,
                        explicitTrackUnit,
                        autoItemCount,
                        autoItemUnit
                    )
                else
                    selLine = trFmt(
                        "footer_line_selected_tracks_containing_items",
                        "Selected: %d %s (containing %d %s)",
                        selTrackCount,
                        explicitTrackUnit,
                        autoItemCount,
                        autoItemUnit
                    )
                end
            else
                selLine = trFmt(
                    "footer_line_selected_tracks_only",
                    "Selected: %d %s",
                    selTrackCount,
                    explicitTrackUnit
                )
            end
        elseif rawSelItemCount > 0 and rawSelTrackCount == 0 then
            local explicitItemUnit = trSingularPlural(selItemCount, "footer_item", "footer_items")
            local explicitItemTrackUnit = trSingularPlural(selItemTrackCount, "footer_track", "footer_tracks")
            selLine = trFmt(
                "footer_line_selected_items_on_tracks",
                "Selected: %d %s on %d %s",
                selItemCount,
                explicitItemUnit,
                selItemTrackCount,
                explicitItemTrackUnit
            )
        else
            selLine = trFmt(
                "footer_line_selected",
                "Selected: %d %s, %d %s",
                displayTrackCount,
                trackUnit,
                displayItemCount,
                itemUnit
            )
        end
    end

    local stemsPerTrack = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or is6Stem) then stemsPerTrack = stemsPerTrack + 1 end
    end

    local outLine
    local locLine
    local function stemUnit(n)
        if (n or 0) == 1 then return trSafe("stem", "stem") end
        return trSafe("stems", "stems")
    end
    local function stemTrackUnit(n)
        return trSingularPlural(n, "footer_stem_track", "footer_stem_tracks")
    end
    local function stemFolderUnit(n)
        return trSingularPlural(n, "footer_stem_folder", "footer_stem_folders")
    end

    if stemsPerTrack == 0 then
        outLine = "[!] " .. (T("no_stems_selected") or "No Stems Selected")
        locLine = T("please_select_stem") or "Please select stems in the center column."
    else
        if viaTimeSelection then
            local folderCountOut = summary.targetCount
            local totalOutputStems = summary.outputStems
            if SETTINGS.createNewTracks and SETTINGS.createFolder and folderCountOut > 0 then
                outLine = trFmt(
                    "footer_line_output_time_folders",
                    "Output: %d %s, %d %s from time selection",
                    folderCountOut,
                    stemFolderUnit(folderCountOut),
                    totalOutputStems,
                    stemTrackUnit(totalOutputStems)
                )
            else
                outLine = trFmt(
                    "footer_line_output_time",
                    "Output: %d %s from time selection",
                    totalOutputStems,
                    stemUnit(totalOutputStems)
                )
            end
            if timeSelText and timeSelText ~= "" then
                outLine = outLine .. " · " .. timeSelText
            end
        elseif SETTINGS.createNewTracks then
            local folderCountOut = (summary.folderCount or 0) > 0 and summary.folderCount or summary.targetCount
            local sourceCountOut = summary.targetCount
            local totalOutputStems = summary.outputStems
            local sourceUnitOut = summary.targetIsItem
                and trSingularPlural(sourceCountOut, "footer_item", "footer_items")
                or trSingularPlural(sourceCountOut, "footer_track", "footer_tracks")
            if SETTINGS.createFolder and folderCountOut > 0 then
                outLine = trFmt(
                    "footer_line_output_tracks_folders",
                    "Output: %d %s, %d %s from %d %s",
                    folderCountOut,
                    stemFolderUnit(folderCountOut),
                    totalOutputStems,
                    stemTrackUnit(totalOutputStems),
                    sourceCountOut,
                    sourceUnitOut
                )
            else
                outLine = trFmt(
                    "footer_line_output_tracks",
                    "Output: %d %s from %d %s",
                    totalOutputStems,
                    stemUnit(totalOutputStems),
                    sourceCountOut,
                    sourceUnitOut
                )
            end
        else
            local itemCountOut = summary.targetCount
            local itemDurOut = selItemDur
            if itemCountOut == 0 and autoItemCount > 0 then
                itemCountOut = autoItemCount
                itemDurOut = autoItemDur
            end
            local totalOutputStems = summary.outputStems
            local itemUnitOut = trSingularPlural(itemCountOut, "footer_item", "footer_items")
            outLine = trFmt(
                "footer_line_output_items",
                "Output: %d %s from %d %s",
                totalOutputStems,
                stemUnit(totalOutputStems),
                itemCountOut,
                itemUnitOut
            )
            local itemDurText = formatDuration(itemDurOut)
            if itemDurText and itemDurText ~= "" then
                outLine = outLine .. " · " .. itemDurText
            end
        end

        local selectedNames = {}
        for _, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or is6Stem) then
                table.insert(selectedNames, T(stem.name:lower()))
            end
        end
        local namesStr = table.concat(selectedNames, ", ")

        if SETTINGS.createNewTracks then
            local baseLoc
            if summary.targetIsItem and effectiveTargets > 1 then
                baseLoc = trSafe("footer_per_item_folders", "Per-item stem folders")
            else
                baseLoc = effectiveTargets > 1 and (trSafe("footer_per_track_folders", "Per-track stem folders")) or trSafe("footer_location_new_folder", "New folder")
            end
            locLine = trFmt(
                "footer_line_location_details",
                "Location: %s (%d: %s)",
                baseLoc,
                stemsPerTrack,
                namesStr
            )
        elseif SETTINGS.outputMode == "in-place" or not SETTINGS.createNewTracks then
            locLine = trFmt(
                "footer_line_location_details",
                "Location: %s (%d: %s)",
                trSafe("in_place", "In-place"),
                stemsPerTrack,
                namesStr
            )
        else
            locLine = trFmt(
                "footer_line_location_simple",
                "Location: %s",
                trSafe("footer_location_new_tracks", "New tracks")
            )
        end
    end

    if OS == "Windows" and GUI and GUI.windowsStartupMonitor and not hasAnySelection() then
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        selLine = tostring(promptTitle or "Start")
        outLine = tostring(promptMessage or "Select audio in REAPER")
        locLine = T("select_audio_tooltip") or "Choose audio in REAPER, then start STEMwerk."
    end

    local isWarning = (stemsPerTrack == 0)
    return { selLine = selLine, outLine = outLine, locLine = locLine, isWarning = isWarning }
end

function renderHelpTabs(ctx)
    if not ctx then return end
    local S = ctx.S
    local w = ctx.w or gfx.w
    local time = ctx.time or os.clock()
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local logoY = utilityMode and S(8) or S(12)
    local logoFontSize = utilityMode and S(21) or S(24)
    local logoAmp = utilityMode and S(1) or S(2)

    gfx.setfont(1, "Arial", logoFontSize, string.byte('b'))
    local logoStartX, _, logoTotalWidth, logoH = drawWavingStemwerkLogo({
        w = w,
        y = logoY,
        fontSize = logoFontSize,
        time = time,
        amp = logoAmp,
        speed = 3,
        phase = 0.5,
        alphaStem = 1,
        alphaRest = 0.9,
    })

    local mx, my = ctx.mx, ctx.my
    local logoHover = mx >= logoStartX and mx <= logoStartX + logoTotalWidth and my >= logoY and my <= logoY + logoH
    if logoHover then
        setTooltip(logoStartX, logoY, logoTotalWidth, logoH, T("tooltip_logo_help"))
        if gfx.mouse_cap & 1 == 1 and not GUI.logoWasClicked then
            GUI.logoWasClicked = true
        elseif gfx.mouse_cap & 1 == 0 and GUI.logoWasClicked then
            GUI.logoWasClicked = false
            GUI.result = "help"
        end
    end

    if not ctx.contentTop then
        ctx.contentTop = utilityMode and S(41) or S(45)
    end
end

function prepareDialogTopRightControls(ctx)
    if not ctx then return end
    local S = ctx.S
    local w = ctx.w
    local mx, my = ctx.mx, ctx.my
    local iconScale = 0.66
    local themeSize = math.max(S(12), math.floor(S(20) * iconScale + 0.5))
    local themeX = w - themeSize - S(10)
    local themeY = S(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local langW = S(22)
    local langH = S(14)
    local langX = themeX - langW - S(6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    local fxSize = math.max(S(10), math.floor(S(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + S(3)
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local fxHover = (not utilityMode) and mx >= fxX - S(2) and mx <= fxX + fxSize + S(2) and my >= fxY - S(2) and my <= fxY + fxSize + S(2)

    local controlsLeft = langX - S(10)
    local controlsBottom = utilityMode and (themeY + themeSize + S(6)) or (fxY + fxSize + S(6))
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = utilityMode and 1.0 or updateControlsOpacity(GUI, mouseInControls)

    ctx.ui = {
        iconScale = iconScale,
        themeSize = themeSize,
        themeX = themeX,
        themeY = themeY,
        themeHover = themeHover,
        langW = langW,
        langH = langH,
        langX = langX,
        langY = langY,
        langHover = langHover,
        fxSize = fxSize,
        fxX = fxX,
        fxY = fxY,
        fxHover = fxHover,
        controlsOpacity = controlsOpacity,
        uiRightClickBlock = themeHover or langHover or fxHover,
    }
end

function renderTopRightControls(ctx)
    local ui = ctx and ctx.ui
    if not ui then return end

    local S = ctx.S
    local mouseDown = ctx.mouseDown
    local rightMouseDown = ctx.rightMouseDown
    local controlsOpacity = ui.controlsOpacity
    local themeSize, themeX, themeY, themeHover = ui.themeSize, ui.themeX, ui.themeY, ui.themeHover
    local langW, langH, langX, langY, langHover = ui.langW, ui.langH, ui.langX, ui.langY, ui.langHover
    local fxSize, fxX, fxY, fxHover = ui.fxSize, ui.fxX, ui.fxY, ui.fxHover

    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    if utilityMode then
        UI_CONTROLS.drawUtilityControls({
            S = S,
            w = gfx.w,
            mx = gfx.mouse_x, my = gfx.mouse_y,
            mouseDown = mouseDown,
            rightMouseDown = ctx.rightMouseDown,
            state = GUI,
            setLanguageFn = setLanguage,
            themeX = themeX, themeY = themeY, themeSize = themeSize,
        })
        return
    end
    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)
        gfx.circle(themeX + themeSize/2 + 4, themeY + themeSize/2 - 3, themeSize/2 - 3, 1, 1)
    else
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/3, 1, 1)
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local x1 = themeX + themeSize/2 + math.cos(angle) * (themeSize/3 + 2)
            local y1 = themeY + themeSize/2 + math.sin(angle) * (themeSize/3 + 2)
            local x2 = themeX + themeSize/2 + math.cos(angle) * (themeSize/2 - 1)
            local y2 = themeY + themeSize/2 + math.sin(angle) * (themeSize/2 - 1)
            gfx.line(x1, y1, x2, y2)
        end
    end

    if themeHover and controlsOpacity > 0.3 then
        local themeTip = getThemeToggleTooltip()
        setTooltip(themeX, themeY, themeSize, themeSize, themeTip)
        if rightMouseDown and not mainDialogArt.wasRightMouseDown then
            cycleThemePreset()
        end
        if mouseDown and not GUI.wasMouseDown then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
    end

    gfx.setfont(1, "Arial", S(9), string.byte('b'))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    if langHover then
        gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    if langHover and controlsOpacity > 0.3 then
        setTooltip(langX, langY, langW, langH, T("tooltip_lang"))
        if rightMouseDown and not mainDialogArt.wasRightMouseDown then
            SETTINGS.tooltips = not SETTINGS.tooltips
            saveSettings()
        end
        if mouseDown and not GUI.wasMouseDown then
            local langs = {"en", "nl", "de"}
            local currentIdx = 1
            for i, l in ipairs(langs) do
                if l == SETTINGS.language then currentIdx = i break end
            end
            local nextIdx = (currentIdx % #langs) + 1
            setLanguage(langs[nextIdx])
            saveSettings()
        end
    end

    if not utilityMode then
        local fxAlpha = ((type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) and 0 or ((fxHover and 1 or 0.7) * controlsOpacity))
        if SETTINGS.visualFX then
            gfx.set(0.4, 0.9, 0.5, fxAlpha)
        else
            gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6)
        end
        gfx.setfont(1, "Arial", S(9), string.byte('b'))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2
        gfx.y = fxY + S(1)
        gfx.drawstr(fxText)

        if SETTINGS.visualFX then
            gfx.set(1, 1, 0.5, fxAlpha * 0.8)
            gfx.circle(fxX - S(1), fxY + S(2), S(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - S(2), S(1.5), 1, 1)
        else
            gfx.set(0.8, 0.3, 0.3, fxAlpha)
            gfx.line(fxX - S(1), fxY + fxSize / 2, fxX + fxSize + S(1), fxY + fxSize / 2)
        end

        if fxHover and controlsOpacity > 0.3 then
            local fxTip = SETTINGS.visualFX and (T("fx_disable") or "Disable FX") or (T("fx_enable") or "Enable FX")
            setTooltip(fxX - S(2), fxY - S(2), fxSize + S(4), fxSize + S(4), fxTip .. " " .. (T("fx_switch_native_suffix") or "Right-click: switch to REAPER Native UI."))
            if mouseDown and not GUI.wasMouseDown then
                SETTINGS.visualFX = not SETTINGS.visualFX
                saveSettings()
            end
            if rightMouseDown and not mainDialogArt.wasRightMouseDown then
                SETTINGS.themePreset = "reaper_native"
                updateTheme()
                saveSettings()
            end
        end
    end
end

function renderDialogBackground(ctx)
    if not ctx then return end
    GUI.uiClickedThisFrame = false

    if proceduralArt.seed == 0 then
        generateNewArt()
    end
    proceduralArt.time = (proceduralArt.time or 0) + 0.016

    local smoothing = 0.15
    mainDialogArt.zoom = mainDialogArt.zoom + (mainDialogArt.targetZoom - mainDialogArt.zoom) * smoothing
    mainDialogArt.panX = mainDialogArt.panX + (mainDialogArt.targetPanX - mainDialogArt.panX) * smoothing
    mainDialogArt.panY = mainDialogArt.panY + (mainDialogArt.targetPanY - mainDialogArt.panY) * smoothing
    mainDialogArt.rotation = mainDialogArt.rotation + (mainDialogArt.targetRotation - mainDialogArt.rotation) * smoothing

    prepareDialogTopRightControls(ctx)

    if ctx.mouseWheel ~= 0 then
        local zoomDelta = ctx.mouseWheel > 0 and 0.15 or -0.15
        mainDialogArt.targetZoom = math.max(0.3, math.min(5.0, mainDialogArt.targetZoom + zoomDelta))
        gfx.mouse_wheel = 0
    end

    local uiRightClickBlock = ctx.ui and ctx.ui.uiRightClickBlock
    if ctx.rightMouseDown and not uiRightClickBlock then
        if not mainDialogArt.wasRightMouseDown then
            mainDialogArt.isRotating = true
            mainDialogArt.rotateStartX = ctx.mx
            mainDialogArt.rotateStartAngle = mainDialogArt.targetRotation
        elseif mainDialogArt.isRotating then
            local deltaX = ctx.mx - mainDialogArt.rotateStartX
            mainDialogArt.targetRotation = mainDialogArt.rotateStartAngle + deltaX * 0.01
        end
    else
        mainDialogArt.isRotating = false
    end

    if ctx.mouseDown then
        if not mainDialogArt.wasMouseDown then
            mainDialogArt.clickStartX = ctx.mx
            mainDialogArt.clickStartY = ctx.my
            mainDialogArt.clickStartTime = os.clock()
            mainDialogArt.wasDrag = false
            mainDialogArt.dragStartPanX = mainDialogArt.targetPanX
            mainDialogArt.dragStartPanY = mainDialogArt.targetPanY
        else
            local dx = ctx.mx - mainDialogArt.clickStartX
            local dy = ctx.my - mainDialogArt.clickStartY
            local dragDist = math.sqrt(dx * dx + dy * dy)
            if dragDist > 5 then
                mainDialogArt.wasDrag = true
                mainDialogArt.isDragging = true
                mainDialogArt.targetPanX = mainDialogArt.dragStartPanX + dx
                mainDialogArt.targetPanY = mainDialogArt.dragStartPanY + dy
            end
        end
    else
        if mainDialogArt.wasMouseDown and not mainDialogArt.wasDrag then
            local clickDuration = os.clock() - (mainDialogArt.clickStartTime or 0)
            if clickDuration < 0.3 then
                mainDialogArt.pendingNewArt = true
                mainDialogArt.pendingNewArtX = mainDialogArt.clickStartX
                mainDialogArt.pendingNewArtY = mainDialogArt.clickStartY
            end
        end
        mainDialogArt.isDragging = false
    end

    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() and THEME and THEME.bg then
        gfx.set(THEME.bg[1], THEME.bg[2], THEME.bg[3], 1)
    elseif SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, ctx.w, ctx.h, 1)

    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
        drawProceduralArt(0, 0, ctx.w, ctx.h, proceduralArt.time, mainDialogArt.rotation, true)

        local overlayAlpha = getFxReadabilityOverlayAlpha()
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, overlayAlpha)
        else
            gfx.set(1, 1, 1, overlayAlpha)
        end
        gfx.rect(0, 0, ctx.w, ctx.h, 1)
    end

    renderTopRightControls(ctx)
end

function renderProcessingHeader(ctx)
    local proc = ctx and ctx.proc
    if not proc then return end

    local S = ctx.S
    local x, y, w = proc.x, proc.y, proc.w
    local btnH = proc.btnH
    local headerFont = proc.headerFont
    local btnFont = proc.btnFont

    y = y + S(8)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("processing_mode") or "Processing:", x, w, headerFont, y)
    setTooltip(x, y, w, S(16), T("tooltip_section_processing") or "Choose sequential or parallel processing.")
    gfx.setfont(1, "Arial", S(13))
    y = y + S(20)
    local modeLabel = SETTINGS.parallelProcessing and (T("parallel") or "Parallel") or (T("sequential") or "Sequential")
    if drawRadio(x, y, true, modeLabel, nil, w, nil, nil, btnFont) then
        SETTINGS.parallelProcessing = not SETTINGS.parallelProcessing
        saveSettings()
    end
    local modeTip = SETTINGS.parallelProcessing and T("tooltip_parallel") or T("tooltip_sequential")
    setTooltip(x, y, w, btnH, modeTip)

    y = y + S(28)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local tempHeaderY = y
    drawColumnHeader(T("temp_files") or "Temp files:", x, w, headerFont, tempHeaderY)
    setTooltip(x, tempHeaderY, w, S(16), T("tooltip_section_cleanup") or "Choose what happens to temporary working files after processing.")
    gfx.setfont(1, "Arial", S(13))

    y = tempHeaderY + S(20)
    local keepLabel = T("temp_files_keep") or "Keep"
    local deleteLabel = T("temp_files_delete") or "Delete"
    local tempLabel = SETTINGS.keepTempFiles and keepLabel or deleteLabel
    local tempR, tempG, tempB
    local _procUtility = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    if SETTINGS.keepTempFiles then
        tempR = THEME.accent[1] * 255
        tempG = THEME.accent[2] * 255
        tempB = THEME.accent[3] * 255
    elseif _procUtility then
        tempR, tempG, tempB = 179, 51, 51
    else
        tempR, tempG, tempB = 255, 120, 120
    end
    if drawCheckbox(x, y, true, tempLabel, tempR, tempG, tempB, w, btnFont) then
        SETTINGS.keepTempFiles = not SETTINGS.keepTempFiles
    end
    local tempTip = SETTINGS.keepTempFiles and T("tooltip_keep_temp_files") or T("tooltip_delete_temp_files")
    setTooltip(x, y, w, btnH, tempTip)

    proc.y = y
end

function renderMainColumns(ctx)
    if not ctx then return end
    local S = ctx.S
    local contentTop = ctx.contentTop or S(45)
    local is6Stem = ctx.is6Stem
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()

    gfx.setfont(1, "Arial", S(13))
    local mainHeaderFont = S(10)

    local gutter = S(10)
    local presetsW = S(64)
    local stemsW = S(64)
    local modelColW = S(72)
    local deviceColW = S(62)
    local outputColW = S(78)
    local afterColW = S(80)

    local col1X = S(10)
    local col2X = col1X + presetsW + gutter
    local col3X = col2X + stemsW + gutter
    local col4X = col3X + modelColW + gutter
    local col5X = col4X + deviceColW + gutter
    local col6X = col5X + outputColW + gutter

    local colW = presetsW
    local btnH = S(20)

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("presets"), col1X, presetsW, mainHeaderFont, contentTop)
    setTooltip(col1X, contentTop, presetsW, S(16), T("tooltip_section_presets") or "Quick choices for common stem sets.")

    local presetLabelKaraoke = (T("karaoke") or "Karaoke") .. " (K)"
    local presetLabelAll     = (T("all_stems") or "All")    .. " (A)"
    local presetLabelVocals  = (T("vocals") or "Vocals")    .. " (V)"
    local presetLabelDrums   = (T("drums") or "Drums")      .. " (D)"
    local presetLabelBass    = (T("bass") or "Bass")        .. " (B)"
    local presetLabelOther   = (T("other") or "Other")      .. " (O)"
    local presetLabelPiano   = (T("piano") or "Piano")      .. " (P)"
    local presetLabelGuitar  = (T("guitar") or "Guitar")    .. " (G)"
    local presetLabels = { presetLabelKaraoke, presetLabelAll, presetLabelVocals, presetLabelDrums, presetLabelBass, presetLabelOther }
    if is6Stem then
        presetLabels[#presetLabels + 1] = presetLabelPiano
        presetLabels[#presetLabels + 1] = presetLabelGuitar
    end
    -- In REAPER Native mode, use 72% font size on all buttons for calmer/denser labels.
    local _ubfs = utilityMode and math.max(S(8), math.floor(S(13) * 0.72 + 0.5)) or S(13)

    local presetsBtnFontSize = _ubfs

    local processingLabels = {
        T("parallel") or "Parallel",
        T("sequential") or "Sequential",
        T("temp_files_keep") or "Keep",
        T("temp_files_delete") or "Delete",
    }
    local processingBtnFontSize = _ubfs

    local presetY = contentTop + S(20)
    gfx.setfont(1, "Arial", S(13))

    local _utilDanger = utilityMode and {179, 51, 51} or {255, 120, 120}
    local _pa = {}
    if utilityMode then
        local function ss(i) return STEMS[i] and STEMS[i].selected or false end
        local v, d, b, o = ss(1), ss(2), ss(3), ss(4)
        local g, p = ss(5), ss(6)
        local no56 = not is6Stem or ((not g) and (not p))
        local yes56 = not is6Stem or (g and p)
        _pa.karaoke = (not v) and d and b and o and yes56
        _pa.all     = v and d and b and o and yes56
        _pa.vocals  = v and (not d) and (not b) and (not o) and no56
        _pa.drums   = (not v) and d and (not b) and (not o) and no56
        _pa.bass    = (not v) and (not d) and b and (not o) and no56
        _pa.other   = (not v) and (not d) and (not b) and o and no56
        _pa.guitar  = is6Stem and (not v) and (not d) and (not b) and (not o) and g and (not p)
        _pa.piano   = is6Stem and (not v) and (not d) and (not b) and (not o) and (not g) and p
    end
    local function drawPresetBtn(py, label, rawColor, isActive)
        if utilityMode then
            return drawRadio(col1X, py, isActive, label, nil, colW, nil, nil, presetsBtnFontSize)
        end
        return drawButton(col1X, py, colW, btnH, label, false, rawColor, presetsBtnFontSize)
    end
    if drawPresetBtn(presetY, presetLabelKaraoke, {80, 80, 90}, _pa.karaoke) then applyPresetKaraoke() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_karaoke"), "K", {255, 200, 100})
    presetY = presetY + S(22)
    if drawPresetBtn(presetY, presetLabelAll, {80, 80, 90}, _pa.all) then applyPresetAll() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_all"), "A", {255, 200, 100})

    presetY = presetY + S(28)

    if drawPresetBtn(presetY, presetLabelVocals, {255, 100, 100}, _pa.vocals) then applyPresetVocalsOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_vocals"), "V", {255, 100, 100})
    presetY = presetY + S(22)
    if drawPresetBtn(presetY, presetLabelDrums, {100, 200, 255}, _pa.drums) then applyPresetDrumsOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_drums"), "D", {100, 200, 255})
    presetY = presetY + S(22)
    if drawPresetBtn(presetY, presetLabelBass, {150, 100, 255}, _pa.bass) then applyPresetBassOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_bass"), "B", {150, 100, 255})
    presetY = presetY + S(22)
    if drawPresetBtn(presetY, presetLabelOther, {100, 255, 150}, _pa.other) then applyPresetOtherOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_other"), "O", {100, 255, 150})
    presetY = presetY + S(22)

    if is6Stem then
        if drawPresetBtn(presetY, presetLabelGuitar, {255, 180, 100}, _pa.guitar) then applyPresetGuitarOnly() end
        setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_guitar"), "G", {255, 180, 100})
        presetY = presetY + S(22)
        if drawPresetBtn(presetY, presetLabelPiano, {255, 120, 200}, _pa.piano) then applyPresetPianoOnly() end
        setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_piano"), "P", {255, 120, 200})
        presetY = presetY + S(22)
    end

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(is6Stem and T("stems_6") or "Stems:", col2X, stemsW, mainHeaderFont, contentTop)
    setTooltip(col2X, contentTop, stemsW, S(16), T("tooltip_section_stems") or "Choose which stems to create.")

    local stemY = contentTop + S(20)
    gfx.setfont(1, "Arial", S(13))
    local stemTooltipKeys = {
        Vocals = "tooltip_stem_vocals",
        Drums = "tooltip_stem_drums",
        Bass = "tooltip_stem_bass",
        Other = "tooltip_stem_other",
        Guitar = "tooltip_stem_guitar",
        Piano = "tooltip_stem_piano"
    }
    local stemLabels = {}
    for _, st in ipairs(STEMS) do
        if not st.sixStemOnly or is6Stem then
            local k = tostring(st.name or ""):lower()
            local dn = T(k) or st.name
            stemLabels[#stemLabels + 1] = tostring(dn) .. " (" .. st.key .. ")"
        end
    end
    local stemsBtnFontSize = _ubfs

    for i, stem in ipairs(STEMS) do
        if not stem.sixStemOnly or is6Stem then
            local k = tostring(stem.name or ""):lower()
            local displayName = T(k) or stem.name
            local label = tostring(displayName) .. " (" .. stem.key .. ")"
            local clicked
            if utilityMode then
                clicked = drawRadio(col2X, stemY, stem.selected, label, nil, colW, nil, nil, stemsBtnFontSize)
            else
                clicked = drawToggleButton(col2X, stemY, colW, btnH, label, stem.selected, stem.color, stemsBtnFontSize)
            end
            if clicked then toggleStemSelection(i) end
            local tooltipKey = stemTooltipKeys[stem.name] or "tooltip_stem_other"
            setTooltipWithShortcut(col2X, stemY, colW, btnH, T(tooltipKey), stem.key, stem.color)
            stemY = stemY + S(22)
        end
    end

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("model"), col3X, modelColW, mainHeaderFont, contentTop)
    setTooltip(col3X, contentTop, modelColW, S(16), T("tooltip_section_model") or "Choose speed/quality and stem model.")
    gfx.setfont(1, "Arial", S(13))

    local modelBoxW = modelColW
    local modelLabels = {}
    for i = 1, #MODELS do
        modelLabels[#modelLabels + 1] = MODELS[i].name
    end
    modelLabels[#modelLabels + 1] = T("parallel")
    modelLabels[#modelLabels + 1] = T("sequential")
    local modelBtnFontSize = _ubfs

    local modelY = contentTop + S(20)
    local modelDescKeys = {
        htdemucs = "model_fast_desc",
        htdemucs_ft = "model_quality_desc",
        htdemucs_6s = "model_6stem_desc",
    }
    local modelShortcutKeys = {
        htdemucs = "F",
        htdemucs_ft = "Q",
        htdemucs_6s = "S",
    }
    for _, model in ipairs(MODELS) do
        local modelAvailable = isModelAvailableInCurrentMode(model.id)
        local modelColor = modelAvailable and nil or {120, 120, 120}
        local modelDisplayName = model.name
        if utilityMode then
            local mk = modelShortcutKeys[model.id]
            if mk then modelDisplayName = model.name .. " (" .. mk .. ")" end
        end
        if drawRadio(col3X, modelY, SETTINGS.model == model.id, modelDisplayName, nil, modelBoxW, nil, nil, modelBtnFontSize) and modelAvailable then
            setModelPreservingStemIntent(model.id)
        end
        local descKey = modelDescKeys[model.id] or "model_fast_desc"
        local tip = T(descKey)
        if not modelAvailable then
            tip = tostring(tip or "") .. "\n\n" .. unavailableModelTooltipSuffix()
        end
        setTooltipWithShortcut(col3X, modelY, modelBoxW, btnH, tip, modelShortcutKeys[model.id] or "?", {255, 200, 100})
        modelY = modelY + S(22)
    end

    ctx.proc = {
        x = col3X,
        y = modelY,
        w = modelBoxW,
        btnH = btnH,
        headerFont = mainHeaderFont,
        btnFont = processingBtnFontSize,
    }
    renderProcessingHeader(ctx)
    ctx.proc = nil

    drawDeviceColumn(col4X, deviceColW, contentTop, btnH, modelBtnFontSize, mainHeaderFont)

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("output"), col5X, outputColW, mainHeaderFont, contentTop)
    setTooltip(col5X, contentTop, outputColW, S(16), T("tooltip_section_output") or "Choose where STEMwerk imports the results in REAPER.")
    gfx.setfont(1, "Arial", S(13))

    local outBoxW = outputColW

    local stemCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or is6Stem) then
            stemCount = stemCount + 1
        end
    end
    local stemPlural = stemCount ~= 1
    local newTracksLabel = stemPlural and T("new_tracks") or T("new_track")
    local inPlaceLabel = T("in_place")

    local outputBtnFontSize = _ubfs
    local afterBtnFontSize = _ubfs

    local outY = contentTop + S(20)
    if drawRadio(col5X, outY, SETTINGS.createNewTracks, newTracksLabel, nil, outBoxW, nil, nil, outputBtnFontSize) then
        SETTINGS.createNewTracks = true
        SETTINGS.postProcessTakes = "none"
    end
    setTooltip(col5X, outY, outBoxW, btnH, T("tooltip_new_tracks"))
    outY = outY + S(22)
    if drawRadio(col5X, outY, not SETTINGS.createNewTracks, inPlaceLabel, nil, outBoxW, nil, nil, outputBtnFontSize) then
        SETTINGS.createNewTracks = false
    end
    setTooltip(col5X, outY, outBoxW, btnH, T("tooltip_in_place"))

    outY = outY + S(28)
    local groupingEnabled = SETTINGS.createNewTracks == true
    local groupingTooltipBlocked = T("tooltip_grouping_new_tracks_only") or "Grouping only applies to New Tracks output."
    local groupingHeaderCol = groupingEnabled and THEME.textDim or THEME.textHint
    gfx.set(groupingHeaderCol[1], groupingHeaderCol[2], groupingHeaderCol[3], 1)
    drawColumnHeader(T("grouping_label"), col5X, outBoxW, mainHeaderFont, outY)
    gfx.setfont(1, "Arial", S(13))
    local groupingHeaderTip = T("tooltip_section_grouping") or "Choose whether selected items get separate output groups or share one group per source track."
    if groupingEnabled then
        setTooltip(col5X, outY, outBoxW, S(16), groupingHeaderTip)
    else
        setTooltip(col5X, outY, outBoxW, S(16), groupingTooltipBlocked)
    end

    SETTINGS.outputGrouping = normalizeOutputGrouping(SETTINGS.outputGrouping)
    outY = outY + S(20)
    local groupingBtnColor = groupingEnabled
        and { THEME.accent[1] * 255, THEME.accent[2] * 255, THEME.accent[3] * 255 }
        or {130, 130, 130}
    local clickedPerItem = drawRadio(col5X, outY, SETTINGS.outputGrouping == "per_item", T("grouping_per_item"), groupingBtnColor, outBoxW, nil, nil, outputBtnFontSize)
    if groupingEnabled and clickedPerItem then
        SETTINGS.outputGrouping = "per_item"
    end
    setTooltip(col5X, outY, outBoxW, btnH, groupingEnabled and T("tooltip_grouping_per_item") or groupingTooltipBlocked)

    outY = outY + S(22)
    local clickedPerSourceTrack = drawRadio(col5X, outY, SETTINGS.outputGrouping == "source_track", T("grouping_per_source_track"), groupingBtnColor, outBoxW, nil, nil, outputBtnFontSize)
    if groupingEnabled and clickedPerSourceTrack then
        SETTINGS.outputGrouping = "source_track"
    end
    setTooltip(col5X, outY, outBoxW, btnH, groupingEnabled and T("tooltip_grouping_per_source_track") or groupingTooltipBlocked)

    outY = outY + S(28)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(HELPERS.getStemFilesHeaderLabel(), col5X, outBoxW, mainHeaderFont, outY)
    setTooltip(col5X, outY, outBoxW, S(16), T("tooltip_section_storage") or "Choose where generated stem files are stored.")
    gfx.setfont(1, "Arial", S(13))

    outY = outY + S(20)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "temp", "Temp", nil, outBoxW, nil, nil, outputBtnFontSize) then
        SETTINGS.stemFileDestination = "temp"
    end
    setTooltip(col5X, outY, outBoxW, btnH, HELPERS.getStemFilesTempTooltip())

    outY = outY + S(22)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "project_media", HELPERS.getStemFileProjectLabel(), nil, outBoxW, nil, nil, outputBtnFontSize) then
        SETTINGS.stemFileDestination = "project_media"
    end
    setTooltip(col5X, outY, outBoxW, btnH, HELPERS.getStemFilesProjectTooltip())

    outY = outY + S(22)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "custom", HELPERS.getStemFileCustomLabel(), nil, outBoxW, nil, nil, outputBtnFontSize) then
        SETTINGS.stemFileDestination = "custom"
    end
    setTooltip(col5X, outY, outBoxW, btnH, HELPERS.getStemFilesCustomTooltip())

    if SETTINGS.stemFileDestination == "custom" then
        outY = outY + S(22)
        local customPathLabel = HELPERS.trimString(SETTINGS.customStemDir)
        if customPathLabel == "" then
            customPathLabel = HELPERS.getSetCustomPathLabel()
        elseif #customPathLabel > 24 then
            customPathLabel = "..." .. customPathLabel:sub(-21)
        end
        if UI_PATH_INPUT.hasBrowse() then
            if drawButton(col5X, outY, outBoxW, btnH, customPathLabel, false, {80, 80, 90}, outputBtnFontSize) then
                openCustomFolderDialog()
            end
            if ctx.rightMouseDown and ctx.mx >= col5X and ctx.mx <= col5X + outBoxW and ctx.my >= outY and ctx.my <= outY + btnH then
                openCustomFolderDialogManual()
            end
            local _bHint = T("path_browse_folder_hint") or "Browse for custom stem folder."
            local _curDir = HELPERS.trimString(SETTINGS.customStemDir)
            local _curLbl = T("path_current_label") or "Current:"
            local _curVal = (_curDir ~= "") and _curDir or (T("path_not_set") or "not set")
            local _rcHint = T("path_rightclick_manual_hint") or "Right-click: type or paste path manually."
            setTooltip(col5X, outY, outBoxW, btnH, _bHint .. "\n" .. _curLbl .. " " .. _curVal .. "\n" .. _rcHint)
        else
            if drawButton(col5X, outY, outBoxW, btnH, customPathLabel, false, {80, 80, 90}, outputBtnFontSize) then
                openCustomFolderDialogManual()
            end
            setTooltip(col5X, outY, outBoxW, btnH, HELPERS.trimString(SETTINGS.customStemDir) ~= "" and SETTINGS.customStemDir or HELPERS.getStemFilesCustomPathTooltip())
        end
    end

    if SETTINGS.createNewTracks then
        local posR = THEME.accent[1] * 255
        local posG = THEME.accent[2] * 255
        local posB = THEME.accent[3] * 255
        local afterY = contentTop + S(20)
        local afterBoxW = afterColW

        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        drawColumnHeader(T("after"), col6X, afterBoxW, mainHeaderFont, contentTop)
        setTooltip(col6X, contentTop, afterBoxW, S(16), T("tooltip_section_after") or "Optional actions to apply after processing.")
        gfx.setfont(1, "Arial", S(13))

        if drawRadio(col6X, afterY, true, HELPERS.getColorModeButtonLabel(), HELPERS.getColorModeButtonColor(), afterBoxW, nil, nil, afterBtnFontSize) then
            HELPERS.cycleColorMode()
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, HELPERS.getColorModeTooltip())
        afterY = afterY + S(22)

        if drawCheckbox(col6X, afterY, SETTINGS.createFolder, T("create_folder"), posR, posG, posB, afterBoxW, afterBtnFontSize) then
            SETTINGS.createFolder = not SETTINGS.createFolder
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_create_folder"))

        afterY = afterY + S(22)
        if drawCheckbox(col6X, afterY, SETTINGS.muteOriginal, T("mute_original"), posR, posG, posB, afterBoxW, afterBtnFontSize) then
            SETTINGS.muteOriginal = not SETTINGS.muteOriginal
            if SETTINGS.muteOriginal then
                SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false; SETTINGS.muteOriginalTrack = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_mute_original"))

        afterY = afterY + S(22)
        local delItemColor = SETTINGS.deleteOriginal and _utilDanger or {160, 160, 160}
        if drawCheckbox(col6X, afterY, SETTINGS.deleteOriginal, T("delete_original"), delItemColor[1], delItemColor[2], delItemColor[3], afterBoxW, afterBtnFontSize) then
            SETTINGS.deleteOriginal = not SETTINGS.deleteOriginal
            if SETTINGS.deleteOriginal then
                SETTINGS.muteOriginal = false; SETTINGS.muteOriginalTrack = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_original"))

        afterY = afterY + S(22)
        local delTrackColor = SETTINGS.deleteOriginalTrack and _utilDanger or {160, 160, 160}
        if drawCheckbox(col6X, afterY, SETTINGS.deleteOriginalTrack, T("delete_track"), delTrackColor[1], delTrackColor[2], delTrackColor[3], afterBoxW, afterBtnFontSize) then
            SETTINGS.deleteOriginalTrack = not SETTINGS.deleteOriginalTrack
            if SETTINGS.deleteOriginalTrack then
                SETTINGS.deleteOriginal = true; SETTINGS.muteOriginal = false; SETTINGS.muteOriginalTrack = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_track"))

        afterY = afterY + S(22)
        local muteTrackColor = SETTINGS.muteOriginalTrack and {posR, posG, posB} or {160, 160, 160}
        if drawCheckbox(col6X, afterY, SETTINGS.muteOriginalTrack, T("mute_track"), muteTrackColor[1], muteTrackColor[2], muteTrackColor[3], afterBoxW, afterBtnFontSize) then
            SETTINGS.muteOriginalTrack = not SETTINGS.muteOriginalTrack
            if SETTINGS.muteOriginalTrack then
                SETTINGS.muteOriginal = false; SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_mute_track"))

        local hasTimeSel = hasTimeSelection()
        if hasTimeSel then
            afterY = afterY + S(22)
            if drawCheckbox(col6X, afterY, SETTINGS.muteSelection, T("mute_selection"), posR, posG, posB, afterBoxW, afterBtnFontSize) then
                SETTINGS.muteSelection = not SETTINGS.muteSelection
                if SETTINGS.muteSelection then
                    SETTINGS.muteOriginal = false; SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false; SETTINGS.muteOriginalTrack = false
                    SETTINGS.deleteSelection = false
                end
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_mute_selection"))

            afterY = afterY + S(22)
            local delSelColor = SETTINGS.deleteSelection and _utilDanger or {160, 160, 160}
            if drawCheckbox(col6X, afterY, SETTINGS.deleteSelection, T("delete_selection"), delSelColor[1], delSelColor[2], delSelColor[3], afterBoxW, afterBtnFontSize) then
                SETTINGS.deleteSelection = not SETTINGS.deleteSelection
                if SETTINGS.deleteSelection then
                    SETTINGS.muteOriginal = false; SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false; SETTINGS.muteOriginalTrack = false
                    SETTINGS.muteSelection = false
                end
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_selection"))
        end

    else
        local afterY = contentTop + S(20)
        local afterBoxW = afterColW
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        drawColumnHeader(T("after"), col6X, afterBoxW, mainHeaderFont, contentTop)
        setTooltip(col6X, contentTop, afterBoxW, S(16), T("tooltip_section_after") or "Optional actions to apply after processing.")
        gfx.setfont(1, "Arial", S(13))

        local selectedMultiTakeCount = getSelectedMultiTakeCountRespectingTimeSelection()
        local pulseMult = 0
        if selectedMultiTakeCount > 0 then
            local t = os.clock() or 0
            pulseMult = 0.85 + 0.25 * (0.5 + 0.5 * math.sin(t * 6.0))
        end

        local mode = tostring(SETTINGS.postProcessTakes or "none")

        if drawRadio(col6X, afterY, true, HELPERS.getColorModeButtonLabel(), HELPERS.getColorModeButtonColor(), afterBoxW, nil, nil, afterBtnFontSize) then
            HELPERS.cycleColorMode()
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, HELPERS.getColorModeTooltip())

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "none", T("keep_takes"), nil, afterBoxW, nil, nil, afterBtnFontSize) then
            SETTINGS.postProcessTakes = "none"
            mode = "none"
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_keep_takes"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_new_tracks", stripExplodePrefix(T("explode_to_new_tracks")), nil, afterBoxW, pulseMult, "explode", afterBtnFontSize) then
            SETTINGS.postProcessTakes = "explode_new_tracks"
            mode = "explode_new_tracks"
            applyPostProcessToSelectedCandidates(mode)
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_explode_to_new_tracks"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_in_place", stripExplodePrefix(T("explode_in_place")), nil, afterBoxW, pulseMult, "explode", afterBtnFontSize) then
            SETTINGS.postProcessTakes = "explode_in_place"
            mode = "explode_in_place"
            applyPostProcessToSelectedCandidates(mode)
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_explode_in_place"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_in_order", stripExplodePrefix(T("explode_in_order")), nil, afterBoxW, pulseMult, "explode", afterBtnFontSize) then
            SETTINGS.postProcessTakes = "explode_in_order"
            mode = "explode_in_order"
            applyPostProcessToSelectedCandidates(mode)
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_explode_in_order"))
    end
end

function renderFooter(ctx)
    if not ctx then return end
    local S = ctx.S
    local w, h = ctx.w, ctx.h
    local btnH = S(20)
    local stemBtnW = S(70)

    local statusFontSize = S(9)
    local statusSubFontSize = S(8)
    local statusPadX = S(10)
    local statusBlockPadY = S(6)
    local statusRowGap = S(2)
    local statusBlockAlpha = 0.7
    local statusBlockBorderAlpha = 0.75

    gfx.setfont(1, "Arial", statusFontSize)
    local statusLineH = gfx.texth
    gfx.setfont(1, "Arial", statusSubFontSize)
    local statusSubLineH = gfx.texth
    local statusBlockH = statusLineH + statusSubLineH + statusBlockPadY * 2 + statusRowGap
    local statusBarH = statusBlockH
    local statusBarY = h - statusBarH
    local footerTooltipText = nil
    local footerTooltipX, footerTooltipY = 0, 0
    local function setFooterTooltip(x, y, ww, hh, text)
        if SETTINGS and SETTINGS.tooltips == false then return end
        if not text or text == "" then return end
        if ctx.mx >= x and ctx.mx <= x + ww and ctx.my >= y and ctx.my <= y + hh then
            footerTooltipText = text
            footerTooltipX = ctx.mx + S(10)
            footerTooltipY = ctx.my + S(15)
        end
    end

    local footerRow4Y = statusBarY - S(10) - btnH
    local footerLines = buildFooterLines()
    local selLine = footerLines.selLine or ""
    local outLine = footerLines.outLine or ""
    local outDuration = nil
    do
        local outMain, duration = tostring(outLine):match("^(.-)%s+·%s+([^·]+)$")
        if outMain and duration and duration ~= "" then
            outLine = outMain
            outDuration = duration
        end
    end
    local locLine = footerLines.locLine or ""
    local isWarning = footerLines.isWarning

    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], statusBlockAlpha)
    gfx.rect(0, statusBarY, w, statusBlockH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], statusBlockBorderAlpha)
    gfx.rect(0, statusBarY, w, statusBlockH, 0)

    local availableW = w - statusPadX * 2
    local splitGap = S(16)
    local leftW = math.max(S(180), math.floor((availableW - splitGap) * 0.48))
    local rightW = math.max(S(180), availableW - leftW - splitGap)
    local row1Y = statusBarY + statusBlockPadY
    local row2Y = row1Y + statusLineH + statusRowGap

    gfx.setfont(1, "Arial", statusFontSize)
    local selLabel = fitTextToBox(selLine, leftW, statusFontSize, statusFontSize)
    local outLabel, outTw = fitTextToBox(outLine, rightW, statusFontSize, statusFontSize)

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    gfx.x = statusPadX
    gfx.y = row1Y
    gfx.drawstr(selLabel)
    setFooterTooltip(statusPadX, row1Y, leftW, statusLineH, T("tooltip_footer_selected") or "Shows how many selected items and source tracks will be processed.")

    if isWarning then
        gfx.set(1, 0.3, 0.3, 1)
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    end
    gfx.x = w - statusPadX - outTw
    gfx.y = row1Y
    gfx.drawstr(outLabel)
    setFooterTooltip(w - statusPadX - rightW, row1Y, rightW, statusLineH, T("tooltip_footer_output") or "Shows how many stem outputs will be created from the current selection.")

    gfx.setfont(1, "Arial", statusSubFontSize)
    local durationLabel = nil
    local durationW = 0
    if outDuration and outDuration ~= "" then
        local durationPrefix = T("footer_audio_total") or "Audio total"
        local durationText = tostring(outDuration)
        if durationText:find(":") and not durationText:find("%a") then
            durationText = durationText .. " min"
        end
        durationLabel = tostring(durationPrefix) .. ": " .. durationText
        durationW = gfx.measurestr(durationLabel)
    end
    local locMaxW = availableW
    if durationLabel then
        locMaxW = math.max(S(120), availableW - durationW - splitGap)
    end
    local locLabel = fitTextToBox(locLine, locMaxW, statusSubFontSize, statusSubFontSize)
    if isWarning then
        gfx.set(1, 0.35, 0.35, 0.95)
    else
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.82)
    end
    gfx.x = statusPadX
    gfx.y = row2Y
    gfx.drawstr(locLabel)
    setFooterTooltip(statusPadX, row2Y, locMaxW, statusSubLineH, T("tooltip_footer_location") or "Shows the current output grouping/storage plan.")

    if durationLabel then
        if isWarning then
            gfx.set(1, 0.35, 0.35, 0.95)
        else
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.82)
        end
        gfx.x = w - statusPadX - durationW
        gfx.y = row2Y
        gfx.drawstr(durationLabel)
    end

    local footerMarginX = S(10)
    local stemBtnX = w - footerMarginX - stemBtnW
    local mx, my = ctx.mx, ctx.my
    local stemBtnHover = mx >= stemBtnX and mx <= stemBtnX + stemBtnW and my >= footerRow4Y and my <= footerRow4Y + btnH
    local stemBtnColor = stemBtnHover and THEME.buttonPrimaryHover or THEME.buttonPrimary

    drawGlossyPill(stemBtnX, footerRow4Y, stemBtnW, btnH, stemBtnColor[1], stemBtnColor[2], stemBtnColor[3])

    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local _fbf = utilityMode and math.max(S(9), math.floor(S(13) * 0.82 + 0.5)) or S(13)
    gfx.setfont(1, "Arial", _fbf, string.byte('b'))
    local textY = footerRow4Y + (btnH - gfx.texth) / 2

    local actionText = T("process_action") or "Process"
    local actionW = gfx.measurestr(actionText)
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.x = stemBtnX + (stemBtnW - actionW) / 2
    gfx.y = textY
    gfx.drawstr(actionText)

    setRichTooltip(stemBtnX, footerRow4Y, stemBtnW, btnH)

    if stemBtnHover and GUI.wasMouseDown and not ctx.mouseDown then
        if canStartProcessingFromDialog() then
            saveSettings()
            GUI.result = true
        end
    end

    local closeBtnX = footerMarginX
    local closeBtnW = stemBtnW
    local closeBtnHover = mx >= closeBtnX and mx <= closeBtnX + closeBtnW and my >= footerRow4Y and my <= footerRow4Y + btnH

    if utilityMode then
        local closeCol = closeBtnHover and (THEME.buttonHover or THEME.button) or THEME.button
        closeCol = closeCol or {0.24, 0.24, 0.24}
        drawGlossyPill(closeBtnX, footerRow4Y, closeBtnW, btnH, closeCol[1], closeCol[2], closeCol[3])
    else
        local closeR, closeG, closeB = 0.7, 0.2, 0.2
        if closeBtnHover then
            closeR, closeG, closeB = 0.9, 0.3, 0.3
        end
        drawGlossyPill(closeBtnX, footerRow4Y, closeBtnW, btnH, closeR, closeG, closeB)
    end

    gfx.setfont(1, "Arial", _fbf, string.byte('b'))
    local closeText = T("close") or "Close"
    local closeTextW = gfx.measurestr(closeText)
    local closeTextX = closeBtnX + (closeBtnW - closeTextW) / 2
    local closeTextY = footerRow4Y + (btnH - gfx.texth) / 2
    if utilityMode then
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x, gfx.y = closeTextX, closeTextY
        gfx.drawstr(closeText)
    else
        gfx.set(0, 0, 0, 0.4)
        gfx.x, gfx.y = closeTextX + 2, closeTextY + 2; gfx.drawstr(closeText)
        gfx.set(0, 0, 0, 0.6)
        gfx.x, gfx.y = closeTextX + 1, closeTextY + 1; gfx.drawstr(closeText)
        gfx.x, gfx.y = closeTextX - 1, closeTextY + 1; gfx.drawstr(closeText)
        gfx.x, gfx.y = closeTextX + 1, closeTextY - 1; gfx.drawstr(closeText)
        gfx.x, gfx.y = closeTextX - 1, closeTextY - 1; gfx.drawstr(closeText)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = closeTextX, closeTextY
        gfx.drawstr(closeText)
    end

    if closeBtnHover and GUI.wasMouseDown and not ctx.mouseDown then
        GUI.result = false
    end
    setFooterTooltip(closeBtnX, footerRow4Y, closeBtnW, btnH, T("tooltip_close"))
    if footerTooltipText and not GUI.richTooltip and not GUI.shortcutTooltip then
        GUI.tooltip = footerTooltipText
        GUI.tooltipX = footerTooltipX
        GUI.tooltipY = footerTooltipY
    end

    GUI.wasMouseDown = ctx.mouseDown
end

openDialogWarning = function(title, message)
    GUI.modal = {
        title = title or "Warning",
        message = message or "",
        icon = "warning",
    }
    GUI.modalWasMouseDown = false
end

openCustomFolderDialogManual = function()
    GUI.modal = {
        mode = "path_input",
        title = HELPERS.getCustomFolderPromptTitle(),
        message = HELPERS.getStemFilesCustomPathTooltip(),
        inputLabel = HELPERS.getCustomFolderPromptLabel(),
        inputValue = tostring(SETTINGS.customStemDir or ""),
        icon = "info",
        onSubmit = function(value)
            SETTINGS.customStemDir = HELPERS.trimString(value)
            saveSettings()
        end,
    }
    GUI.modalWasMouseDown = false
end

openCustomFolderDialog = function()
    if UI_PATH_INPUT.hasBrowse() then
        local dir = UI_PATH_INPUT.browseForFolder(SETTINGS.customStemDir or "")
        if dir and dir ~= "" then
            SETTINGS.customStemDir = HELPERS.trimString(dir)
            saveSettings()
        end
        return
    end
    openCustomFolderDialogManual()
end

canStartProcessingFromDialog = function()
    if OS == "Windows" and GUI and GUI.windowsStartupMonitor and not hasAnySelection() then
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        openDialogWarning(promptTitle, promptMessage)
        return false
    end
    if not isModelAvailableInCurrentMode(tostring(SETTINGS.model or "")) then
        local unavailableTitle = T("model_unavailable_title") or "Model unavailable"
        local unavailableMessage = T("model_unavailable_message") or "The selected model is not available in this installer variant."
        openDialogWarning(
            unavailableTitle,
            unavailableMessage .. "\n\n" .. unavailableModelTooltipSuffix()
        )
        return false
    end

    local is6Stem = isEffectiveRun6Stem()
    local validSelected = false
    for _, stem in ipairs(STEMS) do
        if stem.selected and ((not stem.sixStemOnly) or is6Stem) then
            validSelected = true
            break
        end
    end
    if not validSelected then
        ensureAtLeastOneStemSelected()
        validSelected = countSelectableSelectedStems(nil) > 0
    end
    if not validSelected then
        openDialogWarning(
            T("no_stems_selected") or "No Stems Selected",
            T("please_select_stem") or "Please select at least one stem."
        )
        return false
    end

    if tostring(SETTINGS.stemFileDestination or "temp") == "custom" and HELPERS.trimString(SETTINGS.customStemDir) == "" then
        openDialogWarning(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesMissingCustomWarning())
        return false
    end

    if tostring(SETTINGS.stemFileDestination or "temp") == "project_media" and not HELPERS.getProjectMediaDir() then
        openDialogWarning(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesProjectUnavailableWarning())
        return false
    end

    return true
end

function handleDialogKeyboard(ctx)
    local char = gfx.getchar()
    ctx.char = char

    if char == 27 then
        GUI.result = false
    elseif char == 26161 then
        GUI.result = "help"
    elseif char == 13 or char == 32 then
        if canStartProcessingFromDialog() then
            GUI.result = true
        end
    elseif char == 49 then toggleStemSelection(1)
    elseif char == 50 then toggleStemSelection(2)
    elseif char == 51 then toggleStemSelection(3)
    elseif char == 52 then toggleStemSelection(4)
    elseif char == 53 and SETTINGS.model == "htdemucs_6s" then toggleStemSelection(5)
    elseif char == 54 and SETTINGS.model == "htdemucs_6s" then toggleStemSelection(6)
    elseif char == 118 or char == 86 then applyPresetVocalsOnly()
    elseif char == 100 or char == 68 then applyPresetDrumsOnly()
    elseif char == 98 or char == 66 then applyPresetBassOnly()
    elseif char == 111 or char == 79 then applyPresetOtherOnly()
    elseif char == 112 or char == 80 then applyPresetPianoOnly()
    elseif char == 103 or char == 71 then applyPresetGuitarOnly()
    elseif char == 107 or char == 75 then applyPresetKaraoke()
    elseif char == 105 or char == 73 then applyPresetKaraoke()
    elseif char == 97 or char == 65 then applyPresetAll()
    elseif char == 102 or char == 70 then
        if isModelAvailableInCurrentMode("htdemucs") then
            setModelPreservingStemIntent("htdemucs")
        end
    elseif char == 113 or char == 81 then
        if isModelAvailableInCurrentMode("htdemucs_ft") then
            setModelPreservingStemIntent("htdemucs_ft")
        end
    elseif char == 115 or char == 83 then
        if isModelAvailableInCurrentMode("htdemucs_6s") then
            setModelPreservingStemIntent("htdemucs_6s")
        end
    elseif char == 43 or char == 61 then
        local newW = math.min(GUI.maxW, gfx.w + 76)
        local newH = math.min(GUI.maxH, gfx.h + 68)
        gfx.init(SCRIPT_NAME, newW, newH)
    elseif char == 45 then
        local newW = math.max(GUI.minW, gfx.w - 76)
        local newH = math.max(GUI.minH, gfx.h - 68)
        gfx.init(SCRIPT_NAME, newW, newH)
    end
end

function renderFlarkLogo(ctx)
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then return end
    local S = ctx.S
    local w = ctx.w

    gfx.setfont(1, "Arial", S(10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", S(10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2

    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", S(10))
    gfx.x = logoStartX
    gfx.y = S(3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", S(10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = S(3)
    gfx.drawstr(audioPart)
end

function finalizeDialogLoop(ctx)
    local char = (ctx and ctx.char) or -1
    if GUI.result == nil and char ~= -1 then
        reaper.defer(dialogLoop)
        return
    end

    captureWindowGeometry(SCRIPT_NAME)
    if GUI.result and GUI.result ~= "help" then
        local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        local snap = {
            timeStart = ts0,
            timeEnd = ts1,
            items = {},
            tracks = {},
        }
        local nItems = reaper.CountSelectedMediaItems(0) or 0
        for i = 0, nItems - 1 do
            local it = reaper.GetSelectedMediaItem(0, i)
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                snap.items[#snap.items + 1] = it
            end
        end
        local nTracks = reaper.CountSelectedTracks(0) or 0
        for i = 0, nTracks - 1 do
            local tr = reaper.GetSelectedTrack(0, i)
            if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
                snap.tracks[#snap.tracks + 1] = tr
            end
        end
        PROCESS_SELECTION_SNAPSHOT = snap
        debugLog(string.format(
            "Process click: snap selection time=(%.6f..%.6f) items=%d tracks=%d",
            tonumber(ts0) or -1, tonumber(ts1) or -1, #snap.items, #snap.tracks
        ))
    end
    saveSettings()
    gfx.quit()
    if GUI.result == "help" then
        helpState.openedFrom = "dialog"
        reaper.defer(function() showArtGallery() end)
    elseif GUI.result then
        reaper.defer(function()
            local ok, err = xpcall(runSeparationWorkflow, function(e)
                return tostring(e) .. "\n" .. debug.traceback("", 2)
            end)
            if not ok then
                debugLog("ERROR: runSeparationWorkflow crashed:\n" .. tostring(err))
                if SW_LOG and SW_LOG.logExecResult then
                    SW_LOG.logExecResult("workflow_crash", -1, tostring(err))
                end
                isProcessingActive = false
                showMessage("Error", "STEMwerk crashed while starting processing.\n\nSee log:\n" .. tostring(getCrashLogPath()), "error")
            end
        end)
    else
        if #autoSelectedItems > 0 then
            for _, item in ipairs(autoSelectedItems) do
                if reaper.ValidatePtr(item, "MediaItem*") then
                    reaper.SetMediaItemSelected(item, false)
                end
            end
            autoSelectedItems = {}
        end
        if #autoSelectionTracks > 0 then
            for _, track in ipairs(autoSelectionTracks) do
                if reaper.ValidatePtr(track, "MediaTrack*") then
                    reaper.SetTrackSelected(track, false)
                end
            end
            autoSelectionTracks = {}
        end
        reaper.UpdateArrange()
    end
end

function dialogLoop()
    local loopNow = uiNow()

    -- Check for theme updates from Editor
    local lastRefresh = reaper.GetExtState("STEMwerk", "THEME_REFRESH")
    if lastRefresh ~= "" and lastRefresh ~= GUI._lastThemeRefresh then
        GUI._lastThemeRefresh = lastRefresh
        updateTheme()
    end

    if OS ~= "Windows" or (loopNow - (GUI.windowOpenedAt or 0)) >= 0.35 then
        makeWindowResizable()
    end
    pollRuntimeDeviceProbe()
    if DEBUG.enabled and RUNTIME_DEVICE_PROBE_DEBUG == "async_running" and not GUI._probeLoggedOnce then
        GUI._probeLoggedOnce = true
        perfMark("dialogLoop(): running while device probe async (UI should remain responsive)")
    end

    if GUI._updateFocusHandoff then GUI._updateFocusHandoff() end
    if GUI._updateDialogPosition then GUI._updateDialogPosition() end
    if GUI._throttleSaveSettings then GUI._throttleSaveSettings() end

    updateScale()

    if GUI.modal then
        local modalResult = drawMainDialogModalOverlay()
        if modalResult == "close" then
            captureWindowGeometry(SCRIPT_NAME)
            saveSettings()
            gfx.quit()
            GUI.result = false
            return
        end
        reaper.defer(dialogLoop)
        return
    end

    if GUI._handleNoSelection and GUI._handleNoSelection() then
        return
    end

    local ctx = {
        S = S,
        w = gfx.w,
        h = gfx.h,
        mx = gfx.mouse_x,
        my = gfx.mouse_y,
        mouseDown = (gfx.mouse_cap & 1) == 1,
        rightMouseDown = (gfx.mouse_cap & 2) == 2,
        mouseWheel = gfx.mouse_wheel,
        time = loopNow,
    }
    ctx.is6Stem = (tostring(SETTINGS.model or "") == "htdemucs_6s")

    handleDialogKeyboard(ctx)

    local nextFrameAt = GUI._nextFrameAt or 0
    local forceRedraw = GUI.result ~= nil or GUI.modal or mainDialogArt.pendingNewArt
    if not forceRedraw and loopNow < nextFrameAt then
        reaper.defer(dialogLoop)
        return
    end
    GUI._nextFrameAt = loopNow + pacingFrameInterval("dialogFrameInterval", "dialogFrameIntervalFx")

    renderDialogBackground(ctx)
    renderHelpTabs(ctx)
    renderMainColumns(ctx)
    renderFooter(ctx)
    renderFlarkLogo(ctx)

    if mainDialogArt.pendingNewArt then
        mainDialogArt.pendingNewArt = false
        if not GUI.uiClickedThisFrame then
            generateNewArt()
        end
    end

    mainDialogArt.wasMouseDown = ctx.mouseDown
    mainDialogArt.wasRightMouseDown = ctx.rightMouseDown

    drawTooltip()
    gfx.update()

    finalizeDialogLoop(ctx)
end

-- Show stem selection dialog
showStemSelectionDialog = function()
    ACTIVE_RUN_CONFIG = nil
    loadSettings()
    PROCESS_AUDIBILITY_SOLO_ACTIVE = nil
    perfMark("showStemSelectionDialog(): loadSettings done")
    GUI.result = nil
    GUI.wasMouseDown = false
    GUI._nextFrameAt = 0
    GUI.hadSelectionOnOpen = true  -- Dialog was opened with valid selection, don't auto-close
    GUI.windowsStartupMonitor = GUI.windowsStartupMonitor and true or false

    -- Keep startup non-blocking: seed a safe device list immediately and do runtime probing
    -- only after the window is already visible.
    if not RUNTIME_DEVICES then
        RUNTIME_DEVICES = runtimeDeviceSafeList()
    end

    local dialogW, dialogH, posX, posY = GUI.applyLiveGeometry(840, 600)
    windowResizableSet = false
    GUI.windowOpenedAt = uiNow()
    gfx.init(SCRIPT_NAME, dialogW, dialogH, 0, posX, posY)
    perfMark("showStemSelectionDialog(): gfx.init done (window visible)")

    reaper.defer(function()
        local cacheOpts = nil
        if OS == "Windows" and getTrustedWindowsRuntimeState and getTrustedWindowsRuntimeState() then
            cacheOpts = { skipQuickBench = true }
        end
        if applyCachedRuntimeDevices(cacheOpts) then
            perfMark("showStemSelectionDialog(): cached devices applied")
        else
            perfMark("showStemSelectionDialog(): cached devices unavailable")
        end
        -- Windows startup keeps device labels generic in the main dialog to
        -- avoid an extra cosmetic GPU-name probe during first paint.
    end)

    gfx.setfont(1, "Arial", S(13))
    dialogLoop()
end

-- Unique temp folder helper (avoid collisions when running twice within the same second)
local TEMP_RUN_COUNTER = 0
local function makeUniqueTempSubdir(prefix)
    TEMP_RUN_COUNTER = TEMP_RUN_COUNTER + 1
    local t = (reaper and reaper.time_precise) and reaper.time_precise() or os.clock() or 0
    local ms = math.floor(t * 1000)
    local base = getTempDir() .. PATH_SEP .. (prefix or "STEMwerk")
    return base .. "_" .. tostring(os.time()) .. "_" .. tostring(ms) .. "_" .. tostring(TEMP_RUN_COUNTER)
end

local function isSafeTempDir(path)
    if not path or path == "" then return false end
    local base = normalizePath(getTempDir())
    local p = normalizePath(path)
    local baseLower = base:lower()
    local pLower = p:lower()
    if base ~= "" and pLower:sub(1, #baseLower) ~= baseLower then return false end
    if not pLower:find("stemwerk", 1, true) then return false end
    return true
end

local function cleanupTempWorkDir(dir, opts)
    if not dir or dir == "" then return end
    if not isSafeTempDir(dir) then
        debugLog("cleanupTempWorkDir: skip unsafe path " .. tostring(dir))
        return
    end

    opts = opts or {}
    local successOnly = opts.success == true
    if not successOnly then
        debugLog("cleanupTempWorkDir: skipping because run not marked successful for " .. tostring(dir))
        return
    end

    -- Always copy run logs to persistent storage first, regardless of keepTempFiles.
    SW_LOG.savePersistentRunLogs(dir)

    if SETTINGS and SETTINGS.keepTempFiles then
        debugLog("cleanupTempWorkDir: keepTempFiles enabled, skipping audio cleanup for " .. tostring(dir))
        return
    end

    local knownGeneratedStemWavs = {
        ["vocals.wav"] = true,
        ["vocal.wav"] = true,
        ["drums.wav"] = true,
        ["drum.wav"] = true,
        ["bass.wav"] = true,
        ["other.wav"] = true,
        ["guitar.wav"] = true,
        ["piano.wav"] = true,
        ["instrumental.wav"] = true,
        ["no_vocals.wav"] = true,
        ["accompaniment.wav"] = true,
    }

    local keepByBasename = {}
    local keepStemPaths = opts.keepStemPaths or {}
    for _, p in pairs(keepStemPaths) do
        local s = tostring(p or "")
        if s ~= "" then
            local base = s:match("([^/\\]+)$")
            if base and base ~= "" then
                keepByBasename[base:lower()] = true
            end
        end
    end

    local function isPathInsideDir(path, parentDir)
        local nPath = normalizePath(path or "")
        local nParent = normalizePath(parentDir or "")
        if nPath == "" or nParent == "" then return false end
        local nPathLower = nPath:lower()
        local nParentLower = nParent:lower()
        if nPathLower == nParentLower then return true end
        local sep = PATH_SEP
        local withSep = nParentLower
        if withSep:sub(-1) ~= sep then
            withSep = withSep .. sep
        end
        return nPathLower:sub(1, #withSep) == withSep
    end

    if reaper and reaper.EnumerateFiles then
        local idx = 0
        while true do
            local f = reaper.EnumerateFiles(dir, idx)
            if not f then break end
            local lower = tostring(f):lower()
            local full = dir .. PATH_SEP .. f
            if knownGeneratedStemWavs[lower] and not keepByBasename[lower] and isPathInsideDir(full, dir) then
                local ok = os.remove(full)
                debugLog("cleanupTempWorkDir: removed unselected generated stem " .. tostring(full) .. " ok=" .. tostring(ok))
            end
            idx = idx + 1
        end
    end

    local inputWav = dir .. PATH_SEP .. "input.wav"
    if not (DEBUG and DEBUG.enabled) and isPathInsideDir(inputWav, dir) then
        local ok = os.remove(inputWav)
        if ok then
            debugLog("cleanupTempWorkDir: removed input.wav " .. tostring(inputWav))
        end
    end
end

-- File size helper (bytes). Returns -1 on failure.
local function fileSizeBytes(p)
    if not p then return -1 end
    local f = io.open(p, "rb")
    if not f then return -1 end
    local sz = f:seek("end")
    f:close()
    return tonumber(sz) or -1
end

local TIMING_UNIX_OFFSET = nil
local function writeTimingEvent(target, eventName, jobIndex, fields)
    local jobDir = nil
    if type(target) == "table" then
        jobDir = target.trackDir or target.outputDir
        jobIndex = jobIndex or target.index or target.jobIndex
    else
        jobDir = target
    end
    if not jobDir or jobDir == "" or not eventName or eventName == "" then return end

    local function nowSeconds()
        if reaper and reaper.time_precise then
            if not TIMING_UNIX_OFFSET then
                TIMING_UNIX_OFFSET = os.time() - reaper.time_precise()
            end
            return TIMING_UNIX_OFFSET + reaper.time_precise()
        end
        return os.time()
    end

    local function jsonEscape(value)
        local text = tostring(value or "")
        text = text:gsub("\\", "\\\\")
        text = text:gsub('"', '\\"')
        text = text:gsub("\n", "\\n")
        text = text:gsub("\r", "\\r")
        text = text:gsub("\t", "\\t")
        return text
    end

    local function jsonValue(value)
        if value == nil then return "null" end
        local valueType = type(value)
        if valueType == "number" then return string.format("%.6f", value) end
        if valueType == "boolean" then return value and "true" or "false" end
        return '"' .. jsonEscape(value) .. '"'
    end

    local values = {
        time = nowSeconds(),
        event = eventName,
        job_index = jobIndex,
        job_dir = jobDir,
    }
    if fields then
        for key, value in pairs(fields) do
            values[key] = value
        end
    end

    local orderedKeys = { "time", "event", "job_index", "job_dir", "percent", "stage", "mode" }
    local parts = {}
    local emitted = {}
    for _, key in ipairs(orderedKeys) do
        if values[key] ~= nil then
            parts[#parts + 1] = '"' .. key .. '":' .. jsonValue(values[key])
            emitted[key] = true
        end
    end
    for key, value in pairs(values) do
        if not emitted[key] then
            parts[#parts + 1] = '"' .. jsonEscape(key) .. '":' .. jsonValue(value)
        end
    end

    local handle = io.open(jobDir .. PATH_SEP .. "timing_events.jsonl", "a")
    if handle then
        handle:write("{" .. table.concat(parts, ",") .. "}\n")
        handle:close()
    end
end

-- Run ffmpeg extraction and capture stdout+stderr to a log file for debugging.
-- Returns: ok(bool), ffmpegLogPath(string), exitCode(number|nil)
local function runFfmpegExtract(sourceFile, offsetSec, durationSec, outputPath)
    local logPath = tostring(outputPath) .. ".ffmpeg.log"
    local ffmpegBin = FFMPEG_PATH or "ffmpeg"

    local exitCode = nil
    if OS == "Windows" then
        local cmd = string.format(
            '%s -y -hide_banner -nostats -loglevel error -i %s -ss %.6f -t %.6f -ar 44100 -ac 2 %s',
            quoteArg(ffmpegBin),
            quoteArg(sourceFile),
            offsetSec,
            durationSec,
            quoteArg(outputPath)
        )
        local rc, out = exec_capture(cmd, 0)
        exitCode = tonumber(rc)
        local logFile = io.open(logPath, "w")
        if logFile then
            logFile:write(out or "")
            logFile:close()
        end
    else
        local cmd = string.format(
            '%s -y -hide_banner -nostats -loglevel error -i "%s" -ss %.6f -t %.6f -ar 44100 -ac 2 "%s"',
            quoteArg(ffmpegBin), sourceFile, offsetSec, durationSec, outputPath
        )
        -- On Unix, os.execute uses /bin/sh so redirection works.
        local ok, _, code = os.execute(cmd .. ' >"' .. logPath .. '" 2>&1')
        if ok == true then exitCode = 0
        elseif type(code) == "number" then exitCode = code
        end
    end

    local sz = fileSizeBytes(outputPath)
    local ok = (sz and sz > 1024)
    return ok, logPath, exitCode
end

-- Fallback extractor: render audio from REAPER itself (no ffmpeg dependency).
-- Returns: ok(bool), err(string|nil)
local function renderTakeAccessorToWav(take, startTime, endTime, outputPath)
    local function isFiniteNumber(v)
        return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    end
    local function clampSampleFloat(v)
        if not isFiniteNumber(v) then return 0.0 end
        if v > 1.0 then return 1.0 end
        if v < -1.0 then return -1.0 end
        return v
    end
    local function safeUint(name, v, bits)
        bits = bits or 32
        local max = (bits == 16) and 0xFFFF or 0xFFFFFFFF
        if not isFiniteNumber(v) then
            return nil, string.format("%s invalid (non-finite)", tostring(name))
        end
        local iv = math.floor(v + 0.0)
        if iv < 0 or iv > max then
            return nil, string.format("%s out of range for uint%d (%s)", tostring(name), bits, tostring(iv))
        end
        return iv, nil
    end
    local function safeWritePack(fileHandle, fmt, value, label, bits)
        local safeValue, safeErr = safeUint(label, value, bits)
        if not safeValue then
            return false, safeErr
        end
        local okPack, packed = pcall(string.pack, fmt, safeValue)
        if not okPack then
            return false, string.format("%s pack failed (%s)", tostring(label), tostring(packed))
        end
        local okWrite = fileHandle:write(packed)
        if not okWrite then
            return false, string.format("%s write failed", tostring(label))
        end
        return true, nil
    end
    local function closeWithError(fileHandle, accHandle, msg)
        if accHandle then pcall(reaper.DestroyAudioAccessor, accHandle) end
        if fileHandle then pcall(function() fileHandle:close() end) end
        pcall(os.remove, outputPath)
        return false, "WAV render failed: " .. tostring(msg)
    end

    if not (reaper and reaper.CreateTakeAudioAccessor and reaper.GetAudioAccessorSamples and reaper.DestroyAudioAccessor) then
        return false, "REAPER AudioAccessor API not available"
    end
    if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then
        return false, "Invalid take"
    end
    if not startTime or not endTime or startTime >= endTime then
        return false, "Invalid render range"
    end

    local sr = 44100
    local ch = 2
    local duration = endTime - startTime
    local totalFrames = math.floor(duration * sr + 0.5)
    if totalFrames <= 0 then
        return false, "Render range is empty"
    end

    local acc = reaper.CreateTakeAudioAccessor(take)
    if not acc then
        return false, "Failed to create take audio accessor"
    end

    local ownerItem = reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(take) or nil
    local ownerPos = ownerItem and reaper.ValidatePtr(ownerItem, "MediaItem*") and reaper.GetMediaItemInfo_Value(ownerItem, "D_POSITION") or nil
    local ownerLen = ownerItem and reaper.ValidatePtr(ownerItem, "MediaItem*") and reaper.GetMediaItemInfo_Value(ownerItem, "D_LENGTH") or nil
    local ownerEnd = (ownerPos and ownerLen) and (ownerPos + ownerLen) or nil
    local accStart = reaper.GetAudioAccessorStartTime and reaper.GetAudioAccessorStartTime(acc) or nil
    local accEnd = reaper.GetAudioAccessorEndTime and reaper.GetAudioAccessorEndTime(acc) or nil
    local eps = 1e-5
    local requestStart = startTime
    local requestEnd = endTime
    local sampleStart = requestStart
    local sampleEnd = requestEnd
    local sampleMode = "project"

    if accStart and accEnd then
        local function fitsAccessor(rangeStart, rangeEnd)
            return rangeStart >= (accStart - eps) and rangeEnd <= (accEnd + eps)
        end

        local function fitsAsItemLocal()
            if not ownerPos or not ownerEnd then return false end
            if requestStart < (ownerPos - eps) or requestEnd > (ownerEnd + eps) then return false end
            local localStart = accStart + math.max(0, requestStart - ownerPos)
            local localEnd = accStart + math.max(0, requestEnd - ownerPos)
            return fitsAccessor(localStart, localEnd), localStart, localEnd
        end

        if not fitsAccessor(sampleStart, sampleEnd) then
            local localFits, localStart, localEnd = fitsAsItemLocal()
            if localFits then
                sampleStart = localStart
                sampleEnd = localEnd
                sampleMode = "item-local"
            else
                sampleStart = math.max(accStart, sampleStart)
                sampleEnd = math.min(accEnd, sampleEnd)
                sampleMode = "clamped-project"
            end
        end
    end

    -- Accessor bounds are read-only via GetAudioAccessorStartTime/EndTime.
    -- Keep clamp logic above; do not call legacy/non-existent setter variants.

    local f = io.open(outputPath, "wb")
    if not f then
        reaper.DestroyAudioAccessor(acc)
        return false, "Failed to open output file for writing"
    end

    -- Write WAV header (32-bit float)
    local bytesPerSample = 4
    local blockAlign = ch * bytesPerSample
    local byteRate = sr * blockAlign
    local dataSizePos = nil
    local riffSizePos = nil

    if not f:write("RIFF") then
        return closeWithError(f, acc, "failed writing RIFF header")
    end
    riffSizePos = f:seek()  -- position after 'RIFF'
    if not riffSizePos then
        return closeWithError(f, acc, "failed seeking RIFF size position")
    end
    do
        local ok, err = safeWritePack(f, "<I4", 0, "riff_size_placeholder", 32)
        if not ok then return closeWithError(f, acc, err) end
    end
    if not f:write("WAVE") or not f:write("fmt ") then
        return closeWithError(f, acc, "failed writing WAVE/fmt header")
    end
    do
        local ok, err = safeWritePack(f, "<I4", 16, "fmt_chunk_size", 32)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I2", 3, "audio_format", 16)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I2", ch, "channel_count", 16)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I4", sr, "sample_rate", 32)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I4", byteRate, "byte_rate", 32)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I2", blockAlign, "block_align", 16)
        if not ok then return closeWithError(f, acc, err) end
        ok, err = safeWritePack(f, "<I2", 32, "bits_per_sample", 16)
        if not ok then return closeWithError(f, acc, err) end
    end
    if not f:write("data") then
        return closeWithError(f, acc, "failed writing data header")
    end
    dataSizePos = f:seek()
    if not dataSizePos then
        return closeWithError(f, acc, "failed seeking data size position")
    end
    do
        local ok, err = safeWritePack(f, "<I4", 0, "data_size_placeholder", 32)
        if not ok then return closeWithError(f, acc, err) end
    end

    local blockFrames = 8192
    local buf = reaper.new_array(blockFrames * ch)
    local framesWritten = 0
    local curTime = sampleStart

    while framesWritten < totalFrames do
        local need = math.min(blockFrames, totalFrames - framesWritten)
        -- Ensure buffer capacity.
        if need ~= blockFrames then
            buf = reaper.new_array(need * ch)
        end
        local ok = reaper.GetAudioAccessorSamples(acc, sr, ch, curTime, need, buf)
        if not ok or ok == 0 then
            break
        end
        -- Write interleaved float32 samples
        local parts = {}
        for i = 1, need * ch do
            parts[i] = string.pack("<f", clampSampleFloat(buf[i] or 0.0))
        end
        f:write(table.concat(parts))
        framesWritten = framesWritten + need
        curTime = curTime + (need / sr)
    end

    reaper.DestroyAudioAccessor(acc)

    -- Finalize header sizes
    local dataBytes = framesWritten * ch * bytesPerSample
    local fileEnd = f:seek("end")
    if not fileEnd then
        return closeWithError(f, nil, "failed seeking file end for WAV size finalization")
    end
    local riffBytes = fileEnd - 8
    local safeDataBytes, dataErr = safeUint("data_size", dataBytes, 32)
    if not safeDataBytes then
        return closeWithError(f, nil, dataErr)
    end
    local safeRiffBytes, riffErr = safeUint("riff_size", riffBytes, 32)
    if not safeRiffBytes then
        return closeWithError(f, nil, riffErr)
    end
    -- data chunk size
    f:seek("set", dataSizePos)
    do
        local ok, err = safeWritePack(f, "<I4", safeDataBytes, "data_size", 32)
        if not ok then return closeWithError(f, nil, err) end
    end
    -- riff chunk size = fileSize - 8
    f:seek("set", riffSizePos)
    do
        local ok, err = safeWritePack(f, "<I4", safeRiffBytes, "riff_size", 32)
        if not ok then return closeWithError(f, nil, err) end
    end
    f:close()

    if dataBytes <= 0 then
        return false, string.format(
            "AudioAccessor rendered 0 samples (requested %.6f..%.6f, sampled %.6f..%.6f, mode %s, accessor %.6f..%.6f)",
            tonumber(startTime) or -1,
            tonumber(endTime) or -1,
            tonumber(sampleStart) or -1,
            tonumber(sampleEnd) or -1,
            tostring(sampleMode),
            tonumber(accStart) or -1,
            tonumber(accEnd) or -1
        )
    end
    return true, nil
end


-- Render selected item to a temporary WAV file
-- If time selection exists and overlaps item, only render that portion
local function renderItemToWav(item, outputPath, explicitRenderStart, explicitRenderEnd)
    local take = reaper.GetActiveTake(item)
    if not take then return nil, "No active take" end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil, "No source" end

    local sourceFile = reaper.GetMediaSourceFileName(source, "")
    if not sourceFile or sourceFile == "" then return nil, "No source file" end

    local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local itemEnd = itemPos + itemLen
    local takeOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
    if not playrate or playrate < 0.0001 then
        debugLog("renderItemToWav: suspicious take playrate=" .. tostring(playrate) .. " -> using 1.0")
        playrate = 1.0
    end
    pitch = tonumber(pitch) or 0.0

    -- Check for time selection that overlaps the item (only when time selection mode is active)
    local timeSelStart, timeSelEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local hasTimeSel = timeSelectionMode and (timeSelEnd > timeSelStart)

    local renderStart = explicitRenderStart or itemPos
    local renderEnd = explicitRenderEnd or itemEnd

    if explicitRenderStart and explicitRenderEnd then
        renderStart = math.max(itemPos, explicitRenderStart)
        renderEnd = math.min(itemEnd, explicitRenderEnd)
    elseif hasTimeSel then
        -- Clamp time selection to item bounds
        if timeSelStart > itemPos and timeSelStart < itemEnd then
            renderStart = timeSelStart
        end
        if timeSelEnd > itemPos and timeSelEnd < itemEnd then
            renderEnd = timeSelEnd
        end
        -- Only use time selection if it actually overlaps
        if timeSelStart >= itemEnd or timeSelEnd <= itemPos then
            -- No overlap, render whole item
            renderStart = itemPos
            renderEnd = itemEnd
        end
    end

    -- Calculate source file offset and duration
    local renderOffset = takeOffset + (renderStart - itemPos) * playrate
    local renderDuration = (renderEnd - renderStart) * playrate
    if not renderDuration or renderDuration <= (1 / 100) then
        return nil, "Selection is empty (0s). Make a longer time selection or pick an item with length.", nil
    end

    local isPartialSlice = (math.abs(renderStart - itemPos) > 0.0001) or (math.abs(renderEnd - itemEnd) > 0.0001)
    local hasPlaybackTransform = (math.abs((tonumber(playrate) or 1.0) - 1.0) > 0.0001) or (math.abs(pitch) > 0.0001)
    if isPartialSlice then
        debugLog(string.format(
            "renderItemToWav partial slice: itemPos=%.6f itemEnd=%.6f renderStart=%.6f renderEnd=%.6f takeOffset=%.6f playrate=%.6f sourceOffset=%.6f duration=%.6f source=%s",
            tonumber(itemPos) or 0,
            tonumber(itemEnd) or 0,
            tonumber(renderStart) or 0,
            tonumber(renderEnd) or 0,
            tonumber(takeOffset) or 0,
            tonumber(playrate) or 1,
            tonumber(renderOffset) or 0,
            tonumber(renderDuration) or 0,
            tostring(sourceFile)
        ))
    end

    -- Partial slices with non-default playback should prefer ffmpeg first so the extracted
    -- file remains in source-time and we can safely restore take playback metadata later.
    -- For default playback, prefer AudioAccessor to better reflect split context/arrangement.
    if isPartialSlice then
        if hasPlaybackTransform then
            local ok, ffmpegLog = runFfmpegExtract(sourceFile, renderOffset, renderDuration, outputPath)
            if ok then
                return outputPath, nil, renderStart, renderEnd - renderStart
            end
            local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
            if accOk and fileSizeBytes(outputPath) > 1024 then
                return outputPath, nil, renderStart, renderEnd - renderStart
            end
            if not accOk then
                debugLog(string.format(
                    "renderTakeAccessorToWav failed (partial transform): item=%s take=%s start=%.6f end=%.6f err=%s",
                    tostring(item),
                    tostring(take),
                    tonumber(renderStart) or -1,
                    tonumber(renderEnd) or -1,
                    tostring(accErr)
                ))
            end
            if fileSizeBytes(outputPath) > -1 and fileSizeBytes(outputPath) <= 1024 then
                os.remove(outputPath)
            end
            return nil, "Failed to extract partial audio slice. ffmpeg log: " .. tostring(ffmpegLog) .. "; AudioAccessor: " .. tostring(accErr), nil
        else
            local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
            if accOk and fileSizeBytes(outputPath) > 1024 then
                return outputPath, nil, renderStart, renderEnd - renderStart
            end
            if not accOk then
                debugLog(string.format(
                    "renderTakeAccessorToWav failed (partial default): item=%s take=%s start=%.6f end=%.6f err=%s",
                    tostring(item),
                    tostring(take),
                    tonumber(renderStart) or -1,
                    tonumber(renderEnd) or -1,
                    tostring(accErr)
                ))
            end
            if fileSizeBytes(outputPath) > -1 and fileSizeBytes(outputPath) <= 1024 then
                os.remove(outputPath)
            end
            local ok, ffmpegLog = runFfmpegExtract(sourceFile, renderOffset, renderDuration, outputPath)
            if ok then
                return outputPath, nil, renderStart, renderEnd - renderStart
            end
            return nil, "Failed to extract partial audio slice. AudioAccessor: " .. tostring(accErr) .. "; ffmpeg log: " .. tostring(ffmpegLog), nil
        end
    end

    -- Prefer ffmpeg (fast). If it fails, fall back to REAPER AudioAccessor (robust).
    local ok, ffmpegLog = runFfmpegExtract(sourceFile, renderOffset, renderDuration, outputPath)
    if ok then
        return outputPath, nil, renderStart, renderEnd - renderStart
    end
    local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
    if accOk and fileSizeBytes(outputPath) > 1024 then
        return outputPath, nil, renderStart, renderEnd - renderStart
    end
    if not accOk then
        debugLog(string.format(
            "renderTakeAccessorToWav failed (full item): item=%s take=%s start=%.6f end=%.6f err=%s",
            tostring(item),
            tostring(take),
            tonumber(renderStart) or -1,
            tonumber(renderEnd) or -1,
            tostring(accErr)
        ))
    end
    if fileSizeBytes(outputPath) > -1 and fileSizeBytes(outputPath) <= 1024 then
        os.remove(outputPath)
    end
    return nil, "Failed to extract audio (ffmpeg produced empty output). See: " .. tostring(ffmpegLog) .. (accErr and ("\nAudioAccessor: " .. tostring(accErr)) or ""), nil
end

-- Render time selection to a temporary WAV file
local function renderTimeSelectionToWav(outputPath)
    timeSelectionResolvedItems = nil
    local res = resolveTimeSelectionTargets()
    if not res then return nil, "No time selection" end

    local startTime, endTime = res.startTime, res.endTime
    local noAudibleOverlapMsg = HELPERS.getNoAudibleTargetsMessage()
    local selectedItems = res.items or {}
    local foundItem = selectedItems[1] and selectedItems[1].item or nil

    if #selectedItems == 0 then
        if (res.rawOverlap or 0) > 0 then
            return nil, noAudibleOverlapMsg
        end
        if res.mode == "selected_items" then
            return nil, "No selected items overlap the time selection"
        elseif res.mode == "selected_tracks" then
            if not SETTINGS.createNewTracks then
                return nil, "No items on selected tracks overlap time selection"
            end
            return nil, "No items selected on tracks"
        end
        return nil, "No items overlap the time selection"
    end

    timeSelectionResolvedItems = {}
    for _, entry in ipairs(selectedItems) do
        if entry.item then
            timeSelectionResolvedItems[#timeSelectionResolvedItems + 1] = entry.item
        end
    end

    -- If only one item, use simple ffmpeg extraction (faster)
    if #selectedItems == 1 then
        local take = reaper.GetActiveTake(selectedItems[1].item)
        if not take then return nil, "No active take" end

        local source = reaper.GetMediaItemTake_Source(take)
        if not source then return nil, "No source" end

        local sourceFile = reaper.GetMediaSourceFileName(source, "")
        if not sourceFile or sourceFile == "" then return nil, "No source file" end

        local itemPos = reaper.GetMediaItemInfo_Value(selectedItems[1].item, "D_POSITION")
        local takeOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        if not playrate or playrate < 0.0001 then
            debugLog("renderTimeSelectionToWav: suspicious take playrate=" .. tostring(playrate) .. " -> using 1.0")
            playrate = 1.0
        end

        local selStartInItem = math.max(0, startTime - itemPos)
        local selEndInItem = math.min(endTime - itemPos, reaper.GetMediaItemInfo_Value(selectedItems[1].item, "D_LENGTH"))
        local duration = (selEndInItem - selStartInItem) * playrate
        local sourceOffset = takeOffset + (selStartInItem * playrate)
        if not duration or duration <= 0.0 then
            return nil, "Time selection is empty (0s). Make a longer time selection.", nil
        end

        local renderStart = itemPos + selStartInItem
        local renderEnd = itemPos + selEndInItem
        local ok, ffmpegLog = runFfmpegExtract(sourceFile, sourceOffset, duration, outputPath)
        if ok then
            return outputPath, nil, foundItem
        end
        local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
        if accOk then
            return outputPath, nil, foundItem
        end
        debugLog(string.format(
            "renderTakeAccessorToWav failed (time selection single item): item=%s take=%s start=%.6f end=%.6f err=%s",
            tostring(selectedItems[1].item),
            tostring(take),
            tonumber(renderStart) or -1,
            tonumber(renderEnd) or -1,
            tostring(accErr)
        ))
        return nil, "Failed to extract audio (ffmpeg produced empty output). See: " .. tostring(ffmpegLog) .. (accErr and ("\nAudioAccessor: " .. tostring(accErr)) or ""), nil
    end

    -- Multiple items selected - group by track
    local trackItems = res.trackItems or {}
    local trackList = res.trackList or {}
    local trackCount = res.trackCount or #trackList

    if trackCount > 1 then
        -- Multiple tracks - return special marker to indicate multi-track mode
        return nil, "MULTI_TRACK", nil, trackList, trackItems
    end

    if trackCount == 1 then
        local onlyTrack = trackList[1]
        local itemsOnTrack = (onlyTrack and trackItems[onlyTrack]) or {}
        if #itemsOnTrack > 1 then
            -- Multiple items on a single track: handle as per-item jobs
            return nil, "MULTI_ITEM", nil, trackList, trackItems
        end
    end

    -- All items are on the same track - use the first one
    local take = reaper.GetActiveTake(foundItem)
    if not take then return nil, "No active take" end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil, "No source" end

    local sourceFile = reaper.GetMediaSourceFileName(source, "")
    if not sourceFile or sourceFile == "" then return nil, "No source file" end

    local itemPos = reaper.GetMediaItemInfo_Value(foundItem, "D_POSITION")
    local takeOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if not playrate or playrate < 0.0001 then
        debugLog("renderTimeSelectionToWav: suspicious take playrate=" .. tostring(playrate) .. " -> using 1.0")
        playrate = 1.0
    end

    local selStartInItem = math.max(0, startTime - itemPos)
    local selEndInItem = math.min(endTime - itemPos, reaper.GetMediaItemInfo_Value(foundItem, "D_LENGTH"))
    local duration = (selEndInItem - selStartInItem) * playrate
    local sourceOffset = takeOffset + (selStartInItem * playrate)
    if not duration or duration <= 0.0 then
        return nil, "Time selection is empty (0s). Make a longer time selection.", nil
    end

    local renderStart = itemPos + selStartInItem
    local renderEnd = itemPos + selEndInItem
    local ok, ffmpegLog = runFfmpegExtract(sourceFile, sourceOffset, duration, outputPath)
    if ok then
        return outputPath, nil, foundItem
    end
    local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
    if accOk then
        return outputPath, nil, foundItem
    end
    debugLog(string.format(
        "renderTakeAccessorToWav failed (time selection): item=%s take=%s start=%.6f end=%.6f err=%s",
        tostring(foundItem),
        tostring(take),
        tonumber(renderStart) or -1,
        tonumber(renderEnd) or -1,
        tostring(accErr)
    ))
    return nil, "Failed to extract audio (ffmpeg produced empty output). See: " .. tostring(ffmpegLog) .. (accErr and ("\nAudioAccessor: " .. tostring(accErr)) or ""), nil
end

-- Extract audio for a specific track within time selection
function renderTrackTimeSelectionToWav(track, outputPath)
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if startTime >= endTime then return nil, "No time selection" end
    local soloActive = getProcessingSoloActive()
    if not AUDIBILITY.isTrackAudible(track, soloActive) then
        return nil, "Track muted or not solo-audible"
    end

    -- Find ALL items on this track overlapping time selection
    -- (prefer selected items, but include all overlapping if none selected)
    local numItems = reaper.CountTrackMediaItems(track)
    local foundItem = nil
    local allFoundItems = {}
    local rawSelectedOverlap = 0
    local rawAnyOverlap = 0
    local noAudibleOverlapMsg = HELPERS.getNoAudibleTargetsMessage()

    -- First pass: look for selected items (raw overlap + eligible)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local iEnd = iPos + iLen
        if iPos < endTime and iEnd > startTime then
            rawAnyOverlap = rawAnyOverlap + 1
            if reaper.IsMediaItemSelected(item) then
                rawSelectedOverlap = rawSelectedOverlap + 1
                if AUDIBILITY.isItemAudible(item, soloActive) then
                    if not foundItem then
                        foundItem = item
                    end
                    table.insert(allFoundItems, item)
                end
            end
        end
    end

    if not foundItem and rawSelectedOverlap > 0 then
        return nil, noAudibleOverlapMsg
    end

    -- Second pass: if no selected items overlap, find ANY overlapping items
    if rawSelectedOverlap == 0 then
        for i = 0, numItems - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local iEnd = iPos + iLen
            if AUDIBILITY.isItemAudible(item, soloActive) and iPos < endTime and iEnd > startTime then
                if not foundItem then
                    foundItem = item
                end
                table.insert(allFoundItems, item)
            end
        end
    end

    if not foundItem then
        if rawAnyOverlap > 0 then return nil, noAudibleOverlapMsg end
        return nil, "No items on track overlap time selection"
    end

    local take = reaper.GetActiveTake(foundItem)
    if not take then return nil, "No active take" end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil, "No source" end

    local sourceFile = reaper.GetMediaSourceFileName(source, "")
    if not sourceFile or sourceFile == "" then return nil, "No source file" end

    -- Reuse the robust single-item extractor (ffmpeg with captured log + AudioAccessor fallback).
    -- NOTE: This assumes the track's audio comes from a single main item/take (common workflow).
    local extracted, err = renderItemToWav(foundItem, outputPath)
    if extracted then
        return outputPath, nil, foundItem, allFoundItems
    end
    return nil, err or "Failed to extract audio", nil, nil
end

-- Render selected items on a track to WAV (no time selection needed)
-- Used when items are selected but no time selection exists
function renderTrackSelectedItemsToWav(track, outputPath)
    -- Find ALL selected items on this track
    local soloActive = getProcessingSoloActive()
    if not AUDIBILITY.isTrackAudible(track, soloActive) then
        return nil, "Track muted or not solo-audible"
    end
    local numItems = reaper.CountTrackMediaItems(track)
    local foundItem = nil
    local allFoundItems = {}
    local minPos = math.huge
    local maxEnd = 0

    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if AUDIBILITY.isItemAudible(item, soloActive) and reaper.IsMediaItemSelected(item) then
            local iPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local iLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local iEnd = iPos + iLen
            if not foundItem then
                foundItem = item  -- Keep first for audio extraction
            end
            table.insert(allFoundItems, item)
            minPos = math.min(minPos, iPos)
            maxEnd = math.max(maxEnd, iEnd)
        end
    end

    if not foundItem then return nil, "No selected items on track" end

    -- Robust single-item extraction (renders full item when no time selection exists).
    local extracted, err = renderItemToWav(foundItem, outputPath)
    if extracted then
        return outputPath, nil, foundItem, allFoundItems
    end
    return nil, err or "Failed to extract audio", nil, nil
end

-- Render a single item to WAV (for in-place multi-item processing)
function renderSingleItemToWav(item, outputPath)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then
        return nil, "Invalid item"
    end

    local take = reaper.GetActiveTake(item)
    if not take then return nil, "No active take" end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil, "No source" end

    local sourceFile = reaper.GetMediaSourceFileName(source, "")
    if not sourceFile or sourceFile == "" then return nil, "No source file" end

    local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local takeOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

    if not playrate or playrate < 0.0001 then
        debugLog("renderSingleItemToWav: suspicious take playrate=" .. tostring(playrate) .. " -> using 1.0")
        playrate = 1.0
    end

    local duration = itemLen * playrate
    local sourceOffset = takeOffset

    if not duration or duration <= 0.0 then
        return nil, "Item length is 0s"
    end

    local ok, ffmpegLog = runFfmpegExtract(sourceFile, sourceOffset, duration, outputPath)
    if ok then
        return outputPath, nil
    end
    local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local accOk, accErr = renderTakeAccessorToWav(take, itemPos, itemPos + itemLen, outputPath)
    if accOk then
        return outputPath, nil
    end
    return nil, "Failed to extract audio (ffmpeg produced empty output). See: " .. tostring(ffmpegLog) .. (accErr and ("\nAudioAccessor: " .. tostring(accErr)) or "")
end

-- Progress window state
local progressState = {
    running = false,
    windowOpen = false,
    outputDir = nil,
    stdoutFile = nil,
    logFile = nil,
    exitCodeFile = nil,
    lastCmd = nil,
    execLogPath = nil,
    percent = 0,
    stage = "Starting..",
    startTime = 0,
    wasMouseDown = false,  -- Track mouse state for click detection
    -- Nerd terminal state
    showTerminal = false,
    terminalLines = {},
    terminalScrollPos = 0,
    lastTerminalUpdate = 0,
    nextFrameAt = 0,
    nextPollAt = 0,
    doneDetected = false,
    workflowMode = "",
    workflowSource = "",
}

local function isDrumKitWorkflowActive()
    return tostring(progressState.workflowMode or "") == DKS_WORKFLOW.WORKFLOW_DRUMKIT
end

local function setWorkflowContextForRun(runOptions)
    runOptions = runOptions or {}
    progressState.workflowMode = tostring(runOptions.workflowMode or "")
    progressState.workflowSource = tostring(runOptions.workflowSource or "")
end

UI_PROGRESS.configure({
    progressState               = progressState,
    getProcessingWindowTitle    = getProcessingWindowTitle,
    warnMissingJsWindowStyleApi = warnMissingJsWindowStyleApi,
})

function getProcessingWindowGeometry()
    local winW = lastDialogW or 380
    local winH = lastDialogH or 340
    local winX, winY
    if lastDialogX and lastDialogY then
        winX = lastDialogX
        winY = lastDialogY
    else
        local mouseX, mouseY = reaper.GetMousePosition()
        winX = mouseX - winW / 2
        winY = mouseY - winH / 2
        winX, winY = clampToScreen(winX, winY, winW, winH, mouseX, mouseY)
    end
    return winW, winH, winX, winY
end

function ensureProcessingWindowOpen()
    if progressState.windowOpen then return end
    local winW, winH, winX, winY = getProcessingWindowGeometry()
    progressState.windowTitle = getProcessingWindowTitle()
    gfx.init(progressState.windowTitle, winW, winH, 0, winX, winY)
    progressWindowResizableSet = false
    progressState.windowOpen = true
    progressState.nextFrameAt = 0
    progressState.nextPollAt = 0
    progressState.doneDetected = false
end

function showProcessingPlaceholderWindow(stage)
    if stage and stage ~= "" then
        progressState.stage = stage
    end
    if not progressState.startTime or progressState.startTime == 0 then
        progressState.startTime = os.time()
    end

    ensureProcessingWindowOpen()

    local w, h = gfx.w, gfx.h
    local bg = (THEME and THEME.inputBg) or {0.12, 0.12, 0.14}
    local border = (THEME and THEME.border) or {0.35, 0.35, 0.4}
    local text = (THEME and THEME.text) or {0.95, 0.95, 0.95}
    local dim = (THEME and THEME.textDim) or text
    local accent = (THEME and THEME.accent) or {0.35, 0.65, 0.95}

    gfx.set(bg[1], bg[2], bg[3], 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(border[1], border[2], border[3], 1)
    gfx.rect(0, 0, w, h, 0)

    local barW = math.max(160, math.floor(w * 0.42))
    local barH = 8
    local barX = math.floor((w - barW) / 2)
    local barY = math.floor(h * 0.56)
    local pulse = (math.sin(os.clock() * 4.0) + 1) * 0.5
    local fillW = math.max(24, math.floor(barW * (0.18 + 0.22 * pulse)))

    gfx.setfont(1, "Arial", 20, string.byte('b'))
    local title = isDrumKitWorkflowActive() and "Drum Kit Split" or "STEMwerk"
    local titleW = gfx.measurestr(title)
    gfx.set(text[1], text[2], text[3], 1)
    gfx.x = math.floor((w - titleW) / 2)
    gfx.y = math.floor(h * 0.34)
    gfx.drawstr(title)

    local stageText = tostring(progressState.stage or ((type(T) == "function" and (T("starting") or "Starting...")) or "Starting..."))
    stageText = stageText:gsub("%s*%b[]", "")
    stageText = stageText:gsub("%s*%b()", "")
    stageText = stageText:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if stageText == "" then
        stageText = (type(T) == "function" and (T("starting") or "Starting...")) or "Starting..."
    end
    gfx.setfont(1, "Arial", 13)
    local stageW = gfx.measurestr(stageText)
    gfx.set(dim[1], dim[2], dim[3], 1)
    gfx.x = math.floor((w - stageW) / 2)
    gfx.y = math.floor(h * 0.44)
    gfx.drawstr(stageText)

    gfx.set(border[1], border[2], border[3], 1)
    gfx.rect(barX, barY, barW, barH, 0)
    gfx.set(accent[1], accent[2], accent[3], 0.95)
    gfx.rect(barX + 1, barY + 1, math.max(1, math.min(barW - 2, fillW)), math.max(1, barH - 2), 1)

    gfx.update()
end

function showProcessingWindow(stage, percent)
    if stage and stage ~= "" then
        progressState.stage = stage
    end
    if percent ~= nil then
        progressState.percent = tonumber(percent) or progressState.percent or 0
    end
    if not progressState.startTime or progressState.startTime == 0 then
        progressState.startTime = os.time()
    end

    ensureProcessingWindowOpen()

    drawProgressWindow()
    gfx.update()
end

function closeProcessingWindow()
    if not progressState.windowOpen then return end
    captureWindowGeometry(progressState.windowTitle or getProcessingWindowTitle())
    saveSettings()
    gfx.quit()
    progressState.windowOpen = false
    progressState.running = false
end

-- Multi-track queue state (declared early for access in drawProgressWindow)
multiTrackQueue = {
    tracks = {},           -- List of tracks to process
    currentIndex = 0,      -- Current track being processed
    totalTracks = 0,       -- Total number of tracks
    active = false,        -- Is multi-track mode active
    currentTrackName = "", -- Name of current track being processed
    currentSourceTrack = nil, -- Track to place stems under
    showTerminal = false,  -- Nerd mode: show terminal output (sequential mode only)
    terminalLines = {},    -- Terminal output lines
    lastTerminalUpdate = 0, -- Last time terminal was updated
    listScroll = 0,        -- Scroll offset for large multi-job batches
    listScrollDragging = false,
    listScrollDragOffset = 0,
    nextFrameAt = 0,
    nextPollAt = 0,
}

-- Internal/dev-only parallel worker limiter (no UI yet).
-- nil = production/default: unchanged unlimited parallel launch behavior
-- 3/4 were promising internal benchmark candidates on local GPU
-- Further device/model benchmarks are needed before changing defaults
local INTERNAL_PARALLEL_JOB_LIMIT = nil
-- local INTERNAL_PARALLEL_JOB_LIMIT = 3
-- local INTERNAL_PARALLEL_JOB_LIMIT = 4

-- Forward declarations for multi-track processing
local _sep = {}  -- separation forward-declaration namespace

function utilityProgressColor()
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
        local c = THEME and (THEME.buttonPrimary or THEME.accent) or nil
        if type(c) == "table" then return c[1] or 0.4, c[2] or 0.55, c[3] or 0.42 end
    end
    return 0.30, 0.46, 0.32
end

function utilityProgressMutedColor()
    if SETTINGS and SETTINGS.darkMode then
        return 0.34, 0.42, 0.36
    end
    return 0.56, 0.68, 0.58
end

-- Draw progress window with stem colors and eye candy (scalable)
local function drawProgressWindow()
    -- Function-level aliases for extracted module (don't count toward chunk local limit)
    local PROGRESS_BASE_W        = UI_PROGRESS.PROGRESS_BASE_W
    local PROGRESS_BASE_H        = UI_PROGRESS.PROGRESS_BASE_H
    local makeProgressWindowResizable = UI_PROGRESS.makeProgressWindowResizable
    local normalizeProgressStage = UI_PROGRESS.normalizeProgressStage
    local readableTerminalAccent = UI_PROGRESS.readableTerminalAccent
    local drawTerminalFx         = UI_PROGRESS.drawTerminalFx
    local formatProgressLine     = UI_PROGRESS.formatProgressLine
    local progressUiLabel        = UI_PROGRESS.progressUiLabel
    local w, h = gfx.w, gfx.h

    -- Calculate scale based on window size
    local scaleW = w / PROGRESS_BASE_W
    local scaleH = h / PROGRESS_BASE_H
    local scale = math.min(scaleW, scaleH)
    scale = math.max(0.5, math.min(4.0, scale))  -- Clamp scale

    -- Scaling helper
    local function PS(val) return math.floor(val * scale + 0.5) end
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()

    -- Try to make window resizable
    makeProgressWindowResizable()

    -- === PROCEDURAL ART AS FULL BACKGROUND LAYER ===
    -- Pure black/white background first
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, w, h, 1)

    -- Update art animation time
    proceduralArt.time = proceduralArt.time + 0.016  -- ~60fps

    -- Draw procedural art covering entire window (background layer)
    if not utilityMode then
        drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

        -- Theme-aware readability wash over animated FX
        local overlayAlpha = getFxReadabilityOverlayAlpha()
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, overlayAlpha)
        else
            gfx.set(1, 1, 1, overlayAlpha)
        end
        gfx.rect(0, 0, w, h, 1)
    end

    -- Mouse position for UI interactions
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local mouseWheel = gfx.mouse_wheel

    -- Tooltip tracking
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0
    local cancelClicked = false

    -- Best-effort: parse actual selected device id/name from the separation log (so UI never lies).
    -- We update at most ~2x/sec to keep it cheap.
    if progressState.logFile and (not progressState._deviceInfoLastAt or (os.clock() - progressState._deviceInfoLastAt) > 0.5) then
        progressState._deviceInfoLastAt = os.clock()
        local devId, devName = nil, nil
        local f = io.open(progressState.logFile, "r")
        if f then
            local n = 0
            for line in f:lines() do
                n = n + 1
                -- Example: Selected device: cuda:0 (AMD Radeon RX 9070)
                local id, name = line:match("^Selected device:%s*([%w%-%_:%.]+)%s*%((.+)%)")
                if id then
                    devId = id
                    devName = name
                end
                -- Example: STEMWERK: torch.cuda.set_device(1) -> current_device=1 (AMD Radeon 780M Graphics)
                local idx, name2 = line:match("^STEMWERK:%s*torch%.cuda%.set_device%((%d+)%)%s*%-%>%s*current_device=%d+%s*%((.+)%)")
                if idx then
                    devId = "cuda:" .. idx
                    devName = name2
                end
                if n >= 80 then break end
            end
            f:close()
        end
        progressState._deviceId = devId
        progressState._deviceName = devName
    end

    -- === THEME TOGGLE (top right) ===
    local iconScale = 0.66
    local themeSize = math.max(PS(12), math.floor(PS(20) * iconScale + 0.5))
    local themeX = w - themeSize - PS(10)
    local themeY = PS(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = utilityMode and 1.0 or updateControlsOpacity(progressState, mouseInControls)

    if utilityMode then
        local _uc = {
            S = PS, w = w, mx = mx, my = my,
            mouseDown = mouseDown,
            rightMouseDown = rightMouseDown,
            state = progressState,
            setLanguageFn = setLanguage,
            themeX = themeX, themeY = themeY, themeSize = themeSize,
        }
        UI_CONTROLS.drawUtilityControls(_uc)
        if _uc.tooltipText then
            tooltipText = _uc.tooltipText
            tooltipX = _uc.tooltipX
            tooltipY = _uc.tooltipY
        end
    else
        if SETTINGS.darkMode then
            gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.5) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
            gfx.set(0, 0, 0, 1 * controlsOpacity)
            gfx.circle(themeX + themeSize/2 + 3, themeY + themeSize/2 - 2, themeSize/2 - 3, 1, 1)
        else
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.7) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/3, 1, 1)
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.7) * controlsOpacity)
            for i = 0, 7 do
                local angle = i * math.pi / 4
                local x1 = themeX + themeSize/2 + math.cos(angle) * (themeSize/3 + 1)
                local y1 = themeY + themeSize/2 + math.sin(angle) * (themeSize/3 + 1)
                local x2 = themeX + themeSize/2 + math.cos(angle) * (themeSize/2 - 1)
                local y2 = themeY + themeSize/2 + math.sin(angle) * (themeSize/2 - 1)
                gfx.line(x1, y1, x2, y2)
            end
        end
        if themeHover and controlsOpacity > 0.3 then
            GUI.uiClickedThisFrame = true
            tooltipText = getThemeToggleTooltip()
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
            if rightMouseDown and not (progressState.wasRightMouseDown or false) then cycleThemePreset() end
            if mouseDown and not progressState.wasMouseDown then
                SETTINGS.darkMode = not SETTINGS.darkMode; updateTheme(); saveSettings()
            end
        end
        local langCode = string.upper(SETTINGS.language or "EN")
        local langW = PS(22)
        local langH = PS(14)
        local langX = themeX - langW - PS(6)
        local langY = themeY + (themeSize - langH) / 2
        local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local langTextW = gfx.measurestr(langCode)
        gfx.set(0.5, 0.6, 0.8, (langHover and 1 or 0.4) * controlsOpacity)
        gfx.x = langX + (langW - langTextW) / 2
        gfx.y = langY
        gfx.drawstr(langCode)
        if langHover and controlsOpacity > 0.3 then
            GUI.uiClickedThisFrame = true
            tooltipText = T("tooltip_lang")
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
        end
        if langHover and rightMouseDown and not (progressState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            SETTINGS.tooltips = not SETTINGS.tooltips; saveSettings()
        end
        if langHover and mouseDown and not progressState.wasMouseDown and controlsOpacity > 0.3 then
            local langs = {"en", "nl", "de"}
            local currentIdx = 1
            for i, l in ipairs(langs) do if l == SETTINGS.language then currentIdx = i break end end
            setLanguage(langs[(currentIdx % #langs) + 1]); saveSettings()
        end
        local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
        local fxX = themeX + (themeSize - fxSize) / 2
        local fxY = themeY + themeSize + PS(3)
        local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)
        local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
        if SETTINGS.visualFX then gfx.set(0.4, 0.9, 0.5, fxAlpha) else gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6) end
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2; gfx.y = fxY + PS(1); gfx.drawstr(fxText)
        if SETTINGS.visualFX then
            gfx.set(1, 1, 0.5, fxAlpha * 0.8)
            gfx.circle(fxX - PS(1), fxY + PS(2), PS(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - PS(2), PS(1.5), 1, 1)
        else
            gfx.set(0.8, 0.3, 0.3, fxAlpha)
            gfx.line(fxX - PS(1), fxY + fxSize / 2, fxX + fxSize + PS(1), fxY + fxSize / 2)
        end
        if fxHover and controlsOpacity > 0.3 then
            GUI.uiClickedThisFrame = true
            local fxTip = SETTINGS.visualFX and (T("fx_disable") or "Disable visual effects") or (T("fx_enable") or "Enable visual effects")
            tooltipText = fxTip .. " " .. (T("fx_switch_native_suffix") or "Right-click: switch to REAPER Native UI.")
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
        end
        if fxHover and mouseDown and not progressState.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.visualFX = not SETTINGS.visualFX; saveSettings()
        end
        if fxHover and rightMouseDown and not (progressState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            SETTINGS.themePreset = "reaper_native"
            updateTheme()
            saveSettings()
        end
    end

    -- NOTE: wasMouseDown is set at END of function to allow art click detection

    -- Get selected stems for colors
    local selectedStems = {}
    local runModel = effectiveRunModel()
    local runIs6Stem = (runModel == "htdemucs_6s")
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or runIs6Stem) then
            table.insert(selectedStems, stem)
        end
    end

    -- Single-track progress layout
    local barX = PS(38)
    local barY = PS(102)
    local barW = w - (barX * 2)
    local barH = PS(24)

    -- Model badge (align with progress bar at right side)
    local modelText = runModel
    gfx.setfont(1, "Arial", PS(11))
    local modelW = gfx.measurestr(modelText) + PS(16)
    local badgeX = barX + barW - modelW
    local badgeY = barY + math.floor((barH - PS(18)) / 2)
    local badgeH = PS(18)
    local badgeRadius = getThemeRadius(PS, 8, math.floor(badgeH / 2))
    local badgeBorderWeight = getThemeBorderWeight(PS, 1)
    drawThemeSurfaceBox(badgeX, badgeY, modelW, badgeH, THEME.inputBg, THEME.border, 1, 1, badgeRadius, badgeBorderWeight, 0.55, "process")
    gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
    gfx.x = badgeX + PS(8)
    gfx.y = badgeY + PS(2)
    gfx.drawstr(modelText)

    -- Title / branding
    gfx.setfont(1, "Arial", PS(18), string.byte('b'))
    local titleX = PS(25)
    local titleY = PS(28)

    local drumKitMode = isDrumKitWorkflowActive()

    -- In multi-track mode, show which track
    if multiTrackQueue.active then
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = titleX
        gfx.y = titleY
        local trackPrefix = T("track_prefix") or "Track"
        gfx.drawstr(tostring(trackPrefix) .. " " .. multiTrackQueue.currentIndex .. "/" .. multiTrackQueue.totalTracks .. ": " .. (multiTrackQueue.currentTrackName or ""))
    else
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = titleX
        gfx.y = titleY
        if drumKitMode then
            gfx.drawstr("Drum Kit Split")
        else
            local singleTrackLabel = T("single_track") or "Single-Track"
            gfx.drawstr(singleTrackLabel .. " ")
            local aiW = gfx.measurestr(singleTrackLabel .. " ")
            if utilityMode then
                gfx.drawstr("STEMwerk")
            else
                drawWavingStemwerkLogo({
                    x = titleX + aiW,
                    y = titleY,
                    fontSize = PS(18),
                    time = os.clock(),
                    amp = PS(2),
                    speed = 3,
                    phase = 0.5,
                    alphaStem = 1,
                    alphaRest = 1,
                })
            end
        end
    end

    -- Stem indicators (simple colored boxes)
    local stemX = PS(25)
    local stemY = PS(63)
    local stemBoxSize = PS(14)
    gfx.setfont(1, "Arial", PS(11))
    if drumKitMode then
        local kitLabels = DKS_WORKFLOW.KIT_STEMS or {}
        for _, stemLabel in ipairs(kitLabels) do
            if utilityMode then
                local ur, ug, ub = utilityProgressMutedColor()
                gfx.set(ur, ug, ub, 1)
            else
                gfx.set((THEME.accent[1] or 0.5), (THEME.accent[2] or 0.5), (THEME.accent[3] or 0.5), 1)
            end
            gfx.rect(stemX, stemY, stemBoxSize, stemBoxSize, 1)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = stemX + stemBoxSize + PS(6)
            gfx.y = stemY + PS(1)
            gfx.drawstr(stemLabel)
            stemX = stemX + stemBoxSize + gfx.measurestr(stemLabel) + PS(20)
        end
    else
        for _, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or runIs6Stem) then
                -- Stem marker box. REAPER Native keeps processing windows neutral.
                if utilityMode then
                    local ur, ug, ub = utilityProgressMutedColor()
                    gfx.set(ur, ug, ub, 1)
                else
                    gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
                end
                gfx.rect(stemX, stemY, stemBoxSize, stemBoxSize, 1)
                -- Stem name
                gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
                gfx.x = stemX + stemBoxSize + PS(6)
                gfx.y = stemY + PS(1)
                local stemLabel = getStemDisplayName(stem)
                gfx.drawstr(stemLabel)
                stemX = stemX + stemBoxSize + gfx.measurestr(stemLabel) + PS(20)
            end
        end
    end

    -- Progress bar background
    local mainBarRadius = getThemeRadius(PS, 4, math.floor(barH / 2))
    drawThemeShadow(barX, barY, barW, barH, mainBarRadius, 0.6, "process")
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 1)
    gfx.rect(barX, barY, barW, barH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(barX, barY, barW, barH, 0)
    drawLightSurfaceFinish(barX + 1, barY + 1, math.max(1, barW - 2), math.max(1, barH - 2), math.max(0, mainBarRadius - 1), "process", 1)

    -- Progress bar fill. Native utility mode uses a single muted REAPER-ish
    -- blue/green fill instead of the decorative stem gradient.
    local fillWidth = math.floor(barW * progressState.percent / 100)
    if fillWidth > 0 and #selectedStems > 0 then
        if utilityMode then
            local ur, ug, ub = utilityProgressColor()
            gfx.set(ur, ug, ub, 1)
            gfx.rect(barX + 1, barY + 1, math.max(1, fillWidth - 2), barH - 2, 1)
        else
            for x = 0, fillWidth - 1 do
                local pos = x / math.max(1, fillWidth - 1)
                local idx = math.floor(pos * (#selectedStems - 1)) + 1
                local nextIdx = math.min(idx + 1, #selectedStems)
                local blend = (pos * (#selectedStems - 1)) % 1

                idx = math.max(1, math.min(idx, #selectedStems))
                nextIdx = math.max(1, math.min(nextIdx, #selectedStems))

                local r = (selectedStems[idx].color[1] * (1 - blend) + selectedStems[nextIdx].color[1] * blend) / 255
                local g = (selectedStems[idx].color[2] * (1 - blend) + selectedStems[nextIdx].color[2] * blend) / 255
                local b = (selectedStems[idx].color[3] * (1 - blend) + selectedStems[nextIdx].color[3] * blend) / 255

                gfx.set(r, g, b, 1)
                gfx.rect(barX + x, barY + 1, 1, barH - 2, 1)
            end
        end
    end

    local function drawProgressText(text, x, y, alpha)
        alpha = alpha or 1
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, 0.6 * alpha)
            gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
            gfx.x, gfx.y = x - 1, y + 1; gfx.drawstr(text)
            gfx.x, gfx.y = x + 1, y - 1; gfx.drawstr(text)
            gfx.x, gfx.y = x - 1, y - 1; gfx.drawstr(text)
            gfx.set(1, 1, 1, alpha)
        else
            gfx.set(1, 1, 1, 0.35 * alpha)
            gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
            gfx.set(0.08, 0.10, 0.12, alpha)
        end
        gfx.x, gfx.y = x, y
        gfx.drawstr(text)
    end

    -- Progress percentage in center of bar
    gfx.setfont(1, "Arial", PS(14), string.byte('b'))
    local percentText = string.format("%d%%", progressState.percent)
    local tw = gfx.measurestr(percentText)
    local px = barX + (barW - tw) / 2
    local py = barY + (barH - PS(14)) / 2
    drawProgressText(percentText, px, py, 1)

    local footerElapsed = os.time() - (progressState.startTime or os.time())
    local footerProcessedAudioDur = 0
    if itemSubSelection and itemSubSelEnd and itemSubSelStart and itemSubSelEnd > itemSubSelStart then
        footerProcessedAudioDur = itemSubSelEnd - itemSubSelStart
    elseif itemLen and itemLen > 0 then
        footerProcessedAudioDur = itemLen
    end
    local footerRealtimeFactor = (footerProcessedAudioDur > 0 and footerElapsed > 0) and (footerProcessedAudioDur / footerElapsed) or 0
    local footerDeviceDetail = (progressState.stage or ""):match("%[([^%]]+)%]") or nil

    -- Stage text inside the main progress bar, like the multi-track job bars.
    local stageDisplay = normalizeProgressStage(progressState.stage or (T("starting") or "Starting..."))
    local baseStageText = tostring(stageDisplay or "")
        :gsub("%s*%([^%)]*%)", "")
        :gsub("%s*%[[^%]]*%]", "")
        :gsub("%s+$", "")
    local elapsedMins = math.floor(math.max(0, footerElapsed) / 60)
    local elapsedSecs = math.max(0, footerElapsed) % 60
    local elapsedText = string.format("%d:%02d", elapsedMins, elapsedSecs)
    local stageStr = progressState.stage or ""
    local barEta = stageStr:match("ETA%s+([%d]+:%s*%d+)")
    if barEta then barEta = barEta:gsub("%s+", "") end
    local richParts = { elapsedText }
    if barEta and barEta ~= "" then
        local etaLabel = T("eta_label") or "ETA:"
        richParts[#richParts + 1] = tostring(etaLabel) .. " " .. tostring(barEta)
    end
    local inlineStageText = baseStageText
    if inlineStageText == "" then
        inlineStageText = T("processing_label") or "Processing"
    end
    if #richParts > 0 then
        inlineStageText = inlineStageText .. " (" .. table.concat(richParts, " | ") .. ")"
    end
    if footerDeviceDetail and footerDeviceDetail ~= "" then
        inlineStageText = inlineStageText .. " [" .. tostring(footerDeviceDetail) .. "]"
    end
    if inlineStageText ~= "" then
        gfx.setfont(1, "Arial", PS(11))
        local stageTextW = math.max(PS(110), barW - PS(170))
        local fittedStageText = fitTextToBox(inlineStageText, stageTextW, PS(11), PS(11))
        drawProgressText(fittedStageText, barX + PS(10), barY + PS(4), 0.95)
    end

    -- === NERD TERMINAL TOGGLE BUTTON ===
    local nerdBtnW = PS(22)
    local nerdBtnH = PS(18)
    local nerdBtnX = PS(25)
    local nerdBtnY = math.min(barY + barH + PS(8), h - PS(85))
    local nerdHover = mx >= nerdBtnX and mx <= nerdBtnX + nerdBtnW and my >= nerdBtnY and my <= nerdBtnY + nerdBtnH

    -- Draw nerd button (terminal icon: >_)
    if progressState.showTerminal then
        gfx.set(0.3, 0.8, 0.3, 1)  -- Green when active
    else
        gfx.set(0.4, 0.4, 0.4, nerdHover and 1 or 0.6)
    end
    gfx.rect(nerdBtnX, nerdBtnY, nerdBtnW, nerdBtnH, 1)
    gfx.set(0, 0, 0, 1)
    gfx.setfont(1, "Courier", PS(10), string.byte('b'))
    gfx.x = nerdBtnX + PS(3)
    gfx.y = nerdBtnY + PS(3)
    gfx.drawstr(">_")

    -- Handle nerd button click and tooltip
    if nerdHover then
        GUI.uiClickedThisFrame = true
        if utilityMode then
            tooltipText = progressState.showTerminal and (T("tooltip_nerd_mode_hide") or "Switch to Art View") or (T("tooltip_nerd_mode_show") or "Nerd Mode: Show terminal output")
        elseif progressState.showTerminal then
            tooltipText = T("tooltip_nerd_mode_hide") or "Switch to Art View"
        else
            tooltipText = T("tooltip_nerd_mode_show") or "Nerd Mode: Show terminal output"
        end
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if mouseDown and not progressState.wasMouseDown then
            progressState.showTerminal = not progressState.showTerminal
        end
    end

    if isModelLoadingStage(progressState.stage)
        and drawModelLoadNoteBox(
            nerdBtnX + nerdBtnW + PS(8),
            nerdBtnY,
            math.max(PS(100), w - (nerdBtnX + nerdBtnW + PS(8)) - PS(25)),
            nerdBtnH,
            mx,
            my
        )
    then
            GUI.uiClickedThisFrame = true
            tooltipText = T("model_load_note_long") or "First model load can take longer. STEMwerk may download the model and warm up the selected backend."
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end

    local footerSummaryActive = (not progressState.showTerminal) and (
        footerRealtimeFactor > 0 or (footerDeviceDetail and footerDeviceDetail ~= "")
    )
    local previewStatusFontSize = PS(10)
    local previewStatusPadY = PS(10)
    gfx.setfont(1, "Arial", previewStatusFontSize)
    local previewStatusLineH = gfx.texth
    local previewStatusRowGap = footerSummaryActive and PS(4) or 0
    local singleFooterReserve = previewStatusLineH * (footerSummaryActive and 2 or 1) + previewStatusPadY * 2 + previewStatusRowGap

    -- === DISPLAY AREA (ART or TERMINAL) ===
    local displayY = nerdBtnY + nerdBtnH + PS(10)
    local bottomPad = singleFooterReserve + (progressState.showTerminal and PS(8) or 0)
    local displayH = h - displayY - bottomPad
    local displayX = PS(15)
    local displayW = w - PS(30)

    if displayH > PS(60) then
        if progressState.showTerminal then
            -- === NERD TERMINAL VIEW ===
            -- Theme-aware terminal palette (dark/light)
            local termBgR, termBgG, termBgB, termBgA
            local termBorderR, termBorderG, termBorderB, termBorderA
            local termHeaderR, termHeaderG, termHeaderB, termHeaderA
            local termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA
            local termTextR, termTextG, termTextB, termTextA
            local termDimR, termDimG, termDimB, termDimA
            local termOkR, termOkG, termOkB, termOkA
            local termWarnR, termWarnG, termWarnB, termWarnA
            local termErrR, termErrG, termErrB, termErrA
            local termProgR, termProgG, termProgB, termProgA

            if utilityMode then
                if SETTINGS.darkMode then
                    termBgR, termBgG, termBgB, termBgA = 0.04, 0.04, 0.04, 1
                    termBorderR, termBorderG, termBorderB, termBorderA = 0.35, 0.35, 0.35, 1
                    termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.16, 0.16, 0.16, 1
                    termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.86, 0.86, 0.86, 1
                    termTextR, termTextG, termTextB, termTextA = 0.78, 0.78, 0.78, 1
                    termDimR, termDimG, termDimB, termDimA = 0.55, 0.55, 0.55, 1
                    termOkR, termOkG, termOkB, termOkA = 0.68, 0.78, 0.68, 1
                    termWarnR, termWarnG, termWarnB, termWarnA = 0.82, 0.68, 0.40, 1
                    termErrR, termErrG, termErrB, termErrA = 0.86, 0.38, 0.38, 1
                    termProgR, termProgG, termProgB, termProgA = 0.64, 0.74, 0.64, 1
                else
                    termBgR, termBgG, termBgB, termBgA = 0.96, 0.96, 0.94, 1
                    termBorderR, termBorderG, termBorderB, termBorderA = 0.58, 0.58, 0.54, 1
                    termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.86, 0.86, 0.82, 1
                    termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.10, 0.10, 0.10, 1
                    termTextR, termTextG, termTextB, termTextA = 0.20, 0.20, 0.18, 1
                    termDimR, termDimG, termDimB, termDimA = 0.46, 0.46, 0.42, 1
                    termOkR, termOkG, termOkB, termOkA = 0.24, 0.40, 0.24, 1
                    termWarnR, termWarnG, termWarnB, termWarnA = 0.55, 0.38, 0.10, 1
                    termErrR, termErrG, termErrB, termErrA = 0.70, 0.12, 0.12, 1
                    termProgR, termProgG, termProgB, termProgA = 0.24, 0.40, 0.24, 1
                end
            elseif SETTINGS.darkMode then
                termBgR, termBgG, termBgB, termBgA = 0.02, 0.02, 0.03, 0.98
                termBorderR, termBorderG, termBorderB, termBorderA = 0.2, 0.8, 0.2, 0.5
                termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.2, 0.6, 0.2, 1
                termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0, 0, 0, 1
                termTextR, termTextG, termTextB, termTextA = 0.3, 0.9, 0.3, 0.9
                termDimR, termDimG, termDimB, termDimA = 0.3, 0.5, 0.3, 0.7
                termOkR, termOkG, termOkB, termOkA = 0.5, 1, 0.5, 1
                termWarnR, termWarnG, termWarnB, termWarnA = 1, 0.8, 0.3, 1
                termErrR, termErrG, termErrB, termErrA = 1, 0.3, 0.3, 1
                termProgR, termProgG, termProgB, termProgA = 0.3, 0.8, 1, 1
            else
                -- Light mode: soft paper terminal with dark text + STEMwerk green accents
                termBgR, termBgG, termBgB, termBgA = 0.98, 0.98, 0.99, 0.98
                termBorderR, termBorderG, termBorderB, termBorderA = 0.15, 0.55, 0.2, 0.45
                termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.75, 0.92, 0.78, 1
                termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.05, 0.08, 0.05, 1
                termTextR, termTextG, termTextB, termTextA = 0.08, 0.12, 0.08, 0.95
                termDimR, termDimG, termDimB, termDimA = 0.20, 0.30, 0.20, 0.75
                termOkR, termOkG, termOkB, termOkA = 0.12, 0.45, 0.18, 1
                termWarnR, termWarnG, termWarnB, termWarnA = 0.65, 0.45, 0.05, 1
                termErrR, termErrG, termErrB, termErrA = 0.75, 0.10, 0.10, 1
                termProgR, termProgG, termProgB, termProgA = 0.08, 0.35, 0.75, 1
            end

            -- Accent tint: cycle through selected stems as progress advances (nice variation).
            local accentR, accentG, accentB = THEME.accent[1], THEME.accent[2], THEME.accent[3]
            if (not utilityMode) and selectedStems and #selectedStems > 0 then
                local n = #selectedStems
                local p = tonumber(progressState.percent) or 0
                local idx = math.floor((p / 100) * n) + 1
                if idx < 1 then idx = 1 end
                if idx > n then idx = n end
                local sc = selectedStems[idx].color or {255, 255, 255}
                accentR, accentG, accentB = (sc[1] or 255) / 255, (sc[2] or 255) / 255, (sc[3] or 255) / 255
            end

            -- Apply tint to header/border (keep error/warn colors intact).
            if not utilityMode then
                if SETTINGS.darkMode then
                    termBorderR, termBorderG, termBorderB = accentR, accentG, accentB
                    termBorderA = 0.55
                    -- Slightly dimmed accent for header fill so black header text stays readable.
                    termHeaderR, termHeaderG, termHeaderB, termHeaderA = accentR * 0.75, accentG * 0.75, accentB * 0.75, 1
                    -- Normal text follows accent a bit (variety), but keep it bright enough.
                    termTextR, termTextG, termTextB = math.max(0.15, accentR * 0.9), math.max(0.2, accentG * 0.9), math.max(0.15, accentB * 0.9)
                else
                    -- Light mode: tint header/border only; keep normal text dark for readability.
                    termBorderR, termBorderG, termBorderB = accentR * 0.5, accentG * 0.6, accentB * 0.5
                    termBorderA = 0.45
                    termHeaderR = 0.85 + accentR * 0.12
                    termHeaderG = 0.85 + accentG * 0.12
                    termHeaderB = 0.85 + accentB * 0.12
                    termHeaderA = 1
                    termTextR, termTextG, termTextB = readableTerminalAccent(accentR, accentG, accentB)
                end

                -- Match the LED/progress tint to the active track color when available.
                if progressState.uiColor and type(progressState.uiColor) == "table" then
                    termProgR, termProgG, termProgB = progressState.uiColor[1] or termProgR, progressState.uiColor[2] or termProgG, progressState.uiColor[3] or termProgB
                end
            end

            -- Dark terminal background
            gfx.set(termBgR, termBgG, termBgB, termBgA)
            gfx.rect(displayX, displayY, displayW, displayH, 1)

            -- Terminal border (green)
            gfx.set(termBorderR, termBorderG, termBorderB, termBorderA)
            gfx.rect(displayX, displayY, displayW, displayH, 0)
            if SETTINGS.visualFX and not utilityMode then
                drawTerminalFx(displayX, displayY, displayW, displayH, uiNow(), termBorderR, termBorderG, termBorderB, termProgR, termProgG, termProgB)
            end

            -- Terminal header
            gfx.set(termHeaderR, termHeaderG, termHeaderB, termHeaderA)
            gfx.rect(displayX, displayY, displayW, PS(18), 1)
            gfx.set(termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA)
            gfx.setfont(1, "Courier", PS(10), string.byte('b'))
            gfx.x = displayX + PS(5)
            gfx.y = displayY + PS(3)
            gfx.drawstr(T("terminal_output_title") or "DEMUCS OUTPUT")

            -- Read latest terminal output from stdout file
            local now = uiNow()
            if now - progressState.lastTerminalUpdate > UI_PACING.terminalReadInterval then
                progressState.lastTerminalUpdate = now
                progressState.terminalLines = {}
                if progressState.stdoutFile then
                    local f = io.open(progressState.stdoutFile, "r")
                    if f then
                        for line in f:lines() do
                            local formatted = formatProgressLine(line, 1)
                            table.insert(progressState.terminalLines, formatted or line)
                        end
                        f:close()
                    end
                end
            end

            -- Draw terminal lines (monospace, green on black)
            local termContentY = displayY + PS(22)
            local termContentH = displayH - PS(30)
            local lineHeight = PS(12)
            local maxLines = math.floor(termContentH / lineHeight)
            local startLine = math.max(1, #progressState.terminalLines - maxLines + 1)

            gfx.setfont(1, "Courier", PS(9))
            local lineY = termContentY
            local progressNeedle = (T("progress_label") or "Progress") .. ":"
            for i = startLine, #progressState.terminalLines do
                if lineY < displayY + displayH - PS(5) then
                    local line = progressState.terminalLines[i] or ""
                    -- Truncate long lines
                    if #line > 80 then line = line:sub(1, 77) .. ".." end

                    -- Color based on content
                    if line:match("error") or line:match("Error") or line:match("ERROR") then
                        gfx.set(termErrR, termErrG, termErrB, termErrA)  -- Error
                    elseif line:match("warning") or line:match("Warning") then
                        gfx.set(termWarnR, termWarnG, termWarnB, termWarnA)  -- Warning
                    elseif line:match("PROGRESS") or line:find(progressNeedle, 1, true) then
                        gfx.set(termProgR, termProgG, termProgB, termProgA)  -- Progress
                    elseif line:match("Separating") or line:match("100%%") then
                        gfx.set(termOkR, termOkG, termOkB, termOkA)  -- Success
                    else
                        gfx.set(termTextR, termTextG, termTextB, termTextA)  -- Normal
                    end

                    gfx.x = displayX + PS(5)
                    gfx.y = lineY
                    gfx.drawstr(line)
                    lineY = lineY + lineHeight
                end
            end

            -- Blinking cursor at bottom
            if (not utilityMode) and math.floor(now * 2) % 2 == 0 then
                gfx.set(termOkR, termOkG, termOkB, 1)
                gfx.x = displayX + PS(5)
                gfx.y = math.min(lineY, displayY + displayH - lineHeight - PS(5))
                gfx.drawstr("_")
            end

            -- Terminal hint
            gfx.set(termDimR, termDimG, termDimB, termDimA)
            gfx.setfont(1, "Courier", PS(8))
            local termHint = utilityMode and "Click >_ to return to progress" or (T("terminal_hint_return_to_art") or "Click >_ to return to art")
            local termHintW = gfx.measurestr(termHint)
            gfx.x = displayX + (displayW - termHintW) / 2
            gfx.y = displayY + displayH - PS(16)
            gfx.drawstr(termHint)

        else
            -- === ART INFO VIEW ===
            local artHover = mx >= displayX and mx <= displayX + displayW and my >= displayY and my <= displayY + displayH
            if artHover and not utilityMode then
                tooltipText = T("click_new_art")
                tooltipX, tooltipY = mx + PS(10), my + PS(15)
                if mouseDown and not progressState.wasMouseDown then
                    generateNewArt()
                end
            end
        end
    else
        -- Window is too short: show a clear hint instead of "green toggle but nothing".
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.9)
        gfx.setfont(1, "Arial", PS(9))
        local msg = T("resize_window_for_terminal") or "Tip: resize this window taller to view Terminal / Art"
        local msgW = gfx.measurestr(msg)
        gfx.x = math.max(PS(10), (w - msgW) / 2)
        gfx.y = nerdBtnY + nerdBtnH + PS(2)
        gfx.drawstr(msg)
    end

    -- Bottom footer (aligned with the multi-track Processing footer)
    local stageStr = progressState.stage or ""
    local bottomEta = stageStr:match("ETA%s+([%d]+:%s*%d+)")
    if bottomEta then bottomEta = bottomEta:gsub("%s+", "") end
    local deviceDetail = footerDeviceDetail

    local elapsed = footerElapsed
    local elapsedMins = math.floor(elapsed / 60)
    local elapsedSecs = elapsed % 60
    local etaText = ""
    if bottomEta and bottomEta ~= "" then
        local etaLabel = T("eta_label") or "ETA:"
        etaText = " | " .. tostring(etaLabel) .. " " .. tostring(bottomEta)
    end

    local segValue = "30"
    local footerModel = effectiveRunModel()
    local modelDisplay = (footerModel == "htdemucs_ft")
        and (T("model_label_quality") or "Quality")
        or ((footerModel == "htdemucs_6s") and (T("model_label_6stem") or "6-Stem") or (T("model_label_fast") or "Fast"))
    local mtTime = T("mt_time") or "Time"
    local mtSeg = T("mt_seg") or "Seg"
    local mtCancel = T("mt_cancel") or "ESC=cancel"
    local cancelBtnText = progressUiLabel("progress_cancel_button", T("cancel") or "Cancel")

    local contextItem = timeSelectionSourceItem or selectedItem
    local sourceTrackName, sourceItemName = HELPERS.getStemNamingContextForItem(contextItem, "Selection", "Selection")
    local currentLabel = sourceTrackName or sourceItemName or "Selection"
    if sourceItemName and sourceItemName ~= "" and sourceItemName ~= currentLabel then
        currentLabel = tostring(currentLabel) .. " - " .. tostring(sourceItemName)
    end

    local processedAudioDur = footerProcessedAudioDur
    local audioDurStr = processedAudioDur > 0 and string.format("%.1fs", processedAudioDur) or nil
    local realtimeFactor = footerRealtimeFactor

    local leftParts = {
        string.format("%s: %d:%02d%s", mtTime, elapsedMins, elapsedSecs, etaText),
        string.format("%s: %s", mtSeg, segValue),
        modelDisplay,
    }
    local rightParts = {}
    if currentLabel and currentLabel ~= "" then
        if audioDurStr then
            rightParts[#rightParts + 1] = string.format("%s (%s, %d:%02d)", currentLabel, audioDurStr, elapsedMins, elapsedSecs)
        else
            rightParts[#rightParts + 1] = currentLabel
        end
    end
    rightParts[#rightParts + 1] = mtCancel

    local summaryLeft = nil
    if (not progressState.showTerminal) and realtimeFactor > 0 then
        local speedFmt = T("mt_footer_speed_line") or "Speed %.2fx realtime"
        summaryLeft = string.format(speedFmt, realtimeFactor)
    end
    local summaryRight = nil
    if not progressState.showTerminal then
        summaryRight = deviceDetail
    end

    local statusFontSize = PS(10)
    local statusPadX = PS(10)
    local statusBlockPadY = PS(10)
    local statusBlockAlpha = progressState.showTerminal and 0.8 or 0.96
    local statusBlockBorderAlpha = progressState.showTerminal and 0.85 or 0.92
    gfx.setfont(1, "Arial", statusFontSize)
    local statusLineH = gfx.texth
    local hasSummaryFooter = (summaryLeft and summaryLeft ~= "") or (summaryRight and summaryRight ~= "")
    local statusRowGap = hasSummaryFooter and PS(4) or 0
    local statusBlockH = statusLineH * (hasSummaryFooter and 2 or 1) + statusBlockPadY * 2 + statusRowGap
    local statusBlockY = h - statusBlockH
    local function setFooterTooltip(x, y, ww, hh, text)
        if SETTINGS and SETTINGS.tooltips == false then return end
        if not text or text == "" then return end
        if mx >= x and mx <= x + ww and my >= y and my <= y + hh then
            tooltipText = text
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
        end
    end
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], statusBlockAlpha)
    gfx.rect(0, statusBlockY, w, statusBlockH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], statusBlockBorderAlpha)
    gfx.rect(0, statusBlockY, w, statusBlockH, 0)

    -- Explicit cancel button in processing window (same behavior as ESC / window close).
    local cancelBtnH = PS(28)
    local cancelBtnW = math.max(PS(96), gfx.measurestr(cancelBtnText) + PS(26))
    local cancelBtnX = w - PS(12) - cancelBtnW
    local cancelBtnY = statusBlockY - cancelBtnH - PS(10)
    local cancelHover = mx >= cancelBtnX and mx <= cancelBtnX + cancelBtnW and my >= cancelBtnY and my <= cancelBtnY + cancelBtnH
    local cancelFill = cancelHover and {0.85, 0.24, 0.24} or {0.72, 0.20, 0.20}
    drawThemeSurfaceBox(cancelBtnX, cancelBtnY, cancelBtnW, cancelBtnH, cancelFill, THEME.border, 1, 0.98, getThemeRadius(PS, math.floor(cancelBtnH / 2), math.floor(cancelBtnH / 2)), getThemeBorderWeight(PS, 1), 0.35, "button")
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(12), string.byte('b'))
    local cancelTextW = gfx.measurestr(cancelBtnText)
    gfx.x = cancelBtnX + (cancelBtnW - cancelTextW) / 2
    gfx.y = cancelBtnY + math.floor((cancelBtnH - gfx.texth) / 2)
    gfx.drawstr(cancelBtnText)
    if cancelHover then
        GUI.uiClickedThisFrame = true
        tooltipText = progressUiLabel("progress_cancel_tooltip", progressUiLabel("tooltip_cancel_processing", "Cancel separation"))
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if mouseDown and not progressState.wasMouseDown then
            cancelClicked = true
            progressState.cancelRequested = true
        end
    end

    local availableW = w - statusPadX * 2
    local splitGap = PS(16)
    local leftW = math.max(PS(180), math.floor((availableW - splitGap) * 0.48))
    local rightW = math.max(PS(180), availableW - leftW - splitGap)
    local row1Y = statusBlockY + statusBlockPadY
    local row2Y = row1Y + statusLineH + statusRowGap

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local leftLabel, _ = fitTextToBox(table.concat(leftParts, " | "), leftW, statusFontSize, statusFontSize)
    local rightLabel, rightTw = fitTextToBox(table.concat(rightParts, " | "), rightW, statusFontSize, statusFontSize)
    gfx.x = statusPadX
    gfx.y = row1Y
    gfx.drawstr(leftLabel)
    setFooterTooltip(statusPadX, row1Y, leftW, statusLineH, T("tooltip_footer_selected") or "Shows the current processing selection/time context.")
    gfx.x = w - statusPadX - rightTw
    gfx.y = row1Y
    gfx.drawstr(rightLabel)
    setFooterTooltip(w - statusPadX - rightW, row1Y, rightW, statusLineH, T("tooltip_footer_output") or "Shows current processing target and completion hint.")

    if hasSummaryFooter then
        local summaryFontSize = PS(9)
        gfx.setfont(1, "Arial", summaryFontSize)
        local summaryLeftLabel = fitTextToBox(summaryLeft or "", leftW, summaryFontSize, summaryFontSize)
        local summaryRightLabel, summaryRightTw = fitTextToBox(summaryRight or "", rightW, summaryFontSize, summaryFontSize)
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.78)
        gfx.x = statusPadX
        gfx.y = row2Y
        gfx.drawstr(summaryLeftLabel)
        setFooterTooltip(statusPadX, row2Y, leftW, statusLineH, T("tooltip_footer_location") or "Shows runtime details and progress summary.")
        if summaryRight and summaryRight ~= "" then
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.68)
            gfx.x = w - statusPadX - summaryRightTw
            gfx.y = row2Y
            gfx.drawstr(summaryRightLabel)
            setFooterTooltip(w - statusPadX - rightW, row2Y, rightW, statusLineH, T("tooltip_footer_location") or "Shows runtime details and progress summary.")
        end
    end

    -- flarkAUDIO logo at top (translucent) - skipped in utility mode
    if not utilityMode then
        gfx.setfont(1, "Arial", PS(10))
        local flarkPart = "flark"
        local flarkPartW = gfx.measurestr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        local audioPart = "AUDIO"
        local audioPartW = gfx.measurestr(audioPart)
        local totalLogoW = flarkPartW + audioPartW
        local logoStartX = (w - totalLogoW) / 2
        gfx.set(1.0, 0.5, 0.1, 0.5)
        gfx.setfont(1, "Arial", PS(10))
        gfx.x = logoStartX
        gfx.y = PS(3)
        gfx.drawstr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        gfx.x = logoStartX + flarkPartW
        gfx.y = PS(3)
        gfx.drawstr(audioPart)
    end

    -- === DRAW TOOLTIP (always on top, with STEM colors) ===
    if tooltipText then
        gfx.setfont(1, "Arial", PS(11))
        local padding = PS(8)
        local lineH = PS(14)
        local maxTextW = math.min(w * 0.62, PS(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    -- Update mouse state AFTER all click handling in this function.
    progressState.wasMouseDown = mouseDown
    progressState.wasRightMouseDown = rightMouseDown
    gfx.update()
    return cancelClicked
end

-- Refactor flow helpers into module-like namespaces to reduce top-level locals.
WORKFLOW = WORKFLOW or {}
HELPERS = HELPERS or {}
UI = UI or {}

dofile(script_path .. "_internal/STEMwerk_Helpers.lua")
HELPERS.configure({ makeDir = makeDir, adjustTrackLayout = UI_Window.adjustTrackLayout })

dofile(script_path .. "_internal/STEMwerk_Workflow.lua")
WORKFLOW.configure({
    progressState                 = progressState,
    GUI                           = GUI,
    T                             = T,
    showMessage                   = showMessage,
    buildKnownSeparationFailureMessage = buildKnownSeparationFailureMessage,
    captureWindowGeometry         = captureWindowGeometry,
    saveSettings                  = saveSettings,
    ensureDependenciesInteractive = ensureDependenciesInteractive,
    getExtStateValue              = getExtStateValue,
    isAbsolutePath                = isAbsolutePath,
    quoteArg                      = quoteArg,
    canRunPython                  = canRunPython,
    handleArtAdvance              = UI_Window.handleArtAdvance,
    updateTheme                   = updateTheme,
    loadSettings                  = loadSettings,
    rgbToReaperColor              = rgbToReaperColor,
    suppressStderr                = suppressStderr,
    cleanupTempWorkDir            = cleanupTempWorkDir,
    drawProgressWindow            = drawProgressWindow,
    refreshPythonPathFromExtState = refreshPythonPathFromExtState,
    recordTimingEvent             = writeTimingEvent,
})

MESSAGES.configure({
    loadSettings                 = loadSettings,
    messageWindowLoop            = messageWindowLoop,
    hasTimeSelection             = hasTimeSelection,
    getProcessingSoloActive      = getProcessingSoloActive,
    AUDIBILITY                   = AUDIBILITY,
    resolveTimeSelectionTargets  = resolveTimeSelectionTargets,
    multiTrackQueue              = multiTrackQueue,
})

-- Store callback reference
finishSeparation = WORKFLOW.finishSeparationCallback

-- Replace only a portion of an item with stems (for time selection mode)
-- Splits the item at selection boundaries and replaces only the selected portion
function getItemDisplayNameForTakes(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return "Item" end
    local take = reaper.GetActiveTake(item)
    if take then
        local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if takeName and takeName ~= "" then
            return takeName
        end
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
            local sourcePath = reaper.GetMediaSourceFileName(source, "")
            if sourcePath and sourcePath ~= "" then
                return sourcePath:match("([^/\\]+)$") or sourcePath
            end
        end
    end
    local track = reaper.GetMediaItem_Track(item)
    if track then
        local _, trackName = reaper.GetTrackName(track)
        if trackName and trackName ~= "" then
            return trackName
        end
    end
    return "Item"
end

-- Post-processing: explode takes created by in-place output
-- mode: "none", "explode_new_tracks", "explode_in_place", "explode_in_order"
explodeTakesFromItem = function(item, mode, skipUndo, nameBase)
    mode = tostring(mode or "none")
    if mode == "none" then return 0 end
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return 0 end

    local track = reaper.GetMediaItem_Track(item)
    if not track or not reaper.ValidatePtr(track, "MediaTrack*") then return 0 end

    local takeCount = reaper.CountTakes(item)
    if not takeCount or takeCount < 2 then return 0 end

    local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if not itemPos or not itemLen or itemLen <= 0 then return 0 end

    local created = 0
    if not skipUndo then
        reaper.Undo_BeginBlock()
    end

    local function extractStemNameFromTakeLabel(takeName)
        if not takeName or takeName == "" then return nil end
        local stem = takeName:match("^Take%s+%d+/%d+:%s+.+%s%-%s+(.+)$")
        return stem or takeName
    end

    local function extractBaseNameFromTakeLabel(takeName)
        if not takeName or takeName == "" then return nil end
        return takeName:match("^Take%s+%d+/%d+:%s+(.+)%s%-%s+.+$")
    end

    local baseName = nameBase
    if not baseName or baseName == "" then
        for t = 0, takeCount - 1 do
            local take = reaper.GetTake(item, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                local parsed = extractBaseNameFromTakeLabel(takeName)
                if parsed and parsed ~= "" then
                    baseName = parsed
                    break
                end
            end
        end
    end
    if not baseName or baseName == "" then
        baseName = getItemDisplayNameForTakes(item)
    end

    local function copyTakePlaybackState(srcTake, dstTake)
        if not srcTake or not dstTake then return end
        if not reaper.ValidatePtr(srcTake, "MediaItem_Take*") or not reaper.ValidatePtr(dstTake, "MediaItem_Take*") then return end

        local playrate = tonumber(reaper.GetMediaItemTakeInfo_Value(srcTake, "D_PLAYRATE")) or 1.0
        if playrate < 0.0001 then playrate = 1.0 end
        local pitch = tonumber(reaper.GetMediaItemTakeInfo_Value(srcTake, "D_PITCH")) or 0.0
        local preservePitch = tonumber(reaper.GetMediaItemTakeInfo_Value(srcTake, "B_PPITCH")) or 0
        preservePitch = (preservePitch ~= 0) and 1 or 0
        local startOffset = tonumber(reaper.GetMediaItemTakeInfo_Value(srcTake, "D_STARTOFFS")) or 0.0

        reaper.SetMediaItemTakeInfo_Value(dstTake, "D_PLAYRATE", playrate)
        reaper.SetMediaItemTakeInfo_Value(dstTake, "D_PITCH", pitch)
        reaper.SetMediaItemTakeInfo_Value(dstTake, "B_PPITCH", preservePitch)
        reaper.SetMediaItemTakeInfo_Value(dstTake, "D_STARTOFFS", startOffset)
    end

    if mode == "explode_new_tracks" then
        -- Insert tracks after the source track
        local insertIdx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
        for t = 0, takeCount - 1 do
            local take = reaper.GetTake(item, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                if not takeName or takeName == "" then takeName = "Take " .. tostring(t + 1) end
                local takeColor = reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR")

                reaper.InsertTrackAtIndex(insertIdx, true)
                local newTrack = reaper.GetTrack(0, insertIdx)
                UI_Window.ensureTrackHeight(newTrack)
                insertIdx = insertIdx + 1
                if newTrack then
                    reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", takeName, true)
                    if takeColor and takeColor ~= 0 then
                        HELPERS.applyTrackColorIfEnabled(newTrack, takeColor)
                    end

                    local newItem = reaper.AddMediaItemToTrack(newTrack)
                    if newItem then
                        reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", itemPos)
                        reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", itemLen)

                        local newTake = reaper.AddTakeToMediaItem(newItem)
                        if newTake then
                            reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(take))
                            copyTakePlaybackState(take, newTake)
                            reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", takeName, true)
                            if takeColor and takeColor ~= 0 then
                                HELPERS.applyTakeColorIfEnabled(newTake, takeColor)
                                HELPERS.applyItemColorIfEnabled(newItem, takeColor)
                            end
                            created = created + 1
                        end
                    end
                end
            end
        end

        -- Remove the original multi-take item
        reaper.DeleteTrackMediaItem(track, item)

    elseif mode == "explode_in_place" or mode == "explode_in_order" then
        -- Collect original stem names so we can create a combined "Exploded A + B + C" label
        local explodedNames = {}
        local newTakes = {}
        local newItems = {}
        for t = 0, takeCount - 1 do
            local take = reaper.GetTake(item, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                if not takeName or takeName == "" then takeName = "Take " .. tostring(t + 1) end
                local stemName = extractStemNameFromTakeLabel(takeName)
                table.insert(explodedNames, stemName)
                local takeColor = reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR")

                local newItem = reaper.AddMediaItemToTrack(track)
                if newItem then
                    local pos = itemPos
                    if mode == "explode_in_order" then
                        -- Lay out sequentially in time, preserving take order
                        pos = itemPos + (t * itemLen)
                    end
                    reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", pos)
                    reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", itemLen)

                    local newTake = reaper.AddTakeToMediaItem(newItem)
                    if newTake then
                        reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(take))
                        copyTakePlaybackState(take, newTake)
                        -- Use the original take name for each new take (temporary)
                        reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", takeName, true)
                        if takeColor and takeColor ~= 0 then
                            HELPERS.applyTakeColorIfEnabled(newTake, takeColor)
                            HELPERS.applyItemColorIfEnabled(newItem, takeColor)
                        end
                        table.insert(newTakes, newTake)
                        table.insert(newItems, newItem)
                        created = created + 1
                    end
                end
            end
        end
        -- Name all created takes/items with a combined exploded label so Arrange shows it
        if #newTakes > 0 and #explodedNames > 0 then
        local combined = table.concat(explodedNames, " + ")
        local combinedName = baseName .. " - Exploded " .. combined
            for idx, nt in ipairs(newTakes) do
                if reaper.GetSetMediaItemTakeInfo_String then
                    reaper.GetSetMediaItemTakeInfo_String(nt, "P_NAME", combinedName, true)
                end
                local ni = newItems[idx]
                if ni and reaper.GetSetMediaItemInfo_String then
                    reaper.GetSetMediaItemInfo_String(ni, "P_NAME", combinedName, true)
                end
            end
            if newItems[1] then
                reaper.Main_OnCommand(40289, 0) -- Unselect all items
                reaper.SetMediaItemSelected(newItems[1], true)
            end
            reaper.UpdateArrange()
        end

        -- Remove the original multi-take item
        reaper.DeleteTrackMediaItem(track, item)
    end

    if not skipUndo then
        reaper.Undo_EndBlock("STEMwerk: Explode takes", -1)
    end
    return created
end

-- Create new tracks for each selected stem
function createStemTracks(item, stemPaths, itemPos, itemLen)
    local track = reaper.GetMediaItem_Track(item)
    local trackIdx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if trackName == "" then trackName = "Track " .. math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) end

    local take = reaper.GetActiveTake(item)
    local sourceTrackName = trackName
    local sourceItemName = trackName
    if take then
        local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if takeName and takeName ~= "" then
            sourceItemName = takeName:match("([^/\\]+)%.[^.]*$") or takeName
        else
            local source = reaper.GetMediaItemTake_Source(take)
            if source then
                local sourcePath = reaper.GetMediaSourceFileName(source, "")
                if sourcePath and sourcePath ~= "" then
                    sourceItemName = sourcePath:match("([^/\\]+)%.[^.]*$") or sourcePath
                end
            end
        end
    end
    local sourcePlaybackState = GLUE_HELPERS.snapshotTakePlaybackState(take)

    reaper.Undo_BeginBlock()

    local selectedCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and stemPaths[stem.name:lower()] then selectedCount = selectedCount + 1 end
    end

    local folderNames = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, "Stems")
    local importedItems = {}
    local importedPaths = {}

    local folderTrack = nil
    if SETTINGS.createFolder then
        reaper.InsertTrackAtIndex(trackIdx, true)
        folderTrack = reaper.GetTrack(0, trackIdx)
        reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", folderNames.folderBase .. " - Stems", true)
        reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
        HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
        UI_Window.ensureTrackHeight(folderTrack)
        trackIdx = trackIdx + 1
    end

    local importedCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = stemPaths[stem.name:lower()]
            if stemPath then
                reaper.InsertTrackAtIndex(trackIdx + importedCount, true)
                local newTrack = reaper.GetTrack(0, trackIdx + importedCount)
                UI_Window.ensureTrackHeight(newTrack)

                local outputNames = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stem.name)
                reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", outputNames.trackName, true)

                local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                HELPERS.applyTrackColorIfEnabled(newTrack, color)

                local newItem = reaper.AddMediaItemToTrack(newTrack)
                reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", itemPos)
                reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", itemLen)

                local newTake = reaper.AddTakeToMediaItem(newItem)
                reaper.SetMediaItemTake_Source(newTake, reaper.PCM_Source_CreateFromFile(stemPath))
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", outputNames.takeName, true)
                GLUE_HELPERS.applyTakePlaybackState(newTake, sourcePlaybackState, itemLen)
                HELPERS.applyItemColorIfEnabled(newItem, color)

                importedItems[#importedItems + 1] = newItem
                importedPaths[#importedPaths + 1] = stemPath
                importedCount = importedCount + 1
            end
        end
    end

    if folderTrack and importedCount > 0 then
        reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + importedCount - 1), "I_FOLDERDEPTH", -1)
    end

    if SETTINGS.deleteOriginalTrack then
        reaper.DeleteTrack(track)
    elseif SETTINGS.muteOriginalTrack then
        reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
    elseif SETTINGS.deleteOriginal then
        reaper.DeleteTrackMediaItem(track, item)
    elseif SETTINGS.muteOriginal then
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
    elseif SETTINGS.muteSelection then
        -- Mute only the selection portion by splitting and muting that part
        -- Use the ORIGINAL time selection (stored when separation started), not current selection
        local selStart, selEnd = timeSelectionStart, timeSelectionEnd
        -- Fallback to current selection if no stored selection (shouldn't happen, but safety)
        if selEnd <= selStart then
            selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        end
        local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

        -- Check if there's a valid time selection overlapping the item
        if selEnd > selStart and selStart < origItemEnd and selEnd > origItemPos then
            -- Clamp selection to item bounds
            local muteStart = math.max(selStart, origItemPos)
            local muteEnd = math.min(selEnd, origItemEnd)

            -- Split at selection start (if inside item)
            local middleItem = item
            if muteStart > origItemPos then
                middleItem = reaper.SplitMediaItem(item, muteStart)
            end

            -- Split at selection end (if inside remaining item)
            if middleItem then
                local midPos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
                local midEnd = midPos + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
                if muteEnd < midEnd then
                    reaper.SplitMediaItem(middleItem, muteEnd)
                end
                -- Mute the middle section
                reaper.SetMediaItemInfo_Value(middleItem, "B_MUTE", 1)
            end
        else
            -- No valid selection, mute entire item
            reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
        end
    elseif SETTINGS.deleteSelection then
        -- Delete only the selection portion by splitting and deleting that part
        -- Use the ORIGINAL time selection (stored when separation started), not current selection
        local selStart, selEnd = timeSelectionStart, timeSelectionEnd
        -- Fallback to current selection if no stored selection (shouldn't happen, but safety)
        if selEnd <= selStart then
            selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        end
        local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

        -- Check if there's a valid time selection overlapping the item
        if selEnd > selStart and selStart < origItemEnd and selEnd > origItemPos then
            -- Clamp selection to item bounds
            local delStart = math.max(selStart, origItemPos)
            local delEnd = math.min(selEnd, origItemEnd)

            -- Split at selection start (if inside item)
            local middleItem = item
            if delStart > origItemPos then
                middleItem = reaper.SplitMediaItem(item, delStart)
            end

            -- Split at selection end (if inside remaining item)
            if middleItem then
                local midPos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
                local midEnd = midPos + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
                if delEnd < midEnd then
                    reaper.SplitMediaItem(middleItem, delEnd)
                end
                -- Delete the middle section
                reaper.DeleteTrackMediaItem(track, middleItem)
            end
        else
            -- No valid selection, delete entire item
            reaper.DeleteTrackMediaItem(track, item)
        end
    end
    -- If none of the above, leave item as-is

    HELPERS.refreshImportedMediaItems(importedItems, importedPaths)
    reaper.Undo_EndBlock("STEMwerk: Create stem tracks", -1)
    return importedCount
end

-- Store item reference for async workflow
selectedItem = nil
itemPos = 0
itemLen = 0
-- timeSelectionMode, timeSelectionStart, timeSelectionEnd declared at top of file
timeSelectionSourceItem = nil  -- The item found in time selection (for in-place replacement)
timeSelectionItemMap = nil     -- Track -> items for per-item time selection jobs
selectedItemsNoTimeMap = nil   -- Track -> items captured before no-time-selection multi-job runs
timeSelectionResolvedItems = nil -- Audible time-selection items for createNewTracks
lastNoAudibleOverlap = false   -- Flag for audibility-filtered empty selection
itemSubSelection = false  -- true when we rendered only a portion of the selected item
itemSubSelStart = 0
itemSubSelEnd = 0

-- Get all items that overlap with a time range
-- If selectedOnly is true, only returns items that are also selected
function getItemsInTimeRange(startTime, endTime, selectedOnly)
    local items = {}
    local soloActive = getProcessingSoloActive()
    local numTracks = reaper.CountTracks(0)
    for t = 0, numTracks - 1 do
        local track = reaper.GetTrack(0, t)
        if AUDIBILITY.isTrackAudible(track, soloActive) then
            local numItems = reaper.CountTrackMediaItems(track)
            for i = 0, numItems - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                -- Check if item overlaps with time range
                if itemStart < endTime and itemEnd > startTime then
                    if AUDIBILITY.isItemAudible(item, soloActive) then
                        -- If selectedOnly, check if item is selected
                        if selectedOnly then
                            if reaper.IsMediaItemSelected(item) then
                                table.insert(items, item)
                            end
                        else
                            table.insert(items, item)
                        end
                    end
                end
            end
        end
    end
    return items
end

-- Get overlapping items on a single track (optionally selected-only)
function getItemsInTimeRangeOnTrack(track, startTime, endTime, selectedOnly)
    local items = {}
    if not track or not reaper.ValidatePtr(track, "MediaTrack*") then return items end
    local soloActive = getProcessingSoloActive()
    if not AUDIBILITY.isTrackAudible(track, soloActive) then return items end
    local numItems = reaper.CountTrackMediaItems(track)
    for i = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            if itemStart < endTime and itemEnd > startTime then
                if AUDIBILITY.isItemAudible(item, soloActive) then
                    if selectedOnly then
                        if reaper.IsMediaItemSelected(item) then
                            items[#items + 1] = item
                        end
                    else
                        items[#items + 1] = item
                    end
                end
            end
        end
    end
    return items
end

-- Auto semantics: if any selected items overlap, operate on selected; otherwise operate on all overlapping.
function getItemsInTimeRangeAuto(startTime, endTime, sourceTrack)
    local function countSelectedOverlapOnTrack(track)
        local count = 0
        local numItems = reaper.CountTrackMediaItems(track)
        for i = 0, numItems - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item and reaper.ValidatePtr(item, "MediaItem*") and reaper.IsMediaItemSelected(item) then
                local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                if itemStart < endTime and itemEnd > startTime then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function countSelectedOverlapGlobal()
        local count = 0
        local selCount = reaper.CountSelectedMediaItems(0) or 0
        for i = 0, selCount - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            if item and reaper.ValidatePtr(item, "MediaItem*") then
                local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local itemEnd = itemStart + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                if itemStart < endTime and itemEnd > startTime then
                    count = count + 1
                end
            end
        end
        return count
    end

    if sourceTrack and reaper.ValidatePtr(sourceTrack, "MediaTrack*") then
        local soloActive = getProcessingSoloActive()
        if not AUDIBILITY.isTrackAudible(sourceTrack, soloActive) then
            return {}
        end
        local rawSelectedOverlap = countSelectedOverlapOnTrack(sourceTrack)
        local sel = getItemsInTimeRangeOnTrack(sourceTrack, startTime, endTime, true)
        if #sel > 0 then return sel end
        if rawSelectedOverlap > 0 then return {} end
        return getItemsInTimeRangeOnTrack(sourceTrack, startTime, endTime, false)
    end
    local rawSelectedOverlap = countSelectedOverlapGlobal()
    local sel = getItemsInTimeRange(startTime, endTime, true)
    if #sel > 0 then return sel end
    if rawSelectedOverlap > 0 then return {} end
    return getItemsInTimeRange(startTime, endTime, false)
end

function muteSelectionInItemsFromList(items, startTime, endTime)
    for _, item in ipairs(items) do
        local track = reaper.GetMediaItem_Track(item)
        local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local muteStart = math.max(startTime, origItemPos)
        local muteEnd = math.min(endTime, origItemEnd)

        local middleItem = item
        if muteStart > origItemPos then
            middleItem = reaper.SplitMediaItem(item, muteStart)
        end
        if middleItem then
            local midEnd = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION") + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
            if muteEnd < midEnd then
                reaper.SplitMediaItem(middleItem, muteEnd)
            end
            reaper.SetMediaItemInfo_Value(middleItem, "B_MUTE", 1)
        end
    end
    return #items
end

-- Mute the selection portion of items within a time range (selected-only by default via auto helper at call site)
function muteSelectionInItems(startTime, endTime)
    local items = getItemsInTimeRange(startTime, endTime, true)  -- legacy behavior
    return muteSelectionInItemsFromList(items, startTime, endTime)
end

function deleteSelectionInItemsFromList(items, startTime, endTime)
    -- Process in reverse order to avoid index shifting issues
    for i = #items, 1, -1 do
        local item = items[i]
        local track = reaper.GetMediaItem_Track(item)
        local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local delStart = math.max(startTime, origItemPos)
        local delEnd = math.min(endTime, origItemEnd)

        local middleItem = item
        if delStart > origItemPos then
            middleItem = reaper.SplitMediaItem(item, delStart)
        end
        if middleItem then
            local midEnd = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION") + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
            if delEnd < midEnd then
                reaper.SplitMediaItem(middleItem, delEnd)
            end
            reaper.DeleteTrackMediaItem(track, middleItem)
        end
    end
    return #items
end

-- Delete the selection portion of selected items within a time range (legacy default)
function deleteSelectionInItems(startTime, endTime)
    local items = getItemsInTimeRange(startTime, endTime, true)  -- legacy behavior
    return deleteSelectionInItemsFromList(items, startTime, endTime)
end

-- Create new tracks for stems from time selection (no original item)
function createStemTracksForSelection(stemPaths, selPos, selLen, sourceTrack, itemsOverride, useItemNameForTrack, preferredInsertIndex, options)
    reaper.Undo_BeginBlock()
    lastNoAudibleOverlap = false
    local importedItems = {}
    local importedPaths = {}
    local shouldReturnTrackTargets = type(options) == "table" and options.returnTrackTargets == true
    local createdTrackTargets = shouldReturnTrackTargets and { contexts = {} } or nil
    local soloActive = getProcessingSoloActive()
    local function trackAudible(track)
        return AUDIBILITY.isTrackAudible(track, soloActive)
    end
    local function itemAudible(item)
        return AUDIBILITY.isItemAudible(item, soloActive)
    end

    -- Import-order stabilization: when multiple per-item jobs target the same
    -- source track, repeatedly inserting directly below the source track makes
    -- later jobs appear above earlier ones. Keep a per-call insertion cursor so
    -- per-item outputs are appended in timeline/import order. The multi-job
    -- importer can seed this cursor with preferredInsertIndex.
    local insertCursorByTrack = {}
    local function getTrackKey(track)
        return tostring(track or "")
    end
    local function getInsertIndexForTrack(track)
        if not track or not reaper.ValidatePtr(track, "MediaTrack*") then
            return preferredInsertIndex or 0
        end
        local key = getTrackKey(track)
        if insertCursorByTrack[key] == nil then
            if preferredInsertIndex and sourceTrack and track == sourceTrack then
                insertCursorByTrack[key] = preferredInsertIndex
            else
                insertCursorByTrack[key] = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
            end
        end
        return insertCursorByTrack[key]
    end
    local function advanceInsertIndexForTrack(track, insertedTrackCount)
        insertedTrackCount = tonumber(insertedTrackCount) or 0
        if insertedTrackCount <= 0 or not track or not reaper.ValidatePtr(track, "MediaTrack*") then
            return
        end
        local key = getTrackKey(track)
        if insertCursorByTrack[key] ~= nil then
            insertCursorByTrack[key] = insertCursorByTrack[key] + insertedTrackCount
        end
    end
    local function isValidTrack(track)
        return track and reaper.ValidatePtr(track, "MediaTrack*")
    end
    local function getPlannedTrackTargets(context)
        if type(options) ~= "table" then return nil end
        local resolver = options.resolveTrackTargets
        if type(resolver) == "function" then
            local ok, targets = pcall(resolver, context)
            if ok and type(targets) == "table" then
                return targets
            end
        end
        local planned = options.plannedTracks
        if type(planned) ~= "table" then return nil end
        if context and context.item and type(planned.byItem) == "table" then
            local byItemTargets = planned.byItem[tostring(context.item)]
            if type(byItemTargets) == "table" then
                return byItemTargets
            end
        end
        if context and context.kind == "selection_fallback" and type(planned.selection) == "table" then
            return planned.selection
        end
        return nil
    end
    local function getPlannedStemTrack(targets, stem)
        if type(targets) ~= "table" or type(targets.stemTracks) ~= "table" then return nil end
        return targets.stemTracks[stem.name:lower()] or targets.stemTracks[stem.name]
    end
    local function shouldKeepPlannedFolderName(targets)
        return type(targets) == "table" and targets.preserveFolderName == true
    end
    local function shouldKeepPlannedStemTrackNames(targets)
        return type(targets) == "table" and targets.preserveStemTrackNames == true
    end
    local function shouldKeepPlannedFolderDepth(targets)
        return type(targets) == "table" and targets.preserveFolderDepth == true
    end
    local function recordCreatedTargets(context, folderTrack, stemTracks)
        if not createdTrackTargets then return end
        createdTrackTargets.contexts[#createdTrackTargets.contexts + 1] = {
            kind = context and context.kind or nil,
            item = context and context.item or nil,
            sourceTrack = context and context.sourceTrack or nil,
            folderTrack = folderTrack,
            stemTracks = stemTracks or {}
        }
    end
    -- If there is a time-selection and selected items overlap it, create a set
    -- of stem tracks directly under each source track for each such selected item.
    local itemsToProcess = {}
    if itemsOverride and #itemsOverride > 0 then
        local startSel = selPos
        local endSel = selPos + selLen
        local rawAnyOverlap = 0
        for _, entry in ipairs(itemsOverride) do
            local it = entry
            local nameOverride = nil
            if type(entry) == "table" and entry.item then
                it = entry.item
                nameOverride = entry.sourceItemName or entry.sourceItemDisplayName
            end
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local iend = ipos + ilen
                if ipos < endSel and iend > startSel then
                    rawAnyOverlap = rawAnyOverlap + 1
                    if itemAudible(it) then
                        local p = math.max(ipos, startSel)
                        local e = math.min(iend, endSel)
                        local l = math.max(0, e - p)
                        if l > 0.01 then
                            table.insert(itemsToProcess, {item = it, pos = p, len = l, sourceItemName = nameOverride})
                        end
                    end
                end
            end
        end
        if #itemsToProcess == 0 and rawAnyOverlap > 0 then
            lastNoAudibleOverlap = true
            reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
            return 0
        end
    -- Prefer items on the provided sourceTrack (this function is called per-job).
    elseif sourceTrack and reaper.ValidatePtr(sourceTrack, "MediaTrack*") then
        if not trackAudible(sourceTrack) then
            lastNoAudibleOverlap = true
            reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
            return 0
        end
        local startSel = selPos
        local endSel = selPos + selLen
        local numItems = reaper.CountTrackMediaItems(sourceTrack)
        local rawSelectedOverlap = 0
        local rawAnyOverlap = 0
        -- First pass: selected items on this track that overlap selection (raw + eligible)
        for i = 0, numItems - 1 do
            local it = reaper.GetTrackMediaItem(sourceTrack, i)
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local iend = ipos + ilen
                if ipos < endSel and iend > startSel then
                    rawAnyOverlap = rawAnyOverlap + 1
                    if reaper.IsMediaItemSelected(it) then
                        rawSelectedOverlap = rawSelectedOverlap + 1
                        if itemAudible(it) then
                            local p = math.max(ipos, startSel)
                            local e = math.min(iend, endSel)
                            local l = math.max(0, e - p)
                            if l > 0.01 then
                                table.insert(itemsToProcess, {item = it, pos = p, len = l})
                            end
                        end
                    end
                end
            end
        end
        -- Second pass: if no selected items overlap, include ANY overlapping items on this track
        if rawSelectedOverlap == 0 then
            for i = 0, numItems - 1 do
                local it = reaper.GetTrackMediaItem(sourceTrack, i)
                if it and reaper.ValidatePtr(it, "MediaItem*") then
                    local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                    local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                    local iend = ipos + ilen
                    if ipos < endSel and iend > startSel and itemAudible(it) then
                        local p = math.max(ipos, startSel)
                        local e = math.min(iend, endSel)
                        local l = math.max(0, e - p)
                        if l > 0.01 then
                            table.insert(itemsToProcess, {item = it, pos = p, len = l})
                        end
                    end
                end
            end
        end
        if #itemsToProcess == 0 and rawAnyOverlap > 0 then
            lastNoAudibleOverlap = true
            reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
            return 0
        end
    else
        -- Fallback: global selected items overlapping selection
        local rawSelectedOverlap = 0
        for i = 0, reaper.CountSelectedMediaItems(0)-1 do
            local it = reaper.GetSelectedMediaItem(0, i)
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local iend = ipos + ilen
                local selEnd = selPos + selLen
                if not (iend <= selPos or ipos >= selEnd) then
                    rawSelectedOverlap = rawSelectedOverlap + 1
                    if itemAudible(it) then
                        table.insert(itemsToProcess, {item = it, pos = ipos, len = ilen})
                    end
                end
            end
        end
        if #itemsToProcess == 0 and rawSelectedOverlap > 0 then
            lastNoAudibleOverlap = true
            reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
            return 0
        end
    end

    -- If no selected items overlap the time selection, fall back to single-set behaviour
    if #itemsToProcess == 0 then
        -- Fall back to creating tracks at selection position under provided sourceTrack
        local refTrack = sourceTrack or reaper.GetSelectedTrack(0, 0) or reaper.GetTrack(0, 0)
        if refTrack and not trackAudible(refTrack) then
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
            return 0
        end
        local trackIdx = getInsertIndexForTrack(refTrack)
        local insertedTrackCount = 0

        local selectedCount = 0
        for _, stem in ipairs(STEMS) do if stem.selected and stemPaths[stem.name:lower()] then selectedCount = selectedCount + 1 end end

        local folderTrack = nil
        local stemTrackTargets = {}
        local plannedTargets = getPlannedTrackTargets({
            kind = "selection_fallback",
            sourceTrack = refTrack,
            selectionPos = selPos,
            selectionLen = selLen
        })
        local sourceTrackName = "Selection"
        if refTrack then
            local _, tn = reaper.GetTrackName(refTrack)
            if tn and tn ~= "" then sourceTrackName = tn end
        end
        local sourceItemName = sourceTrackName -- Fallback for items when using selection

        if SETTINGS.createFolder then
            local plannedFolderTrack = plannedTargets and plannedTargets.folderTrack or nil
            if isValidTrack(plannedFolderTrack) then
                folderTrack = plannedFolderTrack
            else
                reaper.InsertTrackAtIndex(trackIdx, true)
                insertedTrackCount = insertedTrackCount + 1
                folderTrack = reaper.GetTrack(0, trackIdx)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderName(plannedTargets)) then
                reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", sourceTrackName .. " - Stems", true)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderDepth(plannedTargets)) then
                reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderName(plannedTargets)) then
                HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
                ensureTrackHeight(folderTrack)
            end
            if not isValidTrack(plannedFolderTrack) then
                trackIdx = trackIdx + 1
            end
        end

        local importedCount = 0
        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = stemPaths[stem.name:lower()]
                if stemPath then
                    local plannedStemTrack = getPlannedStemTrack(plannedTargets, stem)
                    local newTrack = nil
                    if isValidTrack(plannedStemTrack) then
                        newTrack = plannedStemTrack
                    else
                        reaper.InsertTrackAtIndex(trackIdx + importedCount, true)
                        insertedTrackCount = insertedTrackCount + 1
                        newTrack = reaper.GetTrack(0, trackIdx + importedCount)
                    end
                    UI_Window.ensureTrackHeight(newTrack)
                    if not (isValidTrack(plannedStemTrack) and shouldKeepPlannedStemTrackNames(plannedTargets)) then
                        local newTrackName = selectedCount == 1 and (stem.name .. " - " .. sourceTrackName) or (sourceTrackName .. " - " .. stem.name)
                        reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", newTrackName, true)
                    end
                    local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                    if not (isValidTrack(plannedStemTrack) and shouldKeepPlannedStemTrackNames(plannedTargets)) then
                        HELPERS.applyTrackColorIfEnabled(newTrack, color)
                    end
                    local newItem = reaper.AddMediaItemToTrack(newTrack)
                    reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", selPos)
                    reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", selLen)
                    local newTake = reaper.AddTakeToMediaItem(newItem)
                    reaper.SetMediaItemTake_Source(newTake, reaper.PCM_Source_CreateFromFile(stemPath))
                    local newTakeName = sourceItemName .. " - " .. stem.name
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", newTakeName, true)
                    HELPERS.applyItemColorIfEnabled(newItem, color)
                    importedItems[#importedItems + 1] = newItem
                    importedPaths[#importedPaths + 1] = stemPath
                    stemTrackTargets[stem.name:lower()] = newTrack
                    importedCount = importedCount + 1
                end
            end
        end

        if folderTrack and importedCount > 0 and not shouldKeepPlannedFolderDepth(plannedTargets) then
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + importedCount - 1), "I_FOLDERDEPTH", -1)
        end
        recordCreatedTargets({
            kind = "selection_fallback",
            sourceTrack = refTrack
        }, folderTrack, stemTrackTargets)

        reaper.PreventUIRefresh(-1)
        HELPERS.refreshImportedMediaItems(importedItems, importedPaths)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
        return importedCount, insertedTrackCount, createdTrackTargets
    end

    -- Process each selected item that overlaps the time selection. Sort by
    -- source track and timeline position so output ordering is deterministic.
    table.sort(itemsToProcess, function(a, b)
        local ta = a and a.item and reaper.ValidatePtr(a.item, "MediaItem*") and reaper.GetMediaItem_Track(a.item) or nil
        local tb = b and b.item and reaper.ValidatePtr(b.item, "MediaItem*") and reaper.GetMediaItem_Track(b.item) or nil
        local ia = ta and math.floor(reaper.GetMediaTrackInfo_Value(ta, "IP_TRACKNUMBER")) or 999999
        local ib = tb and math.floor(reaper.GetMediaTrackInfo_Value(tb, "IP_TRACKNUMBER")) or 999999
        if ia ~= ib then return ia < ib end
        local pa = tonumber(a and a.pos) or 0
        local pb = tonumber(b and b.pos) or 0
        if pa ~= pb then return pa < pb end
        return tostring(a and a.item or "") < tostring(b and b.item or "")
    end)

    local totalCreated = 0
    local totalInsertedTrackCount = 0
    for _, info in ipairs(itemsToProcess) do
        local item = info.item
        local ipos = info.pos
        local ilen = info.len
        local track = reaper.GetMediaItem_Track(item)
        if not track then goto continue_item end

        local sourceTrackName = "Track"
        local _, tn = reaper.GetTrackName(track)
        if tn and tn ~= "" then sourceTrackName = tn end

        local sourceItemName = info.sourceItemName or sourceTrackName
        local sourcePlaybackState = GLUE_HELPERS.snapshotItemPlaybackState(item)
        local take = reaper.GetActiveTake(item)
        if take and not info.sourceItemName then
            local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            if takeName and takeName ~= "" then
                sourceItemName = takeName:match("([^/\\]+)%.[^.]*$") or takeName
            else
                local source = reaper.GetMediaItemTake_Source(take)
                if source then
                    local sourcePath = reaper.GetMediaSourceFileName(source, "")
                    if sourcePath and sourcePath ~= "" then
                        sourceItemName = sourcePath:match("([^/\\]+)%.[^.]*$") or sourcePath
                    end
                end
            end
        end
        local folderNames = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, "Stems")

        local trackIdx = getInsertIndexForTrack(track)
        local insertedForThisItem = 0

        local folderTrack = nil
        local stemTrackTargets = {}
        local plannedTargets = getPlannedTrackTargets({
            kind = "per_item",
            item = item,
            sourceTrack = track,
            itemPos = ipos,
            itemLen = ilen
        })
        if SETTINGS.createFolder then
            local plannedFolderTrack = plannedTargets and plannedTargets.folderTrack or nil
            if isValidTrack(plannedFolderTrack) then
                folderTrack = plannedFolderTrack
            else
                reaper.InsertTrackAtIndex(trackIdx, true)
                insertedForThisItem = insertedForThisItem + 1
                folderTrack = reaper.GetTrack(0, trackIdx)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderName(plannedTargets)) then
                reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", folderNames.folderBase .. " - Stems", true)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderDepth(plannedTargets)) then
                reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
            end
            if not (isValidTrack(plannedFolderTrack) and shouldKeepPlannedFolderName(plannedTargets)) then
                HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
                UI_Window.ensureTrackHeight(folderTrack)
            end
            if not isValidTrack(plannedFolderTrack) then
                trackIdx = trackIdx + 1
            end
        end

        local createdForThisItem = 0
        local selectedCount = 0
        for _, s in ipairs(STEMS) do if s.selected and stemPaths[s.name:lower()] then selectedCount = selectedCount + 1 end end

        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = stemPaths[stem.name:lower()]
                if stemPath then
                    local plannedStemTrack = getPlannedStemTrack(plannedTargets, stem)
                    local newTrack = nil
                    if isValidTrack(plannedStemTrack) then
                        newTrack = plannedStemTrack
                    else
                        reaper.InsertTrackAtIndex(trackIdx + createdForThisItem, true)
                        insertedForThisItem = insertedForThisItem + 1
                        newTrack = reaper.GetTrack(0, trackIdx + createdForThisItem)
                    end
                    UI_Window.ensureTrackHeight(newTrack)
                    local outputNames = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stem.name)
                    if not (isValidTrack(plannedStemTrack) and shouldKeepPlannedStemTrackNames(plannedTargets)) then
                        reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", outputNames.trackName, true)
                    end
                    local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                    if not (isValidTrack(plannedStemTrack) and shouldKeepPlannedStemTrackNames(plannedTargets)) then
                        HELPERS.applyTrackColorIfEnabled(newTrack, color)
                    end

                    local newItem = reaper.AddMediaItemToTrack(newTrack)
                    reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", ipos)
                    reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", ilen)
                    local newTake = reaper.AddTakeToMediaItem(newItem)
                    reaper.SetMediaItemTake_Source(newTake, reaper.PCM_Source_CreateFromFile(stemPath))
                    reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", outputNames.takeName, true)
                    GLUE_HELPERS.applyTakePlaybackState(newTake, sourcePlaybackState, ilen)
                    HELPERS.applyItemColorIfEnabled(newItem, color)

                    importedItems[#importedItems + 1] = newItem
                    importedPaths[#importedPaths + 1] = stemPath
                    stemTrackTargets[stem.name:lower()] = newTrack
                    createdForThisItem = createdForThisItem + 1
                    totalCreated = totalCreated + 1
                end
            end
        end

        if folderTrack and createdForThisItem > 0 and not shouldKeepPlannedFolderDepth(plannedTargets) then
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + createdForThisItem - 1), "I_FOLDERDEPTH", -1)
        end
        recordCreatedTargets({
            kind = "per_item",
            item = item,
            sourceTrack = track
        }, folderTrack, stemTrackTargets)
        advanceInsertIndexForTrack(track, insertedForThisItem)
        totalInsertedTrackCount = totalInsertedTrackCount + insertedForThisItem

        ::continue_item::
    end

    reaper.PreventUIRefresh(-1)
    HELPERS.refreshImportedMediaItems(importedItems, importedPaths)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection (per-item)", -1)
    return totalCreated, totalInsertedTrackCount, createdTrackTargets
end

-- Store temp directory for async workflow
WORKFLOW_TEMP_DIR = nil
WORKFLOW_TEMP_INPUT = nil

-- Process stems after separation completes (called from progress UI)
function processStemsResult(stems)
    SW_LOG.logExecResult("timing:finalize_start single", nil, "")
    local count
    local mainItem
    local resultMsg
    local resultData = nil
    local noAudibleOverlapMsg = HELPERS.getNoAudibleTargetsMessage()
    local contextItem = timeSelectionSourceItem or selectedItem
    local sourceTrackName, sourceItemName = HELPERS.getStemNamingContextForItem(contextItem, "Selection", "Selection")
    if not contextItem and timeSelectionMode then
        sourceTrackName = sourceTrackName or "Selection"
        sourceItemName = sourceItemName or "Selection"
    end
    stems = HELPERS.finalizeStemFiles(stems, sourceTrackName, sourceItemName)

    writeTimingEvent(WORKFLOW_TEMP_DIR, "import_start", "single", {
        mode = SETTINGS.createNewTracks and "new_tracks" or "in_place",
    })
    if SW_TIMING then SW_TIMING.mark("single", "import_start") end
    if timeSelectionMode then
        -- Time selection mode: respect user's setting
        if SETTINGS.createNewTracks then
            -- In multi-track mode, use the source track from the queue (for auto item selection & mute/delete semantics).
            local sourceTrack = multiTrackQueue.active and multiTrackQueue.currentSourceTrack or nil
            local actionMsg = ""

            local itemsOverride = timeSelectionResolvedItems
            -- Create stems first so the selection-based cleanup doesn't disturb placement
            SW_LOG.logExecResult("timing:import_start mode=new_tracks single=time_selection", nil, "")
            count = createStemTracksForSelection(stems, itemPos, itemLen, sourceTrack, itemsOverride, false)
            SW_LOG.logExecResult("timing:import_end mode=new_tracks single=time_selection created=" .. tostring(count), nil, "")
            if lastNoAudibleOverlap and count == 0 then
                showMessage(HELPERS.getNoAudibleTargetsTitle(), noAudibleOverlapMsg, "info", true)
                return
            end

            local hasCleanupTimeSel = (timeSelectionStart and timeSelectionEnd and timeSelectionEnd > timeSelectionStart) or false

            local function getCleanupItems()
                if itemsOverride and #itemsOverride > 0 then
                    return itemsOverride
                end
                return getItemsInTimeRangeAuto(timeSelectionStart, timeSelectionEnd, sourceTrack)
            end

            local function getCleanupTracks()
                local tracks = {}
                local function addTrack(track)
                    if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then return end
                    for _, existing in ipairs(tracks) do
                        if existing == track then return end
                    end
                    tracks[#tracks + 1] = track
                end
                addTrack(sourceTrack)
                for _, item in ipairs(getCleanupItems()) do
                    addTrack(reaper.GetMediaItem_Track(item))
                end
                return tracks
            end

            if SETTINGS.muteOriginalTrack then
                local tracks = getCleanupTracks()
                for _, track in ipairs(tracks) do
                    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
                end
                local trackWord = #tracks == 1 and "track" or "tracks"
                actionMsg = "\n" .. #tracks .. " " .. trackWord .. " muted."
            elseif SETTINGS.muteOriginal then
                local items = getCleanupItems()
                for _, item in ipairs(items) do
                    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
                end
                local itemWord = #items == 1 and "item" or "items"
                actionMsg = "\n" .. #items .. " " .. itemWord .. " muted."
            elseif SETTINGS.muteSelection and hasCleanupTimeSel then
                local items = getCleanupItems()
                local itemCount = muteSelectionInItemsFromList(items, timeSelectionStart, timeSelectionEnd)
                local itemWord = itemCount == 1 and "item" or "items"
                actionMsg = "\nSelection muted in " .. itemCount .. " " .. itemWord .. "."
            elseif SETTINGS.deleteOriginal then
                local items = getCleanupItems()
                for i = #items, 1, -1 do
                    local item = items[i]
                    reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(item), item)
                end
                local itemWord = #items == 1 and "item" or "items"
                actionMsg = "\n" .. #items .. " " .. itemWord .. " deleted."
            elseif SETTINGS.deleteSelection and hasCleanupTimeSel then
                local items = getCleanupItems()
                local itemCount = deleteSelectionInItemsFromList(items, timeSelectionStart, timeSelectionEnd)
                local itemWord = itemCount == 1 and "item" or "items"
                actionMsg = "\nSelection deleted from " .. itemCount .. " " .. itemWord .. "."
            end
            local trackWord = count == 1 and "track" or "tracks"
            -- In multi-track mode, show which track we're on
            local trackInfo = ""
            if multiTrackQueue.active then
                trackInfo = " [Track " .. multiTrackQueue.currentIndex .. "/" .. multiTrackQueue.totalTracks .. ": " .. (multiTrackQueue.currentTrackName or "?") .. "]"
            end
            resultMsg = count .. " stem " .. trackWord .. " created from time selection." .. actionMsg .. trackInfo
            resultData = {
                kind = "single",
                mainKey = "result_time_selection_created",
                count = count,
                stemsCreated = count,
                sourceCount = 1,
                sourceKind = "time_selection",
            }
        else
            -- In-place mode: replace only the selected portion of the item
            if timeSelectionSourceItem then
                -- Use partial replacement - splits the item and replaces only the selected part
                SW_LOG.logExecResult("timing:import_start mode=in_place_partial single=time_selection", nil, "")
                count, mainItem = WORKFLOW.replaceInPlacePartial(timeSelectionSourceItem, stems, timeSelectionStart, timeSelectionEnd)
                SW_LOG.logExecResult("timing:import_end mode=in_place_partial single=time_selection created=" .. tostring(count), nil, "")
                local exploded = explodeTakesFromItem(mainItem, SETTINGS.postProcessTakes)
                if exploded > 0 then
                    resultMsg = "Selection replaced and takes exploded."
                    resultData = { kind = "single", mainKey = "result_selection_replaced_exploded" }
                else
                    if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                        local takeCount = reaper.CountTakes(mainItem) or 0
                        if takeCount > 1 then
                            addPostProcessCandidate(mainItem)
                            focusReaperAfterMainOpenOnce = true
                        end
                    end
                    -- If we kept takes (multi-take item), select it and jump to the start
                    -- of the time selection so user can press T to cycle takes.
                    if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                        local takeCount = reaper.CountTakes(mainItem) or 0
                        if takeCount > 1 and timeSelectionStart then
                            -- Select only the new multi-take item
                            reaper.Main_OnCommand(40289, 0) -- Unselect all items
                            reaper.SetMediaItemSelected(mainItem, true)

                            -- Intentionally do not move the playhead/cursor.
                        end
                    end
                    resultMsg = count == 1 and "Selection replaced with stem." or "Selection replaced with stems as takes (press T to switch)."
                    resultData = { kind = "single", mainKey = (count == 1) and "result_selection_replaced_single" or "result_selection_replaced_takes_hint" }
                end
            else
                -- Fallback: create new tracks if no source item
                local sourceTrack = multiTrackQueue.active and multiTrackQueue.currentSourceTrack or nil
                local itemsOverride = timeSelectionResolvedItems
                SW_LOG.logExecResult("timing:import_start mode=new_tracks single=time_selection_fallback", nil, "")
                count = createStemTracksForSelection(stems, itemPos, itemLen, sourceTrack, itemsOverride, false)
                SW_LOG.logExecResult("timing:import_end mode=new_tracks single=time_selection_fallback created=" .. tostring(count), nil, "")
                if lastNoAudibleOverlap and count == 0 then
                    showMessage(HELPERS.getNoAudibleTargetsTitle(), noAudibleOverlapMsg, "info", true)
                    return
                end
                local trackWord = count == 1 and "track" or "tracks"
                resultMsg = count .. " stem " .. trackWord .. " created from time selection."
                resultData = {
                    kind = "single",
                    mainKey = "result_time_selection_created",
                    count = count,
                    stemsCreated = count,
                    sourceCount = 1,
                    sourceKind = "time_selection",
                }
            end
        end
    elseif SETTINGS.createNewTracks then
        SW_LOG.logExecResult("timing:import_start mode=new_tracks single=items", nil, "")
        count = createStemTracks(selectedItem, stems, itemPos, itemLen)
        SW_LOG.logExecResult("timing:import_end mode=new_tracks single=items created=" .. tostring(count), nil, "")
        local actionKey = SETTINGS.deleteOriginalTrack and "result_track_deleted" or
                          (SETTINGS.muteOriginalTrack and "result_track_muted" or
                          (SETTINGS.deleteOriginal and "result_item_deleted" or
                          (SETTINGS.deleteSelection and "result_selection_deleted" or
                          (SETTINGS.muteOriginal and "result_item_muted" or
                          (SETTINGS.muteSelection and "result_selection_muted" or nil)))))
        local trackWord = count == 1 and "track" or "tracks"
        resultMsg = count .. " stem " .. trackWord .. " created."
        if actionKey then resultMsg = resultMsg .. "\n" .. (T(actionKey) or "") end
        resultData = {
            kind = "single",
            mainKey = "result_stems_created_generic",
            count = count,
            actionKey = actionKey,
            stemsCreated = count,
            sourceCount = 1,
            sourceKind = "items",
        }
    else
        -- Check if we processed a sub-selection of the item
        if itemSubSelection then
            -- Use partial replacement - splits the item and replaces only the selected part
            SW_LOG.logExecResult("timing:import_start mode=in_place_partial single=item_sub_selection", nil, "")
            count, mainItem = WORKFLOW.replaceInPlacePartial(selectedItem, stems, itemSubSelStart, itemSubSelEnd)
            SW_LOG.logExecResult("timing:import_end mode=in_place_partial single=item_sub_selection created=" .. tostring(count), nil, "")
            local exploded = explodeTakesFromItem(mainItem, SETTINGS.postProcessTakes)
            if exploded > 0 then
                resultMsg = "Selection replaced and takes exploded."
                resultData = { kind = "single", mainKey = "result_selection_replaced_exploded" }
            else
                if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                    local takeCount = reaper.CountTakes(mainItem) or 0
                    if takeCount > 1 then
                        addPostProcessCandidate(mainItem)
                        focusReaperAfterMainOpenOnce = true
                    end
                end
                resultMsg = count == 1 and "Selection replaced with stem." or "Selection replaced with stems as takes (press T to switch)."
                resultData = { kind = "single", mainKey = (count == 1) and "result_selection_replaced_single" or "result_selection_replaced_takes_hint" }
            end
        else
            SW_LOG.logExecResult("timing:import_start mode=in_place single=item_full", nil, "")
            count, mainItem = WORKFLOW.replaceInPlace(selectedItem, stems, itemPos, itemLen)
            SW_LOG.logExecResult("timing:import_end mode=in_place single=item_full created=" .. tostring(count), nil, "")
            local exploded = explodeTakesFromItem(mainItem, SETTINGS.postProcessTakes)
            if exploded > 0 then
                resultMsg = "Stems created and takes exploded."
                resultData = { kind = "single", mainKey = "result_stems_created_exploded" }
            else
                if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                    local takeCount = reaper.CountTakes(mainItem) or 0
                    if takeCount > 1 then
                        addPostProcessCandidate(mainItem)
                        focusReaperAfterMainOpenOnce = true
                    end
                end
                resultMsg = count == 1 and "Stem replaced." or "Stems added as takes (press T to switch)."
                resultData = { kind = "single", mainKey = (count == 1) and "result_stem_replaced" or "result_stems_added_takes_hint" }
            end
        end
    end

    local selectedNames = {}
    local selectedStemData = {}
    local is6Stem = isEffectiveRun6Stem()
    for _, stem in ipairs(STEMS) do
        -- Only include stems that were actually processed (respect sixStemOnly flag)
        if stem.selected and (not stem.sixStemOnly or is6Stem) then
            selectedNames[#selectedNames + 1] = stem.name
            selectedStemData[#selectedStemData + 1] = stem
        end
    end

    -- Calculate and add timing info
    local totalTime = os.time() - (progressState.startTime or os.time())
    local totalMins = math.floor(totalTime / 60)
    local totalSecs = totalTime % 60
    local timeStr = string.format("%d:%02d", totalMins, totalSecs)
    resultMsg = resultMsg .. "\n" .. string.format(T("result_time_line") or "Time: %s", timeStr)
    if resultData then
        local processedAudioDur = 0
        if itemSubSelection and itemSubSelEnd and itemSubSelStart and itemSubSelEnd > itemSubSelStart then
            processedAudioDur = itemSubSelEnd - itemSubSelStart
        elseif itemLen and itemLen > 0 then
            processedAudioDur = itemLen
        end
        local realtimeFactor = (processedAudioDur > 0 and totalTime > 0) and (processedAudioDur / totalTime) or 0
        resultData.totalTimeSec = totalTime
        resultData.realtimeFactor = realtimeFactor
        local requestedParallel = effectiveRunRequestedParallel()
        resultData.sequentialMode = requestedParallel and false or true
        resultData.requestedParallel = requestedParallel and true or false
    end

    reaper.UpdateArrange()

    -- Show custom result window
    writeTimingEvent(WORKFLOW_TEMP_DIR, "import_end", "single", {
        mode = SETTINGS.createNewTracks and "new_tracks" or "in_place",
    })
    if SW_TIMING then
        SW_TIMING.mark("single", "import_end")
        SW_TIMING.endJob("single", "success")
        SW_TIMING.endRun("success")
    end
    SW_LOG.logExecResult("timing:finalize_end single", nil, "")
    showResultWindow(selectedStemData, resultData or resultMsg)
end

-- Result window state (global to avoid exceeding Lua's 200 local limit in the main chunk)
resultWindowState = {
    selectedStems = {},
    message = "",
    running = false,
    startTime = 0,
    confetti = {},
    rings = {},
}

-- One-shot flag to bypass the single-instance window check.
-- Used when we just closed a gfx window and immediately re-open the main UI.
skipExistingWindowCheckOnce = false

-- Initialize celebration effects (global to avoid exceeding Lua's 200 local limit in the main chunk)
function initCelebration()
    resultWindowState.startTime = os.clock()
    resultWindowState.confetti = {}
    resultWindowState.rings = {}

    -- Create confetti particles
    for i = 1, 50 do
        table.insert(resultWindowState.confetti, {
            x = math.random() * 400 + 100,
            y = -math.random() * 100,
            vx = (math.random() - 0.5) * 4,
            vy = math.random() * 2 + 1,
            rotation = math.random() * math.pi * 2,
            rotSpeed = (math.random() - 0.5) * 0.3,
            size = math.random() * 8 + 4,
            colorIdx = math.random(1, 6),
            delay = math.random() * 0.5,
        })
    end

    -- Create expanding rings
    for i = 1, 3 do
        table.insert(resultWindowState.rings, {
            radius = 0,
            alpha = 1,
            delay = i * 0.15,
        })
    end

end

-- Draw result window (clean style matching main app)
function drawResultWindow()
    local w, h = gfx.w, gfx.h
    local resultTokens = (UI_TOKENS and UI_TOKENS.result) or {}
    local spacing = resultTokens.spacing or {}
    local padding = resultTokens.padding or {}
    local button = resultTokens.button or {}
    local fonts = resultTokens.fonts or {}

    -- Calculate scale
    local scale = math.min(w / 380, h / 340)
    scale = math.max(0.5, math.min(4.0, scale))
    local function PS(val) return math.floor(val * scale + 0.5) end

    -- Tooltip (simple, single-line like progress window)
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0

    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1

    -- === PROCEDURAL ART AS FULL BACKGROUND LAYER ===
    -- Pure black/white background first
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, w, h, 1)

    proceduralArt.time = proceduralArt.time + 0.016  -- ~60fps
    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
        drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

        -- Theme-aware readability wash over animated FX
        local overlayAlpha = getFxReadabilityOverlayAlpha()
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, overlayAlpha)
        else
            gfx.set(1, 1, 1, overlayAlpha)
        end
        gfx.rect(0, 0, w, h, 1)
    end

    local controlsCtx = {
        w = w,
        h = h,
        PS = PS,
        mx = mx,
        my = my,
        mouseDown = mouseDown,
        tooltipText = tooltipText,
        tooltipX = tooltipX,
        tooltipY = tooltipY,
    }
    drawResultWindowControls(controlsCtx)
    tooltipText = controlsCtx.tooltipText
    tooltipX = controlsCtx.tooltipX
    tooltipY = controlsCtx.tooltipY

    renderResultTitleArea({ w = w, PS = PS })
    renderResultMessageBox({ w = w, h = h, PS = PS })

    -- OK button (rounded pill style like main app)
    local btnW = PS(button.width or 70)
    local btnH = PS(button.height or 20)
    local btnX = (w - btnW) / 2
    local btnY = h - PS(button.bottomOffset or 40)

    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    -- Button background
    local okR, okG, okB = THEME.buttonPrimary[1], THEME.buttonPrimary[2], THEME.buttonPrimary[3]
    if hover then
        okR, okG, okB = THEME.buttonPrimaryHover[1], THEME.buttonPrimaryHover[2], THEME.buttonPrimaryHover[3]
    end
    drawGlossyPill(btnX, btnY, btnW, btnH, okR, okG, okB)

    -- Button text
    gfx.setfont(1, "Arial", PS(fonts.okButton or 13), string.byte('b'))
    local okText = T("ok") or "OK"
    local okW = gfx.measurestr(okText)
    local okX = btnX + (btnW - okW) / 2
    local okY = btnY + (btnH - gfx.texth) / 2
    if type(isThemeUtilityMode) == "function" and isThemeUtilityMode() then
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    else
        gfx.set(0, 0, 0, 0.4)
        gfx.x, gfx.y = okX + 2, okY + 2; gfx.drawstr(okText)
        gfx.set(0, 0, 0, 0.6)
        gfx.x, gfx.y = okX + 1, okY + 1; gfx.drawstr(okText)
        gfx.x, gfx.y = okX - 1, okY + 1; gfx.drawstr(okText)
        gfx.x, gfx.y = okX + 1, okY - 1; gfx.drawstr(okText)
        gfx.x, gfx.y = okX - 1, okY - 1; gfx.drawstr(okText)
        gfx.set(1, 1, 1, 1)
    end
    gfx.x, gfx.y = okX, okY
    gfx.drawstr(okText)

    -- Hint at very bottom edge
    gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
    gfx.setfont(1, "Arial", PS(fonts.hint or 9))
    local hint = T("complete_hint_keys") or "Enter / ESC"
    local hintW = gfx.measurestr(hint)
    gfx.x = (w - hintW) / 2
    gfx.y = h - PS(spacing.hintBottom or 12)
    gfx.drawstr(hint)

    -- flarkAUDIO logo at top (translucent) - skipped in utility mode
    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
    gfx.setfont(1, "Arial", PS(fonts.logo or 10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", PS(fonts.logo or 10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2
    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", PS(fonts.logo or 10))
    gfx.x = logoStartX
    gfx.y = PS(spacing.logoTop or 3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", PS(fonts.logo or 10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = PS(spacing.logoTop or 3)
    gfx.drawstr(audioPart)
    end -- end utility mode logo guard

    gfx.update()

    -- Check for click on OK button
    if hover and mouseDown and not resultWindowState.wasMouseDown then
        return true  -- Close
    end
    if hover then
        tooltipText = T("complete_ok_tooltip") or "Close (Enter / ESC)"
        tooltipX, tooltipY = mx + PS(spacing.tooltipOffsetX or 10), my + PS(spacing.tooltipOffsetY or 15)
    end

    resultWindowState.wasMouseDown = mouseDown
    resultWindowState.wasRightMouseDown = (gfx.mouse_cap & 2 == 2)

    local char = gfx.getchar()
    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
        UI_Window.handleArtAdvance(resultWindowState, mouseDown, char)
    end
    if char == -1 or char == 27 or char == 13 then  -- Window closed, ESC, Enter
        return true  -- Close
    end

    -- Tooltip draw (match main style: stem-color bar + wrapping)
    if tooltipText then
        gfx.setfont(1, "Arial", PS(fonts.tooltip or 11))
        local tooltipPad = PS(padding.tooltipPadding or 8)
        local lineH = PS(padding.tooltipLineHeight or 14)
        local maxTextW = math.min(w * 0.62, PS(padding.tooltipMaxTextW or 520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, tooltipPad, lineH, maxTextW)
    end

    return false  -- Keep open
end

-- Result window loop
function resultWindowLoop()
    -- Save window position for next time
    if reaper.JS_Window_GetRect then
        local hwnd = reaper.JS_Window_Find(resultWindowState.windowTitle or getCompleteWindowTitle(), true)
        if hwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if retval then
                rememberDialogGeometryFromRect(left, top, right, bottom)
            end

            -- NOTE: Focus check removed - was causing double execution on multi-track processing
            -- The result window should stay open until user explicitly closes it
        end
    end

    -- Check for theme updates from Editor
    local lastRefresh = reaper.GetExtState("STEMwerk", "THEME_REFRESH")
    if lastRefresh ~= "" and lastRefresh ~= GUI._lastThemeRefresh then
        GUI._lastThemeRefresh = lastRefresh
        updateTheme()
    end

    if drawResultWindow() then
        -- Remember any size/position changes made in the complete window
        captureWindowGeometry(resultWindowState.windowTitle or getCompleteWindowTitle())
        saveSettings()
        gfx.quit()
        -- Ensure the user immediately sees what was created/changed in REAPER (no extra click required).
        -- Some systems don't redraw the arrange view until the next interaction.
        HELPERS.forceArrangeRefresh()
        -- Reopen the main dialog directly to avoid retriggering startup checks and shell flashes.
        reaper.defer(function()
            skipExistingWindowCheckOnce = true
            showStemSelectionDialog()
        end)
        return
    end
    reaper.defer(resultWindowLoop)
end

-- Show result window
function showResultWindow(selectedStems, message)
    -- Keep run choices stable until the workflow is complete.
    updateTheme()

    -- Ensure newly created/changed tracks/items are visible in REAPER *before* showing the Complete window.
    -- Some systems won't repaint the arrange view until focus changes, so we also do a best-effort focus nudge below.
    HELPERS.forceArrangeRefresh()

    resultWindowState.selectedStems = selectedStems
    if type(message) == "table" then
        resultWindowState.messageData = message
        resultWindowState.message = ""
    else
        resultWindowState.messageData = nil
        resultWindowState.message = message
    end
    resultWindowState.wasMouseDown = false

    -- Initialize celebration effects
    initCelebration()

    -- Intentionally do not change playhead position or playback state.

    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    resultWindowState.windowTitle = getCompleteWindowTitle()
    gfx.init(resultWindowState.windowTitle, winW, winH, 0, winX, winY)

    -- Best-effort: force an arrange repaint while the Complete window is open.
    -- This makes the processing result visible immediately (without needing to close the window).
    HELPERS.scheduleResultWindowRefresh()
    if OS == "Windows" then
        resultWindowLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(resultWindowLoop)
    end
end

-- Helper: normalize item name for display/file
local function normalizeItemName(name)
    if not name or name == "" then return nil end
    return name:match("([^/\\]+)%.[^.]*$") or name
end

-- Helper: get item name fields
local function getItemNameFields(item, fallbackTrackName)
    local take = reaper.GetActiveTake(item)
    local takeName = nil
    if take then
        local _, tn = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if tn and tn ~= "" then
            takeName = tn
        end
    end
    local sourceName = nil
    if take and not takeName then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
            local sourcePath = reaper.GetMediaSourceFileName(source, "")
            if sourcePath and sourcePath ~= "" then
                sourceName = sourcePath:match("([^/\\]+)$") or sourcePath
            end
        end
    end
    local baseName = normalizeItemName(takeName) or normalizeItemName(sourceName)
    local displayName = baseName or fallbackTrackName or "Item"
    return baseName or displayName, displayName
end

-- Helper: get selected audible items on track
local function getSelectedAudibleItemsOnTrack(track, soloActive)
    local items = {}
    local numItems = reaper.CountTrackMediaItems(track)
    for j = 0, numItems - 1 do
        local item = reaper.GetTrackMediaItem(track, j)
        if item and reaper.ValidatePtr(item, "MediaItem*")
            and reaper.IsMediaItemSelected(item)
            and AUDIBILITY.isItemAudible(item, soloActive) then
            items[#items + 1] = item
        end
    end
    return items
end

-- Build a SourceItemPlan for stem jobs
_sep.buildSourceItemPlan = function(trackList, hasTimeSel, perItemMap, noTimeSelectionItemMap)
    local plan = {}
    local stats = { perItemCandidates = 0, perItemEligible = 0 }
    local original_selection_order = 0
    local soloActive = getProcessingSoloActive()

    for i, track in ipairs(trackList) do
        local trackIdx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
        local trackGUID = reaper.GetTrackGUID(track)
        local _, trackName = reaper.GetTrackName(track)
        if trackName == "" then trackName = "Track " .. trackIdx end

        local selectedTrackItems = (not hasTimeSel)
            and ((noTimeSelectionItemMap and noTimeSelectionItemMap[track]) or getSelectedAudibleItemsOnTrack(track, soloActive))
            or nil

        if perItemMap and hasTimeSel and perItemMap[track] then
            -- Case 1: Time Selection + Per-item
            local entries = perItemMap[track] or {}
            stats.perItemCandidates = stats.perItemCandidates + #entries
            local eligibleEntries = {}
            for _, entry in ipairs(entries) do
                local item = entry.item
                if item and reaper.ValidatePtr(item, "MediaItem*") and AUDIBILITY.isItemAudible(item, soloActive) then
                    table.insert(eligibleEntries, entry)
                end
            end
            stats.perItemEligible = stats.perItemEligible + #eligibleEntries

            for _, entry in ipairs(eligibleEntries) do
                local item = entry.item
                original_selection_order = original_selection_order + 1
                local sourceItemName, sourceItemDisplayName = getItemNameFields(item, trackName)
                table.insert(plan, {
                    source_track = track,
                    source_track_guid = trackGUID,
                    source_track_index = trackIdx,
                    source_track_name = trackName,
                    source_item = item,
                    source_item_guid = select(2, reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)),
                    item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                    item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                    item_name = sourceItemDisplayName,
                    original_selection_order = original_selection_order,
                    sourceItemName = sourceItemName,
                    sourceItemDisplayName = sourceItemDisplayName,
                    selStart = entry.start,
                    selEnd = entry["end"],
                    isPerItem = true,
                    isTimeSelection = true,
                })
            end
        elseif (not hasTimeSel) and ((not SETTINGS.createNewTracks) or (selectedTrackItems and #selectedTrackItems > 1)) then
            -- Case 2: No time selection + Multi-item (or in-place)
            local selectedItems = selectedTrackItems or getSelectedAudibleItemsOnTrack(track, soloActive)
            if selectedItems and #selectedItems > 0 then
                stats.perItemCandidates = stats.perItemCandidates + #selectedItems
                stats.perItemEligible = stats.perItemEligible + #selectedItems
                for _, item in ipairs(selectedItems) do
                    original_selection_order = original_selection_order + 1
                    local sourceItemName, sourceItemDisplayName = getItemNameFields(item, trackName)
                    table.insert(plan, {
                        source_track = track,
                        source_track_guid = trackGUID,
                        source_track_index = trackIdx,
                        source_track_name = trackName,
                        source_item = item,
                        source_item_guid = select(2, reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)),
                        item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                        item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                        item_name = sourceItemDisplayName,
                        original_selection_order = original_selection_order,
                        sourceItemName = sourceItemName,
                        sourceItemDisplayName = sourceItemDisplayName,
                        isPerItem = true,
                        isTimeSelection = false,
                    })
                end
            end
        else
            -- Case 3: Default (One job per track)
            original_selection_order = original_selection_order + 1
            table.insert(plan, {
                source_track = track,
                source_track_guid = trackGUID,
                source_track_index = trackIdx,
                source_track_name = trackName,
                original_selection_order = original_selection_order,
                isPerItem = false,
                isTimeSelection = hasTimeSel,
            })
        end
    end

    table.sort(plan, function(a, b)
        if a.source_track_index ~= b.source_track_index then
            return a.source_track_index < b.source_track_index
        end
        local posA = a.item_position or 0
        local posB = b.item_position or 0
        if posA ~= posB then
            return posA < posB
        end
        return a.original_selection_order < b.original_selection_order
    end)

    return plan, stats
end

-- Run multi-track separation (parallel or sequential based on setting)
_sep.runSingleTrackSeparation = function(trackList)
    refreshPythonPathFromExtState()
    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end
    if (not trustedWindowsRuntime) and (not canRunFfmpeg()) then
        if not ensureDependenciesInteractive() then
            if reaper and reaper.defer then
                reaper.defer(function() showStemSelectionDialog() end)
            end
            isProcessingActive = false
            if multiTrackQueue then
                multiTrackQueue.active = false
            end
            return
        end
    end
    local numpyOk, numpyErr = true, nil
    if not trustedWindowsRuntime then
        numpyOk, numpyErr = checkNumpyCompat(PYTHON_PATH)
    end
    if not numpyOk then
        local msg =
            "NumPy compatibility issue.\n\n"
            .. tostring(numpyErr or "Unknown error") .. "\n\n"
            .. "Fix (command):\n"
            .. "  " .. tostring(PYTHON_PATH) .. " -m pip install \"numpy<2.4\""
        debugLog(msg)
        SW_LOG.logExecResult("preflight: numpy incompatible", -1, msg)
        if reaper and reaper.ShowMessageBox then
            reaper.ShowMessageBox(msg, "Missing Dependency", 0)
        end
        if reaper and reaper.defer then
            reaper.defer(function() showStemSelectionDialog() end)
        end
        isProcessingActive = false
        if multiTrackQueue then
            multiTrackQueue.active = false
        end
        return
    end

    local baseTempDir = makeUniqueTempSubdir("STEMwerk")
    makeDir(baseTempDir)

    -- Check if we have a time selection
    local hasTimeSel = (timeSelectionMode and timeSelectionStart and timeSelectionEnd and timeSelectionEnd > timeSelectionStart)

    local is6Stem = isEffectiveRun6Stem()
    local selectedStemCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or is6Stem) then
            selectedStemCount = selectedStemCount + 1
        end
    end

    -- In-place mode with no time selection: process each item separately
    -- This ensures each item gets its own stems as takes
    local inPlaceMultiItem = not SETTINGS.createNewTracks and not hasTimeSel

    local perItemMap = timeSelectionItemMap
    local noTimeSelectionItemMap = selectedItemsNoTimeMap
    timeSelectionItemMap = nil
    selectedItemsNoTimeMap = nil

    local soloActive = getProcessingSoloActive()

    local function renderPerItemOverlapFallback(item, outputPath, overlapStart, overlapEnd)
        if not item or not reaper.ValidatePtr(item, "MediaItem*") then
            return nil, "Invalid item"
        end
        if not (reaper.GetItemStateChunk and reaper.SetItemStateChunk) then
            return nil, "REAPER item state chunk API not available"
        end

        local overlapLen = (tonumber(overlapEnd) or 0) - (tonumber(overlapStart) or 0)
        if overlapLen <= 0.01 then
            return nil, "Selection is empty (0s). Make a longer time selection or pick an item with length."
        end

        local okChunk, itemChunk = reaper.GetItemStateChunk(item, "", false)
        if not okChunk or not itemChunk or itemChunk == "" then
            return nil, "Failed to clone item state for overlap extraction"
        end

        debugLog(string.format(
            "renderPerItemOverlapFallback: using temporary track clone for %.6f..%.6f",
            tonumber(overlapStart) or -1,
            tonumber(overlapEnd) or -1
        ))

        local selectedTracks = {}
        local selectedItems = {}
        local selectedTrackCount = reaper.CountSelectedTracks(0)
        local selectedItemCount = reaper.CountSelectedMediaItems(0)
        for idx = 0, selectedTrackCount - 1 do
            selectedTracks[#selectedTracks + 1] = reaper.GetSelectedTrack(0, idx)
        end
        for idx = 0, selectedItemCount - 1 do
            selectedItems[#selectedItems + 1] = reaper.GetSelectedMediaItem(0, idx)
        end

        local function restoreSelectionState()
            reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
            reaper.Main_OnCommand(40289, 0) -- Unselect all items
            for _, track in ipairs(selectedTracks) do
                if track and reaper.ValidatePtr(track, "MediaTrack*") then
                    reaper.SetTrackSelected(track, true)
                end
            end
            for _, selectedItem in ipairs(selectedItems) do
                if selectedItem and reaper.ValidatePtr(selectedItem, "MediaItem*") then
                    reaper.SetMediaItemSelected(selectedItem, true)
                end
            end
        end

        reaper.PreventUIRefresh(1)

        local tempTrackIdx = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(tempTrackIdx, false)
        local tempTrack = reaper.GetTrack(0, tempTrackIdx)
        if not tempTrack then
            restoreSelectionState()
            reaper.PreventUIRefresh(-1)
            return nil, "Failed to create temporary extraction track"
        end

        if reaper.SetMediaTrackInfo_Value then
            pcall(function() reaper.SetMediaTrackInfo_Value(tempTrack, "B_SHOWINTCP", 0) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(tempTrack, "B_SHOWINMIXER", 0) end)
            pcall(function() reaper.SetMediaTrackInfo_Value(tempTrack, "B_MUTE", 1) end)
        end

        local tempItem = reaper.AddMediaItemToTrack(tempTrack)
        if not tempItem then
            if reaper.ValidatePtr(tempTrack, "MediaTrack*") then
                reaper.DeleteTrack(tempTrack)
            end
            restoreSelectionState()
            reaper.PreventUIRefresh(-1)
            return nil, "Failed to create temporary extraction item"
        end

        if not reaper.SetItemStateChunk(tempItem, itemChunk, false) then
            if reaper.ValidatePtr(tempTrack, "MediaTrack*") then
                reaper.DeleteTrack(tempTrack)
            end
            restoreSelectionState()
            reaper.PreventUIRefresh(-1)
            return nil, "Failed to apply cloned item state for overlap extraction"
        end

        tempItem = reaper.GetTrackMediaItem(tempTrack, 0) or tempItem
        local middleItem = tempItem
        local tempPos = reaper.GetMediaItemInfo_Value(tempItem, "D_POSITION") or overlapStart
        local tempEnd = tempPos + (reaper.GetMediaItemInfo_Value(tempItem, "D_LENGTH") or 0)
        if overlapStart > tempPos and overlapStart < tempEnd then
            middleItem = reaper.SplitMediaItem(tempItem, overlapStart) or tempItem
        end

        if middleItem and reaper.ValidatePtr(middleItem, "MediaItem*") then
            local midPos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION") or overlapStart
            local midEnd = midPos + (reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH") or 0)
            if overlapEnd > midPos and overlapEnd < midEnd then
                reaper.SplitMediaItem(middleItem, overlapEnd)
            end
        end

        local extracted, err = renderSingleItemToWav(middleItem, outputPath)
        if reaper.ValidatePtr(tempTrack, "MediaTrack*") then
            reaper.DeleteTrack(tempTrack)
        end
        restoreSelectionState()
        reaper.PreventUIRefresh(-1)
        reaper.UpdateArrange()
        if extracted then
            return extracted, nil, overlapStart, overlapLen
        end
        return nil, err or "Failed to extract temporary overlap slice"
    end

    local filteredTrackList = AUDIBILITY.filterTracks(trackList, soloActive)
    if #filteredTrackList ~= (trackList and #trackList or 0) then
        debugLog("Audibility filter: tracks=" .. tostring(trackList and #trackList or 0) .. " -> " .. tostring(#filteredTrackList) .. " (solo=" .. tostring(soloActive) .. ")")
    end
    trackList = filteredTrackList
    if #trackList == 0 then
        isProcessingActive = false
        showMessage(HELPERS.getNoAudibleTargetsTitle(), HELPERS.getNoAudibleTargetsMessage(), "info", true)
        return
    end

    -- Build SourceItemPlan to decide what to process
    local sourcePlan, planStats = _sep.buildSourceItemPlan(trackList, hasTimeSel, perItemMap, noTimeSelectionItemMap)

    -- Prepare all tracks: extract audio
    local trackJobs = {}
    local jobIndex = 0
    local perItemCandidates = planStats.perItemCandidates
    local perItemEligible = planStats.perItemEligible

    local function getJobUIColor(track, fallbackIdx)
        -- Returns {r,g,b} in 0..1 for UI tinting. Uses the track's custom color when set.
        local fallbackStem = STEMS[((fallbackIdx or 1) - 1) % #STEMS + 1]
        local fr = (fallbackStem.color[1] or 160) / 255
        local fg = (fallbackStem.color[2] or 200) / 255
        local fb = (fallbackStem.color[3] or 255) / 255

        if not reaper or not reaper.GetTrackColor then
            return { fr, fg, fb }
        end
        local col = reaper.GetTrackColor(track)
        if not col or col == 0 or not reaper.ColorFromNative then
            return { fr, fg, fb }
        end
        local r, g, b = reaper.ColorFromNative(col)
        r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
        -- Some themes store "default" as 0; if r/g/b are zeroed, use fallback.
        if r == 0 and g == 0 and b == 0 then
            return { fr, fg, fb }
        end
        return { r / 255, g / 255, b / 255 }
    end

    for _, planEntry in ipairs(sourcePlan) do
        local track = planEntry.source_track
        local trackName = planEntry.source_track_name

        if planEntry.isPerItem then
            -- Create per-item job
            jobIndex = jobIndex + 1
            local itemDir = baseTempDir .. PATH_SEP .. "item_" .. jobIndex
            makeDir(itemDir)
            local inputFile = itemDir .. PATH_SEP .. "input.wav"
            local item = planEntry.source_item

            local extracted, err, renderStart, renderLen
            writeTimingEvent(itemDir, "lua_extract_start", jobIndex)
            if planEntry.isTimeSelection then
                extracted, err, renderStart, renderLen = renderItemToWav(item, inputFile, planEntry.selStart, planEntry.selEnd)
                if not extracted then
                    extracted, err, renderStart, renderLen = renderPerItemOverlapFallback(item, inputFile, planEntry.selStart, planEntry.selEnd)
                end
            else
                extracted, err = renderSingleItemToWav(item, inputFile)
                renderStart = planEntry.item_position
                renderLen = planEntry.item_length
            end
            writeTimingEvent(itemDir, "lua_extract_end", jobIndex, { ok = extracted and true or false })

            if extracted then
                local sourceItemName = planEntry.sourceItemName
                local sourceItemDisplayName = planEntry.sourceItemDisplayName
                local itemName = sourceItemDisplayName
                local audioDuration = renderLen or 0
                if audioDuration <= 0 then
                    audioDuration = planEntry.item_length or 0
                end

                local displayTrackName = trackName
                if not planEntry.isTimeSelection then
                    -- Restore original Case 2 naming: Track Name [1/2]
                    local selectedItems = (noTimeSelectionItemMap and noTimeSelectionItemMap[track]) or getSelectedAudibleItemsOnTrack(track, soloActive)
                    displayTrackName = trackName .. " [" .. planEntry.original_selection_order .. "/" .. #selectedItems .. "]"
                end

                table.insert(trackJobs, {
                    track = track,
                    trackName = displayTrackName,
                    uiColor = getJobUIColor(track, jobIndex),
                    trackDir = itemDir,
                    inputFile = inputFile,
                    sourceItem = item,
                    sourceItems = {item},
                    itemNames = itemName,
                    sourceTrackName = trackName,
                    sourceItemName = sourceItemName,
                    sourceItemDisplayName = sourceItemDisplayName,
                    itemCount = 1,
                    expectedItemCount = 1,
                    expectedStemCount = selectedStemCount,
                    selPos = renderStart,
                    selLen = renderLen,
                    index = jobIndex,
                    audioDuration = audioDuration,
                    perItem = true,
                })
            else
                local ef = io.open(itemDir .. PATH_SEP .. "extract_error.txt", "w")
                if ef then
                    ef:write("Track: " .. tostring(trackName) .. "\n")
                    ef:write("Item: " .. tostring(planEntry.item_name) .. "\n")
                    ef:write("Error: " .. tostring(err) .. "\n")
                    ef:close()
                end
                debugLog("Per-item extract failed: " .. tostring(err))
            end
        else
            -- Combined track job (one job per track)
            jobIndex = jobIndex + 1
            local trackDir = baseTempDir .. PATH_SEP .. "track_" .. jobIndex
            makeDir(trackDir)
            local inputFile = trackDir .. PATH_SEP .. "input.wav"

            local extracted, err, sourceItem, allSourceItems
            writeTimingEvent(trackDir, "lua_extract_start", jobIndex)
            if hasTimeSel then
                extracted, err, sourceItem, allSourceItems = renderTrackTimeSelectionToWav(track, inputFile)
            else
                extracted, err, sourceItem, allSourceItems = renderTrackSelectedItemsToWav(track, inputFile)
            end
            writeTimingEvent(trackDir, "lua_extract_end", jobIndex, { ok = extracted and true or false })

            if extracted then
                -- Get media item name(s) for display
                local itemNames = {}
                local itemNameSet = {}
                local items = allSourceItems or {sourceItem}
                for _, item in ipairs(items) do
                    if item and reaper.ValidatePtr(item, "MediaItem*") then
                        local take = reaper.GetActiveTake(item)
                        if take then
                            local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                            if takeName and takeName ~= "" then
                                if not itemNameSet[takeName] then
                                    table.insert(itemNames, takeName)
                                    itemNameSet[takeName] = true
                                end
                            else
                                -- Try to get source filename
                                local source = reaper.GetMediaItemTake_Source(take)
                                if source then
                                    local sourcePath = reaper.GetMediaSourceFileName(source, "")
                                    if sourcePath and sourcePath ~= "" then
                                        local fileName = sourcePath:match("([^/\\]+)$") or sourcePath
                                        if not itemNameSet[fileName] then
                                            table.insert(itemNames, fileName)
                                            itemNameSet[fileName] = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                local itemNamesStr = #itemNames > 0 and table.concat(itemNames, ", ") or "Unknown"

                -- Get audio duration without spawning ffprobe/CMD
                local audioDuration = 0
                if hasTimeSel then
                    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
                    audioDuration = math.max(0, (endTime or 0) - (startTime or 0))
                elseif sourceItem and reaper.ValidatePtr(sourceItem, "MediaItem*") then
                    audioDuration = reaper.GetMediaItemInfo_Value(sourceItem, "D_LENGTH") or 0
                end

                local expectedItemCount = (hasTimeSel and SETTINGS.createNewTracks and items and #items > 0) and #items or 1
                local expectedStemCount = selectedStemCount * expectedItemCount
                table.insert(trackJobs, {
                    track = track,
                    trackName = trackName,
                    uiColor = getJobUIColor(track, jobIndex),
                    trackDir = trackDir,
                    inputFile = inputFile,
                    sourceItem = sourceItem,
                    sourceItems = allSourceItems or {sourceItem},  -- All items for mute/delete
                    itemNames = itemNamesStr,
                    itemCount = #items,
                    expectedItemCount = expectedItemCount,
                    expectedStemCount = expectedStemCount,
                    index = jobIndex,
                    audioDuration = audioDuration,  -- Duration in seconds
                })
            end
        end
    end

    if perItemMap and perItemCandidates > 0 and perItemEligible == 0 then
        isProcessingActive = false
        showMessage(HELPERS.getNoAudibleTargetsTitle(), HELPERS.getNoAudibleTargetsMessage(), "info", true)
        return
    end

    if #trackJobs == 0 then
        -- Nothing started; unlock workflow so user can try again
        isProcessingActive = false
        showMessage("Error", "Failed to extract audio from any tracks.", "error")
        return
    end

    -- Jobs are already sorted by the sourcePlan

    -- Store jobs in queue for progress tracking
    multiTrackQueue.jobs = trackJobs
    multiTrackQueue.totalTracks = #trackJobs
    multiTrackQueue.completedCount = 0
    multiTrackQueue.baseTempDir = baseTempDir
    multiTrackQueue.active = true
    multiTrackQueue.selectedStemCount = selectedStemCount
    local expectedItemsTotal = 0
    local expectedStemsTotal = 0
    for _, job in ipairs(trackJobs) do
        expectedItemsTotal = expectedItemsTotal + (job.expectedItemCount or 1)
        expectedStemsTotal = expectedStemsTotal + (job.expectedStemCount or selectedStemCount or 0)
    end
    multiTrackQueue.expectedItemCount = expectedItemsTotal
    multiTrackQueue.expectedStemCount = expectedStemsTotal
    if perItemEligible > 0 then
        multiTrackQueue.detectedItemCount = perItemEligible
    elseif perItemCandidates > 0 then
        multiTrackQueue.detectedItemCount = perItemCandidates
    else
        multiTrackQueue.detectedItemCount = expectedItemsTotal
    end
    multiTrackQueue.queuedItemCount = #trackJobs
    -- Default: follow user's parallel/sequential preference.
    -- However, on Windows CPU-only (device=cpu/auto), parallel multi-job runs can be MUCH slower
    -- because each job loads the model separately and they compete for CPU/RAM/disk.
    local requestedParallel = effectiveRunRequestedParallel()
    multiTrackQueue.requestedParallel = requestedParallel and true or false
    multiTrackQueue.sequentialMode = not requestedParallel
    multiTrackQueue.forceSequentialReason = nil
    multiTrackQueue.parallelJobLimit = nil
    multiTrackQueue.executionModeReason = requestedParallel and "user_parallel" or "user_sequential"
    local hasPerItemJobs = false
    for _, job in ipairs(trackJobs) do
        if job.perItem then
            hasPerItemJobs = true
            break
        end
    end
    if requestedParallel and #trackJobs > 1 then
        local function hasRuntimeGpuBackends()
            local list = RUNTIME_DEVICES or DEVICES or {}
            for _, d in ipairs(list) do
                local id = string.lower(tostring(d.id or ""))
                local typ = string.lower(tostring(d.type or ""))
                if typ == "cuda" or typ == "directml" or typ == "mps" then return true end
                if id:match("^cuda:") or id:match("^directml:") or id == "mps" then return true end
            end
            return false
        end
        local function hasRuntimeBackendType(kind)
            local needle = string.lower(tostring(kind or ""))
            local list = RUNTIME_DEVICES or DEVICES or {}
            for _, d in ipairs(list) do
                local id = string.lower(tostring(d.id or ""))
                local typ = string.lower(tostring(d.type or ""))
                if typ == needle then return true end
                if needle == "directml" and id:match("^directml:") then return true end
                if needle == "cuda" and id:match("^cuda:") then return true end
                if needle == "mps" and id == "mps" then return true end
            end
            return false
        end
        local function detectLogicalCpuCount()
            local envCount = tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "")
            if envCount and envCount > 0 then return math.floor(envCount) end
            local h = io.popen("getconf _NPROCESSORS_ONLN 2>/dev/null")
            if h then
                local out = tonumber((h:read("*a") or ""):match("%d+"))
                h:close()
                if out and out > 0 then return math.floor(out) end
            end
            return nil
        end
        local function detectSystemRamGiB()
            if OS == "Linux" then
                local f = io.open("/proc/meminfo", "r")
                if f then
                    local txt = f:read("*a") or ""
                    f:close()
                    local kb = tonumber((txt:match("MemTotal:%s*(%d+)") or ""))
                    if kb and kb > 0 then return kb / (1024 * 1024) end
                end
            elseif OS == "macOS" then
                local h = io.popen("sysctl -n hw.memsize 2>/dev/null")
                if h then
                    local bytes = tonumber((h:read("*a") or ""):match("%d+"))
                    h:close()
                    if bytes and bytes > 0 then return bytes / (1024 * 1024 * 1024) end
                end
            elseif OS == "Windows" then
                local kb = tonumber(os.getenv("TOTALPHYSICALMEMORYKB") or "")
                if kb and kb > 0 then return kb / (1024 * 1024) end
            end
            return nil
        end

        local dev = string.lower(effectiveRunDevice())
        local explicitDirectml = dev:find("directml", 1, true) ~= nil
        local directmlMultiJob = explicitDirectml

        -- DirectML multi-job runs are not stable enough yet across Windows GPU stacks.
        -- Run them sequentially so time-selection/multi-track jobs do not silently drop outputs
        -- after the first successful item/track. Do not apply this to AUTO:
        -- AUTO may legitimately choose CUDA on mixed-GPU Windows systems.
        if not multiTrackQueue.sequentialMode and directmlMultiJob then
            multiTrackQueue.sequentialMode = true
            multiTrackQueue.forceSequentialReason = "directml_multi_track"
            debugLog("Forcing sequential multi-track processing (directml_multi_track)")
        end

        -- Respect user's Parallel choice even on CPU.
        -- Only force sequential if device is "auto" AND we know for sure there is no GPU.
        if not multiTrackQueue.sequentialMode and dev == "auto" and not hasRuntimeGpuBackends() then
            dev = "cpu"
        end

        -- Adaptive CPU execution mode:
        -- allow parallel on capable multi-core systems, otherwise stay sequential.
        if not multiTrackQueue.sequentialMode and dev == "cpu" then
            local cpuCount = detectLogicalCpuCount()
            local ramGiB = detectSystemRamGiB()
            local minCpuForParallel = 8
            local minRamGiBForParallel = 8
            local cpuOk = cpuCount and cpuCount >= minCpuForParallel
            local ramOk = ramGiB and ramGiB >= minRamGiBForParallel
            if cpuOk and ramOk then
                local adaptiveCap = math.max(1, math.floor(cpuCount / 2))
                multiTrackQueue.parallelJobLimit = math.min(#trackJobs, adaptiveCap)
                multiTrackQueue.executionModeReason = "cpu_threads_ok"
                debugLog(
                    "Adaptive CPU parallel enabled: cores=" .. tostring(cpuCount)
                        .. " ramGiB=" .. string.format("%.1f", ramGiB)
                        .. " cap=" .. tostring(multiTrackQueue.parallelJobLimit)
                )
            else
                multiTrackQueue.sequentialMode = true
                if not cpuCount then
                    multiTrackQueue.forceSequentialReason = "cpu_threads_unknown"
                    multiTrackQueue.executionModeReason = "cpu_threads_unknown"
                elseif cpuCount < minCpuForParallel then
                    multiTrackQueue.forceSequentialReason = "cpu_threads_low"
                    multiTrackQueue.executionModeReason = "cpu_threads_low"
                elseif not ramGiB then
                    multiTrackQueue.forceSequentialReason = "cpu_ram_unknown"
                    multiTrackQueue.executionModeReason = "cpu_ram_unknown"
                else
                    multiTrackQueue.forceSequentialReason = "cpu_ram_low"
                    multiTrackQueue.executionModeReason = "cpu_ram_low"
                end
                debugLog(
                    "Adaptive CPU sequential fallback (" .. tostring(multiTrackQueue.forceSequentialReason)
                        .. "): cores=" .. tostring(cpuCount) .. " ramGiB=" .. tostring(ramGiB)
                )
            end
        end
    end
    if multiTrackQueue.sequentialMode and not multiTrackQueue.executionModeReason then
        multiTrackQueue.executionModeReason = multiTrackQueue.forceSequentialReason or "user_sequential"
    end
    multiTrackQueue.currentJobIndex = 0
    multiTrackQueue.globalStartTime = os.time()  -- Track total elapsed time
    multiTrackQueue.totalAudioDuration = 0  -- Will be updated when jobs start
    SW_TIMING.beginRun({ mode = multiTrackQueue.sequentialMode and "sequential" or "parallel", job_count = #trackJobs, model = SETTINGS and SETTINGS.model or "", device = SETTINGS and SETTINGS.device or "" })

    if not multiTrackQueue.sequentialMode and type(INTERNAL_PARALLEL_JOB_LIMIT) == "number" and INTERNAL_PARALLEL_JOB_LIMIT > 0 then
        multiTrackQueue.parallelJobLimit = math.max(1, math.floor(INTERNAL_PARALLEL_JOB_LIMIT))
    end

    if not multiTrackQueue.sequentialMode then
        -- Start all jobs (default) or a capped subset (internal dev limiter).
        local launchCount = #trackJobs
        if multiTrackQueue.parallelJobLimit then
            launchCount = math.min(#trackJobs, multiTrackQueue.parallelJobLimit)
            debugLog("Applying internal parallel job cap: " .. tostring(multiTrackQueue.parallelJobLimit))
        end
        for idx, job in ipairs(trackJobs) do
            if idx > launchCount then break end
            _sep.startSeparationProcessForJob(job, 25)  -- Smaller segments for parallel
        end
    else
        -- Sequential mode: start only the first job (uses less VRAM)
        _sep.startSeparationProcessForJob(trackJobs[1], 40)  -- Larger segments for sequential
        multiTrackQueue.currentJobIndex = 1
    end

    SW_LOG.logExecResult(
        "timing:workers_launched count=" .. tostring(#trackJobs)
            .. " mode=" .. (multiTrackQueue.sequentialMode and "sequential" or "parallel")
            .. " cap=" .. tostring(multiTrackQueue.parallelJobLimit or "none")
            .. " reason=" .. tostring(multiTrackQueue.executionModeReason or multiTrackQueue.forceSequentialReason or "none"),
        nil,
        ""
    )

    -- Show progress window that monitors all jobs
    _sep.showMultiTrackProgressWindow()
end

-- Start a separation process for one job (no window, just background process)
-- segmentSize: optional, defaults to 25 for parallel, 40 for sequential
_sep.startSeparationProcessForJob = function(job, segmentSize)
    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end
    segmentSize = segmentSize or 25
    local logFile = job.trackDir .. PATH_SEP .. "separation_log.txt"
    local stdoutFile = job.trackDir .. PATH_SEP .. "stdout.txt"
    local doneFile = job.trackDir .. PATH_SEP .. "done.txt"
    local pidFile = job.trackDir .. PATH_SEP .. "pid.txt"
    local exitCodeFile = job.trackDir .. PATH_SEP .. "exit_code.txt"

    job.stdoutFile = stdoutFile
    job.doneFile = doneFile
    job.logFile = logFile
    job.pidFile = pidFile
    job.exitCodeFile = exitCodeFile
    job.execLogPath = SW_LOG.getLogPath()
    local execLogPath = job.execLogPath or SW_LOG.getLogPath()
    local jobTag = "item_" .. tostring(job.index or 0)
    job.percent = 0
    job.stage = T("progress_starting_backend") or "Starting backend..."
    job.startTime = os.time()
    SW_TIMING.beginJob(job.index, { track = job.trackName, audio_dur = job.audioDuration, model = SETTINGS and SETTINGS.model or "", device = SETTINGS and SETTINGS.device or "", mode = multiTrackQueue.sequentialMode and "sequential" or "parallel" })
    multiTrackQueue.currentIndex = tonumber(job.index) or 0
    multiTrackQueue.currentTrackName = job.sourceTrackName or job.trackName or ""
    multiTrackQueue.currentSourceTrack = job.track or nil

    -- Preflight checks so failures show up clearly in logs/UI.
    if not fileExists(job.inputFile) then
        local msg = "Input file missing: " .. tostring(job.inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: missing input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then lf:write(msg .. "\n"); lf:close() end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end
    local inSz = fileSizeBytes(job.inputFile)
    if not inSz or inSz <= 1024 then
        local msg = "Input WAV is empty (0 samples): " .. tostring(job.inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: empty input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then
            lf:write(msg .. "\n")
            lf:write("Hint: extraction failed; see input.wav.ffmpeg.log next to the input file.\n")
            lf:close()
        end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end
    if not trustedWindowsRuntime then
        local pythonAvailable = false
        if isAbsolutePath(PYTHON_PATH) then
            pythonAvailable = fileExists(PYTHON_PATH)
        else
            pythonAvailable = canRunPython(PYTHON_PATH)
        end
        if not pythonAvailable then
            local msg =
                "Python not found at: " .. tostring(PYTHON_PATH) .. "\n\n"
                .. "Run STEMwerk-SETUP.lua to repair the runtime."
            debugLog(msg)
            SW_LOG.logExecResult("preflight: python missing", -1, msg)
            local lf = io.open(logFile, "w")
            if lf then lf:write(msg .. "\n"); lf:close() end
            local df = io.open(doneFile, "w")
            if df then df:write("DONE\n"); df:close() end
            SW_LOG.writeExitCode(exitCodeFile, -1)
            return
        end
    end
    if not fileExists(SEPARATOR_SCRIPT) then
        local msg = "Separator script not found at: " .. tostring(SEPARATOR_SCRIPT)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: separator missing", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then lf:write(msg .. "\n"); lf:close() end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end

    -- Create empty progress/log files (Python writes to these directly)
    local sf = io.open(stdoutFile, "w")
    if sf then sf:close() end
    local lf = io.open(logFile, "w")
    if lf then lf:close() end

    local requestedDeviceArg = effectiveRunDevice()
    local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
    local modelArg = effectiveRunModel()
    local pythonCmd = string.format(
        '%s -u %s %s %s --model %s --device %s',
        quoteArg(PYTHON_PATH),
        quoteArg(SEPARATOR_SCRIPT),
        quoteArg(job.inputFile),
        quoteArg(job.trackDir),
        quoteArg(modelArg),
        quoteArg(deviceArg)
    )
    job.lastCmd = pythonCmd
    SW_LOG.logExecResult("LAUNCH: " .. pythonCmd, nil, "")
    writeTimingEvent(job, "python_launch", job.index, { mode = multiTrackQueue.sequentialMode and "sequential" or "parallel" })
    if tostring(deviceArg) ~= tostring(requestedDeviceArg) then
        debugLog("Job " .. tostring(job.index) .. " device=" .. tostring(requestedDeviceArg) .. " -> normalized to " .. tostring(deviceArg))
    end

    if OS == "Windows" then
        -- Windows: hidden PowerShell runner (async) that also writes pid.txt and done.txt.
        local vbsPath = job.trackDir .. PATH_SEP .. ("run_hidden_job_" .. tostring(job.index or 0) .. ".vbs")
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            local function escPS(s)
                s = tostring(s or "")
                s = s:gsub("'", "''")
                return s
            end
            local python = escPS(PYTHON_PATH)
            local sep = escPS(SEPARATOR_SCRIPT)
            local inF = escPS(job.inputFile)
            local outD = escPS(job.trackDir)
            local m = escPS(modelArg)
            local dev = escPS(deviceArg)
            local stdoutF = escPS(stdoutFile)
            local stderrF = escPS(logFile)
            local pidF = escPS(pidFile)
            local doneF = escPS(doneFile)
            local exitF = escPS(exitCodeFile)
            local logPath = escPS(execLogPath)
            local jobTagEsc = escPS(jobTag)

            local psInner =
                "$py='" .. python .. "';" ..
                "$sep='" .. sep .. "';" ..
                "$in='" .. inF .. "';" ..
                "$out='" .. outD .. "';" ..
                "$model='" .. m .. "';" ..
                "$dev='" .. dev .. "';" ..
                "$logPath='" .. logPath .. "';" ..
                "$jobTag='" .. jobTagEsc .. "';" ..
                "$env:STEMWERK_LOG_PATH=$logPath;" ..
                "$env:STEMWERK_JOB_TAG=$jobTag;" ..
                "$dq=[char]34;" ..
                "$sepq=$dq + $sep + $dq;" ..
                "$inq=$dq + $in + $dq;" ..
                "$outq=$dq + $out + $dq;" ..
                "$modelq=$dq + $model + $dq;" ..
                "$devq=$dq + $dev + $dq;" ..
                "$p = Start-Process -FilePath $py -ArgumentList @('-u',$sepq,$inq,$outq,'--model',$modelq,'--device',$devq) -WorkingDirectory '" .. outD .. "' -WindowStyle Hidden -PassThru -RedirectStandardOutput '" .. stdoutF .. "' -RedirectStandardError '" .. stderrF .. "';" ..
                " Set-Content -Path '" .. pidF .. "' -Value $p.Id -Encoding ascii;" ..
                " Wait-Process -Id $p.Id;" ..
                " $ec=$p.ExitCode; Set-Content -Path '" .. exitF .. "' -Value $ec -Encoding ascii;" ..
                " if ($ec -eq 0) { Set-Content -Path '" .. doneF .. "' -Value 'DONE' -Encoding ascii } else { Set-Content -Path '" .. doneF .. "' -Value 'ERROR' -Encoding ascii }"

            vbsFile:write('Set sh = CreateObject("WScript.Shell")\n')
            vbsFile:write('cmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""' .. psInner .. '"""\n')
            vbsFile:write('sh.Run cmd, 0, False\n')
            vbsFile:close()

            local wscriptCmd = 'wscript "' .. vbsPath .. '"'
            debugLog('Starting job ' .. tostring(job.index) .. ' (async): ' .. wscriptCmd)
            if reaper.ExecProcess then
                reaper.ExecProcess(wscriptCmd, -1)
            else
                local handle = io.popen(wscriptCmd)
                if handle then handle:close() end
            end
        else
            -- Fallback: run in foreground (old behavior)
            local cmd = string.format(
                '%s -u %s %s %s --model %s --device %s >%s 2>%s && echo DONE >%s',
                quoteArg(PYTHON_PATH),
                quoteArg(SEPARATOR_SCRIPT),
                quoteArg(job.inputFile),
                quoteArg(job.trackDir),
                quoteArg(modelArg),
                quoteArg(deviceArg),
                quoteArg(stdoutFile),
                quoteArg(logFile),
                quoteArg(doneFile)
            )
            debugLog('Job ' .. tostring(job.index) .. ' launcher write failed; executing (foreground): ' .. tostring(cmd))
            os.execute(cmd)
        end
    else
        -- Unix: background sh launcher that writes pid.txt and done.txt.
        local launcherPath = job.trackDir .. PATH_SEP .. "run_bg.sh"
        local script = io.open(launcherPath, "w")
          if script then
              script:write("#!/bin/sh\n")
              script:write("PY=" .. quoteArg(PYTHON_PATH) .. "\n")
              script:write("SEP=" .. quoteArg(SEPARATOR_SCRIPT) .. "\n")
              local ffmpegPath = FFMPEG_PATH or getExtStateValue("ffmpegPath") or getExtStateValue("FFMPEG_PATH")
              if ffmpegPath and ffmpegPath ~= "" then
                  script:write("STEMWERK_FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\n")
                  script:write("FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\n")
                  script:write("IMAGEIO_FFMPEG_EXE=" .. quoteArg(ffmpegPath) .. "\n")
                  script:write("export STEMWERK_FFMPEG_PATH FFMPEG_PATH IMAGEIO_FFMPEG_EXE\n")
                  script:write("FFMPEG_DIR=$(dirname \"$FFMPEG_PATH\")\n")
                  script:write("PATH=\"$FFMPEG_DIR:${PATH}\"\n")
                  script:write("export PATH\n")
              end
              script:write("IN=" .. quoteArg(job.inputFile) .. "\n")
              script:write("OUT=" .. quoteArg(job.trackDir) .. "\n")
              script:write("STEMWERK_LOG_PATH=" .. quoteArg(execLogPath) .. "\n")
              script:write("STEMWERK_JOB_TAG=" .. quoteArg(jobTag) .. "\n")
              script:write("export STEMWERK_LOG_PATH STEMWERK_JOB_TAG\n")
              script:write("MODEL=" .. quoteArg(modelArg) .. "\n")
              script:write("DEVICE=" .. quoteArg(deviceArg) .. "\n")
            script:write("STDOUT=" .. quoteArg(stdoutFile) .. "\n")
            script:write("STDERR=" .. quoteArg(logFile) .. "\n")
            script:write("DONE=" .. quoteArg(doneFile) .. "\n")
            script:write("PIDFILE=" .. quoteArg(pidFile) .. "\n")
            script:write("EXITCODE=" .. quoteArg(exitCodeFile) .. "\n")
            script:write("PY_SITE=$(\"$PY\" -c \"import sysconfig; print(sysconfig.get_paths().get('purelib',''))\")\n")
            script:write("if [ -n \"$PY_SITE\" ]; then\n")
            script:write("  for d in \"$PY_SITE\"/nvidia/*/lib \"$PY_SITE\"/nvidia/*/lib64; do\n")
            script:write("    if [ -d \"$d\" ]; then\n")
            script:write("      case \":$LD_LIBRARY_PATH:\" in\n")
            script:write("        *\":$d:\"*) ;;\n")
            script:write("        *) LD_LIBRARY_PATH=\"${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$d\" ;;\n")
            script:write("      esac\n")
            script:write("    fi\n")
            script:write("  done\n")
            script:write("  export LD_LIBRARY_PATH\n")
            script:write("fi\n")
            script:write("(\n")
            script:write('  "$PY" -u "$SEP" "$IN" "$OUT" --model "$MODEL" --device "$DEVICE" >"$STDOUT" 2>"$STDERR" &\n')
            script:write('  worker_pid=$!\n')
            script:write('  echo "$worker_pid" > "$PIDFILE"\n')
            script:write('  wait "$worker_pid"\n')
            script:write("  rc=$?\n")
            script:write('  echo "$rc" > "$EXITCODE"\n')
            script:write('  if [ "$rc" -eq 0 ]; then\n')
            script:write('    echo DONE > "$DONE"\n')
            script:write('  else\n')
            script:write('    echo "EXIT:$rc" >> "$STDERR"\n')
            script:write('    echo ERROR > "$DONE"\n')
            script:write('  fi\n')
            script:write(") &\n")
            script:close()

            local cmd = "sh " .. quoteArg(launcherPath) .. suppressStderr()
            debugLog("Starting job " .. tostring(job.index) .. " (async): " .. cmd)
            os.execute(cmd)
        else
            -- Fallback: run in foreground
            local cmd = string.format(
                '%s -u %s %s %s --model %s --device %s >%s 2>%s && echo DONE >%s',
                quoteArg(PYTHON_PATH),
                quoteArg(SEPARATOR_SCRIPT),
                quoteArg(job.inputFile),
                quoteArg(job.trackDir),
                quoteArg(modelArg),
                quoteArg(deviceArg),
                quoteArg(stdoutFile),
                quoteArg(logFile),
                quoteArg(doneFile)
            )
            debugLog('Job ' .. tostring(job.index) .. ' launcher write failed; executing (foreground): ' .. tostring(cmd))
            local ok, _, code = os.execute(cmd)
            local rc = (ok == true or ok == 0) and 0 or (code or 1)
            SW_LOG.writeExitCode(exitCodeFile, rc)
        end
    end
end

-- Update progress for all jobs from their stdout files
_sep.updateAllJobsProgress = function()
    for _, job in ipairs(multiTrackQueue.jobs) do
        -- Only check progress for jobs that have been started
        if job.startTime then
            local f = io.open(job.stdoutFile, "r")
            if f then
                local lastProgress = nil
                for line in f:lines() do
                    local percent, stage = line:match("PROGRESS:(%d+):(.+)")
                    if percent then
                        local progressPercent = tonumber(percent)
                        lastProgress = { percent = progressPercent, stage = stage }
                        job.timingSeen = job.timingSeen or {}
                        local function markProgressEvent(flagName, eventName)
                            if not job.timingSeen[flagName] then
                                job.timingSeen[flagName] = true
                                writeTimingEvent(job, eventName, job.index, {
                                    percent = progressPercent,
                                    stage = stage,
                                })
                            end
                        end
                        if progressPercent and progressPercent > 0 then
                            markProgressEvent("first_progress_seen", "first_progress_seen")
                        end
                        if progressPercent and progressPercent >= 50 then
                            markProgressEvent("progress_50_seen", "progress_50_seen")
                        end
                        if progressPercent and progressPercent >= 87 then
                            markProgressEvent("progress_87_or_88_seen", "progress_87_or_88_seen")
                        end
                        if progressPercent and progressPercent >= 90 then
                            markProgressEvent("progress_90_or_92_seen", "progress_90_or_92_seen")
                        end
                    end
                end
                f:close()
                if lastProgress then
                    job.percent = lastProgress.percent
                    job.stage = lastProgress.stage
                end
            end

            -- Check if done
            local doneFile = io.open(job.doneFile, "r")
            if doneFile then
                doneFile:close()
                if not job.done then
                    SW_LOG.persistRunDiagnostics(job.trackDir)
                    job.done = true
                    job.stage = "Waiting for import"
                    writeTimingEvent(job, "done_seen", job.index)
                    SW_TIMING.mark(job.index, "output_detected")
                    SW_LOG.logExecResult(
                        "timing:job_done job=" .. tostring(job.index) .. " dir=" .. tostring(job.trackDir),
                        nil,
                        ""
                    )
                    -- In sequential mode, start the next job when this one completes
                    if multiTrackQueue.sequentialMode then
                        local nextIndex = multiTrackQueue.currentJobIndex + 1
                        if nextIndex <= #multiTrackQueue.jobs then
                            local nextJob = multiTrackQueue.jobs[nextIndex]
                            _sep.startSeparationProcessForJob(nextJob, 40)  -- Larger segments for sequential
                            multiTrackQueue.currentJobIndex = nextIndex
                        end
                    end
                end
            end
        else
            -- Job not yet started (sequential mode)
            job.percent = 0
            job.stage = T("progress_queued") or "Queued"
        end
    end

    if multiTrackQueue.sequentialMode then
        local runningJob = false
        local nextWaitingIndex = nil
        for idx, job in ipairs(multiTrackQueue.jobs) do
            if job.startTime and not job.done then
                runningJob = true
                break
            end
            if nextWaitingIndex == nil and not job.startTime then
                nextWaitingIndex = idx
            end
        end
        if not runningJob and nextWaitingIndex ~= nil then
            local nextJob = multiTrackQueue.jobs[nextWaitingIndex]
            debugLog("Sequential queue fallback starting job " .. tostring(nextWaitingIndex))
            _sep.startSeparationProcessForJob(nextJob, 40)
            multiTrackQueue.currentJobIndex = math.max(tonumber(multiTrackQueue.currentJobIndex) or 0, nextWaitingIndex)
        end
    elseif multiTrackQueue.parallelJobLimit and multiTrackQueue.active and not progressState.cancelRequested then
        local activeCount = 0
        local waitingJobs = {}
        for _, job in ipairs(multiTrackQueue.jobs) do
            if job.startTime and not job.done then
                activeCount = activeCount + 1
            elseif not job.startTime then
                waitingJobs[#waitingJobs + 1] = job
            end
        end
        while activeCount < multiTrackQueue.parallelJobLimit and #waitingJobs > 0 do
            local nextJob = table.remove(waitingJobs, 1)
            _sep.startSeparationProcessForJob(nextJob, 25)
            activeCount = activeCount + 1
        end
    end
end

-- Check if all jobs are done
_sep.allJobsDone = function()
    for _, job in ipairs(multiTrackQueue.jobs) do
        if not job.done then return false end
    end
    return true
end

-- Calculate overall progress
_sep.getOverallProgress = function()
    local total = 0
    for _, job in ipairs(multiTrackQueue.jobs) do
        total = total + (job.percent or 0)
    end
    return math.floor(total / #multiTrackQueue.jobs)
end

-- Draw multi-track progress window
function drawMultiTrackProgressWindow()
    -- Function-level aliases for extracted module (don't count toward chunk local limit)
    local PROGRESS_BASE_W         = UI_PROGRESS.PROGRESS_BASE_W
    local PROGRESS_BASE_H         = UI_PROGRESS.PROGRESS_BASE_H
    local progressUiLabel         = UI_PROGRESS.progressUiLabel
    local readableTerminalAccent  = UI_PROGRESS.readableTerminalAccent
    local drawTerminalFx          = UI_PROGRESS.drawTerminalFx
    local formatProgressLine      = UI_PROGRESS.formatProgressLine
    local localizeProgressStagePrefix = UI_PROGRESS.localizeProgressStagePrefix
    local getOverallProgress      = _sep.getOverallProgress
    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    local w, h = gfx.w, gfx.h

    -- Scale
    local scale = math.min(w / PROGRESS_BASE_W, h / PROGRESS_BASE_H)
    scale = math.max(0.5, math.min(4.0, scale))
    local function PS(val) return math.floor(val * scale + 0.5) end

    -- Mouse position for UI interactions
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local rightMouseDown = gfx.mouse_cap & 2 == 2

    -- Tooltip tracking / UI click tracking (for background art click)
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0
    local cancelClicked = false
    GUI.uiClickedThisFrame = false

    -- === PROCEDURAL ART AS FULL BACKGROUND LAYER ===
    -- Pure black/white background first
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, w, h, 1)

    proceduralArt.time = proceduralArt.time + 0.016  -- ~60fps
    if not (type(isThemeUtilityMode) == "function" and isThemeUtilityMode()) then
        drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

        -- Theme-aware readability wash over animated FX
        local overlayAlpha = getFxReadabilityOverlayAlpha()
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, overlayAlpha)
        else
            gfx.set(1, 1, 1, overlayAlpha)
        end
        gfx.rect(0, 0, w, h, 1)
    end

    -- === THEME TOGGLE (top right) ===
    local iconScale = 0.66
    local themeSize = math.max(PS(12), math.floor(PS(20) * iconScale + 0.5))
    local themeX = w - themeSize - PS(10)
    local themeY = PS(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = utilityMode and 1.0 or updateControlsOpacity(multiTrackQueue, mouseInControls)

    if utilityMode then
        local _uc = {
            S = PS, w = w, mx = mx, my = my,
            mouseDown = mouseDown,
            rightMouseDown = rightMouseDown,
            state = multiTrackQueue,
            setLanguageFn = setLanguage,
            themeX = themeX, themeY = themeY, themeSize = themeSize,
        }
        UI_CONTROLS.drawUtilityControls(_uc)
        if _uc.tooltipText then
            tooltipText = _uc.tooltipText
            tooltipX = _uc.tooltipX
            tooltipY = _uc.tooltipY
        end
    else
        if SETTINGS.darkMode then
            gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.5) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
            gfx.set(0, 0, 0, 1 * controlsOpacity)
            gfx.circle(themeX + themeSize/2 + 3, themeY + themeSize/2 - 2, themeSize/2 - 3, 1, 1)
        else
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.7) * controlsOpacity)
            gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/3, 1, 1)
            gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.7) * controlsOpacity)
            for i = 0, 7 do
                local angle = i * math.pi / 4
                local x1 = themeX + themeSize/2 + math.cos(angle) * (themeSize/3 + 1)
                local y1 = themeY + themeSize/2 + math.sin(angle) * (themeSize/3 + 1)
                local x2 = themeX + themeSize/2 + math.cos(angle) * (themeSize/2 - 1)
                local y2 = themeY + themeSize/2 + math.sin(angle) * (themeSize/2 - 1)
                gfx.line(x1, y1, x2, y2)
            end
        end
        if themeHover and controlsOpacity > 0.3 then
            GUI.uiClickedThisFrame = true
            tooltipText = getThemeToggleTooltip()
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
            if rightMouseDown and not (multiTrackQueue.wasRightMouseDown or false) then cycleThemePreset() end
            if mouseDown and not multiTrackQueue.wasMouseDown then
                SETTINGS.darkMode = not SETTINGS.darkMode; updateTheme(); saveSettings()
            end
        end
        local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
        local fxX = themeX + (themeSize - fxSize) / 2
        local fxY = themeY + themeSize + PS(3)
        local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)
        local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
        if SETTINGS.visualFX then gfx.set(0.4, 0.9, 0.5, fxAlpha) else gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6) end
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2; gfx.y = fxY + PS(1); gfx.drawstr(fxText)
        if SETTINGS.visualFX then
            gfx.set(1, 1, 0.5, fxAlpha * 0.8)
            gfx.circle(fxX - PS(1), fxY + PS(2), PS(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - PS(2), PS(1.5), 1, 1)
        else
            gfx.set(0.8, 0.3, 0.3, fxAlpha)
            gfx.line(fxX - PS(1), fxY + fxSize / 2, fxX + fxSize + PS(1), fxY + fxSize / 2)
        end
        if fxHover and controlsOpacity > 0.3 then
            GUI.uiClickedThisFrame = true
            local fxTip = SETTINGS.visualFX and (T("fx_disable") or "Disable visual effects") or (T("fx_enable") or "Enable visual effects")
            tooltipText = fxTip .. " " .. (T("fx_switch_native_suffix") or "Right-click: switch to REAPER Native UI.")
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
        end
        if fxHover and mouseDown and not multiTrackQueue.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.visualFX = not SETTINGS.visualFX; saveSettings()
        end
        if fxHover and rightMouseDown and not (multiTrackQueue.wasRightMouseDown or false) and controlsOpacity > 0.3 then
            SETTINGS.themePreset = "reaper_native"
            updateTheme()
            saveSettings()
        end
    end

    -- Title / branding
    gfx.setfont(1, "Arial", PS(16), string.byte('b'))
    local titleX = PS(20)
    local titleY = PS(25)

    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.x = titleX
    gfx.y = titleY
    local multiTrackLabel = T("multi_track") or "Multi-Track"
    if utilityMode then
        gfx.drawstr(multiTrackLabel .. " STEMwerk")
        local prefixW = gfx.measurestr(multiTrackLabel .. " STEMwerk")
        gfx.x = titleX + prefixW
        gfx.y = titleY
    else
        gfx.drawstr(multiTrackLabel .. " ")
        local prefixW = gfx.measurestr(multiTrackLabel .. " ")
        local logoW = measureStemwerkLogo(PS(16), "Arial", true)
        drawWavingStemwerkLogo({
            x = titleX + prefixW,
            y = titleY,
            fontSize = PS(16),
            time = os.clock(),
            amp = PS(2),
            speed = 3,
            phase = 0.5,
            alphaStem = 1,
            alphaRest = 1,
        })
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = titleX + prefixW + logoW
        gfx.y = titleY
    end
    local runtimeMode, _, runtimeReason = getRuntimeModeLabel(multiTrackQueue)
    local anyPerItem = false
    for _, job in ipairs(multiTrackQueue.jobs) do
        if job.perItem then anyPerItem = true; break end
    end
    local titleJobCount = #multiTrackQueue.jobs
    if anyPerItem and (multiTrackQueue.detectedItemCount or 0) > 0 then
        titleJobCount = multiTrackQueue.detectedItemCount
    end
    local function jobUnitLabel(count)
        if anyPerItem then
            return (count == 1) and (T("footer_item") or "item") or (T("footer_items") or "items")
        end
        return (count == 1) and (T("footer_track") or "track") or (T("footer_tracks") or "tracks")
    end
    gfx.drawstr(string.format(" - %s (%d %s)", runtimeMode, titleJobCount, jobUnitLabel(titleJobCount)))

    if not utilityMode then
        -- Language toggle (left of theme toggle)
        local langW = PS(22)
        local langH = PS(14)
        local langX = themeX - langW - PS(6)
        local langY = themeY + (themeSize - langH) / 2
        local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH
        gfx.setfont(1, "Arial", PS(9), string.byte('b'))
        local langCode = string.upper(SETTINGS.language or "EN")
        local langTextW = gfx.measurestr(langCode)
        if langHover then
            GUI.uiClickedThisFrame = true
            gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
            if controlsOpacity > 0.3 then
                tooltipText = T("tooltip_lang")
                tooltipX, tooltipY = mx + PS(10), my + PS(15)
                if rightMouseDown and not (multiTrackQueue.wasRightMouseDown or false) then
                    SETTINGS.tooltips = not SETTINGS.tooltips; saveSettings()
                end
                if mouseDown and not multiTrackQueue.wasMouseDown then
                    local langs = {"en", "nl", "de"}
                    local currentIdx = 1
                    for i, l in ipairs(langs) do if l == SETTINGS.language then currentIdx = i; break end end
                    setLanguage(langs[(currentIdx % #langs) + 1]); saveSettings()
                end
            end
        else
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
        end
        gfx.x = langX + (langW - langTextW) / 2
        gfx.y = langY
        gfx.drawstr(langCode)
    end

    -- Stem indicators (simple colored boxes, like single-track)
    local selectedStems = {}
    local runIs6Stem = isEffectiveRun6Stem()
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or runIs6Stem) then
            table.insert(selectedStems, stem)
        end
    end

    local stemRowY = titleY + PS(20)
    local stemBoxSize = PS(12)
    local stemX = PS(20)
    if #selectedStems > 0 then
        gfx.setfont(1, "Arial", PS(10))
        for _, stem in ipairs(selectedStems) do
            if utilityMode then
                local ur, ug, ub = utilityProgressMutedColor()
                gfx.set(ur, ug, ub, 1)
            else
                gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
            end
            gfx.rect(stemX, stemRowY, stemBoxSize, stemBoxSize, 1)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = stemX + stemBoxSize + PS(5)
            gfx.y = stemRowY + PS(1)
            local stemLabel = getStemDisplayName(stem)
            gfx.drawstr(stemLabel)
            stemX = stemX + stemBoxSize + gfx.measurestr(stemLabel) + PS(16)
        end
    end

    if runtimeReason ~= "" then
        gfx.setfont(1, "Arial", PS(10))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.95)
        local reasonLabel = T("mode_reason_label") or "Reason"
        local reasonText = string.format("%s: %s", reasonLabel, runtimeReason)
        gfx.x = PS(20)
        gfx.y = stemRowY + stemBoxSize + PS(3)
        gfx.drawstr(reasonText)
    end

    -- Overall progress bar
    local barX = PS(20)
    local barY
    if #selectedStems > 0 then
        barY = stemRowY + stemBoxSize + (runtimeReason ~= "" and PS(18) or PS(8))
    else
        barY = PS(55)
    end
    local barW = w - PS(40)
    local barH = PS(20)
    local overallProgress = _sep.getOverallProgress()
    local animTime = proceduralArt.time or 0

    -- Progress bar background with subtle gradient
    local overallBarRadius = getThemeRadius(PS, 4, math.floor(barH / 2))
    drawThemeShadow(barX, barY, barW, barH, overallBarRadius, 0.58, "process")
    for i = 0, barH - 1 do
        local shade = 0.1 + (i / barH) * 0.05
        if not SETTINGS.darkMode then shade = 0.85 - (i / barH) * 0.05 end
        gfx.set(shade, shade, shade + 0.02, 1)
        gfx.line(barX, barY + i, barX + barW, barY + i)
    end
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(barX, barY, barW, barH, 0)
    drawLightSurfaceFinish(barX + 1, barY + 1, math.max(1, barW - 2), math.max(1, barH - 2), math.max(0, overallBarRadius - 1), "process", 1)

    -- Progress fill. Native utility mode uses a single muted REAPER-ish
    -- blue/green fill and skips animated glow.
    local fillW = math.floor(barW * overallProgress / 100)
    if fillW > 0 and #selectedStems > 0 then
        if utilityMode then
            local ur, ug, ub = utilityProgressColor()
            gfx.set(ur, ug, ub, 1)
            gfx.rect(barX + 1, barY + 1, math.max(1, fillW - 2), barH - 2, 1)
        else
            for i = 0, fillW - 1 do
                local pos = i / math.max(1, fillW - 1)
                local idx = math.floor(pos * (#selectedStems - 1)) + 1
                local nextIdx = math.min(idx + 1, #selectedStems)
                local blend = (pos * (#selectedStems - 1)) % 1

                idx = math.max(1, math.min(idx, #selectedStems))
                nextIdx = math.max(1, math.min(nextIdx, #selectedStems))

                local r = (selectedStems[idx].color[1] * (1 - blend) + selectedStems[nextIdx].color[1] * blend) / 255
                local g = (selectedStems[idx].color[2] * (1 - blend) + selectedStems[nextIdx].color[2] * blend) / 255
                local b = (selectedStems[idx].color[3] * (1 - blend) + selectedStems[nextIdx].color[3] * blend) / 255
                local pulse = 0.92 + math.sin(animTime * 3 + i * 0.05) * 0.08

                gfx.set(r * pulse, g * pulse, b * pulse, 1)
                gfx.line(barX + 1 + i, barY + 1, barX + 1 + i, barY + barH - 2)
            end
            -- Animated glow at the edge
            if fillW > 3 then
                local glowPulse = 0.5 + math.sin(animTime * 5) * 0.5
                gfx.set(1, 1, 1, glowPulse * 0.6)
                gfx.line(barX + fillW - 2, barY + 2, barX + fillW - 2, barY + barH - 3)
                gfx.set(1, 1, 1, glowPulse * 0.3)
                gfx.line(barX + fillW - 1, barY + 3, barX + fillW - 1, barY + barH - 4)
            end
        end
    end

    local function drawProgressText(text, x, y, alpha)
        alpha = alpha or 1
        if SETTINGS.darkMode then
            gfx.set(0, 0, 0, 0.6 * alpha)
            gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
            gfx.x, gfx.y = x - 1, y + 1; gfx.drawstr(text)
            gfx.x, gfx.y = x + 1, y - 1; gfx.drawstr(text)
            gfx.x, gfx.y = x - 1, y - 1; gfx.drawstr(text)
            gfx.set(1, 1, 1, alpha)
        else
            gfx.set(1, 1, 1, 0.35 * alpha)
            gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
            gfx.set(0.08, 0.10, 0.12, alpha)
        end
        gfx.x, gfx.y = x, y
        gfx.drawstr(text)
    end

    -- Progress text
    gfx.setfont(1, "Arial", PS(11))
    local progText = string.format("%d%%", overallProgress)
    local progW = gfx.measurestr(progText)
    local progX = barX + (barW - progW) / 2
    local progY = barY + PS(3)
    drawProgressText(progText, progX, progY, 1)

    -- === NERD TERMINAL TOGGLE BUTTON (always available; like sequential Processing window) ===
    local nerdBtnW = PS(22)
    local nerdBtnH = PS(18)
    local nerdBtnX = barX
    local nerdBtnY = barY + barH + PS(8)
    local nerdHover = mx >= nerdBtnX and mx <= nerdBtnX + nerdBtnW and my >= nerdBtnY and my <= nerdBtnY + nerdBtnH

    if nerdHover then GUI.uiClickedThisFrame = true end

    if multiTrackQueue.showTerminal then
        gfx.set(0.3, 0.8, 0.3, 1)  -- Green when active
    else
        gfx.set(0.4, 0.4, 0.4, nerdHover and 1 or 0.6)
    end
    gfx.rect(nerdBtnX, nerdBtnY, nerdBtnW, nerdBtnH, 1)
    gfx.set(0, 0, 0, 1)
    gfx.setfont(1, "Courier", PS(10), string.byte('b'))
    gfx.x = nerdBtnX + PS(3)
    gfx.y = nerdBtnY + PS(3)
    gfx.drawstr(">_")

    if nerdHover then
        if utilityMode then
            tooltipText = multiTrackQueue.showTerminal and (T("tooltip_nerd_mode_hide") or "Switch to Art View") or (T("tooltip_nerd_mode_show") or "Nerd Mode: Show terminal output")
        else
            tooltipText = multiTrackQueue.showTerminal and (T("tooltip_nerd_mode_hide") or "Switch to Art View") or (T("tooltip_nerd_mode_show") or "Nerd Mode: Show terminal output")
        end
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if mouseDown and not multiTrackQueue.wasMouseDown then
            multiTrackQueue.showTerminal = not multiTrackQueue.showTerminal
        end
    end

    for _, job in ipairs(multiTrackQueue.jobs) do
        if job.startTime and not job.done and isModelLoadingStage(job.stage) then
            if (barW - PS(150)) > PS(100)
                and drawModelLoadNoteBox(
                    barX + PS(120),
                    nerdBtnY,
                    barW - PS(150),
                    nerdBtnH,
                    mx,
                    my
                )
            then
                GUI.uiClickedThisFrame = true
                tooltipText = T("model_load_note_long") or "First model load can take longer. STEMwerk may download the model and warm up the selected backend."
                tooltipX, tooltipY = mx + PS(10), my + PS(15)
            end
            break
        end
    end

    -- === DISPLAY AREA (TRACK LIST or TERMINAL) ===
    local displayY = nerdBtnY + nerdBtnH + PS(10)
    -- Keep a little extra clearance above the footer in terminal view so the bottom border
    -- and return hint don't feel clipped by the status bar.
    local bottomPad = multiTrackQueue.showTerminal and PS(38) or PS(55)
    local displayH = h - displayY - bottomPad
    local displayX = PS(15)
    local displayW = w - PS(30)
    local terminalViewActive = (multiTrackQueue.showTerminal and displayH > PS(60))

    local activeJob = nil
    for _, job in ipairs(multiTrackQueue.jobs) do
        if job.startTime and not job.done then activeJob = job break end
    end

    -- Individual track progress (only when not in terminal view)
    local numJobs = #multiTrackQueue.jobs
    local infoBlockReserve = terminalViewActive and 0 or PS(34)
    local listGap = terminalViewActive and PS(8) or PS(4)
    local listAreaY = displayY
    local listAreaH = terminalViewActive and displayH or math.max(PS(78), displayH - infoBlockReserve - listGap)
    local infoY = listAreaY + listAreaH + listGap

    if terminalViewActive then
        -- Treat the terminal pane as UI so background art clicks don't trigger when reading logs.
        local termHover = mx >= displayX and mx <= displayX + displayW and my >= displayY and my <= displayY + displayH
        if termHover then GUI.uiClickedThisFrame = true end

        -- === TERMINAL VIEW (combined output from all active jobs) ===
        -- Theme-aware terminal palette (dark/light)
        local termBgR, termBgG, termBgB, termBgA
        local termBorderR, termBorderG, termBorderB, termBorderA
        local termHeaderR, termHeaderG, termHeaderB, termHeaderA
        local termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA
        local termTextR, termTextG, termTextB, termTextA
        local termDimR, termDimG, termDimB, termDimA
        local termOkR, termOkG, termOkB, termOkA
        local termWarnR, termWarnG, termWarnB, termWarnA
        local termErrR, termErrG, termErrB, termErrA
        local termProgR, termProgG, termProgB, termProgA

        if utilityMode then
            if SETTINGS.darkMode then
                termBgR, termBgG, termBgB, termBgA = 0.04, 0.04, 0.04, 1
                termBorderR, termBorderG, termBorderB, termBorderA = 0.35, 0.35, 0.35, 1
                termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.16, 0.16, 0.16, 1
                termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.86, 0.86, 0.86, 1
                termTextR, termTextG, termTextB, termTextA = 0.78, 0.78, 0.78, 1
                termDimR, termDimG, termDimB, termDimA = 0.55, 0.55, 0.55, 1
                termOkR, termOkG, termOkB, termOkA = 0.68, 0.78, 0.68, 1
                termWarnR, termWarnG, termWarnB, termWarnA = 0.82, 0.68, 0.40, 1
                termErrR, termErrG, termErrB, termErrA = 0.86, 0.38, 0.38, 1
                termProgR, termProgG, termProgB, termProgA = 0.64, 0.74, 0.64, 1
            else
                termBgR, termBgG, termBgB, termBgA = 0.96, 0.96, 0.94, 1
                termBorderR, termBorderG, termBorderB, termBorderA = 0.58, 0.58, 0.54, 1
                termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.86, 0.86, 0.82, 1
                termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.10, 0.10, 0.10, 1
                termTextR, termTextG, termTextB, termTextA = 0.20, 0.20, 0.18, 1
                termDimR, termDimG, termDimB, termDimA = 0.46, 0.46, 0.42, 1
                termOkR, termOkG, termOkB, termOkA = 0.24, 0.40, 0.24, 1
                termWarnR, termWarnG, termWarnB, termWarnA = 0.55, 0.38, 0.10, 1
                termErrR, termErrG, termErrB, termErrA = 0.70, 0.12, 0.12, 1
                termProgR, termProgG, termProgB, termProgA = 0.24, 0.40, 0.24, 1
            end
        elseif SETTINGS.darkMode then
            termBgR, termBgG, termBgB, termBgA = 0.07, 0.08, 0.09, 0.98
            termBorderR, termBorderG, termBorderB, termBorderA = 0.24, 0.34, 0.28, 0.85
            termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.13, 0.17, 0.15, 1
            termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.82, 0.88, 0.84, 1
            termTextR, termTextG, termTextB, termTextA = 0.78, 0.82, 0.80, 1
            termDimR, termDimG, termDimB, termDimA = 0.50, 0.56, 0.53, 1
            termOkR, termOkG, termOkB, termOkA = 0.52, 0.78, 0.58, 1
            termWarnR, termWarnG, termWarnB, termWarnA = 0.88, 0.70, 0.32, 1
            termErrR, termErrG, termErrB, termErrA = 0.90, 0.44, 0.44, 1
            termProgR, termProgG, termProgB, termProgA = 0.54, 0.78, 0.62, 1
        else
            termBgR, termBgG, termBgB, termBgA = 0.95, 0.95, 0.93, 1
            termBorderR, termBorderG, termBorderB, termBorderA = 0.55, 0.55, 0.50, 1
            termHeaderR, termHeaderG, termHeaderB, termHeaderA = 0.87, 0.88, 0.84, 1
            termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA = 0.11, 0.12, 0.11, 1
            termTextR, termTextG, termTextB, termTextA = 0.16, 0.17, 0.16, 1
            termDimR, termDimG, termDimB, termDimA = 0.40, 0.40, 0.37, 1
            termOkR, termOkG, termOkB, termOkA = 0.23, 0.41, 0.24, 1
            termWarnR, termWarnG, termWarnB, termWarnA = 0.56, 0.40, 0.11, 1
            termErrR, termErrG, termErrB, termErrA = 0.70, 0.16, 0.16, 1
            termProgR, termProgG, termProgB, termProgA = 0.24, 0.42, 0.26, 1
        end

        -- Accent tint: use the currently active track color for header/border (nice "alive" feedback).
        local activeAccent = nil
        if activeJob and type(activeJob.uiColor) == "table" then
            activeAccent = activeJob.uiColor
        end
        if (not utilityMode) and activeAccent then
            local ar, ag, ab = activeAccent[1] or THEME.accent[1], activeAccent[2] or THEME.accent[2], activeAccent[3] or THEME.accent[3]
            if SETTINGS.darkMode then
                termBorderR, termBorderG, termBorderB = ar, ag, ab
                termBorderA = 0.55
                termHeaderR, termHeaderG, termHeaderB, termHeaderA = ar * 0.75, ag * 0.75, ab * 0.75, 1
            else
                termBorderR, termBorderG, termBorderB = ar * 0.5, ag * 0.6, ab * 0.5
                termBorderA = 0.45
                termHeaderR = 0.85 + ar * 0.12
                termHeaderG = 0.85 + ag * 0.12
                termHeaderB = 0.85 + ab * 0.12
                termHeaderA = 1
            end
        end

        if (not utilityMode) and activeJob and type(activeJob.uiColor) == "table" then
            termProgR, termProgG, termProgB = activeJob.uiColor[1] or termProgR, activeJob.uiColor[2] or termProgG, activeJob.uiColor[3] or termProgB
        end

        -- Terminal text color should follow the same color as the processed track progress bar.
        local function jobBarColor(jobIdx)
            local s = STEMS[((jobIdx or 1) - 1) % #STEMS + 1]
            local c = s and s.color or {255, 255, 255}
            return { (c[1] or 255) / 255, (c[2] or 255) / 255, (c[3] or 255) / 255 }
        end
        local activeBar = activeJob and jobBarColor(activeJob.index or 1) or jobBarColor(1)
        if not utilityMode then
            if SETTINGS.darkMode then
                -- Keep dark mode readable first, then tint toward active bar color.
                termTextR = ((termTextR or 0.78) * 0.82) + (activeBar[1] * 0.18)
                termTextG = ((termTextG or 0.82) * 0.82) + (activeBar[2] * 0.18)
                termTextB = ((termTextB or 0.80) * 0.82) + (activeBar[3] * 0.18)
                termTextA = 1
            else
                -- Light mode: keep text readable, but nudge toward the active bar color.
                local ar, ag, ab = readableTerminalAccent(activeBar[1], activeBar[2], activeBar[3])
                termTextR = ((termTextR or 0.16) * 0.90) + (ar * 0.10)
                termTextG = ((termTextG or 0.17) * 0.90) + (ag * 0.10)
                termTextB = ((termTextB or 0.16) * 0.90) + (ab * 0.10)
                termTextA = 1
            end
        end
        termTextR, termTextG, termTextB, termTextA = termTextR or 0.78, termTextG or 0.78, termTextB or 0.78, termTextA or 1

        local termNow = uiNow()
        gfx.set(termBgR, termBgG, termBgB, termBgA)
        gfx.rect(displayX, displayY, displayW, displayH, 1)

        gfx.set(termBorderR, termBorderG, termBorderB, termBorderA)
        gfx.rect(displayX, displayY, displayW, displayH, 0)
        if SETTINGS.visualFX and not utilityMode then
            drawTerminalFx(displayX, displayY, displayW, displayH, termNow, termBorderR, termBorderG, termBorderB, termProgR, termProgG, termProgB)
        end

        gfx.set(termHeaderR, termHeaderG, termHeaderB, termHeaderA)
        gfx.rect(displayX, displayY, displayW, PS(18), 1)
        gfx.set(termHeaderTextR, termHeaderTextG, termHeaderTextB, termHeaderTextA)
        gfx.setfont(1, "Courier", PS(10), string.byte('b'))
        gfx.x = displayX + PS(5)
        gfx.y = displayY + PS(3)
        gfx.drawstr(T("terminal_output_title") or "DEMUCS OUTPUT")

        local function tailFileLines(filePath, maxLines)
            if not filePath or filePath == "" then return {} end
            local f = io.open(filePath, "r")
            if not f then return {} end
            local ring = {}
            local count = 0
            for line in f:lines() do
                count = count + 1
                local idx = ((count - 1) % maxLines) + 1
                ring[idx] = line
            end
            f:close()
            local res = {}
            local start = math.max(1, count - maxLines + 1)
            for i = start, count do
                local idx = ((i - 1) % maxLines) + 1
                table.insert(res, ring[idx])
            end
            return res
        end

        termNow = uiNow()
        if (termNow - (multiTrackQueue.lastTerminalUpdate or 0)) > UI_PACING.terminalReadInterval then
            multiTrackQueue.lastTerminalUpdate = termNow
            multiTrackQueue.terminalLines = {}

            -- Prefer active jobs; fall back to first job so terminal isn't empty.
            local maxJobsToShow = 6
            local shown = 0
            local anyActive = false

            for i, job in ipairs(multiTrackQueue.jobs) do
                if job.startTime and not job.done then
                    anyActive = true
                    shown = shown + 1
                    if shown > maxJobsToShow then break end
                    -- Prefix with [i] so per-track coloring can apply consistently
                    local trackPrefix = T("track_prefix") or "Track"
                    local header = string.format("[%d] ---- %s %d: %s ----", i, trackPrefix, i, tostring(job.trackName or ""))
                    table.insert(multiTrackQueue.terminalLines, header)
                    local lines = tailFileLines(job.stdoutFile, 60)
                    for _, line in ipairs(lines) do
                        local formatted = formatProgressLine(line, i)
                        if formatted then
                            table.insert(multiTrackQueue.terminalLines, formatted)
                        else
                            table.insert(multiTrackQueue.terminalLines, string.format("[%d] %s", i, line))
                        end
                    end
                end
            end

            if not anyActive then
                local first = multiTrackQueue.jobs[1]
                if first then
                    table.insert(multiTrackQueue.terminalLines, T("terminal_output_section_title") or "---- Output ----")
                    local lines = tailFileLines(first.stdoutFile, 120)
                    for _, line in ipairs(lines) do
                        local formatted = formatProgressLine(line, 1)
                        table.insert(multiTrackQueue.terminalLines, formatted or line)
                    end
                end
            end

            -- Hard cap so drawing stays cheap
            local cap = 500
            if #multiTrackQueue.terminalLines > cap then
                local trimmed = {}
                for i = #multiTrackQueue.terminalLines - cap + 1, #multiTrackQueue.terminalLines do
                    table.insert(trimmed, multiTrackQueue.terminalLines[i])
                end
                multiTrackQueue.terminalLines = trimmed
            end
        end

        local termContentY = displayY + PS(22)
        local termContentH = displayH - PS(30)
        local lineHeight = PS(12)
        local maxLines = math.floor(termContentH / lineHeight)
        local startLine = math.max(1, #(multiTrackQueue.terminalLines or {}) - maxLines + 1)
        gfx.setfont(1, "Courier", PS(9))

        local lineY = termContentY
        local progressNeedle = (T("progress_label") or "Progress") .. ":"
        for i = startLine, #(multiTrackQueue.terminalLines or {}) do
            if lineY < displayY + displayH - PS(5) then
                local line = multiTrackQueue.terminalLines[i] or ""
                if #line > 100 then line = line:sub(1, 97) .. ".." end
                -- Per-track tint (line prefixes are like: [3] ...). Headers use the same track tint.
                local lineTrackIdx = tonumber(line:match("^%[(%d+)%]"))
                local lineAccent = (lineTrackIdx and jobBarColor(lineTrackIdx)) or nil

                if line:match("error") or line:match("Error") or line:match("ERROR") then
                    gfx.set(termErrR, termErrG, termErrB, termErrA)
                elseif line:match("warning") or line:match("Warning") then
                    gfx.set(termWarnR, termWarnG, termWarnB, termWarnA)
                elseif line:match("PROGRESS") or line:find(progressNeedle, 1, true) then
                    gfx.set(termProgR, termProgG, termProgB, termProgA)
                elseif line:match("Separating") or line:match("100%%") then
                    gfx.set(termOkR, termOkG, termOkB, termOkA)
                else
                    if (not utilityMode) and lineTrackIdx and lineAccent and line:match("%-%-%-%-") then
                        -- Track header line
                        local ar, ag, ab = readableTerminalAccent(lineAccent[1] or termTextR, lineAccent[2] or termTextG, lineAccent[3] or termTextB)
                        gfx.set(ar, ag, ab, 0.98)
                    elseif (not utilityMode) and lineAccent and SETTINGS.darkMode then
                        -- Dark mode: tint normal lines toward track color
                        local ar, ag, ab = lineAccent[1] or termTextR, lineAccent[2] or termTextG, lineAccent[3] or termTextB
                        gfx.set((termTextR * 0.35) + (ar * 0.65), (termTextG * 0.35) + (ag * 0.65), (termTextB * 0.35) + (ab * 0.65), termTextA)
                    elseif (not utilityMode) and lineAccent and not SETTINGS.darkMode then
                        -- Light mode: keep it readable; use a subtle tint
                        local ar, ag, ab = readableTerminalAccent(lineAccent[1] or 0.2, lineAccent[2] or 0.2, lineAccent[3] or 0.2)
                        gfx.set((termTextR * 0.8) + (ar * 0.2), (termTextG * 0.8) + (ag * 0.2), (termTextB * 0.8) + (ab * 0.2), termTextA)
                    else
                        gfx.set(termTextR, termTextG, termTextB, termTextA)
                    end
                end
                gfx.x = displayX + PS(5)
                gfx.y = lineY
                gfx.drawstr(line)
                lineY = lineY + lineHeight
            end
        end

        -- Blinking cursor
        if (not utilityMode) and math.floor(termNow * 2) % 2 == 0 then
            gfx.set(termOkR, termOkG, termOkB, 1)
            gfx.x = displayX + PS(5)
            gfx.y = math.min(lineY, displayY + displayH - lineHeight - PS(5))
            gfx.drawstr("_")
        end

        -- Terminal hint
        gfx.set(termDimR, termDimG, termDimB, termDimA)
        gfx.setfont(1, "Courier", PS(8))
        local termHint = utilityMode and "Click >_ to return to progress" or (T("terminal_hint_return_to_art") or "Click >_ to return to art")
        local termHintW = gfx.measurestr(termHint)
        gfx.x = displayX + (displayW - termHintW) / 2
        gfx.y = displayY + displayH - PS(16)
        gfx.drawstr(termHint)

    else
        if multiTrackQueue.showTerminal then
            -- Window is too short: show a clear hint instead of "green toggle but nothing".
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.9)
            gfx.setfont(1, "Arial", PS(9))
            local msg = T("resize_window_for_terminal") or "Tip: resize this window taller to view Terminal"
            local msgW = gfx.measurestr(msg)
            gfx.x = math.max(PS(10), (w - msgW) / 2)
            gfx.y = nerdBtnY + nerdBtnH + PS(2)
            gfx.drawstr(msg)
        end
        local trackY = listAreaY
        local defaultTrackSpacing = PS(30)
        local minTrackSpacing = PS(22)
        local trackSpacing = defaultTrackSpacing
        if numJobs > 0 then
            trackSpacing = math.max(minTrackSpacing, math.floor(listAreaH / numJobs))
        end

        local visibleStart = 1
        local visibleEnd = numJobs
        local scrollNeeded = false
        local visibleRows = numJobs
        local scrollTrackX, scrollTrackY, scrollTrackH, thumbY, thumbH
        if (numJobs * trackSpacing) > listAreaH then
            scrollNeeded = true
            trackSpacing = minTrackSpacing
            visibleRows = math.max(1, math.floor(listAreaH / trackSpacing))
            local maxScroll = math.max(0, numJobs - visibleRows)
            local listHover = mx >= displayX and mx <= displayX + displayW and my >= listAreaY and my <= listAreaY + listAreaH
            scrollTrackX = displayX + displayW - PS(5)
            scrollTrackY = listAreaY
            scrollTrackH = listAreaH
            thumbH = math.max(PS(18), math.floor(scrollTrackH * (visibleRows / math.max(1, numJobs))))
            local thumbTravel = math.max(0, scrollTrackH - thumbH)
            thumbY = scrollTrackY + math.floor(thumbTravel * ((multiTrackQueue.listScroll or 0) / math.max(1, maxScroll)))
            local scrollHover = mx >= scrollTrackX - PS(6) and mx <= scrollTrackX + PS(8) and my >= scrollTrackY and my <= scrollTrackY + scrollTrackH

            local wheelDelta = tonumber(mouseWheel) or 0
            if (listHover or scrollHover) and wheelDelta ~= 0 then
                local step = math.max(1, math.floor(math.abs(wheelDelta) / 120))
                local delta = (wheelDelta > 0) and -step or step
                multiTrackQueue.listScroll = math.max(0, math.min(maxScroll, (multiTrackQueue.listScroll or 0) + delta))
                gfx.mouse_wheel = 0
            end

            if scrollHover and mouseDown and not multiTrackQueue.wasMouseDown then
                if my >= thumbY and my <= thumbY + thumbH then
                    multiTrackQueue.listScrollDragging = true
                    multiTrackQueue.listScrollDragOffset = my - thumbY
                else
                    local thumbCenter = thumbY + (thumbH / 2)
                    local page = math.max(1, visibleRows - 1)
                    if my < thumbCenter then
                        multiTrackQueue.listScroll = math.max(0, (multiTrackQueue.listScroll or 0) - page)
                    else
                        multiTrackQueue.listScroll = math.min(maxScroll, (multiTrackQueue.listScroll or 0) + page)
                    end
                end
            end

            if multiTrackQueue.listScrollDragging then
                if mouseDown then
                    local thumbTravelNow = math.max(0, scrollTrackH - thumbH)
                    local rel = my - scrollTrackY - (multiTrackQueue.listScrollDragOffset or 0)
                    local thumbPos = math.max(0, math.min(thumbTravelNow, rel))
                    local ratio = (thumbTravelNow > 0) and (thumbPos / thumbTravelNow) or 0
                    multiTrackQueue.listScroll = math.floor((maxScroll * ratio) + 0.5)
                else
                    multiTrackQueue.listScrollDragging = false
                    multiTrackQueue.listScrollDragOffset = 0
                end
            end

            multiTrackQueue.listScroll = math.max(0, math.min(maxScroll, multiTrackQueue.listScroll or 0))
            visibleStart = 1 + (multiTrackQueue.listScroll or 0)
            visibleEnd = math.min(numJobs, visibleStart + visibleRows - 1)
        else
            multiTrackQueue.listScroll = 0
            multiTrackQueue.listScrollDragging = false
            multiTrackQueue.listScrollDragOffset = 0
        end

        gfx.setfont(1, "Arial", PS(10))
        for i = visibleStart, visibleEnd do
            local job = multiTrackQueue.jobs[i]
            local rowIdx = i - visibleStart
            local yPos = trackY + rowIdx * trackSpacing

            -- Track name
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = barX
            gfx.y = yPos
            local displayName = job.trackName
            if #displayName > 20 then displayName = displayName:sub(1, 17) .. ".." end
            gfx.drawstr(displayName)

            -- Track progress bar
            local tBarX = barX + PS(120)
            local tBarW = barW - PS(150)
            local tBarH = math.max(PS(14), math.min(PS(18), trackSpacing - PS(6)))

            -- Progress bar background
            local trackBarRadius = getThemeRadius(PS, 3, math.floor(tBarH / 2))
            drawThemeShadow(tBarX, yPos, tBarW, tBarH, trackBarRadius, 0.48, "process")
            gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 1)
            gfx.rect(tBarX, yPos, tBarW, tBarH, 1)
            gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
            gfx.rect(tBarX, yPos, tBarW, tBarH, 0)
            drawLightSurfaceFinish(tBarX + 1, yPos + 1, math.max(1, tBarW - 2), math.max(1, tBarH - 2), math.max(0, trackBarRadius - 1), "process", 0.95)

            -- Fill
            local tFillW = math.floor(tBarW * (job.percent or 0) / 100)
            if tFillW > 0 then
                if utilityMode then
                    local ur, ug, ub = utilityProgressColor()
                    gfx.set(ur, ug, ub, 0.92)
                else
                    -- Color based on stem being processed
                    local stemIdx = (i - 1) % #STEMS + 1
                    local stemColor = STEMS[stemIdx].color
                    gfx.set(stemColor[1]/255, stemColor[2]/255, stemColor[3]/255, 0.85)
                end
                gfx.rect(tBarX + 1, yPos + 1, tFillW - 2, tBarH - 2, 1)
            end

            -- Stage text inside progress bar
            if not job.done and job.stage and job.stage ~= "" then
                gfx.setfont(1, "Arial", PS(9))
                local stageText = localizeProgressStagePrefix(job.stage)
                if stageText == "Waiting.." or stageText == "Waiting..." then
                    stageText = T("waiting") or stageText
                elseif stageText == "Starting.." or stageText == "Starting..." then
                    stageText = T("starting") or stageText
                end
                local stageX = tBarX + PS(5)
                local stageY = yPos + PS(3)
                stageText = stageText:gsub("Direct ML", "DML")
                stageText = stageText:gsub("DirectML", "DML")
                local fittedStageText = fitTextToBox(stageText, tBarW - PS(10), PS(9), PS(9))
                drawProgressText(fittedStageText, stageX, stageY, 0.95)
            end

            -- Done checkmark or percentage
            gfx.setfont(1, "Arial", PS(10))
            if job.done then
                local isWaiting = (job.stage == "Waiting for import")
                if isWaiting then
                    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.7)
                else
                    gfx.set(0.3, 0.75, 0.4, 1)
                end
                gfx.x = tBarX + tBarW + PS(8)
                gfx.y = yPos + PS(2)
                gfx.drawstr(isWaiting and (T("progress_waiting") or "Waiting") or (T("mt_done_label") or "Done"))
            else
                gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
                gfx.x = tBarX + tBarW + PS(8)
                gfx.y = yPos + PS(2)
                gfx.drawstr(string.format("%d%%", job.percent or 0))
            end
        end

        if scrollNeeded then
            local maxScroll = math.max(1, numJobs - visibleRows)
            local thumbTravel = math.max(0, scrollTrackH - thumbH)
            thumbY = scrollTrackY + math.floor(thumbTravel * ((multiTrackQueue.listScroll or 0) / maxScroll))

            gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.35)
            gfx.rect(scrollTrackX, scrollTrackY, PS(3), scrollTrackH, 1)
            gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 0.9)
            gfx.rect(scrollTrackX, thumbY, PS(3), thumbH, 1)

            gfx.setfont(1, "Arial", PS(8))
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.9)
            local scrollWheelHint = T("scroll_wheel_hint") or "wheel"
            local scrollLabel = string.format("%d-%d/%d  %s", visibleStart, visibleEnd, numJobs, scrollWheelHint)
            local scrollLabelW = gfx.measurestr(scrollLabel)
            gfx.x = math.max(barX, displayX + displayW - scrollLabelW - PS(10))
            gfx.y = infoY - PS(12)
            gfx.drawstr(scrollLabel)
        end

        -- Current processing info (positioned below progress bars)
        infoY = listAreaY + listAreaH + listGap
    end

    local globalElapsed = os.time() - (multiTrackQueue.globalStartTime or os.time())

    -- Calculate stats (used for info block and bottom ETA)
    local completedJobs = 0
    local activeJobs = 0
    local totalAudioDur = 0
    local completedAudioDur = 0
    local activeJob = nil

    for _, job in ipairs(multiTrackQueue.jobs) do
        totalAudioDur = totalAudioDur + (job.audioDuration or 0)
        if job.done then
            completedJobs = completedJobs + 1
            completedAudioDur = completedAudioDur + (job.audioDuration or 0)
        elseif job.startTime then
            activeJobs = activeJobs + 1
            if not activeJob then activeJob = job end
            -- Estimate completed audio based on progress %
            completedAudioDur = completedAudioDur + (job.audioDuration or 0) * (job.percent or 0) / 100
        end
    end

    -- Calculate processing speed (realtime factor)
    local realtimeFactor = 0
    if globalElapsed > 5 and completedAudioDur > 0 then
        realtimeFactor = completedAudioDur / globalElapsed
    end

    -- Estimate ETA
    local eta = 0
    local remainingAudio = totalAudioDur - completedAudioDur
    if realtimeFactor > 0 then
        eta = remainingAudio / realtimeFactor
    elseif globalElapsed > 0 and overallProgress > 5 then
        -- Fallback: estimate from progress %
        local totalEstimate = globalElapsed * 100 / overallProgress
        eta = totalEstimate - globalElapsed
    end

    -- Keep the UI minimal in terminal view (like the single-track Processing window).
    local summaryLine1, summaryLine2 = nil, nil
    if not terminalViewActive then
        local function trSafeProgress(key, fallback)
            local v = T(key)
            if not v or v == "" or v == key or v == key:gsub("_", " ") then
                return fallback
            end
            return v
        end

        -- Count expected stems
        local selectedStemCount = 0
        for _, stem in ipairs(STEMS) do
            if stem.selected then selectedStemCount = selectedStemCount + 1 end
        end
        local expectedStems = multiTrackQueue.expectedStemCount
        if not expectedStems or expectedStems <= 0 then
            expectedStems = numJobs * selectedStemCount
        end

        -- Show the duration of the current/last selection as the reference point, not the cumulative batch time
        local displayTotalDur = numJobs > 0 and (multiTrackQueue.jobs[1].audioDuration or 0) or totalAudioDur
        local processedItemTotal = anyPerItem and ((multiTrackQueue.detectedItemCount or 0) > 0 and multiTrackQueue.detectedItemCount or numJobs) or numJobs
        local queuedItemCount = anyPerItem and (multiTrackQueue.queuedItemCount or numJobs) or numJobs
        local displayProcessedAudio = (totalAudioDur > 0 and displayTotalDur > 0) and (completedAudioDur / (totalAudioDur / displayTotalDur)) or 0
        local itemUnit = (processedItemTotal == 1) and (T("footer_item") or "item") or (T("footer_items") or "items")
        local trackUnit = (numJobs == 1) and (T("footer_track") or "track") or (T("footer_tracks") or "tracks")
        local stemUnit = (expectedStems == 1) and (T("stem") or "stem") or (T("stems") or "stems")

        local activeJobs = 0
        local waitingJobs = 0
        for _, job in ipairs(multiTrackQueue.jobs or {}) do
            if job.done then
                -- completedJobs already tracked elsewhere
            elseif job.startTime then
                activeJobs = activeJobs + 1
            else
                waitingJobs = waitingJobs + 1
            end
        end

        local summaryDoneCount = anyPerItem and processedItemTotal or numJobs
        local summaryUnit = anyPerItem and itemUnit or trackUnit
        local tpl = trSafeProgress("mt_footer_summary_concurrency", "%d/%d %s | Active %d | Waiting %d | Audio %.1fs/%.1fs | %d %s")
        summaryLine1 = string.format(
            tpl,
            completedJobs,
            summaryDoneCount,
            summaryUnit,
            activeJobs,
            waitingJobs,
            displayProcessedAudio,
            displayTotalDur,
            expectedStems,
            stemUnit
        )

        if realtimeFactor > 0 then
            local speedFmt = trSafeProgress("mt_footer_speed_line", "Speed %.2fx realtime")
            summaryLine2 = string.format(speedFmt, realtimeFactor)
        else
            summaryLine2 = T("mt_speed_calc") or "Speed calculating.."
        end
        if eta > 0 then
            local etaMins = math.floor(eta / 60)
            local etaSecs = math.floor(eta % 60)
            local etaFmt = trSafeProgress("mt_footer_eta_suffix", " | ETA %d:%02d")
            summaryLine2 = summaryLine2 .. string.format(etaFmt, etaMins, etaSecs)
        end
    end

    -- (Terminal rendering moved into the shared display area above, so it works in both Seq and Par)

    -- Bottom line: Total elapsed, model, segment and cancel hint
    local statusFontSize = PS(10)
    local statusPadX = PS(10)
    local statusBlockPadY = PS(10)
    local statusBlockAlpha = 0.8
    local statusBlockBorderAlpha = 0.85
    gfx.setfont(1, "Arial", statusFontSize)
    local statusLineH = gfx.texth
    local hasSummaryFooter = (summaryLine1 and summaryLine1 ~= "") or (summaryLine2 and summaryLine2 ~= "")
    local statusRowGap = hasSummaryFooter and PS(4) or 0
    local statusBlockH = statusLineH * (hasSummaryFooter and 2 or 1) + statusBlockPadY * 2 + statusRowGap
    local statusBlockY = h - statusBlockH
    local function setFooterTooltip(x, y, ww, hh, text)
        if SETTINGS and SETTINGS.tooltips == false then return end
        if not text or text == "" then return end
        if mx >= x and mx <= x + ww and my >= y and my <= y + hh then
            tooltipText = text
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
        end
    end
    local totalMins = math.floor(globalElapsed / 60)
    local totalSecs = math.floor(globalElapsed % 60)
    local mtTime = T("mt_time") or "Time"
    local mtCancel = T("mt_cancel") or "ESC=cancel"
    local cancelBtnText = progressUiLabel("progress_cancel_button", T("cancel") or "Cancel")
    local etaText = ""
    if eta and eta > 0 then
        local etaMins = math.floor(eta / 60)
        local etaSecs = math.floor(eta % 60)
        local etaLabel = T("eta_label") or "ETA:"
        etaText = string.format(" | %s ±%d:%02d", tostring(etaLabel), etaMins, etaSecs)
    end

    local runModel = effectiveRunModel()
    local modelDisplay = (runModel == "htdemucs_ft")
        and (T("model_label_quality") or "Quality")
        or ((runModel == "htdemucs_6s") and (T("model_label_6stem") or "6-Stem") or (T("model_label_fast") or "Fast"))
    local modeDisplay = multiTrackQueue.sequentialMode and (T("sequential") or "Sequential") or (T("parallel") or "Parallel")
    if (not multiTrackQueue.sequentialMode) and multiTrackQueue.parallelJobLimit then
        local capLabel = T("mt_parallel_cap") or "Parallel cap %d"
        modeDisplay = string.format(capLabel, multiTrackQueue.parallelJobLimit)
    end
    local leftParts = {
        string.format("%s: %d:%02d%s", mtTime, totalMins, totalSecs, etaText),
        modelDisplay,
        modeDisplay,
    }
    local rightParts = {}
    if activeJob then
        local jobElapsed = os.time() - (activeJob.startTime or os.time())
        local jobMins = math.floor(jobElapsed / 60)
        local jobSecs = jobElapsed % 60
        local currentLabel = activeJob.trackName or "?"
        if activeJob.perItem and activeJob.sourceTrackName and activeJob.sourceItemDisplayName then
            currentLabel = activeJob.sourceTrackName .. " - " .. activeJob.sourceItemDisplayName
        end
        local audioDurStr = activeJob.audioDuration and string.format("%.1fs", activeJob.audioDuration) or "?"
        rightParts[#rightParts + 1] = string.format("%s (%s, %d:%02d)", currentLabel, audioDurStr, jobMins, jobSecs)
    end
    rightParts[#rightParts + 1] = mtCancel
    local leftText = table.concat(leftParts, " | ")
    local rightText = table.concat(rightParts, " | ")

    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], statusBlockAlpha)
    gfx.rect(0, statusBlockY, gfx.w, statusBlockH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], statusBlockBorderAlpha)
    gfx.rect(0, statusBlockY, gfx.w, statusBlockH, 0)

    -- Explicit cancel button in multi-track processing window (same behavior as ESC / window close).
    local cancelBtnH = PS(28)
    local cancelBtnW = math.max(PS(96), gfx.measurestr(cancelBtnText) + PS(26))
    local cancelBtnX = w - PS(12) - cancelBtnW
    local cancelBtnY = statusBlockY - cancelBtnH - PS(10)
    local cancelHover = mx >= cancelBtnX and mx <= cancelBtnX + cancelBtnW and my >= cancelBtnY and my <= cancelBtnY + cancelBtnH
    local cancelFill = cancelHover and {0.85, 0.24, 0.24} or {0.72, 0.20, 0.20}
    drawThemeSurfaceBox(cancelBtnX, cancelBtnY, cancelBtnW, cancelBtnH, cancelFill, THEME.border, 1, 0.98, getThemeRadius(PS, math.floor(cancelBtnH / 2), math.floor(cancelBtnH / 2)), getThemeBorderWeight(PS, 1), 0.35, "button")
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(12), string.byte('b'))
    local cancelTextW = gfx.measurestr(cancelBtnText)
    gfx.x = cancelBtnX + (cancelBtnW - cancelTextW) / 2
    gfx.y = cancelBtnY + math.floor((cancelBtnH - gfx.texth) / 2)
    gfx.drawstr(cancelBtnText)
    if cancelHover then
        GUI.uiClickedThisFrame = true
        tooltipText = progressUiLabel("progress_cancel_tooltip", progressUiLabel("tooltip_cancel_processing", "Cancel separation"))
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if mouseDown and not multiTrackQueue.wasMouseDown then
            cancelClicked = true
        end
    end

    local availableW = gfx.w - statusPadX * 2
    local splitGap = PS(16)
    local leftW = math.max(PS(180), math.floor((availableW - splitGap) * 0.48))
    local rightW = math.max(PS(180), availableW - leftW - splitGap)
    local row1Y = statusBlockY + statusBlockPadY
    local row2Y = row1Y + statusLineH + statusRowGap

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local leftLabel, _ = fitTextToBox(leftText, leftW, statusFontSize, statusFontSize)
    local rightLabel, rightTw = fitTextToBox(rightText, rightW, statusFontSize, statusFontSize)
    gfx.x = statusPadX
    gfx.y = row1Y
    gfx.drawstr(leftLabel)
    setFooterTooltip(statusPadX, row1Y, leftW, statusLineH, T("tooltip_footer_selected") or "Shows aggregate batch processing state.")
    gfx.x = gfx.w - statusPadX - rightTw
    gfx.y = row1Y
    gfx.drawstr(rightLabel)
    setFooterTooltip(gfx.w - statusPadX - rightW, row1Y, rightW, statusLineH, T("tooltip_footer_output") or "Shows active batch target and control hint.")

    if hasSummaryFooter then
        local summaryFontSize = PS(9)
        gfx.setfont(1, "Arial", summaryFontSize)
        local summaryLeft = summaryLine1 or ""
        local summaryRight = summaryLine2 or ""
        local summaryLeftLabel = fitTextToBox(summaryLeft, leftW, summaryFontSize, summaryFontSize)
        local summaryRightLabel, summaryRightTw = fitTextToBox(summaryRight, rightW, summaryFontSize, summaryFontSize)
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.78)
        gfx.x = statusPadX
        gfx.y = row2Y
        gfx.drawstr(summaryLeftLabel)
        setFooterTooltip(statusPadX, row2Y, leftW, statusLineH, T("tooltip_footer_location") or "Shows batch summary and throughput.")
        if summaryRight ~= "" then
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.68)
            gfx.x = gfx.w - statusPadX - summaryRightTw
            gfx.y = row2Y
            gfx.drawstr(summaryRightLabel)
            setFooterTooltip(gfx.w - statusPadX - rightW, row2Y, rightW, statusLineH, T("tooltip_footer_location") or "Shows batch summary and throughput.")
        end
    end


    -- flarkAUDIO logo at top (translucent) - skipped in utility mode
    if not utilityMode then
        gfx.setfont(1, "Arial", PS(10))
        local flarkPart = "flark"
        local flarkPartW = gfx.measurestr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        local audioPart = "AUDIO"
        local audioPartW = gfx.measurestr(audioPart)
        local totalLogoW = flarkPartW + audioPartW
        local logoStartX = (w - totalLogoW) / 2
        gfx.set(1.0, 0.5, 0.1, 0.5)
        gfx.setfont(1, "Arial", PS(10))
        gfx.x = logoStartX
        gfx.y = PS(3)
        gfx.drawstr(flarkPart)
        gfx.setfont(1, "Arial", PS(10), string.byte('b'))
        gfx.x = logoStartX + flarkPartW
        gfx.y = PS(3)
        gfx.drawstr(audioPart)
    end

    -- === DRAW TOOLTIP (on top of everything, with STEM colors) ===
    if tooltipText then
        gfx.setfont(1, "Arial", PS(11))
        local padding = PS(8)
        local lineH = PS(14)
        local maxTextW = math.min(w * 0.62, PS(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    -- Track mouse state for next frame
    multiTrackQueue.wasMouseDown = mouseDown
    multiTrackQueue.wasRightMouseDown = rightMouseDown

    gfx.update()

    -- Allow new art via click/space only in the normal visual theme.
    local char = gfx.getchar()
    if not utilityMode then
        UI_Window.handleArtAdvance(multiTrackQueue, mouseDown, char)
    end

    -- Check for cancel
    if char == -1 or char == 27 or cancelClicked then
        return "cancel"
    end

    return nil
end

-- Multi-track progress window loop
function multiTrackProgressLoop()
    local loopNow = uiNow()

    if loopNow >= (multiTrackQueue.nextPollAt or 0) then
        multiTrackQueue.nextPollAt = loopNow + UI_PACING.multiTrackPollInterval
        _sep.updateAllJobsProgress()
    end

    local result = nil
    if loopNow >= (multiTrackQueue.nextFrameAt or 0) then
        multiTrackQueue.nextFrameAt = loopNow + pacingFrameInterval("multiTrackFrameInterval", "multiTrackFrameIntervalFx")
        result = drawMultiTrackProgressWindow()
    end

    if result == "cancel" then
        -- Remember any size/position changes made during processing
        captureWindowGeometry(multiTrackQueue.windowTitle or getMultiTrackWindowTitle())
        saveSettings()

        gfx.quit()
        multiTrackQueue.active = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Preserve best-effort diagnostics before stopping workers; files may be partial on cancel.
        if multiTrackQueue.jobs then
            for _, job in ipairs(multiTrackQueue.jobs) do
                if job.trackDir and job.trackDir ~= "" then
                    SW_LOG.preserveDiagnosticsForRun(job.trackDir, { reason = "user_cancel" })
                end
            end
        end

        -- Best-effort kill of all running workers so cancel is immediate and doesn't slow next run
        if multiTrackQueue.jobs then
            for _, job in ipairs(multiTrackQueue.jobs) do
                HELPERS.killProcessFromPidFile(job.pidFile)
            end
        end
        if multiTrackQueue.jobs then
            for _, job in ipairs(multiTrackQueue.jobs) do
                if job.trackDir and job.trackDir ~= "" then
                    SW_LOG.preserveDiagnosticsForRun(job.trackDir, { reason = "user_cancel" })
                end
            end
        end

        showMessage("Cancelled", UI_PROGRESS.progressUiLabel("progress_cancelled_status", "Cancelled"), "info", true)
        return
    end

    if _sep.allJobsDone() then
        -- Remember any size/position changes made during processing
        captureWindowGeometry(multiTrackQueue.windowTitle or getMultiTrackWindowTitle())
        saveSettings()

        gfx.quit()
        -- Process all results
        _sep.processAllStemsResult()
        return
    end

    reaper.defer(multiTrackProgressLoop)
end

-- Show multi-track progress window
_sep.showMultiTrackProgressWindow = function()
    -- Keep processing settings unchanged while jobs are running.
    updateTheme()

    captureWindowGeometry(SCRIPT_NAME)
    GUI.snapshotMainGeometry()
    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    multiTrackQueue.listScroll = 0
    multiTrackQueue.nextFrameAt = 0
    multiTrackQueue.nextPollAt = 0
    multiTrackQueue.windowTitle = getMultiTrackWindowTitle()
    gfx.init(multiTrackQueue.windowTitle, winW, winH, 0, winX, winY)
    if OS == "Windows" then
        multiTrackProgressLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(multiTrackProgressLoop)
    end
end

-- isProcessingActive is declared near the top of the file to avoid accidentally
-- creating separate global/local variables in different parts of the script.

-- Process all stems after parallel jobs complete
_sep.processAllStemsResult = function()
    SW_LOG.logExecResult("timing:finalize_start multi", nil, "")
    reaper.Undo_BeginBlock()
    for _, job in ipairs(multiTrackQueue.jobs or {}) do
        if job and job.trackDir and job.trackDir ~= "" then
            SW_LOG.persistRunDiagnostics(job.trackDir)
        end
    end

    local actionCount = 0
    local actionData = nil

    -- Skip item-level processing if track-level cleanup is set (tracks handled after stems are created)
    -- Also skip muteSelection/deleteSelection for in-place + time selection mode
    -- (the selection portion will be replaced by stems, splitting is done there)
    local applyCleanup = SETTINGS.createNewTracks
    local skipSelectionProcessing = timeSelectionMode and not SETTINGS.createNewTracks
    local hasCleanupTimeSel = (timeSelectionStart and timeSelectionEnd and timeSelectionEnd > timeSelectionStart) or false

    local function collectUniqueJobItems()
        local items = {}
        local seen = {}
        for _, job in ipairs(multiTrackQueue.jobs or {}) do
            local list = job.sourceItems or (job.sourceItem and { job.sourceItem }) or {}
            for _, item in ipairs(list) do
                if item and reaper.ValidatePtr(item, "MediaItem*") then
                    local key = tostring(item)
                    if not seen[key] then
                        seen[key] = true
                        items[#items + 1] = item
                    end
                end
            end
        end
        return items
    end
    local allItems = collectUniqueJobItems()

    -- Now create stems for each job
    local totalStemsCreated = 0
    local sourceTracksWithStems = {} -- track ptr -> true (only count tracks that actually received stems)
    local sourceItemsWithStems = {} -- item ptr -> true (only count items that actually received stems)
    local trackNames = {}

    debugLog("=== processAllStemsResult: Creating stem tracks ===")
    debugLog("Number of jobs: " .. #multiTrackQueue.jobs)
    debugLog("itemPos: " .. tostring(itemPos) .. ", itemLen: " .. tostring(itemLen))
    debugLog("createNewTracks: " .. tostring(SETTINGS.createNewTracks))

    local is6Stem = isEffectiveRun6Stem()

    -- Track insertion cursor for multi-job imports. Without this, each per-item
    -- job inserts directly below the same source track, so later items push
    -- earlier outputs downward and the visible order becomes reversed.
    local importInsertCursorByTrack = {}
    local function getImportInsertIndexForJob(job)
        local tr = job and job.track or nil
        if not tr or not reaper.ValidatePtr(tr, "MediaTrack*") then
            return nil
        end
        local key = tostring(tr)
        if importInsertCursorByTrack[key] == nil then
            importInsertCursorByTrack[key] = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
        end
        return importInsertCursorByTrack[key]
    end
    local function advanceImportInsertCursorForJob(job, insertedTrackCount)
        insertedTrackCount = tonumber(insertedTrackCount) or 0
        local tr = job and job.track or nil
        if insertedTrackCount <= 0 or not tr or not reaper.ValidatePtr(tr, "MediaTrack*") then
            return
        end
        local key = tostring(tr)
        if importInsertCursorByTrack[key] ~= nil then
            importInsertCursorByTrack[key] = importInsertCursorByTrack[key] + insertedTrackCount
        end
    end

    -- Use a stable selection range for item placement (avoid any stale globals).
    local globalSelPos = itemPos
    local globalSelLen = itemLen
    if timeSelectionMode and timeSelectionStart and timeSelectionEnd and timeSelectionEnd > timeSelectionStart then
        globalSelPos = timeSelectionStart
        globalSelLen = timeSelectionEnd - timeSelectionStart
    end

    -- Build OutputPlan / ImportPlan skeleton.
    -- Grouping is a UI setting, but only applied for New Tracks import routing.
    local outputGrouping = normalizeOutputGrouping(SETTINGS.outputGrouping)
    if not SETTINGS.createNewTracks then
        outputGrouping = "per_item"
    end
    local outputPlan = {
        grouping = outputGrouping,
        destination = SETTINGS.createNewTracks and "new_tracks" or "in_place",
        imports = {}
    }

    for jobIdx, job in ipairs(multiTrackQueue.jobs) do
        debugLog("Job " .. jobIdx .. ": trackDir=" .. tostring(job.trackDir))
        job.hadImportedStems = false
        job.importedStemPaths = nil
        -- Find stem files in job directory
        local stems = {}
        local selectedCount = 0
        local foundCount = 0
        for _, stem in ipairs(STEMS) do
            -- Skip 6-stem-only stems if not using 6-stem model
            local stemApplies = stem.selected and (not stem.sixStemOnly or is6Stem)
            if stemApplies then
                selectedCount = selectedCount + 1
                local stemPath = job.trackDir .. PATH_SEP .. stem.name:lower() .. ".wav"
                local f = io.open(stemPath, "r")
                if f then
                    f:close()
                    stems[stem.name:lower()] = stemPath
                    foundCount = foundCount + 1
                    debugLog("  Found stem: " .. stem.name:lower() .. " at " .. stemPath)
                else
                    debugLog("  MISSING stem: " .. stem.name:lower() .. " at " .. stemPath)
                end
            end
        end
        debugLog("  Selected stems: " .. selectedCount .. ", Found: " .. foundCount)
        if foundCount > 0 and not job.outputDetected then
            job.outputDetected = true
            SW_LOG.logExecResult(
                "timing:output_detected job=" .. tostring(job.index) .. " found=" .. tostring(foundCount) .. " dir=" .. tostring(job.trackDir),
                nil,
                ""
            )
        end

        local importPlan = {
            job = job,
            stems = stems,
            foundCount = foundCount,
            hasStems = false
        }

        -- Create stems based on output mode
        if next(stems) then
            local namingTrack = job.sourceTrackName or job.trackName or "Track"
            local namingItem = job.sourceItemName or job.sourceItemDisplayName or namingTrack
            stems = HELPERS.finalizeStemFiles(stems, namingTrack, namingItem)
            job.importedStemPaths = stems
            importPlan.stems = stems
            importPlan.hasStems = true

            if outputPlan.destination == "new_tracks" then
                -- New tracks mode: create separate tracks for each stem
                -- Use per-job selection range: if time selection exists, use it; otherwise use the job's source item position/length
                local jobSelPos = globalSelPos
                local jobSelLen = globalSelLen
                if job.perItem and job.selPos and job.selLen and job.selLen > 0 then
                    -- Per-item time-selection jobs already captured their exact overlap slice during extraction.
                    -- Reuse that range here so later items don't get rebuilt from the full global selection.
                    jobSelPos = job.selPos
                    jobSelLen = job.selLen
                    debugLog("  Per-item job range: using job sel pos=" .. jobSelPos .. ", len=" .. jobSelLen)
                elseif not timeSelectionMode and job.sourceItem and reaper.ValidatePtr(job.sourceItem, "MediaItem*") then
                    -- No time selection: use the source item's position/length for this job
                    jobSelPos = reaper.GetMediaItemInfo_Value(job.sourceItem, "D_POSITION")
                    jobSelLen = reaper.GetMediaItemInfo_Value(job.sourceItem, "D_LENGTH")
                    debugLog("  No time selection: using source item pos=" .. jobSelPos .. ", len=" .. jobSelLen)
                elseif timeSelectionMode then
                    debugLog("  Time selection mode: using global sel pos=" .. jobSelPos .. ", len=" .. jobSelLen)
                end

                local itemsOverride = nil
                if job and job.perItem and job.sourceItems then
                    itemsOverride = {}
                    for _, it in ipairs(job.sourceItems) do
                        itemsOverride[#itemsOverride + 1] = {
                            item = it,
                            sourceItemName = job.sourceItemName,
                            sourceItemDisplayName = job.sourceItemDisplayName,
                        }
                    end
                end
                local useItemNameForTrack = (job and job.perItem) or false

                importPlan.jobSelPos = jobSelPos
                importPlan.jobSelLen = jobSelLen
                importPlan.itemsOverride = itemsOverride
                importPlan.useItemNameForTrack = useItemNameForTrack
            end
        end
        table.insert(outputPlan.imports, importPlan)
    end

    local function getPlanTrackSortTuple(importPlan)
        local tr = importPlan and importPlan.job and importPlan.job.track or nil
        local idx = tr and reaper.ValidatePtr(tr, "MediaTrack*")
            and math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
            or 999999
        local pos = tonumber(importPlan and importPlan.jobSelPos) or 0
        local itemKey = importPlan and importPlan.job and importPlan.job.sourceItem and tostring(importPlan.job.sourceItem) or ""
        return idx, pos, itemKey
    end

    if outputPlan.destination == "new_tracks" and outputPlan.grouping == "source_track" then
        table.sort(outputPlan.imports, function(a, b)
            local ai, ap, ak = getPlanTrackSortTuple(a)
            local bi, bp, bk = getPlanTrackSortTuple(b)
            if ai ~= bi then return ai < bi end
            if ap ~= bp then return ap < bp end
            return ak < bk
        end)
    end

    local sharedTargetsByTrack = {}
    local function getJobTrackKey(job)
        local tr = job and job.track or nil
        if not (tr and reaper.ValidatePtr(tr, "MediaTrack*")) then return nil end
        return tostring(tr)
    end
    local function getTrackDisplayName(job)
        local tr = job and job.track or nil
        if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
            local _, tn = reaper.GetTrackName(tr)
            if tn and tn ~= "" then return tn end
        end
        return (job and (job.sourceTrackName or job.trackName)) or "Track"
    end
    local function buildSharedTargetsForTrack(job, stems, preferredInsertIndex)
        local tr = job and job.track or nil
        if not (tr and reaper.ValidatePtr(tr, "MediaTrack*")) then return nil, 0 end
        local trackIdx = preferredInsertIndex
        if trackIdx == nil then
            trackIdx = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
        end

        local insertedTrackCount = 0
        local targets = {
            folderTrack = nil,
            stemTracks = {},
            preserveFolderName = true,
            preserveStemTrackNames = true,
            preserveFolderDepth = true,
        }
        local sourceTrackName = getTrackDisplayName(job)

        if SETTINGS.createFolder then
            reaper.InsertTrackAtIndex(trackIdx, true)
            insertedTrackCount = insertedTrackCount + 1
            local folderTrack = reaper.GetTrack(0, trackIdx)
            targets.folderTrack = folderTrack
            reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", sourceTrackName .. " - Stems", true)
            reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
            HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
            UI_Window.ensureTrackHeight(folderTrack)
            trackIdx = trackIdx + 1
        end

        local childCount = 0
        for _, stem in ipairs(STEMS) do
            if stem.selected and stems and stems[stem.name:lower()] then
                reaper.InsertTrackAtIndex(trackIdx + childCount, true)
                insertedTrackCount = insertedTrackCount + 1
                local stemTrack = reaper.GetTrack(0, trackIdx + childCount)
                targets.stemTracks[stem.name:lower()] = stemTrack
                local stemTrackName = SETTINGS.createFolder and stem.name or (sourceTrackName .. " - " .. stem.name)
                reaper.GetSetMediaTrackInfo_String(stemTrack, "P_NAME", stemTrackName, true)
                local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                HELPERS.applyTrackColorIfEnabled(stemTrack, color)
                UI_Window.ensureTrackHeight(stemTrack)
                childCount = childCount + 1
            end
        end

        if SETTINGS.createFolder and childCount > 0 then
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + childCount - 1), "I_FOLDERDEPTH", -1)
        end

        if SETTINGS.createFolder and childCount == 0 and targets.folderTrack then
            reaper.DeleteTrack(targets.folderTrack)
            return nil, 0
        end

        return targets, insertedTrackCount
    end

    -- Execute OutputPlan
    for _, importPlan in ipairs(outputPlan.imports) do
        local job = importPlan.job
        local stems = importPlan.stems

        if importPlan.hasStems then
            writeTimingEvent(job, "import_start", job.index, {
                mode = outputPlan.destination == "new_tracks" and "new_tracks" or "in_place",
            })
            if SW_TIMING then SW_TIMING.mark(job.index, "import_start") end
            if outputPlan.destination == "new_tracks" then
                debugLog("  Calling createStemTracksForSelection..")
                SW_LOG.logExecResult(
                    "timing:import_start job=" .. tostring(job.index) .. " mode=new_tracks",
                    nil,
                    ""
                )
                local preferredInsertIndex = getImportInsertIndexForJob(job)
                local createOptions = nil
                if outputPlan.grouping == "source_track" then
                    local trackKey = getJobTrackKey(job)
                    if trackKey and not sharedTargetsByTrack[trackKey] then
                        local plannedTargets, insertedForPlan = buildSharedTargetsForTrack(job, stems, preferredInsertIndex)
                        if plannedTargets then
                            sharedTargetsByTrack[trackKey] = plannedTargets
                            advanceImportInsertCursorForJob(job, insertedForPlan)
                        end
                    end
                    if trackKey and sharedTargetsByTrack[trackKey] then
                        createOptions = {
                            resolveTrackTargets = function(context)
                                local contextTrack = context and context.sourceTrack
                                local key = contextTrack and reaper.ValidatePtr(contextTrack, "MediaTrack*") and tostring(contextTrack) or nil
                                if key then
                                    return sharedTargetsByTrack[key]
                                end
                                return sharedTargetsByTrack[trackKey]
                            end
                        }
                    end
                end

                local count, insertedTrackCount = createStemTracksForSelection(
                    stems,
                    importPlan.jobSelPos,
                    importPlan.jobSelLen,
                    job.track,
                    importPlan.itemsOverride,
                    importPlan.useItemNameForTrack,
                    preferredInsertIndex,
                    createOptions
                )
                advanceImportInsertCursorForJob(job, insertedTrackCount)
                SW_LOG.logExecResult(
                    "timing:import_end job=" .. tostring(job.index) .. " created=" .. tostring(count),
                    nil,
                    ""
                )
                debugLog("  Created " .. count .. " stem tracks")
                totalStemsCreated = totalStemsCreated + count
                if count > 0 then
                    job.hadImportedStems = true
                    if job.track and reaper.ValidatePtr(job.track, "MediaTrack*") then
                        sourceTracksWithStems[job.track] = true
                    end
                    local jobItems = job.sourceItems or (job.sourceItem and { job.sourceItem }) or {}
                    for _, item in ipairs(jobItems) do
                        if item and reaper.ValidatePtr(item, "MediaItem*") then
                            sourceItemsWithStems[tostring(item)] = true
                        end
                    end
                end
            else
                -- In-place mode: replace source item with stems as takes
                debugLog("  In-place mode: processing source item..")
                local sourceItem = job.sourceItem
                if sourceItem and reaper.ValidatePtr(sourceItem, "MediaItem*") then
                    if job.perItem and job.selPos and job.selLen and job.selLen > 0 then
                        local selStart = job.selPos
                        local selEnd = job.selPos + job.selLen
                        debugLog("  Per-item time selection: replacing selection at " .. selStart .. " len=" .. job.selLen)
                        local nameBase = job.sourceItemName or job.sourceItemDisplayName or getItemDisplayNameForTakes(sourceItem)
                        SW_LOG.logExecResult(
                            "timing:import_start job=" .. tostring(job.index) .. " mode=in_place_partial",
                            nil,
                            ""
                        )
                        local count, mainItem = WORKFLOW.replaceInPlacePartial(sourceItem, stems, selStart, selEnd, nameBase)
                        SW_LOG.logExecResult(
                            "timing:import_end job=" .. tostring(job.index) .. " created=" .. tostring(count),
                            nil,
                            ""
                        )
                        debugLog("  Replaced with " .. count .. " stems as takes")
                        local exploded = explodeTakesFromItem(mainItem, SETTINGS.postProcessTakes, nil, nameBase)
                        if exploded > 0 then
                            debugLog("  Post: exploded takes (" .. tostring(SETTINGS.postProcessTakes) .. ") => " .. tostring(exploded) .. " items")
                        else
                            if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                                local takeCount = reaper.CountTakes(mainItem) or 0
                                if takeCount > 1 then
                                    addPostProcessCandidate(mainItem)
                                    focusReaperAfterMainOpenOnce = true
                                end
                            end
                        end
                        totalStemsCreated = totalStemsCreated + count
                        if count > 0 then job.hadImportedStems = true end
                    else
                        -- Bij time selection: split het item eerst bij de selectie grenzen
                        -- zodat we alleen het selectie-deel vervangen, niet het hele item
                        if timeSelectionMode and timeSelectionStart and timeSelectionEnd then
                            local srcItemPos = reaper.GetMediaItemInfo_Value(sourceItem, "D_POSITION")
                            local srcItemLen = reaper.GetMediaItemInfo_Value(sourceItem, "D_LENGTH")
                            local srcItemEnd = srcItemPos + srcItemLen

                            debugLog("  Time selection mode: splitting item at selection boundaries")
                            debugLog("  Item: " .. srcItemPos .. " to " .. srcItemEnd)
                            debugLog("  Selection: " .. timeSelectionStart .. " to " .. timeSelectionEnd)

                            -- Split bij start van selectie (als selectie niet aan begin item is)
                            local selectionItem = sourceItem
                            if timeSelectionStart > srcItemPos + 0.001 then
                                selectionItem = reaper.SplitMediaItem(sourceItem, timeSelectionStart)
                                debugLog("  Split at start: " .. timeSelectionStart)
                            end

                            -- Split bij einde van selectie (als selectie niet aan einde item is)
                            if selectionItem and timeSelectionEnd < srcItemEnd - 0.001 then
                                reaper.SplitMediaItem(selectionItem, timeSelectionEnd)
                                debugLog("  Split at end: " .. timeSelectionEnd)
                            end

                            -- Gebruik het selectie-item voor replacement
                            if selectionItem then
                                sourceItem = selectionItem
                            end
                        end

                        local srcItemPos = reaper.GetMediaItemInfo_Value(sourceItem, "D_POSITION")
                        local srcItemLen = reaper.GetMediaItemInfo_Value(sourceItem, "D_LENGTH")
                        local nameBase = job.sourceItemName or job.sourceItemDisplayName or getItemDisplayNameForTakes(sourceItem)
                        debugLog("  Replacing item at pos=" .. srcItemPos .. ", len=" .. srcItemLen)
                        SW_LOG.logExecResult(
                            "timing:import_start job=" .. tostring(job.index) .. " mode=in_place",
                            nil,
                            ""
                        )
                        local count, mainItem = WORKFLOW.replaceInPlace(sourceItem, stems, srcItemPos, srcItemLen, nameBase)
                        SW_LOG.logExecResult(
                            "timing:import_end job=" .. tostring(job.index) .. " created=" .. tostring(count),
                            nil,
                            ""
                        )
                        debugLog("  Replaced with " .. count .. " stems as takes")
                    local exploded = explodeTakesFromItem(mainItem, SETTINGS.postProcessTakes, nil, nameBase)
                    if exploded > 0 then
                        debugLog("  Post: exploded takes (" .. tostring(SETTINGS.postProcessTakes) .. ") => " .. tostring(exploded) .. " items")
                    else
                        if mainItem and reaper.ValidatePtr(mainItem, "MediaItem*") then
                            local takeCount = reaper.CountTakes(mainItem) or 0
                            if takeCount > 1 then
                                addPostProcessCandidate(mainItem)
                                focusReaperAfterMainOpenOnce = true
                            end
                        end
                    end
                    totalStemsCreated = totalStemsCreated + count
                    if count > 0 then job.hadImportedStems = true end
                    end
                else
                    debugLog("  ERROR: No valid source item for in-place replacement")
                end
            end
            writeTimingEvent(job, "import_end", job.index, {
                mode = outputPlan.destination == "new_tracks" and "new_tracks" or "in_place",
            })
            if SW_TIMING then SW_TIMING.mark(job.index, "import_end") end
            table.insert(trackNames, job.trackName)
        else
            debugLog("  No stems found, skipping")
        end
        if SW_TIMING then SW_TIMING.endJob(job.index, job.hadImportedStems and "success" or "no_stems") end
    end
    local sourceTrackCountWithStems = 0
    for _ in pairs(sourceTracksWithStems) do sourceTrackCountWithStems = sourceTrackCountWithStems + 1 end
    local sourceItemCountWithStems = 0
    for _ in pairs(sourceItemsWithStems) do sourceItemCountWithStems = sourceItemCountWithStems + 1 end
    debugLog("Total stems created: " .. totalStemsCreated)

    -- If nothing was created, surface the Python log instead of silently returning to main().
    -- Also undo any mute/delete actions that may have been applied earlier in this function.
    if totalStemsCreated == 0 then
        -- Preserve diagnostics for all jobs before surfacing the error.
        if multiTrackQueue.jobs then
            for _, job in ipairs(multiTrackQueue.jobs) do
                if job.trackDir and job.trackDir ~= "" then
                    local ec = SW_LOG.readExitCode(job.exitCodeFile)
                    SW_LOG.preserveDiagnosticsForRun(job.trackDir, { reason = "no_stems", exitCode = ec })
                end
            end
        end

        -- Use the first job's log as the primary error (usually enough).
        local firstJob = multiTrackQueue.jobs and multiTrackQueue.jobs[1] or nil
        local logPath = firstJob and firstJob.logFile or nil
        local logSnippet = SW_LOG.readFileSnippet(logPath, 1400) or "(no log output found)"
        local stdoutSnippet = firstJob and SW_LOG.readFileSnippet(firstJob.stdoutFile, 1200) or nil
        local exitCode = firstJob and SW_LOG.readExitCode(firstJob.exitCodeFile) or nil
        local cmdLine = firstJob and firstJob.lastCmd or nil
        local debugLogPath = firstJob and (firstJob.execLogPath or SW_LOG.getLogPath()) or SW_LOG.getLogPath()

        local msg = buildKnownSeparationFailureMessage(
            logSnippet,
            exitCode,
            cmdLine,
            logPath,
            debugLogPath,
            stdoutSnippet
        )
        if not msg then
            msg = "No stems were created.\n\n"
                .. "This usually means the Python separator failed to start or crashed.\n\n"
                .. "Exit code: " .. tostring(exitCode or "unknown") .. "\n"
                .. "Command: " .. tostring(cmdLine or "unknown") .. "\n"
                .. "Python log (" .. tostring(logPath or "unknown") .. "):\n"
                .. logSnippet
                .. "\n\nDebug log: " .. tostring(debugLogPath)
            if stdoutSnippet and stdoutSnippet ~= "" then
                msg = msg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
            end
        end

        -- Friendly hint for the most common missing dependency.
        if logSnippet:find("No module named 'onnxruntime'", 1, true) then
            local onnxFixCmd = tostring(PYTHON_PATH) .. " -m pip install onnxruntime"
            if logSnippet:find("requested_device=directml", 1, true) then
                onnxFixCmd = tostring(PYTHON_PATH) .. " -m pip install onnxruntime-directml"
            end
            msg = msg
                .. "\n\nFix:\n"
                .. "Install the missing ONNX Runtime package into the Python venv that REAPER is using:\n"
                .. onnxFixCmd .. "\n\n"
                .. "Then rerun STEMwerk-SETUP.lua in REAPER to repair the runtime.\n\n"
                .. "On Windows DirectML, use:\n"
                .. tostring(PYTHON_PATH) .. " -m pip install onnxruntime-directml\n\n"
                .. "On Apple Silicon, use:\n"
                .. tostring(PYTHON_PATH) .. " -m pip install onnxruntime-silicon\n\n"
                .. "If pip refuses (no wheels for your Python version), recreate the venv with Python 3.11/3.12 and reinstall dependencies."
        end

        -- Close and undo the block to revert any pre-stem actions (mute/delete).
        reaper.Undo_EndBlock("STEMwerk: Separation failed (no stems created)", -1)
        if reaper.Undo_DoUndo2 then
            reaper.Undo_DoUndo2(0)
        end
        reaper.UpdateArrange()

        multiTrackQueue.active = false
        isProcessingActive = false
        showMessage("Separation Failed", msg, "error", false)
        return
    end

    -- Handle delete/mute options AFTER stems are created (so placement isn't disturbed)
    if applyCleanup and not (SETTINGS.deleteOriginalTrack or SETTINGS.muteOriginalTrack) then
        if SETTINGS.muteOriginal and not skipSelectionProcessing then
            for _, item in ipairs(allItems) do
                if reaper.ValidatePtr(item, "MediaItem*") then
                    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
                    actionCount = actionCount + 1
                end
            end
            actionData = { kind = "items", key = "result_action_muted", count = actionCount }
        elseif SETTINGS.muteSelection and not skipSelectionProcessing and hasCleanupTimeSel then
            for i = #allItems, 1, -1 do
                local item = allItems[i]
                if reaper.ValidatePtr(item, "MediaItem*") then
                    local itemTrack = reaper.GetMediaItem_Track(item)
                    if itemTrack then
                        local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                        local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                        local itemEnd = itemPos + itemLen
                        if itemPos < timeSelectionEnd and itemEnd > timeSelectionStart then
                            local splitStart = math.max(itemPos, timeSelectionStart)
                            local splitEnd = math.min(itemEnd, timeSelectionEnd)
                            local middleItem = item
                            if splitStart > itemPos + 0.001 then
                                middleItem = reaper.SplitMediaItem(item, splitStart)
                            end
                            if middleItem then
                                local middlePos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
                                local middleLen = reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
                                local middleEnd = middlePos + middleLen
                                if splitEnd < middleEnd - 0.001 then
                                    reaper.SplitMediaItem(middleItem, splitEnd)
                                end
                            end
                            if middleItem then
                                reaper.SetMediaItemInfo_Value(middleItem, "B_MUTE", 1)
                                actionCount = actionCount + 1
                            end
                        end
                    end
                end
            end
            actionData = { kind = "items", key = "result_action_selection_muted", count = actionCount }
        elseif SETTINGS.deleteOriginal then
            for i = #allItems, 1, -1 do
                local item = allItems[i]
                if reaper.ValidatePtr(item, "MediaItem*") then
                    local itemTrack = reaper.GetMediaItem_Track(item)
                    if itemTrack then
                        reaper.DeleteTrackMediaItem(itemTrack, item)
                        actionCount = actionCount + 1
                    end
                end
            end
            actionData = { kind = "items", key = "result_action_deleted", count = actionCount }
        elseif SETTINGS.deleteSelection and not skipSelectionProcessing and hasCleanupTimeSel then
            for i = #allItems, 1, -1 do
                local item = allItems[i]
                if reaper.ValidatePtr(item, "MediaItem*") then
                    local itemTrack = reaper.GetMediaItem_Track(item)
                    if itemTrack then
                        local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                        local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                        local itemEnd = itemPos + itemLen
                        if itemPos < timeSelectionEnd and itemEnd > timeSelectionStart then
                            local splitStart = math.max(itemPos, timeSelectionStart)
                            local splitEnd = math.min(itemEnd, timeSelectionEnd)
                            local middleItem = item
                            if splitStart > itemPos + 0.001 then
                                middleItem = reaper.SplitMediaItem(item, splitStart)
                            end
                            if middleItem then
                                local middlePos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
                                local middleLen = reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")
                                local middleEnd = middlePos + middleLen
                                if splitEnd < middleEnd - 0.001 then
                                    reaper.SplitMediaItem(middleItem, splitEnd)
                                end
                            end
                            if middleItem then
                                local middleTrack = reaper.GetMediaItem_Track(middleItem)
                                if middleTrack then
                                    reaper.DeleteTrackMediaItem(middleTrack, middleItem)
                                    actionCount = actionCount + 1
                                end
                            end
                        end
                    end
                end
            end
            actionData = { kind = "items", key = "result_action_selection_deleted", count = actionCount }
        end
    end

    -- Handle track-level cleanup AFTER stems are created.
    if applyCleanup and (SETTINGS.deleteOriginalTrack or SETTINGS.muteOriginalTrack) then
        -- Collect unique tracks from jobs.
        local sourceTracks = {}
        for _, job in ipairs(multiTrackQueue.jobs) do
            if job.track and reaper.ValidatePtr(job.track, "MediaTrack*") then
                -- Check if track is not already in list
                local found = false
                for _, t in ipairs(sourceTracks) do
                    if t == job.track then found = true; break end
                end
                if not found then
                    table.insert(sourceTracks, job.track)
                end
            end
        end

        if SETTINGS.deleteOriginalTrack then
            -- Delete tracks in reverse order (higher indices first).
            local trackDeleteCount = 0
            for i = #sourceTracks, 1, -1 do
                local track = sourceTracks[i]
                if reaper.ValidatePtr(track, "MediaTrack*") then
                    reaper.DeleteTrack(track)
                    trackDeleteCount = trackDeleteCount + 1
                end
            end
            if trackDeleteCount > 0 then
                actionData = { kind = "tracks", key = "result_action_tracks_deleted", count = trackDeleteCount }
            end
        elseif SETTINGS.muteOriginalTrack then
            local trackMuteCount = 0
            for i = 1, #sourceTracks do
                local track = sourceTracks[i]
                if reaper.ValidatePtr(track, "MediaTrack*") then
                    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
                    trackMuteCount = trackMuteCount + 1
                end
            end
            if trackMuteCount > 0 then
                actionData = { kind = "tracks", key = "result_action_tracks_muted", count = trackMuteCount }
            end
        end
    end

    reaper.Undo_EndBlock("STEMwerk: Multi-track stem separation", -1)
    UI_Window.adjustTrackLayout()

    -- Calculate total processing time
    local totalTime = os.time() - (multiTrackQueue.globalStartTime or os.time())
    local totalMins = math.floor(totalTime / 60)
    local totalSecs = totalTime % 60

    -- Calculate total audio duration processed
    local totalAudioDur = 0
    for _, job in ipairs(multiTrackQueue.jobs) do
        totalAudioDur = totalAudioDur + (job.audioDuration or 0)
    end

    -- Calculate realtime factor
    local realtimeFactor = totalAudioDur > 0 and (totalAudioDur / totalTime) or 0

    -- Log benchmark result
    local modeStr = multiTrackQueue.sequentialMode and "Sequential" or "Parallel"
    local segSize = multiTrackQueue.sequentialMode and "40" or "25"
    local benchmarkLog = getTempDir() .. PATH_SEP .. "STEMwerk_benchmark.txt"
    local bf = io.open(benchmarkLog, "a")
    if bf then
        bf:write(string.format("\n=== Benchmark Result ===\n"))
        bf:write(string.format("Date: %s\n", os.date("%Y-%m-%d %H:%M:%S")))
        bf:write(string.format("Mode: %s (segment size: %s)\n", modeStr, segSize))
        bf:write(string.format("Model: %s\n", effectiveRunModel()))
        bf:write(string.format("Tracks: %d\n", #multiTrackQueue.jobs))
        bf:write(string.format("Audio duration: %.1fs\n", totalAudioDur))
        bf:write(string.format("Processing time: %d:%02d (%ds)\n", totalMins, totalSecs, totalTime))
        bf:write(string.format("Speed: %.2fx realtime\n", realtimeFactor))
        bf:write(string.format("Stems created: %d\n", totalStemsCreated))
        bf:write("========================\n")
        bf:close()
    end

    multiTrackQueue.active = false

    -- Show result
    local selectedStemData = {}
    local is6Stem = isEffectiveRun6Stem()
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or is6Stem) then
            table.insert(selectedStemData, stem)
        end
    end

    local timeStr = string.format("%d:%02d", totalMins, totalSecs)
    local speedStr = string.format("%.2fx", realtimeFactor)
    local resultData
    if SETTINGS.createNewTracks then
        local anyPerItem = false
        for _, job in ipairs(multiTrackQueue.jobs or {}) do
            if job.perItem then
                anyPerItem = true
                break
            end
        end
        local srcCount
        local sourceKind
        if anyPerItem then
            srcCount = sourceItemCountWithStems > 0 and sourceItemCountWithStems or #multiTrackQueue.jobs
            sourceKind = "items"
        else
            srcCount = sourceTrackCountWithStems > 0 and sourceTrackCountWithStems or #multiTrackQueue.jobs
            sourceKind = "tracks"
        end
        resultData = {
            kind = "multi_new_tracks",
            stemsCreated = totalStemsCreated,
            sourceCount = srcCount,
            sourceKind = sourceKind,
            totalTimeSec = totalTime,
            realtimeFactor = realtimeFactor,
            sequentialMode = multiTrackQueue.sequentialMode and true or false,
            forceSequentialReason = multiTrackQueue.forceSequentialReason,
            requestedParallel = effectiveRunRequestedParallel() and true or false,
        }
    else
        local itemCount = #multiTrackQueue.jobs
        resultData = {
            kind = "multi_in_place",
            itemCount = itemCount,
            totalTimeSec = totalTime,
            realtimeFactor = realtimeFactor,
            sequentialMode = multiTrackQueue.sequentialMode and true or false,
            forceSequentialReason = multiTrackQueue.forceSequentialReason,
            requestedParallel = effectiveRunRequestedParallel() and true or false,
        }
    end
    resultData.action = actionData

    -- Cleanup temp working files (keep stem WAVs for REAPER references).
    if multiTrackQueue.jobs then
        for _, job in ipairs(multiTrackQueue.jobs) do
            if job.trackDir and job.hadImportedStems then
                cleanupTempWorkDir(job.trackDir, { success = true, keepStemPaths = job.importedStemPaths or {} })
            end
        end
    end

    -- Before clearing time selection, ensure playhead/cursor is at selection start
    if timeSelectionMode and timeSelectionStart and timeSelectionEnd then
        local playStateNow = reaper.GetPlayState() or 0
        local isPlayingNow = (playStateNow & 1) == 1
        if not isPlayingNow then
            local posNow = reaper.GetCursorPosition()
            local within = (posNow >= timeSelectionStart) and (posNow <= timeSelectionEnd)
            if not within then
                reaper.SetEditCurPos(timeSelectionStart, true, false)
            end
        end
    end

    -- Preserve user's time selection after processing (do not clear)

    -- Reset processing guard
    isProcessingActive = false

    SW_TIMING.endRun("success", { total_audio = totalAudioDur, rtf = realtimeFactor })
    SW_LOG.logExecResult("timing:finalize_end multi", nil, "")
    showResultWindow(selectedStemData, resultData)
end

-- Separation workflow
function runSeparationWorkflow()
    -- Prevent multiple concurrent runs
    if isProcessingActive then
        debugLog("=== runSeparationWorkflow BLOCKED - already processing ===")
        return
    end
    isProcessingActive = true
    debugLog("=== runSeparationWorkflow started ===")
    captureActiveRunConfig()

    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end

    local runOptions = nil
    local workflowModeState = tostring(reaper.GetExtState(EXT_SECTION, "active_workflow_mode") or "")
    local workflowSourceState = tostring(reaper.GetExtState(EXT_SECTION, "active_workflow_source") or "")
    local isDirectDKS = (workflowModeState == DKS_WORKFLOW.WORKFLOW_DRUMKIT)
        and (workflowSourceState == DKS_WORKFLOW.SOURCE_DIRECT or DKS_WORKFLOW.isDirectPreset(workflowSourceState))
    if workflowModeState ~= "" then
        reaper.DeleteExtState(EXT_SECTION, "active_workflow_mode", false)
    end
    if workflowSourceState ~= "" then
        reaper.DeleteExtState(EXT_SECTION, "active_workflow_source", false)
    end
    if isDirectDKS then
        runOptions = DKS_WORKFLOW.buildDirectRunOptions()
        debugLog("Direct DKS mode active: skipping Demucs dependency guard")
    end
    setWorkflowContextForRun(runOptions)

    if OS == "Windows" then
        showProcessingPlaceholderWindow(T("progress_checking_runtime") or "Checking runtime...")
    end

    if (not trustedWindowsRuntime) and (not isDirectDKS) and (not ensureDependenciesInteractive()) then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        setWorkflowContextForRun(nil)
        isProcessingActive = false
        return
    end

    -- Capture time selection ONCE to avoid flicker/race conditions (some systems briefly report equal start/end).
    local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local hasTimeSel = ((ts1 or 0) - (ts0 or 0)) > 0.000001
    if (not hasTimeSel) and reaper.GetSet_LoopTimeRange2 then
        local s2, e2 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
        if (e2 or 0) > (s2 or 0) then
            ts0, ts1 = s2, e2
            hasTimeSel = true
            debugLog(string.format(
                "GetSet_LoopTimeRange2 timeSel: (%.6f..%.6f)",
                tonumber(ts0) or -1, tonumber(ts1) or -1
            ))
        end
    end
    if not hasTimeSel then
        -- Fallback: if loop points are set but time selection isn't linked, mirror loop points.
        local loopStart, loopEnd = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
        if (loopEnd or 0) > (loopStart or 0) then
            reaper.GetSet_LoopTimeRange(true, false, loopStart, loopEnd, false)
            ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
            hasTimeSel = ((ts1 or 0) - (ts0 or 0)) > 0.000001
            debugLog(string.format(
                "Loop points -> time selection: timeSel=%s (%.6f..%.6f)",
                tostring(hasTimeSel),
                tonumber(ts0) or -1, tonumber(ts1) or -1
            ))
        end
    end

    local processSelectionSnap = PROCESS_SELECTION_SNAPSHOT

    debugLog(string.format(
        "Workflow start selection: timeSel=%s (%.6f..%.6f) selItems=%d selTracks=%d snap=%s",
        tostring(hasTimeSel),
        tonumber(ts0) or -1, tonumber(ts1) or -1,
        (reaper.CountSelectedMediaItems(0) or 0),
        (reaper.CountSelectedTracks(0) or 0),
        tostring(processSelectionSnap ~= nil)
    ))

    -- If REAPER reports no selection at workflow start, try to restore the snapshot taken
    -- when the user pressed Process.
    do
        local hasSelNow = false
        if hasTimeSel then
            hasSelNow = true
        elseif (reaper.CountSelectedMediaItems(0) or 0) > 0 then
            hasSelNow = true
        elseif (reaper.CountSelectedTracks(0) or 0) > 0 then
            hasSelNow = true
        end

        if (not hasSelNow) and processSelectionSnap then
            local snap = processSelectionSnap
            debugLog("No current selection; attempting to restore snapshot from Process click")

            if snap.timeStart and snap.timeEnd and (snap.timeEnd > snap.timeStart) then
                reaper.GetSet_LoopTimeRange(true, false, snap.timeStart, snap.timeEnd, false)
            end
            if snap.items and #snap.items > 0 then
                for _, it in ipairs(snap.items) do
                    if it and reaper.ValidatePtr(it, "MediaItem*") then
                        reaper.SetMediaItemSelected(it, true)
                    end
                end
            end
            if snap.tracks and #snap.tracks > 0 then
                for _, tr in ipairs(snap.tracks) do
                    if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
                        reaper.SetTrackSelected(tr, true)
                    end
                end
            end
            reaper.UpdateArrange()

            -- Re-read time selection after restore, once.
            ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
            hasTimeSel = ((ts1 or 0) - (ts0 or 0)) > 0.000001
            debugLog(string.format(
                "After restore: timeSel=%s (%.6f..%.6f) selItems=%d selTracks=%d",
                tostring(hasTimeSel),
                tonumber(ts0) or -1, tonumber(ts1) or -1,
                (reaper.CountSelectedMediaItems(0) or 0),
                (reaper.CountSelectedTracks(0) or 0)
            ))
        end
    end

    -- Guard: don't run if user selected 0 stems (it would produce no outputs and confuse users).
    local selectedStemCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or isEffectiveRun6Stem()) then
            selectedStemCount = selectedStemCount + 1
        end
    end
    if selectedStemCount <= 0 then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(T("no_stems_selected") or "No Stems Selected", T("please_select_stem") or "Please select at least one stem.", "warning")
        setWorkflowContextForRun(nil)
        isProcessingActive = false
        return
    end

    if tostring(SETTINGS.stemFileDestination or "temp") == "custom" and HELPERS.trimString(SETTINGS.customStemDir) == "" then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesMissingCustomWarning(), "warning")
        setWorkflowContextForRun(nil)
        isProcessingActive = false
        return
    end
    if tostring(SETTINGS.stemFileDestination or "temp") == "project_media" and not HELPERS.getProjectMediaDir() then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesProjectUnavailableWarning(), "warning")
        setWorkflowContextForRun(nil)
        isProcessingActive = false
        return
    end

    -- Save playback state to restore after processing
    savedPlaybackState = reaper.GetPlayState()
    debugLog("Saved playback state: " .. tostring(savedPlaybackState))

    -- Capture solo state once for this run (used by audibility filtering)
    PROCESS_AUDIBILITY_SOLO_ACTIVE = AUDIBILITY.anySoloActive()
    debugLog("Audibility solo active: " .. tostring(PROCESS_AUDIBILITY_SOLO_ACTIVE))

    -- Re-fetch the current selection at processing time (user may have changed it)
    selectedItem = reaper.GetSelectedMediaItem(0, 0)
    if (not selectedItem or not reaper.ValidatePtr(selectedItem, "MediaItem*")) and processSelectionSnap and processSelectionSnap.items then
        for _, it in ipairs(processSelectionSnap.items) do
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                reaper.SetMediaItemSelected(it, true)
                selectedItem = it
                debugLog("Recovered selected item directly from Process-click snapshot")
                break
            end
        end
        if selectedItem then
            reaper.UpdateArrange()
        end
    end
    timeSelectionMode = false
    debugLog("Selected item: " .. tostring(selectedItem))

    local soloActiveWorkflow = getProcessingSoloActive()
    local function trackAudibleWorkflow(track)
        return AUDIBILITY.isTrackAudible(track, soloActiveWorkflow)
    end
    local function isItemMutedWorkflow(item)
        return AUDIBILITY.isItemMuted(item)
    end

    -- If no items selected but tracks are selected, auto-select all items on those tracks.
    -- This intentionally ignores any time selection.
    if not selectedItem and reaper.CountSelectedTracks(0) > 0 then
        debugLog("No items/time selection, but tracks selected - auto-selecting items on tracks")
        local anyAudibleTrack = false
        for t = 0, reaper.CountSelectedTracks(0) - 1 do
            local track = reaper.GetSelectedTrack(0, t)
            if trackAudibleWorkflow(track) then
                anyAudibleTrack = true
                local numItems = reaper.CountTrackMediaItems(track)
                for i = 0, numItems - 1 do
                    local item = reaper.GetTrackMediaItem(track, i)
                    if not isItemMutedWorkflow(item) then
                        reaper.SetMediaItemSelected(item, true)
                    end
                end
            end
        end
        if not anyAudibleTrack then
            if OS == "Windows" and progressState.windowOpen then
                closeProcessingWindow()
            end
            showMessage("No audible tracks", "All selected tracks are muted or not solo-audible.", "info", true)
            setWorkflowContextForRun(nil)
            isProcessingActive = false
            return
        end
    UI_Window.adjustTrackLayout()
        selectedItem = reaper.GetSelectedMediaItem(0, 0)
        debugLog("After auto-select, selected item: " .. tostring(selectedItem))
    end

    if selectedItem and reaper.ValidatePtr(selectedItem, "MediaItem*") then
        local selectedItemCount = reaper.CountSelectedMediaItems(0) or 0
        if selectedItemCount > 1 then
            local tr = reaper.GetMediaItem_Track(selectedItem)
            if not (tr and trackAudibleWorkflow(tr)) or isItemMutedWorkflow(selectedItem) then
                local found = nil
                for i = 0, selectedItemCount - 1 do
                    local it = reaper.GetSelectedMediaItem(0, i)
                    local itr = it and reaper.GetMediaItem_Track(it)
                    if it and itr and trackAudibleWorkflow(itr) and not isItemMutedWorkflow(it) then
                        found = it
                        break
                    end
                end
                if found then
                    selectedItem = found
                    debugLog("Selected item was filtered; using alternate audible selected item")
                else
                    debugLog("Keeping explicitly selected item despite audibility filter to avoid selection regression")
                end
            end
        end
    end

    local selTrackCount = reaper.CountSelectedTracks(0) or 0
    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    local useTimeSel = hasTimeSel and not HELPERS.hasExplicitOverlapSelection(ts0, ts1)

    -- Only use time selection when nothing else is explicitly selected.
    if useTimeSel then
        timeSelectionMode = true
        timeSelectionStart, timeSelectionEnd = ts0, ts1
        itemPos = timeSelectionStart
        itemLen = timeSelectionEnd - timeSelectionStart
        debugLog("Time selection mode: " .. timeSelectionStart .. " to " .. timeSelectionEnd)
    elseif selectedItem then
        -- No time selection, use selected item
        itemPos = reaper.GetMediaItemInfo_Value(selectedItem, "D_POSITION")
        itemLen = reaper.GetMediaItemInfo_Value(selectedItem, "D_LENGTH")
    else
        if processSelectionSnap then
            local restored = false
            if processSelectionSnap.timeStart and processSelectionSnap.timeEnd and (processSelectionSnap.timeEnd > processSelectionSnap.timeStart) then
                reaper.GetSet_LoopTimeRange(true, false, processSelectionSnap.timeStart, processSelectionSnap.timeEnd, false)
                restored = true
            end
            if processSelectionSnap.items then
                for _, it in ipairs(processSelectionSnap.items) do
                    if it and reaper.ValidatePtr(it, "MediaItem*") then
                        reaper.SetMediaItemSelected(it, true)
                        selectedItem = it
                        restored = true
                        break
                    end
                end
            end
            if (not selectedItem) and processSelectionSnap.tracks then
                for _, tr in ipairs(processSelectionSnap.tracks) do
                    if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
                        reaper.SetTrackSelected(tr, true)
                        restored = true
                    end
                end
            end
            if restored then
                reaper.UpdateArrange()
                debugLog("Recovered selection from Process-click snapshot before start-screen fallback; retrying workflow")
                PROCESS_SELECTION_SNAPSHOT = nil
                if OS == "Windows" and progressState.windowOpen then
                    closeProcessingWindow()
                end
                isProcessingActive = false
                reaper.defer(function() runSeparationWorkflow() end)
                return
            end
        end

        -- No time selection and no item selected (and no track with items)
        debugLog(string.format(
            "No selection to process -> Start screen. timeSel=%s selItems=%d selTracks=%d",
            tostring(hasTimeSel),
            (reaper.CountSelectedMediaItems(0) or 0),
            (reaper.CountSelectedTracks(0) or 0)
        ))
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        showMessage(promptTitle, promptMessage, "info", true)
        setWorkflowContextForRun(nil)
        isProcessingActive = false
        return
    end

    PROCESS_SELECTION_SNAPSHOT = nil

    if OS == "Windows" then
        showProcessingPlaceholderWindow(T("progress_preparing_audio") or "Preparing audio...")
    end

    WORKFLOW_TEMP_DIR = makeUniqueTempSubdir("STEMwerk")
    makeDir(WORKFLOW_TEMP_DIR)
    WORKFLOW_TEMP_INPUT = WORKFLOW_TEMP_DIR .. PATH_SEP .. "input.wav"
    debugLog("Temp dir: " .. WORKFLOW_TEMP_DIR)
    debugLog("Temp input: " .. WORKFLOW_TEMP_INPUT)

    SW_TIMING.beginRun({ mode = "single", model = SETTINGS and SETTINGS.model or "", device = SETTINGS and SETTINGS.device or "" })
    SW_TIMING.beginJob("single", { model = SETTINGS and SETTINGS.model or "", device = SETTINGS and SETTINGS.device or "" })

    local extracted, err, sourceItem, trackList, trackItems
	    if timeSelectionMode then
	        debugLog("Rendering time selection to WAV..")
	        timeSelectionItemMap = nil
	        selectedItemsNoTimeMap = nil
	        writeTimingEvent(WORKFLOW_TEMP_DIR, "lua_extract_start", "single")
	        SW_TIMING.mark("single", "render_start")
	        extracted, err, sourceItem, trackList, trackItems = renderTimeSelectionToWav(WORKFLOW_TEMP_INPUT)
	        SW_TIMING.mark("single", "render_end")
	        writeTimingEvent(WORKFLOW_TEMP_DIR, "lua_extract_end", "single", { ok = extracted and true or false })
        debugLog("Render result: extracted=" .. tostring(extracted) .. ", err=" .. tostring(err))

        -- Check for multi-track mode
            if err == "MULTI_TRACK" and trackList and #trackList > 1 then
                -- Multi-track mode: process all tracks in parallel
                debugLog("Multi-track mode: " .. #trackList .. " tracks")
                if OS == "Windows" and progressState.windowOpen then
                    closeProcessingWindow()
                end
                if trackItems then
                    timeSelectionItemMap = trackItems
                    debugLog("Multi-track time selection: using per-item jobs across tracks")
            end
            _sep.runSingleTrackSeparation(trackList)
            -- If multi-track setup failed before activating the queue, unlock so user can retry
            if not multiTrackQueue.active then
                debugLog("Multi-track setup did not activate queue; resetting processing guard")
                isProcessingActive = false
            end
            return
        end

        -- Check for per-item time selection mode (single track, multiple items)
        if err == "MULTI_ITEM" and trackList and #trackList == 1 and trackItems then
            debugLog("Multi-item time selection on single track: using per-item jobs")
            if OS == "Windows" and progressState.windowOpen then
                closeProcessingWindow()
            end
            timeSelectionItemMap = trackItems
            _sep.runSingleTrackSeparation(trackList)
            if not multiTrackQueue.active then
                debugLog("Multi-item setup did not activate queue; resetting processing guard")
                isProcessingActive = false
            end
            return
        end

        timeSelectionSourceItem = sourceItem  -- Store for later use
	    else
	        -- No time selection - if tracks or items are selected, build combined track list
	        local selTrackCount = reaper.CountSelectedTracks(0)
	        local selItemCount = reaper.CountSelectedMediaItems(0)
	        debugLog("No time selection, selected items: " .. selItemCount .. ", selected tracks: " .. selTrackCount)
	        selectedItemsNoTimeMap = nil

	        local explicitTrackItemMap = {}
	        local explicitTrackItemSeen = {}
	        local function addExplicitTrackItem(track, item)
	            if not (track and item) then return end
	            if not reaper.ValidatePtr(track, "MediaTrack*") then return end
	            if not reaper.ValidatePtr(item, "MediaItem*") then return end
	            local seen = explicitTrackItemSeen[track]
	            if not seen then
	                seen = {}
	                explicitTrackItemSeen[track] = seen
	            end
	            if seen[item] then return end
	            seen[item] = true
	            local items = explicitTrackItemMap[track]
	            if not items then
	                items = {}
	                explicitTrackItemMap[track] = items
	            end
	            items[#items + 1] = item
	        end

	        if selItemCount and selItemCount > 0 then
	            for i = 0, selItemCount - 1 do
	                local it = reaper.GetSelectedMediaItem(0, i)
	                if it and reaper.ValidatePtr(it, "MediaItem*") and not isItemMutedWorkflow(it) then
	                    local tr = reaper.GetMediaItem_Track(it)
	                    if tr and trackAudibleWorkflow(tr) then
	                        addExplicitTrackItem(tr, it)
	                    end
	                end
	            end
	        elseif selTrackCount and selTrackCount > 0 then
	            for t = 0, selTrackCount - 1 do
	                local tr = reaper.GetSelectedTrack(0, t)
	                if tr and reaper.ValidatePtr(tr, "MediaTrack*") and trackAudibleWorkflow(tr) then
	                    local trackItemCount = reaper.CountTrackMediaItems(tr)
	                    for i = 0, trackItemCount - 1 do
	                        local it = reaper.GetTrackMediaItem(tr, i)
	                        if it and reaper.ValidatePtr(it, "MediaItem*") and not isItemMutedWorkflow(it) then
	                            addExplicitTrackItem(tr, it)
	                        end
	                    end
	                end
	            end
	        end
	        if next(explicitTrackItemMap) then
	            selectedItemsNoTimeMap = explicitTrackItemMap
	        end

	        -- Build combined track list from selected tracks and tracks of selected items
	        local trackSet = {}
        if selTrackCount and selTrackCount > 0 then
            for t = 0, selTrackCount - 1 do
                local tr = reaper.GetSelectedTrack(0, t)
                if tr and reaper.ValidatePtr(tr, "MediaTrack*") then trackSet[tr] = true end
            end
        end
        if selItemCount and selItemCount > 0 then
            for i = 0, selItemCount - 1 do
                local it = reaper.GetSelectedMediaItem(0, i)
                if it and reaper.ValidatePtr(it, "MediaItem*") then
                    local tr = reaper.GetMediaItem_Track(it)
                    if tr and reaper.ValidatePtr(tr, "MediaTrack*") then trackSet[tr] = true end
                end
            end
        end
        local combinedTrackList = {}
        for tr in pairs(trackSet) do table.insert(combinedTrackList, tr) end
        if #combinedTrackList > 1 then
            debugLog("Combined selection: running multi-track on " .. #combinedTrackList .. " tracks")
            if OS == "Windows" and progressState.windowOpen then
                closeProcessingWindow()
            end
            _sep.runSingleTrackSeparation(combinedTrackList)
            if not multiTrackQueue.active then
                debugLog("Combined selection setup did not activate queue; resetting processing guard")
                isProcessingActive = false
            end
            return
        end

        -- Fall back to original per-item selection behavior
        debugLog("Proceeding with per-item logic (selItemCount=" .. tostring(selItemCount) .. ")")

        if selItemCount > 1 then
            -- Multiple items selected - group by track and use multi-track mode
            local trackItems = {}  -- track -> list of items
            for i = 0, selItemCount - 1 do
                local item = reaper.GetSelectedMediaItem(0, i)
                local track = reaper.GetMediaItem_Track(item)
                if not trackItems[track] then
                    trackItems[track] = {}
                end
                table.insert(trackItems[track], item)
            end

            -- Build track list
            local trackList = {}
            for track in pairs(trackItems) do
                table.insert(trackList, track)
            end

            debugLog("Multi-item mode: " .. #trackList .. " tracks with items")
            if OS == "Windows" and progressState.windowOpen then
                closeProcessingWindow()
            end
            _sep.runSingleTrackSeparation(trackList)
            -- If multi-track setup failed before activating the queue, unlock so user can retry
            if not multiTrackQueue.active then
                debugLog("Multi-item setup did not activate queue; resetting processing guard")
                isProcessingActive = false
            end
            return
        end

        -- Single item mode
        local origItemPos = reaper.GetMediaItemInfo_Value(selectedItem, "D_POSITION")
        local origItemLen = reaper.GetMediaItemInfo_Value(selectedItem, "D_LENGTH")

        writeTimingEvent(WORKFLOW_TEMP_DIR, "lua_extract_start", "single")
        SW_TIMING.mark("single", "render_start")
        extracted, err = renderItemToWav(selectedItem, WORKFLOW_TEMP_INPUT)
        SW_TIMING.mark("single", "render_end")
        writeTimingEvent(WORKFLOW_TEMP_DIR, "lua_extract_end", "single", { ok = extracted and true or false })
        -- Check if we rendered a sub-selection (not the whole item)
        local renderPos, renderLen = nil, nil  -- These would come from renderItemToWav if supported
        if renderPos and renderLen then
            itemPos = renderPos
            itemLen = renderLen
            -- Detect if this is a sub-selection
            if math.abs(renderPos - origItemPos) > 0.001 or math.abs(renderLen - origItemLen) > 0.001 then
                itemSubSelection = true
                itemSubSelStart = renderPos
                itemSubSelEnd = renderPos + renderLen
            else
                itemSubSelection = false
            end
        end
    end

    if not extracted then
        debugLog("Extraction FAILED: " .. (err or "Unknown"))
        isProcessingActive = false
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        local detail = tostring(err or "Unknown")
        local noAudibleTargets = HELPERS.isNoAudibleTargetsError(detail)
        local title = noAudibleTargets and HELPERS.getNoAudibleTargetsTitle() or "Extraction Failed"
        local message = noAudibleTargets
            and HELPERS.getNoAudibleTargetsMessage()
            or ("Failed to extract audio.\n\n" .. detail .. "\n\nMake sure the items/tracks you want to process overlap your time selection.")
        showMessage(title, message, noAudibleTargets and "info" or "warning", false, function()
            if hasTimeSelection() or hasAnySelection() then
                showStemSelectionDialog()
            else
                local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
                showMessage(promptTitle, promptMessage, "info", true)
            end
        end)
        setWorkflowContextForRun(nil)
        return
    end

    debugLog("Extraction successful, starting separation..")
    debugLog("Model: " .. SETTINGS.model)
    do
        local fallback = THEME and THEME.accent or {1, 1, 1}
        local fr, fg, fb = fallback[1] or 1, fallback[2] or 1, fallback[3] or 1
        local function getTrackUIColor(track)
            if not track or not reaper or not reaper.GetTrackColor or not reaper.ColorFromNative then
                return { fr, fg, fb }
            end
            local col = reaper.GetTrackColor(track)
            if not col or col == 0 then
                return { fr, fg, fb }
            end
            local r, g, b = reaper.ColorFromNative(col)
            r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
            if r == 0 and g == 0 and b == 0 then
                return { fr, fg, fb }
            end
            return { r / 255, g / 255, b / 255 }
        end
        local uiTrack = nil
        if selectedItem and reaper.ValidatePtr(selectedItem, "MediaItem*") then
            uiTrack = reaper.GetMediaItem_Track(selectedItem)
        end
        if not uiTrack and (reaper.CountSelectedTracks(0) or 0) > 0 then
            uiTrack = reaper.GetSelectedTrack(0, 0)
        end
        progressState.uiColor = getTrackUIColor(uiTrack)
    end
    -- Start separation with progress UI (async)
    writeTimingEvent(WORKFLOW_TEMP_DIR, "python_launch", "single", { mode = "single" })
    local workflowModel = SETTINGS.model
    if runOptions and runOptions.requestedStage2Model then
        workflowModel = runOptions.requestedStage2Model
    end
    WORKFLOW.runSeparationWithProgress(WORKFLOW_TEMP_INPUT, WORKFLOW_TEMP_DIR, workflowModel, runOptions)
    debugLog("runSeparationWithProgress called")
end

-- Check for quick preset mode (called from toolbar scripts)
function checkQuickPreset()
    local quickRun = reaper.GetExtState(EXT_SECTION, "quick_run")
    if quickRun == "1" then
        -- Clear the flag
        reaper.DeleteExtState(EXT_SECTION, "quick_run", false)

        -- Apply preset based on quick_preset
        local preset = reaper.GetExtState(EXT_SECTION, "quick_preset")
        reaper.DeleteExtState(EXT_SECTION, "quick_preset", false)

        if preset == "karaoke" or preset == "instrumental" then
            applyPresetKaraoke()
        elseif preset == "vocals" then
            applyPresetVocalsOnly()
        elseif preset == "drums" then
            applyPresetDrumsOnly()
        elseif preset == "bass" then
            STEMS[1].selected = false
            STEMS[2].selected = false
            STEMS[3].selected = true
            STEMS[4].selected = false
        elseif preset == "all" then
            applyPresetAll()
        elseif preset == DKS_WORKFLOW.WORKFLOW_DRUMKIT or DKS_WORKFLOW.isDirectPreset(preset) then
            reaper.SetExtState(EXT_SECTION, "active_workflow_mode", DKS_WORKFLOW.WORKFLOW_DRUMKIT, false)
            reaper.SetExtState(EXT_SECTION, "active_workflow_source", DKS_WORKFLOW.SOURCE_DIRECT, false)
        end

        return true  -- Quick mode, skip dialog
    end
    return false
end

-- Check for quick command mode (called from toolbar scripts)
function checkQuickCommand()
    local cmd = reaper.GetExtState(EXT_SECTION, "quick_command")
    if cmd == "" then
        return false
    end

    -- Clear one-shot command flag
    reaper.DeleteExtState(EXT_SECTION, "quick_command", false)

    local valid = {
        explode_new_tracks = true,
        explode_in_place = true,
        explode_in_order = true,
    }
    if not valid[cmd] then
        return false
    end

    local created = applyPostProcessToSelectedCandidates(cmd)
    if created <= 0 then
        local multiTakeCount, hasTimeSel = getSelectedMultiTakeCountRespectingTimeSelection()
        local hint
        if hasTimeSel then
            hint = "Select at least one multi-take item that overlaps the time selection."
        else
            hint = "Select at least one multi-take item first."
        end
        reaper.ShowMessageBox(
            "No eligible multi-take items found.\n\n" .. hint,
            "STEMwerk: Explode Takes",
            0
        )
    end
    return true
end

-- Main
main = function()
    debugLog("=== main() called ===")
    perfMark("main() enter")

    if not PATH_STATE.guardNonCanonicalLaunch() then
        return
    end

    -- If a toolbar preset requested an immediate run, bypass the focus-only guard.
    local quickRunRequested = (reaper and reaper.GetExtState and (
        reaper.GetExtState(EXT_SECTION, "quick_run") == "1" or
        reaper.GetExtState(EXT_SECTION, "quick_command") ~= ""
    ))

    -- Check if STEMwerk window is already open - if so, just bring it to focus
    if not quickRunRequested and not skipExistingWindowCheckOnce and reaper.JS_Window_Find then
        local existingHwnd = reaper.JS_Window_Find(SCRIPT_NAME, true)
        if existingHwnd then
            debugLog("  Existing STEMwerk window found, bringing to focus")
            if reaper.JS_Window_SetFocus then
                reaper.JS_Window_SetFocus(existingHwnd)
            end
            return  -- Don't start a new instance
        end
    end

    -- Consume one-shot bypass (if set)
    if skipExistingWindowCheckOnce then
        skipExistingWindowCheckOnce = false
    end

    -- Load settings first (needed for window position in error messages)
    loadSettings()
    perfMark("loadSettings() done")

    -- Quick command mode (toolbar direct tools): run and exit without opening the main UI.
    if checkQuickCommand() then
        return
    end

    selectedItem = reaper.GetSelectedMediaItem(0, 0)
    timeSelectionMode = false
    autoSelectedItems = {}  -- Reset auto-selected items tracking
    autoSelectionTracks = {}  -- Reset auto-selection tracks tracking

    -- If no items selected but tracks are selected, auto-select all items on those tracks.
    -- This intentionally ignores any time selection.
    if not selectedItem and reaper.CountSelectedTracks(0) > 0 then
        for t = 0, reaper.CountSelectedTracks(0) - 1 do
            local track = reaper.GetSelectedTrack(0, t)
            table.insert(autoSelectionTracks, track)  -- Track this track for potential restore
            local numItems = reaper.CountTrackMediaItems(track)
            for i = 0, numItems - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                reaper.SetMediaItemSelected(item, true)
                table.insert(autoSelectedItems, item)  -- Track this item for potential restore
            end
        end
        reaper.UpdateArrange()
        selectedItem = reaper.GetSelectedMediaItem(0, 0)
    end

    local selTrackCount = reaper.CountSelectedTracks(0) or 0
    local selItemCount = reaper.CountSelectedMediaItems(0) or 0
    local useTimeSel = hasTimeSelection() and selTrackCount == 0 and selItemCount == 0

    -- Only use time selection when nothing else is explicitly selected.
    if useTimeSel then
        timeSelectionMode = true
        timeSelectionStart, timeSelectionEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
        itemPos = timeSelectionStart
        itemLen = timeSelectionEnd - timeSelectionStart
    elseif selectedItem then
        -- No time selection, use selected item
        itemPos = reaper.GetMediaItemInfo_Value(selectedItem, "D_POSITION")
        itemLen = reaper.GetMediaItemInfo_Value(selectedItem, "D_LENGTH")
    else
        -- No time selection, no item selected, no track with items
        if OS == "Windows" then
            GUI.windowsStartupMonitor = true
            showStemSelectionDialog()
            return
        end
        -- Show start screen with selection monitoring
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        showMessage(promptTitle, promptMessage, "info", true)
        return
    end

    local monitorState = HELPERS.getSelectionMonitorState()
    if not monitorState.actionable then
        if OS == "Windows" then
            GUI.windowsStartupMonitor = true
            showStemSelectionDialog()
            return
        end
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        showMessage(promptTitle, promptMessage, "info", true)
        return
    end

    -- Check for quick preset mode (from toolbar scripts)
    if checkQuickPreset() then
        -- Quick mode: run immediately without dialog
        saveSettings()
        reaper.defer(function()
            local ok, err = xpcall(runSeparationWorkflow, function(e)
                return tostring(e) .. "\n" .. debug.traceback("", 2)
            end)
            if not ok then
                debugLog("ERROR: runSeparationWorkflow crashed:\n" .. tostring(err))
                if SW_LOG and SW_LOG.logExecResult then
                    SW_LOG.logExecResult("workflow_crash", -1, tostring(err))
                end
                isProcessingActive = false
                showMessage("Error", "STEMwerk crashed while starting processing.\n\nSee log:\n" .. tostring(getCrashLogPath()), "error")
            end
        end)
    else
        -- Normal mode: show dialog
        GUI.windowsStartupMonitor = false
        perfMark("showStemSelectionDialog() about to run")
        showStemSelectionDialog()
    end
end

main()
