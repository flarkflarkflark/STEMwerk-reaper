-- STEMwerk Language Wrapper
-- Converts i18n/languages.lua format to the format expected by STEMwerk.lua
-- Returns LANGUAGES table

-- Load the language file
local file = io.open(debug.getinfo(1, "S").source:match("@?(.*[/\\])") .. "languages.lua", "r")
if not file then
    return {
        en = {},
        nl = {},
        de = {}
    }
end

local content = file:read("*all")
file:close()

-- Execute the language file content to get LANGUAGES table
local chunk, err = load("return " .. content:match("local%s+LANGUAGES%s*=%s*(%b{})"))
if not chunk then
    return {
        en = {},
        nl = {},
        de = {}
    }
end

local ok, languages = pcall(chunk)
if ok and languages then
    return languages
else
    return {
        en = {},
        nl = {},
        de = {}
    }
end
