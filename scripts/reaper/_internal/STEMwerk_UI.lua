-- STEMwerk_UI.lua
-- UI module: theme system (colors, presets, updateTheme) and theme helper functions.
-- Loaded via dofile() from STEMwerk.lua; populates globals directly — no configure() needed.
-- All dependencies (SETTINGS, LANG, THEME, T, saveSettings, updateTheme) are globals.
--
-- This is the primary file to edit for UI theme/color changes.
-- Draw primitive functions (drawButton, drawCheckbox, etc.) are in STEMwerk.lua for now.

UI = UI or {}
ACTIVE_THEME = ACTIVE_THEME or nil

-- ── Theme preset registry ──────────────────────────────────────────────────────

THEME_PRESET_ORDER = {"classic", "ember", "ice", "mono"}

THEME_PRESETS = {
    classic = {
        nameKey = "theme_classic",
        label = "Classic",
    },
    ember = {
        nameKey = "theme_ember",
        label = "Ember",
        dark = {
            accent = {0.75, 0.35, 0.25},
            accentHover = {0.85, 0.45, 0.35},
            checkboxChecked = {0.6, 0.35, 0.25},
            button = {0.55, 0.25, 0.2},
            buttonHover = {0.65, 0.35, 0.3},
            buttonPrimary = {0.5, 0.35, 0.2},
            buttonPrimaryHover = {0.6, 0.45, 0.3},
            bgGradientTop = {0.11, 0.09, 0.08},
            bgGradientBottom = {0.18, 0.14, 0.12},
        },
        light = {
            accent = {0.78, 0.34, 0.24},
            accentHover = {0.88, 0.44, 0.34},
            checkboxChecked = {0.76, 0.38, 0.28},
            button = {0.82, 0.42, 0.28},
            buttonHover = {0.9, 0.52, 0.38},
            buttonPrimary = {0.74, 0.40, 0.26},
            buttonPrimaryHover = {0.84, 0.5, 0.36},
            bgGradientTop = {0.99, 0.95, 0.92},
            bgGradientBottom = {0.93, 0.88, 0.84},
        },
    },
    ice = {
        nameKey = "theme_ice",
        label = "Ice",
        dark = {
            accent = {0.2, 0.65, 0.75},
            accentHover = {0.3, 0.75, 0.85},
            checkboxChecked = {0.2, 0.55, 0.65},
            button = {0.2, 0.5, 0.6},
            buttonHover = {0.3, 0.6, 0.7},
            buttonPrimary = {0.2, 0.55, 0.55},
            buttonPrimaryHover = {0.3, 0.65, 0.65},
            bgGradientTop = {0.08, 0.1, 0.12},
            bgGradientBottom = {0.14, 0.18, 0.2},
        },
        light = {
            accent = {0.14, 0.62, 0.78},
            accentHover = {0.24, 0.72, 0.88},
            checkboxChecked = {0.16, 0.60, 0.76},
            button = {0.16, 0.66, 0.82},
            buttonHover = {0.28, 0.76, 0.92},
            buttonPrimary = {0.14, 0.72, 0.70},
            buttonPrimaryHover = {0.26, 0.82, 0.80},
            bgGradientTop = {0.93, 0.98, 0.99},
            bgGradientBottom = {0.86, 0.93, 0.96},
        },
    },
    mono = {
        nameKey = "theme_mono",
        label = "Mono",
        dark = {
            accent = {0.55, 0.55, 0.6},
            accentHover = {0.65, 0.65, 0.7},
            checkboxChecked = {0.45, 0.45, 0.5},
            button = {0.35, 0.35, 0.4},
            buttonHover = {0.45, 0.45, 0.5},
            buttonPrimary = {0.4, 0.4, 0.45},
            buttonPrimaryHover = {0.5, 0.5, 0.55},
            bgGradientTop = {0.11, 0.11, 0.12},
            bgGradientBottom = {0.16, 0.16, 0.17},
        },
        light = {
            accent = {0.42, 0.42, 0.48},
            accentHover = {0.52, 0.52, 0.58},
            checkboxChecked = {0.46, 0.46, 0.52},
            button = {0.48, 0.48, 0.54},
            buttonHover = {0.58, 0.58, 0.64},
            buttonPrimary = {0.54, 0.54, 0.60},
            buttonPrimaryHover = {0.64, 0.64, 0.70},
            bgGradientTop = {0.96, 0.96, 0.97},
            bgGradientBottom = {0.90, 0.90, 0.92},
        },
    },
}

-- ── Theme helpers ──────────────────────────────────────────────────────────────

function normalizeThemePreset(preset)
    if type(preset) ~= "string" then
        return "classic"
    end
    if THEME_PRESETS[preset] then
        return preset
    end
    return "classic"
end

local function cloneColor(color)
    if type(color) ~= "table" then return color end
    return {color[1], color[2], color[3]}
end

local function avg3(c)
    return ((c and c[1] or 0) + (c and c[2] or 0) + (c and c[3] or 0)) / 3
end

local function shouldApplyThemeEditorOverrides()
    return reaper.GetExtState("STEMwerk", "THEME_USE_EXT_OVERRIDES") == "1"
end

local function resolveThemeSelection()
    local settingsDarkMode = true
    if SETTINGS and SETTINGS.darkMode ~= nil then
        settingsDarkMode = SETTINGS.darkMode
    end

    local resolved = {
        mode = settingsDarkMode and "dark" or "light",
        presetId = normalizeThemePreset(SETTINGS and SETTINGS.themePreset),
        overridesEnabled = shouldApplyThemeEditorOverrides(),
        settingsDarkMode = settingsDarkMode,
        editorDarkMode = nil,
    }

    if resolved.overridesEnabled then
        local extDarkMode = reaper.GetExtState("STEMwerk", "THEME_darkMode")
        if extDarkMode == "1" then
            resolved.mode = "dark"
            resolved.editorDarkMode = true
        elseif extDarkMode == "0" then
            resolved.mode = "light"
            resolved.editorDarkMode = false
        end
    end

    return resolved
end

local function buildBaseLegacyPalette(mode)
    if mode == "dark" then
        return {
            bg = {0.18, 0.18, 0.2},
            bgGradientTop = {0.1, 0.1, 0.12},
            bgGradientBottom = {0.18, 0.18, 0.2},
            inputBg = {0.12, 0.12, 0.14},
            text = {1, 1, 1},
            textDim = {0.7, 0.7, 0.7},
            textHint = {0.5, 0.5, 0.5},
            accent = {0.3, 0.5, 0.8},
            accentHover = {0.4, 0.6, 0.9},
            checkbox = {0.3, 0.3, 0.3},
            checkboxChecked = {0.3, 0.5, 0.7},
            button = {0.2, 0.4, 0.7},
            buttonHover = {0.3, 0.5, 0.8},
            buttonPrimary = {0.2, 0.5, 0.3},
            buttonPrimaryHover = {0.3, 0.6, 0.4},
            border = {0.6, 0.6, 0.6},
        }
    end

    return {
        bg = {0.92, 0.92, 0.94},
        bgGradientTop = {0.96, 0.96, 0.98},
        bgGradientBottom = {0.88, 0.88, 0.9},
        inputBg = {0.85, 0.85, 0.87},
        text = {0.1, 0.1, 0.1},
        textDim = {0.3, 0.3, 0.3},
        textHint = {0.5, 0.5, 0.5},
        accent = {0.2, 0.4, 0.7},
        accentHover = {0.3, 0.5, 0.8},
        checkbox = {0.8, 0.8, 0.8},
        checkboxChecked = {0.3, 0.5, 0.7},
        button = {0.3, 0.5, 0.75},
        buttonHover = {0.4, 0.6, 0.85},
        buttonPrimary = {0.25, 0.55, 0.35},
        buttonPrimaryHover = {0.35, 0.65, 0.45},
        border = {0.4, 0.4, 0.4},
    }
end

local function applyThemePreset(themeTable, mode, presetId)
  local resolvedPresetId = normalizeThemePreset(presetId)
  local preset = THEME_PRESETS[resolvedPresetId]
  if not preset then
      return themeTable
  end
  local overrides = (mode == "dark") and preset.dark or preset.light
  if overrides then
        for key, value in pairs(overrides) do
            themeTable[key] = value
        end
    end
    return themeTable
end

local function applyThemeEditorOverrides(legacyTheme, selection)
    local extPrefix = "THEME_"
    local applied = {}

    if not selection.overridesEnabled then
        return applied
    end

    local keys = {"text", "accent", "button", "buttonPrimary", "bg"}
    for _, key in ipairs(keys) do
        local val = reaper.GetExtState("STEMwerk", extPrefix .. key)
        if val and val ~= "" then
            local r, g, b = val:match("([^,]+),([^,]+),([^,]+)")
            if r and g and b then
                local color = {tonumber(r), tonumber(g), tonumber(b)}
                legacyTheme[key] = color
                applied[key] = cloneColor(color)
                if key == "accent" then
                    legacyTheme.accentHover = {math.min(1, color[1] + 0.1), math.min(1, color[2] + 0.1), math.min(1, color[3] + 0.1)}
                    legacyTheme.checkboxChecked = cloneColor(color)
                end
                if key == "button" then
                    legacyTheme.buttonHover = {math.min(1, color[1] + 0.1), math.min(1, color[2] + 0.1), math.min(1, color[3] + 0.1)}
                end
                if key == "bg" then
                    legacyTheme.bgGradientTop = {math.max(0, color[1] - 0.05), math.max(0, color[2] - 0.05), math.max(0, color[3] - 0.05)}
                    legacyTheme.bgGradientBottom = cloneColor(color)
                end
            end
        end
    end

    return applied
end

local function applyContrastSafetyNet(legacyTheme, mode)
    if mode == "dark" then
        if avg3(legacyTheme.text) < 0.75 then legacyTheme.text = {0.94, 0.94, 0.96} end
        if avg3(legacyTheme.textDim) < 0.55 then legacyTheme.textDim = {0.74, 0.74, 0.78} end
        if avg3(legacyTheme.textHint) < 0.4 then legacyTheme.textHint = {0.60, 0.60, 0.64} end
        if avg3(legacyTheme.border) < 0.35 then legacyTheme.border = {0.52, 0.52, 0.56} end
    else
        if avg3(legacyTheme.text) > 0.35 then legacyTheme.text = {0.10, 0.10, 0.12} end
        if avg3(legacyTheme.textDim) > 0.45 then legacyTheme.textDim = {0.26, 0.26, 0.30} end
        if avg3(legacyTheme.textHint) > 0.55 then legacyTheme.textHint = {0.38, 0.38, 0.44} end
        if avg3(legacyTheme.border) > 0.65 then legacyTheme.border = {0.42, 0.42, 0.46} end
        if avg3(legacyTheme.inputBg) > 0.95 then legacyTheme.inputBg = {0.94, 0.94, 0.96} end
    end
end

local function deriveSemanticTheme(legacyTheme, selection, editorOverrides)
    local panelBg = cloneColor(legacyTheme.bg)
    local panelAltBg = cloneColor(legacyTheme.bgGradientBottom)
    local cardBg = cloneColor(legacyTheme.inputBg)
    local accent = cloneColor(legacyTheme.accent)
    local accentHover = cloneColor(legacyTheme.accentHover)
    local border = cloneColor(legacyTheme.border)
    local textPrimary = cloneColor(legacyTheme.text)
    local textSecondary = cloneColor(legacyTheme.textDim)
    local textMuted = cloneColor(legacyTheme.textHint)
    local buttonBg = cloneColor(legacyTheme.button)
    local buttonHoverBg = cloneColor(legacyTheme.buttonHover)
    local primaryButtonBg = cloneColor(legacyTheme.buttonPrimary)
    local primaryButtonHoverBg = cloneColor(legacyTheme.buttonPrimaryHover)
    local checkboxBg = cloneColor(legacyTheme.checkbox)
    local checkboxCheckedBg = cloneColor(legacyTheme.checkboxChecked)

    return {
        meta = {
            mode = selection.mode,
            presetId = selection.presetId,
            preset = selection.presetId,
            overridesEnabled = selection.overridesEnabled,
            source = {
                mode = selection.editorDarkMode == nil and "settings" or "editor",
                preset = "settings",
                overrides = selection.overridesEnabled and "editor" or "none",
            },
        },
        colors = {
            appBg = cloneColor(legacyTheme.bg),
            panelBg = panelBg,
            panelAltBg = panelAltBg,
            cardBg = cardBg,
            buttonBg = buttonBg,
            buttonHoverBg = buttonHoverBg,
            buttonPrimaryBg = primaryButtonBg,
            buttonPrimaryHoverBg = primaryButtonHoverBg,
            buttonText = textPrimary,
            accent = accent,
            accentHover = accentHover,
            border = border,
            textPrimary = textPrimary,
            textSecondary = textSecondary,
            textMuted = textMuted,
            tooltipBg = cloneColor(cardBg),
            tooltipBorder = cloneColor(border),
            tooltipText = cloneColor(textPrimary),
            iconPrimary = cloneColor(textPrimary),
            iconMuted = cloneColor(textMuted),
            success = cloneColor(primaryButtonBg),
            warning = cloneColor(accent),
            checkboxBg = checkboxBg,
            checkboxCheckedBg = checkboxCheckedBg,
            bgGradientTop = cloneColor(legacyTheme.bgGradientTop),
            bgGradientBottom = cloneColor(legacyTheme.bgGradientBottom),
        },
        style = {
            cornerRadius = 0,
            borderWeight = 1,
            layoutDensity = "normal",
            fxIntensity = (SETTINGS and SETTINGS.visualFX) and 1 or 0,
            shadowStrength = 0,
        },
        derived = {
            contrastMode = selection.mode,
            legacyShape = "v1",
        },
        overrides = {
            darkMode = selection.editorDarkMode,
            colors = editorOverrides,
        },
    }
end

local function buildLegacyThemeFromSemantic(activeTheme)
    local colors = (activeTheme and activeTheme.colors) or {}
    return {
        bg = cloneColor(colors.appBg),
        bgGradientTop = cloneColor(colors.bgGradientTop),
        bgGradientBottom = cloneColor(colors.bgGradientBottom),
        inputBg = cloneColor(colors.cardBg),
        text = cloneColor(colors.textPrimary),
        textDim = cloneColor(colors.textSecondary),
        textHint = cloneColor(colors.textMuted),
        accent = cloneColor(colors.accent),
        accentHover = cloneColor(colors.accentHover),
        checkbox = cloneColor(colors.checkboxBg),
        checkboxChecked = cloneColor(colors.checkboxCheckedBg),
        button = cloneColor(colors.buttonBg),
        buttonHover = cloneColor(colors.buttonHoverBg),
        buttonPrimary = cloneColor(colors.buttonPrimaryBg),
        buttonPrimaryHover = cloneColor(colors.buttonPrimaryHoverBg),
        border = cloneColor(colors.border),
    }
end

local function applyStemBorderOverrides()
    if not STEM_BORDER_COLORS then
        return
    end

    local extPrefix = "THEME_"
    local stems = {"vocals", "drums", "bass", "other"}
    for i, stemName in ipairs(stems) do
        local val = reaper.GetExtState("STEMwerk", extPrefix .. stemName)
        if val and val ~= "" then
            local r, g, b = val:match("([^,]+),([^,]+),([^,]+)")
            if r and g and b then
                STEM_BORDER_COLORS[i] = {tonumber(r) * 255, tonumber(g) * 255, tonumber(b) * 255}
            end
        end
    end
end

function updateTheme()
  local selection = resolveThemeSelection()
  local legacyTheme = buildBaseLegacyPalette(selection.mode)
  applyThemePreset(legacyTheme, selection.mode, selection.presetId)
  local editorOverrides = applyThemeEditorOverrides(legacyTheme, selection)
  applyContrastSafetyNet(legacyTheme, selection.mode)

  ACTIVE_THEME = deriveSemanticTheme(legacyTheme, selection, editorOverrides)
  ACTIVE_THEME.legacy = buildLegacyThemeFromSemantic(ACTIVE_THEME)
  THEME = ACTIVE_THEME.legacy

  applyStemBorderOverrides()
end

-- ── Theme UI helpers ───────────────────────────────────────────────────────────

function getThemePresetLabel()
    local presetId = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
    local preset = THEME_PRESETS[presetId] or THEME_PRESETS.classic
    local key = preset and preset.nameKey
    if LANG and key and LANG[key] then
        return LANG[key]
    end
    return preset and preset.label or presetId
end

function getLangText(key, fallback)
    if LANG and LANG[key] then
        return LANG[key]
    end
    return fallback or key:gsub("_", " ")
end

function getThemeToggleTooltip()
    local switchTip = SETTINGS.darkMode and T("switch_light") or T("switch_dark")
    local presetLabel = getLangText("theme_preset", "Theme")
    local presetName = getThemePresetLabel()
    local cycleHint = getLangText("tooltip_theme_cycle", "Right-click to cycle preset")
    return string.format("%s  %s: %s (%s)", switchTip, presetLabel, presetName, cycleHint)
end

function cycleThemePreset()
    local current = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
    local idx = 1
    for i, presetId in ipairs(THEME_PRESET_ORDER) do
        if presetId == current then
            idx = i
            break
        end
    end
    local nextId = THEME_PRESET_ORDER[(idx % #THEME_PRESET_ORDER) + 1]
    SETTINGS.themePreset = nextId
    updateTheme()
    saveSettings()
end
