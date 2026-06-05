-- STEMwerk: Dev Project State Snapshot
-- dev/test helper for MCP smoke/benchmark automation
-- Default behavior: read-only snapshot to ExtState.
-- Explicit request flow: when STEMwerkDevMCP/request == prepare_benchmark_state,
-- this helper also prepares benchmark state before writing the snapshot.

local MCP_SECTION = "STEMwerkDevMCP"
local SNAPSHOT_SECTION = "STEMwerkDevSnapshot"
local PREP_SECTION = "STEMwerkDevBenchmarkPrep"
local REQUEST_PREPARE_BENCHMARK_STATE = "prepare_benchmark_state"
local DEFAULT_REQUESTED_ITEM_COUNT = 8

if not reaper then
    return
end

local function trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeSet(section, key, value, persist)
    reaper.SetExtState(section, tostring(key or ""), tostring(value or "unknown"), persist and true or false)
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function asUnknown(value)
    local text = trim(value)
    if text == "" then
        return "unknown"
    end
    return text
end

local function getExtState(section, key)
    return trim(reaper.GetExtState(section, key))
end

local function readRequestedItemCount()
    local requested = tonumber(getExtState(MCP_SECTION, "requested_item_count"))
    if type(requested) ~= "number" or requested < 1 then
        return DEFAULT_REQUESTED_ITEM_COUNT
    end
    return math.floor(requested)
end

local function readBenchmarkRequest()
    local request = getExtState(MCP_SECTION, "request")
    if request ~= REQUEST_PREPARE_BENCHMARK_STATE then
        return nil
    end

    local requestState = {
        request = request,
        requested_item_count = readRequestedItemCount(),
        workflow_source = getExtState(MCP_SECTION, "workflow_source"),
        workflow_mode = getExtState(MCP_SECTION, "workflow_mode"),
        device = getExtState(MCP_SECTION, "device"),
    }

    if requestState.workflow_source == "" then
        requestState.workflow_source = "dks_direct"
    end
    if requestState.workflow_mode == "" then
        requestState.workflow_mode = "drumkit"
    end
    if requestState.device == "" then
        requestState.device = "auto"
    end

    return requestState
end

local function countSelectedTracks()
    local ok, count = safeCall(reaper.CountSelectedTracks, 0)
    if ok and type(count) == "number" then
        return count
    end
    return "unknown"
end

local function countSelectedMediaItemsText()
    local ok, count = safeCall(reaper.CountSelectedMediaItems, 0)
    if ok and type(count) == "number" then
        return tostring(count)
    end
    return "unknown"
end

local function countSelectedMediaItemsNumber()
    local ok, count = safeCall(reaper.CountSelectedMediaItems, 0)
    if ok and type(count) == "number" then
        return count
    end
    return nil
end

local function countTrackTakes(trackCount)
    if type(reaper.CountTracks) ~= "function" or type(reaper.GetTrack) ~= "function" or type(reaper.CountTrackMediaItems) ~= "function" then
        return "unknown"
    end

    local total = 0
    local maxTracks = tonumber(trackCount) or 0
    for i = 0, math.max(0, maxTracks - 1) do
        local track = reaper.GetTrack(0, i)
        if track then
            local itemCount = reaper.CountTrackMediaItems(track) or 0
            for j = 0, math.max(0, itemCount - 1) do
                local item = reaper.GetTrackMediaItem(track, j)
                if item then
                    total = total + (reaper.CountTakes(item) or 0)
                end
            end
        end
    end
    return total
end

local function countSelectedTakes()
    if type(reaper.CountSelectedMediaItems) ~= "function" or type(reaper.GetSelectedMediaItem) ~= "function" then
        return "unknown"
    end

    local total = 0
    local selectedItemCount = reaper.CountSelectedMediaItems(0) or 0
    for i = 0, math.max(0, selectedItemCount - 1) do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            total = total + (reaper.CountTakes(item) or 0)
        end
    end
    return total
end

local function countProjectMediaItems()
    if type(reaper.CountMediaItems) ~= "function" then
        return 0
    end
    local ok, count = pcall(reaper.CountMediaItems, 0)
    if ok and type(count) == "number" and count > 0 then
        return count
    end
    return 0
end

local function getProjectMediaItem(index)
    if type(reaper.GetMediaItem) ~= "function" then
        return nil
    end
    local ok, item = pcall(reaper.GetMediaItem, 0, index)
    if ok then
        return item
    end
    return nil
end

local function getItemBounds(item)
    if type(reaper.GetMediaItemInfo_Value) ~= "function" then
        return nil, nil
    end
    local okPos, position = pcall(reaper.GetMediaItemInfo_Value, item, "D_POSITION")
    local okLen, length = pcall(reaper.GetMediaItemInfo_Value, item, "D_LENGTH")
    if not okPos or not okLen then
        return nil, nil
    end
    if type(position) ~= "number" or type(length) ~= "number" then
        return nil, nil
    end
    return position, position + length
end

local function itemOverlapsRange(item, startTime, endTime)
    if not item or type(startTime) ~= "number" or type(endTime) ~= "number" then
        return false
    end
    local itemStart, itemEnd = getItemBounds(item)
    if type(itemStart) ~= "number" or type(itemEnd) ~= "number" then
        return false
    end
    return itemStart < endTime and itemEnd > startTime
end

local function collectProjectItems()
    local count = countProjectMediaItems()
    local items = {}
    for i = 0, math.max(0, count - 1) do
        local item = getProjectMediaItem(i)
        if item then
            items[#items + 1] = item
        end
    end
    return items
end

local function collectTimeSelectionItems(items, startTime, endTime)
    if type(startTime) ~= "number" or type(endTime) ~= "number" or endTime <= startTime then
        return {}
    end
    local selected = {}
    for _, item in ipairs(items) do
        if itemOverlapsRange(item, startTime, endTime) then
            selected[#selected + 1] = item
        end
    end
    return selected
end

local function selectExactItems(items, expectedCount)
    if type(reaper.SelectAllMediaItems) == "function" then
        reaper.SelectAllMediaItems(0, false)
    else
        for i = 0, math.max(0, countProjectMediaItems() - 1) do
            local item = getProjectMediaItem(i)
            if item and type(reaper.SetMediaItemSelected) == "function" then
                reaper.SetMediaItemSelected(item, false)
            end
        end
    end

    for _, item in ipairs(items) do
        if type(reaper.SetMediaItemSelected) == "function" then
            reaper.SetMediaItemSelected(item, true)
        end
    end

    if type(reaper.UpdateArrange) == "function" then
        reaper.UpdateArrange()
    end

    local selectedCount = countSelectedMediaItemsNumber()
    if selectedCount and selectedCount ~= expectedCount then
        return false, string.format("selection_mismatch: expected=%d actual=%d", expectedCount, selectedCount)
    end

    return true, nil
end

local function readTimeSelection()
    if type(reaper.GetSet_LoopTimeRange) ~= "function" then
        return nil, nil, nil
    end
    local ok, startTime, endTime = pcall(reaper.GetSet_LoopTimeRange, false, false, 0, 0, false)
    if not ok or type(startTime) ~= "number" or type(endTime) ~= "number" or endTime <= startTime then
        return nil, nil, nil
    end
    return startTime, endTime, endTime - startTime
end

local function formatTime(value)
    if type(value) ~= "number" then
        return "unknown"
    end
    return string.format("%.6f", value)
end

local function getProjectPath()
    if type(reaper.GetProjectPathEx) == "function" then
        local ok, result = pcall(reaper.GetProjectPathEx, 0, "")
        if ok and type(result) == "string" and trim(result) ~= "" then
            return result
        end
    end
    if type(reaper.GetProjectPath) == "function" then
        local ok, result = pcall(reaper.GetProjectPath, "")
        if ok and type(result) == "string" and trim(result) ~= "" then
            return result
        end
    end
    return "unknown"
end

local function getProjectName()
    if type(reaper.GetProjectName) ~= "function" then
        return "unknown"
    end
    local ok, _, name = pcall(reaper.GetProjectName, 0, "")
    if ok and type(name) == "string" and trim(name) ~= "" then
        return name
    end
    return "unknown"
end

local function getProjectDirty()
    if type(reaper.GetProjectStateChangeCount) ~= "function" then
        return "unknown"
    end
    local ok, count = pcall(reaper.GetProjectStateChangeCount, 0)
    if ok and type(count) == "number" then
        return count > 0 and "1" or "0"
    end
    return "unknown"
end

local function writeSnapshot(snapshot)
    for key, value in pairs(snapshot) do
        safeSet(SNAPSHOT_SECTION, key, value, true)
    end
end

local function writePrepResult(fields)
    for key, value in pairs(fields) do
        safeSet(PREP_SECTION, key, value, true)
    end
end

local function clearBenchmarkRequest(request)
    safeSet(MCP_SECTION, "request_handled", request or "", false)
    safeSet(MCP_SECTION, "request", "", false)
end

local function applyWorkflowExtState(values)
    for key, value in pairs(values) do
        safeSet("STEMwerk", key, value, false)
    end
    return values
end

local function buildSnapshot()
    local snapshot = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        track_count = "unknown",
        selected_track_count = "unknown",
        media_item_count = "unknown",
        selected_media_item_count = "unknown",
        take_count_total = "unknown",
        selected_take_count = "unknown",
        time_selection_start = "unknown",
        time_selection_end = "unknown",
        time_selection_length = "unknown",
        project_dirty = "unknown",
        project_path = "unknown",
        project_name = "unknown",
        last_error = "",
        snapshot_ok = "0",
    }

    local ok, err = pcall(function()
        local trackCount = 0
        if type(reaper.CountTracks) == "function" then
            local count = reaper.CountTracks(0)
            if type(count) == "number" then
                trackCount = count
                snapshot.track_count = tostring(count)
            end
        end

        snapshot.selected_track_count = tostring(countSelectedTracks())

        if type(reaper.CountMediaItems) == "function" then
            local count = reaper.CountMediaItems(0)
            if type(count) == "number" then
                snapshot.media_item_count = tostring(count)
            end
        end

        snapshot.selected_media_item_count = tostring(countSelectedMediaItemsText())
        snapshot.take_count_total = tostring(countTrackTakes(trackCount))
        snapshot.selected_take_count = tostring(countSelectedTakes())

        local tsStart, tsEnd, tsLen = readTimeSelection()
        snapshot.time_selection_start = formatTime(tsStart)
        snapshot.time_selection_end = formatTime(tsEnd)
        snapshot.time_selection_length = formatTime(tsLen)

        snapshot.project_dirty = getProjectDirty()
        snapshot.project_path = getProjectPath()
        snapshot.project_name = getProjectName()

        snapshot.snapshot_ok = "1"
    end)

    if not ok then
        snapshot.snapshot_ok = "0"
        snapshot.last_error = asUnknown(err)
    end

    return snapshot
end

local function buildPrepFields(requestState)
    return {
        prep_ok = "0",
        requested_item_count = tostring(requestState.requested_item_count),
        selected_media_item_count = countSelectedMediaItemsText(),
        selection_source = "failed",
        time_selection_start = "unknown",
        time_selection_end = "unknown",
        workflow_source_set = requestState.workflow_source,
        workflow_mode_set = requestState.workflow_mode,
        device_set = requestState.device,
        last_error = "",
    }
end

local function runBenchmarkPrep(requestState)
    local fields = buildPrepFields(requestState)
    local startTime, endTime = readTimeSelection()
    fields.time_selection_start = formatTime(startTime)
    fields.time_selection_end = formatTime(endTime)

    local allItems = collectProjectItems()
    local selectedItems = {}
    local timeSelectionItems = {}
    local selectionSource = "failed"

    if type(startTime) == "number" and type(endTime) == "number" then
        timeSelectionItems = collectTimeSelectionItems(allItems, startTime, endTime)
        if #timeSelectionItems >= requestState.requested_item_count then
            for i = 1, requestState.requested_item_count do
                selectedItems[#selectedItems + 1] = timeSelectionItems[i]
            end
            selectionSource = "time_selection"
        end
    end

    if #selectedItems < requestState.requested_item_count and #allItems >= requestState.requested_item_count then
        selectedItems = {}
        for i = 1, requestState.requested_item_count do
            selectedItems[#selectedItems + 1] = allItems[i]
        end
        selectionSource = "project_first_items"
    end

    if #selectedItems < requestState.requested_item_count then
        fields.last_error = string.format(
            "insufficient_media_items: need=%d available=%d time_selection_available=%d",
            requestState.requested_item_count,
            #allItems,
            #timeSelectionItems
        )
        writePrepResult(fields)
        clearBenchmarkRequest(requestState.request)
        return
    end

    local ok, err = pcall(function()
        local selectOk, selectErr = selectExactItems(selectedItems, requestState.requested_item_count)
        if not selectOk then
            error(selectErr)
        end

        local workflowValues = applyWorkflowExtState({
            workflow_source = requestState.workflow_source,
            workflow_mode = requestState.workflow_mode,
            device = requestState.device,
            active_workflow_source = requestState.workflow_source,
            active_workflow_mode = requestState.workflow_mode,
            quick_run = "1",
            quick_preset = requestState.workflow_source,
        })

        fields.prep_ok = "1"
        fields.selected_media_item_count = tostring(requestState.requested_item_count)
        fields.selection_source = selectionSource
        fields.workflow_source_set = workflowValues.workflow_source
        fields.workflow_mode_set = workflowValues.workflow_mode
        fields.device_set = workflowValues.device
        fields.last_error = ""
    end)

    if not ok then
        fields.prep_ok = "0"
        fields.selected_media_item_count = countSelectedMediaItemsText()
        fields.last_error = asUnknown(err)
    end

    writePrepResult(fields)
    clearBenchmarkRequest(requestState.request)
end

local function main()
    local requestState = readBenchmarkRequest()
    if requestState then
        runBenchmarkPrep(requestState)
    end

    local snapshot = buildSnapshot()
    writeSnapshot(snapshot)
end

main()
