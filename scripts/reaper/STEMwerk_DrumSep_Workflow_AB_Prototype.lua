--[[
PRIVATE R&D ONLY - NOT FOR REAPACK/PUBLIC RELEASE

AB smoke runner for DrumSep workflow prototype:
1) clean_fast
2) clean_quality
3) clean_6stem
on the same resolved source set (selected items or time selection).
]]

local function getScriptDir()
    local _, scriptPath = reaper.get_action_context()
    if not scriptPath or scriptPath == "" then return nil end
    return scriptPath:match("^(.*[/\\])")
end

local function pathJoin(a, b)
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
    local sep = package.config:sub(1, 1) or "/"
    return a .. sep .. b
end

local function nowSeconds()
    if reaper and reaper.time_precise then
        return reaper.time_precise()
    end
    return os.clock()
end

local function stemList(result)
    if not result or not result.imported_stems or #result.imported_stems == 0 then
        return "(none)"
    end
    return table.concat(result.imported_stems, ",")
end

local function isPrototypeActionAllowed()
    if not (reaper and reaper.GetExtState) then
        return false
    end
    local v = tostring(reaper.GetExtState("STEMwerk-dev", "allow_drumkit_prototype_actions") or ""):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function logLine(msg)
    reaper.ShowConsoleMsg("[DrumSep AB Prototype] " .. tostring(msg) .. "\n")
end

local function runAB()
    local scriptDir = getScriptDir()
    if not scriptDir then
        reaper.ShowMessageBox("Could not resolve script directory.", "STEMwerk DrumSep AB Prototype", 0)
        return
    end

    local workflowPath = pathJoin(scriptDir, "STEMwerk_DrumSep_Workflow_Prototype.lua")
    logLine("DrumSep AB prototype smoke")
    logLine("workflow_script=" .. workflowPath)

    local prevNoAuto = rawget(_G, "STEMWERK_DRUMSEP_WORKFLOW_NO_AUTORUN")
    _G.STEMWERK_DRUMSEP_WORKFLOW_NO_AUTORUN = true
    local api = dofile(workflowPath)
    _G.STEMWERK_DRUMSEP_WORKFLOW_NO_AUTORUN = prevNoAuto

    if type(api) ~= "table" or type(api.runDrumSepWorkflowPrototype) ~= "function" then
        reaper.ShowMessageBox("Failed to load DrumSep workflow prototype API.", "STEMwerk DrumSep AB Prototype", 0)
        return
    end

    local opts = {
        suppressSuccessMessage = true,
        suppressFailureMessage = true,
    }

    logLine("direct_creative_status=experimental_parked_due_bleed")

    local t0 = nowSeconds()
    logLine("mode=clean_fast start")
    local fast = api.runDrumSepWorkflowPrototype("clean_fast", opts)
    logLine("mode=clean_fast ok=" .. tostring(fast and fast.ok == true))
    logLine("mode=clean_fast temp_root=" .. tostring(fast and fast.temp_root or ""))
    logLine("mode=clean_fast imported_stems=" .. stemList(fast))
    if fast and not fast.ok then
        logLine("mode=clean_fast error_stage=" .. tostring(fast.error_stage or ""))
        logLine("mode=clean_fast error_message=" .. tostring(fast.error_message or ""))
        logLine("mode=clean_fast log_path=" .. tostring(fast.log_path or ""))
    end

    local quality = nil
    local skipQuality = (fast and fast.ok == false and fast.error_stage == "stage0")
    if skipQuality then
        logLine("mode=clean_quality skipped due clean_fast stage0 failure")
    else
        logLine("mode=clean_quality start")
        quality = api.runDrumSepWorkflowPrototype("clean_quality", opts)
        logLine("mode=clean_quality ok=" .. tostring(quality and quality.ok == true))
        logLine("mode=clean_quality temp_root=" .. tostring(quality and quality.temp_root or ""))
        logLine("mode=clean_quality imported_stems=" .. stemList(quality))
        if quality and not quality.ok then
            logLine("mode=clean_quality error_stage=" .. tostring(quality.error_stage or ""))
            logLine("mode=clean_quality error_message=" .. tostring(quality.error_message or ""))
            logLine("mode=clean_quality log_path=" .. tostring(quality.log_path or ""))
        end
    end

    local sixStem = nil
    local skipSixStem = (fast and fast.ok == false and fast.error_stage == "stage0")
    if skipSixStem then
        logLine("mode=clean_6stem skipped due clean_fast stage0 failure")
    else
        logLine("mode=clean_6stem start")
        sixStem = api.runDrumSepWorkflowPrototype("clean_6stem", opts)
        logLine("mode=clean_6stem ok=" .. tostring(sixStem and sixStem.ok == true))
        logLine("mode=clean_6stem temp_root=" .. tostring(sixStem and sixStem.temp_root or ""))
        logLine("mode=clean_6stem imported_stems=" .. stemList(sixStem))
        if sixStem and not sixStem.ok then
            logLine("mode=clean_6stem error_stage=" .. tostring(sixStem.error_stage or ""))
            logLine("mode=clean_6stem error_message=" .. tostring(sixStem.error_message or ""))
            logLine("mode=clean_6stem log_path=" .. tostring(sixStem.log_path or ""))
        end
    end

    local elapsed = nowSeconds() - t0
    local fastStatus = (fast and fast.ok) and "PASS" or "FAIL"
    local qualityStatus
    if skipQuality then
        qualityStatus = "SKIPPED (clean_fast stage0 failure)"
    else
        qualityStatus = (quality and quality.ok) and "PASS" or "FAIL"
    end
    local sixStemStatus
    if skipSixStem then
        sixStemStatus = "SKIPPED (clean_fast stage0 failure)"
    else
        sixStemStatus = (sixStem and sixStem.ok) and "PASS" or "FAIL"
    end

    local lines = {
        "DrumSep AB prototype smoke complete",
        "",
        "clean_fast: " .. fastStatus,
        "  temp_root: " .. tostring(fast and fast.temp_root or ""),
        "  imported: " .. stemList(fast),
        "",
        "clean_quality: " .. qualityStatus,
        "  temp_root: " .. tostring(quality and quality.temp_root or ""),
        "  imported: " .. stemList(quality),
        "",
        "clean_6stem: " .. sixStemStatus,
        "  temp_root: " .. tostring(sixStem and sixStem.temp_root or ""),
        "  imported: " .. stemList(sixStem),
        "",
        "elapsed_seconds: " .. string.format("%.3f", elapsed),
    }
    reaper.ShowMessageBox(table.concat(lines, "\n"), "STEMwerk DrumSep AB Prototype", 0)
end

if not isPrototypeActionAllowed() then
    reaper.ShowMessageBox(
        "This Drum Kit Split prototype action is disabled outside development builds.\n\nSet STEMwerk-dev/allow_drumkit_prototype_actions=1 to enable.",
        "STEMwerk Drum Kit Split",
        0
    )
    return
end

runAB()
