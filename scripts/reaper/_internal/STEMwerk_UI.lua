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

THEME_PRESET_ORDER = {"classic", "ember", "ice", "mono", "studio", "aurora", "copper", "reaper_native"}

THEME_PRESETS = {
    classic = {
        nameKey = "theme_classic",
        label = "Classic",
        dark = {
            bg = {0.18, 0.18, 0.20},
            bgGradientTop = {0.10, 0.10, 0.12},
            bgGradientBottom = {0.18, 0.18, 0.20},
            inputBg = {0.12, 0.12, 0.14},
            semantic = {
                panelBg = {0.18, 0.19, 0.21},
                panelAltBg = {0.18, 0.18, 0.20},
                cardBg = {0.12, 0.12, 0.14},
                border = {0.56, 0.56, 0.60},
                textSecondary = {0.72, 0.72, 0.76},
                textMuted = {0.56, 0.56, 0.60},
                iconPrimary = {0.92, 0.92, 0.95},
                iconMuted = {0.58, 0.58, 0.62},
            },
            style = {
                cornerRadius = 6,
                glossStrength = 0.55,
            },
        },
        light = {
            bg = {0.92, 0.92, 0.94},
            bgGradientTop = {0.96, 0.96, 0.98},
            bgGradientBottom = {0.88, 0.88, 0.90},
            inputBg = {0.85, 0.85, 0.87},
            semantic = {
                panelBg = {0.92, 0.92, 0.94},
                panelAltBg = {0.88, 0.88, 0.90},
                cardBg = {0.85, 0.85, 0.87},
                border = {0.40, 0.40, 0.44},
                textSecondary = {0.29, 0.29, 0.33},
                textMuted = {0.42, 0.42, 0.46},
                iconPrimary = {0.12, 0.12, 0.14},
                iconMuted = {0.44, 0.44, 0.48},
            },
            style = {
                cornerRadius = 6,
                shadowStrength = 0.08,
                glossStrength = 0.50,
            },
        },
    },
    ember = {
        nameKey = "theme_ember",
        label = "Ember",
        dark = {
            bg = {0.17, 0.14, 0.12},
            accent = {0.75, 0.35, 0.25},
            accentHover = {0.85, 0.45, 0.35},
            checkboxChecked = {0.6, 0.35, 0.25},
            button = {0.55, 0.25, 0.2},
            buttonHover = {0.65, 0.35, 0.3},
            buttonPrimary = {0.5, 0.35, 0.2},
            buttonPrimaryHover = {0.6, 0.45, 0.3},
            bgGradientTop = {0.11, 0.10, 0.09},
            bgGradientBottom = {0.18, 0.15, 0.13},
            inputBg = {0.13, 0.10, 0.09},
            semantic = {
                panelBg = {0.17, 0.11, 0.09},
                panelAltBg = {0.18, 0.14, 0.12},
                cardBg = {0.13, 0.08, 0.07},
                border = {0.66, 0.42, 0.30},
                textSecondary = {0.80, 0.66, 0.55},
                textMuted = {0.62, 0.48, 0.37},
                iconPrimary = {0.95, 0.74, 0.53},
                iconMuted = {0.70, 0.51, 0.39},
            },
            style = {
                cornerRadius = 8,
                glossStrength = 0.74,
            },
        },
        light = {
            bg = {0.94, 0.90, 0.87},
            accent = {0.78, 0.34, 0.24},
            accentHover = {0.88, 0.44, 0.34},
            checkboxChecked = {0.76, 0.38, 0.28},
            button = {0.82, 0.42, 0.28},
            buttonHover = {0.9, 0.52, 0.38},
            buttonPrimary = {0.74, 0.40, 0.26},
            buttonPrimaryHover = {0.84, 0.5, 0.36},
            bgGradientTop = {0.99, 0.96, 0.94},
            bgGradientBottom = {0.93, 0.89, 0.86},
            inputBg = {0.88, 0.82, 0.78},
            semantic = {
                panelBg = {0.95, 0.89, 0.84},
                panelAltBg = {0.93, 0.88, 0.84},
                cardBg = {0.87, 0.79, 0.72},
                border = {0.69, 0.43, 0.30},
                textSecondary = {0.44, 0.28, 0.20},
                textMuted = {0.57, 0.39, 0.30},
                iconPrimary = {0.70, 0.35, 0.20},
                iconMuted = {0.58, 0.40, 0.30},
            },
            style = {
                cornerRadius = 8,
                shadowStrength = 0.10,
                glossStrength = 0.72,
            },
        },
    },
    ice = {
        nameKey = "theme_ice",
        label = "Ice",
        dark = {
            bg = {0.12, 0.15, 0.19},
            accent = {0.2, 0.65, 0.75},
            accentHover = {0.3, 0.75, 0.85},
            checkboxChecked = {0.2, 0.55, 0.65},
            button = {0.2, 0.5, 0.6},
            buttonHover = {0.3, 0.6, 0.7},
            buttonPrimary = {0.2, 0.55, 0.55},
            buttonPrimaryHover = {0.3, 0.65, 0.65},
            bgGradientTop = {0.07, 0.10, 0.13},
            bgGradientBottom = {0.13, 0.17, 0.21},
            inputBg = {0.10, 0.15, 0.20},
            semantic = {
                panelBg = {0.10, 0.14, 0.17},
                panelAltBg = {0.14, 0.18, 0.20},
                cardBg = {0.09, 0.16, 0.20},
                border = {0.33, 0.63, 0.73},
                textSecondary = {0.66, 0.84, 0.90},
                textMuted = {0.47, 0.70, 0.78},
                iconPrimary = {0.71, 0.93, 0.98},
                iconMuted = {0.49, 0.72, 0.79},
            },
            style = {
                cornerRadius = 7,
                glossStrength = 0.80,
            },
        },
        light = {
            bg = {0.90, 0.95, 0.98},
            accent = {0.14, 0.62, 0.78},
            accentHover = {0.24, 0.72, 0.88},
            checkboxChecked = {0.16, 0.60, 0.76},
            button = {0.16, 0.66, 0.82},
            buttonHover = {0.28, 0.76, 0.92},
            buttonPrimary = {0.14, 0.72, 0.70},
            buttonPrimaryHover = {0.26, 0.82, 0.80},
            bgGradientTop = {0.94, 0.98, 1.00},
            bgGradientBottom = {0.84, 0.92, 0.96},
            inputBg = {0.82, 0.91, 0.95},
            semantic = {
                panelBg = {0.89, 0.96, 0.98},
                panelAltBg = {0.86, 0.93, 0.96},
                cardBg = {0.80, 0.91, 0.95},
                border = {0.27, 0.61, 0.72},
                textSecondary = {0.20, 0.39, 0.45},
                textMuted = {0.31, 0.56, 0.63},
                iconPrimary = {0.11, 0.61, 0.73},
                iconMuted = {0.30, 0.55, 0.63},
            },
            style = {
                cornerRadius = 7,
                shadowStrength = 0.09,
                glossStrength = 0.78,
            },
        },
    },
    mono = {
        nameKey = "theme_mono",
        label = "Mono",
        dark = {
            bg = {0.16, 0.16, 0.17},
            accent = {0.55, 0.55, 0.6},
            accentHover = {0.65, 0.65, 0.7},
            checkboxChecked = {0.45, 0.45, 0.5},
            button = {0.35, 0.35, 0.4},
            buttonHover = {0.45, 0.45, 0.5},
            buttonPrimary = {0.4, 0.4, 0.45},
            buttonPrimaryHover = {0.5, 0.5, 0.55},
            bgGradientTop = {0.11, 0.11, 0.12},
            bgGradientBottom = {0.16, 0.16, 0.17},
            inputBg = {0.11, 0.11, 0.12},
            semantic = {
                panelBg = {0.13, 0.13, 0.14},
                panelAltBg = {0.16, 0.16, 0.17},
                cardBg = {0.11, 0.11, 0.12},
                border = {0.52, 0.52, 0.55},
                textSecondary = {0.73, 0.73, 0.76},
                textMuted = {0.58, 0.58, 0.61},
                iconPrimary = {0.86, 0.86, 0.89},
                iconMuted = {0.60, 0.60, 0.63},
            },
            style = {
                glossStrength = 0.18,
            },
        },
        light = {
            bg = {0.91, 0.91, 0.93},
            accent = {0.42, 0.42, 0.48},
            accentHover = {0.52, 0.52, 0.58},
            checkboxChecked = {0.46, 0.46, 0.52},
            button = {0.48, 0.48, 0.54},
            buttonHover = {0.58, 0.58, 0.64},
            buttonPrimary = {0.54, 0.54, 0.60},
            buttonPrimaryHover = {0.64, 0.64, 0.70},
            bgGradientTop = {0.96, 0.96, 0.97},
            bgGradientBottom = {0.90, 0.90, 0.92},
            inputBg = {0.88, 0.88, 0.90},
            semantic = {
                panelBg = {0.95, 0.95, 0.96},
                panelAltBg = {0.90, 0.90, 0.92},
                cardBg = {0.88, 0.88, 0.90},
                border = {0.43, 0.43, 0.46},
                textSecondary = {0.29, 0.29, 0.32},
                textMuted = {0.42, 0.42, 0.46},
                iconPrimary = {0.16, 0.16, 0.18},
                iconMuted = {0.41, 0.41, 0.45},
            },
            style = {
                shadowStrength = 0.05,
                glossStrength = 0.16,
            },
        },
    },
    studio = {
        nameKey = "theme_studio",
        label = "Studio",
        dark = {
            bg = {0.15, 0.17, 0.19},
            bgGradientTop = {0.10, 0.12, 0.13},
            bgGradientBottom = {0.14, 0.16, 0.18},
            inputBg = {0.12, 0.14, 0.16},
            text = {0.94, 0.95, 0.96},
            textDim = {0.64, 0.67, 0.70},
            textHint = {0.47, 0.50, 0.54},
            accent = {0.44, 0.56, 0.70},
            accentHover = {0.52, 0.64, 0.78},
            checkbox = {0.28, 0.30, 0.33},
            checkboxChecked = {0.38, 0.50, 0.63},
            button = {0.23, 0.29, 0.38},
            buttonHover = {0.29, 0.35, 0.45},
            buttonPrimary = {0.26, 0.37, 0.33},
            buttonPrimaryHover = {0.32, 0.44, 0.39},
            border = {0.39, 0.42, 0.46},
            semantic = {
                panelBg = {0.12, 0.13, 0.15},
                panelAltBg = {0.15, 0.16, 0.18},
                cardBg = {0.10, 0.11, 0.13},
                border = {0.39, 0.42, 0.46},
                textSecondary = {0.64, 0.67, 0.70},
                textMuted = {0.47, 0.50, 0.54},
                tooltipBg = {0.10, 0.11, 0.12},
                tooltipBorder = {0.47, 0.50, 0.54},
                tooltipText = {0.94, 0.95, 0.96},
                iconPrimary = {0.68, 0.72, 0.77},
                iconMuted = {0.44, 0.47, 0.51},
                buttonText = {0.93, 0.94, 0.95},
                success = {0.38, 0.58, 0.47},
                warning = {0.74, 0.60, 0.34},
            },
            style = {
                cornerRadius = 3,
                borderWeight = 1,
                fxIntensity = 0.88,
                shadowStrength = 0.03,
                glossStrength = 0.10,
            },
        },
        light = {
            bg = {0.90, 0.92, 0.94},
            bgGradientTop = {0.95, 0.97, 0.98},
            bgGradientBottom = {0.87, 0.89, 0.92},
            inputBg = {0.85, 0.87, 0.89},
            text = {0.11, 0.12, 0.13},
            textDim = {0.34, 0.36, 0.39},
            textHint = {0.47, 0.49, 0.53},
            accent = {0.37, 0.49, 0.63},
            accentHover = {0.45, 0.57, 0.71},
            checkbox = {0.79, 0.80, 0.82},
            checkboxChecked = {0.39, 0.51, 0.64},
            button = {0.50, 0.58, 0.68},
            buttonHover = {0.58, 0.66, 0.76},
            buttonPrimary = {0.42, 0.58, 0.52},
            buttonPrimaryHover = {0.50, 0.66, 0.60},
            border = {0.41, 0.43, 0.47},
            semantic = {
                panelBg = {0.88, 0.89, 0.91},
                panelAltBg = {0.85, 0.86, 0.88},
                cardBg = {0.84, 0.85, 0.87},
                border = {0.41, 0.43, 0.47},
                textSecondary = {0.34, 0.36, 0.39},
                textMuted = {0.47, 0.49, 0.53},
                tooltipBg = {0.88, 0.89, 0.91},
                tooltipBorder = {0.44, 0.46, 0.49},
                tooltipText = {0.11, 0.12, 0.13},
                iconPrimary = {0.29, 0.34, 0.39},
                iconMuted = {0.43, 0.46, 0.50},
                buttonText = {0.11, 0.12, 0.13},
                success = {0.36, 0.56, 0.46},
                warning = {0.73, 0.56, 0.28},
            },
            style = {
                cornerRadius = 3,
                borderWeight = 1,
                fxIntensity = 0.84,
                shadowStrength = 0.08,
                glossStrength = 0.10,
            },
        },
    },
    aurora = {
        nameKey = "theme_aurora",
        label = "Aurora",
        dark = {
            bg = {0.09, 0.15, 0.18},
            bgGradientTop = {0.05, 0.11, 0.12},
            bgGradientBottom = {0.10, 0.18, 0.20},
            inputBg = {0.07, 0.16, 0.19},
            text = {0.92, 0.98, 0.99},
            textDim = {0.62, 0.80, 0.84},
            textHint = {0.41, 0.66, 0.72},
            accent = {0.21, 0.75, 0.82},
            accentHover = {0.33, 0.87, 0.92},
            checkbox = {0.16, 0.24, 0.27},
            checkboxChecked = {0.19, 0.63, 0.69},
            button = {0.13, 0.39, 0.48},
            buttonHover = {0.20, 0.50, 0.59},
            buttonPrimary = {0.12, 0.53, 0.48},
            buttonPrimaryHover = {0.19, 0.66, 0.60},
            border = {0.25, 0.60, 0.67},
            semantic = {
                panelBg = {0.07, 0.12, 0.15},
                panelAltBg = {0.10, 0.18, 0.21},
                cardBg = {0.05, 0.14, 0.17},
                border = {0.25, 0.60, 0.67},
                textSecondary = {0.62, 0.80, 0.84},
                textMuted = {0.41, 0.66, 0.72},
                tooltipBg = {0.07, 0.12, 0.15},
                tooltipBorder = {0.30, 0.71, 0.75},
                tooltipText = {0.93, 0.98, 0.99},
                iconPrimary = {0.54, 0.91, 0.96},
                iconMuted = {0.37, 0.66, 0.72},
                buttonText = {0.93, 0.98, 0.99},
                success = {0.20, 0.72, 0.62},
                warning = {0.63, 0.86, 0.44},
            },
            style = {
                cornerRadius = 14,
                borderWeight = 2,
                fxIntensity = 1.10,
                shadowStrength = 0.18,
                glossStrength = 1.25,
            },
        },
        light = {
            bg = {0.89, 0.96, 0.97},
            bgGradientTop = {0.94, 0.99, 0.99},
            bgGradientBottom = {0.83, 0.94, 0.96},
            inputBg = {0.81, 0.93, 0.95},
            text = {0.08, 0.16, 0.18},
            textDim = {0.22, 0.40, 0.45},
            textHint = {0.34, 0.56, 0.61},
            accent = {0.13, 0.63, 0.74},
            accentHover = {0.23, 0.75, 0.84},
            checkbox = {0.78, 0.89, 0.91},
            checkboxChecked = {0.16, 0.60, 0.70},
            button = {0.22, 0.68, 0.79},
            buttonHover = {0.32, 0.78, 0.89},
            buttonPrimary = {0.18, 0.73, 0.63},
            buttonPrimaryHover = {0.28, 0.83, 0.73},
            border = {0.23, 0.61, 0.68},
            semantic = {
                panelBg = {0.87, 0.95, 0.97},
                panelAltBg = {0.81, 0.92, 0.95},
                cardBg = {0.79, 0.91, 0.95},
                border = {0.23, 0.61, 0.68},
                textSecondary = {0.22, 0.40, 0.45},
                textMuted = {0.34, 0.56, 0.61},
                tooltipBg = {0.90, 0.97, 0.98},
                tooltipBorder = {0.24, 0.64, 0.69},
                tooltipText = {0.08, 0.16, 0.18},
                iconPrimary = {0.10, 0.62, 0.72},
                iconMuted = {0.29, 0.56, 0.61},
                buttonText = {0.08, 0.16, 0.18},
                success = {0.20, 0.69, 0.58},
                warning = {0.58, 0.74, 0.32},
            },
            style = {
                cornerRadius = 14,
                borderWeight = 2,
                fxIntensity = 1.02,
                shadowStrength = 0.18,
                glossStrength = 1.20,
            },
        },
    },
    copper = {
        nameKey = "theme_copper",
        label = "Copper",
        dark = {
            bg = {0.19, 0.13, 0.10},
            bgGradientTop = {0.11, 0.08, 0.06},
            bgGradientBottom = {0.21, 0.15, 0.11},
            inputBg = {0.17, 0.11, 0.08},
            text = {0.98, 0.94, 0.90},
            textDim = {0.82, 0.69, 0.56},
            textHint = {0.64, 0.49, 0.34},
            accent = {0.82, 0.49, 0.28},
            accentHover = {0.92, 0.59, 0.36},
            checkbox = {0.34, 0.22, 0.17},
            checkboxChecked = {0.72, 0.42, 0.24},
            button = {0.47, 0.24, 0.17},
            buttonHover = {0.58, 0.32, 0.22},
            buttonPrimary = {0.58, 0.34, 0.19},
            buttonPrimaryHover = {0.69, 0.43, 0.27},
            border = {0.73, 0.45, 0.24},
            semantic = {
                panelBg = {0.16, 0.11, 0.08},
                panelAltBg = {0.22, 0.15, 0.10},
                cardBg = {0.14, 0.09, 0.06},
                border = {0.73, 0.45, 0.24},
                textSecondary = {0.82, 0.69, 0.56},
                textMuted = {0.64, 0.49, 0.34},
                tooltipBg = {0.13, 0.09, 0.07},
                tooltipBorder = {0.76, 0.49, 0.30},
                tooltipText = {0.98, 0.94, 0.90},
                iconPrimary = {0.92, 0.67, 0.39},
                iconMuted = {0.69, 0.49, 0.32},
                buttonText = {0.99, 0.95, 0.91},
                success = {0.73, 0.45, 0.23},
                warning = {0.95, 0.68, 0.32},
            },
            style = {
                cornerRadius = 9,
                borderWeight = 2,
                fxIntensity = 0.95,
                shadowStrength = 0.12,
                glossStrength = 0.82,
            },
        },
        light = {
            bg = {0.95, 0.89, 0.84},
            bgGradientTop = {0.99, 0.95, 0.91},
            bgGradientBottom = {0.90, 0.82, 0.76},
            inputBg = {0.89, 0.81, 0.75},
            text = {0.16, 0.10, 0.08},
            textDim = {0.42, 0.27, 0.18},
            textHint = {0.55, 0.37, 0.24},
            accent = {0.74, 0.42, 0.20},
            accentHover = {0.84, 0.52, 0.28},
            checkbox = {0.84, 0.75, 0.69},
            checkboxChecked = {0.72, 0.40, 0.19},
            button = {0.79, 0.48, 0.30},
            buttonHover = {0.89, 0.58, 0.38},
            buttonPrimary = {0.84, 0.54, 0.28},
            buttonPrimaryHover = {0.94, 0.64, 0.36},
            border = {0.72, 0.43, 0.21},
            semantic = {
                panelBg = {0.93, 0.88, 0.83},
                panelAltBg = {0.89, 0.82, 0.76},
                cardBg = {0.88, 0.80, 0.74},
                border = {0.72, 0.43, 0.21},
                textSecondary = {0.42, 0.27, 0.18},
                textMuted = {0.55, 0.37, 0.24},
                tooltipBg = {0.96, 0.92, 0.88},
                tooltipBorder = {0.72, 0.44, 0.25},
                tooltipText = {0.16, 0.10, 0.08},
                iconPrimary = {0.73, 0.39, 0.16},
                iconMuted = {0.58, 0.36, 0.23},
                buttonText = {0.16, 0.10, 0.08},
                success = {0.70, 0.43, 0.22},
                warning = {0.90, 0.62, 0.28},
            },
            style = {
                cornerRadius = 9,
                borderWeight = 2,
                fxIntensity = 0.90,
                shadowStrength = 0.13,
                glossStrength = 0.80,
            },
        },
    },
    reaper_native = {
        nameKey = "theme_reaper_native",
        label = "REAPER Native",
        dark = {
            bg = {0.20, 0.20, 0.20},
            bgGradientTop = {0.20, 0.20, 0.20},
            bgGradientBottom = {0.20, 0.20, 0.20},
            inputBg = {0.15, 0.15, 0.15},
            text = {0.90, 0.90, 0.90},
            textDim = {0.70, 0.70, 0.70},
            textHint = {0.50, 0.50, 0.50},
            accent = {0.30, 0.40, 0.50},
            accentHover = {0.40, 0.50, 0.60},
            checkbox = {0.15, 0.15, 0.15},
            checkboxChecked = {0.30, 0.40, 0.50},
            button = {0.25, 0.25, 0.25},
            buttonHover = {0.35, 0.35, 0.35},
            buttonPrimary = {0.30, 0.40, 0.50},
            buttonPrimaryHover = {0.40, 0.50, 0.60},
            border = {0.40, 0.40, 0.40},
            semantic = {
                panelBg = {0.22, 0.22, 0.22},
                panelAltBg = {0.20, 0.20, 0.20},
                cardBg = {0.18, 0.18, 0.18},
                border = {0.40, 0.40, 0.40},
                textSecondary = {0.70, 0.70, 0.70},
                textMuted = {0.50, 0.50, 0.50},
                tooltipBg = {0.15, 0.15, 0.15},
                tooltipBorder = {0.40, 0.40, 0.40},
                tooltipText = {0.90, 0.90, 0.90},
                iconPrimary = {0.80, 0.80, 0.80},
                iconMuted = {0.50, 0.50, 0.50},
                buttonText = {0.90, 0.90, 0.90},
                success = {0.30, 0.50, 0.30},
                warning = {0.70, 0.50, 0.20},
            },
            style = {
                cornerRadius = 0,
                borderWeight = 1,
                fxIntensity = 0.0,
                shadowStrength = 0.0,
                glossStrength = 0.0,
            },
        },
        light = {
            bg = {0.85, 0.85, 0.85},
            bgGradientTop = {0.85, 0.85, 0.85},
            bgGradientBottom = {0.85, 0.85, 0.85},
            inputBg = {0.95, 0.95, 0.95},
            text = {0.10, 0.10, 0.10},
            textDim = {0.30, 0.30, 0.30},
            textHint = {0.50, 0.50, 0.50},
            accent = {0.50, 0.60, 0.70},
            accentHover = {0.40, 0.50, 0.60},
            checkbox = {0.95, 0.95, 0.95},
            checkboxChecked = {0.50, 0.60, 0.70},
            button = {0.75, 0.75, 0.75},
            buttonHover = {0.85, 0.85, 0.85},
            buttonPrimary = {0.50, 0.60, 0.70},
            buttonPrimaryHover = {0.40, 0.50, 0.60},
            border = {0.60, 0.60, 0.60},
            semantic = {
                panelBg = {0.80, 0.80, 0.80},
                panelAltBg = {0.85, 0.85, 0.85},
                cardBg = {0.90, 0.90, 0.90},
                border = {0.60, 0.60, 0.60},
                textSecondary = {0.30, 0.30, 0.30},
                textMuted = {0.50, 0.50, 0.50},
                tooltipBg = {0.95, 0.95, 0.95},
                tooltipBorder = {0.60, 0.60, 0.60},
                tooltipText = {0.10, 0.10, 0.10},
                iconPrimary = {0.20, 0.20, 0.20},
                iconMuted = {0.50, 0.50, 0.50},
                buttonText = {0.10, 0.10, 0.10},
                success = {0.40, 0.60, 0.40},
                warning = {0.80, 0.60, 0.30},
            },
            style = {
                cornerRadius = 0,
                borderWeight = 1,
                fxIntensity = 0.0,
                shadowStrength = 0.0,
                glossStrength = 0.0,
            },
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

    local presetId = _G.FORCE_THEME_PRESET or (SETTINGS and SETTINGS.themePreset)

    local resolved = {
        mode = settingsDarkMode and "dark" or "light",
        presetId = normalizeThemePreset(presetId),
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
            if key ~= "semantic" and key ~= "style" then
                themeTable[key] = value
            end
        end
    end
    return themeTable
end

local function getThemePresetLayer(mode, presetId)
    local resolvedPresetId = normalizeThemePreset(presetId)
    local preset = THEME_PRESETS[resolvedPresetId]
    if not preset then
        return nil
    end
    return (mode == "dark") and preset.dark or preset.light
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

    local activeTheme = {
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
            glossStrength = 1.0,
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

    local presetLayer = getThemePresetLayer(selection.mode, selection.presetId)
    if presetLayer and type(presetLayer.semantic) == "table" then
        for key, value in pairs(presetLayer.semantic) do
            activeTheme.colors[key] = cloneColor(value)
        end
    end
    if presetLayer and type(presetLayer.style) == "table" then
        for key, value in pairs(presetLayer.style) do
            activeTheme.style[key] = value
        end
    end

    return activeTheme
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
    if _G.FORCE_THEME_PRESET then
        return
    end
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
