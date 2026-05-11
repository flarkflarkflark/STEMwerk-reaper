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

-- Copy separation_log.txt and stdout.txt from a run's temp output dir to the
-- persistent log directory, overwriting the previous run's copies.
-- Called on every successful run regardless of the keepTempFiles setting.
function SW_LOG.savePersistentRunLogs(outputDir)
    if not outputDir or outputDir == "" then return end
    local logDir = SW_LOG.getLogDir()
    SW_LOG.ensureDir(logDir)
    local sep = SW_LOG.isWindows() and "\\" or "/"
    for _, name in ipairs({"separation_log.txt", "stdout.txt"}) do
        local src = outputDir .. sep .. name
        local f = io.open(src, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            if data and data ~= "" then
                local dst = logDir .. sep .. name
                local out = io.open(dst, "wb")
                if out then
                    out:write(data)
                    out:close()
                end
            end
        end
    end
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

-- Copy all available diagnostic files from a run's temp output dir to the
-- persistent log directory. Intended for incomplete or failed runs.
-- Missing source files are silently skipped.
-- Also writes run_summary.txt summarising the outcome.
-- opts: { reason = string, exitCode = number|string|nil }
function SW_LOG.preserveDiagnosticsForRun(outputDir, opts)
    if not outputDir or outputDir == "" then return end
    local logDir = SW_LOG.getLogDir()
    SW_LOG.ensureDir(logDir)
    local sep = SW_LOG.isWindows() and "\\" or "/"
    opts = opts or {}
    local reason = tostring(opts.reason or "unknown")

    local diagnosticFiles = {
        "separation_log.txt",
        "stdout.txt",
        "stderr.txt",
        "exit_code.txt",
        "done.txt",
        "output_detection.txt",
    }
    for _, name in ipairs(diagnosticFiles) do
        local src = outputDir .. sep .. name
        local f = io.open(src, "rb")
        if f then
            local fileData = f:read("*a")
            f:close()
            if fileData then
                local dst = logDir .. sep .. name
                local out = io.open(dst, "wb")
                if out then
                    out:write(fileData)
                    out:close()
                end
            end
        end
    end

    local exitCode = opts.exitCode
    if exitCode == nil then
        exitCode = SW_LOG.readExitCode(outputDir .. sep .. "exit_code.txt")
    end
    local lines = {
        "--- STEMwerk Run Summary ---",
        "timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "reason: " .. reason,
    }
    if exitCode ~= nil then
        lines[#lines + 1] = "exit_code: " .. tostring(exitCode)
    end
    local sf = io.open(logDir .. sep .. "run_summary.txt", "wb")
    if sf then
        sf:write(table.concat(lines, "\n") .. "\n")
        sf:close()
    end
end
