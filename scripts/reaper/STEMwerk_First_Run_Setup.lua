-- @description STEMwerk: First Run Setup (internal)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.1.1
-- @changelog
--   2026-03-15: Added live Linux setup status window and stricter post-bootstrap verification.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"
local BOOTSTRAP_GUARD_STALE_SECONDS = 600
local BOOTSTRAP_GUARD_STARTUP_GRACE_SECONDS = 8

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function openActionList()
    if reaper and reaper.Main_OnCommand then
        reaper.Main_OnCommand(40605, 0)
        return true
    end
    msgBox(
        "STEMwerk Setup",
        "Open the REAPER Action List via: Actions -> Show action list",
        0
    )
    return false
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
local linuxEnvPrefix
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
    if OS == "Windows" then
        local wrapped = 'cmd.exe /d /c ' .. quoteArg(cmd .. ' 2>&1')
        local rc2, out2 = exec(wrapped, timeoutMs or 20000)
        out2 = out2 or ""
        if out2 ~= "" then
            return rc2, out2
        end
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

local function probeOutputHasUsefulDevices(out)
    if not out or out == "" then return false end
    if out:find("STEMWERK_CUDA_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_DML_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_MPS_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tcuda:", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tdirectml", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tmps", 1, true) then return true end
    if out:match('"cuda_available"%s*:%s*true') then return true end
    if out:match('"cuda_count"%s*:%s*[1-9]%d*') then return true end
    if out:match('"directml_possible"%s*:%s*true') then return true end
    if out:match('"mps_available"%s*:%s*true') then return true end
    return false
end

local fileExists

local function directRuntimeDeviceProbe(pythonPath)
    if not pythonPath or pythonPath == "" or not fileExists(pythonPath) then
        return nil, nil
    end

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
    print(f'STEMWERK_CUDA_DEVICE\tcuda:{i}\t{n}')
if env.get('mps_available'):
    print('STEMWERK_MPS_DEVICE\tmps\tApple MPS')
if env.get('directml_possible'):
    try:
        import torch_directml
        c = torch_directml.device_count()
        for i in range(c):
            print(f'STEMWERK_DML_DEVICE\tdirectml:{i}\tDirectML GPU {i}')
        if c == 1:
            print('STEMWERK_DML_ALIAS\tdirectml\tdirectml:0')
    except Exception:
        pass
]]

    local prefix = linuxEnvPrefix()
    local cmd = prefix .. quoteArg(pythonPath) .. " -c " .. quoteArg(py)
    local rc, out = execCapture(cmd, 30000)
    out = out or ""
    if out ~= "" then
        return out, rc
    end
    return nil, rc
end

fileExists = function(path)
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
        if localAppData ~= "" then
            table.insert(candidates, localAppData .. "\\STEMwerk")
        end
    elseif OS == "macOS" then
        table.insert(candidates, home .. "/Library/Application Support/STEMwerk")
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            table.insert(candidates, xdg .. "/STEMwerk")
        end
        table.insert(candidates, home .. "/.local/share/STEMwerk")
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
    local runtimeRoot = base
    local runtimeState = base .. PATH_SEP .. "state"
    local runtimeLogs = base .. PATH_SEP .. "logs"
    local runtimeCache = base .. PATH_SEP .. "cache"
    local venvDir = base .. PATH_SEP .. ".venv"
    return {
        base = base,
        runtimeRoot = runtimeRoot,
        runtimeState = runtimeState,
        runtimeLogs = runtimeLogs,
        runtimeCache = runtimeCache,
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

local function getExt(key)
    if reaper and reaper.GetExtState then
        return tostring(reaper.GetExtState(EXT_SECTION, key) or "")
    end
    return ""
end

local function trim(s)
    if s == nil then return "" end
    local t = tostring(s)
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    return t
end

local function prettyBackendReason(reason)
    if not reason or reason == "" then return "" end
    local parts = {}
    local seen = {}
    for raw in tostring(reason):gmatch("[^;]+") do
        local part = trim(raw)
        local lower = part:lower()
        if lower == "device_probe_failed" then
            part = "No compatible GPU detected; using CPU"
        elseif lower == "backend_install_failed" then
            part = "Backend install failed; using CPU"
        elseif lower == "backend_force_cpu" then
            part = "CPU fallback forced"
        elseif lower == "bootstrap_cuda_confirmed" then
            part = "CUDA runtime confirmed by installer"
        elseif lower == "bootstrap_directml_confirmed" then
            part = "DirectML runtime confirmed by installer"
        end
        local key = part:lower()
        if key ~= "" and not seen[key] then
            seen[key] = true
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "; ")
end

local function formatStepStatus(state)
    local stepIndex = trim(state.STEP_INDEX or "")
    local stepTotal = trim(state.STEP_TOTAL or "")
    local stepLabel = trim(state.STEP_LABEL or "")
    if stepIndex == "" and stepTotal == "" and stepLabel == "" then return "" end

    local prefix = ""
    if stepIndex ~= "" and stepTotal ~= "" then
        prefix = "Step " .. stepIndex .. "/" .. stepTotal
    elseif stepIndex ~= "" then
        prefix = "Step " .. stepIndex
    end

    if prefix ~= "" and stepLabel ~= "" then
        return prefix .. ": " .. stepLabel
    end
    if prefix ~= "" then return prefix end
    return stepLabel
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

linuxEnvPrefix = function()
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

local function drawStemwerkTitleWindows(y, fontSize)
    local x = 18
    local letters = { "S", "T", "E", "M" }
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 150 },
    }
    gfx.setfont(1, "Arial", fontSize)
    local xPos = x
    for i = 1, #letters do
        local c = colors[i]
        gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
        gfx.x = xPos
        gfx.y = y
        gfx.drawstr(letters[i])
        xPos = xPos + gfx.measurestr(letters[i])
    end
    gfx.set(1, 1, 1, 1)
    gfx.x = xPos
    gfx.y = y
    gfx.drawstr("werk Setup [Windows]")
end

local function drawStemwerkInline(x, y, fontSize, prefix, suffix)
    local letters = { "S", "T", "E", "M" }
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 150 },
    }
    gfx.setfont(1, "Arial", fontSize)
    gfx.set(1, 1, 1, 1)
    gfx.x = x
    gfx.y = y
    if prefix and prefix ~= "" then
        gfx.drawstr(prefix)
        x = x + gfx.measurestr(prefix)
    end
    for i = 1, #letters do
        local c = colors[i]
        gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
        gfx.x = x
        gfx.y = y
        gfx.drawstr(letters[i])
        x = x + gfx.measurestr(letters[i])
    end
    gfx.set(1, 1, 1, 1)
    if suffix and suffix ~= "" then
        gfx.x = x
        gfx.y = y
        gfx.drawstr(suffix)
    end
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
    if probeOutputHasUsefulDevices(out1) then
        return out1, rc1, nil
    end

    local cmd2 = prefix .. quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript) .. " --list-devices"
    local rc2, out2 = execCapture(cmd2, 30000)
    if probeOutputHasUsefulDevices(out2) then
        return out2, rc2, nil
    end

    local out3, rc3 = directRuntimeDeviceProbe(pythonPath)
    if out3 and out3 ~= "" then
        return out3, rc3, nil
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
    local cudaAvail = envJson and envJson:find('"cuda_available"%s*:%s*true') ~= nil
    local cudaCount = envJson and tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or 0
    local hasCuda = deviceOut and (
        deviceOut:find("cuda:")
        or deviceOut:find("STEMWERK_CUDA_DEVICE")
        or deviceOut:find("STEMWERK_TORCH_GPU")
        or deviceOut:find("STEMWERK_SELECTED_DEVICE\tcuda:")
    ) or false
    local hasMps = deviceOut and (deviceOut:find("STEMWERK_MPS_DEVICE") or deviceOut:find("\tmps\t")) or false
    local directmlPossible = envJson and envJson:find('"directml_possible"%s*:%s*true') ~= nil
    local hasDirectml = deviceOut and (
        deviceOut:find("directml")
        or deviceOut:find("STEMWERK_DML_DEVICE")
        or deviceOut:find("STEMWERK_SELECTED_DEVICE\tdirectml")
    ) or false
    local backend = "cpu"
    local reason = ""

    if not hasCuda and cudaAvail and cudaCount > 0 then
        hasCuda = true
    end

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
            elseif OS == "Windows" and directmlPossible == false then
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

local readBootstrapPid
local writeBootstrapGuard
local isProcessAlive
local safePerformPostBootstrap

local function psSingleQuote(value)
    local quoted = tostring(value or "")
    quoted = quoted:gsub("'", "''")
    return "'" .. quoted .. "'"
end

local function readBootstrapGuard(path)
    if not PATH_HELPER or not path or path == "" then
        return {}
    end
    local ok, data = pcall(PATH_HELPER.readEnvFile, path)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function inspectBootstrapGuard(guardPath, pidFile)
    local guard = readBootstrapGuard(guardPath)
    if guard.STATUS ~= "running" then
        return "idle", guard, nil, false
    end

    local pid = readBootstrapPid(pidFile)
    if not pid and guard.PID and guard.PID ~= "" then
        pid = tonumber(guard.PID) or tonumber(trim(guard.PID))
    end
    local pidAlive = pid and isProcessAlive(pid) or false
    if pid and pidAlive then
        return "running", guard, pid, true
    end
    if pid and not pidAlive then
        return "stale", guard, pid, false
    end

    local updatedAt = tonumber(guard.UPDATED_AT) or 0
    local age = updatedAt > 0 and (os.time() - updatedAt) or (BOOTSTRAP_GUARD_STALE_SECONDS + 1)
    if age <= BOOTSTRAP_GUARD_STARTUP_GRACE_SECONDS then
        return "starting", guard, pid, false
    end

    return "stale", guard, pid, false
end

local function isBootstrapBusy(guardPath, pidFile)
    local state, guard, pid = inspectBootstrapGuard(guardPath, pidFile)
    if state == "running" or state == "starting" then
        return true, tostring(guard.SCRIPT_PATH or ""), pid
    end
    if state == "stale" then
        return false, tostring(guard.SCRIPT_PATH or ""), pid, "stale"
    end
    return false, "", nil, "idle"
end

local function recoverStaleBootstrapGuard(guardPath, pidFile)
    local state, guard = inspectBootstrapGuard(guardPath, pidFile)
    if state ~= "stale" then
        return false
    end
    writeBootstrapGuard(
        guardPath,
        "failed",
        "stale_bootstrap_run",
        tostring(guard.SCRIPT_PATH or "")
    )
    return true
end

local function isWindowsProcessAlive(pid)
    if not pid then
        return false
    end
    local cmd = "tasklist /FI " .. quoteArg("PID eq " .. tostring(pid)) .. " /NH /FO CSV 2>nul"
    local h = io.popen(cmd)
    if not h then
        return false
    end
    local output = h:read("*a") or ""
    h:close()
    return output:find("," .. tostring(pid) .. ",", 1, true) ~= nil
        or output:find(',"' .. tostring(pid) .. '",', 1, true) ~= nil
end

isProcessAlive = function(pid)
    if OS == "Windows" then
        return isWindowsProcessAlive(pid)
    end
    local ok = os.execute("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1")
    return (ok == true or ok == 0)
end

readBootstrapPid = function(pidFile)
    local f = io.open(pidFile, "r")
    if not f then
        return nil
    end
    local pidText = trim(f:read("*a") or "")
    f:close()
    local pid = tonumber(pidText)
    if pid then
        return pid
    end
    return nil
end

writeBootstrapGuard = function(guardPath, status, reason, scriptPath, pid)
    if not PATH_HELPER then return end
    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = status,
        REASON = reason,
        SCRIPT_PATH = scriptPath or "",
        UPDATED_AT = os.time(),
        PID = pid and tostring(pid) or "",
    })
end

local function showStatusWindow(stateFile, logFile, finalMessage)
    if not gfx then
        if finalMessage then
            msgBox("STEMwerk Setup", finalMessage, finalMessage:find("failed") and 16 or 0)
        end
        return
    end

    if OS == "Windows" then
        local state = parseStateFile(stateFile)
        local msg = finalMessage
        if not msg or msg == "" then
            local lines = {
                "Setup status: " .. tostring(state.STATUS or "unknown"),
            }
            if state.STATUS_REASON and state.STATUS_REASON ~= "" then
                lines[#lines + 1] = "Reason: " .. tostring(state.STATUS_REASON)
            end
            if state.PYTHON_PATH or state.VENV_PYTHON then
                lines[#lines + 1] = "Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or "")
            end
            if state.FFMPEG_PATH then
                lines[#lines + 1] = "FFmpeg: " .. tostring(state.FFMPEG_PATH or "")
            end
            lines[#lines + 1] = "Log: " .. tostring(logFile or "")
            msg = table.concat(lines, "\n")
        end
        msgBox("STEMwerk Setup", msg, (msg:find("failed") and 16) or 0)
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
        local stepLine = formatStepStatus(state)
        local pythonLine = "Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or "")
        local ffmpegLine = "FFmpeg: " .. tostring(state.FFMPEG_PATH or "")
        local spin = spinner[idx]
        idx = (idx % #spinner) + 1

        gfx.set(0, 0, 0, 0)
        gfx.setfont(1, "Arial", 16)
        gfx.x = 20
        gfx.y = 20
        if finalMessage then
            shownMessage = finalMessage
        else
            shownMessage = (state.STATUS == "ok") and "Bootstrap completed." or "Bootstrapping..."
        end
        gfx.drawstr(shownMessage .. " [" .. spin .. "]")
        gfx.y = gfx.y + 30
        gfx.drawstr(stateLine)
        if reasonLine ~= "" then
            gfx.y = gfx.y + 22
            gfx.drawstr(reasonLine)
        end
        if stepLine ~= "" then
            gfx.y = gfx.y + 22
            gfx.drawstr(stepLine)
        end
        gfx.y = gfx.y + 26
        gfx.drawstr(pythonLine)
        gfx.y = gfx.y + 22
        gfx.drawstr(ffmpegLine)
        gfx.y = gfx.y + 26
        gfx.drawstr("Log: " .. tostring(logFile))
        gfx.y = gfx.y + 22
        gfx.drawstr("Recent log lines:")
        gfx.y = gfx.y + 20

        for _, line in ipairs(lines) do
            local wrapped = wrapLine(line, 106)
            for _, wl in ipairs(wrapped) do
                gfx.drawstr(wl)
                gfx.y = gfx.y + 18
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
        local pid = readBootstrapPid(pidFile)
        if pid then
            local ok = isProcessAlive(pid)
            if not ok then
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
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)

    if OS == "Windows" then
        return false, stateFile, logFile, {
            STATUS = "disabled",
            STATUS_REASON = "windows_installer_only",
        }
    end

    local scriptPath = PATH_HELPER.getBootstrapScriptPath(INSTALL_ROOT, OS, PATH_SEP)
    local cmd
    if OS == "macOS" then
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

local function launchWindowsBootstrap(runtime, stateFile, logFile, scriptPath)
    -- Windows REAPER-side bootstrap is disabled; installer handles heavy setup.
    return false
end

local WINDOWS_SETUP = nil

local function windowsDrawStatus(state, logLines, pidAlive, pid)
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    drawStemwerkTitleWindows(y, 26)
    y = y + 30

    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Windows bootstrap in progress")
    y = y + 24
    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Phase: " .. ((state.STATUS == "running" or state.STATUS == "" or not state.STATUS) and "Bootstrapping" or "Finalizing"))
    y = y + 22

    local statusLine = "Status: " .. tostring(state.STATUS or "running")
    gfx.x = 18
    gfx.y = y
    gfx.drawstr(statusLine)
    y = y + 20
    if state.STATUS_REASON and state.STATUS_REASON ~= "" then
        gfx.x = 18
        gfx.y = y
        gfx.drawstr("Reason: " .. tostring(state.STATUS_REASON))
        y = y + 20
    end

    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or ""))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("FFmpeg: " .. tostring(state.FFMPEG_PATH or ""))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("PID: " .. tostring(pid or "") .. " (alive: " .. tostring(pidAlive) .. ")")
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Log: " .. tostring(WINDOWS_SETUP.logFile))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Recent log lines (newest last):")
    y = y + 20

    gfx.setfont(1, "Courier New", 16)
    for _, line in ipairs(logLines) do
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end
end

local function drawWindowsFinal(finalLines, finalSuccess)
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 18
    drawStemwerkTitleWindows(y, 26)
    y = y + 30
    gfx.setfont(1, "Arial Bold", 28)
    gfx.x = 18
    gfx.y = y
    if finalSuccess then
        gfx.set(0.2, 0.9, 0.2, 1)
        local headline = "Setup complete — run STEMwerk.lua from the REAPER Action List"
        local wrapped = wrapLine(headline, 90)
        for _, wl in ipairs(wrapped) do
            gfx.drawstr(wl)
            y = y + 26
            gfx.x = 18
            gfx.y = y
        end
        y = y - 26
    else
        gfx.set(1.0, 0.4, 0.1, 1)
        gfx.drawstr("Setup was not completely successful.")
    end
    gfx.set(1, 1, 1, 1)
    y = y + 34

    gfx.setfont(1, "Arial", 18)
    local startIdx = 1
    if finalSuccess and finalLines and finalLines[1] == "Setup complete — run STEMwerk.lua from the REAPER Action List" then
        startIdx = 2
    elseif (not finalSuccess) and finalLines and finalLines[1] == "Setup was not completely successful." then
        startIdx = 2
    end
    for i = startIdx, #(finalLines or {}) do
        local line = finalLines[i]
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end

    gfx.setfont(1, "Arial", 14)
    gfx.x = 18
    gfx.y = h - 28
    gfx.drawstr("Press Esc or close this window to continue.")

    if WINDOWS_SETUP and finalSuccess then
        local btnW = 200
        local btnH = 26
        local btnY = h - 64
        WINDOWS_SETUP.buttons = {
            { label = "Open Action List", x = 18, y = btnY, w = btnW, h = btnH, action = "open_action_list" },
        }
        gfx.setfont(1, "Arial", 13)
        for _, b in ipairs(WINDOWS_SETUP.buttons) do
            drawButton(b.label, b.x, b.y, b.w, b.h)
        end
    end
end

local function finalizeWindowsSetup(result)
    if not WINDOWS_SETUP or not result then return end
    WINDOWS_SETUP.finalized = true
    local finalMessage = (type(result) == "table" and type(result.finalMessage) == "table") and result.finalMessage or {
        "Setup was not completely successful.",
        "Reason: invalid result payload."
    }
    WINDOWS_SETUP.finalMessage = finalMessage
    WINDOWS_SETUP.finalSuccess = result.success == true
    WINDOWS_SETUP.summaryText = table.concat(finalMessage, "\n")
    writeBootstrapGuard(
        WINDOWS_SETUP.guardPath,
        WINDOWS_SETUP.finalSuccess and "ok" or "failed",
        WINDOWS_SETUP.finalSuccess and "completed" or "bootstrap_failed",
        WINDOWS_SETUP.bootstrapScript,
        readBootstrapPid(WINDOWS_SETUP.pidFile)
    )
end

local function windowsSetupTick()
    if not WINDOWS_SETUP or not gfx then return end

    local state = parseStateFile(WINDOWS_SETUP.stateFile)
    local logLines = readTail(WINDOWS_SETUP.logFile, 32)
    local pid = readBootstrapPid(WINDOWS_SETUP.pidFile)
    local pidAlive = false
    if pid then
        pidAlive = isWindowsProcessAlive(pid)
    end

    if not WINDOWS_SETUP.finalized then
        local status = state.STATUS or ""
        local elapsed = os.time() - (WINDOWS_SETUP.startedAt or os.time())
        if status ~= "" and status ~= "running" then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, status == "ok", state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif status == "launch_failed" then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif pid == nil and (status == "" or status == "running") and elapsed >= 5 then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif pid ~= nil and not pidAlive and (status == "" or status == "running") and elapsed >= 5 then
            local stateDead = parseStateFile(WINDOWS_SETUP.stateFile)
            if stateDead.STATUS == "" or stateDead.STATUS == nil then
                stateDead.STATUS = "pid_dead"
                stateDead.STATUS_REASON = "bootstrap_process_exited"
            end
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, stateDead, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif elapsed >= 1800 then
            local stateTimeout = parseStateFile(WINDOWS_SETUP.stateFile)
            if stateTimeout.STATUS == "" or stateTimeout.STATUS == nil then
                stateTimeout.STATUS = "timeout"
                stateTimeout.STATUS_REASON = "bootstrap_timeout"
            end
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, stateTimeout, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        end
    end

    if WINDOWS_SETUP.finalized then
        drawWindowsFinal(WINDOWS_SETUP.finalMessage, WINDOWS_SETUP.finalSuccess)
    else
        windowsDrawStatus(state, logLines, pidAlive, pid)
    end

    gfx.update()
    if WINDOWS_SETUP and WINDOWS_SETUP.finalized and WINDOWS_SETUP.buttons then
        local cap = gfx.mouse_cap
        local last = WINDOWS_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        WINDOWS_SETUP.lastMouseCap = cap
        if clicked then
            for _, b in ipairs(WINDOWS_SETUP.buttons) do
                if isMouseIn(b.x, b.y, b.w, b.h) then
                    if b.action == "open_action_list" then
                        openActionList()
                    end
                    break
                end
            end
        end
    end
    local key = gfx.getchar()
    if key == 27 or key == -1 then
        if not WINDOWS_SETUP.finalized then
            writeBootstrapGuard(WINDOWS_SETUP.guardPath, "failed", "user_closed", WINDOWS_SETUP.bootstrapScript)
            if WINDOWS_SETUP.summaryText == "" then
                local result = safePerformPostBootstrap(
                    WINDOWS_SETUP.runtime,
                    WINDOWS_SETUP.stateFile,
                    WINDOWS_SETUP.logFile,
                    false,
                    parseStateFile(WINDOWS_SETUP.stateFile),
                    WINDOWS_SETUP.separatorScript
                )
                finalizeWindowsSetup(result)
            end
        end
        gfx.quit()
        WINDOWS_SETUP = nil
        return
    end

    reaper.defer(windowsSetupTick)
end

local function startWindowsSetup(runtime, separatorScript)
    msgBox(
        "STEMwerk Setup",
        "On Windows, setup runs in the installer.\n\n"
            .. "This REAPER script only verifies/repairs and will not launch bootstrap installers.\n\n"
            .. "Please re-run the Windows installer if setup is incomplete.",
        0
    )
    return
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
    local state = {}
    if type(bootstrapState) == "table" then
        for k, v in pairs(bootstrapState) do
            state[k] = v
        end
    end
    local latestState = parseStateFile(stateFile)
    if type(latestState) == "table" then
        for k, v in pairs(latestState) do
            if v ~= nil and v ~= "" then
                state[k] = v
            end
        end
    end

    if (not state.PYTHON_PATH or state.PYTHON_PATH == "") and (not state.VENV_PYTHON or state.VENV_PYTHON == "") then
        local extPythonPath = getExt("pythonPath")
        if extPythonPath ~= "" then
            state.PYTHON_PATH = extPythonPath
        end
    end
    if not state.FFMPEG_PATH or state.FFMPEG_PATH == "" then
        local extFfmpegPath = getExt("ffmpegPath")
        if extFfmpegPath ~= "" then
            state.FFMPEG_PATH = extFfmpegPath
        end
    end

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
    local verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #errors == 0
    local effectiveBootstrapSuccess = bootstrapSuccess or verifiedRuntimeOk

    if verifiedRuntimeOk and state.STATUS ~= "ok" then
        appendLogLine(logFile, "INFO: post-bootstrap verification succeeded; normalizing stale bootstrap state to ok")
        state.STATUS = "ok"
        state.STATUS_REASON = ""
    end

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
    if OS == "Windows" and verifiedRuntimeOk and (probeErr == "device_probe_failed" or deviceOut == nil or deviceOut == "") then
        local bootstrapBackend = trim(state.BACKEND or "")
        local bootstrapProfile = trim(state.PROFILE or "")
        if bootstrapBackend == "cuda" and bootstrapProfile == "windows-cuda" then
            backend = "cuda"
            backendReason = "bootstrap_cuda_confirmed"
        elseif bootstrapBackend == "directml" and bootstrapProfile == "windows-directml" then
            backend = "directml"
            backendReason = "bootstrap_directml_confirmed"
        end
    end
    if OS == "Windows" and backend == "cpu" and verifiedRuntimeOk then
        local bootstrapBackend = trim(state.BACKEND or "")
        local bootstrapProfile = trim(state.PROFILE or "")
        local envCudaAvail = envJsonValue(envJson, "cuda_available") == "true"
        local envCudaCount = tonumber(envJsonValue(envJson, "cuda_count")) or 0
        local sawCudaRuntime = envCudaAvail or envCudaCount > 0
            or (deviceOut and (deviceOut:find("STEMWERK_TORCH_GPU\tcuda:") or deviceOut:find("STEMWERK_SELECTED_DEVICE\tcuda:")))
        local sawDirectMlRuntime = deviceOut and (
            deviceOut:find("STEMWERK_DEVICE\tdirectml")
            or deviceOut:find("STEMWERK_DML_DEVICE\tdirectml")
            or deviceOut:find("STEMWERK_SELECTED_DEVICE\tdirectml")
        )
        if bootstrapBackend == "cuda" and sawCudaRuntime then
            backend = "cuda"
            backendReason = "bootstrap_cuda_confirmed"
        elseif bootstrapBackend == "directml" and sawDirectMlRuntime and bootstrapProfile == "windows-directml" then
            backend = "directml"
            backendReason = "bootstrap_directml_confirmed"
        end
    end
    if state.BACKEND_REASON and state.BACKEND_REASON ~= "" then
        local priorBackend = trim(state.BACKEND or "")
        local sameBackend = (priorBackend == "") or (priorBackend == backend)
        if backend == "cpu" or sameBackend then
            if backendReason ~= "" then
                backendReason = backendReason .. "; " .. state.BACKEND_REASON
            else
                backendReason = state.BACKEND_REASON
            end
        end
    end
    local backendReasonLabel = prettyBackendReason(backendReason)
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
    local verificationStatus = (effectiveBootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) and "ok" or "failed"

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

    if (effectiveBootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) then
        finalMessage[#finalMessage + 1] = "Setup complete — run STEMwerk.lua from the REAPER Action List"
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Python path: " .. tostring(verification.pythonPath)
        finalMessage[#finalMessage + 1] = "FFmpeg path: " .. tostring(verification.ffmpegPath)
        finalMessage[#finalMessage + 1] = "Profile: " .. tostring(profile)
        finalMessage[#finalMessage + 1] = "Backend: " .. tostring(backend)
        if backendReasonLabel and backendReasonLabel ~= "" then
            finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReasonLabel)
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
    if backendReasonLabel and backendReasonLabel ~= "" then
        finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReasonLabel)
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

safePerformPostBootstrap = function(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    local ok, result = pcall(performPostBootstrap, runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    if ok and type(result) == "table" then
        return result
    end
    local state = type(bootstrapState) == "table" and bootstrapState or parseStateFile(stateFile)
    if type(state) ~= "table" then
        state = {}
    end
    local lf = io.open(logFile, "a")
    if lf then
        lf:write("WARN: performPostBootstrap failed, falling back to hard fail path.\n")
        if not ok and type(result) == "string" then
            lf:write("WARN: " .. tostring(result) .. "\n")
        end
        lf:close()
    end
    return {
        success = false,
        finalMessage = {
            "Setup was not completely successful.",
            "",
            "Status: " .. tostring(state.STATUS or "unknown"),
            "Reason: postbootstrap_failed",
            "",
            "An internal setup reporting step failed.",
            "Please run STEMwerk_First_Run_Setup.lua again.",
        },
    }
end

local function appendLogLine(logFile, line)
    if not logFile or logFile == "" then return end
    local lf = io.open(logFile, "a")
    if not lf then return end
    lf:write(tostring(line or "") .. "\n")
    lf:close()
end

local function runPipInstall(pythonPath, package, logFile)
    if not pythonPath or pythonPath == "" or not package or package == "" then return false end
    local cmd = quoteArg(pythonPath) .. " -m pip install " .. package
    if logFile and logFile ~= "" then
        cmd = cmd .. " >> " .. quoteArg(logFile) .. " 2>&1"
    end
    local rc = select(1, exec(cmd, 180000))
    return rc == 0
end

local function isWindowsFfmpegShimPath(path)
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\winget\\links\\ffmpeg.exe", 1, true)
        or p:find("\\windowsapps\\ffmpeg", 1, true)
        or p:find("/microsoft/winget/links/ffmpeg.exe", 1, true)
        or p:find("/windowsapps/ffmpeg", 1, true)
end

local function summarizeInstallerState(state)
    local lines = {}
    if state and next(state) ~= nil then
        lines[#lines + 1] = "Installer status: " .. tostring(state.STATUS or "unknown")
        if state.STATUS_REASON and state.STATUS_REASON ~= "" then
            lines[#lines + 1] = "Installer reason: " .. tostring(state.STATUS_REASON)
        end
        if state.PYTHON_PATH and state.PYTHON_PATH ~= "" then
            lines[#lines + 1] = "Python: " .. tostring(state.PYTHON_PATH)
        end
        if state.FFMPEG_PATH and state.FFMPEG_PATH ~= "" and not isWindowsFfmpegShimPath(state.FFMPEG_PATH) then
            lines[#lines + 1] = "FFmpeg: " .. tostring(state.FFMPEG_PATH)
        end
    else
        lines[#lines + 1] = "Installer state not found."
    end
    return lines
end

local function isWindowsStorePythonPath(path)
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\windowsapps\\python", 1, true)
        or p:find("/microsoft/windowsapps/python", 1, true)
end

local function findWindowsPythonFallback()
    local h = io.popen("where python 2>nul")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    for line in out:gmatch("[^\r\n]+") do
        local p = trim(line)
        if p ~= "" and fileExists(p) and not isWindowsStorePythonPath(p) then
            return p
        end
    end
    return ""
end

local function findWindowsRuntimeFfmpeg(runtime)
    local candidates = {
        runtime.base .. "\\ffmpeg\\bin\\ffmpeg.exe",
        runtime.base .. "\\ffmpeg\\ffmpeg.exe",
        runtime.base .. "\\bin\\ffmpeg.exe",
    }
    for _, p in ipairs(candidates) do
        if fileExists(p) then
            return p
        end
    end
    return ""
end

local function findWindowsFfmpegFallback(runtime)
    local runtimePath = findWindowsRuntimeFfmpeg(runtime)
    if runtimePath ~= "" then
        return runtimePath
    end
    local h = io.popen("where ffmpeg 2>nul")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    for line in out:gmatch("[^\r\n]+") do
        local p = trim(line)
        if p ~= "" and fileExists(p) and not isWindowsFfmpegShimPath(p) then
            return p
        end
    end
    return ""
end
local function isValidFfmpegPath(path)
    return path ~= "" and fileExists(path) and not isWindowsFfmpegShimPath(path)
end

local WINDOWS_VERIFY = nil

local function drawWindowsVerify()
    if not WINDOWS_VERIFY or not gfx then return end
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    drawStemwerkTitleWindows(y, 24)
    y = y + 30

    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    if WINDOWS_VERIFY.finalized and WINDOWS_VERIFY.finalSuccess then
        gfx.set(0.2, 0.9, 0.2, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.drawstr(WINDOWS_VERIFY.title or "Verifying runtime...")
    gfx.set(1, 1, 1, 1)
    y = y + 24

    gfx.setfont(1, "Arial", 16)
    for _, line in ipairs(WINDOWS_VERIFY.statusLines or {}) do
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end

    if WINDOWS_VERIFY.finalized then
        gfx.setfont(1, "Arial", 14)
        gfx.x = 18
        gfx.y = h - 28
        gfx.drawstr("Press Esc or close this window to continue.")
    end
end

local function finalizeWindowsVerify(success, lines)
    if not WINDOWS_VERIFY then return end
    WINDOWS_VERIFY.finalized = true
    WINDOWS_VERIFY.finalSuccess = success == true
    if success and lines and lines[1] == "Setup complete — run STEMwerk.lua from the REAPER Action List" then
        table.remove(lines, 1)
    end
    WINDOWS_VERIFY.statusLines = lines or WINDOWS_VERIFY.statusLines
    WINDOWS_VERIFY.title = success and "Setup complete." or "Setup needs attention."
end

local function windowsVerifyTick()
    if not WINDOWS_VERIFY or not gfx then return end

    drawWindowsVerify()
    gfx.update()

    local key = gfx.getchar()
    if key == 27 or key == -1 then
        gfx.quit()
        WINDOWS_VERIFY = nil
        return
    end

    if WINDOWS_VERIFY.finalized then
        reaper.defer(windowsVerifyTick)
        return
    end

    -- First frame drawn; begin stepwise checks on subsequent ticks
    local step = WINDOWS_VERIFY.step or 0
    if step == 0 then
        WINDOWS_VERIFY.step = 1
        reaper.defer(windowsVerifyTick)
        return
    end

    local runtime = WINDOWS_VERIFY.runtime
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"

    if step == 1 then
        WINDOWS_VERIFY.statusLines = { "Reading installer state..." }
        WINDOWS_VERIFY.state = parseStateFile(stateFile)
        WINDOWS_VERIFY.hasState = (WINDOWS_VERIFY.state and next(WINDOWS_VERIFY.state) ~= nil)
        WINDOWS_VERIFY.step = 2
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 2 then
        WINDOWS_VERIFY.statusLines = { "Resolving Python path..." }
        local state = WINDOWS_VERIFY.state or {}
        local pythonPath = resolvePath((state.PYTHON_PATH and state.PYTHON_PATH ~= "" and state.PYTHON_PATH)
            or (state.VENV_PYTHON and state.VENV_PYTHON ~= "" and state.VENV_PYTHON)
            or runtime.venvPython)
        if pythonPath == "" or isWindowsStorePythonPath(pythonPath) then
            pythonPath = resolvePath(findWindowsPythonFallback())
        end
        WINDOWS_VERIFY.pythonPath = pythonPath
        WINDOWS_VERIFY.step = 3
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 3 then
        WINDOWS_VERIFY.statusLines = { "Resolving FFmpeg path..." }
        local state = WINDOWS_VERIFY.state or {}
        local ffmpegPath = ""
        local shimFound = ""

        -- 1) local runtime FFmpeg
        ffmpegPath = resolvePath(findWindowsRuntimeFfmpeg(runtime))
        if not isValidFfmpegPath(ffmpegPath) then
            ffmpegPath = ""
        end

        -- 2) bootstrap.env FFMPEG_PATH
        local statePath = resolvePath(state.FFMPEG_PATH or "")
        if statePath ~= "" and isWindowsFfmpegShimPath(statePath) then
            shimFound = statePath
            statePath = ""
            state.FFMPEG_PATH = ""
            updateBootstrapEnv(stateFile, { FFMPEG_PATH = "" })
        end
        if ffmpegPath == "" and isValidFfmpegPath(statePath) then
            ffmpegPath = statePath
        end

        -- 3) manual override (ExtState)
        local extPath = resolvePath(getExt("ffmpegPath"))
        if extPath ~= "" and isWindowsFfmpegShimPath(extPath) then
            if shimFound == "" then shimFound = extPath end
            extPath = ""
            setExt("ffmpegPath", "")
        end
        if ffmpegPath == "" and isValidFfmpegPath(extPath) then
            ffmpegPath = extPath
        end

        -- 4) PATH fallback (non-shim only)
        if ffmpegPath == "" then
            ffmpegPath = resolvePath(findWindowsFfmpegFallback(runtime))
            if ffmpegPath ~= "" and isWindowsFfmpegShimPath(ffmpegPath) then
                if shimFound == "" then shimFound = ffmpegPath end
                ffmpegPath = ""
            end
        end

        if shimFound ~= "" then
            WINDOWS_VERIFY.ffmpegShim = shimFound
        end
        if ffmpegPath == "" and shimFound ~= "" then
            state.STATUS = "missing_ffmpeg"
            state.STATUS_REASON = "ffmpeg_shim_path"
            updateBootstrapEnv(stateFile, {
                STATUS = "missing_ffmpeg",
                STATUS_REASON = "ffmpeg_shim_path",
                FFMPEG_PATH = "",
            })
        end

        WINDOWS_VERIFY.ffmpegPath = ffmpegPath
        WINDOWS_VERIFY.step = 4
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 4 then
        WINDOWS_VERIFY.statusLines = { "Checking Python..." }
        local pythonOk = WINDOWS_VERIFY.pythonPath ~= "" and fileExists(WINDOWS_VERIFY.pythonPath)
            and canRunPython(WINDOWS_VERIFY.pythonPath)
        WINDOWS_VERIFY.pythonOk = pythonOk
        WINDOWS_VERIFY.step = 5
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 5 then
        WINDOWS_VERIFY.statusLines = { "Checking FFmpeg..." }
        local ffmpegOk = WINDOWS_VERIFY.ffmpegPath ~= "" and fileExists(WINDOWS_VERIFY.ffmpegPath)
            and canRunFfmpeg(WINDOWS_VERIFY.ffmpegPath)
        WINDOWS_VERIFY.ffmpegOk = ffmpegOk
        WINDOWS_VERIFY.step = 6
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 6 then
        WINDOWS_VERIFY.statusLines = { "Checking stemwerk-core..." }
        local coreOk = false
        if WINDOWS_VERIFY.pythonOk then
            coreOk = canImportStemwerkCore(WINDOWS_VERIFY.pythonPath)
        end
        WINDOWS_VERIFY.coreOk = coreOk
        WINDOWS_VERIFY.step = 7
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 7 then
        WINDOWS_VERIFY.statusLines = { "Checking audio-separator..." }
        local sepOk = false
        if WINDOWS_VERIFY.pythonOk then
            sepOk = canImportAudioSeparator(WINDOWS_VERIFY.pythonPath)
        end
        WINDOWS_VERIFY.sepOk = sepOk
        WINDOWS_VERIFY.step = 8
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 8 then
        local state = WINDOWS_VERIFY.state or {}
        local lines = {}
        local ok = WINDOWS_VERIFY.pythonOk and WINDOWS_VERIFY.ffmpegOk and WINDOWS_VERIFY.coreOk and WINDOWS_VERIFY.sepOk
        if WINDOWS_VERIFY.hasState and state.INSTALLER == "1" and (state.STATUS == "ok" or state.STATUS == "") and ok then
            state.STATUS = "ok"
            state.STATUS_REASON = ""
            state.PYTHON_PATH = WINDOWS_VERIFY.pythonPath
            state.FFMPEG_PATH = WINDOWS_VERIFY.ffmpegPath
            updateBootstrapEnv(stateFile, {
                STATUS = "ok",
                STATUS_REASON = "",
                PYTHON_PATH = WINDOWS_VERIFY.pythonPath,
                FFMPEG_PATH = WINDOWS_VERIFY.ffmpegPath,
            })
            local result = safePerformPostBootstrap(runtime, stateFile, logFile, true, state, WINDOWS_VERIFY.separatorScript)
            finalizeWindowsVerify(true, result.finalMessage)
            reaper.defer(windowsVerifyTick)
            return
        end

        lines[#lines + 1] = "STEMwerk runtime is not ready yet."
        lines[#lines + 1] = ""
        for _, line in ipairs(summarizeInstallerState(state)) do
            lines[#lines + 1] = line
        end
        if WINDOWS_VERIFY.ffmpegShim and WINDOWS_VERIFY.ffmpegShim ~= "" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Detected unsupported Windows FFmpeg shim:"
            lines[#lines + 1] = "  " .. tostring(WINDOWS_VERIFY.ffmpegShim)
        end
        lines[#lines + 1] = ""
        if not WINDOWS_VERIFY.pythonOk then
            lines[#lines + 1] = "Python is missing or unusable."
            lines[#lines + 1] = "Install Python 3.11 (64-bit) from python.org, then re-run setup."
        elseif not WINDOWS_VERIFY.ffmpegOk then
            lines[#lines + 1] = "FFmpeg is missing."
            lines[#lines + 1] = "Install FFmpeg or re-run the installer, then re-run setup."
            if WINDOWS_VERIFY.ffmpegShim and WINDOWS_VERIFY.ffmpegShim ~= "" then
                lines[#lines + 1] = "Windows shim paths (WinGet/WindowsApps) are not supported."
            end
        elseif not WINDOWS_VERIFY.coreOk or not WINDOWS_VERIFY.sepOk then
            lines[#lines + 1] = "Dependencies are incomplete."
            lines[#lines + 1] = "Re-run the installer to repair the runtime."
        else
            lines[#lines + 1] = "Repair could not complete."
            lines[#lines + 1] = "Re-run the installer or check the log for details."
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Log: " .. tostring(logFile)
        finalizeWindowsVerify(false, lines)
        reaper.defer(windowsVerifyTick)
        return
    end
end

local function windowsVerifyStart(runtime, separatorScript)
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)
    gfx.init("STEMwerk Setup [Windows]", 900, 620, 0, 140, 100)
    WINDOWS_VERIFY = {
        runtime = runtime,
        separatorScript = separatorScript,
        step = 0,
        statusLines = { "Starting verification..." },
        title = "Verifying runtime...",
        finalized = false,
        finalSuccess = false,
    }
    reaper.defer(windowsVerifyTick)
end

local function windowsVerifyRepair(runtime, separatorScript)
    windowsVerifyStart(runtime, separatorScript)
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
    gfx.drawstr("STEMwerk Setup [Linux]")
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

    local stepLine = formatStepStatus(state)
    if stepLine ~= "" then
        gfx.x = 18
        gfx.y = y
        gfx.drawstr(stepLine)
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
    gfx.drawstr("STEMwerk Setup [Linux]")
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
        local headline = "Setup complete — run STEMwerk.lua from the REAPER Action List"
        local wrapped = wrapLine(headline, 110)
        for _, wl in ipairs(wrapped) do
            gfx.drawstr(wl)
            y = y + 26
            gfx.x = 18
            gfx.y = y
        end
        y = y - 26
    else
        gfx.set(1.0, 0.4, 0.1, 1)
        gfx.drawstr("Setup was not completely successful.")
    end
    gfx.set(1, 1, 1, 1)
    y = y + 32

    gfx.setfont(1, "Arial", 15)
    local startIdx = 1
    if finalSuccess and finalLines and finalLines[1] == "Setup complete — run STEMwerk.lua from the REAPER Action List" then
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
        LINUX_SETUP.buttons[#LINUX_SETUP.buttons + 1] = { label = "Open Action List", x = x + 2 * (btnW + gap), y = btnY2, w = btnW, h = btnH, action = "open_action_list" }

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
            local result = safePerformPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
            LINUX_SETUP.finalized = true
            LINUX_SETUP.finalMessage = result.finalMessage
            LINUX_SETUP.finalSuccess = result.success
            LINUX_SETUP.summaryText = table.concat(result.finalMessage or {}, "\n")
        elseif not pidAlive and (status == "" or status == "running") then
            local elapsed = os.time() - (LINUX_SETUP.startedAt or os.time())
            if LINUX_SETUP.pidSeen or elapsed >= 5 then
                local result = safePerformPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
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
                    elseif b.action == "open_action_list" then
                        openActionList()
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
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)

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
    gfx.init("STEMwerk Setup [Linux]", 1100, 760, 0, 120, 80)
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

    if OS == "Windows" then
        windowsVerifyRepair(runtime, separatorScript)
        return
    end

    if OS == "Linux" then
        startLinuxSetup(runtime, separatorScript)
        return
    end

    local bootstrapSuccess, stateFile, logFile, bootstrapState = runBootstrap(runtime)
    local result = safePerformPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    showStatusWindow(stateFile, logFile, table.concat(result.finalMessage, "\n"))
end

main()
