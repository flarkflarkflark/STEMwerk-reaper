local M = {}

local C = {}
local PATH_HELPER = nil
local INSTALL_CACHE = nil

local function getPathHelper()
    if PATH_HELPER then return PATH_HELPER end
    local base = C.script_path or ""
    if base == "" then return nil end
    local ok, helper = pcall(dofile, base .. "_internal/STEMwerk_Path_Helper.lua")
    if ok and type(helper) == "table" then
        PATH_HELPER = helper
        return PATH_HELPER
    end
    return nil
end

local function resolveInstallRoot()
    if INSTALL_CACHE then return INSTALL_CACHE end
    local helper = getPathHelper()
    local script_path = C.script_path or ""
    if helper and script_path ~= "" then
        INSTALL_CACHE = helper.resolveInstallRoot(script_path, { os = C.OS })
    else
        INSTALL_CACHE = {
            ok = true,
            root = script_path,
            scriptsDir = script_path,
            canonical = "",
        }
    end
    return INSTALL_CACHE
end

local function showInstallMismatch(install)
    if type(C.showMessageBox) ~= "function" then return end
    if not install then return end
    local text = ""
    if install.canonicalMismatch and install.canonical ~= "" then
        text = "STEMwerk is not installed in the canonical REAPER Scripts path.\n\n"
            .. "Preferred:\n" .. tostring(install.canonical or "(unknown)") .. "\n\n"
            .. "Current runtime install:\n" .. tostring(install.root or "(unknown)") .. "\n\n"
            .. "Setup continues using the current install location."
    else
        text = "STEMwerk runtime location could not be resolved from script path.\n\n"
            .. "Reinstall STEMwerk and run STEMwerk-SETUP.lua from REAPER."
    end
    C.showMessageBox(
        "STEMwerk Setup",
        text,
        0
    )
end

function M.configure(context)
    if type(context) ~= "table" then
        return
    end
    for k, v in pairs(context) do
        C[k] = v
    end
end

local function debugLog(msg)
    if type(C.debugLog) == "function" then
        C.debugLog(msg)
    end
end

local function logExec(cmd, rc, out)
    if type(C.logExecResult) == "function" then
        C.logExecResult(cmd, rc, out)
    end
end

local function fileExists(path)
    return (type(C.fileExists) == "function" and C.fileExists(path)) or false
end

local function getDepState()
    if type(C.getDepState) == "function" then
        local state = C.getDepState()
        if type(state) == "table" then
            return state
        end
    end
    return nil
end

local function commandQuote(s)
    local q = C.quoteArg
    if type(q) == "function" then
        return q(s)
    end
    return '"' .. tostring(s) .. '"'
end

local function execCommandWithOutput(cmd, timeoutMs)
    local execProcess = C.execProcess
    if type(execProcess) == "function" then
        local rc, out = execProcess(cmd, timeoutMs or 15000)
        return tonumber(rc) or -1, out or ""
    end

    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        return -1, ""
    end
    local out = handle:read("*a") or ""
    local ok, _, code = handle:close()
    if ok == true then
        return 0, out
    end
    if code ~= nil then
        return tonumber(code) or -1, out
    end
    return -1, out
end

local function commandPathLooksUsable(path)
    return (type(C.isAbsolutePath) ~= "function" or C.isAbsolutePath(path)) and fileExists(path)
end

local function isWindowsFfmpegShimPath(path)
    if (C.OS or "Windows") ~= "Windows" then return false end
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\winget\\links\\ffmpeg.exe", 1, true)
        or p:find("\\windowsapps\\ffmpeg", 1, true)
        or p:find("/microsoft/winget/links/ffmpeg.exe", 1, true)
        or p:find("/windowsapps/ffmpeg", 1, true)
end

local function readBootstrapEnvFfmpeg(runtime)
    if not runtime or not runtime.base then return "" end
    local PATH_SEP = C.PATH_SEP or "/"
    local stateDir = runtime.runtimeState or (runtime.base .. PATH_SEP .. "state")
    local stateFile = stateDir .. PATH_SEP .. "bootstrap.env"
    local f = io.open(stateFile, "r")
    if not f then return "" end
    for line in f:lines() do
        local k, v = line:match("^([A-Z0-9_]+)%s*=%s*(.*)$")
        if k == "FFMPEG_PATH" and v and v ~= "" then
            f:close()
            return v:gsub("\r", "")
        end
    end
    f:close()
    return ""
end

local function isWindowsStorePythonPath(path)
    if (C.OS or "Windows") ~= "Windows" then return false end
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\windowsapps\\python", 1, true)
        or p:find("/microsoft/windowsapps/python", 1, true)
end

local function isUsableWindowsPythonPath(path)
    if not path or path == "" then return false end
    if isWindowsStorePythonPath(path) then return false end
    local p = tostring(path)
    local lower = p:lower()
    if lower == "python" or lower == "python.exe" then return false end
    if type(C.isAbsolutePath) == "function" and not C.isAbsolutePath(p) then return false end
    return fileExists(p)
end

local function readBootstrapEnvPython(runtime)
    if not runtime or not runtime.base then return "" end
    local PATH_SEP = C.PATH_SEP or "/"
    local stateDir = runtime.runtimeState or (runtime.base .. PATH_SEP .. "state")
    local stateFile = stateDir .. PATH_SEP .. "bootstrap.env"
    local f = io.open(stateFile, "r")
    if not f then return "" end
    local py = ""
    local venv = ""
    for line in f:lines() do
        local k, v = line:match("^([A-Z0-9_]+)%s*=%s*(.*)$")
        if k == "PYTHON_PATH" and v and v ~= "" then
            py = v:gsub("\r", "")
        elseif k == "VENV_PYTHON" and v and v ~= "" then
            venv = v:gsub("\r", "")
        end
    end
    f:close()
    if py ~= "" then return py end
    if venv ~= "" then return venv end
    return ""
end

local function resolveWindowsPythonPath(runtime)
    local caps = M.readCapabilities and M.readCapabilities() or nil
    local capPy = caps and caps.kv and caps.kv.PYTHON_PATH or ""
    if isUsableWindowsPythonPath(capPy) then
        return capPy
    end

    local bootstrapPy = readBootstrapEnvPython(runtime)
    if isUsableWindowsPythonPath(bootstrapPy) then
        return bootstrapPy
    end

    if runtime and isUsableWindowsPythonPath(runtime.venvPython) then
        return runtime.venvPython
    end

    local extPath = type(C.getExtStateValue) == "function" and C.getExtStateValue("pythonPath") or nil
    if isUsableWindowsPythonPath(extPath) then
        return extPath
    end

    local h = io.popen("where python 2>nul")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    for line in out:gmatch("[^\r\n]+") do
        local p = line:gsub("^%s+", ""):gsub("%s+$", "")
        if isUsableWindowsPythonPath(p) then
            return p
        end
    end
    return ""
end

local function resolveNonWindowsPythonPath(runtime)
    local pythonPath = type(C.getPythonPath) == "function" and C.getPythonPath() or nil
    local canRunPython = C.canRunPython

    if pythonPath and pythonPath ~= "" then
        if type(canRunPython) == "function" then
            if canRunPython(pythonPath) then
                return pythonPath
            end
        elseif canRunCommand(pythonPath, " --version", "Python", 12000) then
            return pythonPath
        end
    end

    if runtime and runtime.venvPython and runtime.venvPython ~= "" then
        if type(canRunPython) == "function" then
            if canRunPython(runtime.venvPython) then
                return runtime.venvPython
            end
        elseif canRunCommand(runtime.venvPython, " --version", "Python", 12000) then
            return runtime.venvPython
        end
    end

    return ""
end

local function resolveRuntimeFfmpeg(runtime)
    if not runtime or not runtime.base then return "" end
    local PATH_SEP = C.PATH_SEP or "/"
    local base = runtime.base
    local candidates = {
        base .. PATH_SEP .. "ffmpeg" .. PATH_SEP .. "bin" .. PATH_SEP .. "ffmpeg.exe",
        base .. PATH_SEP .. "ffmpeg" .. PATH_SEP .. "ffmpeg.exe",
        base .. PATH_SEP .. "bin" .. PATH_SEP .. "ffmpeg.exe",
    }
    for _, p in ipairs(candidates) do
        if fileExists(p) and not isWindowsFfmpegShimPath(p) then
            return p
        end
    end
    return ""
end

local function resolveWindowsFfmpegPath(runtime)
    local runtimePath = resolveRuntimeFfmpeg(runtime)
    if runtimePath ~= "" then return runtimePath end

    local bootstrapPath = readBootstrapEnvFfmpeg(runtime)
    if bootstrapPath ~= "" and not isWindowsFfmpegShimPath(bootstrapPath) and fileExists(bootstrapPath) then
        return bootstrapPath
    end

    local extPath = type(C.getExtStateValue) == "function" and C.getExtStateValue("ffmpegPath") or nil
    if extPath and isWindowsFfmpegShimPath(extPath) then
        if type(C.setExtStateValue) == "function" then
            C.setExtStateValue("ffmpegPath", "")
        end
        extPath = nil
    end
    if extPath and extPath ~= "" and fileExists(extPath) then
        return extPath
    end
    if (C.OS or "Windows") == "Windows" then
        local h = io.popen("where ffmpeg 2>nul")
        if h then
            local out = h:read("*a") or ""
            h:close()
            for line in out:gmatch("[^\r\n]+") do
                local p = line:gsub("^%s+", ""):gsub("%s+$", "")
                if p ~= "" and fileExists(p) and not isWindowsFfmpegShimPath(p) then
                    return p
                end
            end
        end
    end
    return ""
end

local function canRunCommand(path, arg, expectedPattern, timeoutMs)
    if not path or path == "" then return false end
    if type(C.isAbsolutePath) == "function" and C.isAbsolutePath(path) and not fileExists(path) then
        return false
    end

    local cmd = commandQuote(path) .. arg
    local rc, out = execCommandWithOutput(cmd, timeoutMs)
    if rc == 0 then
        if expectedPattern == nil or tostring(out):find(expectedPattern, 1, true) then
            return true
        end
    end

    local out2 = tostring(out or "")
    if expectedPattern == nil then
        return out2 ~= ""
    end
    return (out2 ~= "" and out2:find(expectedPattern, 1, true) ~= nil)
end

local function setDepState(state, detail)
    if type(C.setDepState) == "function" then
        C.setDepState(state, detail)
        return
    end
    local stateObj = getDepState()
    if not stateObj then return end
    stateObj.state = state or "unknown"
    stateObj.detail = detail
    stateObj.updatedAt = os.time()
    stateObj.prompted = stateObj.prompted or false
end

local function bootstrapActive()
    if type(C.getBootstrapActive) == "function" then
        return C.getBootstrapActive() and true or false
    end
    return false
end

local function setBootstrapActive(active)
    if type(C.setBootstrapActive) == "function" then
        C.setBootstrapActive(active and true or false)
    end
end

local function refreshRuntimeState()
    local refresh = C.refreshRuntimeState
    local py
    local sep
    if type(refresh) == "function" then
        py, sep = refresh()
    else
        if type(C.findPython) == "function" then
            py = C.findPython()
        end
        if type(C.findSeparatorScript) == "function" then
            sep = C.findSeparatorScript()
        end
        if type(C.setPythonPath) == "function" then
            C.setPythonPath(py)
        end
        if type(C.setSeparatorScript) == "function" then
            C.setSeparatorScript(sep)
        end
    end
    return py, sep
end

function M.ensureWritableDir(path)
    if not path or path == "" then return false end

    if C.SW_LOG and C.SW_LOG.ensureDir then
        C.SW_LOG.ensureDir(path)
    else
        local quoted = (type(C.quoteArg) == "function" and C.quoteArg(path)) or ('"' .. tostring(path) .. '"')
        if (C.OS or "Windows") == "Windows" then
            os.execute("mkdir " .. quoted .. " 2>nul")
        else
            os.execute("mkdir -p " .. quoted .. " 2>/dev/null")
        end
    end

    local sep = C.PATH_SEP or "/"
    local f = io.open(path .. sep .. ".stemwerk_write_test", "w")
    if not f then return false end
    f:write("ok")
    f:close()
    os.remove(path .. sep .. ".stemwerk_write_test")
    return true
end

function M.getRuntimeBase()
    local isAbsolutePath = C.isAbsolutePath
    local getExtStateValue = C.getExtStateValue
    local getHome = C.getHome

    local override = (type(getExtStateValue) == "function") and getExtStateValue("runtimeBase") or nil
    if override ~= nil and type(isAbsolutePath) == "function" and isAbsolutePath(override) then
        return override
    end

    local OS = C.OS or "Linux"
    local PATH_SEP = C.PATH_SEP or "/"
    local home = (type(getHome) == "function" and getHome()) or (os.getenv("HOME") or "/tmp")
    local candidates = {}

    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then table.insert(candidates, localAppData .. "\\STEMwerk") end
    elseif OS == "macOS" then
        table.insert(candidates, home .. "/Library/Application Support/STEMwerk")
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then table.insert(candidates, xdg .. "/STEMwerk") end
        table.insert(candidates, home .. "/.local/share/STEMwerk")
    end

    for _, base in ipairs(candidates) do
        if M.ensureWritableDir(base) then
            if type(C.setExtStateValue) == "function" then
                C.setExtStateValue("runtimeBase", tostring(base))
            end
            return base
        end
    end

    return candidates[1] or (home .. PATH_SEP .. ".STEMwerk")
end

function M.getRuntimePaths()
    local base = M.getRuntimeBase()
    local PATH_SEP = C.PATH_SEP or "/"
    local OS = C.OS or "Linux"
    local runtimeRoot = base
    local runtimeState = base .. PATH_SEP .. "state"
    local runtimeLogs = base .. PATH_SEP .. "logs"
    local runtimeCache = base .. PATH_SEP .. "cache"
    local venvDir = base .. PATH_SEP .. ".venv"
    return {
        base = base,
        runtimeRoot = runtimeRoot,
        runtimeBin = base .. PATH_SEP .. "bin",
        runtimePython = base .. PATH_SEP .. "python",
        runtimeFfmpeg = base .. PATH_SEP .. "ffmpeg",
        runtimeState = runtimeState,
        runtimeLogs = runtimeLogs,
        runtimeCache = runtimeCache,
        venvDir = venvDir,
        venvPython = OS == "Windows" and (venvDir .. "\\Scripts\\python.exe") or (venvDir .. "/bin/python"),
    }
end

function M.getCapabilityPath()
    local paths = M.getRuntimePaths()
    local PATH_SEP = C.PATH_SEP or "/"
    local stateDir = paths.runtimeState or (paths.runtimeRoot .. PATH_SEP .. "state")
    return stateDir .. PATH_SEP .. "capabilities.env"
end

function M.readCapabilities()
    local capPath = M.getCapabilityPath()
    local f = io.open(capPath, "r")
    if not f then return nil end
    local raw = f:read("*a") or ""
    f:close()
    if raw == "" then return nil end
    local kv = {}
    for line in raw:gmatch("[^\r\n]+") do
        local k, v = line:match("^([A-Z0-9_]+)=(.*)$")
        if k and v then
            kv[k] = v
        end
    end
    return {
        path = capPath,
        raw = raw,
        kv = kv,
    }
end

function M.getCapabilityPath()
    local paths = M.getRuntimePaths()
    local PATH_SEP = C.PATH_SEP or "/"
    local stateDir = paths.runtimeState or (paths.runtimeRoot .. PATH_SEP .. "state")
    return stateDir .. PATH_SEP .. "capabilities.env"
end

function M.readCapabilities()
    local capPath = M.getCapabilityPath()
    local f = io.open(capPath, "r")
    if not f then return nil end
    local raw = f:read("*a") or ""
    f:close()
    if raw == "" then return nil end
    local kv = {}
    for line in raw:gmatch("[^\r\n]+") do
        local k, v = line:match("^([A-Z0-9_]+)=(.*)$")
        if k and v then
            kv[k] = v
        end
    end
    return {
        path = capPath,
        raw = raw,
        kv = kv,
    }
end

function M.resolveCommandPath(cmd)
    if not cmd or cmd == "" then return nil end
    if type(C.isAbsolutePath) == "function" and C.isAbsolutePath(cmd) then
        return cmd
    end

    local execProcess = C.execProcess
    local quoteArg = C.quoteArg
    local q = type(quoteArg) == "function" and quoteArg(cmd) or ('"' .. tostring(cmd) .. '"')
    if C.OS == "Windows" then
        if type(execProcess) == "function" then
            local rc, out = execProcess("where " .. q, 8000)
            if rc == 0 and out then
                for line in out:gmatch("[^\r\n]+") do
                    if line ~= "" then
                        return line
                    end
                end
            end
        end
    else
        if type(execProcess) == "function" then
            local rc, out = execProcess("command -v " .. q, 8000)
            if rc == 0 and out then
                local path = out:match("([^\r\n]+)")
                if path and path ~= "" then
                    return path
                end
            end
        end
    end
    return nil
end

function M.persistPythonPath(path)
    local isAbsolutePath = C.isAbsolutePath
    local setExtStateValue = C.setExtStateValue
    if type(setExtStateValue) ~= "function" then return end
    if not path or path == "" then return end

    local toStore = path
    local resolved = nil
    if type(isAbsolutePath) == "function" and not isAbsolutePath(toStore) then
        resolved = M.resolveCommandPath(toStore)
        if resolved then
            toStore = resolved
        end
    end

    if not fileExists(toStore) then
        resolved = M.resolveCommandPath(toStore)
        if resolved then
            toStore = resolved
        end
    end

    setExtStateValue("pythonPath", tostring(toStore))
    debugLog("Persisted pythonPath to ExtState: " .. tostring(toStore))
end

function M.canImportAudioSeparator(pythonPath)
    if not pythonPath or pythonPath == "" then return false end
    local cmd = commandQuote(pythonPath) .. " -c " .. commandQuote("import audio_separator; import onnxruntime; from audio_separator.separator import Separator")
    local rc, out = execCommandWithOutput(cmd, 15000)
    if rc == 0 then
        return true
    end
    logExec("audio_separator_import", rc, out or "")
    return false
end

local function canImportModule(pythonPath, moduleName)
    if not pythonPath or pythonPath == "" or not moduleName or moduleName == "" then return false end
    local cmd = commandQuote(pythonPath) .. " -c " .. commandQuote("import " .. moduleName)
    local rc = select(1, execCommandWithOutput(cmd, 15000))
    return tonumber(rc) == 0
end

local function checkMacOSDemucsCompatibility(pythonPath)
    if (C.OS or "") ~= "macOS" then return true, nil end
    if not pythonPath or pythonPath == "" then return true, nil end
    local script = [=[
import sys
def core(v):
    return str(v).split("+", 1)[0]
try:
    import torch
except Exception as exc:
    print("torch_import_failed:" + str(exc))
    sys.exit(1)
try:
    import numpy
except Exception as exc:
    print("numpy_import_failed:" + str(exc))
    sys.exit(1)
t = core(getattr(torch, "__version__", "0.0.0"))
n = core(getattr(numpy, "__version__", "0.0.0"))
try:
    tmj, tmn = [int(x) for x in t.split(".")[:2]]
except Exception:
    tmj, tmn = 0, 0
try:
    nmj = int(n.split(".", 1)[0])
except Exception:
    nmj = 0
if tmj > 2 or (tmj == 2 and tmn >= 6):
    print("torch_too_new:" + t)
    sys.exit(2)
if nmj >= 2:
    print("numpy_too_new:" + n)
    sys.exit(3)
print("ok")
]=]
    local cmd = commandQuote(pythonPath) .. " -c " .. commandQuote(script)
    local rc, out = execCommandWithOutput(cmd, 15000)
    local text = trim(out or "")
    if tonumber(rc) == 0 then return true, nil end
    logExec("macos_demucs_compat_failed", rc or -1, text)
    if text:find("torch_too_new:", 1, true) then
        return false, "torch_too_new_for_demucs"
    end
    if text:find("numpy_too_new:", 1, true) then
        return false, "numpy_too_new_for_demucs"
    end
    return false, "macos_demucs_runtime_incompatible"
end

function M.safeDofile(path)
    if not path or path == "" then
        return false, "missing"
    end
    if not fileExists(path) then
        return false, "missing"
    end

    local ok, err = xpcall(function()
        dofile(path)
    end, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)

    if not ok then
        debugLog("Setup dofile failed: " .. tostring(err))
        logExec("setup_dofile_failed", -1, err)
    end
    return ok, err
end

function M.isPythonAvailable(path)
    if not path or path == "" then
        return false
    end
    if type(C.isAbsolutePath) == "function" and C.isAbsolutePath(path) and not fileExists(path) then
        return false
    end

    local canRunPython = C.canRunPython
    if type(canRunPython) == "function" and canRunPython(path) then
        return true
    end
    return canRunCommand(path, " --version", "Python", 12000)
end

function M.runSetup()
    local install = resolveInstallRoot()
    if not install.ok then
        showInstallMismatch(install)
        return false
    end

    local scriptsDir = install.scriptsDir or (C.script_path or "")
    if install.canonicalMismatch then
        showInstallMismatch(install)
    end

    local setupScript = scriptsDir .. "_internal/STEMwerk_Setup_Internal.lua"

    if not fileExists(setupScript) then
        setupScript = scriptsDir .. "STEMwerk-SETUP.lua"
    end

    if not fileExists(setupScript) then
        return false
    end

    local ok, err = M.safeDofile(setupScript)
    if not ok and type(C.showMessageBox) == "function" then
        local logPath = C.SW_LOG and C.SW_LOG.getLogPath and C.SW_LOG.getLogPath() or "(unknown)"
        C.showMessageBox(
            "Setup script failed.\n\nSee log:\n" .. tostring(logPath) .. "\n\n" .. tostring(err),
            "STEMwerk Setup",
            0
        )
    end
    return ok
end

function M.verifyRuntimeAfterBootstrap()
    local runtime = M.getRuntimePaths()
    local errors = {}
    local pythonPath
    if (C.OS or "Windows") == "Windows" then
        pythonPath = resolveWindowsPythonPath(runtime)
    else
        pythonPath = resolveNonWindowsPythonPath(runtime)
    end
    if pythonPath and pythonPath ~= "" and type(C.setPythonPath) == "function" then
        C.setPythonPath(pythonPath)
    end
    local canRunFfmpeg = C.canRunFfmpeg

    local pythonOk = M.isPythonAvailable(pythonPath)
    if not pythonOk then
        errors[#errors + 1] = "python_unavailable"
    end

    if not fileExists(runtime.venvPython) then
        if not (pythonPath and pythonPath ~= "" and fileExists(pythonPath)) then
            errors[#errors + 1] = "venv_missing"
        end
    end

    local ffmpegPath = nil
    local ffmpegOk = false
    if type(canRunFfmpeg) == "function" then
        ffmpegPath = resolveWindowsFfmpegPath(runtime)
        if ffmpegPath and ffmpegPath ~= "" then
            ffmpegOk = canRunFfmpeg(ffmpegPath)
        else
            ffmpegOk = canRunFfmpeg()
        end
    end
    if not ffmpegOk and ffmpegPath and ffmpegPath ~= "" then
        ffmpegOk = canRunCommand(ffmpegPath, " -version", "ffmpeg version", 8000)
    end
    if not ffmpegOk then
        errors[#errors + 1] = "ffmpeg_unavailable"
    end

    if pythonOk and not M.canImportAudioSeparator(pythonPath) then
        errors[#errors + 1] = "audio_separator_missing"
    end
    if pythonOk and not canImportModule(pythonPath, "samplerate") then
        errors[#errors + 1] = "samplerate_missing"
    end
    if pythonOk and not canImportModule(pythonPath, "stemwerk_core") then
        errors[#errors + 1] = "stemwerk_core_missing"
    end
    if pythonOk then
        local compatOk, compatErr = checkMacOSDemucsCompatibility(pythonPath)
        if not compatOk and compatErr then
            errors[#errors + 1] = compatErr
        end
    end

    if #errors > 0 then
        logExec("runtime_verify_failed", -1, table.concat(errors, ","))
    end
    return (#errors == 0), errors
end

function M.resolveRuntimePythonPath()
    local runtime = M.getRuntimePaths()
    if (C.OS or "Windows") == "Windows" then
        return resolveWindowsPythonPath(runtime)
    end
    return resolveNonWindowsPythonPath(runtime)
end

function M.ensureDependenciesInteractive()
    local state = getDepState()
    if not state then return false end

    if state.state == "ok" then
        return true
    end
    if state.state == "running" then
        return false
    end
    local helper = getPathHelper()
    if helper then
        local runtime = M.getRuntimePaths()
        local guardPath = helper.getBootstrapGuardPath(runtime.runtimeState, C.PATH_SEP or "/")
        local guard = helper.readEnvFile(guardPath)
        if guard.STATUS == "failed" then
            setDepState("failed", "bootstrap_guard:" .. tostring(guard.REASON or "failed"))
            if type(C.showMessageBox) == "function" then
                C.showMessageBox(
                    "STEMwerk Setup",
                    "Previous bootstrap failed.\n\nReason: " .. tostring(guard.REASON or "unknown") .. "\n\n"
                        .. "Fix the install and run STEMwerk-SETUP.lua manually in REAPER.",
                    0
                )
            end
            return false
        end
    end

    local caps = M.readCapabilities()
    if caps and caps.kv and caps.kv.VERIFICATION == "ok" and (caps.kv.BOOTSTRAP_STATUS == "" or caps.kv.BOOTSTRAP_STATUS == "ok") then
        local pyOk = (caps.kv.PYTHON_PATH and caps.kv.PYTHON_PATH ~= "" and fileExists(caps.kv.PYTHON_PATH)) or false
        local ffOk = (caps.kv.FFMPEG_PATH and caps.kv.FFMPEG_PATH ~= "" and fileExists(caps.kv.FFMPEG_PATH)) or false
        if pyOk and ffOk then
            if type(C.setPythonPath) == "function" then
                C.setPythonPath(caps.kv.PYTHON_PATH)
            end
            if type(C.setExtStateValue) == "function" then
                C.setExtStateValue("ffmpegPath", caps.kv.FFMPEG_PATH)
            end
            setDepState("ok")
            return true
        end
    end

    local runtime = M.getRuntimePaths()
    local canRunFfmpeg = C.canRunFfmpeg
    local pythonPath
    if (C.OS or "Windows") == "Windows" then
        pythonPath = resolveWindowsPythonPath(runtime)
    else
        pythonPath = resolveNonWindowsPythonPath(runtime)
    end
    if pythonPath and pythonPath ~= "" and type(C.setPythonPath) == "function" then
        C.setPythonPath(pythonPath)
    end
    local pythonOk = M.isPythonAvailable(pythonPath)
    local ffmpegOk = false
    if type(canRunFfmpeg) == "function" then
        local ffmpegPath = resolveWindowsFfmpegPath(runtime)
        if ffmpegPath and ffmpegPath ~= "" then
            ffmpegOk = canRunFfmpeg(ffmpegPath)
        else
            ffmpegOk = canRunFfmpeg()
        end
        if not ffmpegOk and ffmpegPath and ffmpegPath ~= "" then
            ffmpegOk = canRunCommand(ffmpegPath, " -version", "ffmpeg version", 8000)
        end
    end
    local audioOk = false
    if pythonOk and ffmpegOk then
        audioOk = M.canImportAudioSeparator(pythonPath)
    end

    if pythonOk and ffmpegOk and audioOk then
        setDepState("ok")
        return true
    end

    local runtimeOk, runtimeErrors = M.verifyRuntimeAfterBootstrap()
    if runtimeOk then
        setDepState("ok")
        return true
    end

    if state.state == "prompt_declined" or state.state == "failed" then
        return false
    end
    if type(C.showMessageBox) ~= "function" then
        return false
    end

    local missing = {}
    if not pythonOk then missing[#missing + 1] = "Python runtime (invalid path or not executable)" end
    if not ffmpegOk then missing[#missing + 1] = "FFmpeg" end
    if pythonOk and ffmpegOk and (not audioOk) then missing[#missing + 1] = "audio_separator/onnxruntime runtime" end
    if runtimeErrors and #runtimeErrors > 0 then
        local hasSamplerate = false
        local hasCore = false
        for _, err in ipairs(runtimeErrors) do
            if err == "samplerate_missing" then hasSamplerate = true end
            if err == "stemwerk_core_missing" then hasCore = true end
            if err == "torch_too_new_for_demucs" then
                missing[#missing + 1] = "macOS Torch version is too new for bundled Demucs/audio-separator; run Rebuild venv or Repair"
            end
            if err == "numpy_too_new_for_demucs" then
                missing[#missing + 1] = "NumPy version is too new for bundled Demucs/audio-separator; run Rebuild venv or Repair"
            end
        end
        if hasSamplerate then missing[#missing + 1] = "samplerate runtime" end
        if hasCore then missing[#missing + 1] = "stemwerk_core runtime" end
    end

    local runtime = M.getRuntimePaths()
    local msg =
        "STEMwerk is missing required runtime components:\n\n- " .. table.concat(missing, "\n- ") ..
        "\n\nSTEMwerk can open setup/repair now and create or repair the runtime at:\n" .. tostring(runtime.base) ..
        "\n\nStart setup now?\n\nYou can also run STEMwerk-SETUP.lua manually from REAPER later."

    if state.prompted then
        return false
    end
    state.prompted = true

    local choice = C.showMessageBox(msg, "STEMwerk Setup", 4)
    if choice ~= 6 then
        setDepState("prompt_declined", "user_declined")
        logExec("bootstrap_prompt_declined", -1, msg)
        return false
    end

    if bootstrapActive() then
        setDepState("running", "bootstrap_already_running")
        return false
    end

    setBootstrapActive(true)
    setDepState("running", "bootstrap_running")
    local bootstrapOk = M.runSetup()
    setBootstrapActive(false)

    if not bootstrapOk then
        setDepState("failed", "setup_failed")
        logExec("bootstrap_failed", -1, "setup_failed")
        return false
    end

    local newPython, newSeparator = refreshRuntimeState()
    if type(C.setPythonPath) == "function" then C.setPythonPath(newPython) end
    if type(C.setSeparatorScript) == "function" then C.setSeparatorScript(newSeparator) end

    if type(C.persistPythonPathFallback) == "function" then
        C.persistPythonPathFallback(newPython)
    else
        M.persistPythonPath(newPython)
    end

    local runtimeOk, errors = M.verifyRuntimeAfterBootstrap()
    if not runtimeOk then
        setDepState("failed", table.concat(errors, ","))
        C.showMessageBox(
            "Automatic setup could not fix everything.\n\n" ..
            "Status: " .. tostring(state.detail or "unknown") .. "\n\n" ..
            "You can rerun repair via:\n" ..
            "  STEMwerk-SETUP.lua\n\n" ..
            "Please check again after that.",
            "STEMwerk Setup",
            0
        )
        return false
    end

    setDepState("ok")
    return true
end

return M
