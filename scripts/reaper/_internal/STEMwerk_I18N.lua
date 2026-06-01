-- STEMwerk_I18N.lua: i18n loader, T(), and language state extracted from STEMwerk.lua

local script_path = ... or (debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "")
local pathJoin = dofile(script_path .. "STEMwerk_System.lua").pathJoin

local LANGUAGES = nil
local LANG = nil

local function loadLanguages()
    local function getActionScriptDir()
        if reaper and reaper.get_action_context then
            local _, _, _, _, _, ctx = reaper.get_action_context()
            if type(ctx) == "string" and ctx ~= "" then
                local dir = ctx:match("@?(.*[/\\])")
                if dir and dir ~= "" then return dir end
            end
        end
        return script_path or ""
    end
    local baseDir = getActionScriptDir()
    local bases = {
        baseDir,
        pathJoin(baseDir, ".."),
        pathJoin(baseDir, ".." .. package.config:sub(1, 1) .. ".."),
    }
    local function buildCandidates(filename)
        local candidates, seen = {}, {}
        for _, base in ipairs(bases) do
            local p = pathJoin(base, "i18n" .. package.config:sub(1, 1) .. filename)
            if not seen[p] then
                candidates[#candidates + 1] = p
                seen[p] = true
            end
        end
        return candidates
    end
    local triedWrapper, triedLang = {}, {}
    for _, wrapper_file in ipairs(buildCandidates("stemwerk_language_wrapper.lua")) do
        triedWrapper[#triedWrapper + 1] = wrapper_file
        local f = io.open(wrapper_file, "r")
        if f then
            f:close()
            local ok, result = pcall(dofile, wrapper_file)
            if ok and type(result) == "table" then
                LANGUAGES = result
                return true
            end
        end
    end
    for _, lang_file in ipairs(buildCandidates("languages.lua")) do
        triedLang[#triedLang + 1] = lang_file
        local f = io.open(lang_file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            local table_str = content:match("local%s+LANGUAGES%s*=%s*(%b{})")
            if table_str then
                local env = {}
                local chunk, err = load("LANGUAGES = " .. table_str, "languages", "t", env)
                if chunk then
                    local ok, result = pcall(chunk)
                    if ok and env.LANGUAGES then
                        LANGUAGES = env.LANGUAGES
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function setLanguage(lang_code)
    if not LANGUAGES then loadLanguages() end
    if LANGUAGES and LANGUAGES[lang_code] then
        LANG = LANGUAGES[lang_code]
        return true
    else
        if LANGUAGES and LANGUAGES.en then
            LANG = LANGUAGES.en
        else
            LANG = {}
        end
    end
    return false
end

local function T(key)
    if LANG and LANG[key] then
        return LANG[key]
    end
    if LANGUAGES and LANGUAGES.en and LANGUAGES.en[key] then
        return LANGUAGES.en[key]
    end
    return (key:gsub("_", " "))
end

local function trPlural(count, singularKey, pluralKey, singularFallback, pluralFallback)
    local function resolveOrFallback(key, fallback)
        local value = T(key)
        local keyText = tostring(key or "")
        local humanized = keyText:gsub("_", " ")
        if value == nil then
            return fallback or keyText
        end
        value = tostring(value)
        if value == "" or value == keyText or value == humanized then
            return fallback or keyText
        end
        return value
    end
    if (count or 0) == 1 then
        return resolveOrFallback(singularKey, singularFallback)
    end
    return resolveOrFallback(pluralKey, pluralFallback)
end

local function getAvailableLanguages()
    if not LANGUAGES then loadLanguages() end
    local langs = {}
    if LANGUAGES then
        for code, _ in pairs(LANGUAGES) do
            table.insert(langs, code)
        end
    end
    table.sort(langs)
    return langs
end

return {
    loadLanguages = loadLanguages,
    setLanguage = setLanguage,
    T = T,
    trPlural = trPlural,
    getAvailableLanguages = getAvailableLanguages,
    LANGUAGES = function() return LANGUAGES end,
    LANG = function() return LANG end,
}
