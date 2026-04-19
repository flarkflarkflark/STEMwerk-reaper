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

TOKENS.about = {
    spacing = {
        tabAreaHeight = 40,
        artBottomReserve = 50,
        contentTop = 30,
        titleToSubtitleGap = 36,
        subtitleToFeaturesGap = 24,
        preFeaturesGap = 10,
        featuresTitleToListGap = 20,
        featureBulletGap = 10,
        featureRowGap = 16,
        featuresToCreditsGap = 20,
        creditsBottom = 18,
        hintLiftAboveBack = 22,
    },
    padding = {
        creditsLeft = 6,
        creditsRight = 12,
    },
    fonts = {
        title = 34,
        subtitle = 12,
        featuresTitle = 12,
        feature = 10,
        credits = 10,
    },
}

TOKENS.welcome = {
    spacing = {
        titleTop = 12,
        subtitleTop = 60,
        dividerTop = 85,
        dividerXStartFactor = 0.2,
        dividerXEndFactor = 0.8,
        featuresTop = 100,
        featureSpacing = 50,
        leftCol = 40,
        badgeOffsetX = 15,
        badgeOffsetY = 12,
        badgeRadius = 18,
        featureTextOffsetX = 45,
        featureDescOffsetY = 22,
    },
    fonts = {
        title = 44,
        subtitle = 16,
        featureTitle = 16,
        featureDesc = 13,
    },
}

TOKENS.helpLayout = {
    contentTop = 0,
    contentBottomReserve = 60,
    contentMaxWidth = 860,
    sidePadding = 36,
    titleFont = 27,
    subtitleFont = 13,
    titleTop = 12,
    subtitleGap = 32,
    bodyTopGap = 70,
    sectionGap = 14,
    bodyWrapWidth = 720,
    reaperBodyWrapWidth = 680,
    stemsBodyWrapWidth = 760,
    panelInnerPadding = 18,
}

return TOKENS
