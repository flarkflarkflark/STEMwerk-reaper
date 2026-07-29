local C = {}

local PROGRESS_IDLE_STALE_SECONDS = 5400 -- 90 minutes without any detectable activity

-- Helper: append a line to workflow_diag.log in outputDir with timestamp and job id
local function append_diag_log(msg)
    local dir = C.progressState and C.progressState.outputDir or nil
    if not dir or dir == "" then return end
    local path = dir .. PATH_SEP .. "workflow_diag.log"
    local job = (C.progressState and C.progressState.jobTag) or (C.jobTag) or ""
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] %s%s%s", ts, msg, job ~= "" and " job=" or "", job ~= "" and job or "")
    local f = io.open(path, "a")
    if f then f:write(line .. "\n"); f:close() end
end
-- STEMwerk_Workflow.lua
-- WORKFLOW module: separation process management, progress loop, in-place replace.
-- Loaded via dofile() from STEMwerk.lua; populates the global WORKFLOW table.
-- Globals (STEMS, SETTINGS, OS, PATH_SEP, PYTHON_PATH, SEPARATOR_SCRIPT, SW_LOG,
--   HELPERS, WINDOW_PROCESSING, UI_PACING, FFMPEG_PATH, isProcessingActive, uiNow,
--   pacingFrameInterval, processStemsResult, canRunFfmpeg, checkNumpyCompat,
--   refreshPythonPathFromExtState, getTrustedWindowsRuntimeState,
--   applyTrustedWindowsRuntimeState, normalizeRequestedDeviceForRuntime,
--   ensureProcessingWindowOpen, showProcessingPlaceholderWindow, closeProcessingWindow,
--   getItemDisplayNameForTakes, reaper, gfx, io, os, string, math) are accessed directly.
-- Locals from STEMwerk.lua are injected via WORKFLOW.configure(ctx).

WORKFLOW = WORKFLOW or {}

local C = {}

local function getFileSizeSafe(path)
    if not path or path == "" then return -1 end
    local f = io.open(path, "rb")
    if not f then return -1 end
    local sz = f:seek("end")
    f:close()
    return tonumber(sz) or -1
end

local function touchProgressActivity(reason)
    C.progressState.lastActivityAt = os.time()
    if reason and reason ~= "" then
        C.progressState.lastActivityReason = reason
    end
end

local function recordTimingEvent(eventName, fields)
    if C.recordTimingEvent and C.progressState and C.progressState.outputDir then
        C.recordTimingEvent(C.progressState.outputDir, eventName, "single", fields)
    end
end

local function normalizeStemOutputKey(rawKey)
    local key = tostring(rawKey or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if key == "" then return "" end
    key = key:gsub("_", "-")
    if key == "hihat" or key == "hihat" or key == "hh" then
        return "hi-hat"
    end
    return key
end

local function collectStemPathsFromStdoutJson(stdoutFile)
    if not stdoutFile or stdoutFile == "" then return {} end
    local f = io.open(stdoutFile, "r")
    if not f then return {} end
    local text = f:read("*a") or ""
    f:close()
    if text == "" then return {} end

    local lastJsonLine = nil
    for line in tostring(text):gmatch("[^\r\n]+") do
        local trimmed = tostring(line or ""):match("^%s*(.-)%s*$") or ""
        if trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" and trimmed:find('"%s*:%s*"', 1) then
            lastJsonLine = trimmed
        end
    end
    if not lastJsonLine then return {} end

    local stems = {}
    for rawKey, rawPath in lastJsonLine:gmatch('"([^"]+)"%s*:%s*"(.-)"') do
        local key = normalizeStemOutputKey(rawKey)
        local path = tostring(rawPath or ""):gsub('\\"', '"'):gsub("\\\\", "\\")
        if key ~= "" and path ~= "" then
            local probe = io.open(path, "rb")
            if probe then
                probe:close()
                stems[key] = path
            end
        end
    end
    return stems
end

local function buildTakeImportStemEntries(stemPaths)
    local sourcePaths = stemPaths or {}
    local stemSet = STEMS
    if type(C.resolveStemSetForPaths) == "function" then
        local resolved = C.resolveStemSetForPaths(sourcePaths)
        if type(resolved) == "table" then
            stemSet = resolved
        end
    end
    local entries = {}
    for _, stem in ipairs(stemSet or {}) do
        if stem.selected then
            local key = normalizeStemOutputKey(stem.name)
            local stemPath = sourcePaths[key] or sourcePaths[tostring(stem.name or ""):lower()]
            if stemPath then
                entries[#entries + 1] = { stem = stem, path = stemPath }
            end
        end
    end
    return entries
end

local function markSingleProgressMilestones(pct, stage)
    if not SW_TIMING then
        return
    end
    pct = tonumber(pct) or 0
    local td = C.progressState.timingDone or {}

    if pct > 0 and not td.first_progress then
        td.first_progress = true
        SW_TIMING.mark("single", "first_progress")
        recordTimingEvent("first_progress_seen", { percent = pct, stage = stage })
    end
    if pct >= 50 and not td.p50 then
        td.p50 = true
        SW_TIMING.mark("single", "progress_50")
        recordTimingEvent("progress_50_seen", { percent = pct, stage = stage })
    end
    if pct >= 87 and not td.p87 then
        td.p87 = true
        recordTimingEvent("progress_87_or_88_seen", { percent = pct, stage = stage })
    end
    if pct >= 90 and not td.p90 then
        td.p90 = true
        SW_TIMING.mark("single", "progress_90")
        recordTimingEvent("progress_90_or_92_seen", { percent = pct, stage = stage })
    end

    C.progressState.timingDone = td
end

local function refreshProgressActivityFromFiles()
    local now = os.time()
    local changed = false

    local stdoutSize = getFileSizeSafe(C.progressState.stdoutFile)
    if stdoutSize ~= (C.progressState.lastStdoutSize or -1) then
        C.progressState.lastStdoutSize = stdoutSize
        C.progressState.lastStdoutChangeAt = now
        changed = true
    end

    local logSize = getFileSizeSafe(C.progressState.logFile)
    if logSize ~= (C.progressState.lastLogSize or -1) then
        C.progressState.lastLogSize = logSize
        C.progressState.lastLogChangeAt = now
        changed = true
    end

    local donePath = (C.progressState.outputDir and C.progressState.outputDir ~= "")
        and (C.progressState.outputDir .. PATH_SEP .. "done.txt")
        or nil
    local doneSize = getFileSizeSafe(donePath)
    if doneSize ~= (C.progressState.lastDoneSize or -1) then
        C.progressState.lastDoneSize = doneSize
        C.progressState.lastDoneChangeAt = now
        changed = true
    end

    if changed then
        touchProgressActivity("file_update")
    end
end

function WORKFLOW.configure(ctx)
    for k, v in pairs(ctx) do C[k] = v end
end

local function isDirectDrumKitRoute(runOptions)
    local workflowMode = tostring((runOptions and runOptions.workflowMode) or "")
    return workflowMode == "drumkit"
end

local function collectRuntimeDeviceIds()
    local ids = {}
    for _, dev in ipairs(RUNTIME_DEVICES or {}) do
        ids[#ids + 1] = tostring(dev and dev.id or "")
    end
    return ids
end

local function runtimeHasGpuDevice()
    for _, dev in ipairs(RUNTIME_DEVICES or {}) do
        local id = tostring(dev and dev.id or "")
        local typ = tostring(dev and dev.type or "")
        if typ == "cuda" or typ == "directml" or typ == "mps"
            or id:match("^cuda:%d+$") or id:match("^directml:%d+$") or id == "cuda" or id == "directml" or id == "mps" then
            return true
        end
    end
    return false
end

local function preflightNormalWorkflowDeviceRoute(runOptions)
    if isDirectDrumKitRoute(runOptions) then
        return true
    end

    local requestedUiDevice = (type(C.effectiveRunDevice) == "function" and C.effectiveRunDevice()) or SETTINGS.device or "auto"
    local workflowMode = tostring((runOptions and runOptions.workflowMode) or "")
    local workflowSource = tostring((runOptions and runOptions.workflowSource) or "")
    debugLog("workflow_mode=" .. workflowMode)
    debugLog("workflow_source=" .. workflowSource)
    debugLog("normal_workflow_device_ui=" .. tostring(SETTINGS.device or ""))
    debugLog("normal_workflow_device_snapshot=" .. tostring(requestedUiDevice))

    if type(C.refreshRuntimeDevices) == "function" then
        C.refreshRuntimeDevices(true)
    end

    local liveIds = collectRuntimeDeviceIds()
    local liveIdsText = table.concat(liveIds, ",")
    local gpuAvailable = runtimeHasGpuDevice()
    debugLog("normal_workflow_live_device_ids=" .. liveIdsText)
    debugLog("normal_workflow_live_gpu_available=" .. (gpuAvailable and "yes" or "no"))

    local normalizedRequest = string.lower(tostring(requestedUiDevice or "auto"))
    -- Only explicit GPU requests are blocked on a CPU-only runtime; "auto" is
    -- allowed because it resolves to the best available device (GPU or CPU).
    if normalizedRequest ~= "" and normalizedRequest ~= "cpu" and normalizedRequest ~= "auto" and not gpuAvailable then
        debugLog("normal_workflow_fallback_reason=live_runtime_cpu_only")
        local msg =
            "Normal STEMwerk processing was stopped because the live normal runtime reports CPU-only devices.\n\n"
            .. "Requested device: " .. tostring(requestedUiDevice) .. "\n"
            .. "Live runtime devices: " .. (liveIdsText ~= "" and liveIdsText or "auto,cpu") .. "\n\n"
            .. "This prevents a silent fallback to CPU.\n\n"
            .. "Direct Drum Kit uses a separate Drum Kit runtime and can still show GPU devices independently.\n\n"
            .. "If you want GPU processing for normal STEMwerk, run STEMwerk-SETUP and repair/rebuild the normal runtime."
        C.showMessage("Runtime Device Unavailable", msg, "error", false)
        return false
    end

    return true
end

local function snapshotActiveTakePlaybackState(item)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then
        return nil
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then
        return nil
    end

    local playrate = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")) or 1.0
    if playrate < 0.0001 then
        playrate = 1.0
    end

    local pitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")) or 0.0
    local preservePitch = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")) or 0
    if preservePitch ~= 0 then preservePitch = 1 else preservePitch = 0 end

    return {
        playrate = playrate,
        pitch = pitch,
        preservePitch = preservePitch
    }
end

local function applyPlaybackStateToTake(take, playbackState)
    if not take or not reaper.ValidatePtr(take, "MediaItem_Take*") then
        return
    end
    if not playbackState then
        return
    end

    local source = reaper.GetMediaItemTake_Source(take)
    local sourceLen = nil
    if source and reaper.GetMediaSourceLength then
        local len, lengthIsQN = reaper.GetMediaSourceLength(source)
        if not lengthIsQN then
            sourceLen = tonumber(len)
        end
    end

    local itemLen = nil
    local item = reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(take) or nil
    if item and reaper.ValidatePtr(item, "MediaItem*") then
        itemLen = tonumber(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
    end

    -- Imported stem WAVs are usually already baked in project-time.
    -- Only transfer playback-state when source duration matches the expected
    -- pre-baked length (itemLen * playrate), otherwise we would double-stretch.
    if sourceLen and itemLen and itemLen > 0 then
        local expected = itemLen * (playbackState.playrate or 1.0)
        local tolerance = math.max(0.01, expected * 0.01)
        if math.abs(sourceLen - expected) > tolerance then
            return
        end
    end

    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", playbackState.playrate or 1.0)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", playbackState.pitch or 0.0)
    reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", playbackState.preservePitch or 0)
end

function WORKFLOW.updateProgressFromFile()
    if not C.progressState.stdoutFile or C.progressState.stdoutFile == "" then return end
    local f = io.open(C.progressState.stdoutFile, "r")
    if not f then return end

    local lastProgress = nil
    for line in f:lines() do
        local percent, stage = line:match("PROGRESS:(%d+):(.+)")
        if percent then
            local pct = tonumber(percent) or 0
            lastProgress = { percent = pct, stage = stage }
            -- Record milestones at the first observed threshold crossing, using
            -- the actual line values (e.g. 92/Writing stems) instead of a later 100/Complete fallback.
            markSingleProgressMilestones(pct, stage)
        end
    end
    f:close()

    if lastProgress then
        local prevPercent = tonumber(C.progressState.percent) or 0
        local prevStage = tostring(C.progressState.stage or "")
        C.progressState.percent = lastProgress.percent
        C.progressState.stage = lastProgress.stage
        if lastProgress.percent ~= prevPercent or tostring(lastProgress.stage or "") ~= prevStage then
            touchProgressActivity("progress_update")
        end
    end
end

-- Check if separation process is done (check for done.txt marker file)
function WORKFLOW.checkSeparationDone()
    if not C.progressState.outputDir or C.progressState.outputDir == "" then
        return false
    end
    -- Check for done marker file
    local doneFile = io.open(C.progressState.outputDir .. PATH_SEP .. "done.txt", "r")
    if doneFile then
        doneFile:close()
        return true
    end
    -- Progress can reach 100 before launcher-owned terminal files are flushed.
    -- Treat as done only when exit_code.txt exists as a terminal marker.
    if (tonumber(C.progressState.percent) or 0) >= 100 then
        local exitFile = io.open(C.progressState.outputDir .. PATH_SEP .. "exit_code.txt", "r")
        if exitFile then
            exitFile:close()
            return true
        end
    end
    return false
end

-- Start separation process in background (Windows)
function WORKFLOW.startSeparationProcess(inputFile, outputDir, model, runOptions)
        append_diag_log("[workflow] start")
        append_diag_log("[workflow] outputDir=" .. tostring(outputDir))
        append_diag_log("[workflow] stdoutFile=" .. tostring(outputDir .. PATH_SEP .. "stdout.txt"))
        append_diag_log("[workflow] separationLogFile=" .. tostring(outputDir .. PATH_SEP .. "separation_log.txt"))
    C.refreshPythonPathFromExtState()
    local trustedWindowsRuntime = nil
    if OS == "Windows" then
        trustedWindowsRuntime = getTrustedWindowsRuntimeState()
        applyTrustedWindowsRuntimeState(trustedWindowsRuntime)
    end
    local logFile = outputDir .. PATH_SEP .. "separation_log.txt"
    local stdoutFile = outputDir .. PATH_SEP .. "stdout.txt"
    local doneFile = outputDir .. PATH_SEP .. "done.txt"
    local pidFile = outputDir .. PATH_SEP .. "pid.txt"
    local exitCodeFile = outputDir .. PATH_SEP .. "exit_code.txt"

    debugLog("startSeparationProcess")
    debugLog("  inputFile=" .. tostring(inputFile))
    debugLog("  outputDir=" .. tostring(outputDir))
    debugLog("  model=" .. tostring(model))
    debugLog("  python=" .. tostring(PYTHON_PATH))
    debugLog("  separator=" .. tostring(SEPARATOR_SCRIPT))
    debugLog("  [LOG] outputDir=" .. tostring(outputDir))
    debugLog("  [LOG] stdoutFile=" .. tostring(stdoutFile))
    debugLog("  [LOG] separationLogFile=" .. tostring(logFile))

    -- Store for progress tracking
    C.progressState.outputDir = outputDir
    C.progressState.stdoutFile = stdoutFile
    C.progressState.logFile = logFile
    C.progressState.pidFile = pidFile
    C.progressState.exitCodeFile = exitCodeFile
    C.progressState.percent = 0
    C.progressState.stage = C.T("progress_starting_backend") or "Starting backend..."
    C.progressState.startTime = os.time()
    C.progressState._deviceId = nil
    C.progressState._deviceName = nil
    C.progressState._runtimeSelected = nil
    C.progressState._normalizedDeviceRequest = nil
    C.progressState._runtimeGpuCapable = nil
    C.progressState._runtimeDeviceNames = nil
    C.progressState._stage1Runtime = nil
    C.progressState._stage1Device = nil
    C.progressState._stage2Runtime = nil
    C.progressState._stage2Device = nil
    C.progressState._deviceInfoLastAt = nil
    C.progressState.lastActivityAt = C.progressState.startTime
    C.progressState.lastActivityReason = "process_start"
    C.progressState.lastStdoutSize = getFileSizeSafe(stdoutFile)
    C.progressState.lastLogSize = getFileSizeSafe(logFile)
    C.progressState.lastDoneSize = getFileSizeSafe(doneFile)
    C.progressState.lastStdoutChangeAt = C.progressState.startTime
    C.progressState.lastLogChangeAt = C.progressState.startTime
    C.progressState.lastDoneChangeAt = C.progressState.startTime
    C.progressState.cancelRequested = false
    C.progressState.timingDone = {}
    if SW_TIMING then SW_TIMING.mark("single", "process_launch") end
    C.progressState.execLogPath = SW_LOG.getLogPath()
    local execLogPath = C.progressState.execLogPath or SW_LOG.getLogPath()
    local jobTag = "single"

    -- Preflight checks so failures show up clearly in logs/UI.
    local function fileExistsLocal(p)
        if not p then return false end
        local f = io.open(p, "r")
        if f then f:close(); return true end
        return false
    end
    local function fileSizeBytes(p)
        if not p then return -1 end
        local f = io.open(p, "rb")
        if not f then return -1 end
        local sz = f:seek("end")
        f:close()
        return tonumber(sz) or -1
    end

    if not fileExistsLocal(inputFile) then
        local msg = "Input file missing: " .. tostring(inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: missing input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then lf:write(msg .. "\n"); lf:close() end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end
    local inSz = fileSizeBytes(inputFile)
    if not inSz or inSz <= 1024 then
        local msg = "Input WAV is empty (0 samples): " .. tostring(inputFile)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: empty input", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then
            lf:write(msg .. "\n")
            lf:write("Hint: make a longer time selection / ensure selection overlaps items.\n")
            lf:close()
        end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end
    if not trustedWindowsRuntime then
        local pythonAvailable = false
        if C.isAbsolutePath(PYTHON_PATH) then
            pythonAvailable = fileExistsLocal(PYTHON_PATH)
        else
            pythonAvailable = C.canRunPython(PYTHON_PATH)
        end

        if not pythonAvailable then
            local msg =
                "Python not found at: " .. tostring(PYTHON_PATH) .. "\n\n"
                .. "Run STEMwerk-SETUP.lua to repair the runtime."
            debugLog(msg)
            SW_LOG.logExecResult("preflight: python missing", -1, msg)
            local lf = io.open(logFile, "w")
            if lf then lf:write(msg .. "\n"); lf:close() end
            local df = io.open(doneFile, "w")
            if df then df:write("DONE\n"); df:close() end
            SW_LOG.writeExitCode(exitCodeFile, -1)
            return
        end
        local numpyOk, numpyErr = checkNumpyCompat(PYTHON_PATH)
        if not numpyOk then
            local msg =
                "NumPy compatibility issue.\n\n"
                .. tostring(numpyErr or "Unknown error") .. "\n\n"
                .. "Fix (command):\n"
                .. "  " .. tostring(PYTHON_PATH) .. " -m pip install \"numpy<2.4\""
            debugLog(msg)
            SW_LOG.logExecResult("preflight: numpy incompatible", -1, msg)
            local lf = io.open(logFile, "w")
            if lf then lf:write(msg .. "\n"); lf:close() end
            local df = io.open(doneFile, "w")
            if df then df:write("DONE\n"); df:close() end
            SW_LOG.writeExitCode(exitCodeFile, -1)
            if reaper and reaper.ShowMessageBox then
                reaper.ShowMessageBox(msg, "Missing Dependency", 0)
            end
            return false
        end
        if not canRunFfmpeg() then
            if not C.ensureDependenciesInteractive() then
                return false
            end
        end
    end
    if not fileExistsLocal(SEPARATOR_SCRIPT) then
        local msg = "Separator script not found at: " .. tostring(SEPARATOR_SCRIPT)
        debugLog(msg)
        SW_LOG.logExecResult("preflight: separator missing", -1, msg)
        local lf = io.open(logFile, "w")
        if lf then lf:write(msg .. "\n"); lf:close() end
        local df = io.open(doneFile, "w")
        if df then df:write("DONE\n"); df:close() end
        SW_LOG.writeExitCode(exitCodeFile, -1)
        return
    end

    if OS == "Windows" then
        -- Create empty progress/log files (Python writes to these directly)
        local sf = io.open(stdoutFile, "w")
        if sf then sf:close() end
        local lf = io.open(logFile, "w")
        if lf then lf:close() end

        -- Launch Python hidden WITHOUT a .bat/.cmd (prevents console windows).
        -- Use WMI Win32_Process.Create to get a PID for proper cancel.
        local requestedDeviceArg = (type(C.effectiveRunDevice) == "function" and C.effectiveRunDevice()) or SETTINGS.device or "auto"
        local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
        local workflowModeArg = tostring((runOptions and runOptions.workflowMode) or "")
        local workflowSourceArg = tostring((runOptions and runOptions.workflowSource) or "")
        debugLog("ui_device_selected_before_run=" .. tostring(requestedDeviceArg))
        debugLog("backend_device_arg=" .. tostring(deviceArg))
        if not isDirectDrumKitRoute(runOptions) then
            debugLog("normal_workflow_command_device=" .. tostring(deviceArg))
        end
        local requestedStage2ModelArg = tostring((runOptions and runOptions.requestedStage2Model) or "")
        local pythonCmd = string.format(
            '%s -u %s %s %s --model %s --device %s',
            C.quoteArg(PYTHON_PATH),
            C.quoteArg(SEPARATOR_SCRIPT),
            C.quoteArg(inputFile),
            C.quoteArg(outputDir),
            C.quoteArg(model),
            C.quoteArg(deviceArg)
        )
        if workflowModeArg ~= "" then
            pythonCmd = pythonCmd .. " --workflow-mode " .. C.quoteArg(workflowModeArg)
        end
        if workflowSourceArg ~= "" then
            pythonCmd = pythonCmd .. " --workflow-source " .. C.quoteArg(workflowSourceArg)
        end
        if requestedStage2ModelArg ~= "" then
            pythonCmd = pythonCmd .. " --requested-stage2-model " .. C.quoteArg(requestedStage2ModelArg)
        end
        C.progressState.lastCmd = pythonCmd
        SW_LOG.logExecResult("LAUNCH: " .. pythonCmd, nil, "")
        if tostring(deviceArg) ~= tostring(requestedDeviceArg) then
            debugLog("  device=" .. tostring(requestedDeviceArg) .. " -> normalized to " .. tostring(deviceArg))
        else
            debugLog("  device=" .. tostring(deviceArg))
        end

        -- Write a tiny VBS launcher that runs PowerShell invisibly via wscript
        -- PowerShell will Start-Process the Python worker and write its PID to pidFile
        local vbsPath = outputDir .. PATH_SEP .. "run_hidden.vbs"
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            local function escPS(s)
                s = tostring(s or "")
                s = s:gsub("'", "''")
                return s
            end
            local python = escPS(PYTHON_PATH)
            local sep = escPS(SEPARATOR_SCRIPT)
            local inF = escPS(inputFile)
            local outD = escPS(outputDir)
            local m = escPS(model)
            local dev = escPS(deviceArg)
            local workflowMode = escPS(workflowModeArg)
            local workflowSource = escPS(workflowSourceArg)
            local requestedStage2Model = escPS(requestedStage2ModelArg)
            local stdoutF = escPS(stdoutFile)
            local stderrF = escPS(logFile)
            local pidF = escPS(pidFile)
            local doneF = escPS(doneFile)
            local exitF = escPS(exitCodeFile)
            local logPath = escPS(execLogPath)
            local jobTagEsc = escPS(jobTag)

            -- Build the PowerShell command that Start-Process the Python worker and writes PID
            local psInner =
                "$py='" .. python .. "';" ..
                "$sep='" .. sep .. "';" ..
                "$in='" .. inF .. "';" ..
                "$out='" .. outD .. "';" ..
                "$model='" .. m .. "';" ..
                "$dev='" .. dev .. "';" ..
                "$logPath='" .. logPath .. "';" ..
                "$jobTag='" .. jobTagEsc .. "';" ..
                "$env:STEMWERK_LOG_PATH=$logPath;" ..
                "$env:STEMWERK_JOB_TAG=$jobTag;" ..
                "Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue;" ..
                "Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue;" ..
                "$dq=[char]34;" ..
                "$sepq=$dq + $sep + $dq;" ..
                "$inq=$dq + $in + $dq;" ..
                "$outq=$dq + $out + $dq;" ..
                "$modelq=$dq + $model + $dq;" ..
                "$devq=$dq + $dev + $dq;" ..
                "$wm='" .. workflowMode .. "';" ..
                "$ws='" .. workflowSource .. "';" ..
                "$s2='" .. requestedStage2Model .. "';" ..
                "$args=@('-u',$sepq,$inq,$outq,'--model',$modelq,'--device',$devq);" ..
                "if ($wm -ne '') { $args += @('--workflow-mode',($dq + $wm + $dq)) };" ..
                "if ($ws -ne '') { $args += @('--workflow-source',($dq + $ws + $dq)) };" ..
                "if ($s2 -ne '') { $args += @('--requested-stage2-model',($dq + $s2 + $dq)) };" ..
                "$p = Start-Process -FilePath $py -ArgumentList $args -WorkingDirectory '" .. outD .. "' -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput '" .. stdoutF .. "' -RedirectStandardError '" .. stderrF .. "'; " ..
                "Set-Content -Path '" .. pidF .. "' -Value $p.Id -Encoding ascii; " ..
                "$ec=$p.ExitCode; Set-Content -Path '" .. exitF .. "' -Value $ec -Encoding ascii; " ..
                "if ($ec -eq 0) { Set-Content -Path '" .. doneF .. "' -Value 'DONE' -Encoding ascii } else { Set-Content -Path '" .. doneF .. "' -Value 'ERROR' -Encoding ascii }"

            -- VBS: create shell and run PowerShell command invisibly (0 = hidden window)
            vbsFile:write('Set sh = CreateObject("WScript.Shell")\n')
            vbsFile:write('cmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""' .. psInner .. '"""\n')
            vbsFile:write('sh.Run cmd, 0, False\n')
            vbsFile:close()
        end

        local wscriptCmd = 'wscript "' .. vbsPath .. '"'
        if reaper.ExecProcess then
            debugLog('Calling reaper.ExecProcess: ' .. wscriptCmd)
            reaper.ExecProcess(wscriptCmd, -1)
            debugLog('reaper.ExecProcess called')
        else
            debugLog('Calling io.popen for: ' .. wscriptCmd)
            local handle = io.popen(wscriptCmd)
            if handle then handle:close() end
            debugLog('io.popen returned')
        end
    else
        -- Unix: run in background so REAPER stays responsive and the progress window can update.
        -- Launch a tiny sh script that starts the Python worker in the background, writes a pid.txt,
        -- and writes done.txt only when the worker exits successfully.
        local requestedDeviceArg = tostring((type(C.effectiveRunDevice) == "function" and C.effectiveRunDevice()) or SETTINGS.device or "auto")
        local deviceArg = normalizeRequestedDeviceForRuntime(requestedDeviceArg)
        local modelArg  = tostring(model or SETTINGS.model or "htdemucs")
        local workflowModeArg = tostring((runOptions and runOptions.workflowMode) or "")
        local workflowSourceArg = tostring((runOptions and runOptions.workflowSource) or "")
        debugLog("ui_device_selected_before_run=" .. tostring(requestedDeviceArg))
        debugLog("backend_device_arg=" .. tostring(deviceArg))
        if not isDirectDrumKitRoute(runOptions) then
            debugLog("normal_workflow_command_device=" .. tostring(deviceArg))
        end
        local requestedStage2ModelArg = tostring((runOptions and runOptions.requestedStage2Model) or "")
        local pythonCmd = string.format(
            '%s -u %s %s %s --model %s --device %s',
            C.quoteArg(PYTHON_PATH),
            C.quoteArg(SEPARATOR_SCRIPT),
            C.quoteArg(inputFile),
            C.quoteArg(outputDir),
            C.quoteArg(modelArg),
            C.quoteArg(deviceArg)
        )
        if workflowModeArg ~= "" then
            pythonCmd = pythonCmd .. " --workflow-mode " .. C.quoteArg(workflowModeArg)
        end
        if workflowSourceArg ~= "" then
            pythonCmd = pythonCmd .. " --workflow-source " .. C.quoteArg(workflowSourceArg)
        end
        if requestedStage2ModelArg ~= "" then
            pythonCmd = pythonCmd .. " --requested-stage2-model " .. C.quoteArg(requestedStage2ModelArg)
        end
        C.progressState.lastCmd = pythonCmd
        SW_LOG.logExecResult("LAUNCH: " .. pythonCmd, nil, "")
        if tostring(deviceArg) ~= tostring(requestedDeviceArg) then
            debugLog("  device=" .. tostring(requestedDeviceArg) .. " -> normalized to " .. tostring(deviceArg))
        end

        -- Create empty progress/log files (Python writes to these directly)
        local sf = io.open(stdoutFile, "w")
        if sf then sf:close() end
        local lf = io.open(logFile, "w")
        if lf then lf:close() end

        local launcherPath = outputDir .. PATH_SEP .. "run_bg.sh"
        local script = io.open(launcherPath, "w")
        if script then
              script:write("#!/bin/sh\n")
              script:write("PY=" .. C.quoteArg(PYTHON_PATH) .. "\n")
              script:write("SEP=" .. C.quoteArg(SEPARATOR_SCRIPT) .. "\n")
            if OS == "macOS" then
                local ffmpegPath = FFMPEG_PATH or getExtStateValue("ffmpegPath") or getExtStateValue("FFMPEG_PATH")
                if ffmpegPath and ffmpegPath ~= "" then
                    script:write("FFMPEG_PATH=" .. C.quoteArg(ffmpegPath) .. "\n")
                    script:write("IMAGEIO_FFMPEG_EXE=" .. C.quoteArg(ffmpegPath) .. "\n")
                    script:write("export FFMPEG_PATH IMAGEIO_FFMPEG_EXE\n")
                    script:write("FFMPEG_DIR=$(dirname \"$FFMPEG_PATH\")\n")
                    script:write("PATH=\"$FFMPEG_DIR:${PATH}\"\n")
                    script:write("export PATH\n")
                end
            end
            if OS == "Windows" then
                local vbsPath = outputDir .. PATH_SEP .. "run_hidden.vbs"
                local vbsFile = io.open(vbsPath, "w")
                if vbsFile then
                    local logPath = SW_LOG and SW_LOG.getLogPath and SW_LOG.getLogPath() or ""
                    local jobTag = "single"
                    -- Append CLI args for log path and job tag
                    local pythonCmd = string.format(
                        '"%s" -u "%s" "%s" "%s" --model %s --stemwerk-log-path "%s" --stemwerk-job-tag "%s"',
                        PYTHON_PATH, SEPARATOR_SCRIPT, inputFile, outputDir, model, logPath, jobTag
                    )
                    pythonCmd = pythonCmd:gsub('"', '""')
                    vbsFile:write('Set WshShell = CreateObject("WScript.Shell")\n')
                    vbsFile:write('WshShell.Run "cmd /c ' .. pythonCmd .. ' >""' .. stdoutFile .. '"" 2>""' .. logFile .. '""", 0, True\n')
                    vbsFile:close()
                    cmd = 'cscript //nologo "' .. vbsPath .. '"'
                end
            else
            script:write("IN=" .. C.quoteArg(inputFile) .. "\n")
            script:write("OUT=" .. C.quoteArg(outputDir) .. "\n")
            script:write("unset PYTHONPATH PYTHONHOME\n")
            script:write("MODEL=" .. C.quoteArg(modelArg) .. "\n")
            script:write("DEVICE=" .. C.quoteArg(deviceArg) .. "\n")
            script:write("WORKFLOW_MODE=" .. C.quoteArg(workflowModeArg) .. "\n")
            script:write("WORKFLOW_SOURCE=" .. C.quoteArg(workflowSourceArg) .. "\n")
            script:write("REQUESTED_STAGE2_MODEL=" .. C.quoteArg(requestedStage2ModelArg) .. "\n")
            script:write("STDOUT=" .. C.quoteArg(stdoutFile) .. "\n")
            script:write("STDERR=" .. C.quoteArg(logFile) .. "\n")
            script:write("DONE=" .. C.quoteArg(doneFile) .. "\n")
            script:write("PIDFILE=" .. C.quoteArg(pidFile) .. "\n")
            script:write("EXITCODE=" .. C.quoteArg(exitCodeFile) .. "\n")
            script:write("PY_SITE=$(\"$PY\" -c \"import sysconfig; print(sysconfig.get_paths().get('purelib',''))\")\n")
            script:write("if [ -n \"$PY_SITE\" ]; then\n")
            script:write("  for d in \"$PY_SITE\"/nvidia/*/lib \"$PY_SITE\"/nvidia/*/lib64; do\n")
            script:write("    if [ -d \"$d\" ]; then\n")
            script:write("      case \":$LD_LIBRARY_PATH:\" in\n")
            script:write("        *\":$d:\"*) ;;\n")
            script:write("        *) LD_LIBRARY_PATH=\"${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$d\" ;;\n")
            script:write("      esac\n")
            script:write("    fi\n")
            script:write("  done\n")
            script:write("  export LD_LIBRARY_PATH\n")
            script:write("fi\n")
            script:write("(\n")
            script:write('  set -- "$PY" -u "$SEP" "$IN" "$OUT" --model "$MODEL" --device "$DEVICE"\n')
            script:write('  if [ -n "$WORKFLOW_MODE" ]; then set -- "$@" --workflow-mode "$WORKFLOW_MODE"; fi\n')
            script:write('  if [ -n "$WORKFLOW_SOURCE" ]; then set -- "$@" --workflow-source "$WORKFLOW_SOURCE"; fi\n')
            script:write('  if [ -n "$REQUESTED_STAGE2_MODEL" ]; then set -- "$@" --requested-stage2-model "$REQUESTED_STAGE2_MODEL"; fi\n')
            script:write('  "$@" >"$STDOUT" 2>"$STDERR" &\n')
            script:write('  worker_pid=$!\n')
            script:write('  echo "$worker_pid" > "$PIDFILE"\n')
            script:write('  wait "$worker_pid"\n')
            script:write("  rc=$?\n")
            script:write('  echo "$rc" > "$EXITCODE"\n')
            script:write('  if [ "$rc" -eq 0 ]; then\n')
            script:write('    echo DONE > "$DONE"\n')
            script:write('  else\n')
            script:write('    echo "EXIT:$rc" >> "$STDERR"\n')
            script:write('    echo ERROR > "$DONE"\n')
            script:write('  fi\n')
            script:write(") &\n")
            script:close()

            local cmd = "sh " .. C.quoteArg(launcherPath) .. C.suppressStderr()
            debugLog("Executing (background) launcher: " .. cmd)
            os.execute(cmd)
            end -- if OS == "Windows"
        else
            -- If we couldn't write the launcher, fall back to a direct foreground run (old behavior).
            local extraArgs = ""
            if workflowModeArg ~= "" then
                extraArgs = extraArgs .. " --workflow-mode " .. C.quoteArg(workflowModeArg)
            end
            if workflowSourceArg ~= "" then
                extraArgs = extraArgs .. " --workflow-source " .. C.quoteArg(workflowSourceArg)
            end
            if requestedStage2ModelArg ~= "" then
                extraArgs = extraArgs .. " --requested-stage2-model " .. C.quoteArg(requestedStage2ModelArg)
            end
            local cmd = string.format(
                '%s -u %s %s %s --model %s --device %s%s >%s 2>%s && echo DONE > %s',
                C.quoteArg(PYTHON_PATH),
                C.quoteArg(SEPARATOR_SCRIPT),
                C.quoteArg(inputFile),
                C.quoteArg(outputDir),
                C.quoteArg(modelArg),
                C.quoteArg(deviceArg),
                extraArgs,
                C.quoteArg(stdoutFile),
                C.quoteArg(logFile),
                C.quoteArg(doneFile)
            )
            debugLog("Unix launcher write failed; executing (foreground) command: " .. cmd)
            local ok, _, code = os.execute(cmd)
            local rc = (ok == true or ok == 0) and 0 or (code or 1)
            SW_LOG.writeExitCode(exitCodeFile, rc)
            debugLog("Command finished with rc=" .. tostring(rc))
        end
    end
    return true
end

-- Progress loop with UI
function WORKFLOW.progressLoop()
    local loopNow = uiNow()
    refreshProgressActivityFromFiles()
    local cancelClicked = false

    if loopNow >= (C.progressState.nextPollAt or 0) then
        C.progressState.nextPollAt = loopNow + UI_PACING.progressPollInterval
        local prevPercent = C.progressState.percent or 0
        WORKFLOW.updateProgressFromFile()
        if prevPercent < 87 and C.progressState.percent >= 87 then
            debugLog("[LOG] Progress reached ~87% (" .. tostring(C.progressState.percent) .. ") stage=" .. tostring(C.progressState.stage))
        end
    end

    if loopNow >= (C.progressState.nextFrameAt or 0) then
        C.progressState.nextFrameAt = loopNow + pacingFrameInterval("progressFrameInterval", "progressFrameIntervalFx")
        cancelClicked = C.drawProgressWindow() and true or false
    end

    local char = gfx.getchar()
    local mouseDown = gfx.mouse_cap & 1 == 1
    C.handleArtAdvance(C.progressState, mouseDown, char)
    if char == 26161 then  -- F1 key code
        -- Reserved (no-op for now). Keep input handling centralized here so ESC is never consumed elsewhere.
    end
    local cancelRequested = cancelClicked or ((C.progressState and C.progressState.cancelRequested) and true or false)
    if char == -1 or char == 27 or cancelRequested then  -- Window closed, ESC pressed, or cancel button
        -- Window closed by user
        C.progressState.cancelRequested = false
        C.progressState.running = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Remember any size/position changes made during processing
        C.captureWindowGeometry(WINDOW_PROCESSING)
        C.saveSettings()

        -- Preserve best-effort diagnostics before stopping worker; files may be partial on cancel.
        if C.progressState.outputDir and C.progressState.outputDir ~= "" then
            SW_LOG.preserveDiagnosticsForRun(C.progressState.outputDir, { reason = "user_cancel" })
        end
        if SW_TIMING then SW_TIMING.endJob("single", "user_cancel"); SW_TIMING.endRun("user_cancel") end

        -- Best-effort kill of running worker (otherwise cancel leaves a hidden Python process running)
        HELPERS.killProcessFromPidFile(C.progressState.pidFile)
        if C.progressState.outputDir and C.progressState.outputDir ~= "" then
            SW_LOG.preserveDiagnosticsForRun(C.progressState.outputDir, { reason = "user_cancel" })
        end

        gfx.quit()
        C.progressState.windowOpen = false

        -- After cancel, go back to the start/selection monitoring window.
        -- This lets the user quickly pick a new item/time selection without reopening the full dialog.
        C.showMessage("Cancelled", C.T("progress_cancelled_status") or C.T("separation_cancelled"), "info", true)
        return
    end

    if WORKFLOW.checkSeparationDone() then
        -- Done!
        C.progressState.running = false
        WORKFLOW.updateProgressFromFile()
        if C.progressState.outputDir and C.progressState.outputDir ~= "" then
            SW_LOG.persistRunDiagnostics(C.progressState.outputDir)
        end
        recordTimingEvent("done_seen")

        -- Remember any size/position changes made during processing
        C.captureWindowGeometry(WINDOW_PROCESSING)
        C.saveSettings()

        gfx.quit()
        C.progressState.windowOpen = false
        WORKFLOW.finishSeparationCallback()
        return
    end

    -- No fixed wall-clock timeout for active jobs.
    -- Only declare stale when there has been no progress/log/state activity for a long period.
    local lastActivityAt = tonumber(C.progressState.lastActivityAt or 0) or 0
    local idleFor = lastActivityAt > 0 and (os.time() - lastActivityAt) or 0
    if idleFor > PROGRESS_IDLE_STALE_SECONDS then
        C.progressState.running = false
        isProcessingActive = false  -- Reset guard so workflow can be restarted

        -- Remember any size/position changes made during processing
        C.captureWindowGeometry(WINDOW_PROCESSING)
        C.saveSettings()

        gfx.quit()
        C.progressState.windowOpen = false
        local msg = "Separation appears stale: no progress or log updates for "
            .. tostring(math.floor(idleFor / 60)) .. " minutes.\n\n"
            .. "Run artifacts and logs were preserved for diagnostics.\n"
            .. "stdout: " .. tostring(C.progressState.stdoutFile or "unknown") .. "\n"
            .. "log: " .. tostring(C.progressState.logFile or "unknown") .. "\n"
            .. "debug: " .. tostring(C.progressState.execLogPath or SW_LOG.getLogPath())
        debugLog("progressLoop stale timeout: idleForSec=" .. tostring(idleFor) .. " lastActivityReason=" .. tostring(C.progressState.lastActivityReason or "unknown"))
        C.showMessage("Timeout", msg, "error", false)
        return
    end

    reaper.defer(WORKFLOW.progressLoop)
end

-- Finish separation after progress completes
function WORKFLOW.finishSeparationCallback()
    -- Small delay to ensure files are written
    local checkCount = 0
    local persistAttempts = 0
    local function fileExistsLocal(path)
        if not path or path == "" then return false end
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end
    local function persistWithExitCodeRetry(onDone)
        persistAttempts = persistAttempts + 1
        if C.progressState.outputDir and C.progressState.outputDir ~= "" then
            SW_LOG.persistRunDiagnostics(C.progressState.outputDir)
        end
        local hasExitCode = SW_LOG.readExitCode(C.progressState.exitCodeFile) ~= nil
        if hasExitCode or persistAttempts >= 8 then
            if onDone then onDone() end
            return
        end
        if fileExistsLocal(C.progressState.outputDir .. PATH_SEP .. "done.txt") then
            reaper.defer(function() persistWithExitCodeRetry(onDone) end)
            return
        end
        if onDone then onDone() end
    end
    debugLog("[LOG] finishSeparationCallback: stdoutFile=" .. tostring(C.progressState.stdoutFile) .. ", separationLogFile=" .. tostring(C.progressState.logFile) .. ", outputDir=" .. tostring(C.progressState.outputDir))
    local function checkFiles()
        checkCount = checkCount + 1
        debugLog("lua_result_probe_start")
        append_diag_log("lua_result_probe_start")
        debugLog("lua_result_probe_workflow_source=" .. tostring(C.progressState.workflowSource or ""))
        append_diag_log("lua_result_probe_workflow_source=" .. tostring(C.progressState.workflowSource or ""))
        local stems = {}
        local topLevelCount = 0
        for _, stem in ipairs(STEMS) do
            if stem.selected then
                local stemPath = C.progressState.outputDir .. PATH_SEP .. stem.file
                local f = io.open(stemPath, "r")
                if f then
                    f:close()
                    stems[stem.name:lower()] = stemPath
                    topLevelCount = topLevelCount + 1
                end
            end
        end
        debugLog("lua_result_probe_top_level_count=" .. tostring(topLevelCount))
        append_diag_log("lua_result_probe_top_level_count=" .. tostring(topLevelCount))
        SW_LOG.logExecResult("dks_probe_stemset first=" .. tostring(STEMS and STEMS[1] and STEMS[1].name or "?")
            .. " stemset_count=" .. tostring(STEMS and #STEMS or 0)
            .. " top_level_count=" .. tostring(topLevelCount)
            .. " workflow_source=" .. tostring(C.progressState.workflowSource or ""), nil, "")

        if next(stems) == nil then
            debugLog("lua_result_probe_stdout_json_attempt=yes")
            append_diag_log("lua_result_probe_stdout_json_attempt=yes")
            local stdoutStems = collectStemPathsFromStdoutJson(C.progressState.stdoutFile)
            if next(stdoutStems) then
                stems = stdoutStems
                local outputCount = 0
                for _ in pairs(stems) do outputCount = outputCount + 1 end
                debugLog("lua_result_probe_stdout_json_ok=yes")
                append_diag_log("lua_result_probe_stdout_json_ok=yes")
                debugLog("lua_result_probe_stdout_json_count=" .. tostring(outputCount))
                append_diag_log("lua_result_probe_stdout_json_count=" .. tostring(outputCount))
                if tostring(C.progressState.workflowSource or "") == "dks_extract" then
                    debugLog("lua_dks_extract_outputs_detected=yes")
                    debugLog("lua_dks_extract_output_count=" .. tostring(outputCount))
                    append_diag_log("lua_dks_extract_outputs_detected=yes")
                    append_diag_log("lua_dks_extract_output_count=" .. tostring(outputCount))
                    SW_LOG.logExecResult("lua_dks_extract_outputs_detected=yes", nil, "lua_dks_extract_output_count=" .. tostring(outputCount))
                end
            else
                debugLog("lua_result_probe_stdout_json_ok=no")
                append_diag_log("lua_result_probe_stdout_json_ok=no")
                debugLog("lua_no_stems_reason=stdout_json_missing_or_invalid")
                append_diag_log("lua_no_stems_reason=stdout_json_missing_or_invalid")
            end
        else
            debugLog("lua_result_probe_stdout_json_attempt=no")
            append_diag_log("lua_result_probe_stdout_json_attempt=no")
        end

        if next(stems) and tostring(C.progressState.workflowSource or "") == "dks_extract" then
            local probeCount = 0
            for k, v in pairs(stems) do
                probeCount = probeCount + 1
                local ev = string.format("dks_import_input_path key=%q path=%q path_len=%d", tostring(k), tostring(v), #tostring(v))
                debugLog(ev)
                append_diag_log(ev)
                SW_LOG.logExecResult(ev, nil, "")
            end
            local cntMsg = "dks_validated_output_count=" .. tostring(probeCount)
            debugLog(cntMsg)
            append_diag_log(cntMsg)
            SW_LOG.logExecResult(cntMsg, nil, "")
        end

        if next(stems) then
            debugLog("[LOG] Output detected for job (finishSeparationCallback)")
            persistWithExitCodeRetry(function()
                -- Success - process stems
                isProcessingActive = false  -- Reset guard so workflow can be restarted after result
                debugLog("[LOG] Import start (processStemsResult)")
                if tostring(C.progressState.workflowSource or "") == "dks_extract" then
                    debugLog("lua_dks_extract_import_start")
                    append_diag_log("lua_dks_extract_import_start")
                    SW_LOG.logExecResult("lua_dks_extract_import_start", nil, "")
                end
                local importOk = processStemsResult(stems)
                if importOk == false then
                    SW_LOG.logExecResult("workflow_success=no", nil, "workflow_failure_reason=dks_import_invariant_violation")
                end
                if tostring(C.progressState.workflowSource or "") == "dks_extract" then
                    debugLog("lua_dks_extract_import_end")
                    append_diag_log("lua_dks_extract_import_end")
                    SW_LOG.logExecResult("lua_dks_extract_import_end", nil, "")
                end
                debugLog("[LOG] Import end (processStemsResult)")
                debugLog("[LOG] Finalize start (cleanupTempWorkDir)")
                C.cleanupTempWorkDir(C.progressState.outputDir, { success = (importOk ~= false), keepStemPaths = stems })
                debugLog("[LOG] Finalize end (cleanupTempWorkDir)")
            end)
        elseif checkCount < 10 then
            -- Retry
            reaper.defer(checkFiles)
        else
            -- Failed
            debugLog("lua_dks_extract_outputs_detected=no")
            append_diag_log("lua_dks_extract_outputs_detected=no")
            SW_LOG.logExecResult("lua_dks_extract_outputs_detected=no", nil, "")
            persistWithExitCodeRetry(function()
                isProcessingActive = false  -- Reset guard so workflow can be restarted
                local exitCode = SW_LOG.readExitCode(C.progressState.exitCodeFile)
                local logSnippet = SW_LOG.readFileSnippet(C.progressState.logFile, 12000) or "(no log output found)"
                local stdoutSnippet = SW_LOG.readFileSnippet(C.progressState.stdoutFile, 1200)
                local errMsg = nil
                if C.buildKnownSeparationFailureMessage then
                    errMsg = C.buildKnownSeparationFailureMessage(
                        logSnippet,
                        exitCode,
                        C.progressState.lastCmd,
                        C.progressState.logFile,
                        C.progressState.execLogPath or SW_LOG.getLogPath(),
                        stdoutSnippet
                    )
                end
                if not errMsg then
                    debugLog("lua_no_stems_reason=no_detected_outputs_after_retries")
                    append_diag_log("lua_no_stems_reason=no_detected_outputs_after_retries")
                    errMsg = "No stems created"
                        .. "\n\nExit code: " .. tostring(exitCode or "unknown")
                        .. "\nCommand: " .. tostring(C.progressState.lastCmd or "unknown")
                        .. "\nLog file: " .. tostring(C.progressState.logFile or "unknown")
                        .. "\nDebug log: " .. tostring(C.progressState.execLogPath or SW_LOG.getLogPath())
                        .. "\n\nOutput (first 2000 chars):\n" .. logSnippet
                    if stdoutSnippet then
                        errMsg = errMsg .. "\n\nStdout (first 1200 chars):\n" .. stdoutSnippet
                    end
                end
                -- Keep this visible until user closes it; auto-monitor mode can immediately
                -- bounce back to the main window and hide actionable error details.
                C.showMessage("Separation Failed", errMsg, "error", false)
            end)
        end
    end
    checkFiles()
end

-- Run separation with progress UI
function WORKFLOW.runSeparationWithProgress(inputFile, outputDir, model, runOptions)
    -- Load settings to get current theme
    C.loadSettings()
    C.updateTheme()

    if preflightNormalWorkflowDeviceRoute(runOptions) == false then
        if OS == "Windows" and C.progressState.windowOpen then
            closeProcessingWindow()
        end
        isProcessingActive = false
        return
    end

    if OS == "Windows" and C.progressState.windowOpen then
        showProcessingPlaceholderWindow(C.T("progress_initializing") or "Initializing...")
    end

    -- Start the process
    local ok = WORKFLOW.startSeparationProcess(inputFile, outputDir, model, runOptions)
    if ok == false then
        if OS == "Windows" and C.progressState.windowOpen then
            closeProcessingWindow()
        end
        isProcessingActive = false
        return
    end
    debugLog("[LOG] All workers launched (runSeparationWithProgress)")

    -- Capture main window geometry and snapshot for cancel -> main restore
    C.captureWindowGeometry(SCRIPT_NAME)
    C.GUI.snapshotMainGeometry()

    if not C.progressState.windowOpen then
        ensureProcessingWindowOpen()
    end
    C.progressState.stage = C.T("progress_starting_backend") or "Starting backend..."

    C.progressState.running = true
    -- DEBUG: Write launcher_debug.txt with all relevant details before generating VBS launcher
    local debug_path = outputDir .. "\\launcher_debug.txt"
    local debug_file = io.open(debug_path, "w")
    if debug_file then
        debug_file:write("[STEMwerk WORKFLOW.runSeparation launcher debug]\n")
        debug_file:write("outputDir: " .. tostring(outputDir) .. "\n")
        debug_file:write("pythonExe: " .. tostring(PYTHON_PATH) .. "\n")
        debug_file:write("scriptPath: " .. tostring(SEPARATOR_SCRIPT) .. "\n")
        debug_file:write("args: " .. table.concat({inputFile, outputDir, model}, " ") .. "\n")
        debug_file:close()
    end

    if OS == "Windows" then
        WORKFLOW.progressLoop()  -- Paint first frame immediately so Windows does not show a blank client area.
    else
        reaper.defer(WORKFLOW.progressLoop)
    end
end

-- Legacy synchronous separation (fallback)
function WORKFLOW.runSeparation(inputFile, outputDir, model)
    local logFile = outputDir .. PATH_SEP .. "separation_log.txt"
    local stdoutFile = outputDir .. PATH_SEP .. "stdout.txt"

    local cmd
    if OS == "Windows" then
        local vbsPath = outputDir .. PATH_SEP .. "run_hidden.vbs"
        local vbsFile = io.open(vbsPath, "w")
        if vbsFile then
            local logPath = SW_LOG and SW_LOG.getLogPath and SW_LOG.getLogPath() or ""
            local jobTag = "single"
            local pythonCmd = string.format(
                '"%s" -u "%s" "%s" "%s" --model %s',
                PYTHON_PATH, SEPARATOR_SCRIPT, inputFile, outputDir, model
            )
            pythonCmd = pythonCmd:gsub('"', '""')
            -- Prepend set commands for env vars
            local envPrefix = 'set STEMWERK_LOG_PATH=' .. logPath .. ' && set STEMWERK_JOB_TAG=' .. jobTag .. ' && '
            envPrefix = envPrefix:gsub('"', '""')
            vbsFile:write('Set WshShell = CreateObject("WScript.Shell")\n')
            vbsFile:write('WshShell.Run "cmd /c ' .. envPrefix .. pythonCmd .. ' >""' .. stdoutFile .. '"" 2>""' .. logFile .. '""", 0, True\n')
            vbsFile:close()
            cmd = 'cscript //nologo "' .. vbsPath .. '"'
        end
    else
        cmd = string.format(
            '"%s" -u "%s" "%s" "%s" --model %s >"%s" 2>"%s"',
            PYTHON_PATH, SEPARATOR_SCRIPT, inputFile, outputDir, model, stdoutFile, logFile
        )
    end

    os.execute(cmd)

    local stems = {}
    for _, stem in ipairs(STEMS) do
        if stem.selected then
            local stemPath = outputDir .. PATH_SEP .. stem.file
            local f = io.open(stemPath, "r")
            if f then f:close(); stems[stem.name:lower()] = stemPath end
        end
    end

    if next(stems) == nil then
        local errLog = io.open(logFile, "r")
        local errMsg = "No stems created"
        if errLog then
            local content = errLog:read("*a")
            errLog:close()
            if content and content ~= "" then
                errMsg = errMsg .. "\n\nLog:\n" .. content:sub(1, 500)
            end
        end
        return nil, errMsg
    end
    return stems
end

-- Replace only a portion of an item with stems (for time selection mode)
-- Splits the item at selection boundaries and replaces only the selected portion
function WORKFLOW.replaceInPlacePartial(item, stemPaths, selStart, selEnd, nameBase)
    local track = reaper.GetMediaItem_Track(item)
    local sourcePlaybackState = snapshotActiveTakePlaybackState(item)
    local origItemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local origItemEnd = origItemPos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local replaceStart = math.max(tonumber(selStart) or origItemPos, origItemPos)
    local replaceEnd = math.min(tonumber(selEnd) or origItemEnd, origItemEnd)

    if replaceEnd <= replaceStart then
        return 0, nil
    end

    local stemEntries = buildTakeImportStemEntries(stemPaths)
    if #stemEntries == 0 then
        return 0, item
    end

    reaper.Undo_BeginBlock()

    -- We need to split the item at selection boundaries
    -- First, deselect all items and select only our target item
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)

    local leftItem = nil   -- Part before selection (if any)
    local middleItem = item -- Part to replace
    local rightItem = nil  -- Part after selection (if any)

    -- Split at selection start if it's inside the item
    if replaceStart > origItemPos and replaceStart < origItemEnd then
        middleItem = reaper.SplitMediaItem(item, replaceStart)
        leftItem = item
        if middleItem then
            reaper.SetMediaItemSelected(leftItem, false)
            reaper.SetMediaItemSelected(middleItem, true)
        else
            -- Split failed, middle is still the original item
            middleItem = item
            leftItem = nil
        end
    end

    -- Split at selection end if it's inside what remains
    if middleItem then
        local midPos = reaper.GetMediaItemInfo_Value(middleItem, "D_POSITION")
        local midEnd = midPos + reaper.GetMediaItemInfo_Value(middleItem, "D_LENGTH")

        if replaceEnd > midPos and replaceEnd < midEnd then
            rightItem = reaper.SplitMediaItem(middleItem, replaceEnd)
            if rightItem then
                reaper.SetMediaItemSelected(rightItem, false)
            end
        end
    end

    -- Now delete the middle item and insert stems in its place
    local selLen = replaceEnd - replaceStart
    if middleItem then
        reaper.DeleteTrackMediaItem(track, middleItem)
    end

    -- Create stem items at the selection position
    local items = {}
    local totalStems = #stemEntries
    local baseName = nameBase or getItemDisplayNameForTakes(item)
    local importedItems = {}
    local importedPaths = {}
    for idx, entry in ipairs(stemEntries) do
        local stem = entry.stem
        local stemPath = entry.path
        local newItem = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", replaceStart)
        reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", selLen)

        local take = reaper.AddTakeToMediaItem(newItem)
        local source = reaper.PCM_Source_CreateFromFile(stemPath)
        reaper.SetMediaItemTake_Source(take, source)
        local takeLabel = string.format("Take %d/%d: %s - %s", idx, math.max(1, totalStems), baseName, stem.name)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", takeLabel, true)
        -- Ensure take volume is at unity (1.0 = 0dB)
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)
        applyPlaybackStateToTake(take, sourcePlaybackState)

        local stemColor = C.rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
        HELPERS.applyItemColorIfEnabled(newItem, stemColor)

        items[#items + 1] = { item = newItem, take = take, color = stemColor, name = takeLabel }
        importedItems[#importedItems + 1] = newItem
        importedPaths[#importedPaths + 1] = stemPath
    end

    -- Merge into takes on the first item
    if #items > 1 then
        local mainItem = items[1].item
        -- Set main item color to first stem color
        HELPERS.applyItemColorIfEnabled(mainItem, items[1].color)

        for i = 2, #items do
            local srcTake = reaper.GetActiveTake(items[i].item)
            if srcTake then
                local newTake = reaper.AddTakeToMediaItem(mainItem)
                reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(srcTake))
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", items[i].name, true)
                -- Ensure take volume is at unity (1.0 = 0dB)
                reaper.SetMediaItemTakeInfo_Value(newTake, "D_VOL", 1.0)
                applyPlaybackStateToTake(newTake, sourcePlaybackState)
            end
            reaper.DeleteTrackMediaItem(track, items[i].item)
        end

        -- Now set the color for each take based on its stem
        -- Iterate through all takes and set their colors
        local numTakes = reaper.CountTakes(mainItem)
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(mainItem, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                -- Find the matching stem color
                for _, stemData in ipairs(items) do
                    if stemData.name == takeName then
                        -- Set take color (I_CUSTOMCOLOR on the take)
                        HELPERS.applyTakeColorIfEnabled(take, stemData.color)
                        break
                    end
                end
            end
        end
    end

    HELPERS.refreshImportedMediaItems({ ((#items >= 1) and items[1].item or nil) }, importedPaths)
    reaper.Undo_EndBlock("STEMwerk: Replace selection in-place", -1)
    local mainItem = (#items >= 1) and items[1].item or nil
    return #items, mainItem
end

-- Replace item in-place with stems as takes
function WORKFLOW.replaceInPlace(item, stemPaths, itemPos, itemLen, nameBase)
    local track = reaper.GetMediaItem_Track(item)
    local sourcePlaybackState = snapshotActiveTakePlaybackState(item)
    local stemEntries = buildTakeImportStemEntries(stemPaths)
    if #stemEntries == 0 then
        return 0, item
    end

    reaper.Undo_BeginBlock()
    reaper.DeleteTrackMediaItem(track, item)

    local items = {}
    local totalStems = #stemEntries
    local baseName = nameBase or getItemDisplayNameForTakes(item)
    local importedPaths = {}
    for idx, entry in ipairs(stemEntries) do
        local stem = entry.stem
        local stemPath = entry.path
        local newItem = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(newItem, "D_POSITION", itemPos)
        reaper.SetMediaItemInfo_Value(newItem, "D_LENGTH", itemLen)

        local take = reaper.AddTakeToMediaItem(newItem)
        local source = reaper.PCM_Source_CreateFromFile(stemPath)
        reaper.SetMediaItemTake_Source(take, source)
        local takeLabel = string.format("Take %d/%d: %s - %s", idx, math.max(1, totalStems), baseName, stem.name)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", takeLabel, true)
        -- Ensure take volume is at unity (1.0 = 0dB)
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)
        applyPlaybackStateToTake(take, sourcePlaybackState)

        local stemColor = C.rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
        HELPERS.applyItemColorIfEnabled(newItem, stemColor)

        items[#items + 1] = { item = newItem, take = take, color = stemColor, name = takeLabel }
        importedPaths[#importedPaths + 1] = stemPath
    end

    -- Merge into takes
    if #items > 1 then
        local mainItem = items[1].item
        -- Set main item color to first stem color
        HELPERS.applyItemColorIfEnabled(mainItem, items[1].color)

        for i = 2, #items do
            local srcTake = reaper.GetActiveTake(items[i].item)
            if srcTake then
                local newTake = reaper.AddTakeToMediaItem(mainItem)
                reaper.SetMediaItemTake_Source(newTake, reaper.GetMediaItemTake_Source(srcTake))
                reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", items[i].name, true)
                -- Ensure take volume is at unity (1.0 = 0dB)
                reaper.SetMediaItemTakeInfo_Value(newTake, "D_VOL", 1.0)
                applyPlaybackStateToTake(newTake, sourcePlaybackState)
            end
            reaper.DeleteTrackMediaItem(track, items[i].item)
        end

        -- Now set the color for each take based on its stem
        local numTakes = reaper.CountTakes(mainItem)
        for t = 0, numTakes - 1 do
            local take = reaper.GetTake(mainItem, t)
            if take then
                local _, takeName = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                -- Find the matching stem color
                for _, stemData in ipairs(items) do
                    if stemData.name == takeName then
                        HELPERS.applyTakeColorIfEnabled(take, stemData.color)
                        break
                    end
                end
            end
        end
    end

    HELPERS.refreshImportedMediaItems({ ((#items >= 1) and items[1].item or nil) }, importedPaths)
    reaper.Undo_EndBlock("STEMwerk: Replace in-place", -1)
    local mainItem = (#items >= 1) and items[1].item or nil
    return #items, mainItem
end
