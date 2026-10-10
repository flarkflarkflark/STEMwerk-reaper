-- Headless behavioral coverage for the 2.3.1.3 Direct Kit Auto/MPS scheduler
-- fix in STEMwerk.lua.
--
-- Direct Kit's own DrumSep worker is memory-heavy; Auto resolving to MPS on
-- Apple Silicon must scale its outer job-launch cap to physical unified
-- memory (cap=1 at ~8 GiB, proven unsafe otherwise on the supported M1 8 GB
-- config; cap=2 preserved, not yet hardware-validated, above that), while
-- explicit MPS keeps its existing conservative cap=1 and every other
-- route/backend is untouched.
--
-- This extracts the real `_sep.SCHEDULER_POLICY` table and the real
-- `_sep.resolveSchedulerConcurrencyPolicy` function verbatim out of the
-- production scripts/reaper/STEMwerk.lua (a 24k-line file with an
-- unconditional `main()` at the bottom and no headless-test guard, so it
-- cannot be dofile()'d directly) and executes that extracted, unmodified
-- source text in isolation. This is real behavioral coverage of the actual
-- shipped function, not a hand-copied reimplementation and not a source-text
-- pattern match.

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local source = (info and info.source) or ""
    local path = source:match("^@(.*)$") or source
    return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local REPO_ROOT = scriptDir() .. "/../.."
local TARGET = REPO_ROOT .. "/scripts/reaper/STEMwerk.lua"

local function readFile(path)
    local f = io.open(path, "rb")
    assertf(f ~= nil, "cannot open " .. tostring(path))
    local data = f:read("*a")
    f:close()
    return data
end

local function extractBetween(source, startMarker, endMarker, label)
    local startPos = source:find(startMarker, 1, true)
    assertf(startPos ~= nil, "could not find start marker for " .. label)
    local endPos = source:find(endMarker, startPos, true)
    assertf(endPos ~= nil, "could not find end marker for " .. label)
    return source:sub(startPos, endPos + #endMarker - 1)
end

local source = readFile(TARGET)

local schedulerPolicyText = extractBetween(
    source, "_sep.SCHEDULER_POLICY = {", "\n}\n", "SCHEDULER_POLICY table")
local policyFunctionText = extractBetween(
    source, "_sep.resolveSchedulerConcurrencyPolicy = function(opts)", "\nend\n",
    "resolveSchedulerConcurrencyPolicy function")

-- Sanity: the extracted function text must contain the fix under test, so a
-- future refactor that silently drops or renames the branch fails loudly
-- here instead of the harness quietly testing stale/missing logic.
local dksDirectAutoMarker = 'route == "dks_direct" and tostring(opts.requestedDevice or ""):lower() == "auto"'
assertf(policyFunctionText:find(dksDirectAutoMarker, 1, true) ~= nil,
    "extracted function no longer contains the dks_direct Auto/MPS branch under test")

local chunkSource = "_sep = {}\nOS = \"macOS\"\n"
    .. schedulerPolicyText .. "\n" .. policyFunctionText .. "\nreturn _sep\n"
local chunk, loadErr = load(chunkSource, "dks_direct_scheduler_extract")
assertf(chunk ~= nil, "failed to load extracted scheduler source: " .. tostring(loadErr))
local sep = chunk()
assertf(type(sep.resolveSchedulerConcurrencyPolicy) == "function",
    "extracted chunk did not define resolveSchedulerConcurrencyPolicy")

local resolvePolicy = sep.resolveSchedulerConcurrencyPolicy

local function baseOpts(overrides)
    local opts = {
        route = "dks_direct",
        stage = "single_stage",
        backend = "mps",
        requestedDevice = "auto",
        requestedParallel = true,
        jobCount = 4,
        cpuCount = 8,
        ramGiB = 8,
    }
    for k, v in pairs(overrides or {}) do
        opts[k] = v
    end
    return opts
end

-- 1. Direct Kit / Auto, MPS backend, ~8 GiB (the proven M1 8 GB config):
--    cap=1, sequentialMode=true, truthful MPS-derived (not CPU-derived) reason.
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 8 }))
    assertf(policy.cap == 1, "8 GiB Auto/MPS expected cap=1, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == true, "8 GiB Auto/MPS expected sequentialMode=true")
    assertf(policy.reason == "scheduler_dks_direct_mps_low_memory_sequential",
        "8 GiB Auto/MPS reason not truthful/MPS-derived, got " .. tostring(policy.reason))
    assertf(not policy.reason:find("cpu", 1, true),
        "8 GiB Auto/MPS reason must not be CPU-derived, got " .. tostring(policy.reason))
end

-- Boundary just under/at the ~8 GiB safety threshold must also stay cap=1.
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 8.4 }))
    assertf(policy.cap == 1, "8.4 GiB Auto/MPS expected cap=1, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == true, "8.4 GiB Auto/MPS expected sequentialMode=true")
end

-- Unknown/zero RAM must default to the safe (cap=1) side, not cap=2.
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 0 }))
    assertf(policy.cap == 1, "unknown RAM Auto/MPS expected safe default cap=1, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == true, "unknown RAM Auto/MPS expected sequentialMode=true")
end

-- 2. Direct Kit / Auto, MPS backend, 16 GiB: preserved (not newly hardware-
--    validated) cap=2 parallel policy.
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 16 }))
    assertf(policy.cap == 2, "16 GiB Auto/MPS expected preserved cap=2, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == false, "16 GiB Auto/MPS expected sequentialMode=false")
    assertf(policy.reason == "scheduler_dks_direct_mps_cap2",
        "16 GiB Auto/MPS reason mismatch, got " .. tostring(policy.reason))
end

-- 3. 32 GiB: same preserved cap=2 policy.
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 32 }))
    assertf(policy.cap == 2, "32 GiB Auto/MPS expected preserved cap=2, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == false, "32 GiB Auto/MPS expected sequentialMode=false")
    assertf(policy.reason == "scheduler_dks_direct_mps_cap2",
        "32 GiB Auto/MPS reason mismatch, got " .. tostring(policy.reason))
end

-- cap should never exceed the actual job count regardless of RAM (jobCount=2
-- is the smallest input that still reaches the multi-job policy branches --
-- jobCount<=1 short-circuits earlier in the function for every route).
do
    local policy = resolvePolicy(baseOpts({ ramGiB = 32, jobCount = 2 }))
    assertf(policy.cap == 2,
        "32 GiB Auto/MPS with jobCount=2 expected cap=min(2,2)=2, got " .. tostring(policy.cap))
end

-- 4. Direct Kit / explicit MPS: unchanged conservative cap=1, regardless of
--    RAM -- the fix must not touch the explicit-device path at all.
for _, ram in ipairs({ 8, 16, 32 }) do
    local policy = resolvePolicy(baseOpts({ requestedDevice = "mps", ramGiB = ram }))
    local ramLabel = tostring(ram)
    assertf(policy.cap == 2, "explicit MPS policy.cap constant unexpectedly changed at ramGiB=" .. ramLabel)
    assertf(policy.sequentialMode == true,
        "explicit MPS at ramGiB=" .. ramLabel .. " must stay sequentialMode=true (cap=1 behavior)")
    assertf(policy.reason == "scheduler_mps_conservative",
        "explicit MPS reason changed at ramGiB=" .. ramLabel .. ", got " .. tostring(policy.reason))
end

-- 5. Direct Kit / CPU: existing CPU policy untouched by the MPS fix.
do
    local policy = resolvePolicy(baseOpts({ backend = "cpu", requestedDevice = "cpu", ramGiB = 8, cpuCount = 8 }))
    assertf(policy.cap == 2, "Direct Kit CPU cap unexpectedly changed, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == false, "Direct Kit CPU sequentialMode unexpectedly changed")
    assertf(policy.reason == "scheduler_dks_direct_cpu_cap2",
        "Direct Kit CPU reason unexpectedly changed, got " .. tostring(policy.reason))
end

-- 6. Normal Stems / Auto-on-MPS: unchanged (route == "normal" branch).
do
    local policy = resolvePolicy(baseOpts({ route = "normal", backend = "mps", ramGiB = 8 }))
    assertf(policy.cap == 2, "Normal Stems MPS cap unexpectedly changed, got " .. tostring(policy.cap))
    assertf(policy.sequentialMode == false, "Normal Stems MPS sequentialMode unexpectedly changed")
    assertf(policy.reason == "scheduler_normal_mps_cap2",
        "Normal Stems MPS reason unexpectedly changed, got " .. tostring(policy.reason))
end

-- 7. Kit Split (dks_extract) stage-1 / Auto-on-MPS and explicit MPS: unchanged.
do
    local autoOpts = baseOpts({ route = "dks_extract", backend = "mps", requestedDevice = "auto", ramGiB = 8 })
    local autoPolicy = resolvePolicy(autoOpts)
    assertf(autoPolicy.cap == 2,
        "Kit Split stage-1 Auto/MPS cap unexpectedly changed, got " .. tostring(autoPolicy.cap))
    assertf(autoPolicy.reason == "scheduler_dks_extract_stage1_normal_mps_cap2",
        "Kit Split stage-1 Auto/MPS reason unexpectedly changed, got " .. tostring(autoPolicy.reason))

    local explicitOpts = baseOpts({ route = "dks_extract", backend = "mps", requestedDevice = "mps", ramGiB = 8 })
    local explicitPolicy = resolvePolicy(explicitOpts)
    assertf(explicitPolicy.cap == 1,
        "Kit Split stage-1 explicit-MPS cap unexpectedly changed, got " .. tostring(explicitPolicy.cap))
    assertf(explicitPolicy.reason == "scheduler_dks_extract_mps_sequential",
        "Kit Split stage-1 explicit-MPS reason unexpectedly changed, got " .. tostring(explicitPolicy.reason))
end

-- 8. ROCm/CUDA (generic "gpu" backend) and DirectML Direct Kit paths:
--    unchanged by this MPS-only fix.
do
    local gpuPolicy = resolvePolicy(baseOpts({ backend = "gpu", requestedDevice = "cuda", ramGiB = 8 }))
    assertf(gpuPolicy.cap == 4,
        "Direct Kit GPU (ROCm/CUDA) cap unexpectedly changed, got " .. tostring(gpuPolicy.cap))
    assertf(gpuPolicy.reason == "scheduler_dks_direct_gpu_cap4",
        "Direct Kit GPU reason unexpectedly changed, got " .. tostring(gpuPolicy.reason))

    local directmlOpts = baseOpts({
        backend = "directml",
        requestedDevice = "directml",
        ramGiB = 8,
        directmlAdapterClass = "integrated",
    })
    local directmlPolicy = resolvePolicy(directmlOpts)
    assertf(directmlPolicy.cap == 1,
        "Direct Kit DirectML integrated-adapter cap unexpectedly changed, got " .. tostring(directmlPolicy.cap))
    assertf(directmlPolicy.reason == "directml_multi_track",
        "Direct Kit DirectML reason unexpectedly changed, got " .. tostring(directmlPolicy.reason))
end

print("OK: dks_direct Auto/MPS scheduler cap policy (8/16/32 GiB, explicit MPS,")
print("    CPU, Normal Stems, Kit Split, GPU/DirectML) all match expected behavior")
