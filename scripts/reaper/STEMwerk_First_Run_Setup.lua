-- @description STEMwerk: First Run Setup
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1
-- @changelog
--   2026-03-15: Added live Linux setup status window and stricter post-bootstrap verification.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function getOS()
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

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local RAW_SCRIPT_DIR = getScriptDir()
local PATH_HELPER = nil
local helperOk, helperMod = pcall(dofile, RAW_SCRIPT_DIR .. "STEMwerk_Path_Helper.lua")
if helperOk and type(helperMod) == "table" then
    PATH_HELPER = helperMod
end
local INSTALL = PATH_HELPER and PATH_HELPER.resolveInstallRoot(RAW_SCRIPT_DIR, { os = OS }) or {
    ok = true,
    root = RAW_SCRIPT_DIR,
    actual = RAW_SCRIPT_DIR,
    scriptsDir = RAW_SCRIPT_DIR,
    canonicalMismatch = false,
    canonical = "",
}

local function warnInstallMismatch()
    if not INSTALL.ok then
        return
    end
    if not INSTALL.canonicalMismatch or INSTALL.canonical == "" then
        return
    end
    msgBox(
        "STEMwerk Setup",
        "STEMwerk is not installed in the canonical REAPER Scripts path.\n\n"
            .. "Preferred:\n" .. tostring(INSTALL.canonical or "(unknown)") .. "\n\n"
            .. "Current runtime install:\n" .. tostring(INSTALL.root or RAW_SCRIPT_DIR) .. "\n\n"
            .. "Setup uses this actual location for bootstrap resolution.",
        0
    )
end

if not INSTALL.ok then
    msgBox(
        "STEMwerk Setup",
        "STEMwerk runtime location could not be resolved.\n\nReinstall STEMwerk and run STEMwerk_First_Run_Setup.lua from REAPER.",
        0
    )
    return
end

local INSTALL_ROOT = INSTALL.root or RAW_SCRIPT_DIR
local SCRIPT_DIR = INSTALL.scriptsDir or RAW_SCRIPT_DIR
warnInstallMismatch()

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

local function exec(cmd, timeoutMs)
    timeoutMs = timeoutMs or 1200000
    if reaper and reaper.ExecProcess then
        local rc, out = reaper.ExecProcess(cmd, timeoutMs)
        return tonumber(rc) or -1, out or ""
    end
    local ok = os.execute(cmd)
    return (ok == true or ok == 0) and 0 or 1, ""
end

local function execCapture(cmd, timeoutMs)
    local rc, out = exec(cmd, timeoutMs or 20000)
    out = out or ""
    if out ~= "" then
        return rc, out
    end
    if OS ~= "Windows" then
        local h = io.popen(cmd .. " 2>&1")
        if h then
            local content = h:read("*a") or ""
            local ok, _, code = h:close()
            if ok == true then
                rc = 0
            elseif type(code) == "number" then
                rc = code
            end
            return rc, content
        end
    end
    return rc, out
end

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function ensureDir(path)
    if not path or path == "" then return false end
    local quoted = quoteArg(path)
    if OS == "Windows" then
        os.execute("mkdir " .. quoted .. " 2>nul")
    else
        os.execute("mkdir -p " .. quoted .. " 2>/dev/null")
    end
    return true
end

local function ensureWritableDir(path)
    if not path or path == "" then return false end
    ensureDir(path)
    local testPath = path .. PATH_SEP .. ".stemwerk_write_test"
    local f = io.open(testPath, "w")
    if not f then return false end
    f:write("ok")
    f:close()
    os.remove(testPath)
    return true
end

local function getHome()
    if OS == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

local function getRuntimeBase()
    local override = reaper and reaper.GetExtState and reaper.GetExtState(EXT_SECTION, "runtimeBase") or ""
    if override ~= "" then
        return override
    end
    local home = getHome()
    local candidates = {}
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        local appData = os.getenv("APPDATA") or ""
        if localAppData ~= "" then
            table.insert(candidates, localAppData .. "\\STEMwerk")
        end
        if appData ~= "" then
            table.insert(candidates, appData .. "\\STEMwerk")
        end
        table.insert(candidates, home .. "\\Documents\\STEMwerk")
    elseif OS == "macOS" then
        table.insert(candidates, "/Users/Shared/STEMwerk")
        table.insert(candidates, home .. "/Library/Application Support/STEMwerk")
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            table.insert(candidates, xdg .. "/STEMwerk")
        end
        table.insert(candidates, home .. "/.local/share/STEMwerk")
        table.insert(candidates, home .. "/.STEMwerk")
    end
    for _, base in ipairs(candidates) do
        if ensureWritableDir(base) then
            return base
        end
    end
    return candidates[1] or (home .. PATH_SEP .. ".STEMwerk")
end

local function getRuntimePaths()
    local base = getRuntimeBase()
    local runtimeRoot = base .. PATH_SEP .. "runtime"
    local runtimeState = runtimeRoot .. PATH_SEP .. "state"
    local venvDir = base .. PATH_SEP .. ".venv"
    return {
        base = base,
        runtimeRoot = runtimeRoot,
        runtimeState = runtimeState,
        venvDir = venvDir,
        venvPython = OS == "Windows" and (venvDir .. "\\Scripts\\python.exe") or (venvDir .. "/bin/python"),
    }
end

local function parseStateFile(path)
    local data = {}
    local f = io.open(path, "r")
    if not f then return data end
    for line in f:lines() do
        local key, value = line:match("^([A-Z0-9_]+)%s*=%s*(.*)$")
        if key and value then
            data[key] = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r", "")
        end
    end
    f:close()
    return data
end

local function setExt(key, value)
    if reaper and reaper.SetExtState then
        reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
    end
end

local function trim(s)
    if s == nil then return "" end
    local t = tostring(s)
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    return t
end

local function stripQuotes(s)
    s = trim(s)
    if s == "" then return "" end
    return (s:match('^"(.*)"$') or s:match("^'(.*)'$") or s):gsub("^%s*", ""):gsub("%s*$", "")
end

local function isAbsolutePath(path)
    if OS == "Windows" then
        return path:match("^[A-Za-z]:[\\/]") ~= nil
    end
    return path:match("^/") ~= nil
end

local function resolvePath(raw)
    local value = stripQuotes(raw)
    if value == "" then return "" end
    if isAbsolutePath(value) then return value end
    if value:find("[/\\]") then
        return getScriptDir() .. value
    end
    return value
end

local function linuxEnvPrefix()
    if OS ~= "Linux" then return "" end
    return "env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES "
end

local function runCommandWithProbe(path, suffix, expectPattern, timeoutMs)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end

    local cmd = quoteArg(path) .. suffix
    if OS ~= "Linux" then
        local rc, out = exec(cmd, timeoutMs or 12000)
        if rc == 0 then
            return true
        end

        local h = io.popen(cmd .. " 2>&1")
        if not h then return false end
        local output = h:read("*a") or ""
        local ok, _, code = h:close()
        local combined = (out or "") .. "\n" .. output
        if expectPattern and combined:find(expectPattern, 1, true) then
            return true
        end
        if expectPattern == nil and ((ok == true) or (code == 0) or combined ~= "") then
            return true
        end
        return false
    end

    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    local combined = (out or "") .. "\n" .. output
    if expectPattern and combined:find(expectPattern, 1, true) then
        return true
    end
    if expectPattern == nil and ((ok == true) or (code == 0) or combined ~= "") then
        return true
    end
    return false
end

local function canRunPython(path)
    path = resolvePath(path)
    return runCommandWithProbe(path, " --version", "Python", 15000)
end

local function canRunFfmpeg(path)
    path = resolvePath(path)
    return runCommandWithProbe(path, " -version", "ffmpeg version", 8000)
end

local function canImportAudioSeparator(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import audio_separator")
    if OS ~= "Linux" then
        local rc = select(1, exec(cmd, 15000))
        return rc == 0
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function canImportStemwerkCore(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import stemwerk_core")
    if OS ~= "Linux" then
        local rc = select(1, exec(cmd, 15000))
        return rc == 0
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function canImportStemwerkCore(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import stemwerk_core")
    if OS ~= "Linux" then
        local rc = select(1, exec(cmd, 15000))
        return rc == 0
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function readTail(path, maxLines)
    local lines = {}
    local max = maxLines or 20
    local f = io.open(path, "r")
    if not f then return lines end
    for line in f:lines() do
        if #lines >= max then
            table.remove(lines, 1)
        end
        lines[#lines + 1] = trim(line)
    end
    f:close()
    return lines
end

local function wrapLine(line, maxLen)
    if #line <= maxLen then return { line } end
    local out = {}
    local s = line
    while #s > maxLen do
        local chunk = s:sub(1, maxLen)
        local cut = chunk:match("^(.*)%s+[%w%p]*$")
        if cut and #cut > 0 then
            out[#out + 1] = cut
            s = s:sub(#cut + 1)
            s = s:gsub("^%s+", "")
        else
            out[#out + 1] = chunk
            s = s:sub(maxLen + 1)
        end
    end
    if s ~= "" then out[#out + 1] = s end
    return out
end

local function probeRuntimeDevices(pythonPath, separatorScript)
    if not pythonPath or pythonPath == "" or not fileExists(pythonPath) then
        return nil, nil, "python_missing"
    end
    if not separatorScript or separatorScript == "" or not fileExists(separatorScript) then
        return nil, nil, "separator_missing"
    end

    local prefix = linuxEnvPrefix()
    local cmd1 = prefix .. quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript) .. " --list-devices-machine"
    local rc1, out1 = execCapture(cmd1, 30000)
    if out1 and out1 ~= "" then
        return out1, rc1, nil
    end

    local cmd2 = prefix .. quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript) .. " --list-devices"
    local rc2, out2 = execCapture(cmd2, 30000)
    if out2 and out2 ~= "" then
        return out2, rc2, nil
    end
    return nil, rc2 or rc1, "device_probe_failed"
end

local function extractEnvJson(deviceOut)
    if not deviceOut then return nil end
    for line in deviceOut:gmatch("[^\r\n]+") do
        if line:match("^STEMWERK_ENV_JSON%s+") then
            return line:gsub("^STEMWERK_ENV_JSON%s+", "")
        end
    end
    return nil
end

local function envJsonValue(envJson, key)
    if not envJson or envJson == "" then return "" end
    local s = envJson:match('"' .. key .. '"%s*:%s*"(.-)"')
    if s ~= nil then return s end
    local b = envJson:match('"' .. key .. '"%s*:%s*(true|false)')
    if b ~= nil then return b end
    local n = envJson:match('"' .. key .. '"%s*:%s*([%d%.%-]+)')
    if n ~= nil then return n end
    local null = envJson:match('"' .. key .. '"%s*:%s*(null)')
    if null ~= nil then return "null" end
    return ""
end

local function collectDeviceNames(deviceOut)
    if not deviceOut then return "" end
    local names = {}
    for line in deviceOut:gmatch("[^\r\n]+") do
        if line:match("^STEMWERK_DEVICE\t") then
            local _, name = line:match("^STEMWERK_DEVICE\t([^\t]*)\t([^\t]*)")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_CUDA_DEVICE\t") then
            local _, name = line:match("^STEMWERK_CUDA_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_DML_DEVICE\t") then
            local _, name = line:match("^STEMWERK_DML_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_MPS_DEVICE\t") then
            local _, name = line:match("^STEMWERK_MPS_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        end
    end
    return table.concat(names, ", ")
end

local function detectBackendFromProbe(deviceOut, envJson)
    local hasCuda = deviceOut and (deviceOut:find("cuda:") or deviceOut:find("STEMWERK_CUDA_DEVICE")) or false
    local hasMps = deviceOut and (deviceOut:find("STEMWERK_MPS_DEVICE") or deviceOut:find("\tmps\t")) or false
    local hasDirectml = deviceOut and (deviceOut:find("directml") or deviceOut:find("STEMWERK_DML_DEVICE")) or false
    local backend = "cpu"
    local reason = ""

    if OS == "macOS" then
        if hasMps then
            backend = "metal"
        else
            reason = "mps_unavailable"
        end
    elseif OS == "Windows" then
        if hasCuda then
            backend = "cuda"
        elseif hasDirectml then
            backend = "directml"
        else
            reason = "no_gpu_detected"
        end
    else
        local hipPresent = envJson
            and envJson:find('"torch_hip"%s*:%s*[^n]')
            and not envJson:find('"torch_hip"%s*:%s*null')
            and not envJson:find('"torch_hip"%s*:%s*""')
        local cudaAvail = envJson and envJson:find('"cuda_available"%s*:%s*true') ~= nil
        local cudaCount = envJson and tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or 0
        local rocmHost = envJson and envJson:find('"rocm_path_exists"%s*:%s*true') ~= nil
        local rocmOk = hipPresent and cudaAvail and cudaCount > 0

        if rocmOk then
            backend = "rocm"
        elseif hasCuda then
            backend = "cuda"
        else
            if rocmHost then
                reason = "rocm_probe_failed"
            else
                reason = "no_gpu_detected"
            end
        end
    end

    if backend == "cpu" and envJson then
        if reason == "" then
            if OS == "Linux" and envJson:find('"cuda_available"%s*:%s*false') then
                reason = "cuda_unavailable"
            elseif OS == "macOS" and envJson:find('"mps_available"%s*:%s*false') then
                reason = "mps_unavailable"
            elseif OS == "Windows" and envJson:find('"directml_possible"%s*:%s*false') then
                reason = "directml_unavailable"
            end
        end
    end

    return backend, reason
end

local function profileForBackend(backend)
    backend = backend or "cpu"
    if OS == "Windows" then
        return "windows-" .. backend
    elseif OS == "macOS" then
        return "mac-" .. backend
    end
    return "linux-" .. backend
end

local function writeCapabilities(path, data, deviceOut)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("CAP_VERSION=1\n")
    f:write("PROFILE=" .. tostring(data.profile or "") .. "\n")
    f:write("BACKEND=" .. tostring(data.backend or "") .. "\n")
    f:write("BACKEND_REASON=" .. tostring(data.backendReason or "") .. "\n")
    if data.backendNote and data.backendNote ~= "" then
        f:write("BACKEND_NOTE=" .. tostring(data.backendNote) .. "\n")
    end
    f:write("PYTHON_PATH=" .. tostring(data.pythonPath or "") .. "\n")
    f:write("FFMPEG_PATH=" .. tostring(data.ffmpegPath or "") .. "\n")
    f:write("RUNTIME_BASE=" .. tostring(data.runtimeBase or "") .. "\n")
    f:write("BOOTSTRAP_STATUS=" .. tostring(data.bootstrapStatus or "") .. "\n")
    f:write("BOOTSTRAP_REASON=" .. tostring(data.bootstrapReason or "") .. "\n")
    f:write("VERIFICATION=" .. tostring(data.verification or "") .. "\n")
    f:write("AUDIO_SEPARATOR=" .. tostring(data.audioSeparator or "") .. "\n")
    f:write("STEMWERK_CORE=" .. tostring(data.stemwerkCore or "") .. "\n")
    f:write("DEVICE_NAMES=" .. tostring(data.deviceNames or "") .. "\n")
    if data.envJson and data.envJson ~= "" then
        f:write("ENV_JSON=" .. tostring(data.envJson) .. "\n")
    end
    if deviceOut and deviceOut ~= "" then
        f:write("DEVICES_OUTPUT_BEGIN\n")
        f:write(deviceOut)
        if deviceOut:sub(-1) ~= "\n" then
            f:write("\n")
        end
        f:write("DEVICES_OUTPUT_END\n")
    end
    f:close()
    return true
end

local function updateBootstrapEnv(path, kv)
    if not path or path == "" or type(kv) ~= "table" then return false end
    local lines = {}
    local seen = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local key = line:match("^([A-Z0-9_]+)=")
            if key and kv[key] ~= nil then
                lines[#lines + 1] = key .. "=" .. tostring(kv[key])
                seen[key] = true
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    for k, v in pairs(kv) do
        if not seen[k] then
            lines[#lines + 1] = k .. "=" .. tostring(v)
        end
    end
    local out = io.open(path, "w")
    if not out then return false end
    for _, line in ipairs(lines) do
        out:write(line .. "\n")
    end
    out:close()
    return true
end

local function showStatusWindow(stateFile, logFile, finalMessage)
    if not gfx then
        if finalMessage then
            msgBox("STEMwerk Setup", finalMessage, finalMessage:find("failed") and 16 or 0)
        end
        return
    end

    local running = true
    local finishedAt = os.time()
    local w, h = 860, 480
    local spinner = { "|", "/", "-", "\\" }
    local idx = 1
    local shownMessage

    gfx.init("STEMwerk Setup", w, h, 0, 150, 120)
    while running do
        local state = parseStateFile(stateFile)
        local lines = readTail(logFile, 16)
        local stateLine = "Status: " .. (state.STATUS and tostring(state.STATUS) or "running")
        local reasonLine = state.STATUS_REASON and ("Reason: " .. tostring(state.STATUS_REASON)) or ""
        local pythonLine = "Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or "")
        local ffmpegLine = "FFmpeg: " .. tostring(state.FFMPEG_PATH or "")
        local spin = spinner[idx]
        idx = (idx % #spinner) + 1

        gfx.set(0, 0, 0, 0)
        gfx.setfont(1, "Arial", 14)
        gfx.x = 20
        gfx.y = 20
        if finalMessage then
            shownMessage = finalMessage
        else
            shownMessage = (state.STATUS == "ok") and "Bootstrap completed." or "Bootstrapping..."
        end
        gfx.drawstr(shownMessage .. " [" .. spin .. "]")
        gfx.y = gfx.y + 28
        gfx.drawstr(stateLine)
        if reasonLine ~= "" then
            gfx.y = gfx.y + 20
            gfx.drawstr(reasonLine)
        end
        gfx.y = gfx.y + 24
        gfx.drawstr(pythonLine)
        gfx.y = gfx.y + 20
        gfx.drawstr(ffmpegLine)
        gfx.y = gfx.y + 24
        gfx.drawstr("Log: " .. tostring(logFile))
        gfx.y = gfx.y + 20
        gfx.drawstr("Recent log lines:")
        gfx.y = gfx.y + 18

        for _, line in ipairs(lines) do
            local wrapped = wrapLine(line, 106)
            for _, wl in ipairs(wrapped) do
                gfx.drawstr(wl)
                gfx.y = gfx.y + 16
            end
        end

        if finalMessage and os.time() - finishedAt > 0 then
            gfx.y = h - 30
            gfx.drawstr("Press Esc or close this window to continue.")
        end

        gfx.update()
        local key = gfx.getchar()
        if finalMessage then
            if key == 27 or key == -1 then
                break
            end
        else
            if state.STATUS and state.STATUS ~= "" and state.STATUS ~= "running" then
                running = false
                if finalMessage == nil then
                    os.execute("sleep 0.25")
                end
            end
        end
        os.execute("sleep 0.15")
    end

    if finalMessage then
        while true do
            local key = gfx.getchar()
            if key == 27 or key == -1 then
                break
            end
            os.execute("sleep 0.05")
        end
    end
    gfx.quit()
end

local function waitForBootstrapState(stateFile, logFile, runtimeState)
    local pidFile = runtimeState .. PATH_SEP .. "bootstrap.pid"
    local started = os.time()
    local status
    local done = false
    while not done do
        status = parseStateFile(stateFile)
        if status.STATUS == "ok" or status.STATUS == "missing_python" or status.STATUS == "missing_ffmpeg" or status.STATUS == "deps_failed" or status.STATUS == "venv_failed" then
            done = true
            break
        end
        local f = io.open(pidFile, "r")
        local pid = nil
        if f then
            local pidText = trim(f:read("*a") or "")
            pid = tonumber(pidText)
            f:close()
        end
        if pid then
            local ok = os.execute("kill -0 " .. pid .. " >/dev/null 2>&1")
            if not (ok == true or ok == 0) then
                done = true
                break
            end
        end
        if os.time() - started > 1800 then
            done = true
            break
        end
        os.execute("sleep 0.2")
    end
    status = parseStateFile(stateFile)
    local final = (status.STATUS == "ok") or (status.STATUS == nil and status.PYTHON_PATH ~= nil and status.FFMPEG_PATH ~= nil)
    showStatusWindow(stateFile, logFile, final and "Bootstrap completed." or "Bootstrap failed.")
    return final, status
end

local function runBootstrap(runtime)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.log"
    ensureDir(runtime.runtimeState)

    local scriptPath = PATH_HELPER.getBootstrapScriptPath(INSTALL_ROOT, OS, PATH_SEP)
    local cmd
    if OS == "Windows" then
        cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File '
            .. quoteArg(scriptPath)
            .. " -RuntimeBase " .. quoteArg(runtime.base)
            .. " -StateFile " .. quoteArg(stateFile)
            .. " -LogFile " .. quoteArg(logFile)
    elseif OS == "macOS" then
        cmd = '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
    else
        cmd = '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
    end

    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    if not fileExists(scriptPath) then
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "failed",
            REASON = "missing_bootstrap",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        msgBox("STEMwerk Setup", "Bootstrap script missing:\n\n" .. tostring(scriptPath), 0)
        return false, stateFile, logFile
    end

    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "running",
        REASON = "launching",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })

    if OS == "Linux" then
        local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
        local background = cmd .. " </dev/null >" .. quoteArg(logFile) .. " 2>&1 & echo $! > " .. quoteArg(pidFile)
        local launchRc = select(1, exec(background, 1800000))
        if launchRc ~= 0 then
            PATH_HELPER.writeEnvFile(guardPath, {
                STATUS = "failed",
                REASON = "launch_failed",
                SCRIPT_PATH = scriptPath,
                UPDATED_AT = os.time(),
            })
            return false, stateFile, logFile
        end
        local final, status = waitForBootstrapState(stateFile, logFile, runtime.runtimeState)
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = final and "ok" or "failed",
            REASON = final and "completed" or "bootstrap_failed",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        return final, stateFile, logFile, status
    end

    local rc = select(1, exec(cmd, 1800000))
    if rc == 0 then
        local state = parseStateFile(stateFile)
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "ok",
            REASON = "completed",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        return true, stateFile, logFile, state
    end
    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "failed",
        REASON = "launch_failed",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })
    return false, stateFile, logFile, parseStateFile(stateFile)
end

local function verifyRuntimePaths(state)
    state = state or {}
    local resolved = {
        pythonPath = resolvePath(state.PYTHON_PATH or state.VENV_PYTHON or ""),
        ffmpegPath = resolvePath(state.FFMPEG_PATH or ""),
    }
    local errors = {}
    local pythonOk = false
    local ffmpegOk = false
    local audioOk = false

    if resolved.pythonPath == "" then
        errors[#errors + 1] = "python_missing"
    else
        if canRunPython(resolved.pythonPath) then
            pythonOk = true
            setExt("pythonPath", resolved.pythonPath)
        else
            errors[#errors + 1] = "python_unusable"
        end
    end

    if resolved.ffmpegPath == "" then
        errors[#errors + 1] = "ffmpeg_missing"
    else
        if canRunFfmpeg(resolved.ffmpegPath) then
            ffmpegOk = true
            setExt("ffmpegPath", resolved.ffmpegPath)
        else
            errors[#errors + 1] = "ffmpeg_unusable"
        end
    end

    if pythonOk and ffmpegOk and not canImportAudioSeparator(resolved.pythonPath) then
        errors[#errors + 1] = "audio_separator_missing"
        audioOk = false
    else
        audioOk = pythonOk and ffmpegOk
    end

    if pythonOk and ffmpegOk and not canImportStemwerkCore(resolved.pythonPath) then
        errors[#errors + 1] = "stemwerk_core_missing"
    end

    return {
        pythonPath = resolved.pythonPath,
        ffmpegPath = resolved.ffmpegPath,
        pythonOk = pythonOk,
        ffmpegOk = ffmpegOk,
        audioOk = audioOk,
        errors = errors,
    }
end

local function performPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    local state = bootstrapState or parseStateFile(stateFile)

    if state.PYTHON_PATH and state.PYTHON_PATH ~= "" then
        setExt("pythonPath", state.PYTHON_PATH)
    elseif state.VENV_PYTHON and state.VENV_PYTHON ~= "" then
        setExt("pythonPath", state.VENV_PYTHON)
    end
    if state.FFMPEG_PATH and state.FFMPEG_PATH ~= "" then
        setExt("ffmpegPath", state.FFMPEG_PATH)
    end

    local verification = verifyRuntimePaths(state)
    local errors = verification.errors
    local finalMessage = {}
    local failureClass = nil

    local deviceOut, probeRc, probeErr = probeRuntimeDevices(verification.pythonPath, separatorScript)
    local envJson = extractEnvJson(deviceOut or "")
    local deviceNames = collectDeviceNames(deviceOut or "")
    if OS == "Linux" then
        local torchVer = envJsonValue(envJson, "torch")
        local hipVer = envJsonValue(envJson, "torch_hip")
        local cudaAvail = envJsonValue(envJson, "cuda_available")
        local cudaCount = envJsonValue(envJson, "cuda_count")
        local lf = io.open(logFile, "a")
        if lf then
            lf:write(
                "CAP_PROBE torch=" .. tostring(torchVer)
                .. " hip=" .. tostring(hipVer)
                .. " cuda_available=" .. tostring(cudaAvail)
                .. " cuda_count=" .. tostring(cudaCount)
                .. " devices=" .. tostring(deviceNames)
                .. "\n"
            )
            lf:close()
        end
    end
    local backend, backendReason = detectBackendFromProbe(deviceOut, envJson)
    if probeErr and probeErr ~= "" then
        backendReason = probeErr
    end
    if state.BACKEND_REASON and state.BACKEND_REASON ~= "" then
        if backendReason ~= "" then
            backendReason = backendReason .. "; " .. state.BACKEND_REASON
        else
            backendReason = state.BACKEND_REASON
        end
    end
    local backendNote = state.BACKEND_NOTE and tostring(state.BACKEND_NOTE) or ""
    local profile = profileForBackend(backend)

    local function hasError(key)
        for _, e in ipairs(errors or {}) do
            if e == key then return true end
        end
        return false
    end
    local audioStatus = hasError("audio_separator_missing") and "missing" or "ok"
    local coreStatus = hasError("stemwerk_core_missing") and "missing" or "ok"
    local verificationStatus = (bootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) and "ok" or "failed"

    ensureDir(runtime.runtimeState)
    local capPath = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local wroteCaps = writeCapabilities(capPath, {
        profile = profile,
        backend = backend,
        backendReason = backendReason,
        backendNote = backendNote,
        pythonPath = verification.pythonPath,
        ffmpegPath = verification.ffmpegPath,
        runtimeBase = runtime.base,
        bootstrapStatus = state.STATUS or "",
        bootstrapReason = state.STATUS_REASON or "",
        verification = verificationStatus,
        audioSeparator = audioStatus,
        stemwerkCore = coreStatus,
        deviceNames = deviceNames,
        envJson = envJson,
    }, deviceOut)
    if not wroteCaps then
        local lf = io.open(logFile, "a")
        if lf then
            lf:write("WARN: failed to write capabilities file: " .. tostring(capPath) .. "\n")
            lf:close()
        end
    end
    local syncKv = {
        PROFILE = profile or "",
        BACKEND = backend or "",
        BACKEND_REASON = backendReason or "",
        BACKEND_NOTE = backendNote or "",
    }
    if verificationStatus == "ok" then
        syncKv.STATUS = "ok"
        syncKv.STATUS_REASON = ""
    end
    local synced = updateBootstrapEnv(stateFile, syncKv)
    if not synced then
        local lf = io.open(logFile, "a")
        if lf then
            lf:write("WARN: failed to sync bootstrap.env with capability profile/backend\n")
            lf:close()
        end
    end

    if (bootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) then
        finalMessage[#finalMessage + 1] = "Setup complete."
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Python path: " .. tostring(verification.pythonPath)
        finalMessage[#finalMessage + 1] = "FFmpeg path: " .. tostring(verification.ffmpegPath)
        finalMessage[#finalMessage + 1] = "Profile: " .. tostring(profile)
        finalMessage[#finalMessage + 1] = "Backend: " .. tostring(backend)
        if backendReason and backendReason ~= "" then
            finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReason)
        end
        if backendNote and backendNote ~= "" then
            finalMessage[#finalMessage + 1] = "Note: " .. tostring(backendNote)
        end
        if deviceNames and deviceNames ~= "" then
            finalMessage[#finalMessage + 1] = "Devices: " .. tostring(deviceNames)
        end
        finalMessage[#finalMessage + 1] = "Capabilities: " .. tostring(capPath)
        finalMessage[#finalMessage + 1] = "Log: " .. tostring(logFile)
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "You can start STEMwerk again."
        return { success = true, finalMessage = finalMessage }
    end

    if state.STATUS and state.STATUS ~= "ok" then
        failureClass = "bootstrap_failed"
    else
        failureClass = "verification_failed"
    end

    finalMessage[#finalMessage + 1] = "Setup was not completely successful."
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "Status: " .. tostring(state.STATUS or "unknown")
    if state.STATUS_REASON and state.STATUS_REASON ~= "" then
        finalMessage[#finalMessage + 1] = "Reason: " .. tostring(state.STATUS_REASON)
    end
    finalMessage[#finalMessage + 1] = "Failure: " .. failureClass
    finalMessage[#finalMessage + 1] = "Checks: " .. ( (#errors > 0) and table.concat(errors, ", ") or "none")
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "Python path: " .. tostring(verification.pythonPath)
    finalMessage[#finalMessage + 1] = "FFmpeg path: " .. tostring(verification.ffmpegPath)
    finalMessage[#finalMessage + 1] = "Profile: " .. tostring(profile)
    finalMessage[#finalMessage + 1] = "Backend: " .. tostring(backend)
    if backendReason and backendReason ~= "" then
        finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReason)
    end
    if backendNote and backendNote ~= "" then
        finalMessage[#finalMessage + 1] = "Note: " .. tostring(backendNote)
    end
    if deviceNames and deviceNames ~= "" then
        finalMessage[#finalMessage + 1] = "Devices: " .. tostring(deviceNames)
    end
    finalMessage[#finalMessage + 1] = "Capabilities: " .. tostring(capPath)
    finalMessage[#finalMessage + 1] = "Log: " .. tostring(logFile)
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "You can run setup again or fix paths manually."
    return { success = false, finalMessage = finalMessage }
end

local LINUX_SETUP = nil

local function linuxPidAlive(pidFile)
    local f = io.open(pidFile, "r")
    if not f then return false, nil end
    local pidText = trim(f:read("*a") or "")
    local pid = tonumber(pidText)
    f:close()
    if not pid then return false, nil end
    local ok = os.execute("kill -0 " .. pid .. " >/dev/null 2>&1")
    return (ok == true or ok == 0), pid
end

local function tryExec(cmd)
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

local function copyToClipboard(text)
    if reaper and reaper.CF_SetClipboard then
        reaper.CF_SetClipboard(text or "")
        return true
    end
    if OS == "Linux" then
        local tmp = os.tmpname()
        local f = io.open(tmp, "w")
        if f then
            f:write(text or "")
            f:close()
        end
        local ok = tryExec("wl-copy < " .. quoteArg(tmp) .. " 2>/dev/null")
        if not ok then
            ok = tryExec("xclip -selection clipboard < " .. quoteArg(tmp) .. " 2>/dev/null")
        end
        os.remove(tmp)
        return ok
    end
    return false
end

local function openPath(path)
    if not path or path == "" then return end
    if reaper and reaper.CF_ShellExecute then
        reaper.CF_ShellExecute(path)
        return
    end
    if OS == "Linux" then
        tryExec("xdg-open " .. quoteArg(path) .. " >/dev/null 2>&1 &")
    end
end

local function drawButton(label, x, y, w, h)
    gfx.set(0.2, 0.2, 0.2, 1)
    gfx.rect(x, y, w, h, 1)
    gfx.set(1, 1, 1, 1)
    gfx.rect(x, y, w, h, 0)
    gfx.x = x + 8
    gfx.y = y + 6
    gfx.drawstr(label)
end

local function isMouseIn(x, y, w, h)
    return gfx.mouse_x >= x and gfx.mouse_x <= (x + w) and gfx.mouse_y >= y and gfx.mouse_y <= (y + h)
end

local function linuxDrawStatus(state, logLines, pidAlive, pid)
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    gfx.setfont(1, "Arial", 22)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("STEMwerk Setup [LINUX LIVE TEST]")
    y = y + 30

    gfx.setfont(1, "Arial", 16)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Linux live setup UI active")
    y = y + 22
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("UI loop running")
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Phase: " .. ((state.STATUS == "running" or state.STATUS == "" or not state.STATUS) and "Bootstrapping" or "Finalizing"))
    y = y + 20

    gfx.setfont(1, "Arial", 14)
    local statusLine = "Status: " .. tostring(state.STATUS or "running")
    if LINUX_SETUP and LINUX_SETUP.spinner then
        statusLine = statusLine .. " [" .. LINUX_SETUP.spinner .. "]"
    end
    gfx.x = 18
    gfx.y = y
    gfx.drawstr(statusLine)
    y = y + 18

    if state.STATUS_REASON and state.STATUS_REASON ~= "" then
        gfx.x = 18
        gfx.y = y
        gfx.drawstr("Reason: " .. tostring(state.STATUS_REASON))
        y = y + 18
    end

    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or ""))
    y = y + 18
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("FFmpeg: " .. tostring(state.FFMPEG_PATH or ""))
    y = y + 18
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("PID: " .. tostring(pid or "") .. " (alive: " .. tostring(pidAlive) .. ")")
    y = y + 18
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Log: " .. tostring(LINUX_SETUP.logFile))
    y = y + 18
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Recent log lines (newest last):")
    y = y + 18

    gfx.setfont(1, "Courier New", 12)
    for _, line in ipairs(logLines) do
        local wrapped = wrapLine(line, 140)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 14
        end
    end
end

local function linuxDrawFinal(finalLines, finalSuccess)
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    gfx.setfont(1, "Arial", 22)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("STEMwerk Setup [LINUX LIVE TEST]")
    y = y + 30
    gfx.setfont(1, "Arial", 16)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Linux live setup UI active")
    y = y + 22
    gfx.setfont(1, "Arial Bold", 26)
    gfx.x = 18
    gfx.y = y
    if finalSuccess then
        gfx.set(0.2, 0.9, 0.2, 1)
        gfx.drawstr("Setup complete.")
    else
        gfx.set(1.0, 0.4, 0.1, 1)
        gfx.drawstr("Setup was not completely successful.")
    end
    gfx.set(1, 1, 1, 1)
    y = y + 32

    gfx.setfont(1, "Arial", 15)
    local startIdx = 1
    if finalSuccess and finalLines and finalLines[1] == "Setup complete." then
        startIdx = 2
    elseif (not finalSuccess) and finalLines and finalLines[1] == "Setup was not completely successful." then
        startIdx = 2
    end
    for i = startIdx, #(finalLines or {}) do
        local line = finalLines[i]
        local wrapped = wrapLine(line, 140)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end

    gfx.setfont(1, "Arial", 13)
    gfx.x = 18
    gfx.y = h - 28
    gfx.drawstr("Press Esc or close this window to continue.")

    if LINUX_SETUP then
        local btnY = h - 64
        local btnW = 200
        local btnH = 26
        local gap = 12
        local x = 18
        LINUX_SETUP.buttons = {
            { label = "Copy Summary", x = x, y = btnY, w = btnW, h = btnH, action = "copy_summary" },
            { label = "Copy Log Path", x = x + (btnW + gap), y = btnY, w = btnW, h = btnH, action = "copy_log" },
            { label = "Copy Capabilities", x = x + 2 * (btnW + gap), y = btnY, w = btnW, h = btnH, action = "copy_cap" },
        }
        local btnY2 = btnY - (btnH + 8)
        LINUX_SETUP.buttons[#LINUX_SETUP.buttons + 1] = { label = "Open Log", x = x, y = btnY2, w = btnW, h = btnH, action = "open_log" }
        LINUX_SETUP.buttons[#LINUX_SETUP.buttons + 1] = { label = "Open Capabilities", x = x + (btnW + gap), y = btnY2, w = btnW, h = btnH, action = "open_cap" }

        gfx.setfont(1, "Arial", 13)
        for _, b in ipairs(LINUX_SETUP.buttons) do
            drawButton(b.label, b.x, b.y, b.w, b.h)
        end
    end
end

local function linuxSetupTick()
    if not LINUX_SETUP then return end
    if not gfx then return end

    local state = parseStateFile(LINUX_SETUP.stateFile)
    local logLines = readTail(LINUX_SETUP.logFile, 32)
    local pidAlive, pid = linuxPidAlive(LINUX_SETUP.pidFile)
    if pidAlive then
        LINUX_SETUP.pidSeen = true
    end

    local spinner = { "|", "/", "-", "\\" }
    local idx = (LINUX_SETUP.spinnerIndex or 1)
    LINUX_SETUP.spinner = spinner[idx]
    LINUX_SETUP.spinnerIndex = (idx % #spinner) + 1

    if not LINUX_SETUP.finalized then
        local status = state.STATUS or ""
        if status ~= "" and status ~= "running" then
            local result = performPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
            LINUX_SETUP.finalized = true
            LINUX_SETUP.finalMessage = result.finalMessage
            LINUX_SETUP.finalSuccess = result.success
            LINUX_SETUP.summaryText = table.concat(result.finalMessage or {}, "\n")
        elseif not pidAlive and (status == "" or status == "running") then
            local elapsed = os.time() - (LINUX_SETUP.startedAt or os.time())
            if LINUX_SETUP.pidSeen or elapsed >= 5 then
                local result = performPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
                LINUX_SETUP.finalized = true
                LINUX_SETUP.finalMessage = result.finalMessage
                LINUX_SETUP.finalSuccess = result.success
                LINUX_SETUP.summaryText = table.concat(result.finalMessage or {}, "\n")
            end
        end
    end

    if LINUX_SETUP.finalized then
        linuxDrawFinal(LINUX_SETUP.finalMessage, LINUX_SETUP.finalSuccess)
    else
        linuxDrawStatus(state, logLines, pidAlive, pid)
    end

    gfx.update()
    if LINUX_SETUP and LINUX_SETUP.finalized and LINUX_SETUP.buttons then
        local cap = gfx.mouse_cap
        local last = LINUX_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        LINUX_SETUP.lastMouseCap = cap
        if clicked then
            for _, b in ipairs(LINUX_SETUP.buttons) do
                if isMouseIn(b.x, b.y, b.w, b.h) then
                    if b.action == "copy_summary" then
                        copyToClipboard(LINUX_SETUP.summaryText or "")
                    elseif b.action == "copy_log" then
                        copyToClipboard(LINUX_SETUP.logFile or "")
                    elseif b.action == "copy_cap" then
                        copyToClipboard(LINUX_SETUP.capFile or "")
                    elseif b.action == "open_log" then
                        openPath(LINUX_SETUP.logFile)
                    elseif b.action == "open_cap" then
                        openPath(LINUX_SETUP.capFile)
                    end
                    break
                end
            end
        end
    end
    local key = gfx.getchar()
    if key == -1 or (LINUX_SETUP.finalized and key == 27) then
        gfx.quit()
        LINUX_SETUP = nil
        return
    end
    reaper.defer(linuxSetupTick)
end

local function startLinuxSetup(runtime, separatorScript)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.log"
    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    ensureDir(runtime.runtimeState)

    os.remove(stateFile)
    os.remove(capFile)
    os.remove(pidFile)
    local lf = io.open(logFile, "w")
    if lf then
        lf:write("Setup run started (Linux)\n")
        lf:close()
    end
    local sf = io.open(stateFile, "w")
    if sf then
        sf:write("STATUS=running\n")
        sf:write("STATUS_REASON=\n")
        sf:close()
    end

    local scriptPath = PATH_HELPER.getBootstrapScriptPath(INSTALL_ROOT, OS, PATH_SEP)
    local launcherPath = PATH_HELPER.getBootstrapLauncherPath(INSTALL_ROOT, OS, PATH_SEP)
    if not fileExists(scriptPath) then
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "failed",
            REASON = "missing_bootstrap",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        msgBox("STEMwerk Setup", "Bootstrap script missing:\n\n" .. tostring(scriptPath), 0)
        return
    end

    local envPrefix = linuxEnvPrefix()
    local cmd
    if fileExists(launcherPath) then
        cmd = envPrefix .. '/bin/sh ' .. quoteArg(launcherPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
            .. " --pid-file " .. quoteArg(pidFile)
            .. " --bootstrap-script " .. quoteArg(scriptPath)
    else
        cmd = envPrefix .. '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
            .. " </dev/null >" .. quoteArg(logFile) .. " 2>&1 & echo $! > " .. quoteArg(pidFile)
    end

    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "running",
        REASON = "launching",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })
    exec(cmd, 20000)
    gfx.init("STEMwerk Setup [LINUX LIVE TEST]", 1100, 760, 0, 120, 80)
    LINUX_SETUP = {
        runtime = runtime,
        separatorScript = separatorScript,
        stateFile = stateFile,
        logFile = logFile,
        pidFile = pidFile,
        capFile = capFile,
        spinnerIndex = 1,
        finalized = false,
        finalMessage = nil,
        pidSeen = false,
        startedAt = os.time(),
        finalSuccess = false,
        summaryText = "",
        lastMouseCap = 0,
    }
    reaper.defer(linuxSetupTick)
end

local function main()
    local runtime = getRuntimePaths()
    setExt("runtimeBase", runtime.base)
    local separatorScript = SCRIPT_DIR .. "audio_separator_process.py"
    if fileExists(separatorScript) then
        setExt("separatorScript", separatorScript)
    end

    local intro =
        "Run this setup once in REAPER before using STEMwerk.lua.\n\n"
        .. "STEMwerk will check and repair components if needed:\n\n"
        .. "- Python runtime\n"
        .. "- FFmpeg\n"
        .. "- STEMwerk venv in:\n  " .. runtime.base .. "\n\n"
        .. "This may download tools. Continue?"
    local ok = (msgBox("STEMwerk Setup", intro, 4) == 6)
    if not ok then return end

    if OS == "Linux" then
        startLinuxSetup(runtime, separatorScript)
        return
    end

    local bootstrapSuccess, stateFile, logFile, bootstrapState = runBootstrap(runtime)
    local result = performPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    showStatusWindow(stateFile, logFile, table.concat(result.finalMessage, "\n"))
end

main()
