-- STEMwerk_DKS_Import.lua
-- Pure helpers for Drum Kit Split (DKS) import validation. No reaper/gfx/io
-- dependencies so this module can be unit-tested with a plain Lua interpreter.
--
-- Invariants enforced here:
--   * one source item  -> expected imported tracks == validated output count
--                         (6 for a full kit split)
--   * N source items   -> expected imported tracks == N * per-item outputs
-- Any mismatch is a workflow failure, never a success.

local M = {}

M.EXPECTED_KIT_OUTPUTS_PER_ITEM = 6

-- Expected imported track count for a run.
-- itemCount: number of source items processed (>= 1).
-- perItem:   validated outputs per item (defaults to a full kit = 6).
function M.expectedTracksForItems(itemCount, perItem)
    local items = tonumber(itemCount) or 0
    local per = tonumber(perItem) or M.EXPECTED_KIT_OUTPUTS_PER_ITEM
    if items < 0 then items = 0 end
    if per < 0 then per = 0 end
    return items * per
end

-- Verdict for a completed import.
-- expected: validated output count (what the worker produced and we validated).
-- imported: tracks actually created in REAPER.
-- Returns ok(boolean), reason(string).
--   ok=true,  reason="ok"                          when expected>0 and imported==expected
--   ok=false, reason="dks_expected_outputs_missing" when expected<=0
--   ok=false, reason="dks_import_count_mismatch"    otherwise
function M.validateImportResult(expected, imported)
    local exp = tonumber(expected) or 0
    local imp = tonumber(imported) or 0
    if exp <= 0 then
        return false, "dks_expected_outputs_missing"
    end
    if imp ~= exp then
        return false, "dks_import_count_mismatch"
    end
    return true, "ok"
end

-- Canonical stem-key normalization used by the import handoff.
-- "hihat"/"hh" alias to "hi-hat"; everything else passes through lowercased.
function M.normalizeStemPathKey(name)
    local key = tostring(name or ""):lower()
    if key == "hihat" or key == "hh" then
        return "hi-hat"
    end
    return key
end

-- Parse the last single-line JSON object printed by the separation worker and
-- keep only entries whose audio file is actually readable. Keys are
-- normalized (underscores -> dashes, hihat alias); values are unescaped
-- JSON string paths. Works with POSIX and Windows (escaped-backslash) paths.
function M.collectStemPathsFromStdoutJson(stdoutFile)
    if not stdoutFile or stdoutFile == "" then return {} end
    local f = io.open(stdoutFile, "r")
    if not f then return {} end
    local text = f:read("*a") or ""
    f:close()
    if text == "" then return {} end

    local lastJsonLine = nil
    for line in tostring(text):gmatch("[^\r\n]+") do
        local trimmed = tostring(line or ""):match("^%s*(.-)%s*$") or ""
        if trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" and trimmed:find('"%s*:%s*"', 1) then
            lastJsonLine = trimmed
        end
    end
    if not lastJsonLine then return {} end

    local stems = {}
    for rawKey, rawPath in lastJsonLine:gmatch('"([^"]+)"%s*:%s*"(.-)"') do
        local key = M.normalizeStemPathKey(rawKey:gsub("_", "-"))
        local path = tostring(rawPath or ""):gsub('\\"', '"'):gsub("\\\\", "\\")
        if key ~= "" and path ~= "" then
            local probe = io.open(path, "rb")
            if probe then
                probe:close()
                stems[key] = path
            end
        end
    end
    return stems
end

return M
