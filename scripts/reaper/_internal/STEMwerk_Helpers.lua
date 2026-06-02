-- STEMwerk_Helpers.lua
-- Internal HELPERS module: UI label strings, file operations, stem naming,
-- color helpers, audibility utilities.
--
-- Loaded via dofile() from STEMwerk.lua. Populates the global HELPERS table.
-- Call HELPERS.configure({...}) immediately after dofile to inject locals.
--
-- Globals used directly (no injection needed):
--   SETTINGS, STEMS, OS, PATH_SEP, SW_LOG, debugLog,
--   normalizeColorMode, getItemDisplayNameForTakes, reaper
--
-- Injected via configure():
--   makeDir, adjustTrackLayout

local C = {}  -- injected context
local function helperFileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function HELPERS.configure(ctx)
    for k, v in pairs(ctx) do C[k] = v end
end

function HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stemName)
    local trackBase = tostring(sourceTrackName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local itemBase = tostring(sourceItemName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local stemBase = tostring(stemName or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if trackBase == "" then trackBase = "Track" end
    if itemBase == "" then itemBase = trackBase end
    if stemBase == "" then stemBase = "Stem" end

    local takeName = itemBase .. " - " .. stemBase
    local folderBase = trackBase
    if itemBase ~= "" and itemBase ~= trackBase then
        folderBase = trackBase .. " - " .. itemBase
    end

    return {
        folderBase = folderBase,
        trackName = folderBase .. " - " .. stemBase,
        takeName = takeName,
    }
end

function HELPERS.trimString(s)
    s = tostring(s or "")
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function HELPERS.getUiLanguageCode()
    local lang = tostring((SETTINGS and SETTINGS.language) or "en"):lower()
    if lang:find("nl", 1, true) == 1 then return "nl" end
    if lang:find("de", 1, true) == 1 then return "de" end
    return "en"
end

function HELPERS.getColorMode()
    SETTINGS.colorMode = normalizeColorMode(SETTINGS.colorMode)
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")
    return SETTINGS.colorMode
end

function HELPERS.setColorMode(mode)
    SETTINGS.colorMode = normalizeColorMode(mode)
    SETTINGS.applyTrackColors = (SETTINGS.colorMode ~= "no_track" and SETTINGS.colorMode ~= "off")
end

function HELPERS.cycleColorMode()
    local order = {
        both = "no_track",
        no_track = "off",
        off = "no_media",
        no_media = "both",
    }
    HELPERS.setColorMode(order[HELPERS.getColorMode()] or "both")
end

function HELPERS.isTrackColoringEnabled()
    local mode = HELPERS.getColorMode()
    return mode ~= "no_track" and mode ~= "off"
end

function HELPERS.isMediaColoringEnabled()
    local mode = HELPERS.getColorMode()
    return mode ~= "no_media" and mode ~= "off"
end

function HELPERS.getColorModeButtonLabel()
    local mode = HELPERS.getColorMode()
    if mode == "no_track" then
        return "Clr -T"
    elseif mode == "no_media" then
        return "Clr -M"
    elseif mode == "off" then
        return "Clr Off"
    end
    return "Clr T+M"
end

function HELPERS.getColorModeButtonColor()
    if HELPERS.getColorMode() == "off" then
        return {120, 120, 120}
    end
    return nil
end

function HELPERS.getColorModeTooltip()
    local mode = HELPERS.getColorMode()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then
        if mode == "no_track" then
            return "Trackkleur uit. Item/media-kleur blijft aan. Klik om te wisselen."
        elseif mode == "no_media" then
            return "Item/media-kleur uit. Trackkleur blijft aan. Klik om te wisselen."
        elseif mode == "off" then
            return "Track- en item/media-kleur uit. Klik om te wisselen."
        end
        return "Track- en item/media-kleur aan. Klik om te wisselen."
    elseif lang == "de" then
        if mode == "no_track" then
            return "Track-Farbe aus. Item/Medien-Farbe bleibt an. Klicken zum Wechseln."
        elseif mode == "no_media" then
            return "Item/Medien-Farbe aus. Track-Farbe bleibt an. Klicken zum Wechseln."
        elseif mode == "off" then
            return "Track- und Item/Medien-Farbe aus. Klicken zum Wechseln."
        end
        return "Track- und Item/Medien-Farbe an. Klicken zum Wechseln."
    end
    if mode == "no_track" then
        return "Track colors off. Item/media colors stay on. Click to cycle."
    elseif mode == "no_media" then
        return "Item/media colors off. Track colors stay on. Click to cycle."
    elseif mode == "off" then
        return "Track and item/media colors off. Click to cycle."
    end
    return "Track and item/media colors on. Click to cycle."
end

function HELPERS.applyTrackColorIfEnabled(track, color)
    if not (track and reaper.ValidatePtr(track, "MediaTrack*")) then return end
    if not HELPERS.isTrackColoringEnabled() then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.applyItemColorIfEnabled(item, color)
    if not (item and reaper.ValidatePtr(item, "MediaItem*")) then return end
    if not HELPERS.isMediaColoringEnabled() then
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.applyTakeColorIfEnabled(take, color)
    if not (take and reaper.ValidatePtr(take, "MediaItem_Take*")) then return end
    if not HELPERS.isMediaColoringEnabled() then
        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", 0)
        return
    end
    if color and color ~= 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", color)
    end
end

function HELPERS.getStemFileDestinationLabel()
    local mode = tostring(SETTINGS.stemFileDestination or "temp")
    if mode == "project_media" then
        return HELPERS.getStemFileProjectLabel and HELPERS.getStemFileProjectLabel() or "Project"
    elseif mode == "custom" then
        return HELPERS.getStemFileCustomLabel and HELPERS.getStemFileCustomLabel() or "Custom"
    end
    return "Temp"
end

function HELPERS.getStemFilesHeaderLabel()
    if type(T) == "function" then
        local localized = T("storage_label")
        if localized and localized ~= "" and localized ~= "storage_label" then
            return localized
        end
    end
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Opslag:" end
    if lang == "de" then return "Speicherort:" end
    return "Storage:"
end

function HELPERS.getStemFileProjectLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "de" then return "Projekt" end
    return "Project"
end

function HELPERS.getStemFileCustomLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Eigen" end
    if lang == "de" then return "Eigen" end
    return "Custom"
end

function HELPERS.getSetCustomPathLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Kies map" end
    if lang == "de" then return "Ordner" end
    return "Set folder"
end

function HELPERS.getCustomFolderPromptTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "STEMwerk aangepaste stemmap" end
    if lang == "de" then return "STEMwerk Stem-Ordner" end
    return "STEMwerk custom stem folder"
end

function HELPERS.getCustomFolderPromptLabel()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Mappad:" end
    if lang == "de" then return "Ordnerpfad:" end
    return "Folder path:"
end

function HELPERS.getStemFilesTempTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Bewaar de gemaakte stemfiles in de tijdelijke STEMwerk-map." end
    if lang == "de" then return "Speichert die erzeugten Stem-Dateien im temporären STEMwerk-Ordner." end
    return "Keep generated stem files in STEMwerk temp folders."
end

function HELPERS.getStemFilesProjectTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Verplaats de gemaakte stemfiles eerst naar de huidige REAPER-projectmap en importeer ze daarna." end
    if lang == "de" then return "Verschiebt die erzeugten Stem-Dateien zuerst in den aktuellen REAPER-Projektordner und importiert sie dann." end
    return "Move generated stem files to the current REAPER project path before importing."
end

function HELPERS.getStemFilesCustomTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Verplaats de gemaakte stemfiles eerst naar een eigen map en importeer ze daarna." end
    if lang == "de" then return "Verschiebt die erzeugten Stem-Dateien zuerst in einen eigenen Ordner und importiert sie dann." end
    return "Move generated stem files to a custom folder before importing."
end

function HELPERS.getStemFilesCustomPathTooltip()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Vul de doelmap voor de definitieve stemfiles in." end
    if lang == "de" then return "Zielordner für die finalen Stem-Dateien eingeben." end
    return "Enter the destination folder for final stem files."
end

function HELPERS.getStemFilesWarningTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Stem files" end
    if lang == "de" then return "Stem-Dateien" end
    return "Stem files"
end

function HELPERS.getStemFilesMissingCustomWarning()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Stel eerst een eigen stemmap in, of zet Stem files terug op Temp/Project." end
    if lang == "de" then return "Zuerst einen eigenen Stem-Ordner festlegen, oder Stem-Dateien auf Temp/Projekt zurücksetzen." end
    return "Set a custom stem folder first, or switch Stem files back to Temp/Project."
end

function HELPERS.getStemFilesProjectUnavailableWarning()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Project is niet beschikbaar voor dit project. Sla het project eerst op, of gebruik Temp/Custom." end
    if lang == "de" then return "Projekt ist für dieses Projekt nicht verfügbar. Projekt zuerst speichern, oder Temp/Custom verwenden." end
    return "Project is unavailable for this project. Save the project first, or use Temp/Custom."
end

function HELPERS.getNoAudibleTargetsTitle()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then return "Geen hoorbare doelwitten" end
    if lang == "de" then return "Keine hörbaren Ziele" end
    return "No audible targets"
end

function HELPERS.getNoAudibleTargetsMessage()
    local lang = HELPERS.getUiLanguageCode()
    if lang == "nl" then
        return "Er is wel audio binnen de huidige selectie, maar alle overeenkomende tracks/items zijn gemute of niet solo-hoorbaar.\n\nUnmute de relevante track of item, of pas de solo-status aan, en probeer opnieuw."
    end
    if lang == "de" then
        return "Innerhalb der aktuellen Auswahl gibt es Audio, aber alle passenden Tracks/Items sind stummgeschaltet oder wegen Solo nicht hörbar.\n\nRelevanten Track oder Item entstummen oder den Solo-Status anpassen und erneut versuchen."
    end
    return "There is audio inside the current selection, but all matching tracks/items are muted or not solo-audible.\n\nUnmute the relevant track or item, or adjust solo state, then try again."
end

function HELPERS.isNoAudibleTargetsError(err)
    local s = string.lower(tostring(err or ""))
    if s == "" then return false end
    if s:find("no audible targets overlap", 1, true) then return true end
    if s:find("muted or not solo%-audible") then return true end
    if s:find("geen hoorbare doelwitten", 1, true) then return true end
    if s:find("keine hörbaren ziele", 1, true) then return true end
    if s:find("keine hoerbaren ziele", 1, true) then return true end
    return false
end

function HELPERS.getSelectionMonitorPrompt()
    local state = HELPERS.getSelectionMonitorState()
    local lang = HELPERS.getUiLanguageCode()
    if state and state.hasSource and not state.actionable then
        if lang == "nl" then
            return HELPERS.getNoAudibleTargetsTitle(), "Selecteer audio of maak tracks/items hoorbaar in REAPER."
        end
        if lang == "de" then
            return HELPERS.getNoAudibleTargetsTitle(), "Audio auswählen oder Tracks/Items in REAPER hörbar machen."
        end
        return HELPERS.getNoAudibleTargetsTitle(), "Select audio or make tracks/items audible in REAPER."
    end
    if lang == "nl" then
        return "Start", "Selecteer audio in REAPER"
    end
    if lang == "de" then
        return "Start", "Audio in REAPER auswählen"
    end
    return "Start", "Select audio in REAPER"
end

function HELPERS.getProjectMediaDir()
    local projectPath = nil
    if reaper and reaper.GetProjectPathEx then
        local ok, result = pcall(reaper.GetProjectPathEx, 0, "")
        if ok and type(result) == "string" and result ~= "" then
            projectPath = result
        end
    end
    if (not projectPath or projectPath == "") and reaper and reaper.GetProjectPath then
        local ok, result = pcall(reaper.GetProjectPath, "")
        if ok and type(result) == "string" and result ~= "" then
            projectPath = result
        end
    end
    projectPath = HELPERS.trimString(projectPath)
    if projectPath == "" then return nil end
    return projectPath
end

function HELPERS.resolveFinalStemOutputDir()
    local mode = tostring(SETTINGS.stemFileDestination or "temp")
    if mode == "project_media" then
        return HELPERS.getProjectMediaDir()
    elseif mode == "custom" then
        local customDir = HELPERS.trimString(SETTINGS.customStemDir)
        if customDir ~= "" then
            return customDir
        end
        return nil
    end
    return nil
end

function HELPERS.sanitizeStemFilenamePart(name)
    local s = HELPERS.trimString(name)
    if s == "" then s = "Stem" end
    s = s:gsub("[<>:\"/\\|%?%*]", "_")
    s = s:gsub("[%c]", "_")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%.+", "")
    s = s:gsub("%.+$", "")
    s = s:gsub("%s+$", "")
    if s == "" then s = "Stem" end
    return s
end

function HELPERS.makeUniqueFilePath(dir, baseName, ext)
    local safeBase = HELPERS.sanitizeStemFilenamePart(baseName)
    local safeExt = ext or ""
    local candidate = dir .. PATH_SEP .. safeBase .. safeExt
    local counter = 2
    while helperFileExists(candidate) do
        candidate = dir .. PATH_SEP .. safeBase .. "_" .. tostring(counter) .. safeExt
        counter = counter + 1
    end
    return candidate
end

function HELPERS.copyFile(src, dst)
    local inFile = io.open(src, "rb")
    if not inFile then return false end
    local outFile = io.open(dst, "wb")
    if not outFile then
        inFile:close()
        return false
    end
    local data = inFile:read("*all")
    inFile:close()
    if not data then
        outFile:close()
        os.remove(dst)
        return false
    end
    outFile:write(data)
    outFile:close()
    return true
end

function HELPERS.moveFile(src, dst)
    if src == dst then return true end
    local ok = os.rename(src, dst)
    if ok then return true end
    if HELPERS.copyFile(src, dst) then
        os.remove(src)
        return true
    end
    return false
end

function HELPERS.getStemNamingContextForItem(item, fallbackTrackName, fallbackItemName)
    local trackName = HELPERS.trimString(fallbackTrackName)
    local itemName = HELPERS.trimString(fallbackItemName)
    if item and reaper.ValidatePtr(item, "MediaItem*") then
        local track = reaper.GetMediaItem_Track(item)
        if track then
            local _, tn = reaper.GetTrackName(track)
            trackName = HELPERS.trimString(tn)
        end
        local display = getItemDisplayNameForTakes(item)
        if display and display ~= "" then
            itemName = HELPERS.trimString(display)
        end
    end
    if trackName == "" then trackName = "Track" end
    if itemName == "" then itemName = fallbackItemName or trackName end
    return trackName, itemName
end

function HELPERS.finalizeStemFiles(stems, sourceTrackName, sourceItemName)
    local finalDir = HELPERS.resolveFinalStemOutputDir()
    if not finalDir or finalDir == "" then
        return stems, nil
    end

    C.makeDir(finalDir)
    local moved = {}
    local relocated = {}
    for _, stem in ipairs(STEMS) do
        local key = stem.name:lower()
        local src = stems[key]
        if src then
            local names = HELPERS.buildStemOutputNames(sourceTrackName, sourceItemName, stem.name)
            local dst = HELPERS.makeUniqueFilePath(finalDir, names.takeName, ".wav")
            if HELPERS.moveFile(src, dst) then
                relocated[key] = dst
                moved[#moved + 1] = dst
            else
                relocated[key] = src
            end
        end
    end
    return relocated, moved
end

function HELPERS.refreshImportedMediaItems(items, sourcePaths)
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
    C.adjustTrackLayout()
end

function HELPERS.forceArrangeRefresh()
    if reaper.PreventUIRefresh then
        pcall(reaper.PreventUIRefresh, 1)
    end
    C.adjustTrackLayout()
    if reaper.PreventUIRefresh then
        pcall(reaper.PreventUIRefresh, -1)
    end
    C.adjustTrackLayout()
end

function HELPERS.scheduleResultWindowRefresh()
    local step = 0
    local function tick()
        step = step + 1
        HELPERS.forceArrangeRefresh()

        if reaper.JS_Window_SetFocus then
            local mainHwnd = reaper.GetMainHwnd and reaper.GetMainHwnd() or nil
            if mainHwnd then
                pcall(reaper.JS_Window_SetFocus, mainHwnd)
            end
        end

        if step < 6 then
            reaper.defer(tick)
        end
    end

    reaper.defer(tick)
end

-- Best-effort: kill a Windows process tree from a pid file
function HELPERS.killWindowsProcessFromPidFile(pidFile)
    if OS ~= "Windows" then return false end
    if not pidFile or pidFile == "" then return false end
    local f = io.open(pidFile, "r")
    if not f then return false end
    local pidStr = (f:read("*l") or ""):match("%d+")
    f:close()
    local pid = tonumber(pidStr)
    if not pid or pid <= 0 then return false end

    local cmd = string.format('taskkill /PID %d /T /F', pid)
    debugLog("Killing process tree: " .. cmd)
    if reaper and reaper.ExecProcess then
        reaper.ExecProcess(cmd, 0)
    else
        os.execute(cmd .. " >nul 2>nul")
    end
    return true
end

-- Best-effort: kill a Unix process from a pid file
function HELPERS.killUnixProcessFromPidFile(pidFile)
    if OS == "Windows" then return false end
    if not pidFile or pidFile == "" then return false end
    local f = io.open(pidFile, "r")
    if not f then return false end
    local pidStr = (f:read("*l") or ""):match("%d+")
    f:close()
    local pid = tonumber(pidStr)
    if not pid or pid <= 0 then return false end

    local function dirname(path)
        if not path then return "" end
        local d = tostring(path):match("^(.*)[/\\][^/\\]+$")
        return d or ""
    end
    local runDir = dirname(pidFile)
    local runDirLower = tostring(runDir):lower()
    local function shellRead(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if not h then return "" end
        local out = h:read("*a") or ""
        h:close()
        return out
    end
    local function pidAlive(checkPid)
        local ok = os.execute("kill -0 " .. tostring(checkPid) .. " 2>/dev/null")
        return ok == true or ok == 0
    end
    local function readCmdline(checkPid)
        local cmd = shellRead("ps -p " .. tostring(checkPid) .. " -o command="):gsub("%s+$", "")
        return cmd
    end
    local function isRelevantProcess(checkPid)
        local cmd = readCmdline(checkPid)
        if cmd == "" then return false end
        local lower = cmd:lower()
        if lower:find("audio_separator_process.py", 1, true) then return true end
        if runDirLower ~= "" and lower:find(runDirLower, 1, true) then return true end
        if lower:find("run_bg.sh", 1, true) and runDirLower ~= "" and lower:find(runDirLower, 1, true) then return true end
        return false
    end
    local function listChildren(parentPid)
        local out = shellRead("pgrep -P " .. tostring(parentPid))
        local kids = {}
        for line in out:gmatch("[^\r\n]+") do
            local n = tonumber((line or ""):match("%d+"))
            if n and n > 0 then kids[#kids + 1] = n end
        end
        return kids
    end

    local queue, seen, ordered = { pid }, {}, {}
    while #queue > 0 do
        local cur = table.remove(queue, 1)
        if cur and cur > 0 and not seen[cur] then
            seen[cur] = true
            ordered[#ordered + 1] = cur
            local kids = listChildren(cur)
            for _, k in ipairs(kids) do
                if not seen[k] then queue[#queue + 1] = k end
            end
        end
    end

    local targets = {}
    for _, p in ipairs(ordered) do
        if pidAlive(p) and isRelevantProcess(p) then
            targets[#targets + 1] = p
        end
    end
    if #targets == 0 and pidAlive(pid) then
        -- Fallback for older launchers where only a shell PID is known; limit by immediate children.
        local kids = listChildren(pid)
        for _, k in ipairs(kids) do
            if pidAlive(k) and isRelevantProcess(k) then
                targets[#targets + 1] = k
            end
        end
    end
    if #targets == 0 then
        debugLog("killUnixProcessFromPidFile: no relevant live targets for " .. tostring(pidFile) .. " pid=" .. tostring(pid))
        return false
    end

    for _, p in ipairs(targets) do
        os.execute("kill -TERM " .. tostring(p) .. " 2>/dev/null")
    end
    os.execute("sleep 0.3")
    for _, p in ipairs(targets) do
        if pidAlive(p) then
            os.execute("kill -KILL " .. tostring(p) .. " 2>/dev/null")
        end
    end
    return true
end

-- Cross-platform kill wrapper
function HELPERS.killProcessFromPidFile(pidFile)
    if OS == "Windows" then
        return HELPERS.killWindowsProcessFromPidFile(pidFile)
    end
    return HELPERS.killUnixProcessFromPidFile(pidFile)
end
