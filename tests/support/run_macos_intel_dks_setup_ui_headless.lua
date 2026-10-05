-- Headless behavioral tests for the Intel-macOS Drum Kit / DKS Setup UI
-- consistency fix in STEMwerk_Setup_Internal.lua.
--
-- Product policy (already correctly enforced by the main STEMwerk.lua
-- processing GUI's intelMacDksPolicyBlocked()): Drum Kit Split is
-- unsupported on Intel macOS, supported on Apple Silicon macOS, and
-- unaffected on any Linux architecture (including Intel hardware running
-- Linux). Setup runs as its own separate REAPER script/process and cannot
-- call that main-GUI function directly, so STEMwerk_Setup_Internal.lua gets
-- its own single definition, isIntelMacDksUnsupported(), reused by every
-- Setup UI surface below instead of each re-deriving the same OS/MAC_ARCH
-- fact independently.
--
-- This dofile()s the real production script exactly like the other
-- tests/support/run_*_headless.lua harnesses -- not a reimplementation.
-- Because `OS` is computed once per load from reaper.GetOS(), and MAC_ARCH is
-- a plain global the production code reads but never sets, each scenario
-- re-dofiles the target after changing both, so every assertion runs against
-- the real, freshly-loaded production code for that OS/arch.

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

local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. TMP_ROOT .. "\"")

local function mkFixtureRuntime(name)
    local base = TMP_ROOT .. SEP .. name
    local stateDir = base .. SEP .. "state"
    local logsDir = base .. SEP .. "logs"
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. stateDir .. "\"")
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. logsDir .. "\"")
    return { base = base, runtimeState = stateDir, runtimeLogs = logsDir, venvDir = base .. SEP .. ".venv" }
end

local messageBoxCalls = {}

local function loadTargetWithPlatform(reportedOS, macArch)
    STEMWERK_SETUP_HEADLESS_TEST = true
    MAC_ARCH = macArch
    messageBoxCalls = {}
    reaper = {
        ShowMessageBox = function(text, title, _t)
            messageBoxCalls[#messageBoxCalls + 1] = { text = text, title = title }
            return 0
        end,
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
    local ok, err = pcall(dofile, TARGET)
    assertf(ok, "failed to load " .. TARGET .. " for GetOS()=" .. tostring(reportedOS)
        .. " MAC_ARCH=" .. tostring(macArch) .. ": " .. tostring(err))
    assertf(type(isIntelMacDksUnsupported) == "function", "isIntelMacDksUnsupported was not exposed as a global function")
    assertf(type(buildSetupMenuChoices) == "function", "buildSetupMenuChoices was not exposed as a global function")
    assertf(type(refreshSetupMenuChoiceLabels) == "function", "refreshSetupMenuChoiceLabels was not exposed as a global function")
    assertf(type(linuxStepLegendModel) == "function", "linuxStepLegendModel was not exposed as a global function")
    assertf(type(startLinuxSetup) == "function", "startLinuxSetup was not exposed as a global function")
end

local function idsOf(choices)
    local ids = {}
    for _, c in ipairs(choices) do
        ids[#ids + 1] = c.id
    end
    return ids
end

-- loadTargetWithPlatform's dofile() always triggers one unrelated, pre-existing
-- "non-canonical install location" notice as a top-level load side effect
-- (this test harness runs the script from a worktree path, never the
-- canonical REAPER Scripts location) -- unconditional on every platform, not
-- specific to the Intel-macOS guard under test. Every message-box assertion
-- below therefore compares growth against a baseline captured right after
-- load, not an absolute count.
local function containsId(ids, needle)
    for _, id in ipairs(ids) do
        if id == needle then return true end
    end
    return false
end

local function buildMenuChoices(runtime, state)
    local choices = buildSetupMenuChoices(runtime, state or {})
    refreshSetupMenuChoiceLabels({ choices = choices })
    return choices
end

local results = {}
local function record(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail }
end

-- --- 1: Intel macOS Setup actions: no actionable "Drum Kit Split runtime" ---

loadTargetWithPlatform("OSX64", "x86_64")
local intelLoadBaseline = #messageBoxCalls
local intelRuntime = mkFixtureRuntime("intel-choices")
local intelChoices = buildMenuChoices(intelRuntime, {})
local intelIds = idsOf(intelChoices)
record(
    "intel-macos-setup-actions-have-no-drumsep-runtime-choice",
    not containsId(intelIds, "drumsep-runtime")
        and not containsId(intelIds, "drumsep-rocm-runtime")
        and not containsId(intelIds, "drumsep-cuda-runtime")
        and not containsId(intelIds, "drumsep-directml-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)
-- repair/rebuild-venv/delete-models/delete-runtime remain: this is narrowly
-- about Drum Kit, not a broader Intel-macOS Setup lockdown.
record(
    "intel-macos-setup-actions-keep-unrelated-mutating-actions",
    containsId(intelIds, "repair") and containsId(intelIds, "rebuild-venv")
        and containsId(intelIds, "delete-models") and containsId(intelIds, "delete-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)

-- --- 2: Intel macOS Modes legend: no actionable "DrumKit CPU" -------------
--
-- compactModeSummaryLabel (the Modes legend renderer) only ever runs over
-- m.choices, so proving "drumsep-runtime" is absent from choices (above)
-- already proves "DrumKit CPU" cannot appear in the legend; this assertion
-- pins that structural guarantee directly rather than re-deriving it.
record(
    "intel-macos-modes-legend-has-no-drumkit-cpu-producing-choice",
    not containsId(intelIds, "drumsep-runtime"),
    "intel choices=" .. table.concat(intelIds, ",")
)

-- --- 3: Intel macOS progress/final presentation: step 5 is unsupported, never active/actionable ---

local labels, colors, forceNeutral = linuxStepLegendModel(true)
record("intel-macos-step5-label-says-unsupported", tostring(labels[5]):find("Unsupported", 1, true) ~= nil, labels[5])
record("intel-macos-step5-label-still-mentions-drum-kit-for-context", tostring(labels[5]):find("Drum Kit", 1, true) ~= nil, labels[5])
record(
    "intel-macos-step5-color-is-neutral-grey-not-the-warning-amber",
    colors[5][1] < 180 and colors[5][2] < 180 and colors[5][3] < 180
        and math.abs(colors[5][1] - colors[5][2]) <= 10 and math.abs(colors[5][2] - colors[5][3]) <= 10,
    "color=" .. table.concat(colors[5], ",")
)
record("intel-macos-step5-is-forced-out-of-active-completed-palette", forceNeutral[5] == true, tostring(forceNeutral[5]))
record("intel-macos-steps-1-through-4-are-unaffected", not forceNeutral[1] and not forceNeutral[2] and not forceNeutral[3] and not forceNeutral[4], "")

-- --- 4: Direct Drum Kit setup dispatch on Intel macOS: clean, no mutation ---

local dispatchRuntime = mkFixtureRuntime("intel-dispatch")
startLinuxSetup(dispatchRuntime, "/does/not/matter.py", "drumsep-runtime")
local bootstrapEnvPath = dispatchRuntime.runtimeState .. SEP .. "bootstrap.env"
local drumsepEnvPath = dispatchRuntime.runtimeState .. SEP .. "drumsep_runtime.env"
local function fileExistsPlain(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end
record("intel-macos-direct-dispatch-writes-no-state-file", not fileExistsPlain(bootstrapEnvPath) and not fileExistsPlain(drumsepEnvPath), "")
record(
    "intel-macos-direct-dispatch-shows-a-message",
    #messageBoxCalls == intelLoadBaseline + 1,
    "messageBoxCalls=" .. #messageBoxCalls .. " baseline=" .. intelLoadBaseline
)
if #messageBoxCalls == intelLoadBaseline + 1 then
    record(
        "intel-macos-direct-dispatch-message-says-unsupported-not-an-error",
        tostring(messageBoxCalls[#messageBoxCalls].text):find("not available", 1, true) ~= nil,
        tostring(messageBoxCalls[#messageBoxCalls].text)
    )
end

local dispatchRuntime2 = mkFixtureRuntime("intel-dispatch-rocm")
local beforeRocmDispatch = #messageBoxCalls
startLinuxSetup(dispatchRuntime2, "/does/not/matter.py", "drumsep-rocm-runtime")
record(
    "intel-macos-direct-dispatch-also-blocks-drumsep-rocm-runtime",
    not fileExistsPlain(dispatchRuntime2.runtimeState .. SEP .. "bootstrap.env")
        and not fileExistsPlain(dispatchRuntime2.runtimeState .. SEP .. "drumsep_runtime_rocm.env")
        and #messageBoxCalls == beforeRocmDispatch + 1,
    ""
)

-- --- 5: Apple Silicon macOS: Drum Kit actions remain available -----------

loadTargetWithPlatform("OSX64", "arm64")
record("apple-silicon-is-not-flagged-unsupported", isIntelMacDksUnsupported() == false, "")
local armRuntime = mkFixtureRuntime("arm64-choices")
local armChoices = buildMenuChoices(armRuntime, {})
local armIds = idsOf(armChoices)
record("apple-silicon-setup-actions-still-offer-drumsep-runtime", containsId(armIds, "drumsep-runtime"), "arm64 choices=" .. table.concat(armIds, ","))

local armLabels, _armColors, armForceNeutral = linuxStepLegendModel(false)
record("apple-silicon-step5-label-is-the-original-unchanged-label", armLabels[5] == "5. Drum Kit runtime", tostring(armLabels[5]))
record("apple-silicon-step5-is-not-forced-neutral", armForceNeutral[5] == false, tostring(armForceNeutral[5]))

-- Unlike the Intel scenario, arm64 is not blocked by the new guard and falls
-- through to the real (unblocked) setup flow, which may show its own
-- unrelated message for this minimal fixture (e.g. about the fake
-- separatorScript path) -- that is not what is under test here. What matters
-- is that the Intel-unsupported message specifically was never shown.
local armDispatchRuntime = mkFixtureRuntime("arm64-dispatch")
local armMessageBoxCallsBefore = #messageBoxCalls
startLinuxSetup(armDispatchRuntime, "/does/not/matter.py", "drumsep-runtime")
local armGuardMessageShown = false
for i = armMessageBoxCallsBefore + 1, #messageBoxCalls do
    if tostring(messageBoxCalls[i].text):find("not available", 1, true) then
        armGuardMessageShown = true
    end
end
record(
    "apple-silicon-direct-dispatch-is-not-blocked-by-the-intel-guard",
    not armGuardMessageShown,
    "the Intel-unsupported message must never fire on Apple Silicon"
)
record(
    "apple-silicon-direct-dispatch-writes-the-drumsep-state-file",
    fileExistsPlain(armDispatchRuntime.runtimeState .. SEP .. "drumsep_runtime.env"),
    ""
)

-- --- 6: Linux x86_64: unaffected -------------------------------------------

loadTargetWithPlatform("Other", "x86_64")
record("linux-x86_64-is-not-flagged-unsupported-by-the-macos-guard", isIntelMacDksUnsupported() == false, "")
local linuxRuntime = mkFixtureRuntime("linux-choices")
local linuxChoices = buildMenuChoices(linuxRuntime, {})
local linuxIds = idsOf(linuxChoices)
record("linux-x86_64-setup-actions-still-offer-drumsep-runtime", containsId(linuxIds, "drumsep-runtime"), "linux choices=" .. table.concat(linuxIds, ","))

local linuxLabels, _linuxColors, linuxForceNeutral = linuxStepLegendModel(false)
record("linux-x86_64-step5-label-is-the-original-unchanged-label", linuxLabels[5] == "5. Drum Kit runtime", tostring(linuxLabels[5]))
record("linux-x86_64-step5-is-not-forced-neutral", linuxForceNeutral[5] == false, tostring(linuxForceNeutral[5]))

-- --- Windows: unaffected (sanity: isIntelMacDksUnsupported must require OS=="macOS") ---

loadTargetWithPlatform("Win64", "x86_64")
record("windows-is-not-flagged-unsupported-by-the-macos-guard-even-with-x86_64-arch", isIntelMacDksUnsupported() == false, "")

-- --- Report ------------------------------------------------------------------

local failed = 0
for _, r in ipairs(results) do
    if r.ok then
        print("PASS " .. r.name)
    else
        failed = failed + 1
        print("FAIL " .. r.name .. (r.detail ~= "" and (": " .. tostring(r.detail)) or ""))
    end
end

os.execute((IS_WINDOWS and "rmdir /s /q " or "rm -rf ") .. "\"" .. TMP_ROOT .. "\"" .. (IS_WINDOWS and "" or " 2>/dev/null"))

if failed > 0 then
    error(tostring(failed) .. " of " .. #results .. " headless Intel-macOS DKS Setup UI tests failed", 0)
end
print("All " .. #results .. " headless Intel-macOS DKS Setup UI tests passed.")
