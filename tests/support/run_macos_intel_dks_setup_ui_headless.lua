-- Headless behavioral tests for the Intel-macOS Drum Kit / DKS Setup UI
-- consistency fix in STEMwerk_Setup_Internal.lua.
--
-- Product policy (already correctly enforced by the main STEMwerk.lua
-- processing GUI's intelMacDksPolicyBlocked()): Drum Kit Split is
-- unsupported on Intel macOS, supported on Apple Silicon macOS, and
-- unaffected on any Linux architecture (including Intel hardware running
-- Linux). Setup runs as its own separate REAPER script/process and cannot
-- call that main-GUI function directly, so STEMwerk_Setup_Internal.lua gets
-- its own single definition, isIntelMacDksUnsupported(), reused by every
-- Setup UI surface below instead of each re-deriving the same OS/MAC_ARCH
-- fact independently.
--
-- This dofile()s the real production script exactly like the other
-- tests/support/run_*_headless.lua harnesses -- not a reimplementation.
-- Because `OS` and MAC_ARCH are computed once per load, each scenario
-- re-dofiles the target after changing the reported platform.  The primary
-- Intel regression scenario deliberately does NOT inject MAC_ARCH: it stubs
-- `uname -m` instead, so it exercises the same architecture-discovery route
-- as a fresh real Setup process.

local SEP = package.config:sub(1, 1)
local IS_WINDOWS = SEP == "\\"

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local source = (info and info.source) or ""
    local path = source:match("^@(.*)$") or source
    return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local REPO_ROOT = scriptDir() .. "/../.."
local TARGET = REPO_ROOT .. "/scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"

local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. TMP_ROOT .. "\"")

local function mkFixtureRuntime(name)
    local base = TMP_ROOT .. SEP .. name
    local stateDir = base .. SEP .. "state"
    local logsDir = base .. SEP .. "logs"
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. stateDir .. "\"")
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. logsDir .. "\"")
    return { base = base, runtimeState = stateDir, runtimeLogs = logsDir, venvDir = base .. SEP .. ".venv" }
end

local messageBoxCalls = {}

local function loadTargetWithPlatform(reportedOS, macArch)
    STEMWERK_SETUP_HEADLESS_TEST = true
    MAC_ARCH = macArch
    messageBoxCalls = {}
    reaper = {
        ShowMessageBox = function(text, title, _t)
            messageBoxCalls[#messageBoxCalls + 1] = { text = text, title = title }
            return 0
        end,
        GetOS = function() return reportedOS end,
        GetExtState = function() return "" end,
        SetExtState = function() end,
        HasExtState = function() return false end,
        DeleteExtState = function() end,
        ShowConsoleMsg = function() end,
        defer = function() end,
        GetResourcePath = function() return "/tmp" end,
        get_action_context = function() return "", "" end,
    }
    local ok, err = pcall(dofile, TARGET)
    assertf(ok, "failed to load " .. TARGET .. " for GetOS()=" .. tostring(reportedOS)
        .. " MAC_ARCH=" .. tostring(macArch) .. ": " .. tostring(err))
    assertf(type(isIntelMacDksUnsupported) == "function", "isIntelMacDksUnsupported was not exposed as a global function")
    assertf(type(buildSetupMenuChoices) == "function", "buildSetupMenuChoices was not exposed as a global function")
    assertf(type(refreshSetupMenuChoiceLabels) == "function", "refreshSetupMenuChoiceLabels was not exposed as a global function")
    assertf(type(linuxStepLegendModel) == "function", "linuxStepLegendModel was not exposed as a global function")
    assertf(type(startLinuxSetup) == "function", "startLinuxSetup was not exposed as a global function")
    assertf(type(startExistingRuntimeSetupMenu) == "function", "startExistingRuntimeSetupMenu was not exposed as a global function")
end

local function loadTargetWithDetectedMacArch(reportedOS, detectedArch)
    local originalPopen = io.popen
    io.popen = function(command, mode)
        if command == "uname -m 2>/dev/null" then
            return {
                read = function(_self, _format) return detectedArch end,
                close = function() return true end,
            }
        end
        return originalPopen(command, mode)
    end
    local ok, err = pcall(loadTargetWithPlatform, reportedOS, nil)
    io.popen = originalPopen
    assertf(ok, "failed to load production architecture route for " .. tostring(detectedArch) .. ": " .. tostring(err))
end

local renderedText = {}
local renderedDraws = {}
local renderedRects = {}
local renderedEvents = {}
local renderedUtf8Valid = true

local function validUtf8(text)
    local value = tostring(text or "")
    if utf8 and utf8.len then
        return utf8.len(value) ~= nil
    end
    local i = 1
    while i <= #value do
        local first = value:byte(i) or 0
        local count = 1
        if first < 0x80 then
            count = 1
        elseif first >= 0xC2 and first <= 0xDF then
            count = 2
        elseif first >= 0xE0 and first <= 0xEF then
            count = 3
        elseif first >= 0xF0 and first <= 0xF4 then
            count = 4
        else
            return false
        end
        if i + count - 1 > #value then return false end
        for offset = 1, count - 1 do
            local continuation = value:byte(i + offset) or 0
            if continuation < 0x80 or continuation > 0xBF then return false end
        end
        i = i + count
    end
    return true
end

local function installGfxCapture()
    renderedText = {}
    renderedDraws = {}
    renderedRects = {}
    renderedEvents = {}
    renderedUtf8Valid = true
    local currentColor = { 0, 0, 0, 1 }
    local currentFontSize = 14
    gfx = {
        w = 1120,
        h = 760,
        x = 0,
        y = 0,
        texth = 14,
        mouse_x = -100,
        mouse_y = -100,
        mouse_cap = 0,
        mouse_wheel = 0,
        init = function(_title, w, h)
            gfx.w = w
            gfx.h = h
        end,
        set = function(r, g, b, a)
            currentColor = { r or 0, g or 0, b or 0, a or 1 }
        end,
        rect = function(x, y, w, h, fill)
            local rect = {
                x = x, y = y, w = w, h = h, fill = fill,
                color = { currentColor[1], currentColor[2], currentColor[3], currentColor[4] },
            }
            renderedRects[#renderedRects + 1] = rect
            renderedEvents[#renderedEvents + 1] = { kind = "rect", value = rect }
        end,
        setfont = function(_slot, _name, size)
            gfx.texth = tonumber(size) or 14
            currentFontSize = gfx.texth
        end,
        measurestr = function(text)
            return #tostring(text or "") * math.max(4, currentFontSize * 0.54)
        end,
        drawstr = function(text)
            local value = tostring(text or "")
            renderedUtf8Valid = renderedUtf8Valid and validUtf8(value)
            renderedText[#renderedText + 1] = value
            local draw = {
                text = value, x = gfx.x, y = gfx.y,
                w = gfx.measurestr(value), h = gfx.texth,
                fontSize = currentFontSize,
            }
            renderedDraws[#renderedDraws + 1] = draw
            renderedEvents[#renderedEvents + 1] = { kind = "text", value = draw }
        end,
        getchar = function()
            local ch = gfx._nextChar or 0
            gfx._nextChar = 0
            return ch
        end,
        update = function() end,
        quit = function() end,
    }
end

local function writeTextFile(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function renderedContains(needle)
    for _, text in ipairs(renderedText) do
        if text:find(needle, 1, true) then return true end
    end
    return false
end

local function idsOf(choices)
    local ids = {}
    for _, c in ipairs(choices) do
        ids[#ids + 1] = c.id
    end
    return ids
end

local function actionCardRects(choices)
    local cards = {}
    local usedStrips = {}
    for _, choice in ipairs(choices) do
        for stripIndex, strip in ipairs(renderedRects) do
            local color = strip.color or {}
            if not usedStrips[stripIndex] and strip.fill == 1 and strip.w > 100 and strip.h >= 5
                and math.abs((color[1] or 0) - choice.accent[1]) < 0.001
                and math.abs((color[2] or 0) - choice.accent[2]) < 0.001
                and math.abs((color[3] or 0) - choice.accent[3]) < 0.001 then
                for _, border in ipairs(renderedRects) do
                    if border.fill == 0 and border.x == strip.x and border.y == strip.y
                        and border.w == strip.w and border.h > strip.h then
                        cards[#cards + 1] = border
                        usedStrips[stripIndex] = true
                        break
                    end
                end
                break
            end
        end
    end
    return cards
end

local function drawForExactText(text)
    for i = #renderedDraws, 1, -1 do
        if renderedDraws[i].text == text then return renderedDraws[i] end
    end
    return nil
end

local function modesPanelRect()
    local modesDraw = drawForExactText(setupText("setup_modes_title", "Modes"))
    if not modesDraw then return nil end
    local best = nil
    for _, rect in ipairs(renderedRects) do
        if rect.fill == 0 and modesDraw.x >= rect.x and modesDraw.x <= rect.x + rect.w
            and modesDraw.y >= rect.y and modesDraw.y <= rect.y + rect.h then
            if not best or (rect.w * rect.h) < (best.w * best.h) then best = rect end
        end
    end
    return best
end

local function isEllipsizedRenderingOf(actualText, expectedText)
    local actual = tostring(actualText or ""):gsub("%s+", "")
    local expected = tostring(expectedText or ""):gsub("%s+", "")
    if actual == expected then return true end
    if not actual:find("...", 1, true) then return false end

    local actualPos, expectedPos, firstPiece = 1, 1, true
    while true do
        local dotsAt = actual:find("...", actualPos, true)
        local piece = dotsAt and actual:sub(actualPos, dotsAt - 1) or actual:sub(actualPos)
        if piece ~= "" then
            local foundAt = expected:find(piece, expectedPos, true)
            if not foundAt or (firstPiece and foundAt ~= 1) then return false end
            expectedPos = foundAt + #piece
            firstPiece = false
        end
        if not dotsAt then
            return actual:sub(-3) == "..." or expectedPos == #expected + 1
        end
        actualPos = dotsAt + 3
        if actualPos > #actual then return true end
    end
end

local function expectedRenderedSummaryLabel(choice)
    if choice.id == "drumsep-runtime" then
        if choice.linuxGpuCapability == "cuda" then
            return setupText("setup_summary_drumkit_cuda", "DrumKit CUDA")
        elseif choice.linuxGpuCapability == "cpu" then
            return setupText("setup_summary_drumkit_cpu", "DrumKit CPU")
        elseif choice.linuxGpuCapability == "unknown" then
            return setupText("setup_summary_drumkit_generic", "DrumKit")
        end
    end
    return setupSummaryLabel(choice.id, choice.label)
end

local function completeModesLegend(choices)
    local panel = modesPanelRect()
    if not panel then return false, "Modes panel missing" end
    local swatches = {}
    for _, rect in ipairs(renderedRects) do
        if rect.fill == 1 and rect.w == 5 and rect.x >= panel.x and rect.x + rect.w <= panel.x + panel.w
            and rect.y >= panel.y and rect.y + rect.h <= panel.y + panel.h then
            swatches[#swatches + 1] = rect
        end
    end
    if #swatches ~= #choices then
        return false, "swatches=" .. tostring(#swatches) .. " choices=" .. tostring(#choices)
    end
    for i, choice in ipairs(choices) do
        local color = swatches[i].color or {}
        if math.abs((color[1] or 0) - choice.accent[1]) >= 0.001
            or math.abs((color[2] or 0) - choice.accent[2]) >= 0.001
            or math.abs((color[3] or 0) - choice.accent[3]) >= 0.001 then
            return false, "swatch order/color mismatch at " .. tostring(i)
        end
    end
    local renderedLabels = {}
    local currentLabel = nil
    for _, event in ipairs(renderedEvents) do
        local value = event.value
        if event.kind == "rect" and value.fill == 1 and value.w == 5
            and value.x >= panel.x and value.x + value.w <= panel.x + panel.w
            and value.y >= panel.y and value.y + value.h <= panel.y + panel.h then
            currentLabel = #renderedLabels + 1
            renderedLabels[currentLabel] = ""
        elseif event.kind == "text" and currentLabel
            and value.x >= panel.x and value.x < panel.x + panel.w
            and value.y >= panel.y and value.y < panel.y + panel.h then
            renderedLabels[currentLabel] = renderedLabels[currentLabel] .. value.text
        end
    end
    if #renderedLabels ~= #choices then
        return false, "labels=" .. tostring(#renderedLabels) .. " choices=" .. tostring(#choices)
    end
    for i, choice in ipairs(choices) do
        local expected = expectedRenderedSummaryLabel(choice)
        local actual = renderedLabels[i]
        if actual:gsub("[%s%.]", "") == "" or not isEllipsizedRenderingOf(actual, expected) then
            return false, "legend label mismatch at " .. tostring(i)
                .. ": expected=" .. expected .. " rendered=" .. actual
        end
    end
    for _, draw in ipairs(renderedDraws) do
        if draw.x >= panel.x and draw.y >= panel.y
            and draw.x < panel.x + panel.w and draw.y < panel.y + panel.h then
            if draw.x + draw.w > panel.x + panel.w + 0.001
                or draw.y + draw.h > panel.y + panel.h + 0.001 then
                return false, "legend text out of bounds: " .. tostring(draw.text)
            end
        end
    end
    return true, "swatches=" .. tostring(#swatches)
end

local function cardTextStaysInside(cards)
    local textCount = 0
    for _, draw in ipairs(renderedDraws) do
        local inCardRow = false
        local contained = false
        for _, card in ipairs(cards) do
            if draw.y >= card.y and draw.y < card.y + card.h then
                inCardRow = true
                if draw.x >= card.x and draw.x + draw.w <= card.x + card.w + 0.001
                    and draw.y + draw.h <= card.y + card.h + 0.001 then
                    contained = true
                    break
                end
            end
        end
        if inCardRow then
            textCount = textCount + 1
            if not contained then return false end
        end
    end
    return textCount >= #cards
end

-- loadTargetWithPlatform's dofile() always triggers one unrelated, pre-existing
-- "non-canonical install location" notice as a top-level load side effect
-- (this test harness runs the script from a worktree path, never the
-- canonical REAPER Scripts location) -- unconditional on every platform, not
-- specific to the Intel-macOS guard under test. Every message-box assertion
-- below therefore compares growth against a baseline captured right after
-- load, not an absolute count.
local function containsId(ids, needle)
    for _, id in ipairs(ids) do
        if id == needle then return true end
    end
    return false
end

local function buildMenuChoices(runtime, state)
    local choices = buildSetupMenuChoices(runtime, state or {})
    refreshSetupMenuChoiceLabels({ choices = choices })
    return choices
end

local results = {}
local function record(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail }
end

-- --- 0: Fresh production load + healthy existing runtime screen -----------

loadTargetWithDetectedMacArch("OSX64", "x86_64")
local freshIntelRuntime = mkFixtureRuntime("fresh-intel-healthy-existing")
writeTextFile(
    freshIntelRuntime.runtimeState .. SEP .. "bootstrap.env",
    "STATUS=ok\nSTEMWERK_SETUP_VERSION=2.3.1.3\nPROFILE=mac-cpu\nBACKEND=cpu\n"
)
installGfxCapture()
local freshIntelChoices = startExistingRuntimeSetupMenu(freshIntelRuntime, "/fixture/audio_separator_process.py")
local freshIntelIds = idsOf(freshIntelChoices)
existingRuntimeSetupMenuTick()
local expectedFreshIntelIds = table.concat({
    "verify", "support-bundle", "open-logs", "open-runtime", "repair",
    "rebuild-venv", "delete-models", "delete-runtime", "cancel",
}, ",")
record(
    "fresh-intel-production-load-detects-x86_64-without-global-injection",
    MAC_ARCH == "x86_64",
    "MAC_ARCH=" .. tostring(MAC_ARCH)
)
record(
    "fresh-intel-healthy-existing-runtime-has-exact-action-grid",
    table.concat(freshIntelIds, ",") == expectedFreshIntelIds,
    "choices=" .. table.concat(freshIntelIds, ",")
)
record(
    "fresh-intel-healthy-existing-runtime-renders-real-screen",
    renderedContains("Existing runtime found. Choose what to do:") and renderedContains("Modes"),
    table.concat(renderedText, " | ")
)
record(
    "fresh-intel-healthy-existing-runtime-renders-no-dks-action-or-mode",
    not renderedContains("Drum Kit Split runtime") and not renderedContains("DrumKit CPU"),
    table.concat(renderedText, " | ")
)
record(
    "fresh-intel-healthy-existing-runtime-keeps-normal-actions",
    renderedContains("Check only") and renderedContains("Save Support Bundle")
        and renderedContains("Open logs folder") and renderedContains("Open runtime folder")
        and renderedContains("Repair") and renderedContains("Rebuild venv")
        and renderedContains("Delete models") and renderedContains("Delete runtime")
        and renderedContains("Cancel"),
    table.concat(renderedText, " | ")
)

-- --- 0b: Shared renderer polish -- EN/NL/DE, size and zoom contracts ------

local EXPECTED_MODES_TITLE = { en = "Modes", nl = "Modi", de = "Modi" }
local EXPECTED_EXISTING_SUBTITLE = {
    en = "Existing runtime found. Choose what to do:",
    nl = "Bestaande runtime gevonden. Kies wat je wilt doen:",
    de = "Vorhandene Runtime gefunden. Aktion auswählen:",
}

local function renderMenu(runtime, langCode, width, height, zoomSteps)
    setLanguage(langCode)
    installGfxCapture()
    local choices = startExistingRuntimeSetupMenu(runtime, "/fixture/audio_separator_process.py")
    gfx.w = width
    gfx.h = height
    for _ = 1, math.abs(zoomSteps or 0) do
        gfx._nextChar = (zoomSteps > 0) and 43 or 45
        existingRuntimeSetupMenuTick()
    end
    renderedText = {}
    renderedDraws = {}
    renderedRects = {}
    renderedEvents = {}
    existingRuntimeSetupMenuTick()
    return choices
end

local function cardsAreUniformAndSeparated(cards, expectedCount, width, height)
    if #cards ~= expectedCount then return false end
    for i, card in ipairs(cards) do
        if card.w ~= cards[1].w or card.h ~= cards[1].h then return false end
        if card.x < 0 or card.y < 0 or card.x + card.w > width or card.y + card.h > height then return false end
        for j = i + 1, #cards do
            local other = cards[j]
            local overlaps = card.x < other.x + other.w and other.x < card.x + card.w
                and card.y < other.y + other.h and other.y < card.y + card.h
            if overlaps then return false end
        end
    end
    return true
end

local function cardsEndBeforeFooter(cards, zoomText)
    local footerY = nil
    for _, draw in ipairs(renderedDraws) do
        if draw.text:find(zoomText, 1, true) then
            footerY = draw.y
            break
        end
    end
    if not footerY then return false end
    for _, card in ipairs(cards) do
        if card.y + card.h >= footerY then return false end
    end
    return true
end

for _, langCode in ipairs({ "en", "nl", "de" }) do
    local localizedChoices = renderMenu(freshIntelRuntime, langCode, 1260, 904, 0)
    local allCardTextVisible = true
    local rowTitleY = {}
    local rowSubtitleY = {}
    for i, choice in ipairs(localizedChoices) do
        local titleDraw = drawForExactText(choice.label)
        local subtitleDraw = drawForExactText(choice.sub)
        if not titleDraw or not subtitleDraw then
            allCardTextVisible = false
            break
        end
        local row = math.floor((i - 1) / 3) + 1
        rowTitleY[row] = rowTitleY[row] or titleDraw.y
        rowSubtitleY[row] = rowSubtitleY[row] or subtitleDraw.y
        if titleDraw.y ~= rowTitleY[row] or subtitleDraw.y ~= rowSubtitleY[row] then
            allCardTextVisible = false
            break
        end
    end
    record(
        "intel-default-layout-renders-complete-aligned-card-text-" .. langCode,
        allCardTextVisible,
        table.concat(renderedText, " | ")
    )
    record(
        "intel-default-layout-renders-localized-header-and-modes-" .. langCode,
        renderedContains(EXPECTED_EXISTING_SUBTITLE[langCode])
            and renderedContains(EXPECTED_MODES_TITLE[langCode])
            and not renderedContains("DrumKit CPU"),
        table.concat(renderedText, " | ")
    )
    local cards = actionCardRects(localizedChoices)
    local modesComplete, modesDetail = completeModesLegend(localizedChoices)
    record(
        "intel-default-layout-has-nine-uniform-nonoverlapping-cards-" .. langCode,
        cardsAreUniformAndSeparated(cards, 9, 1260, 904)
            and cardsEndBeforeFooter(cards, "100%") and cardTextStaysInside(cards)
            and modesComplete and renderedUtf8Valid,
        "cards=" .. tostring(#cards) .. " " .. tostring(modesDetail)
    )
end

for _, viewport in ipairs({
    { name = "minimum", w = 1120, h = 760 },
    { name = "larger", w = 1500, h = 1050 },
}) do
    local viewportChoices = renderMenu(freshIntelRuntime, "en", viewport.w, viewport.h, 0)
    local cards = actionCardRects(viewportChoices)
    local modesComplete = completeModesLegend(viewportChoices)
    record(
        "intel-" .. viewport.name .. "-viewport-keeps-uniform-nonoverlapping-action-grid",
        cardsAreUniformAndSeparated(cards, 9, viewport.w, viewport.h)
            and cardsEndBeforeFooter(cards, "100%") and cardTextStaysInside(cards)
            and modesComplete and renderedUtf8Valid,
        "cards=" .. tostring(#cards)
    )
end

local zoomedChoices = renderMenu(freshIntelRuntime, "de", 1120, 760, 6)
local zoomedCards = actionCardRects(zoomedChoices)
local zoomedModesComplete = completeModesLegend(zoomedChoices)
record(
    "intel-minimum-viewport-at-160pct-keeps-action-grid-in-bounds",
    cardsAreUniformAndSeparated(zoomedCards, 9, 1120, 760)
        and cardsEndBeforeFooter(zoomedCards, "160%") and cardTextStaysInside(zoomedCards)
        and zoomedModesComplete and renderedUtf8Valid and renderedContains("160%"),
    "cards=" .. tostring(#zoomedCards) .. " text=" .. table.concat(renderedText, " | ")
)

local reducedZoomChoices = renderMenu(freshIntelRuntime, "de", 1120, 760, -2)
local reducedZoomCards = actionCardRects(reducedZoomChoices)
local reducedZoomModesComplete = completeModesLegend(reducedZoomChoices)
record(
    "intel-minimum-viewport-at-80pct-keeps-action-grid-in-bounds",
    cardsAreUniformAndSeparated(reducedZoomCards, 9, 1120, 760)
        and cardsEndBeforeFooter(reducedZoomCards, "80%") and cardTextStaysInside(reducedZoomCards)
        and reducedZoomModesComplete and renderedUtf8Valid and renderedContains("80%"),
    "cards=" .. tostring(#reducedZoomCards) .. " text=" .. table.concat(renderedText, " | ")
)

local compactZoomChoices = renderMenu(freshIntelRuntime, "de", 1120, 760, 16)
local compactZoomCards = actionCardRects(compactZoomChoices)
local compactZoomModesComplete = completeModesLegend(compactZoomChoices)
record(
    "intel-minimum-viewport-at-260pct-uses-compact-grid-in-bounds",
    cardsAreUniformAndSeparated(compactZoomCards, 9, 1120, 760)
        and cardsEndBeforeFooter(compactZoomCards, "260%") and cardTextStaysInside(compactZoomCards)
        and compactZoomModesComplete and renderedUtf8Valid and renderedContains("260%"),
    "cards=" .. tostring(#compactZoomCards) .. " text=" .. table.concat(renderedText, " | ")
)

for _, langCode in ipairs({ "en", "nl", "de" }) do
    for _, zoomCase in ipairs({
        { steps = 0, label = "100%" },
        { steps = 16, label = "260%" },
        { steps = 20, label = "300%" },
    }) do
        local matrixChoices = renderMenu(freshIntelRuntime, langCode, 1120, 760, zoomCase.steps)
        local matrixCards = actionCardRects(matrixChoices)
        local matrixModesComplete, matrixModesDetail = completeModesLegend(matrixChoices)
        record(
            "intel-localized-layout-complete-valid-utf8-" .. langCode .. "-" .. zoomCase.label,
            renderedUtf8Valid and matrixModesComplete
                and cardsAreUniformAndSeparated(matrixCards, 9, 1120, 760)
                and cardsEndBeforeFooter(matrixCards, zoomCase.label)
                and cardTextStaysInside(matrixCards),
            tostring(matrixModesDetail) .. " text=" .. table.concat(renderedText, " | ")
        )
    end
end

for _, viewport in ipairs({
    { name = "minimum", w = 1120, h = 760 },
    { name = "default", w = 1260, h = 904 },
    { name = "larger", w = 1500, h = 1050 },
}) do
    for _, zoomCase in ipairs({
        { steps = -2, label = "80%" },
        { steps = 0, label = "100%" },
        { steps = 6, label = "160%" },
        { steps = 16, label = "260%" },
        { steps = 20, label = "300%" },
    }) do
        local matrixChoices = renderMenu(freshIntelRuntime, "en", viewport.w, viewport.h, zoomCase.steps)
        local matrixCards = actionCardRects(matrixChoices)
        local matrixModesComplete, matrixModesDetail = completeModesLegend(matrixChoices)
        record(
            "intel-size-zoom-matrix-" .. viewport.name .. "-" .. zoomCase.label,
            renderedUtf8Valid and matrixModesComplete
                and cardsAreUniformAndSeparated(matrixCards, 9, viewport.w, viewport.h)
                and cardsEndBeforeFooter(matrixCards, zoomCase.label)
                and cardTextStaysInside(matrixCards),
            tostring(matrixModesDetail) .. " text=" .. table.concat(renderedText, " | ")
        )
    end
end

-- --- 1: Intel macOS Setup actions: no actionable "Drum Kit Split runtime" ---

loadTargetWithPlatform("OSX64", "x86_64")
local intelRuntime = mkFixtureRuntime("intel-choices")
local intelChoices = buildMenuChoices(intelRuntime, {})
local intelIds = idsOf(intelChoices)
record(
    "intel-macos-setup-actions-have-no-drumsep-runtime-choice",
    not containsId(intelIds, "drumsep-runtime")
        and not containsId(intelIds, "drumsep-rocm-runtime")
        and not containsId(intelIds, "drumsep-cuda-runtime")
        and not containsId(intelIds, "drumsep-directml-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)
-- repair/rebuild-venv/delete-models/delete-runtime remain: this is narrowly
-- about Drum Kit, not a broader Intel-macOS Setup lockdown.
record(
    "intel-macos-setup-actions-keep-unrelated-mutating-actions",
    containsId(intelIds, "repair") and containsId(intelIds, "rebuild-venv")
        and containsId(intelIds, "delete-models") and containsId(intelIds, "delete-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)

-- --- 2: Intel macOS Modes legend: no actionable "DrumKit CPU" -------------
--
-- compactModeSummaryLabel (the Modes legend renderer) only ever runs over
-- m.choices, so proving "drumsep-runtime" is absent from choices (above)
-- already proves "DrumKit CPU" cannot appear in the legend; this assertion
-- pins that structural guarantee directly rather than re-deriving it.
record(
    "intel-macos-modes-legend-has-no-drumkit-cpu-producing-choice",
    not containsId(intelIds, "drumsep-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)

-- --- 3: Intel macOS progress/final presentation: exactly four rows, no DKS row ---

local labels, colors, forceNeutral = linuxStepLegendModel(true)
record(
    "intel-macos-step-legend-has-exactly-four-rows",
    #labels == 4 and #colors == 4 and #forceNeutral == 4,
    "counts=" .. tostring(#labels) .. "," .. tostring(#colors) .. "," .. tostring(#forceNeutral)
)
record("intel-macos-step-legend-has-no-drum-kit-row", labels[5] == nil, tostring(labels[5]))
local intelHasUnsupportedRow = false
for _, label in ipairs(labels) do
    if tostring(label):find("Unsupported", 1, true) then intelHasUnsupportedRow = true end
end
record("intel-macos-step-legend-has-no-unsupported-row", not intelHasUnsupportedRow, "")
record("intel-macos-steps-1-through-4-are-unaffected", not forceNeutral[1] and not forceNeutral[2] and not forceNeutral[3] and not forceNeutral[4], "")

-- --- 4: Direct Drum Kit setup dispatch on Intel macOS: clean, no mutation ---
--
-- The guard message must reuse the existing drumsep_intel_mac_unsupported_title/
-- _body keys (the same ones the main STEMwerk.lua GUI's showIntelMacDksPolicyBlock
-- already uses for this identical policy) via setupText(), not a separate
-- raw English string -- and EN/NL/DE must all resolve through languages.lua,
-- not a hand-written duplicate. These are the authoritative strings as
-- committed in scripts/reaper/i18n/languages.lua.
local EXPECTED_TITLE = {
    en = "Drum Kit Split unavailable on Intel Mac",
    nl = "Drum Kit Split niet beschikbaar op Intel Mac",
    de = "Drum Kit Split auf Intel Mac nicht verfügbar",
}
local EXPECTED_BODY = {
    en = "Drum Kit Split is not enabled on Intel Mac in this release. Normal CPU stem separation is available. For Drum Kit Split, use Apple Silicon or a supported GPU/accelerated platform.",
    nl = "Drum Kit Split is in deze release niet ingeschakeld op Intel Mac. Normale CPU-stems zijn beschikbaar. Gebruik voor Drum Kit Split Apple Silicon of een ondersteund GPU/versneld platform.",
    de = "Drum Kit Split ist in dieser Version auf Intel Macs nicht aktiviert. Normale CPU-Stems sind verfügbar. Verwende für Drum Kit Split Apple Silicon oder eine unterstützte GPU-/beschleunigte Plattform.",
}
-- The previous (pre-correction) raw custom English body this slice replaces.
local OLD_RAW_CUSTOM_BODY = "Drum Kit Split is not available on Intel Mac in this release."

local function fileExistsPlain(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function testDispatchBlockedInLanguage(langCode)
    setLanguage(langCode)
    local runtime = mkFixtureRuntime("intel-dispatch-" .. langCode)
    local before = #messageBoxCalls
    startLinuxSetup(runtime, "/does/not/matter.py", "drumsep-runtime")
    record(
        "intel-macos-direct-dispatch-writes-no-state-file-" .. langCode,
        not fileExistsPlain(runtime.runtimeState .. SEP .. "bootstrap.env")
            and not fileExistsPlain(runtime.runtimeState .. SEP .. "drumsep_runtime.env"),
        ""
    )
    record(
        "intel-macos-direct-dispatch-shows-exactly-one-message-" .. langCode,
        #messageBoxCalls == before + 1,
        "messageBoxCalls=" .. #messageBoxCalls .. " before=" .. before
    )
    if #messageBoxCalls == before + 1 then
        local call = messageBoxCalls[#messageBoxCalls]
        record(
            "intel-macos-dispatch-title-is-in-the-title-slot-" .. langCode,
            call.title == EXPECTED_TITLE[langCode],
            "title=" .. tostring(call.title)
        )
        record(
            "intel-macos-dispatch-body-is-in-the-text-slot-" .. langCode,
            call.text == EXPECTED_BODY[langCode],
            "text=" .. tostring(call.text)
        )
        record(
            "intel-macos-dispatch-body-is-not-the-old-raw-custom-english-text-" .. langCode,
            not tostring(call.text):find(OLD_RAW_CUSTOM_BODY, 1, true),
            tostring(call.text)
        )
    end
end

loadTargetWithPlatform("OSX64", "x86_64")
testDispatchBlockedInLanguage("en")
testDispatchBlockedInLanguage("nl")
testDispatchBlockedInLanguage("de")

-- drumsep-rocm-runtime dispatch is also blocked (English, the default).
-- SETTINGS is a plain global that survives across dofile() reloads within
-- this one process (production uses `SETTINGS = SETTINGS or {...}`), so the
-- "de" selected by the last language scenario above would otherwise leak in.
loadTargetWithPlatform("OSX64", "x86_64")
setLanguage("en")
local dispatchRuntime2 = mkFixtureRuntime("intel-dispatch-rocm")
local beforeRocmDispatch = #messageBoxCalls
startLinuxSetup(dispatchRuntime2, "/does/not/matter.py", "drumsep-rocm-runtime")
record(
    "intel-macos-direct-dispatch-also-blocks-drumsep-rocm-runtime",
    not fileExistsPlain(dispatchRuntime2.runtimeState .. SEP .. "bootstrap.env")
        and not fileExistsPlain(dispatchRuntime2.runtimeState .. SEP .. "drumsep_runtime_rocm.env")
        and #messageBoxCalls == beforeRocmDispatch + 1,
    ""
)
if #messageBoxCalls == beforeRocmDispatch + 1 then
    record(
        "intel-macos-rocm-dispatch-also-uses-the-localized-keys",
        messageBoxCalls[#messageBoxCalls].title == EXPECTED_TITLE.en
            and messageBoxCalls[#messageBoxCalls].text == EXPECTED_BODY.en,
        ""
    )
end

-- --- 5: Apple Silicon macOS: Drum Kit actions remain available -----------

loadTargetWithDetectedMacArch("OSX64", "arm64")
record("apple-silicon-production-load-detects-arm64", MAC_ARCH == "arm64", "MAC_ARCH=" .. tostring(MAC_ARCH))
record("apple-silicon-is-not-flagged-unsupported", isIntelMacDksUnsupported() == false, "")
local armRuntime = mkFixtureRuntime("arm64-choices")
local armChoices = buildMenuChoices(armRuntime, {})
local armIds = idsOf(armChoices)
record("apple-silicon-setup-actions-still-offer-drumsep-runtime", containsId(armIds, "drumsep-runtime"), "arm64 choices=" .. table.concat(armIds, ","))

setLanguage("en")
installGfxCapture()
local renderedArmChoices = startExistingRuntimeSetupMenu(armRuntime, "/fixture/audio_separator_process.py")
existingRuntimeSetupMenuTick()
record(
    "apple-silicon-existing-runtime-ui-keeps-dks-card-and-mode",
    renderedContains("Drum Kit Split runtime") and renderedContains("DrumKit CPU"),
    table.concat(renderedText, " | ")
)
record(
    "apple-silicon-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
    cardsAreUniformAndSeparated(actionCardRects(renderedArmChoices), #renderedArmChoices, 1260, 904)
        and cardsEndBeforeFooter(actionCardRects(renderedArmChoices), "100%"),
    "choices=" .. tostring(#renderedArmChoices)
)
for _, zoomCase in ipairs({ { steps = 16, label = "260%" }, { steps = 20, label = "300%" } }) do
    local highZoomChoices = renderMenu(armRuntime, "en", 1120, 760, zoomCase.steps)
    local highZoomCards = actionCardRects(highZoomChoices)
    local modesComplete, modesDetail = completeModesLegend(highZoomChoices)
    record(
        "apple-silicon-modes-complete-" .. zoomCase.label,
        #highZoomChoices == 10 and modesComplete and renderedUtf8Valid
            and cardsAreUniformAndSeparated(highZoomCards, 10, 1120, 760)
            and cardsEndBeforeFooter(highZoomCards, zoomCase.label)
            and cardTextStaysInside(highZoomCards)
            and renderedContains("DrumKit") and renderedContains("CPU"),
        tostring(modesDetail) .. " text=" .. table.concat(renderedText, " | ")
    )
end

local armLabels, _armColors, armForceNeutral = linuxStepLegendModel(false)
record("apple-silicon-step5-label-is-the-original-unchanged-label", armLabels[5] == "5. Drum Kit runtime", tostring(armLabels[5]))
record("apple-silicon-step5-is-not-forced-neutral", armForceNeutral[5] == false, tostring(armForceNeutral[5]))

-- Unlike the Intel scenario, arm64 is not blocked by the new guard and falls
-- through to the real (unblocked) setup flow, which may show its own
-- unrelated message for this minimal fixture (e.g. about the fake
-- separatorScript path) -- that is not what is under test here. What matters
-- is that the Intel-unsupported message specifically was never shown.
local armDispatchRuntime = mkFixtureRuntime("arm64-dispatch")
local armMessageBoxCallsBefore = #messageBoxCalls
startLinuxSetup(armDispatchRuntime, "/does/not/matter.py", "drumsep-runtime")
local armGuardMessageShown = false
for i = armMessageBoxCallsBefore + 1, #messageBoxCalls do
    if tostring(messageBoxCalls[i].text):find("not available", 1, true) then
        armGuardMessageShown = true
    end
end
record(
    "apple-silicon-direct-dispatch-is-not-blocked-by-the-intel-guard",
    not armGuardMessageShown,
    "the Intel-unsupported message must never fire on Apple Silicon"
)
record(
    "apple-silicon-direct-dispatch-writes-the-drumsep-state-file",
    fileExistsPlain(armDispatchRuntime.runtimeState .. SEP .. "drumsep_runtime.env"),
    ""
)

-- --- 6: Linux x86_64: unaffected -------------------------------------------

loadTargetWithPlatform("Other", "x86_64")
record("linux-x86_64-is-not-flagged-unsupported-by-the-macos-guard", isIntelMacDksUnsupported() == false, "")
local linuxRuntime = mkFixtureRuntime("linux-choices")
local linuxChoices = buildMenuChoices(linuxRuntime, {})
local linuxIds = idsOf(linuxChoices)
record("linux-x86_64-setup-actions-still-offer-drumsep-runtime", containsId(linuxIds, "drumsep-runtime"), "linux choices=" .. table.concat(linuxIds, ","))

setLanguage("en")
installGfxCapture()
local renderedLinuxChoices = startExistingRuntimeSetupMenu(linuxRuntime, "/fixture/audio_separator_process.py")
existingRuntimeSetupMenuTick()
record(
    "linux-existing-runtime-ui-keeps-dks-card-and-mode",
    renderedContains("Drum Kit Split runtime") and renderedContains("DrumKit"),
    table.concat(renderedText, " | ")
)
record(
    "linux-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
    cardsAreUniformAndSeparated(actionCardRects(renderedLinuxChoices), #renderedLinuxChoices, 1260, 904)
        and cardsEndBeforeFooter(actionCardRects(renderedLinuxChoices), "100%"),
    "choices=" .. tostring(#renderedLinuxChoices)
)
for _, zoomCase in ipairs({ { steps = 16, label = "260%" }, { steps = 20, label = "300%" } }) do
    local highZoomChoices = renderMenu(linuxRuntime, "en", 1120, 760, zoomCase.steps)
    local highZoomCards = actionCardRects(highZoomChoices)
    local modesComplete, modesDetail = completeModesLegend(highZoomChoices)
    record(
        "linux-modes-complete-" .. zoomCase.label,
        #highZoomChoices >= 10 and modesComplete and renderedUtf8Valid
            and cardsAreUniformAndSeparated(highZoomCards, #highZoomChoices, 1120, 760)
            and cardsEndBeforeFooter(highZoomCards, zoomCase.label)
            and cardTextStaysInside(highZoomCards)
            and renderedContains("DrumKit"),
        tostring(modesDetail) .. " text=" .. table.concat(renderedText, " | ")
    )
end

local linuxLabels, _linuxColors, linuxForceNeutral = linuxStepLegendModel(false)
record("linux-x86_64-step5-label-is-the-original-unchanged-label", linuxLabels[5] == "5. Drum Kit runtime", tostring(linuxLabels[5]))
record("linux-x86_64-step5-is-not-forced-neutral", linuxForceNeutral[5] == false, tostring(linuxForceNeutral[5]))

-- --- Windows: unaffected (sanity: isIntelMacDksUnsupported must require OS=="macOS") ---

loadTargetWithPlatform("Win64", "x86_64")
record("windows-is-not-flagged-unsupported-by-the-macos-guard-even-with-x86_64-arch", isIntelMacDksUnsupported() == false, "")
local windowsRuntime = mkFixtureRuntime("windows-choices")
setLanguage("en")
installGfxCapture()
local renderedWindowsChoices = startExistingRuntimeSetupMenu(windowsRuntime, "/fixture/audio_separator_process.py")
existingRuntimeSetupMenuTick()
local renderedWindowsIds = idsOf(renderedWindowsChoices)
record(
    "windows-existing-runtime-ui-keeps-read-only-policy",
    table.concat(renderedWindowsIds, ",") == "verify,support-bundle,open-logs,open-runtime,cancel",
    "choices=" .. table.concat(renderedWindowsIds, ",")
)
record(
    "windows-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
    cardsAreUniformAndSeparated(actionCardRects(renderedWindowsChoices), #renderedWindowsChoices, 1260, 904)
        and cardsEndBeforeFooter(actionCardRects(renderedWindowsChoices), "100%"),
    "choices=" .. tostring(#renderedWindowsChoices)
)
for _, zoomCase in ipairs({ { steps = 16, label = "260%" }, { steps = 20, label = "300%" } }) do
    local highZoomChoices = renderMenu(windowsRuntime, "en", 1120, 760, zoomCase.steps)
    local highZoomCards = actionCardRects(highZoomChoices)
    local modesComplete, modesDetail = completeModesLegend(highZoomChoices)
    record(
        "windows-modes-complete-" .. zoomCase.label,
        table.concat(idsOf(highZoomChoices), ",") == "verify,support-bundle,open-logs,open-runtime,cancel"
            and modesComplete and renderedUtf8Valid
            and cardsAreUniformAndSeparated(highZoomCards, 5, 1120, 760)
            and cardsEndBeforeFooter(highZoomCards, zoomCase.label)
            and cardTextStaysInside(highZoomCards),
        tostring(modesDetail) .. " text=" .. table.concat(renderedText, " | ")
    )
end

-- --- Report ------------------------------------------------------------------

local failed = 0
for _, r in ipairs(results) do
    if r.ok then
        print("PASS " .. r.name)
    else
        failed = failed + 1
        print("FAIL " .. r.name .. (r.detail ~= "" and (": " .. tostring(r.detail)) or ""))
    end
end

os.execute((IS_WINDOWS and "rmdir /s /q " or "rm -rf ") .. "\"" .. TMP_ROOT .. "\"" .. (IS_WINDOWS and "" or " 2>/dev/null"))

if failed > 0 then
    error(tostring(failed) .. " of " .. #results .. " headless Intel-macOS DKS Setup UI tests failed", 0)
end
print("All " .. #results .. " headless Intel-macOS DKS Setup UI tests passed.")
