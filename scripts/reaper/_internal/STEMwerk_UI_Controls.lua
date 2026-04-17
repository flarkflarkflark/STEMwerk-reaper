-- STEMwerk_UI_Controls.lua
-- Shared top-right controls strip (theme/language/fx + tooltip behavior).

local M = {}

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

local function drawHelpControls(ctx)
    local S = ctx.S
    local mx, my = ctx.mx, ctx.my
    local mouseDown = ctx.mouseDown
    local rightMouseDown = ctx.rightMouseDown
    local state = ctx.state
    local controlsOpacity = ctx.controlsOpacity or 1
    local iconScale = ctx.iconScale or 0.66
    local themeX = ctx.themeX
    local themeY = ctx.themeY
    local themeSize = ctx.themeSize

    local tooltipText = ctx.tooltipText
    local tooltipX = ctx.tooltipX
    local tooltipY = ctx.tooltipY

    local themeHover = mx >= themeX and mx <= themeX + themeSize and my >= themeY and my <= themeY + themeSize
    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)
        gfx.circle(themeX + themeSize / 2 + 4, themeY + themeSize / 2 - 3, themeSize / 2 - 3, 1, 1)
    else
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 3, 1, 1)
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
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
        gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
    else
        gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 0.8 * controlsOpacity)
    end
    gfx.x = langX + (langW - langTextW) / 2
    gfx.y = langY
    gfx.drawstr(langCode)

    if langHover and controlsOpacity > 0.3 then
        tooltipText = T("tooltip_change_language")
        tooltipX, tooltipY = mx + S(10), my + S(15)
    end
    if langHover and rightMouseDown and not state.wasRightMouseDown and controlsOpacity > 0.3 then
        SETTINGS.tooltips = not SETTINGS.tooltips
        saveSettings()
    end
    if langHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        cycleLanguageSetting(ctx.setLanguageFn)
    end

    local fxSize = math.max(S(10), math.floor(S(16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + S(3)
    local fxHover = mx >= fxX - S(2) and mx <= fxX + fxSize + S(2) and my >= fxY - S(2) and my <= fxY + fxSize + S(2)

    local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
    if SETTINGS.visualFX then
        gfx.set(0.4, 0.9, 0.5, fxAlpha)
    else
        gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6)
    end
    gfx.setfont(1, "Arial", S(9), string.byte("b"))
    local fxText = "FX"
    local fxTextW = gfx.measurestr(fxText)
    gfx.x = fxX + (fxSize - fxTextW) / 2
    gfx.y = fxY + S(1)
    gfx.drawstr(fxText)

    if SETTINGS.visualFX then
        gfx.set(1, 1, 0.5, fxAlpha * 0.8)
        gfx.circle(fxX - S(1), fxY + S(2), S(1.5), 1, 1)
        gfx.circle(fxX + fxSize, fxY + fxSize - S(2), S(1.5), 1, 1)
    else
        gfx.set(0.8, 0.3, 0.3, fxAlpha)
        gfx.line(fxX - S(1), fxY + fxSize / 2, fxX + fxSize + S(1), fxY + fxSize / 2)
    end

    if fxHover and controlsOpacity > 0.3 then
        tooltipText = SETTINGS.visualFX and T("fx_disable") or T("fx_enable")
        tooltipX, tooltipY = mx + S(10), my + S(15)
    end
    if fxHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
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
    local controlsOpacity = updateControlsOpacity(state, mouseInControls)

    if themeHover then
        GUI.uiClickedThisFrame = true
    end

    if SETTINGS.darkMode then
        gfx.set(0.7, 0.7, 0.5, (themeHover and 1 or 0.6) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 2 - 2, 1, 1)
        gfx.set(0, 0, 0, 1 * controlsOpacity)
        gfx.circle(themeX + themeSize / 2 + 4, themeY + themeSize / 2 - 3, themeSize / 2 - 3, 1, 1)
    else
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
        gfx.circle(themeX + themeSize / 2, themeY + themeSize / 2, themeSize / 3, 1, 1)
        gfx.set(0.9, 0.7, 0.2, (themeHover and 1 or 0.8) * controlsOpacity)
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local x1 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 3 + 2)
            local y1 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 3 + 2)
            local x2 = themeX + themeSize / 2 + math.cos(angle) * (themeSize / 2 - 1)
            local y2 = themeY + themeSize / 2 + math.sin(angle) * (themeSize / 2 - 1)
            gfx.line(x1, y1, x2, y2)
        end
    end

    if themeHover and rightMouseDown and not (state.wasRightMouseDown or false) and controlsOpacity > 0.3 then
        cycleThemePreset()
        updateTheme()
    end
    if themeHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.darkMode = not SETTINGS.darkMode
        updateTheme()
        saveSettings()
    end
    if themeHover and controlsOpacity > 0.3 then
        tooltipText = getThemeToggleTooltip()
        tooltipX, tooltipY = mx + S(spacing.tooltipOffsetX or 10), my + S(spacing.tooltipOffsetY or 15)
    end

    local fxSize = math.max(S(controls.fxSizeMin or 10), math.floor(S(controls.fxSizeBase or 16) * iconScale + 0.5))
    local fxX = themeX + (themeSize - fxSize) / 2
    local fxY = themeY + themeSize + S(gaps.fxOffsetY or 3)
    local fxHover = mx >= fxX - S(controls.fxHitPad or 2) and mx <= fxX + fxSize + S(controls.fxHitPad or 2) and my >= fxY - S(controls.fxHitPad or 2) and my <= fxY + fxSize + S(controls.fxHitPad or 2)

    local fxAlpha = (fxHover and 1 or 0.7) * controlsOpacity
    if SETTINGS.visualFX then
        gfx.set(0.4, 0.9, 0.5, fxAlpha)
    else
        gfx.set(0.5, 0.5, 0.5, fxAlpha * 0.6)
    end
    gfx.setfont(1, "Arial", S(fonts.controls or 9), string.byte("b"))
    local fxText = "FX"
    local fxTextW = gfx.measurestr(fxText)
    gfx.x = fxX + (fxSize - fxTextW) / 2
    gfx.y = fxY + S(1)
    gfx.drawstr(fxText)
    if SETTINGS.visualFX then
        gfx.set(1, 1, 0.5, fxAlpha * 0.8)
        gfx.circle(fxX - S(1), fxY + S(2), S(1.5), 1, 1)
        gfx.circle(fxX + fxSize, fxY + fxSize - S(2), S(1.5), 1, 1)
    else
        gfx.set(0.8, 0.3, 0.3, fxAlpha)
        gfx.line(fxX - S(1), fxY + fxSize / 2, fxX + fxSize + S(1), fxY + fxSize / 2)
    end
    if fxHover and mouseDown and not state.wasMouseDown and controlsOpacity > 0.3 then
        SETTINGS.visualFX = not SETTINGS.visualFX
        saveSettings()
    end
    if fxHover and controlsOpacity > 0.3 then
        tooltipText = SETTINGS.visualFX and (T("fx_disable") or "Disable visual effects") or (T("fx_enable") or "Enable visual effects")
        tooltipX, tooltipY = mx + S(spacing.tooltipOffsetX or 10), my + S(spacing.tooltipOffsetY or 15)
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
        gfx.set(0.4, 0.6, 0.9, 1 * controlsOpacity)
        if controlsOpacity > 0.3 then
            tooltipText = T("tooltip_change_language") or "Click to change language"
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

return M
