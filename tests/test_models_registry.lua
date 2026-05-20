local M = dofile("scripts/reaper/_internal/STEMwerk_Models.lua")

local function fail(message)
    error(message, 2)
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function assertTrue(value, message)
    if value ~= true then
        fail(string.format("%s: expected true, got %s", message, tostring(value)))
    end
end

local function assertFalse(value, message)
    if value ~= false then
        fail(string.format("%s: expected false, got %s", message, tostring(value)))
    end
end

local function assertNil(value, message)
    if value ~= nil then
        fail(string.format("%s: expected nil, got %s", message, tostring(value)))
    end
end

local models = M.list()
assertEqual(#models, 3, "M.list() count")
assertEqual(models[1].id, "htdemucs", "M.list()[1].id")
assertEqual(models[2].id, "htdemucs_ft", "M.list()[2].id")
assertEqual(models[3].id, "htdemucs_6s", "M.list()[3].id")

assertEqual(#M.byId("htdemucs").output_schema, 4, "htdemucs output_schema length")
assertEqual(#M.byId("htdemucs_ft").output_schema, 4, "htdemucs_ft output_schema length")
assertEqual(#M.byId("htdemucs_6s").output_schema, 6, "htdemucs_6s output_schema length")

assertTrue(M.isSixStem("htdemucs_6s"), "M.isSixStem('htdemucs_6s')")
assertFalse(M.isSixStem("htdemucs"), "M.isSixStem('htdemucs')")
assertEqual(M.defaultId(), "htdemucs", "M.defaultId()")
assertEqual(M.mpsPolicy("htdemucs"), "force_cpu_demucs", "M.mpsPolicy('htdemucs')")
assertNil(M.byId("nonexistent"), "M.byId('nonexistent')")
assertNil(M.outputSchema("xyz"), "M.outputSchema('xyz')")

local defaultCount = 0
for _, model in ipairs(models) do
    if model.flags and model.flags.is_default == true then
        defaultCount = defaultCount + 1
    end
end
assertEqual(defaultCount, 1, "default model count")

print("test_models_registry.lua: ok")
