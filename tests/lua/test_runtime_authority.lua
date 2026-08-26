-- Regression tests for issue #110: verified runtime state must stay
-- authoritative for interpreter selection across a transient probe failure,
-- and must not be silently replaced by an unrelated fallback interpreter.
--
-- Pure Lua harness against the real STEMwerk_Runtime_Setup.lua module via
-- its existing M.configure(context) dependency-injection seam. Run with:
--   lua tests/lua/test_runtime_authority.lua

local isWindows = package.config:sub(1, 1) == "\\"
local sep = isWindows and "\\" or "/"

local passCount, failCount = 0, 0
local function check(name, ok, detail)
    if ok then
        passCount = passCount + 1
        print("PASS " .. name)
    else
        failCount = failCount + 1
        print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------------
-- Temp world: a fake runtime base with a real state/ dir so capabilities.env
-- and bootstrap.env can be read with genuine io.open, exactly like production.
-- ---------------------------------------------------------------------
local function mktemp()
    local base = os.tmpname()
    os.remove(base)
    if isWindows then os.execute('mkdir "' .. base .. '" 2>nul') else os.execute('mkdir -p "' .. base .. '"') end
    return base
end

local runtimeBase = mktemp()
local stateDir = runtimeBase .. sep .. "state"
if isWindows then os.execute('mkdir "' .. stateDir .. '" 2>nul') else os.execute('mkdir -p "' .. stateDir .. '"') end
local venvDir = runtimeBase .. sep .. ".venv"
local venvBinDir = isWindows and (venvDir .. sep .. "Scripts") or (venvDir .. sep .. "bin")
if isWindows then
    os.execute('mkdir "' .. venvBinDir .. '" 2>nul')
else
    os.execute('mkdir -p "' .. venvBinDir .. '"')
end
local venvPython = isWindows and (venvBinDir .. sep .. "python.exe") or (venvBinDir .. sep .. "python")
do
    local f = assert(io.open(venvPython, "w"))
    f:write("#!/bin/sh\necho fake venv python\n")
    f:close()
end

local function writeStateFile(name, kvPairs)
    local f = assert(io.open(stateDir .. sep .. name, "w"))
    for k, v in pairs(kvPairs) do
        f:write(k .. "=" .. tostring(v) .. "\n")
    end
    f:close()
end

local function removeStateFile(name)
    os.remove(stateDir .. sep .. name)
end

-- ---------------------------------------------------------------------
-- Stub C context. canRunPython/execProcess/canRunFfmpeg outcomes are
-- controlled per-test via upvalue tables so each scenario can script the
-- exact probe behavior it needs (healthy / transient-fail / broken).
-- ---------------------------------------------------------------------
local existingFiles = { [venvPython] = true }
local canRunPythonResult = {} -- path -> boolean, default false
local extState = {}
local persistedPythonPath = nil
local depState = nil

local function fileExists(path)
    return existingFiles[path] == true
end

local function isAbsolutePath(path)
    if not path or path == "" then return false end
    if isWindows then
        return path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
    end
    return path:sub(1, 1) == "/"
end

local function quoteArg(s)
    return '"' .. tostring(s) .. '"'
end

local RUNTIME_SETUP = dofile("scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua")

local ctx = {
    OS = isWindows and "Windows" or "macOS",
    PATH_SEP = sep,
    script_path = runtimeBase .. sep,
    debugLog = function(_) end,
    logExecResult = function(_, _, _) end,
    fileExists = fileExists,
    getHome = function() return runtimeBase end,
    getExtStateValue = function(k)
        if k == "runtimeBase" then return runtimeBase end
        return extState[k]
    end,
    setExtStateValue = function(k, v) extState[k] = v end,
    isAbsolutePath = isAbsolutePath,
    quoteArg = quoteArg,
    -- Backs execCommandWithOutput() for the dependency-import checks
    -- (audio_separator/samplerate/stemwerk_core/demucs compat); default to
    -- success so those checks are not conflated with interpreter selection,
    -- which is exercised through the separately-stubbed canRunPython below.
    execProcess = function(_, _) return 0, "ok" end,
    canRunPython = function(path) return canRunPythonResult[path] == true end,
    canRunFfmpeg = function(_) return true end,
    findPython = function() return venvPython end,
    findSeparatorScript = function() return "" end,
    setPythonPath = function(path) persistedPythonPath = path end,
    setSeparatorScript = function(_) end,
    getPythonPath = function() return persistedPythonPath end,
    getDepState = function() return depState end,
    setDepState = function(state, detail) depState = { state = state, detail = detail } end,
    getBootstrapActive = function() return false end,
    setBootstrapActive = function(_) end,
    showMessageBox = function(_, _, _) return 0 end,
    persistPythonPathFallback = function(_) end,
    refreshRuntimeState = function() return venvPython, "" end,
    SW_LOG = nil,
}

RUNTIME_SETUP.configure(ctx)

local function resetWorld()
    existingFiles = { [venvPython] = true }
    canRunPythonResult = {}
    extState = {}
    persistedPythonPath = nil
    depState = nil
    removeStateFile("capabilities.env")
    removeStateFile("bootstrap.env")
    ctx.fileExists = fileExists
    ctx.getExtStateValue = function(k)
        if k == "runtimeBase" then return runtimeBase end
        return extState[k]
    end
    ctx.setExtStateValue = function(k, v) extState[k] = v end
    ctx.canRunPython = function(path) return canRunPythonResult[path] == true end
    ctx.setPythonPath = function(path) persistedPythonPath = path end
    ctx.getPythonPath = function() return persistedPythonPath end
    ctx.getDepState = function() return depState end
    ctx.setDepState = function(state, detail) depState = { state = state, detail = detail } end
    ctx.execProcess = function(_, _) return 0, "ok" end
    RUNTIME_SETUP.configure(ctx)
end

-- ---------------------------------------------------------------------
-- Test 1: healthy verified venv, no capabilities.env yet -> venv is used,
-- no fallback interpreter is selected.
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = true
do
    local ok, errors = RUNTIME_SETUP.verifyRuntimeAfterBootstrap()
    check("test1: healthy venv without capabilities.env is used and verified",
        ok == true, table.concat(errors or {}, ","))
    check("test1: resolved path is the verified venv, not a fallback",
        persistedPythonPath == venvPython, tostring(persistedPythonPath))
end

-- ---------------------------------------------------------------------
-- Test 3: Homebrew-like alternate interpreter exists and is runnable, but
-- must not be preferred while the verified venv itself is healthy.
-- ---------------------------------------------------------------------
resetWorld()
local homebrewPython = "/opt/homebrew/bin/python3.11"
existingFiles[homebrewPython] = true
canRunPythonResult[venvPython] = true
canRunPythonResult[homebrewPython] = true
do
    local resolved = RUNTIME_SETUP.resolveRuntimePythonPath()
    check("test3: verified venv wins over a runnable Homebrew interpreter",
        resolved == venvPython, tostring(resolved))
end

-- ---------------------------------------------------------------------
-- Test 4: authoritative venv path genuinely does not exist on disk.
-- Resolution must fail closed (empty), not silently invent a path.
-- ---------------------------------------------------------------------
resetWorld()
existingFiles[venvPython] = nil
do
    local resolved = RUNTIME_SETUP.resolveRuntimePythonPath()
    check("test4: missing venv resolves to empty, no invented fallback path",
        resolved == "", tostring(resolved))
end

-- ---------------------------------------------------------------------
-- Test 5: venv file exists and launches, but a real dependency import is
-- broken -- runtime health must FAIL, never a false READY.
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = true
-- canImportAudioSeparator/canImportModule/checkDemucsRuntimeCompatibility all
-- shell out via execCommandWithOutput -> C.execProcess; make every such call
-- fail so the import checks genuinely fail (this does not touch the
-- interpreter-selection logic under test in cases 1/3/4).
ctx.execProcess = function(_, _) return 1, "ModuleNotFoundError" end
RUNTIME_SETUP.configure(ctx)
do
    local ok, errors = RUNTIME_SETUP.verifyRuntimeAfterBootstrap()
    check("test5: broken imports on a launchable venv are a real FAIL, not READY",
        ok == false and errors and #errors > 0, tostring(ok))
end
ctx.execProcess = function(_, _) return 0, "ok" end
RUNTIME_SETUP.configure(ctx)

-- ---------------------------------------------------------------------
-- Test 7: MANAGED_PYTHON_STATUS=missing (a distinct, bootstrap-installer
-- concept) coexists with a *currently failing* live probe on an otherwise
-- verified venv; capabilities.env's VERIFICATION=ok must still resolve the
-- venv, and MANAGED_PYTHON_STATUS must not be consulted at all -- these are
-- different statuses (ACTIVE_VERIFIED_VENV vs MANAGED_PYTHON_STATUS).
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = false -- simulates a currently-failing live probe
writeStateFile("bootstrap.env", {
    MANAGED_PYTHON_ENABLED = "yes",
    MANAGED_PYTHON_STATUS = "missing",
})
writeStateFile("capabilities.env", {
    VERIFICATION = "ok",
    BOOTSTRAP_STATUS = "ok",
    PYTHON_PATH = venvPython,
    FFMPEG_PATH = venvPython,
})
do
    local resolved = RUNTIME_SETUP.resolveRuntimePythonPath()
    check("test7: MANAGED_PYTHON_STATUS=missing does not block a capabilities-verified venv",
        resolved == venvPython, tostring(resolved))
end

-- ---------------------------------------------------------------------
-- Test 8: capabilities.env is coherent and verified, but the live probe for
-- this call fails (transient ExecProcess-class hiccup) and the in-memory
-- "ExtState-style" prior PYTHON_PATH is stale/pointing elsewhere. The
-- verified capabilities.env state must still win.
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = false -- transient: this specific probe attempt fails
writeStateFile("capabilities.env", {
    VERIFICATION = "ok",
    BOOTSTRAP_STATUS = "ok",
    PYTHON_PATH = venvPython,
    FFMPEG_PATH = venvPython, -- placeholder path; ffmpeg itself is stubbed to always pass
})
persistedPythonPath = "/usr/bin/python3" -- stale "ExtState-like" prior value
do
    local ok, errors = RUNTIME_SETUP.verifyRuntimeAfterBootstrap()
    local detail = "ok=" .. tostring(ok) .. " persisted=" .. tostring(persistedPythonPath)
        .. " errs=" .. table.concat(errors or {}, ",")
    check("test8: verified capabilities.env survives a failing live probe + stale prior path",
        ok == true and persistedPythonPath == venvPython, detail)
end

-- ---------------------------------------------------------------------
-- Test 9: post-Repair reconciliation. bootstrap/capabilities/ready all ok,
-- but the fresh live probe for this call fails (transient). The live
-- verifier must not contradict the just-completed Repair with a false
-- setup failure, and must agree with the processing-time resolver.
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = false
writeStateFile("capabilities.env", {
    VERIFICATION = "ok",
    BOOTSTRAP_STATUS = "ok",
    PYTHON_PATH = venvPython,
    FFMPEG_PATH = venvPython,
})
do
    local ok1 = select(1, RUNTIME_SETUP.verifyRuntimeAfterBootstrap())
    local ok2 = RUNTIME_SETUP.verifyDependenciesReadyForProcessing()
    check("test9: post-Repair state does not produce a contradictory live setup failure",
        ok1 == true and ok2 == true, "ok1=" .. tostring(ok1) .. " ok2=" .. tostring(ok2))
end

-- ---------------------------------------------------------------------
-- Test 10: processing selection is unchanged by this patch -- even with a
-- failing live probe, verifyDependenciesReadyForProcessing must still
-- resolve to the same venv it always did via its pre-existing capabilities
-- fast path (this code path is not touched by this patch at all).
-- ---------------------------------------------------------------------
resetWorld()
canRunPythonResult[venvPython] = false
writeStateFile("capabilities.env", {
    VERIFICATION = "ok",
    BOOTSTRAP_STATUS = "ok",
    PYTHON_PATH = venvPython,
    FFMPEG_PATH = venvPython,
})
do
    local ok = RUNTIME_SETUP.verifyDependenciesReadyForProcessing()
    check("test10: processing dependency resolution still selects the verified venv",
        ok == true and persistedPythonPath == venvPython,
        "ok=" .. tostring(ok) .. " persisted=" .. tostring(persistedPythonPath))
end

-- ---------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------
os.remove(venvPython)
removeStateFile("capabilities.env")
removeStateFile("bootstrap.env")
if isWindows then
    os.execute('rmdir /s /q "' .. runtimeBase .. '" 2>nul')
else
    os.execute('rm -rf "' .. runtimeBase .. '"')
end

print(string.format("RESULT: %d passed, %d failed", passCount, failCount))
if failCount > 0 then os.exit(1) end
