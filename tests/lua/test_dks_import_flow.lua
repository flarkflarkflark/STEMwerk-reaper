-- test_dks_import_flow.lua
-- Regression tests for the DKS (Drum Kit Split) import invariants.
-- Run with a plain Lua interpreter:
--   lua tests/lua/test_dks_import_flow.lua
-- Exits non-zero on failure.

local scriptDir = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repoRoot = scriptDir .. "/../.."
local modulePath = repoRoot .. "/scripts/reaper/_internal/STEMwerk_DKS_Import.lua"

local DKS_IMPORT = dofile(modulePath)

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- Import verdict matrix (single source item, validated outputs vs imported tracks)
local ok, reason = DKS_IMPORT.validateImportResult(6, 0)
check("validated=6 imported=0 => FAIL", ok == false and reason == "dks_import_count_mismatch")

ok, reason = DKS_IMPORT.validateImportResult(6, 5)
check("validated=6 imported=5 => FAIL", ok == false and reason == "dks_import_count_mismatch")

ok, reason = DKS_IMPORT.validateImportResult(6, 6)
check("validated=6 imported=6 => PASS", ok == true and reason == "ok")

ok, reason = DKS_IMPORT.validateImportResult(0, 0)
check("validated=0 imported=0 => FAIL (nothing validated)", ok == false and reason == "dks_expected_outputs_missing")

ok, reason = DKS_IMPORT.validateImportResult(6, 7)
check("validated=6 imported=7 => FAIL (duplicates)", ok == false and reason == "dks_import_count_mismatch")

-- Multi-item expected counts: items * 6
check("expectedTracksForItems(1) == 6", DKS_IMPORT.expectedTracksForItems(1) == 6)
check("expectedTracksForItems(2) == 12", DKS_IMPORT.expectedTracksForItems(2) == 12)
check("expectedTracksForItems(3) == 18", DKS_IMPORT.expectedTracksForItems(3) == 18)

ok, reason = DKS_IMPORT.validateImportResult(DKS_IMPORT.expectedTracksForItems(2), 12)
check("multi-item validated=12 imported=12 => PASS", ok == true and reason == "ok")

ok, reason = DKS_IMPORT.validateImportResult(DKS_IMPORT.expectedTracksForItems(2), 6)
check("multi-item validated=12 imported=6 => FAIL", ok == false and reason == "dks_import_count_mismatch")

-- String numbers must also validate (counts come from log parsing in some flows)
ok, reason = DKS_IMPORT.validateImportResult("6", "6")
check("string counts 6/6 => PASS", ok == true and reason == "ok")

-- ---------------------------------------------------------------------------
-- Stem-key normalization matrix
-- ---------------------------------------------------------------------------
check("normalize hihat -> hi-hat", DKS_IMPORT.normalizeStemPathKey("hihat") == "hi-hat")
check("normalize hh -> hi-hat", DKS_IMPORT.normalizeStemPathKey("hh") == "hi-hat")
check("normalize Hi-Hat -> hi-hat", DKS_IMPORT.normalizeStemPathKey("Hi-Hat") == "hi-hat")
check("normalize Kick -> kick", DKS_IMPORT.normalizeStemPathKey("Kick") == "kick")
check("normalize CRASH -> crash", DKS_IMPORT.normalizeStemPathKey("CRASH") == "crash")

-- ---------------------------------------------------------------------------
-- Stdout-JSON path matrix (real files on disk)
-- ---------------------------------------------------------------------------
local function tempBase()
    local t = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return t
end
local isWindows = package.config:sub(1, 1) == "\\"
local sep = isWindows and "\\" or "/"
local workDir = tempBase() .. sep .. "stemwerk_dks_import_test"
if isWindows then
    os.execute('mkdir "' .. workDir .. '" 2>nul')
else
    os.execute('mkdir -p "' .. workDir .. '"')
end

local kitKeys = { "kick", "snare", "toms", "hihat", "ride", "crash" }
local kitPaths = {}
for _, k in ipairs(kitKeys) do
    local p = workDir .. sep .. k .. ".wav"
    local fh = assert(io.open(p, "wb"))
    fh:write("RIFFTEST")
    fh:close()
    kitPaths[k] = p
end

local function jsonEscape(p)
    -- Escape like a JSON encoder on Windows would: backslash -> double backslash
    return (p:gsub("\\", "\\\\"))
end

local function writeStdout(name, lines)
    local p = workDir .. sep .. name
    local fh = assert(io.open(p, "w"))
    for _, l in ipairs(lines) do fh:write(l .. "\n") end
    fh:close()
    return p
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 1) POSIX-style paths (forward slashes) -> six imports
local jsonParts = {}
for _, k in ipairs(kitKeys) do
    jsonParts[#jsonParts + 1] = '"' .. k .. '": "' .. kitPaths[k]:gsub("\\", "/") .. '"'
end
local f1 = writeStdout("posix_stdout.txt", { "noise line", "{" .. table.concat(jsonParts, ", ") .. "}" })
local stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f1)
check("posix paths => 6 imports", countKeys(stems) == 6)
check("posix hihat key normalized to hi-hat", stems["hi-hat"] ~= nil)

-- 2) Windows drive-letter paths with escaped backslashes -> six imports (Windows only).
--    Off-Windows, kitPaths[k] is already forward-slash separated, so escaping it would be
--    a no-op and would not exercise the backslash-unescape path at all. Build a genuine
--    backslash-separated Windows path instead; it never resolves to a real file on this
--    POSIX machine (the actual fixtures live under workDir with forward slashes), so the
--    parser's file-existence check correctly rejects it.
jsonParts = {}
for _, k in ipairs(kitKeys) do
    local winPath = isWindows and kitPaths[k] or ("C:\\Users\\STEMwerkTest\\" .. k .. ".wav")
    jsonParts[#jsonParts + 1] = '"' .. k .. '": "' .. jsonEscape(winPath) .. '"'
end
local f2 = writeStdout("winbackslash_stdout.txt", { "{" .. table.concat(jsonParts, ", ") .. "}" })
stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f2)
if isWindows then
    check("windows backslash paths => 6 imports", countKeys(stems) == 6)
else
    check("windows backslash paths rejected cleanly off-Windows", countKeys(stems) == 0)
end

-- 3) Paths with spaces -> six imports
local spaceDir = workDir .. sep .. "with space"
if isWindows then os.execute('mkdir "' .. spaceDir .. '" 2>nul') else os.execute('mkdir -p "' .. spaceDir .. '"') end
jsonParts = {}
for _, k in ipairs(kitKeys) do
    local p = spaceDir .. sep .. k .. " stem.wav"
    local fh = assert(io.open(p, "wb"))
    fh:write("RIFF")
    fh:close()
    jsonParts[#jsonParts + 1] = '"' .. k .. '": "' .. p:gsub("\\", "/") .. '"'
end
local f3 = writeStdout("spaces_stdout.txt", { "{" .. table.concat(jsonParts, ", ") .. "}" })
stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f3)
check("paths with spaces => 6 imports", countKeys(stems) == 6)

-- 4) CRLF line endings / trailing CR -> parsed normally
local f4 = workDir .. sep .. "crlf_stdout.txt"
do
    local fh = assert(io.open(f4, "wb"))
    jsonParts = {}
    for _, k in ipairs(kitKeys) do
        jsonParts[#jsonParts + 1] = '"' .. k .. '": "' .. kitPaths[k]:gsub("\\", "/") .. '"'
    end
    fh:write("progress line\r\n{" .. table.concat(jsonParts, ", ") .. "}\r\n")
    fh:close()
end
stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f4)
check("CRLF/trailing CR => 6 imports, no phantom keys", countKeys(stems) == 6)

-- 5) Missing files are rejected explicitly (no entry, no crash)
local f5 = writeStdout("missing_stdout.txt", { '{"kick": "' .. (workDir .. sep .. "does_not_exist.wav"):gsub("\\", "/") .. '"}' })
stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f5)
check("missing file => rejected explicitly", countKeys(stems) == 0)

-- 6) Non-JSON output => empty map, no crash
local f6 = writeStdout("nojson_stdout.txt", { "no json here", "just logs" })
stems = DKS_IMPORT.collectStemPathsFromStdoutJson(f6)
check("no JSON => empty map", type(stems) == "table" and countKeys(stems) == 0)

if failures > 0 then
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
print("RESULT: all tests passed")
