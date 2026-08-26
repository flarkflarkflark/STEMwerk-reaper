-- Headless regression test for STEMwerk_Log.lua's writeCurrentProcessingState
-- temp-write hardening (RunContext authority hardening, section 14):
-- a failed temp-file write/close must never promote (rename into place) a
-- short/partial destination file, and must never disturb a pre-existing
-- valid destination. Uses the SW_LOG._openForWrite injectable seam (real
-- production code always uses plain io.open; only this test overrides it)
-- to simulate an OS-level write/close failure without needing to actually
-- break the filesystem.
--
-- Run directly: lua5.4 tests/support/run_log_write_hardening_headless.lua

local SEP = package.config:sub(1, 1)
local IS_WINDOWS = SEP == "\\"

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function joinPath(...)
    local parts = { ... }
    local out = ""
    for i = 1, #parts do
        local part = tostring(parts[i] or "")
        if part ~= "" then
            if out == "" then out = part
            else out = out .. SEP .. part end
        end
    end
    return out
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function removeTree(path)
    if IS_WINDOWS then
        os.execute('rmdir /S /Q "' .. path .. '" 2>nul')
    else
        os.execute("rm -rf " .. "'" .. path:gsub("'", "'\\''") .. "'")
    end
end

local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local repoRoot = scriptDir:gsub("tests[/\\]support[/\\]?$", "")
local scratchRoot = joinPath(os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp",
    "stemwerk-log-hardening-headless-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)))
removeTree(scratchRoot)
os.execute((IS_WINDOWS and 'mkdir "' or "mkdir -p '") .. scratchRoot .. (IS_WINDOWS and '"' or "'"))

-- Redirect SW_LOG's cache base into the scratch root so this test never
-- touches the real user cache directory. Standard Lua has no os.setenv,
-- so XDG_CACHE_HOME is set for THIS test's own process by re-executing
-- itself once via the shell with the variable already in its environment.
if not os.getenv("STEMWERK_LOG_HARDENING_REEXEC") then
    local cmd
    if IS_WINDOWS then
        cmd = 'set "XDG_CACHE_HOME=' .. scratchRoot .. '\\cache" && set "STEMWERK_LOG_HARDENING_REEXEC=1" && lua5.4 "' .. scriptDir .. 'run_log_write_hardening_headless.lua"'
    else
        cmd = "XDG_CACHE_HOME=" .. scratchRoot .. "/cache STEMWERK_LOG_HARDENING_REEXEC=1 lua5.4 '" .. scriptDir .. "run_log_write_hardening_headless.lua'"
    end
    local ok = os.execute(cmd)
    removeTree(scratchRoot)
    if ok == true or ok == 0 then
        print("All log write-hardening tests passed.")
        os.exit(0)
    else
        os.exit(1)
    end
end

dofile(joinPath(repoRoot, "scripts", "reaper", "_internal", "STEMwerk_Log.lua"))

local runContext = { run_id = "guid-log-hardening-test", run_dir_name = "STEMwerk_1_1_1", started_utc = "2026-08-14T00:00:00Z" }

-- #1: baseline sanity -- a normal write (no seam override) succeeds and
-- the destination file is readable, well-formed JSON containing the
-- expected run_id.
local path1 = SW_LOG.writeCurrentProcessingState(runContext, "running")
assertf(path1 ~= nil, "baseline writeCurrentProcessingState unexpectedly returned nil")
local content1 = readFile(path1)
assertf(content1 ~= nil, "baseline write did not produce a readable destination file")
assertf(content1:find('"run_id": "guid-log-hardening-test"', 1, true) ~= nil,
    "baseline destination file did not contain the expected run_id")
assertf(content1:find('"status": "running"', 1, true) ~= nil,
    "baseline destination file did not contain the expected status")

-- #2: failed temp-file OPEN (io.open itself returns nil) -- must return
-- nil and never touch the existing valid destination.
SW_LOG._openForWrite = function(_, _) return nil end
local path2 = SW_LOG.writeCurrentProcessingState(runContext, "completed")
assertf(path2 == nil, "a failed temp-file open still returned a destination path")
local afterFailedOpen = readFile(path1)
assertf(afterFailedOpen == content1,
    "a failed temp-file open corrupted/changed the pre-existing valid destination file")
SW_LOG._openForWrite = io.open

-- #3: temp file opens successfully, but write() fails (simulated disk-full
-- mid-write) -- must NOT rename/promote the short/partial temp file, must
-- remove the leftover temp file, and must never disturb the existing
-- valid destination.
local fakeWriteFailFile = {
    write = function(_, _) return nil end,
    close = function(_) return true end,
}
SW_LOG._openForWrite = function(_, _) return fakeWriteFailFile end
local path3 = SW_LOG.writeCurrentProcessingState(runContext, "completed")
assertf(path3 == nil, "a failed temp-file write() still returned a destination path")
local afterFailedWrite = readFile(path1)
assertf(afterFailedWrite == content1,
    "a failed temp-file write() corrupted/changed the pre-existing valid destination file")
local tmpPath = path1 .. ".tmp"
assertf(readFile(tmpPath) == nil,
    "a failed temp-file write() left a leftover .tmp file behind instead of removing it")
SW_LOG._openForWrite = io.open

-- #4: temp file opens and write() succeeds, but close() fails (e.g. a
-- flush error surfacing only at close time) -- must NOT promote either.
local fakeCloseFailFile = {
    write = function(_, _) return true end,
    close = function(_) return nil end,
}
SW_LOG._openForWrite = function(_, _) return fakeCloseFailFile end
local path4 = SW_LOG.writeCurrentProcessingState(runContext, "failed")
assertf(path4 == nil, "a failed temp-file close() still returned a destination path")
local afterFailedClose = readFile(path1)
assertf(afterFailedClose == content1,
    "a failed temp-file close() corrupted/changed the pre-existing valid destination file")
SW_LOG._openForWrite = io.open

-- #5: seam restored to plain io.open -- a normal write must work exactly
-- as before, proving the seam itself never leaks into production
-- behavior once cleared.
local path5 = SW_LOG.writeCurrentProcessingState(runContext, "completed")
assertf(path5 ~= nil, "writeCurrentProcessingState failed after the seam was restored to plain io.open")
local content5 = readFile(path5)
assertf(content5 ~= nil and content5:find('"status": "completed"', 1, true) ~= nil,
    "the post-seam-restore write did not produce the expected completed status")

print("PASS log-write-hardening (5/5 checks)")
