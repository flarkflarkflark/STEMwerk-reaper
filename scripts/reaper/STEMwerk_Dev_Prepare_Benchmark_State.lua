-- STEMwerk: Dev Prepare Benchmark State
-- dev/test helper for MCP benchmark automation
-- Read-only audio/project content policy: no tracks/items/takes are created, removed, or saved.

local EXT_SECTION = "STEMwerk"
local PREP_SECTION = "STEMwerkDevBenchmarkPrep"
local REQUESTED_ITEM_COUNT = 8

if not reaper then
    return
end

local function trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeSet(section, key, value)
    reaper.SetExtState(section, tostring(key or ""), tostring(value or "unknown"), true)
end

local function asUnknown(value)
    local text = trim(value)
    if text == "" then
        return "unknown"
    end
    return text
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

local function countSelectedMediaItems()
    if type(reaper.CountSelectedMediaItems) ~= "function" then
        return "unknown"
    end
    local ok, count = pcall(reaper.CountSelectedMediaItems, 0)
    if ok and type(count) == "number" then
        return tostring(count)
    end
    return "unknown"
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

local function selectExactItems(items)
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
end

local function writeWorkflowExtState()
    local values = {
        workflow_source = "dks_direct",
        workflow_mode = "drumkit",
        device = "auto",
        active_workflow_source = "dks_direct",
        active_workflow_mode = "drumkit",
        quick_run = "1",
        quick_preset = "dks_direct",
    }
    for key, value in pairs(values) do
        reaper.SetExtState(EXT_SECTION, key, value, false)
    end
    return values
end

local function writePrepResult(fields)
    for key, value in pairs(fields) do
        safeSet(PREP_SECTION, key, value)
    end
end

local function buildFailure(fields, message)
    fields.prep_ok = "0"
    fields.last_error = asUnknown(message)
    writePrepResult(fields)
end

local function buildSuccess(fields)
    fields.prep_ok = "1"
    fields.last_error = ""
    writePrepResult(fields)
end

local function main()
    local fields = {
        requested_item_count = tostring(REQUESTED_ITEM_COUNT),
        selected_media_item_count = countSelectedMediaItems(),
        selection_source = "failed",
        time_selection_start = "unknown",
        time_selection_end = "unknown",
        workflow_source_set = "dks_direct",
        workflow_mode_set = "drumkit",
        device_set = "auto",
        last_error = "",
        prep_ok = "0",
    }

    local startTime, endTime, length = readTimeSelection()
    fields.time_selection_start = formatTime(startTime)
    fields.time_selection_end = formatTime(endTime)
    if type(length) == "number" then
        fields.time_selection_length = formatTime(length)
    else
        fields.time_selection_length = "unknown"
    end

    local allItems = collectProjectItems()
    local selectedItems = {}
    local selectionSource = "failed"

    if startTime and endTime then
        local timeSelectionItems = collectTimeSelectionItems(allItems, startTime, endTime)
        if #timeSelectionItems >= REQUESTED_ITEM_COUNT then
            selectedItems = {}
            for i = 1, REQUESTED_ITEM_COUNT do
                selectedItems[#selectedItems + 1] = timeSelectionItems[i]
            end
            selectionSource = "time_selection"
        elseif #allItems >= REQUESTED_ITEM_COUNT then
            selectedItems = {}
            for i = 1, REQUESTED_ITEM_COUNT do
                selectedItems[#selectedItems + 1] = allItems[i]
            end
            selectionSource = "project_first_items"
        end
    elseif #allItems >= REQUESTED_ITEM_COUNT then
        selectedItems = {}
        for i = 1, REQUESTED_ITEM_COUNT do
            selectedItems[#selectedItems + 1] = allItems[i]
        end
        selectionSource = "project_first_items"
    end

    if #selectedItems < REQUESTED_ITEM_COUNT then
        local available = #allItems
        local timeSelectionCount = 0
        if startTime and endTime then
            timeSelectionCount = #collectTimeSelectionItems(allItems, startTime, endTime)
        end
        buildFailure(fields, string.format(
            "insufficient_media_items: need=%d available=%d time_selection_available=%d",
            REQUESTED_ITEM_COUNT,
            available,
            timeSelectionCount
        ))
        return
    end

    local ok, err = pcall(function()
        selectExactItems(selectedItems)
        local workflowValues = writeWorkflowExtState()
        fields.selected_media_item_count = tostring(#selectedItems)
        fields.selection_source = selectionSource
        fields.workflow_source_set = workflowValues.workflow_source
        fields.workflow_mode_set = workflowValues.workflow_mode
        fields.device_set = workflowValues.device
        buildSuccess(fields)
    end)

    if not ok then
        buildFailure(fields, err)
    end
end

main()
