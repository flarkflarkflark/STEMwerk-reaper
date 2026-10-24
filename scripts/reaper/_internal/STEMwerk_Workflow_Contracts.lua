-- Pure v1 JSON readers and validators for workflow characterization.
-- Deliberately not loaded by STEMwerk production code in Slice 0.

local M = {}
local SCHEMA_VERSION = "1.0.0"
local JSON_NULL = {}
M.JSON_NULL = JSON_NULL

local function fail(message)
    error(message, 0)
end

-- Small strict JSON decoder: enough for catalog/contract data, with duplicate
-- object keys rejected so Lua and Python do not interpret ambiguous input.
local function decodeJson(text)
    local pos, length = 1, #text

    local function skipSpace()
        while pos <= length and text:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local parseValue

    local function parseString()
        if text:sub(pos, pos) ~= '"' then fail("expected JSON string") end
        pos = pos + 1
        local parts = {}
        while pos <= length do
            local ch = text:sub(pos, pos)
            if ch == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif ch == "\\" then
                local escaped = text:sub(pos + 1, pos + 1)
                local simple = {
                    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
                }
                if simple[escaped] then
                    parts[#parts + 1] = simple[escaped]
                    pos = pos + 2
                elseif escaped == "u" then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:match("^%x%x%x%x$") then fail("invalid JSON unicode escape") end
                    local codepoint = tonumber(hex, 16)
                    if not utf8 or not utf8.char then fail("JSON unicode escape unsupported") end
                    parts[#parts + 1] = utf8.char(codepoint)
                    pos = pos + 6
                else
                    fail("invalid JSON escape")
                end
            else
                if ch:byte() < 32 then fail("control character in JSON string") end
                parts[#parts + 1] = ch
                pos = pos + 1
            end
        end
        fail("unterminated JSON string")
    end

    local function parseNumber()
        local start = pos
        if text:sub(pos, pos) == "-" then pos = pos + 1 end
        if text:sub(pos, pos) == "0" then
            pos = pos + 1
        else
            if not text:sub(pos, pos):match("%d") then fail("invalid JSON number") end
            while text:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        if text:sub(pos, pos) == "." then
            pos = pos + 1
            if not text:sub(pos, pos):match("%d") then fail("invalid JSON number") end
            while text:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        local exp = text:sub(pos, pos)
        if exp == "e" or exp == "E" then
            pos = pos + 1
            local sign = text:sub(pos, pos)
            if sign == "+" or sign == "-" then pos = pos + 1 end
            if not text:sub(pos, pos):match("%d") then fail("invalid JSON number") end
            while text:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        local value = tonumber(text:sub(start, pos - 1))
        if value == nil then fail("invalid JSON number") end
        return value
    end

    local function parseArray()
        pos = pos + 1
        skipSpace()
        local result = {}
        if text:sub(pos, pos) == "]" then pos = pos + 1; return result end
        while true do
            result[#result + 1] = parseValue()
            skipSpace()
            local ch = text:sub(pos, pos)
            if ch == "]" then pos = pos + 1; return result end
            if ch ~= "," then fail("expected comma in JSON array") end
            pos = pos + 1
            skipSpace()
        end
    end

    local function parseObject()
        pos = pos + 1
        skipSpace()
        local result, seen = {}, {}
        if text:sub(pos, pos) == "}" then pos = pos + 1; return result end
        while true do
            local key = parseString()
            if seen[key] then fail("duplicate JSON key: " .. key) end
            seen[key] = true
            skipSpace()
            if text:sub(pos, pos) ~= ":" then fail("expected colon in JSON object") end
            pos = pos + 1
            skipSpace()
            result[key] = parseValue()
            skipSpace()
            local ch = text:sub(pos, pos)
            if ch == "}" then pos = pos + 1; return result end
            if ch ~= "," then fail("expected comma in JSON object") end
            pos = pos + 1
            skipSpace()
        end
    end

    parseValue = function()
        skipSpace()
        local ch = text:sub(pos, pos)
        if ch == '"' then return parseString() end
        if ch == "{" then return parseObject() end
        if ch == "[" then return parseArray() end
        if ch == "-" or ch:match("%d") then return parseNumber() end
        if text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        if text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if text:sub(pos, pos + 3) == "null" then pos = pos + 4; return JSON_NULL end
        fail("invalid JSON value at byte " .. tostring(pos))
    end

    local value = parseValue()
    skipSpace()
    if pos <= length then fail("trailing data after JSON value") end
    return value
end

function M.loadJson(path)
    local handle, openError = io.open(path, "rb")
    if not handle then return nil, "invalid JSON file " .. tostring(path) .. ": " .. tostring(openError) end
    local text = handle:read("*a")
    handle:close()
    local ok, value = pcall(decodeJson, text or "")
    if not ok then return nil, tostring(value) end
    return value
end

local function object(value, where)
    if type(value) ~= "table" or value == JSON_NULL then fail(where .. " must be an object") end
    return value
end

local function array(value, where)
    object(value, where)
    local count = #value
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
            fail(where .. " must be an array")
        end
    end
    return value
end

local function stringValue(value, where)
    if type(value) ~= "string" or value == "" then fail(where .. " must be a non-empty string") end
    return value
end

local function booleanValue(value, where)
    if type(value) ~= "boolean" then fail(where .. " must be a boolean") end
    return value
end

local function schema(document, where)
    local version = stringValue(document.schema_version, where .. ".schema_version")
    if version ~= SCHEMA_VERSION then
        fail(where .. ".schema_version " .. version .. " is unsupported; expected " .. SCHEMA_VERSION)
    end
end

local function onlyKeys(document, allowed, where)
    for key in pairs(document) do
        if not allowed[key] then fail(where .. " contains unsupported field: " .. tostring(key)) end
    end
end

local function stableId(value, where)
    local identifier = stringValue(value, where)
    if not identifier:match("^[a-z][a-z0-9]*[a-z0-9._-]*$")
        or identifier:match("[._-][._-]")
        or identifier:match("[._-]$")
    then
        fail(where .. " must be a stable semantic id")
    end
    return identifier
end

local function unique(items, key, where)
    local result = {}
    for index, item in ipairs(items) do
        object(item, where .. " item")
        local identity = stableId(item[key], where .. "[" .. index .. "]." .. key)
        if result[identity] then fail("duplicate " .. key .. ": " .. identity) end
        result[identity] = item
    end
    return result
end

local function rejectReaperPointers(value, where, visited)
    if type(value) == "string" then
        local lowered = value:lower()
        if lowered:find("reaproject*", 1, true) or lowered:find("userdata: 0x", 1, true) == 1 then
            fail("serialized REAPER pointer at " .. where)
        end
    elseif type(value) == "table" and value ~= JSON_NULL then
        visited = visited or {}
        if visited[value] then return end
        visited[value] = true
        for key, child in pairs(value) do
            local lowered = tostring(key):lower()
            if lowered:find("reaproject", 1, true) or lowered:match("_pointer$") then
                fail("serialized REAPER pointer at " .. where .. "." .. tostring(key))
            end
            rejectReaperPointers(child, where .. "." .. tostring(key), visited)
        end
    end
end

local function relativePath(value, where)
    local path = stringValue(value, where)
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
        or path:find("\\", 1, true) or path:match("^%a:")
    then
        fail(where .. " must be a workspace-contained relative_path")
    end
    for segment in (path .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then
            fail(where .. " must be a workspace-contained relative_path")
        end
    end
    return path
end

local function validateSourcePlan(plan)
    object(plan, "source_plan")
    onlyKeys(plan, { schema_version = true, source_plan_id = true, sources = true }, "source_plan")
    schema(plan, "source_plan")
    stableId(plan.source_plan_id, "source_plan.source_plan_id")
    local sources = array(plan.sources, "source_plan.sources")
    if #sources == 0 then fail("source_plan.sources must not be empty") end
    local identities = unique(sources, "source_id", "source_plan.sources")
    local orders = {}
    for sourceId, source in pairs(identities) do
        onlyKeys(source, { source_id = true, order = true, kind = true, project_identity = true, track_identity = true, item_identity = true }, "source " .. sourceId)
        if source.kind ~= "selected_item" then fail("source " .. sourceId .. " kind must be selected_item") end
        if type(source.order) ~= "number" or source.order % 1 ~= 0 or source.order < 1 or orders[source.order] then
            fail("source ordering must contain unique positive integers")
        end
        orders[source.order] = true
        stableId(source.project_identity, "source " .. sourceId .. ".project_identity")
        stableId(source.track_identity, "source " .. sourceId .. ".track_identity")
        stableId(source.item_identity, "source " .. sourceId .. ".item_identity")
    end
    for index = 1, #sources do if not orders[index] then fail("source ordering must be contiguous") end end
    return plan
end

local function validateStageSpec(stage)
    object(stage, "stage_spec")
    onlyKeys(stage, { schema_version = true, stage_id = true, order = true, capability_id = true, model_id = true, input = true, outputs = true }, "stage_spec")
    schema(stage, "stage_spec")
    stableId(stage.stage_id, "stage_spec.stage_id")
    if type(stage.order) ~= "number" or stage.order % 1 ~= 0 or stage.order < 1 then
        fail("stage_spec.order must be a positive integer")
    end
    stableId(stage.capability_id, "stage_spec.capability_id")
    stableId(stage.model_id, "stage_spec.model_id")
    local input = object(stage.input, "stage_spec.input")
    if input.kind == "source" then
        onlyKeys(input, { kind = true, source_id = true, artifact_kind = true }, "stage_spec.input")
        stableId(input.source_id, "stage_spec.input.source_id")
    elseif input.kind == "stage_output" then
        onlyKeys(input, { kind = true, stage_id = true, port_id = true, artifact_kind = true }, "stage_spec.input")
        stableId(input.stage_id, "stage_spec.input.stage_id")
        stableId(input.port_id, "stage_spec.input.port_id")
    else
        fail("stage_spec.input.kind must be source or stage_output")
    end
    if input.artifact_kind ~= "audio" then fail("stage_spec.input.artifact_kind must be audio") end
    local outputs = array(stage.outputs, "stage_spec.outputs")
    if #outputs == 0 then fail("stage_spec.outputs must not be empty") end
    local ports = {}
    for index, output in ipairs(outputs) do
        local portId = stableId(output.port_id, "stage_spec.outputs[" .. index .. "].port_id")
        if ports[portId] then fail("duplicate output port_id: " .. portId) end
        ports[portId] = output
    end
    local semantics = {}
    for portId, output in pairs(ports) do
        onlyKeys(output, { port_id = true, semantic_id = true, kind = true }, "output " .. portId)
        local semantic = stableId(output.semantic_id, "output " .. portId .. ".semantic_id")
        if semantics[semantic] then fail("duplicate output semantic_id: " .. semantic) end
        semantics[semantic] = true
        if output.kind ~= "audio" then fail("output " .. portId .. ".kind must be audio") end
    end
    return stage
end

local function validateArtifact(artifact)
    object(artifact, "artifact")
    onlyKeys(artifact, { schema_version = true, artifact_id = true, kind = true, semantic_id = true, relative_path = true, producer = true }, "artifact")
    schema(artifact, "artifact")
    stableId(artifact.artifact_id, "artifact.artifact_id")
    if artifact.kind ~= "audio" then fail("artifact.kind must be audio") end
    stableId(artifact.semantic_id, "artifact.semantic_id")
    relativePath(artifact.relative_path, "artifact.relative_path")
    local producer = object(artifact.producer, "artifact.producer")
    onlyKeys(producer, { kind = true, stage_id = true, port_id = true }, "artifact.producer")
    if producer.kind ~= "stage_output" then fail("artifact.producer.kind must be stage_output") end
    stableId(producer.stage_id, "artifact.producer.stage_id")
    stableId(producer.port_id, "artifact.producer.port_id")
    return artifact
end

local function validateWorkflowRequest(request)
    object(request, "workflow_request")
    onlyKeys(request, { schema_version = true, request_id = true, workflow_id = true, source_plan = true, stages = true, deliverable_ids = true, requested_runtime = true }, "workflow_request")
    schema(request, "workflow_request")
    stableId(request.request_id, "workflow_request.request_id")
    stableId(request.workflow_id, "workflow_request.workflow_id")
    validateSourcePlan(request.source_plan)
    local stages = array(request.stages, "workflow_request.stages")
    if #stages == 0 then fail("workflow_request.stages must not be empty") end
    unique(stages, "stage_id", "workflow_request.stages")
    for index, stage in ipairs(stages) do
        validateStageSpec(stage)
        if stage.order ~= index then fail("stages must be in contiguous execution order") end
    end
    local deliverables = array(request.deliverable_ids, "workflow_request.deliverable_ids")
    local seen = {}
    for _, semantic in ipairs(deliverables) do
        semantic = stableId(semantic, "workflow_request.deliverable_ids item")
        if seen[semantic] then fail("duplicate deliverable identity") end
        seen[semantic] = true
    end
    local runtime = object(request.requested_runtime, "workflow_request.requested_runtime")
    onlyKeys(runtime, { model_id = true, device = true, processing_may_download = true }, "workflow_request.requested_runtime")
    stableId(runtime.model_id, "workflow_request.requested_runtime.model_id")
    stringValue(runtime.device, "workflow_request.requested_runtime.device")
    if runtime.processing_may_download ~= false then
        fail("requested_runtime.processing_may_download must be false")
    end
    return request
end

local PROCESSING_STATES = { queued = true, running = true, succeeded = true, failed = true, cancelled = true, blocked = true }
local function validateWorkflowResult(result)
    object(result, "workflow_result")
    onlyKeys(result, { schema_version = true, request_id = true, workflow_id = true, state = true, actual_runtime = true, artifacts = true, deliverables = true }, "workflow_result")
    schema(result, "workflow_result")
    stableId(result.request_id, "workflow_result.request_id")
    stableId(result.workflow_id, "workflow_result.workflow_id")
    if type(result.state) ~= "string" or not PROCESSING_STATES[result.state] then
        fail("invalid processing state: " .. tostring(result.state))
    end
    local runtime = object(result.actual_runtime, "workflow_result.actual_runtime")
    onlyKeys(runtime, { model_id = true, requested_device = true, actual_device = true, fallback_applied = true }, "workflow_result.actual_runtime")
    stableId(runtime.model_id, "workflow_result.actual_runtime.model_id")
    stringValue(runtime.requested_device, "workflow_result.actual_runtime.requested_device")
    stringValue(runtime.actual_device, "workflow_result.actual_runtime.actual_device")
    booleanValue(runtime.fallback_applied, "workflow_result.actual_runtime.fallback_applied")
    local artifacts = array(result.artifacts, "workflow_result.artifacts")
    unique(artifacts, "artifact_id", "workflow_result.artifacts")
    for _, artifact in ipairs(artifacts) do validateArtifact(artifact) end
    local deliverables = array(result.deliverables, "workflow_result.deliverables")
    unique(deliverables, "semantic_id", "workflow_result.deliverables")
    for _, item in ipairs(deliverables) do
        onlyKeys(item, { semantic_id = true, artifact_id = true }, "workflow_result.deliverable")
        stableId(item.artifact_id, "workflow_result.deliverable.artifact_id")
    end
    return result
end

local DESTINATIONS = { new_tracks = true, in_place_takes = true }
local GROUPINGS = { per_item = true, source_track = true }
local SOURCE_AFTER = { keep = true, mute_item = true, delete_item = true, mute_track = true, delete_track = true }
local function validateImportPlan(plan)
    object(plan, "import_plan")
    onlyKeys(plan, { schema_version = true, request_id = true, workflow_id = true, destination = true, grouping = true, create_folder = true, source_after = true, origin_project_policy = true, imports = true }, "import_plan")
    schema(plan, "import_plan")
    stableId(plan.request_id, "import_plan.request_id")
    stableId(plan.workflow_id, "import_plan.workflow_id")
    if not DESTINATIONS[plan.destination] then fail("import_plan.destination is invalid") end
    if not GROUPINGS[plan.grouping] then fail("import_plan.grouping is invalid") end
    booleanValue(plan.create_folder, "import_plan.create_folder")
    if not SOURCE_AFTER[plan.source_after] then fail("import_plan.source_after is invalid") end
    if plan.origin_project_policy ~= "fail_closed" then fail("import_plan.origin_project_policy must be fail_closed") end
    local imports = array(plan.imports, "import_plan.imports")
    unique(imports, "semantic_id", "import_plan.imports")
    local orders = {}
    for _, item in ipairs(imports) do
        onlyKeys(item, { order = true, semantic_id = true, artifact_id = true, name_template = true }, "import")
        stableId(item.artifact_id, "import artifact_id")
        if type(item.order) ~= "number" or item.order % 1 ~= 0 or item.order < 1 or orders[item.order] then
            fail("import ordering must contain unique positive integers")
        end
        orders[item.order] = true
        stringValue(item.name_template, "import name_template")
    end
    for index = 1, #imports do if not orders[index] then fail("import ordering must be contiguous") end end
    return plan
end

local function validateBundle(bundle)
    object(bundle, "bundle")
    rejectReaperPointers(bundle, "contract")
    onlyKeys(bundle, { workflow_request = true, workflow_result = true, import_plan = true }, "bundle")
    local request = validateWorkflowRequest(bundle.workflow_request)
    local result = validateWorkflowResult(bundle.workflow_result)
    local importPlan = validateImportPlan(bundle.import_plan)
    if result.request_id ~= request.request_id or importPlan.request_id ~= request.request_id then
        fail("request identity mismatch")
    end
    if result.workflow_id ~= request.workflow_id or importPlan.workflow_id ~= request.workflow_id then
        fail("workflow identity mismatch")
    end

    local sourceIds = {}
    for _, source in ipairs(request.source_plan.sources) do sourceIds[source.source_id] = true end
    local stages, stageById, stageOrder, outputPorts = request.stages, {}, {}, {}
    for _, stage in ipairs(stages) do
        stageById[stage.stage_id] = stage
        stageOrder[stage.stage_id] = stage.order
        outputPorts[stage.stage_id] = {}
        for _, output in ipairs(stage.outputs) do outputPorts[stage.stage_id][output.port_id] = output.semantic_id end
    end
    for _, stage in ipairs(stages) do
        local input = stage.input
        if input.kind == "source" then
            if not sourceIds[input.source_id] then fail("missing source: " .. input.source_id) end
        else
            if not stageById[input.stage_id] or stageOrder[input.stage_id] >= stage.order then
                fail("missing or non-earlier producer stage: " .. input.stage_id)
            end
            if not outputPorts[input.stage_id][input.port_id] then fail("missing producer output port: " .. input.port_id) end
        end
    end

    local artifacts = {}
    for _, artifact in ipairs(result.artifacts) do
        artifacts[artifact.artifact_id] = artifact
        local producer = artifact.producer
        if not stageById[producer.stage_id] then fail("missing producer stage: " .. producer.stage_id) end
        local semantic = outputPorts[producer.stage_id][producer.port_id]
        if not semantic then fail("missing producer output port: " .. producer.port_id) end
        if artifact.semantic_id ~= semantic then fail("artifact semantic identity does not match producer port") end
    end

    for index, item in ipairs(result.deliverables) do
        if request.deliverable_ids[index] ~= item.semantic_id then
            local declared = false
            for _, semantic in ipairs(request.deliverable_ids) do if semantic == item.semantic_id then declared = true end end
            if not declared then fail("undeclared deliverable: " .. item.semantic_id) end
            fail("deliverables must exactly preserve declared order")
        end
        local artifact = artifacts[item.artifact_id]
        if not artifact then fail("invalid artifact reference: " .. item.artifact_id) end
        if artifact.semantic_id ~= item.semantic_id then fail("deliverable semantic identity does not match artifact") end
    end
    if #result.deliverables ~= #request.deliverable_ids then fail("deliverables must exactly preserve declared order") end

    for index, item in ipairs(importPlan.imports) do
        if request.deliverable_ids[index] ~= item.semantic_id then fail("imports must exactly preserve declared deliverable order") end
        local artifact = artifacts[item.artifact_id]
        if not artifact then fail("invalid artifact reference: " .. item.artifact_id) end
        if artifact.semantic_id ~= item.semantic_id then fail("import semantic identity does not match artifact") end
    end
    if #importPlan.imports ~= #request.deliverable_ids then fail("imports must exactly preserve declared deliverable order") end
    return true
end

local function publicValidator(validator)
    return function(value)
        local ok, result = pcall(validator, value)
        if not ok then return nil, tostring(result) end
        return result
    end
end

M.validateSourcePlan = publicValidator(validateSourcePlan)
M.validateStageSpec = publicValidator(validateStageSpec)
M.validateArtifact = publicValidator(validateArtifact)
M.validateWorkflowRequest = publicValidator(validateWorkflowRequest)
M.validateWorkflowResult = publicValidator(validateWorkflowResult)
M.validateImportPlan = publicValidator(validateImportPlan)
M.validateBundle = publicValidator(validateBundle)

return M
