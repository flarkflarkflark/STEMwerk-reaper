-- STEMwerk_UI_HelpLayout.lua
-- Shared Help text frame/header layout calculations.

local M = {}

local function resolveTokens(ctx)
    local t = (ctx and ctx.tokens) or {}
    return {
        contentTop = t.contentTop or 0,
        contentBottomReserve = t.contentBottomReserve or 60,
        contentMaxWidth = t.contentMaxWidth or 0,
        sidePadding = t.sidePadding or 30,
        titleFont = t.titleFont or 27,
        subtitleFont = t.subtitleFont or 13,
        titleTop = t.titleTop or 12,
        subtitleGap = t.subtitleGap or 32,
        bodyTopGap = t.bodyTopGap or 70,
        sectionGap = t.sectionGap or 12,
        bodyWrapWidth = t.bodyWrapWidth or 0,
        panelInnerPadding = t.panelInnerPadding or 15,
    }
end

function M.computeContentFrame(ctx)
    ctx = ctx or {}
    local S = ctx.S or function(v) return v end
    local t = resolveTokens(ctx)
    local w = ctx.w or 0
    local h = ctx.h or 0
    local contentY = ctx.contentY or 0
    local textOffsetX = ctx.textOffsetX or 0

    -- contentY already includes any upstream text Y offset. Do not add it again.
    local sidePad = S(t.sidePadding)
    local availableW = math.max(S(120), w - sidePad * 2)
    local maxWRaw = ctx.contentMaxWidth or t.contentMaxWidth
    local maxW = maxWRaw > 0 and S(maxWRaw) or availableW
    local frameW = math.min(availableW, maxW)
    local frameX = (w - frameW) / 2 + textOffsetX
    local frameY = contentY + S(t.contentTop + t.bodyTopGap)
    local frameH = math.max(S(80), h - frameY - S(t.contentBottomReserve))

    return {
        x = frameX,
        y = frameY,
        w = frameW,
        h = frameH,
    }
end

function M.computeBodyColumn(ctx)
    ctx = ctx or {}
    local frame = ctx.frame or {}
    local S = ctx.S or function(v) return v end
    local t = resolveTokens(ctx)

    local innerPadRaw = ctx.panelInnerPadding or t.panelInnerPadding
    local innerPad = S(innerPadRaw)
    local bodyX = (frame.x or 0) + innerPad
    local bodyW = math.max(S(80), (frame.w or 0) - innerPad * 2)
    local bodyWrapRaw = ctx.bodyWrapWidth or t.bodyWrapWidth
    if bodyWrapRaw and bodyWrapRaw > 0 then
        local maxBodyW = S(bodyWrapRaw)
        if bodyW > maxBodyW then
            local shrink = bodyW - maxBodyW
            bodyX = bodyX + shrink / 2
            bodyW = maxBodyW
        end
    end
    return {x = bodyX, w = bodyW}
end

function M.computeHeaderLayout(ctx)
    ctx = ctx or {}
    local S = ctx.S or function(v) return v end
    local t = resolveTokens(ctx)
    local w = ctx.w or 0
    local contentY = ctx.contentY or 0
    local textOffsetX = ctx.textOffsetX or 0
    local title = ctx.title or ""
    local subtitle = ctx.subtitle or ""

    local titleFont = S(ctx.titleFont or t.titleFont)
    local subtitleFont = S(ctx.subtitleFont or t.subtitleFont)
    local titleTop = S(ctx.titleTop or t.titleTop)
    local subtitleGap = S(ctx.subtitleGap or t.subtitleGap)

    gfx.setfont(1, "Arial", titleFont, string.byte("b"))
    local titleW = gfx.measurestr(title)
    local titleX = (w - titleW) / 2 + textOffsetX
    local titleY = contentY + titleTop

    gfx.setfont(1, "Arial", subtitleFont)
    local subtitleW = gfx.measurestr(subtitle)
    local subtitleX = (w - subtitleW) / 2 + textOffsetX
    local subtitleY = titleY + subtitleGap

    return {
        titleX = titleX,
        titleY = titleY,
        subtitleX = subtitleX,
        subtitleY = subtitleY,
        titleFont = titleFont,
        subtitleFont = subtitleFont,
    }
end

return M
