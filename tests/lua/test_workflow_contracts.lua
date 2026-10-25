-- Pure cross-language checks over the same JSON fixtures used by pytest.
-- Run with: lua tests/lua/test_workflow_contracts.lua

local scriptDir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repoRoot = scriptDir .. "/../.."
local modulePath = repoRoot .. "/scripts/reaper/_internal/STEMwerk_Workflow_Contracts.lua"
local fixtures = repoRoot .. "/tests/fixtures/golden_2310"
local parityCorpus = repoRoot .. "/tests/fixtures/workflow_result_validator_parity.v1.json"

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

-- -----------------------------------------------------------------------
-- Astra Slice-0 hardening regressions
-- -----------------------------------------------------------------------

local catalogDir = repoRoot .. "/scripts/reaper/catalog"
local function loadCatalogs()
    local capabilities = CONTRACTS.loadJson(catalogDir .. "/capabilities.v1.json")
    local models = CONTRACTS.loadJson(catalogDir .. "/models.v1.json")
    local workflows = CONTRACTS.loadJson(catalogDir .. "/workflows.v1.json")
    return {
        capabilities = capabilities.capabilities,
        models = models.models,
        workflows = workflows.workflows,
    }
end
local REAL_CATALOGS = loadCatalogs()

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    local ok, err = CONTRACTS.validateBundle(bundle, REAL_CATALOGS)
    check("golden bundle validates against real catalog relational closure", ok == true, err)
end

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_request.stages[1].model_id = "totally_unknown_model"
    local ok, err = CONTRACTS.validateBundle(bundle, REAL_CATALOGS)
    check("stage unknown model_id rejected WITH catalogs",
        ok == nil and tostring(err):find("unknown model_id", 1, true) ~= nil, err)
end

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_request.stages[1].capability_id = "totally_unknown_capability"
    local ok, err = CONTRACTS.validateBundle(bundle, REAL_CATALOGS)
    check("stage unknown capability_id rejected WITH catalogs",
        ok == nil and tostring(err):find("unknown capability_id", 1, true) ~= nil, err)
end

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_request.deliverable_ids = { "vocals" }
    bundle.workflow_result.artifacts = { bundle.workflow_result.artifacts[1] }
    bundle.workflow_result.deliverables = { bundle.workflow_result.deliverables[1] }
    bundle.import_plan.imports = { bundle.import_plan.imports[1] }
    local ok, err = CONTRACTS.validateBundle(bundle, REAL_CATALOGS)
    check("selected route allows supported selective deliverables", ok == true, err)
end

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_request.stages[1].outputs = {
        { port_id = "guitar", semantic_id = "guitar", kind = "audio" },
    }
    bundle.workflow_request.deliverable_ids = { "guitar" }
    local artifact = bundle.workflow_result.artifacts[1]
    artifact.artifact_id = "artifact_guitar_001"
    artifact.semantic_id = "guitar"
    artifact.relative_path = "outputs/guitar.wav"
    artifact.producer.port_id = "guitar"
    bundle.workflow_result.artifacts = { artifact }
    bundle.workflow_result.deliverables = {
        { semantic_id = "guitar", artifact_id = "artifact_guitar_001" },
    }
    local imported = bundle.import_plan.imports[1]
    imported.semantic_id = "guitar"
    imported.artifact_id = "artifact_guitar_001"
    bundle.import_plan.imports = { imported }
    local ok, err = CONTRACTS.validateBundle(bundle, REAL_CATALOGS)
    check("selected route rejects unsupported deliverable",
        ok == nil and tostring(err):find("unsupported deliverable", 1, true) ~= nil, err)
end

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_request.stages[1].model_id = "totally_unknown_model"
    local ok, err = CONTRACTS.validateBundle(bundle)
    check("stage unknown model_id still ACCEPTED without catalogs (legacy structural-only mode)",
        ok == true, err)
end

expectInvalid("actual_runtime.model_id disagrees with requested_runtime.model_id without fallback", function(b)
    b.workflow_result.actual_runtime.model_id = "htdemucs_ft"
end, "actual_runtime.model_id disagrees")

do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_result.actual_runtime.model_id = "htdemucs_ft"
    bundle.workflow_result.actual_runtime.fallback_applied = true
    local ok, err = CONTRACTS.validateBundle(bundle)
    check("actual_runtime.model_id disagreement allowed when fallback_applied=true", ok == true, err)
end

for _, state in ipairs({ "failed", "cancelled", "running", "queued", "blocked" }) do
    expectInvalid("non-succeeded state (" .. state .. ") with nonempty import plan is rejected", function(b)
        b.workflow_result.state = state
    end, "must be empty")
end

for _, state in ipairs({ "failed", "cancelled", "running", "queued", "blocked" }) do
    local bundle = loadBundle("normal_stems_new_tracks.json")
    bundle.workflow_result.state = state
    bundle.workflow_result.actual_runtime = nil
    bundle.workflow_result.deliverables = {}
    bundle.workflow_result.artifacts = {}
    bundle.import_plan.imports = {}
    local ok, err = CONTRACTS.validateBundle(bundle)
    check(state .. " result is representable without fabricated runtime/outputs", ok == true, err)
end

expectInvalid("succeeded result still requires actual_runtime", function(b)
    b.workflow_result.actual_runtime = nil
end, "actual_runtime")

expectInvalid("workflow_request.deliverable_ids must not be empty", function(b)
    b.workflow_request.deliverable_ids = {}
end, "deliverable_ids must not be empty")

expectInvalid("source_plan.sources supports exactly one source in Slice-0", function(b)
    local sources = b.workflow_request.source_plan.sources
    local second = {
        source_id = "source_002",
        order = 2,
        kind = "selected_item",
        project_identity = sources[1].project_identity,
        track_identity = sources[1].track_identity,
        item_identity = "source_item_002",
    }
    sources[#sources + 1] = second
end, "exactly one source")

expectInvalid("import order must match array position exactly", function(b)
    local imports = b.import_plan.imports
    imports[1].order, imports[2].order = imports[2].order, imports[1].order
end, "import order must match array position")

-- -----------------------------------------------------------------------
-- Astra: Lua JSON decoder must reassemble UTF-16 surrogate pairs into a
-- single non-BMP UTF-8 codepoint, matching Python's json.loads, instead of
-- emitting two separate invalid 3-byte sequences for the raw surrogate
-- halves. Fixture: U+1F600 (grinning face emoji) as "😀".
-- -----------------------------------------------------------------------
do
    local tmpPath = os.tmpname()
    local f = assert(io.open(tmpPath, "wb"))
    f:write('{"label":"\\ud83d\\ude00"}')
    f:close()
    local decoded, err = CONTRACTS.loadJson(tmpPath)
    os.remove(tmpPath)
    local expected = string.char(0xF0, 0x9F, 0x98, 0x80) -- U+1F600 in correct UTF-8
    check("surrogate pair decodes to correct non-BMP UTF-8 bytes",
        decoded ~= nil and decoded.label == expected,
        decoded and ("got " .. #decoded.label .. " bytes") or err)
end

do
    local tmpPath = os.tmpname()
    local f = assert(io.open(tmpPath, "wb"))
    f:write('{"label":"\\ud83d"}')
    f:close()
    local decoded, err = CONTRACTS.loadJson(tmpPath)
    os.remove(tmpPath)
    check("unpaired high surrogate is rejected, not silently emitted",
        decoded == nil and tostring(err):find("unpaired UTF-16 surrogate", 1, true) ~= nil,
        err)
end

do
    local tmpPath = os.tmpname()
    local f = assert(io.open(tmpPath, "wb"))
    f:write('{"label":"\\ude00"}')
    f:close()
    local decoded, err = CONTRACTS.loadJson(tmpPath)
    os.remove(tmpPath)
    check("unpaired low surrogate is rejected, not silently emitted",
        decoded == nil and tostring(err):find("unpaired UTF-16 surrogate", 1, true) ~= nil,
        err)
end

-- Shared raw-JSON corpus: Python, Lua and JSON Schema consume the same cases.
-- Loading both the corpus and referenced goldens through CONTRACTS.loadJson
-- is essential here; preconstructed Lua tables cannot reproduce the empty
-- JSON array/object identity bug.
do
    local corpus, corpusErr = CONTRACTS.loadJson(parityCorpus)
    check("load shared workflow-result parity corpus", corpus ~= nil, corpusErr)
    if corpus then
        for _, case in ipairs(corpus.cases) do
            local document = case.document
            if case.fixture then
                local payload, fixtureErr = CONTRACTS.loadJson(repoRoot .. "/tests/fixtures/" .. case.fixture)
                check("load shared fixture " .. case.id, payload ~= nil, fixtureErr)
                if payload then
                    document = payload
                    for _, key in ipairs(case.document_path) do document = document[key] end
                end
            end
            if document then
                local accepted = CONTRACTS.validateWorkflowResult(document) ~= nil
                check("shared workflow-result parity " .. case.id,
                    accepted == case.expected.lua,
                    "expected " .. tostring(case.expected.lua) .. ", got " .. tostring(accepted))
            end
        end
    end
end

if failures > 0 then
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
print("RESULT: all tests passed")
