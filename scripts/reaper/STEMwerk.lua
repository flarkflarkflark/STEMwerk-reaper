-- Minimal debug stub so early callers won't fail; real debugLog defined later.
function debugLog(msg) end
function clearDebugLog() end
-- @description Stemwerk: Main
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1.11
-- @changelog
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
local APP_VERSION = "2.2.1.11"
local SCRIPT_NAME = "STEMwerk (v" .. APP_VERSION .. ")"
WINDOW_ART_GALLERY = "STEMwerk Art Gallery (v" .. APP_VERSION .. ")"
WINDOW_PROCESSING = "STEMwerk - Processing.. (v" .. APP_VERSION .. ")"
WINDOW_COMPLETE = "STEMwerk - Complete (v" .. APP_VERSION .. ")"
WINDOW_MULTI_TRACK = "STEMwerk - Multi-Track Progress (v" .. APP_VERSION .. ")"
local EXT_SECTION = "STEMwerk"  -- For ExtState persistence (keep old name for compatibility)
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

local function getExtStateValue(key)
    if reaper and reaper.GetExtState then
        local v = reaper.GetExtState(EXT_SECTION, key)
        if v ~= nil and v ~= "" then
            return v
        end
    end
    return nil
end

local function setExtStateValue(key, value)
    if reaper and reaper.SetExtState then
        reaper.SetExtState(EXT_SECTION, tostring(key), tostring(value), true)
    end
end

local SW_SETUP = dofile(script_path .. "_internal/STEMwerk_Runtime_Setup.lua")

-- Runtime/setup helper functions are delegated to SW_SETUP. Because several
-- functions defined below (canRunFfmpeg, findPython, etc.) reference these names
-- before the SW_SETUP.configure() call binds them, the forward declarations must
-- be visible at parse time - otherwise Lua resolves the names as globals and
-- crashes with "attempt to call a nil value" at runtime.
local ensureWritableDir
local getRuntimeBase
local getRuntimePaths
local resolveCommandPath
local persistPythonPath
local canImportAudioSeparator
local safeDofile
local isPythonAvailable
local runSetup
local verifyRuntimeAfterBootstrap
local ensureDependenciesInteractive

local function isAbsolutePath(p)
    if not p or p == "" then return false end
    if p:match("^%a:[/\\]") then return true end -- Windows drive
    if p:sub(1, 1) == "/" then return true end -- POSIX
    return false
end

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function quoteArg(s)
    s = tostring(s)
    if s:find('"') then
        s = s:gsub('"', '\\"')
    end
    if s:find("%s") then
        return '"' .. s .. '"'
    end
    return s
end

local function shellQuoteSingle(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function isFlatpak()
    local id = os.getenv("FLATPAK_ID")
    if id and id ~= "" then return true end
    local container = os.getenv("container")
    if container and container:lower():find("flatpak") then return true end
    return false
end

local function getFlatpakTempBase()
    if not isFlatpak() then return nil end
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/.cache/STEMwerk"
end

local SW_LOG = {}

function SW_LOG.isWindows()
    return package.config:sub(1, 1) == "\\"
end

function SW_LOG.getTempBase()
    return os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or (SW_LOG.isWindows() and "C:\\Windows\\Temp" or "/tmp")
end

function SW_LOG.getCacheBase()
    if SW_LOG.isWindows() then return SW_LOG.getTempBase() end
    return os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "/tmp") .. "/.cache")
end

function SW_LOG.ensureDir(path)
    if not path or path == "" then return end
    if SW_LOG.isWindows() then
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
    end
    return true
end

function SW_LOG.getLogDir()
    if SW_LOG.isWindows() then
        return SW_LOG.getTempBase() .. "\\STEMwerk\\logs"
    end
    return SW_LOG.getCacheBase() .. "/STEMwerk/logs"
end

function SW_LOG.getLogPath()
    local sep = SW_LOG.isWindows() and "\\" or "/"
    return SW_LOG.getLogDir() .. sep .. "stemwerk.log"
end

function SW_LOG.logExecResult(cmd, rc, out)
    local logDir = SW_LOG.getLogDir()
    SW_LOG.ensureDir(logDir)
    local logPath = SW_LOG.getLogPath()
    local f = io.open(logPath, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. "CMD: " .. tostring(cmd) .. "\n")
        if rc ~= nil then
            f:write("RC: " .. tostring(rc) .. "\n")
        end
        if out and out ~= "" then
            f:write("OUT:\n" .. tostring(out) .. "\n")
        end
        f:write("\n")
        f:close()
    end
    return logPath
end

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

function SW_LOG.wrapCmdForWindows(cmd)
    local lower = tostring(cmd or ""):lower()
    if lower:match("^%s*cmd%.exe") or lower:match("^%s*cmd%s") then
        if lower:find("/c", 1, true) then
            return cmd
        end
    end
    local c = tostring(cmd or "")
    if not c:match('^%s*"') then
        local exe, rest = c:match("^%s*([^%s]+)%s*(.*)$")
        if exe then
            if rest ~= "" then
                c = '"' .. exe .. '" ' .. rest
            else
                c = '"' .. exe .. '"'
            end
        end
    end
    if not c:find("2>&1", 1, true) then
        c = c .. " 2>&1"
    end
    return 'cmd.exe /S /C "' .. c .. '"'
end

function SW_LOG.commandNeedsWindowsShell(cmd)
    local c = tostring(cmd or "")
    local lower = c:lower()
    if lower == "" then return false end
    if lower:match("^%s*cmd%.exe") or lower:match("^%s*cmd%s") then return true end
    if c:find(">", 1, true) or c:find("<", 1, true) or c:find("|", 1, true) then return true end
    if c:find("&&", 1, true) or c:find("&", 1, true) then return true end
    if c:find("%ERRORLEVEL%", 1, true) then return true end
    if lower:find(" if errorlevel ", 1, true) then return true end
    if lower:find(" copy ", 1, true) then return true end
    return false
end

local function exec_capture(cmd, timeoutMs)
    timeoutMs = timeoutMs or 8000
    if reaper and reaper.ExecProcess then
        if SW_LOG.isWindows() and SW_LOG.commandNeedsWindowsShell(cmd) then
            cmd = SW_LOG.wrapCmdForWindows(cmd)
        end
        local rc, out = reaper.ExecProcess(cmd, timeoutMs)
        out = out or ""
        SW_LOG.logExecResult(cmd, rc, out)
        if out ~= "" then
            return tonumber(rc) or -1, out
        end
        if isFlatpak() and OS ~= "Windows" then
            debugLog("exec_capture: ExecProcess empty -> flatpak sandbox file fallback")
            local home = os.getenv("HOME") or ""
            local sep = PATH_SEP or "/"
            local cachePath = home .. sep .. ".cache" .. sep .. "stemwerk_exec_out.txt"
            local inner = "mkdir -p $HOME/.cache && " .. cmd .. " > $HOME/.cache/stemwerk_exec_out.txt 2>&1"
            local sandboxCmd = "sh -lc " .. shellQuoteSingle(inner)
            local rc2 = reaper.ExecProcess(sandboxCmd, timeoutMs)
            local f = io.open(cachePath, "r")
            local content = ""
            if f then
                content = f:read("*a") or ""
                f:close()
                os.remove(cachePath)
            end
            if content ~= "" then
                SW_LOG.logExecResult(sandboxCmd, rc2, content)
                return tonumber(rc2) or tonumber(rc) or -1, content
            end
            debugLog("exec_capture: sandbox fallback empty -> flatpak-spawn host fallback")
            local hostCmd = "flatpak-spawn --host sh -lc " .. shellQuoteSingle(inner)
            local rc3 = reaper.ExecProcess(hostCmd, timeoutMs)
            local f2 = io.open(cachePath, "r")
            local content2 = ""
            if f2 then
                content2 = f2:read("*a") or ""
                f2:close()
                os.remove(cachePath)
            end
            if content2 ~= "" then
                SW_LOG.logExecResult(hostCmd, rc3, content2)
                return tonumber(rc3) or tonumber(rc) or -1, content2
            end
        end
        return tonumber(rc) or -1, out
    end
    local ok = os.execute(cmd)
    local rc = (ok == true or ok == 0) and 0 or 1
    SW_LOG.logExecResult(cmd, rc, "")
    return rc, ""
end

local function execProcess(cmd, timeoutMs)
    timeoutMs = timeoutMs or 8000
    local rc, out = exec_capture(cmd, timeoutMs)
    return tonumber(rc) or -1, out or ""
end

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

    if OS ~= "macOS" then
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
        debugLog("canRunPython macOS: version probe failed for " .. tostring(pythonCmd) .. " output=" .. tostring(versionOut))
        return false
    end
    major = tonumber(major) or 0
    minor = tonumber(minor) or 0
    if major == 3 and minor >= 10 and minor <= 12 then
        return true
    end
    debugLog("Rejecting unsupported macOS Python: " .. tostring(pythonCmd) .. " version=" .. tostring(versionText or (major .. "." .. minor)))
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
    if not pythonPath or pythonPath == "" then
        return true, nil
    end
    local function escapePythonString(s)
        s = tostring(s or "")
        s = s:gsub("\\", "\\\\")
        s = s:gsub("'", "\\'")
        return s
    end

    -- Cross-platform temp directory
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
        if line ~= "" then
            ver = line:match("(%d+%.%d+%.%d+)")
        end
    end

    if rc ~= 0 or not ver then
        if out:lower():find("no module named 'numpy'", 1, true) then
            return false, "NumPy is not installed."
        end
        if rc == 0 and not ver then
            return true, nil
        end
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
DEBUG.logPath = nil  -- Set during init

local function debugLog(msg)
    if not DEBUG.enabled then return end
    if not DEBUG.logPath then
        local tempDir = getFlatpakTempBase() or os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
        DEBUG.logPath = tempDir .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. "STEMwerk_debug.log"
    end
    local f = io.open(DEBUG.logPath, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Clear debug log on script start
local function clearDebugLog()
    if not DEBUG.enabled then return end
    local tempDir = getFlatpakTempBase() or os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
    DEBUG.logPath = tempDir .. (package.config:sub(1,1) == "\\" and "\\" or "/") .. "STEMwerk_debug.log"
    local f = io.open(DEBUG.logPath, "w")
    if f then
        f:write("=== STEMwerk Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        f:close()
    end
end

clearDebugLog()
debugLog("Script loaded")

-- Lightweight performance markers (only when DEBUG.enabled is enabled).
PERF_T0 = os.clock()
function perfMark(label)
    if not DEBUG.enabled then return end
    debugLog(string.format("PERF +%.3fs %s", os.clock() - PERF_T0, tostring(label)))
end

-- FORCE DEBUG (temporary diagnostic): enable logging regardless of ExtState/env
-- (diagnostic removed)

-- Script path already calculated above

-- Detect OS
local function getOS()
    -- REAPER provides a reliable OS string; don't infer from Lua's package.config
    -- (some REAPER builds report POSIX separators even on Windows).
    local ros = ""
    if reaper and reaper.GetOS then
        ros = tostring(reaper.GetOS() or "")
    end
    if ros:match("Win") then return "Windows" end
    if ros:match("OSX") or ros:match("macOS") then return "macOS" end
    return "Linux"
end

local OS = getOS()
local PATH_SEP = OS == "Windows" and "\\" or "/"

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

-- Get home directory (cross-platform)
local function getHome()
    if OS == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    else
        return os.getenv("HOME") or "/tmp"
    end
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
                local rc, out = reaper.ExecProcess(quoteArg(resolved) .. " --version", 8000)
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
        scriptsDir .. "audio_separator_process.py",
        script_path .. "audio_separator_process.py",
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

local PYTHON_PATH
local SEPARATOR_SCRIPT

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

-- Stem configuration (with selection state)
-- First 4 are always shown, Guitar/Piano only for 6-stem model
local STEMS = {
    { name = "Vocals", color = {255, 100, 100}, file = "vocals.wav", selected = true, key = "1", sixStemOnly = false },
    { name = "Drums",  color = {100, 200, 255}, file = "drums.wav", selected = true, key = "2", sixStemOnly = false },
    { name = "Bass",   color = {150, 100, 255}, file = "bass.wav", selected = true, key = "3", sixStemOnly = false },
    { name = "Other",  color = {100, 255, 150}, file = "other.wav", selected = true, key = "4", sixStemOnly = false },
    { name = "Guitar", color = {255, 180, 80},  file = "guitar.wav", selected = true, key = "5", sixStemOnly = true },
    { name = "Piano",  color = {255, 120, 200}, file = "piano.wav", selected = true, key = "6", sixStemOnly = true },
}

-- Forward declarations (these are defined later in the file, but used by early helpers)
local SETTINGS
local saveSettings
local persistWindowPos
local drawGlossyPill
local drawGlossyRect

-- Available processing devices
local DEVICES = {
    { id = "auto", name = "Auto", desc = "Automatically select best GPU" },
    { id = "cpu", name = "CPU", desc = "Force CPU processing (slower)" },
    -- Generic GPU entries (unverified) so users can manually choose a GPU
    -- when the runtime probe fails.
    { id = "directml:0", name = "DirectML 0", type = "directml", desc = "DirectML GPU 0 (unverified)" },
    { id = "directml:1", name = "DirectML 1", type = "directml", desc = "DirectML GPU 1 (unverified)" },
    { id = "cuda:0", name = "CUDA 0", type = "cuda", desc = "CUDA GPU 0 (unverified)" },
    { id = "cuda:1", name = "CUDA 1", type = "cuda", desc = "CUDA GPU 1 (unverified)" },
}

-- Runtime-probed devices (preferred over the static DEVICES table).
-- This makes the UI capability-driven across OS/GPU stacks.
local RUNTIME_DEVICES = nil
local RUNTIME_DEVICE_NOTE_KEY = nil
local RUNTIME_DEVICE_LAST_PROBE = 0
local RUNTIME_DEVICE_PROBE_DEBUG = nil
local RUNTIME_DEVICE_SKIP_NOTE = nil
local RUNTIME_DIRECTML_POSSIBLE = nil
RUNTIME_CUDA_COUNT = nil
RUNTIME_DEVICE_PROBE = nil -- async probe state (avoid blocking UI on startup)

local function runtimeDeviceSafeList()
    return {
        { id = "auto", name = "Auto", type = "auto", desc = "Auto-select best available backend (or CPU fallback)." },
        { id = "cpu", name = "CPU", type = "cpu", desc = "Force CPU processing (works everywhere; slower)." },
    }
end

local function parseDeviceListFromPythonOutput(out)
    if not out or out == "" then return nil, nil end
    local devices = {}
    local envJson = nil
    local skipNote = nil
    local sawMachine = false
    local sawAlt = false
    local skips = {}

    for line in out:gmatch("[^\r\n]+") do
        if line:match("^STEMWERK_DEVICE\t") then
            sawMachine = true
            local id, name, typ = line:match("^STEMWERK_DEVICE\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if id and id ~= "" then
                devices[#devices + 1] = { id = id, name = name ~= "" and name or id, type = typ or "", desc = "" }
            end
        elseif line:match("^STEMWERK_DEVICE_SKIPPED\t") then
            local id, name, reason = line:match("^STEMWERK_DEVICE_SKIPPED\t([^\t]*)\t([^\t]*)\t(.*)$")
            if id and id ~= "" then
                skips[#skips + 1] = { id = id, name = name or id, reason = reason or "" }
            end
        elseif line:match("^STEMWERK_CUDA_DEVICE\t") then
            sawAlt = true
            local id, name = line:match("^STEMWERK_CUDA_DEVICE\t([^\t]*)\t(.*)$")
            if id and id ~= "" then
                devices[#devices + 1] = { id = id, name = (name and name ~= "" and name) or id, type = "cuda", desc = "" }
            end
        elseif line:match("^STEMWERK_DML_DEVICE\t") then
            sawAlt = true
            local id, name = line:match("^STEMWERK_DML_DEVICE\t([^\t]*)\t(.*)$")
            if id and id ~= "" then
                devices[#devices + 1] = { id = id, name = (name and name ~= "" and name) or id, type = "directml", desc = "" }
            end
        elseif line:match("^STEMWERK_DML_ALIAS\t") then
            -- Optional alias like: directml -> directml:0 (we still treat it as its own id)
            sawAlt = true
            local id, name = line:match("^STEMWERK_DML_ALIAS\t([^\t]*)\t(.*)$")
            if id and id ~= "" then
                devices[#devices + 1] = { id = id, name = (name and name ~= "" and name) or id, type = "directml", desc = "" }
            end
        elseif line:match("^STEMWERK_MPS_DEVICE\t") then
            sawAlt = true
            local id, name = line:match("^STEMWERK_MPS_DEVICE\t([^\t]*)\t(.*)$")
            if id and id ~= "" then
                devices[#devices + 1] = { id = id, name = (name and name ~= "" and name) or id, type = "mps", desc = "" }
            end
        elseif line:match("^STEMWERK_ENV_JSON%s+") then
            envJson = line:gsub("^STEMWERK_ENV_JSON%s+", "")
        end
    end

    -- Fallback: parse human output from `--list-devices`
    if not sawMachine and not sawAlt then
        for line in out:gmatch("[^\r\n]+") do
            local id, name, typ = line:match("^%s*([%w%-%_:%.]+):%s*(.-)%s*%(([%w%-%_]+)%)%s*$")
            if id and name and typ then
                devices[#devices + 1] = { id = id, name = name ~= "" and name or id, type = typ or "", desc = "" }
            end
        end
    end

    if #skips > 0 then
        local parts = {}
        for _, s in ipairs(skips) do
            local label = (s.id or "") .. (s.name and s.name ~= "" and (" — " .. s.name) or "")
            local reason = s.reason or ""
            parts[#parts + 1] = label .. (reason ~= "" and ("\n" .. reason) or "")
        end
        skipNote = "Not available:\n" .. table.concat(parts, "\n\n")
    end

    if #devices == 0 then return nil, envJson, skipNote end
    return devices, envJson, skipNote
end

local function buildDeviceNoteFromEnvJson(envJson, devices)
    local noteKey = nil
    local onlyCpu = true
    if devices then
        for _, d in ipairs(devices) do
            if d.id ~= "cpu" and d.id ~= "auto" then
                onlyCpu = false
                break
            end
        end
    end

    if onlyCpu and OS == "Linux" then
        noteKey = "device_note_linux_no_gpu"
    end

    -- If we have JSON, we can add a bit more context without fully parsing it.
    if envJson and envJson ~= "" then
        -- Special case: ROCm is installed but the Python env is using a CUDA build (common when a venv
        -- has pip-installed +cuXXX torch while the system has ROCm torch).
        if OS == "Linux"
            and envJson:find('"rocm_path_exists"%s*:%s*true')
            and envJson:find('"torch"%s*:%s*".-%+cu')
            and envJson:find('"cuda_available"%s*:%s*false')
            and (envJson:find('"torch_hip"%s*:%s*null') or envJson:find('"torch_hip"%s*:%s*""')) then
            noteKey = "device_note_linux_cuda_build"
        end

        if envJson:find('"cuda_available"%s*:%s*false') and OS ~= "Windows" then
            noteKey = noteKey or "device_note_cuda_unavailable"
        end
        if envJson:find('"mps_available"%s*:%s*false') and OS == "macOS" then
            noteKey = noteKey or "device_note_mps_unavailable"
        end
    end

    return noteKey
end

local function formatBackendReasonForUi(reason, deviceName)
    local text = tostring(reason or "")
    if text == "" then return "" end

    local normalizedDevice = tostring(deviceName or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local parts = {}
    local seen = {}

    for raw in text:gmatch("[^;]+") do
        local part = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local lower = part:lower()

        if lower == "device_probe_failed" then
            part = ""
        elseif lower == "backend_install_failed" then
            part = "Backend install failed; using CPU"
        elseif lower == "backend_force_cpu" then
            part = "CPU fallback forced"
        elseif lower == "bootstrap_cuda_confirmed" then
            part = "CUDA runtime confirmed"
        elseif lower == "bootstrap_directml_confirmed" then
            part = "DirectML runtime confirmed"
        elseif lower == "device_name_probe_failed" then
            part = "GPU model name could not be confirmed; the listed device may still work."
        end

        local normalizedPart = part:lower()
        if normalizedPart ~= "" and normalizedPart ~= normalizedDevice and not seen[normalizedPart] then
            seen[normalizedPart] = true
            parts[#parts + 1] = part
        end
    end

    return table.concat(parts, "; ")
end

local function backendTypeLabel(dev)
    if not dev or not dev.id then return "" end
    local id = tostring(dev.id)
    if id == "auto" then return "Auto" end
    if id == "cpu" then return "CPU" end
    if dev.type == "directml" or id:match("^directml") then return "DirectML" end
    if dev.type == "cuda" or id:match("^cuda") then
        if OS == "Linux" then
            local gpuName = string.lower(tostring(dev.fullName or dev.name or ""))
            if gpuName:find("amd", 1, true) or gpuName:find("radeon", 1, true) or gpuName:find("gfx", 1, true) then
                return "ROCm"
            end
        end
        return "CUDA"
    end
    if dev.type == "mps" or id == "mps" then return "Apple MPS" end
    return id
end

local function envJsonBool(envJson, key)
    if not envJson or envJson == "" or not key then return nil end
    if envJson:find('"' .. key .. '"%s*:%s*true') then return true end
    if envJson:find('"' .. key .. '"%s*:%s*false') then return false end
    return nil
end

-- Apply a parsed device list to globals (shared by sync + async probe).
function applyRuntimeDevicesFromParsed(devices, envJson, now)
    now = now or os.time()

    if not devices then
        -- Probe failed. To avoid misleading choices, show a safe minimal list.
        debugLog("  probe FAILED -> safe device list (Auto/CPU)")
        RUNTIME_DEVICE_SKIP_NOTE = nil
        RUNTIME_DIRECTML_POSSIBLE = nil
        RUNTIME_CUDA_COUNT = nil
        RUNTIME_DEVICES = runtimeDeviceSafeList()
        RUNTIME_DEVICE_NOTE_KEY = "device_note_probe_failed"
        RUNTIME_DEVICE_PROBE_DEBUG = "probe_failed"
        RUNTIME_DEVICE_LAST_PROBE = now
        if SETTINGS and SETTINGS.device and SETTINGS.device ~= "auto" and SETTINGS.device ~= "cpu" then
            SETTINGS.device = "auto"
            if saveSettings then saveSettings() end
        end
        return
    end

    -- Ensure stable entries exist even if an older Python script didn't include them.
    local function hasId(list, id)
        for _, d in ipairs(list) do
            if d.id == id then return true end
        end
        return false
    end
    if not hasId(devices, "auto") then
        table.insert(devices, 1, { id = "auto", name = "Auto", type = "auto", desc = "" })
    end
    if not hasId(devices, "cpu") then
        table.insert(devices, 2, { id = "cpu", name = "CPU", type = "cpu", desc = "" })
    end

    RUNTIME_DEVICE_PROBE_DEBUG = "ok"

    local gpuOptionCount = 0
    for _, dev in ipairs(devices) do
        local id = tostring(dev.id or "")
        if dev.type == "cuda" or dev.type == "directml" or id:match("^cuda:%d+$") or id:match("^directml:%d+$") or id == "cuda" or id == "directml" then
            gpuOptionCount = gpuOptionCount + 1
        end
    end

    local function compactGpuLabel(id)
        local sid = tostring(id or "")
        if OS == "Windows" and gpuOptionCount <= 1 and (sid:match("^cuda") or sid:match("^directml")) then
            return "GPU"
        end
        local idx = sid:match(":(%d+)$")
        if idx then
            return "GPU" .. idx
        end
        if sid == "cuda" or sid == "directml" then
            return "GPU"
        end
        return sid
    end

    local function isPlaceholderGpuName(name)
        local n = tostring(name or ""):lower()
        if n == "" then return true end
        if n:match("^cuda%s*%d*$") then return true end
        if n:match("^cuda%s*gpu%s*%d*$") then return true end
        if n:match("^directml%s*%d*$") then return true end
        if n:match("^directml%s*gpu%s*%d*$") then return true end
        if n:match("^gpu%s*%d*$") then return true end
        return false
    end

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

    -- Try to load optional mapping files that map device ids (e.g. "directml:0")
    -- to a human-friendly GPU name discovered by probing.
    --
    -- IMPORTANT: These mappings are *machine-specific*. If you sync/copy the STEMwerk folder
    -- between computers, a shared mapping file can show the "wrong" GPUs (from another system).
    -- To avoid that, we only load per-machine mapping files stored in the user's home folder.
    --
    -- Create one of these files (JSON object of id->name) if you want friendly names:
    --   Windows: %USERPROFILE%\.STEMwerk\device_map_<COMPUTERNAME>.json
    --   Linux:   ~/.STEMwerk/device_map_<HOSTNAME>.json
    --   macOS:   ~/.STEMwerk/device_map_<HOSTNAME>.json
    local function loadDeviceMap()
        local map = {}

        local function readMapFile(mapPath)
            local f = io.open(mapPath, "r")
            if not f then return end
            local ok, data = pcall(function() return f:read("*a") end)
            f:close()
            if not (ok and data and data ~= "") then return end
            for k, v in data:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
                map[k] = v
            end
        end

        local host = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or ""
        host = tostring(host):gsub("%s+", "")
        local home = getHome()
        local candidates = {}

        if home and host ~= "" then
            if PATH_SEP == "\\" then
                table.insert(candidates, home .. "\\.STEMwerk\\device_map_" .. host .. ".json")
                table.insert(candidates, home .. "\\Documents\\STEMwerk\\device_map_" .. host .. ".json")
            else
                table.insert(candidates, home .. "/.STEMwerk/device_map_" .. host .. ".json")
                table.insert(candidates, home .. "/Documents/STEMwerk/device_map_" .. host .. ".json")
            end
        end

        for _, mapPath in ipairs(candidates) do
            readMapFile(mapPath)
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

    -- Filter out backends that can never work on this OS.
    if OS ~= "Windows" then
        local filtered = {}
        for _, d in ipairs(devices) do
            if d.type ~= "directml" and not (d.id and d.id:match("^directml")) then
                filtered[#filtered + 1] = d
            end
        end
        devices = filtered
    end

    local directmlPossible = envJsonBool(envJson, "directml_possible")
    if OS ~= "Windows" then
        directmlPossible = false
    end
    if directmlPossible == nil then
        for _, d in ipairs(devices) do
            if d.type == "directml" or (d.id and d.id:match("^directml")) then
                directmlPossible = true
                break
            end
        end
    end
    RUNTIME_DIRECTML_POSSIBLE = directmlPossible
    if envJson and envJson ~= "" then
        RUNTIME_CUDA_COUNT = tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or RUNTIME_CUDA_COUNT
    else
        RUNTIME_CUDA_COUNT = nil
    end

    for _, d in ipairs(devices) do
        d.fullName = d.name
        local mapped = mappedDeviceName(d.id)
        if mapped then
            d.fullName = mapped
        end
        if d.id and (d.id:match("^cuda:%d+$") or d.id:match("^directml:%d+$") or d.type == "cuda" or d.type == "directml") then
            local short = sanitizeFriendlyName(d.fullName or d.name)
            if not short or short == "" or isPlaceholderGpuName(short) then
                short = sanitizeFriendlyName(d.name)
            end
            if not short or short == "" or isPlaceholderGpuName(short) then
                short = compactGpuLabel(d.id)
            end
            d.uiName = short
        else
            d.uiName = d.name
        end
        if d.id == "auto" then
            d.descKey = "device_auto_desc"
        elseif d.id == "cpu" then
            d.descKey = "device_cpu_desc"
        elseif d.type == "cuda" then
            d.descKey = "device_cuda_desc"
        elseif d.type == "directml" then
            d.descKey = "device_directml_desc"
        elseif d.type == "mps" then
            d.descKey = "device_mps_desc"
        end
    end

    RUNTIME_DEVICES = devices
    RUNTIME_DEVICE_NOTE_KEY = buildDeviceNoteFromEnvJson(envJson, devices)
    RUNTIME_DEVICE_LAST_PROBE = now

    -- Auto-select best device by running a very short benchmark per GPU candidate.
    local function parseBenchOutput(out)
        if not out then return nil end
        for line in out:gmatch("[^\r\n]+") do
            local s = line:match("elapsed=([%d%.]+)s") or line:match("Completed on device=.*elapsed=([%d%.]+)s")
            if s then
                local n = tonumber(s)
                if n then return n end
            end
        end
        return nil
    end

    local function quickBenchDevice(d)
        if not d or not d.id then return nil end
        -- Only benchmark GPU backends
        if not (d.type == "directml" or d.type == "cuda" or (d.id and d.id:match("^directml:%d+$") or d.id:match("^cuda:%d+$"))) then
            return nil
        end
        -- Ensure the helper script exists
        local benchScript = script_path .. "check_directml_runtime.py"
        if not fileExists(benchScript) then
            -- try repo location
            benchScript = (repo_root or "") .. "scripts" .. PATH_SEP .. "reaper" .. PATH_SEP .. "check_directml_runtime.py"
            if not fileExists(benchScript) then return nil end
        end
        local idx = tonumber((d.id or ""):match("%d+$")) or 0
        local cmd = quoteArg(PYTHON_PATH) .. " -u " .. quoteArg(benchScript) .. " --size 800 --iters 1 --dml-device " .. tostring(idx)
        local rc, out = execCapture(cmd, 20000)
        if rc ~= 0 then return nil end
        return parseBenchOutput(out)
    end

    local function autoSelectBestDevice(devices)
        if not devices or #devices == 0 then return end
        local bestId = nil
        local bestTime = nil
        local tried = 0
        for _, d in ipairs(devices) do
            if tried >= 3 then break end -- limit probes to at most 3 devices
            local t = quickBenchDevice(d)
            if t then
                tried = tried + 1
                if not bestTime or t < bestTime then
                    bestTime = t
                    bestId = d.id
                end
            end
        end
        if bestId and SETTINGS and (not SETTINGS.device or SETTINGS.device == "auto") then
            SETTINGS.device = bestId
            if saveSettings then saveSettings() end
            RUNTIME_DEVICE_NOTE_KEY = "device_note_auto_selected"
            debugLog("Auto-selected best device: " .. tostring(bestId) .. " time=" .. tostring(bestTime))
        end
    end

    -- Try to pick the best GPU automatically in the background (non-blocking UI would be nicer,
    -- but keep this simple: run a few quick benches so the UI shows the real preferred device).
    pcall(function() autoSelectBestDevice(RUNTIME_DEVICES) end)

    -- If the saved device is no longer available, fall back to auto.
    if SETTINGS and SETTINGS.device then
        local ok = false
        for _, d in ipairs(RUNTIME_DEVICES) do
            if d.id == SETTINGS.device then ok = true; break end
        end
        if not ok then
            SETTINGS.device = "auto"
            if saveSettings then saveSettings() end
        end
    end
    return true
end

-- Start an async device probe so we never block UI creation (probe results are parsed later).
function startRuntimeDeviceProbeAsync(force)
    force = force or false
    local now = os.time()
    if not force and RUNTIME_DEVICES and (now - (RUNTIME_DEVICE_LAST_PROBE or 0) < 10) then
        return false
    end
    if RUNTIME_DEVICE_PROBE and RUNTIME_DEVICE_PROBE.active then
        return false
    end

    if not force and applyCachedRuntimeDevices() then
        debugLog("=== Device probe: loaded from capabilities ===")
        return false
    end

    local function getTempDirEarly()
        if OS == "Windows" then
            return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        end
        local flatpakTemp = getFlatpakTempBase()
        if flatpakTemp then return flatpakTemp end
        return os.getenv("TMPDIR") or "/tmp"
    end
    local function makeDirEarly(path)
        if reaper and reaper.RecursiveCreateDirectory then
            reaper.RecursiveCreateDirectory(path, 0)
            return
        end
        if OS == "Windows" then
            os.execute('mkdir "' .. path .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
        end
    end
    local function uniqueProbeDir()
        local t = (reaper and reaper.time_precise) and reaper.time_precise() or os.clock() or 0
        local ms = math.floor(t * 1000)
        return getTempDirEarly() .. PATH_SEP .. "STEMwerk_devprobe_" .. tostring(os.time()) .. "_" .. tostring(ms)
    end

    local probeDir = uniqueProbeDir()
    makeDirEarly(probeDir)

    local outFile = probeDir .. PATH_SEP .. "probe_out.txt"
    local doneFile = probeDir .. PATH_SEP .. "done.txt"
    local pidFile = probeDir .. PATH_SEP .. "pid.txt"
    local rcFile = probeDir .. PATH_SEP .. "rc.txt"

    RUNTIME_DEVICE_PROBE = {
        active = true,
        startedAt = os.clock(),
        dir = probeDir,
        outFile = outFile,
        doneFile = doneFile,
        pidFile = pidFile,
        rcFile = rcFile,
    }
    RUNTIME_DEVICE_PROBE_DEBUG = "async_running"

    debugLog("=== Device probe: async start ===")
    debugLog("  dir=" .. tostring(probeDir))

    -- Seed a minimal list so the UI is usable while probing.
    if not RUNTIME_DEVICES then
        RUNTIME_DEVICES = runtimeDeviceSafeList()
    end
    RUNTIME_DEVICE_NOTE_KEY = "device_note_probing"

    if OS == "Windows" then
        local vbsPath = probeDir .. PATH_SEP .. "run_probe_hidden.vbs"
        local vbsFile = io.open(vbsPath, "w")
        if not vbsFile then
            debugLog("Async probe: failed to write VBS")
            RUNTIME_DEVICE_PROBE.active = false
            return false
        end

        local function escVbs(s)
            return tostring(s or ""):gsub('"', '""')
        end

        local function escPsSingle(s)
            return tostring(s or ""):gsub("'", "''")
        end

        local psPath = probeDir .. PATH_SEP .. "run_probe_hidden.ps1"
        local psScript = io.open(psPath, "w")
        if not psScript then
            vbsFile:close()
            debugLog("Async probe: failed to write PowerShell launcher")
            RUNTIME_DEVICE_PROBE.active = false
            return false
        end

        psScript:write("$ErrorActionPreference='SilentlyContinue'\n")
        psScript:write("$py='" .. escPsSingle(PYTHON_PATH) .. "'\n")
        psScript:write("$sep='" .. escPsSingle(SEPARATOR_SCRIPT) .. "'\n")
        psScript:write("$out='" .. escPsSingle(outFile) .. "'\n")
        psScript:write("$rc='" .. escPsSingle(rcFile) .. "'\n")
        psScript:write("$done='" .. escPsSingle(doneFile) .. "'\n")
        psScript:write("$outLast='" .. escPsSingle(script_path .. "probe_out_last.txt") .. "'\n")
        psScript:write("$rcLast='" .. escPsSingle(script_path .. "probe_rc_last.txt") .. "'\n")
        psScript:write("$arg1=@('-u',$sep,'--list-devices-machine')\n")
        psScript:write("$arg2=@('-u',$sep,'--list-devices')\n")
        psScript:write("$p=Start-Process -FilePath $py -ArgumentList $arg1 -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $out\n")
        psScript:write("$exitCode=$p.ExitCode\n")
        psScript:write("if ($exitCode -ne 0) { $p=Start-Process -FilePath $py -ArgumentList $arg2 -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $out; $exitCode=$p.ExitCode }\n")
        psScript:write("Set-Content -Path $rc -Value $exitCode -Encoding ascii\n")
        psScript:write("Set-Content -Path $done -Value 'DONE' -Encoding ascii\n")
        psScript:write("Copy-Item -LiteralPath $out -Destination $outLast -Force -ErrorAction SilentlyContinue\n")
        psScript:write("Copy-Item -LiteralPath $rc -Destination $rcLast -Force -ErrorAction SilentlyContinue\n")
        psScript:close()

        local psCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' .. quoteArg(psPath)

        vbsFile:write('Set sh = CreateObject("WScript.Shell")' .. "\n")
        vbsFile:write('cmd = "' .. escVbs(psCmd) .. '"' .. "\n")
        vbsFile:write('sh.Run cmd, 0, False' .. "\n")
        vbsFile:close()

        -- Save debug copy of the generated command and VBS wrapper
        local dbgPath = script_path .. "probe_debug_last.txt"
        local dbgF = io.open(dbgPath, "w")
        if dbgF then
            dbgF:write("--- PowerShell launcher (for device probe) ---\n")
            dbgF:write(psCmd .. "\n\n")
            dbgF:write("--- VBS wrapper content (will run wscript) ---\n")
            local vbsContent = 'Set sh = CreateObject("WScript.Shell")\n' .. 'cmd = "' .. escVbs(psCmd) .. '"\n' .. 'sh.Run cmd, 0, False\n'
            dbgF:write(vbsContent .. "\n")
            dbgF:close()
        end

        local wscriptCmd = 'wscript "' .. vbsPath .. '"'
        if reaper.ExecProcess then
            reaper.ExecProcess(wscriptCmd, -1)
        else
            local h = io.popen(wscriptCmd)
            if h then h:close() end
        end
    else
        local launcherPath = probeDir .. PATH_SEP .. "run_bg.sh"
        local script = io.open(launcherPath, "w")
        if not script then
            debugLog("Async probe: failed to write launcher")
            RUNTIME_DEVICE_PROBE.active = false
            return false
        end

        script:write("#!/bin/sh\n")
        script:write("PY=" .. quoteArg(PYTHON_PATH) .. "\n")
        script:write("SEP=" .. quoteArg(SEPARATOR_SCRIPT) .. "\n")
        script:write("OUT=" .. quoteArg(outFile) .. "\n")
        script:write("DONE=" .. quoteArg(doneFile) .. "\n")
        script:write("PIDFILE=" .. quoteArg(pidFile) .. "\n")
        script:write("RCFILE=" .. quoteArg(rcFile) .. "\n")
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
        script:write('  "$PY" -u "$SEP" --list-devices-machine >"$OUT" 2>&1\n')
        script:write("  rc=$?\n")
        script:write('  if [ "$rc" -ne 0 ]; then "$PY" -u "$SEP" --list-devices >"$OUT" 2>&1; rc=$?; fi\n')
        script:write('  echo "$rc" > "$RCFILE"\n')
        script:write('  echo DONE > "$DONE"\n')
        script:write(") &\n")
        script:write('echo $! > "$PIDFILE"\n')
        script:close()

        os.execute("sh " .. quoteArg(launcherPath) .. " 2>/dev/null")
    end

    return true
end

local function extractCapabilityDeviceOutput(cap)
    if not (cap and cap.raw) then return "" end

    local deviceOut = cap.raw:match("DEVICES_OUTPUT_BEGIN\r?\n(.-)\r?\nDEVICES_OUTPUT_END")
    if deviceOut and deviceOut ~= "" then
        return deviceOut
    end
    if cap.raw:find("STEMWERK_CUDA_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_DML_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_MPS_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_DEVICE\t", 1, true)
        or cap.raw:find("STEMWERK_ENV_JSON ", 1, true) then
        return cap.raw
    end

    local kv = cap.kv or {}
    local lines = {}
    local envJson = tostring(kv.ENV_JSON or "")
    local deviceNames = tostring(kv.DEVICE_NAMES or "")
    local backend = tostring(kv.BACKEND or "")

    if envJson ~= "" then
        lines[#lines + 1] = "STEMWERK_ENV_JSON " .. envJson
    end

    local function addCsvDevices(prefix, idPrefix, fallbackLabel)
        local idx = 0
        for name in deviceNames:gmatch("[^,]+") do
            local trimmed = tostring(name):gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                lines[#lines + 1] = prefix .. "\t" .. idPrefix .. tostring(idx) .. "\t" .. trimmed
                idx = idx + 1
            end
        end
        if idx == 0 then
            lines[#lines + 1] = prefix .. "\t" .. idPrefix .. "0\t" .. fallbackLabel
        end
    end

    if backend == "cuda" then
        addCsvDevices("STEMWERK_CUDA_DEVICE", "cuda:", "CUDA GPU 0")
    elseif backend == "directml" then
        addCsvDevices("STEMWERK_DML_DEVICE", "directml:", "DirectML GPU 0")
        lines[#lines + 1] = "STEMWERK_DML_ALIAS\tdirectml\tdirectml:0"
    elseif backend == "mps" then
        lines[#lines + 1] = "STEMWERK_MPS_DEVICE\tmps\tApple MPS"
    end

    return table.concat(lines, "\n")
end

function pollRuntimeDeviceProbe()
    if not (RUNTIME_DEVICE_PROBE and RUNTIME_DEVICE_PROBE.active) then return false end

    local age = os.clock() - (RUNTIME_DEVICE_PROBE.startedAt or os.clock())
    if age > 90 then
        debugLog("Async device probe timed out after " .. tostring(age) .. "s")
        RUNTIME_DEVICE_PROBE.active = false
        applyRuntimeDevicesFromParsed(nil, nil, os.time())
        return true
    end

    local df = io.open(RUNTIME_DEVICE_PROBE.doneFile, "r")
    if not df then return false end
    df:close()

    local out = ""
    local f = io.open(RUNTIME_DEVICE_PROBE.outFile, "r")
    if f then
        out = f:read("*a") or ""
        f:close()
    end

    local devices, envJson, skipNote = parseDeviceListFromPythonOutput(out)
    RUNTIME_DEVICE_SKIP_NOTE = skipNote
    applyRuntimeDevicesFromParsed(devices, envJson, os.time())
    RUNTIME_DEVICE_PROBE.active = false
    debugLog("=== Device probe: async done (devices=" .. tostring(RUNTIME_DEVICES and #RUNTIME_DEVICES or 0) .. ") ===")
    return true
end

local function refreshRuntimeDevices(force)
    force = force or false
    local now = os.time()
    if not force and RUNTIME_DEVICES and (now - (RUNTIME_DEVICE_LAST_PROBE or 0) < 10) then
        return
    end

    if not force and applyCachedRuntimeDevices() then
        return
    end

    debugLog("=== Device probe: refreshRuntimeDevices() ===")
    debugLog("  PYTHON_PATH=" .. tostring(PYTHON_PATH))
    debugLog("  SEPARATOR_SCRIPT=" .. tostring(SEPARATOR_SCRIPT))

    -- Probe via Python helper (preferred). If the installed script doesn't support the machine mode
    -- flag yet, we fall back to the human-readable `--list-devices` output.
    local devices, envJson = nil, nil
    -- Importing torch can take a while on some systems; give this probe a generous timeout.
    local PROBE_TIMEOUT_MS = 30000

    -- Exec/capture helper: REAPER's ExecProcess sometimes returns empty output on some systems.
    -- For probing, we can safely fall back to flatpak-spawn file capture or io.popen.
    local function execCapture(cmd, timeoutMs)
        local rc, out = exec_capture(cmd, timeoutMs)
        out = out or ""
        debugLog("  probe execCapture rc=" .. tostring(rc) .. " outLen=" .. tostring(#out))
        if out ~= "" then
            return rc, out
        end
        local h = io.popen(cmd .. " 2>&1")
        if h then
            local content = h:read("*a") or ""
            local ok, _, code = h:close()
            if ok == true then
                rc = 0
            elseif type(code) == "number" then
                rc = code
            else
                rc = rc or -1
            end
            if content ~= "" then
                debugLog("  probe io.popen used (rc=" .. tostring(rc) .. " outLen=" .. tostring(#content) .. ")")
            end
            return rc, content
        end
        return rc, out
    end

    local cmd1 = quoteArg(PYTHON_PATH) .. " -u " .. quoteArg(SEPARATOR_SCRIPT) .. " --list-devices-machine"
    debugLog("  probe cmd1=" .. cmd1)
    local rc1, out1 = execCapture(cmd1, PROBE_TIMEOUT_MS)
    if rc1 == 0 then
        if out1 and out1 ~= "" then
            local snippet = out1
            if #snippet > 900 then snippet = snippet:sub(1, 900) .. "\n...(truncated)..." end
            debugLog("  probe cmd1 output:\n" .. snippet)
        end
        devices, envJson, RUNTIME_DEVICE_SKIP_NOTE = parseDeviceListFromPythonOutput(out1)
        debugLog("  probe cmd1 parsed devices=" .. tostring(devices and #devices or 0))
    end
    if not devices then
        local cmd2 = quoteArg(PYTHON_PATH) .. " -u " .. quoteArg(SEPARATOR_SCRIPT) .. " --list-devices"
        debugLog("  probe cmd2=" .. cmd2)
        local rc2, out2 = execCapture(cmd2, PROBE_TIMEOUT_MS)
        if rc2 == 0 then
            if out2 and out2 ~= "" then
                local snippet = out2
                if #snippet > 900 then snippet = snippet:sub(1, 900) .. "\n...(truncated)..." end
                debugLog("  probe cmd2 output:\n" .. snippet)
            end
            devices, envJson, RUNTIME_DEVICE_SKIP_NOTE = parseDeviceListFromPythonOutput(out2)
            debugLog("  probe cmd2 parsed devices=" .. tostring(devices and #devices or 0))
        end
    end
    if not devices then
        -- Final fallback: probe torch capabilities directly (works even with older installed scripts).
        -- Emits STEMWERK_ENV_JSON plus STEMWERK_*_DEVICE lines we can parse without a JSON parser.
        local py = [[
import json, importlib.util
env = {}
try:
    import torch
    env['torch'] = getattr(torch, '__version__', '')
    env['cuda_available'] = bool(torch.cuda.is_available())
    env['cuda_count'] = int(torch.cuda.device_count()) if env['cuda_available'] else 0
    env['cuda_names'] = [torch.cuda.get_device_name(i) for i in range(env['cuda_count'])] if env['cuda_available'] else []
    try:
        env['mps_available'] = bool(getattr(torch.backends, 'mps', None) is not None and torch.backends.mps.is_available())
    except Exception:
        env['mps_available'] = False
except Exception as e:
    env['torch_error'] = str(e)
    env['cuda_available'] = False
    env['cuda_count'] = 0
    env['cuda_names'] = []
    env['mps_available'] = False
env['directml_possible'] = importlib.util.find_spec('torch_directml') is not None
print('STEMWERK_ENV_JSON ' + json.dumps(env, ensure_ascii=False))
for i, n in enumerate(env.get('cuda_names', [])):
    print(f'STEMWERK_CUDA_DEVICE\\tcuda:{i}\\t{n}')
if env.get('mps_available'):
    print('STEMWERK_MPS_DEVICE\\tmps\\tApple MPS')
if env.get('directml_possible'):
    try:
        import torch_directml
        c = torch_directml.device_count()
        for i in range(c):
            print(f'STEMWERK_DML_DEVICE\\tdirectml:{i}\\tDirectML GPU {i}')
        if c == 1:
            print('STEMWERK_DML_ALIAS\\tdirectml\\tdirectml:0')
    except Exception:
        pass
]]
        -- Avoid giant quoted -c strings (some shells/ExecProcess variants struggle with newlines).
        -- NOTE: this runs early in the script; don't depend on helpers defined later in the file.
        local function getTempDirEarly()
            if OS == "Windows" then
                return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
            end
            local flatpakTemp = getFlatpakTempBase()
            if flatpakTemp then return flatpakTemp end
            return os.getenv("TMPDIR") or "/tmp"
        end
        local function makeDirEarly(path)
            if reaper and reaper.RecursiveCreateDirectory then
                reaper.RecursiveCreateDirectory(path, 0)
                return
            end
            if OS == "Windows" then
                os.execute('mkdir "' .. path .. '" 2>nul')
            else
                os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
            end
        end
        local function uniqueProbeDir()
            local t = (reaper and reaper.time_precise) and reaper.time_precise() or os.clock() or 0
            local ms = math.floor(t * 1000)
            return getTempDirEarly() .. PATH_SEP .. "STEMwerk_probe_" .. tostring(os.time()) .. "_" .. tostring(ms)
        end

        local probeDir = uniqueProbeDir()
        makeDirEarly(probeDir)
        local probePath = probeDir .. PATH_SEP .. "stemwerk_probe_devices.py"
        local f = io.open(probePath, "w")
        if f then
            f:write(py)
            f:close()
        end
        local cmd3 = quoteArg(PYTHON_PATH) .. " " .. quoteArg(probePath)
        debugLog("  probe cmd3=" .. cmd3)
        local rc3, out3 = execCapture(cmd3, PROBE_TIMEOUT_MS)
        if rc3 == 0 then
            if out3 and out3 ~= "" then
                local snippet = out3
                if #snippet > 900 then snippet = snippet:sub(1, 900) .. "\n...(truncated)..." end
                debugLog("  probe cmd3 output:\n" .. snippet)
            end
            devices, envJson, RUNTIME_DEVICE_SKIP_NOTE = parseDeviceListFromPythonOutput(out3)
            debugLog("  probe cmd3 parsed devices=" .. tostring(devices and #devices or 0))
        end
    end

    if not devices then
        -- Probe failed. To avoid misleading choices, show a safe minimal list.
        -- This is better UX than showing CUDA/DirectML when they won't work.
        debugLog("  probe FAILED -> safe device list (Auto/CPU)")
        RUNTIME_DEVICE_SKIP_NOTE = nil
        RUNTIME_DIRECTML_POSSIBLE = nil
        RUNTIME_CUDA_COUNT = nil
        RUNTIME_DEVICES = {
            { id = "auto", name = "Auto", type = "auto", desc = "Auto-select best available backend (or CPU fallback)." },
            { id = "cpu", name = "CPU", type = "cpu", desc = "Force CPU processing (works everywhere; slower)." },
        }
        RUNTIME_DEVICE_NOTE_KEY = "device_note_probe_failed"
        RUNTIME_DEVICE_PROBE_DEBUG = "probe_failed"
        RUNTIME_DEVICE_LAST_PROBE = now
        if SETTINGS.device ~= "auto" and SETTINGS.device ~= "cpu" then
            SETTINGS.device = "auto"
            saveSettings()
        end
        return
    end

    -- Ensure stable entries exist even if an older Python script didn't include them.
    local function hasId(list, id)
        for _, d in ipairs(list) do
            if d.id == id then return true end
        end
        return false
    end
    if not hasId(devices, "auto") then
        table.insert(devices, 1, { id = "auto", name = "Auto", type = "auto", desc = "" })
    end
    if not hasId(devices, "cpu") then
        table.insert(devices, 2, { id = "cpu", name = "CPU", type = "cpu", desc = "" })
    end

    RUNTIME_DEVICE_PROBE_DEBUG = "ok"

    local gpuOptionCount = 0
    for _, dev in ipairs(devices) do
        local id = tostring(dev.id or "")
        if dev.type == "cuda" or dev.type == "directml" or id:match("^cuda:%d+$") or id:match("^directml:%d+$") or id == "cuda" or id == "directml" then
            gpuOptionCount = gpuOptionCount + 1
        end
    end

    local function compactGpuLabel(id)
        local sid = tostring(id or "")
        if OS == "Windows" and gpuOptionCount <= 1 and (sid:match("^cuda") or sid:match("^directml")) then
            return "GPU"
        end
        local idx = sid:match(":(%d+)$")
        if idx then
            return "GPU" .. idx
        end
        if sid == "cuda" or sid == "directml" then
            return "GPU"
        end
        return sid
    end

    local function isPlaceholderGpuName(name)
        local n = tostring(name or ""):lower()
        if n == "" then return true end
        if n:match("^cuda%s*%d*$") then return true end
        if n:match("^cuda%s*gpu%s*%d*$") then return true end
        if n:match("^directml%s*%d*$") then return true end
        if n:match("^directml%s*gpu%s*%d*$") then return true end
        if n:match("^gpu%s*%d*$") then return true end
        return false
    end

    -- Filter out backends that can never work on this OS.
    if OS ~= "Windows" then
        local filtered = {}
        for _, d in ipairs(devices) do
            if d.type ~= "directml" and not (d.id and d.id:match("^directml")) then
                filtered[#filtered + 1] = d
            end
        end
        devices = filtered
    end

    local directmlPossible = envJsonBool(envJson, "directml_possible")
    if OS ~= "Windows" then
        directmlPossible = false
    end
    if directmlPossible == nil then
        for _, d in ipairs(devices) do
            if d.type == "directml" or (d.id and d.id:match("^directml")) then
                directmlPossible = true
                break
            end
        end
    end
    RUNTIME_DIRECTML_POSSIBLE = directmlPossible
    if envJson and envJson ~= "" then
        RUNTIME_CUDA_COUNT = tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or RUNTIME_CUDA_COUNT
    else
        RUNTIME_CUDA_COUNT = nil
    end

    -- Fill descriptions for tooltips (store translation keys, not English strings).
    for _, d in ipairs(devices) do
        d.fullName = d.name
        if d.id and (d.id:match("^cuda:%d+$") or d.id:match("^directml:%d+$") or d.type == "cuda" or d.type == "directml") then
            local short = sanitizeFriendlyName(d.fullName or d.name)
            if not short or short == "" or isPlaceholderGpuName(short) then
                short = sanitizeFriendlyName(d.name)
            end
            if not short or short == "" or isPlaceholderGpuName(short) then
                short = compactGpuLabel(d.id)
            end
            d.uiName = short
        else
            d.uiName = d.name
        end
        if d.id == "auto" then
            d.descKey = "device_auto_desc"
        elseif d.id == "cpu" then
            d.descKey = "device_cpu_desc"
        elseif d.type == "cuda" then
            d.descKey = "device_cuda_desc"
        elseif d.type == "directml" then
            d.descKey = "device_directml_desc"
        elseif d.type == "mps" then
            d.descKey = "device_mps_desc"
        end
    end

    RUNTIME_DEVICES = devices
    RUNTIME_DEVICE_NOTE_KEY = buildDeviceNoteFromEnvJson(envJson, devices)
    RUNTIME_DEVICE_LAST_PROBE = now

    -- If the saved device is no longer available, fall back to auto.
    local ok = false
    for _, d in ipairs(RUNTIME_DEVICES) do
        if d.id == SETTINGS.device then ok = true; break end
    end
    if not ok then
        SETTINGS.device = "auto"
        saveSettings()
    end
end

function applyCachedRuntimeDevices()
    if type(readCapabilities) ~= "function" then
        return false
    end
    local cap = readCapabilities()
    if not cap then
        return false
    end

    local cachedOut = extractCapabilityDeviceOutput(cap)
    if cachedOut == "" then
        return false
    end

    local devices, envJson, skipNote = parseDeviceListFromPythonOutput(cachedOut)
    if not devices then
        return false
    end

    local backendReason = cap.kv and cap.kv.BACKEND_REASON or ""
    local backendReasonLabel = formatBackendReasonForUi(backendReason)
    if backendReasonLabel ~= "" then
        local backendLabel = "Backend"
        if type(T) == "function" then
            backendLabel = T("backend_label") or backendLabel
        end
        skipNote = (skipNote and (skipNote .. "\n\n") or "") .. backendLabel .. ": " .. tostring(backendReasonLabel)
    end
    RUNTIME_DEVICE_SKIP_NOTE = skipNote
    applyRuntimeDevicesFromParsed(devices, envJson, os.time())
    if cap.kv and cap.kv.PROFILE then
        debugLog("Capabilities profile=" .. tostring(cap.kv.PROFILE) .. " backend=" .. tostring(cap.kv.BACKEND))
    end
    return true
end

function getTrustedWindowsRuntimeState()
    if OS ~= "Windows" or type(readCapabilities) ~= "function" then
        return nil
    end
    local cap = readCapabilities()
    if not (cap and type(cap.kv) == "table") then
        return nil
    end

    local function trimValue(v)
        return tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    local function lowerValue(v)
        return string.lower(trimValue(v))
    end

    local verification = lowerValue(cap.kv.VERIFICATION)
    local audioSeparator = lowerValue(cap.kv.AUDIO_SEPARATOR)
    local stemwerkCore = lowerValue(cap.kv.STEMWERK_CORE)
    local pythonPath = trimValue(cap.kv.PYTHON_PATH)
    local ffmpegPath = trimValue(cap.kv.FFMPEG_PATH)

    if verification ~= "ok" or audioSeparator ~= "ok" or stemwerkCore ~= "ok" then
        return nil
    end
    if pythonPath == "" or ffmpegPath == "" then
        return nil
    end
    if isAbsolutePath(pythonPath) and not fileExists(pythonPath) then
        return nil
    end
    if isAbsolutePath(ffmpegPath) and not fileExists(ffmpegPath) then
        return nil
    end

    return {
        pythonPath = pythonPath,
        ffmpegPath = ffmpegPath,
        backend = trimValue(cap.kv.BACKEND),
        profile = trimValue(cap.kv.PROFILE),
    }
end

function applyTrustedWindowsRuntimeState(state)
    if not state then return false end
    if state.pythonPath and state.pythonPath ~= "" then
        PYTHON_PATH = state.pythonPath
    end
    if state.ffmpegPath and state.ffmpegPath ~= "" then
        FFMPEG_PATH = state.ffmpegPath
    end
    return true
end

function normalizeRequestedDeviceForRuntime(requestedDevice)
    local req = tostring(requestedDevice or "auto")
    if req == "" then return "auto" end
    if req == "auto" or req == "cpu" or req == "mps" then return req end

    local list = RUNTIME_DEVICES or DEVICES or {}
    local function hasId(id)
        for _, d in ipairs(list) do
            if tostring(d.id or "") == tostring(id or "") then
                return true
            end
        end
        return false
    end
    local function firstNumbered(prefix)
        for _, d in ipairs(list) do
            local id = tostring(d.id or "")
            if id:match("^" .. prefix .. ":%d+$") then
                return id
            end
        end
        return nil
    end

    if hasId(req) then
        return req
    end

    if req == "directml" then
        return firstNumbered("directml") or (hasId("directml") and "directml") or req
    end
    if req:match("^directml:%d+$") then
        return (hasId("directml") and "directml") or firstNumbered("directml") or req
    end

    if req == "cuda" then
        return firstNumbered("cuda") or (hasId("cuda") and "cuda") or req
    end
    if req:match("^cuda:%d+$") then
        return firstNumbered("cuda") or (hasId("cuda") and "cuda") or req
    end

    return req
end

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
    local function directoryHasAnyFiles(path)
        if not path or path == "" then return false end
        local cmd
        if OS == "Windows" then
            cmd = 'dir /b ' .. quoteArg(path) .. ' 2>nul'
        else
            cmd = 'ls -1 ' .. quoteArg(path) .. ' 2>/dev/null'
        end
        local h = io.popen(cmd)
        if not h then return false end
        local out = h:read("*a") or ""
        h:close()
        return out:match("%S") ~= nil
    end

    local function getModelCacheDirForUi()
        local override = os.getenv("AUDIO_SEPARATOR_MODEL_DIR")
        if override and override ~= "" then
            return override
        end

        local home = os.getenv("HOME") or ""
        if OS == "Windows" then
            local localAppData = os.getenv("LOCALAPPDATA") or ""
            if localAppData ~= "" then
                return localAppData .. "\\STEMwerk\\models"
            end
            if home ~= "" then
                return home .. "\\AppData\\Local\\STEMwerk\\models"
            end
            return ""
        end
        if OS == "macOS" then
            return home .. "/Library/Application Support/STEMwerk/models"
        end

        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            return xdg .. "/STEMwerk/models"
        end
        return home .. "/.local/share/STEMwerk/models"
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
        local bundledRoot = script_path .. "_bundled"
        local hasBundledPayload = directoryHasAnyFiles(bundledRoot .. PATH_SEP .. "wheels")
            or directoryHasAnyFiles(bundledRoot .. PATH_SEP .. "ffmpeg")
            or directoryHasAnyFiles(bundledRoot .. PATH_SEP .. "python")
        MODEL_AVAILABILITY.bundledLimited = hasBundledPayload

        local byId = {}
        if hasBundledPayload then
            local modelDir = getModelCacheDirForUi()
            for _, model in ipairs(MODELS) do
                local yaml = modelDir .. PATH_SEP .. tostring(model.id) .. ".yaml"
                byId[model.id] = fileExists(yaml)
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
        SETTINGS.model = getFirstAvailableModelId()
        return true
    end

    function unavailableModelTooltipSuffix()
        return "Not included in this bundled installer variant."
    end
end

-- Settings (persist between runs)
normalizeColorMode = function(mode)
    mode = tostring(mode or "")
    if mode == "no_track" or mode == "no_media" or mode == "off" then
        return mode
    end
    return "both"
end

SETTINGS = {
    model = "htdemucs",
    createNewTracks = true,
    createFolder = false,
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
    darkMode = true,           -- Dark/Light theme toggle
    themePreset = "classic",   -- Theme accent preset (classic/ember/ice/mono)
    parallelProcessing = true, -- Process multiple tracks in parallel (uses more GPU memory)
    language = "en",           -- UI language: en, nl, de
    visualFX = true,           -- Enable/disable visual effects (procedural art backgrounds)
    tooltips = true,           -- Global tooltip toggle
    keepTempFiles = false,     -- Keep temp working folders/logs after a run
    device = "auto",           -- Device selection: "auto", "cpu", "cuda:0", "cuda:1", "directml"
}

-- ========== INTERNATIONALIZATION (i18n) ==========
-- Load language strings from external file
local LANGUAGES = nil
local LANG = nil  -- Current language table

-- Load language file
local function loadLanguages()
    local function pathJoin(a, b)
        if a == "" then return b end
        local last = a:sub(-1)
        if last == "/" or last == "\\" then
            return a .. b
        end
        return a .. PATH_SEP .. b
    end

    local function getActionScriptDir()
        if reaper and reaper.get_action_context then
            local _, _, _, _, _, ctx = reaper.get_action_context()
            if type(ctx) == "string" and ctx ~= "" then
                local dir = ctx:match("@?(.*[/\\])")
                if dir and dir ~= "" then return dir end
            end
        end
        return script_path or ""
    end

    local baseDir = getActionScriptDir()
    local bases = {
        baseDir,
        pathJoin(baseDir, ".."),
        pathJoin(baseDir, ".." .. PATH_SEP .. ".."),
    }

    local function buildCandidates(filename)
        local candidates, seen = {}, {}
        for _, base in ipairs(bases) do
            local p = pathJoin(base, "i18n" .. PATH_SEP .. filename)
            if not seen[p] then
                candidates[#candidates + 1] = p
                seen[p] = true
            end
        end
        return candidates
    end

    local triedWrapper, triedLang = {}, {}

    -- Prefer the wrapper, which returns a LANGUAGES table.
    for _, wrapper_file in ipairs(buildCandidates("stemwerk_language_wrapper.lua")) do
        triedWrapper[#triedWrapper + 1] = wrapper_file
        local f = io.open(wrapper_file, "r")
        if f then
            f:close()
            local ok, result = pcall(dofile, wrapper_file)
            if ok and type(result) == "table" then
                LANGUAGES = result
                debugLog("Loaded languages from " .. wrapper_file)
                return true
            else
                debugLog("Failed to load languages via wrapper: " .. tostring(result))
            end
        end
    end

    -- Fallback: parse i18n/languages.lua (which defines `local LANGUAGES = {..}`).
    for _, lang_file in ipairs(buildCandidates("languages.lua")) do
        triedLang[#triedLang + 1] = lang_file
        local f = io.open(lang_file, "r")
        if f then
            local content = f:read("*all")
            f:close()

            local table_str = content:match("local%s+LANGUAGES%s*=%s*(%b{})")
            if table_str then
                local env = {}
                local chunk, err = load("LANGUAGES = " .. table_str, "languages", "t", env)
                if chunk then
                    local ok, result = pcall(chunk)
                    if ok and env.LANGUAGES then
                        LANGUAGES = env.LANGUAGES
                        debugLog("Loaded languages from " .. lang_file)
                        return true
                    else
                        debugLog("Failed to execute language table: " .. tostring(result))
                    end
                else
                    debugLog("Failed to parse language table: " .. tostring(err))
                end
            else
                debugLog("Could not extract LANGUAGES table from file: " .. lang_file)
            end
        end
    end

    debugLog("i18n files not found. Tried wrapper paths: " .. table.concat(triedWrapper, "; "))
    debugLog("i18n files not found. Tried language paths: " .. table.concat(triedLang, "; "))
    return false
end

-- Set active language
local function setLanguage(lang_code)
    if not LANGUAGES then loadLanguages() end
    if LANGUAGES and LANGUAGES[lang_code] then
        LANG = LANGUAGES[lang_code]
        SETTINGS.language = lang_code
        debugLog("Language set to: " .. lang_code)
    else
        -- Fallback to English
        if LANGUAGES and LANGUAGES.en then
            LANG = LANGUAGES.en
        else
            -- Ultimate fallback - empty table (strings will use hardcoded defaults)
            LANG = {}
        end
        debugLog("Language fallback to English (requested: " .. tostring(lang_code) .. ")")
    end
end

-- Get translated string (with fallback to key)
local function T(key)
    if LANG and LANG[key] then
        return LANG[key]
    end
    -- Fallback: return key with underscores replaced by spaces
    return key:gsub("_", " ")
end

local function trPlural(count, singularKey, pluralKey, singularFallback, pluralFallback)
    if (count or 0) == 1 then
        return T(singularKey) or singularFallback or singularKey
    end
    return T(pluralKey) or pluralFallback or pluralKey
end

-- Forward declare GUI so early helpers (e.g. handleArtAdvance) can reference it safely.
local GUI

local MIN_TRACK_HEIGHT = 72

local function ensureTrackHeight(track)
    if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then return end
    local current = reaper.GetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE") or 0
    if current < MIN_TRACK_HEIGHT then
        reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", MIN_TRACK_HEIGHT)
    end
end

local function adjustTrackLayout()
    if reaper.TrackList_AdjustWindows then
        reaper.TrackList_AdjustWindows(false)
    end
    if reaper.UpdateTimeline then
        reaper.UpdateTimeline()
    end
    reaper.UpdateArrange()
end

local function handleArtAdvance(state, mouseDown, char)
    state = state or {}
    local uiClicked = (GUI and GUI.uiClickedThisFrame) or false
    if char == 32 then
        generateNewArt()
        return
    end
    if mouseDown and not state.artMouseDown then
        state.artMouseDown = true
        state.artClickBlocked = uiClicked
    elseif not mouseDown and state.artMouseDown then
        if not state.artClickBlocked and not uiClicked then
            generateNewArt()
        end
        state.artMouseDown = false
        state.artClickBlocked = nil
    elseif mouseDown and state.artMouseDown and uiClicked then
        state.artClickBlocked = true
    end
end

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

-- Theme colors (will be set based on darkMode)
local THEME = {}
THEME_PRESET_ORDER = {"classic", "ember", "ice", "mono"}
THEME_PRESETS = {
    classic = {
        nameKey = "theme_classic",
        label = "Classic",
    },
    ember = {
        nameKey = "theme_ember",
        label = "Ember",
        dark = {
            accent = {0.75, 0.35, 0.25},
            accentHover = {0.85, 0.45, 0.35},
            checkboxChecked = {0.6, 0.35, 0.25},
            button = {0.55, 0.25, 0.2},
            buttonHover = {0.65, 0.35, 0.3},
            buttonPrimary = {0.5, 0.35, 0.2},
            buttonPrimaryHover = {0.6, 0.45, 0.3},
            bgGradientTop = {0.11, 0.09, 0.08},
            bgGradientBottom = {0.18, 0.14, 0.12},
        },
        light = {
            accent = {0.7, 0.3, 0.2},
            accentHover = {0.8, 0.4, 0.3},
            checkboxChecked = {0.7, 0.35, 0.25},
            button = {0.75, 0.4, 0.3},
            buttonHover = {0.85, 0.5, 0.4},
            buttonPrimary = {0.65, 0.4, 0.3},
            buttonPrimaryHover = {0.75, 0.5, 0.4},
            bgGradientTop = {0.98, 0.94, 0.92},
            bgGradientBottom = {0.92, 0.88, 0.86},
        },
    },
    ice = {
        nameKey = "theme_ice",
        label = "Ice",
        dark = {
            accent = {0.2, 0.65, 0.75},
            accentHover = {0.3, 0.75, 0.85},
            checkboxChecked = {0.2, 0.55, 0.65},
            button = {0.2, 0.5, 0.6},
            buttonHover = {0.3, 0.6, 0.7},
            buttonPrimary = {0.2, 0.55, 0.55},
            buttonPrimaryHover = {0.3, 0.65, 0.65},
            bgGradientTop = {0.08, 0.1, 0.12},
            bgGradientBottom = {0.14, 0.18, 0.2},
        },
        light = {
            accent = {0.2, 0.55, 0.7},
            accentHover = {0.3, 0.65, 0.8},
            checkboxChecked = {0.25, 0.55, 0.7},
            button = {0.3, 0.55, 0.7},
            buttonHover = {0.4, 0.65, 0.8},
            buttonPrimary = {0.25, 0.6, 0.6},
            buttonPrimaryHover = {0.35, 0.7, 0.7},
            bgGradientTop = {0.94, 0.97, 0.98},
            bgGradientBottom = {0.88, 0.92, 0.94},
        },
    },
    mono = {
        nameKey = "theme_mono",
        label = "Mono",
        dark = {
            accent = {0.55, 0.55, 0.6},
            accentHover = {0.65, 0.65, 0.7},
            checkboxChecked = {0.45, 0.45, 0.5},
            button = {0.35, 0.35, 0.4},
            buttonHover = {0.45, 0.45, 0.5},
            buttonPrimary = {0.4, 0.4, 0.45},
            buttonPrimaryHover = {0.5, 0.5, 0.55},
            bgGradientTop = {0.11, 0.11, 0.12},
            bgGradientBottom = {0.16, 0.16, 0.17},
        },
        light = {
            accent = {0.4, 0.4, 0.45},
            accentHover = {0.5, 0.5, 0.55},
            checkboxChecked = {0.45, 0.45, 0.5},
            button = {0.5, 0.5, 0.55},
            buttonHover = {0.6, 0.6, 0.65},
            buttonPrimary = {0.55, 0.55, 0.6},
            buttonPrimaryHover = {0.65, 0.65, 0.7},
            bgGradientTop = {0.96, 0.96, 0.97},
            bgGradientBottom = {0.9, 0.9, 0.91},
        },
    },
}

function normalizeThemePreset(preset)
    if type(preset) ~= "string" then
        return "classic"
    end
    if THEME_PRESETS[preset] then
        return preset
    end
    return "classic"
end

function applyThemePreset(themeTable)
    local presetId = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
    local preset = THEME_PRESETS[presetId]
    if not preset then
        return themeTable
    end
    local overrides = (SETTINGS and SETTINGS.darkMode) and preset.dark or preset.light
    if overrides then
        for key, value in pairs(overrides) do
            themeTable[key] = value
        end
    end
    return themeTable
end

local function updateTheme()
    if SETTINGS.darkMode then
        -- Dark theme
        THEME = {
            bg = {0.18, 0.18, 0.20},
            bgGradientTop = {0.10, 0.10, 0.12},
            bgGradientBottom = {0.18, 0.18, 0.20},
            inputBg = {0.12, 0.12, 0.14},
            text = {1, 1, 1},
            textDim = {0.7, 0.7, 0.7},
            textHint = {0.5, 0.5, 0.5},
            accent = {0.3, 0.5, 0.8},
            accentHover = {0.4, 0.6, 0.9},
            checkbox = {0.3, 0.3, 0.3},
            checkboxChecked = {0.3, 0.5, 0.7},
            button = {0.2, 0.4, 0.7},
            buttonHover = {0.3, 0.5, 0.8},
            buttonPrimary = {0.2, 0.5, 0.3},
            buttonPrimaryHover = {0.3, 0.6, 0.4},
            border = {0.6, 0.6, 0.6},
        }
    else
        -- Light theme
        THEME = {
            bg = {0.92, 0.92, 0.94},
            bgGradientTop = {0.96, 0.96, 0.98},
            bgGradientBottom = {0.88, 0.88, 0.90},
            inputBg = {0.85, 0.85, 0.87},
            text = {0.1, 0.1, 0.1},
            textDim = {0.3, 0.3, 0.3},
            textHint = {0.5, 0.5, 0.5},
            accent = {0.2, 0.4, 0.7},
            accentHover = {0.3, 0.5, 0.8},
            checkbox = {0.8, 0.8, 0.8},
            checkboxChecked = {0.3, 0.5, 0.7},
            button = {0.3, 0.5, 0.75},
            buttonHover = {0.4, 0.6, 0.85},
            buttonPrimary = {0.25, 0.55, 0.35},
            buttonPrimaryHover = {0.35, 0.65, 0.45},
            border = {0.4, 0.4, 0.4},
        }
    end
    applyThemePreset(THEME)
end

-- Initialize theme
updateTheme()

function getThemePresetLabel()
    local presetId = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
    local preset = THEME_PRESETS[presetId] or THEME_PRESETS.classic
    local key = preset and preset.nameKey
    if LANG and key and LANG[key] then
        return LANG[key]
    end
    return preset and preset.label or presetId
end

function getLangText(key, fallback)
    if LANG and LANG[key] then
        return LANG[key]
    end
    return fallback or key:gsub("_", " ")
end

function getThemeToggleTooltip()
    local switchTip = SETTINGS.darkMode and T("switch_light") or T("switch_dark")
    local presetLabel = getLangText("theme_preset", "Theme")
    local presetName = getThemePresetLabel()
    local cycleHint = getLangText("tooltip_theme_cycle", "Right-click to cycle preset")
    return string.format("%s  %s: %s (%s)", switchTip, presetLabel, presetName, cycleHint)
end

function cycleThemePreset()
    local current = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
    local idx = 1
    for i, presetId in ipairs(THEME_PRESET_ORDER) do
        if presetId == current then
            idx = i
            break
        end
    end
    local nextId = THEME_PRESET_ORDER[(idx % #THEME_PRESET_ORDER) + 1]
    SETTINGS.themePreset = nextId
    updateTheme()
    saveSettings()
end

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

-- Store last dialog position for subsequent windows (progress, result, messages)
lastDialogX, lastDialogY, lastDialogW, lastDialogH = nil, nil, 840, 600

-- Load saved position and size from standard "window_pos" format (x,y,w,h)
local savedPosMain = reaper.GetExtState(EXT_SECTION, "window_pos")
if savedPosMain == "" then savedPosMain = reaper.GetExtState(EXT_SECTION, "window_pos_main") end

if savedPosMain ~= "" then
    local sx, sy, sw, sh = savedPosMain:match("([^,]+),([^,]+),([^,]+),([^,]+)")
    if sx and sy and sw and sh then
        lastDialogX = tonumber(sx)
        lastDialogY = tonumber(sy)
        lastDialogW = math.max(840, tonumber(sw)) -- Default to 840
        lastDialogH = math.max(600, tonumber(sh)) -- Default to 600
    end
end

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

local function clearPostProcessCandidates()
    postProcessCandidates = {}
end

local function addPostProcessCandidate(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return end
    for _, existing in ipairs(postProcessCandidates) do
        if existing == item then return end
    end
    postProcessCandidates[#postProcessCandidates + 1] = item
end

-- Load settings from ExtState
local function loadSettings()
    refreshModelAvailability()

    local model = reaper.GetExtState(EXT_SECTION, "model")
    if model ~= "" then SETTINGS.model = model end

    local createNewTracks = reaper.GetExtState(EXT_SECTION, "createNewTracks")
    if createNewTracks ~= "" then SETTINGS.createNewTracks = (createNewTracks == "1") end

    local createFolder = reaper.GetExtState(EXT_SECTION, "createFolder")
    if createFolder ~= "" then SETTINGS.createFolder = (createFolder == "1") end

    local colorMode = reaper.GetExtState(EXT_SECTION, "colorMode")
    if colorMode ~= "" then
        SETTINGS.colorMode = normalizeColorMode(colorMode)
    else
    local applyTrackColors = reaper.GetExtState(EXT_SECTION, "applyTrackColors")
        if applyTrackColors ~= "" then
            SETTINGS.colorMode = (applyTrackColors == "1") and "both" or "no_track"
        end
    end
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")

    local stemFileDestination = reaper.GetExtState(EXT_SECTION, "stemFileDestination")
    if stemFileDestination ~= "" then SETTINGS.stemFileDestination = stemFileDestination end

    local customStemDir = reaper.GetExtState(EXT_SECTION, "customStemDir")
    if customStemDir ~= "" then SETTINGS.customStemDir = customStemDir end

    local postProcessTakes = reaper.GetExtState(EXT_SECTION, "postProcessTakes")
    if postProcessTakes ~= "" then SETTINGS.postProcessTakes = postProcessTakes end

    local muteOriginal = reaper.GetExtState(EXT_SECTION, "muteOriginal")
    if muteOriginal ~= "" then SETTINGS.muteOriginal = (muteOriginal == "1") end

    local muteSelection = reaper.GetExtState(EXT_SECTION, "muteSelection")
    if muteSelection ~= "" then SETTINGS.muteSelection = (muteSelection == "1") end

    local deleteOriginal = reaper.GetExtState(EXT_SECTION, "deleteOriginal")
    if deleteOriginal ~= "" then SETTINGS.deleteOriginal = (deleteOriginal == "1") end

    local deleteSelection = reaper.GetExtState(EXT_SECTION, "deleteSelection")
    if deleteSelection ~= "" then SETTINGS.deleteSelection = (deleteSelection == "1") end

    local deleteOriginalTrack = reaper.GetExtState(EXT_SECTION, "deleteOriginalTrack")
    if deleteOriginalTrack ~= "" then SETTINGS.deleteOriginalTrack = (deleteOriginalTrack == "1") end

    local darkMode = reaper.GetExtState(EXT_SECTION, "darkMode")
    if darkMode ~= "" then SETTINGS.darkMode = (darkMode == "1") end
    local themePreset = reaper.GetExtState(EXT_SECTION, "themePreset")
    if themePreset ~= "" then SETTINGS.themePreset = themePreset end
    SETTINGS.themePreset = normalizeThemePreset(SETTINGS.themePreset)
    updateTheme()

    local parallelProcessing = reaper.GetExtState(EXT_SECTION, "parallelProcessing")
    if parallelProcessing ~= "" then SETTINGS.parallelProcessing = (parallelProcessing == "1") end

    local visualFX = reaper.GetExtState(EXT_SECTION, "visualFX")
    if visualFX ~= "" then SETTINGS.visualFX = (visualFX == "1") end

    local tooltips = reaper.GetExtState(EXT_SECTION, "tooltips")
    if tooltips ~= "" then SETTINGS.tooltips = (tooltips == "1") end

    -- Load window position into globals only once (startup fallback).
    if not (GUI and GUI.windowPosLoaded) then
        local savedPos = reaper.GetExtState(EXT_SECTION, "window_pos_main")
        if savedPos == "" then savedPos = reaper.GetExtState(EXT_SECTION, "window_pos") end
        if savedPos ~= "" then
            local sx, sy, sw, sh = savedPos:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            if sx and sy then
                lastDialogX = tonumber(sx)
                lastDialogY = tonumber(sy)
                lastDialogW = tonumber(sw) or 840
                lastDialogH = tonumber(sh) or 600

                -- Also update GUI table if it exists
                if GUI then
                    GUI.savedX = lastDialogX
                    GUI.savedY = lastDialogY
                    GUI.savedW = lastDialogW
                    GUI.savedH = lastDialogH
                end
            end
        end
        if GUI then
            GUI.windowPosLoaded = true
        end
    end

    local keepTempFiles = reaper.GetExtState(EXT_SECTION, "keepTempFiles")
    if keepTempFiles ~= "" then SETTINGS.keepTempFiles = (keepTempFiles == "1") end

    local device = reaper.GetExtState(EXT_SECTION, "device")
    if device ~= "" then SETTINGS.device = device end

    -- Load language setting and initialize i18n
    local language = reaper.GetExtState(EXT_SECTION, "language")
    if language ~= "" then SETTINGS.language = language end
    setLanguage(SETTINGS.language)

    -- Load stem selections
    for i, stem in ipairs(STEMS) do
        local sel = reaper.GetExtState(EXT_SECTION, "stem_" .. stem.name)
        if sel ~= "" then STEMS[i].selected = (sel == "1") end
    end

    -- Sanitize: if user is not on the 6-stem model, ensure 6-stem-only stems are not selected.
    -- (These can remain "on" from older saved settings, but they're not valid for 4-stem models.)
    if tostring(SETTINGS.model or "") ~= "htdemucs_6s" then
        for _, stem in ipairs(STEMS) do
            if stem.sixStemOnly then
                stem.selected = false
            end
        end
    end

    if ensureSelectedModelIsAvailable() and tostring(SETTINGS.model or "") ~= "htdemucs_6s" then
        for _, stem in ipairs(STEMS) do
            if stem.sixStemOnly then
                stem.selected = false
            end
        end
    end
end

-- Save settings to ExtState
saveSettings = function()
    -- Do NOT recapture geometry here. On OS-close (window manager X), the gfx
    -- window may already be invalid and return bogus 0,0 or outer-window sizes.
    -- Persist only the last known-good geometry that was captured while alive.

    reaper.SetExtState(EXT_SECTION, "model", SETTINGS.model, true)
    reaper.SetExtState(EXT_SECTION, "createNewTracks", SETTINGS.createNewTracks and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "createFolder", SETTINGS.createFolder and "1" or "0", true)
    SETTINGS.colorMode = normalizeColorMode(SETTINGS.colorMode)
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")
    reaper.SetExtState(EXT_SECTION, "applyTrackColors", SETTINGS.applyTrackColors and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "colorMode", SETTINGS.colorMode, true)
    reaper.SetExtState(EXT_SECTION, "stemFileDestination", tostring(SETTINGS.stemFileDestination or "temp"), true)
    reaper.SetExtState(EXT_SECTION, "customStemDir", tostring(SETTINGS.customStemDir or ""), true)
    reaper.SetExtState(EXT_SECTION, "postProcessTakes", tostring(SETTINGS.postProcessTakes or "none"), true)
    reaper.SetExtState(EXT_SECTION, "muteOriginal", SETTINGS.muteOriginal and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "muteSelection", SETTINGS.muteSelection and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "deleteOriginal", SETTINGS.deleteOriginal and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "deleteSelection", SETTINGS.deleteSelection and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "deleteOriginalTrack", SETTINGS.deleteOriginalTrack and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "darkMode", SETTINGS.darkMode and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "themePreset", tostring(SETTINGS.themePreset or "classic"), true)
    reaper.SetExtState(EXT_SECTION, "parallelProcessing", SETTINGS.parallelProcessing and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "visualFX", SETTINGS.visualFX and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "tooltips", SETTINGS.tooltips and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "keepTempFiles", SETTINGS.keepTempFiles and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "language", SETTINGS.language, true)
    reaper.SetExtState(EXT_SECTION, "device", SETTINGS.device, true)

    for _, stem in ipairs(STEMS) do
        reaper.SetExtState(EXT_SECTION, "stem_" .. stem.name, stem.selected and "1" or "0", true)
    end

    persistWindowPos()
end

-- Register exit function (now that saveSettings is defined)
reaper.atexit(saveSettings)

-- Preset functions
local function applyPresetKaraoke()
    -- Instrumental only (no vocals) - includes Guitar+Piano in 6-stem mode
    STEMS[1].selected = false  -- Vocals OFF
    STEMS[2].selected = true   -- Drums
    STEMS[3].selected = true   -- Bass
    STEMS[4].selected = true   -- Other
    if STEMS[5] then STEMS[5].selected = true end   -- Guitar (6-stem)
    if STEMS[6] then STEMS[6].selected = true end   -- Piano (6-stem)
end

local function applyPresetInstrumental()
    -- Same as karaoke but clearer name
    applyPresetKaraoke()
end

local function applyPresetDrumsOnly()
    STEMS[1].selected = false  -- Vocals
    STEMS[2].selected = true   -- Drums ONLY
    STEMS[3].selected = false  -- Bass
    STEMS[4].selected = false  -- Other
    if STEMS[5] then STEMS[5].selected = false end  -- Guitar
    if STEMS[6] then STEMS[6].selected = false end  -- Piano
end

local function applyPresetVocalsOnly()
    STEMS[1].selected = true   -- Vocals ONLY
    STEMS[2].selected = false  -- Drums
    STEMS[3].selected = false  -- Bass
    STEMS[4].selected = false  -- Other
    if STEMS[5] then STEMS[5].selected = false end  -- Guitar
    if STEMS[6] then STEMS[6].selected = false end  -- Piano
end

local function applyPresetBassOnly()
    STEMS[1].selected = false  -- Vocals
    STEMS[2].selected = false  -- Drums
    STEMS[3].selected = true   -- Bass ONLY
    STEMS[4].selected = false  -- Other
    if STEMS[5] then STEMS[5].selected = false end  -- Guitar
    if STEMS[6] then STEMS[6].selected = false end  -- Piano
end

local function applyPresetOtherOnly()
    STEMS[1].selected = false  -- Vocals
    STEMS[2].selected = false  -- Drums
    STEMS[3].selected = false  -- Bass
    STEMS[4].selected = true   -- Other ONLY
    if STEMS[5] then STEMS[5].selected = false end  -- Guitar
    if STEMS[6] then STEMS[6].selected = false end  -- Piano
end

local function applyPresetGuitarOnly()
    -- Only works with 6-stem model
    STEMS[1].selected = false  -- Vocals
    STEMS[2].selected = false  -- Drums
    STEMS[3].selected = false  -- Bass
    STEMS[4].selected = false  -- Other
    STEMS[5].selected = true   -- Guitar ONLY
    STEMS[6].selected = false  -- Piano
end

local function applyPresetPianoOnly()
    -- Only works with 6-stem model
    STEMS[1].selected = false  -- Vocals
    STEMS[2].selected = false  -- Drums
    STEMS[3].selected = false  -- Bass
    STEMS[4].selected = false  -- Other
    STEMS[5].selected = false  -- Guitar
    STEMS[6].selected = true   -- Piano ONLY
end

local function applyPresetAll()
    for i = 1, #STEMS do
        STEMS[i].selected = true
    end
end

local function rgbToReaperColor(r, g, b)
    return reaper.ColorToNative(r, g, b) | 0x1000000
end

-- Get monitor bounds at a specific screen position (for multi-monitor support)
-- Returns screenLeft, screenTop, screenRight, screenBottom
local function getMonitorBoundsAt(x, y)
    local screenLeft, screenTop, screenRight, screenBottom = nil, nil, nil, nil

    -- Ensure integer coordinates
    x = math.floor(x)
    y = math.floor(y)

    -- Method 1: SWS BR_Win32_GetMonitorRectFromRect (most reliable for multi-monitor)
    if reaper.BR_Win32_GetMonitorRectFromRect then
        local retval, mLeft, mTop, mRight, mBottom = reaper.BR_Win32_GetMonitorRectFromRect(true, x, y, x+1, y+1)
        if retval and mLeft and mTop and mRight and mBottom and mRight > mLeft and mBottom > mTop then
            return mLeft, mTop, mRight, mBottom
        end
    end

    -- Method 2: JS_Window API to find monitor from point
    if reaper.JS_Window_GetRect then
        local mainHwnd = reaper.GetMainHwnd()
        if mainHwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(mainHwnd)
            if retval and left and top and right and bottom then
                -- Check if mouse is within REAPER main window area
                if x >= left and x <= right and y >= top and y <= bottom then
                    screenLeft, screenTop = left, top
                    screenRight, screenBottom = right, bottom
                else
                    -- Mouse is on a different monitor - estimate based on mouse position
                    -- Assume standard monitor size around the mouse position
                    local monitorW, monitorH = 1920, 1080
                    screenLeft = math.floor(x / monitorW) * monitorW
                    screenTop = math.floor(y / monitorH) * monitorH
                    screenRight = screenLeft + monitorW
                    screenBottom = screenTop + monitorH
                end
            end
        end
    end

    -- Fallback: estimate monitor based on mouse position
    if not screenLeft then
        local monitorW, monitorH = 1920, 1080
        -- Handle negative coordinates (monitors to the left/above primary)
        if x >= 0 then
            screenLeft = math.floor(x / monitorW) * monitorW
        else
            screenLeft = math.floor((x + 1) / monitorW) * monitorW - monitorW
        end
        if y >= 0 then
            screenTop = math.floor(y / monitorH) * monitorH
        else
            screenTop = math.floor((y + 1) / monitorH) * monitorH - monitorH
        end
        screenRight = screenLeft + monitorW
        screenBottom = screenTop + monitorH
    end

    return screenLeft, screenTop, screenRight, screenBottom
end

-- Clamp window position to stay fully on screen
local function clampToScreen(winX, winY, winW, winH, refX, refY)
    local screenLeft, screenTop, screenRight, screenBottom = getMonitorBoundsAt(refX, refY)
    local margin = 20

    winX = math.max(screenLeft + margin, winX)
    winY = math.max(screenTop + margin, winY)
    winX = math.min(screenRight - winW - margin, winX)
    winY = math.min(screenBottom - winH - margin, winY)

    return winX, winY
end

GUI.getLiveGeometry = function(defaultW, defaultH)
    local winW = (lastDialogW and lastDialogW > 0) and lastDialogW or (defaultW or 840)
    local winH = (lastDialogH and lastDialogH > 0) and lastDialogH or (defaultH or 600)
    local winX, winY = lastDialogX, lastDialogY
    if not winX or not winY then
        local mouseX, mouseY = reaper.GetMousePosition()
        winX = mouseX - winW / 2
        winY = mouseY - winH / 2
        winX, winY = clampToScreen(winX, winY, winW, winH, mouseX, mouseY)
    end
    return winW, winH, winX, winY
end

GUI.applyLiveGeometry = function(defaultW, defaultH)
    local winW, winH, winX, winY = GUI.getLiveGeometry(defaultW, defaultH)
    lastDialogX, lastDialogY, lastDialogW, lastDialogH = winX, winY, winW, winH
    return winW, winH, winX, winY
end

GUI.snapshotMainGeometry = function()
    if lastDialogX and lastDialogY and lastDialogW and lastDialogH then
        GUI.mainSnapshot = {
            x = lastDialogX,
            y = lastDialogY,
            w = lastDialogW,
            h = lastDialogH,
        }
    else
        GUI.mainSnapshot = nil
    end
end

GUI.restoreMainSnapshot = function()
    if GUI.mainSnapshot then
        lastDialogX = GUI.mainSnapshot.x
        lastDialogY = GUI.mainSnapshot.y
        lastDialogW = GUI.mainSnapshot.w
        lastDialogH = GUI.mainSnapshot.h
    end
end

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
local messageWindowState = {
    title = "",
    message = "",
    icon = "info",  -- "info", "warning", "error"
    wasMouseDown = false,
    startTime = 0,
    monitorSelection = false,  -- When true, auto-close and open main dialog on selection
}

-- Forward declarations (functions defined later in file)
local main
local showMessage
local drawHelpQuickStartHeader
local drawHelpReaperHeader
local getRuntimeModeLabel
local buildFooterLines

-- STEM colors for window borders (used by all windows)
local STEM_BORDER_COLORS = {
    {255, 100, 100},  -- Red (Vocals)
    {100, 200, 255},  -- Blue (Drums)
    {150, 100, 255},  -- Purple (Bass)
    {100, 255, 150},  -- Green (Other)
}

-- Shared tooltip helpers (used across windows) --------------------------------
-- We keep tooltips consistent everywhere: wrapped text + stem-color top bar.
local function _wrapTextToWidth(text, maxWidth)
    -- Preserve explicit newlines and blank lines, but wrap long lines by words.
    local out = {}
    for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if raw == "" then
            out[#out + 1] = ""
        else
            local line = ""
            for word in raw:gmatch("%S+") do
                if line == "" then
                    line = word
                else
                    local candidate = line .. " " .. word
                    if gfx.measurestr(candidate) <= maxWidth then
                        line = candidate
                    else
                        out[#out + 1] = line
                        line = word
                    end
                end
            end
            if line ~= "" then out[#out + 1] = line end
        end
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    return out
end

-- Draw a tooltip box with stem-color top bar. Caller must set font before calling.
-- padding/lineH/maxTextW are already scaled (S/UI/PS).
local function drawTooltipStyled(tooltipText, tooltipX, tooltipY, winW, winH, padding, lineH, maxTextW)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end
    local text = tostring(tooltipText or "")
    if text == "" then return end

    local maxW = maxTextW or (winW * 0.62)
    maxW = math.max(50, math.min(maxW, winW - padding * 4))
    local lines = _wrapTextToWidth(text, maxW)
    if #lines == 0 then lines = {text} end

    local maxLineW = 0
    for _, ln in ipairs(lines) do
        local lw = gfx.measurestr(ln)
        if lw > maxLineW then maxLineW = lw end
    end

    local boxW = maxLineW + padding * 2
    local boxH = (#lines * lineH) + padding * 2

    local tx = tooltipX
    local ty = tooltipY
    if tx + boxW > winW then tx = winW - boxW - padding end
    if ty + boxH > winH then ty = tooltipY - boxH - padding * 2 end
    if tx < padding then tx = padding end
    if ty < padding then ty = padding end

    -- Background (theme-aware)
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.98)
    gfx.rect(tx, ty, boxW, boxH, 1)

    -- Colored top border (STEM colors gradient)
    for i = 0, boxW - 1 do
        local colorIdx = math.floor(i / boxW * 4) + 1
        colorIdx = math.min(4, math.max(1, colorIdx))
        local c = STEM_BORDER_COLORS[colorIdx]
        gfx.set(c[1]/255, c[2]/255, c[3]/255, 0.9)
        gfx.line(tx + i, ty, tx + i, ty + 2)
    end

    -- Border (theme-aware)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(tx, ty, boxW, boxH, 0)

    -- Text
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    local y = ty + padding
    for _, ln in ipairs(lines) do
        gfx.x = tx + padding
        gfx.y = y
        gfx.drawstr(ln)
        y = y + lineH
    end
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

    -- STEM colors for art
    local colors = {
        {1.0, 0.4, 0.4},   -- Vocals red
        {0.4, 0.8, 1.0},   -- Drums blue
        {0.6, 0.4, 1.0},   -- Bass purple
        {0.4, 1.0, 0.6},   -- Other green
    }

    -- Dark semi-transparent background for art area (unless caller handles it)
    if not skipBackground then
        gfx.set(0.05, 0.05, 0.08, 0.95)
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

-- Draw Art Gallery window - SPECTACULAR GRAPHICAL ANIMATIONS
local function drawArtGallery()
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

        local mouseInControls = (my < topControlArea) or (my > bottomY)
        helpState.targetControlsOpacity = mouseInControls and 1.0 or 0.0

        local fadeSpeed = mouseInControls and 0.25 or 0.08  -- Faster fade-in, slower fade-out
        helpState.controlsOpacity = helpState.controlsOpacity + (helpState.targetControlsOpacity - helpState.controlsOpacity) * fadeSpeed
        helpState.controlsOpacity = math.max(0, math.min(1, helpState.controlsOpacity))
        controlsOpacity = helpState.controlsOpacity
    end
    local tabs = {T("help_welcome"), T("help_quickstart"), T("help_stems"), T("help_reaper"), T("help_gallery"), T("help_about")}

    -- Reserve space for the top-right controls so tabs never overlap EN/FX.
    local iconScale = 0.66
    local themeSize = math.max(UI(14), math.floor(UI(24) * iconScale + 0.5))
    local themeX = w - themeSize - UI(10)
    local themeY = UI(6)

    local langCode = string.upper(SETTINGS.language or "EN")
    gfx.setfont(1, "Arial", UI(10), string.byte('b'))
    local langW = gfx.measurestr(langCode)
    local langX = themeX - langW - UI(12)

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
            gfx.set(0.3, 0.3, 0.35, bgAlpha)
        end
        gfx.rect(tabX, tabY, tabWidths[i], tabH, 1)

        -- Tab text
        local textAlpha = (isActive and 1 or 0.7) * controlsOpacity
        gfx.set(1, 1, 1, textAlpha)
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

    -- === THEME TOGGLE (top right) - uses UI(), does NOT zoom ===
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    if SETTINGS.darkMode then
        gfx.set(0.8, 0.8, 0.5, (themeHover and 1 or 0.7) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 3, 1, 1)
        gfx.set(0.12, 0.12, 0.14, controlsOpacity)
        gfx.circle(themeX + themeSize/2 + 4, themeY + themeSize/2 - 3, themeSize/2 - 5, 1, 1)
    else
        gfx.set(1.0, 0.8, 0.2, (themeHover and 1 or 0.85) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/3, 1, 1)
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local x1 = themeX + themeSize/2 + math.cos(angle) * (themeSize/3 + 2)
            local y1 = themeY + themeSize/2 + math.sin(angle) * (themeSize/3 + 2)
            local x2 = themeX + themeSize/2 + math.cos(angle) * (themeSize/2 - 1)
            local y2 = themeY + themeSize/2 + math.sin(angle) * (themeSize/2 - 1)
            gfx.line(x1, y1, x2, y2)
        end
    end

    -- Theme click handling and tooltip
    if themeHover and controlsOpacity > 0.3 then
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + UI(10), my + UI(15)
        if rightMouseDown and not helpState.wasRightMouseDown then
            cycleThemePreset()
        end
        if mouseDown and not helpState.wasMouseDown then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
    end

    -- === LANGUAGE TOGGLE (next to theme) - uses UI(), does NOT zoom ===
    local langCode = string.upper(SETTINGS.language or "EN")
    gfx.setfont(1, "Arial", UI(10), string.byte('b'))
    local langW = gfx.measurestr(langCode)
    local langX = themeX - langW - UI(12)
    local langY = themeY + UI(6)
    local langHover = mx >= langX - UI(4) and mx <= langX + langW + UI(4) and my >= langY - UI(3) and my <= langY + UI(16)

    -- Draw language badge background
    if langHover and controlsOpacity > 0.3 then
        gfx.set(0.3, 0.4, 0.6, 0.5 * controlsOpacity)
        gfx.rect(langX - UI(4), langY - UI(2), langW + UI(8), UI(18), 1)
    end
    gfx.set(0.5, 0.7, 1.0, (langHover and 1 or 0.75) * controlsOpacity)
    gfx.x = langX
    gfx.y = langY
    gfx.drawstr(langCode)

    -- Language tooltip
    if langHover and controlsOpacity > 0.3 then
        tooltipText = T("tooltip_change_language")
        tooltipX, tooltipY = mx + UI(10), my + UI(15)
    end

    if langHover and (gfx.mouse_cap & 2 == 2) and not helpState.wasRightMouseDown and controlsOpacity > 0.3 then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end

    if langHover and mouseDown and not helpState.wasMouseDown and controlsOpacity > 0.3 then
        local langs = {"en", "nl", "de"}
        local currentIdx = 1
        for i, l in ipairs(langs) do
            if l == SETTINGS.language then currentIdx = i break end
        end
        local nextIdx = (currentIdx % #langs) + 1
        setLanguage(langs[nextIdx])
        saveSettings()
    end

    -- === FX TOGGLE (below theme icon) - uses UI(), does NOT zoom ===
    local fxSize = math.max(UI(12), math.floor(UI(20) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2  -- Center under theme icon
    local fxY = themeY + themeSize + UI(4)
    local fxHover = mx >= fxX - UI(2) and mx <= fxX + fxSize + UI(2) and my >= fxY - UI(2) and my <= fxY + fxSize + UI(2)

    -- Draw FX icon (stylized "FX" text or sparkle icon)
    local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
    if SETTINGS.visualFX then
        -- FX enabled: bright colored
        gfx.set(0.4, 0.9, 0.5, fxAlpha)  -- Green when on
    else
        -- FX disabled: dim/grey
        gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6)
    end

    -- Draw "FX" text
    gfx.setfont(1, "Arial", math.max(UI(8), math.floor(UI(11) * iconScale + 0.5)), string.byte('b'))
    local fxText = "FX"
    local fxTextW = gfx.measurestr(fxText)
    gfx.x = fxX + (fxSize - fxTextW) / 2
    gfx.y = fxY + UI(2)
    gfx.drawstr(fxText)

    -- Draw sparkle/star decorations when enabled
    if SETTINGS.visualFX then
        gfx.set(1, 1, 0.5, fxAlpha * 0.8)  -- Yellow sparkles
        -- Small stars around FX
        local starSize = UI(2)
        gfx.circle(fxX - UI(2), fxY + UI(3), starSize, 1, 1)
        gfx.circle(fxX + fxSize + UI(1), fxY + fxSize - UI(3), starSize, 1, 1)
    else
        -- Draw strikethrough when disabled
        gfx.set(0.8, 0.3, 0.3, fxAlpha)
        gfx.line(fxX - UI(2), fxY + fxSize / 2, fxX + fxSize + UI(2), fxY + fxSize / 2)
    end

    -- FX tooltip
    if fxHover and controlsOpacity > 0.3 then
        tooltipText = SETTINGS.visualFX and T("fx_disable") or T("fx_enable")
        tooltipX, tooltipY = mx + UI(10), my + UI(15)
    end

    -- FX click handling
    if fxHover and mouseDown and not helpState.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
    end

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
            local offText = "Visual FX Off - Click FX to enable"
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

        -- Update audio reactivity
        updateAudioReactivity()
        local audioPeak = audioReactive.smoothPeakMono or 0
        local audioBass = audioReactive.smoothBass or 0
        local audioMid = audioReactive.smoothMid or 0
        local audioHigh = audioReactive.smoothHigh or 0
        local audioBeat = audioReactive.beatDecay or 0

        -- Animated background elements (behind text) - gated by FX toggle
        local bgTime = os.clock() - helpState.startTime
        if SETTINGS.visualFX then
            for i = 1, 4 do
                local angle = bgTime * 0.2 + (i - 1) * math.pi / 2 + audioPeak * 0.3
                local radius = math.min(w, h) * (0.4 + audioBass * 0.15)
                local cx = w / 2 + math.cos(angle) * radius * 0.4
                local cy = contentY + contentH / 2 + math.sin(angle) * radius * 0.3
                -- Larger, more visible background circles - pulse with audio
                local maxR = PS(120 + audioBass * 60)
                for r = maxR, PS(40), -PS(20) do
                    local alpha = 0.03 + (maxR - r) / PS(400) + audioBeat * 0.05
                    gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], math.min(0.3, alpha))
                    gfx.circle(cx, cy, r, 1, 1)
                end
            end

            -- Floating particles in background - AUDIO REACTIVE
            local particleCount = 20 + math.floor(audioPeak * 15)
            for i = 1, particleCount do
                local px = (math.sin(bgTime * 0.5 + i * 1.3 + audioHigh * 0.5) * 0.5 + 0.5) * w
                local py = contentY + ((math.cos(bgTime * 0.3 + i * 0.7 + audioMid * 0.3) * 0.5 + 0.5) * contentH * 0.8)
                local col = stemColors[(i % 4) + 1]
                local particleAlpha = 0.15 + audioBeat * 0.2
                local particleSize = PS(3 + (i % 4) + audioPeak * 4)
                gfx.set(col[1], col[2], col[3], math.min(0.5, particleAlpha))
                gfx.circle(px, py, particleSize, 1, 1)
            end

            -- Audio waveform ring in center (MilkDrop-style!)
            if audioPeak > 0.05 then
                local waveRadius = PS(80 + audioBass * 40)
                local wcx, wcy = w / 2, contentY + contentH / 2
                for i = 0, 59 do
                    local angle = (i / 60) * math.pi * 2
                    local waveVal = audioReactive.waveformHistory[((audioReactive.waveformIndex + i) % audioReactive.waveformSize) + 1] or audioPeak
                    local r = waveRadius * (1 + waveVal * 0.4)
                    local wx = wcx + math.cos(angle + bgTime * 0.5) * r
                    local wy = wcy + math.sin(angle + bgTime * 0.5) * r
                    local col = stemColors[(math.floor(i / 15) % 4) + 1]
                    gfx.set(col[1], col[2], col[3], 0.2 + waveVal * 0.3)
                    gfx.circle(wx, wy, PS(2 + waveVal * 4), 1, 1)
                end
            end
        end

        -- === TEXT CONTENT (drawn AFTER background) ===

        -- Large animated STEMwerk title (replaces old "STEMperator" typography)
        do
            local fontSize = PS(44)
            local titleW = measureStemwerkLogo(fontSize, "Arial", true)
            local titleX = (w - titleW) / 2 + textOffsetX
            local titleY = contentY + PS(12)
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
        gfx.setfont(1, "Arial", PS(16))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local welcomeSub = T("help_welcome_sub")
        local wsW = gfx.measurestr(welcomeSub)
        gfx.x = (w - wsW) / 2 + textOffsetX
        gfx.y = contentY + PS(60)
        gfx.drawstr(welcomeSub)

        -- Divider line
        gfx.set(0.4, 0.4, 0.5, 0.5)
        gfx.line(w * 0.2 + textOffsetX, contentY + PS(85), w * 0.8 + textOffsetX, contentY + PS(85))

        -- Features list - LARGER and more descriptive
        local features = {
            {icon = "♪", color = stemColors[1], title = T("help_feature_vocals"), desc = "Lead vocals, backing vocals, speech"},
            {icon = "●", color = stemColors[2], title = T("help_feature_drums"), desc = "Kick, snare, hi-hats, percussion"},
            {icon = "≡", color = stemColors[3], title = T("help_feature_bass"), desc = "Bass guitar, synth bass, low frequencies"},
            {icon = "✦", color = stemColors[4], title = T("help_feature_other"), desc = "Guitar, keys, strings, synths, effects"},
        }
        local featureY = contentY + PS(100)
        local featureSpacing = PS(50)
        local leftCol = PS(40) + textOffsetX

        for i, feat in ipairs(features) do
            -- Colored icon/badge
            gfx.set(feat.color[1], feat.color[2], feat.color[3], 0.9)
            gfx.circle(leftCol + PS(15), featureY + PS(12), PS(18), 1, 1)

            -- Feature title (theme-aware)
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            gfx.setfont(1, "Arial", PS(16), string.byte('b'))
            gfx.x = leftCol + PS(45)
            gfx.y = featureY
            gfx.drawstr(feat.title)

            -- Feature description (theme-aware)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.9)
            gfx.setfont(1, "Arial", PS(13))
            gfx.x = leftCol + PS(45)
            gfx.y = featureY + PS(22)
            gfx.drawstr(feat.desc)

            featureY = featureY + featureSpacing
        end

        -- Version removed from Welcome (requested).

    elseif helpState.currentTab == 2 then
        -- === QUICK START TAB + AUDIO REACTIVE ===

        -- Add subtle procedural art background (requested) - gated by FX toggle
        if SETTINGS.visualFX then
            local artAreaY = UI(40)
            local artAreaH = h - artAreaY - UI(50)
            drawProceduralArtInternal(0, artAreaY, w, artAreaH, time * 0.6, 0, true, 0.22)
        end

        -- Update audio reactivity
        updateAudioReactivity()
        local audioPeak = audioReactive.smoothPeakMono or 0
        local audioBass = audioReactive.smoothBass or 0
        local audioMid = audioReactive.smoothMid or 0
        local audioHigh = audioReactive.smoothHigh or 0
        local audioBeat = audioReactive.beatDecay or 0

        -- Flowing steps background animation (gated by FX toggle)
        local bgTime = os.clock() - helpState.startTime
        if SETTINGS.visualFX then
            -- Flowing number particles (1, 2, 3) - AUDIO REACTIVE
            local stepNums = {"1", "2", "3"}
            local numCount = 25 + math.floor(audioPeak * 10)
            for i = 1, numCount do
                local numIdx = ((i - 1) % 3) + 1
                local num = stepNums[numIdx]

                -- Gentle floating motion - audio reactive
                local floatPhase = bgTime * (0.8 + audioMid * 0.4) + i * 0.7
                local fx = w * (i / (numCount + 1)) + math.sin(floatPhase * 0.6 + i) * PS(40 + audioBass * 30)
                local fy = contentY + (contentH * 0.5) + math.cos(floatPhase * 0.4 + i * 0.5) * PS(80 + audioHigh * 40)

                -- Size pulses with audio
                local fsize = PS(30 + math.sin(floatPhase) * 15 + audioPeak * 20)
                gfx.setfont(1, "Arial", fsize, string.byte('b'))

                -- Subtle color with audio-reactive alpha
                local falpha = 0.04 + math.sin(floatPhase * 2) * 0.02 + audioBeat * 0.08
                gfx.set(stemColors[numIdx][1], stemColors[numIdx][2], stemColors[numIdx][3], math.min(0.25, falpha))

                local fw = gfx.measurestr(num)
                gfx.x = fx - fw / 2
                gfx.y = fy - fsize / 2
                gfx.drawstr(num)
            end

            -- Connecting dotted paths - AUDIO REACTIVE
            for i = 1, 8 do
                local pathPhase = bgTime * (0.5 + audioMid * 0.3) + i * 0.9
                local dotCount = 12 + math.floor(audioPeak * 6)
                for dot = 1, dotCount do
                    local dotPhase = pathPhase + dot * 0.2
                    local dotX = w * 0.2 + (w * 0.6) * (dot / dotCount) + math.sin(dotPhase) * PS(20 + audioHigh * 15)
                    local dotY = contentY + contentH * 0.3 + i * PS(30) + math.cos(dotPhase * 1.3) * PS(15 + audioBass * 20)

                    local dotAlpha = 0.03 + math.sin(dotPhase * 3) * 0.015 + audioBeat * 0.04
                    local colorIdx = ((dot - 1) % 3) + 1
                    local dotSize = PS(2 + math.sin(dotPhase * 2) * 1 + audioPeak * 2)
                    gfx.set(stemColors[colorIdx][1], stemColors[colorIdx][2], stemColors[colorIdx][3], math.min(0.15, dotAlpha))
                    gfx.circle(dotX, dotY, dotSize, 1, 1)
                end
            end

            -- Audio waveform visualization (subtle, behind content)
            if audioPeak > 0.05 then
                local waveY = contentY + contentH * 0.85
                local waveW = w * 0.8
                local waveX = w * 0.1
                for i = 0, 59 do
                    local histIdx = ((audioReactive.waveformIndex or 1) + i * 2) % (audioReactive.waveformSize or 60) + 1
                    local waveVal = (audioReactive.waveformHistory and audioReactive.waveformHistory[histIdx]) or audioPeak * 0.3
                    local wx = waveX + (i / 60) * waveW
                    local wh = waveVal * PS(30)
                    local colorIdx = (math.floor(i / 15) % 3) + 1
                    gfx.set(stemColors[colorIdx][1], stemColors[colorIdx][2], stemColors[colorIdx][3], 0.1 + waveVal * 0.15)
                    gfx.rect(wx, waveY - wh/2, PS(4), wh, 1)
                end
            end
        end

        drawHelpQuickStartHeader(w, contentY, textOffsetX, PS)

        local panelX = PS(30) + textOffsetX
        local panelY = contentY + PS(70) + textOffsetY
        local panelW = w - PS(60)
        local panelH = h - panelY - UI(60)

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
        gfx.set(stemColors[4][1], stemColors[4][2], stemColors[4][3], blink)
        local ptW = gfx.measurestr(proTipText)
        gfx.x = (w - ptW) / 2 + textOffsetX
        gfx.y = panelY + panelH - PS(30)
        gfx.drawstr(proTipText)

    elseif helpState.currentTab == 3 then
        -- === STEMS TAB - COMPREHENSIVE STEM INFO ===

        -- Update audio reactivity for sound-driven animation
        updateAudioReactivity()

        -- Animated background (gated by FX toggle)
        if SETTINGS.visualFX then
            -- SUPER FREAKY STEM letter morphing background (now audio-reactive!)
            local bgTime = os.clock() - helpState.startTime
            local stemLettersBg = {"S", "T", "E", "M"}

            -- Audio reactive values (use smoothed values for animation)
            local audioPeak = audioReactive.smoothPeakMono
            local audioBass = audioReactive.smoothBass
            local audioMid = audioReactive.smoothMid
            local audioHigh = audioReactive.smoothHigh
            local audioBeat = audioReactive.beatDecay

            -- === PSYCHEDELIC PLASMA WAVES ===
            local vortexCenterX = w / 2
            local vortexCenterY = contentY + contentH / 2

            -- Rainbow color cycling function
            local function rainbowColor(phase, baseColor)
                local hueShift = math.sin(phase) * 0.3
                local r = baseColor[1] + math.sin(phase) * 0.3
                local g = baseColor[2] + math.sin(phase + 2.1) * 0.3
                local b = baseColor[3] + math.sin(phase + 4.2) * 0.3
                return math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b))
            end

            -- === HYPNOTIC SPIRALING VORTEX (audio-reactive!) ===
            -- NOTE: Big animated letters were replaced with abstract dots for readability.
            for ring = 1, 7 do
                for i = 1, 12 do
                    local letterIdx = ((i - 1) % 4) + 1

                    -- Warped spiral motion with breathing + AUDIO REACTIVE
                    local breathe = 1 + math.sin(bgTime * 2) * 0.2 + audioBass * 0.4
                    local angle = bgTime * (0.5 + ring * 0.15 + audioPeak * 0.3) + (i - 1) * (math.pi / 6) + ring * 0.7
                    local warpAngle = angle + math.sin(bgTime * 3 + ring) * 0.5 + audioHigh * 0.3
                    local radius = (PS(40 + ring * 35) + math.sin(bgTime * 2.5 + ring * 0.8) * PS(30) + audioBass * PS(40)) * breathe

                    local lx = vortexCenterX + math.cos(warpAngle) * radius
                    local ly = vortexCenterY + math.sin(warpAngle) * radius * 0.5

                    -- Trippy size pulsation + AUDIO BOOST
                    local sizePulse = math.sin(bgTime * 4 + i * 0.5 + ring) * 0.5 + 0.5
                    local dotSize = PS(25 + ring * 12 + sizePulse * 20 + audioPeak * 15)

                    -- Color cycling with phase shift + BEAT FLASH
                    local colorPhase = bgTime * 2 + ring * 0.5 + i * 0.3 + audioPeak * 2
                    local r, g, b = rainbowColor(colorPhase, stemColors[letterIdx])
                    local lalpha = (0.15 - ring * 0.015) * (0.7 + math.sin(bgTime * 3 + i) * 0.3) + audioBeat * 0.15
                    gfx.set(r, g, b, math.min(1, lalpha))

                    gfx.circle(lx, ly, math.max(PS(2), dotSize * 0.14), 1, 1)
                end
            end

            -- === MATRIX RAIN with color trails (audio-reactive!) ===
            -- NOTE: Big animated letters were replaced with abstract dots for readability.
            for i = 1, 30 do
                local letterIdx = ((i - 1) % 4) + 1

                -- Cascading fall with wave distortion + AUDIO SPEED BOOST
                local fallSpeed = (0.4 + (i % 7) * 0.08) * (1 + audioMid * 0.5)
                local waveX = math.sin(bgTime * 2 + i * 0.3) * PS(50) * (1 + audioHigh * 0.5)
                local fallY = contentY + ((bgTime * fallSpeed * 120 + i * 40) % contentH)
                local driftX = w * (i / 31) + waveX

                local rainSize = PS(18 + (i % 4) * 10 + audioPeak * 8)

                -- Pulsing fade with color shift + BEAT BRIGHTNESS
                local fadeProgress = (fallY - contentY) / contentH
                local rainAlpha = (0.06 + audioBeat * 0.08) * math.sin(fadeProgress * math.pi) * (1 + math.sin(bgTime * 5 + i) * 0.3)

                local r, g, b = rainbowColor(bgTime * 3 + i * 0.5 + audioPeak * 2, stemColors[letterIdx])
                gfx.set(r, g, b, math.min(1, rainAlpha))
                gfx.circle(driftX, fallY, math.max(PS(1), rainSize * 0.12), 1, 1)
            end

            -- === ETHEREAL CORNER ORBS (audio-reactive!) ===
            local corners = {
                {x = PS(60), y = contentY + PS(40), idx = 1},
                {x = w - PS(60), y = contentY + PS(40), idx = 2},
                {x = PS(60), y = contentY + contentH - PS(50), idx = 3},
                {x = w - PS(60), y = contentY + contentH - PS(50), idx = 4},
            }
            for _, corner in ipairs(corners) do
                local cphase = bgTime * 1.5 + corner.idx * 1.5

                -- Soft pulsing rings + AUDIO EXPANSION
                for ring = 4, 1, -1 do
                    local ringPhase = cphase + ring * 0.4
                    local ringRadius = PS(15 + ring * 12 + math.sin(ringPhase) * 8) * (1 + audioBass * 0.4)
                    local ringAlpha = (0.03 / ring * (0.8 + math.sin(ringPhase * 2) * 0.2)) + audioBeat * 0.02

                    local r, g, b = rainbowColor(ringPhase + audioPeak, stemColors[corner.idx])
                    gfx.set(r, g, b, math.min(0.3, ringAlpha))
                    gfx.circle(corner.x, corner.y, ringRadius, 0, 1)
                end

                -- Glowing core + BEAT PULSE
                local coreAlpha = 0.06 + math.sin(cphase * 3) * 0.03 + audioBeat * 0.15
                local coreSize = PS(4 + math.sin(cphase * 2) * 2 + audioPeak * 6)
                local r, g, b = rainbowColor(cphase * 2 + audioPeak * 2, stemColors[corner.idx])
                gfx.set(r, g, b, math.min(0.5, coreAlpha))
                gfx.circle(corner.x, corner.y, coreSize, 1, 1)
            end

            -- === LASER BEAMS (audio-reactive!) ===
            for i = 1, 6 do
                local phase1 = bgTime * 0.8 + i * 1.05 + audioHigh * 0.5
                local phase2 = bgTime * 0.8 + ((i % 6) + 1) * 1.05 + audioHigh * 0.5

                local radius1 = PS(120 + math.sin(phase1 * 2) * 40 + audioBass * 60)
                local radius2 = PS(120 + math.sin(phase2 * 2) * 40 + audioBass * 60)
                local x1 = vortexCenterX + math.cos(phase1) * radius1
                local y1 = vortexCenterY + math.sin(phase1) * radius1 * 0.5
                local x2 = vortexCenterX + math.cos(phase2 + math.pi/3) * radius2
                local y2 = vortexCenterY + math.sin(phase2 + math.pi/3) * radius2 * 0.5

                local lineAlpha = 0.08 + math.sin(bgTime * 4 + i) * 0.04 + audioBeat * 0.15
                local colorIdx = ((i - 1) % 4) + 1
                local r, g, b = rainbowColor(bgTime * 2 + i + audioPeak * 3, stemColors[colorIdx])
                gfx.set(r, g, b, math.min(0.5, lineAlpha))
                gfx.line(x1, y1, x2, y2)
                -- Double line for glow effect
                gfx.set(r, g, b, math.min(0.25, lineAlpha * 0.5))
                gfx.line(x1 + 1, y1 + 1, x2 + 1, y2 + 1)
            end

            -- === FLOATING PARTICLES (audio-reactive!) ===
            for i = 1, 15 do
                local pphase = bgTime * 1.5 + i * 0.8
                local px = vortexCenterX + math.sin(pphase * 0.7 + i) * PS(150 + audioBass * 50)
                local py = vortexCenterY + math.cos(pphase * 0.5 + i * 0.5) * PS(80 + audioMid * 30)
                local psize = PS(8 + math.sin(pphase * 3) * 4 + audioPeak * 8)

                local colorIdx = ((i - 1) % 4) + 1
                local r, g, b = rainbowColor(pphase * 2 + audioPeak * 2, stemColors[colorIdx])
                local palpha = 0.15 + math.sin(pphase * 4) * 0.1 + audioBeat * 0.2
                gfx.set(r, g, b, math.min(0.6, palpha))
                gfx.circle(px, py, psize, 1, 1)
            end

            -- === MILKDROP FEEDBACK TUNNEL (zooming concentric shapes) ===
            local tunnelRings = 10
            for ring = tunnelRings, 1, -1 do
                local ringPhase = (bgTime * 0.8 + ring * 0.12) % 1
                local ringRadius = (1 - ringPhase) * math.min(w, contentH) * 0.6

                -- Warp distortion based on audio
                local warpAmt = 0.15 + audioMid * 0.25
                local sides = 4 + (ring % 3)  -- Varying polygon sides

                local col = stemColors[(ring % 4) + 1]
                local r, g, b = rainbowColor(bgTime * 2 + ring * 0.4 + audioPeak * 3, col)
                local alpha = ringPhase * 0.12 + audioBeat * 0.08
                gfx.set(r, g, b, math.min(0.4, alpha))

                -- Draw warped polygon
                for j = 0, sides do
                    local angle1 = (j / sides) * math.pi * 2 + bgTime * 0.3
                    local angle2 = ((j + 1) / sides) * math.pi * 2 + bgTime * 0.3
                    local warp1 = 1 + math.sin(angle1 * 3 + bgTime * 2) * warpAmt * (1 + audioBass * 0.5)
                    local warp2 = 1 + math.sin(angle2 * 3 + bgTime * 2) * warpAmt * (1 + audioBass * 0.5)

                    local x1 = vortexCenterX + math.cos(angle1) * ringRadius * warp1
                    local y1 = vortexCenterY + math.sin(angle1) * ringRadius * warp1 * 0.6
                    local x2 = vortexCenterX + math.cos(angle2) * ringRadius * warp2
                    local y2 = vortexCenterY + math.sin(angle2) * ringRadius * warp2 * 0.6

                    gfx.line(x1, y1, x2, y2)
                end
            end

            -- === MILKDROP PLASMA WAVES (horizontal sine interference) ===
            local plasmaRows = 8
            for row = 1, plasmaRows do
                local rowY = contentY + (row / (plasmaRows + 1)) * contentH
                local rowPhase = bgTime * 1.5 + row * 0.4

                for i = 0, w, PS(8) do
                    local t = i / w
                    -- Multiple sine waves combined (plasma effect)
                    local wave1 = math.sin(t * 8 + rowPhase + audioBass * 2) * PS(15)
                    local wave2 = math.sin(t * 12 - rowPhase * 1.3 + audioMid) * PS(10)
                    local wave3 = math.sin(t * 4 + rowPhase * 0.7 + audioHigh * 3) * PS(20)
                    local combinedWave = (wave1 + wave2 + wave3) * (0.5 + audioPeak * 0.5)

                    local px = i
                    local py = rowY + combinedWave

                    -- Color based on wave height
                    local colorPhase = bgTime * 2 + t * 4 + combinedWave * 0.02
                    local colorIdx = ((row - 1) % 4) + 1
                    local r, g, b = rainbowColor(colorPhase, stemColors[colorIdx])
                    local alpha = 0.06 + math.abs(combinedWave) * 0.002 + audioBeat * 0.04
                    gfx.set(r, g, b, math.min(0.25, alpha))
                    gfx.circle(px, py, PS(2 + audioPeak * 2), 1, 1)
                end
            end

            -- === MILKDROP AUDIO SCOPE (waveform display) ===
            if audioPeak > 0.03 then
                local scopeY = vortexCenterY
                local scopeW = w * 0.7
                local scopeX = (w - scopeW) / 2
                local scopeH = PS(60 + audioBass * 40)

                -- Draw waveform from history buffer
                local prevX, prevY
                local points = audioReactive.waveformSize or 60
                for i = 0, points - 1 do
                    local histIdx = ((audioReactive.waveformIndex or 1) + i) % points + 1
                    local waveVal = (audioReactive.waveformHistory and audioReactive.waveformHistory[histIdx]) or 0

                    local sx = scopeX + (i / points) * scopeW
                    local sy = scopeY + waveVal * scopeH * (0.5 + audioHigh * 0.5)

                    local colorIdx = (math.floor(i / (points / 4)) % 4) + 1
                    local r, g, b = rainbowColor(bgTime * 3 + i * 0.1, stemColors[colorIdx])
                    local alpha = 0.15 + waveVal * 0.3 + audioBeat * 0.1
                    gfx.set(r, g, b, math.min(0.5, alpha))

                    if prevX then
                        gfx.line(prevX, prevY, sx, sy)
                    end
                    prevX, prevY = sx, sy

                    -- Glow dots at peaks
                    if waveVal > 0.3 then
                        gfx.set(r, g, b, alpha * 0.5)
                        gfx.circle(sx, sy, PS(3 + waveVal * 4), 1, 1)
                    end
                end
            end

            -- === MILKDROP MOTION VECTORS (trailing lines) ===
            local mvCount = 12
            for i = 1, mvCount do
                local mvPhase = bgTime * 0.6 + i * 0.52
                local startAngle = (i / mvCount) * math.pi * 2 + bgTime * 0.2
                local mvLen = PS(40 + audioBass * 60 + math.sin(mvPhase * 2) * 20)

                local startR = PS(50 + audioMid * 30)
                local sx = vortexCenterX + math.cos(startAngle) * startR
                local sy = vortexCenterY + math.sin(startAngle) * startR * 0.5
                local ex = sx + math.cos(startAngle + math.sin(mvPhase) * 0.5) * mvLen
                local ey = sy + math.sin(startAngle + math.sin(mvPhase) * 0.5) * mvLen * 0.5

                local colorIdx = ((i - 1) % 4) + 1
                local r, g, b = rainbowColor(mvPhase * 2 + audioPeak * 2, stemColors[colorIdx])

                -- Draw motion trail with fade
                for trail = 0, 4 do
                    local trailAlpha = (0.08 - trail * 0.015) * (1 + audioBeat * 0.5)
                    local trailOffset = trail * PS(3)
                    gfx.set(r, g, b, math.min(0.3, trailAlpha))
                    gfx.line(sx - trailOffset, sy, ex - trailOffset, ey)
                end
            end

            -- === BEAT FLASH OVERLAY (on strong beats) ===
            if audioBeat > 0.3 then
                local flashAlpha = audioBeat * 0.08
                gfx.set(1, 1, 1, flashAlpha)
                gfx.rect(0, contentY, w, contentH, 1)
            end

            -- === BEAT COLOR INVERSION (MilkDrop hardcut style) ===
            if audioBeat > 0.6 then
                -- Brief inverted color flash on strong beats
                local invAlpha = (audioBeat - 0.6) * 0.15
                if SETTINGS.darkMode then
                    gfx.set(1, 1, 1, invAlpha)
                else
                    gfx.set(0, 0, 0, invAlpha)
                end
                gfx.rect(0, contentY, w, contentH, 1)
            end
        end

        -- Title (theme-aware)
        gfx.setfont(1, "Arial", PS(28), string.byte('b'))
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        local stemTitle = T("help_stems_title")
        local stW = gfx.measurestr(stemTitle)
        gfx.x = (w - stW) / 2 + textOffsetX
        gfx.y = contentY + PS(10)
        gfx.drawstr(stemTitle)

        -- Subtitle (translated, theme-aware)
        gfx.setfont(1, "Arial", PS(13))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local subText = T("help_stems_sub")
        local subW = gfx.measurestr(subText)
        gfx.x = (w - subW) / 2 + textOffsetX
        gfx.y = contentY + PS(42)
        gfx.drawstr(subText)

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

        local stemY = contentY + PS(70)
        local cardH = PS(65)
        local cardGap = PS(10)

        for i, stem in ipairs(stems) do
            -- Color accent bar on left (no card background)
            gfx.set(stem.color[1], stem.color[2], stem.color[3], 1)
            gfx.rect(PS(25) + textOffsetX, stemY, PS(8), cardH, 1)

            -- Stem icon circle
            gfx.set(stem.color[1], stem.color[2], stem.color[3], 0.9)
            gfx.circle(PS(60) + textOffsetX, stemY + cardH/2, PS(20), 1, 1)

            -- Letter in circle (always white for contrast on colored circle)
            gfx.set(1, 1, 1, 1)
            gfx.setfont(1, "Arial", PS(16), string.byte('b'))
            local letter = stem.name:sub(1, 1)
            local lW = gfx.measurestr(letter)
            gfx.x = PS(60) + textOffsetX - lW/2
            gfx.y = stemY + cardH/2 - PS(9)
            gfx.drawstr(letter)

            -- Stem name - darker in light mode for readability
            if SETTINGS.darkMode then
                gfx.set(stem.color[1], stem.color[2], stem.color[3], 1)
            else
                gfx.set(stem.color[1] * 0.7, stem.color[2] * 0.7, stem.color[3] * 0.7, 1)
            end
            gfx.setfont(1, "Arial", PS(18), string.byte('b'))
            gfx.x = PS(95) + textOffsetX
            gfx.y = stemY + PS(8)
            gfx.drawstr(stem.name)

            -- Contains description (theme-aware)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.setfont(1, "Arial", PS(12))
            gfx.x = PS(95) + textOffsetX
            gfx.y = stemY + PS(28)
            gfx.drawstr(stem.desc)

            -- Use cases (if space) (theme-aware)
            if contentH > PS(350) then
                gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.9)
                gfx.setfont(1, "Arial", PS(10))
                gfx.x = PS(95) + textOffsetX
                gfx.y = stemY + PS(45)
                gfx.drawstr(stem.uses)
            end

            stemY = stemY + cardH + cardGap
        end

        -- 6-stem model note (translated, better styled)
        if contentH > PS(400) then
            -- Blinking indicator
            local blink6 = 0.7 + math.sin(time * 3) * 0.3
            gfx.setfont(1, "Arial", PS(13), string.byte('b'))
            gfx.set(stemColors[4][1], stemColors[4][2], stemColors[4][3], blink6)
            local model6Title = T("help_6stem_title")
            local m6W = gfx.measurestr(model6Title)
            gfx.x = (w - m6W) / 2 + textOffsetX
            gfx.y = stemY + PS(10)
            gfx.drawstr(model6Title)

            gfx.setfont(1, "Arial", PS(11))
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            local model6Desc = T("help_6stem_desc")
            local m6dW = gfx.measurestr(model6Desc)
            gfx.x = (w - m6dW) / 2 + textOffsetX
            gfx.y = stemY + PS(28)
            gfx.drawstr(model6Desc)
        end

    elseif helpState.currentTab == 4 then
        -- === REAPER FILES TAB ===

        -- Subtle procedural art background (gated by FX toggle)
        if SETTINGS.visualFX then
            local artAreaY = UI(40)
            local artAreaH = h - artAreaY - UI(50)
            drawProceduralArt(0, artAreaY, w, artAreaH, time, 0, true)
        end

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

        drawHelpReaperHeader(w, contentY, textOffsetX, textOffsetY, PS)

        local panelX = PS(30) + textOffsetX
        local panelY = contentY + PS(70) + textOffsetY
        local panelW = w - PS(60)
        local panelH = h - panelY - UI(60)

        local sectionX = panelX + PS(15)
        local sectionY = panelY + PS(15)
        local maxW = panelW - PS(30)

        local reaperHelpFallbacks = {
            help_reaper_selection_title = "Selection & Items",
            help_reaper_selection_body = "STEMwerk uses selected items or tracks. If nothing is selected, make a time selection.",
            help_reaper_temp_title = "Temp Files",
            help_reaper_temp_body = "Temporary audio is stored during processing. You can keep or delete it in the Output options.",
            help_reaper_logs_title = "Logs",
            help_reaper_logs_body = "Processing logs are saved in the runtime state folder for troubleshooting.",
            help_reaper_cleanup_title = "Cleanup",
            help_reaper_cleanup_body = "Cleanup options control what happens to the original items and temporary files.",
        }

        local function drawHelpSection(titleKey, bodyKey)
            local title = getLangText(titleKey, reaperHelpFallbacks[titleKey])
            local body = getLangText(bodyKey, reaperHelpFallbacks[bodyKey] or "")
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
            sectionY = sectionY + PS(12)
        end

        drawHelpSection("help_reaper_selection_title", "help_reaper_selection_body")
        drawHelpSection("help_reaper_temp_title", "help_reaper_temp_body")
        drawHelpSection("help_reaper_logs_title", "help_reaper_logs_body")
        drawHelpSection("help_reaper_cleanup_title", "help_reaper_cleanup_body")

    elseif helpState.currentTab == 6 then
        -- === ABOUT TAB ===
        -- Fullscreen procedural art background with zoom/pan (like Gallery)
        local tabAreaH = UI(40)

        -- Define art display area (below tabs)
        local artX = 0
        local artY = tabAreaH
        local artW = w
        local artH = h - tabAreaH - UI(50)  -- Leave room for close button

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
        local contentY = tabAreaH + PS(30) + textOffsetY

        -- Title (big animated STEMwerk)
        do
            local fontSize = PS(34)
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

        contentY = contentY + PS(36)

        -- Subtitle
        gfx.setfont(1, "Arial", PS(12))
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        local subtitle = T("about_subtitle")
        local subW = gfx.measurestr(subtitle)
        gfx.x = centerX - subW / 2
        gfx.y = contentY
        gfx.drawstr(subtitle)

        contentY = contentY + PS(24)
        -- Give the tab title/subtitle area a bit more breathing room before "Features".
        contentY = contentY + PS(10)

        -- (Credits moved to bottom corners - see after content section)

        -- Features section
        gfx.setfont(1, "Arial", PS(12), string.byte('b'))
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        local featuresTitle = T("about_features_title")
        local ftW = gfx.measurestr(featuresTitle)
        gfx.x = centerX - ftW / 2
        gfx.y = contentY
        gfx.drawstr(featuresTitle)

        contentY = contentY + PS(20)

        -- Feature list (centered per line)
        gfx.setfont(1, "Arial", PS(10))
        local features = {
            {color = stemColors[1], text = T("about_feature_1")},
            {color = stemColors[2], text = T("about_feature_2")},
            {color = stemColors[3], text = T("about_feature_3")},
            {color = stemColors[4], text = T("about_feature_4")},
            {color = stemColors[5], text = T("about_feature_5")},
        }

        local bullet = "●"
        local bulletW = gfx.measurestr(bullet)
        local gap = PS(10)

        for _, feat in ipairs(features) do
            local textW = gfx.measurestr(feat.text)
            local lineW = bulletW + gap + textW
            local x0 = centerX - lineW / 2
            gfx.set(feat.color[1], feat.color[2], feat.color[3], 0.8)
            gfx.x = x0
            gfx.y = contentY
            gfx.drawstr(bullet)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = x0 + bulletW + gap
            gfx.drawstr(feat.text)
            contentY = contentY + PS(16)
        end

        contentY = contentY + PS(20)

        -- (Tip removed; replaced by tooltip on the help hint icon)

        -- Bottom credits (left/right corners)
        do
            -- Place credits flush at the very bottom edge of the window.
            local creditY = h - UI(18)
            gfx.setfont(1, "Arial", UI(10))

            -- Left: Conceived by flarkAUDIO
            local conceivedBy = (T("about_conceived") or "by") .. " "
            gfx.x = UI(6)
            gfx.y = creditY
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.85)
            gfx.drawstr(conceivedBy)
            local prefixW = gfx.measurestr(conceivedBy)
            gfx.x = UI(6) + prefixW
            gfx.y = creditY
            gfx.set(1.0, 0.5, 0.3, 0.95)  -- flark orange
            gfx.drawstr("flarkAUDIO")

            -- Right: Powered by Meta's Demucs
            local poweredBy = (T("about_powered_by") or "Powered by") .. " "
            local demucsName = (T("about_demucs") or "Meta's Demucs")
            gfx.setfont(1, "Arial", UI(10))
            local poweredW = gfx.measurestr(poweredBy)
            local demucsW = gfx.measurestr(demucsName)
            local totalW = poweredW + demucsW
            local x0 = w - totalW - UI(12)
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
            local tabAreaBottom = UI(40)
            local closeBtnTop = h - UI(50)
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

    local backR, backG, backB = 0.5, 0.2, 0.2
    if closeHover then
        backR, backG, backB = 0.9, 0.3, 0.3
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
            hintY = btnY - UI(22)
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

-- Update lastDialogX/Y/W/H from the current gfx window using a consistent
-- geometry model. The key rule is: store the same kind of size that gfx.init()
-- expects on reopen. Using JS_Window_GetRect() width/height (outer frame size)
-- mixed with gfx.w/gfx.h (client/framebuffer size) causes "window creep".
local function estimateTitlebarHeight()
    if OS == "Windows" then return 30 end
    if OS == "macOS" then return 24 end
    return 28
end

local function isGfxWindowVisible()
    if not (gfx and gfx.getchar) then return true end
    local ok, flags = pcall(gfx.getchar, 65537)
    if not ok or type(flags) ~= "number" then return true end
    if flags < 0 then return false end
    -- Only trust the visibility bit when present.
    if flags > 255 and (flags & 4) ~= 4 then return false end
    return true
end

local function rememberDialogGeometry(x, y, w, h)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    if not x or not y or not w or not h then return false end
    if w <= 0 or h <= 0 then return false end

    x = math.floor(x)
    y = math.floor(y)
    w = math.floor(w)
    h = math.floor(h)

    -- Ignore the classic late-close bogus reset to 0,0 if we already had a
    -- more plausible previous position.
    if x == 0 and y == 0 and lastDialogX and lastDialogY and (lastDialogX ~= 0 or lastDialogY ~= 0) then
        return false
    end

    lastDialogX = x
    lastDialogY = y
    lastDialogW = w
    lastDialogH = h
    return true
end

local function rememberDialogGeometryFromRect(left, top, right, bottom)
    -- Keep X/Y from the native window rect, but prefer gfx.w/gfx.h for W/H so
    -- we store the same client/framebuffer size that gfx.init() expects.
    local w = (gfx and gfx.w and gfx.w > 0) and gfx.w or ((lastDialogW and lastDialogW > 0) and lastDialogW or ((right and left) and (right - left) or nil))
    local h = (gfx and gfx.h and gfx.h > 0) and gfx.h or ((lastDialogH and lastDialogH > 0) and lastDialogH or ((bottom and top) and (bottom - top) or nil))
    return rememberDialogGeometry(left, top, w, h)
end

persistWindowPos = function()
    local saveW = (lastDialogW and lastDialogW > 0) and lastDialogW or ((gfx and gfx.w and gfx.w > 0) and gfx.w or nil)
    local saveH = (lastDialogH and lastDialogH > 0) and lastDialogH or ((gfx and gfx.h and gfx.h > 0) and gfx.h or nil)
    if lastDialogX and lastDialogY and saveW and saveH then
        local posStr = string.format("%d,%d,%d,%d", math.floor(lastDialogX), math.floor(lastDialogY), math.floor(saveW), math.floor(saveH))
        reaper.SetExtState(EXT_SECTION, "window_pos", posStr, true)
        reaper.SetExtState(EXT_SECTION, "window_pos_main", posStr, true)
        if GUI then
            GUI.windowPosLoaded = true
        end

        -- Cleanup old individual keys
        reaper.DeleteExtState(EXT_SECTION, "windowX", true)
        reaper.DeleteExtState(EXT_SECTION, "windowY", true)
        reaper.DeleteExtState(EXT_SECTION, "windowWidth", true)
        reaper.DeleteExtState(EXT_SECTION, "windowHeight", true)
    end
end

local function updateDialogPosFromGfx()
    if not (gfx and gfx.w and gfx.h and gfx.w > 0 and gfx.h > 0) then return false end
    if not isGfxWindowVisible() then return false end

    -- Best source inside REAPER: ask gfx itself for the undocked window rect.
    if gfx.dock then
        local dockState, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
        if dockState and wx and wy and ww and wh and ww > 0 and wh > 0 then
            if rememberDialogGeometry(wx, wy, ww, wh) then
                persistWindowPos()
                return true
            end
        end
    end

    if gfx.clienttoscreen then
        local points = {
            {0, 0},
            {1, 1},
            {math.floor(gfx.w / 2), math.floor(gfx.h / 2)},
        }
        for _, pt in ipairs(points) do
            local px, py = pt[1], pt[2]
            local sx, sy = gfx.clienttoscreen(px, py)
            if sx and sy and not (sx == 0 and sy == 0) then
                if rememberDialogGeometry(sx - px, math.max(0, (sy - py) - estimateTitlebarHeight()), gfx.w, gfx.h) then
                    persistWindowPos()
                    return true
                end
            end
        end
    end

    local mx, my = gfx.mouse_x, gfx.mouse_y
    if mx and my and mx >= 0 and my >= 0 and mx <= gfx.w and my <= gfx.h then
        local sx, sy = reaper.GetMousePosition()
        if sx and sy then
            return rememberDialogGeometry(sx - mx, math.max(0, (sy - my) - estimateTitlebarHeight()), gfx.w, gfx.h)
        end
    end
    return false
end

captureWindowGeometry = function(title)
    if updateDialogPosFromGfx() then return true end

    if title and reaper and reaper.JS_Window_Find and reaper.JS_Window_GetRect then
        local hwnd = reaper.JS_Window_Find(title, true)
        if hwnd then
            local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if ok then
                return rememberDialogGeometryFromRect(left, top, right, bottom)
            end
        end
    end

    return false
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
    if reaper.JS_Window_GetRect then
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
        -- Remember any size/position changes made in the help window
        local captured = false
        if helpState.hwnd and reaper.JS_Window_GetRect then
            local ok, left, top, right, bottom = reaper.JS_Window_GetRect(helpState.hwnd)
            if ok then
                rememberDialogGeometryFromRect(left, top, right, bottom)
                captured = true
            end
        end
        if (not captured) and (not lastDialogX or not lastDialogY) then
            if not captureWindowGeometry(currentTitle) then
                captureWindowGeometry(WINDOW_ART_GALLERY)
            end
        end
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
        -- Remember any size/position changes made in the help window
        local captured = false
        if helpState.hwnd and reaper.JS_Window_GetRect then
            local ok, left, top, right, bottom = reaper.JS_Window_GetRect(helpState.hwnd)
            if ok then
                rememberDialogGeometryFromRect(left, top, right, bottom)
                captured = true
            end
        end
        if (not captured) and (not lastDialogX or not lastDialogY) then
            if not captureWindowGeometry(currentTitle) then
                captureWindowGeometry(WINDOW_ART_GALLERY)
            end
        end
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

    -- Pure black/white background
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, w, h, 1)

    -- Draw procedural art background with zoom/pan/rotation
    local artX = messageWindowState.artPanX or 0
    local artY = messageWindowState.artPanY or 0
    local artZoom = messageWindowState.artZoom or 1.0
    local artRot = messageWindowState.artRotation or 0

    -- Apply zoom by adjusting draw area
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

    -- Theme toggle button (sun/moon icon, top right)
    local iconScale = 0.66
    local themeSize = math.max(PS(12), math.floor(PS(20) * iconScale + 0.5))
    local themeX = w - themeSize - PS(10)
    local themeY = PS(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = updateControlsOpacity(messageWindowState, mouseInControls)

    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)  -- Pure black for moon overlay
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

    -- Language toggle button (small text showing current language)
    local langW = PS(22)
    local langH = PS(14)
    local langX = themeX - langW - PS(6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    -- Draw language indicator
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

    -- Handle language toggle click
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    if langHover and rightMouseDown and not (messageWindowState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end
    if langHover and mouseDown and not messageWindowState.wasMouseDown and controlsOpacity > 0.3 then
        -- Cycle through languages: en -> nl -> de -> en
        local langs = {"en", "nl", "de"}
        local currentIdx = 1
        for i, l in ipairs(langs) do
            if l == SETTINGS.language then currentIdx = i break end
        end
        local nextIdx = (currentIdx % #langs) + 1
        setLanguage(langs[nextIdx])
        saveSettings()
    end

    -- === FX TOGGLE (below theme icon) ===
    local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + PS(3)
    local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)

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

    -- Track tooltip
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0

    if themeHover and controlsOpacity > 0.3 then
        tooltipText = getThemeToggleTooltip()
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    elseif langHover and controlsOpacity > 0.3 then
        tooltipText = T("tooltip_change_language")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    elseif fxHover and controlsOpacity > 0.3 then
        tooltipText = SETTINGS.visualFX and T("fx_disable") or T("fx_enable")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
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

    -- === Animated waveform visualization (BELOW tagline) ===
    local waveY = PS(95)
    local waveH = PS(50)
    local waveW = w - PS(60)
    local waveX = PS(30)

    -- Draw 4 layered waveforms (one for each stem color)
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

            if prevX then
                gfx.line(prevX, prevY, x, y)
            end
            prevX, prevY = x, y
        end
    end

    -- === Message (animated, bold, pulsing) ===
    gfx.setfont(1, "Arial", PS(14), string.byte('b'))

    -- Pulsing effect: oscillate between dim and bright
    local pulseAlpha = 0.6 + math.sin(time * 3) * 0.4

    -- Gradient through STEM colors
    local colorPhase = (time * 0.5) % 4
    local colorIdx = math.floor(colorPhase) + 1
    local nextColorIdx = (colorIdx % 4) + 1
    local colorBlend = colorPhase % 1

    local r = stemColors[colorIdx][1] * (1 - colorBlend) + stemColors[nextColorIdx][1] * colorBlend
    local g = stemColors[colorIdx][2] * (1 - colorBlend) + stemColors[nextColorIdx][2] * colorBlend
    local b = stemColors[colorIdx][3] * (1 - colorBlend) + stemColors[nextColorIdx][3] * colorBlend

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

    -- Subtle underline animation (growing/shrinking)
    local underlineW = msgBlockW * (0.5 + math.sin(time * 2) * 0.3)
    local underlineX = (w - underlineW) / 2
    gfx.set(r, g, b, pulseAlpha * 0.5)
    gfx.line(underlineX, msgBottomY + PS(6), underlineX + underlineW, msgBottomY + PS(6))

    -- Shared button dimensions for consistency
    local btnW = PS(70)
    local btnH = PS(20)
    local btnSpacing = PS(10)
    local totalBtnsW = btnW * 2 + btnSpacing
    local btnY = h - PS(40)

    -- Help button (blue, left)
    local helpBtnX = (w - totalBtnsW) / 2
    local helpHover = mx >= helpBtnX and mx <= helpBtnX + btnW and my >= btnY and my <= btnY + btnH

    if helpHover then
        gfx.set(0.3, 0.5, 0.8, 1)  -- Brighter blue on hover
    else
        gfx.set(0.2, 0.4, 0.7, 0.9)  -- Blue
    end
    -- Draw rounded (pill-shaped) button
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
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(13), string.byte('b'))
    local helpText = T("help")
    local helpTextW = gfx.measurestr(helpText)
    gfx.x = helpBtnX + (btnW - helpTextW) / 2
    gfx.y = btnY + (btnH - gfx.texth) / 2
    gfx.drawstr(helpText)

    -- Help button tooltip
    if helpHover and not tooltipText then
        tooltipText = T("help_tooltip")
        tooltipX = mx + PS(10)
        tooltipY = my + PS(15)
    end

    -- Close button (red, right)
    local btnX = helpBtnX + btnW + btnSpacing
    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    -- Red button color
    if hover then
        gfx.set(0.9, 0.3, 0.3, 1)
    else
        gfx.set(0.7, 0.2, 0.2, 1)
    end
    -- Draw rounded (pill-shaped) button
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

    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, "Arial", PS(13), string.byte('b'))
    local closeText = T("close")
    local closeW = gfx.measurestr(closeText)
    gfx.x = btnX + (btnW - closeW) / 2
    gfx.y = btnY + (btnH - gfx.texth) / 2
    gfx.drawstr(closeText)

    -- Close button tooltip
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

    -- flarkAUDIO logo at top (translucent) - "flark" regular, "AUDIO" bold
    gfx.setfont(1, "Arial", PS(10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2
    -- Orange text, 50% translucent
    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", PS(10))
    gfx.x = logoStartX
    gfx.y = PS(3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = PS(3)
    gfx.drawstr(audioPart)

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
    if reaper.JS_Window_Find then
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
-- icon: "info", "warning", "error"
-- monitorSelection: if true, window will auto-close and open main dialog when user makes a selection
showMessage = function(title, message, icon, monitorSelection, onClose)
    -- Load settings to get current theme
    loadSettings()
    updateTheme()

    -- Selection-monitoring mode is used as a safe landing screen (start/cancel).
    -- Make sure no stale processing lock prevents the next run.
    if monitorSelection then
        isProcessingActive = false
        if multiTrackQueue then
            multiTrackQueue.active = false
        end
    end

    messageWindowState.title = title or "STEMwerk"
    messageWindowState.message = message or ""
    messageWindowState.icon = icon or "info"
    messageWindowState.wasMouseDown = false
    messageWindowState.startTime = os.clock()
    messageWindowState.nextFrameAt = 0
    messageWindowState.nextSelectionCheckAt = 0
    messageWindowState.monitorSelection = monitorSelection or false
    messageWindowState.onClose = onClose

    if messageWindowState.monitorSelection then
        local overrideTitle = nil
        local overrideMessage = nil
        if hasTimeSelection() then
            local res = resolveTimeSelectionTargets and resolveTimeSelectionTargets() or nil
            if res and (res.rawOverlap or 0) > 0 and #(res.items or {}) == 0 then
                overrideTitle = HELPERS.getNoAudibleTargetsTitle()
                overrideMessage = HELPERS.getNoAudibleTargetsMessage()
            end
        end
        if not overrideTitle and (reaper.CountSelectedTracks(0) or 0) > 0 then
            local soloActive = getProcessingSoloActive()
            local anyAudibleTrack = false
            for t = 0, (reaper.CountSelectedTracks(0) or 0) - 1 do
                local tr = reaper.GetSelectedTrack(0, t)
                if tr and AUDIBILITY.isTrackAudible(tr, soloActive) then
                    anyAudibleTrack = true
                    break
                end
            end
            if not anyAudibleTrack then
                overrideTitle = HELPERS.getNoAudibleTargetsTitle()
                overrideMessage = HELPERS.getNoAudibleTargetsMessage()
            end
        end
        if overrideTitle then
            messageWindowState.title = overrideTitle
            messageWindowState.message = overrideMessage
            messageWindowState.icon = "info"
        end
    end

    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    gfx.init(SCRIPT_NAME, winW, winH, 0, winX, winY)

    -- In selection-monitoring mode, don't steal focus from REAPER.
    if monitorSelection then
        reaper.defer(function()
            local mainHwnd = reaper.GetMainHwnd()
            if mainHwnd and reaper.JS_Window_SetFocus then
                reaper.JS_Window_SetFocus(mainHwnd)
            end
        end)
    end
    if OS == "Windows" then
        messageWindowLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(messageWindowLoop)
    end
end

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
    if SETTINGS and SETTINGS.tooltips == false then
        GUI.tooltip = nil
        GUI.richTooltip = nil
        GUI.shortcutTooltip = nil
        return
    end
    -- Rich tooltip for STEMwerk button
    if GUI.richTooltip then
        gfx.setfont(1, "Arial", S(10))
        local is6Stem = (tostring(SETTINGS.model or "") == "htdemucs_6s")
        local padding = S(8)
        local lineH = S(14)

        -- Use global STEM border colors
        local titleColors = STEM_BORDER_COLORS

        -- Build selected stems list (use actual STEMS data)
        local selectedStems = {}
        for i, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
                table.insert(selectedStems, {name = stem.name, color = stem.color})
            end
        end

        -- Get target info
        local targetText = "New tracks"
        if SETTINGS.deleteOriginal then targetText = "Delete original"
        elseif SETTINGS.deleteSelection then targetText = "Delete selection"
        elseif SETTINGS.muteOriginal then targetText = "Mute original"
        elseif SETTINGS.muteSelection then targetText = "Mute selection"
        end
        if SETTINGS.createFolder then targetText = targetText .. " + folder" end

        -- Count selection info
        local selTrackCount = reaper.CountSelectedTracks(0)
        local selItemCount = 0
        for i = 0, selTrackCount - 1 do
            local track = reaper.GetSelectedTrack(0, i)
            selItemCount = selItemCount + reaper.CountTrackMediaItems(track)
        end

        -- Calculate tooltip size (5 lines: header, stems, selection, takes, target)
        local th = padding * 2 + lineH * 5 + S(10)

        -- Fixed label column width
        local labelColW = S(65)

        -- Measure line widths (value column only)
        gfx.setfont(1, "Arial", S(10), string.byte('b'))
        local stemsValueW = 0
        for i, stem in ipairs(selectedStems) do
            stemsValueW = stemsValueW + gfx.measurestr(stem.name)
            if i < #selectedStems then stemsValueW = stemsValueW + gfx.measurestr(" ") end
        end

        gfx.setfont(1, "Arial", S(10))
        -- Compose status info for tooltip from the same footer summary used by the main window.
        local selectionText = ""
        local footerLines = (type(buildFooterLines) == "function") and buildFooterLines() or nil
        if footerLines and footerLines.selLine and footerLines.selLine ~= "" then
            selectionText = tostring(footerLines.selLine):gsub("^[^:]+:%s*", "")
        end

        local isTakesMode = not SETTINGS.createNewTracks
        local takesText = isTakesMode and T("yes") or T("no")
        
        -- Build action list (Target)
        local actions = {}
        if SETTINGS.createNewTracks then
            table.insert(actions, T("new_tracks"))
            if SETTINGS.createFolder then table.insert(actions, "+ " .. T("create_folder")) end
        else
            -- In-place mode
            table.insert(actions, T("in_place"))
            
            -- Add post-processing info
            local ppMode = tostring(SETTINGS.postProcessTakes or "none")
            if ppMode == "none" then
                table.insert(actions, "(" .. T("keep_takes") .. ")")
            elseif ppMode == "explode_new_tracks" then
                table.insert(actions, "-> " .. T("new_tracks"))
            elseif ppMode == "explode_in_place" then
                table.insert(actions, "-> " .. T("explode_in_place"))
            elseif ppMode == "explode_in_order" then
                table.insert(actions, "-> " .. T("explode_in_order"))
            end
        end
        
        if SETTINGS.muteOriginal then table.insert(actions, "+ " .. T("mute_original")) end
        if SETTINGS.deleteOriginal then table.insert(actions, "+ " .. T("delete_original")) end
        if SETTINGS.deleteOriginalTrack then table.insert(actions, "+ " .. T("delete_track")) end
        if SETTINGS.muteSelectionOnly then table.insert(actions, "+ " .. T("mute_selection")) end
        if SETTINGS.deleteSelectionOnly then table.insert(actions, "+ " .. T("delete_selection")) end
        local targetText = #actions > 0 and table.concat(actions, " ") or "-"

        local selValueW = gfx.measurestr(selectionText)
        local takesValueW = gfx.measurestr(takesText)
        local targetValueW = gfx.measurestr(targetText)

        -- Measure header
        gfx.setfont(1, "Arial", S(11), string.byte('b'))
        local headerText = T("click_to_stemperate")
        local headerLineW = gfx.measurestr(headerText)

        -- Calculate max value width needed
        local maxValueW = math.max(stemsValueW, selValueW, takesValueW, targetValueW)
        -- Total width = padding + label column + value column + padding
        local tw = math.max(headerLineW + padding * 2, padding + labelColW + maxValueW + padding)

        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        -- Keep tooltip on screen
        if tx + tw > gfx.w then tx = gfx.w - tw - S(5) end
        if ty + th > gfx.h then ty = GUI.tooltipY - th - S(20) end

        -- Background (theme-aware)
        gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.98)
        gfx.rect(tx, ty, tw, th, 1)

        -- Colored top border (stem colors gradient)
        for i = 0, tw - 1 do
            local colorIdx = math.floor(i / tw * 4) + 1
            colorIdx = math.min(4, math.max(1, colorIdx))
            local c = titleColors[colorIdx]
            gfx.set(c[1]/255, c[2]/255, c[3]/255, 0.9)
            gfx.line(tx + i, ty, tx + i, ty + 2)
        end

        -- Border (theme-aware)
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        gfx.rect(tx, ty, tw, th, 0)

        local labelX = tx + padding
        local valueX = tx + padding + labelColW
        local currentY = ty + padding + S(2)

        -- Header: localized ".. STEM.." with colored STEM letters
        gfx.setfont(1, "Arial", S(11), string.byte('b'))
        local headerW = gfx.measurestr(headerText)
        local headerX = tx + (tw - headerW) / 2
        gfx.x = headerX
        gfx.y = currentY

        local stemIdx = headerText:find("STEM")
        local prefix = headerText
        local suffix = ""
        if stemIdx then
            prefix = headerText:sub(1, stemIdx - 1)
            suffix = headerText:sub(stemIdx + 4)
        end

        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.drawstr(prefix)
        for i, letter in ipairs({"S", "T", "E", "M"}) do
            local c = titleColors[i]
            gfx.set(c[1]/255, c[2]/255, c[3]/255, 1)
            gfx.drawstr(letter)
        end
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.drawstr(suffix)
        currentY = currentY + lineH + S(4)

        -- Line 1: Stems (colored)
        gfx.setfont(1, "Arial", S(10))
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_stems_label") or "Stems")

        -- Re-collect selected stems for drawing
        local activeStems = {}
        for _, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or is6Stem) then
                table.insert(activeStems, stem)
            end
        end

        if #activeStems == 0 then
            gfx.set(1, 0.3, 0.3, 1) -- Red for warning
            gfx.x = valueX
            gfx.drawstr(T("no_stems_selected") or "[!] None")
        else
            gfx.setfont(1, "Arial", S(10), string.byte('b'))
            local stemX = valueX
            for i, stem in ipairs(activeStems) do
                gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
                gfx.x = stemX
                gfx.y = currentY
                gfx.drawstr(stem.name)
                stemX = stemX + gfx.measurestr(stem.name)
                if i < #activeStems then
                    gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
                    gfx.x = stemX
                    gfx.drawstr(" ")
                    stemX = stemX + gfx.measurestr(" ")
                end
            end
        end
        currentY = currentY + lineH

        -- Line 2: Selection
        gfx.setfont(1, "Arial", S(10))
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_selection_label") or "Selection")
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = valueX
        gfx.drawstr(selectionText)
        currentY = currentY + lineH

        -- Line 3: Takes
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_takes_label") or "Takes")
        if SETTINGS.createTakes then
            gfx.set(0.4, 0.9, 0.5, 1)  -- Green for yes
        else
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)  -- Dim for no
        end
        gfx.x = valueX
        gfx.drawstr(takesText)
        currentY = currentY + lineH

        -- Line 4: Target
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_target_label") or "Target")
        gfx.set(1.0, 0.6, 0.2, 1)  -- Orange for target (stays colored)
        gfx.x = valueX
        gfx.drawstr(targetText)

        GUI.richTooltip = nil
    elseif GUI.tooltip then
        -- Use global STEM border colors
        local tooltipColors = STEM_BORDER_COLORS

        gfx.setfont(1, "Arial", S(11))
        local padding = S(8)
        -- Support multi-line tooltips (our runtime backend notes use newlines).
        local tooltipText = tostring(GUI.tooltip or "")
        local function wrapTextToWidth(text, maxWidth)
            -- Preserve explicit newlines and blank lines, but wrap long lines by words.
            local out = {}
            for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
                if raw == "" then
                    out[#out + 1] = ""
                else
                    local line = ""
                    for word in raw:gmatch("%S+") do
                        if line == "" then
                            line = word
                        else
                            local candidate = line .. " " .. word
                            if gfx.measurestr(candidate) <= maxWidth then
                                line = candidate
                            else
                                out[#out + 1] = line
                                line = word
                            end
                        end
                    end
                    if line ~= "" then out[#out + 1] = line end
                end
            end
            -- Remove the trailing line added by the extra "\n"
            if #out > 0 and out[#out] == "" then
                -- keep if original ended with a blank line; otherwise trim one trailing empty
                out[#out] = nil
            end
            return out
        end

        -- Cap tooltip width and wrap text so tooltips don't span the whole window.
        local maxTextW = math.floor(math.min(gfx.w * 0.62, S(520)))
        maxTextW = math.max(S(180), maxTextW)
        local lines = wrapTextToWidth(tooltipText, maxTextW)

        local maxLineW = 0
        for _, line in ipairs(lines) do
            local w = gfx.measurestr(line)
            if w > maxLineW then maxLineW = w end
        end
        local lineH = gfx.texth + S(2)
        local tw = maxLineW + padding * 2
        local th = (lineH * #lines) + padding * 2 + S(2)
        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        -- Keep tooltip on screen
        if tx + tw > gfx.w then
            tx = gfx.w - tw - S(5)
        end
        if ty + th > gfx.h then
            ty = GUI.tooltipY - th - S(20)
        end

        -- Background (theme-aware)
        gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.98)
        gfx.rect(tx, ty, tw, th, 1)

        -- Colored top border (stem colors gradient)
        for i = 0, tw - 1 do
            local colorIdx = math.floor(i / tw * 4) + 1
            colorIdx = math.min(4, math.max(1, colorIdx))
            local c = tooltipColors[colorIdx]
            gfx.set(c[1]/255, c[2]/255, c[3]/255, 0.9)
            gfx.line(tx + i, ty, tx + i, ty + 2)
        end

        -- Border (theme-aware)
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        gfx.rect(tx, ty, tw, th, 0)

        -- Text (theme-aware)
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        local x = tx + padding
        local y = ty + padding + S(2)
        for _, line in ipairs(lines) do
            gfx.x = x
            gfx.y = y
            gfx.drawstr(line)
            y = y + lineH
        end

        -- Clear tooltip for next frame
        GUI.tooltip = nil
    elseif GUI.shortcutTooltip then
        -- Tooltip with colored keyboard shortcut
        local tooltipColors = STEM_BORDER_COLORS
        local st = GUI.shortcutTooltip

        gfx.setfont(1, "Arial", S(11))
        local padding = S(8)
        local textW = gfx.measurestr(st.text)
        local shortcutW = gfx.measurestr(" [" .. st.shortcut .. "]")
        local tw = textW + shortcutW + padding * 2
        local th = S(18) + padding * 2
        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        -- Keep tooltip on screen
        if tx + tw > gfx.w then
            tx = gfx.w - tw - S(5)
        end
        if ty + th > gfx.h then
            ty = GUI.tooltipY - th - S(20)
        end

        -- Background (theme-aware)
        gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.98)
        gfx.rect(tx, ty, tw, th, 1)

        -- Colored top border (stem colors gradient)
        for i = 0, tw - 1 do
            local colorIdx = math.floor(i / tw * 4) + 1
            colorIdx = math.min(4, math.max(1, colorIdx))
            local c = tooltipColors[colorIdx]
            gfx.set(c[1]/255, c[2]/255, c[3]/255, 0.9)
            gfx.line(tx + i, ty, tx + i, ty + 2)
        end

        -- Border (theme-aware)
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        gfx.rect(tx, ty, tw, th, 0)

        -- Text (theme-aware)
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = tx + padding
        gfx.y = ty + padding + S(2)
        gfx.drawstr(st.text .. " ")

        -- Shortcut in color
        gfx.set(st.color[1]/255, st.color[2]/255, st.color[3]/255, 1)
        gfx.drawstr("[" .. st.shortcut .. "]")

        -- Clear tooltip for next frame
        GUI.shortcutTooltip = nil
    end
end

local function fitTextToBox(text, availableW, baseFontSize, minFontSize)
    text = tostring(text or "")
    local fontSize = baseFontSize
    local tw = gfx.measurestr(text)
    if tw > availableW and availableW > 0 then
        local scale = availableW / tw
        fontSize = math.max(minFontSize, math.floor(baseFontSize * scale))
        gfx.setfont(1, "Arial", fontSize)
        tw = gfx.measurestr(text)
        if tw > availableW then
            local ell = ".."
            local ellW = gfx.measurestr(ell)
            local maxW = math.max(0, availableW - ellW)
            local n = #text
            while n > 0 and gfx.measurestr(text:sub(1, n)) > maxW do
                n = n - 1
            end
            if n > 0 then
                text = text:sub(1, n) .. ell
            else
                text = ell
            end
            tw = gfx.measurestr(text)
        end
    end
    return text, tw, fontSize
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

    gfx.set(bg[1], bg[2], bg[3], hover and 0.96 or 0.88)
    gfx.rect(x, y, w, h, 1)

    gfx.set(border[1], border[2], border[3], hover and 1 or 0.85)
    gfx.rect(x, y, w, h, 0)

    gfx.set(accent[1], accent[2], accent[3], 0.9)
    gfx.rect(x, y, math.max(2, math.floor(h * 0.16)), h, 1)

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
    local clicked = false
    local labelWidth = gfx.measurestr(label)
    local boxW = fixedW or (labelWidth + S(16))
    local boxH = S(20)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + boxW and my >= y and my <= y + boxH

    if hover then GUI.uiClickedThisFrame = true end

    if mouseDown and hover then
        if not GUI.wasMouseDown then clicked = true end
    end

    local baseR, baseG, baseB
    if checked then
        local mult = hover and 1.2 or 1.0
        baseR = (r or 0) / 255 * mult
        baseG = (g or 0) / 255 * mult
        baseB = (b or 0) / 255 * mult
    else
        local brightness = hover and 0.35 or 0.25
        baseR, baseG, baseB = brightness, brightness, brightness
    end
    drawGlossyRect(x, y, boxW, boxH, baseR, baseG, baseB, 1)

    -- Border
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(x, y, boxW, boxH, 0)

    -- Text - white for contrast
    local textAlpha = checked and 1 or (hover and 0.95 or 0.85)
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = S(9)
    local padding = S(4)
    local labelText, tw, usedFontSize = fitTextToBox(label, boxW - padding * 2, baseFontSize, minFontSize)
    local textX = x + (boxW - tw) / 2
    local textH = gfx.texth
    local textY = y + (boxH - textH) / 2
    gfx.set(0, 0, 0, 0.35 * textAlpha)
    gfx.x, gfx.y = textX + 2, textY + 2; gfx.drawstr(labelText)
    gfx.set(0, 0, 0, 0.55 * textAlpha)
    gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX + 1, textY - 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY - 1; gfx.drawstr(labelText)
    gfx.set(1, 1, 1, textAlpha)
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked, boxW
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
    local w, PS = ctx.w, ctx.PS
    local mx, my, mouseDown = ctx.mx, ctx.my, ctx.mouseDown
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local tooltipText = ctx.tooltipText
    local tooltipX = ctx.tooltipX
    local tooltipY = ctx.tooltipY

    local iconScale = 0.66
    local themeSize = math.max(PS(12), math.floor(PS(20) * iconScale + 0.5))
    local themeX = w - themeSize - PS(10)
    local themeY = PS(8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = updateControlsOpacity(resultWindowState, mouseInControls)

    if themeHover then GUI.uiClickedThisFrame = true end
    if fxHover then GUI.uiClickedThisFrame = true end
    if langHover then GUI.uiClickedThisFrame = true end

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

    if themeHover and rightMouseDown and not (resultWindowState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
        cycleThemePreset()
    end
    if themeHover and mouseDown and not resultWindowState.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.darkMode = not SETTINGS.darkMode
        updateTheme()
        saveSettings()
    end
    if themeHover and controlsOpacity > 0.3 then
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end

    local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + PS(3)
    local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)

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
    if fxHover and mouseDown and not resultWindowState.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
    end
    if fxHover and controlsOpacity > 0.3 then
        tooltipText = SETTINGS.visualFX and (T("fx_disable") or "Disable visual effects") or (T("fx_enable") or "Enable visual effects")
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end

    local langW = PS(22)
    local langH = PS(14)
    local langX = themeX - langW - PS(6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    gfx.setfont(1, "Arial", PS(9), string.byte('b'))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    if langHover then
        gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
        if controlsOpacity > 0.3 then
            tooltipText = T("tooltip_change_language") or "Click to change language"
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
            local rightMouseDown = gfx.mouse_cap & 2 == 2
            if rightMouseDown and not (resultWindowState.wasRightMouseDown or false) then
                SETTINGS.tooltips = not SETTINGS.tooltips
                saveSettings()
            end
            if mouseDown and not resultWindowState.wasMouseDown then
                local langs = {"en", "nl", "de"}
                local currentIdx = 1
                for i, l in ipairs(langs) do
                    if l == SETTINGS.language then currentIdx = i; break end
                end
                local nextIdx = (currentIdx % #langs) + 1
                setLanguage(langs[nextIdx])
                saveSettings()
            end
        end
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    ctx.tooltipText = tooltipText
    ctx.tooltipX = tooltipX
    ctx.tooltipY = tooltipY
end

function renderResultTitleArea(ctx)
    local w, PS = ctx.w, ctx.PS
    local selectedStems = resultWindowState.selectedStems or {}

    local iconX = w / 2
    local iconY = PS(60)
    local iconR = PS(28)

    gfx.set(0.2, 0.65, 0.35, 1)
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

    gfx.setfont(1, "Arial", PS(18), string.byte('b'))
    local stemLetterColors = {
        {255, 100, 100},
        {100, 200, 255},
        {150, 100, 255},
        {100, 255, 150},
    }
    local stemPart = "STEM"
    local restPart = "werk Complete!"
    local stemW = gfx.measurestr(stemPart)
    local restW = gfx.measurestr(restPart)
    local totalW = stemW + restW
    local titleX = (w - totalW) / 2
    local titleY = PS(100)

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

    local stemY = PS(125)
    local stemBoxSize = PS(14)
    gfx.setfont(1, "Arial", PS(11))
    local totalStemWidth = 0
    for _, stem in ipairs(selectedStems) do
        totalStemWidth = totalStemWidth + stemBoxSize + gfx.measurestr(stem.name) + PS(16)
    end
    local stemX = (w - totalStemWidth) / 2
    for _, stem in ipairs(selectedStems) do
        gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
        gfx.rect(stemX, stemY, stemBoxSize, stemBoxSize, 1)
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        gfx.x = stemX + stemBoxSize + PS(5)
        gfx.y = stemY + PS(1)
        gfx.drawstr(stem.name)
        stemX = stemX + stemBoxSize + gfx.measurestr(stem.name) + PS(16)
    end

end

function renderResultMessageBox(ctx)
    local w, h, PS = ctx.w, ctx.h, ctx.PS
    local msgBoxY = PS(170)
    local msgBoxH = PS(70)
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.3)
    gfx.rect(PS(20), msgBoxY, w - PS(40), msgBoxH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.6)
    gfx.rect(PS(20), msgBoxY, w - PS(40), msgBoxH, 0)

    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.setfont(1, "Arial", PS(11))
    local msgLines = buildResultMessageLines()
    local msgY = msgBoxY + PS(8)
    for _, line in ipairs(msgLines) do
        local lineW = gfx.measurestr(line)
        gfx.x = (w - lineW) / 2
        gfx.y = msgY
        gfx.drawstr(line)
        msgY = msgY + PS(13)
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
            table.insert(lines, string.format("Time: %s | Speed: %s realtime", timeStr, speedStr))
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
    local radius = h / 2
    local function drawPillLineAt(i)
        local inset = 0
        if i < radius then
            inset = radius - math.sqrt(radius * radius - (radius - i) * (radius - i))
        elseif i > h - radius then
            inset = radius - math.sqrt(radius * radius - (i - (h - radius)) * (i - (h - radius)))
        end
        gfx.line(x + inset, y + i, x + w - inset, y + i)
    end

    gfx.set(baseR, baseG, baseB, baseA)
    for i = 0, h - 1 do
        drawPillLineAt(i)
    end

    local hiR = math.min(1, baseR + 0.3)
    local hiG = math.min(1, baseG + 0.3)
    local hiB = math.min(1, baseB + 0.3)
    local highlightH = math.max(1, math.floor(h * 0.42))
    for i = 0, highlightH - 1 do
        local t = 1 - (i / math.max(1, highlightH - 1))
        gfx.set(hiR, hiG, hiB, 0.25 * t * baseA)
        drawPillLineAt(i)
    end

    local bandY = math.floor(h * 0.18)
    local bandH = math.max(1, math.floor(h * 0.22))
    for i = 0, bandH - 1 do
        local t = 1 - (i / math.max(1, bandH - 1))
        gfx.set(1, 1, 1, 0.12 * t * baseA)
        drawPillLineAt(bandY + i)
    end

    local shR, shG, shB = baseR * 0.6, baseG * 0.6, baseB * 0.6
    local shadowH = math.max(1, math.floor(h * 0.35))
    for i = 0, shadowH - 1 do
        local t = i / math.max(1, shadowH - 1)
        gfx.set(shR, shG, shB, 0.18 * t * baseA)
        drawPillLineAt(h - 1 - i)
    end

    local innerR, innerG, innerB = baseR * 0.7, baseG * 0.7, baseB * 0.7
    for i = 0, h - 1 do
        if i < 2 or i > h - 3 then
            gfx.set(innerR, innerG, innerB, 0.2 * baseA)
            drawPillLineAt(i)
        end
    end
    return true
end

drawGlossyRect = function(x, y, w, h, baseR, baseG, baseB, baseA)
    baseA = baseA or 1
    gfx.set(baseR, baseG, baseB, baseA)
    gfx.rect(x, y, w, h, 1)

    local hiR = math.min(1, baseR + 0.3)
    local hiG = math.min(1, baseG + 0.3)
    local hiB = math.min(1, baseB + 0.3)
    local highlightH = math.max(1, math.floor(h * 0.42))
    for i = 0, highlightH - 1 do
        local t = 1 - (i / math.max(1, highlightH - 1))
        gfx.set(hiR, hiG, hiB, 0.25 * t * baseA)
        gfx.rect(x, y + i, w, 1, 1)
    end

    local bandY = math.floor(h * 0.18)
    local bandH = math.max(1, math.floor(h * 0.22))
    for i = 0, bandH - 1 do
        local t = 1 - (i / math.max(1, bandH - 1))
        gfx.set(1, 1, 1, 0.12 * t * baseA)
        gfx.rect(x, y + bandY + i, w, 1, 1)
    end

    local shR, shG, shB = baseR * 0.6, baseG * 0.6, baseB * 0.6
    local shadowH = math.max(1, math.floor(h * 0.35))
    for i = 0, shadowH - 1 do
        local t = i / math.max(1, shadowH - 1)
        gfx.set(shR, shG, shB, 0.18 * t * baseA)
        gfx.rect(x, y + (h - 1 - i), w, 1, 1)
    end

    gfx.set(baseR * 0.7, baseG * 0.7, baseB * 0.7, 0.2 * baseA)
    gfx.rect(x, y, w, 1, 1)
    gfx.rect(x, y + h - 1, w, 1, 1)
end

-- Draw a radio button as a toggle box (like stems/presets) and return if it was clicked (scaled)
-- Optional fixedW parameter to set a fixed width for all boxes
-- Optional attentionMult: when not selected, draw a subtle accent pulse (used to hint "direct tool" availability)
-- Optional icon: currently supports "explode" (drawn at left; animated when attentionMult > 0)
-- Optional fontSizeOverride: when provided, all radios in a group can share the same text size.
-- Optional lockFontSize: when true, keep the font size fixed and truncate with ellipsis if needed.
local function drawRadio(x, y, selected, label, color, fixedW, attentionMult, icon, fontSizeOverride, lockFontSize)
    local clicked = false
    local labelWidth = gfx.measurestr(label)
    local boxW = fixedW or (labelWidth + S(16))
    local boxH = S(20)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + boxW and my >= y and my <= y + boxH

    if hover then GUI.uiClickedThisFrame = true end

    if mouseDown and hover then
        if not GUI.wasMouseDown then clicked = true end
    end

    -- Use provided color or default accent color
    local r, g, b = THEME.accent[1] * 255, THEME.accent[2] * 255, THEME.accent[3] * 255
    if color then
        r, g, b = color[1], color[2], color[3]
    end

    -- Background color based on selected state
    local baseR, baseG, baseB, baseA
    if selected then
        local mult = hover and 1.2 or 1.0
        baseR, baseG, baseB, baseA = r / 255 * mult, g / 255 * mult, b / 255 * mult, 1
    else
        if attentionMult and attentionMult > 0 then
            local base = hover and 0.55 or 0.45
            baseA = math.min(0.9, math.max(0.25, base * attentionMult))
            baseR, baseG, baseB = r / 255, g / 255, b / 255
        else
            local brightness = hover and 0.35 or 0.25
            baseR, baseG, baseB, baseA = brightness, brightness, brightness, 1
        end
    end
    drawGlossyRect(x, y, boxW, boxH, baseR, baseG, baseB, baseA)

    -- Border
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(x, y, boxW, boxH, 0)

    -- Text - white for contrast
    local textAlpha = selected and 1 or (hover and 0.95 or 0.85)

    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = lockFontSize and baseFontSize or S(9)
    local padding = S(4)

    if icon == "explode" then
        -- Stacked layout: label on top, icon below.
        local t = os.clock() or 0
        local rot = 0
        local pulse = 1.0
        local anim = hover or (attentionMult and attentionMult > 0)
        if anim then
            rot = t * 2.2
            pulse = 0.92 + 0.14 * (0.5 + 0.5 * math.sin(t * 9.0))
        end

        local size = math.max(6, boxH * 0.52)
        -- Reserve space on the left for the icon so text never overlaps it.
        local reservedLeft = S(5) + size + S(8)
        local labelText, tw, usedFontSize = fitTextToBox(label, boxW - reservedLeft - padding, baseFontSize, minFontSize)
        -- Right align label against the right edge of the box.
        local labelX = x + boxW - padding - tw
        local labelY = y + S(2)
        gfx.set(0, 0, 0, 0.35 * textAlpha)
        gfx.x, gfx.y = labelX + 2, labelY + 2; gfx.drawstr(labelText)
        gfx.set(0, 0, 0, 0.55 * textAlpha)
        gfx.x, gfx.y = labelX + 1, labelY + 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX - 1, labelY + 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX + 1, labelY - 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX - 1, labelY - 1; gfx.drawstr(labelText)
        gfx.set(1, 1, 1, textAlpha)
        gfx.x, gfx.y = labelX, labelY
        gfx.drawstr(labelText)

        if usedFontSize ~= baseFontSize then
            gfx.setfont(1, "Arial", baseFontSize)
        end

        -- Place icon all the way to the left; vertically centered in the box.
        local cx = x + S(5) + size * 0.5
        local cy = y + boxH * 0.5

        local a = 0.9
        if anim then
            local att = attentionMult or 1.0
            a = math.min(1.0, 0.55 + 0.45 * att)
        end

        -- When animating, colorize the explosion with the current stem colors.
        local stemCols = nil
        if anim and STEMS and STEMS[1] and STEMS[1].color then
            stemCols = {}
            for j = 1, 4 do
                local c = STEMS[j] and STEMS[j].color
                if c and c[1] and c[2] and c[3] then
                    stemCols[#stemCols + 1] = {c[1] / 255, c[2] / 255, c[3] / 255}
                end
            end
            if #stemCols == 0 then stemCols = nil end
        end

        local spikeOuter = (size * 0.52) * pulse
        local spikeInner = (size * 0.30) * pulse
        local spikes = 9
        local phase = math.floor(t * 8.0)
        for i = 0, spikes - 1 do
            local ang = rot + (i / spikes) * (math.pi * 2)
            local x1 = cx + math.cos(ang) * spikeInner
            local y1 = cy + math.sin(ang) * spikeInner
            local x2 = cx + math.cos(ang) * spikeOuter
            local y2 = cy + math.sin(ang) * spikeOuter

            if stemCols then
                local ci = ((i + phase) % #stemCols) + 1
                gfx.set(stemCols[ci][1], stemCols[ci][2], stemCols[ci][3], a)
            else
                -- Same color as the text in the box (white)
                gfx.set(1, 1, 1, a)
            end
            gfx.line(x1, y1, x2, y2)
        end

        if stemCols then
            local ci = ((phase + spikes) % #stemCols) + 1
            gfx.set(stemCols[ci][1], stemCols[ci][2], stemCols[ci][3], a)
        else
            gfx.set(1, 1, 1, a)
        end
        gfx.circle(cx, cy, (size * 0.16) * pulse, 1, 1)
    else
        -- Default centered label
        local labelText, tw, usedFontSize = fitTextToBox(label, boxW - padding * 2, baseFontSize, minFontSize)
        local textX = x + (boxW - tw) / 2
        local textH = gfx.texth
    local textY = y + (boxH - textH) / 2
        gfx.set(0, 0, 0, 0.35 * textAlpha)
        gfx.x, gfx.y = textX + 2, textY + 2; gfx.drawstr(labelText)
        gfx.set(0, 0, 0, 0.55 * textAlpha)
        gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = textX - 1, textY + 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = textX + 1, textY - 1; gfx.drawstr(labelText)
        gfx.x, gfx.y = textX - 1, textY - 1; gfx.drawstr(labelText)
        gfx.set(1, 1, 1, textAlpha)
        gfx.x, gfx.y = textX, textY
        gfx.drawstr(labelText)

        if usedFontSize ~= baseFontSize then
            gfx.setfont(1, "Arial", baseFontSize)
        end
    end

    return clicked, boxW
end

local function calcUniformRadioFontSize(labels, boxW, reservedLeft)
    local baseFontSize = S(13)
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

local function getUniformFontSizeCached(cacheId, labels, boxW, reservedLeft)
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
    local clicked = false
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h

    -- Track that mouse is over a UI element (prevents background art click)
    if hover then GUI.uiClickedThisFrame = true end

    if mouseDown and hover then
        if not GUI.wasMouseDown then clicked = true end
    end

    local baseR, baseG, baseB
    if selected then
        local mult = hover and 1.2 or 1.0
        baseR = (color[1] or 0) / 255 * mult
        baseG = (color[2] or 0) / 255 * mult
        baseB = (color[3] or 0) / 255 * mult
    else
        local brightness = hover and 0.35 or 0.25
        baseR, baseG, baseB = brightness, brightness, brightness
    end
    drawGlossyRect(x, y, w, h, baseR, baseG, baseB, 1)

    -- Border - brighter when selected
    if selected then
        gfx.set(1, 1, 1, 0.5)
    else
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    end
    gfx.rect(x, y, w, h, 0)

    -- Button text
    -- Keep text readable even when unselected; match Output column readability.
    local textAlpha = selected and 1 or (hover and 0.9 or 0.75)
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = S(9)
    local padding = S(4)
    local labelText, tw, usedFontSize = fitTextToBox(label, w - padding * 2, baseFontSize, minFontSize)
    local textX = x + (w - tw) / 2
    local textH = gfx.texth
    local textY = y + (h - textH) / 2
    gfx.set(0, 0, 0, 0.35 * textAlpha)
    gfx.x, gfx.y = textX + 2, textY + 2; gfx.drawstr(labelText)
    gfx.set(0, 0, 0, 0.55 * textAlpha)
    gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX + 1, textY - 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY - 1; gfx.drawstr(labelText)
    gfx.set(1, 1, 1, textAlpha)
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked
end

-- Draw a small button and return if it was clicked (scaled)
-- Optional fontSizeOverride: when provided, a group of buttons can share the same text size.
local function drawButton(x, y, w, h, label, isDefault, color, fontSizeOverride)
    local clicked = false
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h

    -- Track that mouse is over a UI element (prevents background art click)
    if hover then GUI.uiClickedThisFrame = true end

    if mouseDown and hover then
        if not GUI.wasMouseDown then clicked = true end
    end

    local baseR, baseG, baseB
    if color then
        local mult = hover and 1.2 or 1.0
        baseR = (color[1] or 0) / 255 * mult
        baseG = (color[2] or 0) / 255 * mult
        baseB = (color[3] or 0) / 255 * mult
    else
        if isDefault then
            if hover then
                baseR, baseG, baseB = THEME.buttonPrimaryHover[1], THEME.buttonPrimaryHover[2], THEME.buttonPrimaryHover[3]
            else
                baseR, baseG, baseB = THEME.buttonPrimary[1], THEME.buttonPrimary[2], THEME.buttonPrimary[3]
            end
        else
            if hover then
                baseR, baseG, baseB = THEME.buttonHover[1], THEME.buttonHover[2], THEME.buttonHover[3]
            else
                baseR, baseG, baseB = THEME.button[1], THEME.button[2], THEME.button[3]
            end
        end
    end

    drawGlossyPill(x, y, w, h, baseR, baseG, baseB)

    -- Button text - always white for good contrast on colored buttons
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = S(9)
    local padding = S(4)
    local labelText, tw, usedFontSize = fitTextToBox(label, w - padding * 2, baseFontSize, minFontSize)
    local textX = x + (w - tw) / 2
    local textH = gfx.texth
    local textY = y + (h - textH) / 2
    gfx.set(0, 0, 0, 0.4)
    gfx.x, gfx.y = textX + 2, textY + 2; gfx.drawstr(labelText)
    gfx.set(0, 0, 0, 0.6)
    gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY + 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX + 1, textY - 1; gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY - 1; gfx.drawstr(labelText)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked
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
    -- Match main dialog day/night: pure black in dark mode, pure white in light mode.
    local bg = (SETTINGS and SETTINGS.darkMode) and 0 or 1
    gfx.set(bg, bg, bg, 1)
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

    -- Rounded rect fill (scanline)
    local r = S(12)
    local function roundedFill(x, y, w, h, radius)
        w = math.floor(w)
        h = math.floor(h)
        radius = math.max(0, math.min(radius, math.floor(math.min(w, h) / 2)))
        for i = 0, h - 1 do
            local inset = 0
            if i < radius then
                inset = radius - math.sqrt(radius * radius - (radius - i) * (radius - i))
            elseif i > h - 1 - radius then
                local di = i - (h - 1 - radius)
                inset = radius - math.sqrt(radius * radius - di * di)
            end
            gfx.line(x + inset, y + i, x + w - inset, y + i)
        end
    end

    -- Panel shadow
    gfx.set(0, 0, 0, 0.35 * fade)
    roundedFill(boxX + S(2), boxY + S(3), boxW, boxH, r)

    -- Panel border + bg (rounded, no square outline)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.95)
    roundedFill(boxX, boxY, boxW, boxH, r)
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.985)
    roundedFill(boxX + 1, boxY + 1, boxW - 2, boxH - 2, math.max(0, r - 1))

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
        local ir = math.floor(inputH / 2)
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.95)
        roundedFill(inputX, valueY, inputW, inputH, ir)
        gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 0.98)
        roundedFill(inputX + 1, valueY + 1, inputW - 2, inputH - 2, math.max(0, ir - 1))

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

    -- Draw a proper pill border (no square rect): outer border pill then inner fill pill.
    local br = math.floor(btnH / 2)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.95)
    roundedFill(btnX, btnY, btnW, btnH, br)
    gfx.set(col[1], col[2], col[3], 1)
    roundedFill(btnX + 1, btnY + 1, btnW - 2, btnH - 2, math.max(0, br - 1))

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
        gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 0.95)
        roundedFill(cancelX, btnY, btnW, btnH, br)
        gfx.set(cancelCol[1], cancelCol[2], cancelCol[3], 1)
        roundedFill(cancelX + 1, btnY + 1, btnW - 2, btnH - 2, math.max(0, br - 1))

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
    local deviceRadioFontSize = getUniformFontSizeCached("main_device_col", deviceLabels, deviceBoxW)
    local function tightenFontSizeToFit(labels, boxW, fontSize)
        local padding = S(4)
        local availableW = (boxW or 0) - padding * 2
        if availableW <= 0 then return fontSize end
        local size = fontSize
        local minSize = S(9)
        while size > minSize do
            gfx.setfont(1, "Arial", size)
            local fits = true
            for _, text in ipairs(labels or {}) do
                local w = gfx.measurestr(tostring(text or ""))
                if w > availableW then
                    fits = false
                    break
                end
            end
            if fits then break end
            size = size - 1
        end
        return size
    end
    deviceRadioFontSize = tightenFontSizeToFit(deviceLabels, deviceBoxW, deviceRadioFontSize)

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
        if drawRadio(col4X, deviceY, SETTINGS.device == device.id, label, nil, deviceBoxW, nil, nil, deviceRadioFontSize, true) then
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
    if reaper.JS_Window_GetRect then
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
    gfx.setfont(1, "Arial", PX(28), string.byte('b'))
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    local qsTitle = getLangText("help_quickstart_title", "Quick Start")
    local qtW = gfx.measurestr(qsTitle)
    gfx.x = (w - qtW) / 2 + textOffsetX
    gfx.y = contentY + PX(15)
    gfx.drawstr(qsTitle)

    gfx.setfont(1, "Arial", PX(14))
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local subText = getLangText("help_quickstart_sub", "A fast guide to getting stems in REAPER.")
    local subW = gfx.measurestr(subText)
    gfx.x = (w - subW) / 2 + textOffsetX
    gfx.y = contentY + PX(50)
    gfx.drawstr(subText)
end

drawHelpReaperHeader = function(w, contentY, textOffsetX, textOffsetY, PS)
    local function PX(val) return (PS and PS(val)) or val end
    gfx.setfont(1, "Arial", PX(26), string.byte('b'))
    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    local repTitle = getLangText("help_reaper_title", "REAPER")
    local repW = gfx.measurestr(repTitle)
    gfx.x = (w - repW) / 2 + textOffsetX
    gfx.y = contentY + PX(10) + textOffsetY
    gfx.drawstr(repTitle)

    gfx.setfont(1, "Arial", PX(13))
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    local repSub = getLangText("help_reaper_sub", "Selection, temp files, and cleanup")
    local repSubW = gfx.measurestr(repSub)
    gfx.x = (w - repSubW) / 2 + textOffsetX
    gfx.y = contentY + PX(40) + textOffsetY
    gfx.drawstr(repSub)
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
        locLine = T("tooltip_start") or "Choose audio in REAPER, then start STEMwerk."
    end

    local isWarning = (stemsPerTrack == 0)
    return { selLine = selLine, outLine = outLine, locLine = locLine, isWarning = isWarning }
end

function renderHelpTabs(ctx)
    if not ctx then return end
    local S = ctx.S
    local w = ctx.w or gfx.w
    local time = ctx.time or os.clock()
    local logoY = S(12)

    gfx.setfont(1, "Arial", S(24), string.byte('b'))
    local logoStartX, _, logoTotalWidth, logoH = drawWavingStemwerkLogo({
        w = w,
        y = logoY,
        fontSize = S(24),
        time = time,
        amp = S(2),
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
        ctx.contentTop = S(45)
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
    local fxHover = mx >= fxX - S(2) and mx <= fxX + fxSize + S(2) and my >= fxY - S(2) and my <= fxY + fxSize + S(2)

    local controlsLeft = langX - S(10)
    local controlsBottom = fxY + fxSize + S(6)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = updateControlsOpacity(GUI, mouseInControls)

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
        setTooltip(langX, langY, langW, langH, T("tooltip_change_language"))
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

    local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
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
        setTooltip(fxX - S(2), fxY - S(2), fxSize + S(4), fxSize + S(4), SETTINGS.visualFX and T("fx_disable") or T("fx_enable"))
        if mouseDown and not GUI.wasMouseDown then
            SETTINGS.visualFX = not SETTINGS.visualFX
            saveSettings()
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

    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.rect(0, 0, ctx.w, ctx.h, 1)

    drawProceduralArt(0, 0, ctx.w, ctx.h, proceduralArt.time, mainDialogArt.rotation, true)

    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 0.5)
    else
        gfx.set(1, 1, 1, 0.5)
    end
    gfx.rect(0, 0, ctx.w, ctx.h, 1)

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
    gfx.setfont(1, "Arial", S(13))

    y = tempHeaderY + S(20)
    local keepLabel = T("temp_files_keep") or "Keep"
    local deleteLabel = T("temp_files_delete") or "Delete"
    local tempLabel = SETTINGS.keepTempFiles and keepLabel or deleteLabel
    local tempR, tempG, tempB
    if SETTINGS.keepTempFiles then
        tempR = THEME.accent[1] * 255
        tempG = THEME.accent[2] * 255
        tempB = THEME.accent[3] * 255
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

    gfx.setfont(1, "Arial", S(13))
    local mainHeaderFont = S(10)

    local gutter = S(10)
    local presetsW = S(58)
    local stemsW = S(58)
    local modelColW = S(68)
    local deviceColW = S(58)
    local outputColW = S(60)
    local afterColW = S(60)

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

    local presetLabelKaraoke = (T("karaoke") or "Karaoke") .. " (K)"
    local presetLabelAll = (T("all_stems") or "All") .. " (A)"
    local presetLabelVocals = (T("vocals") or "Vocals") .. " (V)"
    local presetLabelDrums = (T("drums") or "Drums") .. " (D)"
    local presetLabelBass = (T("bass") or "Bass") .. " (B)"
    local presetLabelOther = (T("other") or "Other") .. " (O)"
    local presetLabelPiano = (T("piano") or "Piano") .. " (P)"
    local presetLabelGuitar = (T("guitar") or "Guitar") .. " (G)"
    local presetLabels = { presetLabelKaraoke, presetLabelAll, presetLabelVocals, presetLabelDrums, presetLabelBass, presetLabelOther }
    if is6Stem then
        presetLabels[#presetLabels + 1] = presetLabelPiano
        presetLabels[#presetLabels + 1] = presetLabelGuitar
    end
    local presetsColFontSize = getUniformFontSizeCached("main_presets_col", presetLabels, colW)
    local commonBtnFontSize = presetsColFontSize

    local presetY = contentTop + S(20)
    gfx.setfont(1, "Arial", S(13))

    if drawButton(col1X, presetY, colW, btnH, presetLabelKaraoke, false, {80, 80, 90}, commonBtnFontSize) then applyPresetKaraoke() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_karaoke"), "K", {255, 200, 100})
    presetY = presetY + S(22)
    if drawButton(col1X, presetY, colW, btnH, presetLabelAll, false, {80, 80, 90}, commonBtnFontSize) then applyPresetAll() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_all"), "A", {255, 200, 100})

    presetY = presetY + S(28)

    if drawButton(col1X, presetY, colW, btnH, presetLabelVocals, false, {255, 100, 100}, commonBtnFontSize) then applyPresetVocalsOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_vocals"), "V", {255, 100, 100})
    presetY = presetY + S(22)
    if drawButton(col1X, presetY, colW, btnH, presetLabelDrums, false, {100, 200, 255}, commonBtnFontSize) then applyPresetDrumsOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_drums"), "D", {100, 200, 255})
    presetY = presetY + S(22)
    if drawButton(col1X, presetY, colW, btnH, presetLabelBass, false, {150, 100, 255}, commonBtnFontSize) then applyPresetBassOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_bass"), "B", {150, 100, 255})
    presetY = presetY + S(22)
    if drawButton(col1X, presetY, colW, btnH, presetLabelOther, false, {100, 255, 150}, commonBtnFontSize) then applyPresetOtherOnly() end
    setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_other"), "O", {100, 255, 150})
    presetY = presetY + S(22)

    if is6Stem then
        if drawButton(col1X, presetY, colW, btnH, presetLabelPiano, false, {255, 120, 200}, commonBtnFontSize) then applyPresetPianoOnly() end
        setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_piano"), "P", {255, 120, 200})
        presetY = presetY + S(22)
        if drawButton(col1X, presetY, colW, btnH, presetLabelGuitar, false, {255, 180, 100}, commonBtnFontSize) then applyPresetGuitarOnly() end
        setTooltipWithShortcut(col1X, presetY, colW, btnH, T("tooltip_preset_guitar"), "G", {255, 180, 100})
        presetY = presetY + S(22)
    end

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(is6Stem and T("stems_6") or "Stems:", col2X, stemsW, mainHeaderFont, contentTop)

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
    getUniformFontSizeCached("main_stems_col", stemLabels, colW)

    for i, stem in ipairs(STEMS) do
        if not stem.sixStemOnly or is6Stem then
            local k = tostring(stem.name or ""):lower()
            local displayName = T(k) or stem.name
            local label = tostring(displayName) .. " (" .. stem.key .. ")"
            if drawToggleButton(col2X, stemY, colW, btnH, label, stem.selected, stem.color, commonBtnFontSize) then
                STEMS[i].selected = not STEMS[i].selected
            end
            local tooltipKey = stemTooltipKeys[stem.name] or "tooltip_stem_other"
            setTooltipWithShortcut(col2X, stemY, colW, btnH, T(tooltipKey), stem.key, stem.color)
            stemY = stemY + S(22)
        end
    end

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("model"), col3X, modelColW, mainHeaderFont, contentTop)
    gfx.setfont(1, "Arial", S(13))

    local modelBoxW = modelColW
    local modelLabels = {}
    for i = 1, #MODELS do
        modelLabels[#modelLabels + 1] = MODELS[i].name
    end
    modelLabels[#modelLabels + 1] = T("parallel")
    modelLabels[#modelLabels + 1] = T("sequential")
    getUniformFontSizeCached("main_model_col", modelLabels, modelBoxW)

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
        if drawRadio(col3X, modelY, SETTINGS.model == model.id, model.name, nil, modelBoxW, nil, nil, commonBtnFontSize) and modelAvailable then
            local prevModel = SETTINGS.model
            SETTINGS.model = model.id
            if prevModel ~= SETTINGS.model then
                if tostring(SETTINGS.model or "") == "htdemucs_6s" then
                    for _, st in ipairs(STEMS) do
                        st.selected = true
                    end
                else
                    for _, st in ipairs(STEMS) do
                        if st.sixStemOnly then st.selected = false end
                    end
                end
                saveSettings()
            end
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
        btnFont = commonBtnFontSize,
    }
    renderProcessingHeader(ctx)
    ctx.proc = nil

    drawDeviceColumn(col4X, deviceColW, contentTop, btnH, commonBtnFontSize, mainHeaderFont)

    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(T("output"), col5X, outputColW, mainHeaderFont, contentTop)
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

    local outBoxH = S(20)
    local iconSize = math.max(6, outBoxH * 0.52)
    local reservedLeftForIcon = S(5) + iconSize + S(8)
    getUniformFontSizeCached("main_output_col", {
        T("new_track"),
        T("new_tracks"),
        inPlaceLabel,
        HELPERS.getStemFilesHeaderLabel(),
        "Temp",
        HELPERS.getStemFileProjectLabel(),
        "Custom",
        HELPERS.getSetCustomPathLabel(),
        "Clr T+M",
        "Clr -T",
        "Clr Off",
        "Clr -M",
        T("keep_takes"),
        T("create_folder"),
        T("mute_original"),
        T("delete_original"),
        T("delete_track"),
        T("mute_selection"),
        T("delete_selection"),
        stripExplodePrefix(T("explode_to_new_tracks")),
        stripExplodePrefix(T("explode_in_place")),
        stripExplodePrefix(T("explode_in_order")),
    }, outBoxW, reservedLeftForIcon)

    local outY = contentTop + S(20)
    if drawRadio(col5X, outY, SETTINGS.createNewTracks, newTracksLabel, nil, outBoxW, nil, nil, commonBtnFontSize) then
        SETTINGS.createNewTracks = true
        SETTINGS.postProcessTakes = "none"
    end
    setTooltip(col5X, outY, outBoxW, btnH, T("tooltip_new_tracks"))
    outY = outY + S(22)
    if drawRadio(col5X, outY, not SETTINGS.createNewTracks, inPlaceLabel, nil, outBoxW, nil, nil, commonBtnFontSize) then
        SETTINGS.createNewTracks = false
    end
    setTooltip(col5X, outY, outBoxW, btnH, T("tooltip_in_place"))

    outY = outY + S(28)
    gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    drawColumnHeader(HELPERS.getStemFilesHeaderLabel(), col5X, outBoxW, mainHeaderFont, outY)
    gfx.setfont(1, "Arial", S(13))

    outY = outY + S(20)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "temp", "Temp", nil, outBoxW, nil, nil, commonBtnFontSize) then
        SETTINGS.stemFileDestination = "temp"
    end
    setTooltip(col5X, outY, outBoxW, btnH, HELPERS.getStemFilesTempTooltip())

    outY = outY + S(22)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "project_media", HELPERS.getStemFileProjectLabel(), nil, outBoxW, nil, nil, commonBtnFontSize) then
        SETTINGS.stemFileDestination = "project_media"
    end
    setTooltip(col5X, outY, outBoxW, btnH, HELPERS.getStemFilesProjectTooltip())

    outY = outY + S(22)
    if drawRadio(col5X, outY, SETTINGS.stemFileDestination == "custom", HELPERS.getStemFileCustomLabel(), nil, outBoxW, nil, nil, commonBtnFontSize) then
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
        if drawButton(col5X, outY, outBoxW, btnH, customPathLabel, false, {80, 80, 90}, commonBtnFontSize) then
            openCustomFolderDialog()
        end
        setTooltip(col5X, outY, outBoxW, btnH, HELPERS.trimString(SETTINGS.customStemDir) ~= "" and SETTINGS.customStemDir or HELPERS.getStemFilesCustomPathTooltip())
    end

    if SETTINGS.createNewTracks then
        local posR = THEME.accent[1] * 255
        local posG = THEME.accent[2] * 255
        local posB = THEME.accent[3] * 255
        local afterY = contentTop + S(20)
        local afterBoxW = afterColW

        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        drawColumnHeader(T("after"), col6X, afterBoxW, mainHeaderFont, contentTop)
        gfx.setfont(1, "Arial", S(13))

        if drawCheckbox(col6X, afterY, SETTINGS.createFolder, T("create_folder"), posR, posG, posB, afterBoxW, commonBtnFontSize) then
            SETTINGS.createFolder = not SETTINGS.createFolder
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_create_folder"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, true, HELPERS.getColorModeButtonLabel(), HELPERS.getColorModeButtonColor(), afterBoxW, nil, nil, commonBtnFontSize) then
            HELPERS.cycleColorMode()
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, HELPERS.getColorModeTooltip())

        afterY = afterY + S(22)
        if drawCheckbox(col6X, afterY, SETTINGS.muteOriginal, T("mute_original"), posR, posG, posB, afterBoxW, commonBtnFontSize) then
            SETTINGS.muteOriginal = not SETTINGS.muteOriginal
            if SETTINGS.muteOriginal then
                SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_mute_original"))

        afterY = afterY + S(22)
        local delItemColor = SETTINGS.deleteOriginal and {255, 120, 120} or {160, 160, 160}
        if drawCheckbox(col6X, afterY, SETTINGS.deleteOriginal, T("delete_original"), delItemColor[1], delItemColor[2], delItemColor[3], afterBoxW, commonBtnFontSize) then
            SETTINGS.deleteOriginal = not SETTINGS.deleteOriginal
            if SETTINGS.deleteOriginal then
                SETTINGS.muteOriginal = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_original"))

        afterY = afterY + S(22)
        local delTrackColor = SETTINGS.deleteOriginalTrack and {255, 120, 120} or {160, 160, 160}
        if drawCheckbox(col6X, afterY, SETTINGS.deleteOriginalTrack, T("delete_track"), delTrackColor[1], delTrackColor[2], delTrackColor[3], afterBoxW, commonBtnFontSize) then
            SETTINGS.deleteOriginalTrack = not SETTINGS.deleteOriginalTrack
            if SETTINGS.deleteOriginalTrack then
                SETTINGS.deleteOriginal = true; SETTINGS.muteOriginal = false
                SETTINGS.muteSelection = false; SETTINGS.deleteSelection = false
            end
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_track"))

        local hasTimeSel = hasTimeSelection()
        if hasTimeSel then
            afterY = afterY + S(22)
            if drawCheckbox(col6X, afterY, SETTINGS.muteSelection, T("mute_selection"), posR, posG, posB, afterBoxW, commonBtnFontSize) then
                SETTINGS.muteSelection = not SETTINGS.muteSelection
                if SETTINGS.muteSelection then
                    SETTINGS.muteOriginal = false; SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false
                    SETTINGS.deleteSelection = false
                end
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_mute_selection"))

            afterY = afterY + S(22)
            local delSelColor = SETTINGS.deleteSelection and {255, 120, 120} or {160, 160, 160}
            if drawCheckbox(col6X, afterY, SETTINGS.deleteSelection, T("delete_selection"), delSelColor[1], delSelColor[2], delSelColor[3], afterBoxW, commonBtnFontSize) then
                SETTINGS.deleteSelection = not SETTINGS.deleteSelection
                if SETTINGS.deleteSelection then
                    SETTINGS.muteOriginal = false; SETTINGS.deleteOriginal = false; SETTINGS.deleteOriginalTrack = false
                    SETTINGS.muteSelection = false
                end
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_delete_selection"))
        end

        local selectedMultiTakeCount = getSelectedMultiTakeCountRespectingTimeSelection()
        if (selectedMultiTakeCount or 0) > 0 then
            local t = os.clock() or 0
            local pulseMult = 0.85 + 0.25 * (0.5 + 0.5 * math.sin(t * 6.0))

            afterY = afterY + S(28)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = col6X
            gfx.y = afterY
            gfx.drawstr(T("direct") or "Direct")

            afterY = afterY + S(16)
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
            gfx.x = col6X
            gfx.y = afterY
            gfx.drawstr(T("direct_explode_now") or "Explode selected takes now")

            afterY = afterY + S(20)
            if drawRadio(col6X, afterY, false, stripExplodePrefix(T("explode_to_new_tracks")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
                applyPostProcessToSelectedCandidates("explode_new_tracks")
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_direct_explode_new_tracks"))

            afterY = afterY + S(22)
            if drawRadio(col6X, afterY, false, stripExplodePrefix(T("explode_in_place")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
                applyPostProcessToSelectedCandidates("explode_in_place")
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_direct_explode_in_place"))

            afterY = afterY + S(22)
            if drawRadio(col6X, afterY, false, stripExplodePrefix(T("explode_in_order")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
                applyPostProcessToSelectedCandidates("explode_in_order")
            end
            setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_direct_explode_in_order"))
        end
    else
        local afterY = contentTop + S(20)
        local afterBoxW = afterColW
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        drawColumnHeader(T("after"), col6X, afterBoxW, mainHeaderFont, contentTop)
        gfx.setfont(1, "Arial", S(13))

        local selectedMultiTakeCount = getSelectedMultiTakeCountRespectingTimeSelection()
        local pulseMult = 0
        if selectedMultiTakeCount > 0 then
            local t = os.clock() or 0
            pulseMult = 0.85 + 0.25 * (0.5 + 0.5 * math.sin(t * 6.0))
        end

        local mode = tostring(SETTINGS.postProcessTakes or "none")

        if drawRadio(col6X, afterY, mode == "none", T("keep_takes"), nil, afterBoxW, nil, nil, commonBtnFontSize) then
            SETTINGS.postProcessTakes = "none"
            mode = "none"
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_keep_takes"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_new_tracks", stripExplodePrefix(T("explode_to_new_tracks")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
            SETTINGS.postProcessTakes = "explode_new_tracks"
            mode = "explode_new_tracks"
            applyPostProcessToSelectedCandidates(mode)
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_explode_to_new_tracks"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_in_place", stripExplodePrefix(T("explode_in_place")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
            SETTINGS.postProcessTakes = "explode_in_place"
            mode = "explode_in_place"
            applyPostProcessToSelectedCandidates(mode)
        end
        setTooltip(col6X, afterY, afterBoxW, btnH, T("tooltip_explode_in_place"))

        afterY = afterY + S(22)
        if drawRadio(col6X, afterY, mode == "explode_in_order", stripExplodePrefix(T("explode_in_order")), nil, afterBoxW, pulseMult, "explode", commonBtnFontSize) then
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

    local footerRow4Y = statusBarY - S(10) - btnH
    local footerLines = buildFooterLines()
    local selLine = footerLines.selLine or ""
    local outLine = footerLines.outLine or ""
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

    if isWarning then
        gfx.set(1, 0.3, 0.3, 1)
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
    end
    gfx.x = w - statusPadX - outTw
    gfx.y = row1Y
    gfx.drawstr(outLabel)

    gfx.setfont(1, "Arial", statusSubFontSize)
    local locLabel = fitTextToBox(locLine, availableW, statusSubFontSize, statusSubFontSize)
    if isWarning then
        gfx.set(1, 0.35, 0.35, 0.95)
    else
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.82)
    end
    gfx.x = statusPadX
    gfx.y = row2Y
    gfx.drawstr(locLabel)

    local footerMarginX = S(10)
    local stemBtnX = w - footerMarginX - stemBtnW
    local mx, my = ctx.mx, ctx.my
    local stemBtnHover = mx >= stemBtnX and mx <= stemBtnX + stemBtnW and my >= footerRow4Y and my <= footerRow4Y + btnH
    local stemBtnColor = stemBtnHover and THEME.buttonPrimaryHover or THEME.buttonPrimary

    drawGlossyPill(stemBtnX, footerRow4Y, stemBtnW, btnH, stemBtnColor[1], stemBtnColor[2], stemBtnColor[3])

    gfx.setfont(1, "Arial", S(13), string.byte('b'))
    local textY = footerRow4Y + (btnH - gfx.texth) / 2

    local letters = {"S", "T", "E", "M", "w", "e", "r", "k"}
    local letterWidths = {}
    local totalWidth = 0
    for i, letter in ipairs(letters) do
        local lw = gfx.measurestr(letter)
        letterWidths[i] = lw
        totalWidth = totalWidth + lw
    end
    local textX = stemBtnX + (stemBtnW - totalWidth) / 2

    local stemColors = {
        {255/255, 100/255, 100/255},
        {100/255, 200/255, 255/255},
        {150/255, 100/255, 255/255},
        {100/255, 255/255, 150/255},
    }

    local offsets = {
        {1, 1}, {-1, 1}, {1, -1}, {-1, -1},
    }
    for _, off in ipairs(offsets) do
        local ox = textX + off[1]
        local oy = textY + off[2]
        gfx.set(0, 0, 0, 0.6)
        for i, letter in ipairs(letters) do
            gfx.x = ox
            gfx.y = oy
            gfx.drawstr(letter)
            ox = ox + letterWidths[i]
        end
    end

    for i, letter in ipairs(letters) do
        if i <= 4 then
            gfx.set(stemColors[i][1], stemColors[i][2], stemColors[i][3], 1)
        else
            gfx.set(1, 1, 1, 1)
        end
        gfx.x = textX
        gfx.y = textY
        gfx.drawstr(letter)
        textX = textX + letterWidths[i]
    end

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

    local closeR, closeG, closeB = 0.7, 0.2, 0.2
    if closeBtnHover then
        closeR, closeG, closeB = 0.9, 0.3, 0.3
    end
    drawGlossyPill(closeBtnX, footerRow4Y, closeBtnW, btnH, closeR, closeG, closeB)

    gfx.setfont(1, "Arial", S(13), string.byte('b'))
    local closeText = T("close") or "Close"
    local closeTextW = gfx.measurestr(closeText)
    local closeTextX = closeBtnX + (closeBtnW - closeTextW) / 2
    local closeTextY = footerRow4Y + (btnH - gfx.texth) / 2
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

    if closeBtnHover and GUI.wasMouseDown and not ctx.mouseDown then
        GUI.result = false
    end
    setTooltip(closeBtnX, footerRow4Y, closeBtnW, btnH, T("tooltip_close"))

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

openCustomFolderDialog = function()
    GUI.modal = {
        mode = "input",
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

canStartProcessingFromDialog = function()
    if OS == "Windows" and GUI and GUI.windowsStartupMonitor and not hasAnySelection() then
        local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
        openDialogWarning(promptTitle, promptMessage)
        return false
    end

    local is6Stem = (tostring(SETTINGS.model or "") == "htdemucs_6s")
    local validSelected = false
    for _, stem in ipairs(STEMS) do
        if stem.selected and ((not stem.sixStemOnly) or is6Stem) then
            validSelected = true
            break
        end
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
    elseif char == 49 then STEMS[1].selected = not STEMS[1].selected
    elseif char == 50 then STEMS[2].selected = not STEMS[2].selected
    elseif char == 51 then STEMS[3].selected = not STEMS[3].selected
    elseif char == 52 then STEMS[4].selected = not STEMS[4].selected
    elseif char == 53 and SETTINGS.model == "htdemucs_6s" then STEMS[5].selected = not STEMS[5].selected
    elseif char == 54 and SETTINGS.model == "htdemucs_6s" then STEMS[6].selected = not STEMS[6].selected
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
            SETTINGS.model = "htdemucs"
            for _, st in ipairs(STEMS) do if st.sixStemOnly then st.selected = false end end
            saveSettings()
        end
    elseif char == 113 or char == 81 then
        if isModelAvailableInCurrentMode("htdemucs_ft") then
            SETTINGS.model = "htdemucs_ft"
            for _, st in ipairs(STEMS) do if st.sixStemOnly then st.selected = false end end
            saveSettings()
        end
    elseif char == 115 or char == 83 then
        if isModelAvailableInCurrentMode("htdemucs_6s") then
            SETTINGS.model = "htdemucs_6s"
            saveSettings()
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
                isProcessingActive = false
                showMessage("Error", "STEMwerk crashed while starting processing.\n\nSee log:\n" .. tostring(DEBUG.logPath), "error")
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
        if applyCachedRuntimeDevices() then
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

-- Get temp directory (cross-platform)
local function getTempDir()
    if OS == "Windows" then
        return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    else
        local flatpakTemp = getFlatpakTempBase()
        if flatpakTemp then return flatpakTemp end
        return os.getenv("TMPDIR") or "/tmp"
    end
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

-- Create directory (cross-platform)
local function makeDir(path)
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return
    end
    if OS == "Windows" then
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end

-- Suppress stderr (cross-platform)
local function suppressStderr()
    return OS == "Windows" and " 2>nul" or " 2>/dev/null"
end

-- Cleanup temp working files (keep output stems)
local function normalizePath(p)
    if not p then return "" end
    local norm = tostring(p)
    if OS == "Windows" then
        norm = norm:gsub("/", "\\")
        norm = norm:lower()
    else
        norm = norm:gsub("\\", "/")
    end
    return norm
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

local function cleanupTempWorkDir(dir)
    if not dir or dir == "" then return end
    if SETTINGS and SETTINGS.keepTempFiles then
        debugLog("cleanupTempWorkDir: keepTempFiles enabled, skipping " .. tostring(dir))
        return
    end
    if not isSafeTempDir(dir) then
        debugLog("cleanupTempWorkDir: skip unsafe path " .. tostring(dir))
        return
    end

    if not (reaper and reaper.EnumerateFiles) then
        local known = {"input.wav", "stdout.txt", "separation_log.txt", "done.txt", "pid.txt"}
        for _, name in ipairs(known) do
            os.remove(dir .. PATH_SEP .. name)
        end
        os.remove(dir .. PATH_SEP .. "input.wav.ffmpeg.log")
        return
    end

    local idx = 0
    while true do
        local f = reaper.EnumerateFiles(dir, idx)
        if not f then break end
        local lower = tostring(f):lower()
        local full = dir .. PATH_SEP .. f
        if lower == "input.wav" then
            os.remove(full)
        elseif lower:match("%.wav$") then
            -- Keep outputs (stems)
        else
            os.remove(full)
        end
        idx = idx + 1
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

    -- Try to set bounds when available (not required, but can improve correctness).
    if reaper.GetSet_AudioAccessorStartTime then
        pcall(function() reaper.GetSet_AudioAccessorStartTime(acc, true, sampleStart) end)
    end
    if reaper.GetSet_AudioAccessorEndTime then
        pcall(function() reaper.GetSet_AudioAccessorEndTime(acc, true, sampleEnd) end)
    end

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

    f:write("RIFF")
    riffSizePos = f:seek()  -- position after 'RIFF'
    f:write(string.pack("<I4", 0)) -- placeholder riff size
    f:write("WAVE")
    f:write("fmt ")
    f:write(string.pack("<I4", 16)) -- fmt chunk size
    f:write(string.pack("<I2", 3))  -- audio format 3 = IEEE float
    f:write(string.pack("<I2", ch))
    f:write(string.pack("<I4", sr))
    f:write(string.pack("<I4", byteRate))
    f:write(string.pack("<I2", blockAlign))
    f:write(string.pack("<I2", 32)) -- bits per sample
    f:write("data")
    dataSizePos = f:seek()
    f:write(string.pack("<I4", 0)) -- placeholder data size

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
            parts[i] = string.pack("<f", buf[i] or 0.0)
        end
        f:write(table.concat(parts))
        framesWritten = framesWritten + need
        curTime = curTime + (need / sr)
    end

    reaper.DestroyAudioAccessor(acc)

    -- Finalize header sizes
    local dataBytes = framesWritten * ch * bytesPerSample
    local fileEnd = f:seek("end")
    -- data chunk size
    f:seek("set", dataSizePos)
    f:write(string.pack("<I4", dataBytes))
    -- riff chunk size = fileSize - 8
    f:seek("set", riffSizePos)
    f:write(string.pack("<I4", fileEnd - 8))
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


-- Execute command without showing a window (Windows-specific)
-- On Windows, os.execute() shows a brief CMD flash. This avoids that.
function execHidden(cmd)
    debugLog("execHidden called")
    debugLog("  Command: " .. cmd:sub(1, 200) .. (cmd:len() > 200 and ".." or ""))
    if OS == "Windows" then
        local directCmd = tostring(cmd or "")
        directCmd = directCmd:gsub("%s+2>nul%s*$", "")

        if reaper and reaper.ExecProcess and not SW_LOG.commandNeedsWindowsShell(directCmd) then
            debugLog("  Using reaper.ExecProcess (direct, no shell)")
            reaper.ExecProcess(directCmd, 0)
            debugLog("  Command completed")
            return
        end

        -- Fall back to a temporary VBS wrapper and execute the original command string
        -- directly, without nesting it inside another cmd.exe /c layer.
        local tempDir = os.getenv("TEMP") or os.getenv("TMP") or "."
        local vbsPath = tempDir .. "\\STEMwerk_exec_" .. os.time() .. ".vbs"
        debugLog("  VBS path: " .. vbsPath)
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            vbsFile:write('On Error Resume Next\n')
            vbsFile:write('Dim sh, p\n')
            vbsFile:write('Set sh = CreateObject("WScript.Shell")\n')
            vbsFile:write('Set p = sh.Exec("' .. directCmd:gsub('"', '""') .. '")\n')
            vbsFile:write('Do While p.Status = 0\n')
            vbsFile:write('  WScript.Sleep 50\n')
            vbsFile:write('Loop\n')
            vbsFile:close()
            debugLog("  VBS file created")

            if reaper.ExecProcess then
                debugLog("  Using reaper.ExecProcess via hidden wscript wrapper")
                reaper.ExecProcess('wscript "' .. vbsPath .. '"', 0)  -- 0 = wait for completion
            else
                debugLog("  Using os.execute via hidden wscript wrapper")
                os.execute('wscript "' .. vbsPath .. '"')
            end
            debugLog("  Command completed")

            -- Clean up VBS file
            os.remove(vbsPath)
            debugLog("  VBS file cleaned up")
        else
            -- Fallback to os.execute if VBS creation fails
            debugLog("  VBS creation failed, falling back to os.execute")
            os.execute(cmd)
        end
    else
        debugLog("  Non-Windows, using os.execute")
        os.execute(cmd)
    end
    debugLog("execHidden done")
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
    if not playrate or playrate < 0.0001 then
        debugLog("renderItemToWav: suspicious take playrate=" .. tostring(playrate) .. " -> using 1.0")
        playrate = 1.0
    end

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

    -- Partial slices must reflect the item/take as arranged in REAPER, including split
    -- context and item-local offsets. Prefer AudioAccessor there; keep ffmpeg as the fast
    -- path for full-item extracts.
    if isPartialSlice then
        local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
        if accOk and fileSizeBytes(outputPath) > 1024 then
            return outputPath, nil, renderStart, renderEnd - renderStart
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

    -- Prefer ffmpeg (fast). If it fails, fall back to REAPER AudioAccessor (robust).
    local ok, ffmpegLog = runFfmpegExtract(sourceFile, renderOffset, renderDuration, outputPath)
    if ok then
        return outputPath, nil, renderStart, renderEnd - renderStart
    end
    local accOk, accErr = renderTakeAccessorToWav(take, renderStart, renderEnd, outputPath)
    if accOk and fileSizeBytes(outputPath) > 1024 then
        return outputPath, nil, renderStart, renderEnd - renderStart
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
}

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
    gfx.init(WINDOW_PROCESSING, winW, winH, 0, winX, winY)
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
    local title = "STEMwerk"
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
    captureWindowGeometry(WINDOW_PROCESSING)
    saveSettings()
    gfx.quit()
    progressState.windowOpen = false
    progressState.running = false
end

-- Multi-track queue state (declared early for access in drawProgressWindow)
local multiTrackQueue = {
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

-- Forward declarations for multi-track processing
local runSingleTrackSeparation
local startSeparationProcessForJob
local updateAllJobsProgress
local allJobsDone
local getOverallProgress
local showMultiTrackProgressWindow
local processAllStemsResult

-- Progress window base dimensions for scaling (taller for art)
local PROGRESS_BASE_W = 480
local PROGRESS_BASE_H = 420

local function normalizeProgressStage(stage)
    stage = tostring(stage or "")
    -- Strip timing + device suffixes to keep the terminal line clean.
    stage = stage:gsub("%s*%b[]", "")
    stage = stage:gsub("%s*%b()", "")
    stage = stage:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if stage == "" then
        stage = T("processing_label") or "Processing"
    elseif stage:lower():match("^processing") then
        stage = T("processing_label") or "Processing"
    end
    return stage
end

local function formatProgressLine(rawLine, trackIdx)
    if not rawLine or rawLine == "" then return nil end
    local percent, stage = rawLine:match("PROGRESS:(%d+):(.+)")
    if not percent then return nil end
    local progressLabel = T("progress_label") or "Progress"
    local stageLabel = normalizeProgressStage(stage)
    local prefix = ""
    if trackIdx then
        local trackLabel = T("track_prefix") or "Track"
        prefix = "[" .. tostring(trackLabel) .. " " .. tostring(trackIdx) .. "] "
    end
    return string.format("%s%s: %s%% %s", prefix, progressLabel, percent, stageLabel)
end

local function drawTerminalFx(x, y, w, h, now, borderR, borderG, borderB, progR, progG, progB)
    if not SETTINGS.visualFX then return end
    if not x or not y or not w or not h then return end
    if w < 4 or h < 4 then return end
    now = now or os.clock()
    local scale = 1
    if PROGRESS_BASE_W and PROGRESS_BASE_H then
        scale = math.min(w / PROGRESS_BASE_W, h / PROGRESS_BASE_H)
        scale = math.max(0.5, math.min(4.0, scale))
    end
    local function px(val) return math.floor(val * scale + 0.5) end

    local scanY = y + (math.floor(now * 22) % math.max(1, math.floor(h - 2)))
    gfx.set(borderR or 0, borderG or 0, borderB or 0, SETTINGS.darkMode and 0.12 or 0.18)
    gfx.rect(x + 1, scanY, w - 2, 1, 1)

    local lineStep = px(4)
    local lineAlpha = SETTINGS.darkMode and 0.05 or 0.04
    gfx.set(borderR or 0, borderG or 0, borderB or 0, lineAlpha)
    for yy = y + 1, y + h - 2, lineStep do
        gfx.line(x + 1, yy, x + w - 2, yy)
    end

    local barH = px(5)
    local barW = math.max(px(28), 14)
    local pad = px(4)
    local span = math.max(1, w - (pad * 2) - barW)
    local cycle = 0.72
    local theta = now * cycle * (math.pi * 2)
    local smooth = (1 - math.cos(theta)) * 0.5
    local velocity = math.sin(theta)
    local edge = 1 - math.min(smooth, 1 - smooth) * 2
    local squash = edge * edge
    local ledW = barW * (1 - 0.18 * squash)
    local ledH = barH * (1 + 0.12 * squash)
    local ledX = x + pad + (span * smooth) + (barW - ledW) * 0.5
    local ledY = y + h - pad - ledH
    local glowW = ledW * 1.6
    local glowH = ledH * 1.6
    local glowX = ledX - (glowW - ledW) * 0.5
    local glowY = ledY - (glowH - ledH) * 0.5
    local ledR = progR or 1
    local ledG = progG or 1
    local ledB = progB or 1
    local lum = (ledR * 0.2126) + (ledG * 0.7152) + (ledB * 0.0722)
    local hot = math.max(0, math.min(1, (0.55 - lum) * 1.6))
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.18 or 0.12)
    gfx.rect(glowX, glowY, glowW, glowH, 1)

    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.7 or 0.6)
    gfx.rect(ledX, ledY, ledW, ledH, 1)

    local coreW = ledW * 0.55
    local coreH = ledH * 0.55
    local coreX = ledX + (ledW - coreW) * 0.5
    local coreY = ledY + (ledH - coreH) * 0.5
    local coreR = ledR + (1 - ledR) * (hot * 0.75)
    local coreG = ledG + (1 - ledG) * (hot * 0.75)
    local coreB = ledB + (1 - ledB) * (hot * 0.75)
    gfx.set(coreR, coreG, coreB, SETTINGS.darkMode and 0.85 or 0.8)
    gfx.rect(coreX, coreY, coreW, coreH, 1)
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.25 or 0.2)
    gfx.rect(ledX + 1, ledY + 1, ledW - 2, 1, 1)

    local tailScale = math.min(1, math.abs(velocity) * 1.6) * (1 - 0.25 * squash)
    local tail1, tail2, tail3, tail4 = px(16) * tailScale, px(30) * tailScale, px(44) * tailScale, px(60) * tailScale
    local tailDir = velocity >= 0 and -1 or 1

    local tailX = (tailDir == -1) and (ledX - tail1) or ledX
    local tailW = ledW + tail1
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.32 or 0.24)
    gfx.rect(tailX, ledY, tailW, ledH, 1)

    tailX = (tailDir == -1) and (ledX - tail2) or ledX
    tailW = ledW + tail2
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.22 or 0.16)
    gfx.rect(tailX, ledY, tailW, ledH, 1)

    tailX = (tailDir == -1) and (ledX - tail3) or ledX
    tailW = ledW + tail3
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.14 or 0.1)
    gfx.rect(tailX, ledY + 1, tailW, ledH - 1, 1)

    tailX = (tailDir == -1) and (ledX - tail4) or ledX
    tailW = ledW + tail4
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.09 or 0.06)
    gfx.rect(tailX, ledY + 2, tailW, 1, 1)
end

-- Progress window resizable flag
local progressWindowResizableSet = false

-- Make progress window resizable
local function makeProgressWindowResizable()
    if progressWindowResizableSet then return true end
    if not reaper.JS_Window_Find then return false end
    if not reaper.JS_Window_GetLong or not reaper.JS_Window_SetLong then
        warnMissingJsWindowStyleApi("progress window resize setup")
        return false
    end

    local hwnd = reaper.JS_Window_Find(WINDOW_PROCESSING, true)
    if not hwnd then return false end

    local style = reaper.JS_Window_GetLong(hwnd, "STYLE")
    if style then
        local WS_THICKFRAME = 0x00040000
        local WS_MAXIMIZEBOX = 0x00010000
        reaper.JS_Window_SetLong(hwnd, "STYLE", style | WS_THICKFRAME | WS_MAXIMIZEBOX)
    end

    progressWindowResizableSet = true
    return true
end

-- Animated waveform data for eye candy
local waveformState = {
    bars = {},
    particles = {},
    lastUpdate = 0,
    pulsePhase = 0,
}

-- Initialize waveform bars
local function initWaveformBars(count)
    waveformState.bars = {}
    for i = 1, count do
        waveformState.bars[i] = {
            height = math.random() * 0.5 + 0.2,
            targetHeight = math.random() * 0.8 + 0.2,
            velocity = 0,
            phase = math.random() * math.pi * 2,
        }
    end
end

-- Draw progress window with stem colors and eye candy (scalable)
local function drawProgressWindow()
    local w, h = gfx.w, gfx.h

    -- Calculate scale based on window size
    local scaleW = w / PROGRESS_BASE_W
    local scaleH = h / PROGRESS_BASE_H
    local scale = math.min(scaleW, scaleH)
    scale = math.max(0.5, math.min(4.0, scale))  -- Clamp scale

    -- Scaling helper
    local function PS(val) return math.floor(val * scale + 0.5) end

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
    drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

    -- Semi-transparent overlay for readability - pure black/white
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 0.5)
    else
        gfx.set(1, 1, 1, 0.5)
    end
    gfx.rect(0, 0, w, h, 1)

    -- Mouse position for UI interactions
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local rightMouseDown = gfx.mouse_cap & 2 == 2
    local mouseWheel = gfx.mouse_wheel

    -- Tooltip tracking
    local tooltipText = nil
    local tooltipX, tooltipY = 0, 0

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
    local themeSize = math.max(PS(11), math.floor(PS(18) * iconScale + 0.5))
    local themeX = w - themeSize - PS(8)
    local themeY = PS(6)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = updateControlsOpacity(progressState, mouseInControls)

    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.5) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)  -- Pure black for moon overlay
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

    -- Theme click and tooltip
    if themeHover and controlsOpacity > 0.3 then
        GUI.uiClickedThisFrame = true
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if rightMouseDown and not (progressState.wasRightMouseDown or false) then
            cycleThemePreset()
        end
        if mouseDown and not progressState.wasMouseDown then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
    end

    -- === LANGUAGE TOGGLE (next to theme) ===
    local langCode = string.upper(SETTINGS.language or "EN")
    gfx.setfont(1, "Arial", PS(8))
    local langW = gfx.measurestr(langCode)
    local langX = themeX - langW - PS(10)
    local langY = themeY + PS(3)
    local langHover = mx >= langX - PS(3) and mx <= langX + langW + PS(3) and my >= langY - PS(2) and my <= langY + PS(10)
    gfx.set(0.5, 0.6, 0.8, (langHover and 1 or 0.4) * controlsOpacity)
    gfx.x = langX
    gfx.y = langY
    gfx.drawstr(langCode)

    -- Language tooltip and click
    if langHover and controlsOpacity > 0.3 then
        GUI.uiClickedThisFrame = true
        tooltipText = T("tooltip_change_language")
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end
    if langHover and rightMouseDown and not (progressState.wasRightMouseDown or false) and controlsOpacity > 0.3 then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end
    if langHover and mouseDown and not progressState.wasMouseDown and controlsOpacity > 0.3 then
        local langs = {"en", "nl", "de"}
        local currentIdx = 1
        for i, l in ipairs(langs) do
            if l == SETTINGS.language then currentIdx = i break end
        end
        local nextIdx = (currentIdx % #langs) + 1
        setLanguage(langs[nextIdx])
        saveSettings()
    end

    -- === FX TOGGLE (below theme icon) ===
    local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + PS(3)
    local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)

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

    if fxHover and controlsOpacity > 0.3 then
        GUI.uiClickedThisFrame = true
        tooltipText = SETTINGS.visualFX and T("fx_disable") or T("fx_enable")
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end
    if fxHover and mouseDown and not progressState.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
    end

    -- NOTE: wasMouseDown is set at END of function to allow art click detection

    -- Get selected stems for colors
    local selectedStems = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
            table.insert(selectedStems, stem)
        end
    end

    -- Single-track progress layout
    local barX = PS(38)
    local barY = PS(102)
    local barW = w - (barX * 2)
    local barH = PS(24)

    -- Model badge (align with progress bar at right side)
    local modelText = SETTINGS.model or "htdemucs"
    gfx.setfont(1, "Arial", PS(11))
    local modelW = gfx.measurestr(modelText) + PS(16)
    local badgeX = barX + barW - modelW
    local badgeY = barY + math.floor((barH - PS(18)) / 2)
    local badgeH = PS(18)
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 1)
    gfx.rect(badgeX, badgeY, modelW, badgeH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(badgeX, badgeY, modelW, badgeH, 0)
    gfx.set(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
    gfx.x = badgeX + PS(8)
    gfx.y = badgeY + PS(2)
    gfx.drawstr(modelText)

    -- Title / branding
    gfx.setfont(1, "Arial", PS(18), string.byte('b'))
    local titleX = PS(25)
    local titleY = PS(28)

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
        local singleTrackLabel = T("single_track") or "Single-Track"
        gfx.drawstr(singleTrackLabel .. " ")
        local aiW = gfx.measurestr(singleTrackLabel .. " ")

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

    -- Stem indicators (simple colored boxes)
    local stemX = PS(25)
    local stemY = PS(63)
    local stemBoxSize = PS(14)
    gfx.setfont(1, "Arial", PS(11))
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
            -- Stem color box
            gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
            gfx.rect(stemX, stemY, stemBoxSize, stemBoxSize, 1)
            -- Stem name
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = stemX + stemBoxSize + PS(6)
            gfx.y = stemY + PS(1)
            gfx.drawstr(stem.name)
            stemX = stemX + stemBoxSize + gfx.measurestr(stem.name) + PS(20)
        end
    end

    -- Progress bar background
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 1)
    gfx.rect(barX, barY, barW, barH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(barX, barY, barW, barH, 0)

    -- Progress bar fill with stem color gradient
    local fillWidth = math.floor(barW * progressState.percent / 100)
    if fillWidth > 0 and #selectedStems > 0 then
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

    local function drawProgressText(text, x, y, alpha)
        alpha = alpha or 1
        gfx.set(0, 0, 0, 0.6 * alpha)
        gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
        gfx.x, gfx.y = x - 1, y + 1; gfx.drawstr(text)
        gfx.x, gfx.y = x + 1, y - 1; gfx.drawstr(text)
        gfx.x, gfx.y = x - 1, y - 1; gfx.drawstr(text)
        gfx.set(1, 1, 1, alpha)
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

    -- Stage text inside the main progress bar, like the multi-track job bars.
    local stageDisplay = normalizeProgressStage(progressState.stage or (T("starting") or "Starting..."))
    local inlineStageText = tostring(stageDisplay or "")
        :gsub("%s*%([^%)]*%)", "")
        :gsub("%s*%[[^%]]*%]", "")
        :gsub("%s+$", "")
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
        if progressState.showTerminal then
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

    local footerElapsed = os.time() - (progressState.startTime or os.time())
    local footerProcessedAudioDur = 0
    if itemSubSelection and itemSubSelEnd and itemSubSelStart and itemSubSelEnd > itemSubSelStart then
        footerProcessedAudioDur = itemSubSelEnd - itemSubSelStart
    elseif itemLen and itemLen > 0 then
        footerProcessedAudioDur = itemLen
    end
    local footerRealtimeFactor = (footerProcessedAudioDur > 0 and footerElapsed > 0) and (footerProcessedAudioDur / footerElapsed) or 0
    local footerDeviceDetail = (progressState.stage or ""):match("%[([^%]]+)%]") or nil
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

            if SETTINGS.darkMode then
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
            if selectedStems and #selectedStems > 0 then
                local n = #selectedStems
                local p = tonumber(progressState.percent) or 0
                local idx = math.floor((p / 100) * n) + 1
                if idx < 1 then idx = 1 end
                if idx > n then idx = n end
                local sc = selectedStems[idx].color or {255, 255, 255}
                accentR, accentG, accentB = (sc[1] or 255) / 255, (sc[2] or 255) / 255, (sc[3] or 255) / 255
            end

            -- Apply tint to header/border (keep error/warn colors intact).
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
            end

            -- Match the LED/progress tint to the active track color when available.
            if progressState.uiColor and type(progressState.uiColor) == "table" then
                termProgR, termProgG, termProgB = progressState.uiColor[1] or termProgR, progressState.uiColor[2] or termProgG, progressState.uiColor[3] or termProgB
            end

            -- Dark terminal background
            gfx.set(termBgR, termBgG, termBgB, termBgA)
            gfx.rect(displayX, displayY, displayW, displayH, 1)

            -- Terminal border (green)
            gfx.set(termBorderR, termBorderG, termBorderB, termBorderA)
            gfx.rect(displayX, displayY, displayW, displayH, 0)
            if SETTINGS.visualFX then
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
            if math.floor(now * 2) % 2 == 0 then
                gfx.set(termOkR, termOkG, termOkB, 1)
                gfx.x = displayX + PS(5)
                gfx.y = math.min(lineY, displayY + displayH - lineHeight - PS(5))
                gfx.drawstr("_")
            end

            -- Terminal hint
            gfx.set(termDimR, termDimG, termDimB, termDimA)
            gfx.setfont(1, "Courier", PS(8))
            local termHint = T("terminal_hint_return_to_art") or "Click >_ to return to art"
            local termHintW = gfx.measurestr(termHint)
            gfx.x = displayX + (displayW - termHintW) / 2
            gfx.y = displayY + displayH - PS(16)
            gfx.drawstr(termHint)

        else
            -- === ART INFO VIEW ===
            -- Keep the art clean; allow regenerating without overlay labels.
            local artHover = mx >= displayX and mx <= displayX + displayW and my >= displayY and my <= displayY + displayH
            if artHover then
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

    -- Update mouse state AFTER all click handling
    progressState.wasMouseDown = mouseDown
    progressState.wasRightMouseDown = rightMouseDown

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
    local modelDisplay = (SETTINGS.model == "htdemucs_ft") and "Quality" or ((SETTINGS.model == "htdemucs_6s") and "6-Stem" or "Fast")
    local mtTime = T("mt_time") or "Time"
    local mtSeg = T("mt_seg") or "Seg"
    local mtCancel = T("mt_cancel") or "ESC=cancel"

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
    gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], statusBlockAlpha)
    gfx.rect(0, statusBlockY, w, statusBlockH, 1)
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], statusBlockBorderAlpha)
    gfx.rect(0, statusBlockY, w, statusBlockH, 0)

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
    gfx.x = w - statusPadX - rightTw
    gfx.y = row1Y
    gfx.drawstr(rightLabel)

    if hasSummaryFooter then
        local summaryFontSize = PS(9)
        gfx.setfont(1, "Arial", summaryFontSize)
        local summaryLeftLabel = fitTextToBox(summaryLeft or "", leftW, summaryFontSize, summaryFontSize)
        local summaryRightLabel, summaryRightTw = fitTextToBox(summaryRight or "", rightW, summaryFontSize, summaryFontSize)
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.78)
        gfx.x = statusPadX
        gfx.y = row2Y
        gfx.drawstr(summaryLeftLabel)
        if summaryRight and summaryRight ~= "" then
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.68)
            gfx.x = w - statusPadX - summaryRightTw
            gfx.y = row2Y
            gfx.drawstr(summaryRightLabel)
        end
    end

    -- flarkAUDIO logo at top (translucent) - "flark" regular, "AUDIO" bold
    gfx.setfont(1, "Arial", PS(10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2
    -- Orange text, 50% translucent
    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", PS(10))
    gfx.x = logoStartX
    gfx.y = PS(3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = PS(3)
    gfx.drawstr(audioPart)

    -- === DRAW TOOLTIP (always on top, with STEM colors) ===
    if tooltipText then
        gfx.setfont(1, "Arial", PS(11))
        local padding = PS(8)
        local lineH = PS(14)
        local maxTextW = math.min(w * 0.62, PS(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    gfx.update()
end

-- Refactor flow helpers into module-like namespaces to reduce top-level locals.
WORKFLOW = WORKFLOW or {}
HELPERS = HELPERS or {}
UI = UI or {}

function HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stemName)
    local trackBase = tostring(sourceTrackName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local itemBase = tostring(sourceItemName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local stemBase = tostring(stemName or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if trackBase == "" then trackBase = "Track" end
    if itemBase == "" then itemBase = trackBase end
    if stemBase == "" then stemBase = "Stem" end

    local takeName = itemBase .. " - " .. stemBase
    local folderBase = trackBase
    if itemBase ~= "" and itemBase ~= trackBase then
        folderBase = trackBase .. " - " .. itemBase
    end

    return {
        folderBase = folderBase,
        trackName = folderBase .. " - " .. stemBase,
        takeName = takeName,
    }
end

function HELPERS.trimString(s)
    s = tostring(s or "")
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function HELPERS.getUiLanguageCode()
    local lang = tostring((SETTINGS and SETTINGS.language) or "en"):lower()
    if lang:find("nl", 1, true) == 1 then return "nl" end
    if lang:find("de", 1, true) == 1 then return "de" end
    return "en"
end

function HELPERS.getColorMode()
    SETTINGS.colorMode = normalizeColorMode(SETTINGS.colorMode)
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")
    return SETTINGS.colorMode
end

function HELPERS.setColorMode(mode)
    SETTINGS.colorMode = normalizeColorMode(mode)
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")
end

function HELPERS.cycleColorMode()
    local order = {
        both = "no_track",
        no_track = "off",
        off = "no_media",
        no_media = "both",
    }
    HELPERS.setColorMode(order[HELPERS.getColorMode()] or "both")
end

function HELPERS.isTrackColoringEnabled()
    local mode = HELPERS.getColorMode()
    return mode ~= "no_track" and mode ~= "off"
end

function HELPERS.isMediaColoringEnabled()
    local mode = HELPERS.getColorMode()
    return mode ~= "no_media" and mode ~= "off"
end

function HELPERS.getColorModeButtonLabel()
    local mode = HELPERS.getColorMode()
    if mode == "no_track" then
        return "Clr -T"
    elseif mode == "no_media" then
        return "Clr -M"
    elseif mode == "off" then
        return "Clr Off"
    end
    return "Clr T+M"
end

function HELPERS.getColorModeButtonColor()
    if HELPERS.getColorMode() == "off" then
        return {120, 120, 120}
    end
    return nil
end

function HELPERS.getColorModeTooltip()
    local mode = HELPERS.getColorMode()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then
        if mode == "no_track" then
            return "Trackkleur uit. Item/media-kleur blijft aan. Klik om te wisselen."
        elseif mode == "no_media" then
            return "Item/media-kleur uit. Trackkleur blijft aan. Klik om te wisselen."
        elseif mode == "off" then
            return "Track- en item/media-kleur uit. Klik om te wisselen."
        end
        return "Track- en item/media-kleur aan. Klik om te wisselen."
    elseif lang == "de" then
        if mode == "no_track" then
            return "Track-Farbe aus. Item/Medien-Farbe bleibt an. Klicken zum Wechseln."
        elseif mode == "no_media" then
            return "Item/Medien-Farbe aus. Track-Farbe bleibt an. Klicken zum Wechseln."
        elseif mode == "off" then
            return "Track- und Item/Medien-Farbe aus. Klicken zum Wechseln."
        end
        return "Track- und Item/Medien-Farbe an. Klicken zum Wechseln."
    end
    if mode == "no_track" then
        return "Track colors off. Item/media colors stay on. Click to cycle."
    elseif mode == "no_media" then
        return "Item/media colors off. Track colors stay on. Click to cycle."
    elseif mode == "off" then
        return "Track and item/media colors off. Click to cycle."
    end
    return "Track and item/media colors on. Click to cycle."
end

function HELPERS.applyTrackColorIfEnabled(track, color)
    if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then return end
    if not HELPERS.isTrackColoringEnabled() then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.applyItemColorIfEnabled(item, color)
    if not (item and reaper.ValidatePtr(item, "MediaItem*")) then return end
    if not HELPERS.isMediaColoringEnabled() then
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.applyTakeColorIfEnabled(take, color)
    if not (take and reaper.ValidatePtr(take, "MediaItem_Take*")) then return end
    if not HELPERS.isMediaColoringEnabled() then
        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.getStemFileDestinationLabel()
    local mode = tostring(SETTINGS.stemFileDestination or "temp")
    if mode == "project_media" then
        return HELPERS.getStemFileProjectLabel and HELPERS.getStemFileProjectLabel() or "Project"
    elseif mode == "custom" then
        return HELPERS.getStemFileCustomLabel and HELPERS.getStemFileCustomLabel() or "Custom"
    end
    return "Temp"
end

function HELPERS.getStemFilesHeaderLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "de" then return "Stem-Dateien:" end
    return "Stem files:"
end

function HELPERS.getStemFileProjectLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "de" then return "Projekt" end
    return "Project"
end

function HELPERS.getStemFileCustomLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Eigen" end
    if lang == "de" then return "Eigen" end
    return "Custom"
end

function HELPERS.getSetCustomPathLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Kies map" end
    if lang == "de" then return "Ordner" end
    return "Set folder"
end

function HELPERS.getCustomFolderPromptTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "STEMwerk aangepaste stemmap" end
    if lang == "de" then return "STEMwerk Stem-Ordner" end
    return "STEMwerk custom stem folder"
end

function HELPERS.getCustomFolderPromptLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Mappad:" end
    if lang == "de" then return "Ordnerpfad:" end
    return "Folder path:"
end

function HELPERS.getStemFilesTempTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Bewaar de gemaakte stemfiles in de tijdelijke STEMwerk-map." end
    if lang == "de" then return "Speichert die erzeugten Stem-Dateien im temporaeren STEMwerk-Ordner." end
    return "Keep generated stem files in STEMwerk temp folders."
end

function HELPERS.getStemFilesProjectTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Verplaats de gemaakte stemfiles eerst naar de huidige REAPER-projectmap en importeer ze daarna." end
    if lang == "de" then return "Verschiebt die erzeugten Stem-Dateien zuerst in den aktuellen REAPER-Projektordner und importiert sie dann." end
    return "Move generated stem files to the current REAPER project path before importing."
end

function HELPERS.getStemFilesCustomTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Verplaats de gemaakte stemfiles eerst naar een eigen map en importeer ze daarna." end
    if lang == "de" then return "Verschiebt die erzeugten Stem-Dateien zuerst in einen eigenen Ordner und importiert sie dann." end
    return "Move generated stem files to a custom folder before importing."
end

function HELPERS.getStemFilesCustomPathTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Vul de doelmap voor de definitieve stemfiles in." end
    if lang == "de" then return "Zielordner fuer die finalen Stem-Dateien eingeben." end
    return "Enter the destination folder for final stem files."
end

function HELPERS.getStemFilesWarningTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Stem files" end
    if lang == "de" then return "Stem-Dateien" end
    return "Stem files"
end

function HELPERS.getStemFilesMissingCustomWarning()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Stel eerst een eigen stemmap in, of zet Stem files terug op Temp/Project." end
    if lang == "de" then return "Zuerst einen eigenen Stem-Ordner festlegen, oder Stem-Dateien auf Temp/Projekt zuruecksetzen." end
    return "Set a custom stem folder first, or switch Stem files back to Temp/Project."
end

function HELPERS.getStemFilesProjectUnavailableWarning()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Project is niet beschikbaar voor dit project. Sla het project eerst op, of gebruik Temp/Custom." end
    if lang == "de" then return "Projekt ist fuer dieses Projekt nicht verfuegbar. Projekt zuerst speichern, oder Temp/Custom verwenden." end
    return "Project is unavailable for this project. Save the project first, or use Temp/Custom."
end

function HELPERS.getNoAudibleTargetsTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Geen hoorbare doelwitten" end
    if lang == "de" then return "Keine hoerbaren Ziele" end
    return "No audible targets"
end

function HELPERS.getNoAudibleTargetsMessage()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then
        return "Er is wel audio binnen de huidige selectie, maar alle overeenkomende tracks/items zijn gemute of niet solo-hoorbaar.\n\nUnmute de relevante track of item, of pas de solo-status aan, en probeer opnieuw."
    end
    if lang == "de" then
        return "Innerhalb der aktuellen Auswahl gibt es Audio, aber alle passenden Tracks/Items sind stummgeschaltet oder wegen Solo nicht hoerbar.\n\nRelevanten Track oder Item entstummen oder den Solo-Status anpassen und erneut versuchen."
    end
    return "There is audio inside the current selection, but all matching tracks/items are muted or not solo-audible.\n\nUnmute the relevant track or item, or adjust solo state, then try again."
end

function HELPERS.isNoAudibleTargetsError(err)
    local s = string.lower(tostring(err or ""))
    if s == "" then return false end
    if s:find("no audible targets overlap", 1, true) then return true end
    if s:find("muted or not solo%-audible") then return true end
    if s:find("geen hoorbare doelwitten", 1, true) then return true end
    if s:find("keine hoerbaren ziele", 1, true) then return true end
    return false
end

function HELPERS.getSelectionMonitorPrompt()
    local state = HELPERS.getSelectionMonitorState()
    local lang = HELPERS.getUiLanguageCode()
    if state and state.hasSource and not state.actionable then
        if lang == "nl" then
            return HELPERS.getNoAudibleTargetsTitle(), "Selecteer audio of maak tracks/items hoorbaar in REAPER."
        end
        if lang == "de" then
            return HELPERS.getNoAudibleTargetsTitle(), "Audio auswaehlen oder Tracks/Items in REAPER hoerbar machen."
        end
        return HELPERS.getNoAudibleTargetsTitle(), "Select audio or make tracks/items audible in REAPER."
    end
    if lang == "nl" then
        return "Start", "Selecteer audio in REAPER"
    end
    if lang == "de" then
        return "Start", "Audio in REAPER auswaehlen"
    end
    return "Start", "Select audio in REAPER"
end

function HELPERS.getProjectMediaDir()
    local projectPath = nil
    if reaper and reaper.GetProjectPathEx then
        local ok, result = pcall(reaper.GetProjectPathEx, 0, "")
        if ok and type(result) == "string" and result ~= "" then
            projectPath = result
        end
    end
    if (not projectPath or projectPath == "") and reaper and reaper.GetProjectPath then
        local ok, result = pcall(reaper.GetProjectPath, "")
        if ok and type(result) == "string" and result ~= "" then
            projectPath = result
        end
    end
    projectPath = HELPERS.trimString(projectPath)
    if projectPath == "" then return nil end
    return projectPath
end

function HELPERS.resolveFinalStemOutputDir()
    local mode = tostring(SETTINGS.stemFileDestination or "temp")
    if mode == "project_media" then
        return HELPERS.getProjectMediaDir()
    elseif mode == "custom" then
        local customDir = HELPERS.trimString(SETTINGS.customStemDir)
        if customDir ~= "" then
            return customDir
        end
        return nil
    end
    return nil
end

function HELPERS.sanitizeStemFilenamePart(name)
    local s = HELPERS.trimString(name)
    if s == "" then s = "Stem" end
    s = s:gsub("[<>:\"/\\|%?%*]", "_")
    s = s:gsub("[%c]", "_")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%.+", "")
    s = s:gsub("%.+$", "")
    s = s:gsub("%s+$", "")
    if s == "" then s = "Stem" end
    return s
end

function HELPERS.makeUniqueFilePath(dir, baseName, ext)
    local safeBase = HELPERS.sanitizeStemFilenamePart(baseName)
    local safeExt = ext or ""
    local candidate = dir .. PATH_SEP .. safeBase .. safeExt
    local counter = 2
    while fileExists(candidate) do
        candidate = dir .. PATH_SEP .. safeBase .. "_" .. tostring(counter) .. safeExt
        counter = counter + 1
    end
    return candidate
end

function HELPERS.copyFile(src, dst)
    local inFile = io.open(src, "rb")
    if not inFile then return false end
    local outFile = io.open(dst, "wb")
    if not outFile then
        inFile:close()
        return false
    end
    local data = inFile:read("*all")
    inFile:close()
    if not data then
        outFile:close()
        os.remove(dst)
        return false
    end
    outFile:write(data)
    outFile:close()
    return true
end

function HELPERS.moveFile(src, dst)
    if src == dst then return true end
    local ok = os.rename(src, dst)
    if ok then return true end
    if HELPERS.copyFile(src, dst) then
        os.remove(src)
        return true
    end
    return false
end

function HELPERS.getStemNamingContextForItem(item, fallbackTrackName, fallbackItemName)
    local trackName = HELPERS.trimString(fallbackTrackName)
    local itemName = HELPERS.trimString(fallbackItemName)
    if item and reaper.ValidatePtr(item, "MediaItem*") then
        local track = reaper.GetMediaItem_Track(item)
        if track then
            local _, tn = reaper.GetTrackName(track)
            trackName = HELPERS.trimString(tn)
        end
        local display = getItemDisplayNameForTakes(item)
        if display and display ~= "" then
            itemName = HELPERS.trimString(display)
        end
    end
    if trackName == "" then trackName = "Track" end
    if itemName == "" then itemName = fallbackItemName or trackName end
    return trackName, itemName
end

function HELPERS.finalizeStemFiles(stems, sourceTrackName, sourceItemName)
    local finalDir = HELPERS.resolveFinalStemOutputDir()
    if not finalDir or finalDir == "" then
        return stems, nil
    end

    makeDir(finalDir)
    local moved = {}
    local relocated = {}
    for _, stem in ipairs(STEMS) do
        local key = stem.name:lower()
        local src = stems[key]
        if src then
            local names = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stem.name)
            local dst = HELPERS.makeUniqueFilePath(finalDir, names.takeName, ".wav")
            if HELPERS.moveFile(src, dst) then
                relocated[key] = dst
                moved[#moved + 1] = dst
            else
                relocated[key] = src
            end
        end
    end
    return relocated, moved
end

function HELPERS.refreshImportedMediaItems(items, sourcePaths)
    local seenTracks = {}
    for _, path in ipairs(sourcePaths or {}) do
        if path and path ~= "" and reaper.GetPeakFileName then
            local ok, peakPath = pcall(reaper.GetPeakFileName, path)
            if ok and type(peakPath) == "string" and peakPath ~= "" then
                os.remove(peakPath)
            end
        end
    end
    if reaper.ClearPeakCache then
        pcall(reaper.ClearPeakCache)
    end
    for _, item in ipairs(items or {}) do
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local takeCount = reaper.CountTakes(item) or 0
            for takeIdx = 0, takeCount - 1 do
                local take = reaper.GetTake(item, takeIdx)
                if take and reaper.ValidatePtr(take, "MediaItem_Take*") and reaper.PCM_Source_BuildPeaks then
                    local src = reaper.GetMediaItemTake_Source(take)
                    if src then
                        local okStart, remaining = pcall(reaper.PCM_Source_BuildPeaks, src, 0)
                        if okStart and tonumber(remaining or 0) and tonumber(remaining or 0) > 0 then
                            local guard = 0
                            repeat
                                local okRun, runRemaining = pcall(reaper.PCM_Source_BuildPeaks, src, 1)
                                if not okRun then break end
                                remaining = tonumber(runRemaining or 0) or 0
                                guard = guard + 1
                            until remaining <= 0 or guard > 20000
                            pcall(reaper.PCM_Source_BuildPeaks, src, 2)
                        end
                    end
                end
            end
            local track = reaper.GetMediaItem_Track(item)
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                local trackKey = tostring(track)
                if not seenTracks[trackKey] then
                    seenTracks[trackKey] = track
                end
            end
            if reaper.UpdateItemInProject then
                pcall(reaper.UpdateItemInProject, item)
            end
        end
    end
    for _, track in pairs(seenTracks) do
        if reaper.MarkTrackItemsDirty then
            pcall(reaper.MarkTrackItemsDirty, track, nil)
        end
    end
    adjustTrackLayout()
end

function HELPERS.forceArrangeRefresh()
    if reaper.PreventUIRefresh then
        pcall(reaper.PreventUIRefresh, 1)
    end
    adjustTrackLayout()
    if reaper.PreventUIRefresh then
        pcall(reaper.PreventUIRefresh, -1)
    end
    adjustTrackLayout()
end

function HELPERS.scheduleResultWindowRefresh()
    local step = 0
    local function tick()
        step = step + 1
        HELPERS.forceArrangeRefresh()

        if reaper.JS_Window_SetFocus then
            local mainHwnd = reaper.GetMainHwnd and reaper.GetMainHwnd() or nil
            if mainHwnd then
                pcall(reaper.JS_Window_SetFocus, mainHwnd)
            end
        end

        if step < 6 then
            reaper.defer(tick)
        end
    end

    reaper.defer(tick)
end

-- Read latest progress from stdout file
function WORKFLOW.updateProgressFromFile()
    if not progressState.stdoutFile or progressState.stdoutFile == "" then return end
    local f = io.open(progressState.stdoutFile, "r")
    if not f then return end

    local lastProgress = nil
    for line in f:lines() do
        local percent, stage = line:match("PROGRESS:(%d+):(.+)")
        if percent then
            lastProgress = { percent = tonumber(percent), stage = stage }
        end
    end
    f:close()

    if lastProgress then
        progressState.percent = lastProgress.percent
        progressState.stage = lastProgress.stage
    end
end

-- Check if separation process is done (check for done.txt marker file)
function WORKFLOW.checkSeparationDone()
    if not progressState.outputDir or progressState.outputDir == "" then
        return false
    end
    -- Check for done marker file
    local doneFile = io.open(progressState.outputDir .. PATH_SEP .. "done.txt", "r")
    if doneFile then
        doneFile:close()
        return true
    end
    -- Also check if progress hit 100%
    return progressState.percent >= 100
end

-- Best-effort: kill a Windows process tree from a pid file
function HELPERS.killWindowsProcessFromPidFile(pidFile)
    if OS ~= "Windows" then return false end
    if not pidFile or pidFile == "" then return false end
    local f = io.open(pidFile, "r")
    if not f then return false end
    local pidStr = (f:read("*l") or ""):match("%d+")
    f:close()
    local pid = tonumber(pidStr)
    if not pid or pid <= 0 then return false end

    local cmd = string.format('taskkill /PID %d /T /F', pid)
    debugLog("Killing process tree: " .. cmd)
    if reaper and reaper.ExecProcess then
        reaper.ExecProcess(cmd, 0)
    else
        os.execute(cmd .. " >nul 2>nul")
    end
    return true
end

-- Best-effort: kill a Unix process from a pid file
function HELPERS.killUnixProcessFromPidFile(pidFile)
    if OS == "Windows" then return false end
    if not pidFile or pidFile == "" then return false end
    local f = io.open(pidFile, "r")
    if not f then return false end
    local pidStr = (f:read("*l") or ""):match("%d+")
    f:close()
    local pid = tonumber(pidStr)
    if not pid or pid <= 0 then return false end

    -- Try TERM first; if the process ignores it, the user can cancel again / wait for cleanup.
    os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null")
    return true
end

-- Cross-platform kill wrapper
function HELPERS.killProcessFromPidFile(pidFile)
    if OS == "Windows" then
        return HELPERS.killWindowsProcessFromPidFile(pidFile)
    end
        return HELPERS.killUnixProcessFromPidFile(pidFile)
end

function SW_LOG.writeExitCode(path, code)
    if not path or path == "" then return end
    local f = io.open(path, "w")
    if f then
        f:write(tostring(code or ""))
        f:close()
    end
end

function SW_LOG.readExitCode(path)
    if not path or path == "" then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l") or ""
    f:close()
    local n = tonumber(v)
    return n or v
end

function SW_LOG.readFileSnippet(path, maxChars)
    maxChars = maxChars or 1200
    if not path or path == "" then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    if content == "" then return nil end
    if #content > maxChars then
        content = content:sub(1, maxChars) .. "\n...(truncated)..."
    end
    return content
end

-- Start separation process in background (Windows)
function WORKFLOW.startSeparationProcess(inputFile, outputDir, model)
    refreshPythonPathFromExtState()
    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end
    local logFile = outputDir .. PATH_SEP .. "separation_log.txt"
    local stdoutFile = outputDir .. PATH_SEP .. "stdout.txt"
    local doneFile = outputDir .. PATH_SEP .. "done.txt"
    local pidFile = outputDir .. PATH_SEP .. "pid.txt"
    local exitCodeFile = outputDir .. PATH_SEP .. "exit_code.txt"

    debugLog("startSeparationProcess")
    debugLog("  inputFile=" .. tostring(inputFile))
    debugLog("  outputDir=" .. tostring(outputDir))
    debugLog("  model=" .. tostring(model))
    debugLog("  python=" .. tostring(PYTHON_PATH))
    debugLog("  separator=" .. tostring(SEPARATOR_SCRIPT))

    -- Store for progress tracking
    progressState.outputDir = outputDir
    progressState.stdoutFile = stdoutFile
    progressState.logFile = logFile
    progressState.pidFile = pidFile
    progressState.exitCodeFile = exitCodeFile
    progressState.percent = 0
    progressState.stage = "Starting.."
    progressState.startTime = os.time()
    progressState.execLogPath = SW_LOG.getLogPath()

    -- Preflight checks so failures show up clearly in logs/UI.
    local function fileExists(p)
        if not p then return false end
        local f = io.open(p, "r")
        if f then f:close(); return true end
        return false
    end
    local function fileSizeBytes(p)
        if not p then return -1 end
        local f = io.open(p, "rb")
        if not f then return -1 end
        local sz = f:seek("end")
        f:close()
        return tonumber(sz) or -1
    end

    if not fileExists(inputFile) then
        local msg = "Input file missing: " .. tostring(inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: missing input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then lf:write(msg .. "\n"); lf:close() end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end
    local inSz = fileSizeBytes(inputFile)
    if not inSz or inSz <= 1024 then
        local msg = "Input WAV is empty (0 samples): " .. tostring(inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: empty input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then
            lf:write(msg .. "\n")
            lf:write("Hint: make a longer time selection / ensure selection overlaps items.\n")
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
        local numpyOk, numpyErr = checkNumpyCompat(PYTHON_PATH)
        if not numpyOk then
            local msg =
                "NumPy compatibility issue.\n\n"
                .. tostring(numpyErr or "Unknown error") .. "\n\n"
                .. "Fix (command):\n"
                .. "  " .. tostring(PYTHON_PATH) .. " -m pip install \"numpy<2.4\""
            debugLog(msg)
            SW_LOG.logExecResult("preflight: numpy incompatible", -1, msg)
            local lf = io.open(logFile, "w")
            if lf then lf:write(msg .. "\n"); lf:close() end
            local df = io.open(doneFile, "w")
            if df then df:write("DONE\n"); df:close() end
            SW_LOG.writeExitCode(exitCodeFile, -1)
            if reaper and reaper.ShowMessageBox then
                reaper.ShowMessageBox(msg, "Missing Dependency", 0)
            end
            return false
        end
        if not canRunFfmpeg() then
            if not ensureDependenciesInteractive() then
                return false
            end
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

    if OS == "Windows" then
        -- Create empty progress/log files (Python writes to these directly)
        local sf = io.open(stdoutFile, "w")
        if sf then sf:close() end
        local lf = io.open(logFile, "w")
        if lf then lf:close() end

        -- Launch Python hidden WITHOUT a .bat/.cmd (prevents console windows).
        -- Use WMI Win32_Process.Create to get a PID for proper cancel.
        local requestedDeviceArg = SETTINGS.device or "auto"
        local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
        local pythonCmd = string.format(
            '%s -u %s %s %s --model %s --device %s',
            quoteArg(PYTHON_PATH),
            quoteArg(SEPARATOR_SCRIPT),
            quoteArg(inputFile),
            quoteArg(outputDir),
            quoteArg(model),
            quoteArg(deviceArg)
        )
        progressState.lastCmd = pythonCmd
        SW_LOG.logExecResult("LAUNCH: " .. pythonCmd, nil, "")
        if tostring(deviceArg) ~= tostring(requestedDeviceArg) then
            debugLog("  device=" .. tostring(requestedDeviceArg) .. " -> normalized to " .. tostring(deviceArg))
        else
            debugLog("  device=" .. tostring(deviceArg))
        end

        -- Write a tiny VBS launcher that runs PowerShell invisibly via wscript
        -- PowerShell will Start-Process the Python worker and write its PID to pidFile
        local vbsPath = outputDir .. PATH_SEP .. "run_hidden.vbs"
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            local function escPS(s)
                s = tostring(s or "")
                s = s:gsub("'", "''")
                return s
            end
            local python = escPS(PYTHON_PATH)
            local sep = escPS(SEPARATOR_SCRIPT)
            local inF = escPS(inputFile)
            local outD = escPS(outputDir)
            local m = escPS(model)
            local dev = escPS(deviceArg)
            local stdoutF = escPS(stdoutFile)
            local stderrF = escPS(logFile)
            local pidF = escPS(pidFile)
            local doneF = escPS(doneFile)
            local exitF = escPS(exitCodeFile)

            -- Build the PowerShell command that Start-Process the Python worker and writes PID
            local psInner =
                "$py='" .. python .. "';" ..
                "$sep='" .. sep .. "';" ..
                "$in='" .. inF .. "';" ..
                "$out='" .. outD .. "';" ..
                "$model='" .. m .. "';" ..
                "$dev='" .. dev .. "';" ..
                "$dq=[char]34;" ..
                "$sepq=$dq + $sep + $dq;" ..
                "$inq=$dq + $in + $dq;" ..
                "$outq=$dq + $out + $dq;" ..
                "$modelq=$dq + $model + $dq;" ..
                "$devq=$dq + $dev + $dq;" ..
                "$p = Start-Process -FilePath $py -ArgumentList @('-u',$sepq,$inq,$outq,'--model',$modelq,'--device',$devq) -WorkingDirectory '" .. outD .. "' -WindowStyle Hidden -PassThru -RedirectStandardOutput '" .. stdoutF .. "' -RedirectStandardError '" .. stderrF .. "'; " ..
                "Set-Content -Path '" .. pidF .. "' -Value $p.Id -Encoding ascii; " ..
                "Wait-Process -Id $p.Id; " ..
                "$ec=$p.ExitCode; Set-Content -Path '" .. exitF .. "' -Value $ec -Encoding ascii; " ..
                "Set-Content -Path '" .. doneF .. "' -Value 'DONE' -Encoding ascii"

            -- VBS: create shell and run PowerShell command invisibly (0 = hidden window)
            vbsFile:write('Set sh = CreateObject("WScript.Shell")\n')
            vbsFile:write('cmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""' .. psInner .. '"""\n')
            vbsFile:write('sh.Run cmd, 0, False\n')
            vbsFile:close()
        end

        local wscriptCmd = 'wscript "' .. vbsPath .. '"'
        if reaper.ExecProcess then
            debugLog('Calling reaper.ExecProcess: ' .. wscriptCmd)
            reaper.ExecProcess(wscriptCmd, -1)
            debugLog('reaper.ExecProcess called')
        else
            debugLog('Calling io.popen for: ' .. wscriptCmd)
            local handle = io.popen(wscriptCmd)
            if handle then handle:close() end
            debugLog('io.popen returned')
        end
    else
        -- Unix: run in background so REAPER stays responsive and the progress window can update.
        -- Launch a tiny sh script that starts the Python worker in the background, writes a pid.txt,
        -- and writes done.txt only when the worker exits successfully.
        local requestedDeviceArg = tostring(SETTINGS.device or "auto")
        local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
        local modelArg  = tostring(model or SETTINGS.model or "htdemucs")
        local pythonCmd = string.format(
            '%s -u %s %s %s --model %s --device %s',
            quoteArg(PYTHON_PATH),
            quoteArg(SEPARATOR_SCRIPT),
            quoteArg(inputFile),
            quoteArg(outputDir),
            quoteArg(modelArg),
            quoteArg(deviceArg)
        )
        progressState.lastCmd = pythonCmd
        SW_LOG.logExecResult("LAUNCH: " .. pythonCmd, nil, "")
        if tostring(deviceArg) ~= tostring(requestedDeviceArg) then
            debugLog("  device=" .. tostring(requestedDeviceArg) .. " -> normalized to " .. tostring(deviceArg))
        end

        -- Create empty progress/log files (Python writes to these directly)
        local sf = io.open(stdoutFile, "w")
        if sf then sf:close() end
        local lf = io.open(logFile, "w")
        if lf then lf:close() end

        local launcherPath = outputDir .. PATH_SEP .. "run_bg.sh"
        local script = io.open(launcherPath, "w")
          if script then
              script:write("#!/bin/sh\n")
              script:write("PY=" .. quoteArg(PYTHON_PATH) .. "\n")
              script:write("SEP=" .. quoteArg(SEPARATOR_SCRIPT) .. "\n")
              if OS == "macOS" then
                  local ffmpegPath = FFMPEG_PATH or getExtStateValue("ffmpegPath")
                  if ffmpegPath and ffmpegPath ~= "" then
                      script:write("FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\n")
                      script:write("IMAGEIO_FFMPEG_EXE=" .. quoteArg(ffmpegPath) .. "\n")
                      script:write("export FFMPEG_PATH IMAGEIO_FFMPEG_EXE\n")
                      script:write("FFMPEG_DIR=$(dirname \"$FFMPEG_PATH\")\n")
                      script:write("PATH=\"$FFMPEG_DIR:${PATH}\"\n")
                      script:write("export PATH\n")
                  end
              end
              script:write("IN=" .. quoteArg(inputFile) .. "\n")
              script:write("OUT=" .. quoteArg(outputDir) .. "\n")
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
            script:write('  "$PY" -u "$SEP" "$IN" "$OUT" --model "$MODEL" --device "$DEVICE" >"$STDOUT" 2>"$STDERR"\n')
            script:write("  rc=$?\n")
            script:write('  echo "$rc" > "$EXITCODE"\n')
            script:write('  if [ "$rc" -ne 0 ]; then echo "EXIT:$rc" >> "$STDERR"; fi\n')
            script:write('  echo DONE > "$DONE"\n')
            script:write(") &\n")
            script:write('echo $! > "$PIDFILE"\n')
            script:close()

            local cmd = "sh " .. quoteArg(launcherPath) .. suppressStderr()
            debugLog("Executing (background) launcher: " .. cmd)
            os.execute(cmd)
        else
            -- If we couldn't write the launcher, fall back to a direct foreground run (old behavior).
            local cmd = string.format(
                '%s -u %s %s %s --model %s --device %s >%s 2>%s && echo DONE > %s',
                quoteArg(PYTHON_PATH),
                quoteArg(SEPARATOR_SCRIPT),
                quoteArg(inputFile),
                quoteArg(outputDir),
                quoteArg(modelArg),
                quoteArg(deviceArg),
                quoteArg(stdoutFile),
                quoteArg(logFile),
                quoteArg(doneFile)
            )
            debugLog("Unix launcher write failed; executing (foreground) command: " .. cmd)
            local ok, _, code = os.execute(cmd)
            local rc = (ok == true or ok == 0) and 0 or (code or 1)
            SW_LOG.writeExitCode(exitCodeFile, rc)
            debugLog("Command finished with rc=" .. tostring(rc))
        end
    end
    return true
end

-- Progress loop with UI
function WORKFLOW.progressLoop()
    local loopNow = uiNow()

    if loopNow >= (progressState.nextPollAt or 0) then
        progressState.nextPollAt = loopNow + UI_PACING.progressPollInterval
        WORKFLOW.updateProgressFromFile()
    end

    if loopNow >= (progressState.nextFrameAt or 0) then
        progressState.nextFrameAt = loopNow + pacingFrameInterval("progressFrameInterval", "progressFrameIntervalFx")
        drawProgressWindow()
    end

    local char = gfx.getchar()
    local mouseDown = gfx.mouse_cap & 1 == 1
    handleArtAdvance(progressState, mouseDown, char)
    if char == 26161 then  -- F1 key code
        -- Reserved (no-op for now). Keep input handling centralized here so ESC is never consumed elsewhere.
    end
    if char == -1 or char == 27 then  -- Window closed or ESC pressed
        -- Window closed by user
        progressState.running = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Remember any size/position changes made during processing
        captureWindowGeometry(WINDOW_PROCESSING)
        saveSettings()

        -- Best-effort kill of running worker (otherwise cancel leaves a hidden Python process running)
        HELPERS.killProcessFromPidFile(progressState.pidFile)

        gfx.quit()
        progressState.windowOpen = false

        -- After cancel, go back to the start/selection monitoring window.
        -- This lets the user quickly pick a new item/time selection without reopening the full dialog.
        showMessage("Cancelled", T("separation_cancelled"), "info", true)
        return
    end

    if WORKFLOW.checkSeparationDone() then
        -- Done!
        progressState.running = false

        -- Remember any size/position changes made during processing
        captureWindowGeometry(WINDOW_PROCESSING)
        saveSettings()

        gfx.quit()
        progressState.windowOpen = false
        WORKFLOW.finishSeparationCallback()
        return
    end

    -- Check timeout (10 minutes max)
    if os.time() - progressState.startTime > 600 then
        progressState.running = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Remember any size/position changes made during processing
        captureWindowGeometry(WINDOW_PROCESSING)
        saveSettings()

        gfx.quit()
        progressState.windowOpen = false
        showMessage("Timeout", "Separation timed out after 10 minutes.", "error", true)
        return
    end

    reaper.defer(WORKFLOW.progressLoop)
end

-- Finish separation after progress completes
function WORKFLOW.finishSeparationCallback()
    -- Small delay to ensure files are written
    local checkCount = 0
    local function checkFiles()
        checkCount = checkCount + 1
        local stems = {}
        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = progressState.outputDir .. PATH_SEP .. stem.file
                local f = io.open(stemPath, "r")
                if f then f:close(); stems[stem.name:lower()] = stemPath end
            end
        end

        if next(stems) then
            -- Success - process stems
            isProcessingActive = false  -- Reset guard so workflow can be restarted after result
            processStemsResult(stems)
            cleanupTempWorkDir(progressState.outputDir)
        elseif checkCount < 10 then
            -- Retry
            reaper.defer(checkFiles)
        else
            -- Failed
            isProcessingActive = false  -- Reset guard so workflow can be restarted
            local exitCode = SW_LOG.readExitCode(progressState.exitCodeFile)
            local logSnippet = SW_LOG.readFileSnippet(progressState.logFile, 2000) or "(no log output found)"
            local stdoutSnippet = SW_LOG.readFileSnippet(progressState.stdoutFile, 1200)
            local errMsg = "No stems created"
                .. "\n\nExit code: " .. tostring(exitCode or "unknown")
                .. "\nCommand: " .. tostring(progressState.lastCmd or "unknown")
                .. "\nLog file: " .. tostring(progressState.logFile or "unknown")
                .. "\nDebug log: " .. tostring(progressState.execLogPath or SW_LOG.getLogPath())
                .. "\n\nOutput (first 2000 chars):\n" .. logSnippet
            if stdoutSnippet then
                errMsg = errMsg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
            end
            showMessage("Separation Failed", errMsg, "error", true)
        end
    end
    checkFiles()
end

-- Store callback reference
finishSeparation = WORKFLOW.finishSeparationCallback

-- Run separation with progress UI
function WORKFLOW.runSeparationWithProgress(inputFile, outputDir, model)
    -- Load settings to get current theme
    loadSettings()
    updateTheme()

    if OS == "Windows" and progressState.windowOpen then
        showProcessingPlaceholderWindow("Initializing...")
    end

    -- Start the process
    local ok = WORKFLOW.startSeparationProcess(inputFile, outputDir, model)
    if ok == false then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        isProcessingActive = false
        return
    end

    -- Capture main window geometry and snapshot for cancel -> main restore
    captureWindowGeometry(SCRIPT_NAME)
    GUI.snapshotMainGeometry()

    if not progressState.windowOpen then
        ensureProcessingWindowOpen()
    end
    progressState.stage = type(T) == "function" and (T("starting") or "Starting...") or "Starting..."

    progressState.running = true

    if OS == "Windows" then
        WORKFLOW.progressLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(WORKFLOW.progressLoop)
    end
end

-- Legacy synchronous separation (fallback)
function WORKFLOW.runSeparation(inputFile, outputDir, model)
    local logFile = outputDir .. PATH_SEP .. "separation_log.txt"
    local stdoutFile = outputDir .. PATH_SEP .. "stdout.txt"

    local cmd
    if OS == "Windows" then
        local vbsPath = outputDir .. PATH_SEP .. "run_hidden.vbs"
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            local pythonCmd = string.format(
                '"%s" -u "%s" "%s" "%s" --model %s',
                PYTHON_PATH, SEPARATOR_SCRIPT, inputFile, outputDir, model
            )
            pythonCmd = pythonCmd:gsub('"', '""')
            vbsFile:write('Set WshShell = CreateObject("WScript.Shell")\n')
            vbsFile:write('WshShell.Run "cmd /c ' .. pythonCmd .. ' >""' .. stdoutFile .. '"" 2>""' .. logFile .. '""", 0, True\n')
            vbsFile:close()
            cmd = 'cscript //nologo "' .. vbsPath .. '"'
        end
    else
        cmd = string.format(
            '"%s" -u "%s" "%s" "%s" --model %s >"%s" 2>"%s"',
            PYTHON_PATH, SEPARATOR_SCRIPT, inputFile, outputDir, model, stdoutFile, logFile
        )
    end

    os.execute(cmd)

    local stems = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = outputDir .. PATH_SEP .. stem.file
            local f = io.open(stemPath, "r")
            if f then f:close(); stems[stem.name:lower()] = stemPath end
        end
    end

    if next(stems) == nil then
        local errLog = io.open(logFile, "r")
        local errMsg = "No stems created"
        if errLog then
            local content = errLog:read("*a")
            errLog:close()
            if content and content ~= "" then
                errMsg = errMsg .. "\n\nLog:\n" .. content:sub(1, 500)
            end
        end
        return nil, errMsg
    end
    return stems
end

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

local function snapshotTakePlaybackState(take)
    if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then return nil end
    local playrate = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")) or 1.0
    if playrate < 0.0001 then playrate = 1.0 end
    local pitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")) or 0.0
    local preservePitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")) or 0
    preservePitch = (preservePitch ~= 0) and 1 or 0
    return {
        playrate = playrate,
        pitch = pitch,
        preservePitch = preservePitch,
    }
end

local function snapshotItemPlaybackState(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return nil end
    return snapshotTakePlaybackState(reaper.GetActiveTake(item))
end

local function applyTakePlaybackState(take, state, itemLen)
    if not take or not state then return end
    if not reaper.ValidatePtr(take, "MediaItem_Take*") then return end

    local source = reaper.GetMediaItemTake_Source(take)
    local sourceLen = nil
    if source and reaper.GetMediaSourceLength then
        local len = reaper.GetMediaSourceLength(source)
        sourceLen = tonumber(len)
    end

    -- Imported separator output is usually rendered from source-time audio.
    -- Only restore playback-state when the source duration matches the
    -- expected pre-baked length, otherwise we would double-apply stretch.
    if sourceLen and itemLen and itemLen > 0 then
        local expected = itemLen * (state.playrate or 1.0)
        local tolerance = math.max(0.01, expected * 0.01)
        if math.abs(sourceLen - expected) > tolerance then
            return
        end
    end

    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", state.playrate or 1.0)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", state.pitch or 0.0)
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", state.preservePitch or 0)
end

function WORKFLOW.replaceInPlacePartial(item, stemPaths, selStart, selEnd, nameBase)
    local track = reaper.GetMediaItem_Track(item)
    local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local replaceStart = math.max(tonumber(selStart) or origItemPos, origItemPos)
    local replaceEnd = math.min(tonumber(selEnd) or origItemEnd, origItemEnd)
    local sourcePlaybackState = snapshotItemPlaybackState(item)

    if replaceEnd <= replaceStart then
        return 0, nil
    end

    reaper.Undo_BeginBlock()

    -- We need to split the item at selection boundaries
    -- First, deselect all items and select only our target item
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)

    local leftItem = nil   -- Part before selection (if any)
    local middleItem = item -- Part to replace
    local rightItem = nil  -- Part after selection (if any)

    -- Split at selection start if it's inside the item
    if replaceStart > origItemPos and replaceStart < origItemEnd then
        middleItem = reaper.SplitMediaItem(item, replaceStart)
        leftItem = item
        if middleItem then
            reaper.SetMediaItemSelected(leftItem, false)
            reaper.SetMediaItemSelected(middleItem, true)
        else
            -- Split failed, middle is still the original item
            middleItem = item
            leftItem = nil
        end
    end

    -- Split at selection end if it's inside what remains
    if middleItem then
        local midPos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
        local midEnd = midPos + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")

        if replaceEnd > midPos and replaceEnd < midEnd then
            rightItem = reaper.SplitMediaItem(middleItem, replaceEnd)
            if rightItem then
                reaper.SetMediaItemSelected(rightItem, false)
            end
        end
    end

    -- Now delete the middle item and insert stems in its place
    local selLen = replaceEnd - replaceStart
    if middleItem then
        reaper.DeleteTrackMediaItem(track, middleItem)
    end

    -- Create stem items at the selection position
    local items = {}
    local stemEntries = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = stemPaths[stem.name:lower()]
            if stemPath then
                stemEntries[#stemEntries + 1] = { stem = stem, path = stemPath }
            end
        end
    end
    local totalStems = #stemEntries
    local baseName = nameBase or getItemDisplayNameForTakes(item)
    local importedItems = {}
    local importedPaths = {}
    for idx, entry in ipairs(stemEntries) do
        local stem = entry.stem
        local stemPath = entry.path
        local newItem = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", replaceStart)
        reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", selLen)

        local take = reaper.AddTakeToMediaItem(newItem)
        local source = reaper.PCM_Source_CreateFromFile(stemPath)
        reaper.SetMediaItemTake_Source(take, source)
        local takeLabel = string.format("Take %d/%d: %s - %s", idx, math.max(1, totalStems), baseName, stem.name)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", takeLabel, true)
        applyTakePlaybackState(take, sourcePlaybackState, selLen)
        -- Ensure take volume is at unity (1.0 = 0dB)
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)

        local stemColor = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
        HELPERS.applyItemColorIfEnabled(newItem, stemColor)

        items[#items + 1] = { item = newItem, take = take, color = stemColor, name = takeLabel }
        importedItems[#importedItems + 1] = newItem
        importedPaths[#importedPaths + 1] = stemPath
    end

    -- Merge into takes on the first item
    if #items > 1 then
        local mainItem = items[1].item
        -- Set main item color to first stem color
        HELPERS.applyItemColorIfEnabled(mainItem, items[1].color)

        for i = 2, #items do
            local srcTake = reaper.GetActiveTake(items[i].item)
            if srcTake then
                local newTake = reaper.AddTakeToMediaItem(mainItem)
                reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(srcTake))
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", items[i].name, true)
                applyTakePlaybackState(newTake, sourcePlaybackState, selLen)
                -- Ensure take volume is at unity (1.0 = 0dB)
                reaper.SetMediaItemTakeInfo_Value(newTake, "D_VOL", 1.0)
            end
            reaper.DeleteTrackMediaItem(track, items[i].item)
        end

        -- Now set the color for each take based on its stem
        -- Iterate through all takes and set their colors
        local numTakes = reaper.CountTakes(mainItem)
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(mainItem, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                -- Find the matching stem color
                for _, stemData in ipairs(items) do
                    if stemData.name == takeName then
                        -- Set take color (I_CUSTOMCOLOR on the take)
                        HELPERS.applyTakeColorIfEnabled(take, stemData.color)
                        break
                    end
                end
            end
        end
    end

    HELPERS.refreshImportedMediaItems({ ((#items >= 1) and items[1].item or nil) }, importedPaths)
    reaper.Undo_EndBlock("STEMwerk: Replace selection in-place", -1)
    local mainItem = (#items >= 1) and items[1].item or nil
    return #items, mainItem
end

-- Replace item in-place with stems as takes
function WORKFLOW.replaceInPlace(item, stemPaths, itemPos, itemLen, nameBase)
    local track = reaper.GetMediaItem_Track(item)
    local sourcePlaybackState = snapshotItemPlaybackState(item)
    reaper.Undo_BeginBlock()
    reaper.DeleteTrackMediaItem(track, item)

    local items = {}
    local stemEntries = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = stemPaths[stem.name:lower()]
            if stemPath then
                stemEntries[#stemEntries + 1] = { stem = stem, path = stemPath }
            end
        end
    end
    local totalStems = #stemEntries
    local baseName = nameBase or getItemDisplayNameForTakes(item)
    local importedPaths = {}
    for idx, entry in ipairs(stemEntries) do
        local stem = entry.stem
        local stemPath = entry.path
        local newItem = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", itemPos)
        reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", itemLen)

        local take = reaper.AddTakeToMediaItem(newItem)
        local source = reaper.PCM_Source_CreateFromFile(stemPath)
        reaper.SetMediaItemTake_Source(take, source)
        local takeLabel = string.format("Take %d/%d: %s - %s", idx, math.max(1, totalStems), baseName, stem.name)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", takeLabel, true)
        applyTakePlaybackState(take, sourcePlaybackState, itemLen)
        -- Ensure take volume is at unity (1.0 = 0dB)
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)

        local stemColor = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
        HELPERS.applyItemColorIfEnabled(newItem, stemColor)

        items[#items + 1] = { item = newItem, take = take, color = stemColor, name = takeLabel }
        importedPaths[#importedPaths + 1] = stemPath
    end

    -- Merge into takes
    if #items > 1 then
        local mainItem = items[1].item
        -- Set main item color to first stem color
        HELPERS.applyItemColorIfEnabled(mainItem, items[1].color)

        for i = 2, #items do
            local srcTake = reaper.GetActiveTake(items[i].item)
            if srcTake then
                local newTake = reaper.AddTakeToMediaItem(mainItem)
                reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(srcTake))
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", items[i].name, true)
                applyTakePlaybackState(newTake, sourcePlaybackState, itemLen)
                -- Ensure take volume is at unity (1.0 = 0dB)
                reaper.SetMediaItemTakeInfo_Value(newTake, "D_VOL", 1.0)
            end
            reaper.DeleteTrackMediaItem(track, items[i].item)
        end

        -- Now set the color for each take based on its stem
        local numTakes = reaper.CountTakes(mainItem)
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(mainItem, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                -- Find the matching stem color
                for _, stemData in ipairs(items) do
                    if stemData.name == takeName then
                        HELPERS.applyTakeColorIfEnabled(take, stemData.color)
                        break
                    end
                end
            end
        end
    end

    HELPERS.refreshImportedMediaItems({ ((#items >= 1) and items[1].item or nil) }, importedPaths)
    reaper.Undo_EndBlock("STEMwerk: Replace in-place", -1)
    local mainItem = (#items >= 1) and items[1].item or nil
    return #items, mainItem
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
                ensureTrackHeight(newTrack)
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
    local sourcePlaybackState = snapshotTakePlaybackState(take)

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
        ensureTrackHeight(folderTrack)
        trackIdx = trackIdx + 1
    end

    local importedCount = 0
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = stemPaths[stem.name:lower()]
            if stemPath then
                reaper.InsertTrackAtIndex(trackIdx + importedCount, true)
                local newTrack = reaper.GetTrack(0, trackIdx + importedCount)
                ensureTrackHeight(newTrack)

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
                applyTakePlaybackState(newTake, sourcePlaybackState, itemLen)
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
function createStemTracksForSelection(stemPaths, selPos, selLen, sourceTrack, itemsOverride, useItemNameForTrack)
    reaper.Undo_BeginBlock()
    lastNoAudibleOverlap = false
    local importedItems = {}
    local importedPaths = {}
    local soloActive = getProcessingSoloActive()
    local function trackAudible(track)
        return AUDIBILITY.isTrackAudible(track, soloActive)
    end
    local function itemAudible(item)
        return AUDIBILITY.isItemAudible(item, soloActive)
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
        local trackIdx = 0
        if refTrack then trackIdx = math.floor(reaper.GetMediaTrackInfo_Value(refTrack, "IP_TRACKNUMBER")) end

        local selectedCount = 0
        for _, stem in ipairs(STEMS) do if stem.selected and stemPaths[stem.name:lower()] then selectedCount = selectedCount + 1 end end

        local folderTrack = nil
        local sourceTrackName = "Selection"
        if refTrack then 
            local _, tn = reaper.GetTrackName(refTrack) 
            if tn and tn ~= "" then sourceTrackName = tn end 
        end
        local sourceItemName = sourceTrackName -- Fallback for items when using selection

        if SETTINGS.createFolder then
            reaper.InsertTrackAtIndex(trackIdx, true)
            folderTrack = reaper.GetTrack(0, trackIdx)
            reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", sourceTrackName .. " - Stems", true)
            reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
            HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
            ensureTrackHeight(folderTrack)
            trackIdx = trackIdx + 1
        end

        local importedCount = 0
        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = stemPaths[stem.name:lower()]
                if stemPath then
                    reaper.InsertTrackAtIndex(trackIdx + importedCount, true)
                    local newTrack = reaper.GetTrack(0, trackIdx + importedCount)
                    ensureTrackHeight(newTrack)
                    local newTrackName = selectedCount == 1 and (stem.name .. " - " .. sourceTrackName) or (sourceTrackName .. " - " .. stem.name)
                    reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", newTrackName, true)
                    local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                    HELPERS.applyTrackColorIfEnabled(newTrack, color)
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
                    importedCount = importedCount + 1
                end
            end
        end

        if folderTrack and importedCount > 0 then
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + importedCount - 1), "I_FOLDERDEPTH", -1)
        end

        reaper.PreventUIRefresh(-1)
        HELPERS.refreshImportedMediaItems(importedItems, importedPaths)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection", -1)
        return importedCount
    end

    -- Process each selected item that overlaps the time selection
    local totalCreated = 0
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
        local sourcePlaybackState = snapshotItemPlaybackState(item)
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

        local trackIdx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))

        local folderTrack = nil
        if SETTINGS.createFolder then
            reaper.InsertTrackAtIndex(trackIdx, true)
            folderTrack = reaper.GetTrack(0, trackIdx)
            reaper.GetSetMediaTrackInfo_String(folderTrack, "P_NAME", folderNames.folderBase .. " - Stems", true)
            reaper.SetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH", 1)
            HELPERS.applyTrackColorIfEnabled(folderTrack, rgbToReaperColor(180, 140, 200))
            ensureTrackHeight(folderTrack)
            trackIdx = trackIdx + 1
        end

        local createdForThisItem = 0
        local selectedCount = 0
        for _, s in ipairs(STEMS) do if s.selected and stemPaths[s.name:lower()] then selectedCount = selectedCount + 1 end end

        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = stemPaths[stem.name:lower()]
                if stemPath then
                    reaper.InsertTrackAtIndex(trackIdx + createdForThisItem, true)
                    local newTrack = reaper.GetTrack(0, trackIdx + createdForThisItem)
                ensureTrackHeight(newTrack)
                    local outputNames = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stem.name)
                    reaper.GetSetMediaTrackInfo_String(newTrack, "P_NAME", outputNames.trackName, true)
                    local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
                    HELPERS.applyTrackColorIfEnabled(newTrack, color)

                    local newItem = reaper.AddMediaItemToTrack(newTrack)
                    reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", ipos)
                    reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", ilen)
                    local newTake = reaper.AddTakeToMediaItem(newItem)
                    reaper.SetMediaItemTake_Source(newTake, reaper.PCM_Source_CreateFromFile(stemPath))
                    reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", outputNames.takeName, true)
                    applyTakePlaybackState(newTake, sourcePlaybackState, ilen)
                    HELPERS.applyItemColorIfEnabled(newItem, color)

                    importedItems[#importedItems + 1] = newItem
                    importedPaths[#importedPaths + 1] = stemPath
                    createdForThisItem = createdForThisItem + 1
                    totalCreated = totalCreated + 1
                end
            end
        end

        if folderTrack and createdForThisItem > 0 then
            reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, trackIdx + createdForThisItem - 1), "I_FOLDERDEPTH", -1)
        end

        ::continue_item::
    end

    reaper.PreventUIRefresh(-1)
    HELPERS.refreshImportedMediaItems(importedItems, importedPaths)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: Create stem tracks from selection (per-item)", -1)
    return totalCreated
end

-- Store temp directory for async workflow
WORKFLOW_TEMP_DIR = nil
WORKFLOW_TEMP_INPUT = nil

-- Process stems after separation completes (called from progress UI)
function processStemsResult(stems)
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

    if timeSelectionMode then
        -- Time selection mode: respect user's setting
        if SETTINGS.createNewTracks then
            -- In multi-track mode, use the source track from the queue (for auto item selection & mute/delete semantics).
            local sourceTrack = multiTrackQueue.active and multiTrackQueue.currentSourceTrack or nil
            local actionMsg = ""

            local itemsOverride = timeSelectionResolvedItems
            -- Create stems first so the selection-based cleanup doesn't disturb placement
            count = createStemTracksForSelection(stems, itemPos, itemLen, sourceTrack, itemsOverride, false)
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

            if SETTINGS.muteOriginal then
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
                count, mainItem = WORKFLOW.replaceInPlacePartial(timeSelectionSourceItem, stems, timeSelectionStart, timeSelectionEnd)
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
                count = createStemTracksForSelection(stems, itemPos, itemLen, sourceTrack, itemsOverride, false)
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
        count = createStemTracks(selectedItem, stems, itemPos, itemLen)
        local actionKey = SETTINGS.deleteOriginalTrack and "result_track_deleted" or
                          (SETTINGS.deleteOriginal and "result_item_deleted" or
                          (SETTINGS.deleteSelection and "result_selection_deleted" or
                          (SETTINGS.muteOriginal and "result_item_muted" or
                          (SETTINGS.muteSelection and "result_selection_muted" or nil))))
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
            count, mainItem = WORKFLOW.replaceInPlacePartial(selectedItem, stems, itemSubSelStart, itemSubSelEnd)
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
            count, mainItem = WORKFLOW.replaceInPlace(selectedItem, stems, itemPos, itemLen)
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
    local is6Stem = (SETTINGS.model == "htdemucs_6s")
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
    resultMsg = resultMsg .. "\nTime: " .. timeStr
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
        resultData.sequentialMode = SETTINGS.parallelProcessing and false or true
        resultData.requestedParallel = SETTINGS.parallelProcessing and true or false
    end

    reaper.UpdateArrange()

    -- Show custom result window
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
    drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

    -- Semi-transparent overlay for readability - pure black/white
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 0.5)
    else
        gfx.set(1, 1, 1, 0.5)
    end
    gfx.rect(0, 0, w, h, 1)

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
    local btnW = PS(70)
    local btnH = PS(20)
    local btnX = (w - btnW) / 2
    local btnY = h - PS(40)

    local hover = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    -- Button background
    local okR, okG, okB = THEME.buttonPrimary[1], THEME.buttonPrimary[2], THEME.buttonPrimary[3]
    if hover then
        okR, okG, okB = THEME.buttonPrimaryHover[1], THEME.buttonPrimaryHover[2], THEME.buttonPrimaryHover[3]
    end
    drawGlossyPill(btnX, btnY, btnW, btnH, okR, okG, okB)

    -- Button text
    gfx.setfont(1, "Arial", PS(13), string.byte('b'))
    local okText = T("ok") or "OK"
    local okW = gfx.measurestr(okText)
    local okX = btnX + (btnW - okW) / 2
    local okY = btnY + (btnH - gfx.texth) / 2
    gfx.set(0, 0, 0, 0.4)
    gfx.x, gfx.y = okX + 2, okY + 2; gfx.drawstr(okText)
    gfx.set(0, 0, 0, 0.6)
    gfx.x, gfx.y = okX + 1, okY + 1; gfx.drawstr(okText)
    gfx.x, gfx.y = okX - 1, okY + 1; gfx.drawstr(okText)
    gfx.x, gfx.y = okX + 1, okY - 1; gfx.drawstr(okText)
    gfx.x, gfx.y = okX - 1, okY - 1; gfx.drawstr(okText)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = okX, okY
    gfx.drawstr(okText)

    -- Hint at very bottom edge
    gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
    gfx.setfont(1, "Arial", PS(9))
    local hint = T("complete_hint_keys") or "Enter / ESC"
    local hintW = gfx.measurestr(hint)
    gfx.x = (w - hintW) / 2
    gfx.y = h - PS(12)
    gfx.drawstr(hint)

    -- flarkAUDIO logo at top (translucent) - "flark" regular, "AUDIO" bold
    gfx.setfont(1, "Arial", PS(10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2
    -- Orange text, 50% translucent
    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", PS(10))
    gfx.x = logoStartX
    gfx.y = PS(3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = PS(3)
    gfx.drawstr(audioPart)

    gfx.update()

    -- Check for click on OK button
    if hover and mouseDown and not resultWindowState.wasMouseDown then
        return true  -- Close
    end
    if hover then
        tooltipText = T("complete_ok_tooltip") or "Close (Enter / ESC)"
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end

    resultWindowState.wasMouseDown = mouseDown
    resultWindowState.wasRightMouseDown = (gfx.mouse_cap & 2 == 2)

    local char = gfx.getchar()
    handleArtAdvance(resultWindowState, mouseDown, char)
    if char == -1 or char == 27 or char == 13 then  -- Window closed, ESC, Enter
        return true  -- Close
    end

    -- Tooltip draw (match main style: stem-color bar + wrapping)
    if tooltipText then
        gfx.setfont(1, "Arial", PS(11))
        local padding = PS(8)
        local lineH = PS(14)
        local maxTextW = math.min(w * 0.62, PS(520))
        drawTooltipStyled(tooltipText, tooltipX, tooltipY, w, h, padding, lineH, maxTextW)
    end

    return false  -- Keep open
end

-- Result window loop
function resultWindowLoop()
    -- Save window position for next time
    if reaper.JS_Window_GetRect then
        local hwnd = reaper.JS_Window_Find(WINDOW_COMPLETE, true)
        if hwnd then
            local retval, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
            if retval then
                rememberDialogGeometryFromRect(left, top, right, bottom)
            end

            -- NOTE: Focus check removed - was causing double execution on multi-track processing
            -- The result window should stay open until user explicitly closes it
        end
    end

    if drawResultWindow() then
        -- Remember any size/position changes made in the complete window
        captureWindowGeometry(WINDOW_COMPLETE)
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
    -- Load settings to get current theme
    loadSettings()
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
    gfx.init(WINDOW_COMPLETE, winW, winH, 0, winX, winY)

    -- Best-effort: force an arrange repaint while the Complete window is open.
    -- This makes the processing result visible immediately (without needing to close the window).
    HELPERS.scheduleResultWindowRefresh()
    if OS == "Windows" then
        resultWindowLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(resultWindowLoop)
    end
end

-- Run multi-track separation (parallel or sequential based on setting)
runSingleTrackSeparation = function(trackList)
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

    local is6Stem = (SETTINGS.model == "htdemucs_6s")
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
    local function trackAudible(track)
        return AUDIBILITY.isTrackAudible(track, soloActive)
    end

    local function normalizeItemName(name)
        if not name or name == "" then return nil end
        return name:match("([^/\\]+)%.[^.]*$") or name
    end

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

    -- Prepare all tracks: extract audio
    local trackJobs = {}
    local jobIndex = 0
    local perItemCandidates = 0
    local perItemEligible = 0

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

    local function getSelectedAudibleItemsOnTrack(track)
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

    for i, track in ipairs(trackList) do
        local _, trackName = reaper.GetTrackName(track)
        if trackName == "" then trackName = "Track " .. math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) end
        local selectedTrackItems = (not hasTimeSel)
            and ((noTimeSelectionItemMap and noTimeSelectionItemMap[track]) or getSelectedAudibleItemsOnTrack(track))
            or nil

        if perItemMap and hasTimeSel and perItemMap[track] then
            -- Time selection + per-item jobs for this track (new tracks OR in-place)
            local entries = perItemMap[track] or {}
            perItemCandidates = perItemCandidates + #entries
            local eligibleEntries = {}
            for _, entry in ipairs(entries) do
                local item = entry and entry.item or nil
                if item and reaper.ValidatePtr(item, "MediaItem*") and AUDIBILITY.isItemAudible(item, soloActive) then
                    table.insert(eligibleEntries, entry)
                end
            end

            perItemEligible = perItemEligible + #eligibleEntries
            for itemIdx, entry in ipairs(eligibleEntries) do
                local item = entry.item
                jobIndex = jobIndex + 1
                local itemDir = baseTempDir .. PATH_SEP .. "item_" .. jobIndex
                makeDir(itemDir)
                local inputFile = itemDir .. PATH_SEP .. "input.wav"

                local extracted, err, renderStart, renderLen = renderItemToWav(item, inputFile, entry.start, entry["end"])
                if not extracted then
                    extracted, err, renderStart, renderLen = renderPerItemOverlapFallback(item, inputFile, entry.start, entry["end"])
                end
                if extracted then
                    local sourceItemName, sourceItemDisplayName = getItemNameFields(item, trackName)
                    local itemName = sourceItemDisplayName
                    local audioDuration = renderLen or 0
                    if audioDuration <= 0 then
                        local fallbackLen = entry.len or 0
                        if fallbackLen > 0 then
                            audioDuration = fallbackLen
                        else
                            local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                            local itemEnd = itemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                            audioDuration = math.max(0, math.min(timeSelectionEnd, itemEnd) - math.max(timeSelectionStart, itemPos))
                        end
                    end

                    table.insert(trackJobs, {
                        track = track,
                        trackName = trackName,
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
                        selPos = renderStart or entry.start,
                        selLen = renderLen or entry.len,
                        index = jobIndex,
                        audioDuration = audioDuration,
                        perItem = true,
                    })
                else
                    local ef = io.open(itemDir .. PATH_SEP .. "extract_error.txt", "w")
                    if ef then
                        ef:write("Track: " .. tostring(trackName) .. "\n")
                        ef:write("Item index: " .. tostring(itemIdx) .. "/" .. tostring(#eligibleEntries) .. "\n")
                        ef:write("Error: " .. tostring(err) .. "\n")
                        ef:close()
                    end
                    debugLog("Per-item extract failed: " .. tostring(err))
                end
            end
        elseif inPlaceMultiItem or (SETTINGS.createNewTracks and not hasTimeSel and selectedTrackItems and #selectedTrackItems > 1) then
            -- No time selection + multiple selected items on one track:
            -- build one job per item so new-tracks mode doesn't silently process only the first item.
            local selectedItems = selectedTrackItems or getSelectedAudibleItemsOnTrack(track)

            for itemIdx, item in ipairs(selectedItems) do
                jobIndex = jobIndex + 1
                local itemDir = baseTempDir .. PATH_SEP .. "item_" .. jobIndex
                makeDir(itemDir)
                local inputFile = itemDir .. PATH_SEP .. "input.wav"

                local extracted, err = renderSingleItemToWav(item, inputFile)
                if extracted then
                    local sourceItemName, sourceItemDisplayName = getItemNameFields(item, trackName)
                    local itemName = sourceItemDisplayName

                    -- Get audio duration without spawning ffprobe/CMD
                    local audioDuration = reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0

                    table.insert(trackJobs, {
                        track = track,
                        trackName = trackName .. " [" .. itemIdx .. "/" .. #selectedItems .. "]",
                        uiColor = getJobUIColor(track, jobIndex),
                        trackDir = itemDir,
                        inputFile = inputFile,
                        sourceItem = item,
                        sourceItems = {item},  -- Only this one item
                        itemNames = itemName,
                        sourceTrackName = trackName,
                        sourceItemName = sourceItemName,
                        sourceItemDisplayName = sourceItemDisplayName,
                        itemCount = 1,
                        expectedItemCount = 1,
                        expectedStemCount = selectedStemCount,
                        index = jobIndex,
                        audioDuration = audioDuration,
                        selPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0,
                        selLen = audioDuration,
                        perItem = true,
                    })
                end
            end
        else
            -- Original behavior: one job per track (combines items or uses time selection)
            jobIndex = jobIndex + 1
            local trackDir = baseTempDir .. PATH_SEP .. "track_" .. jobIndex
            makeDir(trackDir)
            local inputFile = trackDir .. PATH_SEP .. "input.wav"

            -- Use appropriate render function based on whether time selection exists
            local extracted, err, sourceItem, allSourceItems
            if hasTimeSel then
                extracted, err, sourceItem, allSourceItems = renderTrackTimeSelectionToWav(track, inputFile)
            else
                extracted, err, sourceItem, allSourceItems = renderTrackSelectedItemsToWav(track, inputFile)
            end
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
    multiTrackQueue.sequentialMode = not SETTINGS.parallelProcessing
    multiTrackQueue.forceSequentialReason = nil
    local hasPerItemJobs = false
    for _, job in ipairs(trackJobs) do
        if job.perItem then
            hasPerItemJobs = true
            break
        end
    end
    if SETTINGS.parallelProcessing and #trackJobs > 1 then
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

        local dev = string.lower(tostring(SETTINGS.device or "auto"))
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
            multiTrackQueue.sequentialMode = true
            multiTrackQueue.forceSequentialReason = "auto_no_gpu"
            debugLog("Forcing sequential multi-track processing (" .. multiTrackQueue.forceSequentialReason .. ")")
        end
    end
    multiTrackQueue.currentJobIndex = 0
    multiTrackQueue.globalStartTime = os.time()  -- Track total elapsed time
    multiTrackQueue.totalAudioDuration = 0  -- Will be updated when jobs start

    if not multiTrackQueue.sequentialMode then
        -- Start all separation processes in parallel (uses more VRAM)
        for _, job in ipairs(trackJobs) do
            startSeparationProcessForJob(job, 25)  -- Smaller segments for parallel
        end
    else
        -- Sequential mode: start only the first job (uses less VRAM)
        startSeparationProcessForJob(trackJobs[1], 40)  -- Larger segments for sequential
        multiTrackQueue.currentJobIndex = 1
    end

    -- Show progress window that monitors all jobs
    showMultiTrackProgressWindow()
end

-- Start a separation process for one job (no window, just background process)
-- segmentSize: optional, defaults to 25 for parallel, 40 for sequential
startSeparationProcessForJob = function(job, segmentSize)
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
    job.percent = 0
    job.stage = "Starting.."
    job.startTime = os.time()
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

    local requestedDeviceArg = tostring(SETTINGS.device or "auto")
    local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
    local modelArg  = tostring(SETTINGS.model or "htdemucs")
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

            local psInner =
                "$py='" .. python .. "';" ..
                "$sep='" .. sep .. "';" ..
                "$in='" .. inF .. "';" ..
                "$out='" .. outD .. "';" ..
                "$model='" .. m .. "';" ..
                "$dev='" .. dev .. "';" ..
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
                " Set-Content -Path '" .. doneF .. "' -Value 'DONE' -Encoding ascii"

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
              if OS == "macOS" then
                  local ffmpegPath = FFMPEG_PATH or getExtStateValue("ffmpegPath")
                  if ffmpegPath and ffmpegPath ~= "" then
                      script:write("FFMPEG_PATH=" .. quoteArg(ffmpegPath) .. "\n")
                      script:write("IMAGEIO_FFMPEG_EXE=" .. quoteArg(ffmpegPath) .. "\n")
                      script:write("export FFMPEG_PATH IMAGEIO_FFMPEG_EXE\n")
                      script:write("FFMPEG_DIR=$(dirname \"$FFMPEG_PATH\")\n")
                      script:write("PATH=\"$FFMPEG_DIR:${PATH}\"\n")
                      script:write("export PATH\n")
                  end
              end
              script:write("IN=" .. quoteArg(job.inputFile) .. "\n")
            script:write("OUT=" .. quoteArg(job.trackDir) .. "\n")
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
            script:write('  "$PY" -u "$SEP" "$IN" "$OUT" --model "$MODEL" --device "$DEVICE" >"$STDOUT" 2>"$STDERR"\n')
            script:write("  rc=$?\n")
            script:write('  echo "$rc" > "$EXITCODE"\n')
            script:write('  if [ "$rc" -ne 0 ]; then echo "EXIT:$rc" >> "$STDERR"; fi\n')
            script:write('  echo DONE > "$DONE"\n')
            script:write(") &\n")
            script:write('echo $! > "$PIDFILE"\n')
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
updateAllJobsProgress = function()
    for _, job in ipairs(multiTrackQueue.jobs) do
        -- Only check progress for jobs that have been started
        if job.startTime then
            local f = io.open(job.stdoutFile, "r")
            if f then
                local lastProgress = nil
                for line in f:lines() do
                    local percent, stage = line:match("PROGRESS:(%d+):(.+)")
                    if percent then
                        lastProgress = { percent = tonumber(percent), stage = stage }
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
                    job.done = true
                    -- In sequential mode, start the next job when this one completes
                    if multiTrackQueue.sequentialMode then
                        local nextIndex = multiTrackQueue.currentJobIndex + 1
                        if nextIndex <= #multiTrackQueue.jobs then
                            local nextJob = multiTrackQueue.jobs[nextIndex]
                            startSeparationProcessForJob(nextJob, 40)  -- Larger segments for sequential
                            multiTrackQueue.currentJobIndex = nextIndex
                        end
                    end
                end
            end
        else
            -- Job not yet started (sequential mode)
            job.percent = 0
            job.stage = "Waiting.."
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
            startSeparationProcessForJob(nextJob, 40)
            multiTrackQueue.currentJobIndex = math.max(tonumber(multiTrackQueue.currentJobIndex) or 0, nextWaitingIndex)
        end
    end
end

-- Check if all jobs are done
allJobsDone = function()
    for _, job in ipairs(multiTrackQueue.jobs) do
        if not job.done then return false end
    end
    return true
end

-- Calculate overall progress
getOverallProgress = function()
    local total = 0
    for _, job in ipairs(multiTrackQueue.jobs) do
        total = total + (job.percent or 0)
    end
    return math.floor(total / #multiTrackQueue.jobs)
end

-- Draw multi-track progress window
function drawMultiTrackProgressWindow()
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
    drawProceduralArt(0, 0, w, h, proceduralArt.time, 0, true)

    -- Semi-transparent overlay for readability - pure black/white
    if SETTINGS.darkMode then
        gfx.set(0, 0, 0, 0.5)
    else
        gfx.set(1, 1, 1, 0.5)
    end
    gfx.rect(0, 0, w, h, 1)

    -- === THEME TOGGLE (top right) ===
    local iconScale = 0.66
    local themeSize = math.max(PS(11), math.floor(PS(18) * iconScale + 0.5))
    local themeX = w - themeSize - PS(8)
    local themeY = PS(6)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - PS(60)
    local controlsBottom = themeY + themeSize + PS(30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local controlsOpacity = updateControlsOpacity(multiTrackQueue, mouseInControls)

    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.5) * controlsOpacity)
        gfx.circle(themeX + themeSize/2, themeY + themeSize/2, themeSize/2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)  -- Pure black for moon overlay
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

    -- Theme click and tooltip
    if themeHover and controlsOpacity > 0.3 then
        GUI.uiClickedThisFrame = true
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
        if rightMouseDown and not (multiTrackQueue.wasRightMouseDown or false) then
            cycleThemePreset()
        end
        if mouseDown and not multiTrackQueue.wasMouseDown then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
    end

    -- === FX TOGGLE (below theme icon) ===
    local fxSize = math.max(PS(10), math.floor(PS(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + PS(3)
    local fxHover = mx >= fxX - PS(2) and mx <= fxX + fxSize + PS(2) and my >= fxY - PS(2) and my <= fxY + fxSize + PS(2)

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

    if fxHover and controlsOpacity > 0.3 then
        GUI.uiClickedThisFrame = true
        tooltipText = SETTINGS.visualFX and T("fx_disable") or T("fx_enable")
        tooltipX, tooltipY = mx + PS(10), my + PS(15)
    end
    if fxHover and mouseDown and not multiTrackQueue.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
    end

    -- Title / branding
    gfx.setfont(1, "Arial", PS(16), string.byte('b'))
    local titleX = PS(20)
    local titleY = PS(25)

    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
    gfx.x = titleX
    gfx.y = titleY
    local multiTrackLabel = T("multi_track") or "Multi-Track"
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

    -- Language toggle (left of theme toggle)
    local langW = PS(20)
    local langH = PS(14)
    local langX = themeX - langW - PS(8)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    gfx.setfont(1, "Arial", PS(9), string.byte('b'))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    if langHover then
        GUI.uiClickedThisFrame = true
        gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
        if controlsOpacity > 0.3 then
            tooltipText = T("tooltip_change_language")
            tooltipX, tooltipY = mx + PS(10), my + PS(15)
            if rightMouseDown and not (multiTrackQueue.wasRightMouseDown or false) then
                SETTINGS.tooltips = not SETTINGS.tooltips
                saveSettings()
            end
            if mouseDown and not multiTrackQueue.wasMouseDown then
                -- Cycle through languages
                local langs = {"en", "nl", "de"}
                local currentIdx = 1
                for i, l in ipairs(langs) do
                    if l == SETTINGS.language then currentIdx = i; break end
                end
                local nextIdx = (currentIdx % #langs) + 1
                setLanguage(langs[nextIdx])
                saveSettings()
            end
        end
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    -- Stem indicators (simple colored boxes, like single-track)
    local selectedStems = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
            table.insert(selectedStems, stem)
        end
    end

    local stemRowY = titleY + PS(20)
    local stemBoxSize = PS(12)
    local stemX = PS(20)
    if #selectedStems > 0 then
        gfx.setfont(1, "Arial", PS(10))
        for _, stem in ipairs(selectedStems) do
            gfx.set(stem.color[1]/255, stem.color[2]/255, stem.color[3]/255, 1)
            gfx.rect(stemX, stemRowY, stemBoxSize, stemBoxSize, 1)
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
            gfx.x = stemX + stemBoxSize + PS(5)
            gfx.y = stemRowY + PS(1)
            gfx.drawstr(stem.name)
            stemX = stemX + stemBoxSize + gfx.measurestr(stem.name) + PS(16)
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
    local overallProgress = getOverallProgress()
    local animTime = proceduralArt.time or 0

    -- Progress bar background with subtle gradient
    for i = 0, barH - 1 do
        local shade = 0.1 + (i / barH) * 0.05
        if not SETTINGS.darkMode then shade = 0.85 - (i / barH) * 0.05 end
        gfx.set(shade, shade, shade + 0.02, 1)
        gfx.line(barX, barY + i, barX + barW, barY + i)
    end
    gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    gfx.rect(barX, barY, barW, barH, 0)

    -- Progress fill with the same stem color gradient as the single-track window.
    local fillW = math.floor(barW * overallProgress / 100)
    if fillW > 0 and #selectedStems > 0 then
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

    local function drawProgressText(text, x, y, alpha)
        alpha = alpha or 1
        gfx.set(0, 0, 0, 0.6 * alpha)
        gfx.x, gfx.y = x + 1, y + 1; gfx.drawstr(text)
        gfx.x, gfx.y = x - 1, y + 1; gfx.drawstr(text)
        gfx.x, gfx.y = x + 1, y - 1; gfx.drawstr(text)
        gfx.x, gfx.y = x - 1, y - 1; gfx.drawstr(text)
        gfx.set(1, 1, 1, alpha)
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
        tooltipText = multiTrackQueue.showTerminal and (T("tooltip_nerd_mode_hide") or "Switch to Art View") or (T("tooltip_nerd_mode_show") or "Nerd Mode: Show terminal output")
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

        if SETTINGS.darkMode then
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

        -- Accent tint: use the currently active track color for header/border (nice "alive" feedback).
        local activeAccent = nil
        if activeJob and type(activeJob.uiColor) == "table" then
            activeAccent = activeJob.uiColor
        end
        if activeAccent then
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

        if activeJob and type(activeJob.uiColor) == "table" then
            termProgR, termProgG, termProgB = activeJob.uiColor[1] or termProgR, activeJob.uiColor[2] or termProgG, activeJob.uiColor[3] or termProgB
        end

        -- Terminal text color should follow the same color as the processed track progress bar.
        local function jobBarColor(jobIdx)
            local s = STEMS[((jobIdx or 1) - 1) % #STEMS + 1]
            local c = s and s.color or {255, 255, 255}
            return { (c[1] or 255) / 255, (c[2] or 255) / 255, (c[3] or 255) / 255 }
        end
        local activeBar = activeJob and jobBarColor(activeJob.index or 1) or jobBarColor(1)
        if SETTINGS.darkMode then
            termTextR, termTextG, termTextB = activeBar[1] * 0.95, activeBar[2] * 0.95, activeBar[3] * 0.95
            termTextA = 0.92
        else
            -- Light mode: keep text readable, but nudge toward the active bar color.
            termTextR = (termTextR * 0.85) + (activeBar[1] * 0.15)
            termTextG = (termTextG * 0.85) + (activeBar[2] * 0.15)
            termTextB = (termTextB * 0.85) + (activeBar[3] * 0.15)
        end

        local termNow = uiNow()
        gfx.set(termBgR, termBgG, termBgB, termBgA)
        gfx.rect(displayX, displayY, displayW, displayH, 1)

        gfx.set(termBorderR, termBorderG, termBorderB, termBorderA)
        gfx.rect(displayX, displayY, displayW, displayH, 0)
        if SETTINGS.visualFX then
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
                    local header = string.format("[%d] ---- Track %d: %s ----", i, i, tostring(job.trackName or ""))
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
                    table.insert(multiTrackQueue.terminalLines, "---- Output ----")
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
                    if lineTrackIdx and lineAccent and line:match("%-%-%-%-") then
                        -- Track header line
                        gfx.set(lineAccent[1] or termTextR, lineAccent[2] or termTextG, lineAccent[3] or termTextB, 0.98)
                    elseif lineAccent and SETTINGS.darkMode then
                        -- Dark mode: tint normal lines toward track color
                        local ar, ag, ab = lineAccent[1] or termTextR, lineAccent[2] or termTextG, lineAccent[3] or termTextB
                        gfx.set((termTextR * 0.35) + (ar * 0.65), (termTextG * 0.35) + (ag * 0.65), (termTextB * 0.35) + (ab * 0.65), termTextA)
                    elseif lineAccent and not SETTINGS.darkMode then
                        -- Light mode: keep it readable; use a subtle tint
                        local ar, ag, ab = lineAccent[1] or 0.2, lineAccent[2] or 0.2, lineAccent[3] or 0.2
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
        if math.floor(termNow * 2) % 2 == 0 then
            gfx.set(termOkR, termOkG, termOkB, 1)
            gfx.x = displayX + PS(5)
            gfx.y = math.min(lineY, displayY + displayH - lineHeight - PS(5))
            gfx.drawstr("_")
        end

        -- Terminal hint
        gfx.set(termDimR, termDimG, termDimB, termDimA)
        gfx.setfont(1, "Courier", PS(8))
        local termHint = T("terminal_hint_return_to_art") or "Click >_ to return to art"
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
            gfx.set(THEME.inputBg[1], THEME.inputBg[2], THEME.inputBg[3], 1)
            gfx.rect(tBarX, yPos, tBarW, tBarH, 1)
            gfx.set(THEME.border[1], THEME.border[2], THEME.border[3], 1)
            gfx.rect(tBarX, yPos, tBarW, tBarH, 0)

            -- Fill
            local tFillW = math.floor(tBarW * (job.percent or 0) / 100)
            if tFillW > 0 then
                -- Color based on stem being processed
                local stemIdx = (i - 1) % #STEMS + 1
                local stemColor = STEMS[stemIdx].color
                gfx.set(stemColor[1]/255, stemColor[2]/255, stemColor[3]/255, 0.85)
                gfx.rect(tBarX + 1, yPos + 1, tFillW - 2, tBarH - 2, 1)
            end

            -- Stage text inside progress bar
            if not job.done and job.stage and job.stage ~= "" then
                gfx.setfont(1, "Arial", PS(9))
                local stageText = job.stage
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
                gfx.set(0.3, 0.75, 0.4, 1)
                gfx.x = tBarX + tBarW + PS(8)
                gfx.y = yPos + PS(2)
                gfx.drawstr(T("mt_done_label") or "Done")
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
            local scrollLabel = string.format("%d-%d/%d  wheel", visibleStart, visibleEnd, numJobs)
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

        if anyPerItem then
            local tpl = trSafeProgress("mt_footer_summary_items", "%d/%d %s | Queue %d | Audio %.1fs/%.1fs | %d %s")
            summaryLine1 = string.format(tpl,
                completedJobs, processedItemTotal, itemUnit, queuedItemCount, displayProcessedAudio, displayTotalDur, expectedStems, stemUnit)
        else
            local tpl = trSafeProgress("mt_footer_summary_tracks", "%d/%d %s | Audio %.1fs/%.1fs | %d %s")
            summaryLine1 = string.format(tpl,
                completedJobs, numJobs, trackUnit, displayProcessedAudio, displayTotalDur, expectedStems, stemUnit)
        end

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
    local segSize = multiTrackQueue.sequentialMode and "40" or "25"
    local modeStr = multiTrackQueue.sequentialMode and "Seq" or "Par"
    
    -- Fix misleading GPU reporting
    local modeSuffix = ""
    
    local totalMins = math.floor(globalElapsed / 60)
    local totalSecs = math.floor(globalElapsed % 60)
    local mtTime = T("mt_time") or "Time"
    local mtSeg = T("mt_seg") or "Seg"
    local mtCancel = T("mt_cancel") or "ESC=cancel"
    local etaText = ""
    if eta and eta > 0 then
        local etaMins = math.floor(eta / 60)
        local etaSecs = math.floor(eta % 60)
        local etaLabel = T("eta_label") or "ETA:"
        etaText = string.format(" | %s %d:%02d", tostring(etaLabel), etaMins, etaSecs)
    end
    
    local modelDisplay = (SETTINGS.model == "htdemucs_ft") and "Quality" or (is6Stem and "6-Stem" or "Fast")
    local leftParts = {
        string.format("%s: %d:%02d%s", mtTime, totalMins, totalSecs, etaText),
        string.format("%s: %s%s", mtSeg, segSize, modeStr),
        modelDisplay,
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
    gfx.x = gfx.w - statusPadX - rightTw
    gfx.y = row1Y
    gfx.drawstr(rightLabel)

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
        if summaryRight ~= "" then
            gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 0.68)
            gfx.x = gfx.w - statusPadX - summaryRightTw
            gfx.y = row2Y
            gfx.drawstr(summaryRightLabel)
        end
    end


    -- flarkAUDIO logo at top (translucent) - "flark" regular, "AUDIO" bold
    gfx.setfont(1, "Arial", PS(10))
    local flarkPart = "flark"
    local flarkPartW = gfx.measurestr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    local audioPart = "AUDIO"
    local audioPartW = gfx.measurestr(audioPart)
    local totalLogoW = flarkPartW + audioPartW
    local logoStartX = (w - totalLogoW) / 2
    -- Orange text, 50% translucent
    gfx.set(1.0, 0.5, 0.1, 0.5)
    gfx.setfont(1, "Arial", PS(10))
    gfx.x = logoStartX
    gfx.y = PS(3)
    gfx.drawstr(flarkPart)
    gfx.setfont(1, "Arial", PS(10), string.byte('b'))
    gfx.x = logoStartX + flarkPartW
    gfx.y = PS(3)
    gfx.drawstr(audioPart)

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

    -- Allow new art via click/space (anywhere that isn't UI)
    local char = gfx.getchar()
    handleArtAdvance(multiTrackQueue, mouseDown, char)

    -- Check for cancel
    if char == -1 or char == 27 then
        return "cancel"
    end

    return nil
end

-- Multi-track progress window loop
function multiTrackProgressLoop()
    local loopNow = uiNow()

    if loopNow >= (multiTrackQueue.nextPollAt or 0) then
        multiTrackQueue.nextPollAt = loopNow + UI_PACING.multiTrackPollInterval
        updateAllJobsProgress()
    end

    local result = nil
    if loopNow >= (multiTrackQueue.nextFrameAt or 0) then
        multiTrackQueue.nextFrameAt = loopNow + pacingFrameInterval("multiTrackFrameInterval", "multiTrackFrameIntervalFx")
        result = drawMultiTrackProgressWindow()
    end

    if result == "cancel" then
        -- Remember any size/position changes made during processing
        captureWindowGeometry(WINDOW_MULTI_TRACK)
        saveSettings()

        gfx.quit()
        multiTrackQueue.active = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Best-effort kill of all running workers so cancel is immediate and doesn't slow next run
        if multiTrackQueue.jobs then
            for _, job in ipairs(multiTrackQueue.jobs) do
                HELPERS.killProcessFromPidFile(job.pidFile)
            end
        end

        showMessage("Cancelled", "Multi-track separation was cancelled.", "info", true)
        return
    end

    if allJobsDone() then
        -- Remember any size/position changes made during processing
        captureWindowGeometry(WINDOW_MULTI_TRACK)
        saveSettings()

        gfx.quit()
        -- Process all results
        processAllStemsResult()
        return
    end

    reaper.defer(multiTrackProgressLoop)
end

-- Show multi-track progress window
showMultiTrackProgressWindow = function()
    -- Load settings to get current theme
    loadSettings()
    updateTheme()

    captureWindowGeometry(SCRIPT_NAME)
    GUI.snapshotMainGeometry()
    local winW, winH, winX, winY = GUI.applyLiveGeometry(840, 600)
    multiTrackQueue.listScroll = 0
    multiTrackQueue.nextFrameAt = 0
    multiTrackQueue.nextPollAt = 0
    gfx.init(WINDOW_MULTI_TRACK, winW, winH, 0, winX, winY)
    if OS == "Windows" then
        multiTrackProgressLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(multiTrackProgressLoop)
    end
end

-- isProcessingActive is declared near the top of the file to avoid accidentally
-- creating separate global/local variables in different parts of the script.

-- Process all stems after parallel jobs complete
processAllStemsResult = function()
    reaper.Undo_BeginBlock()

    local actionCount = 0
    local actionData = nil

    -- Skip item-level processing if deleteOriginalTrack is set (tracks will be deleted after stems created)
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

    local is6Stem = (SETTINGS.model == "htdemucs_6s")

    -- Use a stable selection range for item placement (avoid any stale globals).
    local globalSelPos = itemPos
    local globalSelLen = itemLen
    if timeSelectionMode and timeSelectionStart and timeSelectionEnd and timeSelectionEnd > timeSelectionStart then
        globalSelPos = timeSelectionStart
        globalSelLen = timeSelectionEnd - timeSelectionStart
    end

    for jobIdx, job in ipairs(multiTrackQueue.jobs) do
        debugLog("Job " .. jobIdx .. ": trackDir=" .. tostring(job.trackDir))
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

        -- Create stems based on output mode
        if next(stems) then
            local namingTrack = job.sourceTrackName or job.trackName or "Track"
            local namingItem = job.sourceItemName or job.sourceItemDisplayName or namingTrack
            stems = HELPERS.finalizeStemFiles(stems, namingTrack, namingItem)
            if SETTINGS.createNewTracks then
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
                debugLog("  Calling createStemTracksForSelection..")
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
                local count = createStemTracksForSelection(stems, jobSelPos, jobSelLen, job.track, itemsOverride, useItemNameForTrack)
                debugLog("  Created " .. count .. " stem tracks")
                totalStemsCreated = totalStemsCreated + count
                if count > 0 then
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
                        local count, mainItem = WORKFLOW.replaceInPlacePartial(sourceItem, stems, selStart, selEnd, nameBase)
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
                        local count, mainItem = WORKFLOW.replaceInPlace(sourceItem, stems, srcItemPos, srcItemLen, nameBase)
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
                    end
                else
                    debugLog("  ERROR: No valid source item for in-place replacement")
                end
            end
            table.insert(trackNames, job.trackName)
        else
            debugLog("  No stems found, skipping")
        end
    end
    local sourceTrackCountWithStems = 0
    for _ in pairs(sourceTracksWithStems) do sourceTrackCountWithStems = sourceTrackCountWithStems + 1 end
    local sourceItemCountWithStems = 0
    for _ in pairs(sourceItemsWithStems) do sourceItemCountWithStems = sourceItemCountWithStems + 1 end
    debugLog("Total stems created: " .. totalStemsCreated)

    -- If nothing was created, surface the Python log instead of silently returning to main().
    -- Also undo any mute/delete actions that may have been applied earlier in this function.
    if totalStemsCreated == 0 then
        -- Use the first job's log as the primary error (usually enough).
        local firstJob = multiTrackQueue.jobs and multiTrackQueue.jobs[1] or nil
        local logPath = firstJob and firstJob.logFile or nil
        local logSnippet = SW_LOG.readFileSnippet(logPath, 1400) or "(no log output found)"
        local exitCode = firstJob and SW_LOG.readExitCode(firstJob.exitCodeFile) or nil
        local cmdLine = firstJob and firstJob.lastCmd or nil
        local debugLogPath = firstJob and (firstJob.execLogPath or SW_LOG.getLogPath()) or SW_LOG.getLogPath()

        local msg = "No stems were created.\n\n"
            .. "This usually means the Python separator failed to start or crashed.\n\n"
            .. "Exit code: " .. tostring(exitCode or "unknown") .. "\n"
            .. "Command: " .. tostring(cmdLine or "unknown") .. "\n"
            .. "Python log (" .. tostring(logPath or "unknown") .. "):\n"
            .. logSnippet
            .. "\n\nDebug log: " .. tostring(debugLogPath)

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
        showMessage("Separation Failed", msg, "error", true)
        return
    end

    -- Handle delete/mute options AFTER stems are created (so placement isn't disturbed)
    if applyCleanup and not SETTINGS.deleteOriginalTrack then
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

    -- Handle deleteOriginalTrack AFTER stems are created (deletes entire source tracks)
    if applyCleanup and SETTINGS.deleteOriginalTrack then
        -- Collect unique tracks from jobs (delete in reverse order to avoid index issues)
        local tracksToDelete = {}
        for _, job in ipairs(multiTrackQueue.jobs) do
            if job.track and reaper.ValidatePtr(job.track, "MediaTrack*") then
                -- Check if track is not already in list
                local found = false
                for _, t in ipairs(tracksToDelete) do
                    if t == job.track then found = true; break end
                end
                if not found then
                    table.insert(tracksToDelete, job.track)
                end
            end
        end
        -- Delete tracks in reverse order (higher indices first)
        local trackDeleteCount = 0
        for i = #tracksToDelete, 1, -1 do
            local track = tracksToDelete[i]
            if reaper.ValidatePtr(track, "MediaTrack*") then
                reaper.DeleteTrack(track)
                trackDeleteCount = trackDeleteCount + 1
            end
        end
        if trackDeleteCount > 0 then
            actionData = { kind = "tracks", key = "result_action_tracks_deleted", count = trackDeleteCount }
        end
    end

    reaper.Undo_EndBlock("STEMwerk: Multi-track stem separation", -1)
    adjustTrackLayout()

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
        bf:write(string.format("Model: %s\n", SETTINGS.model or "?"))
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
    local is6Stem = (SETTINGS.model == "htdemucs_6s")
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
            requestedParallel = SETTINGS.parallelProcessing and true or false,
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
            requestedParallel = SETTINGS.parallelProcessing and true or false,
        }
    end
    resultData.action = actionData

    -- Cleanup temp working files (keep stem WAVs for REAPER references).
    if multiTrackQueue.jobs then
        for _, job in ipairs(multiTrackQueue.jobs) do
            if job.trackDir then
                cleanupTempWorkDir(job.trackDir)
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

    if OS == "Windows" then
        showProcessingPlaceholderWindow("Checking runtime...")
    end

    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end

    if (not trustedWindowsRuntime) and (not ensureDependenciesInteractive()) then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
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
        if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
            selectedStemCount = selectedStemCount + 1
        end
    end
    if selectedStemCount <= 0 then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(T("no_stems_selected") or "No Stems Selected", T("please_select_stem") or "Please select at least one stem.", "warning")
        isProcessingActive = false
        return
    end

    if tostring(SETTINGS.stemFileDestination or "temp") == "custom" and HELPERS.trimString(SETTINGS.customStemDir) == "" then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesMissingCustomWarning(), "warning")
        isProcessingActive = false
        return
    end
    if tostring(SETTINGS.stemFileDestination or "temp") == "project_media" and not HELPERS.getProjectMediaDir() then
        if OS == "Windows" and progressState.windowOpen then
            closeProcessingWindow()
        end
        showMessage(HELPERS.getStemFilesWarningTitle(), HELPERS.getStemFilesProjectUnavailableWarning(), "warning")
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
            isProcessingActive = false
            return
        end
    adjustTrackLayout()
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
        isProcessingActive = false
        return
    end

    PROCESS_SELECTION_SNAPSHOT = nil

    if OS == "Windows" then
        showProcessingPlaceholderWindow("Preparing audio...")
    end

    WORKFLOW_TEMP_DIR = makeUniqueTempSubdir("STEMwerk")
    makeDir(WORKFLOW_TEMP_DIR)
    WORKFLOW_TEMP_INPUT = WORKFLOW_TEMP_DIR .. PATH_SEP .. "input.wav"
    debugLog("Temp dir: " .. WORKFLOW_TEMP_DIR)
    debugLog("Temp input: " .. WORKFLOW_TEMP_INPUT)

    local extracted, err, sourceItem, trackList, trackItems
	    if timeSelectionMode then
	        debugLog("Rendering time selection to WAV..")
	        timeSelectionItemMap = nil
	        selectedItemsNoTimeMap = nil
	        extracted, err, sourceItem, trackList, trackItems = renderTimeSelectionToWav(WORKFLOW_TEMP_INPUT)
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
            runSingleTrackSeparation(trackList)
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
            runSingleTrackSeparation(trackList)
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
            runSingleTrackSeparation(combinedTrackList)
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
            runSingleTrackSeparation(trackList)
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

        extracted, err = renderItemToWav(selectedItem, WORKFLOW_TEMP_INPUT)
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
            if noAudibleTargets then
                local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
                showMessage(promptTitle, promptMessage, "info", true)
            elseif hasTimeSelection() or hasAnySelection() then
                showStemSelectionDialog()
            else
                local promptTitle, promptMessage = HELPERS.getSelectionMonitorPrompt()
                showMessage(promptTitle, promptMessage, "info", true)
            end
        end)
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
    WORKFLOW.runSeparationWithProgress(WORKFLOW_TEMP_INPUT, WORKFLOW_TEMP_DIR, SETTINGS.model)
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
        end

        return true  -- Quick mode, skip dialog
    end
    return false
end

-- Main
main = function()
    debugLog("=== main() called ===")
    perfMark("main() enter")

    if not PATH_STATE.guardNonCanonicalLaunch() then
        return
    end

    -- If a toolbar preset requested an immediate run, bypass the focus-only guard.
    local quickRunRequested = (reaper and reaper.GetExtState and reaper.GetExtState(EXT_SECTION, "quick_run") == "1")

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
                isProcessingActive = false
                showMessage("Error", "STEMwerk crashed while starting processing.\n\nSee log:\n" .. tostring(DEBUG.logPath), "error")
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
