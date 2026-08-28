-- Headless RENDER tests for the 2.3.1.1 second adversarial review's Finding
-- 5 (in-memory "Current Check result" section) and its interaction with
-- Finding 3's historical-provenance banner and Finding 4's Linux-only
-- gating. This drives the REAL production rendering pipeline --
-- showDeferredFinalWindow() -> linuxSetupTick() -> linuxDrawFinal() ->
-- drawLinuxLogPanel() -- through a gfx stub that records every
-- gfx.drawstr() call's text and screen position, so assertions can prove
-- what actually gets drawn and where, not just what a pure decision
-- function would return in isolation. showDeferredFinalWindow is a pure
-- state constructor (no subprocess, no live probe) plus a mocked
-- gfx.init()/reaper.defer() -- linuxSetupTick after it only reads the
-- controlled temp files this harness writes, never spawns a process.

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

local function mkTempDir(suffix)
    local base = os.getenv("TMPDIR") or "/tmp"
    local dir = base .. "/stemwerk-check-result-render-" .. tostring(suffix) .. "-" .. tostring(os.time()) .. tostring(math.random(1, 999999))
    os.execute((IS_WINDOWS and "mkdir " or "mkdir -p ") .. "\"" .. dir .. "\"")
    return dir
end

local function writeFile(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

-- Records every gfx.drawstr() call as { text = ..., x = ..., y = ... },
-- using the CURRENT gfx.x/gfx.y at call time (matching how the real gfx.*
-- drawing API works: x/y are separate assignments consumed by the next
-- drawstr). Every other gfx.* method is a harmless no-op; measurestr
-- returns a plausible pixel width so wrapping/ellipsizing logic in the
-- renderer does not error.
local function makeGfxMock()
    local drawCalls = {}
    local g = { mouse_wheel = 0, mouse_cap = 0, w = 1400, h = 900 }
    setmetatable(g, {
        __index = function(t, k)
            return function(a, ...)
                if k == "drawstr" then
                    drawCalls[#drawCalls + 1] = { text = tostring(a or ""), x = rawget(t, "x") or 0, y = rawget(t, "y") or 0 }
                    return
                end
                if k == "measurestr" then
                    return (tostring(a or ""):len() * 7), 12
                end
                if k == "getchar" then
                    return 0
                end
                return 0
            end
        end,
    })
    return g, drawCalls
end

local function loadTargetWithOS(reportedOS)
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
    local drawCalls
    gfx, drawCalls = makeGfxMock()
    local ok, err = pcall(dofile, TARGET)
    assertf(ok, "failed to load " .. TARGET .. " for GetOS()=" .. tostring(reportedOS) .. ": " .. tostring(err))
    assertf(type(showDeferredFinalWindow) == "function", "showDeferredFinalWindow was not exposed as a global function")
    assertf(type(linuxSetupTick) == "function", "linuxSetupTick was not exposed as a global function")
    assertf(type(buildCurrentLinuxCheckResultLines) == "function", "buildCurrentLinuxCheckResultLines was not exposed as a global function")
    assertf(type(linuxHistoricalBannerAppliesOnThisOS) == "function", "linuxHistoricalBannerAppliesOnThisOS was not exposed as a global function")
    assertf(type(splitHistoricalLogBanner) == "function", "splitHistoricalLogBanner was not exposed as a global function")
    assertf(type(historicalCheckOnlyLogMarkerText) == "function", "historicalCheckOnlyLogMarkerText was not exposed as a global function")
    return drawCalls
end

-- Drives one full Check-only-final render: writes a bootstrap.log with the
-- given historical raw lines, opens the deferred final window exactly as
-- verifyExistingSetup does (showDeferredFinalWindow with a real checkVerdict
-- shape), then runs one real linuxSetupTick() to render it. Returns the
-- recorded drawstr calls plus LINUX_SETUP's own recorded logRect (so
-- assertions can compare banner/content Y positions against the scrollable
-- area's actual bounds) via a second, tiny global test hook.
local function renderCheckOnlyFinal(osValue, historicalLines, verdict, finalSuccess)
    local drawCalls = loadTargetWithOS(osValue)
    local dir = mkTempDir("case")
    local runtime = { runtimeState = dir, runtimeLogs = dir, base = dir }
    local logFile = dir .. "/bootstrap.log"
    writeFile(logFile, table.concat(historicalLines, "\n") .. (#historicalLines > 0 and "\n" or ""))
    local stateFile = dir .. "/bootstrap.env"
    showDeferredFinalWindow(runtime, stateFile, logFile, { "Verify only: done." }, finalSuccess, "/fake/separator.py", nil, verdict)
    linuxSetupTick()
    -- LINUX_SETUP itself is not reachable (module-local); the log/scrollbar
    -- rects it computes each render are only observable through the actual
    -- drawstr positions this harness already records, which is sufficient
    -- for every assertion below (banner vs. content Y ordering).
    return drawCalls
end

local function findDrawCall(drawCalls, text)
    for _, c in ipairs(drawCalls) do
        if c.text == text then return c end
    end
    return nil
end

local function findDrawCallContaining(drawCalls, needle)
    for _, c in ipairs(drawCalls) do
        if c.text:find(needle, 1, true) then return c end
    end
    return nil
end

local function countDrawCallsExactly(drawCalls, text)
    local n = 0
    for _, c in ipairs(drawCalls) do
        if c.text == text then n = n + 1 end
    end
    return n
end

local SUCCESS_VERDICT = { isCheckOnly = true, verifiedRuntimeOk = true, backend = "rocm", backendReason = "", adjustedErrors = {}, allBasicChecksOk = true }
local FAILED_VERDICT = { isCheckOnly = true, verifiedRuntimeOk = false, backend = "cpu", backendReason = "no_gpu_detected", adjustedErrors = { "no_gpu_detected" }, notProvenOnly = false, allBasicChecksOk = true }

-- =======================================================================
-- 1) Banner is actually drawn above/outside the scrollable console: its Y
-- position is strictly above the first CONTENT row's Y.
-- 2) The historical marker is not duplicated as an ordinary scroll line.
-- 3) The current-Check section is below the historical content.
-- 4) The initial viewport (default render, no scroll input at all) already
-- contains the actual end lines (the Current Check section's own text).
-- =======================================================================
local function testBannerDrawnAboveContentAndCurrentSectionVisibleAtBottom()
    local historical = { "Setup run started (repair)", "Mode: repair", "Successfully installed pip-26.2.1" }
    local drawCalls = renderCheckOnlyFinal("Other", historical, SUCCESS_VERDICT, true)

    local marker = historicalCheckOnlyLogMarkerText()
    assertf(countDrawCallsExactly(drawCalls, marker) == 1, "the historical marker must be drawn exactly once (as the fixed banner), not duplicated as an ordinary content row")
    local bannerCall = findDrawCall(drawCalls, marker)
    assertf(bannerCall ~= nil, "the historical banner text must actually be drawn")

    local firstHistoricalCall = findDrawCallContaining(drawCalls, "Mode: repair")
    assertf(firstHistoricalCall ~= nil, "historical content must still be rendered")
    assertf(bannerCall.y < firstHistoricalCall.y, "the banner must be drawn ABOVE the scrollable content, got banner.y=" .. tostring(bannerCall.y) .. " content.y=" .. tostring(firstHistoricalCall.y))

    local titleCall = findDrawCall(drawCalls, "Status: OK")
    assertf(titleCall ~= nil, "the Current Check result's Status line must actually be rendered (visible without scrolling)")
    assertf(titleCall.y > firstHistoricalCall.y, "the Current Check result section must be positioned BELOW the historical content, got status.y=" .. tostring(titleCall.y) .. " historical.y=" .. tostring(firstHistoricalCall.y))

    local sectionTitleCall = findDrawCall(drawCalls, "--- Current Check result ---")
    assertf(sectionTitleCall ~= nil, "the Current Check result section title must be rendered")
    assertf(sectionTitleCall.y > firstHistoricalCall.y, "the section title itself must also be below the historical content")

    print("PASS banner-drawn-above-content-and-current-section-visible-at-bottom")
end

-- =======================================================================
-- 5/6) Short and long historical logs both still show the Current Check
-- result section in the initial viewport.
-- =======================================================================
local function testShortAndLongLogsBothShowCurrentSectionInitially()
    local shortLog = { "one historical line" }
    local drawCallsShort = renderCheckOnlyFinal("Other", shortLog, SUCCESS_VERDICT, true)
    assertf(findDrawCall(drawCallsShort, "Status: OK") ~= nil, "a short historical log must still show the Current Check result initially")

    local longLog = {}
    for i = 1, 300 do longLog[i] = "historical line " .. i end
    local drawCallsLong = renderCheckOnlyFinal("Other", longLog, SUCCESS_VERDICT, true)
    assertf(findDrawCall(drawCallsLong, "Status: OK") ~= nil, "a long (300-line) historical log must still show the Current Check result initially, without manual scrolling")
    -- The long log's oldest lines must NOT be part of the initial viewport
    -- (they only fit if the console opened at the bottom, as intended).
    assertf(findDrawCall(drawCallsLong, "historical line 1") == nil, "the very oldest historical line must not be part of the initial (bottom) viewport in a long log")

    print("PASS short-and-long-logs-both-show-current-section-initially")
end

-- =======================================================================
-- 7/8) Zero, one, and multiple marker-LOOKING lines: only a genuine
-- position-1 marker (prepended by labelHistoricalCheckOnlyLogLines) is ever
-- treated as the banner; ordinary log content that merely happens to look
-- like the marker text elsewhere in the buffer is never abusively removed
-- or promoted to a banner.
-- =======================================================================
local function testMarkerCountVariationsNeverAbusivelyRemoveOrdinaryContent()
    local marker = historicalCheckOnlyLogMarkerText()

    -- Zero markers: a live (non-Check) render never gets one at all.
    local zeroBanner, zeroBody = splitHistoricalLogBanner({ "a", "b" })
    assertf(zeroBanner == nil and #zeroBody == 2, "zero markers: no banner, body untouched")

    -- One marker at position 1 (the only real production shape): peeled.
    local oneBanner, oneBody = splitHistoricalLogBanner({ marker, "a", "b" })
    assertf(oneBanner == marker and #oneBody == 2, "one marker at position 1: peeled into the banner")

    -- A marker-LOOKING line elsewhere in the buffer (not position 1) must
    -- never be treated as a banner, and must survive untouched as ordinary
    -- content -- e.g. a historical log that genuinely contains this exact
    -- sentence as literal past output for some unrelated reason.
    local coincidental = { "a", marker, "b" }
    local coincidentalBanner, coincidentalBody = splitHistoricalLogBanner(coincidental)
    assertf(coincidentalBanner == nil, "a marker-looking line NOT at position 1 must never be treated as the banner")
    assertf(#coincidentalBody == 3 and coincidentalBody[2] == marker, "a marker-looking line NOT at position 1 must be preserved verbatim as ordinary content, not removed")

    -- Same, proven through the real renderer: a historical log whose SECOND
    -- raw line happens to equal the marker text produces TWO occurrences by
    -- construction -- the real banner (prepended fresh at position 1 by
    -- labelHistoricalCheckOnlyLogLines for this Check-only render) plus the
    -- coincidental one surviving, un-removed, as an ordinary content row.
    -- What matters is that the coincidental line is never dropped, and
    -- everything after it still renders too.
    local drawCalls = renderCheckOnlyFinal("Other", { "first line", marker, "third line" }, SUCCESS_VERDICT, true)
    assertf(countDrawCallsExactly(drawCalls, marker) == 2,
        "a coincidental marker-looking historical line must survive as an ordinary row alongside the real banner (2 total), not be deduplicated/removed, got " .. tostring(countDrawCallsExactly(drawCalls, marker)))
    assertf(findDrawCallContaining(drawCalls, "first line") ~= nil, "content before the coincidental marker-looking line must still render")
    assertf(findDrawCallContaining(drawCalls, "third line") ~= nil, "content after the coincidental marker-looking line must still render (nothing truncated)")

    print("PASS marker-count-variations-never-abusively-remove-ordinary-content")
end

-- =======================================================================
-- 9/10) Successful and failed Checks must both be unambiguous.
-- =======================================================================
local function testSuccessfulAndFailedChecksAreUnambiguous()
    local drawCallsOk = renderCheckOnlyFinal("Other", { "old log" }, SUCCESS_VERDICT, true)
    assertf(findDrawCall(drawCallsOk, "Status: OK") ~= nil, "a successful Check must show Status: OK")
    assertf(findDrawCall(drawCallsOk, "Backend: rocm") ~= nil, "a successful Check must show the actual current backend")
    assertf(findDrawCallContaining(drawCallsOk, "Reason:") == nil, "a successful Check must not show a Reason line")

    local drawCallsFailed = renderCheckOnlyFinal("Other", { "old log" }, FAILED_VERDICT, false)
    assertf(findDrawCall(drawCallsFailed, "Status: FAILED") ~= nil, "a failed Check must show Status: FAILED")
    assertf(findDrawCall(drawCallsFailed, "Reason: no_gpu_detected") ~= nil, "a failed Check must show its actual current reason")

    print("PASS successful-and-failed-checks-are-unambiguous")
end

-- =======================================================================
-- Missing optional fields are omitted, never filled in as a misleading
-- "OK"/backend claim.
-- =======================================================================
local function testMissingOptionalFieldsAreOmittedNotFilledIn()
    local sparseVerdict = { isCheckOnly = true, verifiedRuntimeOk = true, backend = "", backendReason = "", adjustedErrors = {}, allBasicChecksOk = true }
    local lines = buildCurrentLinuxCheckResultLines("ok", sparseVerdict, "")
    local text = table.concat(lines, "\n")
    assertf(not text:find("Profile:", 1, true), "an empty profile must be omitted entirely, not shown as blank/misleading")
    assertf(not text:find("Backend:", 1, true), "an empty backend must be omitted entirely, not shown as blank/misleading")
    assertf(text:find("Status: OK", 1, true) ~= nil, "Status must always be present")
    print("PASS missing-optional-fields-are-omitted-not-filled-in")
end

-- =======================================================================
-- 12) macOS and Windows must never get this Linux presentation: no banner,
-- no Current Check result section -- the console renders exactly as it did
-- on baseline (only the historical content, untouched).
-- =======================================================================
local function testMacosAndWindowsNeverGetTheLinuxPresentation()
    for _, osValue in ipairs({ "OSX64", "Win64" }) do
        local drawCalls = renderCheckOnlyFinal(osValue, { "Mode: repair", "Successfully installed pip-26.2.1" }, SUCCESS_VERDICT, true)
        assertf(findDrawCall(drawCalls, historicalCheckOnlyLogMarkerText()) == nil, osValue .. " must never render the Linux historical banner")
        assertf(findDrawCall(drawCalls, "--- Current Check result ---") == nil, osValue .. " must never render the Linux Current Check result section")
        assertf(findDrawCall(drawCalls, "Status: OK") == nil, osValue .. " must never render a Status: line at all")
        assertf(findDrawCallContaining(drawCalls, "Mode: repair") ~= nil, osValue .. " must still render its ordinary historical content untouched")
    end
    print("PASS macos-and-windows-never-get-the-linux-presentation")
end

local tests = {
    { "banner-drawn-above-content-and-current-section-visible-at-bottom", testBannerDrawnAboveContentAndCurrentSectionVisibleAtBottom },
    { "short-and-long-logs-both-show-current-section-initially", testShortAndLongLogsBothShowCurrentSectionInitially },
    { "marker-count-variations-never-abusively-remove-ordinary-content", testMarkerCountVariationsNeverAbusivelyRemoveOrdinaryContent },
    { "successful-and-failed-checks-are-unambiguous", testSuccessfulAndFailedChecksAreUnambiguous },
    { "missing-optional-fields-are-omitted-not-filled-in", testMissingOptionalFieldsAreOmittedNotFilledIn },
    { "macos-and-windows-never-get-the-linux-presentation", testMacosAndWindowsNeverGetTheLinuxPresentation },
}

for _, t in ipairs(tests) do
    local name, fn = t[1], t[2]
    local testOk, testErr = pcall(fn)
    if not testOk then
        io.stderr:write("FAIL " .. name .. ": " .. tostring(testErr) .. "\n")
        os.exit(1)
    end
end

print("All headless Current Check result render tests passed.")
