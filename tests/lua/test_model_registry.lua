--[[
  tests/lua/test_model_registry.lua — headless registry-test (commit 2)
  Draaien met standalone Lua 5.3/5.4 vanuit de repo-root:
      lua5.4 tests/lua/test_model_registry.lua
  Zelfde patroon als tests/support/run_support_bundle_headless.lua: geen REAPER nodig.
]]

local passed, failed = 0, 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print("PASS  " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local function expect_error(name, fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        check(name, false, "verwachtte hard fail, maar er kwam geen error")
    else
        local msg = tostring(err)
        check(name, pattern == nil or msg:find(pattern, 1, true) ~= nil,
              "error kwam, maar zonder verwacht patroon '" .. tostring(pattern) .. "': " .. msg)
    end
end

-- registry laden vanaf repo-root
local Registry = dofile("scripts/reaper/_internal/STEMwerk_Model_Registry.lua")

-- ---------------------------------------------------------------------------
-- Happy path tegen de echte models.json
-- ---------------------------------------------------------------------------

local models = Registry.models()
check("models(): drie actieve modellen", #models == 3, "#models=" .. #models)
check("models(): gesorteerd op ui.order",
      models[1].id == "htdemucs" and models[2].id == "htdemucs_ft" and models[3].id == "htdemucs_6s")
check("models(): hidden entries niet zichtbaar", (function()
    for _, m in ipairs(models) do
        if m.id == "bs_roformer_viperx" or m.id == "stemwerk_dks" then return false end
    end
    return true
end)())

check("default_id() == htdemucs (matcht SETTINGS.model)", Registry.default_id() == "htdemucs")

local stems6 = Registry.stems("htdemucs_6s")
check("stems(htdemucs_6s): 6 stems", #stems6 == 6)
check("has_stem(htdemucs_6s, guitar)", Registry.has_stem("htdemucs_6s", "guitar"))
check("has_stem(htdemucs, guitar) == false", not Registry.has_stem("htdemucs", "guitar"))
check("expected_outputs(htdemucs) == 4", Registry.expected_outputs("htdemucs") == 4)

check("stem_semantics(htdemucs) == full_mix_decomposition",
      Registry.stem_semantics("htdemucs") == "full_mix_decomposition")

local dks = Registry.get("stemwerk_dks")
check("DKS via get() bereikbaar ondanks hidden", dks ~= nil and dks.kind == "internal_stage")
check("DKS stems-volgorde == DIRECT_DKS_EXPECTED_STEMS", (function()
    local expect = { "kick", "snare", "toms", "hihat", "ride", "crash" }
    local got = Registry.stems("stemwerk_dks")
    if #got ~= #expect then return false end
    for i = 1, #expect do
        if got[i] ~= expect[i] then return false end
    end
    return true
end)())

local backend = Registry.backend("htdemucs_ft")
check("backend(htdemucs_ft): engine audio_separator + yaml arg",
      backend.engine == "audio_separator" and backend.backend_arg == "htdemucs_ft.yaml")

local ui = Registry.ui("htdemucs")
check("ui(htdemucs): label_key aanwezig", ui.label_key == "model_label_fast")

check("preset(direct_kit): primary_model == nil (Direct DKS zonder Demucs-stage)",
      Registry.preset("direct_kit").workflow.primary_model == nil)
check("preset(drum_kit_split): primary_model == user_selected",
      Registry.preset("drum_kit_split").workflow.primary_model == "user_selected")
check("validate_preset_stages()", Registry.validate_preset_stages() == true)

check("stems() retourneert een kopie — mutatie raakt registry-state niet", (function()
    local first = Registry.stems("htdemucs_6s")
    first[1] = "GEMUTEERD"
    first[#first + 1] = "extra"
    local second = Registry.stems("htdemucs_6s")
    return second[1] == "vocals" and #second == 6
end)())

-- ---------------------------------------------------------------------------
-- Hard-fail gedrag (registry_policy)
-- ---------------------------------------------------------------------------

expect_error("get(onbekend id) hard-failt",
    function() Registry.get("htdemucs_9000") end, "onbekend model-id")

expect_error("stems(onbekend id) hard-failt — geen stille 4-stem fallback",
    function() Registry.stems("does_not_exist") end, "onbekend model-id")

expect_error("preset(onbekend id) hard-failt",
    function() Registry.preset("nope") end, "onbekend preset-id")

check("exists() is de enige nil-veilige probe",
      Registry.exists("htdemucs") == true and Registry.exists("nope") == false)

-- ---------------------------------------------------------------------------
-- Hard fail op kapotte manifests (verse module-instanties met eigen pad)
-- ---------------------------------------------------------------------------

local function fresh_registry_with(json_text)
    local tmp = os.tmpname()
    local fh = assert(io.open(tmp, "w"))
    fh:write(json_text)
    fh:close()
    local reg = dofile("scripts/reaper/_internal/STEMwerk_Model_Registry.lua")
    reg.set_manifest_path(tmp)
    return reg, tmp
end

do
    local reg = fresh_registry_with('{ "schema_version": 1, "models": [] }')
    expect_error("schema_version != 2 hard-failt",
        function() reg.models() end, "schema_version")
end

do
    local reg = fresh_registry_with('{ "schema_version": 2, "models": [ { "id": "x" } ] }')
    expect_error("registry_policy ontbreekt -> hard fail",
        function() reg.models() end, "registry_policy")
end

do
    local reg = fresh_registry_with([[{
        "schema_version": 2,
        "registry_policy": { "unknown_model_id": "hard_fail", "silent_fallback_to_default": false },
        "stem_semantics_types": { "full_mix_decomposition": "" },
        "models": [ { "id": "broken", "hidden": false, "default": true } ]
    }]])
    expect_error("ontbrekend output_contract hard-failt",
        function() reg.stems("broken") end, "output_contract")
end

do
    local reg = fresh_registry_with('{ not valid json !!! }')
    expect_error("ongeldige JSON hard-failt met positie-info",
        function() reg.models() end, "JSON-fout")
end

-- ---------------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
