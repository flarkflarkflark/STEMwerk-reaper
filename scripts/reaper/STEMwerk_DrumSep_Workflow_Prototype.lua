--[[
PRIVATE R&D ONLY - NOT FOR REAPACK/PUBLIC RELEASE

Drum Split workflow runner prototype (blocking/synchronous):
1) Selected REAPER item -> temp input wav (ffmpeg clip extract)
2) clean_fast mode: htdemucs -> drums.wav -> DrumSep
3) clean_quality mode: htdemucs_ft -> drums.wav -> DrumSep
4) clean_6stem mode: htdemucs_6s -> drums.wav -> DrumSep
5) direct_creative mode: DrumSep directly on input.wav (experimental/parked)
6) Import DrumSep stems as folder + child tracks at selected item position
]]

local PYTHON_BIN = "/home/flark/.local/share/STEMwerk/.venv/bin/python" -- private local RX 9070 proof route
local DEVICE = "cuda:0" -- private local RX 9070 proof route
local STAGE2_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
local FFMPEG_BIN = "ffmpeg"
local DRUMSEP_WORKFLOW_MODE = "clean_fast"
-- allowed:
-- "clean_fast"       selected item -> htdemucs -> drums.wav -> DrumSep
-- "clean_quality"    selected item -> htdemucs_ft -> drums.wav -> DrumSep
-- "clean_6stem"      selected item -> htdemucs_6s -> drums.wav -> DrumSep
-- "direct_creative"  selected item -> DrumSep directly (experimental/parked due bleed)
local CLEAN_PARENT_MODELS = {
    clean_fast = "htdemucs",
    clean_quality = "htdemucs_ft",
    clean_6stem = "htdemucs_6s",
}
local PARENT_MODEL_LABELS = {
    htdemucs = "Fast",
    htdemucs_ft = "Quality",
    htdemucs_6s = "Expanded",
}
local runDrumSepWorkflowPrototypeBlocking
local ASYNC_TEMP_ROOT_KEY = "__drumkit_async_temp_root"

local STEMS = {
    { key = "kick", file = "kick.wav", name = "Kick", color = {255, 174, 66} },
    { key = "snare", file = "snare.wav", name = "Snare", color = {237, 91, 121} },
    { key = "toms", file = "toms.wav", name = "Toms", color = {142, 124, 195} },
    { key = "hihat", file = "hihat.wav", name = "Hi-Hat", color = {242, 206, 110} },
    { key = "ride", file = "ride.wav", name = "Ride", color = {98, 201, 176} },
    { key = "crash", file = "crash.wav", name = "Crash", color = {106, 168, 255} },
}

local function quoteArg(s)
    s = tostring(s or "")
    if s:find('"') then s = s:gsub('"', '\\"') end
    if s:find("%s") then return '"' .. s .. '"' end
    return s
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function pathJoin(a, b)
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
    local sep = package.config:sub(1, 1) or "/"
    return a .. sep .. b
end

local function makeDir(path)
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
    else
        os.execute("mkdir -p " .. quoteArg(path))
    end
end

local function rgbToReaperColor(r, g, b)
    return reaper.ColorToNative(r, g, b) | 0x1000000
end

local function runShell(cmd, stdoutPath, stderrPath)
    local wrapped = cmd
    if stdoutPath then wrapped = wrapped .. " >" .. quoteArg(stdoutPath) end
    if stderrPath then wrapped = wrapped .. " 2>" .. quoteArg(stderrPath) end
    local ok, _, code = os.execute(wrapped)
    if ok == true then return 0 end
    if type(ok) == "number" then return ok end
    if type(code) == "number" then return code end
    return 1
end

local function isWindowsHost()
    if not reaper or not reaper.GetOS then return false end
    local osName = tostring(reaper.GetOS() or "")
    return osName:find("Win", 1, true) ~= nil
end

local function readTextFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function trimText(s)
    local text = tostring(s or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function buildAsyncStageJob(sourceCtx, stageName, cmd, stageDir, stdoutPath, stderrPath, opts)
    sourceCtx = sourceCtx or {}
    opts = opts or {}
    local srcIdx = tonumber(sourceCtx.source_index or 1) or 1
    local srcCount = tonumber(sourceCtx.source_count or 1) or 1
    local stage = tostring(stageName or "")
    local job = {
        id = string.format("src%03d_%s", srcIdx, stage ~= "" and stage or "stage"),
        source_index = srcIdx,
        source_count = srcCount,
        stage = stage,
        cmd = tostring(cmd or ""),
        cwd = tostring(opts.cwd or stageDir or ""),
        stage_dir = tostring(stageDir or ""),
        stdout_path = tostring(stdoutPath or pathJoin(stageDir or "", "cmd_stdout.txt")),
        stderr_path = tostring(stderrPath or pathJoin(stageDir or "", "cmd_stderr.txt")),
        launcher_path = "",
        pid_file = tostring(opts.pid_file or pathJoin(stageDir or "", "pid.txt")),
        done_file = tostring(opts.done_file or pathJoin(stageDir or "", "done.txt")),
        exit_code_file = tostring(opts.exit_code_file or pathJoin(stageDir or "", "exit_code.txt")),
        log_path = tostring(opts.log_path or pathJoin(stageDir or "", "separation_log.txt")),
        phase_events_path = tostring(opts.phase_events_path or pathJoin(stageDir or "", "phase_events.jsonl")),
        status = "queued",
        pid = nil,
        exit_code = nil,
        started_at = nil,
        finished_at = nil,
        launched_ok = false,
        poll_count = 0,
        failure_reason = nil,
        platform = isWindowsHost() and "windows" or "unix",
        launch_cmd = nil,
        launch_exit_code = nil,
    }
    return job
end

local function writeLauncherForJob(job)
    if not job or type(job) ~= "table" then return false, "invalid_job" end
    if not job.stage_dir or job.stage_dir == "" then return false, "missing_stage_dir" end
    if not job.cmd or job.cmd == "" then return false, "missing_cmd" end
    makeDir(job.stage_dir)

    if job.platform == "windows" then
        local launcherPath = pathJoin(job.stage_dir, "run_bg.ps1")
        local script = table.concat({
            "$ErrorActionPreference = \"Continue\"",
            "$cmd = " .. "'" .. tostring(job.cmd):gsub("'", "''") .. "'",
            "$stdout = " .. "'" .. tostring(job.stdout_path):gsub("'", "''") .. "'",
            "$stderr = " .. "'" .. tostring(job.stderr_path):gsub("'", "''") .. "'",
            "$pidFile = " .. "'" .. tostring(job.pid_file):gsub("'", "''") .. "'",
            "$doneFile = " .. "'" .. tostring(job.done_file):gsub("'", "''") .. "'",
            "$exitFile = " .. "'" .. tostring(job.exit_code_file):gsub("'", "''") .. "'",
            "$workDir = " .. "'" .. tostring(job.cwd or job.stage_dir):gsub("'", "''") .. "'",
            "New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pidFile) | Out-Null",
            "$wrapper = \"& { Set-Location -LiteralPath $workDir; & cmd.exe /c $cmd }\"",
            "$proc = Start-Process -FilePath \"powershell.exe\" -ArgumentList \"-NoProfile\", \"-ExecutionPolicy\", \"Bypass\", \"-Command\", $wrapper -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr",
            "Set-Content -Path $pidFile -Value ($proc.Id.ToString()) -Encoding ASCII",
            "$proc.WaitForExit()",
            "Set-Content -Path $exitFile -Value ($proc.ExitCode.ToString()) -Encoding ASCII",
            "Set-Content -Path $doneFile -Value \"done\" -Encoding ASCII",
        }, "\n") .. "\n"
        local okWrite, errWrite = writeTextFile(launcherPath, script)
        if not okWrite then return false, errWrite or "write_failed" end
        job.launcher_path = launcherPath
        job.launch_cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File " .. quoteArg(launcherPath)
        return true, nil
    end

    local launcherPath = pathJoin(job.stage_dir, "run_bg.sh")
    local script = table.concat({
        "#!/usr/bin/env bash",
        "set +e",
        "CMD=" .. quoteArg(job.cmd),
        "STDOUT_PATH=" .. quoteArg(job.stdout_path),
        "STDERR_PATH=" .. quoteArg(job.stderr_path),
        "PID_FILE=" .. quoteArg(job.pid_file),
        "DONE_FILE=" .. quoteArg(job.done_file),
        "EXIT_FILE=" .. quoteArg(job.exit_code_file),
        "WORK_DIR=" .. quoteArg(job.cwd or job.stage_dir),
        "mkdir -p \"$(dirname \"$PID_FILE\")\"",
        "(cd \"$WORK_DIR\" && bash -lc \"$CMD\") >\"$STDOUT_PATH\" 2>\"$STDERR_PATH\" &",
        "PID=$!",
        "echo \"$PID\" > \"$PID_FILE\"",
        "wait \"$PID\"",
        "EC=$?",
        "echo \"$EC\" > \"$EXIT_FILE\"",
        "echo done > \"$DONE_FILE\"",
    }, "\n") .. "\n"
    local okWrite, errWrite = writeTextFile(launcherPath, script)
    if not okWrite then return false, errWrite or "write_failed" end
    os.execute("chmod +x " .. quoteArg(launcherPath))
    job.launcher_path = launcherPath
    job.launch_cmd = "bash " .. quoteArg(launcherPath) .. " &"
    return true, nil
end

local function launchAsyncStageJob(job)
    if not job or type(job) ~= "table" then return false, "invalid_job" end
    local okLauncher, launcherErr = writeLauncherForJob(job)
    if not okLauncher then
        job.status = "failed"
        job.failure_reason = tostring(launcherErr or "launcher_write_failed")
        return false, job.failure_reason
    end
    job.started_at = nowSeconds()
    local rc = runShell(job.launch_cmd)
    job.launch_exit_code = rc
    if rc == 0 then
        job.status = "running"
        job.launched_ok = true
        return true, nil
    end
    job.status = "failed"
    job.launched_ok = false
    job.failure_reason = "launcher_exit_" .. tostring(rc)
    return false, job.failure_reason
end

local function readStageTerminalMarkers(job)
    if not job or type(job) ~= "table" then return {} end
    local pidRaw = readTextFile(job.pid_file or "")
    local doneRaw = readTextFile(job.done_file or "")
    local exitRaw = readTextFile(job.exit_code_file or "")

    local pid = tonumber(trimText(pidRaw or ""))
    local done = doneRaw ~= nil
    local exitCode = tonumber(trimText(exitRaw or ""))
    return {
        pid = pid,
        done = done,
        exit_code = exitCode,
        pid_found = pidRaw ~= nil,
        done_found = doneRaw ~= nil,
        exit_code_found = exitRaw ~= nil,
    }
end

local function pollAsyncStageJob(job)
    if not job or type(job) ~= "table" then return "failed" end
    job.poll_count = (tonumber(job.poll_count) or 0) + 1
    local markers = readStageTerminalMarkers(job)
    if markers.pid and not job.pid then
        job.pid = markers.pid
    end
    if markers.done then
        job.finished_at = job.finished_at or nowSeconds()
        if markers.exit_code ~= nil then
            job.exit_code = markers.exit_code
        end
        if tonumber(job.exit_code or 1) == 0 then
            job.status = "done"
            return "done"
        end
        job.status = "failed"
        job.failure_reason = job.failure_reason or ("exit_code_" .. tostring(job.exit_code or "unknown"))
        return "failed"
    end
    if job.status == "cancelled" then
        return "cancelled"
    end
    if job.status ~= "running" then
        return "failed"
    end
    return "running"
end

local function finalizeAsyncStageJob(job)
    if not job or type(job) ~= "table" then
        return { ok = false, status = "failed", error = "invalid_job" }
    end
    local duration = nil
    if job.started_at and job.finished_at then
        duration = tonumber(job.finished_at - job.started_at) or 0
    end
    return {
        ok = job.status == "done" and tonumber(job.exit_code or 1) == 0,
        id = job.id,
        stage = job.stage,
        status = job.status,
        pid = job.pid,
        exit_code = job.exit_code,
        started_at = job.started_at,
        finished_at = job.finished_at,
        elapsed_seconds = duration,
        poll_count = job.poll_count,
        launcher_path = job.launcher_path,
        pid_file = job.pid_file,
        done_file = job.done_file,
        exit_code_file = job.exit_code_file,
        stdout_path = job.stdout_path,
        stderr_path = job.stderr_path,
        log_path = job.log_path,
        phase_events_path = job.phase_events_path,
        failure_reason = job.failure_reason,
    }
end

local function killAsyncStageJob(job)
    if not job or type(job) ~= "table" then return false, "invalid_job" end
    local markers = readStageTerminalMarkers(job)
    local pid = tonumber(job.pid or markers.pid or 0) or 0
    if pid <= 0 then
        return false, "missing_pid"
    end
    local rc
    if isWindowsHost() then
        rc = runShell("taskkill /PID " .. tostring(math.floor(pid)) .. " /T /F")
    else
        rc = runShell("kill -TERM " .. tostring(math.floor(pid)))
    end
    if rc == 0 then
        job.status = "cancelled"
        job.finished_at = job.finished_at or nowSeconds()
        job.failure_reason = "cancelled"
        return true, nil
    end
    return false, "kill_exit_" .. tostring(rc)
end

local function runDrumSepWorkflowPrototypeAsync(modeOverride, opts)
    opts = opts or {}
    local mode = tostring(modeOverride or DRUMSEP_WORKFLOW_MODE or "clean_fast")
    local modeLabel = folderModeLabel(mode, CLEAN_PARENT_MODELS[mode])
    local tempRoot = tostring(opts[ASYNC_TEMP_ROOT_KEY] or ("/tmp/stemwerk-drumsep-workflow-prototype-" .. os.date("%Y%m%d-%H%M%S")))
    local eventsPath = pathJoin(tempRoot, "drumkit_events.jsonl")
    local metadataPath = pathJoin(tempRoot, "drumkit_run_metadata.json")
    local onComplete = type(opts.onComplete) == "function" and opts.onComplete or nil

    local callbackSent = false
    local function notifyAsyncComplete(rawResult)
        if callbackSent then return end
        callbackSent = true
        if not onComplete then return end
        local totalImportedStems = 0
        if rawResult and type(rawResult.per_source_results) == "table" then
            for _, srcRes in ipairs(rawResult.per_source_results) do
                totalImportedStems = totalImportedStems + #((srcRes and srcRes.imported_stems) or {})
            end
        elseif rawResult and type(rawResult.imported_stems) == "table" then
            totalImportedStems = #rawResult.imported_stems
        end
        local status = "failed"
        if rawResult and rawResult.ok == true then
            status = "success"
        elseif rawResult and rawResult.error_stage == "partial_failure" then
            status = "partial_success"
        elseif rawResult and rawResult.error_stage == "cancelled" then
            status = "cancelled"
        end
        local completionResult = {
            ok = rawResult and rawResult.ok == true or false,
            async = true,
            status = status,
            workflow_mode = mode,
            mode_label = modeLabel,
            temp_root = tostring((rawResult and rawResult.temp_root) or tempRoot or ""),
            resolved_sources = tonumber((rawResult and rawResult.resolved_source_count) or 0) or 0,
            total_imported_stems = tonumber(totalImportedStems) or 0,
            error = rawResult and rawResult.error_message or nil,
            log_path = rawResult and rawResult.log_path or nil,
            metadata_path = tostring((rawResult and rawResult.run_metadata_path) or metadataPath or ""),
            events_path = tostring((rawResult and rawResult.events_path) or eventsPath or ""),
        }
        local okCb, errCb = pcall(onComplete, completionResult)
        if not okCb then
            logKV("on_complete_callback_error", tostring(errCb or "callback_failed"))
        end
    end

    local runOpts = {}
    for k, v in pairs(opts) do
        runOpts[k] = v
    end
    runOpts.async_enabled = nil
    runOpts.onComplete = nil
    runOpts[ASYNC_TEMP_ROOT_KEY] = tempRoot

    reaper.defer(function()
        local okRun, rawOrErr = xpcall(function()
            return runDrumSepWorkflowPrototypeBlocking(mode, runOpts)
        end, debug.traceback)
        if okRun then
            notifyAsyncComplete(rawOrErr)
            return
        end
        notifyAsyncComplete({
            ok = false,
            error_stage = "async_wrapper",
            error_message = tostring(rawOrErr or "unknown error"),
            log_path = nil,
            temp_root = tempRoot,
            resolved_source_count = 0,
            imported_stems = {},
            run_metadata_path = metadataPath,
            events_path = eventsPath,
        })
    end)

    return {
        ok = nil,
        async = true,
        status = "running",
        run_id = tempRoot,
        temp_root = tempRoot,
        metadata_path = metadataPath,
        events_path = eventsPath,
        workflow_mode = mode,
        mode_label = modeLabel,
        async_scaffold_only = true,
    }
end

local function getScriptDir()
    local _, scriptPath = reaper.get_action_context()
    if not scriptPath or scriptPath == "" then return nil end
    return scriptPath:match("^(.*[/\\])")
end

local function basenameNoExt(path)
    local name = tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
    return name:match("(.+)%.[^.]+$") or name
end

local function sourceIndexLabel(n)
    local idx = tonumber(n) or 1
    if idx < 1 then idx = 1 end
    return string.format("%02d", idx)
end

local function sanitizeLabel(label)
    local s = tostring(label or "")
    s = s:gsub("[%c]+", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "-" then s = "" end
    return s
end

local function sanitizeSourceLabel(label, idxLabel)
    local s = sanitizeLabel(label)
    if s == "" then
        return "Source " .. tostring(idxLabel or "01")
    end
    return s
end

local function sanitizeTrackLabel(label, trackIndex)
    local s = sanitizeLabel(label)
    if s == "" then
        local idx = tonumber(trackIndex) or 0
        if idx < 1 then idx = 1 end
        return "Track " .. tostring(idx)
    end
    return s
end

local function folderModeLabel(mode, parentModel)
    if mode == "direct_creative" then
        return "Direct/Experimental"
    end
    local fromParent = PARENT_MODEL_LABELS[tostring(parentModel or "")]
    if fromParent and fromParent ~= "" then return fromParent end
    local parentFromMode = CLEAN_PARENT_MODELS[tostring(mode or "")]
    local fallback = PARENT_MODEL_LABELS[tostring(parentFromMode or "")]
    if fallback and fallback ~= "" then return fallback end
    return "Fast"
end

local function nowSeconds()
    if reaper and reaper.time_precise then
        return reaper.time_precise()
    end
    return os.clock()
end

local function logKV(key, value)
    reaper.ShowConsoleMsg("[DrumSep Workflow Prototype] " .. tostring(key) .. "=" .. tostring(value) .. "\n")
end

local function jsonEscape(s)
    local text = tostring(s or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("\b", "\\b")
    text = text:gsub("\f", "\\f")
    text = text:gsub("\n", "\\n")
    text = text:gsub("\r", "\\r")
    text = text:gsub("\t", "\\t")
    return text
end

local function isArrayTable(tbl)
    if type(tbl) ~= "table" then return false end
    local n = #tbl
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
            return false
        end
    end
    return true
end

local function jsonEncode(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    end
    if t == "boolean" then
        return value and "true" or "false"
    end
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    end
    if t == "string" then
        return '"' .. jsonEscape(value) .. '"'
    end
    if t ~= "table" then
        return '"' .. jsonEscape(tostring(value)) .. '"'
    end
    if isArrayTable(value) then
        local parts = {}
        for i = 1, #value do
            parts[#parts + 1] = jsonEncode(value[i])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, _ in pairs(value) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = '"' .. jsonEscape(key) .. '":' .. jsonEncode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function writeTextFile(path, content)
    local f = io.open(path, "wb")
    if not f then return false, "open_failed" end
    f:write(content or "")
    f:close()
    return true, nil
end

local function appendTextFile(path, content)
    local f = io.open(path, "ab")
    if not f then return false, "open_failed" end
    f:write(content or "")
    f:close()
    return true, nil
end

local function formatUtcIso(epochSeconds)
    local epoch = tonumber(epochSeconds)
    if not epoch then return "" end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(epoch))
end

local function getTimeSelectionRange()
    local startTime, endTime = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if (endTime or 0) > (startTime or 0) then
        return startTime, endTime
    end
    if reaper.GetSet_LoopTimeRange2 then
        local s2, e2 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
        if (e2 or 0) > (s2 or 0) then
            return s2, e2
        end
    end
    local loopStart, loopEnd = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
    if (loopEnd or 0) > (loopStart or 0) then
        return loopStart, loopEnd
    end
    return nil, nil
end

local function anySoloActive()
    local n = reaper.CountTracks(0) or 0
    for i = 0, n - 1 do
        local tr = reaper.GetTrack(0, i)
        if tr and (reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") or 0) > 0 then
            return true
        end
    end
    return false
end

local function isTrackAudible(track, soloActive)
    if not track or not reaper.ValidatePtr(track, "MediaTrack*") then return false end
    if (reaper.GetMediaTrackInfo_Value(track, "B_MUTE") or 0) > 0.5 then return false end
    if soloActive then
        return (reaper.GetMediaTrackInfo_Value(track, "I_SOLO") or 0) > 0
    end
    return true
end

local function isItemAudible(item, soloActive)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return false end
    local tr = reaper.GetMediaItem_Track(item)
    if not isTrackAudible(tr, soloActive) then return false end
    if (reaper.GetMediaItemInfo_Value(item, "B_MUTE") or 0) > 0.5 then return false end
    return true
end

local function itemOverlapRange(item, startTime, endTime)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local iend = ipos + ilen
    if startTime and endTime then
        local segStart = math.max(ipos, startTime)
        local segEnd = math.min(iend, endTime)
        if segEnd <= segStart then return nil, nil end
        return segStart, segEnd
    end
    if ilen <= 0 then return nil, nil end
    return ipos, iend
end

local function trackName(track)
    if not track then return "" end
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name and name ~= "" then return name end
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0)
    return "Track " .. tostring(idx)
end

local function sourcePathFromTake(take)
    if not take then return nil end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then return nil end
    local p = reaper.GetMediaSourceFileName(src, "")
    if not p or p == "" then return nil end
    return p
end

local function sourceLabelFromItemOrTake(item, take, sourcePath)
    if take and reaper.GetSetMediaItemTakeInfo_String then
        local okTake, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if okTake then
            local cleanTakeName = sanitizeLabel(takeName)
            if cleanTakeName ~= "" then
                return cleanTakeName
            end
        end
    end
    if item and reaper.GetSetMediaItemInfo_String then
        local okItem, itemName = reaper.GetSetMediaItemInfo_String(item, "P_NAME", "", false)
        if okItem then
            local cleanItemName = sanitizeLabel(itemName)
            if cleanItemName ~= "" then
                return cleanItemName
            end
        end
    end
    return basenameNoExt(sourcePath)
end

local function buildResolvedSource(item, segStart, segEnd, sourceKind)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return nil end
    local take = reaper.GetActiveTake(item)
    if not take then return nil end
    local sourcePath = sourcePathFromTake(take)
    if not sourcePath then return nil end

    local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local startOffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
    local playRate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
    local pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH") or 0
    local preservePitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH") or 0
    if playRate <= 0 then return nil end
    local segmentStart = tonumber(segStart or itemPos) or itemPos
    local segmentEnd = tonumber(segEnd or (itemPos + itemLen)) or (itemPos + itemLen)
    local segmentLen = segmentEnd - segmentStart
    if segmentLen <= 0.0001 then return nil end

    local tr = reaper.GetMediaItem_Track(item)
    local trIdx = tr and math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or -1) or -1
    local trName = trackName(tr)
    local extractOffset = math.max(0, startOffs + math.max(0, segmentStart - itemPos) * playRate)
    local extractDuration = math.max(0.01, segmentLen * playRate)

    return {
        item = item,
        take = take,
        track = tr,
        track_index = trIdx,
        track_name = trName,
        source_path = sourcePath,
        source_label = sourceLabelFromItemOrTake(item, take, sourcePath),
        item_position = itemPos,
        item_length = itemLen,
        segment_start = segmentStart,
        segment_end = segmentEnd,
        segment_length = segmentLen,
        take_start_offset = startOffs,
        take_playrate = playRate,
        take_pitch = tonumber(pitch) or 0.0,
        take_preserve_pitch = (tonumber(preservePitch) or 0) ~= 0 and 1 or 0,
        extract_offset = extractOffset,
        extract_duration = extractDuration,
        source_kind = sourceKind or "selected_item",
    }
end

local function resolveWorkflowSources(opts)
    opts = opts or {}
    local selectedItemOverride = opts.selectedItem
    local soloActive = anySoloActive()
    local sources = {}
    local rawOverlapCount = 0
    local hasSelectedOverride = selectedItemOverride and reaper.ValidatePtr(selectedItemOverride, "MediaItem*")
    local timeSelStart, timeSelEnd = getTimeSelectionRange()
    local hasTimeSel = timeSelStart and timeSelEnd and timeSelEnd > timeSelStart

    local selectedItems = {}
    if hasSelectedOverride then
        selectedItems[1] = selectedItemOverride
    else
        local selCount = reaper.CountSelectedMediaItems(0) or 0
        for i = 0, selCount - 1 do
            local it = reaper.GetSelectedMediaItem(0, i)
            if it and reaper.ValidatePtr(it, "MediaItem*") then
                selectedItems[#selectedItems + 1] = it
            end
        end
    end

    if #selectedItems > 0 then
        -- Mirror normal STEMwerk semantics:
        -- explicit item selection takes priority over time selection.
        hasTimeSel = false
        timeSelStart, timeSelEnd = nil, nil
        for _, item in ipairs(selectedItems) do
            local segStart, segEnd = itemOverlapRange(item, hasTimeSel and timeSelStart or nil, hasTimeSel and timeSelEnd or nil)
            if segStart and segEnd then
                rawOverlapCount = rawOverlapCount + 1
                if isItemAudible(item, soloActive) then
                    local src = buildResolvedSource(item, segStart, segEnd, hasTimeSel and "selected_item_time_selection" or "selected_item")
                    if src then
                        sources[#sources + 1] = src
                    end
                end
            end
        end

        if #sources == 0 then
            if rawOverlapCount > 0 then
                return nil, "Selected items overlap but are not audible (muted/solo-filtered) or unsupported."
            end
            if hasTimeSel then
                return nil, "Selected items do not overlap the active time selection."
            end
            return nil, "No valid selected items found."
        end

        table.sort(sources, function(a, b)
            if a.track_index ~= b.track_index then return a.track_index < b.track_index end
            if a.segment_start ~= b.segment_start then return a.segment_start < b.segment_start end
            return tostring(a.source_path) < tostring(b.source_path)
        end)
        if #sources > 0 then
            sources[1].selection_precedence_note = "selected_items_override_time_selection"
        end
        return sources, nil
    end

    local selectedTracks = {}
    local selectedTrackCount = reaper.CountSelectedTracks(0) or 0
    for i = 0, selectedTrackCount - 1 do
        local tr = reaper.GetSelectedTrack(0, i)
        if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
            selectedTracks[#selectedTracks + 1] = tr
        end
    end

    if #selectedTracks > 0 then
        -- Mirror normal STEMwerk semantics:
        -- explicit track selection takes priority over time selection.
        hasTimeSel = false
        timeSelStart, timeSelEnd = nil, nil
        for _, tr in ipairs(selectedTracks) do
            if isTrackAudible(tr, soloActive) then
                local nItems = reaper.CountTrackMediaItems(tr) or 0
                for j = 0, nItems - 1 do
                    local item = reaper.GetTrackMediaItem(tr, j)
                    if item and reaper.ValidatePtr(item, "MediaItem*") then
                        local segStart, segEnd = itemOverlapRange(item, nil, nil)
                        if segStart and segEnd then
                            rawOverlapCount = rawOverlapCount + 1
                            if isItemAudible(item, soloActive) then
                                local src = buildResolvedSource(item, segStart, segEnd, "selected_track")
                                if src then
                                    sources[#sources + 1] = src
                                end
                            end
                        end
                    end
                end
            end
        end

        if #sources == 0 then
            if rawOverlapCount > 0 then
                return nil, "Selected tracks contain items, but none are audible (muted/solo-filtered) or supported."
            end
            return nil, "No valid items found on selected tracks."
        end

        table.sort(sources, function(a, b)
            if a.track_index ~= b.track_index then return a.track_index < b.track_index end
            if a.segment_start ~= b.segment_start then return a.segment_start < b.segment_start end
            return tostring(a.source_path) < tostring(b.source_path)
        end)
        if #sources > 0 then
            sources[1].selection_precedence_note = "selected_tracks_override_time_selection"
        end
        return sources, nil
    end

    if hasTimeSel then
        local tracks = {}
        selectedTrackCount = reaper.CountSelectedTracks(0) or 0
        if selectedTrackCount > 0 then
            for i = 0, selectedTrackCount - 1 do
                local tr = reaper.GetSelectedTrack(0, i)
                if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
                    tracks[#tracks + 1] = tr
                end
            end
        else
            local allTrackCount = reaper.CountTracks(0) or 0
            for i = 0, allTrackCount - 1 do
                local tr = reaper.GetTrack(0, i)
                if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
                    tracks[#tracks + 1] = tr
                end
            end
        end

        for _, tr in ipairs(tracks) do
            if isTrackAudible(tr, soloActive) then
                local nItems = reaper.CountTrackMediaItems(tr) or 0
                for j = 0, nItems - 1 do
                    local item = reaper.GetTrackMediaItem(tr, j)
                    if item and reaper.ValidatePtr(item, "MediaItem*") then
                        local segStart, segEnd = itemOverlapRange(item, timeSelStart, timeSelEnd)
                        if segStart and segEnd then
                            rawOverlapCount = rawOverlapCount + 1
                            if isItemAudible(item, soloActive) then
                                local src = buildResolvedSource(item, segStart, segEnd, "time_selection")
                                if src then
                                    sources[#sources + 1] = src
                                end
                            end
                        end
                    end
                end
            end
        end

        if #sources == 0 then
            if rawOverlapCount > 0 then
                return nil, "No audible items overlap the active time selection."
            end
            return nil, "No items overlap the active time selection."
        end

        table.sort(sources, function(a, b)
            if a.track_index ~= b.track_index then return a.track_index < b.track_index end
            if a.segment_start ~= b.segment_start then return a.segment_start < b.segment_start end
            return tostring(a.source_path) < tostring(b.source_path)
        end)
        return sources, nil
    end

    return nil, "No selected items and no active time selection."
end

local function createTrackAtIndex(trackIndex, name, color, folderDepth)
    reaper.InsertTrackAtIndex(trackIndex, true)
    local track = reaper.GetTrack(0, trackIndex)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
    if folderDepth ~= nil then
        reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", folderDepth)
    end
    if color then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
    end
    return track
end

local function addStemItem(track, stemPath, itemStartPos, itemLen, playbackState, itemTakeName)
    local source = reaper.PCM_Source_CreateFromFile(stemPath)
    if not source then
        return nil, "Failed to open source: " .. tostring(stemPath)
    end
    local item = reaper.AddMediaItemToTrack(track)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", itemStartPos)
    local targetLen = tonumber(itemLen or 0) or 0
    if targetLen > 0 then
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", targetLen)
    else
        local srcLen = reaper.GetMediaSourceLength(source)
        if srcLen and srcLen > 0 then
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", srcLen)
        else
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 1.0)
        end
    end
    local take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, source)
    if playbackState then
        local playRate = tonumber(playbackState.playrate) or 1.0
        if playRate < 0.0001 then playRate = 1.0 end
        local pitch = tonumber(playbackState.pitch) or 0.0
        local preservePitch = (tonumber(playbackState.preserve_pitch) or 0) ~= 0 and 1 or 0
        reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playRate)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch)
        reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", preservePitch)
        -- Stage0 extraction already resolves source offset into the rendered file.
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)
    end
    if itemTakeName and itemTakeName ~= "" then
        if reaper.GetSetMediaItemInfo_String then
            pcall(reaper.GetSetMediaItemInfo_String, item, "P_NAME", itemTakeName, true)
        end
        if reaper.GetSetMediaItemTakeInfo_String then
            pcall(reaper.GetSetMediaItemTakeInfo_String, take, "P_NAME", itemTakeName, true)
        end
    end
    return item
end

local function importDrumKitSplit(stage2Dir, folderLabel, sourceEntry, opts)
    opts = opts or {}
    local useFolder = opts.useFolder ~= false
    local insertAtIndex = tonumber(opts.insertAtIndex)
    local sharedLayout = (type(opts.sharedLayout) == "table") and opts.sharedLayout or nil
    local groupingMode = tostring(opts.groupingMode or "per_item")
    local isPerTrackGrouping = groupingMode == "source_track"
    local itemStartPos = tonumber(sourceEntry and sourceEntry.segment_start or 0) or 0
    local itemLen = tonumber(sourceEntry and sourceEntry.segment_length or 0) or 0
    local playbackState = {
        playrate = sourceEntry and sourceEntry.take_playrate or 1.0,
        pitch = sourceEntry and sourceEntry.take_pitch or 0.0,
        preserve_pitch = sourceEntry and sourceEntry.take_preserve_pitch or 0,
    }
    local modeLabel = sanitizeLabel(opts.modeLabel or "") ~= "" and sanitizeLabel(opts.modeLabel or "") or "Fast"
    local srcIdxLabel = sourceIndexLabel(opts.sourceIndex or sourceEntry and sourceEntry.source_index or 1)
    local srcLabel = sanitizeSourceLabel(sourceEntry and sourceEntry.source_label or "", srcIdxLabel)
    local trackLabel = sanitizeTrackLabel(sourceEntry and sourceEntry.track_name or "", sourceEntry and sourceEntry.track_index or 1)
    local present, missing = {}, {}
    for _, stem in ipairs(STEMS) do
        local p = pathJoin(stage2Dir, stem.file)
        if fileExists(p) then
            local childTrackName
            if isPerTrackGrouping or useFolder then
                childTrackName = string.format("%s - %s - %s", trackLabel, stem.name, modeLabel)
            else
                childTrackName = string.format("%s - %s - %s - %s", trackLabel, srcLabel, stem.name, modeLabel)
            end
            present[#present + 1] = {
                stem = stem,
                path = p,
                child_track_name = childTrackName,
                item_take_name = string.format("%s - %s - %s", stem.name, srcLabel, modeLabel),
            }
        else
            missing[#missing + 1] = stem.name
        end
    end

    if #present == 0 then
        return false, {
            imported = {},
            missing = missing,
            failed = {},
            message = "No DrumSep stems found (kick/snare/toms/hihat/ride/crash).",
        }
    end

    local baseIndex = reaper.CountTracks(0)
    if insertAtIndex and insertAtIndex >= 0 then
        baseIndex = math.floor(insertAtIndex)
    end
    local folderName = folderLabel or string.format("%s - %s - Drum Kit Split - %s", trackLabel, srcLabel, modeLabel)
    local firstChildIndex = baseIndex
    local insertedTrackCount = 0
    local sharedChildTracks = nil
    local lastCreatedChild = nil
    if sharedLayout then
        sharedLayout.child_tracks = sharedLayout.child_tracks or {}
        sharedChildTracks = sharedLayout.child_tracks
        if not sharedLayout.initialized then
            if useFolder then
                local folderTrack = createTrackAtIndex(baseIndex, folderName, rgbToReaperColor(180, 140, 200), 1)
                sharedLayout.folder_track = folderTrack
                insertedTrackCount = insertedTrackCount + 1
                firstChildIndex = baseIndex + 1
            else
                firstChildIndex = baseIndex
            end
            sharedLayout.next_child_index = firstChildIndex
            sharedLayout.use_folder = useFolder
            sharedLayout.initialized = true
        else
            firstChildIndex = tonumber(sharedLayout.next_child_index or baseIndex) or baseIndex
        end
        if useFolder and sharedLayout.folder_track and reaper.ValidatePtr(sharedLayout.folder_track, "MediaTrack*") then
            -- Keep parent folder naming canonical even when reusing shared layout state.
            reaper.GetSetMediaTrackInfo_String(sharedLayout.folder_track, "P_NAME", folderName, true)
        end
    elseif useFolder then
        createTrackAtIndex(baseIndex, folderName, rgbToReaperColor(180, 140, 200), 1)
        firstChildIndex = baseIndex + 1
    end

    local importedNames, failed = {}, {}
    local importedItems, importedPaths = {}, {}
    for idx, entry in ipairs(present) do
        local c = entry.stem.color
        local track = nil
        if sharedChildTracks then
            track = sharedChildTracks[entry.stem.key]
            if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then
                local childIndex = tonumber(sharedLayout.next_child_index or firstChildIndex) or firstChildIndex
                track = createTrackAtIndex(childIndex, entry.child_track_name, rgbToReaperColor(c[1], c[2], c[3]), 0)
                sharedChildTracks[entry.stem.key] = track
                sharedLayout.next_child_index = childIndex + 1
                insertedTrackCount = insertedTrackCount + 1
                lastCreatedChild = track
            end
        else
            local childIndex = firstChildIndex + idx - 1
            track = createTrackAtIndex(childIndex, entry.child_track_name, rgbToReaperColor(c[1], c[2], c[3]), 0)
        end
        local item, err = addStemItem(track, entry.path, itemStartPos, itemLen, playbackState, entry.item_take_name)
        if item then
            importedNames[#importedNames + 1] = entry.stem.name
            importedItems[#importedItems + 1] = item
            importedPaths[#importedPaths + 1] = entry.path
        else
            failed[#failed + 1] = entry.stem.name .. ": " .. tostring(err)
        end
    end
    if sharedLayout and useFolder and lastCreatedChild and reaper.ValidatePtr(lastCreatedChild, "MediaTrack*") then
        if sharedLayout.last_child_track and reaper.ValidatePtr(sharedLayout.last_child_track, "MediaTrack*") then
            reaper.SetMediaTrackInfo_Value(sharedLayout.last_child_track, "I_FOLDERDEPTH", 0)
        end
        reaper.SetMediaTrackInfo_Value(lastCreatedChild, "I_FOLDERDEPTH", -1)
        sharedLayout.last_child_track = lastCreatedChild
    elseif useFolder then
        local lastChild = reaper.GetTrack(0, firstChildIndex + #present - 1)
        if lastChild then reaper.SetMediaTrackInfo_Value(lastChild, "I_FOLDERDEPTH", -1) end
    end

    local msg = { "Imported stems: " .. table.concat(importedNames, ", "), }
    if #missing > 0 then msg[#msg + 1] = "Missing stems: " .. table.concat(missing, ", ") end
    if #failed > 0 then msg[#msg + 1] = "Failed stems: " .. table.concat(failed, " | ") end
    if not sharedLayout then
        insertedTrackCount = #present + (useFolder and 1 or 0)
    end
    return true, {
        imported = importedNames,
        missing = missing,
        failed = failed,
        message = table.concat(msg, "\n"),
        insertedTrackCount = insertedTrackCount,
        importedItems = importedItems,
        importedPaths = importedPaths,
    }
end

local function resolvePython()
    if fileExists(PYTHON_BIN) then return PYTHON_BIN end
    return "python3"
end

local function _showMessage(text, suppress)
    if suppress then return end
    reaper.ShowMessageBox(text, "STEMwerk DrumSep Workflow Prototype", 0)
end

local function refreshImportedMediaItems(items, sourcePaths)
    local seenTracks = {}
    for _, path in ipairs(sourcePaths or {}) do
        if path and path ~= "" and reaper.GetPeakFileName then
            local ok, peakPath = pcall(reaper.GetPeakFileName, path)
            if ok and type(peakPath) == "string" and peakPath ~= "" then
                os.remove(peakPath)
            end
        end
    end
    if reaper.ClearPeakCache then
        pcall(reaper.ClearPeakCache)
    end
    for _, item in ipairs(items or {}) do
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local takeCount = reaper.CountTakes(item) or 0
            for takeIdx = 0, takeCount - 1 do
                local take = reaper.GetTake(item, takeIdx)
                if take and reaper.ValidatePtr(take, "MediaItem_Take*") and reaper.PCM_Source_BuildPeaks then
                    local src = reaper.GetMediaItemTake_Source(take)
                    if src then
                        local okStart, remaining = pcall(reaper.PCM_Source_BuildPeaks, src, 0)
                        if okStart and tonumber(remaining or 0) and tonumber(remaining or 0) > 0 then
                            local guard = 0
                            repeat
                                local okRun, runRemaining = pcall(reaper.PCM_Source_BuildPeaks, src, 1)
                                if not okRun then break end
                                remaining = tonumber(runRemaining or 0) or 0
                                guard = guard + 1
                            until remaining <= 0 or guard > 20000
                            pcall(reaper.PCM_Source_BuildPeaks, src, 2)
                        end
                    end
                end
            end
            local track = reaper.GetMediaItem_Track(item)
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                local trackKey = tostring(track)
                if not seenTracks[trackKey] then
                    seenTracks[trackKey] = track
                end
            end
            if reaper.UpdateItemInProject then
                pcall(reaper.UpdateItemInProject, item)
            end
        end
    end
    for _, track in pairs(seenTracks) do
        if reaper.MarkTrackItemsDirty then
            pcall(reaper.MarkTrackItemsDirty, track, nil)
        end
    end
end

local function runPipelineForSource(mode, sourceEntry, ctx)
    local srcIdxLabel = sourceIndexLabel(ctx and ctx.source_index or sourceEntry and sourceEntry.source_index or 1)
    local srcLabel = sanitizeSourceLabel(sourceEntry and sourceEntry.source_label or "", srcIdxLabel)
    local emitEvent = (ctx and type(ctx.emit_event) == "function") and ctx.emit_event or nil
    local sourceIndex = tonumber(ctx and ctx.source_index or sourceEntry and sourceEntry.source_index or 1) or 1
    local sourceCount = tonumber(ctx and ctx.source_count or 1) or 1
    local function emitSourceEvent(eventName, fields)
        if not emitEvent then return end
        fields = fields or {}
        fields.event = eventName
        fields.source_index = sourceIndex
        fields.source_count = sourceCount
        fields.track_label = sanitizeTrackLabel(sourceEntry and sourceEntry.track_name or "", sourceEntry and sourceEntry.track_index or sourceIndex)
        fields.source_label = srcLabel
        emitEvent(fields)
    end
    local function emitFailure(stageName, message, logPath)
        emitSourceEvent("failure", {
            stage = stageName,
            status = "failed",
            error_message = tostring(message or ""),
            log_path = tostring(logPath or ""),
        })
    end
    local sourceResult = {
        ok = false,
        source_kind = sourceEntry.source_kind,
        source_path = sourceEntry.source_path,
        source_label = srcLabel,
        source_index = sourceIndex,
        source_index_label = srcIdxLabel,
        track_name = sourceEntry.track_name,
        segment_start = sourceEntry.segment_start,
        segment_length = sourceEntry.segment_length,
        temp_root = nil,
        stage0_input_path = nil,
        stage1_output_dir = nil,
        stage2_output_dir = nil,
        direct_drumsep_output_dir = nil,
        stage1_cmd = nil,
        stage2_cmd = nil,
        stage1_exit_code = nil,
        stage2_exit_code = nil,
        imported_stems = {},
        missing_stems = {},
        inserted_track_count = 0,
        import_summary = "",
        imported_items = {},
        imported_paths = {},
        elapsed_seconds = 0,
        error_stage = nil,
        error_message = nil,
        log_path = nil,
    }

    local sourcePrefix = string.format("source_%03d", tonumber(ctx.source_index or 1))
    local root = pathJoin(ctx.batch_root, sourcePrefix)
    local stage0 = pathJoin(root, "stage0_input")
    local stage1Fast = pathJoin(root, "stage1_htdemucs")
    local stage1Quality = pathJoin(root, "stage1_htdemucs_ft")
    local stage16Stem = pathJoin(root, "stage1_htdemucs_6s")
    local stage2 = pathJoin(root, "stage2_drumsep")
    local stage1Direct = pathJoin(root, "stage1_direct_drumsep")
    makeDir(root); makeDir(stage0); makeDir(stage1Fast); makeDir(stage1Quality); makeDir(stage16Stem); makeDir(stage2); makeDir(stage1Direct)

    sourceResult.temp_root = root
    sourceResult.stage1_output_dir = "skipped"
    sourceResult.stage2_output_dir = stage2
    sourceResult.direct_drumsep_output_dir = stage1Direct

    local sourceT0 = nowSeconds()
    local inputWav = pathJoin(stage0, "input.wav")
    sourceResult.stage0_input_path = inputWav
    local ffLog = pathJoin(stage0, "ffmpeg_extract.log")
    emitSourceEvent("stage0_extract_start", {
        stage = "stage0_extract",
        status = "start",
        stage_dir = stage0,
        input_path = tostring(sourceEntry.source_path or ""),
        output_path = inputWav,
        ffmpeg_log_path = ffLog,
    })
    local ffCmd = string.format(
        "%s -y -hide_banner -nostats -loglevel error -i %s -ss %.6f -t %.6f -ar 44100 -ac 2 %s",
        quoteArg(FFMPEG_BIN),
        quoteArg(sourceEntry.source_path),
        sourceEntry.extract_offset,
        sourceEntry.extract_duration,
        quoteArg(inputWav)
    )
    local ffRc = runShell(ffCmd, nil, ffLog)
    if ffRc ~= 0 or not fileExists(inputWav) then
        sourceResult.error_stage = "stage0"
        sourceResult.error_message = "Stage 0 extraction failed."
        sourceResult.log_path = ffLog
        sourceResult.elapsed_seconds = nowSeconds() - sourceT0
        emitFailure("stage0_extract", sourceResult.error_message, ffLog)
        return sourceResult
    end
    emitSourceEvent("stage0_extract_done", {
        stage = "stage0_extract",
        status = "done",
        stage_dir = stage0,
        output_path = inputWav,
        ffmpeg_log_path = ffLog,
        exit_code = ffRc,
    })

    local stage1Rc = 0
    local stage2Rc = 0
    local stage1Cmd = ""
    local stage2Cmd = ""
    local stage2Stderr = ""
    local stage1OutputDir = "skipped"
    local drumsepOutputDir = stage2
    local parentModel = nil

    if mode == "clean_fast" or mode == "clean_quality" or mode == "clean_6stem" then
        parentModel = CLEAN_PARENT_MODELS[mode] or CLEAN_PARENT_MODELS.clean_fast
        if mode == "clean_quality" then
            stage1OutputDir = stage1Quality
        elseif mode == "clean_6stem" then
            stage1OutputDir = stage16Stem
        else
            stage1OutputDir = stage1Fast
        end
        sourceResult.stage1_output_dir = stage1OutputDir

        local stage1Stdout = pathJoin(stage1OutputDir, "cmd_stdout.txt")
        local stage1Stderr = pathJoin(stage1OutputDir, "cmd_stderr.txt")
        stage1Cmd = table.concat({
            quoteArg(ctx.python_bin), quoteArg(ctx.separator_script), quoteArg(inputWav), quoteArg(stage1OutputDir),
            "--model", quoteArg(parentModel), "--device", quoteArg(DEVICE)
        }, " ")
        emitSourceEvent("stage1_parent_start", {
            stage = "stage1_parent",
            status = "start",
            stage_dir = stage1OutputDir,
            parent_model = parentModel,
            stdout_path = stage1Stdout,
            stderr_path = stage1Stderr,
            log_path = pathJoin(stage1OutputDir, "separation_log.txt"),
            command = stage1Cmd,
        })
        stage1Rc = runShell(stage1Cmd, stage1Stdout, stage1Stderr)
        local drumsWav = pathJoin(stage1OutputDir, "drums.wav")
        if stage1Rc ~= 0 or not fileExists(drumsWav) then
            sourceResult.error_stage = "stage1"
            sourceResult.error_message = "Stage 1 failed or drums.wav missing."
            sourceResult.log_path = stage1Stderr
            sourceResult.stage1_exit_code = stage1Rc
            sourceResult.stage1_cmd = stage1Cmd
            sourceResult.elapsed_seconds = nowSeconds() - sourceT0
            emitFailure("stage1_parent", sourceResult.error_message, stage1Stderr)
            return sourceResult
        end
        emitSourceEvent("stage1_parent_done", {
            stage = "stage1_parent",
            status = "done",
            stage_dir = stage1OutputDir,
            parent_model = parentModel,
            stdout_path = stage1Stdout,
            stderr_path = stage1Stderr,
            log_path = pathJoin(stage1OutputDir, "separation_log.txt"),
            exit_code = stage1Rc,
            output_path = drumsWav,
        })

        local stage2Stdout = pathJoin(stage2, "cmd_stdout.txt")
        stage2Stderr = pathJoin(stage2, "cmd_stderr.txt")
        stage2Cmd = table.concat({
            quoteArg(ctx.python_bin), quoteArg(ctx.separator_script), quoteArg(drumsWav), quoteArg(stage2),
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(DEVICE)
        }, " ")
        emitSourceEvent("stage2_drumsep_start", {
            stage = "stage2_drumsep",
            status = "start",
            stage_dir = stage2,
            drumsep_model = STAGE2_MODEL,
            stdout_path = stage2Stdout,
            stderr_path = stage2Stderr,
            log_path = pathJoin(stage2, "separation_log.txt"),
            command = stage2Cmd,
        })
        stage2Rc = runShell(stage2Cmd, stage2Stdout, stage2Stderr)
        if stage2Rc ~= 0 then
            sourceResult.error_stage = "stage2"
            sourceResult.error_message = "Stage 2 failed."
            sourceResult.log_path = stage2Stderr
            sourceResult.stage1_exit_code = stage1Rc
            sourceResult.stage2_exit_code = stage2Rc
            sourceResult.stage1_cmd = stage1Cmd
            sourceResult.stage2_cmd = stage2Cmd
            sourceResult.elapsed_seconds = nowSeconds() - sourceT0
            emitFailure("stage2_drumsep", sourceResult.error_message, stage2Stderr)
            return sourceResult
        end
        emitSourceEvent("stage2_drumsep_done", {
            stage = "stage2_drumsep",
            status = "done",
            stage_dir = stage2,
            drumsep_model = STAGE2_MODEL,
            stdout_path = stage2Stdout,
            stderr_path = stage2Stderr,
            log_path = pathJoin(stage2, "separation_log.txt"),
            exit_code = stage2Rc,
        })
    else
        -- direct_creative: skip htdemucs and run DrumSep directly on stage0 input
        stage1Rc = -1
        drumsepOutputDir = stage1Direct
        local directStdout = pathJoin(stage1Direct, "cmd_stdout.txt")
        stage2Stderr = pathJoin(stage1Direct, "cmd_stderr.txt")
        stage2Cmd = table.concat({
            quoteArg(ctx.python_bin), quoteArg(ctx.separator_script), quoteArg(inputWav), quoteArg(stage1Direct),
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(DEVICE)
        }, " ")
        emitSourceEvent("stage2_drumsep_start", {
            stage = "stage2_drumsep",
            status = "start",
            stage_dir = stage1Direct,
            drumsep_model = STAGE2_MODEL,
            stdout_path = directStdout,
            stderr_path = stage2Stderr,
            log_path = pathJoin(stage1Direct, "separation_log.txt"),
            command = stage2Cmd,
            direct_creative = true,
        })
        stage2Rc = runShell(stage2Cmd, directStdout, stage2Stderr)
        if stage2Rc ~= 0 then
            sourceResult.error_stage = "stage2_direct"
            sourceResult.error_message = "Direct DrumSep stage failed."
            sourceResult.log_path = stage2Stderr
            sourceResult.stage1_exit_code = stage1Rc
            sourceResult.stage2_exit_code = stage2Rc
            sourceResult.stage1_cmd = "skipped"
            sourceResult.stage2_cmd = stage2Cmd
            sourceResult.elapsed_seconds = nowSeconds() - sourceT0
            emitFailure("stage2_drumsep", sourceResult.error_message, stage2Stderr)
            return sourceResult
        end
        emitSourceEvent("stage2_drumsep_done", {
            stage = "stage2_drumsep",
            status = "done",
            stage_dir = stage1Direct,
            drumsep_model = STAGE2_MODEL,
            stdout_path = directStdout,
            stderr_path = stage2Stderr,
            log_path = pathJoin(stage1Direct, "separation_log.txt"),
            exit_code = stage2Rc,
            direct_creative = true,
        })
    end

    local modeLabel = folderModeLabel(mode, parentModel)
    local trackLabel = sanitizeTrackLabel(sourceEntry and sourceEntry.track_name or "", sourceEntry and sourceEntry.track_index or 1)
    local folderLabel = string.format("%s - %s - Drum Kit Split - %s", trackLabel, srcLabel, modeLabel)
    if ctx.shared_import_layout and ctx.shared_import_layout.grouping_mode == "source_track" then
        folderLabel = tostring(ctx.shared_import_layout.folder_label or folderLabel)
    end

    emitSourceEvent("import_start", {
        stage = "import",
        status = "start",
        stage_dir = drumsepOutputDir,
    })
    local ok, importSummary = importDrumKitSplit(
        drumsepOutputDir,
        folderLabel,
        sourceEntry,
        {
            useFolder = ctx.use_folder,
            insertAtIndex = ctx.insert_at_index,
            modeLabel = modeLabel,
            sourceIndex = ctx.source_index,
            groupingMode = ctx.grouping_mode,
            sharedLayout = ctx.shared_import_layout,
        }
    )

    sourceResult.stage1_cmd = stage1Cmd ~= "" and stage1Cmd or "skipped"
    sourceResult.stage2_cmd = stage2Cmd
    sourceResult.stage1_exit_code = stage1Rc
    sourceResult.stage2_exit_code = stage2Rc
    sourceResult.imported_stems = importSummary and importSummary.imported or {}
    sourceResult.missing_stems = importSummary and importSummary.missing or {}
    sourceResult.imported_items = importSummary and importSummary.importedItems or {}
    sourceResult.imported_paths = importSummary and importSummary.importedPaths or {}
    sourceResult.inserted_track_count = tonumber(importSummary and importSummary.insertedTrackCount or 0) or 0
    sourceResult.import_summary = tostring(importSummary and importSummary.message or "")
    sourceResult.elapsed_seconds = nowSeconds() - sourceT0
    sourceResult.parent_model = parentModel
    sourceResult.ok = ok and true or false
    if not sourceResult.ok then
        sourceResult.error_stage = "import"
        sourceResult.error_message = "Import failed."
        sourceResult.log_path = stage2Stderr
        emitFailure("import", sourceResult.error_message, stage2Stderr)
    else
        emitSourceEvent("import_done", {
            stage = "import",
            status = "done",
            imported_stems = sourceResult.imported_stems,
            missing_stems = sourceResult.missing_stems,
            imported_count = #(sourceResult.imported_stems or {}),
        })
    end
    return sourceResult
end

runDrumSepWorkflowPrototypeBlocking = function(modeOverride, opts)
    opts = opts or {}
    local selectedItemOverride = opts.selectedItem
    local suppressSuccessMessage = opts.suppressSuccessMessage == true
    local suppressFailureMessage = opts.suppressFailureMessage == true
    local onEvent = type(opts.onEvent) == "function" and opts.onEvent or nil

    local t0 = nowSeconds()
    local startedAtEpoch = os.time()
    local selectedCount = reaper.CountSelectedMediaItems(0)
    local result = {
        ok = false,
        mode = nil,
        selected_item_count = selectedCount,
        resolved_source_count = 0,
        source_resolution_mode = "",
        temp_root = nil,
        source_path = nil,
        stage0_input_path = nil,
        stage1_output_dir = nil,
        stage2_output_dir = nil,
        direct_drumsep_output_dir = nil,
        stage1_cmd = nil,
        stage2_cmd = nil,
        stage1_exit_code = nil,
        stage2_exit_code = nil,
        imported_stems = {},
        missing_stems = {},
        import_summary = "",
        elapsed_seconds = nil,
        error_stage = nil,
        error_message = nil,
        log_path = nil,
        per_source_results = {},
    }

    local scriptDir = getScriptDir()
    if not scriptDir then
        result.error_stage = "startup"
        result.error_message = "Could not resolve script directory."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end
    local separatorScript = pathJoin(scriptDir, "audio_separator_process.py")
    if not fileExists(separatorScript) then
        result.error_stage = "startup"
        result.error_message = "audio_separator_process.py not found next to script."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end

    local mode = tostring(modeOverride or DRUMSEP_WORKFLOW_MODE or "clean_fast")
    if mode ~= "clean_fast" and mode ~= "clean_quality" and mode ~= "clean_6stem" and mode ~= "direct_creative" then
        logKV("warning", "Unknown DRUMSEP_WORKFLOW_MODE=" .. mode .. ", falling back to clean_fast")
        mode = "clean_fast"
    end

    local resolvedSources, resolveErr = resolveWorkflowSources({ selectedItem = selectedItemOverride })
    if not resolvedSources or #resolvedSources == 0 then
        result.error_stage = "selection"
        result.error_message = resolveErr or "No valid sources resolved."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end

    local outputGrouping = tostring(reaper.GetExtState("STEMwerk", "outputGrouping") or "")
    if outputGrouping == "" then outputGrouping = "per_item" end
    local createFolderState = tostring(reaper.GetExtState("STEMwerk", "createFolder") or "")
    local useFolder = (createFolderState == "") and true or (createFolderState == "1")

    local ts = os.date("%Y%m%d-%H%M%S")
    local root = tostring(opts[ASYNC_TEMP_ROOT_KEY] or ("/tmp/stemwerk-drumsep-workflow-prototype-" .. ts))
    makeDir(root)
    local eventsPath = pathJoin(root, "drumkit_events.jsonl")
    result.mode = mode
    result.temp_root = root
    result.events_path = eventsPath
    result.source_path = resolvedSources[1].source_path
    result.resolved_source_count = #resolvedSources
    result.source_resolution_mode = resolvedSources[1].source_kind

    local function emitEvent(fields)
        fields = fields or {}
        if not fields.event or fields.event == "" then return end
        fields.ts = fields.ts or formatUtcIso(os.time())
        fields.elapsed_seconds = tonumber(fields.elapsed_seconds or (nowSeconds() - t0)) or 0
        fields.feature = fields.feature or "Drum Kit Split"
        fields.prototype = true
        fields.workflow_mode = fields.workflow_mode or mode
        fields.mode_label = fields.mode_label or folderModeLabel(mode, CLEAN_PARENT_MODELS[mode])
        fields.temp_root = fields.temp_root or root
        local okWrite, errWrite = appendTextFile(eventsPath, jsonEncode(fields) .. "\n")
        if not okWrite then
            logKV("event_write_error", tostring(errWrite or "write_failed"))
        end
        if onEvent then
            local okCb, errCb = pcall(onEvent, fields)
            if not okCb then
                logKV("event_callback_error", tostring(errCb or "callback_failed"))
            end
        end
    end

    logKV("workflow_mode", mode)
    if mode == "direct_creative" then
        logKV("direct_creative_status", "experimental_parked_due_bleed")
    end
    logKV("selected_item_count", selectedCount)
    logKV("resolved_source_count", #resolvedSources)
    logKV("source_resolution_mode", resolvedSources[1].source_kind or "")
    if resolvedSources[1].selection_precedence_note then
        logKV("selection_precedence", resolvedSources[1].selection_precedence_note)
    end
    logKV("grouping_mode", outputGrouping)
    logKV("folder_mode", useFolder and "folder_on" or "folder_off")
    logKV("temp_root", root)
    logKV("events_path", eventsPath)

    emitEvent({
        event = "run_start",
        status = "start",
        parent_model = CLEAN_PARENT_MODELS[mode] or "",
        drumsep_model = STAGE2_MODEL,
        grouping_mode = outputGrouping,
        folder_mode = useFolder and "folder_on" or "folder_off",
        source_resolution_mode = tostring(resolvedSources[1] and resolvedSources[1].source_kind or ""),
        selection_precedence = tostring(resolvedSources[1] and resolvedSources[1].selection_precedence_note or ""),
        selected_item_count = selectedCount,
        resolved_sources = #resolvedSources,
        source_count = #resolvedSources,
    })

    local py = resolvePython()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local perSource = {}
    local totalImported = 0
    local anyFailure = false
    local firstFailure = nil
    local aggregatedImported = {}
    local aggregatedMissing = {}
    local importedSet = {}
    local missingSet = {}
    local insertCursorByTrack = {}
    local perTrackImportLayouts = {}
    local importedItemsAll = {}
    local importedPathsAll = {}
    local metadataPath = pathJoin(root, "drumkit_run_metadata.json")

    local function persistRunMetadata(status)
        local finishedAtEpoch = os.time()
        local sourcesMetadata = {}
        for idx, sourceEntry in ipairs(resolvedSources or {}) do
            local srcRes = perSource[idx] or {}
            sourcesMetadata[#sourcesMetadata + 1] = {
                index = idx,
                track_label = sanitizeTrackLabel(sourceEntry.track_name or "", sourceEntry.track_index or idx),
                source_label = sanitizeSourceLabel(sourceEntry.source_label or "", sourceIndexLabel(idx)),
                source_kind = tostring(sourceEntry.source_kind or ""),
                source_path = tostring(sourceEntry.source_path or ""),
                segment_start = tonumber(sourceEntry.segment_start or 0) or 0,
                segment_length = tonumber(sourceEntry.segment_length or 0) or 0,
                extract_offset = tonumber(sourceEntry.extract_offset or 0) or 0,
                extract_duration = tonumber(sourceEntry.extract_duration or 0) or 0,
                take_playrate = tonumber(sourceEntry.take_playrate or 1.0) or 1.0,
                take_pitch = tonumber(sourceEntry.take_pitch or 0.0) or 0.0,
                take_preserve_pitch = (tonumber(sourceEntry.take_preserve_pitch or 0) or 0) ~= 0,
                stage0_dir = srcRes.stage0_input_path and pathJoin(srcRes.temp_root or "", "stage0_input") or "",
                stage1_dir = tostring(srcRes.stage1_output_dir or ""),
                stage2_dir = tostring(srcRes.stage2_output_dir or ""),
                imported_stems = srcRes.imported_stems or {},
                missing_stems = srcRes.missing_stems or {},
                ok = srcRes.ok == true,
                error_stage = srcRes.error_stage or "",
                error_message = srcRes.error_message or "",
                log_path = srcRes.log_path or "",
                elapsed_seconds = tonumber(srcRes.elapsed_seconds or 0) or 0,
            }
        end

        local metadata = {
            feature = "Drum Kit Split",
            prototype = true,
            temp_root = root,
            event_log_path = eventsPath,
            status = tostring(status or ""),
            mode_label = folderModeLabel(mode, CLEAN_PARENT_MODELS[mode]),
            workflow_mode = mode,
            parent_model = CLEAN_PARENT_MODELS[mode] or "",
            drumsep_model = STAGE2_MODEL,
            source_resolution_mode = tostring(resolvedSources[1] and resolvedSources[1].source_kind or ""),
            selection_precedence = tostring(resolvedSources[1] and resolvedSources[1].selection_precedence_note or ""),
            grouping_mode = outputGrouping,
            folder_mode = useFolder and "folder_on" or "folder_off",
            selected_item_count = selectedCount,
            resolved_sources = #resolvedSources,
            total_imported_stems = totalImported,
            started_at = formatUtcIso(startedAtEpoch),
            finished_at = formatUtcIso(finishedAtEpoch),
            elapsed_seconds = tonumber(nowSeconds() - t0) or 0,
            sources = sourcesMetadata,
        }

        local okWrite, errWrite = writeTextFile(metadataPath, jsonEncode(metadata) .. "\n")
        if okWrite then
            result.run_metadata_path = metadataPath
            logKV("run_metadata_path", metadataPath)
        else
            logKV("run_metadata_error", tostring(errWrite or "write_failed"))
        end
    end

    for idx, sourceEntry in ipairs(resolvedSources) do
        local insertAtIndex = nil
        if sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
            local trackKey = tostring(sourceEntry.track)
            if insertCursorByTrack[trackKey] == nil then
                local currentTrackNumber = math.floor(reaper.GetMediaTrackInfo_Value(sourceEntry.track, "IP_TRACKNUMBER") or 0)
                -- InsertTrackAtIndex() expects 0-based index; inserting at current track number
                -- places the new tracks directly under the source track.
                insertCursorByTrack[trackKey] = math.max(0, currentTrackNumber)
            end
            insertAtIndex = insertCursorByTrack[trackKey]
        end

        local sharedImportLayout = nil
        if outputGrouping == "source_track" and sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
            local trackKey = tostring(sourceEntry.track)
            sharedImportLayout = perTrackImportLayouts[trackKey]
            if not sharedImportLayout then
                local modeLabel = folderModeLabel(mode, CLEAN_PARENT_MODELS[mode] or nil)
                local trackLabel = sanitizeTrackLabel(sourceEntry.track_name or "", sourceEntry.track_index or 1)
                sharedImportLayout = {
                    grouping_mode = "source_track",
                    folder_label = string.format("%s - Drum Kit Split - %s", trackLabel, modeLabel),
                }
                perTrackImportLayouts[trackKey] = sharedImportLayout
            end
        end

        logKV("source_" .. idx .. "_track", tostring(sourceEntry.track_name))
        logKV("source_" .. idx .. "_path", tostring(sourceEntry.source_path))
        logKV("source_" .. idx .. "_segment_start", string.format("%.6f", sourceEntry.segment_start))
        logKV("source_" .. idx .. "_segment_length", string.format("%.6f", sourceEntry.segment_length))
        if insertAtIndex ~= nil then
            logKV("source_" .. idx .. "_insert_at_index", insertAtIndex)
        end
        emitEvent({
            event = "source_start",
            status = "start",
            source_index = idx,
            source_count = #resolvedSources,
            track_label = sanitizeTrackLabel(sourceEntry.track_name or "", sourceEntry.track_index or idx),
            source_label = sanitizeSourceLabel(sourceEntry.source_label or "", sourceIndexLabel(idx)),
            source_kind = tostring(sourceEntry.source_kind or ""),
            segment_start = tonumber(sourceEntry.segment_start or 0) or 0,
            segment_length = tonumber(sourceEntry.segment_length or 0) or 0,
            extract_offset = tonumber(sourceEntry.extract_offset or 0) or 0,
            extract_duration = tonumber(sourceEntry.extract_duration or 0) or 0,
            take_playrate = tonumber(sourceEntry.take_playrate or 1.0) or 1.0,
            take_pitch = tonumber(sourceEntry.take_pitch or 0.0) or 0.0,
            take_preserve_pitch = (tonumber(sourceEntry.take_preserve_pitch or 0) or 0) ~= 0,
        })
        local srcRes = runPipelineForSource(mode, sourceEntry, {
            batch_root = root,
            source_index = idx,
            source_count = #resolvedSources,
            python_bin = py,
            separator_script = separatorScript,
            use_folder = useFolder,
            insert_at_index = insertAtIndex,
            grouping_mode = outputGrouping,
            shared_import_layout = sharedImportLayout,
            emit_event = emitEvent,
        })
        perSource[#perSource + 1] = srcRes

        if sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
            local trackKey = tostring(sourceEntry.track)
            local added = tonumber((srcRes and srcRes.inserted_track_count) or 0) or 0
            if insertCursorByTrack[trackKey] ~= nil and added > 0 then
                insertCursorByTrack[trackKey] = insertCursorByTrack[trackKey] + added
            end
        end

        if srcRes.ok then
            totalImported = totalImported + #(srcRes.imported_stems or {})
            for _, it in ipairs(srcRes.imported_items or {}) do
                importedItemsAll[#importedItemsAll + 1] = it
            end
            for _, p in ipairs(srcRes.imported_paths or {}) do
                importedPathsAll[#importedPathsAll + 1] = p
            end
            for _, stemName in ipairs(srcRes.imported_stems or {}) do
                if not importedSet[stemName] then
                    importedSet[stemName] = true
                    aggregatedImported[#aggregatedImported + 1] = stemName
                end
            end
            for _, stemName in ipairs(srcRes.missing_stems or {}) do
                if not missingSet[stemName] then
                    missingSet[stemName] = true
                    aggregatedMissing[#aggregatedMissing + 1] = stemName
                end
            end
        else
            anyFailure = true
            firstFailure = firstFailure or srcRes
            logKV("source_" .. idx .. "_error_stage", tostring(srcRes.error_stage or ""))
            logKV("source_" .. idx .. "_error_message", tostring(srcRes.error_message or ""))
            logKV("source_" .. idx .. "_log_path", tostring(srcRes.log_path or ""))
        end
        emitEvent({
            event = "source_done",
            status = srcRes.ok and "success" or "failed",
            source_index = idx,
            source_count = #resolvedSources,
            track_label = sanitizeTrackLabel(sourceEntry.track_name or "", sourceEntry.track_index or idx),
            source_label = sanitizeSourceLabel(sourceEntry.source_label or "", sourceIndexLabel(idx)),
            imported_stems = srcRes.imported_stems or {},
            missing_stems = srcRes.missing_stems or {},
            imported_count = #(srcRes.imported_stems or {}),
            error_stage = srcRes.error_stage or "",
            error_message = srcRes.error_message or "",
            log_path = srcRes.log_path or "",
            source_elapsed_seconds = tonumber(srcRes.elapsed_seconds or 0) or 0,
        })
    end

    if #importedItemsAll > 0 then
        refreshImportedMediaItems(importedItemsAll, importedPathsAll)
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: DrumSep workflow prototype", -1)

    local elapsed = nowSeconds() - t0
    result.per_source_results = perSource
    result.imported_stems = aggregatedImported
    result.missing_stems = aggregatedMissing
    result.elapsed_seconds = elapsed
    result.stage0_input_path = perSource[1] and perSource[1].stage0_input_path or nil
    result.stage1_output_dir = perSource[1] and perSource[1].stage1_output_dir or nil
    result.stage2_output_dir = perSource[1] and perSource[1].stage2_output_dir or nil
    result.direct_drumsep_output_dir = perSource[1] and perSource[1].direct_drumsep_output_dir or nil
    result.stage1_cmd = perSource[1] and perSource[1].stage1_cmd or nil
    result.stage2_cmd = perSource[1] and perSource[1].stage2_cmd or nil
    result.stage1_exit_code = perSource[1] and perSource[1].stage1_exit_code or nil
    result.stage2_exit_code = perSource[1] and perSource[1].stage2_exit_code or nil

    logKV("resolved_sources", #resolvedSources)
    logKV("total_imported_stems", totalImported)
    logKV("elapsed_seconds", string.format("%.3f", elapsed))

    if totalImported <= 0 then
        result.error_stage = firstFailure and firstFailure.error_stage or "pipeline"
        result.error_message = firstFailure and firstFailure.error_message or "No stems imported."
        result.log_path = firstFailure and firstFailure.log_path or nil
        persistRunMetadata("failed")
        emitEvent({
            event = "failure",
            status = "failed",
            stage = tostring(result.error_stage or "pipeline"),
            error_message = tostring(result.error_message or ""),
            log_path = tostring(result.log_path or ""),
            resolved_sources = #resolvedSources,
            total_imported_stems = totalImported,
            elapsed_seconds = elapsed,
        })
        emitEvent({
            event = "run_done",
            status = "failed",
            resolved_sources = #resolvedSources,
            total_imported_stems = totalImported,
            elapsed_seconds = elapsed,
        })
        _showMessage(
            "DrumSep workflow prototype failed.\n\n" ..
            tostring(result.error_message or "No stems imported.") ..
            (result.log_path and ("\n\nLog:\n" .. tostring(result.log_path)) or ""),
            suppressFailureMessage
        )
        return result
    end

    if anyFailure then
        result.error_stage = "partial_failure"
        result.error_message = "Partial success: one or more sources failed."
        result.log_path = firstFailure and firstFailure.log_path or nil
        result.import_summary = "Partial success"
        persistRunMetadata("partial_success")
        emitEvent({
            event = "run_done",
            status = "partial_success",
            resolved_sources = #resolvedSources,
            total_imported_stems = totalImported,
            elapsed_seconds = elapsed,
            error_message = tostring(result.error_message or ""),
            log_path = tostring(result.log_path or ""),
        })
        _showMessage(
            "DrumSep workflow prototype partial success.\n\nMode: " .. mode ..
            "\nResolved sources: " .. tostring(#resolvedSources) ..
            "\nImported stems total: " .. tostring(totalImported) ..
            "\nFailures: yes" ..
            "\nTemp root:\n" .. root,
            suppressFailureMessage
        )
        return result
    end

    result.ok = true
    result.import_summary = "All sources completed."
    persistRunMetadata("success")
    emitEvent({
        event = "run_done",
        status = "success",
        resolved_sources = #resolvedSources,
        total_imported_stems = totalImported,
        elapsed_seconds = elapsed,
    })
    _showMessage(
        "DrumSep workflow prototype complete.\n\nMode: " .. mode ..
        "\nResolved sources: " .. tostring(#resolvedSources) ..
        "\nImported stems total: " .. tostring(totalImported) ..
        "\nTemp root:\n" .. root,
        suppressSuccessMessage
    )
    return result
end

local function runDrumSepWorkflowPrototype(modeOverride, opts)
    opts = opts or {}
    if opts.async_enabled == true then
        local asyncOpts = {}
        for k, v in pairs(opts) do
            asyncOpts[k] = v
        end
        asyncOpts.async_enabled = nil
        return runDrumSepWorkflowPrototypeAsync(modeOverride, asyncOpts)
    end
    return runDrumSepWorkflowPrototypeBlocking(modeOverride, opts)
end

local function main()
    runDrumSepWorkflowPrototype(nil, nil)
end

local API = {
    runDrumSepWorkflowPrototype = runDrumSepWorkflowPrototype,
}

if not rawget(_G, "STEMWERK_DRUMSEP_WORKFLOW_NO_AUTORUN") then
    main()
end

return API
