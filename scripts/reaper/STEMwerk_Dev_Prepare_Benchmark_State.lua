-- STEMwerk: Dev Prepare Benchmark State
-- dev/test compatibility wrapper for the benchmark snapshot dispatcher
-- It primes STEMwerk/dev_mcp_request and then invokes the registered snapshot helper.

local MCP_SECTION = "STEMwerk"
local SNAPSHOT_COMMAND_ID = 71254

if not reaper then
    return
end

local function setTransientExtState(key, value)
    reaper.SetExtState(MCP_SECTION, tostring(key or ""), tostring(value or ""), false)
end

local function main()
    setTransientExtState("dev_mcp_request", "prepare_benchmark_state")
    setTransientExtState("dev_mcp_requested_item_count", "8")
    setTransientExtState("dev_mcp_workflow_source", "dks_direct")
    setTransientExtState("dev_mcp_workflow_mode", "drumkit")
    setTransientExtState("dev_mcp_device", "auto")

    if type(reaper.Main_OnCommand) == "function" then
        reaper.Main_OnCommand(SNAPSHOT_COMMAND_ID, 0)
    end
end

main()
