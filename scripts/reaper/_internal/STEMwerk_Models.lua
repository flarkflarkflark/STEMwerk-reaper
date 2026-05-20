-- STEMwerk_Models.lua
-- Pure model registry metadata. This module intentionally has no REAPER API
-- dependencies so it can be tested outside REAPER.

local M = {}

local MODEL_REGISTRY = {
    {
        id = "htdemucs",
        family = "Demucs",
        backend = "audio-separator",
        pass_type = "single_pass",
        output_schema = { "vocals", "drums", "bass", "other" },
        i18n_label_key = "model_label_fast",
        i18n_desc_key = "model_fast_desc",
        badge = "default",
        tier = "standard",
        flags = {
            is_default = true,
            offline_pack_included = true,
            future_mlx_candidate = false,
        },
        constraints = {
            requires_extra_deps = false,
            approx_size_mb = 84,
            mps_policy = "force_cpu_demucs",
        },
        notes = "Current default 4-stem Demucs model.",
    },
    {
        id = "htdemucs_ft",
        family = "Demucs",
        backend = "audio-separator",
        pass_type = "single_pass",
        output_schema = { "vocals", "drums", "bass", "other" },
        i18n_label_key = "model_label_quality",
        i18n_desc_key = "model_quality_desc",
        badge = "quality",
        tier = "standard",
        flags = {
            is_default = false,
            offline_pack_included = true,
            future_mlx_candidate = false,
        },
        constraints = {
            requires_extra_deps = false,
            approx_size_mb = 337,
            mps_policy = "force_cpu_demucs",
        },
        notes = "Current higher-quality 4-stem Demucs model.",
    },
    {
        id = "htdemucs_6s",
        family = "Demucs",
        backend = "audio-separator",
        pass_type = "single_pass",
        output_schema = { "vocals", "drums", "bass", "other", "guitar", "piano" },
        i18n_label_key = "model_label_6stem",
        i18n_desc_key = "model_6stem_desc",
        badge = "advanced",
        tier = "advanced",
        flags = {
            is_default = false,
            offline_pack_included = true,
            future_mlx_candidate = false,
        },
        constraints = {
            requires_extra_deps = false,
            approx_size_mb = 55,
            mps_policy = "force_cpu_demucs",
        },
        notes = "Current optional 6-stem Demucs model with guitar and piano outputs.",
    },
}

local MODEL_BY_ID = {}
for _, entry in ipairs(MODEL_REGISTRY) do
    MODEL_BY_ID[entry.id] = entry
end

local function matchesFilter(entry, filter)
    if filter == nil then
        return true
    end
    if type(filter) == "function" then
        return filter(entry) and true or false
    end
    if type(filter) ~= "table" then
        return true
    end

    for key, expected in pairs(filter) do
        if entry[key] ~= expected then
            return false
        end
    end
    return true
end

function M.list(filter)
    local out = {}
    for _, entry in ipairs(MODEL_REGISTRY) do
        if matchesFilter(entry, filter) then
            out[#out + 1] = entry
        end
    end
    return out
end

function M.byId(id)
    return MODEL_BY_ID[tostring(id or "")]
end

function M.outputSchema(id)
    local entry = M.byId(id)
    return entry and entry.output_schema or nil
end

function M.isSixStem(id)
    local schema = M.outputSchema(id)
    return schema ~= nil and #schema == 6
end

function M.isCascade(id)
    local entry = M.byId(id)
    return entry ~= nil and entry.pass_type == "cascade"
end

function M.defaultId()
    for _, entry in ipairs(MODEL_REGISTRY) do
        if entry.flags and entry.flags.is_default == true then
            return entry.id
        end
    end
    return nil
end

function M.mpsPolicy(id)
    local entry = M.byId(id)
    if not entry or not entry.constraints then
        return nil
    end
    return entry.constraints.mps_policy
end

return M
