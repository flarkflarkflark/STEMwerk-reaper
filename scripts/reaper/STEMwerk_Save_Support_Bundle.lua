-- @description Stemwerk: Save Support Bundle
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.3.1.0
-- @changelog
--   Collects a read-only STEMwerk support bundle with runtime diagnostics, logs, and temp-folder inventory.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local EXT_SECTION = "STEMwerk"

local function msgBox(title, text, boxType)
    if reaper and reaper.ShowMessageBox then
        return reaper.ShowMessageBox(tostring(text or ""), tostring(title or "STEMwerk"), boxType or 0)
    end
    return 0
end

local function getLanguageCode()
    if reaper and reaper.GetExtState then
        local lang = tostring(reaper.GetExtState(EXT_SECTION, "language") or ""):lower()
        if lang ~= "" then return lang end
    end
    return "en"
end

local function trSupportBundleCollecting()
    local lang = getLanguageCode()
    if lang == "nl" then return "Supportbundel wordt verzameld…" end
    if lang == "de" then return "Support-Bundle wird gesammelt…" end
    return "Collecting support bundle…"
end

local function showCollectingStatus()
    local text = trSupportBundleCollecting()
    if reaper and reaper.TrackCtl_SetToolTip then
        local x, y = 0, 0
        if reaper.GetMousePosition then
            x, y = reaper.GetMousePosition()
        end
        reaper.TrackCtl_SetToolTip(text, x + 8, y + 8, true)
    end
end

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local SCRIPT_DIR = getScriptDir()

local function getOS()
    local ros = ""
    if reaper and reaper.GetOS then
        ros = tostring(reaper.GetOS() or "")
    end
    if ros:match("Win") then return "Windows", ros end
    if ros:match("OSX") or ros:match("macOS") then return "macOS", ros end
    return "Linux", ros
end

local OS, REAPER_OS_RAW = getOS()
local PATH_SEP = OS == "Windows" and "\\" or "/"

local function pad2(n)
    n = tonumber(n) or 0
    if n < 10 then return "0" .. tostring(n) end
    return tostring(n)
end

local function timestampParts(epoch)
    local now = os.date("*t", epoch or os.time())
    return now, string.format(
        "%04d%s%s-%s%s%s",
        tonumber(now.year) or 0,
        pad2(now.month),
        pad2(now.day),
        pad2(now.hour),
        pad2(now.min),
        pad2(now.sec)
    )
end

local function trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startsWith(text, prefix)
    text = tostring(text or "")
    prefix = tostring(prefix or "")
    return prefix ~= "" and text:sub(1, #prefix) == prefix
end

local function endsWith(text, suffix)
    text = tostring(text or "")
    suffix = tostring(suffix or "")
    return suffix ~= "" and text:sub(-#suffix) == suffix
end

local function normalizePath(path)
    local p = tostring(path or "")
    if p == "" then return "" end
    if OS == "Windows" then
        p = p:gsub("/", "\\"):lower()
    else
        p = p:gsub("\\", "/")
    end
    return p
end

local function stripTrailingSep(path)
    return tostring(path or ""):gsub("[/\\]+$", "")
end

local function joinPath(...)
    local parts = { ... }
    local out = ""
    for i = 1, #parts do
        local part = tostring(parts[i] or "")
        if part ~= "" then
            if out == "" then
                out = part:gsub("[/\\]+$", "")
            else
                part = part:gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
                out = out .. PATH_SEP .. part
            end
        end
    end
    return out
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

local function pathExists(path)
    if not path or path == "" then return false end
    local ok, _, code = os.rename(path, path)
    if ok then return true end
    return tonumber(code) == 13
end

local function ensureDir(path)
    if not path or path == "" then return false end
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return pathExists(path)
    end
    if OS == "Windows" then
        os.execute('mkdir "' .. tostring(path):gsub('"', '""') .. '" 2>nul')
    else
        os.execute("mkdir -p " .. "'" .. tostring(path):gsub("'", "'\\''") .. "' >/dev/null 2>&1")
    end
    return pathExists(path)
end

local function readFile(path, mode)
    local f = io.open(path, mode or "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data, mode)
    local f = io.open(path, mode or "wb")
    if not f then return false end
    f:write(data or "")
    f:close()
    return true
end

local function fileSizeBytes(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return tonumber(size)
end

local function quoteArg(arg)
    arg = tostring(arg or "")
    if OS == "Windows" then
        return '"' .. arg:gsub('"', '""') .. '"'
    end
    if arg == "" then return "''" end
    return "'" .. arg:gsub("'", "'\\''") .. "'"
end

local function buildCommand(exe, args)
    local parts = { quoteArg(exe) }
    for i = 1, #(args or {}) do
        parts[#parts + 1] = quoteArg(args[i])
    end
    return table.concat(parts, " ")
end

local function execCapturePipe(cmd)
    if not io or not io.popen then
        return -1, ""
    end
    local handle = io.popen(cmd .. " 2>&1", "r")
    if not handle then
        return -1, ""
    end
    local out = handle:read("*a") or ""
    local ok, _, code = handle:close()
    if ok == true then
        return 0, out
    end
    return tonumber(code) or -1, out
end

local function parseExecProcessResult(result)
    if type(result) ~= "string" then
        return nil, ""
    end
    local firstLine, rest = result:match("^([^\r\n]*)\r?\n?(.*)$")
    local rc = tonumber(firstLine)
    if rc == nil then
        return nil, result
    end
    return rc, rest or ""
end

local function execCapture(cmd, timeoutMs)
    if reaper and reaper.ExecProcess then
        local rc, out = parseExecProcessResult(reaper.ExecProcess(cmd, timeoutMs or 8000))
        return tonumber(rc) or -1, out or ""
    end
    return execCapturePipe(cmd)
end

local function buildShellCommand(cmd, timeoutMs)
    local shellCmd = tostring(cmd or "")
    if OS == "Linux" and timeoutMs and timeoutMs > 0 then
        local seconds = math.max(1, math.ceil((tonumber(timeoutMs) or 0) / 1000))
        shellCmd = "timeout " .. tostring(seconds) .. "s " .. shellCmd
    end
    return shellCmd
end

local function execCommand(exe, args, timeoutMs)
    local cmd = buildCommand(exe, args or {})
    if OS ~= "Windows" then
        local shellCmd = buildShellCommand(cmd, timeoutMs)
        local rc, out = execCapturePipe(shellCmd)
        if rc == 0 or trim(out) ~= "" then
            return rc, out
        end
        if reaper and reaper.ExecProcess then
            local sh = fileExists("/bin/sh") and "/bin/sh" or "sh"
            return execCapture(buildCommand(sh, {"-lc", shellCmd}), timeoutMs)
        end
        return rc, out
    end
    return execCapture(cmd, timeoutMs)
end

local function execPowerShell(script, timeoutMs)
    return execCommand("powershell.exe", {"-NoProfile", "-Command", script}, timeoutMs or 8000)
end

local function openPath(path)
    if not path or path == "" then return end
    if reaper and reaper.CF_ShellExecute then
        reaper.CF_ShellExecute(path)
        return
    end
    if OS == "Windows" then
        execCommand("explorer.exe", {path}, 1000)
    elseif OS == "macOS" then
        execCommand("open", {path}, 1000)
    else
        execCommand("xdg-open", {path}, 1000)
    end
end

local function basename(path)
    local clean = tostring(path or ""):gsub("[/\\]+$", "")
    return clean:match("([^/\\]+)$") or clean
end

local function dirname(path)
    local clean = stripTrailingSep(path)
    return clean:match("^(.*)[/\\][^/\\]+$") or ""
end

local function sanitizePathValue(path)
    local value = trim(path)
    if value == "" then return "missing" end
    return value
end

local function sanitizeUserFolder(path)
    local value = trim(path)
    if value == "" then return "not set" end
    return basename(value) .. " (sanitized)"
end

local MEDIA_PATH_EXTENSIONS = {
    "wav", "flac", "mp3", "aiff", "aif", "m4a", "ogg", "opus", "mp4", "mov"
}

local function classifyMediaArtifact(pathLower)
    for i = 1, #MEDIA_PATH_EXTENSIONS do
        local ext = MEDIA_PATH_EXTENSIONS[i]
        if pathLower:match("%." .. ext .. "$") then
            return "media"
        end
        if pathLower:match("%." .. ext .. "%.ffmpeg%.log$") then
            return "ffmpeg_log"
        end
        if pathLower:match("%." .. ext .. "%.reapeaks$") then
            return "reapeaks"
        end
    end
    return nil
end

local function sanitizeAbsolutePathToken(token)
    local suffix = token:match("([,%);%]%}]+)$") or ""
    local core = suffix ~= "" and token:sub(1, #token - #suffix) or token
    local lower = core:lower()
    local artifactKind = classifyMediaArtifact(lower)
    local tempRoot, tempRest = core:match("^(.*[/\\]STEMwerk_[^/\\%s\"']+)(.*)$")
    local isTempPath = tempRoot ~= nil

    if artifactKind == "ffmpeg_log" then
        return (isTempPath and "[STEMWERK_TEMP_DIR]" or "[TEMP_DIR]") .. "/[TEMP_AUDIO_FILE].ffmpeg.log" .. suffix
    end
    if artifactKind == "reapeaks" then
        return (isTempPath and "[STEMWERK_TEMP_DIR]" or "[TEMP_DIR]") .. "/[TEMP_AUDIO_FILE].reapeaks" .. suffix
    end
    if artifactKind == "media" then
        return (isTempPath and "[TEMP_AUDIO_FILE]" or "[MEDIA_FILE]") .. suffix
    end
    if lower:match("%.rpp$") then
        return "[PROJECT_FILE]" .. suffix
    end
    if isTempPath then
        return "[STEMWERK_TEMP_DIR]" .. (tempRest or "") .. suffix
    end
    return token
end

local function sanitizeTextContent(text)
    local sanitized = tostring(text or "")
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Ww][Aa][Vv])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Ff][Ll][Aa][Cc])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Mm][Pp]3)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Aa][Ii][Ff][Ff]?)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Mm]4[Aa])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Oo][Gg][Gg])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Oo][Pp][Uu][Ss])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Mm][Pp]4)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+%.[Mm][Oo][Vv])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Ww][Aa][Vv])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Ff][Ll][Aa][Cc])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Mm][Pp]3)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Aa][Ii][Ff][Ff]?)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Mm]4[Aa])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Oo][Gg][Gg])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Oo][Pp][Uu][Ss])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Mm][Pp]4)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+%.[Mm][Oo][Vv])", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub('"([A-Za-z]:[/\\][^"\r\n]+)"', function(path)
        return '"' .. sanitizeAbsolutePathToken(path) .. '"'
    end)
    sanitized = sanitized:gsub('"(/[^"\r\n]+)"', function(path)
        return '"' .. sanitizeAbsolutePathToken(path) .. '"'
    end)
    sanitized = sanitized:gsub("'([A-Za-z]:[/\\][^'\r\n]+)'", function(path)
        return "'" .. sanitizeAbsolutePathToken(path) .. "'"
    end)
    sanitized = sanitized:gsub("'(/[^'\r\n]+)'", function(path)
        return "'" .. sanitizeAbsolutePathToken(path) .. "'"
    end)
    sanitized = sanitized:gsub("([A-Za-z]:[/\\][^%s\"'<>]+)", sanitizeAbsolutePathToken)
    sanitized = sanitized:gsub("(/[^%s\"'<>]+)", sanitizeAbsolutePathToken)
    return sanitized
end

local function humanBytes(bytes)
    bytes = tonumber(bytes) or 0
    local units = {"B", "KB", "MB", "GB"}
    local idx = 1
    while bytes >= 1024 and idx < #units do
        bytes = bytes / 1024
        idx = idx + 1
    end
    if idx == 1 then
        return string.format("%d %s", math.floor(bytes), units[idx])
    end
    return string.format("%.1f %s", bytes, units[idx])
end

local function readEnvFile(path)
    local data = {}
    if not path or path == "" then return data end
    local f = io.open(path, "r")
    if not f then return data end
    for line in f:lines() do
        local key, value = line:match("^([A-Z0-9_]+)%s*=%s*(.*)$")
        if key and value then
            data[key] = value:gsub("\r", "")
        end
    end
    f:close()
    return data
end

local function parseKeyValueText(text)
    local data = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w%._%-]+)=(.*)$")
        if key then
            data[key] = trim(value)
        end
    end
    return data
end

local function readVersionHeader(path)
    local f = io.open(path, "r")
    if not f then return "" end
    for _ = 1, 80 do
        local line = f:read("*l")
        if not line then break end
        local version = line:match("^%-%-%s*@version%s+([%w%._%-]+)")
        if version and version ~= "" then
            f:close()
            return version
        end
    end
    f:close()
    return ""
end

local function readAppVersionConstant(path)
    local f = io.open(path, "r")
    if not f then return "" end
    for _ = 1, 140 do
        local line = f:read("*l")
        if not line then break end
        local version = line:match('local%s+APP_VERSION%s*=%s*"([^"]+)"')
        if version and version ~= "" then
            f:close()
            return version
        end
    end
    f:close()
    return ""
end

local function readPackageVersion(rootPath, mainVersion)
    local versionFile = joinPath(rootPath, "VERSION")
    local raw = readFile(versionFile, "rb")
    if raw and trim(raw) ~= "" then
        return trim(raw)
    end
    return mainVersion or ""
end

local function loadPathHelper()
    local ok, mod = pcall(dofile, SCRIPT_DIR .. "_internal/STEMwerk_Path_Helper.lua")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local PATH_HELPER = loadPathHelper()
local INSTALL = PATH_HELPER and PATH_HELPER.resolveInstallRoot(SCRIPT_DIR, { os = OS }) or {
    ok = true,
    root = SCRIPT_DIR,
    scriptsDir = SCRIPT_DIR,
    canonical = "",
    reapack = "",
    status = "fallback",
}

local function getResourcePath()
    if reaper and reaper.GetResourcePath then
        local rp = tostring(reaper.GetResourcePath() or "")
        if rp ~= "" then
            return rp
        end
    end
    if PATH_HELPER and PATH_HELPER.getReaperResourcePath then
        return PATH_HELPER.getReaperResourcePath(OS, PATH_SEP)
    end
    local home = os.getenv(OS == "Windows" and "USERPROFILE" or "HOME") or "/tmp"
    if OS == "Windows" then
        return (os.getenv("APPDATA") or (home .. "\\AppData\\Roaming")) .. "\\REAPER"
    elseif OS == "macOS" then
        return home .. "/Library/Application Support/REAPER"
    end
    return home .. "/.config/REAPER"
end

local function isAbsolutePath(path)
    local value = tostring(path or "")
    if value == "" then return false end
    if value:match("^%a:[/\\]") then return true end
    return value:sub(1, 1) == "/"
end

local function extStateValue(key)
    if reaper and reaper.GetExtState then
        return tostring(reaper.GetExtState(EXT_SECTION, key) or "")
    end
    return ""
end

local function getHome()
    if OS == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

local function detectRuntimeBase()
    local override = trim(extStateValue("runtimeBase"))
    if override ~= "" and isAbsolutePath(override) then
        return override, "extstate"
    end

    local home = getHome()
    local candidates = {}
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then
            candidates[#candidates + 1] = localAppData .. "\\STEMwerk"
        end
    elseif OS == "macOS" then
        candidates[#candidates + 1] = home .. "/Library/Application Support/STEMwerk"
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            candidates[#candidates + 1] = xdg .. "/STEMwerk"
        end
        candidates[#candidates + 1] = home .. "/.local/share/STEMwerk"
    end

    for i = 1, #candidates do
        if pathExists(candidates[i]) then
            return candidates[i], "existing_default"
        end
    end

    return candidates[1] or (home .. PATH_SEP .. ".STEMwerk"), "default_candidate"
end

local function getRuntimePaths(runtimeBase)
    local base = runtimeBase or ""
    local venvDir = joinPath(base, ".venv")
    return {
        base = base,
        runtimeState = joinPath(base, "state"),
        runtimeLogs = joinPath(base, "logs"),
        runtimeCache = joinPath(base, "cache"),
        venvDir = venvDir,
        venvPython = OS == "Windows" and joinPath(venvDir, "Scripts", "python.exe") or joinPath(venvDir, "bin", "python"),
    }
end

local function getModelCacheDir()
    local home = getHome()
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then
            return localAppData .. "\\STEMwerk\\models"
        end
        return home .. "\\AppData\\Local\\STEMwerk\\models"
    elseif OS == "macOS" then
        return home .. "/Library/Application Support/STEMwerk/models"
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            return xdg .. "/STEMwerk/models"
        end
        return home .. "/.local/share/STEMwerk/models"
    end
end

local function resolveCommandOnPath(name)
    if not name or name == "" then return "" end
    if OS == "Windows" then
        local rc, out = execCommand("where.exe", {name}, 5000)
        if rc == 0 and out ~= "" then
            for line in (out:gsub("\r", "")):gmatch("[^\n]+") do
                local candidate = trim(line)
                if candidate:match("^[A-Za-z]:[\\/]") and fileExists(candidate) then
                    return candidate
                end
            end
        end
    else
        local rc, out = execCommand("which", {name}, 5000)
        if rc == 0 and out ~= "" then
            for line in (out:gsub("\r", "")):gmatch("[^\n]+") do
                local candidate = trim(line)
                if candidate:match("^/") and fileExists(candidate) then
                    return candidate
                end
            end
        end
    end
    return ""
end

local function firstUsablePath(candidates)
    local seen = {}
    for i = 1, #candidates do
        local value = trim(candidates[i])
        local key = normalizePath(value)
        if value ~= "" and not seen[key] then
            seen[key] = true
            if not isAbsolutePath(value) then
                return value
            end
            if fileExists(value) or pathExists(value) then
                return value
            end
        end
    end
    return ""
end

local function getTempBase()
    if OS == "Windows" then
        return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    end
    local flatpakId = os.getenv("FLATPAK_ID")
    local container = trim(os.getenv("container"))
    if (flatpakId and flatpakId ~= "") or container:lower():find("flatpak", 1, true) then
        return joinPath(getHome(), ".cache", "STEMwerk")
    end
    return os.getenv("TMPDIR") or "/tmp"
end

-- Returns the persistent run-log directory that SW_LOG writes to after each run.
-- Mirrors SW_LOG.getLogDir() from STEMwerk_Log.lua so the bundle can read it
-- without depending on that module.
local function getStemwerkCacheLogDir()
    if OS == "Windows" then
        local base = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        return joinPath(base, "STEMwerk", "logs")
    end
    local cacheBase = os.getenv("XDG_CACHE_HOME") or joinPath(getHome(), ".cache")
    return joinPath(cacheBase, "STEMwerk", "logs")
end

local function shouldIgnoreTempFolder(name)
    local lower = tostring(name or ""):lower()
    if lower == "" then return true end
    if lower:match("^stemwerk%-support%-bundle%-headless%-") then return true end
    if lower:match("^support%-bundle%-headless%-") then return true end
    if lower:match("^stemwerk[_%-].*support[_%-]bundle[_%-]headless") then return true end
    return false
end

local SUPPORT_SKIP_DIR_NAMES = {
    ["stemwerk-support-bundles"] = true,
    ["support-bundles"] = true,
    ["models"] = true,
    [".venv"] = true,
    ["venv"] = true,
    ["site-packages"] = true,
    ["__pycache__"] = true,
    [".git"] = true,
    ["_bundled"] = true,
    ["wheels"] = true,
    ["wheelhouse"] = true,
    ["cache"] = true,
    ["pip"] = true,
    ["torch"] = true,
    ["checkpoints"] = true,
    ["assets"] = true,
}

local SUPPORT_SKIP_FILE_EXTENSIONS = {
    [".wav"] = true, [".flac"] = true, [".mp3"] = true, [".aiff"] = true, [".aif"] = true,
    [".ogg"] = true, [".m4a"] = true, [".mp4"] = true, [".mov"] = true, [".mkv"] = true,
    [".pth"] = true, [".pt"] = true, [".ckpt"] = true, [".onnx"] = true, [".safetensors"] = true,
    [".whl"] = true, [".zip"] = true, [".7z"] = true, [".tar"] = true, [".gz"] = true, [".xz"] = true,
    [".dll"] = true, [".pyd"] = true, [".exe"] = true, [".msi"] = true, [".iso"] = true,
}

local function shouldSkipSupportDirByName(name)
    local lower = tostring(name or ""):lower()
    if lower == "" then
        return true, "empty-name"
    end
    if SUPPORT_SKIP_DIR_NAMES[lower] then
        return true, "dir-name"
    end
    if lower:match("^stemwerk%-support%-bundle%-") then
        return true, "bundle-dir"
    end
    if lower:match("^support%-bundle%-") then
        return true, "bundle-dir"
    end
    if lower:match("^stemwerk[_%-]mdxc[_%-]matrix") then
        return true, "dev-matrix"
    end
    if lower:match("^stemwerk%-slice%-") then
        return true, "dev-slice"
    end
    return false, ""
end

local function shouldSkipSupportFileByExt(name)
    local lower = tostring(name or ""):lower()
    local ext = lower:match("%.[^%.]+$") or ""
    if ext ~= "" and SUPPORT_SKIP_FILE_EXTENSIONS[ext] then
        return true, ext
    end
    return false, ""
end

local function enumerateSubdirs(path)
    local out = {}
    if not (reaper and reaper.EnumerateSubdirectories) then
        return out
    end
    local idx = 0
    while true do
        local name = reaper.EnumerateSubdirectories(path, idx)
        if not name then break end
        out[#out + 1] = tostring(name)
        idx = idx + 1
    end
    return out
end

local function enumerateFiles(path)
    local out = {}
    if not (reaper and reaper.EnumerateFiles) then
        return out
    end
    local idx = 0
    while true do
        local name = reaper.EnumerateFiles(path, idx)
        if not name then break end
        out[#out + 1] = tostring(name)
        idx = idx + 1
    end
    return out
end

local function getPathStat(path)
    if not path or path == "" then
        return {
            ok = false,
            epoch = 0,
            size = nil,
            sizeLabel = "unavailable (missing path)",
            mtime = "unavailable (missing path)",
            kind = "missing",
            reason = "missing path",
        }
    end

    local kind = fileExists(path) and "file" or (pathExists(path) and "dir" or "missing")
    if kind == "missing" then
        return {
            ok = false,
            epoch = 0,
            size = nil,
            sizeLabel = "unavailable (missing)",
            mtime = "unavailable (missing)",
            kind = kind,
            reason = "missing",
        }
    end

    local rc, out
    if OS == "Windows" then
        local literal = tostring(path):gsub("'", "''")
        rc, out = execPowerShell(
            "$item = Get-Item -LiteralPath '" .. literal .. "' -ErrorAction Stop; " ..
            "Write-Output ([DateTimeOffset]$item.LastWriteTime).ToUnixTimeSeconds(); " ..
            "if ($item.PSIsContainer) { Write-Output 0 } else { Write-Output $item.Length }",
            5000
        )
    elseif OS == "macOS" then
        rc, out = execCommand("stat", {"-f", "%m\n%z", path}, 5000)
    else
        rc, out = execCommand("stat", {"-c", "%Y\n%s", path}, 5000)
    end

    if rc ~= 0 or trim(out) == "" then
        local fallbackSize = (kind == "file") and fileSizeBytes(path) or nil
        local reason = "stat failed"
        if rc == 124 then
            reason = "stat timed out"
        elseif rc ~= 0 then
            reason = "stat failed (exit " .. tostring(rc) .. ")"
        end
        return {
            ok = false,
            epoch = 0,
            size = fallbackSize,
            sizeLabel = fallbackSize and humanBytes(fallbackSize) or ("unavailable (" .. reason .. ")"),
            mtime = "unavailable (" .. reason .. ")",
            kind = kind,
            reason = reason,
        }
    end

    local lines = {}
    for line in tostring(out):gmatch("[^\r\n]+") do
        lines[#lines + 1] = trim(line)
    end
    local epoch = tonumber(lines[1]) or 0
    local size = tonumber(lines[2])
    if kind == "dir" then
        size = nil
    elseif size == nil or size < 0 then
        size = fileSizeBytes(path)
    end
    local mtime = epoch > 0 and os.date("%Y-%m-%d %H:%M:%S", epoch) or "unavailable (invalid timestamp)"
    return {
        ok = epoch > 0 or size ~= nil,
        epoch = epoch,
        size = size,
        sizeLabel = (kind == "dir") and "-" or (size and humanBytes(size) or "unavailable (size probe failed)"),
        mtime = mtime,
        kind = kind,
        reason = (epoch > 0 or size ~= nil) and "" or "stat returned incomplete metadata",
    }
end

local function copySupportTextFile(src, dst, maxBytes)
    maxBytes = tonumber(maxBytes) or (512 * 1024)
    local f = io.open(src, "rb")
    if not f then return false, "missing" end
    local size = f:seek("end") or 0
    f:seek("set", 0)

    local data
    if size <= maxBytes then
        data = f:read("*a") or ""
    else
        local headBytes = math.floor(maxBytes * 0.60)
        local tailBytes = math.max(0, maxBytes - headBytes)
        local head = f:read(headBytes) or ""
        local tail = ""
        if tailBytes > 0 and size > tailBytes then
            f:seek("end", -tailBytes)
            tail = f:read("*a") or ""
        end
        data = table.concat({
            "[STEMwerk support bundle] File truncated to keep the bundle small.\n",
            "Original size: " .. tostring(size) .. " bytes\n",
            "Included: first " .. tostring(#head) .. " bytes and last " .. tostring(#tail) .. " bytes\n",
            "----- BEGIN HEAD -----\n",
            head,
            "\n----- END HEAD -----\n",
            "----- BEGIN TAIL -----\n",
            tail,
            "\n----- END TAIL -----\n",
        })
    end
    f:close()
    data = sanitizeTextContent(data)
    ensureDir(stripTrailingSep(dst):match("^(.*)[/\\][^/\\]+$") or "")
    return writeFile(dst, data, "wb"), size > maxBytes and "truncated" or "copied"
end

local function appendLine(lines, text)
    lines[#lines + 1] = tostring(text or "")
end

local function appendKey(lines, key, value)
    appendLine(lines, string.format("%-28s %s", tostring(key) .. ":", tostring(value or "missing")))
end

local function modelModeLabel(model)
    if model == "htdemucs_ft" then return "Quality" end
    if model == "htdemucs_6s" then return "6-Stem" end
    return "Fast"
end

local function boolLabel(value)
    return value and "true" or "false"
end

local function shortRuntimeGpuName(name)
    local s = trim(name)
    if s == "" then return "" end
    local first = s:match("^([^|,;]+)") or s
    first = trim(first)
    first = first:gsub("^AMD Radeon%s+", "")
    local lower = first:lower()
    if lower:find("rx9070", 1, true) or lower:find("gfx1201", 1, true) then
        return "RX 9070"
    end
    return first
end

local function countDelimitedValues(value)
    local raw = trim(value)
    if raw == "" or raw == "unknown" then return nil end
    local direct = tonumber(raw:match("(%d+)"))
    if direct then return direct end
    local count = 0
    for token in raw:gmatch("[^,|]+") do
        if trim(token) ~= "" then
            count = count + 1
        end
    end
    return count > 0 and count or nil
end

local function joinStringList(values)
    if type(values) ~= "table" or #values == 0 then return "" end
    local out = {}
    for i = 1, #values do
        local v = trim(values[i])
        if v ~= "" then
            out[#out + 1] = v
        end
    end
    return table.concat(out, ",")
end

local function expectedNormalStemNamesForModel(model)
    local lower = trim(model):lower()
    if lower == "htdemucs_6s" then
        return { "vocals", "drums", "bass", "other", "guitar", "piano" }
    end
    return { "vocals", "drums", "bass", "other" }
end

local function detectStemNamesFromText(text, stemNames)
    local lower = tostring(text or ""):lower()
    if lower == "" or type(stemNames) ~= "table" then return {} end
    local found = {}
    local seen = {}
    for i = 1, #stemNames do
        local stem = trim(stemNames[i]):lower()
        if stem ~= "" and not seen[stem] then
            local basenamePattern = "[/\\]" .. stem:gsub("%-", "%%-") .. "%.wav"
            local jsonKeyPattern = '"' .. stem:gsub("%-", "%%-") .. '"%s*:'
            local summaryPattern = "%f[%a]" .. stem:gsub("%-", "%%-") .. "%s*:%s*.+[/\\]" .. stem:gsub("%-", "%%-") .. "%.wav"
            if lower:match(basenamePattern) or lower:match(jsonKeyPattern) or lower:match(summaryPattern) then
                found[#found + 1] = stem
                seen[stem] = true
            end
        end
    end
    return found
end

local function detectStemNamesFromFiles(jobDir, stemNames)
    local fileNames = enumerateFiles(jobDir)
    if #fileNames == 0 or type(stemNames) ~= "table" then return {} end
    local found = {}
    local seen = {}
    local byFile = {}
    for i = 1, #fileNames do
        byFile[tostring(fileNames[i] or ""):lower()] = true
    end
    for i = 1, #stemNames do
        local stem = trim(stemNames[i]):lower()
        local fileName = stem ~= "" and (stem .. ".wav") or ""
        if fileName ~= "" and byFile[fileName] and not seen[stem] then
            found[#found + 1] = stem
            seen[stem] = true
        end
    end
    return found
end

local function maybeInferSingleNormalStemOutputs(entry, jobDir, stdoutData, sepData)
    if tonumber(entry.jobs or 0) ~= 1 then return end
    local workflowSource = trim(entry.workflow_source or ""):lower()
    local workflowMode = trim(entry.workflow_mode or ""):lower()
    if workflowSource == "dks_direct" or workflowSource == "dks_extract" or workflowMode == "drumkit" then
        return
    end

    local expectedStemNames = expectedNormalStemNamesForModel(entry.model)
    if tostring(entry.expected_stems or "unknown") == "unknown" then
        entry.expected_stems = joinStringList(expectedStemNames)
    end

    if tostring(entry.found_stems or "unknown") == "unknown" then
        local foundStemNames = detectStemNamesFromText(stdoutData, expectedStemNames)
        if #foundStemNames == 0 then
            foundStemNames = detectStemNamesFromText(sepData, expectedStemNames)
        end
        if #foundStemNames == 0 then
            foundStemNames = detectStemNamesFromFiles(jobDir, expectedStemNames)
        end
        if #foundStemNames > 0 then
            entry.found_stems = joinStringList(foundStemNames)
        end
    end

    if tostring(entry.found_files or "unknown") == "unknown" and tostring(entry.found_stems or "unknown") ~= "unknown" then
        entry.found_files = tostring(entry.found_stems)
    end

    local expectedCount = countDelimitedValues(entry.expected_stems)
    local foundCount = countDelimitedValues(entry.found_stems) or countDelimitedValues(entry.found_files)
    local hasExitZero = tonumber(entry._sawExitZero or 0) > 0
    local hasDoneSuccess = tonumber(entry._sawDoneSuccess or 0) > 0
    if expectedCount and foundCount and expectedCount == foundCount and hasExitZero and hasDoneSuccess then
        if tostring(entry.output_validation_reason or "unknown") == "unknown" then
            entry.output_validation_reason = "ok"
        end
    end
end

-- Normalizes an evidence value for `or`-fallback chains: nil, "", and the
-- literal placeholder "unknown" (a real, commonly-persisted default value in
-- this codebase, not just an absent value) all become nil/absent. Without
-- this, `a or b` in Lua returns the truthy literal string "unknown" held in
-- `a` and never falls through to a real value held in `b`.
local function presentValue(value)
    local v = trim(value or "")
    if v == "" or v:lower() == "unknown" then return nil end
    return v
end

-- PyTorch ROCm builds also expose cuda-style device notation (cuda:0, etc),
-- so "cuda:N" alone is not proof of NVIDIA. Current-run HIP/ROCm evidence
-- (backend markers, torch.version.hip, or an AMD GPU/device name seen in
-- this run) must be checked and take priority over that notation.
--
-- Classification uses ONLY this specific run's own evidence (the `entry`
-- table). The global/shared runtimeState (bootstrap.env/capabilities.env,
-- common to every run in the bundle) must never be consulted here: it can
-- be stale relative to this particular run (a prior ROCm install, a
-- different run's backend, etc.), and mixing it in risks reclassifying an
-- unrelated current run by leftover global state.
local function currentRunHasRocmEvidence(entry)
    local e = entry or {}
    local runtimeSelected = trim(presentValue(e.runtime_selected) or presentValue(e.backend_runtime) or ""):lower()
    if runtimeSelected == "rocm" then return true end
    if trim(presentValue(e.drumsep_helper_backend_runtime) or ""):lower() == "rocm" then return true end
    local hip = trim(presentValue(e.torch_hip_version) or presentValue(e.hip_version) or ""):lower()
    if hip ~= "" and hip ~= "null" and hip ~= "none" and hip ~= "missing" then
        return true
    end
    local name = trim(presentValue(e.device_name) or presentValue(e.deviceName) or ""):lower()
    if name ~= "" and (name:find("amd", 1, true) or name:find("radeon", 1, true) or name:find("rx ", 1, true)
        or name:find("rx9", 1, true) or name:find("gfx1", 1, true)) then
        return true
    end
    return false
end

local function friendlyDeviceLabel(rawDevice, runtimeState, entry)
    local raw = trim(rawDevice)
    local lower = raw:lower()
    local state = runtimeState or {}
    local runtimeSelected = trim(presentValue(entry and entry.runtime_selected) or presentValue(entry and entry.backend_runtime) or ""):lower()
    if lower == "" then return "unknown" end
    if lower == "cpu" then return "CPU" end
    if lower:find("directml", 1, true) then return "DirectML" end
    if lower == "mps" then return "Apple MPS" end
    local looksLikeCudaNotation = lower:match("^cuda:%d+") ~= nil or lower == "cuda"
    local nvidiaVendorText = lower:find("nvidia", 1, true) or lower:find("geforce", 1, true)
        or lower:find("rtx", 1, true) or lower:find("gtx", 1, true)
    local entryDeviceName = trim(presentValue(entry and entry.device_name) or presentValue(entry and entry.deviceName) or ""):lower()
    local entryHasNvidiaVendorText = entryDeviceName ~= "" and (entryDeviceName:find("nvidia", 1, true)
        or entryDeviceName:find("geforce", 1, true) or entryDeviceName:find("rtx", 1, true) or entryDeviceName:find("gtx", 1, true))
    local looksLikeCuda = looksLikeCudaNotation or nvidiaVendorText
    local isRocm = runtimeSelected == "rocm" or lower == "rocm"
        or (looksLikeCuda and currentRunHasRocmEvidence(entry))
    if isRocm then
        -- Prefer this run's own device name; only fall back to the shared
        -- global runtimeState for a cosmetic display name (classification
        -- above is already decided from run-scoped evidence only).
        local entryName = trim((entry and (entry.device_name or entry.deviceName)) or "")
        if entryName ~= "" then
            local short = shortRuntimeGpuName(entryName)
            if short ~= "" then
                return "AMD ROCm (" .. short .. ")"
            end
        end
        local candidates = {
            trim(state.ROCM_DETECTED_DEVICES or ""),
            trim(state.DRUMSEP_ROCM_DEVICE_NAMES or ""),
            trim(state.DRUMSEP_DEVICE_NAMES or ""),
            trim(state.ROCM_SELECTED_DEVICE or ""),
        }
        for _, candidate in ipairs(candidates) do
            if candidate ~= "" then
                local short = shortRuntimeGpuName(candidate)
                if short ~= "" then
                    return "AMD ROCm (" .. short .. ")"
                end
            end
        end
        return "AMD ROCm"
    end
    if looksLikeCuda then
        if nvidiaVendorText or entryHasNvidiaVendorText then
            return "NVIDIA CUDA"
        end
        -- Bare "cuda:N" notation with no ROCm evidence AND no NVIDIA vendor
        -- evidence (device name, etc.) is genuinely ambiguous -- PyTorch
        -- ROCm builds can also emit cuda-style notation. Do not guess.
        return "ambiguous accelerator (cuda notation, no vendor evidence)"
    end
    if lower:find("radeon", 1, true) or lower:find("amd", 1, true) or lower:find("hip", 1, true) then
        return "AMD ROCm"
    end
    if lower:find("gpu", 1, true) then
        return "GPU"
    end
    return raw
end

local function workflowSummaryLabel(entry)
    local source = trim((entry and entry.workflow_source) or ""):lower()
    local mode = trim((entry and entry.workflow_mode) or ""):lower()
    if source == "dks_direct" then return "Direct Kit" end
    if source == "dks_extract" then return "Kit Split" end
    if mode == "drumkit" then return "Drum Kit" end
    return "Stems"
end

local function drumsepSemanticModel(entry)
    local e = entry or {}
    return trim(e.drumsep_model_id or "") ~= "" and e.drumsep_model_id
        or (trim(e.drumsep_requested_model or "") ~= "" and e.drumsep_requested_model)
        or (trim(e.drumsep_helper_model or "") ~= "" and e.drumsep_helper_model)
        or "unknown"
end

-- Generic entry.model (the last "model=" seen anywhere in a run's logs) is
-- not flow-aware: Direct Kit only ever runs DrumSep, and Kit Split runs a
-- Demucs pass (stage 1) followed by DrumSep (stage 2). Reporting entry.model
-- unqualified for these flows can attach an unrelated Demucs model to a
-- DrumSep-only run, or collapse a two-stage run into a single wrong model.
-- This resolves the single human-readable "semantic model" for a run,
-- matching what actually executed for that flow.
local function semanticModelLabel(entry)
    local source = trim((entry and entry.workflow_source) or ""):lower()
    if source == "dks_direct" then
        return drumsepSemanticModel(entry)
    end
    if source == "dks_extract" then
        local stage1 = trim((entry and entry.model) or "") ~= "" and entry.model or "unknown"
        local stage2 = drumsepSemanticModel(entry)
        return "stage1:" .. tostring(stage1) .. " -> stage2:" .. tostring(stage2) .. " (DrumSep)"
    end
    return tostring((entry and entry.model) or "unknown")
end

local function statusSummaryLabel(entry)
    local result = trim((entry and entry.result) or ""):lower()
    local errorClass = trim((entry and entry.error_class) or ""):lower()
    if result == "success" then return "PASS" end
    if result == "partial" then return "PARTIAL" end
    if result == "cancelled" then return "CANCELLED" end
    if result == "fail" and errorClass:find("^model_", 1, true) then
        return "MODEL ISSUE"
    end
    if result == "fail" then return "FAILED" end
    return "UNKNOWN"
end

local function requestedDeviceRaw(entry)
    -- Fields default to the literal string "unknown", which is truthy in
    -- Lua -- a plain `or` chain would stop at the first field that was ever
    -- initialized, even though it holds no real value. presentValue()
    -- filters those out so a later field with a real value is not
    -- suppressed by an earlier field that only ever held the placeholder.
    return presentValue(entry and entry.requested_device)
        or presentValue(entry and entry.ui_device_selected_before_run)
        or presentValue(entry and entry.backend_device_arg)
        or presentValue(entry and entry.drumsep_helper_requested_device)
        or presentValue(entry and entry.drumsep_helper_device_arg)
        or presentValue(entry and entry.selected_device)
        or presentValue(entry and entry.device)
        or ""
end

local function requestedDeviceSummaryLabel(entry, runtimeState)
    local requested = requestedDeviceRaw(entry)
    local lower = requested:lower()
    if lower == "" or lower == "unknown" then return "unknown" end
    if lower == "auto" then return "Auto" end
    return friendlyDeviceLabel(requested, runtimeState, entry)
end

local function effectiveDeviceRaw(entry)
    -- Same "unknown" truthiness hazard as requestedDeviceRaw above: use
    -- presentValue() so a placeholder "unknown" field never suppresses a
    -- later field that holds this run's actual effective-execution
    -- evidence (e.g. backend_runtime/runtime_selected reflecting a
    -- fallback that effective_device itself never explicitly recorded).
    --
    -- drumsep_helper_device_arg is deliberately EXCLUDED from this chain:
    -- it is the argument passed TO the helper (a request), not evidence of
    -- what actually executed. A helper requested with --device mps that
    -- the runtime then ran on CPU (backend_runtime/runtime_selected=cpu)
    -- must never be shown as the active/effective device -- that argument
    -- is provenance only (see requestedDeviceRaw / "Requested device:").
    return presentValue(entry and entry.effective_device)
        or presentValue(entry and entry.drumsep_helper_device)
        or presentValue(entry and entry.backend_runtime)
        or presentValue(entry and entry.runtime_selected)
        or presentValue(entry and entry.device)
        or ""
end

local function effectiveDeviceSummaryLabel(entry, runtimeState)
    local effective = effectiveDeviceRaw(entry)
    local lower = effective:lower()
    if lower == "" or lower == "unknown" then return "unknown" end
    return friendlyDeviceLabel(effective, runtimeState, entry)
end

local function summaryDeviceLabel(entry, runtimeState)
    local effective = effectiveDeviceRaw(entry)
    if effective ~= "" and effective:lower() ~= "unknown" then
        return friendlyDeviceLabel(effective, runtimeState, entry)
    end
    local requested = requestedDeviceRaw(entry)
    if requested ~= "" and requested:lower() ~= "unknown" then
        return friendlyDeviceLabel(requested, runtimeState, entry)
    end
    return tostring((entry and entry.friendly_device) or "unknown")
end

local function outputCountSummaryLabel(entry)
    local expected = countDelimitedValues(entry and entry.expected_stems)
    local found = countDelimitedValues(entry and entry.found_stems) or countDelimitedValues(entry and entry.found_files)
    if expected and found then
        return string.format("%d/%d", found, expected)
    end
    if found then
        return tostring(found)
    end
    return "unknown"
end

local function cpuFallbackSummaryLabel(entry)
    local requested = trim((entry and entry.requested_device) or ""):lower()
    local runtimeSelected = trim((entry and entry.runtime_selected) or ""):lower()
    local backendRuntime = trim((entry and entry.backend_runtime) or ""):lower()
    local effectiveDevice = trim((entry and entry.effective_device) or ""):lower()
    local mpsFallbackUsed = trim((entry and entry.mps_fallback_used) or ""):lower()
    if mpsFallbackUsed == "1" or mpsFallbackUsed == "true" then
        return "CPU fallback (supported, slower)"
    end
    if requested ~= "" and requested ~= "unknown" and requested ~= "cpu"
        and (runtimeSelected == "cpu" or backendRuntime == "cpu" or effectiveDevice == "cpu") then
        return "CPU fallback (supported, slower)"
    end
    return nil
end

local function appendLatestRunSummary(lines, entry, runtimeState)
    lines[#lines + 1] = "Latest run summary:"
    lines[#lines + 1] = "Status: " .. statusSummaryLabel(entry)
    lines[#lines + 1] = "Workflow: " .. workflowSummaryLabel(entry)
    lines[#lines + 1] = "Model: " .. semanticModelLabel(entry)
    lines[#lines + 1] = "Device: " .. summaryDeviceLabel(entry, runtimeState)
    lines[#lines + 1] = "Requested device: " .. requestedDeviceSummaryLabel(entry, runtimeState)
    lines[#lines + 1] = "Runtime: " .. tostring(entry.runtime_selected or "unknown")
    lines[#lines + 1] = "Backend runtime: " .. tostring(entry.backend_runtime or "unknown")
    lines[#lines + 1] = "Effective device: " .. effectiveDeviceSummaryLabel(entry, runtimeState)
    lines[#lines + 1] = "Outputs: " .. outputCountSummaryLabel(entry)
    lines[#lines + 1] = "Exit code: " .. tostring(entry.exit_code or "unknown")
    lines[#lines + 1] = "Output validation: " .. tostring(entry.output_validation_reason or "unknown")
    local fallback = cpuFallbackSummaryLabel(entry)
    if fallback then
        lines[#lines + 1] = "Fallback: " .. fallback
    end
    if trim(tostring(entry.error_reason or "")) ~= "" and tostring(entry.error_reason or "unknown") ~= "unknown" then
        lines[#lines + 1] = "Reason: " .. tostring(entry.error_reason)
    end
    lines[#lines + 1] = ""
end

local function extBool(key)
    return trim(extStateValue(key)) == "1"
end

local mainScriptPath = joinPath(INSTALL.scriptsDir or SCRIPT_DIR, "STEMwerk.lua")
local setupScriptPath = joinPath(INSTALL.scriptsDir or SCRIPT_DIR, "STEMwerk-SETUP.lua")
local packageVersion = readPackageVersion(INSTALL.root or SCRIPT_DIR, readVersionHeader(mainScriptPath))
local mainHeaderVersion = readVersionHeader(mainScriptPath)
local mainAppVersion = readAppVersionConstant(mainScriptPath)
local setupVersion = readVersionHeader(setupScriptPath)

local runtimeBase, runtimeBaseSource = detectRuntimeBase()
local runtimePaths = getRuntimePaths(runtimeBase)
local bootstrapEnvPath = joinPath(runtimePaths.runtimeState, "bootstrap.env")
local capabilitiesEnvPath = joinPath(runtimePaths.runtimeState, "capabilities.env")
local bootstrapPidPath = joinPath(runtimePaths.runtimeState, "bootstrap.pid")
local bootstrapGuardPath = joinPath(runtimePaths.runtimeState, "bootstrap.guard")
local runtimeState = readEnvFile(bootstrapEnvPath)
local capabilityState = readEnvFile(capabilitiesEnvPath)
local capabilityBootstrapStatus = trim(capabilityState.BOOTSTRAP_STATUS or "")
local runtimeBootstrapStatus = trim(runtimeState.STATUS or "")
local capabilityVerification = trim(capabilityState.VERIFICATION or "")
local capabilityStaleFailedVerification = (
    runtimeBootstrapStatus == "ok"
    and (capabilityBootstrapStatus == "" or capabilityBootstrapStatus == "ok")
    and capabilityVerification == "failed"
)

local function resolvedCapabilityValue(key, fallback)
    local value = trim(capabilityState[key] or "")
    if capabilityStaleFailedVerification and (
        key == "VERIFICATION"
        or key == "RUNTIME_DRIFT_DETECTED"
        or key == "RUNTIME_DRIFT_REASON"
        or key == "TORCH_SUPPORTED"
        or key == "TORCH_VERSION"
        or key == "TORCHAUDIO_VERSION"
    ) then
        value = ""
    end
    if value ~= "" then
        return value
    end
    return trim(fallback or "")
end

local pythonPathCandidates = {
    capabilityState.PYTHON_PATH,
    runtimeState.PYTHON_PATH,
    runtimeState.VENV_PYTHON,
    extStateValue("pythonPath"),
    runtimePaths.venvPython,
}
if OS ~= "Windows" then
    pythonPathCandidates[#pythonPathCandidates + 1] = resolveCommandOnPath("python3")
    pythonPathCandidates[#pythonPathCandidates + 1] = resolveCommandOnPath("python")
end
local detectedPythonPath = firstUsablePath(pythonPathCandidates)

local ffmpegPathCandidates = {
    capabilityState.FFMPEG_PATH,
    runtimeState.FFMPEG_PATH,
    extStateValue("ffmpegPath"),
}
if OS ~= "Windows" then
    ffmpegPathCandidates[#ffmpegPathCandidates + 1] = resolveCommandOnPath("ffmpeg")
end
local detectedFfmpegPath = firstUsablePath(ffmpegPathCandidates)

local function detectReaPackVersion(resourcePath)
    local direct = reaper and reaper.ReaPack_GetVersion
    if type(direct) == "function" then
        local ok, value = pcall(direct)
        if ok and trim(value) ~= "" then
            return trim(value), true
        end
    end

    local iniCandidates = {
        joinPath(resourcePath, "reapack.ini"),
        joinPath(resourcePath, "reaper-reapack.ini"),
        joinPath(resourcePath, "UserPlugins", "reapack.ini"),
    }
    for i = 1, #iniCandidates do
        local raw = readFile(iniCandidates[i], "rb")
        if raw then
            local version = raw:match("[Vv]ersion%s*=%s*([%w%._%-]+)")
            if version and version ~= "" then
                return version, true
            end
        end
    end

    local pluginsDir = joinPath(resourcePath, "UserPlugins")
    local pluginFound = false
    for _, file in ipairs(enumerateFiles(pluginsDir)) do
        if tostring(file):lower():find("reapack", 1, true) then
            pluginFound = true
            break
        end
    end

    if pluginFound then
        return "installed (version not detectable)", false
    end
    return "not detected", false
end

local function getPythonVersion(path)
    if trim(path) == "" then return "missing" end
    if OS == "Windows" then
        return "skipped for speed"
    end
    local rc, out = execCommand(path, {"--version"}, 8000)
    if rc ~= 0 or trim(out) == "" then
        rc, out = execCommand(path, {"-V"}, 8000)
    end
    local line = trim((out:gsub("\r", "")):match("([^\n]+)") or "")
    if line ~= "" then
        return line
    end
    if rc == 124 then
        return "error: timeout"
    end
    return rc ~= 0 and ("error: probe failed (exit " .. tostring(rc) .. ")") or "error: no output"
end

local function getFfmpegVersion(path)
    if trim(path) == "" then return "missing" end
    if OS == "Windows" then
        return "skipped for speed"
    end
    local rc, out = execCommand(path, {"-version"}, 8000)
    local line = trim((out:gsub("\r", "")):match("([^\n]+)") or "")
    if line ~= "" then
        return line
    end
    if rc == 124 then
        return "error: timeout"
    end
    if rc ~= 0 then
        return "error: probe failed (exit " .. tostring(rc) .. ")"
    end
    return "error: no output"
end

local function getPlatformDetails()
    local details = {
        architecture = "undetected",
        osName = OS,
        osVersion = trim(REAPER_OS_RAW) ~= "" and trim(REAPER_OS_RAW) or OS,
        reaperOsRaw = REAPER_OS_RAW,
        extraSummary = {},
        rawBlocks = {},
    }

    if OS == "macOS" then
        local _, swProduct = execCommand("sw_vers", {"-productVersion"}, 5000)
        local _, swBuild = execCommand("sw_vers", {"-buildVersion"}, 5000)
        local _, unameM = execCommand("uname", {"-m"}, 5000)
        local productVersion = trim(swProduct)
        local buildVersion = trim(swBuild)
        local arch = trim(unameM)
        details.architecture = arch ~= "" and arch or "undetected"
        if productVersion ~= "" then
            details.osVersion = "macOS " .. productVersion
        end
        details.extraSummary[#details.extraSummary + 1] = "sw_vers productVersion: " .. (productVersion ~= "" and productVersion or "missing")
        details.extraSummary[#details.extraSummary + 1] = "sw_vers buildVersion: " .. (buildVersion ~= "" and buildVersion or "missing")
        details.extraSummary[#details.extraSummary + 1] = "uname -m: " .. (arch ~= "" and arch or "missing")
        local backend = trim(capabilityState.BACKEND or runtimeState.BACKEND or "")
        local profile
        if arch == "arm64" or arch == "aarch64" then
            profile = "Apple Silicon macOS"
        else
            profile = "Intel macOS CPU fallback"
        end
        if backend ~= "" then
            profile = profile .. " (backend=" .. backend .. ")"
        end
        details.extraSummary[#details.extraSummary + 1] = "detected profile: " .. profile
        details.rawBlocks[#details.rawBlocks + 1] = "[sw_vers -productVersion]\n" .. trim(swProduct)
        details.rawBlocks[#details.rawBlocks + 1] = "[sw_vers -buildVersion]\n" .. trim(swBuild)
        details.rawBlocks[#details.rawBlocks + 1] = "[uname -m]\n" .. trim(unameM)
    elseif OS == "Linux" then
        local _, unameA = execCommand("uname", {"-a"}, 5000)
        local _, unameM = execCommand("uname", {"-m"}, 5000)
        local osRelease = readFile("/etc/os-release", "rb")
        local prettyName = osRelease and (osRelease:match('\nPRETTY_NAME="([^"]+)"') or osRelease:match('^PRETTY_NAME="([^"]+)"')) or ""
        local arch = trim(unameM)
        if arch == "" then
            arch = trim(os.getenv("HOSTTYPE") or os.getenv("MACHTYPE") or "")
        end
        details.architecture = arch ~= "" and arch or "undetected"
        if prettyName ~= "" then
            details.osVersion = prettyName
        end
        details.extraSummary[#details.extraSummary + 1] = "uname -m: " .. (arch ~= "" and arch or "missing")
        details.extraSummary[#details.extraSummary + 1] = "uname -a: " .. trim(unameA)
        details.extraSummary[#details.extraSummary + 1] = "/etc/os-release: " .. (osRelease and "included below" or "missing")
        details.rawBlocks[#details.rawBlocks + 1] = "[uname -m]\n" .. trim(unameM)
        details.rawBlocks[#details.rawBlocks + 1] = "[uname -a]\n" .. trim(unameA)
        details.rawBlocks[#details.rawBlocks + 1] = "[/etc/os-release]\n" .. trim(osRelease or "missing")
    else
        local arch = trim(os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or "")
        details.architecture = arch ~= "" and arch or "undetected"
        details.osVersion = trim(REAPER_OS_RAW) ~= "" and trim(REAPER_OS_RAW) or "Windows"
        details.extraSummary[#details.extraSummary + 1] = "Windows version/build: metadata skipped for speed"
        details.extraSummary[#details.extraSummary + 1] = "CPU architecture: " .. details.architecture
        details.rawBlocks[#details.rawBlocks + 1] = "[windows-version]\nmetadata skipped for speed"
    end

    return details
end

local function runPythonProbe(bundleDir, pythonPath)
    local result = {
        summary = {},
        rawOutput = "",
        status = "missing",
        data = {},
    }
    if OS == "Windows" then
        result.status = "skipped"
        result.summary[#result.summary + 1] = "Python diagnostics: skipped for speed"
        result.rawOutput = "Python diagnostics skipped for speed.\n"
        return result
    end
    if trim(pythonPath) == "" then
        result.summary[#result.summary + 1] = "Python diagnostics: missing (no Python path detected)"
        result.rawOutput = "Python diagnostics missing: no Python path detected.\n"
        return result
    end

    local probeScriptPath = joinPath(bundleDir, "_python_probe.py")
    local probeScript = table.concat({
        "import platform",
        "import sys",
        "import importlib",
        "try:",
        "    from importlib import metadata as importlib_metadata",
        "except Exception:",
        "    import importlib_metadata",
        "",
        "def emit(key, value):",
        "    if isinstance(value, (list, tuple)):",
        "        value = ', '.join(str(v) for v in value)",
        "    elif isinstance(value, bool):",
        "        value = 'true' if value else 'false'",
        "    elif value is None:",
        "        value = ''",
        "    print(f'{key}={value}')",
        "",
        "def dist_version(name):",
        "    try:",
        "        return importlib_metadata.version(name)",
        "    except Exception as exc:",
        "        return f'missing ({type(exc).__name__})'",
        "",
        "def module_version(module_name, dist_name=None):",
        "    try:",
        "        mod = importlib.import_module(module_name)",
        "        version = getattr(mod, '__version__', None)",
        "        if version:",
        "            return version",
        "        if dist_name:",
        "            return dist_version(dist_name)",
        "        return 'imported'",
        "    except Exception as exc:",
        "        if dist_name:",
        "            return f'import_error ({type(exc).__name__}); dist={dist_version(dist_name)}'",
        "        return f'import_error ({type(exc).__name__})'",
        "",
        "emit('python_executable', sys.executable)",
        "emit('python_version', platform.python_version())",
        "emit('numpy', module_version('numpy', 'numpy'))",
        "emit('numba', module_version('numba', 'numba'))",
        "emit('llvmlite', module_version('llvmlite', 'llvmlite'))",
        "emit('torch', module_version('torch', 'torch'))",
        "emit('torchvision', module_version('torchvision', 'torchvision'))",
        "emit('torchaudio', module_version('torchaudio', 'torchaudio'))",
        "emit('audio_separator', module_version('audio_separator', 'audio-separator'))",
        "emit('audio_separator_dist', dist_version('audio-separator'))",
        "emit('onnxruntime', module_version('onnxruntime', 'onnxruntime'))",
        "emit('stemwerk_core', dist_version('stemwerk-core'))",
        "emit('torch_directml', dist_version('torch-directml'))",
        "",
        "try:",
        "    import torch",
        "    emit('torch_cuda_available', torch.cuda.is_available())",
        "    emit('torch_cuda_device_count', torch.cuda.device_count() if torch.cuda.is_available() else 0)",
        "    emit('torch_cuda_version', getattr(getattr(torch, 'version', None), 'cuda', ''))",
        "    emit('torch_hip_version', getattr(getattr(torch, 'version', None), 'hip', ''))",
        "    backends = getattr(torch, 'backends', None)",
        "    mps = getattr(backends, 'mps', None) if backends else None",
        "    emit('torch_mps_built', mps.is_built() if mps and hasattr(mps, 'is_built') else '')",
        "    emit('torch_mps_available', mps.is_available() if mps and hasattr(mps, 'is_available') else '')",
        "except Exception as exc:",
        "    emit('torch_import_error', f'{type(exc).__name__}: {exc}')",
        "",
        "try:",
        "    import onnxruntime as ort",
        "    emit('onnxruntime_providers', ort.get_available_providers())",
        "except Exception as exc:",
        "    emit('onnxruntime_providers_error', f'{type(exc).__name__}: {exc}')",
        "",
        "try:",
        "    import torch_directml as dml",
        "    count = dml.device_count() if hasattr(dml, 'device_count') else 0",
        "    emit('directml_device_count', count)",
        "    if count:",
        "        try:",
        "            emit('directml_device_0', dml.device_name(0))",
        "        except Exception as exc:",
        "            emit('directml_device_0_error', f'{type(exc).__name__}: {exc}')",
        "except Exception as exc:",
        "    emit('torch_directml_import_error', f'{type(exc).__name__}: {exc}')",
        "",
    }, "\n")

    writeFile(probeScriptPath, probeScript, "wb")
    local rc, out = execCommand(pythonPath, {probeScriptPath}, 15000)
    result.rawOutput = out or ""
    result.data = parseKeyValueText(result.rawOutput)
    result.status = (rc == 0 and next(result.data) ~= nil) and "ok" or "failed"
    if fileExists(probeScriptPath) then
        os.remove(probeScriptPath)
    end

    if result.status == "ok" then
        result.summary[#result.summary + 1] = "Python diagnostics: ok"
        result.summary[#result.summary + 1] = "numpy: " .. (result.data.numpy or "missing")
        result.summary[#result.summary + 1] = "numba: " .. (result.data.numba or "missing")
        result.summary[#result.summary + 1] = "llvmlite: " .. (result.data.llvmlite or "missing")
        result.summary[#result.summary + 1] = "torch: " .. (result.data.torch or "missing")
        result.summary[#result.summary + 1] = "torchvision: " .. (result.data.torchvision or "missing")
        result.summary[#result.summary + 1] = "torchaudio: " .. (result.data.torchaudio or "missing")
        result.summary[#result.summary + 1] = "audio-separator: " .. (result.data.audio_separator_dist or result.data.audio_separator or "missing")
        result.summary[#result.summary + 1] = "onnxruntime: " .. (result.data.onnxruntime or "missing")
        if OS == "macOS" then
            result.summary[#result.summary + 1] = "torch MPS built/available: "
                .. tostring(result.data.torch_mps_built or "missing") .. "/"
                .. tostring(result.data.torch_mps_available or "missing")
        end
        if trim(result.data.torch_cuda_version) ~= "" or trim(result.data.torch_cuda_available) ~= "" then
            result.summary[#result.summary + 1] = "CUDA available/version: "
                .. tostring(result.data.torch_cuda_available or "missing") .. "/"
                .. tostring(result.data.torch_cuda_version or "missing")
        end
        if trim(result.data.torch_hip_version) ~= "" then
            result.summary[#result.summary + 1] = "ROCm HIP version: " .. tostring(result.data.torch_hip_version)
        end
        if trim(result.data.onnxruntime_providers) ~= "" then
            result.summary[#result.summary + 1] = "ONNX Runtime providers: " .. tostring(result.data.onnxruntime_providers)
        end
        if trim(result.data.directml_device_count) ~= "" then
            result.summary[#result.summary + 1] = "DirectML device count: " .. tostring(result.data.directml_device_count)
        end
    else
        local reason = (rc == 124) and "timed out" or ("failed (exit " .. tostring(rc) .. ")")
        result.summary[#result.summary + 1] = "Python diagnostics: " .. reason
        if trim(result.rawOutput) == "" then
            result.rawOutput = table.concat({
                "Python diagnostics " .. reason .. ".",
                "Python path: " .. tostring(pythonPath),
                "No output captured.",
                "",
            }, "\n")
        end
        result.summary[#result.summary + 1] = "Python probe output captured in python_diagnostics.txt"
    end

    return result
end

local function readTailText(path, maxBytes)
    local filePath = trim(path)
    if filePath == "" or not fileExists(filePath) then
        return ""
    end
    local cap = math.max(1024, tonumber(maxBytes) or (128 * 1024))
    local size = fileSizeBytes(filePath) or 0
    local f = io.open(filePath, "rb")
    if not f then return "" end
    if size > cap then
        f:seek("end", -cap)
    else
        f:seek("set", 0)
    end
    local data = f:read("*a") or ""
    f:close()
    if size > cap then
        data = "(tail excerpt; file truncated)\n" .. data
    end
    return data
end

local function toLowerSet(values)
    local out = {}
    for i = 1, #(values or {}) do
        out[tostring(values[i]):lower()] = true
    end
    return out
end

local function buildDrumsepRuntimeProbe(runtimePython)
    local result = {}
    local py = trim(runtimePython)
    if py == "" or not fileExists(py) then
        result.error = "python_missing"
        return result
    end
    if OS == "Windows" then
        result.error = "probe_skipped_windows"
        return result
    end

    local script = table.concat({
        "import importlib",
        "import importlib.metadata as metadata",
        "",
        "def emit(k, v):",
        "    if isinstance(v, bool):",
        "        v = 'true' if v else 'false'",
        "    elif isinstance(v, (list, tuple)):",
        "        v = '|'.join(str(x) for x in v)",
        "    elif v is None:",
        "        v = ''",
        "    print(f'{k}={v}')",
        "",
        "def ver(mod_name, dist_name):",
        "    try:",
        "        m = importlib.import_module(mod_name)",
        "        return getattr(m, '__version__', '') or metadata.version(dist_name)",
        "    except Exception as exc:",
        "        return f'error:{type(exc).__name__}'",
        "",
        "emit('audio_separator', ver('audio_separator', 'audio-separator'))",
        "emit('numpy', ver('numpy', 'numpy'))",
        "emit('torch', ver('torch', 'torch'))",
        "emit('onnx', ver('onnx', 'onnx'))",
        "emit('onnxruntime', ver('onnxruntime', 'onnxruntime'))",
        "emit('onnx2torch', ver('onnx2torch', 'onnx2torch'))",
        "try:",
        "    import torch",
        "    emit('torch_version_cuda', getattr(getattr(torch, 'version', None), 'cuda', ''))",
        "    emit('torch_version_hip', getattr(getattr(torch, 'version', None), 'hip', ''))",
        "    emit('torch_cuda_available', torch.cuda.is_available())",
        "    count = torch.cuda.device_count() if torch.cuda.is_available() else 0",
        "    emit('torch_cuda_device_count', count)",
        "    names = []",
        "    if count:",
        "        for i in range(count):",
        "            try:",
        "                names.append(torch.cuda.get_device_name(i))",
        "            except Exception as exc:",
        "                names.append(f'error:{type(exc).__name__}')",
        "    emit('torch_device_names', names)",
        "except Exception as exc:",
        "    emit('torch_error', f'{type(exc).__name__}:{exc}')",
        "try:",
        "    import onnxruntime as ort",
        "    emit('onnxruntime_providers', ort.get_available_providers())",
        "except Exception as exc:",
        "    emit('onnxruntime_providers_error', f'{type(exc).__name__}:{exc}')",
    }, "\n")

    local probePath = joinPath(runtimePaths.base, "state", "_drumsep_support_probe.py")
    if not writeFile(probePath, script, "wb") then
        result.error = "probe_script_write_failed"
        return result
    end
    local rc, out = execCommand(py, {probePath}, 12000)
    if fileExists(probePath) then os.remove(probePath) end
    result.rc = rc
    result.output = out or ""
    result.data = parseKeyValueText(result.output)
    if rc ~= 0 then
        result.error = "probe_failed_exit_" .. tostring(rc)
    end
    return result
end

local function appendDrumsepRuntimeBlock(lines, title, runtimePython, stateData, probe, modelFile, modelYaml)
    appendLine(lines, title)
    appendKey(lines, "python_path", sanitizePathValue(runtimePython))
    appendKey(lines, "python_exists", fileExists(runtimePython) and "yes" or "no")
    appendKey(lines, "runtime_status", trim(stateData.STATUS or stateData.DRUMSEP_CUDA_RUNTIME_STATUS or stateData.DRUMSEP_DIRECTML_RUNTIME_STATUS or stateData.DRUMSEP_RUNTIME_STATUS or stateData.DRUMSEP_ROCM_RUNTIME_STATUS) ~= "" and trim(stateData.STATUS or stateData.DRUMSEP_CUDA_RUNTIME_STATUS or stateData.DRUMSEP_DIRECTML_RUNTIME_STATUS or stateData.DRUMSEP_RUNTIME_STATUS or stateData.DRUMSEP_ROCM_RUNTIME_STATUS) or "unknown")
    appendKey(lines, "runtime_reason", trim(stateData.STATUS_REASON or stateData.DRUMSEP_CUDA_RUNTIME_DETAIL or stateData.DRUMSEP_DIRECTML_RUNTIME_DETAIL or stateData.DRUMSEP_RUNTIME_DETAIL or stateData.DRUMSEP_ROCM_RUNTIME_DETAIL) ~= "" and trim(stateData.STATUS_REASON or stateData.DRUMSEP_CUDA_RUNTIME_DETAIL or stateData.DRUMSEP_DIRECTML_RUNTIME_DETAIL or stateData.DRUMSEP_RUNTIME_DETAIL or stateData.DRUMSEP_ROCM_RUNTIME_DETAIL) or "unknown")
    if probe and probe.data then
        appendKey(lines, "audio_separator_version", probe.data.audio_separator or "unknown")
        appendKey(lines, "numpy_version", probe.data.numpy or "unknown")
        appendKey(lines, "torch_version", probe.data.torch or "unknown")
        appendKey(lines, "torch.version.cuda", probe.data.torch_version_cuda or "unknown")
        appendKey(lines, "torch.version.hip", probe.data.torch_version_hip or "unknown")
        appendKey(lines, "torch.cuda.is_available", probe.data.torch_cuda_available or "unknown")
        appendKey(lines, "torch.cuda.device_count", probe.data.torch_cuda_device_count or "unknown")
        appendKey(lines, "torch_device_names", probe.data.torch_device_names or "unknown")
        appendKey(lines, "onnx_version", probe.data.onnx or "unknown")
        appendKey(lines, "onnxruntime_version", probe.data.onnxruntime or "unknown")
        appendKey(lines, "onnxruntime_providers", probe.data.onnxruntime_providers or probe.data.onnxruntime_providers_error or "unknown")
        appendKey(lines, "onnx2torch_version", probe.data.onnx2torch or "unknown")
        if trim(probe.error or "") ~= "" then
            appendKey(lines, "probe_error", probe.error)
        end
    else
        appendKey(lines, "probe_status", "not_run")
        appendKey(lines, "diagnostic_source", "cached_state")
        appendKey(lines, "audio_separator_version", trim(stateData.DRUMSEP_CUDA_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_DIRECTML_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_ROCM_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_AUDIO_SEPARATOR_VERSION or "") ~= "" and trim(stateData.DRUMSEP_CUDA_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_DIRECTML_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_ROCM_AUDIO_SEPARATOR_VERSION or stateData.DRUMSEP_AUDIO_SEPARATOR_VERSION or "") or "unknown")
        appendKey(lines, "numpy_version", trim(stateData.DRUMSEP_DIRECTML_NUMPY_VERSION or stateData.DRUMSEP_ROCM_NUMPY_VERSION or stateData.DRUMSEP_NUMPY_VERSION or "") ~= "" and trim(stateData.DRUMSEP_DIRECTML_NUMPY_VERSION or stateData.DRUMSEP_ROCM_NUMPY_VERSION or stateData.DRUMSEP_NUMPY_VERSION or "") or "unknown")
        appendKey(lines, "torch_version", trim(stateData.DRUMSEP_CUDA_TORCH_VERSION or stateData.DRUMSEP_DIRECTML_TORCH_VERSION or stateData.DRUMSEP_ROCM_TORCH_VERSION or stateData.DRUMSEP_TORCH_VERSION or "") ~= "" and trim(stateData.DRUMSEP_CUDA_TORCH_VERSION or stateData.DRUMSEP_DIRECTML_TORCH_VERSION or stateData.DRUMSEP_ROCM_TORCH_VERSION or stateData.DRUMSEP_TORCH_VERSION or "") or "unknown")
        appendKey(lines, "torch.version.hip", trim(stateData.DRUMSEP_ROCM_TORCH_HIP or stateData.DRUMSEP_TORCH_HIP or "") ~= "" and trim(stateData.DRUMSEP_ROCM_TORCH_HIP or stateData.DRUMSEP_TORCH_HIP or "") or "unknown")
        appendKey(lines, "torch.cuda.is_available", trim(stateData.TORCH_CUDA_STATUS or stateData.DRUMSEP_ROCM_CUDA_AVAILABLE or stateData.DRUMSEP_CUDA_AVAILABLE or "") ~= "" and trim(stateData.TORCH_CUDA_STATUS or stateData.DRUMSEP_ROCM_CUDA_AVAILABLE or stateData.DRUMSEP_CUDA_AVAILABLE or "") or "unknown")
        appendKey(lines, "torch_device_names", trim(stateData.CUDA_DEVICE or stateData.DRUMSEP_ROCM_DEVICE_NAMES or stateData.DRUMSEP_DEVICE_NAMES or "") ~= "" and trim(stateData.CUDA_DEVICE or stateData.DRUMSEP_ROCM_DEVICE_NAMES or stateData.DRUMSEP_DEVICE_NAMES or "") or "unknown")
        appendKey(lines, "onnx_version", trim(stateData.DRUMSEP_DIRECTML_ONNX_VERSION or stateData.DRUMSEP_ROCM_ONNX_VERSION or stateData.DRUMSEP_ONNX_VERSION or "") ~= "" and trim(stateData.DRUMSEP_DIRECTML_ONNX_VERSION or stateData.DRUMSEP_ROCM_ONNX_VERSION or stateData.DRUMSEP_ONNX_VERSION or "") or "unknown")
        appendKey(lines, "onnxruntime_version", trim(stateData.DRUMSEP_CUDA_ONNXRUNTIME_GPU_VERSION or stateData.DRUMSEP_DIRECTML_ONNXRUNTIME_DIRECTML_VERSION or stateData.DRUMSEP_ROCM_ONNXRUNTIME_VERSION or stateData.DRUMSEP_ONNXRUNTIME_VERSION or "") ~= "" and trim(stateData.DRUMSEP_CUDA_ONNXRUNTIME_GPU_VERSION or stateData.DRUMSEP_DIRECTML_ONNXRUNTIME_DIRECTML_VERSION or stateData.DRUMSEP_ROCM_ONNXRUNTIME_VERSION or stateData.DRUMSEP_ONNXRUNTIME_VERSION or "") or "unknown")
        appendKey(lines, "onnx2torch_version", trim(stateData.DRUMSEP_DIRECTML_ONNX2TORCH_VERSION or stateData.DRUMSEP_ROCM_ONNX2TORCH_VERSION or stateData.DRUMSEP_ONNX2TORCH_VERSION or "") ~= "" and trim(stateData.DRUMSEP_DIRECTML_ONNX2TORCH_VERSION or stateData.DRUMSEP_ROCM_ONNX2TORCH_VERSION or stateData.DRUMSEP_ONNX2TORCH_VERSION or "") or "unknown")
        if trim(stateData.CUDA_DEVICE_ID or "") ~= "" then
            appendKey(lines, "cuda_device_id", trim(stateData.CUDA_DEVICE_ID or ""))
        end
        if trim(stateData.ORT_CUDA_PROVIDER or "") ~= "" then
            appendKey(lines, "ort_cuda_provider", trim(stateData.ORT_CUDA_PROVIDER or ""))
        end
        if trim(stateData.ORT_AVAILABLE_PROVIDERS or "") ~= "" then
            appendKey(lines, "ort_available_providers", trim(stateData.ORT_AVAILABLE_PROVIDERS or ""))
        end
        if trim(stateData.FFMPEG_STATUS or "") ~= "" then
            appendKey(lines, "ffmpeg_status", trim(stateData.FFMPEG_STATUS or ""))
        end
        if trim(stateData.FFMPEG_PATH or "") ~= "" then
            appendKey(lines, "ffmpeg_path", sanitizePathValue(stateData.FFMPEG_PATH))
        end
        if trim(stateData.TORCH_DIRECTML_STATUS or "") ~= "" then
            appendKey(lines, "torch_directml_status", trim(stateData.TORCH_DIRECTML_STATUS or ""))
        end
        if trim(stateData.DIRECTML_DEVICE or "") ~= "" then
            appendKey(lines, "directml_device", trim(stateData.DIRECTML_DEVICE or ""))
        end
        if trim(stateData.DIRECTML_DEVICE_COUNT or "") ~= "" then
            appendKey(lines, "directml_device_count", trim(stateData.DIRECTML_DEVICE_COUNT or ""))
        end
        if trim(stateData.ORT_DIRECTML_PROVIDER or "") ~= "" then
            appendKey(lines, "ort_directml_provider", trim(stateData.ORT_DIRECTML_PROVIDER or ""))
        end
    end
    appendKey(lines, "model_status", trim(stateData.DRUMSEP_CUDA_MODEL_STATUS or stateData.DRUMSEP_DIRECTML_MODEL_STATUS or stateData.DRUMSEP_MODEL_STATUS or stateData.DRUMSEP_ROCM_MODEL_STATUS) ~= "" and trim(stateData.DRUMSEP_CUDA_MODEL_STATUS or stateData.DRUMSEP_DIRECTML_MODEL_STATUS or stateData.DRUMSEP_MODEL_STATUS or stateData.DRUMSEP_ROCM_MODEL_STATUS) or "unknown")
    appendKey(lines, "model_file", sanitizePathValue(modelFile))
    appendKey(lines, "model_file_exists", fileExists(modelFile) and "yes" or "no")
    appendKey(lines, "model_file_size_bytes", tostring(fileSizeBytes(modelFile) or 0))
    appendKey(lines, "model_yaml", sanitizePathValue(modelYaml))
    appendKey(lines, "model_yaml_exists", fileExists(modelYaml) and "yes" or "no")
    appendKey(lines, "model_yaml_size_bytes", tostring(fileSizeBytes(modelYaml) or 0))
    if trim(stateData.DRUMSEP_ROCM_TEMP_DIR or "") ~= "" then
        appendKey(lines, "rocm_temp_dir", stateData.DRUMSEP_ROCM_TEMP_DIR)
    end
    if trim(stateData.DRUMSEP_CUDA_LAST_CHECK_UTC or stateData.DRUMSEP_DIRECTML_LAST_CHECK_UTC or stateData.DRUMSEP_ROCM_LAST_CHECK_UTC or stateData.DRUMSEP_LAST_CHECK_UTC or "") ~= "" then
        appendKey(lines, "last_check_utc", trim(stateData.DRUMSEP_CUDA_LAST_CHECK_UTC or stateData.DRUMSEP_DIRECTML_LAST_CHECK_UTC or stateData.DRUMSEP_ROCM_LAST_CHECK_UTC or stateData.DRUMSEP_LAST_CHECK_UTC or ""))
    end
    appendLine(lines, "")
end

local function resolveDrumsepRuntimePython(runtimeBase, stateData, dirname)
    local candidates = {
        trim(stateData.DRUMSEP_DIRECTML_PYTHON or ""),
        trim(stateData.DRUMSEP_ROCM_PYTHON or ""),
        trim(stateData.DRUMSEP_PYTHON or ""),
        trim(stateData.PYTHON_PATH or ""),
        trim(stateData.VENV_PYTHON_PATH or ""),
        trim(stateData.VENV_PYTHON or ""),
    }
    local fallback = OS == "Windows"
        and joinPath(runtimeBase, dirname, "Scripts", "python.exe")
        or joinPath(runtimeBase, dirname, "bin", "python")
    candidates[#candidates + 1] = fallback
    for i = 1, #candidates do
        local path = trim(candidates[i])
        if path ~= "" and fileExists(path) then
            return path
        end
    end
    return trim(candidates[1]) ~= "" and trim(candidates[1]) or fallback
end

local function collectLatestDksMarkers(cacheLogDir)
    local markerKeys = toLowerSet({
        "workflow_mode", "workflow_source", "error_stage", "error_reason",
        "drumsep_runtime_selected", "drumsep_python", "drumsep_gpu_capable",
        "drumsep_runtime_fallback_reason", "drumsep_torch_version", "drumsep_torch_hip",
        "drumsep_subprocess_env_profile", "drumsep_helper_device_arg", "drumsep_virtual_env",
        "drumsep_cuda_visible_devices", "drumsep_nvidia_visible_devices",
        "drumsep_ld_library_path_contains_main_venv", "drumsep_path_starts_with_drumsep_venv",
        "catalog_lookup_status", "catalog_source", "drumsep_catalog_asset",
        "drumsep_cache_target", "drumsep_cache_source", "drumsep_cache_status",
        "drumsep_cache_asset", "drumsep_cache_sha256", "drumsep_cache_error",
        "drumsep_model_files_ready", "model_id", "yaml_path", "yaml_source",
        "yaml_top_level_keys", "yaml_resolution", "yaml_training_instruments",
        "yaml_target_instrument", "expected_schema", "ckpt_path", "ckpt_source",
        "output_dir", "expected_stems", "found_stems", "found_files",
        "output_validation_reason",
        "direct_demix_enabled", "direct_demix_device", "drumsep_direct_demix_route",
        "drumsep_mps_all_targets_route", "mps_fallback_enabled", "pytorch_mps_fallback_env",
        "backend_runtime", "audio_separator_version", "requested_device", "effective_device",
        "model_device", "direct_demix_keys", "drumsep_direct_demix_gate",
        "drumsep_direct_demix_gate_reason", "drumsep_mps_direct_demix_gate",
        "drumsep_mps_direct_demix_gate_reason",
        "drumsep_device_names", "dks_extract_stage1_runtime", "dks_extract_stage1_requested_device",
        "dks_extract_stage1_device", "dks_extract_stage1_device_name", "dks_extract_stage1_live_device_ids",
        "dks_extract_stage1_fallback_reason", "dks_extract_stage1_output", "dks_extract_stage2_runtime",
        "dks_extract_stage2_requested_device", "dks_extract_stage2_device", "dks_extract_stage2_backend",
        "dks_extract_stage2_effective_cap", "bench_dks_stage2_cap_requested", "bench_dks_stage2_cap_applied",
        "bench_dks_stage2_cap_ignored_reason", "dks_extract_intermediate_dir",
        "dks_extract_stage2_dir", "lua_dks_extract_outputs_detected", "lua_dks_extract_output_count",
        "lua_dks_extract_stage2_concurrency_cap", "lua_dks_extract_stage2_queue_wait_start",
        "lua_dks_extract_stage2_queue_wait_end", "dks_extract_stage2_throttled",
        "expected_drum_outputs", "actual_drum_outputs", "output_count_mismatch",
        "lua_dks_extract_import_start", "lua_dks_extract_import_end", "lua_dks_extract_import_candidate_count",
        "lua_dks_extract_import_selected_count", "lua_dks_extract_import_created", "lua_dks_single_in_place_import_created",
        "lua_dks_single_in_place_no_takes_reason", "lua_result_probe_start",
        "lua_result_probe_workflow_source", "lua_result_probe_top_level_count", "lua_result_probe_stdout_json_attempt",
        "lua_result_probe_stdout_json_ok", "lua_result_probe_stdout_json_count", "lua_no_stems_reason",
        "lua_dks_multi_start", "lua_dks_multi_workflow_source", "lua_dks_multi_source_count",
        "lua_dks_multi_mode", "lua_dks_multi_job_index", "lua_dks_multi_job_dir",
        "lua_dks_multi_worker_args", "lua_dks_multi_worker_exit_code", "lua_dks_multi_stdout_json_ok",
        "lua_dks_multi_output_count", "lua_dks_multi_import_created", "lua_dks_multi_import_total_created",
        "lua_dks_multi_no_stems_reason",
        "dks_expected_output_count", "dks_validated_output_count", "dks_imported_track_count",
        "dks_import_validation_reason", "dks_probe_stemset", "dks_settings_load",
        "dks_settings_load_stemset_skipped", "dks_stemset_activate",
        "workflow_success", "workflow_failure_reason",
        "drumsep_scheduler_backend", "drumsep_scheduler_policy", "drumsep_scheduler_uses_cpu_fallback",
        "bench_drumsep_helper_device_env", "bench_drumsep_helper_device_requested",
        "bench_drumsep_helper_device_applied", "bench_drumsep_helper_device_ignored_reason",
        "drumsep_helper_gpu_probe_status", "drumsep_helper_gpu_probe_reason",
        "drumsep_helper_gpu_probe_torch_hip", "drumsep_helper_gpu_probe_torch_cuda",
        "drumsep_helper_gpu_probe_tensor_device", "drumsep_helper_gpu_probe_device_name",
        "scheduler_policy_route", "scheduler_policy_stage", "scheduler_policy_backend",
        "scheduler_policy_cap", "scheduler_policy_reason", "scheduler_policy_long_workload",
        "lua_dks_scheduler_policy_route", "lua_dks_scheduler_policy_stage", "lua_dks_scheduler_policy_cap",
        "separate_start", "separate_end",
        "stem_write_start", "stem_write_end", "python_done", "drumsep_helper_start",
        "drumsep_helper_ok", "drumsep_helper_stdout", "drumsep_helper_stderr",
    })
    local sourceCandidates = {}
    local addIfExists = function(path)
        if trim(path) ~= "" and fileExists(path) then
            sourceCandidates[#sourceCandidates + 1] = path
        end
    end

    addIfExists(joinPath(cacheLogDir, "stdout.txt"))
    addIfExists(joinPath(cacheLogDir, "separation_log.txt"))
    addIfExists(joinPath(cacheLogDir, "stemwerk.log"))

    local runsRoot = joinPath(cacheLogDir, "runs")
    if pathExists(runsRoot) then
        local runDirs = enumerateSubdirs(runsRoot)
        table.sort(runDirs, function(a, b) return tostring(a) > tostring(b) end)
        for i = 1, math.min(8, #runDirs) do
            local runDir = joinPath(runsRoot, runDirs[i])
            for _, jobName in ipairs(enumerateSubdirs(runDir)) do
                local jobDir = joinPath(runDir, jobName)
                addIfExists(joinPath(jobDir, "stdout.txt"))
                addIfExists(joinPath(jobDir, "separation_log.txt"))
                addIfExists(joinPath(jobDir, "phase_events.jsonl"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_helper_stdout.txt"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_helper_stderr.txt"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_result.json"))
            end
        end
    end

    local tempBase = getTempBase()
    if pathExists(tempBase) then
        local tempRuns = {}
        for _, name in ipairs(enumerateSubdirs(tempBase)) do
            if tostring(name):lower():find("stemwerk_", 1, true) == 1 then
                tempRuns[#tempRuns + 1] = name
            end
        end
        table.sort(tempRuns, function(a, b) return tostring(a) > tostring(b) end)
        for i = 1, math.min(8, #tempRuns) do
            local runDir = joinPath(tempBase, tempRuns[i])
            addIfExists(joinPath(runDir, "stdout.txt"))
            addIfExists(joinPath(runDir, "stderr.txt"))
            addIfExists(joinPath(runDir, "separation_log.txt"))
            addIfExists(joinPath(runDir, "drumsep_helper_stdout.txt"))
            addIfExists(joinPath(runDir, "drumsep_helper_stderr.txt"))
            addIfExists(joinPath(runDir, "phase_events.jsonl"))
            for _, jobName in ipairs(enumerateSubdirs(runDir)) do
                local jobDir = joinPath(runDir, jobName)
                addIfExists(joinPath(jobDir, "stdout.txt"))
                addIfExists(joinPath(jobDir, "separation_log.txt"))
                addIfExists(joinPath(jobDir, "phase_events.jsonl"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_helper_stdout.txt"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_helper_stderr.txt"))
                addIfExists(joinPath(jobDir, "stage2_drumsep", "drumsep_result.json"))
            end
        end
    end

    local markers = {}
    local seen = {}
    for i = 1, #sourceCandidates do
        local src = sourceCandidates[i]
        local tail = readTailText(src, 256 * 1024)
        for line in tostring(tail or ""):gmatch("[^\r\n]+") do
            local raw = trim(line)
            local lower = raw:lower()
            local key, value = raw:match("^%s*([%w%._%-%s/]+)%s*[:=]%s*(.-)%s*$")
            key = key and trim(key):lower():gsub("%s+", "_") or nil
            value = value and trim(value) or nil
            if key and markerKeys[key] then
                local composed = key .. "=" .. tostring(value)
                if not seen[composed] then
                    seen[composed] = true
                    markers[#markers + 1] = composed .. "  [source=" .. basename(src) .. "]"
                end
            else
                for marker, _ in pairs(markerKeys) do
                    if lower:find(marker, 1, true) then
                        local composed = raw .. "  [source=" .. basename(src) .. "]"
                        if not seen[composed] then
                            seen[composed] = true
                            markers[#markers + 1] = composed
                        end
                        break
                    end
                end
            end
            if #markers >= 120 then
                return markers
            end
        end
    end
    return markers
end

local function buildDrumsepRuntimeDiagnostics(runtimeBase, runtimeStateDir, runtimeLogDir, cacheLogDir)
    local lines = {}
    local readyStatePath = joinPath(runtimeStateDir, "ready_to_go.env")
    local readyState = readEnvFile(readyStatePath)
    local modelDir = trim(readyState.CORE_MODEL_CACHE_DIR or "")
    if modelDir == "" then
        modelDir = getModelCacheDir()
    end
    local modelFile = joinPath(modelDir, "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt")
    local modelYaml = joinPath(modelDir, "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml")

    local cpuStatePath = joinPath(runtimeStateDir, "drumsep_runtime.env")
    local cudaStatePath = joinPath(runtimeStateDir, "drumsep_runtime_cuda.env")
    local rocmStatePath = joinPath(runtimeStateDir, "drumsep_runtime_rocm.env")
    local directmlStatePath = joinPath(runtimeStateDir, "drumsep_runtime_directml.env")
    local cpuState = readEnvFile(cpuStatePath)
    local cudaState = readEnvFile(cudaStatePath)
    local rocmState = readEnvFile(rocmStatePath)
    local directmlState = readEnvFile(directmlStatePath)
    local cpuPy = resolveDrumsepRuntimePython(runtimeBase, cpuState, ".venv-drumsep")
    local cudaPy = resolveDrumsepRuntimePython(runtimeBase, cudaState, ".venv-drumsep-cuda")
    local rocmPy = resolveDrumsepRuntimePython(runtimeBase, rocmState, ".venv-drumsep-rocm")
    local directmlPy = resolveDrumsepRuntimePython(runtimeBase, directmlState, ".venv-drumsep-directml")
    local cpuProbe = nil
    local cudaProbe = nil
    local rocmProbe = nil
    local directmlProbe = nil

    appendLine(lines, "DrumSep Runtime Diagnostics")
    appendKey(lines, "runtime_base", runtimeBase)
    appendKey(lines, "runtime_state_dir", runtimeStateDir)
    appendKey(lines, "runtime_logs_dir", runtimeLogDir)
    appendKey(lines, "model_cache_dir", modelDir)
    appendKey(lines, "ready_to_go_env", fileExists(readyStatePath) and "present" or "missing")
    appendKey(lines, "ready_to_go_status", trim(readyState.READY_TO_GO_STATUS or "") ~= "" and trim(readyState.READY_TO_GO_STATUS or "") or "unknown")
    appendKey(lines, "core_model_fast_status", trim(readyState.CORE_MODEL_FAST_STATUS or "") ~= "" and trim(readyState.CORE_MODEL_FAST_STATUS or "") or "unknown")
    appendKey(lines, "core_model_quality_status", trim(readyState.CORE_MODEL_QUALITY_STATUS or "") ~= "" and trim(readyState.CORE_MODEL_QUALITY_STATUS or "") or "unknown")
    appendKey(lines, "core_model_6stem_status", trim(readyState.CORE_MODEL_6STEM_STATUS or "") ~= "" and trim(readyState.CORE_MODEL_6STEM_STATUS or "") or "unknown")
    appendKey(lines, "drumsep_ready_runtime", trim(readyState.DRUMSEP_READY_RUNTIME or "") ~= "" and trim(readyState.DRUMSEP_READY_RUNTIME or "") or "unknown")
    appendKey(lines, "drumsep_ready_runtime_status", trim(readyState.DRUMSEP_READY_RUNTIME_STATUS or "") ~= "" and trim(readyState.DRUMSEP_READY_RUNTIME_STATUS or "") or "unknown")
    appendKey(lines, "drumsep_ready_model_status", trim(readyState.DRUMSEP_READY_MODEL_STATUS or "") ~= "" and trim(readyState.DRUMSEP_READY_MODEL_STATUS or "") or "unknown")
    appendKey(lines, "drumsep_status", trim(readyState.DRUMSEP_STATUS or "") ~= "" and trim(readyState.DRUMSEP_STATUS or "") or "unknown")
    appendKey(lines, "dks_supported", trim(readyState.DKS_SUPPORTED or "") ~= "" and trim(readyState.DKS_SUPPORTED or "") or "unknown")
    appendKey(lines, "normal_stems_supported", trim(readyState.NORMAL_STEMS_SUPPORTED or "") ~= "" and trim(readyState.NORMAL_STEMS_SUPPORTED or "") or "unknown")
    appendKey(lines, "collect_drumsep_runtime_source", "cached")
    appendKey(lines, "collect_drumsep_runtime_live_probe", "skipped")
    appendLine(lines, "")

    appendDrumsepRuntimeBlock(lines, "[CPU fallback runtime]", cpuPy, cpuState, cpuProbe, modelFile, modelYaml)
    appendDrumsepRuntimeBlock(lines, "[CUDA runtime]", cudaPy, cudaState, cudaProbe, modelFile, modelYaml)
    appendDrumsepRuntimeBlock(lines, "[ROCm runtime]", rocmPy, rocmState, rocmProbe, modelFile, modelYaml)
    appendDrumsepRuntimeBlock(lines, "[DirectML runtime]", directmlPy, directmlState, directmlProbe, modelFile, modelYaml)

    appendLine(lines, "[Selector status]")
    appendKey(lines, "selected_runtime", trim(rocmState.DRUMSEP_SELECTED_RUNTIME or cpuState.DRUMSEP_SELECTED_RUNTIME or "") ~= "" and trim(rocmState.DRUMSEP_SELECTED_RUNTIME or cpuState.DRUMSEP_SELECTED_RUNTIME or "") or "unknown")
    appendKey(lines, "gpu_capable", trim(rocmState.DRUMSEP_GPU_CAPABLE or cpuState.DRUMSEP_GPU_CAPABLE or "") ~= "" and trim(rocmState.DRUMSEP_GPU_CAPABLE or cpuState.DRUMSEP_GPU_CAPABLE or "") or "unknown")
    appendLine(lines, "")

    appendLine(lines, "[Latest Direct DKS markers]")
    local markers = collectLatestDksMarkers(cacheLogDir)
    if #markers == 0 then
        appendLine(lines, "no Direct DKS markers found in recent logs")
    else
        for i = 1, #markers do
            appendLine(lines, markers[i])
        end
    end
    appendLine(lines, "")

    appendLine(lines, "[Install log tails]")
    local cpuInstallLog = joinPath(runtimeLogDir, "drumsep_install.log")
    local cudaInstallLog = joinPath(runtimeLogDir, "drumsep_cuda_install.log")
    local rocmInstallLog = joinPath(runtimeLogDir, "drumsep_rocm_install.log")
    local directmlInstallLog = joinPath(runtimeLogDir, "drumsep_directml_install.log")
    appendKey(lines, "drumsep_install.log", fileExists(cpuInstallLog) and "present" or "missing")
    appendKey(lines, "drumsep_cuda_install.log", fileExists(cudaInstallLog) and "present" or "missing")
    appendKey(lines, "drumsep_rocm_install.log", fileExists(rocmInstallLog) and "present" or "missing")
    appendKey(lines, "drumsep_directml_install.log", fileExists(directmlInstallLog) and "present" or "missing")
    appendLine(lines, "")
    if fileExists(cpuInstallLog) then
        appendLine(lines, "----- tail: drumsep_install.log -----")
        appendLine(lines, readTailText(cpuInstallLog, 180 * 1024))
        appendLine(lines, "")
    end
    if fileExists(cudaInstallLog) then
        appendLine(lines, "----- tail: drumsep_cuda_install.log -----")
        appendLine(lines, readTailText(cudaInstallLog, 180 * 1024))
        appendLine(lines, "")
    end
    if fileExists(rocmInstallLog) then
        appendLine(lines, "----- tail: drumsep_rocm_install.log -----")
        appendLine(lines, readTailText(rocmInstallLog, 180 * 1024))
        appendLine(lines, "")
    end
    if fileExists(directmlInstallLog) then
        appendLine(lines, "----- tail: drumsep_directml_install.log -----")
        appendLine(lines, readTailText(directmlInstallLog, 180 * 1024))
        appendLine(lines, "")
    end

    return lines
end

local function psLiteral(text)
    return "'" .. tostring(text or ""):gsub("'", "''") .. "'"
end

local function tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)
    if trim(pythonPath) == "" or not fileExists(pythonPath) then
        return false, "Python runtime unavailable for zip", "python"
    end
    local scriptPath = joinPath(bundleParent, "_support_bundle_zip_" .. tostring(os.time()) .. ".py")
    local script = table.concat({
        "import os",
        "import sys",
        "import zipfile",
        "",
        "def normalize_arcname(path):",
        "    return str(path or '').replace('\\\\', '/').strip('/')",
        "",
        "bundle_dir = os.path.abspath(sys.argv[1])",
        "zip_path = os.path.abspath(sys.argv[2])",
        "parent = os.path.dirname(bundle_dir)",
        "base = os.path.basename(bundle_dir.rstrip('/\\\\'))",
        "",
        "if os.path.exists(zip_path):",
        "    os.remove(zip_path)",
        "",
        "with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:",
        "    for root, dirs, files in os.walk(bundle_dir):",
        "        rel_root = normalize_arcname(os.path.relpath(root, parent))",
        "        if rel_root == '.':",
        "            rel_root = normalize_arcname(base)",
        "        if not files and not dirs:",
        "            zf.writestr(rel_root.rstrip('/\\\\') + '/', '')",
        "        for name in files:",
        "            src = os.path.join(root, name)",
        "            rel = normalize_arcname(os.path.relpath(src, parent))",
        "            zf.write(src, rel)",
    }, "\n")
    if not writeFile(scriptPath, script, "wb") then
        return false, "Could not write zip helper script", "python"
    end
    local rc, out = execCommand(pythonPath, {scriptPath, bundleDir, zipPath}, 60000)
    if fileExists(scriptPath) then os.remove(scriptPath) end
    if rc == 0 and fileExists(zipPath) then
        return true, "", "python"
    end
    return false, trim(out) ~= "" and trim(out) or ("python zip failed (rc=" .. tostring(rc) .. ")"), "python"
end

local function tryCreateZipWithPowerShell(bundleDir, zipPath)
    if OS ~= "Windows" then
        return false, "PowerShell zip is Windows-only", "powershell"
    end
    local script = table.concat({
        "$src = " .. psLiteral(bundleDir),
        "$dst = " .. psLiteral(zipPath),
        "if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }",
        "Compress-Archive -LiteralPath $src -DestinationPath $dst -CompressionLevel Optimal -Force",
    }, "; ")
    local rc, out = execPowerShell(script, 60000)
    if rc == 0 and fileExists(zipPath) then
        return true, "", "powershell"
    end
    return false, trim(out) ~= "" and trim(out) or ("powershell zip failed (rc=" .. tostring(rc) .. ")"), "powershell"
end

local function tryCreateZipWithDitto(bundleDir, zipPath)
    if OS ~= "macOS" then
        return false, "ditto zip is macOS-only", "ditto"
    end
    local rc, out = execCommand("ditto", {"-c", "-k", "--keepParent", bundleDir, zipPath}, 60000)
    if rc == 0 and fileExists(zipPath) then
        return true, "", "ditto"
    end
    return false, trim(out) ~= "" and trim(out) or ("ditto zip failed (rc=" .. tostring(rc) .. ")"), "ditto"
end

local function tryCreateZipWithZipCommand(bundleParent, bundleName, zipPath)
    local shell = fileExists("/bin/sh") and "/bin/sh" or "sh"
    local cmd = "cd " .. quoteArg(bundleParent)
        .. " && zip -r -q "
        .. quoteArg(basename(zipPath))
        .. " "
        .. quoteArg(bundleName)
    local rc, out = execCommand(shell, {"-lc", cmd}, 60000)
    if rc == 0 and fileExists(zipPath) then
        return true, "", "zip"
    end
    return false, trim(out) ~= "" and trim(out) or ("zip command failed (rc=" .. tostring(rc) .. ")"), "zip"
end

local function createZipArchive(bundleParent, bundleDir, bundleName, pythonPath)
    local zipPath = joinPath(bundleParent, bundleName .. ".zip")
    if fileExists(zipPath) then
        os.remove(zipPath)
    end

    local errors = {}
    local ok, err, method
    if OS == "Windows" then
        ok, err, method = tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
        ok, err, method = tryCreateZipWithPowerShell(bundleDir, zipPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
    elseif OS == "macOS" then
        ok, err, method = tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
        ok, err, method = tryCreateZipWithDitto(bundleDir, zipPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
    else
        ok, err, method = tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
    end

    ok, err, method = tryCreateZipWithZipCommand(bundleParent, bundleName, zipPath)
    if ok then return true, zipPath, "", method end
    errors[#errors + 1] = method .. ": " .. tostring(err)

    return false, "", table.concat(errors, " | "), ""
end

local function updateZipTimingFile(zipPath, bundleDir, timingPath, pythonPath)
    if trim(pythonPath) == "" or not fileExists(pythonPath) then
        return false, "python_unavailable"
    end
    if not fileExists(zipPath) or not fileExists(timingPath) then
        return false, "zip_or_timing_missing"
    end
    local bundleParent = tostring(bundleDir or ""):match("^(.*)[/\\][^/\\]+$") or ""
    local scriptPath = joinPath(bundleParent, "_support_bundle_zip_update_" .. tostring(os.time()) .. ".py")
    local script = table.concat({
        "import os",
        "import sys",
        "import zipfile",
        "",
        "def normalize_arcname(path):",
        "    return str(path or '').replace('\\\\', '/').strip('/')",
        "",
        "zip_path = os.path.abspath(sys.argv[1])",
        "bundle_dir = os.path.abspath(sys.argv[2])",
        "timing_path = os.path.abspath(sys.argv[3])",
        "parent = os.path.dirname(bundle_dir)",
        "arcname = normalize_arcname(os.path.relpath(timing_path, parent))",
        "with zipfile.ZipFile(zip_path, 'a', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:",
        "    zf.write(timing_path, arcname)",
    }, "\n")
    if not writeFile(scriptPath, script, "wb") then
        return false, "helper_write_failed"
    end
    local rc, out = execCommand(pythonPath, {scriptPath, zipPath, bundleDir, timingPath}, 30000)
    if fileExists(scriptPath) then os.remove(scriptPath) end
    if rc == 0 then
        return true, ""
    end
    return false, trim(out) ~= "" and trim(out) or ("zip_update_failed_rc_" .. tostring(rc))
end

local function classifyFileForBundle(name)
    local lower = tostring(name or ""):lower()
    local textExt = {
        [".txt"] = true, [".log"] = true, [".env"] = true, [".json"] = true,
        [".jsonl"] = true,
        [".out"] = true, [".err"] = true, [".pid"] = true, [".cfg"] = true,
        [".ini"] = true, [".trace"] = true,
    }
    local binaryExt = {
        [".wav"] = true, [".mp3"] = true, [".flac"] = true, [".ogg"] = true,
        [".aiff"] = true, [".aif"] = true, [".m4a"] = true, [".aac"] = true,
        [".mp4"] = true, [".mov"] = true, [".avi"] = true, [".mkv"] = true,
        [".pt"] = true, [".pth"] = true, [".ckpt"] = true, [".onnx"] = true,
        [".bin"] = true, [".safetensors"] = true, [".npy"] = true, [".npz"] = true,
        [".whl"] = true, [".zip"] = true, [".7z"] = true, [".tar"] = true,
        [".gz"] = true, [".xz"] = true, [".dll"] = true, [".pyd"] = true,
        [".exe"] = true, [".msi"] = true, [".iso"] = true,
    }
    for ext, _ in pairs(binaryExt) do
        if endsWith(lower, ext) then
            return "excluded_binary"
        end
    end
    for ext, _ in pairs(textExt) do
        if endsWith(lower, ext) then
            return "text"
        end
    end
    if lower == "stdout.txt" or lower == "stderr.txt" or lower == "separation_log.txt" or lower == "bootstrap.log" then
        return "text"
    end
    if lower:find("debug", 1, true) and (lower:find(".log", 1, true) or lower:find(".txt", 1, true)) then
        return "text"
    end
    return "other"
end

local function collectExpectedFileStatus(lines, label, path)
    local status = fileExists(path) and "present" or "missing"
    appendKey(lines, label, status .. " - " .. sanitizePathValue(path))
end

local function relativePath(base, path)
    local nBase = normalizePath(base)
    local nPath = normalizePath(path)
    if nBase ~= "" and nPath ~= "" and startsWith(nPath, nBase) then
        local rel = path:sub(#base + 1)
        return rel:gsub("^[/\\]+", "")
    end
    return basename(path)
end

local function collectStateFiles(runtimeDir, bundleDir, copiedFiles)
    local statusLines = {}
    local destDir = joinPath(bundleDir, "runtime_state")
    ensureDir(destDir)
    local readyToGoEnvPath = joinPath(runtimeDir, "ready_to_go.env")

    collectExpectedFileStatus(statusLines, "bootstrap.env", bootstrapEnvPath)
    collectExpectedFileStatus(statusLines, "capabilities.env", capabilitiesEnvPath)
    collectExpectedFileStatus(statusLines, "ready_to_go.env", readyToGoEnvPath)
    collectExpectedFileStatus(statusLines, "bootstrap.pid", bootstrapPidPath)
    collectExpectedFileStatus(statusLines, "bootstrap.guard", bootstrapGuardPath)

    for _, name in ipairs(enumerateFiles(runtimeDir)) do
        local src = joinPath(runtimeDir, name)
        local class = classifyFileForBundle(name)
        if class == "text" or class == "other" then
            local dst = joinPath(destDir, basename(src))
            local ok, mode = copySupportTextFile(src, dst, 1024 * 1024)
            if ok then
                copiedFiles[#copiedFiles + 1] = "runtime_state/" .. basename(src) .. " (" .. mode .. ")"
            end
        end
    end

    return statusLines
end

local function collectRuntimeLogs(runtimeDir, bundleDir, copiedFiles)
    local lines = {}
    local destDir = joinPath(bundleDir, "runtime_logs")
    ensureDir(destDir)
    local bootstrapLogPath = joinPath(runtimeDir, "bootstrap.log")

    appendKey(lines, "bootstrap.log", fileExists(bootstrapLogPath) and ("present - " .. bootstrapLogPath) or ("missing - " .. bootstrapLogPath))

    local found = false
    for _, name in ipairs(enumerateFiles(runtimeDir)) do
        found = true
        local src = joinPath(runtimeDir, name)
        local dst = joinPath(destDir, basename(src))
        local ok, mode = copySupportTextFile(src, dst, 1024 * 1024)
        appendLine(lines, string.format("- %s: %s", basename(src), ok and mode or "missing"))
        if ok then
            copiedFiles[#copiedFiles + 1] = "runtime_logs/" .. basename(src) .. " (" .. mode .. ")"
        end
    end
    if not found then
        appendLine(lines, "- runtime logs folder missing or empty")
    end
    return lines
end

local CURRENT_EVIDENCE_PHASES = {
    { id = "verify", label = "Verify / Check existing setup" },
    { id = "online_normal", label = "Online Normal Stems" },
    { id = "online_drum", label = "Online Direct Kit or Kit Split" },
    { id = "bundled_recovery", label = "Bundled recovery or rebuild" },
    { id = "post_bundled_normal", label = "Post-bundled Normal Stems" },
    { id = "post_bundled_drum", label = "Post-bundled Direct Kit or Kit Split" },
}

local CURRENT_EVIDENCE_ALLOWED = {
    ["evidence.env"] = true,
    ["phase_events.jsonl"] = true,
    ["timing_events.jsonl"] = true,
    ["console.log"] = true,
    ["stdout.txt"] = true,
    ["stderr.txt"] = true,
    ["separation_log.txt"] = true,
    ["output_validation.txt"] = true,
    ["before.sha256"] = true,
    ["after.sha256"] = true,
    ["mutation_check.txt"] = true,
    ["package_metadata.txt"] = true,
}

local function findCurrentEvidenceRoot(runtimeBase, cacheLogDir)
    local candidates = {
        joinPath(runtimeBase, "evidence", "current-session"),
        joinPath(cacheLogDir, "support_evidence", "current-session"),
    }
    for _, candidate in ipairs(candidates) do
        if fileExists(joinPath(candidate, "session.env")) then
            return candidate
        end
    end
    return ""
end

local function classifyOnnxFallback(bootstrapLog, runtimeState, currentHealthyEvidence)
    local text = tostring(readFile(bootstrapLog, "rb") or "")
    local lower = text:lower()
    local lookupFailed = lower:find("no matching distribution found for onnxruntime%-silicon") ~= nil
        or lower:find("could not find a version that satisfies the requirement onnxruntime%-silicon") ~= nil
    local fallbackAttempted = lower:find("falling back to onnxruntime", 1, true) ~= nil
    local fallbackVersion = text:match("Successfully installed[^\r\n]-onnxruntime%-([%d%.]+)")
        or text:match("[\r\n]onnxruntime=([%d%.]+)")
        or ""
    -- bootstrap.log is append-only across every historical bootstrap run,
    -- so a bare text search for "Runtime verification passed." can find a
    -- sentence left behind by an old, unrelated run. That is historical
    -- context, not current proof.
    --
    -- bootstrap.env's STATUS/RUNTIME_VERIFY_DETAIL (structuredHealthy) is
    -- likewise NOT current proof by itself: bootstrap.env has no
    -- freshness/session/generation identity of its own in its current
    -- schema, so "STATUS=ok" recorded there could be from any past
    -- bootstrap run, not necessarily this one. It is cached/recorded
    -- readiness provenance, exposed separately below as
    -- bootstrap_readiness, never merged into the current-health verdict.
    -- Current health can only come from proven-healthy current-session
    -- evidence (currentHealthyEvidence -- session-ID-matched, freshly
    -- timestamped, explicitly-ok acceptance phases / live workers).
    local structuredHealthy = trim(runtimeState.STATUS or ""):lower() == "ok"
        and trim(runtimeState.RUNTIME_VERIFY_DETAIL or ""):lower() == "ok"
    local historicalSentenceSeen = lower:find("runtime verification passed.", 1, true) ~= nil
    local runtimeHealthy = currentHealthyEvidence == true
    local handled = lookupFailed and fallbackAttempted and fallbackVersion ~= "" and runtimeHealthy
    -- A historical lookup failure only counts as a CURRENT fatal error when
    -- there is no other proof the runtime is currently healthy. If current
    -- workers/phases already prove health, the old failure is
    -- historical/recovered context, not a current fault. A merely cached
    -- bootstrap-healthy claim does NOT count as that proof (see above).
    local fatal = lookupFailed and not handled and not runtimeHealthy
    return {
        lookupFailed = lookupFailed,
        fallbackAttempted = fallbackAttempted,
        fallbackVersion = fallbackVersion,
        runtimeHealthy = runtimeHealthy,
        cachedBootstrapHealthy = structuredHealthy,
        historicalSentenceSeen = historicalSentenceSeen,
        handled = handled,
        fatal = fatal,
    }
end

-- Strict UTC ISO-8601 shape ("2026-07-24T13:10:00Z") -- the exact format
-- this codebase's own evidence.env/session.env writers use. A value that
-- doesn't match this is not a parseable timestamp and must not be treated
-- as one: a naive string compare (`>=`) between a malformed value and a
-- real timestamp can accidentally evaluate either way depending on the
-- malformed text's leading characters, which is not proof of anything.
local function isValidIsoUtcTimestamp(value)
    return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
end

local function collectCurrentSessionEvidence(runtimeBase, runtimeLogDir, cacheLogDir, bundleDir, copiedFiles, runtimeState, workerHealth)
    local lines = {
        "STEMwerk Support Evidence Manifest",
        "schema=1",
    }
    local sourceRoot = findCurrentEvidenceRoot(runtimeBase, cacheLogDir)
    local session = sourceRoot ~= "" and readEnvFile(joinPath(sourceRoot, "session.env")) or {}
    local sessionId = trim(session.SESSION_ID or "")
    local destinationRoot = joinPath(bundleDir, "current_session_evidence")
    ensureDir(destinationRoot)
    appendKey(lines, "source_root", sourceRoot ~= "" and sourceRoot or "missing")
    appendKey(lines, "session_id", sessionId ~= "" and sessionId or "missing")
    appendKey(lines, "session_started_utc", trim(session.SESSION_STARTED_UTC or "") ~= "" and session.SESSION_STARTED_UTC or "missing")

    local included = 0
    local missing = 0
    local currentFatalErrors = 0
    local healthyPhaseCount = 0
    local sawStalePhase = false
    local sessionStartedUtc = trim(session.SESSION_STARTED_UTC or "")
    for _, phase in ipairs(CURRENT_EVIDENCE_PHASES) do
        local phaseSource = sourceRoot ~= "" and joinPath(sourceRoot, phase.id) or ""
        local evidencePath = phaseSource ~= "" and joinPath(phaseSource, "evidence.env") or ""
        local evidence = evidencePath ~= "" and readEnvFile(evidencePath) or {}
        local phaseSessionId = trim(evidence.SESSION_ID or "")
        local phaseIdentity = trim(evidence.PHASE or "")
        local phaseTimestampUtc = trim(evidence.TIMESTAMP_UTC or "")
        -- Freshness: a phase file can only influence current health if its
        -- own generation timestamp belongs to the CURRENT session, i.e. it
        -- is present, parses as a real timestamp, and is not older than
        -- that session's start. A missing or malformed timestamp is not
        -- "fresh by default" -- it is unverifiable and must be treated the
        -- same as a provably stale one: it cannot prove current health.
        -- (If the session's own start time is itself missing/malformed,
        -- there is no floor to compare against, so freshness falls back to
        -- "this phase's own timestamp is at least validly formatted".)
        local phaseIsFresh, freshnessReason
        if phaseTimestampUtc == "" then
            phaseIsFresh, freshnessReason = false, "missing_timestamp"
        elseif not isValidIsoUtcTimestamp(phaseTimestampUtc) then
            phaseIsFresh, freshnessReason = false, "malformed_timestamp"
        elseif isValidIsoUtcTimestamp(sessionStartedUtc) and phaseTimestampUtc < sessionStartedUtc then
            phaseIsFresh, freshnessReason = false, "stale_timestamp_outside_current_session"
        else
            phaseIsFresh = true
        end
        local identityMatches = fileExists(evidencePath)
            and phaseIdentity == phase.id
            and sessionId ~= ""
            and phaseSessionId == sessionId
            and phaseIsFresh
        appendLine(lines, "")
        appendLine(lines, "[phase " .. phase.id .. "]")
        appendKey(lines, "label", phase.label)
        appendKey(lines, "expected_source", evidencePath ~= "" and evidencePath or "missing")
        if identityMatches then
            included = included + 1
            appendKey(lines, "selection", "included")
            local phaseStatus = trim(evidence.STATUS or ""):lower()
            appendKey(lines, "status", phaseStatus ~= "" and phaseStatus or "unknown")
            appendKey(lines, "timestamp_utc", phaseTimestampUtc ~= "" and phaseTimestampUtc or "unknown")
            appendKey(lines, "backend", trim(evidence.BACKEND or "") ~= "" and evidence.BACKEND or "unknown")
            appendKey(lines, "device", trim(evidence.DEVICE or "") ~= "" and evidence.DEVICE or "unknown")
            appendKey(lines, "runtime_arch", trim(evidence.RUNTIME_ARCH or "") ~= "" and evidence.RUNTIME_ARCH or "unknown")
            appendKey(lines, "output_validation_reason", trim(evidence.OUTPUT_VALIDATION_REASON or "") ~= "" and evidence.OUTPUT_VALIDATION_REASON or "not_applicable")
            appendKey(lines, "distribution", trim(evidence.DISTRIBUTION or "") ~= "" and evidence.DISTRIBUTION or "unknown")
            local phaseFatal = tonumber(evidence.CURRENT_FATAL_ERROR_COUNT or "0") or 0
            if phaseFatal == 0 and (phaseStatus == "fail" or phaseStatus == "failed" or phaseStatus == "error" or phaseStatus == "fatal") then
                phaseFatal = 1
            end
            currentFatalErrors = currentFatalErrors + math.max(0, phaseFatal)
            appendKey(lines, "current_fatal_error_count", tostring(math.max(0, phaseFatal)))
            -- Only an explicit, non-unknown "ok" status is proof this phase
            -- currently is healthy; an unknown/blank status is not evidence
            -- either way and must not be able to prove current health.
            if phaseFatal == 0 and phaseStatus == "ok" then
                healthyPhaseCount = healthyPhaseCount + 1
            end
            local phaseDestination = joinPath(destinationRoot, phase.id)
            ensureDir(phaseDestination)
            for _, fileName in ipairs(enumerateFiles(phaseSource)) do
                if CURRENT_EVIDENCE_ALLOWED[fileName:lower()] then
                    local ok, mode = copySupportTextFile(
                        joinPath(phaseSource, fileName),
                        joinPath(phaseDestination, fileName),
                        1024 * 1024
                    )
                    if ok then
                        copiedFiles[#copiedFiles + 1] = "current_session_evidence/" .. phase.id .. "/" .. fileName .. " (" .. mode .. ")"
                    end
                end
            end
        else
            missing = missing + 1
            appendKey(lines, "selection", "missing")
            local warning
            if not fileExists(evidencePath) then
                warning = "evidence_not_found"
            elseif phaseIdentity ~= phase.id or sessionId == "" or phaseSessionId ~= sessionId then
                warning = "session_or_phase_identity_mismatch"
            elseif not phaseIsFresh then
                warning = freshnessReason
            else
                warning = "session_or_phase_identity_mismatch"
            end
            appendKey(lines, "warning", warning)
            -- A phase file that exists but failed only the freshness check
            -- is not proof either way, but stays visible as stale/
            -- unverified evidence rather than being silently discarded --
            -- callers can see this phase existed and why it was not
            -- trusted. (If the evidence file never existed at all, there
            -- is nothing real to show.)
            if fileExists(evidencePath) and not phaseIsFresh then
                sawStalePhase = true
                appendKey(lines, "status", trim(evidence.STATUS or ""):lower() ~= "" and trim(evidence.STATUS or ""):lower() or "unknown")
                appendKey(lines, "timestamp_utc", phaseTimestampUtc ~= "" and phaseTimestampUtc or "missing")
            end
        end
    end

    -- Acceptance-phase fixtures (the 6 fixed phases above) are OPTIONAL
    -- acceptance evidence, not the only proof of a healthy current runtime.
    -- "0/6 collected" means exactly that -- fixtures weren't collected -- and
    -- must not by itself read as "no current session evidence" or force
    -- final_runtime_health to not_proven. An explicitly-"ok" phase (not
    -- merely "included"/identity-matched, since an unknown/blank status is
    -- not proof either way) is independent proof of a currently-healthy
    -- worker, usable to reclassify an old/historical failure recorded in
    -- bootstrap.log.
    local anyPhaseHealthy = currentFatalErrors == 0 and healthyPhaseCount > 0
    -- Current fatal precedence: a currently-failing acceptance phase (its
    -- identity/freshness already verified above) must override a stale
    -- structured "healthy" claim -- CURRENT FAILURE always outranks older
    -- healthy state, never the other way around.
    local currentPhaseFailureExists = currentFatalErrors > 0
    -- Current worker-run evidence (derived from the persisted per-run/
    -- per-job records by deriveCurrentWorkerRunHealth) is an independent
    -- CURRENT health proof, kept distinct from acceptance-phase evidence:
    -- either one may prove current health, and the manifest records which
    -- source actually proved it.
    local worker = workerHealth or { status = "not_proven", run = "", reason = "not_evaluated" }
    local currentWorkerHealthy = worker.status == "ok"
    local currentHealthyEvidence = anyPhaseHealthy or currentWorkerHealthy
    local onnx = classifyOnnxFallback(joinPath(runtimeLogDir, "bootstrap.log"), runtimeState or {}, currentHealthyEvidence)
    if onnx.fatal then currentFatalErrors = currentFatalErrors + 1 end
    -- A current worker run carrying explicit failure evidence is current
    -- failure evidence: it joins the same failure channel as a failed
    -- current acceptance phase and can never be overridden by older or
    -- cached healthy state.
    if worker.status == "failed" then currentFatalErrors = currentFatalErrors + 1 end
    appendLine(lines, "")
    appendLine(lines, "[error classification]")
    appendKey(lines, "onnxruntime_silicon_lookup_failed", onnx.lookupFailed and "yes" or "no")
    appendKey(lines, "handled_recovery_event", onnx.handled and "yes" or "no")
    appendKey(lines, "local_onnxruntime_fallback_recorded", onnx.fallbackVersion ~= "" and "yes" or "no")
    appendKey(lines, "local_onnxruntime_version", onnx.fallbackVersion ~= "" and onnx.fallbackVersion or "none")
    -- bootstrap.env's cached STATUS/RUNTIME_VERIFY_DETAIL is exposed here as
    -- provenance only -- it has no freshness/session identity of its own,
    -- so it can never by itself decide final_runtime_health below (see
    -- classifyOnnxFallback).
    appendKey(lines, "bootstrap_readiness", onnx.cachedBootstrapHealthy and "cached_healthy" or "cached_unhealthy_or_unrecorded")
    -- Distinct provenance for each CURRENT health source. Worker evidence
    -- and phase evidence stay separately visible so the verdict below can
    -- always be traced to the source that proved (or failed) it.
    -- Distinct provenance for each health source. CURRENT worker evidence
    -- (session-linked only) and phase evidence stay separately visible, and
    -- recent-but-unlinked worker evidence is surfaced as provenance without
    -- ever being claimed as current.
    appendKey(lines, "current_worker_health", worker.status)
    appendKey(lines, "current_worker_health_run", worker.run ~= "" and worker.run or "none")
    appendKey(lines, "current_worker_health_reason", tostring(worker.reason or "not_evaluated"))
    appendKey(lines, "recent_worker_health", tostring(worker.recentStatus or "none"))
    appendKey(lines, "recent_worker_health_run", tostring(worker.recentRun or "") ~= "" and worker.recentRun or "none")
    appendKey(lines, "recent_worker_health_reason", tostring(worker.recentReason or "none"))
    appendKey(lines, "worker_context_identity", tostring(worker.contextIdentity or "none"))
    local currentPhaseHealth
    if currentPhaseFailureExists then
        currentPhaseHealth = "failed"
    elseif included == 0 then
        currentPhaseHealth = sawStalePhase and "stale" or "not_collected"
    elseif healthyPhaseCount > 0 then
        currentPhaseHealth = "ok"
    else
        currentPhaseHealth = "not_proven"
    end
    appendKey(lines, "current_phase_health", currentPhaseHealth)
    -- Final verdict: proven CURRENT evidence (worker OR phase) AND no
    -- current failure of any kind (phase fatal, ONNX fatal, or an
    -- explicitly failed current worker run -- all counted into
    -- currentFatalErrors above).
    local finalRuntimeHealthy = onnx.runtimeHealthy and currentFatalErrors == 0
    appendKey(lines, "final_runtime_health", finalRuntimeHealthy and "ok" or "not_proven")
    local healthSource = "none"
    if finalRuntimeHealthy then
        healthSource = currentWorkerHealthy and "current_worker_evidence" or "current_phase_evidence"
    end
    appendKey(lines, "final_runtime_health_source", healthSource)
    appendKey(lines, "current_fatal_error_count", tostring(currentFatalErrors))
    appendKey(lines, "current_fatal_errors", currentFatalErrors == 0 and "none" or tostring(currentFatalErrors))
    if onnx.historicalSentenceSeen then
        -- Historical-only provenance: bootstrap.log is append-only, so this
        -- sentence may belong to an old, unrelated run. It is never used to
        -- decide final_runtime_health above -- only proven current-session
        -- evidence can do that (never a merely cached bootstrap claim).
        appendKey(lines, "historical_runtime_verification_sentence_seen", "yes_not_used_as_current_proof")
    end
    if onnx.lookupFailed and onnx.runtimeHealthy then
        appendKey(lines, "historical_onnxruntime_silicon_issue", "recovered_or_superseded_by_current_health")
    end
    appendKey(lines, "historical_errors_scope", "runtime_logs_except_current_bootstrap_and_current_session_evidence")
    appendLine(lines, "")
    appendKey(lines, "phases_expected", tostring(#CURRENT_EVIDENCE_PHASES))
    appendKey(lines, "phases_included", tostring(included))
    appendKey(lines, "phases_missing", tostring(missing))
    local acceptancePhasesStatus
    if included == 0 then
        acceptancePhasesStatus = "not_collected"
    elseif included < #CURRENT_EVIDENCE_PHASES then
        acceptancePhasesStatus = "partial"
    else
        acceptancePhasesStatus = "complete"
    end
    appendKey(lines, "acceptance_phases_status", acceptancePhasesStatus)
    appendKey(lines, "acceptance_phases_note", "Acceptance-phase fixtures are optional evidence; their absence does not by itself affect final_runtime_health.")
    -- Missing OPTIONAL acceptance-phase fixtures alone must not flip the
    -- manifest to a warning state; only actual current fatal errors do.
    appendKey(lines, "manifest_status", currentFatalErrors == 0 and "complete" or "warning")

    local manifestPath = joinPath(bundleDir, "support_evidence_manifest.txt")
    writeFile(manifestPath, table.concat(lines, "\n") .. "\n", "wb")
    copiedFiles[#copiedFiles + 1] = "support_evidence_manifest.txt"
    return lines
end

local function collectPersistedRunDiagnostics(cacheLogDir, bundleDir, copiedFiles)
    local lines = {}
    local runsRoot = joinPath(cacheLogDir, "runs")
    local destRoot = joinPath(bundleDir, "runtime_runs")
    local maxRunsToInclude = 8
    ensureDir(destRoot)

    if not pathExists(runsRoot) then
        appendLine(lines, "- persisted runs folder missing")
        return lines
    end

    local allowed = {
        ["timing_events.jsonl"] = true,
        ["phase_events.jsonl"] = true,
        ["stdout.txt"] = true,
        ["separation_log.txt"] = true,
        ["benchmark_resource_samples.jsonl"] = true,
        ["benchmark_resource_summary.json"] = true,
        ["benchmark_resource_summary.txt"] = true,
        ["exit_code.txt"] = true,
        ["done.txt"] = true,
        ["run_bg.sh"] = true,
        ["worker_context.json"] = true,
    }
    local nestedAllowed = {
        joinPath("stage2_drumsep", "drumsep_helper_stdout.txt"),
        joinPath("stage2_drumsep", "drumsep_helper_stderr.txt"),
        joinPath("stage2_drumsep", "drumsep_result.json"),
        joinPath("stage2_drumsep", "drumsep_helper_result.json"),
        joinPath("stage2_drumsep", "result.json"),
        joinPath("stage2_drumsep", "stdout.txt"),
        joinPath("stage2_drumsep", "stderr.txt"),
    }

    local runDirNames = enumerateSubdirs(runsRoot)
    if #runDirNames == 0 then
        appendLine(lines, "- persisted runs folder empty")
        return lines
    end

    local runEntries = {}
    local unknownEntry = nil
    for _, runName in ipairs(runDirNames) do
        local runSrc = joinPath(runsRoot, runName)
        local epoch = 0
        if OS ~= "Windows" then
            local stat = getPathStat(runSrc)
            epoch = tonumber(stat.epoch) or 0
        end
        local entry = {
            name = runName,
            src = runSrc,
            epoch = epoch,
            isUnknown = (runName == "STEMwerk_unknown"),
        }
        if entry.isUnknown then
            unknownEntry = entry
        else
            runEntries[#runEntries + 1] = entry
        end
    end
    table.sort(runEntries, function(a, b)
        if OS == "Windows" then
            return tostring(a.name) > tostring(b.name)
        end
        if (a.epoch or 0) == (b.epoch or 0) then
            return tostring(a.name) > tostring(b.name)
        end
        return (a.epoch or 0) > (b.epoch or 0)
    end)

    local selectedRuns = {}
    for idx, entry in ipairs(runEntries) do
        if idx <= maxRunsToInclude then
            selectedRuns[#selectedRuns + 1] = entry
        end
    end
    local includedUnknown = false
    if #selectedRuns == 0 and unknownEntry then
        selectedRuns[#selectedRuns + 1] = unknownEntry
        includedUnknown = true
    end

    local copiedCount = 0
    for _, entry in ipairs(selectedRuns) do
        local runName = entry.name
        local runSrc = entry.src
        local runDst = joinPath(destRoot, runName)
        ensureDir(runDst)
        for _, jobName in ipairs(enumerateSubdirs(runSrc)) do
            local jobSrc = joinPath(runSrc, jobName)
            local jobDst = joinPath(runDst, jobName)
            ensureDir(jobDst)
            for _, fileName in ipairs(enumerateFiles(jobSrc)) do
                if allowed[fileName] then
                    local src = joinPath(jobSrc, fileName)
                    local dst = joinPath(jobDst, fileName)
                    local ok, mode = copySupportTextFile(src, dst, 512 * 1024)
                    if ok then
                        copiedCount = copiedCount + 1
                        copiedFiles[#copiedFiles + 1] = "runtime_runs/" .. runName .. "/" .. jobName .. "/" .. fileName .. " (" .. mode .. ")"
                    end
                end
            end
            for _, rel in ipairs(nestedAllowed) do
                local src = joinPath(jobSrc, rel)
                if fileExists(src) then
                    local dst = joinPath(jobDst, rel)
                    ensureDir(dirname(dst))
                    local ok, mode = copySupportTextFile(src, dst, 512 * 1024)
                    if ok then
                        copiedCount = copiedCount + 1
                        copiedFiles[#copiedFiles + 1] = "runtime_runs/" .. runName .. "/" .. jobName .. "/" .. rel .. " (" .. mode .. ")"
                    end
                end
            end
        end
    end

    appendLine(lines, string.format("- persisted run diagnostics copied: %d", copiedCount))
    local totalAvailable = #runEntries + (unknownEntry and 1 or 0)
    local skippedOlder = math.max(0, #runEntries - math.min(#runEntries, maxRunsToInclude))
    appendLine(lines, string.format("- persisted runs available: %d (real=%d, unknown=%d)", totalAvailable, #runEntries, unknownEntry and 1 or 0))
    appendLine(lines, string.format("- persisted runs included: %d (max %d)", #selectedRuns, maxRunsToInclude))
    appendLine(lines, string.format("- persisted runs skipped: %d", skippedOlder))
    appendLine(lines, string.format("- unknown included: %s", includedUnknown and "yes" or "no"))
    appendLine(lines, string.format("- Persistent run diagnostics: included %d of %d real runs; skipped %d older runs; unknown included %s",
        math.min(#runEntries, maxRunsToInclude),
        #runEntries,
        skippedOlder,
        includedUnknown and "yes" or "no"))
    if #selectedRuns > 0 then
        local ids = {}
        for _, entry in ipairs(selectedRuns) do
            ids[#ids + 1] = tostring(entry.name)
        end
        appendLine(lines, "- included run_ids: " .. table.concat(ids, ", "))
        appendLine(lines, "- Included runtime run IDs: " .. table.concat(ids, ", "))
    end
    appendKey(lines, "Persisted runs source", runsRoot)
    return lines
end

local function parseJsonStringField(line, key)
    local pattern = '"' .. tostring(key) .. '"%s*:%s*"(.-)"'
    local value = tostring(line or ""):match(pattern)
    if not value then return nil end
    value = value:gsub('\\"', '"'):gsub("\\\\", "\\")
    return trim(value)
end

local function parseJsonNumberField(line, key)
    local pattern = '"' .. tostring(key) .. '"%s*:%s*([%-]?[%d]+%.?[%d]*)'
    local value = tostring(line or ""):match(pattern)
    return tonumber(value)
end

local function kvAssignIfUnknown(entry, key, value)
    local v = trim(value)
    if v ~= "" and tostring(entry[key] or "") == "unknown" then
        entry[key] = v
        return true
    end
    return false
end

local function kvAssignLast(entry, key, value)
    local v = trim(value)
    if v ~= "" then
        entry[key] = v
    end
end

local function normalizeRelativeBundlePath(path)
    return tostring(path or ""):gsub("\\", "/")
end

local KNOWN_SUMMARY_MODELS = {
    "htdemucs",
    "htdemucs_ft",
    "htdemucs_6s",
}

local function parseCountValue(text)
    local n = tostring(text or ""):match("([0-9]+)")
    local v = tonumber(n)
    if v then
        return tostring(math.floor(v))
    end
    return nil
end

local function parseNumericToken(text)
    local n = tostring(text or ""):match("([%-]?[%d]+%.?[%d]*)")
    return tonumber(n)
end

local function formatSecondsValue(raw)
    local n = parseNumericToken(raw)
    if not n then return nil end
    return string.format("%.1fs", n)
end

local function formatRealtimeValue(raw)
    local n = parseNumericToken(raw)
    if not n then return nil end
    return string.format("%.2fx", n)
end

local function containsKnownModel(line)
    -- Lua patterns have no regex-style alternation ("|"). The previous
    -- pattern "(^|[^%w_%-])(model)([^%w_%-]|$)" matched the literal
    -- characters "^|" / "|$" (which essentially never occur in real log
    -- text) instead of anchoring at the start/end of the string, so this
    -- effectively never matched. Word-boundary matching is done explicitly
    -- below instead.
    local lower = tostring(line or ""):lower()
    for i = 1, #KNOWN_SUMMARY_MODELS do
        local model = KNOWN_SUMMARY_MODELS[i]
        local searchFrom = 1
        while true do
            local s, e = lower:find(model, searchFrom, true)
            if not s then break end
            local before = s > 1 and lower:sub(s - 1, s - 1) or ""
            local after = e < #lower and lower:sub(e + 1, e + 1) or ""
            local beforeOk = before == "" or before:match("[^%w_%-]") ~= nil
            local afterOk = after == "" or after:match("[^%w_%-]") ~= nil
            if beforeOk and afterOk then
                return model
            end
            searchFrom = s + 1
        end
    end
    return nil
end

local function setRunResult(entry, result, priority)
    result = trim(result):lower()
    if result ~= "success" and result ~= "fail" and result ~= "partial" and result ~= "unknown" and result ~= "cancelled" then
        return
    end
    local p = tonumber(priority) or 0
    local currentP = tonumber(entry._resultPriority or 0) or 0
    if p >= currentP then
        entry.result = result
        entry._resultPriority = p
    end
end

local function setFailureReason(entry, reason)
    local value = trim(reason)
    if value ~= "" and tostring(entry.error_reason or "unknown") == "unknown" then
        entry.error_reason = value
    end
end

local function parseKeyValueLine(line)
    local key, value = tostring(line or ""):match("^%s*([%w%._%-%s/]+)%s*[:=]%s*(.-)%s*$")
    if not key then return nil, nil end
    key = trim(key):lower():gsub("%s+", "_")
    value = trim(value)
    if key == "" or value == "" then return nil, nil end
    return key, value
end

local function parseSupportRunText(entry, text)
    local fullText = tostring(text or "")
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local lower = raw:lower()
        if lower == "done" or lower == "success" or lower == "complete" then
            entry._sawDoneSuccess = (entry._sawDoneSuccess or 0) + 1
            entry._positiveHints = (entry._positiveHints or 0) + 1
        end
        if lower:find("progress:100", 1, true) or lower:find("processing complete", 1, true)
            or lower:find("completed successfully", 1, true) then
            entry._sawProgressComplete = (entry._sawProgressComplete or 0) + 1
            entry._positiveHints = (entry._positiveHints or 0) + 1
        end
        if lower:find("user_cancel", 1, true) then
            entry._sawUserCancel = (entry._sawUserCancel or 0) + 1
        end
        local key, value = parseKeyValueLine(raw)
        if key then
            if key == "result" then
                local resultValue = value:lower()
                if resultValue:find("success", 1, true) or resultValue:find("ok", 1, true) or resultValue:find("done", 1, true) then
                    setRunResult(entry, "success", 4)
                elseif resultValue:find("partial", 1, true) then
                    setRunResult(entry, "partial", 4)
                elseif resultValue:find("fail", 1, true) or resultValue:find("error", 1, true) then
                    setRunResult(entry, "fail", 4)
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                end
            elseif key == "mode" then
                kvAssignIfUnknown(entry, "mode", value)
            elseif key == "model" or key == "model_name" then
                kvAssignIfUnknown(entry, "model", value)
            elseif key == "selected_model" then
                kvAssignIfUnknown(entry, "model", value)
            elseif key == "device" then
                kvAssignIfUnknown(entry, "device", value)
            elseif key == "workflow_mode" then
                kvAssignLast(entry, "workflow_mode", value)
            elseif key == "workflow_source" then
                kvAssignLast(entry, "workflow_source", value)
            elseif key == "backend" then
                kvAssignIfUnknown(entry, "backend", value)
            elseif key == "backend_runtime" then
                kvAssignLast(entry, "backend_runtime", value)
            elseif key == "drumsep_runtime_selected" or key == "runtime_selected" then
                kvAssignLast(entry, "runtime_selected", value)
            elseif key == "device_name" or key == "gpu_name" then
                kvAssignLast(entry, "device_name", value)
            elseif key == "torch_hip_version" or key == "hip_version" then
                kvAssignLast(entry, "torch_hip_version", value)
            elseif key == "profile" then
                kvAssignIfUnknown(entry, "profile", value)
            elseif key == "output_validation_reason" then
                kvAssignLast(entry, "output_validation_reason", value)
            elseif key == "expected_stems" then
                kvAssignLast(entry, "expected_stems", value)
            elseif key == "found_stems" then
                kvAssignLast(entry, "found_stems", value)
            elseif key == "found_files" then
                kvAssignLast(entry, "found_files", value)
            elseif key == "expected_outputs" then
                if tostring(entry.expected_stems or "unknown") == "unknown" then
                    kvAssignLast(entry, "expected_stems", value)
                end
            elseif key == "created_outputs" then
                if tostring(entry.found_files or "unknown") == "unknown" then
                    kvAssignLast(entry, "found_files", value)
                end
            elseif key == "jobs" then
                local count = parseCountValue(value)
                if count then kvAssignLast(entry, "jobs", count) end
            elseif key == "items" or key == "item_count" then
                local count = parseCountValue(value)
                if count then kvAssignLast(entry, "items", count) end
            elseif key == "wall_clock_total" then
                kvAssignLast(entry, "wall_clock_total", formatSecondsValue(value) or value)
            elseif key == "total_source_duration" or key == "total_source_dur" or key == "source_duration" or key == "total_source_duration_s" then
                kvAssignLast(entry, "total_source_duration", formatSecondsValue(value) or value)
            elseif key == "avg_realtime_factor" or key == "realtime_factor" then
                kvAssignLast(entry, "realtime_factor", formatRealtimeValue(value) or value)
            elseif key == "speed" then
                if value:find("x", 1, true) or value:lower():find("realtime", 1, true) then
                    kvAssignLast(entry, "realtime_factor", formatRealtimeValue(value) or value)
                end
            elseif key == "reason" or key == "error" or key == "failure_reason" then
                if value ~= "" and value:lower() ~= "none" and value ~= "0" then
                    if value:lower():find("partial_dks_multi", 1, true) then
                        kvAssignLast(entry, "error_reason", "partial_dks_multi")
                        setRunResult(entry, "partial", 6)
                    elseif value:lower():find("user_cancel", 1, true) then
                        entry._sawUserCancel = (entry._sawUserCancel or 0) + 1
                        kvAssignLast(entry, "error_reason", "user_cancel")
                        setRunResult(entry, "cancelled", 5)
                    else
                        setFailureReason(entry, value)
                        entry._clearFailures = (entry._clearFailures or 0) + 1
                        setRunResult(entry, "fail", 4)
                    end
                end
            elseif key == "error_class" or key == "stemwerk_error_class" then
                kvAssignLast(entry, "error_class", value)
                setRunResult(entry, "fail", 5)
                entry._clearFailures = (entry._clearFailures or 0) + 1
            elseif key == "error_hint" or key == "stemwerk_error_hint" then
                kvAssignLast(entry, "error_hint", value)
            elseif key == "model_cache_hint" or key == "stemwerk_model_cache_hint" then
                kvAssignLast(entry, "model_cache_hint", value)
            elseif key == "model_url" or key == "stemwerk_model_url" then
                kvAssignLast(entry, "model_url", value)
            elseif key == "model_path" or key == "stemwerk_model_path" then
                kvAssignLast(entry, "model_path", value)
            elseif key == "status" then
                local status = value:lower()
                if status:find("fail", 1, true) or status:find("error", 1, true) then
                    setRunResult(entry, "fail", 4)
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                elseif status:find("success", 1, true) or status:find("ok", 1, true) then
                    setRunResult(entry, "success", 4)
                end
            elseif key == "timestamp" then
                kvAssignLast(entry, "timestamp", value)
            elseif key == "exit_code" and tonumber(value) then
                local rc = tonumber(value)
                kvAssignLast(entry, "exit_code", tostring(rc))
                if rc == 0 then
                    entry._sawExitZero = (entry._sawExitZero or 0) + 1
                elseif rc == 143 then
                    entry._sawUserCancel = (entry._sawUserCancel or 0) + 1
                    kvAssignLast(entry, "error_reason", "user_cancel")
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                    setRunResult(entry, "cancelled", 5)
                else
                    kvAssignLast(entry, "error_reason", "exit_code: " .. tostring(value))
                    entry._exitNonZero = (entry._exitNonZero or 0) + 1
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                    setRunResult(entry, "fail", 4)
                end
            elseif key == "error_or_cancel" then
                local ec = tonumber(value)
                if ec and ec > 0 then
                    entry._clearFailures = (entry._clearFailures or 0) + ec
                    setFailureReason(entry, "error_or_cancel: " .. tostring(ec))
                    setRunResult(entry, "fail", 4)
                end
            end
        end

        local modelFromFlag = raw:match("%-%-model%s+\"?([%w%._%-]+)\"?")
        if modelFromFlag then
            kvAssignIfUnknown(entry, "model", modelFromFlag)
        end
        local selectedModel = raw:match("^[Ss]elected%s+[Mm]odel%s*[:=]%s*(.+)$")
        if selectedModel then
            kvAssignIfUnknown(entry, "model", trim(selectedModel))
        end
        if tostring(entry.model or "unknown") == "unknown" then
            local known = containsKnownModel(raw)
            if known then kvAssignIfUnknown(entry, "model", known) end
        end

        local totalDurRaw = raw:match("[Tt]otal[_%s]+source[_%s]+duration%s*[:=]%s*([%d%.]+)")
            or raw:match("[Ss]ource[_%s]+duration%s*[:=]%s*([%d%.]+)")
        if totalDurRaw and tostring(entry.total_source_duration or "unknown") == "unknown" then
            kvAssignLast(entry, "total_source_duration", formatSecondsValue(totalDurRaw) or totalDurRaw)
        end
        local realtimeRaw = raw:match("[Aa]vg[_%s]+realtime[_%s]+factor%s*[:=]%s*([%d%.]+)")
            or raw:match("[Rr]ealtime[_%s]+factor%s*[:=]%s*([%d%.]+)")
            or raw:match("[Ss]peed%s*[:=]%s*([%d%.]+)%s*x")
            or raw:match("([%d%.]+)%s*x%s*[Rr]ealtime")
        if realtimeRaw and tostring(entry.realtime_factor or "unknown") == "unknown" then
            kvAssignLast(entry, "realtime_factor", formatRealtimeValue(realtimeRaw) or realtimeRaw)
        end

        if lower:find("processing complete", 1, true) or lower:find("completed successfully", 1, true) then
            entry._positiveHints = (entry._positiveHints or 0) + 1
            if tostring(entry.result or "unknown") == "unknown" then
                setRunResult(entry, "success", 2)
            end
        end
        if lower:find("import_end", 1, true) then
            entry._positiveHints = (entry._positiveHints or 0) + 1
        end

        local selected = raw:match("^STEMWERK_DIAG%s+selected_device=(.+)$")
        if selected then
            kvAssignIfUnknown(entry, "device", selected)
            kvAssignLast(entry, "selected_device", selected)
        end
        local requested = raw:match("^STEMWERK_DIAG%s+requested_device=(.+)$")
        if requested then
            kvAssignLast(entry, "requested_device", requested)
            if tostring(entry.device or "unknown") == "unknown" then
                kvAssignIfUnknown(entry, "device", requested)
            end
        end
        local effective = raw:match("^STEMWERK_DIAG%s+effective_device=(.+)$")
        if effective then
            kvAssignLast(entry, "effective_device", effective)
            kvAssignLast(entry, "device", effective)
        end
        local mpsExperimental = raw:match("^STEMWERK_DIAG%s+mps_experimental=(.+)$")
        if mpsExperimental then
            kvAssignLast(entry, "mps_experimental", mpsExperimental)
        end
        local mpsSegmentSize = raw:match("^STEMWERK_DIAG%s+mps_segment_size=(.+)$")
        if mpsSegmentSize then
            kvAssignLast(entry, "mps_segment_size", mpsSegmentSize)
        end
        local mpsSegmentPolicy = raw:match("^STEMWERK_DIAG%s+mps_segment_policy=(.+)$")
        if mpsSegmentPolicy then
            kvAssignLast(entry, "mps_segment_policy", mpsSegmentPolicy)
        end
        local mpsFallbackUsed = raw:match("^STEMWERK_DIAG%s+mps_fallback_used=(.+)$")
        if mpsFallbackUsed then
            kvAssignLast(entry, "mps_fallback_used", mpsFallbackUsed)
        end
        local mpsFallbackReason = raw:match("^STEMWERK_DIAG%s+mps_fallback_reason=(.+)$")
        if mpsFallbackReason then
            kvAssignLast(entry, "mps_fallback_reason", mpsFallbackReason)
        end
        local autoSelected = raw:match("^STEMWERK_DIAG%s+auto_selected[_%w]*=([%w%-%_:%.%/]+)")
        if autoSelected and tostring(entry.device or "unknown") == "unknown" then
            kvAssignIfUnknown(entry, "device", autoSelected)
        end

        local inlineWorkflowMode = raw:match("workflow_mode=([%w_:%-]+)")
        if inlineWorkflowMode then
            kvAssignLast(entry, "workflow_mode", inlineWorkflowMode)
        end
        local inlineWorkflowSource = raw:match("workflow_source=([%w_:%-]+)")
        if inlineWorkflowSource then
            kvAssignLast(entry, "workflow_source", inlineWorkflowSource)
        end
        local inlineRequested = raw:match("requested_device=([%w_:%-]+)")
        if inlineRequested then
            kvAssignLast(entry, "requested_device", inlineRequested)
        end
        local inlineUiRequested = raw:match("ui_device_selected_before_run=([%w_:%-]+)")
        if inlineUiRequested then
            kvAssignLast(entry, "ui_device_selected_before_run", inlineUiRequested)
        end
        local inlineBackendDevice = raw:match("backend_device_arg=([%w_:%-]+)")
        if inlineBackendDevice then
            kvAssignLast(entry, "backend_device_arg", inlineBackendDevice)
        end
        local inlineEffective = raw:match("effective_device=([%w_:%-]+)")
        if inlineEffective then
            kvAssignLast(entry, "effective_device", inlineEffective)
            kvAssignLast(entry, "device", inlineEffective)
        end
        local inlineRuntimeSelected = raw:match("drumsep_runtime_selected=([%w_:%-]+)")
        if inlineRuntimeSelected then
            kvAssignLast(entry, "runtime_selected", inlineRuntimeSelected)
        end
        local inlineHelperRequested = raw:match("drumsep_helper_requested_device=([%w_:%-]+)")
        if inlineHelperRequested then
            kvAssignLast(entry, "drumsep_helper_requested_device", inlineHelperRequested)
        end
        local inlineHelperBackend = raw:match("drumsep_helper_backend_runtime=([%w_:%-]+)")
        if inlineHelperBackend then
            kvAssignLast(entry, "backend_runtime", inlineHelperBackend)
            kvAssignLast(entry, "drumsep_helper_backend_runtime", inlineHelperBackend)
        end
        local inlineHelperDevice = raw:match("drumsep_helper_device=([%w_:%-]+)")
        if inlineHelperDevice then
            kvAssignLast(entry, "drumsep_helper_device", inlineHelperDevice)
            if tostring(entry.effective_device or "unknown") == "unknown" then
                kvAssignLast(entry, "effective_device", inlineHelperDevice)
            end
        end
        local inlineHelperDeviceArg = raw:match("drumsep_helper_device_arg=([%w_:%-]+)")
        if inlineHelperDeviceArg then
            kvAssignLast(entry, "drumsep_helper_device_arg", inlineHelperDeviceArg)
        end

        -- DrumSep (Direct Kit / Kit Split stage 2) reports its own model
        -- identity separately from the generic Demucs `model=`/`--model`
        -- markers above -- it must never be conflated with them.
        local drumsepModelId = raw:match("model_id=([%w%._%-]+)")
        if drumsepModelId then
            kvAssignLast(entry, "drumsep_model_id", drumsepModelId)
        end
        local drumsepRequestedModel = raw:match("requested_model=([%w%._%-]+)")
        if drumsepRequestedModel then
            kvAssignLast(entry, "drumsep_requested_model", drumsepRequestedModel)
        end
        local drumsepHelperModel = raw:match("drumsep_helper_model=([%w%._%-]+)")
        if drumsepHelperModel then
            kvAssignLast(entry, "drumsep_helper_model", drumsepHelperModel)
        end

        -- Kit Split (dks_extract) runs two distinct stages: stage 1 is the
        -- Demucs pass (htdemucs_6s), stage 2 is DrumSep on the extracted
        -- drum stem. Each stage's own runtime/device must be kept separate
        -- rather than collapsed into one pair of fields.
        local stage1Runtime = raw:match("dks_extract_stage1_runtime=([%w_:%-]+)")
        if stage1Runtime then kvAssignLast(entry, "stage1_runtime", stage1Runtime) end
        local stage1Device = raw:match("dks_extract_stage1_device=([%w_:%-]+)")
        if stage1Device then kvAssignLast(entry, "stage1_device", stage1Device) end
        local stage2Runtime = raw:match("dks_extract_stage2_runtime=([%w_:%-]+)")
        if stage2Runtime then kvAssignLast(entry, "stage2_runtime", stage2Runtime) end
        local stage2Device = raw:match("dks_extract_stage2_device=([%w_:%-]+)")
        if stage2Device then kvAssignLast(entry, "stage2_device", stage2Device) end

        if lower:find("traceback", 1, true) then
            entry._clearFailures = (entry._clearFailures or 0) + 1
            setRunResult(entry, "fail", 4)
            setFailureReason(entry, "traceback detected")
        elseif lower:match("^error:%s*.+$") then
            entry._clearFailures = (entry._clearFailures or 0) + 1
            setRunResult(entry, "fail", 4)
            setFailureReason(entry, trim(raw:gsub("^[Ee][Rr][Rr][Oo][Rr]:%s*", "")))
        end
    end

    local lowerAll = fullText:lower()
    local hasTimeout = lowerAll:find("read timed out", 1, true) or lowerAll:find("httpsconnectionpool", 1, true)
        or lowerAll:find("max retries exceeded", 1, true) or lowerAll:find("timeouterror", 1, true)
    local hasDownload = lowerAll:find("dl.fbaipublicfiles.com", 1, true) or lowerAll:find("connectionerror", 1, true)
        or lowerAll:find("temporary failure in name resolution", 1, true) or lowerAll:find("name or service not known", 1, true)
        or lowerAll:find("certificate verify failed", 1, true)
    local hasChecksum = lowerAll:find("invalid checksum", 1, true) or (lowerAll:find("checksum", 1, true) and lowerAll:find(".th", 1, true))
    local hasUnsupportedModelId = lowerAll:find("not found in supported model files", 1, true) and lowerAll:find("model file", 1, true)
    if hasTimeout or hasDownload or hasChecksum then
        entry._sawModelFailureEvidence = (entry._sawModelFailureEvidence or 0) + 1
    end
    if hasUnsupportedModelId and tostring(entry.error_class or "unknown") == "unknown" then
        kvAssignLast(entry, "error_class", "model_mapping_failed")
        kvAssignLast(entry, "error_hint", "Normal model setup failed internally. Save a Support Bundle and run Setup/Repair before retrying.")
        kvAssignLast(entry, "model_cache_hint", "This is not an internet/DNS/proxy failure. STEMwerk passed an unsupported internal model id to audio-separator.")
        setRunResult(entry, "fail", 5)
        entry._clearFailures = (entry._clearFailures or 0) + 1
    elseif hasChecksum and tostring(entry.error_class or "unknown") == "unknown" then
        kvAssignLast(entry, "error_class", "model_checksum_failed")
        kvAssignLast(entry, "error_hint", "Cached model file appears corrupted. Delete/redownload model cache.")
        kvAssignLast(entry, "model_cache_hint", "Delete corrupted/partial files in the STEMwerk models folder and retry.")
        setRunResult(entry, "fail", 5)
        entry._clearFailures = (entry._clearFailures or 0) + 1
    elseif hasTimeout and tostring(entry.error_class or "unknown") == "unknown" then
        kvAssignLast(entry, "error_class", "model_download_timeout")
        kvAssignLast(entry, "error_hint", "Model download timed out. Check network/VPN/firewall or delete partial model cache and retry.")
        setRunResult(entry, "fail", 5)
        entry._clearFailures = (entry._clearFailures or 0) + 1
    elseif hasDownload and tostring(entry.error_class or "unknown") == "unknown" then
        kvAssignLast(entry, "error_class", "model_download_failed")
        kvAssignLast(entry, "error_hint", "Model download failed. Check internet/DNS/proxy/VPN/firewall and retry.")
        setRunResult(entry, "fail", 5)
        entry._clearFailures = (entry._clearFailures or 0) + 1
    end
end

local function finalizeRunClassification(entry)
    local hasExitZero = tonumber(entry._sawExitZero or 0) > 0
    local hasDoneSuccess = tonumber(entry._sawDoneSuccess or 0) > 0
    local hasProgressComplete = tonumber(entry._sawProgressComplete or 0) > 0
    local hasStemsOutput = tonumber(entry._sawStemsOutput or 0) > 0
    local hasCancel = tonumber(entry._sawUserCancel or 0) > 0
    local hasModelEvidence = tonumber(entry._sawModelFailureEvidence or 0) > 0
    -- _clearFailures/_exitNonZero accumulate across every job in the run
    -- (nonzero exit codes, tracebacks, ERROR: lines, model-failure
    -- evidence, etc.). A run with multiple jobs must not be classified as a
    -- strong success just because SOME job in it produced positive signals
    -- -- one successful job must never clear a genuine failure recorded by
    -- a different job in the same run.
    local hasAnyClearFailure = tonumber(entry._clearFailures or 0) > 0
        or tonumber(entry._exitNonZero or 0) > 0
    local strongSuccess = (hasExitZero and hasDoneSuccess)
        or (hasExitZero and hasProgressComplete)
        or (hasDoneSuccess and hasStemsOutput)
    strongSuccess = strongSuccess and not hasAnyClearFailure

    if strongSuccess then
        setRunResult(entry, "success", 100)
        entry.error_class = "unknown"
        entry.error_hint = "unknown"
        entry.model_cache_hint = "unknown"
        entry.model_url = "unknown"
        entry.model_path = "unknown"
        entry.error_reason = "unknown"
        entry._clearFailures = 0
        entry._exitNonZero = 0
        return
    end

    if hasCancel and not hasModelEvidence then
        setRunResult(entry, "cancelled", 90)
        if tostring(entry.error_class or "unknown"):find("^model_", 1) then
            entry.error_class = "unknown"
        end
        if tostring(entry.error_hint or "unknown") ~= "unknown" then
            entry.error_hint = "unknown"
        end
        if tostring(entry.error_reason or "unknown") == "unknown" then
            entry.error_reason = "user_cancel"
        end
    end
end

local function updateRunFromTimingJson(entry, path, stat)
    local content = readFile(path, "rb")
    if not content then return end
    local foundTime = false
    for line in tostring(content):gmatch("[^\r\n]+") do
        local t = parseJsonNumberField(line, "time")
        if t then
            foundTime = true
            if not stat.minTime or t < stat.minTime then stat.minTime = t end
            if not stat.maxTime or t > stat.maxTime then stat.maxTime = t end
        end
        local mode = parseJsonStringField(line, "mode")
        if mode then kvAssignIfUnknown(entry, "mode", mode) end
        local model = parseJsonStringField(line, "model")
        if model then kvAssignIfUnknown(entry, "model", model) end
        local device = parseJsonStringField(line, "device")
        if device then kvAssignIfUnknown(entry, "device", device) end
        local outputNames = parseJsonStringField(line, "output_names")
            or parseJsonStringField(line, "found_stems")
            or parseJsonStringField(line, "found_files")
        if outputNames then
            kvAssignLast(entry, "found_stems", outputNames)
            kvAssignLast(entry, "found_files", outputNames)
        end
        local outputCount = parseJsonNumberField(line, "output_count")
        if outputCount and tostring(entry.found_stems or "unknown") == "unknown" then
            kvAssignLast(entry, "found_stems", tostring(outputCount))
        end
        local validationReason = parseJsonStringField(line, "output_validation_reason")
        if validationReason then kvAssignLast(entry, "output_validation_reason", validationReason) end
        local result = parseJsonStringField(line, "result")
        if result then
            local lr = result:lower()
            if lr:find("success", 1, true) or lr:find("done", 1, true) or lr:find("ok", 1, true) then
                setRunResult(entry, "success", 4)
            elseif lr:find("partial", 1, true) then
                setRunResult(entry, "partial", 4)
            elseif lr:find("fail", 1, true) or lr:find("error", 1, true) then
                setRunResult(entry, "fail", 4)
                entry._clearFailures = (entry._clearFailures or 0) + 1
            end
        end
        local audioDur = parseJsonNumberField(line, "audio_dur")
        if audioDur then
            stat.audioDurByJob = stat.audioDurByJob or {}
            local jobId = parseJsonStringField(line, "job_id") or tostring(parseJsonNumberField(line, "job_index") or "")
            if jobId ~= "" and not stat.audioDurByJob[jobId] then
                stat.audioDurByJob[jobId] = audioDur
                stat.totalAudioDur = (stat.totalAudioDur or 0) + audioDur
            end
        end
    end
    if foundTime and tostring(entry.log_path or "unknown") == "unknown" then
        entry.log_path = normalizeRelativeBundlePath(relativePath(entry.bundle_root, path))
    end
end

local function deriveRunResultFromJobs(entry, stat)
    local jobs = tonumber(entry.jobs) or 0
    local doneOk = tonumber(stat.doneOk or 0) or 0
    local exitErr = tonumber(stat.exitErr or 0) or 0
    local clearFailures = tonumber(entry._clearFailures or 0) or 0
    local positives = tonumber(entry._positiveHints or 0) or 0

    if tostring(entry.result or "unknown") == "success" or tostring(entry.result or "unknown") == "fail" or tostring(entry.result or "unknown") == "partial" then
        return
    end

    if jobs > 0 then
        if doneOk == jobs and clearFailures == 0 and exitErr == 0 then
            setRunResult(entry, "success", 3)
        elseif doneOk > 0 and (clearFailures > 0 or exitErr > 0) then
            setRunResult(entry, "partial", 3)
        elseif doneOk == 0 and (clearFailures > 0 or exitErr > 0) then
            setRunResult(entry, "fail", 3)
        elseif positives > 0 and clearFailures == 0 and exitErr == 0 then
            setRunResult(entry, "success", 2)
        else
            setRunResult(entry, "unknown", 1)
        end
    else
        if clearFailures > 0 or exitErr > 0 then
            setRunResult(entry, "fail", 2)
        elseif positives > 0 then
            setRunResult(entry, "success", 2)
        else
            setRunResult(entry, "unknown", 1)
        end
    end

    if (tostring(entry.result or "unknown") == "fail" or tostring(entry.result or "unknown") == "partial")
        and tostring(entry.error_reason or "unknown") == "unknown" then
        local reasons = {}
        if clearFailures > 0 then
            reasons[#reasons + 1] = string.format("failure markers: %d", clearFailures)
        end
        if exitErr > 0 then
            reasons[#reasons + 1] = string.format("nonzero exit codes: %d", exitErr)
        end
        if #reasons > 0 then
            entry.error_reason = table.concat(reasons, ", ")
        end
    end
end

local function parseRunStemwerkLogSummary(bundleDir, capabilityState, runtimeState)
    local path = joinPath(bundleDir, "runtime_logs", "run_stemwerk.log")
    local data = readFile(path, "rb")
    if not data or trim(data) == "" then
        return nil
    end

    local entry = {
        run_name = "latest_stemwerk_log",
        timestamp = "unknown",
        result = "unknown",
        model = "unknown",
        backend = trim(capabilityState.BACKEND or runtimeState.BACKEND or "") ~= "" and trim(capabilityState.BACKEND or runtimeState.BACKEND or "") or "unknown",
        profile = trim(capabilityState.PROFILE or runtimeState.PROFILE or "") ~= "" and trim(capabilityState.PROFILE or runtimeState.PROFILE or "") or "unknown",
        device = "unknown",
        mode = "unknown",
        jobs = "unknown",
        items = "unknown",
        wall_clock_total = "unknown",
        total_source_duration = "unknown",
        realtime_factor = "unknown",
        error_reason = "unknown",
        log_path = "runtime_logs/run_stemwerk.log",
    }

    local sawLaunch = false
    local lastRc = nil
    for line in tostring(data):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local ts = raw:match("^%[([0-9][^%]]+)%]%s+CMD:")
        if ts then
            entry.timestamp = ts
        end
        local cmd = raw:match("^%[[^%]]+%]%s+CMD:%s*(.+)$")
        if cmd then
            if cmd:find("LAUNCH:", 1, true) then
                sawLaunch = true
                local model = cmd:match("%-%-model%s+\"?([%w%._%-]+)\"?")
                if model then kvAssignIfUnknown(entry, "model", model) end
                local device = cmd:match("%-%-device%s+\"?([%w%._%-%:]+)\"?")
                if device then kvAssignIfUnknown(entry, "device", device) end
            end
            local mode = cmd:match("mode=([%w_%-]+)")
            if mode then kvAssignIfUnknown(entry, "mode", mode) end
            local jobs = cmd:match("count=(%d+)")
            if jobs then kvAssignLast(entry, "jobs", jobs) end
        end
        parseSupportRunText(entry, raw)
        local rc = raw:match("^RC:%s*([%-]?%d+)")
        if rc then
            lastRc = tonumber(rc)
            if lastRc and lastRc ~= 0 then
                entry._exitNonZero = (entry._exitNonZero or 0) + 1
                entry._clearFailures = (entry._clearFailures or 0) + 1
            end
        end
    end

    if lastRc ~= nil and tostring(entry.result or "unknown") == "unknown" then
        if lastRc == 0 then
            setRunResult(entry, "success", 2)
        else
            setRunResult(entry, "fail", 2)
        end
        if lastRc ~= 0 and tostring(entry.error_reason or "unknown") == "unknown" then
            entry.error_reason = "exit_code: " .. tostring(lastRc)
        end
    end
    return sawLaunch and entry or nil
end

local function parseRuntimeStemwerkLogByRun(bundleDir, capabilityState, runtimeState)
    local path = joinPath(bundleDir, "runtime_logs", "run_stemwerk.log")
    local data = readFile(path, "rb")
    if not data or trim(data) == "" then
        return {}
    end

    local byRun = {}
    local lastRunId = nil
    local function getRun(runId)
        local key = tostring(runId or "")
        if key == "" then return nil end
        if not byRun[key] then
            byRun[key] = {
                run_name = key,
                timestamp = "unknown",
                result = "unknown",
                model = "unknown",
                backend = trim(capabilityState.BACKEND or runtimeState.BACKEND or "") ~= "" and trim(capabilityState.BACKEND or runtimeState.BACKEND or "") or "unknown",
                profile = trim(capabilityState.PROFILE or runtimeState.PROFILE or "") ~= "" and trim(capabilityState.PROFILE or runtimeState.PROFILE or "") or "unknown",
                device = "unknown",
                mode = "unknown",
                jobs = "unknown",
                items = "unknown",
                wall_clock_total = "unknown",
                total_source_duration = "unknown",
                realtime_factor = "unknown",
                error_reason = "unknown",
                log_path = "runtime_logs/run_stemwerk.log",
                _clearFailures = 0,
                _positiveHints = 0,
                _resultPriority = 0,
                _exitNonZero = 0,
                _seenModels = {},
                _seenDevices = {},
            }
        end
        return byRun[key]
    end

    for line in tostring(data):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local ts = raw:match("^%[([0-9][^%]]+)%]")
        local runId = raw:match("(STEMwerk_[%w_%-]+)")
        -- A LAUNCH line always starts a new logical launch/session block. A
        -- tokenless line may only inherit the previous block's run-ID while
        -- it is still part of THAT block; once a new LAUNCH boundary is
        -- crossed (with or without its own token), the previous run's
        -- identity must not keep leaking into whatever tokenless lines
        -- follow it -- that would associate a brand-new, unrelated launch
        -- with the prior run. A non-LAUNCH line carrying its own token also
        -- (re)anchors the current block, e.g. for a replayed/duplicate ID.
        local isLaunchLine = raw:find("CMD:", 1, true) ~= nil and raw:find("LAUNCH:", 1, true) ~= nil
        if isLaunchLine then
            lastRunId = runId
        elseif runId then
            lastRunId = runId
        end

        local cmd = raw:match("^%[[^%]]+%]%s+CMD:%s*(.+)$") or raw
        local targetRun = runId and getRun(runId) or (lastRunId and getRun(lastRunId) or nil)
        if targetRun then
            if ts then targetRun.timestamp = ts end
            parseSupportRunText(targetRun, raw)

            local model = cmd:match("%-%-model%s+\"?([%w%._%-]+)\"?")
            if model then
                targetRun._seenModels[model] = true
                kvAssignIfUnknown(targetRun, "model", model)
            end
            local device = cmd:match("%-%-device%s+\"?([%w%._%-%:]+)\"?")
            if device then
                targetRun._seenDevices[device] = true
                kvAssignIfUnknown(targetRun, "device", device)
            end
            local mode = cmd:match("mode=([%w_%-]+)")
            if mode then kvAssignIfUnknown(targetRun, "mode", mode) end
            local jobs = cmd:match("count=(%d+)")
            if jobs then
                kvAssignLast(targetRun, "jobs", jobs)
                if tostring(targetRun.items or "unknown") == "unknown" then
                    kvAssignLast(targetRun, "items", jobs)
                end
            end

            local rc = raw:match("^RC:%s*([%-]?%d+)")
            if rc then
                local code = tonumber(rc)
                if code and code ~= 0 then
                    targetRun._exitNonZero = (targetRun._exitNonZero or 0) + 1
                    targetRun._clearFailures = (targetRun._clearFailures or 0) + 1
                elseif code == 0 and tostring(targetRun.result or "unknown") == "unknown" then
                    setRunResult(targetRun, "success", 2)
                end
            end
        end
    end

    -- A replayed/reused run-ID token (the same run-ID appearing more than
    -- once in run_stemwerk.log with genuinely different model/device
    -- evidence) cannot be told apart from a single run's evidence by key
    -- alone. Silently keeping whichever value was seen first would present
    -- a guess as fact; surface the ambiguity instead.
    local function distinctCount(set)
        local n = 0
        for _ in pairs(set or {}) do n = n + 1 end
        return n
    end
    for _, run in pairs(byRun) do
        if distinctCount(run._seenModels) > 1 then
            run.model = "ambiguous"
        end
        if distinctCount(run._seenDevices) > 1 then
            run.device = "ambiguous"
        end
    end
    return byRun
end

local function parseTimingSummaryEntry(bundleDir, capabilityState, runtimeState)
    local timingSummaryPath = joinPath(bundleDir, "runtime_logs", "run_separation_timing_summary.txt")
    if not fileExists(timingSummaryPath) then return nil end
    local data = readFile(timingSummaryPath, "rb")
    if not data or trim(data) == "" then return nil end

    local entry = {
        run_name = "latest_persistent",
        timestamp = "unknown",
        result = "unknown",
        model = "unknown",
        backend = trim(capabilityState.BACKEND or runtimeState.BACKEND or "") ~= "" and trim(capabilityState.BACKEND or runtimeState.BACKEND or "") or "unknown",
        profile = trim(capabilityState.PROFILE or runtimeState.PROFILE or "") ~= "" and trim(capabilityState.PROFILE or runtimeState.PROFILE or "") or "unknown",
        device = "unknown",
        mode = "unknown",
        jobs = "unknown",
        items = "unknown",
        wall_clock_total = "unknown",
        total_source_duration = "unknown",
        realtime_factor = "unknown",
        error_reason = "unknown",
        log_path = "runtime_logs/run_separation_timing_summary.txt",
        _clearFailures = 0,
        _positiveHints = 0,
        _resultPriority = 0,
        _exitNonZero = 0,
    }
    parseSupportRunText(entry, data)
    return entry
end

-- NOTE: a previous "reconstructed session" positional-association helper
-- (parseRuntimeStemwerkSessions) lived here. It inferred sessions purely
-- from launch order within run_stemwerk.log with no run-ID token of its
-- own, so it could only ever be paired with a persisted run by array
-- position -- never by a verifiable identity. That is exactly the guessed
-- positional association exact-key matching is meant to prevent, so it was
-- removed rather than kept as an unused fallback; run/log association is
-- exact run-ID-key-only via parseRuntimeStemwerkLogByRun below.

local UNIVERSAL_STEM_NAMES = { "vocals", "drums", "bass", "other", "guitar", "piano" }

-- Determines THIS job's own found-output count from its own evidence only
-- (never from another job's, and never from the shared run-level `entry`
-- table, which only ever keeps the first job's values once set). Used to
-- aggregate outputs across parallel jobs instead of only inferring an
-- output count when jobs==1.
local function jobOwnOutputEvidence(jobDir)
    local found = nil
    local validation = nil
    for _, fileName in ipairs({ "phase_events.jsonl", "timing_events.jsonl" }) do
        local data = readFile(joinPath(jobDir, fileName), "rb")
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                local names = parseJsonStringField(line, "output_names")
                    or parseJsonStringField(line, "found_stems")
                    or parseJsonStringField(line, "found_files")
                if names then
                    local n = countDelimitedValues(names)
                    if n then found = n end
                end
                local count = parseJsonNumberField(line, "output_count")
                if count and not found then found = math.floor(count) end
                local reason = parseJsonStringField(line, "output_validation_reason")
                if reason then validation = reason end
            end
        end
    end
    if not found then
        local names = detectStemNamesFromFiles(jobDir, UNIVERSAL_STEM_NAMES)
        if #names > 0 then found = #names end
    end
    return found, validation
end

-- ---------------------------------------------------------------------
-- CURRENT worker-run health.
--
-- Acceptance-phase fixtures are OPTIONAL evidence. A successful CURRENT
-- persisted worker run is an independent proof of current runtime health,
-- derived only from the existing per-run/per-job records under
-- <cacheLogDir>/runs -- never from bootstrap.env, historical bootstrap.log
-- text, acceptance-phase counts, temp-folder naming, unmatched worker
-- evidence, or ambiguous run association. A persisted run qualifies as
-- CURRENT worker evidence only when ALL of the following hold:
--
--   identity: the run directory name matches STEMwerk's own generated run
--     naming (STEMwerk_<epoch>_<ms>_<counter>, the shape written via
--     makeUniqueTempSubdir/persistRunDiagnostics), AND EVERY job's own
--     evidence independently carries explicit identity-bearing markers
--     actually emitted by production -- the JSON "job_dir" field in
--     timing/phase events, or the drumsep_helper_output_dir= key in the
--     separation/stdout logs -- naming this run ID as a complete path
--     component. All markers within one job must agree: zero markers leave
--     the job unassociated, markers naming only other runs are mismatched
--     (copied evidence), and markers naming multiple distinct run IDs are
--     conflicting; only an exact per-job identity lets that job contribute
--     to a health proof. An arbitrary substring mention of the run ID in
--     prose is NOT identity.
--   current: evidence classes are kept distinct -- CURRENT means linked
--     to a proven-current session (a current-session evidence root whose
--     own SESSION_STARTED_UTC is itself inside the current context window
--     before bundle creation, with the run started inside that session).
--     Identified runs that are merely RECENT (inside the window but not
--     session-linked) are provenance only (recent_worker_health), and
--     anything older is historical; neither can prove current health.
--     The NEWEST run in a class (full epoch/ms/counter ordering) defines
--     the latest processing context and is the only one evaluated.
--   success contract (run level, never "any successful job"): the run has
--     at least one job and EVERY job individually has an explicit exit
--     code 0, an explicit DONE/success/complete marker, complete output
--     evidence for its semantic flow, the validation its flow actually
--     emits, and no failure classification of its own.
--
-- Flow-specific output/validation contract (from production evidence):
--   Direct Kit (dks_direct) and Kit Split (dks_extract) write
--     found_stems=/expected_stems= with the final DrumSep child stems
--     (kick,snare,toms,hihat,ride,crash) plus output_validation_reason=ok
--     into separation_log.txt. All 6 final child stems AND the explicit
--     ok validation are required; stage-1-only completion never suffices
--     for Kit Split because the final child stems only exist after stage 2.
--   Normal/6-Stem flows emit no validation marker; their production
--     success contract is the stem-output listing (final stem->path JSON /
--     output fields) covering the model's expected stem count plus exit 0
--     and DONE.
--
-- Precedence between current runs is time-ordered by the full generated
-- run identity (epoch, then millisecond component, then counter): the
-- newest explicit current failure wins over older current success, and a
-- newer proven success supersedes an older current failure (historical
-- errors must not defeat a current successful run). Ties resolve to
-- failure. A current run that merely lacks proof (incomplete/missing
-- evidence) is not_proven -- never a false failure, never a false success.
-- ---------------------------------------------------------------------
local CURRENT_WORKER_CONTEXT_WINDOW_SECONDS = 3600
local CURRENT_WORKER_RUN_CLOCK_TOLERANCE_SECONDS = 300

-- Canonical final DrumSep child stems, in the exact spelling production
-- writes to found_stems=/expected_stems= (see EXPECTED_STEMS in
-- stemwerk_drumsep_process.py).
local DRUMSEP_FINAL_CHILD_STEMS = { "kick", "snare", "toms", "hihat", "ride", "crash" }

local function normalizeStemName(name)
    return trim(name):lower():gsub("[%-%_ ]", "")
end

local function splitStemNameSet(value)
    local set = nil
    for token in tostring(value or ""):gmatch("[^,|]+") do
        local name = normalizeStemName(token)
        if name ~= "" then
            set = set or {}
            set[name] = true
        end
    end
    return set
end

local function stemSetCovers(foundSet, requiredSet)
    if not foundSet or not requiredSet then return false end
    for name in pairs(requiredSet) do
        if not foundSet[name] then return false end
    end
    return true
end

-- The run ID must appear as a COMPLETE path component of the marker value,
-- never as an arbitrary substring of surrounding prose.
local function pathHasExactComponent(path, name)
    for component in tostring(path or ""):gmatch("[^/\\]+") do
        if component == name then return true end
    end
    return false
end

-- Parses one job's own persisted files into a fresh probe record (never a
-- shared run-level table), reusing the same per-job parsing the
-- processing summary uses. Also collects the strict identity markers and
-- the flow-specific output/validation evidence for this job only.
local function probeWorkerJobEvidence(jobDir, runName)
    local probe = {
        result = "unknown",
        model = "unknown",
        workflow_source = "unknown",
        workflow_mode = "unknown",
        output_validation_reason = "unknown",
        found_stems = "unknown",
        expected_stems = "unknown",
        log_path = "unknown",
        bundle_root = "",
        _resultPriority = 0,
    }
    local stat = { minTime = nil, maxTime = nil, totalAudioDur = 0, doneOk = 0, exitErr = 0 }
    local timingData = readFile(joinPath(jobDir, "timing_events.jsonl"), "rb")
    local phaseData = readFile(joinPath(jobDir, "phase_events.jsonl"), "rb")
    updateRunFromTimingJson(probe, joinPath(jobDir, "timing_events.jsonl"), stat)
    updateRunFromTimingJson(probe, joinPath(jobDir, "phase_events.jsonl"), stat)
    local sepData = readFile(joinPath(jobDir, "separation_log.txt"), "rb")
    if sepData then parseSupportRunText(probe, sepData) end
    local stdoutData = readFile(joinPath(jobDir, "stdout.txt"), "rb")
    if stdoutData then parseSupportRunText(probe, stdoutData) end
    local doneData = readFile(joinPath(jobDir, "done.txt"), "rb")
    if doneData then parseSupportRunText(probe, doneData) end
    local exitData = readFile(joinPath(jobDir, "exit_code.txt"), "rb")
    if exitData then parseSupportRunText(probe, "exit_code: " .. tostring(trim(exitData))) end

    -- Strict PER-JOB run identity: collect EVERY explicit identity-bearing
    -- marker production actually writes (the JSON "job_dir" field in
    -- timing/phase events, the drumsep_helper_output_dir= key in the
    -- separation/stdout logs) and normalize each to the generated run IDs
    -- it references as complete path components. All markers in this job
    -- must agree on exactly this run's ID; zero markers leave the job
    -- unassociated, markers naming only other runs make it mismatched
    -- (copied evidence), and markers naming more than one distinct run ID
    -- make it conflicting -- "any matching marker wins" is never applied.
    local markerRunIds = {}
    local function collectMarkerRunIds(value)
        for component in tostring(value or ""):gmatch("[^/\\]+") do
            if component:match("^STEMwerk_%d+_%d+_%d+$") then
                markerRunIds[component] = true
            end
        end
    end
    -- Explicit shared session identity (see SHARED_SESSION_ID note below):
    -- no known production writer emits this today, but if a job's own
    -- evidence ever does carry one, it must be read here so a mismatch
    -- against session.env's SESSION_ID can be detected rather than falling
    -- back to timestamp-only correlation.
    local jobSessionId = nil
    for _, data in ipairs({ timingData, phaseData }) do
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                local dir = parseJsonStringField(line, "job_dir")
                if dir then collectMarkerRunIds(dir) end
                if not jobSessionId then
                    jobSessionId = parseJsonStringField(line, "session_id")
                end
            end
        end
    end
    for _, data in ipairs({ sepData, stdoutData }) do
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                local key, value = parseKeyValueLine(line)
                if key == "drumsep_helper_output_dir" then
                    collectMarkerRunIds(value)
                elseif key == "session_id" and not jobSessionId then
                    jobSessionId = value
                end
            end
        end
    end
    -- Explicit structured identity (RunContext/JobContext): worker_context.json
    -- is written directly by the Python worker (and, for Direct Kit, echoed
    -- into drumsep_result.json by the DrumSep helper) from the
    -- STEMWERK_RUN_ID/STEMWERK_JOB_ID the launcher passed it -- an exact
    -- authoritative identity tuple, never inferred from directory names or
    -- timestamps. Older/historical evidence predating this file simply has
    -- none, and falls back to the marker/session heuristics above unchanged.
    local structuredRunId = nil
    local structuredJobId = nil
    local workerContextData = readFile(joinPath(jobDir, "worker_context.json"), "rb")
    if workerContextData then
        structuredRunId = presentValue(parseJsonStringField(workerContextData, "run_id"))
        structuredJobId = presentValue(parseJsonStringField(workerContextData, "job_id"))
    end
    if not structuredRunId then
        local stage2ResultData = readFile(joinPath(jobDir, "stage2_drumsep", "drumsep_result.json"), "rb")
        if stage2ResultData then
            structuredRunId = presentValue(parseJsonStringField(stage2ResultData, "run_id"))
            structuredJobId = structuredJobId or presentValue(parseJsonStringField(stage2ResultData, "job_id"))
        end
    end

    local markerCount = 0
    for _ in pairs(markerRunIds) do markerCount = markerCount + 1 end
    local identityStatus
    if markerCount == 0 then
        identityStatus = "unassociated"
    elseif markerCount > 1 then
        identityStatus = "conflicting"
    elseif markerRunIds[runName] then
        identityStatus = "exact"
    else
        identityStatus = "mismatched"
    end

    -- Flow-specific output evidence: prefer the parsed production fields
    -- (found_stems=/expected_stems= key-values and the jsonl output
    -- fields), then the generic stem-name text fallback for normal flows.
    local foundNames = nil
    local foundCount = nil
    for _, data in ipairs({ phaseData, timingData }) do
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                local names = parseJsonStringField(line, "output_names")
                    or parseJsonStringField(line, "found_stems")
                if names then
                    foundNames = splitStemNameSet(names) or foundNames
                    local n = countDelimitedValues(names)
                    if n then foundCount = n end
                end
                local count = parseJsonNumberField(line, "output_count")
                if count and not foundCount then foundCount = math.floor(count) end
            end
        end
    end
    local loggedFound = presentValue(probe.found_stems)
    if loggedFound then
        if loggedFound:match("^%d+$") then
            -- A bare numeric string here is not a stem name list: it is
            -- updateRunFromTimingJson's own display-only fallback (it
            -- stores output_count into found_stems as text when no real
            -- stem names were ever reported). That is COUNT corroboration
            -- only and must never be read back as named stem evidence --
            -- otherwise a plain output_count=6 would silently satisfy the
            -- canonical named-stem-set requirement below.
            if not foundCount then foundCount = tonumber(loggedFound) end
        else
            foundNames = splitStemNameSet(loggedFound) or foundNames
            local n = countDelimitedValues(loggedFound)
            if n then foundCount = n end
        end
    end
    if not foundCount then
        local names = detectStemNamesFromText(stdoutData, UNIVERSAL_STEM_NAMES)
        if #names == 0 then
            names = detectStemNamesFromText(sepData, UNIVERSAL_STEM_NAMES)
        end
        if #names > 0 then
            foundNames = foundNames or splitStemNameSet(table.concat(names, ","))
            foundCount = #names
        end
    end
    local expectedNames = splitStemNameSet(presentValue(probe.expected_stems) or "")

    local _, jsonlValidation = jobOwnOutputEvidence(jobDir)
    local validation = jsonlValidation or presentValue(probe.output_validation_reason)

    local doneState = doneData and trim(doneData):lower() or ""
    return {
        probe = probe,
        identityStatus = identityStatus,
        exitCode = exitData and tonumber(trim(exitData)) or nil,
        doneOk = doneState:find("done", 1, true) ~= nil
            or doneState:find("success", 1, true) ~= nil
            or doneState:find("complete", 1, true) ~= nil,
        foundNames = foundNames,
        foundCount = foundCount,
        expectedNames = expectedNames,
        sessionId = presentValue(jobSessionId),
        structuredRunId = structuredRunId,
        structuredJobId = structuredJobId,
        validation = validation,
    }
end

-- A Normal/6-Stem job's model can only anchor a worker-health proof when it
-- is one of the released 2.3.1.0 model IDs (KNOWN_SUMMARY_MODELS above,
-- also the exact set the REAPER model picker in STEMwerk.lua exposes).
-- Anything missing/unrecognized has no known output contract to check
-- output names against, so it must never be treated as a health proof.
local function isRecognizedWorkerModel(model)
    local lower = presentValue(model)
    if not lower then return false end
    lower = lower:lower()
    for i = 1, #KNOWN_SUMMARY_MODELS do
        if KNOWN_SUMMARY_MODELS[i] == lower then return true end
    end
    return false
end

-- Classifies one job conservatively: explicit failure outranks the success
-- contract, and anything that is not fully proven is unproven (never a
-- false success, never an invented failure). Returns the verdict plus a
-- truthful machine-readable reason for unproven/failed jobs.
local function classifyWorkerJob(job)
    local probe = job.probe
    local result = tostring(probe.result or "unknown"):lower()
    local validation = presentValue(job.validation)
    if validation and validation:lower() == "not_applicable" then
        -- A job that explicitly records validation as not applicable to its
        -- flow is treated like a job that reports no validation at all.
        validation = nil
    end
    local validationLower = validation and validation:lower() or nil
    local validationFailed = validationLower ~= nil
        and (validationLower:find("fail", 1, true) ~= nil or validationLower:find("error", 1, true) ~= nil)
    local explicitFailure = (job.exitCode ~= nil and job.exitCode ~= 0)
        or tonumber(probe._clearFailures or 0) > 0
        or tonumber(probe._exitNonZero or 0) > 0
        or result == "fail" or result == "partial"
        or validationFailed
    if explicitFailure then
        return "failed", "current_job_explicit_failure"
    end

    -- Per-job identity gate: a job can only contribute to a health proof
    -- for THIS run when its own explicit identity markers unambiguously
    -- name this run. Unassociated/copied/conflicting identity evidence is
    -- unproven, never healthy.
    if job.identityStatus == "unassociated" then
        return "unproven", "job_identity_unassociated"
    end
    if job.identityStatus == "mismatched" then
        return "unproven", "job_identity_mismatch"
    end
    if job.identityStatus == "conflicting" then
        return "unproven", "job_identity_conflicting"
    end

    local workflowSource = trim(presentValue(probe.workflow_source) or ""):lower()
    local workflowMode = trim(presentValue(probe.workflow_mode) or ""):lower()
    local isDrumkitFlow = workflowSource == "dks_direct" or workflowSource == "dks_extract"
        or workflowMode == "drumkit"

    -- Flow-specific output completeness. In both branches below, a bare
    -- output COUNT (with no parsed stem names at all) can never substitute
    -- for named evidence of the canonical stem set -- production always
    -- logs the actual stem names for a genuinely complete run, so the
    -- absence of any names is itself proof of nothing.
    local outputsComplete
    local outputsReason = "missing_required_stems"
    if isDrumkitFlow then
        -- Direct Kit / Kit Split: the FINAL DrumSep child stems must all be
        -- present BY NAME. For Kit Split these only exist after stage 2, so
        -- stage-1 completion alone can never satisfy this. The required set
        -- is the FIXED canonical six; a logged expected_stems is
        -- corroborating provenance only and can never reduce it, and a bare
        -- output_count (even output_count=6) is corroborating provenance
        -- only and can never substitute for the named set.
        local required = splitStemNameSet(table.concat(DRUMSEP_FINAL_CHILD_STEMS, ","))
        if job.foundNames then
            outputsComplete = stemSetCovers(job.foundNames, required)
        else
            outputsComplete = false
            outputsReason = "missing_canonical_stem_names"
        end
    else
        -- Normal / 6-Stem flows: the model must first resolve to a released,
        -- recognized worker-output contract (see isRecognizedWorkerModel);
        -- a missing/unrecognized model has no known contract to check
        -- against, so it can never be inferred healthy regardless of output
        -- count or names. Once the model is recognized, found outputs must
        -- cover that model's canonical stem NAME set (4 for
        -- htdemucs/htdemucs_ft, 6 for htdemucs_6s) -- matching output COUNT
        -- alone is not sufficient, since arbitrary names of the right count
        -- prove nothing about which stems were actually produced.
        if not isRecognizedWorkerModel(probe.model) then
            outputsComplete = false
            outputsReason = "unrecognized_model_contract"
        else
            local required = splitStemNameSet(table.concat(expectedNormalStemNamesForModel(probe.model), ","))
            if job.foundNames then
                outputsComplete = stemSetCovers(job.foundNames, required)
            else
                outputsComplete = false
                outputsReason = "missing_canonical_stem_names"
            end
        end
    end

    -- Flow-aware validation contract: Direct Kit / Kit Split always emit an
    -- authoritative output_validation_reason in production, so it must be
    -- explicitly ok; normal flows emit no validation marker, so absence is
    -- neutral there (their contract is output completeness + exit 0 +
    -- DONE), while a reported non-ok value still blocks proof.
    local validationOk
    if isDrumkitFlow then
        validationOk = validationLower == "ok"
    else
        validationOk = validation == nil or validationLower == "ok"
    end

    if job.exitCode == nil or job.exitCode ~= 0 or not job.doneOk then
        return "unproven", "incomplete_job_completion_evidence"
    end
    if not outputsComplete then
        return "unproven", outputsReason
    end
    if isDrumkitFlow and validation == nil then
        return "unproven", "missing_required_validation"
    end
    if not validationOk then
        return "unproven", "validation_not_ok"
    end
    if result == "cancelled" then
        return "unproven", "job_cancelled"
    end
    return "success", "job_success_contract_met"
end

-- Full generated run identity (epoch, millisecond, counter) for
-- deterministic ordering -- including same-second runs.
local function runIdentityParts(runName)
    local epoch, ms, counter = tostring(runName):match("^STEMwerk_(%d+)_(%d+)_(%d+)$")
    if not epoch then return nil end
    return tonumber(epoch), tonumber(ms), tonumber(counter)
end

-- Returns true when identity a is the same as or NEWER than identity b.
local function runIdentityNotOlder(a, b)
    if a.epoch ~= b.epoch then return a.epoch > b.epoch end
    if a.ms ~= b.ms then return a.ms > b.ms end
    return a.counter >= b.counter
end

-- Reads every current-processing state record STEMwerk itself wrote
-- (SW_LOG.writeCurrentProcessingState, one "<run_id>.json" file per
-- run_id -- see that function's own comment for why it is one file per
-- run_id rather than a single shared pointer: two concurrent STEMwerk
-- script instances each own only their own run_id's file, so there is
-- never a write race to resolve here). Returns a plain array of
-- { run_id, status, run_dir_name, started_utc }; malformed/unreadable
-- files are skipped rather than guessed at.
local function readCurrentProcessingRecords(cacheLogDir)
    local records = {}
    local dir = joinPath(cacheLogDir, "current_processing")
    if not pathExists(dir) then return records end
    for _, fileName in ipairs(enumerateFiles(dir)) do
        if fileName:match("%.json$") then
            local data = readFile(joinPath(dir, fileName), "rb")
            if data then
                local runId = presentValue(parseJsonStringField(data, "run_id"))
                if runId then
                    records[#records + 1] = {
                        run_id = runId,
                        status = presentValue(parseJsonStringField(data, "status")) or "",
                        run_dir_name = presentValue(parseJsonStringField(data, "run_dir_name")) or "",
                        started_utc = presentValue(parseJsonStringField(data, "started_utc")) or "",
                    }
                end
            end
        end
    end
    return records
end

-- Derives worker health from the persisted per-run/per-job records,
-- separating three evidence classes explicitly:
--
--   current_session:  identified runs whose embedded start falls inside a
--     PROVEN-current session (session.env with a valid SESSION_STARTED_UTC
--     that is itself no older than CURRENT_WORKER_CONTEXT_WINDOW_SECONDS
--     before bundle creation, and the run started within that session).
--     Only these may prove current health.
--   recent_unlinked:  identified runs fresh relative to bundle creation
--     but NOT linked to any proven-current session. Recent is not current:
--     these are reported as provenance (recent_worker_health) but can
--     never prove final_runtime_health on their own.
--   historical:       anything older; provenance only.
--
-- Within a class, the NEWEST run by full generated identity (epoch, then
-- millisecond, then counter) defines the latest processing context and is
-- the only one evaluated: a newer unproven context supersedes an older
-- proven success (no fallback to older success), a newer explicit failure
-- overrides an older success, and a newer proven success supersedes an
-- older failure. Ties resolve to failure (fail-safe).
--
-- Returns {
--   status/run/reason            = current verdict,
--   recentStatus/recentRun/recentReason = recent-unlinked provenance,
--   contextIdentity              = current_processing|current_session|recent_unlinked|historical|none,
-- }.
--
-- sessionId (session.env's SESSION_ID) is secondary corroboration on top of
-- the timestamp window, not yet its own independent gate: no production
-- evidence writer in this codebase currently persists a matching identity
-- marker into per-run job evidence (verified against every writer of
-- timing_events.jsonl/phase_events.jsonl/separation_log.txt/stdout.txt), so
-- requiring one unconditionally would make current_session permanently
-- unreachable and silently turn every genuinely-healthy current run into a
-- false not_proven -- a truthfulness regression in the other direction. If
-- a job's OWN evidence ever does carry an explicit session identity marker
-- (see probeWorkerJobEvidence), a value that conflicts with session.env's
-- SESSION_ID is honored: that run can never be treated as session-current
-- no matter how well its timestamp lines up.
--
-- currentProcessingRecords (readCurrentProcessingRecords) is the explicit
-- RunContext identity channel: every job's own worker_context.json (or,
-- for Direct Kit, drumsep_result.json) run_id is compared directly against
-- these records' run_id, never against directory names or timestamps. A
-- run where every job's structured run_id matches one of these records is
-- "current_processing" -- the strongest, identity-only signal, checked
-- FIRST -- regardless of how its timestamp lines up. A run where some job's
-- structured run_id names a DIFFERENT run than any current-processing
-- record (e.g. an old run directory copied/renamed to look newer) is
-- vetoed from ever becoming current via the timestamp/session path either:
-- structured identity, once present, is authoritative over both paths for
-- that run. Evidence with no worker_context.json at all (older/historical
-- runs, or evidence from before this identity channel existed) is
-- unaffected and falls through to the pre-existing session-timestamp path
-- exactly as before.
local function deriveCurrentWorkerRunHealth(runsRoot, nowEpoch, sessionStartedUtc, sessionId, currentProcessingRecords)
    sessionId = presentValue(sessionId)
    currentProcessingRecords = currentProcessingRecords or {}
    local result = {
        status = "not_proven",
        run = "",
        reason = "no_current_run_evidence",
        recentStatus = "none",
        recentRun = "",
        recentReason = "no_recent_run_evidence",
        contextIdentity = "none",
    }
    if not pathExists(runsRoot) then
        result.reason = "runs_root_missing"
        return result
    end
    nowEpoch = tonumber(nowEpoch) or os.time()
    -- The session root is only proof of a CURRENT session when its own
    -- start is itself inside the current window; a stale session root is
    -- cached/historical context and cannot make old runs current.
    local sessionCurrent = false
    if isValidIsoUtcTimestamp(sessionStartedUtc) then
        local windowStartIso = os.date("!%Y-%m-%dT%H:%M:%SZ", nowEpoch - CURRENT_WORKER_CONTEXT_WINDOW_SECONDS)
        local toleranceIso = os.date("!%Y-%m-%dT%H:%M:%SZ", nowEpoch + CURRENT_WORKER_RUN_CLOCK_TOLERANCE_SECONDS)
        sessionCurrent = sessionStartedUtc >= windowStartIso and sessionStartedUtc <= toleranceIso
    end
    local newestCurrent = nil
    local newestRecent = nil
    local sawHistoricalIdentified = false
    -- Tracks how many DISTINCT run directories structurally claim each
    -- current-processing run_id. A single run_id claimed by more than one
    -- directory (a replayed/duplicated worker_context.json, or a run
    -- directory copied wholesale including its identity file) is ambiguous
    -- -- it can never be resolved by picking whichever directory happens to
    -- sort newest, so it must never prove current health.
    local structuredClaimCounts = {}
    for _, runName in ipairs(enumerateSubdirs(runsRoot)) do
        local epoch, ms, counter = runIdentityParts(runName)
        if epoch and epoch <= nowEpoch + CURRENT_WORKER_RUN_CLOCK_TOLERANCE_SECONDS then
            local runDir = joinPath(runsRoot, runName)
            local jobNames = enumerateSubdirs(runDir)
            table.sort(jobNames)
            local jobs = {}
            local identified = false
            for _, jobName in ipairs(jobNames) do
                local job = probeWorkerJobEvidence(joinPath(runDir, jobName), runName)
                jobs[#jobs + 1] = job
                -- The run context is identifiable when at least one job's
                -- own markers name this run (per-job identity for the
                -- health contract itself is enforced per job in
                -- classifyWorkerJob), OR when at least one job carries
                -- explicit structured identity (worker_context.json).
                if job.identityStatus == "exact" or job.identityStatus == "conflicting" or job.structuredRunId then
                    identified = true
                end
            end
            -- Evidence without an explicit identity marker is never
            -- associated with this run at all.
            if identified then
                local runStartIso = os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
                -- An explicit session-identity marker on any job that
                -- conflicts with session.env's SESSION_ID proves this run
                -- does NOT belong to the current session, overriding the
                -- timestamp window outright.
                local sessionIdConflict = false
                if sessionId then
                    for _, job in ipairs(jobs) do
                        if job.sessionId and job.sessionId ~= sessionId then
                            sessionIdConflict = true
                        end
                    end
                end
                -- Structured identity: every job that carries a structured
                -- run_id must match some current-processing record's
                -- run_id for the run as a whole to be structurally
                -- current; a job whose structured run_id names a run NOT
                -- in currentProcessingRecords vetoes current status for
                -- this run entirely (copied/replayed evidence).
                local structuredMatch = false
                local structuredConflict = false
                local structuredClaimId = nil
                if #currentProcessingRecords > 0 then
                    local sawStructured = false
                    local allMatched = true
                    for _, job in ipairs(jobs) do
                        if job.structuredRunId then
                            sawStructured = true
                            structuredClaimId = structuredClaimId or job.structuredRunId
                            local matchesSome = false
                            for _, rec in ipairs(currentProcessingRecords) do
                                if rec.run_id == job.structuredRunId then matchesSome = true end
                            end
                            if not matchesSome then allMatched = false end
                        end
                    end
                    if sawStructured then
                        if allMatched then
                            structuredMatch = true
                            structuredClaimCounts[structuredClaimId] = (structuredClaimCounts[structuredClaimId] or 0) + 1
                        else
                            structuredConflict = true
                        end
                    end
                end
                local isCurrent = structuredMatch
                    or (sessionCurrent and runStartIso >= sessionStartedUtc and not sessionIdConflict and not structuredConflict)
                local isRecent = (not isCurrent)
                    and (nowEpoch - epoch) <= CURRENT_WORKER_CONTEXT_WINDOW_SECONDS
                local identity = {
                    epoch = epoch, ms = ms, counter = counter, name = runName,
                    viaStructured = structuredMatch, structuredClaimId = structuredClaimId,
                }
                local anyFailed = false
                local allSuccess = #jobs > 0
                local unprovenReason = nil
                for _, job in ipairs(jobs) do
                    local verdict, reason = classifyWorkerJob(job)
                    if verdict == "failed" then
                        anyFailed = true
                    elseif verdict ~= "success" then
                        allSuccess = false
                        unprovenReason = unprovenReason or reason
                    end
                end
                local verdict, reason
                if anyFailed then
                    verdict, reason = "failed", "current_run_explicit_failure"
                elseif allSuccess then
                    verdict, reason = "ok", "current_run_success_contract_met"
                else
                    verdict, reason = "unproven", (unprovenReason or "current_run_unproven")
                end
                identity.verdict = verdict
                identity.reason = reason
                if isCurrent then
                    if not newestCurrent or runIdentityNotOlder(identity, newestCurrent) then
                        newestCurrent = identity
                    end
                elseif isRecent then
                    if not newestRecent or runIdentityNotOlder(identity, newestRecent) then
                        newestRecent = identity
                    end
                else
                    sawHistoricalIdentified = true
                end
            end
        end
    end
    -- The newest current (session-linked) context alone decides current
    -- worker health; there is no fallback to an older successful run when
    -- the newest context is unproven.
    if newestCurrent then
        result.run = newestCurrent.name
        result.reason = newestCurrent.reason
        if newestCurrent.verdict == "ok" then
            result.status = "ok"
        elseif newestCurrent.verdict == "failed" then
            result.status = "failed"
        else
            result.status = "not_proven"
        end
        result.contextIdentity = newestCurrent.viaStructured and "current_processing" or "current_session"
        -- The same current-processing run_id claimed by more than one
        -- distinct run directory (replayed/duplicated identity evidence)
        -- can never prove health, no matter which directory happens to
        -- sort newest.
        if newestCurrent.viaStructured
            and newestCurrent.structuredClaimId
            and (structuredClaimCounts[newestCurrent.structuredClaimId] or 0) > 1
        then
            result.status = "not_proven"
            result.reason = "replayed_run_id_conflict"
        end
    elseif newestRecent then
        result.contextIdentity = "recent_unlinked"
        if result.reason == "no_current_run_evidence" and sawHistoricalIdentified then
            result.reason = "identified_run_outside_current_window"
        end
    elseif sawHistoricalIdentified then
        result.contextIdentity = "historical"
        result.reason = "identified_run_outside_current_window"
    end
    -- Recent-unlinked evidence is provenance only: surfaced truthfully
    -- (including its success) but never a current-health proof.
    if newestRecent then
        result.recentRun = newestRecent.name
        result.recentReason = newestRecent.reason
        if newestRecent.verdict == "ok" then
            result.recentStatus = "ok"
        elseif newestRecent.verdict == "failed" then
            result.recentStatus = "failed"
        else
            result.recentStatus = "not_proven"
        end
    end
    return result
end

local function buildProcessingSummary(bundleDir, capabilityState, runtimeState)
    local out = {}
    local runsRoot = joinPath(bundleDir, "runtime_runs")
    local runNames = enumerateSubdirs(runsRoot)
    table.sort(runNames, function(a, b)
        return tostring(a) > tostring(b)
    end)

    local maxRuns = math.min(5, #runNames)
    for i = 1, maxRuns do
        local runName = runNames[i]
        local runDir = joinPath(runsRoot, runName)
        local jobNames = enumerateSubdirs(runDir)
        table.sort(jobNames, function(a, b)
            return tostring(a) < tostring(b)
        end)

        local entry = {
            bundle_root = bundleDir,
            run_name = runName,
            timestamp = runName,
            result = "unknown",
            model = "unknown",
            backend = trim(capabilityState.BACKEND or runtimeState.BACKEND or "") ~= "" and trim(capabilityState.BACKEND or runtimeState.BACKEND or "") or "unknown",
            profile = trim(capabilityState.PROFILE or runtimeState.PROFILE or "") ~= "" and trim(capabilityState.PROFILE or runtimeState.PROFILE or "") or "unknown",
            device = "unknown",
            requested_device = "unknown",
            selected_device = "unknown",
            effective_device = "unknown",
            runtime_selected = "unknown",
            backend_runtime = "unknown",
            workflow_mode = "unknown",
            workflow_source = "unknown",
            output_validation_reason = "unknown",
            expected_stems = "unknown",
            found_stems = "unknown",
            found_files = "unknown",
            exit_code = "unknown",
            mps_experimental = "unknown",
            mps_segment_size = "unknown",
            mps_segment_policy = "unknown",
            mps_fallback_used = "unknown",
            mps_fallback_reason = "unknown",
            mode = "unknown",
            jobs = tostring(#jobNames),
            items = "unknown",
            wall_clock_total = "unknown",
            total_source_duration = "unknown",
            realtime_factor = "unknown",
            error_reason = "unknown",
            log_path = "unknown",
            _clearFailures = 0,
            _positiveHints = 0,
            _resultPriority = 0,
        }
        local stat = {
            minTime = nil,
            maxTime = nil,
            totalAudioDur = 0,
            doneOk = 0,
            exitErr = 0,
        }
        -- Per-job diagnostic state (independent of the shared run-level
        -- `entry` above): each job gets its own freshly-parsed record so
        -- one job's model/backend/device evidence can never bleed into
        -- another job's fields. `entry` above keeps accumulating aggregate
        -- bookkeeping (result/failure classification, wall-clock, output
        -- counts) exactly as before; jobEntries below is used only to
        -- truthfully resolve identity/model/backend/device fields after
        -- the loop.
        local jobEntries = {}

        for _, jobName in ipairs(jobNames) do
            local jobDir = joinPath(runDir, jobName)
            local timingPath = joinPath(jobDir, "timing_events.jsonl")
            local phasePath = joinPath(jobDir, "phase_events.jsonl")
            local sepLog = joinPath(jobDir, "separation_log.txt")
            local stdoutLog = joinPath(jobDir, "stdout.txt")
            local donePath = joinPath(jobDir, "done.txt")
            local exitPath = joinPath(jobDir, "exit_code.txt")

            updateRunFromTimingJson(entry, timingPath, stat)
            updateRunFromTimingJson(entry, phasePath, stat)

            local sepData = readFile(sepLog, "rb")
            if sepData then
                parseSupportRunText(entry, sepData)
                if tostring(entry.log_path or "unknown") == "unknown" then
                    entry.log_path = normalizeRelativeBundlePath(relativePath(bundleDir, sepLog))
                end
            end

            local stdoutData = readFile(stdoutLog, "rb")
            if stdoutData then
                parseSupportRunText(entry, stdoutData)
                if tostring(entry.log_path or "unknown") == "unknown" then
                    entry.log_path = normalizeRelativeBundlePath(relativePath(bundleDir, stdoutLog))
                end
            end

            local doneData = readFile(donePath, "rb")
            if doneData then
                local doneState = trim(doneData):lower()
                if doneState:find("done", 1, true) or doneState:find("success", 1, true) or doneState:find("complete", 1, true) then
                    stat.doneOk = stat.doneOk + 1
                    entry._positiveHints = (entry._positiveHints or 0) + 1
                end
                parseSupportRunText(entry, doneData)
                if tostring(entry.log_path or "unknown") == "unknown" then
                    entry.log_path = normalizeRelativeBundlePath(relativePath(bundleDir, donePath))
                end
            end

            local exitData = readFile(exitPath, "rb")
            if exitData then
                local code = tonumber(trim(exitData))
                if code and code ~= 0 then
                    stat.exitErr = stat.exitErr + 1
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                end
                parseSupportRunText(entry, "exit_code: " .. tostring(trim(exitData)))
            end

            local stemsJsonPath = joinPath(jobDir, "stems.json")
            if pathExists(stemsJsonPath) then
                entry._sawStemsOutput = (entry._sawStemsOutput or 0) + 1
                entry._positiveHints = (entry._positiveHints or 0) + 1
            end

            maybeInferSingleNormalStemOutputs(entry, jobDir, stdoutData, sepData)

            local ownFound, ownValidation = jobOwnOutputEvidence(jobDir)
            if ownFound then
                stat.aggFoundTotal = (stat.aggFoundTotal or 0) + ownFound
                stat.aggFoundJobs = (stat.aggFoundJobs or 0) + 1
            end
            if ownValidation then
                local ok = trim(ownValidation):lower() == "ok"
                stat.aggValidationSeen = (stat.aggValidationSeen or 0) + 1
                if ok then stat.aggValidationOkJobs = (stat.aggValidationOkJobs or 0) + 1 end
            end

            -- This job's own identity/model/backend/device record, parsed
            -- from only this job's own files into a fresh table (never the
            -- shared run-level `entry`), so a second job's evidence can
            -- never overwrite or blend with a different job's fields.
            local jobEntry = {
                run_id = runName,
                job_id = jobName,
                model = "unknown",
                device = "unknown",
                device_name = "unknown",
                backend = "unknown",
                backend_runtime = "unknown",
                runtime_selected = "unknown",
                requested_device = "unknown",
                selected_device = "unknown",
                effective_device = "unknown",
                ui_device_selected_before_run = "unknown",
                backend_device_arg = "unknown",
                drumsep_helper_requested_device = "unknown",
                drumsep_helper_device_arg = "unknown",
                drumsep_helper_device = "unknown",
                drumsep_helper_backend_runtime = "unknown",
                drumsep_model_id = "unknown",
                drumsep_requested_model = "unknown",
                drumsep_helper_model = "unknown",
                workflow_mode = "unknown",
                workflow_source = "unknown",
                mps_experimental = "unknown",
                mps_segment_size = "unknown",
                mps_segment_policy = "unknown",
                mps_fallback_used = "unknown",
                mps_fallback_reason = "unknown",
                stage1_runtime = "unknown",
                stage1_device = "unknown",
                stage2_runtime = "unknown",
                stage2_device = "unknown",
                torch_hip_version = "unknown",
                hip_version = "unknown",
                _resultPriority = 0,
            }
            local jobStatOnly = { minTime = nil, maxTime = nil, totalAudioDur = 0, doneOk = 0, exitErr = 0 }
            updateRunFromTimingJson(jobEntry, timingPath, jobStatOnly)
            updateRunFromTimingJson(jobEntry, phasePath, jobStatOnly)
            if sepData then parseSupportRunText(jobEntry, sepData) end
            if stdoutData then parseSupportRunText(jobEntry, stdoutData) end
            if doneData then parseSupportRunText(jobEntry, doneData) end
            if exitData then parseSupportRunText(jobEntry, "exit_code: " .. tostring(trim(exitData))) end
            jobEntries[#jobEntries + 1] = jobEntry
        end

        -- Truthful run-level aggregation of per-job identity/model/backend/
        -- device evidence: if every job that reported a value agrees, use
        -- that common value; if jobs disagree, report "mixed" rather than
        -- letting a first-wins/last-wins mix of unrelated jobs construct a
        -- combination (e.g. jobA's model with jobB's backend) that no
        -- actual job used. This overwrites whatever the shared-entry
        -- parsing above produced for these specific fields, since the
        -- per-job records are strictly more trustworthy for them.
        local IDENTITY_AGGREGATE_FIELDS = {
            "model", "device", "device_name", "backend", "backend_runtime",
            "runtime_selected", "requested_device", "selected_device", "effective_device",
            "ui_device_selected_before_run", "backend_device_arg",
            "drumsep_helper_requested_device", "drumsep_helper_device_arg",
            "drumsep_helper_device", "drumsep_helper_backend_runtime",
            "drumsep_model_id", "drumsep_requested_model", "drumsep_helper_model",
            "workflow_mode", "workflow_source",
            "mps_experimental", "mps_segment_size", "mps_segment_policy",
            "mps_fallback_used", "mps_fallback_reason",
            "stage1_runtime", "stage1_device", "stage2_runtime", "stage2_device",
            "torch_hip_version", "hip_version",
        }
        local function aggregateJobField(fieldName)
            local seen, order = {}, {}
            for _, je in ipairs(jobEntries) do
                local v = presentValue(je[fieldName])
                if v and not seen[v] then
                    seen[v] = true
                    order[#order + 1] = v
                end
            end
            if #order == 0 then return nil end
            if #order == 1 then return order[1] end
            return "mixed"
        end
        if #jobEntries > 0 then
            for _, fieldName in ipairs(IDENTITY_AGGREGATE_FIELDS) do
                local aggregated = aggregateJobField(fieldName)
                if aggregated then
                    entry[fieldName] = aggregated
                end
            end
        end
        entry._jobEntries = jobEntries

        -- Do not infer outputs only for the jobs==1 case. For parallel runs,
        -- aggregate each job's own output evidence instead of leaving the
        -- run-level outputs/validation as "unknown" (which reads as a
        -- failure) when every job actually produced and validated output.
        local jobCount = #jobNames
        if jobCount > 1 then
            local wfSource = trim(entry.workflow_source or ""):lower()
            local wfMode = trim(entry.workflow_mode or ""):lower()
            local isStemsFlow = wfSource ~= "dks_direct" and wfSource ~= "dks_extract" and wfMode ~= "drumkit"
            local haveAllJobsFound = (stat.aggFoundJobs or 0) == jobCount
            if haveAllJobsFound then
                -- Every job's own evidence was found and summed. This is
                -- strictly more trustworthy than the single-job value that
                -- may already have leaked into entry.found_stems (the
                -- shared per-run kvAssignLast/kvAssignIfUnknown helpers
                -- only ever keep the FIRST job's own numbers), so replace
                -- it rather than deferring to a known-partial figure.
                entry.found_stems = tostring(stat.aggFoundTotal or 0)
                entry.found_files = "unknown"
            elseif (stat.aggFoundJobs or 0) > 0 then
                -- Some, but not all, jobs reported their own output
                -- evidence. Reporting the partial sum as if it were the
                -- final/complete count would misrepresent an incomplete
                -- run as truthfully counted; label the incompleteness
                -- explicitly instead.
                entry.found_stems = string.format(
                    "%d (partial: %d/%d jobs reported)",
                    stat.aggFoundTotal or 0, stat.aggFoundJobs or 0, jobCount
                )
                entry.found_files = "unknown"
            end
            if isStemsFlow and (stat.aggFoundJobs or 0) > 0
                and (haveAllJobsFound or tostring(entry.expected_stems or "unknown") == "unknown") then
                entry.expected_stems = tostring(#expectedNormalStemNamesForModel(entry.model) * jobCount)
            end
            -- Recomputed purely from per-job aggregate evidence: a single
            -- job's own output_validation_reason (which may already have
            -- leaked into entry.output_validation_reason via the shared
            -- per-run kvAssignLast path above) must never be reported as
            -- the WHOLE run's aggregate validation when other jobs in the
            -- same run never confirmed validation themselves.
            if (stat.aggValidationSeen or 0) > 0 and (stat.aggValidationSeen or 0) == jobCount
                and stat.aggValidationOkJobs == stat.aggValidationSeen then
                entry.output_validation_reason = "ok"
            elseif stat.doneOk == jobCount and stat.exitErr == 0 and (stat.aggFoundJobs or 0) == jobCount then
                entry.output_validation_reason = "ok"
            elseif (stat.aggValidationSeen or 0) > 0 or (stat.aggFoundJobs or 0) > 0 then
                entry.output_validation_reason = "partial"
            elseif tostring(entry.output_validation_reason or "unknown") ~= "unknown" then
                -- No job-level aggregate evidence at all backs the value
                -- that leaked in from a single job; do not present it as
                -- the run's aggregate.
                entry.output_validation_reason = "unknown"
            end
        end

        if stat.minTime and stat.maxTime and stat.maxTime >= stat.minTime then
            local wall = math.max(0, stat.maxTime - stat.minTime)
            entry.wall_clock_total = string.format("%.1fs", wall)
            if wall > 0 and (stat.totalAudioDur or 0) > 0 then
                entry.total_source_duration = string.format("%.1fs", stat.totalAudioDur)
                entry.realtime_factor = string.format("%.2fx", (stat.totalAudioDur / wall))
            end
        elseif (stat.totalAudioDur or 0) > 0 then
            entry.total_source_duration = string.format("%.1fs", stat.totalAudioDur)
        end

        deriveRunResultFromJobs(entry, stat)
        finalizeRunClassification(entry)
        out[#out + 1] = entry
    end

    local timingSummaryEntry = parseTimingSummaryEntry(bundleDir, capabilityState, runtimeState)
    local stemwerkByRun = parseRuntimeStemwerkLogByRun(bundleDir, capabilityState, runtimeState)

    -- Association with run_stemwerk.log evidence is exact-run-ID-only. A
    -- reconstructed "session" (launch order within the log, with no run-ID
    -- token of its own) is not a usable identity, so it is never paired by
    -- array position -- not even for exactly one run and one session, since
    -- that positional pairing has no identity to actually verify. If a run
    -- has no key-matched log evidence, its model/device/etc. are left
    -- unavailable rather than guessed.
    for i = 1, #out do
        local entry = out[i]
        local stemLog = stemwerkByRun[tostring(entry.run_name or "")]
        if stemLog then
            if tostring(entry.model or "unknown") == "unknown" and tostring(stemLog.model or "unknown") ~= "unknown" then entry.model = stemLog.model end
            if tostring(entry.device or "unknown") == "unknown" and tostring(stemLog.device or "unknown") ~= "unknown" then entry.device = stemLog.device end
            if tostring(entry.mode or "unknown") == "unknown" and tostring(stemLog.mode or "unknown") ~= "unknown" then entry.mode = stemLog.mode end
            if tostring(entry.jobs or "unknown") == "unknown" and tostring(stemLog.jobs or "unknown") ~= "unknown" then entry.jobs = stemLog.jobs end
            if tostring(entry.items or "unknown") == "unknown" and tostring(stemLog.items or "unknown") ~= "unknown" then entry.items = stemLog.items end
            if tostring(entry.timestamp or "unknown") == "unknown" and tostring(stemLog.timestamp or "unknown") ~= "unknown" then entry.timestamp = stemLog.timestamp end
            if tostring(entry.result or "unknown") == "unknown" and tostring(stemLog.result or "unknown") ~= "unknown" then entry.result = stemLog.result end
            if tostring(entry.error_reason or "unknown") == "unknown" and tostring(stemLog.error_reason or "unknown") ~= "unknown" then entry.error_reason = stemLog.error_reason end
            if tostring(entry.log_path or "unknown") == "unknown" then entry.log_path = stemLog.log_path end
        end
        if tostring(entry.items or "unknown") == "unknown" and tostring(entry.jobs or "unknown") ~= "unknown" then
            entry.items = entry.jobs
        end
    end

    if #out > 0 and timingSummaryEntry then
        local first = out[1]
        local firstFromRuntimeRuns = tostring(first.log_path or ""):find("runtime_runs/", 1, true) ~= nil
        if not firstFromRuntimeRuns then
            if tostring(timingSummaryEntry.result or "unknown") ~= "unknown" then first.result = timingSummaryEntry.result end
            if tostring(timingSummaryEntry.model or "unknown") ~= "unknown" then first.model = timingSummaryEntry.model end
            if tostring(timingSummaryEntry.device or "unknown") ~= "unknown" then first.device = timingSummaryEntry.device end
            if tostring(timingSummaryEntry.mode or "unknown") ~= "unknown" then first.mode = timingSummaryEntry.mode end
            if tostring(timingSummaryEntry.jobs or "unknown") ~= "unknown" then first.jobs = timingSummaryEntry.jobs end
            if tostring(timingSummaryEntry.items or "unknown") ~= "unknown" then first.items = timingSummaryEntry.items end
            if tostring(timingSummaryEntry.wall_clock_total or "unknown") ~= "unknown" then first.wall_clock_total = timingSummaryEntry.wall_clock_total end
            if tostring(timingSummaryEntry.total_source_duration or "unknown") ~= "unknown" then first.total_source_duration = timingSummaryEntry.total_source_duration end
            if tostring(timingSummaryEntry.realtime_factor or "unknown") ~= "unknown" then first.realtime_factor = timingSummaryEntry.realtime_factor end
            if tostring(timingSummaryEntry.timestamp or "unknown") ~= "unknown" then first.timestamp = timingSummaryEntry.timestamp end
            if tostring(first.log_path or "unknown") == "unknown" or tostring(first.log_path or ""):find("runtime_runs/", 1, true) then
                first.log_path = timingSummaryEntry.log_path
            end
        end
    end

    if #out == 0 and timingSummaryEntry then
        deriveRunResultFromJobs(timingSummaryEntry, { doneOk = 0, exitErr = timingSummaryEntry._exitNonZero or 0 })
        out[#out + 1] = timingSummaryEntry
    end
    if #out == 0 then
        local stemwerkLogEntry = parseRunStemwerkLogSummary(bundleDir, capabilityState, runtimeState)
        if stemwerkLogEntry then
            deriveRunResultFromJobs(stemwerkLogEntry, { doneOk = 0, exitErr = stemwerkLogEntry._exitNonZero or 0 })
            out[#out + 1] = stemwerkLogEntry
        end
    end

    for i = 1, #out do
        local entry = out[i]
        if tostring(entry.workflow_mode or "unknown") == "unknown" and trim(tostring(entry.runtime_selected or "")):lower() == "cpu" then
            local foundCount = countDelimitedValues(entry.found_stems) or countDelimitedValues(entry.found_files)
            if foundCount == 6 then
                entry.workflow_mode = "drumkit"
            end
        end
        -- The active/effective backend actually used by the worker (once
        -- known) must win over a merely requested/probed device: use the
        -- same effective-device precedence as the "Latest run summary"
        -- block (effective_device/backend_runtime/runtime_selected before
        -- raw device evidence, and raw device before requested-only
        -- evidence) rather than the raw requested/probed `entry.device`
        -- value alone, so e.g. an MPS request that actually fell back to
        -- CPU execution is never shown as the active device.
        entry.friendly_device = summaryDeviceLabel(entry, runtimeState)
    end

    local lines = {}
    if #out == 0 then
        lines[#lines + 1] = "No recent processing summary available. See runtime_logs/run_stemwerk.log and runtime_runs/."
        return lines
    end

    lines[#lines + 1] = "Recent processing summary (newest first)"
    lines[#lines + 1] = ""
    appendLatestRunSummary(lines, out[1], runtimeState)
    for idx, entry in ipairs(out) do
        lines[#lines + 1] = string.format("Run %d", idx)
        lines[#lines + 1] = "summary: " .. statusSummaryLabel(entry)
            .. " | " .. workflowSummaryLabel(entry)
            .. " | " .. tostring(entry.friendly_device or "unknown")
            .. " | outputs " .. outputCountSummaryLabel(entry)
            .. " | validation " .. tostring(entry.output_validation_reason or "unknown")
        lines[#lines + 1] = "run: " .. tostring(entry.run_name or "unknown")
        lines[#lines + 1] = "timestamp: " .. tostring(entry.timestamp or "unknown")
        lines[#lines + 1] = "result: " .. tostring(entry.result or "unknown")
        local wfSourceForModel = trim(entry.workflow_source or ""):lower()
        -- Direct Kit only ever runs DrumSep: the generic user-visible
        -- "model:" line must represent that DrumSep semantic model, never
        -- an unrelated Demucs string that happened to appear in this run's
        -- raw logs (e.g. a cached-model-path decoy). The raw Demucs value,
        -- if any, is kept only as clearly-labeled historical/raw
        -- provenance, never as the reported Direct Kit model.
        if wfSourceForModel == "dks_direct" then
            local drumsepModel = drumsepSemanticModel(entry)
            local rawModel = tostring(entry.model or "unknown")
            if drumsepModel ~= "unknown" then
                lines[#lines + 1] = "model: " .. drumsepModel
                if rawModel ~= "unknown" and rawModel ~= drumsepModel then
                    lines[#lines + 1] = "raw_demucs_model_field (historical, not used for Direct Kit): " .. rawModel
                end
            else
                lines[#lines + 1] = "model: " .. rawModel
            end
        else
            lines[#lines + 1] = "model: " .. tostring(entry.model or "unknown")
        end
        lines[#lines + 1] = "semantic_model: " .. semanticModelLabel(entry)
        if wfSourceForModel == "dks_direct" then
            lines[#lines + 1] = "drumsep_model_id: " .. drumsepSemanticModel(entry)
        elseif wfSourceForModel == "dks_extract" then
            lines[#lines + 1] = "stage1_model: " .. tostring((trim(entry.model or "") ~= "" and entry.model) or "unknown")
            lines[#lines + 1] = "stage1_runtime: " .. tostring(entry.stage1_runtime or "unknown")
            lines[#lines + 1] = "stage1_device: " .. friendlyDeviceLabel(entry.stage1_device, runtimeState, entry)
            lines[#lines + 1] = "stage2_model: " .. drumsepSemanticModel(entry)
            lines[#lines + 1] = "stage2_runtime: " .. tostring(entry.stage2_runtime or "unknown")
            lines[#lines + 1] = "stage2_device: " .. friendlyDeviceLabel(entry.stage2_device, runtimeState, entry)
        end
        lines[#lines + 1] = "backend: " .. tostring(entry.backend or "unknown")
        lines[#lines + 1] = "profile: " .. tostring(entry.profile or "unknown")
        lines[#lines + 1] = "device: " .. tostring(entry.device or "unknown")
        lines[#lines + 1] = "friendly_device: " .. tostring(entry.friendly_device or "unknown")
        lines[#lines + 1] = "requested_device: " .. tostring(entry.requested_device or "unknown")
        lines[#lines + 1] = "selected_device: " .. tostring(entry.selected_device or "unknown")
        lines[#lines + 1] = "effective_device: " .. tostring(entry.effective_device or "unknown")
        lines[#lines + 1] = "runtime_selected: " .. tostring(entry.runtime_selected or "unknown")
        lines[#lines + 1] = "backend_runtime: " .. tostring(entry.backend_runtime or "unknown")
        lines[#lines + 1] = "workflow_mode: " .. tostring(entry.workflow_mode or "unknown")
        lines[#lines + 1] = "workflow_source: " .. tostring(entry.workflow_source or "unknown")
        lines[#lines + 1] = "mps_experimental: " .. tostring(entry.mps_experimental or "unknown")
        lines[#lines + 1] = "mps_segment_size: " .. tostring(entry.mps_segment_size or "unknown")
        lines[#lines + 1] = "mps_segment_policy: " .. tostring(entry.mps_segment_policy or "unknown")
        lines[#lines + 1] = "mps_fallback_used: " .. tostring(entry.mps_fallback_used or "unknown")
        lines[#lines + 1] = "mps_fallback_reason: " .. tostring(entry.mps_fallback_reason or "unknown")
        lines[#lines + 1] = "mode: " .. tostring(entry.mode or "unknown")
        lines[#lines + 1] = "jobs: " .. tostring(entry.jobs or "unknown")
        lines[#lines + 1] = "items: " .. tostring(entry.items or "unknown")
        lines[#lines + 1] = "wall_clock_total: " .. tostring(entry.wall_clock_total or "unknown")
        lines[#lines + 1] = "total_source_duration: " .. tostring(entry.total_source_duration or "unknown")
        lines[#lines + 1] = "realtime_factor: " .. tostring(entry.realtime_factor or "unknown")
        lines[#lines + 1] = "expected_stems: " .. tostring(entry.expected_stems or "unknown")
        lines[#lines + 1] = "found_stems: " .. tostring(entry.found_stems or "unknown")
        lines[#lines + 1] = "found_files: " .. tostring(entry.found_files or "unknown")
        lines[#lines + 1] = "output_validation_reason: " .. tostring(entry.output_validation_reason or "unknown")
        lines[#lines + 1] = "exit_code: " .. tostring(entry.exit_code or "unknown")
        if tostring(entry.result or "unknown") == "fail" or tostring(entry.result or "unknown") == "partial" then
            lines[#lines + 1] = "failure_reason: " .. tostring(entry.error_reason or "unknown")
            lines[#lines + 1] = "error_class: " .. tostring(entry.error_class or "unknown")
            lines[#lines + 1] = "error_hint: " .. tostring(entry.error_hint or "unknown")
            if tostring(entry.model_cache_hint or "") ~= "" and tostring(entry.model_cache_hint or "unknown") ~= "unknown" then
                lines[#lines + 1] = "model_cache_hint: " .. tostring(entry.model_cache_hint)
            end
            if tostring(entry.model_url or "") ~= "" and tostring(entry.model_url or "unknown") ~= "unknown" then
                lines[#lines + 1] = "model_url: " .. tostring(entry.model_url)
            end
            if tostring(entry.model_path or "") ~= "" and tostring(entry.model_path or "unknown") ~= "unknown" then
                lines[#lines + 1] = "model_path: " .. tostring(entry.model_path)
            end
        end
        lines[#lines + 1] = "bundle_log_path: " .. tostring(entry.log_path or "unknown")
        lines[#lines + 1] = ""
    end
    return lines
end

-- A folder name matching STEMwerk's own "STEMwerk_<token>" naming
-- convention is NOT, by itself, proof that STEMwerk actually generated
-- that folder for a real run -- a human-made review/build folder can use
-- the exact same naming shape. Real STEMwerk run evidence always logs its
-- own file paths (e.g. "input=<path>/STEMwerk_<token>/input.wav") into its
-- known marker files, so a folder's own name appearing inside its own
-- marker-file content is a cheap, self-consistency signal that the content
-- actually originated from a run using this folder -- not merely a
-- same-shaped name with unrelated or fabricated content dropped in.
local function tempFolderContentReferencesItself(fullPath, name)
    local markerFiles = { "stdout.txt", "stderr.txt", "separation_log.txt" }
    for _, fileName in ipairs(markerFiles) do
        local data = readFile(joinPath(fullPath, fileName), "rb")
        if data and tostring(data):find(tostring(name), 1, true) then
            return true
        end
    end
    return false
end

local function collectTempInventory(bundleDir, copiedFiles)
    local tempBase = getTempBase()
    local inventoryLines = {}
    local copied = {}
    local folders = {}
    local summary = {
        stdout = false,
        stderr = false,
        separation = false,
    }

    if not pathExists(tempBase) then
        appendLine(inventoryLines, "Temp base missing: " .. tempBase)
        return inventoryLines, copied, tempBase, summary
    end

    local caps = {
        maxFolders = (OS == "Windows") and 5 or 8,
        maxDepth = (OS == "Windows") and 2 or 3,
        maxFilesTotal = (OS == "Windows") and 50 or 400,
        maxDirsTotal = (OS == "Windows") and 120 or 400,
        maxCopySourceBytes = 512 * 1024,
        maxCopyOutputBytes = 256 * 1024,
        maxCopiedBytesTotal = (OS == "Windows") and (2 * 1024 * 1024) or (4 * 1024 * 1024),
    }

    for _, name in ipairs(enumerateSubdirs(tempBase)) do
        local lower = tostring(name):lower()
        local skipDir = shouldSkipSupportDirByName(name)
        if startsWith(lower, "stemwerk") and not shouldIgnoreTempFolder(name) and not skipDir then
            local full = joinPath(tempBase, name)
            local epoch = 0
            -- Only stat the (typically small) set of stemwerk*-prefixed
            -- temp folders, not everything under the OS temp dir, so this
            -- stays cheap while still giving a real recency signal.
            if OS ~= "Windows" then
                local stat = getPathStat(full)
                epoch = tonumber(stat.epoch) or 0
            end
            -- Explicit identity: matching STEMwerk's own generated
            -- run/job-folder naming convention ("STEMwerk_<token>", the
            -- same pattern used to key run-ID association elsewhere in
            -- this file) is necessary but NOT sufficient -- a human-named
            -- folder (dev/review/build) can use that exact same shape. The
            -- folder must also carry actual run identity: its own marker
            -- files must reference this folder itself (see
            -- tempFolderContentReferencesItself above). A loose
            -- case-insensitive "starts with stemwerk" match, an mtime-only
            -- newest-folder heuristic, or the name pattern alone are never
            -- proof of currentness on their own; a newer folder lacking
            -- real run identity must never be able to pass itself off as
            -- current run evidence.
            local nameMatchesRunPattern = tostring(name):match("^STEMwerk_[%w_%-]+$") ~= nil
            folders[#folders + 1] = {
                name = name,
                path = full,
                epoch = epoch,
                mtime = "metadata skipped for speed",
                hasRunIdentity = nameMatchesRunPattern and tempFolderContentReferencesItself(full, name),
            }
        end
    end

    table.sort(folders, function(a, b)
        if (a.epoch or 0) ~= (b.epoch or 0) then
            return (a.epoch or 0) > (b.epoch or 0)
        end
        return tostring(a.name) > tostring(b.name)
    end)
    -- Only the single newest folder that actually carries STEMwerk's own
    -- run/job identity naming (not merely a "stemwerk"-prefixed name) may
    -- count as "current" evidence. Any other name-matching folder is still
    -- inventoried below (as historical/contextual listing), but it must
    -- never be able to make the "Recent stdout.txt" / "Recent stderr.txt" /
    -- "Recent separation_log.txt" diagnostics fields look current -- old
    -- residue with the same well-known filenames (or an unrelated
    -- similarly-named folder that merely happens to be newer) is a proven
    -- contamination source otherwise.
    local newestFolderPath = nil
    for _, folder in ipairs(folders) do
        if folder.hasRunIdentity then
            newestFolderPath = folder.path
            break
        end
    end

    local function sanitizeInventoryDisplayPath(relPath, fileClass)
        local rel = tostring(relPath or ""):gsub("\\", "/")
        local lower = rel:lower()
        local artifactKind = classifyMediaArtifact(lower)
        if fileClass == "excluded_binary" or artifactKind == "media" then
            return "[STEMWERK_TEMP_DIR]/[TEMP_AUDIO_FILE]"
        end
        if artifactKind == "ffmpeg_log" then
            return "[STEMWERK_TEMP_DIR]/[TEMP_AUDIO_FILE].ffmpeg.log"
        end
        if artifactKind == "reapeaks" then
            return "[STEMWERK_TEMP_DIR]/peaks/[TEMP_AUDIO_FILE].reapeaks"
        end
        return "[STEMWERK_TEMP_DIR]/" .. rel
    end

    local function logInventoryEntry(stat, action, relPath, class, reason)
        appendLine(
            inventoryLines,
            string.format(
                "%s | %s | %s | %s | %s%s",
                stat.mtime or "unavailable",
                stat.sizeLabel or "unavailable",
                stat.kind or "file",
                action,
                sanitizeInventoryDisplayPath(relPath, class),
                (trim(reason) ~= "") and (" | " .. tostring(reason)) or ""
            )
        )
    end

    local totals = {
        scannedFiles = 0,
        scannedDirs = 0,
        copiedBytes = 0,
        hitDepthLimit = false,
        hitFileLimit = false,
        hitDirLimit = false,
    }

    local function walkDir(rootDir, relDir, depth)
        if depth > caps.maxDepth then
            if not totals.hitDepthLimit then
                totals.hitDepthLimit = true
                appendLine(inventoryLines, string.format("limit: max depth reached at %s", sanitizeInventoryDisplayPath(relDir, "other")))
            end
            return
        end
        local currentDir = relDir == "" and rootDir or joinPath(rootDir, relDir)
        if totals.scannedDirs >= caps.maxDirsTotal then
            if not totals.hitDirLimit then
                totals.hitDirLimit = true
                appendLine(inventoryLines, string.format("limit: max dirs reached (%d)", caps.maxDirsTotal))
            end
            return
        end
        totals.scannedDirs = totals.scannedDirs + 1
        for _, fileName in ipairs(enumerateFiles(currentDir)) do
            if totals.scannedFiles >= caps.maxFilesTotal then
                if not totals.hitFileLimit then
                    totals.hitFileLimit = true
                    appendLine(inventoryLines, string.format("limit: max files reached (%d)", caps.maxFilesTotal))
                end
                break
            end
            totals.scannedFiles = totals.scannedFiles + 1
            local relPath = relDir == "" and fileName or joinPath(relDir, fileName)
            local fullPath = joinPath(rootDir, relPath)
            local lowerName = tostring(fileName):lower()
            if rootDir == newestFolderPath then
                if lowerName == "stdout.txt" then summary.stdout = true end
                if lowerName == "stderr.txt" then summary.stderr = true end
                if lowerName == "separation_log.txt" then summary.separation = true end
            end

            local skipByExt, ext = shouldSkipSupportFileByExt(fileName)
            if skipByExt then
                logInventoryEntry(
                    {mtime = "unavailable (skipped)", sizeLabel = "unavailable (skipped)", kind = "file"},
                    "excluded-extension",
                    relPath,
                    "excluded_binary",
                    "excluded-ext=" .. tostring(ext)
                )
            else
                local class = classifyFileForBundle(fileName)
                local action = "listed"
                local reason = ""
                local stat = {
                    ok = true,
                    kind = "file",
                    mtime = "unavailable (fast-mode)",
                    size = nil,
                    sizeLabel = "unavailable (fast-mode)",
                    reason = "",
                }
                if class == "excluded_binary" then
                    action = "excluded-binary"
                    stat.mtime = "unavailable (excluded)"
                    stat.sizeLabel = "unavailable (excluded)"
                else
                    if class == "text" then
                        local sourceSize = fileSizeBytes(fullPath)
                        stat.size = sourceSize
                        stat.sizeLabel = sourceSize and humanBytes(sourceSize) or "unavailable (size probe failed)"
                        if sourceSize and sourceSize > caps.maxCopySourceBytes then
                            action = "excluded-too-large"
                            reason = "source-bytes=" .. tostring(sourceSize) .. " > max=" .. tostring(caps.maxCopySourceBytes)
                        else
                            local copyBytes = math.min(tonumber(sourceSize) or caps.maxCopyOutputBytes, caps.maxCopyOutputBytes)
                            if (totals.copiedBytes + copyBytes) > caps.maxCopiedBytesTotal then
                                action = "excluded-copy-cap"
                                reason = "copy-byte-cap=" .. tostring(caps.maxCopiedBytesTotal)
                            else
                                local tempDestDir = joinPath(bundleDir, "temp_logs", basename(rootDir))
                                local tempDestPath = joinPath(tempDestDir, relPath)
                                ensureDir(tempDestPath:match("^(.*)[/\\][^/\\]+$") or tempDestDir)
                                local ok, mode = copySupportTextFile(fullPath, tempDestPath, caps.maxCopyOutputBytes)
                                if ok then
                                    action = "included-" .. tostring(mode)
                                    totals.copiedBytes = totals.copiedBytes + copyBytes
                                    copied[#copied + 1] = "temp_logs/" .. sanitizeInventoryDisplayPath(relPath, class)
                                else
                                    action = "text-copy-failed"
                                end
                            end
                        end
                    end
                end
                logInventoryEntry(
                    stat,
                    action,
                    relPath,
                    class,
                    (not stat.ok and trim(stat.reason) ~= "") and ("metadata=" .. tostring(stat.reason)) or reason
                )
            end
        end
        for _, subDirName in ipairs(enumerateSubdirs(currentDir)) do
            if totals.scannedDirs >= caps.maxDirsTotal then
                break
            end
            local skipDir, skipReason = shouldSkipSupportDirByName(subDirName)
            if skipDir then
                local relPath = relDir == "" and subDirName or joinPath(relDir, subDirName)
                appendLine(inventoryLines, string.format("skip-dir | %s | reason=%s", sanitizeInventoryDisplayPath(relPath, "other"), tostring(skipReason)))
            else
                local nextRel = relDir == "" and subDirName or joinPath(relDir, subDirName)
                walkDir(rootDir, nextRel, depth + 1)
            end
        end
    end

    local maxFolders = math.min(#folders, caps.maxFolders)
    if #folders > maxFolders then
        appendLine(inventoryLines, string.format("Temp folders limited: scanning %d of %d newest STEMwerk folders", maxFolders, #folders))
    end
    if maxFolders == 0 then
        appendLine(inventoryLines, "No STEMwerk temp folders found under: " .. tempBase)
    end

    for i = 1, maxFolders do
        local folder = folders[i]
        appendLine(inventoryLines, "")
        appendLine(
            inventoryLines,
            string.format("[Folder] %s | [STEMWERK_TEMP_DIR] (%s)", folder.mtime, basename(folder.path))
        )
        walkDir(folder.path, "", 0)
        if totals.scannedFiles >= caps.maxFilesTotal then
            break
        end
    end

    appendLine(
        inventoryLines,
        string.format(
            "summary | files=%d/%d dirs=%d/%d copied_bytes=%d/%d",
            totals.scannedFiles,
            caps.maxFilesTotal,
            totals.scannedDirs,
            caps.maxDirsTotal,
            totals.copiedBytes,
            caps.maxCopiedBytesTotal
        )
    )

    for i = 1, #copied do
        copiedFiles[#copiedFiles + 1] = copied[i]
    end

    return inventoryLines, copied, tempBase, summary, {
        copiedCount = #copied,
        copiedBytes = totals.copiedBytes or 0,
        scannedFiles = totals.scannedFiles or 0,
        scannedDirs = totals.scannedDirs or 0,
    }
end

local function performBundleCollection()
    local resourcePath = getResourcePath()
    local _, bundleSuffix = timestampParts(os.time())
    local bundleName = "STEMwerk-support-bundle-" .. bundleSuffix
    local bundleParent = joinPath(resourcePath, "STEMwerk-support-bundles")
    local bundleDir = joinPath(bundleParent, bundleName)

    if not ensureDir(bundleParent) or not ensureDir(bundleDir) then
        return false, "Could not create bundle folder:\n" .. tostring(bundleDir)
    end

    local phaseTimings = {}
    local phaseTimingsWall = {}
    local timingsFile = joinPath(bundleDir, "support_bundle_timings.txt")
    local timingLines = {}
    local totalStartedAt = os.clock()
    local totalWallStartedAt = os.time()

    local function flushTimings()
        writeFile(timingsFile, table.concat(timingLines, "\n") .. "\n", "wb")
    end

    local function timingEvent(phase, state, note)
        timingLines[#timingLines + 1] = string.format(
            "%s | %s | %s%s",
            os.date("%Y-%m-%d %H:%M:%S"),
            tostring(phase),
            tostring(state),
            trim(note) ~= "" and (" | " .. tostring(note)) or ""
        )
        flushTimings()
    end

    local function finalizeTimingsAfterZip()
        local hasCreateZipEnd = false
        local hasTotalEnd = false
        for i = 1, #timingLines do
            local line = tostring(timingLines[i] or "")
            if line:find("| create_zip | end", 1, true) then
                hasCreateZipEnd = true
            end
            if line:find("| total | end", 1, true) then
                hasTotalEnd = true
            end
        end
        if not hasCreateZipEnd then
            timingLines[#timingLines + 1] = string.format(
                "%s | create_zip | end | cpu_duration=%.3f wall_duration=%d",
                os.date("%Y-%m-%d %H:%M:%S"),
                tonumber(phaseTimings.create_zip) or 0,
                tonumber(phaseTimingsWall.create_zip) or 0
            )
        end
        if not hasTotalEnd then
            timingLines[#timingLines + 1] = string.format(
                "%s | total | end | cpu_duration=%.3f wall_duration=%d",
                os.date("%Y-%m-%d %H:%M:%S"),
                tonumber(phaseTimings.total) or 0,
                tonumber(phaseTimingsWall.total) or 0
            )
        end
        flushTimings()
    end

    local function phaseStart(name)
        timingEvent(
            name,
            "start",
            string.format(
                "cpu_elapsed=%.3f wall_elapsed=%d",
                math.max(0, os.clock() - totalStartedAt),
                math.max(0, os.time() - totalWallStartedAt)
            )
        )
        return { cpu = os.clock(), wall = os.time() }
    end

    local function phaseDone(name, startedAt)
        local cpuStarted = type(startedAt) == "table" and tonumber(startedAt.cpu) or tonumber(startedAt or 0)
        local wallStarted = type(startedAt) == "table" and tonumber(startedAt.wall) or os.time()
        local elapsed = math.max(0, os.clock() - tonumber(cpuStarted or 0))
        local wallElapsed = math.max(0, os.time() - tonumber(wallStarted or os.time()))
        phaseTimings[name] = elapsed
        phaseTimingsWall[name] = wallElapsed
        timingEvent(name, "end", string.format("cpu_duration=%.3f wall_duration=%d", elapsed, wallElapsed))
        return elapsed
    end

    timingEvent("total_start", "start", "bundle=" .. bundleName)

    local rootStartedAt = phaseStart("collect_root_diagnostics")
    local reapackVersion = detectReaPackVersion(resourcePath)
    local platform = getPlatformDetails()
    local reaperVersion = reaper and reaper.GetAppVersion and tostring(reaper.GetAppVersion() or "") or "undetected"
    local bundleTimestamp = os.date("%Y-%m-%d %H:%M:%S")
    phaseDone("collect_root_diagnostics", rootStartedAt)

    local probesStartedAt = phaseStart("collect_probes")
    local pythonProbe = runPythonProbe(bundleDir, detectedPythonPath)
    local pythonVersion = pythonProbe.data.python_version or getPythonVersion(detectedPythonPath)
    local ffmpegVersion = getFfmpegVersion(detectedFfmpegPath)
    phaseDone("collect_probes", probesStartedAt)
    local probeTorchVersion = trim(pythonProbe.data.torch or "")
    local probeTorchaudioVersion = trim(pythonProbe.data.torchaudio or "")
    local probeTorchSupported = "unknown"
    local probeTorchaudioPresent = "unknown"
    local probeRuntimeDriftDetected = "unknown"
    local probeRuntimeDriftReason = "unknown"
    do
        local coreTorch = probeTorchVersion:match("([0-9]+%.[0-9]+%.[0-9]+)") or probeTorchVersion:match("([0-9]+%.[0-9]+)")
        local major, minor = coreTorch and coreTorch:match("^(%d+)%.(%d+)")
        if major and minor then
            local torchTooNew = (tonumber(major) or 999) > 2 or ((tonumber(major) or 999) == 2 and (tonumber(minor) or 999) >= 6)
            probeTorchSupported = torchTooNew and "no" or "yes"
            probeTorchaudioPresent = (probeTorchaudioVersion ~= "" and not probeTorchaudioVersion:find("missing", 1, true) and not probeTorchaudioVersion:find("import_error", 1, true)) and "yes" or "no"
            if torchTooNew then
                probeRuntimeDriftDetected = "yes"
                probeRuntimeDriftReason = "torch_too_new_for_demucs"
            elseif probeTorchaudioPresent ~= "yes" then
                probeRuntimeDriftDetected = "yes"
                probeRuntimeDriftReason = "torchaudio_missing_for_demucs"
            else
                probeRuntimeDriftDetected = "no"
                probeRuntimeDriftReason = ""
            end
        end
    end

    local diagnostics = {}
    appendLine(diagnostics, "=== COPY/PASTE VERSION AND PLATFORM SUMMARY ===")
    appendKey(diagnostics, "STEMwerk package version", packageVersion ~= "" and packageVersion or "missing")
    appendKey(diagnostics, "ReaPack version", reapackVersion)
    appendKey(diagnostics, "Main script @version", mainHeaderVersion ~= "" and mainHeaderVersion or "missing")
    appendKey(diagnostics, "Main script APP_VERSION", mainAppVersion ~= "" and mainAppVersion or "missing")
    appendKey(diagnostics, "OS", platform.osName)
    appendKey(diagnostics, "OS version", platform.osVersion)
    appendKey(diagnostics, "Architecture", platform.architecture)
    appendKey(diagnostics, "REAPER version", reaperVersion ~= "" and reaperVersion or "undetected")
    appendKey(diagnostics, "REAPER resource path", resourcePath)
    appendKey(diagnostics, "Runtime base path", runtimeBase)
    appendKey(diagnostics, "Python path", sanitizePathValue(detectedPythonPath))
    appendKey(diagnostics, "Python version", pythonVersion)
    appendKey(diagnostics, "supported_python_found", trim(capabilityState.SUPPORTED_PYTHON_FOUND) ~= "" and trim(capabilityState.SUPPORTED_PYTHON_FOUND) or trim(runtimeState.SUPPORTED_PYTHON_FOUND) ~= "" and trim(runtimeState.SUPPORTED_PYTHON_FOUND) or "unknown")
    appendKey(diagnostics, "detected_python_version", trim(capabilityState.DETECTED_PYTHON_VERSION) ~= "" and trim(capabilityState.DETECTED_PYTHON_VERSION) or trim(runtimeState.DETECTED_PYTHON_VERSION) ~= "" and trim(runtimeState.DETECTED_PYTHON_VERSION) or pythonVersion)
    appendKey(diagnostics, "supported_python_range", trim(capabilityState.SUPPORTED_PYTHON_RANGE) ~= "" and trim(capabilityState.SUPPORTED_PYTHON_RANGE) or trim(runtimeState.SUPPORTED_PYTHON_RANGE) ~= "" and trim(runtimeState.SUPPORTED_PYTHON_RANGE) or (OS ~= "Windows" and "3.10-3.12" or "3.11-3.12"))
    appendKey(diagnostics, "MANAGED_PYTHON_ENABLED", trim(capabilityState.MANAGED_PYTHON_ENABLED) ~= "" and trim(capabilityState.MANAGED_PYTHON_ENABLED) or trim(runtimeState.MANAGED_PYTHON_ENABLED) ~= "" and trim(runtimeState.MANAGED_PYTHON_ENABLED) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_STATUS", trim(capabilityState.MANAGED_PYTHON_STATUS) ~= "" and trim(capabilityState.MANAGED_PYTHON_STATUS) or trim(runtimeState.MANAGED_PYTHON_STATUS) ~= "" and trim(runtimeState.MANAGED_PYTHON_STATUS) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_VERSION", trim(capabilityState.MANAGED_PYTHON_VERSION) ~= "" and trim(capabilityState.MANAGED_PYTHON_VERSION) or trim(runtimeState.MANAGED_PYTHON_VERSION) ~= "" and trim(runtimeState.MANAGED_PYTHON_VERSION) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_RELEASE", trim(capabilityState.MANAGED_PYTHON_RELEASE) ~= "" and trim(capabilityState.MANAGED_PYTHON_RELEASE) or trim(runtimeState.MANAGED_PYTHON_RELEASE) ~= "" and trim(runtimeState.MANAGED_PYTHON_RELEASE) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_PLATFORM", trim(capabilityState.MANAGED_PYTHON_PLATFORM) ~= "" and trim(capabilityState.MANAGED_PYTHON_PLATFORM) or trim(runtimeState.MANAGED_PYTHON_PLATFORM) ~= "" and trim(runtimeState.MANAGED_PYTHON_PLATFORM) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_ARCH", trim(capabilityState.MANAGED_PYTHON_ARCH) ~= "" and trim(capabilityState.MANAGED_PYTHON_ARCH) or trim(runtimeState.MANAGED_PYTHON_ARCH) ~= "" and trim(runtimeState.MANAGED_PYTHON_ARCH) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_URL", trim(capabilityState.MANAGED_PYTHON_URL) ~= "" and trim(capabilityState.MANAGED_PYTHON_URL) or trim(runtimeState.MANAGED_PYTHON_URL) ~= "" and trim(runtimeState.MANAGED_PYTHON_URL) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_SHA256_OK", trim(capabilityState.MANAGED_PYTHON_SHA256_OK) ~= "" and trim(capabilityState.MANAGED_PYTHON_SHA256_OK) or trim(runtimeState.MANAGED_PYTHON_SHA256_OK) ~= "" and trim(runtimeState.MANAGED_PYTHON_SHA256_OK) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_PATH", sanitizePathValue(trim(capabilityState.MANAGED_PYTHON_PATH) ~= "" and trim(capabilityState.MANAGED_PYTHON_PATH) or trim(runtimeState.MANAGED_PYTHON_PATH)))
    appendKey(diagnostics, "MANAGED_PYTHON_REPLACED", trim(capabilityState.MANAGED_PYTHON_REPLACED) ~= "" and trim(capabilityState.MANAGED_PYTHON_REPLACED) or trim(runtimeState.MANAGED_PYTHON_REPLACED) ~= "" and trim(runtimeState.MANAGED_PYTHON_REPLACED) or "unknown")
    appendKey(diagnostics, "MANAGED_PYTHON_ROLLBACK", trim(capabilityState.MANAGED_PYTHON_ROLLBACK) ~= "" and trim(capabilityState.MANAGED_PYTHON_ROLLBACK) or trim(runtimeState.MANAGED_PYTHON_ROLLBACK) ~= "" and trim(runtimeState.MANAGED_PYTHON_ROLLBACK) or "unknown")
    appendKey(diagnostics, "SYSTEM_PYTHON_PATH", sanitizePathValue(trim(capabilityState.SYSTEM_PYTHON_PATH) ~= "" and trim(capabilityState.SYSTEM_PYTHON_PATH) or trim(runtimeState.SYSTEM_PYTHON_PATH)))
    appendKey(diagnostics, "SYSTEM_PYTHON_VERSION", trim(capabilityState.SYSTEM_PYTHON_VERSION) ~= "" and trim(capabilityState.SYSTEM_PYTHON_VERSION) or trim(runtimeState.SYSTEM_PYTHON_VERSION) ~= "" and trim(runtimeState.SYSTEM_PYTHON_VERSION) or "unknown")
    appendKey(diagnostics, "SYSTEM_PYTHON_USED", trim(capabilityState.SYSTEM_PYTHON_USED) ~= "" and trim(capabilityState.SYSTEM_PYTHON_USED) or trim(runtimeState.SYSTEM_PYTHON_USED) ~= "" and trim(runtimeState.SYSTEM_PYTHON_USED) or "unknown")
    appendKey(diagnostics, "VENV_PYTHON_PATH", sanitizePathValue(trim(capabilityState.VENV_PYTHON_PATH) ~= "" and trim(capabilityState.VENV_PYTHON_PATH) or trim(runtimeState.VENV_PYTHON_PATH) ~= "" and trim(runtimeState.VENV_PYTHON_PATH) or trim(runtimeState.VENV_PYTHON)))
    appendKey(diagnostics, "AUDIO_SEPARATOR_IMPORT", trim(capabilityState.AUDIO_SEPARATOR_IMPORT) ~= "" and trim(capabilityState.AUDIO_SEPARATOR_IMPORT) or trim(runtimeState.AUDIO_SEPARATOR_IMPORT) ~= "" and trim(runtimeState.AUDIO_SEPARATOR_IMPORT) or "unknown")
    appendKey(diagnostics, "AUDIO_SEPARATOR_DEPS_COMPLETE", trim(capabilityState.AUDIO_SEPARATOR_DEPS_COMPLETE) ~= "" and trim(capabilityState.AUDIO_SEPARATOR_DEPS_COMPLETE) or trim(runtimeState.AUDIO_SEPARATOR_DEPS_COMPLETE) ~= "" and trim(runtimeState.AUDIO_SEPARATOR_DEPS_COMPLETE) or "unknown")
    appendKey(diagnostics, "BACKEND_DEPS_COMPLETE", trim(capabilityState.BACKEND_DEPS_COMPLETE) ~= "" and trim(capabilityState.BACKEND_DEPS_COMPLETE) or trim(runtimeState.BACKEND_DEPS_COMPLETE) ~= "" and trim(runtimeState.BACKEND_DEPS_COMPLETE) or "unknown")
    appendKey(diagnostics, "BACKEND_DEPS_REASON", trim(capabilityState.BACKEND_DEPS_REASON) ~= "" and trim(capabilityState.BACKEND_DEPS_REASON) or trim(runtimeState.BACKEND_DEPS_REASON) ~= "" and trim(runtimeState.BACKEND_DEPS_REASON) or "unknown")
    appendKey(diagnostics, "BUILD_TOOLS_MISSING", trim(capabilityState.BUILD_TOOLS_MISSING) ~= "" and trim(capabilityState.BUILD_TOOLS_MISSING) or trim(runtimeState.BUILD_TOOLS_MISSING) ~= "" and trim(runtimeState.BUILD_TOOLS_MISSING) or "unknown")
    appendKey(diagnostics, "TORCH_VERSION", trim(capabilityState.TORCH_VERSION) ~= "" and trim(capabilityState.TORCH_VERSION) or probeTorchVersion ~= "" and probeTorchVersion or "unknown")
    appendKey(diagnostics, "TORCHAUDIO_VERSION", trim(capabilityState.TORCHAUDIO_VERSION) ~= "" and trim(capabilityState.TORCHAUDIO_VERSION) or probeTorchaudioVersion ~= "" and probeTorchaudioVersion or "unknown")
    appendKey(diagnostics, "TORCH_SUPPORTED", trim(capabilityState.TORCH_SUPPORTED) ~= "" and trim(capabilityState.TORCH_SUPPORTED) or probeTorchSupported)
    appendKey(diagnostics, "TORCHAUDIO_PRESENT", trim(capabilityState.TORCHAUDIO_PRESENT) ~= "" and trim(capabilityState.TORCHAUDIO_PRESENT) or probeTorchaudioPresent)
    appendKey(diagnostics, "RUNTIME_DRIFT_DETECTED", resolvedCapabilityValue("RUNTIME_DRIFT_DETECTED", probeRuntimeDriftDetected))
    appendKey(diagnostics, "RUNTIME_DRIFT_REASON", resolvedCapabilityValue("RUNTIME_DRIFT_REASON", probeRuntimeDriftReason))
    appendKey(diagnostics, "FFmpeg path", sanitizePathValue(detectedFfmpegPath))
    appendKey(diagnostics, "FFmpeg version", ffmpegVersion)
    appendKey(diagnostics, "Bundle created", bundleTimestamp)
    appendKey(diagnostics, "Bundle path", bundleDir)
    for i = 1, #platform.extraSummary do
        appendLine(diagnostics, platform.extraSummary[i])
    end
    appendLine(diagnostics, "=== END VERSION AND PLATFORM SUMMARY ===")
    appendLine(diagnostics, "")
    appendLine(diagnostics, "STEMwerk Support Bundle")
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Install Detection")
    appendKey(diagnostics, "Install root", INSTALL.root or "missing")
    appendKey(diagnostics, "Install scripts dir", INSTALL.scriptsDir or "missing")
    appendKey(diagnostics, "Canonical scripts root", INSTALL.canonical or "missing")
    appendKey(diagnostics, "ReaPack scripts root", INSTALL.reapack or "missing")
    appendKey(diagnostics, "Install status", INSTALL.status or "undetected")
    appendKey(diagnostics, "Runtime base source", runtimeBaseSource)
    appendKey(diagnostics, "Setup action @version", setupVersion ~= "" and setupVersion or "missing")
    appendKey(diagnostics, "REAPER GetOS raw", REAPER_OS_RAW ~= "" and REAPER_OS_RAW or "missing")
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Runtime State Files")
    local copiedFiles = {}
    local stateStartedAt = phaseStart("collect_state")
    for _, line in ipairs(collectStateFiles(runtimePaths.runtimeState, bundleDir, copiedFiles)) do
        appendLine(diagnostics, line)
    end
    phaseDone("collect_state", stateStartedAt)
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Runtime Logs")
    local runtimeLogsStartedAt = phaseStart("collect_runtime_logs")
    for _, line in ipairs(collectRuntimeLogs(runtimePaths.runtimeLogs, bundleDir, copiedFiles)) do
        appendLine(diagnostics, line)
    end
    local debugLogPath = joinPath(getTempBase(), "STEMwerk_debug.log")
    appendLine(diagnostics, "Known Extra Logs")
    appendKey(diagnostics, "Temp debug log", fileExists(debugLogPath) and debugLogPath or "missing")
    if fileExists(debugLogPath) then
        local ok, mode = copySupportTextFile(debugLogPath, joinPath(bundleDir, "runtime_logs", "STEMwerk_debug.log"), 512 * 1024)
        if ok then
            copiedFiles[#copiedFiles + 1] = "runtime_logs/STEMwerk_debug.log (" .. mode .. ")"
        end
    end
    phaseDone("collect_runtime_logs", runtimeLogsStartedAt)
    appendLine(diagnostics, "")

    local cacheLogDir = getStemwerkCacheLogDir()
    local persistentRunLogs = { run_summary = false, separation_log = false, stdout = false, stemwerk_log = false }
    local recentRunsStartedAt = phaseStart("collect_recent_runs")
    local persistentDiagFiles = {
        "run_summary.txt",
        "output_detection.txt",
        "separation_log.txt",
        "stdout.txt",
        "stderr.txt",
        "exit_code.txt",
        "done.txt",
        "separation_timing_summary.txt",
        "separation_timing_jobs.jsonl",
        "stemwerk.log",
    }
    for _, name in ipairs(persistentDiagFiles) do
        local src = joinPath(cacheLogDir, name)
        if fileExists(src) then
            local dst = joinPath(bundleDir, "runtime_logs", "run_" .. name)
            local ok, mode = copySupportTextFile(src, dst, 512 * 1024)
            if ok then
                copiedFiles[#copiedFiles + 1] = "runtime_logs/run_" .. name .. " (" .. mode .. ")"
            end
            if name == "run_summary.txt" then persistentRunLogs.run_summary = true end
            if name == "separation_log.txt" then persistentRunLogs.separation_log = true end
            if name == "stdout.txt" then persistentRunLogs.stdout = true end
            if name == "stemwerk.log" then persistentRunLogs.stemwerk_log = true end
        end
    end
    appendKey(diagnostics, "Persistent run_summary.txt", persistentRunLogs.run_summary and cacheLogDir or "missing")
    appendKey(diagnostics, "Persistent separation_log.txt", persistentRunLogs.separation_log and cacheLogDir or "missing")
    appendKey(diagnostics, "Persistent stdout.txt", persistentRunLogs.stdout and cacheLogDir or "missing")
    appendKey(diagnostics, "Persistent stemwerk.log", persistentRunLogs.stemwerk_log and cacheLogDir or "missing")
    appendLine(diagnostics, "")
    appendLine(diagnostics, "Persistent Run Diagnostics")
    for _, line in ipairs(collectPersistedRunDiagnostics(cacheLogDir, bundleDir, copiedFiles)) do
        appendLine(diagnostics, line)
    end
    phaseDone("collect_recent_runs", recentRunsStartedAt)
    appendLine(diagnostics, "")

    -- Archive the raw current-processing state records (one per run_id)
    -- alongside the bundle for offline review, in addition to the live
    -- read deriveCurrentWorkerRunHealth already does below.
    do
        local currentProcessingSrcDir = joinPath(cacheLogDir, "current_processing")
        if pathExists(currentProcessingSrcDir) then
            local currentProcessingDstDir = joinPath(bundleDir, "current_processing")
            ensureDir(currentProcessingDstDir)
            for _, fileName in ipairs(enumerateFiles(currentProcessingSrcDir)) do
                if fileName:match("%.json$") then
                    copySupportTextFile(
                        joinPath(currentProcessingSrcDir, fileName),
                        joinPath(currentProcessingDstDir, fileName),
                        64 * 1024
                    )
                end
            end
        end
    end

    appendLine(diagnostics, "Current Session Evidence")
    local workerEvidenceRoot = findCurrentEvidenceRoot(runtimePaths.base, cacheLogDir)
    local workerSession = workerEvidenceRoot ~= "" and readEnvFile(joinPath(workerEvidenceRoot, "session.env")) or {}
    local currentWorkerHealth = deriveCurrentWorkerRunHealth(
        joinPath(cacheLogDir, "runs"),
        os.time(),
        trim(workerSession.SESSION_STARTED_UTC or ""),
        trim(workerSession.SESSION_ID or ""),
        readCurrentProcessingRecords(cacheLogDir)
    )
    for _, line in ipairs(collectCurrentSessionEvidence(
        runtimePaths.base,
        runtimePaths.runtimeLogs,
        cacheLogDir,
        bundleDir,
        copiedFiles,
        runtimeState,
        currentWorkerHealth
    )) do
        appendLine(diagnostics, line)
    end
    appendLine(diagnostics, "")

    local drumsepDiagnosticsStartedAt = phaseStart("collect_drumsep_runtime")
    local drumsepDiagnostics = buildDrumsepRuntimeDiagnostics(runtimePaths.base, runtimePaths.runtimeState, runtimePaths.runtimeLogs, cacheLogDir)
    phaseDone("collect_drumsep_runtime", drumsepDiagnosticsStartedAt)
    writeFile(joinPath(bundleDir, "drumsep_runtime_status.txt"), table.concat(drumsepDiagnostics, "\n"), "wb")
    copiedFiles[#copiedFiles + 1] = "drumsep_runtime_status.txt"
    appendLine(diagnostics, "DrumSep Runtime Diagnostics")
    appendKey(diagnostics, "DrumSep runtime status file", "drumsep_runtime_status.txt")
    appendKey(diagnostics, "CPU runtime state", fileExists(joinPath(runtimePaths.runtimeState, "drumsep_runtime.env")) and "present" or "missing")
    appendKey(diagnostics, "CUDA runtime state", fileExists(joinPath(runtimePaths.runtimeState, "drumsep_runtime_cuda.env")) and "present" or "missing")
    appendKey(diagnostics, "ROCm runtime state", fileExists(joinPath(runtimePaths.runtimeState, "drumsep_runtime_rocm.env")) and "present" or "missing")
    appendKey(diagnostics, "DirectML runtime state", fileExists(joinPath(runtimePaths.runtimeState, "drumsep_runtime_directml.env")) and "present" or "missing")
    do
        local cudaState = readEnvFile(joinPath(runtimePaths.runtimeState, "drumsep_runtime_cuda.env"))
        appendKey(diagnostics, "drumsep_cuda_runtime_status", trim(cudaState.DRUMSEP_CUDA_RUNTIME_STATUS or cudaState.STATUS or "") ~= "" and trim(cudaState.DRUMSEP_CUDA_RUNTIME_STATUS or cudaState.STATUS or "") or "missing")
        appendKey(diagnostics, "drumsep_cuda_python", trim(cudaState.DRUMSEP_CUDA_PYTHON or "") ~= "" and trim(cudaState.DRUMSEP_CUDA_PYTHON or "") or "missing")
        appendKey(diagnostics, "cuda_device", trim(cudaState.CUDA_DEVICE or "") ~= "" and trim(cudaState.CUDA_DEVICE or "") or "unknown")
        appendKey(diagnostics, "cuda_device_id", trim(cudaState.CUDA_DEVICE_ID or "") ~= "" and trim(cudaState.CUDA_DEVICE_ID or "") or "unknown")
        appendKey(diagnostics, "ort_cuda_provider", trim(cudaState.ORT_CUDA_PROVIDER or "") ~= "" and trim(cudaState.ORT_CUDA_PROVIDER or "") or "unknown")
        appendKey(diagnostics, "cuda_runtime_state_file", joinPath(runtimePaths.runtimeState, "drumsep_runtime_cuda.env"))
    end
    do
        local directmlState = readEnvFile(joinPath(runtimePaths.runtimeState, "drumsep_runtime_directml.env"))
        appendKey(diagnostics, "drumsep_directml_runtime_status", trim(directmlState.DRUMSEP_DIRECTML_RUNTIME_STATUS or directmlState.STATUS or "") ~= "" and trim(directmlState.DRUMSEP_DIRECTML_RUNTIME_STATUS or directmlState.STATUS or "") or "missing")
        appendKey(diagnostics, "drumsep_directml_python", trim(directmlState.DRUMSEP_DIRECTML_PYTHON or "") ~= "" and trim(directmlState.DRUMSEP_DIRECTML_PYTHON or "") or "missing")
        appendKey(diagnostics, "torch_directml_status", trim(directmlState.TORCH_DIRECTML_STATUS or "") ~= "" and trim(directmlState.TORCH_DIRECTML_STATUS or "") or "unknown")
        appendKey(diagnostics, "ort_directml_provider", trim(directmlState.ORT_DIRECTML_PROVIDER or "") ~= "" and trim(directmlState.ORT_DIRECTML_PROVIDER or "") or "unknown")
        appendKey(diagnostics, "directml_runtime_state_file", joinPath(runtimePaths.runtimeState, "drumsep_runtime_directml.env"))
    end
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Settings Snapshot")
    local selectedModel = trim(extStateValue("model"))
    if selectedModel == "" then selectedModel = "htdemucs" end
    appendKey(diagnostics, "Backend/device mode", trim(extStateValue("device")) ~= "" and trim(extStateValue("device")) or "auto")
    appendKey(diagnostics, "Capability profile", trim(capabilityState.PROFILE) ~= "" and trim(capabilityState.PROFILE) or "missing")
    appendKey(diagnostics, "Capability backend", trim(capabilityState.BACKEND) ~= "" and trim(capabilityState.BACKEND) or "missing")
    appendKey(diagnostics, "Capability verification", resolvedCapabilityValue("VERIFICATION", "missing") ~= "" and resolvedCapabilityValue("VERIFICATION", "missing") or "missing")
    appendKey(diagnostics, "Capability drumsep_status", trim(capabilityState.DRUMSEP_STATUS) ~= "" and trim(capabilityState.DRUMSEP_STATUS) or "unknown")
    appendKey(diagnostics, "Capability dks_supported", trim(capabilityState.DKS_SUPPORTED) ~= "" and trim(capabilityState.DKS_SUPPORTED) or "unknown")
    appendKey(diagnostics, "Capability normal_stems_supported", trim(capabilityState.NORMAL_STEMS_SUPPORTED) ~= "" and trim(capabilityState.NORMAL_STEMS_SUPPORTED) or "unknown")
    appendKey(diagnostics, "Capability audio_separator", trim(capabilityState.AUDIO_SEPARATOR) ~= "" and trim(capabilityState.AUDIO_SEPARATOR) or "unknown")
    appendKey(diagnostics, "Capability audio_separator_import", trim(capabilityState.AUDIO_SEPARATOR_IMPORT) ~= "" and trim(capabilityState.AUDIO_SEPARATOR_IMPORT) or "unknown")
    appendKey(diagnostics, "Capability audio_separator_deps_complete", trim(capabilityState.AUDIO_SEPARATOR_DEPS_COMPLETE) ~= "" and trim(capabilityState.AUDIO_SEPARATOR_DEPS_COMPLETE) or "unknown")
    appendKey(diagnostics, "Capability stemwerk_core", trim(capabilityState.STEMWERK_CORE) ~= "" and trim(capabilityState.STEMWERK_CORE) or "unknown")
    appendKey(diagnostics, "Capability runtime drift", resolvedCapabilityValue("RUNTIME_DRIFT_DETECTED", "unknown") ~= "" and resolvedCapabilityValue("RUNTIME_DRIFT_DETECTED", "unknown") or "unknown")
    appendKey(diagnostics, "Capability runtime drift reason", resolvedCapabilityValue("RUNTIME_DRIFT_REASON", "unknown") ~= "" and resolvedCapabilityValue("RUNTIME_DRIFT_REASON", "unknown") or "unknown")
    appendKey(diagnostics, "Bootstrap status", trim(capabilityState.BOOTSTRAP_STATUS) ~= "" and trim(capabilityState.BOOTSTRAP_STATUS) or trim(runtimeState.STATUS) ~= "" and trim(runtimeState.STATUS) or "missing")
    appendKey(diagnostics, "ROCm selected index", trim(runtimeState.SELECTED_TORCH_INDEX) ~= "" and trim(runtimeState.SELECTED_TORCH_INDEX) or "unknown")
    appendKey(diagnostics, "ROCm selected torch stack", trim(runtimeState.SELECTED_TORCH_STACK) ~= "" and trim(runtimeState.SELECTED_TORCH_STACK) or "unknown")
    appendKey(diagnostics, "ROCm torch policy", trim(runtimeState.TORCH_RUNTIME_POLICY) ~= "" and trim(runtimeState.TORCH_RUNTIME_POLICY) or "unknown")
    appendKey(diagnostics, "ROCm detected devices", trim(runtimeState.ROCM_DETECTED_DEVICES) ~= "" and trim(runtimeState.ROCM_DETECTED_DEVICES) or "unknown")
    appendKey(diagnostics, "ROCm selected device", trim(runtimeState.ROCM_SELECTED_DEVICE) ~= "" and trim(runtimeState.ROCM_SELECTED_DEVICE) or "unknown")
    appendKey(diagnostics, "ROCm fallback reason", trim(runtimeState.ROCM_FALLBACK_REASON) ~= "" and trim(runtimeState.ROCM_FALLBACK_REASON) or "none")
    appendKey(diagnostics, "Runtime verify detail", trim(runtimeState.RUNTIME_VERIFY_DETAIL) ~= "" and trim(runtimeState.RUNTIME_VERIFY_DETAIL) or "unknown")
    appendKey(diagnostics, "Quality/model mode", selectedModel .. " (" .. modelModeLabel(selectedModel) .. ")")
    appendKey(diagnostics, "Output track mode", extBool("createNewTracks") and "new tracks" or "in place / takes")
    appendKey(diagnostics, "Create folder", boolLabel(extBool("createFolder")))
    appendKey(diagnostics, "Stem file destination", trim(extStateValue("stemFileDestination")) ~= "" and trim(extStateValue("stemFileDestination")) or "temp")
    appendKey(diagnostics, "Custom stem folder", sanitizeUserFolder(extStateValue("customStemDir")))
    appendKey(diagnostics, "Post-process takes", trim(extStateValue("postProcessTakes")) ~= "" and trim(extStateValue("postProcessTakes")) or "none")
    appendKey(diagnostics, "Language", trim(extStateValue("language")) ~= "" and trim(extStateValue("language")) or "system/default")
    appendKey(diagnostics, "Parallel processing", boolLabel(extBool("parallelProcessing")))
    appendKey(diagnostics, "Keep temp files", boolLabel(extBool("keepTempFiles")))
    appendKey(diagnostics, "Color mode", trim(extStateValue("colorMode")) ~= "" and trim(extStateValue("colorMode")) or "both")
    appendKey(diagnostics, "Theme preset", trim(extStateValue("themePreset")) ~= "" and trim(extStateValue("themePreset")) or "classic")
    appendKey(diagnostics, "Visual FX", boolLabel(extBool("visualFX")))
    appendKey(diagnostics, "Tooltips", boolLabel(extBool("tooltips")))
    appendKey(diagnostics, "Mute original", boolLabel(extBool("muteOriginal")))
    appendKey(diagnostics, "Mute selection", boolLabel(extBool("muteSelection")))
    appendKey(diagnostics, "Delete original", boolLabel(extBool("deleteOriginal")))
    appendKey(diagnostics, "Delete selection", boolLabel(extBool("deleteSelection")))
    appendKey(diagnostics, "Delete original track", boolLabel(extBool("deleteOriginalTrack")))
    appendKey(diagnostics, "Mute original track", boolLabel(extBool("muteOriginalTrack")))
    appendKey(diagnostics, "Debug mode", boolLabel(extBool("debugMode") or extBool("debug")))
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Python Dependency Diagnostics")
    for i = 1, #pythonProbe.summary do
        appendLine(diagnostics, "- " .. pythonProbe.summary[i])
    end
    appendLine(diagnostics, "")

    local tempInventoryStartedAt = phaseStart("collect_temp_inventory")
    local tempInventory, _, tempBase, tempSummary, tempMeta = collectTempInventory(bundleDir, copiedFiles)
    phaseDone("collect_temp_inventory", tempInventoryStartedAt)
    appendLine(diagnostics, "Temp Folder Inventory")
    appendKey(diagnostics, "Temp base", tempBase)
    appendKey(diagnostics, "Temp inventory file", "temp_inventory.txt")
    appendKey(diagnostics, "support_bundle_temp_logs_count", tostring((tempMeta and tempMeta.copiedCount) or 0))
    appendKey(diagnostics, "support_bundle_temp_logs_bytes", tostring((tempMeta and tempMeta.copiedBytes) or 0))
    appendKey(diagnostics, "Recent separation_log.txt",
        persistentRunLogs.separation_log and "present (persistent)" or
        (tempSummary.separation and "present (temp only)" or "missing"))
    appendKey(diagnostics, "Recent stdout.txt",
        persistentRunLogs.stdout and "present (persistent)" or
        (tempSummary.stdout and "present (temp only)" or "missing"))
    appendKey(diagnostics, "Recent stderr.txt", tempSummary.stderr and "present" or "missing")
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Collected Files")
    if #copiedFiles == 0 then
        appendLine(diagnostics, "- no files copied")
    else
        table.sort(copiedFiles)
        for i = 1, #copiedFiles do
            appendLine(diagnostics, "- " .. copiedFiles[i])
        end
    end
    appendLine(diagnostics, "")
    appendLine(diagnostics, "Intentional Exclusions")
    appendLine(diagnostics, "- audio/media files (wav, mp3, flac, aiff, m4a, video)")
    appendLine(diagnostics, "- model/runtime payload files (.onnx, .pt, .pth, .bin, .safetensors, .npy, .npz)")
    appendLine(diagnostics, "- user project media and project-specific output folders")
    appendLine(diagnostics, "- large binary temp artifacts; inventory lists them as excluded when seen")
    appendLine(diagnostics, "")

    local readme = {
        "STEMwerk Support Bundle",
        "",
        "This bundle was created by the REAPER action:",
        "  STEMwerk_Save_Support_Bundle.lua",
        "",
        "Included:",
        "- diagnostics.txt with version/platform/runtime summary",
        "- runtime state files from the STEMwerk state folder when present",
        "- runtime logs from the STEMwerk logs folder when present",
        "- recent persisted run diagnostics/logs",
        "- support_evidence_manifest.txt and semantic current-session evidence when supplied",
        "- processing_summary.txt with recent processing speed/results",
        "- minimal temp_inventory.txt from recent STEMwerk temp folders",
        "- support_bundle_timings.txt with phase timing checkpoints",
        "- platform_details.txt with platform probe output",
        "- python_diagnostics.txt with dependency probe output when available",
        "- drumsep_runtime_status.txt with DrumSep CPU/ROCm/DirectML runtime diagnostics and recent Direct DKS markers",
        "- See processing_summary.txt for recent processing results and speed.",
        "",
        "Intentionally excluded:",
        "- source audio, rendered stems, project media, and other user media",
        "- model files and other large runtime payloads",
        "- large binary temp artifacts",
        "",
        "Bundle folder:",
        "  " .. bundleDir,
        "",
    }

    writeFile(joinPath(bundleDir, "README.txt"), table.concat(readme, "\n"), "wb")
    writeFile(joinPath(bundleDir, "temp_inventory.txt"), table.concat(tempInventory, "\n"), "wb")
    writeFile(joinPath(bundleDir, "processing_summary.txt"), table.concat(buildProcessingSummary(bundleDir, capabilityState, runtimeState), "\n"), "wb")
    writeFile(joinPath(bundleDir, "platform_details.txt"), table.concat(platform.rawBlocks, "\n\n"), "wb")
    writeFile(joinPath(bundleDir, "python_diagnostics.txt"), pythonProbe.rawOutput or "", "wb")

    appendLine(diagnostics, "Support Bundle Phase Timings (seconds)")
    appendKey(diagnostics, "total_start", "see support_bundle_timings.txt")
    appendKey(diagnostics, "collect_root_diagnostics", string.format("%.3f", phaseTimings.collect_root_diagnostics or 0))
    appendKey(diagnostics, "collect_state", string.format("%.3f", phaseTimings.collect_state or 0))
    appendKey(diagnostics, "collect_runtime_logs", string.format("%.3f", phaseTimings.collect_runtime_logs or 0))
    appendKey(diagnostics, "collect_recent_runs", string.format("%.3f", phaseTimings.collect_recent_runs or 0))
    appendKey(diagnostics, "collect_drumsep_runtime", string.format("%.3f", phaseTimings.collect_drumsep_runtime or 0))
    appendKey(diagnostics, "collect_temp_inventory", string.format("%.3f", phaseTimings.collect_temp_inventory or 0))
    appendKey(diagnostics, "collect_probes", string.format("%.3f", phaseTimings.collect_probes or 0))
    appendKey(diagnostics, "create_zip", string.format("%.3f", phaseTimings.create_zip or 0))
    appendKey(diagnostics, "total", string.format("%.3f", phaseTimings.total or 0))
    appendKey(diagnostics, "collect_drumsep_runtime_wall", tostring(phaseTimingsWall.collect_drumsep_runtime or 0))
    appendKey(diagnostics, "total_wall_so_far", tostring(math.max(0, os.time() - totalWallStartedAt)))
    appendLine(diagnostics, "")
    appendLine(diagnostics, "Zip Scope")
    appendKey(diagnostics, "Zip source folder", bundleDir)
    appendKey(diagnostics, "Zip parent folder", bundleParent)
    appendKey(diagnostics, "Zip target", bundleName .. ".zip")
    appendLine(diagnostics, "")

    writeFile(joinPath(bundleDir, "diagnostics.txt"), table.concat(diagnostics, "\n"), "wb")

    local zipStartedAt = phaseStart("create_zip")
    local zipOk, zipPath, zipError, zipMethod = createZipArchive(bundleParent, bundleDir, bundleName, detectedPythonPath)
    phaseDone("create_zip", zipStartedAt)

    phaseTimings.total = math.max(0, os.clock() - totalStartedAt)
    phaseTimingsWall.total = math.max(0, os.time() - totalWallStartedAt)
    timingEvent("total", "end", string.format("cpu_duration=%.3f wall_duration=%d", phaseTimings.total, phaseTimingsWall.total))
    finalizeTimingsAfterZip()
    if zipOk and zipPath and zipPath ~= "" then
        updateZipTimingFile(zipPath, bundleDir, timingsFile, detectedPythonPath)
    end
    writeFile(
        joinPath(bundleDir, "support_bundle_result.txt"),
        table.concat({
            "bundle_dir=" .. tostring(bundleDir),
            "zip_created=" .. (zipOk and "true" or "false"),
            "zip_path=" .. tostring(zipPath or ""),
            "zip_method=" .. tostring(zipMethod or ""),
            "zip_error=" .. tostring(zipError or ""),
            "create_zip_seconds=" .. string.format("%.3f", phaseTimings.create_zip or 0),
            "total_seconds=" .. string.format("%.3f", phaseTimings.total or 0),
            "total_wall_seconds=" .. tostring(phaseTimingsWall.total or 0),
        }, "\n") .. "\n",
        "wb"
    )
    flushTimings()

    return true, {
        bundleDir = bundleDir,
        bundleParent = bundleParent,
        zipPath = zipPath,
        zipCreated = zipOk,
        zipError = zipError,
        zipMethod = zipMethod,
    }
end

local function runWithBusyWindow()
    local busyTitle = "STEMwerk Support Bundle"
    local busyText = "Saving Support Bundle..."
    local busySubtitle = "Collecting logs and diagnostics. This should only take a few seconds."
    local busyOpen = false

    local function drawBusyWindow()
        if not gfx then return end
        gfx.set(0.08, 0.08, 0.08, 1.0)
        gfx.rect(0, 0, gfx.w, gfx.h, 1)
        gfx.set(1, 1, 1, 1)
        gfx.setfont(1, "Arial", 20)
        gfx.x = 20
        gfx.y = 18
        gfx.drawstr(busyTitle)
        gfx.setfont(1, "Arial", 16)
        gfx.x = 20
        gfx.y = 56
        gfx.drawstr(busyText)
        gfx.setfont(1, "Arial", 14)
        gfx.x = 20
        gfx.y = 84
        gfx.drawstr(busySubtitle)
        gfx.update()
    end

    local function closeBusyWindow()
        if busyOpen and gfx and gfx.quit then
            pcall(gfx.quit)
        end
        busyOpen = false
    end

    local function showResult(resultOk, resultValue)
        if resultOk then
            local payload = (type(resultValue) == "table") and resultValue or { bundleDir = tostring(resultValue or "") }
            local bundleDir = tostring(payload.bundleDir or "")
            local bundleParent = tostring(payload.bundleParent or dirname(bundleDir))
            local zipCreated = payload.zipCreated == true and trim(payload.zipPath or "") ~= ""
            local zipPath = tostring(payload.zipPath or "")
            local prompt
            if zipCreated then
                prompt = "STEMwerk support bundle ZIP created:\n\n" .. zipPath
                    .. "\n\nSource folder:\n" .. bundleDir
                    .. "\n\nOpen the support-bundles folder now?"
            else
                local zipNote = ""
                if trim(payload.zipError or "") ~= "" then
                    zipNote = "\n\nZIP creation failed (non-fatal):\n" .. tostring(payload.zipError)
                end
                prompt = "STEMwerk support bundle created:\n\n" .. bundleDir
                    .. zipNote
                    .. "\n\nOpen the folder now?"
            end
            local choice = msgBox("STEMwerk Support Bundle", prompt, 4)
            if choice == 6 then
                openPath((zipCreated and bundleParent ~= "") and bundleParent or bundleDir)
            end
        else
            msgBox("STEMwerk Support Bundle", "Could not create the STEMwerk support bundle.\n\nError:\n" .. tostring(resultValue), 0)
        end
    end

    local function runTask()
        local resultOk, resultValue = performBundleCollection()
        closeBusyWindow()
        if reaper and reaper.defer then
            reaper.defer(function() showResult(resultOk, resultValue) end)
        else
            showResult(resultOk, resultValue)
        end
    end

    if gfx and gfx.init and reaper and reaper.defer then
        gfx.init(busyTitle, 700, 140, 0)
        busyOpen = true
        drawBusyWindow()
        if OS == "macOS" then
            reaper.defer(function()
                drawBusyWindow()
                reaper.defer(runTask)
            end)
        else
            reaper.defer(runTask)
        end
    else
        showCollectingStatus()
        runTask()
    end
end

runWithBusyWindow()
