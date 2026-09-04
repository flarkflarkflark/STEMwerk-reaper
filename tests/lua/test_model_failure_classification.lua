-- Regression tests for issue #118: SW_LOG.classifyModelFailure()
-- (scripts/reaper/_internal/STEMwerk_Log.lua) must not classify an
-- unrelated processing failure as a model-download/network failure merely
-- because the log also contains the word "download" in a benign, earlier,
-- successful context.
--
-- Pure Lua harness against the real STEMwerk_Log.lua module (dofile()'d
-- directly; classifyModelFailure has no REAPER-API dependency). Run with:
--   lua tests/lua/test_model_failure_classification.lua

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

dofile("scripts/reaper/_internal/STEMwerk_Log.lua")
assert(SW_LOG and SW_LOG.classifyModelFailure, "SW_LOG.classifyModelFailure must be defined")

-- ---------------------------------------------------------------------
-- A. Exact #118 false-positive regression: a benign, successful
-- "skipping download" line (audio-separator's own local-cache-hit
-- message) followed by an unrelated CUDA kernel-support crash must NOT be
-- classified as a download/network failure.
-- ---------------------------------------------------------------------
do
    local sepText = [[
2026-09-04 01:16:15,426 - DEBUG - separator - File already exists at C:\Users\panoz\AppData\Local\STEMwerk\models\download_checks.json, skipping download
2026-09-04 01:16:15,426 - DEBUG - separator - UVR model download list loaded
2026-09-04 01:16:28,172 - DEBUG - demucs_separator - Running model inference...
ERROR: CUDA error: no kernel image is available for execution on the device
CUDA kernel errors might be asynchronously reported at some other API call, so the stacktrace below might be incorrect.
RuntimeError: CUDA error: no kernel image is available for execution on the device
]]
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "A: benign skipping-download line + CUDA crash is not classified as a download failure",
        result == nil,
        result and ("got error_class=" .. tostring(result.error_class)) or nil
    )
end

-- ---------------------------------------------------------------------
-- B. Bare, unrelated use of the word "download" (e.g. describing policy,
-- not reporting a failure) must not trigger model_download_failed.
-- ---------------------------------------------------------------------
do
    local sepText = "processing_may_download=no\nSTEMWERK_DIAG source_contamination_detected=no\nSome unrelated failure occurred.\nexit_code=1"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "B: bare unrelated 'download' mention is not classified as a download failure",
        result == nil,
        result and ("got error_class=" .. tostring(result.error_class)) or nil
    )
end

-- ---------------------------------------------------------------------
-- C. A genuine download failure (ConnectionError, no timeout-specific
-- wording and no dl.fbaipublicfiles.com -- that domain is itself one of
-- the existing timeout hints, so including it here would confound this
-- case with the model_download_timeout branch) must still be classified
-- as model_download_failed.
-- ---------------------------------------------------------------------
do
    local sepText = "ConnectionError: Failed to establish a new connection: [Errno 111] Connection refused"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "C: genuine download failure is still classified as model_download_failed",
        result ~= nil and result.error_class == "model_download_failed",
        result and ("got error_class=" .. tostring(result.error_class)) or "got nil"
    )
end

-- ---------------------------------------------------------------------
-- D. Genuine download timeout (existing supported classifier case,
-- mirrors tests/test_model_failure_classification.py) must still be
-- classified as model_download_timeout.
-- ---------------------------------------------------------------------
do
    local sepText = "HTTPSConnectionPool(host='dl.fbaipublicfiles.com', port=443): Read timed out"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "D: genuine download timeout is still classified as model_download_timeout",
        result ~= nil and result.error_class == "model_download_timeout",
        result and ("got error_class=" .. tostring(result.error_class)) or "got nil"
    )
end

-- ---------------------------------------------------------------------
-- E. A later unrelated processing exception must take precedence over
-- harmless earlier download context, even when the benign line appears
-- much earlier in a longer log (ordering must not matter).
-- ---------------------------------------------------------------------
do
    local sepText = "download_checks.json already exists, skipping download\n"
        .. string.rep("padding line to simulate a longer real log\n", 20)
        .. "Traceback (most recent call last):\n"
        .. "RuntimeError: CUDA error: no kernel image is available for execution on the device"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "E: unrelated later exception takes precedence over harmless earlier download context",
        result == nil,
        result and ("got error_class=" .. tostring(result.error_class)) or nil
    )
end

-- ---------------------------------------------------------------------
-- Existing behavior, unaffected by this fix -- checksum, mapping, DrumSep
-- backend-limit guard, and ordinary non-failures must be unchanged.
-- ---------------------------------------------------------------------
do
    local sepText = "Invalid checksum for file /tmp/955717e8-8726e21a.th"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "existing: checksum failure classification unchanged",
        result ~= nil and result.error_class == "model_checksum_failed",
        result and ("got error_class=" .. tostring(result.error_class)) or "got nil"
    )
end

do
    local sepText = "ValueError: Model file htdemucs not found in supported model files"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "existing: unsupported internal model id classification unchanged",
        result ~= nil and result.error_class == "model_mapping_failed",
        result and ("got error_class=" .. tostring(result.error_class)) or "got nil"
    )
end

do
    local sepText = "error_reason=drumsep_backend_runtime_limited"
    local result = SW_LOG.classifyModelFailure(sepText, "")
    check(
        "existing: DrumSep backend-limit guard still suppresses classification",
        result == nil,
        result and ("got error_class=" .. tostring(result.error_class)) or nil
    )
end

do
    local result = SW_LOG.classifyModelFailure("No stems were created. exit_code=1", "")
    check("existing: ordinary no-stems failure is not model-download classified", result == nil)
end

print(string.format("RESULT: %d passed, %d failed", passCount, failCount))
if failCount > 0 then os.exit(1) end
