-- Headless regression coverage for STEMwerk_Setup_Toolbar.lua on a fresh
-- REAPER profile (issue #121): a brand-new profile has no reaper-menu.ini
-- yet, and the toolbar script used to hard-fail with "Unable to read
-- reaper-menu.ini" instead of treating that as an empty ini to create.
--
-- This runs the real, unmodified STEMwerk_Setup_Toolbar.lua via dofile()
-- against a minimal mock `reaper` global, following the same style as the
-- other tests/support/run_*_headless.lua harnesses. The real shipped icon
-- assets under scripts/reaper/assets/toolbar_icons/ are used as-is (no
-- fixtures needed) since the script resolves its own directory via
-- debug.getinfo against wherever it is dofile()'d from.

local SEP = "/"

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local passCount = 0
local failCount = 0

local function reportPass(name)
    passCount = passCount + 1
    print("PASS " .. name)
end

local function reportFail(name, err)
    failCount = failCount + 1
    print("FAIL " .. name .. ": " .. tostring(err))
end

local function runCase(name, fn)
    local ok, err = pcall(fn)
    if ok then
        reportPass(name)
    else
        reportFail(name, err)
    end
end

local function makeTempDir(suffix)
    local base = os.getenv("TMPDIR") or "/tmp"
    local path = base .. "/stemwerk_toolbar_headless_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)) .. "_" .. suffix
    assertf(os.execute("mkdir -p " .. path) ~= nil, "failed to create temp dir " .. path)
    return path
end

local function fileExistsOnDisk(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function readFileOnDisk(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end

-- Finds the real repo root (tests/support/ -> repo root) so the toolbar
-- script's own asset lookups (relative to *its* location) work unchanged.
local function repoRootScriptPath()
    local info = debug.getinfo(1, "S")
    local herePath = info.source:match("@?(.*[/\\])") or "./"
    return herePath .. "../../scripts/reaper/STEMwerk_Setup_Toolbar.lua"
end

local function runToolbarScript(resourcePath, opts)
    opts = opts or {}
    local commandCounter = 1000
    local recordedNamedIds = {}
    local mockReaper = {}

    mockReaper.GetOS = function() return "Linux" end
    mockReaper.GetResourcePath = function() return resourcePath end
    mockReaper.GetExtState = function(_, _) return "" end
    mockReaper.ShowConsoleMsg = function(_) end

    mockReaper.RecursiveCreateDirectory = function(path, _)
        os.execute("mkdir -p " .. path)
        return 1
    end

    mockReaper.AddRemoveReaScript = function(_add, _section, _path, _refresh)
        commandCounter = commandCounter + 1
        return commandCounter
    end

    mockReaper.ReverseNamedCommandLookup = function(commandId)
        local named = "_RSheadless" .. tostring(commandId)
        recordedNamedIds[commandId] = named
        return named
    end

    local messageBoxCalls = {}
    local answerIndex = 0
    mockReaper.ShowMessageBox = function(text, title, msgType)
        answerIndex = answerIndex + 1
        messageBoxCalls[#messageBoxCalls + 1] = {text = text, title = title, msgType = msgType}
        local scripted = opts.answers and opts.answers[answerIndex]
        if scripted ~= nil then return scripted end
        return 6 -- default: IDYES, drives the happy path forward
    end

    reaper = mockReaper
    local chunk = assert(loadfile(repoRootScriptPath()))
    local ok, err = pcall(chunk)
    reaper = nil

    return ok, err, messageBoxCalls
end

runCase("fresh profile with no reaper-menu.ini does not error", function()
    local profileDir = makeTempDir("fresh")
    local menuPath = profileDir .. "/reaper-menu.ini"
    assertf(not fileExistsOnDisk(menuPath), "test setup invariant broken: reaper-menu.ini should not exist yet")

    local ok, err, calls = runToolbarScript(profileDir)
    assertf(ok, "toolbar script raised an error on a fresh profile: " .. tostring(err))
    assertf(#calls >= 1, "expected at least one ShowMessageBox call (choose setup mode)")

    for _, call in ipairs(calls) do
        assertf(
            not tostring(call.text or ""):find("Unable to read reaper%-menu%.ini", 1, false),
            "toolbar setup surfaced the stale 'Unable to read reaper-menu.ini' failure on a fresh profile"
        )
    end
end)

runCase("fresh profile creates reaper-menu.ini with a STEMwerk toolbar section", function()
    local profileDir = makeTempDir("create")
    local menuPath = profileDir .. "/reaper-menu.ini"

    local ok, err = runToolbarScript(profileDir)
    assertf(ok, "toolbar script raised an error: " .. tostring(err))
    assertf(fileExistsOnDisk(menuPath), "reaper-menu.ini was not created on a fresh profile")

    local data = readFileOnDisk(menuPath) or ""
    assertf(data:find("%[Floating toolbar %d+%]"), "created reaper-menu.ini has no floating toolbar section")
    assertf(data:find("title=STEMwerk"), "created reaper-menu.ini has no STEMwerk toolbar title")
end)

runCase("existing reaper-menu.ini without a STEMwerk section is preserved and appended to", function()
    local profileDir = makeTempDir("existing")
    local menuPath = profileDir .. "/reaper-menu.ini"
    local preexisting = "[Floating toolbar 1]\ntitle=My Other Toolbar\nitem_0=_SOME_OTHER_ACTION Other\n"
    local f = assert(io.open(menuPath, "wb"))
    f:write(preexisting)
    f:close()

    local ok, err = runToolbarScript(profileDir)
    assertf(ok, "toolbar script raised an error on an existing non-STEMwerk ini: " .. tostring(err))

    local data = readFileOnDisk(menuPath) or ""
    assertf(data:find("My Other Toolbar", 1, true), "pre-existing unrelated toolbar section was lost")
    assertf(data:find("title=STEMwerk"), "STEMwerk toolbar section was not appended alongside the existing one")
end)

runCase("declining the setup-mode prompt on a fresh profile does not write reaper-menu.ini", function()
    local profileDir = makeTempDir("decline")
    local menuPath = profileDir .. "/reaper-menu.ini"

    local ok, err = runToolbarScript(profileDir, {answers = {7}}) -- IDNO on "Choose setup mode"
    assertf(ok, "toolbar script raised an error: " .. tostring(err))
    assertf(not fileExistsOnDisk(menuPath), "reaper-menu.ini should not be created when the user declines")
end)

print(string.format("RESULT: %d passed, %d failed", passCount, failCount))
if failCount > 0 then
    os.exit(1)
end
