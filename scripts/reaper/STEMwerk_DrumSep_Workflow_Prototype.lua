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

local STAGE2_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
local FFMPEG_BIN = "ffmpeg"
local DRUMSEP_WORKFLOW_MODE = "clean_fast"
local DEFAULT_DRUMKIT_DEVICE = "cpu"
local DRUMKIT_PARALLEL_TRACE_PATH = nil
local STEMWERK_EXT_SECTION = "STEMwerk"
local STEMWERK_DEV_EXT_SECTION = "STEMwerk-dev"
local STEMWERK_BENCHMARK_EXT_SECTION = "STEMwerk_benchmark"
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
local currentDrumKitAsyncRun = nil
local ASYNC_TEMP_ROOT_KEY = "__drumkit_async_temp_root"
local getScriptDir
local sourceIndexLabel
local sanitizeSourceLabel
local sanitizeTrackLabel
local nowSeconds
local logKV
local jsonEncode
local writeTextFile
local appendTextFile
local formatUtcIso
local resolveWorkflowSources
local importDrumKitSplit
local resolvePython
local refreshImportedMediaItems
local LOADED_CHUNK_SOURCE = (debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source) or ""
if LOADED_CHUNK_SOURCE:sub(1, 1) == "@" then
    LOADED_CHUNK_SOURCE = LOADED_CHUNK_SOURCE:sub(2)
end
local LOADED_SCRIPT_DIR = LOADED_CHUNK_SOURCE:match("^(.*[/\\])")

local function isPrototypeActionAllowed()
    if not (reaper and reaper.GetExtState) then
        return false
    end
    local v = tostring(reaper.GetExtState("STEMwerk-dev", "allow_drumkit_prototype_actions") or ""):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

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

local function trimPathSep(path)
    local p = tostring(path or "")
    while #p > 1 and (p:sub(-1) == "/" or p:sub(-1) == "\\") do
        p = p:sub(1, -2)
    end
    return p
end

local function stemwerkTempBaseDir()
    local envTemp = os.getenv("STEMWERK_TEMP_DIR")
        or os.getenv("TMPDIR")
        or os.getenv("TEMP")
        or os.getenv("TMP")
    if envTemp and envTemp ~= "" then
        return trimPathSep(envTemp)
    end
    return "/tmp"
end

local function makeDrumKitTempRoot(ts)
    return pathJoin(stemwerkTempBaseDir(), "stemwerk-drumsep-workflow-prototype-" .. tostring(ts or os.date("%Y%m%d-%H%M%S")))
end

DRUMKIT_PARALLEL_TRACE_PATH = pathJoin(stemwerkTempBaseDir(), "STEMwerk_drumkit_parallel_trace.log")

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

local function appendParallelTrace(runCtx, message)
    local paths = { DRUMKIT_PARALLEL_TRACE_PATH }
    if runCtx and runCtx.parallel_trace_path and runCtx.parallel_trace_path ~= "" then
        table.insert(paths, 1, runCtx.parallel_trace_path)
    end
    local elapsed = 0
    if runCtx and runCtx.started_at then
        elapsed = tonumber(nowSeconds() - runCtx.started_at) or 0
    end
    local line = string.format("%.3f %s\n", elapsed, tostring(message or ""))
    for _, path in ipairs(paths) do
        local f = io.open(path, "ab")
        if f then
            f:write(line)
            f:close()
        end
    end
end

local function activeSourceIndexList(runCtx)
    local indices = {}
    for _, sourceCtx in ipairs((runCtx and runCtx.active_source_order) or {}) do
        indices[#indices + 1] = tostring(tonumber(sourceCtx.index or 0) or 0)
    end
    return table.concat(indices, ",")
end

local function pendingSourceCount(runCtx)
    if not runCtx then return 0 end
    local total = tonumber(runCtx.source_count or 0) or 0
    local nextIdx = tonumber(runCtx.pending_next_source_index or 1) or 1
    if nextIdx > total then return 0 end
    return total - nextIdx + 1
end

local readTextFile
local trimText

local function classifyDrumKitDevice(device)
    local d = tostring(device or ""):lower()
    if d == "" or d == "auto" then return "unknown" end
    if d == "cpu" or d:find("cpu", 1, true) then return "cpu" end
    if d:match("^cuda") then return "cuda" end
    if d:match("^rocm") or d:match("^hip") or d:match("^privateuseone") then return "rocm" end
    if d:match("^directml") then return "directml" end
    if d == "mps" then return "mps" end
    if d:find("gpu", 1, true) then return "gpu" end
    return "unknown"
end

local function classifyDeviceClass(device)
    local backend = classifyDrumKitDevice(device)
    if backend == "cpu" then return "cpu" end
    if backend == "cuda" or backend == "rocm" or backend == "directml" or backend == "mps" or backend == "gpu" then
        return "gpu"
    end
    if tostring(device or ""):lower() == "auto" then return "auto" end
    return "unknown"
end

local function parseCommandDevice(cmd)
    local c = tostring(cmd or "")
    local quoted = c:match("%-%-device%s+\"([^\"]+)\"")
    if quoted and quoted ~= "" then return quoted end
    local single = c:match("%-%-device%s+'([^']+)'")
    if single and single ~= "" then return single end
    local bare = c:match("%-%-device%s+([^%s]+)")
    if bare and bare ~= "" then return bare end
    return ""
end

local function parseWorkerDiagnostics(stderrPath, cmd)
    local diag = {
        worker_requested_device = parseCommandDevice(cmd),
        actual_torch_device = "unknown",
        actual_runtime_backend = "unknown",
        actual_acceleration_available = false,
    }
    local text = readTextFile(stderrPath or "") or ""
    for key, value in text:gmatch("STEMWERK_DIAG%s+([%w_]+)=([^\r\n]+)") do
        diag[key] = trimText(value)
    end
    if diag.selected_device and diag.selected_device ~= "" then
        diag.actual_torch_device = tostring(diag.selected_device)
        diag.actual_runtime_backend = classifyDrumKitDevice(diag.selected_device)
    elseif diag.worker_requested_device and diag.worker_requested_device ~= "" then
        diag.actual_torch_device = tostring(diag.worker_requested_device)
        diag.actual_runtime_backend = classifyDrumKitDevice(diag.worker_requested_device)
    end
    if diag.actual_runtime_backend == "unknown" then
        local torchVersion = tostring(diag.torch_version or ""):lower()
        if torchVersion:find("rocm", 1, true) then
            diag.runtime_torch_build_backend = "rocm"
        elseif torchVersion:find("cuda", 1, true) then
            diag.runtime_torch_build_backend = "cuda"
        end
    end
    diag.actual_acceleration_available =
        diag.actual_runtime_backend == "cuda"
        or diag.actual_runtime_backend == "rocm"
        or diag.actual_runtime_backend == "directml"
        or diag.actual_runtime_backend == "mps"
    return diag
end

local function mergeRunDeviceTruth(runCtx, diag)
    if not runCtx or not diag then return end
    local backend = tostring(diag.actual_runtime_backend or "unknown")
    if backend ~= "" and backend ~= "unknown" then
        runCtx.actual_runtime_backend = backend
    end
    local dev = tostring(diag.actual_torch_device or "unknown")
    if dev ~= "" and dev ~= "unknown" then
        runCtx.actual_torch_device = dev
    end
    if diag.actual_acceleration_available == true then
        runCtx.actual_acceleration_available = true
    elseif runCtx.actual_acceleration_available ~= true and backend == "cpu" then
        runCtx.actual_acceleration_available = false
    end
    if diag.runtime_torch_build_backend and diag.runtime_torch_build_backend ~= "" then
        runCtx.runtime_torch_build_backend = tostring(diag.runtime_torch_build_backend)
    end
end

local function getDrumKitMaxParallelJobs(runCtx)
    local device = tostring((runCtx and (runCtx.worker_requested_device or runCtx.effective_device)) or DEFAULT_DRUMKIT_DEVICE)
    local backend = tostring((runCtx and runCtx.effective_backend) or "")
    if backend ~= "cpu" and backend ~= "cuda" and backend ~= "rocm" and backend ~= "directml" and backend ~= "mps" and backend ~= "gpu" then
        backend = classifyDrumKitDevice(device)
    end
    if backend == "cuda" or backend == "rocm" or backend == "directml" or backend == "mps" or backend == "gpu" then
        return 2, "requested_" .. backend, device
    end
    if backend == "cpu" then
        return 1, "cpu", device
    end
    if runCtx and tostring(runCtx.requested_device_class or "") == "gpu" then
        return 2, "requested_gpu_pending_worker_truth", device
    end
    if runCtx and tostring(runCtx.requested_device_class or "") == "auto" and tostring(device):lower() == "auto" then
        return 2, "requested_auto_pending_worker_truth", device
    end
    return 1, "unknown", device
end

local function isWindowsHost()
    if not reaper or not reaper.GetOS then return false end
    local osName = tostring(reaper.GetOS() or "")
    return osName:find("Win", 1, true) ~= nil
end

function readTextFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function trimText(s)
    local text = tostring(s or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
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

local function extState(section, key)
    if not (reaper and reaper.GetExtState) then return "" end
    return tostring(reaper.GetExtState(section, key) or "")
end

local function extBool(section, key)
    return extState(section, key) == "1"
end

local function normalizeWorkflowMode(value)
    local v = tostring(value or ""):lower()
    if v == "drumkit" or v == "drum_kit_split" then return "drum_kit_split" end
    if v == "normal" or v == "standard" then return "standard" end
    return ""
end

local function modeFromStemwerkModel(model)
    local m = tostring(model or "")
    if m == "htdemucs_ft" then return "clean_quality" end
    if m == "htdemucs_6s" then return "clean_6stem" end
    return "clean_fast"
end

local function normalizeOutputGrouping(value)
    return tostring(value or "") == "source_track" and "source_track" or "per_item"
end

local function applyPersistedDrumKitStemSelection()
    local selectedCount = 0
    for _, stem in ipairs(STEMS) do
        local persisted = extState(STEMWERK_EXT_SECTION, "stem_drumkit_" .. stem.name)
        if persisted ~= "" then
            stem.selected = persisted == "1"
        end
        if stem.selected then selectedCount = selectedCount + 1 end
    end
    return selectedCount
end

local function benchmarkSuppressModalEnabled()
    return extBool(STEMWERK_DEV_EXT_SECTION, "suppress_modal_result")
        or extBool(STEMWERK_BENCHMARK_EXT_SECTION, "suppress_modal_result")
end

local function buildCanonicalStartOptions(modeOverride, opts)
    opts = opts or {}
    local canonical = {}
    for k, v in pairs(opts) do canonical[k] = v end

    local workflowMode = normalizeWorkflowMode(extState(STEMWERK_EXT_SECTION, "workflowMode"))
    if workflowMode ~= "drum_kit_split" then
        return nil, "Direct Drum Kit action refused: persisted STEMwerk workflowMode is '" ..
            tostring(workflowMode ~= "" and workflowMode or "missing") .. "', expected drum_kit_split."
    end

    local selectedParts = applyPersistedDrumKitStemSelection()
    if selectedParts <= 0 then
        return nil, "Direct Drum Kit action refused: no persisted Drum Kit parts are selected."
    end

    local persistedModel = extState(STEMWERK_EXT_SECTION, "model")
    local mode = tostring(modeOverride or canonical.workflow_mode or "")
    if mode == "" then mode = modeFromStemwerkModel(persistedModel) end

    local requestedDevice = tostring(canonical.requested_device or canonical.device or "")
    if requestedDevice == "" then
        requestedDevice = extState(STEMWERK_EXT_SECTION, "device")
    end
    if requestedDevice == "" then
        return nil, "Direct Drum Kit action refused: no persisted device setting found."
    end

    canonical.requested_device = requestedDevice
    canonical.requested_device_id = tostring(canonical.requested_device_id or requestedDevice)
    canonical.requested_device_class = tostring(canonical.requested_device_class or classifyDeviceClass(requestedDevice))
    canonical.effective_device = tostring(canonical.effective_device or canonical.worker_requested_device or requestedDevice)
    canonical.worker_requested_device = tostring(canonical.worker_requested_device or canonical.effective_device or requestedDevice)
    canonical.effective_backend = tostring(canonical.effective_backend or classifyDrumKitDevice(canonical.effective_device))
    canonical.output_grouping = normalizeOutputGrouping(canonical.output_grouping or extState(STEMWERK_EXT_SECTION, "outputGrouping"))
    local createFolderState = extState(STEMWERK_EXT_SECTION, "createFolder")
    canonical.use_folder = createFolderState == "" and true or createFolderState == "1"
    canonical.parallel_processing = extState(STEMWERK_EXT_SECTION, "parallelProcessing") ~= "0"
    canonical.suppressSuccessMessage = canonical.suppressSuccessMessage == true or benchmarkSuppressModalEnabled()
    canonical.suppressFailureMessage = canonical.suppressFailureMessage == true or benchmarkSuppressModalEnabled()
    if benchmarkSuppressModalEnabled() then
        canonical.async_enabled = true
        canonical.benchmark_no_modal = true
    end
    return mode, canonical
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
        launch_wrapper_path = nil,
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
        local function escPS(s)
            s = tostring(s or "")
            return s:gsub("'", "''")
        end
        local launcherPath = pathJoin(job.stage_dir, "run_bg.ps1")
        local psScript = table.concat({
            "$ErrorActionPreference = \"Continue\"",
            "$cmd = '" .. escPS(job.cmd) .. "'",
            "$stdout = '" .. escPS(job.stdout_path) .. "'",
            "$stderr = '" .. escPS(job.stderr_path) .. "'",
            "$pidFile = '" .. escPS(job.pid_file) .. "'",
            "$doneFile = '" .. escPS(job.done_file) .. "'",
            "$exitFile = '" .. escPS(job.exit_code_file) .. "'",
            "$workDir = '" .. escPS(job.cwd or job.stage_dir) .. "'",
            "New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pidFile) | Out-Null",
            "$proc = Start-Process -FilePath \"cmd.exe\" -ArgumentList @('/c', $cmd) -WorkingDirectory $workDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr",
            "Set-Content -Path $pidFile -Value ($proc.Id.ToString()) -Encoding ascii",
            "$proc.WaitForExit()",
            "$ec = $proc.ExitCode",
            "Set-Content -Path $exitFile -Value ($ec.ToString()) -Encoding ascii",
            "if ($ec -eq 0) { Set-Content -Path $doneFile -Value 'DONE' -Encoding ascii } else { Set-Content -Path $doneFile -Value 'ERROR' -Encoding ascii }",
        }, "\n") .. "\n"
        local okWritePs, errWritePs = writeTextFile(launcherPath, psScript)
        if not okWritePs then return false, errWritePs or "write_failed" end

        local wrapperPath = pathJoin(job.stage_dir, "run_hidden.vbs")
        local wrapper = io.open(wrapperPath, "w")
        if not wrapper then return false, "write_wrapper_failed" end
        local cmdLine = ("powershell -NoProfile -ExecutionPolicy Bypass -File \"%s\""):format(launcherPath)
        cmdLine = cmdLine:gsub('"', '""')
        wrapper:write('Set sh = CreateObject("WScript.Shell")\n')
        wrapper:write('cmd = "' .. cmdLine .. '"\n')
        wrapper:write('sh.Run cmd, 0, False\n')
        wrapper:close()

        job.launcher_path = launcherPath
        job.launch_wrapper_path = wrapperPath
        job.launch_cmd = 'wscript "' .. wrapperPath .. '"'
        return true, nil
    end

    local launcherPath = pathJoin(job.stage_dir, "run_bg.sh")
    local script = table.concat({
        "#!/bin/sh",
        "set +e",
        "CMD=" .. quoteArg(job.cmd),
        "STDOUT_PATH=" .. quoteArg(job.stdout_path),
        "STDERR_PATH=" .. quoteArg(job.stderr_path),
        "PID_FILE=" .. quoteArg(job.pid_file),
        "DONE_FILE=" .. quoteArg(job.done_file),
        "EXIT_FILE=" .. quoteArg(job.exit_code_file),
        "WORK_DIR=" .. quoteArg(job.cwd or job.stage_dir),
        "mkdir -p \"$(dirname \"$PID_FILE\")\"",
        "(",
        "  cd \"$WORK_DIR\" || exit 1",
        "  sh -c \"exec $CMD\" >\"$STDOUT_PATH\" 2>\"$STDERR_PATH\" &",
        "  worker_pid=$!",
        "  echo \"$worker_pid\" > \"$PID_FILE\"",
        "  wait \"$worker_pid\"",
        "  rc=$?",
        "  echo \"$rc\" > \"$EXIT_FILE\"",
        "  if [ \"$rc\" -eq 0 ]; then",
        "    echo DONE > \"$DONE_FILE\"",
        "  else",
        "    echo ERROR > \"$DONE_FILE\"",
        "  fi",
        ") &",
    }, "\n") .. "\n"
    local okWrite, errWrite = writeTextFile(launcherPath, script)
    if not okWrite then return false, errWrite or "write_failed" end
    os.execute("chmod +x " .. quoteArg(launcherPath))
    job.launcher_path = launcherPath
    job.launch_cmd = "sh " .. quoteArg(launcherPath)
    return true, nil
end

local function launchAsyncStageJob(job)
    if not job or type(job) ~= "table" then return false, "invalid_job" end
    local okLauncher, launcherErr = writeLauncherForJob(job)
    if not okLauncher then
        job.status = "failed"
        job.failure_reason = tostring(launcherErr or "launcher_write_failed")
        if logKV then logKV("async_launcher_failure_reason", job.failure_reason) end
        return false, job.failure_reason
    end
    if logKV then
        logKV("async_launcher_path", tostring(job.launcher_path or ""))
        logKV("async_launcher_cmd", tostring(job.launch_cmd or ""))
    end
    job.started_at = nowSeconds()
    local rc = runShell(job.launch_cmd)
    job.launch_exit_code = rc
    if logKV then
        logKV("async_launcher_exit", tostring(rc))
    end
    if rc == 0 then
        job.status = "running"
        job.launched_ok = true
        if logKV then logKV("async_launcher_status", "running") end
        return true, nil
    end
    job.status = "failed"
    job.launched_ok = false
    job.failure_reason = "launcher_exit_" .. tostring(rc)
    if logKV then
        logKV("async_launcher_status", "failed")
        logKV("async_launcher_failure_reason", job.failure_reason)
    end
    return false, job.failure_reason
end

local function readStageTerminalMarkers(job)
    if not job or type(job) ~= "table" then return {} end
    local pidRaw = readTextFile(job.pid_file or "")
    local doneRaw = readTextFile(job.done_file or "")
    local exitRaw = readTextFile(job.exit_code_file or "")

    local pid = tonumber(trimText(pidRaw or ""))
    local doneValue = trimText(doneRaw or "")
    local done = doneRaw ~= nil
    local exitCode = tonumber(trimText(exitRaw or ""))
    return {
        pid = pid,
        done = done,
        done_value = doneValue,
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
    if logKV and job.poll_count == 1 then
        logKV("async_poll_stage", tostring(job.stage))
        logKV("async_poll_pid_found", tostring(markers.pid_found == true))
        logKV("async_poll_done_found", tostring(markers.done_found == true))
        logKV("async_poll_exit_code_found", tostring(markers.exit_code_found == true))
        logKV("async_poll_state", "running")
    end
    if markers.pid and not job.pid then
        job.pid = markers.pid
    end
    if markers.done then
        job.finished_at = job.finished_at or nowSeconds()
        if markers.exit_code == nil then
            job.status = "failed"
            job.failure_reason = job.failure_reason or "missing_exit_code"
            if logKV then
                logKV("async_poll_stage", tostring(job.stage))
                logKV("async_poll_pid_found", tostring(markers.pid_found == true))
                logKV("async_poll_done_found", tostring(markers.done_found == true))
                logKV("async_poll_exit_code_found", tostring(markers.exit_code_found == true))
                logKV("async_poll_state", "failed")
            end
            return "failed"
        end
        job.exit_code = markers.exit_code
        if tonumber(job.exit_code) == 0 then
            job.status = "done"
            if logKV then
                logKV("async_poll_stage", tostring(job.stage))
                logKV("async_poll_pid_found", tostring(markers.pid_found == true))
                logKV("async_poll_done_found", tostring(markers.done_found == true))
                logKV("async_poll_exit_code_found", tostring(markers.exit_code_found == true))
                logKV("async_poll_state", "done")
            end
            return "done"
        end
        job.status = "failed"
        job.failure_reason = job.failure_reason or ("exit_code_" .. tostring(job.exit_code or "unknown"))
        if logKV then
            logKV("async_poll_stage", tostring(job.stage))
            logKV("async_poll_pid_found", tostring(markers.pid_found == true))
            logKV("async_poll_done_found", tostring(markers.done_found == true))
            logKV("async_poll_exit_code_found", tostring(markers.exit_code_found == true))
            logKV("async_poll_state", "failed")
        end
        return "failed"
    end
    if job.status == "cancelled" then
        if logKV then
            logKV("async_poll_stage", tostring(job.stage))
            logKV("async_poll_state", "cancelled")
        end
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
    if logKV then
        logKV("async_cancel_stage", tostring(job.stage or ""))
        logKV("async_cancel_pid_file", tostring(job.pid_file or ""))
        logKV("async_cancel_pid_found", tostring(markers.pid_found == true))
    end
    if pid <= 0 then
        if logKV then logKV("async_cancel_kill_status", "missing_pid") end
        return false, "missing_pid"
    end
    if logKV then logKV("async_cancel_pid", tostring(pid)) end
    local rc
    if isWindowsHost() then
        if logKV then logKV("async_cancel_kill_attempt", "taskkill /PID " .. tostring(math.floor(pid)) .. " /T /F") end
        rc = runShell("taskkill /PID " .. tostring(math.floor(pid)) .. " /T /F")
    else
        local pidInt = tostring(math.floor(pid))
        if logKV then logKV("async_cancel_kill_attempt", "kill -TERM " .. pidInt) end
        local termMainRc = runShell("kill -TERM " .. pidInt)
        if logKV then logKV("async_cancel_kill_attempt", "pkill -TERM -P " .. pidInt) end
        local termChildrenRc = runShell("pkill -TERM -P " .. pidInt)
        if logKV then logKV("async_cancel_kill_attempt", "kill -TERM -" .. pidInt) end
        local termGroupRc = runShell("kill -TERM -" .. pidInt)
        local sleepRc = runShell("sleep 0.2")
        local aliveRc = runShell("kill -0 " .. pidInt)
        if aliveRc == 0 then
            runShell("pkill -KILL -P " .. pidInt)
            runShell("kill -KILL -" .. pidInt)
            rc = runShell("kill -KILL " .. pidInt)
        else
            rc = 0
        end
        if logKV then
            logKV("async_cancel_term_main_rc", tostring(termMainRc))
            logKV("async_cancel_term_children_rc", tostring(termChildrenRc))
            logKV("async_cancel_term_group_rc", tostring(termGroupRc))
            logKV("async_cancel_sleep_rc", tostring(sleepRc))
            logKV("async_cancel_alive_rc", tostring(aliveRc))
            logKV("async_cancel_pid_alive_after_kill", tostring(aliveRc == 0))
        end
    end
    if rc == 0 then
        job.status = "cancelled"
        job.finished_at = job.finished_at or nowSeconds()
        job.failure_reason = "cancelled"
        if logKV then logKV("async_cancel_kill_status", "ok") end
        return true, nil
    end
    if logKV then logKV("async_cancel_kill_status", "kill_exit_" .. tostring(rc)) end
    return false, "kill_exit_" .. tostring(rc)
end

local function isAsyncCancelRequested(runCtx)
    if not runCtx or runCtx.cancel_requested == true then return true end
    if runCtx.opts and type(runCtx.opts.isCancelRequested) == "function" then
        local okCancel, isCancel = pcall(runCtx.opts.isCancelRequested)
        if okCancel and isCancel == true then
            runCtx.cancel_requested = true
            return true
        end
    end
    return false
end

local function readCleanupActions()
    local function extBool(key)
        return reaper.GetExtState and reaper.GetExtState("STEMwerk", key) == "1"
    end
    return {
        muteOriginal = extBool("muteOriginal"),
        deleteOriginal = extBool("deleteOriginal"),
        deleteOriginalTrack = extBool("deleteOriginalTrack"),
        muteOriginalTrack = extBool("muteOriginalTrack"),
        muteSelection = extBool("muteSelection"),
        deleteSelection = extBool("deleteSelection"),
    }
end

local function collectCleanupSources(sources)
    local items, itemSet = {}, {}
    local tracks, trackSet = {}, {}
    for _, src in ipairs(sources or {}) do
        local item = src and src.item or nil
        if item and reaper.ValidatePtr(item, "MediaItem*") then
            local key = tostring(item)
            if not itemSet[key] then
                itemSet[key] = true
                items[#items + 1] = src
            end
        end
        local track = src and src.track or nil
        if track and reaper.ValidatePtr(track, "MediaTrack*") then
            local key = tostring(track)
            if not trackSet[key] then
                trackSet[key] = true
                tracks[#tracks + 1] = track
            end
        end
    end
    table.sort(tracks, function(a, b)
        local ai = tonumber(reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") or 0) or 0
        local bi = tonumber(reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER") or 0) or 0
        return ai > bi
    end)
    return items, tracks
end

local function splitSourceSelection(sourceEntry)
    local item = sourceEntry and sourceEntry.item or nil
    if not (item and reaper.ValidatePtr(item, "MediaItem*")) then return nil end
    local selStart = tonumber(sourceEntry.segment_start or 0) or 0
    local selEnd = tonumber(sourceEntry.segment_end or 0) or 0
    if selEnd <= selStart then return nil end
    local itemPos = tonumber(reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0) or 0
    local itemLen = tonumber(reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0) or 0
    local itemEnd = itemPos + itemLen
    if selStart <= itemPos + 0.0001 and selEnd >= itemEnd - 0.0001 then
        return item
    end
    local middle = item
    if selStart > itemPos + 0.0001 then
        middle = reaper.SplitMediaItem(item, selStart)
    end
    if middle and reaper.ValidatePtr(middle, "MediaItem*") then
        local midPos = tonumber(reaper.GetMediaItemInfo_Value(middle, "D_POSITION") or 0) or 0
        local midLen = tonumber(reaper.GetMediaItemInfo_Value(middle, "D_LENGTH") or 0) or 0
        local midEnd = midPos + midLen
        if selEnd < midEnd - 0.0001 then
            reaper.SplitMediaItem(middle, selEnd)
        end
    end
    return middle
end

local function applyCleanupActionsToSources(sources)
    local actions = readCleanupActions()
    if not (actions.deleteOriginalTrack or actions.muteOriginalTrack or actions.deleteOriginal
            or actions.muteOriginal or actions.deleteSelection or actions.muteSelection) then
        return nil
    end
    local sourceItems, sourceTracks = collectCleanupSources(sources)
    local actionCount = 0
    if actions.deleteOriginalTrack then
        for _, track in ipairs(sourceTracks) do
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                reaper.DeleteTrack(track)
                actionCount = actionCount + 1
            end
        end
        return { action = "delete_track", count = actionCount }
    end
    if actions.muteOriginalTrack then
        for _, track in ipairs(sourceTracks) do
            if track and reaper.ValidatePtr(track, "MediaTrack*") then
                reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 1)
                actionCount = actionCount + 1
            end
        end
        return { action = "mute_track", count = actionCount }
    end
    if actions.deleteOriginal then
        for i = #sourceItems, 1, -1 do
            local item = sourceItems[i].item
            if item and reaper.ValidatePtr(item, "MediaItem*") then
                local track = reaper.GetMediaItem_Track(item)
                if track then
                    reaper.DeleteTrackMediaItem(track, item)
                    actionCount = actionCount + 1
                end
            end
        end
        return { action = "delete_original", count = actionCount }
    end
    if actions.muteOriginal then
        for _, src in ipairs(sourceItems) do
            local item = src.item
            if item and reaper.ValidatePtr(item, "MediaItem*") then
                reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
                actionCount = actionCount + 1
            end
        end
        return { action = "mute_original", count = actionCount }
    end
    if actions.deleteSelection or actions.muteSelection then
        for _, src in ipairs(sourceItems) do
            local sourceKind = tostring(src.source_kind or "")
            if sourceKind == "time_selection" or sourceKind == "selected_item_time_selection" then
                local middle = splitSourceSelection(src)
                if middle and reaper.ValidatePtr(middle, "MediaItem*") then
                    if actions.deleteSelection then
                        local track = reaper.GetMediaItem_Track(middle)
                        if track then
                            reaper.DeleteTrackMediaItem(track, middle)
                            actionCount = actionCount + 1
                        end
                    else
                        reaper.SetMediaItemInfo_Value(middle, "B_MUTE", 1)
                        actionCount = actionCount + 1
                    end
                end
            end
        end
        return { action = actions.deleteSelection and "delete_selection" or "mute_selection", count = actionCount }
    end
    return nil
end

local function createAsyncRunContext(modeOverride, opts)
    opts = opts or {}
    local mode = tostring(modeOverride or DRUMSEP_WORKFLOW_MODE or "clean_fast")
    if mode ~= "clean_fast" and mode ~= "clean_quality" and mode ~= "clean_6stem" and mode ~= "direct_creative" then
        mode = "clean_fast"
    end
    local modeLabel = folderModeLabel(mode, CLEAN_PARENT_MODELS[mode])
    local ts = os.date("%Y%m%d-%H%M%S")
    local tempRoot = tostring(opts[ASYNC_TEMP_ROOT_KEY] or makeDrumKitTempRoot(ts))
    makeDir(tempRoot)

    local scriptDir = getScriptDir()
    if logKV then logKV("async_script_dir", tostring(scriptDir or "")) end
    if not scriptDir then
        return nil, { stage = "startup", message = "Could not resolve script directory." }
    end
    local separatorScript = pathJoin(scriptDir, "audio_separator_process.py")
    if logKV then logKV("async_separator_script", tostring(separatorScript or "")) end
    if not fileExists(separatorScript) then
        return nil, { stage = "startup", message = "audio_separator_process.py not found next to script." }
    end

    local resolvedSources, resolveErr = resolveWorkflowSources({ selectedItem = opts.selectedItem })
    if not resolvedSources or #resolvedSources == 0 then
        return nil, { stage = "selection", message = resolveErr or "No valid sources resolved." }
    end

    local outputGrouping = normalizeOutputGrouping(opts.output_grouping or extState(STEMWERK_EXT_SECTION, "outputGrouping"))
    local useFolder = opts.use_folder
    if useFolder == nil then
        local createFolderState = extState(STEMWERK_EXT_SECTION, "createFolder")
        useFolder = (createFolderState == "") and true or (createFolderState == "1")
    end
    local onEvent = type(opts.onEvent) == "function" and opts.onEvent or nil
    local onComplete = type(opts.onComplete) == "function" and opts.onComplete or nil
    local selectedCount = reaper.CountSelectedMediaItems(0)
    local py = resolvePython()
    local requestedDevice = tostring(opts.requested_device or opts.device or DEFAULT_DRUMKIT_DEVICE)
    local effectiveDevice = tostring(opts.effective_device or opts.device or requestedDevice)
    local effectiveBackend = tostring(opts.effective_backend or "")
    local workerDevice = tostring(opts.worker_requested_device or effectiveDevice or DEFAULT_DRUMKIT_DEVICE)

    local runCtx = {
        mode = mode,
        mode_label = modeLabel,
        workflow_mode = mode,
        temp_root = tempRoot,
        events_path = pathJoin(tempRoot, "drumkit_events.jsonl"),
        parallel_trace_path = pathJoin(tempRoot, "drumkit_parallel_trace.log"),
        metadata_path = pathJoin(tempRoot, "drumkit_run_metadata.json"),
        script_dir = scriptDir,
        separator_script = separatorScript,
        python_bin = py,
        requested_device = requestedDevice,
        requested_device_class = classifyDeviceClass(requestedDevice),
        requested_device_id = tostring(opts.requested_device_id or requestedDevice),
        worker_requested_device = workerDevice,
        effective_device = effectiveDevice,
        effective_backend = effectiveBackend,
        actual_runtime_backend = "unknown",
        actual_torch_device = "unknown",
        actual_acceleration_available = false,
        runtime_torch_build_backend = "unknown",
        sources = resolvedSources,
        source_count = #resolvedSources,
        current_source_index = 0,
        current_source = nil,
        phase = "init",
        status = "running",
        active_job = nil,
        max_parallel_jobs = 1,
        max_parallel_reason = "unknown",
        pending_next_source_index = 1,
        active_sources = {},
        active_source_order = {},
        completed_source_count = 0,
        poll_interval = 0.25,
        next_poll_at = 0,
        started_at = nowSeconds(),
        started_at_epoch = os.time(),
        finished_at = nil,
        selected_item_count = selectedCount,
        source_resolution_mode = tostring(resolvedSources[1].source_kind or ""),
        selection_precedence = tostring(resolvedSources[1].selection_precedence_note or ""),
        output_grouping = outputGrouping,
        use_folder = useFolder,
        opts = opts,
        on_event = onEvent,
        on_complete = onComplete,
        completion_sent = false,
        cancel_requested = false,
        per_source_results = {},
        total_imported_stems = 0,
        output_folders = 0,
        output_tracks = 0,
        audio_seconds = 0,
        speed_realtime = 0,
        completed_sources = {},
        imported_items_all = {},
        imported_paths_all = {},
        aggregated_imported = {},
        aggregated_missing = {},
        imported_set = {},
        missing_set = {},
        any_failure = false,
        first_failure = nil,
        last_error_stage = nil,
        last_error_message = nil,
        last_log_path = nil,
        insert_cursor_by_track = {},
        per_track_import_layouts = {},
        processing_started = false,
    }
    local maxJobs, maxReason = getDrumKitMaxParallelJobs(runCtx)
    if opts.parallel_processing == false then
        maxJobs, maxReason = 1, "settings_sequential"
    end
    runCtx.max_parallel_jobs = maxJobs
    runCtx.max_parallel_reason = maxReason
    return runCtx, nil
end

local function emitAsyncEvent(runCtx, fields)
    if not runCtx or not fields or not fields.event or fields.event == "" then return end
    fields.ts = fields.ts or formatUtcIso(os.time())
    fields.elapsed_seconds = tonumber(fields.elapsed_seconds or (nowSeconds() - runCtx.started_at)) or 0
    fields.feature = "Drum Kit Split"
    fields.prototype = true
    fields.workflow_mode = fields.workflow_mode or runCtx.workflow_mode
    fields.mode_label = fields.mode_label or runCtx.mode_label
    fields.temp_root = fields.temp_root or runCtx.temp_root
    local okWrite, errWrite = appendTextFile(runCtx.events_path, jsonEncode(fields) .. "\n")
    if not okWrite then
        logKV("event_write_error", tostring(errWrite or "write_failed"))
    end
    if runCtx.on_event then
        local okCb, errCb = pcall(runCtx.on_event, fields)
        if not okCb then
            logKV("event_callback_error", tostring(errCb or "callback_failed"))
        end
    end
end

local function writeAsyncMetadata(runCtx, status)
    local sourcesMetadata = {}
    for idx, sourceEntry in ipairs(runCtx.sources or {}) do
        local srcRes = runCtx.per_source_results[idx] or {}
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
            stage0_dir = tostring(srcRes.stage0_dir or ""),
            stage1_dir = tostring(srcRes.stage1_dir or ""),
            stage2_dir = tostring(srcRes.stage2_dir or ""),
            imported_stems = srcRes.imported_stems or {},
            missing_stems = srcRes.missing_stems or {},
            ok = srcRes.ok == true,
            error_stage = tostring(srcRes.error_stage or ""),
            error_message = tostring(srcRes.error_message or ""),
            log_path = tostring(srcRes.log_path or ""),
            elapsed_seconds = tonumber(srcRes.elapsed_seconds or 0) or 0,
            stage1_worker_requested_device = tostring(srcRes.stage1_worker_requested_device or ""),
            stage2_worker_requested_device = tostring(srcRes.stage2_worker_requested_device or ""),
            stage1_device_diag = srcRes.stage1_device_diag or {},
            stage2_device_diag = srcRes.stage2_device_diag or {},
        }
    end

    local metadata = {
        feature = "Drum Kit Split",
        prototype = true,
        temp_root = runCtx.temp_root,
        event_log_path = runCtx.events_path,
        parallel_trace_path = runCtx.parallel_trace_path,
        status = tostring(status or ""),
        mode_label = runCtx.mode_label,
        workflow_mode = runCtx.workflow_mode,
        parent_model = CLEAN_PARENT_MODELS[runCtx.mode] or "",
        drumsep_model = STAGE2_MODEL,
        requested_device_class = tostring(runCtx.requested_device_class or "unknown"),
        requested_device_id = tostring(runCtx.requested_device_id or runCtx.requested_device or "unknown"),
        worker_requested_device = tostring(runCtx.worker_requested_device or ""),
        effective_device = tostring(runCtx.effective_device or ""),
        effective_backend = tostring(runCtx.effective_backend or "unknown"),
        actual_runtime_backend = tostring(runCtx.actual_runtime_backend or "unknown"),
        actual_torch_device = tostring(runCtx.actual_torch_device or "unknown"),
        actual_acceleration_available = runCtx.actual_acceleration_available == true,
        runtime_torch_build_backend = tostring(runCtx.runtime_torch_build_backend or "unknown"),
        source_resolution_mode = runCtx.source_resolution_mode or "",
        selection_precedence = runCtx.selection_precedence or "",
        grouping_mode = runCtx.output_grouping or "",
        folder_mode = runCtx.use_folder and "folder_on" or "folder_off",
        selected_item_count = runCtx.selected_item_count or 0,
        resolved_sources = runCtx.source_count or 0,
        total_imported_stems = runCtx.total_imported_stems or 0,
        started_at = formatUtcIso(runCtx.started_at_epoch),
        finished_at = formatUtcIso(os.time()),
        elapsed_seconds = tonumber(nowSeconds() - runCtx.started_at) or 0,
        sources = sourcesMetadata,
    }
    local okWrite, errWrite = writeTextFile(runCtx.metadata_path, jsonEncode(metadata) .. "\n")
    if not okWrite then
        logKV("run_metadata_error", tostring(errWrite or "write_failed"))
    else
        logKV("run_metadata_path", runCtx.metadata_path)
    end
end

local function notifyAsyncComplete(runCtx, status, payload)
    if not runCtx or runCtx.completion_sent then return end
    runCtx.completion_sent = true
    if not runCtx.on_complete then return end
    payload = payload or {}
    local completionResult = {
        ok = payload.ok == true,
        async = true,
        status = status,
        workflow_mode = runCtx.workflow_mode,
        mode_label = runCtx.mode_label,
        temp_root = runCtx.temp_root,
        resolved_sources = tonumber(payload.resolved_sources or runCtx.source_count or 0) or 0,
        total_imported_stems = tonumber(payload.total_imported_stems or runCtx.total_imported_stems or 0) or 0,
        output_folders = tonumber(payload.output_folders or runCtx.output_folders or 0) or 0,
        output_tracks = tonumber(payload.output_tracks or runCtx.output_tracks or runCtx.total_imported_stems or 0) or 0,
        elapsed_seconds = tonumber(payload.elapsed_seconds or (runCtx.finished_at and (runCtx.finished_at - runCtx.started_at)) or 0) or 0,
        audio_seconds = tonumber(payload.audio_seconds or runCtx.audio_seconds or 0) or 0,
        speed_realtime = tonumber(payload.speed_realtime or runCtx.speed_realtime or 0) or 0,
        error = payload.error,
        log_path = payload.log_path,
        metadata_path = runCtx.metadata_path,
        events_path = runCtx.events_path,
    }
    local okCb, errCb = pcall(runCtx.on_complete, completionResult)
    if not okCb then
        logKV("on_complete_callback_error", tostring(errCb or "callback_failed"))
    end
end

local function finishAsyncRun(runCtx, status, payload)
    if runCtx.status ~= "running" then return end
    logKV("async_finish_status", tostring(status or ""))
    logKV("async_finish_completion_sent_before", tostring(runCtx.completion_sent == true))
    payload = payload or {}
    runCtx.status = status == "cancelled" and "cancelled" or (status == "success" and "success" or "failed")
    runCtx.finished_at = nowSeconds()
    if #runCtx.imported_items_all > 0 then
        refreshImportedMediaItems(runCtx.imported_items_all, runCtx.imported_paths_all)
    end
    if runCtx.processing_started then
        reaper.PreventUIRefresh(-1)
        runCtx.processing_started = false
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("STEMwerk: Drum Kit Split", -1)
    else
        reaper.UpdateArrange()
    end

    writeAsyncMetadata(runCtx, status)
    emitAsyncEvent(runCtx, {
        event = "run_done",
        status = status,
        resolved_sources = runCtx.source_count,
        total_imported_stems = runCtx.total_imported_stems,
        elapsed_seconds = tonumber(nowSeconds() - runCtx.started_at) or 0,
        error_message = payload.error or "",
        log_path = payload.log_path or "",
    })
    notifyAsyncComplete(runCtx, status, {
        ok = status == "success",
        resolved_sources = runCtx.source_count,
        total_imported_stems = runCtx.total_imported_stems,
        output_folders = runCtx.output_folders,
        output_tracks = runCtx.output_tracks,
        elapsed_seconds = tonumber(runCtx.finished_at and (runCtx.finished_at - runCtx.started_at) or 0) or 0,
        audio_seconds = runCtx.audio_seconds,
        speed_realtime = runCtx.speed_realtime,
        error = payload.error,
        log_path = payload.log_path,
    })
    if currentDrumKitAsyncRun == runCtx then
        currentDrumKitAsyncRun = nil
        if rawget(_G, "STEMWERK_DRUMKIT_CURRENT_ASYNC_RUN") == runCtx then
            _G.STEMWERK_DRUMKIT_CURRENT_ASYNC_RUN = nil
        end
    end
end

local function clearPendingAsyncSources(runCtx)
    if not runCtx then return end
    runCtx.pending_next_source_index = (tonumber(runCtx.source_count or 0) or 0) + 1
end

local function killActiveSourceJobs(runCtx, keepSourceCtx)
    if not runCtx then return end
    for _, sourceCtx in ipairs(runCtx.active_source_order or {}) do
        if sourceCtx ~= keepSourceCtx then
            local job = sourceCtx and sourceCtx.active_job
            if job and job.status == "running" then
                local okKill, killErr = killAsyncStageJob(job)
                if not okKill then
                    logKV("async_cancel_kill_error", tostring(killErr or "kill_failed"))
                end
            end
        end
    end
    runCtx.active_sources = {}
    runCtx.active_source_order = {}
    runCtx.active_job = nil
end

local function failAsyncRun(runCtx, stage, errMsg, logPath)
    appendParallelTrace(
        runCtx,
        "failure source=" .. tostring(runCtx and runCtx.current_source_index or "")
            .. " stage=" .. tostring(stage or "")
            .. " active=[" .. activeSourceIndexList(runCtx) .. "]"
            .. " pending=" .. tostring(pendingSourceCount(runCtx))
    )
    clearPendingAsyncSources(runCtx)
    killActiveSourceJobs(runCtx)
    runCtx.last_error_stage = stage
    runCtx.last_error_message = errMsg
    runCtx.last_log_path = logPath
    emitAsyncEvent(runCtx, {
        event = "failure",
        stage = tostring(stage or ""),
        status = "failed",
        error_message = tostring(errMsg or ""),
        log_path = tostring(logPath or ""),
    })
    finishAsyncRun(runCtx, "failed", {
        error = tostring(errMsg or "Async pipeline failed."),
        log_path = logPath,
    })
end

local function cancelAsyncRun(runCtx, reason)
    if not runCtx or runCtx.status ~= "running" then return end
    runCtx.cancel_requested = true
    logKV("async_cancel_enter", "1")
    logKV("async_cancel_requested", "true")
    logKV("async_cancel_phase", tostring(runCtx.phase or ""))
    logKV("async_cancel_status", tostring(runCtx.status or ""))
    logKV("async_cancel_reason", tostring(reason or "cancelled"))
    logKV("async_cancel_active_job", tostring(runCtx.active_job ~= nil))
    logKV("async_cancel_active_source_count", tostring(#(runCtx.active_source_order or {})))
    for _, sourceCtx in ipairs(runCtx.active_source_order or {}) do
        if sourceCtx and sourceCtx.active_job then
            logKV("async_cancel_active_job_stage", tostring(sourceCtx.active_job.stage or ""))
        end
    end
    appendParallelTrace(
        runCtx,
        "cancel active=[" .. activeSourceIndexList(runCtx) .. "]"
            .. " pending=" .. tostring(pendingSourceCount(runCtx))
    )
    clearPendingAsyncSources(runCtx)
    killActiveSourceJobs(runCtx)
    emitAsyncEvent(runCtx, {
        event = "run_cancelled",
        status = "cancelled",
        error_message = tostring(reason or "cancelled"),
    })
    finishAsyncRun(runCtx, "cancelled", { error = reason or "Cancelled by user." })
end

local function cancelCurrentDrumKitAsyncRun(reason)
    local runCtx = currentDrumKitAsyncRun
    if not runCtx or runCtx.status ~= "running" then
        return false
    end
    runCtx.cancel_requested = true
    cancelAsyncRun(runCtx, reason or "Cancelled by user.")
    return true
end

local function buildSourceAsyncContext(runCtx, sourceEntry, sourceIndex)
    local idx = tonumber(sourceIndex or runCtx.current_source_index or 1) or 1
    local sourcePrefix = string.format("source_%03d", idx)
    local root = pathJoin(runCtx.temp_root, sourcePrefix)
    local stage0 = pathJoin(root, "stage0_input")
    local stage1Fast = pathJoin(root, "stage1_htdemucs")
    local stage1Quality = pathJoin(root, "stage1_htdemucs_ft")
    local stage16Stem = pathJoin(root, "stage1_htdemucs_6s")
    local stage2 = pathJoin(root, "stage2_drumsep")
    local stage1Direct = pathJoin(root, "stage1_direct_drumsep")
    makeDir(root); makeDir(stage0); makeDir(stage1Fast); makeDir(stage1Quality); makeDir(stage16Stem); makeDir(stage2); makeDir(stage1Direct)

    local stage1OutputDir = stage1Fast
    local parentModel = nil
    if runCtx.mode == "clean_quality" then
        parentModel = CLEAN_PARENT_MODELS.clean_quality
        stage1OutputDir = stage1Quality
    elseif runCtx.mode == "clean_6stem" then
        parentModel = CLEAN_PARENT_MODELS.clean_6stem
        stage1OutputDir = stage16Stem
    elseif runCtx.mode == "clean_fast" then
        parentModel = CLEAN_PARENT_MODELS.clean_fast
        stage1OutputDir = stage1Fast
    end

    local inputWav = pathJoin(stage0, "input.wav")
    local ffLog = pathJoin(stage0, "ffmpeg_extract.log")
    local ffStdout = pathJoin(stage0, "cmd_stdout.txt")
    local stage1Stdout = pathJoin(stage1OutputDir, "cmd_stdout.txt")
    local stage1Stderr = pathJoin(stage1OutputDir, "cmd_stderr.txt")
    local stage2OutputDir = runCtx.mode == "direct_creative" and stage1Direct or stage2
    local stage2Stdout = pathJoin(stage2OutputDir, "cmd_stdout.txt")
    local stage2Stderr = pathJoin(stage2OutputDir, "cmd_stderr.txt")
    local drumsWav = pathJoin(stage1OutputDir, "drums.wav")

    local stage1Cmd = ""
    local ffCmd = string.format(
        "%s -y -hide_banner -nostats -loglevel error -i %s -ss %.6f -t %.6f -ar 44100 -ac 2 %s",
        quoteArg(FFMPEG_BIN),
        quoteArg(sourceEntry.source_path),
        sourceEntry.extract_offset,
        sourceEntry.extract_duration,
        quoteArg(inputWav)
    )
    if runCtx.mode ~= "direct_creative" then
        stage1Cmd = table.concat({
            quoteArg(runCtx.python_bin), quoteArg(runCtx.separator_script), quoteArg(inputWav), quoteArg(stage1OutputDir),
            "--model", quoteArg(parentModel), "--device", quoteArg(runCtx.worker_requested_device or runCtx.effective_device or DEFAULT_DRUMKIT_DEVICE)
        }, " ")
    end
    local stage2Input = runCtx.mode == "direct_creative" and inputWav or drumsWav
    local stage2Cmd = table.concat({
        quoteArg(runCtx.python_bin), quoteArg(runCtx.separator_script), quoteArg(stage2Input), quoteArg(stage2OutputDir),
        "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(runCtx.worker_requested_device or runCtx.effective_device or DEFAULT_DRUMKIT_DEVICE)
    }, " ")

    local trackLabel = sanitizeTrackLabel(sourceEntry.track_name or "", sourceEntry.track_index or idx)
    local sourceLabel = sanitizeSourceLabel(sourceEntry.source_label or "", sourceIndexLabel(idx))
    local modeLabel = folderModeLabel(runCtx.mode, parentModel)
    local folderLabel = string.format("%s - %s - Drum Kit Split - %s", trackLabel, sourceLabel, modeLabel)
    local sharedLayout = nil
    if runCtx.output_grouping == "source_track" and sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
        local trackKey = tostring(sourceEntry.track)
        sharedLayout = runCtx.per_track_import_layouts[trackKey]
        if not sharedLayout then
            sharedLayout = {
                grouping_mode = "source_track",
                folder_label = string.format("%s - Drum Kit Split - %s", trackLabel, modeLabel),
            }
            runCtx.per_track_import_layouts[trackKey] = sharedLayout
        end
        folderLabel = sharedLayout.folder_label
    end

    local insertAtIndex = nil
    if sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
        local trackKey = tostring(sourceEntry.track)
        if runCtx.insert_cursor_by_track[trackKey] == nil then
            local currentTrackNumber = math.floor(reaper.GetMediaTrackInfo_Value(sourceEntry.track, "IP_TRACKNUMBER") or 0)
            runCtx.insert_cursor_by_track[trackKey] = math.max(0, currentTrackNumber)
        end
        insertAtIndex = runCtx.insert_cursor_by_track[trackKey]
    end

    return {
        index = idx,
        source_entry = sourceEntry,
        source_label = sourceLabel,
        track_label = trackLabel,
        source_root = root,
        stage0_dir = stage0,
        stage0_input_path = inputWav,
        ffmpeg_log_path = ffLog,
        stage0_cmd = ffCmd,
        stage0_stdout = ffStdout,
        stage1_dir = stage1OutputDir,
        stage2_dir = stage2OutputDir,
        stage1_cmd = stage1Cmd,
        stage2_cmd = stage2Cmd,
        stage1_worker_requested_device = parseCommandDevice(stage1Cmd),
        stage2_worker_requested_device = parseCommandDevice(stage2Cmd),
        stage1_stdout = stage1Stdout,
        stage1_stderr = stage1Stderr,
        stage2_stdout = stage2Stdout,
        stage2_stderr = stage2Stderr,
        stage2_input = stage2Input,
        drums_wav = drumsWav,
        parent_model = parentModel,
        folder_label = folderLabel,
        shared_layout = sharedLayout,
        insert_at_index = insertAtIndex,
        source_t0 = nowSeconds(),
        stage1_exit_code = nil,
        stage2_exit_code = nil,
    }
end

local function launchCurrentStageJob(runCtx, sourceCtx, stageName)
    local cmd, stageDir, stdoutPath, stderrPath, logPath, phaseEventsPath
    if stageName == "stage0_extract" then
        cmd = sourceCtx.stage0_cmd
        stageDir = sourceCtx.stage0_dir
        stdoutPath = sourceCtx.stage0_stdout
        stderrPath = sourceCtx.ffmpeg_log_path
        logPath = sourceCtx.ffmpeg_log_path
        phaseEventsPath = pathJoin(sourceCtx.stage0_dir, "phase_events.jsonl")
    elseif stageName == "stage1_parent" then
        cmd = sourceCtx.stage1_cmd
        stageDir = sourceCtx.stage1_dir
        stdoutPath = sourceCtx.stage1_stdout
        stderrPath = sourceCtx.stage1_stderr
        logPath = pathJoin(sourceCtx.stage1_dir, "separation_log.txt")
        phaseEventsPath = pathJoin(sourceCtx.stage1_dir, "phase_events.jsonl")
    else
        cmd = sourceCtx.stage2_cmd
        stageDir = sourceCtx.stage2_dir
        stdoutPath = sourceCtx.stage2_stdout
        stderrPath = sourceCtx.stage2_stderr
        logPath = pathJoin(sourceCtx.stage2_dir, "separation_log.txt")
        phaseEventsPath = pathJoin(sourceCtx.stage2_dir, "phase_events.jsonl")
    end
    local job = buildAsyncStageJob(
        { source_index = sourceCtx.index, source_count = runCtx.source_count },
        stageName,
        cmd,
        stageDir,
        stdoutPath,
        stderrPath,
        { log_path = logPath, phase_events_path = phaseEventsPath }
    )
    local okLaunch, launchErr = launchAsyncStageJob(job)
    if not okLaunch then
        return nil, launchErr
    end
    logKV("async_launch_stage", tostring(stageName))
    logKV("async_launch_cmd", tostring(cmd or ""))
    logKV("async_launch_stage_dir", tostring(stageDir or ""))
    logKV("async_launch_pid_file", tostring(job.pid_file or ""))
    logKV("async_launch_done_file", tostring(job.done_file or ""))
    logKV("async_launch_exit_code_file", tostring(job.exit_code_file or ""))
    sourceCtx.phase = stageName .. "_poll"
    sourceCtx.active_job = job
    runCtx.active_job = job
    emitAsyncEvent(runCtx, {
        event = stageName .. "_start",
        stage = stageName,
        status = "start",
        source_index = sourceCtx.index,
        source_count = runCtx.source_count,
        running_sources = #(runCtx.active_source_order or {}),
        completed_sources = tonumber(runCtx.completed_source_count or 0) or 0,
        track_label = sourceCtx.track_label,
        source_label = sourceCtx.source_label,
        pid_file = job.pid_file,
        done_file = job.done_file,
        exit_code_file = job.exit_code_file,
        launcher_path = job.launcher_path,
        launch_wrapper_path = job.launch_wrapper_path,
        stdout_path = job.stdout_path,
        stderr_path = job.stderr_path,
        log_path = job.log_path,
        phase_events_path = job.phase_events_path,
        parent_model = sourceCtx.parent_model or "",
        drumsep_model = STAGE2_MODEL,
    })
    if stageName == "stage0_extract" then
        appendParallelTrace(runCtx, "stage0_start source=" .. tostring(sourceCtx.index))
    elseif stageName == "stage2_drumsep" then
        appendParallelTrace(runCtx, "stage2_start source=" .. tostring(sourceCtx.index) .. " pid=" .. tostring(job.pid or "pending"))
    end
    return job, nil
end

local function pollCurrentStageJob(runCtx, sourceCtx)
    sourceCtx = sourceCtx or runCtx.current_source
    local job = sourceCtx and sourceCtx.active_job or runCtx.active_job
    if not job then return "failed", "missing_active_job" end
    local pollState = pollAsyncStageJob(job)
    if job.stage == "stage2_drumsep" and job.pid and not sourceCtx.stage2_pid_traced then
        sourceCtx.stage2_pid_traced = true
        appendParallelTrace(runCtx, "stage2_start source=" .. tostring(sourceCtx.index) .. " pid=" .. tostring(job.pid))
    end
    if pollState == "running" then
        return "running", nil
    end
    local summary = finalizeAsyncStageJob(job)
    if pollState == "done" and summary.ok then
        if job.stage == "stage1_parent" or job.stage == "stage2_drumsep" then
            local diag = parseWorkerDiagnostics(summary.stderr_path, job.cmd)
            if job.stage == "stage1_parent" then
                sourceCtx.stage1_device_diag = diag
            else
                sourceCtx.stage2_device_diag = diag
            end
            mergeRunDeviceTruth(runCtx, diag)
            emitAsyncEvent(runCtx, {
                event = job.stage .. "_device",
                stage = job.stage,
                status = "done",
                source_index = sourceCtx.index,
                source_count = runCtx.source_count,
                requested_device_class = runCtx.requested_device_class,
                requested_device_id = runCtx.requested_device_id,
                worker_requested_device = diag.worker_requested_device or "",
                actual_runtime_backend = diag.actual_runtime_backend or "unknown",
                actual_torch_device = diag.actual_torch_device or "unknown",
                actual_acceleration_available = diag.actual_acceleration_available == true,
                runtime_torch_build_backend = diag.runtime_torch_build_backend or "unknown",
                torch_version = diag.torch_version or "",
            })
            appendParallelTrace(
                runCtx,
                "device_truth source=" .. tostring(sourceCtx.index)
                    .. " stage=" .. tostring(job.stage)
                    .. " worker_requested_device=" .. tostring(diag.worker_requested_device or "")
                    .. " actual_runtime_backend=" .. tostring(diag.actual_runtime_backend or "unknown")
                    .. " actual_torch_device=" .. tostring(diag.actual_torch_device or "unknown")
                    .. " actual_acceleration_available=" .. tostring(diag.actual_acceleration_available == true)
            )
        end
        local ev = "stage2_drumsep_done"
        if job.stage == "stage0_extract" then
            ev = "stage0_extract_done"
        elseif job.stage == "stage1_parent" then
            ev = "stage1_parent_done"
        end
        emitAsyncEvent(runCtx, {
            event = ev,
            stage = job.stage,
            status = "done",
            source_index = sourceCtx.index,
            source_count = runCtx.source_count,
            running_sources = #(runCtx.active_source_order or {}),
            completed_sources = tonumber(runCtx.completed_source_count or 0) or 0,
            track_label = sourceCtx.track_label,
            source_label = sourceCtx.source_label,
            pid_file = summary.pid_file,
            done_file = summary.done_file,
            exit_code_file = summary.exit_code_file,
            launcher_path = summary.launcher_path,
            stdout_path = summary.stdout_path,
            stderr_path = summary.stderr_path,
            log_path = summary.log_path,
            phase_events_path = summary.phase_events_path,
            exit_code = summary.exit_code,
        })
        if job.stage == "stage0_extract" then
            if not fileExists(sourceCtx.stage0_input_path) then
                return "failed", "stage0_done_without_input_wav"
            end
            appendParallelTrace(runCtx, "stage0_done source=" .. tostring(sourceCtx.index))
        elseif job.stage == "stage1_parent" then
            sourceCtx.stage1_exit_code = summary.exit_code
            if runCtx.mode ~= "direct_creative" and not fileExists(sourceCtx.drums_wav) then
                return "failed", "stage1_done_without_drums_wav"
            end
        else
            sourceCtx.stage2_exit_code = summary.exit_code
            appendParallelTrace(runCtx, "stage2_done source=" .. tostring(sourceCtx.index))
        end
        sourceCtx.active_job = nil
        if runCtx.active_job == job then runCtx.active_job = nil end
        return "done", nil
    end
    sourceCtx.active_job = nil
    if runCtx.active_job == job then runCtx.active_job = nil end
    if pollState == "cancelled" then
        return "cancelled", summary.failure_reason or "cancelled"
    end
    return "failed", summary.failure_reason or "stage_failed"
end

local function startAsyncSource(runCtx, sourceIndex)
    if isAsyncCancelRequested(runCtx) then
        cancelAsyncRun(runCtx, "Cancelled before source start.")
        return nil
    end
    local idx = tonumber(sourceIndex or runCtx.pending_next_source_index or 1) or 1
    local sourceEntry = runCtx.sources[idx]
    if not sourceEntry then
        return nil
    end
    local sourceCtx = buildSourceAsyncContext(runCtx, sourceEntry, idx)
    runCtx.current_source = sourceCtx
    runCtx.current_source_index = idx
    emitAsyncEvent(runCtx, {
        event = "source_start",
        status = "start",
        source_index = idx,
        source_count = runCtx.source_count,
        running_sources = #(runCtx.active_source_order or {}) + 1,
        completed_sources = tonumber(runCtx.completed_source_count or 0) or 0,
        track_label = sourceCtx.track_label,
        source_label = sourceCtx.source_label,
        source_kind = tostring(sourceEntry.source_kind or ""),
        segment_start = tonumber(sourceEntry.segment_start or 0) or 0,
        segment_length = tonumber(sourceEntry.segment_length or 0) or 0,
        extract_offset = tonumber(sourceEntry.extract_offset or 0) or 0,
        extract_duration = tonumber(sourceEntry.extract_duration or 0) or 0,
        take_playrate = tonumber(sourceEntry.take_playrate or 1.0) or 1.0,
        take_pitch = tonumber(sourceEntry.take_pitch or 0.0) or 0.0,
        take_preserve_pitch = (tonumber(sourceEntry.take_preserve_pitch or 0) or 0) ~= 0,
    })
    sourceCtx.phase = "stage0_launch"
    runCtx.active_sources[idx] = sourceCtx
    runCtx.active_source_order[#runCtx.active_source_order + 1] = sourceCtx
    appendParallelTrace(
        runCtx,
        "start_source source=" .. tostring(idx)
            .. " active=" .. tostring(#(runCtx.active_source_order or {}))
            .. " active_indices=[" .. activeSourceIndexList(runCtx) .. "]"
            .. " pending=" .. tostring(pendingSourceCount(runCtx))
    )
    return sourceCtx
end

local function buildCompletedSourceResult(runCtx, sourceCtx)
    local sourceEntry = sourceCtx.source_entry
    return {
        ok = true,
        source_kind = sourceEntry.source_kind,
        source_path = sourceEntry.source_path,
        source_label = sourceCtx.source_label,
        source_index = sourceCtx.index,
        track_name = sourceEntry.track_name,
        segment_start = sourceEntry.segment_start,
        segment_length = sourceEntry.segment_length,
        temp_root = sourceCtx.source_root,
        stage0_input_path = sourceCtx.stage0_input_path,
        stage1_output_dir = runCtx.mode == "direct_creative" and "skipped" or sourceCtx.stage1_dir,
        stage2_output_dir = sourceCtx.stage2_dir,
        stage1_cmd = runCtx.mode == "direct_creative" and "skipped" or sourceCtx.stage1_cmd,
        stage2_cmd = sourceCtx.stage2_cmd,
        stage1_worker_requested_device = runCtx.mode == "direct_creative" and "skipped" or sourceCtx.stage1_worker_requested_device,
        stage2_worker_requested_device = sourceCtx.stage2_worker_requested_device,
        stage1_device_diag = sourceCtx.stage1_device_diag or {},
        stage2_device_diag = sourceCtx.stage2_device_diag or {},
        stage1_exit_code = runCtx.mode == "direct_creative" and -1 or sourceCtx.stage1_exit_code,
        stage2_exit_code = sourceCtx.stage2_exit_code,
        imported_stems = {},
        missing_stems = {},
        inserted_track_count = 0,
        import_summary = "",
        imported_items = {},
        imported_paths = {},
        elapsed_seconds = nowSeconds() - sourceCtx.source_t0,
        error_stage = nil,
        error_message = nil,
        log_path = nil,
        stage0_dir = sourceCtx.stage0_dir,
        stage1_dir = runCtx.mode == "direct_creative" and "skipped" or sourceCtx.stage1_dir,
        stage2_dir = sourceCtx.stage2_dir,
    }
end

local function recordCompletedSource(runCtx, sourceCtx)
    local sourceResult = buildCompletedSourceResult(runCtx, sourceCtx)
    runCtx.completed_sources[#runCtx.completed_sources + 1] = {
        index = sourceCtx.index,
        source_ctx = sourceCtx,
        source_entry = sourceCtx.source_entry,
        result = sourceResult,
    }
    runCtx.per_source_results[sourceCtx.index] = sourceResult
    runCtx.completed_source_count = (tonumber(runCtx.completed_source_count or 0) or 0) + 1
    runCtx.audio_seconds = (tonumber(runCtx.audio_seconds or 0) or 0) + (tonumber(sourceCtx.source_entry and sourceCtx.source_entry.extract_duration or 0) or 0)
    appendParallelTrace(
        runCtx,
        "complete_source source=" .. tostring(sourceCtx.index)
            .. " completed=" .. tostring(runCtx.completed_source_count) .. "/" .. tostring(runCtx.source_count)
    )
    emitAsyncEvent(runCtx, {
        event = "source_done",
        status = "processed",
        source_index = sourceCtx.index,
        source_count = runCtx.source_count,
        running_sources = #(runCtx.active_source_order or {}),
        completed_sources = tonumber(runCtx.completed_source_count or 0) or 0,
        track_label = sourceCtx.track_label,
        source_label = sourceCtx.source_label,
        stage2_dir = sourceCtx.stage2_dir,
        source_elapsed_seconds = tonumber(sourceResult.elapsed_seconds or 0) or 0,
    })
end

local function importCompletedSources(runCtx)
    if isAsyncCancelRequested(runCtx) then
        logKV("async_cancel_import_skipped", "true")
        cancelAsyncRun(runCtx, "Cancelled before import.")
        return false
    end
    appendParallelTrace(runCtx, "batch_import_start completed=" .. tostring(#runCtx.completed_sources))
    emitAsyncEvent(runCtx, {
        event = "import_start",
        stage = "import",
        status = "start",
        source_count = runCtx.source_count,
        completed_sources = #runCtx.completed_sources,
    })
    if not runCtx.processing_started then
        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)
        runCtx.processing_started = true
    end
    runCtx.batch_insert_cursor_by_track = {}
    table.sort(runCtx.completed_sources, function(a, b)
        return (tonumber(a.index or 0) or 0) < (tonumber(b.index or 0) or 0)
    end)
    for _, completed in ipairs(runCtx.completed_sources) do
        if runCtx.status ~= "running" then return false end
        if isAsyncCancelRequested(runCtx) then
            cancelAsyncRun(runCtx, "Cancelled during import.")
            return false
        end
        local sourceCtx = completed.source_ctx
        local sourceEntry = completed.source_entry
        local sourceIndex = tonumber(completed.index or 0) or 0
        emitAsyncEvent(runCtx, {
            event = "source_import_start",
            stage = "import",
            status = "start",
            source_index = sourceIndex,
            source_count = runCtx.source_count,
            track_label = sourceCtx.track_label,
            source_label = sourceCtx.source_label,
            stage_dir = sourceCtx.stage2_dir,
        })
        local insertAtIndex = sourceCtx.insert_at_index
        if sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
            local trackKey = tostring(sourceEntry.track)
            if runCtx.batch_insert_cursor_by_track[trackKey] == nil then
                local currentTrackNumber = math.floor(reaper.GetMediaTrackInfo_Value(sourceEntry.track, "IP_TRACKNUMBER") or 0)
                runCtx.batch_insert_cursor_by_track[trackKey] = math.max(0, currentTrackNumber)
            end
            insertAtIndex = runCtx.batch_insert_cursor_by_track[trackKey]
        end
        local okImport, importSummary = importDrumKitSplit(
            sourceCtx.stage2_dir,
            sourceCtx.folder_label,
            sourceEntry,
            {
                useFolder = runCtx.use_folder,
                insertAtIndex = insertAtIndex,
                modeLabel = runCtx.mode_label,
                sourceIndex = sourceIndex,
                groupingMode = runCtx.output_grouping,
                sharedLayout = sourceCtx.shared_layout,
                isCancelRequested = function()
                    return isAsyncCancelRequested(runCtx)
                end,
            }
        )
        local sourceResult = completed.result or buildCompletedSourceResult(runCtx, sourceCtx)
        sourceResult.ok = okImport and true or false
        sourceResult.imported_stems = importSummary and importSummary.imported or {}
        sourceResult.missing_stems = importSummary and importSummary.missing or {}
        sourceResult.inserted_track_count = tonumber(importSummary and importSummary.insertedTrackCount or 0) or 0
        sourceResult.import_summary = tostring(importSummary and importSummary.message or "")
        sourceResult.imported_items = importSummary and importSummary.importedItems or {}
        sourceResult.imported_paths = importSummary and importSummary.importedPaths or {}
        sourceResult.elapsed_seconds = nowSeconds() - sourceCtx.source_t0
        if importSummary and importSummary.cancelled == true then
            runCtx.per_source_results[sourceIndex] = sourceResult
            cancelAsyncRun(runCtx, "Cancelled during import.")
            return false
        end
        if not sourceResult.ok then
            sourceResult.error_stage = "import"
            sourceResult.error_message = "Import failed."
            sourceResult.log_path = sourceCtx.stage2_stderr
            runCtx.per_source_results[sourceIndex] = sourceResult
            failAsyncRun(runCtx, "import", sourceResult.error_message, sourceResult.log_path)
            return false
        end
        runCtx.total_imported_stems = runCtx.total_imported_stems + #(sourceResult.imported_stems or {})
        runCtx.output_tracks = runCtx.total_imported_stems
        if runCtx.use_folder then
            if runCtx.output_grouping == "source_track" then
                runCtx.output_folders = 0
                for _, layout in pairs(runCtx.per_track_import_layouts or {}) do
                    if layout.initialized and layout.use_folder then
                        runCtx.output_folders = runCtx.output_folders + 1
                    end
                end
            else
                runCtx.output_folders = runCtx.output_folders + 1
            end
        end
        for _, it in ipairs(sourceResult.imported_items or {}) do
            runCtx.imported_items_all[#runCtx.imported_items_all + 1] = it
        end
        for _, p in ipairs(sourceResult.imported_paths or {}) do
            runCtx.imported_paths_all[#runCtx.imported_paths_all + 1] = p
        end
        for _, stemName in ipairs(sourceResult.imported_stems or {}) do
            if not runCtx.imported_set[stemName] then
                runCtx.imported_set[stemName] = true
                runCtx.aggregated_imported[#runCtx.aggregated_imported + 1] = stemName
            end
        end
        for _, stemName in ipairs(sourceResult.missing_stems or {}) do
            if not runCtx.missing_set[stemName] then
                runCtx.missing_set[stemName] = true
                runCtx.aggregated_missing[#runCtx.aggregated_missing + 1] = stemName
            end
        end
        if sourceEntry.track and reaper.ValidatePtr(sourceEntry.track, "MediaTrack*") then
            local trackKey = tostring(sourceEntry.track)
            local added = tonumber(sourceResult.inserted_track_count or 0) or 0
            if runCtx.batch_insert_cursor_by_track[trackKey] ~= nil and added > 0 then
                runCtx.batch_insert_cursor_by_track[trackKey] = runCtx.batch_insert_cursor_by_track[trackKey] + added
            end
        end
        runCtx.per_source_results[sourceIndex] = sourceResult
        emitAsyncEvent(runCtx, {
            event = "import_done",
            stage = "import",
            status = "done",
            source_index = sourceIndex,
            source_count = runCtx.source_count,
            track_label = sourceCtx.track_label,
            source_label = sourceCtx.source_label,
            imported_stems = sourceResult.imported_stems,
            missing_stems = sourceResult.missing_stems,
            imported_count = #(sourceResult.imported_stems or {}),
        })
    end
    local cleanupSummary = applyCleanupActionsToSources(runCtx.sources)
    if cleanupSummary then
        runCtx.cleanup_action = cleanupSummary.action
        runCtx.cleanup_count = cleanupSummary.count
        logKV("cleanup_action", tostring(cleanupSummary.action or ""))
        logKV("cleanup_count", tostring(cleanupSummary.count or 0))
    end
    local elapsed = tonumber(nowSeconds() - runCtx.started_at) or 0
    local audioSeconds = tonumber(runCtx.audio_seconds or 0) or 0
    if elapsed > 0 and audioSeconds > 0 then
        runCtx.speed_realtime = audioSeconds / elapsed
    end
    emitAsyncEvent(runCtx, {
        event = "import_done",
        stage = "import",
        status = "done",
        source_count = runCtx.source_count,
        total_imported_stems = runCtx.total_imported_stems,
        output_folders = runCtx.output_folders,
        output_tracks = runCtx.output_tracks,
    })
    return true
end

local function removeActiveSource(runCtx, sourceCtx)
    if not runCtx or not sourceCtx then return end
    runCtx.active_sources[sourceCtx.index] = nil
    local kept = {}
    for _, active in ipairs(runCtx.active_source_order or {}) do
        if active ~= sourceCtx then
            kept[#kept + 1] = active
        end
    end
    runCtx.active_source_order = kept
    if runCtx.current_source == sourceCtx then
        runCtx.current_source = runCtx.active_source_order[1]
    end
    if sourceCtx.active_job and runCtx.active_job == sourceCtx.active_job then
        runCtx.active_job = nil
    end
end

local function emitAsyncSchedulerStatus(runCtx)
    if not runCtx then return end
    local completed = tonumber(runCtx.completed_source_count or 0) or 0
    local total = tonumber(runCtx.source_count or 0) or 0
    local running = #(runCtx.active_source_order or {})
    local pending = math.max(0, total - completed - running)
    local signature = table.concat({ tostring(running), tostring(completed), tostring(total), tostring(pending) }, "/")
    if runCtx.last_scheduler_status_signature == signature then return end
    runCtx.last_scheduler_status_signature = signature
    appendParallelTrace(
        runCtx,
        "poll_active active=[" .. activeSourceIndexList(runCtx) .. "]"
            .. " completed=" .. tostring(completed) .. "/" .. tostring(total)
            .. " pending=" .. tostring(pending)
    )
    emitAsyncEvent(runCtx, {
        event = "source_queue_status",
        status = "running",
        source_count = total,
        completed_sources = completed,
        running_sources = running,
        active_source_indices = activeSourceIndexList(runCtx),
        pending_sources = pending,
        max_parallel_jobs = tonumber(runCtx.max_parallel_jobs or 1) or 1,
    })
end

local function startPendingAsyncSources(runCtx)
    local maxJobs = tonumber(runCtx.max_parallel_jobs or 1) or 1
    if maxJobs < 1 then maxJobs = 1 end
    while runCtx.status == "running"
        and not isAsyncCancelRequested(runCtx)
        and #(runCtx.active_source_order or {}) < maxJobs
        and (tonumber(runCtx.pending_next_source_index or 1) or 1) <= (tonumber(runCtx.source_count or 0) or 0)
    do
        local idx = tonumber(runCtx.pending_next_source_index or 1) or 1
        runCtx.pending_next_source_index = idx + 1
        local sourceCtx = startAsyncSource(runCtx, idx)
        if runCtx.status ~= "running" then return false end
        if not sourceCtx then return false end
        logKV("async_scheduler_started_source", tostring(idx))
        logKV("async_scheduler_active_sources", tostring(#(runCtx.active_source_order or {})))
    end
    return true
end

local function advanceAsyncSource(runCtx, sourceCtx)
    if not sourceCtx then return "failed", "missing_source_context" end
    runCtx.current_source = sourceCtx
    runCtx.current_source_index = sourceCtx.index
    local phase = tostring(sourceCtx.phase or "")
    if phase == "stage0_launch" then
        local _, launchErr = launchCurrentStageJob(runCtx, sourceCtx, "stage0_extract")
        if launchErr then
            return "failed", "Stage 0 launch failed: " .. tostring(launchErr), "stage0_extract", sourceCtx.ffmpeg_log_path
        end
        return "running", nil
    end
    if phase == "stage0_extract_poll" then
        local state, err = pollCurrentStageJob(runCtx, sourceCtx)
        if state == "running" then return "running", nil end
        if state == "done" then
            sourceCtx.phase = runCtx.mode == "direct_creative" and "stage2_launch" or "stage1_launch"
            return "running", nil
        end
        if state == "cancelled" then
            return "cancelled", err or "Cancelled"
        end
        return "failed", "Stage 0 failed: " .. tostring(err or "unknown"), "stage0_extract", sourceCtx.ffmpeg_log_path
    end
    if phase == "stage1_launch" then
        local _, launchErr = launchCurrentStageJob(runCtx, sourceCtx, "stage1_parent")
        if launchErr then
            return "failed", "Stage 1 launch failed: " .. tostring(launchErr), "stage1_parent", sourceCtx.stage1_stderr
        end
        return "running", nil
    end
    if phase == "stage1_parent_poll" then
        local state, err = pollCurrentStageJob(runCtx, sourceCtx)
        if state == "running" then return "running", nil end
        if state == "done" then
            sourceCtx.phase = "stage2_launch"
            return "running", nil
        end
        if state == "cancelled" then
            return "cancelled", err or "Cancelled"
        end
        return "failed", "Stage 1 failed: " .. tostring(err or "unknown"), "stage1_parent", sourceCtx.stage1_stderr
    end
    if phase == "stage2_launch" then
        local _, launchErr = launchCurrentStageJob(runCtx, sourceCtx, "stage2_drumsep")
        if launchErr then
            return "failed", "Stage 2 launch failed: " .. tostring(launchErr), "stage2_drumsep", sourceCtx.stage2_stderr
        end
        return "running", nil
    end
    if phase == "stage2_drumsep_poll" then
        local state, err = pollCurrentStageJob(runCtx, sourceCtx)
        if state == "running" then return "running", nil end
        if state == "done" then
            return "done", nil
        end
        if state == "cancelled" then
            return "cancelled", err or "Cancelled"
        end
        return "failed", "Stage 2 failed: " .. tostring(err or "unknown"), "stage2_drumsep", sourceCtx.stage2_stderr
    end
    return "failed", "Unknown source phase: " .. phase, "pipeline", sourceCtx.stage2_stderr or sourceCtx.stage1_stderr
end

local function pollActiveAsyncSources(runCtx)
    local snapshot = {}
    for _, sourceCtx in ipairs(runCtx.active_source_order or {}) do
        snapshot[#snapshot + 1] = sourceCtx
    end
    for _, sourceCtx in ipairs(snapshot) do
        if runCtx.status ~= "running" then return false end
        if isAsyncCancelRequested(runCtx) then
            cancelAsyncRun(runCtx, "Cancelled by callback request.")
            return false
        end
        local state, err, stage, logPath = advanceAsyncSource(runCtx, sourceCtx)
        if state == "done" then
            removeActiveSource(runCtx, sourceCtx)
            recordCompletedSource(runCtx, sourceCtx)
        elseif state == "cancelled" then
            cancelAsyncRun(runCtx, err or "Cancelled")
            return false
        elseif state == "failed" then
            removeActiveSource(runCtx, sourceCtx)
            failAsyncRun(runCtx, stage or "pipeline", tostring(err or "Async source failed."), logPath)
            return false
        end
    end
    return true
end

local function advanceAsyncRunState(runCtx)
    if runCtx.status ~= "running" then return end
    if isAsyncCancelRequested(runCtx) then
        cancelAsyncRun(runCtx, "Cancelled by callback request.")
        return
    end
    if runCtx.last_logged_phase ~= runCtx.phase then
        runCtx.last_logged_phase = runCtx.phase
        logKV("async_phase", tostring(runCtx.phase))
    end

    if runCtx.phase == "init" then
        writeTextFile(DRUMKIT_PARALLEL_TRACE_PATH, "")
        writeTextFile(runCtx.parallel_trace_path, "")
        logKV("workflow_mode", runCtx.mode)
        logKV("selected_item_count", runCtx.selected_item_count)
        logKV("resolved_source_count", runCtx.source_count)
        logKV("requested_device", tostring(runCtx.requested_device or ""))
        logKV("requested_device_class", tostring(runCtx.requested_device_class or ""))
        logKV("requested_device_id", tostring(runCtx.requested_device_id or ""))
        logKV("worker_requested_device", tostring(runCtx.worker_requested_device or ""))
        logKV("effective_device", tostring(runCtx.effective_device or ""))
        logKV("effective_backend", tostring(runCtx.effective_backend or ""))
        logKV("actual_runtime_backend", tostring(runCtx.actual_runtime_backend or "unknown"))
        logKV("actual_torch_device", tostring(runCtx.actual_torch_device or "unknown"))
        logKV("max_parallel_jobs", tostring(runCtx.max_parallel_jobs or 1))
        logKV("max_parallel_reason", tostring(runCtx.max_parallel_reason or "unknown"))
        appendParallelTrace(
            runCtx,
            "scheduler_start total_sources=" .. tostring(runCtx.source_count)
                .. " max_parallel=" .. tostring(runCtx.max_parallel_jobs or 1)
                .. " reason=" .. tostring(runCtx.max_parallel_reason or "unknown")
                .. " requested_device_class=" .. tostring(runCtx.requested_device_class or "")
                .. " requested_device_id=" .. tostring(runCtx.requested_device_id or "")
                .. " worker_requested_device=" .. tostring(runCtx.worker_requested_device or "")
                .. " effective_device=" .. tostring(runCtx.effective_device or "")
                .. " effective_backend=" .. tostring(runCtx.effective_backend or "")
                .. " actual_runtime_backend=" .. tostring(runCtx.actual_runtime_backend or "unknown")
                .. " actual_torch_device=" .. tostring(runCtx.actual_torch_device or "unknown")
        )
        logKV("source_resolution_mode", runCtx.source_resolution_mode)
        logKV("selection_precedence", runCtx.selection_precedence)
        logKV("grouping_mode", runCtx.output_grouping)
        logKV("folder_mode", runCtx.use_folder and "folder_on" or "folder_off")
        logKV("temp_root", runCtx.temp_root)
        logKV("events_path", runCtx.events_path)
        logKV("parallel_trace_path", runCtx.parallel_trace_path)
        emitAsyncEvent(runCtx, {
            event = "run_start",
            status = "start",
            parent_model = CLEAN_PARENT_MODELS[runCtx.mode] or "",
            drumsep_model = STAGE2_MODEL,
            grouping_mode = runCtx.output_grouping,
            folder_mode = runCtx.use_folder and "folder_on" or "folder_off",
            source_resolution_mode = runCtx.source_resolution_mode,
            selection_precedence = runCtx.selection_precedence,
            selected_item_count = runCtx.selected_item_count,
            resolved_sources = runCtx.source_count,
            source_count = runCtx.source_count,
            max_parallel_jobs = runCtx.max_parallel_jobs,
            max_parallel_reason = runCtx.max_parallel_reason,
            requested_device = runCtx.requested_device,
            requested_device_class = runCtx.requested_device_class,
            requested_device_id = runCtx.requested_device_id,
            worker_requested_device = runCtx.worker_requested_device,
            effective_device = runCtx.effective_device,
            effective_backend = runCtx.effective_backend,
            actual_runtime_backend = runCtx.actual_runtime_backend,
            actual_torch_device = runCtx.actual_torch_device,
            actual_acceleration_available = runCtx.actual_acceleration_available == true,
        })
        runCtx.phase = "processing"
        return
    end

    if runCtx.phase == "processing" then
        if not startPendingAsyncSources(runCtx) then return end
        if not pollActiveAsyncSources(runCtx) then return end
        if not startPendingAsyncSources(runCtx) then return end
        emitAsyncSchedulerStatus(runCtx)
        local completed = tonumber(runCtx.completed_source_count or 0) or 0
        local total = tonumber(runCtx.source_count or 0) or 0
        if completed >= total and #(runCtx.active_source_order or {}) == 0 then
            runCtx.phase = "batch_import"
        end
        return
    end

    if runCtx.phase == "batch_import" then
        if not importCompletedSources(runCtx) then return end
        runCtx.phase = "run_done"
        return
    end

    if runCtx.phase == "run_done" then
        if runCtx.total_imported_stems <= 0 then
            failAsyncRun(runCtx, "pipeline", "No stems imported.", runCtx.last_log_path)
            return
        end
        finishAsyncRun(runCtx, "success", nil)
        return
    end
end

local function scheduleAsyncRunLoop(runCtx)
    local function loop()
        if runCtx.status ~= "running" then return end
        runCtx.loop_tick_count = (tonumber(runCtx.loop_tick_count) or 0) + 1
        if runCtx.loop_tick_count <= 10 then
            logKV("async_loop_tick", tostring(runCtx.loop_tick_count) .. " phase=" .. tostring(runCtx.phase) .. " status=" .. tostring(runCtx.status))
        end
        if isAsyncCancelRequested(runCtx) then
            logKV("async_cancel_seen", "true")
            logKV("async_cancel_seen_phase", tostring(runCtx.phase or ""))
            logKV("async_cancel_seen_active_job_stage", tostring(runCtx.active_job and runCtx.active_job.stage or ""))
            logKV("async_cancel_seen_active_sources", tostring(#(runCtx.active_source_order or {})))
            cancelAsyncRun(runCtx, "Cancelled by callback request.")
            return
        end
        local now = nowSeconds()
        if now >= runCtx.next_poll_at then
            advanceAsyncRunState(runCtx)
            runCtx.next_poll_at = now + runCtx.poll_interval
        end
        if runCtx.status == "running" then
            reaper.defer(loop)
        end
    end
    reaper.defer(loop)
end

local function runDrumSepWorkflowPrototypeAsync(modeOverride, opts)
    opts = opts or {}
    logKV("async_entry", "1")
    local runCtx, initErr = createAsyncRunContext(modeOverride, opts)
    if not runCtx then
        local mode = tostring(modeOverride or DRUMSEP_WORKFLOW_MODE or "clean_fast")
        local modeLabel = folderModeLabel(mode, CLEAN_PARENT_MODELS[mode])
        local tempRoot = tostring(opts[ASYNC_TEMP_ROOT_KEY] or makeDrumKitTempRoot(os.date("%Y%m%d-%H%M%S")))
        local failed = {
            ok = false,
            async = true,
            status = "failed",
            workflow_mode = mode,
            mode_label = modeLabel,
            temp_root = tempRoot,
            resolved_sources = 0,
            total_imported_stems = 0,
            error = tostring(initErr and initErr.message or "Async init failed."),
            log_path = nil,
            metadata_path = pathJoin(tempRoot, "drumkit_run_metadata.json"),
            events_path = pathJoin(tempRoot, "drumkit_events.jsonl"),
        }
        if type(opts.onComplete) == "function" then
            local okCb, errCb = pcall(opts.onComplete, failed)
            if not okCb then
                logKV("on_complete_callback_error", tostring(errCb or "callback_failed"))
            end
        end
        logKV("async_init_error_stage", tostring(initErr and initErr.stage or ""))
        logKV("async_init_error_message", tostring(initErr and initErr.message or ""))
        return failed
    end
    logKV("async_temp_root", tostring(runCtx.temp_root or ""))
    currentDrumKitAsyncRun = runCtx
    _G.STEMWERK_DRUMKIT_CURRENT_ASYNC_RUN = runCtx
    _G.STEMWERK_DRUMKIT_CANCEL_CURRENT_ASYNC_RUN = cancelCurrentDrumKitAsyncRun
    scheduleAsyncRunLoop(runCtx)
    logKV("async_return_stub", "1")
    return {
        ok = nil,
        async = true,
        status = "running",
        run_id = runCtx.temp_root,
        temp_root = runCtx.temp_root,
        metadata_path = runCtx.metadata_path,
        events_path = runCtx.events_path,
        workflow_mode = runCtx.workflow_mode,
        mode_label = runCtx.mode_label,
    }
end

getScriptDir = function()
    if LOADED_SCRIPT_DIR and LOADED_SCRIPT_DIR ~= "" then
        return LOADED_SCRIPT_DIR
    end
    local _, scriptPath = reaper.get_action_context()
    if not scriptPath or scriptPath == "" then return nil end
    return scriptPath:match("^(.*[/\\])")
end

local function basenameNoExt(path)
    local name = tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
    return name:match("(.+)%.[^.]+$") or name
end

sourceIndexLabel = function(n)
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

sanitizeSourceLabel = function(label, idxLabel)
    local s = sanitizeLabel(label)
    if s == "" then
        return "Source " .. tostring(idxLabel or "01")
    end
    return s
end

sanitizeTrackLabel = function(label, trackIndex)
    local s = sanitizeLabel(label)
    if s == "" then
        local idx = tonumber(trackIndex) or 0
        if idx < 1 then idx = 1 end
        return "Track " .. tostring(idx)
    end
    return s
end

nowSeconds = function()
    if reaper and reaper.time_precise then
        return reaper.time_precise()
    end
    return os.clock()
end

logKV = function(key, value)
    local msg = "[DrumSep Workflow Prototype] " .. tostring(key) .. "=" .. tostring(value)
    if type(debugLog) == "function" then
        debugLog(msg)
    end
    local consoleFlag = reaper.GetExtState and reaper.GetExtState("STEMwerk", "DEBUG_CONSOLE") or ""
    if consoleFlag == "1" and reaper.ShowConsoleMsg then
        reaper.ShowConsoleMsg(msg .. "\n")
    end
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

jsonEncode = function(value)
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

writeTextFile = function(path, content)
    local f = io.open(path, "wb")
    if not f then return false, "open_failed" end
    f:write(content or "")
    f:close()
    return true, nil
end

appendTextFile = function(path, content)
    local f = io.open(path, "ab")
    if not f then return false, "open_failed" end
    f:write(content or "")
    f:close()
    return true, nil
end

formatUtcIso = function(epochSeconds)
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

resolveWorkflowSources = function(opts)
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

importDrumKitSplit = function(stage2Dir, folderLabel, sourceEntry, opts)
    opts = opts or {}
    local isCancelRequested = type(opts.isCancelRequested) == "function" and opts.isCancelRequested or nil
    local function importCancelRequested()
        if not isCancelRequested then return false end
        local okCancel, cancelled = pcall(isCancelRequested)
        return okCancel and cancelled == true
    end
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
        if stem.selected ~= false then
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
    end

    if #present == 0 then
        return false, {
            imported = {},
            missing = missing,
            failed = {},
            message = "No Drum Kit Split stems found (kick/snare/toms/hihat/ride/crash).",
        }
    end

    if importCancelRequested() then
        return false, {
            imported = {},
            missing = missing,
            failed = {},
            cancelled = true,
            message = "Import cancelled.",
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
        if importCancelRequested() then
            return false, {
                imported = importedNames,
                missing = missing,
                failed = failed,
                cancelled = true,
                message = "Import cancelled.",
                insertedTrackCount = insertedTrackCount,
                importedItems = importedItems,
                importedPaths = importedPaths,
            }
        end
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

resolvePython = function()
    if reaper and reaper.GetExtState then
        local configured = tostring(reaper.GetExtState(STEMWERK_EXT_SECTION, "pythonPath") or "")
        if configured ~= "" and fileExists(configured) then return configured end
    end
    local envPython = os.getenv("STEMWERK_PYTHON") or os.getenv("PYTHON")
    if envPython and envPython ~= "" and fileExists(envPython) then return envPython end
    local scriptDir = getScriptDir and getScriptDir() or ""
    if scriptDir ~= "" then
        local sep = package.config:sub(1, 1) or "/"
        local candidates = {
            pathJoin(pathJoin(scriptDir, ".venv"), sep == "\\" and "Scripts\\python.exe" or "bin/python"),
            pathJoin(pathJoin(pathJoin(scriptDir, ".."), ".venv"), sep == "\\" and "Scripts\\python.exe" or "bin/python"),
        }
        for _, candidate in ipairs(candidates) do
            if fileExists(candidate) then return candidate end
        end
    end
    return "python3"
end

local function _showMessage(text, suppress)
    if suppress then return end
    reaper.ShowMessageBox(text, "STEMwerk Drum Kit Split Workflow Prototype", 0)
end

refreshImportedMediaItems = function(items, sourcePaths)
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
    local workerDevice = tostring(ctx and ctx.worker_requested_device or ctx and ctx.effective_device or DEFAULT_DRUMKIT_DEVICE)
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
            "--model", quoteArg(parentModel), "--device", quoteArg(workerDevice)
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
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(workerDevice)
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
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(workerDevice)
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
    if type(ctx.begin_import_undo) == "function" then
        ctx.begin_import_undo()
    end
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

    local outputGrouping = normalizeOutputGrouping(opts.output_grouping or extState(STEMWERK_EXT_SECTION, "outputGrouping"))
    local useFolder = opts.use_folder
    if useFolder == nil then
        local createFolderState = extState(STEMWERK_EXT_SECTION, "createFolder")
        useFolder = (createFolderState == "") and true or (createFolderState == "1")
    end

    local ts = os.date("%Y%m%d-%H%M%S")
    local root = tostring(opts[ASYNC_TEMP_ROOT_KEY] or makeDrumKitTempRoot(ts))
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
    local importUndoStarted = false
    local function beginImportUndo()
        if importUndoStarted then return end
        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)
        importUndoStarted = true
    end

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
            worker_requested_device = tostring(opts.worker_requested_device or opts.effective_device or opts.requested_device or DEFAULT_DRUMKIT_DEVICE),
            effective_device = tostring(opts.effective_device or opts.worker_requested_device or opts.requested_device or DEFAULT_DRUMKIT_DEVICE),
            use_folder = useFolder,
            insert_at_index = insertAtIndex,
            grouping_mode = outputGrouping,
            shared_import_layout = sharedImportLayout,
            emit_event = emitEvent,
            begin_import_undo = beginImportUndo,
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
    local cleanupSummary = nil
    if totalImported > 0 then
        cleanupSummary = applyCleanupActionsToSources(resolvedSources)
        if cleanupSummary then
            result.cleanup_action = cleanupSummary.action
            result.cleanup_count = cleanupSummary.count
            logKV("cleanup_action", tostring(cleanupSummary.action or ""))
            logKV("cleanup_count", tostring(cleanupSummary.count or 0))
        end
    end
    if importUndoStarted then
        reaper.PreventUIRefresh(-1)
    end
    reaper.UpdateArrange()
    if importUndoStarted then
        reaper.Undo_EndBlock("STEMwerk: Drum Kit Split", -1)
    end

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
            "Drum Kit Split failed.\n\n" ..
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
            "Drum Kit Split partial success.\n\nMode: " .. mode ..
            "\nResolved sources: " .. tostring(#resolvedSources) ..
            "\nImported stems total: " .. tostring(totalImported) ..
            "\nFailures: yes" ..
            "\nLogs: " .. root,
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
        "Drum Kit Split complete.\n\nMode: " .. mode ..
        "\nResolved sources: " .. tostring(#resolvedSources) ..
        "\nImported stems total: " .. tostring(totalImported) ..
        "\nLogs: " .. root,
        suppressSuccessMessage
    )
    return result
end

local function runDrumSepWorkflowPrototype(modeOverride, opts)
    opts = opts or {}
    local canonicalMode, canonicalOptsOrErr = buildCanonicalStartOptions(modeOverride, opts)
    if not canonicalMode then
        local err = tostring(canonicalOptsOrErr or "Unable to resolve canonical Drum Kit start settings.")
        logKV("canonical_start_error", err)
        if not benchmarkSuppressModalEnabled() then
            _showMessage(err, opts.suppressFailureMessage == true)
        end
        return {
            ok = false,
            async = false,
            status = "failed",
            error_stage = "settings",
            error_message = err,
            resolved_sources = 0,
            total_imported_stems = 0,
        }
    end
    opts = canonicalOptsOrErr
    modeOverride = canonicalMode
    local asyncEnabled = opts.async_enabled == true
    logKV("dispatch_async_enabled", tostring(asyncEnabled))
    if asyncEnabled then
        logKV("dispatch_path", "async")
        local asyncOpts = {}
        for k, v in pairs(opts) do
            asyncOpts[k] = v
        end
        asyncOpts.async_enabled = nil
        return runDrumSepWorkflowPrototypeAsync(modeOverride, asyncOpts)
    end
    logKV("dispatch_path", "blocking")
    return runDrumSepWorkflowPrototypeBlocking(modeOverride, opts)
end

local function main()
    runDrumSepWorkflowPrototype(nil, nil)
end

local API = {
    runDrumSepWorkflowPrototype = runDrumSepWorkflowPrototype,
    cancelCurrentDrumKitAsyncRun = cancelCurrentDrumKitAsyncRun,
}

if not rawget(_G, "STEMWERK_DRUMSEP_WORKFLOW_NO_AUTORUN") then
    if isPrototypeActionAllowed() then
        main()
    else
        reaper.ShowMessageBox(
            "This Drum Kit Split prototype action is disabled outside development builds.\n\nSet STEMwerk-dev/allow_drumkit_prototype_actions=1 to enable.",
            "STEMwerk Drum Kit Split",
            0
        )
    end
end

return API
