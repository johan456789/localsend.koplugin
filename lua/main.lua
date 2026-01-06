local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
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
local state = require("localsend_state")
local lsutils = require("localsend_utils")
local lsupdate = require("localsend_update")
local lsrouting = require("localsend_routing")
local lstransfers = require("localsend_transfers")
local lsdialogs = require("localsend_dialogs")

-- Polling interval for sentinel file (cheap stat() only)
local SENTINEL_POLL_INTERVAL = 2

-- Import utility functions from localsend_utils module
local isValidPath = lsutils.isValidPath
local isValidPort = lsutils.isValidPort
local compareVersions = lsutils.compareVersions
local findAssetForArch = lsutils.findAssetForArch
local normalizeApostrophes = lsutils.normalizeApostrophes
local validateDeviceName = lsutils.validateDeviceName

-- Check if an iptables rule exists (returns true if rule exists)
-- @param rule_args table Array of iptables arguments (e.g., {"INPUT", "-p", "tcp", "--dport", "53317", "-j", "ACCEPT"})
-- @return boolean True if rule exists, false otherwise
local function iptablesRuleExists(rule_args)
    -- Build command with -C (check) flag
    local cmd_args = {"iptables", "-C"}
    for _, arg in ipairs(rule_args) do
        table.insert(cmd_args, arg)
    end
    -- Use shell_escape for proper argument quoting
    local cmd = util.shell_escape(cmd_args) .. " 2>/dev/null"
    local result = os.execute(cmd)
    return result == 0
end

-- Add iptables rule only if it doesn't already exist
-- @param rule_args table Array of iptables arguments (e.g., {"INPUT", "-p", "tcp", "--dport", "53317", "-j", "ACCEPT"})
-- @return boolean True if rule was added, false if it already existed
local function iptablesAddIfMissing(rule_args)
    if not iptablesRuleExists(rule_args) then
        -- Build command with -A (append) flag
        local cmd_args = {"iptables", "-A"}
        for _, arg in ipairs(rule_args) do
            table.insert(cmd_args, arg)
        end
        os.execute(util.shell_escape(cmd_args))
        return true
    end
    return false
end

-- Delete iptables rule (silently ignores if rule doesn't exist)
-- @param rule_args table Array of iptables arguments
local function iptablesDelete(rule_args)
    local cmd_args = {"iptables", "-D"}
    for _, arg in ipairs(rule_args) do
        table.insert(cmd_args, arg)
    end
    os.execute(util.shell_escape(cmd_args) .. " 2>/dev/null")
end

local data_dir = DataStorage:getFullDataDir()
local plugin_path = data_dir .. "/plugins/localsend.koplugin"

-- ServerState is now in localsend_state.lua module
local ServerState = state.ServerState

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
local transfer_notify_file = "/tmp/localsend_notify"  -- Sentinel file for fast transfer detection

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

    -- Auto update check settings
    self.auto_update_check = G_reader_settings:nilOrTrue("LocalSend_auto_update_check")
    self.update_check_interval_hours = G_reader_settings:readSetting("LocalSend_update_check_interval_hours") or 168  -- Weekly default
    self.last_update_check = G_reader_settings:readSetting("LocalSend_last_update_check") or 0

    -- Initialize update module with dependencies
    lsupdate.init({
        UIManager = UIManager,
        InfoMessage = InfoMessage,
        NetworkMgr = NetworkMgr,
        util = util,
        json = json,
        logger = logger,
        T = T,
        _ = _,
        G_reader_settings = G_reader_settings,
    })

    -- Initialize routing module with dependencies
    lsrouting.init({
        UIManager = UIManager,
        InfoMessage = InfoMessage,
        InputDialog = InputDialog,
        PathChooser = PathChooser,
        json = json,
        logger = logger,
        T = T,
        _ = _,
        G_reader_settings = G_reader_settings,
    })

    -- Initialize transfers module with dependencies
    lstransfers.init({
        UIManager = UIManager,
        InfoMessage = InfoMessage,
        Notification = Notification,
        util = util,
        json = json,
        logger = logger,
        T = T,
        _ = _,
    })

    -- Initialize dialogs module with dependencies
    lsdialogs.init({
        UIManager = UIManager,
        InfoMessage = InfoMessage,
        InputDialog = InputDialog,
        PathChooser = PathChooser,
        util = util,
        logger = logger,
        T = T,
        _ = _,
        G_reader_settings = G_reader_settings,
    })

    -- Cache for menu rendering (avoids disk I/O on every menu open)
    -- Updated via _updateCache() on state changes
    self._cached_running = false
    self._cached_transfer_count = 0

    -- Create instance-specific task references for proper unscheduling
    -- (See UIManager docs: anonymous functions cannot be unscheduled)
    self.check_sentinel_task = function()
        self:_checkSentinelFile()
    end
    self.resume_start_task = function()
        self:start(true)  -- silent=true to suppress notification
    end
    self.check_update_task = function()
        self:_autoCheckForUpdates()
    end

    -- Clean up orphaned resources from previous crashes
    self:_cleanupOrphanedResources()

    -- Handle missed resume event: if was_running_before_suspend is true, a previous
    -- widget instance was destroyed during suspend/resume and this new instance
    -- needs to restart the server. This takes priority over autostart.
    if ServerState.was_running_before_suspend and not ServerState.user_stopped then
        ServerState.was_running_before_suspend = false  -- Clear flag before starting
        NetworkMgr:runWhenConnected(function()
            if not ServerState.user_stopped then
                self:start(true)  -- silent=true like normal resume
            end
        end)
    -- Only autostart if:
    -- 1. autostart setting is enabled
    -- 2. user hasn't explicitly stopped the server this session
    -- (ServerState resets on KOReader restart, so autostart works on fresh launch)
    elseif self.autostart and not ServerState.user_stopped then
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

    -- Schedule auto update check if enabled
    if self.auto_update_check then
        self:_scheduleUpdateCheck()
    end

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
    -- Keep handlers registered if:
    -- 1. Server is currently running
    -- 2. Autostart is enabled and user hasn't stopped it
    -- 3. Server was running before suspend/disconnect (so we can restart on resume)
    local should_register = self:isRunning()
        or (self.autostart and not ServerState.user_stopped)
        or ServerState.was_running_before_suspend
        or ServerState.was_running_before_disconnect
    if should_register then
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
    self:_unscheduleUpdateCheck()

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

    -- Reschedule update check after resume
    if self.auto_update_check then
        self:_scheduleUpdateCheck()
    end

    if ServerState.was_running_before_suspend and not ServerState.user_stopped then
        if NetworkMgr:isConnected() then
            -- Network already available (fast reconnect or didn't disconnect)
            ServerState.was_running_before_suspend = false
            self:start(true)  -- silent=true to suppress notification
        else
            -- Network not ready yet - keep flag set and let _onNetworkConnected handle it
            logger.dbg("[LocalSend] Waiting for network to restart server")
        end
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
        if NetworkMgr:isConnected() then
            -- Network already available
            ServerState.was_running_before_suspend = false
            self:start(true)  -- silent=true to suppress notification
        else
            -- Network not ready yet - keep flag set and let _onNetworkConnected handle it
            logger.dbg("[LocalSend] Waiting for network to restart server")
        end
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
    -- Restart if we were waiting for network after suspend OR after disconnect
    local should_restart = (ServerState.was_running_before_suspend or ServerState.was_running_before_disconnect)
        and not ServerState.user_stopped
    if should_restart then
        -- Clear both flags
        ServerState.was_running_before_suspend = false
        ServerState.was_running_before_disconnect = false
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
    if self.check_sentinel_task then
        UIManager:unschedule(self.check_sentinel_task)
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

    -- Recreate task references if they were nullified by onCloseWidget
    -- This can happen during suspend/resume cycles when the widget is closed
    if not self.check_sentinel_task then
        self.check_sentinel_task = function()
            self:_checkSentinelFile()
        end
    end

    -- Start fast sentinel polling for responsive notifications
    self:_unschedulePolling()  -- Ensure no duplicate polling
    ServerState.last_sentinel_value = nil  -- Reset to pick up current state
    UIManager:scheduleIn(SENTINEL_POLL_INTERVAL, self.check_sentinel_task)

    if not silent then
        -- Build concise startup message for top notification
        local network_info = Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() or nil
        local pin_status = self.pin ~= "" and _("PIN") or nil

        local message_parts = { effective_name }

        -- Try to extract IP and show with port for manual connection
        local ip_addr = network_info and network_info:match("(%d+%.%d+%.%d+%.%d+)")
        if ip_addr then
            table.insert(message_parts, ip_addr .. ":" .. self.port)
        end

        if pin_status then
            table.insert(message_parts, pin_status)
        end

        UIManager:show(Notification:new{
            text = _("LocalSend Ready") .. " - " .. table.concat(message_parts, " | "),
            timeout = 5,
        })
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
    self.check_sentinel_task = nil

    -- Unschedule any pending resume task
    self:_unscheduleResume()
    self.resume_start_task = nil

    -- Unschedule update check task
    self:_unscheduleUpdateCheck()
    self.check_update_task = nil

    -- Note: Server process continues running - new widget instance
    -- will take over polling responsibility in init() if server is running
end

function LocalSend:openFirewall()
    if Device:isKindle() then
        if not isValidPort(self.port) then
            logger.err("[LocalSend] Invalid port, cannot configure firewall")
            return
        end
        local port = tostring(self.port)
        -- TCP for file transfer (idempotent - won't add if already exists)
        iptablesAddIfMissing({"INPUT", "-p", "tcp", "--dport", port,
            "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-j", "ACCEPT"})
        iptablesAddIfMissing({"OUTPUT", "-p", "tcp", "--sport", port,
            "-m", "conntrack", "--ctstate", "ESTABLISHED", "-j", "ACCEPT"})
        -- UDP for device discovery
        iptablesAddIfMissing({"INPUT", "-p", "udp", "--dport", port, "-j", "ACCEPT"})
        iptablesAddIfMissing({"OUTPUT", "-p", "udp", "--sport", port, "-j", "ACCEPT"})
        -- WebRTC/ICE UDP ports - must match range in peer.go SetEphemeralUDPPortRange
        if self.use_webrtc then
            iptablesAddIfMissing({"INPUT", "-p", "udp", "--dport", "50000:50100", "-j", "ACCEPT"})
            iptablesAddIfMissing({"OUTPUT", "-p", "udp", "--sport", "50000:50100", "-j", "ACCEPT"})
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
        local port = tostring(self.port)
        iptablesDelete({"INPUT", "-p", "tcp", "--dport", port,
            "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-j", "ACCEPT"})
        iptablesDelete({"OUTPUT", "-p", "tcp", "--sport", port,
            "-m", "conntrack", "--ctstate", "ESTABLISHED", "-j", "ACCEPT"})
        iptablesDelete({"INPUT", "-p", "udp", "--dport", port, "-j", "ACCEPT"})
        iptablesDelete({"OUTPUT", "-p", "udp", "--sport", port, "-j", "ACCEPT"})
        -- Clean up WebRTC UDP rules (ignore errors if they don't exist)
        iptablesDelete({"INPUT", "-p", "udp", "--dport", "50000:50100", "-j", "ACCEPT"})
        iptablesDelete({"OUTPUT", "-p", "udp", "--sport", "50000:50100", "-j", "ACCEPT"})
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

-- Transfer logging functions (delegated to localsend_transfers module)
function LocalSend:getTransferLog()
    return lstransfers.getTransferLog()
end

function LocalSend:getNewTransfers()
    return lstransfers.getNewTransfers()
end

function LocalSend:getTransferCount()
    return lstransfers.getTransferCount()
end

function LocalSend:clearTransferLog()
    lstransfers.clearTransferLog()
end

function LocalSend:_checkForNewTransfers()
    lstransfers.checkForNewTransfers(self)
end

function LocalSend:_checkSentinelFile()
    lstransfers.checkSentinelFile(self)
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
        -- Start sentinel polling for fast notifications
        self:_unschedulePolling()
        ServerState.last_sentinel_value = nil
        UIManager:scheduleIn(SENTINEL_POLL_INTERVAL, self.check_sentinel_task)
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

    -- Add on-transfer callback to write unique value to sentinel file for fast notification
    -- Using date +%s%N gives nanosecond precision to avoid mtime resolution issues
    table.insert(args, "--on-transfer")
    table.insert(args, "date +%s%N > " .. transfer_notify_file)

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
    UIManager:show(Notification:new{
        text = _("LocalSend stopped"),
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

-- UI dialog functions (delegated to localsend_dialogs module)
function LocalSend:getPickerStartPath(path)
    return lsdialogs.getPickerStartPath(path)
end

function LocalSend:showSaveDirPicker(touchmenu_instance)
    lsdialogs.showSaveDirPicker(self, touchmenu_instance)
end

function LocalSend:showDeviceNameDialog(touchmenu_instance)
    lsdialogs.showDeviceNameDialog(self, touchmenu_instance)
end

function LocalSend:showPinDialog(touchmenu_instance)
    lsdialogs.showPinDialog(self, touchmenu_instance)
end

function LocalSend:showCustomExtDialog()
    lsdialogs.showCustomExtDialog(self)
end

function LocalSend:buildExtensionPresetsMenu()
    return lsdialogs.buildExtensionPresetsMenu(self)
end

-- Extension routing functions (delegated to localsend_routing module)
function LocalSend:exportExtRouting()
    return lsrouting.exportExtRouting(self.routing_enabled, self.ext_dirs, self.routing_accept_all, self.save_dir, plugin_path)
end

function LocalSend:addExtensionRoute(ext, dir)
    lsrouting.addExtensionRoute(self, ext, dir)
end

function LocalSend:removeExtensionRoute(ext)
    lsrouting.removeExtensionRoute(self, ext)
end

function LocalSend:showAddExtensionRouteDialog(touchmenu_instance)
    lsrouting.showAddExtensionRouteDialog(self, touchmenu_instance)
end

function LocalSend:showCustomExtensionDialog(touchmenu_instance)
    lsrouting.showCustomExtensionDialog(self, touchmenu_instance)
end

function LocalSend:showExtensionDirPicker(ext, touchmenu_instance)
    lsrouting.showExtensionDirPicker(self, ext, touchmenu_instance)
end

function LocalSend:refreshRoutingMenu(touchmenu_instance)
    lsrouting.refreshRoutingMenu(self, touchmenu_instance)
end

function LocalSend:buildExtensionRoutingMenu()
    return lsrouting.buildExtensionRoutingMenu(self)
end

function LocalSend:showRecentTransfers()
    lstransfers.showRecentTransfers(self)
end

function LocalSend:rotateCertificates()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("This will delete the current TLS certificates.\n\nTrusted devices may need to re-verify the connection.\n\nContinue?"),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Remove certificates from the certs folder next to the binary
            -- Go will generate new ones on next start
            os.execute(util.shell_escape({"rm", "-f", certs_path .. "/server.key.pem"}))
            os.execute(util.shell_escape({"rm", "-f", certs_path .. "/server.crt"}))

            UIManager:show(InfoMessage:new{
                text = _("Certificates cleared. New certificates will be generated on next start."),
                timeout = 3,
            })
        end,
    })
end

function LocalSend:getDeviceArch()
    return lsupdate.getDeviceArch()
end

function LocalSend:performUpdate(download_url, asset_name, new_version)
    lsupdate.performUpdate(self, download_url, asset_name, new_version, plugin_path)
end

function LocalSend:doPerformUpdate(download_url, asset_name, new_version)
    lsupdate.doPerformUpdate(self, download_url, asset_name, new_version, plugin_path)
end

-- =========================================================================
-- Auto Update Check Methods
-- =========================================================================

-- Calculate seconds until next update check
function LocalSend:_getUpdateCheckDelay()
    return lsupdate.getUpdateCheckDelay(self.last_update_check, self.update_check_interval_hours)
end

-- Schedule the next update check
function LocalSend:_scheduleUpdateCheck()
    if not self.auto_update_check then
        return
    end

    local delay = self:_getUpdateCheckDelay()
    logger.dbg("[LocalSend] Scheduling update check in", delay, "seconds")
    UIManager:scheduleIn(delay, self.check_update_task)
end

-- Unschedule update check task
function LocalSend:_unscheduleUpdateCheck()
    if self.check_update_task then
        UIManager:unschedule(self.check_update_task)
    end
end

-- Auto update check (silent, uses Notification not ConfirmBox)
function LocalSend:_autoCheckForUpdates()
    -- If offline, silently skip and reschedule
    if not NetworkMgr:isOnline() then
        self:_scheduleUpdateCheck()
        return
    end

    -- Create schedule_next callback for the update module
    local schedule_next = function()
        self:_scheduleUpdateCheck()
    end

    lsupdate.doAutoCheckForUpdates(self, PLUGIN_VERSION, schedule_next)
end

function LocalSend:checkForUpdates()
    lsupdate.checkForUpdates(self, PLUGIN_VERSION, plugin_path)
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
                    if self.auto_update_check then
                        local intervals = { [12] = "12h", [24] = "24h", [72] = "3 days", [168] = "Weekly" }
                        local label = intervals[self.update_check_interval_hours] or (self.update_check_interval_hours .. "h")
                        return T(_("Auto-check for updates (%1)"), label)
                    else
                        return _("Auto-check for updates")
                    end
                end,
                checked_func = function() return self.auto_update_check end,
                -- Long-press to quick toggle enable/disable
                hold_callback = function(touchmenu_instance)
                    self.auto_update_check = not self.auto_update_check
                    G_reader_settings:flipNilOrTrue("LocalSend_auto_update_check")
                    if self.auto_update_check then
                        self:_scheduleUpdateCheck()
                    else
                        self:_unscheduleUpdateCheck()
                    end
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
                -- Tap to open submenu for interval configuration
                sub_item_table = {
                    {
                        text = _("Enable auto-check"),
                        checked_func = function() return self.auto_update_check end,
                        callback = function()
                            self.auto_update_check = not self.auto_update_check
                            G_reader_settings:flipNilOrTrue("LocalSend_auto_update_check")
                            if self.auto_update_check then
                                self:_scheduleUpdateCheck()
                            else
                                self:_unscheduleUpdateCheck()
                            end
                        end,
                    },
                    { text = "---" },
                    {
                        text = _("Every 12 hours"),
                        enabled_func = function() return self.auto_update_check end,
                        checked_func = function() return self.update_check_interval_hours == 12 end,
                        callback = function()
                            self.update_check_interval_hours = 12
                            G_reader_settings:saveSetting("LocalSend_update_check_interval_hours", 12)
                        end,
                    },
                    {
                        text = _("Every 24 hours"),
                        enabled_func = function() return self.auto_update_check end,
                        checked_func = function() return self.update_check_interval_hours == 24 end,
                        callback = function()
                            self.update_check_interval_hours = 24
                            G_reader_settings:saveSetting("LocalSend_update_check_interval_hours", 24)
                        end,
                    },
                    {
                        text = _("Every 3 days"),
                        enabled_func = function() return self.auto_update_check end,
                        checked_func = function() return self.update_check_interval_hours == 72 end,
                        callback = function()
                            self.update_check_interval_hours = 72
                            G_reader_settings:saveSetting("LocalSend_update_check_interval_hours", 72)
                        end,
                    },
                    {
                        text = _("Weekly (default)"),
                        enabled_func = function() return self.auto_update_check end,
                        checked_func = function() return self.update_check_interval_hours == 168 end,
                        callback = function()
                            self.update_check_interval_hours = 168
                            G_reader_settings:saveSetting("LocalSend_update_check_interval_hours", 168)
                        end,
                    },
                },
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
