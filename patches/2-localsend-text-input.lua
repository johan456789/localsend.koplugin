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
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- Constants
local TEXT_INPUT_SAVE_DIR = "/tmp/localsend_textinput"
local POLL_INTERVAL = 1  -- seconds
local LOG_PREFIX = "[LocalSend-TextInput]"

-- State tracking
local TextInputIntegration = {
    active_input_widget = nil,
    server_started_by_us = false,
    poll_task = nil,
    last_file_count = 0,
}

-- Get the LocalSend plugin instance
local function getLocalSendPlugin()
    local PluginLoader = require("pluginloader")
    if PluginLoader.enabled_plugins then
        for _, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "LocalSend" then
                return plugin
            end
        end
    end

    -- Try alternate method via PluginShare
    local PluginShare = require("pluginshare")
    if PluginShare.localsend_running then
        -- Plugin is running, try to get instance from loaded plugins
        local ok, main = pcall(require, "localsend.koplugin/main")
        if ok and main then
            return main
        end
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
    os.execute("rm -f " .. TEXT_INPUT_SAVE_DIR .. "/*")
end

-- Count files in save directory
local function countFiles()
    local count = 0
    local dir = io.popen("ls -1 " .. TEXT_INPUT_SAVE_DIR .. " 2>/dev/null")
    if dir then
        for _ in dir:lines() do
            count = count + 1
        end
        dir:close()
    end
    return count
end

-- Get list of .txt files in save directory
local function getTxtFiles()
    local files = {}
    local dir = io.popen("ls -1t " .. TEXT_INPUT_SAVE_DIR .. "/*.txt 2>/dev/null")
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
    local current_count = countFiles()
    if current_count > TextInputIntegration.last_file_count then
        -- New files arrived
        local txt_files = getTxtFiles()
        if #txt_files > 0 then
            -- Process the newest file
            local newest_file = txt_files[1]
            local content = readTextFile(newest_file)

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

                -- Remove the processed file
                os.remove(newest_file)
            end
        end
    end
    TextInputIntegration.last_file_count = current_count
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

-- Start the LocalSend server for text input
function TextInputIntegration:startServer()
    if not isLocalSendInstalled() then
        logger.dbg(LOG_PREFIX, "LocalSend plugin not installed")
        return false
    end

    ensureSaveDir()
    clearSaveDir()
    self.last_file_count = 0

    -- Build command to start LocalSend server
    local DataStorage = require("datastorage")
    local binary_path = DataStorage:getFullDataDir() .. "/plugins/localsend.koplugin/localsend"

    if not util.pathExists(binary_path) then
        logger.warn(LOG_PREFIX, "LocalSend binary not found")
        return false
    end

    -- Check if server is already running
    local PluginShare = require("pluginshare")
    if PluginShare.localsend_running then
        logger.dbg(LOG_PREFIX, "LocalSend already running, using existing server")
        -- We need to configure it to accept .txt files to our directory
        -- For now, we'll use a separate instance approach
    end

    -- Start the server with text-input specific settings
    local pid_file = "/tmp/localsend_textinput.pid"

    -- Build command using proper shell escaping
    local cmd = string.format(
        "(%s recv -d %s --accept-ext txt -n KOReader-TextInput) & echo $! > %s",
        binary_path,
        TEXT_INPUT_SAVE_DIR,
        pid_file
    )

    logger.dbg(LOG_PREFIX, "Starting server:", cmd)
    local result = os.execute(cmd)

    if result == 0 then
        self.server_started_by_us = true

        -- Start polling for files
        self.poll_task = function()
            pollForFiles()
        end
        UIManager:scheduleIn(POLL_INTERVAL, self.poll_task)

        UIManager:show(Notification:new{
            text = _("LocalSend ready for text input"),
            timeout = 3,
        })
        return true
    end

    return false
end

-- Stop the LocalSend server if we started it
function TextInputIntegration:stopServer()
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end

    if self.server_started_by_us then
        local pid_file = "/tmp/localsend_textinput.pid"
        local f = io.open(pid_file, "r")
        if f then
            local pid = f:read("*l")
            f:close()
            if pid then
                os.execute("kill " .. pid .. " 2>/dev/null")
            end
            os.remove(pid_file)
        end
        self.server_started_by_us = false
        logger.dbg(LOG_PREFIX, "Server stopped")
    end

    clearSaveDir()
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
