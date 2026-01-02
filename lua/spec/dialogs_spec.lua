require 'busted.runner'()

-- Tests for dialog functions: showSaveDirPicker, showDeviceNameDialog, showPinDialog,
-- showCustomExtDialog, showAddExtensionRouteDialog, showCustomExtensionDialog, showExtensionDirPicker

describe("Dialog Functions", function()
    local LocalSend
    local notifications_shown
    local dialogs_shown
    local settings

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...)
                -- Simple template substitution for %1, %2, etc.
                local args = {...}
                local result = s
                for i, v in ipairs(args) do
                    result = result:gsub("%%" .. i, tostring(v))
                end
                return result
            end,
            usleep = function() end,
            sleep = function() end,
        }
        package.loaded["datastorage"] = {
            getFullDataDir = function() return "/tmp/koreader" end,
        }
        package.loaded["device"] = {
            isKindle = function() return false end,
            retrieveNetworkInfo = function() return "WiFi" end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }

        local WidgetContainer = {}
        WidgetContainer.__index = WidgetContainer
        function WidgetContainer:extend(o)
            o = o or {}
            setmetatable(o, self)
            self.__index = self
            o.__index = o
            return o
        end
        function WidgetContainer:new(o)
            o = o or {}
            setmetatable(o, self)
            if o.init then o:init() end
            return o
        end
        package.loaded["ui/widget/container/widgetcontainer"] = WidgetContainer

        package.loaded["logger"] = {
            err = function() end,
            warn = function() end,
            info = function() end,
            dbg = function() end,
        }
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        notifications_shown = {}
        dialogs_shown = {}
        settings = {}

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["util"] = {
            pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/documents" then return true end
                return false
            end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/widget/inputdialog"] = {
            new = function(self, o)
                o._type = "InputDialog"
                table.insert(dialogs_shown, o)
                -- Mock getInputText to return the input or a test value
                o.getInputText = function()
                    return o._mock_input or o.input or ""
                end
                o.onShowKeyboard = function() end
                return o
            end,
        }

        package.loaded["ui/widget/pathchooser"] = {
            new = function(self, o)
                o._type = "PathChooser"
                table.insert(dialogs_shown, o)
                return o
            end,
        }

        package.loaded["ui/widget/buttondialog"] = {
            new = function(self, o)
                o._type = "ButtonDialog"
                table.insert(dialogs_shown, o)
                return o
            end,
        }

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
        }

        _G.os.execute = function() return 0 end
        _G.os.remove = function() return true end

        -- Mock io.open for write tests
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" and path:match("%.localsend_write_test$") then
                return { close = function() end }
            end
            return original_io_open(path, mode)
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("showSaveDirPicker", function()
        it("should create PathChooser for directory selection", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            local mock_menu = { updateItems = function() end }
            dialogs_shown = {}

            instance:showSaveDirPicker(mock_menu)

            local found_path_chooser = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "PathChooser" then
                    found_path_chooser = true
                    assert.is_true(d.select_directory, "Should select directories")
                    assert.is_false(d.select_file, "Should not select files")
                    break
                end
            end
            assert.is_true(found_path_chooser, "Should show PathChooser")
        end)

        it("should use getPickerStartPath for initial path", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            local picker_start_called = false
            instance.getPickerStartPath = function(self, path)
                picker_start_called = true
                return path
            end

            dialogs_shown = {}
            instance:showSaveDirPicker({ updateItems = function() end })

            assert.is_true(picker_start_called, "Should call getPickerStartPath")
        end)

        it("should have onConfirm callback that validates directory", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            dialogs_shown = {}
            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = nil
            for _, d in ipairs(dialogs_shown) do
                if d._type == "PathChooser" then
                    path_chooser = d
                    break
                end
            end

            assert.is_not_nil(path_chooser)
            assert.is_function(path_chooser.onConfirm)
        end)

        it("onConfirm should save valid directory", function()
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/newdir" then return true end
                return false
            end

            -- Mock write test
            _G.io.open = function(path, mode)
                if mode == "w" and path:match("%.localsend_write_test$") then
                    return { close = function() end }
                end
                return nil
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            local menu_updated = false
            local mock_menu = { updateItems = function() menu_updated = true end }

            dialogs_shown = {}
            instance:showSaveDirPicker(mock_menu)

            local path_chooser = dialogs_shown[1]

            -- Simulate selecting a valid directory
            path_chooser.onConfirm("/mnt/us/newdir")

            assert.equal("/mnt/us/newdir", instance.save_dir)
            assert.equal("/mnt/us/newdir", settings["LocalSend_save_dir"])
        end)

        it("onConfirm should show error for invalid directory", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.validateSaveDir = function() return false, "Not writable" end

            dialogs_shown = {}
            notifications_shown = {}
            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = dialogs_shown[1]
            path_chooser.onConfirm("/readonly/path")

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" and n.text:match("Cannot use this directory") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error for invalid directory")
        end)
    end)

    describe("showDeviceNameDialog", function()
        it("should create InputDialog with current device name", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.device_name = "My Kindle"

            dialogs_shown = {}
            instance:showDeviceNameDialog({ updateItems = function() end })

            local found_dialog = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "InputDialog" and d.title:match("Device name") then
                    found_dialog = true
                    assert.equal("My Kindle", d.input)
                    break
                end
            end
            assert.is_true(found_dialog, "Should show InputDialog for device name")
        end)

        it("should have description mentioning random name option", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            assert.truthy(dialog.description:match("random name"))
        end)

        it("should validate device name on save", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.device_name = ""

            local validate_called = false
            instance.validateDeviceName = function(self, name)
                validate_called = true
                return true
            end

            dialogs_shown = {}
            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            dialog._mock_input = "New Name"

            -- Find and call the Save button callback
            local save_button = dialog.buttons[1][2] -- Second button in first row
            save_button.callback()

            assert.is_true(validate_called)
        end)

        it("should show error for invalid device name", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.validateDeviceName = function() return false, "Invalid characters" end

            dialogs_shown = {}
            notifications_shown = {}
            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            dialog._mock_input = "Invalid<>Name"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error)
        end)

        it("cancel button should close dialog without changes", function()
            -- Track close calls through the mock
            local close_called = false
            local close_arg = nil
            package.loaded["ui/uimanager"] = {
                show = function() end,
                close = function(self, dialog)
                    close_called = true
                    close_arg = dialog
                end,
                scheduleIn = function() end,
            }

            -- Must reload main module to pick up new UIManager mock
            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.device_name = "Original Name"

            dialogs_shown = {}
            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]  -- First button in first row

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(close_called, "Cancel should close dialog")
            assert.equal("Original Name", instance.device_name, "Device name should not change")
        end)
    end)

    describe("showPinDialog", function()
        it("should create InputDialog for PIN", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.pin = "1234"

            dialogs_shown = {}
            instance:showPinDialog({ updateItems = function() end })

            local found_dialog = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "InputDialog" and d.title:match("PIN") then
                    found_dialog = true
                    assert.equal("1234", d.input)
                    break
                end
            end
            assert.is_true(found_dialog)
        end)

        it("should save PIN and update settings", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.pin = ""

            local menu_updated = false
            dialogs_shown = {}
            instance:showPinDialog({ updateItems = function() menu_updated = true end })

            local dialog = dialogs_shown[1]
            dialog._mock_input = "5678"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            assert.equal("5678", instance.pin)
            assert.equal("5678", settings["LocalSend_pin"])
        end)

        it("cancel button should close dialog without changes", function()
            -- Track close calls through the mock
            local close_called = false
            package.loaded["ui/uimanager"] = {
                show = function() end,
                close = function(self, dialog)
                    close_called = true
                end,
                scheduleIn = function() end,
            }

            -- Must reload main module to pick up new UIManager mock
            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.pin = "1234"

            dialogs_shown = {}
            instance:showPinDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(close_called, "Cancel should close dialog")
            assert.equal("1234", instance.pin, "PIN should not change")
        end)
    end)

    describe("showCustomExtDialog", function()
        it("should create InputDialog for custom extensions", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.accept_ext = "epub,pdf"

            dialogs_shown = {}
            instance:showCustomExtDialog()

            local found_dialog = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "InputDialog" and d.title:match("extensions") then
                    found_dialog = true
                    assert.equal("epub,pdf", d.input)
                    break
                end
            end
            assert.is_true(found_dialog)
        end)

        it("should have comma-separated example in description", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showCustomExtDialog()

            local dialog = dialogs_shown[1]
            assert.truthy(dialog.description:match("Comma%-separated"))
        end)

        it("should save custom extensions", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.accept_ext = ""

            dialogs_shown = {}
            instance:showCustomExtDialog()

            local dialog = dialogs_shown[1]
            dialog._mock_input = "mobi,azw3"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            assert.equal("mobi,azw3", instance.accept_ext)
            assert.equal("mobi,azw3", settings["LocalSend_accept_ext"])
        end)

        it("cancel button should close dialog without changes", function()
            -- Track close calls through the mock
            local close_called = false
            package.loaded["ui/uimanager"] = {
                show = function() end,
                close = function(self, dialog)
                    close_called = true
                end,
                scheduleIn = function() end,
            }

            -- Must reload main module to pick up new UIManager mock
            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.accept_ext = "epub,pdf"

            dialogs_shown = {}
            instance:showCustomExtDialog()

            local dialog = dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(close_called, "Cancel should close dialog")
            assert.equal("epub,pdf", instance.accept_ext, "Extensions should not change")
        end)
    end)

    describe("showAddExtensionRouteDialog", function()
        it("should show ButtonDialog with extension presets", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local found_dialog = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "ButtonDialog" then
                    found_dialog = true
                    assert.truthy(d.title:match("extension"))
                    break
                end
            end
            assert.is_true(found_dialog)
        end)

        it("should have common ebook extension buttons", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local found_epub = false
            local found_pdf = false

            for _, row in ipairs(dialog.buttons) do
                for _, button in ipairs(row) do
                    if button.text == "epub" then found_epub = true end
                    if button.text == "PDF" then found_pdf = true end
                end
            end

            assert.is_true(found_epub, "Should have epub button")
            assert.is_true(found_pdf, "Should have PDF button")
        end)

        it("should have Custom option", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local found_custom = false

            for _, row in ipairs(dialog.buttons) do
                for _, button in ipairs(row) do
                    if button.text:match("Custom") then
                        found_custom = true
                        break
                    end
                end
            end

            assert.is_true(found_custom, "Should have Custom option")
        end)
    end)

    describe("showCustomExtensionDialog", function()
        it("should create InputDialog for custom extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            dialogs_shown = {}
            instance:showCustomExtensionDialog({ updateItems = function() end })

            local found_dialog = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "InputDialog" and d.title:match("Extension to route") then
                    found_dialog = true
                    break
                end
            end
            assert.is_true(found_dialog)
        end)

        it("should strip leading dot from extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local picker_ext = nil
            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_ext = ext
            end

            dialogs_shown = {}
            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            dialog._mock_input = ".epub"

            local next_button = dialog.buttons[1][2]
            next_button.callback()

            assert.equal("epub", picker_ext, "Should strip leading dot")
        end)

        it("should lowercase the extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local picker_ext = nil
            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_ext = ext
            end

            dialogs_shown = {}
            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            dialog._mock_input = "EPUB"

            local next_button = dialog.buttons[1][2]
            next_button.callback()

            assert.equal("epub", picker_ext, "Should lowercase extension")
        end)

        it("cancel button should close dialog without proceeding", function()
            local picker_called = false
            -- Track close calls through the mock
            local close_called = false
            package.loaded["ui/uimanager"] = {
                show = function() end,
                close = function(self, dialog)
                    close_called = true
                end,
                scheduleIn = function() end,
            }

            -- Must reload main module to pick up new UIManager mock
            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_called = true
            end

            dialogs_shown = {}
            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(close_called, "Cancel should close dialog")
            assert.is_false(picker_called, "Should not proceed to extension picker")
        end)
    end)

    describe("showExtensionDirPicker", function()
        it("should create PathChooser for extension directory", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            dialogs_shown = {}
            instance:showExtensionDirPicker("epub", { updateItems = function() end })

            local found_chooser = false
            for _, d in ipairs(dialogs_shown) do
                if d._type == "PathChooser" then
                    found_chooser = true
                    -- PathChooser may or may not have title depending on KOReader version
                    -- Just verify it was created for directory selection
                    assert.is_true(d.select_directory)
                    break
                end
            end
            assert.is_true(found_chooser)
        end)

        it("onConfirm should add extension route", function()
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/books" then return true end
                return false
            end

            _G.io.open = function(path, mode)
                if mode == "w" then return { close = function() end } end
                return nil
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.ext_dirs = {}

            local route_added = false
            instance.addExtensionRoute = function(self, ext, dir)
                route_added = true
                assert.equal("pdf", ext)
                assert.equal("/mnt/us/books", dir)
            end

            dialogs_shown = {}
            instance:showExtensionDirPicker("pdf", { updateItems = function() end })

            local chooser = dialogs_shown[1]
            chooser.onConfirm("/mnt/us/books")

            assert.is_true(route_added)
        end)

        it("onConfirm should show success notification", function()
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/books" then return true end
                return false
            end

            _G.io.open = function(path, mode)
                if mode == "w" then return { close = function() end } end
                return nil
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.ext_dirs = {}
            instance.addExtensionRoute = function() end

            dialogs_shown = {}
            notifications_shown = {}
            instance:showExtensionDirPicker("epub", { updateItems = function() end })

            local chooser = dialogs_shown[1]
            chooser.onConfirm("/mnt/us/books")

            -- Check for success notification (text contains extension or path info)
            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("epub") or n.text:match("books")) then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success)
        end)
    end)
end)
