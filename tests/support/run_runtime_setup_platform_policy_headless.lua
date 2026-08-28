local TARGET = "scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua"

local function assertf(condition, message)
    if not condition then error(message, 2) end
end

local function contains(messages, needle)
    needle = needle:lower()
    for _, message in ipairs(messages) do
        if message:lower():find(needle, 1, true) then return true end
    end
    return false
end

local function loadRuntime(osName, filesExist, omitRuntimeOverride)
    local module = dofile(TARGET)
    local state = { state = "unknown", prompted = false }
    local evidence = { messages = {}, mutations = 0, execs = 0, state = state }
    module.configure({
        OS = osName,
        PATH_SEP = osName == "Windows" and "\\" or "/",
        script_path = "",
        getDepState = function() return state end,
        setDepState = function() evidence.mutations = evidence.mutations + 1 end,
        setBootstrapActive = function() evidence.mutations = evidence.mutations + 1 end,
        setPythonPath = function() evidence.mutations = evidence.mutations + 1 end,
        setSeparatorScript = function() evidence.mutations = evidence.mutations + 1 end,
        setExtStateValue = function() evidence.mutations = evidence.mutations + 1 end,
        persistPythonPathFallback = function() evidence.mutations = evidence.mutations + 1 end,
        getExtStateValue = function(key)
            if key == "runtimeBase" and not omitRuntimeOverride then
                return osName == "Windows" and "C:\\STEMwerk-runtime" or "/virtual/stemwerk-runtime"
            end
            return ""
        end,
        isAbsolutePath = function(path)
            return tostring(path):match("^/") ~= nil or tostring(path):match("^%a:[/\\]") ~= nil
        end,
        fileExists = function(path)
            if type(filesExist) == "function" then return filesExist(path) end
            return filesExist == true
        end,
        canRunPython = function() return filesExist == true end,
        canRunFfmpeg = function() return filesExist == true end,
        execProcess = function()
            evidence.execs = evidence.execs + 1
            return 1, ""
        end,
        quoteArg = function(value) return '"' .. tostring(value) .. '"' end,
        showMessageBox = function(a, b)
            evidence.messages[#evidence.messages + 1] = tostring(a or "") .. "\n" .. tostring(b or "")
            return 6
        end,
        logExecResult = function() end,
    })
    local ensureWritableDir = module.ensureWritableDir
    module.ensureWritableDir = function(path)
        evidence.mutations = evidence.mutations + 1
        return ensureWritableDir(path)
    end
    return module, evidence
end

local function assertWindowsBlocked(name, configureCase, filesExist, omitRuntimeOverride)
    local module, evidence = loadRuntime("Windows", filesExist == true, omitRuntimeOverride)
    if configureCase then configureCase(module, evidence) end
    local runSetupCalls = 0
    module.runSetup = function()
        runSetupCalls = runSetupCalls + 1
        return true
    end
    local ok = module.ensureDependenciesInteractive()
    assertf(ok == false, name .. ": dependency gate must remain closed")
    assertf(runSetupCalls == 0, name .. ": M.runSetup callcount must be exactly zero")
    assertf(evidence.mutations == 0, name .. ": Windows diagnosis must not mutate filesystem/bootstrap/runtime state")
    assertf(contains(evidence.messages, "stemwerk installer"), name .. ": external-installer guidance missing")
    for _, forbidden in ipairs({ "setup/repair", "run repair", "rebuild", "stemwerk-setup.lua" }) do
        assertf(not contains(evidence.messages, forbidden), name .. ": stale in-REAPER recovery copy: " .. forbidden)
    end
    print("PASS " .. name)
end

assertWindowsBlocked("windows-dependency-failure")
assertWindowsBlocked("windows-python-missing")
assertWindowsBlocked("windows-bootstrap-failure", function(_, evidence)
    evidence.state.state = "failed"
    evidence.state.detail = "bootstrap_guard:previous_bootstrap_failed"
end)

assertWindowsBlocked("windows-torch-torchaudio-onnx-failure", function(module)
    module.isPythonAvailable = function() return true end
    module.canImportAudioSeparator = function() return true end
    module.verifyRuntimeAfterBootstrap = function()
        return false, { "torch_too_new_for_demucs", "torchaudio_missing_for_demucs", "audio_separator_missing" }
    end
end, true)

assertWindowsBlocked("windows-interactive-confirmation-never-starts-setup")
assertWindowsBlocked("windows-diagnosis-without-runtime-root-stays-read-only", nil, false, true)

do
    local module, evidence = loadRuntime("Windows", true)
    local originalRunSetup = module.runSetup
    local ok = originalRunSetup()
    assertf(ok == false, "direct Windows M.runSetup must fail closed")
    assertf(evidence.mutations == 0, "direct Windows M.runSetup must not mutate state")
    assertf(contains(evidence.messages, "stemwerk installer"), "direct Windows M.runSetup needs installer guidance")
    print("PASS windows-direct-runsetup-fails-closed")
end

do
    local module, evidence = loadRuntime("Windows", false, true)
    module.resolveRuntimePythonPath()
    assertf(evidence.mutations == 0, "Windows runtime resolution without a configured root must stay read-only")
    print("PASS windows-runtime-resolution-without-root-stays-read-only")
end

for _, osName in ipairs({ "Linux", "macOS" }) do
    local module = loadRuntime(osName, false)
    local runSetupCalls = 0
    module.verifyRuntimeAfterBootstrap = function() return false, { "python_unavailable" } end
    module.runSetup = function()
        runSetupCalls = runSetupCalls + 1
        return false
    end
    module.ensureDependenciesInteractive()
    assertf(runSetupCalls == 1, osName .. " must preserve the existing confirmed in-REAPER setup route")
    print("PASS " .. osName:lower() .. "-interactive-setup-route-preserved")
end

do
    local module, evidence = loadRuntime(nil, false)
    local ok = module.runSetup()
    assertf(ok == false and evidence.mutations == 0, "unknown OS must fail closed without adopting another platform contract")
    print("PASS unknown-platform-does-not-default-to-windows-or-unix-setup")
end

print("ALL PASS runtime-setup-platform-policy")
