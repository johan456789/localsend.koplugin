require 'busted.runner'()

-- Tests for the stop() wrapper function

describe("stop() wrapper function", function()
    local LocalSend
    local notifications_shown

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
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
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }

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
        _G.LocalSend_user_stopped = nil

        _G.G_reader_settings = {
            readSetting = function() return nil end,
            saveSetting = function() end,
            isTrue = function() return false end,
            nilOrTrue = function() return true end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
        }

        package.loaded["util"] = {
            pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
        }

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    after_each(function()
        _G.LocalSend_user_stopped = nil
    end)

    describe("user_stopped flag", function()
        it("should set global user_stopped flag", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return true end

            instance:stop()

            assert.is_true(_G.LocalSend_user_stopped,
                "Should set user_stopped flag")
        end)

        it("should set flag before attempting stop", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local flag_was_set = false
            instance.stopServer = function()
                flag_was_set = _G.LocalSend_user_stopped
                return true
            end

            instance:stop()

            assert.is_true(flag_was_set,
                "Flag should be set before stopServer is called")
        end)
    end)

    describe("graceful stop", function()
        it("should first attempt graceful stop (force=false)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_calls = {}
            instance.stopServer = function(self, force)
                table.insert(stop_calls, { force = force })
                return true
            end

            instance:stop()

            assert.equal(1, #stop_calls)
            assert.is_false(stop_calls[1].force, "First stop should be graceful")
        end)

        it("should show success notification on graceful stop", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return true end

            notifications_shown = {}
            instance:stop()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("server stopped") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success notification")
        end)
    end)

    describe("force stop fallback", function()
        it("should attempt force stop when graceful fails", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_calls = {}
            instance.stopServer = function(self, force)
                table.insert(stop_calls, { force = force })
                if not force then
                    return false, "Process did not exit"
                end
                return true
            end

            instance:stop()

            assert.equal(2, #stop_calls)
            assert.is_false(stop_calls[1].force, "First should be graceful")
            assert.is_true(stop_calls[2].force, "Second should be forced")
        end)

        it("should show success after force stop succeeds", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local call_count = 0
            instance.stopServer = function(self, force)
                call_count = call_count + 1
                if call_count == 1 then
                    return false, "Process did not exit"
                end
                return true
            end

            notifications_shown = {}
            instance:stop()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("server stopped") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success after force stop")
        end)
    end)

    describe("complete failure", function()
        it("should show error when both graceful and force fail", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.stopServer = function(self, force)
                return false, "Process did not exit"
            end

            notifications_shown = {}
            instance:stop()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" and n.text:match("Failed to stop") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error notification")
        end)

        it("should not show success notification on complete failure", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.stopServer = function(self, force)
                return false, "Process did not exit"
            end

            notifications_shown = {}
            instance:stop()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("server stopped") and not n.icon then
                    found_success = true
                    break
                end
            end
            assert.is_false(found_success, "Should not show success on failure")
        end)
    end)

    describe("notification details", function()
        it("success notification should have timeout", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return true end

            notifications_shown = {}
            instance:stop()

            local found_notification = nil
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("server stopped") then
                    found_notification = n
                    break
                end
            end
            assert.is_not_nil(found_notification)
            assert.equal(2, found_notification.timeout, "Success notification should have 2 second timeout")
        end)

        it("error notification should have warning icon", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return false, "error" end

            notifications_shown = {}
            instance:stop()

            local found_error = nil
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed") then
                    found_error = n
                    break
                end
            end
            assert.is_not_nil(found_error)
            assert.equal("notice-warning", found_error.icon)
        end)
    end)
end)
