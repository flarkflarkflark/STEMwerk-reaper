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

function SW_LOG.getRunsLogDir()
    local sep = SW_LOG.isWindows() and "\\" or "/"
    return SW_LOG.getLogDir() .. sep .. "runs"
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

local function sw_basename(path)
    local p = tostring(path or ""):gsub("[/\\]+$", "")
    return p:match("([^/\\]+)$") or p
end

local function sw_parent(path)
    local p = tostring(path or "")
    p = p:gsub("[/\\]+$", "")
    local parent = p:match("^(.*)[/\\][^/\\]+$")
    if not parent or parent == "" then return "" end
    return parent:gsub("[/\\]+$", "")
end

local function deriveRunAndJobNames(outputDir)
    local dirName = sw_basename(outputDir)
    local parentDirName = sw_basename(sw_parent(outputDir))
    local isJobDir = (dirName == "single")
        or dirName:match("^item_[%w%-_]+$")
        or dirName:match("^track_[%w%-_]+$")

    if dirName:match("^STEMwerk[_%-]") then
        return dirName, "single"
    end
    if isJobDir and parentDirName:match("^STEMwerk[_%-]") then
        return parentDirName, dirName
    end
    if parentDirName:match("^STEMwerk[_%-]") then
        return parentDirName, (dirName ~= "" and dirName or "single")
    end
    return "STEMwerk_unknown", (dirName ~= "" and dirName or "single")
end

local function copyFileIfExists(src, dst)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if data == nil then return false end
    local out = io.open(dst, "wb")
    if not out then return false end
    out:write(data)
    out:close()
    return true
end

function SW_LOG.persistRunDiagnostics(outputDir, opts)
    if not outputDir or outputDir == "" then return nil end
    opts = opts or {}
    local sep = SW_LOG.isWindows() and "\\" or "/"
    local runId, jobName = deriveRunAndJobNames(outputDir)
    local runDir = SW_LOG.getRunsLogDir() .. sep .. runId
    local jobDir = runDir .. sep .. jobName
    SW_LOG.ensureDir(jobDir)

    local allowed = opts.files or {
        "timing_events.jsonl",
        "phase_events.jsonl",
        "stdout.txt",
        "separation_log.txt",
        "exit_code.txt",
        "done.txt",
    }
    for _, name in ipairs(allowed) do
        local src = outputDir .. sep .. name
        local dst = jobDir .. sep .. name
        local ok = copyFileIfExists(src, dst)
        if not ok and opts.logMissing then
            SW_LOG.logExecResult("persistRunDiagnostics: missing " .. tostring(src), nil, "")
        end
    end

    return jobDir
end

-- Copy separation_log.txt and stdout.txt from a run's temp output dir to the
-- persistent log directory, overwriting the previous run's copies.
-- Called on every successful run regardless of the keepTempFiles setting.
function SW_LOG.savePersistentRunLogs(outputDir)
    if not outputDir or outputDir == "" then return end
    SW_LOG.persistRunDiagnostics(outputDir)
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

local function sw_lower_contains_any(lowerText, patterns)
    for i = 1, #(patterns or {}) do
        if lowerText:find(patterns[i], 1, true) then
            return true
        end
    end
    return false
end

function SW_LOG.classifyModelFailure(logText, stdoutText)
    local joined = tostring(logText or "") .. "\n" .. tostring(stdoutText or "")
    local lower = string.lower(joined)
    if lower == "" then return nil end

    local timeoutHints = {
        "read timed out",
        "httpsconnectionpool",
        "dl.fbaipublicfiles.com",
        "max retries exceeded",
        "timeouterror",
        "temporary failure in name resolution",
        "name or service not known",
        "certificate verify failed",
    }
    local checksumHints = {
        "invalid checksum",
        "checksum",
    }

    local hasTimeout = sw_lower_contains_any(lower, timeoutHints)
    local hasChecksum = sw_lower_contains_any(lower, checksumHints)
    local hasModelFile = lower:find("%.th", 1) ~= nil
        or lower:find("955717e8%-8726e21a%.th", 1) ~= nil
        or lower:find("f7e0c4bc%-ba3fe64a%.th", 1) ~= nil
        or lower:find("demucs", 1, true) ~= nil
        or lower:find("audio_separator_model_dir", 1, true) ~= nil
    local hasDownloadContext = lower:find("dl.fbaipublicfiles.com", 1, true) ~= nil
        or lower:find("https://dl.fbaipublicfiles.com", 1, true) ~= nil
        or lower:find("download", 1, true) ~= nil
        or lower:find("connectionerror", 1, true) ~= nil

    local function extractFirst(pattern)
        local hit = joined:match(pattern)
        return hit and tostring(hit) or nil
    end
    local modelPath = extractFirst("([^\r\n]*%.th)")
    local modelUrl = extractFirst("(https?://[%w%._%-%/%?=&]+)")

    if hasChecksum and hasModelFile then
        return {
            error_class = "model_checksum_failed",
            error_hint = "Cached model file appears corrupted. Delete/redownload model cache.",
            model_cache_hint = "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            model_path = modelPath,
            model_url = modelUrl,
            reason = "model_cache_corrupt",
        }
    end
    if hasTimeout and (hasDownloadContext or hasModelFile) then
        return {
            error_class = "model_download_timeout",
            error_hint = "Model download timed out. Check network/VPN/firewall or delete partial model cache and retry.",
            model_cache_hint = "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            model_path = modelPath,
            model_url = modelUrl,
            reason = "model_load_failed",
        }
    end
    if hasDownloadContext then
        return {
            error_class = "model_download_failed",
            error_hint = "Model download failed. Check internet/DNS/proxy/VPN/firewall and retry.",
            model_cache_hint = "Delete corrupted/partial files in the STEMwerk models folder and retry.",
            model_path = modelPath,
            model_url = modelUrl,
            reason = "model_load_failed",
        }
    end
    return nil
end

-- Copy all available diagnostic files from a run's temp output dir to the
-- persistent log directory. Intended for incomplete or failed runs.
-- Missing source files are silently skipped.
-- Also writes run_summary.txt summarising the outcome.
-- opts: { reason = string, exitCode = number|string|nil }
function SW_LOG.preserveDiagnosticsForRun(outputDir, opts)
    if not outputDir or outputDir == "" then return end
    SW_LOG.persistRunDiagnostics(outputDir)
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
    local doneText = SW_LOG.readFileSnippet(outputDir .. sep .. "done.txt", 1024) or ""
    local runSucceeded = tonumber(exitCode) == 0 and tostring(doneText):find("DONE", 1, true) ~= nil
    local sepText = SW_LOG.readFileSnippet(outputDir .. sep .. "separation_log.txt", 128000) or ""
    local outText = SW_LOG.readFileSnippet(outputDir .. sep .. "stdout.txt", 128000) or ""
    local failure = nil
    if not runSucceeded then
        failure = SW_LOG.classifyModelFailure(sepText, outText)
    end
    if failure and failure.reason and reason == "no_stems" then
        reason = tostring(failure.reason)
    end
    local lines = {
        "--- STEMwerk Run Summary ---",
        "timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "reason: " .. reason,
    }
    if failure then
        lines[#lines + 1] = "error_class: " .. tostring(failure.error_class or "unknown")
        lines[#lines + 1] = "error_hint: " .. tostring(failure.error_hint or "")
        lines[#lines + 1] = "model_cache_hint: " .. tostring(failure.model_cache_hint or "")
        if failure.model_url then
            lines[#lines + 1] = "model_url: " .. tostring(failure.model_url)
        end
        if failure.model_path then
            lines[#lines + 1] = "model_path: " .. tostring(failure.model_path)
        end
        SW_LOG.logExecResult(
            "processing_diag",
            nil,
            "STEMWERK_ERROR_CLASS=" .. tostring(failure.error_class or "unknown") .. "\n"
                .. "STEMWERK_ERROR_HINT=" .. tostring(failure.error_hint or "") .. "\n"
                .. "STEMWERK_MODEL_CACHE_HINT=" .. tostring(failure.model_cache_hint or "")
                .. (failure.model_url and ("\nSTEMWERK_MODEL_URL=" .. tostring(failure.model_url)) or "")
                .. (failure.model_path and ("\nSTEMWERK_MODEL_PATH=" .. tostring(failure.model_path)) or "")
        )
    end
    if exitCode ~= nil then
        lines[#lines + 1] = "exit_code: " .. tostring(exitCode)
    end
    local sf = io.open(logDir .. sep .. "run_summary.txt", "wb")
    if sf then
        sf:write(table.concat(lines, "\n") .. "\n")
        sf:close()
    end
end
