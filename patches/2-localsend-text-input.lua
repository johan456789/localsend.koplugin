--[[--
LocalSend Text Input Integration for KOReader

This user patch enables receiving text from your phone via LocalSend
directly into KOReader's text input fields.

When you open a text input dialog (search, notes, etc.), this patch:
1. Auto-starts the LocalSend server in "text input mode"
2. Accepts .txt files from LocalSend
3. Inserts the text content directly into the active text field
4. Shows a toast notification confirming the action

If direct insertion fails, the text is copied to clipboard instead.

Installation:
1. Copy this file to koreader/patches/
2. Make sure localsend.koplugin is installed
3. Restart KOReader

Usage:
1. Tap on any text input field in KOReader (search, notes, etc.)
2. On your phone, open LocalSend
3. Create a text file or use "Send text" feature
4. Send the .txt file to your Kindle/e-reader
5. The text will be inserted automatically

@module 2-localsend-text-input
--]]

local Device = require("device")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

-- Constants
local TEXT_INPUT_SAVE_DIR = "/tmp/localsend_textinput"
local POLL_INTERVAL = 0.5  -- seconds
local STARTUP_CHECK_INTERVAL = 0.1  -- seconds
local STARTUP_MAX_ATTEMPTS = 50
local LOG_PREFIX = "[LocalSend-TextInput]"

-- State tracking
local TextInputIntegration = {
    active_input_widget = nil,
    server_started_by_us = false,
    server_start_requested_by_us = false,
    poll_task = nil,
    startup_task = nil,
    plugin_instance = nil,
    original_plugin_config = nil,
    original_check_for_new_transfers = nil,
    using_raw_server = false,
}

-- Get the LocalSend plugin instance
local function getLocalSendPlugin()
    local PluginLoader = require("pluginloader")
    if PluginLoader.getPluginInstance then
        local instance = PluginLoader:getPluginInstance("localsend")
            or PluginLoader:getPluginInstance("LocalSend")
        if instance then
            return instance
        end
    end

    -- Fallback: inspect loaded_plugins table directly if available.
    if PluginLoader.loaded_plugins then
        return PluginLoader.loaded_plugins.localsend
            or PluginLoader.loaded_plugins.LocalSend
    end

    return nil
end

-- Check if localsend.koplugin is installed
local function isLocalSendInstalled()
    local DataStorage = require("datastorage")
    local plugin_path = DataStorage:getFullDataDir() .. "/plugins/localsend.koplugin"
    return util.pathExists(plugin_path)
end

-- Create the text input save directory
local function ensureSaveDir()
    if not util.pathExists(TEXT_INPUT_SAVE_DIR) then
        util.makePath(TEXT_INPUT_SAVE_DIR)
    end
end

-- Clear old files from save directory
local function clearSaveDir()
    if not util.pathExists(TEXT_INPUT_SAVE_DIR) then
        return
    end

    for file in lfs.dir(TEXT_INPUT_SAVE_DIR) do
        if file ~= "." and file ~= ".." then
            os.remove(TEXT_INPUT_SAVE_DIR .. "/" .. file)
        end
    end
end

-- Get list of .txt files in save directory, oldest first.
local function getTxtFiles()
    local files = {}
    local dir = io.popen("ls -1tr " .. TEXT_INPUT_SAVE_DIR .. "/*.txt 2>/dev/null")
    if dir then
        for line in dir:lines() do
            table.insert(files, line)
        end
        dir:close()
    end
    return files
end

-- Read text content from a file
local function readTextFile(filepath)
    local f = io.open(filepath, "r")
    if not f then
        return nil
    end
    local content = f:read("*all")
    f:close()
    return content
end

-- Insert text into the active input widget
local function insertTextIntoInput(text)
    local input_widget = TextInputIntegration.active_input_widget
    if not input_widget then
        logger.warn(LOG_PREFIX, "No active input widget")
        return false
    end

    -- Try different methods to insert text
    -- Method 1: If it's an InputText widget with setText
    if input_widget.setText then
        local current_text = ""
        if input_widget.getText then
            current_text = input_widget:getText() or ""
        elseif input_widget.text then
            current_text = input_widget.text or ""
        end
        -- Append the new text
        input_widget:setText(current_text .. text)
        UIManager:setDirty(input_widget, "ui")
        return true
    end

    -- Method 2: If it's an InputDialog, try to access the internal input widget
    if input_widget._input_widget then
        local internal = input_widget._input_widget
        if internal.setText then
            local current_text = ""
            if internal.getText then
                current_text = internal:getText() or ""
            end
            internal:setText(current_text .. text)
            UIManager:setDirty(input_widget, "ui")
            return true
        end
    end

    -- Method 3: Try setInputText method (for InputDialog)
    if input_widget.setInputText then
        local current_text = ""
        if input_widget.getInputText then
            current_text = input_widget:getInputText() or ""
        end
        input_widget:setInputText(current_text .. text)
        UIManager:setDirty(input_widget, "ui")
        return true
    end

    return false
end

-- Copy text to clipboard as fallback
local function copyToClipboard(text)
    Device.input.setClipboardText(text)
    return true
end

-- Check for new text files and process them
local function checkForNewFiles()
    for _, txt_file in ipairs(getTxtFiles()) do
        local content = readTextFile(txt_file)

        if content and content ~= "" then
            -- Clean up the content (trim whitespace)
            content = content:gsub("^%s+", ""):gsub("%s+$", "")

            -- Try to insert into active input
            local inserted = insertTextIntoInput(content)

            if inserted then
                UIManager:show(Notification:new{
                    text = _("Text inserted from LocalSend"),
                    timeout = 2,
                })
            else
                -- Fallback to clipboard
                copyToClipboard(content)
                UIManager:show(Notification:new{
                    text = _("Text copied to clipboard from LocalSend"),
                    timeout = 2,
                })
            end
        end

        -- Remove the processed file
        os.remove(txt_file)
    end
end

-- Poll task function
local function pollForFiles()
    if not TextInputIntegration.active_input_widget then
        -- Input widget closed, stop polling
        TextInputIntegration:stopServer()
        return
    end

    checkForNewFiles()

    -- Schedule next poll
    if TextInputIntegration.active_input_widget then
        UIManager:scheduleIn(POLL_INTERVAL, TextInputIntegration.poll_task)
    end
end

local function beginStartupWait(is_ready)
    local attempts_remaining = STARTUP_MAX_ATTEMPTS
    TextInputIntegration.startup_task = function()
        if not TextInputIntegration.active_input_widget then
            TextInputIntegration:stopServer()
            return
        end

        if is_ready() then
            TextInputIntegration.server_started_by_us = true
            TextInputIntegration.startup_task = nil

            TextInputIntegration.poll_task = function()
                pollForFiles()
            end
            UIManager:scheduleIn(POLL_INTERVAL, TextInputIntegration.poll_task)

            UIManager:show(Notification:new{
                text = _("LocalSend ready for text input"),
                timeout = 3,
            })
            return
        end

        attempts_remaining = attempts_remaining - 1
        if attempts_remaining <= 0 then
            TextInputIntegration.startup_task = nil
            UIManager:show(Notification:new{
                text = _("LocalSend failed to start for text input"),
                timeout = 4,
            })
            return
        end

        UIManager:scheduleIn(STARTUP_CHECK_INTERVAL, TextInputIntegration.startup_task)
    end

    UIManager:scheduleIn(STARTUP_CHECK_INTERVAL, TextInputIntegration.startup_task)
end

-- Start the LocalSend server for text input
function TextInputIntegration:startServer()
    if not isLocalSendInstalled() then
        logger.dbg(LOG_PREFIX, "LocalSend plugin not installed")
        return false
    end

    ensureSaveDir()
    clearSaveDir()

    local plugin = getLocalSendPlugin()
    if not plugin then
        logger.warn(LOG_PREFIX, "LocalSend plugin instance not found; using raw recv fallback")

        local DataStorage = require("datastorage")
        local binary_path = DataStorage:getFullDataDir() .. "/plugins/localsend.koplugin/localsend"
        if not util.pathExists(binary_path) then
            UIManager:show(Notification:new{
                text = _("LocalSend binary not found"),
                timeout = 4,
            })
            return false
        end

        local PluginShare = require("pluginshare")
        if PluginShare.localsend_running then
            UIManager:show(Notification:new{
                text = _("LocalSend already running. Stop it first for text input mode."),
                timeout = 4,
            })
            return false
        end

        local pid_file = "/tmp/localsend_textinput.pid"
        local cmd = string.format(
            "(%s) & echo $! > %s",
            util.shell_escape({
                binary_path,
                "recv",
                "-d",
                TEXT_INPUT_SAVE_DIR,
                "--accept-ext",
                "txt",
                "-n",
                "KOReader-TextInput",
            }),
            util.shell_escape({pid_file})
        )

        local result = os.execute(cmd)
        if result ~= 0 then
            self.server_start_requested_by_us = false
            UIManager:show(Notification:new{
                text = _("LocalSend failed to start for text input"),
                timeout = 4,
            })
            return false
        end

        self.using_raw_server = true
        self.server_start_requested_by_us = true
        beginStartupWait(function()
            local f = io.open(pid_file, "r")
            local pid = f and f:read("*l") or nil
            if f then f:close() end
            return pid and util.pathExists("/proc/" .. pid)
        end)
        return true
    end

    -- Avoid launching a second receiver that can conflict with main LocalSend.
    if plugin.isRunning and plugin:isRunning() then
        UIManager:show(Notification:new{
            text = _("LocalSend already running. Stop it first for text input mode."),
            timeout = 4,
        })
        return false
    end

    if not plugin.start then
        logger.warn(LOG_PREFIX, "LocalSend plugin has no start() method")
        UIManager:show(Notification:new{
            text = _("LocalSend plugin start() not available"),
            timeout = 4,
        })
        return false
    end

    self.plugin_instance = plugin

    -- Temporarily override receiver settings for text-only input mode.
    self.original_plugin_config = {
        save_dir = plugin.save_dir,
        accept_ext = plugin.accept_ext,
        device_name = plugin.device_name,
        routing_enabled = plugin.routing_enabled,
    }

    plugin.save_dir = TEXT_INPUT_SAVE_DIR
    plugin.accept_ext = "txt"
    plugin.device_name = "KOReader-TextInput"
    plugin.routing_enabled = false
    -- Suppress default LocalSend "File received: <filename>" toasts during text input mode.
    self.original_check_for_new_transfers = plugin._checkForNewTransfers
    plugin._checkForNewTransfers = function() end

    self.server_start_requested_by_us = true
    plugin:start(true)

    beginStartupWait(function()
        return plugin.isRunning and plugin:isRunning()
    end)
    return true
end

-- Stop the LocalSend server if we started it
function TextInputIntegration:stopServer()
    if self.startup_task then
        UIManager:unschedule(self.startup_task)
        self.startup_task = nil
    end

    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end

    local plugin = self.plugin_instance
    local should_stop_server = self.server_started_by_us or self.server_start_requested_by_us
    if should_stop_server and plugin and plugin.stopServer then
        plugin:stopServer()
    end

    if should_stop_server and self.using_raw_server then
        local pid_file = "/tmp/localsend_textinput.pid"
        local f = io.open(pid_file, "r")
        if f then
            local pid = f:read("*l")
            f:close()
            if pid and pid:match("^%d+$") then
                os.execute(util.shell_escape({"kill", "-TERM", pid}) .. " 2>/dev/null")
            end
            os.remove(pid_file)
        end
    end

    if plugin and self.original_plugin_config then
        plugin.save_dir = self.original_plugin_config.save_dir
        plugin.accept_ext = self.original_plugin_config.accept_ext
        plugin.device_name = self.original_plugin_config.device_name
        plugin.routing_enabled = self.original_plugin_config.routing_enabled
        self.original_plugin_config = nil
    end

    if plugin and self.original_check_for_new_transfers then
        plugin._checkForNewTransfers = self.original_check_for_new_transfers
        self.original_check_for_new_transfers = nil
    end

    if self.server_started_by_us then
        self.server_started_by_us = false
        logger.dbg(LOG_PREFIX, "Server stopped")
    end

    self.server_start_requested_by_us = false
    clearSaveDir()
    self.plugin_instance = nil
    self.using_raw_server = false
    self.active_input_widget = nil
end

-- Hook into InputText widget to detect when text input is active
local InputText = require("ui/widget/inputtext")
local orig_InputText_init = InputText.init

function InputText:init()
    orig_InputText_init(self)

    -- When an InputText is initialized and becomes editable, start LocalSend
    if not self.readonly then
        TextInputIntegration.active_input_widget = self
        logger.dbg(LOG_PREFIX, "Text input activated")

        -- Start server when text input becomes active
        -- Delay slightly to allow the widget to fully initialize
        UIManager:scheduleIn(0.5, function()
            if TextInputIntegration.active_input_widget == self then
                TextInputIntegration:startServer()
            end
        end)
    end
end

-- Hook into InputText cleanup
local orig_InputText_onCloseWidget = InputText.onCloseWidget

function InputText:onCloseWidget()
    if TextInputIntegration.active_input_widget == self then
        logger.dbg(LOG_PREFIX, "Text input deactivated")
        TextInputIntegration:stopServer()
    end

    if orig_InputText_onCloseWidget then
        return orig_InputText_onCloseWidget(self)
    end
end

-- Also handle InputDialog for better coverage
local InputDialog = require("ui/widget/inputdialog")
local orig_InputDialog_init = InputDialog.init

function InputDialog:init()
    orig_InputDialog_init(self)

    -- Track the dialog's internal input widget
    if self._input_widget and not self.readonly then
        TextInputIntegration.active_input_widget = self
        logger.dbg(LOG_PREFIX, "Input dialog activated")

        UIManager:scheduleIn(0.5, function()
            if TextInputIntegration.active_input_widget == self then
                TextInputIntegration:startServer()
            end
        end)
    end
end

local orig_InputDialog_onClose = InputDialog.onClose

function InputDialog:onClose()
    if TextInputIntegration.active_input_widget == self then
        logger.dbg(LOG_PREFIX, "Input dialog closed")
        TextInputIntegration:stopServer()
    end

    if orig_InputDialog_onClose then
        return orig_InputDialog_onClose(self)
    end
end

-- Log that the patch is loaded
logger.info(LOG_PREFIX, "Text input integration patch loaded")
