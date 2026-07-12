--[[
  STEMwerk_Model_Registry.lua — registry schema v2 (commit 2)
  ------------------------------------------------------------
  Metadata-only toegang tot scripts/reaper/models.json.

  HARD-FAIL POLICY (registry_policy in models.json):
    * onbekend model-id            -> error(), na SW_LOG-entry indien beschikbaar
    * ontbrekend output_contract   -> error()
    * ontbrekende/foute manifest   -> error() bij eerste gebruik
    * GEEN stille fallback naar 4-stem Demucs of naar de default, nergens

  Laden (conform bestaande _internal conventie):
    local Registry = dofile(script_path .. "_internal/STEMwerk_Model_Registry.lua")

  Deze module raakt geen runtime: geen device-keuzes, geen process-spawn,
  geen settings-writes. Zij levert uitsluitend metadata; audio_separator_process.py
  en de DKS-runtime blijven leidend voor al het gedrag.
]]

local Registry = {}

-- ---------------------------------------------------------------------------
-- Logging + hard fail
-- ---------------------------------------------------------------------------

local function log_line(msg)
    -- SW_LOG is een global zodra STEMwerk_Log.lua geladen is; registry werkt
    -- ook headless (tests) zonder SW_LOG.
    local ok = pcall(function()
        if SW_LOG and SW_LOG.logExecResult then
            SW_LOG.logExecResult("lua_model_registry_error=" .. tostring(msg), nil, "")
        end
    end)
    return ok
end

local function fail(msg)
    log_line(msg)
    error("STEMwerk_Model_Registry: " .. tostring(msg), 3)
end

-- ---------------------------------------------------------------------------
-- Minimale JSON-decoder (alleen wat models.json nodig heeft:
-- object/array/string/number/true/false/null, string-escapes incl. \uXXXX)
-- ---------------------------------------------------------------------------

local json_decode
do
    local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                      b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

    local function decode_error(str, pos, why)
        local line = 1
        for _ in str:sub(1, pos):gmatch("\n") do line = line + 1 end
        fail(("JSON-fout op regel %d (pos %d): %s"):format(line, pos, why))
    end

    local function skip_ws(str, pos)
        local _, e = str:find("^[ \t\r\n]*", pos)
        return e + 1
    end

    local decode_value

    local function decode_string(str, pos)
        local out, i = {}, pos + 1
        while true do
            local c = str:sub(i, i)
            if c == "" then decode_error(str, i, "onafgesloten string") end
            if c == '"' then
                return table.concat(out), i + 1
            elseif c == "\\" then
                local esc = str:sub(i + 1, i + 1)
                if esc == "u" then
                    local hex = str:sub(i + 2, i + 5)
                    if not hex:match("^%x%x%x%x$") then
                        decode_error(str, i, "ongeldige \\u escape")
                    end
                    local code = tonumber(hex, 16)
                    -- basis-multilingual plane volstaat voor models.json
                    if code < 0x80 then
                        out[#out + 1] = string.char(code)
                    elseif code < 0x800 then
                        out[#out + 1] = string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
                    else
                        out[#out + 1] = string.char(0xE0 | (code >> 12),
                                                    0x80 | ((code >> 6) & 0x3F),
                                                    0x80 | (code & 0x3F))
                    end
                    i = i + 6
                else
                    local mapped = ESCAPES[esc]
                    if not mapped then decode_error(str, i, "ongeldige escape \\" .. esc) end
                    out[#out + 1] = mapped
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
    end

    local function decode_number(str, pos)
        local num_str = str:match("^-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
        local num = tonumber(num_str)
        if not num then decode_error(str, pos, "ongeldig getal") end
        return num, pos + #num_str
    end

    local function decode_array(str, pos)
        local arr = {}
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local value
            value, pos = decode_value(str, pos)
            arr[#arr + 1] = value
            pos = skip_ws(str, pos)
            local c = str:sub(pos, pos)
            if c == "]" then return arr, pos + 1 end
            if c ~= "," then decode_error(str, pos, "',' of ']' verwacht") end
            pos = skip_ws(str, pos + 1)
        end
    end

    local function decode_object(str, pos)
        local obj = {}
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "object-key verwacht") end
            local key
            key, pos = decode_string(str, pos)
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "':' verwacht") end
            local value
            value, pos = decode_value(str, skip_ws(str, pos + 1))
            obj[key] = value
            pos = skip_ws(str, pos)
            local c = str:sub(pos, pos)
            if c == "}" then return obj, pos + 1 end
            if c ~= "," then decode_error(str, pos, "',' of '}' verwacht") end
            pos = skip_ws(str, pos + 1)
        end
    end

    decode_value = function(str, pos)
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == "{" then return decode_object(str, pos) end
        if c == "[" then return decode_array(str, pos) end
        if c == '"' then return decode_string(str, pos) end
        if c == "-" or c:match("%d") then return decode_number(str, pos) end
        if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
        if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
        if str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
        decode_error(str, pos, "onverwacht teken '" .. c .. "'")
    end

    json_decode = function(str)
        local value, pos = decode_value(str, 1)
        pos = skip_ws(str, pos)
        if pos <= #str then decode_error(str, pos, "data na einde JSON") end
        return value
    end
end

-- ---------------------------------------------------------------------------
-- Manifest laden + schema-check
-- ---------------------------------------------------------------------------

local PATH_SEP = package.config:sub(1, 1)

local function module_dir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("(.*[/\\])") or ("." .. PATH_SEP)
end

-- _internal/ -> parent (scripts/reaper/) waar models.json naast STEMwerk.lua staat
local DEFAULT_MANIFEST_PATH = module_dir() .. ".." .. PATH_SEP .. "models.json"

local _state = { manifest = nil, by_id = nil, path = nil }

--- Optioneel: expliciet pad zetten (tests / afwijkende layouts). Moet vóór
--- eerste gebruik; daarna hard fail om halfslachtige herlaad-states te voorkomen.
function Registry.set_manifest_path(path)
    if _state.manifest then
        fail("set_manifest_path na laden is niet toegestaan")
    end
    _state.path = path
end

local function validate_manifest(data, path)
    if type(data) ~= "table" then
        fail("manifest is geen JSON-object: " .. path)
    end
    if data.schema_version ~= 2 then
        fail(("schema_version %s wordt niet ondersteund (verwacht 2): %s")
            :format(tostring(data.schema_version), path))
    end
    if type(data.models) ~= "table" or #data.models == 0 then
        fail("manifest bevat geen models[]: " .. path)
    end
    local policy = data.registry_policy or {}
    if policy.unknown_model_id ~= "hard_fail" or policy.silent_fallback_to_default ~= false then
        fail("registry_policy ontbreekt of staat niet op hard_fail: " .. path)
    end
end

local function load_manifest()
    if _state.manifest then return _state.manifest end
    local path = _state.path or DEFAULT_MANIFEST_PATH
    local fh, err = io.open(path, "r")
    if not fh then
        fail("models.json niet gevonden: " .. tostring(err))
    end
    local raw = fh:read("*a")
    fh:close()
    local ok, data = pcall(json_decode, raw)
    if not ok then
        -- json_decode faalt zelf al via fail(); dit vangt onverwachte errors
        error(data, 0)
    end
    validate_manifest(data, path)

    local by_id = {}
    for _, model in ipairs(data.models) do
        if type(model.id) ~= "string" or model.id == "" then
            fail("model zonder geldig id in manifest")
        end
        if by_id[model.id] then
            fail("duplicaat model-id: " .. model.id)
        end
        by_id[model.id] = model
    end

    _state.manifest = data
    _state.by_id = by_id
    _state.path = path
    return data
end

local function contract_of(model)
    local contract = model.output_contract
    if type(contract) ~= "table"
        or type(contract.stems) ~= "table"
        or #contract.stems == 0
        or type(contract.stem_semantics) ~= "string"
        or type(contract.expected_outputs) ~= "number" then
        fail("output_contract ontbreekt of is onvolledig voor model: " .. model.id)
    end
    if contract.expected_outputs ~= #contract.stems then
        fail("output_contract inconsistent (expected_outputs != #stems) voor model: " .. model.id)
    end
    return contract
end

-- ---------------------------------------------------------------------------
-- Publieke API — alles hard-failend, geen stille fallbacks
-- ---------------------------------------------------------------------------

--- Model op id. HARD FAIL bij onbekend id.
function Registry.get(id)
    load_manifest()
    local model = _state.by_id[id]
    if not model then
        fail("onbekend model-id: " .. tostring(id))
    end
    return model
end

--- Bestaans-check zonder fail. Uitsluitend voor expliciete probes
--- (bv. settings-migratie); NOOIT gebruiken om stil op iets anders
--- terug te vallen.
function Registry.exists(id)
    load_manifest()
    return _state.by_id[id] ~= nil
end

--- Actieve (hidden == false) modellen, gesorteerd op ui.order.
function Registry.models()
    local data = load_manifest()
    local out = {}
    for _, model in ipairs(data.models) do
        if model.hidden ~= true then
            out[#out + 1] = model
        end
    end
    table.sort(out, function(a, b)
        return ((a.ui or {}).order or 0) < ((b.ui or {}).order or 0)
    end)
    return out
end

--- Id van het actieve default-model. HARD FAIL bij nul of meerdere defaults —
--- geen fallback naar een hardcoded modelnaam.
function Registry.default_id()
    local found = nil
    for _, model in ipairs(Registry.models()) do
        if model.default == true then
            if found then
                fail("meerdere actieve default-modellen: " .. found .. ", " .. model.id)
            end
            found = model.id
        end
    end
    if not found then
        fail("geen actief default-model in manifest")
    end
    return found
end

--- Stems van een model. HARD FAIL bij onbekend id of ontbrekend contract.
--- Dit vervangt elke `model == "htdemucs_6s"` check.
--- Retourneert een KOPIE zodat callers de registry-state niet kunnen muteren.
local function copy_array(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end

function Registry.stems(id)
    return copy_array(contract_of(Registry.get(id)).stems)
end

function Registry.has_stem(id, stem)
    for _, s in ipairs(Registry.stems(id)) do
        if s == stem then return true end
    end
    return false
end

function Registry.expected_outputs(id)
    return contract_of(Registry.get(id)).expected_outputs
end

--- stem_semantics van een model ("full_mix_decomposition" | "complement" | "split").
--- Dit vervangt is_two_stem()-achtige helpers: de UI kiest layout op semantiek.
function Registry.stem_semantics(id)
    local semantics = contract_of(Registry.get(id)).stem_semantics
    local known = (load_manifest().stem_semantics_types or {})
    if known[semantics] == nil then
        fail("onbekende stem_semantics '" .. tostring(semantics) .. "' voor model: " .. id)
    end
    return semantics
end

--- Backend-metadata voor de bestaande runtime-aanroep.
--- Levert alleen door wat in het manifest staat; geen device/engine-keuzes hier.
function Registry.backend(id)
    local model = Registry.get(id)
    return {
        engine = model.engine,
        architecture = model.architecture,
        family = model.family,
        backend_arg = model.backend_arg,
        kind = model.kind,
    }
end

--- UI-metadata; caller resolvet label_key/tooltip_key via trSafeValue,
--- fallback_label alleen als laatste redmiddel (zelfde patroon als i18n nu).
function Registry.ui(id)
    local model = Registry.get(id)
    local ui = model.ui or {}
    return {
        label_key = ui.label_key,
        tooltip_key = ui.tooltip_key,
        fallback_label = ui.fallback_label,
        tier = ui.tier,
        order = ui.order,
    }
end

function Registry.runtime(id)
    local model = Registry.get(id)
    local rt = model.runtime
    if type(rt) ~= "table" or type(rt.profiles) ~= "table" then
        fail("runtime-blok ontbreekt voor model: " .. id)
    end
    return rt
end

--- Presets (workflows). HARD FAIL bij onbekend preset-id.
function Registry.presets()
    return load_manifest().presets or {}
end

function Registry.preset(id)
    for _, preset in ipairs(Registry.presets()) do
        if preset.id == id then return preset end
    end
    fail("onbekend preset-id: " .. tostring(id))
end

--- Valideert dat elke stage in elke preset naar een bestaand internal_stage
--- model verwijst. Bedoeld voor een load-time sanity call vanuit STEMwerk.lua;
--- HARD FAIL bij schending.
function Registry.validate_preset_stages()
    for _, preset in ipairs(Registry.presets()) do
        for _, stage in ipairs((preset.workflow or {}).stages or {}) do
            local model = Registry.get(stage.stage) -- hard fail bij onbekend
            if model.kind ~= "internal_stage" then
                fail(("preset '%s' verwijst naar stage '%s' die geen internal_stage is")
                    :format(preset.id, stage.stage))
            end
        end
    end
    return true
end

function Registry.manifest_path()
    load_manifest()
    return _state.path
end

return Registry
