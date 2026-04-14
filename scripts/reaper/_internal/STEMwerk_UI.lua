-- STEMwerk_UI.lua
-- UI module: theme system (colors, presets, updateTheme) and theme helper functions.
-- Loaded via dofile() from STEMwerk.lua; populates globals directly — no configure() needed.
-- All dependencies (SETTINGS, LANG, THEME, T, saveSettings, updateTheme) are globals.
--
-- This is the primary file to edit for UI theme/color changes.
-- Draw primitive functions (drawButton, drawCheckbox, etc.) are in STEMwerk.lua for now.

UI = UI or {}

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

function applyThemePreset(themeTable, darkMode)
  local presetId = normalizeThemePreset(SETTINGS and SETTINGS.themePreset)
  local preset = THEME_PRESETS[presetId]
  if not preset then
      return themeTable
  end
  local overrides = darkMode and preset.dark or preset.light
    if overrides then
        for key, value in pairs(overrides) do
            themeTable[key] = value
        end
    end
    return themeTable
end

-- ── Base colors (dark / light) + preset overlay ───────────────────────────────
-- Edit these values to change the look of STEMwerk's UI.
-- Keys used by draw functions: bg, bgGradientTop, bgGradientBottom, inputBg,
--   text, textDim, textHint, accent, accentHover, checkbox, checkboxChecked,
--   button, buttonHover, buttonPrimary, buttonPrimaryHover, border.

local function shouldApplyThemeEditorOverrides()
    return reaper.GetExtState("STEMwerk", "THEME_USE_EXT_OVERRIDES") == "1"
end

local function avg3(c)
    return ((c and c[1] or 0) + (c and c[2] or 0) + (c and c[3] or 0)) / 3
end

function updateTheme()
  local darkMode = true
  if SETTINGS and SETTINGS.darkMode ~= nil then
      darkMode = SETTINGS.darkMode
  end

  local useThemeEditorOverrides = shouldApplyThemeEditorOverrides()
  if useThemeEditorOverrides then
      local extDarkMode = reaper.GetExtState("STEMwerk", "THEME_darkMode")
      if extDarkMode == "1" then darkMode = true
      elseif extDarkMode == "0" then darkMode = false end
  end

  if darkMode then
        THEME = {
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
    else
        -- Light theme base colors
        THEME = {
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
    applyThemePreset(THEME, darkMode)

    local ext_prefix = "THEME_"

    -- Optional Theme Editor overrides (disabled unless explicitly enabled)
    if useThemeEditorOverrides then
        local keys = {
            "text", "accent", "button", "buttonPrimary", "bg"
        }
        for _, k in ipairs(keys) do
            local val = reaper.GetExtState("STEMwerk", ext_prefix .. k)
            if val and val ~= "" then
                local r, g, b = val:match("([^,]+),([^,]+),([^,]+)")
                if r and g and b then
                    THEME[k] = {tonumber(r), tonumber(g), tonumber(b)}
                    if k == "accent" then
                        THEME.accentHover = {math.min(1, THEME[k][1]+0.1), math.min(1, THEME[k][2]+0.1), math.min(1, THEME[k][3]+0.1)}
                        THEME.checkboxChecked = THEME[k]
                    end
                    if k == "button" then
                        THEME.buttonHover = {math.min(1, THEME[k][1]+0.1), math.min(1, THEME[k][2]+0.1), math.min(1, THEME[k][3]+0.1)}
                    end
                    if k == "bg" then
                        THEME.bgGradientTop = {math.max(0, THEME[k][1]-0.05), math.max(0, THEME[k][2]-0.05), math.max(0, THEME[k][3]-0.05)}
                        THEME.bgGradientBottom = THEME[k]
                    end
                end
            end
        end
    end

    -- Contrast/readability safety net
    if darkMode then
        if avg3(THEME.text) < 0.75 then THEME.text = {0.94, 0.94, 0.96} end
        if avg3(THEME.textDim) < 0.55 then THEME.textDim = {0.74, 0.74, 0.78} end
        if avg3(THEME.textHint) < 0.4 then THEME.textHint = {0.60, 0.60, 0.64} end
        if avg3(THEME.border) < 0.35 then THEME.border = {0.52, 0.52, 0.56} end
    else
        if avg3(THEME.text) > 0.35 then THEME.text = {0.10, 0.10, 0.12} end
        if avg3(THEME.textDim) > 0.45 then THEME.textDim = {0.26, 0.26, 0.30} end
        if avg3(THEME.textHint) > 0.55 then THEME.textHint = {0.38, 0.38, 0.44} end
        if avg3(THEME.border) > 0.65 then THEME.border = {0.42, 0.42, 0.46} end
        if avg3(THEME.inputBg) > 0.95 then THEME.inputBg = {0.94, 0.94, 0.96} end
    end

    -- Override STEM Stem colors (the rainbow border)
    if STEM_BORDER_COLORS then
        local stems = {"vocals", "drums", "bass", "other"}
        for i, s in ipairs(stems) do
            local val = reaper.GetExtState("STEMwerk", ext_prefix .. s)
            if val and val ~= "" then
                local r, g, b = val:match("([^,]+),([^,]+),([^,]+)")
                if r and g and b then
                    STEM_BORDER_COLORS[i] = {tonumber(r)*255, tonumber(g)*255, tonumber(b)*255}
                end
            end
        end
    end
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
