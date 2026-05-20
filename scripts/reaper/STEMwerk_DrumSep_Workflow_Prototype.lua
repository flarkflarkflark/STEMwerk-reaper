--[[
PRIVATE R&D ONLY - NOT FOR REAPACK/PUBLIC RELEASE

Drum Split workflow runner prototype (blocking/synchronous):
1) Selected REAPER item -> temp input wav (ffmpeg clip extract)
2) Stage 1: htdemucs -> drums.wav
3) Stage 2: MDX23C-DrumSep-aufr33-jarredou.ckpt on drums.wav
4) Import DrumSep stems as folder + child tracks at selected item position
]]

local PYTHON_BIN = "/home/flark/.local/share/STEMwerk/.venv/bin/python" -- private local RX 9070 proof route
local DEVICE = "cuda:0" -- private local RX 9070 proof route
local STAGE1_MODEL = "htdemucs"
local STAGE2_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
local FFMPEG_BIN = "ffmpeg"

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

local function importDrumKitSplit(stage2Dir, sourceLabel, itemStartPos)
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
    local folderName = "Drum Kit Split - " .. (sourceLabel or "Source")
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

local function main()
    local t0 = nowSeconds()
    local selectedCount = reaper.CountSelectedMediaItems(0)

    if selectedCount > 1 then
        local warningText = "DrumSep workflow prototype processes only the first selected item. Selected items: " .. tostring(selectedCount) .. "."
        reaper.ShowMessageBox(warningText, "STEMwerk DrumSep Workflow Prototype", 0)
        logKV("warning", warningText)
    end

    local selectedItem = reaper.GetSelectedMediaItem(0, 0)
    if not selectedItem then
        reaper.ShowMessageBox("Select one media item first.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
    end
    local take = reaper.GetActiveTake(selectedItem)
    if not take then
        reaper.ShowMessageBox("Selected item has no active take.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
    end

    local source = reaper.GetMediaItemTake_Source(take)
    local sourcePath = source and reaper.GetMediaSourceFileName(source, "") or ""
    if not sourcePath or sourcePath == "" then
        reaper.ShowMessageBox("Could not resolve source file path for selected take.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
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
        reaper.ShowMessageBox("Unsupported take playrate (<= 0) for prototype extraction.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
    end

    local scriptDir = getScriptDir()
    if not scriptDir then
        reaper.ShowMessageBox("Could not resolve script directory.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
    end
    local separatorScript = pathJoin(scriptDir, "audio_separator_process.py")
    if not fileExists(separatorScript) then
        reaper.ShowMessageBox("audio_separator_process.py not found next to script.", "STEMwerk DrumSep Workflow Prototype", 0)
        return
    end

    local ts = os.date("%Y%m%d-%H%M%S")
    local root = "/tmp/stemwerk-drumsep-workflow-prototype-" .. ts
    local stage0 = pathJoin(root, "stage0_input")
    local stage1 = pathJoin(root, "stage1_htdemucs")
    local stage2 = pathJoin(root, "stage2_drumsep")
    makeDir(stage0); makeDir(stage1); makeDir(stage2)

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
        reaper.ShowMessageBox(
            "Stage 0 (extract selected item) failed.\n\nLog:\n" .. ffLog,
            "STEMwerk DrumSep Workflow Prototype",
            0
        )
        return
    end

    local py = resolvePython()
    local stage1Stdout = pathJoin(stage1, "cmd_stdout.txt")
    local stage1Stderr = pathJoin(stage1, "cmd_stderr.txt")
    local stage1Cmd = table.concat({
        quoteArg(py), quoteArg(separatorScript), quoteArg(inputWav), quoteArg(stage1),
        "--model", quoteArg(STAGE1_MODEL), "--device", quoteArg(DEVICE)
    }, " ")
    local stage1Rc = runShell(stage1Cmd, stage1Stdout, stage1Stderr)
    local drumsWav = pathJoin(stage1, "drums.wav")
    if stage1Rc ~= 0 or not fileExists(drumsWav) then
        logKV("stage1_cmd", stage1Cmd)
        logKV("stage1_exit_code", stage1Rc)
        logKV("stage1_log", stage1Stderr)
        reaper.ShowMessageBox(
            "Stage 1 failed or drums.wav missing.\n\nLog:\n" .. stage1Stderr,
            "STEMwerk DrumSep Workflow Prototype",
            0
        )
        return
    end

    local stage2Stdout = pathJoin(stage2, "cmd_stdout.txt")
    local stage2Stderr = pathJoin(stage2, "cmd_stderr.txt")
    local stage2Cmd = table.concat({
        quoteArg(py), quoteArg(separatorScript), quoteArg(drumsWav), quoteArg(stage2),
        "--model", quoteArg(STAGE2_MODEL), "--device", quoteArg(DEVICE)
    }, " ")
    local stage2Rc = runShell(stage2Cmd, stage2Stdout, stage2Stderr)
    if stage2Rc ~= 0 then
        logKV("stage2_cmd", stage2Cmd)
        logKV("stage2_exit_code", stage2Rc)
        logKV("stage2_log", stage2Stderr)
        reaper.ShowMessageBox(
            "Stage 2 failed.\n\nLog:\n" .. stage2Stderr,
            "STEMwerk DrumSep Workflow Prototype",
            0
        )
        return
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    local label = basenameNoExt(sourcePath)
    local ok, importSummary = importDrumKitSplit(stage2, label, itemPos)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: DrumSep workflow prototype", -1)

    local elapsed = nowSeconds() - t0
    logKV("stage0_input_path", inputWav)
    logKV("stage1_output_dir", stage1)
    logKV("stage2_output_dir", stage2)
    logKV("stage1_cmd", stage1Cmd)
    logKV("stage2_cmd", stage2Cmd)
    logKV("stage1_exit_code", stage1Rc)
    logKV("stage2_exit_code", stage2Rc)
    logKV("imported_stems", table.concat(importSummary and importSummary.imported or {}, ","))
    logKV("missing_stems", table.concat(importSummary and importSummary.missing or {}, ","))
    logKV("elapsed_seconds", string.format("%.3f", elapsed))
    logKV("import_summary", tostring(importSummary and importSummary.message or ""))

    if not ok then
        reaper.ShowMessageBox(
            "Import failed.\n\n" .. tostring(importSummary and importSummary.message or "") .. "\n\nStage 2 log:\n" .. stage2Stderr,
            "STEMwerk DrumSep Workflow Prototype",
            0
        )
        return
    end

    local importedCount = #(importSummary and importSummary.imported or {})
    local note = ""
    if selectedCount > 1 then
        note = "\n\nNote: first selected item only."
    end
    reaper.ShowMessageBox(
        "DrumSep workflow prototype complete.\n\nImported stems: " .. tostring(importedCount) ..
        "\nTemp root:\n" .. root .. note,
        "STEMwerk DrumSep Workflow Prototype",
        0
    )
end

main()
