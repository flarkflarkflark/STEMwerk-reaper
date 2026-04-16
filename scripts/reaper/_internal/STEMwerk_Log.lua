-- STEMwerk_Log.lua
-- Logging helpers and small file utilities for separation runs.
-- Loaded via dofile() from STEMwerk.lua; populates global SW_LOG.

SW_LOG = SW_LOG or {}

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
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return true
    end
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
