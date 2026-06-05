-- STEMwerk: Dev Prepare Benchmark State
-- dev/test compatibility wrapper for the benchmark snapshot dispatcher
-- It primes STEMwerkDevMCP/request and then invokes the registered snapshot helper.

local MCP_SECTION = "STEMwerkDevMCP"
local SNAPSHOT_COMMAND_ID = 71254

if not reaper then
    return
end

local function setTransientExtState(key, value)
    reaper.SetExtState(MCP_SECTION, tostring(key or ""), tostring(value or ""), false)
end

local function main()
    setTransientExtState("request", "prepare_benchmark_state")
    setTransientExtState("requested_item_count", "8")
    setTransientExtState("workflow_source", "dks_direct")
    setTransientExtState("workflow_mode", "drumkit")
    setTransientExtState("device", "auto")

    if type(reaper.Main_OnCommand) == "function" then
        reaper.Main_OnCommand(SNAPSHOT_COMMAND_ID, 0)
    end
end

main()
