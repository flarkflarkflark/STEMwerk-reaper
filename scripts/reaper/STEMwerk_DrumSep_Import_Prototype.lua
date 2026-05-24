--[[
PRIVATE R&D ONLY - NOT FOR REAPACK/PUBLIC RELEASE

Prototype action:
- Imports pre-rendered DrumSep stems from a local proof directory
- Creates a "Drum Kit Split" folder track with child tracks
- Does not run backend processing; import/layout proof only
]]

local DEFAULT_SOURCE_LABEL = "DrumSep Proof"

local STEMS = {
    { key = "kick", file = "kick.wav", name = "Kick", color = {255, 174, 66} },
    { key = "snare", file = "snare.wav", name = "Snare", color = {237, 91, 121} },
    { key = "toms", file = "toms.wav", name = "Toms", color = {142, 124, 195} },
    { key = "hihat", file = "hihat.wav", name = "Hi-Hat", color = {242, 206, 110} },
    { key = "ride", file = "ride.wav", name = "Ride", color = {98, 201, 176} },
    { key = "crash", file = "crash.wav", name = "Crash", color = {106, 168, 255} },
}

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function pathJoin(a, b)
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function isPrototypeActionAllowed()
    if not (reaper and reaper.GetExtState) then
        return false
    end
    local v = tostring(reaper.GetExtState("STEMwerk-dev", "allow_drumkit_prototype_actions") or ""):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function defaultProofDir()
    local fromEnv = os.getenv("STEMWERK_DRUMSEP_PROOF_DIR")
    if fromEnv and fromEnv ~= "" then
        return fromEnv
    end
    local tempBase = os.getenv("STEMWERK_TEMP_DIR") or os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return pathJoin(tempBase, "stemwerk-drumsep-proof")
end

local function rgbToReaperColor(r, g, b)
    return reaper.ColorToNative(r, g, b) | 0x1000000
end

local function sanitizeLabel(label)
    local value = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return DEFAULT_SOURCE_LABEL
    end
    return value
end

local function getStemAvailability(outputDir)
    local present, missing = {}, {}
    for _, stem in ipairs(STEMS) do
        local fullPath = pathJoin(outputDir, stem.file)
        if fileExists(fullPath) then
            present[#present + 1] = { stem = stem, path = fullPath }
        else
            missing[#missing + 1] = stem
        end
    end
    return present, missing
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

function importDrumKitSplitPrototype(outputDir, sourceNameOrLabel)
    local resolvedDir = tostring(outputDir or "")
    local sourceLabel = sanitizeLabel(sourceNameOrLabel)
    local startPos = reaper.GetCursorPositionEx(0)

    if resolvedDir == "" or not reaper.EnumerateFiles(resolvedDir, 0) then
        reaper.ShowMessageBox(
            "DrumSep proof directory not found:\n" .. tostring(resolvedDir),
            "STEMwerk DrumSep Prototype",
            0
        )
        return false
    end

    local present, missing = getStemAvailability(resolvedDir)
    if #present == 0 then
        reaper.ShowMessageBox(
            "No DrumSep stems found in:\n" .. resolvedDir .. "\n\nExpected:\n" ..
            "kick.wav, snare.wav, toms.wav, hihat.wav, ride.wav, crash.wav",
            "STEMwerk DrumSep Prototype",
            0
        )
        return false
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local baseIndex = reaper.CountTracks(0)
    local folderName = "Drum Kit Split - " .. sourceLabel
    local folderColor = rgbToReaperColor(180, 140, 200)
    createTrackAtIndex(baseIndex, folderName, folderColor, 1)

    local imported = 0
    local importedNames = {}
    local failed = {}

    for idx, entry in ipairs(present) do
        local childIndex = baseIndex + idx
        local stem = entry.stem
        local color = rgbToReaperColor(stem.color[1], stem.color[2], stem.color[3])
        local childTrack = createTrackAtIndex(childIndex, stem.name, color, 0)
        local item, err = addStemItem(childTrack, entry.path, startPos)
        if item then
            imported = imported + 1
            importedNames[#importedNames + 1] = stem.name
        else
            failed[#failed + 1] = stem.name .. ": " .. tostring(err)
        end
    end

    if #present > 0 then
        local lastChild = reaper.GetTrack(0, baseIndex + #present)
        if lastChild then
            reaper.SetMediaTrackInfo_Value(lastChild, "I_FOLDERDEPTH", -1)
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("STEMwerk: DrumSep import prototype", -1)

    local missingNames = {}
    for _, stem in ipairs(missing) do
        missingNames[#missingNames + 1] = stem.name
    end

    local lines = {
        "Imported from: " .. resolvedDir,
        "Start position (seconds): " .. string.format("%.3f", startPos),
        "Imported stems: " .. table.concat(importedNames, ", "),
    }
    if #missingNames > 0 then
        lines[#lines + 1] = "Missing stems: " .. table.concat(missingNames, ", ")
    end
    if #failed > 0 then
        lines[#lines + 1] = "Failed stems: " .. table.concat(failed, " | ")
    end

    local severity = (#missingNames > 0 or #failed > 0) and "WARNING" or "OK"
    reaper.ShowMessageBox(severity .. "\n\n" .. table.concat(lines, "\n"), "STEMwerk DrumSep Prototype", 0)
    reaper.ShowConsoleMsg("[STEMwerk DrumSep Prototype] " .. table.concat(lines, " | ") .. "\n")

    return imported > 0
end

if not isPrototypeActionAllowed() then
    reaper.ShowMessageBox(
        "This Drum Kit Split development action is disabled outside development builds.\n\nSet STEMwerk-dev/allow_drumkit_prototype_actions=1 to enable.",
        "STEMwerk Drum Kit Split",
        0
    )
    return
end

importDrumKitSplitPrototype(defaultProofDir(), "DrumSep Proof")
