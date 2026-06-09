-- STEMwerk_Devices.lua
-- Runtime device probing and capability cache helpers.

DEVICE_RUNTIME = DEVICE_RUNTIME or {}

local C = {}
local DEVICE_PROBE_CACHE_TTL_SECONDS = 600
local DEVICE_PROBE_CACHE_VERSION = "1"

function DEVICE_RUNTIME.configure(ctx)
    for k, v in pairs(ctx or {}) do
        C[k] = v
    end
end

function DEVICE_RUNTIME.runtimeDeviceSafeList()
    return {
        { id = "auto", name = "Auto", type = "auto", desc = "Automatically chooses the best available processing." },
        { id = "cpu", name = "CPU", type = "cpu", desc = "Force CPU processing (works everywhere; slower)." },
    }
end

local function deviceProbeCachePath()
    if type(C.getRuntimePaths) ~= "function" then return nil end
    local paths = C.getRuntimePaths()
    local stateDir = paths and paths.runtimeState or ""
    if stateDir == "" then return nil end
    return stateDir .. C.PATH_SEP .. "device_probe_cache.txt"
end

local function writeSuccessfulDeviceProbeCache(out, now)
    local path = deviceProbeCachePath()
    if not path or not out or out == "" then return false end
    local tmpPath = path .. ".tmp"
    local f = io.open(tmpPath, "w")
    if not f then return false end
    f:write("STEMWERK_DEVICE_PROBE_CACHE_VERSION=" .. DEVICE_PROBE_CACHE_VERSION .. "\n")
    f:write("STEMWERK_DEVICE_PROBE_CACHE_TIME=" .. tostring(now or os.time()) .. "\n")
    f:write("STEMWERK_DEVICE_PROBE_CACHE_PYTHON=" .. tostring(PYTHON_PATH or "") .. "\n")
    f:write("STEMWERK_DEVICE_PROBE_CACHE_SEPARATOR=" .. tostring(SEPARATOR_SCRIPT or "") .. "\n")
    f:write(out)
    if out:sub(-1) ~= "\n" then f:write("\n") end
    f:close()
    os.remove(path)
    local ok = os.rename(tmpPath, path)
    if not ok then os.remove(tmpPath) end
    return ok and true or false
end

local function readFreshDeviceProbeCache(now)
    local path = deviceProbeCachePath()
    if not path then return nil, "path_unavailable" end
    local f = io.open(path, "r")
    if not f then return nil, "missing" end
    local content = f:read("*a") or ""
    f:close()
    if content == "" then return nil, "empty" end

    local version = content:match("STEMWERK_DEVICE_PROBE_CACHE_VERSION=([^\r\n]+)")
    local cachedAt = tonumber(content:match("STEMWERK_DEVICE_PROBE_CACHE_TIME=(%d+)") or "")
    local cachedPython = content:match("STEMWERK_DEVICE_PROBE_CACHE_PYTHON=([^\r\n]*)") or ""
    local cachedSeparator = content:match("STEMWERK_DEVICE_PROBE_CACHE_SEPARATOR=([^\r\n]*)") or ""
    if version ~= DEVICE_PROBE_CACHE_VERSION then return nil, "version_mismatch" end
    if not cachedAt then return nil, "timestamp_missing" end
    if tostring(cachedPython) ~= tostring(PYTHON_PATH or "") then return nil, "python_changed" end
    if tostring(cachedSeparator) ~= tostring(SEPARATOR_SCRIPT or "") then return nil, "separator_changed" end
    if (now or os.time()) - cachedAt > DEVICE_PROBE_CACHE_TTL_SECONDS then return nil, "expired" end
    return content, "fresh"
end

local function sanitizeFriendlyName(name)
    if not name then return "" end
    local raw = tostring(name):gsub("%c", " ")
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

    if not sawMachine and not sawAlt then
        for line in out:gmatch("[^\r\n]+") do
            local id, name, typ = line:match("^%s*([%w%-%_:%./]+):%s*(.-)%s*%(([%w%-%_]+)%)%s*$")
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

    if envJson and envJson ~= "" then
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

function DEVICE_RUNTIME.backendTypeLabel(dev)
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

local function isAppleSiliconMpsPlatform()
    return OS == "macOS" and (ARCH == "arm64" or ARCH == "aarch64")
end

local function hasMpsDevice(devices)
    for _, d in ipairs(devices or {}) do
        if tostring(d.id or "") == "mps" or tostring(d.type or "") == "mps" then
            return true
        end
    end
    return false
end

local function filterExplicitMpsDevices(devices, envJson)
    local mpsAvailable = envJsonBool(envJson, "mps_available")
    local allowMps = isAppleSiliconMpsPlatform() and mpsAvailable == true
    local filtered = {}
    for _, d in ipairs(devices or {}) do
        local isMps = tostring(d.id or "") == "mps" or tostring(d.type or "") == "mps"
        if not isMps or allowMps then
            filtered[#filtered + 1] = d
        end
    end
    return filtered
end

function DEVICE_RUNTIME.applyRuntimeDevicesFromParsed(devices, envJson, now, opts)
    now = now or os.time()
    opts = opts or {}
    local skipQuickBench = (OS == "Windows") and (opts.skipQuickBench == true)

    if not devices then
        debugLog("  probe FAILED -> safe device list (Auto/CPU)")
        RUNTIME_DEVICE_SKIP_NOTE = nil
        RUNTIME_DIRECTML_POSSIBLE = nil
        RUNTIME_CUDA_COUNT = nil
        RUNTIME_DEVICES = DEVICE_RUNTIME.runtimeDeviceSafeList()
        RUNTIME_DEVICE_NOTE_KEY = "device_note_probe_failed"
        RUNTIME_DEVICE_PROBE_DEBUG = "probe_failed"
        RUNTIME_DEVICE_LAST_PROBE = now
        if SETTINGS and SETTINGS.device and SETTINGS.device ~= "auto" and SETTINGS.device ~= "cpu" then
            SETTINGS.device = "auto"
            if saveSettings then saveSettings() end
        end
        return
    end

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
        local home = C.getHome()
        local candidates = {}

        if home and host ~= "" then
            if C.PATH_SEP == "\\" then
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

    if OS ~= "Windows" then
        local filtered = {}
        for _, d in ipairs(devices) do
            if d.type ~= "directml" and not (d.id and d.id:match("^directml")) then
                filtered[#filtered + 1] = d
            end
        end
        devices = filtered
    end

    devices = filterExplicitMpsDevices(devices, envJson)


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
            d.uiName = type(C.T) == "function" and (C.T("device_mps_label") or d.uiName) or d.uiName
        end
    end

    RUNTIME_DEVICES = devices
    RUNTIME_DEVICE_NOTE_KEY = buildDeviceNoteFromEnvJson(envJson, devices)
    RUNTIME_DEVICE_LAST_PROBE = now

    if SETTINGS.device == "mps" and not hasMpsDevice(RUNTIME_DEVICES) then
        SETTINGS.device = "cpu"
        saveSettings()
    end

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
        if not (d.type == "directml" or d.type == "cuda" or (d.id and d.id:match("^directml:%d+$") or d.id:match("^cuda:%d+$"))) then
            return nil
        end
        local benchScript = C.script_path .. "check_directml_runtime.py"
        if not C.fileExists(benchScript) then
            benchScript = (C.repo_root or "") .. "scripts" .. C.PATH_SEP .. "reaper" .. C.PATH_SEP .. "check_directml_runtime.py"
            if not C.fileExists(benchScript) then return nil end
        end
        local idx = tonumber((d.id or ""):match("%d+$")) or 0
        local cmd = C.quoteArg(PYTHON_PATH) .. " -u " .. C.quoteArg(benchScript) .. " --size 800 --iters 1 --dml-device " .. tostring(idx)
        local rc, out = execCapture(cmd, 20000)
        if rc ~= 0 then return nil end
        return parseBenchOutput(out)
    end

    local function autoSelectBestDevice(list)
        if not list or #list == 0 then return end
        local bestId = nil
        local bestTime = nil
        local tried = 0
        for _, d in ipairs(list) do
            if tried >= 3 then break end
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

    if not skipQuickBench then
        pcall(function() autoSelectBestDevice(RUNTIME_DEVICES) end)
    end

    if SETTINGS and SETTINGS.device then
        local ok = false
        for _, d in ipairs(RUNTIME_DEVICES) do
            if d.id == SETTINGS.device then ok = true break end
        end
        if not ok then
            SETTINGS.device = "auto"
            if saveSettings then saveSettings() end
        end
    end
    return true
end

function DEVICE_RUNTIME.startRuntimeDeviceProbeAsync(force)
    force = force or false
    local now = os.time()
    if not force and RUNTIME_DEVICES and (now - (RUNTIME_DEVICE_LAST_PROBE or 0) < 10) then
        return false
    end
    if RUNTIME_DEVICE_PROBE and RUNTIME_DEVICE_PROBE.active then
        return false
    end

    if not force and DEVICE_RUNTIME.applyCachedRuntimeDevices() then
        debugLog("=== Device probe: loaded from capabilities ===")
        return false
    end

    local function getTempDirEarly()
        if OS == "Windows" then
            return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        end
        local flatpakTemp = C.getFlatpakTempBase()
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
        return getTempDirEarly() .. C.PATH_SEP .. "STEMwerk_devprobe_" .. tostring(os.time()) .. "_" .. tostring(ms)
    end

    local probeDir = uniqueProbeDir()
    makeDirEarly(probeDir)

    local outFile = probeDir .. C.PATH_SEP .. "probe_out.txt"
    local doneFile = probeDir .. C.PATH_SEP .. "done.txt"
    local pidFile = probeDir .. C.PATH_SEP .. "pid.txt"
    local rcFile = probeDir .. C.PATH_SEP .. "rc.txt"

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

    if not RUNTIME_DEVICES then
        RUNTIME_DEVICES = DEVICE_RUNTIME.runtimeDeviceSafeList()
    end
    RUNTIME_DEVICE_NOTE_KEY = "device_note_probing"

    if OS == "Windows" then
        local vbsPath = probeDir .. C.PATH_SEP .. "run_probe_hidden.vbs"
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

        local psPath = probeDir .. C.PATH_SEP .. "run_probe_hidden.ps1"
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
        psScript:write("$outLast='" .. escPsSingle(C.script_path .. "probe_out_last.txt") .. "'\n")
        psScript:write("$rcLast='" .. escPsSingle(C.script_path .. "probe_rc_last.txt") .. "'\n")
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

        local psCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' .. C.quoteArg(psPath)

        vbsFile:write('Set sh = CreateObject("WScript.Shell")' .. "\n")
        vbsFile:write('cmd = "' .. escVbs(psCmd) .. '"' .. "\n")
        vbsFile:write('sh.Run cmd, 0, False' .. "\n")
        vbsFile:close()

        local dbgPath = C.script_path .. "probe_debug_last.txt"
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
        local launcherPath = probeDir .. C.PATH_SEP .. "run_bg.sh"
        local script = io.open(launcherPath, "w")
        if not script then
            debugLog("Async probe: failed to write launcher")
            RUNTIME_DEVICE_PROBE.active = false
            return false
        end

        script:write("#!/bin/sh\n")
        script:write("PY=" .. C.quoteArg(PYTHON_PATH) .. "\n")
        script:write("SEP=" .. C.quoteArg(SEPARATOR_SCRIPT) .. "\n")
        script:write("OUT=" .. C.quoteArg(outFile) .. "\n")
        script:write("DONE=" .. C.quoteArg(doneFile) .. "\n")
        script:write("PIDFILE=" .. C.quoteArg(pidFile) .. "\n")
        script:write("RCFILE=" .. C.quoteArg(rcFile) .. "\n")
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

        os.execute("sh " .. C.quoteArg(launcherPath) .. " 2>/dev/null")
    end

    return true
end

local function extractCapabilityDeviceOutput(cap)
    if not (cap and cap.raw) then return "" end

    local kv = cap.kv or {}
    local backend = string.lower(tostring(kv.BACKEND or ""))
    local verification = string.lower(tostring(kv.VERIFICATION or ""))
    local driftDetected = string.lower(tostring(kv.RUNTIME_DRIFT_DETECTED or "")) == "yes"
    local rawLooksStale = driftDetected
        or backend == "cpu"
        or verification == "runtime_probe_failed"
        or verification == "probe_failed"

    local deviceOut = (not rawLooksStale) and cap.raw:match("DEVICES_OUTPUT_BEGIN\r?\n(.-)\r?\nDEVICES_OUTPUT_END") or nil
    if deviceOut and deviceOut ~= "" then
        return deviceOut
    end
    if (not rawLooksStale)
        and (cap.raw:find("STEMWERK_CUDA_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_DML_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_MPS_DEVICE", 1, true)
        or cap.raw:find("STEMWERK_DEVICE\t", 1, true)
        or cap.raw:find("STEMWERK_ENV_JSON ", 1, true)) then
        return cap.raw
    end

    local lines = {}
    local envJson = tostring(kv.ENV_JSON or "")
    local deviceNames = tostring(kv.DEVICE_NAMES or "")

    if envJson ~= "" then
        lines[#lines + 1] = "STEMWERK_ENV_JSON " .. envJson
    end

    lines[#lines + 1] = "STEMWERK_DEVICE\tauto\tAuto\tauto"
    lines[#lines + 1] = "STEMWERK_DEVICE\tcpu\tCPU\tcpu"

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

function DEVICE_RUNTIME.pollRuntimeDeviceProbe()
    if not (RUNTIME_DEVICE_PROBE and RUNTIME_DEVICE_PROBE.active) then return false end

    local age = os.clock() - (RUNTIME_DEVICE_PROBE.startedAt or os.clock())
    if age > 90 then
        debugLog("Async device probe timed out after " .. tostring(age) .. "s")
        RUNTIME_DEVICE_PROBE.active = false
        DEVICE_RUNTIME.applyRuntimeDevicesFromParsed(nil, nil, os.time())
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
    if devices then
        writeSuccessfulDeviceProbeCache(out, os.time())
    end
    DEVICE_RUNTIME.applyRuntimeDevicesFromParsed(devices, envJson, os.time())
    RUNTIME_DEVICE_PROBE.active = false
    debugLog("=== Device probe: async done (devices=" .. tostring(RUNTIME_DEVICES and #RUNTIME_DEVICES or 0) .. ") ===")
    return true
end

function DEVICE_RUNTIME.applyFreshDeviceProbeCache(opts)
    local content, reason = readFreshDeviceProbeCache(os.time())
    if not content then
        debugLog("Device probe cache skipped reason=" .. tostring(reason))
        return false, reason
    end
    local devices, envJson, skipNote = parseDeviceListFromPythonOutput(content)
    if not devices then
        debugLog("Device probe cache skipped reason=parse_failed")
        return false, "parse_failed"
    end
    RUNTIME_DEVICE_SKIP_NOTE = skipNote
    DEVICE_RUNTIME.applyRuntimeDevicesFromParsed(devices, envJson, os.time(), opts)
    debugLog("Device probe cache applied ttl_seconds=" .. tostring(DEVICE_PROBE_CACHE_TTL_SECONDS))
    return true, "fresh"
end

function DEVICE_RUNTIME.refreshRuntimeDevices(force)
    force = force or false
    local now = os.time()
    if not force and RUNTIME_DEVICES and (now - (RUNTIME_DEVICE_LAST_PROBE or 0) < 10) then
        return
    end

    if not force and DEVICE_RUNTIME.applyCachedRuntimeDevices() then
        return
    end

    debugLog("=== Device probe: refreshRuntimeDevices() ===")
    debugLog("  PYTHON_PATH=" .. tostring(PYTHON_PATH))
    debugLog("  SEPARATOR_SCRIPT=" .. tostring(SEPARATOR_SCRIPT))

    local devices, envJson = nil, nil
    local PROBE_TIMEOUT_MS = 30000

    function execCapture(cmd, timeoutMs)
        local rc, out = C.exec_capture(cmd, timeoutMs)
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

    local cmd1 = C.quoteArg(PYTHON_PATH) .. " -u " .. C.quoteArg(SEPARATOR_SCRIPT) .. " --list-devices-machine"
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
        local cmd2 = C.quoteArg(PYTHON_PATH) .. " -u " .. C.quoteArg(SEPARATOR_SCRIPT) .. " --list-devices"
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
        local py = [[
import json, importlib.util, platform
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
machine = platform.machine().lower()
if platform.system() == 'Darwin' and machine in ('arm64', 'aarch64') and env.get('mps_available'):
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
        local function getTempDirEarly()
            if OS == "Windows" then
                return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
            end
            local flatpakTemp = C.getFlatpakTempBase()
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
            return getTempDirEarly() .. C.PATH_SEP .. "STEMwerk_probe_" .. tostring(os.time()) .. "_" .. tostring(ms)
        end

        local probeDir = uniqueProbeDir()
        makeDirEarly(probeDir)
        local probePath = probeDir .. C.PATH_SEP .. "stemwerk_probe_devices.py"
        local f = io.open(probePath, "w")
        if f then
            f:write(py)
            f:close()
        end
        local cmd3 = C.quoteArg(PYTHON_PATH) .. " " .. C.quoteArg(probePath)
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
        debugLog("  probe FAILED -> safe device list (Auto/CPU)")
        RUNTIME_DEVICE_SKIP_NOTE = nil
        RUNTIME_DIRECTML_POSSIBLE = nil
        RUNTIME_CUDA_COUNT = nil
        RUNTIME_DEVICES = DEVICE_RUNTIME.runtimeDeviceSafeList()
        RUNTIME_DEVICE_NOTE_KEY = "device_note_probe_failed"
        RUNTIME_DEVICE_PROBE_DEBUG = "probe_failed"
        RUNTIME_DEVICE_LAST_PROBE = now
        if SETTINGS.device ~= "auto" and SETTINGS.device ~= "cpu" then
            SETTINGS.device = "auto"
            saveSettings()
        end
        return
    end

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
        if idx then return "GPU" .. idx end
        if sid == "cuda" or sid == "directml" then return "GPU" end
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

    if OS ~= "Windows" then
        local filtered = {}
        for _, d in ipairs(devices) do
            if d.type ~= "directml" and not (d.id and d.id:match("^directml")) then
                filtered[#filtered + 1] = d
            end
        end
        devices = filtered
    end

    devices = filterExplicitMpsDevices(devices, envJson)

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
            d.uiName = type(C.T) == "function" and (C.T("device_mps_label") or d.uiName) or d.uiName
        end
    end

    RUNTIME_DEVICES = devices
    RUNTIME_DEVICE_NOTE_KEY = buildDeviceNoteFromEnvJson(envJson, devices)
    RUNTIME_DEVICE_LAST_PROBE = now

    if SETTINGS.device == "mps" and not hasMpsDevice(RUNTIME_DEVICES) then
        SETTINGS.device = "cpu"
        saveSettings()
    end

    local ok = false
    for _, d in ipairs(RUNTIME_DEVICES) do
        if d.id == SETTINGS.device then ok = true break end
    end
    if not ok then
        SETTINGS.device = "auto"
        saveSettings()
    end
end

function DEVICE_RUNTIME.applyCachedRuntimeDevices(opts)
    if type(C.readCapabilities) ~= "function" then
        return false
    end
    local cap = C.readCapabilities()
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
        if type(C.T) == "function" then
            backendLabel = C.T("backend_label") or backendLabel
        end
        skipNote = (skipNote and (skipNote .. "\n\n") or "") .. backendLabel .. ": " .. tostring(backendReasonLabel)
    end
    RUNTIME_DEVICE_SKIP_NOTE = skipNote
    DEVICE_RUNTIME.applyRuntimeDevicesFromParsed(devices, envJson, os.time(), opts)
    if cap.kv and cap.kv.PROFILE then
        debugLog("Capabilities profile=" .. tostring(cap.kv.PROFILE) .. " backend=" .. tostring(cap.kv.BACKEND))
    end
    return true
end

function DEVICE_RUNTIME.getTrustedWindowsRuntimeState()
    if OS ~= "Windows" or type(C.readCapabilities) ~= "function" then
        return nil
    end
    local cap = C.readCapabilities()
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
    if C.isAbsolutePath(pythonPath) and not C.fileExists(pythonPath) then
        return nil
    end
    if C.isAbsolutePath(ffmpegPath) and not C.fileExists(ffmpegPath) then
        return nil
    end

    return {
        pythonPath = pythonPath,
        ffmpegPath = ffmpegPath,
        backend = trimValue(cap.kv.BACKEND),
        profile = trimValue(cap.kv.PROFILE),
    }
end

function DEVICE_RUNTIME.applyTrustedWindowsRuntimeState(state)
    if not state then return false end
    if state.pythonPath and state.pythonPath ~= "" then
        PYTHON_PATH = state.pythonPath
    end
    if state.ffmpegPath and state.ffmpegPath ~= "" then
        FFMPEG_PATH = state.ffmpegPath
    end
    return true
end

function DEVICE_RUNTIME.normalizeRequestedDeviceForRuntime(requestedDevice)
    local rawReq = tostring(requestedDevice or "auto")
    local req = rawReq:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if req == "" then return "auto" end
    local list = RUNTIME_DEVICES or C.DEVICES or {}
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

    if req == "mps" then
        if isAppleSiliconMpsPlatform() and hasId("mps") then
            return "mps"
        end
        return "cpu"
    end
    if req == "auto" or req == "cpu" then return req end

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

return DEVICE_RUNTIME
