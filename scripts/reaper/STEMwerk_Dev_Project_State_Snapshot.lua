-- STEMwerk: Dev Project State Snapshot
-- dev/test helper for MCP smoke/benchmark automation
-- Read-only helper: captures project state and writes it to ExtState only.

local SNAPSHOT_SECTION = "STEMwerkDevSnapshot"

if not reaper then
    return
end

local function trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeSet(key, value)
    reaper.SetExtState(SNAPSHOT_SECTION, tostring(key or ""), tostring(value or "unknown"), true)
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

local function countSelectedTracks()
    local ok, count = safeCall(reaper.CountSelectedTracks, 0)
    if ok and type(count) == "number" then
        return count
    end
    return "unknown"
end

local function countSelectedMediaItems()
    local ok, count = safeCall(reaper.CountSelectedMediaItems, 0)
    if ok and type(count) == "number" then
        return count
    end
    return "unknown"
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

local function getTimeSelection()
    if type(reaper.GetSet_LoopTimeRange) ~= "function" then
        return "unknown", "unknown", "unknown"
    end

    local ok, startTime, endTime = pcall(reaper.GetSet_LoopTimeRange, false, false, 0, 0, false)
    if not ok then
        return "unknown", "unknown", "unknown"
    end
    if type(startTime) ~= "number" or type(endTime) ~= "number" or endTime <= startTime then
        return "unknown", "unknown", "unknown"
    end
    return string.format("%.6f", startTime), string.format("%.6f", endTime), string.format("%.6f", endTime - startTime)
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

        local mediaItemCount = 0
        if type(reaper.CountMediaItems) == "function" then
            local count = reaper.CountMediaItems(0)
            if type(count) == "number" then
                mediaItemCount = count
                snapshot.media_item_count = tostring(count)
            end
        end

        snapshot.selected_media_item_count = tostring(countSelectedMediaItems())
        snapshot.take_count_total = tostring(countTrackTakes(trackCount))
        snapshot.selected_take_count = tostring(countSelectedTakes())

        local tsStart, tsEnd, tsLen = getTimeSelection()
        snapshot.time_selection_start = tsStart
        snapshot.time_selection_end = tsEnd
        snapshot.time_selection_length = tsLen

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

local snapshot = buildSnapshot()
for key, value in pairs(snapshot) do
    safeSet(key, value)
end
