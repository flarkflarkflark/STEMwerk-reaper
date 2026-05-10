-- STEMwerk_UI_Draw.lua: Common draw and tooltip helpers extracted from STEMwerk.lua

local M = {}

local DEPS = {}

function M.configure(deps)
    if type(deps) ~= "table" then
        return
    end
    for k, v in pairs(deps) do
        DEPS[k] = v
    end
end

local function optionalDep(name)
    local v = DEPS[name]
    if v ~= nil then
        return v
    end
    return _G[name]
end

local function requireDep(name)
    local v = optionalDep(name)
    if v == nil then
        error("STEMwerk_UI_Draw missing dependency: " .. tostring(name))
    end
    return v
end

function M._wrapTextToWidth(text, maxWidth)
    local out = {}
    for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if raw == "" then
            out[#out + 1] = ""
        else
            local line = ""
            for word in raw:gmatch("%S+") do
                if line == "" then
                    line = word
                else
                    local candidate = line .. " " .. word
                    if gfx.measurestr(candidate) <= maxWidth then
                        line = candidate
                    else
                        out[#out + 1] = line
                        line = word
                    end
                end
            end
            if line ~= "" then
                out[#out + 1] = line
            end
        end
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    return out
end

function M.fitTextToBox(text, availableW, baseFontSize, minFontSize)
    text = tostring(text or "")
    local fontSize = baseFontSize
    local tw = gfx.measurestr(text)
    if tw > availableW and availableW > 0 then
        local scale = availableW / tw
        fontSize = math.max(minFontSize, math.floor(baseFontSize * scale))
        gfx.setfont(1, "Arial", fontSize)
        tw = gfx.measurestr(text)
        if tw > availableW then
            local ell = ".."
            local ellW = gfx.measurestr(ell)
            local maxW = math.max(0, availableW - ellW)
            local n = #text
            while n > 0 and gfx.measurestr(text:sub(1, n)) > maxW do
                n = n - 1
            end
            if n > 0 then
                text = text:sub(1, n) .. ell
            else
                text = ell
            end
            tw = gfx.measurestr(text)
        end
    end
    return text, tw, fontSize
end

local function fitControlLabel(label, availableW, baseFontSize, minScale, hardMin)
    local minByScale = math.floor((baseFontSize or 0) * (minScale or 0.84) + 0.5)
    local minFontSize = math.max(hardMin or 0, minByScale)
    return M.fitTextToBox(label, availableW, baseFontSize, minFontSize)
end

-- Draw a tooltip box with stem-color top bar. Caller must set font before calling.
-- padding/lineH/maxTextW are already scaled (S/UI/PS).
function M.drawTooltipStyled(tooltipText, tooltipX, tooltipY, winW, winH, padding, lineH, maxTextW)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end

    local getTooltipPalette = requireDep("getTooltipPalette")
    local getThemeRadius = requireDep("getThemeRadius")
    local getThemeBorderWeight = requireDep("getThemeBorderWeight")
    local drawThemeSurfaceBox = requireDep("drawThemeSurfaceBox")

    local text = tostring(tooltipText or "")
    if text == "" then
        return
    end

    local maxW = maxTextW or (winW * 0.62)
    maxW = math.max(50, math.min(maxW, winW - padding * 4))
    local lines = M._wrapTextToWidth(text, maxW)
    if #lines == 0 then
        lines = { text }
    end

    local maxLineW = 0
    for _, ln in ipairs(lines) do
        local lw = gfx.measurestr(ln)
        if lw > maxLineW then
            maxLineW = lw
        end
    end

    local boxW = maxLineW + padding * 2
    local boxH = (#lines * lineH) + padding * 2

    local tx = tooltipX
    local ty = tooltipY
    if tx + boxW > winW then
        tx = winW - boxW - padding
    end
    if ty + boxH > winH then
        ty = tooltipY - boxH - padding * 2
    end
    if tx < padding then
        tx = padding
    end
    if ty < padding then
        ty = padding
    end

    local ttBg, ttBorder, ttText, ttAlpha = getTooltipPalette()
    local radius = getThemeRadius(nil, 6, math.floor(math.min(boxW, boxH) / 2))
    local borderWeight = getThemeBorderWeight(nil, 1)
    drawThemeSurfaceBox(tx, ty, boxW, boxH, ttBg, ttBorder, ttAlpha, 1, radius, borderWeight, 0.75, "tooltip")

    local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
    if not utilityMode then
        for i = 0, boxW - 1 do
            local colorIdx = math.floor(i / boxW * 4) + 1
            colorIdx = math.min(4, math.max(1, colorIdx))
            local c = STEM_BORDER_COLORS[colorIdx]
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.9)
            gfx.line(tx + i, ty, tx + i, ty + 2)
        end
    end

    gfx.set(ttText[1], ttText[2], ttText[3], 1)
    local y = ty + padding
    for _, ln in ipairs(lines) do
        gfx.x = tx + padding
        gfx.y = y
        gfx.drawstr(ln)
        y = y + lineH
    end
end

-- Draw the current tooltip (call at end of frame)
function M.drawTooltip()
    if SETTINGS and SETTINGS.tooltips == false then
        GUI.tooltip = nil
        GUI.richTooltip = nil
        GUI.shortcutTooltip = nil
        return
    end

    local S = requireDep("S")
    local getTooltipPalette = requireDep("getTooltipPalette")
    local getThemeRadius = requireDep("getThemeRadius")
    local getThemeBorderWeight = requireDep("getThemeBorderWeight")
    local drawThemeSurfaceBox = requireDep("drawThemeSurfaceBox")

    if GUI.richTooltip then
        gfx.setfont(1, "Arial", S(10))
        local is6Stem = (tostring(SETTINGS.model or "") == "htdemucs_6s")
        local padding = S(8)
        local lineH = S(14)
        local stemNameKeyById = {
            vocals = "stem_vocals",
            drums = "stem_drums",
            bass = "stem_bass",
            other = "stem_other",
            guitar = "stem_guitar",
            piano = "stem_piano",
        }

        local function stemDisplayName(stemOrName)
            local raw = stemOrName
            if type(stemOrName) == "table" then
                raw = stemOrName.name or stemOrName.file or ""
            end
            raw = tostring(raw or "")
            if raw == "" then return "" end
            local id = raw:lower():gsub("%.wav$", "")
            local key = stemNameKeyById[id]
            if key and type(T) == "function" then
                local translated = T(key)
                if translated and translated ~= "" and translated ~= key then
                    return translated
                end
            end
            return raw
        end

        local titleColors = STEM_BORDER_COLORS

        local selectedStems = {}
        for _, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or SETTINGS.model == "htdemucs_6s") then
                table.insert(selectedStems, { name = stemDisplayName(stem), color = stem.color })
            end
        end

        local targetText = "New tracks"
        if SETTINGS.deleteOriginal then
            targetText = "Delete original"
        elseif SETTINGS.deleteSelection then
            targetText = "Delete selection"
        elseif SETTINGS.muteOriginal then
            targetText = "Mute original"
        elseif SETTINGS.muteSelection then
            targetText = "Mute selection"
        end
        if SETTINGS.createFolder then
            targetText = targetText .. " + folder"
        end

        local selTrackCount = reaper.CountSelectedTracks(0)
        local selItemCount = 0
        for i = 0, selTrackCount - 1 do
            local track = reaper.GetSelectedTrack(0, i)
            selItemCount = selItemCount + reaper.CountTrackMediaItems(track)
        end

        local th = padding * 2 + lineH * 5 + S(10)
        local labelColW = S(65)

        gfx.setfont(1, "Arial", S(10), string.byte("b"))
        local stemsValueW = 0
        for i, stem in ipairs(selectedStems) do
            stemsValueW = stemsValueW + gfx.measurestr(stem.name)
            if i < #selectedStems then
                stemsValueW = stemsValueW + gfx.measurestr(" ")
            end
        end

        gfx.setfont(1, "Arial", S(10))
        local selectionText = ""
        local buildFooterLines = optionalDep("buildFooterLines")
        local footerLines = (type(buildFooterLines) == "function") and buildFooterLines() or nil
        if footerLines and footerLines.selLine and footerLines.selLine ~= "" then
            selectionText = tostring(footerLines.selLine):gsub("^[^:]+:%s*", "")
        end

        local isTakesMode = not SETTINGS.createNewTracks
        local takesText = isTakesMode and T("yes") or T("no")

        local actions = {}
        if SETTINGS.createNewTracks then
            table.insert(actions, T("new_tracks"))
            if SETTINGS.createFolder then
                table.insert(actions, "+ " .. T("create_folder"))
            end
        else
            table.insert(actions, T("in_place"))

            local ppMode = tostring(SETTINGS.postProcessTakes or "none")
            if ppMode == "none" then
                table.insert(actions, "(" .. T("keep_takes") .. ")")
            elseif ppMode == "explode_new_tracks" then
                table.insert(actions, "-> " .. T("new_tracks"))
            elseif ppMode == "explode_in_place" then
                table.insert(actions, "-> " .. T("explode_in_place"))
            elseif ppMode == "explode_in_order" then
                table.insert(actions, "-> " .. T("explode_in_order"))
            end
        end

        if SETTINGS.muteOriginal then
            table.insert(actions, "+ " .. T("mute_original"))
        end
        if SETTINGS.deleteOriginal then
            table.insert(actions, "+ " .. T("delete_original"))
        end
        if SETTINGS.deleteOriginalTrack then
            table.insert(actions, "+ " .. T("delete_track"))
        end
        if SETTINGS.muteSelectionOnly then
            table.insert(actions, "+ " .. T("mute_selection"))
        end
        if SETTINGS.deleteSelectionOnly then
            table.insert(actions, "+ " .. T("delete_selection"))
        end
        targetText = #actions > 0 and table.concat(actions, " ") or "-"

        local selValueW = gfx.measurestr(selectionText)
        local takesValueW = gfx.measurestr(takesText)
        local targetValueW = gfx.measurestr(targetText)

        gfx.setfont(1, "Arial", S(11), string.byte("b"))
        local headerText = T("click_to_stemperate")
        local headerLineW = gfx.measurestr(headerText)

        local maxValueW = math.max(stemsValueW, selValueW, takesValueW, targetValueW)
        local tw = math.max(headerLineW + padding * 2, padding + labelColW + maxValueW + padding)

        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        if tx + tw > gfx.w then
            tx = gfx.w - tw - S(5)
        end
        if ty + th > gfx.h then
            ty = GUI.tooltipY - th - S(20)
        end

        local ttBg, ttBorder, ttText, ttAlpha = getTooltipPalette()
        local tooltipRadius = getThemeRadius(nil, S(6), math.floor(math.min(tw, th) / 2))
        local tooltipBorderWeight = getThemeBorderWeight(nil, 1)
        drawThemeSurfaceBox(tx, ty, tw, th, ttBg, ttBorder, ttAlpha, 1, tooltipRadius, tooltipBorderWeight, 0.75, "tooltip")

        local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
        if not utilityMode then
            for i = 0, tw - 1 do
                local colorIdx = math.floor(i / tw * 4) + 1
                colorIdx = math.min(4, math.max(1, colorIdx))
                local c = titleColors[colorIdx]
                gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.9)
                gfx.line(tx + i, ty, tx + i, ty + 2)
            end
        end
        local labelX = tx + padding
        local valueX = tx + padding + labelColW
        local currentY = ty + padding + S(2)

        gfx.setfont(1, "Arial", S(11), string.byte("b"))
        local headerW = gfx.measurestr(headerText)
        local headerX = tx + (tw - headerW) / 2
        gfx.x = headerX
        gfx.y = currentY

        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        if utilityMode then
            gfx.drawstr(headerText)
        else
            local stemIdx = headerText:find("STEM")
            local prefix = headerText
            local suffix = ""
            if stemIdx then
                prefix = headerText:sub(1, stemIdx - 1)
                suffix = headerText:sub(stemIdx + 4)
            end
            gfx.drawstr(prefix)
            for i, letter in ipairs({ "S", "T", "E", "M" }) do
                local c = titleColors[i]
                gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
                gfx.drawstr(letter)
            end
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
            gfx.drawstr(suffix)
        end
        currentY = currentY + lineH + S(4)

        gfx.setfont(1, "Arial", S(10))
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_stems_label") or "Stems")

        local activeStems = {}
        for _, stem in ipairs(STEMS) do
            if stem.selected and (not stem.sixStemOnly or is6Stem) then
                table.insert(activeStems, stem)
            end
        end

        if #activeStems == 0 then
            gfx.set(1, 0.3, 0.3, 1)
            gfx.x = valueX
            gfx.drawstr(T("no_stems_selected") or "[!] None")
        else
            gfx.setfont(1, "Arial", S(10), string.byte("b"))
            local stemX = valueX
            for i, stem in ipairs(activeStems) do
                local stemLabel = stemDisplayName(stem)
                if utilityMode then
                    gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
                else
                    gfx.set(stem.color[1] / 255, stem.color[2] / 255, stem.color[3] / 255, 1)
                end
                gfx.x = stemX
                gfx.y = currentY
                gfx.drawstr(stemLabel)
                stemX = stemX + gfx.measurestr(stemLabel)
                if i < #activeStems then
                    gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
                    gfx.x = stemX
                    gfx.drawstr(" ")
                    stemX = stemX + gfx.measurestr(" ")
                end
            end
        end
        currentY = currentY + lineH

        gfx.setfont(1, "Arial", S(10))
        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_selection_label") or "Selection")
        gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        gfx.x = valueX
        gfx.drawstr(selectionText)
        currentY = currentY + lineH

        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_takes_label") or "Takes")
        if utilityMode then
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        elseif SETTINGS.createTakes then
            gfx.set(0.4, 0.9, 0.5, 1)
        else
            gfx.set(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3], 1)
        end
        gfx.x = valueX
        gfx.drawstr(takesText)
        currentY = currentY + lineH

        gfx.set(THEME.textHint[1], THEME.textHint[2], THEME.textHint[3], 1)
        gfx.x = labelX
        gfx.y = currentY
        gfx.drawstr(T("rich_target_label") or "Target")
        if utilityMode then
            gfx.set(THEME.text[1], THEME.text[2], THEME.text[3], 1)
        else
            gfx.set(1.0, 0.6, 0.2, 1)
        end
        gfx.x = valueX
        gfx.drawstr(targetText)

        GUI.richTooltip = nil
    elseif GUI.tooltip then
        local tooltipColors = STEM_BORDER_COLORS

        gfx.setfont(1, "Arial", S(11))
        local padding = S(8)
        local tooltipText = tostring(GUI.tooltip or "")

        local function wrapTextToWidth(text, maxWidth)
            local out = {}
            for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
                if raw == "" then
                    out[#out + 1] = ""
                else
                    local line = ""
                    for word in raw:gmatch("%S+") do
                        if line == "" then
                            line = word
                        else
                            local candidate = line .. " " .. word
                            if gfx.measurestr(candidate) <= maxWidth then
                                line = candidate
                            else
                                out[#out + 1] = line
                                line = word
                            end
                        end
                    end
                    if line ~= "" then
                        out[#out + 1] = line
                    end
                end
            end
            if #out > 0 and out[#out] == "" then
                out[#out] = nil
            end
            return out
        end

        local maxTextW = math.floor(math.min(gfx.w * 0.62, S(520)))
        maxTextW = math.max(S(180), maxTextW)
        local lines = wrapTextToWidth(tooltipText, maxTextW)

        local maxLineW = 0
        for _, line in ipairs(lines) do
            local w = gfx.measurestr(line)
            if w > maxLineW then
                maxLineW = w
            end
        end
        local lineH = gfx.texth + S(2)
        local tw = maxLineW + padding * 2
        local th = (lineH * #lines) + padding * 2 + S(2)
        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        if tx + tw > gfx.w then
            tx = gfx.w - tw - S(5)
        end
        if ty + th > gfx.h then
            ty = GUI.tooltipY - th - S(20)
        end

        local ttBg, ttBorder, ttText, ttAlpha = getTooltipPalette()
        local tooltipRadius = getThemeRadius(nil, S(6), math.floor(math.min(tw, th) / 2))
        local tooltipBorderWeight = getThemeBorderWeight(nil, 1)
        drawThemeSurfaceBox(tx, ty, tw, th, ttBg, ttBorder, ttAlpha, 1, tooltipRadius, tooltipBorderWeight, 0.75, "tooltip")

        local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
        if not utilityMode then
            for i = 0, tw - 1 do
                local colorIdx = math.floor(i / tw * 4) + 1
                colorIdx = math.min(4, math.max(1, colorIdx))
                local c = tooltipColors[colorIdx]
                gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.9)
                gfx.line(tx + i, ty, tx + i, ty + 2)
            end
        end
        gfx.set(ttText[1], ttText[2], ttText[3], 1)
        local x = tx + padding
        local y = ty + padding + S(2)
        for _, line in ipairs(lines) do
            gfx.x = x
            gfx.y = y
            gfx.drawstr(line)
            y = y + lineH
        end

        GUI.tooltip = nil
    elseif GUI.shortcutTooltip then
        local tooltipColors = STEM_BORDER_COLORS
        local st = GUI.shortcutTooltip

        gfx.setfont(1, "Arial", S(11))
        local padding = S(8)
        local textW = gfx.measurestr(st.text)
        local shortcutW = gfx.measurestr(" [" .. st.shortcut .. "]")
        local tw = textW + shortcutW + padding * 2
        local th = S(18) + padding * 2
        local tx = GUI.tooltipX
        local ty = GUI.tooltipY

        if tx + tw > gfx.w then
            tx = gfx.w - tw - S(5)
        end
        if ty + th > gfx.h then
            ty = GUI.tooltipY - th - S(20)
        end

        local ttBg, ttBorder, ttText, ttAlpha = getTooltipPalette()
        local tooltipRadius = getThemeRadius(nil, S(6), math.floor(math.min(tw, th) / 2))
        local tooltipBorderWeight = getThemeBorderWeight(nil, 1)
        drawThemeSurfaceBox(tx, ty, tw, th, ttBg, ttBorder, ttAlpha, 1, tooltipRadius, tooltipBorderWeight, 0.75, "tooltip")

        local utilityMode = type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
        if not utilityMode then
            for i = 0, tw - 1 do
                local colorIdx = math.floor(i / tw * 4) + 1
                colorIdx = math.min(4, math.max(1, colorIdx))
                local c = tooltipColors[colorIdx]
                gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 0.9)
                gfx.line(tx + i, ty, tx + i, ty + 2)
            end
        end
        gfx.set(ttText[1], ttText[2], ttText[3], 1)
        gfx.x = tx + padding
        gfx.y = ty + padding + S(2)
        gfx.drawstr(st.text .. " ")

        if utilityMode then
            gfx.set(ttText[1], ttText[2], ttText[3], 0.7)
        else
            gfx.set(st.color[1] / 255, st.color[2] / 255, st.color[3] / 255, 1)
        end
        gfx.drawstr("[" .. st.shortcut .. "]")

        GUI.shortcutTooltip = nil
    end
end

-- Draw a checkbox as a toggle box (like stems/presets) and return if it was clicked (scaled)
-- Optional fixedW parameter to set a fixed width for all boxes
-- Optional fontSizeOverride: when provided, a group of boxes can share the same text size.
function M.drawCheckbox(x, y, checked, label, r, g, b, fixedW, fontSizeOverride)
    local S = requireDep("S")
    local drawGlossyRect = requireDep("drawGlossyRect")

    local clicked = false
    local labelWidth = gfx.measurestr(label)
    local boxW = fixedW or (labelWidth + S(16))
    local boxH = S(20)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + boxW and my >= y and my <= y + boxH

    if hover then
        GUI.uiClickedThisFrame = true
    end

    if mouseDown and hover then
        if not GUI.wasMouseDown then
            clicked = true
        end
    end

    local baseR
    local baseG
    local baseB
    local _chkUtilLight = not checked
        and type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
        and type(isThemeLightMode) == "function" and isThemeLightMode()
    if checked then
        local mult = hover and 1.2 or 1.0
        baseR = (r or 0) / 255 * mult
        baseG = (g or 0) / 255 * mult
        baseB = (b or 0) / 255 * mult
    elseif _chkUtilLight then
        local btn = THEME.button or {0.75, 0.75, 0.75}
        local mult = hover and 1.1 or 1.0
        baseR = math.min(1, btn[1] * mult)
        baseG = math.min(1, btn[2] * mult)
        baseB = math.min(1, btn[3] * mult)
    else
        local brightness = hover and 0.35 or 0.25
        baseR, baseG, baseB = brightness, brightness, brightness
    end
    drawGlossyRect(x, y, boxW, boxH, baseR, baseG, baseB, 1)

    local textAlpha = checked and 1 or (hover and 0.95 or 0.85)
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = math.max(S(10), math.floor(baseFontSize * 0.86 + 0.5))
    local padding = S(4)
    local labelText, tw, usedFontSize = fitControlLabel(label, boxW - padding * 2, baseFontSize, 0.86, minFontSize)
    local textX = x + (boxW - tw) / 2
    local textH = gfx.texth
    local textY = y + (boxH - textH) / 2
    if _chkUtilLight then
        local tc = THEME.text or {0.1, 0.1, 0.1}
        gfx.set(1, 1, 1, 0.18 * textAlpha)
        gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
        gfx.set(tc[1], tc[2], tc[3], textAlpha)
    else
        gfx.set(0, 0, 0, 0.35 * textAlpha)
        gfx.x, gfx.y = textX + 2, textY + 2
        gfx.drawstr(labelText)
        gfx.set(0, 0, 0, 0.55 * textAlpha)
        gfx.x, gfx.y = textX + 1, textY + 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = textX - 1, textY + 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = textX + 1, textY - 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = textX - 1, textY - 1
        gfx.drawstr(labelText)
        gfx.set(1, 1, 1, textAlpha)
    end
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked, boxW
end

-- Draw a radio button as a toggle box (like stems/presets) and return if it was clicked (scaled)
-- Optional fixedW parameter to set a fixed width for all boxes
-- Optional attentionMult: when not selected, draw a subtle accent pulse (used to hint "direct tool" availability)
-- Optional icon: currently supports "explode" (drawn at left; animated when attentionMult > 0)
-- Optional fontSizeOverride: when provided, all radios in a group can share the same text size.
-- Optional lockFontSize: when true, keep the font size fixed and truncate with ellipsis if needed.
function M.drawRadio(x, y, selected, label, color, fixedW, attentionMult, icon, fontSizeOverride, lockFontSize)
    local S = requireDep("S")
    local drawGlossyRect = requireDep("drawGlossyRect")

    local clicked = false
    local labelWidth = gfx.measurestr(label)
    local boxW = fixedW or (labelWidth + S(16))
    local boxH = S(20)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + boxW and my >= y and my <= y + boxH

    if hover then
        GUI.uiClickedThisFrame = true
    end

    if mouseDown and hover then
        if not GUI.wasMouseDown then
            clicked = true
        end
    end

    local r, g, b = THEME.accent[1] * 255, THEME.accent[2] * 255, THEME.accent[3] * 255
    if color then
        r, g, b = color[1], color[2], color[3]
    end

    local baseR
    local baseG
    local baseB
    local baseA
    local _radioUtilLight = not selected and (not (attentionMult and attentionMult > 0))
        and type(isThemeUtilityMode) == "function" and isThemeUtilityMode()
        and type(isThemeLightMode) == "function" and isThemeLightMode()
    if selected then
        local mult = hover and 1.2 or 1.0
        baseR, baseG, baseB, baseA = r / 255 * mult, g / 255 * mult, b / 255 * mult, 1
    else
        if attentionMult and attentionMult > 0 then
            local base = hover and 0.55 or 0.45
            baseA = math.min(0.9, math.max(0.25, base * attentionMult))
            baseR, baseG, baseB = r / 255, g / 255, b / 255
        elseif _radioUtilLight then
            local btn = THEME.button or {0.75, 0.75, 0.75}
            local mult = hover and 1.1 or 1.0
            baseR, baseG, baseB, baseA = math.min(1, btn[1] * mult), math.min(1, btn[2] * mult), math.min(1, btn[3] * mult), 1
        else
            local brightness = hover and 0.35 or 0.25
            baseR, baseG, baseB, baseA = brightness, brightness, brightness, 1
        end
    end
    drawGlossyRect(x, y, boxW, boxH, baseR, baseG, baseB, baseA)

    local textAlpha = selected and 1 or (hover and 0.95 or 0.85)
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = lockFontSize and baseFontSize or math.max(S(10), math.floor(baseFontSize * 0.86 + 0.5))
    local padding = S(4)

    if icon == "explode" then
        local t = os.clock() or 0
        local rot = 0
        local pulse = 1.0
        local anim = hover or (attentionMult and attentionMult > 0)
        if anim then
            rot = t * 2.2
            pulse = 0.92 + 0.14 * (0.5 + 0.5 * math.sin(t * 9.0))
        end

        local size = math.max(6, boxH * 0.52)
        local reservedLeft = S(5) + size + S(8)
        local labelText, tw, usedFontSize = fitControlLabel(label, boxW - reservedLeft - padding, baseFontSize, 0.88, minFontSize)
        local labelX = x + boxW - padding - tw
        local labelY = y + S(2)
        gfx.set(0, 0, 0, 0.35 * textAlpha)
        gfx.x, gfx.y = labelX + 2, labelY + 2
        gfx.drawstr(labelText)
        gfx.set(0, 0, 0, 0.55 * textAlpha)
        gfx.x, gfx.y = labelX + 1, labelY + 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX - 1, labelY + 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX + 1, labelY - 1
        gfx.drawstr(labelText)
        gfx.x, gfx.y = labelX - 1, labelY - 1
        gfx.drawstr(labelText)
        gfx.set(1, 1, 1, textAlpha)
        gfx.x, gfx.y = labelX, labelY
        gfx.drawstr(labelText)

        if usedFontSize ~= baseFontSize then
            gfx.setfont(1, "Arial", baseFontSize)
        end

        local cx = x + S(5) + size * 0.5
        local cy = y + boxH * 0.5

        local a = 0.9
        if anim then
            local att = attentionMult or 1.0
            a = math.min(1.0, 0.55 + 0.45 * att)
        end

        local stemCols = nil
        if anim and STEMS and STEMS[1] and STEMS[1].color then
            stemCols = {}
            for j = 1, 4 do
                local c = STEMS[j] and STEMS[j].color
                if c and c[1] and c[2] and c[3] then
                    stemCols[#stemCols + 1] = { c[1] / 255, c[2] / 255, c[3] / 255 }
                end
            end
            if #stemCols == 0 then
                stemCols = nil
            end
        end

        local spikeOuter = (size * 0.52) * pulse
        local spikeInner = (size * 0.30) * pulse
        local spikes = 9
        local phase = math.floor(t * 8.0)
        for i = 0, spikes - 1 do
            local ang = rot + (i / spikes) * (math.pi * 2)
            local x1 = cx + math.cos(ang) * spikeInner
            local y1 = cy + math.sin(ang) * spikeInner
            local x2 = cx + math.cos(ang) * spikeOuter
            local y2 = cy + math.sin(ang) * spikeOuter

            if stemCols then
                local ci = ((i + phase) % #stemCols) + 1
                gfx.set(stemCols[ci][1], stemCols[ci][2], stemCols[ci][3], a)
            else
                gfx.set(1, 1, 1, a)
            end
            gfx.line(x1, y1, x2, y2)
        end

        if stemCols then
            local ci = ((phase + spikes) % #stemCols) + 1
            gfx.set(stemCols[ci][1], stemCols[ci][2], stemCols[ci][3], a)
        else
            gfx.set(1, 1, 1, a)
        end
        gfx.circle(cx, cy, (size * 0.16) * pulse, 1, 1)
    else
        local labelText, tw, usedFontSize = fitControlLabel(label, boxW - padding * 2, baseFontSize, 0.86, minFontSize)
        local textX = x + (boxW - tw) / 2
        local textH = gfx.texth
        local textY = y + (boxH - textH) / 2
        if _radioUtilLight then
            local tc = THEME.text or {0.1, 0.1, 0.1}
            gfx.set(1, 1, 1, 0.18 * textAlpha)
            gfx.x, gfx.y = textX + 1, textY + 1; gfx.drawstr(labelText)
            gfx.set(tc[1], tc[2], tc[3], textAlpha)
        else
            gfx.set(0, 0, 0, 0.35 * textAlpha)
            gfx.x, gfx.y = textX + 2, textY + 2
            gfx.drawstr(labelText)
            gfx.set(0, 0, 0, 0.55 * textAlpha)
            gfx.x, gfx.y = textX + 1, textY + 1
            gfx.drawstr(labelText)
            gfx.x, gfx.y = textX - 1, textY + 1
            gfx.drawstr(labelText)
            gfx.x, gfx.y = textX + 1, textY - 1
            gfx.drawstr(labelText)
            gfx.x, gfx.y = textX - 1, textY - 1
            gfx.drawstr(labelText)
            gfx.set(1, 1, 1, textAlpha)
        end
        gfx.x, gfx.y = textX, textY
        gfx.drawstr(labelText)

        if usedFontSize ~= baseFontSize then
            gfx.setfont(1, "Arial", baseFontSize)
        end
    end

    return clicked, boxW
end

-- Draw a toggle button (like stems) with selected state
-- Optional fontSizeOverride: when provided, a group of buttons can share the same text size (like Output column).
function M.drawToggleButton(x, y, w, h, label, selected, color, fontSizeOverride)
    local S = requireDep("S")
    local drawGlossyRect = requireDep("drawGlossyRect")

    local clicked = false
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h

    if hover then
        GUI.uiClickedThisFrame = true
    end

    if mouseDown and hover then
        if not GUI.wasMouseDown then
            clicked = true
        end
    end

    local baseR
    local baseG
    local baseB
    if selected then
        local mult = hover and 1.2 or 1.0
        baseR = (color[1] or 0) / 255 * mult
        baseG = (color[2] or 0) / 255 * mult
        baseB = (color[3] or 0) / 255 * mult
    else
        local brightness = hover and 0.35 or 0.25
        baseR, baseG, baseB = brightness, brightness, brightness
    end
    drawGlossyRect(x, y, w, h, baseR, baseG, baseB, 1)

    local textAlpha = selected and 1 or (hover and 0.9 or 0.75)
    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = math.max(S(10), math.floor(baseFontSize * 0.86 + 0.5))
    local padding = S(4)
    local labelText, tw, usedFontSize = fitControlLabel(label, w - padding * 2, baseFontSize, 0.86, minFontSize)
    local textX = x + (w - tw) / 2
    local textH = gfx.texth
    local textY = y + (h - textH) / 2
    gfx.set(0, 0, 0, 0.35 * textAlpha)
    gfx.x, gfx.y = textX + 2, textY + 2
    gfx.drawstr(labelText)
    gfx.set(0, 0, 0, 0.55 * textAlpha)
    gfx.x, gfx.y = textX + 1, textY + 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY + 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX + 1, textY - 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY - 1
    gfx.drawstr(labelText)
    gfx.set(1, 1, 1, textAlpha)
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked
end

-- Draw a small button and return if it was clicked (scaled)
-- Optional fontSizeOverride: when provided, a group of buttons can share the same text size.
function M.drawButton(x, y, w, h, label, isDefault, color, fontSizeOverride)
    local S = requireDep("S")
    local drawGlossyPill = requireDep("drawGlossyPill")

    local clicked = false
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local mouseDown = gfx.mouse_cap & 1 == 1
    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h

    if hover then
        GUI.uiClickedThisFrame = true
    end

    if mouseDown and hover then
        if not GUI.wasMouseDown then
            clicked = true
        end
    end

    local baseR
    local baseG
    local baseB
    if color then
        local mult = hover and 1.2 or 1.0
        baseR = (color[1] or 0) / 255 * mult
        baseG = (color[2] or 0) / 255 * mult
        baseB = (color[3] or 0) / 255 * mult
    else
        if isDefault then
            if hover then
                baseR, baseG, baseB = THEME.buttonPrimaryHover[1], THEME.buttonPrimaryHover[2], THEME.buttonPrimaryHover[3]
            else
                baseR, baseG, baseB = THEME.buttonPrimary[1], THEME.buttonPrimary[2], THEME.buttonPrimary[3]
            end
        else
            if hover then
                baseR, baseG, baseB = THEME.buttonHover[1], THEME.buttonHover[2], THEME.buttonHover[3]
            else
                baseR, baseG, baseB = THEME.button[1], THEME.button[2], THEME.button[3]
            end
        end
    end

    drawGlossyPill(x, y, w, h, baseR, baseG, baseB)

    local baseFontSize = fontSizeOverride or S(13)
    local minFontSize = math.max(S(10), math.floor(baseFontSize * 0.84 + 0.5))
    local padding = S(4)
    local labelText, tw, usedFontSize = fitControlLabel(label, w - padding * 2, baseFontSize, 0.84, minFontSize)
    local textX = x + (w - tw) / 2
    local textH = gfx.texth
    local textY = y + (h - textH) / 2
    gfx.set(0, 0, 0, 0.4)
    gfx.x, gfx.y = textX + 2, textY + 2
    gfx.drawstr(labelText)
    gfx.set(0, 0, 0, 0.6)
    gfx.x, gfx.y = textX + 1, textY + 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY + 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX + 1, textY - 1
    gfx.drawstr(labelText)
    gfx.x, gfx.y = textX - 1, textY - 1
    gfx.drawstr(labelText)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = textX, textY
    gfx.drawstr(labelText)

    if usedFontSize ~= baseFontSize then
        gfx.setfont(1, "Arial", baseFontSize)
    end

    return clicked
end

return M
