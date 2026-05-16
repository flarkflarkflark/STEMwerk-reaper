-- STEMwerk_UI_Controls.lua
-- Shared top-right controls strip (theme/language/fx + tooltip behavior).

local M = {}

local function getActiveThemeColors()
    return (ACTIVE_THEME and ACTIVE_THEME.colors) or {}
end

local function getColorOrFallback(key, fallback)
    local colors = getActiveThemeColors()
    local color = colors[key]
    if type(color) == "table" then
        return color
    end
    return fallback
end

local function getFunctionalIconPalette()
    return {
        sun = {0.92, 0.72, 0.22},
        sunRays = {0.96, 0.79, 0.30},
        moon = {0.74, 0.76, 0.80},
        moonCutout = {0.00, 0.00, 0.00},
        fxOn = {0.34, 0.82, 0.50},
        fxOff = {0.50, 0.50, 0.54},
        fxOffSlash = {0.80, 0.32, 0.32},
        fxSpark = {0.98, 0.98, 0.96},
    }
end

local function isUtilityMode()
    return type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
end

local function drawUtilityThemeToggle(themeX, themeY, themeSize, hover, alpha)
    local label = SETTINGS and SETTINGS.darkMode and "D" or "L"
    gfx.setfont(1, "Arial", math.max(8, math.floor(themeSize * 0.62)), string.byte("b"))
    local tw = gfx.measurestr(label)
    local bg = getColorOrFallback("buttonBg", {0.25, 0.25, 0.25})
    local border = getColorOrFallback("border", {0.45, 0.45, 0.45})
    local text = getColorOrFallback("textPrimary", {0.90, 0.90, 0.90})
    gfx.set(border[1], border[2], border[3], alpha or 1)
    gfx.rect(themeX, themeY, themeSize, themeSize, 0)
    if hover then
        gfx.set(bg[1] + 0.08, bg[2] + 0.08, bg[3] + 0.08, 0.95 * (alpha or 1))
    else
        gfx.set(bg[1], bg[2], bg[3], 0.75 * (alpha or 1))
    end
    gfx.rect(themeX + 1, themeY + 1, math.max(1, themeSize - 2), math.max(1, themeSize - 2), 1)
    gfx.set(text[1], text[2], text[3], alpha or 1)
    gfx.x = themeX + (themeSize - tw) / 2
    gfx.y = themeY + math.floor((themeSize - gfx.texth) / 2)
    gfx.drawstr(label)
end

local function cycleLanguageSetting(setLanguageFn)
    local langs = {"en", "nl", "de"}
    local currentIdx = 1
    for i, l in ipairs(langs) do
        if l == SETTINGS.language then
            currentIdx = i
            break
        end
    end
    local nextIdx = (currentIdx % #langs) + 1
    local applyLanguage = setLanguageFn
    if type(applyLanguage) ~= "function" then
        applyLanguage = _G.setLanguage
    end
    if type(applyLanguage) ~= "function" then
        return
    end
    applyLanguage(langs[nextIdx])
    saveSettings()
end

local function toggleUIMode()
    if _G.FORCE_THEME_PRESET then return end
    SETTINGS.themePreset = isUtilityMode() and "classic" or "reaper_native"
    updateTheme()
    saveSettings()
end

local function drawUtilityControlsCore(ctx)
    local S = ctx.S
    local w = ctx.w
    local mx, my = ctx.mx, ctx.my
    local mouseDown = ctx.mouseDown
    local rightMouseDown = ctx.rightMouseDown or (gfx.mouse_cap & 2 == 2)
    local state = ctx.state or {}
    local tooltipsOn = not (SETTINGS and SETTINGS.tooltips == false)

    local iconScale = ctx.iconScale or 0.66
    local themeSize = ctx.themeSize or math.max(S(12), math.floor(S(20) * iconScale + 0.5))
    local themeY = ctx.themeY or S(8)
    -- Layout right-to-left: [EN] [D] [UI]
    local uiBoxX  = w - themeSize - S(4)           -- [UI] rightmost
    local themeX  = uiBoxX - themeSize - S(4)       -- [D]
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    -- D/L box (middle)
    if themeHover then GUI.uiClickedThisFrame = true end
    drawUtilityThemeToggle(themeX, themeY, themeSize, themeHover, 1.0)
    if themeHover and mouseDown and not state.wasMouseDown then
        SETTINGS.darkMode = not SETTINGS.darkMode
        updateTheme()
        saveSettings()
    end
    if themeHover and tooltipsOn then
        ctx.tooltipText = T("tooltip_theme") or (T("tooltip_theme") or "Toggle dark / light.")
        ctx.tooltipX = mx + S(10)
        ctx.tooltipY = my + S(15)
        GUI.tooltip  = ctx.tooltipText
        GUI.tooltipX = ctx.tooltipX
        GUI.tooltipY = ctx.tooltipY
    end

    -- Language box (left of D/L box, identical visual style)
    local langBoxW = themeSize
    local langBoxX = themeX - langBoxW - S(4)
    local langBoxY = themeY
    local langHover = mx >= langBoxX and mx <= langBoxX + langBoxW
                   and my >= langBoxY and my <= langBoxY + themeSize

    local bg     = getColorOrFallback("buttonBg",   {0.25, 0.25, 0.25})
    local border = getColorOrFallback("border",     {0.45, 0.45, 0.45})
    local text   = getColorOrFallback("textPrimary",{0.90, 0.90, 0.90})

    gfx.setfont(1, "Arial", math.max(8, math.floor(themeSize * 0.62)), string.byte("b"))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    gfx.set(border[1], border[2], border[3], 1)
    gfx.rect(langBoxX, langBoxY, langBoxW, themeSize, 0)
    if langHover then
        GUI.uiClickedThisFrame = true
        gfx.set(bg[1] + 0.08, bg[2] + 0.08, bg[3] + 0.08, 0.95)
    else
        gfx.set(bg[1], bg[2], bg[3], 0.75)
    end
    gfx.rect(langBoxX + 1, langBoxY + 1, math.max(1, langBoxW - 2), math.max(1, themeSize - 2), 1)
    gfx.set(text[1], text[2], text[3], 1)
    gfx.x = langBoxX + (langBoxW - langTextW) / 2
    gfx.y = langBoxY + math.floor((themeSize - gfx.texth) / 2)
    gfx.drawstr(langCode)

    if langHover and mouseDown and not state.wasMouseDown then
        cycleLanguageSetting(ctx.setLanguageFn)
    end
    if langHover and rightMouseDown and not state._ucWasRightDown then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end
    state._ucWasRightDown = langHover and rightMouseDown
    if langHover and tooltipsOn then
        ctx.tooltipText = T("tooltip_lang") or (T("tooltip_lang") or "Change language. Right-click: toggle tooltips.")
        ctx.tooltipX = mx + S(10)
        ctx.tooltipY = my + S(15)
        GUI.tooltip  = ctx.tooltipText
        GUI.tooltipX = ctx.tooltipX
        GUI.tooltipY = ctx.tooltipY
    end

    -- [UI] mode box (rightmost, layout: [EN] [D] [UI])
    local uiHover = mx >= uiBoxX and mx <= uiBoxX + themeSize
                 and my >= themeY and my <= themeY + themeSize
    if uiHover then GUI.uiClickedThisFrame = true end
    gfx.setfont(1, "Arial", math.max(8, math.floor(themeSize * 0.62)), string.byte("b"))
    local uiLabel  = "UI"
    local uiLabelW = gfx.measurestr(uiLabel)
    gfx.set(border[1], border[2], border[3], 1)
    gfx.rect(uiBoxX, themeY, themeSize, themeSize, 0)
    if uiHover then
        gfx.set(bg[1] + 0.08, bg[2] + 0.08, bg[3] + 0.08, 0.95)
    else
        gfx.set(bg[1], bg[2], bg[3], 0.75)
    end
    gfx.rect(uiBoxX + 1, themeY + 1, math.max(1, themeSize - 2), math.max(1, themeSize - 2), 1)
    gfx.set(text[1], text[2], text[3], 1)
    gfx.x = uiBoxX + (themeSize - uiLabelW) / 2
    gfx.y = themeY + math.floor((themeSize - gfx.texth) / 2)
    gfx.drawstr(uiLabel)
    if uiHover and mouseDown and not state.wasMouseDown and not _G.FORCE_THEME_PRESET then
        toggleUIMode()
    end
    if uiHover and tooltipsOn then
        ctx.tooltipText = T("tooltip_ui_mode") or (T("tooltip_ui_mode") or "Switch UI mode.")
        ctx.tooltipX = mx + S(10)
        ctx.tooltipY = my + S(15)
        GUI.tooltip  = ctx.tooltipText
        GUI.tooltipX = ctx.tooltipX
        GUI.tooltipY = ctx.tooltipY
    end
end

local function drawHelpControls(ctx)
    local S = ctx.S
    local mx, my = ctx.mx, ctx.my
    local mouseDown = ctx.mouseDown
    local rightMouseDown = ctx.rightMouseDown
    local state = ctx.state
    local utilityMode = isUtilityMode()
    local controlsOpacity = utilityMode and 1.0 or (ctx.controlsOpacity or 1)
    local iconScale = ctx.iconScale or 0.66
    local themeX = ctx.themeX
    local themeY = ctx.themeY
    local themeSize = ctx.themeSize

    local tooltipText = ctx.tooltipText
    local tooltipX = ctx.tooltipX
    local tooltipY = ctx.tooltipY

    if utilityMode then
        drawUtilityControlsCore(ctx)
        return
    end

    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize
    local iconPalette = getFunctionalIconPalette()
    local accent = getColorOrFallback("accent", {0.4, 0.6, 0.9})
    if SETTINGS.darkMode then
        gfx.set(iconPalette.moon[1], iconPalette.moon[2], iconPalette.moon[3], (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 2 - 2, 1, 1)
        gfx.set(iconPalette.moonCutout[1], iconPalette.moonCutout[2], iconPalette.moonCutout[3], 1 * controlsOpacity)
        gfx.circle(themeX + themeSize / 2 + 4, themeY + themeSize / 2 - 3, themeSize / 2 - 3, 1, 1)
    else
        gfx.set(iconPalette.sun[1], iconPalette.sun[2], iconPalette.sun[3], (themeHover and 1 or 0.8) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 3, 1, 1)
        gfx.set(iconPalette.sunRays[1], iconPalette.sunRays[2], iconPalette.sunRays[3], (themeHover and 1 or 0.8) * controlsOpacity)
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local x1 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 3 + 2)
            local y1 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 3 + 2)
            local x2 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 2 - 1)
            local y2 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 2 - 1)
            gfx.line(x1, y1, x2, y2)
        end
    end
    if themeHover and controlsOpacity > 0.3 then
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + S(10), my + S(15)
        if rightMouseDown and not state.wasRightMouseDown then
            cycleThemePreset()
            updateTheme()
        end
        if mouseDown and not state.wasMouseDown then
            SETTINGS.darkMode = not SETTINGS.darkMode
            updateTheme()
            saveSettings()
        end
    end

    local langW = S(22)
    local langH = S(14)
    local langX = themeX - langW - S(6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    gfx.setfont(1, "Arial", S(9), string.byte("b"))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    if langHover then
        gfx.set(accent[1], accent[2], accent[3], 1 * controlsOpacity)
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    if langHover and controlsOpacity > 0.3 then
        tooltipText = T("tooltip_lang")
        tooltipX, tooltipY = mx + S(10), my + S(15)
    end
    if langHover and rightMouseDown and not state.wasRightMouseDown and controlsOpacity > 0.3 then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end
    if langHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        cycleLanguageSetting(ctx.setLanguageFn)
    end

    if not utilityMode then
        local fxSize = math.max(S(10), math.floor(S(16) * iconScale + 0.5))
        local fxX = themeX + (themeSize - fxSize) / 2
        local fxY = themeY + themeSize + S(3)
        local fxHover = mx >= fxX - S(2) and mx <= fxX + fxSize + S(2) and my >= fxY - S(2) and my <= fxY + fxSize + S(2)

        local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
        if SETTINGS.visualFX then
            gfx.set(iconPalette.fxOn[1], iconPalette.fxOn[2], iconPalette.fxOn[3], fxAlpha)
        else
            gfx.set(iconPalette.fxOff[1], iconPalette.fxOff[2], iconPalette.fxOff[3], fxAlpha * 0.6)
        end
        gfx.setfont(1, "Arial", S(9), string.byte("b"))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2
        gfx.y = fxY + S(1)
        gfx.drawstr(fxText)

        if SETTINGS.visualFX then
            gfx.set(iconPalette.fxSpark[1], iconPalette.fxSpark[2], iconPalette.fxSpark[3], fxAlpha * 0.8)
            gfx.circle(fxX - S(1), fxY + S(2), S(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - S(2), S(1.5), 1, 1)
        else
            gfx.set(iconPalette.fxOffSlash[1], iconPalette.fxOffSlash[2], iconPalette.fxOffSlash[3], fxAlpha)
            gfx.line(fxX - S(1), fxY + fxSize / 2, fxX + fxSize + S(1), fxY + fxSize / 2)
        end

        if fxHover and controlsOpacity > 0.3 then
            local fxTip = SETTINGS.visualFX and (T("fx_disable") or "Disable FX") or (T("fx_enable") or "Enable FX")
            tooltipText = fxTip .. " " .. (T("fx_switch_native_suffix") or (T("fx_switch_native_suffix") or "Right-click: switch to REAPER Native UI."))
            tooltipX, tooltipY = mx + S(10), my + S(15)
        end
        if fxHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.visualFX = not SETTINGS.visualFX
            saveSettings()
        end
        if fxHover and rightMouseDown and not state.wasRightMouseDown then
            toggleUIMode()
        end
    end

    ctx.tooltipText = tooltipText
    ctx.tooltipX = tooltipX
    ctx.tooltipY = tooltipY
end

local function drawResultControls(ctx)
    local w, S = ctx.w, ctx.S
    local mx, my = ctx.mx, ctx.my
    local mouseDown = ctx.mouseDown
    local rightMouseDown = ctx.rightMouseDown
    local state = ctx.state
    local tooltipText = ctx.tooltipText
    local tooltipX = ctx.tooltipX
    local tooltipY = ctx.tooltipY

    local resultTokens = (UI_TOKENS and UI_TOKENS.result) or {}
    local controls = resultTokens.controls or {}
    local gaps = resultTokens.sectionGaps or {}
    local spacing = resultTokens.spacing or {}
    local fonts = resultTokens.fonts or {}

    local iconScale = controls.iconScale or 0.66
    local themeSize = math.max(S(controls.themeSizeMin or 12), math.floor(S(controls.themeSizeBase or 20) * iconScale + 0.5))
    local themeX = w - themeSize - S(controls.themeRight or 10)
    local themeY = S(controls.themeTop or 8)
    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize

    local controlsLeft = themeX - S(gaps.controlsLeftPad or 60)
    local controlsBottom = themeY + themeSize + S(gaps.controlsBottomPad or 30)
    local mouseInControls = (mx >= controlsLeft) and (my >= 0) and (my <= controlsBottom)
    local applyControlsOpacity = ctx.updateControlsOpacityFn
    if type(applyControlsOpacity) ~= "function" then
        applyControlsOpacity = _G.updateControlsOpacity
    end
    local utilityMode = isUtilityMode()
    if utilityMode then
        ctx.themeX = themeX
        ctx.themeY = themeY
        ctx.themeSize = themeSize
        drawUtilityControlsCore(ctx)
        return
    end

    local controlsOpacity
    if type(applyControlsOpacity) == "function" then
        controlsOpacity = applyControlsOpacity(state, mouseInControls)
    else
        controlsOpacity = mouseInControls and 1.0 or 0.0
    end

    if themeHover then
        GUI.uiClickedThisFrame = true
    end
    local iconPalette = getFunctionalIconPalette()
    local accent = getColorOrFallback("accent", {0.4, 0.6, 0.9})

    if SETTINGS.darkMode then
        gfx.set(iconPalette.moon[1], iconPalette.moon[2], iconPalette.moon[3], (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 2 - 2, 1, 1)
        gfx.set(iconPalette.moonCutout[1], iconPalette.moonCutout[2], iconPalette.moonCutout[3], 1 * controlsOpacity)
        gfx.circle(themeX + themeSize / 2 + 4, themeY + themeSize / 2 - 3, themeSize / 2 - 3, 1, 1)
    else
        gfx.set(iconPalette.sun[1], iconPalette.sun[2], iconPalette.sun[3], (themeHover and 1 or 0.8) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 3, 1, 1)
        gfx.set(iconPalette.sunRays[1], iconPalette.sunRays[2], iconPalette.sunRays[3], (themeHover and 1 or 0.8) * controlsOpacity)
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local x1 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 3 + 2)
            local y1 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 3 + 2)
            local x2 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 2 - 1)
            local y2 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 2 - 1)
            gfx.line(x1, y1, x2, y2)
        end
    end

    if themeHover and not utilityMode and rightMouseDown and not (state.wasRightMouseDown or false) and controlsOpacity > 0.3 then
        cycleThemePreset()
        updateTheme()
    end
    if themeHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.darkMode = not SETTINGS.darkMode
        updateTheme()
        saveSettings()
    end
    if themeHover and controlsOpacity > 0.3 then
        tooltipText = utilityMode and (T("tooltip_theme") or (T("tooltip_theme") or "Toggle dark / light.")) or getThemeToggleTooltip()
        tooltipX, tooltipY = mx + S(spacing.tooltipOffsetX or 10), my + S(spacing.tooltipOffsetY or 15)
    end

    if not utilityMode then
        local fxSize = math.max(S(controls.fxSizeMin or 10), math.floor(S(controls.fxSizeBase or 16) * iconScale + 0.5))
        local fxX = themeX + (themeSize - fxSize) / 2
        local fxY = themeY + themeSize + S(gaps.fxOffsetY or 3)
        local fxHover = mx >= fxX - S(controls.fxHitPad or 2) and mx <= fxX + fxSize + S(controls.fxHitPad or 2) and my >= fxY - S(controls.fxHitPad or 2) and my <= fxY + fxSize + S(controls.fxHitPad or 2)

        local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
        if SETTINGS.visualFX then
            gfx.set(iconPalette.fxOn[1], iconPalette.fxOn[2], iconPalette.fxOn[3], fxAlpha)
        else
            gfx.set(iconPalette.fxOff[1], iconPalette.fxOff[2], iconPalette.fxOff[3], fxAlpha * 0.6)
        end
        gfx.setfont(1, "Arial", S(fonts.controls or 9), string.byte("b"))
        local fxText = "FX"
        local fxTextW = gfx.measurestr(fxText)
        gfx.x = fxX + (fxSize - fxTextW) / 2
        gfx.y = fxY + S(1)
        gfx.drawstr(fxText)
        if SETTINGS.visualFX then
            gfx.set(iconPalette.fxSpark[1], iconPalette.fxSpark[2], iconPalette.fxSpark[3], fxAlpha * 0.8)
            gfx.circle(fxX - S(1), fxY + S(2), S(1.5), 1, 1)
            gfx.circle(fxX + fxSize, fxY + fxSize - S(2), S(1.5), 1, 1)
        else
            gfx.set(iconPalette.fxOffSlash[1], iconPalette.fxOffSlash[2], iconPalette.fxOffSlash[3], fxAlpha)
            gfx.line(fxX - S(1), fxY + fxSize / 2, fxX + fxSize + S(1), fxY + fxSize / 2)
        end
        if fxHover then
            GUI.uiClickedThisFrame = true
        end
        if fxHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
            SETTINGS.themePreset = "reaper_native"
            updateTheme()
            saveSettings()
        end
        if fxHover and controlsOpacity > 0.3 then
            tooltipText = T("tooltip_switch_native_ui") or "Switch to REAPER Native UI."
            tooltipX, tooltipY = mx + S(spacing.tooltipOffsetX or 10), my + S(spacing.tooltipOffsetY or 15)
        end
    end

    local langW = S(controls.langWidth or 22)
    local langH = S(controls.langHeight or 14)
    local langX = themeX - langW - S(gaps.langGap or 6)
    local langY = themeY + (themeSize - langH) / 2
    local langHover = mx >= langX and mx <= langX + langW and my >= langY and my <= langY + langH

    gfx.setfont(1, "Arial", S(fonts.controls or 9), string.byte("b"))
    local langCode = string.upper(SETTINGS.language or "EN")
    local langTextW = gfx.measurestr(langCode)

    if langHover then
        gfx.set(accent[1], accent[2], accent[3], 1 * controlsOpacity)
        if controlsOpacity > 0.3 then
            tooltipText = T("tooltip_lang") or (T("tooltip_lang") or "Change language. Right-click: toggle tooltips.")
            tooltipX, tooltipY = mx + S(spacing.tooltipOffsetX or 10), my + S(spacing.tooltipOffsetY or 15)
            if rightMouseDown and not (state.wasRightMouseDown or false) then
                SETTINGS.tooltips = not SETTINGS.tooltips
                saveSettings()
            end
            if mouseDown and not state.wasMouseDown then
                cycleLanguageSetting(ctx.setLanguageFn)
            end
        end
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    ctx.tooltipText = tooltipText
    ctx.tooltipX = tooltipX
    ctx.tooltipY = tooltipY
end

function M.drawTopRightControls(ctx)
    ctx = ctx or {}
    local profile = ctx.profile or "help"
    if not ctx.S then
        error("drawTopRightControls(ctx) requires ctx.S scale function")
    end
    if ctx.rightMouseDown == nil then
        ctx.rightMouseDown = gfx.mouse_cap & 2 == 2
    end

    if profile == "result" then
        drawResultControls(ctx)
        return ctx
    end

    drawHelpControls(ctx)
    return ctx
end

M.drawUtilityControls = drawUtilityControlsCore

return M
