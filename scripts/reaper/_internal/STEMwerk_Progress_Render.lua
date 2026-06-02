-- STEMwerk_Progress_Render.lua
-- Progress window UI helpers: text/stage formatting, terminal FX animation,
-- waveform state, window resize helper.
-- Loaded at startup; call configure() once progressState is available.

local M = {}

local PROGRESS_BASE_W = 480
local PROGRESS_BASE_H = 420

-- Injected at runtime via configure() for functions that need progressState.
local _deps = {}

function M.configure(deps)
    _deps.progressState               = deps.progressState
    _deps.getProcessingWindowTitle    = deps.getProcessingWindowTitle
    _deps.warnMissingJsWindowStyleApi = deps.warnMissingJsWindowStyleApi
end

-- ── Text helpers ──────────────────────────────────────────────────────────────

local function progressUiLabel(key, fallback)
    local translated = T(key)
    local rawKey = tostring(key or "")
    local humanized = rawKey:gsub("_", " ")
    if translated == nil then
        return fallback
    end
    translated = tostring(translated)
    if translated == "" or translated == rawKey or translated == humanized then
        return fallback
    end
    return translated
end

local function progressWorkflowSource()
    local ps = _deps.progressState or {}
    return tostring(ps.workflowSource or "")
end

local function isExtractDrumKitProgress()
    return progressWorkflowSource() == "dks_extract"
end

local function isDirectDrumKitProgress()
    return progressWorkflowSource() == "dks_direct"
end

local function stagePrefixLabel(stageIndex)
    if stageIndex == 1 then
        return progressUiLabel("progress_stage_label_1_of_2", "Stage 1/2")
    elseif stageIndex == 2 then
        return progressUiLabel("progress_stage_label_2_of_2", "Stage 2/2")
    end
    return ""
end

local function inferDrumKitStageIndex(stageText)
    local lower = tostring(stageText or ""):lower()
    if lower:find("stage 1", 1, true) or lower:find("extracting drums", 1, true) then
        return 1
    end
    if lower:find("stage 2", 1, true)
        or lower:find("starting drum kit runtime", 1, true)
        or lower:find("splitting drum kit", 1, true)
        or lower:find("writing drum tracks", 1, true)
        or lower:find("drumsep stage2 separating kit stems", 1, true)
    then
        return 2
    end
    return nil
end

local function decorateDrumKitStage(stageText, rawStage)
    if not isExtractDrumKitProgress() then
        return stageText
    end
    local stageIndex = inferDrumKitStageIndex(rawStage or stageText)
    if not stageIndex then
        return stageText
    end
    local prefix = stagePrefixLabel(stageIndex)
    if prefix == "" then
        return stageText
    end
    local normalized = tostring(stageText or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then
        return prefix
    end
    if normalized:find(prefix, 1, true) == 1 then
        return normalized
    end
    return prefix .. ": " .. normalized
end

local function normalizeProgressStage(stage)
    local rawStage = tostring(stage or "")
    stage = rawStage
    stage = stage:gsub("%s*%b[]", "")
    stage = stage:gsub("%s*%b()", "")
    stage = stage:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = stage:lower()
    if stage == "" then
        stage = progressUiLabel("progress_stage_processing", "Processing")
    elseif lower:match("^processing[%s%.]*$") then
        stage = progressUiLabel("progress_stage_processing", "Processing")
    else
        local key = nil
        local flat = lower:gsub("[%s%.:]+$", "")
        if flat == "initializing" then
            key = "progress_initializing"
        elseif flat == "loading model" then
            key = "progress_stage_loading_model"
        elseif flat == "loading ai model" then
            key = "progress_stage_loading_ai_model"
        elseif flat == "starting separation" then
            key = "progress_stage_starting_separation"
        elseif flat == "preparing direct drum kit" then
            key = "progress_stage_preparing_direct_drum_kit"
        elseif flat == "starting drum kit runtime" then
            key = "progress_stage_starting_drum_kit_runtime"
        elseif flat == "splitting drum kit" then
            key = "progress_stage_splitting_drum_kit"
        elseif flat == "drumsep stage2 separating kit stems" then
            key = "progress_stage_splitting_drum_kit"
        elseif flat == "writing drum tracks" then
            key = "progress_stage_writing_drum_tracks"
        elseif flat == "writing stems" then
            key = "progress_stage_writing_stems"
        elseif flat == "complete" then
            key = "progress_stage_complete"
        end
        if key then
            stage = progressUiLabel(key, stage)
        end
    end
    return decorateDrumKitStage(stage, rawStage)
end

local function localizeProgressStagePrefix(stageText)
    local text = tostring(stageText or "")
    if text == "" then return text end
    local map = {
        {"initializing",        progressUiLabel("progress_initializing",             "Initializing")},
        {"processing",          progressUiLabel("progress_stage_processing",         "Processing")},
        {"loading ai model",    progressUiLabel("progress_stage_loading_ai_model",   "Loading AI model")},
        {"loading model",       progressUiLabel("progress_stage_loading_model",      "Loading model")},
        {"starting separation", progressUiLabel("progress_stage_starting_separation","Starting separation")},
        {"preparing direct drum kit", progressUiLabel("progress_stage_preparing_direct_drum_kit","Preparing Direct Drum Kit...")},
        {"starting drum kit runtime", progressUiLabel("progress_stage_starting_drum_kit_runtime","Starting Drum Kit runtime...")},
        {"splitting drum kit", progressUiLabel("progress_stage_splitting_drum_kit","Splitting drum kit...")},
        {"drumsep stage2 separating kit stems", progressUiLabel("progress_stage_splitting_drum_kit","Splitting drum kit...")},
        {"writing drum tracks", progressUiLabel("progress_stage_writing_drum_tracks","Writing drum tracks...")},
        {"writing stems",       progressUiLabel("progress_stage_writing_stems",      "Writing stems")},
        {"complete",            progressUiLabel("progress_stage_complete",           "Complete")},
    }
    local trimmed = text:gsub("^%s+", "")
    local lower = trimmed:lower()
    for _, entry in ipairs(map) do
        local src, dst = entry[1], entry[2]
        if lower == src
            or lower:sub(1, #src + 1) == (src .. " ")
            or lower:sub(1, #src + 1) == (src .. "(")
            or lower:sub(1, #src + 1) == (src .. "[")
            or lower:sub(1, #src + 1) == (src .. ".")
        then
            local suffix = trimmed:sub(#src + 1)
            suffix = suffix:gsub("^%s+", "")
            local suffixLower = suffix:lower()
            if suffixLower == src
                or suffixLower:sub(1, #src + 1) == (src .. " ")
                or suffixLower:sub(1, #src + 1) == (src .. "(")
                or suffixLower:sub(1, #src + 1) == (src .. "[")
            then
                suffix = suffix:sub(#src + 1)
                suffix = suffix:gsub("^%s+", "")
            end
            if suffix ~= "" then
                return dst .. " " .. suffix
            end
            return dst
        end
    end
    return decorateDrumKitStage(text, stageText)
end

local function readableTerminalAccent(r, g, b)
    if SETTINGS.darkMode then
        return r, g, b
    end
    local dr = math.max(0.07, math.min(0.33, (r * 0.26) + 0.05))
    local dg = math.max(0.08, math.min(0.36, (g * 0.28) + 0.06))
    local db = math.max(0.07, math.min(0.34, (b * 0.26) + 0.05))
    return dr, dg, db
end

local function formatProgressLine(rawLine, trackIdx)
    if not rawLine or rawLine == "" then return nil end
    local percent, stage = rawLine:match("PROGRESS:(%d+):(.+)")
    if not percent then return nil end
    local progressLabel = T("progress_label") or "Progress"
    local stageLabel = normalizeProgressStage(stage)
    local prefix = ""
    if trackIdx then
        local trackLabel = T("track_prefix") or "Track"
        prefix = "[" .. tostring(trackLabel) .. " " .. tostring(trackIdx) .. "] "
    end
    return string.format("%s%s: %s%% %s", prefix, progressLabel, percent, stageLabel)
end

-- ── Terminal FX animation ─────────────────────────────────────────────────────

local function drawTerminalFx(x, y, w, h, now, borderR, borderG, borderB, progR, progG, progB)
    if not SETTINGS.visualFX then return end
    if not x or not y or not w or not h then return end
    if w < 4 or h < 4 then return end
    now = now or os.clock()
    local scale = 1
    if PROGRESS_BASE_W and PROGRESS_BASE_H then
        scale = math.min(w / PROGRESS_BASE_W, h / PROGRESS_BASE_H)
        scale = math.max(0.5, math.min(4.0, scale))
    end
    local function px(val) return math.floor(val * scale + 0.5) end

    local scanY = y + (math.floor(now * 22) % math.max(1, math.floor(h - 2)))
    gfx.set(borderR or 0, borderG or 0, borderB or 0, SETTINGS.darkMode and 0.12 or 0.18)
    gfx.rect(x + 1, scanY, w - 2, 1, 1)

    local lineStep = px(4)
    local lineAlpha = SETTINGS.darkMode and 0.05 or 0.04
    gfx.set(borderR or 0, borderG or 0, borderB or 0, lineAlpha)
    for yy = y + 1, y + h - 2, lineStep do
        gfx.line(x + 1, yy, x + w - 2, yy)
    end

    local barH = px(5)
    local barW = math.max(px(28), 14)
    local pad = px(4)
    local span = math.max(1, w - (pad * 2) - barW)
    local cycle = 0.72
    local theta = now * cycle * (math.pi * 2)
    local smooth = (1 - math.cos(theta)) * 0.5
    local velocity = math.sin(theta)
    local edge = 1 - math.min(smooth, 1 - smooth) * 2
    local squash = edge * edge
    local ledW = barW * (1 - 0.18 * squash)
    local ledH = barH * (1 + 0.12 * squash)
    local ledX = x + pad + (span * smooth) + (barW - ledW) * 0.5
    local ledY = y + h - pad - ledH
    local glowW = ledW * 1.6
    local glowH = ledH * 1.6
    local glowX = ledX - (glowW - ledW) * 0.5
    local glowY = ledY - (glowH - ledH) * 0.5
    local ledR = progR or 1
    local ledG = progG or 1
    local ledB = progB or 1
    local lum = (ledR * 0.2126) + (ledG * 0.7152) + (ledB * 0.0722)
    local hot = math.max(0, math.min(1, (0.55 - lum) * 1.6))
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.18 or 0.12)
    gfx.rect(glowX, glowY, glowW, glowH, 1)

    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.7 or 0.6)
    gfx.rect(ledX, ledY, ledW, ledH, 1)

    local coreW = ledW * 0.55
    local coreH = ledH * 0.55
    local coreX = ledX + (ledW - coreW) * 0.5
    local coreY = ledY + (ledH - coreH) * 0.5
    local coreR = ledR + (1 - ledR) * (hot * 0.75)
    local coreG = ledG + (1 - ledG) * (hot * 0.75)
    local coreB = ledB + (1 - ledB) * (hot * 0.75)
    gfx.set(coreR, coreG, coreB, SETTINGS.darkMode and 0.85 or 0.8)
    gfx.rect(coreX, coreY, coreW, coreH, 1)
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.25 or 0.2)
    gfx.rect(ledX + 1, ledY + 1, ledW - 2, 1, 1)

    local tailScale = math.min(1, math.abs(velocity) * 1.6) * (1 - 0.25 * squash)
    local tail1 = px(16) * tailScale
    local tail2 = px(30) * tailScale
    local tail3 = px(44) * tailScale
    local tail4 = px(60) * tailScale
    local tailDir = velocity >= 0 and -1 or 1

    local tailX = (tailDir == -1) and (ledX - tail1) or ledX
    local tailW = ledW + tail1
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.32 or 0.24)
    gfx.rect(tailX, ledY, tailW, ledH, 1)

    tailX = (tailDir == -1) and (ledX - tail2) or ledX
    tailW = ledW + tail2
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.22 or 0.16)
    gfx.rect(tailX, ledY, tailW, ledH, 1)

    tailX = (tailDir == -1) and (ledX - tail3) or ledX
    tailW = ledW + tail3
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.14 or 0.1)
    gfx.rect(tailX, ledY + 1, tailW, ledH - 1, 1)

    tailX = (tailDir == -1) and (ledX - tail4) or ledX
    tailW = ledW + tail4
    gfx.set(ledR, ledG, ledB, SETTINGS.darkMode and 0.09 or 0.06)
    gfx.rect(tailX, ledY + 2, tailW, 1, 1)
end

-- ── Window resize helper ──────────────────────────────────────────────────────

local progressWindowResizableSet = false

local function makeProgressWindowResizable()
    if progressWindowResizableSet then return true end
    if not reaper.JS_Window_Find then return false end
    if not reaper.JS_Window_GetLong or not reaper.JS_Window_SetLong then
        if _deps.warnMissingJsWindowStyleApi then
            _deps.warnMissingJsWindowStyleApi("progress window resize setup")
        end
        return false
    end

    local ps = _deps.progressState
    local title = ps and ps.windowTitle
    if not title then
        local fn = _deps.getProcessingWindowTitle
        if type(fn) == "function" then title = fn() end
    end
    local hwnd = reaper.JS_Window_Find(title or "", true)
    if not hwnd then return false end

    local style = reaper.JS_Window_GetLong(hwnd, "STYLE")
    if style then
        local WS_THICKFRAME  = 0x00040000
        local WS_MAXIMIZEBOX = 0x00010000
        reaper.JS_Window_SetLong(hwnd, "STYLE", style | WS_THICKFRAME | WS_MAXIMIZEBOX)
    end

    progressWindowResizableSet = true
    return true
end

-- ── Waveform animation state ──────────────────────────────────────────────────

local waveformState = {
    bars = {},
    particles = {},
    lastUpdate = 0,
    pulsePhase = 0,
}

local function initWaveformBars(count)
    waveformState.bars = {}
    for i = 1, count do
        waveformState.bars[i] = {
            height       = math.random() * 0.5 + 0.2,
            targetHeight = math.random() * 0.8 + 0.2,
            velocity     = 0,
            phase        = math.random() * math.pi * 2,
        }
    end
end

-- ── Exports ───────────────────────────────────────────────────────────────────

M.PROGRESS_BASE_W             = PROGRESS_BASE_W
M.PROGRESS_BASE_H             = PROGRESS_BASE_H
M.progressUiLabel             = progressUiLabel
M.normalizeProgressStage      = normalizeProgressStage
M.localizeProgressStagePrefix = localizeProgressStagePrefix
M.readableTerminalAccent      = readableTerminalAccent
M.formatProgressLine          = formatProgressLine
M.drawTerminalFx              = drawTerminalFx
M.makeProgressWindowResizable = makeProgressWindowResizable
M.waveformState               = waveformState
M.initWaveformBars            = initWaveformBars

return M
