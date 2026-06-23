-- STEMwerk_System.lua
-- Low-level OS/path/command/temp helpers.
-- Loaded via dofile() from STEMwerk.lua; returns a helper table.

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

function M.getArch()
    local arch = ""
    if M.getOS() == "Windows" then
        arch = tostring(os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or "")
    else
        local handle = io.popen("uname -m 2>/dev/null", "r")
        if handle then
            arch = tostring(handle:read("*l") or "")
            handle:close()
        end
    end

    arch = arch:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arch == "amd64" then return "x86_64" end
    if arch == "arm64e" then return "arm64" end
    return arch
end

local SYSTEM_OS = rawget(_G, "OS") or M.getOS()
local SYSTEM_PATH_SEP = rawget(_G, "PATH_SEP")
    or ((package.config and package.config:sub(1, 1)) or (SYSTEM_OS == "Windows" and "\\" or "/"))

local function currentOS()
    return rawget(_G, "OS") or SYSTEM_OS
end

local function currentPathSep()
    return rawget(_G, "PATH_SEP") or SYSTEM_PATH_SEP
end

function M.isAbsolutePath(p)
    if not p or p == "" then return false end
    if p:match("^%a:[/\\]") then return true end -- Windows drive
    if p:sub(1, 1) == "/" then return true end -- POSIX
    return false
end

function M.fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

function M.quoteArg(s)
    s = tostring(s)
    if s:find('"') then
        s = s:gsub('"', '\\"')
    end
    if s:find("%s") then
        return '"' .. s .. '"'
    end
    return s
end

function M.shellQuoteSingle(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

-- Get home directory (cross-platform)
function M.getHome()
    if currentOS() == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

function M.isFlatpak()
    local id = os.getenv("FLATPAK_ID")
    if id and id ~= "" then return true end
    local container = os.getenv("container")
    if container and container:lower():find("flatpak") then return true end
    return false
end

function M.getFlatpakTempBase()
    if not M.isFlatpak() then return nil end
    local home = os.getenv("HOME") or "/tmp"
    return home .. "/.cache/STEMwerk"
end

-- Get temp directory (cross-platform)
function M.getTempDir()
    if currentOS() == "Windows" then
        return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    end
    local flatpakTemp = M.getFlatpakTempBase()
    if flatpakTemp then return flatpakTemp end
    return os.getenv("TMPDIR") or "/tmp"
end

-- Create directory (cross-platform)
function M.makeDir(path)
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return
    end
    if currentOS() == "Windows" then
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end

-- Suppress stderr (cross-platform)
function M.suppressStderr()
    return currentOS() == "Windows" and " 2>nul" or " 2>/dev/null"
end

function M.normalizePath(p)
    if not p then return "" end
    local norm = tostring(p)
    if currentOS() == "Windows" then
        norm = norm:gsub("/", "\\")
        norm = norm:lower()
    else
        norm = norm:gsub("\\", "/")
    end
    return norm
end

function M.pathJoin(a, b)
    if a == "" then return b end
    local last = a:sub(-1)
    if last == "/" or last == "\\" then
        return a .. b
    end
    return a .. currentPathSep() .. b
end

function M.parseExecProcessResult(result)
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

function M.exec_capture(cmd, timeoutMs)
    timeoutMs = timeoutMs or 8000
    if reaper and reaper.ExecProcess then
        if SW_LOG.isWindows() and SW_LOG.commandNeedsWindowsShell(cmd) then
            cmd = SW_LOG.wrapCmdForWindows(cmd)
        end
        local rc, out = M.parseExecProcessResult(reaper.ExecProcess(cmd, timeoutMs))
        out = out or ""
        SW_LOG.logExecResult(cmd, rc, out)
        if out ~= "" then
            return tonumber(rc) or -1, out
        end
        if M.isFlatpak() and currentOS() ~= "Windows" then
            debugLog("exec_capture: ExecProcess empty -> flatpak sandbox file fallback")
            local home = os.getenv("HOME") or ""
            local sep = currentPathSep()
            local cachePath = home .. sep .. ".cache" .. sep .. "stemwerk_exec_out.txt"
            local inner = "mkdir -p $HOME/.cache && " .. cmd .. " > $HOME/.cache/stemwerk_exec_out.txt 2>&1"
            local sandboxCmd = "sh -lc " .. M.shellQuoteSingle(inner)
            local rc2 = M.parseExecProcessResult(reaper.ExecProcess(sandboxCmd, timeoutMs))
            local f = io.open(cachePath, "r")
            local content = ""
            if f then
                content = f:read("*a") or ""
                f:close()
                os.remove(cachePath)
            end
            if content ~= "" then
                SW_LOG.logExecResult(sandboxCmd, rc2, content)
                return tonumber(rc2) or tonumber(rc) or -1, content
            end
            debugLog("exec_capture: sandbox fallback empty -> flatpak-spawn host fallback")
            local hostCmd = "flatpak-spawn --host sh -lc " .. M.shellQuoteSingle(inner)
            local rc3 = M.parseExecProcessResult(reaper.ExecProcess(hostCmd, timeoutMs))
            local f2 = io.open(cachePath, "r")
            local content2 = ""
            if f2 then
                content2 = f2:read("*a") or ""
                f2:close()
                os.remove(cachePath)
            end
            if content2 ~= "" then
                SW_LOG.logExecResult(hostCmd, rc3, content2)
                return tonumber(rc3) or tonumber(rc) or -1, content2
            end
        end
        return tonumber(rc) or -1, out
    end
    local ok = os.execute(cmd)
    local rc = (ok == true or ok == 0) and 0 or 1
    SW_LOG.logExecResult(cmd, rc, "")
    return rc, ""
end

function M.execProcess(cmd, timeoutMs)
    timeoutMs = timeoutMs or 8000
    local rc, out = M.exec_capture(cmd, timeoutMs)
    return tonumber(rc) or -1, out or ""
end

-- Execute command without showing a window (Windows-specific)
-- On Windows, os.execute() shows a brief CMD flash. This avoids that.
function M.execHidden(cmd)
    debugLog("execHidden called")
    debugLog("  Command: " .. cmd:sub(1, 200) .. (cmd:len() > 200 and ".." or ""))
    if currentOS() == "Windows" then
        local directCmd = tostring(cmd or "")
        directCmd = directCmd:gsub("%s+2>nul%s*$", "")

        if reaper and reaper.ExecProcess and not SW_LOG.commandNeedsWindowsShell(directCmd) then
            debugLog("  Using reaper.ExecProcess (direct, no shell)")
            reaper.ExecProcess(directCmd, 0)
            debugLog("  Command completed")
            return
        end

        -- Fall back to a temporary VBS wrapper and execute the original command string
        -- directly, without nesting it inside another cmd.exe /c layer.
        local tempDir = os.getenv("TEMP") or os.getenv("TMP") or "."
        local vbsPath = tempDir .. "\\STEMwerk_exec_" .. os.time() .. ".vbs"
        debugLog("  VBS path: " .. vbsPath)
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            vbsFile:write('On Error Resume Next\n')
            vbsFile:write('Dim sh, p\n')
            vbsFile:write('Set sh = CreateObject("WScript.Shell")\n')
            vbsFile:write('Set p = sh.Exec("' .. directCmd:gsub('"', '""') .. '")\n')
            vbsFile:write('Do While p.Status = 0\n')
            vbsFile:write('  WScript.Sleep 50\n')
            vbsFile:write('Loop\n')
            vbsFile:close()
            debugLog("  VBS file created")

            if reaper.ExecProcess then
                debugLog("  Using reaper.ExecProcess via hidden wscript wrapper")
                reaper.ExecProcess('wscript "' .. vbsPath .. '"', 0)  -- 0 = wait for completion
            else
                debugLog("  Using os.execute via hidden wscript wrapper")
                os.execute('wscript "' .. vbsPath .. '"')
            end
            debugLog("  Command completed")

            -- Clean up VBS file
            os.remove(vbsPath)
            debugLog("  VBS file cleaned up")
        else
            -- Fallback to os.execute if VBS creation fails
            debugLog("  VBS creation failed, falling back to os.execute")
            os.execute(cmd)
        end
    else
        debugLog("  Non-Windows, using os.execute")
        os.execute(cmd)
    end
    debugLog("execHidden done")
end

return M
