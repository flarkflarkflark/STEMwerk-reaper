-- STEMwerk_UI_Draw.lua: Common draw and tooltip helpers extracted from STEMwerk.lua

local M = {}

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
            if line ~= "" then out[#out + 1] = line end
        end
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    return out
end

function M.drawTooltipStyled(tooltipText, tooltipX, tooltipY, winW, winH, padding, lineH, maxTextW)
    if SETTINGS and SETTINGS.tooltips == false then
        return
    end
    -- ...existing code...
end

function M.drawTooltip()
    if SETTINGS and SETTINGS.tooltips == false then
        GUI.tooltip = nil
        GUI.richTooltip = nil
        GUI.shortcutTooltip = nil
        return
    end
    -- ...existing code...
end

function M.drawCheckbox(x, y, checked, label, r, g, b, fixedW, fontSizeOverride)
    -- ...existing code...
end

function M.drawRadio(x, y, selected, label, color, fixedW, attentionMult, icon, fontSizeOverride, lockFontSize)
    -- ...existing code...
end

function M.drawToggleButton(x, y, w, h, label, selected, color, fontSizeOverride)
    -- ...existing code...
end

function M.drawButton(x, y, w, h, label, isDefault, color, fontSizeOverride)
    -- ...existing code...
end

function M.fitTextToBox(text, availableW, baseFontSize, minFontSize)
    -- ...existing code...
end

return M
