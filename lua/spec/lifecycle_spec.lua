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
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
            sleep = function() end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
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
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
            unschedule = function() end,
        }
        package.loaded["pluginshare"] = {}

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
            makePath = function(path) return true end,
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

        it("should have onCloseWidget method that cleans up tasks but NOT server", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- onCloseWidget SHOULD exist to clean up scheduled Lua tasks
            -- But it should NOT stop the server (server persists across document switches)
            assert.is_function(instance.onCloseWidget,
                "onCloseWidget should be defined for task cleanup")

            -- Verify it doesn't stop the server
            local stop_called = false
            instance.stopServer = function() stop_called = true; return true end
            instance.isRunning = function() return true end

            instance:onCloseWidget()

            assert.is_false(stop_called,
                "onCloseWidget should NOT stop the server - it fires on document switch!")
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

            LocalSend = require("main")
            LocalSend._ServerState.user_stopped = false -- Clear any previous state

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
            -- Note: ServerState persists because it's a module-local table
            local instance2 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should NOT have called start again because user explicitly stopped
            assert.equal(1, start_count,
                "Should NOT autostart after user explicitly stopped server")

            -- Cleanup
            LocalSend._ServerState.user_stopped = false
        end)

        it("should clear user_stopped flag when user manually starts", function()
            LocalSend = require("main")
            LocalSend._ServerState.user_stopped = true -- Simulate user had stopped

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            instance.start = function() end -- Mock start

            -- User manually starts via toggle
            instance:onToggleLocalSend()

            assert.is_false(LocalSend._ServerState.user_stopped,
                "Manual start should clear the user_stopped flag")

            -- Cleanup
            LocalSend._ServerState.user_stopped = false
        end)

        it("should set user_stopped flag when user manually stops", function()
            LocalSend = require("main")
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.stopServer = function() return true end

            -- User manually stops
            instance:stop()

            assert.is_true(LocalSend._ServerState.user_stopped,
                "Manual stop should set the user_stopped flag")

            -- Cleanup
            LocalSend._ServerState.user_stopped = false
        end)

        it("should allow autostart after user manually restarts", function()
            G_reader_settings._settings["LocalSend_autostart"] = true

            LocalSend = require("main")
            LocalSend._ServerState.user_stopped = false

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
            assert.is_true(LocalSend._ServerState.user_stopped)

            -- User manually restarts via toggle
            instance1.isRunning = function() return false end
            instance1:onToggleLocalSend()
            -- onToggleLocalSend calls start(), so count is now 2
            assert.equal(2, start_count, "Manual restart should call start")
            assert.is_false(LocalSend._ServerState.user_stopped, "Flag should be cleared")

            -- Simulate opening new document - ServerState persists across instances
            local instance2 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should autostart again because user manually restarted (flag was cleared)
            assert.equal(3, start_count,
                "Should autostart after user manually restarted")

            -- Cleanup
            LocalSend._ServerState.user_stopped = false
        end)
    end)

    describe("suspend/resume behavior", function()
        it("should have _onSuspend implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.is_function(instance._onSuspend)
        end)

        it("should have _onResume implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.is_function(instance._onResume)
        end)

        it("should have _onEnterStandby implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.is_function(instance._onEnterStandby)
        end)

        it("should have _onLeaveStandby implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.is_function(instance._onLeaveStandby)
        end)

        it("onSuspend should be registered when autostart is enabled", function()
            _G.G_reader_settings._settings["LocalSend_autostart"] = true
            package.loaded["main"] = nil  -- Force reload
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            assert.is_function(instance.onSuspend, "onSuspend should be registered when autostart is enabled")
            _G.G_reader_settings._settings["LocalSend_autostart"] = nil
        end)

        it("_onSuspend should stop server and set was_running_before_suspend", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function() stop_called = true; return true end

            instance:_onSuspend()

            assert.is_true(stop_called, "_onSuspend should stop the server")
            assert.is_true(LocalSend._ServerState.was_running_before_suspend,
                "was_running_before_suspend should be true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)

        it("onSuspend should clear was_running_before_suspend if server not running", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true -- Previously set

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end

            instance:_onSuspend()

            assert.is_false(LocalSend._ServerState.was_running_before_suspend,
                "was_running_before_suspend should be false when server not running")
        end)

        it("onResume should restart server if was_running_before_suspend is true", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            local start_silent = nil
            instance.start = function(self, silent)
                start_called = true
                start_silent = silent
            end

            instance:_onResume()

            -- NetworkMgr:runWhenConnected mock calls callback immediately
            assert.is_true(start_called, "start should be called after resume")
            assert.is_true(start_silent, "start should be called with silent=true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)

        it("onResume should NOT restart server if user_stopped is true", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true
            LocalSend._ServerState.user_stopped = true

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
        package.loaded["pluginshare"] = {}

            local start_called = false
            instance.start = function(self, silent)
                start_called = true
            end

            instance:_onResume()

            assert.is_false(start_called,
                "start should NOT be called when user_stopped is true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
            LocalSend._ServerState.user_stopped = false
        end)

        it("onResume should NOT restart server if was_running_before_suspend is false", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = false
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.start = function(self, silent)
                start_called = true
            end

            instance:_onResume()

            assert.is_false(start_called,
                "start should NOT be called when server was not running before suspend")
        end)

        it("onEnterStandby should stop server and set was_running_before_suspend", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function() stop_called = true; return true end

            instance:_onEnterStandby()

            assert.is_true(stop_called, "onEnterStandby should stop the server")
            assert.is_true(LocalSend._ServerState.was_running_before_suspend,
                "was_running_before_suspend should be true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)

        it("onLeaveStandby should restart server immediately (no delay)", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            local start_silent = nil
            instance.start = function(self, silent)
                start_called = true
                start_silent = silent
            end

            instance:_onLeaveStandby()

            -- onLeaveStandby calls start directly, no delay
            assert.is_true(start_called, "start should be called after leaving standby")
            assert.is_true(start_silent, "start should be called with silent=true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)

        it("onLeaveStandby should NOT restart server if user_stopped is true", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true
            LocalSend._ServerState.user_stopped = true

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.start = function(self, silent)
                start_called = true
            end

            instance:_onLeaveStandby()

            assert.is_false(start_called,
                "start should NOT be called when user_stopped is true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
            LocalSend._ServerState.user_stopped = false
        end)
    end)

    describe("start(silent) behavior", function()
        it("start(true) should not show success notification", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Mock necessary functions
            local is_running = false
            instance.save_dir = "/mnt/us/documents"
            instance.validateSaveDir = function() return true end
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end
            -- isRunning returns false initially, then true after os.execute
            instance.isRunning = function() return is_running end

            -- Make os.execute succeed and set server as running
            local original_execute = os.execute
            os.execute = function() is_running = true; return 0 end

            -- Clear notifications
            notifications_shown = {}

            -- Start with silent=true
            instance:start(true)

            -- Restore
            os.execute = original_execute

            -- Should NOT have shown the "LocalSend Ready" notification
            local found_ready_notification = false
            for _, msg in ipairs(notifications_shown) do
                if msg and msg:match("LocalSend Ready") then
                    found_ready_notification = true
                    break
                end
            end

            assert.is_false(found_ready_notification,
                "start(true) should not show 'LocalSend Ready' notification")
        end)

        it("start(true) should not clear transfer log", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local clear_log_called = false
            local is_running = false
            instance.save_dir = "/mnt/us/documents"
            instance.validateSaveDir = function() return true end
            instance.clearTransferLog = function() clear_log_called = true end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end
            -- isRunning returns false initially, then true after os.execute
            instance.isRunning = function() return is_running end

            local original_execute = os.execute
            os.execute = function() is_running = true; return 0 end

            -- Start with silent=true
            instance:start(true)

            os.execute = original_execute

            assert.is_false(clear_log_called,
                "start(true) should not clear transfer log (preserve across sleep)")
        end)

        it("start(false) should clear transfer log", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local clear_log_called = false
            local is_running = false
            instance.save_dir = "/mnt/us/documents"
            instance.validateSaveDir = function() return true end
            instance.clearTransferLog = function() clear_log_called = true end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end
            -- isRunning returns false initially, then true after os.execute
            instance.isRunning = function() return is_running end

            local original_execute = os.execute
            os.execute = function() is_running = true; return 0 end

            -- Start with silent=false (or nil)
            instance:start()

            os.execute = original_execute

            assert.is_true(clear_log_called,
                "start() without silent should clear transfer log")
        end)
    end)

    -- =========================================================================
    -- Network disconnect/reconnect handling
    -- =========================================================================
    describe("network disconnect/reconnect behavior", function()
        it("should have _onNetworkDisconnected implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._onNetworkDisconnected,
                "_onNetworkDisconnected implementation should be defined to handle WiFi loss")
        end)

        it("should have _onNetworkConnected implementation defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._onNetworkConnected,
                "_onNetworkConnected implementation should be defined to handle WiFi reconnection")
        end)

        it("ServerState should have was_running_before_disconnect field", function()
            LocalSend = require("main")

            assert.is_not_nil(LocalSend._ServerState.was_running_before_disconnect,
                "ServerState should track was_running_before_disconnect")
        end)

        it("onNetworkDisconnected should stop server if running", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_disconnect = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function() stop_called = true; return true end

            instance:_onNetworkDisconnected()

            assert.is_true(stop_called,
                "onNetworkDisconnected should stop the server")
            assert.is_true(LocalSend._ServerState.was_running_before_disconnect,
                "should set was_running_before_disconnect for potential reconnect")

            -- Cleanup
            LocalSend._ServerState.was_running_before_disconnect = false
        end)

        it("onNetworkDisconnected should set was_running_before_disconnect=false if not running", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_disconnect = true -- Previously set

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end

            instance:_onNetworkDisconnected()

            assert.is_false(LocalSend._ServerState.was_running_before_disconnect,
                "should clear was_running_before_disconnect when server not running")
        end)

        it("onNetworkConnected should restart server if was_running_before_disconnect", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_disconnect = true
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            local start_silent = nil
            instance.start = function(self, silent)
                start_called = true
                start_silent = silent
            end

            instance:_onNetworkConnected()

            assert.is_true(start_called,
                "onNetworkConnected should restart server if it was running before disconnect")
            assert.is_true(start_silent,
                "onNetworkConnected should call start with silent=true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_disconnect = false
        end)

        it("onNetworkConnected should NOT restart if user_stopped is true", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_disconnect = true
            LocalSend._ServerState.user_stopped = true

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.start = function(self, silent)
                start_called = true
            end

            instance:_onNetworkConnected()

            assert.is_false(start_called,
                "onNetworkConnected should NOT restart if user explicitly stopped")

            -- Cleanup
            LocalSend._ServerState.user_stopped = false
            LocalSend._ServerState.was_running_before_disconnect = false
        end)

        it("onNetworkConnected should NOT restart if was_running_before_disconnect is false", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_disconnect = false
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.start = function(self, silent)
                start_called = true
            end

            instance:_onNetworkConnected()

            assert.is_false(start_called,
                "onNetworkConnected should NOT restart if server was not running before disconnect")
        end)
    end)

    -- =========================================================================
    -- onFlushSettings lifecycle handler
    -- =========================================================================
    describe("onFlushSettings lifecycle", function()
        it("should have onFlushSettings method defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.onFlushSettings,
                "onFlushSettings should be defined for proper KOReader lifecycle compliance")
        end)

        it("onFlushSettings should not error when called", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.has_no.errors(function()
                instance:onFlushSettings()
            end)
        end)
    end)
end)
