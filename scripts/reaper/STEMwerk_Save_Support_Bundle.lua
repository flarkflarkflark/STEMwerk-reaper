-- @description Stemwerk: Save Support Bundle
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.2.2
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

local function resolveCommandOnPath(name)
    if not name or name == "" then return "" end
    if OS == "Windows" then
        local rc, out = execCommand("where.exe", {name}, 5000)
        if rc == 0 and out ~= "" then
            local first = trim((out:gsub("\r", "")):match("([^\n]+)"))
            return first or ""
        end
    else
        local rc, out = execCommand("which", {name}, 5000)
        if rc == 0 and out ~= "" then
            local first = trim((out:gsub("\r", "")):match("([^\n]+)"))
            return first or ""
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
        "        rel_root = os.path.relpath(root, parent)",
        "        if rel_root == '.':",
        "            rel_root = base",
        "        if not files and not dirs:",
        "            zf.writestr(rel_root.rstrip('/\\\\') + '/', '')",
        "        for name in files:",
        "            src = os.path.join(root, name)",
        "            rel = os.path.relpath(src, parent)",
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
        ok, err, method = tryCreateZipWithPowerShell(bundleDir, zipPath)
        if ok then return true, zipPath, "", method end
        errors[#errors + 1] = method .. ": " .. tostring(err)
        ok, err, method = tryCreateZipWithPython(bundleParent, bundleDir, zipPath, pythonPath)
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

    collectExpectedFileStatus(statusLines, "bootstrap.env", bootstrapEnvPath)
    collectExpectedFileStatus(statusLines, "capabilities.env", capabilitiesEnvPath)
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

local function collectPersistedRunDiagnostics(cacheLogDir, bundleDir, copiedFiles)
    local lines = {}
    local runsRoot = joinPath(cacheLogDir, "runs")
    local destRoot = joinPath(bundleDir, "runtime_runs")
    local maxRunsToInclude = 5
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
        ["exit_code.txt"] = true,
        ["done.txt"] = true,
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

local function collectDrumKitPrototypeDiagnostics(bundleDir, copiedFiles)
    local lines = {}
    local tempBase = getTempBase()
    local destRoot = joinPath(bundleDir, "drumkit_split_runs")
    local maxRunsToInclude = 5
    ensureDir(destRoot)

    local runNames = {}
    for _, name in ipairs(enumerateSubdirs(tempBase)) do
        local lower = tostring(name or ""):lower()
        if lower:match("^stemwerk%-drumsep%-workflow%-prototype%-") and not shouldIgnoreTempFolder(lower) then
            runNames[#runNames + 1] = tostring(name)
        end
    end
    if #runNames == 0 then
        appendLine(lines, "- no Drum Kit Split prototype temp runs found")
        appendKey(lines, "Drum Kit runs source", tempBase)
        return lines
    end

    local entries = {}
    for _, runName in ipairs(runNames) do
        local runSrc = joinPath(tempBase, runName)
        local stat = getPathStat(runSrc)
        entries[#entries + 1] = {
            name = runName,
            src = runSrc,
            epoch = tonumber(stat.epoch) or 0,
        }
    end
    table.sort(entries, function(a, b)
        if (a.epoch or 0) == (b.epoch or 0) then
            return tostring(a.name) > tostring(b.name)
        end
        return (a.epoch or 0) > (b.epoch or 0)
    end)

    local selected = {}
    for idx, entry in ipairs(entries) do
        if idx <= maxRunsToInclude then
            selected[#selected + 1] = entry
        end
    end

    local rootAllowedFiles = {
        ["drumkit_run_metadata.json"] = true,
        ["drumkit_events.jsonl"] = true,
        ["run_metadata.json"] = true,
        ["source_resolution.json"] = true,
        ["import_summary.json"] = true,
    }
    local stageAllowedFiles = {
        ["cmd_stdout.txt"] = true,
        ["cmd_stderr.txt"] = true,
        ["stdout.txt"] = true,
        ["separation_log.txt"] = true,
        ["phase_events.jsonl"] = true,
        ["ffmpeg_extract.log"] = true,
    }

    local copiedCount = 0
    local includedRunNames = {}
    for _, entry in ipairs(selected) do
        local runSrc = entry.src
        local runName = entry.name
        local runDst = joinPath(destRoot, runName)
        ensureDir(runDst)
        includedRunNames[#includedRunNames + 1] = runName

        for _, fileName in ipairs(enumerateFiles(runSrc)) do
            if rootAllowedFiles[fileName] then
                local src = joinPath(runSrc, fileName)
                local dst = joinPath(runDst, fileName)
                local ok, mode = copySupportTextFile(src, dst, 1024 * 1024)
                if ok then
                    copiedCount = copiedCount + 1
                    copiedFiles[#copiedFiles + 1] = "drumkit_split_runs/" .. runName .. "/" .. fileName .. " (" .. mode .. ")"
                end
            end
        end

        for _, sourceDirName in ipairs(enumerateSubdirs(runSrc)) do
            if tostring(sourceDirName):match("^source_%d+") then
                local sourceSrc = joinPath(runSrc, sourceDirName)
                for _, stageDirName in ipairs(enumerateSubdirs(sourceSrc)) do
                    if tostring(stageDirName):match("^stage%d") then
                        local stageSrc = joinPath(sourceSrc, stageDirName)
                        local stageDst = joinPath(runDst, sourceDirName, stageDirName)
                        ensureDir(stageDst)
                        for _, fileName in ipairs(enumerateFiles(stageSrc)) do
                            if stageAllowedFiles[fileName] then
                                local src = joinPath(stageSrc, fileName)
                                local dst = joinPath(stageDst, fileName)
                                local ok, mode = copySupportTextFile(src, dst, 1024 * 1024)
                                if ok then
                                    copiedCount = copiedCount + 1
                                    copiedFiles[#copiedFiles + 1] = "drumkit_split_runs/" .. runName .. "/" .. sourceDirName .. "/" .. stageDirName .. "/" .. fileName .. " (" .. mode .. ")"
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local skipped = math.max(0, #entries - #selected)
    appendLine(lines, string.format("- Drum Kit prototype runs available: %d", #entries))
    appendLine(lines, string.format("- Drum Kit prototype runs included: %d (max %d)", #selected, maxRunsToInclude))
    appendLine(lines, string.format("- Drum Kit prototype runs skipped: %d", skipped))
    appendLine(lines, string.format("- Drum Kit prototype diagnostic files copied: %d", copiedCount))
    if #includedRunNames > 0 then
        appendLine(lines, "- included run_ids: " .. table.concat(includedRunNames, ", "))
    end
    appendLine(lines, "- exclusions: audio/media/reapeaks/model-cache payloads remain excluded")
    appendKey(lines, "Drum Kit runs source", tempBase)
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
    local lower = tostring(line or ""):lower()
    for i = 1, #KNOWN_SUMMARY_MODELS do
        local model = KNOWN_SUMMARY_MODELS[i]
        local pattern = "(^|[^%w_%-])(" .. model .. ")([^%w_%-]|$)"
        local hit = lower:match(pattern)
        if hit then
            return model
        end
    end
    return nil
end

local function setRunResult(entry, result, priority)
    result = trim(result):lower()
    if result ~= "success" and result ~= "fail" and result ~= "partial" and result ~= "unknown" then
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
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local lower = raw:lower()
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
            elseif key == "model" then
                kvAssignIfUnknown(entry, "model", value)
            elseif key == "selected_model" then
                kvAssignIfUnknown(entry, "model", value)
            elseif key == "device" then
                kvAssignIfUnknown(entry, "device", value)
            elseif key == "backend" then
                kvAssignIfUnknown(entry, "backend", value)
            elseif key == "profile" then
                kvAssignIfUnknown(entry, "profile", value)
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
                    setFailureReason(entry, value)
                    entry._clearFailures = (entry._clearFailures or 0) + 1
                    setRunResult(entry, "fail", 4)
                end
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
            elseif key == "exit_code" and tonumber(value) and tonumber(value) ~= 0 then
                kvAssignLast(entry, "error_reason", "exit_code: " .. tostring(value))
                entry._exitNonZero = (entry._exitNonZero or 0) + 1
                entry._clearFailures = (entry._clearFailures or 0) + 1
                setRunResult(entry, "fail", 4)
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
        end
        local requested = raw:match("^STEMWERK_DIAG%s+requested_device=(.+)$")
        if requested and tostring(entry.device or "unknown") == "unknown" then
            kvAssignIfUnknown(entry, "device", requested)
        end
        local autoSelected = raw:match("^STEMWERK_DIAG%s+auto_selected[_%w]*=([%w%-%_:%.%/]+)")
        if autoSelected and tostring(entry.device or "unknown") == "unknown" then
            kvAssignIfUnknown(entry, "device", autoSelected)
        end

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
            }
        end
        return byRun[key]
    end

    for line in tostring(data):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local ts = raw:match("^%[([0-9][^%]]+)%]")
        local runId = raw:match("(STEMwerk_[%w_%-]+)")
        if runId then
            lastRunId = runId
        end

        local cmd = raw:match("^%[[^%]]+%]%s+CMD:%s*(.+)$") or raw
        local targetRun = runId and getRun(runId) or (lastRunId and getRun(lastRunId) or nil)
        if targetRun then
            if ts then targetRun.timestamp = ts end
            parseSupportRunText(targetRun, raw)

            local model = cmd:match("%-%-model%s+\"?([%w%._%-]+)\"?")
            if model then kvAssignIfUnknown(targetRun, "model", model) end
            local device = cmd:match("%-%-device%s+\"?([%w%._%-%:]+)\"?")
            if device then kvAssignIfUnknown(targetRun, "device", device) end
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

local function selectMostFrequentValue(counts)
    local bestValue = nil
    local bestCount = -1
    for value, count in pairs(counts or {}) do
        local c = tonumber(count) or 0
        if c > bestCount then
            bestCount = c
            bestValue = tostring(value)
        end
    end
    return bestValue
end

local function parseRuntimeStemwerkSessions(bundleDir)
    local path = joinPath(bundleDir, "runtime_logs", "run_stemwerk.log")
    local data = readFile(path, "rb")
    if not data or trim(data) == "" then
        return {}
    end

    local sessions = {}
    local current = nil
    local function ensureCurrent(ts)
        if not current then
            current = {
                first_ts = ts or "unknown",
                last_ts = ts or "unknown",
                modelCounts = {},
                deviceCounts = {},
                launches = 0,
            }
        end
    end
    local function pushSession(ts, jobs, mode)
        ensureCurrent(ts)
        local model = selectMostFrequentValue(current.modelCounts) or "unknown"
        local device = selectMostFrequentValue(current.deviceCounts) or "unknown"
        sessions[#sessions + 1] = {
            timestamp = ts or current.last_ts or current.first_ts or "unknown",
            model = model,
            device = device,
            jobs = jobs or "unknown",
            items = jobs or "unknown",
            mode = mode or "unknown",
            log_path = "runtime_logs/run_stemwerk.log",
        }
        current = nil
    end

    for line in tostring(data):gmatch("[^\r\n]+") do
        local raw = trim(line)
        local ts = raw:match("^%[([0-9][^%]]+)%]")
        local cmd = raw:match("^%[[^%]]+%]%s+CMD:%s*(.+)$")
        if cmd then
            local model = cmd:match("%-%-model%s+\"?([%w%._%-]+)\"?")
            local device = cmd:match("%-%-device%s+\"?([%w%._%-%:]+)\"?")
            if model or device then
                ensureCurrent(ts)
                current.last_ts = ts or current.last_ts
                current.launches = (current.launches or 0) + 1
                if model then
                    current.modelCounts[model] = (current.modelCounts[model] or 0) + 1
                end
                if device then
                    current.deviceCounts[device] = (current.deviceCounts[device] or 0) + 1
                end
            end
            local jobs = cmd:match("timing:workers_launched%s+count=(%d+)")
            local mode = cmd:match("timing:workers_launched.-%s+mode=([%w_%-]+)")
            if jobs or mode then
                pushSession(ts, jobs, mode)
            end
        end
    end

    if current and (current.launches or 0) > 0 then
        pushSession(current.last_ts, tostring(current.launches), "unknown")
    end

    local newestFirst = {}
    for i = #sessions, 1, -1 do
        newestFirst[#newestFirst + 1] = sessions[i]
    end
    return newestFirst
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
        out[#out + 1] = entry
    end

    local timingSummaryEntry = parseTimingSummaryEntry(bundleDir, capabilityState, runtimeState)
    local stemwerkByRun = parseRuntimeStemwerkLogByRun(bundleDir, capabilityState, runtimeState)
    local stemwerkSessions = parseRuntimeStemwerkSessions(bundleDir)

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

        local session = stemwerkSessions[i]
        if session then
            if tostring(entry.model or "unknown") == "unknown" and tostring(session.model or "unknown") ~= "unknown" then entry.model = session.model end
            if tostring(entry.device or "unknown") == "unknown" and tostring(session.device or "unknown") ~= "unknown" then entry.device = session.device end
            if tostring(entry.mode or "unknown") == "unknown" and tostring(session.mode or "unknown") ~= "unknown" then entry.mode = session.mode end
            if tostring(entry.jobs or "unknown") == "unknown" and tostring(session.jobs or "unknown") ~= "unknown" then entry.jobs = session.jobs end
            if tostring(entry.items or "unknown") == "unknown" and tostring(session.items or "unknown") ~= "unknown" then entry.items = session.items end
            if tostring(entry.timestamp or "unknown") == "unknown" and tostring(session.timestamp or "unknown") ~= "unknown" then entry.timestamp = session.timestamp end
            if tostring(entry.log_path or "unknown") == "unknown" then entry.log_path = session.log_path end
        end
    end

    if #out > 0 and timingSummaryEntry then
        local first = out[1]
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

    local lines = {}
    if #out == 0 then
        lines[#lines + 1] = "No recent processing summary available. See runtime_logs/run_stemwerk.log and runtime_runs/."
        return lines
    end

    lines[#lines + 1] = "Recent processing summary (newest first)"
    lines[#lines + 1] = ""
    for idx, entry in ipairs(out) do
        lines[#lines + 1] = string.format("Run %d", idx)
        lines[#lines + 1] = "run: " .. tostring(entry.run_name or "unknown")
        lines[#lines + 1] = "timestamp: " .. tostring(entry.timestamp or "unknown")
        lines[#lines + 1] = "result: " .. tostring(entry.result or "unknown")
        lines[#lines + 1] = "model: " .. tostring(entry.model or "unknown")
        lines[#lines + 1] = "backend: " .. tostring(entry.backend or "unknown")
        lines[#lines + 1] = "profile: " .. tostring(entry.profile or "unknown")
        lines[#lines + 1] = "device: " .. tostring(entry.device or "unknown")
        lines[#lines + 1] = "mode: " .. tostring(entry.mode or "unknown")
        lines[#lines + 1] = "jobs: " .. tostring(entry.jobs or "unknown")
        lines[#lines + 1] = "items: " .. tostring(entry.items or "unknown")
        lines[#lines + 1] = "wall_clock_total: " .. tostring(entry.wall_clock_total or "unknown")
        lines[#lines + 1] = "total_source_duration: " .. tostring(entry.total_source_duration or "unknown")
        lines[#lines + 1] = "realtime_factor: " .. tostring(entry.realtime_factor or "unknown")
        if tostring(entry.result or "unknown") == "fail" or tostring(entry.result or "unknown") == "partial" then
            lines[#lines + 1] = "failure_reason: " .. tostring(entry.error_reason or "unknown")
        end
        lines[#lines + 1] = "bundle_log_path: " .. tostring(entry.log_path or "unknown")
        lines[#lines + 1] = ""
    end
    return lines
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
            folders[#folders + 1] = {
                name = name,
                path = full,
                epoch = 0,
                mtime = "metadata skipped for speed",
            }
        end
    end

    table.sort(folders, function(a, b)
        return tostring(a.name) > tostring(b.name)
    end)

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
            if lowerName == "stdout.txt" then summary.stdout = true end
            if lowerName == "stderr.txt" then summary.stderr = true end
            if lowerName == "separation_log.txt" then summary.separation = true end

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

    return inventoryLines, copied, tempBase, summary
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
    local timingsFile = joinPath(bundleDir, "support_bundle_timings.txt")
    local timingLines = {}
    local totalStartedAt = os.clock()

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
                "%s | create_zip | end | duration=%.3f",
                os.date("%Y-%m-%d %H:%M:%S"),
                tonumber(phaseTimings.create_zip) or 0
            )
        end
        if not hasTotalEnd then
            timingLines[#timingLines + 1] = string.format(
                "%s | total | end | duration=%.3f",
                os.date("%Y-%m-%d %H:%M:%S"),
                tonumber(phaseTimings.total) or 0
            )
        end
        flushTimings()
    end

    local function phaseStart(name)
        timingEvent(name, "start", string.format("cpu_elapsed=%.3f", math.max(0, os.clock() - totalStartedAt)))
        return os.clock()
    end

    local function phaseDone(name, startedAt)
        local elapsed = math.max(0, os.clock() - tonumber(startedAt or 0))
        phaseTimings[name] = elapsed
        timingEvent(name, "end", string.format("duration=%.3f", elapsed))
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

    local drumKitRunsStartedAt = phaseStart("collect_drumkit_runs")
    appendLine(diagnostics, "Drum Kit Split Prototype Diagnostics")
    for _, line in ipairs(collectDrumKitPrototypeDiagnostics(bundleDir, copiedFiles)) do
        appendLine(diagnostics, line)
    end
    phaseDone("collect_drumkit_runs", drumKitRunsStartedAt)
    appendLine(diagnostics, "")

    appendLine(diagnostics, "Settings Snapshot")
    local selectedModel = trim(extStateValue("model"))
    if selectedModel == "" then selectedModel = "htdemucs" end
    appendKey(diagnostics, "Backend/device mode", trim(extStateValue("device")) ~= "" and trim(extStateValue("device")) or "auto")
    appendKey(diagnostics, "Capability profile", trim(capabilityState.PROFILE) ~= "" and trim(capabilityState.PROFILE) or "missing")
    appendKey(diagnostics, "Capability backend", trim(capabilityState.BACKEND) ~= "" and trim(capabilityState.BACKEND) or "missing")
    appendKey(diagnostics, "Capability verification", trim(capabilityState.VERIFICATION) ~= "" and trim(capabilityState.VERIFICATION) or "missing")
    appendKey(diagnostics, "Bootstrap status", trim(capabilityState.BOOTSTRAP_STATUS) ~= "" and trim(capabilityState.BOOTSTRAP_STATUS) or trim(runtimeState.STATUS) ~= "" and trim(runtimeState.STATUS) or "missing")
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
    local tempInventory, _, tempBase, tempSummary = collectTempInventory(bundleDir, copiedFiles)
    phaseDone("collect_temp_inventory", tempInventoryStartedAt)
    appendLine(diagnostics, "Temp Folder Inventory")
    appendKey(diagnostics, "Temp base", tempBase)
    appendKey(diagnostics, "Temp inventory file", "temp_inventory.txt")
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
        "- processing_summary.txt with recent processing speed/results",
        "- minimal temp_inventory.txt from recent STEMwerk temp folders",
        "- support_bundle_timings.txt with phase timing checkpoints",
        "- platform_details.txt with platform probe output",
        "- python_diagnostics.txt with dependency probe output when available",
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

    local zipStartedAt = phaseStart("create_zip")
    local zipOk, zipPath, zipError, zipMethod = createZipArchive(bundleParent, bundleDir, bundleName, detectedPythonPath)
    phaseDone("create_zip", zipStartedAt)

    phaseTimings.total = math.max(0, os.clock() - totalStartedAt)
    timingEvent("total", "end", string.format("duration=%.3f", phaseTimings.total))
    finalizeTimingsAfterZip()

    appendLine(diagnostics, "Support Bundle Phase Timings (seconds)")
    appendKey(diagnostics, "total_start", "see support_bundle_timings.txt")
    appendKey(diagnostics, "collect_root_diagnostics", string.format("%.3f", phaseTimings.collect_root_diagnostics or 0))
    appendKey(diagnostics, "collect_state", string.format("%.3f", phaseTimings.collect_state or 0))
    appendKey(diagnostics, "collect_runtime_logs", string.format("%.3f", phaseTimings.collect_runtime_logs or 0))
    appendKey(diagnostics, "collect_recent_runs", string.format("%.3f", phaseTimings.collect_recent_runs or 0))
    appendKey(diagnostics, "collect_temp_inventory", string.format("%.3f", phaseTimings.collect_temp_inventory or 0))
    appendKey(diagnostics, "collect_probes", string.format("%.3f", phaseTimings.collect_probes or 0))
    appendKey(diagnostics, "create_zip", string.format("%.3f", phaseTimings.create_zip or 0))
    appendKey(diagnostics, "total", string.format("%.3f", phaseTimings.total or 0))
    appendLine(diagnostics, "")
    appendLine(diagnostics, "Zip Scope")
    appendKey(diagnostics, "Zip source folder", bundleDir)
    appendKey(diagnostics, "Zip parent folder", bundleParent)
    appendKey(diagnostics, "Zip target", zipOk and zipPath or (bundleName .. ".zip (failed)"))
    appendLine(diagnostics, "")

    writeFile(joinPath(bundleDir, "diagnostics.txt"), table.concat(diagnostics, "\n"), "wb")
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
