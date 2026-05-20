--[[
PRIVATE R&D ONLY - NOT FOR REAPACK/PUBLIC RELEASE

Drum Split workflow runner prototype (blocking/synchronous):
1) Selected REAPER item -> temp input wav (ffmpeg clip extract)
2) clean_fast mode: htdemucs -> drums.wav -> DrumSep
3) clean_quality mode: htdemucs_ft -> drums.wav -> DrumSep
4) direct_creative mode: DrumSep directly on input.wav (experimental/parked)
4) Import DrumSep stems as folder + child tracks at selected item position
]]

local PYTHON_BIN = "/home/flark/.local/share/STEMwerk/.venv/bin/python" -- private local RX 9070 proof route
local DEVICE = "cuda:0" -- private local RX 9070 proof route
local STAGE2_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
local FFMPEG_BIN = "ffmpeg"
local DRUMSEP_WORKFLOW_MODE = "clean_fast"
-- allowed:
-- "clean_fast"       selected item -> htdemucs -> drums.wav -> DrumSep
-- "clean_quality"    selected item -> htdemucs_ft -> drums.wav -> DrumSep
-- "direct_creative"  selected item -> DrumSep directly (experimental/parked due bleed)
local CLEAN_PARENT_MODELS = {
    clean_fast = "htdemucs",
    clean_quality = "htdemucs_ft",
}

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

local function getScriptDir()
    local _, scriptPath = reaper.get_action_context()
    if not scriptPath or scriptPath == "" then return nil end
    return scriptPath:match("^(.*[/\\])")
end

local function basenameNoExt(path)
    local name = tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
    return name:match("(.+)%.[^.]+$") or name
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

local function addStemItem(track, stemPath, itemStartPos)
    local source = reaper.PCM_Source_CreateFromFile(stemPath)
    if not source then
        return nil, "Failed to open source: " .. tostring(stemPath)
    end
    local item = reaper.AddMediaItemToTrack(track)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", itemStartPos)
    local srcLen = reaper.GetMediaSourceLength(source)
    if srcLen and srcLen > 0 then
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", srcLen)
    else
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 1.0)
    end
    local take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, source)
    return item
end

local function importDrumKitSplit(stage2Dir, folderLabel, itemStartPos)
    local present, missing = {}, {}
    for _, stem in ipairs(STEMS) do
        local p = pathJoin(stage2Dir, stem.file)
        if fileExists(p) then
            present[#present + 1] = { stem = stem, path = p }
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
    local folderName = folderLabel or "Drum Kit Split"
    createTrackAtIndex(baseIndex, folderName, rgbToReaperColor(180, 140, 200), 1)

    local importedNames, failed = {}, {}
    for idx, entry in ipairs(present) do
        local childIndex = baseIndex + idx
        local c = entry.stem.color
        local track = createTrackAtIndex(childIndex, entry.stem.name, rgbToReaperColor(c[1], c[2], c[3]), 0)
        local item, err = addStemItem(track, entry.path, itemStartPos)
        if item then
            importedNames[#importedNames + 1] = entry.stem.name
        else
            failed[#failed + 1] = entry.stem.name .. ": " .. tostring(err)
        end
    end
    local lastChild = reaper.GetTrack(0, baseIndex + #present)
    if lastChild then reaper.SetMediaTrackInfo_Value(lastChild, "I_FOLDERDEPTH", -1) end

    local msg = { "Imported stems: " .. table.concat(importedNames, ", "), }
    if #missing > 0 then msg[#msg + 1] = "Missing stems: " .. table.concat(missing, ", ") end
    if #failed > 0 then msg[#msg + 1] = "Failed stems: " .. table.concat(failed, " | ") end
    return true, {
        imported = importedNames,
        missing = missing,
        failed = failed,
        message = table.concat(msg, "\n"),
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

local function runDrumSepWorkflowPrototype(modeOverride, opts)
    opts = opts or {}
    local selectedItemOverride = opts.selectedItem
    local suppressSuccessMessage = opts.suppressSuccessMessage == true
    local suppressFailureMessage = opts.suppressFailureMessage == true
    local suppressMultiSelectMessage = opts.suppressMultiSelectMessage == true

    local t0 = nowSeconds()
    local selectedCount = reaper.CountSelectedMediaItems(0)
    local result = {
        ok = false,
        mode = nil,
        selected_item_count = selectedCount,
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
    }

    if selectedCount > 1 then
        local warningText = "DrumSep workflow prototype processes only the first selected item. Selected items: " .. tostring(selectedCount) .. "."
        _showMessage(warningText, suppressMultiSelectMessage)
        logKV("warning", warningText)
    end

    local selectedItem = selectedItemOverride or reaper.GetSelectedMediaItem(0, 0)
    if selectedItemOverride and (not reaper.ValidatePtr(selectedItemOverride, "MediaItem*")) then
        selectedItem = nil
    end
    if not selectedItem then
        result.error_stage = "selection"
        result.error_message = "Select one media item first."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end
    local take = reaper.GetActiveTake(selectedItem)
    if not take then
        result.error_stage = "selection"
        result.error_message = "Selected item has no active take."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end

    local source = reaper.GetMediaItemTake_Source(take)
    local sourcePath = source and reaper.GetMediaSourceFileName(source, "") or ""
    if not sourcePath or sourcePath == "" then
        result.error_stage = "selection"
        result.error_message = "Could not resolve source file path for selected take."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end

    local itemPos = reaper.GetMediaItemInfo_Value(selectedItem, "D_POSITION")
    local itemLen = reaper.GetMediaItemInfo_Value(selectedItem, "D_LENGTH")
    local startOffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
    local playRate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
    local sourceTrack = reaper.GetMediaItem_Track(selectedItem)
    local sourceTrackNum = sourceTrack and reaper.GetMediaTrackInfo_Value(sourceTrack, "IP_TRACKNUMBER") or -1
    local sourceTrackName = ""
    if sourceTrack then
        local _, tn = reaper.GetSetMediaTrackInfo_String(sourceTrack, "P_NAME", "", false)
        sourceTrackName = tn or ""
    end
    if playRate <= 0 then
        result.error_stage = "selection"
        result.error_message = "Unsupported take playrate (<= 0) for prototype extraction."
        _showMessage(result.error_message, suppressFailureMessage)
        return result
    end

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
    if mode ~= "clean_fast" and mode ~= "clean_quality" and mode ~= "direct_creative" then
        logKV("warning", "Unknown DRUMSEP_WORKFLOW_MODE=" .. mode .. ", falling back to clean_fast")
        mode = "clean_fast"
    end

    local ts = os.date("%Y%m%d-%H%M%S")
    local root = "/tmp/stemwerk-drumsep-workflow-prototype-" .. ts
    local stage0 = pathJoin(root, "stage0_input")
    local stage1Fast = pathJoin(root, "stage1_htdemucs")
    local stage1Quality = pathJoin(root, "stage1_htdemucs_ft")
    local stage2 = pathJoin(root, "stage2_drumsep")
    local stage1Direct = pathJoin(root, "stage1_direct_drumsep")
    makeDir(stage0); makeDir(stage1Fast); makeDir(stage1Quality); makeDir(stage2)
    makeDir(stage1Direct)
    result.mode = mode
    result.temp_root = root
    result.source_path = sourcePath

    logKV("workflow_mode", mode)
    if mode == "direct_creative" then
        logKV("direct_creative_status", "experimental_parked_due_bleed")
    end
    logKV("selected_item_count", selectedCount)
    logKV("selected_item_mode", selectedCount > 1 and "first_selected_only" or "single")
    logKV("selected_item_index_used", 1)
    logKV("selected_track_number", sourceTrackNum)
    logKV("selected_track_name", sourceTrackName)
    logKV("selected_source_path", sourcePath)
    logKV("selected_item_start", string.format("%.6f", itemPos))
    logKV("selected_item_length", string.format("%.6f", itemLen))
    logKV("selected_take_start_offset", string.format("%.6f", startOffs))
    logKV("selected_take_playrate", string.format("%.6f", playRate))
    logKV("temp_root", root)

    local inputWav = pathJoin(stage0, "input.wav")
    result.stage0_input_path = inputWav
    local ffLog = pathJoin(stage0, "ffmpeg_extract.log")
    local extractOffset = math.max(0, startOffs)
    local extractDuration = math.max(0.01, itemLen * playRate)
    local ffCmd = string.format(
        "%s -y -hide_banner -nostats -loglevel error -i %s -ss %.6f -t %.6f -ar 44100 -ac 2 %s",
        quoteArg(FFMPEG_BIN),
        quoteArg(sourcePath),
        extractOffset,
        extractDuration,
        quoteArg(inputWav)
    )
    local ffRc = runShell(ffCmd, nil, ffLog)
    if ffRc ~= 0 or not fileExists(inputWav) then
        logKV("stage0_cmd", ffCmd)
        logKV("stage0_exit_code", ffRc)
        logKV("stage0_log", ffLog)
        result.error_stage = "stage0"
        result.error_message = "Stage 0 (extract selected item) failed."
        result.log_path = ffLog
        _showMessage(result.error_message .. "\n\nLog:\n" .. ffLog, suppressFailureMessage)
        return result
    end

    local py = resolvePython()
    local stage1Rc = 0
    local stage2Rc = 0
    local stage1Cmd = ""
    local stage2Cmd = ""
    local stage1Stderr = ""
    local stage2Stderr = ""
    local drumsepOutputDir = stage2
    local stage1OutputDir = "skipped"
    local parentModel = nil
    result.stage1_output_dir = stage1OutputDir
    result.stage2_output_dir = stage2
    result.direct_drumsep_output_dir = stage1Direct

    if mode == "clean_fast" or mode == "clean_quality" then
        parentModel = CLEAN_PARENT_MODELS[mode] or CLEAN_PARENT_MODELS.clean_fast
        stage1OutputDir = (mode == "clean_quality") and stage1Quality or stage1Fast
        result.stage1_output_dir = stage1OutputDir
        result.parent_model = parentModel
        logKV("parent_model", parentModel)

        local stage1Stdout = pathJoin(stage1OutputDir, "cmd_stdout.txt")
        stage1Stderr = pathJoin(stage1OutputDir, "cmd_stderr.txt")
        stage1Cmd = table.concat({
            quoteArg(py), quoteArg(separatorScript), quoteArg(inputWav), quoteArg(stage1OutputDir),
            "--model", quoteArg(parentModel), "--device", quoteArg(DEVICE)
        }, " ")
        result.stage1_cmd = stage1Cmd
        stage1Rc = runShell(stage1Cmd, stage1Stdout, stage1Stderr)
        local drumsWav = pathJoin(stage1OutputDir, "drums.wav")
        if stage1Rc ~= 0 or not fileExists(drumsWav) then
            logKV("stage1_cmd", stage1Cmd)
            logKV("stage1_exit_code", stage1Rc)
            logKV("stage1_log", stage1Stderr)
            result.error_stage = "stage1"
            result.error_message = "Stage 1 failed or drums.wav missing."
            result.stage1_exit_code = stage1Rc
            result.log_path = stage1Stderr
            _showMessage(result.error_message .. "\n\nLog:\n" .. stage1Stderr, suppressFailureMessage)
            return result
        end

        local stage2Stdout = pathJoin(stage2, "cmd_stdout.txt")
        stage2Stderr = pathJoin(stage2, "cmd_stderr.txt")
        stage2Cmd = table.concat({
            quoteArg(py), quoteArg(separatorScript), quoteArg(drumsWav), quoteArg(stage2),
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(DEVICE)
        }, " ")
        result.stage2_cmd = stage2Cmd
        stage2Rc = runShell(stage2Cmd, stage2Stdout, stage2Stderr)
        if stage2Rc ~= 0 then
            logKV("stage2_cmd", stage2Cmd)
            logKV("stage2_exit_code", stage2Rc)
            logKV("stage2_log", stage2Stderr)
            result.error_stage = "stage2"
            result.error_message = "Stage 2 failed."
            result.stage2_exit_code = stage2Rc
            result.log_path = stage2Stderr
            _showMessage(result.error_message .. "\n\nLog:\n" .. stage2Stderr, suppressFailureMessage)
            return result
        end
    else
        -- direct_creative: skip htdemucs and run DrumSep directly on stage0 input
        logKV("stage1_htdemucs_skipped", 1)
        logKV("direct_creative_status", "experimental_parked_due_bleed")
        stage1Rc = -1
        drumsepOutputDir = stage1Direct
        local directStdout = pathJoin(stage1Direct, "cmd_stdout.txt")
        stage2Stderr = pathJoin(stage1Direct, "cmd_stderr.txt")
        stage2Cmd = table.concat({
            quoteArg(py), quoteArg(separatorScript), quoteArg(inputWav), quoteArg(stage1Direct),
            "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(DEVICE)
        }, " ")
        result.stage1_cmd = "skipped"
        result.stage2_cmd = stage2Cmd
        stage2Rc = runShell(stage2Cmd, directStdout, stage2Stderr)
        if stage2Rc ~= 0 then
            logKV("direct_drumsep_cmd", stage2Cmd)
            logKV("direct_drumsep_exit_code", stage2Rc)
            logKV("direct_drumsep_log", stage2Stderr)
            result.error_stage = "stage2_direct"
            result.error_message = "Direct DrumSep stage failed."
            result.stage2_exit_code = stage2Rc
            result.log_path = stage2Stderr
            _showMessage(result.error_message .. "\n\nLog:\n" .. stage2Stderr, suppressFailureMessage)
            return result
        end
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    local label = basenameNoExt(sourcePath)
    local folderLabel
    if mode == "clean_fast" then
        folderLabel = "Drum Kit Split - Clean/Fast - " .. label
    elseif mode == "clean_quality" then
        folderLabel = "Drum Kit Split - Clean/Quality - " .. label
    else
        folderLabel = "Drum Kit Split - Direct/Experimental - " .. label
    end
    local ok, importSummary = importDrumKitSplit(drumsepOutputDir, folderLabel, itemPos)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: DrumSep workflow prototype", -1)

    local elapsed = nowSeconds() - t0
    logKV("stage0_input_path", inputWav)
    logKV("stage1_output_dir", (mode == "clean_fast" or mode == "clean_quality") and stage1OutputDir or "skipped")
    logKV("stage2_output_dir", (mode == "clean_fast" or mode == "clean_quality") and stage2 or "skipped")
    logKV("direct_drumsep_output_dir", mode == "direct_creative" and stage1Direct or "n/a")
    if mode == "clean_fast" or mode == "clean_quality" then
        logKV("stage1_cmd", stage1Cmd)
        logKV("stage2_cmd", stage2Cmd)
        logKV("parent_model", tostring(parentModel or ""))
    else
        logKV("stage1_cmd", "skipped")
        logKV("direct_drumsep_cmd", stage2Cmd)
    end
    logKV("stage1_exit_code", stage1Rc)
    logKV("stage2_exit_code", stage2Rc)
    logKV("imported_stems", table.concat(importSummary and importSummary.imported or {}, ","))
    logKV("missing_stems", table.concat(importSummary and importSummary.missing or {}, ","))
    logKV("elapsed_seconds", string.format("%.3f", elapsed))
    logKV("import_summary", tostring(importSummary and importSummary.message or ""))
    result.stage1_exit_code = stage1Rc
    result.stage2_exit_code = stage2Rc
    result.imported_stems = importSummary and importSummary.imported or {}
    result.missing_stems = importSummary and importSummary.missing or {}
    result.import_summary = tostring(importSummary and importSummary.message or "")
    result.elapsed_seconds = elapsed

    if not ok then
        result.error_stage = "import"
        result.error_message = "Import failed."
        result.log_path = stage2Stderr
        _showMessage(
            "Import failed.\n\n" .. tostring(importSummary and importSummary.message or "") .. "\n\nStage 2 log:\n" .. stage2Stderr,
            suppressFailureMessage
        )
        return result
    end

    local importedCount = #(importSummary and importSummary.imported or {})
    local note = ""
    if selectedCount > 1 then
        note = "\n\nNote: first selected item only."
    end
    _showMessage(
        "DrumSep workflow prototype complete.\n\nMode: " .. mode ..
        "\nImported stems: " .. tostring(importedCount) ..
        "\nTemp root:\n" .. root .. note,
        suppressSuccessMessage
    )
    result.ok = true
    return result
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
