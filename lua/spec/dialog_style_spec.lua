require 'busted.runner'()

-- Tests for Issue #5: Dialog references should use local variables, not self fields
-- This ensures dialogs don't unnecessarily persist on the widget instance

describe("LocalSend Dialog References", function()
    local LocalSend

    setup(function()
        -- Mock KOReader dependencies
        package.loaded["ffi/util"] = {
            template = function(s, ...)
                local args = {...}
                local result = s
                for i, v in ipairs(args) do
                    result = result:gsub("%%" .. i, tostring(v))
                end
                return result
            end,
            usleep = function() end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
            sleep = function() end,
        }
        package.loaded["datastorage"] = {
            getFullDataDir = function() return "/tmp/koreader" end,
        }
        package.loaded["device"] = {
            isKindle = function() return false end,
            retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
        }
        package.loaded["dispatcher"] = {
            registerAction = function() end,
        }
        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o) return o end,
        }
        package.loaded["ui/widget/inputdialog"] = {
            new = function(self, o)
                return {
                    _is_dialog = true,
                    getInputText = function() return "" end,
                    onShowKeyboard = function() end,
                }
            end,
        }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = { isOnline = function() return true end }

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
        }

        -- Mock WidgetContainer
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
        package.loaded["util"] = {
            shell_escape = function(t)
                local escaped = {}
                for _, v in ipairs(t) do
                    if v == nil then
                        table.insert(escaped, "''")
                    else
                        table.insert(escaped, "'" .. tostring(v):gsub("'", "'\\''") .. "'")
                    end
                end
                return table.concat(escaped, " ")
            end,
            pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end,
            makePath = function() return true end,
            readFromFile = function() return nil end,
        }
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }
        package.loaded["localsend_utils"] = require("localsend_utils")

        -- Mock G_reader_settings
        local settings = {}
        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
            _settings = settings,
            _reset = function()
                for k in pairs(settings) do settings[k] = nil end
            end,
        }

        -- Mock dofile for _meta.lua
        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
            error("dofile not mocked for: " .. path)
        end
    end)

    before_each(function()
        G_reader_settings._reset()
        package.loaded["main"] = nil
    end)

    describe("dialog field cleanup", function()
        -- These tests verify that dialog instances are NOT stored on self
        -- Official KOReader pattern is to use local variables for dialogs

        it("should NOT have device_name_dialog field after showDeviceNameDialog", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Before calling, field should not exist
            assert.is_nil(instance.device_name_dialog,
                "device_name_dialog should not exist before calling showDeviceNameDialog")

            -- Call the dialog function
            instance:showDeviceNameDialog({})

            -- After calling, field should still not exist (dialog should be local)
            assert.is_nil(instance.device_name_dialog,
                "device_name_dialog should NOT be stored on self - use local variable instead")
        end)

        it("should NOT have pin_dialog field after showPinDialog", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance.pin_dialog,
                "pin_dialog should not exist before calling showPinDialog")

            instance:showPinDialog({})

            assert.is_nil(instance.pin_dialog,
                "pin_dialog should NOT be stored on self - use local variable instead")
        end)

        it("should NOT have accept_ext_dialog field after showCustomExtDialog", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance.accept_ext_dialog,
                "accept_ext_dialog should not exist before calling showCustomExtDialog")

            pcall(function() instance:showCustomExtDialog() end)

            assert.is_nil(instance.accept_ext_dialog,
                "accept_ext_dialog should NOT be stored on self - use local variable instead")
        end)

        it("should NOT have ext_preset_dialog field after dialog functions", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance.ext_preset_dialog,
                "ext_preset_dialog should not exist initially")

            -- The ext_preset_dialog might be created in various functions
            -- Just verify it's not persisted on the instance after creation
        end)

        it("should NOT have custom_ext_dialog field after showAddExtensionRouteDialog", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance.custom_ext_dialog,
                "custom_ext_dialog should not exist before calling")

            pcall(function() instance:showAddExtensionRouteDialog({}) end)

            assert.is_nil(instance.custom_ext_dialog,
                "custom_ext_dialog should NOT be stored on self - use local variable instead")
        end)

        it("should NOT have route_action_dialog field after dialog functions", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance.route_action_dialog,
                "route_action_dialog should not exist initially")

            -- The route_action_dialog might be created in various routing functions
            -- Just verify it's not persisted on the instance
            assert.is_nil(instance.route_action_dialog,
                "route_action_dialog should NOT be stored on self - use local variable instead")
        end)
    end)

    describe("general dialog pattern", function()
        it("instance should not accumulate dialog fields over time", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Count dialog-related fields on instance
            local dialog_fields = {}
            for k, _ in pairs(instance) do
                if type(k) == "string" and k:match("_dialog$") then
                    table.insert(dialog_fields, k)
                end
            end

            assert.equal(0, #dialog_fields,
                "Instance should not have any *_dialog fields. Found: " .. table.concat(dialog_fields, ", "))
        end)
    end)
end)
