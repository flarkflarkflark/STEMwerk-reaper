-- @description STEMwerk: UI Idle Benchmark - Flashy (LOCAL TEST ONLY - not shipped)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.1.9
-- @changelog
--   Local benchmark entrypoint.

-- Sets benchmark global BEFORE dofile so STEMwerk.lua can see it.
-- Normal flarkAUDIO theme + visual FX enabled.
-- Does NOT permanently alter user settings (no saveSettings call).

_G.STEMWERK_UI_IDLE_BENCHMARK = {
    enabled     = true,
    label       = "flashy",
    duration_sec = 120,
    force_fx    = true,
    force_utility = false,
    frame_count = 0,
    max_interval = 0,
    last_tick   = nil,
    start_time  = nil,
    last_log_t  = nil,
    log_path    = nil,
    done        = false,
}

local info = debug.getinfo(1, "S")
local script_path = info and info.source and info.source:match("@?(.*[/\\])") or ""
local main_path = script_path .. "STEMwerk.lua"

local f = io.open(main_path, "r")
if not f then
    reaper.MB("Could not find STEMwerk.lua at:\n" .. main_path, "Benchmark Error", 0)
    return
end
f:close()

dofile(main_path)

-- After dofile: SETTINGS, updateTheme, reaper.GetResourcePath are available.
-- Force FX on without saving to persistent storage.
if type(SETTINGS) == "table" then
    SETTINGS.visualFX = true
end
if type(updateTheme) == "function" then
    updateTheme()
end

-- Setup log directory and file.
local resPath = (reaper.GetResourcePath and reaper.GetResourcePath()) or "/tmp"
local sep = package.config:sub(1,1)
local logDir = resPath .. sep .. "STEMwerk-benchmarks"
os.execute('mkdir -p "' .. logDir .. '" 2>/dev/null')

local ts = os.date("%Y%m%d-%H%M%S")
local bm = _G.STEMWERK_UI_IDLE_BENCHMARK
bm.log_path  = logDir .. sep .. "ui-idle-" .. bm.label .. "-" .. ts .. ".csv"
bm.start_time = os.clock()
bm.last_tick  = bm.start_time
bm.last_log_t = bm.start_time

local lf = io.open(bm.log_path, "w")
if lf then
    lf:write("# STEMwerk UI Idle Benchmark\n")
    lf:write("# label=" .. bm.label .. "  duration=" .. bm.duration_sec .. "s\n")
    lf:write("# visual_fx=true  force_utility=false\n")
    lf:write("# started=" .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    lf:write("elapsed_sec,frame_count,interval_sec,max_interval_sec,visual_fx,theme,win_w,win_h\n")
    lf:close()
end

local function benchmarkTick()
    local bm = _G.STEMWERK_UI_IDLE_BENCHMARK
    if not bm or bm.done then return end

    -- Stop if gfx window was closed.
    if gfx.w <= 0 and bm.frame_count > 10 then
        bm.done = true
        return
    end

    local now = os.clock()
    local interval = now - (bm.last_tick or now)
    bm.last_tick = now
    bm.frame_count = bm.frame_count + 1
    if interval > bm.max_interval then bm.max_interval = interval end

    local elapsed = now - bm.start_time

    -- Log a row every 5 seconds.
    if (now - bm.last_log_t) >= 5 and bm.log_path then
        bm.last_log_t = now
        local fx  = (type(SETTINGS) == "table") and tostring(SETTINGS.visualFX) or "?"
        local thm = (type(SETTINGS) == "table") and tostring(SETTINGS.themePreset or "classic") or "?"
        local lf2 = io.open(bm.log_path, "a")
        if lf2 then
            lf2:write(string.format("%.2f,%d,%.4f,%.4f,%s,%s,%d,%d\n",
                elapsed, bm.frame_count, interval, bm.max_interval,
                fx, thm, gfx.w, gfx.h))
            lf2:close()
        end
    end

    if elapsed >= bm.duration_sec then
        bm.done = true
        local lf2 = io.open(bm.log_path, "a")
        if lf2 then
            lf2:write(string.format(
                "# SUMMARY: label=%s  frames=%d  elapsed=%.1fs  avg_interval=%.4fs  max_interval=%.4fs\n",
                bm.label, bm.frame_count,
                elapsed,
                elapsed / math.max(1, bm.frame_count),
                bm.max_interval))
            lf2:close()
        end
        reaper.ShowMessageBox(
            string.format("Benchmark done.\nFrames: %d\nElapsed: %.1fs\nAvg interval: %.4fs\nMax interval: %.4fs\nLog: %s",
                bm.frame_count, elapsed,
                elapsed / math.max(1, bm.frame_count),
                bm.max_interval, bm.log_path),
            "STEMwerk Benchmark", 0)
        return
    end

    reaper.defer(benchmarkTick)
end

reaper.defer(benchmarkTick)
