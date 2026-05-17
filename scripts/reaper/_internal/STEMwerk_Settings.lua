-- STEMwerk_Settings.lua
-- Internal settings module: ExtState persistence and startup restore of the
-- main window position. Live geometry capture stays in STEMwerk.lua for now.

local SETTINGS_MOD = {}
local C = {}

function SETTINGS_MOD.configure(ctx)
    for k, v in pairs(ctx or {}) do
        C[k] = v
    end
end

local function normalizeLanguageCode(value)
    local v = tostring(value or ""):lower()
    if v == "" then return nil end

    if v:find("nl", 1, true) == 1 then return "nl" end
    if v:find("de", 1, true) == 1 then return "de" end
    if v:find("en", 1, true) == 1 then return "en" end

    if v:find("dutch", 1, true) or v:find("neder", 1, true) then return "nl" end
    if v:find("german", 1, true) or v:find("deutsch", 1, true) then return "de" end
    if v:find("english", 1, true) then return "en" end

    if v:find("nl_", 1, true) or v:find("_nl", 1, true) or v:find("nl-", 1, true) then return "nl" end
    if v:find("de_", 1, true) or v:find("_de", 1, true) or v:find("de-", 1, true) then return "de" end
    if v:find("en_", 1, true) or v:find("_en", 1, true) or v:find("en-", 1, true) then return "en" end

    return nil
end

local function detectSystemLanguage()
    local candidates = {}
    local function addCandidate(v)
        if type(v) == "string" and v ~= "" then
            candidates[#candidates + 1] = v
        end
    end

    if os and os.setlocale then
        local okCtype, ctypeLocale = pcall(function() return os.setlocale(nil, "ctype") end)
        if okCtype then addCandidate(ctypeLocale) end
        local okDefault, defaultLocale = pcall(function() return os.setlocale() end)
        if okDefault then addCandidate(defaultLocale) end
    end

    if os and os.getenv then
        addCandidate(os.getenv("LC_ALL"))
        addCandidate(os.getenv("LC_MESSAGES"))
        addCandidate(os.getenv("LANGUAGE"))
        addCandidate(os.getenv("LANG"))
        addCandidate(os.getenv("PreferredUILanguages"))
    end

    for _, raw in ipairs(candidates) do
        local detected = normalizeLanguageCode(raw)
        if detected then
            return detected
        end
    end

    return "en"
end

function SETTINGS_MOD.normalizeColorMode(mode)
    mode = tostring(mode or "")
    if mode == "no_track" or mode == "no_media" or mode == "off" then
        return mode
    end
    return "both"
end

function SETTINGS_MOD.normalizeOutputGrouping(value)
    local v = tostring(value or ""):lower()
    if v == "source_track" then
        return "source_track"
    end
    return "per_item"
end

function SETTINGS_MOD.loadSavedMainWindowPos()
    local getExtState = C.reaper and C.reaper.GetExtState
    if not getExtState then return end

    local savedPosMain = C.reaper.GetExtState(C.EXT_SECTION, "window_pos_main")
    if savedPosMain == "" then
        savedPosMain = C.reaper.GetExtState(C.EXT_SECTION, "window_pos")
    end

    if savedPosMain ~= "" then
        local sx, sy, sw, sh = savedPosMain:match("([^,]+),([^,]+),([^,]+),([^,]+)")
        if sx and sy and sw and sh then
            local x = tonumber(sx)
            local y = tonumber(sy)
            local w = math.max(840, tonumber(sw))
            local h = math.max(600, tonumber(sh))
            C.setWindowState(x, y, w, h)
        end
    end
end

function SETTINGS_MOD.load()
    C.refreshModelAvailability()

    local model = C.reaper.GetExtState(C.EXT_SECTION, "model")
    if model ~= "" then C.SETTINGS.model = model end

    local createNewTracks = C.reaper.GetExtState(C.EXT_SECTION, "createNewTracks")
    if createNewTracks ~= "" then C.SETTINGS.createNewTracks = (createNewTracks == "1") end

    local createFolder = C.reaper.GetExtState(C.EXT_SECTION, "createFolder")
    if createFolder ~= "" then C.SETTINGS.createFolder = (createFolder == "1") end

    local outputGrouping = C.reaper.GetExtState(C.EXT_SECTION, "outputGrouping")
    if outputGrouping ~= "" then
        C.SETTINGS.outputGrouping = SETTINGS_MOD.normalizeOutputGrouping(outputGrouping)
    else
        C.SETTINGS.outputGrouping = SETTINGS_MOD.normalizeOutputGrouping(C.SETTINGS.outputGrouping)
    end

    local colorMode = C.reaper.GetExtState(C.EXT_SECTION, "colorMode")
    if colorMode ~= "" then
        C.SETTINGS.colorMode = SETTINGS_MOD.normalizeColorMode(colorMode)
    else
        local applyTrackColors = C.reaper.GetExtState(C.EXT_SECTION, "applyTrackColors")
        if applyTrackColors ~= "" then
            C.SETTINGS.colorMode = (applyTrackColors == "1") and "both" or "no_track"
        end
    end
    C.SETTINGS.applyTrackColors = (C.SETTINGS.colorMode ~= "no_track" and C.SETTINGS.colorMode ~= "off")

    local stemFileDestination = C.reaper.GetExtState(C.EXT_SECTION, "stemFileDestination")
    if stemFileDestination ~= "" then C.SETTINGS.stemFileDestination = stemFileDestination end

    local customStemDir = C.reaper.GetExtState(C.EXT_SECTION, "customStemDir")
    if customStemDir ~= "" then C.SETTINGS.customStemDir = customStemDir end

    local postProcessTakes = C.reaper.GetExtState(C.EXT_SECTION, "postProcessTakes")
    if postProcessTakes ~= "" then C.SETTINGS.postProcessTakes = postProcessTakes end

    local muteOriginal = C.reaper.GetExtState(C.EXT_SECTION, "muteOriginal")
    if muteOriginal ~= "" then C.SETTINGS.muteOriginal = (muteOriginal == "1") end

    local muteSelection = C.reaper.GetExtState(C.EXT_SECTION, "muteSelection")
    if muteSelection ~= "" then C.SETTINGS.muteSelection = (muteSelection == "1") end

    local deleteOriginal = C.reaper.GetExtState(C.EXT_SECTION, "deleteOriginal")
    if deleteOriginal ~= "" then C.SETTINGS.deleteOriginal = (deleteOriginal == "1") end

    local deleteSelection = C.reaper.GetExtState(C.EXT_SECTION, "deleteSelection")
    if deleteSelection ~= "" then C.SETTINGS.deleteSelection = (deleteSelection == "1") end

    local deleteOriginalTrack = C.reaper.GetExtState(C.EXT_SECTION, "deleteOriginalTrack")
    if deleteOriginalTrack ~= "" then C.SETTINGS.deleteOriginalTrack = (deleteOriginalTrack == "1") end

    local muteOriginalTrack = C.reaper.GetExtState(C.EXT_SECTION, "muteOriginalTrack")
    if muteOriginalTrack ~= "" then C.SETTINGS.muteOriginalTrack = (muteOriginalTrack == "1") end

    local darkMode = C.reaper.GetExtState(C.EXT_SECTION, "darkMode")
    if darkMode ~= "" then C.SETTINGS.darkMode = (darkMode == "1") end

    local themePreset = C.reaper.GetExtState(C.EXT_SECTION, "themePreset")
    if themePreset ~= "" then C.SETTINGS.themePreset = themePreset end
    C.SETTINGS.themePreset = C.normalizeThemePreset(C.SETTINGS.themePreset)
    C.updateTheme()

    local parallelProcessing = C.reaper.GetExtState(C.EXT_SECTION, "parallelProcessing")
    if parallelProcessing ~= "" then C.SETTINGS.parallelProcessing = (parallelProcessing == "1") end

    local visualFX = C.reaper.GetExtState(C.EXT_SECTION, "visualFX")
    if visualFX ~= "" then C.SETTINGS.visualFX = (visualFX == "1") end

    local tooltips = C.reaper.GetExtState(C.EXT_SECTION, "tooltips")
    if tooltips ~= "" then C.SETTINGS.tooltips = (tooltips == "1") end

    if not (C.GUI and C.GUI.windowPosLoaded) then
        local savedPos = C.reaper.GetExtState(C.EXT_SECTION, "window_pos_main")
        if savedPos == "" then savedPos = C.reaper.GetExtState(C.EXT_SECTION, "window_pos") end
        if savedPos ~= "" then
            local sx, sy, sw, sh = savedPos:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            if sx and sy then
                local x = tonumber(sx)
                local y = tonumber(sy)
                local w = tonumber(sw) or 840
                local h = tonumber(sh) or 600
                C.setWindowState(x, y, w, h)

                if C.GUI then
                    C.GUI.savedX = x
                    C.GUI.savedY = y
                    C.GUI.savedW = w
                    C.GUI.savedH = h
                end
            end
        end
        if C.GUI then
            C.GUI.windowPosLoaded = true
        end
    end

    local keepTempFiles = C.reaper.GetExtState(C.EXT_SECTION, "keepTempFiles")
    if keepTempFiles ~= "" then C.SETTINGS.keepTempFiles = (keepTempFiles == "1") end

    local device = C.reaper.GetExtState(C.EXT_SECTION, "device")
    if device ~= "" then C.SETTINGS.device = device end
    if C.OS == "macOS" and C.ARCH == "arm64" and tostring(C.SETTINGS.device or "") == "mps" then
        C.SETTINGS.device = "cpu"
    end

    local language = C.reaper.GetExtState(C.EXT_SECTION, "language")
    local normalizedLanguage = normalizeLanguageCode(language)
    if normalizedLanguage then
        C.SETTINGS.language = normalizedLanguage
    else
        C.SETTINGS.language = "en"
    end
    C.reaper.SetExtState(C.EXT_SECTION, "language", C.SETTINGS.language, true)

    local appliedLanguage = C.setLanguage(C.SETTINGS.language)
    if not appliedLanguage then
        C.SETTINGS.language = "en"
        C.setLanguage(C.SETTINGS.language)
        C.reaper.SetExtState(C.EXT_SECTION, "language", C.SETTINGS.language, true)
    end

    for i, stem in ipairs(C.STEMS) do
        local sel = C.reaper.GetExtState(C.EXT_SECTION, "stem_" .. stem.name)
        if sel ~= "" then C.STEMS[i].selected = (sel == "1") end
    end

    if tostring(C.SETTINGS.model or "") ~= "htdemucs_6s" then
        for _, stem in ipairs(C.STEMS) do
            if stem.sixStemOnly then
                stem.selected = false
            end
        end
    end

    -- Keep the saved model selection intact here; run/start validation handles availability.
end

function SETTINGS_MOD.persistWindowPos()
    local x, y, w, h = C.getWindowState()
    local saveW = (w and w > 0) and w or ((gfx and gfx.w and gfx.w > 0) and gfx.w or nil)
    local saveH = (h and h > 0) and h or ((gfx and gfx.h and gfx.h > 0) and gfx.h or nil)
    if x and y and saveW and saveH then
        local posStr = string.format("%d,%d,%d,%d", math.floor(x), math.floor(y), math.floor(saveW), math.floor(saveH))
        C.reaper.SetExtState(C.EXT_SECTION, "window_pos", posStr, true)
        C.reaper.SetExtState(C.EXT_SECTION, "window_pos_main", posStr, true)
        if C.GUI then
            C.GUI.windowPosLoaded = true
        end

        C.reaper.DeleteExtState(C.EXT_SECTION, "windowX", true)
        C.reaper.DeleteExtState(C.EXT_SECTION, "windowY", true)
        C.reaper.DeleteExtState(C.EXT_SECTION, "windowWidth", true)
        C.reaper.DeleteExtState(C.EXT_SECTION, "windowHeight", true)
    end
end

function SETTINGS_MOD.save()
    C.reaper.SetExtState(C.EXT_SECTION, "model", C.SETTINGS.model, true)
    C.reaper.SetExtState(C.EXT_SECTION, "createNewTracks", C.SETTINGS.createNewTracks and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "createFolder", C.SETTINGS.createFolder and "1" or "0", true)
    C.SETTINGS.outputGrouping = SETTINGS_MOD.normalizeOutputGrouping(C.SETTINGS.outputGrouping)
    C.reaper.SetExtState(C.EXT_SECTION, "outputGrouping", C.SETTINGS.outputGrouping, true)
    C.SETTINGS.colorMode = SETTINGS_MOD.normalizeColorMode(C.SETTINGS.colorMode)
    C.SETTINGS.applyTrackColors = (C.SETTINGS.colorMode ~= "no_track" and C.SETTINGS.colorMode ~= "off")
    C.reaper.SetExtState(C.EXT_SECTION, "applyTrackColors", C.SETTINGS.applyTrackColors and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "colorMode", C.SETTINGS.colorMode, true)
    C.reaper.SetExtState(C.EXT_SECTION, "stemFileDestination", tostring(C.SETTINGS.stemFileDestination or "temp"), true)
    C.reaper.SetExtState(C.EXT_SECTION, "customStemDir", tostring(C.SETTINGS.customStemDir or ""), true)
    C.reaper.SetExtState(C.EXT_SECTION, "postProcessTakes", tostring(C.SETTINGS.postProcessTakes or "none"), true)
    C.reaper.SetExtState(C.EXT_SECTION, "muteOriginal", C.SETTINGS.muteOriginal and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "muteSelection", C.SETTINGS.muteSelection and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "deleteOriginal", C.SETTINGS.deleteOriginal and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "deleteSelection", C.SETTINGS.deleteSelection and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "deleteOriginalTrack", C.SETTINGS.deleteOriginalTrack and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "muteOriginalTrack", C.SETTINGS.muteOriginalTrack and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "darkMode", C.SETTINGS.darkMode and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "themePreset", tostring(C.SETTINGS.themePreset or "classic"), true)
    C.reaper.SetExtState(C.EXT_SECTION, "parallelProcessing", C.SETTINGS.parallelProcessing and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "visualFX", C.SETTINGS.visualFX and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "tooltips", C.SETTINGS.tooltips and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "keepTempFiles", C.SETTINGS.keepTempFiles and "1" or "0", true)
    C.reaper.SetExtState(C.EXT_SECTION, "language", C.SETTINGS.language, true)
    if C.OS == "macOS" and C.ARCH == "arm64" and tostring(C.SETTINGS.device or "") == "mps" then
        C.SETTINGS.device = "cpu"
    end
    C.reaper.SetExtState(C.EXT_SECTION, "device", C.SETTINGS.device, true)

    for _, stem in ipairs(C.STEMS) do
        C.reaper.SetExtState(C.EXT_SECTION, "stem_" .. stem.name, stem.selected and "1" or "0", true)
    end

    SETTINGS_MOD.persistWindowPos()
end

return SETTINGS_MOD
