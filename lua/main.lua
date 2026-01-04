local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local json = require("json")
local PluginShare = require("pluginshare")

-- Polling interval constants for adaptive transfer detection
local POLLING_INTERVAL_IDLE = 15     -- 15 seconds when idle
local POLLING_INTERVAL_ACTIVE = 5    -- 5 seconds after recent transfer
local POLLING_ACTIVE_DURATION = 60   -- Stay in active mode for 60 seconds after transfer

local GITHUB_RELEASE_URL = "https://api.github.com/repos/kaikozlov/localsend.koplugin/releases/latest"

-- Utility functions (inlined for backwards compatibility with older self-update)
-- Also available in localsend_utils.lua for testing

-- Validate that a path is safe for shell operations
local function isValidPath(path)
    if path == nil or path == "" then return false end
    -- Reject paths with null bytes
    if path:find("%z") then return false end
    -- Must be absolute path
    if not path:match("^/") then return false end
    -- No command substitution patterns
    if path:find("`") or path:find("%$%(") then return false end
    return true
end

-- Validate that a port number is safe for shell operations
local function isValidPort(port)
    if port == nil then return false end
    local num = tonumber(port)
    if num == nil then return false end
    if num < 1 or num > 65535 then return false end
    -- Ensure it's an integer
    if num ~= math.floor(num) then return false end
    return true
end

-- Compare semantic versions
-- Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
local function compareVersions(v1, v2)
    local function parseVersion(v)
        local parts = {}
        for num in string.gmatch(v:gsub("^v", ""), "(%d+)") do
            table.insert(parts, tonumber(num) or 0)
        end
        return parts
    end

    local p1, p2 = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#p1, #p2) do
        local n1, n2 = p1[i] or 0, p2[i] or 0
        if n1 < n2 then return -1 end
        if n1 > n2 then return 1 end
    end
    return 0
end

-- Find download asset URL for given architecture
local function findAssetForArch(assets, arch)
    local pattern = "localsend%-koplugin%-" .. arch .. "%.zip$"
    for _, asset in ipairs(assets) do
        if asset.name and asset.name:match(pattern) then
            return asset.browser_download_url, asset.name
        end
    end
    return nil, nil
end

-- Normalize curly quotes to straight quotes
local function normalizeApostrophes(str)
    if str == nil then return nil end
    -- Replace curly single quotes (U+2018, U+2019) with straight quote
    return str:gsub("\xe2\x80\x98", "'"):gsub("\xe2\x80\x99", "'")
end

-- Validate device name for LocalSend
local function validateDeviceName(name)
    -- Empty or nil name is valid (will use random name)
    if name == nil or name == "" then
        return true
    end

    -- Check length (reasonable limit)
    if #name > 64 then
        return false, "Device name is too long (max 64 characters)."
    end

    -- Normalize curly quotes to straight for validation
    local normalized = normalizeApostrophes(name)

    -- Only allow alphanumeric, spaces, hyphens, underscores, and apostrophes
    if not normalized:match("^[%w%s%-_']+$") then
        return false, "Device name can only contain letters, numbers, spaces, hyphens, underscores, and apostrophes."
    end

    return true
end

-- Check if an iptables rule exists (returns true if rule exists)
local function iptablesRuleExists(rule)
    -- iptables -C checks if rule exists, returns 0 if it does
    local result = os.execute("iptables -C " .. rule .. " 2>/dev/null")
    return result == 0
end

-- Add iptables rule only if it doesn't already exist
local function iptablesAddIfMissing(rule)
    if not iptablesRuleExists(rule) then
        os.execute("iptables -A " .. rule)
        return true
    end
    return false
end

local data_dir = DataStorage:getFullDataDir()
local plugin_path = data_dir .. "/plugins/localsend.koplugin"

-- Module-local state that persists across widget instances (view switches)
-- This is preferred over _G globals for tracking state within a single KOReader session
local ServerState = {
    user_stopped = false,  -- True when user explicitly stopped the server
    was_running_before_suspend = false,  -- True if server was running before suspend/standby
    was_running_before_disconnect = false,  -- True if server was running before network disconnect
    last_log_position = 0,  -- Track transfer log read position across instances
    transfer_count = 0,  -- Cached transfer count (avoids full file read on e-readers)
    last_transfer_time = nil,  -- TimeVal of last transfer for adaptive polling
}

-- Load plugin metadata safely (wrap dofile in pcall)
local plugin_meta
local meta_path = plugin_path .. "/_meta.lua"
local ok, result = pcall(dofile, meta_path)
if ok and type(result) == "table" then
    plugin_meta = result
else
    logger.warn("[LocalSend] Failed to load _meta.lua:", result)
    plugin_meta = { version = "unknown", name = "LocalSend" }
end
local PLUGIN_VERSION = plugin_meta.version or "unknown"
local binary_path = plugin_path .. "/localsend"
local certs_path = plugin_path .. "/certs"  -- Certs folder next to binary (managed by Go)
local pid_file = "/tmp/localsend_koreader.pid"
local transfer_log_file = "/tmp/localsend_transfers.log"

-- Extension presets
local EXTENSION_PRESETS = {
    { name = _("All files"), value = "" },
    { name = _("eBooks (epub, pdf, mobi, azw3)"), value = "epub,pdf,mobi,azw3" },
    { name = _("eBooks + CBZ (comics)"), value = "epub,pdf,mobi,azw3,cbz,cbr" },
    { name = _("PDF only"), value = "pdf" },
    { name = _("EPUB only"), value = "epub" },
    { name = _("Custom..."), value = nil },
}

-- Check if binary exists
if not util.pathExists(binary_path) then
    return { disabled = true, }
end

local LocalSend = WidgetContainer:extend{
    name = "LocalSend",
    is_doc_only = false,
}

function LocalSend:init()
    local loaded_port = G_reader_settings:readSetting("LocalSend_port") or "53317"
    if not isValidPort(loaded_port) then
        logger.warn("[LocalSend] Invalid port in settings, using default 53317")
        loaded_port = "53317"
    end
    self.port = loaded_port
    self.save_dir = G_reader_settings:readSetting("LocalSend_save_dir") or "/mnt/us/documents"
    self.device_name = G_reader_settings:readSetting("LocalSend_device_name") or ""
    self.use_https = G_reader_settings:nilOrTrue("LocalSend_use_https")
    self.autostart = G_reader_settings:isTrue("LocalSend_autostart")
    self.pin = G_reader_settings:readSetting("LocalSend_pin") or ""
    self.accept_ext = G_reader_settings:readSetting("LocalSend_accept_ext") or ""
    self.use_webrtc = G_reader_settings:isTrue("LocalSend_use_webrtc") -- Experimental, off by default
    self.ext_dirs = G_reader_settings:readSetting("LocalSend_ext_dirs") or {} -- Extension routing: ext -> dir
    self.routing_accept_all = G_reader_settings:isTrue("LocalSend_routing_accept_all") -- Accept unrouted files to default dir
    self.routing_enabled = G_reader_settings:isTrue("LocalSend_routing_enabled") -- Whether routing is active
    self.last_transfer_count = 0

    -- Cache for menu rendering (avoids disk I/O on every menu open)
    -- Updated via _updateCache() on state changes
    self._cached_running = false
    self._cached_transfer_count = 0

    -- Create instance-specific task references for proper unscheduling
    -- (See UIManager docs: anonymous functions cannot be unscheduled)
    self.check_transfer_task = function()
        self:_checkForNewTransfers()
    end
    self.resume_start_task = function()
        self:start(true)  -- silent=true to suppress notification
    end

    -- Clean up orphaned resources from previous crashes
    self:_cleanupOrphanedResources()

    -- Only autostart if:
    -- 1. autostart setting is enabled
    -- 2. user hasn't explicitly stopped the server this session
    -- (ServerState resets on KOReader restart, so autostart works on fresh launch)
    if self.autostart and not ServerState.user_stopped then
        -- Use NetworkMgr:runWhenConnected for reliable startup after WiFi is ready
        NetworkMgr:runWhenConnected(function()
            -- Re-check user_stopped in case they toggled it while waiting for network
            if not ServerState.user_stopped then
                self:start()
            end
        end)
    end

    -- Sync cache with actual state (server may be running from previous widget instance)
    self:_updateCache()

    -- Register event handlers based on current state
    self:registerEvents()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- Clean up orphaned resources from previous crashes (stale PID file, firewall rules)
function LocalSend:_cleanupOrphanedResources()
    if util.pathExists(pid_file) then
        local content = util.readFromFile(pid_file)
        if content then
            local pid = tonumber(content:match("^(%d+)"))
            if pid and not util.pathExists("/proc/" .. pid) then
                -- Process is dead but PID file exists - clean up
                logger.warn("[LocalSend] Found stale PID file, cleaning up")
                os.remove(pid_file)
                -- Also clean up firewall rules (they may be orphaned)
                self:closeFirewall()
            end
        else
            -- Empty or unreadable PID file - remove it
            os.remove(pid_file)
        end
    end
end

-- Cleanup when KOReader exits (not when switching documents)
-- Note: onCloseWidget is called when switching books, so we don't stop the server there.
-- Instead, we stop on Exit event which is only triggered when KOReader actually closes.
function LocalSend:onExit()
    if self:isRunning() then
        self:stopServer()
        logger.dbg("[LocalSend] Server stopped on KOReader exit")
    end
end

-- Dynamic event registration (KOSync pattern)
-- Only register power/network handlers when server is running or expected to run
-- This reduces event processing overhead when the plugin is idle
function LocalSend:registerEvents()
    if self:isRunning() or (self.autostart and not ServerState.user_stopped) then
        -- Server running or expected to run: register handlers
        self.onSuspend = self._onSuspend
        self.onResume = self._onResume
        self.onEnterStandby = self._onEnterStandby
        self.onLeaveStandby = self._onLeaveStandby
        self.onNetworkDisconnected = self._onNetworkDisconnected
        self.onNetworkConnected = self._onNetworkConnected
        logger.dbg("[LocalSend] Event handlers registered")
    else
        -- Server not running: unregister handlers to reduce overhead
        self.onSuspend = nil
        self.onResume = nil
        self.onEnterStandby = nil
        self.onLeaveStandby = nil
        self.onNetworkDisconnected = nil
        self.onNetworkConnected = nil
        logger.dbg("[LocalSend] Event handlers unregistered")
    end
end

-- Event handler implementations (underscore-prefixed for dynamic registration)
-- Stop server before device suspends (WiFi will be disabled)
function LocalSend:_onSuspend()
    logger.dbg("[LocalSend] onSuspend")
    -- Unschedule polling before stopping
    self:_unschedulePolling()
    self:_unscheduleResume()

    if self:isRunning() then
        ServerState.was_running_before_suspend = true
        self:stopServer()
        logger.dbg("[LocalSend] Server stopped for suspend")
    else
        ServerState.was_running_before_suspend = false
    end
end

-- Restart server after device resumes (if it was running before)
function LocalSend:_onResume()
    logger.dbg("[LocalSend] onResume")
    if ServerState.was_running_before_suspend and not ServerState.user_stopped then
        -- Use NetworkMgr:runWhenConnected for reliable restart after WiFi reconnects
        NetworkMgr:runWhenConnected(function()
            if not ServerState.user_stopped then
                self:start(true)  -- silent=true to suppress notification
            end
        end)
    end
end

-- Same handling for standby (light sleep)
function LocalSend:_onEnterStandby()
    logger.dbg("[LocalSend] onEnterStandby")
    -- Unschedule polling before stopping
    self:_unschedulePolling()

    if self:isRunning() then
        ServerState.was_running_before_suspend = true
        self:stopServer()
        logger.dbg("[LocalSend] Server stopped for standby")
    else
        ServerState.was_running_before_suspend = false
    end
end

function LocalSend:_onLeaveStandby()
    logger.dbg("[LocalSend] onLeaveStandby")
    if ServerState.was_running_before_suspend and not ServerState.user_stopped then
        self:start(true)  -- silent=true to suppress notification
    end
end

-- Handle network disconnect (e.g., user manually turns off WiFi)
function LocalSend:_onNetworkDisconnected()
    logger.dbg("[LocalSend] onNetworkDisconnected")
    if self:isRunning() then
        ServerState.was_running_before_disconnect = true
        self:stopServer()
        logger.dbg("[LocalSend] Server stopped due to network disconnect")
    else
        ServerState.was_running_before_disconnect = false
    end
end

-- Handle network reconnect
function LocalSend:_onNetworkConnected()
    logger.dbg("[LocalSend] onNetworkConnected")
    if ServerState.was_running_before_disconnect and not ServerState.user_stopped then
        self:start(true)  -- silent=true to suppress notification
        logger.dbg("[LocalSend] Server restarted after network reconnect")
    end
end

-- Lifecycle: flush settings before shutdown
function LocalSend:onFlushSettings()
    -- Settings are saved immediately on change via G_reader_settings,
    -- so nothing to do here. This method exists for KOReader lifecycle compliance.
    logger.dbg("[LocalSend] onFlushSettings")
end

-- Unschedule helpers for proper task cleanup
-- These use stored task references so UIManager can actually unschedule them
function LocalSend:_unschedulePolling()
    if self.check_transfer_task then
        UIManager:unschedule(self.check_transfer_task)
    end
end

function LocalSend:_unscheduleResume()
    if self.resume_start_task then
        UIManager:unschedule(self.resume_start_task)
    end
end

-- Update cached state values (called on state changes to avoid disk I/O in menu)
function LocalSend:_updateCache()
    self._cached_running = self:isRunning()
    self._cached_transfer_count = self:getTransferCount()
end

-- Non-blocking server startup wait using UIManager scheduling
-- Replaces busy-wait loop to avoid blocking the UI thread
function LocalSend:_waitForServerReady(attempts_remaining, silent, on_ready, on_failure)
    if attempts_remaining <= 0 then
        on_failure()
        return
    end
    if self:isRunning() then
        on_ready()
        return
    end
    -- Non-blocking: schedule next check in 100ms
    UIManager:scheduleIn(0.1, function()
        self:_waitForServerReady(attempts_remaining - 1, silent, on_ready, on_failure)
    end)
end

-- Non-blocking process exit wait using UIManager scheduling
-- Replaces busy-wait loop to avoid blocking the UI thread
function LocalSend:_waitForProcessExit(pid, attempts_remaining, force, callback)
    local function isProcAlive(p)
        return p and util.pathExists("/proc/" .. p)
    end

    if not isProcAlive(pid) then
        callback(true)  -- Process exited successfully
        return
    end

    if attempts_remaining <= 0 then
        if force then
            -- Force kill with SIGKILL
            os.execute(util.shell_escape({"kill", "-KILL", tostring(pid)}))
            -- Give one more brief check after SIGKILL
            UIManager:scheduleIn(0.2, function()
                callback(not isProcAlive(pid))
            end)
        else
            callback(false)  -- Process did not exit
        end
        return
    end

    -- Schedule next check in 100ms
    UIManager:scheduleIn(0.1, function()
        self:_waitForProcessExit(pid, attempts_remaining - 1, force, callback)
    end)
end

-- Called when server has been confirmed running after startup
function LocalSend:_onServerStarted(silent, effective_name)
    -- Update cache now that server is running
    self:_updateCache()

    -- Expose running state to other plugins via PluginShare
    PluginShare.localsend_running = true

    -- Register event handlers now that server is running
    self:registerEvents()

    -- Start polling for new transfers using stored task reference
    self:_unschedulePolling()  -- Ensure no duplicate polling
    UIManager:scheduleIn(POLLING_INTERVAL_IDLE, self.check_transfer_task)

    if not silent then
        -- Build concise startup message
        local network_info = Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() or nil
        local pin_status = self.pin ~= "" and _("PIN: enabled") or nil

        local message_parts = {
            T(_("Device: %1"), effective_name),
        }

        -- Try to extract IP and show with port for manual connection
        local ip_addr = network_info and network_info:match("(%d+%.%d+%.%d+%.%d+)")
        if ip_addr then
            table.insert(message_parts, T(_("IP: %1"), ip_addr .. ":" .. self.port))
        elseif network_info and network_info ~= "" then
            -- Fallback: show raw network info if we can't extract IP
            table.insert(message_parts, network_info)
        end

        if pin_status then
            table.insert(message_parts, pin_status)
        end

        local info = InfoMessage:new{
            timeout = 5,
            text = _("LocalSend Ready") .. "\n" .. table.concat(message_parts, "\n"),
        }
        UIManager:show(info)
    else
        logger.dbg("[LocalSend] Server restarted after resume")
    end
end

-- Called when server startup has failed
function LocalSend:_onServerStartFailed(silent)
    self:closeFirewall()
    self:_updateCache()

    if not silent then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("LocalSend process failed to start within 5 seconds. Check if the binary works."),
        })
    else
        logger.warn("[LocalSend] Failed to restart server after resume")
    end
end

-- Cleanup scheduled tasks when widget is destroyed (document switch, view change)
-- Note: Server process continues running - only Lua-side tasks are cleaned up
function LocalSend:onCloseWidget()
    logger.dbg("[LocalSend] onCloseWidget")

    -- Unschedule polling task
    self:_unschedulePolling()
    self.check_transfer_task = nil

    -- Unschedule any pending resume task
    self:_unscheduleResume()
    self.resume_start_task = nil

    -- Note: Server process continues running - new widget instance
    -- will take over polling responsibility in init() if server is running
end

function LocalSend:openFirewall()
    if Device:isKindle() then
        if not isValidPort(self.port) then
            logger.err("[LocalSend] Invalid port, cannot configure firewall")
            return
        end
        -- TCP for file transfer (idempotent - won't add if already exists)
        iptablesAddIfMissing(string.format(
            "INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
            self.port))
        iptablesAddIfMissing(string.format(
            "OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT",
            self.port))
        -- UDP for device discovery
        iptablesAddIfMissing(string.format(
            "INPUT -p udp --dport %s -j ACCEPT",
            self.port))
        iptablesAddIfMissing(string.format(
            "OUTPUT -p udp --sport %s -j ACCEPT",
            self.port))
        -- WebRTC/ICE UDP ports - must match range in peer.go SetEphemeralUDPPortRange
        if self.use_webrtc then
            iptablesAddIfMissing("INPUT -p udp --dport 50000:50100 -j ACCEPT")
            iptablesAddIfMissing("OUTPUT -p udp --sport 50000:50100 -j ACCEPT")
            logger.dbg("[LocalSend] Firewall opened for WebRTC UDP ports (50000-50100)")
        end
        logger.dbg("[LocalSend] Firewall opened for port " .. self.port)
    end
end

function LocalSend:closeFirewall()
    if Device:isKindle() then
        if not isValidPort(self.port) then
            logger.err("[LocalSend] Invalid port, cannot configure firewall")
            return
        end
        os.execute(string.format(
            "iptables -D INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
            self.port))
        os.execute(string.format(
            "iptables -D OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT",
            self.port))
        os.execute(string.format(
            "iptables -D INPUT -p udp --dport %s -j ACCEPT",
            self.port))
        os.execute(string.format(
            "iptables -D OUTPUT -p udp --sport %s -j ACCEPT",
            self.port))
        -- Clean up WebRTC UDP rules (ignore errors if they don't exist)
        os.execute("iptables -D INPUT -p udp --dport 50000:50100 -j ACCEPT 2>/dev/null")
        os.execute("iptables -D OUTPUT -p udp --sport 50000:50100 -j ACCEPT 2>/dev/null")
        logger.dbg("[LocalSend] Firewall closed for port " .. self.port)
    end
end

function LocalSend:validateDeviceName(name)
    local valid, err = validateDeviceName(name)
    if not valid and err then
        return false, _(err)
    end
    return valid
end

function LocalSend:validateSaveDir(path)
    -- Validate path is safe for shell operations
    if not isValidPath(path) then
        return false, _("Invalid path: must be an absolute path without special characters.")
    end

    -- Check if path exists
    if not util.pathExists(path) then
        -- Try to create it
        local ok, err = util.makePath(path)
        if not ok then
            logger.warn("[LocalSend] Failed to create directory:", err)
            return false, _("Directory does not exist and could not be created.")
        end
    end

    -- Check if writable by trying to create a temp file
    local test_file = path .. "/.localsend_write_test"
    local f = io.open(test_file, "w")
    if not f then
        return false, _("Directory is not writable.")
    end
    f:close()
    os.remove(test_file)

    return true
end

function LocalSend:getTransferLog()
    local transfers = {}
    if not util.pathExists(transfer_log_file) then
        return transfers
    end

    local f = io.open(transfer_log_file, "r")
    if not f then return transfers end

    for line in f:lines() do
        local ok, entry = pcall(json.decode, line)
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
function LocalSend:getNewTransfers()
    local transfers = {}
    if not util.pathExists(transfer_log_file) then
        ServerState.last_log_position = 0
        return transfers
    end

    local f = io.open(transfer_log_file, "r")
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
        local ok, entry = pcall(json.decode, line)
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
function LocalSend:getTransferCount()
    return ServerState.transfer_count
end

function LocalSend:clearTransferLog()
    os.remove(transfer_log_file)
    ServerState.last_log_position = 0  -- Reset position tracking when log is cleared
    ServerState.transfer_count = 0  -- Reset cached count
end

-- Internal polling method called by the stored task reference
-- No generation counter needed - proper unscheduling handles stale callbacks
function LocalSend:_checkForNewTransfers()
    if not self:isRunning() then
        return
    end

    -- Use optimized getNewTransfers() instead of reading the whole file
    local new_transfers = self:getNewTransfers()
    if #new_transfers > 0 then
        -- Record transfer time for adaptive polling
        ServerState.last_transfer_time = UIManager:getElapsedTimeSinceBoot()

        -- Update cache to reflect new transfer count
        self:_updateCache()

        local latest = new_transfers[#new_transfers]
        local text
        if #new_transfers == 1 then
            text = T(_("File received: %1"), latest.filename)
        else
            text = T(_("%1 files received. Latest: %2"), #new_transfers, latest.filename)
        end

        UIManager:show(InfoMessage:new{
            text = text,
            timeout = 5,
        })
    end

    -- Schedule next check only if still running
    -- Use adaptive polling: shorter interval after recent transfers
    if self:isRunning() then
        local next_interval = POLLING_INTERVAL_IDLE
        if ServerState.last_transfer_time then
            local time_since_boot = UIManager:getElapsedTimeSinceBoot()
            -- TimeVal subtraction returns elapsed seconds as a number in real KOReader
            -- But test mocks may return plain tables with .sec/.usec fields
            local elapsed_seconds
            if type(time_since_boot) == "table" and time_since_boot.sec ~= nil then
                -- Test mock: calculate elapsed time manually from sec/usec fields
                local last = ServerState.last_transfer_time
                elapsed_seconds = (time_since_boot.sec - last.sec) + (time_since_boot.usec - last.usec) / 1000000
            else
                -- Real KOReader: TimeVal subtraction returns seconds as a number directly
                elapsed_seconds = time_since_boot - ServerState.last_transfer_time
            end
            if elapsed_seconds < POLLING_ACTIVE_DURATION then
                next_interval = POLLING_INTERVAL_ACTIVE
            end
        end
        UIManager:scheduleIn(next_interval, self.check_transfer_task)
    end
end

-- Legacy wrapper for backwards compatibility (still used by some code paths)
-- @param my_generation number|nil Generation counter (deprecated, ignored)
function LocalSend:checkForNewTransfers(my_generation)
    -- Generation counter is now deprecated - proper task unscheduling handles stale callbacks
    -- Just delegate to the internal method
    self:_checkForNewTransfers()
end

-- Start the LocalSend server
-- @param silent boolean If true, suppress the startup notification (used for resume from sleep)
function LocalSend:start(silent)
    -- If server is already running, just take over polling responsibility
    if self:isRunning() then
        logger.dbg("[LocalSend] Server already running, taking over polling")
        -- Sync cache with actual state
        self:_updateCache()
        -- Expose running state to other plugins
        PluginShare.localsend_running = true
        -- Unschedule any existing polling task before starting new one
        self:_unschedulePolling()
        UIManager:scheduleIn(POLLING_INTERVAL_IDLE, self.check_transfer_task)
        -- Ensure event handlers are registered
        self:registerEvents()
        return
    end

    -- Validate save directory
    local valid, err = self:validateSaveDir(self.save_dir)
    if not valid then
        if not silent then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Invalid save directory: %1"), err),
            })
        end
        return
    end

    -- Clear old transfer log and reset count (only on fresh start, not resume)
    if not silent then
        self:clearTransferLog()
    end

    -- Build command arguments table
    local args = {binary_path, "recv", "-d", self.save_dir, "-l", transfer_log_file}

    -- Always pass device name (default to "KOReader" if not set)
    local effective_name = self.device_name ~= "" and self.device_name or "KOReader"
    table.insert(args, "-n")
    table.insert(args, effective_name)

    if self.pin ~= "" then
        table.insert(args, "-p")
        table.insert(args, self.pin)
    end

    -- Determine accept_ext based on routing or manual setting
    local effective_accept_ext = self.accept_ext
    if self.routing_enabled and next(self.ext_dirs) then
        -- Routing is active: accept only routed extensions (unless accept_all is enabled)
        if not self.routing_accept_all then
            local exts = {}
            for ext, _ in pairs(self.ext_dirs) do
                table.insert(exts, ext)
            end
            effective_accept_ext = table.concat(exts, ",")
        else
            effective_accept_ext = "" -- Accept all
        end
    end

    if effective_accept_ext ~= "" then
        table.insert(args, "-a")
        table.insert(args, effective_accept_ext)
    end

    if not self.use_https then
        table.insert(args, "--https=false")
    end

    if not self.use_webrtc then
        table.insert(args, "-w=false")
    end

    -- Export and apply extension routing config if configured
    local routing_path = self:exportExtRouting()
    if routing_path then
        table.insert(args, "--ext-routing")
        table.insert(args, routing_path)
    end

    -- Open firewall before starting
    self:openFirewall()

    -- Build final command: run in background and save PID
    local cmd = string.format("(%s) & echo $! > %s", util.shell_escape(args), util.shell_escape({pid_file}))

    logger.dbg("[LocalSend] Starting server: ", cmd)

    local result = os.execute(cmd)

    if result == 0 then
        -- Non-blocking wait for server readiness (max 5 seconds = 50 * 100ms)
        self:_waitForServerReady(50, silent,
            -- on_ready callback
            function()
                self:_onServerStarted(silent, effective_name)
            end,
            -- on_failure callback
            function()
                self:_onServerStartFailed(silent)
            end
        )
    else
        self:closeFirewall()
        self:_updateCache()
        if not silent then
            local info = InfoMessage:new{
                icon = "notice-warning",
                text = _("Failed to start LocalSend server."),
            }
            UIManager:show(info)
        else
            logger.warn("[LocalSend] Failed to start server after resume")
        end
    end
end

function LocalSend:isRunning()
    if not util.pathExists(pid_file) then
        return false
    end

    local content = util.readFromFile(pid_file)
    if not content then return false end
    local pid = tonumber(content:match("^(%d+)"))
    if not pid then return false end
    return util.pathExists("/proc/" .. pid)
end

function LocalSend:stopServer()
    -- Unschedule Lua tasks first
    self:_unschedulePolling()

    -- Read PID before removing file
    local pid = nil
    if util.pathExists(pid_file) then
        local content = util.readFromFile(pid_file)
        if content then
            pid = tonumber(content:match("^(%d+)"))
        end
        -- Remove PID file FIRST to prevent state confusion
        -- This ensures isRunning() returns false immediately
        os.remove(pid_file)
    else
        -- No PID file means server wasn't running
        self:_cleanupServerState()
        return true
    end

    -- Kill the process if PID is valid and process exists
    if pid and util.pathExists("/proc/" .. pid) then
        -- Use SIGKILL (signal 9) for guaranteed, immediate termination
        -- SIGKILL cannot be caught, blocked, or ignored - kernel handles it directly
        -- Using os.execute instead of ffiutil.terminateSubProcess for reliability
        os.execute("kill -9 " .. tostring(pid) .. " 2>/dev/null")
    end

    -- Clean up firewall and state
    self:closeFirewall()
    self:_cleanupServerState()

    return true
end

-- Clean up server state after stopping (PluginShare, cache, events)
function LocalSend:_cleanupServerState()
    -- Clear PluginShare state
    PluginShare.localsend_running = nil

    -- Update cache
    self:_updateCache()

    -- Update event registration (may unregister handlers if server stopped)
    self:registerEvents()
end

function LocalSend:stop()
    -- Mark that user explicitly stopped the server this session
    -- This prevents autostart from restarting it when opening a new document
    ServerState.user_stopped = true
    self:stopServer()
    UIManager:show(InfoMessage:new{
        text = _("LocalSend server stopped."),
        timeout = 2,
    })
end

function LocalSend:restart()
    if self:isRunning() then
        self:stopServer()
    end
    self:start()
end

function LocalSend:onToggleLocalSend()
    if self:isRunning() then
        self:stop()
    else
        -- User is explicitly starting the server, clear the stopped flag
        -- so autostart can work again if they open another document
        ServerState.user_stopped = false
        self:start()
    end
end

function LocalSend:getPickerStartPath(path)
    -- Only apply workaround if home folder lock is enabled
    if not G_reader_settings:isTrue("lock_home_folder") then
        return path
    end

    -- Check if save_dir is at or inside the locked home folder
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then
        -- Normalize paths (remove trailing slashes for comparison)
        local norm_path = path:gsub("/$", "")
        local norm_home = home_dir:gsub("/$", "")
        -- Escape Lua pattern special characters for matching
        local escaped_home = norm_home:gsub("([%.%-%+%[%]%(%)%$%^%%%?%*])", "%%%1")
        -- If save_dir doesn't start with home_dir, no workaround needed
        if norm_path ~= norm_home and not norm_path:match("^" .. escaped_home .. "/") then
            return path
        end
    end

    -- If already at root, stay there
    if path == "/" then
        return path
    end

    -- Remove trailing slash if present (except for root)
    path = path:gsub("/$", "")

    -- Get parent directory
    local parent = path:match("^(.+)/[^/]+$")
    if not parent or parent == "" then
        -- Path is like "/foo" so parent would be root
        parent = "/"
    end

    -- Check if parent directory exists and is accessible
    if util.pathExists(parent) then
        return parent
    end

    -- Parent doesn't exist or isn't accessible, fall back to original path
    return path
end

function LocalSend:showSaveDirPicker(touchmenu_instance)
    local start_path = self:getPickerStartPath(self.save_dir)
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = start_path,
        onConfirm = function(path)
            local valid, err = self:validateSaveDir(path)
            if valid then
                self.save_dir = path
                G_reader_settings:saveSetting("LocalSend_save_dir", self.save_dir)
                touchmenu_instance:updateItems()
            else
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Cannot use this directory: %1"), err),
                })
            end
        end,
    }
    UIManager:show(path_chooser)
end

function LocalSend:showDeviceNameDialog(touchmenu_instance)
    local dialog  -- Local variable instead of self.dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        description = _("Leave empty for default ('KOReader')"),
        input = self.device_name,
        input_hint = "My Kindle",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_name = dialog:getInputText()
                        local valid, err = self:validateDeviceName(new_name)
                        if not valid then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = err,
                            })
                            return
                        end
                        self.device_name = new_name
                        G_reader_settings:saveSetting("LocalSend_device_name", self.device_name)
                        UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LocalSend:showPinDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("PIN code"),
        description = _("Leave empty to disable PIN protection"),
        input = self.pin,
        input_hint = "1234",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.pin = dialog:getInputText()
                        G_reader_settings:saveSetting("LocalSend_pin", self.pin)
                        UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LocalSend:showCustomExtDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Custom extensions"),
        description = _("Comma-separated list (e.g., 'epub,pdf,mobi')"),
        input = self.accept_ext,
        input_hint = "epub,pdf,mobi",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.accept_ext = dialog:getInputText()
                        G_reader_settings:saveSetting("LocalSend_accept_ext", self.accept_ext)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LocalSend:buildExtensionPresetsMenu()
    local menu = {}
    for _, preset in ipairs(EXTENSION_PRESETS) do
        if preset.value == nil then
            -- Custom option
            table.insert(menu, {
                text = preset.name,
                keep_menu_open = true,
                callback = function()
                    self:showCustomExtDialog()
                end,
            })
        else
            table.insert(menu, {
                text = preset.name,
                checked_func = function()
                    return self.accept_ext == preset.value
                end,
                callback = function()
                    self.accept_ext = preset.value
                    G_reader_settings:saveSetting("LocalSend_accept_ext", self.accept_ext)
                end,
            })
        end
    end
    return menu
end

-- Extension routing functions
function LocalSend:exportExtRouting()
    -- Export extension routing config to JSON file for CLI
    if not self.routing_enabled or not next(self.ext_dirs) then
        return nil -- Routing disabled or no routes configured
    end

    local config = {}
    for ext, dir in pairs(self.ext_dirs) do
        config[ext] = dir
    end

    -- Only include default if "accept all" is enabled
    if self.routing_accept_all then
        config["default"] = self.save_dir
    end

    local path = plugin_path .. "/ext_routing.json"
    local f = io.open(path, "w")
    if f then
        local ok, err = pcall(function()
            f:write(json.encode(config))
        end)
        f:close()
        if not ok then
            logger.warn("[LocalSend] Failed to write extension routing config:", err)
            return nil
        end
        logger.dbg("[LocalSend] Exported extension routing config to", path)
        return path
    end
    return nil
end

function LocalSend:addExtensionRoute(ext, dir)
    ext = string.lower(ext)
    -- Auto-enable routing when adding first route
    if not next(self.ext_dirs) and not self.routing_enabled then
        self.routing_enabled = true
        G_reader_settings:saveSetting("LocalSend_routing_enabled", true)
    end
    self.ext_dirs[ext] = dir
    G_reader_settings:saveSetting("LocalSend_ext_dirs", self.ext_dirs)
end

function LocalSend:removeExtensionRoute(ext)
    ext = string.lower(ext)
    self.ext_dirs[ext] = nil
    G_reader_settings:saveSetting("LocalSend_ext_dirs", self.ext_dirs)
end

function LocalSend:showAddExtensionRouteDialog(touchmenu_instance)
    -- Common extension presets for e-readers
    local ButtonDialog = require("ui/widget/buttondialog")
    local ext_presets = {
        { "epub", "PDF", "mobi" },
        { "azw3", "cbz", "cbr" },
    }

    local dialog
    local buttons = {}
    for _, row in ipairs(ext_presets) do
        local button_row = {}
        for _, ext in ipairs(row) do
            table.insert(button_row, {
                text = ext,
                callback = function()
                    UIManager:close(dialog)
                    self:showExtensionDirPicker(ext, touchmenu_instance)
                end,
            })
        end
        table.insert(buttons, button_row)
    end

    -- Add custom option
    table.insert(buttons, {
        {
            text = _("Custom..."),
            callback = function()
                UIManager:close(dialog)
                self:showCustomExtensionDialog(touchmenu_instance)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Select extension to route"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LocalSend:showCustomExtensionDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Extension to route"),
        description = _("Enter file extension (without dot)"),
        input = "",
        input_hint = "epub",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local ext = dialog:getInputText()
                        if ext and ext ~= "" then
                            ext = string.lower(ext:gsub("^%.", "")) -- Remove leading dot if present
                            UIManager:close(dialog)
                            self:showExtensionDirPicker(ext, touchmenu_instance)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LocalSend:showExtensionDirPicker(ext, touchmenu_instance)
    local start_path = self:getPickerStartPath(self.ext_dirs[ext] or self.save_dir)
    local path_chooser = PathChooser:new{
        title = T(_("Select directory for .%1 files"), ext),
        select_directory = true,
        select_file = false,
        path = start_path,
        onConfirm = function(path)
            local valid, err = self:validateSaveDir(path)
            if valid then
                self:addExtensionRoute(ext, path)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                UIManager:show(InfoMessage:new{
                    text = T(_(".%1 files will be saved to:\n%2"), ext, path),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Cannot use this directory: %1"), err),
                })
            end
        end,
    }
    UIManager:show(path_chooser)
end

function LocalSend:buildExtensionRoutingMenu()
    local menu = {}

    -- Enable/disable toggle (shown first when routes exist)
    local has_routes = next(self.ext_dirs) ~= nil
    if has_routes then
        table.insert(menu, {
            text = _("Enable file type routing"),
            checked_func = function()
                return self.routing_enabled
            end,
            callback = function()
                self.routing_enabled = not self.routing_enabled
                G_reader_settings:flipNilOrFalse("LocalSend_routing_enabled")
            end,
            help_text = _("When enabled, files are routed to directories based on extension. " ..
                "When disabled, all files go to the main save directory."),
        })
        table.insert(menu, { text = "---" })
    end

    -- Show existing routes
    for ext, dir in pairs(self.ext_dirs) do
        local captured_ext = ext -- Capture for closure
        table.insert(menu, {
            text = T(_(".%1 → %2"), ext, dir),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                -- Show options: change directory or remove
                local ButtonDialog = require("ui/widget/buttondialog")
                local dialog
                dialog = ButtonDialog:new{
                    title = T(_("Route for .%1"), captured_ext),
                    buttons = {
                        {
                            {
                                text = _("Change directory"),
                                callback = function()
                                    UIManager:close(dialog)
                                    self:showExtensionDirPicker(captured_ext, touchmenu_instance)
                                end,
                            },
                        },
                        {
                            {
                                text = _("Remove route"),
                                callback = function()
                                    UIManager:close(dialog)
                                    self:removeExtensionRoute(captured_ext)
                                    if touchmenu_instance then
                                        touchmenu_instance:updateItems()
                                    end
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Route for .%1 removed"), captured_ext),
                                        timeout = 2,
                                    })
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end

    if has_routes then
        table.insert(menu, { text = "---" })
    end

    -- Add new route option
    table.insert(menu, {
        text = _("Add extension route..."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showAddExtensionRouteDialog(touchmenu_instance)
        end,
    })

    -- Only show "accept all" option when routes exist
    if has_routes then
        table.insert(menu, {
            text = _("Accept other files → main directory"),
            checked_func = function()
                return self.routing_accept_all
            end,
            callback = function()
                self.routing_accept_all = not self.routing_accept_all
                G_reader_settings:flipNilOrFalse("LocalSend_routing_accept_all")
            end,
            help_text = _("When enabled, files without a specific route are saved to the main " ..
                "save directory. When disabled, only routed file types are accepted."),
        })
    end

    return menu
end

function LocalSend:showRecentTransfers()
    local transfers = self:getTransferLog()

    if #transfers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No recent transfers."),
            timeout = 3,
        })
        return
    end

    -- Build text showing recent transfers (last 10)
    local lines = {}
    local start_idx = math.max(1, #transfers - 9)
    for i = start_idx, #transfers do
        local t = transfers[i]
        local size_str = t.size and string.format(" (%s)", util.getFriendlySize(t.size)) or ""
        table.insert(lines, string.format("%d. %s%s", i, t.filename, size_str))
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Recent transfers (%1 total):\n\n%2"), #transfers, table.concat(lines, "\n")),
    })
end

function LocalSend:rotateCertificates()
    -- Remove certificates from the certs folder next to the binary
    -- Go will generate new ones on next start
    os.execute(util.shell_escape({"rm", "-f", certs_path .. "/server.key.pem"}))
    os.execute(util.shell_escape({"rm", "-f", certs_path .. "/server.crt"}))

    UIManager:show(InfoMessage:new{
        text = _("Certificates cleared. New certificates will be generated on next start."),
        timeout = 3,
    })
end

function LocalSend:getDeviceArch()
    -- Detect device architecture for selecting the right binary
    local handle = io.popen("uname -m")
    if not handle then return nil end
    local arch = handle:read("*l")
    handle:close()

    if not arch then return nil end

    -- Map uname output to our asset naming
    -- arm64/aarch64: 64-bit ARM (newer devices)
    -- armv7: 32-bit ARM with hardware float (most Kindles PW1+, returns "armv7l")
    -- armv5: legacy 32-bit ARM with soft float (K3, K4, older devices)
    if arch:match("^aarch64") or arch:match("^arm64") then
        return "arm64"
    elseif arch:match("^armv7") then
        return "armv7"
    elseif arch:match("^armv[56]") or arch:match("^arm") then
        -- armv5, armv6, or generic "arm" -> use legacy armv5 binary
        return "arm-legacy"
    end

    return nil
end

function LocalSend:performUpdate(download_url, asset_name, new_version)
    -- Stop server if running
    if self:isRunning() then
        self:stopServer()
    end

    UIManager:show(InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 2,
    })

    -- Give UI time to show the message
    UIManager:scheduleIn(0.5, function()
        self:doPerformUpdate(download_url, asset_name, new_version)
    end)
end

function LocalSend:doPerformUpdate(download_url, asset_name, new_version)
    local tmp_zip = "/tmp/localsend_update.zip"
    local tmp_extract = "/tmp/localsend_update_extract"

    -- Clean up any previous update attempt
    os.remove(tmp_zip)
    os.execute(util.shell_escape({"rm", "-rf", tmp_extract}))

    -- Download the zip
    local cmd = util.shell_escape({"curl", "-L", "-s", "-o", tmp_zip, "-w", "%{http_code}",
        "--connect-timeout", "30", "--max-time", "120", download_url})

    local handle = io.popen(cmd)
    local http_code = handle:read("*a")
    handle:close()

    if http_code ~= "200" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Download failed.\nHTTP status: %1"), http_code),
        })
        os.remove(tmp_zip)
        return
    end

    -- Verify zip was downloaded
    if not util.pathExists(tmp_zip) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Download failed: file not saved."),
        })
        return
    end

    -- Create extraction directory
    util.makePath(tmp_extract)

    -- Extract the zip
    local result = os.execute(util.shell_escape({"unzip", "-o", tmp_zip, "-d", tmp_extract}))

    if result ~= 0 then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to extract update."),
        })
        os.remove(tmp_zip)
        os.execute(util.shell_escape({"rm", "-rf", tmp_extract}))
        return
    end

    -- The zip contains localsend.koplugin/ folder
    local extracted_plugin = tmp_extract .. "/localsend.koplugin"

    if not util.pathExists(extracted_plugin) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Invalid update package structure."),
        })
        os.remove(tmp_zip)
        os.execute(util.shell_escape({"rm", "-rf", tmp_extract}))
        return
    end

    -- Copy files to plugin directory
    -- Core files that must exist:
    local files_to_copy = { "main.lua", "_meta.lua", "localsend" }
    local copy_failed = false

    for _, file in ipairs(files_to_copy) do
        local src = extracted_plugin .. "/" .. file
        local dst = plugin_path .. "/" .. file

        if util.pathExists(src) then
            local cp_result = os.execute(util.shell_escape({"cp", src, dst}))
            if cp_result ~= 0 then
                copy_failed = true
                logger.err("[LocalSend] Failed to copy:", file)
            end
        else
            logger.warn("[LocalSend] File not in update package:", file)
        end
    end

    -- Also copy any additional .lua files (for future-proofing)
    -- This ensures new Lua modules are picked up without hardcoding names
    -- Note: glob pattern must remain unquoted for shell expansion
    -- Wrap in pcall to ensure handle is always closed on error
    local ls_handle = io.popen(util.shell_escape({"ls"}) .. " " .. util.shell_escape({extracted_plugin}) .. "/*.lua 2>/dev/null")
    if ls_handle then
        local process_ok, process_err = pcall(function()
            for lua_file in ls_handle:lines() do
                local _, filename = util.splitFilePathName(lua_file)
                -- Skip files we already copied
                if filename and filename ~= "main.lua" and filename ~= "_meta.lua" then
                    local dst = plugin_path .. "/" .. filename
                    local cp_result = os.execute(util.shell_escape({"cp", lua_file, dst}))
                    if cp_result ~= 0 then
                        logger.warn("[LocalSend] Failed to copy additional lua file:", filename)
                    else
                        logger.dbg("[LocalSend] Copied additional lua file:", filename)
                    end
                end
            end
        end)
        ls_handle:close()  -- Always close, even on error
        if not process_ok then
            logger.err("[LocalSend] Error processing lua files:", process_err)
        end
    end

    -- Make binary executable
    os.execute(util.shell_escape({"chmod", "+x", plugin_path .. "/localsend"}))

    -- Cleanup
    os.remove(tmp_zip)
    os.execute(util.shell_escape({"rm", "-rf", tmp_extract}))

    if copy_failed then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Update partially failed. Some files could not be copied. Please update manually."),
        })
        return
    end

    -- Success!
    UIManager:show(InfoMessage:new{
        text = T(_("Update to %1 installed successfully!\n\nPlease restart KOReader for changes to take effect."), new_version),
    })
end

function LocalSend:checkForUpdates()
    -- Use NetworkMgr:runWhenOnline to handle network prompting automatically
    -- This provides better UX by prompting user to connect if offline
    NetworkMgr:runWhenOnline(function()
        self:doCheckForUpdates()
    end)
end

function LocalSend:doCheckForUpdates()
    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 2,
    })

    -- Use curl to fetch the latest release info
    local tmp_file = "/tmp/localsend_update_check.json"
    local cmd = string.format(
        "curl -s -o '%s' -w '%%{http_code}' --connect-timeout 10 -H 'Accept: application/vnd.github.v3+json' '%s'",
        tmp_file, GITHUB_RELEASE_URL)

    local handle = io.popen(cmd)
    local http_code = handle:read("*a")
    handle:close()

    if http_code ~= "200" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Failed to check for updates.\nHTTP status: %1\n\nPlease check your internet connection."), http_code),
        })
        os.remove(tmp_file)
        return
    end

    local content = util.readFromFile(tmp_file)
    os.remove(tmp_file)

    if not content then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to read update information."),
        })
        return
    end

    local ok, release = pcall(json.decode, content)
    if not ok or not release or not release.tag_name then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to parse update information."),
        })
        return
    end

    local latest_version = release.tag_name:gsub("^v", "")
    local current_version = PLUGIN_VERSION:gsub("^v", "")

    if compareVersions(current_version, latest_version) >= 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("You're up to date!\n\nCurrent version: %1\nLatest version: %2"), PLUGIN_VERSION, release.tag_name),
            timeout = 5,
        })
    else
        -- Update available - check if we can auto-update
        local arch = self:getDeviceArch()
        local download_url, asset_name

        if arch and release.assets then
            download_url, asset_name = findAssetForArch(release.assets, arch)
        end

        local release_notes = release.body or _("No release notes available.")
        -- Truncate if too long
        if #release_notes > 300 then
            release_notes = release_notes:sub(1, 300) .. "..."
        end

        if download_url then
            -- Can auto-update
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("Update available!\n\nCurrent: %1\nLatest: %2\n\n%3\n\nInstall update now?"),
                    PLUGIN_VERSION, release.tag_name, release_notes),
                ok_text = _("Install"),
                cancel_text = _("Later"),
                ok_callback = function()
                    self:performUpdate(download_url, asset_name, release.tag_name)
                end,
            })
        else
            -- Can't auto-update (unknown arch or no matching asset)
            local reason
            if not arch then
                reason = _("\n\nAuto-update not available: unknown device architecture.")
            else
                reason = T(_("\n\nAuto-update not available: no package for %1 architecture."), arch)
            end

            UIManager:show(InfoMessage:new{
                text = T(_("Update available!\n\nCurrent: %1\nLatest: %2\n\n%3%4\n\nVisit GitHub to download manually."),
                    PLUGIN_VERSION, release.tag_name, release_notes, reason),
            })
        end
    end
end

function LocalSend:addToMainMenu(menu_items)
    menu_items.localsend = {
        text_func = function()
            if self._cached_running then
                if self._cached_transfer_count > 0 then
                    return T(_("LocalSend (%1 received)"), self._cached_transfer_count)
                end
                return _("LocalSend (running)")
            end
            return _("LocalSend")
        end,
        sorting_hint = "network",
        -- Add check indicator for running state
        checked_func = function() return self._cached_running end,
        -- Quick toggle via long-press (SSH plugin pattern)
        hold_callback = function(touchmenu_instance)
            self:onToggleLocalSend()
            UIManager:scheduleIn(1, function()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end)
        end,
        sub_item_table = {
            {
                text_func = function()
                    if self._cached_running then
                        return _("Stop server")
                    else
                        return _("Start server")
                    end
                end,
                keep_menu_open = true,
                checked_func = function() return self._cached_running end,
                check_callback_updates_menu = true,  -- Hint for menu system to update on check change
                callback = function(touchmenu_instance)
                    self:onToggleLocalSend()
                    UIManager:scheduleIn(1, function()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            {
                text_func = function()
                    if self._cached_transfer_count > 0 then
                        return T(_("Recent transfers (%1)"), self._cached_transfer_count)
                    end
                    return _("Recent transfers")
                end,
                enabled_func = function() return self._cached_transfer_count > 0 end,
                callback = function()
                    self:showRecentTransfers()
                end,
            },
            {
                text_func = function()
                    return T(_("Save directory (%1)"), self.save_dir)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self._cached_running end,
                callback = function(touchmenu_instance)
                    self:showSaveDirPicker(touchmenu_instance)
                end,
            },
            {
                text = _("Settings"),
                enabled_func = function() return not self._cached_running end,
                sub_item_table = {
                    {
                        text_func = function()
                            if self.device_name ~= "" then
                                return T(_("Device name (%1)"), self.device_name)
                            else
                                return _("Device name (KOReader)")
                            end
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:showDeviceNameDialog(touchmenu_instance)
                        end,
                    },
                    {
                        text_func = function()
                            if self.routing_enabled and next(self.ext_dirs) then
                                return _("Allowed extensions (using routing)")
                            elseif self.accept_ext ~= "" then
                                return T(_("Allowed extensions (%1)"), self.accept_ext)
                            else
                                return _("Allowed extensions (all)")
                            end
                        end,
                        enabled_func = function()
                            return not (self.routing_enabled and next(self.ext_dirs)) -- Disabled when routing is enabled
                        end,
                        sub_item_table_func = function()
                            return self:buildExtensionPresetsMenu()
                        end,
                        help_text = _("When file type routing is enabled, allowed extensions are determined by the routing rules."),
                    },
                    {
                        text_func = function()
                            local count = 0
                            for _ in pairs(self.ext_dirs) do count = count + 1 end
                            if count > 0 then
                                if self.routing_enabled then
                                    return T(_("File type routing (%1 rules)"), count)
                                else
                                    return T(_("File type routing (disabled, %1 rules)"), count)
                                end
                            else
                                return _("File type routing")
                            end
                        end,
                        sub_item_table_func = function()
                            return self:buildExtensionRoutingMenu()
                        end,
                        help_text = _("Route different file types to different directories (e.g., EPUBs to Books folder, PDFs to Documents)."),
                    },
                    {
                        text_func = function()
                            if self.pin ~= "" then
                                return _("PIN code (enabled)")
                            else
                                return _("PIN code (disabled)")
                            end
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:showPinDialog(touchmenu_instance)
                        end,
                    },
                    {
                        text = "---",
                    },
                    {
                        text = _("Use HTTPS"),
                        checked_func = function() return self.use_https end,
                        callback = function()
                            self.use_https = not self.use_https
                            G_reader_settings:flipNilOrTrue("LocalSend_use_https")
                        end,
                    },
                    {
                        text = _("Start with KOReader"),
                        checked_func = function() return self.autostart end,
                        callback = function()
                            self.autostart = not self.autostart
                            G_reader_settings:flipNilOrFalse("LocalSend_autostart")
                        end,
                    },
                    {
                        text = _("Enable WebRTC Support (Experimental)"),
                        checked_func = function() return self.use_webrtc end,
                        callback = function()
                            self.use_webrtc = not self.use_webrtc
                            G_reader_settings:flipNilOrFalse("LocalSend_use_webrtc")
                        end,
                        help_text = _("Connect to public signaling server for WebRTC transfers. Requires internet access."),
                    },
                    {
                        text = _("Rotate certificates"),
                        keep_menu_open = true,
                        callback = function()
                            self:rotateCertificates()
                        end,
                    },
                },
            },
            {
                text = "---",
            },
            {
                text_func = function()
                    return T(_("Check for updates (%1)"), PLUGIN_VERSION)
                end,
                keep_menu_open = true,
                callback = function()
                    self:checkForUpdates()
                end,
            },
        }
    }
end

function LocalSend:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_localsend_server",
        { category = "none", event = "ToggleLocalSend", title = _("Toggle LocalSend server"), general = true })
end

-- Expose ServerState for testing purposes
-- Production code should NOT access this directly
LocalSend._ServerState = ServerState

return LocalSend
