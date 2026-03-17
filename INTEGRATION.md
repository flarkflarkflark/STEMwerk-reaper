# STEMwerk i18n Integration Guide

## Current Status

✅ **Completed:**
- `i18n/languages.lua` - 152 translations × 3 languages (EN/NL/DE)
- `tests/i18n/test_languages.py` - Complete validation suite (all tests pass)
- `i18n/stemwerk_language_wrapper.lua` - Lua wrapper for language loading
- CI integration in `.github/workflows/ci-full.yml`
- Documentation in `README.md` and `TESTING.md`

## Integration with STEMwerk REAPER Script

The full STEMwerk REAPER script lives in `scripts/reaper/STEMwerk.lua` (12k+ lines) and contains all features:
- Cross-platform Python detection (Homebrew, Windows AppData, venv support)
- Time selection support
- Guitar/Piano stems (keys 5/6)
- Scalable/resizable GUI
- ExtState persistence
- Keyboard shortcuts
- **i18n infrastructure** (needs path adjustment)

### Required Changes

**File:** `scripts/reaper/STEMwerk.lua`
**Area:** `loadLanguages()` (near the i18n section)

**Current code:**
```lua
local function loadLanguages()
    local lang_file = script_path .. "lang" .. PATH_SEP .. "i18n.lua"
    local f = io.open(lang_file, "r")
    if f then
        f:close()
        local ok, result = pcall(dofile, lang_file)
        if ok and result then
            LANGUAGES = result
            debugLog("Loaded languages from " .. lang_file)
            return true
        else
            debugLog("Failed to load languages: " .. tostring(result))
        end
    else
        debugLog("Language file not found: " .. lang_file)
    end
    return false
end
```

**Replace with (recommended):**
```lua
local function loadLanguages()
    -- Use the wrapper so `dofile()` returns a LANGUAGES table.
    local wrapper_file = script_path .. ".." .. PATH_SEP .. ".." .. PATH_SEP .. "i18n" .. PATH_SEP .. "stemwerk_language_wrapper.lua"
    local f = io.open(wrapper_file, "r")
    if f then
        f:close()
        local ok, result = pcall(dofile, wrapper_file)
        if ok and type(result) == "table" then
            LANGUAGES = result
            debugLog("Loaded languages from " .. wrapper_file)
            return true
        end
    end
    return false
end
```

### Directory Structure

```
STEMwerk/
├── i18n/
│   ├── languages.lua              # 152 keys × 3 languages
│   └── stemwerk_language_wrapper.lua  # Alternative loader
├── scripts/
│   └── reaper/
│       ├── STEMwerk.lua  # Main script
│       ├── STEMwerk_AI_Separate.lua  # Compatibility wrapper (old name)
│       ├── STEMwerk-SETUP.lua        # Guided installer / verifier
│       └── audio_separator_process.py
└── tests/
    └── i18n/
        └── test_languages.py      # Validation tests
```

### Testing After Integration

1. **Load script in REAPER:**
   ```
   Actions → Show action list → ReaScript: Load ReaScript...
   Select: STEMwerk/scripts/reaper/STEMwerk.lua
   ```

2. **Verify language loading:**
   - Check debug log (Windows: `%TEMP%\stemwerk_debug.log`)
   - Should show: "Loaded languages from ..."
   - Open script settings (gear icon)
   - Toggle between EN/NL/DE
   - Verify UI updates

3. **Test translations:**
   - English: "Vocals", "Help", "Processing"
   - Nederlands: "Vocalen", "Hulp", "Verwerken"
   - Deutsch: "Vocals", "Hilfe", "Verarbeitung"

### Alternative: Direct Inline Loading

If file path issues persist, embed languages directly in STEMwerk.lua:

```lua
-- Replace loadLanguages() with direct assignment
local function loadLanguages()
    LANGUAGES = {
        en = {
            help = "Help",
            vocals = "Vocals",
            drums = "Drums",
            bass = "Bass",
            other = "Other",
            guitar = "Guitar",
            piano = "Piano",
            -- ... copy all 152 keys from i18n/languages.lua
        },
        nl = {
            help = "Hulp",
            vocals = "Vocalen",
            -- ... copy all NL translations
        },
        de = {
            help = "Hilfe",
            vocals = "Vocals",
            -- ... copy all DE translations
        }
    }
    debugLog("Loaded embedded languages")
    return true
end
```

## Next Steps

1. ✅ Patch `scripts/reaper/STEMwerk.lua` to load `i18n/languages.lua`
3. ⏳ Test in REAPER with sample audio
4. ⏳ Verify language switching works
5. ⏳ Commit and push to repository

## Validation Commands

```bash
# Test i18n completeness
python tests/i18n/test_languages.py

# Expected output:
# ✓ All expected languages present: {'en', 'nl', 'de'}
# ✓ English has 152 keys
# ✓ NL complete (152 keys)
# ✓ DE complete (152 keys)
# ✓ All critical keys present
# Results: 4/4 tests passed
```

## Release Notes (from Untitled-2)

All features already implemented in STEMwerk.lua:

**Cross-platform support:**
- ✅ Better Python detection (Homebrew, Windows venvs, user paths)
- ✅ macOS: /opt/homebrew paths for Apple Silicon
- ✅ Windows: Better AppData Python detection

**Time selection support:**
- ✅ Separate time selections (not just media items)
- ✅ If no item selected, uses time selection instead
- ✅ Stems placed at time selection position

**UI Enhancements:**
- ✅ Keys 5/6 toggle Guitar/Piano stems
- ✅ Scalable/resizable GUI
- ✅ Window resizable (drag edges/corners)
- ✅ All elements scale proportionally
- ✅ Settings persist between sessions (ExtState)
- ✅ Keyboard shortcuts: 1-4, K, I, D, Enter, Escape

**New (Today):**
- ✅ Internationalization (EN/NL/DE)
- ✅ Language switching (settings gear menu)
- ✅ 152 translations per language
- ✅ Automated i18n validation tests
