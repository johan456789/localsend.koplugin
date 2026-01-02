require 'busted.runner'()

-- Tests for LocalSend plugin lifecycle behavior
-- These tests verify the plugin behaves correctly during KOReader events

describe("LocalSend Lifecycle", function()
    local LocalSend
    local notifications_shown
    local server_stopped

    setup(function()
        -- Mock KOReader dependencies
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
            retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
        }
        package.loaded["dispatcher"] = {
            registerAction = function() end,
        }
        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o.text or "notification")
                return o
            end,
        }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
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
            pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end,
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
        notifications_shown = {}
        server_stopped = false
        G_reader_settings._reset()

        -- Reset package.loaded to get fresh LocalSend instance
        package.loaded["main"] = nil
    end)

    describe("start() when server already running", function()
        it("should NOT show notification if server is already running", function()
            -- Load the module
            LocalSend = require("main")

            -- Create instance with mocked menu
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Mock isRunning to return true (server already running)
            instance.isRunning = function() return true end

            -- Clear any notifications from init
            notifications_shown = {}

            -- Call start()
            instance:start()

            -- Should NOT have shown any notification
            assert.equal(0, #notifications_shown,
                "No notification should be shown when server is already running")
        end)
    end)

    describe("onExit vs onCloseWidget behavior", function()
        it("should have onExit method defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.onExit,
                "onExit should be defined for cleanup on KOReader exit")
        end)

        it("should NOT have onCloseWidget method defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- onCloseWidget should NOT exist because it's called on document switch
            -- which would incorrectly stop the server
            assert.is_nil(rawget(LocalSend, "onCloseWidget"),
                "onCloseWidget should NOT be defined - it fires on document switch!")
        end)

        it("onExit should stop server if running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function() stop_called = true; return true end

            instance:onExit()

            assert.is_true(stop_called, "onExit should stop the server")
        end)

        it("onExit should not error if server not running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end

            -- Should not throw
            assert.has_no.errors(function()
                instance:onExit()
            end)
        end)
    end)

    describe("autostart behavior", function()
        it("should call start() during init when autostart is enabled", function()
            G_reader_settings._settings["LocalSend_autostart"] = true

            LocalSend = require("main")

            local start_called = false
            local original_start = LocalSend.start
            LocalSend.start = function(self)
                start_called = true
            end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(start_called, "start() should be called when autostart is enabled")

            LocalSend.start = original_start
        end)

        it("should NOT call start() during init when autostart is disabled", function()
            G_reader_settings._settings["LocalSend_autostart"] = false

            LocalSend = require("main")

            local start_called = false
            local original_start = LocalSend.start
            LocalSend.start = function(self)
                start_called = true
            end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(start_called, "start() should NOT be called when autostart is disabled")

            LocalSend.start = original_start
        end)

        it("should NOT autostart after user explicitly stops server", function()
            G_reader_settings._settings["LocalSend_autostart"] = true
            _G.LocalSend_user_stopped = nil -- Clear any previous state

            LocalSend = require("main")

            -- First instance - autostart should work
            local start_count = 0
            local original_start = LocalSend.start
            LocalSend.start = function(self)
                start_count = start_count + 1
            end

            local instance1 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.equal(1, start_count, "First init should autostart")

            -- User explicitly stops the server
            instance1.stopServer = function() return true end
            instance1:stop()

            -- Simulate opening a new document (new plugin instance)
            package.loaded["main"] = nil
            LocalSend = require("main")
            LocalSend.start = function(self)
                start_count = start_count + 1
            end

            local instance2 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should NOT have called start again because user explicitly stopped
            assert.equal(1, start_count,
                "Should NOT autostart after user explicitly stopped server")

            -- Cleanup
            _G.LocalSend_user_stopped = nil
        end)

        it("should clear user_stopped flag when user manually starts", function()
            _G.LocalSend_user_stopped = true -- Simulate user had stopped

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            instance.start = function() end -- Mock start

            -- User manually starts via toggle
            instance:onToggleLocalSend()

            assert.is_nil(_G.LocalSend_user_stopped,
                "Manual start should clear the user_stopped flag")

            -- Cleanup
            _G.LocalSend_user_stopped = nil
        end)

        it("should set user_stopped flag when user manually stops", function()
            _G.LocalSend_user_stopped = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.stopServer = function() return true end

            -- User manually stops
            instance:stop()

            assert.is_true(_G.LocalSend_user_stopped,
                "Manual stop should set the user_stopped flag")

            -- Cleanup
            _G.LocalSend_user_stopped = nil
        end)

        it("should allow autostart after user manually restarts", function()
            G_reader_settings._settings["LocalSend_autostart"] = true
            _G.LocalSend_user_stopped = nil

            LocalSend = require("main")

            local start_count = 0
            LocalSend.start = function(self)
                start_count = start_count + 1
            end

            -- First instance
            local instance1 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.equal(1, start_count, "First init should autostart")

            -- User stops
            instance1.stopServer = function() return true end
            instance1:stop()
            assert.is_true(_G.LocalSend_user_stopped)

            -- User manually restarts via toggle
            instance1.isRunning = function() return false end
            instance1:onToggleLocalSend()
            -- onToggleLocalSend calls start(), so count is now 2
            assert.equal(2, start_count, "Manual restart should call start")
            assert.is_nil(_G.LocalSend_user_stopped, "Flag should be cleared")

            -- Simulate opening new document
            package.loaded["main"] = nil
            LocalSend = require("main")
            LocalSend.start = function(self)
                start_count = start_count + 1
            end

            local instance2 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should autostart again because user manually restarted (flag was cleared)
            assert.equal(3, start_count,
                "Should autostart after user manually restarted")

            -- Cleanup
            _G.LocalSend_user_stopped = nil
        end)
    end)
end)
