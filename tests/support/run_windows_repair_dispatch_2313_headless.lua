-- Headless regression coverage for the 2.3.1.3 Windows Setup/Repair dispatch fix.
--
-- Windows reaches the shared Linux/macOS final Setup window through the real
-- Check-only route (menu -> windowsVerifyStart -> windowsVerifyTick ->
-- finalizeWindowsVerify -> showDeferredFinalWindow -> linuxSetupTick). Before
-- the fix that window offered Repair/Rebuild venv, whose click called
-- startLinuxSetup: it deleted bootstrap.env/capabilities.env and then tried
-- `/bin/sh ...STEMwerk_Bootstrap_Windows.ps1`.
--
-- Runs the real production Lua. Windows paths are used verbatim as file names
-- inside the current working directory, which the caller sets to a temp dir.

local REPO_ROOT = assert(os.getenv("STEMWERK_TEST_REPO_ROOT"), "STEMWERK_TEST_REPO_ROOT is required")
local SETUP_TARGET = REPO_ROOT .. "/scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"
local RUNTIME_TARGET = REPO_ROOT .. "/scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua"

local BASE = "C:\\STEMwerk\\STEMwerk"
local STATE_FILES = {
    [BASE .. "\\state\\bootstrap.env"] = "STATUS=failed\r\nSTATUS_REASON=python_missing\r\nINSTALLER=1\r\nRUNTIME_BASE=" .. BASE .. "\r\n",
    [BASE .. "\\state\\capabilities.env"] = "CAP_VERSION=1\r\nPROFILE=windows-cpu\r\nBACKEND=cpu\r\nVERIFICATION=failed\r\nRUNTIME_BASE=" .. BASE .. "\r\n",
    [BASE .. "\\logs\\bootstrap.log"] = "Installer bootstrap started\r\nRUNTIME_BASE=" .. BASE .. "\r\n",
}

local REAL_OS_EXECUTE = os.execute
local REAL_IO_POPEN = io.popen

local function assertf(condition, message)
    if not condition then error(message, 2) end
end

local function readBytes(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeBytes(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function seedStateFiles()
    for path, data in pairs(STATE_FILES) do writeBytes(path, data) end
    -- Lets the pre-fix startLinuxSetup reach its launch step, as it does on a
    -- real install where the bootstrap script exists.
    writeBytes((REPO_ROOT:gsub("/", "\\")) .. "\\STEMwerk_Bootstrap_Windows.ps1", "")
end

local function assertStateFilesUnchanged(name)
    for path, expected in pairs(STATE_FILES) do
        local actual = readBytes(path)
        assertf(actual ~= nil, name .. ": " .. path .. " was deleted")
        assertf(actual == expected, name .. ": " .. path .. " bytes changed")
    end
end

local function newSetupEnv(reportedOS)
    local ctx = { queue = {}, drawn = {}, msgs = {}, execs = {}, shell = {}, linuxSetupCalls = {}, quitCount = 0 }
    STEMWERK_SETUP_HEADLESS_TEST = true
    STEMWERK_SETUP_TEST_HOOKS = {}
    reaper = {
        ShowMessageBox = function(msg, title)
            ctx.msgs[#ctx.msgs + 1] = { title = tostring(title), msg = tostring(msg) }
            return 1
        end,
        GetOS = function() return reportedOS end,
        GetExtState = function(_, key) if key == "runtimeBase" then return BASE end return "" end,
        SetExtState = function() end,
        HasExtState = function() return false end,
        DeleteExtState = function() end,
        ShowConsoleMsg = function() end,
        defer = function(fn) ctx.queue[#ctx.queue + 1] = fn end,
        GetResourcePath = function() return "C:\\Users\\tester\\AppData\\Roaming\\REAPER" end,
        get_action_context = function() return "", "" end,
        ExecProcess = function(cmd) ctx.execs[#ctx.execs + 1] = tostring(cmd); return nil end,
        time_precise = function() return os.clock() end,
    }
    local g = { w = 1260, h = 904, x = 0, y = 0, mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0, texth = 14 }
    g.measurestr = function(s) return #tostring(s) * 7, 14 end
    g.drawstr = function(s) ctx.drawn[#ctx.drawn + 1] = { s = tostring(s), x = g.x, y = g.y } end
    g.getchar = function() return 0 end
    g.dock = function() return 0 end
    g.quit = function() ctx.quitCount = ctx.quitCount + 1 end
    gfx = setmetatable(g, { __index = function() return function() return 0 end end })
    ctx.gfx = g
    os.execute = function(cmd) ctx.shell[#ctx.shell + 1] = tostring(cmd); return true end
    io.popen = function(cmd) ctx.shell[#ctx.shell + 1] = tostring(cmd); return nil end

    local ok, err = pcall(dofile, SETUP_TARGET)
    assertf(ok, "failed to load " .. SETUP_TARGET .. " for GetOS()=" .. reportedOS .. ": " .. tostring(err))

    local realStartLinuxSetup = startLinuxSetup
    startLinuxSetup = function(runtime, separatorScript, mode)
        ctx.linuxSetupCalls[#ctx.linuxSetupCalls + 1] = tostring(mode)
        if ctx.passThroughLinuxSetup then
            return realStartLinuxSetup(runtime, separatorScript, mode)
        end
    end
    ctx.runtime = {
        base = BASE, runtimeRoot = BASE,
        runtimeState = BASE .. "\\state", runtimeLogs = BASE .. "\\logs",
        runtimeCache = BASE .. "\\cache", venvDir = BASE .. "\\.venv",
        venvPython = BASE .. "\\.venv\\Scripts\\python.exe",
    }
    return ctx
end

local function restoreGlobals()
    os.execute = REAL_OS_EXECUTE
    io.popen = REAL_IO_POPEN
end

local function pump(ctx, ticks)
    for _ = 1, ticks or 1 do
        local q = ctx.queue
        ctx.queue = {}
        if #q == 0 then return end
        ctx.drawn = {}
        for _, fn in ipairs(q) do
            local ok, err = pcall(fn)
            assertf(ok, "deferred tick raised: " .. tostring(err))
        end
    end
end

local function findLabel(ctx, label, minY)
    for _, d in ipairs(ctx.drawn) do
        if d.s == label and d.y >= (minY or 0) then return d end
    end
    return nil
end

local function hasText(ctx, needle)
    for _, d in ipairs(ctx.drawn) do
        if d.s:find(needle, 1, true) then return true end
    end
    return false
end

local function click(ctx, d)
    ctx.gfx.mouse_x, ctx.gfx.mouse_y, ctx.gfx.mouse_cap = d.x + 2, d.y + 2, 1
    pump(ctx, 1)
    ctx.gfx.mouse_cap = 0
end

local function anyContains(list, needle)
    for _, v in ipairs(list) do
        if tostring(v):find(needle, 1, true) then return true end
    end
    return false
end

-- Real Windows Check-only route: Setup menu -> "Check only" -> verify ticks ->
-- shared final window. Returns ctx with the final window rendered.
local function openWindowsCheckOnlyFinalWindow()
    local ctx = newSetupEnv("Win64")
    seedStateFiles()
    ctx.passThroughLinuxSetup = true
    startExistingRuntimeSetupMenu(ctx.runtime, "audio_separator_process.py")
    pump(ctx, 1)
    local checkOnly = findLabel(ctx, "Check only", 600)
    assertf(checkOnly, "Windows Setup menu did not render the Check only action")
    click(ctx, checkOnly)
    for _ = 1, 60 do
        pump(ctx, 1)
        if hasText(ctx, "Windows live setup UI active") then return ctx end
    end
    error("Windows Check-only route never reached the shared final Setup window")
end

local function testWindowsCheckOnlyRouteReachesFinalWindowWithoutRepair()
    local ctx = openWindowsCheckOnlyFinalWindow()
    assertf(hasText(ctx, "Setup was not completely successful."), "expected the failed Check-only headline")
    assertf(findLabel(ctx, "Repair") == nil, "Windows final window must not offer in-REAPER Repair")
    assertf(findLabel(ctx, "Rebuild venv") == nil, "Windows final window must not offer Rebuild venv")
    assertf(findLabel(ctx, "Save Support Bundle") ~= nil, "read-only Save Support Bundle action must remain")
    assertf(linuxFinalOffersInReaperRepair() == false, "linuxFinalOffersInReaperRepair must be false on Windows")
    assertf(#ctx.linuxSetupCalls == 0, "Check-only route must not call startLinuxSetup")
    assertStateFilesUnchanged("windows-check-only-route")
    restoreGlobals()
    print("PASS windows-check-only-route-reaches-final-window-without-repair")
end

-- Defense in depth: even if a future render change offered Repair/Rebuild venv
-- on Windows again, the click must hit the installer guard, not startLinuxSetup.
local function testWindowsRepairClickIsGuardedAndPreservesState(label)
    local ctx = openWindowsCheckOnlyFinalWindow()
    linuxFinalOffersInReaperRepair = function() return true end
    pump(ctx, 1)
    local button = findLabel(ctx, label)
    assertf(button, "could not force-render the " .. label .. " button for the guard test")
    ctx.msgs = {}
    click(ctx, button)
    local name = "windows-" .. label:lower():gsub("%s+", "-") .. "-click"
    assertStateFilesUnchanged(name)
    assertf(#ctx.linuxSetupCalls == 0, name .. ": startLinuxSetup was called (" .. table.concat(ctx.linuxSetupCalls, ",") .. ")")
    assertf(not anyContains(ctx.execs, "/bin/sh") and not anyContains(ctx.shell, "/bin/sh"), name .. ": a /bin/sh launch was attempted")
    assertf(#ctx.execs == 0, name .. ": no process may be launched, got: " .. table.concat(ctx.execs, " | "))
    assertf(#ctx.msgs == 1, name .. ": expected exactly one guidance message, got " .. #ctx.msgs)
    assertf(ctx.msgs[1].title == "STEMwerk Setup", name .. ": unexpected guidance title " .. ctx.msgs[1].title)
    assertf(ctx.msgs[1].msg:find("handled by the STEMwerk installer", 1, true), name .. ": guidance must point to the STEMwerk installer")
    assertf(ctx.msgs[1].msg:find("Nothing was changed.", 1, true), name .. ": guidance must state nothing was changed")
    pump(ctx, 1)
    assertf(hasText(ctx, "Windows live setup UI active"), name .. ": final window must stay open after the guidance")
    restoreGlobals()
    print("PASS " .. name .. "-uses-installer-guard-and-preserves-state")
end

local function testWindowsSuccessFinalWindowUnchanged()
    local ctx = newSetupEnv("Win64")
    showDeferredFinalWindow(ctx.runtime, BASE .. "\\state\\bootstrap.env", BASE .. "\\logs\\bootstrap.log", { "ok" }, true, "sep.py", true)
    pump(ctx, 1)
    assertf(findLabel(ctx, "Open STEMwerk") ~= nil, "Windows success window must still offer Open STEMwerk")
    assertf(findLabel(ctx, "Repair") == nil, "Windows success window must not offer Repair")
    restoreGlobals()
    print("PASS windows-success-final-window-unchanged")
end

local function testUnixFinalWindowRepairUnchanged(reportedOS, label)
    for _, case in ipairs({ { button = "Repair", mode = "repair" }, { button = "Rebuild venv", mode = "rebuild-venv" } }) do
        local ctx = newSetupEnv(reportedOS)
        assertf(linuxFinalOffersInReaperRepair() == true, label .. ": linuxFinalOffersInReaperRepair must stay true")
        showDeferredFinalWindow(ctx.runtime, BASE .. "/state/bootstrap.env", BASE .. "/logs/bootstrap.log", { "failed" }, false, "sep.py", true)
        pump(ctx, 1)
        local button = findLabel(ctx, case.button)
        assertf(button, label .. ": final window must still offer " .. case.button)
        ctx.msgs = {}
        click(ctx, button)
        assertf(#ctx.linuxSetupCalls == 1 and ctx.linuxSetupCalls[1] == case.mode,
            label .. ": " .. case.button .. " must still call startLinuxSetup(" .. case.mode .. ")")
        assertf(ctx.quitCount == 1, label .. ": " .. case.button .. " must still close the final window first")
        for _, box in ipairs(ctx.msgs) do
            assertf(not box.msg:find("handled by the STEMwerk installer", 1, true),
                label .. ": " .. case.button .. " must not show the Windows installer guard")
        end
        restoreGlobals()
    end
    print("PASS " .. label .. "-final-window-repair-and-rebuild-unchanged")
end

local function testWindowsInstallerRequiredMessageTitleAndBody()
    local module = dofile(RUNTIME_TARGET)
    local boxes = {}
    module.configure({
        OS = "Windows",
        PATH_SEP = "\\",
        script_path = "",
        getDepState = function() return { state = "unknown" } end,
        setDepState = function() end,
        getExtStateValue = function(key) if key == "runtimeBase" then return BASE end return "" end,
        isAbsolutePath = function(p) return tostring(p):match("^%a:[/\\]") ~= nil end,
        fileExists = function() return false end,
        canRunPython = function() return false end,
        canRunFfmpeg = function() return false end,
        execProcess = function() return 1, "" end,
        quoteArg = function(v) return '"' .. tostring(v) .. '"' end,
        -- Same parameter order as the production adapter in STEMwerk.lua.
        showMessageBox = function(title, text, boxType)
            boxes[#boxes + 1] = { title = title, text = text, boxType = boxType }
            return 1
        end,
        logExecResult = function() end,
    })
    assertf(module.verifyDependenciesReadyForProcessing() == false, "missing Windows runtime must keep processing blocked")
    assertf(module.runSetup() == false, "Windows runSetup must stay fail-closed")
    assertf(#boxes == 2, "expected two installer-required messages, got " .. #boxes)
    for _, box in ipairs(boxes) do
        assertf(box.title == "STEMwerk Setup", "installer-required title must be 'STEMwerk Setup', got: " .. tostring(box.title))
        assertf(tostring(box.text):find("^The STEMwerk runtime is not installed or is incomplete%."), "installer-required body must carry the explanation, got: " .. tostring(box.text))
        assertf(tostring(box.text):find("Re-run the STEMwerk installer before processing.", 1, true), "installer-required body must tell the user to re-run the installer")
    end
    assertf(tostring(boxes[2].text):find("Windows runtime repair is performed by the external installer", 1, true), "runSetup detail must stay in the body")
    print("PASS windows-installer-required-message-title-and-body")
end

local scenarios = {
    function() testWindowsCheckOnlyRouteReachesFinalWindowWithoutRepair() end,
    function() testWindowsRepairClickIsGuardedAndPreservesState("Repair") end,
    function() testWindowsRepairClickIsGuardedAndPreservesState("Rebuild venv") end,
    function() testWindowsSuccessFinalWindowUnchanged() end,
    function() testUnixFinalWindowRepairUnchanged("Other", "linux") end,
    function() testUnixFinalWindowRepairUnchanged("OSX64", "macos") end,
    function() testWindowsInstallerRequiredMessageTitleAndBody() end,
}
local failures = 0
for _, scenario in ipairs(scenarios) do
    local ok, err = pcall(scenario)
    restoreGlobals()
    if not ok then
        failures = failures + 1
        print("FAIL " .. tostring(err))
    end
end
if failures > 0 then
    print(failures .. " FAILED run_windows_repair_dispatch_2313_headless")
    os.exit(1)
end
print("ALL PASS run_windows_repair_dispatch_2313_headless")
