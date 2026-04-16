-- STEMwerk_UI_Tokens.lua
-- Layout/style tokens only (no theme colors, no workflow/runtime behavior).

local TOKENS = {}

TOKENS.result = {
    spacing = {
        tooltipOffsetX = 10,
        tooltipOffsetY = 15,
        iconY = 60,
        iconRadius = 28,
        titleY = 100,
        stemRowY = 125,
        stemLabelGap = 5,
        stemItemGap = 16,
        hintBottom = 12,
        logoTop = 3,
    },
    padding = {
        messageBoxX = 20,
        messageBoxTop = 170,
        messageBoxHeight = 70,
        messageTextTop = 8,
        messageLineStep = 13,
        tooltipPadding = 8,
        tooltipLineHeight = 14,
        tooltipMaxTextW = 520,
    },
    button = {
        width = 70,
        height = 20,
        bottomOffset = 40,
    },
    sectionGaps = {
        controlsLeftPad = 60,
        controlsBottomPad = 30,
        langGap = 6,
        fxOffsetY = 3,
    },
    controls = {
        iconScale = 0.66,
        themeSizeMin = 12,
        themeSizeBase = 20,
        themeRight = 10,
        themeTop = 8,
        fxSizeMin = 10,
        fxSizeBase = 16,
        fxHitPad = 2,
        langWidth = 22,
        langHeight = 14,
    },
    fonts = {
        title = 18,
        stem = 11,
        message = 11,
        hint = 9,
        logo = 10,
        tooltip = 11,
        controls = 9,
        okButton = 13,
    },
}

return TOKENS
