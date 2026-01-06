-- localsend_transfers.lua
-- Transfer logging and notification system for LocalSend plugin
-- Handles reading transfer logs, checking for new transfers, and showing notifications

local state = require("localsend_state")

local M = {}

-- Module constants
M.transfer_log_file = "/tmp/localsend_transfers.log"
M.transfer_notify_file = "/tmp/localsend_notify"
M.SENTINEL_POLL_INTERVAL = 2

-- Dependencies container (set via M.init)
local deps = {}

-- Initialize module with dependencies
-- @param d table Dependencies: { UIManager, InfoMessage, Notification, util, json, logger, T, _ }
function M.init(d)
    deps = d
end

-- ServerState reference for convenience
local function getServerState()
    return state.ServerState
end

-- Read full transfer log from disk
-- @return table Array of transfer entries
function M.getTransferLog()
    local transfers = {}
    if not deps.util.pathExists(M.transfer_log_file) then
        return transfers
    end

    local f = io.open(M.transfer_log_file, "r")
    if not f then return transfers end

    for line in f:lines() do
        local ok, entry = pcall(deps.json.decode, line)
        if ok and entry then
            table.insert(transfers, entry)
        end
    end
    f:close()

    return transfers
end

-- Optimized log reading - only reads new entries since last check
-- This is more efficient for e-reader CPUs that poll every 5 seconds
-- Uses ServerState.last_log_position to persist across widget instances
-- @return table Array of new transfer entries
function M.getNewTransfers()
    local ServerState = getServerState()
    local transfers = {}
    if not deps.util.pathExists(M.transfer_log_file) then
        ServerState.last_log_position = 0
        return transfers
    end

    local f = io.open(M.transfer_log_file, "r")
    if not f then
        ServerState.last_log_position = 0
        return transfers
    end

    -- Check if file was truncated (position beyond file size)
    local file_size = f:seek("end")
    if ServerState.last_log_position > file_size then
        ServerState.last_log_position = 0
    end

    -- Seek to last known position
    f:seek("set", ServerState.last_log_position)

    for line in f:lines() do
        local ok, entry = pcall(deps.json.decode, line)
        if ok and entry then
            table.insert(transfers, entry)
        end
    end

    -- Save new position and update cached count
    ServerState.last_log_position = f:seek()
    ServerState.transfer_count = ServerState.transfer_count + #transfers
    f:close()

    return transfers
end

-- Returns the cached transfer count (avoids file I/O on e-readers)
-- Count is updated by getNewTransfers() and cleared by clearTransferLog()
-- @return number Transfer count
function M.getTransferCount()
    return getServerState().transfer_count
end

-- Clear transfer log and reset all tracking state
function M.clearTransferLog()
    local ServerState = getServerState()
    os.remove(M.transfer_log_file)
    os.remove(M.transfer_notify_file)  -- Also remove sentinel file
    ServerState.last_log_position = 0  -- Reset position tracking when log is cleared
    ServerState.transfer_count = 0  -- Reset cached count
    ServerState.last_sentinel_value = nil  -- Reset sentinel tracking
end

-- Internal polling method for checking new transfers
-- Shows notification when new files are received
-- @param instance table LocalSend instance (for calling isRunning, getNewTransfers, _updateCache)
function M.checkForNewTransfers(instance)
    if not instance:isRunning() then
        return
    end

    -- Use optimized getNewTransfers() instead of reading the whole file
    local new_transfers = instance:getNewTransfers()
    if #new_transfers > 0 then
        -- Update cache to reflect new transfer count
        instance:_updateCache()

        local latest = new_transfers[#new_transfers]
        local text
        if #new_transfers == 1 then
            text = deps.T(deps._("File received: %1"), latest.filename)
        else
            text = deps.T(deps._("%1 files received. Latest: %2"), #new_transfers, latest.filename)
        end

        deps.UIManager:show(deps.Notification:new{
            text = text,
            timeout = 3,
        })
    end
end

-- Fast sentinel file check - reads tiny sentinel file content
-- When content changes, triggers an immediate full log check
-- @param instance table LocalSend instance
function M.checkSentinelFile(instance)
    local ServerState = getServerState()

    if not instance:isRunning() then
        -- Server died unexpectedly - clean up state so UI reflects reality
        instance:_cleanupServerState()
        deps.logger.dbg("[LocalSend] Server died, cleaned up state")
        return
    end

    -- Read sentinel file content (tiny file with just a timestamp)
    local content = deps.util.readFromFile(M.transfer_notify_file)
    if content then
        content = content:gsub("%s+", "")  -- Trim whitespace
        -- Trigger check if:
        -- 1. First time seeing sentinel (last_sentinel_value is nil) - handles first transfer
        -- 2. Sentinel content changed - handles subsequent transfers
        if ServerState.last_sentinel_value == nil or content ~= ServerState.last_sentinel_value then
            deps.logger.dbg("[LocalSend] Sentinel file changed, checking for new transfers")
            instance:_checkForNewTransfers()
        end
        ServerState.last_sentinel_value = content
    end

    -- Schedule next sentinel check
    if instance:isRunning() then
        deps.UIManager:scheduleIn(M.SENTINEL_POLL_INTERVAL, instance.check_sentinel_task)
    end
end

-- Show recent transfers in a dialog
-- @param instance table LocalSend instance
function M.showRecentTransfers(instance)
    local transfers = instance:getTransferLog()

    if #transfers == 0 then
        deps.UIManager:show(deps.InfoMessage:new{
            text = deps._("No recent transfers."),
            timeout = 3,
        })
        return
    end

    -- Build text showing recent transfers (last 10)
    local lines = {}
    local start_idx = math.max(1, #transfers - 9)
    for i = start_idx, #transfers do
        local t = transfers[i]
        local size_str = t.size and string.format(" (%s)", deps.util.getFriendlySize(t.size)) or ""
        table.insert(lines, string.format("%d. %s%s", i, t.filename, size_str))
    end

    deps.UIManager:show(deps.InfoMessage:new{
        text = deps.T(deps._("Recent transfers (%1 total):\n\n%2"), #transfers, table.concat(lines, "\n")),
    })
end

return M
