-- Pure cross-language checks over the same JSON fixtures used by pytest.
-- Run with: lua tests/lua/test_workflow_contracts.lua

local scriptDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repoRoot = scriptDir .. "/../.."
local modulePath = repoRoot .. "/scripts/reaper/_internal/STEMwerk_Workflow_Contracts.lua"
local fixtures = repoRoot .. "/tests/fixtures/golden_2310"

local CONTRACTS = dofile(modulePath)
local failures = 0

local function check(name, condition, detail)
    if condition then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

local function loadBundle(name)
    local payload, err = CONTRACTS.loadJson(fixtures .. "/" .. name)
    check("load " .. name, payload ~= nil, err)
    return payload and payload.contracts
end

for _, name in ipairs({ "normal_stems_new_tracks.json", "normal_stems_in_place.json" }) do
    local bundle = loadBundle(name)
    if bundle then
        local ok, err = CONTRACTS.validateBundle(bundle)
        check("validate " .. name, ok == true, err)
    end
end

local function expectInvalid(name, mutate, expected)
    local bundle = loadBundle("normal_stems_new_tracks.json")
    if not bundle then return end
    mutate(bundle)
    local ok, err = CONTRACTS.validateBundle(bundle)
    check(name, ok == nil and tostring(err):find(expected, 1, true) ~= nil, err)
end

local function setArtifactPath(bundle, path)
    bundle.workflow_result.artifacts[1].relative_path = path
end

local function referenceStageOutput(bundle, stageId)
    bundle.workflow_request.stages[1].input = {
        kind = "stage_output",
        stage_id = stageId,
        port_id = "vocals",
        artifact_kind = "audio",
    }
end

expectInvalid("unsupported schema major", function(b)
    b.workflow_request.schema_version = "2.0.0"
end, "schema_version")

expectInvalid("duplicate stage output port", function(b)
    local outputs = b.workflow_request.stages[1].outputs
    outputs[#outputs + 1] = outputs[1]
end, "duplicate output port_id")

expectInvalid("missing source reference", function(b)
    b.workflow_request.stages[1].input.source_id = "source_missing"
end, "missing source")

expectInvalid("undeclared deliverable", function(b)
    b.workflow_result.deliverables[1].semantic_id = "guitar"
end, "undeclared deliverable")

expectInvalid("request identity mismatch", function(b)
    b.workflow_result.request_id = "request_other"
end, "request identity mismatch")

expectInvalid("invalid processing state", function(b)
    b.workflow_result.state = "maybe_finished"
end, "invalid processing state")

for _, path in ipairs({
    "..",
    ".",
    "outputs/../x.wav",
    "outputs/./x.wav",
    "outputs//x.wav",
    "outputs/x.wav/",
    "../outputs/x.wav",
    "./outputs/x.wav",
    "/tmp/x.wav",
}) do
    expectInvalid("reject raw invalid path " .. path, function(b)
        setArtifactPath(b, path)
    end, "relative_path")
end

for _, path in ipairs({ "outputs/vocals.wav", "stages/01-normal/vocals.wav" }) do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    if bundle then
        setArtifactPath(bundle, path)
        local ok, err = CONTRACTS.validateBundle(bundle)
        check("accept normal relative path " .. path, ok == true, err)
    end
end

expectInvalid("reject forward stage reference", function(b)
    local future = {
        schema_version = "1.0.0",
        stage_id = "separate_future_002",
        order = 2,
        capability_id = "normal_stems_4",
        model_id = "htdemucs",
        input = {
            kind = "source",
            source_id = "source_001",
            artifact_kind = "audio",
        },
        outputs = {
            { port_id = "vocals", semantic_id = "vocals", kind = "audio" },
        },
    }
    b.workflow_request.stages[2] = future
    referenceStageOutput(b, "separate_future_002")
end, "non-earlier producer stage")

expectInvalid("reject self-cycle stage reference", function(b)
    referenceStageOutput(b, "separate_normal_001")
end, "non-earlier producer stage")

expectInvalid("missing producer", function(b)
    b.workflow_result.artifacts[1].producer.stage_id = "stage_missing"
end, "missing producer stage")

expectInvalid("invalid artifact reference", function(b)
    b.import_plan.imports[1].artifact_id = "artifact_missing"
end, "invalid artifact reference")

expectInvalid("serialized REAPER pointer", function(b)
    b.workflow_request.reaproject_pointer = "ReaProject* 0x1234"
end, "serialized REAPER pointer")

expectInvalid("unstable semantic id", function(b)
    b.workflow_request.deliverable_ids = { "Vocals" }
end, "stable semantic id")

expectInvalid("predicate is outside stage v1", function(b)
    b.workflow_request.stages[1].predicate = "always"
end, "unsupported field")

if failures > 0 then
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
print("RESULT: all tests passed")
