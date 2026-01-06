require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for dialog functions: showSaveDirPicker, showDeviceNameDialog, showPinDialog,
-- showCustomExtDialog, showAddExtensionRouteDialog, showCustomExtensionDialog, showExtensionDirPicker

describe("Dialog Functions", function()
    setup(function()
        helper.setup_complete({
            util = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                    if path == "/mnt/us/documents" then return true end
                    return false
                end,
            },
        })
        helper.mock_os_execute()
        helper.mock_os_remove()
    end)

    before_each(function()
        helper.before_each()
    end)

    describe("showSaveDirPicker", function()
        it("should create PathChooser for directory selection", function()
            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"

            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = helper.find_dialog("PathChooser")
            assert.is_truthy(path_chooser, "Should show PathChooser")
            assert.is_true(path_chooser.select_directory, "Should select directories")
            assert.is_false(path_chooser.select_file, "Should not select files")
        end)

        it("should use getPickerStartPath for initial path", function()
            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"

            local picker_start_called = false
            instance.getPickerStartPath = function(self, path)
                picker_start_called = true
                return path
            end

            instance:showSaveDirPicker({ updateItems = function() end })

            assert.is_true(picker_start_called, "Should call getPickerStartPath")
        end)

        it("should have onConfirm callback that validates directory", function()
            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"

            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = helper.find_dialog("PathChooser")
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
            local original_io_open = _G.io.open
            _G.io.open = function(path, mode)
                if mode == "w" and path:match("%.localsend_write_test$") then
                    return { close = function() end }
                end
                return original_io_open(path, mode)
            end

            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"

            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = helper.state.dialogs_shown[1]
            path_chooser.onConfirm("/mnt/us/newdir")

            assert.equal("/mnt/us/newdir", instance.save_dir)
            assert.equal("/mnt/us/newdir", helper.state.settings["LocalSend_save_dir"])
        end)

        it("onConfirm should show error for invalid directory", function()
            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"
            instance.validateSaveDir = function() return false, "Not writable" end

            instance:showSaveDirPicker({ updateItems = function() end })

            local path_chooser = helper.state.dialogs_shown[1]
            path_chooser.onConfirm("/readonly/path")

            local error_notification = helper.find_notification("Cannot use this directory")
            assert.is_truthy(error_notification, "Should show error for invalid directory")
        end)
    end)

    describe("showDeviceNameDialog", function()
        it("should create InputDialog with current device name", function()
            local instance = helper.create_instance()
            instance.device_name = "My Kindle"

            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = helper.find_dialog_with_title("InputDialog", "Device name")
            assert.is_truthy(dialog, "Should show InputDialog for device name")
            assert.equal("My Kindle", dialog.input)
        end)

        it("should have description mentioning default name option", function()
            local instance = helper.create_instance()

            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            assert.truthy(dialog.description:match("KOReader"))
        end)

        it("should validate device name on save", function()
            local instance = helper.create_instance()
            instance.device_name = ""

            local validate_called = false
            instance.validateDeviceName = function(self, name)
                validate_called = true
                return true
            end

            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = "New Name"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            assert.is_true(validate_called)
        end)

        it("should show error for invalid device name", function()
            local instance = helper.create_instance()
            instance.validateDeviceName = function() return false, "Invalid characters" end

            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = "Invalid<>Name"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            local found_error = false
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.icon == "notice-warning" then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error)
        end)

        it("cancel button should close dialog without changes", function()
            local instance = helper.create_instance()
            instance.device_name = "Original Name"

            instance:showDeviceNameDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(#helper.state.close_calls > 0, "Cancel should close dialog")
            assert.equal("Original Name", instance.device_name, "Device name should not change")
        end)
    end)

    describe("showPinDialog", function()
        it("should create InputDialog for PIN", function()
            local instance = helper.create_instance()
            instance.pin = "1234"

            instance:showPinDialog({ updateItems = function() end })

            local dialog = helper.find_dialog_with_title("InputDialog", "PIN")
            assert.is_truthy(dialog)
            assert.equal("1234", dialog.input)
        end)

        it("should save PIN and update settings", function()
            local instance = helper.create_instance()
            instance.pin = ""

            instance:showPinDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = "5678"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            assert.equal("5678", instance.pin)
            assert.equal("5678", helper.state.settings["LocalSend_pin"])
        end)

        it("cancel button should close dialog without changes", function()
            local instance = helper.create_instance()
            instance.pin = "1234"

            instance:showPinDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(#helper.state.close_calls > 0, "Cancel should close dialog")
            assert.equal("1234", instance.pin, "PIN should not change")
        end)
    end)

    describe("showCustomExtDialog", function()
        it("should create InputDialog for custom extensions", function()
            local instance = helper.create_instance()
            instance.accept_ext = "epub,pdf"

            instance:showCustomExtDialog()

            local dialog = helper.find_dialog_with_title("InputDialog", "extensions")
            assert.is_truthy(dialog)
            assert.equal("epub,pdf", dialog.input)
        end)

        it("should have comma-separated example in description", function()
            local instance = helper.create_instance()

            instance:showCustomExtDialog()

            local dialog = helper.state.dialogs_shown[1]
            assert.truthy(dialog.description:match("Comma%-separated"))
        end)

        it("should save custom extensions", function()
            local instance = helper.create_instance()
            instance.accept_ext = ""

            instance:showCustomExtDialog()

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = "mobi,azw3"

            local save_button = dialog.buttons[1][2]
            save_button.callback()

            assert.equal("mobi,azw3", instance.accept_ext)
            assert.equal("mobi,azw3", helper.state.settings["LocalSend_accept_ext"])
        end)

        it("cancel button should close dialog without changes", function()
            local instance = helper.create_instance()
            instance.accept_ext = "epub,pdf"

            instance:showCustomExtDialog()

            local dialog = helper.state.dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(#helper.state.close_calls > 0, "Cancel should close dialog")
            assert.equal("epub,pdf", instance.accept_ext, "Extensions should not change")
        end)
    end)

    describe("showAddExtensionRouteDialog", function()
        it("should show ButtonDialog with extension presets", function()
            local instance = helper.create_instance()

            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local dialog = helper.find_dialog("ButtonDialog")
            assert.is_truthy(dialog)
            assert.truthy(dialog.title:match("extension"))
        end)

        it("should have common ebook extension buttons", function()
            local instance = helper.create_instance()

            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            local found_epub, found_pdf = false, false

            for _, row in ipairs(dialog.buttons) do
                for _, button in ipairs(row) do
                    if button.text == "epub" then found_epub = true end
                    if button.text == "pdf" then found_pdf = true end
                end
            end

            assert.is_true(found_epub, "Should have epub button")
            assert.is_true(found_pdf, "Should have pdf button")
        end)

        it("should have Custom option", function()
            local instance = helper.create_instance()

            instance:showAddExtensionRouteDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
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
            local instance = helper.create_instance()

            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = helper.find_dialog_with_title("InputDialog", "Extension to route")
            assert.is_truthy(dialog)
        end)

        it("should strip leading dot from extension", function()
            local instance = helper.create_instance()

            local picker_ext = nil
            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_ext = ext
            end

            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = ".epub"

            local next_button = dialog.buttons[1][2]
            next_button.callback()

            assert.equal("epub", picker_ext, "Should strip leading dot")
        end)

        it("should lowercase the extension", function()
            local instance = helper.create_instance()

            local picker_ext = nil
            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_ext = ext
            end

            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            dialog._mock_input = "EPUB"

            local next_button = dialog.buttons[1][2]
            next_button.callback()

            assert.equal("epub", picker_ext, "Should lowercase extension")
        end)

        it("cancel button should close dialog without proceeding", function()
            local picker_called = false
            local instance = helper.create_instance()

            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_called = true
            end

            instance:showCustomExtensionDialog({ updateItems = function() end })

            local dialog = helper.state.dialogs_shown[1]
            local cancel_button = dialog.buttons[1][1]

            assert.equal("Cancel", cancel_button.text)
            cancel_button.callback()

            assert.is_true(#helper.state.close_calls > 0, "Cancel should close dialog")
            assert.is_false(picker_called, "Should not proceed to extension picker")
        end)
    end)

    describe("showExtensionDirPicker", function()
        it("should create PathChooser for extension directory", function()
            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"

            instance:showExtensionDirPicker("epub", { updateItems = function() end })

            local chooser = helper.find_dialog("PathChooser")
            assert.is_truthy(chooser)
            assert.is_true(chooser.select_directory)
        end)

        it("onConfirm should add extension route", function()
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/books" then return true end
                return false
            end

            local original_io_open = _G.io.open
            _G.io.open = function(path, mode)
                if mode == "w" then return { close = function() end } end
                return original_io_open(path, mode)
            end

            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"
            instance.ext_dirs = {}

            local route_added = false
            instance.addExtensionRoute = function(self, ext, dir)
                route_added = true
                assert.equal("pdf", ext)
                assert.equal("/mnt/us/books", dir)
            end

            instance:showExtensionDirPicker("pdf", { updateItems = function() end })

            local chooser = helper.state.dialogs_shown[1]
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

            local original_io_open = _G.io.open
            _G.io.open = function(path, mode)
                if mode == "w" then return { close = function() end } end
                return original_io_open(path, mode)
            end

            local instance = helper.create_instance()
            instance.save_dir = "/mnt/us/documents"
            instance.ext_dirs = {}
            instance.addExtensionRoute = function() end

            instance:showExtensionDirPicker("epub", { updateItems = function() end })

            local chooser = helper.state.dialogs_shown[1]
            chooser.onConfirm("/mnt/us/books")

            local found_success = false
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.text and (n.text:match("epub") or n.text:match("books")) then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success)
        end)
    end)

    -- Tests for dialog field cleanup (merged from dialog_style_spec.lua)
    describe("dialog field cleanup", function()
        it("should NOT have device_name_dialog field after showDeviceNameDialog", function()
            local instance = helper.create_instance()
            assert.is_nil(instance.device_name_dialog)
            instance:showDeviceNameDialog({})
            assert.is_nil(instance.device_name_dialog,
                "device_name_dialog should NOT be stored on self")
        end)

        it("should NOT have pin_dialog field after showPinDialog", function()
            local instance = helper.create_instance()
            assert.is_nil(instance.pin_dialog)
            instance:showPinDialog({})
            assert.is_nil(instance.pin_dialog,
                "pin_dialog should NOT be stored on self")
        end)

        it("instance should not accumulate dialog fields over time", function()
            local instance = helper.create_instance()
            local dialog_fields = {}
            for k, _ in pairs(instance) do
                if type(k) == "string" and k:match("_dialog$") then
                    table.insert(dialog_fields, k)
                end
            end
            assert.equal(0, #dialog_fields,
                "Instance should not have any *_dialog fields")
        end)
    end)

    -- Tests for getPickerStartPath (merged from path_picker_spec.lua)
    describe("getPickerStartPath", function()
        it("should return path unchanged when lock_home_folder is false", function()
            helper.state.settings["lock_home_folder"] = false
            helper.state.settings["home_dir"] = "/mnt/us/documents"

            local instance = helper.create_instance()
            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents/books", result)
        end)

        it("should return parent when lock_home_folder is true and path is inside home", function()
            helper.state.settings["lock_home_folder"] = true
            helper.state.settings["home_dir"] = "/mnt/us/documents"
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/documents" then return true end
                return false
            end

            local instance = helper.create_instance()
            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents", result)
        end)

        it("should return path unchanged when outside home_dir", function()
            helper.state.settings["lock_home_folder"] = true
            helper.state.settings["home_dir"] = "/mnt/us/documents"

            local instance = helper.create_instance()
            local result = instance:getPickerStartPath("/mnt/us/other/folder")
            assert.equal("/mnt/us/other/folder", result)
        end)

        it("should not match partial directory names", function()
            helper.state.settings["lock_home_folder"] = true
            helper.state.settings["home_dir"] = "/mnt/us/doc"

            local instance = helper.create_instance()
            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents/books", result)
        end)
    end)
end)
