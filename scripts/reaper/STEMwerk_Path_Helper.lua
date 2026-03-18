local M = {}

function M.getOS()
    local ros = ""
    if reaper and reaper.GetOS then
        ros = tostring(reaper.GetOS() or "")
    end
    if ros:match("Win") then return "Windows" end
    if ros:match("OSX") or ros:match("macOS") then return "macOS" end
    return "Linux"
end

function M.pathSep(os)
    return (os == "Windows") and "\\" or "/"
end

local function normalizeForCompare(path, osName)
    local p = tostring(path or "")
    if p == "" then return "" end
    p = p:gsub("[/\\]+", "/")
    p = p:gsub("/+$", "")
    if osName == "Windows" then
        p = p:lower()
    end
    return p
end

function M.pathEquals(a, b, os)
    return normalizeForCompare(a, os) == normalizeForCompare(b, os)
end

function M.ensureTrailingSep(path, sep)
    if not path or path == "" then return "" end
    if path:sub(-1) == sep then return path end
    return path .. sep
end

function M.stripTrailingSep(path)
    if not path or path == "" then return "" end
    return (tostring(path):gsub("[/\\]+$", ""))
end

function M.joinPath(sep, ...)
    local parts = { ... }
    local out = ""
    for i, part in ipairs(parts) do
        if part and part ~= "" then
            local p = tostring(part)
            p = p:gsub("[/\\]+", sep)
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

local function getHome(osName)
    if osName == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

function M.getReaperResourcePath(osName, sep)
    local rp = ""
    if reaper and reaper.GetResourcePath then
        rp = tostring(reaper.GetResourcePath() or "")
    end
    if rp ~= "" then
        return rp
    end

    local home = getHome(osName)
    if osName == "Windows" then
        local appData = os.getenv("APPDATA") or ""
        if appData ~= "" then
            return appData .. "\\REAPER"
        end
        return home .. "\\AppData\\Roaming\\REAPER"
    elseif osName == "macOS" then
        return home .. "/Library/Application Support/REAPER"
    end
    return home .. "/.config/REAPER"
end

function M.getCanonicalInstallRoot(osName, sep)
    local rp = M.getReaperResourcePath(osName, sep)
    if rp == "" then return "" end
    return M.joinPath(sep, rp, "Scripts", "STEMwerk-reaper")
end

function M.deriveInstallRootFromScriptDir(scriptDir, osName, sep)
    local clean = M.stripTrailingSep(scriptDir)
    if clean == "" then return "" end
    local suffix = sep .. "scripts" .. sep .. "reaper"
    local lowerClean = normalizeForCompare(clean, osName)
    local lowerSuffix = normalizeForCompare(suffix, osName)
    if lowerClean:sub(-#lowerSuffix) == lowerSuffix then
        return clean:sub(1, #clean - #suffix)
    end
    return clean
end

function M.resolveInstallRoot(scriptDir, opts)
    opts = opts or {}
    local osName = opts.os or M.getOS()
    local sep = M.pathSep(osName)
    local canonical = M.getCanonicalInstallRoot(osName, sep)
    local actual = M.deriveInstallRootFromScriptDir(scriptDir, osName, sep)
    local hasActual = actual ~= ""
    local root
    local status = "ok"
    if not hasActual and canonical ~= "" then
        root = canonical
        status = "fallback"
        hasActual = true
    else
        root = actual
    end
    local canonicalMismatch = false
    if canonical ~= "" and hasActual then
        canonicalMismatch = not M.pathEquals(root, canonical, osName)
        if canonicalMismatch then
            status = "noncanonical"
        end
    end
    local ok = hasActual
    local scriptsDir = M.ensureTrailingSep(actual ~= "" and actual or root, sep)
    return {
        ok = ok,
        os = osName,
        sep = sep,
        canonical = canonical,
        actual = actual,
        root = root,
        scriptsDir = scriptsDir,
        canonicalMismatch = canonicalMismatch,
        status = status,
    }
end

function M.bootstrapScriptName(os)
    if os == "Windows" then return "STEMwerk_Bootstrap_Windows.ps1" end
    if os == "macOS" then return "STEMwerk_Bootstrap_macOS.sh" end
    return "STEMwerk_Bootstrap_Linux.sh"
end

function M.bootstrapLauncherName(os)
    if os == "Linux" then
        return "STEMwerk_Bootstrap_Linux_Launcher.sh"
    end
    return nil
end

function M.getBootstrapScriptPath(installRoot, os, sep)
    local name = M.bootstrapScriptName(os)
    return M.joinPath(sep, installRoot, name)
end

function M.getBootstrapLauncherPath(installRoot, os, sep)
    local name = M.bootstrapLauncherName(os)
    if not name then return nil end
    return M.joinPath(sep, installRoot, name)
end

function M.readEnvFile(path)
    local data = {}
    if not path or path == "" then return data end
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

function M.writeEnvFile(path, kv)
    if not path or path == "" or type(kv) ~= "table" then return false end
    local f = io.open(path, "w")
    if not f then return false end
    for k, v in pairs(kv) do
        f:write(tostring(k) .. "=" .. tostring(v or "") .. "\n")
    end
    f:close()
    return true
end

function M.getBootstrapGuardPath(runtimeState, sep)
    return M.joinPath(sep, runtimeState, "bootstrap.guard")
end

return M
