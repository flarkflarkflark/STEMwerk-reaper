-- STEMwerk_Platform.lua
-- Phase 1 passthrough: collects OS-specific platform knowledge under a stable namespace.
-- No new behavior is introduced. Call sites migrate opportunistically in follow-up tasks.
-- See docs/planning/REFACTOR_2_2_2.md for the broader refactor context.

local M = {}

-- ── OS detection ──────────────────────────────────────────────────────────────

function M.isWindows()
    local os = (reaper and reaper.GetOS and reaper.GetOS()) or ""
    return os:sub(1, 3) == "Win"
end

function M.isMac()
    local os = (reaper and reaper.GetOS and reaper.GetOS()) or ""
    return os:sub(1, 3) == "OSX" or os:sub(1, 5) == "macOS"
end

function M.isLinux()
    local os = (reaper and reaper.GetOS and reaper.GetOS()) or ""
    if os == "" then return true end
    return not M.isWindows() and not M.isMac()
end

-- ── Paths ─────────────────────────────────────────────────────────────────────

function M.pathSep()
    if M.isWindows() then return "\\" end
    return "/"
end

function M.pathJoin(...)
    local args = {...}
    local out = {}
    for i = 1, #args do
        local v = args[i]
        if v ~= nil and v ~= "" then
            out[#out + 1] = v
        end
    end
    if #out == 0 then return "" end
    if #out == 1 then return out[1] end
    return table.concat(out, M.pathSep())
end

-- ── Shell quoting ─────────────────────────────────────────────────────────────

function M.quote(arg)
    if arg == nil then arg = "" end
    arg = tostring(arg)
    if M.isWindows() then
        -- Always wrap in double quotes, double internal quotes
        local quoted = arg:gsub('"', '""')
        return '"' .. quoted .. '"'
    else
        -- Always wrap in single quotes, escape internal single quotes
        if arg == "" then return "''" end
        local quoted = arg:gsub("'", "'\\''")
        return "'" .. quoted .. "'"
    end
end

-- ── Process spawning ──────────────────────────────────────────────────────────

function M.spawn(opts)
    local start = (reaper and reaper.time_precise and reaper.time_precise()) or 0
    local platform = M.isWindows() and "windows" or (M.isMac() and "mac" or "linux")
    local result = {
        ok = false,
        exitCode = nil,
        stdout = nil,
        stderr = "",
        mechanism = "none",
        platform = platform,
        durationMs = 0,
    }
    local function finish()
        local stop = (reaper and reaper.time_precise and reaper.time_precise()) or start
        result.durationMs = math.floor((stop - start) * 1000)
        return result
    end
    local ok, err = pcall(function()
        if type(opts) ~= "table" then return end
        if type(opts.cmd) ~= "string" or opts.cmd == "" then return end
        if opts.mode ~= "fire-and-forget" and opts.mode ~= "capture" then return end
        local args = opts.args or {}
        local quoted = {M.quote(opts.cmd)}
        for i = 1, #args do
            quoted[#quoted + 1] = M.quote(args[i])
        end
        local fullCmd = table.concat(quoted, " ")
        if type(opts.onLog) == "function" then
            opts.onLog("Platform.spawn: " .. fullCmd)
        end
        if opts.mode == "fire-and-forget" then
            if reaper and reaper.ExecProcess then
                reaper.ExecProcess(fullCmd, -1)
                result.ok = true
                result.mechanism = "ExecProcess"
                result.exitCode = nil
                result.stdout = nil
            end
        elseif opts.mode == "capture" then
            local handle = io.popen(fullCmd, "r")
            if handle then
                local out = handle:read("*a") or ""
                handle:close()
                result.ok = true
                result.mechanism = "io.popen"
                result.exitCode = 0
                result.stdout = out
            end
        end
        if type(opts.onLog) == "function" then
            opts.onLog(string.format("Platform.spawn: done ok=%s mechanism=%s durationMs=%d", tostring(result.ok), result.mechanism, result.durationMs))
        end
    end)
    if not ok then
        result.ok = false
        result.mechanism = "none"
    end
    return finish()
end

-- ── Diagnostics ───────────────────────────────────────────────────────────────

function M.version()
    return "0.1.0"
end

return M
