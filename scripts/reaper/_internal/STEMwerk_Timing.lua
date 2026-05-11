-- STEMwerk_Timing.lua
-- Lightweight separation timing diagnostics.
-- Populates global SW_TIMING.

SW_TIMING = SW_TIMING or {}

local function _tnow()
    if reaper and reaper.time_precise then return reaper.time_precise() end
    return os.clock()
end

local function _jesc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"',  '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

local function _jval(v)
    if v == nil then return "null" end
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return tostring(math.floor(v)) end
        return string.format("%.3f", v)
    end
    if t == "boolean" then return v and "true" or "false" end
    return '"' .. _jesc(v) .. '"'
end

local _KEY_ORDER = {
    "job_id", "track", "audio_dur", "model", "device", "mode",
    "render_start", "render_end", "render_dur",
    "process_launch", "first_progress", "progress_50", "progress_90",
    "output_detected", "import_start", "import_end", "import_dur",
    "job_dur", "result",
}

local function _toJsonLine(t)
    local parts, seen = {}, {}
    for _, k in ipairs(_KEY_ORDER) do
        if t[k] ~= nil then
            parts[#parts + 1] = '"' .. k .. '":' .. _jval(t[k])
            seen[k] = true
        end
    end
    for k, v in pairs(t) do
        if not seen[k] then
            parts[#parts + 1] = '"' .. k .. '":' .. _jval(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function SW_TIMING.beginRun(opts)
    opts = opts or {}
    SW_TIMING._run = {
        t_start   = _tnow(),
        model     = tostring(opts.model     or ""),
        device    = tostring(opts.device    or ""),
        mode      = tostring(opts.mode      or "single"),
        job_count = tonumber(opts.job_count) or 1,
    }
    SW_TIMING._jobs = {}
end

function SW_TIMING.beginJob(id, opts)
    opts = opts or {}
    if not SW_TIMING._jobs then SW_TIMING._jobs = {} end
    SW_TIMING._jobs[id] = {
        job_id    = tostring(id),
        t_start   = _tnow(),
        track     = tostring(opts.track     or ""),
        audio_dur = tonumber(opts.audio_dur),
        model     = tostring(opts.model     or ""),
        device    = tostring(opts.device    or ""),
        mode      = tostring(opts.mode      or ""),
    }
end

function SW_TIMING.mark(id, event)
    if not SW_TIMING._jobs then return end
    local j = SW_TIMING._jobs[id]
    if not j then return end
    j[event] = _tnow()
end

function SW_TIMING.endJob(id, result)
    if not SW_TIMING._jobs then return end
    local j = SW_TIMING._jobs[id]
    if not j then return end
    j.t_end  = _tnow()
    j.result = tostring(result or "unknown")
    if j.t_start then j.job_dur = j.t_end - j.t_start end
    if j.import_start and j.import_end then j.import_dur = j.import_end - j.import_start end
    if j.render_start and j.render_end then j.render_dur = j.render_end - j.render_start end
end

function SW_TIMING.endRun(result, opts)
    local r = SW_TIMING._run
    if not r then return end
    opts = opts or {}
    r.t_end  = _tnow()
    r.result = tostring(result or "unknown")
    if r.t_start then r.wall_clock = r.t_end - r.t_start end
    if opts.total_audio then r.total_audio_dur = tonumber(opts.total_audio) end
    if opts.rtf         then r.avg_rtf         = tonumber(opts.rtf) end
    SW_TIMING._writeFiles()
end

function SW_TIMING._writeFiles()
    local r = SW_TIMING._run
    if not r then return end
    if not SW_LOG then return end
    local logDir = SW_LOG.getLogDir()
    SW_LOG.ensureDir(logDir)
    local sep = SW_LOG.isWindows() and "\\" or "/"

    local jobs = {}
    for _, j in pairs(SW_TIMING._jobs or {}) do jobs[#jobs + 1] = j end
    table.sort(jobs, function(a, b)
        return (tonumber(a.job_id) or 0) < (tonumber(b.job_id) or 0)
    end)

    local earliest, latest, sum_dur = nil, nil, 0
    for _, j in ipairs(jobs) do
        if j.t_start and (not earliest or j.t_start < earliest) then earliest = j.t_start end
        if j.t_end   and (not latest   or j.t_end   > latest)   then latest   = j.t_end   end
        sum_dur = sum_dur + (j.job_dur or 0)
    end

    local sf = io.open(logDir .. sep .. "separation_timing_summary.txt", "wb")
    if sf then
        local L = {}
        L[#L + 1] = "--- STEMwerk Separation Timing ---"
        L[#L + 1] = "timestamp: " .. os.date("%Y-%m-%d %H:%M:%S")
        L[#L + 1] = "mode: "      .. r.mode
        L[#L + 1] = "jobs: "      .. tostring(r.job_count)
        L[#L + 1] = "model: "     .. r.model
        L[#L + 1] = "device: "    .. r.device
        L[#L + 1] = "result: "    .. r.result
        if r.wall_clock then
            L[#L + 1] = string.format("wall_clock_total: %.1fs", r.wall_clock)
        end
        if r.total_audio_dur and r.total_audio_dur > 0 then
            L[#L + 1] = string.format("total_source_duration: %.1fs", r.total_audio_dur)
        end
        if r.avg_rtf and r.avg_rtf > 0 then
            L[#L + 1] = string.format("avg_realtime_factor: %.2fx", r.avg_rtf)
        end
        if earliest then L[#L + 1] = string.format("earliest_job_start: %.3f", earliest) end
        if latest   then L[#L + 1] = string.format("latest_job_end: %.3f",     latest) end
        if sum_dur > 0 then
            L[#L + 1] = string.format("sum_of_job_durations: %.1fs", sum_dur)
        end
        if r.wall_clock and r.wall_clock > 0 and sum_dur > 0 and r.mode ~= "single" then
            L[#L + 1] = string.format("overlap_note: %.2fx overlap (%s)", sum_dur / r.wall_clock, r.mode)
        end
        sf:write(table.concat(L, "\n") .. "\n")
        sf:close()
    end

    local jf = io.open(logDir .. sep .. "separation_timing_jobs.jsonl", "wb")
    if jf then
        for _, j in ipairs(jobs) do
            local row = {}
            local function add(k) if j[k] ~= nil and j[k] ~= "" then row[k] = j[k] end end
            add("job_id"); add("track"); add("audio_dur"); add("model"); add("device"); add("mode")
            add("render_start"); add("render_end"); add("render_dur")
            add("process_launch"); add("first_progress"); add("progress_50"); add("progress_90")
            add("output_detected"); add("import_start"); add("import_end"); add("import_dur")
            add("job_dur"); add("result")
            jf:write(_toJsonLine(row) .. "\n")
        end
        jf:close()
    end
end
