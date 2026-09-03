-- Executes the real deferred Check window through its first render. When a
-- source snapshot path is supplied, that source is loaded with the current
-- repository path as its chunk name so its relative helper loads stay real.

local function assertf(condition, message)
    if not condition then error(message, 2) end
end

local function scriptDir()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    local path = source:match("^@(.*)$") or source
    return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local root = scriptDir() .. "/../.."
local target = root .. "/scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"
local sourceSnapshot = arg[1] ~= "" and arg[1] or nil
local reportedOS = arg[2]
local drawCalls = {}

STEMWERK_SETUP_HEADLESS_TEST = true
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
gfx = { mouse_wheel = 0, mouse_cap = 0, w = 1400, h = 900 }
setmetatable(gfx, {
    __index = function(t, key)
        return function(value)
            if key == "drawstr" then
                drawCalls[#drawCalls + 1] = tostring(value or "")
            elseif key == "measurestr" then
                return #tostring(value or "") * 7, 12
            elseif key == "getchar" then
                return 0
            end
            return 0
        end
    end,
})

local loader, loadErr
if sourceSnapshot then
    local f = assert(io.open(sourceSnapshot, "rb"))
    local source = f:read("*a")
    f:close()
    -- Baseline forward-declares this function local. Expose that same
    -- function for the harness without changing its body or route behavior.
    source = source:gsub("local showDeferredFinalWindow\n", "showDeferredFinalWindow = nil\n", 1)
    loader, loadErr = load(source, "@" .. target)
else
    loader, loadErr = loadfile(target)
end
assertf(loader ~= nil, "could not load Setup source: " .. tostring(loadErr))
local ok, err = pcall(loader)
assertf(ok, "could not execute Setup source: " .. tostring(err))

local tempDir = os.tmpname()
os.remove(tempDir)
assertf(os.execute('mkdir -p "' .. tempDir .. '"') == true, "could not create fixture directory")
local logFile = tempDir .. "/bootstrap.log"
local f = assert(io.open(logFile, "w"))
for i = 1, 80 do f:write(string.format("history-%03d\n", i)) end
f:close()

local verdict = {
    isCheckOnly = true,
    verifiedRuntimeOk = true,
    backend = "cpu",
    backendReason = "",
    adjustedErrors = {},
    allBasicChecksOk = true,
}
local runtime = { runtimeState = tempDir, runtimeLogs = tempDir, base = tempDir }
showDeferredFinalWindow(runtime, tempDir .. "/bootstrap.env", logFile,
    { "Verify only: done." }, true, "/fake/separator.py", nil, verdict)
linuxSetupTick()

local function wasDrawn(needle)
    for _, text in ipairs(drawCalls) do
        if text == needle then return true end
    end
    return false
end

print(table.concat({
    "oldest=" .. tostring(wasDrawn("history-001")),
    "newest=" .. tostring(wasDrawn("history-080")),
    "current=" .. tostring(wasDrawn("--- Current Check result ---")),
}, "|"))

os.remove(logFile)
os.remove(tempDir .. "/bootstrap.env")
os.remove(tempDir .. "/capabilities.env")
os.remove(tempDir .. "/bootstrap.pid")
os.execute('rmdir "' .. tempDir .. '" 2>/dev/null')
