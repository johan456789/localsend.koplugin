local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local json = require("json")

local GITHUB_RELEASE_URL = "https://api.github.com/repos/kaikozlov/localsend.koplugin/releases/latest"

-- Shell escape utility to prevent command injection
-- Wraps string in single quotes and escapes any embedded single quotes
local function shellEscape(str)
    if str == nil then return "''" end
    -- Single quote escape: replace ' with '\''
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

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
local plugin_meta = dofile(plugin_path .. "/_meta.lua")
local PLUGIN_VERSION = plugin_meta.version or "unknown"
local binary_path = plugin_path .. "/localsend"
local cert_storage_path = plugin_path .. "/certs"
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
    last_transfer_count = 0,
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

    if self.autostart then
        self:start()
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- Cleanup when KOReader exits (not when switching documents)
-- Note: onCloseWidget is called when switching books, so we don't stop the server there.
-- Instead, we stop on Exit event which is only triggered when KOReader actually closes.
function LocalSend:onExit()
    if self:isRunning() then
        self:stopServer(true)
        logger.dbg("[LocalSend] Server stopped on KOReader exit")
    end
end

function LocalSend:setupCertificates()
    -- Ensure cert storage directory exists
    if not util.pathExists(cert_storage_path) then
        os.execute("mkdir -p " .. shellEscape(cert_storage_path))
    end

    local stored_key = cert_storage_path .. "/server.key.pem"
    local stored_cert = cert_storage_path .. "/server.crt"
    local tmp_key = "/tmp/server.key.pem"
    local tmp_cert = "/tmp/server.crt"

    -- If we have stored certs, symlink them to /tmp where localsend expects them
    if util.pathExists(stored_key) and util.pathExists(stored_cert) then
        os.execute("ln -sf " .. shellEscape(stored_key) .. " " .. shellEscape(tmp_key))
        os.execute("ln -sf " .. shellEscape(stored_cert) .. " " .. shellEscape(tmp_cert))
        logger.dbg("[LocalSend] Using stored certificates")
        return true
    end

    return false
end

function LocalSend:saveCertificates()
    -- After first run, copy generated certs to persistent storage
    local tmp_key = "/tmp/server.key.pem"
    local tmp_cert = "/tmp/server.crt"
    local stored_key = cert_storage_path .. "/server.key.pem"
    local stored_cert = cert_storage_path .. "/server.crt"

    if util.pathExists(tmp_key) and util.pathExists(tmp_cert) then
        if not util.pathExists(stored_key) then
            os.execute("cp " .. shellEscape(tmp_key) .. " " .. shellEscape(stored_key))
            os.execute("cp " .. shellEscape(tmp_cert) .. " " .. shellEscape(stored_cert))
            logger.dbg("[LocalSend] Saved certificates for future use")
        end
    end
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
    -- Empty name is valid (will use random name)
    if name == "" then
        return true
    end

    -- Check length (reasonable limit)
    if #name > 64 then
        return false, _("Device name is too long (max 64 characters).")
    end

    -- Only allow alphanumeric, spaces, hyphens, underscores, and apostrophes (straight and curly)
    -- This matches the style of generated aliases (e.g., "Special Pineapple")
    -- and avoids shell injection and JSON encoding issues
    if not name:match("^[%w%s%-_'’‘]+$") then
        return false, _("Device name can only contain letters, numbers, spaces, hyphens, underscores, and apostrophes.")
    end

    return true
end

function LocalSend:validateSaveDir(path)
    -- Validate path is safe for shell operations
    if not isValidPath(path) then
        return false, _("Invalid path: must be an absolute path without special characters.")
    end

    -- Check if path exists
    if not util.pathExists(path) then
        -- Try to create it
        local result = os.execute("mkdir -p " .. shellEscape(path))
        if result ~= 0 then
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

function LocalSend:getTransferCount()
    local count = 0
    if not util.pathExists(transfer_log_file) then
        return 0
    end

    local f = io.open(transfer_log_file, "r")
    if not f then return 0 end

    for _ in f:lines() do
        count = count + 1
    end
    f:close()

    return count
end

function LocalSend:clearTransferLog()
    os.remove(transfer_log_file)
    self.last_transfer_count = 0
end

function LocalSend:checkForNewTransfers()
    if not self:isRunning() then
        return
    end

    local current_count = self:getTransferCount()
    if current_count > self.last_transfer_count then
        local new_count = current_count - self.last_transfer_count
        local transfers = self:getTransferLog()

        -- Get the most recent transfer
        local latest = transfers[#transfers]
        if latest then
            local text
            if new_count == 1 then
                text = T(_("File received: %1"), latest.filename)
            else
                text = T(_("%1 files received. Latest: %2"), new_count, latest.filename)
            end

            UIManager:show(InfoMessage:new{
                text = text,
                timeout = 5,
            })
        end

        self.last_transfer_count = current_count
    end

    -- Schedule next check only if still running
    if self:isRunning() then
        UIManager:scheduleIn(5, function()
            self:checkForNewTransfers()
        end)
    end
end

function LocalSend:start()
    if self:isRunning() then
        logger.dbg("[LocalSend] Server already running")
        return
    end

    -- Validate save directory
    local valid, err = self:validateSaveDir(self.save_dir)
    if not valid then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Invalid save directory: %1"), err),
        })
        return
    end

    -- Setup persistent certificates
    self:setupCertificates()

    -- Clear old transfer log and reset count
    self:clearTransferLog()

    -- Build command with proper shell escaping
    local cmd = string.format("%s recv -d %s -l %s",
        shellEscape(binary_path),
        shellEscape(self.save_dir),
        shellEscape(transfer_log_file))

    if self.device_name ~= "" then
        cmd = string.format("%s -n %s", cmd, shellEscape(self.device_name))
    end

    if self.pin ~= "" then
        cmd = string.format("%s -p %s", cmd, shellEscape(self.pin))
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
        cmd = string.format("%s -a %s", cmd, shellEscape(effective_accept_ext))
    end

    if not self.use_https then
        cmd = string.format("%s --https=false", cmd)
    end

    if not self.use_webrtc then
        cmd = string.format("%s -w=false", cmd)
    end

    -- Export and apply extension routing config if configured
    local routing_path = self:exportExtRouting()
    if routing_path then
        cmd = string.format("%s --ext-routing %s", cmd, shellEscape(routing_path))
    end

    -- Open firewall before starting
    self:openFirewall()

    -- Run in background and save PID
    cmd = string.format("(%s) & echo $! > %s", cmd, shellEscape(pid_file))

    logger.dbg("[LocalSend] Starting server: ", cmd)

    local result = os.execute(cmd)

    if result == 0 then
        -- Poll for server readiness (max 5 seconds)
        local ready = false
        for _ = 1, 50 do  -- 50 * 100ms = 5 seconds
            ffiutil.usleep(100000)  -- 100ms
            if self:isRunning() then
                ready = true
                break
            end
        end

        -- Verify it actually started
        if ready then
            self:saveCertificates()

            -- Start checking for new transfers
            UIManager:scheduleIn(5, function()
                self:checkForNewTransfers()
            end)

            local info = InfoMessage:new{
                timeout = 10,
                text = T(_("LocalSend server started.\n\nPort: %1\nSave directory: %2\n%3"),
                    self.port,
                    self.save_dir,
                    Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() or _("Could not retrieve network info.")),
            }
            UIManager:show(info)
        else
            self:closeFirewall()
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("LocalSend process failed to start within 5 seconds. Check if the binary works."),
            })
        end
    else
        self:closeFirewall()
        local info = InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to start LocalSend server."),
        }
        UIManager:show(info)
    end
end

function LocalSend:isRunning()
    if not util.pathExists(pid_file) then
        return false
    end

    -- Helper to check PID validity
    local function checkPID()
        local f = io.open(pid_file, "r")
        if not f then return false end
        local pid = f:read("*l")
        f:close()

        if pid and tonumber(pid) then
            return util.pathExists("/proc/" .. pid)
        end
        return false
    end

    -- Check twice with small delay to handle race conditions
    -- (PID file might be written but process not yet fully started,
    -- or process might exit between reading PID and checking /proc)
    if checkPID() then
        return true
    end
    ffiutil.usleep(10000)  -- 10ms
    return checkPID()
end

function LocalSend:stopServer(force)
    if not util.pathExists(pid_file) then
        return true
    end

    local function readPID()
        local f = io.open(pid_file, "r")
        if not f then return nil end
        local s = f:read("*l")
        f:close()
        return s and tonumber(s) or nil
    end

    local pid = readPID()

    local function isProcAlive(p)
        return p and util.pathExists("/proc/" .. p)
    end

    local function send(sig, p)
        return os.execute(string.format("kill -%s %d", sig, p)) == 0
    end

    if pid then
        send("TERM", pid)
        for _ = 1, 20 do
            if not isProcAlive(pid) then break end
            ffiutil.sleep(0.1)
        end

        if isProcAlive(pid) and force then
            send("KILL", pid)
            for _ = 1, 10 do
                if not isProcAlive(pid) then break end
                ffiutil.sleep(0.1)
            end
        end

        if not isProcAlive(pid) then
            os.remove(pid_file)
            self:closeFirewall()
            return true
        end
        return false, "LocalSend process did not exit"
    end

    os.remove(pid_file)
    self:closeFirewall()
    return true
end

function LocalSend:stop()
    local ok, err = self:stopServer(false)
    if not ok then
        logger.warn("[LocalSend] Graceful stop failed:", err)
        ok, err = self:stopServer(true)
        if not ok then
            logger.err("[LocalSend] Force stop failed:", err)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Failed to stop LocalSend server."),
            })
            return
        end
    end
    UIManager:show(InfoMessage:new{
        text = _("LocalSend server stopped."),
        timeout = 2,
    })
end

function LocalSend:restart()
    if self:isRunning() then
        self:stopServer(true)
    end
    self:start()
end

function LocalSend:onToggleLocalSend()
    if self:isRunning() then
        self:stop()
    else
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
    self.device_name_dialog = InputDialog:new{
        title = _("Device name"),
        description = _("Leave empty for random name (e.g., 'Special Pineapple')"),
        input = self.device_name,
        input_hint = "My Kindle",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.device_name_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_name = self.device_name_dialog:getInputText()
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
                        UIManager:close(self.device_name_dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(self.device_name_dialog)
    self.device_name_dialog:onShowKeyboard()
end

function LocalSend:showPinDialog(touchmenu_instance)
    self.pin_dialog = InputDialog:new{
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
                        UIManager:close(self.pin_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.pin = self.pin_dialog:getInputText()
                        G_reader_settings:saveSetting("LocalSend_pin", self.pin)
                        UIManager:close(self.pin_dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(self.pin_dialog)
    self.pin_dialog:onShowKeyboard()
end

function LocalSend:showCustomExtDialog()
    self.accept_ext_dialog = InputDialog:new{
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
                        UIManager:close(self.accept_ext_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.accept_ext = self.accept_ext_dialog:getInputText()
                        G_reader_settings:saveSetting("LocalSend_accept_ext", self.accept_ext)
                        UIManager:close(self.accept_ext_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(self.accept_ext_dialog)
    self.accept_ext_dialog:onShowKeyboard()
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

    local buttons = {}
    for _, row in ipairs(ext_presets) do
        local button_row = {}
        for _, ext in ipairs(row) do
            table.insert(button_row, {
                text = ext,
                callback = function()
                    UIManager:close(self.ext_preset_dialog)
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
                UIManager:close(self.ext_preset_dialog)
                self:showCustomExtensionDialog(touchmenu_instance)
            end,
        },
    })

    self.ext_preset_dialog = ButtonDialog:new{
        title = _("Select extension to route"),
        buttons = buttons,
    }
    UIManager:show(self.ext_preset_dialog)
end

function LocalSend:showCustomExtensionDialog(touchmenu_instance)
    self.custom_ext_dialog = InputDialog:new{
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
                        UIManager:close(self.custom_ext_dialog)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local ext = self.custom_ext_dialog:getInputText()
                        if ext and ext ~= "" then
                            ext = string.lower(ext:gsub("^%.", "")) -- Remove leading dot if present
                            UIManager:close(self.custom_ext_dialog)
                            self:showExtensionDirPicker(ext, touchmenu_instance)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.custom_ext_dialog)
    self.custom_ext_dialog:onShowKeyboard()
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
            help_text = _("When enabled, files are routed to directories based on their extension. When disabled, all files go to the main save directory."),
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
                self.route_action_dialog = ButtonDialog:new{
                    title = T(_("Route for .%1"), captured_ext),
                    buttons = {
                        {
                            {
                                text = _("Change directory"),
                                callback = function()
                                    UIManager:close(self.route_action_dialog)
                                    self:showExtensionDirPicker(captured_ext, touchmenu_instance)
                                end,
                            },
                        },
                        {
                            {
                                text = _("Remove route"),
                                callback = function()
                                    UIManager:close(self.route_action_dialog)
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
                UIManager:show(self.route_action_dialog)
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
            help_text = _("When enabled, files without a specific route are saved to the main save directory. When disabled, only routed file types are accepted."),
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
        local size_str = ""
        if t.size then
            if t.size >= 1048576 then
                size_str = string.format(" (%.1f MB)", t.size / 1048576)
            elseif t.size >= 1024 then
                size_str = string.format(" (%.1f KB)", t.size / 1024)
            else
                size_str = string.format(" (%d B)", t.size)
            end
        end
        table.insert(lines, string.format("%d. %s%s", i, t.filename, size_str))
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Recent transfers (%1 total):\n\n%2"), #transfers, table.concat(lines, "\n")),
    })
end

function LocalSend:rotateCertificates()
    -- Remove stored certificates so new ones will be generated
    os.execute("rm -f " .. shellEscape(cert_storage_path .. "/server.key.pem"))
    os.execute("rm -f " .. shellEscape(cert_storage_path .. "/server.crt"))
    os.execute("rm -f " .. shellEscape("/tmp/server.key.pem"))
    os.execute("rm -f " .. shellEscape("/tmp/server.crt"))

    UIManager:show(InfoMessage:new{
        text = _("Certificates cleared. New certificates will be generated on next start."),
        timeout = 3,
    })
end

function LocalSend:compareVersions(v1, v2)
    -- Compare semantic versions, returns:
    -- -1 if v1 < v2, 0 if equal, 1 if v1 > v2
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

function LocalSend:getDeviceArch()
    -- Detect device architecture for selecting the right binary
    local handle = io.popen("uname -m")
    if not handle then return nil end
    local arch = handle:read("*l")
    handle:close()

    if not arch then return nil end

    -- Map uname output to our asset naming
    if arch:match("^aarch64") or arch:match("^arm64") then
        return "arm64"
    elseif arch:match("^armv7") or arch:match("^armv6") or arch:match("^arm") then
        return "armv7"
    end

    return nil
end

function LocalSend:findAssetForArch(assets, arch)
    -- Find the download URL for our architecture
    local pattern = "localsend%-koplugin%-" .. arch .. "%.zip$"
    for _, asset in ipairs(assets) do
        if asset.name and asset.name:match(pattern) then
            return asset.browser_download_url, asset.name
        end
    end
    return nil, nil
end

function LocalSend:performUpdate(download_url, asset_name, new_version)
    -- Stop server if running
    if self:isRunning() then
        self:stopServer(true)
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
    os.execute("rm -rf " .. shellEscape(tmp_extract))

    -- Download the zip
    local cmd = string.format(
        "curl -L -s -o %s -w '%%{http_code}' --connect-timeout 30 --max-time 120 %s",
        shellEscape(tmp_zip), shellEscape(download_url))

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
    os.execute("mkdir -p " .. shellEscape(tmp_extract))

    -- Extract the zip
    local extract_cmd = string.format("unzip -o %s -d %s", shellEscape(tmp_zip), shellEscape(tmp_extract))
    local result = os.execute(extract_cmd)

    if result ~= 0 then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to extract update."),
        })
        os.remove(tmp_zip)
        os.execute("rm -rf " .. shellEscape(tmp_extract))
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
        os.execute("rm -rf " .. shellEscape(tmp_extract))
        return
    end

    -- Copy files to plugin directory
    local files_to_copy = { "main.lua", "_meta.lua", "localsend" }
    local copy_failed = false

    for _, file in ipairs(files_to_copy) do
        local src = extracted_plugin .. "/" .. file
        local dst = plugin_path .. "/" .. file

        if util.pathExists(src) then
            local cp_result = os.execute(string.format("cp %s %s", shellEscape(src), shellEscape(dst)))
            if cp_result ~= 0 then
                copy_failed = true
                logger.err("[LocalSend] Failed to copy:", file)
            end
        else
            logger.warn("[LocalSend] File not in update package:", file)
        end
    end

    -- Make binary executable
    os.execute("chmod +x " .. shellEscape(plugin_path .. "/localsend"))

    -- Cleanup
    os.remove(tmp_zip)
    os.execute("rm -rf " .. shellEscape(tmp_extract))

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

    local f = io.open(tmp_file, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to read update information."),
        })
        return
    end

    local content = f:read("*a")
    f:close()
    os.remove(tmp_file)

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

    if self:compareVersions(current_version, latest_version) >= 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("You're up to date!\n\nCurrent version: %1\nLatest version: %2"), PLUGIN_VERSION, release.tag_name),
            timeout = 5,
        })
    else
        -- Update available - check if we can auto-update
        local arch = self:getDeviceArch()
        local download_url, asset_name

        if arch and release.assets then
            download_url, asset_name = self:findAssetForArch(release.assets, arch)
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
            local reason = ""
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
            if self:isRunning() then
                local count = self:getTransferCount()
                if count > 0 then
                    return T(_("LocalSend (%1 received)"), count)
                end
                return _("LocalSend (running)")
            end
            return _("LocalSend")
        end,
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    if self:isRunning() then
                        return _("Stop server")
                    else
                        return _("Start server")
                    end
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onToggleLocalSend()
                    ffiutil.sleep(1)
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    local count = self:getTransferCount()
                    if count > 0 then
                        return T(_("Recent transfers (%1)"), count)
                    end
                    return _("Recent transfers")
                end,
                enabled_func = function() return self:getTransferCount() > 0 end,
                callback = function()
                    self:showRecentTransfers()
                end,
            },
            {
                text_func = function()
                    return T(_("Save directory (%1)"), self.save_dir)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:showSaveDirPicker(touchmenu_instance)
                end,
            },
            {
                text = _("Settings"),
                enabled_func = function() return not self:isRunning() end,
                sub_item_table = {
                    {
                        text_func = function()
                            if self.device_name ~= "" then
                                return T(_("Device name (%1)"), self.device_name)
                            else
                                return _("Device name (random)")
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

return LocalSend
