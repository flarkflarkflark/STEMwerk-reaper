-- Headless behavioral tests for the 2.3.1.1 Setup UX/installer-policy
-- cleanup in STEMwerk_Setup_Internal.lua:
--   1) Windows: startExistingRuntimeSetupMenu must build exactly the five
--      allowed read-only choices (verify, support-bundle, open-logs,
--      open-runtime, cancel) -- no Repair, Rebuild venv, or DrumSep
--      CUDA/DirectML runtime installs.
--   2) Linux: the "drumsep-runtime" choice must be labeled and summarized
--      according to what capabilities.env actually evidences (CPU / CUDA
--      GPU / neutral-unknown), and "drumsep-rocm-runtime" must only appear
--      when ROCm hardware evidence (TORCH_HIP) is present.
--   3) macOS: the same choices-list code path must produce byte-identical
--      output to before this slice (generic "Drum Kit Split runtime"
--      label, "DrumKit CPU" compact summary, no OS-specific gating change).
--
-- This dofile()s the real production script exactly like the other
-- tests/support/run_*_headless.lua harnesses. Because `OS` is computed once
-- per load from reaper.GetOS(), each scenario below re-dofiles the target
-- after changing the GetOS mock, so every assertion runs against the real,
-- freshly-loaded production choices-list/label code for that OS -- not a
-- reimplementation.

local SEP = package.config:sub(1, 1)
local IS_WINDOWS = SEP == "\\"

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
local TARGET = REPO_ROOT .. "/scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"

local function mkTempDir(suffix)
    local base = os.getenv("TMPDIR") or "/tmp"
    local dir = base .. "/stemwerk-setup-ui-policy-2311-" .. tostring(suffix) .. "-" .. tostring(os.time()) .. tostring(math.random(1, 999999))
    os.execute("mkdir -p " .. "'" .. dir .. "'")
    return dir
end

local function writeFile(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function loadTargetWithOS(reportedOS, testHooks)
    STEMWERK_SETUP_HEADLESS_TEST = true
    STEMWERK_SETUP_TEST_HOOKS = testHooks or {}
    reaper = {
        ShowMessageBox = function() return 0 end,
        GetOS = function() return reportedOS end,
        GetExtState = function() return "" end,
        SetExtState = function() end,
        HasExtState = function() return false end,
        DeleteExtState = function() end,
        ShowConsoleMsg = function() end,
        defer = function() end,
        GetResourcePath = function() return "/tmp" end,
        get_action_context = function() return "", "" end,
    }
    gfx = {
        init = function() end,
        mouse_wheel = 0,
        mouse_cap = 0,
        w = 1000,
        h = 700,
    }
    local ok, err = pcall(dofile, TARGET)
    assertf(ok, "failed to load " .. TARGET .. " for GetOS()=" .. tostring(reportedOS) .. ": " .. tostring(err))
    assertf(type(buildSetupMenuChoices) == "function", "buildSetupMenuChoices was not exposed as a global function")
    assertf(type(refreshSetupMenuChoiceLabels) == "function", "refreshSetupMenuChoiceLabels was not exposed as a global function")
    assertf(type(resolveLinuxDrumsepGpuCapability) == "function", "resolveLinuxDrumsepGpuCapability was not exposed as a global function")
    assertf(type(verifyExistingSetup) == "function", "verifyExistingSetup was not exposed as a global function")
    assertf(type(startExistingRuntimeSetupMenu) == "function", "startExistingRuntimeSetupMenu was not exposed as a global function")
end

local function buildMenuChoices(runtimeStateDir, state)
    local runtime = {
        runtimeState = runtimeStateDir,
        runtimeLogs = runtimeStateDir,
        base = runtimeStateDir,
    }
    local choices = buildSetupMenuChoices(runtime, state)
    refreshSetupMenuChoiceLabels({ choices = choices })
    return choices
end

-- Finding 2 (2.3.1.1 second adversarial review): builds a state table
-- carrying invocation-local CURRENT_PROBE_* evidence, exactly as
-- startExistingRuntimeSetupMenu merges it in from CURRENT_LINUX_PROBE after
-- a real probe has run in the current process -- this is NOT read from or
-- written to any file; it exists only for the lifetime of one Setup
-- invocation. ok defaults to "true" (a probe genuinely completed).
local function currentProbeState(overrides)
    local state = {
        CURRENT_PROBE_OK = "true",
        CURRENT_PROBE_PROFILE = "linux-cpu",
        CURRENT_PROBE_BACKEND = "cpu",
        CURRENT_PROBE_CUDA_AVAILABLE = "false",
        CURRENT_PROBE_CUDA_COUNT = "0",
        CURRENT_PROBE_TORCH_HIP = "",
    }
    for k, v in pairs(overrides or {}) do
        state[k] = v
    end
    return state
end

local function idsOf(choices)
    local ids = {}
    for _, c in ipairs(choices) do
        ids[#ids + 1] = c.id
    end
    return ids
end

local function containsId(choices, id)
    for _, c in ipairs(choices) do
        if c.id == id then return true, c end
    end
    return false, nil
end

local function joined(list)
    return table.concat(list, ", ")
end

-- ===========================================================================
-- 1) Windows: only the five allowed read-only actions.
-- ===========================================================================
local function testWindowsChoicesAreExactlyTheAllowedFive()
    loadTargetWithOS("Win64")
    local dir = mkTempDir("windows")
    local choices = buildMenuChoices(dir)
    local ids = idsOf(choices)
    local expected = { verify = true, ["support-bundle"] = true, ["open-logs"] = true, ["open-runtime"] = true, cancel = true }
    local forbidden = { "repair", "rebuild-venv", "drumsep-cuda-runtime", "drumsep-directml-runtime",
        "drumsep-runtime", "drumsep-rocm-runtime", "delete-models", "delete-runtime" }
    assertf(#ids == 5, "Windows Setup menu must render exactly 5 choices, got " .. #ids .. ": " .. joined(ids))
    for _, id in ipairs(ids) do
        assertf(expected[id], "unexpected Windows Setup choice id: " .. tostring(id) .. " (full list: " .. joined(ids) .. ")")
    end
    for _, id in ipairs(forbidden) do
        local present = containsId(choices, id)
        assertf(not present, "Windows Setup menu must never offer mutating choice: " .. id)
    end
    print("PASS windows-choices-are-exactly-the-allowed-five")
end

-- ===========================================================================
-- Finding 7 (2.3.1.1 adversarial review): the Windows fail-closed guard,
-- executably tested against the real production function -- not a second,
-- test-only dispatch implementation. startWindowsSetup is called directly,
-- exactly as existingRuntimeSetupMenuTick's real dispatch calls it, for
-- every id buildSetupMenuChoices could ever offer on Windows plus a
-- would-be-mutating id that must never reach production code either way.
-- ===========================================================================
local function loadWindowsTargetCapturingMessages()
    STEMWERK_SETUP_HEADLESS_TEST = true
    local messages = {}
    reaper = {
        ShowMessageBox = function(text, title, kind)
            messages[#messages + 1] = { text = text, title = title, kind = kind }
            return 0
        end,
        GetOS = function() return "Win64" end,
        GetExtState = function() return "" end,
        SetExtState = function() end,
        HasExtState = function() return false end,
        DeleteExtState = function() end,
        ShowConsoleMsg = function() end,
        defer = function() end,
        GetResourcePath = function() return "/tmp" end,
        get_action_context = function() return "", "" end,
    }
    gfx = { init = function() end, mouse_wheel = 0, mouse_cap = 0, w = 1000, h = 700 }
    local ok, err = pcall(dofile, TARGET)
    assertf(ok, "failed to load " .. TARGET .. " for GetOS()=Win64: " .. tostring(err))
    assertf(type(startWindowsSetup) == "function", "startWindowsSetup was not exposed as a global function")
    return messages
end

local function dirIsEmptyOrMissing(dir)
    local p = io.popen and io.popen('ls -A "' .. dir .. '" 2>/dev/null')
    if not p then return true end
    local out = p:read("*a") or ""
    p:close()
    return out:gsub("%s+", "") == ""
end

local function testWindowsFailClosedGuardRefusesEveryMutatingModeAndTouchesNothing()
    local messages = loadWindowsTargetCapturingMessages()
    local dir = mkTempDir("windows-guard")
    local runtime = { runtimeState = dir .. "/state", runtimeLogs = dir .. "/logs", base = dir }
    -- Every mode string a mutating menu choice id could ever pass, plus an
    -- arbitrary/unknown mode string (defense in depth: even something no
    -- real menu choice produces must still be refused, not default to a
    -- mutating action).
    local forbiddenModes = {
        "repair", "rebuild-venv", "drumsep-runtime", "drumsep-cuda-runtime",
        "drumsep-rocm-runtime", "drumsep-directml-runtime", "ready-to-go-verify",
        "some-unexpected-mode",
    }
    for _, mode in ipairs(forbiddenModes) do
        local before = #messages
        local result = startWindowsSetup(runtime, "/fake/separator.py", mode, false)
        assertf(result == false, "startWindowsSetup(mode=" .. mode .. ") on Windows must return false, got " .. tostring(result))
        assertf(#messages == before + 1, "startWindowsSetup(mode=" .. mode .. ") must show exactly one message, showed " .. tostring(#messages - before))
        local msg = messages[#messages]
        assertf(msg.text:find("STEMwerk installer", 1, true) ~= nil,
            "the refusal message for mode=" .. mode .. " must reference the external STEMwerk installer, got: " .. tostring(msg.text))
        assertf(msg.text:find("Nothing was changed", 1, true) ~= nil,
            "the refusal message for mode=" .. mode .. " must state nothing was changed, got: " .. tostring(msg.text))
    end
    -- No runtime path, bootstrap process, guard file, or delete action was
    -- ever reached: the guard returns before ensureDir/isBootstrapBusy/
    -- process-launch, so neither directory this runtime points at should
    -- exist at all.
    assertf(dirIsEmptyOrMissing(runtime.runtimeState), "the guard must never create/touch runtimeState: " .. runtime.runtimeState)
    assertf(dirIsEmptyOrMissing(runtime.runtimeLogs), "the guard must never create/touch runtimeLogs: " .. runtime.runtimeLogs)
    print("PASS windows-fail-closed-guard-refuses-every-mutating-mode-and-touches-nothing")
end

local function testWindowsFailClosedGuardDoesNotBlockTheFiveAllowedActions()
    -- Re-proves, from within this same Finding-7-focused fixture, that the
    -- five read-only actions are still the ones buildSetupMenuChoices
    -- offers on Windows, and that none of them is startWindowsSetup's
    -- forbidden dispatch branch (chosen == "repair" or "rebuild-venv" or
    -- any drumsep-* id) -- i.e. the guard's existence never suppresses the
    -- legitimately allowed actions, it only refuses the mutating ones.
    loadTargetWithOS("Win64")
    local dir = mkTempDir("windows-allowed")
    local choices = buildMenuChoices(dir)
    local ids = idsOf(choices)
    local allowed = { verify = true, ["support-bundle"] = true, ["open-logs"] = true, ["open-runtime"] = true, cancel = true }
    local mutatingDispatchIds = { repair = true, ["rebuild-venv"] = true, ["drumsep-runtime"] = true,
        ["drumsep-cuda-runtime"] = true, ["drumsep-rocm-runtime"] = true, ["drumsep-directml-runtime"] = true }
    assertf(#ids == 5, "expected exactly 5 allowed Windows choices, got " .. #ids .. ": " .. joined(ids))
    for _, id in ipairs(ids) do
        assertf(allowed[id], "unexpected Windows choice id reaching the menu: " .. tostring(id))
        assertf(not mutatingDispatchIds[id], "an allowed Windows choice id must never also be a mutating dispatch id: " .. tostring(id))
    end
    print("PASS windows-fail-closed-guard-does-not-block-the-five-allowed-actions")
end

local function testLinuxAndMacosDispatchNotBlockedByWindowsGuard()
    -- The Windows guard lives entirely inside startWindowsSetup, which
    -- production dispatch only ever calls when OS == "Windows" (see
    -- existingRuntimeSetupMenuTick's `if OS == "Windows" then
    -- startWindowsSetup(...) else startLinuxSetup(...) end`). Proving
    -- Linux/macOS dispatch is unaffected means proving buildSetupMenuChoices
    -- keeps offering the real mutating choices there (already covered
    -- extensively above/elsewhere) and that startWindowsSetup itself is
    -- simply never in that call path for those OSes.
    for _, os_value in ipairs({ "Other", "OSX64" }) do
        loadTargetWithOS(os_value)
        local dir = mkTempDir("dispatch-" .. os_value)
        local choices = buildMenuChoices(dir)
        assertf(containsId(choices, "repair"), "Linux/macOS must still offer repair, unaffected by the Windows guard (OS=" .. os_value .. ")")
        assertf(containsId(choices, "rebuild-venv"), "Linux/macOS must still offer rebuild-venv, unaffected by the Windows guard (OS=" .. os_value .. ")")
    end
    print("PASS linux-and-macos-dispatch-not-blocked-by-windows-guard")
end

-- ===========================================================================
-- Finding 2 (2.3.1.1 SECOND adversarial review): capability labels only
-- after an actual probe in the SAME Setup invocation. Every scenario below
-- drives the real resolveLinuxDrumsepGpuCapability(runtime, state) /
-- buildSetupMenuChoices(runtime, state) production route with a `state`
-- table shaped exactly like startExistingRuntimeSetupMenu's merge of
-- CURRENT_LINUX_PROBE (invocation-local, never persisted) -- never by
-- writing capabilities.env alone. capabilities.env, when written in a
-- scenario, models PERSISTED state that may only support, never replace,
-- the current-invocation probe evidence.
-- ===========================================================================

local function testLinuxRocmMachineShowsCpuPlusRocm()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-rocm")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-rocm",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "6.4.43483-a187df25c",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "rocm", "expected capability 'rocm' for a current, schema-conformant ROCm probe, got " .. tostring(cap))

    local choices = buildMenuChoices(dir, state)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    local hasRocm = containsId(choices, "drumsep-rocm-runtime")
    local hasCudaId = containsId(choices, "drumsep-cuda-runtime")
    assertf(hasDrumsep, "expected drumsep-runtime choice to be present")
    assertf(hasRocm, "expected drumsep-rocm-runtime choice to be present on ROCm-capable hardware")
    assertf(not hasCudaId, "Windows-only drumsep-cuda-runtime id must never appear on Linux")
    assertf(drumsepChoice.label == "Drum Kit Split CPU runtime",
        "on ROCm hardware, drumsep-runtime must be labeled CPU (ROCm gets its own separate choice), got: " .. tostring(drumsepChoice.label))
    print("PASS linux-rocm-machine-shows-cpu-plus-rocm")
end

local function testLinuxCudaMachineShowsCudaOnlyNoRocm()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-cuda")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-cuda",
        CURRENT_PROBE_BACKEND = "cuda",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "cuda", "expected capability 'cuda' for a current CUDA probe, got " .. tostring(cap))

    local choices = buildMenuChoices(dir, state)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    local hasRocm = containsId(choices, "drumsep-rocm-runtime")
    assertf(hasDrumsep, "expected drumsep-runtime choice to be present")
    assertf(not hasRocm, "NVIDIA/CUDA machine must not show the ROCm choice")
    assertf(drumsepChoice.label == "Drum Kit Split CUDA GPU runtime",
        "on CUDA hardware, drumsep-runtime must be labeled CUDA GPU, got: " .. tostring(drumsepChoice.label))
    print("PASS linux-cuda-machine-shows-cuda-only-no-rocm")
end

local function testLinuxCpuOnlyMachineShowsCpuOnly()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-cpu")
    local state = currentProbeState({})
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "cpu", "expected capability 'cpu' for a current CPU-only probe, got " .. tostring(cap))

    local choices = buildMenuChoices(dir, state)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    local hasRocm = containsId(choices, "drumsep-rocm-runtime")
    assertf(hasDrumsep, "expected drumsep-runtime choice to be present")
    assertf(not hasRocm, "CPU-only machine must not show the ROCm choice")
    assertf(drumsepChoice.label == "Drum Kit Split CPU runtime",
        "on CPU-only hardware, drumsep-runtime must be labeled CPU, got: " .. tostring(drumsepChoice.label))
    print("PASS linux-cpu-only-machine-shows-cpu-only")
end

-- Scenario 4/8: no current probe at all (a freshly (re-)opened Setup window,
-- exactly as if CURRENT_LINUX_PROBE was nil and startExistingRuntimeSetupMenu
-- never merged anything in) + a seemingly valid OLD ROCm capabilities.env on
-- disk -> neutral. The old invocation-local flag from any PRIOR probe must
-- never be reused; a `state` table without CURRENT_PROBE_* fields is exactly
-- what a truly fresh invocation (or a reopen before any new probe) looks
-- like, and must never fall back to trusting the persisted file alone.
local function testLinuxNoCurrentProbeWithOldRocmFilesIsNeutral()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-no-probe-old-rocm")
    writeFile(dir .. "/capabilities.env",
        "CAP_VERSION=1\nPROFILE=linux-rocm\nBACKEND=rocm\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=6.4.43483-a187df25c\n")
    -- No capabilities.env written at all is also still neutral.
    local capNoFile = resolveLinuxDrumsepGpuCapability({ runtimeState = mkTempDir("linux-no-probe-no-file") })
    assertf(capNoFile == "unknown", "no current probe and no persisted evidence must be neutral, got " .. tostring(capNoFile))
    -- A plain freshly-read bootstrap.env-shaped state (e.g. only
    -- STEMWERK_SETUP_VERSION/STATUS, as startExistingRuntimeSetupMenu builds
    -- before any merge) carries no CURRENT_PROBE_* fields at all.
    local freshlyOpenedState = { STATUS = "ok", STEMWERK_SETUP_VERSION = "2.3.1.1" }
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, freshlyOpenedState)
    assertf(cap == "unknown", "an old, otherwise-valid ROCm capabilities.env must not be trusted without a current-invocation probe, got " .. tostring(cap))
    local choices = buildMenuChoices(dir, freshlyOpenedState)
    assertf(not containsId(choices, "drumsep-rocm-runtime"), "no current probe must never dispatch to the ROCm-specific choice")
    print("PASS linux-no-current-probe-with-old-rocm-files-is-neutral")
end

-- Scenario 5: the current probe itself failed/did not complete -> neutral,
-- regardless of what backend fields happen to be populated.
local function testLinuxCurrentProbeFailedIsNeutral()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-probe-failed")
    local state = currentProbeState({
        CURRENT_PROBE_OK = "false",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "6.4.43483-a187df25c",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "CURRENT_PROBE_OK=false must always be neutral even with otherwise-valid-looking fields, got " .. tostring(cap))
    print("PASS linux-current-probe-failed-is-neutral")
end

-- Scenario 6: current-invocation probe and persisted capabilities.env
-- actively disagree -> neutral, never silently prefer one.
local function testLinuxCurrentProbeConflictsWithPersistedStateIsNeutral()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-probe-conflict")
    -- Persisted file says cuda (from some earlier invocation)...
    writeFile(dir .. "/capabilities.env",
        "CAP_VERSION=1\nPROFILE=linux-cuda\nBACKEND=cuda\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=\n")
    -- ...but THIS invocation's own live probe says rocm.
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-rocm",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "6.4.43483-a187df25c",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "a current probe conflicting with persisted capabilities.env must be neutral, got " .. tostring(cap))
    print("PASS linux-current-probe-conflicts-with-persisted-state-is-neutral")
end

-- Scenario 7 (repeat, explicit): current, valid, and CONSISTENT with
-- persisted state -> the persisted file supports (does not block) the
-- correct current-invocation label and dispatch.
local function testLinuxCurrentProbeConsistentWithPersistedStateDispatchesCorrectly()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-probe-consistent")
    writeFile(dir .. "/capabilities.env",
        "CAP_VERSION=1\nPROFILE=linux-cuda\nBACKEND=cuda\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=\n")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-cuda",
        CURRENT_PROBE_BACKEND = "cuda",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "cuda", "a current probe consistent with persisted state must still dispatch correctly, got " .. tostring(cap))
    local choices = buildMenuChoices(dir, state)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    assertf(hasDrumsep and drumsepChoice.label == "Drum Kit Split CUDA GPU runtime",
        "expected the CUDA label to be dispatched, got: " .. tostring(drumsepChoice and drumsepChoice.label))
    print("PASS linux-current-probe-consistent-with-persisted-state-dispatches-correctly")
end

-- ===========================================================================
-- Fail-neutral schema/evidence checks (carried over from the first review's
-- Finding 4, now expressed against CURRENT_PROBE_* invocation-local
-- evidence instead of capabilities.env alone).
-- ===========================================================================

local function testLinuxTorchHipFalseNeverClaimsRocm()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-hip-false")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-rocm",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "false",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "TORCH_HIP=false must never be accepted as ROCm evidence, got " .. tostring(cap))
    local choices = buildMenuChoices(dir, state)
    assertf(not containsId(choices, "drumsep-rocm-runtime"), "a neutral capability must not show the ROCm choice")
    print("PASS linux-torch-hip-false-never-claims-rocm")
end

local function testLinuxTorchHipZeroNeverClaimsRocm()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-hip-zero")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-rocm",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "0",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "TORCH_HIP=0 must never be accepted as ROCm evidence, got " .. tostring(cap))
    print("PASS linux-torch-hip-zero-never-claims-rocm")
end

local function testLinuxCorruptVersionNeverClaimsRocm()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-hip-corrupt")
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "linux-rocm",
        CURRENT_PROBE_BACKEND = "rocm",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
        CURRENT_PROBE_TORCH_HIP = "not-a-version",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "a corrupt/non-version TORCH_HIP must never be accepted as ROCm evidence, got " .. tostring(cap))
    print("PASS linux-corrupt-version-never-claims-rocm")
end

local function testLinuxPartialStateIsNeutral()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-partial")
    -- CURRENT_PROBE_OK missing/not exactly "true" (e.g. a probe that never
    -- ran, or an incompletely populated invocation-local table) -- must
    -- never be treated as CPU-only just because CUDA_AVAILABLE happens to be
    -- present and false.
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, { CURRENT_PROBE_CUDA_AVAILABLE = "false" })
    assertf(cap == "unknown", "a partial/incomplete current-probe state missing CURRENT_PROBE_OK must fall back to unknown, got " .. tostring(cap))
    print("PASS linux-partial-state-is-neutral")
end

local function testLinuxForeignProfileIsNeutral()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-foreign-profile")
    -- Otherwise schema-conformant-looking current-probe fields, but PROFILE
    -- belongs to a different OS/profile entirely -- must not be trusted as
    -- Linux hardware evidence.
    local state = currentProbeState({
        CURRENT_PROBE_PROFILE = "windows-cuda",
        CURRENT_PROBE_BACKEND = "cuda",
        CURRENT_PROBE_CUDA_AVAILABLE = "true",
        CURRENT_PROBE_CUDA_COUNT = "1",
    })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "current-probe evidence from a different OS/profile must fall back to unknown, got " .. tostring(cap))
    print("PASS linux-foreign-profile-is-neutral")
end

local function testLinuxCorrectNeutralFallbackDispatchesToNoGpuChoice()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-neutral-dispatch")
    local state = currentProbeState({ CURRENT_PROBE_BACKEND = "metal" })
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir }, state)
    assertf(cap == "unknown", "an out-of-domain CURRENT_PROBE_BACKEND must fall back to unknown, got " .. tostring(cap))
    local choices = buildMenuChoices(dir, state)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    assertf(hasDrumsep, "expected drumsep-runtime choice to remain present even on a neutral read")
    assertf(not containsId(choices, "drumsep-rocm-runtime"), "a neutral capability must never dispatch to the ROCm-specific choice")
    assertf(not drumsepChoice.label:match("CUDA") and not drumsepChoice.label:match("CPU"),
        "a neutral capability must not claim CPU or CUDA in the dispatched label, got: " .. tostring(drumsepChoice.label))
    print("PASS linux-correct-neutral-fallback-dispatches-to-no-gpu-choice")
end

local function testLinuxUncertainCapabilityUsesNeutralFallback()
    loadTargetWithOS("Other")
    local dir = mkTempDir("linux-unknown")
    -- No state at all -- capability is genuinely unknown.
    local cap = resolveLinuxDrumsepGpuCapability({ runtimeState = dir })
    assertf(cap == "unknown", "expected capability 'unknown' with no state at all, got " .. tostring(cap))

    local choices = buildMenuChoices(dir)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    local hasRocm = containsId(choices, "drumsep-rocm-runtime")
    assertf(hasDrumsep, "expected drumsep-runtime choice to be present")
    assertf(not hasRocm, "unproven capability must not show the ROCm-specific choice")
    assertf(not drumsepChoice.label:match("CUDA") and not drumsepChoice.label:match("CPU"),
        "with no capability evidence, the label must not claim CPU or CUDA, got: " .. tostring(drumsepChoice.label))
    print("PASS linux-uncertain-capability-uses-neutral-fallback")
end

-- ===========================================================================
-- 6) macOS: unaffected -- same generic label/behavior as before this slice.
-- ===========================================================================
local function testMacosChoicesAndLabelsAreUnchanged()
    loadTargetWithOS("OSX64")
    local dir = mkTempDir("macos")
    local choices = buildMenuChoices(dir)
    local hasDrumsep, drumsepChoice = containsId(choices, "drumsep-runtime")
    local hasRocm = containsId(choices, "drumsep-rocm-runtime")
    local hasRepair = containsId(choices, "repair")
    local hasRebuildVenv = containsId(choices, "rebuild-venv")
    assertf(hasDrumsep, "macOS must still offer drumsep-runtime")
    assertf(not hasRocm, "macOS must never offer the Linux-only ROCm choice")
    assertf(hasRepair and hasRebuildVenv, "macOS Repair/Rebuild venv must remain unaffected by the Windows policy change")
    assertf(drumsepChoice.label == "Drum Kit Split runtime",
        "macOS drumsep-runtime label must stay the original generic text, got: " .. tostring(drumsepChoice.label))
    assertf(drumsepChoice.linuxGpuCapability == nil,
        "macOS choices must never be tagged with a Linux GPU capability")
    print("PASS macos-choices-and-labels-are-unchanged")
end

-- ===========================================================================
-- Final review Finding 1: full production-route probe lifecycle. These cases
-- enter through verifyExistingSetup(), let that function execute its real
-- probe/reconciliation path, and obtain choices from the real
-- startExistingRuntimeSetupMenu() -> buildSetupMenuChoices() route. The only
-- test seam replaces the external device subprocess; no CURRENT_PROBE_* state
-- is constructed by the test.
-- ===========================================================================

local function probeOutput(backend)
    if backend == "cuda" then
        return 'STEMWERK_ENV_JSON {"cuda_available":true,"cuda_count":1,"torch_hip":null}\n'
            .. 'STEMWERK_CUDA_DEVICE\t0\tNVIDIA Test GPU\n'
    end
    if backend == "rocm" then
        return 'STEMWERK_ENV_JSON {"cuda_available":true,"cuda_count":1,"torch_hip":"6.4.0"}\n'
            .. 'STEMWERK_CUDA_DEVICE\t0\tAMD Test GPU\n'
    end
    return 'STEMWERK_ENV_JSON {"cuda_available":false,"cuda_count":0,"torch_hip":null}\n'
end

local function routeChoiceCapability(choices)
    local _, choice = containsId(choices, "drumsep-runtime")
    return choice and choice.linuxGpuCapability or nil, containsId(choices, "drumsep-rocm-runtime")
end

local function runProbeRoute(sequence, persistedCapabilities)
    local dir = mkTempDir("probe-route")
    if persistedCapabilities then
        writeFile(dir .. "/capabilities.env", persistedCapabilities)
    end
    local call = 0
    local sawClearedBeforeEveryProbe = true
    local hooks = {}
    hooks.probeRuntimeDevices = function()
        call = call + 1
        assertf(type(hooks.getCurrentLinuxProbe) == "function", "production did not publish the namespaced probe-state observer")
        if hooks.getCurrentLinuxProbe() ~= nil then
            sawClearedBeforeEveryProbe = false
        end
        local item = sequence[call]
        assertf(item ~= nil, "unexpected probe call " .. tostring(call))
        if item.kind == "exception" then error("synthetic probe exception") end
        if item.kind == "failure" then return nil, 1, "device_probe_failed" end
        if item.kind == "partial" then
            return 'STEMWERK_ENV_JSON {"cuda_available":true,"torch_hip":null}\n', 0, nil
        end
        return probeOutput(item.backend), 0, nil
    end
    loadTargetWithOS("Other", hooks)
    local runtime = {
        runtimeState = dir,
        runtimeLogs = dir,
        base = dir,
        venvDir = dir .. "/.venv",
    }
    for _ = 1, #sequence do
        local ok, err = pcall(verifyExistingSetup, runtime, "/synthetic/separator.py")
        assertf(ok, "verifyExistingSetup must contain probe exceptions and continue fail-neutral: " .. tostring(err))
    end
    local choices = startExistingRuntimeSetupMenu(runtime, "/synthetic/separator.py")
    assertf(type(choices) == "table", "startExistingRuntimeSetupMenu must return its real production choices for route verification")
    return choices, hooks, sawClearedBeforeEveryProbe, call
end

local function testRealProbeRoutePublishesOnlyCompleteCurrentEvidence()
    for _, backend in ipairs({ "cuda", "rocm", "cpu" }) do
        local choices, _, cleared, calls = runProbeRoute({ { kind = "success", backend = backend } })
        local capability, hasRocm = routeChoiceCapability(choices)
        local expectedChoiceCapability = backend == "rocm" and "cpu" or backend
        assertf(capability == expectedChoiceCapability,
            "real route expected " .. expectedChoiceCapability .. " menu capability for " .. backend .. ", got " .. tostring(capability))
        assertf(hasRocm == (backend == "rocm"), "ROCm choice presence did not match the real current probe")
        assertf(cleared and calls == 1, "probe state must be nil immediately before the real probe call")
    end
    print("PASS real-probe-route-publishes-cuda-rocm-cpu-only-after-validation")
end

local function testRealProbeRouteNeverReusesEarlierSuccess()
    for _, second in ipairs({ "failure", "exception", "partial" }) do
        local choices, _, cleared = runProbeRoute({
            { kind = "success", backend = "rocm" },
            { kind = second },
        })
        local capability, hasRocm = routeChoiceCapability(choices)
        assertf(capability == "unknown" and not hasRocm,
            "success followed by " .. second .. " must produce neutral choices, got " .. tostring(capability))
        assertf(cleared, "old probe evidence was still visible while the second probe ran")
    end
    print("PASS real-probe-route-success-then-failure-exception-partial-is-neutral")
end

local function testRealProbeRouteConsecutiveSuccessAndPersistentCrosschecks()
    local changed = runProbeRoute({
        { kind = "success", backend = "rocm" },
        { kind = "success", backend = "cuda" },
    })
    assertf(routeChoiceCapability(changed) == "cuda", "second successful probe must atomically replace the first backend")

    local staleRocm = "PROFILE=linux-rocm\nBACKEND=rocm\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=6.4.0\n"
    local cpuChoices = runProbeRoute({ { kind = "success", backend = "cpu" } }, staleRocm)
    assertf(routeChoiceCapability(cpuChoices) == "unknown", "persisted ROCm versus current CPU must remain neutral")

    local staleCuda = "PROFILE=linux-cuda\nBACKEND=cuda\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=null\n"
    local failedChoices = runProbeRoute({ { kind = "failure" } }, staleCuda)
    assertf(routeChoiceCapability(failedChoices) == "unknown", "persisted CUDA must not replace a failed current probe")
    print("PASS real-probe-route-replaces-success-and-keeps-persisted-state-crosscheck-only")
end

local function testRealProbeRouteConsumesEvidenceOnMenuOpen()
    local dir = mkTempDir("probe-route-consume")
    local hooks = { probeRuntimeDevices = function() return probeOutput("cuda"), 0, nil end }
    loadTargetWithOS("Other", hooks)
    local runtime = { runtimeState = dir, runtimeLogs = dir, base = dir, venvDir = dir .. "/.venv" }
    verifyExistingSetup(runtime, "/synthetic/separator.py")
    local first = startExistingRuntimeSetupMenu(runtime, "/synthetic/separator.py")
    local second = startExistingRuntimeSetupMenu(runtime, "/synthetic/separator.py")
    assertf(routeChoiceCapability(first) == "cuda", "first menu after the current Check must use its current evidence")
    assertf(routeChoiceCapability(second) == "unknown", "reopening without a new Check must not reuse consumed evidence")
    print("PASS real-probe-route-menu-reopen-without-new-check-is-neutral")
end

if IS_WINDOWS then
    print("SKIP headless Setup UI policy coverage requires a POSIX path environment")
    os.exit(0)
end

testWindowsChoicesAreExactlyTheAllowedFive()
testWindowsFailClosedGuardRefusesEveryMutatingModeAndTouchesNothing()
testWindowsFailClosedGuardDoesNotBlockTheFiveAllowedActions()
testLinuxAndMacosDispatchNotBlockedByWindowsGuard()
testLinuxRocmMachineShowsCpuPlusRocm()
testLinuxCudaMachineShowsCudaOnlyNoRocm()
testLinuxCpuOnlyMachineShowsCpuOnly()
testLinuxNoCurrentProbeWithOldRocmFilesIsNeutral()
testLinuxCurrentProbeFailedIsNeutral()
testLinuxCurrentProbeConflictsWithPersistedStateIsNeutral()
testLinuxCurrentProbeConsistentWithPersistedStateDispatchesCorrectly()
testLinuxTorchHipFalseNeverClaimsRocm()
testLinuxTorchHipZeroNeverClaimsRocm()
testLinuxCorruptVersionNeverClaimsRocm()
testLinuxPartialStateIsNeutral()
testLinuxForeignProfileIsNeutral()
testLinuxCorrectNeutralFallbackDispatchesToNoGpuChoice()
testLinuxUncertainCapabilityUsesNeutralFallback()
testMacosChoicesAndLabelsAreUnchanged()
testRealProbeRoutePublishesOnlyCompleteCurrentEvidence()
testRealProbeRouteNeverReusesEarlierSuccess()
testRealProbeRouteConsecutiveSuccessAndPersistentCrosschecks()
testRealProbeRouteConsumesEvidenceOnMenuOpen()

print("ALL PASS run_setup_ui_policy_2311_headless")
