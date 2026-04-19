-- STEMwerk_UI_Backgrounds.lua
-- Shared Help background and FX rendering helpers extracted from STEMwerk.lua.

local M = {}

local function resolveSettings(ctx)
    if ctx and ctx.SETTINGS then
        return ctx.SETTINGS
    end
    return _G.SETTINGS or {}
end

function M.drawWelcomeBackground(ctx)
    if not ctx then
        return
    end

    local w = ctx.w or 0
    local h = ctx.h or 0
    local contentY = ctx.contentY or 0
    local contentH = ctx.contentH or 0
    local textOffsetY = ctx.textOffsetY or 0
    local stemColors = ctx.stemColors or {}
    local PS = ctx.PS or function(v) return v end
    local helpStartTime = ctx.helpStartTime or 0
    local updateAudioReactivity = ctx.updateAudioReactivity
    local audioReactive = ctx.audioReactive or {}
    local settings = resolveSettings(ctx)

    local welcomeArtY = contentY - textOffsetY

    if type(updateAudioReactivity) == "function" then
        updateAudioReactivity()
    end

    local audioPeak = audioReactive.smoothPeakMono or 0
    local audioBass = audioReactive.smoothBass or 0
    local audioMid = audioReactive.smoothMid or 0
    local audioHigh = audioReactive.smoothHigh or 0
    local audioBeat = audioReactive.beatDecay or 0

    local bgTime = os.clock() - helpStartTime
    if settings.visualFX then
        for i = 1, 4 do
            local color = stemColors[i] or {1, 1, 1}
            local angle = bgTime * 0.2 + (i - 1) * math.pi / 2 + audioPeak * 0.3
            local radius = math.min(w, h) * (0.4 + audioBass * 0.15)
            local cx = w / 2 + math.cos(angle) * radius * 0.4
            local cy = welcomeArtY + contentH / 2 + math.sin(angle) * radius * 0.3
            local maxR = PS(120 + audioBass * 60)
            for r = maxR, PS(40), -PS(20) do
                local alpha = 0.03 + (maxR - r) / PS(400) + audioBeat * 0.05
                gfx.set(color[1], color[2], color[3], math.min(0.3, alpha))
                gfx.circle(cx, cy, r, 1, 1)
            end
        end

        local particleCount = 20 + math.floor(audioPeak * 15)
        for i = 1, particleCount do
            local px = (math.sin(bgTime * 0.5 + i * 1.3 + audioHigh * 0.5) * 0.5 + 0.5) * w
            local py = welcomeArtY + ((math.cos(bgTime * 0.3 + i * 0.7 + audioMid * 0.3) * 0.5 + 0.5) * contentH * 0.8)
            local col = stemColors[(i % 4) + 1] or {1, 1, 1}
            local particleAlpha = 0.15 + audioBeat * 0.2
            local particleSize = PS(3 + (i % 4) + audioPeak * 4)
            gfx.set(col[1], col[2], col[3], math.min(0.5, particleAlpha))
            gfx.circle(px, py, particleSize, 1, 1)
        end

        if audioPeak > 0.05 then
            local waveRadius = PS(80 + audioBass * 40)
            local wcx, wcy = w / 2, welcomeArtY + contentH / 2
            local waveformSize = audioReactive.waveformSize or 60
            local waveformIndex = audioReactive.waveformIndex or 1
            local waveformHistory = audioReactive.waveformHistory
            for i = 0, 59 do
                local angle = (i / 60) * math.pi * 2
                local histIdx = ((waveformIndex + i) % waveformSize) + 1
                local waveVal = (waveformHistory and waveformHistory[histIdx]) or audioPeak
                local r = waveRadius * (1 + waveVal * 0.4)
                local wx = wcx + math.cos(angle + bgTime * 0.5) * r
                local wy = wcy + math.sin(angle + bgTime * 0.5) * r
                local col = stemColors[(math.floor(i / 15) % 4) + 1] or {1, 1, 1}
                gfx.set(col[1], col[2], col[3], 0.2 + waveVal * 0.3)
                gfx.circle(wx, wy, PS(2 + waveVal * 4), 1, 1)
            end
        end
    end
end

function M.drawQuickStartBackground(ctx)
    if not ctx then
        return {audioPeak = 0, audioBass = 0, audioMid = 0, audioHigh = 0, audioBeat = 0}
    end

    local w = ctx.w or 0
    local h = ctx.h or 0
    local contentY = ctx.contentY or 0
    local contentH = ctx.contentH or 0
    local time = ctx.time or 0
    local PS = ctx.PS or function(v) return v end
    local UI = ctx.UI or function(v) return v end
    local stemColors = ctx.stemColors or {}
    local helpStartTime = ctx.helpStartTime or 0
    local updateAudioReactivity = ctx.updateAudioReactivity
    local audioReactive = ctx.audioReactive or {}
    local drawProceduralArtInternal = ctx.drawProceduralArtInternal
    local settings = resolveSettings(ctx)

    if settings.visualFX and type(drawProceduralArtInternal) == "function" then
        local artAreaY = UI(40)
        local artAreaH = h - artAreaY - UI(50)
        drawProceduralArtInternal(0, artAreaY, w, artAreaH, time * 0.6, 0, true, 0.22)
    end

    if type(updateAudioReactivity) == "function" then
        updateAudioReactivity()
    end

    local audioPeak = audioReactive.smoothPeakMono or 0
    local audioBass = audioReactive.smoothBass or 0
    local audioMid = audioReactive.smoothMid or 0
    local audioHigh = audioReactive.smoothHigh or 0
    local audioBeat = audioReactive.beatDecay or 0

    local bgTime = os.clock() - helpStartTime
    if settings.visualFX then
        local stepNums = {"1", "2", "3"}
        local numCount = 25 + math.floor(audioPeak * 10)
        for i = 1, numCount do
            local numIdx = ((i - 1) % 3) + 1
            local num = stepNums[numIdx]
            local floatPhase = bgTime * (0.8 + audioMid * 0.4) + i * 0.7
            local fx = w * (i / (numCount + 1)) + math.sin(floatPhase * 0.6 + i) * PS(40 + audioBass * 30)
            local fy = contentY + (contentH * 0.5) + math.cos(floatPhase * 0.4 + i * 0.5) * PS(80 + audioHigh * 40)

            local fsize = PS(30 + math.sin(floatPhase) * 15 + audioPeak * 20)
            gfx.setfont(1, "Arial", fsize, string.byte("b"))

            local falpha = 0.04 + math.sin(floatPhase * 2) * 0.02 + audioBeat * 0.08
            local col = stemColors[numIdx] or {1, 1, 1}
            gfx.set(col[1], col[2], col[3], math.min(0.25, falpha))

            local fw = gfx.measurestr(num)
            gfx.x = fx - fw / 2
            gfx.y = fy - fsize / 2
            gfx.drawstr(num)
        end

        for i = 1, 8 do
            local pathPhase = bgTime * (0.5 + audioMid * 0.3) + i * 0.9
            local dotCount = 12 + math.floor(audioPeak * 6)
            for dot = 1, dotCount do
                local dotPhase = pathPhase + dot * 0.2
                local dotX = w * 0.2 + (w * 0.6) * (dot / dotCount) + math.sin(dotPhase) * PS(20 + audioHigh * 15)
                local dotY = contentY + contentH * 0.3 + i * PS(30) + math.cos(dotPhase * 1.3) * PS(15 + audioBass * 20)

                local dotAlpha = 0.03 + math.sin(dotPhase * 3) * 0.015 + audioBeat * 0.04
                local colorIdx = ((dot - 1) % 3) + 1
                local dotSize = PS(2 + math.sin(dotPhase * 2) * 1 + audioPeak * 2)
                local col = stemColors[colorIdx] or {1, 1, 1}
                gfx.set(col[1], col[2], col[3], math.min(0.15, dotAlpha))
                gfx.circle(dotX, dotY, dotSize, 1, 1)
            end
        end

        if audioPeak > 0.05 then
            local waveY = contentY + contentH * 0.85
            local waveW = w * 0.8
            local waveX = w * 0.1
            local waveformSize = audioReactive.waveformSize or 60
            local waveformIndex = audioReactive.waveformIndex or 1
            local waveformHistory = audioReactive.waveformHistory
            for i = 0, 59 do
                local histIdx = (waveformIndex + i * 2) % waveformSize + 1
                local waveVal = (waveformHistory and waveformHistory[histIdx]) or audioPeak * 0.3
                local wx = waveX + (i / 60) * waveW
                local wh = waveVal * PS(30)
                local colorIdx = (math.floor(i / 15) % 3) + 1
                local col = stemColors[colorIdx] or {1, 1, 1}
                gfx.set(col[1], col[2], col[3], 0.1 + waveVal * 0.15)
                gfx.rect(wx, waveY - wh / 2, PS(4), wh, 1)
            end
        end
    end

    return {
        audioPeak = audioPeak,
        audioBass = audioBass,
        audioMid = audioMid,
        audioHigh = audioHigh,
        audioBeat = audioBeat,
    }
end

function M.drawStandardHelpBackground(ctx)
    if not ctx then
        return
    end

    local settings = resolveSettings(ctx)
    local UI = ctx.UI
    local drawProceduralArt = ctx.drawProceduralArt
    if not settings.visualFX or type(UI) ~= "function" or type(drawProceduralArt) ~= "function" then
        return
    end

    local w = ctx.w or 0
    local h = ctx.h or 0
    local time = ctx.time or 0
    local artAreaY = UI(40)
    local artAreaH = h - artAreaY - UI(50)
    drawProceduralArt(0, artAreaY, w, artAreaH, time, 0, true)
end

function M.handleStandardHelpBackgroundClick(ctx)
    if not ctx then
        return false
    end

    local mouseDown = ctx.mouseDown
    local wasMouseDown = ctx.wasMouseDown
    if mouseDown or not wasMouseDown then
        return false
    end

    local UI = ctx.UI or function(v) return v end
    local PS = ctx.PS or function(v) return v end
    local h = ctx.h or 0
    local mx = ctx.mx or 0
    local my = ctx.my or 0
    local startX = ctx.clickStartX or mx
    local startY = ctx.clickStartY or my

    local tabAreaBottom = UI(40)
    local closeBtnTop = h - UI(50)
    if startY <= tabAreaBottom or startY >= closeBtnTop then
        return false
    end

    local dx = mx - startX
    local dy = my - startY
    local dragThreshold = PS(6)
    if (dx * dx + dy * dy) > (dragThreshold * dragThreshold) then
        return false
    end

    local onGenerateArt = ctx.onGenerateArt
    if type(onGenerateArt) ~= "function" then
        return false
    end
    onGenerateArt()
    return true
end

return M
